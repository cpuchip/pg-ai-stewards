// Tool handlers for the stewards-mcp sidecar.
//
// Each handler is a thin wrapper: validate inputs → run a single SQL
// query against the substrate → marshal the result. The substrate's
// own SQL functions enforce semantics (FTS, line pagination, etc.); we
// just expose them through the MCP interface.

package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// toolError builds the model-visible error result.
//
// Per the MCP spec (and per the SDK's protocol.go comment block on
// CallToolResult.IsError), tool-execution failures are returned as a
// `CallToolResult` with `IsError: true` plus a text content block
// describing what went wrong. JSON-RPC errors are reserved for protocol
// violations (unknown method, malformed params) which the SDK handles
// for us. Mixing them up means the model sees DB outages as
// unrecoverable system errors and stops trying.
func toolError(format string, args ...any) *mcp.CallToolResult {
	return &mcp.CallToolResult{
		IsError: true,
		Content: []mcp.Content{
			&mcp.TextContent{Text: fmt.Sprintf(format, args...)},
		},
	}
}

// registerDocTools wires up the v1+v1.1 (Phase 3e.1, 3e.1.1) tool surface:
// doc_search, doc_get, doc_similar, doc_citations.
func registerDocTools(srv *mcp.Server, pool *pgxpool.Pool) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_search",
		Description: "Full-text search the substrate's studies corpus. " +
			"Returns matching slugs, titles, kinds, snippets, and ranks. " +
			"Filter by kinds (e.g. ['study','journal','proposal']) to narrow " +
			"to a specific document type. Use doc_get afterward to read a " +
			"matched document by slug.",
	}, makeDocSearch(pool))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_get",
		Description: "Read a substrate study by slug, with optional line-range " +
			"pagination for large documents. Returns the body, frontmatter, " +
			"file path, and metadata as a single JSON object. Use doc_search " +
			"first to find slugs by topic.",
	}, makeDocGet(pool))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_similar",
		Description: "Find studies similar to a given slug, via the substrate's " +
			"precomputed embedding edges. Returns related slugs with similarity " +
			"scores and edge direction (in/out/both). Useful after doc_get to " +
			"surface adjacent material the author may have cross-referenced.",
	}, makeDocSimilar(pool))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_citations",
		Description: "List the canonical sources (scriptures, talks, etc.) that a " +
			"given study cites. Returns cited URIs grouped by kind, with anchor " +
			"text and citation count per URI. The URIs are resolvable via " +
			"gospel-engine-v2 (path semantics like 'eng/scriptures/bofm/mosiah/18.md#11').",
	}, makeDocCitations(pool))
}

// ---------------------------------------------------------------------
// doc_search
// ---------------------------------------------------------------------

// DocSearchInput mirrors stewards.doc_search(text, text[], int).
//
// jsonschema struct tags are description-only per jsonschema-go's For
// documentation. The library reserves WORD= prefixes for future syntax,
// so do not write 'description=foo,minimum=1' — that violates the
// future-compatibility rule. Use plain prose. Constraints (min, max,
// enum) require manual *Schema construction; the substrate's own SQL
// functions already enforce reasonable bounds, so we don't bother.
type DocSearchInput struct {
	Query string   `json:"query" jsonschema:"natural-language search text (websearch_to_tsquery semantics)"`
	Kinds []string `json:"kinds,omitempty" jsonschema:"optional filter on document kinds (study journal proposal phase-doc doc); empty matches all"`
	Limit int      `json:"limit,omitempty" jsonschema:"max results, default 10, capped at 100"`
}

// DocSearchHit is one row returned by stewards.doc_search.
type DocSearchHit struct {
	Slug    string  `json:"slug"`
	Kind    string  `json:"kind"`
	Title   string  `json:"title"`
	Snippet string  `json:"snippet"`
	Rank    float32 `json:"rank"`
}

// DocSearchOutput is the structured envelope. We wrap in a `results`
// field rather than returning the array directly because MCP outputSchema
// expects an object at the top level.
type DocSearchOutput struct {
	Results []DocSearchHit `json:"results"`
	Count   int              `json:"count"`
}

