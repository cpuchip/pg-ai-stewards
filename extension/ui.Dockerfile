# =====================================================================
# ui.Dockerfile — the pg-ai-stewards local web UI.
#
# stewards-ui is a single Go binary that serves both the Vue SPA
# (embedded from cmd/stewards-ui/frontend/dist via embed.FS) and the
# JSON API at /api/* on one port. It is read-mostly substrate
# observability + a few write islands (create work / ratify / trust /
# councils). pgxpool connects with STEWARDS_DSN; bind 127.0.0.1 on the
# host for local-only access.
#
# Build context = the repository ROOT (where go.mod + cmd/ live), NOT
# this directory. docker-compose.yaml sets `context: .` and
# `dockerfile: extension/ui.Dockerfile`.
#
# Single Go module: github.com/cpuchip/pg-ai-stewards. cmd/stewards-ui is
# part of it — no go.work, no sibling-module stubs (the clean-room
# extraction, unlike the workspace original which stubbed ~30 siblings).
#
# Three stages:
#   1. node:lts-alpine   — npm ci + vite build -> frontend/dist
#   2. golang:1.26-alpine — go build with the dist embedded
#   3. alpine:3.20        — slim runtime, ca-certificates, one binary
# =====================================================================

# ---------------------------------------------------------------------
# Stage 1 — frontend builder. node + npm + vite + tsc.
# ---------------------------------------------------------------------
FROM node:lts-alpine AS frontend

WORKDIR /frontend

# Manifests first for layer caching.
COPY cmd/stewards-ui/frontend/package.json cmd/stewards-ui/frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund

# Source, then build.
COPY cmd/stewards-ui/frontend/ ./
RUN npm run build

# ---------------------------------------------------------------------
# Stage 2 — Go builder. Embeds the built dist into a static binary.
# ---------------------------------------------------------------------
FROM golang:1.26-alpine AS gobuilder

RUN apk add --no-cache ca-certificates
WORKDIR /src

# Module manifests first so the dependency layer caches across code edits.
COPY go.mod go.sum ./
RUN go mod download

# The command tree (includes the committed stub dist, overwritten below).
COPY cmd/ ./cmd/

# Replace the stub dist with the freshly-built SPA from stage 1.
COPY --from=frontend /frontend/dist ./cmd/stewards-ui/frontend/dist

ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build -trimpath -ldflags="-s -w" -o /out/stewards-ui ./cmd/stewards-ui

# ---------------------------------------------------------------------
# Stage 3 — runtime. Slim alpine + ca-certificates.
# ---------------------------------------------------------------------
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata

COPY --from=gobuilder /out/stewards-ui /usr/local/bin/stewards-ui

# Default DSN points at the compose service name `pg`; compose overrides it.
ENV STEWARDS_DSN="postgres://stewards:stewards@pg:5432/stewards?sslmode=disable"

# Bind 0.0.0.0 inside the container; compose maps it to 127.0.0.1 on the
# host for local-only access.
ENTRYPOINT ["/usr/local/bin/stewards-ui", "--addr", "0.0.0.0:8080"]
EXPOSE 8080
