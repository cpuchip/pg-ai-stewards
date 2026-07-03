// OTLP/HTTP JSON wire types + transport (miss D of the 2026-07-03 audit:
// "emit OTLP spans per turn/tool-call from rows that already exist").
//
// Why hand-rolled instead of go.opentelemetry.io/otel + otlptracehttp: the
// official Go exporter always encodes protobuf on the wire (there is no
// http/json codec in the Go SDK, unlike the JS SDK) -- pulling it in means
// the whole go.opentelemetry.io/proto/otlp + google.golang.org/protobuf tree
// for a bridge that otherwise carries zero protobuf dependencies. The OTLP
// JSON mapping is a stable, spec-published wire format
// (https://opentelemetry.io/docs/specs/otlp/#otlphttp -- "OTLP/HTTP JSON"),
// so a small struct-and-marshal encoder is the minimal-dependency path the
// task brief names as the acceptable fallback. Zero new go.mod entries.
//
// Field-level notes against the spec's protobuf-JSON mapping
// (https://protobuf.dev/programming-guides/proto3/#json):
//   - trace_id / span_id / parent_span_id are proto `bytes`, which the
//     generic protobuf-JSON mapping renders as base64 -- but the Go
//     collector's pdata package implements a custom UnmarshalJSON for these
//     two ID types that expects HEX, not base64 (matching the W3C
//     traceparent format everything else in the ecosystem uses). Verified
//     empirically in this task's proof step: a base64-encoded trace/span id
//     POSTed to a real otel/opentelemetry-collector instance 400s with
//     "length mismatch" the moment the base64 alphabet emits a `+` or `/`;
//     hex fixed it outright. docs/otel.md carries the collector log.
//   - start/end time and int64 attribute values are proto (u)int64 -> JSON
//     strings, to avoid float64 precision loss on 19-digit nanosecond
//     timestamps.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// Span kind + status code enums (OTLP trace.proto). Only the values this
// exporter actually emits are named.
const (
	spanKindInternal = 1 // SPAN_KIND_INTERNAL

	statusUnset = 0 // STATUS_CODE_UNSET
	statusOK    = 1 // STATUS_CODE_OK
	statusError = 2 // STATUS_CODE_ERROR
)

type otlpExportRequest struct {
	ResourceSpans []otlpResourceSpans `json:"resourceSpans"`
}

type otlpResourceSpans struct {
	Resource   otlpResource     `json:"resource"`
	ScopeSpans []otlpScopeSpans `json:"scopeSpans"`
}

type otlpResource struct {
	Attributes []otlpKV `json:"attributes,omitempty"`
}

type otlpScopeSpans struct {
	Scope otlpScope  `json:"scope"`
	Spans []otlpSpan `json:"spans"`
}

type otlpScope struct {
	Name    string `json:"name"`
	Version string `json:"version,omitempty"`
}

type otlpSpan struct {
	TraceID           string      `json:"traceId"`
	SpanID            string      `json:"spanId"`
	ParentSpanID      string      `json:"parentSpanId,omitempty"`
	Name              string      `json:"name"`
	Kind              int         `json:"kind"`
	StartTimeUnixNano string      `json:"startTimeUnixNano"`
	EndTimeUnixNano   string      `json:"endTimeUnixNano"`
	Attributes        []otlpKV    `json:"attributes,omitempty"`
	Status            *otlpStatus `json:"status,omitempty"`
}

type otlpStatus struct {
	Code    int    `json:"code"`
	Message string `json:"message,omitempty"`
}

type otlpKV struct {
	Key   string       `json:"key"`
	Value otlpAnyValue `json:"value"`
}

// otlpAnyValue mirrors opentelemetry.proto.common.v1.AnyValue. Only the
// variants this exporter needs (string/int/double) are represented; the
// proto3 JSON mapping omits unset oneof fields, which the `omitempty` tags
// give us for free.
type otlpAnyValue struct {
	StringValue *string  `json:"stringValue,omitempty"`
	IntValue    *string  `json:"intValue,omitempty"` // int64 -> JSON string
	DoubleValue *float64 `json:"doubleValue,omitempty"`
}

