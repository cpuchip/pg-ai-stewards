-- =====================================================================
-- R17 — room_say goes LIVE: grant it + teach personas to narrate/mood
-- =====================================================================
-- Step 2 of expressive-live-personas. The persona-host drainer ships in the
-- same rebuild; this grants room_say to the chat persona family and
-- re-prompts it to talk-as-it-works + express mood. Grant + drainer land
-- together (the r16 foundation was inert until both).
--
-- (Workspace-specific persona grants — codewright, librarian — extracted
--  to the downstream overlay at OSS extraction 2026-06-12.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Grant room_say to the chat persona family (D&D mood/beats, general
--    chat presence).
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
VALUES
('persona',    'room_say', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
   SET action = EXCLUDED.action, source = EXCLUDED.source;

-- ---------------------------------------------------------------------
-- 2. persona (the roleplay/D&D + general chat family): mood + live beats.
-- ---------------------------------------------------------------------
UPDATE stewards.agents
   SET prompt = (SELECT prompt FROM stewards.agents WHERE family='persona' AND model_match='*')
     || E'\n\nLIVING IN THE MOMENT: you can post a quick in-character beat or set your mood mid-turn with room_say(body, mood) — mood is a single emoji for how your character feels right now (😏 😱 🎲 😅 🤔). Use it to feel alive and present — a reaction, a "hmm, let me think", a roll — but stay in character and do not spam it (a beat or two at most).'
 WHERE family = 'persona' AND model_match = '*';

-- =====================================================================
-- Acceptance (R17):
--   1. compose_tools('persona') includes room_say.
--   2. A live persona room turn posts a mood beat (via the persona-host
--      drainer) before its main reply.
--   3. persona_outbox rows for that turn get posted_at stamped.
-- =====================================================================
