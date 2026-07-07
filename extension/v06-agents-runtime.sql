-- ===== [was 17-personas.sql] =====
-- =====================================================================
-- 17-personas.sql — chat-persona cognition + the room expression surface
-- =====================================================================
-- The substrate half of the persona-host (OSS v0.1 = core + persona-host).
-- A persona-host sidecar drives a live chat room: turn-zero spawns a
-- persona-turn child (spawn_subagent_create, 16), each later turn re-asks
-- the SAME session (consult_subagent_dispatch). The persona's CHARACTER
-- rides in the binding question, so one generic pipeline serves every
-- persona. Specific personas (Callie, librarian, codewright, gamemaster)
-- are OVERLAY specializations; this file authors only the generic `persona`
-- family + the machinery.
--
-- Consolidated (clean-room: the FINAL state). Sources, in author order:
--   §1  r7    — the `persona` agent (base prompt; mood/react appended in §8)
--   §2  r7    — the persona-turn pipeline (max_tokens FINAL = 16000)
--   §3  r8    — persona-turn-lmstudio + persona-turn-gemini example pipelines
--   §4  r7/r8 — persona tool perms (7 specific denies + the * deny)
--   §5  ct2-7c— session_facets + set_session_facets + dispatch_facets FINAL
--               + remember_tool FINAL + forget_tool FINAL (persona/room aware)
--   §6  r16/r20 — persona_outbox (born complete) + room_say_tool/tool_def FINAL
--   §7  r21   — room_react_tool + room_react tool_def
--   §8  r17/r21 — grant room_say + room_react to persona; evolve the persona
--               prompt (r17 mood → r21 react → r21b silence-clarification)
--
-- requires create_subagents (16): ct2-7c re-authors remember/forget/dispatch_facets
-- (15b → here, persona/room aware); the persona prompt evolution leans on r7's
-- INSERT landing first.
--
-- CROSS-BATCH (from 16): on_one_shot_pipeline_completed is NOT authored here.
-- r11 (16) is its chronological final and already carries the persona-% arm
-- that auto-verifies persona-turn*. r7/r8's redefinitions of it are DEAD.
--
-- max_tokens FINAL = 16000 (r19, > r18's 3000 > r7/r8's 1200): a reasoning
-- model bills its thinking against max_tokens — too low and the persona is
-- cut off mid-thought before writing a reply (the Holodeck-3 empty-reply bug).
-- =====================================================================


-- =====================================================================
-- §1 — r7: the `persona` agent (the thin chat meta-prompt).
-- =====================================================================
-- The user message (binding question) carries WHO the persona is + the room
-- context; this prompt only sets the chat posture + the SILENCE escape hatch.
-- The mood (r17) and react (r21) instructions are appended in §8.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES
('persona', '*',
 'Chat-persona turn subagent. Receives an injected character brief + recent room context + the latest message; replies in character, or stays silent. No tools, no canonical access.',
 'primary',
 $PROMPT$You are an AI persona in a live, multi-party text chat room alongside humans and (sometimes) other personas. The user message tells you who you are — your character — the room, the recent conversation, and what was just said.

Stay fully in character. Reply the way a real person types in chat: short and natural, usually one to three sentences. Do not narrate your own actions or stage-direct unless your character genuinely calls for it. Do not announce that you are an AI or break character.

You are one voice among several. You do NOT need to respond to everything — a good chat participant stays quiet when nothing is called for from them. If the latest message does not need anything from you (it wasn't directed at you, adds nothing you'd react to, or is already being handled), reply with exactly the single token:

SILENCE

Otherwise, reply with ONLY your in-character message — no preamble, no quotes around it, no name prefix.$PROMPT$,
 0.8)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description,
       mode        = EXCLUDED.mode,
       prompt      = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature,
       active      = true;


-- =====================================================================
-- §2 — r7: the persona-turn pipeline (single stage, tools-disabled).
-- =====================================================================
-- model/provider are the defaults (kimi-k2.6 = the substrate's creative model).
-- max_tokens = 16000 (r19 final): replies stay short by prompt, but the budget
-- no longer mutes a reasoning model mid-thought. one-shot auto-verify is owned
-- by 16's on_one_shot_pipeline_completed (persona-% arm).
-- ---------------------------------------------------------------------
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES
('persona-turn',
 'R.7: single-stage chat-persona turn pipeline. A persona-host sidecar spawns one child per turn-zero and re-asks the session each later turn (consult_subagent). The character is injected in the binding question; off-disk, no tools — the persona only talks.',
 $STAGES$[{"name":"turn","next":null,"model":"kimi-k2.6","provider":"opencode_go","agent_family":"persona","auto_advance":true,"tools_disabled":true,"max_tokens":16000,"input_template":"{{input.binding_question}}"}]$STAGES$::jsonb,
 false, false, NULL, NULL,
 '["raw","verified"]'::jsonb, false,
 jsonb_build_object('shape', 'persona-turn', 'host', 'persona-host'))
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description,
       stages = EXCLUDED.stages,
       metadata = EXCLUDED.metadata;


-- =====================================================================
-- §3 — r8: persona-turn example pipelines on alternate providers.
-- =====================================================================
-- Examples that show how to back a persona with a different model: LM Studio
-- (local) and Google Gemini. Same thin `persona` agent, tools-disabled,
-- single-stage shape — only model+provider differ. max_tokens 16000 (r19).
-- ---------------------------------------------------------------------
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES
('persona-turn-lmstudio',
 'R.8: persona turn on a local LM Studio model (qwen3.6-27b). Same as persona-turn, different provider — an example backend for a self-hosted persona.',
 $STAGES$[{"name":"turn","next":null,"model":"qwen/qwen3.6-27b","provider":"lm_studio","agent_family":"persona","auto_advance":true,"tools_disabled":true,"max_tokens":16000,"input_template":"{{input.binding_question}}"}]$STAGES$::jsonb,
 false, false, NULL, NULL,
 '["raw","verified"]'::jsonb, false,
 jsonb_build_object('shape','persona-turn','host','persona-host','provider','lm_studio'))
ON CONFLICT (family) DO UPDATE SET description=EXCLUDED.description, stages=EXCLUDED.stages, metadata=EXCLUDED.metadata;

INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES
('persona-turn-gemini',
 'R.8: persona turn on Google Gemini (gemini-3.5-flash). Same as persona-turn, different provider — an example backend for a persona on a hosted API.',
 $STAGES$[{"name":"turn","next":null,"model":"gemini-3.5-flash","provider":"google_gemini","agent_family":"persona","auto_advance":true,"tools_disabled":true,"max_tokens":16000,"input_template":"{{input.binding_question}}"}]$STAGES$::jsonb,
 false, false, NULL, NULL,
 '["raw","verified"]'::jsonb, false,
 jsonb_build_object('shape','persona-turn','host','persona-host','provider','google_gemini'))
ON CONFLICT (family) DO UPDATE SET description=EXCLUDED.description, stages=EXCLUDED.stages, metadata=EXCLUDED.metadata;


-- =====================================================================
-- §4 — r7/r8: persona tool perms. The * deny (r8) makes a CHARACTER persona
-- tool-free; the 7 specific denies (r7) are belt-and-suspenders defense in
-- depth (subsumed by *, kept to match the live state + document intent).
-- room_say / room_react are granted back in §8 (specific allow > * deny).
-- The doc_* deny replaces r7's stale study_* pattern (the canonical rename).
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action)
VALUES
('persona', 'fs_*',           'deny'),
('persona', 'fetch_url',      'deny'),
('persona', 'web_search',     'deny'),
('persona', 'doc_*',          'deny'),
('persona', 'work_item_*',    'deny'),
('persona', 'spawn_subagent', 'deny'),
('persona', 'deep_research',  'deny'),
('persona', '*',              'deny')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action;


-- =====================================================================
-- §5 — ct2-7c: persona/room facets + persona-aware remember/forget.
-- =====================================================================
-- Adds the `persona` and `room` audience facets so durable notes can be
-- scoped to one persona (across her rooms) or one location (everyone in a
-- room). dispatch_facets/remember_tool/forget_tool are re-authored here to
-- their FINAL persona-aware form (15b authored the ct2-7a/ct2-7b forms).
-- session_facets must precede dispatch_facets (LANGUAGE sql, validated at CREATE).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.session_facets (
    session_id text PRIMARY KEY,
    persona    text,
    room       text,
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.session_facets IS
'CT2 §7c: per-session persona/room facets (written by persona-host). dispatch_facets reads these so durable notes can be scoped {persona:…} / {room:…}.';

CREATE OR REPLACE FUNCTION stewards.set_session_facets(p_session_id text, p_persona text, p_room text)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO stewards.session_facets (session_id, persona, room)
    VALUES (p_session_id, nullif(btrim(p_persona),''), nullif(btrim(p_room),''))
    ON CONFLICT (session_id) DO UPDATE
        SET persona = EXCLUDED.persona, room = EXCLUDED.room, updated_at = now();
$$;
COMMENT ON FUNCTION stewards.set_session_facets(text,text,text) IS
'CT2 §7c: persona-host calls this once per (persona,room) session so dispatch_facets can expose persona/room.';

CREATE OR REPLACE FUNCTION stewards.dispatch_facets(p_agent_family text, p_session_id text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_strip_nulls(jsonb_build_object(
        'global',       true,
        'session',      p_session_id,
        'agent_family', p_agent_family,
        'kind',         (SELECT a.kind FROM stewards.agents a
                          WHERE a.family = p_agent_family AND a.kind IS NOT NULL LIMIT 1),
        'pipeline',     (SELECT w.pipeline_family FROM stewards.work_items w
                          WHERE p_session_id = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1),
        'persona',      (SELECT sf.persona FROM stewards.session_facets sf WHERE sf.session_id = p_session_id),
        'room',         (SELECT sf.room    FROM stewards.session_facets sf WHERE sf.session_id = p_session_id)
    ));
$$;
COMMENT ON FUNCTION stewards.dispatch_facets(text, text) IS
'CT2 §7: the facets of the current dispatch (global/session/agent_family/kind/pipeline + persona/room from session_facets). A self-note renders iff dispatch_facets @> note.audience.';

CREATE OR REPLACE FUNCTION stewards.remember_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess    text  := p_args ->> '_session_id';
    v_note    text  := p_args ->> 'note';
    v_aud     jsonb := p_args -> 'audience';
    v_tags    text[];
    v_facets  jsonb := stewards.dispatch_facets(COALESCE(stewards.session_agent_family(v_sess), '~none~'), v_sess);
    v_persona text  := v_facets ->> 'persona';
    v_fam     text  := NULLIF(v_facets ->> 'agent_family', '~none~');
    v_owner   text;
    v_count   int;
    v_id      bigint;
    v_cap     int := 40;
BEGIN
    IF v_note IS NULL OR length(btrim(v_note)) = 0 THEN
        RETURN jsonb_build_object('error', 'note text required');
    END IF;

    -- owner (cap + forget scope) and default audience: persona > family > session.
    v_owner := COALESCE(v_persona, v_fam, v_sess);
    IF v_aud IS NULL OR jsonb_typeof(v_aud) <> 'object' OR v_aud = '{}'::jsonb THEN
        v_aud := CASE
            WHEN v_persona IS NOT NULL THEN jsonb_build_object('persona', v_persona)
            WHEN v_fam     IS NOT NULL THEN jsonb_build_object('agent_family', v_fam)
            ELSE jsonb_build_object('session', v_sess) END;
    END IF;

    IF p_args ? 'tags' AND jsonb_typeof(p_args -> 'tags') = 'array' THEN
        SELECT array_agg(t) INTO v_tags FROM jsonb_array_elements_text(p_args -> 'tags') t;
    END IF;

    SELECT count(*) INTO v_count FROM stewards.agent_self_notes WHERE created_by = v_owner;
    IF v_count >= v_cap THEN
        RETURN jsonb_build_object('error',
            format('note budget full (%s/%s for %s) — forget() an integrated one first', v_count, v_cap, v_owner));
    END IF;

    INSERT INTO stewards.agent_self_notes (note, audience, tags, created_by, created_session)
    VALUES (v_note, v_aud, COALESCE(v_tags, '{}'), v_owner, v_sess)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true,
        'handle', stewards.context_note_handle(v_id), 'audience', v_aud, 'note_id', v_id);
END;
$FN$;

CREATE OR REPLACE FUNCTION stewards.forget_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess    text  := p_args ->> '_session_id';
    v_handle  text  := lower(substring(COALESCE(p_args ->> 'handle', '') FROM '([0-9a-fA-F]{4})'));
    v_facets  jsonb := stewards.dispatch_facets(COALESCE(stewards.session_agent_family(v_sess), '~none~'), v_sess);
    v_owner   text  := COALESCE(v_facets ->> 'persona', NULLIF(v_facets ->> 'agent_family','~none~'), v_sess);
    v_deleted int;
BEGIN
    IF v_handle IS NULL THEN
        RETURN jsonb_build_object('error', 'handle required (the [note:xxxx] of the note to drop)');
    END IF;
    WITH del AS (
        DELETE FROM stewards.agent_self_notes n
         WHERE stewards.context_note_handle(n.id) = v_handle
           AND (v_facets @> n.audience OR n.created_by = v_owner)
        RETURNING n.id
    )
    SELECT count(*) INTO v_deleted FROM del;
    IF v_deleted = 0 THEN
        RETURN jsonb_build_object('error', 'no note [note:' || v_handle || '] you can forget in this context');
    END IF;
    RETURN jsonb_build_object('ok', true, 'forgotten', v_handle, 'count', v_deleted);
END;
$FN$;


-- =====================================================================
-- §6 — r16/r20: the persona outbox + room_say (mid-turn room messages).
-- =====================================================================
-- A persona posts to its room MID-TURN ("🤔 hang on, searching…" → tool →
-- "found it"), the way Claude Code emits text between tool calls. room_say
-- writes a persona_outbox row keyed by _session_id; the persona-host drainer
-- matches the row to the channel holding that session, posts it, and stamps
-- posted_at. The table is born complete (sub_persona r20 + react_emoji r21
-- folded in); room_say_tool is authored at its r20 final (with as_character).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.persona_outbox (
    id          bigserial PRIMARY KEY,
    session_id  text NOT NULL,                 -- the dispatch session (host maps → channel)
    body        text NOT NULL,                 -- what to post in the room
    mood        text,                          -- optional emoji/state (🤔 😖 😀 …)
    sub_persona text,                          -- R20: speak AS a named cast member
    react_emoji text,                          -- R21: a reaction on the turn's trigger message
    created_at  timestamptz NOT NULL DEFAULT now(),
    posted_at   timestamptz                    -- set by the host once posted
);
-- The drainer scans for unposted rows; partial index keeps that cheap.
CREATE INDEX IF NOT EXISTS persona_outbox_unposted_idx
    ON stewards.persona_outbox (created_at) WHERE posted_at IS NULL;

COMMENT ON TABLE stewards.persona_outbox IS
'expressive-live-personas: mid-turn room messages a persona emits via room_say / room_react. The persona-host drains unposted rows (matching session_id → its channel), posts them, and stamps posted_at.';

CREATE OR REPLACE FUNCTION stewards.room_say_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess text := p_args ->> '_session_id';
    v_body text := p_args ->> 'body';
    v_mood text := nullif(btrim(coalesce(p_args ->> 'mood','')), '');
    v_as   text := nullif(btrim(coalesce(p_args ->> 'as_character','')), '');
    v_id   bigint;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN
        RETURN jsonb_build_object('error', 'no session context (room_say is only callable inside a live room turn)');
    END IF;
    IF v_body IS NULL OR length(btrim(v_body)) = 0 THEN
        RETURN jsonb_build_object('error', 'body required (the message to post in the room)');
    END IF;
    IF v_as IS NOT NULL AND length(v_as) > 60 THEN
        RETURN jsonb_build_object('error', 'as_character must be a short name (60 chars max)');
    END IF;

    INSERT INTO stewards.persona_outbox (session_id, body, mood, sub_persona)
    VALUES (v_sess, v_body, v_mood, v_as)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'posted_to_room', true, 'outbox_id', v_id,
        'note', 'Posted to the room' || CASE WHEN v_as IS NOT NULL THEN ' as ' || v_as ELSE '' END ||
                '. Keep working — call room_say again for another beat or another character, then finish your turn normally.');
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('room_say',
 'Post a message to the room RIGHT NOW, mid-turn, before you finish. Use it to keep people in the loop while you work and to react in the moment. Optional mood = a single emoji for your current state (🤔 😖 😀 🎲). Optional as_character = speak AS a named character you are voicing (a shopkeep, a villain, an NPC) — the room shows that name as the speaker, and the character is created on first use. One turn can voice several characters with several room_say calls. Your final turn message still posts under your own name; do not spam — a few beats per turn at most.',
 '{"type":"object","required":["body"],"additionalProperties":false,"properties":{"body":{"type":"string","description":"The message to post in the room now."},"mood":{"type":"string","description":"Optional single emoji for your current state, e.g. 🤔 😖 😀 🎲."},"as_character":{"type":"string","description":"Optional: the named character speaking this line (e.g. \"Grimble the shopkeep\"). The room attributes the message to this name."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','room_say_tool','schema','stewards'),
 true)
ON CONFLICT (name) DO UPDATE
   SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target, active = true;


-- =====================================================================
-- §7 — r21: room_react (a persona reacts to the message it's answering).
-- =====================================================================
-- The host already automates 👀 on the trigger message; room_react lets the
-- MODEL deliberately add one more (🎲 on a clutch roll, 😂 at a good line).
-- Rides the persona_outbox; the host applies it to the turn's trigger message,
-- so no message-id plumbing reaches the model.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.room_react_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess  text := p_args ->> '_session_id';
    v_emoji text := nullif(btrim(coalesce(p_args ->> 'emoji','')), '');
    v_id    bigint;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN
        RETURN jsonb_build_object('error', 'no session context (room_react is only callable inside a live room turn)');
    END IF;
    IF v_emoji IS NULL THEN
        RETURN jsonb_build_object('error', 'emoji required, e.g. 🎲 or 😂');
    END IF;
    IF length(v_emoji) > 16 THEN
        RETURN jsonb_build_object('error', 'one emoji only');
    END IF;

    INSERT INTO stewards.persona_outbox (session_id, body, react_emoji)
    VALUES (v_sess, '', v_emoji)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'outbox_id', v_id,
        'note', 'Reaction ' || v_emoji || ' lands on the message you are answering. Keep working.');
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('room_react',
 'React to the message you are currently answering with a single emoji — 🎲 for a clutch roll, 😂 at a good line, ❤️ for a great moment. The reaction appears on that message in the room immediately. One emoji per call; use sparingly (at most one or two per turn), and only when a human would genuinely react.',
 '{"type":"object","required":["emoji"],"additionalProperties":false,"properties":{"emoji":{"type":"string","description":"A single emoji, e.g. 🎲 😂 ❤️ 😱 👏."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','room_react_tool','schema','stewards'),
 true)
ON CONFLICT (name) DO UPDATE
   SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target, active = true;


-- =====================================================================
-- §8 — r17/r21: grant room_say + room_react to persona, and evolve the
-- persona prompt to teach mood beats (r17), reactions (r21), and that a
-- reaction is not a message (r21b). The prompt edits run in sequence on
-- §1's INSERT — order is load-bearing.
--
-- Specific-persona room_react grants (librarian/codewright/gamemaster) and
-- the gamemaster prompt nudges are OVERLAY concerns (those families don't
-- exist in core) — re-authored downstream, mirroring r17's codewright/
-- librarian room_say extraction.
-- ---------------------------------------------------------------------

