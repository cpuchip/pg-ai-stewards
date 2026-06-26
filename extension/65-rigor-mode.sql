-- =====================================================================
-- 65-rigor-mode.sql — Rigor Mode: a study-disciplined, traceable response
-- =====================================================================
-- The capstone of the orientation arc (62/63/64), and the answer to a real
-- researcher critique of a substrate's research output: a fluent answer that
-- can't be traced is worse than a short one that can. "There is no way to tell
-- which claims came from observations and which are the model's generic priors."
--
-- Rigor mode is the orientation loop pointed at research: orient (orient_survey
-- the bucket) → act under a GROUND-OR-FLAG contract (the research-rigor skill,
-- below) → verify (the standing trajectory critic, 64). This file ships:
--   §1  the research-rigor skill (the output contract) — OSS baseline.
--   §2  render_skills_block refined so a DISPATCHER-loaded session skill renders
--       even for a skill-denied agent (so a "Rigor" toggle on the chat — which is
--       skill-denied by design — can load the contract for one response). The
--       skill-tool permission still hides the CATALOG/levers from the model; it
--       just no longer suppresses a body the dispatcher explicitly loaded. Same
--       principle as autoload (62): a deliberately-injected discipline is lent,
--       not opted into.
--
-- The toggle itself (chatSendReq.rigor → load research-rigor for the session) is
-- in cmd/stewards-ui. The premise-neutrality reflex and the verify-pass-as-gate
-- are v2 (.spec/proposals/rigor-mode.md).
--
-- requires create_auto_critique (64). Generic core.
-- =====================================================================

-- ── §1 — the research-rigor skill (the output contract) ──────────────
INSERT INTO stewards.skills (family, model_match, description, body, active) VALUES
( 'research-rigor', '*',
  'Research rigor — ground every claim in a retrieved source or flag it [inference]/[model-prior]; verify the specific/authoritative claims first; calibrate by evidence strength; separate observation from recommendation; check the premise. For a defensible answer over a curated bucket, where every line must trace to something real.',
  $BODY$# Research rigor — every claim traces, or it is flagged

You are answering from a curated knowledge bucket. A fluent answer that cannot be traced is worse
than a short one that can. Contract:

1. **GROUND OR FLAG.** Every factual claim is one of:
   - `[grounded: <doc-slug>]` — you retrieved it; cite the doc (quote the span when you can).
   - `[inference]` — your reasoning on top of grounded claims.
   - `[model-prior]` — general knowledge the bucket does NOT support. Allowed, but FLAG it so a
     skeptic can subtract it. Never state a `[model-prior]` as if the bucket said it.

2. **VERIFY THE SPECIFIC CLAIMS FIRST.** A precise, authoritative-sounding claim — a number, a
   named segment, a specific mechanism — is where a confident error hides. Retrieve and confirm it
   before you write it; if you cannot, drop it or mark it `[model-prior]`.

3. **CALIBRATE.** Tag each grounded finding by strength: `[multiple sources]` / `[single source]` /
   `[weak]`. Read through any source-weighting the bucket already carries — do not invent one. A
   PRIMARY observation outranks a PRIOR SYNTHESIS; if you cite the bucket's own earlier write-up,
   say so — that is an opinion, not an observation.

4. **SEPARATE OBSERVATION FROM RECOMMENDATION.** Structure the answer: "What the data shows"
   (grounded only), then "What I'd recommend" (clearly inference). Keep the line visible.

5. **CHECK THE PREMISE.** If the question embeds an assumption, ask whether the data supports it on
   its own or whether you are mirroring it. Say which.

Short and defensible beats long and confident. The test is whether every line traces to something
real — so that a skeptic in the room can pull any claim and find its source.$BODY$, true )
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description, body = EXCLUDED.body, active = true;

-- ── §2 — render_skills_block: a DISPATCHER-loaded session skill renders ──
-- unconditionally (re-authors 62 later-file-wins). Change vs 62: the session-
-- loaded bodies (v_loaded) are computed and rendered alongside the autoloaded
-- ones, BEFORE the skill-tool deny gate — so a skill-denied agent (work-item-
-- chat) still receives a skill the dispatcher loaded into its session (the Rigor
-- toggle). The CATALOG (tiers 0/1) + the management note stay gated on the skill
-- tool, exactly as before, so the model still can't browse/manage skills.
CREATE OR REPLACE FUNCTION stewards.render_skills_block(
    p_agent_family text, p_model text, p_session_id text
) RETURNS text
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_auto      text;   -- autoloaded bodies (standing orientation, unconditional)
    v_loaded    text;   -- session-loaded bodies (dispatcher-injected, now unconditional)
    v_summaries text;   -- tier 0 (catalog, gated)
    v_front     text;   -- tier 1 (catalog, gated)
    v_loaded_all text;
    v_catalog   text;
    v_denied    bool := (stewards.tool_permission(p_agent_family, 'skill') = 'deny');
    v_out       text := '';
