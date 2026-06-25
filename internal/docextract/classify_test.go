package docextract

import "testing"

// Oracle for the code-vs-docs classifier (RC-2 routing). Deterministic, list-only.
func TestClassify(t *testing.T) {
	cases := []struct {
		name  string
		paths []string
		want  string
	}{
		{"go repo by manifest", []string{"go.mod", "main.go", "README.md"}, "code"},
		{"node repo by manifest", []string{"package.json", "src/app.ts", "src/index.tsx"}, "code"},
		{"rust repo by manifest", []string{"Cargo.toml", "src/lib.rs"}, "code"},
		{"git dir is decisive", []string{".git/config", "notes.md"}, "code"},
		{"nested git dir", []string{"proj/.git/HEAD", "proj/whatever.txt"}, "code"},
		{"sources dominate, no manifest", []string{"a.py", "b.py", "c.py"}, "code"},
		{"doc corpus — pdf/docx", []string{"q1-report.pdf", "plan.docx", "budget.xlsx"}, "docs"},
		{"doc corpus — markdown notes", []string{"a.md", "b.md", "c.md"}, "docs"},
		{"single pdf", []string{"whitepaper.pdf"}, "docs"},
		{"mixed — a source + a doc", []string{"util.go", "spec.pdf"}, "mixed"},
		{"empty", []string{}, "mixed"},
		{"backslash paths normalize", []string{"src\\main.go", "go.mod"}, "code"},
		{"manifest case-insensitive", []string{"Dockerfile", "run.sh"}, "code"},
		{"weak-doc single md is not enough alone", []string{"README.md"}, "mixed"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got, reason := Classify(c.paths); got != c.want {
				t.Errorf("Classify(%v) = %q (%s), want %q", c.paths, got, reason, c.want)
			}
		})
	}
}
