// citation_check — the text-vs-text citation sanity oracle (case-file wave).
//
// The one genuinely new verification primitive from the 2026-07-07
// pipelines-skeleton panel (DEMO-PATH G3): given a CLAIMED quote and a
// doc/section address, fetch the actual text (stewards.docs.body +
// stewards.doc_sections spans) and verify the claimed text really
// appears there. "Does the cited policy section actually say what the
// letter claims it says?" — a mismatch is finding #1.
//
// Honesty contract (stated boundaries, not aspirations):
//   - The check is EXACT after deterministic normalization: whitespace
//     runs collapse to one space, case is folded, and typographic
//     punctuation variants (curly quotes, en/em dashes, NBSP) map to
//     their ASCII forms. Nothing fuzzier than that.
//   - NO pg_trgm (a stated codebase boundary — see the "no pg_trgm"
//     rulings in v02/v22) and NO fabricated similarity scores. When the
//     quote does not appear, the tool reports the closest region by
//     LONGEST COMMON SUBSTRING — overlap_chars is a real count of
//     matching characters, not a synthesized 0.87.
//   - Offsets are CHARACTER (rune) offsets over docs.body, the same
//     unit doc_sections.char_start/char_end use (SQL length/substring
//     semantics), so found_at composes with the v29 section addresses.
//
// This is a synchronous read-only tool: pipeline stages reach it via
// the tool_defs mcp_proxy path ({"kind":"mcp_proxy","server":
// "pg-ai-stewards","tool":"citation_check"} — the tool_def row is
// seeded by examples/case-file-digester.sql, since examples own their
// seeds); interactive harnesses get it on the stdio surface like every
// other tool here. It writes nothing.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// citationQuoteCap / citationBodyCap bound the nearest-region scan.
// The containment check itself is cheap and never skipped; only the
// O(len(quote)*len(body)) locality scan is capped, and hitting a cap
// is REPORTED in note, never silent.
const (
	citationQuoteCap = 1000   // normalized runes of the claimed quote used for matching
	citationBodyCap  = 400000 // normalized runes of body the LCS locality scan will walk
	citationExcerpt  = 160    // runes of context on each side of the nearest region
)

// CitationCheckInput is the tool's argument surface. doc accepts a
// docs.id or a docs.slug (resolved server-side, the v29 convention).
// Exactly one scope: section_ref (an exact v29 address like "s1.3"),
// heading (case-insensitive substring match on doc_sections.heading),
// or neither (the whole document).
type CitationCheckInput struct {
	Quote      string `json:"quote" jsonschema:"the claimed quote to verify (verbatim text the citing document attributes to the cited one)"`
	Doc        string `json:"doc" jsonschema:"the CITED doc to check against - a docs.id or docs.slug (e.g. the policy document)"`
	SectionRef string `json:"section_ref,omitempty" jsonschema:"optional exact doc_sections address to scope the check to (e.g. s1.3); run doc_split_sections on the doc first"`
	Heading    string `json:"heading,omitempty" jsonschema:"optional heading text to scope the check to - case-insensitive substring match on the doc's section headings (e.g. 4.2(b)); alternative to section_ref"`
}

// CitationLocation is a resolved position: the v29 section address plus
// character offsets over docs.body ([char_start, char_end), 0-based,
// same unit as doc_sections.char_start/char_end).
type CitationLocation struct {
	SectionRef string `json:"section_ref,omitempty"`
	CharStart  int    `json:"char_start"`
	CharEnd    int    `json:"char_end"`
}

// CitationCheckOutput is the verdict envelope.
type CitationCheckOutput struct {
	Verified bool   `json:"verified"`
	DocSlug  string `json:"doc_slug"`
	Scope    string `json:"scope"` // what was actually checked (honesty about heading/section resolution)
	// FoundAt is non-nil only when Verified: where the quote appears.
	FoundAt *CitationLocation `json:"found_at"`
	// The honest nearest region when NOT verified: the section the
	// closest overlap lives in, a verbatim excerpt of the actual text
	// around it, and the real matched-character count of the longest
	// common substring (a count, not a similarity score).
	NearestSectionRef string `json:"nearest_section_ref,omitempty"`
	NearestExcerpt    string `json:"nearest_excerpt,omitempty"`
	OverlapChars      int    `json:"overlap_chars,omitempty"`
	Note              string `json:"note,omitempty"`
}

// citationSection mirrors one stewards.doc_sections row.
type citationSection struct {
	Ref       string
	Heading   string
	CharStart int
	CharEnd   int
}