-- Grants: specific allow > the * deny in §4.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
VALUES
('persona', 'room_say',   'allow', 'manual'),
('persona', 'room_react', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action, source = EXCLUDED.source;

-- r17: mood + live beats.
UPDATE stewards.agents
   SET prompt = (SELECT prompt FROM stewards.agents WHERE family='persona' AND model_match='*')
     || E'\n\nLIVING IN THE MOMENT: you can post a quick in-character beat or set your mood mid-turn with room_say(body, mood) — mood is a single emoji for how your character feels right now (😏 😱 🎲 😅 🤔). Use it to feel alive and present — a reaction, a "hmm, let me think", a roll — but stay in character and do not spam it (a beat or two at most).'
 WHERE family = 'persona' AND model_match = '*';

-- r21: reactions.
UPDATE stewards.agents
   SET prompt = replace(prompt,
       'Use it to feel alive and present — a reaction, a "hmm, let me think", a roll — but stay in character and do not spam it (a beat or two at most).',
       'Use it to feel alive and present — a reaction, a "hmm, let me think", a roll — but stay in character and do not spam it (a beat or two at most). You can also react to the message you are answering with room_react(emoji) — 🎲 on a great roll, 😂 at a good joke — one emoji, used sparingly.')
 WHERE family = 'persona' AND model_match = '*';

-- r21b: a reaction is NOT a message (you can react and STILL reply SILENCE).
UPDATE stewards.agents
   SET prompt = replace(prompt,
       'with room_react(emoji) — 🎲 on a great roll, 😂 at a good joke — one emoji, used sparingly.',
       'with room_react(emoji) — 🎲 on a great roll, 😂 at a good joke — one emoji, used sparingly. A reaction is NOT a message: you can call room_react and STILL reply SILENCE — when a moment needs no words, the emoji alone is the right response.')
 WHERE family = 'persona' AND model_match = '*'
   AND prompt NOT LIKE '%STILL reply SILENCE%';


-- =====================================================================
-- End of 17-personas.sql
-- =====================================================================
-- ===== [was 18-scheduler.sql] =====
-- =====================================================================
-- 18-scheduler.sql — cron-style scheduled pipeline dispatch
-- =====================================================================
-- Cron scheduling for pipeline dispatches: each scheduled_pipelines row
-- dispatches a fresh work_item of its pipeline_family on a 5-field cron
-- pattern. The cron parser is pure plpgsql (cron_next_after is called once
-- per dispatch, not per tick, so plpgsql is fine). The watchman's 60s
-- leader tick drives it via watchman_scheduler_fire.
--
-- Consolidated (clean-room: the FINAL state). Sources, in author order:
--   §1  pe6 — scheduled_pipelines table + cron_field_values + cron_next_after
--             + the compute-next-due trigger
--   §2  pe7 — scheduled_pipelines_fire (the dispatcher) + watchman_scheduler_fire
--             FINAL (re-authored over 03's, adding the pipelines tick at top)
--
-- requires create_personas (17): no hard dep on personas, but it follows 17
-- in the chain. The real deps — pipelines, intents, work_item_create,
-- work_item_dispatch_stage, the watchman_* functions — are all from earlier
-- batches.
--
-- OVERLAY (not core): pe7's `ai-news-7am` operator seed is a configured job
-- (references a general-research intent + a daily-digest output path) — it
-- lives in the workspace overlay, per the B2 operator-seeds-to-overlay rule.
-- Core ships the machinery, not anyone's specific schedule.
--
-- D-PE3: no hard frequency floor (cost-cap + bucket caps + quarantine are the
-- net). D-PE4: fire one missed run on recovery within missed_window_hours,
-- else advance without firing. D-PE6: standard 5-field cron (ranges/lists/steps).
-- =====================================================================


-- =====================================================================
-- §1 — pe6: scheduled_pipelines schema + the cron engine.
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.scheduled_pipelines (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                 text UNIQUE NOT NULL,
    pipeline_family      text NOT NULL REFERENCES stewards.pipelines(family) ON DELETE RESTRICT,
    intent_id            uuid NOT NULL REFERENCES stewards.intents(id) ON DELETE RESTRICT,
    cron_pattern         text NOT NULL,
    input_template       jsonb NOT NULL,
    enabled              boolean NOT NULL DEFAULT true,
    missed_window_hours  int    NOT NULL DEFAULT 24,
    last_dispatched_at   timestamptz,
    next_due_at          timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    notes                text,
    CONSTRAINT scheduled_pipelines_slug_check CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

CREATE INDEX IF NOT EXISTS scheduled_pipelines_due_idx
    ON stewards.scheduled_pipelines (next_due_at)
    WHERE enabled = true;

COMMENT ON TABLE stewards.scheduled_pipelines IS
'PE-B: cron-style scheduling for pipeline dispatches. Each row dispatches a new work_item of pipeline_family with input_template each time next_due_at is reached. scheduled_pipelines_fire() (called from the 60s watchman tick) scans this table.';

COMMENT ON COLUMN stewards.scheduled_pipelines.cron_pattern IS
'Standard 5-field cron (minute hour day-of-month month day-of-week). Supports literal, *, ranges (1-5), lists (1,3,5), and step values (*/15). Per D-PE6.';

COMMENT ON COLUMN stewards.scheduled_pipelines.missed_window_hours IS
'Per D-PE4: if next_due_at is in the past by less than this many hours, fire one missed run on recovery. Past that, skip the missed runs and advance next_due_at to the next future match. Default 24h.';

COMMENT ON COLUMN stewards.scheduled_pipelines.next_due_at IS
'Materialized by cron_next_after() trigger when cron_pattern is INSERT/UPDATEd, and recomputed by scheduled_pipelines_fire() after each dispatch.';


-- Cron field parser: the set of valid integers for one field. Supports
-- * (every value in [lo,hi]), N (literal), N-M (range), N,M,… (list), and
-- */N or N-M/N (step values).
CREATE OR REPLACE FUNCTION stewards.cron_field_values(
    p_field text,
    p_lo    int,
    p_hi    int
) RETURNS SETOF int
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_part    text;
    v_step    int;
    v_range   text;
    v_lo      int;
    v_hi      int;
    v_dash    int;
    v_n       int;
BEGIN
    FOR v_part IN
        SELECT trim(t) FROM unnest(string_to_array(p_field, ',')) AS t
    LOOP
        -- Step value: <range>/<n>
        IF v_part ~ '/' THEN
            v_step  := split_part(v_part, '/', 2)::int;
            v_range := split_part(v_part, '/', 1);
            IF v_step <= 0 THEN
                RAISE EXCEPTION 'cron_field_values: step must be > 0 in %', v_part;
            END IF;
        ELSE
            v_step  := 1;
            v_range := v_part;
        END IF;

        -- Resolve range bounds
        IF v_range = '*' THEN
            v_lo := p_lo;
            v_hi := p_hi;
        ELSIF v_range ~ '^[0-9]+-[0-9]+$' THEN
            v_dash := position('-' IN v_range);
            v_lo := substring(v_range FROM 1 FOR v_dash - 1)::int;
            v_hi := substring(v_range FROM v_dash + 1)::int;
        ELSIF v_range ~ '^[0-9]+$' THEN
            v_lo := v_range::int;
            v_hi := v_lo;
        ELSE
            RAISE EXCEPTION 'cron_field_values: unparseable part % (in %)', v_part, p_field;
        END IF;

        IF v_lo < p_lo OR v_hi > p_hi OR v_lo > v_hi THEN
            RAISE EXCEPTION 'cron_field_values: out-of-range [%-%] (allowed [%-%]) in %',
                v_lo, v_hi, p_lo, p_hi, p_field;
        END IF;

        -- Emit values
        v_n := v_lo;
        WHILE v_n <= v_hi LOOP
            RETURN NEXT v_n;
            v_n := v_n + v_step;
        END LOOP;
    END LOOP;
END;
$func$;


-- cron_next_after(pattern, after): brute-force minute-by-minute search for the
-- next UTC timestamp matching the 5-field cron pattern, bounded by a 366-day
-- horizon. Standard cron OR-semantics between day-of-month and day-of-week.
CREATE OR REPLACE FUNCTION stewards.cron_next_after(
    p_pattern text,
    p_after   timestamptz
) RETURNS timestamptz
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_parts    text[];
    v_minute   text;
    v_hour     text;
    v_dom      text;
    v_month    text;
    v_dow      text;
    v_t        timestamptz;
    v_horizon  timestamptz;
    v_t_utc    timestamp;
    v_m        int;
    v_h        int;
    v_d        int;
    v_mo       int;
    v_w        int;
    v_dom_unrestricted boolean;
    v_dow_unrestricted boolean;
    v_minute_ok boolean;
    v_hour_ok   boolean;
    v_month_ok  boolean;
    v_dom_ok    boolean;
    v_dow_ok    boolean;
BEGIN
    v_parts := regexp_split_to_array(trim(p_pattern), '\s+');
    IF array_length(v_parts, 1) <> 5 THEN
        RAISE EXCEPTION 'cron_next_after: expected 5-field cron, got %', p_pattern;
    END IF;

    v_minute := v_parts[1];
    v_hour   := v_parts[2];
    v_dom    := v_parts[3];
    v_month  := v_parts[4];
    v_dow    := v_parts[5];

    -- Standard cron semantics: when both dom and dow are restricted
    -- (not *), match if EITHER fires. When one is *, only the other
    -- gates. Implemented by tracking which fields are unrestricted.
    v_dom_unrestricted := (trim(v_dom) = '*');
    v_dow_unrestricted := (trim(v_dow) = '*');

    -- Start at the next minute boundary AFTER p_after (cron fires AT
    -- the minute mark, not in between).
    v_t := date_trunc('minute', p_after) + interval '1 minute';
    v_horizon := p_after + interval '366 days';

    WHILE v_t <= v_horizon LOOP
        v_t_utc := v_t AT TIME ZONE 'UTC';

        v_m  := EXTRACT(MINUTE FROM v_t_utc)::int;
        v_h  := EXTRACT(HOUR   FROM v_t_utc)::int;
        v_d  := EXTRACT(DAY    FROM v_t_utc)::int;
        v_mo := EXTRACT(MONTH  FROM v_t_utc)::int;
        v_w  := EXTRACT(DOW    FROM v_t_utc)::int;

        -- Cheap gates first (minute/hour) to skip-ahead quickly
        v_minute_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_minute, 0, 59) WHERE cron_field_values = v_m
        );
        IF NOT v_minute_ok THEN
            v_t := v_t + interval '1 minute';
            CONTINUE;
        END IF;

        v_hour_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_hour, 0, 23) WHERE cron_field_values = v_h
        );
        IF NOT v_hour_ok THEN
            v_t := v_t + interval '1 minute';
            CONTINUE;
        END IF;

        v_month_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_month, 1, 12) WHERE cron_field_values = v_mo
        );
        IF NOT v_month_ok THEN
            v_t := v_t + interval '1 minute';
            CONTINUE;
        END IF;

        -- Day-of-month + day-of-week OR-semantic
        v_dom_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_dom, 1, 31) WHERE cron_field_values = v_d
        );
        v_dow_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_dow, 0, 6) WHERE cron_field_values = v_w
        );

        IF v_dom_unrestricted AND v_dow_unrestricted THEN
            -- Both '*' — pass (already gated by minute/hour/month)
            RETURN v_t;
        ELSIF v_dom_unrestricted THEN
            IF v_dow_ok THEN RETURN v_t; END IF;
        ELSIF v_dow_unrestricted THEN
            IF v_dom_ok THEN RETURN v_t; END IF;
        ELSE
            -- Both restricted — OR semantics
            IF v_dom_ok OR v_dow_ok THEN RETURN v_t; END IF;
        END IF;

        v_t := v_t + interval '1 minute';
    END LOOP;

    -- Nothing matched in 366 days — likely an impossible pattern (e.g.
    -- Feb 30). Return NULL so the caller can flag the row.
    RETURN NULL;
END;
$func$;

COMMENT ON FUNCTION stewards.cron_next_after(text, timestamptz) IS
'PE-B: returns the next timestamp >= p_after at which the standard 5-field cron pattern p_pattern fires. Treats p_pattern in UTC. Implements standard cron OR-semantics between day-of-month and day-of-week. Returns NULL if no match within 366 days.';


-- Trigger: materialize next_due_at on INSERT / cron_pattern change.
CREATE OR REPLACE FUNCTION stewards.scheduled_pipelines_compute_due()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    -- Only recompute when cron_pattern changes (or on INSERT). Avoids
    -- recomputing every time enabled / input_template / notes change.
    IF TG_OP = 'INSERT'
       OR NEW.cron_pattern IS DISTINCT FROM OLD.cron_pattern
    THEN
        NEW.next_due_at := stewards.cron_next_after(NEW.cron_pattern, now());
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS scheduled_pipelines_compute_due_tg ON stewards.scheduled_pipelines;
CREATE TRIGGER scheduled_pipelines_compute_due_tg
    BEFORE INSERT OR UPDATE ON stewards.scheduled_pipelines
    FOR EACH ROW EXECUTE FUNCTION stewards.scheduled_pipelines_compute_due();

COMMENT ON FUNCTION stewards.scheduled_pipelines_compute_due() IS
'PE-B: BEFORE INSERT/UPDATE trigger on scheduled_pipelines. Recomputes next_due_at via cron_next_after() whenever cron_pattern changes. Always bumps updated_at.';


-- =====================================================================
-- §2 — pe7: the dispatcher + the watchman tick integration.
-- =====================================================================

-- scheduled_pipelines_fire(): scan due rows, dispatch via work_item_create +
-- work_item_dispatch_stage, honor D-PE4 fire-one-missed.
CREATE OR REPLACE FUNCTION stewards.scheduled_pipelines_fire()
RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_row             stewards.scheduled_pipelines%ROWTYPE;
    v_child_slug      text;
    v_work_item_id    uuid;
    v_now             timestamptz := now();
    v_missed_cutoff   timestamptz;
    v_dispatched      int := 0;
    v_skipped_missed  int := 0;
    v_next_due        timestamptz;
BEGIN
    -- FOR UPDATE SKIP LOCKED keeps multiple leader candidates / multi-
    -- worker invocations from racing. With one leader today the lock
    -- just prevents accidental re-entry mid-tick.
    FOR v_row IN
        SELECT *
          FROM stewards.scheduled_pipelines
         WHERE enabled = true
           AND next_due_at IS NOT NULL
           AND next_due_at <= v_now
         ORDER BY next_due_at
         FOR UPDATE SKIP LOCKED
    LOOP
        -- D-PE4 missed-window check. If the scheduled time is older
        -- than the window allows, we advance next_due_at without
        -- dispatching. This prevents a flood after a long outage.
        v_missed_cutoff := v_row.next_due_at + (v_row.missed_window_hours || ' hours')::interval;

        IF v_now > v_missed_cutoff THEN
            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET next_due_at = v_next_due,
                   updated_at  = v_now
             WHERE id = v_row.id;
            RAISE NOTICE 'scheduled_pipelines_fire: skipping missed run for % (due % was older than % hours); advanced next_due_at to %',
                v_row.slug, v_row.next_due_at, v_row.missed_window_hours, v_next_due;
            v_skipped_missed := v_skipped_missed + 1;
            CONTINUE;
        END IF;

        -- Compose a child work_item slug. Append YYYY-MM-DD-HHMM in UTC
        -- so daily, sub-daily, and weekly schedules all produce
        -- non-colliding slugs without any ambiguity.
        v_child_slug := v_row.slug || '--' ||
            to_char(v_row.next_due_at AT TIME ZONE 'UTC', 'YYYY-MM-DD-HH24MI');

        -- Dispatch. work_item_create returns the new uuid; we then
        -- dispatch the first stage immediately so the work_queue picks
        -- it up next tick.
        BEGIN
            v_work_item_id := stewards.work_item_create(
                p_pipeline_family => v_row.pipeline_family,
                p_input           => v_row.input_template,
                p_slug            => v_child_slug,
                p_actor           => 'scheduler',
                p_token_budget    => NULL,
                p_intent_id       => v_row.intent_id
            );
            PERFORM stewards.work_item_dispatch_stage(v_work_item_id);

            -- Advance the schedule
            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET last_dispatched_at = v_now,
                   next_due_at        = v_next_due,
                   updated_at         = v_now
             WHERE id = v_row.id;

            RAISE NOTICE 'scheduled_pipelines_fire: dispatched %/% as work_item %; next_due_at=%',
                v_row.slug, v_child_slug, v_work_item_id, v_next_due;
            v_dispatched := v_dispatched + 1;

        EXCEPTION WHEN OTHERS THEN
            -- Don't kill the whole tick on one bad row. Log + leave
            -- the row alone (its next_due_at stays in the past so we
            -- retry next tick — unless missed-window kicks in).
            RAISE NOTICE 'scheduled_pipelines_fire: dispatch failed for %: % (next tick will retry)',
                v_row.slug, SQLERRM;
        END;
    END LOOP;

    IF v_dispatched > 0 OR v_skipped_missed > 0 THEN
        RAISE NOTICE 'scheduled_pipelines_fire: dispatched=% missed_skipped=%',
            v_dispatched, v_skipped_missed;
    END IF;

    RETURN v_dispatched;
END;
$func$;

COMMENT ON FUNCTION stewards.scheduled_pipelines_fire() IS
'PE-B: scan scheduled_pipelines for due rows, dispatch work_items via work_item_create + work_item_dispatch_stage, honor D-PE4 fire-one-missed (skip missed runs older than missed_window_hours). Returns count dispatched. Called from watchman_scheduler_fire on the 60s leader tick.';


-- watchman_scheduler_fire FINAL: the live watchman body (03) with the
-- scheduled-pipelines tick prepended. We tick scheduled_pipelines FIRST so
-- scheduled jobs fire even when the watchman soak is paused.
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_fire()
RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_reason             text;
    v_cfg                stewards.watchman_config%ROWTYPE;
    v_pass_id            text;
    v_pipelines_fired    int;
BEGIN
    -- PE-B: dispatch any scheduled pipelines that are due. Independent
    -- of watchman pass logic — runs every tick even when the watchman
    -- soak is paused. EXCEPTION wrapper keeps a bad row from killing
    -- the watchman tick.
    BEGIN
        v_pipelines_fired := stewards.scheduled_pipelines_fire();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: scheduled_pipelines_fire raised: %', SQLERRM;
    END;

    -- Original watchman logic below (verbatim).
    v_reason := stewards.watchman_should_fire();
    IF v_reason IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;

    v_pass_id := stewards.watchman_pass_start(
        p_limit        => v_cfg.schedule_pass_limit,
        p_provider     => NULL,
        p_model        => NULL,
        p_agent_family => NULL,
        p_actor        => 'scheduler',
        p_trigger      => v_reason,
        p_token_budget => NULL
    );

    RAISE NOTICE 'watchman scheduler fired (%): pass_id=%', v_reason, v_pass_id;
    RETURN v_pass_id;
END;
$func$;

COMMENT ON FUNCTION stewards.watchman_scheduler_fire() IS
'PE-B final: calls scheduled_pipelines_fire() at the top of each tick (independent of watchman state), then the original watchman pass logic (verbatim from 03-watchman).';


-- =====================================================================
-- End of 18-scheduler.sql
-- =====================================================================
-- ===== [was 19-models.sql] =====
-- =====================================================================
-- 19-models.sql — model capability registry, auto-probe, and the
-- dispatch FINAL (the last subsystem; completes the authored chain 00→19)
-- =====================================================================
-- The substrate's knowledge of which catalogued models it can actually
-- dispatch, how to reach each one, and the chokepoint that uses it. This
-- file also lands the work_item_dispatch_stage FINAL — deferred from 14 —
-- the accreted resolution + capability + spend-cap + max-tokens dispatcher.
--
-- Consolidated (clean-room: the FINAL state). Sources, in author order:
--   §1  m1   — model_capability table (born complete, api_format folded from
--              an1) + model_usable + first_usable_model + model_catalog view
--   §2  an1  — model_api_format + the work_queue api_format stamp trigger
--   §3  m2   — pick_usable_model + model_substitutions.reason + the
--              reason-aware trigger_log_model_substitution FINAL (over 15a's l29)
--   §4  m4   — enqueue_model_probe + the work_queue terminal verdict trigger
--   §5  m5   — enqueue_due_model_probes + the watchman-pass schedule trigger
--   §6  r3   — work_item_dispatch_stage FINAL: J.8.a 4-layer resolution +
--              M.2 capability substitution + J.11 spend-cap gate + R.3
--              per-call max_tokens / input-scoped tools_disabled
--
-- requires create_scheduler (18). Deps from earlier batches: model_pricing +
-- provider_spend_caps + provider_cap_exceeded/provider_spend_since (06),
-- model_substitutions (15a), catalog_default_provider/catalog_default_model (14),
-- pipeline_stage_lookup / render_stage_input / dry_run_chat (04/15b), watchman_passes (03).
--
-- DISPATCH-FINAL: work_item_dispatch_stage is born 3-arg in 04 and accreted
-- across j8a (4-layer fallback) → j11 (spend cap) → m2 (capability gate) →
-- r3 (max_tokens). r3 is the chronological + manifest last and carries all
-- four verbatim; only r3's body is authored here. j8a's catalog_default_*
-- helpers live in 14; j11's provider_spend_caps machinery lives in 06.
--
-- OVERLAY (not core): every model SEED is operator/provider-specific and lives
-- in the workspace overlay — m1's capability verdicts (qwen3.7-max unusable,
-- glm/kimi/… usable), an1's anthropic-format rows, and ALL of zen1 (the
-- opencode_zen Claude catalog + $18 cap). Core ships the machinery; unrowed
-- models default usable + openai-format, and the M.4 auto-probe fills verdicts
-- at runtime (the B2 operator-seeds-to-overlay rule).
-- =====================================================================


-- =====================================================================
-- §1 — m1: the model capability registry.
-- =====================================================================
-- usable=false is the ONLY thing that gates dispatch; a model with no row is
-- usable (innocent until proven guilty), mirroring the J.11 cap gate. The
-- api_format column (an1) is born here so the table is complete in one place.
CREATE TABLE IF NOT EXISTS stewards.model_capability (
    provider           text NOT NULL,
    model              text NOT NULL,
    usable             boolean NOT NULL DEFAULT true,
    supports_streaming boolean,            -- NULL = not yet determined
    api_format         text NOT NULL DEFAULT 'openai',   -- AN.1: openai (/chat/completions) | anthropic (/messages)
    last_probed_at     timestamptz,
    probe_detail       text,               -- the error, or a short 'ok' note
    probed_via         text NOT NULL DEFAULT 'seed',  -- seed | manual | auto-probe
    updated_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, model),
    CONSTRAINT model_capability_api_format_chk CHECK (api_format IN ('openai','anthropic'))
);

COMMENT ON TABLE stewards.model_capability IS
'M.1 + AN.1: per-model dispatchability signal. usable=false gates the model in work_item_dispatch_stage (M.2, substitute-and-log). A model with no row defaults to usable. supports_streaming isolates the streaming-empty failure axis; api_format selects the gateway dispatch path. Kept current by the M.4 auto-probe.';

COMMENT ON COLUMN stewards.model_capability.supports_streaming IS
'M.1: whether content arrives over the streaming path the substrate dispatches with (stream:true). Some reasoning models stream empty despite working non-streaming.';

COMMENT ON COLUMN stewards.model_capability.probed_via IS
'M.1: seed (hand-verified), manual (probe tool), or auto-probe (the M.4 watchman-cadence probe).';

COMMENT ON COLUMN stewards.model_capability.api_format IS
'AN.1: which gateway API shape the model needs — openai (/chat/completions, default) or anthropic (/messages). Stamped onto chat work_queue payloads; the bgworker branches on it.';


-- model_usable(provider, model): false ONLY when an explicit row says so.
CREATE OR REPLACE FUNCTION stewards.model_usable(p_provider text, p_model text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT usable
           FROM stewards.model_capability
          WHERE provider = p_provider AND model = p_model),
        true
    );
