package docextract

import (
	"archive/zip"
	"bytes"
	"context"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------
// safeArchiveName — the zip-slip / path-traversal oracle.
// ---------------------------------------------------------------------

func TestSafeArchiveName(t *testing.T) {
	cases := []struct {
		in       string
		wantOK   bool
		wantPath string
	}{
		{"docs/report.pdf", true, "docs/report.pdf"},
		{"./a/b.txt", true, "a/b.txt"},
		{"a/b/../c.txt", true, "a/c.txt"}, // interior .. that stays inside is fine
		{"q3/marketing.pptx", true, "q3/marketing.pptx"},
		// Escapes — all must be refused.
		{"../../etc/passwd", false, ""},
		{"../evil", false, ""},
		{"a/../../escape", false, ""},
		{"/etc/passwd", false, ""},
		{"/abs", false, ""},
		{`..\..\windows\system32`, false, ""},
		{`C:\evil`, false, ""},
		{"", false, ""},
		{".", false, ""},
		{"..", false, ""},
	}
	for _, c := range cases {
		got, ok := safeArchiveName(c.in)
		if ok != c.wantOK {
			t.Errorf("safeArchiveName(%q) ok=%v, want %v", c.in, ok, c.wantOK)
			continue
		}
		if ok && got != c.wantPath {
			t.Errorf("safeArchiveName(%q) = %q, want %q", c.in, got, c.wantPath)
		}
	}
}

// ---------------------------------------------------------------------
// structuralFindings — the maldoc detection oracle.
// ---------------------------------------------------------------------

func TestStructuralFindings_PDF(t *testing.T) {
	// A PDF with an auto-open action + embedded JS.
	pdf := []byte("%PDF-1.7\n<< /OpenAction << /S /JavaScript /JS (app.alert\\(1\\)) >> >>\n/Type /Catalog")
	got := structuralFindings(pdf, "x.pdf")
	wantAny := []string{"pdf:/OpenAction", "pdf:/JavaScript", "pdf:/JS"}
	for _, w := range wantAny {
		if !contains(got, w) {
			t.Errorf("PDF findings %v missing %q", got, w)
		}
	}

	clean := []byte("%PDF-1.7\n<< /Type /Catalog /Pages 2 0 R >>\nplain text content")
	if f := structuralFindings(clean, "ok.pdf"); len(f) != 0 {
		t.Errorf("clean PDF should have no findings, got %v", f)
	}
}

func TestStructuralFindings_OOXMLMacro(t *testing.T) {
	macro := buildZip(t, map[string][]byte{
		"[Content_Types].xml":   []byte("<Types/>"),
		"word/document.xml":     []byte("<doc/>"),
		"word/vbaProject.bin":   []byte("\x00\x01macro-blob"),
	})
	got := structuralFindings(macro, "memo.docm")
	if !contains(got, "ooxml:vbaProject.bin(macros)") {
		t.Errorf("macro docx findings %v missing vbaProject.bin", got)
	}

	clean := buildZip(t, map[string][]byte{
		"[Content_Types].xml": []byte("<Types/>"),
		"word/document.xml":   []byte("<doc>hello</doc>"),
	})
	if f := structuralFindings(clean, "memo.docx"); len(f) != 0 {
		t.Errorf("clean docx should have no findings, got %v", f)
	}
}

func TestStructuralFindings_OLEandRTF(t *testing.T) {
	ole := append(append([]byte{}, magicOLE...), []byte("...._VBA_PROJECT....Macros....")...)
	got := structuralFindings(ole, "old.doc")
	if !contains(got, "ole:legacy-cfb-container") {
		t.Errorf("OLE findings %v missing legacy-cfb-container", got)
	}

	rtf := []byte(`{\rtf1\ansi {\object\objupdate {\*\objdata 01050000}}}`)
	rg := structuralFindings(rtf, "x.rtf")
	if !contains(rg, `rtf:\objupdate`) {
		t.Errorf("RTF findings %v missing objupdate", rg)
	}
}

// ---------------------------------------------------------------------
// Scan — verdict policy without ClamAV (structural-only, graceful).
// ---------------------------------------------------------------------

func TestScan_StructuralOnly(t *testing.T) {
	ctx := context.Background()

	// Benign text -> clean, engine "structural" (no ClamAV DB configured).
	clean := Scan(ctx, []byte("just a normal note"), "note.txt", "")
	if clean.Verdict != VerdictClean {
		t.Errorf("benign text verdict = %q, want clean", clean.Verdict)
	}
	if clean.Engine != "structural" {
		t.Errorf("no-DB engine = %q, want structural", clean.Engine)
	}

	// Macro PDF -> suspicious (flag, but still extractable).
	susp := Scan(ctx, []byte("%PDF-1.7 /Launch /OpenAction"), "x.pdf", "")
	if susp.Verdict != VerdictSuspicious {
		t.Errorf("macro PDF verdict = %q, want suspicious", susp.Verdict)
	}
	if len(susp.Findings) == 0 {
		t.Error("suspicious scan must carry findings")
	}
}

// ---------------------------------------------------------------------
// unpackArchive — the zip-bomb / caps oracle.
// ---------------------------------------------------------------------

func TestUnpackArchive_Benign(t *testing.T) {
	z := buildZip(t, map[string][]byte{
		"a.txt":       []byte("alpha"),
		"sub/b.txt":   []byte("bravo"),
		"sub/c.md":    []byte("# charlie"),
	})
	members, warnings, err := unpackArchive(context.Background(), z, "bundle.zip", DefaultArchiveCaps())
	if err != nil {
		t.Fatalf("benign unpack error: %v", err)
	}
	if len(warnings) != 0 {
		t.Errorf("benign unpack warnings: %v", warnings)
	}
	if len(members) != 3 {
		t.Fatalf("got %d members, want 3", len(members))
	}
}

func TestUnpackArchive_ZipSlipRefused(t *testing.T) {
	z := buildZip(t, map[string][]byte{
		"ok.txt":          []byte("fine"),
		"../../etc/passwd": []byte("root:x:0:0"),
	})
	members, warnings, err := unpackArchive(context.Background(), z, "slip.zip", DefaultArchiveCaps())
	if err != nil {
		t.Fatalf("unpack error: %v", err)
	}
	for _, m := range members {
		if strings.Contains(m.name, "..") || strings.HasPrefix(m.name, "/") {
			t.Errorf("zip-slip entry escaped: %q", m.name)
		}
	}
	if len(members) != 1 {
		t.Errorf("got %d members, want only the safe one", len(members))
	}
	if !anyContains(warnings, "unsafe entry path") {
		t.Errorf("expected an unsafe-entry warning, got %v", warnings)
	}
}

func TestUnpackArchive_BombTotalCap(t *testing.T) {
	// One entry of ~2 MB of zeros (compresses tiny). Cap total at 1 MB -> abort.
	big := make([]byte, 2<<20)
	z := buildZip(t, map[string][]byte{"huge.bin": big})
	caps := DefaultArchiveCaps()
	caps.MaxTotalUncompressed = 1 << 20 // 1 MB
	caps.MaxEntrySize = 8 << 20         // entry cap high so the TOTAL cap is what trips
	_, _, err := unpackArchive(context.Background(), z, "bomb.zip", caps)
	if err == nil {
		t.Fatal("expected a total-uncompressed cap breach, got nil")
	}
	if !strings.Contains(err.Error(), "total-uncompressed cap") {
		t.Errorf("error = %v, want total-uncompressed cap breach", err)
	}
}

func TestUnpackArchive_BombRatioCap(t *testing.T) {
	// Highly compressible content trips the ratio ceiling before the size caps.
	big := make([]byte, 4<<20) // 4 MB of zeros -> compresses to a few KB
	z := buildZip(t, map[string][]byte{"zeros.bin": big})
	caps := DefaultArchiveCaps()
	caps.MaxRatio = 10              // a real bomb is far higher than 10:1
	caps.MaxTotalUncompressed = 1 << 30 // huge so RATIO is what trips
	caps.MaxEntrySize = 1 << 30
	_, _, err := unpackArchive(context.Background(), z, "ratio.zip", caps)
	if err == nil {
		t.Fatal("expected a compression-ratio bomb breach, got nil")
	}
	if !strings.Contains(err.Error(), "decompression-bomb") {
		t.Errorf("error = %v, want decompression-bomb guard", err)
	}
}

func TestUnpackArchive_EntryCountCap(t *testing.T) {
	files := map[string][]byte{}
	for i := 0; i < 50; i++ {
		files["f"+itoa(i)+".txt"] = []byte("x")
	}
	z := buildZip(t, files)
	caps := DefaultArchiveCaps()
	caps.MaxEntries = 10
	_, _, err := unpackArchive(context.Background(), z, "flood.zip", caps)
	if err == nil || !strings.Contains(err.Error(), "entry-count cap") {
		t.Errorf("expected entry-count cap breach, got %v", err)
	}
}

// ---------------------------------------------------------------------
// detectDocType — magic + extension routing.
// ---------------------------------------------------------------------

func TestDetectDocType(t *testing.T) {
	cases := []struct {
		data     []byte
		name     string
		wantType string
	}{
		{[]byte("%PDF-1.7 ..."), "report.pdf", "pdf"},
		{buildZip(t, map[string][]byte{"word/document.xml": []byte("x")}), "memo.docx", "docx"},
		{[]byte("# Hello\n\nplain markdown"), "notes.md", "text"},
		{[]byte("<!doctype html><html><body>hi</body></html>"), "page.html", "html"},
		{[]byte("just some text with no extension hint"), "mystery", "text"},
		{append(magicOLE, []byte("old binary doc")...), "old.doc", "legacy-office"},
	}
	for _, c := range cases {
		got, _ := detectDocType(c.data, c.name)
		if got != c.wantType {
			t.Errorf("detectDocType(%q) = %q, want %q", c.name, got, c.wantType)
		}
	}
}

// ---------------------------------------------------------------------
// ExtractFile / Run — end-to-end on benign inputs (no Docker, no poppler).
// ---------------------------------------------------------------------

func TestExtractFile_Text(t *testing.T) {
	fr := ExtractFile(context.Background(), []byte("hello world from a note"), "note.txt", Options{})
	if fr.Skipped {
		t.Fatal("benign text should not be skipped")
	}
	if !strings.Contains(fr.Text, "hello world") {
		t.Errorf("text not extracted: %q", fr.Text)
	}
	if fr.WordCount != 5 {
		t.Errorf("word count = %d, want 5", fr.WordCount)
	}
	if fr.Scan.Verdict != VerdictClean {
		t.Errorf("clean text verdict = %q", fr.Scan.Verdict)
	}
}

func TestRun_DispatchesArchive(t *testing.T) {
	z := buildZip(t, map[string][]byte{
		"a.txt":     []byte("alpha text"),
		"b.md":      []byte("# bravo"),
	})
	res, err := Run(context.Background(), z, Options{Filename: "bundle.zip"})
	if err != nil {
		t.Fatalf("Run archive: %v", err)
	}
	if res.Mode != "archive" {
		t.Errorf("mode = %q, want archive", res.Mode)
	}
	if len(res.Files) != 2 {
		t.Fatalf("got %d files, want 2", len(res.Files))
	}

	// A single document dispatches to the file pipeline.
	fres, err := Run(context.Background(), []byte("plain note"), Options{Filename: "note.txt"})
	if err != nil {
		t.Fatalf("Run file: %v", err)
	}
	if fres.Mode != "file" || len(fres.Files) != 1 {
		t.Errorf("single file: mode=%q files=%d", fres.Mode, len(fres.Files))
	}
}

func TestRun_NestedArchiveNotRecursed(t *testing.T) {
	inner := buildZip(t, map[string][]byte{"secret.txt": []byte("nested")})
	outer := buildZip(t, map[string][]byte{
		"readme.txt": []byte("top level"),
		"inner.zip":  inner,
	})
	res, err := Run(context.Background(), outer, Options{Filename: "outer.zip"})
	if err != nil {
		t.Fatalf("Run nested: %v", err)
	}
	var sawNested bool
	for _, f := range res.Files {
		if f.Path == "inner.zip" {
			sawNested = true
			if !f.Skipped || f.DocType != "archive" {
				t.Errorf("nested archive should be surfaced-not-recursed: %+v", f)
			}
		}
	}
	if !sawNested {
		t.Error("nested inner.zip not present in results")
	}
}

// ---------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------

func buildZip(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, data := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatalf("zip create %q: %v", name, err)
		}
		if _, err := w.Write(data); err != nil {
			t.Fatalf("zip write %q: %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zip close: %v", err)
	}
	return buf.Bytes()
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

func anyContains(ss []string, sub string) bool {
	for _, s := range ss {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	return string(b)
}
