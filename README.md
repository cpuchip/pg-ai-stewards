# pg-ai-stewards

[![CI](https://github.com/cpuchip/pg-ai-stewards/actions/workflows/ci.yml/badge.svg)](https://github.com/cpuchip/pg-ai-stewards/actions/workflows/ci.yml)

**An agentic substrate that lives in Postgres** — work items, pipelines,
multi-model councils, cost accounting, and persistent memory for AI agents,
with **covenant, intent, and stewardship as first-class state** rather than
prompt garnish. The human stays the Hinge: agents propose, verify, and
account; merge, deploy, and spend authority stay human.

Born inside a private workspace where it has been running real workloads —
research councils, a sandboxed coding pipeline that lands PRs, chat personas
with durable minds, and one fully-operational D&D holodeck. This repo is the
public, generalized extraction of that substrate.

## Status: pre-release (extraction in progress)

The extraction plan — what ships, in what order, and why — lives at
[`.spec/proposals/extraction-plan.md`](.spec/proposals/extraction-plan.md).
The short version:

- **v0.1**: the core (Postgres extension + MCP bridge + CLI + verify suite)
  **plus persona-host**, pairing with
  [ai-chattermax](https://github.com/cpuchip/ai-chattermax) so personas can
  sit in a room on day one. One `docker compose up`, boots on a virgin
  machine, seeded with generic covenant/intent templates and example agents.
- **Behavior is data**: agents, pipelines, tool grants, covenant, and intent
  are rows and YAML. Extending the substrate means an overlay directory of
  migrations and your own MCP servers — not a fork.
- First doc, landed: [**"Anatomy of a Turn"**](docs/anatomy-of-a-turn.md) —
  exactly what happens between a message arriving and a model answering
  (system-prompt composition, context engine, tool routing, auto-fire
  verification). Start there; everything else in the substrate is built
  out of turns.

## License

[Apache-2.0](LICENSE). Use it, deploy it, build on it — someone will live
better for it. The patent clause cuts both ways on purpose: contributors
grant users a patent license for their contributions, and suing the project
over patents terminates yours.
