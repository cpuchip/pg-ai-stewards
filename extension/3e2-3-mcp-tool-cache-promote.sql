-- =====================================================================
-- Phase 3e.2.d/e — auto-promote mcp_tool_cache rows into tool_defs +
-- per-agent grants for the bridged MCP tools.
--
-- 3e.2.b/c shipped 3 hand-curated tool_defs (gospel_search, gospel_get,
-- webster_define). This file makes that path generic: every active row
-- in stewards.mcp_tool_cache automatically becomes a stewards.tool_defs
-- row with execute_target='mcp_proxy', kept in sync by an AFTER trigger.
--
-- Naming: bare tool_name (e.g. 'gospel_search'), matching the
-- model-friendly convention OpenAI's tool spec requires (alphanumeric +
-- underscore + hyphen, no slashes). Cross-server collisions on
-- tool_name would silently overwrite via ON CONFLICT — none exist
-- today (verified 2026-05-08); future collisions become a real
-- correctness concern that 3e.2.f or later will address.
--
-- Per-agent grants: explicit (source='manual') so the importer's
-- DELETE-rebuild on frontmatter doesn't wipe them. Granting set was
-- chosen by Michael 2026-05-08:
--   study (all variants), lesson, talk → gospel_search, gospel_get, webster_define
--   journal, review                    → gospel_search
--   research                            → web_search_exa
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. promote_mcp_tool_cache_to_tool_defs — bulk sync function
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.promote_mcp_tool_cache_to_tool_defs()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    n_touched integer := 0;
    cache_row record;
BEGIN
    -- Upsert one tool_def per active cache row. Description prefixes
    -- the originating server so an agent reading its tools list sees
    -- "via gospel-engine-v2: ..." rather than just the raw tool blurb.
    -- The execute_target jsonb is the dispatch contract for
    -- exec_mcp_proxy_tool in tools.rs.
    FOR cache_row IN
        SELECT server_name, tool_name, description, title, input_schema, active
          FROM stewards.mcp_tool_cache
         WHERE active
    LOOP
        INSERT INTO stewards.tool_defs
            (name, description, args_schema, execute_target, active)
        VALUES (
            cache_row.tool_name,
            format('via %s: %s', cache_row.server_name,
                   coalesce(cache_row.description, cache_row.title, cache_row.tool_name)),
            coalesce(cache_row.input_schema, '{"type":"object"}'::jsonb),
            jsonb_build_object(
                'kind',   'mcp_proxy',
                'server', cache_row.server_name,
                'tool',   cache_row.tool_name
            ),
            true
        )
        ON CONFLICT (name) DO UPDATE
           SET description    = EXCLUDED.description,
               args_schema    = EXCLUDED.args_schema,
               execute_target = EXCLUDED.execute_target,
               active         = true;
        n_touched := n_touched + 1;
    END LOOP;

    -- Soft-deactivate any tool_defs that point at mcp_proxy but no
    -- longer have a corresponding active cache row. Keeps history
    -- (rows preserved with active=false) without leaving stale
    -- tool_defs visible to agents.
    UPDATE stewards.tool_defs td
       SET active = false
     WHERE (execute_target ->> 'kind') = 'mcp_proxy'
       AND active = true
       AND NOT EXISTS (
            SELECT 1 FROM stewards.mcp_tool_cache c
             WHERE c.server_name = (td.execute_target ->> 'server')
               AND c.tool_name   = (td.execute_target ->> 'tool')
               AND c.active
        );

    RETURN n_touched;
END
$$;

COMMENT ON FUNCTION stewards.promote_mcp_tool_cache_to_tool_defs IS
  'Bulk sync: upsert one tool_defs row per active mcp_tool_cache row, '
  'soft-deactivate orphaned mcp_proxy tool_defs. Idempotent. Bridge '
  'calls this at the end of refresh-tools; the trigger below also '
  'fires on row-level changes for live consistency.';

-- ---------------------------------------------------------------------
-- 2. Row-level trigger — keep tool_defs in lockstep with cache
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.mcp_tool_cache_sync_trigger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        -- Cache row removed entirely — deactivate matching tool_def.
        UPDATE stewards.tool_defs
           SET active = false
         WHERE (execute_target ->> 'kind') = 'mcp_proxy'
           AND (execute_target ->> 'server') = OLD.server_name
           AND (execute_target ->> 'tool')   = OLD.tool_name;
        RETURN OLD;
    END IF;

    -- INSERT / UPDATE: mirror the row.
    IF NEW.active THEN
        INSERT INTO stewards.tool_defs
            (name, description, args_schema, execute_target, active)
        VALUES (
            NEW.tool_name,
            format('via %s: %s', NEW.server_name,
                   coalesce(NEW.description, NEW.title, NEW.tool_name)),
            coalesce(NEW.input_schema, '{"type":"object"}'::jsonb),
            jsonb_build_object(
                'kind',   'mcp_proxy',
                'server', NEW.server_name,
                'tool',   NEW.tool_name
            ),
            true
        )
        ON CONFLICT (name) DO UPDATE
           SET description    = EXCLUDED.description,
               args_schema    = EXCLUDED.args_schema,
               execute_target = EXCLUDED.execute_target,
               active         = true;
    ELSE
        -- Cache row marked inactive — hide the tool_def too.
        UPDATE stewards.tool_defs
           SET active = false
         WHERE (execute_target ->> 'kind') = 'mcp_proxy'
           AND (execute_target ->> 'server') = NEW.server_name
           AND (execute_target ->> 'tool')   = NEW.tool_name;
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS mcp_tool_cache_sync ON stewards.mcp_tool_cache;
CREATE TRIGGER mcp_tool_cache_sync
    AFTER INSERT OR UPDATE OR DELETE ON stewards.mcp_tool_cache
    FOR EACH ROW
    EXECUTE FUNCTION stewards.mcp_tool_cache_sync_trigger();

-- ---------------------------------------------------------------------
-- 3. Bootstrap — sync once now from whatever's currently in the cache
-- ---------------------------------------------------------------------
SELECT stewards.promote_mcp_tool_cache_to_tool_defs() AS bootstrapped_count;

-- (Seed rows extracted to the downstream overlay at OSS extraction
--  2026-06-12: servers/tools/pipelines are operator data, not machinery.
--  Generic examples ship in the seed pack.)
