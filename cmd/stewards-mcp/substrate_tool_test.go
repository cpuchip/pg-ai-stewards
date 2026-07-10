package main

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type fakeSubstrateToolStore struct {
	entries     []substrateToolEntry
	listErr     error
	target      substrateToolTarget
	lookupErr   error
	lookupName  string
	allowed     bool
	allowErr    error
	allowedName string
	sqlResult   []byte
	sqlErr      error
	sqlCalls    int
	sqlTarget   substrateToolTarget
	sqlPayload  []byte
}

func (f *fakeSubstrateToolStore) list(context.Context) ([]substrateToolEntry, error) {
	return f.entries, f.listErr
}

func (f *fakeSubstrateToolStore) lookup(_ context.Context, name string) (substrateToolTarget, error) {
	f.lookupName = name
	return f.target, f.lookupErr
}

func (f *fakeSubstrateToolStore) writeAllowed(_ context.Context, name string) (bool, error) {
	f.allowedName = name
	return f.allowed, f.allowErr
}

func (f *fakeSubstrateToolStore) callSQL(_ context.Context, target substrateToolTarget, payload []byte) ([]byte, error) {
	f.sqlCalls++
	f.sqlTarget = target
	f.sqlPayload = append([]byte(nil), payload...)
	return f.sqlResult, f.sqlErr
}

func callResultText(t *testing.T, result *mcp.CallToolResult) string {
	t.Helper()
	if result == nil || len(result.Content) != 1 {
		t.Fatalf("result content = %#v, want one text block", result)
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("result content type = %T, want *mcp.TextContent", result.Content[0])
	}
	return text.Text
}

func TestSubstrateToolsListsSQLAndMCPProxyKinds(t *testing.T) {
	store := &fakeSubstrateToolStore{entries: []substrateToolEntry{
		{
			Name: "case_timeline", Description: "Build a timeline", Kind: "sql_fn",
			EffectClass: "read", ArgsSchema: json.RawMessage(`{"type":"object"}`), Dispatchable: true,
		},
		{
			Name: "citation_check", Description: "Check a citation", Kind: "mcp_proxy",
			EffectClass: "read", ArgsSchema: json.RawMessage(`{"type":"object"}`), Dispatchable: true,
		},
	}}

	result, _, err := makeSubstrateToolsList(store)(context.Background(), nil, SubstrateToolsInput{})
	if err != nil {
		t.Fatalf("substrate_tools returned protocol error: %v", err)
	}
	if result.IsError {
		t.Fatalf("substrate_tools returned tool error: %s", callResultText(t, result))
	}

	var got struct {
		Count int                  `json:"count"`
		Tools []substrateToolEntry `json:"tools"`
	}
	if err := json.Unmarshal([]byte(callResultText(t, result)), &got); err != nil {
		t.Fatalf("decode substrate_tools output: %v", err)
	}
	if got.Count != 2 || len(got.Tools) != 2 {
		t.Fatalf("catalog count/tools = %d/%d, want 2/2", got.Count, len(got.Tools))
	}
	if got.Tools[0].Name != "case_timeline" || got.Tools[0].Kind != "sql_fn" {
		t.Errorf("first catalog tool = %#v, want case_timeline/sql_fn", got.Tools[0])
	}
	if got.Tools[1].Name != "citation_check" || got.Tools[1].Description != "Check a citation" || got.Tools[1].Kind != "mcp_proxy" {
		t.Errorf("second catalog tool = %#v, want citation_check description/mcp_proxy", got.Tools[1])
	}
}

func TestSubstrateToolRoutesMCPProxyThroughSharedBoundary(t *testing.T) {
	store := &fakeSubstrateToolStore{target: substrateToolTarget{
		Kind: "mcp_proxy", Server: "pg-ai-stewards", Tool: "citation_check", EffectClass: "read",
	}}
	wantResult := &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: `{"verdict":"MATCH"}`}},
	}
	var gotServer, gotTool string
	var gotArgs map[string]any
	proxy := func(_ context.Context, server, tool string, args map[string]any) (*mcp.CallToolResult, error) {
		gotServer, gotTool, gotArgs = server, tool, args
		return wantResult, nil
	}
	inputArgs := map[string]any{"quote": "policy text", "doc": "policy-1"}

	result, _, err := makeSubstrateToolCall(store, "wi--12345678--critic", proxy)(
		context.Background(), nil, SubstrateToolInput{Name: " Citation_Check ", Args: inputArgs})
	if err != nil {
		t.Fatalf("substrate_tool returned protocol error: %v", err)
	}
	if result != wantResult {
		t.Fatalf("result = %#v, want proxied result %#v", result, wantResult)
	}
	if store.lookupName != "citation_check" {
		t.Errorf("lookup name = %q, want normalized citation_check", store.lookupName)
	}
	if gotServer != "pg-ai-stewards" || gotTool != "citation_check" {
		t.Errorf("proxy target = %s/%s, want pg-ai-stewards/citation_check", gotServer, gotTool)
	}
	if !reflect.DeepEqual(gotArgs, inputArgs) {
		t.Errorf("proxy args = %#v, want %#v (no session injection without target opt-in)", gotArgs, inputArgs)
	}
	if store.sqlCalls != 0 {
		t.Errorf("SQL calls = %d, want 0 for mcp_proxy", store.sqlCalls)
	}
}

