-- examples/case-file-digester.sql — drop a folder of delicate paperwork in,
-- get an inspectable case file out.
--
-- The Build-2 reproduction from the 2026-07-07 pipelines-skeleton panel
-- (.spec/wargames/2026-07-07-pipelines-skeleton/DEMO-PATH.md): a pipeline
-- family `case-file` that walks a dropped document pack (a denial letter,
-- the policy it cites, a claim history, supporting notes) into a case file
-- a human can inspect — fact timeline, denial map with the EXACT cited
-- language, evidence checklist with missing items first, citation-sanity
-- findings, and a draft appeal letter.
--
-- THE DESIGN DECISION THAT MAKES IT A CASE FILE AND NOT A VIBES LETTER:
-- facts are queries, not compositions. The timeline, denial map, cited
-- language, checklist, and findings are rendered SERVER-SIDE from typed
-- rows (v29's doc_facts / evidence_items + this file's case_citations) by
-- SQL functions — the model never re-types a date, an amount, or a policy
-- sentence, so it cannot drift from the database even on a bad day. The
-- draft appeal letter is the ONE generative section, and it must cite the
-- same [doc#section] anchors, so it stays checkable the same way.
--
-- GATE POSTURE: the pipeline ENDS at the assembled case file + draft.
-- There is no send tool in this file, in core, or anywhere else — grep for
-- one. An absent capability cannot be jailbroken. The case file's preamble
-- says so in print.
--
-- Builds on v29-normalize (doc_sections / doc_split_sections / doc_facts /
-- parse_facts_deterministic / evidence_items + the renders) and on the
-- citation_check Go tool (cmd/stewards-mcp/citation_check.go — reached via
-- the pg-ai-stewards mcp_proxy surface; its tool_def is seeded HERE,
-- because examples own their seeds).
--
-- Import after the model catalog (examples/models.sql) into a stack with a
-- provider configured:
--   docker compose exec -T pg psql -U stewards -d stewards < examples/case-file-digester.sql
--
-- The demo pack + a runnable deterministic-spine walkthrough live in
-- examples/case-file-demo/ (four synthetic files with ONE planted
-- contradiction — the inverse-hypothesis fixture for citation_check).
--
-- LIFELESS-CORE COMPLIANCE: no model or provider is named here. Stages
-- name ROLES (ingest/reason/critic); the alias router picks the member.
-- The deterministic spine (sections, floor, renders, assemble) runs with
-- ZERO models configured — only normalize/sanity/letter need one.

-- ── case shelf ──────────────────────────────────────────────────────────
-- Mirrors book_shelf: the queue + the cross-stage cursor. One case is
-- 'building' at a time; case_next claims it, case_file_publish closes it.
CREATE TABLE IF NOT EXISTS stewards.case_shelf (
    slug        text PRIMARY KEY CHECK (slug ~ '^[a-z0-9-]+$'),
    title       text NOT NULL,
    project     text NOT NULL,              -- docs.project_association tag of the case's document pack
    status      text NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued','building','done','skipped')),
    started_at  timestamptz,
    done_at     timestamptz,
    added_by    text NOT NULL DEFAULT 'seed',
    added_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.case_shelf IS
'case-file digester queue. status flows queued -> building -> done. The single building row is the cross-stage cursor (case_next claims it, case_file_publish closes it). project names the docs.project_association tag the case''s dropped documents carry (the drop-folder name).';

-- ── case_citations: the citation-sanity ledger ──────────────────────────
-- One row per citation_check verdict: what the citing document CLAIMED the
-- cited document says, and whether it actually says it. The renders below
-- read this ledger — a MISMATCH row is finding #1. The Go tool is the
-- oracle; this table is the ledger the case file is rendered from.
CREATE TABLE IF NOT EXISTS stewards.case_citations (
    id                bigserial PRIMARY KEY,
    case_slug         text NOT NULL REFERENCES stewards.case_shelf(slug) ON DELETE CASCADE,
    claim_quote       text NOT NULL,        -- the text the citing doc attributes to the cited one
    source_doc_id     text,                 -- the CITING doc (the denial letter); soft
    cited_doc_id      text NOT NULL,        -- the CITED doc (the policy) — canonical docs.id
    cited_section_ref text,                 -- v29 section address, when resolved (e.g. s1.3)
    verified          boolean NOT NULL,
    nearest_excerpt   text,                 -- verbatim ACTUAL text near the closest overlap (mismatches)
    overlap_chars     int,                  -- real matched-character count (LCS) — a count, not a score
    note              text,
    checked_by        text NOT NULL DEFAULT 'citation_check',
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS case_citations_case_idx ON stewards.case_citations (case_slug);
COMMENT ON TABLE stewards.case_citations IS
'case-file digester: the citation-sanity ledger. Each row records one citation_check verdict (claimed quote vs. the cited doc/section''s actual text). verified=false rows are the FINDINGS — the case file renders them first. nearest_excerpt/overlap_chars come from the tool''s honest nearest-region report (longest common substring; no similarity scores, per the no-pg_trgm boundary). Recorded by the sanity stage copying the tool''s output; the tool itself is the oracle.';

-- ── case_add(slug, title, project): queue a case ────────────────────────
CREATE OR REPLACE FUNCTION stewards.case_add(p_slug text, p_title text, p_project text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE
    v_slug    text := trim(both '-' from lower(regexp_replace(coalesce(p_slug, ''), '[^a-zA-Z0-9]+', '-', 'g')));
    v_project text := coalesce(nullif(btrim(coalesce(p_project, '')), ''), NULL);
BEGIN
    IF v_slug = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'slug is required');
    END IF;
    IF btrim(coalesce(p_title, '')) = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'title is required');
    END IF;
    v_project := coalesce(v_project, v_slug);   -- default: project tag = case slug (the drop-folder name)
    INSERT INTO stewards.case_shelf (slug, title, project, added_by)
    VALUES (v_slug, btrim(p_title), v_project, 'tool')
    ON CONFLICT (slug) DO NOTHING;
    -- Register the project entity so work items / project scoping can tag it.
    INSERT INTO stewards.projects (slug, name, description)
    VALUES (v_project, 'Case: ' || btrim(p_title), 'case-file digester document pack')
    ON CONFLICT (slug) DO NOTHING;
    RETURN jsonb_build_object('ok', true, 'slug', v_slug, 'project', v_project);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END $func$;

CREATE OR REPLACE FUNCTION stewards.case_add_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $func$
    SELECT stewards.case_add(p_args->>'slug', p_args->>'title', p_args->>'project');
$func$;

-- ── case_next(): claim the next case (resume the building one, else next queued)
CREATE OR REPLACE FUNCTION stewards.case_next()
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE
    v_row  stewards.case_shelf%ROWTYPE;
    v_docs jsonb;
BEGIN
    SELECT * INTO v_row FROM stewards.case_shelf
     WHERE status = 'building' ORDER BY added_at LIMIT 1;
    IF v_row.slug IS NULL THEN
        SELECT * INTO v_row FROM stewards.case_shelf
         WHERE status = 'queued' ORDER BY added_at LIMIT 1
           FOR UPDATE SKIP LOCKED;
        IF v_row.slug IS NULL THEN RETURN NULL; END IF;
        UPDATE stewards.case_shelf
           SET status = 'building', started_at = coalesce(started_at, now())
         WHERE slug = v_row.slug;
    END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object('slug', d.slug, 'title', d.title)
                              ORDER BY d.slug), '[]'::jsonb)
      INTO v_docs
      FROM stewards.docs d
     WHERE d.project_association = v_row.project
       AND d.kind <> 'case-file';   -- a previously-published case file is output, not input
    RETURN jsonb_build_object('slug', v_row.slug, 'title', v_row.title,
                              'project', v_row.project, 'docs', v_docs);
