# sol-p0-release-batch — red-run evidence (2026-08-11, journeyman)

Red-first per the queue's oracle: every defect watched failing on the real path
(image built from HEAD `6d3e37a`, virgin `pgvector:pg18` cluster, container
`pg-p0red`, no live DB touched) before any fix was written.

## RED 1 — Sol P0: virgin CREATE EXTENSION aborts

```
NOTICE:  installing required extension "vector"
ERROR:  role "brain_read" does not exist
CONTEXT:  SQL statement "GRANT EXECUTE ON FUNCTION stewards.box_for_role(text) TO brain_read"
extension script file "pg_ai_stewards--0.3.0.sql", near line 55743
```

Instrument: `docker exec -i pg-p0red psql -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_ai_stewards CASCADE;"`.
The failed CREATE EXTENSION is atomic — the CASCADE-installed vector rolls back
with it (re-verified on the retry).

## RED 2 — NEW finding (beyond Sol's audit): missing house.roster breaks the
## install one step later

With `brain_read`/`brain_absorb` provisioned by hand (simulating the fixture),
`CREATE EXTENSION` **succeeds** — and then:

```
INSERT INTO stewards.nodes (kind, ref, label) VALUES ('memory','red2-probe','probe');
ERROR:  relation "house.roster" does not exist
CONTEXT:  SQL function "box_for_role" statement 1
PL/pgSQL function stamp_origin_box() line 3 at assignment
```

`SELECT * FROM stewards.lane_check()` fails identically (its check (c) queries
`house.roster` directly). So on a fresh install EVERY nodes/fact_edges INSERT
errors — the v49 stamp trigger fires `current_box()` → `box_for_role()` →
`house.roster`. The roster is host-private by ruling (brain-client
`roster.py:70`: "Private house schema — never ships in the public chain"), yet
the public chain depends on it. Sol's static audit stopped at the GRANT abort;
this is the breaker behind it.

Remedy taken (repo-only): `box_for_role` + `lane_check` re-authored in v51 to
treat a missing roster as "no roster on this install" — the same designed
fallback v49 already uses for an unenrolled role (lane = role name). Fixture
stays roles-only per the queue.

## RED 3a — Sol P1: two-session brain_add, same normalized title

dblink-driven concurrent sessions, HEAD build:

```
NOTICE:  RACE A RESULT: 2 live memories with the same normalized title (1 = guarded, 2 = RACE LANDED)
WARNING:  RED: sibling-prevention lost the race — two live memories share one subject
```

## RED 3b — Sol P1: two-session brain_amend, lost correction

```
NOTICE:  RACE B final body: original body

> ⚠ CORRECTED 2026-08-11 — correction-TWO
WARNING:  RED: correction-ONE was silently discarded by the concurrent amend
```

correction-ONE (committed first) is gone; no error was raised to either
session.

Script: the same shapes were then hardened into `tests/concurrency-write-path.sql`
(assert-fatal instead of WARNING) and watched fail against this HEAD image
before v51 was written — the oracle proven red on the real defect before its
green is trusted.

---

## Round 2 — codex's review of e79895fc, and the v52 red (same day)

