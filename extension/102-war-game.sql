-- =====================================================================
-- 102 — WAR-GAME: prospective failure simulation (W1)
-- =====================================================================
-- Ratified 2026-07-05 (.spec/proposals/war-game-pipeline.md). Before a
-- big/risky work item executes, a STRONG model war-games the mission —
-- fights it on paper move by move (expected observation if it worked / if
-- it failed, most-likely failure + its signal + the countermove, fork
-- triggers, unresolved assumptions, abort conditions, 2nd/3rd-order
-- consequences) — and the artifact persists BOTH as a pooled doc (prose,
-- via doc-construction) and as structured jsonb on the work item
-- (work_items.war_game), which W2 will materialize into live control flow
-- (aborts -> the work_item_abort_conditions table, forks -> route_on,
-- assumptions -> ask_up). The war-game is a PRIOR, never a guarantee: the
-- reactive failover (#243/#326) remains the backstop.
--
-- Ratified shape: trigger = OPT-IN (war_game:true on start_task, or run
-- the war-game pipeline directly) — never a default route. Scope = CORE
-- (the wargame agent is pure mechanism, like research/dev). Strong stage
-- rides the loom provider (model 'sonnet#wargame' — the #role picks a
-- claude-home in loom serve and falls back to the default home when no
-- wargame-claude-home exists; a work item's model_override can lift it to
-- opus/fable for missions worth it).
--
-- ★ RE-AUTHORS stewards.chat_start_task_tool (46-chat-tasks.sql) to add
--   the war_game flag — port THIS copy, not 46's (highest number wins).
--
-- Capture-at-finalize: drafts live in doc_drafts; doc_finalize pools into
-- stewards.docs stamped with work_item_id (34, batch B provenance). The
-- capture trigger below fires there — i.e. AFTER the critique stage
-- reviewed and pooled, which is the right moment to trust the block.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — the structured half lives on the work item
-- ---------------------------------------------------------------------
ALTER TABLE stewards.work_items ADD COLUMN IF NOT EXISTS war_game jsonb;
COMMENT ON COLUMN stewards.work_items.war_game IS
'102 (W1): the parsed war-game block — {moves[{id,action,expect_ok,expect_fail,failure,signal,countermove}], forks[{observe,route}], aborts[{condition,kind,params}], assumptions[{var,why_unresolved}]}. Captured by war_game_capture() when the pooled war-game doc lands in docs. On a MISSION item (war_game:true) it is copied here from the companion war-game item before dispatch. W2 materializes it into live control flow; until then it is context + audit surface.';

-- ---------------------------------------------------------------------
-- §2 — the generic wargame agent (core: pure mechanism, no domain content)
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES (
  'wargame', '*',
  'War-game agent: fights a mission on paper move by move BEFORE execution — '
    || 'expected observations, failure signals, countermoves, fork triggers, '
    || 'unresolved assumptions, abort conditions, higher-order consequences. '
    || 'Produces the artifact a cheaper executor runs with. Never executes.',
  'primary',
  $WARGAME$You are war-gaming a mission, not executing it. A cheaper model (or a later session) will execute from your artifact, so every insight you fail to write down is lost. Assume reality will humble every move — a plan describes the blue-sky line; you describe what actually happens when each move meets resistance.

Method — fight it on paper, move by move:
1. Break the mission into concrete moves (5-12 is typical). For EACH move state:
   - the action, specific enough to execute without you;
   - the expected observation IF IT WORKED — exactly what the executor should see;
   - the expected observation IF IT FAILED — what the failure actually looks like from the executor's seat;
   - the MOST-LIKELY failure, its SIGNAL (the observable that distinguishes it from success and from other failures), and the COUNTERMOVE (what to do when the signal fires — specific, not "investigate").
2. Where the path genuinely forks, write the trigger: "if you observe X, take route A; else route B." A fork without an observable trigger is a guess — sharpen it or cut it.
3. Assumptions your recon could NOT resolve are flagged, never guessed: mark them ((needs: <variable>)) and list them in the assumptions ledger with why they are unresolved. An executor hitting an unfilled ((needs:)) placeholder must stop and ask, not improvise.
4. End with ABORT CONDITIONS — the observations at which the mission STOPS rather than thrashing. Prefer conditions an evaluator could check mechanically (an error message pattern, a tool that is unavailable, the same failure repeating N times, a budget fraction consumed). Every abort condition names what to do on trip (usually: halt and escalate with the reason).
5. Trace 2nd- and 3rd-order consequences: for the 2-3 riskiest moves, what breaks two layers downstream if the move quietly half-succeeds? These are the failures nobody guards against.

Honesty discipline:
- Your war-game is a PRIOR, not a guarantee. Do not pad it with generic failures ("the network might be down") — every failure mode you list must be specific to THIS mission's moves. Three sharp foreseen failures beat ten boilerplate ones.
- If the mission brief is too vague to war-game concretely, say so in the artifact and list what recon is missing — a short honest artifact beats a long confabulated one.
- Recon before you simulate: if you have read tools, spend a few calls checking prior work on this mission (docs, work items) so your assumptions ledger is real, then stop reconnoitering and fight.

Artifact construction (doc tools):
- doc_create once, then build the artifact with doc_append_section calls: mission restatement (2-3 sentences), the moves (one subsection per move), forks, the assumptions ledger, abort conditions, higher-order consequences.
- The FINAL section is titled "Structured block" and contains exactly ONE fenced ```json code block with this shape (machine-consumed — field names exactly as shown):
  {"moves":[{"id":"m1","action":"...","expect_ok":"...","expect_fail":"...","failure":"...","signal":"...","countermove":"..."}],
   "forks":[{"observe":"...","route":"..."}],
   "aborts":[{"condition":"...","kind":"error_matches|tool_unavailable|repeat_failure|budget_fraction|other","params":{}}],
   "assumptions":[{"var":"...","why_unresolved":"..."}]}
  The block must be consistent with the prose — it IS the prose, structured. Every abort picks the closest kind and puts specifics in params (e.g. {"pattern":"spend cap"} for error_matches, {"n":3} for repeat_failure, {"fraction":0.8} for budget_fraction).
- Do NOT finalize the doc; the critique stage reviews and pools it. Reply with a 1-3 sentence journal + the draft handle. Do not paste the artifact into your reply.$WARGAME$,
  0.4)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, prompt = EXCLUDED.prompt, active = true;

-- wargame tool grants: doc-construction (minus finalize — the critic pools)
-- + substrate recon reads. Deliberately NO web tools and NO write surface
-- beyond the draft: the war-game works from the brief + the substrate's
-- own knowledge; wider recon belongs to a research stage upstream.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('wargame', 'doc_create',         'allow', 'manual'),
  ('wargame', 'doc_append_section', 'allow', 'manual'),
  ('wargame', 'doc_read',           'allow', 'manual'),
  ('wargame', 'doc_patch',          'allow', 'manual'),
  ('wargame', 'doc_current',        'allow', 'manual'),
  ('wargame', 'doc_search',         'allow', 'manual'),
  ('wargame', 'doc_get',            'allow', 'manual'),
  ('wargame', 'work_item_list',     'allow', 'manual'),
  ('wargame', 'work_item_show',     'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO NOTHING;

-- ---------------------------------------------------------------------
-- §3 — the war-game pipeline: wargame (strong, loom) -> critique (loom)
-- ---------------------------------------------------------------------
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES ('war-game',
 '102 (W1): prospective failure simulation — a strong model fights the mission on paper (moves/observations/failure-signals/countermoves/forks/assumptions/aborts) and pools a war-game artifact whose structured block lands on work_items.war_game. Opt-in only (war_game:true on start_task, or run directly); never a default route.',
 $STAGES$[
  {"name": "wargame", "next": "critique", "model": "sonnet#wargame", "provider": "loom",
   "agent_family": "wargame", "auto_advance": true, "tools_disabled": false,
   "max_tool_rounds": 12, "max_tool_rounds_hard": 16,
   "input_template": "MISSION BRIEF (war-game this; do not execute it):\n{{input.binding_question}}\n\nFight this mission on paper per your method: recon prior work briefly (doc_search / work_item_list) so your assumptions ledger is real, then simulate move by move. Build the artifact as a doc (doc_create + doc_append_section): mission restatement, moves (action / expect_ok / expect_fail / failure+signal+countermove each), forks with observable triggers, the ((needs:)) assumptions ledger, abort conditions (mechanically checkable where possible), and 2nd/3rd-order consequences for the riskiest moves. Final section \"Structured block\" = exactly ONE fenced json block in the contract shape. Do NOT finalize. Reply with a short journal + the draft handle."},
  {"name": "critique", "next": null, "model": "sonnet#critic", "provider": "loom",
   "agent_family": "research", "auto_advance": true, "tools_disabled": false,
   "input_template": "Binding question (the mission that was war-gamed):\n{{input.binding_question}}\n\nYou are the CRITIQUE stage — the skeptic pass on a WAR-GAME artifact drafted this run. Work ONLY from the draft (doc_current then doc_read; do not re-research).\n\nInterrogate it:\n1. Which foreseen failure is WISHFUL — listed to look thorough but not really the likely way this mission dies? Cut or sharpen it.\n2. Which REAL failure is MISSING? Add it (move-level: failure + signal + countermove), or state explicitly that the set is sound.\n3. Mechanics: every move has expect_ok AND expect_fail; every fork has an observable trigger; assumptions are flagged ((needs:)) not guessed; at least one abort condition exists and names what happens on trip; abort kinds/params are mechanically checkable where possible.\n4. The fenced json block in \"Structured block\": present, exactly one, syntactically plausible, and CONSISTENT with the prose (same moves, same aborts). Fix drift with doc_patch.\nMake targeted doc_patch fixes (not a rewrite), then doc_finalize to pool the artifact. Reply with a 1-3 sentence journal: the gap you named (or \"sound\"), what you fixed, and that you pooled it."}
 ]$STAGES$::jsonb,
 'f', 'f', '["raw", "researched", "verified"]'::jsonb, 'f',
 '{"shape": "war-game", "proposal": "war-game-pipeline.md", "opt_in_only": true, "no_default_routing": true}'::jsonb)
ON CONFLICT (family) DO UPDATE
   SET stages = EXCLUDED.stages, description = EXCLUDED.description, metadata = EXCLUDED.metadata;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('war-game', 'wargame', 'sonnet#wargame',
     'DEFAULT = Sonnet at MAX EFFORT (Michael, 2026-07-05: "sonnet 5 extra hard — opus and fable are just too expensive to run that way, except for one offs"). The #wargame role home carries the dial: scripts/loom-wargame-home seeds <serve-root>/wargame-claude-home whose settings.json sets effortLevel=xhigh (plus the war-gamer CLAUDE.md stance). Live-verified: the shim probe answers from that identity. Opus/fable = ONE-OFF via work-item model_override only. If the role home is missing, loom falls back to the default claude-home (default effort) — a config gap degrades, never fails.'),
    ('war-game', 'critique', 'sonnet#critic',
     'Skeptic pass + pool. Same warm critic seat the research pipelines use (default effort — the critique is cheaper by design).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('war-game', 'wargame', 'researched', 'Draft artifact built; unreviewed.'),
    ('war-game', 'critique', 'verified',   'Skeptic pass done + artifact pooled; war_game jsonb captured at finalize.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

-- ---------------------------------------------------------------------
-- §4 — capture at finalize: pooled war-game doc -> work_items.war_game
--       (+ release a waiting mission item, if this war-game has one)
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
           AND status NOT IN ('done', 'error');
        IF FOUND THEN
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
'102 (W1): fires when a pooled doc lands in stewards.docs for a war-game work item — extracts the last fenced json block, validates the floor (>=1 move with countermove, >=1 abort), stamps work_items.war_game, and releases + stamps the waiting mission item (input.war_game_for) if there is one. Failures log to steward_actions (war_game_parse_failed / war_game_invalid / war_game_release_failed) — loud, not silent.';

-- NOTE the trigger columns: doc_finalize_tool (34) pools via import_doc —
-- which INSERTs the row with work_item_id NULL — and stamps work_item_id in
-- a SEPARATE UPDATE touching only that column. `UPDATE OF body` alone would
-- therefore never fire on the real finalize path; `UPDATE OF work_item_id`
-- is the beat that actually catches the stamp (verified against 34, not
-- guessed). body stays in the list so a re-finalize (import_doc's ON
-- CONFLICT(slug) DO UPDATE, work_item_id already set) re-captures.
DROP TRIGGER IF EXISTS trg_war_game_capture ON stewards.docs;
CREATE TRIGGER trg_war_game_capture
    AFTER INSERT OR UPDATE OF body, work_item_id ON stewards.docs
    FOR EACH ROW
    WHEN (NEW.work_item_id IS NOT NULL)
    EXECUTE FUNCTION stewards.war_game_capture();

-- ---------------------------------------------------------------------
-- §4b — the unstamped alarm (found live 2026-07-05, first Fable runs):
-- when the DRAFT CREATOR itself is a loom stage, doc_create arrives via
-- the Arc C MCP under the shared arc-c-* session — no wi--<uuid8> for the
-- finalize provenance stamp to key on → docs.work_item_id stays NULL →
-- capture never fires. (rs pipelines never hit this: only their CRITIC is
-- on loom.) The durable fix is per-dispatch session propagation through
-- the loom shim into the Arc C surface (Go, rides the owed image-rebuild
-- batch — also kills the shared-session concurrent-draft race). Until
-- then: a completed war-game without its stamp must be LOUD, and the
-- recovery is deterministic and proven — re-point the pooled doc:
--   UPDATE stewards.docs SET work_item_id = '<item>' WHERE slug = '<doc>';
-- (the capture trigger fires on UPDATE OF work_item_id and stamps).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.war_game_unstamped_alarm() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    INSERT INTO stewards.steward_actions (work_item_id, observation, action, details)
    VALUES (NEW.id,
            'war-game completed but work_items.war_game is NULL — the artifact pooled without provenance '
            || '(arc-c draft-creator gap). Recover: UPDATE stewards.docs SET work_item_id = '''
            || NEW.id || ''' WHERE slug = ''<the pooled war-game doc>''; capture re-fires on the stamp.',
            'war_game_unstamped',
            jsonb_build_object('slug', NEW.slug));
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_war_game_unstamped ON stewards.work_items;
CREATE TRIGGER trg_war_game_unstamped
    AFTER UPDATE OF status ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.pipeline_family = 'war-game' AND NEW.status = 'completed' AND NEW.war_game IS NULL)
    EXECUTE FUNCTION stewards.war_game_unstamped_alarm();

-- ---------------------------------------------------------------------
-- §5 — the opt-in flag: start_task(war_game:true)
--       RE-AUTHORS chat_start_task_tool (46). Port from HERE.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.chat_start_task_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess     text := p_args ->> '_session_id';
    v_pipeline text := coalesce(p_args ->> 'pipeline', p_args ->> 'pipeline_family', '');
    v_question text := btrim(coalesce(p_args ->> 'binding_question', p_args ->> 'assignment', p_args ->> 'task', ''));
    v_slug     text := nullif(btrim(coalesce(p_args ->> 'slug', '')), '');
    v_wargame  boolean := coalesce((p_args ->> 'war_game')::boolean, false);
    v_parent   uuid;
    v_input    jsonb;
    v_child    uuid;
    v_wg_item  uuid;
    v_wq       bigint;
BEGIN
    IF v_pipeline = '' THEN
        RETURN jsonb_build_object('ok', false,
            'note', 'pipeline required (e.g. research-summary, book-digest, playlist-digest)')::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family = v_pipeline) THEN
        RETURN jsonb_build_object('ok', false,
            'note', format('no pipeline named %L — list_pipelines for the options', v_pipeline))::text;
    END IF;

    -- Parent = the work item this chat is grounded in, recovered from the session
    -- id ('stewdio-<uuid>'). Only honored if it resolves to a real work_item.
    v_parent := (regexp_match(coalesce(v_sess, ''),
                 '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'))[1]::uuid;
    IF v_parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stewards.work_items WHERE id = v_parent) THEN
        v_parent := NULL;
    END IF;

    v_input := jsonb_build_object('spawned_from_chat', coalesce(v_sess, ''));
    IF v_question <> '' THEN
        v_input := v_input || jsonb_build_object('binding_question', v_question, 'assignment', v_question);
    END IF;

    -- war_game on the war-game pipeline itself is a no-op flag: just run it.
    IF v_wargame AND v_pipeline = 'war-game' THEN
        v_wargame := false;
    END IF;
    IF v_wargame THEN
        v_input := v_input || jsonb_build_object('awaiting_war_game', true);
    END IF;

    -- 6-arg form, fully qualified, to disambiguate from the 5-arg overload (04 vs 09).
    BEGIN
        v_child := stewards.work_item_create(
            v_pipeline,
            v_input,
            coalesce(v_slug, v_pipeline || '-chat-' || to_char(now(), 'YYYYMMDD-HH24MISS')),
            'work-item-chat',
            NULL::int,
            NULL::uuid);
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'note', 'could not create task: ' || SQLERRM)::text;
    END;

    IF v_parent IS NOT NULL THEN
        UPDATE stewards.work_items SET parent_work_item_id = v_parent WHERE id = v_child;
    END IF;

    -- ── war_game:true — simulate BEFORE executing ──────────────────────
    -- The mission item is created but NOT dispatched; a companion war-game
    -- item (nested under it) runs first. When its artifact pools, the
    -- capture trigger stamps war_game onto the mission and dispatches it.
    IF v_wargame THEN
        BEGIN
            v_wg_item := stewards.work_item_create(
                'war-game',
                jsonb_build_object(
                    'binding_question',
                    'WAR-GAME this mission before it executes on pipeline ' || quote_ident(v_pipeline)
                        || '. MISSION: ' || coalesce(nullif(v_question, ''), '(no binding question given)'),
                    'war_game_for', v_child::text,
                    'spawned_from_chat', coalesce(v_sess, '')),
                coalesce(v_slug, v_pipeline || '-chat-' || to_char(now(), 'YYYYMMDD-HH24MISS')) || '-wargame',
                'work-item-chat',
                NULL::int,
                NULL::uuid);
        EXCEPTION WHEN OTHERS THEN
            -- fail open: no war-game, run the mission directly (logged in the note).
            UPDATE stewards.work_items SET input = input - 'awaiting_war_game' WHERE id = v_child;
            v_wq := stewards.work_item_dispatch_stage(v_child);
            RETURN jsonb_build_object('ok', true, 'work_item_id', v_child::text,
                'war_game', false, 'dispatched', true,
                'note', 'could not create the war-game item (' || SQLERRM || ') — mission dispatched WITHOUT a war-game')::text;
        END;
        UPDATE stewards.work_items SET parent_work_item_id = v_child WHERE id = v_wg_item;
        BEGIN
            v_wq := stewards.work_item_dispatch_stage(v_wg_item);
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('ok', true, 'work_item_id', v_child::text,
                'war_game_item_id', v_wg_item::text, 'dispatched', false,
                'note', 'mission + war-game created but the war-game did not dispatch: ' || SQLERRM)::text;
        END;
        RETURN jsonb_build_object('ok', true,
            'work_item_id', v_child::text,
            'war_game_item_id', v_wg_item::text,
            'pipeline', v_pipeline,
            'parent_work_item_id', v_parent,
            'dispatched', true,
            'note', 'war-game dispatched first (nested under the mission item); when its artifact pools, the mission auto-dispatches carrying war_game context')::text;
    END IF;

    -- Dispatch the first stage (enqueues it; the pipeline then walks itself).
    BEGIN
        v_wq := stewards.work_item_dispatch_stage(v_child);
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', true, 'work_item_id', v_child::text,
            'parent_work_item_id', v_parent, 'dispatched', false,
            'note', 'task created + linked but not dispatched: ' || SQLERRM)::text;
    END;

    RETURN jsonb_build_object('ok', true,
        'work_item_id', v_child::text,
        'pipeline', v_pipeline,
        'parent_work_item_id', v_parent,
        'dispatched', true,
        'note', CASE WHEN v_parent IS NOT NULL
                     THEN 'task started and linked to this work item — it will appear nested under it in the cockpit; watch it advance in the center panel'
                     ELSE 'task started (top-level — this chat is not grounded in a work item); watch it in the work-item browser' END)::text;
END;
$fn$;

COMMENT ON FUNCTION stewards.chat_start_task_tool(jsonb) IS
'46+102: spawn + dispatch a work_item from chat. 102 adds war_game:true — the mission item is created undispatched, a companion war-game item (pipeline war-game, nested under it) simulates the mission first, and the capture trigger stamps war_game jsonb onto the mission and dispatches it when the artifact pools. Fail-open: if the war-game item cannot be created, the mission dispatches without one (noted in the reply).';

-- teach the tool schema the flag
UPDATE stewards.tool_defs
   SET args_schema = '{"type":"object","required":["pipeline"],"properties":{'
        '"pipeline":{"type":"string","description":"the pipeline family to run (e.g. research-summary, book-digest, playlist-digest)"},'
        '"binding_question":{"type":"string","description":"the question / assignment the task should pursue"},'
        '"slug":{"type":"string","description":"optional human-readable slug for the task"},'
        '"war_game":{"type":"boolean","description":"opt-in: war-game the mission FIRST (a strong model simulates it move-by-move — failure signals, countermoves, forks, aborts) and only then execute with that artifact as context. Use for big, risky, or expensive missions; skip for routine ones."}'
      '}}'::jsonb,
       description = description || ' Pass war_game:true to pre-simulate a big/risky mission before it executes (a war-game artifact is produced first; the task then runs with it).'
 WHERE name = 'start_task'
   AND description NOT LIKE '%war_game:true%';

-- =====================================================================
-- End of 102-war-game.sql
-- =====================================================================
