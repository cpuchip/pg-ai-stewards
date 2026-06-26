-- =====================================================================
-- examples/bounded-gather-skill.sql — a loadable "methodical gathering" skill
-- =====================================================================
-- An OPT-IN example skill (the OSS core ships the skills machinery but seeds no
-- skill content — operators bring their own). Run this against a substrate to add
-- a "bounded-gather" skill any gathering agent can load on demand.
--
-- Why: an agent that searches/extracts over a large or open-ended source with no
-- externalized worklist and no done-signal will search until it falls off the edge
-- — looping to its step cap, often producing nothing. Observed on a weak local
-- model (world-build: 235 searches, 0 entities) AND on a strong cloud model
-- (Gemini, same shape) — a strong model failing identically means it is the
-- HARNESS, not the model. This skill is the loadable, on-demand version of the
-- COMMIT discipline already baked into work-item-chat (45) and world-build (61).
--
-- To ACTIVATE it for a gathering agent: grant that agent the skill levers
-- (skill_load / skill_unload) and nudge it to load this skill when a task has it
-- gathering broadly. (Agents that already have a mechanical rail — world-build's
-- walk — do not need it.)
-- =====================================================================

INSERT INTO stewards.skills (family, model_match, description, body, active)
VALUES (
  'bounded-gather', '*',
  'Methodical gathering — how to search/extract over a large or open-ended source WITHOUT looping: commit when you have enough, treat an empty search as "absent", walk a finite set instead of re-deriving what is left, and stop on a fact not a feeling. Load this when a task has you gathering, surveying, or extracting broadly.',
  $BODY$# Methodical gathering — don't search until you fall off the edge

You are gathering over a large or open-ended source. The failure to avoid: searching
feels like progress, so you keep searching when you should be producing — and burn your
whole tool budget looping, often with nothing to show. Four rules:

1. **COMMIT.** The moment what you have retrieved answers the question, STOP searching and
   produce. Verify at most once. Producing from what you hold beats one more search.

2. **EMPTY MEANS ABSENT.** A search that returns nothing means that content is not in this
   source — move on. NEVER re-issue the same search reworded; that rephrase-and-retry is
   exactly the loop that wastes the run.

3. **KNOW YOUR FRONTIER.** If you can enumerate what you must cover — every chunk, every
   doc, every item — work THROUGH that list and track what is done, rather than re-deriving
   "what's left" from memory each turn. When the list is empty, you are finished. (If a tool
   gives you a coverage walk, use it: it is your worklist and your done-signal.)

4. **A DONE-SIGNAL IS A FACT, NOT A FEELING.** "I think I've searched enough" is not done.
   "I have answered the question" / "0 items remain" is done.

If you notice you have searched several times with little new, that IS the signal: stop and
write your result with what you have.
$BODY$,
  true
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description, body = EXCLUDED.body, active = true;

-- =====================================================================
-- End of examples/bounded-gather-skill.sql
-- =====================================================================