END $func$;

CREATE OR REPLACE FUNCTION stewards.case_next_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $func$
    SELECT coalesce(stewards.case_next()::text,
                    '{"case": null, "note": "the case shelf is empty — nothing queued"}');
$func$;

-- ── case_normalize_floor(case_slug): the deterministic spine, one call ──
-- Server-side, zero models: for every doc in the case's project,
--   1. doc_split_sections (v29 §2) — stable addressable section refs
--   2. parse_facts_deterministic (v29 §5) over the doc body — the typed
--      fact floor (dates, $-amounts), each row anchored to the section
--      containing its FIRST occurrence.
-- Idempotent: re-running deletes and re-extracts this extractor's own
-- rows only (extracted_by = 'parse_facts_deterministic'); LLM-refined
-- facts (deadline promotions, parties) are never touched.
CREATE OR REPLACE FUNCTION stewards.case_normalize_floor(p_case_slug text)
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE
    v_case     stewards.case_shelf%ROWTYPE;
    v_doc      record;
    v_fact     record;
    v_split    jsonb;
    v_pos      int;
    v_sref     text;
    n_docs     int := 0;
    n_sections int := 0;
    n_facts    int := 0;
BEGIN
    SELECT * INTO v_case FROM stewards.case_shelf WHERE slug = btrim(coalesce(p_case_slug, ''));
    IF v_case.slug IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('no case with slug "%s" — case_add it first', p_case_slug));
    END IF;

    FOR v_doc IN
        SELECT d.id, d.slug, d.body FROM stewards.docs d
         WHERE d.project_association = v_case.project
           AND d.kind <> 'case-file'   -- never split/extract a published case file back into itself
         ORDER BY d.slug
    LOOP
        n_docs := n_docs + 1;

        v_split := stewards.doc_split_sections(v_doc.id);
        IF NOT coalesce((v_split->>'ok')::boolean, false) THEN
            RETURN jsonb_build_object('ok', false, 'error',
                format('doc_split_sections failed for %s: %s', v_doc.slug, v_split->>'error'));
        END IF;
        n_sections := n_sections + coalesce((v_split->>'sections')::int, 0);

        -- re-runs replace only this extractor's own floor rows
        DELETE FROM stewards.doc_facts
         WHERE doc_id = v_doc.id AND extracted_by = 'parse_facts_deterministic';

        FOR v_fact IN
            SELECT * FROM stewards.parse_facts_deterministic(v_doc.body)
        LOOP
            -- anchor: the section containing the span's first occurrence
            -- (0-based char offset; sections are non-overlapping spans)
            v_pos  := position(v_fact.raw_text IN v_doc.body) - 1;
            v_sref := NULL;
            IF v_pos >= 0 THEN
                SELECT s.section_ref INTO v_sref FROM stewards.doc_sections s
                 WHERE s.doc_id = v_doc.id
                   AND s.char_start <= v_pos AND v_pos < s.char_end
                 LIMIT 1;
            END IF;
            INSERT INTO stewards.doc_facts
                (doc_id, section_ref, fact_kind, raw_text,
                 value_date, value_numeric, value_currency, extracted_by)
            VALUES
                (v_doc.id, v_sref, v_fact.fact_kind, v_fact.raw_text,
                 v_fact.value_date, v_fact.value_numeric, v_fact.value_currency,
                 'parse_facts_deterministic');
            n_facts := n_facts + 1;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'case_slug', v_case.slug,
                              'project', v_case.project, 'docs', n_docs,
                              'sections', n_sections, 'facts', n_facts);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END $func$;
