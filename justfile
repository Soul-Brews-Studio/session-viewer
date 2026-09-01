# session-viewer — browse and index ~/.claude/projects session transcripts.
#
# Reuse note: this deliberately does NOT reimplement what already exists in the fleet.
#   jsonl-lens  (Soul-Brews-Studio/jsonl-lens) — live corpus scan, `just scan`/`just who`,
#               sqlite export. Its README's own argument stands: for "who said X and when",
#               a live rg over the corpus beats an index. See `just upstream` below.
#   dig.py      (~/.claude/skills/dig/scripts/dig.py) — session timeline + gap mining.
#               NOTE: its --deep glob misses the workflow tier entirely (700 agent
#               transcripts + 55 journals of 1030 files on this machine) — see
#               ψ/ralph/jsonl-with--workflows.md. `just stats` shows the real split.

db_path    := justfile_directory() / ".data/sessions.db"
data_dir   := justfile_directory() / ".data"
schema     := justfile_directory() / "schema.sql"
projects   := env_var('HOME') / ".claude/projects"

# Pinned deliberately. On this machine `sqlite3` on PATH resolves to the Android SDK's
# build (platform-tools), which has NO FTS5 — schema.sql's events_fts table fails there
# with "no such module: fts5". macOS's system sqlite3 has it. Verified 2026-08-24:
#   android  3.50.6 -> Error: stepping, no such module: fts5
#   /usr/bin 3.51.0 -> FTS5 OK
sqlite     := "/usr/bin/sqlite3"

# The built binary, invoked directly. NOT `swift run <subcommand>` — swift run treats
# its first argument as a PRODUCT name, so `swift run diff` fails with
# "no executable product named 'diff'" rather than passing diff through as an argument.
bin        := justfile_directory() / ".build/release/session-viewer"

# list available recipes
default:
    @just --list

# ── build ────────────────────────────────────────────────────────────────────

# compile the Swift binary
build:
    swift build -c release --package-path {{ justfile_directory() }}

# run the app (SwiftUI window)
run: build
    {{ bin }} --db {{ db_path }}

# ── data ─────────────────────────────────────────────────────────────────────

# create the local sqlite db from schema.sql (idempotent — safe to re-run)
init-db:
    @mkdir -p {{ parent_directory(db_path) }}
    {{ sqlite }} {{ db_path }} < {{ schema }}
    @echo "✓ db ready: {{ db_path }}"

# every session file ON DISK (no db needed) — sort: tier|size|mtime|path
list sort='mtime':
    @bash {{ justfile_directory() }}/scripts/list.sh {{ projects }} {{ sort }}

# IMPORTED sessions from the db — sort: description|tier|project|events|lines|size|started|mtime, dir: asc|desc
#
# Arguments are POSITIONAL: `just sessions size`, `just sessions size asc`,
# `just sessions events '' session 10`. NOT `just sessions sort=size` — after the recipe
# name just passes `sort=size` through as the literal value, and the binary (correctly)
# rejects it as an unknown sort key.
#
# Leaving dir empty means "this key's natural direction" — biggest/newest first for
# numbers and times, A→Z for text — decided by SessionSort.defaultDirection, not here.
sessions sort='mtime' dir='' tier='all' limit='40': build init-db
    @{{ bin }} list --db {{ db_path }} --sort {{ sort }} --tier {{ tier }} --limit {{ limit }} \
      {{ if dir == '' { '' } else { '--dir ' + dir } }}

# show what an import WOULD do — new / changed / unchanged, nothing written
diff: build init-db
    {{ bin }} diff --db {{ db_path }} --root {{ projects }}

# import new + changed files into the db (safe to re-run; skips unchanged)
import: build init-db
    {{ bin }} import --db {{ db_path }} --root {{ projects }}

# full rebuild — delete the db and re-import everything from scratch
reimport:
    rm -f {{ db_path }} {{ db_path }}-wal {{ db_path }}-shm
    @just init-db import

