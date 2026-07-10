// substrate_tool — dynamic dispatch to tool_defs rows (companion wave).
//
// THE GAP THIS CLOSES (#346, made load-bearing by the voice companion):
// tools born as tool_defs rows — the case tools, companion reminders, and
// every tool the FORGE creates — execute in the bgworker but were invisible
// to harness seats, whose MCP surface is the fixed set of Go tools in this
// binary. A freshly forged tool could not be used by the voice that asked
// for it. substrate_tool makes the dynamic registry itself the surface:
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
//   - only {"kind":"sql_fn"} and {"kind":"mcp_proxy"} targets qualify.
//     sql_fn schema/function names are validated as plain identifiers before
//     interpolation; mcp_proxy calls reuse the bridge daemon's session path.
//   - _session_id is injected for sql_fn tools. mcp_proxy session_id is only
//     injected when execute_target opts in, matching pipeline dispatch.

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

// SubstrateToolInput calls one registered dynamic tool by name.
type SubstrateToolInput struct {
	Name string         `json:"name" jsonschema:"the registered tool name (see substrate_tools for the catalog)"`
	Args map[string]any `json:"args,omitempty" jsonschema:"the tool's arguments as an object (see its args_schema from substrate_tools)"`
}

// SubstrateToolsInput lists the callable catalog. No arguments.
type SubstrateToolsInput struct{}

type substrateToolEntry struct {
	Name         string          `json:"name"`
	Description  string          `json:"description"`
	Kind         string          `json:"kind"`
	EffectClass  string          `json:"effect_class"`
	ArgsSchema   json.RawMessage `json:"args_schema"`
	Dispatchable bool            `json:"dispatchable_here"`
}

type substrateToolTarget struct {
	Kind          string
	Schema        string
	Fn            string
	Server        string
	Tool          string
	InjectSession bool
	EffectClass   string
}

type substrateToolStore interface {
	list(context.Context) ([]substrateToolEntry, error)
	lookup(context.Context, string) (substrateToolTarget, error)
	writeAllowed(context.Context, string) (bool, error)
	callSQL(context.Context, substrateToolTarget, []byte) ([]byte, error)
}

type postgresSubstrateToolStore struct {
	pool *pgxpool.Pool
}

