// doc_write.go — the "doc create/update" half of the harness write-back set
// (90's addendum, ratified 1B 2026-07-03: "harness write-back with a NARROW
// write set").
//
// 34-doc-builder.sql already built + battle-tested the whole verb set
// (doc_create/doc_append_section/doc_patch/doc_read/doc_finalize/doc_current)
// as stewards.tool_defs rows (kind sql_fn) — but that surface is reachable
// ONLY through the substrate's OWN internal per-pipeline tool-calling loop
// (bridge_run.go executing execute_target against a model the SUBSTRATE
// dispatched itself). It was never wired to an actual MCP server, so no
// external MCP client — not this package's stdio surface, not Arc C's HTTP
// surface — could call it. That is the gap a harness (a FULL Claude Code
// instance dispatched via loom, reaching the substrate only through the Arc C
// HTTP hinge) needs closed to deliver a document as its work product.
//
// This file is the missing wiring: real MCP tools that call the SAME
// stewards.doc_*_tool(jsonb) SQL functions 34 already defined — no new SQL,
// no new semantics, just a second front door onto code that already works.
// (doc_finalize pools via stewards.import_doc, the same path every digester
// uses — see extension/34-doc-builder.sql and the schema.rs `import_doc`
// definition.)
//
// _session_id scoping: doc_drafts rows are scoped by
// stewards.doc_draft_session_match (exact match, or a shared wi--<uuid8>
// work-item prefix). A harness dispatch has no work-item session of its own,
// so registerDocWriteTools takes a caller-supplied sessionID and closes over
// it — every doc_create/append/patch/read/finalize call made through ONE
// registration (one Arc C HTTP MCP session = one harness dispatch's whole
// lifetime, since NewStreamableHTTPHandler calls getServer once per NEW
// session and reuses the server for the rest of that session) shares one
// draft namespace, exactly like one pipeline run's stages do today.
package main

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// DocWriteResult mirrors A2AResult: every doc_*_tool SQL function returns a
// jsonb OBJECT ({"ok":true,...} or {"error":...}), so a permissive
// map[string]any carries it through without us mirroring every key.
type DocWriteResult = map[string]any

// registerDocWriteTools exposes 34's doc-draft build/publish verbs as real
// MCP tools: doc_create, doc_append_section, doc_patch, doc_read,
// doc_finalize, doc_current. sessionID scopes which drafts this
// registration's caller can see/build (see the header). Deliberately NOT
// here: doc_search/doc_get/doc_similar/doc_citations (registerDocTools,
// read-only, already wired) and anything outside the "build + publish one
// doc" shape (no delete, no listing other sessions' drafts).
func registerDocWriteTools(srv *mcp.Server, pool *pgxpool.Pool, sessionID string) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_create",
		Description: "Start building a document to deliver as your work product. You do NOT write the whole document " +
			"in one reply — BUILD it incrementally: this returns a handle, then call doc_append_section repeatedly, " +
			"doc_patch to fix, and doc_finalize to pool it to the searchable studies corpus when done.",
	}, makeDocWriteCall(pool, sessionID, "stewards.doc_create_tool",
		func(in DocCreateInput) (map[string]any, string) {
			if strings.TrimSpace(in.Title) == "" {
				return nil, "doc_create: 'title' is required"
			}
			return structToArgs(in), ""
		}))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_append_section",
		Description: "Append one section to the document you are building. Keep each call small — a heading plus a " +
			"few focused paragraphs — and call it repeatedly to build the doc section by section.",
	}, makeDocWriteCall(pool, sessionID, "stewards.doc_append_section_tool",
		func(in DocAppendSectionInput) (map[string]any, string) {
			if strings.TrimSpace(in.Handle) == "" {
				return nil, "doc_append_section: 'handle' is required (from doc_create)"
			}
			if strings.TrimSpace(in.Body) == "" && strings.TrimSpace(in.Heading) == "" {
				return nil, "doc_append_section: 'body' or 'heading' is required"
			}
			return structToArgs(in), ""
		}))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_patch",
		Description: "Fix or revise text already in your draft: replace the first occurrence of an exact anchor " +
			"string with new text. Use doc_read first to see the current body.",
	}, makeDocWriteCall(pool, sessionID, "stewards.doc_patch_tool",
		func(in DocPatchInput) (map[string]any, string) {
			if strings.TrimSpace(in.Handle) == "" {
				return nil, "doc_patch: 'handle' is required"
			}
			if in.Find == "" {
				return nil, "doc_patch: 'find' (the exact text to replace) is required"
			}
			return structToArgs(in), ""
		}))

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "doc_read",
		Description: "Read back the current body of the document you are building, so you know what is already there before adding more.",
	}, makeDocWriteCall(pool, sessionID, "stewards.doc_read_tool",
		func(in DocHandleInput) (map[string]any, string) {
			if strings.TrimSpace(in.Handle) == "" {
				return nil, "doc_read: 'handle' is required"
			}
			return structToArgs(in), ""
		}))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_finalize",
		Description: "Finish the document: pool it to the searchable studies corpus and clear the draft. Call this " +
			"once the doc is complete; the returned slug is your delivery proof.",
	}, makeDocWriteCall(pool, sessionID, "stewards.doc_finalize_tool",
		func(in DocFinalizeInput) (map[string]any, string) {
			if strings.TrimSpace(in.Handle) == "" {
				return nil, "doc_finalize: 'handle' is required"
			}
			return structToArgs(in), ""
		}))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_current",
		Description: "Find the document draft this run is building (its handle), if a prior call already started " +
			"one. Returns {handle, title, total_chars} or handle=null if nothing is open yet.",
	}, makeDocWriteCall(pool, sessionID, "stewards.doc_current_tool",
		func(in DocCurrentInput) (map[string]any, string) {
			return structToArgs(in), ""
		}))
}

