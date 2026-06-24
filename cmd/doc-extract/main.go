// doc-extract is the deterministic document CONVERTER that runs INSIDE the
// hardened, no-network sandbox (extension/doc-extract.Dockerfile). It reads an
// untrusted document's bytes from stdin, runs the four-layer defense (scan ->
// contain[the sandbox] -> disarm-by-non-execution -> content-gate), and emits a
// docextract.Result as JSON on stdout. Only plain text and page pixels ever
// cross out — never the original file structure (proposal §3).
//
// It is NOT an MCP server. The bridge-side cmd/doc-extract-mcp spawns this in a
// sandbox, pipes the bytes in, and reads the JSON back. Running it directly is
// also how the adversarial smoke and unit tests exercise the converter.
//
// Usage (inside the container):
//
//	doc-extract -filename report.pdf -render -max-pages 5 < bytes > result.json
//	doc-extract -smoke                 # self-test: prove the converter end to end
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"github.com/cpuchip/pg-ai-stewards/internal/docextract"
)

func main() {
	var (
		filename    = flag.String("filename", "attachment", "original filename (drives type detection for ambiguous magic)")
		render      = flag.Bool("render", false, "also render page pixels (poppler) alongside the always-on text")
		maxPages    = flag.Int("max-pages", 0, "cap rendered pages (0 = built-in default)")
		dpi         = flag.Int("dpi", 0, "render DPI (0 = default 150)")
		clamavDB    = flag.String("clamav-db", os.Getenv("DOC_EXTRACT_CLAMAV_DB"), "ClamAV signature DB dir (empty = skip the signature scan)")
		maxTotal    = flag.Int64("max-total", 0, "archive: max total uncompressed bytes (0 = default 200MB)")
		maxEntry    = flag.Int64("max-entry", 0, "archive: max single-entry bytes (0 = default 50MB)")
		maxEntries  = flag.Int("max-entries", 0, "archive: max member count (0 = default 1000)")
		maxRatio    = flag.Int("max-ratio", 0, "archive: compression-ratio ceiling (0 = default 200)")
		recurse     = flag.Bool("recurse-nested", false, "archive: recurse into nested archives (default false = surface as a file)")
		smoke       = flag.Bool("smoke", false, "run a self-test (benign + adversarial inputs) and exit")
		timeoutSecs = flag.Int("timeout", 120, "overall extraction timeout in seconds")
	)
	flag.Parse()

	log.SetOutput(os.Stderr)
	log.SetPrefix("doc-extract: ")

	if *smoke {
		if err := runSmoke(); err != nil {
			log.Fatalf("smoke FAILED: %v", err)
		}
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*timeoutSecs)*time.Second)
	defer cancel()

	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		log.Fatalf("read stdin: %v", err)
	}
	if len(data) == 0 {
		log.Fatalf("no input bytes on stdin")
	}

	caps := docextract.DefaultArchiveCaps()
	if *maxTotal > 0 {
		caps.MaxTotalUncompressed = *maxTotal
	}
	if *maxEntry > 0 {
		caps.MaxEntrySize = *maxEntry
	}
	if *maxEntries > 0 {
		caps.MaxEntries = *maxEntries
	}
	if *maxRatio > 0 {
		caps.MaxRatio = *maxRatio
	}
	caps.RecurseNested = *recurse

	res, err := docextract.Run(ctx, data, docextract.Options{
		Filename:    *filename,
		RenderPages: *render,
		MaxPages:    *maxPages,
		RenderDPI:   *dpi,
		ClamAVDB:    *clamavDB,
		Caps:        caps,
	})
	if err != nil {
		// A run-level error still emits whatever partial result we have, so the
		// caller sees the warnings (e.g. a bomb halted mid-unpack).
		res.Warnings = append(res.Warnings, "run error: "+err.Error())
	}

	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(res); err != nil {
		log.Fatalf("encode result: %v", err)
	}
}

// runSmoke proves the converter end to end on benign + adversarial inputs,
// without needing the MCP/bridge. It does NOT require ClamAV (the structural
// scan still runs); when ClamAV is present + a DB is configured, the EICAR case
// also exercises the signature path.
func runSmoke() error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// 1. Benign text -> extracted, clean.
	r, err := docextract.Run(ctx, []byte("hello from the doc-extract smoke"), docextract.Options{Filename: "note.txt"})
	if err != nil {
		return fmt.Errorf("benign text: %w", err)
	}
	if len(r.Files) != 1 || r.Files[0].Skipped || r.Files[0].WordCount == 0 {
		return fmt.Errorf("benign text not extracted cleanly: %+v", r.Files)
	}
	fmt.Printf("smoke: benign text OK (words=%d, verdict=%s)\n", r.Files[0].WordCount, r.Files[0].Scan.Verdict)

	// 2. Macro-flagged PDF -> suspicious, but STILL extracted (non-execution).
	macroPDF := []byte("%PDF-1.7\n<< /OpenAction << /S /JavaScript /JS (evil) >> >>\nbody text here")
	r, err = docextract.Run(ctx, macroPDF, docextract.Options{Filename: "macro.pdf", ClamAVDB: os.Getenv("DOC_EXTRACT_CLAMAV_DB")})
	if err != nil {
		return fmt.Errorf("macro pdf: %w", err)
	}
	if r.Files[0].Scan.Verdict != docextract.VerdictSuspicious {
		return fmt.Errorf("macro pdf should be suspicious, got %q", r.Files[0].Scan.Verdict)
	}
	fmt.Printf("smoke: macro PDF flagged suspicious OK (findings=%v)\n", r.Files[0].Scan.Findings)

	// 3. EICAR -> when the ClamAV signature engine actually runs (DB populated),
	// it MUST be quarantined (malicious). If the DB is absent/empty the engine
	// degrades to structural-only and we skip the assertion (the structural scan
	// can't catch EICAR — that's exactly why the signature layer exists).
	if db := os.Getenv("DOC_EXTRACT_CLAMAV_DB"); db != "" {
		eicar := []byte(`X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*`)
		r, err = docextract.Run(ctx, eicar, docextract.Options{Filename: "eicar.com", ClamAVDB: db})
		if err != nil {
			return fmt.Errorf("eicar: %w", err)
		}
		switch r.Files[0].Scan.Engine {
		case "clamav+structural": // the signature engine ran — EICAR must be caught
			if r.Files[0].Scan.Verdict != docextract.VerdictMalicious || !r.Files[0].Skipped {
				return fmt.Errorf("EICAR must be quarantined when ClamAV is live, got verdict=%q skipped=%v",
					r.Files[0].Scan.Verdict, r.Files[0].Skipped)
			}
			fmt.Printf("smoke: EICAR quarantined OK (sig=%s)\n", r.Files[0].Scan.Signature)
		default: // DB empty/absent — clamscan couldn't run; structural can't see EICAR
			fmt.Printf("smoke: EICAR signature check unavailable (engine=%s; ClamAV DB not populated yet) — structural scan active\n",
				r.Files[0].Scan.Engine)
		}
	} else {
		fmt.Println("smoke: EICAR skipped (no DOC_EXTRACT_CLAMAV_DB; structural scan still active)")
	}

	fmt.Println("doc-extract smoke: PASS")
	return nil
}
