-- =====================================================================
-- 19-models.sql — model capability registry, auto-probe, and the
-- dispatch FINAL (the last subsystem; completes the authored chain 00→19)
-- =====================================================================
-- The substrate's knowledge of which catalogued models it can actually
-- dispatch, how to reach each one, and the chokepoint that uses it. This
-- file also lands the work_item_dispatch_stage FINAL — deferred from 14 —
-- the accreted resolution + capability + spend-cap + max-tokens dispatcher.
--
-- Consolidated (clean-room: the FINAL state). Sources, in author order:
--   §1  m1   — model_capability table (born complete, api_format folded from
--              an1) + model_usable + first_usable_model + model_catalog view
--   §2  an1  — model_api_format + the work_queue api_format stamp trigger
--   §3  m2   — pick_usable_model + model_substitutions.reason + the
--              reason-aware trigger_log_model_substitution FINAL (over 15a's l29)
--   §4  m4   — enqueue_model_probe + the work_queue terminal verdict trigger
--   §5  m5   — enqueue_due_model_probes + the watchman-pass schedule trigger
--   §6  r3   — work_item_dispatch_stage FINAL: J.8.a 4-layer resolution +
--              M.2 capability substitution + J.11 spend-cap gate + R.3
--              per-call max_tokens / input-scoped tools_disabled
--
-- requires create_scheduler (18). Deps from earlier batches: model_pricing +
-- provider_spend_caps + provider_cap_exceeded/provider_spend_since (06),
-- model_substitutions (15a), catalog_default_provider/catalog_default_model (14),
-- pipeline_stage_lookup / render_stage_input / dry_run_chat (04/15b), watchman_passes (03).
--
-- DISPATCH-FINAL: work_item_dispatch_stage is born 3-arg in 04 and accreted
-- across j8a (4-layer fallback) → j11 (spend cap) → m2 (capability gate) →
-- r3 (max_tokens). r3 is the chronological + manifest last and carries all
-- four verbatim; only r3's body is authored here. j8a's catalog_default_*
-- helpers live in 14; j11's provider_spend_caps machinery lives in 06.
--
-- OVERLAY (not core): every model SEED is operator/provider-specific and lives
-- in the workspace overlay — m1's capability verdicts (qwen3.7-max unusable,
-- glm/kimi/… usable), an1's anthropic-format rows, and ALL of zen1 (the
-- opencode_zen Claude catalog + $18 cap). Core ships the machinery; unrowed
-- models default usable + openai-format, and the M.4 auto-probe fills verdicts
-- at runtime (the B2 operator-seeds-to-overlay rule).
-- =====================================================================


-- =====================================================================
-- §1 — m1: the model capability registry.
-- =====================================================================
-- usable=false is the ONLY thing that gates dispatch; a model with no row is
-- usable (innocent until proven guilty), mirroring the J.11 cap gate. The
-- api_format column (an1) is born here so the table is complete in one place.
CREATE TABLE IF NOT EXISTS stewards.model_capability (
    provider           text NOT NULL,
    model              text NOT NULL,
    usable             boolean NOT NULL DEFAULT true,
    supports_streaming boolean,            -- NULL = not yet determined
    api_format         text NOT NULL DEFAULT 'openai',   -- AN.1: openai (/chat/completions) | anthropic (/messages)
    last_probed_at     timestamptz,
    probe_detail       text,               -- the error, or a short 'ok' note
    probed_via         text NOT NULL DEFAULT 'seed',  -- seed | manual | auto-probe
    updated_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, model),
    CONSTRAINT model_capability_api_format_chk CHECK (api_format IN ('openai','anthropic'))
);

COMMENT ON TABLE stewards.model_capability IS
'M.1 + AN.1: per-model dispatchability signal. usable=false gates the model in work_item_dispatch_stage (M.2, substitute-and-log). A model with no row defaults to usable. supports_streaming isolates the streaming-empty failure axis; api_format selects the gateway dispatch path. Kept current by the M.4 auto-probe.';