// registerCitationCheckTool wires up the sanity oracle.
func registerCitationCheckTool(srv *mcp.Server, pool *pgxpool.Pool) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "citation_check",
		Description: "Verify that a CLAIMED quote actually appears in a cited doc/section — the text-vs-text " +
			"citation sanity check (does the cited policy section really say what the letter claims?). " +
			"Pass the claimed quote plus the cited doc (id or slug), optionally scoped by section_ref " +
			"(a doc_split_sections address like s1.3) or heading (substring match, e.g. \"4.2(b)\"). " +
			"The check is exact after whitespace/case/typographic-punctuation normalization — no fuzzy scoring. " +
			"Returns {verified, found_at} on success; on a mismatch it returns the honest nearest region " +
			"(nearest_section_ref, a verbatim excerpt of what the text ACTUALLY says, and overlap_chars — " +
			"the real character count of the longest common substring). A mismatch is a finding, not a failure: " +
			"record it. Read-only; deterministic; no model involved.",
	}, makeCitationCheck(pool))
}

func makeCitationCheck(pool *pgxpool.Pool) func(
	ctx context.Context, req *mcp.CallToolRequest, in CitationCheckInput,
) (*mcp.CallToolResult, CitationCheckOutput, error) {
	return func(
		ctx context.Context, req *mcp.CallToolRequest, in CitationCheckInput,
	) (*mcp.CallToolResult, CitationCheckOutput, error) {
		if strings.TrimSpace(in.Quote) == "" {
			return toolError("citation_check: 'quote' is required — the claimed text to verify"),
				CitationCheckOutput{}, nil
		}
		if strings.TrimSpace(in.Doc) == "" {
			return toolError("citation_check: 'doc' is required — the cited doc's id or slug"),
				CitationCheckOutput{}, nil
		}
		if in.SectionRef != "" && in.Heading != "" {
			return toolError("citation_check: pass section_ref OR heading, not both"),
				CitationCheckOutput{}, nil
		}

		// Resolve the cited doc (id or slug — the v29 convention).
		var docID, docSlug, body string
		err := pool.QueryRow(ctx,
			`SELECT d.id, d.slug, d.body FROM stewards.docs d
			  WHERE d.id = $1 OR d.slug = $1 LIMIT 1`,
			strings.TrimSpace(in.Doc),
		).Scan(&docID, &docSlug, &body)
		if err != nil {
			return toolError("citation_check: no doc with id or slug %q (%v)", in.Doc, err),
				CitationCheckOutput{}, nil
		}

		// Load the doc's v29 section map (may be empty — split is on-demand).
		sections, err := loadCitationSections(ctx, pool, docID)
		if err != nil {
			return toolError("citation_check: loading doc_sections: %v", err),
				CitationCheckOutput{}, nil
		}

		out := checkCitation(in, docSlug, body, sections)

		// Unstructured content: a sentinel first line + the full JSON,
		// so a text-only consumer still gets the whole verdict.
		verdict := "MISMATCH"
		if out.Verified {
			verdict = "VERIFIED"
		}
		js, _ := json.MarshalIndent(out, "", "  ")
		return &mcp.CallToolResult{
			Content: []mcp.Content{
				&mcp.TextContent{Text: verdict + "\n" + string(js)},
			},
		}, out, nil
	}
}