Codex (the Sol seat) reviewed the batch: no objections to the fixes above, and
a RED on v51's roster-absence design — structural absence is mutable database
state, not posture; dropping authority data must not silently change the
identity function from roster name to role name (room msgs #810/#812/#814).
The ruling became v52 (`lane_identity_mode`, sticky + guarded + fail-closed).

**RED (v51 image, virgin cluster `pg-v52red`):** roles bootstrapped, extension
installed, `house.roster` created then DROPPED — and the write LANDED:

```
INSERT INTO stewards.nodes (kind, ref, label) VALUES ('memory','v52red-probe','probe') RETURNING origin_box;
 origin_box
------------
 fermion
(1 row)
INSERT 0 1
```

The silent downgrade, observed. v52 makes this exact write fail closed under
`roster_required`; smoke OK 120c–g (which replaced the OK 120b that
green-certified this) carries the DROP TABLE and DROP SCHEMA reds plus the
recovery and the disable-and-account operator path.

The new oracle then caught v52's OWN first build: `fact_recall_mine` as an
inlinable SQL function let PostgreSQL fold the lane expression into per-row
contexts, so an empty recall never evaluated `box_for_role` and answered in
the fail-closed state — OK 120d red on the mine-recall assert. Re-authored
plpgsql, lane computed before the query; fail-closed no longer depends on
result-set size. (A guard you can inline away is a guard that leaves no
trace.)

## Round 3 — codex's review of 11803e4b: the guard's key was a door

Codex accepted v52's shape and then found the hole in its skin (room msg
#823): the guard's `WHEN (OLD.key = 'lane_identity_mode')` watched the VALUE
while permitting the KEY to change. Observed live on the v52 build
(container `pg-p0green`, post-green-run state):

```
UPDATE stewards.config SET key='lane_identity_mode_old' WHERE key='lane_identity_mode';
UPDATE 1                                      -- the protected row escaped
INSERT INTO stewards.config (key, value) VALUES ('evil', to_jsonb('anarchy'::text));
UPDATE stewards.config SET key='lane_identity_mode' WHERE key='evil';
UPDATE 1                                      -- a poisoned row took the key
SELECT coalesce(stewards.box_for_role('box_anything'), '<null = silent fallback>');
 <null = silent fallback>                     -- readers defaulted right past it
```

Because v52's readers DEFAULTED a missing/foreign mode from roster presence,
the rename resurrected the structural fallback v52 existed to remove — with
lane_check reporting mode valid off the same default. v53 pins the key (both
rename directions), removes the default entirely (missing/invalid row fails
closed in both postures), validates inherited preseed rows at migration or
aborts, and binds every trigger assertion to its table + enabled state.
Smoke OK 120h/120i carry the reds; verify-53 carries the live-safe subset.

## Round 4 — codex's review of 5ae8901b: posture must be causal, and the
## oracle must require origin-enabled triggers

Two holes, both watched red on the v53 build (container `pg-v54red`):

**A. The mode was validated but not USED as the source chooser.** Declared
`role_name`, then created a roster with a conflicting mapping:

```
 declared_mode = role_name
 INSERT INTO house.roster ... ('box','probename','probename','box_probe');
 SELECT stewards.box_for_role('box_probe');
  -> 'probename'          -- the roster answered under role_name posture
```

Restoring a backup (or preparing an enrollment early) silently changed every
box's lane derivation with no posture transition. v54: role_name returns
NULL unconditionally (the roster is INERT until the explicit forward flip);
roster_required requires and queries it. Smoke OK 120 now asserts the inert
case and OK 120c asserts the source switches exactly at the flip.

**B. `tgenabled <> 'D'` accepted replica-only triggers.**

```
 ALTER TABLE stewards.nodes ENABLE REPLICA TRIGGER stamp_origin_box;
 SELECT ... lane_check() WHERE check_name='stamp_is_forced';  -> ok = t
 INSERT INTO stewards.nodes ... RETURNING origin_box;
  -> <NULL — trigger did not fire>
```

The lane-forcing wall silently off, the oracle green. Every trigger
assertion (lane_check b/b2/b3, smoke OK 118, verify-53/54) now requires
`tgenabled IN ('O','A')`.

## Standing finding — GitHub CI has never run on this repository

While watching the e79895fc push: GitHub recorded every PushEvent (events
API), the CI workflow is `active` with Actions enabled — and the workflow's
run count is ZERO, ever. Every "green CI" premise about this repo was
vacuous: the only oracle that has ever actually gated the chain is the local
run of the same scripts. `workflow_dispatch` was added to ci.yml as probe +
on-demand repair; root cause unresolved at this writing (instrument:
`gh api repos/cpuchip/pg-ai-stewards/events` vs
`gh api .../actions/workflows/<ci-id>/runs` = empty).
