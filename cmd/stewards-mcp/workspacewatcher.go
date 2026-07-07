// Workspace watcher (v30 db-projected-workspace, feat/full-treatment).
//
// The read-back half of the writable projection: scans every REGISTERED
// workspace dir (stewards.knowledge_workspaces — the wall: nothing outside
// the registry is ever read back) under STEWARDS_KNOWLEDGE_DIR and calls
// stewards.workspace_writeback for changed files. The sha-triple decision
// (apply / noop / create / conflict) lives entirely in SQL so it is
// transactional; this loop only detects change, ships bytes, and logs the
// outcome. The frontmatter parse that identifies target rows is ALSO
// SQL-side (one authoritative parser) — the raw file goes down the wire.
//
// POLL-FIRST BY DESIGN (same contract as dropwatcher.go): 30s poll, no
// inotify — events don't cross Docker Desktop bind mounts on Windows.
// "Live in the db" = within one poll of save
// (.spec/proposals/db-projected-workspace.md, decision 5).
//
// Change detection: an in-memory map of (workspace, relpath) -> raw-file
// sha256, updated after each writeback call. Empty on startup, so the
// first pass replays every file — deliberately: edits made while the
// bridge was down land on boot, and unchanged files no-op cheaply in SQL
// (S_file = S_proj). Files whose writeback errors are marked seen too (a
// permanently broken file must not churn every 30s); change the file or
// restart the bridge to retry — the error is logged LOUD either way.
//
// Only text files ride (md/markdown/txt, valid UTF-8 — same isTextDrop
// gate as the drop watcher); junk and dotfiles are skipped. Binary assets
// do not belong in a prose workspace.
//
// Disabled when STEWARDS_WORKSPACES_DISABLED=1, when the knowledge dir is
// absent, or (per-boot, logged once) when the database predates v30.
//
// Companion SQL: extension/v30-workspaces.sql. Projection INTO workspace
// dirs rides the projector's pass (projector.go — the chosen seam).

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	workspacePollInterval = 30 * time.Second
	workspaceMaxFileBytes = 10 << 20 // 10 MB — workspaces hold prose; bigger is a mistake worth a log line
)

// runWorkspaceWatcher is started from runBridgeRun in a goroutine,
// mirroring runDropWatcher's shape. Returns only when ctx is done, or
// immediately when disabled/unconfigured.
func runWorkspaceWatcher(ctx context.Context, pool *pgxpool.Pool) {
	if os.Getenv("STEWARDS_WORKSPACES_DISABLED") == "1" {
		log.Printf("workspace-watcher: disabled via STEWARDS_WORKSPACES_DISABLED=1")
		return
	}

	dir := os.Getenv("STEWARDS_KNOWLEDGE_DIR")
	if dir == "" {
		dir = "/knowledge"
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		log.Printf("workspace-watcher: knowledge dir %s not present (%v) — workspace write-back disabled. "+
			"Mount a directory there (compose: ./knowledge:/knowledge) to enable.", dir, err)
		return
	}

	// Older database (pre-v30): disable cleanly rather than erroring every
	// pass — the bridge and the chain migrate on different clocks.
	var hasV30 bool
	if err := pool.QueryRow(ctx,
		"SELECT to_regprocedure('stewards.workspace_writeback(text,text,text,text,text)') IS NOT NULL",
	).Scan(&hasV30); err != nil || !hasV30 {
		log.Printf("workspace-watcher: stewards.workspace_writeback not installed (v30 not applied yet; err=%v) — "+
			"workspace write-back disabled this boot. Apply the chain and restart the bridge.", err)
		return
	}

	actor := os.Getenv("STEWARDS_WORKSPACE_ACTOR")
	if actor == "" {
		actor = "file-edit" // the spec's default actor for anonymous saves
	}

	w := &workspaceWatcher{pool: pool, root: dir, actor: actor, seen: map[string]string{}}
	log.Printf("workspace-watcher: watching registered workspaces under %s (poll every %s — the poll IS the contract; actor=%s)",
		dir, workspacePollInterval, actor)

	w.scan(ctx)

	ticker := time.NewTicker(workspacePollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Printf("workspace-watcher: shutting down (ctx done)")
			return
		case <-ticker.C:
			w.scan(ctx)
		}
	}
}

type workspaceWatcher struct {
	pool  *pgxpool.Pool
	root  string
	actor string
	// seen maps workspace + "\x00" + relpath -> raw-file sha256 last handed
	// to workspace_writeback. Change detection only; the sha-triple truth
	// lives DB-side.
	seen map[string]string
}

