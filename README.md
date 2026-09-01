# session-viewer

> Search, tail, and inspect Claude Code session transcripts across parent,
> subagent, and workflow-agent tiers.

**[Open the public static fixture demo](https://session-viewer-fixture-demo.laris.workers.dev/)**

![Session Viewer public demo](docs/session-viewer-demo.gif)

The public demo uses the real React web surface with **five synthetic sessions**
and seven synthetic transcript lines. It has no KV, D1, R2, database,
filesystem access, WebSocket, secrets, telemetry, or persistence. The local
Swift binary remains the full-featured reader and indexer.

## Public demo — every screen

The deployed fixture has one live-fleet screen; the screenshot below is rendered
in this README so it needs no click-through.

![Live session fleet with grouped parent and agent sessions](docs/screenshots/live-fleet.png)

See [docs/public-demo-gallery.md](docs/public-demo-gallery.md) for the capture
notes and [HOW-IT-WORKS.md](HOW-IT-WORKS.md) for the local/server boundary.

---


Search every Claude Code session on this machine — including the 700+ workflow-agent
transcripts a plain glob never sees. Native macOS app, CLI, WebSocket/HTTP server, and MCP
server, in one SwiftPM binary with **zero third-party Swift dependencies**.

```bash
just build && just import && just search "กระจก"
```

That is the whole first run: compile, index `~/.claude/projects`, and search it — in Thai,
which is the case that motivated most of what follows.

---

## Why it exists

Measured on this machine, 2026-08-24:

| tier | path shape | files |
|---|---|---:|
| 1 · session | `<project>/<uuid>.jsonl` | 85 |
| 2 · subagent | `<project>/<uuid>/subagents/<agent>.jsonl` | 200 |
| 3 · workflow agent | `.../subagents/workflows/wf_*/agent-*.jsonl` | 754 |
| **total** | | **1039 files · 567 MB** |

**A tool that globs only `<project>/*.jsonl` sees 85 of 1039 files.** Tier 3 is 73% of the
corpus and is invisible to the obvious approach. That silent under-coverage is the specific
failure this exists to avoid, which is why tier is a modeled column and not an
implementation detail.

## Search — two indexes, because each is blind where the other works

Measured on this corpus, `LIKE` as ground truth:

| query | truth | unicode61 | trigram |
|---|---:|---:|---:|
| ความ | 435 | 5 (1%) | **435 (100%)** |
| กระจก | 4 | **0 (0%)** | **4 (100%)** |
| append *(English)* | 488 | 361 (74%) | **488 (100%)** |

`unicode61` splits on whitespace and Thai does not use it, so `กระจก` — a word from this
repo's own stated principle — was **unfindable**. But trigram cannot match under 3
characters (`9c` → 0 rows), so both ship and the query length picks. Results are ranked by
`bm25`; before that FTS5 returned rowid order, which put the *weakest* hit first.

## Semantic search — measured, and not a replacement

Apple `NLContextualEmbedding`, on-device, opt-in, 512-dim.

| ground truth | keyword @10 | semantic @10 | semantic @50 |
|---|---:|---:|---:|
| substring (n=12) | **100%** | 48% | 32% |
| paraphrase (n=13) | 5% | **16%** | **23%** |

They fail in opposite directions. Keyword wins where the words appear; semantic wins on
paraphrases whose words appear *nowhere* — every paraphrase query in the eval set is
verified to have zero literal matches, or it would just be a substring query in disguise.

Run it yourself: `just eval`.

## Commands

```bash
just build                 # release build
just import                # index ~/.claude/projects   (~30 s, 1039 files)
just search "trigram"      # ranked full-text search
just app                   # the macOS window
just serve                 # WebSocket + HTTP + MCP on one port
just eval                  # retrieval measurement, keyword vs semantic
just models                # which vector spaces the index holds, and who built them
just shape                 # per-project tier breakdown (via DuckDB, read-only)
```

`just --list` has the rest. The index is a **rebuildable cache** — `.data/` is gitignored
and `just import` reconstructs it.

## MCP server — both standard transports

Protocol **`2026-07-28`** (the "modern" era: stateless, no `initialize` handshake, every
request carries its own version).

```bash
# stdio — no port, no auth surface
claude mcp add --scope user session-viewer -- \
  "$PWD/.build/release/session-viewer" mcp --db "$PWD/.data/sessions.db"

# or Streamable HTTP, on the same listener that serves the web UI
just serve
claude mcp add --transport http --scope user session-viewer http://127.0.0.1:8780/mcp
```

The HTTP binding is bound to **loopback** and validates `Origin` — a spec MUST, and not
redundant with the bind: any web page you visit can POST to `127.0.0.1` from your browser,
which is what DNS rebinding is. `GET`/`DELETE` on `/mcp` return `405`.

### Digging, end to end

The loop that makes this useful: **find → read around it**. A search hit alone is a dead
end — 140 characters of snippet tells you a session mentioned something, not what was
decided. So every hit hands back the exact call to open it:

```
search_sessions{query:"กระจก", project:"digger-oracle"}
  [-12.59] assistant 2026-08-24T17:33:00
    …| «กระจก» | 4 | **0** (0%) | **4** |…
    → read_context{session:"c80b8013", seq:4930}

read_context{session:"c80b8013", seq:4930}
  #4930 assistant … the full exchange, with the table and the conclusion
```

`search_sessions` narrows by `project`, `tier`, `since` and `until` — over 1039 sessions an
unfiltered query is usually the wrong tool. `read_session` reads a transcript in order and
tells you how to page on.

**One uuid can have many rows**, and that is the three-tier structure rather than
duplication: measured on one session here, 1 tier-1 transcript + 8 subagent + 65
workflow-agent files all share its uuid. `read_session` resolves to the tier-1 parent and
reports genuine ambiguity by distinct uuid, not by row.

### Seeing the surface

`tools/list` answers *what can I call*. The question you actually have — when a client shows
98 tools from five servers and silently drops some — is *where did each of these come from
and what is it costing me*. Three surfaces answer it, all from one computation:

```bash
just tools                                  # CLI
curl http://127.0.0.1:8780/mcp/surface      # JSON (GET; add ?probe=0 to skip upstreams)
```
…and the **MCP tab** in the app.

```
tools      43 total — 13 built-in · 0 promoted topics · 30 wrapped
context    ~3,167 tokens of tool definitions
budget     43 tools — past Cursor's 40-tool cap and into the range where
           selection accuracy is measurably worse.

  UPSTREAMS
  oracle   stdio  legacy   517 ms   30 tools   /Users/example/.local/bin/bun
```

The budget line is the one that matters, and it names other people's limits rather than
inventing one. The `era` column matters too: a **legacy** upstream needs an `initialize`
handshake, and speaking modern at one gets silence rather than an error.

### Topics, and the promote/demote split

A **topic** is a remembered investigation. It memoizes what it finds *across runs*, which a
one-shot search cannot do, and records `runs`/`last_hits` — so a topic that used to find
things and now finds none tells you the corpus moved or the query rotted.

Every topic is runnable immediately via one stable tool:

```
dig_topic{name:"thai_search"}
```

**Promotion is separate, and deliberately so.** `promote_topic` gives a topic its own
`dig_<name>` tool; `demote_topic` takes it back and keeps everything it captured:

```
tools/list                        → 13 tools · dig_topic
promote_topic{name:"thai_search"} → notifications/tools/list_changed
tools/list                        → 14 tools · dig_topic, dig_thai_search
demote_topic{name:"thai_search"}  → back to 13
```

The split exists because two researched facts are both true. A specifically-named tool
genuinely helps a model choose — AWS's MCP guidance: *"splitting a multi-purpose tool into
several specific tools provides clarity to the model."* And every tool is charged against a
budget shared with every other connected server: accuracy degrades past ~30–50 tools,
Cursor hard-caps at 40 and **silently drops** the rest, and Claude Code has an open bug
dropping tools past position 30 in multi-server setups. This machine already runs ~98 tools
across 5 servers.

So a topic costs nothing until you decide it earns a slot. In the app, the ★ in the Search
tab's Topics panel is the same operation as `promote_topic` — one implementation, so the UI
and MCP can never disagree.

On the spec: the tool set "**MAY** change over time … but **MUST NOT** vary per-connection
or as a side effect of other requests." That sentence comes from
[SEP-2567](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567), whose
purpose is removing protocol sessions so servers run behind a round-robin load balancer, and
whose author defined per-connection state as *"relying on information sent in previous
messages on the connection."* Topics are durable and global — every connection and replica
sees the identical list — so this design satisfies the guarantee the sentence exists to make.

## Building your own higher-order tool

`docs/HIGHER-ORDER-MCP.md` is the recipe — the four-part mechanism, why durable state is the
compliance argument rather than just tidiness, the tool-budget limits that actually decide
the design, and a checklist. It also records where the three shapes differ: *surfacing* a
fixed catalogue is well supported, *wrapping* is common, and *generating* new schemas at
runtime — the interesting one — has SDK support but no SEP behind it.

## Design notes

`SPEC.md` carries the decisions and the traps — each with the error string that identifies
it, because `no such module: fts5` is searchable next year and "be careful with sqlite" is
not. `TODO.md` carries what is verified and what is not; `[x]` there means a command was
run and its real output recorded.

Three traps worth knowing before you change anything:

- **A no-op `swift build` reports success over broken source.** A sub-0.5 s "Build complete"
  is not a verification.
- **`swift build` builds DEBUG**; `.build/release/` may be a different, stale binary.
- **Unknown CLI flags used to be ignored.** `tail --self-test` (real flag: `--selftest`)
  fell through to follow-forever and sat blocked for 94 minutes looking like a hang. Flags
  are now rejected with exit 2.

All three share a shape: *the tool succeeds at something other than what you asked, so
nothing fails at the point of the mistake.*

## Tests

```bash
swift test        # 118 tests, 24 suites
```
