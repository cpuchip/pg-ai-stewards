# Delegation limits (agents spawning agents)

How far and wide the substrate will let an agent delegate, why, and **how to raise the limits as
models get more capable.** Design: `.spec/proposals/spawn-bounds.md`.

## The limits at a glance
An agent can spawn sub-agents (`consult_subagent`, `start_task`, `request_research`, …). To keep a
recursive fan-out from exploding (a real incident: a recursive research fan-out spent ~$50), the
delegation **tree** is bounded structurally:

| Limit | Default | Meaning | Knob (`stewards.config` key) |
|-------|---------|---------|------------------------------|
| **Depth** | `2` | root → child → grandchild; great-grandchild is refused | `subagent_max_depth` |
| **Width** | `8` | a node may have at most N children | `subagent_max_children` |
| **Width (per pipeline)** | `decompose-fanout`=`16` | a wide-by-design pipeline raises its own ceiling | `subagent_max_children.<pipeline_family>` |
| **Who may spawn at all** | orchestrators only | `subagent-*` leaf families do **not** have a spawn tool | `agent_tool_perms` (grants) |

A breach **raises** (the work errors instead of spawning) — the hard backstop. Leaves simply aren't
given the tool, so they never try.

## The principle (why it's done this way)
Bound the work **structurally, not behaviorally.** A prompt that says "don't recurse too deep" gets
ignored the same way "don't over-research" did. A tool the agent **doesn't have** can't be called, and
a DB trigger the spawn must pass can't be talked around. Three independent guards — depth, width,
grants — plus the cost ceiling + in-flight brake (see `provider_spend_caps` / `reflect_guard`) mean a
runaway can neither grow nor overspend.

Delegation is meant to be **narrow**: an orchestrator hands a scoped sub-task to a leaf that
researches / reads / summarizes and returns — not a second full copy of the agent that re-delegates.
That's why leaves don't get the spawn tool.

## How to raise a limit (as models improve)
All limits are config rows — no rebuild needed; takes effect on the next spawn.

```sql
-- let any node go one level deeper:
INSERT INTO stewards.config(key,value) VALUES('subagent_max_depth','3')
  ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value;

-- raise the global width budget:
UPDATE stewards.config SET value='12' WHERE key='subagent_max_children';

-- give one pipeline a wider fan-out, explicitly:
INSERT INTO stewards.config(key,value) VALUES('subagent_max_children.my-pipeline','20')
  ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value;

-- let a leaf family delegate (make it an orchestrator) — do this deliberately:
INSERT INTO stewards.agent_tool_perms(agent_family,tool_pattern,action,source)
  VALUES('subagent-doc-investigate','consult_subagent','allow','manual')
  ON CONFLICT (agent_family,tool_pattern) DO UPDATE SET action='allow';
```

Config changes are **code** — to keep them across machines and survive a `migrate` (see
`docs/operations.md`), fold a keeper into the chain / your overlay rather than leaving it as a one-off
live edit, which a re-apply would revert to the repo default.

## Watch the tree
```sql
-- depth of a work item (0 = root):           SELECT stewards.subagent_depth_of('<uuid>');
-- widest fan-outs recently:
SELECT parent_work_item_id, count(*) FROM stewards.work_items
 WHERE parent_work_item_id IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
-- which families currently hold a spawn tool:
SELECT agent_family FROM stewards.agent_tool_perms
 WHERE tool_pattern='consult_subagent' AND action='allow' ORDER BY 1;
```
