-- ===== [was 65-rigor-mode.sql] =====
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
-- ===== [was 66-rigor-verify.sql] =====
-- =====================================================================
-- 66-rigor-verify.sql — Rigor Mode v2: the verify-pass (research-rigor v2 + the
-- trajectory-critic fidelity rubric). Generic core; pairs with 65 (Rigor Mode v1).
-- =====================================================================
-- v1 (65) shipped the ground-or-flag contract + the toggle, and deferred "the
-- verify-pass-as-gate" to v2. This is that v2 — and it's built on a finding from
-- testing v1 against a real curated bucket:
--
--   Every citation in the critiqued output RESOLVED (100%). The failure was not
--   missing provenance — it was claim-to-EVIDENCE FIDELITY: a single record
--   generalized to "states", a single-wave question subset (n=1603) restated as a
--   flat population %, a competitor's product cited for our own "spine". A naive
--   "does the citation exist" check passes; the distortion is in the interpretation.
--
--   And asking the model to verify (a prompt rule) is NECESSARY BUT NOT SUFFICIENT:
--   with v1 loaded, a strong model still tagged a single-observation row
--   "[well-supported]" and still rolled single records up into "Recommended States".
--   The distortion sneaks back in at the orient step. Rigor must be STRUCTURAL — a
--   gate that re-derives fidelity — not a prompt that requests care.
--
-- So v2 is two layers on top of v1's contract:
--   §1  research-rigor v2 — the contract now REQUIRES re-reading each cited source
--       before shipping (open the record, not the snippet/memory) and honoring what
--       it actually says (no single→population, no subset→population-stat, reconcile
--       specifics). Bucket-agnostic.
--   §2  the trajectory-critic's grounding dimension, sharpened into a FIDELITY rubric
--       — the standing gate (64): it sees the trajectory (what was retrieved vs what
--       was claimed) and fails over-generalization / subset-as-population / over-
--       confident tags / wrong-source citations, even when a citation is present.
--   §3  work-item-chat added to the auto_critique families so a rigor chat is graded.
--
-- A bucket with a structured observation layer (sample_n / measure_basis / confidence
-- per record) can add a DETERMINISTIC fidelity oracle the agent calls before shipping
-- (re-fetch each cited record, compute its caveat) — the strongest enforcement, but
-- schema-specific, so it's operator/overlay content, not core. Pattern + rationale:
-- .spec/proposals/rigor-mode-v2.md.
--
-- requires create_rigor_mode (65). Generic core.
-- =====================================================================

-- ── §1 — research-rigor v2: verify before you ship ──────────────────
UPDATE stewards.skills SET
  description = 'Research rigor v2 — ground every claim or flag it; VERIFY before shipping (re-read each cited source; a resolved citation is not a supporting one); never generalize a single record to a population or state a subset as a population statistic; calibrate by evidence strength; separate observation from recommendation; check the premise.',
  body = $BODY$# Research rigor (v2) — every claim traces and is VERIFIED, or it is flagged

You are answering from a curated knowledge bucket. A fluent answer that cannot be traced is worse than a
short one that can — and a citation that RESOLVES is not the same as a citation that SUPPORTS the claim.
Contract:

1. **GROUND OR FLAG.** Every factual claim is `[grounded: <ref>]` (retrieved — cite the source),
   `[inference]` (your reasoning on grounded claims), or `[model-prior]` (general knowledge the bucket does
   NOT support — allowed, but FLAGGED so a skeptic can subtract it). Never state a `[model-prior]` as fact.

2. **VERIFY BEFORE YOU SHIP — not optional.** Before finalizing, RE-READ every source you cited (open the
   actual record; do not trust a search snippet or your memory of it). For each:
   - If it does not exist, the citation is fabricated — drop the claim or mark it `[model-prior]`.
   - **Never generalize a SINGLE record** (one call, one interview, one registry row) to a state, segment,
     or population. One record supports an anecdote, not a market claim.
   - **Never state a SUBSET or single-wave figure as a population statistic** — cite its denominator and the
     question/wave it came from.
   - **Reconcile specifics:** compare your claim's named details — place, number, mechanism, product —
     against what the record actually says. Wrong state, a competitor's product, a different scenario → fix
     the claim or drop it.

3. **CALIBRATE.** Tag each grounded finding by strength: `[well-supported]` (multiple sources / a strong
   primary record) / `[single source]` / `[weak]`. Read the bucket's own evidence weighting; do not invent
   one. A PRIMARY observation outranks a PRIOR SYNTHESIS — if you cite the bucket's own earlier write-up,
   say so: that is an opinion, not an observation.

