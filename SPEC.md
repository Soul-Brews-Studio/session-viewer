# session-viewer — spec

A native macOS app to browse, import, and search the Claude Code session corpus at
`~/.claude/projects`.

## Why it exists

The corpus is large and structurally non-obvious. Measured on m5, 2026-08-24:

| tier | path shape | files |
|---|---|---:|
| 1 · session | `<project>/<uuid>.jsonl` | 84 |
| 2 · subagent | `<project>/<uuid>/subagents/<agent>.jsonl` | 191 |
| 3 · workflow agent | `<project>/<uuid>/subagents/workflows/wf_*/agent-*.jsonl` | 700 |
| — · workflow journal | `.../wf_*/journal.jsonl` | 55 (different shape, not a transcript) |
| **total** | | **1030 files · 541 MB** |

**A tool that globs only `<project>/*.jsonl` sees 84 of 1030 files.** `dig.py` does exactly
this today — its `--deep` mode descends one level into `subagents/` but not into
`subagents/workflows/`, so every Workflow-spawned agent transcript is invisible to it.
That silent under-coverage is the specific failure this project exists to avoid, and the
reason tier is a first-class modeled column rather than an implementation detail.

## Non-goals

- **Not a replacement for `jsonl-lens`.** For "who said X and when", its own README's
  argument holds: a live `rg` over the corpus beats an index and has zero staleness.
  `just upstream` delegates to it rather than reimplementing it.
- **Not an archive.** The DB is a rebuildable cache; disk is the source of truth.
- **Not a chat replica.** Rendering a faithful conversation UI is out of scope for v1.

## Data model decisions

**Import identity is `(path, mtime, size)`** — no content hashing. Rehashing 541 MB on
every run to detect changes would dominate runtime for no benefit; session files are
append-only in practice, so size+mtime is a sound change signal.

**The DB is a cache, not an archive.** Sessions *do* get pruned from disk
(`cleanupPeriodDays` defaults to 30; a 27-agent workflow run from 2026-07-12 was already
gone when checked on 08-24 — see `ψ/ralph/jsonl-with--workflows.md`). Consequence: the
index will legitimately contain rows whose files no longer exist. `just diff` reports
these as "in db but no longer on disk" — informational, not corruption.

**Line types are modeled, not collapsed.** A real session carries ~14 distinct `type`
values, not 3. Only ~half are conversational (`user`/`assistant`/`system`); the rest are
session/UI state (`mode`, `permission-mode`, `file-history-snapshot`, `attachment`,
`last-prompt`, `atis-latch`, `ai-title`, `queue-operation`, `pr-link`, `agent-name`,
`file-history-delta`). `session_type_counts` records all of them; `events_fts` indexes
only the conversational ones. A renderer that assumes 3 types silently drops most lines.

**Project paths come from the file's own `cwd` field, never from decoding the directory
name.** The encoded dirname replaces both `/` and `.` with `-`, which is lossy and
ambiguous in both directions.

**Sort columns are a closed enum, never a caller string.** SQLite can bind values but not
identifiers: `ORDER BY ?` sorts every row by the same constant and returns an arbitrary
order *without erroring*. So the session list's sort column and direction must be
interpolated into the SQL text — the only such interpolation in the app. `SessionSort` /
`SortDirection` (`SQL.swift`) are the allow-list that makes it safe: callers pick a case,
each case maps to a hand-written literal column expression, and unrecognized input can only
fail `init(rawValue:)` (verified: `list --sort ';DROP TABLE sessions;--'` exits 2 with the
table intact). Widening these to `String` would be a SQL injection, not a refactor.

**Timestamps render as UTC on a pinned Gregorian calendar.** `started_at` is UTC straight
from the jsonl; a bare `DateFormatter` here inherits the machine's Thai locale and prints
file mtimes as year **2569** in local time, which put two adjacent time columns 7 hours and
543 years apart. `utcStamp` pins `en_US_POSIX` + UTC.

**Parsing is line-streamed and failure-tolerant.** The p99 session file is 39.6 MB;
reading whole files into memory would stall the UI and balloon import memory. Individual
malformed lines are skipped, not fatal — real session files get truncated mid-write.

## Toolchain constraints

