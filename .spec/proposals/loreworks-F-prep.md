# Loreworks F (walkthrough) — advance prep

> Advance-scouting for F (the walkthrough video), executed after A+E land. Plan-only — nothing installed.

## hyperframes — setup as an MCP

Read at `external_context/hyperframes/` (repo `github.com/heygen-com/hyperframes`, HeyGen, Apache-2.0, **v0.7.6**, released 2026-06-25).

### What HyperFrames actually is, and what kind of video it makes

**"Write HTML. Render video."** It is NOT markdown-to-video, NOT a script DSL, NOT a React/JSX framework (that's Remotion, which it's explicitly modeled against). A HyperFrames **composition is a plain `.html` file** whose DOM declares timing/tracks via `data-*` attributes, and whose animation is *seekable* (frame-accurate). The renderer drives **headless Chrome** (Puppeteer) to seek and screenshot each frame, then encodes with **FFmpeg**. Same input → same frames → same MP4 (deterministic; no `Date.now()`, no unseeded `Math.random()`, no render-time network fetches).

The composition contract (from `docs/quickstart.mdx` and the `hyperframes-core` skill):
- **Root element** needs `data-composition-id`, `data-width`, `data-height` (e.g. `1920`/`1080`).
- **Timed elements** ("clips") need `class="clip"` plus `data-start`, `data-duration`, `data-track-index`.
- **Animation**: a GSAP timeline created `{ paused: true }` and registered on `window.__timelines["<composition-id>"]`. GSAP is the primary adapter; Lottie / Three.js / Anime.js / CSS / WAAPI / TypeGPU plug in via the seek-by-frame adapter pattern.
- Media: `<video>`/`<audio>` clips with the same `data-*` track attributes; sub-compositions via `data-composition-src` / `data-composition-id`.

Output formats (CLI `render`): **mp4** (H.264, default), **webm** (VP9, alpha/transparent), **mov** (ProRes), **gif**, **png-sequence**. fps 24/30/60. It is built for agents: the CLI is non-interactive-capable and the framework ships agent **skills**.

### Install + run locally

Requirements (from `quickstart.mdx`): **Node.js 22+** and **FFmpeg** (must be on PATH). Docker optional (for byte-identical renders). The CLI is published to npm as `hyperframes` and runs via `npx` — no clone needed.

```bash
# scaffold a project (interactive wizard)
npx hyperframes init my-video
cd my-video
# non-interactive (CI/agent): pick an example, skip prompts
npx hyperframes init my-video --non-interactive --example blank

npx hyperframes preview                 # Studio + hot-reload in browser (default port 3002)
npx hyperframes lint                    # static HTML-structure check
npx hyperframes validate                # runtime check in headless Chrome (JS errors, missing assets)
npx hyperframes render --output out.mp4 # render to MP4
```

Key `render` flags verified in `skills/hyperframes-cli/references/preview-render.md` and `packages/cli/src/commands/render.ts`:
- `--composition, -c <file>` (default `index.html`; render a specific sub-comp)
- `--output, -o <path>` (default is **timestamped** `renders/<project>_<date>_<time>.<ext>` — pass `-o` for a stable name)
- `--fps 24|30|60` · `--quality draft|standard|high` (use `high` for final delivery) · `--format mp4|webm|mov|gif|png-sequence`
- `--resolution landscape|portrait|landscape-4k|...` (supersample via Chrome deviceScaleFactor) · `--docker` (reproducible) · `--workers <n|auto>` · `--gpu` (NVENC etc.) · `--browser-timeout <s>` (raise above 60 for heavy comps with many videos/fonts) · `--variables '{...}'` / `--variables-file` (parametrized renders)

Other useful commands: `play` (lightweight player, port 3003), `publish` (uploads, returns a public preview URL), `doctor`, `add` (install catalog blocks), `transcribe`/`tts`/`remove-background` (asset preprocessing), `capture` (website→assets), `batchRender`.

**Repo-dev note (only if you clone the monorepo, not needed to *use* it):** package manager is **bun** (not pnpm/npm for workspace ops): `bun install` → `bun run build` → `bun run test`. Lint/format are **oxlint/oxfmt** (not eslint/prettier). Repo uses Git LFS (~240 MB of golden `.mp4` baselines); `GIT_LFS_SKIP_SMUDGE=1 git clone ...` to skip.

### Running it AS AN MCP SERVER for Claude Code — the important caveat

