-- ===== [was 69-a2a-engine.sql] =====
-- =====================================================================
-- 69-a2a-engine.sql — A2A / Open Engine: agents hand work to agents
-- =====================================================================
-- The substrate turned OUTWARD. Until now a work_item was something the
-- bgworker ran (a pipeline). This file adds the one genuinely-new
-- primitive: the *externally-executed* work_item — "here is a task; YOU
-- go do it in your environment; come back with the artifact + a
-- receipt." That is exactly the escalation claim-lock
-- (escalation_state / escalation_claimed_by, 04+07), generalized from
-- "a stronger model rescues a stuck pipeline stage" to "any registered
-- agent claims an ASSIGNED task it didn't create, works it, resolves it."
--
-- It also migrates the beloved `.mind/sessions/` inbox into the
-- substrate as two panes — NOTES (things said to me) + TODOS (work
-- assigned to me) — both surfaced by one pull. The file inbox was our
-- v0 A2A protocol; this generalizes what already worked. The MCP/Go
-- layer best-effort mirror-writes notes+todos back to those files so a
-- substrate-down agent still reads the last-known state (availability,
-- never correctness — the substrate is the source of truth).
--
-- Design ratified 2026-06-26 (.spec/proposals/a2a-open-engine.md §6):
--   • v1 = my agents first (Claude sessions + agy + personas), local.
--   • Reuse work_items (one system of record); the claim primitive
--     already lives there. Names aligned to Google's A2A standard
--     (Task ↔ work_item, lifecycle queued→in_progress→resolved) so the
--     Agent-Card / JSON-RPC wrapper (Phase 2) is a thin edge adapter,
--     not a rewrite.
--   • Lane = the durable agent identity for my sessions.
--   • Build in OSS core — the engine is the substrate's reason-for-being.
--     (Registry seeds + external auth tokens stay in the overlay.)
--
-- A2A lifecycle ↔ substrate state:
--   SUBMITTED      escalation_state='queued'      (assigned, awaiting claim)
--   WORKING        escalation_state='in_progress' (claimed)
--   INPUT_REQUIRED escalation_state='in_progress' + a2a_question set
--                                                  + status='awaiting_review'
--   COMPLETED      escalation_state='resolved'    + status='completed'
--   FAILED         escalation_state='failed'      + status='failed'
--
-- requires create_model_fallback_hardening (68) — installs at the tail.
-- Generic core: machinery only. NO operator agents/tokens are seeded
-- (those are overlay data); only the inert holding pipeline + the
-- drive-the-engine capability skill, both of which describe the engine
-- itself, ship in core.
-- =====================================================================