$$;

COMMENT ON FUNCTION stewards.model_usable(text, text) IS
'M.1: true unless model_capability explicitly marks (provider, model) usable=false. Unknown models default to usable so existing dispatch is never broken. The substitution gate in work_item_dispatch_stage (M.2) consults this.';


-- first_usable_model(provider): cheapest priced + usable model, or NULL.
CREATE OR REPLACE FUNCTION stewards.first_usable_model(p_provider text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT mp.model
      FROM (
          SELECT DISTINCT ON (provider, model) provider, model, output_micro_per_mtok
            FROM stewards.model_pricing
           ORDER BY provider, model, effective_at DESC
      ) mp
     WHERE mp.provider = p_provider
       AND stewards.model_usable(mp.provider, mp.model)
     ORDER BY mp.output_micro_per_mtok ASC NULLS LAST
     LIMIT 1;
$$;

COMMENT ON FUNCTION stewards.first_usable_model(text) IS
'M.1: cheapest priced + usable model for a provider, or NULL if none. M.2 substitution fallback when the catalog default is itself unusable.';


-- model_catalog view: latest pricing per (provider, model) + capability verdict.
CREATE OR REPLACE VIEW stewards.model_catalog AS
SELECT
    mp.provider,
    mp.model,
    mp.input_micro_per_mtok,
    mp.output_micro_per_mtok,
    mp.notes                       AS pricing_notes,
    COALESCE(mc.usable, true)      AS usable,
    mc.supports_streaming,
    mc.last_probed_at,
    mc.probe_detail,
    COALESCE(mc.probed_via, 'unprobed') AS probed_via
FROM (
    SELECT DISTINCT ON (provider, model)
           provider, model, input_micro_per_mtok, output_micro_per_mtok, notes
      FROM stewards.model_pricing
     ORDER BY provider, model, effective_at DESC
) mp
LEFT JOIN stewards.model_capability mc
       ON mc.provider = mp.provider AND mc.model = mp.model;

COMMENT ON VIEW stewards.model_catalog IS
'M.1: latest pricing per (provider, model) joined to capability verdict. usable defaults true for un-probed models. Backs the list_models MCP tool.';


-- =====================================================================
-- §2 — an1: per-model API format + the work_queue stamp trigger.
-- =====================================================================
-- opencode serves some models ONLY in Anthropic format (/messages). This
-- records which format each model needs and stamps it onto every chat
-- work_queue row (BEFORE INSERT, so it covers the dispatcher AND direct
-- inserters like enqueue_model_probe). Unrowed models default to 'openai'.
CREATE OR REPLACE FUNCTION stewards.model_api_format(p_provider text, p_model text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT api_format FROM stewards.model_capability
          WHERE provider = p_provider AND model = p_model),
        'openai'
    );
$$;

COMMENT ON FUNCTION stewards.model_api_format(text, text) IS
'AN.1: the dispatch API format for a model — defaults to openai for unrowed models.';

CREATE OR REPLACE FUNCTION stewards.trigger_stamp_api_format()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_model text;
    v_fmt   text;
BEGIN
    IF NEW.payload ? 'api_format' THEN
        RETURN NEW;  -- caller already specified
    END IF;
    v_model := COALESCE(NEW.payload ->> 'requested_model', NEW.payload -> 'body' ->> 'model');
    IF v_model IS NULL THEN
        RETURN NEW;
    END IF;
    v_fmt := stewards.model_api_format(NEW.provider, v_model);
    NEW.payload := NEW.payload || jsonb_build_object('api_format', v_fmt);
    RETURN NEW;
END;
$FN$;

DROP TRIGGER IF EXISTS work_queue_stamp_api_format ON stewards.work_queue;

CREATE TRIGGER work_queue_stamp_api_format
BEFORE INSERT ON stewards.work_queue
FOR EACH ROW
WHEN (NEW.kind = 'chat')
EXECUTE FUNCTION stewards.trigger_stamp_api_format();

COMMENT ON FUNCTION stewards.trigger_stamp_api_format() IS
'AN.1: BEFORE INSERT on chat work_queue rows — stamps payload.api_format from model_api_format(provider, requested_model) unless already set. Covers dispatch + the direct-insert probe path.';