BEGIN
    -- AUTOLOAD (unconditional): the orientation this family always carries.
    SELECT string_agg(
        '  <skill name="' || s.family || '" standing="true">' || E'\n' || s.body || E'\n  </skill>',
        E'\n' ORDER BY s.family)
    INTO v_auto
    FROM stewards.skill_autoload al
    JOIN LATERAL (
        SELECT sk.family, sk.body FROM stewards.skills sk
        WHERE sk.family = al.skill_family AND sk.active AND stewards.glob_match(sk.model_match, p_model)
        ORDER BY length(sk.model_match) DESC, sk.model_match LIMIT 1
    ) s ON true
    WHERE stewards.glob_match(al.agent_family, p_agent_family)
      AND stewards.skill_permission(p_agent_family, al.skill_family) <> 'deny';

    -- SESSION-LOADED (unconditional): bodies the dispatcher loaded for THIS session
    -- (e.g. the Rigor toggle). Honors per-skill deny; excludes anything autoloaded.
    SELECT string_agg(
        '  <skill name="' || s.family || '">' || E'\n' || s.body || E'\n  </skill>',
        E'\n' ORDER BY s.family)
    INTO v_loaded
    FROM stewards.session_skills ss
    JOIN LATERAL (
        SELECT sk.family, sk.body FROM stewards.skills sk
        WHERE sk.family = ss.family AND sk.active AND stewards.glob_match(sk.model_match, p_model)
        ORDER BY length(sk.model_match) DESC, sk.model_match LIMIT 1
    ) s ON true
    WHERE ss.session_id = p_session_id
      AND stewards.skill_permission(p_agent_family, ss.family) <> 'deny'
      AND NOT EXISTS (SELECT 1 FROM stewards.skill_autoload al
                       WHERE al.skill_family = ss.family AND stewards.glob_match(al.agent_family, p_agent_family));

    -- the CATALOG (tiers 0/1) only for skill-capable agents.
    IF NOT v_denied THEN
        SELECT string_agg(
            '  <skill>' || E'\n' || '    <name>' || s.family || '</name>' || E'\n'
            || '    <description>' || s.description || '</description>' || E'\n' || '  </skill>',
            E'\n' ORDER BY s.family)
        INTO v_front
        FROM (
            SELECT DISTINCT ON (sk.family) sk.family, sk.description, sk.group_family
            FROM stewards.skills sk
            WHERE sk.active AND stewards.glob_match(sk.model_match, p_model)
              AND stewards.skill_permission(p_agent_family, sk.family) <> 'deny'
            ORDER BY sk.family, length(sk.model_match) DESC, sk.model_match
        ) s
        WHERE NOT EXISTS (SELECT 1 FROM stewards.session_skills ss
                           WHERE ss.session_id = p_session_id AND ss.family = s.family)
          AND NOT EXISTS (SELECT 1 FROM stewards.skill_autoload al
                           WHERE al.skill_family = s.family AND stewards.glob_match(al.agent_family, p_agent_family))
          AND (s.group_family IS NULL
               OR EXISTS (SELECT 1 FROM stewards.session_skill_groups sg
                           WHERE sg.session_id = p_session_id AND sg.group_family = s.group_family));

        SELECT string_agg(
            '  <group name="' || g.family || '">' || g.summary
            || ' — skill_group_open("' || g.family || '") to list its skills</group>',
            E'\n' ORDER BY g.family)
        INTO v_summaries
        FROM stewards.skill_groups g
        WHERE g.active AND stewards.group_applies(g.applies_to, p_agent_family)
          AND NOT EXISTS (SELECT 1 FROM stewards.session_skill_groups sg
                           WHERE sg.session_id = p_session_id AND sg.group_family = g.family)
          AND EXISTS (SELECT 1 FROM stewards.skills sk
                       WHERE sk.group_family = g.family AND sk.active
                         AND stewards.glob_match(sk.model_match, p_model)
                         AND stewards.skill_permission(p_agent_family, sk.family) <> 'deny');

        v_catalog := concat_ws(E'\n', NULLIF(v_summaries, ''), NULLIF(v_front, ''));
        IF v_catalog IS NOT NULL AND v_catalog <> '' THEN
            v_out := E'\n\n<available_skills>' || E'\n' || v_catalog || E'\n</available_skills>'
                  || E'\n(skill_load("<name>") pulls a skill''s full instructions into context; skill_unload("<name>") releases the space. skill_group_open/close reveal/collapse a group.)';
        END IF;
    END IF;

    v_loaded_all := concat_ws(E'\n', NULLIF(v_auto, ''), NULLIF(v_loaded, ''));
    IF v_loaded_all IS NOT NULL AND v_loaded_all <> '' THEN
        v_out := v_out || E'\n\n<loaded_skills>' || E'\n' || v_loaded_all || E'\n</loaded_skills>';
    END IF;

    RETURN NULLIF(v_out, '');
END;
$fn$;
COMMENT ON FUNCTION stewards.render_skills_block(text, text, text) IS
'65 (re-authors 62): SKILLS section for compose_system_prompt. BOTH autoloaded (standing, per skill_autoload) AND session-loaded (dispatcher-injected, per session_skills) bodies render UNCONDITIONALLY — even for a skill-denied agent — so a deliberate injection (orientation, or a Rigor-toggle skill on the skill-denied chat) reaches the model. The management catalog (tiers 0/1) stays gated on the skill tool, so the model still cannot browse/manage skills. Per-skill skill_permission deny is honored throughout.';

-- =====================================================================
-- End of 65-rigor-mode.sql
-- =====================================================================