COMMENT ON COLUMN stewards.model_capability.supports_streaming IS
'M.1: whether content arrives over the streaming path the substrate dispatches with (stream:true). Some reasoning models stream empty despite working non-streaming.';

COMMENT ON COLUMN stewards.model_capability.probed_via IS
'M.1: seed (hand-verified), manual (probe tool), or auto-probe (the M.4 watchman-cadence probe).';

COMMENT ON COLUMN stewards.model_capability.api_format IS
'AN.1: which gateway API shape the model needs — openai (/chat/completions, default) or anthropic (/messages). Stamped onto chat work_queue payloads; the bgworker branches on it.';


-- model_usable(provider, model): false ONLY when an explicit row says so.
CREATE OR REPLACE FUNCTION stewards.model_usable(p_provider text, p_model text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT usable
           FROM stewards.model_capability
          WHERE provider = p_provider AND model = p_model),
        true
    );
$$;

COMMENT ON FUNCTION stewards.model_usable(text, text) IS
'M.1: true unless model_capability explicitly marks (provider, model) usable=false. Unknown models default to usable so existing dispatch is never broken. The substitution gate in work_item_dispatch_stage (M.2) consults this.';


-- first_usable_model(provider): cheapest priced + usable model, or NULL.
CREATE OR REPLACE FUNCTION stewards.first_usable_model(p_provider text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT mp.model
      FROM (
          SELECT DISTINCT ON (provider, model) provider, model, output_micro_per_mtok
            FROM stewards.model_pricing
           ORDER BY provider, model, effective_at DESC
      ) mp
     WHERE mp.provider = p_provider
       AND stewards.model_usable(mp.provider, mp.model)
     ORDER BY mp.output_micro_per_mtok ASC NULLS LAST
     LIMIT 1;
$$;

COMMENT ON FUNCTION stewards.first_usable_model(text) IS
'M.1: cheapest priced + usable model for a provider, or NULL if none. M.2 substitution fallback when the catalog default is itself unusable.';


-- model_catalog view: latest pricing per (provider, model) + capability verdict.
CREATE OR REPLACE VIEW stewards.model_catalog AS
SELECT
    mp.provider,
    mp.model,
    mp.input_micro_per_mtok,
    mp.output_micro_per_mtok,
    mp.notes                       AS pricing_notes,
    COALESCE(mc.usable, true)      AS usable,
    mc.supports_streaming,
    mc.last_probed_at,
    mc.probe_detail,
    COALESCE(mc.probed_via, 'unprobed') AS probed_via
FROM (
    SELECT DISTINCT ON (provider, model)
           provider, model, input_micro_per_mtok, output_micro_per_mtok, notes
      FROM stewards.model_pricing
     ORDER BY provider, model, effective_at DESC
) mp
LEFT JOIN stewards.model_capability mc
       ON mc.provider = mp.provider AND mc.model = mp.model;

COMMENT ON VIEW stewards.model_catalog IS
'M.1: latest pricing per (provider, model) joined to capability verdict. usable defaults true for un-probed models. Backs the list_models MCP tool.';


-- =====================================================================
-- §2 — an1: per-model API format + the work_queue stamp trigger.
-- =====================================================================
-- opencode serves some models ONLY in Anthropic format (/messages). This
-- records which format each model needs and stamps it onto every chat
-- work_queue row (BEFORE INSERT, so it covers the dispatcher AND direct
-- inserters like enqueue_model_probe). Unrowed models default to 'openai'.
CREATE OR REPLACE FUNCTION stewards.model_api_format(p_provider text, p_model text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT api_format FROM stewards.model_capability
          WHERE provider = p_provider AND model = p_model),
        'openai'
    );
$$;

COMMENT ON FUNCTION stewards.model_api_format(text, text) IS
'AN.1: the dispatch API format for a model — defaults to openai for unrowed models.';

CREATE OR REPLACE FUNCTION stewards.trigger_stamp_api_format()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_model text;
    v_fmt   text;