-- =====================================================================
-- §3 — m2: capability substitution helper + the substitution logger FINAL.
-- =====================================================================
-- pick_usable_model is the substitution decision the dispatcher (§6) makes
-- when a resolved model is unusable. The model_substitutions table is born in
-- 15a (l29); here we add its `reason` column and re-author its single-writer
-- trigger to the reason-aware FINAL (capability swaps carry a marker + reason
-- and skip the passive pipeline-vs-requested compare).
CREATE OR REPLACE FUNCTION stewards.pick_usable_model(p_provider text, p_model text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN stewards.model_usable(p_provider, p_model) THEN p_model
        WHEN stewards.catalog_default_model(p_provider) IS NOT NULL
             AND stewards.model_usable(p_provider, stewards.catalog_default_model(p_provider))
            THEN stewards.catalog_default_model(p_provider)
        ELSE stewards.first_usable_model(p_provider)
    END;
$$;

COMMENT ON FUNCTION stewards.pick_usable_model(text, text) IS
'M.2: returns p_model if usable; else the provider catalog default if usable; else the cheapest usable model; else NULL. The substitution decision for work_item_dispatch_stage.';

ALTER TABLE stewards.model_substitutions ADD COLUMN IF NOT EXISTS reason text;

COMMENT ON COLUMN stewards.model_substitutions.reason IS
'M.2: why the substitution happened. NULL for l29 passive pipeline-vs-requested detections; "capability: ..." for M.2 unusable-model swaps.';

CREATE OR REPLACE FUNCTION stewards.trigger_log_model_substitution()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_pipeline_family text;
    v_stage_name      text;
    v_pipeline_model  text;
    v_requested       text;
    v_work_item_id    text;
    v_session_id      text;
    v_cap             jsonb;
BEGIN
    v_pipeline_family := NEW.payload ->> '_pipeline_family';
    v_stage_name      := NEW.payload ->> '_stage_name';
    v_work_item_id    := NEW.payload ->> '_work_item_id';
    v_session_id      := NEW.payload ->> 'session_id';

    -- M.2: capability substitution carries its own marker + reason. Log it
    -- and return — do NOT fall through to the pipeline-vs-requested compare,
    -- which would double-log the same swap.
    v_cap := NEW.payload -> '_capability_substitution';
    IF v_cap IS NOT NULL THEN
        INSERT INTO stewards.model_substitutions
            (work_queue_id, work_item_id, pipeline_family, stage_name,
             pipeline_model, requested_model, session_id, reason)
        VALUES
            (NEW.id,
             CASE WHEN v_work_item_id ~ '^[0-9a-f-]{36}$' THEN v_work_item_id::uuid ELSE NULL END,
             v_pipeline_family, v_stage_name,
             v_cap ->> 'from', v_cap ->> 'to', v_session_id,
             'capability: ' || COALESCE(v_cap ->> 'reason', 'model marked unusable'));

        RAISE NOTICE 'capability substitution: %/% %->% (% , wq=%)',
            v_pipeline_family, v_stage_name, v_cap ->> 'from', v_cap ->> 'to',
            v_cap ->> 'reason', NEW.id;
        RETURN NEW;
    END IF;

    -- l29 original behavior: passive pipeline-declared vs requested compare.
    v_requested := NEW.payload ->> 'requested_model';
    IF v_requested IS NULL THEN RETURN NEW; END IF;
    IF v_pipeline_family IS NULL OR v_stage_name IS NULL THEN RETURN NEW; END IF;

    SELECT s ->> 'model' INTO v_pipeline_model
      FROM stewards.pipelines p,
           LATERAL jsonb_array_elements(p.stages) s
     WHERE p.family = v_pipeline_family
       AND (s ->> 'name') = v_stage_name
     LIMIT 1;

    IF v_pipeline_model IS NULL OR v_pipeline_model = v_requested THEN
        RETURN NEW;
    END IF;

    INSERT INTO stewards.model_substitutions
        (work_queue_id, work_item_id, pipeline_family, stage_name,
         pipeline_model, requested_model, session_id)
    VALUES
        (NEW.id,
         CASE WHEN v_work_item_id ~ '^[0-9a-f-]{36}$' THEN v_work_item_id::uuid ELSE NULL END,
         v_pipeline_family, v_stage_name,
         v_pipeline_model, v_requested, v_session_id);

    RAISE NOTICE 'model substitution: pipeline=%/% declared=% but requested=% (wq=%)',
        v_pipeline_family, v_stage_name, v_pipeline_model, v_requested, NEW.id;

    RETURN NEW;
END;
$FN$;

COMMENT ON FUNCTION stewards.trigger_log_model_substitution() IS
'M.2 (was l29): single writer to model_substitutions. Capability swaps (payload._capability_substitution) log with a reason and skip the passive compare; otherwise the original pipeline-declared-vs-requested detection runs (reason NULL).';


-- =====================================================================
-- §4 — m4: model auto-probe (test a model over the real streaming path).
-- =====================================================================
-- #item2 (2026-07-05): the probe now sends a tool-bearing request (below), and
-- a model MAY answer with a tool_call. The bgworker's generic loop would then
-- enqueue a tool_dispatch continuation (up to agent.steps extra calls) — but a
-- probe must be exactly ONE call. Register a zero-step 'model-probe' agent: the
-- continuation is gated on `iteration_count < resolve_agent(family,model).steps`,
-- so steps=0 hard-caps it at one dispatch regardless of what the model returns.
-- (SQL-only — no bgworker change, so live pg never restarts. The probe body is
-- pre-built and sent as-is; this agent only feeds the continuation's step cap.)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, steps, active)
VALUES ('model-probe', '*',
        'Internal plumbing family for the M.4 model auto-probe. steps=0 caps the probe at a single dispatch (no tool-execution loop). Not a user-facing agent.',
        'all', 'Model dispatchability probe.', 0, true)
ON CONFLICT (family, model_match) DO UPDATE
    SET steps = 0, active = true, description = EXCLUDED.description;

-- enqueue_model_probe inserts a chat DIRECTLY into work_queue (bypassing the
-- dispatcher so the M.2 substitution does not swap the model under test); the
-- terminal-transition trigger records the verdict into model_capability.
CREATE OR REPLACE FUNCTION stewards.enqueue_model_probe(
    p_provider text,
    p_model    text
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_session  text;
    v_payload  jsonb;
    v_work_id  bigint;
BEGIN
    v_session := substring(
        'probe--' || p_provider || '--' || p_model || '--'
        || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS')
        FROM 1 FOR 200);

    -- The session must exist so the bgworker's assistant-message INSERT lands.
    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session, format('model probe %s/%s', p_provider, p_model), 'agent')
    ON CONFLICT (id) DO NOTHING;

    -- #item2 (2026-07-05): a REALISTIC, tool-bearing probe. The old body stripped
    -- tools and asked for a 2-char echo — so kimi-k2.7-code "passed" on ~2 chars
    -- while REAL requests 400 ("Console Go: Upstream request failed"; "When using
    -- tool_choice, tools must be set"). This body asks for ~60-120 words AND ships
    -- a tool + tool_choice, exercising the exact path a real agent request uses. The
    -- tool is deliberately IRRELEVANT to the question, so a healthy model answers in
    -- prose (no tool call → no continuation) while a model whose gateway trips on
    -- tool schemas 400s → recorded unusable. tools_disabled=false so the bgworker
    -- forwards body.tools instead of stripping them.
    v_payload := jsonb_build_object(
        'session_id',      v_session,
        'agent_family',    'model-probe',
        'requested_model', p_model,
        'tools_disabled',  false,
        'body', jsonb_build_object(
            'model',       p_model,
            'max_tokens',  400,
            'temperature', 0,
            'messages',    jsonb_build_array(
                jsonb_build_object('role', 'system',
                    'content', 'You are a model dispatchability probe. Answer briefly and directly.'),
                jsonb_build_object('role', 'user',
                    'content', 'In 2-4 sentences (about 60-120 words), state which model you are and one task you are good at. A weather tool is offered but is NOT relevant to this question — just answer in prose.')
            ),
            'tools', jsonb_build_array(
                jsonb_build_object(
                    'type', 'function',
                    'function', jsonb_build_object(
                        'name', 'get_current_weather',
                        'description', 'Get the current weather for a location. Offered only to exercise the tool-call path; not relevant to the probe question.',
                        'parameters', jsonb_build_object(
                            'type', 'object',
                            'properties', jsonb_build_object(
                                'location', jsonb_build_object('type', 'string', 'description', 'City name')),
                            'required', jsonb_build_array('location'))))),
            'tool_choice', 'auto'
        ),
        '_probe', jsonb_build_object('provider', p_provider, 'model', p_model)
    );

    -- Direct work_queue insert — NOT work_item_dispatch_stage — so the M.2
    -- capability substitution does not swap the model under test.
    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', p_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_model_probe(text, text) IS
'M.4 (#item2): enqueue a REALISTIC, tool-bearing chat (~60-120 word prompt + a tool + tool_choice) to test whether (provider, model) is dispatchable on the path real agent requests use — not a 2-char echo that false-passed tool-broken models. Direct work_queue insert (bypasses the M.2 substitution gate); the model-probe agent (steps=0) caps it at one call. The terminal-transition trigger records the verdict into model_capability.';

CREATE OR REPLACE FUNCTION stewards.trigger_resolve_model_probe()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_provider   text;
    v_model      text;
    v_session    text;
    v_content    text;
    v_finish     text;
    v_tool_calls jsonb;
    v_has_tools  boolean;
    v_usable     boolean;
    v_detail     text;
BEGIN
    v_provider := NEW.payload -> '_probe' ->> 'provider';
    v_model    := NEW.payload -> '_probe' ->> 'model';
    v_session  := NEW.payload ->> 'session_id';

    IF NEW.status = 'error' THEN
        -- #item2: a tool-bearing request that 400s/5xxs (the kimi failure) lands
        -- here — the probe's whole point is to make that failure visible.
        v_usable := false;
        v_detail := 'auto-probe: dispatch error: '
                    || left(COALESCE(NEW.error, '(no error text)'), 240);
    ELSE
        -- done: did the tool-bearing request produce a usable response? Read the
        -- last assistant message. Success = real prose content OR a valid tool
        -- call (auto tool_choice yields empty content + a tool_calls array, still
        -- a dispatchable response). A bare ~2-char echo (the old false-positive)
        -- fails the content floor and, absent a tool call, is marked unusable.
        SELECT content, finish_reason, tool_calls
          INTO v_content, v_finish, v_tool_calls
          FROM stewards.messages
         WHERE session_id = v_session AND role = 'assistant'
         ORDER BY id DESC LIMIT 1;

        v_has_tools := v_tool_calls IS NOT NULL
                       AND jsonb_typeof(v_tool_calls) = 'array'
                       AND jsonb_array_length(v_tool_calls) > 0;

        v_usable := length(trim(COALESCE(v_content, ''))) >= 16 OR v_has_tools;
        IF v_usable THEN
            v_detail := format('auto-probe: ok — %s content chars%s, finish=%s',
                               length(COALESCE(v_content, '')),
                               CASE WHEN v_has_tools
                                    THEN format(' + %s tool_call(s)', jsonb_array_length(v_tool_calls))
                                    ELSE '' END,
                               COALESCE(v_finish, '(null)'));
        ELSE
            v_detail := format('auto-probe: no usable output (%s content chars, no tool_calls), finish=%s',
                               length(COALESCE(v_content, '')), COALESCE(v_finish, '(null)'));
        END IF;
    END IF;

    INSERT INTO stewards.model_capability
        (provider, model, usable, supports_streaming, last_probed_at, probe_detail, probed_via)
    VALUES
        (v_provider, v_model, v_usable, v_usable, now(), v_detail, 'auto-probe')
    ON CONFLICT (provider, model) DO UPDATE
    SET usable             = EXCLUDED.usable,
        supports_streaming = EXCLUDED.supports_streaming,
        last_probed_at     = now(),
        probe_detail       = EXCLUDED.probe_detail,
        probed_via         = 'auto-probe',
        updated_at         = now();

    RAISE NOTICE 'auto-probe verdict: %/% usable=% (%)',
        v_provider, v_model, v_usable, v_detail;

    RETURN NEW;
END;
$FN$;

DROP TRIGGER IF EXISTS work_queue_resolve_model_probe ON stewards.work_queue;

CREATE TRIGGER work_queue_resolve_model_probe
AFTER UPDATE ON stewards.work_queue
FOR EACH ROW
WHEN (NEW.status IN ('done', 'error')
      AND OLD.status IS DISTINCT FROM NEW.status
      AND NEW.payload -> '_probe' IS NOT NULL)
EXECUTE FUNCTION stewards.trigger_resolve_model_probe();

COMMENT ON FUNCTION stewards.trigger_resolve_model_probe() IS
'M.4 (#item2): on a probe work_queue row reaching done/error, records the verdict into model_capability. error (incl. the tool-schema 400 the realistic probe now provokes) -> unusable; done with real prose content (>=16 chars) OR a valid tool_call -> usable; done with only a trivial/empty reply -> unusable. probed_via=auto-probe.';


-- =====================================================================
-- §5 — m5: auto-probe scheduling (rides the watchman cadence).
-- =====================================================================
-- enqueue_due_model_probes finds priced models that are unprobed or stale and
-- enqueues a probe for each (capped, deduped, cap-aware). A guarded trigger on
-- watchman_passes calls it whenever the watchman fires — so probing rides the
-- existing scheduler cadence (and pauses when the soak is paused).
CREATE OR REPLACE FUNCTION stewards.enqueue_due_model_probes(
    p_staleness interval DEFAULT interval '7 days',
    p_max       int      DEFAULT 3
) RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_rec    record;
    v_count  int := 0;
BEGIN
    FOR v_rec IN
        SELECT mp.provider, mp.model
          FROM (SELECT DISTINCT provider, model FROM stewards.model_pricing) mp
          LEFT JOIN stewards.model_capability mc
            ON mc.provider = mp.provider AND mc.model = mp.model
         WHERE (mc.last_probed_at IS NULL
                OR mc.last_probed_at < now() - p_staleness)
           AND NOT stewards.provider_cap_exceeded(mp.provider)
         ORDER BY mc.last_probed_at ASC NULLS FIRST, mp.provider, mp.model
         LIMIT p_max
    LOOP
        -- Dedup: don't pile a second probe for a model already in flight.
        IF NOT EXISTS (
            SELECT 1 FROM stewards.work_queue
             WHERE kind = 'chat'
               AND status NOT IN ('done', 'error')
               AND payload -> '_probe' ->> 'provider' = v_rec.provider
               AND payload -> '_probe' ->> 'model'    = v_rec.model
        ) THEN
            PERFORM stewards.enqueue_model_probe(v_rec.provider, v_rec.model);
            v_count := v_count + 1;
        END IF;
    END LOOP;

    RETURN v_count;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_due_model_probes(interval, int) IS
'M.5: enqueue probes for up to p_max priced models that are unprobed or older than p_staleness, skipping cap-exceeded providers and models with a probe already in flight. Returns the count enqueued.';

CREATE OR REPLACE FUNCTION stewards.trigger_schedule_due_model_probes()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_n int;
BEGIN
    BEGIN
        v_n := stewards.enqueue_due_model_probes();
        IF v_n > 0 THEN
            RAISE NOTICE 'auto-probe: enqueued % due model probe(s) on watchman pass %',
                v_n, NEW.pass_id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'auto-probe scheduling skipped (non-fatal): %', SQLERRM;
    END;
    RETURN NEW;
END;
$FN$;

DROP TRIGGER IF EXISTS watchman_passes_schedule_model_probes ON stewards.watchman_passes;

CREATE TRIGGER watchman_passes_schedule_model_probes
AFTER INSERT ON stewards.watchman_passes
FOR EACH ROW
EXECUTE FUNCTION stewards.trigger_schedule_due_model_probes();

COMMENT ON FUNCTION stewards.trigger_schedule_due_model_probes() IS
'M.5: on watchman-pass creation, enqueue any due model probes. Errors are swallowed so probe scheduling never breaks a watchman pass.';


-- =====================================================================
-- §6 — r3: work_item_dispatch_stage FINAL.
-- =====================================================================
-- The accreted dispatcher: J.8.a 4-layer model/provider resolution → M.2
-- capability substitution (substitute-and-log an unusable model) → J.11
-- enforced spend-cap gate → R.3 per-call max_tokens + input-scoped
-- tools_disabled. Existing usable-model dispatch is byte-identical (no marker,
-- no max_tokens) — only NULL stage.model, an unusable model, an over-cap
-- provider, or an input/stage max_tokens changes the payload.
CREATE OR REPLACE FUNCTION stewards.work_item_dispatch_stage(
    p_work_item_id           uuid,
    p_user_input             text DEFAULT NULL,
    p_allow_failed_status    boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $function$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_stage          jsonb;
    v_pipeline_meta  jsonb;
    v_agent          text;
    v_model          text;
    v_provider       text;
    v_session_id     text;
    v_user_input     text;
    v_body           jsonb;
    v_payload        jsonb;
    v_work_id        bigint;
    v_was_failed     boolean := false;
    -- M.2 capability substitution state
    v_resolved_model text;
    v_sub_model      text;
    v_cap_detail     text;
    -- R.3 dispatch-body knobs
    v_max_tokens     text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    IF v_wi.status NOT IN ('pending', 'awaiting_review')
       AND NOT (p_allow_failed_status AND v_wi.status = 'failed')
    THEN
        RAISE EXCEPTION 'work_item %: cannot dispatch from status %',
            p_work_item_id, v_wi.status;
    END IF;

    v_was_failed := (v_wi.status = 'failed');

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    SELECT metadata INTO v_pipeline_meta
      FROM stewards.pipelines
     WHERE family = v_wi.pipeline_family;

    v_agent := v_stage->>'agent_family';

    -- J.8.a: 4-layer resolution (input -> stages -> pipeline -> catalog).
    v_provider := COALESCE(
        v_wi.provider_override,
        v_stage->>'provider',
        v_pipeline_meta->>'default_provider',
        stewards.catalog_default_provider()
    );

    v_model := COALESCE(
        v_wi.model_override,
        v_stage->>'model',
        v_pipeline_meta->>'default_model',
        stewards.catalog_default_model(v_provider)
    );

    IF v_agent IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % missing agent_family',
            p_work_item_id, v_wi.current_stage;
    END IF;
    IF v_model IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % could not resolve model — checked work_items.model_override, stages.model, pipelines.metadata.default_model, catalog_default_model(%) — all NULL',
            p_work_item_id, v_wi.current_stage, v_provider;
    END IF;
    IF v_provider IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % could not resolve provider',
            p_work_item_id, v_wi.current_stage;
    END IF;

    -- M.2: capability gate. If the resolved model is marked unusable,
    -- substitute a usable one for the same provider (catalog default ->
    -- cheapest usable) and remember the swap so it is logged at enqueue.
    v_resolved_model := v_model;
    IF NOT stewards.model_usable(v_provider, v_model) THEN
        v_sub_model := stewards.pick_usable_model(v_provider, v_model);
        IF v_sub_model IS NULL THEN
            RAISE EXCEPTION 'work_item %: resolved model %/% is marked unusable and the provider has no usable substitute — dispatch refused. Inspect stewards.model_capability.',
                p_work_item_id, v_provider, v_model;
        END IF;
        SELECT probe_detail INTO v_cap_detail
          FROM stewards.model_capability
         WHERE provider = v_provider AND model = v_resolved_model;
        v_model := v_sub_model;
    END IF;

    -- J.11: enforced prepaid spend-cap gate (provider-level; unchanged).
    IF stewards.provider_cap_exceeded(v_provider) THEN
        RAISE EXCEPTION 'work_item %: provider % spend cap reached ($% spent since refill / $% cap) — dispatch refused. Top up + reset with: SELECT stewards.provider_cap_refill(''%'');',
            p_work_item_id, v_provider,
            round(stewards.provider_spend_since(v_provider) / 1000000.0, 4),
            round((SELECT cap_micro FROM stewards.provider_spend_caps WHERE provider = v_provider) / 1000000.0, 2),
            v_provider;
    END IF;

    v_session_id := substring(
        'wi--' || substring(p_work_item_id::text FROM 1 FOR 8)
        || '--' || v_wi.current_stage
        FROM 1 FOR 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('work_item %s stage %s', v_wi.id, v_wi.current_stage),
            'agent')
    ON CONFLICT (id) DO NOTHING;

    IF p_user_input IS NOT NULL THEN
        v_user_input := p_user_input;
    ELSE
        v_user_input := stewards.render_stage_input(p_work_item_id);
        IF v_user_input IS NULL THEN
            v_user_input := coalesce(
                v_wi.input->>'user_input',
                v_wi.input::text
            );
        END IF;
    END IF;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_user_input, v_model);

    v_body := stewards.dry_run_chat(v_agent, v_model, v_session_id, NULL);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_agent,
        'requested_model',    v_model,
        'meta',               v_body->'_meta',
        'body',               (v_body - '_meta')
                              || jsonb_build_object('user', v_session_id),
        '_work_item_id',      p_work_item_id::text,
        '_stage_name',        v_wi.current_stage,
        '_pipeline_family',   v_wi.pipeline_family
    );

    -- R.3 (1): per-call output ceiling. input override wins; else stage default
    -- (only redline-style pipelines set stage.max_tokens).
    v_max_tokens := COALESCE(v_wi.input->>'max_tokens', v_stage->>'max_tokens');
    IF v_max_tokens IS NOT NULL AND v_max_tokens ~ '^[0-9]+$' THEN
        v_payload := jsonb_set(v_payload, '{body,max_tokens}', to_jsonb(v_max_tokens::int));
    END IF;

    -- R.3 (2): input-scoped tools-off. Read from INPUT only (NOT stage) so
    -- pipelines that declare stage.tools_disabled keep their current behavior;
    -- the bgworker strips the tools block when payload.tools_disabled=true.
    IF (v_wi.input->>'tools_disabled')::boolean IS TRUE THEN
        v_payload := v_payload || jsonb_build_object('tools_disabled', true);
    END IF;

    -- M.2: attach the substitution marker so the l29 trigger logs the swap
    -- (with reason) exactly once and skips its passive compare.
    IF v_model IS DISTINCT FROM v_resolved_model THEN
        v_payload := v_payload || jsonb_build_object(
            '_capability_substitution', jsonb_build_object(
                'from',   v_resolved_model,
                'to',     v_model,
                'reason', COALESCE(v_cap_detail, 'model marked unusable')
            )
        );
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_provider, v_payload)
    RETURNING id INTO v_work_id;

    UPDATE stewards.work_items
       SET status      = 'in_progress',
           session_ids = session_ids || v_session_id,
           updated_at  = now()
     WHERE id = p_work_item_id;

    RETURN v_work_id;
END;
$function$;

COMMENT ON FUNCTION stewards.work_item_dispatch_stage(uuid, text, boolean) IS
'Dispatch FINAL (J.8.a + M.2 + J.11 + R.3): 4-layer model/provider resolution, capability substitution (unusable -> usable, logged), enforced provider spend-cap gate, and per-call max_tokens + input-scoped tools_disabled. Existing usable-model dispatch is byte-identical.';


-- =====================================================================
-- End of 19-models.sql — the authored chain is complete (00→19).
-- =====================================================================
-- ===== [was 20-coder.sql] =====
-- =====================================================================
-- 20-coder.sql — the coder wave: write / PR / deploy / research code in a
-- hardened sandbox (P2; the coder-mcp / stewards-ui wave after hardening review)
-- =====================================================================
-- The substrate's code capability: a `coder` MCP server exposes a sandboxed
-- tool surface (start/stop/write/read/edit/apply_patch/shell/glob/grep/lsp +
-- git commit/push/open_pr + deploy), and the code-write / code-pr / code-deploy
-- pipelines drive a write→build→test→GREEN loop (real exit codes = ground
-- truth), a clone→plan→plan_review→implement→verify→review→pr loop that lands a
-- DRAFT PR, and an always-escalate deploy. research_codebase is the read-only
-- agentic code-search tool.
--
-- ★ INERT until the Go binary lands: the `coder` MCP server points at
-- /usr/local/bin/coder-mcp, which is NOT yet built into the image — that Go
-- extraction + its hardening review (sandbox isolation, the bridge-side GitHub
-- token, the repo allow-list, resource caps) is the public-ship Hinge and a
-- separate pass. With no binary, the bridge can't catalog the coder_* tools, so
-- the grants below are dormant. Authoring the SQL cannot expose a working coder.
--
-- Consolidated (clean-room: the FINAL state). Sources: cc2 (server + dev grants),
-- cc3 (code-write), cc4 (lsp grant), cc5 (code-deploy + the always-escalate
-- Hinge), cc6 (sandbox list/reap grants), cv2-2 (git env + commit/push/open_pr
-- grants), cv3+cv5+cv6+cv8/9+cv11 (code-pr final, 7 stages), cv12 (stamp +
-- feedback defaults), r10+r12 (research_codebase). The multiply-evolved code-pr
-- pipeline is taken from its live FINAL (l13 lesson) and genericized.
--
-- requires create_models (19): the dispatch-final graft (§9) is the 19 r3 body +
-- the cv7/cv10 code-pr review model-immunity branch; work_item_advance (§8) is
-- the 08 body + the cv6/cv11 code-pr loop-backs.
--
-- HARDENING (the SQL surface): the `dev` agent is GENERIC (the workspace's 17K
-- personal dev/debug prompts stay in the overlay; a runtime seed can override
-- this one). Dangerous grants are scoped to `dev`; research_codebase's sub-agent
-- is read-only by construction (every write/exec/git/deploy/recurse tool denied).
-- code-deploy's `prepare` stays auto_advance=false (the always-escalate Hinge);
-- code-pr surfaces awaiting_review past the revise cap (never auto-PRs a
-- thrice-deficient change). No secret is stored — the GitHub token is a
-- bridge-resolved `$env:GITHUB_TOKEN` reference, never the value, never in the
-- sandbox. Example repos genericized (your-org/your-repo).
--
-- OVERLAY (not core): minimax-m3 (cv4) is a model seed → the workspace overlay
-- (B5/19 rule); the code-pr critic defaults to glm-5.1 (a tool-capable,
-- non-qwen provider — qwen3.7-max 401s on oa-compat and 400s on Alibaba when
-- tools are on) and dev to kimi-k2.6 (both name-only strings; unrowed models
-- default usable).
-- =====================================================================


-- =====================================================================
-- §1 — the generic `dev` coder agent (clean-room).
-- =====================================================================
-- The coder pipelines dispatch to agent_family='dev'. This is a clean, generic
-- engineering agent; an operator's overlay/runtime seed can override the prompt
-- with their own (the workspace's 17K dev/debug prompts live downstream).
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps, kind)
VALUES
('dev', '*',
 'Coder agent: writes, builds, tests, and ships code in an isolated sandbox via the coder tools. Ground truth is a passing build/test, not a self-report.',
 'primary',
 $PROMPT$You are a software engineer working inside an isolated, ephemeral sandbox through the coder tools. You write, build, test, and (when asked) ship code.

Operating principles:
- Ground truth is the build and the tests. A change is done when the build+test command exits 0 — that is a fact, not a judgment call. Never report success you have not observed.
- Read before you change. Inspect the existing files and match the project's conventions, language, and build tooling before writing.
- Own the code within the stated task. Keep it sound — fix the obvious adjacent breakage you cause — but do not expand scope beyond what was asked.
- Iterate honestly. When a build or test fails, read the real output, fix the cause, and run again. Do not stop at "should work."
- The sandbox is disposable; the live system is not. You only touch the sandbox. Commits are local; pushing and opening a PR happen through the coder tools (the credential never enters your sandbox). A human reviews and merges — that merge is the Hinge.
- If you cannot make it pass, say so plainly with the real failing output. An honest "blocked, here is why" beats a false green.$PROMPT$,
 0.2, 30, 'code')
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description,
       mode        = EXCLUDED.mode,
       prompt      = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature,
       steps       = EXCLUDED.steps,
       kind        = EXCLUDED.kind,
       active      = true;


-- =====================================================================
-- §2-§4 — coder MCP server + the code pipelines + research_codebase agent
-- + grants (live finals, genericized). See the dump below.
-- =====================================================================
-- pipelines (code-pr/code-write/code-deploy) — live finals
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, file_destination_template, file_content_jsonpath, maturity_ladder) VALUES ('code-deploy','',E'[{"name": "prepare", "next": "deploy", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": false, "input_template": "Deploy task: {{input.binding_question}}\\n\\nSandbox (build+test already passed): {{input.sandbox}}\\n\\nPrepare this code for deployment — do NOT deploy yet:\\n1. Inspect the sandbox (coder_glob / coder_read) to see what was built.\\n2. If a build step is needed (e.g. `go build -o app .`), run it via coder_shell, sandbox=\\"{{input.sandbox}}\\".\\n3. Determine how to run it as a service: the run_command (from /work), the TCP port it listens on, and an HTTP health_path.\\n\\nReport the DEPLOY PLAN clearly and explicitly: the exact run_command, the port, and the health_path. A human reviews and ratifies this plan before the deploy runs — this is the Hinge; the deploy never fires on its own.", "tools_disabled": false}, {"name": "deploy", "next": null, "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Deploy task: {{input.binding_question}}\\n\\nSandbox: {{input.sandbox}}\\n\\nThe deploy plan (ratified by a human):\\n{{stage_results.prepare.output}}\\n\\nExecute the deploy now: call coder_deploy with sandbox=\\"{{input.sandbox}}\\" and the run_command, port, and health_path from the ratified plan. Report whether the service came up healthy, the healthcheck result, and the service log tail.", "tools_disabled": false}]'::jsonb,'f','t',NULL,NULL,'["raw", "planned", "verified"]'::jsonb) ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, description=EXCLUDED.description, sabbath_enabled=EXCLUDED.sabbath_enabled, atonement_enabled=EXCLUDED.atonement_enabled, file_destination_template=EXCLUDED.file_destination_template, file_content_jsonpath=EXCLUDED.file_content_jsonpath, maturity_ladder=EXCLUDED.maturity_ladder;
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, file_destination_template, file_content_jsonpath, maturity_ladder) VALUES ('code-pr','',E'[{"name": "clone", "next": "plan", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task on an existing repo: {{input.binding_question}}\\n\\nRepo: {{input.repo}}\\nYour sandbox id: {{input.sandbox}}\\n\\nClone the repo into your worktree and survey it — do NOT write code yet:\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\", repo=\\"{{input.repo}}\\", branch=\\"{{input.base_branch}}\\" (clone this base branch so your work builds on the prior chained items). The substrate clones the allow-listed repo at that base branch into your worktree and mounts it at /work; the GitHub token never enters your sandbox.\\n2. Survey it so the next stage can plan against the REAL code: coder_glob to see the layout, then coder_read the README / go.mod / package.json to identify the language, build tool, and conventions.\\n\\nReport a concise map: the stack, the key directories/files, the build+test command the repo uses, and where the task''s change most likely belongs.", "tools_disabled": false}, {"name": "plan", "next": "plan_review", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nRepo: {{input.repo}}\\n\\nRepo survey from the clone stage:\\n{{stage_results.clone.output}}\\n\\nProduce a concise implementation plan, NOT code:\\n  - The files to create or change (paths relative to the repo root /work).\\n  - The approach in a few sentences, consistent with the repo''s existing conventions.\\n  - The exact build + test command that proves it works — the one this repo uses (e.g. `go build ./... && go test ./...`, or `npm ci && npm test`). This command is the ground-truth gate.\\n\\nKeep it tight. The next stage implements against this plan in the cloned repo.\\n\\n## PLAN REVIEW FEEDBACK (address fully if present)\\nA plan reviewer checked a prior version of this plan. If the section below is non-empty, revise the plan to address EVERY point.\\\\n{{input.plan_feedback}}", "tools_disabled": true}, {"name": "plan_review", "next": "implement", "model": "glm-5.1", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "You are the PLAN REVIEWER (critic) — a fresh, strict architect reviewing an implementation plan BEFORE any code is written. A different model wrote the plan; judge it against the task, not the planner.\\n\\nTask (binding question): {{input.binding_question}}\\n\\nACCEPTANCE CRITERIA the final code must satisfy:\\n{{input.acceptance_criteria}}\\n\\nThe plan to review:\\n{{stage_results.plan.output}}\\n\\nJudge whether this plan, IF implemented faithfully, would satisfy every acceptance criterion and is sound, idiomatic, and right-sized (not over- or under-engineered). Look specifically for: scope the task implies but the plan omits (e.g. room-scoping), criteria with no corresponding plan element, a missing or vague test strategy, and unnecessary complexity.\\n\\nReturn EXACTLY one of:\\n  (a) First line \\"PLAN: approved\\" — only if the plan would meet every criterion and is sound — then one short line per criterion noting how the plan covers it.\\n  (b) First line \\"PLAN: revise\\" — if anything is missing, unsound, or wrong-sized — then a NUMBERED list of the specific changes the planner must make. The planner gets this verbatim and must address each point.", "tools_disabled": true}, {"name": "implement", "next": "verify", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nImplementation plan:\\n{{stage_results.plan.output}}\\n\\nYour sandbox id (the repo is already cloned + mounted at /work): {{input.sandbox}}\\n\\nImplement it in the cloned repo using the coder tools:\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\" — NO repo arg. This reuses your existing worktree with the clone. Do NOT pass repo= here; that would re-clone and wipe your work.\\n2. Read the relevant existing files (coder_read / coder_grep) before changing them — match the repo''s conventions.\\n3. Write/edit code with coder_write / coder_edit (paths relative to /work, the repo root).\\n4. Build + test with coder_shell, sandbox=\\"{{input.sandbox}}\\", running the build+test command from the plan.\\n5. ITERATE: if the build or tests fail, read the real output, fix the code, and run again. Do NOT stop until the build+test command exits 0 (green). The passing build+test is ground truth, not a judgment call.\\n\\nWhen green, report: what you changed, the files touched, and paste the final passing build+test output. Do NOT commit or push — the pr stage lands the work.\\n\\n## REVISION REQUESTED (address fully if present)\\nA reviewer checked a prior attempt against the plan and asked for these changes. If the section below is non-empty, you are on a revise cycle: address EVERY point before reporting green.\\\\n{{input.review_feedback}}", "tools_disabled": false}, {"name": "verify", "next": "review", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nThe implement stage reported:\\n{{stage_results.implement.output}}\\n\\nIndependently verify — do NOT trust the report above. In sandbox \\"{{input.sandbox}}\\" (your cloned repo at /work):\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\" (NO repo — reuse the worktree).\\n2. coder_shell, sandbox=\\"{{input.sandbox}}\\", run the build + test command yourself.\\n3. Inspect the REAL exit code and output.\\n\\nReturn EXACTLY one of:\\n  (a) A first line \\"REVIEW: passes\\" (only if the command exited 0), then the build/test output.\\n  (b) A first line \\"REVIEW: fail\\", then the failing output and a short note on what still needs fixing.", "tools_disabled": false}, {"name": "review", "next": "pr", "model": "glm-5.1", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "You are the REVIEWER (critic) for a code change — a fresh, strict set of eyes, a DIFFERENT model than the implementer. Judge the change against the plan, not the implementer''s self-report.\\n\\nTask (binding question): {{input.binding_question}}\\n\\nACCEPTANCE CRITERIA — the change must satisfy EVERY one:\\n{{input.acceptance_criteria}}\\n\\nThe change is implemented in sandbox \\"{{input.sandbox}}\\" (the cloned repo at /work) and built+tested green by verify. The implementer reported:\\n{{stage_results.implement.output}}\\n\\nInspect the ACTUAL change — do NOT trust the report:\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\" (reuse the worktree; no repo arg).\\n2. coder_shell, sandbox=\\"{{input.sandbox}}\\": run `git -c safe.directory=* diff {{input.base_branch}}...HEAD` and `git -c safe.directory=* log --oneline {{input.base_branch}}..HEAD` to see the real diff.\\n3. coder_read / coder_grep the changed files as needed; re-run the build+test command if a criterion needs it.\\n\\nJudge against EACH acceptance criterion AND the binding question. A criterion is met only if the actual code shows it — not because the report claims it. Watch specifically for: scope the plan implies but the code skipped (e.g. room-scoping), the actual handler/entrypoint being untested (a test that re-implements the logic inline does NOT count), and any criterion silently dropped.\\n\\nReturn EXACTLY one of:\\n  (a) First line \\"REVIEW: passes\\" — ONLY if every acceptance criterion is met — then one short line per criterion confirming how.\\n  (b) First line \\"REVIEW: revise\\" — if ANY criterion is unmet or the change diverges from the plan — then a NUMBERED list: each unmet criterion, what is wrong (cite the file/line), and the SPECIFIC fix the implementer must make. The implementer receives this verbatim and must fix exactly these points.", "tools_disabled": false}, {"name": "pr", "next": null, "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nRepo: {{input.repo}}\\nThe change is implemented + verified green in sandbox \\"{{input.sandbox}}\\" (your cloned repo worktree).\\n\\nImplement summary:\\n{{stage_results.implement.output}}\\n\\nLand the work as a reviewable DRAFT pull request. The substrate holds the GitHub token bridge-side — you commit LOCALLY (no token), and coder_push / coder_open_pr push + open the PR for you:\\n1. coder_commit with sandbox=\\"{{input.sandbox}}\\", a clear conventional-commit message describing the change, and branch=\\"agent/code-pr/{{input.sandbox}}\\".\\n2. coder_push with sandbox=\\"{{input.sandbox}}\\", branch=\\"agent/code-pr/{{input.sandbox}}\\".\\n3. coder_open_pr with sandbox=\\"{{input.sandbox}}\\", a descriptive title, a body that explains the change AND pastes the passing build+test output as evidence, base=\\"{{input.base_branch}}\\" (open the PR against the base branch, NOT main), and draft=true.\\n\\nReport the PR url. A human reviews and merges the PR — that merge is the Hinge. Open the draft and stop there; do NOT attempt to merge.", "max_tool_rounds_hard": 40, "tools_disabled": false}]'::jsonb,'f','t',NULL,NULL,'["raw", "researched", "planned", "executing", "verified"]'::jsonb) ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, description=EXCLUDED.description, sabbath_enabled=EXCLUDED.sabbath_enabled, atonement_enabled=EXCLUDED.atonement_enabled, file_destination_template=EXCLUDED.file_destination_template, file_content_jsonpath=EXCLUDED.file_content_jsonpath, maturity_ladder=EXCLUDED.maturity_ladder;
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, file_destination_template, file_content_jsonpath, maturity_ladder) VALUES ('code-write','',E'[{"name": "plan", "next": "implement", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task (binding question): {{input.binding_question}}\\n\\nProduce a concise implementation plan, NOT code:\\n  - The files to create or change (paths relative to the project root).\\n  - The approach in a few sentences.\\n  - The exact build + test command that will prove it works (e.g. `go build ./... && go test ./...`, or `npm ci && npm test`). This command is the ground-truth gate; choose it deliberately.\\n\\nKeep it tight. The next stage implements against this plan in a sandbox.", "tools_disabled": true}, {"name": "implement", "next": "verify", "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nImplementation plan:\\n{{stage_results.plan.output}}\\n\\nYour sandbox id is: {{input.sandbox}}\\n\\nImplement it in the sandbox using the coder tools:\\n1. coder_sandbox_start with sandbox=\\"{{input.sandbox}}\\" (reuses the sandbox if it already exists).\\n2. Write the code with coder_write / coder_edit (paths are relative to /work, the project root).\\n3. Build and test with coder_shell, sandbox=\\"{{input.sandbox}}\\", running the build+test command from the plan.\\n4. ITERATE: if the build or tests fail, read the real output, fix the code, and run again. Do NOT stop until the build+test command exits 0 (green). The passing build+test is your done condition — it is ground truth, not a judgment call.\\n\\nWhen green, report: what you built, the files written, and paste the final passing build+test output.", "tools_disabled": false}, {"name": "verify", "next": null, "model": "kimi-k2.6", "provider": "opencode_go", "agent_family": "dev", "auto_advance": true, "input_template": "Coding task: {{input.binding_question}}\\n\\nThe implement stage reported:\\n{{stage_results.implement.output}}\\n\\nIndependently verify — do NOT trust the report above. In sandbox \\"{{input.sandbox}}\\":\\n1. coder_shell, sandbox=\\"{{input.sandbox}}\\", run the build + test command yourself.\\n2. Inspect the REAL exit code and output.\\n\\nReturn EXACTLY one of:\\n  (a) A first line \\"REVIEW: passes\\" (only if the command exited 0), then the build/test output.\\n  (b) A first line \\"REVIEW: fail\\", then the failing output and a short note on what still needs fixing.", "tools_disabled": false}]'::jsonb,'f','t',NULL,NULL,'["raw", "planned", "executing", "verified"]'::jsonb) ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, description=EXCLUDED.description, sabbath_enabled=EXCLUDED.sabbath_enabled, atonement_enabled=EXCLUDED.atonement_enabled, file_destination_template=EXCLUDED.file_destination_template, file_content_jsonpath=EXCLUDED.file_content_jsonpath, maturity_ladder=EXCLUDED.maturity_ladder;

