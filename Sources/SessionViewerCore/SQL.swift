// SQL.swift — every SQL statement in the app, as named constants.
//
// Caseless enum of plain strings. Deliberately NOT a query builder/factory: every
// statement here is fixed and uses bound parameters, so hiding it behind a builder
// would only obscure the SQL from schema review and reinvent a worse Drizzle right
// before the project possibly adopts the real one (see SPEC.md's "Deferred" section).
//
// ONE deliberate exception to "fixed text + bound params": the session list's ORDER BY
// column and direction, which SQLite cannot bind. That exception is confined to
// `SessionSort` / `SortDirection` below — a closed allow-list of literal SQL fragments
// that no caller string can reach. Everything else, LIMIT included, is a real `?`.
//
// Two statements (deleteTypeCountsForSession / deleteEventsFtsForSession) were
// string-interpolated with a raw session id in the pre-extraction code — the only
// unparameterized statements in the codebase. Extracted here as `?`-bound like every
// other statement, since a "static constant" can't itself carry a per-call value; the
// call sites now bind session_id instead of interpolating it. Same rows deleted either
// way — this is a bind-parameter mechanics change, not a behavior change.
enum SQL {

    // MARK: - projects

    static let selectProjectByDirName = "SELECT id FROM projects WHERE dir_name = ?"

    static let updateProjectCwd = """
        UPDATE projects SET cwd = COALESCE(cwd, ?), last_seen_at = datetime('now') WHERE id = ?
        """

    /// Atomic upsert that RETURNS the id, so the caller never has to infer it from
    /// `last_insert_rowid()`.
    ///
    /// The old form was a plain INSERT whose step result was discarded, followed by
    /// `return db.lastInsertId`. `last_insert_rowid()` reports the last SUCCESSFUL insert on
    /// the connection — so when the INSERT did not happen (SQLITE_CONSTRAINT from
    /// UNIQUE(dir_name) after a starved SELECT, or SQLITE_BUSY_SNAPSHOT, which SQLite does
    /// NOT route through the busy handler) the function returned some OTHER row's id and the
    /// importer filed that project's sessions under it, reporting success. ON CONFLICT +
    /// RETURNING collapses the select/insert race into one statement and makes the id
    /// something the database states rather than something we guess.
    static let upsertProjectReturning = """
        INSERT INTO projects (dir_name, cwd) VALUES (?, ?)
        ON CONFLICT(dir_name) DO UPDATE SET
            cwd = COALESCE(projects.cwd, excluded.cwd),
            last_seen_at = datetime('now')
        RETURNING id
        """

    /// The live fleet view maps an on-disk project dirname to the real cwd the importer
    /// recorded (SPEC.md: never decode the dirname). A live session in a project that was
    /// never imported simply has no row here and falls back to the raw dirname.
    static let selectProjectPaths = "SELECT dir_name, cwd FROM projects"

    // MARK: - sessions

    /// Ingest.swift's diff-loading query — kept identical in text to the pre-extraction
    /// literal (also identical in text to a manual SELECT one might write against the
    /// schema below), just named here for the same schema-review reason as everything else.
    static let selectKnownFiles = "SELECT file_path, file_mtime, file_size, import_status FROM sessions"

    static let updateSession = """
        UPDATE sessions SET file_mtime=?, file_size=?, imported_at=datetime('now'),
          import_status='imported', import_error=NULL, line_count=?, event_count=?,
          started_at=?, ended_at=?, description=? WHERE id=?
        """

    static let insertSession = """
        INSERT INTO sessions (project_id, session_uuid, file_path, file_tier,
          workflow_run_id, agent_id, file_mtime, file_size, imported_at, import_status,
          line_count, event_count, started_at, ended_at, description)
        VALUES (?,?,?,?,?,?,?,?,datetime('now'),'imported',?,?,?,?,?)
        """

    static let selectSessionIdByPath = "SELECT id FROM sessions WHERE file_path = ?"

    /// Failure-path counterparts of updateSession/insertSession — used by
    /// recordImportFailure (Store.swift) instead of leaving a file's row stuck showing
    /// stale success data (or, for a never-before-seen file, no row at all) when the
    /// read or a write genuinely fails. insertSessionFailed's ON CONFLICT covers the
    /// race where a row already exists at file_path under the "new file" branch.
    static let updateSessionFailed = """
        UPDATE sessions SET file_mtime=?, file_size=?, imported_at=datetime('now'),
          import_status='failed', import_error=? WHERE id=?
        """

    static let insertSessionFailed = """
        INSERT INTO sessions (project_id, session_uuid, file_path, file_tier,
          workflow_run_id, agent_id, file_mtime, file_size, imported_at, import_status,
          import_error)
        VALUES (?,?,?,?,?,?,?,?,datetime('now'),'failed',?)
        ON CONFLICT(file_path) DO UPDATE SET
          file_mtime=excluded.file_mtime, file_size=excluded.file_size,
          imported_at=excluded.imported_at, import_status='failed',
          import_error=excluded.import_error
        """