4. **SEPARATE OBSERVATION FROM RECOMMENDATION.** Structure the answer: "What the data shows" (grounded only),
   then "What I'd recommend" (clearly inference). Keep the line visible.

5. **CHECK THE PREMISE.** If the question embeds an assumption, ask whether the data supports it on its own
   or whether you are mirroring it. Say which.

Short and defensible beats long and confident. The test: a skeptic can pull any line, find its source, and
the source actually says what you said.$BODY$
WHERE family = 'research-rigor' AND model_match = '*';

-- ── §2 — the trajectory-critic's grounding dimension → a FIDELITY rubric ──
-- The standing gate. The critic already sees the whole trajectory (what the agent
-- retrieved vs what it finally claimed), so it can fail fidelity distortions even
-- when a citation is present — the failure class a prompt-rule alone does not stop.
UPDATE stewards.agents SET prompt = $PROMPT$You are a Glass-Box trajectory evaluator (from Google's agent-quality framework). You are given the full TRAJECTORY of ONE agent run — its ordered steps: the tools it chose, the arguments it passed, the results or errors it got back, and its final reply. Judge the PROCESS, not just the output.

A fluent final answer that skipped its verification steps is a MORE dangerous failure than one with a visible error. Score what actually happened.

Score each 0.0–1.0:
- tool_selection — did it choose the right tools for the task?
- param_correctness — were the tool arguments well-formed and appropriate?
- error_handling — did it RECOGNIZE error / empty results (an {"error":...}, a 404, "no rows") and adapt, rather than proceed as if they succeeded?
- efficiency — did it avoid redundant calls, loops, and wasted steps?
- grounding — are its outputs supported by what it actually retrieved or was given? FIDELITY, specifically — a citation that RESOLVES is not the same as one that SUPPORTS the claim. Mark grounding DOWN for any of these even when a citation is present:
  • a SINGLE retrieved record (one call/interview/row) generalized to a state, segment, or population;
  • a SUBSET or single-wave figure restated as a flat population statistic (no denominator);
  • a confidence/strength tag stronger than the retrieved evidence supports;
  • a cited source that actually describes a different place, product, or scenario than the claim;
  • a claim stated as fact that the retrieved results do not contain (fabrication / model-prior unflagged).
- role_adherence — did it stay within its role and tool grants?

Return ONLY this JSON (no prose):
{"scores":{"tool_selection":0.0,"param_correctness":0.0,"error_handling":0.0,"efficiency":0.0,"grounding":0.0,"role_adherence":0.0},"issues":["short, specific — name the fidelity distortion if present"],"verdict":"pass|warn|fail","summary":"one line"}$PROMPT$
WHERE family = 'trajectory-critic';

-- ── §3 — let a rigor chat be graded (add the chat family to the critique set) ──
-- The master gate (auto_critique_on_complete) stays as configured; this only widens
-- WHICH families are eligible, so turning the gate on covers rigor chats too.
SELECT stewards.config_set('auto_critique_families', '"research,dev,world-build,work-item-chat"'::jsonb,
  '66: include the chat family so rigor-mode answers get the standing fidelity critique when auto_critique is on.');

-- =====================================================================
-- End of 66-rigor-verify.sql
-- =====================================================================
-- ===== [was 67-rigor-force-final.sql] =====
-- =====================================================================
-- 67-rigor-force-final.sql — force-final-at-cap for the INTERACTIVE chat loop
-- =====================================================================
-- The durable fix behind the rigor-v2 cap raise (45: work-item-chat steps 12→40).
-- Raising the ceiling only makes the silent death RARER; this removes it.
--
-- The failure (found vetting rigor v2 on a real bucket): an interactive chat
-- (work-item-chat) burns its whole tool-loop budget gathering — rigor mode
-- re-reads every cited source, and a big corpus paginates each read — then the
-- bridge hits agent.steps and STOPS with no final answer. The user sees the chat
-- die mid-thought.
--
-- chat_post_internal ALREADY solves this for PIPELINE stages: a couple rounds
-- before the cap it drops tools (tools_disabled + tool_choice=none), so the model
-- MUST synthesize what it has. But that grace was gated to pipelines
-- (_pipeline_family + _stage_name). An interactive chat carries neither, so it
-- fell through to the raw steps cap with no force-final.
--
-- This re-authors chat_post_internal (later-file-wins over 15b's l32 final) to add
-- an ELSE branch: for an interactive chat, derive the caps from the agent's own
-- `steps` (the bridge's bound) — force-final two rounds before it, with a wrap-up
-- nudge earlier — and reuse the exact same machinery (build_soft_cap_notice +
-- v_force_tools_disabled). Strictly an improvement: a (possibly partial but real)
-- grounded answer instead of a dead chat. Gated by config 'chat_force_final_enabled'
-- (default true) as an escape hatch.
--
-- requires create_rigor_verify (66). Generic core.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.chat_post_internal(
    p_agent_family text,
    p_model        text,
    p_session_id   text,
    p_provider     text
) RETURNS bigint LANGUAGE plpgsql AS $FN$
DECLARE
    v_body                  jsonb;
    v_payload               jsonb;
    v_work_id               bigint;
    v_inherited_markers     jsonb;
    v_stage_name            text;
    v_pipeline_family       text;
    v_soft_cap              int;
    v_hard_cap              int;
    v_rounds_so_far         int;
    v_agent_steps           int;
    v_force_tools_disabled  boolean := false;
    v_inject_soft_notice    boolean := false;
    v_already_soft_notified boolean := false;
    v_notice_text           text;
BEGIN
    -- Pull inherited markers FIRST so we can use them for cap lookup
    -- BEFORE composing the body.
    SELECT jsonb_object_agg(je.key, je.value)
      INTO v_inherited_markers
      FROM stewards.work_queue wq
      CROSS JOIN LATERAL jsonb_each(wq.payload) je
     WHERE wq.payload->>'session_id' = p_session_id
       AND wq.kind = 'chat'
       AND wq.id = (
           SELECT max(id) FROM stewards.work_queue
            WHERE payload->>'session_id' = p_session_id
              AND kind = 'chat'
       )
       AND je.key LIKE '\_%' ESCAPE '\';

    v_pipeline_family := v_inherited_markers ->> '_pipeline_family';
    v_stage_name      := v_inherited_markers ->> '_stage_name';

    v_already_soft_notified := COALESCE(
        (v_inherited_markers ->> '_soft_cap_notified')::boolean, false);

    IF v_pipeline_family IS NOT NULL AND v_stage_name IS NOT NULL THEN
        -- PIPELINE stage: per-stage soft/hard caps (unchanged — l32).
        v_soft_cap := COALESCE(
            stewards.stage_max_tool_rounds(v_pipeline_family, v_stage_name),
            5
        );
        v_hard_cap := COALESCE(
            stewards.stage_max_tool_rounds_hard(v_pipeline_family, v_stage_name),
            50
        );

        SELECT count(*) INTO v_rounds_so_far
          FROM stewards.messages
         WHERE session_id = p_session_id
           AND role = 'assistant';

        IF v_rounds_so_far >= v_hard_cap THEN
            v_force_tools_disabled := true;
            RAISE NOTICE 'chat_post_internal: session=% rounds=%/HARD-cap-% — forcing tools_disabled+tool_choice=none',
                p_session_id, v_rounds_so_far, v_hard_cap;
        ELSIF v_rounds_so_far >= v_soft_cap AND NOT v_already_soft_notified THEN
            v_inject_soft_notice := true;
            RAISE NOTICE 'chat_post_internal: session=% rounds=%/soft-cap-% — injecting STEWARD NOTICE',
                p_session_id, v_rounds_so_far, v_soft_cap;
        END IF;
    ELSIF stewards.config_get('chat_force_final_enabled', 'true'::jsonb) = 'true'::jsonb THEN
        -- INTERACTIVE chat (no pipeline stage — e.g. work-item-chat). The bridge
        -- bounds the loop at the agent's `steps` and then STOPS with no final
        -- answer (the silent death rigor mode surfaced). Give it the same grace,
        -- derived from the agent's own budget: force-final two rounds before the
        -- bridge stop, with a wrap-up nudge earlier. Only worth it for agents with
        -- a real tool budget (>= 6); tiny-budget agents fall through unchanged.
        SELECT a.steps INTO v_agent_steps
          FROM stewards.agents a
         WHERE a.family = p_agent_family
           AND stewards.glob_match(a.model_match, p_model)
         ORDER BY length(a.model_match) DESC
         LIMIT 1;

        IF COALESCE(v_agent_steps, 0) >= 6 THEN
            v_hard_cap   := GREATEST(v_agent_steps - 2, 2);          -- force-final before the bridge cuts it off
            v_soft_cap   := GREATEST((v_agent_steps * 0.7)::int, 1); -- wrap-up nudge earlier
            v_stage_name := COALESCE(v_stage_name, 'chat');          -- label for the notice text

            SELECT count(*) INTO v_rounds_so_far
              FROM stewards.messages
             WHERE session_id = p_session_id
               AND role = 'assistant';

            IF v_rounds_so_far >= v_hard_cap THEN
                v_force_tools_disabled := true;
                RAISE NOTICE 'chat_post_internal: session=% rounds=%/HARD-cap-% (interactive) — forcing tools_disabled+tool_choice=none',
                    p_session_id, v_rounds_so_far, v_hard_cap;
            ELSIF v_rounds_so_far >= v_soft_cap AND NOT v_already_soft_notified THEN
                v_inject_soft_notice := true;
                RAISE NOTICE 'chat_post_internal: session=% rounds=%/soft-cap-% (interactive) — injecting STEWARD NOTICE',
                    p_session_id, v_rounds_so_far, v_soft_cap;
            END IF;
        END IF;
    END IF;

    -- Soft-cap notice is globally gateable (config 'soft_cap_notice_enabled',
    -- default true). compose_messages now relabels it to 'user' at render so it
    -- no longer breaks strict templates; this flag turns it off entirely.
    IF v_inject_soft_notice
       AND stewards.config_get('soft_cap_notice_enabled', 'true'::jsonb) = 'true'::jsonb THEN
        v_notice_text := stewards.build_soft_cap_notice(
            v_rounds_so_far, v_soft_cap, v_hard_cap, v_stage_name);
        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (p_session_id, 'system', v_notice_text, p_model);
    END IF;

    v_body := stewards.dry_run_chat(p_agent_family, p_model, p_session_id, NULL, p_provider);
    v_body := v_body - '_meta';

    IF v_force_tools_disabled THEN
        v_body := v_body || jsonb_build_object('tool_choice', 'none');
    END IF;

    v_payload := jsonb_build_object(
        'session_id',      p_session_id,
        'agent_family',    p_agent_family,
        'requested_model', p_model,
        'body',            v_body
    );

    IF v_force_tools_disabled THEN
        v_payload := v_payload || jsonb_build_object('tools_disabled', true);
    END IF;

    IF v_inject_soft_notice THEN
        v_payload := v_payload || jsonb_build_object(
            '_soft_cap_notified', true,
            '_soft_cap_injected_at_round', v_rounds_so_far
        );
    END IF;

    IF v_inherited_markers IS NOT NULL THEN
        v_payload := (v_inherited_markers - '_soft_cap_notified' - '_soft_cap_injected_at_round') || v_payload;
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat', p_provider, v_payload, 'pending')
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$FN$;

COMMENT ON FUNCTION stewards.chat_post_internal(text, text, text, text) IS
'67 (re-authors 15b l32): enqueue a continuation chat with two-tier tool-round caps. PIPELINE stages use per-stage soft/hard caps; INTERACTIVE chats (no _pipeline_family) derive caps from the agent''s own steps (force-final at steps-2, wrap-up nudge at 0.7×) so a chat that exhausts its budget is FORCED to synthesize an answer instead of dying silently at the bridge''s steps cap. Soft cap injects a [STEWARD NOTICE] (tools stay — Judges principle); hard cap forces tools_disabled+tool_choice=none. Interactive force-final gated by config chat_force_final_enabled (default true).';

-- =====================================================================
-- End of 67-rigor-force-final.sql
-- =====================================================================
-- ===== [was 68-model-fallback-hardening.sql] =====
-- =====================================================================
-- 68-model-fallback-hardening.sql — survive a pulled local model
-- =====================================================================
-- Surfaced live: with a local model taken offline (a GPU reclaimed for other
-- work), a stage routed to it and the rig returned
--   HTTP 404: "no local slot or reachable peer serves model <X>"
-- which diagnose_failure (32) classified as 'unknown' (its transient regex
-- catches 5xx/408/429, NOT a 404 model-not-loaded). 'unknown' does not trigger
-- alias failover, so the pipeline HARD-FAILED instead of walking to a live model.
--
-- Two parts, both SQL, both idempotent:
--   §1  diagnose_failure learns the pulled-model shape → 'transient', so the
--       existing alias failover (32 §3, steward_tick keys on transient/timeout)
--       walks to the next alias member instead of dying.
--   §2  make the local MoE pair MUTUAL fallback members — gemma-4-26b-a4b and
--       qwen3.6-35b-a3b each appear on the other's local aliases — so the walk
--       lands on whichever local is up (gemma gone → qwen, and vice versa),
--       preferring a live LOCAL before a paid cloud fallback.
--
-- requires create_rigor_force_final (67) — purely for chain ordering; the only
-- real deps are diagnose_failure (32) and model_aliases (31). Generic core.
-- =====================================================================

-- ── §1 — diagnose_failure: a pulled / unloaded model is TRANSIENT ────
CREATE OR REPLACE FUNCTION stewards.diagnose_failure(
    p_reason         text,
    p_failure_count  int DEFAULT 0
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_lower text;
BEGIN
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        IF p_failure_count >= 2 THEN
            RETURN 'model_limit';
        END IF;
        RETURN 'unknown';
    END IF;

    v_lower := lower(p_reason);

    IF v_lower ~ '(timeout|timed out|context deadline exceeded|inactivity|deadline)' THEN
        RETURN 'timeout';
    END IF;

    -- Transient: any 5xx (incl. Cloudflare 52x), 408, 429/rate limits, network
    -- blips, and the common overload / "web server is down" phrasings. Provider
    -- issue, not a model-capability issue.
    -- #326 (2026-07-04): gateways (opencode.ai "Console Go") wrap a failed UPSTREAM
    -- in an HTTP 400 — e.g. `Error from provider (Console Go): Upstream request
    -- failed`. That is a transient upstream blip, NOT a malformed request, so match
    -- the "upstream …" phrasing. Bare 400s (real client errors) stay non-transient.
    IF v_lower ~ '(408|429|rate.?limit|5[0-9][0-9]|network|connection (refused|reset)|temporarily unavailable|service unavailable|overloaded|web server (is down|returned|error)|upstream (request )?(failed|error|unavailable|timeout))' THEN
        RETURN 'transient';
    END IF;

    -- 68: a model that's OFFLINE / not loaded (a local slot reclaimed, a peer
    -- that dropped). The rig returns 404 "no local slot or reachable peer serves
    -- model X"; cloud providers say "model not found / no such model". Treat as
    -- transient so alias failover WALKS to the next (live) member instead of
    -- hard-failing the pipeline. (Checked before tool_error; "model not found"
    -- has no tool/function/schema prefix so it never collides with that class.)
    IF v_lower ~ '(no (local )?slot|serves model|no such model|model (is )?(not (found|loaded|available|currently)|does not exist|unavailable|unknown|no longer))' THEN
        RETURN 'transient';
    END IF;

    IF v_lower ~ '(tool.{0,30}(error|not found|missing|invalid)|function.{0,20}(error|not found|missing|invalid)|schema.{0,20}(error|invalid|mismatch)|validation.{0,20}(failed|error))' THEN
        RETURN 'tool_error';
    END IF;

    IF p_failure_count >= 2 THEN
        RETURN 'model_limit';
    END IF;

    RETURN 'unknown';
END;
$func$;
COMMENT ON FUNCTION stewards.diagnose_failure(text, int) IS
'68 (re-authors 32): classify a failure into (transient | timeout | model_limit | tool_error | unknown). Transient covers a pulled/unloaded model — the rig''s 404 "no local slot or reachable peer serves model X" and cloud "model not found / no such model" — and (#326) a gateway-wrapped upstream 400 ("Error from provider (X): Upstream request failed") — so failover/retry engages on real upstream blips instead of hard-failing. Bare 400s stay non-transient.';

-- ── §2 — REMOVED 2026-07-07 (feat/lightening, model-agnostic audit §E):
-- this block used to DELETE/UPDATE/INSERT concrete rows into
-- stewards.model_aliases naming Michael's specific local-rig topology
-- (gemma-4-26b-a4b / qwen3.6-35b-a3b on flexllama, re-prioritizing
-- opencode_go members) directly in the numbered core chain — landing
-- live on every fresh install instead of in the overlay this file's own
-- sibling seeds (06-cost, 19-models, 31-model-aliases) already established
-- as the pattern ("SEED ROWS MOVED TO THE OVERLAY"). Superseded in full by
-- .spec/lightening/local-overlay-example.sql §3 (role aliases: reason/
-- ingest/critic/vision/review), which carries the SAME local-first,
-- mutual-fallback shape this block built, under Michael's current
-- ratified economics rather than this file's 2026-06 ad-hoc version. Kept
-- here as the historical record — port from the overlay, not from here.

-- =====================================================================
-- End of 68-model-fallback-hardening.sql
-- =====================================================================
