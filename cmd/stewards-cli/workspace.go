// stewards-cli workspace — create/list db-projected workspaces (v30,
// .spec/proposals/db-projected-workspace.md P2: the loom seat).
//
//	stewards-cli workspace create <name> --scope <kind>:<ref> [--for-loom] [--created-by X]
//	stewards-cli workspace list
//
// create registers the workspace (stewards.workspace_create — opt-in per
// workspace, the wall), which fires the projection NOTIFY; the BRIDGE's
// projector then writes the files (same division of labor as `stewards-cli
// project`: the knowledge dir is mounted into the bridge container, so the
// CLI never writes projection files itself). The CLI polls the workspace's
// pending count so "create" returns with the tree actually on disk when a
// bridge is running, then prints the absolute HOST directory a harness can
// open. --for-loom additionally prints a ready-to-run
// `loom run --workdir <dir>` line — a Claude Code seat authoring INSIDE
// the database: saves land as canonical rows within one 30s watcher poll,
// sha-guarded, provenance-stamped.
//
// The host directory is resolved from $KNOWLEDGE_DIR (the same variable
// docker-compose.yaml uses for the ./knowledge:/knowledge mount), default
// ./knowledge relative to the current directory.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/cpuchip/pg-ai-stewards/cmd/stewards-cli/internal/db"
	"github.com/jackc/pgx/v5/pgxpool"
)

func runWorkspace(ctx context.Context, args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "workspace: subcommand required (create|list)")
		os.Exit(1)
	}
	pool, err := db.Connect(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "db: %v\n", err)
		os.Exit(1)
	}
	defer pool.Close()

	switch args[0] {
	case "create":
		runWorkspaceCreate(ctx, pool, args[1:])
	case "list":
		runWorkspaceList(ctx, pool)
	default:
		fmt.Fprintf(os.Stderr, "workspace: unknown subcommand %q (create|list)\n", args[0])
		os.Exit(1)
	}
}

func runWorkspaceCreate(ctx context.Context, pool *pgxpool.Pool, args []string) {
	fs := flag.NewFlagSet("workspace create", flag.ExitOnError)
	scope := fs.String("scope", "", "<kind>:<ref> — project:<name> | wiki:<slug> | world:<slug> | doc-kind:<kind> (required)")
	forLoom := fs.Bool("for-loom", false, "print a ready-to-run `loom run --workdir <dir>` line")
	createdBy := fs.String("created-by", "cli", "recorded as knowledge_workspaces.created_by")
	wait := fs.Int("wait", 30, "seconds to wait for the bridge's projector to land the files (0 = don't wait)")
	// The documented shape is name-first (`workspace create <name> --scope
	// ...`), but Go's flag package stops parsing at the first positional —
	// so peel the name off the front when it's there, and fall back to
	// flags-first (`--scope ... <name>`) otherwise.
	name := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		name = args[0]
		args = args[1:]
	}
	if err := fs.Parse(args); err != nil {
		os.Exit(1)
	}
	if name == "" && fs.NArg() == 1 {
		name = fs.Arg(0)
	}
	if name == "" || *scope == "" {
		fmt.Fprintln(os.Stderr, "workspace create: <name> and --scope <kind>:<ref> required")
		os.Exit(1)
	}
	idx := strings.Index(*scope, ":")
	if idx <= 0 || idx == len(*scope)-1 {
		fmt.Fprintf(os.Stderr, "workspace create: --scope must be <kind>:<ref>, got %q\n", *scope)
		os.Exit(1)
	}
	scopeKind, scopeRef := (*scope)[:idx], (*scope)[idx+1:]

	var resJSON []byte
	if err := pool.QueryRow(ctx,
		"SELECT stewards.workspace_create($1, $2, $3, $4)",
		name, scopeKind, scopeRef, *createdBy).Scan(&resJSON); err != nil {
		fmt.Fprintf(os.Stderr, "workspace create: %v\n", err)
		os.Exit(1)
	}
	var res struct {
		OK      bool   `json:"ok"`
		Error   string `json:"error"`
		Existed bool   `json:"existed"`
		Name    string `json:"workspace"`
		Dir     string `json:"dir"`
		Pending int    `json:"pending"`
	}
	if err := json.Unmarshal(resJSON, &res); err != nil {
		fmt.Fprintf(os.Stderr, "workspace create: decode result: %v\n", err)
		os.Exit(1)
	}
	if !res.OK {
		fmt.Fprintf(os.Stderr, "workspace create: %s\n", res.Error)
		os.Exit(1)
	}
	if res.Existed {
		fmt.Printf("workspace %q already registered (same scope) — reusing it\n", res.Name)
	} else {
		fmt.Printf("workspace %q registered (scope %s:%s, %d row(s) to project)\n",
			res.Name, scopeKind, scopeRef, res.Pending)
	}

	// The registration already fired the projection NOTIFY; poll until the
	// bridge's projector drains this workspace (or the wait budget runs
	// out — a down bridge is not an error, just a slower landing).
	landed := res.Pending == 0
	if !landed && *wait > 0 {
		fmt.Printf("waiting for the bridge's projector to land the files (up to %ds)...\n", *wait)
		deadline := time.Now().Add(time.Duration(*wait) * time.Second)
		for time.Now().Before(deadline) {
			time.Sleep(2 * time.Second)
			var pending int
			if err := pool.QueryRow(ctx,
				"SELECT count(*) FROM stewards.workspace_projection_pending($1) p WHERE p.action = 'project'",
				res.Name).Scan(&pending); err != nil {
				fmt.Fprintf(os.Stderr, "workspace create: pending poll: %v\n", err)
				break
			}
			if pending == 0 {
				landed = true
				break
			}
		}
	}

	hostDir := workspaceHostDir(res.Dir)
	if landed {
		fmt.Printf("projection landed. Workspace directory (host):\n\n    %s\n\n", hostDir)
	} else {
		fmt.Printf("projection still pending — is the bridge running? Files land on its next pass (startup/NOTIFY/hourly).\nWorkspace directory (host, once projected):\n\n    %s\n\n", hostDir)
	}
	fmt.Printf("Edits saved in this directory land as canonical rows within one 30s poll\n")
	fmt.Printf("(sha-guarded — a row that changed underneath you parks a conflict instead of clobbering).\n")
	if *forLoom {
		fmt.Printf("\nrun a Claude Code seat inside the database:\n\n    loom run --workdir %s\n", hostDir)
	}
}

