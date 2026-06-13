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
  ('opencode_zen', 'claude-opus-4-8',        true, true, 'openai')
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
  ('opencode_go', 'qwen3.7-max',       true, true, 'openai'),
  ('opencode_go', 'minimax-m3',        true, true, 'openai'),  -- 1M ctx, reasoning
  ('opencode_go', 'glm-5.1',           true, true, 'openai')
ON CONFLICT (provider, model) DO NOTHING;

INSERT INTO stewards.model_pricing (provider, model, input_micro_per_mtok, output_micro_per_mtok, effective_at, notes) VALUES
  ('opencode_go', 'deepseek-v4-flash',       0,       0, now(), 'free on the go tier'),
  ('opencode_go', 'kimi-k2.6',          950000, 4000000, now(), 'snapshot 2026-06-13'),
  ('opencode_go', 'qwen3.6-plus',       500000, 3000000, now(), 'snapshot 2026-06-13'),
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
