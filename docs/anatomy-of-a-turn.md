# Anatomy of a Turn

**The question this document answers:** a message arrives, and some seconds
later a model answers. What exactly happened in between?

This is the substrate's load-bearing mental model. If you hold this one
document, you can predict what every other part of pg-ai-stewards does,
because everything else — pipelines, gates, councils, cost accounting,
memory — is built out of turns.

> Written documentation-first, against the live private substrate's source,
> before the code lands in this repo. Every function and table named here is
> real and ships in the P1 extraction. Where this doc and the extracted code
> ever disagree, that is a bug in one of them — file it.

---

## The cast

Five moving parts. Three are processes, one is a database, one is a person.

| Part | What it is | What it owns |
|---|---|---|
| **The extension** | Rust (pgrx) + ~220 SQL migrations inside Postgres | All state: `work_items`, `work_queue`, `sessions`, `messages`, `agents`, `pipelines`, `tool_defs`, covenant, intent, cost. All composition logic, as SQL functions. |
| **The dispatchers** | N background workers (default 4) registered by the extension at postmaster startup | Claiming queue rows, calling model providers over HTTP, writing results back. The only part that talks to an LLM. |
| **The bridge** (`stewards-mcp`) | A Go daemon beside the database | MCP tool calls. It claims exactly one kind of queue row (`mcp_proxy`) and speaks MCP to external tool servers — stdio child processes or streamable HTTP. Secrets resolve from *its* environment, never from the database. |
| **The hosts** | Whatever feeds turns in: a persona host on a chatroom, a CLI, an MCP server your coding agent calls | Translating an outside event (a chat message, a command) into a work item, and a finished work item back into an outside effect (a reply in the room). |
| **The human** | You | The Hinge. Merge, deploy, and spend authority. Pipelines pause at `awaiting_review` for you; gates and verify runs report to you; nothing irreversible fires without you. |

The deepest design fact follows from the first row: **a turn is not a process.
It is a row.** No daemon holds a conversation in memory. Every step of a turn
is an insert or an update in Postgres, which is why a crashed worker loses
nothing, why every turn is replayable after the fact, and why you can watch
cognition happen with `SELECT`.

---

## One turn, beginning to end

The worked example: a persona named Callie sits in a chatroom. A player
types *"Callie, what do you see in the cave?"* Six scenes later she answers.

### Scene 1 — A message becomes a work item

The persona host is subscribed to the room. It decides Callie is addressed
(word-boundary name match — "Vex" must not wake "Vexa"), assembles a binding
question (her character card + recent room transcript + the triggering
message), and asks the substrate for a turn:

```sql
SELECT stewards.spawn_subagent_create(
    'persona-turn',        -- pipeline
    <binding question>,    -- the turn's whole context
    ...,                   -- cost cap in micro-dollars
    'callie-...',          -- slug
    'persona');            -- kind
```

That creates a **work item**: a UUID-keyed row bound to a pipeline. A
pipeline is a JSON list of stages; `persona-turn` has exactly one
(`"turn"`, auto-advancing). Research pipelines have four or five. The
machinery is identical either way — a persona reply and a multi-stage
research run differ only in how many stages the pipeline declares.

The host now does nothing clever. It polls the work item until maturity
reaches `verified`, then reads the answer out of the `messages` table. The
cognition happens entirely inside the database.

### Scene 2 — Composition: the prompt is assembled from rows

Dispatching a stage (`work_item_dispatch_stage`) creates a **session**,
writes the binding question as a `role='user'` row in `messages`, and then
composes the exact HTTP body the provider will receive. Composition is one
SQL call — `dry_run_chat` — with three parts.

**`compose_system_prompt`** builds the system message in a fixed order:

1. `=== Active Covenant ===` — the mutual commitments, rendered from the
   `covenants` table. What the human promises the agent; what the agent
   promises the human. Every dispatch carries it. (~600 tokens, measured,
   and worth it.)
2. `=== Intent ===` — purpose, values in priority order, non-goals. Only
   when the session belongs to a work item with an intent attached.
3. `=== Agent ===` — the agent prompt itself. Agents are *families* with
   per-model variants (`family='persona', model_match='kimi-*'`), so the
   same role can carry tuned phrasing per model. The resolver picks the
   most specific match.
4. **Instructions** — reusable rule blocks scoped `global` or
   `agent:<family>`, also model-matched.