- **`sqlite3` must be `/usr/bin/sqlite3`, pinned.** On this machine bare `sqlite3` resolves
  to the Android SDK's build, which has **no FTS5** — `schema.sql` fails there with
  `no such module: fts5`. Verified: android 3.50.6 → error; /usr/bin 3.51.0 → OK.
- **No third-party dependencies.** System SQLite3 + Foundation + SwiftUI + AppKit only,
  matching `neo-oracle`'s `rag.swift`/`ocr.swift` convention. AppKit is named explicitly
  because the app is not a SwiftUI `App`: it drives `NSApplication`/`NSWindow`/
  `NSHostingView` directly (`App.swift`), which is what lets a single SwiftPM executable
  be both a CLI (`diff`/`import`/`list`/`tail`) and a windowed app with no `.xcodeproj`.
  The rule is "nothing third-party", not "nothing but SwiftUI" — an earlier version of
  this line said the latter and was false the day it was written.
- **Invoke the built binary directly, not `swift run <subcommand>`** — `swift run` treats
  its first argument as a *product* name, so `swift run diff` fails rather than passing
  `diff` through.
- **A no-op `swift build` reports success over broken source.** If nothing it tracks changed,
  it prints `Build complete! (0.08s)` without compiling — so a genuinely broken tree keeps
  reporting green. This hid a real breakage: after splitting `Design.swift` into `Type`
  (fixed chrome) and `Content` (user-scalable), five call sites still referenced the removed
  `Type.scale`/`Type.steps`, and several "successful" builds in a row never noticed. A peer
  reviewing the same tree hit `error: input file was modified during the build` and found it.
  **A sub-0.5s "Build complete" is not a verification** — force it with
  `touch Sources/**/*.swift` (or `swift build --force-resolved-versions` / a clean) whenever
  the result matters. Same family as the debug/release trap below: the tool reports success
  while doing something other than what you asked.
- **`swift build` builds DEBUG; `.build/release/` is a different, possibly stale binary.**
  Running `swift build` then executing `.build/release/session-viewer` silently runs old
  code — the build says "Build complete!" and the binary runs fine, it is just not the one
  you compiled. This cost three wrong diagnoses of a "broken" cwd fix that was correct all
  along. Always `swift build -c release` when the release binary is what runs, or compare
  `stat -f '%Sm' .build/debug/... .build/release/...` when behaviour contradicts the source.
  The justfile's `build` recipe uses `-c release` for exactly this reason.

- **Unknown CLI flags are rejected, not ignored.** Third member of the family above. Every
  flag `tail` takes is a *modifier*, so a mistyped one does not disable a feature — it falls
  through to the unmodified default, and `tail`'s default is **follow forever**. Measured:
  `tail --self-test` (real flag: `--selftest`) sat blocked **94 minutes at 0.0% CPU**, which
  reads as a hung app while the app was in fact doing exactly what was asked. `TailOptions.parse`
  now walks argv against an allow-list and exits 2 on anything unrecognized.
  Verified: `tail --self-test` → `unknown flag: --self-test`, exit 2; `tail --selftest` → ALL PASS.
  The shared shape of all three traps: **the tool succeeds at something other than what you
  asked, so nothing fails at the point of the mistake.**

## Concurrency: one file, many readers

Every part of this app reads the same SQLite file at the same time — the live poll, the
tailer, the server, an import, and the Database tab's status read. Two rules follow, and
both were learned from a crash (EXC_BREAKPOINT, 2026-08-25) in which a status read and a
project scan raced on two background queues:

**A busy timeout is set in `DB.init`, not by callers.** It used to be `db.setBusyTimeout()`
at the call site. Eight sites remembered; the two newest did not, and a contended access
returned SQLITE_BUSY immediately. *A safety property each new caller must remember is one
that will eventually be forgotten* — so it moved into the initializer where it cannot be.

**`DB.prepare` returns nil; it does not `fatalError`.** The old reasoning was that every SQL
string here is a compiled constant, so a prepare failure could only be a typo worth crashing
on. That was wrong about *when* prepare fails: SQLITE_BUSY, a schema changed under an open
handle, or a table an older db lacks are all runtime conditions, all recoverable — and the
app killed a window the user was working in over one. Every step/finalize already treats nil
as "no rows", so a failed prepare now degrades to an empty result plus a loud stderr line.
The tradeoff is accepted knowingly: a genuine typo becomes a silent-empty-result instead of
an abort, which is a shape this project has been bitten by — hence the message names the
statement. Losing a result set is recoverable; losing the user's window is not.