func strAttr(k, v string) otlpKV {
	return otlpKV{Key: k, Value: otlpAnyValue{StringValue: &v}}
}

func intAttr(k string, v int64) otlpKV {
	s := strconv.FormatInt(v, 10)
	return otlpKV{Key: k, Value: otlpAnyValue{IntValue: &s}}
}

func doubleAttr(k string, v float64) otlpKV {
	return otlpKV{Key: k, Value: otlpAnyValue{DoubleValue: &v}}
}

// nanoStr formats a duration/timestamp as the JSON-string-wrapped uint64
// nanosecond count OTLP JSON expects for *TimeUnixNano fields.
func nanoStr(unixNano int64) string {
	return strconv.FormatInt(unixNano, 10)
}

// traceIDFromUUID turns a Postgres uuid (its canonical 36-char text form)
// into the base64 wire encoding of its raw 16 bytes. The work_item's own
// UUID becomes the trace id byte-for-byte -- no hashing needed, and it means
// a human staring at a trace in a UI can go `SELECT * FROM stewards.work_items
// WHERE id = '<hex-trace-id-as-uuid>'` and land on the exact row that
// produced it.
func traceIDFromUUID(id string) (string, error) {
	hexStr := strings.ReplaceAll(id, "-", "")
	if len(hexStr) != 32 {
		return "", fmt.Errorf("work_item id %q is not a 32-hex-char uuid", id)
	}
	// Round-trip through DecodeString/EncodeToString rather than returning
	// hexStr directly: it validates the input is genuine hex (a malformed
	// "uuid" with the right dash positions but garbage characters would
	// otherwise sail through) and normalizes case.
	raw, err := hex.DecodeString(hexStr)
	if err != nil {
		return "", fmt.Errorf("decode uuid %q: %w", id, err)
	}
	return hex.EncodeToString(raw), nil
}

// spanIDFor derives a deterministic 8-byte span id from a seed string
// (sha256, first 8 bytes). Determinism matters here for the same reason
// the trace id is the raw work_item uuid: re-exporting an already-sent
// work_item (e.g. after a checkpoint-save failure that follows a
// successful POST -- see otel_export.go's tick()) produces byte-identical
// spans, which most OTLP backends treat as a harmless duplicate rather
// than a second event.
func spanIDFor(seed string) string {
	sum := sha256.Sum256([]byte(seed))
	return hex.EncodeToString(sum[:8])
}

// parseOtelHeaders decodes the standard OTEL_EXPORTER_OTLP_HEADERS shape:
// comma-separated key=value pairs (the same format every other OTel SDK
// reads), e.g. "x-honeycomb-team=abc123,x-another=xyz". Malformed pairs are
// skipped rather than failing startup -- a typo in one header shouldn't
// disable the whole exporter.
func parseOtelHeaders(raw string) map[string]string {
	out := map[string]string{}
	for _, pair := range strings.Split(raw, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		parts := strings.SplitN(pair, "=", 2)
		if len(parts) != 2 {
			continue
		}
		k := strings.TrimSpace(parts[0])
		v := strings.TrimSpace(parts[1])
		if k == "" {
			continue
		}
		out[k] = v
	}
	return out
}

// otlpPost POSTs one ExportTraceServiceRequest as OTLP/HTTP JSON to
// <endpoint>/v1/traces. endpoint must already be the base
// OTEL_EXPORTER_OTLP_ENDPOINT with no trailing slash.
func otlpPost(ctx context.Context, client *http.Client, endpoint string, headers map[string]string, req otlpExportRequest) error {
	body, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal export request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/v1/traces", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		httpReq.Header.Set(k, v)
	}

	resp, err := client.Do(httpReq)
	if err != nil {
		return fmt.Errorf("POST %s/v1/traces: %w", endpoint, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("collector returned %s: %s", resp.Status, string(b))
	}
	return nil
}
