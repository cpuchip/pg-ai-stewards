-- =====================================================================
-- 00-config — the substrate's configuration surface
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg; NEW — rebuild lesson #4).
-- One key/value table for the dials that used to live as magic numbers
-- inside function bodies and Rust source: the default intent slug
-- (was hardcoded 'scripture-study' in yaml.rs/k4/j5/j8c/j9c/j12),
-- context pressure tiers, provider-specific chars-per-token estimators.
--
-- Convention: values are jsonb. Seeds here are defaults — operators own
-- the rows after install (ON CONFLICT DO NOTHING; upgrades never
-- overwrite an operator's setting).
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.config (
    key         text PRIMARY KEY,
    value       jsonb NOT NULL,
    description text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.config IS
  'Substrate configuration: one row per dial. Values are jsonb. '
  'Seeded with defaults at install; operator-owned afterward.';

CREATE OR REPLACE FUNCTION stewards.config_get(p_key text, p_default jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT value FROM stewards.config WHERE key = p_key), p_default);
$$;

CREATE OR REPLACE FUNCTION stewards.config_get_text(p_key text, p_default text DEFAULT NULL)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT value #>> '{}' FROM stewards.config WHERE key = p_key), p_default);
$$;

CREATE OR REPLACE FUNCTION stewards.config_set(p_key text, p_value jsonb, p_description text DEFAULT NULL)
RETURNS void
LANGUAGE sql AS $$
    INSERT INTO stewards.config (key, value, description, updated_at)
    VALUES (p_key, p_value, p_description, now())
    ON CONFLICT (key) DO UPDATE
       SET value = EXCLUDED.value,
           description = COALESCE(EXCLUDED.description, stewards.config.description),
           updated_at = now();
$$;

-- Defaults. Operators change these with config_set(); upgrades never
-- overwrite them.
INSERT INTO stewards.config (key, value, description) VALUES
  ('default_intent_slug', '"default"'::jsonb,
   'Intent slug bound to work created without an explicit intent. Seed an intent with this slug (the seed pack does) or change this key.'),
  ('context_pressure_tiers', '[0.50, 0.70, 0.85, 0.95]'::jsonb,
   'Context-engine pressure thresholds as fractions of the model window. Rendering degrades gracefully tier by tier.'),
  ('chars_per_token_default', '3.5'::jsonb,
   'Fallback token estimator. Provider-specific overrides live under chars_per_token.<provider> keys.'),
  ('chars_per_token.anthropic', '3.8'::jsonb,
   'Anthropic-family estimator (content multipliers may refine later).'),
  ('chars_per_token.openai', '4.0'::jsonb,
   'OpenAI-format estimator.')
ON CONFLICT (key) DO NOTHING;