// ---------------------------------------------------------------------
// input shapes (mirror the args_schema authored in 34-doc-builder.sql)
// ---------------------------------------------------------------------

type DocCreateInput struct {
	Title   string `json:"title" jsonschema:"the document title"`
	Outline string `json:"outline,omitempty" jsonschema:"optional: a brief section outline to keep the doc coherent"`
	Project string `json:"project,omitempty" jsonschema:"optional pool/project tag, e.g. ai or books"`
}

type DocAppendSectionInput struct {
	Handle  string `json:"handle" jsonschema:"the draft handle from doc_create"`
	Heading string `json:"heading,omitempty" jsonschema:"section heading (optional; omit to append body only)"`
	Body    string `json:"body,omitempty" jsonschema:"the section text (markdown)"`
}

type DocPatchInput struct {
	Handle  string `json:"handle" jsonschema:"the draft handle"`
	Find    string `json:"find" jsonschema:"exact text currently in the draft to replace"`
	Replace string `json:"replace,omitempty" jsonschema:"the new text (empty string deletes the anchor)"`
}

type DocHandleInput struct {
	Handle string `json:"handle" jsonschema:"the draft handle"`
}

type DocFinalizeInput struct {
	Handle string `json:"handle" jsonschema:"the draft handle"`
	Slug   string `json:"slug,omitempty" jsonschema:"optional explicit slug (default derived from the title)"`
}

type DocCurrentInput struct{}

// structToArgs round-trips a typed input struct through its own json tags
// into a plain map, so callDocFn can add `_session_id` and hand the whole
// thing to a doc_*_tool(jsonb) SQL function unchanged.
func structToArgs(v any) map[string]any {
	b, err := json.Marshal(v)
	if err != nil {
		return map[string]any{}
	}
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	if m == nil {
		m = map[string]any{}
	}
	return m
}

// makeDocWriteCall builds an MCP handler for one doc_*_tool SQL function.
// validate runs first (empty-arg checks mirror what the SQL function itself
// would reject, but failing here saves a round-trip and gives a clearer
// message); on success it returns the args map to send.
func makeDocWriteCall[T any](pool *pgxpool.Pool, sessionID, fn string, validate func(T) (map[string]any, string)) func(
	ctx context.Context, req *mcp.CallToolRequest, in T,
) (*mcp.CallToolResult, DocWriteResult, error) {
	return func(ctx context.Context, req *mcp.CallToolRequest, in T) (*mcp.CallToolResult, DocWriteResult, error) {
		args, errMsg := validate(in)
		if errMsg != "" {
			return toolError("%s", errMsg), DocWriteResult{}, nil
		}
		return callDocFn(ctx, pool, sessionID, fn, args)
	}
}

// callDocFn invokes one of 34's doc_*_tool(jsonb) SQL functions, injecting
// _session_id so stewards.doc_draft_session_match scopes the draft to THIS
// caller.
func callDocFn(ctx context.Context, pool *pgxpool.Pool, sessionID, fn string, args map[string]any) (*mcp.CallToolResult, DocWriteResult, error) {
	if args == nil {
		args = map[string]any{}
	}
	args["_session_id"] = sessionID
	raw, err := json.Marshal(args)
	if err != nil {
		return toolError("%s: encode args: %v", fn, err), DocWriteResult{}, nil
	}
	var out []byte
	// fn is always one of the constant names above (never caller input), so
	// string-concatenating it into the query is safe.
	if qerr := pool.QueryRow(ctx, "SELECT "+fn+"($1::jsonb)", raw).Scan(&out); qerr != nil {
		return toolError("%s: %v", fn, qerr), DocWriteResult{}, nil
	}
	var obj DocWriteResult
	if jerr := json.Unmarshal(out, &obj); jerr != nil {
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(out)}}},
			DocWriteResult{"result": string(out)}, nil
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(out)}}}, obj, nil
}
