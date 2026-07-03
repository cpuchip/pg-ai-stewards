// OTel span exporter (miss D of the 2026-07-03 audit synthesis,
// .spec/proposals/audit-synthesis-2026-07.md: "emit OTLP spans per
// turn/tool-call from rows that already exist").
//
// The substrate's SQL-native audit is the deepest trace in the field (every
// dispatch, tool call, and cost event is a durable row -- see
// docs/anatomy-of-a-turn.md), but it speaks no standard wire protocol. This
// file is a pure READER on that ledger: it polls completed work_items,
// projects the rows it already has onto a 3-level OTLP span tree, and POSTs
// them to whatever OTLP/HTTP collector the operator points it at. It writes
// nothing to the ledger except its own poll checkpoint.
//
// Span tree, one trace per work_item (docs/otel.md has the full mapping):
//
//	work_item (root span, trace id = the work_item's own uuid)
//	  +- session   (one per stage dispatch -- docs/anatomy-of-a-turn.md
//	  |             Scene 2; session id is the documented `wi--<uuid8>--
//	  |             <stage>` convention, e.g. extension/37-tool-groups.sql)
//	  |     +- tool call (one per role='tool' message, matched back to the
//	  |                    requesting assistant message's tool_calls[].id)
//
// Disabled (zero overhead, zero log noise beyond one startup line) unless
// OTEL_EXPORTER_OTLP_ENDPOINT is set. Started from runBridgeRun alongside
// the materializer (materializer.go) -- same "own goroutine, own poll
// ticker, log and continue on error" shape.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	otelPollInterval   = 10 * time.Second
	otelDefaultService = "pg-ai-stewards"
	otelCheckpointKey  = "otel.checkpoint"
	otelBackfillCap    = 1 * time.Hour
	otelBatchLimit     = 200
)

// otelExporter holds the poller's config + a reused HTTP client (the audit
// itself flagged "cache the reqwest client... reuse it" as a Rust-side
// lesson; the same discipline applies here on the Go side).
type otelExporter struct {
	pool        *pgxpool.Pool
	client      *http.Client
	endpoint    string // base OTEL_EXPORTER_OTLP_ENDPOINT, no trailing slash
	serviceName string
	headers     map[string]string
}

