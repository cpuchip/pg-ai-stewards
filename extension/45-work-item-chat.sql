-- =====================================================================
-- 45 — work-item chat: "chat with a work item" (Stewdio's right panel)
-- =====================================================================
-- A conversational agent that answers grounded in a work item's facets — its
-- doc, its source corpus, and the agent sessions that built it — using ONLY
-- retrieval tools. Each turn runs against a PERSISTENT chat session (not a
-- work_item), so there is no per-message work_item bloat. The reply lands in
-- stewards.messages keyed by session_id; the Stewdio UI streams it over SSE.
--
-- Design (ratified 2026-06-23, .spec/proposals/stewards-studio.md, decision #8):
--   * persistent chat sessions, dispatched via dispatch_chat_turn (a thin
--     wrapper over the existing bare-session chat_enqueue path — full agentic
--     tool loop, marker-free kind='chat' work_queue row, so the work_item
--     completion trigger [04, gated on _work_item_id] never fires);
--   * a read-only retrieval agent (allow-list over a deny-all base);
--   * local model by default (model alias 'reason' → the operator's rig via the
--     role-aliases overlay; falls back to a literal model + catalog default
--     provider when the alias isn't seeded, e.g. a virgin core).

-- ---------------------------------------------------------------------
-- §1 — the work-item-chat agent family
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES (
  'work-item-chat', '*',
  'Conversational agent: answers grounded in a work item''s doc + corpus + sessions via retrieval tools only.',
  'primary',
  $PROMPT$You are answering a human's questions about ONE work item (or the doc it produced) inside Stewdio.
You are in a CHAT WINDOW: replies are short and conversational — a few paragraphs at most — and you invite the next question.

Ground every answer in what you RETRIEVE — never from memory:
- The doc itself: doc_get (read its body), doc_search / doc_similar (related corpus).
- The source it was built from: read_corpus_parents / result_search where a corpus exists; doc_citations for cited sources.
- The agent sessions that built it ("how/why did you conclude X"): investigate_session on the building session, or investigate_doc.

Retrieve BEFORE you answer, and cite (doc slug, session) rather than paraphrasing from memory. If the material is silent on a question, say so plainly — do not invent.

COMMIT — do not over-think. The MOMENT your retrieved material answers the question, STOP retrieving and STOP verifying, and write the answer. Verify at most once; never re-read a source you have already read to double-check yourself. A solid grounded answer sent now beats a perfect one you keep polishing and never send.

KEEP IT TO THE CHAT WINDOW. A few short paragraphs, max. If a faithful answer would run longer than that — a full report, a broad survey across the corpus, a deep multi-part analysis — do NOT write it inline. Instead call start_task (e.g. pipeline 'research-summary') with the user's question as the binding_question to DELEGATE the report: it spawns a work_item that builds the report, links to this chat, and appears as a card the user can watch. Then reply briefly — tell them you've started the report and give a one- or two-sentence preview of the headline finding.

Your tools are read-only (you do not modify anything) EXCEPT start_task, which delegates a larger piece of work.$PROMPT$,
  0.3, 12
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description,
      prompt      = EXCLUDED.prompt,
      temperature = EXCLUDED.temperature,
      steps       = EXCLUDED.steps,
      active       = true;

-- ---------------------------------------------------------------------
-- §2 — tool grants: a READ-ONLY allow-list (deny '*' base; longest-glob-wins
-- means each specific allow beats the catch-all deny). source='manual' so the
-- frontmatter re-importer never wipes it.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', '*',                   'deny',  'manual'),
  ('work-item-chat', 'doc_search',          'allow', 'manual'),
  ('work-item-chat', 'doc_get',             'allow', 'manual'),
  ('work-item-chat', 'doc_similar',         'allow', 'manual'),
  ('work-item-chat', 'doc_citations',       'allow', 'manual'),
  ('work-item-chat', 'investigate_session', 'allow', 'manual'),
  ('work-item-chat', 'investigate_doc',     'allow', 'manual'),
  ('work-item-chat', 'context_search',      'allow', 'manual'),
  ('work-item-chat', 'read_corpus_parents', 'allow', 'manual'),
  ('work-item-chat', 'result_search',       'allow', 'manual'),
  ('work-item-chat', 'result_read',         'allow', 'manual'),
  ('work-item-chat', 'expand_message',      'allow', 'manual'),
  ('work-item-chat', 'work_item_show',      'allow', 'manual'),
  ('work-item-chat', 'work_item_list',      'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ---------------------------------------------------------------------
-- §3 — dispatch_chat_turn: enqueue one chat turn against a persistent session.
-- ---------------------------------------------------------------------
-- Mirrors the bare-session chat path (chat_enqueue → chat_post_internal →
-- dry_run_chat → kind='chat' work_queue row → bgworker tool loop → reply in
-- messages), adding: session ensure, first-turn grounding, and alias→concrete
-- model resolution (chat_enqueue takes a concrete provider+model, not an alias).
-- Emits NO _work_item_id/_stage_name/_pipeline_family markers, so it never
-- trips the work_item or watchman completion triggers.
CREATE OR REPLACE FUNCTION stewards.dispatch_chat_turn(
    p_session_id   text,
    p_user_input   text,
    p_agent_family text DEFAULT 'work-item-chat',
    p_model_alias  text DEFAULT 'reason',
    p_grounding    text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $FN$
DECLARE
    v_provider text;
    v_model    text;
    v_have     int;
BEGIN
    -- ensure the persistent chat session exists (kind='chat')
    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (p_session_id, 'stewdio chat ' || left(p_session_id, 40), 'chat')
    ON CONFLICT (id) DO NOTHING;

    -- on the first turn, seed the grounding (which work item/doc + how to ground).
    -- A user-role context row (kept simple so compose_messages doesn't relabel a
    -- mid-history system row); subsequent turns inherit it from history.
    SELECT count(*) INTO v_have FROM stewards.messages WHERE session_id = p_session_id;
    IF v_have = 0 AND p_grounding IS NOT NULL AND length(btrim(p_grounding)) > 0 THEN
        INSERT INTO stewards.messages (session_id, role, content)
        VALUES (p_session_id, 'user', p_grounding);
    END IF;

    -- resolve the alias → concrete (provider, model); fall back to a literal
    -- model id + the catalog default provider when the alias isn't seeded.
    SELECT m.provider, m.model INTO v_provider, v_model
      FROM stewards.pick_alias_member(p_model_alias, false) m;
    IF v_model IS NULL THEN
        v_model    := p_model_alias;
        v_provider := stewards.catalog_default_provider();
    END IF;

    -- append the user turn + enqueue (full tool loop; reply lands in messages)
    RETURN stewards.chat_enqueue(p_agent_family, v_model, p_session_id, p_user_input, v_provider);
END
$FN$;

COMMENT ON FUNCTION stewards.dispatch_chat_turn(text, text, text, text, text) IS
'45: enqueue one chat turn against a persistent chat session (Stewdio "chat with a work item"). Wraps chat_enqueue with session-ensure + first-turn grounding + alias→model resolution. Marker-free kind=chat row → bgworker tool loop → reply in messages by session_id; never trips the work_item/watchman triggers.';
