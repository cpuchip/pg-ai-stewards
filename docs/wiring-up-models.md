# Wiring up models

The substrate dispatches model calls through **providers** (an OpenAI-compatible
HTTP endpoint + key) and a **model catalog** (what models exist, whether they're
usable, and what they cost). This page gets you from a fresh install to "agents
can actually call a model," with four concrete examples — including free ones so
you can try the harness with zero spend.

## The two pieces

1. **Providers** are bootstrapped from environment variables at Postgres
   startup (read once by the in-database bgworker). The pattern is:

   ```
   STEWARDS_PROVIDER_<NAME>_BASE_URL=https://...      # required
   STEWARDS_PROVIDER_<NAME>_API_KEY=sk-...            # omit for keyless/local
   STEWARDS_PROVIDER_<NAME>_DEFAULT_MODEL=some-model  # optional
   STEWARDS_PROVIDER_<NAME>_KIND=openai               # openai (default) | anthropic
   ```

   `<NAME>` becomes the lowercased provider id (e.g. `OPENCODE_ZEN` →
   `opencode_zen`). Put these in your `.env` (the pg service reads it). Confirm
   what loaded: `SELECT * FROM stewards.providers_loaded();`

2. **The model catalog** lives in two tables you seed with SQL:
   - `stewards.model_capability` — `(provider, model, usable, supports_streaming,
     api_format)`. The substrate auto-probes models via the real dispatch path and
     flips `usable` if a model doesn't actually stream; you can also seed it.
   - `stewards.model_pricing` — `(provider, model, input_micro_per_mtok,
     output_micro_per_mtok)`. Feeds the cost buckets + per-work-item caps. Prices
     are in micro-dollars per million tokens (so `$0.95/Mtok` = `950000`).

   A ready-to-edit catalog is in [`examples/models.sql`](../examples/models.sql) —
   import it, then trim to the models you actually use.

## Four ways to get a model (free → paid → local)

### A. opencode zen — free models out of the gate
[opencode](https://opencode.ai) zen serves several models, including free ones
(e.g. `deepseek-v4-flash-free`). Great for trying the substrate at $0.

```
STEWARDS_PROVIDER_OPENCODE_ZEN_BASE_URL=https://opencode.ai/zen/v1
STEWARDS_PROVIDER_OPENCODE_ZEN_API_KEY=<your opencode key>
STEWARDS_PROVIDER_OPENCODE_ZEN_DEFAULT_MODEL=deepseek-v4-flash-free
```
zen also fronts the Claude family (haiku/sonnet/opus) and others — see the
catalog. Set a low-cost default and let pipelines escalate to stronger models.

### B. opencode go — the subscription tier
The go subscription fronts kimi / qwen / glm / minimax / deepseek (`/zen/go/v1`).
This is the workhorse tier for code + research pipelines.

```
STEWARDS_PROVIDER_OPENCODE_GO_BASE_URL=https://opencode.ai/zen/go/v1
STEWARDS_PROVIDER_OPENCODE_GO_API_KEY=<your opencode key>
STEWARDS_PROVIDER_OPENCODE_GO_DEFAULT_MODEL=kimi-k2.6
```

### C. Google Gemini — your own API key
Gemini exposes an OpenAI-compatible endpoint, so it slots in the same way:

```
STEWARDS_PROVIDER_GOOGLE_GEMINI_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
STEWARDS_PROVIDER_GOOGLE_GEMINI_API_KEY=<your AI Studio key>
STEWARDS_PROVIDER_GOOGLE_GEMINI_DEFAULT_MODEL=gemini-2.5-flash
```
Get a key from Google AI Studio. (Free-quota terms vary and are often tied to
specific surfaces/models — check current limits before relying on "free.")

### D. LM Studio — fully local, no key, no spend
Run a model locally in [LM Studio](https://lmstudio.ai) (its server listens on
`:1234`). From inside the compose network, the host is `host.docker.internal`:

```
STEWARDS_PROVIDER_LM_STUDIO_BASE_URL=http://host.docker.internal:1234/v1
STEWARDS_PROVIDER_LM_STUDIO_DEFAULT_MODEL=qwen/qwen3.6-27b
# no API key
```
Local models price at $0/Mtok. Note: some local reasoning models always emit
thinking — give them a generous per-call `max_tokens` or the answer can get
truncated.

## Keeping prices current

`examples/models.sql` is a **snapshot** — model lineups and prices change. The
authoritative source is each provider's own `/models` endpoint and pricing page
(for opencode: `GET <base_url>/models` lists what your key can reach). A good
agent task: periodically fetch the provider's model list, diff it against
`model_capability`/`model_pricing`, and propose updates. Treat the seeded prices
as estimates that feed the cost-cap math, not a bill.

## Verify it works

```sql
SELECT * FROM stewards.providers_loaded();          -- providers env loaded?
SELECT provider, model, usable FROM stewards.model_capability ORDER BY 1,2;
SELECT stewards.enqueue_model_probe('<provider>', '<model>');  -- real-path probe
```
The probe dispatches a real streamed call and records whether the model is
usable — the honest check, not a config guess.
