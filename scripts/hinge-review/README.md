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

## Usage
```bash
python hinge-review.py            # review all pending
python hinge-review.py --dry-run  # show verdicts without recording
python hinge-review.py --model claude-sonnet-4-6   # cheaper reviewer
```
Curate the reviewer by editing `hinge/CLAUDE.md`. Keep it lean — `claude -p` loads the
folder's context, so a tight folder = focused judgment + low cost.
