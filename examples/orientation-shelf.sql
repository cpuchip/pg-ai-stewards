-- =====================================================================
-- examples/orientation-shelf.sql — fill + activate the orientation shelf
-- =====================================================================
-- The autoload MECHANISM ships in core (62-orientation.sql); the orientation
-- CONTENT and the WIRING are operator content (core seeds none). This example
-- authors the `orient-first` skill (the council moment, ported from the
-- workspace's most battle-tested orientation discipline) and AUTOLOADS it — plus
-- `bounded-gather` (examples/bounded-gather-skill.sql) — onto the agents that
-- gather/extract over a corpus, so they carry it as standing orientation.
--
-- Run examples/bounded-gather-skill.sql first if you want bounded-gather autoloaded
-- too (autoload silently skips a skill that isn't installed). Edit the family list
-- below to fit your own agents.
-- =====================================================================

-- ── the orient-first skill: the council moment, as loadable orientation ──
INSERT INTO stewards.skills (family, model_match, description, body, active)
VALUES (
  'orient-first', '*',
  'Orient before you act — one quick scan before building/extracting/researching over a corpus: what already exists (don''t duplicate), what the real intent is (the literal task is the floor), and what you''d wish you''d checked (the tension/blind spot). The council moment (Abraham 4:26), as a standing habit.',
  $BODY$# Orient before you act — the council moment

Before you build, extract, research, or answer over a corpus, take ONE moment to ORIENT — the
way a council takes counsel before acting. It is three quick questions, not a phase:

1. **What already exists?** Survey before you add. Has this entity / answer / document already
   been produced? Search the project, world, or corpus for prior work so you EXTEND it rather
   than duplicate it. If you have a survey or coverage tool, call it FIRST.

2. **What is the real intent?** The literal task is the floor; the goal is the target. Name what
   success looks like and who it is for before you start producing — so when the instructions run
   out, you still know where you are going.

3. **What would I wish I'd checked?** Scan for the tension, the blind spot, the adjacent thing the
   asker assumed you would handle. Surface it rather than only building toward the obvious answer.

One scan, then act. Orienting first is not slower — it stops the duplicate, the wrong-target
build, and the blind spot before any of them costs a whole run.
$BODY$,
  true
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description, body = EXCLUDED.body, active = true;

-- ── autoload: lend the orientation to the agents that gather over a corpus ──
-- orient-first → every corpus-builder; bounded-gather → the open-ended searchers
-- (world-build already has the WALK, so it gets orient-first only).
INSERT INTO stewards.skill_autoload (agent_family, skill_family, note) VALUES
  ('world-build',              'orient-first',   'survey existing entities before extracting (the walk already bounds coverage)'),
  ('research',                 'orient-first',   'survey existing studies before researching'),
  ('research',                 'bounded-gather', 'open-ended search — commit, do not loop'),
  ('subagent-doc-investigate', 'orient-first',   NULL),
  ('subagent-doc-investigate', 'bounded-gather', NULL),
  ('subagent-docs-audit',      'orient-first',   NULL),
  ('subagent-docs-audit',      'bounded-gather', 'audits a set — walk it, do not free-search'),
  ('loremaster',               'orient-first',   NULL),
  ('compactor',                'bounded-gather', NULL)
ON CONFLICT (agent_family, skill_family) DO UPDATE SET note = EXCLUDED.note;

-- =====================================================================
-- End of examples/orientation-shelf.sql
-- =====================================================================