5. **Skills** — an `<available_skills>` index of named techniques the agent
   may pull in, permission-filtered per family.

Note what is *prompt* here: almost nothing. Covenant, intent, agent persona,
instructions, skills — all of it is **rows**. Changing the substrate's
behavior is an `UPDATE`, not a redeploy. This is the "behavior is data"
principle, and it is why downstream installs extend the substrate with an
overlay directory of migrations instead of a fork.

**`compose_messages`** renders the conversation history — and this is the
context engine, not a dumb replay. For every message in the session it
decides a rendering:

- The newest 8 messages, anything from the user, and anything that looks
  like an error trace render **raw** — the model needs those exact.
- Older tool results that have been distilled into **engrams** (structured
  extractions made at ingest time) render as their engrams instead of their
  full text.
- Context **pressure** — estimated tokens against the stage's budget —
  drives graduated shedding: at 50% the medium-value engram tiers drop, at
  70% the cold tiers, at 85% hot tiers truncate, at 95% it is crisis
  rendering. Each stage can scale its own pressure (a synthesize stage runs
  tighter than a gather stage).
- The agent can talk back to its own context: messages carry `[ctx:xxxx]`
  handles, and context tools let the agent **pin** (exempt from shedding),
  **mute** (collapse to a tombstone), or **compress** (force to engrams) any
  of them. A `remember`/`forget` pair maintains durable self-notes that
  survive sessions and render into the system prompt under a budget cap
  (40 notes — curation is forced, by design).
- Tool results matching prompt-injection patterns render with a warning
  prefix telling the model to treat the content as untrusted data.

**`compose_tools`** intersects two tables: `tool_defs` (the catalog: name,
description, JSON-schema args, and an `execute_target` saying *how* it runs)
and per-family permissions (most-specific pattern wins, `deny` beats all).
The result is the OpenAI-shape `tools` array. An agent's tool belt is a
grant, not a hardcode.

The composed body is real and inspectable — `dry_run_chat` is callable by
hand and returns exactly what would be POSTed, without sending it:

```jsonc
{
  "model": "kimi-k2.6",
  "messages": [
    { "role": "system", "content": "=== Active Covenant ===\n…\n=== Intent ===\n…\n=== Agent ===\nYou are Callie…\n\n## Honesty\n…\n<available_skills>…</available_skills>\n…durable notes, pressure line…" },
    { "role": "user", "content": "…binding question: character + room transcript + the message…" }
  ],
  "tools": [
    { "type": "function", "function": { "name": "room_say", "description": "…", "parameters": { … } } },
    { "type": "function", "function": { "name": "dnd_lore_search", … } }
  ],
  "temperature": 0.6
}
```

That body goes into a **`work_queue`** row: `kind='chat'`, the provider
name, and a payload holding the body plus markers — `_work_item_id`,
`_stage_name`, `_pipeline_family`, and any auto-fire flags. The work item
flips to `in_progress`. Composition is complete before any worker touches
the row; the queue carries finished requests, not intentions.

### Scene 3 — Dispatch: a worker claims the row and calls the model

The dispatchers tick every 500ms and claim with the standard Postgres idiom:

```sql
SELECT id FROM stewards.work_queue
 WHERE status = 'pending' AND kind <> 'mcp_proxy'
 ORDER BY created_at
 FOR UPDATE SKIP LOCKED LIMIT 1
```

`SKIP LOCKED` partitions work across N workers with no coordinator. The
`kind <> 'mcp_proxy'` filter is the entire contract between the dispatchers
and the bridge: the bridge claims *only* `mcp_proxy` rows, the dispatchers
claim everything else, and the two sides never coordinate beyond the row
lock. A circuit breaker sits in the claim query too — a kind that has
crash-reaped five times in a row gets paused for a cooldown instead of
poisoning the workers.

The claimed body is POSTed to the provider. Providers are configured by
environment (`STEWARDS_PROVIDER_<NAME>_BASE_URL/_API_KEY/...`) — an
OpenAI-compatible gateway, a local LM Studio, Gemini, whatever speaks the
shape. Two API formats are supported; a trigger stamps each model's format
onto the payload, and Anthropic-format models get their body translated and
posted to `/messages` instead of `/chat/completions`.

