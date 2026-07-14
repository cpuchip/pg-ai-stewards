// Seed memory (S1) — a dynamically generated overview of what the substrate
// corpus holds, injected into the client LLM at session start through BOTH
// channels that reach it:
//
//  1. the MCP `instructions` field (the "standards channel" — lands in the
//     client's system prompt at initialize), and
//  2. the primary search tool's description ("CURRENT MEMORY OVERVIEW: …" —
//     the universal fallback, since every tool-calling client loads tool
//     descriptions even when it ignores server instructions).
//
// The problem it kills: a client that sees tool NAMES only has no signal that
// the memory might already hold an answer, so it answers from its own head and
// never calls doc_search. The seed is the signal. Ported (pattern, not code)
// from understory's packages/server/src/mcp/seed.ts — the key steal is
// DESCRIPTIONS over filenames: "The pg-ai-stewards substrate…" ignites the
// "memory might know this" instinct in a way a bare slug never does.
//
// Config: on by default; STEWARDS_SEED_MEMORY=false disables it (both channels
// no-op, restoring the pre-seed behavior — a clean A/B toggle). Cap: the
// overview body is bounded at maxSeedChars with a "use doc_search to explore"
// tail so the injection can never blow up a system prompt.
//
// Freshness: the stdio server is long-lived, so its seed reflects startup state
// (and the instructions channel freezes per session by protocol either way).
// The HTTP surface rebuilds its server per MCP session (see http.go), so it
// re-derives the seed on every connection — freshness with zero invalidation
// logic, the elegant property understory gets from stateless HTTP.

package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	// maxSeedChars bounds the rendered overview body (matching understory's
	// 3000). The instructions/description framing is added on top of this.
	maxSeedChars = 3000
	// maxDocTitlesPerPool caps the semantic hooks shown per knowledge pool
	// before collapsing the rest into "…and N more".
	maxDocTitlesPerPool = 10
	// maxIntentsShown caps the "Active intents" list.
	maxIntentsShown = 8
	// maxRecentActivity caps the "Recent activity" tail (understory: last-3).
	maxRecentActivity = 3
	// seedTruncTail is appended when the body is cut to the cap.
	seedTruncTail = "\n… (truncated — use doc_search to explore further)"
)

// seedData is the raw material for the overview, pulled from the substrate in
// fetchSeedData and rendered by renderSeed. Separating the two keeps the
// formatting logic pure and unit-testable without a database.
type seedData struct {
	KindCounts []kindCount     // doc counts by type (studies, proposals, …)
	Pools      []poolSummary   // knowledge pools (projects) with their docs
	Intents    []intentSummary // the "why" behind work — governance intents
	Recent     []recentEntry   // last-N recently touched docs
}

type kindCount struct {
	Kind string
	N    int
}

// poolSummary is one knowledge pool (a stewards.projects row, or a bare
// project_association tag with no formal project row). Description/Name may be
// empty when the pool is only a tag; renderer falls back through them.
type poolSummary struct {
	Key         string   // project_association value (or "(unfiled)")
	Name        string   // stewards.projects.name, if any
	Description string   // stewards.projects.description, if any
	Count       int      // total docs in the pool
	Titles      []string // up to maxDocTitlesPerPool most-recent doc titles
}

type intentSummary struct {
	Slug    string
	Purpose string
}

type recentEntry struct {
	Date  string // YYYY-MM-DD
	Kind  string
	Title string
}

// seedMemoryEnabled reports whether seed injection is on. Default on;
// STEWARDS_SEED_MEMORY=false|0|no|off turns it off.
func seedMemoryEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("STEWARDS_SEED_MEMORY"))) {
	case "false", "0", "no", "off":
		return false
	default:
		return true
	}
}

