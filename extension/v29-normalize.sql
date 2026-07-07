-- =====================================================================
-- v29-normalize.sql — the NORMALIZE primitive: typed facts, evidence
--   checklists, a deterministic parser floor, structural sections —
--   plus the file-drop honesty patch (a failure must have a face).
-- =====================================================================
-- Mandated by the 2026-07-07 pipelines-skeleton panel
-- (.spec/wargames/2026-07-07-pipelines-skeleton/): all three seats
-- converged on NORMALIZE as the one missing primitive of the nine —
-- "dates become dates, amounts become amounts, missing documents become
-- missing documents" — no typed extraction and no first-class
-- missing-document object anywhere in 28 volumes (MAPPER primitive #4,
-- SKEPTIC attack #2, DEMO-PATH gaps G1/G2). And SKEPTIC attack #1,
-- sustained: a binary drop on a stock install dead-ends into a
-- file_drops status='error' row that no surface shows. The synthesis
-- named the systemic rule this file starts enforcing: "no failure
-- without a face."
--
-- WHAT SHIPS HERE:
--   §1  file-drop error alarm — every file_drops row still in
--       status='error' at COMMIT rings the attention bell (a deduped
--       hinge row, kind=file-drop-error, one open face per path).
--   §2  stewards.doc_sections + doc_split_sections — deterministic,
--       ON-DEMAND markdown-heading splitter: stable addressable refs
--       ('s0' preamble, 's1', 's3.2') for retrieve-by-section and
--       cite-by-address.
--   §3  stewards.doc_facts — the typed-fact table. fact_kind is CHECKed,
--       and the typed value column MATCHING the kind is CHECK-enforced
--       non-null (date/deadline -> value_date, amount -> value_numeric).
--       raw_text (the verbatim source span) is always required — a fact
--       that can't show its span is a guess in a costume.
--   §4  stewards.evidence_items — missing-documents-as-first-class: an
--       expected item is a row whose status is have | missing | n/a,
--       queryable without an LLM re-reading anything.
--   §5  parse_facts_deterministic — the plpgsql regex floor: common
--       date formats + $-amounts, zero model calls. PRECISION OVER
--       RECALL by design: it extracts only spans it can type with near
--       certainty, and an LLM stage REFINES this floor (adds kinds like
--       deadline/party, catches formats the regexes skip) — it never
--       replaces it. A floor the adjudicator can trust beats a net that
--       catches everything including garbage.
--   §6  tool surface — doc_fact_add / doc_facts_list / evidence_set /
--       evidence_checklist / doc_split_sections, the jsonb-in/jsonb-out
--       never-RAISE convention (94/100), deny-by-default grants like
--       the v26 observation tools.
--   §7  server-side renders — render_fact_timeline and
--       render_evidence_checklist return markdown straight from the
--       typed rows (SELECT + format only, no model in the path). The
--       case-file wave pastes these verbatim; a model cannot drift from
--       the DB even on a bad day.
--
-- THE CHUNKING TRADE — A NARROW EXCEPTION, NOT A REVERSAL. The ratified
-- ES.3 council (2026-05-15; lineage in v04-context-engine.sql's header)
-- deliberately DROPPED the leaf-chunk-and-embed corpus (l14…l17) once
-- the judge-compiled-brief replaced it. That ruling was made over prose
-- corpora — research PDFs, transcripts, wiki prose — where structural
-- boundaries carry little meaning and engram extraction wins. The
-- paperwork workload (retrieve-by-section, cite-by-address: "Policy
-- Section 4.2(b)", "the Appeal rights section") was not in view, and it
-- is the one workload where structure IS the address. §2 is scoped to
-- exactly that gap: deterministic heading ADDRESSING for
-- document-shaped sources — no embedding, no model, no per-chunk docs
-- pool rows, no retrieval machinery replaced — and it runs ON-DEMAND
-- only (a plain function call by the pipelines/ingest paths that want
-- it), never as a trigger taxing every doc write. The engram path is
-- untouched. This is the exception the 2026-05-15 decision anticipated,
-- carved as narrowly as we know how.
--
-- LIFELESS-CORE COMPLIANCE (v27): nothing in this file names a model or
-- a provider. The parser floor, the splitter, the renders, and the
-- alarm are deterministic SQL end to end. The tools are surfaces an LLM
-- stage MAY drive; nothing here requires one.
--
-- HONEST LIMITATIONS, named up front (v20/v28's discipline):
--   * parse_facts_deterministic covers ISO dates, US m/d/y (US reading
--     of slash dates is assumed and documented), full/abbreviated
--     English month names, and $-prefixed amounts (USD). No relative
--     dates ("within 180 days"), no bare numbers, no €/£ — the LLM
--     refinement stage owns those. Precision over recall, on purpose.
--   * doc_split_sections reads ATX headings ('#'…'######' at line
--     start) and skips fenced blocks (``` / ~~~ toggle). Setext
--     headings (=== underlines) and indented-heading edge cases are not
--     parsed — named, not hidden.
--   * doc_facts.section_ref is a SOFT reference (no FK): sections are
--     delete+rebuilt by design, and a fact must survive its section
--     being renumbered by a re-split. A dangling section_ref degrades
--     to "no anchor," never to a lost fact (raw_text still binds it).
--   * evidence_items.scope_id is text across three id spaces (docs.id,
--     work_items uuid, project name) — same shape needs_attention
--     already uses for its mixed id spaces. Doc scopes are canonicalized
--     to docs.id at write time; a deleted work_item leaves its checklist
--     rows behind (they describe the expectation, not the worker).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — the file-drop error alarm: a failure must have a face.
-- ---------------------------------------------------------------------
-- Why a DEFERRED CONSTRAINT trigger and not a plain AFTER trigger:
-- file_drop_ingest / _binary write the ledger row provenance-FIRST with
-- status='error' ("ingest did not complete") and flip it to 'ingested'
-- in the SAME transaction — the transient error state is the crash
-- insurance, not a failure. A plain row trigger would ring the bell on
-- every successful drop. Deferring to COMMIT and re-reading the row
-- means only a drop that ENDS its transaction in error gets a face —
-- which is exactly the honest boundary.
--
-- Dedup follows the 106 schedule-staleness idiom (one OPEN alarm per
-- subject), keyed on payload->>'path' rather than the subject string
-- because the subject carries the error text (the mandated face:
-- "file drop failed: <path> — <error>") while the dedup key must be
-- stable across different errors on the same path. status IN
-- ('pending','escalated') mirrors the needs_attention view's own
-- definition of "still open" so an escalated face is never doubled.
CREATE OR REPLACE FUNCTION stewards.file_drop_error_alarm()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_row stewards.file_drops%ROWTYPE;
BEGIN
    -- Deferred to COMMIT: re-read the row's FINAL state. Vanished (test
    -- fixtures, pruning) or no longer error (the transient
    -- provenance-first state) -> no face needed.
    SELECT * INTO v_row FROM stewards.file_drops WHERE id = NEW.id;
    IF v_row.id IS NULL OR v_row.status <> 'error' THEN
        RETURN NULL;
    END IF;

    IF EXISTS (SELECT 1 FROM stewards.hinge_reviews h
                WHERE h.kind = 'file-drop-error'
                  AND h.payload->>'path' = v_row.path
                  AND h.status IN ('pending','escalated')) THEN
        RETURN NULL;                     -- one open face per path
    END IF;

    PERFORM stewards.hinge_enqueue(
        'file-drop-error',
        format('file drop failed: %s — %s',
               v_row.path, coalesce(left(v_row.error, 200), '(no detail)')),
        jsonb_strip_nulls(jsonb_build_object(
            'drop_id',       v_row.id,
            'path',          v_row.path,
            'sha256',        v_row.sha256,
            'project_hint',  v_row.project_hint,
            'error',         v_row.error,
            'routed_to',     v_row.routed_to,
            'attachment_id', v_row.attachment_id)),
        'file_drop_error_alarm');
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    -- The face must never break the drop: this fires inside the
    -- ingest's own COMMIT, so an alarm failure is a WARNING, not an
    -- aborted ingest (#330 per-row discipline).
    RAISE WARNING 'file_drop_error_alarm: % (file_drops id %)', SQLERRM, NEW.id;
    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION stewards.file_drop_error_alarm() IS
'v29 §1: constraint-trigger body (INITIALLY DEFERRED — fires at COMMIT). A file_drops row whose FINAL state is status=error enqueues a hinge row (kind=file-drop-error, subject "file drop failed: <path> — <error>") surfacing in needs_attention. Deduped per path (payload->>''path'', one open face while pending/escalated — the 106 idiom). Re-reads the row at commit so the ingest functions'' transient provenance-first error state never rings. Never raises out (a broken bell must not abort the ingest).';

DROP TRIGGER IF EXISTS file_drops_error_alarm ON stewards.file_drops;
CREATE CONSTRAINT TRIGGER file_drops_error_alarm
    AFTER INSERT OR UPDATE OF status, error ON stewards.file_drops
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (NEW.status = 'error')
    EXECUTE FUNCTION stewards.file_drop_error_alarm();

-- ---------------------------------------------------------------------
-- §2 — structural sections: stable addresses into a document.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.doc_sections (
    doc_id      text NOT NULL REFERENCES stewards.docs(id) ON DELETE CASCADE,
    section_ref text NOT NULL,      -- 's0' preamble | 's1' | 's3.2' (hierarchical, stable per split)
    heading     text,               -- NULL for the preamble
    level       int  NOT NULL,      -- 0 = preamble, 1..6 = ATX heading depth
    body        text NOT NULL DEFAULT '',   -- section text AFTER the heading line, up to the next heading
    char_start  int  NOT NULL,      -- 0-based offset of the section span's start (heading line incl.)
    char_end    int  NOT NULL,      -- 0-based exclusive end: [char_start, char_end) over docs.body
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (doc_id, section_ref)
);

COMMENT ON TABLE stewards.doc_sections IS
'v29 §2: deterministic structural sections of a doc — the narrow, on-demand exception to the 2026-05-15 chunking trade (see the file header; addressing for document-shaped sources, NOT a return of leaf-chunk-and-embed). Rebuilt wholesale by doc_split_sections (delete+rebuild, idempotent). section_ref is the citable address (''s0'' preamble, ''s1'', ''s3.2''); [char_start, char_end) is the 0-based raw span over docs.body including the heading line; body is the text after the heading line.';
COMMENT ON COLUMN stewards.doc_sections.section_ref IS
'v29: hierarchical address by heading order — ''s0'' = preamble before the first heading; a level-1 heading increments the first counter (''s1'', ''s2''…); a level-2 under it appends (''s2.1''). A doc that opens at level 2 with no level-1 parent yields ''s0.1'' (distinct from the ''s0'' preamble). Stable for a given body; a re-split after edits MAY renumber — which is why doc_facts.section_ref is soft.';

-- doc_split_sections — the deterministic splitter. ON-DEMAND ONLY, by
-- decision: no trigger. Splitting every doc on every write would tax
-- the whole pool for a structure only paperwork-shaped pipelines ask
-- for; the callers that want addresses (an ingest path, a normalize
-- stage) call this once per doc revision. Idempotent: delete+rebuild.
CREATE OR REPLACE FUNCTION stewards.doc_split_sections(p_doc_id text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_body     text;
    v_lines    text[];
    v_line     text;
    v_offset   int := 0;                      -- 0-based offset of current line start
    v_total    int;
    v_in_fence boolean := false;
    v_m        text[];
    -- collected headings
    h_level    int[]  := ARRAY[]::int[];
    h_text     text[] := ARRAY[]::text[];
    h_start    int[]  := ARRAY[]::int[];      -- heading line start (0-based)
    h_bodyat   int[]  := ARRAY[]::int[];      -- first offset AFTER the heading line
    -- ref counters
    v_counters int[]  := ARRAY[0,0,0,0,0,0];
    v_refs     text[] := ARRAY[]::text[];
    v_ref      text;
    v_span_end int;
    v_n        int := 0;
    i          int;
    j          int;
BEGIN
    SELECT d.body INTO v_body FROM stewards.docs d WHERE d.id = p_doc_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no doc with id %s', p_doc_id));
    END IF;

    DELETE FROM stewards.doc_sections WHERE doc_id = p_doc_id;

    v_total := length(coalesce(v_body, ''));
    v_lines := string_to_array(coalesce(v_body, ''), E'\n');

    -- walk the lines: fence-aware ATX heading scan, raw offsets kept
    FOR i IN 1 .. coalesce(array_length(v_lines, 1), 0) LOOP
        v_line := regexp_replace(v_lines[i], E'\r$', '');
        IF v_line ~ '^\s*(```|~~~)' THEN
            v_in_fence := NOT v_in_fence;
        ELSIF NOT v_in_fence THEN
            v_m := regexp_match(v_line, '^(#{1,6})\s+(.+?)\s*$');
            IF v_m IS NOT NULL THEN
                h_level  := h_level  || length(v_m[1]);
                h_text   := h_text   || v_m[2];
                h_start  := h_start  || v_offset;
                h_bodyat := h_bodyat || least(v_offset + length(v_lines[i]) + 1, v_total);
            END IF;
        END IF;
        v_offset := v_offset + length(v_lines[i]) + 1;   -- +1 for the split '\n'
    END LOOP;

    -- preamble (or the whole body when no headings): 's0'
    v_span_end := CASE WHEN coalesce(array_length(h_start, 1), 0) > 0 THEN h_start[1] ELSE v_total END;
    IF btrim(substring(v_body FROM 1 FOR v_span_end)) <> '' THEN
        INSERT INTO stewards.doc_sections (doc_id, section_ref, heading, level, body, char_start, char_end)
        VALUES (p_doc_id, 's0', NULL, 0, substring(v_body FROM 1 FOR v_span_end), 0, v_span_end);
        v_refs := v_refs || 's0';
        v_n := v_n + 1;
    END IF;

    -- headed sections: span = [own heading start, next heading start)
    FOR i IN 1 .. coalesce(array_length(h_start, 1), 0) LOOP
        v_counters[h_level[i]] := v_counters[h_level[i]] + 1;
        FOR j IN h_level[i] + 1 .. 6 LOOP
            v_counters[j] := 0;
        END LOOP;
        v_ref := 's' || array_to_string(v_counters[1:h_level[i]], '.');

        v_span_end := CASE WHEN i < array_length(h_start, 1) THEN h_start[i + 1] ELSE v_total END;

        INSERT INTO stewards.doc_sections (doc_id, section_ref, heading, level, body, char_start, char_end)
        VALUES (p_doc_id, v_ref, h_text[i], h_level[i],
                substring(v_body FROM h_bodyat[i] + 1 FOR v_span_end - h_bodyat[i]),
                h_start[i], v_span_end);
        v_refs := v_refs || v_ref;
        v_n := v_n + 1;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'doc_id', p_doc_id, 'sections', v_n,
                              'refs', to_jsonb(v_refs));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;

COMMENT ON FUNCTION stewards.doc_split_sections(text) IS
'v29 §2: deterministic markdown-heading splitter — rebuilds stewards.doc_sections for one doc (delete+rebuild, idempotent; ON-DEMAND by decision, never a trigger — see table comment). ATX headings only (#…######), fenced blocks (```/~~~) skipped, preamble before the first heading = ''s0''. Returns {"ok",doc_id,sections,refs}. Never raises.';

-- ---------------------------------------------------------------------
-- §3 — doc_facts: typed facts with the verbatim span attached.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.doc_facts (
    id             bigserial PRIMARY KEY,
    doc_id         text NOT NULL REFERENCES stewards.docs(id) ON DELETE CASCADE,
    section_ref    text,               -- SOFT ref into doc_sections (no FK — sections rebuild)
    fact_kind      text NOT NULL
                   CONSTRAINT doc_facts_kind_check
                   CHECK (fact_kind IN ('date','amount','deadline','party','identifier','other')),
    raw_text       text NOT NULL,      -- the VERBATIM source span this fact was read from
    value_date     date,
    value_numeric  numeric,
    value_currency text,
    value_text     text,
    confidence     real
                   CONSTRAINT doc_facts_confidence_check
                   CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    extracted_by   text,               -- 'parse_facts_deterministic' | a pipeline stage name | …
    created_at     timestamptz NOT NULL DEFAULT now(),
    -- The normalize contract: the typed column matching the kind is
    -- NOT NULL, enforced by Postgres, not by prompt discipline. A
    -- "deadline" without a date is not a fact — it is prose.
    CONSTRAINT doc_facts_typed_value_check CHECK (
        CASE fact_kind
            WHEN 'date'     THEN value_date    IS NOT NULL
            WHEN 'deadline' THEN value_date    IS NOT NULL
            WHEN 'amount'   THEN value_numeric IS NOT NULL
            ELSE true
        END)
);

CREATE INDEX IF NOT EXISTS doc_facts_doc_idx  ON stewards.doc_facts (doc_id);
CREATE INDEX IF NOT EXISTS doc_facts_kind_idx ON stewards.doc_facts (fact_kind);
CREATE INDEX IF NOT EXISTS doc_facts_date_idx ON stewards.doc_facts (value_date)
    WHERE value_date IS NOT NULL;

COMMENT ON TABLE stewards.doc_facts IS
'v29 §3: the NORMALIZE primitive — one typed fact extracted from a doc. raw_text is the verbatim source span (always required: every fact can show its receipt). The typed value column matching fact_kind is CHECK-enforced non-null (date/deadline -> value_date, amount -> value_numeric); party/identifier/other carry value_text as optional normalization over raw_text. section_ref soft-points at doc_sections for cite-by-address. confidence in [0,1]; extracted_by names the extractor (the deterministic parser or a pipeline stage).';
COMMENT ON COLUMN stewards.doc_facts.section_ref IS
'v29: SOFT reference to doc_sections.section_ref (no FK — sections are delete+rebuilt and may renumber). A dangling ref degrades to "no anchor"; raw_text still binds the fact to its source.';

-- ---------------------------------------------------------------------
-- §4 — evidence_items: missing documents as first-class rows.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.evidence_items (
    id                  bigserial PRIMARY KEY,
    scope_kind          text NOT NULL
                        CONSTRAINT evidence_items_scope_kind_check
                        CHECK (scope_kind IN ('doc','project','work_item')),
    scope_id            text NOT NULL,     -- docs.id | work_items.id::text | project name
    item                text NOT NULL,     -- what is EXPECTED ('physician letter of medical necessity')
    status              text NOT NULL DEFAULT 'missing'
                        CONSTRAINT evidence_items_status_check
                        CHECK (status IN ('have','missing','n/a')),
    satisfied_by_doc_id text REFERENCES stewards.docs(id) ON DELETE SET NULL,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (scope_kind, scope_id, item)
);

COMMENT ON TABLE stewards.evidence_items IS
'v29 §4: the evidence checklist — an EXPECTED document/item per scope (doc | project | work_item), status have | missing | n/a. Missing documents are first-class, queryable rows ("what''s still missing?" is a WHERE clause, not an LLM re-read). satisfied_by_doc_id points at the pooled doc that satisfied the expectation (SET NULL if that doc is later deleted — the expectation outlives its satisfier). One row per (scope, item); evidence_set upserts.';

-- ---------------------------------------------------------------------
-- §5 — the deterministic parser floor.
-- ---------------------------------------------------------------------
-- _try_date: to_date with the failure swallowed. Postgres validates
-- ranges (2026-13-40 errors) — an invalid match is silently dropped,
-- which IS the precision-over-recall contract.
CREATE OR REPLACE FUNCTION stewards._try_date(p_raw text, p_fmt text)
RETURNS date LANGUAGE plpgsql STABLE AS $fn$
BEGIN
    RETURN to_date(p_raw, p_fmt);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$fn$;
COMMENT ON FUNCTION stewards._try_date(text, text) IS
'v29 §5: private helper — to_date or NULL (never raises). The parser floor drops what it cannot validate rather than guessing.';

-- parse_facts_deterministic — the cheap floor an LLM stage refines,
-- never replaces. PRECISION OVER RECALL: only spans typable with near
-- certainty are returned, so the adjudicating stage can trust every row
-- it gets and spend its judgment on what the floor could not see.
-- Coverage (documented, deliberately narrow):
--   dates   — ISO (2026-07-15); US slash m/d/yyyy (US reading assumed);
--             English month names, full or abbreviated, optional
--             ordinal suffix ("July 15, 2026", "Sep 5 2026", "Jan. 2, 2027")
--   amounts — $-prefixed: $500, $1,234.56, $1000000.5 (currency USD)
-- All extracted dates land as fact_kind='date' — promoting a date to
-- 'deadline' requires reading the sentence around it, which is judgment,
-- i.e. the refining stage's job, not the floor's.
CREATE OR REPLACE FUNCTION stewards.parse_facts_deterministic(p_text text)
RETURNS TABLE (
    fact_kind      text,
    raw_text       text,
    value_date     date,
    value_numeric  numeric,
    value_currency text
) LANGUAGE sql STABLE AS $fn$
    -- pass 1: ISO dates
    SELECT 'date'::text, m[1],
           stewards._try_date(m[1], 'YYYY-MM-DD'),
           NULL::numeric, NULL::text
      FROM regexp_matches(coalesce(p_text, ''), '\y(\d{4}-\d{2}-\d{2})\y', 'g') AS m
     WHERE stewards._try_date(m[1], 'YYYY-MM-DD') IS NOT NULL

    UNION ALL
    -- pass 2: US slash dates (m/d/yyyy — the US reading is assumed and documented)
    SELECT 'date', m[1],
           stewards._try_date(m[1], 'MM/DD/YYYY'),
           NULL, NULL
      FROM regexp_matches(coalesce(p_text, ''), '\y(\d{1,2}/\d{1,2}/\d{4})\y', 'g') AS m
     WHERE stewards._try_date(m[1], 'MM/DD/YYYY') IS NOT NULL

    UNION ALL
    -- pass 3: English month-name dates ("July 15, 2026", "Sep 5 2026")
    SELECT 'date', m[1],
           stewards._try_date(left(initcap(m[2]), 3) || ' ' || m[3] || ' ' || m[4], 'Mon DD YYYY'),
           NULL, NULL
      FROM regexp_matches(coalesce(p_text, ''),
               '\y((January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)\.?[ ]+(\d{1,2})(?:st|nd|rd|th)?,?[ ]+(\d{4}))\y', 'gi') AS m
     WHERE stewards._try_date(left(initcap(m[2]), 3) || ' ' || m[3] || ' ' || m[4], 'Mon DD YYYY') IS NOT NULL

    UNION ALL
    -- pass 4: $-amounts (USD)
    SELECT 'amount', m[1], NULL,
           replace(regexp_replace(m[1], '^\$', ''), ',', '')::numeric,
           'USD'
      FROM regexp_matches(coalesce(p_text, ''),
               '(\$(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?)\y', 'g') AS m;
$fn$;

COMMENT ON FUNCTION stewards.parse_facts_deterministic(text) IS
'v29 §5: the deterministic parser floor — regex extraction of common dates (ISO; US m/d/yyyy; English month names) and $-amounts (USD) with the verbatim matched span as raw_text. PRECISION OVER RECALL by design: it returns only what it can type with near certainty (invalid calendar dates are dropped, not guessed), and an LLM stage REFINES it (deadline/party/identifier kinds, formats outside coverage) — it never replaces it. All dates emit as fact_kind=''date''; deadline promotion is a judgment call and therefore the refining stage''s. Zero model calls. Rows are ordered by pass (ISO, slash, month-name, amount), then match order.';

-- ---------------------------------------------------------------------
-- §6 — the tool surface (94/100 convention: never RAISE; *_tool wrappers
--       are what tool_defs.execute_target points at).
-- ---------------------------------------------------------------------
-- _doc_id_resolve: accept a docs.id or a docs.slug, return the id.
CREATE OR REPLACE FUNCTION stewards._doc_id_resolve(p_ref text)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT d.id FROM stewards.docs d
     WHERE d.id = p_ref OR d.slug = p_ref
     LIMIT 1;
$fn$;
COMMENT ON FUNCTION stewards._doc_id_resolve(text) IS
'v29 §6: private helper — resolve a docs.id OR slug to the id (NULL if neither matches). The tools take doc/doc_id/doc_slug interchangeably, same server-side-resolution posture as the lore tools'' world_slug convention.';

-- _scope_canon: canonicalize (scope_kind, scope_id) so writers and
-- readers land on the same key. doc -> docs.id (id-or-slug resolved);
-- work_item / project -> trimmed as given. NULL = unresolvable doc.
CREATE OR REPLACE FUNCTION stewards._scope_canon(p_scope_kind text, p_scope_id text)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT CASE
        WHEN p_scope_kind = 'doc' THEN stewards._doc_id_resolve(btrim(coalesce(p_scope_id, '')))
        ELSE nullif(btrim(coalesce(p_scope_id, '')), '')
    END;
$fn$;
COMMENT ON FUNCTION stewards._scope_canon(text, text) IS
'v29 §6: private helper — canonical scope_id for evidence/renders (doc scopes resolve id-or-slug to docs.id so evidence_set and the renders always meet on the same key; project/work_item pass through trimmed).';

-- ── doc_fact_add ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.doc_fact_add(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_doc_ref   text := coalesce(nullif(btrim(coalesce(p_args->>'doc_id', '')), ''),
                                 nullif(btrim(coalesce(p_args->>'doc_slug', '')), ''),
                                 nullif(btrim(coalesce(p_args->>'doc', '')), ''));
    v_doc_id    text;
    v_kind      text := btrim(coalesce(p_args->>'fact_kind', ''));
    v_raw       text := btrim(coalesce(p_args->>'raw_text', ''));
    v_section   text := nullif(btrim(coalesce(p_args->>'section_ref', '')), '');
    v_date      date;
    v_numeric   numeric;
    v_currency  text := nullif(btrim(coalesce(p_args->>'value_currency', '')), '');
    v_text      text := nullif(btrim(coalesce(p_args->>'value_text', '')), '');
    v_conf      real;
    v_by        text := nullif(btrim(coalesce(p_args->>'extracted_by', '')), '');
    v_row       stewards.doc_facts%ROWTYPE;
BEGIN
    IF v_doc_ref IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'doc_id or doc_slug is required');
    END IF;
    v_doc_id := stewards._doc_id_resolve(v_doc_ref);
    IF v_doc_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no doc with id or slug "%s"', v_doc_ref));
    END IF;
    IF v_kind NOT IN ('date','amount','deadline','party','identifier','other') THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('fact_kind must be one of date, amount, deadline, party, identifier, other (got %L)', p_args->>'fact_kind'));
    END IF;
    IF v_raw = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'raw_text (the verbatim source span) is required');
    END IF;

    IF (p_args ? 'value_date') AND jsonb_typeof(p_args->'value_date') <> 'null' THEN
        BEGIN
            v_date := (p_args->>'value_date')::date;
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('ok', false, 'error',
                format('value_date must be a date (got %L)', p_args->>'value_date'));
        END;
    END IF;
    IF (p_args ? 'value_numeric') AND jsonb_typeof(p_args->'value_numeric') <> 'null' THEN
        BEGIN
            v_numeric := (p_args->>'value_numeric')::numeric;
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('ok', false, 'error',
                format('value_numeric must be numeric (got %L)', p_args->>'value_numeric'));
        END;
    END IF;
    IF (p_args ? 'confidence') AND jsonb_typeof(p_args->'confidence') <> 'null' THEN
        BEGIN
            v_conf := (p_args->>'confidence')::real;
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('ok', false, 'error', 'confidence must be a number in [0,1]');
        END;
        IF v_conf < 0 OR v_conf > 1 THEN
            RETURN jsonb_build_object('ok', false, 'error', 'confidence must be in [0,1]');
        END IF;
    END IF;

    -- friendly pre-check of the typed-value constraint (the table CHECK
    -- is the enforcement; this is the readable error)
    IF v_kind IN ('date','deadline') AND v_date IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('fact_kind %s requires value_date — a %s without a typed date is prose, not a fact', v_kind, v_kind));
    END IF;
    IF v_kind = 'amount' AND v_numeric IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
            'fact_kind amount requires value_numeric — an amount without a typed number is prose, not a fact');
    END IF;

    INSERT INTO stewards.doc_facts
        (doc_id, section_ref, fact_kind, raw_text, value_date, value_numeric,
         value_currency, value_text, confidence, extracted_by)
    VALUES
        (v_doc_id, v_section, v_kind, v_raw, v_date, v_numeric,
         v_currency, v_text, v_conf, v_by)
    RETURNING * INTO v_row;

    RETURN jsonb_build_object('ok', true, 'id', v_row.id, 'fact',
        jsonb_strip_nulls(jsonb_build_object(
            'id', v_row.id, 'doc_id', v_row.doc_id, 'section_ref', v_row.section_ref,
            'fact_kind', v_row.fact_kind, 'raw_text', v_row.raw_text,
            'value_date', v_row.value_date, 'value_numeric', v_row.value_numeric,
            'value_currency', v_row.value_currency, 'value_text', v_row.value_text,
            'confidence', v_row.confidence, 'extracted_by', v_row.extracted_by,
            'created_at', v_row.created_at)));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_fact_add(jsonb) IS