// scan is one full pass over every registered workspace dir. Never returns
// an error — per-file failures are logged and the pass continues.
func (w *workspaceWatcher) scan(ctx context.Context) {
	workspaces, err := w.loadRegistry(ctx)
	if err != nil {
		log.Printf("workspace-watcher: registry read failed (%v) — skipping this pass", err)
		return
	}
	if len(workspaces) == 0 {
		return // nothing registered — the dominant quiet case
	}

	var applied, created, conflicts, errored int
	for name, wsDir := range workspaces {
		if ctx.Err() != nil {
			return
		}
		// The registry's dir is DB-supplied — validate with the same
		// discipline the projector applies to catalog paths.
		rel, ok := safeKnowledgeRel(wsDir)
		if !ok {
			log.Printf("workspace-watcher: REFUSED unsafe workspace dir %q (workspace %s)", wsDir, name)
			continue
		}
		base := filepath.Join(w.root, filepath.FromSlash(rel))
		if fi, err := os.Stat(base); err != nil || !fi.IsDir() {
			continue // not projected yet — the projector creates it on its next pass
		}

		walkErr := filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				log.Printf("workspace-watcher: walk %s: %v (skipping)", p, err)
				return nil
			}
			name2 := d.Name()
			if d.IsDir() {
				if p != base && strings.HasPrefix(name2, ".") {
					return filepath.SkipDir
				}
				return nil
			}
			if strings.HasPrefix(name2, ".") || isDropJunk(name2) {
				return nil
			}

			fileRel, rerr := filepath.Rel(base, p)
			if rerr != nil {
				return nil
			}
			fileRel = filepath.ToSlash(fileRel)

			if info, ierr := d.Info(); ierr == nil && info.Size() > workspaceMaxFileBytes {
				log.Printf("workspace-watcher: %s/%s is %d bytes (> %d cap) — skipped (workspaces hold prose)",
					name, fileRel, info.Size(), int64(workspaceMaxFileBytes))
				return nil
			}

			data, rderr := os.ReadFile(p)
			if rderr != nil {
				log.Printf("workspace-watcher: read %s/%s: %v (skipping; likely mid-write — next poll retries)",
					name, fileRel, rderr)
				return nil
			}
			if !isTextDrop(fileRel, data) {
				return nil // non-text in a prose workspace: ignored by contract
			}

			sum := sha256.Sum256(data)
			sha := hex.EncodeToString(sum[:])
			key := name + "\x00" + fileRel
			if w.seen[key] == sha {
				return nil // unchanged since we last shipped it
			}

			status, note, cbErr := w.writebackOne(ctx, name, fileRel, data, sha)
			// Mark seen regardless of outcome: SQL is idempotent for the
			// same bytes, so re-shipping identical content every 30s only
			// burns cycles. A content change (new sha) always retries.
			w.seen[key] = sha
			switch {
			case cbErr != nil:
				errored++
				log.Printf("workspace-watcher: %s/%s: writeback call FAILED: %v (will retry when the file changes, or restart the bridge)",
					name, fileRel, cbErr)
			case status == "applied":
				applied++
				log.Printf("workspace-watcher: applied %s/%s -> row updated with revision (sha=%s...)", name, fileRel, sha[:12])
			case status == "created":
				created++
				log.Printf("workspace-watcher: created %s/%s -> NEW row in scope (%s)", name, fileRel, note)
			case status == "conflict":
				conflicts++
				log.Printf("workspace-watcher: CONFLICT %s/%s parked, row untouched: %s", name, fileRel, note)
			case status == "noop":
				// quiet — the dominant case (projector-written files round-trip here)
			default:
				errored++
				log.Printf("workspace-watcher: %s/%s landed status=%s: %s", name, fileRel, status, note)
			}
			return nil
		})
		if walkErr != nil && ctx.Err() == nil {
			log.Printf("workspace-watcher: walk %s aborted: %v", name, walkErr)
		}
	}

	if applied > 0 || created > 0 || conflicts > 0 || errored > 0 {
		log.Printf("workspace-watcher: pass done — %d applied, %d created, %d conflict(s), %d errored",
			applied, created, conflicts, errored)
	}
}

// loadRegistry snapshots name -> dir for every registered workspace.
func (w *workspaceWatcher) loadRegistry(ctx context.Context) (map[string]string, error) {
	rows, err := w.pool.Query(ctx, "SELECT name, dir FROM stewards.knowledge_workspaces")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var name, dir string
		if err := rows.Scan(&name, &dir); err != nil {
			return nil, err
		}
		out[name] = dir
	}
	return out, rows.Err()
}

// writebackOne ships one raw file to stewards.workspace_writeback and
// returns (status, note-or-error, transport-error).
func (w *workspaceWatcher) writebackOne(ctx context.Context, workspace, rel string, data []byte, sha string) (string, string, error) {
	callCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	var resJSON []byte
	err := w.pool.QueryRow(callCtx,
		"SELECT stewards.workspace_writeback($1, $2, $3, $4, $5)",
		workspace, rel, string(data), sha, w.actor).Scan(&resJSON)
	if err != nil {
		return "", "", err
	}

	var res struct {
		Status string `json:"status"`
		Note   string `json:"note"`
		Reason string `json:"reason"`
		Error  string `json:"error"`
	}
	if err := json.Unmarshal(resJSON, &res); err != nil {
		return "", "", err
	}
	note := res.Note
	if note == "" {
		note = res.Reason
	}
	if note == "" {
		note = res.Error
	}
	if res.Status == "" {
		res.Status = "error"
	}
	return res.Status, note, nil
}