func TestSubstrateToolSQLFnRegression(t *testing.T) {
	store := &fakeSubstrateToolStore{
		target: substrateToolTarget{
			Kind: "sql_fn", Schema: "case_file", Fn: "case_timeline_tool", EffectClass: "read",
		},
		sqlResult: []byte(`{"events":2}`),
	}
	proxy := func(context.Context, string, string, map[string]any) (*mcp.CallToolResult, error) {
		return nil, errors.New("proxy must not be called for sql_fn")
	}
	inputArgs := map[string]any{"case_slug": "sample-case"}

	result, _, err := makeSubstrateToolCall(store, "wi--12345678--letter", proxy)(
		context.Background(), nil, SubstrateToolInput{Name: "case_timeline", Args: inputArgs})
	if err != nil {
		t.Fatalf("substrate_tool returned protocol error: %v", err)
	}
	if result.IsError {
		t.Fatalf("sql_fn returned tool error: %s", callResultText(t, result))
	}
	if got := callResultText(t, result); got != `{"events":2}` {
		t.Errorf("SQL result text = %q, want %q", got, `{"events":2}`)
	}
	if store.sqlCalls != 1 || store.sqlTarget.Schema != "case_file" || store.sqlTarget.Fn != "case_timeline_tool" {
		t.Errorf("SQL dispatch = calls:%d target:%#v, want one case_file.case_timeline_tool call", store.sqlCalls, store.sqlTarget)
	}
	var payload map[string]any
	if err := json.Unmarshal(store.sqlPayload, &payload); err != nil {
		t.Fatalf("decode SQL payload: %v", err)
	}
	if payload["case_slug"] != "sample-case" || payload["_session_id"] != "wi--12345678--letter" {
		t.Errorf("SQL payload = %#v, want caller args plus injected _session_id", payload)
	}
	if _, mutated := inputArgs["_session_id"]; mutated {
		t.Errorf("caller args were mutated: %#v", inputArgs)
	}
}

func TestSubstrateToolMCPProxyPreservesWriteAllowlist(t *testing.T) {
	store := &fakeSubstrateToolStore{target: substrateToolTarget{
		Kind: "mcp_proxy", Server: "external", Tool: "write_file", EffectClass: "write_local",
	}}
	proxyCalled := false
	proxy := func(context.Context, string, string, map[string]any) (*mcp.CallToolResult, error) {
		proxyCalled = true
		return nil, nil
	}

	result, _, err := makeSubstrateToolCall(store, "session", proxy)(
		context.Background(), nil, SubstrateToolInput{Name: "write_file"})
	if err != nil {
		t.Fatalf("substrate_tool returned protocol error: %v", err)
	}
	if !result.IsError || !strings.Contains(callResultText(t, result), "not on arc_c_dynamic_write_allowlist") {
		t.Fatalf("result = %#v, want allowlist refusal", result)
	}
	if store.allowedName != "write_file" {
		t.Errorf("allowlist lookup name = %q, want write_file", store.allowedName)
	}
	if proxyCalled {
		t.Error("proxy called despite write allowlist refusal")
	}
}

func TestSubstrateToolMCPProxyInjectsSessionOnlyWhenOptedIn(t *testing.T) {
	store := &fakeSubstrateToolStore{target: substrateToolTarget{
		Kind: "mcp_proxy", Server: "pg-ai-stewards", Tool: "harness_run",
		InjectSession: true, EffectClass: "read",
	}}
	var gotArgs map[string]any
	proxy := func(_ context.Context, _, _ string, args map[string]any) (*mcp.CallToolResult, error) {
		gotArgs = args
		return &mcp.CallToolResult{}, nil
	}

	_, _, err := makeSubstrateToolCall(store, "wi--12345678--pilot", proxy)(context.Background(), nil,
		SubstrateToolInput{Name: "harness_run", Args: map[string]any{"session_id": "model-guessed"}})
	if err != nil {
		t.Fatalf("substrate_tool returned protocol error: %v", err)
	}
	if gotArgs["session_id"] != "wi--12345678--pilot" {
		t.Errorf("proxy session_id = %#v, want authoritative dispatch session", gotArgs["session_id"])
	}
}