'v29 §6: validate + insert one typed fact. Args: doc_id|doc_slug|doc (resolved server-side), fact_kind, raw_text (required — the verbatim span); section_ref (soft), value_date, value_numeric, value_currency, value_text, confidence [0,1], extracted_by. Enforces the typed-value contract with a readable error before the table CHECK does it with a hard one. Never raises.';

CREATE OR REPLACE FUNCTION stewards.doc_fact_add_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN stewards.doc_fact_add(p_args);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- ── doc_facts_list ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.doc_facts_list(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_doc_ref text := coalesce(nullif(btrim(coalesce(p_args->>'doc_id', '')), ''),
                               nullif(btrim(coalesce(p_args->>'doc_slug', '')), ''),
                               nullif(btrim(coalesce(p_args->>'doc', '')), ''));
    v_doc_id  text;
    v_kind    text := nullif(btrim(coalesce(p_args->>'fact_kind', '')), '');
    v_section text := nullif(btrim(coalesce(p_args->>'section_ref', '')), '');
    v_limit   int  := least(greatest(coalesce((p_args->>'limit')::int, 50), 1), 200);
    v_out     jsonb;
BEGIN
    IF v_doc_ref IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'doc_id or doc_slug is required');
    END IF;
    v_doc_id := stewards._doc_id_resolve(v_doc_ref);
    IF v_doc_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no doc with id or slug "%s"', v_doc_ref));
    END IF;
    IF v_kind IS NOT NULL AND v_kind NOT IN ('date','amount','deadline','party','identifier','other') THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('fact_kind must be one of date, amount, deadline, party, identifier, other (got %L)', v_kind));
    END IF;

    SELECT coalesce(jsonb_agg(f ORDER BY (f->>'id')::bigint), '[]'::jsonb) INTO v_out
      FROM (
        SELECT jsonb_strip_nulls(jsonb_build_object(
                 'id', df.id, 'doc_id', df.doc_id, 'section_ref', df.section_ref,
                 'fact_kind', df.fact_kind, 'raw_text', df.raw_text,
                 'value_date', df.value_date, 'value_numeric', df.value_numeric,
                 'value_currency', df.value_currency, 'value_text', df.value_text,
                 'confidence', df.confidence, 'extracted_by', df.extracted_by,
                 'created_at', df.created_at)) AS f
          FROM stewards.doc_facts df
         WHERE df.doc_id = v_doc_id
           AND (v_kind IS NULL OR df.fact_kind = v_kind)
           AND (v_section IS NULL OR df.section_ref = v_section)
         ORDER BY df.id
         LIMIT v_limit
      ) s;

    RETURN jsonb_build_object('ok', true, 'count', jsonb_array_length(v_out), 'facts', v_out);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.doc_facts_list(jsonb) IS
