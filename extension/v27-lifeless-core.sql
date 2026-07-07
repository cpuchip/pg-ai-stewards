-- ===== [was 107-lifeless-core.sql] =====
-- =====================================================================
-- 107 — LIFELESS CORE: "default is no models, it's just a db that's
-- lifeless. you give it models to bring it to life." (Michael, ratified
-- 2026-07-07, .spec/lightening/model-agnostic-audit.md)
-- =====================================================================
-- Builder E's strip, driven verbatim by the audit. Three moves, in order:
--
--   §1  catalog_default_provider()/catalog_default_model() — the ONE
--       substrate-wide last-resort — become config-driven (NULL absent
--       config), dropping IMMUTABLE (config reads are STABLE at best).
--   §2  trigger_embed_provider_route() — stop forcing 'lm_studio' on
--       every embed row. NULL config = the doc/brain_entry lands
--       unembedded, no error, + a deduped hinge nudge.
--   §3  work_item_dispatch_stage_safe() — a thin wrapper that softens
--       ONLY the "nothing is configured" shape of work_item_dispatch_
--       stage's RAISE EXCEPTIONs (could-not-resolve-model/provider, an
--       alias with no usable member, capability-unusable-with-no-
--       substitute) into a status='awaiting_review' landing in the
--       EXISTING needs_attention 'review' bucket (89-attention.sql) —
--       genuine programming errors still raise loud. Swapped in at the
--       ~9 call sites the audit's §3 trace found genuinely UNWRAPPED
--       (attention_answer's review-resume, route_intake, spawn_subagent_
--       create, propose_prompt_change_tool's critic dispatch, spawn_
--       children's per-child loop, check_and_dispatch_fanout_aggregator,
--       wiki_organize_start, wiki_collect_start, crawl_start). Sites that
--       ALREADY wrap the raw call in their own local BEGIN/EXCEPTION and
--       return a clear, human-readable note (102-war-game.sql's 4 sites,
--       46-chat-tasks.sql, 49-doc-extract.sql, 32-alias-failover.sql's 3
--       retry sites, 22-reflect-steward.sql's 2, 103-abort-conditions.sql's
--       1) are NOT swapped — they don't "RAISE cryptically" today (the
--       task's trigger condition), they degrade into a synchronous note
--       or a steward_actions log line already. Documented here as known-
--       and-left, not silently skipped. 07-steward.sql's steward_tick is
--       an exception to that rule: it's already locally caught, but on
--       an "unconfigured" failure the per-item UPDATE (model_override,
--       failure_count+1) rolls back with it, so the SAME item is retried
--       forever with no way out of the 'failed' bucket — _safe breaks
--       that loop by landing the item in 'awaiting_review' instead, so
--       it's swapped too (32-alias-failover.sql's FINAL steward_tick body
--       is re-authored below, all 3 of its dispatch call sites).
--   §4  03-watchman's schema-level NOT NULL DEFAULT 'opencode_go'/
--       'kimi-k2.6' columns become nullable, no default; watchman_pass_
--       start degrades to a logged 'errored' pass + a deduped hinge
--       nudge instead of enqueueing chats certain to fail.
--   §5  08-gates.sql / 10-sabbath-atonement.sql / 12-council.sql: seven
--       functions (evaluate_gate, generate_scenarios, verify_work_item,
--       sabbath_dispatch, atonement_dispatch, convene_council, synthesize_
--       council) hardcoded a DECLARE-time model/provider literal for
--       their own internal gate/sabbath/atonement/council dispatch. Re-
--       authored to resolve via catalog_default_provider()/model() (one
--       central lifeless default, per the audit's own "point here instead
--       of repeating the literal" recommendation for 36) with a config
--       override pair (gate_dispatch_provider/model) for the four
--       gate/sabbath/atonement functions that share the shape 36 already
--       established for judges. convene_council/synthesize_council raise
--       a CLEAR (not cryptic) pre-flight error when unconfigured — there
--       is no single work_item to park a multi-member council on.
--   §6  __queue_for_opus__ -> __queue_for_strongest__: the escalation-
--       ladder terminal sentinel named a specific model in the core
--       vocabulary. Renamed at its 3 real call sites (pick_model produces
--       it, 32-alias-failover.sql's steward_tick + 07-steward.sql's
--       superseded copy consume it) — mechanical, no seed data anywhere
--       names the old string (the matrix ships empty; the overlay doesn't
--       seed it either), so this is genuinely free. 06/07/32's own files
--       are left as the historical record (matching this codebase's own
--       "port from HERE" idiom, e.g. 102-war-game.sql's kept bug) with a
--       one-line pointer comment added at each site.
--   §7  The judge-family hand-built work_queue dispatches (engram-
--       extractor's 3 functions in 15a, judge-brief's dispatcher in 15b,
--       the judge branch of consult_subagent_dispatch in 16) hardcoded
--       'deepseek-v4-flash'/'opencode_go' inline instead of reading the
--       judge_dispatch_provider/judge_dispatch_model config pair
--       36-judge-local-routing.sql ALREADY defines for this exact
--       purpose (its own header names these as 2 of its 3 named judges).
--       Re-authored to read that pair (falling through to catalog_
--       default_provider/model when even that's unset) instead of
--       hardcoding a literal and leaning on 36's opt-in reroute trigger
--       to fix it after the fact. 36's own config_set seeds for
--       judge_dispatch_provider/model are DELETED here (no more literal
--       'opencode_go'/'deepseek-v4-flash' default — one central lifeless
--       default via catalog_default_* instead of two, per the audit's own
--       §H recommendation). apply_engram_extraction / apply_judge_brief's
--       'extracted_by' provenance stamps, hardcoded to name deepseek
--       regardless of what actually ran, are made dynamic (they read the
--       work_queue row's own requested_model) — leaving them hardcoded
--       would have been a NEW lie once the dispatch itself became
--       variable. trigger_populate_engram_embeddings' embed-kind insert
--       literal is nulled (cosmetic only — the kind='embed' BEFORE INSERT
--       trigger from §2 overwrites NEW.provider unconditionally regardless
--       of what this INSERT names).
--   §8  Two generic STRIP sweeps close out the ~19-file inventory without
--       hand-transcribing giant escaped-JSON pipeline literals (20-coder's
--       pipelines are single-string E'[...]'::jsonb blobs; hand-editing
--       those key-by-key is exactly the kind of transcription error this
--       principle should not be bought with): (a) drop 'model'/'provider'
--       from every pipeline's stages jsonb EXCEPT where the value already
--       names a role alias (reason/critic/ingest/vision/review — 35's
--       already-correct pattern, preserved automatically, no per-pipeline
--       enumeration needed) and except the two explicitly-documented
--       KEEP-as-example persona pipelines (persona-turn-lmstudio/gemini);
--       (b) drop default_model/default_provider/suggested_model/
--       suggested_provider from every pipeline's metadata (the 12
--       brainstorm-lens pipelines' j8b/j9b shape). Both run LAST in the
--       chain (this file), after every core INSERT has landed, so they
--       catch every literal regardless of which numbered file seeded it.
--       stewards.stage_models is TRUNCATED outright — every row in it is
--       operator policy by the table's own COMMENT (06-cost.sql), exactly
--       parallel to how model_pricing/model_escalation already ship
--       empty; pick_model() raising 'no stage_models row' on a virgin
--       install is a STEWARD-RETRY-path failure only (never first
--       dispatch), already caught by steward_tick's per-item EXCEPTION.
--       68-model-fallback-hardening.sql's live model_aliases DELETE/
--       UPDATE/INSERT block (Michael's specific local-rig topology,
--       landed directly in core instead of the overlay its sibling files
--       established) is removed at its source file, not swept generically
--       (arbitrary DML, not a fixed-shape seed) — the overlay's existing
--       §3 role-alias block already supersedes it in full.
--
-- Every stripped literal is re-seeded in .spec/lightening/local-overlay-
-- example.sql, extended alongside this file. The pipelines/functions this
-- file touches all still CREATE/run fine with no model configured — they
-- just don't name one until an operator (or the overlay) supplies it.
--
-- requires create_schedule_visibility (106).
-- =====================================================================


-- =====================================================================
-- §1 — catalog_default_provider() / catalog_default_model(): the ONE
-- substrate-wide last resort. Config-driven, NULL when unset. Dropped
-- IMMUTABLE -> STABLE (config_get_text itself is STABLE, not IMMUTABLE —
-- the value can change between installs/config_set calls within a
-- session's lifetime, just not within one statement).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.catalog_default_provider()
RETURNS text LANGUAGE sql STABLE AS $cdp$
    SELECT stewards.config_get_text('default_provider', NULL)
$cdp$;

COMMENT ON FUNCTION stewards.catalog_default_provider() IS
'107 (lifeless core, re-authors 14''s j8a): substrate-wide default provider when no higher layer (override / stage / pipeline.metadata) specifies. Reads config key default_provider; NULL when unset (a virgin install has no preference — the credentials wizard or the local overlay sets this). Was IMMUTABLE SQL RETURNS ''opencode_go'' unconditionally; now STABLE + config-driven.';

CREATE OR REPLACE FUNCTION stewards.catalog_default_model(p_provider text)
RETURNS text LANGUAGE sql STABLE AS $cdm$
    SELECT CASE
        WHEN p_provider IS NOT NULL
             AND p_provider = stewards.config_get_text('default_provider', NULL)
        THEN stewards.config_get_text('default_model', NULL)
        ELSE NULL
    END
$cdm$;

COMMENT ON FUNCTION stewards.catalog_default_model(text) IS
'107 (lifeless core, re-authors 14''s j8a): substrate-wide default model, paired ONLY with the resolved default_provider (a default_model with no matching default_provider is meaningless — return NULL and let the caller degrade). Config-driven; NULL when either key is unset. Was a hardcoded CASE (opencode_go -> kimi-k2.6); now reads default_provider/default_model.';


-- =====================================================================
-- §2 — trigger_embed_provider_route(): stop forcing lm_studio on every
-- embed row. NULL config = land unembedded, no error, + a deduped hinge
-- nudge (kind=embed-unconfigured). This is a BEFORE INSERT trigger;
-- returning NULL from a BEFORE ROW trigger cancels the INSERT for that
-- row entirely — no partial/broken work_queue row, no bgworker "unknown
-- provider" error.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.trigger_embed_provider_route()
RETURNS trigger LANGUAGE plpgsql AS $emb$
DECLARE
    v_embed_provider text;
BEGIN
    IF NEW.kind = 'embed' THEN
        v_embed_provider := stewards.config_get_text('embed_provider', NULL);

        IF v_embed_provider IS NULL THEN
            IF NOT EXISTS (
                SELECT 1 FROM stewards.hinge_reviews
                 WHERE kind = 'embed-unconfigured' AND status = 'pending'
            ) THEN
                PERFORM stewards.hinge_enqueue('embed-unconfigured', 'embeddings',
                    jsonb_build_object('note',
                        'A document or brain entry needs embedding but no embed_provider is configured. '
                        || 'It will stay unembedded (no semantic search over it) until one is set. '
                        || 'Open Settings -> Providers & Models, or SELECT stewards.config_set(''embed_provider'', to_jsonb(''<provider>''::text)).'),
                    'trigger_embed_provider_route');
            END IF;
            RETURN NULL;  -- cancel the INSERT; no broken work_queue row lands
        END IF;

        IF COALESCE(NEW.provider, '') <> v_embed_provider THEN
            RAISE NOTICE 'embed provider route: rewrote % -> % (wq pending insert)',
                COALESCE(NEW.provider, '(null)'), v_embed_provider;
            NEW.provider := v_embed_provider;
        END IF;

        IF NEW.payload IS NULL THEN
            NEW.payload := '{}'::jsonb;
        END IF;
        IF COALESCE(NEW.payload->>'model', '') = '' THEN
            NEW.payload := jsonb_set(NEW.payload, '{model}',
                to_jsonb(stewards.config_get_text('embed_model', 'nomic-embed-text-v1.5')), true);
        END IF;
        IF COALESCE(NEW.payload->>'dimensions', '') = '' THEN
            NEW.payload := jsonb_set(NEW.payload, '{dimensions}',
                to_jsonb(stewards.config_get_text('embed_dimensions', '768')::int), true);
        END IF;
    END IF;
    RETURN NEW;
END;
$emb$;

COMMENT ON FUNCTION stewards.trigger_embed_provider_route() IS
'107 (lifeless core, re-authors es2/15a): BEFORE INSERT on work_queue. kind=embed reads config embed_provider; NULL cancels the insert (RETURN NULL) + rings a deduped hinge bell (kind=embed-unconfigured) instead of forcing lm_studio and silently failing at the bgworker. Configured: rewrites NEW.provider + fills payload.model/dimensions from embed_model/embed_dimensions when absent, exactly as before.';


-- =====================================================================
-- §3 — work_item_dispatch_stage_safe(): soften the "nothing is
-- configured" shape of work_item_dispatch_stage's RAISE EXCEPTIONs into a
-- status='awaiting_review' landing in the EXISTING needs_attention
-- 'review' bucket (89-attention.sql: status='awaiting_review' AND
-- a2a_question IS NULL, question text = coalesce(error, ...)). Genuine
-- programming errors (bad work_item_id, bad status transition, missing
-- stage/agent_family) still RAISE loud — matched by exact substrings from
-- 31-model-aliases.sql's FINAL work_item_dispatch_stage body (the live
-- one, later-file-wins): "could not resolve model", "could not resolve
-- provider", "no usable member", "no usable substitute".
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.work_item_dispatch_stage_safe(
    p_work_item_id           uuid,
    p_user_input             text DEFAULT NULL,
    p_allow_failed_status    boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $safe$
DECLARE
    v_work_id bigint;
    v_wi      stewards.work_items%ROWTYPE;
BEGIN
    BEGIN
        v_work_id := stewards.work_item_dispatch_stage(p_work_item_id, p_user_input, p_allow_failed_status);
        RETURN v_work_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%could not resolve model%'
           OR SQLERRM LIKE '%could not resolve provider%'
           OR SQLERRM LIKE '%no usable member%'
           OR SQLERRM LIKE '%no usable substitute%'
        THEN
            SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
            UPDATE stewards.work_items
               SET status     = 'awaiting_review',
                   error      = left(
                       'no model configured for stage ' || COALESCE(v_wi.current_stage, '?')
                       || ' of pipeline ' || COALESCE(v_wi.pipeline_family, '?')
                       || ' — open Settings -> Providers & Models to assign one. (' || SQLERRM || ')',
                       2000),
                   updated_at = now()
             WHERE id = p_work_item_id;
            RETURN NULL;
        ELSE
            RAISE;
        END IF;
    END;
END;
$safe$;

COMMENT ON FUNCTION stewards.work_item_dispatch_stage_safe(uuid, text, boolean) IS
'107 (lifeless core): wraps work_item_dispatch_stage. On the specific "nothing configured" exception shapes (could not resolve model/provider, alias has no usable member, no usable capability substitute), parks the work_item at awaiting_review with a clear error (lands in needs_attention''s review bucket) and returns NULL instead of raising. Every other exception (genuine bugs) re-raises unchanged via bare RAISE. Swapped in at call sites that previously called work_item_dispatch_stage() UNWRAPPED — see this file''s header for the list and for the sites deliberately left alone.';


-- =====================================================================
-- §4 — the ~9 previously-unwrapped call sites, swapped to the safe
-- wrapper. Each function is byte-identical to its current live body
-- except the one dispatch call (and, for spawn_subagent_create, still
-- returning the child id even when dispatch soft-lands it in review —
-- previously an uncaught exception here meant the caller never even
-- learned the child's id).
-- =====================================================================

-- ── 16-subagents.sql: spawn_subagent_create ──────────────────────────
CREATE OR REPLACE FUNCTION stewards.spawn_subagent_create(
    p_pipeline_family    text,
    p_binding_question   text,
    p_parent_work_item_id uuid DEFAULT NULL,
    p_cost_cap_micro     bigint DEFAULT 500000,
    p_project_association text DEFAULT NULL,
    p_slug               text DEFAULT NULL,
    p_actor              text DEFAULT 'subagent'
) RETURNS uuid LANGUAGE plpgsql AS $ssc$
DECLARE
    v_parent       stewards.work_items%ROWTYPE;
    v_child_id     uuid;
    v_intent_id    uuid;
    v_actor        text;
    v_project      text;
    v_slug         text;
BEGIN
    IF p_parent_work_item_id IS NOT NULL THEN
        SELECT * INTO v_parent FROM stewards.work_items WHERE id = p_parent_work_item_id;
        IF v_parent.id IS NULL THEN
            RAISE EXCEPTION 'spawn_subagent_create: parent % not found', p_parent_work_item_id;
        END IF;
        v_intent_id := v_parent.intent_id;
        v_actor     := COALESCE(p_actor, v_parent.actor);
        v_project   := COALESCE(p_project_association, v_parent.project_association);
    ELSE
        SELECT id INTO v_intent_id FROM stewards.intents
         WHERE slug = stewards.config_get_text('default_intent_slug', 'default') LIMIT 1;
        v_actor   := COALESCE(p_actor, 'subagent');
        v_project := p_project_association;
    END IF;

    v_slug := COALESCE(p_slug, 'subagent-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS-MS'));

    v_child_id := stewards.work_item_create(
        p_pipeline_family => p_pipeline_family,
        p_input           => jsonb_build_object('binding_question', p_binding_question),
        p_slug            => v_slug,
        p_actor           => v_actor,
        p_intent_id       => v_intent_id
    );

    UPDATE stewards.work_items
       SET parent_work_item_id = p_parent_work_item_id,
           project_association = v_project,
           cost_cap_micro      = COALESCE(p_cost_cap_micro, cost_cap_micro),
           origin              = 'agent_planning'
     WHERE id = v_child_id;

    -- 107: was PERFORM work_item_dispatch_stage(v_child_id, NULL) unwrapped
    -- — an unconfigured stage raised straight through, and the caller never
    -- even learned v_child_id. Now soft-lands the child in awaiting_review.
    PERFORM stewards.work_item_dispatch_stage_safe(v_child_id, NULL);

    RAISE NOTICE 'spawn_subagent_create: parent=% child=% pipeline=% slug=% cost_cap=%',
        p_parent_work_item_id, v_child_id, p_pipeline_family, v_slug,
        COALESCE(p_cost_cap_micro, 0);

    RETURN v_child_id;
END;
$ssc$;

COMMENT ON FUNCTION stewards.spawn_subagent_create(text, text, uuid, bigint, text, text, text) IS
'107 (re-authors 16, dispatch-safe swap only): creates a child work_item with parent linkage and dispatches its first stage via work_item_dispatch_stage_safe. Returns the child uuid unconditionally — even when the stage could not be dispatched (unconfigured model), the item exists in awaiting_review and the caller can act on it.';

-- ── 16-subagents.sql: propose_prompt_change_tool (the self-prompt critic dispatch) ──
CREATE OR REPLACE FUNCTION stewards.propose_prompt_change_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $ppc$
DECLARE
    v_sess      text := p_args ->> '_session_id';
    v_rationale text := p_args ->> 'rationale';
    v_proposed  text := p_args ->> 'proposed_prompt';
    v_fam       text := stewards.session_agent_family(v_sess);
    v_match     text;
    v_current   text;
    v_pending   int;
    v_id        bigint;
    v_wi        uuid;
    v_binding   text;
BEGIN
    IF v_fam IS NULL THEN
        RETURN jsonb_build_object('error', 'could not resolve your agent family from this session');
    END IF;
    IF NOT stewards.self_prompt_on(v_fam) THEN
        RETURN jsonb_build_object('error', format('family %s is not allowed to propose base-prompt changes (allow_self_base_prompt is off)', v_fam));
    END IF;
    IF v_proposed IS NULL OR length(btrim(v_proposed)) < 40 THEN
        RETURN jsonb_build_object('error', 'proposed_prompt required (the FULL replacement prompt, not a fragment)');
    END IF;
    IF v_rationale IS NULL OR length(btrim(v_rationale)) = 0 THEN
        RETURN jsonb_build_object('error', 'rationale required — why should your base prompt change?');
    END IF;

    SELECT a.model_match INTO v_match FROM stewards.agents a
     WHERE a.family = v_fam AND a.model_match = '*';
    IF v_match IS NULL THEN
        SELECT min(a.model_match) INTO v_match FROM stewards.agents a WHERE a.family = v_fam;
        IF (SELECT count(*) FROM stewards.agents a WHERE a.family = v_fam) <> 1 THEN
            RETURN jsonb_build_object('error', format('family %s has multiple model variants and no * row — a human must edit directly', v_fam));
        END IF;
    END IF;
    SELECT a.prompt INTO v_current FROM stewards.agents a
     WHERE a.family = v_fam AND a.model_match = v_match;

    SELECT count(*) INTO v_pending FROM stewards.prompt_change_proposals
     WHERE agent_family = v_fam AND status = 'pending';
    IF v_pending >= 3 THEN
        RETURN jsonb_build_object('error', 'you already have 3 pending proposals — wait for the human to decide them');
    END IF;

    INSERT INTO stewards.prompt_change_proposals
        (agent_family, model_match, proposed_prompt, rationale, proposed_by_session)
    VALUES (v_fam, v_match, v_proposed, v_rationale, v_sess)
    RETURNING id INTO v_id;

    v_binding := format(
        E'A "%s" agent proposes changing its own base prompt. Review per your charge.\n\n'
        '## RATIONALE (the agent''s own)\n%s\n\n## CURRENT PROMPT\n%s\n\n## PROPOSED PROMPT\n%s',
        v_fam, v_rationale, coalesce(v_current, '(none)'), v_proposed);
    v_wi := stewards.work_item_create(
        'prompt-critic',
        jsonb_build_object('binding_question', v_binding, 'proposal_id', v_id),
        'prompt-critic-' || v_id,
        'self-prompt', NULL, NULL);
    -- 107: was PERFORM work_item_dispatch_stage(v_wi) unwrapped — an
    -- uncaught exception here rolled back the WHOLE proposal (the INSERT
    -- above too), losing the proposal a human never saw. Soft-lands instead.
    PERFORM stewards.work_item_dispatch_stage_safe(v_wi);

    RETURN jsonb_build_object('ok', true, 'proposal_id', v_id,
        'status', 'pending',
        'note', 'Proposal recorded and a critic review dispatched. It does NOT take effect unless a human ratifies it (prompt_proposal_apply). Continue operating under your current prompt.');
END;
$ppc$;

COMMENT ON FUNCTION stewards.propose_prompt_change_tool(jsonb) IS
'107 (re-authors 16, dispatch-safe swap only): records a self-prompt-change proposal and dispatches its critic review via work_item_dispatch_stage_safe, so an unconfigured critic model parks the review in awaiting_review instead of rolling back the whole proposal.';

-- ── 89-attention.sql: attention_answer's 'review' branch ─────────────
CREATE OR REPLACE FUNCTION stewards.attention_answer(
    p_kind   text,
    p_id     text,
    p_answer text
) RETURNS jsonb LANGUAGE plpgsql AS $aa$
DECLARE
    v_wq bigint;
BEGIN
    IF p_kind = 'gate' THEN
        RETURN stewards.tool_confirm_verdict(p_id::bigint, p_answer, NULL, 'michael');

    ELSIF p_kind = 'hinge' THEN
        RETURN stewards.hinge_record_verdict(p_id::bigint, p_answer, NULL, 'michael');

    ELSIF p_kind = 'ask' THEN
        RETURN stewards.ask_record_answer(p_id::bigint, p_answer);

    ELSIF p_kind = 'a2a_question' THEN
        RETURN stewards.a2a_answer(p_id::uuid, p_answer);

    ELSIF p_kind = 'review' THEN
        -- 107: was an inline unwrapped work_item_dispatch_stage(...) call
        -- INSIDE the jsonb_build_object — the one raw exception the audit
        -- named as hitting the Stewdio "answer" HTTP call directly. Now
        -- resolved via the safe wrapper first, so a still-unconfigured
        -- resume re-parks the item in review (with an updated error
        -- message) instead of throwing a raw SQL exception at the API.
        v_wq := stewards.work_item_dispatch_stage_safe(
                    p_id::uuid, nullif(btrim(coalesce(p_answer,'')), ''));
        RETURN jsonb_build_object(
            'work_item_id',  p_id::uuid,
            'dispatched',    v_wq IS NOT NULL,
            'work_queue_id', v_wq);
    ELSE
        RETURN jsonb_build_object('ok', false, 'note', format('attention_answer: unknown source_kind %s', p_kind));
    END IF;
END;
$aa$;

COMMENT ON FUNCTION stewards.attention_answer(text, text, text) IS
'107 (re-authors 89, dispatch-safe swap only): the review branch resumes via work_item_dispatch_stage_safe — a still-unconfigured model re-parks the item in awaiting_review (dispatched:false) instead of throwing a raw exception at the Stewdio bell''s answer API. Every other kind unchanged.';

-- ── 99-route-intake.sql: route_intake ────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.route_intake(
    p_kind        text,
    p_ref         text,
    p_instruction text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $ri$
DECLARE
    v_kind text := lower(btrim(coalesce(p_kind, '')));
    v_ref  text := btrim(coalesce(p_ref, ''));
    v_slug text;
    v_id   uuid;
BEGIN
    IF v_kind NOT IN ('url', 'file', 'video', 'text') THEN
        RAISE EXCEPTION 'route_intake: kind must be one of url|file|video|text, got %', p_kind;
    END IF;
    IF v_ref = '' THEN
        RAISE EXCEPTION 'route_intake: ref is required (a url, an attachment id, or a doc slug)';
    END IF;

    v_slug := 'route-intake-' || v_kind || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS-MS');

    v_id := stewards.work_item_create(
        p_pipeline_family => 'route-intake',
        p_input           => jsonb_build_object(
            'binding_question', format('Classify and route this %s (%s)%s.',
                v_kind, left(v_ref, 200),
                CASE WHEN coalesce(p_instruction, '') <> '' THEN ' — instruction: ' || p_instruction
                     ELSE ' — auto-magic (no instruction given)' END),
            'kind', v_kind,
            'ref', v_ref,
            'instruction', nullif(btrim(coalesce(p_instruction, '')), '')
        ),
        p_slug  => v_slug,
        p_actor => 'human'
    );

    -- 107: was PERFORM work_item_dispatch_stage(v_id) unwrapped — an
    -- MCP tool call an agent invokes directly; an unconfigured route-
    -- intake stage failed the entire tool call with a raw SQL exception.
    PERFORM stewards.work_item_dispatch_stage_safe(v_id);
    RETURN v_id;
END;
$ri$;
COMMENT ON FUNCTION stewards.route_intake(text, text, text) IS
'107 (re-authors 99, dispatch-safe swap only): creates + dispatches a route-intake work_item via work_item_dispatch_stage_safe — an unconfigured classify/match stage parks the item in awaiting_review instead of failing the calling tool call with a raw exception.';

-- ── 14-fanout-brainstorm.sql: spawn_children ─────────────────────────
CREATE OR REPLACE FUNCTION stewards.spawn_children(p_parent_id uuid)
RETURNS int LANGUAGE plpgsql AS $sch$
DECLARE
    v_parent            stewards.work_items%ROWTYPE;
    v_manifest          jsonb;
    v_manifest_raw      text;
    v_child             jsonb;
    v_child_id          uuid;
    v_count             int := 0;
    v_aggregator        jsonb;
    v_agg_id            uuid;
    v_agg_dest          text;
    v_children_arr      jsonb := '[]'::jsonb;
    v_child_pipeline    text;
    v_child_slug        text;
    v_child_input       jsonb;
    v_cost_cap          bigint;
    v_child_dest        text;
    v_model_override    text;
    v_provider_override text;
BEGIN
    SELECT * INTO v_parent FROM stewards.work_items WHERE id = p_parent_id;
    IF v_parent.id IS NULL THEN
        RAISE EXCEPTION 'spawn_children: parent % not found', p_parent_id;
    END IF;

    v_manifest := v_parent.stage_results -> 'decompose' -> 'output';
    IF v_manifest IS NULL THEN
        RAISE EXCEPTION 'spawn_children: no decompose output on parent %', p_parent_id;
    END IF;

    IF jsonb_typeof(v_manifest) = 'string' THEN
        v_manifest_raw := v_manifest #>> '{}';
        v_manifest_raw := regexp_replace(
                              regexp_replace(btrim(v_manifest_raw), '^```[a-zA-Z]*\s*', ''),
                              '\s*```\s*$', '');
        v_manifest_raw := coalesce((regexp_match(v_manifest_raw, '\{.*\}'))[1], v_manifest_raw);
        BEGIN
            v_manifest := v_manifest_raw::jsonb;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'spawn_children: decompose output is not valid JSON: %', SQLERRM;
        END;
    END IF;

    IF v_manifest -> 'children' IS NULL
       OR jsonb_typeof(v_manifest -> 'children') <> 'array'
       OR jsonb_array_length(v_manifest -> 'children') = 0 THEN
        RAISE EXCEPTION 'spawn_children: manifest.children is missing or empty';
    END IF;

    IF v_manifest -> 'aggregate' IS NULL
       OR (v_manifest -> 'aggregate' ->> 'destination') IS NULL THEN
        RAISE EXCEPTION 'spawn_children: manifest.aggregate.destination is required';
    END IF;

    FOR v_child IN SELECT * FROM jsonb_array_elements(v_manifest -> 'children') LOOP
        v_child_pipeline := v_child ->> 'pipeline_family';
        v_child_slug     := v_child ->> 'slug';

        IF v_child_pipeline IS NULL OR v_child_slug IS NULL
           OR (v_child ->> 'binding_question') IS NULL THEN
            RAISE EXCEPTION 'spawn_children: child entry missing slug/pipeline_family/binding_question: %', v_child;
        END IF;

        v_child_input := jsonb_build_object(
            'binding_question', v_child ->> 'binding_question'
        );
        IF (v_child -> 'input_extra') IS NOT NULL
           AND jsonb_typeof(v_child -> 'input_extra') = 'object' THEN
            v_child_input := v_child_input || (v_child -> 'input_extra');
        END IF;

        IF EXISTS (SELECT 1 FROM stewards.work_items WHERE slug = v_child_slug) THEN
            v_child_slug := v_child_slug || '-' || substr(p_parent_id::text, 1, 8);
        END IF;

        v_child_id := stewards.work_item_create(
            p_pipeline_family => v_child_pipeline,
            p_input           => v_child_input,
            p_slug            => v_child_slug,
            p_actor           => v_parent.actor,
            p_intent_id       => v_parent.intent_id
        );

        v_cost_cap := NULL;
        IF (v_child ->> 'cost_cap_micro') IS NOT NULL THEN
            v_cost_cap := (v_child ->> 'cost_cap_micro')::bigint;
        END IF;

        v_child_dest := v_child ->> 'file_destination';

        UPDATE stewards.work_items
           SET parent_work_item_id = p_parent_id,
               project_association = COALESCE(
                   (SELECT p.slug FROM stewards.projects p
                     WHERE p.slug = v_child ->> 'project_association'),
                   v_parent.project_association
               ),
               cost_cap_micro   = COALESCE(v_cost_cap, cost_cap_micro),
               file_destination = COALESCE(v_child_dest, file_destination)
         WHERE id = v_child_id;

        v_model_override    := v_child ->> 'model_override';
        v_provider_override := v_child ->> 'provider_override';
        IF v_model_override IS NOT NULL OR v_provider_override IS NOT NULL THEN
            UPDATE stewards.work_items
               SET model_override    = COALESCE(v_model_override,    model_override),
                   provider_override = COALESCE(v_provider_override, provider_override)
             WHERE id = v_child_id;
        END IF;

        -- 107: was PERFORM work_item_dispatch_stage(v_child_id, NULL)
        -- unwrapped INSIDE the loop — one unconfigured child raised and
        -- killed the WHOLE fan-out (no aggregator ever spawned, and
        -- every LATER sibling in this manifest silently never created).
        PERFORM stewards.work_item_dispatch_stage_safe(v_child_id, NULL);

        v_children_arr := v_children_arr || jsonb_build_object(
            'id', v_child_id::text,
            'slug', v_child_slug,
            'binding_question', v_child ->> 'binding_question',
            'pipeline_family', v_child_pipeline,
            'file_destination', v_child_dest
        );
        v_count := v_count + 1;
    END LOOP;

    v_aggregator := v_manifest -> 'aggregate';
    v_agg_dest   := v_aggregator ->> 'destination';

    v_agg_id := stewards.work_item_create(
        p_pipeline_family => 'aggregate-children',
        p_input           => jsonb_build_object(
            'binding_question', 'Aggregate index for: ' || COALESCE(v_parent.input ->> 'binding_question', v_parent.slug),
            'parent_work_item_id', p_parent_id::text,
            'destination', v_agg_dest,
            'synthesis', COALESCE((v_aggregator ->> 'synthesis')::boolean, false),
            'children', v_children_arr
        ),
        p_slug            => COALESCE(v_parent.slug, p_parent_id::text) || '-aggregator',
        p_actor           => v_parent.actor,
        p_intent_id       => v_parent.intent_id
    );

    UPDATE stewards.work_items
       SET parent_work_item_id = p_parent_id,
           project_association = v_parent.project_association,
           file_destination    = v_agg_dest
     WHERE id = v_agg_id;

    RAISE NOTICE 'spawn_children: parent=% spawned % children + aggregator % (dest=%)',
        p_parent_id, v_count, v_agg_id, v_agg_dest;

    RETURN v_count;
END;
$sch$;

COMMENT ON FUNCTION stewards.spawn_children(uuid) IS
'107 (re-authors 14, dispatch-safe swap only): dispatches each fan-out child via work_item_dispatch_stage_safe — one child''s unconfigured model no longer kills the rest of the batch or prevents the aggregator from ever being spawned.';

-- ── 14-fanout-brainstorm.sql: check_and_dispatch_fanout_aggregator ───
CREATE OR REPLACE FUNCTION stewards.check_and_dispatch_fanout_aggregator(p_parent_id uuid)
RETURNS uuid LANGUAGE plpgsql AS $cdfa$
DECLARE
    v_unfinished int;
    v_agg_id     uuid;
    v_agg_wq     bigint;
BEGIN
    IF p_parent_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT COUNT(*) INTO v_unfinished
      FROM stewards.work_items
     WHERE parent_work_item_id = p_parent_id
       AND pipeline_family <> 'aggregate-children'
       AND maturity <> 'verified'
       AND status NOT IN ('cancelled', 'failed');

    IF v_unfinished > 0 THEN
        RETURN NULL;
    END IF;

    SELECT id INTO v_agg_id
      FROM stewards.work_items
     WHERE parent_work_item_id = p_parent_id
       AND pipeline_family = 'aggregate-children'
       AND status = 'pending'
     LIMIT 1;

    IF v_agg_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- 107: was a bare work_item_dispatch_stage call — this runs from a
    -- trigger (on_maturity_verified / on_child_status_terminal); an
    -- unconfigured aggregator either broke the trigger chain or was
    -- silently swallowed by it, either way invisibly. Now parks visibly.
    v_agg_wq := stewards.work_item_dispatch_stage_safe(v_agg_id, NULL);
    RAISE NOTICE 'check_and_dispatch_fanout_aggregator: aggregator % dispatched wq=% (parent=%, all siblings terminal)',
        v_agg_id, v_agg_wq, p_parent_id;

    RETURN v_agg_id;
END;
$cdfa$;

COMMENT ON FUNCTION stewards.check_and_dispatch_fanout_aggregator(uuid) IS
'107 (re-authors 14, dispatch-safe swap only): dispatches the aggregator via work_item_dispatch_stage_safe when all siblings are terminal — an unconfigured aggregator model parks visibly in awaiting_review instead of raising inside a trigger or vanishing silently.';

-- ── 94-wiki-curator.sql: wiki_organize_start ─────────────────────────
CREATE OR REPLACE FUNCTION stewards.wiki_organize_start(
    p_scope                jsonb,
    p_wiki_slug            text,
    p_actor                text DEFAULT 'human',
    p_project_association  text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $wos$
DECLARE
    v_slug text;
    v_id   uuid;
BEGIN
    IF p_wiki_slug IS NULL OR btrim(p_wiki_slug) = '' THEN
        RAISE EXCEPTION 'wiki_organize_start: wiki_slug is required';
    END IF;
    v_slug := 'wiki-organize-' || p_wiki_slug || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS');

    v_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-organize',
        p_input           => jsonb_build_object(
            'binding_question', format('Organize the %s scope into wiki pages for "%s".',
                                        COALESCE(p_scope, '{"kind":"all"}'::jsonb), p_wiki_slug),
            'scope', COALESCE(p_scope, '{"kind":"all","value":null}'::jsonb),
            'wiki_slug', p_wiki_slug
        ),
        p_slug   => v_slug,
        p_actor  => COALESCE(p_actor, 'human')
    );
    UPDATE stewards.work_items
       SET project_association = p_project_association
     WHERE id = v_id;

    PERFORM stewards.work_item_dispatch_stage_safe(v_id, NULL);
    RETURN v_id;
END;
$wos$;
COMMENT ON FUNCTION stewards.wiki_organize_start(jsonb, text, text, text) IS
'107 (re-authors 94, dispatch-safe swap only): entry point for wiki-organize, dispatched via work_item_dispatch_stage_safe.';

-- ── 94-wiki-curator.sql: wiki_collect_start ──────────────────────────
CREATE OR REPLACE FUNCTION stewards.wiki_collect_start(
    p_question             text,
    p_scope                jsonb DEFAULT NULL,
    p_wiki_slug            text  DEFAULT NULL,
    p_actor                text  DEFAULT 'human',
    p_project_association  text  DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $wcs$
DECLARE
    v_wiki_slug text;
    v_slug      text;
    v_id        uuid;
BEGIN
    IF p_question IS NULL OR btrim(p_question) = '' THEN
        RAISE EXCEPTION 'wiki_collect_start: question is required';
    END IF;
    v_wiki_slug := COALESCE(NULLIF(p_wiki_slug, ''),
        trim(both '-' from regexp_replace(lower(btrim(p_question)), '[^a-z0-9]+', '-', 'g')));
    v_slug := 'wiki-collect-' || v_wiki_slug || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS');

    v_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-collect',
        p_input           => jsonb_build_object(
            'binding_question', p_question,
            'question', p_question,
            'scope', COALESCE(p_scope, '{"kind":"all","value":null}'::jsonb),
            'wiki_slug', v_wiki_slug
        ),
        p_slug   => v_slug,
        p_actor  => COALESCE(p_actor, 'human')
    );
    UPDATE stewards.work_items
       SET project_association = p_project_association
     WHERE id = v_id;

    PERFORM stewards.work_item_dispatch_stage_safe(v_id, NULL);
    RETURN v_id;
END;
$wcs$;
COMMENT ON FUNCTION stewards.wiki_collect_start(text, jsonb, text, text, text) IS
'107 (re-authors 94, dispatch-safe swap only): entry point for wiki-collect, dispatched via work_item_dispatch_stage_safe.';

-- ── 98-crawler.sql: crawl_start ───────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.crawl_start(
    p_url      text,
    p_purpose  text,
    p_config   jsonb   DEFAULT '{}'::jsonb,
    p_actor    text    DEFAULT 'human',
    p_dispatch boolean DEFAULT true
) RETURNS uuid LANGUAGE plpgsql AS $crs$
DECLARE
    v_norm text;
    v_cfg  jsonb;
    v_slug text;
    v_id   uuid;
BEGIN
    v_norm := stewards.crawl_url_normalize(p_url);
    IF v_norm IS NULL THEN
        RAISE EXCEPTION 'crawl_start: p_url must be an http(s) URL, got %', p_url;
    END IF;
    IF p_purpose IS NULL OR btrim(p_purpose) = '' THEN
        RAISE EXCEPTION 'crawl_start: a crawl needs a purpose — "everything" is exactly what the budget floor exists to prevent';
    END IF;

    v_cfg  := stewards.crawl_config(jsonb_build_object('config', coalesce(p_config, '{}'::jsonb)));
    v_slug := 'crawl-'
           || regexp_replace(coalesce(stewards.crawl_url_host(v_norm), 'site'), '[^a-z0-9]+', '-', 'g')
           || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS')
           || '-' || substr(md5(random()::text), 1, 4);

    v_id := stewards.work_item_create(
        p_pipeline_family => 'crawl',
        p_input           => jsonb_build_object(
            'binding_question', format('Crawl %s for: %s', v_norm, p_purpose),
            'url',       v_norm,
            'purpose',   p_purpose,
            'config',    v_cfg,
            'last_step', '(first step — the frontier holds only the root URL)',
            '_crawl',    jsonb_build_object('bytes_saved', 0, 'pages_saved', 0)),
        p_slug  => v_slug,
        p_actor => coalesce(p_actor, 'human'));

    IF v_cfg->>'target_project' IS NOT NULL
       AND EXISTS (SELECT 1 FROM stewards.projects WHERE slug = v_cfg->>'target_project') THEN
        UPDATE stewards.work_items
           SET project_association = v_cfg->>'target_project'
         WHERE id = v_id;
    END IF;

    INSERT INTO stewards.crawl_frontier
        (work_item_id, url, url_normalized, depth, priority, status)
    VALUES (v_id, v_norm, v_norm, 0, 1.0, 'pending');

    PERFORM stewards.crawl_status_write(v_id);
    IF p_dispatch THEN
        PERFORM stewards.work_item_dispatch_stage_safe(v_id, NULL);
    END IF;
    RETURN v_id;
END;
$crs$;

COMMENT ON FUNCTION stewards.crawl_start(text, text, jsonb, text, boolean) IS
'107 (re-authors 98, dispatch-safe swap only): starts a purpose-crawl, dispatched via work_item_dispatch_stage_safe.';


-- =====================================================================
-- §5 — 03-watchman: schema-level model defaults become nullable, and
-- watchman_pass_start degrades to a logged 'errored' pass + a deduped
-- hinge nudge instead of enqueueing chats certain to fail.
-- =====================================================================
ALTER TABLE stewards.watchman_config
    ALTER COLUMN default_provider DROP NOT NULL,
    ALTER COLUMN default_provider SET DEFAULT NULL,
    ALTER COLUMN default_model DROP NOT NULL,
    ALTER COLUMN default_model SET DEFAULT NULL;

-- One-time un-seed: 03's singleton INSERT (id=1) ran before this file
-- could change the column DEFAULT, so an already-migrated row — including
-- a fresh install today, since 03 loads before 107 — still carries the
-- old hardcoded literal. Null it ONLY when it still matches that literal
-- exactly (indistinguishable from "nobody touched it yet"; an operator
-- who deliberately chose the same value re-sets it in one CLI/wizard call).
UPDATE stewards.watchman_config SET default_provider = NULL
 WHERE id = 1 AND default_provider = 'opencode_go';
UPDATE stewards.watchman_config SET default_model = NULL
 WHERE id = 1 AND default_model = 'kimi-k2.6';

CREATE OR REPLACE FUNCTION stewards.watchman_pass_start(
    p_limit         int  DEFAULT 5,
    p_provider      text DEFAULT NULL,
    p_model         text DEFAULT NULL,
    p_agent_family  text DEFAULT NULL,
    p_actor         text DEFAULT 'watchman',
    p_trigger       text DEFAULT 'manual',
    p_token_budget  int  DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $wps$
DECLARE
    v_pass_id        text;
    v_provider       text;
    v_model          text;
    v_agent_family   text;
    v_budget         int;
    v_planned        int := 0;
    v_planned_tokens int := 0;
    v_estimate       int;
    v_budget_stopped boolean := false;
    v_slug           text;
    v_session_id     text;
    v_input          text;
    v_body           jsonb;
    v_payload        jsonb;
    v_cfg            stewards.watchman_config%ROWTYPE;
BEGIN
    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;

    -- 107 (lifeless core): the config row's own defaults are gone (NULL
    -- unless an operator or overlay set them) — fall through to the ONE
    -- substrate-wide catalog default, same last resort every other
    -- dispatch path uses. Still no hardcoded provider/model name here.
    v_provider     := coalesce(p_provider, v_cfg.default_provider, stewards.catalog_default_provider());
    v_model        := coalesce(p_model, v_cfg.default_model, stewards.catalog_default_model(v_provider));
    v_agent_family := coalesce(p_agent_family, v_cfg.default_agent_family, 'watchman-consolidator');
    v_budget       := coalesce(p_token_budget, v_cfg.token_budget, 50000);

    -- Lifeless-db degrade: nothing configured anywhere. Don't enqueue
    -- work_queue rows certain to fail at the bgworker with an opaque
    -- "unknown provider" — park the pass as errored and ring the hinge
    -- bell once (deduped) so a human opens the Models wizard.
    IF v_provider IS NULL OR v_model IS NULL THEN
        v_pass_id := 'watchman-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISS"Z"')
                     || '-' || substring(replace(gen_random_uuid()::text, '-', '') FROM 1 FOR 6);
        INSERT INTO stewards.watchman_passes
            (pass_id, started_at, finished_at, trigger, provider, model, agent_family,
             token_budget, actor, status, doc_count_planned)
        VALUES
            (v_pass_id, now(), now(), p_trigger, coalesce(v_provider, '(unset)'),
             coalesce(v_model, '(unset)'), v_agent_family, v_budget, p_actor, 'errored', 0);

        IF NOT EXISTS (
            SELECT 1 FROM stewards.hinge_reviews
             WHERE kind = 'model-unconfigured' AND subject = 'watchman' AND status = 'pending'
        ) THEN
            PERFORM stewards.hinge_enqueue('model-unconfigured', 'watchman',
                jsonb_build_object('note',
                    'watchman_pass_start: no provider/model configured (watchman_config defaults + the substrate default are both unset) — open the Models wizard.'),
                'watchman_pass_start');
        END IF;
        RETURN v_pass_id;
    END IF;

    v_pass_id := 'watchman-'
                 || to_char(now() AT TIME ZONE 'UTC',
                            'YYYYMMDD"T"HH24MISS"Z"')
                 || '-'
                 || substring(replace(gen_random_uuid()::text, '-', '')
                              FROM 1 FOR 6);

    INSERT INTO stewards.watchman_passes
        (pass_id, started_at, trigger, provider, model, agent_family,
         token_budget, actor, status)
    VALUES
        (v_pass_id, now(), p_trigger, v_provider, v_model,
         v_agent_family, v_budget, p_actor, 'in_progress');

    FOR v_slug IN
        SELECT slug FROM stewards.dirty_queue
         ORDER BY coalesce(last_consolidated_at, 'epoch'::timestamptz),
                  updated_at
         LIMIT p_limit
    LOOP
        v_estimate := stewards.estimate_chat_tokens(v_slug);

        IF v_planned_tokens + v_estimate > v_budget THEN
            v_budget_stopped := true;
            EXIT;
        END IF;

        v_session_id := substring(v_pass_id || '--' || v_slug FROM 1 FOR 200);

        INSERT INTO stewards.sessions (id, label, kind)
        VALUES (v_session_id,
                'Watchman pass ' || v_pass_id || ' for ' || v_slug,
                'agent')
        ON CONFLICT (id) DO NOTHING;

        v_input := stewards.watchman_input(v_slug);
        IF v_input IS NULL THEN
            CONTINUE;
        END IF;

        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (v_session_id, 'user', v_input, v_model);

        v_body := stewards.dry_run_chat(v_agent_family, v_model,
                                         v_session_id, NULL);

        v_payload := jsonb_build_object(
            'session_id',         v_session_id,
            'agent_family',       v_agent_family,
            'requested_model',    v_model,
            'meta',               v_body->'_meta',
            'body',               (v_body - '_meta')
                                  || jsonb_build_object('user', v_session_id),
            '_watchman_pass_id',  v_pass_id,
            '_watchman_slug',     v_slug,
            '_watchman_actor',    p_actor,
            '_watchman_estimate', v_estimate
        );

        INSERT INTO stewards.work_queue (kind, provider, payload)
        VALUES ('chat', v_provider, v_payload);

        v_planned        := v_planned + 1;
        v_planned_tokens := v_planned_tokens + v_estimate;
    END LOOP;

    UPDATE stewards.watchman_passes
       SET doc_count_planned = v_planned,
           budget_stopped    = v_budget_stopped
     WHERE pass_id = v_pass_id;

    IF v_planned = 0 THEN
        UPDATE stewards.watchman_passes
           SET finished_at = now(),
               status      = 'completed'
         WHERE pass_id = v_pass_id;
    END IF;

    UPDATE stewards.watchman_config
       SET last_pass_at = now(),
           updated_at   = now()
     WHERE id = 1;

    RETURN v_pass_id;
END;
$wps$;

COMMENT ON FUNCTION stewards.watchman_pass_start(int, text, text, text, text, text, int) IS
'107 (re-authors 03, lifeless-core degrade): resolves provider/model from watchman_config (now nullable) -> catalog_default_provider/model. When BOTH are still NULL, does not enqueue any chats — logs an errored pass row + a deduped hinge nudge (kind=model-unconfigured, subject=watchman) and returns the pass_id. Otherwise identical to the prior body.';


-- =====================================================================
-- §6 — 08-gates.sql / 10-sabbath-atonement.sql / 12-council.sql: the
-- self-check dispatch functions' hardcoded v_gate_model/v_gate_provider
-- (and council's v_provider/v_model/v_synth_model) now resolve through a
-- dedicated gate_dispatch_provider/gate_dispatch_model config pair
-- (mirroring 36-judge-local-routing.sql's shape) falling through to
-- catalog_default_provider/model — one central lifeless default, per the
-- audit's own recommendation for exactly this pattern. evaluate_gate /
-- generate_scenarios / verify_work_item / sabbath_dispatch / atonement_
-- dispatch degrade the SAME way work_item_dispatch_stage_safe does (park
-- the work_item in awaiting_review with a clear message) since they ARE
-- the thing that would otherwise advance the work_item's maturity — an
-- unconfigured gate must not silently leave the item stuck forever with
-- no signal. convene_council / synthesize_council raise a CLEAR pre-
-- flight error instead (no single work_item to park a multi-member
-- council on; failing loud before any work_queue row is created is
-- strictly better than a raw "unknown provider" surfacing later).
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.evaluate_gate(
    p_work_item_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $eg$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_produces_maturity text;
    v_template        text;
    v_input_summary   text;
    v_stage_output    text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_gate_model      text;
    v_gate_provider   text;
    v_gate_agent      text := 'plan';
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    v_gate_provider := coalesce(stewards.config_get_text('gate_dispatch_provider', NULL), stewards.catalog_default_provider());
    v_gate_model    := coalesce(stewards.config_get_text('gate_dispatch_model', NULL), stewards.catalog_default_model(v_gate_provider));
    IF v_gate_provider IS NULL OR v_gate_model IS NULL THEN
        UPDATE stewards.work_items
           SET status = 'awaiting_review',
               error  = 'no model configured for the maturity gate — open Settings -> Providers & Models (gate_dispatch_provider/model or the substrate default)',
               updated_at = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    SELECT produces_maturity INTO v_produces_maturity
      FROM stewards.pipeline_stage_maturity
     WHERE pipeline_family = v_wi.pipeline_family
       AND stage_name = v_wi.current_stage;

    SELECT template INTO v_template
      FROM stewards.gate_prompts WHERE id = 'evaluate';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.evaluate template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_output  := substring(
        coalesce(v_wi.stage_results->v_wi.current_stage->>'output', ''),
        1, 8000);

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family',   v_wi.pipeline_family,
        'current_stage',     v_wi.current_stage,
        'maturity',          v_wi.maturity,
        'produces_maturity', coalesce(v_produces_maturity, '(none)'),
        'revision_count',    v_wi.revision_count::text,
        'input_summary',     v_input_summary,
        'stage_output',      v_stage_output
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--gate-' ||
        v_wi.maturity || '--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('gate eval work_item=%s maturity=%s', v_wi.id, v_wi.maturity),
            'gate')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_gate_agent,
        'requested_model',    v_gate_model,
        'meta',               '{}'::jsonb,
        'body',               (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                              || jsonb_build_object('user', v_session_id),
        'tools_disabled',     true,
        '_work_item_id',      p_work_item_id::text,
        '_stage_name',        v_wi.current_stage,
        '_pipeline_family',   v_wi.pipeline_family,
        '_gate_eval',         true,
        '_gate_from_maturity', v_wi.maturity
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$eg$;

COMMENT ON FUNCTION stewards.evaluate_gate(uuid) IS
'107 (re-authors 08, lifeless-core): resolves gate_dispatch_provider/model (config) -> catalog_default_provider/model. Unconfigured parks the work_item in awaiting_review with a clear message instead of enqueueing a chat certain to fail (previously hardcoded qwen3.7-plus/opencode_go).';

CREATE OR REPLACE FUNCTION stewards.generate_scenarios(
    p_work_item_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $gs$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_template        text;
    v_input_summary   text;
    v_stage_output    text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_gate_model      text;
    v_gate_provider   text;
    v_gate_agent      text := 'plan';
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    v_gate_provider := coalesce(stewards.config_get_text('gate_dispatch_provider', NULL), stewards.catalog_default_provider());
    v_gate_model    := coalesce(stewards.config_get_text('gate_dispatch_model', NULL), stewards.catalog_default_model(v_gate_provider));
    IF v_gate_provider IS NULL OR v_gate_model IS NULL THEN
        UPDATE stewards.work_items
           SET status = 'awaiting_review',
               error  = 'no model configured for scenario generation — open Settings -> Providers & Models (gate_dispatch_provider/model or the substrate default)',
               updated_at = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    SELECT template INTO v_template
      FROM stewards.gate_prompts WHERE id = 'generate_scenarios';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.generate_scenarios template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_output := substring(
        coalesce(v_wi.spec, v_wi.stage_results->v_wi.current_stage->>'output', ''),
        1, 8000);

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family',     v_wi.pipeline_family,
        'input_summary',       v_input_summary,
        'spec_or_stage_output', v_stage_output
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--scenarios--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('scenarios gen work_item=%s', v_wi.id),
            'gate')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_gate_agent,
        'requested_model',    v_gate_model,
        'meta',               '{}'::jsonb,
        'body',               (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                              || jsonb_build_object('user', v_session_id),
        'tools_disabled',     true,
        '_work_item_id',      p_work_item_id::text,
        '_scenarios_gen',     true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$gs$;

COMMENT ON FUNCTION stewards.generate_scenarios(uuid) IS
'107 (re-authors 08, lifeless-core): resolves gate_dispatch_provider/model -> catalog_default. Unconfigured parks the work_item in awaiting_review instead of enqueueing a doomed chat (previously hardcoded kimi-k2.6/opencode_go).';

CREATE OR REPLACE FUNCTION stewards.verify_work_item(
    p_work_item_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $vw$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_template        text;
    v_input_summary   text;
    v_stage_output    text;
    v_scenarios_str   text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_gate_model      text;
    v_gate_provider   text;
    v_gate_agent      text := 'plan';
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    IF v_wi.scenarios IS NULL OR jsonb_array_length(v_wi.scenarios) = 0 THEN
        RAISE EXCEPTION 'verify_work_item: work_item % has no scenarios — call generate_scenarios first', p_work_item_id;
    END IF;

    v_gate_provider := coalesce(stewards.config_get_text('gate_dispatch_provider', NULL), stewards.catalog_default_provider());
    v_gate_model    := coalesce(stewards.config_get_text('gate_dispatch_model', NULL), stewards.catalog_default_model(v_gate_provider));
    IF v_gate_provider IS NULL OR v_gate_model IS NULL THEN
        UPDATE stewards.work_items
           SET status = 'awaiting_review',
               error  = 'no model configured for scenario verification — open Settings -> Providers & Models (gate_dispatch_provider/model or the substrate default)',
               updated_at = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    SELECT template INTO v_template
      FROM stewards.gate_prompts WHERE id = 'verify';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.verify template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_output := substring(
        coalesce(v_wi.stage_results->v_wi.current_stage->>'output', ''),
        1, 8000);

    SELECT string_agg('  - ' || s, E'\n')
      INTO v_scenarios_str
      FROM jsonb_array_elements_text(v_wi.scenarios) s;

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family', v_wi.pipeline_family,
        'input_summary',   v_input_summary,
        'scenarios',       coalesce(v_scenarios_str, '(none)'),
        'stage_output',    v_stage_output
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--verify--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('verify work_item=%s', v_wi.id),
            'gate')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_gate_agent,
        'requested_model',    v_gate_model,
        'meta',               '{}'::jsonb,
        'body',               (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                              || jsonb_build_object('user', v_session_id),
        'tools_disabled',     true,
        '_work_item_id',      p_work_item_id::text,
        '_verify',            true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$vw$;

COMMENT ON FUNCTION stewards.verify_work_item(uuid) IS
'107 (re-authors 08, lifeless-core): resolves gate_dispatch_provider/model -> catalog_default. Unconfigured parks the work_item in awaiting_review instead of enqueueing a doomed chat (previously hardcoded qwen3.7-plus/opencode_go).';

CREATE OR REPLACE FUNCTION stewards.sabbath_dispatch(
    p_work_item_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $sd$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_pipeline        stewards.pipelines%ROWTYPE;
    v_effective       boolean;
    v_template        text;
    v_input_summary   text;
    v_stage_summary   text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_gate_model      text;
    v_gate_provider   text;
    v_gate_agent      text := 'plan';
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'sabbath_dispatch: work_item % not found', p_work_item_id;
    END IF;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    v_effective := COALESCE(v_wi.sabbath_enabled, v_pipeline.sabbath_enabled);
    IF NOT v_effective THEN
        RAISE EXCEPTION 'sabbath_dispatch: sabbath not enabled (work_item override=%, pipeline=%)',
            COALESCE(v_wi.sabbath_enabled::text, 'NULL'),
            v_pipeline.sabbath_enabled;
    END IF;

    v_gate_provider := coalesce(stewards.config_get_text('gate_dispatch_provider', NULL), stewards.catalog_default_provider());
    v_gate_model    := coalesce(stewards.config_get_text('gate_dispatch_model', NULL), stewards.catalog_default_model(v_gate_provider));
    IF v_gate_provider IS NULL OR v_gate_model IS NULL THEN
        UPDATE stewards.work_items
           SET status = 'awaiting_review',
               error  = 'no model configured for the sabbath reflection — open Settings -> Providers & Models (gate_dispatch_provider/model or the substrate default)',
               updated_at = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    SELECT template INTO v_template FROM stewards.gate_prompts WHERE id = 'sabbath';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.sabbath template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_summary := substring(coalesce(v_wi.stage_results::text, ''), 1, 8000);

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family',       v_wi.pipeline_family,
        'input_summary',         v_input_summary,
        'stage_results_summary', v_stage_summary
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--sabbath--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('sabbath work_item=%s', v_wi.id),
            'sabbath')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',      v_session_id,
        'agent_family',    v_gate_agent,
        'requested_model', v_gate_model,
        'meta',            '{}'::jsonb,
        'body',            (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                           || jsonb_build_object('user', v_session_id),
        'tools_disabled',  true,
        '_work_item_id',   p_work_item_id::text,
        '_sabbath',        true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$sd$;

COMMENT ON FUNCTION stewards.sabbath_dispatch(uuid) IS
'107 (re-authors 10, lifeless-core): resolves gate_dispatch_provider/model -> catalog_default. Unconfigured parks the work_item in awaiting_review instead of enqueueing a doomed chat (previously hardcoded qwen3.7-plus/opencode_go).';

CREATE OR REPLACE FUNCTION stewards.atonement_dispatch(
    p_work_item_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $ad$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_pipeline        stewards.pipelines%ROWTYPE;
    v_effective       boolean;
    v_template        text;
    v_input_summary   text;
    v_stage_summary   text;
    v_actions_summary text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_gate_model      text;
    v_gate_provider   text;
    v_gate_agent      text := 'plan';
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'atonement_dispatch: work_item % not found', p_work_item_id;
    END IF;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    v_effective := COALESCE(v_wi.atonement_enabled, v_pipeline.atonement_enabled);
    IF NOT v_effective THEN
        RAISE EXCEPTION 'atonement_dispatch: atonement not enabled (work_item override=%, pipeline=%)',
            COALESCE(v_wi.atonement_enabled::text, 'NULL'),
            v_pipeline.atonement_enabled;
    END IF;

    v_gate_provider := coalesce(stewards.config_get_text('gate_dispatch_provider', NULL), stewards.catalog_default_provider());
    v_gate_model    := coalesce(stewards.config_get_text('gate_dispatch_model', NULL), stewards.catalog_default_model(v_gate_provider));
    IF v_gate_provider IS NULL OR v_gate_model IS NULL THEN
        UPDATE stewards.work_items
           SET status = 'awaiting_review',
               error  = 'no model configured for the atonement extraction — open Settings -> Providers & Models (gate_dispatch_provider/model or the substrate default)',
               updated_at = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    SELECT template INTO v_template FROM stewards.gate_prompts WHERE id = 'atonement';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.atonement template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_summary := substring(coalesce(v_wi.stage_results::text, ''), 1, 6000);

    SELECT string_agg(
             '  - [' || to_char(at, 'YYYY-MM-DD HH24:MI') || '] ' || action ||
             coalesce(' (' || diagnosis || ')', '') ||
             ': ' || observation,
             E'\n' ORDER BY at DESC)
      INTO v_actions_summary
      FROM (
        SELECT at, action, diagnosis, observation
          FROM stewards.steward_actions
         WHERE work_item_id = p_work_item_id
         ORDER BY at DESC
         LIMIT 20
      ) t;

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family',         v_wi.pipeline_family,
        'input_summary',           v_input_summary,
        'failure_count',           v_wi.failure_count::text,
        'quarantine_reason',       coalesce(v_wi.quarantine_reason, '(none)'),
        'steward_actions_summary', coalesce(v_actions_summary, '  (no steward actions recorded)'),
        'stage_results_summary',   v_stage_summary
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--atonement--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('atonement work_item=%s', v_wi.id),
            'atonement')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',      v_session_id,
        'agent_family',    v_gate_agent,
        'requested_model', v_gate_model,
        'meta',            '{}'::jsonb,
        'body',            (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                           || jsonb_build_object('user', v_session_id),
        'tools_disabled',  true,
        '_work_item_id',   p_work_item_id::text,
        '_atonement',      true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$ad$;

COMMENT ON FUNCTION stewards.atonement_dispatch(uuid) IS
'107 (re-authors 10, lifeless-core): resolves gate_dispatch_provider/model -> catalog_default. Unconfigured parks the work_item in awaiting_review instead of enqueueing a doomed chat (previously hardcoded kimi-k2.6/opencode_go).';

CREATE OR REPLACE FUNCTION stewards.convene_council(
    p_intent_id        uuid,
    p_binding_question text,
    p_members          jsonb,
    p_bishop           text,
    p_convened_by      text DEFAULT 'human'
) RETURNS uuid
LANGUAGE plpgsql AS $cc$
DECLARE
    v_council_id  uuid;
    v_intent      stewards.intents%ROWTYPE;
    v_member      jsonb;
    v_role        text;
    v_agent       text;
    v_model       text;
    v_session_id  text;
    v_template_id text;
    v_template    text;
    v_prompt      text;
    v_payload     jsonb;
    v_work_id     bigint;
    v_provider    text;
    v_tools_off   boolean;
    v_member_count int;
BEGIN
    SELECT * INTO v_intent FROM stewards.intents WHERE id = p_intent_id;
    IF v_intent.id IS NULL THEN
        RAISE EXCEPTION 'convene_council: intent % not found', p_intent_id;
    END IF;

    IF p_members IS NULL OR jsonb_typeof(p_members) <> 'array' THEN
        RAISE EXCEPTION 'convene_council: p_members must be a jsonb array';
    END IF;

    v_member_count := jsonb_array_length(p_members);
    IF v_member_count < 2 OR v_member_count > 5 THEN
        RAISE EXCEPTION 'convene_council: must have between 2 and 5 members (got %)', v_member_count;
    END IF;

    IF EXISTS (SELECT 1 FROM stewards.councils
                WHERE status IN ('deliberating', 'synthesizing', 'awaiting_bishop')) THEN
        RAISE EXCEPTION 'convene_council: one council at a time (D-F1) — resolve or dissolve the active council first';
    END IF;

    -- 107 (lifeless core): the substrate-wide last resort, resolved ONCE
    -- for members that don't declare their own model. No hardcoded
    -- 'opencode_go' — was DECLARE v_provider text := 'opencode_go'.
    v_provider := stewards.catalog_default_provider();

    INSERT INTO stewards.councils (intent_id, binding_question, convened_by, bishop)
    VALUES (p_intent_id, p_binding_question, p_convened_by, p_bishop)
    RETURNING id INTO v_council_id;

    FOR v_member IN SELECT * FROM jsonb_array_elements(p_members) LOOP
        v_role  := v_member->>'role';
        v_agent := v_member->>'agent_family';
        v_model := coalesce(v_member->>'model', stewards.catalog_default_model(v_provider));

        IF v_role NOT IN ('proposer', 'critic', 'synthesizer') THEN
            RAISE EXCEPTION 'convene_council: invalid role % for agent %', v_role, v_agent;
        END IF;
        IF v_model IS NULL OR v_provider IS NULL THEN
            RAISE EXCEPTION 'convene_council: member % (role %) has no model and no substrate default is configured — pass p_members[].model explicitly, or configure a default via Settings -> Providers & Models',
                v_agent, v_role;
        END IF;

        v_template_id := 'council_' || v_role;
        SELECT template INTO v_template
          FROM stewards.gate_prompts WHERE id = v_template_id;

        v_session_id := substring(
            'council--' || substring(v_council_id::text FROM 1 FOR 8) ||
            '--' || v_role || '--' || v_agent,
            1, 200);

        INSERT INTO stewards.sessions (id, label, kind)
        VALUES (v_session_id,
                format('council %s role=%s agent=%s', v_council_id, v_role, v_agent),
                'council')
        ON CONFLICT (id) DO NOTHING;

        v_prompt := stewards.render_template(v_template, jsonb_build_object(
            'intent_purpose',     v_intent.purpose,
            'binding_question',   p_binding_question,
            'proposer_responses', '(none yet — proposer responses arrive in parallel)',
            'member_responses',   '(none yet — members responding in parallel)'
        ));

        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (v_session_id, 'user', v_prompt, v_model);

        v_tools_off := (v_role = 'synthesizer');

        v_payload := jsonb_build_object(
            'session_id',      v_session_id,
            'agent_family',    v_agent,
            'requested_model', v_model,
            'meta',            '{}'::jsonb,
            'body',            (stewards.dry_run_chat(v_agent, v_model, v_session_id, NULL) - '_meta')
                               || jsonb_build_object('user', v_session_id),
            'tools_disabled',  v_tools_off,
            '_council_id',     v_council_id::text,
            '_council_member', true,
            '_council_role',   v_role
        );

        INSERT INTO stewards.work_queue (kind, provider, payload)
        VALUES ('chat', v_provider, v_payload)
        RETURNING id INTO v_work_id;

        INSERT INTO stewards.council_members (council_id, agent_family, role, work_id)
        VALUES (v_council_id, v_agent, v_role, v_work_id);
    END LOOP;

    RETURN v_council_id;
END;
$cc$;

COMMENT ON FUNCTION stewards.convene_council(uuid, text, jsonb, text, text) IS
'107 (re-authors 12, lifeless core): the fallback provider/model is now catalog_default_provider/model, not a hardcoded opencode_go/kimi-k2.6. A member with no model and no configured substrate default is a CLEAR pre-flight RAISE EXCEPTION (no single work_item exists yet to park in review) — fails loud before any work_queue row or council_members row is created, naming exactly which member and how to fix it.';

CREATE OR REPLACE FUNCTION stewards.synthesize_council(
    p_council_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $sc$
DECLARE
    v_council         stewards.councils%ROWTYPE;
    v_intent          stewards.intents%ROWTYPE;
    v_template        text;
    v_member_responses text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_synth_agent     text := 'plan';
    v_synth_provider  text;
    v_synth_model     text;
BEGIN
    SELECT * INTO v_council FROM stewards.councils WHERE id = p_council_id;
    IF v_council.id IS NULL THEN
        RAISE EXCEPTION 'synthesize_council: council % not found', p_council_id;
    END IF;
    IF v_council.status NOT IN ('deliberating', 'synthesizing') THEN
        RAISE EXCEPTION 'synthesize_council: council % status=%, expected deliberating/synthesizing',
                        p_council_id, v_council.status;
    END IF;

    v_synth_provider := stewards.catalog_default_provider();
    v_synth_model    := stewards.catalog_default_model(v_synth_provider);
    IF v_synth_provider IS NULL OR v_synth_model IS NULL THEN
        RAISE EXCEPTION 'synthesize_council: no substrate default model/provider configured — open Settings -> Providers & Models before synthesizing council %',
            p_council_id;
    END IF;

    SELECT * INTO v_intent FROM stewards.intents WHERE id = v_council.intent_id;

    SELECT template INTO v_template FROM stewards.gate_prompts WHERE id = 'council_synthesizer';

    SELECT string_agg(
             format(E'### %s (%s)\n\n%s', upper(role), agent_family,
                    coalesce(response, '(no response)')),
             E'\n\n---\n\n' ORDER BY role, agent_family)
      INTO v_member_responses
      FROM stewards.council_members
     WHERE council_id = p_council_id
       AND role IN ('proposer', 'critic');

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'intent_purpose',   v_intent.purpose,
        'binding_question', v_council.binding_question,
        'member_responses', coalesce(v_member_responses, '(no member responses recorded)')
    ));

    v_session_id := substring(
        'council--' || substring(v_council.id::text FROM 1 FOR 8) ||
        '--synthesize--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('council %s synthesizer (auto)', v_council.id),
            'council')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_synth_model);

    v_payload := jsonb_build_object(
        'session_id',           v_session_id,
        'agent_family',         v_synth_agent,
        'requested_model',      v_synth_model,
        'meta',                 '{}'::jsonb,
        'body',                 (stewards.dry_run_chat(v_synth_agent, v_synth_model, v_session_id, NULL) - '_meta')
                                || jsonb_build_object('user', v_session_id),
        'tools_disabled',       true,
        '_council_id',          v_council.id::text,
        '_council_synthesize',  true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_synth_provider, v_payload)
    RETURNING id INTO v_work_id;

    UPDATE stewards.councils
       SET status = 'synthesizing'
     WHERE id = p_council_id;

    RETURN v_work_id;
END;
$sc$;

COMMENT ON FUNCTION stewards.synthesize_council(uuid) IS
'107 (re-authors 12, lifeless core): the synthesizer''s provider/model is now catalog_default_provider/model (was a hardcoded ''kimi-k2.6''/inline literal ''opencode_go'' in the work_queue INSERT — two places naming the same thing two different ways). Unconfigured is a CLEAR pre-flight RAISE EXCEPTION before any work_queue row lands.';


-- =====================================================================
-- §7 — the escalation-ladder terminal sentinel, renamed. Same shape,
-- generic name: __queue_for_opus__ -> __queue_for_strongest__. Only the
-- SENTINEL STRING changes; the (empty-in-core) model_escalation matrix
-- and its consumers are otherwise byte-identical to their live bodies.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.pick_model(
    p_pipeline_family text,
    p_stage_name      text,
    p_attempt         int,
    p_diagnosis       text DEFAULT 'initial'
) RETURNS text
LANGUAGE plpgsql STABLE AS $pm$
DECLARE
    v_current_model text;
    v_escalation    record;
    i               int;
BEGIN
    SELECT default_model INTO v_current_model
      FROM stewards.stage_models
     WHERE pipeline_family = p_pipeline_family
       AND stage_name = p_stage_name;

    IF v_current_model IS NULL THEN
        RAISE EXCEPTION 'no stage_models row for %/%',
            p_pipeline_family, p_stage_name;
    END IF;

    IF p_attempt <= 1 OR p_diagnosis = 'initial' OR p_diagnosis IS NULL THEN
        RETURN v_current_model;
    END IF;

    FOR i IN 2..p_attempt LOOP
        SELECT * INTO v_escalation
          FROM stewards.model_escalation
         WHERE current_model = v_current_model
           AND diagnosis = p_diagnosis
           AND attempt_threshold <= i;

        IF v_escalation IS NULL OR v_escalation.next_model IS NULL THEN
            RETURN v_current_model;
        END IF;

        IF v_escalation.next_model = '__queue_for_strongest__' THEN
            RETURN '__queue_for_strongest__';
        END IF;

        v_current_model := v_escalation.next_model;
    END LOOP;

    RETURN v_current_model;
END;
$pm$;

COMMENT ON FUNCTION stewards.pick_model(text, text, int, text) IS
'107 (re-authors 06, sentinel rename only): picks the model for the next dispatch, walking model_escalation per (attempt, diagnosis). Returns the __queue_for_strongest__ sentinel (was __queue_for_opus__ — a deployer''s top rung is not always Opus, per 84-tool-effect-gate.sql''s own "a Fable hinge is now possible" note) when the chain exhausts. 06-cost.sql keeps the old name as the historical record; this is the live body.';

CREATE OR REPLACE FUNCTION stewards.steward_tick()
RETURNS int
LANGUAGE plpgsql AS $stk$
DECLARE
    v_count               int := 0;
    v_item                record;
    v_diagnosis           text;
    v_next_model          text;
    v_breaker_ok          boolean;
    v_attempt             int;
    v_retry_text          text;
    v_dispatched_work_id  bigint;
    v_provider            text;
    v_stage               jsonb;
    v_stage_model         text;
    v_forbid              boolean;
    v_excluded            jsonb;
    v_fp                  text;
    v_fm                  text;
BEGIN
    FOR v_item IN
        SELECT id, pipeline_family, current_stage, failure_count,
               last_failure_reason, escalation_state, intent_id
          FROM stewards.work_items
         WHERE status = 'failed'
           AND failure_count < 3
           AND quarantined_at IS NULL
           AND escalation_state = 'normal'
         ORDER BY updated_at ASC
         LIMIT 10
         FOR UPDATE SKIP LOCKED
    LOOP
        BEGIN
            v_attempt := v_item.failure_count + 1;

            IF stewards.cost_cap_exceeded(v_item.id) THEN
                UPDATE stewards.work_items
                   SET quarantined_at = now(),
                       quarantine_reason = 'cost_cap_exceeded'
                 WHERE id = v_item.id;

                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action, details)
                VALUES
                    (v_item.id,
                     'cumulative cost exceeded cap; quarantining',
                     'cost_limit',
                     'quarantine',
                     jsonb_build_object('quarantine_reason','cost_cap_exceeded'));

                PERFORM stewards.maybe_enqueue_atonement(v_item.id);

                v_count := v_count + 1;
                CONTINUE;
            END IF;

            v_diagnosis := stewards.diagnose_failure(
                v_item.last_failure_reason, v_item.failure_count);
            UPDATE stewards.work_items
               SET last_failure_diagnosis = v_diagnosis
             WHERE id = v_item.id;

            v_breaker_ok := stewards.breaker_check(
                v_item.pipeline_family, v_item.current_stage);
            IF NOT v_breaker_ok THEN
                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action)
                VALUES
                    (v_item.id,
                     format('breaker open for %s/%s; deferring',
                            v_item.pipeline_family, v_item.current_stage),
                     v_diagnosis,
                     'defer_breaker_open');
                v_count := v_count + 1;
                CONTINUE;
            END IF;

            IF v_diagnosis IN ('transient','timeout') THEN
                v_stage := stewards.pipeline_stage_lookup(
                    v_item.pipeline_family, v_item.current_stage);
                v_stage_model := v_stage->>'model';
                IF v_stage_model IS NOT NULL
                   AND EXISTS (SELECT 1 FROM stewards.model_aliases WHERE alias = v_stage_model) THEN
                    v_forbid := stewards.intent_forbids_training(v_item.intent_id)
                                AND NOT COALESCE((v_stage->>'public_io')::boolean, false);
                    v_excluded := stewards.alias_transient_failed_members(
                        v_item.id, v_item.current_stage);
                    SELECT m.provider, m.model INTO v_fp, v_fm
                      FROM stewards.pick_alias_member(v_stage_model, v_forbid, v_excluded) m;
                    IF v_fp IS NOT NULL AND v_fm IS NOT NULL THEN
                        UPDATE stewards.work_items
                           SET provider_override = v_fp,
                               model_override    = v_fm,
                               failure_count     = failure_count + 1
                         WHERE id = v_item.id;

                        -- 107: swapped to the safe wrapper so an alias
                        -- member that resolves but is STILL unusable
                        -- (capability-unusable, no substitute) breaks the
                        -- retry loop into awaiting_review instead of
                        -- retrying this same item forever.
                        v_dispatched_work_id := stewards.work_item_dispatch_stage_safe(
                            v_item.id, NULL, true);

                        INSERT INTO stewards.steward_actions
                            (work_item_id, observation, diagnosis, action, model_used,
                             details)
                        VALUES
                            (v_item.id,
                             format('alias %s failover -> %s/%s (attempt #%s after %s); work_id %s',
                                    v_stage_model, v_fp, v_fm, v_attempt, v_diagnosis,
                                    v_dispatched_work_id),
                             v_diagnosis,
                             CASE WHEN v_dispatched_work_id IS NULL THEN 'alias_failover_parked' ELSE 'alias_failover' END,
                             v_fm,
                             jsonb_build_object(
                                 'alias', v_stage_model,
                                 'provider', v_fp,
                                 'model', v_fm,
                                 'excluded', v_excluded,
                                 'dispatched_work_id', v_dispatched_work_id));

                        v_count := v_count + 1;
                        CONTINUE;
                    END IF;
                ELSIF v_stage IS NOT NULL AND v_stage_model IS NOT NULL THEN
                    UPDATE stewards.work_items
                       SET failure_count = failure_count + 1
                     WHERE id = v_item.id;
                    v_dispatched_work_id := stewards.work_item_dispatch_stage_safe(
                        v_item.id, NULL, true);
                    INSERT INTO stewards.steward_actions
                        (work_item_id, observation, diagnosis, action, model_used, details)
                    VALUES
                        (v_item.id,
                         format('pinned %s transient retry (attempt #%s after %s); work_id %s',
                                v_stage_model, v_attempt, v_diagnosis, v_dispatched_work_id),
                         v_diagnosis,
                         CASE WHEN v_dispatched_work_id IS NULL THEN 'pinned_retry_parked' ELSE 'pinned_retry' END,
                         v_stage_model,
                         jsonb_build_object('model', v_stage_model,
                                            'dispatched_work_id', v_dispatched_work_id));
                    v_count := v_count + 1;
                    CONTINUE;
                END IF;
            END IF;

            v_next_model := stewards.pick_model(
                v_item.pipeline_family, v_item.current_stage,
                v_attempt, v_diagnosis);

            IF v_next_model = '__queue_for_strongest__' THEN
                UPDATE stewards.work_items
                   SET escalation_state = 'queued',
                       escalation_attempts = escalation_attempts + 1
                 WHERE id = v_item.id;

                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action, model_used,
                     details)
                VALUES
                    (v_item.id,
                     'escalation chain exhausted; queued for human-mediated boost',
                     v_diagnosis,
                     'queue_for_strongest',
                     '__queue_for_strongest__',
                     jsonb_build_object(
                         'attempt', v_attempt,
                         'escalation_attempts',
                             (SELECT escalation_attempts FROM stewards.work_items
                               WHERE id = v_item.id)));
                v_count := v_count + 1;
                CONTINUE;
            END IF;

            SELECT provider INTO v_provider
              FROM stewards.model_pricing
             WHERE model = v_next_model
             ORDER BY effective_at DESC
             LIMIT 1;

            v_retry_text := stewards.retry_guidance_with_lessons(
                v_diagnosis, v_attempt,
                v_item.pipeline_family, v_item.current_stage);

            UPDATE stewards.work_items
               SET model_override     = v_next_model,
                   provider_override  = v_provider,
                   failure_count      = failure_count + 1
             WHERE id = v_item.id;

            -- 107: swapped to the safe wrapper. Previously an "unconfigured"
            -- failure here rolled back this whole BEGIN block (including the
            -- UPDATE just above), so the item's failure_count never advanced
            -- and steward_tick picked the SAME item again next tick, forever
            -- — the exact silent-retry-loop shape the audit named for the
            -- scheduler. Now it lands cleanly in awaiting_review instead.
            v_dispatched_work_id := stewards.work_item_dispatch_stage_safe(
                v_item.id, v_retry_text, true);

            INSERT INTO stewards.steward_actions
                (work_item_id, observation, diagnosis, action, model_used,
                 details)
            VALUES
                (v_item.id,
                 format('attempt #%s after %s; dispatched as work_id %s',
                        v_attempt, v_diagnosis, v_dispatched_work_id),
                 v_diagnosis,
                 CASE WHEN v_dispatched_work_id IS NULL THEN 'retry_parked_for_review' ELSE 'retry_dispatched' END,
                 v_next_model,
                 jsonb_build_object(
                     'attempt', v_attempt,
                     'retry_guidance', v_retry_text,
                     'dispatched_work_id', v_dispatched_work_id,
                     'provider_override', v_provider));

            v_count := v_count + 1;
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action, details)
                VALUES
                    (v_item.id,
                     'tick error: ' || SQLERRM,
                     COALESCE(v_diagnosis, 'unknown'),
                     'tick_error',
                     jsonb_build_object(
                         'sqlerrm', SQLERRM,
                         'sqlstate', SQLSTATE,
                         'pipeline_family', v_item.pipeline_family,
                         'current_stage', v_item.current_stage));
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
            v_count := v_count + 1;
        END;
    END LOOP;

    IF to_regprocedure('stewards.abort_conditions_evaluate()') IS NOT NULL THEN
        BEGIN
            v_count := v_count + stewards.abort_conditions_evaluate();
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                INSERT INTO stewards.steward_actions (observation, action, details)
                VALUES ('abort_conditions_evaluate failed: ' || SQLERRM, 'tick_error',
                        jsonb_build_object('sqlerrm', SQLERRM, 'sqlstate', SQLSTATE,
                                           'source', 'abort_conditions_evaluate'));
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END;
    END IF;

    RETURN v_count;
END;
$stk$;

COMMENT ON FUNCTION stewards.steward_tick() IS
'107 (re-authors 32''s FINAL body, sentinel rename + dispatch-safe swap): Watch->Diagnose->Act->Account. Per-item exception isolation; alias-failover + pinned-retry branches; otherwise lessons-aware retry + pick_model escalation (queue sentinel renamed __queue_for_strongest__). All 3 retry dispatch calls now go through work_item_dispatch_stage_safe, so an "unconfigured model" failure breaks the retry loop into awaiting_review instead of looping the same failed item forever (the UPDATE that bumps failure_count no longer rolls back with the exception, because there is no exception). 103''s guarded abort_conditions_evaluate() sweep is carried verbatim. 06/07/32''s own files keep the old sentinel name as the historical record.';


-- =====================================================================
-- §8 — the judge-family hand-built work_queue dispatches: parameterize
-- via judge_dispatch_provider/judge_dispatch_model (36's own config
-- pair, already meant for exactly these two named judges), falling
-- through to catalog_default_provider/model. 36's literal-default
-- config_set seeds are removed — one central lifeless default.
-- =====================================================================

-- Remove 36's literal defaults ('opencode_go'/'deepseek-v4-flash') — a
-- config row's absence IS "no preference" (config_get_text's own NULL-
-- safe default), consistent with every other config key this file adds.
DELETE FROM stewards.config WHERE key IN ('judge_dispatch_provider', 'judge_dispatch_model');

-- ── 15a-context-engrams.sql: extract_engrams ─────────────────────────
CREATE OR REPLACE FUNCTION stewards.extract_engrams(p_message_id bigint)
RETURNS bigint LANGUAGE plpgsql AS $ee$
DECLARE
    v_message      stewards.messages%ROWTYPE;
    v_work_item    stewards.work_items%ROWTYPE;
    v_binding      text;
    v_agent        stewards.agents%ROWTYPE;
    v_msg_prefix   text;
    v_user_message text;
    v_body         jsonb;
    v_payload      jsonb;
    v_wq_id        bigint;
    v_judge_provider text;
    v_judge_model    text;
BEGIN
    SELECT * INTO v_message FROM stewards.messages WHERE id = p_message_id;
    IF v_message.id IS NULL THEN
        RAISE EXCEPTION 'extract_engrams: message % not found', p_message_id;
    END IF;
    IF v_message.engrams IS NOT NULL THEN
        RETURN NULL;
    END IF;
    IF v_message.content LIKE '[JUDGE-PENDING]%' OR v_message.content LIKE '[JUDGE BRIEF]%'
       OR v_message.content LIKE '[CORPUS-INDEXED]%' THEN
        RETURN NULL;
    END IF;

    v_judge_provider := coalesce(stewards.config_get_text('judge_dispatch_provider', NULL), stewards.catalog_default_provider());
    v_judge_model    := coalesce(stewards.config_get_text('judge_dispatch_model', NULL), stewards.catalog_default_model(v_judge_provider));

    SELECT * INTO v_work_item
      FROM stewards.work_items
     WHERE v_message.session_id = ANY(session_ids)
     ORDER BY created_at DESC
     LIMIT 1;

    IF v_work_item.id IS NOT NULL THEN
        v_binding := COALESCE(v_work_item.input ->> 'binding_question', '');
    ELSE
        v_binding := '';
    END IF;

    SELECT * INTO v_agent
      FROM stewards.agents
     WHERE family = 'engram-extractor' AND active
     LIMIT 1;
    IF v_agent.family IS NULL THEN
        RAISE EXCEPTION 'extract_engrams: engram-extractor agent not registered';
    END IF;

    v_msg_prefix := substring(p_message_id::text FROM 1 FOR 8);

    v_user_message :=
        E'BINDING QUESTION:\n' || v_binding ||
        E'\n\nMESSAGE ID PREFIX (use this in engram ids): ' || v_msg_prefix ||
        E'\n\nDOCUMENT (' || length(v_message.content)::text || E' chars):\n---\n' ||
        v_message.content ||
        E'\n---\n\nExtract engrams. Output ONLY the JSON.';

    v_body := jsonb_build_object(
        'model', v_judge_model,
        'messages', jsonb_build_array(
            jsonb_build_object('role', 'system', 'content', v_agent.prompt),
            jsonb_build_object('role', 'user', 'content', v_user_message)
        ),
        'temperature', v_agent.temperature
    );
    IF v_agent.response_format IS NOT NULL THEN
        v_body := v_body || jsonb_build_object('response_format', v_agent.response_format);
    END IF;

    INSERT INTO stewards.sessions (id, kind, label)
    VALUES (
        'engram-ex-' || p_message_id::text,
        'tool',
        'engram extraction for message ' || p_message_id::text
    )
    ON CONFLICT (id) DO NOTHING;

    v_payload := jsonb_build_object(
        'session_id', 'engram-ex-' || p_message_id::text,
        'agent_family', 'engram-extractor',
        'requested_model', v_judge_model,
        'body', v_body,
        'tools_disabled', true,
        '_engram_extraction_target_msg_id', p_message_id,
        '_engram_extraction_binding', v_binding,
        '_engram_extraction_raw_chars', length(v_message.content)
    );

    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat', v_judge_provider, v_payload, 'pending')
    RETURNING id INTO v_wq_id;

    RAISE NOTICE 'extract_engrams: message=% queued wq=% raw_chars=% provider=% model=%',
        p_message_id, v_wq_id, length(v_message.content), v_judge_provider, v_judge_model;

    RETURN v_wq_id;
END;
$ee$;

COMMENT ON FUNCTION stewards.extract_engrams(bigint) IS
'107 (re-authors 15a, lifeless core): enqueues an engram extraction via judge_dispatch_provider/model (config) -> catalog_default_provider/model. Was hardcoded deepseek-v4-flash/opencode_go inline. If both resolve NULL, the work_queue insert''s own NOT NULL provider constraint fails — caught by the caller (trigger_extract_engrams_on_large_tool already wraps this in BEGIN/EXCEPTION, "compose_messages falls back to raw" per its own comment), same graceful-degrade shape as an unembedded doc.';

-- ── 15a-context-engrams.sql: map_reduce_extract_engrams ──────────────
CREATE OR REPLACE FUNCTION stewards.map_reduce_extract_engrams(
    p_message_id bigint,
    p_binding    text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $mre$
DECLARE
    v_parent     stewards.messages_raw_overflow%ROWTYPE;
    v_agent      stewards.agents%ROWTYPE;
    v_user_msg   text;
    v_body       jsonb;
    v_wq_id      bigint;
    v_count      int := 0;
    v_binding    text;
    v_msg_prefix text;
    v_judge_provider text;
    v_judge_model    text;
BEGIN
    v_judge_provider := coalesce(stewards.config_get_text('judge_dispatch_provider', NULL), stewards.catalog_default_provider());
    v_judge_model    := coalesce(stewards.config_get_text('judge_dispatch_model', NULL), stewards.catalog_default_model(v_judge_provider));

    SELECT binding_question INTO v_binding
      FROM stewards.messages_raw_overflow
     WHERE message_id = p_message_id LIMIT 1;
    v_binding := COALESCE(p_binding, v_binding, 'Extract key facts and findings.');

    SELECT * INTO v_agent FROM stewards.agents
     WHERE family = 'engram-extractor' AND active LIMIT 1;
    IF v_agent.family IS NULL THEN
        RAISE EXCEPTION 'map_reduce_extract_engrams: engram-extractor agent missing';
    END IF;

    INSERT INTO stewards.sessions (id, kind, label)
    VALUES ('mr-extract-' || p_message_id::text, 'tool',
            'map-reduce engram extraction for message ' || p_message_id::text)
    ON CONFLICT (id) DO NOTHING;

    v_msg_prefix := substring(p_message_id::text FROM 1 FOR 8);

    FOR v_parent IN
        SELECT * FROM stewards.messages_raw_overflow
         WHERE message_id = p_message_id
         ORDER BY parent_ordinal
    LOOP
        v_user_msg :=
            E'BINDING QUESTION:\n' || v_binding ||
            E'\n\nENGRAM ID PREFIX (use this in engram ids): ' || v_msg_prefix || '-p' || v_parent.parent_ordinal::text ||
            E'\n\nNOTE: this is one parent chunk of a larger document. Extract engrams from THIS CHUNK ONLY.' ||
            E'\n\nDOCUMENT CHUNK (' || length(v_parent.content)::text || E' chars):\n---\n' ||
            v_parent.content ||
            E'\n---\n\nExtract engrams. Output ONLY the JSON.';

        v_body := jsonb_build_object(
            'model', v_judge_model,
            'messages', jsonb_build_array(
                jsonb_build_object('role', 'system', 'content', v_agent.prompt),
                jsonb_build_object('role', 'user', 'content', v_user_msg)
            ),
            'temperature', v_agent.temperature
        );
        IF v_agent.response_format IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('response_format', v_agent.response_format);
        END IF;

        INSERT INTO stewards.work_queue (kind, provider, payload, status)
        VALUES (
            'chat',
            v_judge_provider,
            jsonb_build_object(
                'session_id', 'mr-extract-' || p_message_id::text,
                'agent_family', 'engram-extractor',
                'requested_model', v_judge_model,
                'body', v_body,
                'tools_disabled', true,
                '_map_reduce_extract_target_msg_id', p_message_id,
                '_map_reduce_extract_parent_id',    v_parent.id,
                '_map_reduce_extract_parent_ord',   v_parent.parent_ordinal
            ),
            'pending'
        )
        RETURNING id INTO v_wq_id;
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'message_id', p_message_id,
        'parents_dispatched', v_count,
        'binding', v_binding
    );
END;
$mre$;

COMMENT ON FUNCTION stewards.map_reduce_extract_engrams(bigint, text) IS
'107 (re-authors 15a, lifeless core): parent-chunk engram extraction via judge_dispatch_provider/model -> catalog_default. Was hardcoded deepseek-v4-flash/opencode_go inline.';

-- ── 15a-context-engrams.sql: re_extract_engrams ──────────────────────
CREATE OR REPLACE FUNCTION stewards.re_extract_engrams(
    p_message_id  bigint,
    p_new_binding text
) RETURNS bigint LANGUAGE plpgsql AS $ree$
DECLARE
    v_message    stewards.messages%ROWTYPE;
    v_agent      stewards.agents%ROWTYPE;
    v_old_engrams jsonb;
    v_history    jsonb;
    v_msg_prefix text;
    v_user_msg   text;
    v_body       jsonb;
    v_payload    jsonb;
    v_wq_id      bigint;
    v_judge_provider text;
    v_judge_model    text;
BEGIN
    v_judge_provider := coalesce(stewards.config_get_text('judge_dispatch_provider', NULL), stewards.catalog_default_provider());
    v_judge_model    := coalesce(stewards.config_get_text('judge_dispatch_model', NULL), stewards.catalog_default_model(v_judge_provider));

    SELECT * INTO v_message FROM stewards.messages WHERE id = p_message_id;
    IF v_message.id IS NULL THEN
        RAISE EXCEPTION 're_extract_engrams: message % not found', p_message_id;
    END IF;

    v_old_engrams := v_message.engrams;

    v_history := COALESCE(v_old_engrams -> '_history', '[]'::jsonb);
    IF v_old_engrams IS NOT NULL THEN
        v_history := v_history || jsonb_build_array(
            v_old_engrams - '_history'
            || jsonb_build_object('_archived_at', now())
        );
    END IF;

    UPDATE stewards.messages
       SET engrams = jsonb_build_object('_history', v_history)
     WHERE id = p_message_id;

    SELECT * INTO v_agent
      FROM stewards.agents WHERE family = 'engram-extractor' AND active LIMIT 1;
    IF v_agent.family IS NULL THEN
        RAISE EXCEPTION 're_extract_engrams: engram-extractor agent not registered';
    END IF;

    v_msg_prefix := substring(p_message_id::text FROM 1 FOR 8);

    v_user_msg :=
        E'BINDING QUESTION:\n' || p_new_binding ||
        E'\n\nMESSAGE ID PREFIX (use this in engram ids): ' || v_msg_prefix ||
        E'\n\nNOTE: this is a RE-EXTRACTION with a NEW binding question. The previous engrams have been archived; produce a fresh set tuned to this binding.' ||
        E'\n\nDOCUMENT (' || length(v_message.content)::text || E' chars):\n---\n' ||
        v_message.content ||
        E'\n---\n\nExtract engrams. Output ONLY the JSON.';

    v_body := jsonb_build_object(
        'model', v_judge_model,
        'messages', jsonb_build_array(
            jsonb_build_object('role', 'system', 'content', v_agent.prompt),
            jsonb_build_object('role', 'user', 'content', v_user_msg)
        ),
        'temperature', v_agent.temperature
    );
    IF v_agent.response_format IS NOT NULL THEN
        v_body := v_body || jsonb_build_object('response_format', v_agent.response_format);
    END IF;

    INSERT INTO stewards.sessions (id, kind, label)
    VALUES ('engram-re-ex-' || p_message_id::text, 'tool',
            'engram re-extraction for message ' || p_message_id::text)
    ON CONFLICT (id) DO NOTHING;

    v_payload := jsonb_build_object(
        'session_id', 'engram-re-ex-' || p_message_id::text,
        'agent_family', 'engram-extractor',
        'requested_model', v_judge_model,
        'body', v_body,
        'tools_disabled', true,
        '_engram_extraction_target_msg_id', p_message_id,
        '_engram_extraction_binding', p_new_binding,
        '_engram_extraction_raw_chars', length(v_message.content),
        '_re_extraction', true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat', v_judge_provider, v_payload, 'pending')
    RETURNING id INTO v_wq_id;

    RAISE NOTICE 're_extract_engrams: message=% old engrams archived; new extraction queued wq=%',
        p_message_id, v_wq_id;

    RETURN v_wq_id;
END;
$ree$;

COMMENT ON FUNCTION stewards.re_extract_engrams(bigint, text) IS
'107 (re-authors 15a, lifeless core): re-extraction via judge_dispatch_provider/model -> catalog_default. Was hardcoded deepseek-v4-flash/opencode_go inline.';

-- ── 15a-context-engrams.sql: apply_engram_extraction's provenance stamp ──
-- Once the dispatch above is dynamic, hardcoding 'extracted_by':
-- 'deepseek-v4-flash' would be a NEW lie (claiming a specific model ran
-- regardless of what actually did). Read it back from the work_queue row.
CREATE OR REPLACE FUNCTION stewards.apply_engram_extraction()
RETURNS trigger LANGUAGE plpgsql AS $aee$
DECLARE
    v_target_id     bigint;
    v_binding       text;
    v_raw_chars     int;
    v_content       text;
    v_parsed        jsonb;
    v_engrams_obj   jsonb;
    v_extracted_by  text;
BEGIN
    v_target_id := (NEW.payload ->> '_engram_extraction_target_msg_id')::bigint;
    v_binding   := NEW.payload ->> '_engram_extraction_binding';
    v_raw_chars := (NEW.payload ->> '_engram_extraction_raw_chars')::int;
    v_extracted_by := COALESCE(NULLIF(NEW.payload ->> 'requested_model', ''), NEW.provider, 'unknown');

    IF v_target_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.status = 'done' THEN
        DECLARE
            v_resp_str text;
            v_resp_json jsonb;
        BEGIN
            v_resp_str := NEW.result ->> 'response';
            IF v_resp_str IS NULL OR v_resp_str = '' THEN
                v_content := NULL;
            ELSE
                v_resp_json := v_resp_str::jsonb;
                v_content := v_resp_json #>> '{choices,0,message,content}';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_content := NULL;
        END;

        IF v_content IS NULL OR v_content = '' THEN
            v_engrams_obj := jsonb_build_object(
                'items', '[]'::jsonb,
                'injection_suspected', false,
                'injection_evidence', null,
                'extraction_error', 'empty response content',
                'extracted_at', now(),
                'extracted_by', v_extracted_by,
                'extracted_for_binding', v_binding,
                'raw_chars', v_raw_chars
            );
        ELSE
            BEGIN
                v_parsed := v_content::jsonb;
            EXCEPTION WHEN OTHERS THEN
                v_parsed := NULL;
            END;

            IF v_parsed IS NULL THEN
                v_engrams_obj := jsonb_build_object(
                    'items', '[]'::jsonb,
                    'injection_suspected', false,
                    'injection_evidence', null,
                    'extraction_error', 'response content not valid JSON',
                    'raw_response_preview', substring(v_content FROM 1 FOR 500),
                    'extracted_at', now(),
                    'extracted_by', v_extracted_by,
                    'extracted_for_binding', v_binding,
                    'raw_chars', v_raw_chars
                );
            ELSE
                DECLARE
                    v_items jsonb;
                    v_normalized jsonb := '[]'::jsonb;
                    v_item jsonb;
                BEGIN
                    IF jsonb_typeof(v_parsed) = 'array' THEN
                        v_items := v_parsed;
                    ELSE
                        v_items := COALESCE(
                            v_parsed -> 'items',
                            v_parsed -> 'engrams',
                            v_parsed -> 'memory_engrams',
                            '[]'::jsonb
                        );
                    END IF;
                    IF jsonb_typeof(v_items) <> 'array' THEN
                        v_items := '[]'::jsonb;
                    END IF;

                    FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
                        v_normalized := v_normalized || jsonb_build_array(
                            jsonb_build_object(
                                'id', COALESCE(v_item ->> 'id', ''),
                                'tier', lower(COALESCE(v_item ->> 'tier', 'cold')),
                                'topic', COALESCE(
                                    NULLIF(v_item ->> 'topic', ''),
                                    NULLIF(v_item ->> 'title', ''),
                                    ''
                                ),
                                'content', COALESCE(
                                    NULLIF(v_item ->> 'content', ''),
                                    NULLIF(v_item ->> 'context', ''),
                                    NULLIF(v_item ->> 'engram', ''),
                                    ''
                                ),
                                'provenance', lower(COALESCE(
                                    NULLIF(v_item ->> 'provenance', ''),
                                    'extracted'
                                )),
                                'preserved', COALESCE(v_item -> 'preserved', '{}'::jsonb)
                            )
                        );
                    END LOOP;

                    v_engrams_obj := jsonb_build_object(
                        'items', v_normalized,
                        'injection_suspected', COALESCE((v_parsed ->> 'injection_suspected')::boolean, false),
                        'injection_evidence', v_parsed -> 'injection_evidence',
                        'extracted_at', now(),
                        'extracted_by', v_extracted_by,
                        'extracted_for_binding', v_binding,
                        'raw_chars', v_raw_chars
                    );
                END;
            END IF;
        END IF;
    ELSE
        v_engrams_obj := jsonb_build_object(
            'items', '[]'::jsonb,
            'injection_suspected', false,
            'injection_evidence', null,
            'extraction_error', 'work_queue status=' || NEW.status || ' error=' || COALESCE(NEW.error, ''),
            'extracted_at', now(),
            'extracted_by', v_extracted_by,
            'extracted_for_binding', v_binding,
            'raw_chars', v_raw_chars
        );
    END IF;

    UPDATE stewards.messages
       SET engrams = v_engrams_obj
     WHERE id = v_target_id;

    RETURN NEW;
END;
$aee$;

COMMENT ON FUNCTION stewards.apply_engram_extraction() IS
'107 (re-authors es6, lifeless core): 4-shape normalizer + provenance, byte-identical except extracted_by now reads the work_queue row''s own requested_model/provider instead of hardcoding deepseek-v4-flash — that literal would have been a lie once extract_engrams'' dispatch became config-driven.';

-- ── 15b-context-surface.sql: dispatch_judge_brief ────────────────────
CREATE OR REPLACE FUNCTION stewards.dispatch_judge_brief(
    p_message_id    bigint,
    p_document      text,
    p_binding       text
) RETURNS bigint LANGUAGE plpgsql AS $djb$
DECLARE
    v_agent        stewards.agents;
    v_session_id   text;
    v_msg_prefix   text;
    v_user_message text;
    v_body         jsonb;
    v_payload      jsonb;
    v_wq_id        bigint;
    v_judge_provider text;
    v_judge_model    text;
BEGIN
    v_judge_provider := coalesce(stewards.config_get_text('judge_dispatch_provider', NULL), stewards.catalog_default_provider());
    v_judge_model    := coalesce(stewards.config_get_text('judge_dispatch_model', NULL), stewards.catalog_default_model(v_judge_provider));

    SELECT * INTO v_agent
      FROM stewards.agents
     WHERE family = 'judge-brief' AND active
     LIMIT 1;
    IF v_agent.family IS NULL THEN
        RAISE EXCEPTION 'dispatch_judge_brief: judge-brief agent not registered';
    END IF;

    v_session_id := 'judge-' || p_message_id::text;
    v_msg_prefix := substring(p_message_id::text FROM 1 FOR 8);

    v_user_message :=
        E'BINDING QUESTION:\n' || COALESCE(p_binding, '(none provided)') ||
        E'\n\nMESSAGE ID PREFIX (use in engram ids): ' || v_msg_prefix ||
        E'\n\nDOCUMENT (' || length(p_document)::text || E' chars):\n---\n' ||
        p_document ||
        E'\n---\n\nJudge this document. Output ONLY the JSON brief.';

    v_body := jsonb_build_object(
        'model', v_judge_model,
        'messages', jsonb_build_array(
            jsonb_build_object('role', 'system', 'content', v_agent.prompt),
            jsonb_build_object('role', 'user',   'content', v_user_message)
        ),
        'temperature', v_agent.temperature
    );
    IF v_agent.response_format IS NOT NULL THEN
        v_body := v_body || jsonb_build_object('response_format', v_agent.response_format);
    END IF;

    INSERT INTO stewards.sessions (id, kind, label)
    VALUES (v_session_id, 'tool', 'judge brief for message ' || p_message_id::text)
    ON CONFLICT (id) DO NOTHING;

    v_payload := jsonb_build_object(
        'session_id', v_session_id,
        'agent_family', 'judge-brief',
        'requested_model', v_judge_model,
        'body', v_body,
        'tools_disabled', true,
        '_judge_brief_target_msg_id', p_message_id,
        '_judge_brief_binding', COALESCE(p_binding, ''),
        '_judge_brief_raw_chars', length(p_document)
    );

    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat', v_judge_provider, v_payload, 'pending')
    RETURNING id INTO v_wq_id;

    RAISE NOTICE 'dispatch_judge_brief: message=% queued judge wq=% (% doc chars) provider=% model=%',
        p_message_id, v_wq_id, length(p_document), v_judge_provider, v_judge_model;

    RETURN v_wq_id;
END;
$djb$;

COMMENT ON FUNCTION stewards.dispatch_judge_brief(bigint, text, text) IS
'107 (re-authors 15b, lifeless core): enqueues the judge-brief chat via judge_dispatch_provider/model -> catalog_default. Was hardcoded deepseek-v4-flash/opencode_go inline. No max_tokens — reasoning budget unrestricted.';

-- ── 15b-context-surface.sql: apply_judge_brief's provenance stamp ────
CREATE OR REPLACE FUNCTION stewards.apply_judge_brief()
RETURNS trigger LANGUAGE plpgsql AS $ajb$
DECLARE
    v_target_id   bigint;
    v_binding     text;
    v_raw_chars   int;
    v_content     text;
    v_parsed      jsonb;
    v_engrams_in  jsonb;
    v_engram      jsonb;
    v_norm        jsonb := '[]'::jsonb;
    v_state       text;
    v_discarded   text;
    v_surface     text;
    v_engrams_obj jsonb;
    v_msg_prefix  text;
    v_dispatch_id   bigint;
    v_parent_session text;
    v_disp_row      stewards.work_queue%ROWTYPE;
    v_wi            stewards.work_items%ROWTYPE;
    v_still_pending int;
    v_chat_id       bigint;
    v_judged_by     text;
BEGIN
    v_target_id := (NEW.payload ->> '_judge_brief_target_msg_id')::bigint;
    v_binding   := NEW.payload ->> '_judge_brief_binding';
    v_raw_chars := (NEW.payload ->> '_judge_brief_raw_chars')::int;
    v_judged_by := 'judge-brief/' || COALESCE(NULLIF(NEW.payload ->> 'requested_model', ''), NEW.provider, 'unknown');
    IF v_target_id IS NULL THEN
        RETURN NEW;
    END IF;
    v_msg_prefix := substring(v_target_id::text FROM 1 FOR 8);

    IF NEW.status = 'done' THEN
        DECLARE
            v_resp_str  text;
            v_resp_json jsonb;
        BEGIN
            v_resp_str := NEW.result ->> 'response';
            IF v_resp_str IS NULL OR v_resp_str = '' THEN
                v_content := NULL;
            ELSE
                v_resp_json := v_resp_str::jsonb;
                v_content := v_resp_json #>> '{choices,0,message,content}';
                IF v_content IS NULL OR v_content = '' THEN
                    v_content := v_resp_json #>> '{choices,0,message,reasoning_content}';
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_content := NULL;
        END;

        IF v_content IS NOT NULL AND v_content <> '' THEN
            BEGIN
                v_parsed := v_content::jsonb;
            EXCEPTION WHEN OTHERS THEN
                v_parsed := NULL;
            END;
        END IF;
    END IF;

    IF v_parsed IS NOT NULL THEN
        v_state     := lower(COALESCE(v_parsed ->> 'state', 'done'));
        v_discarded := COALESCE(v_parsed ->> 'discarded', '');
        v_engrams_in := COALESCE(v_parsed -> 'engrams', v_parsed -> 'items', '[]'::jsonb);
        IF jsonb_typeof(v_engrams_in) <> 'array' THEN
            v_engrams_in := '[]'::jsonb;
        END IF;

        FOR v_engram IN SELECT * FROM jsonb_array_elements(v_engrams_in)
        LOOP
            v_norm := v_norm || jsonb_build_array(jsonb_build_object(
                'id', COALESCE(NULLIF(v_engram ->> 'id',''),
                               'judge-' || v_msg_prefix || '-e' || (jsonb_array_length(v_norm)+1)::text),
                'tier', lower(COALESCE(v_engram ->> 'tier', 'cold')),
                'topic', COALESCE(NULLIF(v_engram ->> 'topic',''),
                                  NULLIF(v_engram ->> 'title',''), ''),
                'content', COALESCE(NULLIF(v_engram ->> 'content',''),
                                    NULLIF(v_engram ->> 'context',''), ''),
                'provenance', lower(COALESCE(NULLIF(v_engram ->> 'provenance',''), 'extracted')),
                'preserved', COALESCE(v_engram -> 'preserved', '{}'::jsonb)
            ));
        END LOOP;
    ELSE
        v_state     := 'empty';
        v_discarded := 'judge brief unavailable (status=' || NEW.status
                    || COALESCE(', error=' || NEW.error, '')
                    || ') — raw document preserved, read via read_overflow_raw';
    END IF;

    v_engrams_obj := jsonb_build_object(
        'items', v_norm,
        'state', v_state,
        'discarded', v_discarded,
        'injection_suspected', COALESCE((v_parsed ->> 'injection_suspected')::boolean, false),
        'extracted_at', now(),
        'extracted_by', v_judged_by,
        'extracted_for_binding', v_binding,
        'raw_chars', v_raw_chars,
        'source', 'es3-judge'
    );

    v_surface := stewards.render_judge_brief_surface(
        v_target_id,
        jsonb_build_object('engrams', v_norm, 'state', v_state, 'discarded', v_discarded)
    );

    UPDATE stewards.messages
       SET engrams = v_engrams_obj,
           content = v_surface
     WHERE id = v_target_id;

    RETURN NEW;
END;
$ajb$;

COMMENT ON FUNCTION stewards.apply_judge_brief() IS
'107 (re-authors es7.4, lifeless core): completion handler, byte-identical except extracted_by now reads the dispatching work_queue row''s own requested_model/provider ("judge-brief/<model>") instead of hardcoding "judge-brief/deepseek-v4-flash".';

-- ── 16-subagents.sql: consult_subagent_dispatch's judge branch ───────
CREATE OR REPLACE FUNCTION stewards.consult_subagent_dispatch(
    p_session_id text,
    p_question   text
) RETURNS bigint LANGUAGE plpgsql AS $csd$
DECLARE
    v_soft_cap   constant int := 5;
    v_prior      int;
    v_question   text;
    v_judge_msgid bigint;
    v_document   text;
    v_binding    text;
    v_prior_ans  text;
    v_agent      stewards.agents;
    v_body       jsonb;
    v_payload    jsonb;
    v_wq_id      bigint;
    v_family     text;
    v_model      text;
    v_provider   text;
    v_judge_provider text;
    v_judge_model    text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM stewards.sessions WHERE id = p_session_id) THEN
        RAISE EXCEPTION 'consult_subagent_dispatch: session % not found', p_session_id;
    END IF;
    IF COALESCE(trim(p_question), '') = '' THEN
        RAISE EXCEPTION 'consult_subagent_dispatch: question is empty';
    END IF;

    SELECT count(*) INTO v_prior
      FROM stewards.messages
     WHERE session_id = p_session_id
       AND role = 'user'
       AND content LIKE '[CONSULT]%';

    v_question := p_question;
    IF v_prior >= v_soft_cap THEN
        v_question :=
            E'[STEWARD NOTICE — soft cap reached]\n'
         || E'You have re-engaged this sub-agent ' || v_prior::text
         || E' times (soft cap ' || v_soft_cap::text || E'). Each re-ask spends real budget. '
         || E'If you can answer your binding question from what you already hold, do that '
         || E'instead. If this consult is genuinely needed, proceed and it will be honored.'
         || E'\n\n' || p_question;
    END IF;

    INSERT INTO stewards.messages (session_id, role, content)
    VALUES (p_session_id, 'user', '[CONSULT] ' || v_question);

    -- ---- Judge session: rebuild the document context manually -------
    IF p_session_id LIKE 'judge-%' THEN
        v_judge_msgid := NULLIF(substring(p_session_id FROM 7), '')::bigint;

        SELECT content, binding_question
          INTO v_document, v_binding
          FROM stewards.messages_raw_overflow
         WHERE message_id = v_judge_msgid
         ORDER BY parent_ordinal ASC
         LIMIT 1;

        IF v_document IS NULL THEN
            RAISE EXCEPTION 'consult_subagent_dispatch: no preserved document for judge session % (msg %)',
                p_session_id, v_judge_msgid;
        END IF;

        SELECT content INTO v_prior_ans
          FROM stewards.messages
         WHERE session_id = p_session_id AND role = 'assistant'
         ORDER BY id DESC LIMIT 1;

        SELECT * INTO v_agent
          FROM stewards.agents WHERE family = 'judge-brief' AND active LIMIT 1;
        IF v_agent.family IS NULL THEN
            RAISE EXCEPTION 'consult_subagent_dispatch: judge-brief agent not registered';
        END IF;

        v_judge_provider := coalesce(stewards.config_get_text('judge_dispatch_provider', NULL), stewards.catalog_default_provider());
        v_judge_model    := coalesce(stewards.config_get_text('judge_dispatch_model', NULL), stewards.catalog_default_model(v_judge_provider));

        v_body := jsonb_build_object(
            'model', v_judge_model,
            'messages', jsonb_build_array(
                jsonb_build_object('role','system','content', v_agent.prompt),
                jsonb_build_object('role','user','content',
                    E'BINDING QUESTION:\n' || COALESCE(v_binding,'(none)') ||
                    E'\n\nDOCUMENT (' || length(v_document)::text || E' chars):\n---\n' ||
                    v_document || E'\n---'),
                jsonb_build_object('role','assistant','content',
                    COALESCE(v_prior_ans, '(prior brief unavailable)')),
                jsonb_build_object('role','user','content',
                    E'FOLLOW-UP — re-judge the SAME document for this new question:\n'
                    || v_question ||
                    E'\n\nOutput ONLY the JSON brief, scoped to this follow-up.')
            ),
            'temperature', v_agent.temperature
        );
        IF v_agent.response_format IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('response_format', v_agent.response_format);
        END IF;

        v_payload := jsonb_build_object(
            'session_id', p_session_id,
            'agent_family', 'judge-brief',
            'requested_model', v_judge_model,
            'body', v_body,
            'tools_disabled', true,
            '_consult_subagent_session', p_session_id,
            '_consult_reask_index', v_prior + 1
        );

        INSERT INTO stewards.work_queue (kind, provider, payload, status)
        VALUES ('chat', v_judge_provider, v_payload, 'pending')
        RETURNING id INTO v_wq_id;

        RAISE NOTICE 'consult_subagent_dispatch: judge session % re-engaged, chat wq=% (re-ask #%)',
            p_session_id, v_wq_id, v_prior + 1;
        RETURN v_wq_id;
    END IF;

    -- ---- Any other sub-agent session: normal continuation -----------
    SELECT payload ->> 'agent_family', payload ->> 'requested_model', provider
      INTO v_family, v_model, v_provider
      FROM stewards.work_queue
     WHERE kind = 'chat'
       AND payload ->> 'session_id' = p_session_id
     ORDER BY id DESC LIMIT 1;

    IF v_family IS NULL THEN
        RAISE EXCEPTION 'consult_subagent_dispatch: cannot resolve agent for session % (no prior chat)',
            p_session_id;
    END IF;

    SELECT stewards.chat_post_internal(v_family, v_model, p_session_id, v_provider)
      INTO v_wq_id;

    UPDATE stewards.work_queue
       SET payload = payload || jsonb_build_object(
               '_consult_subagent_session', p_session_id,
               '_consult_reask_index', v_prior + 1)
     WHERE id = v_wq_id;

    RAISE NOTICE 'consult_subagent_dispatch: session % re-engaged via chat_post_internal, chat wq=% (re-ask #%)',
        p_session_id, v_wq_id, v_prior + 1;
    RETURN v_wq_id;
END;
$csd$;

COMMENT ON FUNCTION stewards.consult_subagent_dispatch(text, text) IS
'107 (re-authors ES.3.s3, lifeless core): the judge-session re-engagement branch dispatches via judge_dispatch_provider/model -> catalog_default (was hardcoded deepseek-v4-flash/opencode_go inline). The non-judge continuation branch is unchanged.';

-- ── 15a-context-engrams.sql: trigger_populate_engram_embeddings' embed
--    provider literal, nulled for source clarity. Cosmetic only — §2's
--    kind=''embed'' BEFORE INSERT trigger overwrites NEW.provider (or
--    cancels the row) unconditionally regardless of what this names.
CREATE OR REPLACE FUNCTION stewards.trigger_populate_engram_embeddings()
RETURNS trigger LANGUAGE plpgsql AS $tpe$
DECLARE
    v_item          jsonb;
    v_engram_id     text;
    v_tier          text;
    v_topic         text;
    v_content       text;
    v_preview       text;
    v_composite_id  text;
    v_session       text;
    v_project       text;
    v_wq_id         bigint;
BEGIN
    SELECT session_id INTO v_session FROM stewards.messages WHERE id = NEW.id;
    SELECT wi.project_association INTO v_project
      FROM stewards.work_items wi
     WHERE v_session = ANY(wi.session_ids)
     ORDER BY wi.created_at DESC LIMIT 1;

    FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(NEW.engrams -> 'items', '[]'::jsonb))
    LOOP
        v_engram_id    := v_item ->> 'id';
        v_tier         := lower(COALESCE(v_item ->> 'tier', 'cold'));
        v_topic        := COALESCE(v_item ->> 'topic', '');
        v_content      := COALESCE(v_item ->> 'content', '');
        v_preview      := substring(v_content FROM 1 FOR 200);
        v_composite_id := NEW.id::text || ':' || v_engram_id;

        INSERT INTO stewards.engram_embeddings
            (id, message_id, engram_id, tier, topic, content_preview, session_id, project_association)
        VALUES
            (v_composite_id, NEW.id, v_engram_id, v_tier, v_topic, v_preview, v_session, v_project)
        ON CONFLICT (id) DO UPDATE
           SET tier = EXCLUDED.tier,
               topic = EXCLUDED.topic,
               content_preview = EXCLUDED.content_preview,
               session_id = EXCLUDED.session_id,
               project_association = EXCLUDED.project_association,
               embedded_at = CASE WHEN stewards.engram_embeddings.content_preview <> EXCLUDED.content_preview
                                  THEN NULL ELSE stewards.engram_embeddings.embedded_at END;

        IF NOT EXISTS (
            SELECT 1 FROM stewards.engram_embeddings
             WHERE id = v_composite_id AND embedded_at IS NOT NULL
        ) THEN
            INSERT INTO stewards.work_queue (kind, provider, payload, status)
            VALUES (
                'embed',
                NULL,  -- 107: the kind='embed' route trigger (§2) always supplies the real value (or cancels the row) — no literal to name here.
                jsonb_build_object(
                    'target_table', 'engram_embeddings',
                    'target_id', v_composite_id,
                    'text', COALESCE(v_topic || E'\n\n' || v_content, v_content, '')
                ),
                'pending'
            )
            RETURNING id INTO v_wq_id;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$tpe$;

COMMENT ON FUNCTION stewards.trigger_populate_engram_embeddings() IS
'107 (re-authors 15a, cosmetic only): the embed work_queue insert names no provider literal — trigger_embed_provider_route (§2) supplies it (or cancels the row) unconditionally for every kind=embed row regardless of what this INSERT passes. Behavior is unchanged from the prior hardcoded ''opencode_go'' (which the route trigger already overwrote every time).';


-- =====================================================================
-- §9 — two generic strip sweeps, run once against the FINAL state of
-- stewards.pipelines (every core file has loaded by the time this file
-- runs). Both are alias-aware and idempotent (safe to re-run on a
-- rebuild — CREATE OR REPLACE / re-running this file is exactly that).
-- =====================================================================

-- (a) stages jsonb: drop 'model'/'provider' from every stage UNLESS the
-- model value is one of the reserved role-alias names (35-research-doc-
-- construction.sql's already-correct pattern — reason/critic/ingest/
-- vision/review resolve via model_aliases, not a literal, and must be
-- preserved verbatim), and except the two pipelines explicitly documented
-- as KEEP-as-example (17-personas.sql's persona-turn-lmstudio/gemini —
-- naming honesty examples of an alternate backend, not a routing default).
UPDATE stewards.pipelines
   SET stages = (
       SELECT COALESCE(jsonb_agg(
                  CASE
                      WHEN stage ? 'model'
                           AND stage ->> 'model' IN ('reason','critic','ingest','vision','review')
                      THEN stage
                      ELSE (stage - 'model' - 'provider')
                  END
                  ORDER BY ord), '[]'::jsonb)
         FROM jsonb_array_elements(stages) WITH ORDINALITY AS t(stage, ord)
   )
 WHERE family NOT IN ('persona-turn-lmstudio', 'persona-turn-gemini')
   AND jsonb_typeof(stages) = 'array'
   AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(stages) s
        WHERE (s ? 'model' AND s ->> 'model' NOT IN ('reason','critic','ingest','vision','review'))
           OR (s ? 'provider')
   );

-- (b) pipeline metadata: drop the brainstorm-lens shape's default_model/
-- default_provider/suggested_model/suggested_provider (j8b/j9b, 12
-- pipelines x up to 4 keys each). No pipeline needs to be excluded here —
-- nothing legitimate stores a role-alias name under these specific keys
-- (35's pattern lives entirely in stages.model, never in metadata).
UPDATE stewards.pipelines
   SET metadata = metadata - 'default_model' - 'default_provider'
                          - 'suggested_model' - 'suggested_provider'
 WHERE metadata ?| array['default_model','default_provider','suggested_model','suggested_provider'];

-- (c) stage_models: every row is operator policy by the table's own
-- COMMENT (06-cost.sql: "Operator policy — seed via the overlay"),
-- exactly parallel to how model_pricing/model_escalation already ship
-- empty. Truncate outright rather than hand-deleting per (pipeline,
-- stage) across 13/20/90/94/99/98/87/102's INSERTs — a mechanical sweep
-- that cannot miss a row a hand-edit would. pick_model() raising 'no
-- stage_models row' on a virgin install is a STEWARD-RETRY-path failure
-- only (never first dispatch, which reads stages.model/pipeline.metadata
-- — both handled above) and is already caught by steward_tick's per-item
-- EXCEPTION (logs 'tick error', the loop continues).
DELETE FROM stewards.stage_models;

-- =====================================================================
-- End of 107-lifeless-core.sql
-- =====================================================================
-- ===== [was 35-research-doc-construction.sql] =====
-- =====================================================================
-- 35-research-doc-construction.sql — recast research-summary + research-write
-- onto agentic doc-construction (R2b/R2c of the local-learnings rollout).
-- =====================================================================
-- 13-research-pipelines.sql defines these as one-shot pipelines whose synthesize
-- stage EMITS the whole digest/piece as its generation (then review verifies the
-- text). On a small local model that one-shot generation trips the reaper, hogs
-- the slot, and 500s on grammar — the same failures the playlist + book digesters
-- hit. This file re-shapes both so the model BUILDS the artifact via doc_* tool-
-- call diffs and its chat reply is a journal (agentic-doc-construction.md):
--
--   research-summary:  gather -> build -> critique
--   research-write:    context_gather -> gather -> build -> critique
--
-- It swaps synthesize->build (doc_* construction, no publish) and review->critique
-- (doc_current -> doc_read -> doc_patch -> doc_finalize), preserving the well-tuned
-- gather / context_gather stages (only their `next` + model role are touched). The
-- pipeline pools its doc via doc_finalize (which falls back to the work item's
-- project, since a research digest has no static project like a book), so
-- auto_materialize is OFF + metadata.pools_via_tool is set (08-gates skips the
-- auto-pool arm — else the critique journal would be pooled as the digest).
--
-- Stages name ROLES (ingest/reason/critic); the alias router picks the best
-- available member (local-first via the workspace overlay; public default via
-- examples/models.sql). Idempotent: the swaps match both the old (synthesize/
-- review) and new (build/critique) stage names. Requires 13 + 34 (doc tools).
-- =====================================================================

-- ── shared stage builders (build = doc_* construct; critique = patch + finalize)
DO $recast$
DECLARE
    v_summary_build    jsonb;
    v_summary_critique jsonb;
    v_write_build      jsonb;
    v_write_critique   jsonb;
BEGIN

-- research-summary BUILD (daily digest, from the items brief)
v_summary_build := jsonb_build_object(
    'name','build','next','critique','model','reason','agent_family','research',
    'auto_advance',true,'tools_disabled',false,
    'input_template',
      'Binding question: {{input.binding_question}}' || E'\n\n' ||
      'You are the BUILD stage. BUILD the daily digest as a document using your doc tools — do NOT write the digest as your reply.' || E'\n\n' ||
      'Items brief from the gather stage:' || E'\n\n' ||
      '{{stage_results.gather.output}}' || E'\n\n' ||
      'Steps:' || E'\n' ||
      '1. Call doc_create with a short title derived from the binding question (no project — it inherits the work item''s intent).' || E'\n' ||
      '2. Build the digest with doc_append_section (one call each, small). A 24-hour scan, ~300-700 words total — not a deep dive. Every claim gets an inline [Title](URL) link; paraphrase by default. Sections (adapt to what the day produced):' || E'\n' ||
      '   - "Headlines" — the 1-3 most important items, one short paragraph each.' || E'\n' ||
      '   - "Notable" — second-tier items, one line each with a link.' || E'\n' ||
      '   - "Skeptical takes" — credible dissenting voices, if any.' || E'\n' ||
      '   - "Carry-forward" — what to watch tomorrow; any deep-research candidates.' || E'\n' ||
      '   If the day was slow, say so honestly — a three-line digest beats manufactured importance.' || E'\n' ||
      '3. Call doc_read to review; fix weak spots with doc_patch. Do NOT finalize — the critique stage does.' || E'\n' ||
      '4. Reply with a short JOURNAL (1-3 sentences) + the draft handle. Do NOT paste the digest.' );

-- research-summary CRITIQUE (review the draft, then doc_finalize)
v_summary_critique := jsonb_build_object(
    'name','critique','next',NULL,'model','critic','agent_family','research',
    'auto_advance',true,'tools_disabled',false,
    'input_template',
      'Binding question: {{input.binding_question}}' || E'\n\n' ||
      'You are the CRITIQUE stage — the final review before the digest is pooled. The build stage built a draft for this run.' || E'\n\n' ||
      'Work ONLY from the draft. Your tools are doc_current, doc_read, doc_patch, doc_append_section, doc_finalize. Do NOT fetch_url or web_search — you are reviewing the draft, not re-gathering. Converge to finalize.' || E'\n\n' ||
      'Steps:' || E'\n' ||
      '1. doc_current to get the handle, then doc_read it once.' || E'\n' ||
      '2. Check: every claim has an inline link; recency (items within ~24-48h or framed as still-trending); no rhetorical inflation (framing no hotter than the source); honest emptiness if the day was slow. Fix problems with doc_patch (a few targeted edits, not a rewrite).' || E'\n' ||
      '3. Call doc_finalize with the handle to pool the digest.' || E'\n' ||
      '4. Reply with a short JOURNAL (1-3 sentences): what you fixed and that you pooled it. Do NOT paste the digest.' );

-- research-write BUILD (deep piece, from prior context + sources brief)
v_write_build := jsonb_build_object(
    'name','build','next','critique','model','reason','agent_family','research',
    'auto_advance',true,'tools_disabled',false,
    'input_template',
      'Binding question: {{input.binding_question}}' || E'\n\n' ||
      'You are the BUILD stage. BUILD the research piece as a document using your doc tools — do NOT write the piece as your reply.' || E'\n\n' ||
      'Prior context (context_gather stage):' || E'\n' || '{{stage_results.context_gather.output}}' || E'\n\n' ||
      'Sources brief (gather stage):' || E'\n' || '{{stage_results.gather.output}}' || E'\n\n' ||
      'Steps:' || E'\n' ||
      '1. Call doc_create with a title derived from the binding question (no project — it inherits the work item''s intent).' || E'\n' ||
      '2. Build the piece with doc_append_section (one call each). Draw on the sources brief; do NOT introduce new sources. Every non-trivial claim cites its source inline [Title](URL); say so where a claim is your synthesis across sources. Quote verbatim only when the source text is in front of you. Suggested sections (adapt to the binding question): "Headlines" (3-5 findings that answer it), "Notable", "Skeptical takes", "Open questions". 800-2500 words by depth; resist padding; honest uncertainty over fabrication.' || E'\n' ||
      '3. Call doc_read to review; fix weak or uncited claims with doc_patch. Do NOT finalize — the critique stage does.' || E'\n' ||
      '4. Reply with a short JOURNAL (1-3 sentences) + the draft handle. Do NOT paste the piece.' );

-- research-write CRITIQUE
v_write_critique := jsonb_build_object(
    'name','critique','next',NULL,'model','critic','agent_family','research',
    'auto_advance',true,'tools_disabled',false,
    'input_template',
      'Binding question: {{input.binding_question}}' || E'\n\n' ||
      'You are the CRITIQUE stage — the final review before the piece is pooled. The build stage built a draft for this run.' || E'\n\n' ||
      'Work ONLY from the draft. Tools: doc_current, doc_read, doc_patch, doc_append_section, doc_finalize. Do NOT fetch_url or web_search — review the draft, do not re-research. Converge to finalize.' || E'\n\n' ||
      'Steps:' || E'\n' ||
      '1. doc_current to get the handle, then doc_read it once.' || E'\n' ||
      '2. Check against the binding question: every factual claim has a citation; citations are credible; the piece actually answers what was asked; honest uncertainty where the sources are thin (no fabricated certainty). Fix with doc_patch; where a claim is unverifiable from the draft, flag it in the text rather than inventing support.' || E'\n' ||
      '3. Call doc_finalize with the handle to pool the piece.' || E'\n' ||
      '4. Reply with a short JOURNAL (1-3 sentences): what you fixed and that you pooled it. Do NOT paste the piece.' );

-- gather/context_gather get a HARD tool-round cap so a weak local model can't loop
-- searching forever without producing its brief — the dispatch force-stops tool
-- calls after max_tool_rounds_hard and the model must emit its final answer (the
-- brief). The notebook (33) bounds the per-turn CONTEXT; this bounds the NUMBER of
-- rounds. (gather over-searched ~10 rounds without converging on the local rig.)
-- ── research-summary: swap synthesize->build, review->critique; gather->ingest+next=build+caps
UPDATE stewards.pipelines p SET stages = (
    SELECT jsonb_agg(
        CASE
            WHEN e->>'name' = 'gather'                  THEN (e - 'provider') || jsonb_build_object('model','ingest','next','build','max_tool_rounds',5,'max_tool_rounds_hard',8,'tool_groups',jsonb_build_array('web-research'))
            WHEN e->>'name' IN ('synthesize','build')   THEN v_summary_build
            WHEN e->>'name' IN ('review','critique')    THEN v_summary_critique
            ELSE e
        END ORDER BY ord)
    FROM jsonb_array_elements(p.stages) WITH ORDINALITY t(e, ord))
WHERE p.family = 'research-summary';

-- ── research-write: swap synthesize->build, review->critique; context_gather/gather->ingest, gather.next=build+caps
UPDATE stewards.pipelines p SET stages = (
    SELECT jsonb_agg(
        CASE
            WHEN e->>'name' = 'context_gather'          THEN (e - 'provider') || jsonb_build_object('model','ingest','max_tool_rounds',4,'max_tool_rounds_hard',6,'tool_groups',jsonb_build_array('substrate-read'))
            WHEN e->>'name' = 'gather'                  THEN (e - 'provider') || jsonb_build_object('model','ingest','next','build','max_tool_rounds',5,'max_tool_rounds_hard',8,'tool_groups',jsonb_build_array('web-research'))
            WHEN e->>'name' IN ('synthesize','build')   THEN v_write_build
            WHEN e->>'name' IN ('review','critique')    THEN v_write_critique
            ELSE e
        END ORDER BY ord)
    FROM jsonb_array_elements(p.stages) WITH ORDINALITY t(e, ord))
WHERE p.family = 'research-write';

END $recast$;

-- ── pipeline-level: pool via the finalize tool, not the auto-materialize arm.
-- doc_finalize pools the doc (project-tagged from the work item) during critique;
-- the final stage output is a journal, so turn auto_materialize OFF and declare
-- pools_via_tool so on_maturity_verified does NOT auto-pool the journal (08-gates).
UPDATE stewards.pipelines
   SET auto_materialize_on_verified = false,
       file_destination_template    = NULL,
       file_content_jsonpath        = NULL,
       metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('pools_via_tool', true),
       updated_at = now()
 WHERE family IN ('research-summary', 'research-write');

-- ── stage_models + maturity: rename synthesize->build, review->critique (cosmetic;
--    main dispatch reads the stages jsonb, but keep these consistent).
DELETE FROM stewards.stage_models
 WHERE pipeline_family IN ('research-summary','research-write') AND stage_name IN ('synthesize','review');
INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('research-summary','build',    'reason', 'Build the digest as a doc via doc_* (no publish); tools on. Local reason alias.'),
    ('research-summary','critique', 'critic', 'Review the draft + doc_finalize; tools on, no re-research. Local critic alias.'),
    ('research-write',  'build',    'reason', 'Build the piece as a doc via doc_* (no publish); tools on. Local reason alias.'),
    ('research-write',  'critique', 'critic', 'Review the draft + doc_finalize; tools on, no re-research. Local critic alias.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;
-- gather/context_gather move to the ingest role too
UPDATE stewards.stage_models SET default_model='ingest'
 WHERE pipeline_family IN ('research-summary','research-write') AND stage_name IN ('gather','context_gather');

DELETE FROM stewards.pipeline_stage_maturity
 WHERE pipeline_family IN ('research-summary','research-write') AND stage_name IN ('synthesize','review');
INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('research-summary','build',    'planned',  'Draft built; ready for the critique pass.'),
    ('research-summary','critique', 'verified', 'Reviewed + pooled via doc_finalize.'),
    ('research-write',  'build',    'planned',  'Draft built; ready for the critique pass.'),
    ('research-write',  'critique', 'verified', 'Reviewed + pooled via doc_finalize.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

-- =====================================================================
-- End of 35-research-doc-construction.sql
-- =====================================================================
