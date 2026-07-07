// Knowledge projector (v28 files-interface, feat/files-interface).
//
// Projects the substrate's prose rows into a greppable, PR-able markdown
// tree under STEWARDS_KNOWLEDGE_DIR (default /knowledge; compose mounts
// ./knowledge:/knowledge). The projection CATALOG lives in SQL
// (stewards.knowledge_projection_pending — extension/v28-files-interface
// .sql); this goroutine owns only the file I/O, mirroring the ratified
// autonomous-materializer split (bridge-side goroutine, LISTEN/NOTIFY +
// safety poll, path-validated writes — .spec/proposals/autonomous-
// materializer.md D-AM-1..3). Lineage: the founding research verdict
// (2026-05-02) — markdown files "become *projections* of canonical rows,
// not the canonical store."
//
// Cadence: one pass at startup, then LISTEN stewards_knowledge_projection
// (fired by stewards.knowledge_project_now() / `stewards-cli project`)
// with an hourly tick as the safety poll.
//
// Tree layout (from the SQL catalog; segments sanitized DB-side and
// re-validated here before any write):
//
//   knowledge/wiki/<scope-or-collection>/<slug>.md
//   knowledge/docs/<project>/<slug>.md
//   knowledge/lessons/lesson-<id>-<kind>.md
//
// Each file gets YAML frontmatter (id, kind, project, source_updated_at,
// projected_at, provenance) and is written atomically (temp + rename).
// Deletions (source row vanished / left scope) remove the file and forget
// the state row. If STEWARDS_KNOWLEDGE_DIR/.git exists, a changed pass is
// committed best-effort ("projection: <n> changed").
//
// ONE-WAY v1: edits made in the knowledge tree are NEVER read back — the
// drop directory (dropwatcher.go) is the write path into the substrate.
//
// Disabled when STEWARDS_PROJECTOR_DISABLED=1, or when the dir is absent.

package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	projectorNotifyChannel = "stewards_knowledge_projection"
	projectorTickInterval  = time.Hour
	projectorProvenance    = "projected from pg-ai-stewards — canonical store is the database; author changes via the drop directory"
)

// runProjector is started from runBridgeRun in a goroutine, mirroring
// runMaterializer's LISTEN + safety-poll shape. Returns only when ctx is
// done, or immediately when disabled/unconfigured.
func runProjector(ctx context.Context, pool *pgxpool.Pool) {
	if os.Getenv("STEWARDS_PROJECTOR_DISABLED") == "1" {
		log.Printf("projector: disabled via STEWARDS_PROJECTOR_DISABLED=1")
		return
	}

	dir := os.Getenv("STEWARDS_KNOWLEDGE_DIR")
	if dir == "" {
		dir = "/knowledge"
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		log.Printf("projector: knowledge dir %s not present (%v) — projection disabled. "+
			"Mount a directory there (compose: ./knowledge:/knowledge) to enable.", dir, err)
		return
	}
	if err := assertRepoRootWritable(dir); err != nil {
		log.Printf("projector: knowledge dir %s not writable (%v) — projection disabled. "+
			"Check the docker-compose mount.", dir, err)
		return
	}

	// Dedicated LISTEN conn, pinned via Hijack — same pattern as the
	// materializer and the main mcp_proxy listener.
	listenAcq, err := pool.Acquire(ctx)
	if err != nil {
		log.Printf("projector: acquire listen conn failed: %v — disabled", err)
		return
	}
	pgxConn := listenAcq.Hijack()
	defer pgxConn.Close(context.Background())

	if _, err := pgxConn.Exec(ctx, "LISTEN "+projectorNotifyChannel); err != nil {
		log.Printf("projector: LISTEN %s failed: %v — disabled", projectorNotifyChannel, err)
		return
	}
	log.Printf("projector: LISTENing on %s + %s safety tick (knowledge dir=%s)",
		projectorNotifyChannel, projectorTickInterval, dir)

	// Project once at startup to catch anything that changed while the
	// bridge was down.
	projectPass(ctx, pool, dir, "startup")

	for {
		waitCtx, cancel := context.WithTimeout(ctx, projectorTickInterval)
		_, err := pgxConn.WaitForNotification(waitCtx)
		cancel()

		if ctx.Err() != nil {
			log.Printf("projector: shutting down (ctx done)")
			return
		}
		if err != nil {
			if waitCtx.Err() == context.DeadlineExceeded {
				projectPass(ctx, pool, dir, "tick")
				continue
			}
			log.Printf("projector: WaitForNotification: %v (sleeping 5s)", err)
			time.Sleep(5 * time.Second)
			continue
		}
		projectPass(ctx, pool, dir, "notify")
	}
}