// runOtelExporter is started from runBridgeRun in a goroutine, mirroring
// runMaterializer's shape. Returns only when ctx is done, OR immediately at
// startup if OTEL_EXPORTER_OTLP_ENDPOINT is unset -- the disabled path costs
// one log line and nothing else.
func runOtelExporter(ctx context.Context, pool *pgxpool.Pool) {
	endpoint := strings.TrimRight(strings.TrimSpace(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")), "/")
	if endpoint == "" {
		log.Printf("otel: OTEL_EXPORTER_OTLP_ENDPOINT not set -- span export disabled")
		return
	}

	serviceName := strings.TrimSpace(os.Getenv("OTEL_SERVICE_NAME"))
	if serviceName == "" {
		serviceName = otelDefaultService
	}

	exp := &otelExporter{
		pool:        pool,
		client:      &http.Client{Timeout: 15 * time.Second},
		endpoint:    endpoint,
		serviceName: serviceName,
		headers:     parseOtelHeaders(os.Getenv("OTEL_EXPORTER_OTLP_HEADERS")),
	}

	checkpoint, err := exp.loadCheckpoint(ctx)
	if err != nil {
		log.Printf("otel: load checkpoint failed: %v -- span export disabled", err)
		return
	}
	log.Printf("otel: exporting spans to %s/v1/traces (service=%s, poll=%s, checkpoint=%s)",
		endpoint, serviceName, otelPollInterval, checkpoint.Format(time.RFC3339))

	// Drain once at startup (mirrors materializer.go), then settle into the
	// tick loop.
	checkpoint = exp.tick(ctx, checkpoint)

	ticker := time.NewTicker(otelPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Printf("otel: shutting down (ctx done)")
			return
		case <-ticker.C:
			checkpoint = exp.tick(ctx, checkpoint)
		}
	}
}

// tick does one poll-export-checkpoint cycle. On any failure it logs and
// returns the checkpoint UNCHANGED so the same rows are retried next tick --
// deterministic span/trace ids (otel_otlp.go) make that safe: a retried
// export produces byte-identical spans, which collectors treat as a
// harmless duplicate rather than corrupting the trace.
func (e *otelExporter) tick(ctx context.Context, checkpoint time.Time) time.Time {
	items, err := e.fetchWorkItems(ctx, checkpoint, otelBatchLimit)
	if err != nil {
		log.Printf("otel: fetch work_items failed: %v", err)
		return checkpoint
	}
	if len(items) == 0 {
		return checkpoint
	}

	spans, maxUpdated, err := e.buildSpans(ctx, items)
	if err != nil {
		log.Printf("otel: build spans failed: %v", err)
		return checkpoint
	}

	if len(spans) > 0 {
		if err := otlpPost(ctx, e.client, e.endpoint, e.headers, e.buildRequest(spans)); err != nil {
			log.Printf("otel: export %d span(s) for %d work_item(s) FAILED: %v -- will retry next tick",
				len(spans), len(items), err)
			return checkpoint
		}
	}

	if err := e.saveCheckpoint(ctx, maxUpdated); err != nil {
		log.Printf("otel: save checkpoint failed (spans already sent): %v", err)
		return checkpoint
	}

	if len(spans) > 0 {
		log.Printf("otel: exported %d span(s) for %d work_item(s), checkpoint -> %s",
			len(spans), len(items), maxUpdated.Format(time.RFC3339))
	}
	return maxUpdated
}

func (e *otelExporter) buildRequest(spans []otlpSpan) otlpExportRequest {
	return otlpExportRequest{
		ResourceSpans: []otlpResourceSpans{{
			Resource: otlpResource{Attributes: []otlpKV{
				strAttr("service.name", e.serviceName),
				strAttr("service.version", version),
				strAttr("telemetry.sdk.name", "pg-ai-stewards-otel-export"),
				strAttr("telemetry.sdk.language", "go"),
			}},
			ScopeSpans: []otlpScopeSpans{{
				Scope: otlpScope{Name: "github.com/cpuchip/pg-ai-stewards/otel-export", Version: version},
				Spans: spans,
			}},
		}},
	}
}

// ---------------------------------------------------------------------
// Checkpoint (stewards.config key 'otel.checkpoint')
// ---------------------------------------------------------------------

func (e *otelExporter) loadCheckpoint(ctx context.Context) (time.Time, error) {
	var raw *string
	if err := e.pool.QueryRow(ctx, `SELECT stewards.config_get_text($1)`, otelCheckpointKey).Scan(&raw); err != nil {
		return time.Time{}, fmt.Errorf("read checkpoint: %w", err)
	}
	if raw == nil || *raw == "" {
		// First run ever: cap the backfill so enabling the exporter on a
		// substrate with months of history doesn't flood the collector.
		cp := time.Now().UTC().Add(-otelBackfillCap)
		if err := e.saveCheckpoint(ctx, cp); err != nil {
			return time.Time{}, fmt.Errorf("seed checkpoint: %w", err)
		}
		return cp, nil
	}
	t, err := time.Parse(time.RFC3339Nano, *raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("parse checkpoint %q: %w", *raw, err)
	}
	return t, nil
}

func (e *otelExporter) saveCheckpoint(ctx context.Context, t time.Time) error {
	_, err := e.pool.Exec(ctx,
		`SELECT stewards.config_set($1, to_jsonb($2::text), $3)`,
		otelCheckpointKey,
		t.UTC().Format(time.RFC3339Nano),
		"OTel exporter: last-exported work_item.updated_at, RFC3339Nano UTC (see cmd/stewards-mcp/otel_export.go)")
	if err != nil {
		return fmt.Errorf("config_set: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------
// Ledger reads
// ---------------------------------------------------------------------

type otelWorkItem struct {
	ID             string
	Slug           string
	PipelineFamily string
	CurrentStage   string
	Status         string
	Origin         string
	TokensIn       int64
	TokensOut      int64
	CostMicro      int64
	CreatedAt      time.Time
	UpdatedAt      time.Time
	CompletedAt    *time.Time
	ProjectAssoc   string
	ErrorText      string
	SessionIDs     []string
}

// fetchWorkItems polls terminal-state work_items (the substrate's
// "completed since a checkpoint" -- pending/in_progress/awaiting_review
// rows are still live and would produce an incomplete trace).
func (e *otelExporter) fetchWorkItems(ctx context.Context, since time.Time, limit int) ([]otelWorkItem, error) {
	rows, err := e.pool.Query(ctx, `
		SELECT id::text, coalesce(slug,''), pipeline_family, current_stage, status, origin,
		       tokens_in, tokens_out, cost_micro_dollars,
		       created_at, updated_at, completed_at,
		       coalesce(project_association,''), coalesce(error,''),
		       session_ids
		  FROM stewards.work_items
		 WHERE status IN ('completed','failed','cancelled')
		   AND updated_at > $1
		 ORDER BY updated_at ASC
		 LIMIT $2`, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []otelWorkItem
	for rows.Next() {
		var it otelWorkItem
		var completedAt *time.Time
		if err := rows.Scan(&it.ID, &it.Slug, &it.PipelineFamily, &it.CurrentStage, &it.Status, &it.Origin,
			&it.TokensIn, &it.TokensOut, &it.CostMicro,
			&it.CreatedAt, &it.UpdatedAt, &completedAt,
			&it.ProjectAssoc, &it.ErrorText, &it.SessionIDs); err != nil {
			return nil, err
		}
		it.CompletedAt = completedAt
		out = append(out, it)
	}
	return out, rows.Err()
}

type otelSession struct {
	Kind         string
	CreatedAt    time.Time
	LastActiveAt time.Time
}

func (e *otelExporter) fetchSessions(ctx context.Context, ids []string) (map[string]otelSession, error) {
	out := map[string]otelSession{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := e.pool.Query(ctx,
		`SELECT id, kind, created_at, last_active_at FROM stewards.sessions WHERE id = ANY($1)`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var s otelSession
		if err := rows.Scan(&id, &s.Kind, &s.CreatedAt, &s.LastActiveAt); err != nil {
			return nil, err
		}
		out[id] = s
	}
	return out, rows.Err()
}

// fetchStageAgentFamilies loads every pipeline's declared stage ->
// agent_family map in one query (the table is tiny; re-fetching it every
// tick is simpler and cheap enough to not warrant a cache). Note: stage
// `model`/`provider` are role ALIASES ("ingest"/"reason"/"critic"), not real
// model/provider names -- verified against the live substrate's
// research-write pipeline -- so this map deliberately carries agent_family
// only. Actual model/provider come from cost_events (fetchCostAgg below).
func (e *otelExporter) fetchStageAgentFamilies(ctx context.Context) (map[[2]string]string, error) {
	out := map[[2]string]string{}
	rows, err := e.pool.Query(ctx, `
		SELECT p.family, s.elem->>'name', coalesce(s.elem->>'agent_family','')
		  FROM stewards.pipelines p
		 CROSS JOIN LATERAL jsonb_array_elements(p.stages) s(elem)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var family, stage, agentFamily string
		if err := rows.Scan(&family, &stage, &agentFamily); err != nil {
			return nil, err
		}
		out[[2]string{family, stage}] = agentFamily
	}
	return out, rows.Err()
}

type otelMessage struct {
	ID         int64
	SessionID  string
	Role       string
	Content    string
	Model      string
	ToolCalls  []byte // raw jsonb, decoded lazily
	ToolCallID string
	CreatedAt  time.Time
}

func (e *otelExporter) fetchMessages(ctx context.Context, sessionIDs []string) ([]otelMessage, error) {
	if len(sessionIDs) == 0 {
		return nil, nil
	}
	rows, err := e.pool.Query(ctx, `
		SELECT id, session_id, role, content, coalesce(model,''),
		       tool_calls, coalesce(tool_call_id,''), created_at
		  FROM stewards.messages
		 WHERE session_id = ANY($1)
		 ORDER BY session_id, created_at, id`, sessionIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []otelMessage
	for rows.Next() {
		var m otelMessage
		if err := rows.Scan(&m.ID, &m.SessionID, &m.Role, &m.Content, &m.Model,
			&m.ToolCalls, &m.ToolCallID, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

type otelCostAgg struct {
	InputTokens  int64
	OutputTokens int64
	MicroDollars int64
	Models       map[string]bool
	Providers    map[string]bool
}

// fetchCostAgg sums the real, actually-dispatched provider/model per
// (work_item, session) -- the substrate's model-alias/fallback machinery
// (docs/wiring-up-models.md) means the pipeline's declared stage model can
// differ from what actually ran; cost_events records the real one.
func (e *otelExporter) fetchCostAgg(ctx context.Context, workItemIDs []string) (map[[2]string]*otelCostAgg, error) {
	out := map[[2]string]*otelCostAgg{}
	if len(workItemIDs) == 0 {
		return out, nil
	}
	rows, err := e.pool.Query(ctx, `
		SELECT work_item_id::text, coalesce(session_id,''), provider, model,
		       sum(input_tokens), sum(output_tokens), sum(micro_dollars)
		  FROM stewards.cost_events
		 WHERE work_item_id = ANY($1::uuid[])
		 GROUP BY work_item_id, session_id, provider, model`, workItemIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var workItemID, sessionID, provider, model string
		var inTok, outTok, micro int64
		if err := rows.Scan(&workItemID, &sessionID, &provider, &model, &inTok, &outTok, &micro); err != nil {
			return nil, err
		}
		key := [2]string{workItemID, sessionID}
		agg := out[key]
		if agg == nil {
			agg = &otelCostAgg{Models: map[string]bool{}, Providers: map[string]bool{}}
			out[key] = agg
		}
		agg.InputTokens += inTok
		agg.OutputTokens += outTok
		agg.MicroDollars += micro
		if model != "" {
			agg.Models[model] = true
		}
		if provider != "" {
			agg.Providers[provider] = true
		}
	}
	return out, rows.Err()
}

// ---------------------------------------------------------------------
// Span construction
// ---------------------------------------------------------------------

// buildSpans is the single entry point: given a batch of terminal
// work_items, issue the handful of batched queries needed to describe them
// and project everything onto the span tree. Returns the max updated_at
// seen (the caller advances the checkpoint to it on success).
func (e *otelExporter) buildSpans(ctx context.Context, items []otelWorkItem) ([]otlpSpan, time.Time, error) {
	var maxUpdated time.Time
	var allSessionIDs, workItemIDs []string
	for _, it := range items {
		allSessionIDs = append(allSessionIDs, it.SessionIDs...)
		workItemIDs = append(workItemIDs, it.ID)
		if it.UpdatedAt.After(maxUpdated) {
			maxUpdated = it.UpdatedAt
		}
	}

	sessions, err := e.fetchSessions(ctx, allSessionIDs)
	if err != nil {
		return nil, maxUpdated, fmt.Errorf("fetch sessions: %w", err)
	}
	stageAgents, err := e.fetchStageAgentFamilies(ctx)
	if err != nil {
		return nil, maxUpdated, fmt.Errorf("fetch pipeline stages: %w", err)
	}
	messages, err := e.fetchMessages(ctx, allSessionIDs)
	if err != nil {
		return nil, maxUpdated, fmt.Errorf("fetch messages: %w", err)
	}
	costAgg, err := e.fetchCostAgg(ctx, workItemIDs)
	if err != nil {
		return nil, maxUpdated, fmt.Errorf("fetch cost_events: %w", err)
	}

	msgsBySession := map[string][]otelMessage{}
	for _, m := range messages {
		msgsBySession[m.SessionID] = append(msgsBySession[m.SessionID], m)
	}

	var spans []otlpSpan
	for _, it := range items {
		ws, err := buildWorkItemSpans(it, sessions, stageAgents, msgsBySession, costAgg)
		if err != nil {
			log.Printf("otel: work_item %s: %v (skipped)", it.ID, err)
			continue
		}
		spans = append(spans, ws...)
	}
	return spans, maxUpdated, nil
}

// stageNameFromSessionID parses the documented wi--<uuid8>--<stage>
// session id convention (extension/04-work-items.sql
// work_item_dispatch_stage; also relied on by extension/37-tool-groups.sql
// and extension/34-doc-builder.sql). Returns "" for anything that doesn't
// match -- callers degrade gracefully rather than erroring.
func stageNameFromSessionID(sessionID string) string {
	if !strings.HasPrefix(sessionID, "wi--") {
		return ""
	}
	parts := strings.SplitN(sessionID, "--", 3)
	if len(parts) != 3 {
		return ""
	}
	return parts[2]
}

func buildWorkItemSpans(it otelWorkItem, sessions map[string]otelSession, stageAgents map[[2]string]string,
	msgsBySession map[string][]otelMessage, costAgg map[[2]string]*otelCostAgg) ([]otlpSpan, error) {

	traceID, err := traceIDFromUUID(it.ID)
	if err != nil {
		return nil, err
	}
	rootSpanID := spanIDFor("root:" + it.ID)

	endTime := it.UpdatedAt
	if it.CompletedAt != nil {
		endTime = *it.CompletedAt
	}
	if !endTime.After(it.CreatedAt) {
		endTime = it.CreatedAt.Add(time.Millisecond)
	}

	rootAttrs := []otlpKV{
		strAttr("stewards.work_item.id", it.ID),
		strAttr("stewards.pipeline_family", it.PipelineFamily),
		strAttr("stewards.origin", it.Origin),
		strAttr("stewards.status", it.Status),
		intAttr("stewards.tokens_in", it.TokensIn),
		intAttr("stewards.tokens_out", it.TokensOut),
		doubleAttr("stewards.cost_usd", float64(it.CostMicro)/1e6),
	}
	if it.Slug != "" {
		rootAttrs = append(rootAttrs, strAttr("stewards.work_item.slug", it.Slug))
	}
	if it.ProjectAssoc != "" {
		rootAttrs = append(rootAttrs, strAttr("stewards.project", it.ProjectAssoc))
	}

	rootStatus := &otlpStatus{Code: statusUnset}
	switch it.Status {
	case "completed":
		rootStatus.Code = statusOK
	case "failed":
		rootStatus.Code = statusError
		rootStatus.Message = it.ErrorText
	}

	spans := []otlpSpan{{
		TraceID: traceID, SpanID: rootSpanID,
		Name:              "work_item:" + it.PipelineFamily,
		Kind:              spanKindInternal,
		StartTimeUnixNano: nanoStr(it.CreatedAt.UnixNano()),
		EndTimeUnixNano:   nanoStr(endTime.UnixNano()),
		Attributes:        rootAttrs,
		Status:            rootStatus,
	}}

	for _, sessID := range it.SessionIDs {
		sess, haveSess := sessions[sessID]
		msgs := msgsBySession[sessID]
		if !haveSess && len(msgs) == 0 {
			continue // session row + all its messages are gone; nothing to show
		}
		stageName := stageNameFromSessionID(sessID)
		agentFamily := stageAgents[[2]string{it.PipelineFamily, stageName}]

		sessStart, sessEnd := sess.CreatedAt, sess.LastActiveAt
		if len(msgs) > 0 {
			sessStart, sessEnd = msgs[0].CreatedAt, msgs[0].CreatedAt
			for _, m := range msgs {
				if m.CreatedAt.Before(sessStart) {
					sessStart = m.CreatedAt
				}
				if m.CreatedAt.After(sessEnd) {
					sessEnd = m.CreatedAt
				}
			}
		}
		if !sessEnd.After(sessStart) {
			sessEnd = sessStart.Add(time.Millisecond)
		}

		sessSpanID := spanIDFor("session:" + sessID)
		sessAttrs := []otlpKV{
			strAttr("stewards.session_id", sessID),
		}
		if stageName != "" {
			sessAttrs = append(sessAttrs, strAttr("stewards.stage_name", stageName))
		}
		if agentFamily != "" {
			sessAttrs = append(sessAttrs, strAttr("stewards.agent_family", agentFamily))
		}
		if sess.Kind != "" {
			sessAttrs = append(sessAttrs, strAttr("stewards.session_kind", sess.Kind))
		}

		model := lastNonEmptyModel(msgs)
		provider := ""
		if agg := costAgg[[2]string{it.ID, sessID}]; agg != nil {
			sessAttrs = append(sessAttrs,
				intAttr("stewards.tokens_in", agg.InputTokens),
				intAttr("stewards.tokens_out", agg.OutputTokens),
				doubleAttr("stewards.cost_usd", float64(agg.MicroDollars)/1e6))
			if len(agg.Models) == 1 {
				for m := range agg.Models {
					model = m
				}
			}
			if len(agg.Providers) == 1 {
				for p := range agg.Providers {
					provider = p
				}
			}
		}
		if model != "" {
			sessAttrs = append(sessAttrs, strAttr("stewards.model", model))
		}
		if provider != "" {
			sessAttrs = append(sessAttrs, strAttr("stewards.provider", provider))
		}

		sessStatus := &otlpStatus{Code: statusUnset}
		if it.Status == "completed" {
			sessStatus.Code = statusOK
		} else if it.Status == "failed" && stageName != "" && stageName == it.CurrentStage {
			// current_stage isn't reset on failure (04-work-items.sql status
			// lifecycle comment), so it names the stage that was running
			// when the work_item died. Earlier, already-advanced-past
			// stages stay Unset -- they didn't fail, the chain did.
			sessStatus.Code = statusError
			sessStatus.Message = it.ErrorText
		}

		spans = append(spans, otlpSpan{
			TraceID: traceID, SpanID: sessSpanID, ParentSpanID: rootSpanID,
			Name:              spanNameForStage(stageName),
			Kind:              spanKindInternal,
			StartTimeUnixNano: nanoStr(sessStart.UnixNano()),
			EndTimeUnixNano:   nanoStr(sessEnd.UnixNano()),
			Attributes:        sessAttrs,
			Status:            sessStatus,
		})

		spans = append(spans, buildToolCallSpans(traceID, sessSpanID, msgs)...)
	}
	return spans, nil
}

func spanNameForStage(stage string) string {
	if stage == "" {
		return "session"
	}
	return "stage:" + stage
}

func lastNonEmptyModel(msgs []otelMessage) string {
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].Model != "" {
			return msgs[i].Model
		}
	}
	return ""
}

type toolCallShape struct {
	ID       string `json:"id"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

// buildToolCallSpans matches each role='tool' message back to the
// tool_calls[] entry (by id) on the assistant message that requested it --
// extension/src/bgworker.rs is the authoring side of both columns. Span
// start = the requesting assistant message's created_at (when the model
// asked); end = the tool reply's created_at (when the answer landed as a
// row). A tool call with no matching request (shouldn't happen, but the
// join is defensive) still gets a degenerate zero-width span rather than
// being dropped silently.
func buildToolCallSpans(traceID, parentSpanID string, msgs []otelMessage) []otlpSpan {
	type pending struct {
		name, args string
		calledAt   time.Time
	}
	byCallID := map[string]pending{}

	var spans []otlpSpan
	for _, m := range msgs {
		if m.Role == "assistant" && len(m.ToolCalls) > 0 {
			var calls []toolCallShape
			if err := json.Unmarshal(m.ToolCalls, &calls); err == nil {
				for _, c := range calls {
					if c.ID == "" {
						continue
					}
					byCallID[c.ID] = pending{name: c.Function.Name, args: c.Function.Arguments, calledAt: m.CreatedAt}
				}
			}
		}
		if m.Role != "tool" || m.ToolCallID == "" {
			continue
		}
		p := byCallID[m.ToolCallID]
		name := p.name
		if name == "" {
			name = "unknown_tool"
		}
		start := p.calledAt
		if start.IsZero() {
			start = m.CreatedAt
		}
		end := m.CreatedAt
		if !end.After(start) {
			end = start.Add(time.Millisecond)
		}

		attrs := []otlpKV{
			strAttr("stewards.tool", name),
			strAttr("stewards.tool_call_id", m.ToolCallID),
		}
		if p.args != "" {
			attrs = append(attrs, strAttr("stewards.tool.arguments", truncateForAttr(p.args)))
		}

		status := &otlpStatus{Code: statusOK}
		if msg, isErr := toolReplyError(m.Content); isErr {
			status.Code = statusError
			status.Message = msg
		}

		spans = append(spans, otlpSpan{
			TraceID: traceID, SpanID: spanIDFor(fmt.Sprintf("tool:%d", m.ID)), ParentSpanID: parentSpanID,
			Name:              "tool:" + name,
			Kind:              spanKindInternal,
			StartTimeUnixNano: nanoStr(start.UnixNano()),
			EndTimeUnixNano:   nanoStr(end.UnixNano()),
			Attributes:        attrs,
			Status:            status,
		})
		delete(byCallID, m.ToolCallID)
	}
	return spans
}

// toolReplyError detects the substrate's documented per-call error shape
// (docs/anatomy-of-a-turn.md Scene 5: a failing tool call's error is
// captured into the tool reply as a JSON object with an "error" key).
// Returns the message + true when the reply is such an error object; false
// for any normal reply, including ones that happen to not be JSON.
func toolReplyError(content string) (string, bool) {
	var v map[string]any
	if err := json.Unmarshal([]byte(content), &v); err != nil {
		return "", false
	}
	e, ok := v["error"]
	if !ok {
		return "", false
	}
	switch t := e.(type) {
	case string:
		if t == "" {
			return "", false
		}
		return truncateForAttr(t), true
	case nil:
		return "", false
	default:
		b, _ := json.Marshal(t)
		return truncateForAttr(string(b)), true
	}
}

// truncateForAttr caps a value going into a span attribute or status
// message. Ledger content (tool args, error bodies) is unbounded; OTLP
// attributes are not meant to carry megabytes.
func truncateForAttr(s string) string {
	const limit = 2000
	if len(s) <= limit {
		return s
	}
	return s[:limit] + "...(truncated)"
}
