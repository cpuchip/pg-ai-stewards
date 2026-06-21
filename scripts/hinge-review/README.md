# hinge-review — the Hinge reviewer (a curated `claude -p`)

The substrate tends itself; its gated decisions (a refined skill rule, a graph reorg, a
pipeline cutover) need a Hinge. Michael is the ultimate Hinge — this is a **curated
`claude -p` that tiers under him**: it reviews each pending proposal against the covenant
and returns a verdict; the substrate applies what's approved. A judge, not a doer.

Runs on the **host** (where `claude` is installed + authed via the Max subscription), the
sibling of `materialize-writes`. For each row in `stewards.hinge_reviews` (status
`pending`) it runs `claude -p` from the curated `hinge/` subfolder (whose `CLAUDE.md` is
the Hinge role + covenant + verdict format), parses the JSON verdict, and records it via
`stewards.hinge_record_verdict` — which **enforces the bounds in the substrate**, so the
reviewer can never exceed its delegated grant.

## Bounds (config — Michael owns these)
- `hinge_auto_approve_kinds` — kinds the reviewer may auto-approve (default `[]` — none
  until granted in council).
- `hinge_escalate_always_kinds` — kinds that ALWAYS go to Michael regardless of the
  verdict (default: cutover, new-pipeline, new-capability, spend-increase, schedule-change).

An out-of-bounds or escalate-always kind the reviewer "approves" is recorded as
**escalated** (with its recommendation), waiting for Michael. Michael's verdict is final.

## It investigates, it doesn't just glance
The curated `hinge/` folder gives the judge real scope: an `architecture.md` brief (what
each proposal kind means + where the evidence lives) and **read-only DB access** via
`hinge/query.sh` (writes are refused). So the reviewer reads the actual flagged quotes a
rule claims to fix, the two docs a link claims to relate, prior verdicts — the 30,000-foot
view, not the payload alone. (It once caught a proposed rule whose grounding was a spurious
correlation and would have pushed the digesters toward fabrication — and revised it.)

## Usage
```bash
python hinge-review.py            # review all pending
python hinge-review.py --dry-run  # show verdicts without recording
python hinge-review.py --model claude-sonnet-4-6   # cheaper/faster reviewer
```
Every review is logged to `hinge-review.log` (the verdict + the raw `claude -p` envelope:
turns, cost, session id). The queue itself is `SELECT * FROM stewards.hinge_reviews`.

## Running it continuously — the daemon
```powershell
pwsh hinge-daemon.ps1     # poll + review until Ctrl-C (or register as a scheduled task)
```
The daemon is **substrate-driven**: each tick it asks `stewards.hinge_gate_status()` whether
to run, how often (`hinge_daemon_interval_seconds`), and whether the system is paused. It
runs the reviewer only when there is pending work AND the substrate is **not** paused — so
the global emergency stop (`autonomy_paused`, which the watchman trips on a runaway) halts
the gate along with the source and the digesters. One switch stops everything.

Curate the reviewer by editing `hinge/CLAUDE.md` + `hinge/architecture.md`. Cost is not a
concern (a deep review is pennies); depth is the point of a Hinge.
