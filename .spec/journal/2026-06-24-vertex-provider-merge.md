# 2026-06-24 — merged PR #1: native Google Vertex service-account auth

Michael opened a PR from the work side adding a `google_sa` provider auth mode
and asked me to review + merge if good. He can't test Vertex creds on the dev
box (they work on the work machine), and flagged that the PR's carry-forward
"may align with the alias-failover part" (#243). It does — exactly.

## What it adds

A `google_sa` auth mode so the substrate reaches **Vertex's OpenAI-compat
endpoint directly** with a refreshing service-account OAuth token — no external
proxy. This matters because a Vertex SA is a rotating OAuth token, not a static
api_key, and Vertex is **no-train** (unlike the AI-Studio key, which trains). So
this is the work-confidential Gemini path the work machine needs (it won't run
qwen). And because it's a native OpenAI-compat path, the bgworker's existing
Gemini tool-loop fixes (finish_reason / streaming index / thought_signature)
apply — Gemini drives the agentic loop with no shim.

- `gcp_sa.rs` (new) — RS256 self-signed JWT → `jwt-bearer` grant → scoped access
  token, cached per provider, refreshed 5min before expiry. Synchronous (fits
  the blocking bgworker). Key/JWT/token never logged; errors carry only the
  failing step + the credentials *path*; token-endpoint error body capped.
- `providers.rs` — `AuthMode { ApiKey | GoogleSa{credentials_file} }`, parsed
  from `STEWARDS_PROVIDER_<NAME>_{AUTH,CREDENTIALS_FILE}`; `bearer_token()`
  unifies static-key and minted-SA; `auth_label()` for the startup log.
- `bgworker.rs` — chat + embed dispatch go through `bearer_token()`; Anthropic
  still uses x-api-key; startup log gains `auth=`.
- deps/config — `jsonwebtoken`; `.env.example` documents GOOGLE_VERTEX; opt-in
  `docker-compose.gemini-vertex.yaml` mounts the SA key read-only into pg.

Backward compatible: no `AUTH` → `ApiKey` (every existing provider unchanged).

## Review + verification

LGTM on read — careful secret hygiene, clean integration, no SQL-chain changes.
What I could verify here (no Vertex creds):
- **Compile oracle:** pg image builds with the new `jsonwebtoken` dep + the
  `gcp_sa` module + the bgworker/providers changes (exit 0).
- **virgin-smoke 00→52 green** (the PR adds no chain SQL, so OK 42 et al. hold).
- **Live boot:** recreated the dev pg from the merged image — the new `auth=`
  label renders on all existing providers as `auth=api_key` (backward compat
  confirmed live); the 52 inject-session trigger persisted across the recreate.

What only the work machine can verify: the live Vertex auth path. Michael
already proved it there — `doc-build` with `reason`→`google_vertex`,
gemini-3.5-flash drove ~17 tool turns to a real downloadable PDF, no proxy, with
`extra_content`/thought_signature round-tripping.

Merge was clean against my Round-4 commits (lib.rs auto-merged: `mod gcp_sa;` at
the top + the `52` chain entry at the bottom, no conflict). Merged as `60c1300`,
pushed to main, PR #1 MERGED.

## The carry-forward = #243, sharpened

The PR's TODO names the real shape of the alias-failover gap: the substrate
resolves a stage's model **once**, so failover happens at resolution time, not
mid-loop — a single transient **429/503 on tool turn N fails the whole stage**.
Surfaced by a Vertex preview model (gemini-3.1-pro) `429 Resource exhausted`
partway through a multi-turn doc-build; a higher-RPM model (3.5-flash) absorbs
it. The robust fix is **backoff + retry, and/or a breaker that re-resolves the
alias to a fallback member, INSIDE the bgworker tool loop** — a hot-path change,
its own careful pass. #243 re-specced to match.

## Note

A pre-existing `lib.rs` unused-import warning (`Provider`/`ProviderRegistry`/
`ProviderSummary`) is not from this PR — worth a separate cleanup.
