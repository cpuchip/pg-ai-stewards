// substrate_tool — dynamic dispatch to sql_fn tool_defs rows (companion wave).
//
// THE GAP THIS CLOSES (#346, made load-bearing by the voice companion):
// tools born as tool_defs rows — the case tools, companion reminders, and
// every tool the FORGE creates — execute in the bgworker but were invisible
// to harness seats, whose MCP surface is the fixed set of Go tools in this
// binary. A freshly forged tool could not be used by the voice that asked
// for it. substrate_tool makes the sql_fn registry itself the surface:
// a tool registered at 10:00 is callable by the seat at 10:00.
//
// THE WALL (this surface is read-mostly on purpose):
//   - effect_class='read' rows dispatch freely.
//   - anything else dispatches ONLY if its name is in the config row
//     `arc_c_dynamic_write_allowlist` (jsonb array of names). The
//     companion pack seeds reminders + the verbal-approval tool there.
//     forge_register is deliberately NOT on the list — the forge's plans
//     are approved on the bell (or by an allowlisted approval tool whose
//     own protocol requires the human's explicit spoken yes); the
//     registrar stage runs forge_register from INSIDE the pipeline.
//   - only {"kind":"sql_fn"} targets qualify; schema/function names are
//     validated as plain identifiers before interpolation.
//   - _session_id is injected exactly like the doc-write tools, so
//     session-scoped sql_fn tools scope correctly.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var sqlIdentRe = regexp.MustCompile(`^[a-z_][a-z0-9_]{0,62}$`)

// SubstrateToolInput calls one registered sql_fn tool by name.
type SubstrateToolInput struct {
	Name string          `json:"name" jsonschema:"the registered tool name (see substrate_tools for the catalog)"`
	Args map[string]any `json:"args,omitempty" jsonschema:"the tool's arguments as an object (see its args_schema from substrate_tools)"`
}

// SubstrateToolsInput lists the callable catalog. No arguments.
type SubstrateToolsInput struct{}

type substrateToolRow struct {
	Schema      string
	Fn          string
	EffectClass string
}

// dynamicWriteAllowed reports whether a non-read sql_fn tool may be
// dispatched from this surface, per the arc_c_dynamic_write_allowlist
// config row (jsonb array of tool names).
func dynamicWriteAllowed(ctx context.Context, pool *pgxpool.Pool, name string) (bool, error) {
	var ok bool
	err := pool.QueryRow(ctx, `
		SELECT EXISTS (
		    SELECT 1 FROM stewards.config c, jsonb_array_elements_text(c.value) a(name)
		     WHERE c.key = 'arc_c_dynamic_write_allowlist'
		       AND jsonb_typeof(c.value) = 'array'
		       AND a.name = $1)`, name).Scan(&ok)
	return ok, err
}

func registerSubstrateToolDispatch(srv *mcp.Server, pool *pgxpool.Pool, sessionID string) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "substrate_tools",
		Description: "List the substrate's DYNAMIC tool catalog — sql_fn tools registered in tool_defs " +
			"(including tools created by the forge after this server started). Returns name, description, " +
			"effect_class, args_schema, and whether THIS surface may dispatch it (read tools: always; " +
			"write tools: only if allowlisted). Use substrate_tool to call one.",
	}, makeSubstrateToolsList(pool))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "substrate_tool",
		Description: "Call one registered substrate sql_fn tool by name with an args object — the dynamic " +
			"companion to the fixed tools on this surface. Freshly forged tools are callable here the moment " +
			"they are registered. Read-class tools dispatch freely; write-class tools only if allowlisted " +
			"(a refusal names the reason honestly). The session is injected server-side.",
	}, makeSubstrateToolCall(pool, sessionID))
}