// buildSeed is the orchestration entry point: disabled → "" (no injection);
// fetch error → "" (degrade to pre-seed behavior, never block the initialize
// handshake or a new HTTP session on a transient DB hiccup). Otherwise returns
// the rendered, capped overview.
func buildSeed(ctx context.Context, pool *pgxpool.Pool) string {
	if !seedMemoryEnabled() {
		return ""
	}
	d, err := fetchSeedData(ctx, pool)
	if err != nil {
		// stderr is safe (stdout is the protocol stream); logging here, not
		// failing, is the whole point — a missing overview degrades to the
		// prior tool-names-only behavior rather than crashing startup.
		fmt.Fprintf(os.Stderr, "stewards-mcp: seed-memory: fetch failed, no overview this session: %v\n", err)
		return ""
	}
	return renderSeed(d)
}

// fetchSeedData reads the overview material from the substrate. All queries are
// read-only aggregates over already-indexed columns. Column names are verified
// against extension/src/schema.rs (docs) and extension/v01/v02 (projects,
// intents) — no invented columns.
func fetchSeedData(ctx context.Context, pool *pgxpool.Pool) (seedData, error) {
	var d seedData

	// 1. Doc counts by kind.
	rows, err := pool.Query(ctx, `
		SELECT kind, count(*)::int
		  FROM stewards.docs
		 GROUP BY kind
		 ORDER BY count(*) DESC, kind`)
	if err != nil {
		return d, fmt.Errorf("kind counts: %w", err)
	}
	for rows.Next() {
		var kc kindCount
		if err := rows.Scan(&kc.Kind, &kc.N); err != nil {
			rows.Close()
			return d, fmt.Errorf("kind counts scan: %w", err)
		}
		d.KindCounts = append(d.KindCounts, kc)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return d, fmt.Errorf("kind counts rows: %w", err)
	}

	// 2. Knowledge pools (projects) with doc counts + description. A doc's
	// project_association may or may not have a matching stewards.projects row
	// (it can be a bare tag), so LEFT JOIN and fall back to the tag as the
	// pool key. NULL/empty association collapses into "(unfiled)".
	rows, err = pool.Query(ctx, `
		SELECT COALESCE(NULLIF(d.project_association, ''), '(unfiled)') AS seg,
		       COALESCE(p.name, '')        AS name,
		       COALESCE(p.description, '') AS descr,
		       count(*)::int               AS n
		  FROM stewards.docs d
		  LEFT JOIN stewards.projects p
		         ON p.slug = d.project_association
		 GROUP BY seg, name, descr
		 ORDER BY n DESC, seg`)
	if err != nil {
		return d, fmt.Errorf("pools: %w", err)
	}
	for rows.Next() {
		var ps poolSummary
		if err := rows.Scan(&ps.Key, &ps.Name, &ps.Description, &ps.Count); err != nil {
			rows.Close()
			return d, fmt.Errorf("pools scan: %w", err)
		}
		d.Pools = append(d.Pools, ps)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return d, fmt.Errorf("pools rows: %w", err)
	}

	// 3. Up to maxDocTitlesPerPool most-recent doc titles per pool, in one
	// windowed pass. Titles are the substrate's semantic hooks (docs have no
	// separate description column; the title is the "what someone would look
	// up" string — exactly understory's description ?? title fallback).
	//
	// Collect into a keyed map, then attach after d.Pools is fully built —
	// storing pointers into d.Pools while it is still being appended to would
	// alias a stale backing array once append reallocates (only the last pools
	// would keep valid pointers). The map sidesteps that entirely.
	rows, err = pool.Query(ctx, `
		SELECT seg, title FROM (
		    SELECT COALESCE(NULLIF(project_association, ''), '(unfiled)') AS seg,
		           title,
		           row_number() OVER (
		               PARTITION BY COALESCE(NULLIF(project_association, ''), '(unfiled)')
		               ORDER BY updated_at DESC, title
		           ) AS rn
		      FROM stewards.docs
		) t
		 WHERE rn <= $1
		 ORDER BY seg, rn`, maxDocTitlesPerPool)
	if err != nil {
		return d, fmt.Errorf("pool titles: %w", err)
	}
	titlesBySeg := map[string][]string{}
	for rows.Next() {
		var seg, title string
		if err := rows.Scan(&seg, &title); err != nil {
			rows.Close()
			return d, fmt.Errorf("pool titles scan: %w", err)
		}
		titlesBySeg[seg] = append(titlesBySeg[seg], title)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return d, fmt.Errorf("pool titles rows: %w", err)
	}
	attachTitles(d.Pools, titlesBySeg)

	// 4. Active intents — the "why" behind work, one-line purpose each.
	rows, err = pool.Query(ctx, `
		SELECT slug, purpose
		  FROM stewards.intents
		 ORDER BY updated_at DESC, slug
		 LIMIT $1`, maxIntentsShown)
	if err != nil {
		return d, fmt.Errorf("intents: %w", err)
	}
	for rows.Next() {
		var is intentSummary
		if err := rows.Scan(&is.Slug, &is.Purpose); err != nil {
			rows.Close()
			return d, fmt.Errorf("intents scan: %w", err)
		}
		d.Intents = append(d.Intents, is)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return d, fmt.Errorf("intents rows: %w", err)
	}

	// 5. Recent activity — last-N touched docs.
	rows, err = pool.Query(ctx, `
		SELECT to_char(updated_at, 'YYYY-MM-DD'), kind, title
		  FROM stewards.docs
		 ORDER BY updated_at DESC
		 LIMIT $1`, maxRecentActivity)
	if err != nil {
		return d, fmt.Errorf("recent: %w", err)
	}
	for rows.Next() {
		var re recentEntry
		if err := rows.Scan(&re.Date, &re.Kind, &re.Title); err != nil {
			rows.Close()
			return d, fmt.Errorf("recent scan: %w", err)
		}
		d.Recent = append(d.Recent, re)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return d, fmt.Errorf("recent rows: %w", err)
	}

	return d, nil
}

