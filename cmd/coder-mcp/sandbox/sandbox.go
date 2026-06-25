// Package sandbox manages per-work_item coding sandboxes: ephemeral Docker
// containers (image coder-runtime) the substrate's coder writes/builds/tests
// inside. It shells out to the `docker` CLI against the host daemon (the
// bridge mounts /var/run/docker.sock) — the "trusted-tool" isolation tier
// ratified in substrate-coding-capability D-CC2 (medium-safe; shared host
// kernel accepted for our own code).
//
// Lifecycle (D-CC8 — owned here, keyed by work_item id):
//
//	Provision(wi)  docker run -d --name coder-sb-<wi> <hardening> <net> coder-runtime sleep infinity
//	Exec(wi, cmd)  docker exec coder-sb-<wi> bash -lc '<cmd>'
//	Teardown(wi)   docker rm -f coder-sb-<wi>
//
// The worktree lives inside the container's own (ephemeral) filesystem and is
// discarded on teardown — the ephemeral-per-task posture from the research.
// The coder never touches the live /workspace mount (proposal §4).
package sandbox

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/cpuchip/pg-ai-stewards/internal/docextract"
)

// Network controls the sandbox's egress. Default is On (D-CC5: open,
// default-on, switchable offline — the agent must pull go mod / npm / pip).
type Network string

const (
	NetOn  Network = "on"  // host daemon default network: egress allowed
	NetOff Network = "off" // --network none: fully offline
)

// Manager provisions and drives coding sandboxes.
type Manager struct {
	Image     string // coder-runtime image (CODER_RUNTIME_IMAGE or default)
	MemLimit  string // --memory (e.g. "2g")
	CPULimit  string // --cpus  (e.g. "2")
	PidsLimit string // --pids-limit
}

// New returns a Manager with the ratified defaults.
func New() *Manager {
	img := os.Getenv("CODER_RUNTIME_IMAGE")
	if img == "" {
		img = "coder-runtime:latest"
	}
	// CV2.2: git/gh run as root (bridge) over coder-uid-owned worktrees; disable
	// git's dubious-ownership guard for our own worktrees so commit/push/gh work
	// (the worktrees are ours — the guard is a multi-user safety net we don't need).
	_ = exec.Command("git", "config", "--global", "--add", "safe.directory", "*").Run()
	return &Manager{Image: img, MemLimit: "2g", CPULimit: "2", PidsLimit: "512"}
}

// containerName is the deterministic per-work_item container name.
func containerName(wi string) string {
	return "coder-sb-" + sanitize(wi)
}

// sanitize keeps the work_item id docker-name-safe ([a-zA-Z0-9_.-]) AND
// component-safe: it strips leading dots so a sandbox id can never resolve to
// "." or ".." — which would otherwise make /worktrees/<id> escape to /worktrees
// or / for the destructive rm -rf / chown in CloneRepo / UnpackArchiveToWorktree.
// (No real work_item id — a UUID — starts with a dot.)
func sanitize(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '_', r == '.', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	out := strings.TrimLeft(b.String(), ".") // "." / ".." / "...x" → safe; UUIDs unaffected
	if out == "" {
		out = "wi"
	}
	return out
}

