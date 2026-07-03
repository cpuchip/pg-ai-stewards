-- =====================================================================
-- 89-attention.sql — the unified "Needs your answer" surface (ladder Phase 2, partial)
-- =====================================================================
-- Michael's ratified ask ("stewdio for now, we could create a new panel for
-- notifications that need to be answered to make it super easy") pointed at
-- a real gap: every human-blocking case in the substrate had its OWN surface
-- — the Hinge queue (39), the tool-effect gate's tool-confirm reviews (84),
-- a paused pipeline stage (04 awaiting_review), an A2A blocking question (69
-- a2a_question) — each readable only by someone who already knew where to
-- look. This unions the real pending sets into ONE shape (needs_attention),
-- one cheap count (attention_count), and one router that resolves an answer
-- through the RIGHT existing verb per kind (attention_answer) — no
-- reimplementation of tool_confirm_verdict / hinge_record_verdict /
-- a2a_answer / work_item_dispatch_stage, all of which already enforce their
-- own bounds (84's escalate-always wall, 39's D&C 121 wall).
--
-- Also lands ladder Phase 2's ask_up: a weak/local model consults the NEXT
-- enabled rung on 84's escalation_ladder — NO authority transfer, just an
-- answer to reason with (the ladder's rung 1). When the caller is already at
-- (or above) the top enabled rung, there is nowhere higher to ask — it
-- surfaces as an 'ask' row in needs_attention instead, so it never silently
-- strands. Phase 2 minimal: no autopilot, no notify service, no min_tier
-- knob — see .spec/proposals/hinge-and-escalation-ladder.md Piece 3.
--
-- requires create_sticky_agent_family (86) — installs at the tail.
-- =====================================================================

-- =====================================================================
-- §1 — needs_attention: the union of every human-blocking source.
-- =====================================================================
-- Five source_kinds, five real pending sets (discovered by reading the SQL,
-- not guessed):
--   gate         — 84's tool-confirm reviews (hinge_reviews kind='tool-confirm',
--                  status pending/escalated). The withheld dangerous tool call.
--   ask          — a free-standing question (hinge_reviews kind='ask') — today
--                  only ask_up's top-rung fallback writes these (§3).
--   hinge        — every OTHER Hinge review kind (digest-skill-rule, graph-reorg,
--                  cutover, …) pending/escalated — the 39 queue, minus the two
--                  kinds broken out above so each row appears in exactly one bucket.
--   a2a_question — 69's INPUT_REQUIRED: work_items.status='awaiting_review' WITH
--                  a2a_question set (the exact blocking question a claimed A2A
--                  task raised).
--   review       — a paused PIPELINE stage with NO a2a_question: status=
--                  'awaiting_review' because auto_advance=false, a token-budget
--                  hit, or a dispatch failure (04 §"Status lifecycle"). Not a
--                  question-answer — a human ack-to-continue.
-- Same shape throughout so the UI renders one card type: source_kind,
-- source_id (text — the id space differs per kind: hinge_reviews.id is
-- bigint, work_items.id is uuid), title, question, options (jsonb array of
-- quick-reply strings, or NULL = free-text answer), created_at, work_item_id
-- (uuid, where one exists).
CREATE OR REPLACE VIEW stewards.needs_attention AS
SELECT
    'gate'::text                                        AS source_kind,
    id::text                                            AS source_id,
    format('Approve tool call: %s', payload->>'tool')   AS title,
    subject                                             AS question,
    '["approve","decline"]'::jsonb                      AS options,
    created_at,
    nullif(payload->>'work_item_id','')::uuid           AS work_item_id
  FROM stewards.hinge_reviews
 WHERE kind = 'tool-confirm' AND status IN ('pending','escalated')

UNION ALL
SELECT
    'ask'::text,
    id::text,
    subject,
    coalesce(payload->>'question', subject),
    NULL::jsonb,
    created_at,
    nullif(payload->>'work_item_id','')::uuid
  FROM stewards.hinge_reviews
 WHERE kind = 'ask' AND status IN ('pending','escalated')

UNION ALL
SELECT
    'hinge'::text,
    id::text,
    subject,
    coalesce(payload->>'reason', subject),
    '["approve","revise","decline"]'::jsonb,
    created_at,
    nullif(payload->>'work_item_id','')::uuid
  FROM stewards.hinge_reviews
 WHERE kind NOT IN ('tool-confirm','ask') AND status IN ('pending','escalated')

