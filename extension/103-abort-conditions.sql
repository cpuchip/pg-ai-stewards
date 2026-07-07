-- =====================================================================
-- 103 — ABORT CONDITIONS: war-game aborts[] materialized as live checks (W2)
-- =====================================================================
-- Ratified 2026-07-05 (.spec/proposals/war-game-pipeline.md, decision #3).
-- W1 (102) captures a war-game's structured block onto work_items.war_game
-- as context-only jsonb -- nothing evaluates it. W2 gives the `aborts[]`
-- half a live home: a first-class table the substrate checks mechanically
-- every tick, joining the ~9 existing per-work-item side tables
-- (gate_decisions, verify_results, needs_attention, ...).
--
-- Predicate discipline (decision #3, same as route_on's edge vocabulary):
-- `kind` is STRUCTURED, from a FIXED evaluator vocabulary, never
-- model-authored SQL. An abort the wargame agent invents with an unknown
-- kind (D3C's war-game invented "metric_threshold") maps to 'other' at
-- arming time WITHOUT erroring -- 'other' is human-only and never trips
-- mechanically. Forks still -> route_on, assumptions still -> ask_up
-- (their existing right homes); only aborts get this new table.
--
-- Three pieces, each re-authoring or extending the highest-numbered prior
-- definition (later-file-wins, CORE-on-CORE, clobber-check safe):
--   §1 work_item_abort_conditions   — NEW table + partial index.
--   §2 war_game_capture             — 103 RE-AUTHORS war_game_capture FROM
--                                      102: identical parse/floor/release
--                                      logic, +arming one row per
--                                      aborts[] entry on the RELEASE path
--                                      only (a standalone war-game item
--                                      with no war_game_for mission has
--                                      nothing to execute, so nothing to
--                                      abort). Port from HERE, not 102, if
--                                      a future file touches this again.
--   §3 abort_conditions_evaluate    — NEW: the mechanical per-kind check,
--                                      per-row exception isolation (the
--                                      #330 poison-row lesson), disarm +
--                                      awaiting_review + steward_actions
--                                      on trip.
-- §4 wires the evaluator into steward_tick's LAST author (32-alias-
-- failover.sql) with one surgical to_regprocedure-guarded, exception-
-- isolated call -- see that file for the actual edit; nothing to install
-- from this file for §4, it is documented here for the reader who greps
-- 103 looking for the wiring and doesn't find it in this file.
-- =====================================================================


-- ---------------------------------------------------------------------
-- §1 — the abort-condition rows themselves.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.work_item_abort_conditions (
    id              bigserial PRIMARY KEY,
    work_item_id    uuid NOT NULL REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    kind            text NOT NULL DEFAULT 'other'
                    CHECK (kind IN ('error_matches', 'tool_unavailable',
                                     'repeat_failure', 'budget_fraction', 'other')),
    params          jsonb NOT NULL DEFAULT '{}'::jsonb,
    condition       text NOT NULL,
    source_move     text,
    armed           boolean NOT NULL DEFAULT true,
    tripped_at      timestamptz,
    tripped_reason  text,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_work_item_abort_conditions_armed
    ON stewards.work_item_abort_conditions (work_item_id) WHERE armed;

COMMENT ON TABLE stewards.work_item_abort_conditions IS
'103 (W2): a war-game''s aborts[] materialized as first-class, queryable rows -- one per abort condition named in work_items.war_game. Armed by war_game_capture() on the RELEASE path (a mission work item, not the standalone war-game item). Evaluated each tick by stewards.abort_conditions_evaluate(). kind is a FIXED evaluator vocabulary (error_matches/tool_unavailable/repeat_failure/budget_fraction/other); an unrecognized kind from the artifact always coerces to ''other'' at arming time (human-only, never auto-trips) rather than erroring.';


-- ---------------------------------------------------------------------
-- §2 — 103 re-authors war_game_capture from 102: same parse/floor/release
--      logic verbatim, + arm one abort_conditions row per aborts[] entry
--      when the release path stamps a MISSION work item (not the
--      standalone war-game item itself -- it has nothing to execute).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.war_game_capture() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE
    v_item     stewards.work_items%ROWTYPE;
    v_txt      text;
    v_wg       jsonb;
    v_ok       boolean;
    v_target   uuid;
    v_reason   text;
    v_armed_n  int;
BEGIN
    SELECT * INTO v_item FROM stewards.work_items WHERE id = NEW.work_item_id;
    IF NOT FOUND OR v_item.pipeline_family <> 'war-game' THEN
        RETURN NEW;
    END IF;

    -- last fenced ```json block in the pooled body (the critic may have
    -- patched it; last wins). Lazy dotall match; 'g' returns blocks in order.
    SELECT (array_agg(m[1]))[array_upper(array_agg(m[1]), 1)] INTO v_txt
      FROM regexp_matches(NEW.body, '```json\s*(.+?)```', 'gs') AS m;

    IF v_txt IS NULL THEN
        INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
        VALUES (v_item.id, 'pooled war-game doc has no fenced json block', 'war_game_parse_failed',
                jsonb_build_object('doc_slug', NEW.slug));
        RETURN NEW;
    END IF;

    BEGIN
        v_wg := btrim(v_txt)::jsonb;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
        VALUES (v_item.id, left('war-game json block does not parse: ' || SQLERRM, 500),
                'war_game_parse_failed', jsonb_build_object('doc_slug', NEW.slug));
        RETURN NEW;
    END;

    -- W1 oracle floor: >=1 move carrying a countermove, >=1 abort condition.
    -- coalesce guards the three-valued trap: a MISSING key makes jsonb_typeof
    -- return NULL, NULL AND true = NULL, and IF NOT NULL never fires — the
    -- invalid block would stamp. (Caught by the vs102 inverse assertion.)
    v_ok := coalesce(
        jsonb_typeof(v_wg -> 'moves') = 'array'
        AND jsonb_array_length(v_wg -> 'moves') >= 1
        AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_wg -> 'moves') mv
                     WHERE btrim(coalesce(mv ->> 'countermove', '')) <> '')
        AND jsonb_typeof(v_wg -> 'aborts') = 'array'
        AND jsonb_array_length(v_wg -> 'aborts') >= 1,
        false);
    IF NOT v_ok THEN
        INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
        VALUES (v_item.id,
                'war-game block parsed but fails the floor (needs >=1 move with countermove + >=1 abort)',
                'war_game_invalid',
                jsonb_build_object('doc_slug', NEW.slug,
                                   'moves', jsonb_typeof(v_wg -> 'moves'),
                                   'aborts', jsonb_typeof(v_wg -> 'aborts')));
        RETURN NEW;
    END IF;

    UPDATE stewards.work_items SET war_game = v_wg WHERE id = v_item.id;
    INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
    VALUES (v_item.id, 'war-game artifact pooled; structured block captured', 'war_game_captured',
            jsonb_build_object('doc_slug', NEW.slug,
                               'moves',  jsonb_array_length(v_wg -> 'moves'),
                               'aborts', jsonb_array_length(v_wg -> 'aborts'),
                               'forks',  coalesce(jsonb_array_length(v_wg -> 'forks'), 0),
                               'assumptions', coalesce(jsonb_array_length(v_wg -> 'assumptions'), 0)));

    -- Release the waiting mission item, if this war-game was spawned for one.
    v_target := nullif(v_item.input ->> 'war_game_for', '')::uuid;
    IF v_target IS NOT NULL THEN
        UPDATE stewards.work_items
           SET war_game = v_wg,
               input    = (input - 'awaiting_war_game')
                          || jsonb_build_object('war_game_doc', NEW.slug)
         WHERE id = v_target
           -- Only release a mission that is still WAITING. Builder A caught
           -- the original guard here checking status values ('done','error')
           -- that do not exist in work_items' CHECK constraint — making it
           -- always-true, so a cancelled/already-running mission could be
           -- stamped and re-dispatched. 'pending' is the one state a
           -- war_game:true mission occupies while its companion fights.
           AND status = 'pending';
        IF FOUND THEN
            -- 103 (W2): arm one work_item_abort_conditions row per aborts[]
            -- entry on the MISSION now that it is about to execute (a
            -- standalone war-game item with no war_game_for target never
            -- reaches this branch — it has nothing to abort). Isolated in
            -- its own exception block: an arming failure must not block
            -- the mission's release (fail open, same discipline as the
            -- dispatch PERFORM immediately below).
            BEGIN
                INSERT INTO stewards.work_item_abort_conditions
                    (work_item_id, kind, params, condition, source_move)
                SELECT v_target,
                       CASE WHEN (ab ->> 'kind') IN ('error_matches', 'tool_unavailable',
                                                       'repeat_failure', 'budget_fraction')
                            THEN ab ->> 'kind'
                            ELSE 'other'   -- unknown/missing kind (e.g. D3C's invented
                                           -- "metric_threshold") ALWAYS coerces here —
                                           -- never raises the CHECK constraint.
                       END,
                       coalesce(ab -> 'params', '{}'::jsonb),
                       coalesce(nullif(btrim(ab ->> 'condition'), ''), '(no condition text given)'),
                       NULL
                  FROM jsonb_array_elements(coalesce(v_wg -> 'aborts', '[]'::jsonb)) ab;
                GET DIAGNOSTICS v_armed_n = ROW_COUNT;

                INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
                VALUES (v_target, format('armed %s abort condition(s) from the war-game', v_armed_n),
                        'war_game_aborts_armed',
                        jsonb_build_object('war_game_item', v_item.id, 'doc_slug', NEW.slug, 'armed', v_armed_n));
            EXCEPTION WHEN OTHERS THEN
                INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
                VALUES (v_target, 'war-game aborts failed to arm: ' || SQLERRM,
                        'war_game_aborts_arm_failed', jsonb_build_object('war_game_item', v_item.id));
            END;

            BEGIN
                PERFORM stewards.work_item_dispatch_stage(v_target);
                INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
                VALUES (v_target, 'war-game complete; mission released for execution',
                        'war_game_release', jsonb_build_object('war_game_item', v_item.id, 'doc_slug', NEW.slug));
            EXCEPTION WHEN OTHERS THEN
                v_reason := left(SQLERRM, 500);
                INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
                VALUES (v_target, 'war-game captured but mission dispatch failed: ' || v_reason,
                        'war_game_release_failed', jsonb_build_object('war_game_item', v_item.id));
            END;
        END IF;
    END IF;

    RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION stewards.war_game_capture() IS
'102/103: fires when a pooled doc lands in stewards.docs for a war-game work item — extracts the last fenced json block, validates the floor (>=1 move with countermove, >=1 abort), stamps work_items.war_game, and releases + stamps the waiting mission item (input.war_game_for) if there is one. 103 additionally arms one stewards.work_item_abort_conditions row per aborts[] entry on that release (unknown kind coerces to ''other'', never errors). Failures log to steward_actions (war_game_parse_failed / war_game_invalid / war_game_release_failed / war_game_aborts_arm_failed) — loud, not silent.';


-- ---------------------------------------------------------------------
-- §3 — the evaluator: check every armed row on a non-terminal work item,
--      mechanically, per kind. Called by steward_tick each tick (§4, the
--      wiring lives in 32-alias-failover.sql — see that file's edit).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.abort_conditions_evaluate() RETURNS int
LANGUAGE plpgsql AS $fn$
DECLARE
    v_count    int := 0;
    v_row      record;
    v_wi       stewards.work_items%ROWTYPE;
    v_tripped  boolean;
    v_reason   text;
BEGIN
    FOR v_row IN
        SELECT ac.*
          FROM stewards.work_item_abort_conditions ac
          JOIN stewards.work_items wi ON wi.id = ac.work_item_id
         WHERE ac.armed
           AND wi.status NOT IN ('completed', 'cancelled')
         ORDER BY ac.id
         FOR UPDATE OF ac SKIP LOCKED
    LOOP
        BEGIN
            SELECT * INTO v_wi FROM stewards.work_items WHERE id = v_row.work_item_id;
            IF NOT FOUND THEN
                CONTINUE;
            END IF;

            v_tripped := false;
            v_reason  := NULL;

            CASE v_row.kind
            WHEN 'error_matches' THEN
                -- params.pattern ~* against last_failure_reason OR error.
                v_tripped := coalesce(
                    (v_row.params ->> 'pattern') IS NOT NULL
                    AND (coalesce(v_wi.last_failure_reason, '') ~* (v_row.params ->> 'pattern')
                         OR coalesce(v_wi.error, '') ~* (v_row.params ->> 'pattern')),
                    false);
                IF v_tripped THEN
                    v_reason := format('error_matches: pattern %L matched last_failure_reason/error',
                                        v_row.params ->> 'pattern');
                END IF;

            WHEN 'repeat_failure' THEN
                -- params.n <= failure_count.
                v_tripped := coalesce(
                    (v_row.params ->> 'n') IS NOT NULL
                    AND (v_row.params ->> 'n')::int <= v_wi.failure_count,
                    false);
                IF v_tripped THEN
                    v_reason := format('repeat_failure: failure_count %s >= n %s',
                                        v_wi.failure_count, v_row.params ->> 'n');
                END IF;

            WHEN 'budget_fraction' THEN
                -- params.fraction <= cost_micro_dollars / cost_cap_micro.
                -- NULLIF guards div-by-zero/NULL cap; coalesce guards the
                -- three-valued trap (a NULL comparison must read as "did
                -- not trip", never as an error or a silent true).
                v_tripped := coalesce(
                    (v_row.params ->> 'fraction') IS NOT NULL
                    AND v_wi.cost_cap_micro IS NOT NULL
                    AND (v_row.params ->> 'fraction')::float <=
                        (v_wi.cost_micro_dollars::float / NULLIF(v_wi.cost_cap_micro, 0)),
                    false);
                IF v_tripped THEN
                    v_reason := format('budget_fraction: spent %s/%s (fraction %.4f) >= threshold %s',
                                        v_wi.cost_micro_dollars, v_wi.cost_cap_micro,
                                        v_wi.cost_micro_dollars::float / NULLIF(v_wi.cost_cap_micro, 0),
                                        v_row.params ->> 'fraction');
                END IF;

            WHEN 'tool_unavailable' THEN
                -- params.tool NOT IN the active tool_defs set.
                v_tripped := coalesce(
                    (v_row.params ->> 'tool') IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM stewards.tool_defs
                                     WHERE name = (v_row.params ->> 'tool') AND active),
                    false);
                IF v_tripped THEN
                    v_reason := format('tool_unavailable: %s is not an active tool',
                                        v_row.params ->> 'tool');
                END IF;

            ELSE
                -- 'other' (and anything else that somehow lands here):
                -- human-only. Never trips mechanically — a person decides.
                v_tripped := false;
            END CASE;

            IF v_tripped THEN
                UPDATE stewards.work_item_abort_conditions
                   SET armed = false,
                       tripped_at = now(),
                       tripped_reason = v_reason
                 WHERE id = v_row.id;

                UPDATE stewards.work_items
                   SET status = 'awaiting_review'
                 WHERE id = v_wi.id
                   AND status NOT IN ('completed', 'cancelled');

                INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
                VALUES (v_wi.id,
                        format('war-game abort tripped: %s — %s', v_row.condition, v_reason),
                        'war_game_abort_tripped',
                        jsonb_build_object('abort_condition_id', v_row.id, 'kind', v_row.kind,
                                           'condition', v_row.condition, 'params', v_row.params,
                                           'reason', v_reason));
                v_count := v_count + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- #330 poison-row lesson, generalized: one bad predicate (a
            -- malformed params.n/fraction that fails ::int/::float cast,
            -- say) must never abort the whole sweep.
            BEGIN
                INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
                VALUES (v_row.work_item_id,
                        'abort_conditions_evaluate row error: ' || SQLERRM,
                        'tick_error',
                        jsonb_build_object('sqlerrm', SQLERRM, 'sqlstate', SQLSTATE,
                                           'abort_condition_id', v_row.id, 'kind', v_row.kind));
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END;
    END LOOP;

    RETURN v_count;
END;
$fn$;

COMMENT ON FUNCTION stewards.abort_conditions_evaluate() IS
'103 (W2): checks every ARMED work_item_abort_conditions row on a non-terminal work item mechanically — error_matches (params.pattern ~* last_failure_reason/error), repeat_failure (params.n <= failure_count), budget_fraction (params.fraction <= cost_micro_dollars/cost_cap_micro), tool_unavailable (params.tool not in the active tool_defs set); kind=other is human-only and never auto-trips. On trip: disarms the row, stamps tripped_at/tripped_reason, moves the work item to awaiting_review, and logs a war_game_abort_tripped steward_action. Per-row exception isolation (the #330 lesson) — one bad row logs tick_error and the sweep continues. Returns the count of conditions tripped this call. Wired into steward_tick (32-alias-failover.sql) via a to_regprocedure-guarded, exception-isolated PERFORM.';

-- =====================================================================
-- End of 103-abort-conditions.sql
-- =====================================================================
