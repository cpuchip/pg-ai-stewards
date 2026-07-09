-- =====================================================================
-- v33-wargame-w2.sql — war-game W2, part 2/3: FORKS + ASSUMPTIONS made
--                      operational (aborts shipped already in v25).
-- =====================================================================
-- Ratified 2026-07-05 (.spec/proposals/war-game-pipeline.md). W1 (v25 §102)
-- captures a war-game's structured block onto work_items.war_game as
-- context-only jsonb. W2 gives the three outputs live homes:
--
--   aborts[]       -> stewards.work_item_abort_conditions + the tick sweep.
--                     ALREADY SHIPPED in v25 (§ "[was 103-abort-conditions]")
--                     and wired into steward_tick by v31. This volume does
--                     NOT touch that table or evaluator — it re-verifies them
--                     as a regression in tests/smoke-w2.sql.
--   forks[]        -> route_on. NEW HERE.
--   assumptions[]  -> ask_up / needs_attention. NEW HERE.
--
-- Why a NEW volume and not an edit: v25/v31 are applied (their sha is in the
-- migrate ledger); editing an applied volume forces a whole-migration
-- re-apply. This volume re-authors work_item_advance (last full author: v09)
-- and war_game_capture (last full author: v25 §103) ONE more time each —
-- carried verbatim + a single surgical addition apiece, the same later-file-
-- wins / carry-the-latest-body discipline v31 used on v27's steward_tick.
--
-- Three pieces:
--   §1  work_items.route_on_override   — NEW per-item column; the home a
--                                        war-game's translated forks land in
--                                        WITHOUT polluting the shared pipeline.
--   §2  wargame_apply_forks            — translate CLEAN forks -> route_on_override;
--       wargame_surface_assumptions    — batch unresolved assumptions -> ONE
--                                        needs_attention 'ask' (not one bell each);
--       wargame_materialize            — orchestrator (forks + assumptions;
--                                        aborts are already armed at capture).
--   §3  war_game_capture  (re-authored v25 §103 body, verbatim + one call)
--                                      — calls wargame_materialize on the SAME
--                                        release path that arms the aborts.
--   §4  work_item_advance (re-authored v09 body, verbatim + one CASE)
--                                      — reads route_on_override[stage] FIRST,
--                                        then the shared pipeline's route_on.
--
-- requires (lib.rs): create_v31_steward_park. NOTE FOR THE FOREMAN — a
-- sibling branch (feat/dispatch-honesty) owns v32; when both land, bump this
-- volume's `requires` to create_v32_* so the linear chain stays linear. See
-- the PR body.
--
-- Predicate discipline (unchanged from v25/route_on): forks translate ONLY
-- into route_on's existing regex-on-stage-output vocabulary; nothing here
-- authors or evaluates model-written SQL. A fork the war-gamer emits as prose
-- ({observe, route}) is NOT a clean shape -> it surfaces to a human, never
-- gets invented into a regex. Conservative by construction.
-- =====================================================================


-- ---------------------------------------------------------------------
-- §1 — per-item route_on override. The shared pipeline definition
--      (stewards.pipelines.stages) is one template for every item on the
--      family; a war-game's forks are the OPPOSITE — specific to one mission.
--      This column is where a mission's own translated forks live so they
--      route only THAT item. work_item_advance (§4) merges it ahead of the
--      pipeline's own route_on.
-- ---------------------------------------------------------------------
ALTER TABLE stewards.work_items ADD COLUMN IF NOT EXISTS route_on_override jsonb;

COMMENT ON COLUMN stewards.work_items.route_on_override IS
'v33 (W2): per-item route_on rules, an OBJECT keyed by the branching stage name -> array of route_on rule objects (same vocabulary as pipelines.stages route_on: when/unless/goto/feedback_key/count_key/max/on_max_goto/on_max_status/on_max_reason). Populated by wargame_apply_forks() from work_items.war_game -> forks (clean shapes only). work_item_advance evaluates route_on_override[current_stage] BEFORE the shared pipeline stage''s own route_on (first-match-wins). NULL (the default) -> byte-identical prior routing behavior. This is how a war-game''s forks route ONE mission without editing the shared pipeline template.';