// docker runs a docker subcommand, returning combined output.
func docker(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "docker", args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// Provision starts an idle sandbox container for wi. Idempotent-ish: it tears
// down any pre-existing container of the same name first. When worktree is
// true, the shared coder-worktrees volume (subpath wi) is mounted at /work —
// so the coder tools operate on a repo the bridge cloned there (CV2.1). The
// caller must CloneRepo first (the subpath must exist).
func (m *Manager) Provision(ctx context.Context, wi string, net Network, worktree bool) error {
	// Operator kill-switch: CODER_SANDBOX_NETWORK=off|none|false forces EVERY
	// sandbox fully offline (--network=none), regardless of what the pipeline
	// requested. Egress is on by default so the agent can pull go mod / npm /
	// pip; set this for untrusted repos or an air-gapped posture.
	switch strings.ToLower(strings.TrimSpace(os.Getenv("CODER_SANDBOX_NETWORK"))) {
	case "off", "none", "false", "0":
		net = NetOff
	}
	_ = m.Teardown(ctx, wi) // clear any leftover; ignore "not found"
	args := []string{
		"run", "-d", "--name", containerName(wi),
		// Hardening (defense-in-depth; the container is the real boundary).
		"--cap-drop=ALL",
		"--security-opt=no-new-privileges",
		"--memory=" + m.MemLimit,
		"--cpus=" + m.CPULimit,
		"--pids-limit=" + m.PidsLimit,
		"--label=stewards.coder=1",
		"--label=stewards.work_item=" + sanitize(wi),
	}
	if worktree {
		args = append(args, "--mount",
			fmt.Sprintf("type=volume,source=%s,target=/work,volume-subpath=%s", worktreeVol, sanitize(wi)))
	}
	if net == NetOff {
		args = append(args, "--network=none")
	}
	args = append(args, m.Image, "sleep", "infinity")
	if out, err := docker(ctx, args...); err != nil {
		return fmt.Errorf("provision %s: %w\n%s", wi, err, out)
	}
	return nil
}

// --- coder-v2: repo worktrees (CV2.1) ---

const (
	worktreeVol  = "coder-worktrees" // shared volume; bridge + sandbox both mount it
	worktreeRoot = "/worktrees"      // the bridge's mount point of worktreeVol
)

// defaultPublicHosts — the git hosts the anonymous public-repo lane accepts.
// Overridable via CODER_PUBLIC_HOSTS (comma-separated). Kept to well-known
// public forges so "explore/build off a public repo" can't be pointed at an
// arbitrary internal host.
var defaultPublicHosts = []string{
	"github.com", "gitlab.com", "bitbucket.org", "codeberg.org", "git.sr.ht", "gitea.com",
}

func publicHosts() []string {
	if v := strings.TrimSpace(os.Getenv("CODER_PUBLIC_HOSTS")); v != "" {
		var out []string
		for _, h := range strings.Split(v, ",") {
			if h = strings.TrimSpace(h); h != "" {
				out = append(out, h)
			}
		}
		return out
	}
	return defaultPublicHosts
}

// publicLaneEnabled — the anonymous public-repo lane is ON by default (clone a
// PUBLIC repo to research or build off, no credentials). Set CODER_PUBLIC_REPOS
// to false/off/0/no to disable it (back to allow-list-only).
func publicLaneEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("CODER_PUBLIC_REPOS"))) {
	case "false", "off", "0", "no":
		return false
	}
	return true
}

// repoHost extracts the host from an https URL (lowercased). "" for anything
// that isn't a plain https URL — ssh/git/http forms never take the public lane.
func repoHost(repo string) string {
	const p = "https://"
	if !strings.HasPrefix(repo, p) {
		return ""
	}
	rest := repo[len(p):]
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		rest = rest[:i]
	}
	if strings.Contains(rest, "@") { // user@ / user:pass@ — creds-in-URL not allowed on the public lane
		return ""
	}
	return strings.ToLower(rest)
}

// publicHostAllowed reports whether repo is an https URL to an allowed public host.
func publicHostAllowed(repo string) bool {
	h := repoHost(repo)
	if h == "" {
		return false
	}
	for _, allowed := range publicHosts() {
		if h == strings.ToLower(allowed) {
			return true
		}
	}
	return false
}