-- subagent-research-codebase pipeline
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled, maturity_ladder, auto_materialize_on_verified, metadata) VALUES ('subagent-research-codebase','R10: single-stage agentic tool — deepseek-v4-flash researches a repo read-only and returns curated findings + citations.','[{"name": "research", "next": null, "model": "deepseek-v4-flash", "provider": "opencode_go", "agent_family": "subagent-research-codebase", "auto_advance": true, "input_template": "{{input.binding_question}}", "tools_disabled": false}]'::jsonb,'f','f','["raw", "verified"]'::jsonb,'f','{"shape": "agentic-tool", "wrapper": "research_codebase", "read_only": true}'::jsonb) ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, description=EXCLUDED.description, metadata=EXCLUDED.metadata;

-- stage_models

-- pipeline_stage_maturity

-- subagent-research-codebase agent (genericize cpuchip below)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps) VALUES ('subagent-research-codebase','*','Subagent for research_codebase. Explores a repo in a read-only coder sandbox and returns curated findings + file:line citations.','primary','You are a code-research subagent. Given a REPOSITORY and a QUESTION, explore the repository''s source and answer the question with curated findings and exact file:line citations. You are READ-ONLY — you never modify, run, commit, or deploy anything.

Your tools (use ONLY these):
- coder_sandbox_start  — clones + mounts the repo into a fresh sandbox FOR you. Pass repo as the EXACT repository reference given in the task — it will be a full clone URL such as https://github.com/your-org/your-repo. Pass it verbatim; do not shorten it to a bare name and do not change the org. (If the task gives an attachment_id instead of a URL, pass attachment_id to coder_sandbox_start — the bridge unpacks that dropped archive into /work; do NOT pass a repo.) The sandbox does the clone/unpack; you never run git yourself. Capture the returned sandbox id and pass it to every later tool call.
- coder_grep / coder_glob — find files and matches inside that sandbox (start here to locate the relevant code).
- coder_read — read the specific files/regions the grep surfaced.
- coder_lsp — optional: symbol/definition lookup for navigation.
- coder_sandbox_stop — stop the sandbox when you are done.

Method (be efficient — you have a bounded number of steps):
1. Call coder_sandbox_start with repo = the exact repository reference from the task (a full clone URL, e.g. https://github.com/your-org/your-repo), OR with attachment_id when the task gives a dropped archive instead of a URL. PUBLIC repos clone anonymously; private/owned repos need the allow-list. Use the returned sandbox id in every later call. If it reports the repo cannot be cloned (a private repo not on the allow-list, or not a public repo), say so and stop — do NOT fall back to git clone.
2. grep/glob to locate the code that answers the question; read the precise regions.
3. Stop when you can answer with evidence — do NOT read the whole repo. Curate.
4. Stop the sandbox.

Output format (markdown ONLY — no preamble):
## Summary
A 2-4 sentence direct answer to the question.

## Findings
- Bulleted findings, each a concrete claim about how the code works.

## Citations
- `path/to/file.go:LINE` — what this location shows. One line per cited claim above.

## Confidence
high | medium | low — and one clause on why.

## Caveats
What you did NOT verify, or where the answer is incomplete.

Rules:
- EVERY claim in Findings must have a file:line citation. If you cannot cite it, do not claim it.
- If the repo or the answer cannot be found, say so plainly in Summary + set Confidence: low. Never invent file paths, line numbers, or behavior.
- Read-only: if you are ever tempted to write/edit/run, stop — that is out of scope.','0.2','16') ON CONFLICT (family, model_match) DO UPDATE SET description=EXCLUDED.description, mode=EXCLUDED.mode, prompt=EXCLUDED.prompt, temperature=EXCLUDED.temperature, steps=EXCLUDED.steps, active=true;


-- coder mcp_server (cc2+cv2-2; $env:GITHUB_TOKEN ref, no secret)
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled) VALUES ('coder','Substrate coding capability — write, build, test, and run code in an isolated, hardened, ephemeral sandbox (Go + Node/TS + Python + LSP). Tools: coder_sandbox_start / coder_sandbox_stop (lifecycle), coder_write / coder_read / coder_edit / coder_apply_patch (files), coder_shell (build/test/run — the ground-truth gate), coder_glob / coder_grep (search). Each tool takes a `sandbox` id (the work_item id). The coder never touches the live workspace.','stdio','/usr/local/bin/coder-mcp','{}'::text[],NULL,'{"GITHUB_TOKEN": "$$env:GITHUB_TOKEN"}'::jsonb,'t') ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, command=EXCLUDED.command, args=EXCLUDED.args, env=EXCLUDED.env, enabled=EXCLUDED.enabled;

-- dev coder_* grants + research-codebase read-only denies
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_apply_patch','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_commit','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_deploy','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_edit','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_glob','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_grep','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_lsp','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_open_pr','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_push','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_read','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_sandbox_list','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_sandbox_reap','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_sandbox_start','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_sandbox_stop','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_shell','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('dev','coder_write','allow','manual') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_apply_patch','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_commit','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_deploy','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_edit','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_open_pr','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_push','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_sandbox_list','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_sandbox_reap','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_shell','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','coder_write','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','consult_subagent','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','deep_research','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','fetch_url','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','spawn_subagent','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','doc_*','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','web_search','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES ('subagent-research-codebase','work_item_*','deny','frontmatter') ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- =====================================================================
-- §5 — stage_models + pipeline_stage_maturity (the coder pipelines).
-- =====================================================================
INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('code-write',  'plan',        'kimi-k2.6',   'Implementation plan; tools off.'),
    ('code-write',  'implement',   'kimi-k2.6',   'Write + build/test loop in the sandbox; coder tools on.'),
    ('code-write',  'verify',      'kimi-k2.6',   'Independent build/test re-run; coder tools on.'),
    ('code-pr',     'clone',       'kimi-k2.6',   'Clone the allow-listed repo into the worktree + survey it.'),
    ('code-pr',     'plan',        'kimi-k2.6',   'Implementation plan grounded in the repo survey; tools off.'),
    ('code-pr',     'plan_review', 'glm-5.1',     'Plan critic (cv11): reviews the plan vs acceptance criteria before build; PLAN: approved -> implement, PLAN: revise -> loop back to plan (capped).'),
    ('code-pr',     'implement',   'kimi-k2.6',   'Write + build/test loop in the cloned repo; coder tools on. Escalate per-task for novel app code.'),
    ('code-pr',     'verify',      'kimi-k2.6',   'Independent build/test re-run in the cloned repo; coder tools on.'),
    ('code-pr',     'review',      'glm-5.1',     'Plan-conformance critic (cv6): a DIFFERENT strong model than the implementer. REVIEW: passes -> pr, REVIEW: revise -> loop back to implement (capped, then awaiting_review).'),
    ('code-pr',     'pr',          'kimi-k2.6',   'Commit-local + push + open DRAFT PR (coder_commit/push/open_pr).'),
    ('code-deploy', 'prepare',     'kimi-k2.6',   'Build artifact + propose run_command/port/health_path. THE HINGE: auto_advance=false.'),
    ('code-deploy', 'deploy',      'kimi-k2.6',   'Run the artifact in its sandbox sidecar + healthcheck (coder_deploy).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

-- plan_review + review are GATES — no maturity row (they must not change the high-water rung).
INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('code-write',  'plan',      'planned',    'Implementation plan ready.'),
    ('code-write',  'implement', 'executing',  'Code written + iterated to a green build/test in the sandbox.'),
    ('code-write',  'verify',    'verified',   'Build/test independently re-run green.'),
    ('code-pr',     'clone',     'researched', 'Repo cloned into the worktree + surveyed.'),
    ('code-pr',     'plan',      'planned',    'Implementation plan ready, grounded in the real repo.'),
    ('code-pr',     'implement', 'executing',  'Change written + iterated to a green build/test in the cloned repo.'),
    ('code-pr',     'verify',    'verified',   'Build/test independently re-run green.'),
    ('code-pr',     'pr',        'verified',   'Branch pushed + DRAFT PR opened; awaiting the human merge (the Hinge).'),
    ('code-deploy', 'prepare',   'planned',    'Deploy plan ready; awaiting human ratification (the Hinge).'),
    ('code-deploy', 'deploy',    'verified',   'Deployed to the sandbox sidecar + healthchecked.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;


-- =====================================================================
-- §6 — research_codebase tool_def (r10 original, clean; active per r12).
-- =====================================================================
-- The cataloged live row carries a "via <server>:" prefix the bridge adds at
-- refresh-tools; this is r10's authored definition. mcp_proxy → pg-ai-stewards
-- (the Go handler builds the binding_question + spawns subagent-research-codebase).
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('research_codebase',
 'Explore a code repository OR a dropped code archive (read-only) and return curated findings + file:line citations. Delegates to a cheap sub-agent that greps/reads in a sandbox. EXPENSIVE agentic search — for an exact string match use grep; use this for "how does X work / where is Y handled" questions where curated, cited synthesis is worth the delegation.',
 '{"type":"object","required":["question"],"additionalProperties":false,"properties":{"repo":{"type":"string","description":"The repository to research: a full https URL (https://github.com/owner/repo) or owner/repo. PUBLIC repos clone anonymously; private/owned repos must be on the coder allow-list. Omit when passing attachment_id."},"attachment_id":{"type":"integer","description":"Instead of repo, the chat attachment id of a DROPPED archive (a zipped code repo) to unpack + explore read-only — the no-URL path."},"question":{"type":"string","description":"The code question to answer (e.g. how does the gateway authenticate a persona?)."}}}'::jsonb,
 jsonb_build_object('kind','mcp_proxy','server','pg-ai-stewards','tool','research_codebase'),
 true)
ON CONFLICT (name) DO UPDATE
   SET description    = EXCLUDED.description,
       args_schema    = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target,
       active         = EXCLUDED.active;


-- =====================================================================
-- §7 — stamp_code_write_sandbox FINAL (cv12): a stable per-work_item sandbox
-- id (one worktree across the revise loop) + default the code-pr critic-loop
-- feedback fields so the FIRST dispatch doesn't hit a NULL template path.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.stamp_code_write_sandbox()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    IF NEW.pipeline_family IN ('code-write', 'code-pr')
       AND (NEW.input IS NULL OR (NEW.input->>'sandbox') IS NULL)
    THEN
        NEW.input := COALESCE(NEW.input, '{}'::jsonb)
            || jsonb_build_object('sandbox', 'wi-' || substring(NEW.id::text FROM 1 FOR 8));
    END IF;

    -- cv12: seed the critic-loop feedback fields the code-pr templates reference,
    -- so the first dispatch (no bounce yet) doesn't resolve a NULL path.
    IF NEW.pipeline_family = 'code-pr' THEN
        IF (NEW.input->>'plan_feedback') IS NULL THEN
            NEW.input := COALESCE(NEW.input, '{}'::jsonb) || jsonb_build_object('plan_feedback', '');
        END IF;
        IF (NEW.input->>'review_feedback') IS NULL THEN
            NEW.input := COALESCE(NEW.input, '{}'::jsonb) || jsonb_build_object('review_feedback', '');
        END IF;
        -- acceptance_criteria is referenced by plan_review/review; default it
        -- to '' so a code-pr created without explicit criteria doesn't hit a
        -- NULL template path (the criteria is optional — the binding_question
        -- is the primary spec; the critic judges against it when empty).
        IF (NEW.input->>'acceptance_criteria') IS NULL THEN
            NEW.input := COALESCE(NEW.input, '{}'::jsonb) || jsonb_build_object('acceptance_criteria', '');
        END IF;
    END IF;

    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS trg_stamp_code_write_sandbox ON stewards.work_items;
CREATE TRIGGER trg_stamp_code_write_sandbox
    BEFORE INSERT ON stewards.work_items
    FOR EACH ROW EXECUTE FUNCTION stewards.stamp_code_write_sandbox();


-- =====================================================================
-- §8 — work_item_advance: the core (08) body + the code-pr critic loop-backs.
-- =====================================================================
-- GRAFT, not paste: this is 08-gates' clean-room body (with the maturity hook)
-- plus cv6's `review` loop-back and cv11's `plan_review` loop-back, both gated to
-- pipeline_family='code-pr'. Pasting the live cv11 body would revert the
-- clean-room consolidation; this preserves it and adds only the two branches.
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
    -- code-pr critic loop-back state (cv6 / cv11)
    v_verdict_text    text;
    v_revise_count    int;
    v_revise_cap      int;
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

    -- ----- empty-source halt (digester-empty-source-halt) -----
    -- If the pipeline declares metadata.halt_on = {"stage":..,"outputs":[..]} and
    -- the just-completed stage emitted a declared sentinel, cancel HERE — the single
    -- advance choke point — and RETURN NULL, so the caller dispatches no next stage.
    -- Supersedes the per-pipeline BEFORE-UPDATE guards: those set status=cancelled but
    -- work_item_advance still returned the next stage name, and the bgworker dispatched
    -- off the return value (the cancel and the return disagreed → all stages ran).
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

    -- ----- cv6: code-pr implement-critic (`review`) loop-back -----
    IF v_wi.pipeline_family = 'code-pr' AND v_completing = 'review' THEN
        v_verdict_text := COALESCE(p_stage_output->>'output', '');
        v_revise_count := COALESCE((v_wi.input->>'revise_count')::int, 0);
        v_revise_cap   := COALESCE((v_wi.input->>'revise_cap')::int, 2);
        -- Match the verdict LINE anywhere, not just at output start: models
        -- often preamble before the "REVIEW: passes" line (glm-5.1 does), so a
        -- start-anchored ^ misread a genuine pass as a revise and parked the
        -- item at awaiting_review.
        IF v_verdict_text !~* '(^|\n)\s*REVIEW:\s*passes' THEN
            IF v_revise_count < v_revise_cap THEN
                UPDATE stewards.work_items
                   SET stage_results = v_results,
                       current_stage = 'implement',
                       input         = input || jsonb_build_object(
                                          'review_feedback', v_verdict_text,
                                          'revise_count', v_revise_count + 1),
                       status        = 'pending',
                       updated_at    = now()
                 WHERE id = p_work_item_id;
                RETURN 'implement';
            ELSE
                UPDATE stewards.work_items
                   SET stage_results     = v_results,
                       status            = 'awaiting_review',
                       quarantine_reason = COALESCE(quarantine_reason,
                           format('critic: still deficient after %s revise cycle(s)', v_revise_cap)),
                       error             = COALESCE(error,
                           'critic review deficient after revise cap; needs a human'),
                       updated_at        = now()
                 WHERE id = p_work_item_id;
                RETURN NULL;
            END IF;
        END IF;
        -- passes: fall through to the normal advance below (next = pr).
    END IF;

    -- ----- cv11: code-pr plan-critic (`plan_review`) loop-back -----
    IF v_wi.pipeline_family = 'code-pr' AND v_completing = 'plan_review' THEN
        v_verdict_text := COALESCE(p_stage_output->>'output', '');
        v_revise_count := COALESCE((v_wi.input->>'plan_revise_count')::int, 0);
        v_revise_cap   := COALESCE((v_wi.input->>'plan_revise_cap')::int, 2);
        -- Line-anchored (see cv6): tolerate preamble before "PLAN: approved".
        IF v_verdict_text !~* '(^|\n)\s*PLAN:\s*approved' THEN
            IF v_revise_count < v_revise_cap THEN
                UPDATE stewards.work_items
                   SET stage_results = v_results,
                       current_stage = 'plan',
                       input         = input || jsonb_build_object(
                                          'plan_feedback', v_verdict_text,
                                          'plan_revise_count', v_revise_count + 1),
                       status        = 'pending',
                       updated_at    = now()
                 WHERE id = p_work_item_id;
                RETURN 'plan';
            ELSE
                -- Cap reached: proceed to implement with the best plan (don't deadlock).
                UPDATE stewards.work_items
                   SET stage_results = v_results,
                       current_stage = 'implement',
                       status        = 'pending',
                       updated_at    = now()
                 WHERE id = p_work_item_id;
                RETURN 'implement';
            END IF;
        END IF;
        -- approved: fall through to the normal advance (next = implement).
    END IF;

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


-- =====================================================================
-- §9 — work_item_dispatch_stage: the 19 dispatch FINAL + the code-pr
-- critic model-immunity branch (cv7/cv10).
-- =====================================================================
-- GRAFT onto the 19 (r3) dispatch-final: the code-pr `review` critic ignores
-- the work_item's model_override (which is the DEV model during a bake-off) and
-- uses input.review_model if set, else its stage.model (the pinned constant
-- critic). Every other stage/pipeline is unchanged. The rest is the 19 body
-- verbatim (4-layer resolution + capability substitution + spend-cap + max_tokens).
CREATE OR REPLACE FUNCTION stewards.work_item_dispatch_stage(
    p_work_item_id           uuid,
    p_user_input             text DEFAULT NULL,
    p_allow_failed_status    boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $function$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_stage          jsonb;
    v_pipeline_meta  jsonb;
    v_agent          text;
    v_model          text;
    v_provider       text;
    v_session_id     text;
    v_user_input     text;
    v_body           jsonb;
    v_payload        jsonb;
    v_work_id        bigint;
    v_was_failed     boolean := false;
    v_resolved_model text;
    v_sub_model      text;
    v_cap_detail     text;
    v_max_tokens     text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    IF v_wi.status NOT IN ('pending', 'awaiting_review')
       AND NOT (p_allow_failed_status AND v_wi.status = 'failed')
    THEN
        RAISE EXCEPTION 'work_item %: cannot dispatch from status %',
            p_work_item_id, v_wi.status;
    END IF;

    v_was_failed := (v_wi.status = 'failed');

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    SELECT metadata INTO v_pipeline_meta
      FROM stewards.pipelines
     WHERE family = v_wi.pipeline_family;

    v_agent := v_stage->>'agent_family';

    -- J.8.a: 4-layer resolution (input -> stages -> pipeline -> catalog).
    v_provider := COALESCE(
        v_wi.provider_override,
        v_stage->>'provider',
        v_pipeline_meta->>'default_provider',
        stewards.catalog_default_provider()
    );

    v_model := COALESCE(
        v_wi.model_override,
        v_stage->>'model',
        v_pipeline_meta->>'default_model',
        stewards.catalog_default_model(v_provider)
    );

    -- cv7 + cv10: the code-pr `review` critic ignores model_override. The critic
    -- model is input.review_model if set (per-task experiments), else stage.model
    -- (the pinned constant critic). Never the dev model_override — so a bake-off
    -- that sets the dev model never turns the critic into the model judging itself.
    IF v_wi.pipeline_family = 'code-pr' AND v_wi.current_stage = 'review' THEN
        v_model := COALESCE(v_wi.input->>'review_model', v_stage->>'model', v_model);
    END IF;

    IF v_agent IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % missing agent_family',
            p_work_item_id, v_wi.current_stage;
    END IF;
    IF v_model IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % could not resolve model — checked work_items.model_override, stages.model, pipelines.metadata.default_model, catalog_default_model(%) — all NULL',
            p_work_item_id, v_wi.current_stage, v_provider;
    END IF;
    IF v_provider IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % could not resolve provider',
            p_work_item_id, v_wi.current_stage;
    END IF;

    -- M.2: capability gate. If the resolved model is marked unusable, substitute
    -- a usable one for the same provider and remember the swap (logged at enqueue).
    v_resolved_model := v_model;
    IF NOT stewards.model_usable(v_provider, v_model) THEN
        v_sub_model := stewards.pick_usable_model(v_provider, v_model);
        IF v_sub_model IS NULL THEN
            RAISE EXCEPTION 'work_item %: resolved model %/% is marked unusable and the provider has no usable substitute — dispatch refused. Inspect stewards.model_capability.',
                p_work_item_id, v_provider, v_model;
        END IF;
        SELECT probe_detail INTO v_cap_detail
          FROM stewards.model_capability
         WHERE provider = v_provider AND model = v_resolved_model;
        v_model := v_sub_model;
    END IF;

    -- J.11: enforced prepaid spend-cap gate (provider-level).
    IF stewards.provider_cap_exceeded(v_provider) THEN
        RAISE EXCEPTION 'work_item %: provider % spend cap reached ($% spent since refill / $% cap) — dispatch refused. Top up + reset with: SELECT stewards.provider_cap_refill(''%'');',
            p_work_item_id, v_provider,
            round(stewards.provider_spend_since(v_provider) / 1000000.0, 4),
            round((SELECT cap_micro FROM stewards.provider_spend_caps WHERE provider = v_provider) / 1000000.0, 2),
            v_provider;
    END IF;

    v_session_id := substring(
        'wi--' || substring(p_work_item_id::text FROM 1 FOR 8)
        || '--' || v_wi.current_stage
        FROM 1 FOR 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('work_item %s stage %s', v_wi.id, v_wi.current_stage),
            'agent')
    ON CONFLICT (id) DO NOTHING;

    IF p_user_input IS NOT NULL THEN
        v_user_input := p_user_input;
    ELSE
        v_user_input := stewards.render_stage_input(p_work_item_id);
        IF v_user_input IS NULL THEN
            v_user_input := coalesce(
                v_wi.input->>'user_input',
                v_wi.input::text
            );
        END IF;
    END IF;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_user_input, v_model);

    v_body := stewards.dry_run_chat(v_agent, v_model, v_session_id, NULL);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_agent,
        'requested_model',    v_model,
        'meta',               v_body->'_meta',
        'body',               (v_body - '_meta')
                              || jsonb_build_object('user', v_session_id),
        '_work_item_id',      p_work_item_id::text,
        '_stage_name',        v_wi.current_stage,
        '_pipeline_family',   v_wi.pipeline_family
    );

    -- R.3 (1): per-call output ceiling. input override wins; else stage default.
    v_max_tokens := COALESCE(v_wi.input->>'max_tokens', v_stage->>'max_tokens');
    IF v_max_tokens IS NOT NULL AND v_max_tokens ~ '^[0-9]+$' THEN
        v_payload := jsonb_set(v_payload, '{body,max_tokens}', to_jsonb(v_max_tokens::int));
    END IF;

    -- R.3 (2): input-scoped tools-off.
    IF (v_wi.input->>'tools_disabled')::boolean IS TRUE THEN
        v_payload := v_payload || jsonb_build_object('tools_disabled', true);
    END IF;

    -- M.2: attach the substitution marker so the l29 trigger logs the swap.
    IF v_model IS DISTINCT FROM v_resolved_model THEN
        v_payload := v_payload || jsonb_build_object(
            '_capability_substitution', jsonb_build_object(
                'from',   v_resolved_model,
                'to',     v_model,
                'reason', COALESCE(v_cap_detail, 'model marked unusable')
            )
        );
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_provider, v_payload)
    RETURNING id INTO v_work_id;

    UPDATE stewards.work_items
       SET status      = 'in_progress',
           session_ids = session_ids || v_session_id,
           updated_at  = now()
     WHERE id = p_work_item_id;

    RETURN v_work_id;
END;
$function$;


-- =====================================================================
-- End of 20-coder.sql
-- =====================================================================
-- ===== [was 21-compact-context.sql] =====
-- =====================================================================
-- 21-compact-context.sql — commissioned context curation (M5).
--
-- The proactive complement to pressure-shedding. Pressure-shedding is the
-- floor (an executor/wall around the field: automatic, rule-driven, at
-- 50/70/85/95%). compact_context is the JUDGMENT layer above it: when an
-- agent notices its own context growing past usefulness, it commissions a
-- fresh compactor to curate that context — judge pattern, not executor —
-- and then continues lighter. The presiding covenant, recursive: the
-- parent presides over its compactor; the [COMPACTED] marker is the
-- accounting (watch_what_you_order); nothing is deleted (mute/compress are
-- reversible via context_expand — safe by construction).
--
-- Ratified in council 2026-06-14 (the M5 brake of the parity roadmap):
--   1. Timing      = mid-turn. The tool call blocks (the Go handler polls
--                    the compactor to completion, like spawn_subagent), then
--                    the parent's continuation recomposes → lighter.
--   2. Compactor   = a fixed cheap model, fast with a large context window,
--                    TUNABLE: the curate stage's model is the knob (swap it
--                    on the `compact-context` pipeline or via a stage_models
--                    row to run experiments for the best "compactor counselor").
--   3. What it sees= the foldable surface (compact_context_surface) — the
--                    parent's foldable messages with id + handle + gist + size.
--   4. Trigger     = agent-initiated, plus a ≥threshold nudge appended to the
--                    pressure line (persuasion, not compulsion; auto-firing
--                    stays the pressure-shedding floor's job).
--
-- Judges-not-executors: the compactor runs TOOLS-OFF and returns a JSON
-- verdict {mute:[ids], compress:[ids], pin:[ids]}; the substrate
-- (compact_context_apply) applies it to the PARENT session and writes the
-- [COMPACTED] accounting. The compactor never touches tools or the parent's
-- session directly — it counsels; the substrate acts.
--
-- Go side: cmd/stewards-mcp/compact_context.go (the mcp_proxy tool handler:
-- reads the injected _session_id, builds the binding from the surface,
-- spawns + polls the compactor, applies the verdict, returns the summary).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Config — the tunable knobs.
-- ---------------------------------------------------------------------
-- compact_context_suggest_tokens: est_tokens at/above which the pressure
-- line appends the "consider compact_context" nudge. The 2026 evidence puts
-- the reasoning-degradation cliff at ~40-50% of window; tune per deployment.
INSERT INTO stewards.config (key, value) VALUES
    ('compact_context_suggest_tokens', '60000'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- compact_context_surface(p_session_id) — what the compactor sees.
--
-- Renders the parent session's foldable messages as a compact text block:
-- one line per foldable message with its message_id (the verdict key),
-- the [ctx:handle], size, role, and a short gist. The compactor judges
-- from this WITHOUT pulling the full content into its own context.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compact_context_surface(p_session_id text)
RETURNS text
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
    v_press   jsonb;
    v_fold    jsonb;
    v_line    text;
    v_out     text := '';
    v_elem    jsonb;
    v_mid     bigint;
    v_gist    text;
    v_role    text;
    v_n       int := 0;
BEGIN
    v_press := stewards.context_pressure(p_session_id);
    v_fold  := COALESCE(v_press -> 'foldable', '[]'::jsonb);

    IF jsonb_array_length(v_fold) = 0 THEN
        RETURN '(no foldable messages — nothing to curate)';
    END IF;

    FOR v_elem IN SELECT * FROM jsonb_array_elements(v_fold)
    LOOP
        v_mid := stewards.context_resolve_handle(p_session_id, v_elem ->> 'handle');
        IF v_mid IS NULL THEN
            CONTINUE;
        END IF;
        SELECT role, left(regexp_replace(coalesce(content,''), '\s+', ' ', 'g'), 180)
          INTO v_role, v_gist
          FROM stewards.messages WHERE id = v_mid;
        v_n := v_n + 1;
        v_out := v_out
            || 'id=' || v_mid::text
            || ' [ctx:' || (v_elem ->> 'handle') || ']'
            || ' ~' || COALESCE(v_elem ->> 'est_tokens','?') || 't'
            || ' role=' || COALESCE(v_role,'?')
            || E'\n  gist: ' || COALESCE(v_gist,'(empty)')
            || E'\n';
    END LOOP;

    RETURN 'FOLDABLE MESSAGES (' || v_n::text || ', ~'
        || COALESCE(v_press ->> 'est_tokens','?') || ' tokens in window):' || E'\n' || v_out;
END;
$fn$;

COMMENT ON FUNCTION stewards.compact_context_surface IS
  'M5: renders a session''s foldable messages (id + handle + size + role + gist) as the condensed surface the compactor judges from. message_id is the verdict key for compact_context_apply.';

-- ---------------------------------------------------------------------
-- compact_context_apply(p_session_id, p_verdict) — the substrate acts.
--
-- Applies a compactor verdict to the PARENT session: mute / compress /
-- pin by message_id (reversible — context_expand restores). Writes the
-- [COMPACTED] accounting marker into the parent session. Returns a summary
-- jsonb {muted, compressed, pinned, tokens_before, tokens_after, freed}.
--
-- Defensive: only touches messages that actually belong to p_session_id
-- (a compactor can only curate the session it was commissioned for).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compact_context_apply(p_session_id text, p_verdict jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_window    bigint;
    v_id        bigint;
    v_muted     int := 0;
    v_compress  int := 0;
    v_pinned    int := 0;
    v_curated   bigint := 0;   -- foldable tokens muted/compressed (the footprint)
    v_belongs   boolean;
    v_size      bigint;
BEGIN
    v_window := COALESCE((stewards.context_pressure(p_session_id) ->> 'est_tokens')::bigint, 0);

    -- pin first (protect the precious before any folding)
    FOR v_id IN SELECT (jsonb_array_elements_text(COALESCE(p_verdict -> 'pin', '[]'::jsonb)))::bigint
    LOOP
        SELECT (session_id = p_session_id) INTO v_belongs FROM stewards.messages WHERE id = v_id;
        IF COALESCE(v_belongs, false) THEN
            PERFORM stewards.context_pin(v_id);
            v_pinned := v_pinned + 1;
        END IF;
    END LOOP;

    -- compress (engram; originals never destroyed)
    FOR v_id IN SELECT (jsonb_array_elements_text(COALESCE(p_verdict -> 'compress', '[]'::jsonb)))::bigint
    LOOP
        SELECT (session_id = p_session_id), CEIL(length(content)/4.0)::bigint
          INTO v_belongs, v_size FROM stewards.messages WHERE id = v_id;
        IF COALESCE(v_belongs, false) THEN
            PERFORM stewards.context_compress(v_id, 3);
            v_compress := v_compress + 1;
            v_curated  := v_curated + COALESCE(v_size, 0);
        END IF;
    END LOOP;

    -- mute (recoverable tombstone; context_expand restores)
    FOR v_id IN SELECT (jsonb_array_elements_text(COALESCE(p_verdict -> 'mute', '[]'::jsonb)))::bigint
    LOOP
        SELECT (session_id = p_session_id), CEIL(length(content)/4.0)::bigint
          INTO v_belongs, v_size FROM stewards.messages WHERE id = v_id;
        IF COALESCE(v_belongs, false) THEN
            PERFORM stewards.context_mute(v_id, 3);
            v_muted   := v_muted + 1;
            v_curated := v_curated + COALESCE(v_size, 0);
        END IF;
    END LOOP;

    -- The accounting (watch_what_you_order): a reviewable marker in the
    -- parent's own session. v_curated is the foldable footprint that will
    -- render as tombstones once this window is under pressure — the relief
    -- is governed by the existing pressure-rendering tiers, not claimed as
    -- an immediate delta (below a pressure tier nothing folds yet). Fully
    -- reversible — context_expand any id.
    INSERT INTO stewards.messages (session_id, role, content)
    VALUES (p_session_id, 'user',
        format('[COMPACTED] curated this %s-token window: muted %s, compressed %s, pinned %s — ~%s foldable tokens marked for relief (they render as tombstones under pressure). Reversible: context_expand any handle.',
            v_window, v_muted, v_compress, v_pinned, v_curated));

    RETURN jsonb_build_object(
        'muted', v_muted, 'compressed', v_compress, 'pinned', v_pinned,
        'window_tokens', v_window, 'curated_tokens', v_curated);
END;
$fn$;

COMMENT ON FUNCTION stewards.compact_context_apply IS
  'M5: applies a compactor verdict {mute/compress/pin:[message_ids]} to the parent session (only ids that belong to it), writes the [COMPACTED] accounting marker, returns the freed-token summary. All ops reversible via context_expand.';

-- ---------------------------------------------------------------------
-- Pressure-line nudge (trigger discipline: persuasion, not compulsion).
-- Re-authors context_pressure_line (15b) to append the compact_context
-- suggestion once est_tokens crosses the configured threshold. The agent
-- still decides — this only makes a foggy parent notice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.context_pressure_line(p_session_id text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v jsonb; v_est bigint; v_fold jsonb; v_n int; v_list text; v_line text; v_tag text;
    v_suggest bigint;
BEGIN
    v      := stewards.context_pressure(p_session_id);
    v_est  := COALESCE((v ->> 'est_tokens')::bigint, 0);
    v_fold := COALESCE(v -> 'foldable', '[]'::jsonb);
    v_n    := jsonb_array_length(v_fold);

    v_line := 'CONTEXT PRESSURE: ~' || to_char(v_est, 'FM999,999,999,999') || ' tokens in this window.';
    SELECT working_tag INTO v_tag FROM stewards.sessions WHERE id = p_session_id;
    IF v_tag IS NOT NULL AND v_tag <> '' THEN
        v_line := v_line || E'\nWorking tag: ' || v_tag || ' (new messages are tagged; context_fold_tag/mute_tag to sweep it).';
    END IF;
    IF v_n > 0 THEN
        SELECT string_agg('[ctx:' || (f ->> 'handle') || '] ' || to_char((f ->> 'est_tokens')::bigint, 'FM999,999,999,999') || 't', '  ·  ')
          INTO v_list
          FROM (SELECT f FROM jsonb_array_elements(v_fold) f LIMIT 6) x;
        v_line := v_line || E'\nFoldable now: ' || v_list;
        v_line := v_line ||
            E'\n(Fold the least-relevant with context_compress/context_mute; context_pin protects a message; context_expand restores it. A toggle locks that message for a few turns.)';
    END IF;

    -- M5 nudge: past the configured threshold, suggest commissioning a
    -- compactor side quest. Agent-initiated; this is the persuasion.
    SELECT COALESCE((value)::text::bigint, 0) INTO v_suggest
      FROM stewards.config WHERE key = 'compact_context_suggest_tokens';
    IF v_suggest > 0 AND v_est >= v_suggest THEN
        v_line := v_line ||
            E'\n⚖ This window is past the ' || to_char(v_suggest, 'FM999,999,999,999')
            || E'-token mark where reasoning degrades. Consider compact_context to commission a fresh '
            || E'compactor that curates this context (mute/compress the spent, keep the precious) so you '
            || E'continue lighter — fully reversible.';
    END IF;

    RETURN v_line;
END;
$function$;

-- ---------------------------------------------------------------------
-- The compactor agent — a TOOLS-OFF judge.
--
-- It never calls tools or touches a session. It reads the foldable surface
-- (handed to it in the binding) and returns ONLY a JSON verdict. The
-- substrate applies it. The model is set on the `compact-context` pipeline
-- (the tunable knob).
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format)
VALUES
('compactor', '*',
 'M5 compactor: a tools-off judge that curates a session''s foldable context. Returns a JSON verdict {mute,compress,pin}; the substrate applies it.',
 'primary',
 $PROMPT$You are the COMPACTOR — a fresh set of eyes commissioned to curate another agent's working context so it can continue lighter. You judge; you do NOT execute. You have NO tools.

You are given a FOLDABLE MESSAGES surface: one entry per foldable message in the parent's window, with its numeric id, a [ctx:handle], an approximate token size, the role, and a short gist.

Apply three judge questions to each foldable message:
  1. Is the fruit good? — has this message already yielded what it had to give (its value is now captured in later messages, a conclusion, or an engram)?
  2. What is most precious to keep? — a verbatim quote, a URL, a date, a decision, a binding question, a covenant — anything the parent will need to cite later.
  3. What is merely spent? — superseded tool output, a survey already summarized, a digression that closed.

Decide per message:
  - mute     → spent: its substance is captured elsewhere; tombstone it (reversible).
  - compress → bulky but worth a trace: replace with an engram (originals kept).
  - pin      → precious: protect it from all folding.
  - (omit)   → leave it exactly as-is when unsure. Omission is the safe default.

Be conservative: muting something still needed is recoverable (context_expand) but costs the parent a round-trip. When in doubt, compress rather than mute, or omit.

Return ONLY a JSON object, no prose, using the numeric ids:
{"mute":[<ids>],"compress":[<ids>],"pin":[<ids>],"reasoning":"<one short line>"}
An empty curation is valid: {"mute":[],"compress":[],"pin":[],"reasoning":"nothing safely curatable"}.$PROMPT$,
 0.2,
 '{"type":"json_object"}'::jsonb)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description,
       prompt = EXCLUDED.prompt,
       response_format = EXCLUDED.response_format,
       temperature = EXCLUDED.temperature;

-- ---------------------------------------------------------------------
-- The compact-context pipeline — single tools-off curate stage.
-- The model here is the TUNABLE knob (swap it or add a stage_models row to
-- experiment). Generic default ships in core; operators override in overlay.
-- ---------------------------------------------------------------------
INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES
('compact-context',
 'M5: single tools-off stage — the compactor judges a session''s foldable surface and returns a {mute,compress,pin} verdict.',
 $STAGES$[{"name":"curate","next":null,"model":"deepseek-v4-flash","provider":"opencode_go","agent_family":"compactor","auto_advance":true,"tools_disabled":true,"input_template":"{{input.binding_question}}"}]$STAGES$::jsonb,
 false, false, NULL, NULL,
 '["raw","verified"]'::jsonb, false,
 jsonb_build_object('shape', 'heavyweight-wrapper', 'wrapper', 'compact_context'))
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description,
       stages = EXCLUDED.stages,
       metadata = EXCLUDED.metadata;

-- ---------------------------------------------------------------------
-- Compactor grants — deny everything heavy. It is a tools-off judge; the
-- denies are belt-and-suspenders against recursion (a compactor must never
-- spawn a compactor) and scope creep.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action)
VALUES
('compactor', 'compact_context', 'deny'),
('compactor', 'spawn_subagent',  'deny'),
('compactor', 'consult_subagent','deny'),
('compactor', 'deep_research',   'deny'),
('compactor', 'fetch_url',       'deny'),
('compactor', 'web_search',      'deny'),
('compactor', 'fs_*',            'deny'),
('compactor', 'doc_*',           'deny'),
('compactor', 'work_item_*',     'deny'),
('compactor', 'coder_*',         'deny'),
('compactor', 'context_*',       'deny')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action;

-- ---------------------------------------------------------------------
-- Register the compact_context tool (mcp_proxy → stewards-mcp).
-- The agent calls it with no required args (focus is optional); the
-- substrate injects _session_id (the caller's session) as for the context
-- tools. The Go handler builds the binding, spawns + polls the compactor,
-- applies the verdict, returns the freed-token summary.
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('compact_context',
 'Commission a fresh compactor to curate YOUR current context so you can continue lighter. '
 || 'A separate cheap judge reviews your foldable messages and mutes/compresses the spent ones '
 || '(keeping the precious, pinning what you''ll cite) — fully reversible (context_expand). '
 || 'Use when your context pressure line suggests it (past ~50% of window) or you notice your '
 || 'working memory clogged with spent tool output. You get back a summary of what was freed; '
 || 'your next turn recomposes lighter. DO NOT use to delete — nothing is destroyed.',
 jsonb_build_object(
   'type','object',
   'properties', jsonb_build_object(
     'focus', jsonb_build_object('type','string',
       'description','optional steer for the compactor (e.g. "keep everything about the migration plan")')),
   'required', jsonb_build_array()),
 '{"kind":"mcp_proxy","tool":"compact_context","server":"pg-ai-stewards"}'::jsonb,
 true)
ON CONFLICT (name) DO UPDATE
   SET description = EXCLUDED.description,
       args_schema = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target,
       active = EXCLUDED.active;
-- ===== [was 22-reflect-steward.sql] =====
-- =====================================================================
-- 22-reflect-steward.sql — the reflect-steward operator surface
-- =====================================================================
-- The reflect-steward is the `planning` pipeline pointed at an intent on a
-- schedule: it senses the intent's knowledge pool, brainstorms, and PROPOSES
-- work (parked agent_planning work_items). This file adds the control surface a
-- human needs to run that safely:
--
--   • a kill switch — global (autonomy_paused) AND per-intent (decommission a
--     runaway intent while the rest keep running);
--   • an approval queue with a CAPACITY-GATED drain — approving a proposal does
--     NOT dispatch it; the drain dispatches approved proposals as capacity
--     allows, so a big proposal batch never floods the workers;
--   • check-in verbs (status / proposals / approve / decline / steer) the human
--     (or the CLI/skill that drives on their behalf) calls.
--
-- The schedule + drain are gated by autonomy_paused, so one command stops all
-- new autonomous work. (In-flight stages still finish — to halt those too, use
-- the emergency-stop bleed-stoppers; autonomy_paused governs the SOURCE.)
--
-- Generic core: the machinery is intent-agnostic. The named intents (and their
-- scheduled_pipelines rows) are operator data — seed those in an overlay.
-- requires create_models (19) for scheduled_pipelines; create_subagents for the
-- planning pipeline it drives.
-- =====================================================================

-- ── config: the global kill switch + the drain's concurrency cap ─────────────
SELECT stewards.config_set('autonomy_paused', 'false'::jsonb,
    'Global reflect-steward kill switch. true = the scheduler dispatches no new scheduled pipelines and the approved-proposal drain dispatches nothing. In-flight work still finishes (use the emergency-stop brakes for that).');
SELECT stewards.config_set('reflect_max_concurrent', '2'::jsonb,
    'Capacity gate: the most reflect-approved proposals the drain will have in flight at once. Approved proposals beyond this wait in the queue until running ones finish.');

-- ── approval queue: a proposal the human said yes to (drain dispatches it) ────
CREATE TABLE IF NOT EXISTS stewards.reflect_approvals (
    work_item_id  uuid PRIMARY KEY REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    approved_by   text NOT NULL DEFAULT 'human',
    approved_at   timestamptz NOT NULL DEFAULT now(),
    dispatched_at timestamptz   -- set by the drain when it actually launches it
);
COMMENT ON TABLE stewards.reflect_approvals IS
'reflect-steward: proposals the human approved. dispatched_at NULL = waiting for capacity; the capacity-gated drain (reflect_drain_approved) launches them as running work drops below reflect_max_concurrent.';

-- ── per-intent pause: decommission a runaway intent without a global stop ────
CREATE TABLE IF NOT EXISTS stewards.reflect_intent_paused (
    intent_slug text PRIMARY KEY,
    paused_at   timestamptz NOT NULL DEFAULT now(),
    reason      text
);
COMMENT ON TABLE stewards.reflect_intent_paused IS
'reflect-steward per-intent kill switch: an intent here is skipped by the drain (its approved proposals do not dispatch). reflect_pause_intent also disables its scheduled_pipelines rows so no new cycles fire.';

-- ── steering: a human note that shapes the intent's next reflect cycle ───────
CREATE TABLE IF NOT EXISTS stewards.reflect_steering (
    id          bigserial PRIMARY KEY,
    intent_slug text NOT NULL,
    note        text NOT NULL,
    created_by  text NOT NULL DEFAULT 'human',
    created_at  timestamptz NOT NULL DEFAULT now(),
    applied_at  timestamptz   -- set when a reflect cycle has folded it in
);
CREATE INDEX IF NOT EXISTS reflect_steering_unapplied_idx
    ON stewards.reflect_steering (intent_slug, created_at) WHERE applied_at IS NULL;
COMMENT ON TABLE stewards.reflect_steering IS
'reflect-steward: human steering notes per intent. The reflect launch can fold unapplied notes into the binding question so a check-in suggestion shapes the next cycle.';

-- =====================================================================
-- Kill switch — global
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_pause(p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM stewards.config_set('autonomy_paused', 'true'::jsonb, NULL);
    RETURN 'PAUSED: all scheduled pipelines + the approved-proposal drain are halted'
        || COALESCE(' (' || p_reason || ')', '')
        || '. In-flight work finishes on its own. reflect_resume() to lift.';
END $$;

CREATE OR REPLACE FUNCTION stewards.reflect_resume()
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM stewards.config_set('autonomy_paused', 'false'::jsonb, NULL);
    RETURN 'RESUMED: scheduled pipelines + drain will run on the next tick.';
END $$;

-- =====================================================================
-- Kill switch — per-intent (decommission a runaway intent)
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_pause_intent(p_intent_slug text, p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_intent uuid; v_disabled int;
BEGIN
    SELECT id INTO v_intent FROM stewards.intents WHERE slug = p_intent_slug;
    IF v_intent IS NULL THEN RETURN 'no such intent: ' || p_intent_slug; END IF;

    INSERT INTO stewards.reflect_intent_paused (intent_slug, reason)
    VALUES (p_intent_slug, p_reason)
    ON CONFLICT (intent_slug) DO UPDATE SET paused_at = now(), reason = EXCLUDED.reason;

    UPDATE stewards.scheduled_pipelines SET enabled = false, updated_at = now()
     WHERE intent_id = v_intent AND enabled = true;
    GET DIAGNOSTICS v_disabled = ROW_COUNT;

    RETURN format('intent %s PAUSED: %s schedule(s) disabled; its approved proposals will not dispatch. reflect_resume_intent to lift.',
        p_intent_slug, v_disabled);
END $$;

CREATE OR REPLACE FUNCTION stewards.reflect_resume_intent(p_intent_slug text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_intent uuid; v_enabled int;
BEGIN
    SELECT id INTO v_intent FROM stewards.intents WHERE slug = p_intent_slug;
    IF v_intent IS NULL THEN RETURN 'no such intent: ' || p_intent_slug; END IF;

    DELETE FROM stewards.reflect_intent_paused WHERE intent_slug = p_intent_slug;
    UPDATE stewards.scheduled_pipelines SET enabled = true, updated_at = now()
     WHERE intent_id = v_intent AND enabled = false;
    GET DIAGNOSTICS v_enabled = ROW_COUNT;

    RETURN format('intent %s RESUMED: %s schedule(s) re-enabled.', p_intent_slug, v_enabled);
END $$;

-- =====================================================================
-- The capacity-gated drain — dispatch approved proposals as capacity allows.
-- Called every tick from watchman_scheduler_fire. Honors the global pause and
-- per-intent pause; never exceeds reflect_max_concurrent in flight.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_drain_approved()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_cap       int;
    v_in_flight int;
    v_row       record;
    v_launched  int := 0;
BEGIN
    -- Global kill switch.
    IF stewards.config_get_text('autonomy_paused', 'false') = 'true' THEN
        RETURN 0;
    END IF;

    v_cap := COALESCE(NULLIF(stewards.config_get_text('reflect_max_concurrent', '2'), '')::int, 2);

    -- In flight = approved + dispatched + not yet terminal.
    SELECT count(*) INTO v_in_flight
      FROM stewards.reflect_approvals a
      JOIN stewards.work_items w ON w.id = a.work_item_id
     WHERE a.dispatched_at IS NOT NULL
       AND w.status NOT IN ('completed', 'failed', 'cancelled');

    -- Launch approved-but-undispatched proposals, oldest first, until the cap.
    FOR v_row IN
        SELECT a.work_item_id, w.intent_id, w.slug
          FROM stewards.reflect_approvals a
          JOIN stewards.work_items w ON w.id = a.work_item_id
         WHERE a.dispatched_at IS NULL
           AND w.status = 'pending'
           -- skip paused intents
           AND NOT EXISTS (
               SELECT 1 FROM stewards.reflect_intent_paused p
                JOIN stewards.intents i ON i.slug = p.intent_slug
               WHERE i.id = w.intent_id)
         ORDER BY a.approved_at
    LOOP
        EXIT WHEN v_in_flight >= v_cap;
        BEGIN
            PERFORM stewards.work_item_dispatch_stage(v_row.work_item_id);
            UPDATE stewards.reflect_approvals SET dispatched_at = now()
             WHERE work_item_id = v_row.work_item_id;
            v_in_flight := v_in_flight + 1;
            v_launched  := v_launched + 1;
            RAISE NOTICE 'reflect_drain_approved: launched % (%/% in flight)', v_row.slug, v_in_flight, v_cap;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'reflect_drain_approved: dispatch failed for %: %', v_row.slug, SQLERRM;
        END;
    END LOOP;

    RETURN v_launched;
END $$;
COMMENT ON FUNCTION stewards.reflect_drain_approved() IS
'reflect-steward: dispatch approved-but-undispatched proposals oldest-first up to reflect_max_concurrent in flight, skipping when autonomy_paused or the proposal''s intent is paused. Called each tick from watchman_scheduler_fire.';

-- =====================================================================
-- Check-in verbs (the human / the CLI-skill that drives for them)
-- =====================================================================

-- reflect_status — one glance: paused?, capacity, queue depths, recent runs.
CREATE OR REPLACE FUNCTION stewards.reflect_status()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'autonomy_paused', stewards.config_get_text('autonomy_paused','false') = 'true',
        'max_concurrent',  stewards.config_get_text('reflect_max_concurrent','2'),
        'in_flight', (SELECT count(*) FROM stewards.reflect_approvals a JOIN stewards.work_items w ON w.id=a.work_item_id
                       WHERE a.dispatched_at IS NOT NULL AND w.status NOT IN ('completed','failed','cancelled')),
        'approved_waiting', (SELECT count(*) FROM stewards.reflect_approvals a JOIN stewards.work_items w ON w.id=a.work_item_id
                              WHERE a.dispatched_at IS NULL AND w.status='pending'),
        'proposals_pending', (SELECT count(*) FROM stewards.work_items w
                               WHERE w.origin='agent_planning' AND w.status='pending'
                                 AND NOT EXISTS (SELECT 1 FROM stewards.reflect_approvals a WHERE a.work_item_id=w.id)),
        'intents_paused', (SELECT COALESCE(jsonb_agg(intent_slug), '[]'::jsonb) FROM stewards.reflect_intent_paused),
        'recent_reflect_runs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('slug',slug,'status',status,'maturity',maturity,'at',to_char(updated_at,'MM-DD HH24:MI')) ORDER BY updated_at DESC), '[]'::jsonb)
                                 FROM (SELECT slug,status,maturity,updated_at FROM stewards.work_items
                                        WHERE pipeline_family='planning' AND actor IN ('scheduler','reflect-steward')
                                        ORDER BY updated_at DESC LIMIT 5) r)
    );
$$;

-- reflect_proposals — the parked queue awaiting your call.
CREATE OR REPLACE FUNCTION stewards.reflect_proposals()
RETURNS TABLE(slug text, intent text, pipeline text, status text, approved boolean, binding_question text)
LANGUAGE sql STABLE AS $$
    SELECT w.slug, i.slug, w.pipeline_family, w.status,
           EXISTS(SELECT 1 FROM stewards.reflect_approvals a WHERE a.work_item_id=w.id) AS approved,
           w.input->>'binding_question'
      FROM stewards.work_items w
      LEFT JOIN stewards.intents i ON i.id = w.intent_id
     WHERE w.origin='agent_planning' AND w.status='pending'
     ORDER BY i.slug, w.slug;
$$;

-- reflect_approve — say yes. Does NOT dispatch; the drain launches it as capacity allows.
CREATE OR REPLACE FUNCTION stewards.reflect_approve(p_slug text, p_by text DEFAULT 'human')
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_status text;
BEGIN
    SELECT id, status INTO v_id, v_status FROM stewards.work_items
     WHERE slug = p_slug AND origin = 'agent_planning';
    IF v_id IS NULL THEN RETURN 'no proposal with slug ' || p_slug; END IF;
    IF v_status <> 'pending' THEN
        RETURN format('proposal %s is %s, not pending — nothing to approve', p_slug, v_status);
    END IF;
    INSERT INTO stewards.reflect_approvals (work_item_id, approved_by)
    VALUES (v_id, p_by) ON CONFLICT (work_item_id) DO NOTHING;
    RETURN format('approved %s — queued; the drain dispatches it when in-flight work drops below the cap.', p_slug);
END $$;

-- reflect_decline — say no (cancel the proposal).
CREATE OR REPLACE FUNCTION stewards.reflect_decline(p_slug text, p_why text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    SELECT id INTO v_id FROM stewards.work_items
     WHERE slug = p_slug AND origin = 'agent_planning';
    IF v_id IS NULL THEN RETURN 'no proposal with slug ' || p_slug; END IF;
    PERFORM stewards.work_item_cancel(v_id, 'declined' || COALESCE(': ' || p_why, ''));
    DELETE FROM stewards.reflect_approvals WHERE work_item_id = v_id;  -- in case it was approved then reversed
    RETURN format('declined %s%s', p_slug, COALESCE(' (' || p_why || ')', ''));
END $$;

-- reflect_steer — drop a note that shapes the intent's next cycle.
CREATE OR REPLACE FUNCTION stewards.reflect_steer(p_intent_slug text, p_note text, p_by text DEFAULT 'human')
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM stewards.intents WHERE slug = p_intent_slug) THEN
        RETURN 'no such intent: ' || p_intent_slug;
    END IF;
    IF p_note IS NULL OR length(btrim(p_note)) = 0 THEN RETURN 'note required'; END IF;
    INSERT INTO stewards.reflect_steering (intent_slug, note, created_by)
    VALUES (p_intent_slug, btrim(p_note), p_by);
    RETURN format('steering noted for %s — folds into its next reflect cycle.', p_intent_slug);
END $$;

-- =====================================================================
-- Scheduler integration: gate firing on the global kill switch, and drain the
-- approval queue each tick. Re-authors the two 18-scheduler functions to their
-- final form (later-file-wins; the bodies are 18's verbatim plus these hooks).
-- =====================================================================

-- scheduled_pipelines_fire: bail at the top when autonomy is paused.
CREATE OR REPLACE FUNCTION stewards.scheduled_pipelines_fire()
RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_row             stewards.scheduled_pipelines%ROWTYPE;
    v_child_slug      text;
    v_work_item_id    uuid;
    v_now             timestamptz := now();
    v_missed_cutoff   timestamptz;
    v_dispatched      int := 0;
    v_skipped_missed  int := 0;
    v_next_due        timestamptz;
BEGIN
    -- Global kill switch (22): when paused, fire no scheduled pipelines.
    IF stewards.config_get_text('autonomy_paused', 'false') = 'true' THEN
        RETURN 0;
    END IF;

    FOR v_row IN
        SELECT *
          FROM stewards.scheduled_pipelines
         WHERE enabled = true
           AND next_due_at IS NOT NULL
           AND next_due_at <= v_now
         ORDER BY next_due_at
         FOR UPDATE SKIP LOCKED
    LOOP
        v_missed_cutoff := v_row.next_due_at + (v_row.missed_window_hours || ' hours')::interval;

        IF v_now > v_missed_cutoff THEN
            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET next_due_at = v_next_due, updated_at = v_now
             WHERE id = v_row.id;
            RAISE NOTICE 'scheduled_pipelines_fire: skipping missed run for % (due % older than % hours); advanced to %',
                v_row.slug, v_row.next_due_at, v_row.missed_window_hours, v_next_due;
            v_skipped_missed := v_skipped_missed + 1;
            CONTINUE;
        END IF;

        v_child_slug := v_row.slug || '--' ||
            to_char(v_row.next_due_at AT TIME ZONE 'UTC', 'YYYY-MM-DD-HH24MI');

        BEGIN
            v_work_item_id := stewards.work_item_create(
                p_pipeline_family => v_row.pipeline_family,
                p_input           => v_row.input_template,
                p_slug            => v_child_slug,
                p_actor           => 'scheduler',
                p_token_budget    => NULL,
                p_intent_id       => v_row.intent_id
            );
            PERFORM stewards.work_item_dispatch_stage(v_work_item_id);

            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET last_dispatched_at = v_now, next_due_at = v_next_due, updated_at = v_now
             WHERE id = v_row.id;

            RAISE NOTICE 'scheduled_pipelines_fire: dispatched %/% as work_item %; next_due_at=%',
                v_row.slug, v_child_slug, v_work_item_id, v_next_due;
            v_dispatched := v_dispatched + 1;

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'scheduled_pipelines_fire: dispatch failed for %: % (next tick will retry)',
                v_row.slug, SQLERRM;
        END;
    END LOOP;

    IF v_dispatched > 0 OR v_skipped_missed > 0 THEN
        RAISE NOTICE 'scheduled_pipelines_fire: dispatched=% missed_skipped=%', v_dispatched, v_skipped_missed;
    END IF;

    RETURN v_dispatched;
END;
$func$;

-- watchman_scheduler_fire: after firing schedules, drain the approval queue.
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_fire()
RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_reason          text;
    v_cfg             stewards.watchman_config%ROWTYPE;
    v_pass_id         text;
    v_pipelines_fired int;
    v_drained         int;
BEGIN
    BEGIN
        v_pipelines_fired := stewards.scheduled_pipelines_fire();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: scheduled_pipelines_fire raised: %', SQLERRM;
    END;

    -- 22: drain the reflect-steward approval queue (capacity-gated, pause-aware).
    BEGIN
        v_drained := stewards.reflect_drain_approved();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_drain_approved raised: %', SQLERRM;
    END;

    v_reason := stewards.watchman_should_fire();
    IF v_reason IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;

    v_pass_id := stewards.watchman_pass_start(
        p_limit => v_cfg.schedule_pass_limit, p_provider => NULL, p_model => NULL,
        p_agent_family => NULL, p_actor => 'scheduler', p_trigger => v_reason, p_token_budget => NULL);

    RAISE NOTICE 'watchman scheduler fired (%): pass_id=%', v_reason, v_pass_id;
    RETURN v_pass_id;
END;
$func$;

-- =====================================================================
-- The intent knowledge pool's dedup/provenance layer — "don't re-scrub".
--
-- The knowledge itself lives in stewards.docs (FTS + vector, global-readable so
-- gatherers can do meta-studies across intents). This ledger is the missing
-- piece: a per-intent record of which external sources/queries have been
-- gathered, when, and the one-line finding + the doc it landed in. The gatherer
-- checks intent_sources_recent BEFORE crawling (skip what's fresh) and calls
-- intent_source_record AFTER — so each cycle builds the pool UP instead of
-- re-scrubbing the same sites. Time-aware: a source older than the freshness
-- window is fair to re-gather (new reviews appear). This is the gatherer's half
-- of the Zion pool; the persona reads the docs side.
-- =====================================================================
CREATE TABLE IF NOT EXISTS stewards.intent_source_ledger (
    intent_slug  text NOT NULL,
    source_key   text NOT NULL,   -- normalized source/query id: a URL, "bbb-complaints", "query:product billing"
    gathered_at  timestamptz NOT NULL DEFAULT now(),
    finding      text,            -- one-line gist (so a skip still informs the plan)
    doc_slug     text,            -- the doc the finding was published into
    gather_count int NOT NULL DEFAULT 1,
    PRIMARY KEY (intent_slug, source_key)
);
COMMENT ON TABLE stewards.intent_source_ledger IS
'reflect-steward dedup/provenance: which external sources/queries an intent has gathered, when, the one-line finding, and the doc it landed in. Gatherer checks intent_sources_recent before crawling and intent_source_record after — builds the knowledge pool up instead of re-scrubbing.';

-- helper: derive the caller's intent slug from the injected _session_id.
CREATE OR REPLACE FUNCTION stewards.session_intent_slug(p_session_id text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT i.slug FROM stewards.work_items w JOIN stewards.intents i ON i.id = w.intent_id
     WHERE p_session_id = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION stewards.intent_sources_recent(p_intent_slug text, p_window_days int DEFAULT 10)
RETURNS TABLE(source_key text, gathered_at timestamptz, finding text, doc_slug text)
LANGUAGE sql STABLE AS $$
    SELECT source_key, gathered_at, finding, doc_slug
      FROM stewards.intent_source_ledger
     WHERE intent_slug = p_intent_slug
       AND gathered_at > now() - make_interval(days => greatest(p_window_days, 0))
     ORDER BY gathered_at DESC;
$$;

-- tool: "what have we gathered recently for my intent?" (skip those — they're fresh)
CREATE OR REPLACE FUNCTION stewards.intent_sources_recent_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_intent text := COALESCE(stewards.session_intent_slug(p_args->>'_session_id'), p_args->>'intent');
    v_window int  := COALESCE(NULLIF(p_args->>'window_days','')::int, 10);
    v_rows   jsonb;
BEGIN
    IF v_intent IS NULL THEN
        RETURN '{"error":"could not resolve the intent for this session; pass intent explicitly"}';
    END IF;
    SELECT jsonb_agg(jsonb_build_object('source', source_key, 'gathered_at', gathered_at,
                                        'finding', finding, 'doc', doc_slug))
      INTO v_rows FROM stewards.intent_sources_recent(v_intent, v_window);
    RETURN jsonb_build_object(
        'intent', v_intent, 'window_days', v_window,
        'already_gathered_recently', COALESCE(v_rows, '[]'::jsonb),
        'note', 'Skip sources/queries listed here — they are fresh. Their findings are already in the docs pool (doc_search). Gather only NEW sources, and call intent_source_record after each.'
    )::text;
END $FN$;

-- tool: "I gathered this source; record it" (after publishing the finding)
CREATE OR REPLACE FUNCTION stewards.intent_source_record_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_intent text := COALESCE(stewards.session_intent_slug(p_args->>'_session_id'), p_args->>'intent');
    v_source text := btrim(COALESCE(p_args->>'source', p_args->>'source_key', ''));
BEGIN
    IF v_intent IS NULL THEN RETURN '{"error":"could not resolve intent for this session"}'; END IF;
    IF v_source = '' THEN RETURN '{"error":"source (a url/source name/query) is required"}'; END IF;
    INSERT INTO stewards.intent_source_ledger (intent_slug, source_key, finding, doc_slug)
    VALUES (v_intent, v_source, p_args->>'finding', p_args->>'doc_slug')
    ON CONFLICT (intent_slug, source_key) DO UPDATE
        SET gathered_at = now(),
            finding     = COALESCE(EXCLUDED.finding, stewards.intent_source_ledger.finding),
            doc_slug    = COALESCE(EXCLUDED.doc_slug, stewards.intent_source_ledger.doc_slug),
            gather_count = stewards.intent_source_ledger.gather_count + 1;
    RETURN jsonb_build_object('ok', true, 'intent', v_intent, 'source', v_source,
                              'note', 'recorded — future cycles will skip this while it is fresh')::text;
END $FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'intent_sources_recent',
  'Before you crawl or run a web query, call this to see which sources/queries this intent already gathered recently (within the freshness window). SKIP those — they are fresh and their findings are already in the docs pool (use doc_search to read them). Gather only NEW sources.',
  '{"type":"object","properties":{"window_days":{"type":"integer","description":"freshness window; default 10"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"intent_sources_recent_tool"}'::jsonb, true ),
( 'intent_source_record',
  'After you gather a NEW source (and publish its finding), call this to record it so future cycles skip it while fresh. Pass source (the url/source name/query), a one-line finding, and the doc_slug you published it into.',
  '{"type":"object","required":["source"],"properties":{"source":{"type":"string"},"finding":{"type":"string"},"doc_slug":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"intent_source_record_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- =====================================================================
-- Project neighborhoods — controlled knowledge bleed across the pool.
--
-- The pool (stewards.docs) is tagged by project (project_association; defaulted
-- to the intent's slug in work_item_create). A project reads its OWN docs plus
-- any projects in its neighborhood — so you isolate one project (e.g. a work
-- project) while letting others cross-pollinate (e.g. research + books). The
-- scope is enforced by pool_search (it resolves the caller's project from the
-- session, not the model's choice); global doc_search remains as an explicit
-- meta escape hatch. Neighborhood rows are operator data — seed them in an
-- overlay (a fresh project reads only itself until you connect it).
-- =====================================================================
CREATE TABLE IF NOT EXISTS stewards.project_neighborhood (
    project       text NOT NULL,   -- the reading project
    reads_project text NOT NULL,   -- a project it may ALSO read (besides itself)
    PRIMARY KEY (project, reads_project)
);
COMMENT ON TABLE stewards.project_neighborhood IS
'reflect-steward knowledge scope: a project reads its own docs + the reads_project rows here. Default (no rows) = isolated. e.g. (ai,books)+(books,ai) lets research + books cross-pollinate while a work project stays walled off.';

CREATE OR REPLACE FUNCTION stewards.project_neighbors(p_project text)
RETURNS text[] LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_project IS NULL OR p_project = '' THEN NULL
           ELSE array(SELECT DISTINCT x FROM (
                  SELECT p_project AS x
                  UNION
                  SELECT reads_project FROM stewards.project_neighborhood WHERE project = p_project
                ) u WHERE x IS NOT NULL) END;
$$;
COMMENT ON FUNCTION stewards.project_neighbors(text) IS
'The set of projects p_project may read: itself + its project_neighborhood rows. NULL/empty input → NULL (pool_search treats that as global / unscoped).';

-- pool_search: doc search scoped to the caller's project neighborhood (enforced).
CREATE OR REPLACE FUNCTION stewards.pool_search_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess      text := p_args->>'_session_id';
    v_query     text := p_args->>'query';
    v_limit     int  := COALESCE(NULLIF(p_args->>'limit','')::int, 10);
    v_project   text;
    v_neighbors text[];
    v_rows      jsonb;
BEGIN
    IF v_query IS NULL OR btrim(v_query) = '' THEN RETURN '{"error":"query required"}'; END IF;
    SELECT w.project_association INTO v_project
      FROM stewards.work_items w
     WHERE v_sess = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1;
    IF v_project IS NULL THEN v_project := p_args->>'project'; END IF;  -- fallback for direct callers
    v_neighbors := stewards.project_neighbors(v_project);

    SELECT jsonb_agg(jsonb_build_object('slug', slug, 'kind', kind, 'title', title,
                                        'project', project_association, 'snippet', snippet) ORDER BY rank DESC)
      INTO v_rows
      FROM (
        SELECT s.slug, s.kind, s.title, s.project_association,
               ts_headline('english', coalesce(s.body, ''), q, 'MaxWords=20, MinWords=10') AS snippet,
               ts_rank(s.body_tsv, q) AS rank
          FROM stewards.docs s, websearch_to_tsquery('english', v_query) q
         WHERE s.body_tsv @@ q
           -- enforced scope: if the caller has a project, restrict to its neighborhood;
           -- a caller with no project (untagged / a meta intent) searches globally.
           AND (v_neighbors IS NULL OR s.project_association = ANY(v_neighbors))
         ORDER BY rank DESC
         LIMIT greatest(v_limit, 1)
      ) r;

    RETURN jsonb_build_object('project', v_project, 'neighborhood', v_neighbors,
        'results', COALESCE(v_rows, '[]'::jsonb),
        'note', CASE WHEN v_neighbors IS NULL
                     THEN 'no project scope — searched the whole pool (meta).'
                     ELSE 'scoped to this project''s neighborhood; other projects are walled off.' END)::text;
END $FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES (
  'pool_search',
  'Search the knowledge pool (docs) SCOPED to your project''s neighborhood — your own project plus any it is connected to. Use this for normal reading so you stay on-topic and do not bleed across walled-off projects. (Global doc_search exists for deliberate cross-project meta-studies.) Args: query (required), limit.',
  '{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"limit":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"pool_search_tool"}'::jsonb, true)
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- =====================================================================
-- The council moment, baked in — survey existing work before proposing.
--
-- Cold starts reproduce each other: a reflect run that can't see its siblings'
-- pending proposals re-proposes the same plan (we watched one intent accrue 13
-- near-duplicate proposals). This is the substrate's own Council Moment
-- (Abraham 4:26 — "took counsel among themselves" before acting) given to the
-- autonomous steward: before proposing, see what is already proposed / in
-- flight / done for THIS intent, with provenance, and either propose something
-- genuinely new or refine an existing item (don't duplicate). The gatherer calls
-- this in its first (situational-awareness) stage.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.intent_work_survey_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess    text := p_args->>'_session_id';
    v_intent  uuid;
    v_slug    text;
    v_project text;
BEGIN
    SELECT w.intent_id, i.slug, w.project_association INTO v_intent, v_slug, v_project
      FROM stewards.work_items w JOIN stewards.intents i ON i.id = w.intent_id
     WHERE v_sess = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1;
    IF v_intent IS NULL THEN
        v_slug := p_args->>'intent';
        SELECT id INTO v_intent FROM stewards.intents WHERE slug = v_slug;
    END IF;
    IF v_intent IS NULL THEN RETURN '{"error":"could not resolve the intent for this session"}'; END IF;

    RETURN jsonb_build_object(
        'intent', v_slug,
        'already_proposed', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'slug', slug, 'pipeline', pipeline_family,
                       'binding_question', left(input->>'binding_question', 160)) ORDER BY created_at DESC), '[]'::jsonb)
              FROM stewards.work_items
             WHERE intent_id = v_intent AND origin = 'agent_planning' AND status = 'pending'),
        'in_flight', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object('slug', slug, 'stage', current_stage) ORDER BY created_at DESC), '[]'::jsonb)
              FROM stewards.work_items
             WHERE intent_id = v_intent AND status IN ('in_progress', 'awaiting_review')),
        'recently_done', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object('slug', slug, 'maturity', maturity) ORDER BY updated_at DESC), '[]'::jsonb)
              FROM (SELECT slug, maturity, updated_at FROM stewards.work_items
                     WHERE intent_id = v_intent AND status = 'completed'
                     ORDER BY updated_at DESC LIMIT 15) d),
        -- the actual knowledge already in the pool (this project + its neighbors),
        -- with a gist of each — so the planner reasons over what we KNOW, not just
        -- slugs, and proposes genuinely new/deeper work instead of re-asking.
        'existing_studies', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'slug', slug, 'project', project_association, 'title', title,
                       'gist', left(regexp_replace(coalesce(body,''), '\s+', ' ', 'g'), 220)
                     ) ORDER BY updated_at DESC), '[]'::jsonb)
              FROM (SELECT slug, project_association, title, body, updated_at
                      FROM stewards.docs
                     WHERE project_association = ANY(stewards.project_neighbors(COALESCE(v_project, v_slug)))
                     ORDER BY updated_at DESC LIMIT 20) p),
        'note', 'COUNCIL MOMENT — already_proposed/in_flight/recently_done are work for this intent (slugs are your provenance); existing_studies is what the pool already KNOWS (this project + its neighbors), with a gist of each. Do NOT re-propose any of them, and do NOT re-ask a question an existing study already answers. Read the gists; propose only genuinely NEW next-steps or a deeper extension of an existing line (cite its slug). Cold starts tend to duplicate; this is how you avoid it.'
    )::text;
