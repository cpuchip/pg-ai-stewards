-- =====================================================================
-- v32-dispatch-honesty.sql — the dispatch says what it does.
-- =====================================================================
-- Three independent honesty fixes, each a later-file-wins re-author of a
-- CORE function (no data migration; additive config description refresh):
--
--   §1 (FIX 1 — the unstick-pin bug). work_item_dispatch_stage read
--      work_items.model_override into its 4-layer ladder, but the M.2
--      capability-substitution gate then SILENTLY swapped ANY unusable
--      resolved model — including an explicit item override. So an operator
--      (or the steward's escalation write) who pinned model_override='X'
--      watched every dispatch land on the provider's cheapest usable model
--      instead, with only a NOTICE. Now: an item override that names an
--      unusable CONCRETE model is REFUSED with a clear error naming the
--      override, not substituted. Stage / pipeline / alias-resolved models
--      still substitute byte-identically to v08 (31-model-aliases). The
--      _safe wrapper learns the new error shape so the autonomous path
--      PARKS (awaiting_review, rings the bell) instead of hard-raising.
--
--   §2 (FIX 2 — probes must exercise the path they claim, #359). The probe
--      body never declared stream:true; it relied implicitly on the
--      bgworker forcing streaming onto every chat. A body-respecting
--      executor (or a shim like loom) would run the probe NON-streaming,
--      pass a model whose streaming path a provider rejects, and
--      trigger_resolve_model_probe would flip usable=true — re-poisoning
--      routing. Now the probe body declares stream:true + stream_options
--      (matching a real dispatch body exactly) and the resolve trigger
--      records supports_streaming as the honest streaming signal, with
--      usable following the STREAMING result for openai-format models.
--
--   §3 (FIX 3 — parked failures must not hold the pause open; Michael's
--      ratify pending). reflect_guard_signals counted autonomous
--      awaiting_review items toward in_flight. Since v31 parks tick-errored
--      failures INTO awaiting_review, a park wave inflated in_flight and
--      could trip the runaway guard (in_flight >= max) — holding the
--      autonomy pause open on work that is, by definition, waiting on a
--      human. Now only in_progress counts. reflect_watchman_tick and
--      reflect_status both read this one function, so the fix reaches every
--      consumer.
--
-- requires create_v31_steward_park. CORE re-authoring CORE (later file
-- wins), not an overlay touching core — clobber-check safe.
-- =====================================================================


-- =====================================================================
-- §1 — FIX 1: overrides are honored, not silently substituted.
-- =====================================================================
-- Re-authors the v08 (31-model-aliases) dispatch FINAL verbatim EXCEPT for
-- the override-honesty guard at the M.2 substitution gate. The 4-layer
-- resolution, alias path, file_private guard rail, J.11 spend-cap gate, and
-- R.3 max_tokens / tools_disabled knobs are unchanged. Two surgical edits:
--   (a) v_model_from_override tracks whether the concrete literal model came
--       from work_items.model_override (an alias override is NOT flagged —
--       an alias asks for "the best usable member" by design, and
--       pick_alias_member already validates usability / raises).
--   (b) at M.2, an unusable model that came from the item override is
--       REFUSED (clear error naming the override) instead of substituted.
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

    UPDATE stewards.work_items
       SET status      = 'in_progress',
           session_ids = session_ids || v_session_id,
           updated_at  = now()
     WHERE id = p_work_item_id;

    RETURN v_work_id;
END;
$function$;

COMMENT ON FUNCTION stewards.work_item_dispatch_stage(uuid, text, boolean) IS
'Dispatch FINAL (v32 override-honesty + J.8.a + 31 aliases + M.2 + J.11 + R.3): 4-layer resolution where the requested model may be a logical alias; a file_private guard rail; then M.2 capability substitution — EXCEPT a model that came from work_items.model_override is now REFUSED (clear error naming the override) rather than silently substituted, so a pinned model is honored or the dispatch fails loudly (v32 FIX 1). Stage / pipeline / alias-resolved models substitute exactly as v08. Then the J.11 spend-cap gate and R.3 max_tokens + input-scoped tools_disabled.';

-- Re-author the _safe wrapper (v27/107) so the new "unusable override" refusal
-- PARKS the item at awaiting_review (rings needs_attention's review bucket)
-- instead of hard-raising on the autonomous path — the same treatment the
-- "nothing configured" shapes already get. The unwrapped function still RAISES
-- for manual/UI callers. Everything else is byte-identical to v27.
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
           OR SQLERRM LIKE '%override names an unusable model%'
        THEN
            SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
            UPDATE stewards.work_items
               SET status     = 'awaiting_review',
                   error      = left(
                       CASE WHEN SQLERRM LIKE '%override names an unusable model%'
                            THEN 'pinned model unusable for stage ' || COALESCE(v_wi.current_stage, '?')
                                 || ' of pipeline ' || COALESCE(v_wi.pipeline_family, '?')
                                 || ' — clear work_items.model_override or pin a usable model. (' || SQLERRM || ')'
                            ELSE 'no model configured for stage ' || COALESCE(v_wi.current_stage, '?')
                                 || ' of pipeline ' || COALESCE(v_wi.pipeline_family, '?')
                                 || ' — open Settings -> Providers & Models to assign one. (' || SQLERRM || ')'
                       END,
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
'107 + v32: wraps work_item_dispatch_stage. On the "nothing configured" exception shapes (could not resolve model/provider, alias has no usable member, no usable capability substitute) AND the v32 "override names an unusable model" refusal, parks the work_item at awaiting_review with a clear error (lands in needs_attention''s review bucket) and returns NULL instead of raising. Every other exception re-raises unchanged. Swapped in at call sites that previously called work_item_dispatch_stage() UNWRAPPED.';


-- =====================================================================
-- §2 — FIX 2: probes exercise the streaming path they claim (#359).
-- =====================================================================
-- Re-authors enqueue_model_probe (v06/M.4) verbatim EXCEPT the body now
-- declares stream:true + stream_options.include_usage — the SAME shape a
-- real dispatch body carries (bgworker chat() adds these to every dispatch;
-- the probe now carries them in the stored row too, so it is honest about
-- the path it runs and drift-proof against any body-respecting executor).
-- max_tokens dropped 400 -> 128 (the probe only needs to confirm the stream
-- yields content / a tool call, or trips a streaming-path rejection early).
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

    -- #item2 (2026-07-05): a REALISTIC, tool-bearing probe. The old body stripped
    -- tools and asked for a 2-char echo — so kimi-k2.7-code "passed" on ~2 chars
    -- while REAL requests 400 ("Console Go: Upstream request failed"; "When using
    -- tool_choice, tools must be set"). This body asks for a short prose reply AND
    -- ships a tool + tool_choice, exercising the exact path a real agent request
    -- uses. The tool is deliberately IRRELEVANT to the question, so a healthy
    -- model answers in prose (no tool call → no continuation) while a model whose
    -- gateway trips on tool schemas 400s → recorded unusable. tools_disabled=false
    -- so the bgworker forwards body.tools instead of stripping them.
    -- v32 (#359): stream:true + stream_options.include_usage so the probe runs
    -- the SAME streaming path a real dispatch does — a model whose streaming path
    -- a provider rejects (SSE error / streams empty) now FAILS the probe instead
    -- of false-passing a non-streaming completion and re-poisoning routing.
    v_payload := jsonb_build_object(
        'session_id',      v_session,
        'agent_family',    'model-probe',
        'requested_model', p_model,
        'tools_disabled',  false,
        'body', jsonb_build_object(
            'model',         p_model,
            'max_tokens',    128,
            'temperature',   0,
            'stream',        true,
            'stream_options', jsonb_build_object('include_usage', true),
            'messages',    jsonb_build_array(
                jsonb_build_object('role', 'system',
                    'content', 'You are a model dispatchability probe. Answer briefly and directly.'),
                jsonb_build_object('role', 'user',
                    'content', 'In 1-2 sentences, state which model you are and one task you are good at. A weather tool is offered but is NOT relevant to this question — just answer in prose.')
            ),
            'tools', jsonb_build_array(
                jsonb_build_object(
                    'type', 'function',
                    'function', jsonb_build_object(
                        'name', 'get_current_weather',
                        'description', 'Get the current weather for a location. Offered only to exercise the tool-call path; not relevant to the probe question.',
                        'parameters', jsonb_build_object(
                            'type', 'object',
                            'properties', jsonb_build_object(
                                'location', jsonb_build_object('type', 'string', 'description', 'City name')),
                            'required', jsonb_build_array('location'))))),
            'tool_choice', 'auto'
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
'M.4 (#item2 + v32/#359): enqueue a REALISTIC, tool-bearing, STREAMING chat (short prose prompt + a tool + tool_choice + stream:true/stream_options) to test whether (provider, model) is dispatchable on the exact streaming path real agent requests use — not a 2-char echo and not a non-streaming completion that false-passes a model whose streaming path a provider rejects. Direct work_queue insert (bypasses the M.2 substitution gate); the model-probe agent (steps=0) caps it at one call. The terminal-transition trigger records the streaming verdict into model_capability (usable + supports_streaming).';

-- Re-author the resolve trigger (v06/M.4) so supports_streaming is recorded
-- as an HONEST streaming signal (the probe now streams), and usable follows
-- the STREAMING result for openai-format models. api_format is read from the
-- probe payload (stamped by the work_queue BEFORE INSERT trigger) or the
-- capability row, defaulting to 'openai'.
CREATE OR REPLACE FUNCTION stewards.trigger_resolve_model_probe()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_provider   text;
    v_model      text;
    v_session    text;
    v_content    text;
    v_finish     text;
    v_tool_calls jsonb;
    v_has_tools  boolean;
    v_usable     boolean;
    v_detail     text;
    v_api_format text;
    v_stream_ok  boolean;
BEGIN
    v_provider := NEW.payload -> '_probe' ->> 'provider';
    v_model    := NEW.payload -> '_probe' ->> 'model';
    v_session  := NEW.payload ->> 'session_id';

    -- v32 (#359): which gateway shape this probe ran. The probe body declares
    -- stream:true for every format; openai-format is the path the "Console Go
    -- waves" rejection lives on, so its usable verdict is the streaming verdict.
    v_api_format := COALESCE(
        NEW.payload ->> 'api_format',
        (SELECT api_format FROM stewards.model_capability
          WHERE provider = v_provider AND model = v_model),
        'openai');

    IF NEW.status = 'error' THEN
        -- #item2 + v32: a tool-bearing STREAMING request that 400s/5xxs, or whose
        -- SSE stream carries an error event (the "may not exist / no access"
        -- rejection), lands here — the probe's whole point is to make the
        -- streaming-path failure visible. Streaming did NOT work.
        v_usable    := false;
        v_stream_ok := false;
        v_detail := 'auto-probe (streaming): dispatch error: '
                    || left(COALESCE(NEW.error, '(no error text)'), 240);
    ELSE
        -- done: did the tool-bearing STREAMING request produce a usable response?
        -- Read the last assistant message. Success = real prose content OR a valid
        -- tool call (auto tool_choice yields empty content + a tool_calls array,
        -- still a dispatchable streamed response). A bare/empty reply fails the
        -- content floor and, absent a tool call, is marked unusable.
        SELECT content, finish_reason, tool_calls
          INTO v_content, v_finish, v_tool_calls
          FROM stewards.messages
         WHERE session_id = v_session AND role = 'assistant'
         ORDER BY id DESC LIMIT 1;

        v_has_tools := v_tool_calls IS NOT NULL
                       AND jsonb_typeof(v_tool_calls) = 'array'
                       AND jsonb_array_length(v_tool_calls) > 0;

        -- The streaming path produced a usable response.
        v_stream_ok := length(trim(COALESCE(v_content, ''))) >= 16 OR v_has_tools;
        v_usable    := v_stream_ok;
        IF v_usable THEN
            v_detail := format('auto-probe (streaming): ok — %s content chars%s, finish=%s',
                               length(COALESCE(v_content, '')),
                               CASE WHEN v_has_tools
                                    THEN format(' + %s tool_call(s)', jsonb_array_length(v_tool_calls))
                                    ELSE '' END,
                               COALESCE(v_finish, '(null)'));
        ELSE
            v_detail := format('auto-probe (streaming): no usable output (%s content chars, no tool_calls), finish=%s',
                               length(COALESCE(v_content, '')), COALESCE(v_finish, '(null)'));
        END IF;
    END IF;

    -- v32: supports_streaming is now a first-class, honestly-measured signal —
    -- the outcome of a stream:true probe — recorded alongside usable. For
    -- openai-format models usable IS the streaming verdict (a model that only
    -- works non-streaming is not dispatchable, because dispatch always streams).
    INSERT INTO stewards.model_capability
        (provider, model, usable, supports_streaming, last_probed_at, probe_detail, probed_via)
    VALUES
        (v_provider, v_model, v_usable, v_stream_ok, now(), v_detail, 'auto-probe')
    ON CONFLICT (provider, model) DO UPDATE
    SET usable             = EXCLUDED.usable,
        supports_streaming = EXCLUDED.supports_streaming,
        last_probed_at     = now(),
        probe_detail       = EXCLUDED.probe_detail,
        probed_via         = 'auto-probe',
        updated_at         = now();

    RAISE NOTICE 'auto-probe verdict (% streaming): %/% usable=% supports_streaming=% (%)',
        v_api_format, v_provider, v_model, v_usable, v_stream_ok, v_detail;

    RETURN NEW;
END;
$FN$;

COMMENT ON FUNCTION stewards.trigger_resolve_model_probe() IS
'M.4 (#item2 + v32/#359): on a probe work_queue row reaching done/error, records the STREAMING verdict into model_capability. The probe body declares stream:true, so error (incl. an SSE error event / streaming-empty) -> usable=false, supports_streaming=false; done with real prose (>=16 chars) OR a valid tool_call over the stream -> usable=true, supports_streaming=true. For openai-format models usable IS the streaming verdict (dispatch always streams). probed_via=auto-probe.';


-- =====================================================================
-- (§3 — FIX 3: reflect_guard_signals in_flight fix — appended in its own
--  commit; Michael's ratify pending. See the PR body.)
-- =====================================================================

-- =====================================================================
-- End of v32-dispatch-honesty.sql
-- =====================================================================
