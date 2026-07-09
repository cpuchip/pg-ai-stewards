\echo Use "CREATE EXTENSION stewards_companion" to load this file. \quit
-- >>> from packs/companion/forge.sql
-- =====================================================================
-- packs/companion/forge.sql — the FORGE: Hinge-gated self-extension
-- =====================================================================
--
-- A PACK, not core (apply by choice, like the examples; remove with
-- uninstall.sql). The substrate stays lifeless; this teaches an installed
-- instance to GROW NEW TOOLS — with a human approval between the wish and
-- the wire, always.
--
-- Provenance: the plan→approve→codegen→verify→register loop is the good
-- idea in Ada-SI (github.com/nazirlouis/Ada-SI, MIT) — rebuilt on the
-- substrate's own organs: the plan lands on the EXISTING approval bell
-- (auto_advance=false → awaiting_review → needs_attention 'review'
-- bucket), and Ada's throwaway-venv verify becomes a Postgres
-- TRANSACTION: forge_register applies the approved SQL, runs the plan's
-- own test call, and registers the tool_defs row atomically — a failing
-- test rolls ALL of it back.
--
-- The trust model, stated plainly: the human approves the EXACT SQL that
-- will run (it is in the plan on the bell — nothing else is executed).
-- forge_register additionally enforces STRUCTURE (a single CREATE OR
-- REPLACE FUNCTION in the `forge` schema, jsonb->jsonb signature), but
-- structure checks are a seatbelt, not the wall: THE APPROVAL IS THE
-- WALL. Forged functions run as the extension owner — do not approve SQL
-- you have not read. (The composable policy layer, D3C, will widen what
-- can skip the bell; until then everything stops there.)
--
-- Pipeline: forge = plan (LLM, STOPS ON THE BELL) -> register
-- (deterministic; the model makes exactly one tool call).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS forge;
COMMENT ON SCHEMA forge IS
'companion pack: home of FORGED tools (human-approved, transaction-verified). Every function here was approved on the bell as exact SQL before it existed.';

-- ── the forged-tools ledger ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS forge.forged_tools (
    tool_name    text PRIMARY KEY,
    work_item_id uuid,
    plan_excerpt text NOT NULL,          -- the approved plan's header (audit trail)
    test_call    jsonb NOT NULL,         -- the args the verify ran with
    test_result  jsonb NOT NULL,         -- what the verify got back
    forged_at    timestamptz NOT NULL DEFAULT now(),
    forged_by    text NOT NULL DEFAULT 'forge_register'
);
COMMENT ON TABLE forge.forged_tools IS
'companion pack: one row per forged tool — the plan it came from, the test that proved it, when. The receipt behind every tool the forge ever made.';

