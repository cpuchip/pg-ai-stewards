# 2026-06-24 — Stewdio Details mode: live working pulse + Activity stream

Third focusing-release increment (after S1–S4 Developer toggle + S5 intent launcher).
Michael's ask, verbatim: "we need a debug mode, or details mode … like you can see
all the models and a stream of tokens, tool calls etc. sometimes it looks like
nothing is happening in the UI … no thinking badge. I like the clean, but I also
love the details on, it's actually doing something."

Same loop: build → deterministic oracle → adversarial workflow QA → **verify the
findings** → fix → commit.

## What shipped

1. **The working pulse (the "looks dead" fix) — unconditional, everyone.** The chat
   badge was driven by an optimistic `pending` flag cleared on the first non-tool_calls
   reply, plus a `pendingPoll` that only ever *cleared* it. So once a reply landed, any
   further background work showed nothing. Replaced with an authoritative `working` ref
   polled from `chatSessionStatus` (true iff the session has an in-flight work_queue row),
   folded into the unified `pollWorkItems`/`scheduleWorkItems` loop. Badge = `busy`
   (pending || working || a spawned card in-flight) and it **names the current activity**
   ("working · searching docs") from the last assistant turn's tool calls, so it never
   reads as dead air.

2. **The Activity stream (the "stream of tokens, tool calls") — Details-gated.** The
   Models pane became **Activity**: a new "Live dispatches" section renders
   `activity.recent` (model · pipeline/slug · ↑in/↓out tokens · ago), poll switched to
   2.5s-while-busy. The data was already in `/api/activity.recent` — just never surfaced.

3. **Relabel ⚙ Dev → ⚙ Details** (same `store.dev` flag). "One surface, two depths":
   clean by default; Details reveals the live Activity pane + inline tool-call detail +
   the raw/developer surfaces.

## The QA earned its keep again — the first fix only *narrowed* the bug

The 3-lens QA workflow (`wf_459f9779`) found **3 HIGHs the oracle structurally couldn't**,
and the most important one was that my "fix" wasn't a fix:

- **HIGH — ≤15s of dead air remained.** `scheduleWorkItems` snapshots `active` once and
  commits a fixed 15s idle timer. A continuation enqueued in the gap *after* a reply but
  *before* the next poll → up to 15s with no badge = the **exact reported symptom**. Fix:
  a 45s cool-down (stay at 3s cadence after any activity) + `pollSoon()` on send and on
  every terminal frame. Forever → ~15s → ~3s/immediate.
- **HIGH — stop() re-raised within ~3s.** `chatStop` only cancels *pending* rows; a
  *running* row keeps session-status pending, so the authoritative poller flipped the
  badge back on right after the user hit ■ stop — a stuck-ON regression I introduced. Fix:
  a `cancelling` guard that holds the badge off until the queue actually drains.
  **Live-verified**: badge stayed off the full 12s after stop.
- **HIGH — stale-session write race.** `pollWorkItems` captured the session, awaited, then
  wrote the shared refs without re-checking — an old session's poll clobbers the new
  session's badge/cards after a switch. Fix: capture-sid guard after every await.
- MED: dockview persists pane titles, so a stale layout would still show "Models" — fixed
  with `applyCatalogTitles()` (setTitle after restore) instead of churning LAYOUT_KEY.
  MED: orphan `setTimeout(refreshWork)` could revive the loop post-unmount → `alive` guard
  + tracked one-shot. NIT: a "(developer)" tooltip survived the relabel.

Oracle extended to 20/20 (adds the Live-dispatches assertion + the Details/Activity
relabel). The pulse + stop were verified with real turns (the oracle can't drive an
in-flight turn deterministically).

## Lesson

The authoritative-poll fix was *right in shape but wrong in cadence* — making a signal
trustworthy isn't enough if you only sample it every 15s. And making `working`
authoritative defeated stop()'s optimistic clear, which had silently worked before. Both
were invisible to a green oracle and a clean happy-path test; the adversarial trace found
them. "Build passed" is not verification — reproduce the actual reported scenario.

## Carry-forward — the import/clone workstream Michael ratified this session

Diagnosing his second report (a `pg-ai-stewards` repo **zip timed out**) surfaced that
`doc_import_corpus` runs ONE 180s synchronous extraction container over the whole archive
+ embeds every file (`runner.Timeout`, `cmd/doc-extract-mcp/tools.go`). Michael's calls:

- **F1 (do it):** make corpus import an **async tracked work item with a progress card**,
  per-member, that works for large repos — no 180s cliff.
- **F2 (do it):** **LLM-route by content** — if we detect a code repo (or know it's code
  from the chat), pick early and **explore in repo form** (sandbox) rather than embed
  every file into the DB.
- **F3 (new — do it):** **clone a public repo from chat.** He noted the sandbox couldn't
  clone a public repo; since we have the sandbox we should add a "give me a repo URL →
  clone into a sandbox → explore" path (the coder sandbox has network; doc-extract is
  no-network by design — the clone belongs on the coder/explore side).

This is the next build arc on the substrate (tasks to follow).
