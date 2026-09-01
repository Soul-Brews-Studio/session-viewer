import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { agoStr, groupFleet, sizeStr, useFleet } from './useFleet'
import type { Heat, WireSession } from './types'

const THEMES = [
  ['modern-dark', 'Modern dark'], ['modern-light', 'Modern light'],
  ['classic-term', 'Classic terminal'], ['classic-paper', 'Classic paper'],
] as const

const HEAT_BG: Record<Heat, string> = {
  hot: 'bg-[var(--hot)]', warm: 'bg-[var(--warm)]', cool: 'bg-[var(--cool)]',
}

export function App() {
  const { fleet, events, selected, attach, attachedInfo, connected, following, setFollowing,
          loadOlder, atTop, loadingHistory } = useFleet()
  const [filter, setFilter] = useState('')
  const [scale, setScale] = useState(() => Number(localStorage.getItem('sv.scale') ?? 100))
  const [theme, setTheme] = useState(() =>
    localStorage.getItem('sv.theme') ??
    // First run follows the OS instead of assuming dark: a tool that opens in the wrong
    // scheme at 9am is a tool you squint at before you can use it.
    (matchMedia('(prefers-color-scheme: light)').matches ? 'modern-light' : 'modern-dark'))

  useEffect(() => {
    document.documentElement.style.setProperty('--content', `${(13 * scale) / 100}px`)
    localStorage.setItem('sv.scale', String(scale))
  }, [scale])
  useEffect(() => {
    document.documentElement.dataset.theme = theme
    localStorage.setItem('sv.theme', theme)
  }, [theme])
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return
      if (e.key === '=' || e.key === '+') { e.preventDefault(); setScale(s => Math.min(180, s + 15)) }
      if (e.key === '-') { e.preventDefault(); setScale(s => Math.max(85, s - 15)) }
    }
    addEventListener('keydown', onKey)
    return () => removeEventListener('keydown', onKey)
  }, [])

  const groups = groupFleet(fleet, filter)
  const current = fleet.find(s => s.path === selected) ?? null

  return (
    <div className="grid h-screen" style={{ gridTemplateColumns: 'minmax(340px,30%) 1fr' }}>
      <aside className="flex min-w-0 flex-col border-r border-[var(--line)]">
        <header className="flex flex-none items-center gap-2.5 border-b border-[var(--line)] px-3 py-2.5">
          <span className="font-semibold tracking-tight">LIVE</span>
          <span className="text-xs text-[var(--dim)]">written in the last 5 min</span>
          <span className="flex-1" />
          <Btn onClick={() => setFollowing(f => !f)}>{following ? 'Stop' : 'Start'}</Btn>
        </header>

        <div className="px-3 pb-2.5">
          <input
            type="search" value={filter} onChange={e => setFilter(e.target.value)}
            placeholder="filter — project, session id, agent name"
            className="w-full rounded-[var(--radius)] border border-[var(--line)] bg-[var(--panel)]
                       px-2.5 py-1.5 text-xs text-[var(--fg)] placeholder:text-[var(--faint)]" />
        </div>

        <div className="flex-1 overflow-y-auto pb-5">
          {groups.length === 0 && (
            <p className="mt-24 px-6 text-center text-[var(--faint)]">
              {connected ? 'nothing written in the last 5 minutes' : 'connecting…'}
              <span className="mt-1 block text-xs">
                {connected ? 'normal — sessions write in bursts at turn boundaries' : 'is `just serve` running?'}
              </span>
            </p>
          )}
          {groups.map(g => (
            <section key={g.uuid}>
              {/* The project appears ONCE per group. Repeating it on every row is what made
                  the flat list unreadable — the biggest text was the string every row shared. */}
              <div className="sticky top-0 flex items-baseline gap-2 bg-[var(--bg)] px-3 pt-3 pb-1
                              text-xs font-semibold text-[var(--dim)]">
                <span className="truncate" dir="rtl">{g.project}</span>
                <span className="shrink-0 font-normal text-[var(--faint)]">
                  {g.kids.length ? `${g.kids.length} agent${g.kids.length > 1 ? 's' : ''} · ` : ''}
                  {sizeStr((g.parent?.size ?? 0) + g.kids.reduce((n, k) => n + k.size, 0))}
                </span>
              </div>
              {g.parent && <Row s={g.parent} sel={selected === g.parent.path} onClick={() => attach(g.parent!.path)} />}
              {g.kids.map(k => (
                <Row key={k.path} s={k} child sel={selected === k.path} onClick={() => attach(k.path)} />
              ))}
            </section>
          ))}
        </div>

        <footer className="mono flex-none border-t border-[var(--line)] px-3 py-1.5 text-[11px] text-[var(--faint)]">
          {fleet.length} live · {groups.length} group(s) · {following ? 'following' : 'paused'}
          {!connected && ' · disconnected'}
        </footer>
      </aside>

      <main className="flex min-w-0 flex-col">
        <header className="flex flex-none items-center gap-2.5 border-b border-[var(--line)] px-3.5 py-2.5">
          <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${HEAT_BG[current?.heat ?? 'cool']}`} />
          <span className="truncate font-semibold">{current?.project ?? 'select a live session'}</span>
          <span className="flex-1" />
          <select value={theme} onChange={e => setTheme(e.target.value)} aria-label="Theme"
            className="rounded-[var(--radius)] border border-[var(--line)] bg-[var(--panel)] px-1.5 py-1 text-xs">
            {THEMES.map(([v, label]) => <option key={v} value={v}>{label}</option>)}
          </select>
          <Btn onClick={() => setScale(s => Math.max(85, s - 15))} title="Smaller text (⌘−)">A−</Btn>
          <span className="mono w-11 text-center text-[11px] text-[var(--dim)]">{scale}%</span>
          <Btn onClick={() => setScale(s => Math.min(180, s + 15))} title="Larger text (⌘+)">A+</Btn>
        </header>

        {current && (
          <div className="mono flex-none border-b border-[var(--line)] px-3.5 py-2.5 text-[11px] text-[var(--dim)]">
            <Kv k="session" v={current.sessionUUID} />
            <Kv k="agent" v={current.agentName ?? current.agentId ?? '—'} />
            <Kv k="tier" v={current.tier} />
            <Kv k="size" v={sizeStr(current.size)} />
            <Kv k="tail" v={attachedInfo ?? '…'} />
          </div>
        )}

        <Stream events={events} hasSelection={!!current}
                loadOlder={loadOlder} atTop={atTop} loading={loadingHistory} />
      </main>
    </div>
  )
}

function Btn({ children, ...p }: React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button {...p}
      className="rounded-[var(--radius)] border border-[var(--line)] bg-[var(--panel)] px-2.5 py-1
                 text-xs text-[var(--fg)] hover:border-[var(--faint)] active:brightness-110">
      {children}
    </button>
  )
}

function Kv({ k, v }: { k: string; v: string }) {
  return (
    <div className="grid gap-x-3" style={{ gridTemplateColumns: '62px 1fr' }}>
      <span>{k}</span><b className="break-all font-normal text-[var(--fg)]">{v}</b>
    </div>
  )
}

function Row({ s, child, sel, onClick }: { s: WireSession; child?: boolean; sel: boolean; onClick: () => void }) {
  const named = !!s.agentName
  return (
    <button onClick={onClick} aria-current={sel}
      className={`flex w-full items-start gap-2 border-l-2 py-1.5 pr-3 text-left
                  ${child ? 'pl-8' : 'pl-3'}
                  ${sel ? 'border-l-[var(--accent)] bg-[var(--sel)]' : 'border-l-transparent hover:bg-[var(--hover)]'}`}>
      <span className={`mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full ${HEAT_BG[s.heat]}`} />
      <span className="min-w-0">
        {/* The agent's NAME when it has one — "codex-freeze" identifies a worker,
            "a0dba268cf1507085" does not. Anonymous ones stay mono so the two read apart. */}
        <span className={`block truncate text-[15px] ${named ? 'font-medium' : 'mono text-[var(--dim)]'}`}>
          {named ? s.agentName : (s.agentId?.slice(0, 10) ?? s.sessionUUID.slice(0, 8))}
        </span>
        <span className="mono block text-[11px] text-[var(--faint)]">
          {s.tier} · {sizeStr(s.size)} · {agoStr(s.secondsSinceWrite)} ago
        </span>
      </span>
    </button>
  )
}

function Stream({ events, hasSelection, loadOlder, atTop, loading }: {
  events: ReturnType<typeof useFleet>['events']
  hasSelection: boolean
  loadOlder: () => void
  atTop: boolean
  loading: boolean
}) {
  const box = useRef<HTMLDivElement>(null)
  const stick = useRef(true)
  /** Scroll height captured BEFORE a prepend, so the view can be pinned afterwards. */
  const prevHeight = useRef(0)
  const prevCount = useRef(0)

  useLayoutEffect(() => {
    const el = box.current
    if (!el) return

    const grewAtTop = events.length > prevCount.current && !stick.current
    if (grewAtTop && prevHeight.current) {
      // THE INFINITE-SCROLL-UP FIX. Prepending pushes existing content down by exactly
      // the height of what was added, so without this the view jumps and you lose the
      // line you were reading — the thing you scrolled up to find. Restoring
      // scrollTop by the height delta keeps that line visually still.
      el.scrollTop += el.scrollHeight - prevHeight.current
    } else if (stick.current) {
      el.scrollTop = el.scrollHeight
    }
    prevHeight.current = el.scrollHeight
    prevCount.current = events.length
  }, [events])

  const onScroll = () => {
    const el = box.current
    if (!el) return
    // "Stuck to the bottom" is what decides whether new lines auto-scroll. Scroll up to
    // read and the tail stops yanking you; scroll back down and it resumes.
    stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 120
    if (el.scrollTop < 200 && !atTop && !loading) {
      prevHeight.current = el.scrollHeight   // capture before the prepend lands
      loadOlder()
    }
  }

  if (!hasSelection) {
    return <div className="content-text flex-1 pt-[22vh] text-center text-[var(--faint)]">
      pick a session on the left to tail it
    </div>
  }

  return (
    <div ref={box} onScroll={onScroll} className="flex-1 overflow-y-auto px-3.5 py-3">
      <div className="mono pb-2 text-center text-[11px] text-[var(--faint)]">
        {atTop ? '— start of session —' : loading ? 'loading earlier…' : 'scroll up for earlier history'}
      </div>
      {events.map(e => (
        <div key={`${e.byteOffset}:${e.seq}`} className="mb-2.5">
          <div className="mono flex gap-2 text-[11px]">
            <span className={e.text || e.summary ? 'font-semibold text-[var(--accent)]' : 'text-[var(--faint)]'}>
              {e.lineType}
            </span>
            <span className="text-[var(--faint)]">{(e.ts ?? '').slice(11, 19)}</span>
          </div>
          {/* A tool call is never "no text": it has a name and a target, and both are on
              the wire. Only a genuinely empty line falls through to the muted case. */}
          <div className={`content-text break-words whitespace-pre-wrap
                           ${e.text ? '' : 'mono text-[var(--dim)]'}`}>
            {e.text || e.summary || '· state line'}
          </div>
        </div>
      ))}
    </div>
  )
}
