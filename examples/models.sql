-- examples/models.sql — a starter model catalog.
--
-- Import after your providers are set in .env (see docs/wiring-up-models.md):
--   psql "$STEWARDS_DSN" -f examples/models.sql
-- or, into the compose stack:
--   docker compose exec -T pg psql -U stewards -d stewards < examples/models.sql
--
-- This seeds stewards.model_capability (what's usable) + stewards.model_pricing
-- (cost-cap math). It is a SNAPSHOT (captured 2026-06-13) — model lineups and
-- prices drift. The authoritative source is each provider's own /models endpoint
-- + pricing page; the substrate's auto-probe (enqueue_model_probe) verifies
-- `usable` via the real streamed dispatch path. Trim to the models you use.
--
-- Prices are micro-dollars per million tokens ($0.95/Mtok = 950000).
-- api_format is 'openai' throughout: all four example providers expose
-- OpenAI-compatible endpoints. (If a provider needs Anthropic-format framing,
-- set api_format='anthropic' for that row.)

-- ── opencode zen (https://opencode.ai/zen/v1) — free + the Claude family ──────
INSERT INTO stewards.model_capability (provider, model, usable, supports_streaming, api_format) VALUES
  ('opencode_zen', 'deepseek-v4-flash-free', true, true, 'openai'),  -- FREE
  ('opencode_zen', 'claude-haiku-4-5',       true, true, 'openai'),
  ('opencode_zen', 'claude-sonnet-4-6',      true, true, 'openai'),
  -- Probed 2026-07-24: opencode_zen answers HTTP 400 for the Opus tier and for
  -- the 5-series. Seeded usable=false so a fresh install does not dispatch into
  -- a wall; re-probe (enqueue_model_probe) if the provider's lineup changes.
  -- Listing lies, the probe is truth — see docs/wiring-up-models.md.
  ('opencode_zen', 'claude-opus-4-8',        false, true, 'openai'),
  ('opencode_zen', 'claude-opus-5',          false, true, 'openai'),
  ('opencode_zen', 'claude-sonnet-5',        false, true, 'openai')
ON CONFLICT (provider, model) DO NOTHING;

INSERT INTO stewards.model_pricing (provider, model, input_micro_per_mtok, output_micro_per_mtok, effective_at, notes) VALUES
  ('opencode_zen', 'deepseek-v4-flash-free',       0,        0, now(), 'free tier'),
  ('opencode_zen', 'claude-haiku-4-5',       1000000,  5000000, now(), 'snapshot 2026-06-13'),
  ('opencode_zen', 'claude-sonnet-4-6',      3000000, 15000000, now(), 'snapshot 2026-06-13'),
  ('opencode_zen', 'claude-opus-4-8',        5000000, 25000000, now(), 'snapshot 2026-06-13')
ON CONFLICT (provider, model, effective_at) DO NOTHING;

-- ── opencode go (https://opencode.ai/zen/go/v1) — the subscription workhorses ─
INSERT INTO stewards.model_capability (provider, model, usable, supports_streaming, api_format) VALUES
  ('opencode_go', 'deepseek-v4-flash', true, true, 'openai'),  -- free on the tier
  ('opencode_go', 'kimi-k2.6',         true, true, 'openai'),
  ('opencode_go', 'qwen3.6-plus',      true, true, 'openai'),
  ('opencode_go', 'qwen3.7-plus',      true, true, 'openai'),  -- the default workhorse
  ('opencode_go', 'qwen3.7-max',       true, true, 'openai'),
  ('opencode_go', 'minimax-m3',        true, true, 'openai'),  -- 1M ctx, reasoning
  ('opencode_go', 'glm-5.1',           true, true, 'openai')
ON CONFLICT (provider, model) DO NOTHING;

INSERT INTO stewards.model_pricing (provider, model, input_micro_per_mtok, output_micro_per_mtok, effective_at, notes) VALUES
  ('opencode_go', 'deepseek-v4-flash',       0,       0, now(), 'free on the go tier'),
  ('opencode_go', 'kimi-k2.6',          950000, 4000000, now(), 'snapshot 2026-06-13'),
  ('opencode_go', 'qwen3.6-plus',       500000, 3000000, now(), 'snapshot 2026-06-13'),
  ('opencode_go', 'qwen3.7-plus',       400000, 1600000, now(), 'opencode zen 2026-06-17: $0.40 in / $1.60 out — cheaper than qwen3.6-plus'),
  ('opencode_go', 'qwen3.7-max',       2500000, 7500000, now(), 'snapshot 2026-06-13 (premium tier)'),
  ('opencode_go', 'minimax-m3',         300000, 1200000, now(), 'snapshot; 1M-token reasoning model — give generous max_tokens'),
  ('opencode_go', 'glm-5.1',           1400000, 4400000, now(), 'snapshot 2026-06-13')
ON CONFLICT (provider, model, effective_at) DO NOTHING;

-- ── Google Gemini (OpenAI-compat endpoint) — bring your AI Studio key ─────────
-- Prices vary by model/tier; verify at ai.google.dev. Estimates below.
INSERT INTO stewards.model_capability (provider, model, usable, supports_streaming, api_format) VALUES
  ('google_gemini', 'gemini-2.5-flash', true, true, 'openai'),
  ('google_gemini', 'gemini-2.5-pro',   true, true, 'openai')
ON CONFLICT (provider, model) DO NOTHING;

INSERT INTO stewards.model_pricing (provider, model, input_micro_per_mtok, output_micro_per_mtok, effective_at, notes) VALUES
  ('google_gemini', 'gemini-2.5-flash',  300000,  2500000, now(), 'ESTIMATE — verify at ai.google.dev'),
  ('google_gemini', 'gemini-2.5-pro',   1250000, 10000000, now(), 'ESTIMATE — verify at ai.google.dev')
ON CONFLICT (provider, model, effective_at) DO NOTHING;

-- ── LM Studio (local, http://host.docker.internal:1234/v1) — $0, no key ───────
INSERT INTO stewards.model_capability (provider, model, usable, supports_streaming, api_format) VALUES
  ('lm_studio', 'qwen/qwen3.6-27b', true, true, 'openai')
ON CONFLICT (provider, model) DO NOTHING;

INSERT INTO stewards.model_pricing (provider, model, input_micro_per_mtok, output_micro_per_mtok, effective_at, notes) VALUES
  ('lm_studio', 'qwen/qwen3.6-27b', 0, 0, now(), 'local — no per-token cost')
ON CONFLICT (provider, model, effective_at) DO NOTHING;

-- ── role aliases (the digesters dispatch by ROLE, not a concrete model) ───────
-- The example digesters (book/playlist) and the doc-construction loops name a
-- ROLE — ingest (big-context doer), reason (strong doer/synthesizer), critic
-- (reviewer) — so a deployer repoints the whole fleet by editing these rows (e.g.
-- to local models) instead of every pipeline. pick_alias_member picks the
-- lowest-priority AVAILABLE member, failing over within the role. These are the
-- PUBLIC defaults at priority 5 (a low-precedence floor): a deployer who adds
-- local members at priority 0 (see the workspace overlay) overrides them, while a
-- bare public install still dispatches. Requires the model_aliases table (core 31).
INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, notes) VALUES
  ('ingest', 'opencode_go', 'kimi-k2.6',    5, 'public default: big-context doer'),
  ('reason', 'opencode_go', 'kimi-k2.6',    5, 'public default: strong doer / synthesizer'),
  ('critic', 'opencode_go', 'qwen3.7-plus', 5, 'public default: strong reviewer')
ON CONFLICT (alias, provider, provider_model) DO NOTHING;