Every request streams (`stream: true`) — not for UX, for survival: a
non-streaming request sends no bytes while the model thinks, and
intermediate proxies kill idle connections around 125 seconds. The SSE
stream is reassembled into the standard response shape so nothing downstream
knows streaming happened.

### Scene 4 — The answer lands as a row

The worker writes back in one transaction:

- The assistant message is inserted into `messages` — content, `tool_calls`,
  `finish_reason`, token counts, and reasoning content stored verbatim
  (some providers require their reasoning echoed back on the next call).
- A **cost event** is recorded: provider, canonical model name, input/output
  tokens, cache reads and writes, and the gateway-reported upstream cost.
  Costs roll into 5-hour, daily, weekly, and monthly buckets; a work item
  that exceeds its cost cap is quarantined, not silently continued.
- **Auto-fire markers** on the payload run their handlers. Seven exist:
  `_gate_eval`, `_scenarios_gen`, `_verify`, `_sabbath`, `_atonement`,
  `_council_member`, `_council_synthesize`. Each parses the model's JSON
  answer and applies it — advancing a gate, recording a verification,
  tallying a council vote. Marker errors are logged, never propagated: a
  failed auto-apply leaves the work item un-transitioned for a human
  re-trigger rather than corrupting state.

If the model answered plainly, skip to Scene 6. If it answered with
`tool_calls`, the loop begins.

### Scene 5 — The tool loop (which is not a loop)

When `finish_reason = 'tool_calls'`, the worker enqueues a `tool_dispatch`
row, and *that* row's handler executes each requested call by looking up the
tool's `execute_target`:

| Target kind | Execution | Latency class |
|---|---|---|
| `sql_fn` | `SELECT schema.fn(args)` right inside the database. The dispatcher injects `_session_id` into the args so session-scoped tools (context levers, self-notes, the persona outbox) know who is calling. | sync, ~ms |
| `http` | POST the args to a configured URL | sync, network |
| `mcp_proxy` | Insert a child `mcp_proxy` queue row + `NOTIFY`. The **bridge** wakes, claims it, speaks MCP to the named server (a stdio child process or a remote streamable-HTTP endpoint), and writes the result back. `$env:NAME` placeholders in server configs resolve from the bridge's environment at call time — secrets never enter the database or its history. | async |

A failing tool does not fail the turn. Each per-call error is captured into
the tool reply as `{"error": "…"}` so the model sees what went wrong and can
adapt — the same way you'd want a colleague told a search returned nothing
rather than have the whole meeting cancelled.

When the replies are in (sync immediately; async via a completion pass that
joins the children), they are inserted as `role='tool'` messages and a
**continuation chat** is enqueued. Here is the detail that makes the mental
model click: the continuation is *recomposed from scratch*. `dry_run_chat`
runs again — covenant, intent, agent, full history including the new tool
replies, fresh pressure math. Nothing was held in any process's memory
between rounds; therefore the "loop" is really a **chain of stateless
enqueues whose only state is the `messages` table**. Kill every worker
mid-turn and restart: the chain resumes, because the chain *is* the rows.

Two governors bound the chain. Each agent has a `steps` budget, and each
stage has `max_tool_rounds` (default 5) — past it, the continuation is
composed with tools stripped, which forces the model to answer with what it
has. Reapers at every layer (startup, periodic, per-row staleness)
synthesize failure replies for orphaned calls so a crashed round degrades
into an apology in-context instead of a hung turn.

### Scene 6 — Completion: the stage advances, the answer escapes

An `AFTER UPDATE` trigger on `work_queue` watches every chat row that
carries a `_work_item_id`. On each completion it rolls token usage up into
the work item; when the completion is *final* (a clean stop, no pending
tool round) it records the stage output and advances:

