# pg-ai-stewards

[![CI](https://github.com/cpuchip/pg-ai-stewards/actions/workflows/ci.yml/badge.svg)](https://github.com/cpuchip/pg-ai-stewards/actions/workflows/ci.yml)

**Stewdio — a studio for your worlds.** An open knowledge engine that gathers,
builds, and remembers, running entirely inside a Postgres you already know how to
back up.

A **world** is anything with a corpus you want to understand and grow — and it can
be real or invented:

- a **knowledge base** you're building from customer research, a market, a domain
- a **topic** you're learning, and relating to everything you already know
- a **book**, a paper trail, a pile of digested talks and videos
- a **D&D campaign**, a fiction setting, a universe with its own canon and cast

Every world runs the same machinery: **gather → digest → fact-find → relate →
present → engage.** Point it at customer interviews and it builds you a dossier;
point it at a campaign and it keeps the canon and voices the characters. The
report-builder and the dungeon master are the same governed pipeline aimed at
different canon — so the serious tool and the fun one are one tool.

## Why it's different

Most "chat with your knowledge" tools bolt a vector store, a job queue, a file
store, and a chat cache together and hope they agree. Here, the agent's whole
brain **is** one Postgres:

- **One brain, one `SELECT`.** Vector + relational + graph in the same query; one
  backup, one point-in-time recovery, one replication target. Your agent's entire
  memory recovers to a moment in time and is queryable with SQL you already know.
- **Every action is a row.** Provenance, version history, and cost fall out of the
  schema instead of being features. Click any sentence → the corpus row it came
  from. Click any artifact → its full edit history. Click any cost → the exact
  model call.
- **Governance as queryable state.** Intent (a standing goal), covenant (the rules
  of engagement), a trust ladder (earned autonomy), and spend caps that *refuse
  before they spend* are first-class rows — not guardrails taped on the side. The
  human stays the Hinge: agents propose, verify, and account; merge, deploy, and
  spend authority stay human.
- **Local-first.** Bring your own models — local GPUs, a federation across your own
  machines, or a hosted provider. Your data never has to leave.
- **Behavior is data.** Agents, pipelines, tool grants, covenant, and intent are
  rows and YAML. You extend it with an overlay of migrations and your own MCP
  servers — not a fork.

## What it does

One engine, the full arc:

- **Research** — multi-source gather → synthesize → review pipelines, web + corpus
  retrieval wrapped as untrusted data, fan-out across many sources, and an
  autonomous reflect-steward that researches an intent on a schedule and *proposes*
  work (you approve).
- **Present** — `doc-build` writes a generator in a sandbox and exports a real,
  downloadable PDF / Office doc / deck; generated images; reports and dossiers from
  a corpus.
- **Build** — a hardened coder sandbox that writes, tests, and lands a draft PR
  against a real repo, with the merge as the human Hinge.
- **Deep lore** — durable personas with facet-scoped memory that voice a world's
  cast (the D&D holodeck is the worked example), over a typed knowledge graph with
  associative multi-hop recall.
- **Self-learning** — failure→lesson capture, a reflective tuning loop that scores
  its own output against an oracle and proposes a better rule, and a knowledge pool
  that compounds as every verified finding flows back in. Self-improvement you can
  *read* — every change is a proposal a human approves, persisted as rows, not
  opaque weights.

## Start here: Stewdio

**Stewdio** (`/stewdio`) is the cockpit — a dark, three-pane studio: browse a
world's sources on the left, read and build artifacts in the center, chat grounded
in the corpus on the right. Drag in a PDF, Office doc, or zipped folder and it
becomes safe, searchable subject material. Ask for a document and watch a pipeline
walk plan → build → deliver in the conversation. Everyday surface stays clean; the
power and ops depth tuck behind a developer view.

Read [**Anatomy of a Turn**](docs/anatomy-of-a-turn.md) for exactly what happens
between a message arriving and a model answering — everything in the substrate is
built out of turns.

## Your models, your keys

Run it on whatever you want — a free tier to start, a paid provider, or your own
local GPUs (a single box, or a federation across your machines). You add a provider
key, list the models you want, and the engine probes each one, prices it, and routes
by **role**: a cheap model for ingestion, a strong one for reasoning, a vision model
for images — with free-first fallback when a call fails or a provider rate-limits.
Nothing leaves your machine unless you send it to a hosted provider, and a no-train
path keeps confidential corpora out of training.
[**Wiring up models**](docs/wiring-up-models.md) takes you from nothing to a working
model. (Making key + model setup a first-class in-app step — instead of editing env —
is on the near roadmap.)

## Status

Early but real. It has run real workloads daily inside a private workspace —
research councils, a coding pipeline that lands PRs, chat personas with durable
minds, an autonomous research loop, and a full D&D holodeck — and this repo is the
public, generalized substrate. The interfaces still move; the engine is solid. One
`docker compose up` boots it on a clean machine.

## Documentation

| Guide | What it gets you |
|-------|------------------|
| [Anatomy of a Turn](docs/anatomy-of-a-turn.md) | The turn pipeline end to end — read this first. |
| [Rich chat + artifacts](docs/rich-chat-and-artifacts.md) | Stewdio's doc-build, brainstorm, chat-across-a-whole-world, remote MCP — **plus the full fresh-rig bring-up runbook** (images, provider, overlays, verify). |
| [Wiring up models](docs/wiring-up-models.md) | From fresh install to "agents can call a model" — free → paid → local, with a no-train Vertex path. |
| [Wiring up MCP servers](docs/wiring-up-mcp-servers.md) | Give agents tools — stdio + remote-HTTP MCP, deny-by-default grants, worked examples. |
| [Personas + ai-chattermax](docs/personas-and-chattermax.md) | Put a durable-mind persona in a live room; the D&D holodeck as a tool-using example. |
| [Rich documents in chat](docs/rich-documents.md) | Attach a PDF / Office doc / zipped folder and reason over it — the hardened no-network doc-extract sandbox. |

Copy-paste starters (model catalog, content digesters) live in
[`examples/`](examples/).

## License

[Apache-2.0](LICENSE). Use it, deploy it, build on it — someone will live better
for it. The patent clause cuts both ways on purpose: contributors grant users a
patent license for their contributions, and suing the project over patents
terminates yours.