# ── live fleet (no db needed — reads the filesystem, not the index) ──────────

# Dots: ● ≤30s writing · ◍ ≤2m active · ○ ≤window idle. Measured on a normal afternoon:
# 8-13 live files across all 3 tiers and 3 repos, ~60-190 ms per scan of the whole corpus.

# who is writing RIGHT NOW, machine-wide — headless twin of the app's Live tab
live window='300' repeat='1' interval='2': build
    @{{ bin }} live --db {{ db_path }} --root {{ projects }} \
      --window {{ window }} --repeat {{ repeat }} --interval {{ interval }}

# same as `live`, plus incrementally tail ONE file. Prints offset vs size every tick, so
# "only the delta is read" is visible rather than claimed — verified on a LIVE 32.8 MB
# session: 78 KB read over 30 s, offset always equal to size, never a re-read.
live-attach path window='300' repeat='6' interval='5': build
    @{{ bin }} live --db {{ db_path }} --root {{ projects }} --attach {{ path }} \
      --window {{ window }} --repeat {{ repeat }} --interval {{ interval }}

# Asserts every published update arrives on the MAIN thread — the contract that keeps a
# 39 MB file off the UI. Prints "ALL publishes arrived on the main thread" or a count.

# drive the real LiveFleetModel on a runloop, no window
live-model path='' seconds='15': build
    @{{ bin }} live --run-model --db {{ db_path }} --root {{ projects }} \
      --for {{ seconds }} {{ if path == '' { '' } else { '--attach ' + path } }}

# ── inspect ──────────────────────────────────────────────────────────────────

# real scale of the corpus on this machine, split by the three file tiers
stats:
    @bash {{ justfile_directory() }}/scripts/stats.sh {{ projects }}

# what's in the db right now — per-tier counts, import status, date range
db-stats: init-db
    @{{ sqlite }} -box {{ db_path }} \
      "SELECT file_tier AS tier, import_status AS status, count(*) AS n, \
              sum(file_size)/1000000 AS mb, sum(line_count) AS lines \
       FROM sessions GROUP BY file_tier, import_status ORDER BY tier, status;"

# the import-run log — what was imported when, and how much changed each time
history: init-db
    @{{ sqlite }} -box {{ db_path }} \
      "SELECT id, started_at, finished_at, files_scanned AS scanned, files_new AS new, \
              files_changed AS changed, files_skipped AS skipped, files_failed AS failed \
       FROM import_runs ORDER BY id DESC LIMIT 20;"

# what line types actually appear in the corpus (there are ~14, not 3)
types: init-db
    @{{ sqlite }} -box {{ db_path }} \
      "SELECT line_type, sum(count) AS total, count(DISTINCT session_id) AS in_sessions \
       FROM session_type_counts GROUP BY line_type ORDER BY total DESC;"

# full-text search the imported conversational content
search term: build
    @.build/release/session-viewer search "{{ term }}" --db {{ db_path }} --limit 40

# open the db in the sqlite shell
shell: init-db
    @{{ sqlite }} {{ db_path }}

# ── upstream tools (reuse, don't reinvent) ───────────────────────────────────

# live-scan the corpus via jsonl-lens — no index, no staleness (often the right answer)
upstream *args:
    @just --justfile /workspace/Soul-Brews-Studio/jsonl-lens/justfile {{ args }}

# ── server + web UI ──────────────────────────────────────────────────────────

# run the WebSocket server (the web UI connects to this)
serve port="8779":
    {{ bin }} serve --db {{ db_path }} --root {{ projects }} --port {{ port }}

# open the web UI over HTTP (needs `just serve` running in another pane).
# NOT the file:// path: browsers treat every `file:` URL as a unique opaque origin, so the
# page cannot open a WebSocket at all — it fails with "'file:' URLs are treated as unique
# security origins" and no data ever streams. `just serve` runs an HTTP listener on
# port+1 precisely so the page has a real origin.
web port="8780":
    @open http://127.0.0.1:{{ port }}/

