# session-viewer — todo

Status as of 2026-08-26. `[x]` means verified by running it, not by assuming.
Tracking: TODO.md only. Current sprint: bge-m3 GPU run + A/B eval (6-DNA-planned, see SPEC provenance).

Buckets are commitment levels, and they had drifted: six done items were sitting in
`## Now`, three more in `## Next`, and four entries were stale — a `(superseded)`
duplicate plus three original-sprint items that also appeared, verified, in the workflow
section above. Re-bucketed 2026-08-25. Deferred items stayed in Deferred: a deferral is a
recorded decision, not backlog, and hoisting it to `## Now` loses that.

## Done — verified

- [x] Chat class build — 31,582 events → 110,317 vectors, 0 skipped, 2375 s (~40 min).
      Verified: `done 31582 events → 110317 vectors` in the run log; class file holds
      31,611 events / 110,417 vectors (incl. the 29-event test seed).

- [x] Eval หลัง build (Q6). Verified: `just eval` — clean post-drop state:
      substring kw 100%@10 / sem 60%@10 · labeled kw 3%@10 / sem 14%@10, 19%@50.
      Semantic beats keyword 4-5× on paraphrase, loses everywhere else — exactly the
      division of labour the panel's honest note describes.
      Surprise: correct geometry lifted substring sem 48% → 60-61%@10, but paraphrase
      moved only 16% → 19%@50 — geometry was not the paraphrase bottleneck.

- [x] Drop legacy vectors (Q1). Verified: `just drop-legacy-vectors` → "dropped 207956
      legacy vectors"; guard held until the work list was empty. Search 1044 ms → 438 ms
      (2.4×); sessions.db 2.56 GB → 2.0 GB; mixed-geometry warning now gates on
      `legacyVectors > 0` (run history alone could never clear) and is gone.

- [x] Whitespace collapse (Q5) — embed path only, FTS untouched (`chunkText`).
      Verified: swift test 155 green; ChunkCapTests fixtures unaffected.

- [x] Invariant test แทน factory (Q4) — `fullMCPToolList` เหลือ derivation เดียว,
      CLI surface ย้ายเข้า core (CLISurface.swift), SurfaceInvariantTests 6 ข้อ.
      Verified: `swift test` → 155 tests / 29 suites. Residue stated in the test header:
      the dispatch switch itself stays untestable until the registry.

- [x] Codex subagent tier ใน index (Q3). Verified: codex import → "retiered 568 existing
      row(s)"; `SELECT file_tier, count(*)` → 59 session / 568 subagent (569/627 parented).
      Rule = thread_source, not parent-presence — forks stay top-level.

- [x] `schema.sql` — projects / sessions / session_type_counts / events_fts / import_runs.
      Verified: `just init-db` creates all tables incl. FTS5 shadow tables.

- [x] Three-tier file discovery (`Ingest.swift`).
      Verified: `just diff` → `scanned 975 files` = 84 + 191 + 700, journals correctly excluded.

- [x] Import-diff on `(path, mtime, size)`.
      Verified: first run reports `new 975 (496 MB), changed 0, unchanged 0`.

- [x] Line-streamed jsonl parser, per-type counting, FTS extraction (`Store.swift`).
      Verified: isolated repro of the slicing logic against a real 3.8 MB session →
      `lines parsed: 554`, `cwd: /opt/Code/.../digger-oracle` extracted correctly.

- [x] `justfile` — build/run/init-db/list/diff/import/reimport/stats/db-stats/history/types/search/shell/upstream.
      Verified: `just --list` parses, `just stats` and `just diff` run clean.

- [x] `sqlite3` pinned to `/usr/bin/sqlite3` after finding the Android SDK build lacks FTS5.
      Verified: android 3.50.6 → `Error: stepping, no such module: fts5`;
      /usr/bin 3.51.0 → `FTS5 OK`. Both run directly.

- [x] Binary invoked directly after `swift run diff` failed on product-name resolution.
      Verified: `just diff` with `swift run` → `error: no executable product named 'diff'`;
      same recipe via `.build/release/session-viewer` → `scanned 975 files`.

- [x] SwiftUI window skeleton (`App.swift`) — list, tier filter, search box, detail pane.
      Verified: compiles clean.

- [x] `SQL.swift` — every statement extracted to a caseless `enum SQL` of constants.
      Decision held: **not** a query builder/factory. Fixed literals + bound params mean a
      builder would hide the SQL from schema review for no gain.
      Verified: `swift build` green; adversarial verifier confirmed pure refactor via
      `git diff` (no behaviour change) and `just diff` still `scanned 975 files`.

- [x] Ingest hardening — real failure path (`return false` + `import_error` recorded +
      `import_status='failed'`), every statement finalized on all paths.
      Was previously dead code: `importFile` unconditionally returned `true`.
      Verified: `rg -n 'return false|failure =' Store.swift` → 4 real failure returns and
      6 distinct error-recording branches where there were previously none.