type projectionRow struct {
	action          string
	sourceKind      string
	sourceID        string
	targetPath      string
	title           *string
	body            *string
	project         *string
	sourceUpdatedAt *time.Time
	contentSha      *string
}

// projectPass drains stewards.knowledge_projection_pending() once:
// 'project' rows are written atomically + recorded; 'delete' rows are
// removed + forgotten. Errors are per-row (logged, row skipped — the
// watermark is only advanced AFTER a successful write, so the next pass
// retries). A changed pass ends with a best-effort git commit.
func projectPass(ctx context.Context, pool *pgxpool.Pool, dir, trigger string) {
	queryCtx, cancel := context.WithTimeout(ctx, 120*time.Second)
	rows, err := pool.Query(queryCtx,
		`SELECT action, source_kind, source_id, target_path, title, body,
		        project, source_updated_at, content_sha
		   FROM stewards.knowledge_projection_pending()`)
	if err != nil {
		cancel()
		log.Printf("projector: pending query failed (trigger=%s): %v", trigger, err)
		return
	}
	var pending []projectionRow
	for rows.Next() {
		var r projectionRow
		if err := rows.Scan(&r.action, &r.sourceKind, &r.sourceID, &r.targetPath,
			&r.title, &r.body, &r.project, &r.sourceUpdatedAt, &r.contentSha); err != nil {
			rows.Close()
			cancel()
			log.Printf("projector: scan failed (trigger=%s): %v", trigger, err)
			return
		}
		pending = append(pending, r)
	}
	rows.Close()
	cancel()
	if rows.Err() != nil {
		log.Printf("projector: pending rows failed (trigger=%s): %v", trigger, rows.Err())
		return
	}
	if len(pending) == 0 {
		return // dominant quiet case
	}

	var projected, deleted, failed int
	for _, r := range pending {
		if ctx.Err() != nil {
			return
		}
		rel, ok := safeKnowledgeRel(r.targetPath)
		if !ok {
			failed++
			log.Printf("projector: REFUSED unsafe target path %q (%s %s)", r.targetPath, r.sourceKind, r.sourceID)
			continue
		}
		full := filepath.Join(dir, filepath.FromSlash(rel))

		switch r.action {
		case "project":
			if err := writeFileAtomic(full, renderKnowledgeFile(r)); err != nil {
				failed++
				log.Printf("projector: write %s failed: %v", rel, err)
				continue
			}
			// Record the watermark AFTER the write lands; a record failure
			// just means the next pass rewrites the same bytes (idempotent).
			var oldPath *string
			recCtx, recCancel := context.WithTimeout(ctx, 30*time.Second)
			err := pool.QueryRow(recCtx,
				"SELECT stewards.knowledge_projection_record($1,$2,$3,$4,$5)",
				r.sourceKind, r.sourceID, rel, r.sourceUpdatedAt, r.contentSha).Scan(&oldPath)
			recCancel()
			if err != nil {
				failed++
				log.Printf("projector: record %s failed: %v (file written; next pass re-records)", rel, err)
				continue
			}
			// The projection moved (project reassigned / slug changed) —
			// remove the orphaned prior file.
			if oldPath != nil {
				if oldRel, ok := safeKnowledgeRel(*oldPath); ok && oldRel != rel {
					_ = os.Remove(filepath.Join(dir, filepath.FromSlash(oldRel)))
				}
			}
			projected++

		case "delete":
			if err := os.Remove(full); err != nil && !os.IsNotExist(err) {
				failed++
				log.Printf("projector: delete %s failed: %v", rel, err)
				continue
			}
			fgCtx, fgCancel := context.WithTimeout(ctx, 30*time.Second)
			_, err := pool.Exec(fgCtx,
				"SELECT stewards.knowledge_projection_forget($1,$2)", r.sourceKind, r.sourceID)
			fgCancel()
			if err != nil {
				failed++
				log.Printf("projector: forget %s/%s failed: %v", r.sourceKind, r.sourceID, err)
				continue
			}
			deleted++

		default:
			failed++
			log.Printf("projector: unknown action %q for %s %s", r.action, r.sourceKind, r.sourceID)
		}
	}

	log.Printf("projector: pass trigger=%s — %d projected, %d deleted, %d failed",
		trigger, projected, deleted, failed)
	if projected+deleted > 0 {
		gitCommitKnowledge(ctx, dir, projected+deleted)
	}
}

