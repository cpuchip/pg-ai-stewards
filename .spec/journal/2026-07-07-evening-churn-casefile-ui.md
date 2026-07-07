# 2026-07-07 evening — v31 park kills the churn; the case-file demo earns its letter; Stewdio's first ui-review

**Context:** Michael, brain fried, green-lit the suggested set: #338, the live case-file
demo, and a Stewdio dense-pro pass with the UI/UX skills vendored earlier tonight
(ui-ux-pro-max, web-interface-guidelines, web-quality-audit — MIT, provenance-noted,
wired as ui-craft/ui-review companions). All three delivered; three commits on main
(`89bd834`, `a0bb0d1`, `7248034`).

## v31 — steward park (#338)

New volume `v31-steward-park.sql` re-authors steward_tick (previous author v27/107 —
NOT edited; changing an applied volume's sha would make migrate re-apply the whole
lifeless-core migration). The per-item exception handler now PARKS the item at
awaiting_review with a readable error before accounting — the savepoint rollback that
used to leave the row untouched let the same 10 oldest failed items monopolize the
LIMIT-10 lane every 30s. Chain v00→v31; smoke OK 111 (parks on tick 1, bell rings,
ticks 2–3 add zero tick_error rows); migrate.sh status showed ONLY v31 differing
before apply; PARITY OK vs the v31test image.

**The fix earned its keep before its own fixture proof ran.** At 23:03 the 8 zombies
failed this morning (book-digest/read + subagent-url-summary — no stage_models rows)
were churning 8 tick_errors per tick, live. v31 applied ~23:05; last tick_error ever:
23:03:35. All 8 parked with `parked_awaiting_review=true`; lane-eligible failed
count: 0.

**Shim lesson:** the psql shim's `docker cp` needs `cygpath -m` on the HOST path, and
`MIGRATE_EXIT=$?` after a pipeline reads the pipe's exit, not migrate's — the first
apply attempt failed loudly and fail-closed (no ledger row) before the fixed re-run.

## The guard loop, end to end

The guard paused at 23:04 (`guard:in_flight 10 >= 8` — the 23:00 book-digest spawn
over the still-running 22:00 one). Auto-resume then wouldn't fire because
**reflect_guard_signals counts autonomous-actor `awaiting_review` items as in_flight**
— the 8 items v31 had just parked were themselves holding the pause open. Their honest
terminal state was cancellation (unroutable zombies; the hourly schedule reprocesses
those books) → in_flight 10→2 → the guard's own auto-resume fired
("in_flight 2 back under 75% of 8"). Trip → park → disposition → self-release, all on
the real path. The design tension (should human-blocked awaiting_review count toward a
RUNAWAY metric?) is SURFACED, not changed — task #347, Michael's call.

## Case-file demo — four runs to an honest letter

- **Floor (demo.sh) on live: exit 0.** Planted contradiction CATCH→CLEAN→CATCH on the
  real bridge MCP path; facts typed; case file published server-side.
- **Run 1: cancelled "SHELF EMPTY" — my bug.** The reopen UPDATE shared a
  multi-statement `psql -c` with a query that errored → one implicit transaction, all
  rolled back. Also: `work_item_create` only creates; dispatch is separate (README
  implies auto — noted).
- **Run 2: the letter stage grounded on KANT.** deepseek's `doc_current` (session-
  scoped) found nothing in its fresh stage session and wandered onto a concurrent
  book-digest doc; journaled confidently, wrote nothing anywhere (verified: no doc
  touched in the window). Fix 1: prompt hands the explicit handle from
  `{{stage_results.assemble.output}}`, forbids grounding elsewhere.
- **Run 3: the guardrail obeyed — and exposed the real gap.** The model refused
  perfectly ("no draft 2444c1cf in your session … I stop"), but doc_read had REFUSED a
  same-work-item handle. Root cause: **sql_fn tools get per-call `_session_id`
  injection; mcp_proxy tools ride ONE cached MCP client session per server** — the
  generic proxy session can't see wi-scoped drafts even though
  doc_draft_session_match's same-wi branch allows it (proven with the exact sessions,
  live). Fix 2: `case_draft_read`/`case_draft_append` sql_fn tools wrapping the same
  v08 `doc_*_tool` functions; letter surface narrowed to case-finalize only.
- **Run 4: COMPLETE.** sections→normalize→sanity→assemble→letter on
  mimo-v2.5/deepseek-v4-flash/sonnet#critic. The letter is grounded and anchor-cited
  throughout, argues BOTH deadlines (the notice's July 15 and the policy-derived
  July 16 — normalize's typed facts), builds the reversal case from the denial's own
  text, invents nothing, sends nothing (no send capability exists).

**Honest caveat:** the sanity stage on loom refused — the critic's Arc-C tool surface
predates tonight's case tools (task #346; same class as rs7's doc_* refusal). Findings
section honestly reads "no citation checks recorded." The citation oracle itself is
proven on the floor path.

## Stewdio dense-pro pass — first live run of the new UI stack

ui-review protocol: **ui-lint first** (12 hard tap-target fails — all nav links 20px;
zero :focus-visible rules; spacing 83%), screenshots at 390/834/1440. Fixes: py-2 on
nav links/buttons + dropdown rows (12 hard fails → 0), the app's first
`:focus-visible` ring (sky, keyboard-only), "Free GPUs" solid red → red outline so
Start brain is the view's single solid accent, schedules link padded. Oracle after:
**0 hard / focus 1 / spacing 85%**; ui container redeployed `--no-deps` (pg container
id unchanged, verified). Remaining advisories = the 44px-comfort tier on a desktop
nav; acceptable dense-pro.

## Carry-forward

- #346 critic tool-surface refresh (Arc-C mcp service vs new tool_defs).
- #347 SURFACE: guard in_flight counting awaiting_review (v31 interaction) — Michael.
- Durable question (bigger than the example): should the internal bgworker path
  execute doc_* as sql_fn instead of mcp_proxy? The mixed-scoping world (sql_fn = wi
  session, proxy = generic session) will bite other pipelines that hand drafts across
  stages.
- README snippet: work_item_create + "watch it walk" needs the dispatch call (or the
  watchman running).
- Live remains one volume ahead of the pg18 image tag (v31 in DB, not image) — rides
  the next sanctioned rebuild; v31test image kept locally for parity runs.
