#!/usr/bin/env python3
"""hinge-review — the host-side Hinge reviewer (Phase H of the self-tending memory).

A curated `claude -p` reviews the substrate's gated proposals. It runs on the HOST
(where `claude` is installed + authed via the Max subscription), NOT in the container —
the sibling of `materialize-writes`. For each pending row in `stewards.hinge_reviews`,
it runs `claude -p` from the curated `hinge/` subfolder (which holds the Hinge CLAUDE.md
= role + covenant + verdict format), parses the structured verdict, and records it via
`hinge_record_verdict` — which ENFORCES the bounds in the substrate, so a generous
reviewer can never exceed its delegated grant (out-of-bounds / escalate-always kinds go
to Michael regardless).

It is a JUDGE, not a doer: it only writes a verdict; the substrate applies what's approved.

Usage:
  python hinge-review.py            # review all pending items
  python hinge-review.py --limit 5
  python hinge-review.py --dry-run  # show the verdict, don't record it
  python hinge-review.py --once     # review one item and stop
Options: --container NAME (default stewards-oss-pg), --model NAME (claude -p --model).
Exit 0 always (a review run is best-effort; failures are logged per item).
"""
import sys, os, re, json, subprocess

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # Windows console is cp1252 by default
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
HINGE_DIR = os.path.join(HERE, "hinge")        # the curated subfolder (its CLAUDE.md is the role)
CONTAINER = "stewards-oss-pg"
MODEL = None
DRY = False
LOG = os.path.join(HERE, "hinge-review.log")  # easy human-readable log of every review


def _ts():
    import datetime
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log_raw(text):
    """Append the raw claude -p envelope (truncated) — for debugging a review."""
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"\n----- {_ts()} claude -p raw (truncated) -----\n{(text or '')[:1800]}\n")
    except Exception:
        pass


def log_review(item, verdict, reason, status):
    """Append the human-readable verdict line (what the Hinge decided + why)."""
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{_ts()}  #{item['id']} [{item['kind']}] {item['subject']}\n"
                    f"  VERDICT {verdict} -> {status}\n  {reason}\n\n")
    except Exception:
        pass


def psql(sql):
    out = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-U", "stewards", "-d", "stewards", "-tAc", sql],
        capture_output=True, text=True, encoding="utf-8",
    )
    if out.returncode != 0:
        sys.stderr.write(f"db error: {out.stderr}\n")
        sys.exit(2)
    return out.stdout.strip()


def pending(limit):
    raw = psql(
        "SELECT coalesce(json_agg(row_to_json(h)), '[]') FROM "
        f"(SELECT id, kind, subject, payload FROM stewards.hinge_pending({limit})) h"
    )
    return json.loads(raw or "[]")


def review(item):
    """Run claude -p from the curated hinge/ dir; return (verdict, reason)."""
    prompt = (
        "Review this proposal and emit ONLY your JSON verdict.\n\n"
        f"kind: {item['kind']}\n"
        f"subject: {item['subject']}\n"
        "payload:\n"
        f"{json.dumps(item.get('payload', {}), indent=2)}\n"
    )
    # Give the judge real scope: read-only DB access (bash query.sh) + read its folder,
    # so it can investigate the evidence, not just the payload. cwd = the curated folder.
    cmd = ["claude", "-p", prompt, "--output-format", "json",
           "--allowedTools", "Bash,Read,Grep,Glob", "--max-turns", "30"]
    if MODEL:
        cmd += ["--model", MODEL]
    out = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", cwd=HINGE_DIR)
    log_raw(out.stdout or out.stderr)
    if out.returncode != 0:
        return None, f"claude -p failed: {out.stderr[:200]}"
    try:
        env = json.loads(out.stdout)
        text = env.get("result", "") if isinstance(env, dict) else out.stdout
    except Exception:
        text = out.stdout
    # extract the first {...} verdict object from the model's text
    m = re.search(r"\{[^{}]*\"verdict\"[^{}]*\}", text, re.DOTALL)
    if not m:
        return "escalate", "could not parse a verdict from the reviewer — escalating"
    try:
        v = json.loads(m.group(0))
        return (v.get("verdict") or "escalate"), (v.get("reason") or "")
    except Exception:
        return "escalate", "malformed verdict json — escalating"


def record(item_id, verdict, reason):
    safe = (reason or "").replace("'", "''")[:1000]
    res = psql(f"SELECT stewards.hinge_record_verdict({item_id}, '{verdict}', '{safe}', 'claude-hinge')")
    try:
        return json.loads(res).get("status", "?")
    except Exception:
        return res


def main():
    global CONTAINER, MODEL, DRY
    args, limit, once = sys.argv[1:], 20, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--container": CONTAINER = args[i+1]; i += 2; continue
        if a == "--model": MODEL = args[i+1]; i += 2; continue
        if a == "--limit": limit = int(args[i+1]); i += 2; continue
        if a == "--dry-run": DRY = True; i += 1; continue
        if a == "--once": once = True; i += 1; continue
        i += 1

    items = pending(limit)
    if not items:
        print("hinge-review: nothing pending")
        return
    print(f"hinge-review: {len(items)} pending\n")
    for item in items:
        verdict, reason = review(item)
        if verdict is None:
            print(f"  #{item['id']} [{item['kind']}] ERROR: {reason}")
            continue
        if DRY:
            print(f"  #{item['id']} [{item['kind']}] {item['subject']}\n      would: {verdict} — {reason}")
        else:
            status = record(item["id"], verdict, reason)
            log_review(item, verdict, reason, status)
            print(f"  #{item['id']} [{item['kind']}] {item['subject']}\n      {verdict} → {status} — {reason}")
        if once:
            break


if __name__ == "__main__":
    main()