func makeSubstrateToolsList(pool *pgxpool.Pool) func(
	ctx context.Context, req *mcp.CallToolRequest, in SubstrateToolsInput,
) (*mcp.CallToolResult, any, error) {
	return func(ctx context.Context, req *mcp.CallToolRequest, in SubstrateToolsInput,
	) (*mcp.CallToolResult, any, error) {
		rows, err := pool.Query(ctx, `
			SELECT t.name, t.description, t.effect_class, t.args_schema,
			       t.effect_class = 'read' OR EXISTS (
			           SELECT 1 FROM stewards.config c, jsonb_array_elements_text(c.value) a(name)
			            WHERE c.key = 'arc_c_dynamic_write_allowlist'
			              AND jsonb_typeof(c.value) = 'array' AND a.name = t.name)
			  FROM stewards.tool_defs t
			 WHERE t.active AND t.execute_target->>'kind' = 'sql_fn'
			 ORDER BY t.name`)
		if err != nil {
			return toolError("substrate_tools: %v", err), nil, nil
		}
		defer rows.Close()
		type entry struct {
			Name         string          `json:"name"`
			Description  string          `json:"description"`
			EffectClass  string          `json:"effect_class"`
			ArgsSchema   json.RawMessage `json:"args_schema"`
			Dispatchable bool            `json:"dispatchable_here"`
		}
		var out []entry
		for rows.Next() {
			var e entry
			if err := rows.Scan(&e.Name, &e.Description, &e.EffectClass, &e.ArgsSchema, &e.Dispatchable); err != nil {
				return toolError("substrate_tools: scan: %v", err), nil, nil
			}
			out = append(out, e)
		}
		bs, _ := json.Marshal(map[string]any{"count": len(out), "tools": out})
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(bs)}}}, nil, nil
	}
}

func makeSubstrateToolCall(pool *pgxpool.Pool, sessionID string) func(
	ctx context.Context, req *mcp.CallToolRequest, in SubstrateToolInput,
) (*mcp.CallToolResult, any, error) {
	return func(ctx context.Context, req *mcp.CallToolRequest, in SubstrateToolInput,
	) (*mcp.CallToolResult, any, error) {
		name := strings.TrimSpace(strings.ToLower(in.Name))
		if name == "" {
			return toolError("substrate_tool: 'name' is required (substrate_tools lists the catalog)"), nil, nil
		}

		var row substrateToolRow
		err := pool.QueryRow(ctx, `
			SELECT coalesce(execute_target->>'schema',''), coalesce(execute_target->>'name',''), effect_class
			  FROM stewards.tool_defs
			 WHERE name = $1 AND active AND execute_target->>'kind' = 'sql_fn'`, name).Scan(
			&row.Schema, &row.Fn, &row.EffectClass)
		if err != nil {
			return toolError("substrate_tool: no active sql_fn tool named %q (substrate_tools lists what exists)", name), nil, nil
		}
		if !sqlIdentRe.MatchString(row.Schema) || !sqlIdentRe.MatchString(row.Fn) {
			return toolError("substrate_tool: %q has a malformed execute_target (schema/function must be plain identifiers)", name), nil, nil
		}
		if row.EffectClass != "read" {
			ok, aerr := dynamicWriteAllowed(ctx, pool, name)
			if aerr != nil {
				return toolError("substrate_tool: allowlist check failed: %v", aerr), nil, nil
			}
			if !ok {
				return toolError("substrate_tool: %q is %s-class and not on arc_c_dynamic_write_allowlist — "+
					"this surface is read-mostly; gated writes happen through their own pipelines and the approval bell",
					name, row.EffectClass), nil, nil
			}
		}

		args := in.Args
		if args == nil {
			args = map[string]any{}
		}
		args["_session_id"] = sessionID
		payload, _ := json.Marshal(args)

		// schema/fn validated as plain identifiers above.
		var out []byte
		q := fmt.Sprintf("SELECT %s.%s($1::jsonb)", row.Schema, row.Fn)
		if err := pool.QueryRow(ctx, q, payload).Scan(&out); err != nil {
			return toolError("substrate_tool: %s failed: %v", name, err), nil, nil
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(out)}}}, nil, nil
	}
}
