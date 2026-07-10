# #346 finding: `mcp_proxy` is behind an intentional substrate-tool wall

## Verdict

Stop without implementing the proposed bridge change.

The `mcp_proxy` exclusion from `substrate_tool` / `substrate_tools` is explicit
and was introduced as part of the surface's security boundary. This triggers the
unit brief's stop condition: "If the exclusion turns out to be deliberate (a
security wall, a comment saying why), STOP and write the finding instead of the
fix."

## Evidence

The file-level contract in `cmd/stewards-mcp/substrate_tool.go` labels the policy
`THE WALL (this surface is read-mostly on purpose)` and then states that only
`{"kind":"sql_fn"}` targets qualify. The implementation enforces that contract
twice:

- catalog lookup filters on `execute_target->>'kind' = 'sql_fn'`;
- call lookup filters on the same kind before validating the SQL identifiers and
  applying the non-read allowlist.

`git log -S` traces the filter and its explanation to commit `b496779` (`companion
v1.1: durable reminders, verbal approval, and the dynamic tool surface (#346)`).
That commit introduced the whole file. Its message describes the design as a
"Wall": read-class SQL functions dispatch freely, while writes require the
`arc_c_dynamic_write_allowlist`, with registration deliberately excluded. The
source comment couples the kind restriction to that same wall and to validated
schema/function interpolation.

The existing `mcp_proxy` mechanism is materially different: bridge-run workers
claim `kind='mcp_proxy'` rows from `stewards.work_queue` and execute them through
an MCP client session. Making those targets directly available to a harness seat
would therefore expand the intentionally narrow dynamic surface beyond its
documented SQL-function/allowlist boundary. Whether a revised policy should
permit that expansion needs an explicit security decision; it is not an
oversight fix under this unit's own Constitution.

## Changes deliberately not made

- no Go source changes;
- no `mcp_proxy` catalog or call-path tests, because implementing the behavior
  would violate the stop instruction;
- no changes under `extension/`;
- no live database or container use.
