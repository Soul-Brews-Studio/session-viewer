-- session-viewer local index — SQLite
--
-- Design decisions, made explicit because they were argued for in the design review:
--   * source of truth stays ~/.claude/projects/**/*.jsonl on disk — this DB is a
--     rebuildable CACHE + search index, not an archive. If a session is pruned from
--     disk (confirmed to happen — see ψ/ralph/jsonl-with--workflows.md), the DB row
--     for it is stale evidence of "this once existed", not a promise it still does.
--   * import identity is (path, mtime, size) — cheap, no content hashing over 541MB.
--     A file whose mtime+size are unchanged since last import is skipped outright.
--   * three file tiers are modeled explicitly (session / subagent / workflow_agent)
--     because dig.py's own glob bug (one tier invisible) is the exact mistake this
--     schema is designed not to repeat — see file_tier CHECK constraint below.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS projects (
    id            INTEGER PRIMARY KEY,
    dir_name      TEXT UNIQUE NOT NULL,   -- the raw ~/.claude/projects/<this> dirname (encoded, ambiguous — display only)
    cwd           TEXT,                   -- real path, recovered from a session's own `cwd` field, not decoded from dir_name
    first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
    last_seen_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sessions (
    id              INTEGER PRIMARY KEY,
    project_id      INTEGER NOT NULL REFERENCES projects(id),
    session_uuid    TEXT NOT NULL,             -- from filename or sessionId field
    file_path       TEXT UNIQUE NOT NULL,       -- absolute path, the import-diff key
    file_tier       TEXT NOT NULL CHECK (file_tier IN ('session','subagent','workflow_agent')),
    workflow_run_id TEXT,                       -- wf_<runid>, only set for file_tier='workflow_agent'
    agent_id        TEXT,                       -- only set for subagent/workflow_agent tiers
    parent_session_id INTEGER REFERENCES sessions(id),  -- the owning top-level session, if resolvable

    -- which agent wrote the transcript: 'claude' (~/.claude/projects) or 'codex'
    -- (~/.codex/sessions). A Codex rollout is a top-level session — not a fourth Claude
    -- tier — so it takes file_tier='session' and is told apart by this column instead.
    -- Also added by ALTER for databases created before it existed (SQL.addSessionSourceColumn):
    -- the two must stay in step, because every session query selects it.
    source          TEXT NOT NULL DEFAULT 'claude',

    -- import-diff tracking (see design note above)
    file_mtime      INTEGER NOT NULL,           -- unix epoch, from stat
    file_size       INTEGER NOT NULL,           -- bytes, from stat
    imported_at     TEXT,                       -- NULL until first successful import
    import_status   TEXT NOT NULL DEFAULT 'pending' CHECK (import_status IN ('pending','imported','failed','stale')),
    import_error    TEXT,                       -- last error message, if import_status='failed'

    -- summary metadata, filled on import (the "length" feature)
    line_count      INTEGER,
    event_count     INTEGER,                    -- count of type='user'|'assistant'|'system' only
    started_at      TEXT,                        -- timestamp of first parseable line
    ended_at        TEXT,                        -- timestamp of last parseable line
    description     TEXT                        -- short human summary — first user message, truncated; editable later
);

CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id);
CREATE INDEX IF NOT EXISTS idx_sessions_tier ON sessions(file_tier);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(import_status);
CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id);

-- Per-line-type counts per session — answers "what's actually in here" without
-- re-parsing the file, and surfaces the 14-type reality (dig #193's finding) instead
-- of collapsing everything to "message".
CREATE TABLE IF NOT EXISTS session_type_counts (
    session_id  INTEGER NOT NULL REFERENCES sessions(id),
    line_type   TEXT NOT NULL,
    count       INTEGER NOT NULL,
    PRIMARY KEY (session_id, line_type)
);

-- Full-text index — built only over conversational content (user/assistant/system
-- text), not the UI/session-state event types. FTS5, matching this fleet's own
-- default elsewhere (librarian-oracle, jsonl-lens) rather than inventing a new engine.
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
    session_id UNINDEXED,
    seq UNINDEXED,        -- line number within the file, for jump-to
    role UNINDEXED,        -- user / assistant / system
    ts UNINDEXED,
    text
);

