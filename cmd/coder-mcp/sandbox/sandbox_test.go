package sandbox

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/cpuchip/pg-ai-stewards/internal/docextract"
)

// Deterministic oracle for the repo clone-policy gate (RC-1: the public-repo
// lane). cloneMode is the security-critical decision — what may be cloned and
// HOW (credentialed allow-list vs anonymous public lane vs refused). No network;
// pure policy. The inverse hypothesis lives in the table: deny still beats all,
// the public lane is https + known-host + no-creds only, and turning the lane
// off returns to allow-list-only.
func TestCloneMode(t *testing.T) {
	cases := []struct {
		name      string
		repo      string
		allowlist string // CODER_REPO_ALLOWLIST
		denylist  string // CODER_REPO_DENYLIST
		publicOff bool   // CODER_PUBLIC_REPOS=false
		hosts     string // CODER_PUBLIC_HOSTS override
		want      string // "", "token", "anon"
	}{
		// --- the public (anonymous) lane: on by default, known hosts only ---
		{name: "public github default", repo: "https://github.com/torvalds/linux", want: "anon"},
		{name: "public gitlab default", repo: "https://gitlab.com/foo/bar", want: "anon"},
		{name: "public codeberg default", repo: "https://codeberg.org/foo/bar", want: "anon"},
		{name: "public .git suffix", repo: "https://github.com/foo/bar.git", want: "anon"},
		{name: "host case-insensitive", repo: "https://GitHub.com/Foo/Bar", want: "anon"},

		// --- the public lane refuses anything that isn't https + known host + creds-free ---
		{name: "unknown host refused", repo: "https://git.internal.corp/secret/repo", want: ""},
		{name: "non-https (ssh) refused", repo: "git@github.com:foo/bar", want: ""},
		{name: "plain http refused", repo: "http://github.com/foo/bar", want: ""},
		{name: "creds in url refused", repo: "https://user:tok@github.com/foo/bar", want: ""},
		{name: "user@ in url refused", repo: "https://user@github.com/foo/bar", want: ""},

		// --- the credentialed allow-list path (unchanged) ---
		{name: "allowlisted -> token", repo: "https://github.com/cpuchip/ai-chattermax", allowlist: "github.com/cpuchip/ai-chattermax", want: "token"},
		{name: "allowlist wins over anon (owned repo uses creds)", repo: "https://github.com/cpuchip/ai-chattermax", allowlist: "github.com/cpuchip/", want: "token"},
		{name: "allowlist lets a private host through (token)", repo: "https://git.internal.corp/team/app", allowlist: "git.internal.corp/team/", want: "token"},

		// --- deny beats everything ---
		{name: "deny beats public", repo: "https://github.com/evil/malware", denylist: "github.com/evil/", want: ""},
		{name: "deny beats allowlist", repo: "https://github.com/cpuchip/secret", allowlist: "github.com/cpuchip/", denylist: "github.com/cpuchip/secret", want: ""},

		// --- token-exfil attacks: an allow pattern in the PATH of a DIFFERENT host
		//     must NOT take the credentialed (token) path (the anchoring fix) ---
		{name: "exfil: allow-pat in path of evil host", repo: "https://evil.com/github.com/cpuchip/x", allowlist: "github.com/cpuchip/", want: ""},
		{name: "exfil: lookalike host with allow-pat in path", repo: "https://github.com.evil.com/github.com/cpuchip/", allowlist: "github.com/cpuchip/", want: ""},
		{name: "exfil: ssh path-smuggle", repo: "git@github.com:github.com/cpuchip/x", allowlist: "github.com/cpuchip/", want: ""},
		{name: "ssh OWNED repo still takes token", repo: "git@github.com:cpuchip/app", allowlist: "github.com/cpuchip/", want: "token"},

		// --- the kill switch + host override ---
		{name: "public lane off -> github refused", repo: "https://github.com/foo/bar", publicOff: true, want: ""},
		{name: "public lane off but allowlisted -> token", repo: "https://github.com/foo/bar", publicOff: true, allowlist: "github.com/foo/", want: "token"},
		{name: "host override narrows", repo: "https://github.com/foo/bar", hosts: "codeberg.org", want: ""},
		{name: "host override allows the listed one", repo: "https://codeberg.org/foo/bar", hosts: "codeberg.org", want: "anon"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// Isolate env per case (t.Setenv auto-restores; "" means unset-equivalent).
			t.Setenv("CODER_REPO_ALLOWLIST", c.allowlist)
			t.Setenv("CODER_REPO_DENYLIST", c.denylist)
			t.Setenv("CODER_PUBLIC_HOSTS", c.hosts)
			if c.publicOff {
				t.Setenv("CODER_PUBLIC_REPOS", "false")
			} else {
				t.Setenv("CODER_PUBLIC_REPOS", "")
			}
			if got := cloneMode(c.repo); got != c.want {
				t.Errorf("cloneMode(%q) = %q, want %q", c.repo, got, c.want)
			}
			// repoAllowed is the yes/no shim — it must agree with cloneMode.
			if got, want := repoAllowed(c.repo), c.want != ""; got != want {
				t.Errorf("repoAllowed(%q) = %v, want %v", c.repo, got, want)
			}
		})
	}
}