'v29 §6: list typed facts for one doc. Args: doc_id|doc_slug (required), fact_kind, section_ref, limit (default 50, cap 200). Never raises.';

CREATE OR REPLACE FUNCTION stewards.doc_facts_list_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $FN$
BEGIN
    RETURN stewards.doc_facts_list(p_args);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- ── evidence_set ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.evidence_set(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_scope_kind text := btrim(coalesce(p_args->>'scope_kind', ''));
    v_scope_raw  text := btrim(coalesce(p_args->>'scope_id', ''));
    v_scope_id   text;
    v_item       text := btrim(coalesce(p_args->>'item', ''));
    v_status     text := nullif(btrim(coalesce(p_args->>'status', '')), '');
    v_sat_ref    text := coalesce(nullif(btrim(coalesce(p_args->>'satisfied_by_doc_id', '')), ''),
                                  nullif(btrim(coalesce(p_args->>'satisfied_by_doc_slug', '')), ''),
                                  nullif(btrim(coalesce(p_args->>'satisfied_by', '')), ''));
    v_sat_id     text;
    v_notes      text := nullif(btrim(coalesce(p_args->>'notes', '')), '');
    v_row        stewards.evidence_items%ROWTYPE;
BEGIN
    IF v_scope_kind NOT IN ('doc','project','work_item') THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('scope_kind must be one of doc, project, work_item (got %L)', p_args->>'scope_kind'));
    END IF;
    v_scope_id := stewards._scope_canon(v_scope_kind, v_scope_raw);
    IF v_scope_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
            CASE WHEN v_scope_kind = 'doc'
                 THEN format('no doc with id or slug "%s"', v_scope_raw)
                 ELSE 'scope_id is required' END);
    END IF;
    IF v_item = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'item (what is expected) is required');
    END IF;
    IF v_status IS NOT NULL AND v_status NOT IN ('have','missing','n/a') THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('status must be one of have, missing, n/a (got %L)', v_status));
    END IF;
    IF v_sat_ref IS NOT NULL THEN
        v_sat_id := stewards._doc_id_resolve(v_sat_ref);
        IF v_sat_id IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'error',
                format('satisfied_by: no doc with id or slug "%s"', v_sat_ref));
        END IF;
    END IF;

    -- upsert: an expectation is one row per (scope, item). Absent args
    -- preserve the existing values (status defaults to 'missing' only
    -- for a NEW expectation — an expectation is born as a gap).
    SELECT * INTO v_row FROM stewards.evidence_items e
     WHERE e.scope_kind = v_scope_kind AND e.scope_id = v_scope_id AND e.item = v_item;

    IF FOUND THEN
        UPDATE stewards.evidence_items e
           SET status              = coalesce(v_status, e.status),
               satisfied_by_doc_id = coalesce(v_sat_id, e.satisfied_by_doc_id),
               notes               = coalesce(v_notes, e.notes),
               updated_at          = now()
         WHERE e.id = v_row.id
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO stewards.evidence_items
            (scope_kind, scope_id, item, status, satisfied_by_doc_id, notes)
        VALUES
            (v_scope_kind, v_scope_id, v_item, coalesce(v_status, 'missing'), v_sat_id, v_notes)
        RETURNING * INTO v_row;
    END IF;

    RETURN jsonb_build_object('ok', true, 'id', v_row.id, 'evidence',
        jsonb_strip_nulls(jsonb_build_object(
            'id', v_row.id, 'scope_kind', v_row.scope_kind, 'scope_id', v_row.scope_id,
            'item', v_row.item, 'status', v_row.status,
            'satisfied_by_doc_id', v_row.satisfied_by_doc_id, 'notes', v_row.notes,
            'updated_at', v_row.updated_at)));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.evidence_set(jsonb) IS
