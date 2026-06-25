# 2026-06-24 — RC-1: explore (+ build off) public repos, no DB embedding

Michael ratified the import/clone arc (F1/F2/F3) after the zip-timeout diagnosis,
then on RC-1: "Lets widen it a bit, mostly so we can do research and build off of
public repos. I think no db embeddings is good for that. lets go." With the
security defaults (https / known hosts / public-only / no creds / read-only sandbox,
runs local).

## The key finding: the machinery already existed

The explore-in-sandbox path was already built — `research_codebase` (cheap
sub-agent → `coder_sandbox_start` → grep/read, read-only, no write/exec/git,
file:line citations) + `git_clone`. The only reason a public repo "couldn't
clone" was the **repo allow-list** (`CODER_REPO_ALLOWLIST`, deny-by-default,
default just ai-chattermax). So RC-1 was three small pieces, not a new engine:

1. **The public-repo clone lane** (`cmd/coder-mcp/sandbox/sandbox.go`):
   `cloneMode(repo)` → `"token"` (allow-listed, credentialed) / `"anon"` (public
   host, anonymous clone) / `""` (refused). The anon lane is **self-enforcing
   public-only** — a private repo fails to clone anonymously, so no prior
   knowledge of visibility is needed. ON by default; `CODER_PUBLIC_REPOS=false`
   disables it; `CODER_PUBLIC_HOSTS` overrides the host set.
2. **The grant** (`53-explore-repos.sql` + lib.rs + Dockerfile COPY):
   `research_codebase` → `work-item-chat` (it wasn't granted; the door existed,
   the chat couldn't reach it). NO DB embedding — exploration stays in the sandbox.
3. **`/explore <url>`** slash command in the chat composer.

## The security QA found TWO real vulnerabilities — both fixed

The 3-lens adversarial QA (`wf_76537cf2`) earned its keep on a security-sensitive
change. Two were genuine, reproduced holes:

- **HIGH — `-c credential.helper=` does NOT neutralize ambient credentials.**
  git merges config system→global→`-c`; an empty helper only clears entries
  *before* it, so a SYSTEM/GLOBAL helper (GCM, etc.) survives. On a bridge with a
  credential helper, the "anonymous" lane would still offer the bridge's token to
  the host it dials — breaking BOTH the no-leak and the public-only guarantees.
  **Fix:** `anonGitEnv()` — a hermetic env: GITHUB_TOKEN/GH_TOKEN dropped,
  `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, a HOME with no
  `~/.netrc`/`~/.git-credentials`. This also closes the MEDIUM `url.insteadOf` /
  `http.extraHeader` / netrc rewrite vectors in one move.
- **HIGH — allow-list matched `strings.Contains` over the WHOLE URL** (a
  pre-existing bug RC-1 newly made chat-reachable): `https://evil.com/github.com/
  cpuchip/x` contains `github.com/cpuchip/` in its PATH → took the CREDENTIALED
  path → token exfiltrated to evil.com. **Fix:** `hostRootedPath()` + anchored
  `HasPrefix` match — the pattern must match from the real host, so a path can't
  smuggle a different host onto the token path.

Both now have inverse-hypothesis oracle cases (`sandbox_test.go`: exfil URLs
refused, `anonGitEnv` strips the token + sets the hermetic vars, `hostRootedPath`
parsing). Also fixed: **HIGH — bare name `/explore react` → cpuchip/react → 404**
(research_codebase now refuses a bare name with a clear "give owner/repo or a
full URL"), and **HIGH — SECURITY.md/.env.example claimed "deny-all by default"**
(rewritten to document the public lane, the off-switch, and the widened
build-script-exfil residual risk).

## The blast-radius call (documented, not silently shipped)

`CloneRepo` is shared, so default-ON widens what the EXEC-capable code-* flows
could clone. Decision: keep the lane ON (Michael's intent + the EXPLORE path is
exec-DENIED at the perm layer, so chat→explore can't run a build script). The
"build off a public repo" (exec) path is operator/steward-initiated, not an
attacker primitive — but it IS a widened residual risk, so SECURITY.md §2 now
says so plainly and points to `CODER_PUBLIC_REPOS=false` + `CODER_SANDBOX_NETWORK=off`.

## Verified

Policy oracle (`go test ./cmd/coder-mcp/sandbox`) green incl. all exfil/hermetic
cases; live anonymous clone proven (octocat/Hello-World clones, a nonexistent/
private repo fails fast — no credential hang); go vet + build both binaries;
frontend builds; virgin-smoke 00→53 green (OK 43 grant). **Deferred:** the full
chat→explore e2e (needs the coder overlay + a model + network — the work rig has
it) and the two LOW nits (a literal `:443` port falls off the anon lane;
`http://` only takes the token path). RC-2 (route a dropped code archive to
explore) + RC-3 (async corpus import) are the next phases.

## Lesson

On a security-sensitive widening, the adversarial pass is not optional — a green
functional oracle said "works," and it DID work, while quietly carrying a
token-exfiltration primitive and a credential-leak hole. "It clones the public
repo" is not the same as "it clones ONLY public repos with NO credential." Both
holes were invisible to the happy path and the policy table I first wrote; the
reproduced attacks found them.