**A view's background work runs on its OWN serial queue.** `DBView` dispatched to
`.global(qos:)`, so `refresh()` and `scan()` ran concurrently — and `chooseFolder()` calls
both back to back. Serialising prevents the collision; the busy timeout is still needed for
the writers a private queue cannot serialise against, so both fixes stay.

## The server, and why not a WebView

The recurring question was "do we need a webview toggler?" — meaning: swap the native
renderer for HTML to get CSS control. The answer is no, and the better shape is a server:

    Swift app ──┬── native SwiftUI window   (NSHostingView, unchanged)
                └── `serve` ── WebSocket ──┬── web/index.html   (full CSS, no build step)
                                           └── any other client, incl. another machine

A WebView would have *replaced* the renderer, forfeiting List virtualization over 1000+ rows
and the native feel, to solve a font problem that a token scale already solved. A server
*adds* a client instead: nothing is replaced, the browser gets real CSS, and the stream can
leave the machine — which a WebView never could.

**Zero dependencies, verified before committing to it.** `Network.framework` ships
`NWProtocolWebSocket` and it works on the LISTENER side, not just as a client — checked by
standing up an `NWListener` with a websocket protocol stack on a real port *before* writing
`Serve.swift`. No Vapor, no swift-nio, nothing added to `Package.swift`.

**The server owns no logic.** `liveFiles`/`discoverFiles` decide what is live, `SessionTailer`
does the byte-offset read, `LiveEventRow.summarizeBlocks` names the tool calls — all shared
with the window and the CLI. If the server disagreed with the app about what "live" means,
that would be a second source of truth, which is the bug this whole project exists to avoid.

Wire protocol: one JSON frame per message, tagged with `kind`
(`fleet` | `events` | `attached` | `error`), so a client switches on a field and an added
case cannot break a client that predates it. Commands are `{"cmd":"attach","path":…}` /
`{"cmd":"detach"}`. Attach starts at END of file, matching the window's policy — a live view
starts from now, not by replaying 39 MB down a socket.

Verified end to end with a real WebSocket client: 11 live sessions streamed, recovered agent
names on the wire (`omx-hermes-addon`, `codex-freeze`), and an attach to a 42.2 MB session at
byte 42237070 — the append-only offset seek working over the network.

    just serve      # start it
    just web        # open the UI (separate pane)

## The web client is the one place with dependencies

`webapp/` is React 19 + TypeScript (strict, `noUncheckedIndexedAccess`) + Tailwind v4,
built with Vite/Bun into `web/`. It is the ONLY part of this project with a build step or a
`node_modules`.

That is a deliberate line, not a lapse. The Swift side — server, CLI, native app — stays
zero-dependency because it is the thing that must keep running unattended and survive a
toolchain that moves under it. The web client is disposable by comparison: it renders a
wire format it does not own, holds no state the app needs, and can be deleted without the
app losing a capability. A framework earns its keep there and nowhere else.

Precedent in this fleet: `laris-co/facebook-oracle` already ships React + Tailwind + Vite.

**MIME types are load-bearing in the static server.** A browser REFUSES to execute a module
script served as `text/plain` ("expected a JavaScript MIME type") — the page loads and
renders nothing, with the only clue in the console. `StaticFileServer` maps extensions
explicitly; this was caught by checking the served `Content-Type` header rather than by
opening the page and seeing white.

**Attach backfills, it does not start empty.** Attaching exactly at EOF was right about not
replaying 39 MB down a socket and wrong in the way that matters: the pane stayed blank until
the session next wrote, which on a thinking session is minutes. `tail -f` behaves the same
and nobody uses it bare — they use `tail -n 40 -f`. The server now starts 256 KB before EOF
(a few dozen events; far short of the 39.6 MB p99 file) and pushes that immediately rather
than waiting for the next tick. Verified: 150 rows land the instant you click a session.

## Vectors: per-class sibling files, chat first — and model identity is the safety property

