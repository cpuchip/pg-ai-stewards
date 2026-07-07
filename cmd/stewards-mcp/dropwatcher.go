// Drop watcher (v28 files-interface, feat/files-interface).
//
// Scans STEWARDS_DROP_DIR (default /drop; compose mounts ./drop:/drop)
// and ingests what it finds through the v28 SQL surface:
//
//   - text drops (.md/.txt/.markdown, valid UTF-8) -> stewards.file_drop_ingest
//     (content inline; pooled via the existing import_doc path)
//   - everything else -> stewards.file_drop_ingest_binary (bytes -> a durable
//     chat_attachments row + the existing doc-extract/doc_import_corpus path)
//
// POLL-FIRST BY DESIGN: a 30s poll IS the contract. inotify/fsnotify is
// unreliable across Docker Desktop bind mounts on Windows (events simply
// don't cross the VM boundary for host-side writes), and fsnotify isn't a
// module dependency today — so no watcher, no accelerant, just the poll.
//
// Routing rules, as implemented:
//   - dotfiles and dot-directories are skipped (the whole subtree for dirs);
//     editor/OS junk (Thumbs.db, desktop.ini, .DS_Store, *~, ~$*, *.tmp,
//     *.swp/.swo, *.partial, *.crdownload) is skipped.
//   - the FIRST path segment under the drop root is the project hint
//     (drop/work-corpus/x.md -> project 'work-corpus'); files at the root carry none.
//   - every candidate is sha256'd; a (path, sha) already on the ledger with
//     a non-error status is skipped silently (the freshness principle's
//     cheap half). A (path, sha) that previously ERRORED is retried at most
//     once per bridge process (in-memory guard) so a permanently broken file
//     doesn't churn the ledger every 30 seconds; restart the bridge (or
//     change the file) to retry again.
//   - files over 100MB are skipped with a log line (bytea inline storage is
//     the substrate's convention; a 100MB+ drop needs a deliberate path).
//   - errors land in stewards.file_drops.status='error' (the SQL functions
//     never RAISE); the loop itself never crashes on a bad file.
//
// After each scan pass, stewards.file_drop_reconcile() pulls async
// doc_import_corpus outcomes back onto the ledger (a failed extract must
// FLAG, never silently sit as 'ingested').
//
// Disabled when STEWARDS_DROP_DISABLED=1, or when the drop dir is absent.
//
// Companion SQL: extension/v28-files-interface.sql. Lineage: the ratified
// files-as-interface verdict (.spec/proposals/files-as-interface-db-as-
// engine.md, Layer 3 "ingested BY trigger") and the founding research
// verdict (2026-05-02): files are the interface, rows are the canon.

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"log"
	"mime"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	dropPollInterval = 30 * time.Second
	dropMaxFileBytes = 100 << 20 // 100 MB — inline bytea is the convention; bigger needs a deliberate path
)

// runDropWatcher is started from runBridgeRun in a goroutine, mirroring
// runMaterializer's shape. Returns only when ctx is done, or immediately
// when disabled/unconfigured.
func runDropWatcher(ctx context.Context, pool *pgxpool.Pool) {
	if os.Getenv("STEWARDS_DROP_DISABLED") == "1" {
		log.Printf("drop-watcher: disabled via STEWARDS_DROP_DISABLED=1")
		return
	}

	dropDir := os.Getenv("STEWARDS_DROP_DIR")
	if dropDir == "" {
		dropDir = "/drop"
	}
	if fi, err := os.Stat(dropDir); err != nil || !fi.IsDir() {
		log.Printf("drop-watcher: drop dir %s not present (%v) — ingest-by-drop disabled. "+
			"Mount a directory there (compose: ./drop:/drop) to enable.", dropDir, err)
		return
	}

	w := &dropWatcher{pool: pool, dir: dropDir, attempted: map[string]bool{}}
	log.Printf("drop-watcher: watching %s (poll every %s — the poll IS the contract; "+
		"inotify is unreliable across Docker Desktop bind mounts)", dropDir, dropPollInterval)

	// Scan once at startup, then on the poll cadence.
	w.scan(ctx)

	ticker := time.NewTicker(dropPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Printf("drop-watcher: shutting down (ctx done)")
			return
		case <-ticker.C:
			w.scan(ctx)
		}
	}
}

type dropWatcher struct {
	pool *pgxpool.Pool
	dir  string
	// attempted guards error-status retries: one retry per (path,sha) per
	// bridge process, so a permanently broken file doesn't churn every 30s.
	attempted map[string]bool
}