-- ---------------------------------------------------------------------
-- §2a — wargame_apply_forks: forks[] -> route_on_override (clean) / ask (messy)
-- ---------------------------------------------------------------------
-- A fork is CLEAN (safe to auto-route) only when it carries, explicitly:
--   * `when`  — an observable regex trigger (route_on matches it against the
--               completing stage's text output). A fork with no observable
--               trigger is a guess (the v25 wargame prompt says so itself).
--   * `goto`  — a branch target that IS a real stage in this item's pipeline.
--   * `from`  — the branch-FROM stage (also real): route_on rules attach to
--               the stage whose completion is being judged, so we must know
--               which one. No `from` -> we will not guess the attach point.
-- The W1 contract emits forks as prose ({observe, route}); those lack
-- from/when/goto and are SURFACED, never invented into routing. Rebuilds the
-- override from scratch each call -> idempotent (a re-finalize re-capture
-- converges, never duplicates a rule).
CREATE OR REPLACE FUNCTION stewards.wargame_apply_forks(p_work_item uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi         stewards.work_items%ROWTYPE;
    v_forks      jsonb;
    v_fork       jsonb;
    v_from       text;
    v_goto       text;
    v_when       text;
    v_rule       jsonb;
    v_override   jsonb := '{}'::jsonb;
    v_existing   jsonb;
    v_translated int := 0;
    v_messy      jsonb := '[]'::jsonb;
    v_hinge_id   bigint;
    v_question   text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item;
    IF NOT FOUND OR v_wi.war_game IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'note', 'no work item or no war_game',
                                  'translated', 0, 'surfaced', 0);
    END IF;

    v_forks := v_wi.war_game -> 'forks';
    IF v_forks IS NULL OR jsonb_typeof(v_forks) <> 'array' THEN
        v_forks := '[]'::jsonb;
    END IF;

    FOR v_fork IN SELECT * FROM jsonb_array_elements(v_forks) LOOP
        v_from := nullif(btrim(coalesce(v_fork ->> 'from', '')), '');
        v_goto := nullif(btrim(coalesce(v_fork ->> 'goto', '')), '');
        v_when := nullif(btrim(coalesce(v_fork ->> 'when', '')), '');

        IF v_from IS NOT NULL AND v_goto IS NOT NULL AND v_when IS NOT NULL
           AND stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_from) IS NOT NULL
           AND stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_goto) IS NOT NULL
        THEN
            -- whitelist ONLY route_on's own keys; carry `max` as a jsonb number
            -- (route_on reads (rule->>'max')::int), the rest as text. strip_nulls
            -- drops the ones this fork did not specify.
            v_rule := jsonb_strip_nulls(jsonb_build_object(
                'when',          v_when,
                'goto',          v_goto,
                'unless',        v_fork ->> 'unless',
                'feedback_key',  v_fork ->> 'feedback_key',
                'count_key',     v_fork ->> 'count_key',
                'max',           v_fork -> 'max',
                'on_max_goto',   v_fork ->> 'on_max_goto',
                'on_max_status', v_fork ->> 'on_max_status',
                'on_max_reason', v_fork ->> 'on_max_reason',
                'source',        to_jsonb('wargame'::text)));
            v_existing := coalesce(v_override -> v_from, '[]'::jsonb);
            v_override := v_override
                          || jsonb_build_object(v_from, v_existing || jsonb_build_array(v_rule));
            v_translated := v_translated + 1;
        ELSE
            v_messy := v_messy || jsonb_build_array(jsonb_build_object(
                'observe', coalesce(v_fork ->> 'observe', v_fork ->> 'when', ''),
                'route',   coalesce(v_fork ->> 'route',   v_fork ->> 'goto', ''),
                'why',     'not a clean shape: needs explicit from+when+goto, with from/goto naming real stages'));
        END IF;
    END LOOP;

    UPDATE stewards.work_items
       SET route_on_override = CASE WHEN v_override = '{}'::jsonb THEN NULL ELSE v_override END,
           updated_at = now()
     WHERE id = p_work_item;

    -- Messy forks -> ONE batched needs_attention 'ask' per item. Idempotent
    -- guard: don't ring a second bell if one is already pending for this item.
    IF jsonb_array_length(v_messy) > 0
       AND NOT EXISTS (SELECT 1 FROM stewards.hinge_reviews
                        WHERE kind = 'ask' AND status IN ('pending','escalated')
                          AND payload ->> 'wargame_kind' = 'forks'
                          AND payload ->> 'work_item_id' = p_work_item::text)
    THEN
        v_question := format(
            'War-game proposed %s fork(s) that could not be safely auto-routed for this mission (pipeline %s). '
            || 'Each is "if you observe X, take route Y" without a concrete stage edge — turn it into one, or confirm '
            || 'it is not worth routing. (Clean forks were already applied to the item''s routing.)',
            jsonb_array_length(v_messy), v_wi.pipeline_family);
        v_hinge_id := stewards.hinge_enqueue(
            'ask',
            left(format('Review %s un-routable war-game fork(s)', jsonb_array_length(v_messy)), 120),
            jsonb_build_object('question', v_question, 'wargame_kind', 'forks',
                               'work_item_id', p_work_item, 'forks', v_messy),
            'wargame');
    END IF;

    INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
    VALUES (p_work_item,
            format('war-game forks materialized: %s translated to route_on, %s surfaced for review',
                   v_translated, jsonb_array_length(v_messy)),
            'war_game_forks_applied',
            jsonb_build_object('translated', v_translated, 'surfaced', jsonb_array_length(v_messy),
                               'override_stages', (SELECT coalesce(jsonb_agg(k), '[]'::jsonb)
                                                     FROM jsonb_object_keys(v_override) k)));

    RETURN jsonb_build_object('ok', true, 'translated', v_translated,
                              'surfaced', jsonb_array_length(v_messy), 'hinge_id', v_hinge_id);
