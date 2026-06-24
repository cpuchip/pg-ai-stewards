# Rich documents in chat — injectable subject material + multimodal

**Status:** ✅ RATIFIED in council with Michael, 2026-06-23 (`dominion_in_council` satisfied — he agreed 100% and added the UI rich-media-rendering requirement). Execution-ready.
**Author:** agent + Michael, 2026-06-23.
**One line:** Attach rich media (images, PDFs, office docs, text) to a Stewdio chat — empty OR grounded in a work item — as **injectable subject material**; the chat reasons over the combination (work item + media + a referenced corpus/project as a lens), renders the media inline, and can `start_task` to spawn new work from the whole.

**Builds on:** Stewdio P1 (chat-with-a-work-item, `45`), `start_task` (Delegate, `46`), `book_chunks`/`book_search` (P3 corpus pattern), the role-alias router (`31/32`), project-scoped `doc_search`.

---

## 1. The reframe — a chat holds multiple subjects

Today "chat with a work item" grounds the chat in one work_item's facets. Generalize it: a chat session can hold **several pieces of subject material at once** — its (optional) grounding work_item, any attached media, and a referenced corpus/project as a *lens*. The agent reasons over the combination; `start_task` spawns work from it. Three shapes, one model:

- empty chat + media + corpus lens → *"what does our AI-news corpus say about this chapter?"*
- work-item chat + media → *"the work item **and** this flyer — chat about both"*
- either + `start_task` → *"spawn work based on **both**"*

## 2. De-risk findings (the build rests on these — verified 2026-06-23)

- **The :8090 router already forwards multimodal content untouched** — `proxyByModel` buffers the raw body, parses only `{model}`, reverse-proxies the original bytes (256 MB cap fits base64 images); the federation / `?node=` paths use the same passthrough. **No router work.**
- **The rig models are vision-capable** (gemma-4 family + qwen3.6-35b = vision/tool/reasoning), and the **mmproj projectors are on disk, co-located** with the GGUFs (`gemma-4-26B-A4B-it/mmproj-…`, etc.); llama-chip's `Discover()` already *skips* them. The only gap: `rig.args()` never emits `--mmproj`.
- **The substrate assumes string content** — `messages.content` is `text`; `compose_messages` / `page_in_cap` do string ops on it. **But the OpenAI bgworker dispatch path forwards message arrays verbatim** (the bright spot). So a parallel `content_parts jsonb` column + a `compose_messages` passthrough for those rows is the load-bearing change.
- **Vertex / Gemini paid = private-safe** (not trained on) → cloud vision is viable for private subjects too; local-vs-cloud is a *preference*, not a hard wall. The `file_private` guard still routes private turns local by default.

## 3. Ratified decisions

1. **Phasing P0→P4** (§5) — de-risk vision + the substrate carry first; MVP at P2.
2. **Vision default = local** (gemma-4-26b-a4b + mmproj, $0 / private); Vertex/Gemini the stronger opt-in. A new **`vision` role alias**, auto-selected when media is attached.
3. **Long-doc handling = hybrid** — short / visual docs (a flyer, a chapter, a few pages) feed as **images to the vision model** (layout preserved); long text (a whole book) gets **extracted + chunked** (avoids per-page vision cost).
4. **Image storage = in-DB `bytea`** (durable with the session, carries into spawned work, simplest) — revisit if bloat bites.
5. **Content surface = a new `content_parts jsonb` column** (text rows + all the string-assuming code untouched), not retyping `content`.
6. **UI renders rich media inline** (Michael's add) — attached images show in the chat stream; docs show a file chip / preview. Not just sent to the model — visible in the conversation.

## 4. Architecture — the pieces (mostly assembly)

- **llama-chip:** `--mmproj` launch support (config `mmproj` field + `FindMMProj` auto-detect of the co-located projector + one `args()` line) + a `supports_vision` flag on discovered models. [P0]
- **Substrate:** `content_parts jsonb` on `messages` + `compose_messages` passthrough for array rows + a `vision` role alias + a `supports_vision` capability bit on `model_capability`. [P1]
- **Attachments:** a `chat_attachments` table (session-scoped, durable, `bytea` + extracted text + chunks) + an upload API + extraction (image = an `image_url` part; pdf/office = text-or-render-to-image per the hybrid). [P2/P3]
- **UI:** an attach control + **inline media rendering** + empty-chat mode + a corpus/project lens picker. [P2/P3]
- **Spawn:** `start_task` carries attachment(s) + work_item into the spawned pipeline's input. [P4]

## 5. Phases

- **P0 — local vision serves.** llama-chip `--mmproj` (config field + auto-detect + one `args()` line + a `supports_vision` flag) → boot gemma-4-26b-a4b (or qwen3.6-35b) with vision; verify a raw image round-trip on :8090; confirm Vertex vision via the gemini provider. Proves a model can *see*. (Rig is free — autonomy down for innovation week.)
- **P1 — substrate carries an image** *(the hard slice, de-risked early)*. `content_parts jsonb` + `compose_messages` passthrough + the `vision` alias + inject an image part into a chat turn → vision model → grounded answer, end to end.
- **P2 — attachments in the chat (MVP).** `chat_attachments` + upload API + the chat injecting attached image(s) as subject + the UI upload control **AND inline media rendering**. Works in empty AND work-item chats. First real win.
- **P3 — documents + corpus-as-lens.** PDF/office handling (extract or render-to-image) + chunk+index as searchable subject + the empty-chat corpus/project picker. The cross-reference (*"AI-news vs this chapter"*, *"the work-corpus pool vs this flyer"*).
- **P4 — spawn from the combination.** `start_task` carries the media + work_item into the spawned pipeline (*"critique this flyer against our work-corpus findings"* → a work_item runs on both).

## 6. Privacy keystone + tensions

- **The privacy wall is the keystone.** A `file_private` chat's media MUST route local — the `vision` alias honors `file_private` (the same guard the substrate already uses for intent-private routing). Public subjects can use Vertex. The one rule we cannot get wrong.
- **Cost / latency:** vision payloads are big and the chat compose is already ~7–11s; images make turns heavier. The hybrid (P3) keeps long docs off per-page vision.
- **Security:** uploaded files are untrusted, and PDF/office parsers carry a real CVE surface → the extractor gets sandboxed (the same instinct as walling off the digester).
- **DB bloat:** `bytea` images grow the DB → an attachment retention/cleanup policy is a P3+ follow-up.

## 7. Where it lands

OSS core (generic, public): the `content_parts` column, the `vision`-alias mechanism, `chat_attachments`, the upload API + UI. Work instance (private overlay): the Vertex/Gemini key + the local `vision` alias members (the rig). Michael pulls the feature; the overlay supplies the private vision routing.