// hostRootedPath parses repo into a canonical "host/path" form for ANCHORED
// allow-list matching, so an allow pattern like "github.com/cpuchip/" can never
// be smuggled into the PATH of a different host (e.g. https://evil.com/github.com/
// cpuchip/x) and thereby route an attacker URL onto the credentialed clone path.
// Accepts https://host/path and scp-style [user@]host:path. Returns "" for a
// creds-bearing https URL or anything it can't confidently parse — those never
// match the allow-list.
func hostRootedPath(repo string) string {
	r := strings.TrimSpace(repo)
	if strings.HasPrefix(r, "https://") {
		h := repoHost(r) // "" if creds-in-url / malformed
		if h == "" {
			return ""
		}
		rest := r[len("https://"):]
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			return h + "/" + strings.TrimLeft(rest[i+1:], "/")
		}
		return h
	}
	if strings.Contains(r, "://") {
		return "" // some other scheme (http/git/ssh://) — not on the credentialed-anchor path
	}
	// scp-style git@host:owner/repo (ssh; key-auth, no creds-in-url leak)
	if at := strings.IndexByte(r, '@'); at >= 0 {
		r = r[at+1:]
	}
	if c := strings.IndexByte(r, ':'); c > 0 {
		host := strings.ToLower(r[:c])
		if host == "" || strings.Contains(host, "/") {
			return ""
		}
		return host + "/" + strings.TrimLeft(r[c+1:], "/")
	}
	return ""
}

// cloneMode decides whether + HOW repo may be cloned. DENY beats everything.
//
//	""      refused
//	"token" allow-listed (CODER_REPO_ALLOWLIST) — the credentialed path; the
//	        bridge's GITHUB_TOKEN can reach private/owned repos here. Matched
//	        ANCHORED to the host-rooted path (no substring smuggling).
//	"anon"  the public lane — anonymous clone, NO credentials, known host only.
//	        A private repo therefore fails to clone (auth required), which is
//	        exactly the "public-only" guarantee — no prior knowledge of repo
//	        visibility is needed.
//
// The token path stays deny-by-default (empty CODER_REPO_ALLOWLIST → no
// credentialed clones). The anon path is independent and on by default.
func cloneMode(repo string) string {
	if deny := os.Getenv("CODER_REPO_DENYLIST"); deny != "" {
		for _, pat := range strings.Split(deny, ",") {
			if pat = strings.TrimSpace(pat); pat != "" && strings.Contains(repo, pat) {
				return "" // deny beats all; substring is fine here — it only ever REFUSES
			}
		}
	}
	// allow-list (credentialed) — anchored to the host-rooted form so a pattern
	// can't match inside another host's path (the token-exfil hole).
	if rooted := hostRootedPath(repo); rooted != "" {
		if list := os.Getenv("CODER_REPO_ALLOWLIST"); list != "" {
			for _, pat := range strings.Split(list, ",") {
				if pat = strings.TrimSpace(pat); pat != "" && strings.HasPrefix(rooted, pat) {
					return "token"
				}
			}
		}
	}
	if publicLaneEnabled() && publicHostAllowed(repo) {
		return "anon"
	}
	return ""
}

// anonGitEnv builds a HERMETIC environment for an anonymous public clone: it
// drops GITHUB_TOKEN/GH_TOKEN from the process and disables every ambient git
// credential + URL-rewrite source — the system config (GIT_CONFIG_NOSYSTEM=1),
// the global config (GIT_CONFIG_GLOBAL=/dev/null → no credential.helper /
// url.insteadOf / http.extraHeader), and ~/.netrc + ~/.git-credentials (a HOME
// that has neither). So a public clone can offer NO ambient credential to the
// host it dials, and an approved host can't be transparently rewritten to
// another. This is the real enforcement of "anonymous = public-only" — an empty
// `-c credential.helper=` alone does NOT clear a system/global helper.
func anonGitEnv() []string {
	out := make([]string, 0, len(os.Environ())+4)
	for _, kv := range os.Environ() {
		switch {
		case strings.HasPrefix(kv, "GITHUB_TOKEN="), strings.HasPrefix(kv, "GH_TOKEN="),
			strings.HasPrefix(kv, "HOME="), strings.HasPrefix(kv, "GIT_CONFIG_GLOBAL="),
			strings.HasPrefix(kv, "GIT_CONFIG_NOSYSTEM="), strings.HasPrefix(kv, "GIT_TERMINAL_PROMPT="):
			continue // replaced below (or stripped)
		}
		out = append(out, kv)
	}
	return append(out,
		"GIT_TERMINAL_PROMPT=0",      // never prompt (a private repo fails fast)
		"GIT_CONFIG_NOSYSTEM=1",      // ignore /etc/gitconfig (system helper / insteadOf)
		"GIT_CONFIG_GLOBAL=/dev/null", // ignore ~/.gitconfig (global helper / insteadOf / extraHeader)
		"HOME=/nonexistent-stewards-anon", // no ~/.netrc / ~/.git-credentials
	)
}