- [x] SwiftUI pass — background Import button, per-line-type breakdown in detail pane,
      clickable search results.
      Verified: `swift build -c release` green (clean rebuild, not cache).

- [x] **`projects.cwd` now populated from the file's own `cwd` field.**
      Was hardcoded `nil`, silently violating this project's own SPEC — every project
      displayed its lossy encoded dirname. Found by the workflow's survey lens but missed
      by all three verifiers, because no implement task owned it (a scoping error in the
      workflow, not a verifier failure).
      Verified: 38/38 projects populated, real paths recovered.

- [x] Full real import: **1003 files, 0 failed.** (Grew from 975 during this session —
      the workflows themselves spawned new agent transcripts.)
      Verified: `.build/release/session-viewer import` → `import run 1: 1003 new, 0 changed,
      0 skipped, 0 failed`; db then reports 999+ session rows, 38/38 projects with real cwd.

- [x] **Sortable session list — 8 keys, allow-list enforced, one code path for UI and CLI.**
      `ORDER BY` is the one thing in this app SQLite cannot bind, so the column is
      interpolated; `SessionSort`/`SortDirection` (SQL.swift) are closed enums and are the
      only reason that is safe. `fetchSessions` takes the enums, never a String. New
      `list` subcommand + `just sessions <sort> [dir] [tier] [limit]`; clickable column
      headers in the app (click to sort, click again to reverse, ▲/▼ on the active column).
      Verified: all 8 keys run against the real 1003-row db —
      `list --sort size` → 39789/32517/32222 KB descending, `--dir asc` → 0/0/0 ascending,
      `--sort events`, `lines`, `started`, `tier`, `project`, `description` all ordered.
      Injection rejected, not executed: `list --sort ';DROP TABLE sessions;--'` →
      `unknown --sort: … (want: description|tier|project|events|lines|size|started|mtime)`,
      exit 2, and `select count(*) from sessions` still returns 1003 afterwards.
      Two real bugs found by running it, both fixed: `DateFormatter` printed file mtimes as
      **2569**-08-24 (default locale here is Thai → Buddhist era; now pinned to
      `en_US_POSIX`), and it rendered them in local time next to a UTC `started_at`, putting
      two adjacent time columns 7 hours apart (now both UTC).
      Not verified by running: the SwiftUI header layout — it compiles and drives the same
      `fetchSessions` the CLI proves, but the window opens on its own Space behind a
      fullscreen terminal, so it was not screenshotted.

- [x] **Explicit Start/Stop for live following, and `tail -f`-style streaming.**
      Following is now a thing the user turns on and off, not a background poll that
      cannot be paused. `wantsFollow` holds the user's intent separately from tab
      visibility: visibility may SUSPEND following, never resume it — without that,
      pressing Stop and switching tabs silently restarted the poll.

- [x] **Tool calls render their name and target instead of "no text".**
      The placeholder `· no text (tool call or result)` was discarding the single most
      useful field on the most common line in a transcript. `tool_use` carries `name` +
      `input`; `tool_result` carries `is_error` — both were already in `TailEvent.raw`.
      One summarizer (`LiveEventRow.summarizeBlocks`) is shared by the window AND the CLI
      `tail`, so running the CLI is a real test of the GUI's rendering — the CLI had the
      identical bug in a second renderer, found only by running it.
      Verified live: `WebFetch · https://…/INDANCSClient`, `Bash · cd /private/tmp/…`,
      `→ result`, where all three printed blank 10 minutes earlier.

- [x] **`thinking` blocks no longer render as empty rows.**
      Measured over 408 real content blocks: tool_use 140, tool_result 139, **thinking 75
      (18%)**, text 54. Renders `thinking…`; the preview is usually absent because the
      stored `thinking` string is empty (len=0) with only an opaque `signature` — content
      is stripped at write time, not lost by the parser. Recorded in-code so the
      impossible preview is not "fixed" later.
      Verified: `swift build -c release` green, discovery unregressed at
      `scanned 1020 files / new 17 / changed 9 / unchanged 994` (incremental path working
      on live files, including this session).

- [x] **Freeze fixed — measured twice, two distinct causes.**
      (a) `foldStateRuns(model.events)` ran INLINE in a ForEach, so a fresh `[TailItem]`
      array was allocated on every body evaluation. Codex's mechanism is the better one:
      a new array VALUE defeats LazyVStack's prefetch/placement cache diffing, so it tears
      down and rebuilds that cache on unrelated re-renders (hover, typing, animation), not
      just on the 2s tick — that is why it goes runaway rather than merely slow.
      Cached as `LiveFleetModel.foldedEvents`/`.groups`, published once per data change.
      (b) An ANIMATED `scrollTo` over a 500-row LazyVStack re-laid-out the whole stack every
      frame, and events arrive faster than the 0.15s animation on a busy session, so the
      animations overlapped and layout never settled. A tail should snap; `tail -f` does not
      ease. Also trimmed retained rows 500 → 150.
      Verified by `sample` on the live process: BEFORE 99.5% CPU / 3.39 GB RSS with
      ViewList(224)/LazyLayout(213) hot on the main thread; AFTER 1.3–16.9% CPU, RSS flat at
      0.17 GB across 40s while attached to a busy session.
      My UserDefaults-per-font hypothesis was REFUTED — zero frames in the sample.

