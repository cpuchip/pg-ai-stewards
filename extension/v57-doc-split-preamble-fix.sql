-- ---------------------------------------------------------------------
-- v57 — doc_split_sections: the preamble ('s0') branch, fixed.
--
-- FOUND by threadchip (chillacks #908) on a clean-v55 bench with four
-- controls; ROOT-CAUSED by basecamp, repro'd rollback-wrapped on live v55.
--
-- The defect, one line — v29-normalize.sql:248:
--
--     v_refs := v_refs || 's0';        -- v_refs is text[]
--
-- The literal is UNTYPED, so Postgres has two candidate operators for
-- `text[] || unknown`: anyarray||anyelement and anyarray||anyarray. It
-- resolves the ARRAY form and tries to cast 's0' ITSELF to text[], which
-- raises `malformed array literal: "s0"`. The headed loop (line 266)
-- appends v_ref, a declared `text` variable, so the type is known there
-- and that branch always worked.
--
-- What it cost: EVERY doc with content before its first heading, and
-- EVERY plain .txt (which has no headings at all, so the whole body is
-- the preamble), failed to split — since v29, across 28 volumes. And it
-- failed QUIETLY: doc_split_sections carries a deliberate never-raise
-- handler, so the caller got {"ok":false,"error":…} instead of an error,
-- the plpgsql exception block rolled its subtransaction back, and the doc
-- was left sitting in the pool with ZERO addressable sections. Measured
-- on the red bench before this fix:
--
--     file_drop_ingest('probe/preamble.md', …)  -> {"ok": true,  …}
--     doc_split_sections(<that doc>)            -> {"ok": false,
--                                     "error": "malformed array literal: \"s0\""}
--     sections written                          -> 0
--     doc still present                         -> 1
--
-- It went unseen because the OK 109 smoke fixture opens with a heading,
-- leaving `s0` — a section the v29 documentation explicitly promises
-- (see doc_sections' own COMMENT: "''s0'' preamble") — with zero test
-- coverage. tests/virgin-smoke.sql OK 125 is that coverage, and it is RED
-- on v56 with exactly the error above.
--
-- The fix is the type annotation and nothing else: the body below is
-- v29's verbatim, one line changed. No behavior is added — this restores
-- the contract v29 already documented.
-- ---------------------------------------------------------------------

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
        -- v57: ::text is load-bearing. Untyped, `text[] || 's0'` resolves
        -- as array||array and casts the literal to text[] -> malformed
        -- array literal. Do not remove the annotation.
        v_refs := v_refs || 's0'::text;
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
'v29 §2, repaired in v57: deterministic structural sections of a doc, on demand (no trigger), rebuilt wholesale (delete+rebuild, idempotent). section_ref is the citable address — ''s0'' is the preamble before the first heading (and, for a doc with no headings at all, the whole body); ''s1''/''s3.2'' are the hierarchical heading addresses. [char_start, char_end) is the 0-based raw span over docs.body including the heading line. v57 fixes the untyped ''s0'' array append that made every preamble-bearing doc and every plain .txt fail closed, quietly, from v29 onward (found by threadchip, chillacks #908).';