func makeDocSearch(pool *pgxpool.Pool) func(
	ctx context.Context, req *mcp.CallToolRequest, in DocSearchInput,
) (*mcp.CallToolResult, DocSearchOutput, error) {
	return func(
		ctx context.Context, req *mcp.CallToolRequest, in DocSearchInput,
	) (*mcp.CallToolResult, DocSearchOutput, error) {
		if in.Query == "" {
			return toolError("doc_search: 'query' is required and must be non-empty"),
				DocSearchOutput{}, nil
		}
		if in.Limit <= 0 {
			in.Limit = 10
		}
		// Pass nil/empty array for kinds when caller didn't filter; the
		// substrate fn already treats an empty array as "no filter".
		kinds := in.Kinds
		if kinds == nil {
			kinds = []string{}
		}

		rows, err := pool.Query(ctx,
			"SELECT slug, kind, title, snippet, rank "+
				"FROM stewards.doc_search($1, $2, $3)",
			in.Query, kinds, in.Limit)
		if err != nil {
			return toolError("doc_search query: %v", err),
				DocSearchOutput{}, nil
		}
		defer rows.Close()

		var results []DocSearchHit
		for rows.Next() {
			var h DocSearchHit
			if err := rows.Scan(&h.Slug, &h.Kind, &h.Title, &h.Snippet, &h.Rank); err != nil {
				return toolError("doc_search scan: %v", err),
					DocSearchOutput{}, nil
			}
			results = append(results, h)
		}
		if err := rows.Err(); err != nil {
			return toolError("doc_search rows: %v", err),
				DocSearchOutput{}, nil
		}

		out := DocSearchOutput{Results: results, Count: len(results)}
		// Returning (nil, out, nil) lets the SDK build the standard
		// {content: [{type: text, text: <JSON>}], structuredContent: out,
		// isError: false} envelope.
		return nil, out, nil
	}
}

// ---------------------------------------------------------------------
// doc_get
// ---------------------------------------------------------------------

// DocGetInput mirrors stewards.doc_get(text, bool, int, int, int).
// The line-pagination defaults (offset=0, count=200, max_chars=20000)
// match the substrate fn's own defaults; callers only need to provide
// slug for the common case.
type DocGetInput struct {
	Slug       string `json:"slug" jsonschema:"substrate study slug (kebab-case e.g. way-truth-life or substrate--ftc-wtl-meta-v3-kimi-tuned)"`
	LineOffset int    `json:"line_offset,omitempty" jsonschema:"0-indexed line to start at, default 0"`
	LineCount  int    `json:"line_count,omitempty" jsonschema:"max body lines, default 200, capped at 2000"`
	MaxChars   int    `json:"max_chars,omitempty" jsonschema:"hard cap on body characters returned, default 20000, capped at 200000"`
}

// DocGetOutput is the substrate fn's jsonb return value, decoded.
// We use map[string]any so the shape passes through whatever the
// substrate decided to include without us having to mirror every key.
type DocGetOutput map[string]any

func makeDocGet(pool *pgxpool.Pool) func(
	ctx context.Context, req *mcp.CallToolRequest, in DocGetInput,
) (*mcp.CallToolResult, DocGetOutput, error) {
	return func(
		ctx context.Context, req *mcp.CallToolRequest, in DocGetInput,
	) (*mcp.CallToolResult, DocGetOutput, error) {
		if in.Slug == "" {
			return toolError("doc_get: 'slug' is required"), nil, nil
		}
		if in.LineCount == 0 {
			in.LineCount = 200
		}
		if in.MaxChars == 0 {
			in.MaxChars = 20000
		}

		var raw []byte
		err := pool.QueryRow(ctx,
			"SELECT stewards.doc_get($1, $2, $3, $4, $5)",
			in.Slug, true /* include_body */, in.LineOffset, in.LineCount, in.MaxChars,
		).Scan(&raw)
		if err != nil {
			return toolError("doc_get query: %v (slug=%q)", err, in.Slug), nil, nil
		}

		var out DocGetOutput
		if err := json.Unmarshal(raw, &out); err != nil {
			return toolError("doc_get decode: %v", err), nil, nil
		}
		// The substrate fn returns NULL when the slug doesn't exist.
		// pgx scans NULL jsonb into raw=nil → Unmarshal succeeds with
		// out=nil. len() on a nil map returns 0, so this check covers
		// both the truly-empty and the not-found cases.
		if len(out) == 0 {
			return toolError("doc_get: no study with slug %q", in.Slug), nil, nil
		}

		return nil, out, nil
	}
}

// ---------------------------------------------------------------------
// doc_similar
// ---------------------------------------------------------------------

// DocSimilarInput mirrors stewards.doc_similar(text, int).
type DocSimilarInput struct {
	Slug  string `json:"slug" jsonschema:"substrate study slug to find neighbors of"`
	Limit int    `json:"limit,omitempty" jsonschema:"max neighbors returned, default 10, capped at 100"`
}