func loadCitationSections(ctx context.Context, pool *pgxpool.Pool, docID string) ([]citationSection, error) {
	rows, err := pool.Query(ctx,
		`SELECT section_ref, coalesce(heading, ''), char_start, char_end
		   FROM stewards.doc_sections
		  WHERE doc_id = $1
		  ORDER BY char_start`, docID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []citationSection
	for rows.Next() {
		var s citationSection
		if err := rows.Scan(&s.Ref, &s.Heading, &s.CharStart, &s.CharEnd); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// checkCitation is the pure core: no I/O, fully deterministic. Split
// out so the verdict logic is testable/inspectable independent of the
// MCP plumbing.
func checkCitation(in CitationCheckInput, docSlug, body string, sections []citationSection) CitationCheckOutput {
	out := CitationCheckOutput{DocSlug: docSlug}
	bodyRunes := []rune(body)

	var notes []string

	// Resolve the scope: which [start,end) spans of the body to check,
	// in priority order. Default = the whole document.
	type span struct {
		ref        string
		start, end int
	}
	var scopes []span

	clamp := func(v int) int {
		if v < 0 {
			return 0
		}
		if v > len(bodyRunes) {
			return len(bodyRunes)
		}
		return v
	}

	switch {
	case in.SectionRef != "":
		found := false
		for _, s := range sections {
			if s.Ref == in.SectionRef {
				scopes = append(scopes, span{s.Ref, clamp(s.CharStart), clamp(s.CharEnd)})
				out.Scope = fmt.Sprintf("section %s", s.Ref)
				found = true
				break
			}
		}
		if !found {
			if len(sections) == 0 {
				notes = append(notes, fmt.Sprintf(
					"doc has no sections recorded (run doc_split_sections first); section_ref %q could not be resolved — checked the whole document instead", in.SectionRef))
			} else {
				notes = append(notes, fmt.Sprintf(
					"no section %q in this doc — checked the whole document instead", in.SectionRef))
			}
			scopes = append(scopes, span{"", 0, len(bodyRunes)})
			out.Scope = "whole document (section_ref did not resolve)"
		}

	case in.Heading != "":
		want := strings.ToLower(strings.TrimSpace(in.Heading))
		var matched []citationSection
		for _, s := range sections {
			if s.Heading != "" && strings.Contains(strings.ToLower(s.Heading), want) {
				matched = append(matched, s)
			}
		}
		switch {
		case len(matched) == 1:
			s := matched[0]
			scopes = append(scopes, span{s.Ref, clamp(s.CharStart), clamp(s.CharEnd)})
			out.Scope = fmt.Sprintf("section %s (%q)", s.Ref, s.Heading)
		case len(matched) > 1:
			refs := make([]string, len(matched))
			for i, s := range matched {
				scopes = append(scopes, span{s.Ref, clamp(s.CharStart), clamp(s.CharEnd)})
				refs[i] = s.Ref
			}
			out.Scope = fmt.Sprintf("%d sections matching heading %q (%s)", len(matched), in.Heading, strings.Join(refs, ", "))
			notes = append(notes, "heading matched more than one section — each was checked; found_at names the one that verified")
		default:
			if len(sections) == 0 {
				notes = append(notes, fmt.Sprintf(
					"doc has no sections recorded (run doc_split_sections first); heading %q could not be resolved — checked the whole document instead", in.Heading))
			} else {
				notes = append(notes, fmt.Sprintf(
					"no section heading matches %q — checked the whole document instead", in.Heading))
			}
			scopes = append(scopes, span{"", 0, len(bodyRunes)})
			out.Scope = "whole document (heading did not resolve)"
		}

	default:
		scopes = append(scopes, span{"", 0, len(bodyRunes)})
		out.Scope = "whole document"
	}

	// Normalize the claimed quote once.
	normQuote, _ := normalizeCitationText(bodyRunesOf(in.Quote), 0)
	if len(normQuote) == 0 {
		out.Note = "the claimed quote is empty after normalization"
		return out
	}
	if len(normQuote) > citationQuoteCap {
		normQuote = normQuote[:citationQuoteCap]
		notes = append(notes, fmt.Sprintf("claimed quote is very long — matched on its first %d normalized characters", citationQuoteCap))
	}

	// Pass 1 — containment in each scope (exact after normalization).
	for _, sc := range scopes {
		normBody, offMap := normalizeCitationText(bodyRunes[sc.start:sc.end], sc.start)
		if idx := indexRunes(normBody, normQuote); idx >= 0 {
			startOff := offMap[idx]
			endOff := offMap[idx+len(normQuote)-1] + 1
			out.Verified = true
			out.FoundAt = &CitationLocation{
				SectionRef: sectionRefForOffset(sections, startOff, sc.ref),
				CharStart:  startOff,
				CharEnd:    endOff,
			}
			out.Note = joinCitationNotes(notes)
			return out
		}
	}

	// Pass 2 — not found. Locate the closest region honestly: the
	// longest common substring between the normalized quote and the
	// normalized body (a real overlap count, not a similarity score).
	// Scanned over the WHOLE document (not just the scope) so a quote
	// that lives in a different section than claimed is still located.
	normBody, offMap := normalizeCitationText(bodyRunes, 0)
	if len(normBody) > citationBodyCap {
		normBody = normBody[:citationBodyCap]
		offMap = offMap[:citationBodyCap]
		notes = append(notes, fmt.Sprintf("doc is very large — the nearest-region scan covered its first %d normalized characters", citationBodyCap))
	}

	overlapLen, bodyEnd := longestCommonSubstring(normQuote, normBody)
	if overlapLen > 0 {
		matchStart := offMap[bodyEnd-overlapLen]
		matchEnd := offMap[bodyEnd-1] + 1
		out.OverlapChars = overlapLen
		out.NearestSectionRef = sectionRefForOffset(sections, matchStart, "")
		out.NearestExcerpt = excerptAround(bodyRunes, matchStart, matchEnd)
		notes = append(notes, fmt.Sprintf(
			"the claimed text does NOT appear; the closest region shares %d consecutive characters — read nearest_excerpt for what the text actually says", overlapLen))
	} else {
		notes = append(notes, "the claimed text does not appear, and no part of it overlaps this doc at all")
	}
	out.Note = joinCitationNotes(notes)
	return out
}

// bodyRunesOf is a tiny alias to keep call sites readable.
func bodyRunesOf(s string) []rune { return []rune(s) }

func joinCitationNotes(notes []string) string { return strings.Join(notes, "; ") }

// normalizeCitationText produces the comparison form of a rune slice
// plus an offset map from each normalized rune back to the ORIGINAL
// character offset (baseOffset + index into the input slice — i.e.
// doc-absolute when the caller passes a body slice with its start).
//
// Normalization, in full (deterministic, documented, nothing else):
//   - case folded (unicode.ToLower)
//   - typographic quotes/apostrophes -> ASCII ' and "
//   - en dash / em dash / minus sign -> ASCII hyphen
//   - NBSP and all unicode whitespace runs -> ONE space (leading and
//     trailing whitespace dropped)
func normalizeCitationText(runes []rune, baseOffset int) ([]rune, []int) {
	norm := make([]rune, 0, len(runes))
	offs := make([]int, 0, len(runes))
	inSpace := false
	spaceStart := -1

	for i, r := range runes {
		switch r {
		case '‘', '’', '‚', '′': // curly single quotes, prime
			r = '\''
		case '“', '”', '„', '″': // curly double quotes
			r = '"'
		case '–', '—', '−': // en dash, em dash, minus
			r = '-'
		}
		if unicode.IsSpace(r) {
			if !inSpace {
				inSpace = true
				spaceStart = i
			}
			continue
		}
		if inSpace {
			if len(norm) > 0 { // no leading space
				norm = append(norm, ' ')
				offs = append(offs, baseOffset+spaceStart)
			}
			inSpace = false
		}
		norm = append(norm, unicode.ToLower(r))
		offs = append(offs, baseOffset+i)
	}
	return norm, offs
}

// indexRunes returns the index of the first occurrence of needle in
// hay, or -1. Plain scan — needles here are short quotes.
func indexRunes(hay, needle []rune) int {
	if len(needle) == 0 || len(needle) > len(hay) {
		return -1
	}
	for i := 0; i+len(needle) <= len(hay); i++ {
		if hay[i] != needle[0] {
			continue
		}
		j := 1
		for ; j < len(needle); j++ {
			if hay[i+j] != needle[j] {
				break
			}
		}
		if j == len(needle) {
			return i
		}
	}
	return -1
}

// longestCommonSubstring returns (length, end-index-in-b-exclusive) of
// the longest run of characters a and b share. Classic O(len(a)*len(b))
// DP with a rolling row — both inputs are already capped by the caller.
func longestCommonSubstring(a, b []rune) (int, int) {
	if len(a) == 0 || len(b) == 0 {
		return 0, 0
	}
	prev := make([]int, len(b)+1)
	cur := make([]int, len(b)+1)
	bestLen, bestEnd := 0, 0
	for i := 1; i <= len(a); i++ {
		for j := 1; j <= len(b); j++ {
			if a[i-1] == b[j-1] {
				cur[j] = prev[j-1] + 1
				if cur[j] > bestLen {
					bestLen = cur[j]
					bestEnd = j
				}
			} else {
				cur[j] = 0
			}
		}
		prev, cur = cur, prev
	}
	return bestLen, bestEnd
}

// sectionRefForOffset maps a doc-absolute character offset to the v29
// section address containing it. Sections from doc_split_sections are
// non-overlapping ([own heading start, next heading start)), so at most
// one row contains the offset. fallback is returned when no section
// does (unsplit doc, or offset in no recorded span).
func sectionRefForOffset(sections []citationSection, off int, fallback string) string {
	for _, s := range sections {
		if s.CharStart <= off && off < s.CharEnd {
			return s.Ref
		}
	}
	return fallback
}

// excerptAround returns the ORIGINAL (un-normalized) text around
// [start,end), expanded by citationExcerpt runes each side, with
// ellipses marking truncation. The excerpt is verbatim source text —
// that is the point: it shows what the doc actually says.
func excerptAround(body []rune, start, end int) string {
	lo := start - citationExcerpt
	hi := end + citationExcerpt
	if lo < 0 {
		lo = 0
	}
	if hi > len(body) {
		hi = len(body)
	}
	var sb strings.Builder
	if lo > 0 {
		sb.WriteString("…")
	}
	sb.WriteString(string(body[lo:hi]))
	if hi < len(body) {
		sb.WriteString("…")
	}
	return sb.String()
}