END;
$fn$;

COMMENT ON FUNCTION stewards.wargame_apply_forks(uuid) IS
'v33 (W2): translate work_items.war_game -> forks[] into the item''s route_on_override. CLEAN (auto-routed): a fork with explicit from+when+goto where from/goto name real stages in the item''s pipeline. MESSY (the W1 {observe,route} prose shape, or any fork missing those): batched into ONE needs_attention ''ask'' (kind=ask, payload.wargame_kind=forks) — never invented into a regex. Rebuilds route_on_override from scratch each call (idempotent). Conservative by construction: only clean shapes route; the rest surface.';


-- ---------------------------------------------------------------------
-- §2b — wargame_surface_assumptions: assumptions[] -> ONE needs_attention ask
-- ---------------------------------------------------------------------
-- The v25 wargame contract flags assumptions its recon could NOT resolve
-- ({var, why_unresolved}) and tells the executor to STOP on an unfilled one.
-- W2 makes that visible: ONE batched 'ask' per work item (not one bell per
-- assumption). Uses hinge_enqueue(kind='ask') — the same surface ask_up's
-- top-rung fallback writes, which the needs_attention view already renders.
CREATE OR REPLACE FUNCTION stewards.wargame_surface_assumptions(p_work_item uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi        stewards.work_items%ROWTYPE;
    v_assum     jsonb;
    v_a         jsonb;
    v_lines     text := '';
    v_n         int := 0;
    v_hinge_id  bigint;
    v_question  text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item;
    IF NOT FOUND OR v_wi.war_game IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'note', 'no work item or no war_game', 'surfaced', 0);
    END IF;

    v_assum := v_wi.war_game -> 'assumptions';
    IF v_assum IS NULL OR jsonb_typeof(v_assum) <> 'array' OR jsonb_array_length(v_assum) = 0 THEN
        RETURN jsonb_build_object('ok', true, 'surfaced', 0, 'note', 'no unresolved assumptions');
    END IF;

    -- one bell per item: if an assumptions ask is already pending, don't ring another.
    IF EXISTS (SELECT 1 FROM stewards.hinge_reviews
                WHERE kind = 'ask' AND status IN ('pending','escalated')
                  AND payload ->> 'wargame_kind' = 'assumptions'
                  AND payload ->> 'work_item_id' = p_work_item::text) THEN
        RETURN jsonb_build_object('ok', true, 'surfaced', 0,
                                  'note', 'assumptions ask already pending (idempotent)');
    END IF;

    FOR v_a IN SELECT * FROM jsonb_array_elements(v_assum) LOOP
        v_n := v_n + 1;
        v_lines := v_lines || format(E'\n  %s. %s — %s',
            v_n,
            coalesce(nullif(btrim(v_a ->> 'var'), ''), '(unnamed assumption)'),
            coalesce(nullif(btrim(v_a ->> 'why_unresolved'), ''), 'unresolved'));
    END LOOP;

    v_question := format(
        'Before trusting this war-gamed mission, %s assumption(s) the recon could NOT resolve need your confirmation '
        || '(the executor is told to STOP on an unfilled assumption rather than improvise):%s',
        v_n, v_lines);

    v_hinge_id := stewards.hinge_enqueue(
        'ask',
        left(format('Confirm %s unresolved war-game assumption(s)', v_n), 120),
        jsonb_build_object('question', v_question, 'wargame_kind', 'assumptions',
                           'work_item_id', p_work_item, 'assumptions', v_assum, 'count', v_n),
        'wargame');

    INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
    VALUES (p_work_item,
            format('war-game surfaced %s unresolved assumption(s) as ONE needs_attention ask', v_n),
            'war_game_assumptions_surfaced',
            jsonb_build_object('count', v_n, 'hinge_id', v_hinge_id));

    RETURN jsonb_build_object('ok', true, 'surfaced', v_n, 'hinge_id', v_hinge_id);