- [x] **Text size split into CONTENT vs CHROME.** ⌘+/⌘− scales only what you read
      (transcript, tool summaries, descriptions); buttons, column headers and legends stay
      at native macOS sizes. Scaling chrome made the toolbar lurch and solved nothing.

- [x] **Text-size change no longer destroys state.** `.id(uiScale)` on the root forced a
      whole-tree rebuild, which discards every `@State` it contains — resizing wiped the
      selected session and emptied the detail pane. Replaced with `@AppStorage` observed in
      each view: same re-render, stable view identity, selection/filter/expansion survive.
      Verified: selection held through a resize to 180%.

- [x] **Parent sessions are selectable.** They were rendered as a List `Section` header,
      which takes no `.tag()` — List selection could neither highlight nor report them, so
      clicking a parent looked dead while children worked. Parent is now a real row.

- [x] **Agent NAMES recovered from filenames.** No name field exists in any transcript
      (checked 193 files). The name is in the path: `agent-a<name>-<hex>`. Handles BOTH
      encodings — discovery strips `agent-` for workflow agents but not for subagents, and
      handling only one produced the visible `gent-aomx-hermes-addon` bug.
      Verified: `codex-freeze`, `omx-hermes-addon`, `rsrch-feasibility`; unnamed → nil.

- [x] **Search prefix matching.** A quoted FTS5 phrase matches only WHOLE tokens, so typing
      `9c` to find `9cda6f37` returned zero results and looked broken while working as
      written. Last token is now a prefix (`"9c"*`). Verified: `9c` 0 → 3 hits.

- [x] **Expandable tail rows.** `→ result` rendered three characters while the line behind
      it held the real command output (measured 750 chars of `git status` in one line).
      Click a row for the full tool input, full result body, or full reasoning.

- [x] **Package restructured for testability**: `SessionViewerCore` library + thin
      executable + `Tests/SessionViewerCoreTests`. A SwiftPM executableTarget cannot be
      imported by a testTarget, so logic in the executable is permanently untestable.
      Verified: `swift build` green, `swift test` runs.

> [!warning] This file failed its own standard, twice
> An independent judge found 3 `[x]` items with no `Verified:` line; a correct block-aware
> re-count found **7 of 13**, and 4 of those were added by the same session that wrote the
> "`[x]` means verified by running it" rule at the top. Writing the standard is not the same
> as meeting it, and the first count of the violation was itself wrong (a line-adjacent
> `awk` check missed multi-line items — the same class of measurement error the standard
> exists to catch). Both were fixed by supplying the real commands and outputs, which
> already existed in the session — they had simply never been written down.

- [x] **13 labeled eval queries, and the picture inverts.**
      Each paraphrase is hand-written and verified `leak = 0` — it appears NOWHERE literally,
      so keyword cannot reach it by substring. One candidate was rejected for having only a
      single truth session.

      | ground truth | kw@10 | kw@50 | sem@10 | sem@50 |
      |---|---:|---:|---:|---:|
      | substring (n=12) | **100%** | **100%** | 48% | 32% |
      | paraphrase (n=13) | 5% | 4% | **16%** | **23%** |

      สมมติฐาน: the two engines fail in opposite directions → **HELD.** Semantic is 3–6×
      keyword on paraphrase, with MRR 1.00 on two queries (top result relevant); keyword is
      100% where truth is defined by substring, which it computes by definition.
      They are complementary, not competing — which is why both indexes ship.
      Limitation, stated rather than buried: the truth SET is derived from a hand-chosen
      keyword clause — a topic proxy, not per-document relevance judgement. Weaker than
      full hand-labelling, and recorded in the query file itself.

- [x] **Search log.** `search_log` records every query, which INDEX answered, hit count,
      latency, top score and score spread. Written by both the Search tab and the CLI, so
      there is one history rather than two.
      Two derived flags, because neither is visible from a hit count: **EMPTY** (returned
      nothing — the row you most want to find again, and whose wording you forget) and
      **FLAT** (all scores within 5%, so the engine could not rank what it returned — the
      exact signal that exposed the semantic ranking failure, now reviewable after the fact).
      History panel in the Search tab is clickable to re-run. CLI: `session-viewer searches`.
      Verified: 4 searches logged → `zzzznotfound` EMPTY, `the` FLAT, `crash`/`กระจก` clean.