'v29 §6: upsert one evidence expectation. Args: scope_kind (doc|project|work_item), scope_id (doc scopes accept id or slug, canonicalized to docs.id), item (required); status (have|missing|n/a — a NEW expectation defaults to missing: it is born as a gap), satisfied_by_doc_id|_slug, notes. Absent args preserve existing values on update. Never raises.';

CREATE OR REPLACE FUNCTION stewards.evidence_set_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN stewards.evidence_set(p_args);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- ── evidence_checklist (tool: rows + counts + the §7 render) ─────────
CREATE OR REPLACE FUNCTION stewards.evidence_checklist(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_scope_kind text := btrim(coalesce(p_args->>'scope_kind', ''));
    v_scope_raw  text := btrim(coalesce(p_args->>'scope_id', ''));
    v_scope_id   text;
    v_items      jsonb;
    v_counts     jsonb;
BEGIN
    IF v_scope_kind NOT IN ('doc','project','work_item') THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('scope_kind must be one of doc, project, work_item (got %L)', p_args->>'scope_kind'));
    END IF;
    v_scope_id := stewards._scope_canon(v_scope_kind, v_scope_raw);
    IF v_scope_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
            CASE WHEN v_scope_kind = 'doc'
                 THEN format('no doc with id or slug "%s"', v_scope_raw)
                 ELSE 'scope_id is required' END);
    END IF;

    SELECT coalesce(jsonb_agg(i.row_out ORDER BY i.ord, i.item), '[]'::jsonb) INTO v_items
      FROM (
        SELECT e.item,
               CASE e.status WHEN 'missing' THEN 0 WHEN 'have' THEN 1 ELSE 2 END AS ord,
               jsonb_strip_nulls(jsonb_build_object(
                   'id', e.id, 'item', e.item, 'status', e.status,
                   'satisfied_by_doc_id', e.satisfied_by_doc_id,
                   'satisfied_by_doc_slug', d.slug,
                   'notes', e.notes, 'updated_at', e.updated_at)) AS row_out
          FROM stewards.evidence_items e
          LEFT JOIN stewards.docs d ON d.id = e.satisfied_by_doc_id
         WHERE e.scope_kind = v_scope_kind AND e.scope_id = v_scope_id
      ) i;

    SELECT jsonb_build_object(
             'have',    count(*) FILTER (WHERE e.status = 'have'),
             'missing', count(*) FILTER (WHERE e.status = 'missing'),
             'n/a',     count(*) FILTER (WHERE e.status = 'n/a'))
      INTO v_counts
      FROM stewards.evidence_items e
     WHERE e.scope_kind = v_scope_kind AND e.scope_id = v_scope_id;

    RETURN jsonb_build_object(
        'ok', true, 'scope_kind', v_scope_kind, 'scope_id', v_scope_id,
        'counts', v_counts, 'items', v_items,
        'markdown', stewards.render_evidence_checklist(v_scope_kind, v_scope_id));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.evidence_checklist(jsonb) IS