**Vectors live in per-class sibling databases** (`sessions.chat.vec.db`, `sessions.tools.vec.db`),
ATTACHed and UNIONed — not in one table. Two measured facts decided it (2026-08-25, m5):
conversation is 16.8% of the corpus by characters (tool_result alone is 68.4%), and
`semanticSearch` is a brute-force scan whose cost is the bytes it reads — a `role` column
would still read them; a file that is not attached is not read at all.
Consequence: the app builds CHAT ONLY by default (~20 min, not ~5 h); `--classes tools`
exists and is deliberately unbuilt — keyword search already scores 100% recall on tool
output. The legacy in-db `event_vectors` table stays a UNION branch of every read until
dropped (`just drop-legacy-vectors`, guarded), after which the mixed-geometry warning
clears. An 18-agent adversarial pass confirmed 11 defects in the first cut of this split
(commit 5b6155c fixes them) — the durable lesson: every reader (search, eval, coverage,
dump) must derive from the SAME union, or two definitions of "embedded" exist.

## Vectors: one table, many engines — and model identity is the safety property

**A vector is meaningless without the identity of the space it lives in.** Measured on this
machine, the string `the database crashed` embedded by Apple's per-language models:

| pair | cosine |
|---|---:|
| en vs th | **-0.0227** |
| en vs zh-Hans | 0.0791 |

Orthogonal. Not "differently scaled" — different spaces. The first version of
`event_vectors` had no `model` column, and the app shipped **44,387 vectors built by four
models** (`Embedder` routes per chunk across en/th/zh/ja by detected language) with nothing
recording which. `corpusMean` averaged across all four; the query was embedded by whichever
model matched the QUERY's language and scored against chunks from the other three. A 40-event
rebuild on the fixed schema immediately showed `apple-nlce/en/r1/512` × 1137 alongside
`apple-nlce/th/r1/512` × 1 — mixing that had been invisible.

So: **`model` is in the PRIMARY KEY**, and identity is the FULL space —
`provider/language/revision/dimension`. Revision is included because a macOS update can
re-mint assets at the same dimension, and **dimension equality is not model identity**.
Every read binds it: `selectUnembedded` (or a corpus half-built by one model reports complete
for every other), `selectEmbedCoverage` (a `max(dim)` over mixed rows was a number the search
was not using), and `selectVectorsForSearch` (scanning across models is not a wider search,
it is a meaningless one).

**The pluggability seam is a FILE, not a protocol or an HTTP client.** Six independent design
lenses converged on this and three adversarial challengers failed to break it:

    session-viewer embed --dump  |  ssh gpu embed.py  |  session-viewer embed --load --model NAME

Rejected, with reasons: an `EmbeddingProvider` protocol (`Embedder.vector(for:)` has two call
sites — a protocol for two call sites is ceremony); a Swift HTTP client (curl in a script owns
the network, so no `URLSession` and no secrets on argv, where `ps` would expose them); and
`POST /embed` on the existing server — `StaticFileServer` does one 8 KB receive and parses only
the path (`Serve.swift`), so a real endpoint is more new Swift than the entire CLI.

**Cloudflare Workers AI and a local 2×4090 differ only by environment variables in that
script.** Neither reaches into Swift. The `--dump` half also means a remote provider is an
explicit, visible act: session text leaving the machine is a pipe the operator typed, not a
default — and the UI must stop claiming "on-device · no network" once a non-Apple model is
present.

## The remote embed service (bge-m3 on the 4090s) — spec before first vector

Written 2026-08-26, before any non-Apple vector exists, deliberately: `model` is in
`event_vectors`' PRIMARY KEY, so the name minted on first `--load` is permanent — renaming
means re-embedding. Every decision here is cheap now and expensive after.

**Topology.** Producer = this Mac (`embed --dump` / `--load`). Service = **Ollama already
running on the boxes** (`:11434`, `bge-m3` pulled, measured 66–69k chars/s in the 08-18
jsonl-lens pool). Transport = **held SSH tunnel, not a public port**:

    ssh -N -L 11439:localhost:11434 gpu2 &          # remote-hop today; direct once local's key lands
    EMBED_URL='http://localhost:11439/api/embed' EMBED_DIM=1024 EMBED_MODEL=bge-m3 \
      scripts/embed-http.sh

`embed-http.sh` already parses Ollama's `{"embeddings":[[…]]}` shape; the request body needs
the Ollama form (`{"model":…,"input":[…]}`) — the script's one Cloudflare-shaped `-d` line is
the only edit this spec requires. No new Swift, no protocol, no server endpoint (the seam
decision above stands).

