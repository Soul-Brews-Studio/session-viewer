import { useCallback, useEffect, useRef, useState } from 'react'
import type { Group, WireEvent, WireFrame, WireSession } from './types'

const WS_URL = `ws://${location.hostname}:8779`
// The public Worker cannot open a local WebSocket or read a transcript. Keep the same
// interaction model there with deterministic fixture rows; local hosts still use Swift's
// live server exactly as before.
const PUBLIC_FIXTURE = location.hostname.endsWith('.workers.dev')
/** Same retention as the native app: every kept row is another node to diff and lay out,
 *  and an unbounded live tail is what pinned the Mac app at 100% CPU / 5.4 GB. */
const MAX_EVENTS = 150

const DEMO_FLEET: WireSession[] = [
  { path: '/fixture/projects/session-viewer/8c2a.jsonl', project: 'session-viewer', tier: 'session', sessionUUID: '8c2a1f90', agentId: null, agentName: null, workflowRunId: null, size: 2480000, secondsSinceWrite: 12, heat: 'hot' },
  { path: '/fixture/projects/session-viewer/8c2a/subagents/search.jsonl', project: 'session-viewer', tier: 'subagent', sessionUUID: '8c2a1f90', agentId: 'search-01', agentName: 'search', workflowRunId: null, size: 384000, secondsSinceWrite: 26, heat: 'warm' },
  { path: '/fixture/projects/lance-indexer/42bd.jsonl', project: 'lance-indexer', tier: 'session', sessionUUID: '42bd77e1', agentId: null, agentName: null, workflowRunId: null, size: 1740000, secondsSinceWrite: 58, heat: 'warm' },
  { path: '/fixture/projects/lance-indexer/42bd/subagents/map.jsonl', project: 'lance-indexer', tier: 'subagent', sessionUUID: '42bd77e1', agentId: 'map-02', agentName: 'map', workflowRunId: null, size: 212000, secondsSinceWrite: 75, heat: 'cool' },
  { path: '/fixture/projects/jsonl-lens/a91e.jsonl', project: 'jsonl-lens', tier: 'session', sessionUUID: 'a91e55c0', agentId: null, agentName: null, workflowRunId: null, size: 928000, secondsSinceWrite: 140, heat: 'cool' },
]

function demoEvents(path: string): WireEvent[] {
  const project = DEMO_FLEET.find(s => s.path === path)?.project ?? 'session-viewer'
  const rows: Array<[string, string, string]> = [
    ['user', '09:40:01', `Inspect the ${project} session timeline and keep the source boundary visible.`],
    ['assistant', '09:40:04', 'I will read the indexed events first, then stream context from the source file.'],
    ['tool_use', '09:40:06', 'search_sessions · query="timeline" · limit=20'],
    ['tool_result', '09:40:07', '12 hits · trigram route · read-only'],
    ['assistant', '09:40:11', 'The hit is navigable: session id plus sequence number are retained.'],
    ['tool_use', '09:40:14', 'read_context · session=fixture · seq=42 · before=4 · after=6'],
    ['assistant', '09:40:18', 'Context window loaded. Scroll up to inspect earlier history.'],
  ]
  return rows.map(([lineType, time, text], i) => ({ seq: i + 1, lineType, ts: `2026-09-01T${time}.000Z`, text, summary: null, byteOffset: i * 320 }))
}

