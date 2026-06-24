# Retry/backoff oracle — bgworker transient HTTP failover

Deterministic, reproducible proof for the in-loop retry/backoff in
`extension/src/bgworker.rs` (`send_with_retry`): a transient `429/5xx` from a
model provider is retried with exponential backoff so a single blip mid-tool-loop
no longer fails the whole stage. A *persistent* transient still falls through
(bounded) to the steward's stage-level alias failover (`32-alias-failover.sql`).

Not wired into CI (needs Docker + a host port + a live build); run it by hand when
touching the dispatch retry path. The pure backoff math is unit-testable; this
harness proves the end-to-end behavior through the real `reqwest` path.

## Pieces

- `stub429.py` — an OpenAI-compat `/v1/chat/completions` stub. Returns HTTP 429
  for the first `fail_first` requests since the last reset, then a valid SSE
  completion. Control plane: `GET /set?fail=N` (reset counter), `GET /count`.

## Run

```sh
# 1. start the stub on the host (reachable from a container at host.docker.internal:8799)
STUB_FAIL_FIRST=0 STUB_PORT=8799 python tests/retry-oracle/stub429.py 2>/tmp/stub.log &

# 2. a scratch pg from the built image, with the stub as a provider + fast backoff
docker run -d --name retry-oracle --add-host=host.docker.internal:host-gateway \
  -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=x -e POSTGRES_DB=stewards \
  -e STEWARDS_PROVIDER_STUB_KIND=openai \
  -e STEWARDS_PROVIDER_STUB_BASE_URL=http://host.docker.internal:8799/v1 \
  -e STEWARDS_PROVIDER_STUB_API_KEY=x \
  -e STEWARDS_PROVIDER_STUB_DEFAULT_MODEL=stub-model \
  -e STEWARDS_HTTP_RETRY_MAX=3 -e STEWARDS_HTTP_RETRY_BASE_MS=200 \
  stewards-oss-pg:pg18 -c shared_preload_libraries=pg_ai_stewards
# wait for readiness, then:
docker exec retry-oracle psql -U stewards -d stewards -c "CREATE EXTENSION pg_ai_stewards CASCADE;"

# helper: enqueue one chat to the stub (a session row is required — messages FKs sessions)
enq() {  # $1 = session id
  docker exec retry-oracle psql -U stewards -d stewards -tAc \
    "DELETE FROM stewards.work_queue WHERE provider='stub';
     INSERT INTO stewards.sessions (id,kind) VALUES ('$1','chat') ON CONFLICT DO NOTHING;
     SELECT stewards.enqueue('chat','stub',
       '{\"session_id\":\"$1\",\"agent_family\":\"dev\",\"requested_model\":\"stub-model\",
         \"body\":{\"model\":\"stub-model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}}'::jsonb);"
}
status() { docker exec retry-oracle psql -U stewards -d stewards -tAc \
  "SELECT status||' | '||left(coalesce(error,''),50) FROM stewards.work_queue WHERE provider='stub' ORDER BY id DESC LIMIT 1;"; }
count() { curl -s http://127.0.0.1:8799/count; }
reset() { curl -s "http://127.0.0.1:8799/set?fail=$1"; }
```

## Expected results

| case | command | row | requests |
|------|---------|-----|----------|
| **absorb** (transient blip) | `reset 2; enq ot-1` | `done` | 3 (429,429,200) |
| **exhaustion** (persistent) | `reset 99; enq ot-2` | `error` (chat HTTP 429) | 3 then give up |
| **baseline / inverse** | run with `STEWARDS_HTTP_RETRY_MAX=1`, `reset 1; enq b` | `error` | 1 (no retry) |

The bgworker log shows `chat transient HTTP 429 (attempt N/3); backing off` for each
absorbed attempt. Cleanup: `docker rm -f retry-oracle` + kill the stub.

Proven 2026-06-24 on the #243 build (see `.spec/journal/2026-06-24-retry-backoff-243.md`).
