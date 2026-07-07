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
-- §8 — stage_models: the retry-path defaults 107-lifeless-core.sql's §9(c)
-- TRUNCATEd wholesale (every row was operator policy by the table's own
-- COMMENT — the same discipline model_pricing/model_escalation already
-- follow). These are the EXACT literal values that were living in core
-- before the strip (13-research-pipelines / 20-coder / 90-harness-executor
-- / 94-wiki-curator / 99-route-intake / 98-crawler), preserved here for
-- 1:1 behavioral parity if you want it back verbatim — swap freely.
-- war-game's stage_models (wargame/critique) already live in §4 below.
-- =====================================================================
INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('planning', 'context_gather', 'qwen3.7-plus', 'local overlay: pre-strip literal (13-research-pipelines.sql)'),
    ('planning', 'explore',        'kimi-k2.6',    'local overlay: pre-strip literal'),
    ('planning', 'synthesize',     'kimi-k2.6',    'local overlay: pre-strip literal'),
    ('planning', 'propose_work',   'qwen3.7-plus', 'local overlay: pre-strip literal'),
    ('planning', 'review_plan',    'qwen3.7-plus', 'local overlay: pre-strip literal'),

    ('agent-proposal',  'validate', 'qwen3.7-plus', 'local overlay: pre-strip literal'),
    ('revise-proposal', 'revise',   'qwen3.7-plus', 'local overlay: pre-strip literal'),

    ('code-write', 'plan',      'kimi-k2.6', 'local overlay: pre-strip literal (20-coder.sql)'),
    ('code-write', 'implement', 'kimi-k2.6', 'local overlay: pre-strip literal'),
    ('code-write', 'verify',    'kimi-k2.6', 'local overlay: pre-strip literal'),

    ('code-pr', 'clone',       'kimi-k2.6', 'local overlay: pre-strip literal'),
    ('code-pr', 'plan',        'kimi-k2.6', 'local overlay: pre-strip literal'),
    ('code-pr', 'plan_review', 'glm-5.1',   'local overlay: pre-strip literal — a DIFFERENT model than the implementer, on purpose'),
    ('code-pr', 'implement',   'kimi-k2.6', 'local overlay: pre-strip literal'),
    ('code-pr', 'verify',      'kimi-k2.6', 'local overlay: pre-strip literal'),
    ('code-pr', 'review',      'glm-5.1',   'local overlay: pre-strip literal — a DIFFERENT model than the implementer, on purpose'),
    ('code-pr', 'pr',          'kimi-k2.6', 'local overlay: pre-strip literal'),

    ('code-deploy', 'prepare', 'kimi-k2.6', 'local overlay: pre-strip literal'),
    ('code-deploy', 'deploy',  'kimi-k2.6', 'local overlay: pre-strip literal'),

    ('harness-review', 'dispatch', 'kimi-k2.6', 'local overlay: pre-strip literal (90-harness-executor.sql) — thin pilot turn, reliability over brilliance'),

    ('wiki-organize',      'gather',   'kimi-k2.6', 'local overlay: pre-strip literal (94-wiki-curator.sql)'),
    ('wiki-organize',      'propose',  'kimi-k2.6', 'local overlay: pre-strip literal'),
    ('wiki-collect-entity','research', 'kimi-k2.6', 'local overlay: pre-strip literal'),
    ('wiki-collect',       'plan',     'kimi-k2.6', 'local overlay: pre-strip literal'),

    ('route-intake', 'classify', 'kimi-k2.6', 'local overlay: pre-strip literal (99-route-intake.sql)'),
    ('route-intake', 'match',    'kimi-k2.6', 'local overlay: pre-strip literal'),

    ('crawl', 'step', 'deepseek-v4-flash', 'local overlay: pre-strip literal (98-crawler.sql) — workhorse-grade link scoring')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE
    SET default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;


-- =====================================================================
-- §9 — stages jsonb: re-attach model/provider for FIRST dispatch (the
-- resolution ladder reads stage.model/provider before ever consulting
-- stage_models, which only governs steward RETRY). 107's §9(a) generic
-- sweep drops these from every pipeline that doesn't already name a role
-- alias — this section re-attaches the EXACT pre-strip literal per
-- pipeline so applying this overlay reproduces identical first-dispatch
-- behavior. Grouped one UPDATE per pipeline; each is idempotent (jsonb ||
-- overwrites the two keys, safe to re-run after every migrate).
-- =====================================================================

-- Uniform-model pipelines (every stage takes the same model/provider) —
-- one UPDATE per pipeline, no per-stage CASE needed.
UPDATE stewards.pipelines
   SET stages = (SELECT jsonb_agg(stage || jsonb_build_object('model','kimi-k2.6','provider','opencode_go') ORDER BY ord)
                   FROM jsonb_array_elements(stages) WITH ORDINALITY t(stage, ord))
 WHERE family IN ('code-write','code-deploy','echo-test','persona-turn','wiki-organize',
                   'wiki-collect-entity','wiki-collect','route-intake','prompt-critic','lab-regression');

