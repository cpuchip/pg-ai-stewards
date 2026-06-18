-- =====================================================================
-- 31-model-aliases.sql — logical model aliases + provider-aware fallback
-- + the file_private-intent no-train guard rail.
-- =====================================================================
-- The dispatch FINAL (19 §6) resolves provider and model independently down a
-- 4-layer COALESCE ladder, and the only "fallback" it has is M.2 capability
-- substitution — which stays WITHIN a single provider. So two real needs were
-- inexpressible:
--
--   1. The same logical model on two providers carries different ids
--      (opencode_go calls it `kimi-k2.6`; nvidia calls it `moonshotai/kimi-k2.6`).
--      Nothing tied them together, so "if nvidia is unavailable, fall back to
--      opencode_go" could not be written.
--   2. A file_private intent (work-corpus) must never reach a train-on-data provider
--      (nvidia / opencode_zen free tiers train on submitted data). The only
--      guard was an out-of-band convention.
--
-- This file adds three generic primitives and re-authors the dispatcher to use
-- them (later-file-wins over 19 §6):
--
--   • model_aliases  — a logical name → an ORDERED set of concrete
--                      (provider, provider_model) members. The alias resolves to
--                      the highest-priority member that is configured + usable +
--                      under spend cap + (for a private intent) no-train.
--   • model_capability.trains_on_data — per-(provider, model) policy flag. Set
--                      true for free public tiers; a file_private intent's
--                      dispatch drops these members.
--   • provider_is_loaded / model_trains_on_data / intent_forbids_training /
--     pick_alias_member — the read helpers the dispatcher consults.
--
-- Generic core: the machinery + an EMPTY model_aliases table + a default-false
-- policy column. A virgin install behaves exactly as before (no alias rows → the
-- literal path; no trains_on_data flags → no member ever dropped). The operator
-- overlay seeds the aliases, the trains_on_data flags, and points stages at the
-- aliases.
--
-- requires create_tool_primers (30). No data migration; additive table + column
-- + one function re-author (work_item_dispatch_stage). Clobber-check safe — this
-- is CORE re-authoring CORE (later file wins), not an overlay touching core.
-- =====================================================================


-- =====================================================================
-- §1 — per-(provider, model) train-on-data policy.
-- =====================================================================
-- A nullable column on the existing capability table (per-(provider, model) is
-- the right grain: opencode_zen serves BOTH free models that train AND paid
-- Claude models that do not, so a per-provider flag would be too coarse).
-- NULL / absent row => false (assume no-train): the providers we pay for are
-- no-train, and the exceptions (nvidia, zen-free) are explicitly flagged in the
-- overlay. usable already follows this innocent-until-flagged shape.
ALTER TABLE stewards.model_capability
    ADD COLUMN IF NOT EXISTS trains_on_data boolean;

COMMENT ON COLUMN stewards.model_capability.trains_on_data IS
'31: true when the provider trains on data submitted to this model (free public tiers — nvidia, opencode_zen free). NULL/absent => false. A file_private intent''s dispatch drops train-on-data alias members and refuses a literal train-on-data resolution. Operator policy — flag via the overlay.';

CREATE OR REPLACE FUNCTION stewards.model_trains_on_data(p_provider text, p_model text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT trains_on_data FROM stewards.model_capability
          WHERE provider = p_provider AND model = p_model),
        false
    );
$$;

COMMENT ON FUNCTION stewards.model_trains_on_data(text, text) IS
'31: true only when model_capability explicitly flags (provider, model) trains_on_data. Unflagged models default no-train. Consulted by the file_private guard in work_item_dispatch_stage.';


-- =====================================================================
-- §2 — is a provider actually wired in env?
-- =====================================================================
-- providers_loaded() reflects the in-process registry the bgworker reads at
-- boot (names are lowercased). Used so an alias never resolves to a provider the
-- operator hasn't configured — it falls through to the next member instead.
CREATE OR REPLACE FUNCTION stewards.provider_is_loaded(p_provider text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM stewards.providers_loaded() WHERE name = lower(p_provider)
    );
$$;

COMMENT ON FUNCTION stewards.provider_is_loaded(text) IS
'31: true when p_provider is present in the in-process provider registry (providers_loaded()). pick_alias_member uses it to skip unconfigured providers — but only when the registry is non-empty, so a bare SQL/test context (no bgworker) does not over-filter.';


-- =====================================================================
-- §3 — does this intent forbid train-on-data dispatch?
-- =====================================================================
-- v1 reuses the file_private flag (29): a private intent is also private about
-- its data. Wrapped in its own helper so a dedicated `sensitive` flag can split
-- the two later without touching the dispatcher.
CREATE OR REPLACE FUNCTION stewards.intent_forbids_training(p_intent_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT file_private FROM stewards.intents WHERE id = p_intent_id),
        false
    );