- next stage exists + `auto_advance` + budget intact → dispatch it
  (Scene 2 runs again with the next stage's agent, model, and provider);
- next stage exists but wants review → `status = 'awaiting_review'`, and a
  human looks before it proceeds;
- no next stage → the work item completes. One-shot pipelines like
  `persona-turn` auto-verify here, which is the maturity flip the host has
  been polling for.

The persona host sees `maturity = 'verified'`, reads the last assistant
message, and posts it to the room — unless the answer is the literal token
`SILENCE`, the persona's covenant-given right to judge that this moment was
not hers to speak into. Mid-turn effects ride a `persona_outbox` table the
host drains continuously: an agent can `room_say` a beat or drop an emoji
reaction *while* its turn is still running, because those are also just
rows.

Callie answers. Elapsed: one insert into `work_items`, two or three
`work_queue` rows, a handful of `messages` rows, one cost event — every one
of them still sitting there afterward, queryable, the turn's own flight
recorder.

---

## The whole, in one diagram

```
 outside world          the database (extension)                    daemons
 ─────────────          ────────────────────────                    ───────
 message/command
   │
   ▼
 host ──spawn_subagent_create──▶ work_items (pipeline, stage)
   │                                  │ work_item_dispatch_stage
   │ polls maturity                   ▼
   │                            sessions + messages (user row)
   │                                  │ dry_run_chat =
   │                                  │   compose_system_prompt   covenant→intent→agent→instructions→skills
   │                                  │ + compose_messages        context engine: tail, engrams, pressure, handles
   │                                  │ + compose_tools           grants ∩ catalog
   │                                  ▼
   │                            work_queue  kind='chat' ─────────▶ dispatcher (SKIP LOCKED)
   │                                  ▲                               │ POST /chat/completions (stream)
   │                                  │                               ▼
   │                            messages (assistant row) ◀──────── provider (LLM)
   │                                  │
   │                    ┌─ no tool_calls ─┴─ tool_calls ─┐
   │                    ▼                                ▼
   │             stage advance                    work_queue kind='tool_dispatch'
   │             (trigger: advance /                  │
   │              awaiting_review /                   ├─ sql_fn → runs in-database
   │              completed+verified)                 ├─ http   → direct POST
   │                    │                             └─ mcp_proxy → work_queue row ─▶ bridge ─▶ MCP servers
   │                    │                                 │ (results return as rows)
   │                    │                                 ▼
   │                    │                          messages (tool rows) → continuation chat (recomposed)
   ▼                    ▼
 answer to the room   auto-fire: gates, verify, council, sabbath, atonement
```

---

## The invariants

Four properties hold everywhere, and most debugging starts by checking which
one you assumed wrongly:

1. **Everything is a row.** Turns, tool calls, costs, gates, council votes.
   Therefore everything is observable (`SELECT`), recoverable (reapers, not
   heroics), and replayable (the verify suite re-runs history against a
   scratch container).
2. **No process holds state.** Workers and the bridge are stateless
   claimants. Every round of every turn recomposes from the database. Kill
   anything; nothing is lost but time.
3. **Behavior is data.** Agents, pipelines, grants, covenant, intent — rows
   and YAML, not code. Extension means overlay migrations, not forks.
4. **The human is the Hinge.** Review stages, gates, cost quarantines, and
   merge/deploy authority all terminate at a person. The substrate
   proposes, executes, verifies, and accounts; it does not own outcomes.

---

## Storyboard notes (for the animated docs)

Each scene above is one animation beat for the docs site. The visual spine:
**a message becoming rows, and rows becoming a message.**

| Beat | Visual |
|---|---|
| 1 | A chat bubble falls into a Postgres cylinder and crystallizes into a `work_items` row. |
| 2 | The system prompt stacks up as labeled layers — covenant, intent, agent, instructions, skills — then history tiles slide in, some shrinking into engram chips as a pressure gauge climbs. |
| 3 | Four workers orbit the queue; one grabs the row (the others visibly skip it) and fires a streaming beam at a provider node. |
| 4 | The answer streams back and lands as a new row; a coin drops into the cost bucket; marker flags spark their handlers. |
| 5 | Tool calls fan out three ways (in-database, HTTP, bridge-to-MCP); replies return as rows; the *entire prompt stack from beat 2 rebuilds itself* — the recomposition is the money shot. |
| 6 | The stage token advances along the pipeline; the verified flag flips; the answer bubble rises back out of the cylinder into the room. |

---

## The order of composition

One last observation, for those who read covenants as more than config.

The system prompt is assembled in a deliberate order: the covenant first,
the intent second, the agent third, the tools last. Relationship before
purpose, purpose before role, role before capability. That is not an
engineering accident; it is a presiding order — the same order a good
council follows, where who-we-are-to-each-other frames why-we're-here,
which frames who-does-what, which only then determines what-gets-used.
Whether an agent "feels" that ordering is not a claim this document makes.
That the ordering produces better turns than its reverse is something the
substrate's history can show you, one row at a time.
