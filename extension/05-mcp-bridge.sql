-- =====================================================================
-- 05-mcp-bridge — the substrate's window to the external MCP world
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Sources folded, in original
-- ship order: 3e2-1 (server registry + tool cache), 3e2-2 (mcp_proxy
-- dispatch; its work_queue status-CHECK expansion was born back into
-- schema.rs), 3e2-3 (cache→tool_defs auto-promote), h1-5a
-- (mcp_proxy_enqueue soft-fail — the final form authored here), h1-7a
-- (fs-read + pg-ai-stewards self-surface seeds — these two binaries
-- ship WITH the substrate, so their registrations are core, not
-- overlay; external server seeds live in the operator's overlay).
--
-- The design, in one paragraph: the Rust bgworker stays reqwest-only;
-- a Go bridge daemon holds the MCP client sessions. stewards.mcp_servers
-- is the registry (stdio command or http url; secrets in env jsonb,
-- read only by the bridge). The bridge populates mcp_tool_cache via
-- tools/list, and a sync trigger auto-promotes active cache rows into
-- stewards.tool_defs with execute_target kind='mcp_proxy' —
-- deny-by-default, explicit agent grants required. At call time the
-- bgworker enqueues child work_queue rows of kind='mcp_proxy' (async
-- fan-out; the parent tool_dispatch parks at 'waiting_for_tools'), the
-- bridge claims children via LISTEN/NOTIFY, and
-- tool_dispatch_complete_waiting() promotes parents whose children all
-- resolved: insert role='tool' messages, enqueue the continuation chat.
-- =====================================================================

-- ---------------------------------------------------------------------
-- mcp_servers — registry of external MCP servers the bridge connects to.
-- Single source of truth for both the substrate (knows which tools are
-- routable) and the bridge (knows what to spawn/connect). Secrets
-- (bearer tokens, API keys) live in the env jsonb and are read only by
-- the bridge process — keep stewards role permissions tight.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.mcp_servers (
    name        text PRIMARY KEY
                CHECK (name ~ '^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$'),
    description text NOT NULL DEFAULT '',
    transport   text NOT NULL CHECK (transport IN ('stdio', 'http')),
    -- transport='stdio': command + args + env. Bridge spawns this
    -- binary and pipes JSON-RPC over stdin/stdout. command is an
    -- absolute path on the bridge's host (in-container for the
    -- shipped compose).
    command     text,
    args        text[] NOT NULL DEFAULT ARRAY[]::text[],
    -- transport='http': remote URL. Bridge speaks Streamable HTTP.
    url         text,
    -- Common: env vars passed to the spawned process (stdio) or as
    -- request headers (http).
    env         jsonb NOT NULL DEFAULT '{}'::jsonb,
    enabled     boolean NOT NULL DEFAULT false,
    -- Operational telemetry — bridge updates these on refresh / call.
    last_health_check_at  timestamptz,
    last_tools_refresh_at timestamptz,
    last_error            text,
    notes       text NOT NULL DEFAULT '',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    -- Transport-specific field validation:
    --   stdio MUST have command; http MUST have url.
    CONSTRAINT mcp_servers_transport_fields CHECK (
        (transport = 'stdio' AND command IS NOT NULL AND command <> '')
        OR
        (transport = 'http'  AND url IS NOT NULL AND url <> '')
    )
);

CREATE INDEX IF NOT EXISTS mcp_servers_enabled_idx
    ON stewards.mcp_servers (enabled) WHERE enabled;

COMMENT ON TABLE stewards.mcp_servers IS
  'Registry of external MCP servers the bridge daemon connects to. '
  'Single source of truth for both the substrate (knows which tools '
  'are routable) and the bridge (knows what to spawn/connect). Secrets '
  '(bearer tokens, API keys) live in the env jsonb and are read only '
  'by the bridge process.';

