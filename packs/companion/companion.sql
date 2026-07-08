-- =====================================================================
-- packs/companion/companion.sql — durable voice-side organs
-- =====================================================================
-- Born from the first real morning (2026-07-08): the seat was asked for a
-- water reminder and reached for its HARNESS schedulers (ScheduleWakeup /
-- CronCreate) — real tools whose lifetime is the per-turn container, which
-- is destroyed after every reply. The reminder died with it, silently.
-- Durable means: reminders are ROWS; delivery is the voice front's poller
-- (the only thing with a mouth). Apply AFTER forge.sql.

CREATE SCHEMA IF NOT EXISTS companion;
COMMENT ON SCHEMA companion IS
'companion pack: the voice companion''s durable organs — reminders, the bell surface, verbal approval.';

-- ── reminders: durable rows, delivered by the voice front ───────────────
CREATE TABLE IF NOT EXISTS companion.reminders (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    remind_at    timestamptz NOT NULL,
    message      text NOT NULL,
    status       text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','delivered','cancelled')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text NOT NULL DEFAULT 'companion',
    delivered_at timestamptz
);
CREATE INDEX IF NOT EXISTS reminders_due_idx
    ON companion.reminders (remind_at) WHERE status = 'pending';
COMMENT ON TABLE companion.reminders IS
'companion pack: durable reminders. Set by the seat (reminder_set), DELIVERED by the voice front''s poller (Spin injects a spoken turn when one is due) — the substrate holds the row, the front holds the mouth.';

CREATE OR REPLACE FUNCTION companion.reminder_set(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_msg  text := btrim(coalesce(p_args->>'message',''));
    v_at   timestamptz;
    v_mins numeric;
    v_id   bigint;
BEGIN
    IF v_msg = '' THEN RETURN jsonb_build_object('error','message required'); END IF;
    IF p_args ? 'minutes_from_now' THEN
        BEGIN v_mins := (p_args->>'minutes_from_now')::numeric;
        EXCEPTION WHEN others THEN RETURN jsonb_build_object('error','minutes_from_now must be a number'); END;
        IF v_mins <= 0 OR v_mins > 60*24*30 THEN RETURN jsonb_build_object('error','minutes_from_now must be between 0 and 43200 (30 days)'); END IF;
        v_at := now() + make_interval(mins => v_mins::int, secs => ((v_mins - floor(v_mins))*60)::int);
    ELSIF p_args ? 'at' THEN
        BEGIN v_at := (p_args->>'at')::timestamptz;
        EXCEPTION WHEN others THEN RETURN jsonb_build_object('error','at must be a timestamp (ISO, with timezone if not UTC)'); END;
        IF v_at <= now() THEN RETURN jsonb_build_object('error','that time is already past (server now: ' || now()::text || ')'); END IF;
    ELSE
        RETURN jsonb_build_object('error','give minutes_from_now (number) or at (timestamp)');
    END IF;
    INSERT INTO companion.reminders (remind_at, message, created_by)
    VALUES (v_at, v_msg, coalesce(p_args->>'_session_id','companion'))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'remind_at', v_at,
        'in_minutes', round(extract(epoch FROM v_at - now())/60, 1),
        'note', 'durable — survives every session; the voice front delivers it aloud when due (if no voice client is connected at that moment, it is spoken on the next connect)');
END;
$fn$;