    /// fetchSessions composes this base + an optional tier filter + order/limit — see
    /// Store.swift and `selectSessionsOrderLimit(_:_:)` below.
    ///
    /// Column 10 (`s.file_mtime`) is appended last on purpose: it is the DEFAULT sort key,
    /// so the list must be able to show it. Sorting by a column the rows don't display is
    /// what made the old fixed `ORDER BY s.file_mtime DESC` look unsorted next to the
    /// `started_at` the rows printed.
    static let selectSessionsBase = """
        SELECT s.id, s.session_uuid, s.file_tier, COALESCE(p.cwd, p.dir_name), s.file_path,
               s.file_size, COALESCE(s.line_count,0), COALESCE(s.event_count,0),
               s.started_at, s.description, s.file_mtime, COALESCE(s.source,'claude')
        FROM sessions s JOIN projects p ON p.id = s.project_id
        """

    static let selectSessionsTierFilter = " WHERE s.file_tier = ?"

    /// Composable filter fragments — `fetchSessions` joins the ones in force with AND.
    /// Bare fragments (no WHERE) so the composition owns the keyword; values are BOUND.
    static let sessionsTierFragment = "s.file_tier = ?"
    static let sessionsSinceFragment = "s.file_mtime >= ?"

    /// The ONLY place ORDER BY text is assembled, and the only interpolation in this file.
    /// It is a function rather than a constant because the sort column varies at runtime
    /// and **SQLite cannot bind a column name** — read the `SessionSort` comment below
    /// before touching it. Both interpolated pieces come from closed Swift enums, never
    /// from a caller-supplied string.
    ///
    /// `s.id DESC` is a tiebreaker so equal keys (very common on `file_tier`, and on
    /// `file_mtime` for the workflow tier, where a whole fan-out lands in the same second)
    /// produce a stable order instead of shuffling between reloads.
    ///
    /// LIMIT is a real bound parameter here. The pre-sorting code concatenated it as
    /// literal text, which contradicted this file's own header comment.
    static func selectSessionsOrderLimit(_ sort: SessionSort, _ direction: SortDirection) -> String {
        " ORDER BY \(sort.sqlExpression) \(direction.sqlKeyword), s.id DESC LIMIT ?"
    }

    /// Fetch a single session by id, independent of any tier filter — used by
    /// fetchSession (Store.swift) so a search hit can populate the detail pane even when
    /// its tier isn't the sidebar's current filter. Column list must stay identical to
    /// selectSessionsBase: both build the same `SessionRow`.
    static let selectSessionById = """
        SELECT s.id, s.session_uuid, s.file_tier, COALESCE(p.cwd, p.dir_name), s.file_path,
               s.file_size, COALESCE(s.line_count,0), COALESCE(s.event_count,0),
               s.started_at, s.description, s.file_mtime, COALESCE(s.source,'claude')
        FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ?
        """

    // MARK: - type counts

    static let deleteTypeCountsForSession = "DELETE FROM session_type_counts WHERE session_id=?"

    static let insertTypeCount = "INSERT INTO session_type_counts (session_id, line_type, count) VALUES (?,?,?)"

    static let selectTypeCountsForSession = "SELECT line_type, count FROM session_type_counts WHERE session_id = ? ORDER BY count DESC"

    // MARK: - fts

    static let deleteEventsFtsForSession = "DELETE FROM events_fts WHERE session_id=?"

    static let deleteEventsFtsTriForSession = "DELETE FROM events_fts_tri WHERE session_id=?"

    static let insertEventFts = "INSERT INTO events_fts (session_id, seq, role, ts, text) VALUES (?,?,?,?,?)"

    static let insertEventFtsTri = "INSERT INTO events_fts_tri (session_id, seq, role, ts, text) VALUES (?,?,?,?,?)"

    /// Same projection as `searchEvents`, against the trigram index. A separate constant
    /// rather than an interpolated table name: the table is an identifier, and this file's
    /// whole discipline is that identifiers are never built from variables.
    /// The final `snippet()` argument is a TOKEN count, and a trigram index's tokens are
    /// 3-character sequences, not words. Passing the same 16 used for unicode61 produced a
    /// ~18-character window — measured: `…Detect «Workflo»…` — which is too narrow to read
    /// and can clip the very phrase that was searched for. 96 trigrams gives a window
    /// comparable to 16 words.
    static let searchEventsTri = """
        SELECT e.session_id, s.session_uuid, e.role, e.ts,
               snippet(events_fts_tri, 4, '«', '»', '…', 96), bm25(events_fts_tri)
        FROM events_fts_tri e JOIN sessions s ON s.id = e.session_id
        WHERE events_fts_tri MATCH ? ORDER BY bm25(events_fts_tri) LIMIT ?
        """

    /// Idempotent DDL so an existing db picks the trigram index up without a rebuild —
    /// same self-healing reasoning as `createTailState`.
    static let createTrigramIndex = """
        CREATE VIRTUAL TABLE IF NOT EXISTS events_fts_tri USING fts5(
            session_id UNINDEXED, seq UNINDEXED, role UNINDEXED, ts UNINDEXED, text,
            tokenize='trigram'
        )
        """