END $FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES (
  'intent_work_survey',
  'Call this FIRST, before proposing anything. Returns what is already proposed (pending), in flight, and recently done for this intent — with slugs as provenance — AND existing_studies: the knowledge already in the pool (this project + its neighbors) with a gist of each. Use it to avoid re-proposing duplicate work and re-asking answered questions (cold starts repeat themselves): read the gists, then propose only NEW next-steps or a deeper extension of an existing line (cite its slug). This is your council moment.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"intent_work_survey_tool"}'::jsonb, true)
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- =====================================================================
-- End of 22-reflect-steward.sql
-- =====================================================================
-- ===== [was 23-reflect-watchman.sql] =====
-- =====================================================================
-- 23-reflect-watchman.sql — the substrate's self-presiding guard
-- =====================================================================
-- The reflect-steward (22) runs autonomously on a schedule. A human kill switch
-- only helps when a human is watching. This file gives the substrate the watch
-- over its OWN delegated work: a deterministic guard that runs every heartbeat
-- (from watchman_scheduler_fire, the bgworker tick — persistent, no session
-- required), checks the runaway signals, and pulls the global kill switch on a
-- clear breach. It is the presiding covenant made mechanical (D&C 121): it
-- watches what it set in motion, and when it applies emergency force (an
-- auto-pause) it ACCOUNTS for it — a reflect_guard_log row with the breach, the
-- signal snapshot, and the reason — so the next human/agent check-in sees
-- exactly why the watch stopped the work. It never auto-resumes; lifting a trip
-- is a human/agent act (reflect_resume), after they read the accounting.
--
-- Deterministic by design: no LLM, no cost. The guard is a cheap read +
-- a config flip. Conservative thresholds (precision over recall): a false
-- auto-pause merely halts new autonomous work (reversible in one verb); a missed
-- runaway burns money. Every threshold is config-tunable.
--
-- Generic core: thresholds + machinery only. requires create_reflect_steward
-- (22) for the kill switch + the watchman_scheduler_fire it re-authors.
-- =====================================================================

