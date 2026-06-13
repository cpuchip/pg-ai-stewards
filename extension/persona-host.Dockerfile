# =====================================================================
# persona-host.Dockerfile — the optional persona SIDECAR (cmd/persona-host).
#
# Drives "always-on" personas: reaches the substrate DB (pg:5432) for
# cognition and connects OUT to an ai-chattermax platform gateway so a
# persona with a durable mind can sit in a room. Inert until the
# CHATTERMAX_GATEWAY + CHATTERMAX_PERSONAS env are set (it still starts its
# HTTP server and idles without them).
#
# Build context = the repository ROOT. docker-compose.yaml sets
# `context: .` + `dockerfile: extension/persona-host.Dockerfile`, and runs
# this service only under the `personas` profile.
#
# Single module (github.com/cpuchip/pg-ai-stewards) — same as the bridge.
# =====================================================================

FROM golang:1.26-alpine AS builder

RUN apk add --no-cache ca-certificates
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/

ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build -trimpath -ldflags="-s -w" -o /out/persona-host ./cmd/persona-host

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY --from=builder /out/persona-host /usr/local/bin/persona-host

# STEWARDS_DSN points at the internal pg service; CHATTERMAX_GATEWAY +
# CHATTERMAX_PERSONAS (the persona key is a secret) come from the .env file.
ENV STEWARDS_DSN="postgres://stewards:stewards@pg:5432/stewards?sslmode=disable"

ENTRYPOINT ["/usr/local/bin/persona-host", "-addr", ":8090"]