// DocSimilarHit is one row from stewards.doc_similar.
// `direction` is one of 'in' (cited by slug), 'out' (slug cites it),
// or 'both' (mutual). Score is cosine similarity in [0, 1].
type DocSimilarHit struct {
	Slug      string  `json:"slug"`
	Title     string  `json:"title"`
	FilePath  string  `json:"file_path"`
	Score     float64 `json:"score"`
	Direction string  `json:"direction"`
}

type DocSimilarOutput struct {
	Results []DocSimilarHit `json:"results"`
	Count   int               `json:"count"`
}

func makeDocSimilar(pool *pgxpool.Pool) func(
	ctx context.Context, req *mcp.CallToolRequest, in DocSimilarInput,
) (*mcp.CallToolResult, DocSimilarOutput, error) {
	return func(
		ctx context.Context, req *mcp.CallToolRequest, in DocSimilarInput,
	) (*mcp.CallToolResult, DocSimilarOutput, error) {
		if in.Slug == "" {
			return toolError("doc_similar: 'slug' is required"),
				DocSimilarOutput{}, nil
		}
		if in.Limit <= 0 {
			in.Limit = 10
		}

		rows, err := pool.Query(ctx,
			"SELECT slug, title, file_path, score, direction "+
				"FROM stewards.doc_similar($1, $2)",
			in.Slug, in.Limit)
		if err != nil {
			return toolError("doc_similar query: %v (slug=%q)", err, in.Slug),
				DocSimilarOutput{}, nil
		}
		defer rows.Close()

		var results []DocSimilarHit
		for rows.Next() {
			var h DocSimilarHit
			if err := rows.Scan(&h.Slug, &h.Title, &h.FilePath, &h.Score, &h.Direction); err != nil {
				return toolError("doc_similar scan: %v", err),
					DocSimilarOutput{}, nil
			}
			results = append(results, h)
		}
		if err := rows.Err(); err != nil {
			return toolError("doc_similar rows: %v", err),
				DocSimilarOutput{}, nil
		}

		return nil, DocSimilarOutput{Results: results, Count: len(results)}, nil
	}
}

// ---------------------------------------------------------------------
// doc_citations
// ---------------------------------------------------------------------

// DocCitationsInput mirrors stewards.doc_citations(text).
type DocCitationsInput struct {
	Slug string `json:"slug" jsonschema:"substrate study slug to list citations for"`
}

// DocCitation is one row from stewards.doc_citations.
// study_slug is repeated per row (the substrate fn could in principle
// be reused for graph walks across multiple studies, but for now it's
// always the input slug). cited_kind is e.g. 'scripture', 'talk',
// 'manual'. anchor_text is the displayed link text. citation_count is
// how many times this URI is cited within the source study.
type DocCitation struct {
	StudySlug     string `json:"study_slug"`
	CitedURI      string `json:"cited_uri"`
	CitedKind     string `json:"cited_kind"`
	AnchorText    string `json:"anchor_text"`
	CitationCount int    `json:"citation_count"`
}

type DocCitationsOutput struct {
	Citations []DocCitation `json:"citations"`
	Count     int             `json:"count"`
}

func makeDocCitations(pool *pgxpool.Pool) func(
	ctx context.Context, req *mcp.CallToolRequest, in DocCitationsInput,
) (*mcp.CallToolResult, DocCitationsOutput, error) {
	return func(
		ctx context.Context, req *mcp.CallToolRequest, in DocCitationsInput,
	) (*mcp.CallToolResult, DocCitationsOutput, error) {
		if in.Slug == "" {
			return toolError("doc_citations: 'slug' is required"),
				DocCitationsOutput{}, nil
		}

		rows, err := pool.Query(ctx,
			"SELECT study_slug, cited_uri, cited_kind, anchor_text, citation_count "+
				"FROM stewards.doc_citations($1)",
			in.Slug)
		if err != nil {
			return toolError("doc_citations query: %v (slug=%q)", err, in.Slug),
				DocCitationsOutput{}, nil
		}
		defer rows.Close()

		var results []DocCitation
		for rows.Next() {
			var c DocCitation
			if err := rows.Scan(&c.StudySlug, &c.CitedURI, &c.CitedKind, &c.AnchorText, &c.CitationCount); err != nil {
				return toolError("doc_citations scan: %v", err),
					DocCitationsOutput{}, nil
			}
			results = append(results, c)
		}
		if err := rows.Err(); err != nil {
			return toolError("doc_citations rows: %v", err),
				DocCitationsOutput{}, nil
		}

		return nil, DocCitationsOutput{Citations: results, Count: len(results)}, nil
	}
}
