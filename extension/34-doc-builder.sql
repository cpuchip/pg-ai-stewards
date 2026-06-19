-- =====================================================================
-- 34-doc-builder.sql — agentic doc construction: build the artifact via
-- tool-call diffs, instead of one-shot emitting it as the final chat output.
-- =====================================================================
-- The problem (FlexLLama local-model soak, 2026-06-19): asking a small local
-- model to emit a 20k-char structured digest in ONE generation triggers all
-- three soak failures — the long call trips the 15-min reaper, it monopolizes
-- the model's one slot (contention), and grammar-constrained final output 500s
-- on a reasoning model ("peg-native format"). But these models are TRAINED for
-- tool-calling loops. Reframe (Michael, ratified 2026-06-19): the model BUILDS
-- the doc with small tool-call diffs (doc_create/append/patch), each call short;
-- its chat "final output" becomes a free-flow JOURNAL of what it did. This is how
-- the coder already works (code-write/code-pr ApplyEdits + self-heal), and how
-- Claude writes anything large — incrementally, never one-shot.
--
-- Why it addresses the three: many short calls (no single >15min reap); each call
-- frees the slot (interleave); tool-call JSON is the model's NATIVE trained format
-- and allows think-THEN-call, so reasoning tokens no longer break a grammar.
--
-- Pilot scope: playlist-digest (the leg actually broken on qwen). Self-contained:
-- WIP lives in its own doc_drafts table (NOT a flag on docs) so it touches zero
-- core search/embedding and a no-go just drops the table. Finalize pools via the
-- existing import_doc. Proposal: .spec/proposals/agentic-doc-construction.md.
-- Generic core; pairs with the page-in tools (33) for bounded source reads.
-- =====================================================================

-- ── WIP drafts: the model's scratch artifact, keyed by its building session ──
CREATE TABLE IF NOT EXISTS stewards.doc_drafts (
    handle      text PRIMARY KEY DEFAULT substr(md5(random()::text || clock_timestamp()::text), 1, 8),
    session_id  text NOT NULL,
    title       text NOT NULL,
    outline     text,
    body        text NOT NULL DEFAULT '',
    project     text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS doc_drafts_session_idx ON stewards.doc_drafts (session_id);
COMMENT ON TABLE stewards.doc_drafts IS
'34: work-in-progress docs the model builds incrementally via doc_* tool calls. Scoped to the building session; finalize -> import_doc pool + delete. Self-contained (no core search/embedding touch).';

-- ── doc_create: start a draft (outline-first, for coherence) ──────────
CREATE OR REPLACE FUNCTION stewards.doc_create_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess    text := p_args ->> '_session_id';
    v_title   text := btrim(coalesce(p_args ->> 'title', ''));
    v_outline text := p_args ->> 'outline';
    v_project text := p_args ->> 'project';
    v_handle  text;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_title = '' THEN RETURN jsonb_build_object('error', 'title required'); END IF;
    INSERT INTO stewards.doc_drafts (session_id, title, outline, project, body)
    VALUES (v_sess, v_title, v_outline, v_project, '# ' || v_title || E'\n')
    RETURNING handle INTO v_handle;
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'title', v_title,
        'note', 'draft started. Build it section by section with doc_append_section("' || v_handle ||
                '", heading, body); fix with doc_patch; check with doc_read; doc_finalize when complete. '
                || CASE WHEN v_outline IS NOT NULL AND btrim(v_outline) <> ''
                        THEN 'Your outline: ' || v_outline ELSE 'Tip: sketch an outline first.' END);
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_create_tool(jsonb) IS '34: start a WIP draft, return its handle.';