**Which box: gpu2.** Live-verified 2026-08-26: gpu1 disk is 96% and runs a 9 GB llama-server;
gpu2 is 35% disk, 2.5 GB VRAM used — and gpu-oracle's standing rule is "prefer gpu2" anyway.
Nothing lands on the box's disk: text streams through the tunnel and vectors stream back;
memory-only on the worker. Known gpu2 quirk (gpu-oracle, 07-11): detached processes over
non-interactive ssh die on disconnect — hold the tunnel with `autossh -M 0 -f -N`, don't
nohup on-box.

**Etiquette.** The cluster is shared, gatekept by gpu-oracle, which exists because three
oracles once dispatched uncoordinated. A full-corpus run gets announced to gpu-oracle's
ψ/inbox first; a smoke test doesn't. Session text leaving the machine is an explicit
operator act (the pipe you typed), and the UI must stop claiming "on-device · no network"
the moment the first bge-m3 vector loads — the `remoteProviders` warning firing is the
guard working, not a bug.

**Model identity: `bge-m3/multi/r1/1024` — ONE multilingual space.** This is the real
divergence from Apple: apple-nlce splits en/th into orthogonal spaces (cosine −0.0227) and
the query router picks by detected language; bge-m3 is a single multilingual space, so BOTH
query languages map to the same model when it's active. `multi` in the name records that
routing difference; `r1` pins the revision — record `ollama show bge-m3 --modelfile` digest
in the run notes, because "bge-m3:latest" is a moving pointer and a silently-updated model
is a corrupted vector space that no query will ever reveal.