// repoAllowed reports whether repo is clonable by either path (kept for callers
// that just need a yes/no).
func repoAllowed(repo string) bool { return cloneMode(repo) != "" }

// CloneRepo clones a clonable repo into the per-work_item worktree
// (/worktrees/<wi> on the shared volume) and chowns it to the sandbox's coder
// uid (1000). Runs in the bridge. For the credentialed ("token") path the
// GitHub token (CV2.2) lives here, never in the sandbox; for the public ("anon")
// path NO credential helper is used, so only public repos clone.
func (m *Manager) CloneRepo(ctx context.Context, wi, repo, branch string) error {
	mode := cloneMode(repo)
	if mode == "" {
		return fmt.Errorf("repo %q not clonable: not in CODER_REPO_ALLOWLIST and not a public repo on an allowed host "+
			"(CODER_PUBLIC_HOSTS=%s; set CODER_PUBLIC_REPOS=false to disable the public lane)", repo, strings.Join(publicHosts(), ","))
	}
	dir := worktreeRoot + "/" + sanitize(wi)
	if !worktreeChildOK(dir) { // strict-parent guard (defense in depth — never rm -rf outside /worktrees/<id>)
		return fmt.Errorf("refusing unsafe worktree root %q for sandbox id %q", dir, wi)
	}
	_ = exec.CommandContext(ctx, "rm", "-rf", dir).Run() // fresh clone
	args := []string{}
	if mode == "anon" {
		// Public lane: never offer a credential helper to a public host, so a
		// token can't leak and a PRIVATE repo simply fails (auth required).
		args = append(args, "-c", "credential.helper=")
	}
	args = append(args, "clone", "--depth", "50")
	if branch != "" {
		args = append(args, "--branch", branch)
	}
	args = append(args, repo, dir)
	cmd := exec.CommandContext(ctx, "git", args...)
	if mode == "anon" {
		// Hermetic env: no token, no system/global git config, no ~/.netrc — so the
		// public clone offers NO ambient credential and the host can't be rewritten.
		cmd.Env = anonGitEnv()
	}
	var buf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &buf, &buf
	if err := cmd.Run(); err != nil {
		if mode == "anon" {
			return fmt.Errorf("clone %s (public/anonymous): %w — is it a PUBLIC repo? (private repos need CODER_REPO_ALLOWLIST + a token)\n%s", repo, err, buf.String())
		}
		return fmt.Errorf("clone %s: %w\n%s", repo, err, buf.String())
	}
	if out, err := exec.CommandContext(ctx, "chown", "-R", "1000:1000", dir).CombinedOutput(); err != nil {
		return fmt.Errorf("chown worktree %s: %w\n%s", dir, err, out)
	}
	return nil
}

