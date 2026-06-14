# Wiring up MCP servers

A model is only as useful as the tools it can reach. The substrate gives its
agents tools by connecting to **MCP servers** — the same Model Context Protocol
your IDE or Claude Desktop speaks — through a Go **bridge daemon**. This page
takes you from "the stack is up" to "an agent can actually call an external
tool," with four worked examples: one that already works out of the box, one
that ships in this repo behind an opt-in flag, and two public servers of ours
you can wire in as remote endpoints.

## How it fits together

The Rust in-database worker never talks to MCP servers directly. Instead:

1. **`stewards.mcp_servers`** is the registry — one row per server, naming a
   transport (`stdio` or `http`) and how to reach it. This is the single source
   of truth: the substrate reads it to know which tools are routable, and the
   bridge reads it to know what to spawn or dial.
2. **The bridge** (`stewards-mcp bridge run`, a service in the compose) holds the
   live MCP client sessions. On `refresh-tools` it calls each enabled server's
   `tools/list` and writes the results into **`stewards.mcp_tool_cache`**.
3. A trigger **auto-promotes** each cached tool into **`stewards.tool_defs`** with
   an `execute_target` of `kind=mcp_proxy`. The tool now exists in the catalog —
   but no agent can call it yet.
4. **Grants are deny-by-default.** A cached tool stays invisible to every agent
   until you add an explicit `stewards.agent_tool_perms` allow row. This is the
   security boundary: registering a server does not hand its tools to anyone.

At call time the worker enqueues a `kind=mcp_proxy` work-queue row, the bridge
claims it over `LISTEN/NOTIFY`, calls the real tool, and writes the result back
as a `role='tool'` message the model reads on its next turn.

## The registry row

```sql
INSERT INTO stewards.mcp_servers
  (name, description, transport, command, args, url, env, enabled)
VALUES (...);
```

| Column | stdio | http |
|--------|-------|------|
| `transport` | `'stdio'` | `'http'` |
| `command` | absolute path to the binary **inside the bridge container** | — |
| `args` | `text[]` of CLI args | — |
| `url` | — | the server's `/mcp` endpoint (Streamable HTTP) |
| `env` | env vars for the spawned process | request headers |
| `enabled` | set `true` (defaults to `false`) | same |