func TestRepoHost(t *testing.T) {
	cases := map[string]string{
		"https://github.com/foo/bar":     "github.com",
		"https://github.com":             "github.com",
		"https://GitHub.com/Foo":         "github.com",
		"git@github.com:foo/bar":         "",
		"http://github.com/foo":          "",
		"https://user@github.com/foo":    "",
		"https://user:pass@github.com/x": "",
		"":                               "",
	}
	for in, want := range cases {
		if got := repoHost(in); got != want {
			t.Errorf("repoHost(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHostRootedPath(t *testing.T) {
	cases := map[string]string{
		"https://github.com/cpuchip/app":     "github.com/cpuchip/app",
		"https://github.com":                 "github.com",
		"git@github.com:cpuchip/app":         "github.com/cpuchip/app",
		"git@github.com:github.com/cpuchip/x": "github.com/github.com/cpuchip/x", // smuggle: host stays github.com
		"https://evil.com/github.com/cpuchip/x": "evil.com/github.com/cpuchip/x", // smuggle: host stays evil.com
		"https://user:tok@github.com/x":      "",  // creds-in-url → unparseable for the anchor
		"ssh://git@github.com/cpuchip/app":   "",  // other scheme → not on the credentialed-anchor path
		"":                                   "",
	}
	for in, want := range cases {
		if got := hostRootedPath(in); got != want {
			t.Errorf("hostRootedPath(%q) = %q, want %q", in, got, want)
		}
	}
}

// anonGitEnv must produce a hermetic env: the token gone, the credential/config
// sources neutralized. This is the inverse-hypothesis floor under the
// "anonymous = public-only, no leak" guarantee (HIGH#1: -c credential.helper=
// alone does not clear a system/global helper).
func TestAnonGitEnv(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "ghp_secret")
	t.Setenv("GH_TOKEN", "gh_secret")
	t.Setenv("HOME", "/home/bridge")
	env := anonGitEnv()
	has := func(prefix string) bool {
		for _, kv := range env {
			if len(kv) >= len(prefix) && kv[:len(prefix)] == prefix {
				return true
			}
		}
		return false
	}
	if has("GITHUB_TOKEN=") || has("GH_TOKEN=") {
		t.Error("anonGitEnv must NOT carry GITHUB_TOKEN / GH_TOKEN")
	}
	for _, want := range []string{"GIT_TERMINAL_PROMPT=0", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"} {
		if !has(want) {
			t.Errorf("anonGitEnv must set %s", want)
		}
	}
	if has("HOME=/home/bridge") {
		t.Error("anonGitEnv must override HOME away from the bridge's (no ~/.netrc / ~/.git-credentials)")
	}
}

// Oracle for the dropped-archive unpack (RC-2): a crafted member name must NEVER
// write outside the worktree root. writeMembers re-verifies containment per write
// (defense in depth over safeArchiveName), so we feed it MALICIOUS names directly.
func TestWriteMembers_NoEscape(t *testing.T) {
	root := filepath.Join(t.TempDir(), "wt")
	members := []docextract.Member{
		{Name: "src/main.go", Data: []byte("package main")},
		{Name: "README.md", Data: []byte("# hi")},
		{Name: "../escape.txt", Data: []byte("evil")},        // parent traversal
		{Name: "a/../../escape2.txt", Data: []byte("evil")},  // sneaky traversal
		{Name: "deep/../../../escape3", Data: []byte("evil")}, // multi-level
	}
	n, err := writeMembers(root, members)
	if err != nil {
		t.Fatalf("writeMembers: %v", err)
	}
	// the safe members landed inside root
	for _, ok := range []string{"src/main.go", "README.md"} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(ok))); err != nil {
			t.Errorf("safe member %q should be written: %v", ok, err)
		}
	}
	// NOTHING escaped to the parent (the worktree's sibling space)
	parent := filepath.Dir(root)
	entries, _ := os.ReadDir(parent)
	for _, e := range entries {
		if e.Name() != "wt" {
			t.Errorf("ESCAPE: %q was written outside the worktree root", e.Name())
		}
	}
	if n != 2 {
		t.Errorf("expected exactly 2 safe members written, got %d", n)
	}
}

