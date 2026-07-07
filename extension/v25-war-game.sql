-- ===== [was 102-war-game.sql] =====
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
-- ★ 103-abort-conditions.sql RE-AUTHORS war_game_capture (adds: arming a
--   work_item_abort_conditions row per aborts[] entry on the release path)
--   — port THAT copy, not this one, if this function is touched again
--   (highest number wins).
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
           -- BUG (kept for the record, FIXED in 103's re-authored copy which
           -- is the live one): 'done'/'error' are not valid work_items
           -- statuses, so this guard was always-true. 103 uses
           -- status = 'pending' — only a still-waiting mission releases.
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
-- ===== [was 103-abort-conditions.sql] =====
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
