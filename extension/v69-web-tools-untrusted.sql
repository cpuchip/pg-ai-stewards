-- =====================================================================
-- v69-web-tools-untrusted.sql: every fetch-md tool is a web tool.
--
-- stewards.is_web_tool (v04, batch L.8) names the tools whose results the
-- messages_wrap_untrusted_web_content trigger wraps in
-- [BEGIN/END UNTRUSTED EXTERNAL DATA] markers and scans for prompt-injection
-- patterns. It listed fetch_url and not the other three tools the fetch-md MCP
-- server exposes (fetch_urls, extract_links, fetch_url_raw), nor fetch_html, so
-- a page fetched through any of those reached the agent with no trust boundary
-- in any instance. Found 2026-10-16 by a real refresh-tools on an instance pinned
-- at c3890d3, whose local overlay carried this same change until it landed here.
--
-- The list is a denylist of tool NAMES, so a new fetching tool is unwrapped
-- until it is added here. That is the shape v04 chose; this migration only
-- completes the list for the server the house ships. A follow-up could key on
-- the MCP server instead of the tool name.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.is_web_tool(p_tool text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_tool IS NOT NULL AND lower(p_tool) IN (
        'web_search',
        'web_search_exa',
        'fetch_url',
        'fetch_urls',
        'extract_links',
        'fetch_url_raw',
        'fetch_html',
        'fetch_md',
        'scrape_url',
        'summarize_url',
        'deep_research'
    )
$$;

COMMENT ON FUNCTION stewards.is_web_tool(text) IS
'Batch L.8 (v69): the tools whose role=tool results are wrapped as untrusted external data by messages_wrap_untrusted_web_content. Every fetch-md tool is listed (fetch_url, fetch_urls, extract_links, fetch_url_raw, fetch_html) beside the search and summarize tools. A fetching tool not named here is NOT wrapped: add it here when it is added to the house.';

-- The check that would have caught v04's gap: every fetch-md tool is a web tool,
-- a non-web tool is not, and the case of the name does not matter.
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['fetch_url', 'fetch_urls', 'extract_links', 'fetch_url_raw', 'fetch_html', 'FETCH_URLS'] LOOP
        IF NOT stewards.is_web_tool(t) THEN
            RAISE EXCEPTION 'v69: is_web_tool(%) is false; a fetch-md tool would reach the agent unwrapped', t;
        END IF;
    END LOOP;
    IF stewards.is_web_tool('work_item_show') OR stewards.is_web_tool(NULL) THEN
        RAISE EXCEPTION 'v69: is_web_tool is true for a tool that is not a web tool';
    END IF;
END $$;
