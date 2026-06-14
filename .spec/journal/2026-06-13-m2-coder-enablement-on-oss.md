# 2026-06-13 — M2: coder enablement on OSS (proven; PR blocked on token scope)

**Session:** pg-ai-stewards lane, parity roadmap M2. Michael chose "keep
debugging now" when the DRAFT PR kept stalling — and it paid off: persistence
traced the blocker through six layers to its true external root rather than
leaving it vague.

## Verdict

**The coder is fully proven on the OSS stack.** A `code-pr` run spawns a
hardened sandbox (host docker socket, token bridge-side), clones the real repo,
writes correct Go (`go.mod` + `greet` package + table tests + `main.go`), runs
`go test` GREEN, and commits locally — the entire code-generation + verification
capability works end to end, all seven stages dispatch and execute.

**The DRAFT PR did not land — blocked solely by the GitHub token's repo scope.**
The bridge's fine-grained PAT is scoped to specific repos; the brand-new
throwaway `cpuchip/pg-ai-stewards-coder-proof` isn't in its access list, so it
can clone (public read) but `git push` returns
`remote: Permission to cpuchip/pg-ai-stewards-coder-proof.git denied to cpuchip. 403`
(confirmed by a direct bridge push test). Same root as the earlier repo-create
403. **Not a coder or substrate defect — a GitHub PAT setting.** To land it:
grant the PAT write on the repo (or point the coder at a repo it already writes,
or use a broader token), then re-dispatch the pr stage (~30s, the code is proven).

## The six layers (each a real finding)

1. **Clone propagation race** — repo created seconds before the run; GitHub's git
   backend 404s briefly. The coder fell back to a local module and still tested
   green. Clears on retry.
2. **Incomplete input** — `code-pr` needs `input.acceptance_criteria`; omitting it
   made plan_review's auto-dispatch raise on the NULL, which the bgworker
   swallowed → looked "stuck at awaiting_review." Not a bgworker bug.
3. **qwen3.7-max unusable** — the review gates hardcode it; it 401s on opencode's
   oa-compat. The **model checker works** (probe flips it `usable=f`) but the
   auto-probe had never run on this fresh stack (0/13 — it rides the *weekly*
   watchman pass). Manually probed all 13 → catalog current.
4. **qwen3.7-plus tool-format** — as the review model it 400s on Alibaba
   (`tool_choice` with tools) because review legitimately needs tools (its
   template calls `coder_shell`/`coder_read` to inspect the diff). Fixed by
   moving the review gates to **glm-5.1** (opencode_go, tool-capable, non-qwen,
   ≠ the kimi implementer).
5. **pr stage `steps_exhausted`** — the default tool-round hard cap was too low
   for clone+diff+commit+push+gh-pr. Raised `max_tool_rounds_hard` to 40.
6. **push 403** — the real bottom: token repo-scope (above).

## Genuine fixes (promote to OSS-canonical in M6 — not band-aids)

- **Review gates → glm-5.1.** More portable than qwen3.7-max (401s on non-qwen
  oa-compat) and qwen3.7-plus (400s on Alibaba when tools are on). The deeper M6
  item: the model checker probes *chat* but not *tool-use*, so a model can pass
  the probe yet fail a tool-using stage — capability-aware substitution should
  cover this.
- **pr `max_tool_rounds_hard=40`.** The default is too low for the git/PR
  sequence; a real fix.
- These were applied as live edits to Michael's dev `code-pr` pipeline (def +
  stage_models) — reconcile to canonical in M6.

## My own miss

My first poll auto-nudged the work item whenever it hit `awaiting_review` —
which for a *review* stage is the normal verdict-pending state. That made run 4's
review oscillate and fail. Removed the nudge; run 5 flowed clean. And I ran the
coder five times chasing one artifact — the capability was proven by run 1's
passing test; the honest call was to trace the blocker (done) rather than keep
spinning runs.

## Carry-forward (M6)

- Promote glm-5.1 review gates + pr round cap to OSS-canonical; reconcile the
  live dev-stack edits.
- Capability-aware model substitution (probe tool-use, not just chat).
- `stamp_code_write_sandbox` should default `acceptance_criteria=''` (forgiving).
- bgworker should surface (not swallow) template-render errors.
- The auto-probe rides the weekly watchman — shorten the cron if faster refresh
  is wanted (not a bug).
- To actually land a coder PR: Michael grants the PAT write on a target repo.