**HyperFrames does NOT ship a local/stdio MCP server you can run from this repo.** Grepping the entire tree (`mcp|modelcontextprotocol|mcpServers`) — there is no MCP entrypoint, no `bin` for an MCP server, and **no `mcpServers` key in any plugin.json**. The CLI's only `bin` is `hyperframes` → `./dist/cli.js` (in `packages/cli/package.json`).

There IS a HyperFrames MCP (documented in `docs/guides/mcp.mdx`), but it is a **hosted, cloud-only HeyGen product**, not a local server:
- URL: `https://mcp.heygen.com/mcp/hyperframes` — **remote, OAuth, requires a HeyGen account + render credits**, renders run on HeyGen infra.
- It exposes 6 tools to the model: `compose`, `list_compositions`, `get_composition`, `render_video`, `get_render_status`, `get_credits`.
- Critically: "**Text-only MCP clients (Claude Code CLI, Cursor, Windsurf) will see a clickable preview URL instead** [of the inline player widget] — full text-mode support is on the roadmap." So even the hosted MCP is degraded in Claude Code; it's built for Claude.ai web/desktop, ChatGPT, Grok.

If you *did* want the hosted MCP in a `.mcp.json` (remote, OAuth, cloud-render, costs credits), the entry would be the standard remote-MCP-via-`mcp-remote` bridge:
```json
{
  "mcpServers": {
    "hyperframes": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://mcp.heygen.com/mcp/hyperframes"]
    }
  }
}
```
(That URL and the `mcp-remote` invocation are exactly what the docs' MCP-Inspector debug line uses: `npx @modelcontextprotocol/inspector npx -y mcp-remote https://mcp.heygen.com/mcp/hyperframes`.) **No env vars** — auth is interactive OAuth to HeyGen, not a token. `.env.example` has nothing for it (its only optional var is unrelated: `GEMINI_API_KEY` for AI image-captioning during website capture).

**The correct local integration for Claude Code is SKILLS, not MCP.** This repo ships agent skills (the plugin manifests all point to `"skills": "./skills/"`, not an MCP server). Install them:
```bash
npx skills add heygen-com/hyperframes          # interactive picker (core set)
npx skills add heygen-com/hyperframes --all    # core + every workflow, no picker
npx skills add heygen-com/hyperframes --yes     # non-interactive
```
Confirmed in `packages/cli/src/commands/init.ts:804-810`: when run under Claude Code (env `CLAUDECODE` set), `init` installs skills with `--agent claude-code --yes`, landing them in **`.claude/skills/`** as slash commands. `hyperframes init` auto-installs skills unless you pass `--skip-skills`. After install, restart the Claude Code session so it loads them.

**Bottom line for wiring:** to render locally in Claude Code, you don't wire an MCP server at all — you `npx skills add heygen-com/hyperframes --all`, then drive the local `npx hyperframes` CLI. The skill `/hyperframes` is the entry point that routes "make me a video" to a workflow. (The hosted MCP is only worth it if you want zero-install cloud authoring inside Claude.ai web, with HeyGen credits — not what an innovation-week local render wants.)

### What INPUT it takes (how to feed it a ~6-min walkthrough)

The CLI consumes a **project directory** (`init` scaffolds it):
```
my-video/
  meta.json          # project metadata (name, id, date)
  index.html         # root composition = the video entry point
  compositions/      # sub-compositions, loaded via data-composition-src
    intro.html
    captions.html
  assets/            # media: .mp4, .wav/.mp3, images
```
So the raw input is **HTML compositions + an `assets/` dir of media**. You can hand it a source video at scaffold time for auto-transcription + captions: `npx hyperframes init my-video --example warm-grain --video ./intro.mp4`.

But you almost never hand-write that HTML — the **skills are the input layer**. The `/hyperframes` entry skill (`skills/hyperframes/SKILL.md`) is a router that maps your intent + input to a workflow. For a ~6-min innovation-week walkthrough, the relevant routes:
- **`/general-video`** — the right pick for a **~6-min, multi-scene narrated walkthrough**. The entry skill's own rule: "go to `/general-video` … when the piece is clearly longer than ~3 min, or is a static/loop/custom format." All the URL/PR/product workflows cap at ~3 min (sweet spot 30–90s).
- **`/website-to-video`** if the walkthrough is a tour *of* a live site/app (it screen-captures the site with headless Chrome → real screenshots + brand assets). This is the closest thing to "screen captures": the `capture` command crawls a URL into assets. There is **no screen-*recording*** capability — it captures static screenshots of web pages, not a recording of you clicking through a desktop app.
- **`/faceless-explainer`** if it's narration over LLM-invented visuals (typography/diagrams/data-viz), no site capture.
- **`/pr-to-video`** if the walkthrough is really "here's what this PR/code change does" (reads the PR via `gh` CLI).
- **`/slideshow`** if you actually want a navigable deck rather than a rendered MP4.

For narration: the `hyperframes-media` skill + CLI `tts` generates voiceover; `transcribe` (local Whisper, no API key) makes captions; `--video` at init transcribes existing footage. v0.7.6 added `.srt`/`.vtt` caption sidecar export.

**Recommended feed:** write a beat-by-beat **script** (walkthrough narration + what's on screen per scene), `npx skills add heygen-com/hyperframes --all`, restart Claude Code, then invoke `/hyperframes` with the script and let it route to `/general-video` (it'll build the compositions, wire GSAP timelines, add TTS narration + captions, lint/validate, preview, render). Drop any logos/screenshots into `assets/`.

### Gotchas (concrete, from the files)

- **The MCP is not local.** Anyone expecting a `stewards-mcp`-style stdio binary will not find one. Local = skills + CLI. Hosted MCP = cloud, OAuth, credits, and *degraded to a clickable URL inside Claude Code anyway*.
- **`render` default output is timestamped**, not `output.mp4`: `renders/<project>_<YYYY-MM-DD>_<HH-MM-SS>.<ext>`. Pass `-o` for a stable filename or successive renders won't clobber.
- **Always `lint` + `validate` before `render`.** `validate` runs the comp in headless Chrome and catches JS errors / missing assets that `lint` (static) misses. The skill convention: render only after the user has reviewed in `preview` and approved — don't auto-render.
- **Heavy comps time out at 60 s navigation.** A 6-min walkthrough with many videos/fonts/remote assets may not hit `domcontentloaded` in time — raise `--browser-timeout`.
- **Determinism rules are load-bearing**: no `Date.now()`, no unseeded `Math.random()`, no render-time network fetches, or frames diverge.
- **FFmpeg must be installed and on PATH** (Windows: `winget install ffmpeg`); it is not bundled. Node must be ≥22.
- **`--resolution` cannot combine with `--hdr`**; `--crf` and `--video-bitrate` are mutually exclusive; `--browser-gpu` can't combine with `--docker`.
- **GIF is capped at 30fps, no audio, 1-bit transparency** — use `--fps 15` for it; not a delivery format for a walkthrough.
- **Preview hand-off URL is the Studio route, not the file**: `http://localhost:<port>/#project/<project-name>` (from `preview`), whereas `play` reports a plain `http://localhost:<port>`.
- **Repo dev only**: it's **bun**, not pnpm (CLAUDE.md: "do not create pnpm-lock.yaml"), and **oxlint/oxfmt**, not eslint/prettier. Cloning the full repo pulls ~240 MB LFS baselines — use `GIT_LFS_SKIP_SMUDGE=1`.
- **Optional `GEMINI_API_KEY`** (from `.env.example`) only matters for AI image-captioning during *website capture* (~$0.001/image); not needed for general rendering.

Key files read: `README.md`, `CLAUDE.md`/`AGENTS.md`, `DESIGN.md`, `package.json`, `packages/cli/package.json`, `.env.example`, `.claude-plugin/{plugin,marketplace}.json`, `.codex-plugin/plugin.json`, `.cursor-plugin/plugin.json`, `docs/quickstart.mdx`, `docs/guides/mcp.mdx`, `skills/hyperframes/SKILL.md`, `skills/hyperframes-cli/references/preview-render.md`, `packages/cli/src/commands/{skills,init,render}.ts`, `releases/v0.7.6.md`. All under `C:\path\to\workspace\external_context\hyperframes\`.

---

## Voice clone — local plan

Narrate a ~6-min video in Michael's voice, fully local.

### Ground facts verified this session

- **Target file exists:** `books/creators-playbook/EP_87_87-soul-bleeding-dystopias/episode.mp3` — mono, **44.1 kHz**, MP3 @ 96 kbps, **~48 min** total. It carries an **embedded mjpeg cover image** (a second stream), so the ffmpeg command below must explicitly map only the audio stream or ffmpeg may try to treat the cover as video.
- **Kokoro is synthesis-only — confirmed.** Spin pulls it via `pipecat-ai[kokoro]==1.3.0` → `kokoro-onnx 0.5.0`, instantiated as `KokoroTTSService(settings=Settings(voice=TTS_VOICE))` with `SPIN_TTS_VOICE=af_heart` (`projects/spin/app/spin_bot.py:149`, `.env.example:17`). Kokoro is an 82M StyleTTS2-style model that ships a **fixed bank of preset voices** (`af_heart`, etc.) selected by name. There is no speaker-reference/enrollment input — it cannot clone. It's the wrong tool for this; we need a separate clone-capable model.
- **Hardware:** the llama-chip rig pins LLMs to `gpus:[0]` and `gpus:[1]` (two 4090s, `projects/llama-chip/config.json`). The TTS job is a separate process and only needs **one** GPU; point it at whichever 4090 the rig isn't saturating via `CUDA_VISIBLE_DEVICES`. No interaction with the substrate or the rig — it's a standalone Python venv invocation.

### (1) Survey: clone-capable TTS on Windows + CUDA, from a ~30s sample

| Model | Local setup on Win+CUDA | Quality from ~30s | License | Verdict |
|---|---|---|---|---|
| **F5-TTS** | `pip install f5-tts`; PyTorch-CUDA; downloads ckpt from HF on first run. Clean Gradio app + a one-line CLI (`f5-tts_infer-cli`). Fully offline after the model cache. | **Excellent** zero-shot from 10–30s. Flow-matching + DiT; very natural prosody, strong speaker similarity on a clean reference. Best-in-class for short-reference English narration right now. | **MIT** (code). Base checkpoint trained on Emilia — permissive for local/private use. | **PRIMARY** |
| **XTTS-v2 (Coqui)** | `pip install coqui-tts` (the maintained fork; original `TTS` is archived). Mature, batteries-included `tts` CLI + Python API, `--speaker_wav ref.wav`. Best-documented, most reproducible Windows path. | **Very good** from ~6–30s; slightly more "TTS texture" than F5 but rock-solid and predictable. 24 kHz native. | **Coqui Public Model License (CPML)** — non-commercial. Fine for private personal narration; would block any commercial use. | **FALLBACK** |
| OpenVoice v2 | Two-stage: a base TTS (MeloTTS) + a tone-color converter that paints the reference timbre on. More moving parts; MeloTTS install is fussier on Windows. | Good *timbre transfer*, but accent/prosody comes from the base voice, not the reference — less faithful to Michael's actual delivery than F5/XTTS. | MIT. | Skip — extra plumbing, weaker fidelity to delivery. |
| Fish-Speech (OpenAudio) | Strong model, but the smooth path is its own server/UI stack; CLI inference is heavier to stand up than F5. | Very good zero-shot. | Mixed (code permissive; weights CC-BY-NC-SA — non-commercial). | Skip for a one-off; more setup than payoff. |
| Chatterbox (Resemble) | `pip install chatterbox-tts`, easy install. | Good, expressive, emotion-control knob; English speaker-similarity from a short clip is a notch below F5/XTTS. | MIT. | Honorable mention; second fallback if F5 *and* XTTS both disappoint. |

**Recommendation:** **F5-TTS (primary)**, **XTTS-v2 via `coqui-tts` (fallback)**.
- F5 wins on quality-from-short-reference and has an MIT license with no commercial restriction — best fit for a private, possibly-reused voice.
- XTTS-v2 is the fallback because its Windows install is the most reproducible and its `--speaker_wav` CLI is the simplest to script; the only caveat is CPML (non-commercial), which is irrelevant for private use but worth flagging if this voice ever ships publicly.

### (2) Kokoro — confirmed synthesis-only

Already covered above. Kokoro selects from preset voices by name and has no reference-audio input. **It cannot clone.** It stays in Spin for the JARVIS front-end; it plays no role here.

### (3) Exact ffmpeg command — extract the ~35s reference sample

The episode is already mono and has a cover-art stream, so map only audio (`-map 0:a:0`), strip the cover (`-vn`), resample to 24 kHz, force a single channel, and write 16-bit PCM WAV:

```bash
ffmpeg -ss 0 -t 35 -i "books/creators-playbook/EP_87_87-soul-bleeding-dystopias/episode.mp3" \
  -map 0:a:0 -vn -ac 1 -ar 24000 -sample_fmt s16 -acodec pcm_s16le \
  "ref-michael-35s.wav"
```

Notes:
- 24 kHz is XTTS-v2's native rate and is fine for F5 (F5 resamples internally; 24 kHz is the cleanest common denominator). If you go F5-primary you can also use `-ar 24000` unchanged — no need to special-case.
- `-map 0:a:0 -vn` is what prevents the embedded mjpeg cover from derailing the extract.
- **Pick the cleanest 35s.** Offset 0 may catch an intro sting or music bed. Inspect `transcript.md` in that folder for a stretch of clean continuous Michael speech (no music, no second voice, no cross-talk) and set `-ss` to that timestamp instead of `0`. Clean reference is the single biggest quality lever for zero-shot cloning — more than model choice.
- Verify after: `ffprobe ref-michael-35s.wav` should report `pcm_s16le, 24000 Hz, mono`. Give it a listen end-to-end; trim any trailing breath/silence (a ref with leading/trailing dead air or a clipped word hurts similarity).

### (4) Run recipe

**Where it runs:** a standalone Python venv on the Windows box, **not** inside the substrate or the llama-chip rig. It borrows one of the two 4090s via `CUDA_VISIBLE_DEVICES`. A 6-minute narration is a handful of synthesis calls — seconds-to-low-minutes of GPU time. Pin it to the GPU the rig isn't hammering (the rig keeps `gpus:[0]`/`gpus:[1]` busy; choose the freer one).

**Primary path — F5-TTS:**

```powershell
# 1. Isolated env (do NOT pollute Spin's uv project)
py -3.11 -m venv C:\voice-clone\.venv
C:\voice-clone\.venv\Scripts\Activate.ps1

# 2. PyTorch CUDA build first, then F5 (let torch resolve before f5-tts)
pip install torch --index-url https://download.pytorch.org/whl/cu124
pip install f5-tts

# 3. Pin to one 4090 (use the GPU the rig isn't saturating)
$env:CUDA_VISIBLE_DEVICES = "1"

# 4. Put the 6-min script in narration.txt, then synthesize from the reference
f5-tts_infer-cli `
  --ref_audio  C:\voice-clone\ref-michael-35s.wav `
  --ref_text   "EXACT transcript of those 35 seconds, verbatim" `
  --gen_file   C:\voice-clone\narration.txt `
  --output_dir C:\voice-clone\out
```

- F5 needs the **`--ref_text`** to match the reference clip verbatim — transcribe the exact 35s you cut (the folder's `transcript.json` likely already has the timestamped words; lift the span). A mismatched ref_text degrades similarity.
- First run downloads the F5 checkpoint to the HF cache; **after that it's fully offline.** No audio or text leaves the machine.
- For a clean 6-min result: **chunk the script by paragraph/sentence and synthesize per chunk** (F5, like all these models, drifts on very long single passes). Then concatenate with ffmpeg (`-f concat`) and do one normalization pass: `ffmpeg ... -af "loudnorm=I=-16:TP=-1.5:LRA=11"` for broadcast-clean, consistent loudness. Audition each chunk; re-roll any with artifacts (zero-shot TTS is non-deterministic — a bad chunk is a re-run, not a model failure).

**Fallback path — XTTS-v2 (coqui-tts):**

```powershell
pip install coqui-tts
$env:CUDA_VISIBLE_DEVICES = "1"
tts --model_name "tts_models/multilingual/multi-dataset/xtts_v2" `
    --speaker_wav C:\voice-clone\ref-michael-35s.wav `
    --language_idx en `
    --text "one chunk of narration here" `
    --use_cuda true `
    --out_path C:\voice-clone\out\chunk01.wav
```

- XTTS doesn't need a ref_text (it infers the speaker embedding from `--speaker_wav` alone), which makes scripting simpler — same chunk-then-concat-then-loudnorm flow.
- First invocation prompts to accept the CPML license non-interactively via `COQUI_TOS_AGREED=1`; downloads the model to cache, then offline.

**Done-signal / quality gate:** produce one chunk first, listen, confirm it sounds like Michael before synthesizing all 6 minutes. If F5's similarity is weak, the usual cause is a noisy/short/mismatched reference, not the model — re-cut a cleaner 35s span before switching models. Switch to XTTS-v2 only if a *clean* F5 reference still underperforms.

**Relevant absolute paths:**
- Target audio: `C:\path\to\workspace\books\creators-playbook\EP_87_87-soul-bleeding-dystopias\episode.mp3`
- Folder transcript (source for `--ref_text`): `C:\path\to\workspace\books\creators-playbook\EP_87_87-soul-bleeding-dystopias\transcript.json` (and `transcript.md`)
- Kokoro-is-synthesis-only evidence: `C:\path\to\workspace\projects\spin\app\spin_bot.py:149` and `projects\spin\app\.env.example:17`
- GPU topology reference: `C:\path\to\workspace\projects\llama-chip\config.json`

Nothing was installed. This is plan-only.

---

## Narration script (~6 min, draft)

[SCENE: Dark Stewdio cockpit, the three-pane studio. A single Postgres elephant logo, then `docker compose up` scrolling. Slow zoom on a database table where one row lights up.]

This is a Postgres database. The kind you already know how to back up. But this one thinks. It digests your sources, runs grounded AI on your own GPUs, and dispatches models — free, paid, or local — and routes every job to the right one. The agent's whole brain is one database. One backup. One query. Vector, relational, and graph in the same SELECT. Today I want to show you what we built on top of that, and it's called Loreworks.

[SCENE: A messy desktop folder — dozens of PDFs and rulebooks piling up, a wiki, scanned pages. The clutter sits there, inert.]

Start with the problem. You have a pile of lore. A campaign setting, a rulebook, years of your own writing, a wiki nobody's read end to end. It's all there, and none of it is usable. You can't search it by what you mean — only by the exact words you happened to type. You can't see how the pieces connect. You can't ask a character in it a question. It's a graveyard of stuff you bought and meant to use. So the lore just sits there, and the world stays locked inside the files.

[SCENE: A single rulebook PDF dragged into Stewdio's left pane. A pipeline animates: read → extract → graph → summarize. Entity cards and edges bloom out of the document text.]

Loreworks changes that. You drop the source in, and the substrate builds a world. Not a chatbot bolted onto a file — a world with four parts. It digests the canon into something you can search by meaning, so a query for "alert overload" finds the passage about "notification fatigue" even though they share no words. It extracts every entity — characters, places, factions, items, events — and the relationships between them, into a real knowledge graph. And it stands up personas, grounded in that exact canon, that you can talk to. Same governed pipeline that writes a research dossier. We just aimed it at lore.

[SCENE: Three world tiles light up side by side — a bright pastel My Little Pony crest, a Starfleet delta, and a brooding dark-fantasy sigil. Each opens to its own searchable canon.]

Here's the proof. Three worlds, built from tabletop games I actually bought — so this is legally mine, and it never leaves my machine. My Little Pony, all whimsy. Star Trek Adventures, hard sci-fi. And a dark-fantasy setting, all grim. Three completely different genres, same pipeline, no special-casing. Drop the books in, get back a world. The engine doesn't care what the lore is about. It cares that there's a canon to read.

[SCENE: The 3D force-graph panel. Hundreds of glowing nodes and edges rotating in space. A cursor clicks a node — a side panel slides in with that entity's lore and the source passages it was pulled from. A filter toggles "characters only," then "factions."]

This is the Star Trek world as a graph. Every node is an entity the substrate pulled out of the rulebooks. Every edge is a relationship it found, with the evidence attached. Click a captain, and you get who they serve under, what ship they command, the factions they answer to — and the actual passage each fact came from. Click any sentence, you land on the corpus row it was built from. Nothing's invented. Filter to just the characters, just the places, just the factions. We're not reading a book here. We're flying through one.

[SCENE: A world chat room. A pony character avatar. The user types a question about a far-off region of Equestria. The persona answers in voice — and a provenance chip under each claim links back to the canon passage.]

Then you go talk to it. This is a character grounded in the Pony canon. I ask her about a place she's never mentioned, and she answers from the actual lore — and shows me the passage she's standing on. She's not making it up from training data. She's reading the world we built and speaking from inside it. Same machinery that voices a D&D table. The serious tool and the fun one really are one tool.

[SCENE: The Postgres logo again, now ringed by a small cluster of GPUs glowing on a desk. A "no-train" lock icon sits over the data flowing between them.]

So here's what it means. Any world you can feed it becomes fully searchable, fully mapped, and fully alive — and it's yours. It runs on the GPUs on your own desk, in a Postgres you can back up like any other. The lore never has to leave the building. No cloud holding your canon hostage, no provider training on the world you spent years building.

[SCENE: Pull back from the three worlds to a wide field of empty tiles waiting to be filled — a campaign, a codebase, a company's research, a life's worth of notes. The Loreworks title resolves over them.]

We proved it on three tabletop games because they're vivid and easy to show. But a world is anything with a corpus you want to understand and grow. Point this at your customer research and it builds you a dossier. Point it at a topic you're learning and it relates everything back to what you already know. Point it at a fiction setting and it keeps the canon and voices the cast. We built one engine for all of it, and we put it out in the open. Drop in your lore. Get back a world. That's Loreworks.
