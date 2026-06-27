# Hinge Reviewer — Amendment (decouple, widen, notify)

**Status:** proposed (2026-06-26), for council ratification. An **amendment** to the
already-shipped Hinge reviewer (`39-hinge.sql` + `scripts/hinge-review/`, Phase H / #195;
exercised in the 2026-06-21 overnight watch). Not a new system — three small changes so the
existing reviewer earns more of the unused Max-plan capacity.

## Where we already are (don't rebuild this)

The Hinge reviewer is built and proven:
- `stewards.hinge_reviews` queue + `hinge_enqueue` / `hinge_pending` / `hinge_record_verdict`.
- **Two-tier authority, enforced in SQL** (not prompt): `hinge_record_verdict` clamps every
  verdict to the bounds — `hinge_auto_approve_kinds` (currently `digest-skill-rule`,
  `graph-link`, `pipeline-adjust`) and `hinge_escalate_always_kinds` (`cutover`,
  `new-pipeline`, `new-capability`, `spend-increase`, `schedule-change` → always Michael,
  regardless of the reviewer's verdict). A generous reviewer **cannot** exceed its grant.
- A curated host `claude -p` reviewer (`scripts/hinge-review/`, its own `hinge/CLAUDE.md` +
  read-only DB access) that **investigates** — it once caught a spurious-correlation rule that
  would have pushed the digesters toward fabrication, and revised it.
- A substrate-driven daemon: `hinge_gate_status()` → `should_run = pending>0 AND NOT
  autonomy_paused`, polled every `hinge_daemon_interval_seconds` (300).

**Live state now:** 49 pending (36 `graph-link` + 13 `digest-skill-rule`, all
auto-approvable kinds), off because `autonomy_paused=true` (innovation-week GPU pause).

This amendment is the delta between *what exists* and Michael's ask: *"can a woken Claude
review the upper-level Hinges — instruction changes, judge reviews — so I render the verdict
fast, and so I use more of my 20x Max plan?"* Council 2026-06-26 ratified **two-tier authority**
(unchanged — it's already the design) and **spec-then-build**.

## Change 1 — Decouple the reviewer from the global GPU pause

**Why:** the reviewer runs on `claude -p` — **cloud Max, independent of the local 4090 rig.**
The overnight failures were the *digester loops* dying on the rig, not the reviewer. But it
rides `autonomy_paused`, which during innovation week means "free the GPUs" — so the
rig-independent reviewer is idled for a reason that doesn't apply to it. That's exactly the
50%-on-the-table capacity.

**What:** the reviewer gets its own switch, and an opt-in to ignore the *GPU* pause — while a
true **emergency** stop still halts it.
- New config `hinge_daemon_paused` (default `false`) — the reviewer's own kill switch.
- New config `hinge_runs_during_global_pause` (default `false`) — when `true`, the reviewer
  ignores `autonomy_paused` (the innovation-week setting). Default `false` = current behavior.
- `hinge_gate_status.should_run := pending>0 AND NOT hinge_daemon_paused AND (NOT
  autonomy_paused OR hinge_runs_during_global_pause)`.
- **Emergency stays supreme:** the watchman guard (`23`/`28`), on a *true* runaway, sets
  `hinge_daemon_paused=true` too — so a real emergency halts the reviewer regardless of the
  opt-in. "Free the GPUs" leaves it working; "stop everything" still stops it.

Michael sets `hinge_runs_during_global_pause=true` for innovation week → the Max-plan reviewer
clears Hinges while the GPUs rest.

## Change 2 — Widen the sources to the upper-level Hinges (prepare-only)

**Why:** today the queue is fed by memory/digester proposals (skill-rules, graph-links). The
categories Michael wants a Claude-caliber eye on — **instruction/prompt changes** and
**judge/critic changes** — don't flow into it yet (`propose_prompt_change` is gated off
entirely). These are exactly the categories the eval-gaming guard protects.

**What:**
- Add kinds `instruction-change`, `judge-change`, `prompt-change` to
  **`hinge_escalate_always_kinds`** — so the reviewer **always prepares-only** on them and
  Michael renders. (Review ≠ modify; recommend ≠ approve. The bright line, enforced in SQL.)
- Wire the gated paths to enqueue: when an autonomous process proposes an instruction/judge/
  prompt change, it `hinge_enqueue`s a row (kind = the above) carrying the full diff + context,
  instead of silently sitting or being refused. The reviewer reads the diff, the affected
  agents, the rationale, and writes a **decision-ready brief + a recommendation + the
  steelman-against** (Ben Test: present the case *against* the change too, not just for it),
  recorded as `status=escalated`. Michael's verdict is final.
- (Optional, deferred) surface `work_items` at `awaiting_review` as a `work-item-review` kind
  (escalate-always) so the general Hinge queue and the reviewer unify. Off by default — it can
  flood; revisit after the upper-level kinds prove out.

**Self-reference guard (honest risk):** a Claude reviewing changes to the *critics that may
later judge Claude's own work* is meta-evaluation. Mitigations: prepare-only (never
auto-applies), the SQL bounds, the required steelman-against, and the full trajectory log
(`hinge-review.log` + the trajectory critic, `56`) so Michael can audit the reasoning.

