-- =====================================================================
-- 12-council.sql — councils (Zion / cycle step 11): convene → deliberate
--   → synthesize → bishop resolution, + the resolution-file producer.
--
-- Consolidated (authoring leg, 2026-06-13) from the historical chain:
--   5g   — councils / council_members / resolutions tables (+ the
--          one_active_council index). The sessions.kind 'council' value is
--          born in src/schema.rs (no constraint churn here).
--   5g2  — council_proposer/critic/synthesizer templates + convene_council
--   5g3  — synthesize_council / apply_synthesize_result / resolve_council
--   5g4  — bishop_eligible (values_anchor) + suggest_councils
--   6e   — enqueue_resolution_file + the resolutions promoted_to trigger
--          (these live HERE, not 10-sabbath, because they declare
--          stewards.resolutions%ROWTYPE and trigger ON stewards.resolutions —
--          a %ROWTYPE / trigger on a not-yet-existing table fails at CREATE).
--
-- Rename applied: bishop_eligible's low-stakes test reads
-- intents.values_anchor (was scripture_anchor).
-- =====================================================================

-- ---------------------------------------------------------------------
-- councils — one row per convened council (D-F1: one active at a time)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.councils (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    intent_id         uuid NOT NULL REFERENCES stewards.intents(id),
    binding_question  text NOT NULL,
    convened_at       timestamptz NOT NULL DEFAULT now(),
    convened_by       text NOT NULL,
    bishop            text NOT NULL,
    status            text NOT NULL DEFAULT 'deliberating'
                       CHECK (status IN ('deliberating', 'synthesizing', 'awaiting_bishop',
                                          'resolved', 'dissolved')),
    resolution_id     uuid,                    -- FK wired after resolutions exists
    dissolved_reason  text,
    resolved_at       timestamptz
);

CREATE INDEX IF NOT EXISTS councils_status      ON stewards.councils (status);
CREATE INDEX IF NOT EXISTS councils_convened_at ON stewards.councils (convened_at);

DO $idx$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes WHERE indexname = 'one_active_council'
    ) THEN
        CREATE UNIQUE INDEX one_active_council
            ON stewards.councils ((1))
            WHERE status IN ('deliberating', 'synthesizing', 'awaiting_bishop');
    END IF;
END;
$idx$;

COMMENT ON TABLE stewards.councils IS
'Phase 5g (F.1): one row per convened council. one_active_council partial unique index enforces D-F1 (one concurrent council initially).';

-- ---------------------------------------------------------------------
-- council_members
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.council_members (
    council_id    uuid NOT NULL REFERENCES stewards.councils(id) ON DELETE CASCADE,
    agent_family  text NOT NULL,
    role          text NOT NULL CHECK (role IN ('proposer', 'critic', 'synthesizer')),
    work_id       bigint,
    response      text,
    completed_at  timestamptz,
    PRIMARY KEY (council_id, agent_family, role)
);

CREATE INDEX IF NOT EXISTS council_members_council ON stewards.council_members (council_id);

COMMENT ON TABLE stewards.council_members IS
'Phase 5g (F.1): per-(council, agent_family, role) member. Member key = (council_id, agent_family, role); model floats per dispatch.';

-- ---------------------------------------------------------------------
-- resolutions
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.resolutions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    council_id      uuid REFERENCES stewards.councils(id),
    resolved_at     timestamptz NOT NULL DEFAULT now(),
    resolved_by     text NOT NULL,
    text            text NOT NULL,
    promoted_to     text,
    promoted_at     timestamptz,
    raw_proposal    jsonb
);

CREATE INDEX IF NOT EXISTS resolutions_council ON stewards.resolutions (council_id);

COMMENT ON TABLE stewards.resolutions IS
'Phase 5g (F.1): canonical resolutions (D-F3). Bishop accept may also promote to study/ or .mind/decisions.md based on question type via the resolutions promoted_to trigger.';