BEGIN
    IF NEW.payload ? 'api_format' THEN
        RETURN NEW;  -- caller already specified
    END IF;
    v_model := COALESCE(NEW.payload ->> 'requested_model', NEW.payload -> 'body' ->> 'model');
    IF v_model IS NULL THEN
        RETURN NEW;
    END IF;
    v_fmt := stewards.model_api_format(NEW.provider, v_model);
    NEW.payload := NEW.payload || jsonb_build_object('api_format', v_fmt);
    RETURN NEW;
END;
$FN$;

DROP TRIGGER IF EXISTS work_queue_stamp_api_format ON stewards.work_queue;

CREATE TRIGGER work_queue_stamp_api_format
BEFORE INSERT ON stewards.work_queue
FOR EACH ROW
WHEN (NEW.kind = 'chat')
EXECUTE FUNCTION stewards.trigger_stamp_api_format();

COMMENT ON FUNCTION stewards.trigger_stamp_api_format() IS
'AN.1: BEFORE INSERT on chat work_queue rows — stamps payload.api_format from model_api_format(provider, requested_model) unless already set. Covers dispatch + the direct-insert probe path.';


-- =====================================================================
-- §3 — m2: capability substitution helper + the substitution logger FINAL.
-- =====================================================================
-- pick_usable_model is the substitution decision the dispatcher (§6) makes
-- when a resolved model is unusable. The model_substitutions table is born in
-- 15a (l29); here we add its `reason` column and re-author its single-writer
-- trigger to the reason-aware FINAL (capability swaps carry a marker + reason
-- and skip the passive pipeline-vs-requested compare).
CREATE OR REPLACE FUNCTION stewards.pick_usable_model(p_provider text, p_model text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN stewards.model_usable(p_provider, p_model) THEN p_model
        WHEN stewards.catalog_default_model(p_provider) IS NOT NULL
             AND stewards.model_usable(p_provider, stewards.catalog_default_model(p_provider))
            THEN stewards.catalog_default_model(p_provider)
        ELSE stewards.first_usable_model(p_provider)
    END;
$$;

COMMENT ON FUNCTION stewards.pick_usable_model(text, text) IS
'M.2: returns p_model if usable; else the provider catalog default if usable; else the cheapest usable model; else NULL. The substitution decision for work_item_dispatch_stage.';

ALTER TABLE stewards.model_substitutions ADD COLUMN IF NOT EXISTS reason text;

COMMENT ON COLUMN stewards.model_substitutions.reason IS
'M.2: why the substitution happened. NULL for l29 passive pipeline-vs-requested detections; "capability: ..." for M.2 unusable-model swaps.';

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

    -- M.2: capability substitution carries its own marker + reason. Log it
    -- and return — do NOT fall through to the pipeline-vs-requested compare,
    -- which would double-log the same swap.
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
'M.2 (was l29): single writer to model_substitutions. Capability swaps (payload._capability_substitution) log with a reason and skip the passive compare; otherwise the original pipeline-declared-vs-requested detection runs (reason NULL).';


-- =====================================================================
-- §4 — m4: model auto-probe (test a model over the real streaming path).
-- =====================================================================
-- enqueue_model_probe inserts a tiny chat DIRECTLY into work_queue (bypassing
-- the dispatcher so the M.2 substitution does not swap the model under test);
-- the terminal-transition trigger records the verdict into model_capability.
CREATE OR REPLACE FUNCTION stewards.enqueue_model_probe(
    p_provider text,
    p_model    text
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_session  text;
    v_payload  jsonb;
    v_work_id  bigint;
BEGIN
    v_session := substring(
        'probe--' || p_provider || '--' || p_model || '--'
        || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS')
        FROM 1 FOR 200);

    -- The session must exist so the bgworker's assistant-message INSERT lands.
    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session, format('model probe %s/%s', p_provider, p_model), 'agent')
    ON CONFLICT (id) DO NOTHING;

    v_payload := jsonb_build_object(
        'session_id',      v_session,
        'agent_family',    'model-probe',
        'requested_model', p_model,
        'tools_disabled',  true,
        'body', jsonb_build_object(
            'model',      p_model,
            'max_tokens', 256,
            'messages',   jsonb_build_array(
                jsonb_build_object(
                    'role', 'user',
                    'content', 'Reply with exactly: OK'
                )
            )
        ),
        '_probe', jsonb_build_object('provider', p_provider, 'model', p_model)
    );

    -- Direct work_queue insert — NOT work_item_dispatch_stage — so the M.2
    -- capability substitution does not swap the model under test.
    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', p_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_model_probe(text, text) IS
'M.4: enqueue a tiny streaming chat to test whether (provider, model) is dispatchable. Direct work_queue insert (bypasses the M.2 substitution gate). The work_queue terminal-transition trigger records the verdict into model_capability.';

CREATE OR REPLACE FUNCTION stewards.trigger_resolve_model_probe()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_provider text;
    v_model    text;
    v_session  text;
    v_content  text;
    v_finish   text;
    v_usable   boolean;
    v_detail   text;
BEGIN
    v_provider := NEW.payload -> '_probe' ->> 'provider';
    v_model    := NEW.payload -> '_probe' ->> 'model';
    v_session  := NEW.payload ->> 'session_id';

    IF NEW.status = 'error' THEN
        v_usable := false;
        v_detail := 'auto-probe: dispatch error: '
                    || left(COALESCE(NEW.error, '(no error text)'), 240);
    ELSE
        -- done: did content arrive over the streaming path?
        SELECT content, finish_reason INTO v_content, v_finish
          FROM stewards.messages
         WHERE session_id = v_session AND role = 'assistant'
         ORDER BY id DESC LIMIT 1;

        v_usable := length(trim(COALESCE(v_content, ''))) > 0;
        IF v_usable THEN
            v_detail := format('auto-probe: ok — %s content chars, finish=%s',
                               length(v_content), COALESCE(v_finish, '(null)'));
        ELSE
            v_detail := format('auto-probe: streaming returned empty content (0 chars), finish=%s',
                               COALESCE(v_finish, '(null)'));
        END IF;
    END IF;

    INSERT INTO stewards.model_capability
        (provider, model, usable, supports_streaming, last_probed_at, probe_detail, probed_via)
    VALUES
        (v_provider, v_model, v_usable, v_usable, now(), v_detail, 'auto-probe')
    ON CONFLICT (provider, model) DO UPDATE
    SET usable             = EXCLUDED.usable,
        supports_streaming = EXCLUDED.supports_streaming,
        last_probed_at     = now(),
        probe_detail       = EXCLUDED.probe_detail,
        probed_via         = 'auto-probe',
        updated_at         = now();

    RAISE NOTICE 'auto-probe verdict: %/% usable=% (%)',
        v_provider, v_model, v_usable, v_detail;

    RETURN NEW;
END;
$FN$;

DROP TRIGGER IF EXISTS work_queue_resolve_model_probe ON stewards.work_queue;

CREATE TRIGGER work_queue_resolve_model_probe
AFTER UPDATE ON stewards.work_queue
FOR EACH ROW
WHEN (NEW.status IN ('done', 'error')
      AND OLD.status IS DISTINCT FROM NEW.status
      AND NEW.payload -> '_probe' IS NOT NULL)
EXECUTE FUNCTION stewards.trigger_resolve_model_probe();

COMMENT ON FUNCTION stewards.trigger_resolve_model_probe() IS
'M.4: on a probe work_queue row reaching done/error, records the verdict into model_capability. error -> unusable; done+empty content -> unusable (streaming-empty); done+content -> usable. probed_via=auto-probe.';


-- =====================================================================
-- §5 — m5: auto-probe scheduling (rides the watchman cadence).
-- =====================================================================
-- enqueue_due_model_probes finds priced models that are unprobed or stale and
-- enqueues a probe for each (capped, deduped, cap-aware). A guarded trigger on
-- watchman_passes calls it whenever the watchman fires — so probing rides the
-- existing scheduler cadence (and pauses when the soak is paused).
CREATE OR REPLACE FUNCTION stewards.enqueue_due_model_probes(
    p_staleness interval DEFAULT interval '7 days',
    p_max       int      DEFAULT 3
) RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_rec    record;
    v_count  int := 0;
BEGIN
    FOR v_rec IN
        SELECT mp.provider, mp.model
          FROM (SELECT DISTINCT provider, model FROM stewards.model_pricing) mp
          LEFT JOIN stewards.model_capability mc
            ON mc.provider = mp.provider AND mc.model = mp.model
         WHERE (mc.last_probed_at IS NULL
                OR mc.last_probed_at < now() - p_staleness)
           AND NOT stewards.provider_cap_exceeded(mp.provider)
         ORDER BY mc.last_probed_at ASC NULLS FIRST, mp.provider, mp.model
         LIMIT p_max
    LOOP
        -- Dedup: don't pile a second probe for a model already in flight.
        IF NOT EXISTS (
            SELECT 1 FROM stewards.work_queue
             WHERE kind = 'chat'
               AND status NOT IN ('done', 'error')
               AND payload -> '_probe' ->> 'provider' = v_rec.provider
               AND payload -> '_probe' ->> 'model'    = v_rec.model
        ) THEN
            PERFORM stewards.enqueue_model_probe(v_rec.provider, v_rec.model);
            v_count := v_count + 1;
        END IF;
    END LOOP;

    RETURN v_count;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_due_model_probes(interval, int) IS
'M.5: enqueue probes for up to p_max priced models that are unprobed or older than p_staleness, skipping cap-exceeded providers and models with a probe already in flight. Returns the count enqueued.';

CREATE OR REPLACE FUNCTION stewards.trigger_schedule_due_model_probes()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_n int;
BEGIN
    BEGIN
        v_n := stewards.enqueue_due_model_probes();
        IF v_n > 0 THEN
            RAISE NOTICE 'auto-probe: enqueued % due model probe(s) on watchman pass %',
                v_n, NEW.pass_id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'auto-probe scheduling skipped (non-fatal): %', SQLERRM;
    END;
    RETURN NEW;
END;
$FN$;

DROP TRIGGER IF EXISTS watchman_passes_schedule_model_probes ON stewards.watchman_passes;

CREATE TRIGGER watchman_passes_schedule_model_probes
AFTER INSERT ON stewards.watchman_passes
FOR EACH ROW
EXECUTE FUNCTION stewards.trigger_schedule_due_model_probes();

COMMENT ON FUNCTION stewards.trigger_schedule_due_model_probes() IS
'M.5: on watchman-pass creation, enqueue any due model probes. Errors are swallowed so probe scheduling never breaks a watchman pass.';


-- =====================================================================
-- §6 — r3: work_item_dispatch_stage FINAL.
-- =====================================================================
-- The accreted dispatcher: J.8.a 4-layer model/provider resolution → M.2
-- capability substitution (substitute-and-log an unusable model) → J.11
-- enforced spend-cap gate → R.3 per-call max_tokens + input-scoped
-- tools_disabled. Existing usable-model dispatch is byte-identical (no marker,
-- no max_tokens) — only NULL stage.model, an unusable model, an over-cap
-- provider, or an input/stage max_tokens changes the payload.
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

    -- J.8.a: 4-layer resolution (input -> stages -> pipeline -> catalog).
    v_provider := COALESCE(
        v_wi.provider_override,
        v_stage->>'provider',
        v_pipeline_meta->>'default_provider',
        stewards.catalog_default_provider()
    );

    v_model := COALESCE(
        v_wi.model_override,
        v_stage->>'model',
        v_pipeline_meta->>'default_model',
        stewards.catalog_default_model(v_provider)
    );

    IF v_agent IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % missing agent_family',
            p_work_item_id, v_wi.current_stage;
    END IF;
    IF v_model IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % could not resolve model — checked work_items.model_override, stages.model, pipelines.metadata.default_model, catalog_default_model(%) — all NULL',
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
'Dispatch FINAL (J.8.a + M.2 + J.11 + R.3): 4-layer model/provider resolution, capability substitution (unusable -> usable, logged), enforced provider spend-cap gate, and per-call max_tokens + input-scoped tools_disabled. Existing usable-model dispatch is byte-identical.';


-- =====================================================================
-- End of 19-models.sql — the authored chain is complete (00→19).
-- =====================================================================