-- ---------------------------------------------------------------------
-- mcp_tool_cache — per-server tool catalog from tools/list. Populated
-- by the bridge at startup and on tools/list_changed notifications.
-- active=false hides a tool from agents without losing its schema
-- (e.g., during incident response when a server's tool misbehaves).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.mcp_tool_cache (
    server_name      text NOT NULL
                     REFERENCES stewards.mcp_servers(name) ON DELETE CASCADE,
    tool_name        text NOT NULL,
    description      text NOT NULL DEFAULT '',
    title            text,
    -- The MCP server's own JSON Schema for inputs; becomes
    -- tool_defs.args_schema at promotion.
    input_schema     jsonb NOT NULL,
    output_schema    jsonb,
    last_refreshed_at timestamptz NOT NULL DEFAULT now(),
    active           boolean NOT NULL DEFAULT true,
    PRIMARY KEY (server_name, tool_name)
);

CREATE INDEX IF NOT EXISTS mcp_tool_cache_active_idx
    ON stewards.mcp_tool_cache (active) WHERE active;

COMMENT ON TABLE stewards.mcp_tool_cache IS
  'Discovered tools from each MCP server, populated by the bridge daemon '
  'via tools/list at startup and on tools/list_changed notifications. '
  'The sync trigger auto-creates stewards.tool_defs rows from this cache, '
  'but agent_tool_perms defaults to deny — explicit grant required before '
  'agents can call any cached tool.';

-- ---------------------------------------------------------------------
-- mcp_bridge_state — at-a-glance bridge connectivity. After bridge
-- refresh-tools runs, active_tools should be > 0 for every enabled
-- server; last_error NULL means the most recent health check passed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.mcp_bridge_state AS
SELECT s.name AS server,
       s.transport,
       s.enabled,
       s.last_health_check_at,
       s.last_tools_refresh_at,
       coalesce((SELECT count(*) FROM stewards.mcp_tool_cache c
                  WHERE c.server_name = s.name AND c.active), 0) AS active_tools,
       s.last_error
  FROM stewards.mcp_servers s
 ORDER BY s.name;

-- ---------------------------------------------------------------------
-- mcp_proxy_enqueue — substrate-internal API (soft-fail final form).
--
-- Inserts a child work_queue row of kind='mcp_proxy' describing which
-- MCP server + tool to call and the tool's args. The provider column
-- carries the server name so operators can grep the queue. NOTIFY
-- wakes the bridge immediately. Returns the new row's id; the Rust
-- caller records it in the parent tool_dispatch's result jsonb so the
-- completion pass knows which child belongs to which tool_call_id.
--
-- Disabled/unregistered server → RAISE NOTICE + RETURN NULL (h1-5a).
-- A RAISE EXCEPTION here crashes the bgworker dispatcher via pgrx SPI
-- longjmp; NULL lets the Rust caller emit a structured tool-failure
-- reply the model can read and route around.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.mcp_proxy_enqueue(
    p_server   text,
    p_tool     text,
    p_args     jsonb,
    p_parent_tool_dispatch_id bigint  -- nullable; for synthetic tests
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    new_id bigint;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM stewards.mcp_servers
        WHERE name = p_server AND enabled
    ) THEN
        RAISE NOTICE 'mcp_proxy_enqueue: server % is not registered or not enabled — returning NULL', p_server;
        RETURN NULL;
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES (
        'mcp_proxy',
        p_server,
        jsonb_build_object(
            'server',                  p_server,
            'tool',                    p_tool,
            'args',                    p_args,
            'parent_tool_dispatch_id', p_parent_tool_dispatch_id
        )
    )
    RETURNING id INTO new_id;

    -- NOTIFY payload is the row id as text. Bridge LISTENs and uses it
    -- as a hint to immediately try claiming (it claims the OLDEST
    -- pending mcp_proxy regardless, so race-safe under concurrent
    -- producers).
    PERFORM pg_notify('stewards_mcp_proxy', new_id::text);

    RETURN new_id;
END;
$func$;

COMMENT ON FUNCTION stewards.mcp_proxy_enqueue(text, text, jsonb, bigint) IS
'Enqueue a child work_queue row of kind=mcp_proxy and notify the bridge daemon. Soft-fails (NOTICE + NULL) on a disabled/unregistered server — an EXCEPTION here would crash the bgworker via pgrx SPI longjmp. Synthetic callers (tests) can pass NULL for p_parent_tool_dispatch_id.';