    /// LIMIT is a real bound parameter, matching `selectSessionsOrderLimit` and this
    /// file's header claim. It used to be concatenated as literal text (carried over from
    /// the pre-extraction code), which made the header's "LIMIT included, is a real `?`"
    /// false for this one statement — the last such exception.
    static let searchEvents = """
        SELECT e.session_id, s.session_uuid, e.role, e.ts,
               snippet(events_fts, 4, '«', '»', '…', 16), bm25(events_fts)
        FROM events_fts e JOIN sessions s ON s.id = e.session_id
        WHERE events_fts MATCH ? ORDER BY bm25(events_fts) LIMIT ?
        """

    // MARK: - transactions

    static let begin = "BEGIN"

    static let commit = "COMMIT"

    // MARK: - import runs

    static let insertImportRun = "INSERT INTO import_runs (files_scanned) VALUES (?)"

    static let updateImportRun = """
        UPDATE import_runs SET finished_at=datetime('now'), files_new=?, files_changed=?,
          files_skipped=?, files_failed=? WHERE id=?
        """

    /// Newest-first import log. `finished_at IS NULL` is a run that never completed —
    /// shown as "interrupted" rather than hidden, because a crashed import is exactly the
    /// state you want to see when the index looks wrong.
    static let selectImportRuns = """
        SELECT id, started_at, finished_at, files_scanned, files_new, files_changed,
               files_skipped, files_failed
          FROM import_runs ORDER BY id DESC LIMIT ?
        """

    // RANKING: both search statements above end in `ORDER BY bm25(...)`, and did not until
    // 2026-08-25. Without it FTS5 returns rows in rowid order — which is arbitrary with
    // respect to the query, and measurably worse than arbitrary in practice: for `crash` the
    // first five rows in rowid order scored -0.33, -1.45, -1.45, -1.66, -1.71, and in FTS5
    // a MORE NEGATIVE bm25 is a BETTER match. The page was led by its weakest hit.
    //
    // bm25 rather than a hand-rolled TF-IDF: BM25 is TF-IDF's successor (it adds term
    // saturation and document-length normalisation, which is exactly what stops one long
    // transcript full of repeats from dominating), and SQLite ships it. Writing our own
    // would be the SQL-builder argument again — reinventing something worse and hiding it
    // from review.

    // MARK: - vectors (the ML/NL index)

    /// Idempotent, so an existing db gains the table without a rebuild — same self-healing
    /// reasoning as `createTailState` and `createTrigramIndex`.
    /// One row per CHUNK, not per event: uniform chunking is the single biggest recall lever
    /// measured (e5 55%→88%, Apple NLCE 30%→60%), so chunks are the unit the schema models.
    /// `model` is in the PRIMARY KEY, and that is the whole safety property of this table.
    ///
    /// MEASURED: vectors from two different models are not merely differently scaled, they
    /// are different SPACES. The same string "the database crashed" embedded by Apple's
    /// English model vs its Thai model has cosine **-0.0227** — orthogonal. en vs zh-Hans is
    /// 0.0791. So a table holding both and treating them as one index does not degrade
    /// gracefully; it produces numbers with no meaning.
    ///
    /// The first version of this table omitted `model` and the app shipped 44,387 vectors
    /// built by FOUR models (Embedder routes per-chunk across en/th/zh/ja by detected
    /// language). Nothing recorded which. `corpusMean` averaged across all four and the
    /// query was embedded by whichever model matched the QUERY's language, then scored
    /// against chunks from the other three.
    ///
    /// Model identity is the FULL space, not the model name: provider, language, asset
    /// revision, and dimension. `apple-nlce/en/r1/512` and `apple-nlce/th/r1/512` are
    /// different indexes that happen to come from one framework. A macOS update that bumps
    /// the asset revision also mints a new identity — dimension equality is not identity.
    static let createEventVectors = """
        CREATE TABLE IF NOT EXISTS event_vectors (
            session_id  INTEGER NOT NULL,
            seq         INTEGER NOT NULL,
            chunk_index INTEGER NOT NULL,
            model       TEXT NOT NULL,
            dim         INTEGER NOT NULL,
            vector      BLOB NOT NULL,
            text        TEXT,
            PRIMARY KEY (session_id, seq, chunk_index, model)
        )
        """

    static let insertEventVector = """
        INSERT OR REPLACE INTO event_vectors (session_id, seq, chunk_index, model, dim, vector, text)
        VALUES (?,?,?,?,?,?,?)
        """

    /// Insert into an ATTACHed class database ("vec_chat" / "vec_tools").
    ///
    /// The schema name is interpolated, and that is safe for the same reason SessionSort's
    /// ORDER BY is: it is derived from a closed enum (`VectorClass.rawValue`), never from
    /// caller input, and SQLite cannot bind an identifier.
    static func insertEventVector(schema: String) -> String {
        """
        INSERT OR REPLACE INTO \(schema).event_vectors
               (session_id, seq, chunk_index, model, dim, vector, text)
        VALUES (?,?,?,?,?,?,?)
        """
    }