func TestWithinDir(t *testing.T) {
	root := filepath.FromSlash("/work/wt")
	cases := map[string]bool{
		"/work/wt/src/main.go": true,
		"/work/wt":             true,  // root itself
		"/work/wt/../escape":   false, // parent traversal
		"/work/escape":         false, // outside
		"/work/wtsibling":      false, // prefix-but-not-subdir (the naive HasPrefix trap)
	}
	for p, want := range cases {
		if got := withinDir(root, filepath.FromSlash(p)); got != want {
			t.Errorf("withinDir(%q, %q) = %v, want %v", root, p, got, want)
		}
	}
}

// The BLOCKER the QA found: a sandbox id of "." / ".." must NOT survive sanitize,
// else /worktrees/<id> resolves to /worktrees or / for the destructive rm -rf.
func TestSanitize_ComponentSafe(t *testing.T) {
	cases := map[string]string{
		".":                                    "wi",
		"..":                                   "wi",
		"...":                                  "wi",
		"....//....//":                         "--....--", // leading dots stripped, separators dashed (no "." / "..")
		"":                                     "wi",
		"a/b":                                  "a-b",
		"victim x":                             "victim-x",
		"3b497b0c-a06e-43bd-8231-f095fa775e51": "3b497b0c-a06e-43bd-8231-f095fa775e51", // a real UUID is unchanged
	}
	for in, want := range cases {
		if got := sanitize(in); got != want {
			t.Errorf("sanitize(%q) = %q, want %q", in, got, want)
		}
		// invariant: a sanitized id is never "." or ".." (the catastrophic tokens)
		if got := sanitize(in); got == "." || got == ".." {
			t.Errorf("sanitize(%q) = %q — must never be a dot token", in, got)
		}
	}
}

// worktreeChildOK is the strict-parent guard: only a direct single-component
// child of /worktrees may be rm -rf'd / chown'd.
func TestWorktreeChildOK(t *testing.T) {
	cases := map[string]bool{
		worktreeRoot + "/abc":   true,
		worktreeRoot + "/a-b_c": true,
		worktreeRoot:            false, // the root itself — never
		worktreeRoot + "/.":     false,
		worktreeRoot + "/..":    false,
		worktreeRoot + "/a/b":   false, // multi-component
		"/etc":                  false,
		"/":                     false,
	}
	for p, want := range cases {
		if got := worktreeChildOK(p); got != want {
			t.Errorf("worktreeChildOK(%q) = %v, want %v", p, got, want)
		}
	}
}
