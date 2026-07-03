// stewards-cli migrate — RETIRED (2026-07-03, audit-synthesis-2026-07.md §IV
// Track 2, "one blessed runner, not two").
//
// This command used to apply extension/*.sql files directly against
// "projects/pg-ai-stewards/extension" — the OLD monorepo layout. In THIS
// (OSS) repo the extension chain lives at "extension/" off the repo root,
// so that path never resolves here; it also ordered files with sort.Strings
// (a plain lexical directory listing) with zero awareness of a downstream
// overlays/migration-manifest.txt. That made it the SECOND wrong apply-order
// the audit found — scripts/migrate.sh (which used `ls | sort -V`) was the
// first, and is now the fixed, manifest-obedient, requires-core-checking
// runner. Two runners disagreeing on order is exactly how cut3-restore-
// core-finals.sql's "runs LAST so core finals win" landmine happened.
//
// The fix here is retirement, not a repointed path: this command's whole
// job (apply the core chain directly, file by file, outside the pgrx
// package/CREATE EXTENSION path) is now scripts/migrate.sh's job too, and
// having both invite exactly the drift this audit closed. Keep this stub so
// a stale `stewards-cli migrate` invocation — a script, a muscle-memory
// habit, a stale doc — fails LOUD with a pointer to the real runner instead
// of silently walking a path that doesn't exist and doing nothing.
//
// See: docs/operations.md (the one-page runbook), scripts/migrate.sh.
package main

import (
	"context"
	"fmt"
	"os"
)

func runMigrate(_ context.Context, _ []string) {
	fmt.Fprintln(os.Stderr, "stewards-cli migrate: RETIRED — this command is no longer maintained.")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Use scripts/migrate.sh instead (the one blessed runner — docs/operations.md):")
	fmt.Fprintln(os.Stderr, "  STEWARDS_DSN=postgres://stewards:stewards@localhost:5432/stewards ./scripts/migrate.sh [apply|adopt|status]")
	fmt.Fprintln(os.Stderr, "  OVERLAY_DIR=<path to your overlays/> ./scripts/migrate.sh   # + this box's overlays, manifest-ordered")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Why retired: this command pointed at the old monorepo extension path (which does not")
	fmt.Fprintln(os.Stderr, "exist in this repo) and applied files in a plain lexical sort with no")
	fmt.Fprintln(os.Stderr, "migration-manifest.txt awareness — the second of the two wrong apply-orders named in")
	fmt.Fprintln(os.Stderr, ".spec/proposals/audit-synthesis-2026-07.md §IV. scripts/migrate.sh is now manifest-")
	fmt.Fprintln(os.Stderr, "obedient and enforces requires-core headers via stewards.assert_core_compat().")
	os.Exit(1)
}