// scan is one full pass over the drop tree. Never returns an error — every
// per-file failure is logged (and, where the SQL got involved, ledgered)
// and the pass continues.
func (w *dropWatcher) scan(ctx context.Context) {
	known, knownErr, err := w.loadLedger(ctx)
	if err != nil {
		log.Printf("drop-watcher: ledger read failed (%v) — skipping this pass", err)
		return
	}

	var ingested, errored int
	walkErr := filepath.WalkDir(w.dir, func(p string, d fs.DirEntry, err error) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			log.Printf("drop-watcher: walk %s: %v (skipping)", p, err)
			return nil
		}
		name := d.Name()
		if d.IsDir() {
			if p != w.dir && strings.HasPrefix(name, ".") {
				return filepath.SkipDir // .git, .stfolder, hidden trees — never descend
			}
			return nil
		}
		if strings.HasPrefix(name, ".") || isDropJunk(name) {
			return nil
		}

		rel, rerr := filepath.Rel(w.dir, p)
		if rerr != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)

		if info, ierr := d.Info(); ierr == nil && info.Size() > dropMaxFileBytes {
			log.Printf("drop-watcher: %s is %d bytes (> %d cap) — skipped (too big for inline bytea; "+
				"use doc_import_corpus on a deliberate upload instead)", rel, info.Size(), int64(dropMaxFileBytes))
			return nil
		}

		data, rderr := os.ReadFile(p)
		if rderr != nil {
			log.Printf("drop-watcher: read %s: %v (skipping; likely mid-copy — next poll retries)", rel, rderr)
			return nil
		}

		sum := sha256.Sum256(data)
		sha := hex.EncodeToString(sum[:])
		key := rel + "\x00" + sha
		if known[key] {
			return nil // unchanged — skip silently
		}
		if knownErr[key] {
			if w.attempted[key] {
				return nil // already retried this process; stay quiet
			}
			w.attempted[key] = true
		}

		hint := ""
		if i := strings.IndexByte(rel, '/'); i > 0 {
			hint = rel[:i]
		}

		status, ingErr := w.ingestOne(ctx, rel, data, hint, sha)
		switch {
		case ingErr != nil:
			errored++
			log.Printf("drop-watcher: %s: ingest call failed: %v", rel, ingErr)
		case status == "ingested":
			ingested++
			log.Printf("drop-watcher: ingested %s (project=%s sha=%s...)", rel, orNone(hint), sha[:12])
		case status == "skipped_unchanged":
			// ledger knew it even though our snapshot didn't — quiet
		default:
			errored++
			log.Printf("drop-watcher: %s landed status=%s (see stewards.file_drops.error)", rel, status)
		}
		return nil
	})
	if walkErr != nil && ctx.Err() == nil {
		log.Printf("drop-watcher: walk aborted: %v", walkErr)
	}

	// Pull async extract outcomes back onto the ledger (binary drops).
	var flipped int
	if err := w.pool.QueryRow(ctx, "SELECT stewards.file_drop_reconcile()").Scan(&flipped); err != nil {
		log.Printf("drop-watcher: reconcile failed: %v", err)
	} else if flipped > 0 {
		log.Printf("drop-watcher: reconcile flagged %d extract failure(s) on the ledger", flipped)
	}

	if ingested > 0 || errored > 0 {
		log.Printf("drop-watcher: pass done — %d ingested, %d errored", ingested, errored)
	}
}

// loadLedger snapshots (path,sha) -> seen, split by whether the row errored
// (error rows are retry candidates; everything else is a silent skip).
func (w *dropWatcher) loadLedger(ctx context.Context) (known, knownErr map[string]bool, err error) {
	rows, err := w.pool.Query(ctx, "SELECT path, sha256, status FROM stewards.file_drops")
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	known, knownErr = map[string]bool{}, map[string]bool{}
	for rows.Next() {
		var p, s, st string
		if err := rows.Scan(&p, &s, &st); err != nil {
			return nil, nil, err
		}
		if st == "error" {
			knownErr[p+"\x00"+s] = true
		} else {
			known[p+"\x00"+s] = true
		}
	}
	return known, knownErr, rows.Err()
}

// ingestOne routes a single candidate to the right v28 SQL function and
// returns the resulting ledger status.
func (w *dropWatcher) ingestOne(ctx context.Context, rel string, data []byte, hint, sha string) (string, error) {
	callCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	var resJSON []byte
	if isTextDrop(rel, data) {
		err := w.pool.QueryRow(callCtx,
			"SELECT stewards.file_drop_ingest($1, $2, nullif($3,''), $4)",
			rel, string(data), hint, sha).Scan(&resJSON)
		if err != nil {
			return "", err
		}
	} else {
		err := w.pool.QueryRow(callCtx,
			"SELECT stewards.file_drop_ingest_binary($1, $2, nullif($3,''), nullif($4,''), $5)",
			rel, data, mimeForDrop(rel), hint, sha).Scan(&resJSON)
		if err != nil {
			return "", err
		}
	}

	var res struct {
		Status string `json:"status"`
		Error  string `json:"error"`
	}
	if err := json.Unmarshal(resJSON, &res); err != nil {
		return "", err
	}
	if res.Status == "" {
		res.Status = "error"
	}
	return res.Status, nil
}

// isTextDrop: markdown/plain-text extension AND actually valid UTF-8 (a
// mislabeled binary rides the attachment path instead of corrupting a text
// column).
func isTextDrop(rel string, data []byte) bool {
	switch strings.ToLower(filepath.Ext(rel)) {
	case ".md", ".markdown", ".txt":
		return utf8.Valid(data)
	}
	return false
}

// isDropJunk filters the editor/OS noise that shows up in any watched dir.
func isDropJunk(name string) bool {
	lower := strings.ToLower(name)
	switch lower {
	case "thumbs.db", "desktop.ini", ".ds_store":
		return true
	}
	if strings.HasSuffix(name, "~") || strings.HasPrefix(name, "~$") {
		return true
	}
	switch filepath.Ext(lower) {
	case ".tmp", ".swp", ".swo", ".partial", ".crdownload":
		return true
	}
	return false
}

func mimeForDrop(rel string) string {
	return mime.TypeByExtension(strings.ToLower(filepath.Ext(rel)))
}

func orNone(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}
