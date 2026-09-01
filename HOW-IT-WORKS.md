# How session-viewer works

The local app is a macOS SwiftPM binary with a rebuildable SQLite cache and a
small HTTP/WebSocket server. It owns the schema, imports JSONL, serves the React
client, and optionally builds Apple on-device embeddings.

1. `just import` recursively discovers session, subagent, and workflow-agent
   JSONL files under the root you choose (the default is `~/.claude/projects`).
2. The importer keys a file by path + mtime + size, records a manifest row, and
   updates normalized session metadata and the two FTS5 indexes (unicode61 and
   trigram). Re-running skips unchanged files.
3. `just serve` binds the local HTTP UI and a loopback WebSocket. The UI receives
   a fleet frame, attaches to one path, then pages transcript history by byte
   offset without mixing sessions.
4. Search results retain session id and sequence cursors so a hit can open exact
   context. The SQLite file is a rebuildable cache, not an archive.
5. Optional embedding is a separate vector run with recorded model/provider
   provenance; it is never required for lexical search.

The public Cloudflare Worker is intentionally different: it serves the built
React surface and deterministic fixture endpoints only. It cannot open a local
file, SQLite database, or WebSocket and has only a static `ASSETS` binding.