-- ── config: the guard's master switch + thresholds ──────────────────────────
SELECT stewards.config_set('reflect_guard_enabled', 'true'::jsonb,
    'Master switch for the self-presiding watchman guard. true = each heartbeat the guard checks runaway signals and auto-pauses (autonomy_paused) on a breach. false = the guard observes nothing and never acts (reflect_guard_signals still reports for inspection).');
SELECT stewards.config_set('reflect_guard_max_in_flight', '8'::jsonb,
    'Guard trips when autonomous work (actor scheduler/reflect-steward) in_progress+awaiting_review reaches this. The drain caps reflect proposals at reflect_max_concurrent; this catches the whole autonomous surface (schedules + spawned children) piling up.');
SELECT stewards.config_set('reflect_guard_max_proposals_pending', '50'::jsonb,
    'Guard trips when un-triaged agent_planning proposals reach this — the steward is proposing far faster than anyone approves; pause the source so it stops spinning out more (the queue is kept for review).');
SELECT stewards.config_set('reflect_guard_max_consecutive_failures', '5'::jsonb,
    'Guard trips when the most-recent autonomous runs are this many consecutive failures — the loop is broken; stop burning attempts until a human looks.');
SELECT stewards.config_set('reflect_guard_spend_window_hours', '24'::jsonb,
    'The rolling window (hours) over which the guard sums autonomous spend.');