$$;

COMMENT ON FUNCTION stewards.intent_forbids_training(uuid) IS
'31: whether an intent may not dispatch to train-on-data providers. v1 = the intent''s file_private flag (29). Separate helper so a future dedicated sensitivity flag can replace the source without changing dispatch.';


-- =====================================================================
-- §4 — the alias table.
-- =====================================================================
-- A logical name maps to an ordered set of concrete members. EMPTY in core; the
-- operator overlay seeds the rows. Aliases should be names that are NOT real
-- provider model ids (e.g. 'kimi', 'qwen-workhorse', 'critic') so the
-- dispatcher's "is this an alias?" test never collides with a literal model.
CREATE TABLE IF NOT EXISTS stewards.model_aliases (
    alias            text NOT NULL,   -- the logical name a stage requests
    provider         text NOT NULL,   -- a configured provider
    provider_model   text NOT NULL,   -- that provider's id for this model
    priority         int  NOT NULL DEFAULT 0,  -- lower = tried first
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (alias, provider, provider_model)
);

COMMENT ON TABLE stewards.model_aliases IS
'31: logical model name -> ordered (provider, provider_model) members. A stage that requests an alias resolves to the lowest-priority member that is configured + usable + under spend cap + (for a file_private intent) no-train. Gives provider-crossing fallback the same-provider M.2 substitution cannot. Empty in core; seeded by the operator overlay.';

COMMENT ON COLUMN stewards.model_aliases.priority IS
'31: try order — lowest first. Put free/preferred members at 0, paid fallbacks higher.';


-- pick_alias_member: the best member for an alias under the given constraints,
-- or no rows. VOLATILE (calls providers_loaded). The availability filter is
-- bypassed when the registry is empty (a bare SQL/test context) so it never
-- over-filters where it simply has no provider information.
CREATE OR REPLACE FUNCTION stewards.pick_alias_member(
    p_alias           text,
    p_forbid_training boolean DEFAULT false
)
RETURNS TABLE (provider text, model text)
LANGUAGE sql AS $$
    SELECT a.provider, a.provider_model
      FROM stewards.model_aliases a
     WHERE a.alias = p_alias
       AND (
            NOT EXISTS (SELECT 1 FROM stewards.providers_loaded())   -- no registry info → don't filter
            OR stewards.provider_is_loaded(a.provider)
       )
       AND stewards.model_usable(a.provider, a.provider_model)
       AND NOT stewards.provider_cap_exceeded(a.provider)
       AND (NOT p_forbid_training
            OR NOT stewards.model_trains_on_data(a.provider, a.provider_model))
     ORDER BY a.priority ASC, a.provider, a.provider_model
     LIMIT 1;
$$;

COMMENT ON FUNCTION stewards.pick_alias_member(text, boolean) IS
'31: resolve a model alias to its best concrete (provider, model) — lowest priority that is configured (when the registry is populated) + usable + under spend cap + (when p_forbid_training) no-train. Returns no rows if none qualify.';


-- =====================================================================
-- §4.5 — keep the substitution log clean: alias expansion is not a swap.
-- =====================================================================
-- The M.2 substitution logger (19 §3) has a PASSIVE arm that records a row when
-- a stage's declared model differs from the dispatched requested_model. With
-- aliases that is now the normal case (declared 'kimi' -> requested
-- 'moonshotai/kimi-k2.6'), so every alias dispatch would log a phantom
-- "substitution". Re-author the logger (later-file-wins over 19 §3) to skip the
-- passive log when the declared stage model is an alias — the capability-swap
-- arm (M.2 marker) and genuine declared-vs-requested swaps are untouched.
CREATE OR REPLACE FUNCTION stewards.trigger_log_model_substitution()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_pipeline_family text;
    v_stage_name      text;
    v_pipeline_model  text;
    v_requested       text;
    v_work_item_id    text;
    v_session_id      text;
    v_cap             jsonb;
