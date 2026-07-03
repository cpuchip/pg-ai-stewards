// harness_home_init.go — the `stewards-mcp harness-home-init` subcommand.
//
// harness_run mounts STEWARDS_HARNESS_CLAUDE_HOME as the dispatched
// container's ~/.claude (the header of harness.go explains why it's a
// dedicated dir, not the operator's real one). Until now nothing ever seeded
// that directory: a fresh one held only what `claude` itself creates on first
// run (.credentials.json, session state) — no CLAUDE.md telling the dispatched
// harness what it is, no settings tuned for a headless/isolated/non-
// interactive container. This subcommand is that seeding, as CODE (not a
// one-off `Write` into ~/.stewards/harness-claude-home) so it is
// version-controlled, re-runnable on a fresh box, and idempotent — it never
// clobbers an existing CLAUDE.md/settings.json (which may carry an operator's
// hand edits, or nothing at all to lose) unless -force is passed, and it
// never touches anything else loom/claude manage in that dir (sessions/,
// .credentials.json, shell-snapshots/, ...).
//
// Usage:
//
//	stewards-mcp harness-home-init [-home DIR] [-force]
//
// Default DIR is $STEWARDS_HARNESS_CLAUDE_HOME, else
// <user home>/.stewards/harness-claude-home — the same resolution harness.go
// itself uses, so running this with no flags seeds the SAME directory a
// harness_run dispatch will actually mount.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// harnessHomeClaudeMD orients a dispatched harness: what it is, what it can
// reach, and what "done" looks like. Single-quoted tool names (not backtick
// code spans) so this stays a plain Go string literal.
const harnessHomeClaudeMD = `# You are a dispatched steward, not the operator

You are a Claude Code instance dispatched by pg-ai-stewards' harness_run (via
loom) — not the interactive session Michael drives elsewhere, and not the
substrate itself. Nobody is watching this run in real time. Do the task,
deliver the artifact, stop.

## Where you are

You are running --isolate: a docker sandbox that sees ONLY the bind-mounted
workdir (/work) and this claude-home. The container is ephemeral (--rm) —
nothing you write outside /work and outside the substrate (see below)
survives past this run. /work is your corpus: read it with Read/Glob/Grep.
There is no Bash tool here — you cannot run shell commands or write loose
files, on purpose. If your task is "read this and tell me" or "build this
document," that is the whole point: the substrate reads /work and your tool
calls, not a shell transcript.

## What you can reach

Whatever appears in your tool list under the mcp__pg-ai-stewards__ prefix is
your ENTIRE reach into the substrate — nothing else exists for you, whether
or not it sounds plausible. Read tools (always present when the hinge is
wired): doc_search, doc_get, doc_similar, doc_citations, work_item_show,
work_item_list, list_models.

When the operator has wired the write set, you will ALSO see:
  - doc_create / doc_append_section / doc_patch / doc_read / doc_finalize /
    doc_current — build and pool ONE document. Start with doc_create (returns
    a handle), add sections with doc_append_section (small calls, one section
    each), fix mistakes with doc_patch, and call doc_finalize exactly once
    when it's done — the slug it returns is your delivery proof. doc_current
    finds the handle again if you lose track of it.
  - a2a_note / a2a_note_clear — leave an async note for whoever is waiting on
    this dispatch (they read it on their next engagement; you do not get a
    reply back in this run).

If a tool is not in your list, it is not reachable. Do not assume
a2a_submit, a2a_claim, spawn_subagent, or any coder_* tool exists just
because you have heard of it — those are walled off by design, not by
convention, and a call to one will simply fail as an unknown tool.

## Deliver, don't narrate

Your job is to PRODUCE the artifact (a pooled doc slug and/or a note), not to
describe what you would produce. Prefer the write tools above over echoing
the whole document back in your final reply.

## Be concise

Your final assistant message is returned VERBATIM as the harness_run result
text. Keep it a short journal — what you read, what you decided, what you
produced (slug / note recipient) — not a restatement of the document itself.
`

func runHarnessHomeInit(args []string) error {
	fs := flag.NewFlagSet("harness-home-init", flag.ContinueOnError)
	home := fs.String("home", "", "claude-home dir to seed (default: $STEWARDS_HARNESS_CLAUDE_HOME, else <user home>/.stewards/harness-claude-home — the same resolution harness_run itself uses)")
	force := fs.Bool("force", false, "overwrite CLAUDE.md/settings.json even if they already exist (default: leave existing files untouched)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	dir := strings.TrimSpace(*home)
	if dir == "" {
		dir = strings.TrimSpace(os.Getenv("STEWARDS_HARNESS_CLAUDE_HOME"))
	}
	if dir == "" {
		uh, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("harness-home-init: resolve home dir: %w (pass -home or set STEWARDS_HARNESS_CLAUDE_HOME)", err)
		}
		dir = filepath.Join(uh, ".stewards", "harness-claude-home")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("harness-home-init: mkdir %q: %w", dir, err)
	}

	claudeMDPath := filepath.Join(dir, "CLAUDE.md")
	wrote, err := writeIfAbsent(claudeMDPath, []byte(harnessHomeClaudeMD), *force)
	if err != nil {
		return fmt.Errorf("harness-home-init: %w", err)
	}
	logSeedResult(claudeMDPath, wrote)

	settingsRaw, err := json.MarshalIndent(harnessHomeSettings(), "", "  ")
	if err != nil {
		return fmt.Errorf("harness-home-init: encode settings.json: %w", err)
	}
	settingsPath := filepath.Join(dir, "settings.json")
	wrote, err = writeIfAbsent(settingsPath, append(settingsRaw, '\n'), *force)
	if err != nil {
		return fmt.Errorf("harness-home-init: %w", err)
	}
	logSeedResult(settingsPath, wrote)

	fmt.Printf("harness-home-init: %s ready\n", dir)
	return nil
}

func logSeedResult(path string, wrote bool) {
	if wrote {
		log.Printf("harness-home-init: wrote %s", path)
	} else {
		log.Printf("harness-home-init: %s already exists — left untouched (pass -force to overwrite)", path)
	}
}

// harnessHomeSettings are the sensible defaults for a headless, isolated,
// non-interactive claude-home. Each dispatch is a fresh --rm container, so
// there is nothing to "update" between runs and no human present to see a
// telemetry/feedback prompt — CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC covers
// the telemetry/error-reporting/feedback group in one flag,
// DISABLE_AUTOUPDATER separately (it is not folded into that shorthand).
// includeCoAuthoredBy:false because if this steward's work ever lands in a
// commit trailer, its identity is "a dispatched steward," not "Claude Code
// the product." (Auth is untouched — loom mounts the user's
// .credentials.json read-only regardless of anything here.)
func harnessHomeSettings() map[string]any {
	return map[string]any{
		"includeCoAuthoredBy": false,
		"env": map[string]string{
			"DISABLE_AUTOUPDATER":                      "1",
			"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
		},
	}
}

// writeIfAbsent writes data to path unless it already exists — idempotent by
// default (never clobbers resume state, an operator's hand edits, or a
// previous seeding) — unless force is set.
func writeIfAbsent(path string, data []byte, force bool) (bool, error) {
	if !force {
		if _, statErr := os.Stat(path); statErr == nil {
			return false, nil
		} else if !os.IsNotExist(statErr) {
			return false, statErr
		}
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return false, err
	}
	return true, nil
}