## Change 3 — Tell Michael (the notification plane) — TRANSPORT DEFERRED

**Why:** the loop only closes when Michael *knows* a verdict is waiting. Today the queue sits
silently. He asked for an **outbound-only** notification plane — agent → him; nothing he
texts/emails back is ever a command.

**What (now):** build a transport-agnostic primitive — `stewards.notify(text, priority, link)`
that records to a `stewards.notifications` table (and surfaces in Stewdio). The Hinge reviewer
calls it on `status=escalated` rows; the same hook serves "a long job finished." This closes the
*signal* without committing to any transport.

**What (deferred — Michael's rethink 2026-06-26):** he is hesitant to add **another third
party** (Pushover/Apprise), and would rather use **own infrastructure** — the **brain app
(ibeco.me)**, currently pointed at the dead gen-3 brain. Candidate: repoint the brain app at
pg-ai-stewards (gen-4) and use it as the notification surface — **web push (PWA, VAPID) = genuinely
zero third-party** for self-notify. Honest constraint: **SMS needs a carrier gateway** (Twilio
etc. — unavoidable third party) and **email needs a sender** (SES/SMTP); "no third party at all"
only holds for web push to his own device. And his bigger framing — *"reach others on my behalf"*
— widens this from "notify me" to **the agent communicating outward as Michael's representative**,
which is a larger, more sensitive capability — its own council. (This is what **OpenClaw**
[`github.com/openclaw/openclaw`, 200k★] does off-the-shelf by wiring an agent to WhatsApp / Signal /
iMessage / Telegram etc. — but its **inbound-messaging-as-control-plane** is the prompt-injection
nightmare documented in arXiv 2603.27517 + Kaspersky, and is exactly what Michael's "nothing
authoritative from email/text" rule forbids. pg-ai-stewards does the same *reach* **send-only and
walled** — OpenClaw's capability without OpenClaw's attack surface.) So: **transport decision
deferred**; `notify()` records now, the wire (brain-app web push first; minimal email later) is
chosen separately. Send-only by construction regardless — the substrate POSTs out; no inbound path
is ever consumed.

## Rails (mostly already there)

- Two-tier authority: enforced in `hinge_record_verdict` (unchanged). Upper-level kinds =
  escalate-always = prepare-only.
- Emergency stop: `autonomy_paused` (supreme) + new `hinge_daemon_paused`; watchman trips both
  on a runaway.
- Cost: a deep review is pennies; the overnight watch was $7.65 for ~18 reviews on real
  judgment. The reviewer is cloud Max (the unused capacity), not rig load.
- Accounting: every review logged (verdict + the `claude -p` envelope: turns, cost, session id).
  Presiding: Michael → daemon → woken-Claude; the log is the watch.

## Phases / acceptance

- **P0 — caliber check (this session):** `hinge-review.py --dry-run --limit 8` over the live
  backlog → show the verdicts, nothing applied. *Acceptance: the briefs are Michael-grade.*
- **P1 — decouple + drain:** ship Change 1; with Michael's go, a bounded real pass over the 49
  (auto-approvable kinds apply within bounds; anything off-grant escalates). *Acceptance: queue
  drains, zero out-of-bounds applies.*
- **P2 — widen + notify:** ship Change 2 (new escalate-always kinds + the enqueue wiring) and
  Change 3 (the notify hook). *Acceptance: an instruction/judge change proposed → appears as an
  escalated Hinge with a decision-ready brief → Michael gets a notification → renders.*

## Council decisions for Michael

1. **Decouple** via `hinge_runs_during_global_pause` (default off; set on for innovation week)?
   *(rec: yes)*
2. **Widen** to `instruction-change` / `judge-change` / `prompt-change` as **escalate-always**
   (prepare-only)? *(rec: yes)*
3. **Notify** plane: Apprise + Pushover to start, outbound-only? *(rec: yes — see the notes)*
4. Drain the 49 backlog after the dry-run caliber check? *(rec: yes, bounded pass)*

## Provenance
- `39-hinge.sql` + `scripts/hinge-review/README.md` (the existing reviewer + its bounds).
- `.spec/journal/2026-06-21-overnight-hinge-watch.md` (it ran; the watchman saved it twice).
- Council 2026-06-26 (this session): two-tier ratified, spec-then-build; the A2A "can you be
  woken" thread that surfaced it (`.spec/proposals/a2a-open-engine.md`).