-- ---------------------------------------------------------------------
-- tool_dispatch_complete_waiting — completion pass for async fan-out.
--
-- Scans tool_dispatch rows in 'waiting_for_tools', checks whether all
-- their mcp_proxy children are done/errored, and if so collects the
-- children's results, inserts role='tool' messages, enqueues the
-- continuation chat (chat_post_internal — markers inherit), and
-- transitions the parent to 'done'. The Rust tick loop calls this on
-- each tick. Implemented in SQL because the per-row logic is SPI-heavy
-- and already exists as SQL call sites.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.tool_dispatch_complete_waiting()
RETURNS integer
LANGUAGE plpgsql AS $func$
DECLARE
    parent_row    record;
    child_row     record;
    resolved_arr  jsonb;
    pending_arr   jsonb;
    pending_elem  jsonb;
    all_done      boolean;
    final_msgs    jsonb := '[]'::jsonb;
    completed_n   integer := 0;
    chat_work_id  bigint;
    parent_chat_id bigint;
    parent_session text;
    parent_family  text;
    parent_model   text;
    parent_provider text;
BEGIN
    -- SKIP LOCKED so concurrent workers running this same function
    -- don't block each other.
    FOR parent_row IN
        SELECT id, payload, result, provider
          FROM stewards.work_queue
         WHERE kind = 'tool_dispatch'
           AND status = 'waiting_for_tools'
         ORDER BY created_at
         FOR UPDATE SKIP LOCKED
    LOOP
        resolved_arr := coalesce(parent_row.result -> 'resolved', '[]'::jsonb);
        pending_arr  := coalesce(parent_row.result -> 'pending',  '[]'::jsonb);
        all_done := true;
        final_msgs := '[]'::jsonb;

        -- Re-merge resolved (sync) replies first.
        final_msgs := resolved_arr;

        -- For each pending entry, look up the child's status.
        FOR pending_elem IN SELECT * FROM jsonb_array_elements(pending_arr)
        LOOP
            SELECT id, status, result, error
              INTO child_row
              FROM stewards.work_queue
             WHERE id = (pending_elem ->> 'child_work_id')::bigint;

            IF child_row.status NOT IN ('done', 'error') THEN
                all_done := false;
                EXIT;
            END IF;

            -- Pull the tool reply content. Bridge stores result.content
            -- (string) on success, error column on failure. The model
            -- gets whichever surfaced.
            DECLARE
                content_text text;
            BEGIN
                IF child_row.status = 'done' THEN
                    content_text := child_row.result ->> 'content';
                    IF content_text IS NULL THEN
                        content_text := child_row.result::text;
                    END IF;
                ELSE
                    content_text := jsonb_build_object(
                        'error', child_row.error
                    )::text;
                END IF;

                final_msgs := final_msgs || jsonb_build_array(
                    jsonb_build_object(
                        'tc_id',   pending_elem ->> 'tc_id',
                        'name',    pending_elem ->> 'name',
                        'content', content_text
                    )
                );
            END;
        END LOOP;

        IF NOT all_done THEN
            CONTINUE;
        END IF;

        -- All children resolved; promote to done. Insert tool messages,
        -- enqueue the continuation chat.
        parent_chat_id  := (parent_row.payload ->> 'parent_work_id')::bigint;
        parent_session  := parent_row.payload ->> 'session_id';
        parent_family   := parent_row.payload ->> 'agent_family';
        parent_model    := parent_row.payload ->> 'model';
        parent_provider := parent_row.provider;

        FOR pending_elem IN SELECT * FROM jsonb_array_elements(final_msgs)
        LOOP
            INSERT INTO stewards.messages
                (session_id, role, content, tool_call_id, parent_work_id)
            VALUES (
                parent_session,
                'tool',
                pending_elem ->> 'content',
                pending_elem ->> 'tc_id',
                parent_row.id
            );
        END LOOP;

        SELECT stewards.chat_post_internal(
            parent_family, parent_model, parent_session, parent_provider
        ) INTO chat_work_id;

        UPDATE stewards.work_queue
           SET status = 'done',
               result = parent_row.result || jsonb_build_object(
                   'completed_at',     now()::text,
                   'next_chat_work_id', chat_work_id,
                   'final_tool_count',  jsonb_array_length(final_msgs)
               ),
               done_at = now()
         WHERE id = parent_row.id;

        completed_n := completed_n + 1;
    END LOOP;

    RETURN completed_n;
