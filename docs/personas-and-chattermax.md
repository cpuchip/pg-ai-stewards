# Personas, and linking them to ai-chattermax

A **persona** is a durable mind that sits in a live chat room — answering in
character, remembering across turns, reacting in the moment, and (when you let
it) using tools. The substrate ships the machinery to run one; pairing it with
[ai-chattermax](https://github.com/cpuchip/ai-chattermax) puts it in a real
room with humans on day one. This is the `core + persona-host` half of v0.1.

## Two halves

A persona is split across two processes that each do what they're good at:

- **The persona-host** (`cmd/persona-host`, the `personas` compose profile) is
  the sidecar. It connects to the chat platform *as* one or more personas, holds
  the room connections, runs the turn loop, and manages persona identities in
  its own tables (`personas`, `persona_rooms`, `signing_key`, `token_issuance`).
- **The substrate** is the cognition. It ships a generic `persona` agent and a
  one-stage `persona-turn` pipeline; the host dispatches a turn through it and
  gets back what the persona should say.

The seam between them is the **binding question**: the host injects *who the
persona is* (character brief + room + recent conversation + the latest message)
as the turn's input, so one generic pipeline serves every persona. The
character lives in data, not in a forked pipeline.

## How a turn works

1. A message lands in a room the persona is in. The host decides whether to take
   a turn (it isn't obligated — see SILENCE below).
2. **Turn zero** spawns a `persona-turn` subagent (a child work-item), injecting
   the character brief as the binding question. **Each later turn re-asks the
   same session**, so the persona accumulates the conversation as its own
   history rather than restarting cold.
3. The `persona` agent replies in character — usually one to three sentences,
   the way a person types in chat — or replies with the single token `SILENCE`
   when nothing is called for from it. A good chat participant stays quiet most
   of the time.
4. The reply posts to the room under the persona's name.

The agent is **tools-off by default**: the generic `persona` family has a `*`
deny on tools (it only talks), with two deliberate exceptions granted back —
`room_say` and `room_react` (below). Read
[`extension/17-personas.sql`](../extension/17-personas.sql) for the agent
prompt, the pipeline, and the grant logic.

### Living in the moment: room_say and room_react

A persona shouldn't go silent for ten seconds and then dump a wall of text. Two
tools let it act *mid-turn*, the way Claude Code emits text between tool calls:

- **`room_say(body, mood, as_character)`** posts a message to the room right
  now, before the turn finishes — "🤔 hang on, let me check…", then a tool call,
  then "found it." `mood` is a single emoji for the character's current state;
  `as_character` lets one persona voice a named NPC (a shopkeep, a villain), and
  the room attributes that line to the named character.
- **`room_react(emoji)`** drops a single emoji reaction on the message the
  persona is answering — 🎲 on a clutch roll, 😂 at a good line. A reaction is
  not a message: a persona can react and *still* reply `SILENCE`.

Both write to `stewards.persona_outbox`; the host drains unposted rows, matches
each to the right channel, and posts it.

## Backing a persona with any model

The default `persona-turn` runs on `kimi-k2.6`. Because the persona is just a
binding question over a generic pipeline, swapping the model is a one-line
change — and the repo ships two example pipelines that do exactly that:

| Pipeline | Model | Use |
|----------|-------|-----|
| `persona-turn` | `kimi-k2.6` (opencode go) | the default creative voice |
| `persona-turn-lmstudio` | `qwen/qwen3.6-27b` (LM Studio) | a fully local, self-hosted persona |
| `persona-turn-gemini` | `gemini-3.5-flash` (Google) | a persona on a hosted API |

One note carried from production: give a reasoning model a generous
`max_tokens` (the examples use 16000). A reasoning model bills its thinking
against that budget, and too low a cap cuts the persona off mid-thought before
it writes a single word of reply.

## Linking to ai-chattermax

Bring up the sidecar with the `personas` profile and point it at your chat
platform in `.env`:

```bash
docker compose --profile personas up -d
```

```bash
# .env — the ai-chattermax platform path
CHATTERMAX_GATEWAY=wss://your-chattermax-host/gateway
# localSlug=key@roomId, comma-separated. The key is the persona's secret,
# issued by ai-chattermax; the roomId is the room you want it to join.
CHATTERMAX_PERSONAS=librarian=PERSONA_KEY@room-abc123,dm=DM_KEY@room-def456
```

Without `CHATTERMAX_GATEWAY` the sidecar still starts — it serves its HTTP API
and idles, no rooms joined. Each entry in `CHATTERMAX_PERSONAS` dials the
gateway as one persona: `localSlug` is the substrate-side name, `key` is the
per-persona secret you create in ai-chattermax, and `roomId` is the room it
joins. (There's also a simpler direct path for a self-hosted WebSocket setup:
`CHATTERMAX_WS_BASE` + `PERSONA_AUTOJOIN="slug@room,slug@room"`. The gateway
path is the one ai-chattermax uses.)

See the [ai-chattermax](https://github.com/cpuchip/ai-chattermax) repo for
standing up the chat platform itself and creating the persona keys.

## A tool-using persona — the D&D holodeck

The fullest worked example is the table that runs Dungeons & Dragons in chat: a
Dungeon Master persona that rolls real dice and tracks HP through
[dnd-tools](https://github.com/cpuchip/dnd-tools), with humans at the same
table. It composes the two integrations:

1. **Register dnd-tools** as a remote MCP server and grant its tools to the DM
   persona's family — exactly the recipe in
   [`docs/wiring-up-mcp-servers.md`](wiring-up-mcp-servers.md) (example D).
   Granting a tool overrides the persona's `*` deny for that one tool.
2. **Run the DM persona** through the persona-host against your chat room.

Because both the human's `/hp -3` in the chat UI and the DM persona reading that
HP back hit the *same* dnd-tools instance, the game state stays unified across
human and AI players. A persona that *uses* tools is just a persona whose family
has tool grants beyond `room_say`/`room_react` — the generic machinery is the
same; the grants make it specialized.

## Memory: scoping notes to a persona or a room

Personas can keep durable notes with `remember(note, audience)` and drop them
with `forget(handle)`. The `audience` is faceted: a note scoped `{persona: …}`
follows that persona across every room it's in, while `{room: …}` is shared by
everyone in one location. The host records the active `(persona, room)` for each
session (`set_session_facets`), and a note renders into the prompt only when the
current dispatch's facets match its audience. So a persona can remember a
returning player's name everywhere, or a house rule only at one table.

## What's core vs. yours

The core ships the **generic machinery**: the `persona` agent, the three
`persona-turn*` pipelines, `room_say`/`room_react`, and the facet-scoped memory.
The **named personalities** — their character briefs, custom tool grants, room
assignments — are operator data. Define them in your overlay and your `.env`,
the same way every other piece of "behavior is data" in this substrate is
yours to shape.
