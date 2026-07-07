-- ===== [was 31-model-aliases.sql] =====
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

-- Per-model REAL context window (2026-06-18). A provider-level window can't
-- capture local models loaded at a fixed n_ctx — one provider (flexllama)
-- serves many windows (qwen 65k, gemma 256k, nemotron 1M). effective_budget
-- (15a, Layer 2.5) uses window*0.70 so 30% stays free for reasoning+output.
-- NULL = fall through to provider.context_window (unchanged for paid providers).
ALTER TABLE stewards.model_capability
    ADD COLUMN IF NOT EXISTS context_window int;

COMMENT ON COLUMN stewards.model_capability.context_window IS
'31: real per-model context window (n_ctx) in tokens, when known (local models loaded at a fixed n_ctx). effective_budget reserves 30% for reasoning+output (window*0.70). NULL => fall through to provider.context_window. Operator sets it via the overlay to match the loaded runtime config.';

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
-- ===== [was 32-alias-failover.sql] =====
-- =====================================================================
-- 32-alias-failover.sql — runtime failover across alias members.
-- =====================================================================
-- 31 gave alias resolution a STATIC filter: a member that is unconfigured,
-- unusable, over-cap, or probe-failed is skipped at dispatch time. The gap it
-- left (the documented P1): a provider that is UP but fails MID-CALL (NVIDIA
-- returns a Cloudflare 521, Moonshot 522, an Anthropic 529 overload) — the
-- member was usable at dispatch, so the work_item just fails. The M.5 auto-probe
-- only flips it unusable on the next cadence.
--
-- This file closes that gap by teaching the steward to WALK to the next alias
-- member when a transient/timeout failure hits an alias-dispatched stage —
-- before pick_model (which raises for stages-jsonb pipelines that have no
-- stage_models row, so without this the steward gives an alias stage no retry at
-- all). It also fixes diagnose_failure, whose transient regex matched only
-- 500-504 and so MISSED the exact Cloudflare 52x shape that motivated this.
--
-- Three core re-authors (later-file-wins; CORE-on-CORE, clobber-check safe):
--   §1 diagnose_failure (07)      — broaden the transient class to any 5xx
--                                   (incl. 52x), 408, 529, "overloaded",
--                                   Cloudflare "web server" text.
--   §2 pick_alias_member (31)     — gains an exclude set (skip tried members).
--   §3 steward_tick (07)          — the alias-failover branch.
-- + §2.5 a small helper for the tried-transient member set.
--
-- 103 (2026-07, war-game W2) makes ONE surgical edit inside §3's steward_tick
-- body — NOT a full re-author — adding a to_regprocedure-guarded, exception-
-- isolated sweep of stewards.abort_conditions_evaluate() right before the
-- RETURN. This file remains steward_tick's LAST full author; 103 owns only
-- that one inserted block (see its own comment there for why a surgical edit
-- was chosen over yet another full-body re-author).
--
-- SUPERSEDED 2026-07-07 (feat/lightening, model-agnostic audit): 107-
-- lifeless-core.sql re-authors this file's steward_tick ONE more time —
-- the __queue_for_opus__ sentinel becomes __queue_for_strongest__, and all
-- 3 dispatch call sites below (alias failover, pinned retry, normal retry)
-- swap to work_item_dispatch_stage_safe, so an "unconfigured model"
-- failure lands the item in awaiting_review instead of rolling back the
-- failure_count bump and retrying the same item forever. §3's body below
-- is the historical record — port from 107, not from here.
--
-- requires create_model_aliases (31). No schema change; no data migration.
-- The mechanism mirrors the steward's existing escalation (set model_override +
-- provider_override, re-dispatch with p_allow_failed_status). Known limit: like
-- that escalation, the override persists, so a mid-pipeline failover keeps the
-- work_item's LATER stages on the chosen member for that run (it self-heals on
-- the next run / work_item). Clearing overrides on stage advance is the clean
-- follow-up (improves the existing escalation too).
-- =====================================================================


