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
