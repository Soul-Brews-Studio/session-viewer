// Mirrors Serve.swift's wire format EXACTLY. If these drift, the UI silently renders
// undefined — so the Swift structs are the source of truth and this file follows them.
export type Heat = 'hot' | 'warm' | 'cool'

export interface WireSession {
  path: string
  project: string
  tier: 'session' | 'subagent' | 'workflow_agent'
  sessionUUID: string
  agentId: string | null
  /** Parsed from the filename in Swift — there is no name field in any transcript. */
  agentName: string | null
  workflowRunId: string | null
  size: number
  secondsSinceWrite: number
  heat: Heat
}

export interface WireEvent {
  seq: number
  lineType: string
  ts: string | null
  /** Conversational text; "" when the line carries only tool/thinking blocks. */
  text: string
  /** Tool name + target, or "thinking…". Present when `text` is empty. */
  summary: string | null
  byteOffset: number
}

export type WireFrame =
  | { kind: 'history'; events: WireEvent[]; path: string; fromOffset: number; atTop: boolean; stamp: string }
  | { kind: 'fleet'; fleet: WireSession[]; stamp: string }
  | { kind: 'events'; events: WireEvent[]; path: string | null; stamp: string }
  | { kind: 'attached'; path: string; message: string; fromOffset: number; stamp: string }
  | { kind: 'error'; message: string; stamp: string }

/** One parent session plus the agents running under it — same grouping as the native app. */
export interface Group {
  uuid: string
  project: string
  parent: WireSession | null
  kids: WireSession[]
}
