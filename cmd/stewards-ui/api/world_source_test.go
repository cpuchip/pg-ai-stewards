package api

import "testing"

func TestRepoWebURL(t *testing.T) {
	cases := []struct{ in, want string }{
		// the two forms called out in #301 item 5
		{"git@github.com:cpuchip/lodestar.git", "https://github.com/cpuchip/lodestar"},
		{"https://github.com/cpuchip/lodestar.git", "https://github.com/cpuchip/lodestar"},
		// without .git
		{"git@github.com:cpuchip/lodestar", "https://github.com/cpuchip/lodestar"},
		{"https://github.com/cpuchip/lodestar", "https://github.com/cpuchip/lodestar"},
		// ssh:// and git:// scheme forms
		{"ssh://git@github.com/cpuchip/lodestar.git", "https://github.com/cpuchip/lodestar"},
		{"git://github.com/cpuchip/lodestar.git", "https://github.com/cpuchip/lodestar"},
		// gitlab nested groups (multi-segment path)
		{"git@gitlab.com:group/sub/repo.git", "https://gitlab.com/group/sub/repo"},
		{"https://gitlab.com/group/sub/repo.git", "https://gitlab.com/group/sub/repo"},
		// bitbucket
		{"git@bitbucket.org:team/repo.git", "https://bitbucket.org/team/repo"},
		// host with a port, credentials in the https url
		{"https://user@example.com:8443/x/y.git", "https://example.com/x/y"},
		// self-hosted host is preserved
		{"git@git.internal.corp:infra/thing.git", "https://git.internal.corp/infra/thing"},
		// graceful degrade — nothing to link
		{"", ""},
		{"   ", ""},
		{"not-a-remote", ""},
		{"git@github.com:", ""},
	}
	for _, c := range cases {
		if got := repoWebURL(c.in); got != c.want {
			t.Errorf("repoWebURL(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRepoBlobURL(t *testing.T) {
	cases := []struct {
		origin, ref, file, want string
	}{
		// git@ + https forms, real file path
		{"git@github.com:cpuchip/lodestar.git", "main", "internal/graph/graph.go",
			"https://github.com/cpuchip/lodestar/blob/main/internal/graph/graph.go"},
		{"https://github.com/cpuchip/lodestar.git", "v1.2", "cmd/main.go",
			"https://github.com/cpuchip/lodestar/blob/v1.2/cmd/main.go"},
		// ref defaults to main when unset
		{"git@github.com:cpuchip/lodestar.git", "", "cmd/main.go",
			"https://github.com/cpuchip/lodestar/blob/main/cmd/main.go"},
		// HEAD is a valid ref and is kept (github resolves /blob/HEAD to default branch)
		{"https://github.com/cpuchip/lodestar.git", "HEAD", "go.mod",
			"https://github.com/cpuchip/lodestar/blob/HEAD/go.mod"},
		// leading slash on the file path is trimmed
		{"https://github.com/cpuchip/lodestar.git", "main", "/pkg/x.go",
			"https://github.com/cpuchip/lodestar/blob/main/pkg/x.go"},
		// gitlab uses /blob/ too
		{"git@gitlab.com:group/sub/repo.git", "dev", "a/b.py",
			"https://gitlab.com/group/sub/repo/blob/dev/a/b.py"},
		// bitbucket uses /src/ instead of /blob/
		{"git@bitbucket.org:team/repo.git", "main", "src/app.ts",
			"https://bitbucket.org/team/repo/src/main/src/app.ts"},
		// graceful degrade: no origin, or no file
		{"", "main", "cmd/main.go", ""},
		{"git@github.com:cpuchip/lodestar.git", "main", "", ""},
		{"git@github.com:cpuchip/lodestar.git", "main", "   ", ""},
	}
	for _, c := range cases {
		if got := repoBlobURL(c.origin, c.ref, c.file); got != c.want {
			t.Errorf("repoBlobURL(%q, %q, %q) = %q, want %q", c.origin, c.ref, c.file, got, c.want)
		}
	}
}