COMMENT ON FUNCTION stewards.case_normalize_floor(text) IS
'case-file digester: the deterministic spine in one call — doc_split_sections + parse_facts_deterministic over every doc in the case''s project, floor facts inserted into doc_facts with section anchors (extracted_by=parse_facts_deterministic). Idempotent per extractor; never touches LLM-refined facts. Zero models. Never raises.';

CREATE OR REPLACE FUNCTION stewards.case_normalize_floor_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN stewards.case_normalize_floor(p_args->>'case_slug');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END $FN$;

-- ── case_citation_record: write one citation_check verdict to the ledger ─
CREATE OR REPLACE FUNCTION stewards.case_citation_record(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE
    v_case     stewards.case_shelf%ROWTYPE;
    v_slug     text := nullif(btrim(coalesce(p_args->>'case_slug', '')), '');
    v_quote    text := btrim(coalesce(p_args->>'claim_quote', ''));
    v_cited    text := coalesce(nullif(btrim(coalesce(p_args->>'cited_doc', '')), ''),
                                nullif(btrim(coalesce(p_args->>'cited_doc_id', '')), ''),
                                nullif(btrim(coalesce(p_args->>'cited_doc_slug', '')), ''));
    v_cited_id text;
    v_src      text := coalesce(nullif(btrim(coalesce(p_args->>'source_doc', '')), ''),
                                nullif(btrim(coalesce(p_args->>'source_doc_id', '')), ''),
                                nullif(btrim(coalesce(p_args->>'source_doc_slug', '')), ''));
    v_src_id   text;
    v_row      stewards.case_citations%ROWTYPE;
BEGIN
    IF v_slug IS NULL THEN
        SELECT * INTO v_case FROM stewards.case_shelf WHERE status = 'building'
         ORDER BY added_at LIMIT 1;
    ELSE
        SELECT * INTO v_case FROM stewards.case_shelf WHERE slug = v_slug;
    END IF;
    IF v_case.slug IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
            coalesce('no case with slug "' || v_slug || '"', 'no case is currently building — pass case_slug'));
    END IF;
    IF v_quote = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'claim_quote (the text the citing doc claims) is required');
    END IF;
    IF v_cited IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'cited_doc (id or slug of the CITED doc) is required');
    END IF;
    v_cited_id := stewards._doc_id_resolve(v_cited);
    IF v_cited_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', format('cited_doc: no doc with id or slug "%s"', v_cited));
    END IF;
    IF v_src IS NOT NULL THEN
        v_src_id := stewards._doc_id_resolve(v_src);  -- soft: unresolvable source is recorded as NULL
    END IF;
    IF p_args->'verified' IS NULL OR jsonb_typeof(p_args->'verified') <> 'boolean' THEN
        RETURN jsonb_build_object('ok', false, 'error',
            'verified (boolean — copy citation_check''s verdict faithfully) is required');
    END IF;

    INSERT INTO stewards.case_citations
        (case_slug, claim_quote, source_doc_id, cited_doc_id, cited_section_ref,
         verified, nearest_excerpt, overlap_chars, note, checked_by)
    VALUES
        (v_case.slug, v_quote, v_src_id, v_cited_id,
         nullif(btrim(coalesce(p_args->>'cited_section_ref', '')), ''),
         (p_args->>'verified')::boolean,
         nullif(btrim(coalesce(p_args->>'nearest_excerpt', '')), ''),
         nullif(p_args->>'overlap_chars', '')::int,
         nullif(btrim(coalesce(p_args->>'note', '')), ''),
         coalesce(nullif(btrim(coalesce(p_args->>'checked_by', '')), ''), 'citation_check'))
    RETURNING * INTO v_row;

    RETURN jsonb_build_object('ok', true, 'id', v_row.id, 'case_slug', v_row.case_slug,
        'verified', v_row.verified,
        'note', CASE WHEN v_row.verified THEN 'verdict recorded'
                     ELSE 'MISMATCH recorded — this is a finding; the case file will surface it first' END);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END $func$;
COMMENT ON FUNCTION stewards.case_citation_record(jsonb) IS
'case-file digester: record one citation_check verdict in the case_citations ledger. Args: claim_quote + cited_doc (+ verified, copied FAITHFULLY from the tool) required; case_slug (defaults to the building case), cited_section_ref, source_doc, nearest_excerpt, overlap_chars, note optional. Honesty note: the recording stage copies the tool''s output — the tool is the oracle, this is the ledger; the demo''s inverse proof runs against the TOOL directly.';

-- ── server-side renders (facts are queries, not compositions) ───────────

-- the case's source documents, with drop provenance
CREATE OR REPLACE FUNCTION stewards.render_case_sources(p_case_slug text)
RETURNS text LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_case  stewards.case_shelf%ROWTYPE;
    v_lines text;
BEGIN
    SELECT * INTO v_case FROM stewards.case_shelf WHERE slug = p_case_slug;
    IF v_case.slug IS NULL THEN RETURN '_no such case_'; END IF;
    SELECT string_agg(
             format('- [%s] **%s**%s', d.slug, d.title,
                    CASE WHEN d.frontmatter->>'drop_path' IS NOT NULL
                         THEN ' — dropped as `' || (d.frontmatter->>'drop_path') || '`'
                         ELSE '' END),
             E'\n' ORDER BY d.slug)
      INTO v_lines
      FROM stewards.docs d
     WHERE d.project_association = v_case.project
       AND d.kind <> 'case-file';   -- the case file lists its inputs, not itself
    RETURN format(E'## Sources\n\n%s',
                  coalesce(v_lines, '_no documents ingested for this case yet_'));
END $func$;

