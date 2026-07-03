package main

import (
	"strings"
	"testing"
)

func TestStageNameFromSessionID(t *testing.T) {
	cases := []struct {
		sessionID string
		want      string
	}{
		{"wi--dd7945fb--critique", "critique"},
		{"wi--dd7945fb--context_gather", "context_gather"},
		{"wi--abc12345--build", "build"},
		{"not-a-wi-session", ""},
		{"wi--onlytwoparts", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := stageNameFromSessionID(c.sessionID); got != c.want {
			t.Errorf("stageNameFromSessionID(%q) = %q, want %q", c.sessionID, got, c.want)
		}
	}
}

// Real session ids follow extension/04-work-items.sql's
// work_item_dispatch_stage: 'wi--' || substring(uuid FROM 1 FOR 8) || '--' || stage.
func TestStageNameFromSessionID_RealConvention(t *testing.T) {
	workItemID := "dd7945fb-9839-4b87-8835-8aea48c8f516"
	sessionID := "wi--" + workItemID[:8] + "--critique"
	if got := stageNameFromSessionID(sessionID); got != "critique" {
		t.Errorf("stageNameFromSessionID(%q) = %q, want %q", sessionID, got, "critique")
	}
}

func TestTraceIDFromUUID(t *testing.T) {
	id := "dd7945fb-9839-4b87-8835-8aea48c8f516"
	got, err := traceIDFromUUID(id)
	if err != nil {
		t.Fatalf("traceIDFromUUID(%q) error: %v", id, err)
	}
	// Deterministic: same uuid -> same trace id, every time.
	got2, _ := traceIDFromUUID(id)
	if got != got2 {
		t.Errorf("traceIDFromUUID not deterministic: %q vs %q", got, got2)
	}
	// Decodes to exactly 16 bytes (a valid OTLP trace id) as lowercase hex.
	if len(got) != 32 {
		t.Errorf("traceIDFromUUID(%q) = %q, want a 32-char hex string (16 raw bytes)", id, got)
	}
	if got != strings.ReplaceAll(id, "-", "") {
		t.Errorf("traceIDFromUUID(%q) = %q, want the uuid's own hex digits (byte-for-byte)", id, got)
	}

	if _, err := traceIDFromUUID("not-a-uuid"); err == nil {
		t.Errorf("traceIDFromUUID(\"not-a-uuid\") should have errored")
	}
}

func TestSpanIDForDeterministic(t *testing.T) {
	a := spanIDFor("session:wi--dd7945fb--critique")
	b := spanIDFor("session:wi--dd7945fb--critique")
	if a != b {
		t.Errorf("spanIDFor not deterministic: %q vs %q", a, b)
	}
	c := spanIDFor("session:wi--dd7945fb--build")
	if a == c {
		t.Errorf("spanIDFor collided for two different seeds: %q", a)
	}
	// 8 raw bytes hex-encoded is always 16 chars.
	if len(a) != 16 {
		t.Errorf("spanIDFor(...) = %q, want a 16-char hex string (8 raw bytes)", a)
	}
}

func TestParseOtelHeaders(t *testing.T) {
	got := parseOtelHeaders("x-honeycomb-team=abc123, x-another = xyz ,malformed,=noKey,valid=")
	want := map[string]string{
		"x-honeycomb-team": "abc123",
		"x-another":        "xyz",
		"valid":            "",
	}
	if len(got) != len(want) {
		t.Fatalf("parseOtelHeaders() = %#v, want %#v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("parseOtelHeaders()[%q] = %q, want %q", k, got[k], v)
		}
	}

	if got := parseOtelHeaders(""); len(got) != 0 {
		t.Errorf("parseOtelHeaders(\"\") = %#v, want empty map", got)
	}
}

func TestToolReplyError(t *testing.T) {
	cases := []struct {
		content   string
		wantIsErr bool
	}{
		{`{"error": "search returned nothing"}`, true},
		{`{"error": ""}`, false},
		{`{"content": "all good"}`, false},
		{"plain text, not json", false},
		{`{"error": {"code": 500, "message": "boom"}}`, true},
	}
	for _, c := range cases {
		_, isErr := toolReplyError(c.content)
		if isErr != c.wantIsErr {
			t.Errorf("toolReplyError(%q) isErr = %v, want %v", c.content, isErr, c.wantIsErr)
		}
	}
}

func TestTruncateForAttr(t *testing.T) {
	short := "hello"
	if got := truncateForAttr(short); got != short {
		t.Errorf("truncateForAttr(%q) = %q, want unchanged", short, got)
	}

	long := strings.Repeat("a", 3000)
	got := truncateForAttr(long)
	if len(got) >= len(long) {
		t.Errorf("truncateForAttr did not shorten a %d-char string", len(long))
	}
	if !strings.HasSuffix(got, "...(truncated)") {
		t.Errorf("truncateForAttr(long) = %q, want a truncation suffix", got[len(got)-20:])
	}
}

func TestSpanNameForStage(t *testing.T) {
	if got := spanNameForStage("critique"); got != "stage:critique" {
		t.Errorf("spanNameForStage(\"critique\") = %q, want %q", got, "stage:critique")
	}
	if got := spanNameForStage(""); got != "session" {
		t.Errorf("spanNameForStage(\"\") = %q, want %q", got, "session")
	}
}

func TestLastNonEmptyModel(t *testing.T) {
	msgs := []otelMessage{
		{Role: "user", Model: "qwen3.6-35b-a3b"},
		{Role: "assistant", Model: ""},
		{Role: "tool", Model: ""},
	}
	if got := lastNonEmptyModel(msgs); got != "qwen3.6-35b-a3b" {
		t.Errorf("lastNonEmptyModel = %q, want %q", got, "qwen3.6-35b-a3b")
	}
	if got := lastNonEmptyModel(nil); got != "" {
		t.Errorf("lastNonEmptyModel(nil) = %q, want empty", got)
	}
}
