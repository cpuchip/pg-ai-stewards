-- held-live-finals: the 3 gospel-overlay re-authors of core functions that run
-- on the LIVE DB but whose source exists nowhere else (cut-era apply; old repo
-- files retired). Captured 2026-07-04 via pg_get_functiondef as data-loss
-- insurance. D2A (#319) packages these properly as the stewards_workspace
-- extension; until then this file is the ONLY source of record.
-- parity-check.sh holds these as its allowlist.

-- ---- stewards.import_doc(text,text,text,text,jsonb,text) (live final) ----
CREATE OR REPLACE FUNCTION stewards.import_doc(p_slug text, p_file_path text, p_title text, p_body text, p_frontmatter jsonb DEFAULT '{}'::jsonb, p_kind text DEFAULT 'doc'::text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
    DECLARE
        v_id      text;
        v_node    uuid;
        v_link    record;
    BEGIN
        INSERT INTO stewards.docs (slug, file_path, title, body, frontmatter, kind)
        VALUES (p_slug, p_file_path, p_title, p_body, p_frontmatter, p_kind)
        ON CONFLICT (slug) DO UPDATE
            SET title       = EXCLUDED.title,
                file_path   = EXCLUDED.file_path,
                body        = EXCLUDED.body,
                frontmatter = EXCLUDED.frontmatter,
                kind        = EXCLUDED.kind
        RETURNING id INTO v_id;

        v_node := stewards.graph_node_upsert(
            'doc', p_slug, p_title,
            jsonb_build_object('id', v_id,
                               'file_path', p_file_path,
                               'doc_kind',  p_kind));

        -- Drop existing CITES edges so re-imports stay in sync with body.
        DELETE FROM stewards.edges
         WHERE src = v_node AND kind = 'CITES';

        -- For each unique cited URI, upsert the cited node + CITES edge.
        FOR v_link IN
            SELECT uri,
                   max(anchor_text) AS anchor_text,
                   max(kind)        AS kind,
                   count(*)::int    AS citation_count
              FROM stewards.parse_gospel_links(p_body)
             GROUP BY uri
        LOOP
            PERFORM stewards.graph_edge_upsert(
                'doc', p_slug,
                v_link.kind, v_link.uri,
                'CITES',
                v_link.citation_count::real,
                jsonb_build_object(
                    'anchor_text',    v_link.anchor_text,
                    'citation_count', v_link.citation_count,
                    'provenance',     'parsed',
                    'source',         'import_doc'));
        END LOOP;

        RETURN v_id;
    END;
    $function$

;

-- ---- stewards.doc_citations_resolved(text) (live final) ----
CREATE OR REPLACE FUNCTION stewards.doc_citations_resolved(p_slug text)
 RETURNS TABLE(cited_uri text, cited_kind text, anchor_text text, citation_count integer, resolved jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
    BEGIN
        RETURN QUERY
        WITH cites AS (
            SELECT * FROM stewards.doc_citations(p_slug)
        ),
        verses AS (
            SELECT c.cited_uri,
                   c.anchor_text,
                   pr.ref,
                   rr.content,
                   rr.error
              FROM cites c
              CROSS JOIN LATERAL stewards.parse_reference(c.anchor_text) AS pr(ref)
              LEFT JOIN stewards.resolved_refs rr ON rr.ref = pr.ref
        )
        SELECT
            c.cited_uri,
            c.cited_kind,
            c.anchor_text,
            c.citation_count,
            coalesce(
                (SELECT jsonb_agg(
                    jsonb_build_object(
                        'ref',     v.ref,
                        'content', v.content,
                        'error',   v.error
                    ) ORDER BY v.ref
                  )
                  FROM verses v
                 WHERE v.cited_uri = c.cited_uri
                   AND v.anchor_text = c.anchor_text),
                '[]'::jsonb
            ) AS resolved
          FROM cites c
         ORDER BY c.citation_count DESC, c.cited_uri ASC;
    END;
    $function$

;

-- ---- stewards.refresh_doc_refs(text) (live final) ----
CREATE OR REPLACE FUNCTION stewards.refresh_doc_refs(p_slug text)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
    DECLARE
        v_enqueued int := 0;
        v_link     record;
        v_ref      text;
        v_id       bigint;
    BEGIN
        FOR v_link IN
            SELECT cited_uri, anchor_text
              FROM stewards.doc_citations(p_slug)
        LOOP
            FOR v_ref IN
                SELECT * FROM stewards.parse_reference(v_link.anchor_text)
            LOOP
                v_id := stewards.enqueue_resolve(v_ref);
                IF v_id IS NOT NULL THEN
                    v_enqueued := v_enqueued + 1;
                END IF;
            END LOOP;
        END LOOP;
        RETURN v_enqueued;
    END;
    $function$

;