-- findings: the MISMATCH rows, numbered, first-class
CREATE OR REPLACE FUNCTION stewards.render_case_findings(p_case_slug text)
RETURNS text LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_lines   text;
    v_checked int;
    v_bad     int;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE NOT verified)
      INTO v_checked, v_bad
      FROM stewards.case_citations WHERE case_slug = p_case_slug;

    IF v_checked = 0 THEN
        RETURN E'## Findings\n\n_no citation checks recorded for this case_';
    END IF;
    IF v_bad = 0 THEN
        RETURN format(E'## Findings\n\n%s citation(s) checked · all verified — no findings.', v_checked);
    END IF;

    -- number the findings in a subquery (a window fn cannot live inside
    -- an aggregate's arguments), then render
    SELECT string_agg(
             format(E'### Finding #%s — cited text not found (MISMATCH)\n\n'
                    '- The citing document claims%s: "%s"\n'
                    '- The cited document [%s%s] ACTUALLY says%s: "%s"%s',
                    f.n,
                    coalesce(' (in [' || f.source_slug || '])', ''),
                    f.claim_quote,
                    f.cited_slug,
                    coalesce('#' || f.cited_section_ref, ''),
                    CASE WHEN f.overlap_chars IS NOT NULL
                         THEN format(' (closest region, %s consecutive matching characters)', f.overlap_chars)
                         ELSE '' END,
                    coalesce(f.nearest_excerpt, '(no overlapping region found)'),
                    coalesce(E'\n- Note: ' || f.note, '')),
             E'\n\n' ORDER BY f.n)
      INTO v_lines
      FROM (
        SELECT row_number() OVER (ORDER BY c.id) AS n,
               c.claim_quote, c.cited_section_ref, c.overlap_chars,
               c.nearest_excerpt, c.note,
               cd.slug AS cited_slug, sd.slug AS source_slug
          FROM stewards.case_citations c
          JOIN stewards.docs cd ON cd.id = c.cited_doc_id
          LEFT JOIN stewards.docs sd ON sd.id = c.source_doc_id
         WHERE c.case_slug = p_case_slug AND NOT c.verified
      ) f;

    RETURN format(E'## Findings\n\n%s citation(s) checked · %s MISMATCH(ES) — read these first.\n\n%s',
                  v_checked, v_bad, v_lines);
END $func$;
COMMENT ON FUNCTION stewards.render_case_findings(text) IS
'case-file digester: deterministic markdown of the verified=false case_citations rows — the findings, numbered, claim vs. actual text side by side. SELECT + format only.';

-- denial map: every checked citation, verdict + the EXACT cited language
CREATE OR REPLACE FUNCTION stewards.render_denial_map(p_case_slug text)
RETURNS text LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_lines text;
BEGIN
    SELECT string_agg(
             format(E'- **%s** — the letter claims (citing [%s%s]): "%s"%s',
                    CASE WHEN c.verified THEN 'VERIFIED' ELSE 'MISMATCH' END,
                    cd.slug,
                    coalesce('#' || c.cited_section_ref, ''),
                    c.claim_quote,
                    coalesce(E'\n  - the cited section actually reads:\n\n'
                             || regexp_replace(btrim(ds.body), '^', '    > ', 'ng'),
                             '')),
             E'\n' ORDER BY c.verified, c.id)   -- mismatches first (false < true)
      INTO v_lines
      FROM stewards.case_citations c
      JOIN stewards.docs cd ON cd.id = c.cited_doc_id
      LEFT JOIN stewards.doc_sections ds
             ON ds.doc_id = c.cited_doc_id AND ds.section_ref = c.cited_section_ref
     WHERE c.case_slug = p_case_slug;

    RETURN format(E'## Denial map — claimed citations vs. the exact cited language\n\n%s',
                  coalesce(v_lines, '_no citations checked for this case_'));
END $func$;
COMMENT ON FUNCTION stewards.render_denial_map(text) IS
'case-file digester: deterministic markdown of ALL case_citations rows (mismatches first) with the cited section''s ACTUAL text blockquoted verbatim from doc_sections — the "exact policy language" export, server-side. SELECT + format only.';

-- ── case_assemble: build the case-file DRAFT, entirely server-side ──────
-- The model calls this ONCE with no args; the body is composed here from
-- the renders. It lands as a doc-construction draft (doc_drafts) so the
-- letter stage can doc_append_section the one generative section and then
-- case_file_publish pulls it server-side — the model never re-emits the
-- document.
CREATE OR REPLACE FUNCTION stewards.case_assemble_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE
    -- _session_id is injected by the tool dispatcher for pipeline stages.
    -- 'session' is the manual/demo fallback: draft session scoping is a
    -- convenience, not the security boundary (the handle is the
    -- capability — v08's own ruling), so the deterministic demo may
    -- drive the same real path from psql.
    v_sess   text := coalesce(nullif(p_args->>'_session_id', ''), nullif(p_args->>'session', ''));
    v_slug   text := nullif(btrim(coalesce(p_args->>'case_slug', '')), '');
    v_case   stewards.case_shelf%ROWTYPE;
    v_body   text;
    v_handle text;
BEGIN
    IF v_sess IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no session context');
    END IF;
    IF v_slug IS NULL THEN
        SELECT * INTO v_case FROM stewards.case_shelf WHERE status = 'building'
         ORDER BY added_at LIMIT 1;
    ELSE
        SELECT * INTO v_case FROM stewards.case_shelf WHERE slug = v_slug;
    END IF;
    IF v_case.slug IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
            'no case is currently building (case_next first, or pass case_slug)');
    END IF;

    v_body :=
        '# Case file: ' || v_case.title || E'\n\n' ||
        '_Assembled ' || to_char(now(), 'YYYY-MM-DD') || ' by the case-file digester. '
        'Every section below except the draft letter is rendered server-side from typed rows '
        '(doc_facts / evidence_items / case_citations) — the model composed none of it. '
        'Nothing has been sent, and no send capability exists: this document is for human review._'
        || E'\n\n' ||
        stewards.render_case_sources(v_case.slug)                          || E'\n\n' ||
        stewards.render_case_findings(v_case.slug)                         || E'\n\n' ||
        stewards.render_fact_timeline('project', v_case.project)           || E'\n\n' ||
        stewards.render_denial_map(v_case.slug)                            || E'\n\n' ||
        stewards.render_evidence_checklist('project', v_case.project);

    INSERT INTO stewards.doc_drafts (session_id, title, project, body)
    VALUES (v_sess, 'Case file: ' || v_case.title, v_case.project, v_body)
    RETURNING handle INTO v_handle;

    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'case_slug', v_case.slug,
        'chars', length(v_body),
        'note', 'case-file draft assembled server-side. The letter stage appends ONE section '
                '("Draft appeal letter") with doc_append_section, then case_file_publish pools it.');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END $func$;