// UnpackArchiveToWorktree safely unpacks an archive's members into the per-
// work_item worktree (/worktrees/<wi>) for READ-ONLY exploration — the dropped-
// archive sibling of CloneRepo (RC-2: explore a dropped code repo without
// embedding it). docextract.Unpack applies the hardened zip-slip / bomb /
// symlink guards in memory; writeMembers re-verifies containment per write
// (defense in depth) so a crafted member name can never escape the worktree.
// Runs bridge-side; the content is never executed (research_codebase is
// read-only — no shell/exec/git). Returns the number of files written.
func (m *Manager) UnpackArchiveToWorktree(ctx context.Context, wi, filename string, data []byte) (int, error) {
	root := worktreeRoot + "/" + sanitize(wi)
	// Strict-parent guard: never rm -rf / chown anything that isn't a direct child
	// of /worktrees (defense in depth under the sanitize "." / ".." fix — the
	// destructive ops must not escape even if an id somehow slipped through).
	if !worktreeChildOK(root) {
		return 0, fmt.Errorf("refusing unsafe worktree root %q for sandbox id %q", root, wi)
	}
	// The dropped source is already bounded to 25MB by the chat upload cap; keep
	// the on-disk expansion tighter than the generic 200MB default.
	caps := docextract.DefaultArchiveCaps()
	caps.MaxTotalUncompressed = 128 << 20
	members, _, err := docextract.Unpack(ctx, data, filename, caps)
	if err != nil {
		return 0, fmt.Errorf("unpack archive %q: %w", filename, err)
	}
	// Structural malware scan per member (no ClamAV DB bridge-side → structural
	// only), mirroring the doc_extract quarantine floor: a member flagged malicious
	// is skipped, not written. The explore sandbox is read-only (no exec), so this
	// is defense in depth, not the sole barrier.
	safe := members[:0]
	for _, mem := range members {
		if docextract.Scan(ctx, mem.Data, mem.Name, "").Verdict == docextract.VerdictMalicious {
			continue
		}
		safe = append(safe, mem)
	}
	members = safe
	_ = exec.CommandContext(ctx, "rm", "-rf", root).Run() // fresh
	n, werr := writeMembers(root, members)
	if werr != nil {
		return n, werr
	}
	if n == 0 {
		return 0, fmt.Errorf("archive %q had no usable members to explore", filename)
	}
	// chown to the sandbox coder uid so the mounted sandbox can read the tree.
	if out, err := exec.CommandContext(ctx, "chown", "-R", "1000:1000", root).CombinedOutput(); err != nil {
		return n, fmt.Errorf("chown worktree %s: %w\n%s", root, err, out)
	}
	return n, nil
}

// worktreeChildOK reports whether root is a direct, single-component child of
// worktreeRoot, so a destructive rm -rf / chown can never escape /worktrees even
// if a sandbox id slipped past sanitize. Defense in depth under the sanitize fix.
func worktreeChildOK(root string) bool {
	rel, err := filepath.Rel(worktreeRoot, root)
	if err != nil {
		return false
	}
	return rel != "." && rel != ".." && !strings.HasPrefix(rel, "..") && rel == filepath.Base(rel)
}

// writeMembers writes vetted archive members under root, re-verifying that each
// resolved path stays WITHIN root before writing (belt-and-suspenders over
// safeArchiveName). Anything that would escape is skipped, not written. Pure +
// root-parameterized so the zip-slip guard is unit-testable without /worktrees.
func writeMembers(root string, members []docextract.Member) (int, error) {
	if err := os.MkdirAll(root, 0o755); err != nil {
		return 0, fmt.Errorf("mkdir worktree %s: %w", root, err)
	}
	n := 0
	for _, mem := range members {
		dest := filepath.Join(root, filepath.FromSlash(mem.Name))
		if !withinDir(root, dest) {
			continue // would escape the worktree — refuse (never reached given safeArchiveName, but enforced anyway)
		}
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			continue
		}
		if err := os.WriteFile(dest, mem.Data, 0o644); err != nil {
			continue
		}
		n++
	}
	return n, nil
}

// withinDir reports whether p resolves to a path inside root (no escape).
func withinDir(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil {
		return false
	}
	return rel != ".." &&
		!strings.HasPrefix(rel, ".."+string(filepath.Separator)) &&
		!filepath.IsAbs(rel)
}

