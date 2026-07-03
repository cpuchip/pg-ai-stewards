# OpenTelemetry export

The substrate's audit is world-class and speaks no standard wire protocol:
every dispatch, tool call, and cost event is already a durable row (see
[anatomy-of-a-turn.md](anatomy-of-a-turn.md)), but nothing outside Postgres
can see a turn happen. This is the smallest fix for that: a background
poller in the bridge that projects the ledger's own rows onto an OTLP span
tree and POSTs them to whatever collector you already run. It writes
nothing new to the ledger except its own poll checkpoint.

Ratified from the 2026-07-03 audit synthesis's "miss D" (`.spec/proposals/audit-synthesis-2026-07.md`):
> OTel export | everything-is-a-row + Stewdio | emit OTLP spans per
> turn/tool-call from rows that already exist | S · high

## What gets exported

One **trace per work_item**. The trace id is the work_item's own UUID,
byte-for-byte (lowercase hex, dashes stripped) -- `SELECT * FROM
stewards.work_items WHERE id = '<trace-id-with-dashes-back>'` always finds
the exact row a trace came from, in either direction.

```
work_item                  (root span -- one per pipeline run)
  +- session               (one per stage dispatch: "context_gather", "gather",
  |                          "build", "critique", ... -- anatomy-of-a-turn.md
  |                          Scene 2. Session id is the substrate's own
  |                          `wi--<uuid8>--<stage>` convention.)
  |     +- tool call       (one per role='tool' message, matched back to the
  |                          requesting assistant message's tool_calls[].id)
```

| Span | Name | Key attributes |
|---|---|---|
| root (work_item) | `work_item:<pipeline_family>` | `stewards.work_item.id`, `stewards.pipeline_family`, `stewards.origin`, `stewards.status`, `stewards.tokens_in/out`, `stewards.cost_usd`, `stewards.work_item.slug`, `stewards.project` |
| session (stage) | `stage:<stage_name>` | `stewards.session_id`, `stewards.stage_name`, `stewards.agent_family` (from the pipeline's declared stage), `stewards.model` / `stewards.provider` (the REAL dispatched model/provider, from `cost_events` -- not the pipeline's declared value, which is a role alias like `ingest`/`reason`/`critic`, not a real model name), `stewards.tokens_in/out`, `stewards.cost_usd` |
| tool call | `tool:<tool_name>` | `stewards.tool`, `stewards.tool_call_id`, `stewards.tool.arguments` (capped at 2000 chars) |