-- =====================================================================
-- §1 — diagnose_failure: the transient class was too narrow.
-- =====================================================================
-- The old regex matched 5(00|01|02|03|04) only, so a Cloudflare 521/522 ("web
-- server is down"), an Anthropic 529 ("overloaded"), and a 408 all fell through
-- to 'unknown' — and the alias failover keys on 'transient'/'timeout'. Broaden
-- to any 5xx + 408 + the overload/web-server phrasings. Timeout still checked
-- first (most specific). IMMUTABLE preserved.
CREATE OR REPLACE FUNCTION stewards.diagnose_failure(
    p_reason         text,
    p_failure_count  int DEFAULT 0
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_lower text;
BEGIN
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        IF p_failure_count >= 2 THEN
            RETURN 'model_limit';
        END IF;
        RETURN 'unknown';
    END IF;

    v_lower := lower(p_reason);

    IF v_lower ~ '(timeout|timed out|context deadline exceeded|inactivity|deadline)' THEN
        RETURN 'timeout';
    END IF;

    -- Transient: any 5xx (incl. Cloudflare 52x), 408, 429/rate limits, network
    -- blips, and the common overload / "web server is down" phrasings. Provider
    -- issue, not a model-capability issue.
    -- NOTE: 68-model-fallback-hardening.sql RE-AUTHORS this function (it is the
    -- live authority). The #326 upstream-400 pattern lives THERE, not here.
    IF v_lower ~ '(408|429|rate.?limit|5[0-9][0-9]|network|connection (refused|reset)|temporarily unavailable|service unavailable|overloaded|web server (is down|returned|error))' THEN
        RETURN 'transient';
    END IF;

    IF v_lower ~ '(tool.{0,30}(error|not found|missing|invalid)|function.{0,20}(error|not found|missing|invalid)|schema.{0,20}(error|invalid|mismatch)|validation.{0,20}(failed|error))' THEN
        RETURN 'tool_error';
    END IF;

    IF p_failure_count >= 2 THEN
        RETURN 'model_limit';
    END IF;

    RETURN 'unknown';
END;
$func$;

COMMENT ON FUNCTION stewards.diagnose_failure(text, int) IS
'Classify a failure reason into (transient | timeout | model_limit | tool_error | unknown). 32: the transient class now covers any 5xx (incl. Cloudflare 52x), 408, 529/overloaded, and "web server is down" — so alias failover triggers on the real provider-outage shapes.';


-- =====================================================================
-- §2 — pick_alias_member gains an exclude set.
-- =====================================================================
-- Same selection as 31 plus: skip any member whose {provider, model} is in
-- p_exclude. Used by the failover to walk PAST members that already failed this
-- attempt. Replaces the 2-arg form (drop-then-create — a defaulted 3rd arg
-- would make the 2-arg call ambiguous); the 31 dispatch's 2-arg call resolves
-- to this via the default at runtime.
DROP FUNCTION IF EXISTS stewards.pick_alias_member(text, boolean);

CREATE OR REPLACE FUNCTION stewards.pick_alias_member(
    p_alias           text,
    p_forbid_training boolean DEFAULT false,
    p_exclude         jsonb   DEFAULT '[]'::jsonb
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
       AND NOT (p_exclude @> jsonb_build_array(
                jsonb_build_object('provider', a.provider, 'model', a.provider_model)))
     ORDER BY a.priority ASC, a.provider, a.provider_model
     LIMIT 1;
$$;

COMMENT ON FUNCTION stewards.pick_alias_member(text, boolean, jsonb) IS
'31/32: resolve a model alias to its best concrete (provider, model) — lowest priority that is configured (when the registry is populated) + usable + under spend cap + (when p_forbid_training) no-train + NOT in p_exclude (a jsonb array of {provider, model} already tried this attempt). No rows if none qualify.';


-- =====================================================================
-- §2.5 — the tried-transient member set for a work_item's current stage.
-- =====================================================================
-- The members an alias-dispatched stage has already tried THIS run and that
-- failed with a transient/timeout error. Derived from work_queue history — no
-- new column. (A member that COMPLETED is not excluded, so a revise/re-run can
-- legitimately reuse it.) Resets naturally per stage (keyed by _stage_name).
CREATE OR REPLACE FUNCTION stewards.alias_transient_failed_members(
    p_work_item_id uuid,
    p_stage        text
) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
               'provider', wq.provider, 'model', wq.payload->>'requested_model')), '[]'::jsonb)
      FROM stewards.work_queue wq
     WHERE wq.kind = 'chat'
       AND wq.status = 'error'
       AND wq.payload->>'_work_item_id' = p_work_item_id::text
       AND wq.payload->>'_stage_name'   = p_stage
       AND stewards.diagnose_failure(COALESCE(wq.error, '')) IN ('transient','timeout');
$$;

COMMENT ON FUNCTION stewards.alias_transient_failed_members(uuid, text) IS
'32: the {provider, model} set an alias stage already tried this run that failed transiently (from work_queue error rows). Feeds pick_alias_member''s exclude so failover walks to the next member.';