COMMENT ON FUNCTION stewards.case_assemble_tool(jsonb) IS
'case-file digester: assemble the case-file DRAFT entirely server-side (sources + findings + fact timeline + denial map w/ exact cited language + evidence checklist) into doc_drafts. The model''s only job afterward is the draft letter section. Never raises.';

-- ── case_file_publish: pool the finished case file (mirrors book_publish_draft)
CREATE OR REPLACE FUNCTION stewards.case_file_publish_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE
    v_sess   text := coalesce(nullif(p_args->>'_session_id', ''), nullif(p_args->>'session', ''));
    v_handle text := lower(btrim(coalesce(p_args->>'handle', '')));
    v_case   stewards.case_shelf%ROWTYPE;
    v_body   text;
    v_doc    text;
    v_slug   text;
BEGIN
    IF v_sess IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no session context');
    END IF;
    SELECT * INTO v_case FROM stewards.case_shelf WHERE status = 'building'
     ORDER BY added_at LIMIT 1;
    IF v_case.slug IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no case is currently building');
    END IF;

    IF v_handle = '' THEN
        SELECT handle INTO v_handle FROM stewards.doc_drafts
         WHERE stewards.doc_draft_session_match(session_id, v_sess)
         ORDER BY updated_at DESC LIMIT 1;
        IF v_handle IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'error',
                'no draft for this run — case_assemble first');
        END IF;
    END IF;
    SELECT body INTO v_body FROM stewards.doc_drafts
     WHERE handle = v_handle AND stewards.doc_draft_session_match(session_id, v_sess);
    IF v_body IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('no draft %s for this run — case_assemble first', v_handle));
    END IF;

    v_slug := 'case-file-' || v_case.slug;
    v_doc  := stewards.import_doc(
        v_slug,
        'cases/' || v_case.slug || '.md',
        'Case file: ' || v_case.title,
        v_body,
        jsonb_build_object('source_type', 'case-file', 'case_slug', v_case.slug,
                           'project', v_case.project, 'built_by', 'case-file-digester'),
        'case-file');
    UPDATE stewards.docs
       SET source_type = 'case-file', project_association = v_case.project
     WHERE id = v_doc;

    -- Queue the file write too (materializes to disk only if the operator
    -- has the materializer on /workspace RW; otherwise waits harmlessly —
    -- the doc is always in the DB, and the knowledge projection tree
    -- (kind=case-file, see the config append below) carries it regardless).
    INSERT INTO stewards.pending_file_writes
        (requested_by, target_path, write_mode, content, source_id, source_kind)
    VALUES ('case_file_publish', 'cases/' || v_case.slug || '.md', 'create',
            v_body, v_doc, 'case-file');

    UPDATE stewards.case_shelf SET status = 'done', done_at = now() WHERE slug = v_case.slug;
    DELETE FROM stewards.doc_drafts WHERE handle = v_handle;

    RETURN jsonb_build_object('ok', true, 'doc_id', v_doc, 'doc_slug', v_slug,
        'case', v_case.slug, 'path', 'cases/' || v_case.slug || '.md',
        'note', 'case file pooled and the case marked done. NOTHING WAS SENT — the case file is for '
                'human review. Your reply now is a short JOURNAL of what you did — do NOT paste the document.');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END $func$;
COMMENT ON FUNCTION stewards.case_file_publish_tool(jsonb) IS
'case-file digester: publish the assembled draft as the pooled case file (kind=case-file, slug case-file-<case>), queue the cases/<slug>.md file write, mark the case done, clear the draft. Body is pulled server-side by handle — the model never re-emits it. Never raises.';

-- ── tool defs (examples own their seeds) ────────────────────────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
( 'case_next',
  'Claim the next case to build from the case shelf (resumes the in-progress one, else the next queued). Returns {slug, title, project, docs:[{slug,title}...]} — the case''s dropped documents — or {case: null} if the shelf is empty. Call this FIRST in every case-file stage.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"case_next_tool"}'::jsonb, 'read', true ),
( 'case_add',
  'Queue a case on the case shelf. slug (required) should match the drop folder the case''s documents were dropped under (it becomes the docs project tag unless you pass project explicitly); title (required) is the human name.',
  '{"type":"object","required":["slug","title"],"properties":{"slug":{"type":"string"},"title":{"type":"string"},"project":{"type":"string","description":"docs project_association tag (defaults to slug)"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"case_add_tool"}'::jsonb, 'write_local', true ),
( 'case_normalize_floor',
  'Run the deterministic spine for a case in ONE call, server-side, zero models: split every case doc into addressable sections (doc_split_sections) and extract the typed fact floor (parse_facts_deterministic — dates, $-amounts) into doc_facts with section anchors. Idempotent. Returns {docs, sections, facts} counts. An LLM stage REFINES this floor (doc_fact_add) — it never replaces it.',
  '{"type":"object","required":["case_slug"],"properties":{"case_slug":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"case_normalize_floor_tool"}'::jsonb, 'write_local', true ),