END;
$fn$;

COMMENT ON FUNCTION stewards.wargame_surface_assumptions(uuid) IS
'v33 (W2): batch work_items.war_game -> assumptions[] into ONE needs_attention ''ask'' (hinge_reviews kind=ask, payload.wargame_kind=assumptions) — one bell per work item, listing every unresolved assumption, NOT one ring per assumption. Idempotent (skips if an assumptions ask is already pending for the item). No assumptions -> no bell.';


-- ---------------------------------------------------------------------
-- §2c — wargame_materialize: the orchestrator called at release (§3).
--       Aborts are already armed by war_game_capture; this does the other two.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.wargame_materialize(p_work_item uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi     stewards.work_items%ROWTYPE;
    v_forks  jsonb;
    v_assum  jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'note', 'no such work item');
    END IF;
    IF v_wi.war_game IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'note', 'work item has no war_game to materialize');
    END IF;

    v_forks := stewards.wargame_apply_forks(p_work_item);
    v_assum := stewards.wargame_surface_assumptions(p_work_item);

    UPDATE stewards.work_items
       SET input = input || jsonb_build_object('wargame_materialized',
                                               to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF')),
           updated_at = now()
     WHERE id = p_work_item;

    INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
    VALUES (p_work_item,
            format('war-game materialized: forks(%s translated / %s surfaced), assumptions(%s surfaced) '
                   || '[aborts armed at capture]',
                   coalesce(v_forks->>'translated','0'), coalesce(v_forks->>'surfaced','0'),
                   coalesce(v_assum->>'surfaced','0')),
            'war_game_materialized',
            jsonb_build_object('forks', v_forks, 'assumptions', v_assum));

    RETURN jsonb_build_object('ok', true, 'forks', v_forks, 'assumptions', v_assum);
END;
$fn$;

COMMENT ON FUNCTION stewards.wargame_materialize(uuid) IS
'v33 (W2): the release-time orchestrator — applies a captured war-game''s forks (wargame_apply_forks) and assumptions (wargame_surface_assumptions) to the mission work item. Aborts[] are NOT handled here: they are armed by war_game_capture at the same release moment (v25 §103). Idempotent (both helpers are). Called by the re-authored war_game_capture on the mission-release path, and safe to call by hand to (re-)materialize a specific item.';


-- ---------------------------------------------------------------------
-- §3 — war_game_capture re-authored (v25 §103 body carried VERBATIM +
--      ONE exception-isolated call to wargame_materialize on the release
--      path, right where the aborts are armed). The trg_war_game_capture
--      trigger (v25) already points at this function by name; CREATE OR
--      REPLACE keeps it wired.
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

            -- v33 (W2): now that the mission is armed and about to execute,
            -- materialize the OTHER two war-game outputs the same way the
            -- aborts were just armed above: forks -> the item's per-item
            -- route_on override (clean shapes only; messy ones surface),
            -- assumptions -> ONE batched needs_attention 'ask'. Isolated +
            -- fail-open exactly like the aborts block: a materialization
            -- failure must never block the mission's release (the dispatch
            -- PERFORM below). Idempotent, so a re-finalize re-capture is safe.
            BEGIN
                PERFORM stewards.wargame_materialize(v_target);
            EXCEPTION WHEN OTHERS THEN
                INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
                VALUES (v_target, 'war-game forks/assumptions failed to materialize: ' || SQLERRM,
                        'war_game_materialize_failed', jsonb_build_object('war_game_item', v_item.id));
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
'102/103/v33: fires when a pooled doc lands in stewards.docs for a war-game work item — extracts the last fenced json block, validates the floor (>=1 move with countermove, >=1 abort), stamps work_items.war_game, and releases + stamps the waiting mission item (input.war_game_for). On that release it (v25 §103) arms one work_item_abort_conditions row per aborts[] entry AND (v33 W2) calls wargame_materialize(mission) to translate forks -> route_on_override and batch assumptions -> one needs_attention ask. Both are exception-isolated / fail-open: neither an arming nor a materialization failure blocks the mission''s dispatch. Failures log to steward_actions (war_game_parse_failed / war_game_invalid / war_game_release_failed / war_game_aborts_arm_failed / war_game_materialize_failed) — loud, not silent.';


