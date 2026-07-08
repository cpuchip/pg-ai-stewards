-- packs/companion/smoke.sql — deterministic forge oracle (no models needed).
-- Run against a scratch container with the pack applied, or live (cleans up).
-- Proves: a good plan forges+verifies+registers atomically; a plan whose own
-- test fails rolls back EVERYTHING (inverse); the structure seatbelt refuses
-- wrong-schema and smuggled-statement SQL.

DO $smoke$
DECLARE
    v jsonb;
BEGIN
    -- ── happy path: forge a tiny real tool ─────────────────────────────
    v := forge.forge_register(jsonb_build_object(
        'tool_name', 'smoke_echo_upper',
        'description', 'uppercases the text arg (forge smoke fixture)',
        'sql',
          'CREATE OR REPLACE FUNCTION forge.smoke_echo_upper(p_args jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$'
          'BEGIN IF coalesce(p_args->>''text'','''') = '''' THEN RETURN jsonb_build_object(''error'',''text required''); END IF;'
          'RETURN jsonb_build_object(''ok'', true, ''text'', upper(p_args->>''text'')); END; $f$',
        'args_schema', '{"type":"object","required":["text"],"properties":{"text":{"type":"string"}}}'::jsonb,
        'test_args', '{"text":"hello forge"}'::jsonb,
        'plan_excerpt', 'smoke fixture'));
    ASSERT (v->>'ok')::boolean, format('smoke 1: happy-path forge must succeed, got %s', v);
    ASSERT v->'test_result'->>'text' = 'HELLO FORGE', 'smoke 1: the verify must have really run the tool';
    ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name='smoke_echo_upper' AND active), 'smoke 1: tool_defs row must exist';
    ASSERT EXISTS (SELECT 1 FROM forge.forged_tools WHERE tool_name='smoke_echo_upper'), 'smoke 1: receipt row must exist';
    ASSERT (forge.smoke_echo_upper('{"text":"abc"}'::jsonb))->>'text' = 'ABC', 'smoke 1: the forged tool must be callable';

    -- ── INVERSE: a failing test call must roll back function+row+receipt ─
    BEGIN
        v := forge.forge_register(jsonb_build_object(
            'tool_name', 'smoke_broken',
            'description', 'always errors (must NOT register)',
            'sql',
              'CREATE OR REPLACE FUNCTION forge.smoke_broken(p_args jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$'
              'BEGIN RETURN jsonb_build_object(''error'', ''I never work''); END; $f$',
            'args_schema', '{"type":"object","properties":{}}'::jsonb,
            'test_args', '{}'::jsonb,
            'plan_excerpt', 'smoke inverse fixture'));
        RAISE EXCEPTION 'smoke 2: forge of a failing tool must RAISE, got %', v;
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'forge verify failed%' THEN RAISE; END IF;
    END;
    ASSERT to_regprocedure('forge.smoke_broken(jsonb)') IS NULL, 'smoke 2 INVERSE: the function must not exist';
    ASSERT NOT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name='smoke_broken'), 'smoke 2 INVERSE: no tool_defs row';
    ASSERT NOT EXISTS (SELECT 1 FROM forge.forged_tools WHERE tool_name='smoke_broken'), 'smoke 2 INVERSE: no receipt';

    -- ── seatbelt: wrong schema refused ──────────────────────────────────
    v := forge.forge_register(jsonb_build_object(
        'tool_name', 'smoke_escape',
        'description', 'x', 'test_args', '{}'::jsonb,
        'sql', 'CREATE OR REPLACE FUNCTION stewards.smoke_escape(p_args jsonb) RETURNS jsonb LANGUAGE sql AS $f$ SELECT ''{}''::jsonb $f$'));
    ASSERT NOT (v->>'ok')::boolean AND v->>'error' LIKE '%forge.smoke_escape%', 'smoke 3: wrong-schema SQL must be refused';

    -- ── seatbelt: smuggled second statement refused ─────────────────────
    v := forge.forge_register(jsonb_build_object(
        'tool_name', 'smoke_smuggle',
        'description', 'x', 'test_args', '{}'::jsonb,
        'sql', 'CREATE OR REPLACE FUNCTION forge.smoke_smuggle(p_args jsonb) RETURNS jsonb LANGUAGE sql AS $f$ SELECT ''{}''::jsonb $f$; DROP TABLE forge.forged_tools'));
    ASSERT NOT (v->>'ok')::boolean AND v->>'error' LIKE '%SINGLE statement%', 'smoke 4: smuggled statement must be refused';
    ASSERT to_regclass('forge.forged_tools') IS NOT NULL, 'smoke 4: the ledger must still exist';

    -- cleanup the happy-path fixture
    DROP FUNCTION forge.smoke_echo_upper(jsonb);
    DELETE FROM stewards.tool_defs WHERE name='smoke_echo_upper';
    DELETE FROM forge.forged_tools WHERE tool_name='smoke_echo_upper';

    RAISE NOTICE 'OK forge-smoke: happy path forges+verifies+registers atomically (and the forged tool runs); a failing self-test rolls back function+registry+receipt (inverse-proven); wrong-schema and smuggled-statement SQL are refused with the ledger intact';
END
$smoke$;

\echo '== companion pack: forge smoke PASSED =='
