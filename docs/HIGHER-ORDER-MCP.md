# Building a higher-order MCP tool

A recipe, written from building one and then researching whether that was a good idea. It
was — but not in the shape I first built it, and the difference is the whole document.

Everything here is grounded in `Topics.swift`, `MCP.swift` and `Surface.swift` in this repo,
and in sources cited inline.

---

## First: which of the three things do you mean?

"Higher-order MCP" gets used for three different mechanisms with very different support.

| shape | what it is | how well supported |
|---|---|---|
| **Surfacing** | show a subset of a fixed catalogue, chosen at runtime | **Strong.** Anthropic's Tool Search: Opus 4 accuracy 49% → 74%, context 77K → 8.7K tokens. Three live SEPs (1821, 1881, 1888). |
| **Wrapping** | re-expose someone else's tool under a new name | **Common.** Every MCP gateway does it; the spec explicitly blesses prefixing for proxies. |
| **Generation** | mint a brand-new tool schema at runtime | **Thin.** SDKs support it (FastMCP `add_tool`, Spring AI `addTool`, TS `registerTool`), but no SEP proposes it and no shipping gateway lets an end user do it. |

The instinct behind "give my saved investigation its own tool name" is **generation**. It is
the least supported of the three, and it is still worth doing *selectively* — because a
specific name genuinely helps a model choose. AWS's MCP guidance:

> "Splitting a multi-purpose tool into several specific tools provides clarity to the model
> and gives more granular results."

The recipe below is how to get that benefit without paying its full cost.

---

## The mechanism, in four parts

### 1. `tools/list` must be computed, not a constant

This is the entire trick. Everything else follows.

```swift
case "tools/list":
    let tools = mcpTools()                  // built-ins, a literal array
              + topicTools(dbPath: dbPath)  // ← derived from a table
              + upstreamTools(dbPath: dbPath)
```

### 2. Put the state outside the process

`topicTools()` reads rows and mints one `MCPTool` per row. Restarting the server loses
nothing, because the tools were never *in* the server.

This also keeps you on the right side of the spec — see **Is this legal?** below.

### 3. Dispatch generated names first, and guard the namespace

```swift
if let r = callTopicTool(name: name, ...) { return r }   // matches dig_* only
switch name { case "search_sessions": ... }              // built-ins
```

Order is only safe because creation **refuses** a colliding name:

```
trace_topic{name:"search sessions"}
→ "search_sessions" is already a built-in tool — pick another topic name
```

Reject at creation, not at call time. By call time the tool is already advertised, and a
model has already been told it exists.

### 4. Declare `listChanged: true` — and actually send it

```swift
"capabilities": ["tools": ["listChanged": true]]
```

The flag is a **promise to notify**. Advertising it without sending is worse than declaring
`false`, because the client takes it as licence to stop polling — so the tool you just
created stays invisible. Send after the response, so the client has its result before being
told to re-list:

```
id=4  Promoted "thai_search" — it now has its own `dig_thai_search` tool.
      ← notifications/tools/list_changed
```

Two caveats that cost real debugging here:

- In **2026-07-28** the notification goes to clients that opened a `subscriptions/listen`
  stream with `toolsListChanged: true` — it is not a bare broadcast any more.
- Over **Streamable HTTP** you cannot push at all: the modern era removed the standalone GET
  SSE channel, and a one-shot POST has no open stream. HTTP clients must re-list.

---

## Is this legal?

The spec says the tool set:

> **MAY** change over time … but **MUST NOT** vary per-connection or as a side effect of
> other requests on the connection.

I first read that as forbidding this entire pattern. That was wrong. The sentence comes from
[SEP-2567 "Sessionless MCP"](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567),
whose purpose is removing `Mcp-Session-Id` so servers run behind a plain round-robin load
balancer. Its author defined the key term directly:

> "'Per-connection state' means relying on information sent in previous messages on the
> connection. The auth headers are on every request, so it is stateless."

**So the test is: would a second, fresh connection — or a different replica — see the same
list?** If your tools come from a shared database, yes, and you satisfy the guarantee the
sentence exists to make. If they come from a variable in the connection handler, no.

That is the real reason for part 2. Durable state is not tidiness; it is the compliance
argument.

*(No maintainer has ruled on this exact case, so treat this as a well-supported reading, not
a quotation.)*

---

## The part that actually decides it: budget

Every tool is charged against a budget shared with **every other server the client has
connected**, and the limits are not theoretical:

