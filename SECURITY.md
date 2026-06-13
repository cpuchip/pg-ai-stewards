# Security — the coder sandbox trust model + hardening review

The substrate's **coder** capability (`coder-mcp`) lets an agent write, build,
test, and run code, and open pull requests. That is real code execution and real
git write access. This document is the trust model and the hardening review you
should read **before enabling the coder** (`docker-compose.coder.yaml`).

Everything else in the substrate — research, councils, personas, the resolver —
is read/think/propose. The coder is the one capability that *acts on the world*,
so it is opt-in and gated behind your explicit decision.

## The one trust boundary that matters: the docker socket

`coder-mcp`'s sandbox manager spawns each coding sandbox as a **sibling
container** by shelling `docker` against the host daemon. For that, the coder
override mounts `/var/run/docker.sock` into the bridge.

**The docker socket is host-root-equivalent.** Any process that can talk to it
can start a container that mounts the host filesystem and escalate to root on the
host. So enabling the coder means: *you trust the substrate (and the models it
dispatches) with root on the host running the bridge.*

This is a deliberate, ratified posture — the "trusted-tool isolation tier": a
shared host kernel is accepted because the substrate is running **your** code on
**your** machine. It is the right tradeoff for a single-operator dev box; it is
**not** a multi-tenant sandbox. Recommendations:

- Run the coder on a **dedicated host** you're willing to grant that trust (the
  "playground box" posture), not your primary workstation or a shared server.
- The default `docker compose up` does **not** mount the socket. You only get it
  by adding `-f docker-compose.coder.yaml`. Leave it off if you don't need code
  execution.
- A future hardening (not shipped) is a rootless/DinD daemon so the sandbox host
  daemon isn't the real host daemon. Tracked, not done.

## Sandbox hardening (defense-in-depth)

The container is the boundary; these reduce blast radius if code inside misbehaves.
Each sandbox (`coder-sb-<work_item>`, image `coder-runtime`) is spawned with:

| Control | Setting | Why |
|---------|---------|-----|
| Capabilities | `--cap-drop=ALL` | no Linux capabilities |
| Privilege escalation | `--security-opt=no-new-privileges` | a setuid binary can't gain privileges |
| User | image runs as **non-root** `coder` (uid 1000) | exec'd commands aren't root-in-container |
| Memory | `--memory=2g` | caps runaway allocation |
| CPU | `--cpus=2` | caps CPU burn |
| PIDs | `--pids-limit=512` | caps fork bombs |
| Lifetime | ephemeral per work_item; torn down after; **reaped** if >2h old | no long-lived state, no leaks |
| Filesystem | the repo worktree on a shared volume subpath; discarded on teardown | the coder never touches your real files |

Network egress is controlled per run (`on` lets the agent pull go mod / npm /
pip; `off` is fully offline via `--network=none`). See the finding below.

## The GitHub token never enters a sandbox

This is the property that lets the coder open PRs without handing code-execution
the keys:

- **clone / commit / push / `gh pr create` all run bridge-side** (in `coder-mcp`'s
  own process), never via `docker exec` into a sandbox.
- `push` supplies `GITHUB_TOKEN` through a **one-shot inline credential helper**
  (`echo password=$GITHUB_TOKEN`) — the token is never written to `.git/config`,
  the worktree, or the sandbox environment. A sandbox can read the *code* in its
  `/work` mount but cannot read the token.
- The bridge can clone private repos (the token reaches them), so the repo
  **deny-list beats the allow-list** — broad allow patterns can't accidentally
  expose a private repo you've denied.

## Repo allow-list — deny by default

`CODER_REPO_ALLOWLIST` is **empty by default, which denies everything**: the
coder cannot clone any repo until you explicitly list it (comma-separated
substrings of the clone URL). `CODER_REPO_DENYLIST` hard-excludes repos
regardless of the allow pattern. The clone helper refuses anything not allowed,
*before* the token is ever used.

## Protected branches + commit hygiene

- Commit/push onto `main`, `master`, or `release/*` is **refused**. The coder
  works on `agent/coder/<work_item>` branches and opens PRs; a human merges
  (the merge is the Hinge).
- `git add -A` would sweep in compiled build artifacts; the committer strips
  executable binaries (mode 100755, git-binary) out of the commit and logs it —
  source/text/assets are untouched.

## Hardening-review findings

What the review found, and the residual decisions:

1. **Docker-socket trust (accepted, documented).** The fundamental boundary
   above. Mitigation is operational (dedicated host), not technical, in v1.
2. **Network egress defaults to ON per build (residual risk).** Builds need to
   pull dependencies, so the code-* pipelines run sandboxes with egress on. A
   malicious/compromised build script in an allow-listed repo could exfiltrate
   over the network. Mitigations: the repo allow-list bounds *what* gets cloned;
   `--network=none` is available for offline runs. **Recommendation:** for
   untrusted repos, run offline and vendor dependencies; consider an egress
   allow-list (proxy) as a future hardening.
3. **Writable rootfs (low risk, by design).** The sandbox rootfs is writable
   (the coder builds in `/tmp` and `/work`). A read-only rootfs + tmpfs is a
   possible future tightening; it's low-value given the container is ephemeral.
4. **`coder` mcp_server ships enabled but inert without the socket.** With the
   default compose (no socket), `coder-mcp` starts and lists its tools but any
   sandbox op fails with a docker error. If you prefer it fully dormant, disable
   the `coder` row in `stewards.mcp_servers` until you opt in. (Open question for
   the operator — see below.)

## Operator checklist before enabling the coder

- [ ] You are on a host you trust the substrate with at the docker-daemon level.
- [ ] `coder-runtime:latest` is built (`docker build -f
      extension/coder-runtime.Dockerfile -t coder-runtime:latest extension`).
- [ ] `CODER_REPO_ALLOWLIST` lists only the repos the coder should touch.
- [ ] `CODER_REPO_DENYLIST` lists any private/sensitive repos to hard-exclude.
- [ ] `GITHUB_TOKEN` (if pushing) is scoped to the minimum repos/permissions.
- [ ] You bring the stack up with `-f docker-compose.coder.yaml` only when you
      want the capability live.

## Reporting

This is pre-release software. If you find a security issue, open an issue on the
repository (or contact the maintainer) before public disclosure.