    /// Events with no vector yet — makes a build resumable rather than all-or-nothing.
    /// Unembedded FOR A GIVEN MODEL. The model is bound, not omitted: without it, a corpus
    /// half-built by one model reports as complete for every other, so a second engine
    /// silently inherits the first's coverage and indexes nothing.
    /// The work list, now carrying ROLE so the builder can route each vector to its class
    /// database and honour a role filter.
    ///
    /// `?3` is a comma-joined role list rendered by the caller from a CLOSED enum
    /// (`VectorClass.roles`) — never from user input — for the same reason `SessionSort`
    /// renders ORDER BY: SQLite binds values, not lists, and the alternative is a variable
    /// number of placeholders for a set that is fixed at compile time.
    ///
    /// The NOT EXISTS still keys on (session_id, seq, model) WITHIN one class database. It
    /// deliberately does not consider chunk geometry — see the mixed-geometry warning in
    /// EmbedCoverage; that is a known gap, surfaced rather than silently papered over.
    /// `v.model IN (?1, ?2)` — BOTH of the embedder's spaces, not English alone.
    ///
    /// `Embedder.embed` routes by detected language and stores Thai text under the th model
    /// id. The first version of this check asked only for the en id, so every Thai event
    /// (2,383 of them, 7,879 vectors measured) failed the check on every run, was
    /// re-embedded, and was INSERT OR REPLACEd onto its own identical rows — an infinite
    /// re-embed loop that advanced the per-run counters and never advanced coverage.
    static func selectUnembedded(rolesIn roles: [String], vectorSchema: String) -> String {
        let list = roles.map { "'\($0)'" }.joined(separator: ",")
        return """
        SELECT e.session_id, e.seq, e.text, e.role FROM events_fts e
        WHERE e.role IN (\(list))
          AND NOT EXISTS (SELECT 1 FROM \(vectorSchema).event_vectors v
                          WHERE v.session_id = e.session_id AND v.seq = e.seq
                            AND v.model IN (?1, ?2))
        """
    }

    static let selectUnembedded = """
        SELECT e.session_id, e.seq, e.text, e.role FROM events_fts e
        WHERE NOT EXISTS (SELECT 1 FROM event_vectors v
                          WHERE v.session_id = e.session_id AND v.seq = e.seq
                            AND v.model = ?1)
        """

    static let selectUnembeddedLimited = selectUnembedded + " LIMIT ?2"

    /// Per-model coverage. `max(dim)` over a mixed table was meaningless — it reported one
    /// number for a table containing several spaces, so the UI confidently displayed a
    /// dimension the search was not using.
    static let selectEmbedCoverage = """
        SELECT count(*),
               count(DISTINCT session_id || ':' || seq),
               coalesce(max(dim),0),
               coalesce(sum(length(vector)),0)
          FROM event_vectors WHERE model = ?
        """

    /// Which models this db actually contains. If more than one exists and none is named,
    /// searching must ERROR rather than silently scan across incomparable spaces.
    static let selectVectorModels = """
        SELECT model, dim, count(*) FROM event_vectors GROUP BY model, dim ORDER BY count(*) DESC
        """

    static let selectVectorsForSearch = """
        SELECT v.session_id, s.session_uuid, 'vector', NULL, v.vector, v.text
          FROM event_vectors v JOIN sessions s ON s.id = v.session_id
         WHERE v.model = ?
        """

    /// The same scan against one ATTACHed class database. `sessions` lives in the main
    /// schema, and cross-schema JOINs are exactly what ATTACH exists for. `?1` on every
    /// branch of a UNION means one bind serves the whole statement.
    static func selectVectorsForSearch(schema: String) -> String {
        """
        SELECT v.session_id, s.session_uuid, 'vector', NULL, v.vector, v.text
          FROM \(schema).event_vectors v JOIN sessions s ON s.id = v.session_id
         WHERE v.model = ?1
        """
    }

    /// Filtered search. The WHERE fragments are appended by `searchEventsFiltered`, and the
    /// values are BOUND — the only interpolation is the fixed fragment text itself, chosen
    /// by a Bool, never by caller input. Same discipline as SessionSort: SQLite can bind
    /// values but not identifiers, so anything that is not a value stays a literal here.
    static let searchEventsBase = """
        SELECT e.session_id, s.session_uuid, e.role, e.ts,
               snippet(events_fts, 4, '«', '»', '…', 16), bm25(events_fts), e.seq
        FROM events_fts e JOIN sessions s ON s.id = e.session_id
        JOIN projects p ON p.id = s.project_id
        WHERE events_fts MATCH ?
        """

    static let searchEventsTriBase = """
        SELECT e.session_id, s.session_uuid, e.role, e.ts,
               snippet(events_fts_tri, 4, '«', '»', '…', 96), bm25(events_fts_tri), e.seq
        FROM events_fts_tri e JOIN sessions s ON s.id = e.session_id
        JOIN projects p ON p.id = s.project_id
        WHERE events_fts_tri MATCH ?
        """