**Secrets never sit in the row.** Put a placeholder of the form `$env:NAME` in
`env` or anywhere in the `url`, and the bridge resolves it against *its own*
process environment at connect time — so the key lives in the bridge's `.env`,
not in the database. (`$$env:NAME` is also honored; it's a legacy over-escape.)
Example, from the bundled `git` server:

```sql
env => '{"GITHUB_TOKEN": "$env:GITHUB_TOKEN"}'::jsonb
```

For HTTP servers that key off a query parameter, the same indirection works
inline: `url => 'https://host/mcp?key=$env:MY_KEY'`.

## The four steps, every time

```bash
# 1. register the server (psql / a .sql file)
docker compose exec -T pg psql -U stewards -d stewards < my-server.sql
# 2. tell the bridge to (re)discover tools
docker compose exec bridge stewards-mcp bridge refresh-tools
# 3. confirm it connected + cached tools
docker compose exec -T pg psql -U stewards -d stewards \
  -c "SELECT server, transport, enabled, active_tools, last_error FROM stewards.mcp_bridge_state;"
# 4. grant the tool(s) to an agent (deny-by-default until you do)
docker compose exec -T pg psql -U stewards -d stewards -c \
  "INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
   VALUES ('stewards-explore','my_tool','allow','manual')
   ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action;"
```

`active_tools > 0` with `last_error` NULL means the server connected and its
tools are cached. Re-run `refresh-tools` whenever a server gains or renames
tools — the catalog is a snapshot, not a live mirror, and a grant on a tool name
that isn't yet in the catalog simply does nothing until the next refresh.

---

## A. exa-search — remote HTTP, works out of the box

The substrate ships with web search already wired: a core seed registers Exa's
hosted MCP over HTTP, on Exa's keyless free tier. Nothing to install.

```sql
-- (already seeded in core — shown for shape)
transport => 'http',
url        => 'https://mcp.exa.ai/mcp?tools=web_search_exa',
enabled    => true
```

It's still deny-by-default — grant `web_search_exa` to the agent that should
have it. For production volume add your own key inline: append
`&exaApiKey=$env:EXA_API_KEY` to the url and set `EXA_API_KEY` in `.env`. (Be a
good citizen: the free tier is for trying things out.)

## B. yt-mcp — a bundled stdio server, opt-in

YouTube transcript + playlist tools ship in this repo (`cmd/yt-mcp`), but behind
a build flag so the default image stays lean and python-free. Bringing them in
is the canonical "add a stdio server" example, and it powers
[`examples/playlist-digester.sql`](../examples/playlist-digester.sql):

```bash
# build the bridge WITH youtube (adds the yt-mcp binary + python3/yt-dlp)
docker compose -f docker-compose.yaml -f docker-compose.yt.yaml up -d --build
# register the server + the digest pipeline, then refresh
docker compose exec -T pg psql -U stewards -d stewards < examples/playlist-digester.sql
docker compose exec bridge stewards-mcp bridge refresh-tools
```

The registry row (from that example file) shows a stdio server with a
subcommand and an env var:

```sql
transport => 'stdio',
command    => '/usr/local/bin/yt-mcp',
args       => ARRAY['serve'],          -- yt-mcp's MCP loop subcommand
env        => '{"YT_DIR": "/yt"}'::jsonb,
enabled    => true
```

This is the same shape the core uses for its own bundled servers — `fs-read`,
the substrate's self-surface (`pg-ai-stewards`), `fetch-md`, and `git`. Read
[`extension/05-mcp-bridge.sql`](../extension/05-mcp-bridge.sql) to see those
seeds; they're the reference for any stdio server you add.

## C. gospel-engine — a public server, stdio *or* remote HTTP

[gospel-engine](https://github.com/cpuchip/gospel-engine) is one of our public
servers (its code is open; the scripture corpus it indexes is licensed
separately and mounted privately). It's a useful example because the **same
binary speaks MCP two ways** — as a local stdio child, or as a shared remote
endpoint at `/mcp`. Pick the transport that fits your deployment:

```sql
-- remote: one engine, many clients (no binary in the bridge image)
INSERT INTO stewards.mcp_servers (name, description, transport, url, env, enabled)
VALUES (
  'gospel-engine',
  'Scripture + talk search/get (gospel_search, gospel_get, gospel_list).',
  'http',
  'https://engine.example.com/mcp?key=$env:GOSPEL_MCP_KEY',
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO UPDATE SET
  transport='http', url=EXCLUDED.url, command=NULL,
  args=ARRAY[]::text[], env=EXCLUDED.env, enabled=true, updated_at=now();
```

Set `GOSPEL_MCP_KEY` in the bridge's `.env`; the bridge substitutes it into the
URL at connect time so the secret never touches the database. The stdio form is
identical to example B — point `command` at the `gospel-engine` binary instead
of giving a `url`. This is the pattern for any **domain** MCP server you keep
out of the core: it's *your* data and *your* deployment, so its registry row
lives in your overlay, not in this repo.

## D. dnd-tools — a public remote server, the live reference

[dnd-tools](https://github.com/cpuchip/dnd-tools) is a small public Go MCP
(SRD 5.2 + Open5e: `/attack`, `/check`, `/save`, `/cast`, HP) deployed at
`https://dnd.ibeco.me/mcp`. It's the worked example of dialing a **remote**
server you didn't write into the bridge — and the tool side of the D&D persona
in [`docs/personas-and-chattermax.md`](personas-and-chattermax.md):

```sql
INSERT INTO stewards.mcp_servers (name, description, transport, url, env, enabled)
VALUES (
  'dnd-tools',
  'Dice + 5e rules: roll, attack, check, save, cast, hp.',
  'http',
  'https://dnd.ibeco.me/mcp?key=$env:DND_API_KEY',
  '{}'::jsonb,
  true
)
ON CONFLICT (name) DO UPDATE SET url=EXCLUDED.url, enabled=true, updated_at=now();
```

Same recipe as gospel-engine: register, set the key in `.env`, `refresh-tools`,
grant to the persona who runs the table. A human typing `/hp -3` in the chat UI
and the persona reading that HP back both hit the *same* dnd-tools instance — the
state is unified because both clients dial one server.

---

## Building your own

An MCP server is just a process that speaks the protocol — write it in any
language. The bundled Go servers in `cmd/` (`fs-read-mcp`, `git-mcp`, `yt-mcp`)
are readable references; for remote/HTTP, gospel-engine and dnd-tools both serve
`/mcp` with a [`mark3labs/mcp-go`](https://github.com/mark3labs/mcp-go)
`StreamableHTTPServer` gated by a `?key=` query parameter. The substrate doesn't
care how a server is built — only that it's registered, refreshed, and granted.

## Verify it works

```sql
SELECT * FROM stewards.mcp_bridge_state;                         -- per-server health + tool count
SELECT name, active FROM stewards.tool_defs                      -- did the tool promote?
 WHERE execute_target->>'kind' = 'mcp_proxy' ORDER BY name;
SELECT agent_family, tool_pattern, action FROM stewards.agent_tool_perms  -- who can call it
 WHERE tool_pattern = 'my_tool';
```

A tool an agent still can't reach is almost always one of three things: the
server isn't `enabled`, you haven't run `refresh-tools` since adding it, or the
grant is missing (deny-by-default). The `mcp_bridge_state` view tells you the
first two at a glance.
