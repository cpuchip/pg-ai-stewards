# 2026-06-24 — soak found two bugs: work_item_list NULL scan + stale chat spinner

The soak earned its keep within the hour. Michael was chatting in Stewdio about
picking 5 influential books; the chat "stalled" — spinner spinning, no work items,
no GPU. I looked instead of guessing: nothing was hung.

## What actually happened

Session `stewdio-project-books`, 12 iterations, ended on `loop_stop_reason=
steps_exhausted`. Root cause: the agent called **`work_item_list`** and it
**errored** — `can't scan into dest[7] (col: token_budget)`. The tool failure sent
it down a rabbit hole ("I don't see a specific list of 5 books…"), burning its step
budget. Then the loop stopped with the last assistant message still at
`finish_reason=tool_calls` ("Let me get the Book of Tea digest…"), so the UI — which
only clears the spinner on a non-tool_calls finish — showed a **stale "thinking"**
forever. Two bugs.

## Bug 1 — work_item_list NULL scan (root, blocking)

`cmd/stewards-mcp/inspection.go`: `WorkItemSummary` has non-pointer Go fields
(`PipelineFamily/CurrentStage/Actor string`, `TokenBudget/TokensIn/Out int`) but
those `work_items` columns are nullable — `token_budget` has no default, so a
launched item is NULL and a single NULL aborts the whole row scan. Same class as
the old NULL-slug bug. Fix: `COALESCE` every nullable-into-non-pointer column in
the `work_item_list` SELECT, and the same in the two `watchman_passes` queries
(provider/model/agent_family/counts/token_budget/budget_stopped).

Proven (inverse hypothesis): dispatched `work_item_list` through the bridge via
`mcp_proxy_enqueue` → `status=done`, `{"count":3,"items":[…]}`. Before the fix that
exact call errored `can't scan into dest[7]`.

## Bug 2 — stale "thinking" spinner on a stopped loop (UX)

A loop that ends on `steps_exhausted`/`truncated_tool_calls` leaves its last
assistant message at `finish_reason=tool_calls`; the SSE stream never delivers a
terminal message, so ChatPanel's spinner sticks. Fix uses the substrate's REAL
state, not a timer guess: new `GET /api/chat/session-status?session=` →
`{pending}` = does the session have any work_queue row in
pending/in_progress/waiting_for_tools. ChatPanel polls it every 5s while
"thinking" and clears the spinner when it goes false. Proven: the stalled session
reads `{"pending":false}`.

## Why it stalled, in one line

`work_item_list` errored → agent floundered → hit the step cap → spinner never
cleared. Nothing hung; the substrate was healthy the whole time (rig up, zero
in-flight rows).

## Note

The agent reaching for `work_item_list` to "find a list of 5 books" was a detour;
with the tool returning cleanly it won't dead-end there. The real book-research
path is `book_search` over the now-backfilled corpus (52 books). Soak continues.