    // MARK: - multi-source (Claude Code + Codex)

    /// WHICH TOOL PRODUCED THIS TRANSCRIPT. 'claude' | 'codex'.
    ///
    /// A separate axis from `file_tier`, not a new tier value. A Codex rollout genuinely IS
    /// a top-level session — it is not a fourth kind of Claude file — so it takes
    /// file_tier='session' and is told apart by source. That also avoids rewriting the
    /// table: `file_tier` carries a CHECK constraint and SQLite cannot alter one in place.
    static let addSessionSourceColumn = "ALTER TABLE sessions ADD COLUMN source TEXT NOT NULL DEFAULT 'claude'"

    static let countSessions = "SELECT count(*) FROM sessions"

    static let selectSourceCounts = """
        SELECT coalesce(source,'claude'), file_tier, count(*), coalesce(sum(file_size),0),
               coalesce(sum(event_count),0)
          FROM sessions GROUP BY 1, 2 ORDER BY 1, 3 DESC
        """

    /// Codex states its parent outright, so unlike Claude tier-3 this can be populated.
    static let updateSessionParentThread = "UPDATE sessions SET parent_session_id = (SELECT id FROM sessions WHERE session_uuid = ?) WHERE id = ?"

    // MARK: - reading a session (the dig path)

    /// A contiguous run of one session's conversation, in order.
    ///
    /// This is the tool the index was missing. Search could FIND a hit and nothing could
    /// READ around it, which makes a search result a dead end: you get 140 characters of
    /// snippet and no way to learn what the exchange actually was.
    static let selectSessionEvents = """
        SELECT e.seq, e.role, coalesce(e.ts,''), e.text
          FROM events_fts e
         WHERE e.session_id = ? AND e.seq >= ?
         ORDER BY e.seq LIMIT ?
        """

    /// Messages either side of one event — the context a hit needs to mean anything.
    static let selectEventContext = """
        SELECT e.seq, e.role, coalesce(e.ts,''), e.text
          FROM events_fts e
         WHERE e.session_id = ? AND e.seq BETWEEN ? AND ?
         ORDER BY e.seq
        """

    /// Resolve a uuid prefix to a session id. Prefixes because nobody types a whole uuid,
    /// and search results show only the first 8 characters.
    static let selectSessionByUUIDPrefix = """
        SELECT s.id, s.session_uuid, s.file_tier, s.file_path,
               coalesce(p.cwd, p.dir_name), coalesce(s.started_at,''), coalesce(s.event_count,0)
          FROM sessions s JOIN projects p ON p.id = s.project_id
         WHERE s.session_uuid LIKE ? || '%' LIMIT 200
        """

    // MARK: - saved topics (dynamic MCP tools)

    /// A topic is a REMEMBERED INVESTIGATION that becomes its own MCP tool.
    ///
    /// The point is higher-order: `tools/list` is not a fixed set. Start a trace on a topic,
    /// and from then on the server advertises `dig_<topic>` alongside the built-in tools, so
    /// a model can call the investigation by name instead of re-deriving the query every
    /// time. The query, the engine that answered it, and what it found are all memoized, so
    /// the tool carries its own provenance rather than being an opaque alias.
    ///
    /// `last_hits` and `last_run_at` are stored because a saved topic that has stopped
    /// finding anything is the interesting case — it means either the corpus moved or the
    /// query rotted, and neither is visible from the tool's name.
    static let createTopics = """
        CREATE TABLE IF NOT EXISTS topics (
            name         TEXT PRIMARY KEY,
            query        TEXT NOT NULL,
            engine       TEXT NOT NULL DEFAULT 'keyword',
            description  TEXT,
            created_at   TEXT NOT NULL DEFAULT (datetime('now')),
            last_run_at  TEXT,
            runs         INTEGER NOT NULL DEFAULT 0,
            last_hits    INTEGER,
            -- Does this topic get its OWN tool in tools/list?
            --
            -- Default 0, and that default is the research result. Two things are true at
            -- once: a specifically-named tool genuinely helps a model choose (AWS's MCP
            -- guidance: "splitting a multi-purpose tool into several specific tools
            -- provides clarity to the model"), AND every extra tool is charged against a
            -- budget that is already strained — this machine runs 98 tools across 5
            -- servers, Claude Code has an open bug dropping tools past position 30 in
            -- multi-server setups, and Cursor hard-caps at 40 and silently discards the
            -- rest. So a topic is reachable through the stable `dig_topic` tool from the
            -- moment it exists, and only spends a tool slot when someone decides it earns
            -- one.
            promoted     INTEGER NOT NULL DEFAULT 0,
            -- COMPOSITION. A comma-separated source list; empty means "local keyword only",
            -- which is what every topic was before this column existed.
            --
            --   local:keyword          this machine's session index, trigram/unicode61
            --   local:semantic         this machine's vectors
            --   upstream:<name>/<tool> a wrapped MCP server's tool, e.g. oracle/oracle_search
            --
            -- This is where composition has to live. MCP has NO composition primitive —
            -- no server-to-server RPC, no tool calling another tool; SEP-1610 explicitly
            -- excludes server-side macro tools and SEP-1686 (Tasks) states it is not a
            -- composition mechanism. The spec's own guidance leaves exactly three options:
            -- do it inside one tool, let the model chain calls, or use code execution.
            -- A topic is the first of those, made durable.
            sources      TEXT NOT NULL DEFAULT ''
        )
        """