- [x] **Vectors carry model identity.** `model` added to `event_vectors` and to its PK;
      `selectUnembedded` / `selectEmbedCoverage` / `selectVectorsForSearch` all bind it.
      สมมติฐาน: the four Apple per-language models are different vector spaces, so the shipped
      index was silently mixed → คาดหวัง: a rebuild shows more than one model in one table.
      Verified: pair test on identical text — `en vs th cos = -0.0227`, `en vs zh = 0.0791`
      (orthogonal, not merely rescaled). A 40-event rebuild then reported
      `apple-nlce/en/r1/512 → 1137` and `apple-nlce/th/r1/512 → 1` in the same table.
      Surprise: this was found by an adversarial challenger reading code written an hour
      earlier in the same session, not by the tests — and it plausibly contributes to the
      measured 2/8 recall.

- [x] **`session-viewer eval` — recall@10/@50 and MRR, keyword vs semantic, one table.**
      Two ground-truth modes, and the distinction is the point: `substring` is auto and
      reproducible but BIASED — a trigram index computes substring containment by
      definition, so its 100% is tautological, not a win. `labeled` carries hand-written
      ids and is the only mode that can express a paraphrase whose words never appear.
      Every row also reports `emb` (relevant ∩ embedded) so a low semantic score cannot be
      misread as bad ranking when it is really missing coverage — the exact mistake made
      earlier with a Thai query whose relevant chunks were simply not in the index.
      Verified: `just eval` → substring n=12 keyword @10 100% @50 100%, semantic @10 31%
      @50 28%.
      Surprise: the eval caught TWO bugs in itself on first run. It printed recall of 109%,
      155% and **529%** — arithmetically impossible, caused by counting duplicate session
      ids against a de-duplicated denominator. Then recall@50 came out BELOW recall@10,
      which is also impossible, because a 50-row fetch collapses to far fewer unique
      sessions; fixed by retrieving 400 and scoring shallow. An instrument whose errors are
      invisible would have been worse than no instrument.

- [x] **The fair test ran. Semantic finds what keyword structurally cannot — barely.**
      Rebuild finished: 19,266 events → 78,200 vectors, **27.9 min, 154.3 MB, 0 failed**
      (projected 29 min / 199 MB; the old C=20/S=10 geometry projected ~100 min / ~918 MB).

      | ground truth | keyword @10 | keyword @50 | semantic @10 | semantic @50 |
      |---|---:|---:|---:|---:|
      | substring (n=12, biased to keyword) | 100% | 100% | 48% | 32% |
      | **labeled (n=3, the fair test)** | **0%** | **0%** | **0%** | **19%** |

      สมมติฐาน: paraphrases with a verified literal-match leak of 0 are unreachable by
      keyword and reachable by semantic → **HELD, weakly.** Keyword is exactly 0% at both
      depths — structurally blind, as predicted. Semantic reaches 19% @50 but 0% @10, with
      MRR 0.01–0.06: it finds some of them and ranks them far down. Per-row: 50%, 8%, 0%.
      Chunking C=100/S=50 also lifted substring semantic 31% → 48% @10.

      What this does and does not license: semantic retrieval is doing something real that
      keyword cannot do at all, and it is not yet good enough to lead a result page.
      **n=3 is far too small to generalise** — the honest next step is more labeled rows,
      not a conclusion.
      Surprise: this row read `emb 0` and scored 0% for a while AFTER the index covered
      those sessions. `embeddedSubset` keyed on "session:seq" while labeled truth is
      session-level, so the intersection was always empty — and the eval's own coverage
      warning fired and made the bug look like an explanation. A measurement that explains
      away its own defect is the dangerous kind.

- [x] **Unknown flags rejected CLI-wide.** `flag()` returned its default for anything it did
      not find, so a typo was never an error — it was a silent fallback to default
      behaviour. Landed in the same pass as six new flags (`--chunk-words`, `--chunk-stride`,
      `--file`, `--generate`, `--out`, `--count`), which is what made it urgent:
      `embed --chunk-word 100` would have silently rebuilt the whole corpus at the default
      geometry, a ~30-minute mistake with no error where the mistake was made.
      Verified: `embed --chunk-word 100` → `unknown flag: --chunk-word`, exit 2;
      `eval --db … --file …` → exit 0; 118 tests still pass.
      Surprise: `--model` is already boolean (`live --model`) but the planned
      `embed --load --model NAME` wants it valued, and a flag cannot be both — recorded
      in-code so the collision is found before it ships, not after.

- [x] **`vector_runs` provenance table.** A deliberate copy of `import_runs`, including its
      best property: `finished_at IS NULL` means a build that never completed, surfaced as
      interrupted rather than hidden. Records model, provider, endpoint, chunk geometry,
      counts, and whether Stop was pressed. The row opens BEFORE any work, so a crash leaves
      evidence instead of nothing.
      The UI's hardcoded "on-device · no network" is now read from it: a non-`apple`
      provider flips it to an orange "text left this machine" warning. That sentence was not
      merely stale — once a remote engine can write vectors it is FALSE about whether the
      corpus left the machine, which is the one thing an operator must be able to trust.
      Verified: bounded build on a copy → `id 1 | apple | w 100 | s 50 | ok`.
      Surprise: the SQL `LIMIT` is applied before the `minLength` filter, so `--limit 8`
      reported "0 events" — documented in-code so the zero is not read as a broken build.