END;
$func$;

COMMENT ON FUNCTION stewards.tool_dispatch_complete_waiting IS
  'Completion pass for async-fan-out tool_dispatch. Bgworker calls '
  'this on each tick; rows whose mcp_proxy children have all '
  'resolved are promoted from waiting_for_tools to done with the '
  'usual side effects (insert tool messages + enqueue continuation '
  'chat).';

-- ---------------------------------------------------------------------
-- promote_mcp_tool_cache_to_tool_defs — bulk sync.
--
-- Upserts one tool_def per active cache row (description prefixed
-- "via <server>: ..."), soft-deactivates orphaned mcp_proxy tool_defs.
-- Idempotent. Bridge calls this at the end of refresh-tools; the
-- row-level trigger below keeps live consistency between refreshes.
--
-- Naming: bare tool_name (model-friendly, no slashes). Cross-server
-- collisions on tool_name would silently overwrite via ON CONFLICT —
-- a future correctness concern if two servers ship a same-named tool.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.promote_mcp_tool_cache_to_tool_defs()
RETURNS integer
LANGUAGE plpgsql AS $func$
DECLARE
    n_touched integer := 0;
    cache_row record;
BEGIN
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

    -- Soft-deactivate tool_defs that point at mcp_proxy but no longer
    -- have a corresponding active cache row. Keeps history without
    -- leaving stale tool_defs visible to agents.
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
END;
$func$;

COMMENT ON FUNCTION stewards.promote_mcp_tool_cache_to_tool_defs IS
  'Bulk sync: upsert one tool_defs row per active mcp_tool_cache row, '
  'soft-deactivate orphaned mcp_proxy tool_defs. Idempotent. Bridge '
  'calls this at the end of refresh-tools; the trigger keeps row-level '
  'consistency between refreshes.';

-- ---------------------------------------------------------------------
-- Row-level trigger — keep tool_defs in lockstep with the cache.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.mcp_tool_cache_sync_trigger()
RETURNS trigger
LANGUAGE plpgsql AS $func$
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
END;
$func$;

DROP TRIGGER IF EXISTS mcp_tool_cache_sync ON stewards.mcp_tool_cache;
CREATE TRIGGER mcp_tool_cache_sync
    AFTER INSERT OR UPDATE OR DELETE ON stewards.mcp_tool_cache
    FOR EACH ROW
    EXECUTE FUNCTION stewards.mcp_tool_cache_sync_trigger();

-- ---------------------------------------------------------------------
-- Self-surface seeds (h1-7a). These two servers ship WITH the
-- substrate (cmd/fs-read-mcp, cmd/stewards-mcp in this repo; the
-- compose mounts them at the paths below), so they're core machinery,
-- not overlay data. External servers are operator data — seed them in
-- the overlay. ON CONFLICT DO NOTHING: operators own these rows after
-- install (paths, scopes, enabled state).
--
-- agent_tool_perms intentionally NOT granted here. Bridged tools are
-- deny-by-default; operators allow them per-agent explicitly.
-- ---------------------------------------------------------------------
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'fs-read',
  'Path-scoped filesystem read for substrate-internal agents. Tools: '
    || 'fs_list, fs_read, fs_search. Scope is enforced at the MCP tool '
    || 'layer via the --allowed-paths flag — even if the bridge container '
    || 'mounts more of the workspace, the agent only sees what is in '
    || 'scope. Adjust -allowed-paths to your workspace layout.',
  'stdio',
  '/usr/local/bin/fs-read-mcp',
  ARRAY[
    '-repo-root', '/workspace',
    '-allowed-paths', '.spec/journal/*,.spec/proposals/*,.mind/*,docs/**'
  ],
  NULL,
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;