// WorktreePath is the bridge-side path of wi's repo worktree.
func (m *Manager) WorktreePath(wi string) string { return worktreeRoot + "/" + sanitize(wi) }

func (m *Manager) HasWorktree(wi string) bool {
	_, err := os.Stat(m.WorktreePath(wi) + "/.git")
	return err == nil
}

// gitC runs `git -C dir args...` (combined output). Inherits coder-mcp's env,
// which carries GITHUB_TOKEN — these run bridge-side, never in the sandbox.
func gitC(ctx context.Context, dir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir, "-c", "safe.directory=*"}, args...)...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func protectedBranch(b string) bool {
	return b == "main" || b == "master" || strings.HasPrefix(b, "release/")
}

// Commit stages all changes in wi's worktree onto `branch` (created if absent)
// and commits. Local op — no token. Returns the new SHA + the branch.
func (m *Manager) Commit(ctx context.Context, wi, message, branch string) (sha, br string, err error) {
	dir := m.WorktreePath(wi)
	if !m.HasWorktree(wi) {
		return "", "", fmt.Errorf("no repo worktree for %q — start the sandbox with repo=", wi)
	}
	if branch == "" {
		branch = "agent/coder/" + sanitize(wi)
	}
	if protectedBranch(branch) {
		return "", "", fmt.Errorf("refusing to commit onto protected branch %q", branch)
	}
	if out, e := gitC(ctx, dir, "checkout", "-B", branch); e != nil {
		return "", "", fmt.Errorf("checkout %s: %w\n%s", branch, e, out)
	}
	if out, e := gitC(ctx, dir, "add", "-A"); e != nil {
		return "", "", fmt.Errorf("add: %w\n%s", e, out)
	}
	// Build-artifact hygiene: `git add -A` sweeps in compiled binaries a build
	// step left in the tree (e.g. `go build` writes an executable named after the
	// module — `chatroom` — which a stock Go .gitignore does not catch). Unstage
	// them so they never reach the PR. Source/text/scripts and non-executable
	// binary assets (images, fixtures) are untouched.
	if stripped := stripBuildArtifacts(ctx, dir); len(stripped) > 0 {
		fmt.Fprintf(os.Stderr, "coder_commit: kept build artifact(s) out of the commit (compiled binaries are not committed): %s\n",
			strings.Join(stripped, ", "))
	}
	// Commit author is configurable; generic defaults keep it operator-neutral.
	authorName := os.Getenv("CODER_GIT_AUTHOR_NAME")
	if authorName == "" {
		authorName = "pg-ai-stewards coder"
	}
	authorEmail := os.Getenv("CODER_GIT_AUTHOR_EMAIL")
	if authorEmail == "" {
		authorEmail = "pg-ai-stewards-coder@users.noreply.github.com"
	}
	msg := message + "\n\nCo-Authored-By: " + authorName + " <" + authorEmail + ">\n"
	if out, e := gitC(ctx, dir, "-c", "user.name="+authorName,
		"-c", "user.email="+authorEmail, "commit", "-m", msg); e != nil {
		return "", "", fmt.Errorf("commit: %w\n%s", e, out)
	}
	out, _ := gitC(ctx, dir, "rev-parse", "HEAD")
	return strings.TrimSpace(out), branch, nil
}

