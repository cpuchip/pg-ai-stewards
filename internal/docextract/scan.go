package docextract

import (
	"archive/zip"
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// Scan is layer 1 of the defense — run BEFORE any content extraction. It
// combines two independent detectors (the ratified (c) combo):
//
//   - signature: ClamAV (clamscan) against a read-only signature DB. Catches
//     known malware/maldocs. Skipped (engine "structural-only") when no DB
//     path is configured — the structural half still runs.
//   - structural: a pure-Go, technique-based check for the constructs maldocs
//     use (auto-executing actions, embedded JS, VBA macros, OLE/DDE). Does not
//     rot when the ClamAV DB is stale; catches the macro/JS class AV may miss.
//
// Honest scope (proposal §5): this layer is early-reject + transparency, NOT
// the safety guarantee. A pure-byte structural scan cannot see inside
// compressed PDF object streams, and AV is signature-based — the GUARANTEE is
// the no-network sandbox (layer 2) plus non-executing extraction (layer 3).
func Scan(ctx context.Context, data []byte, filename, clamavDB string) ScanResult {
	res := ScanResult{Verdict: VerdictClean, Engine: "structural"}

	// Signature scan first — a known-malware hit is decisive (quarantine).
	if clamavDB != "" {
		if sig, found, err := clamScan(ctx, data, clamavDB); err == nil {
			res.Engine = "clamav+structural"
			if found {
				res.Verdict = VerdictMalicious
				res.Signature = sig
				// A malicious verdict short-circuits — we won't parse it for
				// content, so the structural detail is moot.
				return res
			}
		}
		// clamScan error (engine missing / DB unreadable) -> stay "structural"
		// and continue; the sandbox + non-execution still contain it.
	}

	// Structural scan — flags suspicious constructs but never blocks (the doc
	// is still safe to text-extract because layer 3 never runs the payload).
	res.Findings = structuralFindings(data, filename)
	if len(res.Findings) > 0 && res.Verdict == VerdictClean {
		res.Verdict = VerdictSuspicious
	}
	return res
}

// clamScan shells `clamscan` against the bytes (piped on stdin) using the
// given read-only signature DB. Returns the signature name + found=true on a
// hit. clamscan exit codes: 0 = clean, 1 = virus found, 2 = error.
func clamScan(ctx context.Context, data []byte, dbDir string) (sig string, found bool, err error) {
	cmd := exec.CommandContext(ctx, "clamscan",
		"--no-summary", "--infected", "--stdout",
		"--database="+dbDir, "-") // "-" = read the file from stdin
	cmd.Stdin = bytes.NewReader(data)
	out, runErr := cmd.Output()
	// Distinguish "virus found" (exit 1) from a real engine error (exit 2 / no
	// binary). exec returns *ExitError for non-zero exits.
	if runErr != nil {
		if ee, ok := runErr.(*exec.ExitError); ok {
			switch ee.ExitCode() {
			case 1: // infected — parse the signature from "stream: <Sig> FOUND"
				return parseClamSignature(string(out)), true, nil
			default: // 2 = error (DB missing, etc.) — let the caller degrade
				return "", false, fmt.Errorf("clamscan error (exit %d): %s", ee.ExitCode(), strings.TrimSpace(string(out)))
			}
		}
		return "", false, fmt.Errorf("clamscan: %w", runErr) // binary not found, etc.
	}
	return "", false, nil // exit 0 — clean
}

// parseClamSignature pulls the signature name out of clamscan's "<path>: <Sig>
// FOUND" line. Returns the raw line if it can't parse cleanly.
func parseClamSignature(out string) string {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasSuffix(line, "FOUND") {
			// "stream: Eicar-Signature FOUND" -> "Eicar-Signature"
			if i := strings.LastIndex(line, ": "); i >= 0 {
				return strings.TrimSpace(strings.TrimSuffix(line[i+2:], "FOUND"))
			}
			return strings.TrimSpace(strings.TrimSuffix(line, "FOUND"))
		}
	}
	return "malware"
}

// magic byte prefixes for the formats we route.
var (
	magicPDF = []byte("%PDF")
	magicZIP = []byte{0x50, 0x4B, 0x03, 0x04}                         // PK\x03\x04 — zip / OOXML / odt / epub
	magicOLE = []byte{0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1} // CFB — legacy doc/xls/ppt
	magicRTF = []byte(`{\rtf`)
)