    /// One captured result for a topic — the memoized half.
    static let createTopicHits = """
        CREATE TABLE IF NOT EXISTS topic_hits (
            topic       TEXT NOT NULL,
            session_id  INTEGER NOT NULL,
            uuid        TEXT NOT NULL,
            role        TEXT,
            ts          TEXT,
            score       REAL,
            snippet     TEXT,
            captured_at TEXT NOT NULL DEFAULT (datetime('now')),
            -- WHICH source produced this hit. Without it a composed topic is a pile with
            -- no way to tell whether the upstream is pulling its weight or just adding
            -- latency — and that is the only question worth asking about a composition.
            source      TEXT NOT NULL DEFAULT 'local:keyword',
            PRIMARY KEY (topic, session_id, snippet)
        )
        """

    static let upsertTopic = """
        INSERT INTO topics (name, query, engine, description) VALUES (?,?,?,?)
        ON CONFLICT(name) DO UPDATE SET query=excluded.query, engine=excluded.engine,
          description=coalesce(excluded.description, topics.description)
        """

    static let finishTopicRun = """
        UPDATE topics SET last_run_at=datetime('now'), runs=runs+1, last_hits=? WHERE name=?
        """

    static let insertTopicHit = """
        INSERT OR REPLACE INTO topic_hits (topic, session_id, uuid, role, ts, score, snippet, source)
        VALUES (?,?,?,?,?,?,?,?)
        """

    static let addTopicHitSourceColumn = "ALTER TABLE topic_hits ADD COLUMN source TEXT NOT NULL DEFAULT 'local:keyword'"

    static let selectTopicSourceCounts = """
        SELECT source, count(*) FROM topic_hits WHERE topic = ? GROUP BY source ORDER BY count(*) DESC
        """

    /// ORDER BY name is deliberate: the spec asks servers to "return tools in a
    /// deterministic order … Deterministic ordering enables clients to reliably cache the
    /// tool list and improves LLM prompt cache hit rates."
    static let selectTopics = """
        SELECT name, query, engine, coalesce(description,''), created_at,
               coalesce(last_run_at,''), runs, coalesce(last_hits,-1), promoted,
               coalesce(sources,'')
          FROM topics ORDER BY name
        """

    static let setTopicPromoted = "UPDATE topics SET promoted = ? WHERE name = ?"

    /// Idempotent migration for databases created before promotion existed. SQLite has no
    /// ADD COLUMN IF NOT EXISTS, so the error is caught rather than prevented — the same
    /// self-healing pattern used for the tail-state and trigram tables.
    static let addTopicPromotedColumn = "ALTER TABLE topics ADD COLUMN promoted INTEGER NOT NULL DEFAULT 0"

    static let addTopicSourcesColumn = "ALTER TABLE topics ADD COLUMN sources TEXT NOT NULL DEFAULT ''"

    static let setTopicSources = "UPDATE topics SET sources = ? WHERE name = ?"

    static let selectTopicHits = """
        SELECT uuid, coalesce(role,''), coalesce(ts,''), coalesce(score,0), coalesce(snippet,''),
               coalesce(source,'local:keyword')
          FROM topic_hits WHERE topic = ?
         ORDER BY source, score ASC, captured_at DESC LIMIT ?
        """

    static let deleteTopic = "DELETE FROM topics WHERE name = ?"
    static let deleteTopicHits = "DELETE FROM topic_hits WHERE topic = ?"

    // MARK: - search log

    /// Every search, with what answered it and what came back.
    ///
    /// Worth storing rather than leaving in the UI's memory for three reasons this project
    /// has already hit: (1) which INDEX answered is otherwise invisible, and the routing
    /// rule surprises people — a 2-character query silently uses a different engine;
    /// (2) a query returning zero is the single most useful thing to be able to look back
    /// at, and it is exactly what a person forgets the wording of; (3) `top_score` and
    /// `score_spread` make a flat, non-discriminating result set visible AFTER the fact —
    /// the spread is what exposed the semantic index's ranking failure, and a log of it
    /// turns that from a live-only observation into something reviewable.
    static let createSearchLog = """
        CREATE TABLE IF NOT EXISTS search_log (
            id          INTEGER PRIMARY KEY,
            ts          TEXT NOT NULL DEFAULT (datetime('now')),
            query       TEXT NOT NULL,
            engine      TEXT NOT NULL,      -- trigram | unicode61 | vectors
            model       TEXT,               -- set for vector searches
            hits        INTEGER NOT NULL,
            ms          REAL NOT NULL,
            top_score   REAL,
            score_spread REAL               -- top minus bottom; ~0 means it could not rank
        )
        """