CREATE OR REPLACE FUNCTION companion.reminder_list(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT jsonb_build_object('count', count(*), 'reminders',
        coalesce(jsonb_agg(jsonb_build_object('id', id, 'remind_at', remind_at,
            'in_minutes', round(extract(epoch FROM remind_at - now())/60, 1),
            'message', message) ORDER BY remind_at), '[]'::jsonb))
      FROM companion.reminders WHERE status = 'pending';
$fn$;

CREATE OR REPLACE FUNCTION companion.reminder_cancel(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_id bigint; v_n int;
BEGIN
    BEGIN v_id := (p_args->>'id')::bigint;
    EXCEPTION WHEN others THEN RETURN jsonb_build_object('error','id (number) required — reminder_list shows them'); END;
    UPDATE companion.reminders SET status='cancelled' WHERE id = v_id AND status='pending';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RETURN jsonb_build_object('error','no pending reminder with id ' || v_id); END IF;
    RETURN jsonb_build_object('ok', true, 'cancelled', v_id);
END;
$fn$;

-- The poller's claim: atomically take due reminders (so two pollers can't
-- both speak the same one). The voice front calls this directly over SQL.
CREATE OR REPLACE FUNCTION companion.reminders_claim_due()
RETURNS TABLE (id bigint, message text, remind_at timestamptz)
LANGUAGE sql AS $fn$
    UPDATE companion.reminders r
       SET status='delivered', delivered_at=now()
     WHERE r.status='pending' AND r.remind_at <= now()
    RETURNING r.id, r.message, r.remind_at;
$fn$;

-- ── the bell, hearable: list + VERBAL approval ──────────────────────────
CREATE OR REPLACE FUNCTION companion.companion_bell(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT jsonb_build_object('count', count(*), 'items',
        coalesce(jsonb_agg(jsonb_build_object(
            'source_kind', a.source_kind, 'title', a.title,
            'question', left(a.question, 500), 'work_item_id', a.work_item_id,
            'since', a.created_at) ORDER BY a.created_at), '[]'::jsonb))
      FROM stewards.needs_attention a;
$fn$;
COMMENT ON FUNCTION companion.companion_bell(jsonb) IS
'companion pack: the needs_attention bell as a spoken-friendly list. For forge plans, read the item''s question (it contains the plan) — summarize the TOOL and RISKS sections aloud before any approval.';

CREATE OR REPLACE FUNCTION companion.companion_approve(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi  uuid;
    v_wq  bigint;
    v_st  text;
BEGIN
    BEGIN v_wi := (p_args->>'work_item_id')::uuid;
    EXCEPTION WHEN others THEN RETURN jsonb_build_object('error','work_item_id (uuid) required — companion_bell lists them'); END;
    SELECT status INTO v_st FROM stewards.work_items WHERE id = v_wi;
    IF v_st IS NULL THEN RETURN jsonb_build_object('error','no such work item'); END IF;
    IF v_st <> 'awaiting_review' THEN
        RETURN jsonb_build_object('error','item is ' || v_st || ', not awaiting_review — nothing to approve');
    END IF;
    v_wq := stewards.work_item_dispatch_stage_safe(v_wi, NULL, false);
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_wi, 'resumed', v_wq IS NOT NULL,
        'note', 'approved and resumed. VERBAL-GATE PROTOCOL: this tool must only ever be called after the plan/question was read aloud and the human explicitly said to approve.');
END;
$fn$;
COMMENT ON FUNCTION companion.companion_approve(jsonb) IS
'companion pack: resume an awaiting_review item — the VERBAL approval (ratified 2026-07-08: "gated here or verbally"). The gate is procedural: the seat must read the plan aloud and receive an explicit spoken yes before calling this. Never lifts anything except awaiting_review.';

-- ── register the tools ──────────────────────────────────────────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
( 'reminder_set',
  'Set a DURABLE reminder (survives every session; a row in the substrate). The voice front speaks it when due. Give minutes_from_now (number) or at (ISO timestamp with timezone). NEVER use harness schedulers (ScheduleWakeup/CronCreate) for reminders — those die with the per-turn session.',
  '{"type":"object","required":["message"],"properties":{"message":{"type":"string"},"minutes_from_now":{"type":"number"},"at":{"type":"string","description":"ISO timestamp; include the timezone offset"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"reminder_set"}'::jsonb, 'write_local', true ),
( 'reminder_list', 'List pending reminders with minutes remaining.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"reminder_list"}'::jsonb, 'read', true ),
( 'reminder_cancel', 'Cancel a pending reminder by id (reminder_list shows ids).',
  '{"type":"object","required":["id"],"properties":{"id":{"type":"number"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"reminder_cancel"}'::jsonb, 'write_local', true ),
( 'companion_bell', 'List everything waiting on the human''s answer (the needs_attention bell) in a spoken-friendly shape — forge plans, paused stages, questions.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"companion_bell"}'::jsonb, 'read', true ),
( 'companion_approve',
  'VERBAL approval: resume ONE awaiting_review item (e.g. an approved forge plan). Protocol is absolute: first read the item''s plan/question aloud (for forge plans: the TOOL and RISKS sections and that the SQL is as planned), then call this ONLY after the human explicitly says to approve. Refusable, auditable, never bulk.',
  '{"type":"object","required":["work_item_id"],"properties":{"work_item_id":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"companion_approve"}'::jsonb, 'write_local', true )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, effect_class = EXCLUDED.effect_class, active = true;

-- ── the Arc-C dynamic-write allowlist (substrate_tool's wall) ───────────
-- Read-class sql_fn tools dispatch freely from harness seats; ONLY these
-- write-class names may be dispatched there. forge_register is absent on
-- purpose — the forge is approved on the bell (companion_approve IS the
-- voice path to that same bell), and the registrar runs inside the
-- pipeline. Operators extend this list deliberately, one name at a time.
SELECT stewards.config_set('arc_c_dynamic_write_allowlist',
        '["reminder_set","reminder_cancel","companion_approve"]'::jsonb,
        'companion pack: write-class sql_fn tools dispatchable via substrate_tool from harness seats (Arc-C). The gate for everything else stays the bell.');

-- moon_phase (forged last night as write_local by the registrar's old
-- default) is pure math — correct its class so seats can call it freely.
UPDATE stewards.tool_defs SET effect_class = 'read'
 WHERE name = 'moon_phase' AND execute_target->>'schema' = 'forge';