// pdfDangerMarkers are PDF dictionary keys that drive auto-execution or carry
// active content. Their PRESENCE is a yellow flag, not proof of malice — many
// are legitimate — so a hit yields "suspicious" (still extracted), never a
// block. Precision is tuned over recall so the adjudicator keeps trusting it.
var pdfDangerMarkers = []string{
	"/JavaScript", "/JS", // embedded scripts
	"/OpenAction", "/AA", // run-on-open / additional (event) actions
	"/Launch",       // launch an external program
	"/EmbeddedFile", // a file embedded in the PDF
	"/RichMedia",    // Flash/embedded media (CVE-rich)
	"/XFA",          // XFA forms (parser-heavy attack surface)
}

// structuralFindings runs the pure-Go, technique-based maldoc check. Returns a
// sorted, de-duplicated list of finding tags (e.g. "pdf:/OpenAction").
func structuralFindings(data []byte, filename string) []string {
	set := map[string]bool{}
	add := func(s string) { set[s] = true }

	switch {
	case bytes.HasPrefix(data, magicPDF):
		for _, m := range pdfDangerMarkers {
			if bytes.Contains(data, []byte(m)) {
				add("pdf:" + m)
			}
		}
		// A compressed object stream can hide the markers above from a byte
		// scan; flag its presence so the limitation is visible (not a block).
		if bytes.Contains(data, []byte("/ObjStm")) {
			add("pdf:/ObjStm(opaque-to-byte-scan)")
		}
	case bytes.HasPrefix(data, magicZIP):
		for _, f := range ooxmlFindings(data) {
			add(f)
		}
	case bytes.HasPrefix(data, magicOLE):
		// Legacy OLE/CFB (doc/xls/ppt) is a common macro carrier and tabula
		// doesn't read it well anyway — flag the container, and look for the
		// VBA stream markers as a stronger signal.
		add("ole:legacy-cfb-container")
		for _, marker := range []string{"VBA", "_VBA_PROJECT", "Macros"} {
			if bytes.Contains(data, []byte(marker)) {
				add("ole:vba-marker:" + marker)
			}
		}
	case bytes.HasPrefix(data, magicRTF):
		// RTF object-update / embed abuse (CVE-2017-0199 class).
		for _, marker := range []string{`\objupdate`, `\objemb`, `\objdata`} {
			if bytes.Contains(bytes.ToLower(data), bytes.ToLower([]byte(marker))) {
				add("rtf:" + marker)
			}
		}
	default:
		// HTML / text — flag inline script + javascript: URLs (readability
		// strips them on extraction, but transparency is the point here).
		low := bytes.ToLower(data)
		if isHTMLName(filename) || bytes.Contains(low, []byte("<html")) || bytes.Contains(low, []byte("<!doctype html")) {
			if bytes.Contains(low, []byte("<script")) {
				add("html:<script>")
			}
			if bytes.Contains(low, []byte("javascript:")) {
				add("html:javascript-uri")
			}
		}
	}

	out := make([]string, 0, len(set))
	for s := range set {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

// ooxmlFindings inspects a zip-based Office Open XML container (docx/xlsx/pptx)
// for macro parts WITHOUT extracting content — it reads the central directory
// (member names) and the lightweight relationship/document parts only. The
// canonical macro tell is a `vbaProject.bin` member.
func ooxmlFindings(data []byte) []string {
	var findings []string
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil // not a readable zip (or odt/epub that isn't OOXML) — nothing to say
	}
	for _, f := range zr.File {
		name := strings.ToLower(f.Name)
		switch {
		case strings.HasSuffix(name, "vbaproject.bin"):
			findings = append(findings, "ooxml:vbaProject.bin(macros)")
		case strings.HasSuffix(name, "vbadata.xml"):
			findings = append(findings, "ooxml:vbaData.xml(macros)")
		case strings.Contains(name, "macrosheet"):
			findings = append(findings, "ooxml:macrosheet")
		case strings.HasSuffix(name, "/activex.bin") || strings.Contains(name, "activex"):
			findings = append(findings, "ooxml:activeX")
		case strings.HasSuffix(name, ".bin") && strings.Contains(name, "ole"):
			findings = append(findings, "ooxml:oleObject")
		}
	}
	sort.Strings(findings)
	return findings
}

func isHTMLName(name string) bool {
	switch strings.ToLower(filepath.Ext(path.Base(name))) {
	case ".html", ".htm", ".xhtml":
		return true
	}
	return false
}