UNION ALL
SELECT
    'a2a_question'::text,
    id::text,
    coalesce(input->>'title', '(untitled)'),
    a2a_question,
    NULL::jsonb,
    updated_at,
    id
  FROM stewards.work_items
 WHERE status = 'awaiting_review' AND a2a_question IS NOT NULL

UNION ALL
SELECT
    'review'::text,
    id::text,
    coalesce(input->>'title', pipeline_family || ' / ' || current_stage),
    coalesce(error, format('Stage "%s" complete — review and continue', current_stage)),
    NULL::jsonb,
    updated_at,
    id
  FROM stewards.work_items
 WHERE status = 'awaiting_review' AND a2a_question IS NULL
;

COMMENT ON VIEW stewards.needs_attention IS
'89: every human-blocking item, one shape. gate=84 tool-confirm reviews; ask=free-standing questions (ask_up''s top-rung fallback, §3); hinge=every other Hinge review kind (39); a2a_question=69 INPUT_REQUIRED (the exact blocking question); review=a paused pipeline stage with no question (ack-to-continue). options=NULL means free-text (the UI renders a text input); a jsonb array of strings means quick-reply buttons. Backs the Stewdio "Needs your answer" bell.';

-- ── needs_attention_list — the jsonb-agg wrapper the Go API scans (mirrors
--    tool_confirm_pending's shape: one row → jsonb_agg, so a2aQuery's plain
--    "SELECT fn()" passthrough works unchanged).
CREATE OR REPLACE FUNCTION stewards.needs_attention_list(p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(a ORDER BY a.created_at), '[]'::jsonb)
      FROM (SELECT * FROM stewards.needs_attention ORDER BY created_at LIMIT p_limit) a;
$fn$;

COMMENT ON FUNCTION stewards.needs_attention_list(int) IS
'89: needs_attention as a jsonb array, oldest first, capped at p_limit. The Stewdio bell''s list call.';

-- ── attention_count — the cheap badge count.
CREATE OR REPLACE FUNCTION stewards.attention_count()
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT jsonb_build_object('count', count(*)) FROM stewards.needs_attention;
$fn$;

COMMENT ON FUNCTION stewards.attention_count() IS
'89: {"count": N} — how many items need Michael''s answer right now. Cheap (STABLE, no joins beyond the view''s own unions). The Stewdio bell badge.';

-- =====================================================================
-- §2 — ask_record_answer: the ONE kind with no existing resolver.
-- =====================================================================
-- Every other kind routes to a resolver 39/69/84 already built. 'ask' is
-- new (born here, §3) and is NOT a proposal (approve/revise/decline) — it is
-- a free-text QUESTION needing a free-text ANSWER, so hinge_record_verdict's
-- verdict vocabulary doesn't fit. GAP (named, not hidden): this records the
-- answer on the hinge_reviews row but does NOT yet deliver it back to the
-- asking agent/work item — there is no live round-trip today. That delivery
-- is Phase 3 (Stewdio surface polish / the notify service, per the proposal's
-- build-phases list); until then the asker (or a teammate) reads the answer
-- off the resolved hinge_reviews row.
CREATE OR REPLACE FUNCTION stewards.ask_record_answer(p_hinge_id bigint, p_answer text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_row stewards.hinge_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM stewards.hinge_reviews WHERE id = p_hinge_id AND kind = 'ask';
    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'note', 'no such ask (wrong id or not kind=ask)');
    END IF;
    IF v_row.status NOT IN ('pending','escalated') THEN
        RETURN jsonb_build_object('ok', false, 'note', format('ask already %s', v_row.status));
    END IF;

    UPDATE stewards.hinge_reviews
       SET status      = 'applied',
           verdict     = 'answered',
           reason      = p_answer,
           reviewed_by = 'michael',
           reviewed_at = now(),
           applied_at  = now(),
           payload     = payload || jsonb_build_object('answer', p_answer)
     WHERE id = p_hinge_id;

    RETURN jsonb_build_object('ok', true, 'hinge_id', p_hinge_id, 'status', 'applied', 'answer', p_answer);
END;
$fn$;

COMMENT ON FUNCTION stewards.ask_record_answer(bigint, text) IS
'89: records Michael''s free-text answer to an ask (hinge_reviews kind=ask). GAP: does not yet deliver the answer back to the asking agent/work item — that live round-trip is Phase 3 (Stewdio surface polish / the notify service). Today the answer lives on the resolved hinge_reviews row.';