( 'case_citation_record',
  'Record one citation_check verdict in the case''s citation ledger — copy the tool''s output FAITHFULLY (a mismatch is finding #1, the most valuable thing this pipeline produces; never soften one). Args: claim_quote + cited_doc + verified required; cited_section_ref, source_doc, nearest_excerpt, overlap_chars, note optional; case_slug defaults to the building case.',
  '{"type":"object","required":["claim_quote","cited_doc","verified"],"properties":{'
    '"case_slug":{"type":"string"},'
    '"claim_quote":{"type":"string","description":"the text the citing doc attributes to the cited one"},'
    '"cited_doc":{"type":"string","description":"the CITED doc id or slug"},'
    '"cited_section_ref":{"type":"string","description":"the section address checked (from citation_check found_at, or the heading you scoped to)"},'
    '"source_doc":{"type":"string","description":"the CITING doc id or slug (e.g. the denial letter)"},'
    '"verified":{"type":"boolean","description":"citation_check''s verdict, copied faithfully"},'
    '"nearest_excerpt":{"type":"string","description":"on mismatch: the tool''s verbatim nearest-region excerpt"},'
    '"overlap_chars":{"type":"integer","description":"on mismatch: the tool''s longest-common-substring character count"},'
    '"note":{"type":"string"}'
  '}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"case_citation_record"}'::jsonb, 'write_local', true ),
( 'case_assemble',
  'Assemble the case file as a document draft, ENTIRELY server-side: sources, findings (mismatches first), fact timeline, denial map with the exact cited language, and evidence checklist — all rendered from typed rows; you compose nothing. Call ONCE with no args (the building case is used). Returns the draft handle for the letter stage.',
  '{"type":"object","properties":{"case_slug":{"type":"string","description":"optional; defaults to the building case"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"case_assemble_tool"}'::jsonb, 'write_local', true ),
( 'case_file_publish',
  'Publish the case file you finished (assembled sections + your draft letter). Pass the draft handle (or omit it to use this run''s active draft) — NOT the body; it is pulled server-side. Pools the doc (kind=case-file), queues the cases/<slug>.md write, marks the case done. NOTHING IS SENT. Call this LAST, once.',
  '{"type":"object","properties":{"handle":{"type":"string","description":"the draft handle from case_assemble (optional; defaults to this run''s active draft)"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"case_file_publish_tool"}'::jsonb, 'write_local', true ),
-- citation_check is the Go sanity oracle (cmd/stewards-mcp/citation_check.go),
-- reached through the pg-ai-stewards self-surface via the bridge proxy —
-- the same path spawn_subagent/expand_message use. After first import, run
-- `stewards-mcp bridge refresh-tools` so the tool cache learns it.
( 'citation_check',
  'Verify a CLAIMED quote against the cited doc/section''s ACTUAL text — the text-vs-text citation sanity check. Args: quote + doc (id or slug), optionally section_ref (e.g. s1.3) or heading (substring, e.g. "4.2(b)"). Exact after whitespace/case/typographic-punctuation normalization; no fuzzy scores. Returns {verified, found_at} or the honest nearest region (nearest_section_ref, verbatim nearest_excerpt, overlap_chars). A MISMATCH is a finding — record it with case_citation_record.',
  '{"type":"object","required":["quote","doc"],"properties":{'
    '"quote":{"type":"string","description":"the claimed quote to verify"},'
    '"doc":{"type":"string","description":"the CITED doc id or slug"},'
    '"section_ref":{"type":"string","description":"optional exact section address (doc_split_sections)"},'
    '"heading":{"type":"string","description":"optional heading substring to scope to (alternative to section_ref)"}'
  '}}'::jsonb,
  '{"kind":"mcp_proxy","server":"pg-ai-stewards","tool":"citation_check"}'::jsonb, 'read', true )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, effect_class = EXCLUDED.effect_class, active = true;

-- ── tool groups + grants (deny-by-default posture, v26/v29 pattern) ─────
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('case-file-tools',
   'the case-file digester surface: shelf cursor (case_next/case_add), the deterministic spine (case_normalize_floor), the citation sanity pair (citation_check + case_citation_record), and server-side assembly (case_assemble)',
   ARRAY['case_next','case_add','case_normalize_floor','citation_check','case_citation_record','case_assemble']),
  ('case-finalize',
   'the one finalize tool for the case-file publishing stage',
   ARRAY['case_file_publish'])
ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description, tool_patterns = EXCLUDED.tool_patterns;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research', 'case_next',             'allow', 'manual'),
    ('research', 'case_add',              'allow', 'manual'),
    ('research', 'case_normalize_floor',  'allow', 'manual'),
    ('research', 'case_citation_record',  'allow', 'manual'),
    ('research', 'case_assemble',         'allow', 'manual'),
    ('research', 'case_file_publish',     'allow', 'manual'),
    ('research', 'citation_check',        'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET
    action = EXCLUDED.action, source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- project the case files into the knowledge tree: append kind=case-file to
-- the projection catalog's kind list (dedup — re-import safe; preserves any
-- operator-customized list rather than clobbering it).
SELECT stewards.config_set('knowledge_projection.doc_kinds',
    (SELECT jsonb_agg(DISTINCT k) FROM (
        SELECT jsonb_array_elements_text(
                 coalesce(stewards.config_get('knowledge_projection.doc_kinds'),
                          '["doc","study"]'::jsonb)) AS k
        UNION SELECT 'case-file') s),
    'doc kinds the knowledge projection tree materializes (case-file appended by examples/case-file-digester.sql)');

