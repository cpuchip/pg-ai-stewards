-- =====================================================================
-- v73: defaults an instance should not have to override.
-- =====================================================================
-- Four places where a second instance (stuffleupagus, on lepton) had to re-author core or seed rows by hand
-- before the core behaved; each is now a setting with today's behaviour as its default, except the
-- watchman, which a fresh install now starts with off.
--
-- §1 role_default. The core's five roles (reason, review, critic, ingest, vision) resolve through
--    model_aliases; an instance whose providers come from the environment never seeds them, and the
--    dashboard chat then sent the role's NAME to the default provider as a model id ("model reason not
--    found"). config role_default {"provider", "model"} is the member pick_alias_member returns for a core
--    role when no alias member qualifies (and it passes the same usable / cap / no-train / exclude checks).
--    Unset, nothing changes, except that dispatch_chat_turn now refuses an unmapped core role by name.
-- §2 watchman off on a fresh install. watchman_config.schedule_enabled defaulted true, so a new instance
--    ran a memory-consolidation pass at startup (on stuffleupagus it errored, and a consolidator is a
--    write path around review). The default is now false, and the row is turned off only where no pass has
--    ever run, once (config marker v73_watchman_default). An instance that runs its watchman is untouched.
--    The schedule gated only the pass: guards, scheduled pipelines and the reflect drain still tick. The one
--    thing the pass did for a fresh install, the model-unconfigured bell, now rings without it
--    (ring_model_unconfigured, from watchman_scheduler_fire, once a day at most).
-- §3 accepts_temperature. Claude 5.5 models refuse a temperature (HTTP 400 "`temperature` is deprecated
--    for this model"). A family moved to such a model kept its agents' temperatures and failed every call.
--    model_capability.accepts_temperature (default true) marks a model that refuses one; a chat for it
--    leaves the queue without body.temperature, whatever the agent says. Per model, not per provider.
-- §4 chat_default_family. chat_agent_family's fallback for a session with no family was hardcoded to
--    work-item-chat; config chat_default_family overrides it (stuffleupagus routes its operator chat so).
--
-- Oracle: virgin-smoke OK 140. Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — role_default
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.core_roles()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
    SELECT ARRAY['reason', 'review', 'critic', 'ingest', 'vision']
$$;

COMMENT ON FUNCTION stewards.core_roles() IS
'v73: the model roles the core itself dispatches by (dispatch_chat_turn, stages, the judge and critic paths). role_default answers for these only.';

CREATE OR REPLACE FUNCTION stewards.role_default()
RETURNS TABLE (provider text, model text)
LANGUAGE sql STABLE AS $$
    SELECT d ->> 'provider', d ->> 'model'
      FROM (SELECT stewards.config_get('role_default') AS d) c
     WHERE jsonb_typeof(d) = 'object'
       AND coalesce(d ->> 'provider', '') <> ''
       AND coalesce(d ->> 'model', '') <> ''
$$;

COMMENT ON FUNCTION stewards.role_default() IS
'v73: config role_default as (provider, model), or no row when it is unset or malformed.';

CREATE OR REPLACE FUNCTION stewards.pick_alias_member(
    p_alias           text,
    p_forbid_training boolean DEFAULT false,
    p_exclude         jsonb   DEFAULT '[]'::jsonb
)
RETURNS TABLE (provider text, model text)
LANGUAGE sql AS $$
    WITH member AS (
        SELECT a.provider, a.provider_model AS model
          FROM stewards.model_aliases a
         WHERE a.alias = p_alias
           AND a.enabled
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
         LIMIT 1
    )
    SELECT provider, model FROM member
    UNION ALL
    -- v73: a core role with no member that qualifies takes role_default, under the same checks
    SELECT r.provider, r.model
      FROM stewards.role_default() r
     WHERE NOT EXISTS (SELECT 1 FROM member)
       AND p_alias = ANY (stewards.core_roles())
       AND stewards.model_usable(r.provider, r.model)
       AND NOT stewards.provider_cap_exceeded(r.provider)
       AND (NOT p_forbid_training OR NOT stewards.model_trains_on_data(r.provider, r.model))
       AND NOT (p_exclude @> jsonb_build_array(jsonb_build_object('provider', r.provider, 'model', r.model)));
$$;

COMMENT ON FUNCTION stewards.pick_alias_member(text, boolean, jsonb) IS
'31/32/95: resolve a model alias to its best concrete (provider, model) — lowest priority that is ENABLED + configured (when the registry is populated) + usable + under spend cap + (when p_forbid_training) no-train + NOT in p_exclude (a jsonb array of {provider, model} already tried this attempt). No rows if none qualify. Both work_item_dispatch_stage (31) and steward_tick''s alias failover (32) resolve through this one function, so a disabled member is skipped at dispatch time AND at runtime failover. v73: for a core role (core_roles) with no qualifying member, config role_default under the same checks (not the registry filter: role_default is the operator naming a provider it has).';

-- dispatch_chat_turn (47's 6-argument form; the 5-argument one was dropped later in the chain): v10's body
-- verbatim, plus the refusal of an unmapped core role.


CREATE OR REPLACE FUNCTION stewards.dispatch_chat_turn(
    p_session_id    text,
    p_user_input    text,
    p_agent_family  text  DEFAULT 'work-item-chat',
    p_model_alias   text  DEFAULT 'reason',
    p_grounding     text  DEFAULT NULL,
    p_content_parts jsonb DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $FN$
DECLARE
    v_provider text;
    v_model    text;
    v_have     int;
    v_alias    text;
    v_has_media boolean;
    v_parts    jsonb;
BEGIN
    -- ensure the persistent chat session exists (kind='chat')
    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (p_session_id, 'stewdio chat ' || left(p_session_id, 40), 'chat')
    ON CONFLICT (id) DO NOTHING;

    -- on the first turn, seed the grounding (which work item/doc + how to ground).
    -- A user-role context row (kept simple so compose_messages doesn't relabel a
    -- mid-history system row); subsequent turns inherit it from history.
    SELECT count(*) INTO v_have FROM stewards.messages WHERE session_id = p_session_id;
    IF v_have = 0 AND p_grounding IS NOT NULL AND length(btrim(p_grounding)) > 0 THEN
        INSERT INTO stewards.messages (session_id, role, content)
        VALUES (p_session_id, 'user', p_grounding);
    END IF;

    v_has_media := (p_content_parts IS NOT NULL
                    AND jsonb_typeof(p_content_parts) = 'array'
                    AND jsonb_array_length(p_content_parts) > 0);

    -- 47: when media is attached, auto-select the `vision` alias (decision #2).
    v_alias := CASE WHEN v_has_media THEN 'vision' ELSE p_model_alias END;

    -- resolve the alias → concrete (provider, model). If the `vision` alias isn't
    -- seeded, fall back to the requested alias (e.g. reason); then to a literal
    -- model id + the catalog default provider (a virgin core with no aliases).
    SELECT m.provider, m.model INTO v_provider, v_model
      FROM stewards.pick_alias_member(v_alias, false) m;
    IF v_model IS NULL AND v_alias <> p_model_alias THEN
        SELECT m.provider, m.model INTO v_provider, v_model
          FROM stewards.pick_alias_member(p_model_alias, false) m;
    END IF;
    IF v_model IS NULL THEN
        -- v73: a core role with no member and no role_default fails here, by name, instead of sending the
        -- role's name to a provider as if it were a model id
        IF p_model_alias = ANY (stewards.core_roles()) THEN
            RAISE EXCEPTION 'role % has no model: add a model_aliases row or set role_default', p_model_alias
                USING HINT = 'SELECT stewards.config_set(''role_default'', ''{"provider": "<provider>", "model": "<model>"}'')';
        END IF;
        v_model    := p_model_alias;
        v_provider := stewards.catalog_default_provider();
    END IF;

    IF v_has_media THEN
        -- multimodal turn: insert the user message as a content ARRAY (a text part
        -- + the media parts) and enqueue via chat_post_internal. content (text) is
        -- set as a fallback for pressure/history-text. The user turn is already in
        -- history, so do NOT also append a plain-text user row via chat_enqueue.
        v_parts := jsonb_build_array(jsonb_build_object('type', 'text', 'text', coalesce(p_user_input, '')))
                   || p_content_parts;
        INSERT INTO stewards.messages (session_id, role, content, content_parts, model)
        VALUES (p_session_id, 'user', coalesce(p_user_input, ''), v_parts, v_model);
        RETURN stewards.chat_post_internal(p_agent_family, v_model, p_session_id, v_provider);
    END IF;

    -- text-only turn: unchanged — append the user turn + enqueue (full tool loop).
    RETURN stewards.chat_enqueue(p_agent_family, v_model, p_session_id, p_user_input, v_provider);
END
$FN$;

-- ---------------------------------------------------------------------
-- §2 — the watchman starts off on a fresh install
-- ---------------------------------------------------------------------
ALTER TABLE stewards.watchman_config ALTER COLUMN schedule_enabled SET DEFAULT false;

-- once per install (config marker v73_watchman_default): off where no pass has ever run; true when it turned it off
CREATE OR REPLACE FUNCTION stewards.watchman_default_off()
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
    v_n int;
BEGIN
    IF stewards.config_get('v73_watchman_default') IS NOT NULL THEN
        RETURN false;
    END IF;
    UPDATE stewards.watchman_config SET schedule_enabled = false
     WHERE schedule_enabled AND NOT EXISTS (SELECT 1 FROM stewards.watchman_passes);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM stewards.config_set('v73_watchman_default', to_jsonb(v_n > 0),
        'v73: whether this install''s watchman schedule was turned off (true: it had never run a pass). Applied once.');
    IF v_n > 0 THEN
        RAISE NOTICE 'v73: the watchman schedule is now off: this instance has never run a pass. Turn it on with UPDATE stewards.watchman_config SET schedule_enabled = true.';
    ELSE
        RAISE NOTICE 'v73: the watchman schedule is left as it was (it has run a pass, or was already off).';
    END IF;
    RETURN v_n > 0;
END;
$fn$;

COMMENT ON FUNCTION stewards.watchman_default_off() IS
'v73: turns the watchman schedule off on an install that has never run a pass, once (config v73_watchman_default records that it ran and what it did). A running watchman is never touched.';


-- the lifeless-core bell (v27's watchman_pass_start), without a pass: when neither the watchman's own defaults nor
-- the substrate default name a provider and model. Once a day at most: a pending bell, or one rung in the last day
-- and answered, holds it.
CREATE OR REPLACE FUNCTION stewards.ring_model_unconfigured()
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
    v_cfg      stewards.watchman_config%ROWTYPE;
    v_provider text;
    v_model    text;
BEGIN
    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;
    v_provider := coalesce(v_cfg.default_provider, stewards.catalog_default_provider());
    v_model    := coalesce(v_cfg.default_model, stewards.catalog_default_model(v_provider));
    IF v_provider IS NOT NULL AND v_model IS NOT NULL THEN
        RETURN false;
    END IF;
    IF EXISTS (SELECT 1 FROM stewards.hinge_reviews
                WHERE kind = 'model-unconfigured' AND subject = 'watchman'
                  AND (status = 'pending' OR created_at > now() - interval '1 day')) THEN
        RETURN false;
    END IF;
    PERFORM stewards.hinge_enqueue('model-unconfigured', 'watchman',
        jsonb_build_object('note',
            'no provider/model configured (watchman_config defaults + the substrate default are both unset) — open the Models wizard.'),
        'watchman_scheduler_fire');
    RETURN true;
END;
$fn$;

COMMENT ON FUNCTION stewards.ring_model_unconfigured() IS
'v73: rings the model-unconfigured hinge bell that watchman_pass_start rings on a lifeless install, for an install whose watchman schedule is off (so no pass starts). At most once a day.';

-- watchman_scheduler_fire: v07's final (28: the guard auto-resume) verbatim, plus the bell when the schedule is off.
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_fire()
RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_reason          text;
    v_cfg             stewards.watchman_config%ROWTYPE;
    v_pass_id         text;
    v_pipelines_fired int;
    v_drained         int;
    v_guard_breach    text;
    v_autoresume      text;
BEGIN
    -- 23: self-presiding guard FIRST — auto-pause on runaway before any new work.
    BEGIN
        v_guard_breach := stewards.reflect_watchman_tick();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_watchman_tick raised: %', SQLERRM;
    END;

    -- 28: narrow auto-resume — lift a guard spend/in_flight pause once it self-clears.
    BEGIN
        v_autoresume := stewards.reflect_guard_autoresume_tick();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_guard_autoresume_tick raised: %', SQLERRM;
    END;

    BEGIN
        v_pipelines_fired := stewards.scheduled_pipelines_fire();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: scheduled_pipelines_fire raised: %', SQLERRM;
    END;

    -- 22: drain the reflect-steward approval queue (capacity-gated, pause-aware).
    BEGIN
        v_drained := stewards.reflect_drain_approved();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_drain_approved raised: %', SQLERRM;
    END;

    v_reason := stewards.watchman_should_fire();
    IF v_reason IS NULL THEN
        -- v73: with the schedule off (a fresh install's default now) the pass that rang the lifeless-core bell
        -- never starts; ring it here instead, so a person still learns that no model is set up
        IF NOT coalesce((SELECT schedule_enabled FROM stewards.watchman_config WHERE id = 1), false) THEN
            PERFORM stewards.ring_model_unconfigured();
        END IF;
        RETURN NULL;
    END IF;

    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;

    v_pass_id := stewards.watchman_pass_start(
        p_limit => v_cfg.schedule_pass_limit, p_provider => NULL, p_model => NULL,
        p_agent_family => NULL, p_actor => 'scheduler', p_trigger => v_reason, p_token_budget => NULL);

    RAISE NOTICE 'watchman scheduler fired (%): pass_id=%', v_reason, v_pass_id;
    RETURN v_pass_id;
END;
$func$;

SELECT stewards.watchman_default_off();

-- ---------------------------------------------------------------------
-- §3 — a model that refuses a temperature never gets one
-- ---------------------------------------------------------------------
ALTER TABLE stewards.model_capability ADD COLUMN IF NOT EXISTS accepts_temperature boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN stewards.model_capability.accepts_temperature IS
'v73: false for a model that refuses a temperature (Claude 5.5: HTTP 400 "`temperature` is deprecated for this model"). A chat queued for it loses body.temperature (trigger work_queue_zy_drop_refused_temperature).';

CREATE OR REPLACE FUNCTION stewards.trigger_drop_refused_temperature()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF jsonb_typeof(NEW.payload -> 'body') IS DISTINCT FROM 'object' OR NOT (NEW.payload -> 'body' ? 'temperature') THEN
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM stewards.model_capability c
                WHERE c.provider = NEW.provider
                  AND c.model = coalesce(NEW.payload ->> 'requested_model', NEW.payload #>> '{body,model}')
                  AND NOT c.accepts_temperature) THEN
        NEW.payload := NEW.payload #- '{body,temperature}';
    END IF;
    RETURN NEW;
END;
$fn$;

-- named to run after the reroute triggers (BEFORE triggers fire in name order) and before zz_route_batch
DROP TRIGGER IF EXISTS work_queue_zy_drop_refused_temperature ON stewards.work_queue;
CREATE TRIGGER work_queue_zy_drop_refused_temperature
BEFORE INSERT ON stewards.work_queue
FOR EACH ROW
WHEN (NEW.kind = 'chat')
EXECUTE FUNCTION stewards.trigger_drop_refused_temperature();

COMMENT ON FUNCTION stewards.trigger_drop_refused_temperature() IS
'v73: BEFORE INSERT on chat work_queue rows. Removes body.temperature when model_capability marks (provider, model) accepts_temperature = false. Every other chat is untouched.';

-- ---------------------------------------------------------------------
-- §4 — the dashboard chat's fallback family is a setting
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.chat_agent_family(p_session text)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(
        (SELECT agent_family FROM stewards.sessions WHERE id = p_session),
        nullif(stewards.config_get_text('chat_default_family'), ''),
        'work-item-chat');
$fn$;

COMMENT ON FUNCTION stewards.chat_agent_family(text) IS
'86: resolve the agent family for a CHAT dispatch (named chat_* to avoid 15b''s
session_agent_family, which resolves a PIPELINE stage''s family — different semantics) — the session''s recorded family, else
the work-item-chat default. The Go chat handlers pass this instead of a hardcoded
family, so a specialized session (85 loremaster) STAYS its agent on follow-ups. v73: config chat_default_family, when set, replaces work-item-chat as the fallback.';
