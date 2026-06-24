# =====================================================================
# doc-extract — the hardened document CONVERTER image (rich-docs P3a).
#
# A lean image whose ENTRYPOINT is the deterministic `doc-extract` Go binary
# (cmd/doc-extract): read untrusted bytes on stdin -> scan + extract text
# (tabula, pure Go, full office) + render page pixels (poppler) -> emit a JSON
# Result on stdout. doc-extract-mcp spawns this with the untrusted-input
# hardening (proposal §4): --network=none --read-only --tmpfs --cap-drop=ALL
# --ulimit nofile, plus the ClamAV signature DB mounted read-only at /clamav.
#
# What's in the image (and why it stays lean):
#   - the doc-extract Go binary (tabula + readability + html-to-markdown +
#     mholt/archives all linked in — pure Go, full office + archives)
#   - poppler-utils  -> pdftoppm (PDF -> pixels, the overlay path)
#   - clamav         -> clamscan (the signature half of the scan layer); the
#                       ~300MB signature DB is NOT baked in — it rides the
#                       read-only clamav-db volume the freshclam sidecar keeps
#                       fresh (docker-compose.doc-extract.yaml), so the image
#                       stays small and the scan stays air-gapped at run time.
#   NO Python (the structural maldoc check is pure Go), NO libreoffice (faithful
#   office->pixels is a later tier), NO markitdown.
#
# Build context = the repository ROOT (go.mod + cmd/ + internal/ live there):
#   docker build -f extension/doc-extract.Dockerfile -t doc-extract:latest .
# =====================================================================

# ---------------------------------------------------------------------
# Stage 1 — builder. One module, one binary (CGO off -> static).
# ---------------------------------------------------------------------
FROM golang:1.26-bookworm AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

# The converter + its extraction library.
COPY cmd/doc-extract ./cmd/doc-extract
COPY internal/docextract ./internal/docextract

ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build -trimpath -ldflags="-s -w" -o /out/doc-extract ./cmd/doc-extract

# ---------------------------------------------------------------------
# Stage 2 — runtime. debian-slim + poppler + clamav engine + the binary.
# ---------------------------------------------------------------------
FROM debian:bookworm-slim

# clamav  -> clamscan (signature engine; DB arrives via the mounted volume)
# poppler-utils -> pdftoppm (PDF -> page PNGs)
# ca-certificates -> harmless; tini -> clean PID 1 for the one-shot run
RUN apt-get update && apt-get install -y --no-install-recommends \
        clamav poppler-utils ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/doc-extract /usr/local/bin/doc-extract

# Non-root. The container runs --read-only with tmpfs /work + /tmp; this user
# owns nothing on the read-only rootfs and writes only to the tmpfs scratch.
RUN useradd -m -u 1000 -s /usr/sbin/nologin extractor
USER 1000:1000
WORKDIR /work

# The converter reads stdin, writes stdout. tini reaps any child (pdftoppm).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/doc-extract"]