-- =====================================================================
-- §3 — steward_tick: walk to the next alias member on a transient failure.
-- =====================================================================
-- Carries the 07 final verbatim and inserts ONE branch (step 3.5) after the
-- breaker check and before pick_model: when the failed work_item's current
-- stage declares a model ALIAS and the diagnosis is transient/timeout, pick the
-- next untried member (excluding the ones that already transient-failed this
-- run) and re-dispatch it. Falls through to the normal pick_model path when the
-- stage is not an alias, the failure is not transient, or all members are spent.
CREATE OR REPLACE FUNCTION stewards.steward_tick()
RETURNS int
LANGUAGE plpgsql AS $func$
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
    -- 32 alias-failover state
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
         ORDER BY updated_at ASC  -- oldest failures first
         LIMIT 10
         FOR UPDATE SKIP LOCKED
    LOOP
        BEGIN
            v_attempt := v_item.failure_count + 1;

            -- 1. Cost cap check
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

            -- 2. Diagnose (cached on the work_item for visibility)
            v_diagnosis := stewards.diagnose_failure(
                v_item.last_failure_reason, v_item.failure_count);
            UPDATE stewards.work_items
               SET last_failure_diagnosis = v_diagnosis
             WHERE id = v_item.id;

            -- 3. Breaker check
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

            -- 3.5 ALIAS RUNTIME FAILOVER (32): a provider/transient/timeout
            -- failure on an alias-dispatched stage → walk to the next untried
            -- member. Runs BEFORE pick_model, which raises for stages-jsonb
            -- pipelines (no stage_models row) and so would give an alias stage
            -- no retry at all.
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

                        v_dispatched_work_id := stewards.work_item_dispatch_stage(
                            v_item.id, NULL, true);

                        INSERT INTO stewards.steward_actions
                            (work_item_id, observation, diagnosis, action, model_used,
                             details)
                        VALUES
                            (v_item.id,
                             format('alias %s failover → %s/%s (attempt #%s after %s); work_id %s',
                                    v_stage_model, v_fp, v_fm, v_attempt, v_diagnosis,
                                    v_dispatched_work_id),
                             v_diagnosis,
                             'alias_failover',
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
                    -- no untried member left → fall through to pick_model.
                ELSIF v_stage IS NOT NULL AND v_stage_model IS NOT NULL THEN
                    -- #326: pinned concrete model on a stages-jsonb stage. No alias
                    -- to walk, and pick_model RAISES for stages pipelines (no
                    -- stage_models row) — so without this a transient provider blip
                    -- (e.g. a gateway-wrapped upstream 400) gives the stage NO
                    -- retry at all. Re-dispatch the SAME pinned stage; failure_count<3
                    -- caps it, then it parks (a persistent outage escalates normally).
                    UPDATE stewards.work_items
                       SET failure_count = failure_count + 1
                     WHERE id = v_item.id;
                    v_dispatched_work_id := stewards.work_item_dispatch_stage(
                        v_item.id, NULL, true);
                    INSERT INTO stewards.steward_actions
                        (work_item_id, observation, diagnosis, action, model_used, details)
                    VALUES
                        (v_item.id,
                         format('pinned %s transient retry (attempt #%s after %s); work_id %s',
                                v_stage_model, v_attempt, v_diagnosis, v_dispatched_work_id),
                         v_diagnosis, 'pinned_retry', v_stage_model,
                         jsonb_build_object('model', v_stage_model,
                                            'dispatched_work_id', v_dispatched_work_id));
                    v_count := v_count + 1;
                    CONTINUE;
                END IF;
            END IF;

            -- 4. Pick model (raises if no stage_models row exists;
            -- caught by the per-item EXCEPTION below)
            v_next_model := stewards.pick_model(
                v_item.pipeline_family, v_item.current_stage,
                v_attempt, v_diagnosis);

            -- 5. Queue sentinel → human-mediated escalation
            IF v_next_model = '__queue_for_opus__' THEN
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
                     'queue_for_opus',
                     '__queue_for_opus__',
                     jsonb_build_object(
                         'attempt', v_attempt,
                         'escalation_attempts',
                             (SELECT escalation_attempts FROM stewards.work_items
                               WHERE id = v_item.id)));
                v_count := v_count + 1;
                CONTINUE;
            END IF;

            -- 6. Resolve provider from model_pricing (each model knows
            -- its provider; that's the canonical mapping). NULL when
            -- the model has no pricing row — then no provider override
            -- is set and the stage's own provider applies at dispatch.
            SELECT provider INTO v_provider
              FROM stewards.model_pricing
             WHERE model = v_next_model
             ORDER BY effective_at DESC
             LIMIT 1;

            -- 7. Retry path: lessons-aware guidance, set overrides,
            -- dispatch, account.
            v_retry_text := stewards.retry_guidance_with_lessons(
                v_diagnosis, v_attempt,
                v_item.pipeline_family, v_item.current_stage);

            UPDATE stewards.work_items
               SET model_override     = v_next_model,
                   provider_override  = v_provider,
                   failure_count      = failure_count + 1
             WHERE id = v_item.id;

            v_dispatched_work_id := stewards.work_item_dispatch_stage(
                v_item.id, v_retry_text, true);

            INSERT INTO stewards.steward_actions
                (work_item_id, observation, diagnosis, action, model_used,
                 details)
            VALUES
                (v_item.id,
                 format('attempt #%s after %s; dispatched as work_id %s',
                        v_attempt, v_diagnosis, v_dispatched_work_id),
                 v_diagnosis,
                 'retry_dispatched',
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

    -- 103 (W2, .spec/proposals/war-game-pipeline.md decision #3): sweep
    -- ARMED war-game abort conditions across every non-terminal work item —
    -- not just the failed ones the loop above walks (a budget_fraction or
    -- tool_unavailable abort can trip on a RUNNING item too). 103 loads
    -- AFTER this file in the chain, so at CREATE time of this very
    -- function the callee does not exist yet — plpgsql resolves the name
    -- at EXECUTION time, by which the full chain is installed; the
    -- to_regprocedure guard mirrors 99/97's optional-sibling calls so a
    -- partial/worktree build lacking 103 degrades honestly instead of
    -- raising every tick. Isolated in its own exception block so an
    -- evaluator bug can never abort the tick itself (the #330 poison-row
    -- lesson, generalized). Folded into v_count so "actions taken" this
    -- tick reflects trips too. Surgical addition only — steward_tick
    -- itself is NOT restructured.
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
$func$;

COMMENT ON FUNCTION stewards.steward_tick() IS
'Watch→Diagnose→Act→Account orchestration (32): per-item exception isolation; an ALIAS-FAILOVER branch walks a transient/timeout alias failure to its next untried member before pick_model (which raises for stages-jsonb pipelines); #326 adds a PINNED-RETRY sibling branch — a transient/timeout failure on a pinned concrete-model stages-jsonb stage re-dispatches the same stage (failure_count<3 caps it) instead of getting no retry at all; otherwise lessons-aware retry guidance + pick_model escalation. 103 adds a guarded post-loop sweep of stewards.abort_conditions_evaluate() (war-game W2 abort conditions) — isolated so an evaluator bug can never break the tick. Returns count of actions taken (includes abort trips). Called by the bgworker on tick.';


-- =====================================================================
-- End of 32-alias-failover.sql
-- =====================================================================
-- ===== [was 33-page-in.sql] =====
-- =====================================================================
-- 33-page-in.sql — page in large tool results instead of inlining them.
-- =====================================================================
-- The problem (from the FlexLLama local-inference session, 2026-06-18):
-- compose_messages preserves the fresh tail RAW, so a single big fetch_url
-- result (~40k tokens) can blow a small window in ONE round — and the
-- budget-driven folding can't compress a message it must keep verbatim.
-- The window-aware budget (15a Layer 2.5) handles the torso; this handles
-- the fat fresh message: cap it to a head + a handle, and let the model
-- PAGE the rest on demand. Model-chosen retrieval beats lossy auto-summary,
-- and it cuts token cost on paid providers (stop shipping 200k of raw pages).
--
-- Ratified 2026-06-18 (Michael — "lets build number 3"). P0 scope:
--   * page_in_cap: compose_messages truncates any single rendered message
--     over effective_budget*ratio to head + a [page-in] banner with its handle.
--   * result_read(handle, offset, limit) / result_search(handle, query):
--     read spans / grep within the full stored message (own session + the
--     non-private watch — reuses 27's context_descendant_sessions).
-- Window-aware (rides the now-correct effective_budget): big-window models
-- rarely truncate; small windows never overflow on one fat fetch.
-- Proposal: .spec/proposals/page-in-large-results.md.
-- requires create_alias_failover (32). Generic core.
-- =====================================================================

SELECT stewards.config_set('page_in_single_msg_ratio', '0.5'::jsonb,
  '33: compose_messages caps any single rendered message to effective_budget * this ratio (tokens, ~3.5 chars/tok); over the cap -> head + a page-in banner carrying the message handle. The model reads the rest with result_read/result_search. Window-aware. 0 disables.');

-- The "research notebook" cap (2026-06-19): an ABSOLUTE char cap for TOOL-role
-- results, applied on top of the ratio cap (compose_messages takes the lower of the
-- two for tool messages). The ratio cap is per-message, so a gather stage that does
-- several medium web_search/fetch calls piles them up under the cap until a local
-- model wedges. A low absolute tool cap pages EACH raw tool result to a head +
-- handle, so the model carries a compact "notebook" and pulls the bits it needs with
-- result_search/result_read. 0 = off (the public default; a local rig sets e.g. 3000).
SELECT stewards.config_set('page_in_tool_result_cap_chars', '0'::jsonb,
  '33: absolute char cap for TOOL-role results (the research-notebook lever). compose_messages caps a tool message to LEAST(ratio cap, this) when >0; the model pages the rest with result_search/result_read. 0 disables (default). A local rig sets ~3000 so gather does not accumulate raw web pages.');

-- ── the cap helper (wrapped around each rendered message by compose_messages) ──
CREATE OR REPLACE FUNCTION stewards.page_in_cap(p_obj jsonb, p_cap_chars int, p_handle text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE
        WHEN p_cap_chars IS NULL OR p_cap_chars <= 0 THEN p_obj
        WHEN p_obj ? 'content' AND p_obj ->> 'content' IS NOT NULL
             AND length(p_obj ->> 'content') > p_cap_chars THEN
            jsonb_set(p_obj, '{content}', to_jsonb(
                left(p_obj ->> 'content', p_cap_chars)
                || E'\n\n[page-in: ' || (length(p_obj ->> 'content') - p_cap_chars)::text
                || ' more chars truncated to fit the window. Read the rest with '
                || 'result_read("' || COALESCE(p_handle, '?') || '", offset, limit) or '
                || 'result_search("' || COALESCE(p_handle, '?') || '", "your query"); '
                || 'expand_message("' || COALESCE(p_handle, '?') || '") for the full text.]'))
        ELSE p_obj
    END;
$fn$;
COMMENT ON FUNCTION stewards.page_in_cap(jsonb, int, text) IS
'33: cap a single rendered message to p_cap_chars (head) + a page-in banner carrying its handle. No-op when content fits or cap<=0. Trims only content; tool_call_id/tool_calls/reasoning_content stay intact.';

-- ── result_read — read a span of a stored message by handle ──────────
CREATE OR REPLACE FUNCTION stewards.result_read_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower((regexp_match(coalesce(p_args ->> 'handle', ''), '([0-9a-fA-F]{3,8})'))[1]);
    v_off    int  := greatest(coalesce((p_args ->> 'offset')::int, 0), 0);
    v_lim    int  := least(greatest(coalesce((p_args ->> 'limit')::int, 4000), 100), 20000);
    v_content text;
    v_total  int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle IS NULL THEN RETURN jsonb_build_object('error', 'handle required (the id from a [ctx:..] / page-in banner)'); END IF;
    SELECT m.content INTO v_content
      FROM stewards.messages m
     WHERE stewards.context_handle(m.id) = v_handle
       AND m.session_id IN (SELECT v_sess
                            UNION
                            SELECT session_id FROM stewards.context_descendant_sessions(v_sess))
     LIMIT 1;
    IF v_content IS NULL THEN RETURN jsonb_build_object('error', 'no readable message for handle ' || v_handle || ' in your context'); END IF;
    v_total := length(v_content);
    RETURN jsonb_build_object(
        'ok', true, 'handle', v_handle, 'offset', v_off, 'total_chars', v_total,
        'returned', substring(v_content from v_off + 1 for v_lim),
        'has_more', (v_off + v_lim < v_total),
        'note', CASE WHEN v_off + v_lim < v_total
                     THEN 'more available — call again with offset=' || (v_off + v_lim)::text
                     ELSE 'end of content' END);
END;
$fn$;

-- ── result_search — grep within a stored message by handle ───────────
CREATE OR REPLACE FUNCTION stewards.result_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower((regexp_match(coalesce(p_args ->> 'handle', ''), '([0-9a-fA-F]{3,8})'))[1]);
    v_query  text := p_args ->> 'query';
    v_lim    int  := least(greatest(coalesce((p_args ->> 'limit')::int, 5), 1), 20);
    v_content text;
    v_res    jsonb;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle IS NULL THEN RETURN jsonb_build_object('error', 'handle required'); END IF;
    IF v_query IS NULL OR btrim(v_query) = '' THEN RETURN jsonb_build_object('error', 'query required'); END IF;
    BEGIN PERFORM regexp_instr('probe', v_query, 1, 1, 0, 'i');
    EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', 'invalid regex: ' || SQLERRM); END;
    SELECT m.content INTO v_content
      FROM stewards.messages m
     WHERE stewards.context_handle(m.id) = v_handle
       AND m.session_id IN (SELECT v_sess
                            UNION
                            SELECT session_id FROM stewards.context_descendant_sessions(v_sess))
     LIMIT 1;
    IF v_content IS NULL THEN RETURN jsonb_build_object('error', 'no readable message for handle ' || v_handle); END IF;
    SELECT jsonb_agg(jsonb_build_object(
               'at', off,
               'snippet', regexp_replace(substring(v_content from greatest(1, off - 60) for 220), '\s+', ' ', 'g')
           ) ORDER BY off)
      INTO v_res
    FROM (SELECT regexp_instr(v_content, v_query, 1, g, 0, 'i') AS off
            FROM generate_series(1, v_lim) g) s
   WHERE off > 0;
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'query', v_query,
        'matches', coalesce(v_res, '[]'::jsonb),
        'note', 'offsets are char positions — result_read(handle, offset, limit) to read a span in full');
END;
$fn$;

-- ── register the tools (sql_fn — no bridge refresh needed) ────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'result_read',
  'Read a span of a large tool result that was page-in truncated in your context. When a fetched page / document is too big to inline, you see its head plus a [page-in] banner with a handle; call result_read with that handle to read the rest in chunks. The full text is durable — you choose what to pull into your window.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the id from a [ctx:..] or page-in banner"},'
    '"offset":{"type":"integer","description":"start char offset (default 0)"},'
    '"limit":{"type":"integer","description":"chars to return (default 4000, max 20000)"}'
  '},"required":["handle"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"result_read_tool"}'::jsonb, true ),
( 'result_search',
  'Grep within a large tool result that was page-in truncated. Pass the handle from the [page-in] banner and a text/regex query; returns the char offsets + snippets of each match so you can result_read the right span. Use this to find the part of a big page you actually need without pulling the whole thing into your window.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the id from a [ctx:..] or page-in banner"},'
    '"query":{"type":"string","description":"text or POSIX regex to find (case-insensitive)"},'
    '"limit":{"type":"integer","description":"max matches (default 5, max 20)"}'
  '},"required":["handle","query"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"result_search_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- ── grant to the tool-using doers (idempotent) ───────────────────────
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
SELECT v.a, v.b, 'allow', 'manual'
  FROM (VALUES ('research','result_read'), ('research','result_search'),
               ('dev','result_read'), ('dev','result_search')) v(a, b)
 WHERE NOT EXISTS (
        SELECT 1 FROM stewards.agent_tool_perms p
         WHERE p.agent_family = v.a AND p.tool_pattern = v.b AND p.action = 'allow');

-- =====================================================================
-- End of 33-page-in.sql
-- =====================================================================
-- ===== [was 34-doc-builder.sql] =====
-- =====================================================================
-- 34-doc-builder.sql — agentic doc construction: build the artifact via
-- tool-call diffs, instead of one-shot emitting it as the final chat output.
-- =====================================================================
-- The problem (FlexLLama local-model soak, 2026-06-19): asking a small local
-- model to emit a 20k-char structured digest in ONE generation triggers all
-- three soak failures — the long call trips the 15-min reaper, it monopolizes
-- the model's one slot (contention), and grammar-constrained final output 500s
-- on a reasoning model ("peg-native format"). But these models are TRAINED for
-- tool-calling loops. Reframe (Michael, ratified 2026-06-19): the model BUILDS
-- the doc with small tool-call diffs (doc_create/append/patch), each call short;
-- its chat "final output" becomes a free-flow JOURNAL of what it did. This is how
-- the coder already works (code-write/code-pr ApplyEdits + self-heal), and how
-- Claude writes anything large — incrementally, never one-shot.
--
-- Why it addresses the three: many short calls (no single >15min reap); each call
-- frees the slot (interleave); tool-call JSON is the model's NATIVE trained format
-- and allows think-THEN-call, so reasoning tokens no longer break a grammar.
--
-- Pilot scope: playlist-digest (the leg actually broken on qwen). Self-contained:
-- WIP lives in its own doc_drafts table (NOT a flag on docs) so it touches zero
-- core search/embedding and a no-go just drops the table. Finalize pools via the
-- existing import_doc. Proposal: .spec/proposals/agentic-doc-construction.md.
-- Generic core; pairs with the page-in tools (33) for bounded source reads.
-- =====================================================================

-- ── provenance: tie a pooled doc back to the work item that produced it ──
-- A pooled doc had no reliable link to its producing work item: docs.frontmatter
-- .session stamps the FINALIZING caller's session, which for a loom/arc-c critic
-- is the CRITIC's session (arc-c-*), not the wi--<uuid8> builder. Add a real FK-ish
-- column. Chosen over a doc_provenance(slug, work_item_id) table because the
-- provenance we need is "the work item that produced the CURRENTLY-pooled body":
-- import_doc's ON CONFLICT(slug) DO UPDATE already models "latest producer wins"
-- for the body, and a single column shares that lifecycle exactly (stamped
-- alongside the body on each finalize). It answers both UI directions (this
-- work item's doc / this doc's work item) without a join, and is losslessly
-- supersedable by a history table later (backfill from the column) if an audit
-- of every producer is ever needed. Lives here (not create_docs) because its
-- meaning is defined by this subsystem — the same rationale as 03's
-- last_consolidated_at. Nullable: pure-chat drafts have no wi-- producer.
ALTER TABLE stewards.docs
    ADD COLUMN IF NOT EXISTS work_item_id uuid;
CREATE INDEX IF NOT EXISTS docs_work_item_id_idx
    ON stewards.docs (work_item_id) WHERE work_item_id IS NOT NULL;
COMMENT ON COLUMN stewards.docs.work_item_id IS
'34: the work item whose pipeline built this doc (stamped by doc_finalize from the DRAFT''s creating wi--<uuid8> session, robust to a critic finalizing under a different arc-c-* session). NULL for pure-chat drafts. The reliable doc→work-item tie the frontmatter.session text could not give.';

-- ── WIP drafts: the model's scratch artifact, keyed by its building session ──
CREATE TABLE IF NOT EXISTS stewards.doc_drafts (
    handle      text PRIMARY KEY DEFAULT substr(md5(random()::text || clock_timestamp()::text), 1, 8),
    session_id  text NOT NULL,
    title       text NOT NULL,
    outline     text,
    body        text NOT NULL DEFAULT '',
    project     text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS doc_drafts_session_idx ON stewards.doc_drafts (session_id);
COMMENT ON TABLE stewards.doc_drafts IS
'34: work-in-progress docs the model builds incrementally via doc_* tool calls. Scoped to the building WORK ITEM (all its stages), so a build stage can construct a draft and a separate critic/publish stage can read+patch+publish it. finalize -> import_doc pool + delete. Self-contained (no core search/embedding touch).';

-- ── work-item-scoped access (cross-stage drafts) ──────────────────────
-- A pipeline dispatches each stage under its own session id of the form
-- `wi--<uuid8>--<stage>` (04-work-items.sql work_item_dispatch_stage). Scoping a
-- draft to the EXACT session would lock it to the stage that created it — so a
-- build stage's draft would be invisible to a separate critic/publish stage of
-- the SAME run. Match on the shared `wi--<uuid8>` work-item prefix instead: a
-- draft is reachable from any stage of the work item that built it, but stays
-- isolated across different work items and from persona/chat sessions (which use
-- a different id shape → exact-match only). The handle is a random PK, so this is
-- a scoping convenience, not the security boundary.
--
-- arc-c- callers (ratified 2026-07-04): the Arc C HTTP MCP surface mints
-- `arc-c-<hex>` sessions per connection (cmd/stewards-mcp/http.go). An
-- out-of-band reviewer reached through it — e.g. a loom-hosted critique stage
-- finalizing the build stage's draft — can never share a wi-- prefix, so
-- without this branch the whole narrow-write surface (doc_read/patch/finalize
-- by handle) is unusable for drafts it didn't create. For arc-c callers the
-- HANDLE is the capability: every call site already filters `handle = <given>`,
-- and the surface itself sits behind the bearer token (localhost wall). In-band
-- sessions (wi--/chat/persona) keep the strict scoping above.
CREATE OR REPLACE FUNCTION stewards.doc_draft_session_match(p_draft_session text, p_caller_session text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
    SELECT p_draft_session = p_caller_session
        OR ( left(p_draft_session, 4) = 'wi--'
             AND left(p_caller_session, 4) = 'wi--'
             AND split_part(p_draft_session, '--', 2) = split_part(p_caller_session, '--', 2) )
        OR left(p_caller_session, 6) = 'arc-c-';
$fn$;
COMMENT ON FUNCTION stewards.doc_draft_session_match(text, text) IS
'34: true if a draft session belongs to the same work item (wi--<uuid8>) as the caller, the exact same session, or the caller is the token-authed Arc C HTTP surface (arc-c-*, handle-as-capability — every call site filters by handle). Lets a draft built in one stage be reached by a later stage of the same run, or by an out-of-band reviewer that was handed the handle.';

-- ── doc_create: start a draft (outline-first, for coherence) ──────────
CREATE OR REPLACE FUNCTION stewards.doc_create_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess    text := p_args ->> '_session_id';
    v_title   text := btrim(coalesce(p_args ->> 'title', ''));
    v_outline text := p_args ->> 'outline';
    v_project text := p_args ->> 'project';
    v_handle  text;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_title = '' THEN RETURN jsonb_build_object('error', 'title required'); END IF;
    INSERT INTO stewards.doc_drafts (session_id, title, outline, project, body)
    VALUES (v_sess, v_title, v_outline, v_project, '# ' || v_title || E'\n')
    RETURNING handle INTO v_handle;
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'title', v_title,
        'note', 'draft started. Build it section by section with doc_append_section("' || v_handle ||
                '", heading, body); fix with doc_patch; check with doc_read; doc_finalize when complete. '
                || CASE WHEN v_outline IS NOT NULL AND btrim(v_outline) <> ''
                        THEN 'Your outline: ' || v_outline ELSE 'Tip: sketch an outline first.' END);
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_create_tool(jsonb) IS '34: start a WIP draft, return its handle.';

-- ── doc_append_section: append a section (the main building diff) ──────
CREATE OR REPLACE FUNCTION stewards.doc_append_section_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess    text := p_args ->> '_session_id';
    v_handle  text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_heading text := p_args ->> 'heading';
    v_body    text := coalesce(p_args ->> 'body', '');
    v_chars   int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle = '' THEN RETURN jsonb_build_object('error', 'handle required (from doc_create)'); END IF;
    IF btrim(v_body) = '' AND coalesce(btrim(v_heading), '') = '' THEN
        RETURN jsonb_build_object('error', 'heading or body required'); END IF;
    UPDATE stewards.doc_drafts
       SET body = body || E'\n\n'
                  || CASE WHEN v_heading IS NOT NULL AND btrim(v_heading) <> ''
                          THEN '## ' || btrim(v_heading) || E'\n\n' ELSE '' END
                  || v_body,
           updated_at = now()
     WHERE handle = v_handle AND stewards.doc_draft_session_match(session_id, v_sess)
    RETURNING length(body) INTO v_chars;
    IF v_chars IS NULL THEN RETURN jsonb_build_object('error', 'no draft ' || v_handle || ' in your session (doc_create first)'); END IF;
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'total_chars', v_chars,
        'note', 'section appended. Keep going, or doc_read to review, or doc_finalize to pool it.');
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_append_section_tool(jsonb) IS '34: append a markdown section to a draft.';

-- ── doc_patch: replace the first occurrence of an anchor (corrections) ─
CREATE OR REPLACE FUNCTION stewards.doc_patch_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_find   text := p_args ->> 'find';
    v_repl   text := coalesce(p_args ->> 'replace', '');
    v_body   text;
    v_pos    int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle = '' THEN RETURN jsonb_build_object('error', 'handle required'); END IF;
    IF v_find IS NULL OR v_find = '' THEN RETURN jsonb_build_object('error', 'find (the exact text to replace) required'); END IF;
    SELECT body INTO v_body FROM stewards.doc_drafts WHERE handle = v_handle AND stewards.doc_draft_session_match(session_id, v_sess);
    IF v_body IS NULL THEN RETURN jsonb_build_object('error', 'no draft ' || v_handle || ' in your session'); END IF;
    v_pos := position(v_find IN v_body);
    IF v_pos = 0 THEN RETURN jsonb_build_object('error', 'find text not present — doc_read to see the current body', 'handle', v_handle); END IF;
    UPDATE stewards.doc_drafts
       SET body = left(v_body, v_pos - 1) || v_repl || substr(v_body, v_pos + length(v_find)),
           updated_at = now()
     WHERE handle = v_handle AND stewards.doc_draft_session_match(session_id, v_sess);
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'note', 'patched the first occurrence.');
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_patch_tool(jsonb) IS '34: replace the first occurrence of an anchor in a draft.';

-- ── doc_read: read back what is built (read-before-write discipline) ──
CREATE OR REPLACE FUNCTION stewards.doc_read_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_d      stewards.doc_drafts%ROWTYPE;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle = '' THEN RETURN jsonb_build_object('error', 'handle required'); END IF;
    SELECT * INTO v_d FROM stewards.doc_drafts WHERE handle = v_handle AND stewards.doc_draft_session_match(session_id, v_sess);
    IF v_d.handle IS NULL THEN RETURN jsonb_build_object('error', 'no draft ' || v_handle || ' in your session'); END IF;
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'title', v_d.title,
        'total_chars', length(v_d.body), 'body', v_d.body);
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_read_tool(jsonb) IS '34: read the current body of a draft.';

-- ── doc_finalize: pool the finished draft (import_doc) + delete it ────
CREATE OR REPLACE FUNCTION stewards.doc_finalize_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_slug   text := p_args ->> 'slug';
    v_d      stewards.doc_drafts%ROWTYPE;
    v_doc_id text;
    v_proj   text;
    v_wi     uuid;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle = '' THEN RETURN jsonb_build_object('error', 'handle required'); END IF;
    SELECT * INTO v_d FROM stewards.doc_drafts WHERE handle = v_handle AND stewards.doc_draft_session_match(session_id, v_sess);
    IF v_d.handle IS NULL THEN RETURN jsonb_build_object('error', 'no draft ' || v_handle || ' in your session'); END IF;
    IF length(btrim(v_d.body)) < 80 THEN
        RETURN jsonb_build_object('error', 'draft too short to finalize (' || length(v_d.body) || ' chars) — build it first'); END IF;
    v_slug := coalesce(nullif(btrim(coalesce(v_slug, '')), ''),
                       regexp_replace(lower(v_d.title), '[^a-z0-9]+', '-', 'g') || '-' || v_handle);
    -- pool it (import_doc returns the doc id, not the slug)
    v_doc_id := stewards.import_doc(v_slug, '', v_d.title, v_d.body,
                    jsonb_build_object('built_by', 'doc-construction', 'session', v_sess), 'doc');
    -- Provenance: resolve the producing work item from the DRAFT's creating
    -- session (wi--<uuid8>--<stage>), NOT the finalizing caller (v_sess). A
    -- loom/arc-c critic finalizes under an arc-c-* session, so keying on the
    -- caller silently missed BOTH the work_item link and the project tag for
    -- every critic-finalized doc. The draft row carries the builder's session.
    IF left(v_d.session_id, 4) = 'wi--' THEN
        SELECT id INTO v_wi FROM stewards.work_items
         WHERE left(id::text, 8) = split_part(v_d.session_id, '--', 2)
         ORDER BY created_at DESC
         LIMIT 1;
    END IF;
    IF v_wi IS NOT NULL THEN
        UPDATE stewards.docs SET work_item_id = v_wi WHERE slug = v_slug;
    END IF;

    -- Project-tag the pooled doc so it is findable in the intent pool. Prefer the
    -- draft's explicit project; else fall back to the producing WORK ITEM's project
    -- (a research digest has no static project like a book does — its project comes
    -- from the intent->project map on the work_item). Resolved via v_wi above so it
    -- works even when the finalizing caller is an out-of-band critic (same fix).
    v_proj := nullif(btrim(coalesce(v_d.project, '')), '');
    IF v_proj IS NULL AND v_wi IS NOT NULL THEN
        SELECT project_association INTO v_proj FROM stewards.work_items
         WHERE id = v_wi AND project_association IS NOT NULL;
    END IF;
    IF v_proj IS NOT NULL THEN
        UPDATE stewards.docs SET project_association = v_proj WHERE slug = v_slug;
    END IF;
    DELETE FROM stewards.doc_drafts WHERE handle = v_handle;
    RETURN jsonb_build_object('ok', true, 'slug', v_slug, 'doc_id', v_doc_id,
        'chars', length(v_d.body),
        'note', 'pooled to the docs corpus and the draft cleared. Your chat reply now is the JOURNAL: what you read, chose, and produced.');
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_finalize_tool(jsonb) IS '34: pool a finished draft via import_doc + delete the draft. Stamps docs.work_item_id (and the project tag) from the DRAFT''s wi--<uuid8> creating session, so the doc→work-item tie survives an arc-c/loom critic finalizing under a different session.';

-- ── doc_current: find the active draft for THIS work item (cross-stage) ──
-- A later stage (critic / publish) needs the handle of the draft an earlier
-- stage built. Rather than parse it out of the prior stage's free-text journal,
-- this returns the most-recently-touched draft reachable from the caller's
-- work item (doc_draft_session_match). One draft per run is the common case.
CREATE OR REPLACE FUNCTION stewards.doc_current_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_sess text := p_args ->> '_session_id';
    v_d    stewards.doc_drafts%ROWTYPE;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    SELECT * INTO v_d FROM stewards.doc_drafts
     WHERE stewards.doc_draft_session_match(session_id, v_sess)
     ORDER BY updated_at DESC LIMIT 1;
    IF v_d.handle IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'handle', NULL,
            'note', 'no active draft for this work item — an earlier stage should have doc_create''d one'); END IF;
    RETURN jsonb_build_object('ok', true, 'handle', v_d.handle, 'title', v_d.title,
        'total_chars', length(v_d.body),
        'note', 'the active draft. doc_read it, revise with doc_patch, then publish/finalize.');
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_current_tool(jsonb) IS '34: return the active draft handle for the caller''s work item (cross-stage handoff).';

-- ── register the tools (sql_fn — no bridge refresh needed) ────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'doc_current',
  'Find the document draft your run is building (its handle), when a previous stage created it and you need to read, revise, or publish it. Returns {handle, title, total_chars}. Use this at the start of a critic or publish stage to pick up the draft the build stage made.',
  '{"type":"object","additionalProperties":false,"properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_current_tool"}'::jsonb, true ),
