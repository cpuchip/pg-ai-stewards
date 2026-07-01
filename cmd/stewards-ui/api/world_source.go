// world_source.go — the repo-origin → browsable-source-URL normalizer (#301, item
// 5). The ref-capture foundation (83-code-graph.sql) stamps a git remote on each
// code entity (world_entities.metadata.repo_origin), the repo-relative file on the
// entity (metadata.file_path), and the extraction's git ref on the world
// (worlds.metadata.ref). Given those three, worldNodeHandler builds a "↗ source"
// link to the exact file on the branch. The normalizer is a small, deterministic,
// unit-tested pure function (see world_source_test.go) so the git@/https forms are
// pinned; it degrades to "" whenever provenance is missing (worlds imported before
// #298 lack repo_origin — the link simply doesn't appear).

package api

import (
	"net/url"
	"strings"
)

// repoWebURL normalizes a git remote (any of the common forms) to its browsable
// web base URL, or "" when it can't (which callers treat as "no source link").
//
//	git@github.com:owner/repo.git          -> https://github.com/owner/repo
//	ssh://git@github.com/owner/repo.git    -> https://github.com/owner/repo
//	https://github.com/owner/repo.git      -> https://github.com/owner/repo
//	https://gitlab.com/group/sub/repo.git  -> https://gitlab.com/group/sub/repo
//
// Host is preserved (github/gitlab/bitbucket/self-hosted all work); only the
// scheme is forced to https, the .git suffix and any credentials/ports dropped.
func repoWebURL(origin string) string {
	origin = strings.TrimSpace(origin)
	if origin == "" {
		return ""
	}

	var host, path string
	switch {
	case strings.HasPrefix(origin, "git@"):
		// scp-like syntax: git@host:owner/repo(.git)
		rest := strings.TrimPrefix(origin, "git@")
		i := strings.IndexByte(rest, ':')
		if i < 0 {
			return ""
		}
		host, path = rest[:i], rest[i+1:]
	case strings.Contains(origin, "://"):
		// scheme://[user@]host[:port]/owner/repo(.git) — https, ssh, git, ...
		u, err := url.Parse(origin)
		if err != nil || u.Host == "" {
			return ""
		}
		host, path = u.Hostname(), strings.TrimPrefix(u.Path, "/")
	default:
		// a bare host:owner/repo (no scheme, no git@) — treat like scp form.
		i := strings.IndexByte(origin, ':')
		if i < 0 {
			return ""
		}
		host, path = origin[:i], origin[i+1:]
	}

	host = strings.TrimSpace(host)
	path = strings.Trim(strings.TrimSpace(path), "/")
	path = strings.TrimSuffix(path, ".git")
	if host == "" || path == "" {
		return ""
	}
	return "https://" + host + "/" + path
}

// repoBlobURL builds a link to one file on a given ref, browsable in the host's
// web UI. GitHub and GitLab use /blob/<ref>/<path>; Bitbucket uses /src/<ref>/<path>.
// ref defaults to "main" when unset (a world imported before branch-aware capture
// has no metadata.ref). Returns "" when there's not enough to link (no origin or
// no file path) so the UI can degrade gracefully.
func repoBlobURL(origin, ref, filePath string) string {
	base := repoWebURL(origin)
	if base == "" {
		return ""
	}
	filePath = strings.TrimLeft(strings.TrimSpace(filePath), "/")
	if filePath == "" {
		return ""
	}
	if ref = strings.TrimSpace(ref); ref == "" {
		ref = "main"
	}
	segment := "/blob/"
	if strings.Contains(base, "bitbucket.org") {
		segment = "/src/" // Bitbucket's file-browse path differs from github/gitlab
	}
	return base + segment + ref + "/" + filePath
}