-- ── forge_register(p_args) — the deterministic register+verify ─────────
-- Args: { "sql": "<CREATE OR REPLACE FUNCTION forge.x(p_args jsonb) ...>",
--         "tool_name": "x", "description": "...",
--         "args_schema": {...}, "test_args": {...},
--         "plan_excerpt": "...", "_session_id": injected }
-- ONE transaction: structure-check -> EXECUTE the SQL -> run the test
-- call -> register tool_defs (sql_fn, forge schema) -> receipt row.
-- Any failure (structure, execution, test raising, test returning an
-- {"error": ...}) raises -> the whole thing rolls back: no function, no
-- tool row, no receipt.
CREATE OR REPLACE FUNCTION forge.forge_register(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sql    text := btrim(coalesce(p_args->>'sql', ''));
    v_name   text := lower(btrim(coalesce(p_args->>'tool_name', '')));
    v_desc   text := coalesce(p_args->>'description', '');
    v_schema jsonb := coalesce(p_args->'args_schema', '{"type":"object","properties":{}}'::jsonb);
    v_test   jsonb := coalesce(p_args->'test_args', '{}'::jsonb);
    v_plan   text := left(coalesce(p_args->>'plan_excerpt', '(no excerpt given)'), 2000);
    v_wi     uuid  := NULLIF(p_args->>'work_item_id','')::uuid;
    v_effect text  := lower(btrim(coalesce(p_args->>'effect_class','write_local')));
    v_body_stripped text;
    v_result jsonb;
BEGIN
    IF v_name = '' OR v_name !~ '^[a-z][a-z0-9_]{2,62}$' THEN
        RETURN jsonb_build_object('ok', false, 'error',
            'tool_name required: lowercase identifier, 3-63 chars');
    END IF;
    IF v_sql = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'sql required (the approved CREATE FUNCTION)');
    END IF;
    IF v_effect NOT IN ('read','write_local') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'effect_class must be read or write_local');
    END IF;

    -- Structure seatbelt (the approval is the wall; this catches accidents):
    -- must be a single CREATE OR REPLACE FUNCTION forge.<tool_name>(p_args jsonb)
    -- and, outside dollar-quoted bodies, contain no second statement.
    IF v_sql !~* ('^CREATE\s+OR\s+REPLACE\s+FUNCTION\s+forge\.' || v_name || '\s*\(\s*p_args\s+jsonb\s*\)') THEN
        RETURN jsonb_build_object('ok', false, 'error',
            'sql must define exactly CREATE OR REPLACE FUNCTION forge.' || v_name || '(p_args jsonb)');
    END IF;
    -- strip $tag$...$tag$ bodies, then any semicolon left except a single
    -- trailing one means extra statements smuggled alongside the function.
    v_body_stripped := regexp_replace(v_sql, '\$[a-zA-Z_]*\$.*?\$[a-zA-Z_]*\$', '', 'gs');
    IF regexp_replace(v_body_stripped, ';\s*$', '') ~ ';' THEN
        RETURN jsonb_build_object('ok', false, 'error',
            'sql must be a SINGLE statement (extra '';'' found outside the function body)');
    END IF;

    -- 1. create the function (rolls back with everything else on any failure)
    EXECUTE v_sql;

    -- 2. the plan's own test call — a raise OR an {"error":...} result fails the forge
    EXECUTE format('SELECT forge.%I($1::jsonb)', v_name) USING v_test INTO v_result;
    IF v_result IS NULL OR (jsonb_typeof(v_result) = 'object' AND v_result ? 'error') THEN
        RAISE EXCEPTION 'forge verify failed: test call returned %', coalesce(v_result::text, 'NULL');
    END IF;

    -- 3. register as a live sql_fn tool (hot: no restart, no rebuild)
    INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active)
    VALUES (v_name, v_desc, v_schema,
            jsonb_build_object('kind','sql_fn','schema','forge','name',v_name),
            v_effect, true)
    ON CONFLICT (name) DO UPDATE SET
        description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
        execute_target = EXCLUDED.execute_target, active = true;

    -- 4. the receipt
    INSERT INTO forge.forged_tools (tool_name, work_item_id, plan_excerpt, test_call, test_result)
    VALUES (v_name, v_wi, v_plan, v_test, v_result)
    ON CONFLICT (tool_name) DO UPDATE SET
        work_item_id = EXCLUDED.work_item_id, plan_excerpt = EXCLUDED.plan_excerpt,
        test_call = EXCLUDED.test_call, test_result = EXCLUDED.test_result,
        forged_at = now();

    RETURN jsonb_build_object('ok', true, 'tool', v_name,
        'test_result', v_result,
        'note', 'forged, verified by its own test call, and registered live. '
                'Substrate pipelines/chat can use it now; harness seats (Arc C) see it after their tool surface refreshes.');
END;
$fn$;
COMMENT ON FUNCTION forge.forge_register(jsonb) IS
'companion pack: apply an APPROVED forge plan atomically — structure-check, EXECUTE the CREATE FUNCTION, run the plan''s test call, register tool_defs, write the receipt. Any failure rolls back everything. The bell approval of the exact SQL is the wall; this is the seatbelt + the verify.';

-- ── tool_defs: expose forge_register to the register stage ─────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
( 'forge_register',
  'Apply the APPROVED forge plan: creates the forge.<tool_name> function, runs the plan''s test call, registers the tool — all in one transaction (any failure rolls everything back). Pass the plan''s fields VERBATIM; the human approved that exact SQL and nothing else.',
  '{"type":"object","required":["sql","tool_name","description","test_args"],"properties":{'
    '"sql":{"type":"string","description":"the approved CREATE OR REPLACE FUNCTION forge.<tool_name>(p_args jsonb) statement, verbatim from the plan"},'
    '"tool_name":{"type":"string"},'
    '"description":{"type":"string","description":"one-sentence tool description for the registry"},'
    '"args_schema":{"type":"object","description":"JSON schema for the tool args, from the plan"},'
    '"test_args":{"type":"object","description":"the plan''s test call args"},'
    '"plan_excerpt":{"type":"string","description":"first lines of the approved plan (the receipt)"},'
    '"effect_class":{"type":"string","enum":["read","write_local"],"description":"from the plan: read = pure lookup/computation (callable from harness seats freely), write_local = writes rows"},'
    '"work_item_id":{"type":"string"}'
  '}}'::jsonb,
  '{"kind":"sql_fn","schema":"forge","name":"forge_register"}'::jsonb, 'write_local', true )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, effect_class = EXCLUDED.effect_class, active = true;

INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('forge-register', 'the forge''s one finalize tool — the register stage''s whole surface', ARRAY['forge_register'])
ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description, tool_patterns = EXCLUDED.tool_patterns;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research', 'forge_register', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ── the companion intent (idempotent) ───────────────────────────────────
INSERT INTO stewards.intents (slug, purpose, beneficiary)
VALUES ('companion',
        'Be the household''s voice-reachable steward: answer from the substrate, start real work, and grow new capabilities only through the forge''s approval bell.',
        'the humans this instance serves')
ON CONFLICT (slug) DO NOTHING;

-- ── the forge pipeline ──────────────────────────────────────────────────
INSERT INTO stewards.pipelines (family, description, stages, metadata)
VALUES (
  'forge',
  'Hinge-gated self-extension: plan a new forge tool (STOPS on the approval bell with the exact SQL) -> register (deterministic apply+verify+register in one transaction). Nothing is created or registered before a human approves the plan.',
  jsonb_build_array(
    jsonb_build_object('name','plan','next','register',
        'model','reason','agent_family','research',
        'auto_advance', false,   -- THE GATE: the plan stops on the bell
        'tools_disabled', true,  -- planning is thinking, not doing
        'input_template',
          'You are the FORGE PLANNER. Someone wished for a capability this substrate does not have:' || E'\n\n' ||
          '{{input.assignment}}' || E'\n\n' ||
          'Draft ONE forge plan for a HUMAN REVIEWER (it will sit on their approval bell; they approve the exact SQL or edit the wish and re-run). Write, in this order:' || E'\n' ||
          '1. TOOL: <tool_name> — one sentence on what it does. Name: lowercase_snake, 3-63 chars.' || E'\n' ||
          '2. RISKS: what this function can touch, worst case, in plain words. If the wish needs network access, external services, secrets, or writes outside the database — say the forge CANNOT do that part and plan the largest safe subset (or say the wish needs a real coder task instead).' || E'\n' ||
          '3. SQL: one complete `CREATE OR REPLACE FUNCTION forge.<tool_name>(p_args jsonb) RETURNS jsonb LANGUAGE plpgsql` statement, dollar-quoted, defensive (validate args, return {"error": "..."} for bad input, never raise on user input). Read-only against stewards.* unless the wish clearly requires writes; forged tools NEVER touch stewards.config, tool_defs, agent_* or other governance tables.' || E'\n' ||
          '4. ARGS_SCHEMA: the JSON schema object for p_args.' || E'\n' ||
          '5. TEST_ARGS: one JSON object of test args whose call must succeed (this exact call gates registration — if it fails, nothing is created).' || E'\n' ||
          '6. EXPECTED: one sentence — what the test call should return.' || E'\n\n' ||
          'Output the plan as plain text with those numbered sections. No preamble.'),
    jsonb_build_object('name','register','next',NULL,
        'model','ingest','agent_family','research',
        'auto_advance', true, 'tools_disabled', false,
        'tool_groups', jsonb_build_array('forge-register'),
        'input_template',
          'You are the FORGE REGISTRAR — deterministic. The plan below was APPROVED by a human exactly as written.' || E'\n\n' ||
          '{{stage_results.plan.output}}' || E'\n\n' ||
          'Make ONE tool call: `forge_register`, copying the plan''s fields VERBATIM — sql (section 3, the complete statement), tool_name, description (section 1''s sentence), effect_class (the effect declared in section 1: read or write_local), args_schema (section 4), test_args (section 5), plan_excerpt (section 1-2, condensed), and the work item id if you know it. Do NOT modify the SQL in any way; you are a courier, not an editor.' || E'\n\n' ||
          'Reply with EXACTLY one line: "FORGED <tool_name>" on success, or the tool''s error verbatim.')
  ),
  jsonb_build_object('pack','companion','provenance','Ada-SI (MIT) forge loop, rebuilt on substrate organs')
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    metadata = stewards.pipelines.metadata || EXCLUDED.metadata,
    updated_at = now();
-- >>> from packs/companion/companion.sql
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