( 'doc_create',
  'Start building a document incrementally. You do NOT write the whole document as one chat reply — you BUILD it with tool calls (this is how good agents write anything large). Returns a handle. Sketch an outline, then add sections with doc_append_section, fix with doc_patch, and doc_finalize when done. Your final chat reply is a short JOURNAL of what you did, not the document itself.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"title":{"type":"string","description":"the document title"},'
    '"outline":{"type":"string","description":"optional: a brief section outline to keep the doc coherent"},'
    '"project":{"type":"string","description":"optional pool/project tag, e.g. ai or books"}'
  '},"required":["title"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_create_tool"}'::jsonb, true ),
( 'doc_append_section',
  'Append one section to the document you are building. Keep each call small — a heading plus a few focused paragraphs. Call it repeatedly to build the doc section by section. Small diffs are the point: they finish fast (no timeouts), free the model for other work, and play to what you are good at (tool calls, not one giant grammar-constrained generation).',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the draft handle from doc_create"},'
    '"heading":{"type":"string","description":"section heading (optional; omit to append body only)"},'
    '"body":{"type":"string","description":"the section text (markdown)"}'
  '},"required":["handle","body"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_append_section_tool"}'::jsonb, true ),
( 'doc_patch',
  'Fix or revise text already in your draft: replace the first occurrence of an exact anchor string with new text. Use doc_read first to see the current body. Good for corrections and tightening — redemptive editing, the same loop you use when fixing code.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the draft handle"},'
    '"find":{"type":"string","description":"exact text currently in the draft to replace"},'
    '"replace":{"type":"string","description":"the new text (empty string deletes the anchor)"}'
  '},"required":["handle","find"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_patch_tool"}'::jsonb, true ),
( 'doc_read',
  'Read back the current body of the document you are building, so you know what is already there before adding more (read-before-write).',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the draft handle"}'
  '},"required":["handle"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_read_tool"}'::jsonb, true ),
( 'doc_finalize',
  'Finish the document: pool it to the searchable corpus and clear the draft. Call this once the doc is complete. After finalizing, your chat reply should be a short JOURNAL — what you read, what you decided, and that you produced the doc (slug returned) — NOT the document text again.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the draft handle"},'
    '"slug":{"type":"string","description":"optional explicit slug (default derived from the title)"}'
  '},"required":["handle"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_finalize_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- ── grant to the digester / research doers (idempotent) ───────────────
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
SELECT v.a, v.b, 'allow', 'manual'
  FROM (SELECT a, b FROM unnest(ARRAY['research','stewards-explore']) a
                  CROSS JOIN unnest(ARRAY['doc_create','doc_append_section','doc_patch','doc_read','doc_finalize','doc_current']) b) v
 WHERE NOT EXISTS (
        SELECT 1 FROM stewards.agent_tool_perms p
         WHERE p.agent_family = v.a AND p.tool_pattern = v.b AND p.action = 'allow');

-- =====================================================================
-- End of 34-doc-builder.sql
-- =====================================================================