export function useFleet() {
  const [fleet, setFleet] = useState<WireSession[]>([])
  const [events, setEvents] = useState<WireEvent[]>([])
  const [selected, setSelected] = useState<string | null>(null)
  const [attachedInfo, setAttachedInfo] = useState<string | null>(null)
  /** Byte offset of the OLDEST line currently held. Paging up asks for what precedes it. */
  const [oldestOffset, setOldestOffset] = useState<number | null>(null)
  const [atTop, setAtTop] = useState(false)
  const [loadingHistory, setLoadingHistory] = useState(false)
  const [connected, setConnected] = useState(false)
  const [following, setFollowing] = useState(true)

  const ws = useRef<WebSocket | null>(null)
  // Refs, not state, inside the message handler: reading `following` from state there
  // would capture a stale closure and the Stop button would appear to do nothing.
  const followingRef = useRef(following)
  followingRef.current = following

  useEffect(() => {
    if (PUBLIC_FIXTURE) {
      const path = DEMO_FLEET[0]!.path
      setFleet(DEMO_FLEET)
      setSelected(path)
      setEvents(demoEvents(path))
      setAttachedInfo('fixture stream · 7 synthetic lines')
      setOldestOffset(0)
      setAtTop(true)
      setConnected(true)
      return
    }
    let closed = false
    let retry: number | undefined

    const connect = () => {
      const sock = new WebSocket(WS_URL)
      ws.current = sock
      sock.onopen = () => setConnected(true)
      sock.onclose = () => {
        setConnected(false)
        if (!closed) retry = window.setTimeout(connect, 2000)
      }
      sock.onmessage = (ev: MessageEvent<string>) => {
        const f: WireFrame = JSON.parse(ev.data)
        if (f.kind === 'fleet') {
          if (followingRef.current) setFleet(f.fleet)
        } else if (f.kind === 'events') {
          // Live tail appends. The cap applies to the NEWEST end only — trimming the front
          // here would fight the history the user just scrolled up to load.
          setEvents(prev => [...prev, ...f.events].slice(-(MAX_EVENTS * 6)))
        } else if (f.kind === 'history') {
          // Older page: PREPEND, and remember the new oldest byte so the next page can
          // continue from it.
          setEvents(prev => [...f.events, ...prev])
          setOldestOffset(f.fromOffset)
          setAtTop(f.atTop)
          setLoadingHistory(false)
        } else if (f.kind === 'attached') {
          setAttachedInfo(f.message)
          setOldestOffset(f.fromOffset)
          setAtTop(f.fromOffset <= 0)
        }
      }
    }
    connect()
    return () => { closed = true; window.clearTimeout(retry); ws.current?.close() }
  }, [])

  const attach = useCallback((path: string) => {
    setSelected(path)
    setEvents(PUBLIC_FIXTURE ? demoEvents(path) : []) // never mix two sessions
    setAttachedInfo(null)
    setOldestOffset(null)
    setAtTop(PUBLIC_FIXTURE)
    if (PUBLIC_FIXTURE) setAttachedInfo('fixture stream · 7 synthetic lines')
    else ws.current?.send(JSON.stringify({ cmd: 'attach', path }))
  }, [])

  /** Ask for the page of lines immediately before what we already hold. */
  const loadOlder = useCallback(() => {
    if (!selected || oldestOffset === null || atTop || loadingHistory) return
    if (PUBLIC_FIXTURE) { setAtTop(true); return }
    setLoadingHistory(true)
    ws.current?.send(JSON.stringify({ cmd: 'history', path: selected, before: oldestOffset }))
  }, [selected, oldestOffset, atTop, loadingHistory])

  return {
    fleet, events, selected, attach, attachedInfo, connected, following, setFollowing,
    loadOlder, atTop, loadingHistory,
  }
}

/** Group children under their parent by shared session uuid, in a STABLE order.
 *  Active before idle, then by uuid — never by recency, which reshuffles the list under
 *  the cursor on every 2s tick and makes a row you are reading a moving target. */
export function groupFleet(fleet: WireSession[], filter: string): Group[] {
  const by = new Map<string, Group>()
  for (const s of fleet) {
    let g = by.get(s.sessionUUID)
    if (!g) { g = { uuid: s.sessionUUID, project: s.project, parent: null, kids: [] }; by.set(s.sessionUUID, g) }
    if (s.tier === 'session') g.parent = s
    else g.kids.push(s)
  }

  const q = filter.trim().toLowerCase()
  const hit = (s: WireSession | null) =>
    !!s && (s.project.toLowerCase().includes(q) || s.sessionUUID.toLowerCase().includes(q) ||
            (s.agentName ?? '').toLowerCase().includes(q) || (s.agentId ?? '').toLowerCase().includes(q))

  let out = [...by.values()]
  if (q) {
    out = out.flatMap(g => {
      if (hit(g.parent)) return [g]
      const kids = g.kids.filter(hit)
      return kids.length ? [{ ...g, kids }] : []   // keep the parent for context
    })
  }

  const stale = (g: Group) => (g.parent?.heat ?? g.kids[0]?.heat) === 'cool'
  out.sort((a, b) => Number(stale(a)) - Number(stale(b)) || a.uuid.localeCompare(b.uuid))
  for (const g of out) {
    g.kids.sort((x, y) => (x.agentName ?? x.agentId ?? '').localeCompare(y.agentName ?? y.agentId ?? ''))
  }
  return out
}

export const sizeStr = (b: number) =>
  b < 1e3 ? `${b} B` : b < 1e6 ? `${Math.round(b / 1e3)} KB` : `${(b / 1e6).toFixed(1)} MB`

export const agoStr = (s: number) =>
  s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`