// stripBuildArtifacts unstages compiled-binary build outputs that `git add -A`
// swept in. It targets the precise signature — a file git sees as BINARY whose
// index mode is 100755 (the executable bit) — which is what `go build` (and
// other compilers) produce, while source, text, scripts, and non-executable
// binary assets (images/fixtures, mode 100644) are left staged. Returns the
// paths it unstaged so the caller can log them (the guard is never silent).
func stripBuildArtifacts(ctx context.Context, dir string) []string {
	numstat, err := gitC(ctx, dir, "diff", "--cached", "--numstat")
	if err != nil {
		return nil
	}
	var stripped []string
	for _, line := range strings.Split(strings.TrimSpace(numstat), "\n") {
		// Binary files render as "-\t-\t<path>" (added/deleted line counts are "-").
		fields := strings.SplitN(line, "\t", 3)
		if len(fields) != 3 || fields[0] != "-" || fields[1] != "-" {
			continue
		}
		path := fields[2]
		mode, e := gitC(ctx, dir, "ls-files", "--stage", "--", path)
		if e != nil || !strings.HasPrefix(strings.TrimSpace(mode), "100755") {
			continue // not an executable binary — leave it staged (asset, not artifact)
		}
		if _, e := gitC(ctx, dir, "reset", "-q", "--", path); e == nil {
			stripped = append(stripped, path)
		}
	}
	return stripped
}

// Push pushes branch to origin. The GitHub token (coder-mcp's env) is supplied
// via a one-shot credential helper — never persisted in .git/config or the
// worktree (so the sandbox can't read it). Runs bridge-side.
func (m *Manager) Push(ctx context.Context, wi, branch string) (string, error) {
	if branch == "" || protectedBranch(branch) {
		return "", fmt.Errorf("refusing to push protected/empty branch %q", branch)
	}
	const helper = `!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f`
	out, err := gitC(ctx, m.WorktreePath(wi),
		"-c", "credential.helper=", "-c", "credential.helper="+helper,
		"push", "--set-upstream", "origin", branch)
	if err != nil {
		return "", fmt.Errorf("push %s: %w\n%s", branch, err, out)
	}
	return out, nil
}

// OpenPR opens a pull request via gh (uses GITHUB_TOKEN from env). Bridge-side.
func (m *Manager) OpenPR(ctx context.Context, wi, title, body, base string, draft bool) (string, error) {
	if base == "" {
		base = "main"
	}
	// Pass --head explicitly. gh's "current branch" auto-detect unreliably
	// reports "you must first push the current branch" in this bridge-side
	// worktree setup even after a successful push; resolving the checked-out
	// branch and passing it as --head sidesteps that detection.
	head, herr := gitC(ctx, m.WorktreePath(wi), "rev-parse", "--abbrev-ref", "HEAD")
	if herr != nil {
		return "", fmt.Errorf("resolve head branch: %w\n%s", herr, head)
	}
	head = strings.TrimSpace(head)
	args := []string{"pr", "create", "--base", base, "--head", head, "--title", title, "--body", body}
	if draft {
		args = append(args, "--draft")
	}
	cmd := exec.CommandContext(ctx, "gh", args...)
	cmd.Dir = m.WorktreePath(wi)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("gh pr create: %w\n%s", err, out)
	}
	return strings.TrimSpace(string(out)), nil
}

// ExecResult is the outcome of a sandbox command.
type ExecResult struct {
	Output   string
	ExitCode int
}

// Exec runs a shell command inside wi's sandbox (login shell, so PATH carries
// go/node/python). Returns the command's exit code separately from a docker
// transport error.
func (m *Manager) Exec(ctx context.Context, wi, command string) (ExecResult, error) {
	cmd := exec.CommandContext(ctx, "docker", "exec", containerName(wi), "bash", "-lc", command)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	res := ExecResult{Output: buf.String()}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			res.ExitCode = ee.ExitCode()
			return res, nil // command failed inside the box — not a transport error
		}
		return res, fmt.Errorf("exec %s: %w\n%s", wi, err, buf.String())
	}
	return res, nil
}

// WriteFile writes content to an absolute path inside wi's sandbox, creating
// parent directories. Uses stdin so content needs no shell escaping.
func (m *Manager) WriteFile(ctx context.Context, wi, path, content string) error {
	cmd := exec.CommandContext(ctx, "docker", "exec", "-i", containerName(wi),
		"sh", "-c", `mkdir -p "$(dirname "$0")" && cat > "$0"`, path)
	cmd.Stdin = strings.NewReader(content)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("write %s: %w\n%s", path, err, buf.String())
	}
	return nil
}