# run the test suite
test:
    swift test --package-path {{ justfile_directory() }}

# ── web app (React + TypeScript + Tailwind) ──────────────────────────────────
#
# The ONLY part of this project with a build step and third-party packages. The Swift
# server, CLI and native app stay zero-dependency; `webapp/` is a client, and clients are
# where a framework earns its keep. Output lands in web/ so `serve` keeps serving one dir.

# install web deps (once)
web-install:
    cd {{ justfile_directory() }}/webapp && bun install

# typecheck + build the React UI into web/
web-build:
    cd {{ justfile_directory() }}/webapp && bun run build

# vite dev server with HMR (still streams from `just serve` on :8779)
web-dev:
    cd {{ justfile_directory() }}/webapp && bun run dev

# --- analysis ---------------------------------------------------------------
# DuckDB is NOT a dependency of this app and is not embedded. It reads our SQLite
# file directly (read-only), so it costs nothing architecturally and can be deleted
# without the app losing a capability.
#
# Measured 2026-08-25 on the real 1039-session db: the same per-project/per-tier
# pivot ran in 6 ms under sqlite3 and 34 ms under duckdb (startup + extension load
# dominates). So this is here for EXPRESSIVENESS — window functions, FILTER,
# PIVOT, list aggregation — not for speed. Reach for it when the query is awkward
# in SQLite, not when it is slow.

# Open an interactive DuckDB shell attached to the index (read-only)
duck:
    duckdb -cmd "LOAD sqlite; ATTACH '{{justfile_directory()}}/.data/sessions.db' AS sv (TYPE sqlite, READ_ONLY); USE sv;"

# One-shot analytical query: just duck-q "SELECT ..."
duck-q QUERY:
    duckdb -c "LOAD sqlite; ATTACH '{{justfile_directory()}}/.data/sessions.db' AS sv (TYPE sqlite, READ_ONLY); USE sv; {{QUERY}}"

# Where does the corpus actually live? Per-project tier pivot, biggest first.
shape:
    @just duck-q "SELECT p.cwd AS project, count(*) FILTER (WHERE s.file_tier='session') AS t1, count(*) FILTER (WHERE s.file_tier='subagent') AS t2, count(*) FILTER (WHERE s.file_tier='workflow_agent') AS t3, round(sum(s.file_size)/1048576.0,1) AS mb, sum(s.event_count) AS events FROM sv.sessions s JOIN sv.projects p ON p.id=s.project_id GROUP BY p.cwd ORDER BY mb DESC LIMIT 15"

# --- eval ------------------------------------------------------------------
# Retrieval measurement. Built before tuning anything, because every knob added
# to search so far changed a number nobody could read.
#
# Two ground-truth modes, and the distinction is the whole point:
#   substring — auto, reproducible, and BIASED toward keyword (a trigram index
#               computes substring containment by definition, so it scores 100%
#               tautologically). A regression check, not a verdict.
#   labeled   — hand-written ids. The only mode that can express a paraphrase
#               whose words never appear, which is what semantic search is for.

# Run the eval set
eval FILE="eval/queries.jsonl":
    .build/release/session-viewer eval --db {{ db_path }} --file {{ FILE }}

# Regenerate the substring starter set. Hand-written `labeled` rows are PRESERVED —
# they are the only fair test of semantic retrieval and are not regenerable.
eval-gen COUNT="12":
    .build/release/session-viewer eval --generate --db {{ db_path }} --out eval/queries.jsonl --count {{ COUNT }}

# --- external embedding providers -------------------------------------------
# The provider seam is a FILE. Cloudflare Workers AI and a local 2x4090 box
# differ only by env vars in scripts/embed-http.sh; nothing in the Swift binary
# knows either exists. `--dump` is also where session text leaves this machine —
# a pipe you typed, not a default.