-- ── the case-file pipeline ──────────────────────────────────────────────
-- sections (deterministic spine, one tool call) -> normalize (LLM refines
-- the floor: deadline promotion, parties, evidence expectations) -> sanity
-- (citation_check every claimed citation; record verdicts) -> assemble
-- (server-side render into a draft, one tool call) -> letter (the ONE
-- generative section + publish). Stages name ROLES (ingest/reason/critic);
-- the alias router picks the member. No send stage exists.
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder,
    auto_materialize_on_verified, metadata
) VALUES (
    'case-file',
    'Drop a folder of paperwork in, get an inspectable case file out: sections (deterministic: split + typed fact floor, one tool call) -> normalize (LLM refines: deadline promotion, parties, evidence expectations) -> sanity (citation_check: does the cited section say what the letter claims? mismatch = finding #1) -> assemble (server-side renders into a draft — the model composes nothing) -> letter (the ONE generative section, anchor-cited, then publish). Ends at the assembled case file + draft; no send capability exists. Uses the research agent.',
    jsonb_build_array(
        -- SECTIONS: the deterministic spine. The model drives ONE server-side
        -- call and reports counts; it extracts nothing itself.
        jsonb_build_object('name','sections','next','normalize',
            'model','ingest','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            'tool_groups', jsonb_build_array('case-file-tools'),
            'input_template',
              'You are the SECTIONS stage of the case-file digester — the deterministic spine. You compose nothing and extract nothing yourself.' || E'\n\n' ||
              '1. Call `case_next` to get your assigned case ({slug, title, project, docs}). If it returns case:null, reply EXACTLY "SHELF EMPTY" and stop.' || E'\n' ||
              '2. Call `case_normalize_floor` with {"case_slug": <slug>} — ONE call. Server-side it splits every case document into addressable sections and extracts the deterministic typed-fact floor (dates, $-amounts). Zero models are involved in that work.' || E'\n' ||
              '3. Output EXACTLY these four lines and NOTHING ELSE:' || E'\n' ||
              '   CASE_SLUG: <the slug>' || E'\n' ||
              '   PROJECT: <the project>' || E'\n' ||
              '   DOCS: <docs count from case_normalize_floor>' || E'\n' ||
              '   FLOOR: <sections> sections, <facts> facts' ),
        -- NORMALIZE: the LLM refines the floor — it never replaces it.
        jsonb_build_object('name','normalize','next','sanity',
            'model','reason','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            'input_template',
              'You are the NORMALIZE stage of the case-file digester. The deterministic floor already ran; you REFINE it — you never replace it, and you never re-type what it already captured.' || E'\n\n' ||
              'The sections stage reported:' || E'\n\n' ||
              '{{stage_results.sections.output}}' || E'\n\n' ||
              'Steps:' || E'\n' ||
              '1. Call `case_next` (it resumes the in-progress case) to get the case''s document list.' || E'\n' ||
              '2. For each document: `doc_get` it (read the ACTUAL text) and `doc_facts_list` it (see what the floor extracted).' || E'\n' ||
              '3. Refine with `doc_fact_add` — judgment the floor cannot make:' || E'\n' ||
              '   - Promote the appeal DEADLINE: find the floor''s date fact whose surrounding sentence names a deadline, and add fact_kind=deadline with value_date, raw_text = the VERBATIM sentence span, and its section_ref.' || E'\n' ||
              '   - Parties (fact_kind=party) and claim/policy identifiers (fact_kind=identifier), each with the verbatim raw_text span.' || E'\n' ||
              '   - Never invent a fact. raw_text must be copied character-for-character from the document.' || E'\n' ||
              '4. Record the evidence checklist with `evidence_set` (scope_kind=project, scope_id=<project>): every item the case EXPECTS — including what the denial letter itself says would change the outcome (e.g. a physician letter). Mark items you can see in the pack as status=have (+ satisfied_by_doc_slug); mark what is absent as status=missing. Missing documents are first-class: recording the gap IS the work.' || E'\n' ||
              '5. Reply with a short JOURNAL (2-4 sentences): what you promoted, what evidence is missing. Do NOT paste facts or documents.' ),
        -- SANITY: the citation check — does the cited text say what the
        -- citing document claims it says? Mismatch = finding #1.
        jsonb_build_object('name','sanity','next','assemble',
            'model','critic','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            'tool_groups', jsonb_build_array('case-file-tools','substrate-read'),
            'input_template',
              'You are the SANITY stage of the case-file digester — the citation check. The question: does the cited document actually say what the citing document claims it says?' || E'\n\n' ||
              '1. Call `case_next` to get the case and its documents.' || E'\n' ||
              '2. `doc_get` the CITING document(s) — typically the denial letter. Find every place it quotes or characterizes another case document ("Per Policy Section 4.2(b), ...").' || E'\n' ||
              '3. For EACH claimed citation, call `citation_check` with {quote: the claimed text, doc: the cited doc''s slug, heading: the cited section name (e.g. "4.2(b)")}. The tool is deterministic — exact match after normalization, honest nearest-region on failure.' || E'\n' ||
              '4. Record EVERY verdict with `case_citation_record`, copying the tool''s output FAITHFULLY: verified as returned, cited_section_ref (from found_at.section_ref or the section you scoped to), nearest_excerpt / overlap_chars / note on a mismatch, source_doc = the citing doc. Do NOT soften a mismatch — a mismatch is finding #1, the most valuable thing this pipeline produces.' || E'\n' ||
              '5. Reply with EXACTLY one line: "MISMATCH: <n>" (n = number of verified=false verdicts) or "CLEAN".' ),
        -- ASSEMBLE: deterministic. One tool call; the server renders the
        -- case file from typed rows. The model composes NOTHING here.
        jsonb_build_object('name','assemble','next','letter',
            'model','ingest','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            'tool_groups', jsonb_build_array('case-file-tools'),
            'input_template',
              'You are the ASSEMBLE stage of the case-file digester — deterministic.' || E'\n\n' ||
              'Make ONE tool call: `case_assemble` (no args). Server-side it builds the case-file draft from the typed rows — sources, findings (mismatches first), fact timeline, denial map with the exact cited language, evidence checklist. You compose NOTHING; the facts render from the database so they cannot drift.' || E'\n\n' ||
              'Reply with EXACTLY one line: "ASSEMBLED <handle>" using the handle the tool returns (or the tool''s error verbatim if it fails).' ),
        -- LETTER: the ONE generative section, anchor-cited, then publish.
        -- Scoped to doc-edit + the one finalize tool (the book-digest 37
        -- pattern) so the model cannot wander.
        jsonb_build_object('name','letter','next',NULL,
            'model','reason','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            'tool_groups', jsonb_build_array('doc-edit','case-finalize'),
            'input_template',
              'You are the LETTER stage of the case-file digester — the ONE generative section of the case file. Everything else was rendered server-side from typed rows.' || E'\n\n' ||
              'The assemble stage reported: {{stage_results.assemble.output}}' || E'\n\n' ||
              'Steps:' || E'\n' ||
              '1. Call `doc_current` to get the assembled draft handle, then `doc_read` it once. Every fact you may use is already in it, with [doc-slug#section-ref] anchors.' || E'\n' ||
              '2. `doc_append_section` ONE section, heading "Draft appeal letter": a firm, courteous draft appeal. Every factual claim in the letter must cite its anchor exactly as it appears in the sections above ([doc#ref]). If the Findings section shows a MISMATCH, that mismatch is the letter''s core argument. Do not invent dates, amounts, or policy language: if it is not in the draft above, it does not go in the letter.' || E'\n' ||
              '3. The letter is a DRAFT for human review. Nothing is sent by this pipeline and no send capability exists — do not write send instructions or fabricate a sent status.' || E'\n' ||
              '4. Call `case_file_publish` (omit the handle to use this run''s draft). It pools the case file and marks the case done.' || E'\n' ||
              '5. Reply with a short JOURNAL (2-3 sentences): the case, whether findings drove the letter, and that you published. Do NOT paste the document.' )
    ),
    false, false,
    NULL, NULL,
    '["raw","verified"]'::jsonb,
    false,  -- case_file_publish persists directly (no file auto-materialize)
    -- doc-construction posture: the publish tool pools the canonical doc;
    -- the letter stage's chat reply is a journal — don't auto-pool it.
    -- halt_on: an empty shelf cancels at the sections stage (the generic
    -- core mechanism the book digester proved out).
    jsonb_build_object('pools_via_tool', true,
                       'halt_on', jsonb_build_object('stage', 'sections',
                                                     'outputs', jsonb_build_array('SHELF EMPTY')))
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    maturity_ladder = EXCLUDED.maturity_ladder,
    metadata = stewards.pipelines.metadata || EXCLUDED.metadata,
    updated_at = now();

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('case-file','sections',  'ingest', 'Deterministic spine: case_next + case_normalize_floor (one server-side call); tools on. Cheapest capable alias.'),
    ('case-file','normalize', 'reason', 'Refine the typed-fact floor: deadline promotion, parties, evidence expectations; tools on.'),
    ('case-file','sanity',    'critic', 'citation_check every claimed citation + record verdicts faithfully; tools on.'),
    ('case-file','assemble',  'ingest', 'Deterministic: ONE case_assemble call (server-side renders); tools on. Cheapest capable alias.'),
    ('case-file','letter',    'reason', 'The one generative section (anchor-cited draft letter) + case_file_publish; tools scoped to doc-edit + case-finalize.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity) VALUES
    ('case-file','letter','verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

-- ── the case-file intent (the core ships no intents; seed our own) ──────
INSERT INTO stewards.intents (slug, purpose, beneficiary, values_hierarchy, values_anchor)
VALUES (
    'case-file',
    'Turn a dropped folder of delicate paperwork into an inspectable, citation-anchored case file a human can act on — typed facts, surfaced gaps, checked citations, and a draft the human reviews. Never send anything.',
    'the operator and the person whose paperwork it is',
    jsonb_build_array(
        jsonb_build_object('key','facts-are-queries','description','Dates, amounts, deadlines, and policy language are rendered from typed rows, never re-typed by a model. A fact that cannot show its verbatim source span does not ship.'),
        jsonb_build_object('key','gaps-are-first-class','description','A missing document is a row, not a footnote. The checklist leads with what is absent.'),
        jsonb_build_object('key','check-the-citation','description','When one document claims another says something, verify it against the actual text. A mismatch is finding #1, not an embarrassment to smooth over.'),
        jsonb_build_object('key','the-human-sends','description','The pipeline ends at a reviewable case file and draft. No send capability exists anywhere in it.')
    ),
    'Build the case file the way a careful paralegal would: every fact traceable, every gap named, every citation checked, and the decision left with the human.'
)
ON CONFLICT (slug) DO NOTHING;

-- No schedule is seeded: cases are dispatched per document pack, not on a
-- cron. Start one manually after dropping the pack + case_add:
--   SELECT stewards.work_item_create('case-file',
--            jsonb_build_object('assignment','Build the case file for the next case on the shelf.'),
--            NULL, 'human', NULL,
--            (SELECT id FROM stewards.intents WHERE slug='case-file'));
-- (or via the Stewdio /new page). An operator who wants drop-to-run
-- automation can add a scheduled_pipelines row gated on a queued shelf —
-- the book digester shows the shape.