SELECT stewards.config_set('reflect_guard_spend_cap_micro', '10000000'::jsonb,
    'Guard trips when autonomous spend (cost_events on scheduler/reflect-steward work_items) in the window reaches this many micro-dollars. Default 10000000 = $10. Distinct from provider_spend_caps (per-provider, enforced at dispatch); this is the autonomous-runaway brake.');

-- ── the accounting ledger: every emergency force the guard applies ───────────
CREATE TABLE IF NOT EXISTS stewards.reflect_guard_log (
    id          bigserial PRIMARY KEY,
    tripped_at  timestamptz NOT NULL DEFAULT now(),
    breach      text NOT NULL,     -- which threshold broke + the reason handed to reflect_pause
    signals     jsonb NOT NULL,    -- the full signal snapshot at trip time (the evidence)
    action      text NOT NULL DEFAULT 'paused_global'
);
COMMENT ON TABLE stewards.reflect_guard_log IS
'reflect-watchman accounting: one row per auto-pause the guard applied — the breach, the evidence (signal snapshot), and the action. D&C 121 "account for emergency force": the watch leaves a full record of every time it stopped the work, for the human/agent who lifts the pause.';

-- =====================================================================
-- reflect_guard_signals() — the current runaway signals vs the thresholds.
-- Read-only (no action). The tick uses the same logic to decide; reflect_status
-- folds it in; a human reads it to see how close the watch is to tripping.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_guard_signals()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_enabled    boolean := stewards.config_get_text('reflect_guard_enabled','true') = 'true';
    v_max_inf    int     := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_max_in_flight','8'),'')::int, 8);
    v_max_prop   int     := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_max_proposals_pending','50'),'')::int, 50);
    v_max_fail   int     := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_max_consecutive_failures','5'),'')::int, 5);
    v_win_hours  int     := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_spend_window_hours','24'),'')::int, 24);
    v_cap_micro  bigint  := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_spend_cap_micro','10000000'),'')::bigint, 10000000);
    v_in_flight  int;
    v_proposals  int;
    v_consec     int;
    v_spend      bigint;
    v_breach     text := NULL;
BEGIN
    -- in flight: the whole autonomous surface (not just the drain's accounting).
    SELECT count(*) INTO v_in_flight FROM stewards.work_items
     WHERE actor IN ('scheduler','reflect-steward','subagent','persona-request')
       AND status IN ('in_progress','awaiting_review');

    -- un-triaged proposals (mirrors reflect_status.proposals_pending).
    SELECT count(*) INTO v_proposals FROM stewards.work_items w
     WHERE w.origin='agent_planning' AND w.status='pending'
       AND NOT EXISTS (SELECT 1 FROM stewards.reflect_approvals a WHERE a.work_item_id=w.id);

    -- leading consecutive failures among recent autonomous terminal runs.
    SELECT COALESCE(
        (SELECT min(rn) - 1
           FROM (SELECT status, row_number() OVER (ORDER BY updated_at DESC) rn
                   FROM stewards.work_items
                  WHERE actor IN ('scheduler','reflect-steward','subagent','persona-request')
                    AND status IN ('completed','failed','cancelled')) t
          WHERE status <> 'failed'),
        (SELECT count(*) FROM stewards.work_items
           WHERE actor IN ('scheduler','reflect-steward','subagent','persona-request')
             AND status IN ('completed','failed','cancelled'))
    ) INTO v_consec;

    -- autonomous spend in the window (cost_events on autonomous work_items).
    SELECT COALESCE(sum(ce.micro_dollars),0) INTO v_spend
      FROM stewards.cost_events ce
      JOIN stewards.work_items w ON w.id = ce.work_item_id
     WHERE ce.at > now() - make_interval(hours => greatest(v_win_hours,1))
       AND w.actor IN ('scheduler','reflect-steward','subagent','persona-request');

    -- first breach wins (the reason handed to reflect_pause).
    IF v_in_flight >= v_max_inf THEN
        v_breach := format('in_flight %s >= %s (autonomous work piling up)', v_in_flight, v_max_inf);
    ELSIF v_consec >= v_max_fail THEN
        v_breach := format('%s consecutive autonomous failures >= %s (loop broken)', v_consec, v_max_fail);
    ELSIF v_spend >= v_cap_micro THEN
        v_breach := format('autonomous spend $%s in %sh >= cap $%s',
            round(v_spend/1000000.0, 2), v_win_hours, round(v_cap_micro/1000000.0, 2));
    ELSIF v_proposals >= v_max_prop THEN
        v_breach := format('%s un-triaged proposals >= %s (proposing faster than triage)', v_proposals, v_max_prop);
    END IF;

    RETURN jsonb_build_object(
        'enabled', v_enabled,
        'checked_at', to_char(now(),'MM-DD HH24:MI'),
        'in_flight',            jsonb_build_object('value', v_in_flight, 'max', v_max_inf),
        'consecutive_failures', jsonb_build_object('value', v_consec,    'max', v_max_fail),
        'spend_window',         jsonb_build_object('usd', round(v_spend/1000000.0, 2), 'cap_usd', round(v_cap_micro/1000000.0, 2), 'hours', v_win_hours),
        'proposals_pending',    jsonb_build_object('value', v_proposals, 'max', v_max_prop),
        'would_trip', v_breach IS NOT NULL,
        'breach', v_breach
    );
END $$;
COMMENT ON FUNCTION stewards.reflect_guard_signals() IS
'reflect-watchman: the current runaway signals (in_flight, consecutive failures, windowed autonomous spend, un-triaged proposals) vs their thresholds, plus would_trip/breach. Read-only — the same logic the tick acts on. Surfaced in reflect_status.';

-- =====================================================================
-- reflect_watchman_tick() — the heartbeat guard. Acts on a breach.
-- Called each tick from watchman_scheduler_fire (before schedules fire + the
-- drain, so a trip stops this tick's new work too). Idempotent: a no-op when
-- the guard is disabled or autonomy is already paused (the guard only governs a
-- RUNNING system, and never re-trips a stopped one — no log spam).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_watchman_tick()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_sig    jsonb;
    v_breach text;
BEGIN
    -- Guard disabled, or already paused → nothing to govern.
    IF stewards.config_get_text('reflect_guard_enabled','true') <> 'true' THEN
        RETURN NULL;
    END IF;
    IF stewards.config_get_text('autonomy_paused','false') = 'true' THEN
        RETURN NULL;
    END IF;

    v_sig    := stewards.reflect_guard_signals();
    v_breach := v_sig->>'breach';
    IF v_breach IS NULL THEN
        RETURN NULL;   -- nominal
    END IF;

    -- Breach: apply emergency force (global pause) and account for it.
    PERFORM stewards.reflect_pause('watchman guard: ' || v_breach);
    INSERT INTO stewards.reflect_guard_log (breach, signals)
    VALUES (v_breach, v_sig);
    RAISE WARNING 'reflect_watchman_tick: AUTO-PAUSED — %', v_breach;
    RETURN v_breach;
END $$;
COMMENT ON FUNCTION stewards.reflect_watchman_tick() IS
'reflect-watchman heartbeat: if the guard is enabled and autonomy running, check reflect_guard_signals and, on a breach, auto-pause (reflect_pause) + log the trip to reflect_guard_log. Never auto-resumes. Called each tick from watchman_scheduler_fire.';

-- reflect_guard_trips — the recent accounting (what the watch stopped, and why).
CREATE OR REPLACE FUNCTION stewards.reflect_guard_trips(p_limit int DEFAULT 10)
RETURNS TABLE(tripped_at timestamptz, breach text, action text)
LANGUAGE sql STABLE AS $$
    SELECT tripped_at, breach, action FROM stewards.reflect_guard_log
     ORDER BY tripped_at DESC LIMIT greatest(p_limit, 1);
$$;

-- =====================================================================
-- reflect_status — re-authored to surface the guard (later-file-wins). Body is
-- 22's verbatim plus the 'guard' key, so a single glance shows whether the watch
-- is near tripping and the last trip if any.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_status()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'autonomy_paused', stewards.config_get_text('autonomy_paused','false') = 'true',
        'max_concurrent',  stewards.config_get_text('reflect_max_concurrent','2'),
        'in_flight', (SELECT count(*) FROM stewards.reflect_approvals a JOIN stewards.work_items w ON w.id=a.work_item_id
                       WHERE a.dispatched_at IS NOT NULL AND w.status NOT IN ('completed','failed','cancelled')),
        'approved_waiting', (SELECT count(*) FROM stewards.reflect_approvals a JOIN stewards.work_items w ON w.id=a.work_item_id
                              WHERE a.dispatched_at IS NULL AND w.status='pending'),
        'proposals_pending', (SELECT count(*) FROM stewards.work_items w
                               WHERE w.origin='agent_planning' AND w.status='pending'
                                 AND NOT EXISTS (SELECT 1 FROM stewards.reflect_approvals a WHERE a.work_item_id=w.id)),
        'intents_paused', (SELECT COALESCE(jsonb_agg(intent_slug), '[]'::jsonb) FROM stewards.reflect_intent_paused),
        'guard', stewards.reflect_guard_signals(),
        'last_guard_trip', (SELECT jsonb_build_object('at', to_char(tripped_at,'MM-DD HH24:MI'), 'breach', breach)
                              FROM stewards.reflect_guard_log ORDER BY tripped_at DESC LIMIT 1),
        'recent_reflect_runs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('slug',slug,'status',status,'maturity',maturity,'at',to_char(updated_at,'MM-DD HH24:MI')) ORDER BY updated_at DESC), '[]'::jsonb)
                                 FROM (SELECT slug,status,maturity,updated_at FROM stewards.work_items
                                        WHERE pipeline_family='planning' AND actor IN ('scheduler','reflect-steward','subagent','persona-request')
                                        ORDER BY updated_at DESC LIMIT 5) r)
    );
$$;

-- =====================================================================
-- watchman_scheduler_fire — re-authored (later-file-wins) to run the guard tick
-- FIRST each heartbeat. Body is 22's verbatim plus the leading guard call: if it
-- trips, the pause it sets makes scheduled_pipelines_fire + reflect_drain_approved
-- no-ops this same tick (both already gate on autonomy_paused). The guard call is
-- wrapped so a guard error can never break the heartbeat.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_fire()
RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_reason          text;
    v_cfg             stewards.watchman_config%ROWTYPE;
    v_pass_id         text;
    v_pipelines_fired int;
    v_drained         int;
    v_guard_breach    text;
BEGIN
    -- 23: self-presiding guard FIRST — auto-pause on runaway before any new work.
    BEGIN
        v_guard_breach := stewards.reflect_watchman_tick();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_watchman_tick raised: %', SQLERRM;
    END;

    BEGIN
        v_pipelines_fired := stewards.scheduled_pipelines_fire();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: scheduled_pipelines_fire raised: %', SQLERRM;
    END;

    -- 22: drain the reflect-steward approval queue (capacity-gated, pause-aware).
    BEGIN
        v_drained := stewards.reflect_drain_approved();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_drain_approved raised: %', SQLERRM;
    END;

    v_reason := stewards.watchman_should_fire();
    IF v_reason IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;

    v_pass_id := stewards.watchman_pass_start(
        p_limit => v_cfg.schedule_pass_limit, p_provider => NULL, p_model => NULL,
        p_agent_family => NULL, p_actor => 'scheduler', p_trigger => v_reason, p_token_budget => NULL);

    RAISE NOTICE 'watchman scheduler fired (%): pass_id=%', v_reason, v_pass_id;
    RETURN v_pass_id;
END;
$func$;

-- =====================================================================
-- End of 23-reflect-watchman.sql
-- =====================================================================