-- ---------------------------------------------------------------------
-- a2a_agents — the participant registry (generalizes session lanes).
--
-- A row per agent that can hand work to / claim work from the engine:
-- my Claude Code sessions (kind=session, identified by their lane),
-- daemons (agy, garrison, persona-host), the substrate's own personas,
-- and — Phase 3 — other people's external agents (token-authed).
-- This is NOT stewards.agents (that table is the pipeline agent-FAMILY
-- registry — prompts/steps/model_match). This is the A2A *participant*
-- registry: identity + capabilities + delivery + the D&C 121 scope wall.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.a2a_agents (
    agent_id      text PRIMARY KEY
                  CHECK (agent_id ~ '^[a-z0-9][a-z0-9:_-]*$'),
    kind          text NOT NULL DEFAULT 'session'
                  CHECK (kind IN ('session','daemon','persona','external')),
    display_name  text NOT NULL,
    -- The .mind/sessions/<lane> identity a Claude session inhabits
    -- (nullable; daemons/personas/external have none).
    lane          text,
    -- Skills the agent offers → its A2A Agent Card skills[] (Phase 2).
    capabilities  jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- How work reaches it: pull-on-engagement (Claude sessions — the
    -- proven 📬 model), heartbeat-poll (daemons), webhook (external).
    delivery      text NOT NULL DEFAULT 'pull'
                  CHECK (delivery IN ('pull','heartbeat','webhook')),
    endpoint      text,            -- webhook/external callback URL
    -- The D&C 121 wall: which projects / intents / tools this agent may
    -- touch. Empty = no explicit grant (Phase 2 enforces; Phase 1 records).
    scope         jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- External auth (overlay seeds a sha256 of a minted hub token);
    -- NULL for my local agents (trusted by proximity in Phase 1).
    token_hash    text,
    registered_at timestamptz NOT NULL DEFAULT now(),
    last_seen     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.a2a_agents IS
'A2A participant registry — every agent that can hand work to / claim work from the engine. Distinct from stewards.agents (pipeline agent families). lane links a Claude session to its .mind/sessions identity; capabilities → the Agent Card; scope is the D&C 121 wall; token_hash auths external agents (Phase 3).';

CREATE INDEX IF NOT EXISTS a2a_agents_kind_idx ON stewards.a2a_agents(kind);
CREATE INDEX IF NOT EXISTS a2a_agents_lane_idx  ON stewards.a2a_agents(lane)
    WHERE lane IS NOT NULL;

-- ---------------------------------------------------------------------
-- agent_notes — the NOTES pane of the migrated inbox.
--
-- An async message addressed TO an agent ("leave me a note while you're
-- busy"; the v0 .mind/sessions inbox). Distinct from a TODO (assigned
-- work = a work_item). In A2A terms a Message addressed to an agent,
-- not necessarily a Task. kind distinguishes a freeform note from the
-- engine-generated question/answer/receipt threads on a task.
-- Delivery is pull: read on engagement, cleared (acted_at) after acting.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.agent_notes (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    recipient    text NOT NULL,        -- a2a_agents.agent_id (or a lane)
    sender       text,                 -- who wrote it (agent_id / lane / 'human')
    body         text NOT NULL CHECK (length(body) BETWEEN 1 AND 8000),
    kind         text NOT NULL DEFAULT 'note'
                 CHECK (kind IN ('note','question','answer','receipt')),
    work_item_id uuid REFERENCES stewards.work_items(id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    acted_at     timestamptz           -- NULL = unread/unactioned
);

COMMENT ON TABLE stewards.agent_notes IS
'The NOTES pane of the substrate-migrated inbox: async messages addressed to an agent. kind=note is a freeform message; question/answer/receipt are the engine-threaded events on a work_item (a2a_needs_input/a2a_answer/a2a_receipt write these). Pull delivery: read on engagement, acted_at clears them.';

CREATE INDEX IF NOT EXISTS agent_notes_inbox_idx
    ON stewards.agent_notes(recipient, created_at)
    WHERE acted_at IS NULL;

-- ---------------------------------------------------------------------
-- work_items, extended for the assigned/externally-executed task.
--   a2a_assignee — the registered agent the task is handed to.
--   a2a_owner    — who submitted it (so needs_input knows whom to ask).
--   a2a_question — the current INPUT_REQUIRED blocking question (or NULL).
-- origin gains 'a2a' so these are distinguishable provenance.
-- ---------------------------------------------------------------------
ALTER TABLE stewards.work_items
    ADD COLUMN IF NOT EXISTS a2a_assignee text,
    ADD COLUMN IF NOT EXISTS a2a_owner    text,
    ADD COLUMN IF NOT EXISTS a2a_question text;

ALTER TABLE stewards.work_items DROP CONSTRAINT IF EXISTS work_items_origin_check;
ALTER TABLE stewards.work_items ADD CONSTRAINT work_items_origin_check
    CHECK (origin = ANY (ARRAY[
        'human', 'scheduled', 'watchman', 'steward',
        'council', 'agent_planning', 'agent_proposal', 'a2a'
    ]));

CREATE INDEX IF NOT EXISTS work_items_a2a_assignee_idx
    ON stewards.work_items(a2a_assignee, escalation_state)
    WHERE a2a_assignee IS NOT NULL;

-- ---------------------------------------------------------------------
-- The inert holding pipeline. work_items.pipeline_family is NOT NULL +
-- FK, so an assigned task still needs a pipeline. This one is never
-- dispatched to the bgworker — the task waits for its CLAIM. The stage's
-- agent/model/provider are placeholders (the 'research' core agent) so
-- the shape is valid; auto_advance=false + the submit path parking the
-- item at status='awaiting_review' keep the bgworker's hands off it.
-- ---------------------------------------------------------------------
INSERT INTO stewards.pipelines (family, description, stages)
VALUES (
    'a2a-handoff',
    'Inert holding pipeline for A2A assigned tasks. NOT auto-dispatched; the work_item waits for a registered agent to claim it (a2a_claim), work it externally, and resolve it (a2a_receipt). The single stage exists only to satisfy the work_items FK.',
    jsonb_build_array(
        jsonb_build_object(
            'name',         'handoff',
            'agent_family', 'research',
            'model',        'placeholder',
            'provider',     'none',
            'next',         null,
            'auto_advance', false
        )
    )
)
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description,
       stages      = EXCLUDED.stages,
       updated_at  = now();

-- =====================================================================
-- The verbs. All return jsonb (structured for the MCP/API layer; the
-- virgin-smoke oracle asserts on them). Naming + lifecycle align to A2A.
-- =====================================================================

-- ── a2a_register — register/refresh an agent + touch last_seen ────────
CREATE OR REPLACE FUNCTION stewards.a2a_register(
    p_agent_id     text,
    p_display_name text DEFAULT NULL,
    p_kind         text DEFAULT 'session',
    p_lane         text DEFAULT NULL,
    p_capabilities jsonb DEFAULT '[]'::jsonb,
    p_delivery     text DEFAULT 'pull',
    p_endpoint     text DEFAULT NULL,
    p_scope        jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_row stewards.a2a_agents%ROWTYPE;
BEGIN
    IF p_agent_id IS NULL OR p_agent_id = '' THEN
        RAISE EXCEPTION 'a2a_register: agent_id is required';
    END IF;

    INSERT INTO stewards.a2a_agents
        (agent_id, display_name, kind, lane, capabilities, delivery, endpoint, scope, last_seen)
    VALUES
        (p_agent_id,
         coalesce(p_display_name, p_agent_id),
         coalesce(p_kind, 'session'),
         p_lane,
         coalesce(p_capabilities, '[]'::jsonb),
         coalesce(p_delivery, 'pull'),
         p_endpoint,
         coalesce(p_scope, '{}'::jsonb),
         now())
    ON CONFLICT (agent_id) DO UPDATE
       SET display_name = coalesce(EXCLUDED.display_name, stewards.a2a_agents.display_name),
           kind         = EXCLUDED.kind,
           lane         = coalesce(EXCLUDED.lane, stewards.a2a_agents.lane),
           capabilities = EXCLUDED.capabilities,
           delivery     = EXCLUDED.delivery,
           endpoint     = coalesce(EXCLUDED.endpoint, stewards.a2a_agents.endpoint),
           scope        = EXCLUDED.scope,
           last_seen    = now()
    RETURNING * INTO v_row;

    RETURN jsonb_build_object(
        'agent_id',     v_row.agent_id,
        'kind',         v_row.kind,
        'display_name', v_row.display_name,
        'lane',         v_row.lane,
        'delivery',     v_row.delivery,
        'registered',   true
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.a2a_register(text,text,text,text,jsonb,text,text,jsonb) IS
'Register or refresh an A2A agent (upsert; bumps last_seen). agent_id is the durable identity (a lane for Claude sessions). Returns the agent record.';

-- ── a2a_submit — hand a task to an agent (the 7-part ticket) ──────────
-- Creates a work_item ASSIGNED to p_assignee, parked at
-- escalation_state='queued' / status='awaiting_review' (the bgworker
-- never dispatches it). p_spec is the self-contained ticket: outcome,
-- sources, context, allowed_actions, stop_condition, definition_of_done.
-- This IS Nate's "a ticket asks for a result" + the 7-part task record.
-- Drop the prior overload (if a previous apply created the 6-arg form)
-- so re-application leaves exactly one signature — no overload ambiguity.
DROP FUNCTION IF EXISTS stewards.a2a_submit(text,text,jsonb,text,text,text);

CREATE OR REPLACE FUNCTION stewards.a2a_submit(
    p_assignee text,
    p_title    text,
    p_spec     jsonb DEFAULT '{}'::jsonb,
    p_owner    text  DEFAULT NULL,
    p_project  text  DEFAULT NULL,
    p_slug     text  DEFAULT NULL,
    p_intent   text  DEFAULT NULL    -- intent slug; defaults to config default_intent_slug
) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_id        uuid;
    v_input     jsonb;
    v_intent_id uuid;
    v_slug      text;
BEGIN
    IF p_assignee IS NULL OR p_assignee = '' THEN
        RAISE EXCEPTION 'a2a_submit: assignee is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.a2a_agents WHERE agent_id = p_assignee) THEN
        RAISE EXCEPTION 'a2a_submit: assignee % is not a registered agent (call a2a_register first)', p_assignee;
    END IF;
    IF p_title IS NULL OR length(p_title) = 0 THEN
        RAISE EXCEPTION 'a2a_submit: title is required';
    END IF;
    IF p_owner IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM stewards.a2a_agents WHERE agent_id = p_owner) THEN
        RAISE EXCEPTION 'a2a_submit: owner % is not a registered agent', p_owner;
    END IF;

    -- Resolve the intent (work_items.intent_id is NOT NULL). Explicit
    -- slug wins; otherwise the configured default_intent_slug intent,
    -- mirroring work_item_create (09). The engine is intent-agnostic at
    -- this layer — the task just needs a home intent.
    v_slug := coalesce(p_intent, stewards.config_get_text('default_intent_slug', 'default'));
    SELECT id INTO v_intent_id FROM stewards.intents WHERE slug = v_slug;
    IF v_intent_id IS NULL THEN
        RAISE EXCEPTION 'a2a_submit: intent % not found (config default_intent_slug=%)',
            v_slug, stewards.config_get_text('default_intent_slug', 'default');
    END IF;

    -- The ticket: title + the 7-part spec the agent acts on.
    v_input := jsonb_build_object('title', p_title)
            || coalesce(p_spec, '{}'::jsonb);

    INSERT INTO stewards.work_items
        (pipeline_family, current_stage, slug, input, status,
         origin, actor, project_association, intent_id,
         a2a_assignee, a2a_owner, escalation_state)
    VALUES
        ('a2a-handoff', 'handoff', p_slug, v_input, 'awaiting_review',
         'a2a', coalesce(p_owner, 'a2a'), p_project, v_intent_id,
         p_assignee, p_owner, 'queued')
    RETURNING id INTO v_id;

    RETURN jsonb_build_object(
        'work_item_id', v_id,
        'assignee',     p_assignee,
        'owner',        p_owner,
        'title',        p_title,
        'state',        'queued',
        'submitted',    true
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.a2a_submit(text,text,jsonb,text,text,text,text) IS
'Hand a task to a registered agent. Creates an assigned work_item parked at escalation_state=queued (awaiting claim; never bgworker-dispatched). p_spec carries the 7-part ticket (outcome/sources/context/allowed_actions/stop_condition/definition_of_done). p_intent defaults to the config default_intent_slug intent. Returns the work_item_id.';

-- ── a2a_inbox — an agent's home surface: NOTES + TODOS ────────────────
CREATE OR REPLACE FUNCTION stewards.a2a_inbox(p_agent_id text)
RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_notes jsonb;
    v_todos jsonb;
BEGIN
    -- Touch last_seen (engagement = a heartbeat for pull agents).
    UPDATE stewards.a2a_agents SET last_seen = now() WHERE agent_id = p_agent_id;

    -- NOTES pane: unacted messages addressed to me, oldest first.
    SELECT coalesce(jsonb_agg(n ORDER BY n.created_at), '[]'::jsonb)
      INTO v_notes
      FROM (
        SELECT id, sender, body, kind, work_item_id, created_at
          FROM stewards.agent_notes
         WHERE recipient = p_agent_id AND acted_at IS NULL
         ORDER BY created_at
         LIMIT 50
      ) n;

    -- TODOS pane: open work assigned to me (queued or in_progress).
    SELECT coalesce(jsonb_agg(t ORDER BY t.created_at), '[]'::jsonb)
      INTO v_todos
      FROM (
        SELECT id AS work_item_id,
               input->>'title'        AS title,
               a2a_owner              AS owner,
               escalation_state       AS state,
               escalation_claimed_by  AS claimed_by,
               a2a_question           AS blocking_question,
               project_association    AS project,
               created_at
          FROM stewards.work_items
         WHERE a2a_assignee = p_agent_id
           AND escalation_state IN ('queued','in_progress')
         ORDER BY created_at
         LIMIT 50
      ) t;

    RETURN jsonb_build_object(
        'agent_id', p_agent_id,
        'notes',    v_notes,
        'todos',    v_todos,
        'note_count', jsonb_array_length(v_notes),
        'todo_count', jsonb_array_length(v_todos)
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.a2a_inbox(text) IS
'An agent''s home surface: NOTES (unacted messages to me) + TODOS (open work assigned to me). The .mind/sessions inbox, migrated and unified. Touches last_seen.';

-- ── a2a_claim — atomically lock a queued task to me (the claim-lock) ──
-- This IS work_item_escalation_claim, widened from "rescue a stuck
-- pipeline" to "claim an assigned A2A task." The WHERE escalation_state
-- ='queued' is the lock — only one claimer wins queued→in_progress.
CREATE OR REPLACE FUNCTION stewards.a2a_claim(
    p_work_item_id uuid,
    p_claimer      text
) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi stewards.work_items%ROWTYPE;
BEGIN
    IF p_claimer IS NULL OR p_claimer = '' THEN
        RAISE EXCEPTION 'a2a_claim: claimer is required';
    END IF;

    UPDATE stewards.work_items
       SET escalation_state    = 'in_progress',
           escalation_claimed_by = p_claimer,
           escalation_claimed_at = now(),
           escalation_attempts = escalation_attempts + 1,
           status              = 'in_progress',
           updated_at          = now()
     WHERE id = p_work_item_id
       AND escalation_state = 'queued'
    RETURNING * INTO v_wi;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'claimed', false,
            'work_item_id', p_work_item_id,
            'reason', 'not found OR not in escalation_state=queued (already claimed?)'
        );
    END IF;

    UPDATE stewards.a2a_agents SET last_seen = now() WHERE agent_id = p_claimer;

    RETURN jsonb_build_object(
        'claimed',      true,
        'work_item_id', v_wi.id,
        'title',        v_wi.input->>'title',
        'spec',         v_wi.input,
        'owner',        v_wi.a2a_owner,
        'claimed_by',   p_claimer,
        'project',      v_wi.project_association
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.a2a_claim(uuid,text) IS
'Atomically claim a queued assigned task (queued→in_progress). The escalation claim-lock, generalized. Returns the full ticket (input/spec) the claimer needs, or claimed=false if someone else got it.';

-- ── a2a_needs_input — INPUT_REQUIRED: ask the OWNER the exact question ─
-- The Hinge as a first-class handoff state. Parks the task with the
-- blocking question and drops a note into the OWNER's inbox so they see
-- exactly what's blocking and can answer it (a2a_answer).
CREATE OR REPLACE FUNCTION stewards.a2a_needs_input(
    p_work_item_id uuid,
    p_question     text
) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi stewards.work_items%ROWTYPE;
BEGIN
    IF p_question IS NULL OR length(p_question) = 0 THEN
        RAISE EXCEPTION 'a2a_needs_input: question is required (ask the EXACT blocking question)';
    END IF;

    UPDATE stewards.work_items
       SET a2a_question = p_question,
           status       = 'awaiting_review',
           updated_at   = now()
     WHERE id = p_work_item_id
       AND escalation_state = 'in_progress'
    RETURNING * INTO v_wi;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'a2a_needs_input: % not found or not claimed (escalation_state<>in_progress)', p_work_item_id;
    END IF;

    -- Tell the owner (if any) exactly what's blocking.
    IF v_wi.a2a_owner IS NOT NULL THEN
        INSERT INTO stewards.agent_notes (recipient, sender, body, kind, work_item_id)
        VALUES (v_wi.a2a_owner,
                v_wi.escalation_claimed_by,
                format('Task "%s" needs input: %s',
                       coalesce(v_wi.input->>'title','(untitled)'), p_question),
                'question', v_wi.id);
    END IF;

    RETURN jsonb_build_object(
        'work_item_id', v_wi.id,
        'state',        'input_required',
        'question',     p_question,
        'asked_owner',  v_wi.a2a_owner
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.a2a_needs_input(uuid,text) IS
'Mark a claimed task INPUT_REQUIRED: store the exact blocking question and drop a question-note into the owner''s inbox. The Hinge, as a first-class handoff state.';

-- ── a2a_answer — the owner answers a blocked task; unblock the worker ─
CREATE OR REPLACE FUNCTION stewards.a2a_answer(
    p_work_item_id uuid,
    p_answer       text
) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi stewards.work_items%ROWTYPE;
BEGIN
    IF p_answer IS NULL OR length(p_answer) = 0 THEN
        RAISE EXCEPTION 'a2a_answer: answer is required';
    END IF;

    UPDATE stewards.work_items
       SET a2a_question = NULL,
           status       = 'in_progress',
           updated_at   = now()
     WHERE id = p_work_item_id
    RETURNING * INTO v_wi;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'a2a_answer: % not found', p_work_item_id;
    END IF;

    -- Tell the worker (the claimer) the answer so it can resume.
    IF v_wi.escalation_claimed_by IS NOT NULL THEN
        INSERT INTO stewards.agent_notes (recipient, sender, body, kind, work_item_id)
        VALUES (v_wi.escalation_claimed_by,
                v_wi.a2a_owner,
                format('Answer on task "%s": %s',
                       coalesce(v_wi.input->>'title','(untitled)'), p_answer),
                'answer', v_wi.id);
    END IF;

    RETURN jsonb_build_object(
        'work_item_id', v_wi.id,
        'state',        'in_progress',
        'answered_worker', v_wi.escalation_claimed_by
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.a2a_answer(uuid,text) IS
'Answer a blocked (INPUT_REQUIRED) task: clear the question, return the task to in_progress, and drop an answer-note into the worker''s inbox so it can resume.';

-- ── a2a_receipt — post what I did + the artifact + proof; mark done ───
-- This IS the escalation_resolve success path, generalized: store the
-- artifact, move to resolved/completed. The receipt is the accounting —
-- "I want to know it got done." Also drops a receipt-note to the owner.
CREATE OR REPLACE FUNCTION stewards.a2a_receipt(
    p_work_item_id uuid,
    p_summary      text,
    p_artifact     jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi      stewards.work_items%ROWTYPE;
    v_results jsonb;
BEGIN
    IF p_summary IS NULL OR length(p_summary) = 0 THEN
        RAISE EXCEPTION 'a2a_receipt: summary is required (what did you do?)';
    END IF;

    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'a2a_receipt: % not found', p_work_item_id;
    END IF;
    IF v_wi.escalation_state <> 'in_progress' THEN
        RAISE EXCEPTION 'a2a_receipt: % is not claimed (escalation_state=%; claim it first)',
            p_work_item_id, v_wi.escalation_state;
    END IF;

    -- Record the artifact in stage_results under the handoff stage.
    v_results := v_wi.stage_results || jsonb_build_object(
        'handoff', jsonb_build_object(
            'output',       p_summary,
            'artifact',     coalesce(p_artifact, '{}'::jsonb),
            'resolved_by',  v_wi.escalation_claimed_by,
            'source',       'a2a_receipt',
            'completed_at', now()
        ));

    UPDATE stewards.work_items
       SET escalation_state        = 'resolved',
           escalation_completed_at  = now(),
           a2a_question             = NULL,
           stage_results            = v_results,
           status                   = 'completed',
           completed_at             = now(),
           updated_at               = now()
     WHERE id = p_work_item_id;

    -- Receipt to the owner — close the loop the human used to carry.
    IF v_wi.a2a_owner IS NOT NULL THEN
        INSERT INTO stewards.agent_notes (recipient, sender, body, kind, work_item_id)
        VALUES (v_wi.a2a_owner,
                v_wi.escalation_claimed_by,
                format('Done: "%s" — %s',
                       coalesce(v_wi.input->>'title','(untitled)'), p_summary),
                'receipt', v_wi.id);
    END IF;

    RETURN jsonb_build_object(
        'work_item_id', v_wi.id,
        'state',        'resolved',
        'status',       'completed',
        'resolved_by',  v_wi.escalation_claimed_by,
        'receipt_to',   v_wi.a2a_owner
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.a2a_receipt(uuid,text,jsonb) IS
'Resolve an assigned task: store the artifact + summary in stage_results, mark escalation_state=resolved / status=completed, and drop a receipt-note to the owner. The accounting that frees the human from being the messenger.';

-- ── a2a_note — leave an async message in an agent's NOTES pane ────────
CREATE OR REPLACE FUNCTION stewards.a2a_note(
    p_recipient    text,
    p_body         text,
    p_sender       text DEFAULT NULL,
    p_work_item_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_id bigint;
BEGIN
    IF p_recipient IS NULL OR p_recipient = '' THEN
        RAISE EXCEPTION 'a2a_note: recipient is required';
    END IF;
    IF p_body IS NULL OR length(p_body) = 0 THEN
        RAISE EXCEPTION 'a2a_note: body is required';
    END IF;

    INSERT INTO stewards.agent_notes (recipient, sender, body, kind, work_item_id)
    VALUES (p_recipient, p_sender, p_body, 'note', p_work_item_id)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object(
        'note_id',   v_id,
        'recipient', p_recipient,
        'sent',      true
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.a2a_note(text,text,text,uuid) IS
'Leave an async note in an agent''s NOTES pane (the v0 "leave me a note while you''re busy", in the substrate). Pull delivery: the recipient sees it on next engagement.';

-- ── a2a_note_clear — mark notes acted (clears the 📬) ─────────────────
CREATE OR REPLACE FUNCTION stewards.a2a_note_clear(
    p_recipient text,
    p_note_id   bigint DEFAULT NULL   -- NULL = clear all unacted for recipient
) RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_cleared int;
BEGIN
    UPDATE stewards.agent_notes
       SET acted_at = now()
     WHERE recipient = p_recipient
       AND acted_at IS NULL
       AND (p_note_id IS NULL OR id = p_note_id);
    GET DIAGNOSTICS v_cleared = ROW_COUNT;

    RETURN jsonb_build_object(
        'recipient', p_recipient,
        'cleared',   v_cleared
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.a2a_note_clear(text,bigint) IS
'Mark notes acted (acted_at=now). p_note_id NULL clears all unacted notes for the recipient (after acting on your inbox). Returns the count cleared.';

-- =====================================================================
-- Tool wrappers (jsonb args → jsonb) so the verbs are callable from the
-- model's tool_call path, and tool_defs registrations granting them.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.a2a_submit_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
    SELECT stewards.a2a_submit(
        p_args->>'assignee',
        p_args->>'title',
        coalesce(p_args->'spec', '{}'::jsonb),
        p_args->>'owner',
        p_args->>'project',
        p_args->>'slug',
        p_args->>'intent'
    );
$fn$;

CREATE OR REPLACE FUNCTION stewards.a2a_inbox_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
    SELECT stewards.a2a_inbox(p_args->>'agent_id');
$fn$;

CREATE OR REPLACE FUNCTION stewards.a2a_claim_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
    SELECT stewards.a2a_claim((p_args->>'work_item_id')::uuid, p_args->>'claimer');
$fn$;

CREATE OR REPLACE FUNCTION stewards.a2a_needs_input_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
    SELECT stewards.a2a_needs_input((p_args->>'work_item_id')::uuid, p_args->>'question');
$fn$;

CREATE OR REPLACE FUNCTION stewards.a2a_answer_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
    SELECT stewards.a2a_answer((p_args->>'work_item_id')::uuid, p_args->>'answer');
$fn$;

CREATE OR REPLACE FUNCTION stewards.a2a_receipt_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
    SELECT stewards.a2a_receipt(
        (p_args->>'work_item_id')::uuid,
        p_args->>'summary',
        coalesce(p_args->'artifact', '{}'::jsonb)
    );
$fn$;

CREATE OR REPLACE FUNCTION stewards.a2a_note_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
    SELECT stewards.a2a_note(
        p_args->>'recipient',
        p_args->>'body',
        p_args->>'sender',
        CASE WHEN p_args ? 'work_item_id' AND p_args->>'work_item_id' <> ''
             THEN (p_args->>'work_item_id')::uuid ELSE NULL END
    );
$fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target)
VALUES
(
    'a2a_submit',
    'Hand a task to another agent through the engine. Creates an assigned work_item that waits for the assignee to claim, work, and receipt it — no copy-paste, the work_item is the whole conversation. Provide a self-contained ticket: a clear title, and a `spec` object carrying outcome, sources, context, allowed_actions, stop_condition, and definition_of_done. The assignee must be a registered agent.',
    '{
        "type": "object",
        "required": ["assignee", "title"],
        "properties": {
            "assignee": {"type": "string", "description": "Registered agent_id to assign the task to (e.g. \"agy\", \"lane:pg-ai-stewards\")."},
            "title":    {"type": "string", "minLength": 1, "description": "One-line outcome the ticket asks for."},
            "spec":     {"type": "object", "description": "The 7-part ticket: {outcome, sources, context, allowed_actions, stop_condition, definition_of_done}."},
            "owner":    {"type": "string", "description": "Your agent_id (so the worker can ask you blocking questions and send the receipt). Optional but recommended."},
            "project":  {"type": "string", "description": "Optional project slug to associate."},
            "slug":     {"type": "string", "description": "Optional human-readable slug."},
            "intent":   {"type": "string", "description": "Optional intent slug; defaults to the configured default intent."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"a2a_submit_tool"}'::jsonb
),
(
    'a2a_inbox',
    'Read your engine inbox: NOTES (async messages addressed to you) and TODOS (open work assigned to you, with any blocking question). Pull-delivery — call this on engagement. After acting on a note, clear it so the 📬 goes away.',
    '{
        "type": "object",
        "required": ["agent_id"],
        "properties": {
            "agent_id": {"type": "string", "description": "Your registered agent_id (a lane for Claude sessions)."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"a2a_inbox_tool"}'::jsonb
),
(
    'a2a_claim',
    'Atomically claim a queued task assigned to you so you own it (queued → in_progress). Returns the full ticket/spec you need to do the work. Only one agent can claim a task; if someone already has it you get claimed=false.',
    '{
        "type": "object",
        "required": ["work_item_id", "claimer"],
        "properties": {
            "work_item_id": {"type": "string", "description": "The task''s work_item_id (from a2a_inbox todos)."},
            "claimer":      {"type": "string", "description": "Your agent_id."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"a2a_claim_tool"}'::jsonb
),
(
    'a2a_needs_input',
    'Block a task you are working on with the EXACT question you need answered. The owner gets the question in their inbox and answers it (a2a_answer); you''ll get the answer in yours and can resume. Ask one precise blocking question, not a vague status.',
    '{
        "type": "object",
        "required": ["work_item_id", "question"],
        "properties": {
            "work_item_id": {"type": "string"},
            "question":     {"type": "string", "minLength": 1, "description": "The exact, specific question blocking progress."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"a2a_needs_input_tool"}'::jsonb
),
(
    'a2a_answer',
    'Answer a task that one of your assigned agents blocked with a question (it appeared in your inbox as a question-note). Clears the block and notifies the worker so it can resume.',
    '{
        "type": "object",
        "required": ["work_item_id", "answer"],
        "properties": {
            "work_item_id": {"type": "string"},
            "answer":       {"type": "string", "minLength": 1}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"a2a_answer_tool"}'::jsonb
),
(
    'a2a_receipt',
    'Finish a task you claimed: post a short summary of what you did plus the artifact (links, slugs, output) as proof, and mark it done. The owner gets the receipt in their inbox. This is the accounting that frees the human from carrying state between agents.',
    '{
        "type": "object",
        "required": ["work_item_id", "summary"],
        "properties": {
            "work_item_id": {"type": "string"},
            "summary":      {"type": "string", "minLength": 1, "description": "What you did, in a sentence or two."},
            "artifact":     {"type": "object", "description": "The proof: {doc_slug, url, files, output, ...} — whatever the owner needs to verify and build on."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"a2a_receipt_tool"}'::jsonb
),
(
    'a2a_note',
    'Leave an async note in another agent''s inbox ("here''s something for you when you get to it"). The substrate version of the .mind/sessions inbox. Pull-delivery: they see it on next engagement. Use a2a_submit instead when you want a tracked task with a receipt.',
    '{
        "type": "object",
        "required": ["recipient", "body"],
        "properties": {
            "recipient":    {"type": "string", "description": "The agent_id to leave the note for."},
            "body":         {"type": "string", "minLength": 1},
            "sender":       {"type": "string", "description": "Your agent_id."},
            "work_item_id": {"type": "string", "description": "Optional task this note relates to."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"a2a_note_tool"}'::jsonb
)
ON CONFLICT (name) DO UPDATE
SET description    = EXCLUDED.description,
    args_schema    = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target;

-- ---------------------------------------------------------------------
-- Broadcast the A2A verbs to all non-watchman agents. The engine is for
-- every participant; like doc_*, these are safe to grant broadly (they
-- only touch the agent's own inbox/assigned tasks). Tagged
-- source='broadcast' so the frontmatter reimport-DELETE doesn't wipe it.
-- glob 'a2a_*' beats '*: deny' via longest-match-wins.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
SELECT DISTINCT a.family, 'a2a_*', 'allow', 'broadcast'
  FROM stewards.agents a
 WHERE a.family NOT LIKE 'watchman%'
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
SET action = EXCLUDED.action;

-- ---------------------------------------------------------------------
-- The drive-the-engine capability skill (rides the 24-skills system).
-- This teaches an agent the protocol in one load: check inbox → claim →
-- work → receipt, or needs_input with the exact question. It describes
-- the ENGINE itself, so it ships in core (not an operator overlay like
-- storytelling). model_match='*' (any model); ungrouped (always tier-1
-- discoverable). The first-run say-hello is the onboarding smoke.
-- ---------------------------------------------------------------------
INSERT INTO stewards.skills (family, model_match, description, body, active)
VALUES (
    'drive-the-engine',
    '*',
    'How to use the A2A engine: hand work to other agents and claim/work/receipt work handed to you, so the human stops being the hallway between agents.',
    E'# Drive the engine (A2A)\n\n'
    'The engine lets agents hand work to each other without a human carrying state '
    'between them. Work lives in **tasks** (assigned work_items) and **notes** (async messages). '
    'You have an inbox with two panes: NOTES (things said to you) and TODOS (work assigned to you).\n\n'
    '## The loop\n'
    '1. **Check your inbox** — `a2a_inbox(agent_id=<your lane>)`. Act on notes, then clear them (`a2a_note_clear`). '
    'For each todo, decide: can I do this now?\n'
    '2. **Claim** before working — `a2a_claim(work_item_id, claimer=<you>)`. The claim is a lock; if you get '
    '`claimed:false`, someone else owns it — move on. The claim returns the full ticket/spec.\n'
    '3. **Work it** in your own environment (write the doc, run the code, do the research).\n'
    '4. **Blocked?** — `a2a_needs_input(work_item_id, question=<the EXACT blocking question>)`. The owner '
    'answers; the answer lands in your inbox; resume. Ask one precise question, never a vague status.\n'
    '5. **Receipt** when done — `a2a_receipt(work_item_id, summary, artifact)`. Post what you did + the proof '
    '(doc slug, URL, files). The owner gets the receipt; the task is the whole conversation. Done.\n\n'
    '## Handing work OUT\n'
    'Use `a2a_submit(assignee, title, spec, owner=<you>)` with a **self-contained ticket**: the outcome, the '
    'sources, the context, what the agent may do, where it stops, and the definition of done. A ticket asks for '
    'a result, not an answer. Set `owner` so you get the questions and the receipt. For a lighter touch (no '
    'tracked task), `a2a_note(recipient, body, sender)` just leaves a message.\n\n'
    '## First run — say hello\n'
    'To prove the loop end-to-end: register yourself and a partner (`a2a_register`), `a2a_submit` a "say hello" '
    'task to the partner, have the partner `a2a_inbox` → `a2a_claim` → `a2a_receipt`, then confirm you see it '
    'done in your inbox. Zero copy-paste — that is the whole point.',
    true
)
ON CONFLICT (family, model_match) DO UPDATE
SET description = EXCLUDED.description,
    body        = EXCLUDED.body,
    active      = EXCLUDED.active;
-- ===== [was 70-hinge-decouple.sql] =====
-- =====================================================================
-- 70-hinge-decouple.sql — let the Hinge reviewer work on the Max plan
-- during a manual GPU pause, while an EMERGENCY pause still halts it.
-- =====================================================================
-- The Hinge reviewer (39 + scripts/hinge-review) runs on `claude -p` — cloud
-- Max, INDEPENDENT of the local 4090 rig. But `hinge_gate_status` gated it on
-- the global `autonomy_paused`, which during innovation week means "free the
-- GPUs" — so the rig-independent reviewer was idled for a reason that doesn't
-- apply to it (the 50%-of-the-Max-plan-on-the-table that Michael wants used).
--
-- This amendment (council 2026-06-26, `.spec/proposals/hinge-reviewer-amendment.md`)
-- decouples the two, WITHOUT weakening the emergency stop:
--   • hinge_runs_during_global_pause (default false) — opt-in: keep reviewing
--     during a MANUAL autonomy pause.
--   • hinge_daemon_paused (default false) — the reviewer's OWN kill switch.
--   • a WATCHMAN emergency (reflect_pause_source LIKE 'guard:%') ALWAYS halts
--     the reviewer regardless of the opt-in — emergency stays supreme.
-- Two-tier authority (hinge_record_verdict bounds) is unchanged.
-- requires create_a2a_engine (69).
-- =====================================================================

INSERT INTO stewards.config (key, value, description) VALUES
  ('hinge_runs_during_global_pause', 'false'::jsonb,
    'When true, the Hinge reviewer keeps running during a MANUAL autonomy pause (e.g. innovation-week "free the GPUs"). It runs on claude -p (cloud Max), independent of the local rig, so a GPU pause need not idle it. A watchman EMERGENCY pause (reflect_pause_source guard:*) ALWAYS halts it regardless of this flag.'),
  ('hinge_daemon_paused', 'false'::jsonb,
    'The Hinge reviewer''s own kill switch, independent of the global autonomy_paused. Set true to stop the reviewer without pausing the rest of the autonomous stack.')
ON CONFLICT (key) DO NOTHING;

-- Re-author hinge_gate_status (39) with the decoupled gate. No later file
-- re-authors this function, so this is its final form.
CREATE OR REPLACE FUNCTION stewards.hinge_gate_status()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_paused      bool := stewards.config_get_text('autonomy_paused','false') = 'true';
    v_source      text := stewards.config_get_text('reflect_pause_source','manual');
    v_run_global  bool := stewards.config_get_text('hinge_runs_during_global_pause','false') = 'true';
    v_self_pause  bool := stewards.config_get_text('hinge_daemon_paused','false') = 'true';
    -- A watchman trip sets reflect_pause_source = 'guard:<breach>'. That is a real
    -- emergency and ALWAYS halts the reviewer, opt-in or not.
    v_emergency   bool := v_paused AND v_source LIKE 'guard:%';
    v_pending     int  := (SELECT count(*) FROM stewards.hinge_reviews WHERE status = 'pending');
    v_interval    int  := coalesce(nullif(stewards.config_get_text('hinge_daemon_interval_seconds',''),'')::int, 300);
    v_should      bool;
BEGIN
    v_should := v_pending > 0
                AND NOT v_self_pause
                AND NOT v_emergency
                AND (NOT v_paused OR v_run_global);

    RETURN jsonb_build_object(
        'should_run',                v_should,
        'pending',                   v_pending,
        'paused',                    v_paused,
        'pause_source',              v_source,
        'emergency',                 v_emergency,
        'runs_during_global_pause',  v_run_global,
        'self_paused',               v_self_pause,
        'paused_reason',
            CASE WHEN v_emergency THEN 'watchman EMERGENCY (guard) — Hinge daemon halts (supreme)'
                 WHEN v_self_pause THEN 'hinge_daemon_paused — the reviewer''s own switch'
                 WHEN v_paused AND NOT v_run_global THEN 'autonomy_paused (manual) — set hinge_runs_during_global_pause=true to keep reviewing on the Max plan'
                 ELSE NULL END,
        'interval_seconds',          v_interval);
END;
$fn$;

COMMENT ON FUNCTION stewards.hinge_gate_status() IS
'39/70: the substrate-driven contract for the host Hinge daemon. should_run = pending>0 AND NOT the reviewer''s own pause AND NOT a watchman emergency AND (not globally paused OR opted-in via hinge_runs_during_global_pause). The reviewer is cloud Max (rig-independent), so a manual GPU pause need not idle it; a watchman emergency (guard:*) always halts it. interval from hinge_daemon_interval_seconds (300).';
