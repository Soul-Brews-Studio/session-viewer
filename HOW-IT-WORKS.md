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

## ψ memory is a separate corpus

The Oracle `ψ/memory` vault is Markdown knowledge (learnings, retrospectives,
traces, and mailbox notes), not the session-viewer database. A fleet indexer such
as [librarian-oracle](https://github.com/Soul-Brews-Studio/librarian-oracle) can
ingest both vault Markdown and JSONL into its own SQLite FTS5 index, with optional
vectors. session-viewer intentionally stays a transcript reader: it reads the
cache it owns and never publishes or bundles private vault contents.

The public Cloudflare Worker is intentionally different: it serves the built
React surface and deterministic fixture endpoints only. It cannot open a local
file, SQLite database, or WebSocket and has only a static `ASSETS` binding.

To reproduce the native screenshot with the included public fixture:

```bash
demo_db="$(mktemp -d)/sessions.db"
/usr/bin/sqlite3 "$demo_db" < schema.sql
.build/release/session-viewer import --root fixtures/native-demo --db "$demo_db"
.build/release/session-viewer --db "$demo_db"
```
