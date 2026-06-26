# Proposal: spawn bounds — structurally cap the delegation tree

**Status:** ratified (Michael, 2026-06-25). Pairs with `docs/delegation-limits.md` (the findable,
tunable reference) and the change in `extension/16-subagents.sql`.

## Why
A recursive research fan-out on a paid model spawned without a width ceiling and spent ~$50
(PR #6 = the cost backstop). Root cause: the delegation **tree** had no structural bound on *width*.
The existing guard caps **depth** (≤ 2, a `BEFORE INSERT` trigger walking `parent_work_item_id`) but
nothing limited how many children a node spawns, so a depth-2 tree could be N × N agents for
unbounded N. Same family as the chat over-gather and the cost runaway: **bound the work
structurally, not behaviorally** — a tool the agent doesn't have can't be called.

## The ratified rule
1. **Depth** stays capped (default **2**: root → child → grandchild; great-grandchild forbidden) — now
   config-driven (`subagent_max_depth`) instead of hardcoded, so it's tunable as models improve.
   Michael's "children can't spawn" is enforced per-research by the **grant model** (below), tighter
   than the global depth cap.
2. **Width** is newly capped **per pipeline**: a node may have at most `N` children, where `N` is the
   parent's pipeline override or a global default. Defaults chosen from real usage (decompose-fanout
   legitimately fans to 13; planning to 5):
   - global default `subagent_max_children` = **8**
   - `subagent_max_children.decompose-fanout` = **16** (it genuinely fans wide)
   - a research orchestrator keeps Michael's **5** (its decomposition prompt + the grant model already
     hold it there)
   Default-bounded, opt-out-loud: a pipeline raises its own ceiling **explicitly**; nothing silently
   exceeds it.
3. **Spawn is a narrow privilege (the grant model = tool removal at the family level).** `consult_subagent`
   is granted to *orchestrators*, not to *leaves*. The `subagent-*` worker families lose the grant —
   a research leaf's job is local research (read / search / summarize / return), never re-delegation.
   This is "narrow research, not a second copy of you," enforced by the tool simply not being there.

## Defense in depth (three independent guards)
| Guard | Stops the tree from… | Where |
|---|---|---|
| **depth cap** | going deeper than 2 | `trigger_enforce_subagent_depth` |
| **width cap** (new) | a node fanning past its budget | same trigger, per-pipeline |
| **grant model** | leaves spawning at all | `agent_tool_perms` |
| cost ceiling + in-flight brake (PR #6) | overspending / over-running | compose_messages + reflect_guard |

The $50 happened because only the (leaky) cost guard existed. With width + grants, the tree can't grow
unbounded; with PR #6, it can't overspend even if it does.

## Implementation (in `16-subagents.sql`, the file that owns the depth cap)
- `trigger_enforce_subagent_depth` extended: depth from `config('subagent_max_depth', 2)`; width =
  count of existing children of the parent vs `config('subagent_max_children.<parent_pipeline>')` ⟶
  `config('subagent_max_children')` ⟶ 8. Raise on breach (the hard backstop).
- Config seeds for the knobs + the decompose-fanout override.
- Grant cleanup: `consult_subagent` removed from the leaf `subagent-*` families.

The raise is the *backstop*; the grant removal is the *graceful* path (the model never offered the
tool). Tool-removal at the per-instance level (drop the spawn tool in `compose_tools` once a node is at
depth/width limit, so a still-eligible orchestrator stops being offered it after its budget) is a clean
follow-on — it needs `compose_tools` to take the work-item context (today it's family-scoped).

## Tuning as models get more powerful
All limits are `stewards.config` rows — raise `subagent_max_depth` / `subagent_max_children[.pipeline]`
when a model earns more rope. Documented in `docs/delegation-limits.md` so it's easy to find.
