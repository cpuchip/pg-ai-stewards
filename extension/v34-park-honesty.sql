-- =====================================================================
-- v34-park-honesty.sql — the bell quotes the CURRENT failure, not a stale one.
-- (#362 half 2: stale error reuse on redispatch)
-- =====================================================================
--
-- THE BUG (found live 2026-07-09, war-game watcher verdict): a parked item
-- surfaced OLD error text on the bell. A July-5 qwen error was quoted for a
-- July-9 deepseek park and NEARLY caused a false verdict — the watcher read
-- the stale qwen line as the current blocker before verify-via-real-path
-- caught that the qwen text was days old and never cleared.
--
-- ROOT CAUSE: work_item_dispatch_stage (last full author v32 §1) ends every
-- (re)dispatch with
--     UPDATE stewards.work_items
--        SET status='in_progress', session_ids=…, updated_at=now()
--      WHERE id = p_work_item_id;
-- It moves the item to in_progress but NEVER clears work_items.error. So when
-- an item that parked at awaiting_review with error='<old failure>' is
-- redispatched, the old error rides along. needs_attention's 'review' bucket
-- (v19: awaiting_review AND a2a_question IS NULL, question = coalesce(error,…))
-- then quotes that stale error on the NEXT park — even though the current
-- dispatch failed for a completely different reason (or produced no verdict at
-- all, as the deepseek DSML-leak did — see #362 half 1, bgworker.rs).
--
-- THE FIX: clear work_items.error in that terminal UPDATE. dispatch_stage is
-- the SINGLE redispatch chokepoint — initial dispatch, steward retry,
-- alias-failover, escalation resume, and the attention-answer API all route
-- through it (escalation_resolve + the answer API via
-- work_item_dispatch_stage_safe -> this). Clearing here means the error column
-- only ever holds the CURRENT cycle's failure: a later re-park (v31's handler,
-- or _safe's "nothing configured"/"unusable override" park) writes a FRESH
-- error; a success leaves it NULL. At the moment of the clear the item is
-- transitioning OFF awaiting_review into in_progress, so it is no longer on the
-- bell — nothing that a human still needs to read is discarded.
--
-- Note on the _safe wrapper: when dispatch_stage RAISES, its subtransaction
-- (including this error=NULL clear) rolls back, and _safe's handler writes the
-- fresh park error — so the failure path keeps its fresh error and the success
-- path clears the stale one. Both correct.
--
-- OWNERSHIP: re-authors work_item_dispatch_stage ONE more time (previous full
-- author v32 §1). Body below is v32 §1's VERBATIM except the terminal UPDATE
-- gains `error = NULL`. Same later-file-wins / carry-the-latest-body discipline
-- v31 used on v27's steward_tick and v33 used on v09's work_item_advance. The
-- v32 _safe wrapper, enqueue_model_probe, trigger_resolve_model_probe, and
-- reflect_guard_signals are NOT touched.
--
-- requires create_v33_wargame_w2 (keeps the volume chain linear:
-- v31 -> v32 -> v33 -> v34).
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.work_item_dispatch_stage(
    p_work_item_id           uuid,
    p_user_input             text DEFAULT NULL,
    p_allow_failed_status    boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $function$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_stage          jsonb;
    v_pipeline_meta  jsonb;
    v_agent          text;
    v_model          text;
    v_provider       text;
    v_session_id     text;
    v_user_input     text;
    v_body           jsonb;
    v_payload        jsonb;
    v_work_id        bigint;
    v_was_failed     boolean := false;
    -- 31 alias / policy state
    v_model_req      text;
    v_forbid_training boolean;
    -- M.2 capability substitution state
    v_resolved_model text;
    v_sub_model      text;
    v_cap_detail     text;
    -- v32 FIX 1: did the concrete literal model come from the item override?
    v_model_from_override boolean := false;
    -- R.3 dispatch-body knobs
    v_max_tokens     text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    IF v_wi.status NOT IN ('pending', 'awaiting_review')
       AND NOT (p_allow_failed_status AND v_wi.status = 'failed')
    THEN
        RAISE EXCEPTION 'work_item %: cannot dispatch from status %',
            p_work_item_id, v_wi.status;
    END IF;

    v_was_failed := (v_wi.status = 'failed');

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    SELECT metadata INTO v_pipeline_meta
      FROM stewards.pipelines
     WHERE family = v_wi.pipeline_family;

    v_agent := v_stage->>'agent_family';

    -- 31: a file_private intent forbids train-on-data dispatch — UNLESS the stage
    -- declares "public_io": a gather stage whose inputs/outputs are public even
    -- under a private intent (it sends public web queries, not the private pool).
    -- This is what lets a private intent's "gather public info" stages run on free
    -- providers while its analysis / steward / critic stages stay no-train.
    v_forbid_training := stewards.intent_forbids_training(v_wi.intent_id)
        AND NOT COALESCE((v_stage->>'public_io')::boolean, false);

    -- J.8.a: the requested model from the 4-layer ladder (input -> stage ->
    -- pipeline). The catalog default is deferred to the literal branch, since an
    -- alias selects its own provider AND model.
    v_model_req := COALESCE(
        v_wi.model_override,
        v_stage->>'model',
        v_pipeline_meta->>'default_model'
    );

    IF v_model_req IS NOT NULL
       AND EXISTS (SELECT 1 FROM stewards.model_aliases WHERE alias = v_model_req) THEN
        -- 31 ALIAS path: the logical name selects BOTH provider and concrete
        -- model from its ordered members (configured + usable + under-cap +
        -- no-train-when-private). Lowest priority wins; a private intent drops
        -- any train-on-data member and falls through to the next.
        SELECT m.provider, m.model INTO v_provider, v_model
          FROM stewards.pick_alias_member(v_model_req, v_forbid_training) m;
        IF v_provider IS NULL OR v_model IS NULL THEN
            RAISE EXCEPTION 'work_item %: model alias ''%'' has no usable member (needs configured + usable + under-cap%s) — dispatch refused. Inspect stewards.model_aliases, providers_loaded(), stewards.model_capability.',
                p_work_item_id, v_model_req,
                CASE WHEN v_forbid_training THEN ' + no-train for this file_private intent' ELSE '' END;
        END IF;
    ELSE
        -- LITERAL path: provider via its own 4-layer ladder; model literal or
        -- the provider catalog default.
        v_provider := COALESCE(
            v_wi.provider_override,
            v_stage->>'provider',
            v_pipeline_meta->>'default_provider',
            stewards.catalog_default_provider()
        );
        v_model := COALESCE(v_model_req, stewards.catalog_default_model(v_provider));

        -- v32 FIX 1: flag when the concrete literal model came from the item
        -- override. model_override is first in the ladder, so if it is set and
        -- not an alias, it IS v_model here. This flag makes the M.2 gate refuse
        -- rather than silently swap an operator/steward-pinned model.
        v_model_from_override := (v_wi.model_override IS NOT NULL
                                  AND v_model = v_wi.model_override);

        -- 31 guard rail: a literal resolution has no declared fallback, so a
        -- file_private intent landing on a train-on-data model is refused loudly
        -- rather than silently leaking. Route via an alias with a no-train member.
        IF v_provider IS NOT NULL AND v_model IS NOT NULL
           AND v_forbid_training
           AND stewards.model_trains_on_data(v_provider, v_model) THEN
            RAISE EXCEPTION 'work_item %: intent is file_private but stage resolves to train-on-data %/% — dispatch refused. Route via a model alias with a no-train member, or set a no-train provider/model on the stage.',
                p_work_item_id, v_provider, v_model;
        END IF;
    END IF;

    IF v_agent IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % missing agent_family',
            p_work_item_id, v_wi.current_stage;
    END IF;
    IF v_model IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % could not resolve model — checked work_items.model_override, stages.model, pipelines.metadata.default_model (+ alias members), catalog_default_model(%) — all NULL',
            p_work_item_id, v_wi.current_stage, v_provider;
    END IF;
    IF v_provider IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % could not resolve provider',
            p_work_item_id, v_wi.current_stage;
    END IF;

    -- M.2: capability gate. If the resolved model is marked unusable,
    -- substitute a usable one for the same provider (catalog default ->
    -- cheapest usable) and remember the swap so it is logged at enqueue.
    v_resolved_model := v_model;
    IF NOT stewards.model_usable(v_provider, v_model) THEN
        -- v32 FIX 1: an item override that names an unusable CONCRETE model is
        -- REFUSED, not silently swapped. The operator (or the steward's
        -- escalation write on work_items.model_override) named this model;
        -- dispatching a different one behind their back is the dishonesty this
        -- closes. Stage / pipeline / alias-resolved models still substitute
        -- below, exactly as v08 did.
        IF v_model_from_override THEN
            RAISE EXCEPTION 'work_item %: model_override ''%'' on provider % is marked unusable — dispatch refused (override names an unusable model; not silently substituted). Clear work_items.model_override or pin a usable model. Inspect stewards.model_capability WHERE provider=''%'' AND model=''%''.',
                p_work_item_id, v_wi.model_override, v_provider, v_provider, v_model;
        END IF;
        v_sub_model := stewards.pick_usable_model(v_provider, v_model);
        IF v_sub_model IS NULL THEN
            RAISE EXCEPTION 'work_item %: resolved model %/% is marked unusable and the provider has no usable substitute — dispatch refused. Inspect stewards.model_capability.',
                p_work_item_id, v_provider, v_model;
        END IF;
        SELECT probe_detail INTO v_cap_detail
          FROM stewards.model_capability
         WHERE provider = v_provider AND model = v_resolved_model;
        v_model := v_sub_model;
    END IF;

    -- J.11: enforced prepaid spend-cap gate (provider-level; unchanged).
    IF stewards.provider_cap_exceeded(v_provider) THEN
        RAISE EXCEPTION 'work_item %: provider % spend cap reached ($% spent since refill / $% cap) — dispatch refused. Top up + reset with: SELECT stewards.provider_cap_refill(''%'');',
            p_work_item_id, v_provider,
            round(stewards.provider_spend_since(v_provider) / 1000000.0, 4),
            round((SELECT cap_micro FROM stewards.provider_spend_caps WHERE provider = v_provider) / 1000000.0, 2),
            v_provider;
    END IF;

    v_session_id := substring(
        'wi--' || substring(p_work_item_id::text FROM 1 FOR 8)
        || '--' || v_wi.current_stage
        FROM 1 FOR 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('work_item %s stage %s', v_wi.id, v_wi.current_stage),
            'agent')
    ON CONFLICT (id) DO NOTHING;

    IF p_user_input IS NOT NULL THEN
        v_user_input := p_user_input;
    ELSE
        v_user_input := stewards.render_stage_input(p_work_item_id);
        IF v_user_input IS NULL THEN
            v_user_input := coalesce(
                v_wi.input->>'user_input',
                v_wi.input::text
            );
        END IF;
    END IF;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_user_input, v_model);

    v_body := stewards.dry_run_chat(v_agent, v_model, v_session_id, NULL);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_agent,
        'requested_model',    v_model,
        'meta',               v_body->'_meta',
        'body',               (v_body - '_meta')
                              || jsonb_build_object('user', v_session_id),
        '_work_item_id',      p_work_item_id::text,
        '_stage_name',        v_wi.current_stage,
        '_pipeline_family',   v_wi.pipeline_family
    );

    -- R.3 (1): per-call output ceiling. input override wins; else stage default
    -- (only redline-style pipelines set stage.max_tokens).
    v_max_tokens := COALESCE(v_wi.input->>'max_tokens', v_stage->>'max_tokens');
    IF v_max_tokens IS NOT NULL AND v_max_tokens ~ '^[0-9]+$' THEN
        v_payload := jsonb_set(v_payload, '{body,max_tokens}', to_jsonb(v_max_tokens::int));
    END IF;

    -- R.3 (2): input-scoped tools-off. Read from INPUT only (NOT stage) so
    -- pipelines that declare stage.tools_disabled keep their current behavior;
    -- the bgworker strips the tools block when payload.tools_disabled=true.
    IF (v_wi.input->>'tools_disabled')::boolean IS TRUE THEN
        v_payload := v_payload || jsonb_build_object('tools_disabled', true);
    END IF;

    -- M.2: attach the substitution marker so the l29 trigger logs the swap
    -- (with reason) exactly once and skips its passive compare.
    IF v_model IS DISTINCT FROM v_resolved_model THEN
        v_payload := v_payload || jsonb_build_object(
            '_capability_substitution', jsonb_build_object(
                'from',   v_resolved_model,
                'to',     v_model,
                'reason', COALESCE(v_cap_detail, 'model marked unusable')
            )
        );
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_provider, v_payload)
    RETURNING id INTO v_work_id;

    -- v34 (#362 half 2): clear error on (re)dispatch. This is the single
    -- redispatch chokepoint; leaving a prior cycle's error on the row let
    -- needs_attention (question = coalesce(error,…)) quote a STALE failure on
    -- the next park (live 2026-07-09: a July-5 qwen error quoted for a July-9
    -- deepseek park, nearly a false verdict). A later re-park writes a fresh
    -- error; a success leaves it NULL. The item is transitioning OFF
    -- awaiting_review here, so it is no longer on the bell — nothing a human
    -- still needs is discarded. Everything else in this UPDATE is v32-verbatim.
    UPDATE stewards.work_items
       SET status      = 'in_progress',
           session_ids = session_ids || v_session_id,
           error       = NULL,
           updated_at  = now()
     WHERE id = p_work_item_id;

    RETURN v_work_id;
END;
$function$;

COMMENT ON FUNCTION stewards.work_item_dispatch_stage(uuid, text, boolean) IS
'Dispatch FINAL (v34 park-honesty + v32 override-honesty + J.8.a + 31 aliases + M.2 + J.11 + R.3): 4-layer resolution where the requested model may be a logical alias; a file_private guard rail; then M.2 capability substitution — EXCEPT a model that came from work_items.model_override is REFUSED (clear error naming the override) rather than silently substituted (v32 FIX 1). Stage / pipeline / alias-resolved models substitute exactly as v08. Then the J.11 spend-cap gate and R.3 max_tokens + input-scoped tools_disabled. v34 (#362): the terminal (re)dispatch UPDATE now also clears work_items.error, so the redispatch chokepoint never leaves a prior cycle''s park reason on the row for needs_attention to quote as a stale failure — the bell always shows the CURRENT failure (a later re-park writes a fresh error; a success leaves it NULL).';

-- =====================================================================
-- End of v34-park-honesty.sql
-- =====================================================================