// ReadFile reads an absolute path from wi's sandbox (argv form — no shell, so
// the path needs no quoting).
func (m *Manager) ReadFile(ctx context.Context, wi, path string) (string, error) {
	cmd := exec.CommandContext(ctx, "docker", "exec", containerName(wi), "cat", "--", path)
	var out, errBuf bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			return "", fmt.Errorf("read %s: %s", path, strings.TrimSpace(errBuf.String()))
		}
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	return out.String(), nil
}

// ReadFileBytes reads an absolute path from wi's sandbox as RAW bytes (binary-
// safe — for generated artifacts like pdf/xlsx/zip that ReadFile's string path
// would mangle). Arc B doc-build: the export-artifact tool pulls the generated
// file out this way.
func (m *Manager) ReadFileBytes(ctx context.Context, wi, path string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "docker", "exec", containerName(wi), "cat", "--", path)
	var out, errBuf bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("read %s: %s", path, strings.TrimSpace(errBuf.String()))
		}
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return out.Bytes(), nil
}

// Exists reports whether wi's sandbox container is present.
func (m *Manager) Exists(ctx context.Context, wi string) (bool, error) {
	out, err := docker(ctx, "ps", "-aq", "--filter", "name=^"+containerName(wi)+"$")
	if err != nil {
		return false, fmt.Errorf("exists %s: %w\n%s", wi, err, out)
	}
	return strings.TrimSpace(out) != "", nil
}

// Teardown removes wi's sandbox container (force, ignores not-found).
func (m *Manager) Teardown(ctx context.Context, wi string) error {
	out, err := docker(ctx, "rm", "-f", containerName(wi))
	if err != nil && !strings.Contains(out, "No such container") {
		return fmt.Errorf("teardown %s: %w\n%s", wi, err, out)
	}
	return nil
}

// SandboxInfo describes a coder sandbox container.
type SandboxInfo struct {
	Name     string    `json:"name"`
	WorkItem string    `json:"work_item,omitempty"`
	Created  time.Time `json:"created"`
	AgeMin   int       `json:"age_minutes"`
}

// ListSandboxes lists all coder sandboxes (label stewards.coder=1) with age.
func (m *Manager) ListSandboxes(ctx context.Context) ([]SandboxInfo, error) {
	out, err := docker(ctx, "ps", "-a", "--filter", "label=stewards.coder=1",
		"--format", "{{.Names}}\t{{.CreatedAt}}\t{{.Label \"stewards.work_item\"}}")
	if err != nil {
		return nil, fmt.Errorf("list sandboxes: %w\n%s", err, out)
	}
	var infos []SandboxInfo
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 3)
		info := SandboxInfo{Name: parts[0]}
		if len(parts) == 3 {
			info.WorkItem = parts[2]
		}
		// docker's CreatedAt format, e.g. "2026-06-03 22:20:01 +0000 UTC".
		if len(parts) >= 2 {
			if t, perr := time.Parse("2006-01-02 15:04:05 -0700 MST", parts[1]); perr == nil {
				info.Created = t
				info.AgeMin = int(time.Since(t).Minutes())
			}
		}
		infos = append(infos, info)
	}
	return infos, nil
}

// ReapSandboxes force-removes sandboxes older than maxAge (the reaper for
// leaked/abandoned sandboxes). Returns the names removed.
func (m *Manager) ReapSandboxes(ctx context.Context, maxAge time.Duration) ([]string, error) {
	infos, err := m.ListSandboxes(ctx)
	if err != nil {
		return nil, err
	}
	var removed []string
	for _, info := range infos {
		if info.Created.IsZero() || time.Since(info.Created) <= maxAge {
			continue
		}
		if out, derr := docker(ctx, "rm", "-f", info.Name); derr == nil ||
			strings.Contains(out, "No such container") {
			removed = append(removed, info.Name)
		}
	}
	return removed, nil
}