UPDATE stewards.pipelines
   SET stages = (SELECT jsonb_agg(stage || jsonb_build_object('model','qwen3.7-plus','provider','opencode_go') ORDER BY ord)
                   FROM jsonb_array_elements(stages) WITH ORDINALITY t(stage, ord))
 WHERE family IN ('decompose-fanout','aggregate-children',
                   'subagent-url-summary','subagent-files-audit','subagent-session-investigate',
                   'subagent-doc-summary','subagent-doc-investigate','subagent-docs-audit');

UPDATE stewards.pipelines
   SET stages = (SELECT jsonb_agg(stage || jsonb_build_object('model','deepseek-v4-flash','provider','opencode_go') ORDER BY ord)
                   FROM jsonb_array_elements(stages) WITH ORDINALITY t(stage, ord))
 WHERE family IN ('compact-context','subagent-research-codebase');

-- crawl's 'step' stage: pre-strip literal used opencode_zen, not opencode_go.
UPDATE stewards.pipelines
   SET stages = (SELECT jsonb_agg(stage || jsonb_build_object('model','deepseek-v4-flash','provider','opencode_zen') ORDER BY ord)
                   FROM jsonb_array_elements(stages) WITH ORDINALITY t(stage, ord))
 WHERE family = 'crawl';

-- code-pr: per-stage variation (plan_review/review get a DIFFERENT model
-- than the implementer, on purpose — the review-discipline this pipeline
-- is built around; see the stage_models notes above).
UPDATE stewards.pipelines
   SET stages = (
       SELECT jsonb_agg(
                  CASE stage->>'name'
                      WHEN 'plan_review' THEN stage || jsonb_build_object('model','glm-5.1','provider','opencode_go')
                      WHEN 'review'      THEN stage || jsonb_build_object('model','glm-5.1','provider','opencode_go')
                      ELSE stage || jsonb_build_object('model','kimi-k2.6','provider','opencode_go')
                  END
                  ORDER BY ord)
         FROM jsonb_array_elements(stages) WITH ORDINALITY t(stage, ord))
 WHERE family = 'code-pr';

-- war-game: wargame + critique are DIFFERENT loom seats (#role syntax —
-- see 102-war-game.sql's own comment). §4 above already re-seeds this
-- pipeline's stage_models; this is the matching FIRST-dispatch re-attach
-- (stages.model, which the resolution ladder reads before stage_models
-- is ever consulted).
UPDATE stewards.pipelines
   SET stages = (
       SELECT jsonb_agg(
                  CASE stage->>'name'
                      WHEN 'wargame'  THEN stage || jsonb_build_object('model','sonnet#wargame','provider','loom')
                      WHEN 'critique' THEN stage || jsonb_build_object('model','sonnet#critic', 'provider','loom')
                      ELSE stage
                  END
                  ORDER BY ord)
         FROM jsonb_array_elements(stages) WITH ORDINALITY t(stage, ord))
 WHERE family = 'war-game';


-- =====================================================================
-- §10 — the 12 brainstorm-lens pipelines' metadata.default_model/
-- default_provider/suggested_model/suggested_provider (107's §9(b) sweep
-- drops all four keys from every pipeline's metadata). Each lens already
-- ships with stages[0].model=NULL by design (j8b/j9b — the lens dispatches
-- via the pipeline.metadata layer of the resolution ladder, one rung below
-- stage.model), so THIS is the layer that actually needs re-attaching for
-- these 12 to dispatch at all. Values are the exact pre-strip literals.
-- =====================================================================
UPDATE stewards.pipelines
   SET metadata = metadata || jsonb_build_object(
       'default_model', v.model, 'default_provider', 'opencode_go',
       'suggested_model', v.model, 'suggested_provider', 'opencode_go')
  FROM (VALUES
      ('brainstorm-scamper',      'qwen3.7-plus'),
      ('brainstorm-six-hats',     'kimi-k2.6'),
      ('brainstorm-crazy8s',      'qwen3.7-plus'),
      ('brainstorm-reverse',      'kimi-k2.6'),
      ('brainstorm-mind-mapping', 'qwen3.7-plus'),
      ('brainstorm-brainwriting', 'kimi-k2.6'),
      ('brainstorm-starbursting', 'kimi-k2.6'),
      ('brainstorm-disney',       'kimi-k2.6'),
      ('brainstorm-storyboarding','qwen3.7-plus'),
      ('brainstorm-triz',         'kimi-k2.6'),
      ('brainstorm-forced-analogy','qwen3.7-plus'),
      ('brainstorm-worst-idea',   'qwen3.7-plus')
  ) AS v(family, model)
 WHERE stewards.pipelines.family = v.family;


-- =====================================================================
-- End of local-overlay-example.sql
-- =====================================================================
