# Model aliases + intent-aware routing — 2026-06-17

**Binding question (Michael's, a teaching/design conversation):** how do model
providers work; can we have an alias table so the same logical model on two
providers can fall back (nvidia down → opencode_go); use opencode zen's free
models (qwen3.6-plus!); and a project/intent-based model override — "gather
public info on work-corpus = free, but analysis / steward / critic = private."

## What I taught (from source, not memory)

Two halves that meet only by name: the **env registry** (`providers.rs::from_env`,
read once at postmaster start, secret never leaves the process) and the **in-DB
catalog** (`model_capability`/`model_pricing`/`stage_models`/`model_escalation`).
The dispatch FINAL (`19 §6`) resolves provider and model **independently** down a
4-layer COALESCE ladder (work_item → stage → pipeline → catalog). The only
existing "fallback" — M.2 capability substitution — is **same-provider only**;
`model_escalation` is model-name-keyed and provider-blind. So "nvidia down → fall
back to opencode_go" was genuinely inexpressible. Michael's alias instinct was
the missing primitive, not a nicety.

## What I built (Michael chose "Full: alias + intent-aware routing")

New core `31-model-aliases.sql` (chain 00→**31**):
- `model_aliases(alias, provider, provider_model, priority)` — a logical name →
  an ordered set of concrete members. `pick_alias_member` resolves to the
  lowest-priority member that is **configured** (`providers_loaded()`, bypassed
  when the registry is empty so tests don't over-filter) + **usable** +
  **under spend cap** + (for a private intent) **no-train**.
- `model_capability.trains_on_data` (per-(provider,model); opencode_zen mixes
  free-train + paid-no-train, so per-provider was too coarse) + helpers
  `model_trains_on_data` / `provider_is_loaded` / `intent_forbids_training`.
- Re-authored `work_item_dispatch_stage`: the requested model may be an alias
  (selects provider+model from its members); a `file_private` intent's dispatch
  drops train-on-data alias members and **refuses** a literal train-on-data
  resolution — **bypassed per stage by `"public_io": true`** (the gather-is-
  public escape hatch that answers Michael's work-corpus case exactly).
- Re-authored `trigger_log_model_substitution` to **skip alias expansion** (it
  was logging every `declared 'kimi' → requested 'moonshotai/kimi-k2.6'` as a
  phantom substitution; caught by the live e2e proof, fixed + 2 phantom rows
  purged).

Overlay (workspace): `opencode-zen-free.sql` (the zen free models),
`nvidia-provider.sql` (+ trains_on_data), `model-aliases.sql` (the `kimi` alias
+ repoint gather stages). Manifest updated.

## The surprise the design was built to catch

I optimistically registered 6 zen free models. The auto-probe (real streaming
path) immediately walled two: **`qwen3.6-plus-free`** — the very one Michael was
excited about — **and `minimax-m3-free` had their free promotions END** (HTTP
401, "subscribe to OpenCode Go"). The `/v1/models` listing still shows them; the
listing lies, the probe is the truth. 4 zen free models actually work
(deepseek-v4-flash / mimo-v2.5 / nemotron-3-ultra / north-mini-code). So I
anchored the gather alias on **nvidia's free kimi-k2.6** (verified working,
tool-capable, strong) instead, with a paid opencode_go kimi fallback. This is
the alias system doing its job: dead free member → skip → next member.

## Proven

- virgin-smoke **OK 1–18** (chain 00→31): alias priority pick, private drops the
  train-on-data member (falls to paid), unusable skipped, literal train-on-data
  into a private intent refused, public_io bypasses the guard.
- overlay-replay 47/48 (the 1 fail = the pre-existing `vera-persona` /
  persona_host-schema gap, unrelated). clobber-check **3/0 PASS**.
- LIVE (applied to running `stewards-oss-pg`, pg18 rebaked): `kimi/public →
  nvidia free`, `kimi/private → opencode_go paid`; planning gather stages =
  `kimi` + public_io, analysis/steward/critic stay literal paid no-train.
- **Inverse-hypothesis e2e on live:** a throwaway work-corpus (file_private)
  `context_gather` (public_io) dispatched to **nvidia free moonshotai/kimi-k2.6**,
  torn down clean (no autonomous run). work-corpus forbids_training=true; the public
  intents false.

## Carry-forward / honest limits

- **Runtime-failure fallback is P1.** The static filter catches not-configured /
  unusable / over-cap / probe-failed members. A provider that is *up but fails
  mid-call* (nvidia 521) isn't instantly walked to the next member within the
  same work item; the M.5 auto-probe flips it unusable on the next cadence and
  the alias then falls through. Within-work-item retry-next-member = the P1.
- The other 4 working zen free models are registered + available but not yet
  wired into any stage (future aliases — e.g. a cheap-critic on
  deepseek-v4-flash-free).
- Closes the NVIDIA #185 private guard rail (the generalized version, not an
  `if provider=nvidia` one-off).

## P1 done same session (Michael: "lets take that on") — `32-alias-failover.sql`

The runtime-failure fallback the v1 deferred. Two findings drove the shape:
- **A real bug in `diagnose_failure`:** the transient regex matched `5(00..04)`
  only — it MISSED Cloudflare 521/522 and Anthropic 529, the exact outage shapes
  nvidia/Moonshot throw. Broadened to any 5xx + 408 + 529/overloaded + "web
  server is down". (Failover keys on `transient`/`timeout`, so this was load-bearing.)
- **The hook is the steward, not the per-completion trigger.** `pick_model`
  (the steward's escalation) RAISES for stages-jsonb pipelines (no stage_models
  row) — so without this, an alias stage got NO retry. Added an alias-failover
  branch to `steward_tick` BEFORE pick_model: on a transient/timeout failure of
  an alias-dispatched stage, exclude the members that already transient-failed
  this run (`alias_transient_failed_members` from work_queue error history),
  `pick_alias_member(..., exclude)` the next one, set model_override +
  provider_override, re-dispatch. Bounded by the tried-set + `failure_count < 3`.
- Chose the steward-override mechanism (mirrors the existing escalation) over
  re-authoring the dispatch FINAL a second time. **Known limit (documented):**
  the override persists, so a mid-pipeline failover keeps the work_item's LATER
  stages on the chosen member for that run; self-heals next run. Clean follow-up
  = clear overrides on stage advance (improves the existing escalation too).
- virgin-smoke **OK 19** (00→32): diagnose covers 5xx/52x/529/timeout; the
  exclude set skips a tried member; `steward_tick` walks a transient alias
  failure to the next member (override set + `alias_failover` logged). clobber
  **3/0**. Applied to live (steward_tick has failover, 521→transient,
  pick_alias_member 3-arg, the `kimi` alias still resolves), pg18 rebaked.

## Side note (Michael's question): Gemini-direct is wired
`google_gemini` is a configured provider (loaded, key present), 8 models
catalogued, 7 auto-probed usable (2.5-flash/-lite/-pro, 3-flash, 3.1-flash-lite,
3.1-pro, 3.5-flash); only `gemini-3-pro-preview` fails (404 "no longer
available" — a retired id the probe correctly walls). Gemini's free AI-Studio
tier also trains on data, so if it's ever used for a private intent it should be
flagged `trains_on_data` per provider/model like nvidia/zen-free.