    static let insertSearchLog = """
        INSERT INTO search_log (query, engine, model, hits, ms, top_score, score_spread)
        VALUES (?,?,?,?,?,?,?)
        """

    static let selectSearchLog = """
        SELECT id, ts, query, engine, coalesce(model,''), hits, ms,
               coalesce(top_score,0), coalesce(score_spread,0)
          FROM search_log ORDER BY id DESC LIMIT ?
        """

    /// Queries that came back empty — the most useful rows in the table.
    static let selectEmptySearches = """
        SELECT query, engine, count(*) FROM search_log WHERE hits = 0
        GROUP BY query, engine ORDER BY count(*) DESC LIMIT ?
        """

    // MARK: - vector runs (provenance)

    /// Who built the vectors, with what geometry, and did it finish.
    ///
    /// A deliberate COPY of `import_runs` rather than a new mechanism — including its best
    /// property, stated in `selectImportRuns`: a row with `finished_at IS NULL` is a run
    /// that never completed, and is shown as interrupted rather than hidden, because a
    /// crashed build is exactly the state you want to see when the index looks wrong.
    ///
    /// It exists because provenance was previously UNFALSIFIABLE: `DBView` hardcoded
    /// "Apple NaturalLanguage · on-device · no network" and the only evidence in the db was
    /// `max(dim)` over possibly-mixed rows. Once a remote provider can write here, a UI that
    /// still claims "no network" is not merely stale — it is wrong about whether the
    /// corpus left the machine, which is the one thing an operator must be able to trust.
    static let createVectorRuns = """
        CREATE TABLE IF NOT EXISTS vector_runs (
            id            INTEGER PRIMARY KEY,
            model         TEXT NOT NULL,
            provider      TEXT NOT NULL,
            endpoint      TEXT,
            chunk_words   INTEGER NOT NULL,
            chunk_stride  INTEGER NOT NULL,
            started_at    TEXT NOT NULL DEFAULT (datetime('now')),
            finished_at   TEXT,
            events        INTEGER,
            vectors       INTEGER,
            skipped       INTEGER,
            stopped       INTEGER NOT NULL DEFAULT 0
        )
        """

    static let insertVectorRun = """
        INSERT INTO vector_runs (model, provider, endpoint, chunk_words, chunk_stride)
        VALUES (?,?,?,?,?)
        """

    static let finishVectorRun = """
        UPDATE vector_runs SET finished_at=datetime('now'), events=?, vectors=?, skipped=?,
          stopped=? WHERE id=?
        """

    static let selectVectorRuns = """
        SELECT id, model, provider, endpoint, chunk_words, chunk_stride,
               started_at, finished_at, coalesce(events,0), coalesce(vectors,0),
               coalesce(skipped,0), stopped
          FROM vector_runs ORDER BY id DESC LIMIT ?
        """

    /// Does this index contain anything a remote engine produced? One query, so the UI can
    /// stop guessing whether "on-device" is still true.
    static let selectRemoteProviders = """
        SELECT DISTINCT provider FROM vector_runs WHERE provider != 'apple'
        """

    // MARK: - db overview (the Database tab)

    /// One row, whole-db. `bytes` is the size of the source files this index covers —
    /// NOT the size of the db itself, which is stat'd from disk separately. Conflating
    /// the two would report 541 MB for a 40 MB index.
    static let selectDBOverview = """
        SELECT (SELECT count(*) FROM sessions),
               (SELECT count(*) FROM projects),
               (SELECT count(*) FROM sessions WHERE import_status='imported'),
               (SELECT count(*) FROM sessions WHERE import_status='failed'),
               (SELECT coalesce(sum(file_size),0) FROM sessions),
               (SELECT coalesce(sum(event_count),0) FROM sessions),
               (SELECT coalesce(sum(line_count),0) FROM sessions),
               (SELECT min(first_seen_at) FROM projects)
        """

    static let selectTierCounts = """
        SELECT file_tier, count(*), coalesce(sum(file_size),0)
          FROM sessions GROUP BY file_tier ORDER BY file_tier
        """

    /// Biggest sessions within one tier — the drill-down behind a clickable tier row.
    /// `file_tier` is bound, not interpolated: it is a value here, unlike ORDER BY.
    static let selectSessionsInTier = """
        SELECT s.file_path, s.session_uuid, s.agent_id, s.file_size,
               coalesce(s.event_count,0), coalesce(p.cwd, p.dir_name)
          FROM sessions s JOIN projects p ON p.id = s.project_id
         WHERE s.file_tier = ?
         ORDER BY s.file_size DESC LIMIT ?
        """

    // MARK: - tail state (live follow)