-- ── doc_append_section: append a section (the main building diff) ──────
CREATE OR REPLACE FUNCTION stewards.doc_append_section_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess    text := p_args ->> '_session_id';
    v_handle  text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_heading text := p_args ->> 'heading';
    v_body    text := coalesce(p_args ->> 'body', '');
    v_chars   int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle = '' THEN RETURN jsonb_build_object('error', 'handle required (from doc_create)'); END IF;
    IF btrim(v_body) = '' AND coalesce(btrim(v_heading), '') = '' THEN
        RETURN jsonb_build_object('error', 'heading or body required'); END IF;
    UPDATE stewards.doc_drafts
       SET body = body || E'\n\n'
                  || CASE WHEN v_heading IS NOT NULL AND btrim(v_heading) <> ''
                          THEN '## ' || btrim(v_heading) || E'\n\n' ELSE '' END
                  || v_body,
           updated_at = now()
     WHERE handle = v_handle AND session_id = v_sess
    RETURNING length(body) INTO v_chars;
    IF v_chars IS NULL THEN RETURN jsonb_build_object('error', 'no draft ' || v_handle || ' in your session (doc_create first)'); END IF;
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'total_chars', v_chars,
        'note', 'section appended. Keep going, or doc_read to review, or doc_finalize to pool it.');
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_append_section_tool(jsonb) IS '34: append a markdown section to a draft.';

-- ── doc_patch: replace the first occurrence of an anchor (corrections) ─
CREATE OR REPLACE FUNCTION stewards.doc_patch_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_find   text := p_args ->> 'find';
    v_repl   text := coalesce(p_args ->> 'replace', '');
    v_body   text;
    v_pos    int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle = '' THEN RETURN jsonb_build_object('error', 'handle required'); END IF;
    IF v_find IS NULL OR v_find = '' THEN RETURN jsonb_build_object('error', 'find (the exact text to replace) required'); END IF;
    SELECT body INTO v_body FROM stewards.doc_drafts WHERE handle = v_handle AND session_id = v_sess;
    IF v_body IS NULL THEN RETURN jsonb_build_object('error', 'no draft ' || v_handle || ' in your session'); END IF;
    v_pos := position(v_find IN v_body);
    IF v_pos = 0 THEN RETURN jsonb_build_object('error', 'find text not present — doc_read to see the current body', 'handle', v_handle); END IF;
    UPDATE stewards.doc_drafts
       SET body = left(v_body, v_pos - 1) || v_repl || substr(v_body, v_pos + length(v_find)),
           updated_at = now()
     WHERE handle = v_handle AND session_id = v_sess;
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'note', 'patched the first occurrence.');
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_patch_tool(jsonb) IS '34: replace the first occurrence of an anchor in a draft.';

-- ── doc_read: read back what is built (read-before-write discipline) ──
CREATE OR REPLACE FUNCTION stewards.doc_read_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_d      stewards.doc_drafts%ROWTYPE;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle = '' THEN RETURN jsonb_build_object('error', 'handle required'); END IF;
    SELECT * INTO v_d FROM stewards.doc_drafts WHERE handle = v_handle AND session_id = v_sess;
    IF v_d.handle IS NULL THEN RETURN jsonb_build_object('error', 'no draft ' || v_handle || ' in your session'); END IF;
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'title', v_d.title,
        'total_chars', length(v_d.body), 'body', v_d.body);
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_read_tool(jsonb) IS '34: read the current body of a draft.';

-- ── doc_finalize: pool the finished draft (import_doc) + delete it ────
CREATE OR REPLACE FUNCTION stewards.doc_finalize_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_slug   text := p_args ->> 'slug';
    v_d      stewards.doc_drafts%ROWTYPE;
    v_doc_id text;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle = '' THEN RETURN jsonb_build_object('error', 'handle required'); END IF;
    SELECT * INTO v_d FROM stewards.doc_drafts WHERE handle = v_handle AND session_id = v_sess;
    IF v_d.handle IS NULL THEN RETURN jsonb_build_object('error', 'no draft ' || v_handle || ' in your session'); END IF;
    IF length(btrim(v_d.body)) < 80 THEN
        RETURN jsonb_build_object('error', 'draft too short to finalize (' || length(v_d.body) || ' chars) — build it first'); END IF;
    v_slug := coalesce(nullif(btrim(coalesce(v_slug, '')), ''),
                       regexp_replace(lower(v_d.title), '[^a-z0-9]+', '-', 'g') || '-' || v_handle);
    -- pool it (import_doc returns the doc id, not the slug)
    v_doc_id := stewards.import_doc(v_slug, '', v_d.title, v_d.body,
                    jsonb_build_object('built_by', 'doc-construction', 'session', v_sess), 'digest');
    IF v_d.project IS NOT NULL AND btrim(v_d.project) <> '' THEN
        UPDATE stewards.docs SET project_association = v_d.project WHERE slug = v_slug;
    END IF;
    DELETE FROM stewards.doc_drafts WHERE handle = v_handle;
    RETURN jsonb_build_object('ok', true, 'slug', v_slug, 'doc_id', v_doc_id,
        'chars', length(v_d.body),
        'note', 'pooled to the docs corpus and the draft cleared. Your chat reply now is the JOURNAL: what you read, chose, and produced.');
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_finalize_tool(jsonb) IS '34: pool a finished draft via import_doc + delete the draft.';

