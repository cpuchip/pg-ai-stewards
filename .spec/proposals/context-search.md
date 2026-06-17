# Proposal: `context_search` — give every agent grep over its own durable context

**Status:** ✅ RATIFIED (council w/ Michael, 2026-06-17) · **Date:** 2026-06-17 · for Michael
**Motivation:** Michael — "Context in a model isn't durable, BUT in our system it
is, because we curate it. What if we give every agent a tool to search its context
and inject it into things like documents?"
**Pairs with:** the context engine (compose_messages / context_state / engrams),
`expand_message`, the productivity auto-fold (`26-productivity.sql`), the presiding
covenant (D&C 121 — walls are lawful), the open inbox item "let the digesters read
our repos."

## Ratified (council w/ Michael, 2026-06-17)

1. **P0 = own + descendants + the private wall.** Search own context
   (`session` + `self`) AND `descendants` (a presider searching the subagents'
   work it ordered — the watch), plus the session-level `private` flag. Upward
   (`ancestors`) and per-message private → P1.
2. **Upward is private by default.** A child cannot grep an ancestor's context
   unless the ancestor opts in to share — the conservative posture (opt-in leaks
   nothing you didn't choose; opt-out leaks the message you forgot to flag). [P1]
3. **A session can wall itself `private`** — searchable only by itself, invisible
   to everyone *including its own parent*. The wall **beats the watch**: a private
   child cannot be searched even by the presider that spawned it. Manual flag in
   P0 (no auto-private — no sensitive workload yet; there for when it's needed).
4. **The wall is absolute.** A parent cannot compel a child's private wall down
   (D&C 121 — walls are lawful; force where persuasion would do is a breach).
5. **No auto-private in P0** — local-vs-cloud routing and privacy stay independent
   levers. **P1 future want:** a `sensitive` intent/agent flag that wires the whole
   sensitive path in one switch — force local-model dispatch **and** force
   `private`, so sensitive work never egresses to cloud *and* never leaks across
   sessions.

## The insight

A model's context window is a lossy sliding pane — the start of a long
conversation falls off, and our own compaction engine deliberately folds spent
material away. The model cannot scroll back. But our agents sit on a database
where **every message is a durable row** (`stewards.messages`). The thing a human
dev does constantly with a chat log — Ctrl-F the history — the model structurally
cannot do, and we can simply hand it to them.

This is the substrate thesis turned into a tool: context that compounds because
it's curated and queryable, not a window that evaporates.

## The gap (nothing existing is this)

| Surface | What it does | Why it's not this |
|---|---|---|
| `investigate_session` | LLM Q&A over a session | expensive, and itself lossy (an LLM rummaging) |
| `doc_search` / `pool_search` | search the **published** pool | the curated *output*, not my raw thinking |
| `expand_message` | un-fold a specific message | you must already know *which* message |

The missing primitive is a **cheap, deterministic, exact-text search over my own
durable messages**. It's also the *locator* that makes `expand_message` usable:
`context_search` finds the message, `expand_message` fetches the one you chose.
Deterministic grep beats an LLM trying to remember — the same "build the oracle
first" lesson as verify-quotes.

## The primitive: `context_search`

A SQL function + `tool_def` (in the `context_*` family already enabled on most
agents), roughly:

```
context_search(
    pattern        text,                 -- regex / ILIKE over message content
    scope          text  default 'session',
    include_folded boolean default false,
    limit          int   default 20
) -> rows of { message_handle, role, ts, snippet, context_state, session }
```

Returns **snippets + handles**, not whole messages (see "don't re-bloat" below).
The agent reads the snippets, then `expand_message`s the one it wants — e.g. to
quote its own earlier finding verbatim into a document it's writing.

### Curated by default (honoring "because we curate it")
Default search hits the **visible/curated layer** (verbatim + pinned, plus
compressed summaries). It skips muted/folded bodies so the first grep isn't 40
lines of dispatch noise. The agent learns to trust it.

### `include_folded` — the recovery flag (Michael's add)
Set `include_folded=true` and the search *also* reaches the **muted / compressed
full bodies** — the things the agent (or the compaction engine, or a `todo_done`
auto-fold) folded away. This is the recovery path: *"I muted something earlier
that I now want back — find it so I can re-open it."* Folded hits are marked
`[FOLDED]`/`[MUTED]` in the result so the agent knows it's reaching into the
folded layer, and can `context_expand` / `expand_message` to restore it. This
closes a loop with the productivity surface: `todo_done` auto-folds a tag's
context; `context_search include_folded` → `context_expand` brings it back when
the work reopens.

## The scope ladder (the walls — D&C 121)

Whose context an agent may grep is the load-bearing decision. It maps onto the
presiding covenant: walls are lawful; a presider watches what it ordered; force
where persuasion would do is a breach.

1. **`session`** (this session) — always. Default.
2. **`self`** (all *my own* sessions, by agent_family / persona) — my own durable
   memory across time. A long-lived persona (a librarian, an analyst) accumulates
   many sessions; this is its hippocampus.
3. **`descendants`** (parent → children, my spawn tree) — "watch what you order,
   given eyes." A steward gripping its own delegated subagents' work *is* the
   watch. **Allowed.**
4. **`ancestors`** (children → parent, up my chain) — **private by default
   (ratified); P1.** A child may reach into a parent's context only for what the
   parent has opted to share; the parent's context is otherwise walled (it may hold
   a Hinge decision, evaluation criteria the child could game, a credential).
5. **`global`** (any agent's context) — powerful but a wall. One agent reading
   another's private context is a breach and a tenant-leak surface. `doc_search`
   is global *on purpose* (the pool is shared); raw-context-grep is not. **Gated
   / deferred.**

### The privacy model (ratified)
Two levers:
- **Session `private` flag (P0, manual).** A session marks *itself* private and is
  then searchable only by itself — invisible to all other sessions, **including its
  own parent** (the wall beats the watch). The security primitive: sensitive work
  (a steward dispatching to a local, non-cloud model) walls its context so no other
  agent — least of all a cloud-model parent — can grep it. No auto-private in P0;
  the flag is set explicitly (there for when it's needed).
- **Upward private-by-default + per-message `private` (P1).** `ancestors` search
  sees only what a parent opted to share; the parent can also mark individual
  messages `private` to wall specifics while sharing the rest.

Downward (`descendants`) needs no flag — a presider may see the non-private work it
ordered. Own context is always fully searchable (it's mine). **The wall is
absolute:** no parent can compel a child's `private` down (D&C 121).

## Provenance ≠ truth (the honesty guardrail)

`context_search` gives **provenance** — *what I actually said / decided N turns
ago* — not **truth** — *that it was correct*. It's perfect for "did I already
conclude X?" and "pull my own earlier finding into this doc." It is **not** a
substitute for source verification: my 40-turns-ago self could have confabulated,
and grep faithfully resurfaces the confabulation. So: inject-with-provenance for
self-recall; for an external claim (a scripture, a source, a number) the **source**
is still the oracle, not my memory of it. Read-before-quoting is unchanged — this
just makes "what did *we* decide" as checkable as "what does the source say."

## Don't re-bloat the window

A grep that injects 50 whole messages re-clogs the very context the compaction
engine works to keep lean. So:
- return **snippets + handles**, not full bodies;
- let the tool result **ride the existing context engine** (interceptable,
  foldable, taggable) like any other tool output;
- compose with `expand_message`: grep = the pointers, expand = the *one* fetch you
  chose. The tool should *feed* compaction, not fight it.

## Reuse map (most of it exists)
- **The store** — `stewards.messages` (content, role, ts, `context_state`,
  `context_tags`, session lineage).
- **Lineage resolution** — the spawn tree / `context_resolve_handle` infra already
  resolves parent↔child sessions.
- **The fold/restore pair** — `context_state` (verbatim/muted/compressed/pinned)
  + `context_expand` / `expand_message`.
- **The grant family** — `context_tools_on` (just enabled on ~36 agents); the new
  tool joins it, gated the same way.
**New bits:** the `context_search` function + `tool_def`; the `include_folded`
search path; the `private` flag + the `ancestors`/`descendants` scope resolution.

## Phasing (ratified)
- **P0 — own + descendants + the private wall.** `context_search` over `session` +
  `self` + `descendants` (the watch); curated by default + `include_folded`
  recovery; the manual session-level `private` flag that `descendants` search
  respects (a private child is invisible even to its parent); snippet+handle
  results in the `context_*` grant family. Virgin-smoke: a folded message is found
  only with `include_folded`; a found handle round-trips through `expand_message`;
  a parent finds a normal child's message but NOT a private child's.
- **P1 — upward + finer privacy + the sensitive switch.** `ancestors` (child →
  parent, **private by default**, opt-in share) + per-message `private` + the
  **`sensitive` intent/agent flag** (forces local-model dispatch + `private`
  together — the noted future want). Smoke: a child sees an ancestor message only
  when shared.
- **P2 — the recall surface.** Unify own-context grep + `pool_search` + engram
  search into one **recall** tool (the substrate as the agent's full memory), and
  decide the `global` tier under the walls.

## Why this is worth it
It's a small primitive (a function over `messages` + a tool_def) with an outsized
payoff: it turns the durable-but-passive message log into an agent's *active*
memory, gives a deterministic floor under "what did we decide," and makes
`expand_message` and the whole fold/recover loop usable. It's the natural next
expression of "the database thinks."

**Standing-capability note:** giving *every* agent a new tool is
`dominion_in_council` — **RATIFIED 2026-06-17** (council w/ Michael), cleared to
build P0; same gate skills and the productivity surface went through.