- [x] **FTS tokenizer decided — BOTH, routed by query length.**
      Re-measured on THIS corpus rather than trusting the borrowed 18%/100% figure
      (19,376 indexed rows, 2,331 containing Thai = 12%), with `LIKE` as ground truth:

      | query | truth | unicode61 | trigram |
      |---|---:|---:|---:|
      | ความ | 435 | 5 (1%) | 435 (100%) |
      | หลักฐาน | 168 | 67 (40%) | 168 (100%) |
      | ทดสอบ | 145 | 18 (12%) | 145 (100%) |
      | กระจก | 4 | **0** | 4 (100%) |
      | append (EN) | 488 | 361 (74%) | 488 (100%) |

      `กระจก` — a word from this repo's own stated principle — was unfindable. unicode61
      also loses on ENGLISH, because token matching misses substrings inside paths.
      Trigram is not a free win, so it did not simply replace the old index:
        * cannot match a needle under 3 chars (`9c` → 0 rows), which is exactly the
          regression that made search look broken once already;
        * a prefix wildcard over-matches on it (`"work"*` → 4527 vs a truth of 771);
        * `snippet()`'s width argument counts TRIGRAMS, so the inherited 16 produced an
          ~18-character window (`…Detect «Workflo»…`) that clipped the searched phrase;
        * highlight spans are trigram-aligned, so a marker can land mid-word;
        * the index is the larger cost: **131 MB vs 52 MB**, db 59 MB → 198 MB.
      Verified end to end after a forced rebuild: `กระจก` 0 → 7 hits, `ทดสอบ` 18 → 148,
      `หลักฐาน` 67 → 172, and `9c` still routes to unicode61-with-prefix and still hits.
      110 tests pass; two pre-existing tests were UPDATED, not deleted — one had encoded
      the old engine's limitation (`byt off` must find nothing) as if it were desired.

- [x] **`import --force`.** Adding an index exposed a real gap: the `(path, mtime, size)`
      diff is about SOURCE freshness, so it skipped all 1031 unchanged files and left the
      new trigram index empty while every status line reported success. A diff that tracks
      file freshness cannot also track index completeness.
      Verified: plain import → `0 new, 8 changed, 1031 skipped`; `--force` →
      `0 new, 1039 changed, 0 skipped, 0 failed` in 31 s.

- [x] **Step 2 — semantic index built, and MEASURED AS NOT YET WORTH USING.**
      Apple `NLContextualEmbedding`, 512-dim, on-device, zero dependencies. UI panel in the
      Database tab (build / bounded build / stop, resumable, live coverage bar) plus
      `session-viewer embed [--limit N] [--query TEXT]`.
      Built on 1,930 events: **44,387 chunk vectors, 90.9 MB, 600 s** — so the full 19,482
      events extrapolate to roughly **918 MB and ~100 minutes**, against 131 MB and 31 s for
      the trigram index.
      Fair head-to-head, on a query whose content IS in the embedded subset (277 relevant
      chunks present): **semantic 2/8 relevant, keyword 8/9.** Same direction as
      facebook-oracle's own benchmark (Apple NLCE 60% vs FTS5 trigram 100%).
      Three findings from building it, all measured:
        * `C=20 S=10` was tuned on 12–400-char chat messages. Our events have median 149 but
          p90 2,276 and max 218,955 chars, so the same parameters yield ~23 chunks/event and
          the vector count explodes. Borrowed chunk parameters do not transfer across corpora.
        * Mean-centering the vectors (standard anisotropy fix) did NOT help here.
        * A null test comparing TOP SCORES ACROSS QUERIES is invalid — against 44k candidates
          even gibberish finds a high match by extreme-value chance. A controlled pair test
          showed the model itself is fine (same 0.86 / related 0.88 / unrelated 0.74 /
          gibberish 0.68); the failure is in ranking real chunks, not in the model.
      One retraction: an earlier Thai comparison was unfair — ZERO `ประชุม` chunks were in
      the embedded 10%, so that test measured coverage, not quality.
      Kept, opt-in, and labelled in the UI as being for paraphrase queries keyword search
      cannot express — not as an upgrade.