// attachTitles binds each pool's semantic-hook titles by key, in place. It is
// its own function (not an inline loop over pointers into the pools slice)
// because the pointer form aliases a stale backing array once append grows the
// slice — the bug the live-substrate smoke caught, where only the last-built
// pools kept their titles. Keyed lookup after the slice is final is aliasing-proof.
func attachTitles(pools []poolSummary, titlesBySeg map[string][]string) {
	for i := range pools {
		pools[i].Titles = titlesBySeg[pools[i].Key]
	}
}

// poolLabel resolves the description-over-name rule: prefer the project's
// description (the semantic hook), then its name, then the bare key. This is
// the substrate analog of understory's "description ?? title ?? name".
func poolLabel(p poolSummary) string {
	if s := strings.TrimSpace(p.Description); s != "" {
		return s
	}
	if s := strings.TrimSpace(p.Name); s != "" {
		return s
	}
	return p.Key
}

// renderSeed formats seedData into the capped overview body. Pure — no I/O — so
// it is unit-testable without a database.
func renderSeed(d seedData) string {
	var sections []string

	// Corpus line: doc counts by type.
	if len(d.KindCounts) > 0 {
		parts := make([]string, 0, len(d.KindCounts))
		for _, kc := range d.KindCounts {
			parts = append(parts, fmt.Sprintf("%d %s", kc.N, plural(kc.Kind, kc.N)))
		}
		sections = append(sections, "Corpus: "+strings.Join(parts, ", "))
	}

	// Knowledge pools, each with up to N doc-title semantic hooks.
	if len(d.Pools) > 0 {
		var b strings.Builder
		b.WriteString("Knowledge pools:")
		for _, p := range d.Pools {
			label := poolLabel(p)
			b.WriteString("\n* ")
			if label != p.Key {
				fmt.Fprintf(&b, "%s — %s (%d %s):", p.Key, label, p.Count, plural("doc", p.Count))
			} else {
				fmt.Fprintf(&b, "%s (%d %s):", p.Key, p.Count, plural("doc", p.Count))
			}
			for _, t := range p.Titles {
				b.WriteString("\n    * ")
				b.WriteString(t)
			}
			if more := p.Count - len(p.Titles); more > 0 {
				fmt.Fprintf(&b, "\n    * …and %d more", more)
			}
		}
		sections = append(sections, b.String())
	}

	// Active intents — the why.
	if len(d.Intents) > 0 {
		var b strings.Builder
		b.WriteString("Active intents:")
		for _, in := range d.Intents {
			fmt.Fprintf(&b, "\n* %s — %s", in.Slug, firstLine(in.Purpose))
		}
		sections = append(sections, b.String())
	}

	// Recent activity — last-N touched docs.
	if len(d.Recent) > 0 {
		var b strings.Builder
		b.WriteString("Recent activity:")
		for _, r := range d.Recent {
			fmt.Fprintf(&b, "\n- %s %s: %s", r.Date, r.Kind, r.Title)
		}
		sections = append(sections, b.String())
	}

	body := strings.Join(sections, "\n\n")
	if body == "" {
		body = "(memory is empty — nothing stored yet)"
	}
	return capSeed(body)
}