| limit | source |
|---|---|
| accuracy degrades past ~30–50 tools | Anthropic guidance |
| Cursor hard-caps at 40, **silently dropping** the rest | [cursor#3369](https://github.com/cursor/cursor/issues/3369) |
| Claude Code drops tools past position 30 in multi-server setups | [claude-code#39586](https://github.com/anthropics/claude-code/issues/39586) |
| ~150 tokens per tool definition, on every turn | gateway write-ups |

`just tools` prints where you stand. On this machine, wrapping one upstream took this server
from 13 tools / ~1,667 tokens to **43 tools / ~3,167 tokens — past Cursor's cap**.

So the recipe's final part is the one most implementations skip:

### 5. Separate *creating* a thing from *spending a tool slot on it*

```
trace_topic{name:"thai search", query:"trigram"}   → topic exists, 0 new tools
dig_topic{name:"thai_search"}                      → runs it, via ONE stable tool
promote_topic{name:"thai_search"}                  → NOW it costs a slot
demote_topic{name:"thai_search"}                   → gives the slot back, keeps the topic
```

One stable `dig_topic{name}` reaches everything. It needs no slot, and it works on clients
that never re-read `tools/list` — which is most of them, historically. Promotion buys the
naming benefit for the few things you reach for constantly.

---

## Make generated tools introspectable — with ONE tool, not one per tool

A generated tool's description is assembled, not written, so "what does calling this actually
do" is a fair question. `describe_tool{name}` answers it: the full schema, and for a
`dig_<topic>` tool the row it was generated from plus the code path a call takes.

The tempting shape is `dig_esp32_description` — a describer per tool. Do not. That doubles
the tool count for every topic (10 topics → 20 tools), which is the budget problem promotion
exists to avoid. One tool taking a name costs a single slot and covers built-ins and proxied
upstream tools as well.

The general rule: **when you are about to add a tool per instance of something, add one tool
that takes the instance as an argument instead.**

## Make the generated tool earn its name

A generated tool that is just a saved argument should have been a prompt. `dig_<topic>` is
not an alias for `search_sessions{query:"trigram"}` — it **memoizes across runs**, so it
answers with fresh results *plus* everything the topic ever found, and records `runs` and
`last_hits`. A topic that used to find things and now finds none tells you the corpus moved
or the query rotted. That is information a parameterised call cannot produce.

This is the one part with real research behind it:
[CoCoDA](https://arxiv.org/abs/2605.08399) abstracts successful trajectories over primitives
into new composite tools; [Tulip Agent](https://arxiv.org/abs/2407.21778) gives agents CRUD
over their own tool library.

---

## Composition, when you actually need it

MCP has no composition primitive, so it has to live inside one tool. A topic can carry a
**source list**, and `dig_<topic>` fans out and merges:

```
trace_topic{name:"esp32", query:"ESP32",
            sources:["local:keyword", "upstream:oracle/oracle_search"]}

dig_topic{name:"esp32"}
  sources  local:keyword + upstream:oracle/oracle_search   ← composed
  by source
    local:keyword                  39
    upstream:oracle/oracle_search   5
```

It earned its place immediately: for `kru32` the local index held three identical
repo-list lines, while Oracle supplied *"Mentored turso-oracle + kru32-oracle — walked them
through codex team"* — a fact the local index does not contain.

Four things this surfaced that are easy to get wrong:

- **Partial results are the design.** A source that fails is recorded and skipped, never
  fatal. If an upstream being down costs you the local answer, composing is strictly worse
  than not composing, and people stop doing it.
- **Score scales are incomparable.** Local bm25 is negative (more negative is better);
  upstream results had no score. Sorting globally put every upstream row on top. There is no
  honest cross-source ranking, so results are **interleaved** — a fair share from each.
- **Upstream results are structured; parse them.** Splitting a JSON blob on newlines gave
  "hits" like `"source_file": "..."`. Fragments of a serialisation are not results.
- **Wrapping for composition ≠ re-exposing tools.** These are separate decisions, so
  `expose` defaults to **false**. Doing both by default put 30 Oracle tools into a client
  that already had Oracle connected directly — 13 tools became 43, past Cursor's cap. A
  compose-only upstream is reachable by topics and invisible in `tools/list`.

## What the spec does *not* give you

There is **no composition primitive**. No server-to-server RPC, no tool calling another
tool; `tools/call` is always client-initiated. SEP-1610 (declarative chaining) explicitly
excludes server-side macro tools, and SEP-1686 (Tasks, accepted) states it is not a
composition mechanism.

If you want "call A, feed into B" you have three options, none of them a new MCP tool:

1. Do it **inside one tool's implementation** — which is what `dig_<topic>` does.
2. Let the **model** chain the calls.
3. **Code execution** — the direction the ecosystem is actually moving. Anthropic reports
   150K → 2K tokens (98.7%); Cloudflare's Code Mode exposes 2,500+ endpoints in ~1,000
   tokens behind two meta-tools.

If you find yourself wanting many generated tools, option 3 is probably the real answer.

---

## Checklist

- [ ] `tools/list` computed from durable, shared state — not connection state
- [ ] Generated names guarded against built-ins **at creation**
- [ ] Names match the spec charset: `[A-Za-z0-9_.-]`, 1–128 chars, no spaces
- [ ] Deterministic order (`ORDER BY name`) — the spec asks for it so clients can cache
- [ ] `listChanged: true` **and** the notification actually sent
- [ ] Same value in `initialize` and `server/discover` — they disagreed here once
- [ ] Creation and promotion are separate operations
- [ ] A default-off promotion, and a way to see the budget (`just tools`)
- [ ] The generated tool does something a parameterised call cannot