**Query-time embedding is the hidden half.** Searching bge-m3 vectors requires embedding the
*query* with bge-m3 too — Apple embeds on-device, but bge-m3 queries need an embedder. m5
has its own ollama (`/usr/local/bin/ollama`, bge-m3 present per haos-oracle's 08-25 probe):
queries embed locally (one vector, latency fine), bulk goes to the 4090. **Unverified
assumption to test before any eval**: that m5-ollama and gpu2-ollama produce the same
vectors for the same text — cosine ≥ 0.999 on a 10-string probe set, else the corpus and
the queries live in subtly different spaces and recall numbers are noise.

**Size of the job, measured**: 112,657 chunks · 39.8 MB text (avg 353 chars) → **~10 min on
one 4090** at the measured pool rate. Small enough to redo; never worth risking a hole.

**Failure modes this system has already met, encoded:**
- A dropped chunk is a *permanent hole* — the event has SOME rows and looks done to
  `--dump` (the script's 3× retry exists for this; verify counts after load:
  loaded == dumped, and `readEmbedCoverage` agrees).
- Dim mismatch fails fast (`EMBED_DIM` is mandatory) — bge-m3 is 1024, not 512.
- The dump/load seam once bypassed the class split and mis-bound non-Apple model names
  (fixed 7d49821/02048ab) — which is why the verification below runs a real search, not
  just counts.
- Stale daemons read zero vectors (08-26 incident): restart any session-viewer MCP daemon
  before judging results, or the run will "look absent".

**Verification ladder (each rung gates the next):**
1. Tunnel up → `curl localhost:11439/api/tags` shows bge-m3. ✅ 2026-08-26 — both boxes,
   same digest `7907646426…` (gpu1 :11435, gpu2 :11439, held tunnels under remote@m5.local).
2. Cross-embedder identity: same 10 strings through m5-ollama and gpu2-ollama, cosine ≥ 0.999.
   ✅ 2026-08-26 — worst 0.999991 over EN/TH/mixed/code strings, dim 1024 both sides.
3. 10-chunk smoke: dump-head → embed → load → count = 10, one `embed --query` returns them.
   ✅ 2026-08-26 — **and it caught a real defect**: `runLoadCLI` still wrote main's legacy
   table while dump anti-joined `vec_chat` (the 13-defect batch fixed dump only). Live
   symptom: two 79-chunk GPU runs, 79 rows, second dump re-emitted identical work — "done"
   underivable, and `drop-legacy-vectors` would have deleted every remote vector. Fixed
   (load now creates+ATTACHes the class file, inserts via `insertEventVector(schema:)`,
   refuses multi-class streams); 79 misplaced rows migrated copy-verify-then-delete;
   171/30 tests green; dump provably advances past loaded work (79 → 12 → next-unembedded
   confirmed). The registry file (`.data/workers.json`) pins both workers + digest.
4. Full chat class on **gpu2 alone, one sequential pipe** (~10 min) → verify by CHUNK
   COUNT, never run status (a BUSY-refused row still stamps `finished_at`); re-dump → 0.
   Decision: no two-box sharding — two concurrent dumps overlap 100% (event-keyed
   anti-join, no ORDER BY/OFFSET) and two loads on one file silently drop on BUSY.
5. **A/B eval in python, same scorer both arms** (`eval/eval_ab.py`): `just eval` is
   structurally blind to bge (Eval.swift pins the Apple model AND `unpackVector` rejects
   1024-float blobs at dim 512), and python-vs-Swift numbers are incomparable — so score
   apple-nlce AND bge with identical centering/dedupe/denominator in one file. English 13
   labeled @50 primary + a Thai↔EN paraphrase arm (same truth ids): the single
   multilingual space is bge's distinct advantage and every existing query is English.
   Trap, verbatim: `eval --generate` once destroyed 12/13 hand-written labeled rows
   (recovered from git, d92cc7a) — never run it against the real queries.jsonl.
6. **VERDICT (2026-08-26, run complete): the model WAS the ceiling — bge-m3 wins.**
   99,562 chunks embedded on gpu2 in 44 min, refused 0, re-dump 0. Same 13 labeled
   queries, same truth, @50 primary:

   | recall@50 | apple-nlce | bge-m3/multi/r1/1024 |
   |---|---:|---:|
   | EN paraphrase | 19.2% (fresh control, reproduces recorded 19%) | **28.2%** (+47% rel) |
   | TH cross-lingual | 7.8% | **27.5%** (3.4×) |

   The deepest result: bge TH ≈ bge EN (27.5 vs 28.2) — one multilingual space erases
   the language penalty entirely. EN@10 is a tie (12.5 vs 13): the win lives in the
   tail. Caveats recorded: apple arms ran in Swift `eval --file` (Apple query vectors
   cannot leave the Embedder), bge arms in `eval/eval_ab.py` mirroring the ranker
   line-for-line; n=13; truth is 25-id topic proxies. Consequence: the deferred Swift
   query-side routing (`--query-vector-file`, dim-from-blob) is now UNBLOCKED — until
   it ships, these 99,653 winning vectors remain unreachable by every consumer.
   Note: the historical "19%@50" names two different runs (n=3 on 78,200 vectors, then
   n=13 on 110,317) — the A/B's own apple arm is the only valid control.

---
DNA lenses: Archaeologist · Mechanic · Skeptic · User · Architect · Minimalist — parallel
subagents, 2026-08-26. Codex consult skipped: no codex team active (`maw peek/locate` empty).

## Deferred: Bun + Drizzle + libSQL — blocker CLEARED, still not scheduled

An alternative ingest layer in TypeScript, agreed as a later step. Viable because libSQL
writes a standard SQLite file that Swift's `SQLite3` can read directly, letting TS own
writes and Swift own reads with `schema.sql` shared.

**The blocking test has now been RUN, and it PASSES** (2026-08-28, `@libsql/client` 0.17.4):

- `CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram')` → succeeds
- `PRAGMA compile_options` → `ENABLE_FTS5=1`
- Thai mid-word match: inserted `กระจกไม่แกล้งเป็นคน`, queried `MATCH '"ระจก"'` → hit
- **Byte-compatibility confirmed**: the file libSQL wrote is readable and queryable by
  stock `/usr/bin/sqlite3`, FTS5 trigram queries included

So the reason this stays deferred is now **"no need"**, not "unknown". Nothing here wants
replication or a remote endpoint, and `bun:sqlite` already works.

**Drizzle specifically is now an anti-recommendation**, measured the same day: `drizzle-kit
generate` emits a plain `CREATE TABLE` where an FTS5 virtual table was declared — the
migration tool is actively wrong for FTS5, not merely unhelpful — and all three
Drizzle-using sibling oracles (`arra-oracle`, `arra-oracle-v3`, `oracle-v2`) already carve
FTS5 out to raw SQL. An ORM that cannot model the interesting half buys nothing here.

Evidence and full lens write-up: `ψ/lab/session-search/SPEC.md` (`## Why not Drizzle`).