-- ── register the tools (sql_fn — no bridge refresh needed) ────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'doc_create',
  'Start building a document incrementally. You do NOT write the whole document as one chat reply — you BUILD it with tool calls (this is how good agents write anything large). Returns a handle. Sketch an outline, then add sections with doc_append_section, fix with doc_patch, and doc_finalize when done. Your final chat reply is a short JOURNAL of what you did, not the document itself.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"title":{"type":"string","description":"the document title"},'
    '"outline":{"type":"string","description":"optional: a brief section outline to keep the doc coherent"},'
    '"project":{"type":"string","description":"optional pool/project tag, e.g. ai or books"}'
  '},"required":["title"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_create_tool"}'::jsonb, true ),
( 'doc_append_section',
  'Append one section to the document you are building. Keep each call small — a heading plus a few focused paragraphs. Call it repeatedly to build the doc section by section. Small diffs are the point: they finish fast (no timeouts), free the model for other work, and play to what you are good at (tool calls, not one giant grammar-constrained generation).',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the draft handle from doc_create"},'
    '"heading":{"type":"string","description":"section heading (optional; omit to append body only)"},'
    '"body":{"type":"string","description":"the section text (markdown)"}'
  '},"required":["handle","body"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_append_section_tool"}'::jsonb, true ),
( 'doc_patch',
  'Fix or revise text already in your draft: replace the first occurrence of an exact anchor string with new text. Use doc_read first to see the current body. Good for corrections and tightening — redemptive editing, the same loop you use when fixing code.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the draft handle"},'
    '"find":{"type":"string","description":"exact text currently in the draft to replace"},'
    '"replace":{"type":"string","description":"the new text (empty string deletes the anchor)"}'
  '},"required":["handle","find"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_patch_tool"}'::jsonb, true ),
( 'doc_read',
  'Read back the current body of the document you are building, so you know what is already there before adding more (read-before-write).',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the draft handle"}'
  '},"required":["handle"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_read_tool"}'::jsonb, true ),
( 'doc_finalize',
  'Finish the document: pool it to the searchable corpus and clear the draft. Call this once the doc is complete. After finalizing, your chat reply should be a short JOURNAL — what you read, what you decided, and that you produced the doc (slug returned) — NOT the document text again.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the draft handle"},'
    '"slug":{"type":"string","description":"optional explicit slug (default derived from the title)"}'
  '},"required":["handle"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"doc_finalize_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- ── grant to the digester / research doers (idempotent) ───────────────
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
SELECT v.a, v.b, 'allow', 'manual'
  FROM (SELECT a, b FROM unnest(ARRAY['research','stewards-explore']) a
                  CROSS JOIN unnest(ARRAY['doc_create','doc_append_section','doc_patch','doc_read','doc_finalize']) b) v
 WHERE NOT EXISTS (
        SELECT 1 FROM stewards.agent_tool_perms p
         WHERE p.agent_family = v.a AND p.tool_pattern = v.b AND p.action = 'allow');

-- =====================================================================
-- End of 34-doc-builder.sql
-- =====================================================================
