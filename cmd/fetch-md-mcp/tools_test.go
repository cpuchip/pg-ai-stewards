package main

import (
	"net/url"
	"strings"
	"testing"
)

// ES.5.s2: detectDocExt decides whether a fetched body is a non-HTML
// document (route to tabula) or HTML (route to readability).
func TestDetectDocExt(t *testing.T) {
	cases := []struct {
		name     string
		body     string
		fetchURL string
		want     string
	}{
		{"pdf by magic bytes", "%PDF-1.6\n%âãÏÓ binary…", "https://x.test/report", ".pdf"},
		{"pdf magic beats html extension", "%PDF-1.4 stuff", "https://x.test/doc.html", ".pdf"},
		{"pdf by url extension", "not actually pdf bytes", "https://x.test/paper.pdf", ".pdf"},
		{"docx by url extension", "PK\x03\x04 zip bytes", "https://x.test/memo.docx", ".docx"},
		{"xlsx by url extension", "PK\x03\x04 zip bytes", "https://x.test/sheet.xlsx", ".xlsx"},
		{"epub by url extension", "PK\x03\x04 zip bytes", "https://x.test/book.epub", ".epub"},
		{"html body, html url", "<!DOCTYPE html><html>…", "https://x.test/page.html", ""},
		{"html body, no extension", "<html><body>hi</body></html>", "https://x.test/article", ""},
		{"query string after pdf ext", "%nope", "https://x.test/f.pdf?dl=1", ".pdf"},
		{"unknown zip-ish extension stays html", "PK stuff", "https://x.test/thing.zip", ""},
	}
	for _, c := range cases {
		got := detectDocExt([]byte(c.body), c.fetchURL)
		if got != c.want {
			t.Errorf("%s: detectDocExt(%q, %q) = %q, want %q",
				c.name, c.body[:min(len(c.body), 16)], c.fetchURL, got, c.want)
		}
	}
}

// ES.5.s2: buildDocOutput derives a title from the URL and honors
// max_chars truncation.
func TestBuildDocOutput(t *testing.T) {
	md := strings.Repeat("word ", 100) // 500 chars
	out := buildDocOutput("https://x.test/papers/bacteriopolis.pdf", md, 0)
	if out.Title != "bacteriopolis.pdf" {
		t.Errorf("title = %q, want bacteriopolis.pdf", out.Title)
	}
	if out.WordCount != 100 {
		t.Errorf("word count = %d, want 100", out.WordCount)
	}
	if out.Truncated {
		t.Error("no max_chars set — should not be truncated")
	}

	clipped := buildDocOutput("https://x.test/a.pdf", md, 120)
	if !clipped.Truncated {
		t.Error("max_chars=120 with 500-char body — should be truncated")
	}
	if !strings.HasSuffix(clipped.Markdown, "[…truncated]") {
		t.Error("truncated output should carry the truncation marker")
	}
}

// wiki-assets: extractImageURLs discovers the article's own <img> URLs
// (absolute, deduped, data: URIs excluded) — the hook a downstream ingestion
// caller downloads+scans+persists via internal/wikiassets.
func TestExtractImageURLs(t *testing.T) {
	base, _ := url.Parse("https://ttrpg.example/rules/gazetteer")
	articleHTML := `
		<article>
			<h1>The Bree-lands</h1>
			<img src="/img/map-bree.png" alt="a map">
			<p>A rules table follows.</p>
			<img src="https://cdn.example/table.png">
			<img src="data:image/png;base64,iVBORw0KGgo=">
			<img src="/img/map-bree.png">
		</article>`
	got := extractImageURLs(articleHTML, base)
	want := []string{
		"https://ttrpg.example/img/map-bree.png",
		"https://cdn.example/table.png",
	}
	if len(got) != len(want) {
		t.Fatalf("got %d images %v, want %d %v", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("image[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestExtractImageURLs_CapsToMax(t *testing.T) {
	base, _ := url.Parse("https://x.test/page")
	var b strings.Builder
	b.WriteString("<article>")
	for i := 0; i < maxArticleImages+10; i++ {
		b.WriteString("<img src=\"/img/")
		b.WriteString(strings.Repeat("a", 1)) // keep it simple; uniqueness comes from the loop index below
		b.WriteString("-")
		b.WriteString(itoaTest(i))
		b.WriteString(".png\">")
	}
	b.WriteString("</article>")
	got := extractImageURLs(b.String(), base)
	if len(got) != maxArticleImages {
		t.Errorf("got %d images, want capped to %d", len(got), maxArticleImages)
	}
}

func itoaTest(i int) string {
	if i == 0 {
		return "0"
	}
	var out []byte
	for i > 0 {
		out = append([]byte{byte('0' + i%10)}, out...)
		i /= 10
	}
	return string(out)
}
