# Prior Art: Claude Code in a Container as a Workspace Host (2026-06-27)

*Opus research, web-verified against Anthropic's own docs + help center (not inferred). Feeds the
Workspace-Host vision (`.spec/notes/2026-06-27-workspace-host-and-enterprise-vision.md`). Sources at
the bottom.*

## TL;DR for the build spec
- **The Max-sub-in-a-container plan works TODAY** — `claude -p` authenticated with a
  `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) draws from Michael's Max subscription pool.
  **But it is provisional.** Anthropic announced (May 13) headless `claude -p` / Agent SDK / 3rd-party
  usage would move to a separate metered credit pool on **June 15**, then **paused that change on June
  15** (the day it was due) and is reworking it with advance notice. → **Design auth as SWAPPABLE**
  (`CLAUDE_CODE_OAUTH_TOKEN` now, `ANTHROPIC_API_KEY` fallback), because the subsidy may return.
- **Anthropic ships the reference design** you're cloning: an official `.devcontainer` (egress firewall
  + persistent `~/.claude` volume + non-root) and a published devcontainer Feature. Copy it.
- **The credential pattern: the secret stays at the orchestrator; only a short-lived, scoped credential
  goes in the box.** Your `coder` v2 MCP already does this for git ("token never in sandbox"). The
  Workspace Host generalizes it from the git token to the Claude credential itself.

## The `claude -p` auth answer (verified precedence)
Claude Code resolves creds in this order: (1) cloud-provider (Bedrock/Vertex/Foundry) → (2)
`ANTHROPIC_AUTH_TOKEN` (Bearer, for gateways) → (3) **`ANTHROPIC_API_KEY`** (X-Api-Key; *"in
non-interactive `-p` mode the key is always used when present"* — pay-per-token) → (4) **`apiKeyHelper`**
(a script returning a rotating short-lived key; re-called after 5 min or on 401) → (5)
**`CLAUDE_CODE_OAUTH_TOKEN`** (the one-year token from `claude setup-token`; *"for CI/scripts where
browser login isn't available"*; Pro/Max/Team/Enterprise; **inference-only, no Remote Control**) →
(6) interactive `/login`.

**To run headless on the Max plan in a per-task container:**
1. Once, on a browser machine: `claude setup-token` → prints a **one-year token** (not saved; you copy it).
2. Inject it into each container **at runtime** as `CLAUDE_CODE_OAUTH_TOKEN` (never in the image).
3. Run plain `claude -p` (usage bills against the Max sub).

**Caveats that bite:**
- **`--bare` does NOT read `CLAUDE_CODE_OAUTH_TOKEN`** → use plain `-p`, not `--bare`.
- **`ANTHROPIC_API_KEY` outranks the OAuth token**, and a stale/disabled key fails *silently* → set
  **exactly one** credential per container; `/status` confirms which is active.
- **Rate limits are shared across every container on the same token** → parallel fan-out of N
  workspaces on one Max OAuth token collides on the 5-hour/weekly caps. For real parallelism, give each
  container its own `ANTHROPIC_API_KEY` (pay-per-token).
- **OAuth token is inference-only** (can't drive a Remote-Control session) — fine for `-p`.
- **One-year hard expiry** (auto-refresh within validity; regenerate annually).

### Credential-injection methods, ranked safest-first
1. **Orchestrator-injected runtime env / secret mount** — the substrate sets the token at `docker
   run`/compose `secrets:` time → lands as `/run/secrets/<id>` or a tmpfs file the entrypoint exports.
   Never in image / `docker history` / a layer. **Default for a per-task container.**
2. **`apiKeyHelper` reading from a vault** — short-lived rotating tokens; re-fetched on 401.
3. **Bind-mount read-only `~/.claude/.credentials.json` (0600)** — works, but under
   `--dangerously-skip-permissions` a hostile repo can exfiltrate it → trusted repos only.
4. **Docker/Compose `secrets:` / BuildKit `RUN --mount=type=secret`** — only if something at *build*
   time needs a key (usually nothing here does).

**Anti-patterns (all leak into image/history/logs):** `ENV KEY=` in the Dockerfile, `ARG` for keys,
`COPY .env`, committing `.env`, echoing the token in entrypoint logs.

## Recommended container shape
```
Base:   mcr.microsoft.com/devcontainers/base:ubuntu  (or Anthropic's reference Dockerfile)
User:   non-root — REQUIRED (CLI refuses --dangerously-skip-permissions as root)
CLI:    pinned `npm i -g @anthropic-ai/claude-code@X.Y.Z` + DISABLE_AUTOUPDATER=1
Egress: init-firewall.sh default-deny → allow api.anthropic.com, github.com, npm, + substrate endpoints
        (runArgs: NET_ADMIN, NET_RAW)
Config: ~/.claude on a named per-task volume (source=claude-code-config-${taskId})
```
- **Repos in:** substrate clones the scoped repos and bind-mounts the workspace (RW for the agent).
  **Keep the GitHub token OUT of the container** — mirror Claude Code on the web (a proxy holds the
  GitHub token outside the sandbox, issues scoped creds inside); route git writes back through the
  existing `coder` MCP rather than handing the container a PAT.
- **Creds in:** runtime-injected `CLAUDE_CODE_OAUTH_TOKEN` (Max, today) or `ANTHROPIC_API_KEY`
  (scalable/parallel), one per container, never baked.
- **Agent runs:** `claude -p "<binding question>" --output-format stream-json
  --dangerously-skip-permissions` — safe because non-root + firewalled + ephemeral. (Auto mode is the
  lower-blast-radius alternative.)
- **Human attaches alongside** (same bind-mounted workspace the agent edits): `code tunnel` inside the
  container (open `vscode.dev/tunnel/<name>`), OR desktop VS Code **"Attach to Running Container"** for
  an already-running per-task container. "Reopen in Container" only when *starting* from the repo.

## Top gotchas (ranked)
1. **Billing subsidy is provisional** — keep auth swappable (OAuth ↔ API key).
2. **`--bare` silently ignores the OAuth token** — use plain `-p`.
3. **API key beats OAuth token, stale key fails silently** — exactly one credential per container.
4. **`--dangerously-skip-permissions` rejected as root** — run non-root.
5. **Under skip-permissions a malicious repo can exfiltrate `~/.claude`** — don't mount host secrets;
   short-lived scoped tokens; keep the egress firewall on.
6. **One token → shared rate limits** — per-container API key for parallel scale.
7. **OAuth token is inference-only** (no Remote Control).
8. **Tunnel auth is separate** (GitHub/Microsoft device-code); the tunnel binary needs glibc (**Alpine
   unsupported**).
9. **Persist `~/.claude` on a volume** or the agent re-auths every rebuild; isolate per task.

## The combined pattern in the wild ("agent codes in a box, human can join")
Everyone converging on this design does **ephemeral sandbox + clone repo + scoped creds + a human
review/attach surface**, and **none put the long-lived secret in the box:**
- **Claude Code on the web** (Anthropic's own) — isolated managed VM per session; network proxy with
  default allowlist; **GitHub token held OUTSIDE the sandbox, scoped creds issued inside**; clones +
  pushes branches. This *is* the Workspace Host, hosted — borrow the proxy-holds-the-secret pattern.
- **GitHub Copilot coding agent** — per-task cloud sandbox on ephemeral Actions infra → clone → edit/
  build/test → PR (human attaches async via the PR).
- **Cursor background agents** — worktree-mode separate copy so agent edits don't collide; deliver PRs.
- **Devin** — managed env with terminal/editor/browser; human watches + intervenes live.

The borrowable lesson = the `coder` MCP principle, generalized: durable credential stays at the
orchestrator; mint scoped short-lived access for the container.

## Sources
Authentication / Devcontainer / Sandbox-environments — Claude Code Docs (code.claude.com/docs/en/);
Anthropic Help Center "Use the Agent SDK with your Claude plan" (the June-15 pause) + The New Stack
coverage; `anthropics/claude-code/.devcontainer/` + `anthropics/devcontainer-features` (claude-code);
Anthropic Engineering "Claude Code sandboxing"; Docker BuildKit secrets; community wrappers
(textcortex/claude-code-sandbox→Spritz, rvaidya, streamingfast/sbox); Docker + Cloudflare sandbox
templates; dev.to "VS Code Remote Tunnels in a container"; GitHub Copilot coding-agent docs.
