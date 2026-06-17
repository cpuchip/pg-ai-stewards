# Proposal: `context_search` — give every agent grep over its own durable context

**Status:** draft for council · **Date:** 2026-06-17 · for Michael
**Motivation:** Michael — "Context in a model isn't durable, BUT in our system it
is, because we curate it. What if we give every agent a tool to search its context
and inject it into things like documents?"
**Pairs with:** the context engine (compose_messages / context_state / engrams),
`expand_message`, the productivity auto-fold (`26-productivity.sql`), the presiding
covenant (D&C 121 — walls are lawful), the open inbox item "let the digesters read
our repos."

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
4. **`ancestors`** (children → parent, up my chain) — "kinda makes sense, but not
   always" (Michael). A child reaching into its parent's context is sometimes
   useful, but the parent may hold privileged material the child shouldn't see
   (a Hinge decision, evaluation criteria the child could game, a credential).
   So upward search honors a **`private` flag**: the parent marks privileged
   messages private, and `ancestors` search filters them out.
5. **`global`** (any agent's context) — powerful but a wall. One agent reading
   another's private context is a breach and a tenant-leak surface. `doc_search`
   is global *on purpose* (the pool is shared); raw-context-grep is not. **Gated
   / deferred.**

### The `private` flag
A message-level privacy marker (a `private` boolean or a reserved `private`
context-tag). Honored by **upward** (`ancestors`) and any future cross-agent
search; never needed downward (a presider may see all it ordered) or for own
context (it's mine).

**Council question — the posture:** Michael's lean is *default-visible upward +
flag-to-hide* (opt-out). The more conservative posture is *private-by-default
upward + opt-in share* (opt-out leaks the message you forgot to flag; opt-in
leaks nothing you didn't choose). Recommend opt-out for P0 ergonomics **with**
a blanket "mark this whole session private" switch for sensitive runs, and
revisit if privileged leakage shows up. This is the one real fork for council.

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

## Phasing
- **P0** — `context_search` over **own** context (`session` + `self`), curated by
  default + `include_folded` recovery flag, snippet+handle results, in the
  `context_*` grant family. Virgin-smoke: a folded message is found only with
  `include_folded`, and a found handle round-trips through `expand_message`.
- **P1** — the **lineage** scopes: `descendants` (the watch) and `ancestors`
  (private-aware), with the `private` message flag + a session-level private
  switch. Smoke: a child cannot see a parent message marked private; a parent
  sees all of a child's.
- **P2** — unify own-context grep + `pool_search` + engram search into one
  **recall** surface (the substrate as the agent's full memory), and decide the
  `global` tier under the walls.

## Why this is worth it
It's a small primitive (a function over `messages` + a tool_def) with an outsized
payoff: it turns the durable-but-passive message log into an agent's *active*
memory, gives a deterministic floor under "what did we decide," and makes
`expand_message` and the whole fold/recover loop usable. It's the natural next
expression of "the database thinks."

**Standing-capability note:** giving *every* agent a new tool is
`dominion_in_council` — ratify before building, the same gate skills and the
productivity surface went through.
