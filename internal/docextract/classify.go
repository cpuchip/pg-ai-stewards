package docextract

import (
	"fmt"
	"path"
	"strings"
)

// Classify decides whether an unpacked archive's member list looks like a CODE
// repository or a DOCUMENT corpus — the routing brain for "explore a dropped
// code repo in a sandbox" vs "import a folder of docs into the searchable pool"
// (RC-2). Deterministic, list-only (no content), so it is a pure oracle.
//
// Returns kind ∈ {"code","docs","mixed"} + a short human reason. A build
// manifest or a .git directory is decisive for code; otherwise the dominant
// file class wins, with ambiguous folders ("a few sources + a few docs") left
// "mixed" so the caller can ask rather than guess.
func Classify(paths []string) (kind, reason string) {
	var code, docStrong, weakDoc int
	manifest := ""
	hasGit := false
	for _, p := range paths {
		p = strings.ReplaceAll(strings.TrimSpace(p), "\\", "/")
		if p == "" {
			continue
		}
		if p == ".git" || strings.HasPrefix(p, ".git/") || strings.Contains(p, "/.git/") {
			hasGit = true
			continue
		}
		base := strings.ToLower(path.Base(p))
		if manifestNames[base] {
			if manifest == "" {
				manifest = base
			}
			continue
		}
		switch ext := strings.ToLower(path.Ext(base)); {
		case codeExt[ext]:
			code++
		case docStrongExt[ext]:
			docStrong++
		case weakDocExt[ext]:
			weakDoc++
		}
	}
	switch {
	case hasGit:
		return "code", "contains a .git directory (a git repo)"
	case manifest != "":
		return "code", "has a build manifest (" + manifest + ")"
	case code >= 2 && code >= docStrong:
		return "code", fmt.Sprintf("%d source file(s) dominate", code)
	case code == 0 && (docStrong >= 1 || weakDoc >= 2):
		return "docs", fmt.Sprintf("%d document file(s), no source", docStrong+weakDoc)
	default:
		return "mixed", fmt.Sprintf("%d source / %d doc file(s) — ambiguous", code, docStrong+weakDoc)
	}
}

// manifestNames — a build/package manifest (or a repo marker) is a strong,
// near-certain "this is a code repo" signal on its own.
var manifestNames = map[string]bool{
	"go.mod": true, "go.sum": true, "package.json": true, "package-lock.json": true,
	"yarn.lock": true, "pnpm-lock.yaml": true, "tsconfig.json": true, "cargo.toml": true,
	"cargo.lock": true, "pyproject.toml": true, "requirements.txt": true, "setup.py": true,
	"pipfile": true, "gemfile": true, "composer.json": true, "pom.xml": true,
	"build.gradle": true, "settings.gradle": true, "cmakelists.txt": true, "makefile": true,
	"dockerfile": true, ".gitignore": true, ".gitmodules": true, "go.work": true,
}

// codeExt — unambiguous source-code extensions.
var codeExt = map[string]bool{
	".go": true, ".ts": true, ".tsx": true, ".js": true, ".jsx": true, ".mjs": true, ".cjs": true,
	".py": true, ".rs": true, ".java": true, ".kt": true, ".kts": true, ".scala": true,
	".c": true, ".cc": true, ".cpp": true, ".cxx": true, ".h": true, ".hpp": true,
	".cs": true, ".swift": true, ".rb": true, ".php": true, ".pl": true, ".pm": true,
	".sh": true, ".bash": true, ".zsh": true, ".lua": true, ".r": true, ".jl": true,
	".dart": true, ".ex": true, ".exs": true, ".erl": true, ".hs": true, ".ml": true,
	".fs": true, ".vue": true, ".svelte": true, ".sql": true, ".proto": true, ".graphql": true,
}

// docStrongExt — formats that mark a DOCUMENT corpus (office/publishing), not code.
var docStrongExt = map[string]bool{
	".pdf": true, ".doc": true, ".docx": true, ".xls": true, ".xlsx": true,
	".ppt": true, ".pptx": true, ".odt": true, ".ods": true, ".odp": true,
	".epub": true, ".rtf": true,
}

// weakDocExt — text-ish formats common in BOTH (README.md, notes, configs); a
// weak doc signal only, and only when no source files are present.
var weakDocExt = map[string]bool{
	".md": true, ".markdown": true, ".txt": true, ".text": true, ".html": true, ".htm": true, ".csv": true,
}
