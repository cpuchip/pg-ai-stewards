-- #327 fix: make research-summary's gather stage dual-purpose. Prepend a
-- targeted-read short-circuit so a binding question that names a specific doc
-- (slug/id/URL) reads THAT directly and skips the news scan (which was burning
-- paid web_search_exa calls + tool rounds + token bloat on local-read tasks).
UPDATE stewards.pipelines p SET stages = (
  SELECT jsonb_agg(
    CASE WHEN e->>'name' = 'gather'
         THEN jsonb_set(e, '{input_template}',
                to_jsonb(
                  E'TARGETED-READ CHECK — do this FIRST, before any search:\n'
                  || E'If the binding question names a SPECIFIC source — a doc slug (e.g. crawl-...), a doc id, a URL, or phrasing like "read the doc/paper with slug X" — then read THAT source directly (doc_get for a slug/id, fetch_url for a URL), base your entire output on it, and SKIP the news scan below. Do NOT call web_search_exa / news_search when you were handed a specific source; that wastes a paid call and floods context. The scan is only for open-ended "what is new about X" questions.\n\n---\n\n'
                  || (e->>'input_template')))
         ELSE e END ORDER BY ord)
  FROM jsonb_array_elements(p.stages) WITH ORDINALITY t(e, ord))
WHERE p.family = 'research-summary';
