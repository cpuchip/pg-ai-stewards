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
#   - fetch-md-mcp  (fetch a URL -> readable markdown; fetch_url / fetch_urls)
#   - git-mcp       (general git ops, distinct from coder's sandbox-scoped git)
#   - yt-mcp        (YouTube transcript + playlist tools via yt-dlp — OPT-IN,
#                    built only with --build-arg WITH_YT=1, which also installs
#                    a python3 + yt-dlp runtime. See docker-compose.yt.yaml and
#                    examples/playlist-digester.sql. Omitted from the default
#                    image so the generic core stays lean + python-free.)
# Web search needs an operator API key, so it is "bring your own" (register a
# web_search_exa server in an overlay — see the docs). Domain MCP servers
# (your own docs / data tools) are likewise BYO.
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

# Opt-in: the YouTube tool (yt-mcp) is compiled only when WITH_YT=1, so the
# default image ships no YouTube surface. docker-compose.yt.yaml flips it on.
ARG WITH_YT=0

RUN go build -trimpath -ldflags="-s -w" -o /out/stewards-mcp  ./cmd/stewards-mcp  \
 && go build -trimpath -ldflags="-s -w" -o /out/fs-read-mcp   ./cmd/fs-read-mcp   \
 && go build -trimpath -ldflags="-s -w" -o /out/stewards-cli  ./cmd/stewards-cli  \
 && go build -trimpath -ldflags="-s -w" -o /out/coder-mcp     ./cmd/coder-mcp     \
 && go build -trimpath -ldflags="-s -w" -o /out/fetch-md-mcp  ./cmd/fetch-md-mcp  \
 && go build -trimpath -ldflags="-s -w" -o /out/git-mcp       ./cmd/git-mcp       \
 && if [ "$WITH_YT" = "1" ]; then \
        go build -trimpath -ldflags="-s -w" -o /out/yt-mcp ./cmd/yt-mcp ; \
    fi

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
# fetch-md-mcp's JS-rendering path (the `js:true` tool param) needs a
# `chromium` binary on PATH; the default static fetch does NOT. We omit
# chromium to keep the image lean — static fetch works, js:true degrades with
# a clear error. Add `chromium` to this apk line if you want JS-rendered pages.
# Opt-in YouTube runtime: yt-mcp shells `yt-dlp`, which needs python3. Installed
# only when WITH_YT=1 (pip pulls the LATEST yt-dlp — the alpine package lags and
# breaks on YouTube changes). No ffmpeg: we fetch subtitles, never media.
ARG WITH_YT=0

RUN apk add --no-cache ca-certificates tzdata git github-cli docker-cli \
 && if [ "$WITH_YT" = "1" ]; then \
        apk add --no-cache python3 py3-pip \
        && pip install --break-system-packages --no-cache-dir -U yt-dlp ; \
    fi

# Copy the whole build output so the optional yt-mcp binary comes along when it
# was built (WITH_YT=1) and is simply absent otherwise.
COPY --from=builder /out/ /usr/local/bin/

# Default DSN points at the compose service name `pg`; compose overrides it.
ENV STEWARDS_DSN="postgres://stewards:stewards@pg:5432/stewards?sslmode=disable"

COPY extension/bridge-entrypoint.sh /usr/local/bin/bridge-entrypoint.sh
RUN chmod +x /usr/local/bin/bridge-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/bridge-entrypoint.sh"]