// safeKnowledgeRel validates a catalog-supplied relative path before any
// filesystem operation — same discipline as the materializer's repo-root
// validation. The SQL sanitizer makes traversal structurally impossible,
// but the bridge does not TRUST that: it re-checks.
func safeKnowledgeRel(p string) (string, bool) {
	p = strings.TrimPrefix(strings.TrimSpace(p), "/")
	if p == "" || strings.Contains(p, "\\") {
		return "", false
	}
	clean := path.Clean(p)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", false
	}
	for _, seg := range strings.Split(clean, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return "", false
		}
	}
	return clean, true
}

// renderKnowledgeFile composes YAML frontmatter + the body. The
// frontmatter is the provenance stamp the four-layer ruling requires on
// every projected file.
func renderKnowledgeFile(r projectionRow) []byte {
	var b strings.Builder
	b.WriteString("---\n")
	fmt.Fprintf(&b, "id: %s\n", yamlQuote(r.sourceID))
	fmt.Fprintf(&b, "kind: %s\n", yamlQuote(r.sourceKind))
	if r.project != nil && *r.project != "" {
		fmt.Fprintf(&b, "project: %s\n", yamlQuote(*r.project))
	}
	if r.title != nil && *r.title != "" {
		fmt.Fprintf(&b, "title: %s\n", yamlQuote(*r.title))
	}
	if r.sourceUpdatedAt != nil {
		fmt.Fprintf(&b, "source_updated_at: %s\n", r.sourceUpdatedAt.UTC().Format(time.RFC3339))
	}
	fmt.Fprintf(&b, "projected_at: %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&b, "provenance: %s\n", yamlQuote(projectorProvenance))
	b.WriteString("---\n\n")
	if r.body != nil {
		b.WriteString(*r.body)
	}
	if !strings.HasSuffix(b.String(), "\n") {
		b.WriteString("\n")
	}
	return []byte(b.String())
}

// yamlQuote renders s as a YAML double-quoted scalar (escapes are a
// superset-compatible subset of YAML's double-quote style).
func yamlQuote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				fmt.Fprintf(&b, `\x%02X`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// writeFileAtomic writes via temp-file-in-same-dir + rename, so a reader
// (or a crash) never sees a half-written projection.
func writeFileAtomic(full string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(full), "."+filepath.Base(full)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, full); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return nil
}

// gitCommitKnowledge: if the knowledge dir is itself a git repo, commit the
// pass. Best-effort by contract — absent git or a .git dir, silently skip;
// a failed commit logs and moves on (the files are already on disk).
func gitCommitKnowledge(ctx context.Context, dir string, changed int) {
	if fi, err := os.Stat(filepath.Join(dir, ".git")); err != nil || !fi.IsDir() {
		return
	}
	if _, err := exec.LookPath("git"); err != nil {
		return
	}
	gitCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	// safe.directory: a bind-mounted repo is routinely "owned" by a
	// different uid than the container process — without this, git
	// refuses with "dubious ownership" and the best-effort commit
	// silently never happens.
	safeDir := "safe.directory=" + dir

	add := exec.CommandContext(gitCtx, "git", "-C", dir, "-c", safeDir, "add", "-A")
	if out, err := add.CombinedOutput(); err != nil {
		log.Printf("projector: git add failed (best-effort): %v: %s", err, summarizeOutput(out))
		return
	}
	// Nothing staged (e.g. identical bytes rewritten) — skip the commit.
	diff := exec.CommandContext(gitCtx, "git", "-C", dir, "-c", safeDir, "diff", "--cached", "--quiet")
	if err := diff.Run(); err == nil {
		return
	}
	commit := exec.CommandContext(gitCtx, "git", "-C", dir, "-c", safeDir,
		"-c", "user.name=pg-ai-stewards projector",
		"-c", "user.email=pg-ai-stewards@localhost",
		"commit", "-m", fmt.Sprintf("projection: %d changed", changed))
	if out, err := commit.CombinedOutput(); err != nil {
		log.Printf("projector: git commit failed (best-effort): %v: %s", err, summarizeOutput(out))
		return
	}
	log.Printf("projector: committed knowledge pass (%d changed)", changed)
}