-- pg-ai-stewards MCP — the substrate's own tool surface exposed to
-- internal agents through the bridge proxy. The stewards-mcp binary
-- defaults to inbound stdio mode with no subcommand args; STEWARDS_DSN
-- propagates from the bridge container's env so the substrate connects
-- to itself. Read tools (doc_search/doc_get/doc_similar/doc_citations,
-- work_item_list/show, watchman_pass_show/passes_list) are the
-- intended grant surface; escalation write tools exist on the same MCP
-- but belong to the operator review surface.
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'pg-ai-stewards',
  'Substrate self-surface — exposes the substrate''s own docs/work_items/'
    || 'watchman read tools to internal agents through the bridge proxy. '
    || 'Agents call doc_search/work_item_show to consult prior work before '
    || 'doing external research. Escalation write tools (work_item_escalation_*) '
    || 'exist on the same MCP but are excluded from research-agent grants — '
    || 'they belong to the operator review surface.',
  'stdio',
  '/usr/local/bin/stewards-mcp',
  ARRAY[]::text[],
  NULL,
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;

-- fetch-md — fetch a URL and return readable markdown (fetch_url, fetch_urls,
-- extract_links, fetch_url_raw). A generic utility the research pipelines lean
-- on. Static fetch needs no key; the js:true rendering path needs a `chromium`
-- binary in the bridge image (omitted by default — see bridge.Dockerfile).
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'fetch-md',
  'Fetch a web page and return it as readable markdown. Tools: fetch_url '
    || '(one URL -> markdown via readability), fetch_urls (batch), extract_links '
    || '(list a page''s links), fetch_url_raw (unprocessed HTML). The default '
    || 'path is a plain HTTP client; a js:true param renders with headless '
    || 'chromium when available.',
  'stdio',
  '/usr/local/bin/fetch-md-mcp',
  ARRAY[]::text[],
  NULL,
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;

-- git — general git/gh operations over a configured workdir, distinct from
-- coder-mcp's sandbox-scoped git. Branch ops are namespaced to agent/* and
-- main/master/release/* are protected (the tool refuses them). GITHUB_TOKEN is
-- read from the bridge env at exec time (rotation without restart); deny-by-
-- default like every bridged server — grant per-agent in an overlay.
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'git',
  'General git + GitHub ops over a configured workdir. Tools: git_clone, '
    || 'git_status, git_branch_create, git_add, git_commit, git_push, '
    || 'gh_pr_create, gh_issue_create. Agent branches are namespaced (agent/*) '
    || 'and protected branches (main/master/release/*) are refused.',
  'stdio',
  '/usr/local/bin/git-mcp',
  ARRAY[]::text[],
  NULL,
  '{"GITHUB_TOKEN": "$$env:GITHUB_TOKEN"}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;

-- exa-search — the default web search (Exa's hosted MCP, remote/http). The
-- substrate ships with web search working OUT OF THE BOX: Exa's endpoint
-- serves web_search_exa on a keyless free/anonymous tier (rate-limited). For
-- production volume, add your own key by appending &exaApiKey=<KEY> to the url
-- (operators own this row after install). Deny-by-default like every bridged
-- server — grant web_search_exa per-agent in an overlay.
--
-- Be a good citizen: the free tier is for trying it out; register your own Exa
-- account + key for anything beyond light use.
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'exa-search',
  'Web search via Exa''s hosted MCP. Tool: web_search_exa (neural web search '
    || '-> titles, URLs, and content highlights). Works on Exa''s keyless free '
    || 'tier out of the box; append &exaApiKey=<KEY> to the url for production '
    || 'rate limits.',
  'http',
  NULL,
  ARRAY[]::text[],
  'https://mcp.exa.ai/mcp?tools=web_search_exa',
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO NOTHING;