-- ---------------------------------------------------------------------
-- §4 — work_item_advance re-authored (v09 body carried VERBATIM + ONE
--      CASE that reads the per-item route_on_override[stage] BEFORE the
--      shared pipeline stage's own route_on). Last full author before this
--      was v09 (verified: v01/v02/v06/v09 author it; v09 is highest). No
--      trigger depends on it; CREATE OR REPLACE keeps every caller wired.
--      Everything outside the marked CASE is byte-identical to v09.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_advance(
    p_work_item_id uuid,
    p_stage_output jsonb DEFAULT '{}'::jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_pipeline        stewards.pipelines%ROWTYPE;
    v_stage           jsonb;
    v_next_name       text;
    v_auto_advance    boolean;
    v_results         jsonb;
    v_completing      text;
    v_new_maturity    text;
    v_current_idx     int;
    v_new_idx         int;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;
    IF v_wi.status NOT IN ('in_progress', 'awaiting_review', 'pending') THEN
        RAISE EXCEPTION 'work_item %: cannot advance from status %',
            p_work_item_id, v_wi.status;
    END IF;

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    v_next_name    := v_stage->>'next';
    v_auto_advance := COALESCE((v_stage->>'auto_advance')::bool, true);
    v_completing   := v_wi.current_stage;

    v_results := v_wi.stage_results
              || jsonb_build_object(v_completing,
                     p_stage_output
                     || jsonb_build_object('completed_at', now()));

    -- ----- empty-source halt (digester-empty-source-halt; pipeline-level) -----
    DECLARE
        v_halt jsonb;
    BEGIN
        SELECT metadata->'halt_on' INTO v_halt
          FROM stewards.pipelines WHERE family = v_wi.pipeline_family;
        IF v_halt IS NOT NULL
           AND v_halt->>'stage' = v_completing
           AND (v_halt->'outputs') ? btrim(COALESCE(v_results->v_completing->>'output','')) THEN
            UPDATE stewards.work_items
               SET stage_results       = v_results,
                   status              = 'cancelled',
                   last_failure_reason = format(
                       'empty-source halt: stage "%s" emitted "%s" (pipeline halt_on) — no downstream dispatch, nothing pooled',
                       v_completing, btrim(v_results->v_completing->>'output')),
                   updated_at          = now()
             WHERE id = p_work_item_id;
            RETURN NULL;
        END IF;
    END;

    -- ----- route_on: data-driven conditional / loop-back routing (A) -----
    -- Generalizes the old hardcoded code-pr review->implement (cv6) and
    -- plan_review->plan (cv11) loop-backs. First matching rule wins.
    DECLARE
        v_route    jsonb;
        v_rule     jsonb;
        v_out      text := btrim(COALESCE(v_results->v_completing->>'output',''));
        v_when     text;
        v_unless   text;
        v_goto     text;
        v_count    int;
        v_max      int;
        v_hops     int;
        v_hop_cap  int := COALESCE((SELECT (value#>>'{}')::int FROM stewards.config
                                     WHERE key = 'route_on_max_hops'), 50);
    BEGIN
        -- v33 (W2): per-item route_on override. A war-game's translated forks
        -- (stewards.wargame_apply_forks) land in work_items.route_on_override,
        -- an object keyed by the BRANCHING stage name. Those rules are tried
        -- FIRST (first-match-wins), then the shared pipeline stage's own
        -- route_on as fallback. No override object, or none for THIS stage ->
        -- `?` yields NULL/false -> the ELSE arm reproduces the prior behavior
        -- byte-for-byte (the shared-pipeline rules alone). Additive + safe:
        -- existing items carry route_on_override = NULL.
        v_route := CASE
            WHEN v_wi.route_on_override ? v_completing
            THEN COALESCE(v_wi.route_on_override -> v_completing, '[]'::jsonb)
                 || COALESCE(v_stage->'route_on', '[]'::jsonb)
            ELSE v_stage->'route_on'
        END;
        IF v_route IS NOT NULL AND jsonb_typeof(v_route) = 'array' THEN
            FOR v_rule IN SELECT * FROM jsonb_array_elements(v_route) LOOP
                v_when   := v_rule->>'when';
                v_unless := v_rule->>'unless';
                CONTINUE WHEN NOT ((v_when IS NULL OR v_out ~* v_when)
                                   AND (v_unless IS NULL OR v_out !~* v_unless));

                v_goto := v_rule->>'goto';
                v_max  := (v_rule->>'max')::int;          -- NULL if absent
                v_count := CASE WHEN v_rule->>'count_key' IS NOT NULL
                                THEN COALESCE((v_wi.input->>(v_rule->>'count_key'))::int, 0)
                                ELSE 0 END;

                -- capped: stop looping (on_max_goto, else on_max_status)
                IF v_max IS NOT NULL AND v_count >= v_max THEN
                    IF v_rule->>'on_max_goto' IS NOT NULL THEN
                        UPDATE stewards.work_items
                           SET stage_results = v_results,
                               current_stage = v_rule->>'on_max_goto',
                               status        = 'pending',
                               updated_at    = now()
                         WHERE id = p_work_item_id;
                        RETURN v_rule->>'on_max_goto';
                    END IF;
                    UPDATE stewards.work_items
                       SET stage_results     = v_results,
                           status            = COALESCE(v_rule->>'on_max_status','awaiting_review'),
                           quarantine_reason = COALESCE(quarantine_reason, v_rule->>'on_max_reason'),
                           error             = COALESCE(error, v_rule->>'on_max_reason'),
                           updated_at        = now()
                     WHERE id = p_work_item_id;
                    RETURN NULL;
                END IF;

                -- goto null -> halt (per-stage cancel)
                IF v_goto IS NULL THEN
                    UPDATE stewards.work_items
                       SET stage_results       = v_results,
                           status              = 'cancelled',
                           last_failure_reason = COALESCE(v_rule->>'on_max_reason',
                               format('route_on halt: stage "%s" matched a null-goto rule', v_completing)),
                           updated_at          = now()
                     WHERE id = p_work_item_id;
                    RETURN NULL;
                END IF;

                -- global infinite-loop backstop (misconfigured uncapped loop)
                v_hops := COALESCE((v_results->'_route_hops'->>v_completing)::int, 0) + 1;
                IF v_hops > v_hop_cap THEN
                    UPDATE stewards.work_items
                       SET stage_results     = v_results,
                           status            = 'awaiting_review',
                           quarantine_reason = COALESCE(quarantine_reason,
                               format('route_on: stage "%s" exceeded %s hops (loop guard)', v_completing, v_hop_cap)),
                           updated_at        = now()
                     WHERE id = p_work_item_id;
                    RETURN NULL;
                END IF;

                -- route (loop back or skip): set goto, inject feedback + counter
                UPDATE stewards.work_items
                   SET stage_results = jsonb_set(v_results, ARRAY['_route_hops', v_completing],
                                                 to_jsonb(v_hops), true),
                       current_stage = v_goto,
                       input         = input
                         || CASE WHEN v_rule->>'feedback_key' IS NOT NULL
                                 THEN jsonb_build_object(v_rule->>'feedback_key', v_out)
                                 ELSE '{}'::jsonb END
                         || CASE WHEN v_rule->>'count_key' IS NOT NULL
                                 THEN jsonb_build_object(v_rule->>'count_key', v_count + 1)
                                 ELSE '{}'::jsonb END,
                       status        = 'pending',
                       updated_at    = now()
                 WHERE id = p_work_item_id;
                RETURN v_goto;
            END LOOP;
        END IF;
    END;

    -- ----- maturity advance hook (forward-only) -----
    SELECT produces_maturity INTO v_new_maturity
      FROM stewards.pipeline_stage_maturity
     WHERE pipeline_family = v_wi.pipeline_family
       AND stage_name      = v_completing;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    IF v_new_maturity IS NOT NULL AND v_pipeline.maturity_ladder IS NOT NULL THEN
        SELECT pos - 1 INTO v_current_idx
          FROM jsonb_array_elements_text(v_pipeline.maturity_ladder)
          WITH ORDINALITY AS t(rung, pos)
         WHERE rung = COALESCE(v_wi.maturity, 'raw');

        SELECT pos - 1 INTO v_new_idx
          FROM jsonb_array_elements_text(v_pipeline.maturity_ladder)
          WITH ORDINALITY AS t(rung, pos)
         WHERE rung = v_new_maturity;

        IF v_current_idx IS NOT NULL AND v_new_idx IS NOT NULL AND v_new_idx > v_current_idx THEN
            NULL;
        ELSE
            v_new_maturity := NULL;
        END IF;
    END IF;

    IF v_next_name IS NULL OR v_next_name = '' THEN
        UPDATE stewards.work_items
           SET stage_results = v_results,
               status        = 'completed',
               completed_at  = now(),
               maturity      = COALESCE(v_new_maturity, maturity),
               updated_at    = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    IF stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_next_name) IS NULL THEN
        RAISE EXCEPTION
            'work_item %: stage %s `next` references missing stage %',
            p_work_item_id, v_completing, v_next_name;
    END IF;

    UPDATE stewards.work_items
       SET stage_results = v_results,
           current_stage = v_next_name,
           status        = CASE WHEN v_auto_advance THEN 'pending'
                                ELSE 'awaiting_review' END,
           maturity      = COALESCE(v_new_maturity, maturity),
           updated_at    = now()
     WHERE id = p_work_item_id;

    RETURN v_next_name;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_advance(uuid, jsonb) IS
'v33 (W2, re-authors v09''s route_on body): stage-completion advance — empty-source halt, then route_on, then maturity + forward advance. NEW: route_on now merges the per-item work_items.route_on_override[current_stage] AHEAD of the shared pipeline stage''s own route_on (first-match-wins), so a war-game''s translated forks route ONE mission without editing the shared pipeline template. No override (route_on_override NULL, or no entry for this stage) -> byte-identical prior behavior. Everything else carried verbatim from v09.';

-- =====================================================================
-- End of v33-wargame-w2.sql
-- =====================================================================
