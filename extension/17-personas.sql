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