    /// Kept byte-identical to the `session_tail_state` block in schema.sql — they are two
    /// copies of one DDL on purpose: schema.sql is the reviewable source of truth, and
    /// this constant lets `session-viewer tail` self-heal a db created before the table
    /// existed (the current .data/sessions.db is exactly that) without a rebuild.
    /// `CREATE TABLE IF NOT EXISTS` is idempotent, which is why this is a TABLE and not an
    /// `ALTER TABLE sessions ADD COLUMN` — SQLite has no ADD COLUMN IF NOT EXISTS, so a
    /// column would make re-running schema.sql fail on any db that already has it.
    static let createTailState = """
        CREATE TABLE IF NOT EXISTS session_tail_state (
            file_path     TEXT PRIMARY KEY,
            byte_offset   INTEGER NOT NULL DEFAULT 0,
            file_size     INTEGER NOT NULL DEFAULT 0,
            file_mtime    INTEGER,
            lines_seen    INTEGER NOT NULL DEFAULT 0,
            last_line_at  TEXT,
            updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """

    static let selectTailState = """
        SELECT byte_offset, file_size, lines_seen FROM session_tail_state WHERE file_path = ?
        """

    static let upsertTailState = """
        INSERT INTO session_tail_state (file_path, byte_offset, file_size, file_mtime,
          lines_seen, last_line_at, updated_at)
        VALUES (?,?,?,?,?,?,datetime('now'))
        ON CONFLICT(file_path) DO UPDATE SET
          byte_offset=excluded.byte_offset, file_size=excluded.file_size,
          file_mtime=excluded.file_mtime, lines_seen=excluded.lines_seen,
          last_line_at=excluded.last_line_at, updated_at=excluded.updated_at
        """
}

// MARK: - Sorting allow-list
//
// ############################################################################
// #  DO NOT "SIMPLIFY" THIS INTO fetchSessions(orderBy: String).             #
// ############################################################################
//
// A sort column CANNOT be a bound parameter in SQLite. `ORDER BY ?` binds a *value*,
// so every row sorts by the same constant — SQLite accepts it and returns rows in an
// arbitrary order. It does not error, it silently does nothing. The column name must
// therefore be interpolated into the SQL text.
//
// The only safe way to interpolate a column is a CLOSED ALLOW-LIST: the caller picks a
// case of this enum, never supplies a string, and each case maps to a literal column
// expression written by hand below. A caller string never reaches the SQL. Untrusted
// input can only ever fail `SessionSort(rawValue:)` and be rejected (see main.swift's
// `list` subcommand) — it can never become SQL.
//
// If you replace this enum with a plain `String` parameter that gets interpolated,
// you have written a SQL injection into a tool that reads every transcript on the
// machine. `ORDER BY` is injectable in exactly the same way a WHERE clause is.
public enum SessionSort: String, CaseIterable {
    case description
    case tier
    case project
    case events
    case lines
    case size
    case started
    case mtime

    /// The literal SQL fragment this case sorts by. Every branch is a constant written
    /// into this file — nothing here is derived from a caller value. Expressions mirror
    /// `SQL.selectSessionsBase`'s select list so the sort matches what the row displays.
    var sqlExpression: String {
        switch self {
        case .description: return "COALESCE(s.description, s.session_uuid) COLLATE NOCASE"
        case .tier:        return "s.file_tier"
        case .project:     return "COALESCE(p.cwd, p.dir_name) COLLATE NOCASE"
        case .events:      return "COALESCE(s.event_count,0)"
        case .lines:       return "COALESCE(s.line_count,0)"
        case .size:        return "s.file_size"
        case .started:     return "s.started_at"
        case .mtime:       return "s.file_mtime"
        }
    }

    /// Column header / CLI header text.
    var label: String {
        switch self {
        case .description: return "description"
        case .tier:        return "tier"
        case .project:     return "project"
        case .events:      return "events"
        case .lines:       return "lines"
        case .size:        return "KB"
        case .started:     return "started"
        case .mtime:       return "modified"
        }
    }

    /// First click on a header uses this. Bigger/newer first reads as "sorted" for
    /// numbers and timestamps; A→Z reads as sorted for text.
    public var defaultDirection: SortDirection {
        switch self {
        case .description, .tier, .project: return .asc
        case .events, .lines, .size, .started, .mtime: return .desc
        }
    }

    /// `description|tier|project|…` — for CLI usage/error text, generated from the
    /// allow-list itself so it can never drift from what is actually accepted.
    public static var usage: String { allCases.map(\.rawValue).joined(separator: "|") }
}

/// The other half of the allow-list: ASC/DESC are also SQL keywords, not bindable
/// values, so they get the same closed-enum treatment as the column.
public enum SortDirection: String, CaseIterable {
    case asc
    case desc

    /// Literal keyword. Never a caller string — same reason as SessionSort.sqlExpression.
    var sqlKeyword: String { self == .asc ? "ASC" : "DESC" }

    var toggled: SortDirection { self == .asc ? .desc : .asc }

    /// Active-sort indicator for the UI headers.
    public var arrow: String { self == .asc ? "▲" : "▼" }

    public static var usage: String { allCases.map(\.rawValue).joined(separator: "|") }
}
