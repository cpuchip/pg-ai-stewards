# 2026-06-24 — #243: in-loop retry/backoff on transient HTTP (the mid-loop failover gap)

Right after merging the Vertex provider PR, Michael asked "should we tackle 243
now?" and chose **oracle-first**. #243 was the carry the Vertex PR sharpened: a
transient `429/503` on tool turn N fails the whole stage because the model is
resolved once and there's no mid-loop retry.

## What I found (precise propagation, traced before touching anything)

- `chat()` (`bgworker.rs`) made a SINGLE `req.send()` — **no retry/backoff
  anywhere**. A non-2xx → `Err("chat HTTP 429 …")`.
- Write phase sets the chat work_queue row `status='error'`; for `kind='chat'`
  the tool_dispatch continuation-recovery branch is skipped, so the loop just
  stops.
- AFTER-UPDATE trigger `work_item_advance_completion` → `work_item_fail` →
  work_item `status='failed'`.
- `steward_tick` (32-alias-failover) THEN re-resolves the alias to the next
  member — but only at the **stage level**, re-running the whole loop. So a
  single blip nuked the stage instead of being shrugged off.

## The fix (scoped: retry the call, not re-architect the loop)

`send_with_retry(build, label)` in `bgworker.rs`: retries the POST on a transient
outcome — HTTP **408/429/any 5xx** (incl. Cloudflare 52x) or a network error —
with exponential backoff (`base * 2^(attempt-1)`, capped 10s). Non-transient 4xx
fail fast. The bearer is minted once before the loop (the SA token is cached) and
reused; a `RequestBuilder` is consumed by `send()`, so `build` rebuilds it per
attempt. Applied to both `chat()` and `embed()`. Tunable without a rebuild:
`STEWARDS_HTTP_RETRY_MAX` (default 3), `STEWARDS_HTTP_RETRY_BASE_MS` (default 800).

A transient blip is now absorbed in place; only a PERSISTENT transient falls
through (bounded) to 32's stage-level member failover, which stays the backstop.
The deeper **mid-loop member re-resolution** (switch alias members WITHOUT
restarting the loop) is left as a follow-up — it needs the alias threaded into the
continuation payload (today only the resolved concrete model is carried), and 32
backstops the persistent case. Retry/backoff is the PR's primary ask and covers
the stated failure.

## Oracle-first (kept: `tests/retry-oracle/`)

A controllable 429 stub (`stub429.py`, OpenAI-compat, `/set?fail=N`) registered as
a substrate provider on a scratch pg. Proven, with the inverse hypothesis:

| case | stub | row | requests |
|------|------|-----|----------|
| **baseline** (current/merged `.so`, no retry) | 429×1 | **error** `chat HTTP 429` | 1 |
| **fix — absorb** | 429×2 → 200 | **done** | 3 |
| **fix — exhaustion** | 429 always | **error** (bounded) | 3, then give up |

bgworker log on the absorb/exhaust runs: `chat transient HTTP 429 (attempt N/3);
backing off`. The errored ad-hoc row does NOT loop (stub count stable). The
baseline run on the pre-fix binary is the inverse check: same stub, fails on the
first 429. virgin-smoke 00→52 stays green (no chain change). Dev pg recreated from
the new image (retry live).

## Harness gotchas (kept for next time)

- `messages.session_id` FKs `stewards.sessions` — an ad-hoc chat enqueue must
  `INSERT` the session first, or the assistant-message insert rolls back the whole
  dispatch tx and the row re-dispatches in a loop (looked like "no retry worked"
  until I saw the FK error).
- Background stub processes accumulate; `pkill -f` doesn't kill Windows `python`.
  Kill via PowerShell `Get-CimInstance Win32_Process | ? CommandLine -like
  '*stub429*' | Stop-Process`. A `/set?fail=N` control endpoint (reset the
  counter in place) beats restart-per-phase.
- `docker run` a scratch pg needs `--add-host=host.docker.internal:host-gateway`
  to reach a host stub.

## Carry

- Mid-loop alias member re-resolution (the "and/or a breaker" half) — needs the
  alias in the continuation payload; 32 is the current backstop. (#243 stays open
  for this; the retry/backoff half is done.)
- Pre-existing `lib.rs` unused-import warning (from the Vertex merge) — separate
  cleanup.