-- SECOND full-text index, trigram tokenizer, over the SAME text as events_fts.
--
-- Not a replacement — a companion, because each one fails where the other works and the
-- failures were MEASURED on this corpus (19,376 indexed rows, 2,331 of them containing
-- Thai — 12%):
--
--   query        ground truth   unicode61      trigram
--   ความ                  435       5  (1%)    435 (100%)
--   หลักฐาน               168      67 (40%)    168 (100%)
--   ทดสอบ                 145      18 (12%)    145 (100%)
--   กระจก                   4       0  (0%)      4 (100%)
--   append (EN)           488     361 (74%)    488 (100%)
--
-- unicode61 splits on whitespace, and Thai does not use it — so a Thai query matches only
-- when the writer happened to leave a space at both ends of the phrase. `กระจก`, a word
-- from this repo's own stated principle, was unfindable.
--
-- Trigram is not free and not universally better:
--   * the index is 1.79x larger (100.5 MB vs 56.2 MB measured on the same rows)
--   * it CANNOT match a query shorter than 3 characters — `9c` returns zero, which is
--     exactly the bug that made search look broken once already
--   * a prefix wildcard over-matches badly on it (`"work"*` -> 4527 rows against a truth
--     of 771)
--
-- Hence both, routed by query length in `searchEvents`. The db is a rebuildable cache, so
-- paying disk for correctness on 12% of the corpus is the cheap side of this trade.
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts_tri USING fts5(
    session_id UNINDEXED,
    seq UNINDEXED,
    role UNINDEXED,
    ts UNINDEXED,
    text,
    tokenize='trigram'
);

-- One row per VECTOR build: which model, which provider, what chunk geometry, and whether
-- it finished. Same shape and same reasoning as import_runs below — a row with
-- finished_at IS NULL is a build that never completed, and is surfaced as interrupted
-- rather than hidden, because a crashed build is exactly the state you want to see when
-- the index looks wrong.
--
-- It exists because provenance was previously unfalsifiable: the UI hardcoded
-- "on-device · no network" and the only evidence in the db was max(dim) over possibly-mixed
-- rows. Once a remote engine can write vectors, that sentence is not stale — it is wrong
-- about whether the corpus left this machine.
CREATE TABLE IF NOT EXISTS vector_runs (
    id            INTEGER PRIMARY KEY,
    model         TEXT NOT NULL,          -- provider/language/revision/dim — the full space
    provider      TEXT NOT NULL,          -- 'apple' | 'cloudflare' | 'gpu' | …
    endpoint      TEXT,                   -- NULL means nothing left this machine
    chunk_words   INTEGER NOT NULL,
    chunk_stride  INTEGER NOT NULL,
    started_at    TEXT NOT NULL DEFAULT (datetime('now')),
    finished_at   TEXT,
    events        INTEGER,
    vectors       INTEGER,
    skipped       INTEGER,
    stopped       INTEGER NOT NULL DEFAULT 0   -- 1 = user pressed Stop, progress kept
);

-- One row per import run, so "what was imported, when, how much" (the diff feature)
-- has its own durable log instead of being inferred from sessions.imported_at alone.
-- Per-file tail offset for LIVE follow (Tail.swift). Exists because session .jsonl files
-- are append-only — verified 2026-08-24: a file's head md5 stayed
-- bda4e46c5b650d5e302f61b4959e8d19 while it grew 3825889 -> 3850991 bytes. So a follower
-- only ever needs the bytes after byte_offset; persisting that offset means a restart
-- resumes instead of re-reading (the p99 file here is 39.6 MB).
--
-- A TABLE, not a column on sessions, deliberately:
--   * MIGRATION: SQLite has no `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so a new
--     sessions column would make re-running this file against an existing db fail with
--     "duplicate column name". CREATE TABLE IF NOT EXISTS is idempotent, so the EXISTING
--     .data/sessions.db (created before this table) picks it up from a plain `just
--     init-db` with no reimport. `session-viewer tail` also runs this same DDL at open
--     time (SQL.createTailState) so it self-heals a db nobody re-inited.
--   * The tailer sees files with no sessions row at all — a workflow agent transcript
--     created seconds ago has never been imported. Keyed by file_path, not session id.
--   * Follow bookkeeping is not import state; wiping the index need not wipe it.
-- NOT NULL-free on purpose for last_line_at/file_mtime: a live file may have produced no
-- parseable timestamp yet.
CREATE TABLE IF NOT EXISTS session_tail_state (
    file_path     TEXT PRIMARY KEY,          -- absolute path, same key as sessions.file_path
    byte_offset   INTEGER NOT NULL DEFAULT 0, -- bytes consumed; always ON a line boundary
    file_size     INTEGER NOT NULL DEFAULT 0, -- size at last read (byte_offset < size ⇒ partial tail held back)
    file_mtime    INTEGER,
    lines_seen    INTEGER NOT NULL DEFAULT 0,
    last_line_at  TEXT,                       -- `timestamp` of the last complete line seen
    updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS import_runs (
    id              INTEGER PRIMARY KEY,
    started_at      TEXT NOT NULL DEFAULT (datetime('now')),
    finished_at     TEXT,
    files_scanned   INTEGER,
    files_new       INTEGER,
    files_changed   INTEGER,
    files_skipped   INTEGER,
    files_failed    INTEGER
);
