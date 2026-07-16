package main

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// decideWorktree is the fail-loud gate for coder_sandbox_start's no-repo branch
// (defect 2). The matrix IS the contract: a present worktree re-mounts, a
// repo-mode sandbox whose worktree vanished fails loud (the bug: it used to hand
// back an empty /work, so a review stage "reviewed" emptiness and a push died
// with `cannot change to '/worktrees/<id>'`), and a genuinely ephemeral
// code-write sandbox stays ephemeral (v1 behavior — must NOT regress to an
// error, since code-write shares the wi-<uuid8> id form).
func TestDecideWorktree(t *testing.T) {
	cases := []struct {
		name            string
		hasWorktree     bool
		expectsWorktree bool
		want            worktreeDecision
	}{
		{"worktree present -> remount", true, false, remountWorktree},
		{"worktree present, also expected -> remount", true, true, remountWorktree},
		{"gone but repo-mode expects it -> FAIL LOUD", false, true, failWorktreeGone},
		{"fresh code-write, none expected -> ephemeral", false, false, provisionEphemeral},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := decideWorktree(c.hasWorktree, c.expectsWorktree); got != c.want {
				t.Errorf("decideWorktree(has=%v, expects=%v) = %v, want %v",
					c.hasWorktree, c.expectsWorktree, got, c.want)
			}
		})
	}
}

// A nil pool (no STEWARDS_DSN) must NOT assert a worktree should exist — without
// the DB we cannot know, so we preserve the pre-existing ephemeral behavior
// rather than wrongly failing loud on a code-write run.
func TestSandboxExpectsWorktree_NilPool(t *testing.T) {
	if sandboxExpectsWorktree(context.Background(), nil, "wi-deadbeef") {
		t.Error("sandboxExpectsWorktree(nil pool) must be false (cannot assert -> don't break)")
	}
}

// Real-path proof of the discriminator against a Postgres carrying the
// pg_ai_stewards extension. Skipped unless CODER_TEST_DSN points at a SCRATCH DB
// (never the live stack). A code-pr sandbox belongs to a pipeline with a `clone`
// stage (a worktree should exist) => true; a code-write sandbox has no clone
// stage => false; an unknown id => false.
func TestSandboxExpectsWorktree_DB(t *testing.T) {
	dsn := os.Getenv("CODER_TEST_DSN")
	if dsn == "" {
		t.Skip("set CODER_TEST_DSN to a scratch pg_ai_stewards DB (never the live stack) to run")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	defer pool.Close()

	const prSb, cwSb = "wi-testpr01", "wi-testcw01"
	if _, err := pool.Exec(ctx, `
		WITH intent AS (
		  INSERT INTO stewards.intents (slug, purpose)
		  VALUES ('coder-test-intent', 'coder-mcp discriminator test fixture')
		  ON CONFLICT (slug) DO UPDATE SET purpose = EXCLUDED.purpose
		  RETURNING id
		)
		INSERT INTO stewards.work_items (pipeline_family, current_stage, intent_id, input)
		SELECT v.fam, v.stage, i.id, jsonb_build_object('sandbox', v.sb)
		  FROM intent i
		  CROSS JOIN (VALUES ('code-pr','clone',$1::text), ('code-write','plan',$2::text)) AS v(fam, stage, sb)
		`, prSb, cwSb); err != nil {
		t.Fatalf("seed work_items: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(),
			`DELETE FROM stewards.work_items WHERE input->>'sandbox' = ANY($1)`,
			[]string{prSb, cwSb})
	})

	if !sandboxExpectsWorktree(ctx, pool, prSb) {
		t.Error("code-pr sandbox (has a clone stage) must expect a worktree")
	}
	if sandboxExpectsWorktree(ctx, pool, cwSb) {
		t.Error("code-write sandbox (no clone stage) must NOT expect a worktree")
	}
	if sandboxExpectsWorktree(ctx, pool, "wi-doesnotexist") {
		t.Error("unknown sandbox id must not expect a worktree")
	}
}