-- Wire the FK back from councils.resolution_id → resolutions.id
DO $fk$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'councils_resolution_id_fkey'
    ) THEN
        ALTER TABLE stewards.councils
            ADD CONSTRAINT councils_resolution_id_fkey
            FOREIGN KEY (resolution_id) REFERENCES stewards.resolutions(id);
    END IF;
END;
$fk$;

-- ---------------------------------------------------------------------
-- council member prompt templates (table + CHECK born in 08-gates)
-- ---------------------------------------------------------------------

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('council_proposer',
$tmpl$You are a member of a council convened to address a single binding question. Your role is PROPOSER.

The intent and active covenant for this council are loaded into your system prompt above.

Council intent: {{intent_purpose}}
Binding question: {{binding_question}}

Your job as proposer: offer a concrete proposed answer to the binding question. Lead with the answer; back it with reasoning that engages the corpus where relevant. You have substrate-internal tools (doc_search, doc_get, doc_similar, doc_citations) available — use them to ground your proposal in existing work.

Don't hedge. Don't list every possible angle. Take a position and defend it. The critic will stress-test it; the synthesizer will integrate.

Respond with prose (no JSON shape required). Aim for 200-500 words.
$tmpl$,
     'Phase 5g (F.2): proposer role. Tools enabled.')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('council_critic',
$tmpl$You are a member of a council convened to address a single binding question. Your role is CRITIC.

The intent and active covenant for this council are loaded into your system prompt above.

Council intent: {{intent_purpose}}
Binding question: {{binding_question}}

Your job as critic: find what's wrong, missing, or under-considered in the proposer's framing. The covenant's surface_tensions commitment binds you here — your function is the council's check, not its echo.

If the proposer's response is available you'll see it below; if not, articulate the strongest counterposition you can.

{{proposer_responses}}

Don't be contrarian for sport. Identify the real fault lines. What's the proposer assuming that they shouldn't? What corpus context would change the picture? You have substrate-internal tools available.

Respond with prose. 200-500 words.
$tmpl$,
     'Phase 5g (F.2): critic role. Tools enabled. surface_tensions covenant directly applied.')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('council_synthesizer',
$tmpl$You are the synthesizer for a council convened to address a single binding question.

The intent and active covenant for this council are loaded into your system prompt above.

Council intent: {{intent_purpose}}
Binding question: {{binding_question}}

Council members responded:

{{member_responses}}

Your job: produce a single proposed resolution. Honor the proposer's instinct where it survived the critic; honor the critic's catch where the proposer missed something; name the genuine tension where both have a point and the human bishop needs to decide.

Don't paper over disagreement. Don't pretend to consensus that isn't there.

Respond with JSON ONLY (no prose around it, no tool calls):
{
  "resolution": "the proposed answer (1-3 paragraphs)",
  "tensions": ["unresolved tension 1", "tension 2", ...],
  "destination_hint": "study" | "decisions" | "either" | "none"
}

destination_hint guides the bishop: 'study' if the resolution belongs in study/<slug>.md (doctrinal/narrative), 'decisions' if it belongs in .mind/decisions.md (engineering/operational), 'either' if both, 'none' if it should stay in the resolutions table only.
$tmpl$,
     'Phase 5g (F.2): synthesizer role. Tools DISABLED (structured JSON output). Per D-F3, destination_hint feeds the bishop''s promotion choice.')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