func (s postgresSubstrateToolStore) list(ctx context.Context) ([]substrateToolEntry, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT t.name, t.description, t.execute_target->>'kind', t.effect_class, t.args_schema,
		       t.effect_class = 'read' OR EXISTS (
		           SELECT 1 FROM stewards.config c, jsonb_array_elements_text(c.value) a(name)
		            WHERE c.key = 'arc_c_dynamic_write_allowlist'
		              AND jsonb_typeof(c.value) = 'array' AND a.name = t.name)
		  FROM stewards.tool_defs t
		 WHERE t.active AND t.execute_target->>'kind' IN ('sql_fn', 'mcp_proxy')
		 ORDER BY t.name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []substrateToolEntry
	for rows.Next() {
		var entry substrateToolEntry
		if err := rows.Scan(&entry.Name, &entry.Description, &entry.Kind, &entry.EffectClass,
			&entry.ArgsSchema, &entry.Dispatchable); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out = append(out, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func (s postgresSubstrateToolStore) lookup(ctx context.Context, name string) (substrateToolTarget, error) {
	var target substrateToolTarget
	err := s.pool.QueryRow(ctx, `
		SELECT execute_target->>'kind',
		       coalesce(execute_target->>'schema',''), coalesce(execute_target->>'name',''),
		       coalesce(execute_target->>'server',''), coalesce(execute_target->>'tool',''),
		       execute_target @> '{"inject_session":true}'::jsonb, effect_class
		  FROM stewards.tool_defs
		 WHERE name = $1 AND active
		   AND execute_target->>'kind' IN ('sql_fn', 'mcp_proxy')`, name).Scan(
		&target.Kind, &target.Schema, &target.Fn, &target.Server, &target.Tool,
		&target.InjectSession, &target.EffectClass)
	return target, err
}

// writeAllowed preserves the Arc C read-mostly wall for every dynamic kind.
func (s postgresSubstrateToolStore) writeAllowed(ctx context.Context, name string) (bool, error) {
	var ok bool
	err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (
		    SELECT 1 FROM stewards.config c, jsonb_array_elements_text(c.value) a(name)
		     WHERE c.key = 'arc_c_dynamic_write_allowlist'
		       AND jsonb_typeof(c.value) = 'array'
		       AND a.name = $1)`, name).Scan(&ok)
	return ok, err
}

func (s postgresSubstrateToolStore) callSQL(ctx context.Context, target substrateToolTarget, payload []byte) ([]byte, error) {
	// Schema/function are validated as plain identifiers by the handler before
	// reaching this interpolation boundary.
	var out []byte
	q := fmt.Sprintf("SELECT %s.%s($1::jsonb)", target.Schema, target.Fn)
	err := s.pool.QueryRow(ctx, q, payload).Scan(&out)
	return out, err
}

func registerSubstrateToolDispatch(srv *mcp.Server, pool *pgxpool.Pool, sessionID string,
	callProxy mcpProxyCallFunc) {
	store := postgresSubstrateToolStore{pool: pool}
	mcp.AddTool(srv, &mcp.Tool{
		Name: "substrate_tools",
		Description: "List the substrate's DYNAMIC tool catalog — sql_fn and mcp_proxy tools registered in tool_defs " +
			"(including tools created by the forge after this server started). Returns name, description, " +
			"kind, effect_class, args_schema, and whether THIS surface may dispatch it (read tools: always; " +
			"write tools: only if allowlisted). Use substrate_tool to call one.",
	}, makeSubstrateToolsList(store))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "substrate_tool",
		Description: "Call one registered substrate sql_fn or mcp_proxy tool by name with an args object — the dynamic " +
			"companion to the fixed tools on this surface. Freshly forged tools are callable here the moment " +
			"they are registered. Read-class tools dispatch freely; write-class tools only if allowlisted " +
			"(a refusal names the reason honestly). Session data is injected server-side when required.",
	}, makeSubstrateToolCall(store, sessionID, callProxy))
}

func makeSubstrateToolsList(store substrateToolStore) func(
	ctx context.Context, req *mcp.CallToolRequest, in SubstrateToolsInput,
) (*mcp.CallToolResult, any, error) {
	return func(ctx context.Context, req *mcp.CallToolRequest, in SubstrateToolsInput,
	) (*mcp.CallToolResult, any, error) {
		tools, err := store.list(ctx)
		if err != nil {
			return toolError("substrate_tools: %v", err), nil, nil
		}
		bs, _ := json.Marshal(map[string]any{"count": len(tools), "tools": tools})
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(bs)}}}, nil, nil
	}
}

func makeSubstrateToolCall(store substrateToolStore, sessionID string, callProxy mcpProxyCallFunc) func(
	ctx context.Context, req *mcp.CallToolRequest, in SubstrateToolInput,
) (*mcp.CallToolResult, any, error) {
	return func(ctx context.Context, req *mcp.CallToolRequest, in SubstrateToolInput,
	) (*mcp.CallToolResult, any, error) {
		name := strings.TrimSpace(strings.ToLower(in.Name))
		if name == "" {
			return toolError("substrate_tool: 'name' is required (substrate_tools lists the catalog)"), nil, nil
		}

		target, err := store.lookup(ctx, name)
		if err != nil {
			return toolError("substrate_tool: no active dynamic tool named %q (substrate_tools lists what exists)", name), nil, nil
		}
		if target.Kind == "sql_fn" && (!sqlIdentRe.MatchString(target.Schema) || !sqlIdentRe.MatchString(target.Fn)) {
			return toolError("substrate_tool: %q has a malformed execute_target (schema/function must be plain identifiers)", name), nil, nil
		}
		if target.Kind == "mcp_proxy" && (strings.TrimSpace(target.Server) == "" || strings.TrimSpace(target.Tool) == "") {
			return toolError("substrate_tool: %q has a malformed mcp_proxy execute_target (server/tool are required)", name), nil, nil
		}
		if target.EffectClass != "read" {
			ok, aerr := store.writeAllowed(ctx, name)
			if aerr != nil {
				return toolError("substrate_tool: allowlist check failed: %v", aerr), nil, nil
			}
			if !ok {
				return toolError("substrate_tool: %q is %s-class and not on arc_c_dynamic_write_allowlist — "+
					"this surface is read-mostly; gated writes happen through their own pipelines and the approval bell",
					name, target.EffectClass), nil, nil
			}
		}

		args := make(map[string]any, len(in.Args)+1)
		for key, value := range in.Args {
			args[key] = value
		}

		switch target.Kind {
		case "sql_fn":
			args["_session_id"] = sessionID
			payload, _ := json.Marshal(args)
			out, err := store.callSQL(ctx, target, payload)
			if err != nil {
				return toolError("substrate_tool: %s failed: %v", name, err), nil, nil
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(out)}}}, nil, nil
		case "mcp_proxy":
			if target.InjectSession && sessionID != "" {
				// Match exec_one_tool: the target flag opts into authoritative
				// session_id override; arbitrary proxy tools receive no extra arg.
				args["session_id"] = sessionID
			}
			if callProxy == nil {
				return toolError("substrate_tool: %s failed: mcp proxy caller is unavailable", name), nil, nil
			}
			result, err := callProxy(ctx, target.Server, target.Tool, args)
			if err != nil {
				return toolError("substrate_tool: %s failed: %v", name, err), nil, nil
			}
			return result, nil, nil
		default:
			return toolError("substrate_tool: %q has unsupported kind %q", name, target.Kind), nil, nil
		}
	}
}
