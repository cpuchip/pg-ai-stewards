-- =====================================================================
-- 46 — chat delegation: let a work-item chat START A TASK (sub work_item)
-- =====================================================================
-- Stewdio's chat (45) is grounded, retrieval-only Q&A — the "Ask" mode. This
-- adds the "Delegate" mode: when the user asks for actual WORK ("go research X
-- across the corpus", "digest this book"), the chat can spawn a real work_item
-- that runs a pipeline asynchronously, and the user watches it in the cockpit's
-- plan=progress panel. The spawned task LINKS BACK TO THE PARENT — the work
-- item the chat is grounded in — so it nests under it in the browser and its
-- lineage is traceable.
--
-- Reliable parent linkage (not model-guessed): a chat grounded on a work_item
-- has the session id 'stewdio-<work_item_uuid>' (chatSessionFor preserves the
-- uuid). start_task resolves the parent from the session id server-side, so the
-- link is correct regardless of what the model passes. A chat grounded on a doc
-- (slug session) or an empty chat spawns a TOP-LEVEL task (no parent) — graceful.
--
-- Capability note: this crosses the chat agent's read-only boundary (it can now
-- create + dispatch a work_item). Authorized in council 2026-06-23 (Michael:
-- "lets get sub work_item working and it needs to link back to the parent") —
-- dominion_in_council satisfied. The chat only spawns what the human asks for.
-- requires create_work_item_chat (45). Generic core.
-- =====================================================================

-- ── chat_start_task_tool — create + parent-link + dispatch a sub work_item ──
CREATE OR REPLACE FUNCTION stewards.chat_start_task_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess     text := p_args ->> '_session_id';
    v_pipeline text := coalesce(p_args ->> 'pipeline', p_args ->> 'pipeline_family', '');
    v_question text := btrim(coalesce(p_args ->> 'binding_question', p_args ->> 'assignment', p_args ->> 'task', ''));
    v_slug     text := nullif(btrim(coalesce(p_args ->> 'slug', '')), '');
    v_parent   uuid;
    v_input    jsonb;
    v_child    uuid;
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

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'start_task',
  'DELEGATE a piece of work: spawn a new work_item that runs a pipeline asynchronously, and the user watches it advance in the cockpit. Use this when the user asks you to GO DO something substantial (research a topic across a corpus, digest a book/video, run an analysis) rather than answer a question. The task links back to the work item this chat is about. Pass the pipeline family + a binding question / assignment. Returns the new work_item id; tell the user you have started it and they can watch its progress.',
  '{"type":"object","required":["pipeline"],"properties":{'
    '"pipeline":{"type":"string","description":"the pipeline family to run (e.g. research-summary, book-digest, playlist-digest)"},'
    '"binding_question":{"type":"string","description":"the question / assignment the task should pursue"},'
    '"slug":{"type":"string","description":"optional human-readable slug for the task"}'
  '}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"chat_start_task_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- grant it to the chat agent (the deny '*' base means this explicit allow is needed)
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'start_task', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- The 45 prompt declares the chat read-only; it now has ONE write tool (start_task).
-- Soften that line + teach the Ask vs Delegate split, in place.
UPDATE stewards.agents
   SET prompt = replace(prompt,
       'You have read-only tools; you do not write or modify anything.',
       'Default to ANSWERING from what you retrieve (read-only). The one exception: if the user asks you to GO DO substantial work — research a topic across a corpus, digest a book or video, run an analysis — call start_task to spawn a work_item that runs that pipeline, then tell them you have started it and they can watch its progress in the cockpit. Ask before starting a task if the request is ambiguous.')
 WHERE family = 'work-item-chat' AND model_match = '*';

-- =====================================================================
-- End of 46-chat-tasks.sql
-- =====================================================================