// capSeed bounds the body to maxSeedChars, counting runes (not bytes) so a
// multibyte character is never split. When it overflows, it reserves room for
// the tail so the FINAL string — body plus tail — still fits the cap (a small,
// deliberate improvement over understory, which appends the tail after slicing
// and can exceed the cap).
func capSeed(body string) string {
	if utf8.RuneCountInString(body) <= maxSeedChars {
		return body
	}
	keep := maxSeedChars - utf8.RuneCountInString(seedTruncTail)
	if keep < 0 {
		keep = 0
	}
	runes := []rune(body)
	return string(runes[:keep]) + seedTruncTail
}

// seedInstructions wraps the overview into the initialize `instructions` block
// — the standards channel. The prose teaches the instinct the seed exists to
// ignite: search before answering, persist what's learned.
func seedInstructions(seed string) string {
	if seed == "" {
		return ""
	}
	return `This server is a persistent memory + knowledge corpus for the pg-ai-stewards substrate — studies, proposals, journals, and project knowledge that survive across sessions, searchable via doc_search / doc_get.

MEMORY OVERVIEW (as of session start):

` + seed + `

How to use this memory:
- BEFORE answering anything related to the topics, pools, or intents above, call doc_search — the answer may already be recorded here. Prefer the stored corpus over answering from your own head.
- Use doc_get to read a matched document in full, and doc_similar / doc_citations to follow its neighborhood.
- This overview is a map, not the territory: it lists what exists, not its contents. When a pool or title looks relevant, search into it.`
}

// docSearchBaseDescription is the doc_search tool's description without the
// overview — shared by tools.go (registration) and the overview-append below so
// the two never drift.
const docSearchBaseDescription = "Full-text search the substrate's studies corpus. " +
	"Returns matching slugs, titles, kinds, snippets, and ranks. " +
	"Filter by kinds (e.g. ['study','journal','proposal']) to narrow " +
	"to a specific document type. Use doc_get afterward to read a " +
	"matched document by slug."

// docSearchDescription is the second channel: the primary search tool's
// description carries the overview so even a client that ignores server
// instructions still sees what the corpus holds. Empty seed → base only.
func docSearchDescription(seed string) string {
	if seed == "" {
		return docSearchBaseDescription
	}
	return docSearchBaseDescription + "\n\nCURRENT MEMORY OVERVIEW:\n" + seed
}

// plural is a tiny helper: naive English pluralization for the count lines
// (doc→docs, study→studies, proposal→proposals). Good enough for the known
// doc kinds; unknown kinds get a trailing 's'.
func plural(word string, n int) string {
	if n == 1 {
		return word
	}
	switch {
	case strings.HasSuffix(word, "y") && !strings.HasSuffix(word, "ay") &&
		!strings.HasSuffix(word, "ey") && !strings.HasSuffix(word, "oy"):
		return word[:len(word)-1] + "ies"
	case strings.HasSuffix(word, "s"), strings.HasSuffix(word, "x"),
		strings.HasSuffix(word, "ch"), strings.HasSuffix(word, "sh"):
		return word + "es"
	default:
		return word + "s"
	}
}

// firstLine trims a purpose to its first non-empty line so a multi-line intent
// purpose stays a one-liner in the overview.
func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = strings.TrimSpace(s[:i])
	}
	return s
}
