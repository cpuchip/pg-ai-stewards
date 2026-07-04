-- Operator roster (Michael, 2026-07-04 PM): opencode-zen balance low ($7 left);
-- opencode-go working (~$10/day); loom drives sonnet-5 for critical reviews (FREE
-- via Max subscription, through the loom serve OpenAI shim). NOT part of the
-- CREATE EXTENSION chain — an operator config snapshot, applied live + kept here
-- so the routing is reproducible. Requires: `loom serve --listen 127.0.0.1:7791
-- --openai-claude-home <host ~/.claude>` running on the host.
BEGIN;
-- go workhorse quartet, 256k ceiling
INSERT INTO stewards.model_capability (provider, model, usable, context_window, probe_detail, probed_via) VALUES
  ('opencode_go','deepseek-v4-flash', true, 256000, 'go workhorse', 'operator'),
  ('opencode_go','minimax-m3',        true, 256000, 'go workhorse', 'operator'),
  ('opencode_go','mimo-v2.5',         true, 256000, 'go workhorse', 'operator'),
  ('opencode_go','qwen3.7-plus',      true, 256000, 'go workhorse', 'operator')
ON CONFLICT (provider, model) DO UPDATE SET usable=true, context_window=256000, probed_via='operator';

-- loom as a keyless openai provider (localhost is the wall) + sonnet@loom (free)
SELECT stewards.provider_dials_set('loom', 'http://host.docker.internal:7791/v1', 'openai', 'sonnet');
INSERT INTO stewards.model_pricing (provider, model, input_micro_per_mtok, output_micro_per_mtok, effective_at, notes)
  VALUES ('loom','sonnet', 0, 0, now(), 'FREE via Max subscription — loom serve OpenAI shim -> Claude Code sonnet');
INSERT INTO stewards.model_capability (provider, model, usable, api_format, context_window, probe_detail, probed_via)
  VALUES ('loom','sonnet', true, 'openai', 200000, 'loom-driven sonnet-5 for critical reviews', 'operator')
  ON CONFLICT (provider, model) DO UPDATE SET usable=true, api_format='openai', probed_via='operator';

-- aliases: ingest/reason -> go quartet; critic/review -> sonnet@loom
UPDATE stewards.model_aliases SET enabled=false WHERE provider='opencode_zen' AND enabled;
INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, enabled, notes) VALUES
  ('ingest','opencode_go','deepseek-v4-flash',0,true,'go workhorse'),
  ('ingest','opencode_go','minimax-m3',1,true,'go workhorse'),
  ('ingest','opencode_go','mimo-v2.5',2,true,'go workhorse'),
  ('ingest','opencode_go','qwen3.7-plus',3,true,'go workhorse'),
  ('reason','opencode_go','deepseek-v4-flash',0,true,'go workhorse'),
  ('reason','opencode_go','minimax-m3',1,true,'go workhorse'),
  ('reason','opencode_go','qwen3.7-plus',2,true,'go workhorse'),
  ('critic','loom','sonnet',0,true,'loom sonnet-5 critical reviews (free via Max)'),
  ('review','loom','sonnet',0,true,'loom sonnet-5 reviews (free via Max)')
ON CONFLICT DO NOTHING;
COMMIT;