'v29 §6: the checklist for one scope — structured rows (missing first, then have, then n/a), counts, AND the §7 server-rendered markdown. Args: scope_kind + scope_id (doc scopes accept id or slug). Never raises.';

CREATE OR REPLACE FUNCTION stewards.evidence_checklist_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $FN$
BEGIN
    RETURN stewards.evidence_checklist(p_args);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- ── doc_split_sections_tool ──────────────────────────────────────────
-- Registered as a tool (beyond the mandated four) for one load-bearing
-- reason, named rather than silently done: "on-demand, called by the
-- pipelines/ingest paths that want it" is only TRUE if a pipeline stage
-- can actually reach it, and stages reach functions through tool_defs.
CREATE OR REPLACE FUNCTION stewards.doc_split_sections_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_doc_ref text := coalesce(nullif(btrim(coalesce(p_args->>'doc_id', '')), ''),
                               nullif(btrim(coalesce(p_args->>'doc_slug', '')), ''),
                               nullif(btrim(coalesce(p_args->>'doc', '')), ''));
    v_doc_id  text;
BEGIN
    IF v_doc_ref IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'doc_id or doc_slug is required');
    END IF;
    v_doc_id := stewards._doc_id_resolve(v_doc_ref);
    IF v_doc_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no doc with id or slug "%s"', v_doc_ref));
    END IF;
    RETURN stewards.doc_split_sections(v_doc_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- ---------------------------------------------------------------------
-- §7 — server-side renders: markdown from typed rows, no model in the
--       path. The case-file wave pastes these verbatim (facts are
--       queries, not compositions); these are the generic halves.
-- ---------------------------------------------------------------------
-- _scope_doc_ids: the docs a (scope_kind, scope_id) reaches.
CREATE OR REPLACE FUNCTION stewards._scope_doc_ids(p_scope_kind text, p_scope_id text)
RETURNS SETOF text LANGUAGE sql STABLE AS $fn$
    SELECT d.id FROM stewards.docs d
     WHERE (p_scope_kind = 'doc'       AND d.id = stewards._doc_id_resolve(p_scope_id))
        OR (p_scope_kind = 'project'   AND d.project_association = p_scope_id)
        OR (p_scope_kind = 'work_item' AND d.work_item_id::text = p_scope_id);
$fn$;
COMMENT ON FUNCTION stewards._scope_doc_ids(text, text) IS
'v29 §7: private helper — the docs.id set a scope reaches (doc: that one doc, id-or-slug; project: docs.project_association; work_item: docs.work_item_id, compared as text so a malformed id yields empty, never an error).';

CREATE OR REPLACE FUNCTION stewards.render_fact_timeline(p_scope_kind text, p_scope_id text)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_lines text;
BEGIN
    IF coalesce(p_scope_kind, '') NOT IN ('doc','project','work_item') THEN
        RETURN '_render_fact_timeline: scope_kind must be one of doc, project, work_item_';
    END IF;

    SELECT string_agg(
             format('- **%s**%s — "%s" — [%s%s]',
                 to_char(df.value_date, 'YYYY-MM-DD'),
                 CASE WHEN df.fact_kind = 'deadline' THEN ' (DEADLINE)' ELSE '' END,
                 df.raw_text,
                 d.slug,
                 CASE WHEN df.section_ref IS NOT NULL THEN '#' || df.section_ref ELSE '' END),
             E'\n' ORDER BY df.value_date, df.fact_kind, df.id)
      INTO v_lines
      FROM stewards.doc_facts df
      JOIN stewards.docs d ON d.id = df.doc_id
     WHERE df.doc_id IN (SELECT stewards._scope_doc_ids(p_scope_kind, p_scope_id))
       AND df.fact_kind IN ('date','deadline');

    RETURN format(E'## Fact timeline — %s:%s\n\n%s',
                  p_scope_kind, coalesce(p_scope_id, ''),
                  coalesce(v_lines, '_no dated facts recorded for this scope_'));
END;
$fn$;
COMMENT ON FUNCTION stewards.render_fact_timeline(text, text) IS
'v29 §7: deterministic markdown timeline — facts of kind date/deadline in scope, chronological, each with its verbatim raw_text and a source anchor [doc-slug#section_ref]. SELECT + format only; a pipeline stage pastes this verbatim so the model cannot drift a date. Empty scope renders an honest "_no dated facts…_" line, never an error.';

CREATE OR REPLACE FUNCTION stewards.render_evidence_checklist(p_scope_kind text, p_scope_id text)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_scope_id text;
    v_lines    text;
    v_have     int;
    v_missing  int;
    v_na       int;
BEGIN
    IF coalesce(p_scope_kind, '') NOT IN ('doc','project','work_item') THEN
        RETURN '_render_evidence_checklist: scope_kind must be one of doc, project, work_item_';
    END IF;
    v_scope_id := stewards._scope_canon(p_scope_kind, p_scope_id);
    IF v_scope_id IS NULL THEN
        RETURN format(E'## Evidence checklist — %s:%s\n\n_unresolvable scope_',
                      p_scope_kind, coalesce(p_scope_id, ''));
    END IF;

    SELECT count(*) FILTER (WHERE e.status = 'have'),
           count(*) FILTER (WHERE e.status = 'missing'),
           count(*) FILTER (WHERE e.status = 'n/a')
      INTO v_have, v_missing, v_na
      FROM stewards.evidence_items e
     WHERE e.scope_kind = p_scope_kind AND e.scope_id = v_scope_id;

    SELECT string_agg(i.line, E'\n' ORDER BY i.ord, i.item) INTO v_lines
      FROM (
        SELECT e.item,
               CASE e.status WHEN 'missing' THEN 0 WHEN 'have' THEN 1 ELSE 2 END AS ord,
               CASE e.status
                   WHEN 'missing' THEN format('- [ ] **MISSING** — %s%s', e.item,
                        CASE WHEN e.notes IS NOT NULL THEN ' — ' || e.notes ELSE '' END)
                   WHEN 'have'    THEN format('- [x] %s%s%s', e.item,
                        CASE WHEN d.slug IS NOT NULL THEN format(' — satisfied by [%s]', d.slug) ELSE '' END,
                        CASE WHEN e.notes IS NOT NULL THEN ' — ' || e.notes ELSE '' END)
                   ELSE                format('- ~~%s~~ — n/a%s', e.item,
                        CASE WHEN e.notes IS NOT NULL THEN ' — ' || e.notes ELSE '' END)
               END AS line
          FROM stewards.evidence_items e
          LEFT JOIN stewards.docs d ON d.id = e.satisfied_by_doc_id
         WHERE e.scope_kind = p_scope_kind AND e.scope_id = v_scope_id
      ) i;

    RETURN format(E'## Evidence checklist — %s:%s\n\n%s have · %s missing · %s n/a\n\n%s',
                  p_scope_kind, v_scope_id, v_have, v_missing, v_na,
                  coalesce(v_lines, '_no evidence expectations recorded for this scope_'));
END;
$fn$;
COMMENT ON FUNCTION stewards.render_evidence_checklist(text, text) IS
'v29 §7: deterministic markdown checklist — missing items FIRST (the gap is the product), then have (with the satisfying doc''s slug), then n/a (struck through). Counts line up top. SELECT + format only; paste-safe (renders an honest one-liner for empty/unresolvable scopes, never errors).';

-- ---------------------------------------------------------------------
-- §8 — tool_defs + tool_groups + grants (the v26 observation-tools
--       pattern: explicit rows, deny-by-default posture).
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
('doc_fact_add',
 'Record one TYPED fact extracted from a doc — the normalize primitive. fact_kind: date | amount | deadline | party | identifier | other. raw_text (required) is the VERBATIM source span the fact was read from — every fact shows its receipt. The typed value matching the kind is enforced: date/deadline require value_date (a real date, not a string), amount requires value_numeric (+ optional value_currency). section_ref (optional) cites the doc_sections address the span lives in. Use parse_facts_deterministic''s output as the floor and add what it could not see.',
 '{"type":"object","required":["fact_kind","raw_text"],"properties":{'
   '"doc_id":{"type":"string","description":"the doc this fact was read from (or pass doc_slug)"},'
   '"doc_slug":{"type":"string","description":"alternative to doc_id"},'
   '"fact_kind":{"type":"string","enum":["date","amount","deadline","party","identifier","other"]},'
   '"raw_text":{"type":"string","description":"the verbatim source span (required)"},'
   '"section_ref":{"type":"string","description":"doc_sections address the span lives in (e.g. s2.1)"},'
   '"value_date":{"type":"string","description":"ISO date — required for fact_kind date/deadline"},'
   '"value_numeric":{"type":"number","description":"required for fact_kind amount"},'
   '"value_currency":{"type":"string","description":"e.g. USD"},'
   '"value_text":{"type":"string","description":"normalized text value (party/identifier/other)"},'
   '"confidence":{"type":"number","description":"0..1"},'
   '"extracted_by":{"type":"string","description":"who/what extracted this"}'
 '}}'::jsonb,
 '{"kind":"sql_fn","schema":"stewards","name":"doc_fact_add_tool"}'::jsonb, 'write_local', true),

('doc_facts_list',
 'List the typed facts recorded for one doc, optionally filtered by fact_kind or section_ref. Returns each fact with its verbatim raw_text span and typed values (value_date/value_numeric/value_text).',
 '{"type":"object","properties":{'
   '"doc_id":{"type":"string","description":"the doc (or pass doc_slug)"},'
   '"doc_slug":{"type":"string"},'
   '"fact_kind":{"type":"string","enum":["date","amount","deadline","party","identifier","other"]},'
   '"section_ref":{"type":"string"},'
   '"limit":{"type":"integer","description":"default 50, max 200"}'
 '}}'::jsonb,
 '{"kind":"sql_fn","schema":"stewards","name":"doc_facts_list_tool"}'::jsonb, 'read', true),

('evidence_set',
 'Record or update an EXPECTED evidence item for a scope — missing documents are first-class here. scope_kind: doc | project | work_item. status: have | missing | n/a (a new expectation defaults to missing — it is born as a gap). When a pooled doc satisfies the expectation, pass satisfied_by_doc_id (or _slug) and status=have. One row per (scope, item); calling again updates it.',
 '{"type":"object","required":["scope_kind","scope_id","item"],"properties":{'
   '"scope_kind":{"type":"string","enum":["doc","project","work_item"]},'
   '"scope_id":{"type":"string","description":"docs id/slug, work_item uuid, or project name"},'
   '"item":{"type":"string","description":"what is expected (e.g. physician letter of medical necessity)"},'
   '"status":{"type":"string","enum":["have","missing","n/a"]},'
   '"satisfied_by_doc_id":{"type":"string","description":"the pooled doc that satisfies this (or pass satisfied_by_doc_slug)"},'
   '"satisfied_by_doc_slug":{"type":"string"},'
   '"notes":{"type":"string"}'
 '}}'::jsonb,
 '{"kind":"sql_fn","schema":"stewards","name":"evidence_set_tool"}'::jsonb, 'write_local', true),

('evidence_checklist',
 'The evidence checklist for a scope: structured rows (missing first — the gap is the product), have/missing/n-a counts, and server-rendered markdown you can paste verbatim into a document. scope_kind: doc | project | work_item.',
 '{"type":"object","required":["scope_kind","scope_id"],"properties":{'
   '"scope_kind":{"type":"string","enum":["doc","project","work_item"]},'
   '"scope_id":{"type":"string","description":"docs id/slug, work_item uuid, or project name"}'
 '}}'::jsonb,
 '{"kind":"sql_fn","schema":"stewards","name":"evidence_checklist_tool"}'::jsonb, 'read', true),

('doc_split_sections',
 'Split one doc into deterministic, addressable structural sections (stewards.doc_sections) by its markdown headings — ''s0'' preamble, ''s1'', ''s3.2''. Idempotent (delete+rebuild for the doc). Run this before recording doc_facts with section_ref anchors, so facts can cite by address. Deterministic — no model involved.',
 '{"type":"object","properties":{'
   '"doc_id":{"type":"string","description":"the doc to split (or pass doc_slug)"},'
   '"doc_slug":{"type":"string"}'
 '}}'::jsonb,
 '{"kind":"sql_fn","schema":"stewards","name":"doc_split_sections_tool"}'::jsonb, 'write_local', true)

ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, effect_class = EXCLUDED.effect_class, active = true;

-- discoverability bundle (37-tool-groups' pattern, mirroring v26's
-- 'observation-tools').
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('normalize-tools',
   'the normalize primitive: typed facts with verbatim spans (doc_fact_add/doc_facts_list), evidence expectations with missing-as-first-class (evidence_set/evidence_checklist), and deterministic structural sectioning (doc_split_sections)',
   ARRAY['doc_fact_add','doc_facts_list','evidence_set','evidence_checklist','doc_split_sections'])
ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description, tool_patterns = EXCLUDED.tool_patterns;

-- grants: research + work-item-chat, the same two families v26 granted
-- its knowledge tools to (deny-by-default posture — named rows only).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('research',       'doc_fact_add',       'allow', 'manual'),
  ('research',       'doc_facts_list',     'allow', 'manual'),
  ('research',       'evidence_set',       'allow', 'manual'),
  ('research',       'evidence_checklist', 'allow', 'manual'),
  ('research',       'doc_split_sections', 'allow', 'manual'),
  ('work-item-chat', 'doc_fact_add',       'allow', 'manual'),
  ('work-item-chat', 'doc_facts_list',     'allow', 'manual'),
  ('work-item-chat', 'evidence_set',       'allow', 'manual'),
  ('work-item-chat', 'evidence_checklist', 'allow', 'manual'),
  ('work-item-chat', 'doc_split_sections', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- =====================================================================
-- End of v29-normalize.sql
-- =====================================================================
