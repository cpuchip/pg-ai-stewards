-- =====================================================================
-- 42-route-on.sql — the route_on primitive (A): data-driven conditional /
-- loop-back stage routing.
-- =====================================================================
-- Re-authors work_item_advance (final form in 20-coder §8) to REPLACE the two
-- hardcoded code-pr loop-backs (cv6 review->implement, cv11 plan_review->plan)
-- with ONE generic, data-driven evaluator. Everything else — load/validate,
-- stage_results recording, the empty-source halt_on, the maturity hook, and the
-- normal forward advance — is preserved verbatim.
--
-- A stage declares routing in its own jsonb:
--   "route_on": [ { when?, unless?, goto, feedback_key?, count_key?, max?,
--                   on_max_goto?, on_max_status?, on_max_reason? } ]
-- Evaluated (in order, first match wins) against the completing stage's text
-- output. A rule FIRES when its `when` regex matches (or is absent) AND its
-- `unless` regex does NOT match (or is absent), case-insensitive.
--   goto = an EARLIER stage  -> loop back     (study workflow: critical -> gather)
--   goto = a  LATER  stage   -> skip forward
--   goto = null              -> halt (cancel)  (generalizes halt_on per-stage)
-- Loop guard: a looping rule should carry { count_key, max } — the counter lives
-- in work_items.input; on reaching max the rule routes to on_max_goto (else sets
-- on_max_status, default awaiting_review). A hard global hop ceiling
-- (route_on_max_hops, default 50) backstops a misconfigured infinite loop.
-- feedback_key (optional) injects the completing stage's output into input under
-- that key (so the looped-to stage sees why it was sent back).
--
-- No route_on, or no rule matches -> fall through to the normal advance.
-- requires: create_memory_tend (41) — tail of the chain; this is a pure
-- re-author of work_item_advance, no new tables.
-- =====================================================================

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
        v_route := v_stage->'route_on';
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

-- ----- migrate code-pr off the retired hardcoded loop-backs to route_on data -----
-- review: loop to implement UNLESS the verdict line says "REVIEW: passes"; cap 2,
--   then awaiting_review (cv6). plan_review: loop to plan UNLESS "PLAN: approved";
--   cap 2, then proceed to implement (cv11). The dispatch-stage critic-immunity
--   branch (cv7/cv10) in 20-coder §9 is untouched.
UPDATE stewards.pipelines p SET stages = (
    SELECT jsonb_agg(
        CASE
            WHEN elem->>'name' = 'review' THEN elem || jsonb_build_object('route_on', jsonb_build_array(
                jsonb_build_object(
                    'unless', '(^|\n)\s*REVIEW:\s*passes',
                    'goto', 'implement',
                    'feedback_key', 'review_feedback',
                    'count_key', 'revise_count',
                    'max', 2,
                    'on_max_status', 'awaiting_review',
                    'on_max_reason', 'critic review deficient after revise cap; needs a human')))
            WHEN elem->>'name' = 'plan_review' THEN elem || jsonb_build_object('route_on', jsonb_build_array(
                jsonb_build_object(
                    'unless', '(^|\n)\s*PLAN:\s*approved',
                    'goto', 'plan',
                    'feedback_key', 'plan_feedback',
                    'count_key', 'plan_revise_count',
                    'max', 2,
                    'on_max_goto', 'implement')))
            ELSE elem
        END ORDER BY ord)
    FROM jsonb_array_elements(p.stages) WITH ORDINALITY AS t(elem, ord))
WHERE p.family = 'code-pr';

-- =====================================================================
-- End of 42-route-on.sql
-- =====================================================================
