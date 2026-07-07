-- =====================================================================
-- local-overlay-example.sql — "bring your own life" template.
-- =====================================================================
-- Everything in here is OPERATOR DATA, not core. It is exactly what
-- .spec/lightening/model-agnostic-audit.md classified STRIP: name/model
-- seeds that were found living in the numbered extension/*.sql chain and
-- belong here instead. Copy this file, rename it to your own overlay, and
-- edit freely — a virgin core install runs with none of this and simply
-- has no dispatchable model until an overlay (this file, or the
-- credentials wizard) supplies one.
--
-- Written against Michael's RATIFIED local economics (2026-07-07):
--   - loom (Claude Code via `loom serve`) is the PRIMARY doer/critic tier:
--     sonnet for the everyday balance, haiku for cheap/bulk, opus when a
--     dispatch is worth it. sonnet#wargame / sonnet#critic are loom's
--     "#role" syntax (extension/102-war-game.sql's own comment: the #role
--     picks a claude-home in loom serve, falling back to the default home
--     when no role-specific one exists).
--   - opencode_go (the subscription workhorse tier: kimi/qwen/glm/minimax)
--     is the fallback/bulk tier — cheaper, good enough for gather/classify/
--     structured-extraction work.
--   - local models (lm_studio / flexllama: gemma, qwen, nemotron) are
--     NON-CRITICAL EXTRAS — free, always-available fallback members at the
--     bottom of each role's priority list, not anyone's primary.
--
-- Idempotent throughout (ON CONFLICT ... DO UPDATE / DO NOTHING) — safe to
-- re-run after every `stewards-cli migrate` as the standing "wake this rig
-- back up" step. Requires: 00-config, 06-cost (provider_spend_caps), 14
-- (catalog_default_provider/model — see §0 note), 19 (model_capability), 31
-- (model_aliases), 36 (judge_dispatch_* config keys), 88 (credential_*
-- wizard functions), 95 (model_aliases.enabled), 102 (war-game pipeline).
-- =====================================================================


-- =====================================================================
-- §0 — the substrate-wide last-resort default (once 14-fanout-brainstorm.sql
-- is PARAMETERIZED per the audit's §3 recommendation: catalog_default_provider
-- reads stewards.config_get_text('default_provider', NULL) instead of
-- returning the literal 'opencode_go'). Until that lands, these two config
-- keys are inert — core still hardcodes 'opencode_go'/'kimi-k2.6' — but
-- setting them now costs nothing and makes this overlay forward-compatible.
-- =====================================================================
SELECT stewards.config_set('default_provider', to_jsonb('opencode_go'::text),
    'local overlay: last-resort provider when nothing else resolves (workhorse tier, not the primary — loom is primary via aliases below)');
SELECT stewards.config_set('default_model', to_jsonb('kimi-k2.6'::text),
    'local overlay: last-resort model for default_provider');


-- =====================================================================
-- §1 — provider dials. Secrets (API keys / the loom bridge token) are NOT
-- set here on purpose — stewards.credential_set takes bytea ciphertext only
-- (88-credentials.sql's whole point: SQL never sees plaintext). Add the
-- actual keys through the credentials wizard UI (Settings > Providers &
-- Models), or via the Go cockpit's encrypt-then-credential_set path. This
-- overlay only wires the non-secret half (base_url/kind/default_model) so a
-- `provider_dials_set` + a wizard-pasted key is enough to go live with no
-- rebuild.
-- =====================================================================
-- loom dials: the loom serve bridge — drives Claude Code (sonnet/haiku/opus,
-- plus #role seats like sonnet#wargame) as OpenAI-compat chat completions.
-- Paste the loom serve token via the wizard's credential step (not here —
-- this call only sets the non-secret base_url/kind/default_model dials).
SELECT stewards.provider_dials_set('loom',
    'http://host.docker.internal:7777/v1', 'openai', 'sonnet');

SELECT stewards.provider_dials_set('opencode_go',
    'https://opencode.ai/zen/go/v1', 'openai', 'kimi-k2.6');

-- Local, keyless — no credential_set call needed at all (88's "keyless
-- local providers are dials with no credential row").
SELECT stewards.provider_dials_set('lm_studio',
    'http://host.docker.internal:1234/v1', 'openai', NULL);
SELECT stewards.provider_dials_set('flexllama',
    'http://host.docker.internal:8090/v1', 'openai', NULL);


-- =====================================================================
-- §2 — daily budgets (88's provider_budget_set). loom/opencode_go are paid;
-- local providers get none (nothing to cap).
-- =====================================================================
SELECT stewards.provider_budget_set('loom',       10000000, 'daily'); -- $10/day
SELECT stewards.provider_budget_set('opencode_go', 5000000, 'daily'); -- $5/day


-- =====================================================================
-- §3 — role aliases: reason / ingest / critic / vision + review.
-- Priority 0 = tried first. This REPLACES examples/models.sql's public
-- priority-5 floor for these roles with the real local economics — loom
-- first, opencode_go as the paid-but-cheaper fallback, local models last as
-- non-critical extras. Mirrors the live shape (verified 2026-07-07: 39 rows
-- on the running DB, none of them committed anywhere in the repo before
-- this file) so the template is real, not aspirational.
-- =====================================================================
INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, notes) VALUES
    -- reason: loom's sonnet seat first, opencode_go workhorses as paid
    -- fallback, local models as free non-critical extras.
    ('reason', 'loom',       'sonnet',            0, 'local overlay: primary doer'),
    ('reason', 'opencode_go','kimi-k2.7-code',    1, 'local overlay: paid fallback'),
    ('reason', 'opencode_go','qwen3.7-plus',      2, 'local overlay: paid fallback'),
    ('reason', 'flexllama',  'gemma-4-26b-a4b',   3, 'local overlay: non-critical local extra'),

    -- critic: a DIFFERENT strong model than reason, per code-pr's own review
    -- discipline ("a DIFFERENT strong model than the implementer").
    ('critic', 'loom',       'sonnet#critic',     0, 'local overlay: primary critic (loom #role seat)'),
    ('critic', 'opencode_go','glm-5.2',           1, 'local overlay: paid fallback'),
    ('critic', 'flexllama',  'qwen3.6-27b',       2, 'local overlay: non-critical local extra'),

    -- ingest: big-context doer for gather/read-heavy stages. Local-first is
    -- fine here (ingest is workhorse-grade, not judgment-grade).
    ('ingest', 'opencode_go','qwen3.7-plus',      0, 'local overlay: primary ingest'),
    ('ingest', 'flexllama',  'gemma-4-26b-a4b',   1, 'local overlay: non-critical local extra'),
    ('ingest', 'flexllama',  'qwen3.6-35b-a3b',   2, 'local overlay: non-critical local extra'),

    -- vision: multimodal-capable member only.
    ('vision', 'google_gemini', 'gemini-3-flash-preview', 0, 'local overlay: vision (requires a google_gemini key via the wizard)'),
    ('vision', 'flexllama',     'gemma-4-26b-a4b',        1, 'local overlay: non-critical local vision extra'),

    -- review: the ask_up / Hinge-adjacent "second full loom seat" role.
    ('review', 'loom', 'sonnet#review', 0, 'local overlay: review seat (loom #role)')
ON CONFLICT (alias, provider, provider_model) DO UPDATE
    SET priority = EXCLUDED.priority, notes = EXCLUDED.notes;

-- Local mutual-fallback pair (68-model-fallback-hardening.sql's pattern,
-- moved here verbatim): when one local MoE model is unloaded, the walk
-- lands on whichever is up instead of dead-ending.
INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, notes) VALUES
    ('research-local', 'flexllama', 'gemma-4-26b-a4b',  1, 'local overlay: local MoE primary'),
    ('research-local', 'flexllama', 'qwen3.6-35b-a3b',  2, 'local overlay: local MoE mutual fallback')
ON CONFLICT (alias, provider, provider_model) DO UPDATE
    SET priority = EXCLUDED.priority, notes = EXCLUDED.notes;


-- =====================================================================
-- §4 — the war-game pipeline's stage defaults (STRIPPED from
-- extension/102-war-game.sql per the audit — this is Michael's specific
-- loom-seat economics, not a public default). Once 102 is lightened to ship
-- with NULL stage.model (falling through to pipeline.metadata or an alias),
-- this overlay is what re-attaches the real assignment.
-- =====================================================================
INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('war-game', 'wargame',  'sonnet#wargame',
     'local overlay: the wargame seat — a strong loom model (loom #role) fights a prospective failure simulation.'),
    ('war-game', 'critique', 'sonnet#critic',
     'local overlay: DIFFERENT loom seat than wargame, same discipline as code-pr''s implementer/critic split.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE
    SET default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;


-- =====================================================================
-- §5 — background judge dispatch (36-judge-local-routing.sql). This file's
-- MECHANISM is already correct (config-driven, not hardcoded) — this
-- overlay just flips the switch + points it at the local rig, per that
-- file's own header: "Bump judge_dispatch_model to gemma-12b or
-- qwen3.6-27b if extraction quality matters."
-- =====================================================================
SELECT stewards.config_set('judge_dispatch_local', to_jsonb(true),
    'local overlay: route background judges (engram-extractor/judge-brief/watchman-consolidator) to the local rig instead of opencode_go');
SELECT stewards.config_set('judge_dispatch_provider', to_jsonb('flexllama'::text),
    'local overlay: local rig for background judges');
SELECT stewards.config_set('judge_dispatch_model', to_jsonb('gemma-4-26b-a4b'::text),
    'local overlay: fast local MoE for background judge extraction');


-- =====================================================================
-- §6 — embeddings. Once trigger_embed_provider_route (15a-context-engrams.sql)
-- is PARAMETERIZED per the audit's §3 recommendation to read
-- config_get_text('embed_provider', NULL) instead of unconditionally
-- forcing 'lm_studio', this is the one-line switch that opts back into the
-- local LM Studio embedding endpoint this workspace actually runs.
-- =====================================================================
SELECT stewards.config_set('embed_provider', to_jsonb('lm_studio'::text),
    'local overlay: embeddings run on local LM Studio (OpenCode Go has no /v1/embeddings)');
SELECT stewards.config_set('embed_model', to_jsonb('nomic-embed-text-v1.5'::text),
    'local overlay: the local embedding model actually loaded');
SELECT stewards.config_set('embed_dimensions', to_jsonb(768),
    'local overlay: nomic-embed-text-v1.5''s native width');


-- =====================================================================
-- §7 — "rest all local models" convenience (95-model-role-toggles.sql's
-- bulk switch) — left ENABLED by default here since this overlay is meant
-- to be live, not just installed. Flip to false to rest every flexllama/
-- lm_studio alias member at once (e.g. before a GPU-hungry ComfyUI/asset-gen
-- run) without touching the priority list above.
-- =====================================================================
-- SELECT stewards.model_aliases_set_local_enabled(false);  -- uncomment to rest


-- =====================================================================
-- End of local-overlay-example.sql
-- =====================================================================