**Status mapping:** the root span is `Error` (message = `work_items.error`)
when the work_item's status is `failed`, `Ok` when `completed`, `Unset` when
`cancelled`. The stage span carries the same Error + message ONLY on the
stage matching `current_stage` at failure time (earlier stages in the same
run completed fine -- the run failed, they didn't). A tool-call span is
`Error` whenever its reply is the substrate's documented per-call error
shape, `{"error": "..."}` (anatomy-of-a-turn.md Scene 5) -- independent of
whether the overall work_item succeeded (a tool can fail and the model can
recover).

## Enabling it

Nothing is exported, and the exporter never even starts a goroutine, unless
`OTEL_EXPORTER_OTLP_ENDPOINT` is set. Set it in `.env` (see the "OTel
export" block in `.env.example`) or the bridge service's environment:

| Env var | Default | Meaning |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | *(unset = disabled)* | Base OTLP/HTTP endpoint, e.g. `http://otel-collector:4318`. `/v1/traces` is appended. |
| `OTEL_SERVICE_NAME` | `pg-ai-stewards` | `service.name` resource attribute. |
| `OTEL_EXPORTER_OTLP_HEADERS` | *(none)* | Comma-separated `key=value` pairs added as HTTP headers -- the usual place for a collector API key (Honeycomb, Grafana Cloud, etc). |

Poll interval is a fixed 10s (not configurable -- this is a light, batched
poll of a `stewards.work_items` index, not a hot path). The first time the
exporter runs on a substrate with history, it caps the backfill to the last
1 hour (rather than flooding the collector with everything that ever
completed) -- the cap is recorded as the starting checkpoint in
`stewards.config` under key `otel.checkpoint`, and every successful export
after that advances it to the newest `updated_at` seen.

## Verifying your collector before flipping the poller on

`otel-smoke` is a subcommand of the same `stewards-mcp` binary -- the exact
fetch -> span-build -> POST code the background poller runs, invoked
directly so you can point it at a fresh collector and see real spans land
without waiting on the 10s tick or touching the checkpoint:

```
docker compose exec bridge stewards-mcp otel-smoke \
  --endpoint http://otel-collector:4318 --since 24h --limit 5
```

It is read-only against the substrate (no checkpoint write -- the flags
`--since`/`--limit` bound what it looks at, and it never calls
`stewards.config_set`), so it's safe to run against a live database
whenever you want to confirm the wire is actually up.

## A local collector, wired up

`docker-compose.otel.yaml` is an opt-in overlay (same pattern as
`docker-compose.coder.yaml` / `docker-compose.yt.yaml`): it adds an
`otel-collector` service running the stock
[`otel/opentelemetry-collector`](https://hub.docker.com/r/otel/opentelemetry-collector)
image with a `debug` exporter (prints every span to its own container
logs -- swap the config for a real backend once you've seen it work), and
points the bridge's `OTEL_EXPORTER_OTLP_ENDPOINT` at it automatically:

```
docker compose -f docker-compose.yaml -f docker-compose.otel.yaml up -d --build
docker compose logs -f otel-collector
```

Point `otel-collector-config.yaml`'s `exporters:` block at a real backend
(Honeycomb, Jaeger, Grafana Tempo, anything OTLP) when you're ready to keep
the data instead of just watching it stream by.

## Implementation notes (for the next person reading the code)

- **Hand-rolled OTLP/HTTP JSON, not the official Go SDK.** The Go SDK's
  `otlptracehttp` exporter always encodes protobuf on the wire -- there is
  no JSON codec in the Go SDK the way there is in the JS SDK -- so pulling
  it in would mean the whole `go.opentelemetry.io/proto/otlp` +
  `google.golang.org/protobuf` dependency tree for a bridge that otherwise
  carries zero protobuf dependencies. The OTLP/HTTP JSON mapping is a
  stable, spec-published wire format
  ([spec](https://opentelemetry.io/docs/specs/otlp/#otlphttp)), so
  `cmd/stewards-mcp/otel_otlp.go` is a small struct-and-marshal encoder
  instead. **Zero new `go.mod` entries.**
- **trace_id / span_id are hex, not base64** -- the one genuine surprise
  this task's proof step caught. The generic protobuf-JSON mapping says
  `bytes` fields become base64 strings, and that's what the code shipped
  with initially. POSTing that to a real `otel/opentelemetry-collector`
  produced `400 ID.UnmarshalJSONIter: length mismatch` the moment the
  base64 alphabet emitted a `+` or `/` -- the collector's `pdata` package
  implements a custom `UnmarshalJSON` for these two ID types that expects
  hex (matching the W3C `traceparent` format everything else in the
  ecosystem uses). Fixed by switching both `traceIDFromUUID` and
  `spanIDFor` (`cmd/stewards-mcp/otel_otlp.go`) to `encoding/hex`, verified
  against the same real collector afterward.
- **Deterministic ids, always.** `traceIDFromUUID` doesn't hash the
  work_item id -- it decodes and re-encodes it, so the trace id IS the
  uuid. Span ids are `sha256(seed)[:8]`, hex-encoded, where `seed` is
  `"root:<work_item_id>"`, `"session:<session_id>"`, or
  `"tool:<message_id>"`. This means re-exporting an already-sent work_item
  (which happens on any transient POST failure -- the poller doesn't
  advance its checkpoint until a POST succeeds, so it retries the same
  batch next tick) produces byte-identical spans. Most OTLP backends treat
  a repeated identical span as a harmless duplicate, not data corruption --
  the safety property that makes at-least-once retries fine here.
- **Stage -> agent_family, not stage -> model/provider.** A pipeline
  stage's declared `model`/`provider` fields are role ALIASES (`ingest`,
  `reason`, `critic` -- see `docs/wiring-up-models.md`), resolved to a real
  model/provider at dispatch time, and the substrate's fallback/escalation
  machinery can substitute a different model than the one requested. So
  `stewards.model`/`stewards.provider` on the stage span come from
  `stewards.cost_events` (what actually ran and was billed), while
  `stewards.agent_family` (a real, meaningful family like `research`) comes
  from the pipeline's own stage declaration.
- **Session -> stage name via the substrate's own convention.** Session
  ids already encode their stage (`wi--<uuid8>--<stage>` --
  `extension/04-work-items.sql`'s `work_item_dispatch_stage`, also relied
  on by `extension/37-tool-groups.sql` and `extension/34-doc-builder.sql`).
  `stageNameFromSessionID` just parses it; no extra join needed.
- **Zero-session and empty-message edge cases are real, not
  hypothetical** -- the proof run against live data hit both: an
  `a2a-handoff` work_item with no sessions at all (root span only, no
  crash), and a `research-write` work_item that failed before its first
  chat dispatch completed (a degenerate 1ms-duration stage span, using the
  `sessions` row's own `created_at`/`last_active_at` since there were no
  messages to derive timing from).