-- =====================================================================
-- §3 — attention_answer: route to the RIGHT existing resolver per kind.
-- =====================================================================
-- p_id is text, not one narrow type — the id space genuinely differs per
-- kind (hinge_reviews.id is bigint; work_items.id is uuid), and the view
-- already carries source_id as text for exactly this reason. Each branch
-- casts to the resolver's real parameter type and calls it VERBATIM — no
-- reimplementation of tool_confirm_verdict / hinge_record_verdict /
-- a2a_answer / work_item_dispatch_stage, so their existing bounds (84's
-- escalate-always wall; 39's auto-approve/escalate-always wall) apply
-- exactly as they do everywhere else those verbs are called.
CREATE OR REPLACE FUNCTION stewards.attention_answer(
    p_kind   text,
    p_id     text,
    p_answer text
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
    IF p_kind = 'gate' THEN
        -- 84's resolver: records Michael's verdict AND executes the STORED
        -- call verbatim on approve (idempotent; declines execute nothing).
        RETURN stewards.tool_confirm_verdict(p_id::bigint, p_answer, NULL, 'michael');

    ELSIF p_kind = 'hinge' THEN
        -- 39's resolver: bounds-enforced (hinge_auto_approve_kinds /
        -- hinge_escalate_always_kinds); reviewer='michael' so the verdict
        -- is final regardless of kind.
        RETURN stewards.hinge_record_verdict(p_id::bigint, p_answer, NULL, 'michael');

    ELSIF p_kind = 'ask' THEN
        -- No existing resolver fits a free-text Q&A (§2's gap, named there).
        RETURN stewards.ask_record_answer(p_id::bigint, p_answer);

    ELSIF p_kind = 'a2a_question' THEN
        -- 69's resolver: clears a2a_question, returns the task to
        -- in_progress, drops an answer-note in the worker's inbox.
        RETURN stewards.a2a_answer(p_id::uuid, p_answer);

    ELSIF p_kind = 'review' THEN
        -- No dedicated "review" resolver exists — the real resume path IS
        -- re-dispatching the paused stage (04's own status-check already
        -- accepts 'awaiting_review'). A non-empty p_answer becomes that
        -- stage's user_input override (the same one-shot override the
        -- steward's own retries use); empty/whitespace resumes with the
        -- stage's normal templated input.
        RETURN jsonb_build_object(
            'work_item_id',  p_id::uuid,
            'dispatched',    true,
            'work_queue_id', stewards.work_item_dispatch_stage(
                                  p_id::uuid, nullif(btrim(coalesce(p_answer,'')), '')));
    ELSE
        RETURN jsonb_build_object('ok', false, 'note', format('attention_answer: unknown source_kind %s', p_kind));
    END IF;
END;
$fn$;

COMMENT ON FUNCTION stewards.attention_answer(text, text, text) IS
'89: the ONE answer-routing entry point the Stewdio bell calls. Dispatches by source_kind to the resolver that kind ALREADY has: gate->tool_confirm_verdict (84), hinge->hinge_record_verdict (39), a2a_question->a2a_answer (69), review->work_item_dispatch_stage (04, re-dispatch resumes the paused stage), ask->ask_record_answer (89 §2, the one genuinely new kind). Never reimplements a resolver''s bounds.';

-- =====================================================================
-- §4 — ask_up: ladder Phase 2's model-tier consult.
-- =====================================================================
-- escalation_ladder_current_rung — best-effort map a work_item to the rung
-- ITS CALLER is running at: model_override (the one-shot pin most callers —
-- the steward, a pinned chat turn — set) if present, else the pipeline
-- stage's own declared model. Unlisted → rung 0 (the proposal's "unlisted →
-- rung 0" — weaker than anything on the ladder, so ANY enabled rung is
-- "up" from it).
CREATE OR REPLACE FUNCTION stewards.escalation_ladder_current_rung(p_work_item uuid)
RETURNS int LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_wi    stewards.work_items%ROWTYPE;
    v_model text;
    v_rung  int;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item;
    IF v_wi.id IS NULL THEN RETURN 0; END IF;

    v_model := v_wi.model_override;
    IF v_model IS NULL THEN
        v_model := (stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage))->>'model';
    END IF;

    SELECT rung INTO v_rung FROM stewards.escalation_ladder WHERE model_alias = v_model;
    RETURN coalesce(v_rung, 0);
