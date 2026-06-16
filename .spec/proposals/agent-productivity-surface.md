# Proposal: an agent productivity surface — todos & goals as the context-management front-end

**Status:** draft for council · **Date:** 2026-06-16 · for Michael
**Pairs with:** the context engine (15a/15b — engrams, working tags, levers), `compact_context` (21), skills (24), `intents` (goals, 09).

## The idea (Michael's, 2026-06-16)

Give agents lightweight **productivity tools** — todo management and goal management — and **tie them to context** so that **completing a task auto-folds the messages/tool-calls that produced it.** The list becomes the lever by which context manages itself: while you're working a thing it stays verbatim; when you finish it, its traces collapse to a one-line engram. "Finish the work, reclaim the context it cost."

## The realization: a todo IS a context tag with a lifecycle

The substrate is ~90% built for this. The pieces exist and just aren't wired together or turned on:

| Need | Existing primitive |
|---|---|
| tag messages/tool-calls to a unit of work | **working tags** — `context_set_tag` / `context_fold_tag` / `context_mute_tag` (15b/CT2-7d) |
| auto-fold a finished unit | **`context_mute_tag`** — collapse every message bearing a tag in one move |
| a durable per-session scratchpad | **`session_facets`** — agent-written self-notes (`remember`/`forget`) |
| formal, dispatchable work | **work_items** (heavyweight) |
| goals | **intents** (per-work-item values/purpose) |

So the model: **an open todo = an active working tag** (its messages stay verbatim). **Marking it done = fold its tag** (`context_mute_tag` → those messages become a tombstone/engram). The todo list *is* the context-management surface; finishing work reclaims its context automatically. Reopen a todo → `context_expand_tag` brings it back. Reversible by construction (the lever guarantees CT2 already provides).

This is different from `compact_context` (a between-turn *judge* that compresses spent context the agent didn't curate) and from work_items (formal, dispatchable, cross-session). The productivity surface is the agent's **own, in-session, self-curated** layer — the thing it manages turn-to-turn.

## Design sketch

**A thin semantic layer over tags + facets.** Two options for storage:
- (a) **Reuse `session_facets`** with a `kind='todo'|'goal'` + a status — no new table, todos are just structured self-notes that own a tag. Leanest.
- (b) A small `session_todos (session_id, slug, title, tag, status, goal_slug, created/closed_at)` table if we want clean querying/rendering. (Lean: start with (a), promote to (b) if rendering needs it.)

**Tools (sql_fn levers, like the context levers; `_session_id`-injected):**
- `todo_add(title)` → opens a todo + mints its working tag; returns the tag so the agent stamps the messages it's about.
- `todo_done(slug|title)` → marks done **and** `context_mute_tag(tag)` — the auto-fold. (Config: auto-fold on/off, default on — Michael's "if wanted.")
- `todo_reopen` → `context_expand_tag(tag)`.
- `todo_list` → the open/done todos (rendered in the prompt like the CONTEXT PRESSURE line).
- `goal_set(text)` / `goal_check` — the session's north star (a `kind='goal'` facet); `goal_check` re-states it so a long session doesn't drift. (Heavier goals stay `intents`.)

**Rendering:** `compose_system_prompt` (or the pressure line) shows an **AGENDA** block: the active goal + open todos (one line each) + a count of folded/done ones. Cheap, always-current, and it doubles as the "what am I doing" anchor for long autonomous runs.

**The dependency (the report finding):** none of this fires unless agents have **`context_tools_enabled`** — today **0 of 39 agents** do, so the levers + `remember`/`forget` are invisible. Enabling context tools broadly (the separate ratified change) is the prerequisite; this surface is what makes them worth having.

## Other productivity tools that fit the same grain (P2+)
- **Reminders** — "surface this when X" (a deferred self-note that re-injects on a trigger/turn-count).
- **Focus mode** — one active todo; auto-fold everything not tagged to it (aggressive self-management for a long run).
- **Done-log / standup** — completed todos roll into a session summary engram (a natural compaction boundary).
- **Inter-agent handoff** — pass a todo (with its tag's engram) to another agent/subagent.

## Guardrails
- **Not work_items.** The productivity surface is session-scoped + self-curated; it does NOT dispatch, spend, or cross sessions. Promote a todo to a work_item explicitly if it needs the formal pipeline.
- **Auto-fold is reversible + togglable.** `todo_done` muting a tag is recoverable (`context_expand_tag`); a config disables auto-fold for agents that want manual control.
- **Read-only on others' context.** A todo only folds tags in the agent's OWN session (same `_session_id` ownership the context levers already enforce).

## Phasing
- **P0** — `todo_add/done/reopen/list` + `goal_set/check` over `session_facets` (option a); `todo_done` → `context_mute_tag` auto-fold (config-gated); the AGENDA render in `compose_system_prompt`. Granted like the context levers (gated on `context_tools_enabled`). virgin-smoke: open→tag→done→folded→reopen→restored.
- **P1** — focus mode + reminders + the done-log roll-up.
- **P2** — promote-todo-to-work_item; inter-agent handoff.

## RATIFIED + BUILT 2026-06-16 (P0 shipped, deployed live)

Council/ask-tool ratify: **auto-fold ON** by default (reversible/togglable);
**single active todo** (auto-stamp; `todo_focus` to switch); todos **separate from
work_items** in P0 (promote = later); granted to **all context-enabled agents**.
Storage = a purpose-built `session_todos` + `session_goals` (the `session_facets`
rec was wrong — that table is persona/room scoping, not a notes store).

**Built (`extension/26-productivity.sql`):** the tables + `todo_autofold_on_done`
config + `todo_slugify` + the 6 levers (`todo_add/done/reopen/focus/list`,
`goal_set`) — each wrapping the existing working-tag tools (`todo_add` →
`context_set_tag`; `todo_done` → `context_mute_tag`; `todo_reopen` →
`context_expand_tag`) so the fold machinery is reused, not rebuilt — + `render_agenda`
(the AGENDA block) + the tool_defs. `compose_tools` re-authored (later-file-wins,
carrying 24's body) to surface `todo_/goal_` on `context_tools_on` agents;
`compose_system_prompt` (09) calls `render_agenda` (late-bound). The deny-* agents
get `todo_*`/`goal_*` grants via the `context-tools-on` overlay.

**Proven:** virgin-smoke **OK 12** (00→26: goal_set + todo_add sets the active
working_tag, a tagged message auto-folds to `muted` on `todo_done`, `todo_reopen`
restores it to `verbatim`); clobber-check PASS 3/0; deployed live — research +
gamemaster + librarian see the tools, the judge + `propose_prompt_change` stay off.
P1 (focus mode, reminders, done-log) + P2 (promote-to-work_item, handoff) remain.

## Open questions for council
1. Storage: structured `session_facets` (a) vs a `session_todos` table (b)? (Lean: a, then b if needed.)
2. Auto-fold default on or off? (Michael: "if wanted" → on, config-togglable.)
3. Does the AGENDA block always render, or only when there are open todos? (Lean: only when non-empty — zero cost otherwise.)
4. Goals here vs `intents`: keep the lightweight session-goal separate from the formal intent? (Lean: yes — session goal is ephemeral, intent is the durable north star.)