-- ---------------------------------------------------------------------
-- convene_council — D-F1 enforcement + parallel member dispatch
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.convene_council(
    p_intent_id        uuid,
    p_binding_question text,
    p_members          jsonb,
    p_bishop           text,
    p_convened_by      text DEFAULT 'human'
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_council_id  uuid;
    v_intent      stewards.intents%ROWTYPE;
    v_member      jsonb;
    v_role        text;
    v_agent       text;
    v_model       text;
    v_session_id  text;
    v_template_id text;
    v_template    text;
    v_prompt      text;
    v_payload     jsonb;
    v_work_id     bigint;
    v_provider    text := 'opencode_go';
    v_tools_off   boolean;
    v_member_count int;
BEGIN
    SELECT * INTO v_intent FROM stewards.intents WHERE id = p_intent_id;
    IF v_intent.id IS NULL THEN
        RAISE EXCEPTION 'convene_council: intent % not found', p_intent_id;
    END IF;

    IF p_members IS NULL OR jsonb_typeof(p_members) <> 'array' THEN
        RAISE EXCEPTION 'convene_council: p_members must be a jsonb array';
    END IF;

    v_member_count := jsonb_array_length(p_members);
    IF v_member_count < 2 OR v_member_count > 5 THEN
        RAISE EXCEPTION 'convene_council: must have between 2 and 5 members (got %)', v_member_count;
    END IF;

    IF EXISTS (SELECT 1 FROM stewards.councils
                WHERE status IN ('deliberating', 'synthesizing', 'awaiting_bishop')) THEN
        RAISE EXCEPTION 'convene_council: one council at a time (D-F1) — resolve or dissolve the active council first';
    END IF;

    INSERT INTO stewards.councils (intent_id, binding_question, convened_by, bishop)
    VALUES (p_intent_id, p_binding_question, p_convened_by, p_bishop)
    RETURNING id INTO v_council_id;

    FOR v_member IN SELECT * FROM jsonb_array_elements(p_members) LOOP
        v_role  := v_member->>'role';
        v_agent := v_member->>'agent_family';
        v_model := coalesce(v_member->>'model', 'kimi-k2.6');

        IF v_role NOT IN ('proposer', 'critic', 'synthesizer') THEN
            RAISE EXCEPTION 'convene_council: invalid role % for agent %', v_role, v_agent;
        END IF;

        v_template_id := 'council_' || v_role;
        SELECT template INTO v_template
          FROM stewards.gate_prompts WHERE id = v_template_id;

        v_session_id := substring(
            'council--' || substring(v_council_id::text FROM 1 FOR 8) ||
            '--' || v_role || '--' || v_agent,
            1, 200);

        INSERT INTO stewards.sessions (id, label, kind)
        VALUES (v_session_id,
                format('council %s role=%s agent=%s', v_council_id, v_role, v_agent),
                'council')
        ON CONFLICT (id) DO NOTHING;

        v_prompt := stewards.render_template(v_template, jsonb_build_object(
            'intent_purpose',     v_intent.purpose,
            'binding_question',   p_binding_question,
            'proposer_responses', '(none yet — proposer responses arrive in parallel)',
            'member_responses',   '(none yet — members responding in parallel)'
        ));

        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (v_session_id, 'user', v_prompt, v_model);

        v_tools_off := (v_role = 'synthesizer');

        v_payload := jsonb_build_object(
            'session_id',      v_session_id,
            'agent_family',    v_agent,
            'requested_model', v_model,
            'meta',            '{}'::jsonb,
            'body',            (stewards.dry_run_chat(v_agent, v_model, v_session_id, NULL) - '_meta')
                               || jsonb_build_object('user', v_session_id),
            'tools_disabled',  v_tools_off,
            '_council_id',     v_council_id::text,
            '_council_member', true,
            '_council_role',   v_role
        );

        INSERT INTO stewards.work_queue (kind, provider, payload)
        VALUES ('chat', v_provider, v_payload)
        RETURNING id INTO v_work_id;

        INSERT INTO stewards.council_members (council_id, agent_family, role, work_id)
        VALUES (v_council_id, v_agent, v_role, v_work_id);
    END LOOP;

    RETURN v_council_id;
END;
$func$;

COMMENT ON FUNCTION stewards.convene_council(uuid, text, jsonb, text, text) IS
'Phase 5g (F.2): convene a council. Validates intent + members shape (2-5) + D-F1 (one active at a time). Dispatches each member in parallel with role-specific prompt + _council_id/_council_member markers. Synthesizer member gets tools_disabled=true; proposer/critic get tools enabled.';

-- ---------------------------------------------------------------------
-- synthesize_council — second-round dispatch with member context
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.synthesize_council(
    p_council_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_council         stewards.councils%ROWTYPE;
    v_intent          stewards.intents%ROWTYPE;
    v_template        text;
    v_member_responses text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_synth_agent     text := 'plan';
    v_synth_model     text := 'kimi-k2.6';
BEGIN
    SELECT * INTO v_council FROM stewards.councils WHERE id = p_council_id;
    IF v_council.id IS NULL THEN
        RAISE EXCEPTION 'synthesize_council: council % not found', p_council_id;
    END IF;
    IF v_council.status NOT IN ('deliberating', 'synthesizing') THEN
        RAISE EXCEPTION 'synthesize_council: council % status=%, expected deliberating/synthesizing',
                        p_council_id, v_council.status;
    END IF;

    SELECT * INTO v_intent FROM stewards.intents WHERE id = v_council.intent_id;

    SELECT template INTO v_template FROM stewards.gate_prompts WHERE id = 'council_synthesizer';

    SELECT string_agg(
             format(E'### %s (%s)\n\n%s', upper(role), agent_family,
                    coalesce(response, '(no response)')),
             E'\n\n---\n\n' ORDER BY role, agent_family)
      INTO v_member_responses
      FROM stewards.council_members
     WHERE council_id = p_council_id
       AND role IN ('proposer', 'critic');

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'intent_purpose',   v_intent.purpose,
        'binding_question', v_council.binding_question,
        'member_responses', coalesce(v_member_responses, '(no member responses recorded)')
    ));

    v_session_id := substring(
        'council--' || substring(v_council.id::text FROM 1 FOR 8) ||
        '--synthesize--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('council %s synthesizer (auto)', v_council.id),
            'council')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_synth_model);

    v_payload := jsonb_build_object(
        'session_id',           v_session_id,
        'agent_family',         v_synth_agent,
        'requested_model',      v_synth_model,
        'meta',                 '{}'::jsonb,
        'body',                 (stewards.dry_run_chat(v_synth_agent, v_synth_model, v_session_id, NULL) - '_meta')
                                || jsonb_build_object('user', v_session_id),
        'tools_disabled',       true,
        '_council_id',          v_council.id::text,
        '_council_synthesize',  true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', 'opencode_go', v_payload)
    RETURNING id INTO v_work_id;

    UPDATE stewards.councils
       SET status = 'synthesizing'
     WHERE id = p_council_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.synthesize_council(uuid) IS
'Phase 5g (F.3): enqueue the synthesizer dispatch with proposer + critic responses in context. tools_disabled=true. Status → synthesizing. bgworker auto-fires apply_synthesize_result on completion.';

-- ---------------------------------------------------------------------
-- apply_synthesize_result — store draft + transition to bishop
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_synthesize_result(
    p_council_id uuid,
    p_result     jsonb,
    p_work_id    bigint DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_council        stewards.councils%ROWTYPE;
    v_resolution_id  uuid;
BEGIN
    SELECT * INTO v_council FROM stewards.councils WHERE id = p_council_id FOR UPDATE;
    IF v_council.id IS NULL THEN
        RAISE EXCEPTION 'apply_synthesize_result: council % not found', p_council_id;
    END IF;

    INSERT INTO stewards.resolutions
        (council_id, resolved_by, text, raw_proposal)
    VALUES
        (p_council_id, '__draft__', coalesce(p_result->>'resolution', '(no resolution text)'),
         p_result)
    RETURNING id INTO v_resolution_id;

    UPDATE stewards.councils
       SET status        = 'awaiting_bishop',
           resolution_id = v_resolution_id
     WHERE id = p_council_id;

    RETURN v_resolution_id;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_synthesize_result(uuid, jsonb, bigint) IS
'Phase 5g (F.3): store the synthesizer''s draft resolution; transition council to awaiting_bishop. resolved_by=__draft__ until the bishop accepts via resolve_council.';

-- ---------------------------------------------------------------------
-- resolve_council — bishop's accept / request_revision / dissolve
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.resolve_council(
    p_council_id      uuid,
    p_action          text,
    p_resolution_text text,
    p_destination     text,
    p_resolved_by     text,
    p_dissolved_reason text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_council    stewards.councils%ROWTYPE;
    v_resolution_id uuid;
    v_promoted_to text;
BEGIN
    SELECT * INTO v_council FROM stewards.councils WHERE id = p_council_id FOR UPDATE;
    IF v_council.id IS NULL THEN
        RAISE EXCEPTION 'resolve_council: council % not found', p_council_id;
    END IF;
    IF p_action NOT IN ('accept', 'request_revision', 'dissolve') THEN
        RAISE EXCEPTION 'resolve_council: invalid action %', p_action;
    END IF;
    IF v_council.status NOT IN ('awaiting_bishop', 'deliberating', 'synthesizing') THEN
        RAISE EXCEPTION 'resolve_council: council % status=%, cannot resolve', p_council_id, v_council.status;
    END IF;

    IF p_action = 'accept' THEN
        IF p_resolution_text IS NULL OR length(trim(p_resolution_text)) = 0 THEN
            RAISE EXCEPTION 'resolve_council: accept requires resolution_text';
        END IF;
        IF p_resolved_by IS NULL OR length(trim(p_resolved_by)) = 0 THEN
            RAISE EXCEPTION 'resolve_council: accept requires resolved_by';
        END IF;

        v_promoted_to := CASE p_destination
            WHEN 'study'     THEN 'study/' || substring(v_council.id::text FROM 1 FOR 8) || '.md'
            WHEN 'decisions' THEN '.mind/decisions.md'
            ELSE NULL
        END;

        IF v_council.resolution_id IS NOT NULL THEN
            UPDATE stewards.resolutions
               SET text         = p_resolution_text,
                   resolved_by  = p_resolved_by,
                   resolved_at  = now(),
                   promoted_to  = v_promoted_to,
                   promoted_at  = CASE WHEN v_promoted_to IS NOT NULL THEN now() ELSE NULL END
             WHERE id = v_council.resolution_id
            RETURNING id INTO v_resolution_id;
        ELSE
            INSERT INTO stewards.resolutions
                (council_id, resolved_by, text, promoted_to, promoted_at)
            VALUES
                (p_council_id, p_resolved_by, p_resolution_text, v_promoted_to,
                 CASE WHEN v_promoted_to IS NOT NULL THEN now() ELSE NULL END)
            RETURNING id INTO v_resolution_id;
        END IF;

        UPDATE stewards.councils
           SET status        = 'resolved',
               resolution_id = v_resolution_id,
               resolved_at   = now()
         WHERE id = p_council_id;

        RETURN v_resolution_id;

    ELSIF p_action = 'request_revision' THEN
        IF v_council.resolution_id IS NOT NULL THEN
            UPDATE stewards.resolutions
               SET text = text || E'\n\n[Bishop requests revision] ' || coalesce(p_resolution_text, '')
             WHERE id = v_council.resolution_id;
        END IF;
        UPDATE stewards.councils SET status = 'deliberating' WHERE id = p_council_id;
        PERFORM stewards.synthesize_council(p_council_id);
        RETURN v_council.resolution_id;

    ELSIF p_action = 'dissolve' THEN
        UPDATE stewards.councils
           SET status           = 'dissolved',
               dissolved_reason = coalesce(p_dissolved_reason, 'no reason given'),
               resolved_at      = now()
         WHERE id = p_council_id;
        RETURN v_council.resolution_id;
    END IF;

    RETURN NULL;
END;
$func$;

COMMENT ON FUNCTION stewards.resolve_council(uuid, text, text, text, text, text) IS
'Phase 5g (F.3): bishop''s resolution path. accept = canonicalize the draft (optional promotion to study/ or .mind/decisions.md per D-F3); request_revision = re-fire synthesize with bishop note; dissolve = terminate with reason.';

-- ---------------------------------------------------------------------
-- bishop_eligible — D-F2. Humans always; agents only on low-stakes
-- intents (values_anchor IS NULL + values_hierarchy lacks doctrinal/
-- spiritual/discernment) AND master-tier on the intent's pipeline.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.bishop_eligible(
    p_bishop    text,
    p_intent_id uuid
) RETURNS boolean
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_intent      stewards.intents%ROWTYPE;
    v_parts       text[];
    v_agent       text;
    v_pipeline    text;
    v_required_tier text;
    v_actual_level text;
    v_low_stakes  boolean;
BEGIN
    IF p_bishop LIKE 'human:%' THEN
        RETURN true;
    END IF;

    SELECT * INTO v_intent FROM stewards.intents WHERE id = p_intent_id;
    IF v_intent.id IS NULL THEN
        RETURN false;
    END IF;

    -- Low-stakes check: doctrinal/spiritual/discernment intents (or any
    -- intent carrying a values_anchor) always require a human bishop.
    v_low_stakes := (
        v_intent.values_anchor IS NULL
        AND v_intent.values_hierarchy::text !~* '(doctrinal|spiritual|discernment)'
    );

    IF NOT v_low_stakes THEN
        RETURN false;
    END IF;

    v_parts := string_to_array(p_bishop, ':');
    IF array_length(v_parts, 1) < 4 OR v_parts[1] <> 'agent' THEN
        RETURN false;
    END IF;
    v_agent         := v_parts[2];
    v_pipeline      := v_parts[3];
    v_required_tier := v_parts[4];

    IF v_required_tier <> 'master' THEN
        RETURN false;
    END IF;

    SELECT trust_level INTO v_actual_level
      FROM stewards.trust_scores
     WHERE agent_family = v_agent
       AND pipeline_family = v_pipeline
       AND trust_level = 'master'
     LIMIT 1;

    RETURN v_actual_level IS NOT NULL;
END;
$func$;

COMMENT ON FUNCTION stewards.bishop_eligible(text, uuid) IS
'Phase 5g (F.5): bishop eligibility per D-F2. Humans always eligible. Agents (bishop=agent:<family>:<pipeline>:master) only on low-stakes intents (no values_anchor + values_hierarchy lacks doctrinal/spiritual/discernment) AND master-tier on at least one (agent, pipeline, model) cell.';

-- ---------------------------------------------------------------------
-- suggest_councils — clusters of 5+ ratified lessons by (pipeline, stage)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.suggest_councils(
    p_min_lessons int DEFAULT 5
) RETURNS TABLE (
    pipeline_family text,
    current_stage   text,
    lesson_count    bigint,
    sample_content  text
)
LANGUAGE sql STABLE AS $func$
SELECT
    pipeline_family,
    current_stage,
    count(*) AS lesson_count,
    string_agg('  - ' || left(content, 100), E'\n' ORDER BY at DESC) FILTER (WHERE rn <= 3) AS sample_content
  FROM (
    SELECT
        l.id,
        l.content,
        l.at,
        wi.pipeline_family,
        wi.current_stage,
        row_number() OVER (PARTITION BY wi.pipeline_family, wi.current_stage ORDER BY l.at DESC) AS rn
      FROM stewards.lessons l
      JOIN stewards.work_items wi ON wi.id = l.work_item_id
     WHERE l.ratified_at IS NOT NULL
       AND l.kind IN ('lesson', 'principle')
       AND l.at > COALESCE((
           SELECT max(c.convened_at)
             FROM stewards.councils c
             JOIN stewards.intents i ON i.id = c.intent_id
            WHERE i.purpose ILIKE '%' || wi.pipeline_family || '%'
       ), '-infinity'::timestamptz)
  ) clustered
 GROUP BY pipeline_family, current_stage
HAVING count(*) >= p_min_lessons
 ORDER BY lesson_count DESC, pipeline_family, current_stage;
$func$;

COMMENT ON FUNCTION stewards.suggest_councils(int) IS
'Phase 5g (F.5): scan ratified lessons for clusters by (pipeline_family, current_stage). Default threshold 5+. Heuristic dedupe: skip clusters where a council on this pipeline was convened more recently than the lessons.';

-- ---------------------------------------------------------------------
-- enqueue_resolution_file + the resolutions promoted_to trigger
-- (6e resolution half — needs stewards.resolutions + stewards.councils).
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.enqueue_resolution_file(p_resolution_id uuid)
RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_res stewards.resolutions%ROWTYPE;
    v_council stewards.councils%ROWTYPE;
    v_pwid bigint;
    v_content text;
    v_write_mode text;
BEGIN
    SELECT * INTO v_res FROM stewards.resolutions WHERE id = p_resolution_id;
    IF v_res.id IS NULL OR v_res.promoted_to IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_council FROM stewards.councils WHERE id = v_res.council_id;

    IF v_res.promoted_to LIKE '.mind/%' THEN
        v_write_mode := 'append';
        v_content := format(
            E'\n\n## %s — Council resolution: %s\n\n%s\n',
            to_char(coalesce(v_res.resolved_at, now()), 'YYYY-MM-DD'),
            coalesce(v_council.binding_question, '(no binding question)'),
            v_res.text);
    ELSE
        v_write_mode := 'create';
        v_content := format(
            E'# Council resolution\n\n**Binding question:** %s\n**Resolved by:** %s\n**Resolved at:** %s\n\n---\n\n%s\n',
            coalesce(v_council.binding_question, '(no binding question)'),
            v_res.resolved_by,
            to_char(coalesce(v_res.resolved_at, now()), 'YYYY-MM-DD HH24:MI'),
            v_res.text);
    END IF;

    INSERT INTO stewards.pending_file_writes
        (requested_by, target_path, write_mode, content, source_id, source_kind)
    VALUES
        ('council_resolve', v_res.promoted_to, v_write_mode, v_content,
         v_res.id::text, 'resolution')
    RETURNING id INTO v_pwid;

    RETURN v_pwid;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_resolution_file(uuid) IS
'Batch G.4.5: queue a pending_file_writes row for an accepted council resolution. Paths under .mind/ use append mode + dated header; study/<id>.md paths use create mode + full document frontmatter.';

CREATE OR REPLACE FUNCTION stewards.resolutions_promoted_to_trigger()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    IF NEW.promoted_to IS NOT NULL
       AND (OLD.promoted_to IS NULL OR OLD.promoted_to <> NEW.promoted_to) THEN
        BEGIN
            PERFORM stewards.enqueue_resolution_file(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'enqueue_resolution_file failed for resolution %: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS resolutions_promoted_to_au ON stewards.resolutions;
CREATE TRIGGER resolutions_promoted_to_au
    AFTER UPDATE OF promoted_to ON stewards.resolutions
    FOR EACH ROW
    EXECUTE FUNCTION stewards.resolutions_promoted_to_trigger();

COMMENT ON FUNCTION stewards.resolutions_promoted_to_trigger() IS
'Batch G.4.5: fires enqueue_resolution_file when a council resolution''s promoted_to transitions from NULL to a path (bishop accepted with destination=study|decisions). Errors swallowed via NOTICE.';

-- =====================================================================
-- Done. 12-council: convene → deliberate → synthesize → bishop resolution,
-- bishop eligibility, council suggestion, and the resolution-file producer.
-- =====================================================================