END;
$fn$;

COMMENT ON FUNCTION stewards.escalation_ladder_current_rung(uuid) IS
'89: the CALLER''s rung on 84''s escalation_ladder — model_override if the work_item has a one-shot pin, else the current stage''s declared model. No ladder row matches (or the work_item is gone) -> rung 0, the proposal''s "unlisted -> rung 0."';

-- ask_up — Piece 3 of the ladder (.spec/proposals/hinge-and-escalation-ladder.md):
-- consult a STRONGER model; NO authority transfer, NO side effect. The
-- caller still decides and still hits the tool-effect gate (84) for
-- anything dangerous — this only widens what it reasons with.
--   * A higher enabled rung exists above the caller's own rung: dispatch a
--     ONE-SHOT consult via the EXISTING chat machinery (dispatch_chat_turn,
--     45 — session-ensure + alias->concrete-model resolution + chat_enqueue;
--     the same enqueue path Stewdio's "chat with a work item" and the
--     model-pin escalation already use). The answer lands in stewards.messages
--     for the returned session_id; nothing here blocks on it or applies it.
--   * No higher enabled rung (the caller is already AT or ABOVE the top): there
--     is nowhere higher to ask — park it as a human 'ask' (hinge_enqueue) so
--     it surfaces in needs_attention rather than silently stranding.
-- Phase 2 minimal, per the proposal: no min_tier knob, no autopilot, no
-- notify service — just the two branches the ladder needs to exist at all.
CREATE OR REPLACE FUNCTION stewards.ask_up(
    p_work_item uuid,
    p_question  text,
    p_context   jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_rung       int  := stewards.escalation_ladder_current_rung(p_work_item);
    v_next_rung  int;
    v_next_alias text;
    v_session    text;
    v_wq_id      bigint;
    v_hinge_id   bigint;
BEGIN
    IF p_question IS NULL OR length(btrim(p_question)) = 0 THEN
        RAISE EXCEPTION 'ask_up: question is required';
    END IF;

    SELECT rung, model_alias INTO v_next_rung, v_next_alias
      FROM stewards.escalation_ladder
     WHERE enabled AND rung > v_rung
     ORDER BY rung ASC
     LIMIT 1;

    IF v_next_alias IS NOT NULL THEN
        v_session := substring(
            'askup--' || substring(p_work_item::text from 1 for 8)
            || '--' || substring(md5(p_question || clock_timestamp()::text) from 1 for 8)
            FROM 1 FOR 200);

        v_wq_id := stewards.dispatch_chat_turn(
            v_session,
            p_question || CASE WHEN coalesce(p_context, '{}'::jsonb) <> '{}'::jsonb
                                THEN E'\n\nContext: ' || p_context::text ELSE '' END,
            'work-item-chat',
            v_next_alias,
            format('You are being consulted by another agent working on work_item %s (rung %s). '
                   || 'Answer plainly — you are advising, not taking over the task.', p_work_item, v_rung));

        RETURN jsonb_build_object(
            'escalated_to',  'consult',
            'rung',          v_next_rung,
            'model_alias',   v_next_alias,
            'session_id',    v_session,
            'work_queue_id', v_wq_id,
            'note', 'no authority transfer — the answer lands in stewards.messages for this session; the caller still decides and still hits the tool-effect gate for anything dangerous.'
        );
    END IF;

    v_hinge_id := stewards.hinge_enqueue(
        'ask',
        left(p_question, 120),
        jsonb_build_object('question', p_question, 'context', coalesce(p_context, '{}'::jsonb),
                            'work_item_id', p_work_item, 'caller_rung', v_rung),
        'ask_up');

    RETURN jsonb_build_object(
        'escalated_to', 'human',
        'hinge_id',     v_hinge_id,
        'note', 'already at (or above) the top enabled rung — parked for Michael in needs_attention (kind=ask).'
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.ask_up(uuid, text, jsonb) IS
'89: ladder Phase 2 — the caller consults the NEXT enabled rung above its own (escalation_ladder_current_rung) via a one-shot dispatch_chat_turn (45''s existing enqueue machinery; NO authority transfer, NO side effect). No higher enabled rung -> hinge_enqueue(kind=ask), surfacing in needs_attention for Michael instead of silently stranding. Phase 2 minimal: no min_tier, no autopilot (Phase 4, council-gated).';

-- =====================================================================
-- End of 89-attention.sql
-- =====================================================================