// workspaceHostDir resolves the HOST path of a workspace dir: the compose
// mount's host side ($KNOWLEDGE_DIR, default ./knowledge) + the registry's
// relative dir.
func workspaceHostDir(wsDir string) string {
	base := os.Getenv("KNOWLEDGE_DIR")
	if base == "" {
		base = "./knowledge"
	}
	abs, err := filepath.Abs(filepath.Join(base, filepath.FromSlash(wsDir)))
	if err != nil {
		return filepath.Join(base, filepath.FromSlash(wsDir))
	}
	return abs
}

func runWorkspaceList(ctx context.Context, pool *pgxpool.Pool) {
	rows, err := pool.Query(ctx, `
		SELECT name, scope_kind, scope_ref, dir, projected, pending, conflicts,
		       coalesce(to_char(last_writeback_at, 'YYYY-MM-DD HH24:MI'), '-')
		  FROM stewards.workspace_list()`)
	if err != nil {
		fmt.Fprintf(os.Stderr, "workspace list: %v\n", err)
		os.Exit(1)
	}
	defer rows.Close()

	w := tabwriter.NewWriter(os.Stdout, 2, 4, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tSCOPE\tDIR\tPROJECTED\tPENDING\tCONFLICTS\tLAST WRITE-BACK")
	n := 0
	for rows.Next() {
		var name, kind, ref, dir, lastWB string
		var projected, pending, conflicts int64
		if err := rows.Scan(&name, &kind, &ref, &dir, &projected, &pending, &conflicts, &lastWB); err != nil {
			fmt.Fprintf(os.Stderr, "workspace list: scan: %v\n", err)
			os.Exit(1)
		}
		fmt.Fprintf(w, "%s\t%s:%s\t%s\t%d\t%d\t%d\t%s\n",
			name, kind, ref, dir, projected, pending, conflicts, lastWB)
		n++
	}
	if err := rows.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "workspace list: rows: %v\n", err)
		os.Exit(1)
	}
	w.Flush()
	if n == 0 {
		fmt.Println("(no workspaces registered — `stewards-cli workspace create <name> --scope project:<name>`)")
	}
}