BEGIN
    v_pipeline_family := NEW.payload ->> '_pipeline_family';
    v_stage_name      := NEW.payload ->> '_stage_name';
    v_work_item_id    := NEW.payload ->> '_work_item_id';
    v_session_id      := NEW.payload ->> 'session_id';

    -- M.2: capability substitution carries its own marker + reason. Log it and
    -- return — do NOT fall through to the pipeline-vs-requested compare.
    v_cap := NEW.payload -> '_capability_substitution';
    IF v_cap IS NOT NULL THEN
        INSERT INTO stewards.model_substitutions
            (work_queue_id, work_item_id, pipeline_family, stage_name,
             pipeline_model, requested_model, session_id, reason)
        VALUES
            (NEW.id,
             CASE WHEN v_work_item_id ~ '^[0-9a-f-]{36}$' THEN v_work_item_id::uuid ELSE NULL END,
             v_pipeline_family, v_stage_name,
             v_cap ->> 'from', v_cap ->> 'to', v_session_id,
             'capability: ' || COALESCE(v_cap ->> 'reason', 'model marked unusable'));

        RAISE NOTICE 'capability substitution: %/% %->% (% , wq=%)',
            v_pipeline_family, v_stage_name, v_cap ->> 'from', v_cap ->> 'to',
            v_cap ->> 'reason', NEW.id;
        RETURN NEW;
    END IF;

    -- l29 original behavior: passive pipeline-declared vs requested compare.
    v_requested := NEW.payload ->> 'requested_model';
    IF v_requested IS NULL THEN RETURN NEW; END IF;
    IF v_pipeline_family IS NULL OR v_stage_name IS NULL THEN RETURN NEW; END IF;

    SELECT s ->> 'model' INTO v_pipeline_model
      FROM stewards.pipelines p,
           LATERAL jsonb_array_elements(p.stages) s
     WHERE p.family = v_pipeline_family
       AND (s ->> 'name') = v_stage_name
     LIMIT 1;

    IF v_pipeline_model IS NULL OR v_pipeline_model = v_requested THEN
        RETURN NEW;
    END IF;

    -- 31: when the stage declares a model ALIAS, requested != declared is the
    -- normal alias expansion (declared 'kimi' -> requested 'moonshotai/kimi-k2.6'),
    -- not a substitution. Skip the passive log.
    IF EXISTS (SELECT 1 FROM stewards.model_aliases WHERE alias = v_pipeline_model) THEN
        RETURN NEW;
    END IF;

    INSERT INTO stewards.model_substitutions
        (work_queue_id, work_item_id, pipeline_family, stage_name,
         pipeline_model, requested_model, session_id)
    VALUES
        (NEW.id,
         CASE WHEN v_work_item_id ~ '^[0-9a-f-]{36}$' THEN v_work_item_id::uuid ELSE NULL END,
         v_pipeline_family, v_stage_name,
         v_pipeline_model, v_requested, v_session_id);

    RAISE NOTICE 'model substitution: pipeline=%/% declared=% but requested=% (wq=%)',
        v_pipeline_family, v_stage_name, v_pipeline_model, v_requested, NEW.id;

    RETURN NEW;
END;
$FN$;

COMMENT ON FUNCTION stewards.trigger_log_model_substitution() IS
'M.2 (was l29, re-authored in 31): single writer to model_substitutions. Capability swaps (payload._capability_substitution) log with a reason; the passive declared-vs-requested compare runs otherwise BUT skips alias-declared stages (alias expansion is not a substitution).';


-- =====================================================================
-- §5 — work_item_dispatch_stage re-authored (alias expansion + guard rail).
-- =====================================================================
-- Carries the 19 §6 FINAL verbatim (M.2 capability substitution, J.11 spend-cap
-- gate, R.3 max_tokens / input-scoped tools_disabled). The ONLY change is the
-- resolution block: the requested model is now alias-aware, and a file_private
-- intent is filtered (alias path) / refused (literal path) off train-on-data —
-- UNLESS the stage declares "public_io":true, the per-stage escape hatch that
-- lets a private intent's public gather stages still use free providers while
-- its analysis / steward / critic stages stay no-train (Michael's "gather public
-- info on work-corpus = free; analysis = private"). Existing dispatch is unchanged
-- when the requested model is not an alias and the intent is not file_private.
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

    UPDATE stewards.work_items
       SET status      = 'in_progress',
           session_ids = session_ids || v_session_id,
           updated_at  = now()
     WHERE id = p_work_item_id;

    RETURN v_work_id;
END;
$function$;

COMMENT ON FUNCTION stewards.work_item_dispatch_stage(uuid, text, boolean) IS
'Dispatch FINAL (J.8.a + 31 aliases + M.2 + J.11 + R.3): 4-layer resolution where the requested model may be a logical alias (resolves to its best configured/usable/under-cap/no-train-when-private member), a file_private guard rail (alias members filtered, literal resolution refused) off train-on-data providers — bypassed for a stage marked "public_io":true (a gather stage whose I/O is public even under a private intent) — then M.2 capability substitution, the J.11 spend-cap gate, and R.3 max_tokens + input-scoped tools_disabled. Non-alias dispatch under a non-private intent is byte-identical to 19 §6.';


-- =====================================================================
-- End of 31-model-aliases.sql
-- =====================================================================
