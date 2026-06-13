# =====================================================================
# bridge.Dockerfile — the pg-ai-stewards MCP bridge daemon.
#
# Runs `stewards-mcp bridge run` as a long-lived process beside the
# Postgres+extension container. The bridge brokers tool calls between
# substrate-internal agents and the external MCP world: it claims
# kind='mcp_proxy' rows off the work_queue, spawns the target MCP server
# as a stdio subprocess, forwards the call, and writes the result back.
#
# Build context = the repository ROOT (where go.mod + cmd/ live), NOT
# this directory. docker-compose.yaml sets `context: .` and
# `dockerfile: extension/bridge.Dockerfile`.
#
# Single Go module: github.com/cpuchip/pg-ai-stewards. Every cmd/* binary
# is part of it — no go.work, no sibling-module stubs (the daemon-leg
# consolidation, 2026-06-12, collapsed five binaries into this one module).
#
# This image ships the substrate-intrinsic binaries:
#   - stewards-mcp  (the bridge itself + the substrate self-surface)
#   - fs-read-mcp   (path-scoped filesystem read, spawned on demand)
#   - stewards-cli  (migrations / ad-hoc CLI inside the container)
#   - coder-mcp     (the sandbox coding capability — spawns hardened
#                    coder-runtime sandboxes against the host docker daemon;
#                    see SECURITY.md for the trust model + hardening review)
# Generic utilities (fetch-md, git) arrive in M2. Domain MCP servers (your
# own search / docs / data tools) are "bring your own" — register one in an
# overlay and add its binary here.
# =====================================================================

# ---------------------------------------------------------------------
# Stage 1 — builder. One module, three binaries.
# ---------------------------------------------------------------------
FROM golang:1.26-alpine AS builder

RUN apk add --no-cache ca-certificates

WORKDIR /src

# Module manifests first so the dependency layer caches across code edits.
COPY go.mod go.sum ./
RUN go mod download

# The whole command tree. cmd/stewards-cli/internal/* is pulled in with it.
COPY cmd/ ./cmd/

ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64

RUN go build -trimpath -ldflags="-s -w" -o /out/stewards-mcp  ./cmd/stewards-mcp  \
 && go build -trimpath -ldflags="-s -w" -o /out/fs-read-mcp   ./cmd/fs-read-mcp   \
 && go build -trimpath -ldflags="-s -w" -o /out/stewards-cli  ./cmd/stewards-cli  \
 && go build -trimpath -ldflags="-s -w" -o /out/coder-mcp     ./cmd/coder-mcp

# ---------------------------------------------------------------------
# Stage 2 — runtime. Slim alpine + the substrate binaries.
# ---------------------------------------------------------------------
FROM alpine:3.20

# ca-certificates: HTTPS to model providers + remote MCP servers (e.g. Exa).
# tzdata: sane timestamps in logs and scheduled-pipeline cron math.
# docker-cli + git + github-cli: coder-mcp's sandbox-manager shells `docker`
# against the host daemon (socket mounted by compose) to spawn coder-runtime
# sandboxes, and runs clone/commit/push/gh-pr BRIDGE-SIDE (the GitHub token
# lives here, never inside a sandbox). Omit the coder mcp_server row (or skip
# building coder-runtime) if you don't want the coding capability.
RUN apk add --no-cache ca-certificates tzdata git github-cli docker-cli

COPY --from=builder /out/stewards-mcp  /usr/local/bin/stewards-mcp
COPY --from=builder /out/fs-read-mcp   /usr/local/bin/fs-read-mcp
COPY --from=builder /out/stewards-cli  /usr/local/bin/stewards-cli
COPY --from=builder /out/coder-mcp     /usr/local/bin/coder-mcp

# Default DSN points at the compose service name `pg`; compose overrides it.
ENV STEWARDS_DSN="postgres://stewards:stewards@pg:5432/stewards?sslmode=disable"

COPY extension/bridge-entrypoint.sh /usr/local/bin/bridge-entrypoint.sh
RUN chmod +x /usr/local/bin/bridge-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/bridge-entrypoint.sh"]