- [x] **`embed --dump` / `embed --load` — the provider seam.** JSONL over stdio, so any
      engine can supply vectors:
      `embed --dump | ssh gpu embed.py | embed --load --model NAME`.
      สมมติฐาน: the two halves of `buildEmbeddings` split cleanly at chunk/insert, so the
      seam needs no Swift HTTP client and no new dependency → คาดหวัง: a foreign engine at a
      DIFFERENT dimension coexists with the Apple vectors without contaminating them.
      **HELD.** Verified 2026-08-25 by piping 60 events through a stand-in engine:
      `embed --dump --model verify/8 --limit 60` → 335 chunks → `embed --load` →
      `loaded 335 vectors as verify/8, refused 0`. Three spaces then coexist, each labelled:
      `apple-nlce/en/r1/512` ×124,486 · `apple-nlce/th/r1/512` ×7,812 · `verify/8` ×335 —
      note the 8-dim rows sitting beside 512-dim ones, which is the whole point of putting
      `model` in the primary key.
      Validation refuses bad input rather than storing it:
      `{"dim":8,"vector":[0.1,0.2]}` → `vector has 2 floats but dim says 8 — refused`,
      `loaded 0, refused 1`. Without that check a short vector becomes a BLOB that
      `unpackVector` drops silently at query time — stored, counted in coverage, and
      invisible.
      Provenance recorded both runs: `vector_runs` shows `external | verify/8 | 335 | 0`
      and `external | verify/8 | 0 | 1`, so the refusal is in the log rather than only on
      stderr.
      `scripts/embed-http.sh` makes Cloudflare Workers AI and a local 2×4090 differ only by
      environment variables; the token lives in the script's env, never on argv where `ps`
      would show it.

- [x] **`--chunk-words` / `--chunk-stride` plumbed, and the defaults changed.**
      สมมติฐาน: C=20/S=10 was borrowed from a benchmark on 12–400 char chat messages and is
      wrong for events with p90 2,276 chars → คาดหวัง: larger windows cut the vector count
      sharply without losing the tail of a chunk.
      **HELD, bounded on both sides.** Verified 2026-08-25 over the same 40 events:
      C=20/S=10 → **1,138 chunks**; C=100/S=50 → **245**; C=200/S=100 → **137**.
      The upper bound is the model, not taste: `maximumSequenceLength` is 256 tokens and
      overrunning it is SILENT — two 200-word chunks sharing a head but with completely
      different tails embed to cosine **1.000000**, identical, because the tails were
      truncated before reaching the model. At 60 words the same pair differs (0.998397).
      So the default moved to C=100/S=50, between a floor set by chunk count and a ceiling
      set by the window.
      Measured on the real rebuild: 4.8 chunks/event instead of 23, 19,266 events → 78,200
      vectors in 27.9 min / 154.3 MB, against a ~100 min / ~918 MB projection at the old
      geometry. `vector_runs` records the geometry per build, so a later comparison does not
      depend on remembering which one produced which index.
      Surprise: the first attempt to verify this compared chunk counts using `set -- $G` in
      zsh, which does NOT word-split unquoted expansions — all three geometries silently ran
      at the defaults and produced identical counts, which read as "the flags do nothing".

## Now — in flight

Sprint 2026-08-26: bge-m3 corpus run + A/B eval. Simplest viable design (3 lenses):
one pipe on gpu2, one python scorer for both spaces, Swift only if bge wins.

- [x] **Harden `scripts/embed-http.sh` failure semantics** — `curl -sSf`, 3-attempt loop
      then explicit `exit 1`, and a sent-vs-returned batch-length guard.
      Verified: dead port → 3× "Failed to connect" then "embed-http: no response after 3
      attempts … aborting before any partial batch", `exit=1`, load never ran; live gpu2
      path on a 1-event dump → 1 aligned vector line.

