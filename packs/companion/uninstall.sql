-- packs/companion/uninstall.sql — remove the forge machinery.
-- Deliberately does NOT drop forged tools by default: they are the
-- operator's data. It prints what remains and how to remove it.

DELETE FROM stewards.pipelines WHERE family = 'forge';
DELETE FROM stewards.tool_defs WHERE name = 'forge_register';
DELETE FROM stewards.tool_groups WHERE name = 'forge-register';
DELETE FROM stewards.agent_tool_perms WHERE tool_pattern = 'forge_register';
DROP FUNCTION IF EXISTS forge.forge_register(jsonb);

DO $u$
DECLARE n int; names text;
BEGIN
    SELECT count(*), string_agg(tool_name, ', ') INTO n, names FROM forge.forged_tools;
    IF n > 0 THEN
        RAISE NOTICE 'companion pack removed. % forged tool(s) KEPT (your data): %', n, names;
        RAISE NOTICE 'To remove them too: DROP each forge.<name>(jsonb), DELETE FROM stewards.tool_defs WHERE name IN (...), then DROP SCHEMA forge CASCADE.';
    ELSE
        DROP TABLE IF EXISTS forge.forged_tools;
        DROP SCHEMA IF EXISTS forge;
        RAISE NOTICE 'companion pack removed cleanly (no forged tools existed).';
    END IF;
END
$u$;
