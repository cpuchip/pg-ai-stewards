// stewards-cli project — force a knowledge-projection pass (v28
// files-interface).
//
// The bridge's projector (cmd/stewards-mcp/projector.go) LISTENs on
// stewards_knowledge_projection and re-projects changed wiki pages /
// docs / lessons into the knowledge tree on an hourly safety tick. This
// verb fires that NOTIFY (via stewards.knowledge_project_now()) so a
// human doesn't have to wait for the tick.
//
// The NOTIFY is deliberately the whole job: the knowledge directory is
// mounted into the BRIDGE container (compose ./knowledge:/knowledge), so
// a direct CLI-side projection would write to the wrong filesystem on
// every dockerized deploy. The bridge owns the file I/O; the CLI just
// rings the bell. --pending previews what the next pass will do.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/cpuchip/pg-ai-stewards/cmd/stewards-cli/internal/db"
)

func runProject(ctx context.Context, args []string) {
	fs := flag.NewFlagSet("project", flag.ExitOnError)
	pending := fs.Bool("pending", false, "list what the next projector pass will project/delete, without firing it")
	if err := fs.Parse(args); err != nil {
		os.Exit(1)
	}

	pool, err := db.Connect(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "db: %v\n", err)
		os.Exit(1)
	}
	defer pool.Close()

	if *pending {
		rows, err := pool.Query(ctx,
			`SELECT action, source_kind, source_id, target_path
			   FROM stewards.knowledge_projection_pending()
			  ORDER BY action, target_path`)
		if err != nil {
			fmt.Fprintf(os.Stderr, "project: pending query: %v\n", err)
			os.Exit(1)
		}
		defer rows.Close()
		n := 0
		for rows.Next() {
			var action, kind, id, target string
			if err := rows.Scan(&action, &kind, &id, &target); err != nil {
				fmt.Fprintf(os.Stderr, "project: scan: %v\n", err)
				os.Exit(1)
			}
			fmt.Printf("%-8s %-10s %-40s %s\n", action, kind, target, id)
			n++
		}
		if err := rows.Err(); err != nil {
			fmt.Fprintf(os.Stderr, "project: rows: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("project: %d row(s) pending\n", n)
		return
	}

	if _, err := pool.Exec(ctx, "SELECT stewards.knowledge_project_now()"); err != nil {
		fmt.Fprintf(os.Stderr, "project: notify: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("project: NOTIFY stewards_knowledge_projection sent — the bridge's projector will run a pass (check its logs; hourly tick + startup pass are the fallback if the bridge is down)")
}