# Emit chunks needing vectors for MODEL, as JSONL
dump MODEL LIMIT="0":
    @.build/release/session-viewer embed --dump --db {{ db_path }} --model {{ MODEL }} --limit {{ LIMIT }}

# Read vector JSONL on stdin and store it as MODEL (validates length vs dim)
load MODEL:
    @.build/release/session-viewer embed --load --db {{ db_path }} --model {{ MODEL }}

# Drop the legacy in-db vector table — ONLY after the chat class build is complete.
# The guard is the point: every reader unions legacy + class files, so dropping early
# would silently shrink search. Refuses unless the class file covers the chat work list.
drop-legacy-vectors:
    #!/usr/bin/env bash
    set -euo pipefail
    remaining=$({{ bin }} embed --db {{ db_path }} --limit 1 2>/dev/null | grep -c '^done       0 events' || true)
    unfinished=$({{ sqlite }} {{ db_path }} "SELECT count(*) FROM vector_runs WHERE finished_at IS NULL;")
    if [ "$remaining" -ne 1 ]; then
        echo "REFUSED: chat work list is not empty — finish the build first (just build-chat)"; exit 2
    fi
    before=$({{ sqlite }} {{ db_path }} "SELECT count(*) FROM event_vectors;")
    {{ sqlite }} {{ db_path }} "DELETE FROM event_vectors; VACUUM;"
    echo "dropped $before legacy vectors · unfinished-run rows kept as history ($unfinished)"
    {{ sqlite }} -box {{ db_path }} "SELECT count(*) legacy_vectors_now FROM event_vectors;"

# Which spaces does this index hold, and who built them? Vectors live in the legacy table
# AND the per-class sibling files — a report reading only the legacy table goes blind the
# moment a class build starts.
models:
    @{{ sqlite }} -box {{ db_path }} "SELECT 'legacy' home, model, dim, count(*) vectors FROM event_vectors GROUP BY model, dim ORDER BY vectors DESC;"
    @for f in {{ data_dir }}/*.vec.db; do [ -f "$f" ] && {{ sqlite }} -box "$f" "SELECT '$(basename $f)' home, model, dim, count(*) vectors FROM event_vectors GROUP BY model, dim;" || true; done
    @{{ sqlite }} -box {{ db_path }} "SELECT id, model, provider, coalesce(endpoint,'-') endpoint, chunk_words w, chunk_stride s, coalesce(vectors,0) vec, CASE WHEN finished_at IS NULL THEN 'INTERRUPTED' ELSE 'ok' END state FROM vector_runs ORDER BY id DESC LIMIT 10;"

# --- MCP -------------------------------------------------------------------
# session-viewer as an MCP server, protocol 2026-07-28 (modern era: stateless,
# no initialize handshake, every request carries its own version).
#
# stdio, not Streamable HTTP: no port, no Origin validation (a spec MUST against
# DNS rebinding), no auth surface to build. This binary is already a CLI, so the
# subcommand IS the transport.
#
# Register with:
#   claude mcp add --scope user session-viewer -- \
#     {{justfile_directory()}}/.build/release/session-viewer mcp --db {{justfile_directory()}}/.data/sessions.db

# Run the MCP server on stdio (a client normally launches this, not you)
mcp:
    @.build/release/session-viewer mcp --db {{ db_path }}

# Smoke-test the protocol without a client
mcp-test:
    @printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"server/discover"}' \
      '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
      | .build/release/session-viewer mcp --db {{ db_path }} 2>/dev/null | head -2

# The live MCP surface — what is exposed, where it came from, what it costs
tools:
    @.build/release/session-viewer tools --db {{ db_path }}

# What Codex CLI has, without importing it. OMX work is in here too — omx launches
# codex, so an omx run is a codex rollout with a `.omx-worktrees` cwd.
codex ROOT="":
    @.build/release/session-viewer codex {{ if ROOT == "" { "" } else { "--codex-root " + ROOT } }}