- [x] **Announce to gpu-oracle inbox, then full build on gpu2 ALONE** — single sequential
      pipe. Decision held: NO two-box sharding (two dumps overlap 100%, two loads drop on
      BUSY silently).
      Verified: inbox note written to gpu-oracle 01:10; `loaded 99562 vectors as
      bge-m3/multi/r1/1024, refused 0`, RC=0, elapsed 2645 s (44 min — the 10-min estimate
      assumed the pool's concurrent batching; sequential HTTP is ~4× slower).
      Surprise: dump emitted 99,562 chunks, not ~112,566 — the whitespace-collapse chunker
      landed AFTER the apple build, so the same events chunk smaller now. Not a hole:
      re-dump proves coverage.

- [x] **Integrity by chunk count, never run status**.
      Verified: 99,562 + 91 smoke = 99,653 rows exactly; 0 rows with blob ≠ 4096 bytes;
      legacy main.event_vectors = 0; re-dump → `dumped 0 chunks` — done is derivable.

- [x] **Python A/B eval — same scorer per arm, apple via Swift `eval --file`** (apple query
      vectors cannot leave the Embedder; python mirrors centering/dedupe/denominator
      line-for-line — recorded caveat: cross-implementation comparison, n=13, 25-id proxy
      truth, @50 primary).
      Verified: `eval --file labeled-en.jsonl` → apple sem 13%@10/19%@50 (reproduces the
      recorded 14/19 baseline → control valid); TH file → apple 5%@10/8%@50.
      `python3 eval/eval_ab.py` → bge EN 12.5%@10/**28.2%@50** · TH 18.5%@10/**27.5%@50**.
      **Verdict: bge wins EN@50 by +47% relative and TH by 3.4×; bge TH ≈ bge EN — the
      single multilingual space erases the language penalty. The model WAS the ceiling.**
      Surprise: @10 EN is a tie (12.5 vs 13) — bge's win lives in the tail, not the head.

- [x] **Write back**: verdict recorded in SPEC rung 6 (table + caveats + unblock note);
      MCP `semantic_search` description now carries the measured 19%@50-vs-4% numbers;
      `logSearch(engine: "vector")` added to the semantic_search handler.
      Verified: `swift build` clean; `swift test` → "171 tests in 30 suites passed".

- [x] **Import remote@m5.local's session corpus** — in place via local-only inheritable ACL
      (no copy; future files inherit readability), sequenced after the bge load.
      Verified: `import run 17: 28739 new, 0 changed, 0 skipped, 0 failed` in 424 s;
      21,237 rows parent-linked (856 unlinked, parents not on disk — honest count);
      status → 30,782 sessions / 713 projects / 3,229,594 events / 20.29 GB source;
      spot-search "gpu1-cf" → 5 hits incl. remote's 2026-07-11 tunnel-setup session
      (0 hits before import). 29,560 found vs 28,739 imported = journals/non-transcript
      exclusions, consistent with the three-tier discovery rules.
      Surprise: **the pruned chip regressed by shape** — "pruned 28739 rows whose file is
      gone" is exactly remote's file count: the diff walks only the default roots, so a
      third root's files read as deleted. Same disease as the 627-phantom fix in this
      file; rows and search are unaffected, the chip lies. → filed under Next.

## Sprint Retro: bge-m3 GPU run + A/B eval (2026-08-26)

| # | Task | Hypothesis | Matched? | Surprise |
|---|------|-----------|----------|----------|
| 1 | Harden embed-http.sh | 5xx exits 0; dead tunnel loads partials | ✅ | none |
| 2 | Full build, gpu2 alone | ~112.5k chunks, ≤25 min | ⚠️ half | 99,562 chunks (post-apple chunker collapses whitespace); 44 min (sequential HTTP ≈ 4× slower than pool rate) |
| 3 | Integrity by count | loaded==dumped, dim ok, legacy 0 | ✅ | none — exact to the row |
| 4 | A/B eval | bge ≥ apple EN@50, ≫ TH | ✅ | EN@10 is a TIE — the win lives entirely in the tail; bge TH ≈ bge EN |
| 5 | Write-back | 2 small MCP edits, tests green | ✅ | stale SourceKit diags ≠ compiler truth |
| 6 | remote corpus import | ~29.5k files, attribution correct | ✅ | pruned-chip regression (third root, same 627-phantom shape) |

- **Matched**: 5/6 fully, 1 half (throughput + chunk-count estimates wrong, outcome right)
- **Lessons**: sequential-HTTP ≠ pool throughput (batch concurrency is the difference);
  every NEW root re-opens the "which roots does the diff walk" bug class — roots want a
  single registry the scan/diff/status all read; the verification ladder caught a real
  load-path defect at rung 3 — spec-first paid for itself before the run started.
- **Artifacts**: this file + SPEC.md (rung-6 verdict table) · eval/eval_ab.py ·
  .data/workers.json · gpu-oracle inbox note 01:10

- [x] **Registry occupant #2: `sync` / `import_index`** (2026-08-27) — MCP-triggered
      incremental import over NAMED corpus roots (`corpus` = all|local|remote via
      `.data/roots.json`, the roots-registry seed) with a `since` file-mtime window;
      `index_status` gained a "last import run N · finished <ts>" freshness line
      (`lastImportRunLine`, DBStatus.swift). Deliberately NOT the `import` verb — that
      one keeps arbitrary `--root` paths; MCP clients only ever get named roots.
      Verified: raw stdio JSON-RPC → `import_index {corpus:"remote", since:"today"}` →
      "remote: run 21 — 0 new, 0 changed, 16 unchanged"; `index_status` → "last import
      run 21 · finished 2026-08-27 05:39:08 UTC"; CLI `sync --corpus local --since 30m`
      scopes correctly; 171/30 green.
      Surprise: the param was first named `root` and `sync --root local` silently ran BOTH
      corpora — `--root` is a global flag main.swift consumes before the validator, so
      the param defaulted to "all" and broadened scope without refusing. Renamed to
      `corpus`. Bridge-hazard family #2: registry params must never shadow global flags.

## Next — unblocked by this sprint

- [ ] Swift query-side routing (`--query-vector-file` + dim-from-blob) — trigger FIRED:
      bge won. Until it ships, 99,653 winning vectors are unreachable by every consumer.
- [ ] Roots registry: scan/diff/status/live all walk one recorded list of roots
      (local claude + local codex + /Users/remote/.claude/projects + remote codex pending) —
      kills the pruned-phantom class instead of patching it per-root.
- [ ] remote's ~/.codex/sessions (8.3 GB) — needs the codex verb to take `--root`.

## Next — not started

- [x] Runtime Command Registry — landed WITH its first occupant, because the time-window
      filter was the "next real new verb" it was blocked on. One declaration serves
      `list` (CLI) + `list_sessions` (MCP) + the All-tab picker; one validator for both
      surfaces; `.choice` renders enums into JSON Schema; `.int(min:max:)` bounds.
      Verified: `list --since 3h` and MCP list_sessions{since:"30m"} answer from the same
      declaration; `--limit abc` / `--sort nonsense` / `--limit -5` all refuse by name.
      Surprise: the bridge hazard fired on the FIRST run (`--since` rejected by the global
      allow-list) — fixed structurally: CLI_VALUED_FLAGS unions in registry params.

- [x] Time-window filters — `since` = 30m/3h/today/7d/Nm-Nh-Nd/YYYY-MM-DD, filtering on
      indexed file mtime (active-in-window). "today" = local midnight, tested by name.

- [x] Resolve tier-2/3 `parent_session_id`. The parent's uuid is IN the file path, both
      rows are in the table — nothing had ever joined them. Now an idempotent pass at the
      end of every import, scoped by (uuid, project_id) so two checkouts of one repo
      cannot cross-link.
      Verified: import → "linked 1250 subagent/workflow row(s)"; unparented now 0/0.

- [x] Pruned-file count. It was 627 — exactly the number of LIVE Codex files, because the
      diff walked only ~/.claude/projects and declared everything in ~/.codex/sessions
      "gone from disk". Both roots now feed the diff; real pruned count today: 0.
      A chip asserting files are gone when they exist teaches you to ignore the one
      number that matters if pruning ever really bites.

## Deferred — decided, not scheduled

- [ ] Index `journal.jsonl`. Measured 2026-08-25: 73 files, 8.3 MB, shape
      {type: started|result, key: v2:<hash>, agentId, result}. DECIDED against a table:
      the `result` text duplicates the agent transcript's final output, which is already
      indexed as a workflow_agent session — a second copy would double-index the same
      content. Revisit only for: a real search that misses content existing ONLY in a
      journal result (e.g. StructuredOutput objects never echoed into the transcript).

- [ ] Bun + libSQL ingest layer. **No longer blocked** — the cheap test ran 2026-08-28 and
      PASSED: `@libsql/client` 0.17.4 ships FTS5 with `tokenize='trigram'` (Thai mid-word
      `MATCH '"ระจก"'` → hit), and the file it writes is readable and queryable by stock
      `/usr/bin/sqlite3`, trigram queries included. Not scheduled anyway — nothing here needs
      replication or a remote endpoint, so the reason is now "no need", not "unknown".
      **Drop Drizzle from this idea**: `drizzle-kit generate` emits a plain `CREATE TABLE`
      where an FTS5 virtual table was declared, and every Drizzle-using sibling oracle
      already carves FTS5 out to raw SQL. See SPEC.md and
      `ψ/lab/session-search/SPEC.md`.

- [ ] `.xcodeproj`. Not needed — SwiftPM runs a SwiftUI window fine. Revisit only for
      signing/distribution/app icon.

- [ ] Tools vector class (Q2: ไม่ทำ). `--classes tools` มีอยู่แล้วแต่ไม่ build — keyword
      ครอบคลุม 100% อยู่แล้ว. Revisit only for: a real paraphrase query over tool output
      that keyword misses.

- [ ] Developer-text dedupe (Q5: ข้าม — 2,123 rows / 37 distinct texts route ไป tools
      class ซึ่งไม่ build). Revisit only if the tools class is ever built.

- [ ] Swift query-side routing for remote models — `--query-vector-file` on embed/eval,
      dim-from-blob in `semanticSearch` (today model AND dim both derive from the Apple
      `Embedder`; 1024-float blobs are silently dropped at unpackVector). Blocked on:
      bge winning the python A/B. Without a win no Swift change is warranted; with one it
      is the value gate — bge rows are structurally unreachable by every consumer
      (MCP/GUI/CLI) until this ships.

- [ ] Two-box sharding / pool script. Safe shape if ever needed: dump once to file →
      split disjoint halves → embed in parallel → load SERIALLY. Revisit only for:
      corpus ~10× or a single-box build exceeding ~1 h. `.data/workers.json` stays as
      description (nothing reads it — deliberate: registry documents, probes decide).

- [ ] Hub-in-serve + SwiftUI pool panel. Revisit only for: third worker or second job
      type (OCR/transcribe/training).

## Open questions


- Is a persistent index even the right call, or is live `rg` enough? `jsonl-lens`'s README
  argues the latter for search. The index earns its keep for *aggregates* (per-tier counts,
  import history, type breakdowns) — which is what the app actually shows.

