# Sol full adversarial audit — 2026-08-11

Scope: static, read-only audit of the public repository. I did not execute SQL
against a database. This report was written before reading any prior audit or
review material.

## Findings

### P0 — A clean install cannot reach `CREATE EXTENSION`: v49/v50 grant roles that the public substrate never creates

**Evidence:** [`extension/v49-memory-lanes.sql:50`](../../extension/v49-memory-lanes.sql#L50) grants to `brain_read`, and [`extension/v50-lane-write-path.sql:159-163`](../../extension/v50-lane-write-path.sql#L159) grants to `brain_absorb`. The fresh-init hook runs `CREATE EXTENSION` directly ([`extension/init/00-extensions.sql:10-11`](../../extension/init/00-extensions.sql#L10)); the advertised compose boot claims this works on a virgin machine ([`docker-compose.yaml:9-13`](../../docker-compose.yaml#L9)). There is no `CREATE ROLE brain_read` or `CREATE ROLE brain_absorb` anywhere in the repository.

**Failure scenario:** PostgreSQL rejects `GRANT ... TO <nonexistent role>` with `ERROR: role ... does not exist`. As soon as pgrx reaches v49, the entire extension-install transaction aborts. `docker compose up` therefore cannot deliver the README's “clean machine” install once this chain is actually packaged.

**Suggested fix:** Do not make an extension own cluster-global roles. Either remove these grants from core and document an explicit, idempotent operator provisioning step before applying v49, or ship an opt-in bootstrap SQL script run by an operator/superuser that creates NOLOGIN group roles and grants narrowly. Add a clean-cluster test that has no pre-created roles and exercises the actual v50 package.

### P1 — `brain_add`'s sibling-prevention invariant loses to a normal concurrent insert race

**Evidence:** The collision check is a standalone read at [`extension/v50-lane-write-path.sql:60-70`](../../extension/v50-lane-write-path.sql#L60), followed by an unconstrained insert at [`extension/v50-lane-write-path.sql:73-77`](../../extension/v50-lane-write-path.sql#L73). The only relevant database uniqueness is `(kind, ref)`, not normalized title ([`extension/v00-foundations.sql:147-150`](../../extension/v00-foundations.sql#L147)).

**Failure scenario:** Two box sessions call `brain_add` concurrently with different refs but the same normalized title. Both observe no collision before either insert commits, then both insert successfully. Lane-first recall can now surface a stale sibling to its original author—the exact failure the v50 guard says it prevents.

**Suggested fix:** Serialize the collision domain: take a transaction-scoped advisory lock keyed by normalized title/ref, then recheck before insert; or enforce an appropriate live-memory uniqueness constraint and make the insert use `ON CONFLICT` to emit the domain error. Add a two-session regression test proving that exactly one concurrent add succeeds.

### P1 — Concurrent amendments silently discard a correction

**Evidence:** `brain_amend` reads the whole row without a lock ([`extension/v50-lane-write-path.sql:95-96`](../../extension/v50-lane-write-path.sql#L95)), constructs a replacement body in local memory ([`extension/v50-lane-write-path.sql:113-117`](../../extension/v50-lane-write-path.sql#L113)), then writes that snapshot ([`extension/v50-lane-write-path.sql:119-123`](../../extension/v50-lane-write-path.sql#L119)).

**Failure scenario:** Two agents amend the same memory at once. Both read body A; one writes A+correction-1, then the other writes A+correction-2. Correction 1 disappears without an error, despite the claimed strike-in-place history.

**Suggested fix:** `SELECT ... FOR UPDATE` the identity row, construct the new body only after the lock is acquired, and update by immutable `id` plus the expected lane. Add a concurrent-amend oracle asserting both corrections survive in a deterministic order.

### P1 — The checked CI oracle stops at v40 even though the shipped extension chain continues through v50

**Evidence:** The Rust registry packages v41–v50 ([`extension/src/lib.rs:459-613`](../../extension/src/lib.rs#L459)), and the Docker build copies all of them ([`extension/Dockerfile:100-109`](../../extension/Dockerfile#L100)). CI runs only `tests/virgin-smoke.sql` ([`.github/workflows/ci.yml:48-49`](../../.github/workflows/ci.yml#L48)), whose own completion banner declares the chain sound only through v40 ([`tests/virgin-smoke.sql:6592`](../../tests/virgin-smoke.sql#L6592)). `verify-49` and `verify-50` are manual scripts, and both skip their decisive role tests when the box role is absent ([`extension/verify-49-memory-lanes.sql:33-36`](../../extension/verify-49-memory-lanes.sql#L33), [`extension/verify-50-lane-write-path.sql:30-33`](../../extension/verify-50-lane-write-path.sql#L30)).

**Failure scenario:** A v41–v50 regression ships with green CI because the only post-install oracle neither asserts those objects exist nor runs their behavior. The P0 above is particularly damaging: the intended clean boot test must catch it, but the test contract advertised by the repo never reaches the new lane features after the roles are made available.

**Suggested fix:** Make one CI-owned virgin test assert every registered volume (including v50) and run behavior tests for v43–v50. Provision isolated test roles in the test fixture, never by relying on a developer's existing cluster. Require concurrency tests for the v50 write path.

### P1 — Fact recall scales with the entire live graph, not the requested neighborhood, and exposes an unbounded work factor

**Evidence:** Both recall implementations first materialize all live fact edges ([`extension/v45-fact-recall.sql:31-38`](../../extension/v45-fact-recall.sql#L31); [`extension/v49-memory-lanes.sql:113-119`](../../extension/v49-memory-lanes.sql#L113)), scan that set again to calculate every node degree ([`extension/v45-fact-recall.sql:47-51`](../../extension/v45-fact-recall.sql#L47)), and expand each frontier through `src = id OR dst = id` ([`extension/v45-fact-recall.sql:61-67`](../../extension/v45-fact-recall.sql#L61)). Callers can supply `p_max_hops` with no upper bound ([`extension/v45-fact-recall.sql:26-29`](../../extension/v45-fact-recall.sql#L26)). The indexes are directional `(src, kind)`/`(dst, kind)` ([`extension/v43-fact-edges.sql:145-150`](../../extension/v43-fact-edges.sql#L145)), which do not directly satisfy the live, kindless OR join.

**Failure scenario:** At 10x corpus size, a one-seed, one-hop recall still builds an all-edge CTE and global degree aggregation. A caller can request a large hop count, multiplying paths through hubs. This converts an agent query into a shared CPU/memory denial of service and stalls queue work under load.

**Suggested fix:** Hard-cap hops and seed count at the SQL boundary; use a frontier-first recursive plan with separate indexed `src` and `dst` branches; maintain/calculate degree only for reached nodes or a cached live-degree table; benchmark against a 10x fixture with statement-time limits.

### P2 — `fact_recall_laned` lets any caller choose whose lane counts as “own”

**Evidence:** The public function accepts `p_lane` as an ordinary text argument ([`extension/v49-memory-lanes.sql:102-110`](../../extension/v49-memory-lanes.sql#L102)) and uses that supplied value for score boost and first-sort ([`extension/v49-memory-lanes.sql:142-152`](../../extension/v49-memory-lanes.sql#L142)). Although `current_box()` correctly derives identity from the role ([`extension/v49-memory-lanes.sql:52-58`](../../extension/v49-memory-lanes.sql#L52)), this recall function does not call it. The function comment says it is the caller's own lane ([`extension/v49-memory-lanes.sql:154-155`](../../extension/v49-memory-lanes.sql#L154)).

**Failure scenario:** A box can call `fact_recall_laned(..., 'fermion', ...)` and privilege the host lane, or an arbitrary rival lane, over its own. No row is leaked—the design already reads shared data—but the claimed independent, per-caller ordering is not enforced and an agent can trivially defeat it.

**Suggested fix:** Expose a caller-facing wrapper with no lane parameter that uses `current_box()`. Keep an explicitly named, owner-only/admin analysis function if arbitrary lane simulation is needed. Test that an unprivileged box cannot select a different lane.

### P2 — “Unforgeable” lane attribution only applies to INSERT; an UPDATE-capable writer can rewrite history

**Evidence:** The stamp function overwrites `NEW.origin_box` ([`extension/v49-memory-lanes.sql:74-79`](../../extension/v49-memory-lanes.sql#L74)), but both triggers are `BEFORE INSERT` only ([`extension/v49-memory-lanes.sql:82-87`](../../extension/v49-memory-lanes.sql#L82)). The documentation says callers cannot set the field ([`extension/v49-memory-lanes.sql:59-65`](../../extension/v49-memory-lanes.sql#L59)).

**Failure scenario:** Any future box/write integration granted `UPDATE` on `nodes` or `fact_edges` (or any currently privileged operational role) can change `origin_box` after insertion. That changes lane-first recall and provenance while the `lane_check()` trigger-count test remains green.

**Suggested fix:** Revoke direct updates from box roles and add a `BEFORE UPDATE OF origin_box` trigger that rejects changes (or resets to `OLD.origin_box`). Extend `lane_check()` and its oracle to attempt a post-insert forgery, not just an insert forgery.

### P2 — `p_force` is an unrestricted bypass of the only sibling-correction control

**Evidence:** `brain_add` skips the collision check whenever the caller sets `p_force` ([`extension/v50-lane-write-path.sql:60-71`](../../extension/v50-lane-write-path.sql#L60)); that boolean is part of the function granted to `brain_absorb` ([`extension/v50-lane-write-path.sql:48-55`](../../extension/v50-lane-write-path.sql#L48), [`extension/v50-lane-write-path.sql:159-163`](../../extension/v50-lane-write-path.sql#L159)).

**Failure scenario:** An agent that wants to avoid the amend workflow simply supplies `p_force := true`; no reason, evidence, reviewer, rate limit, or audit event is required. The core integrity promise reduces to prompt-following precisely where a model is correcting itself.

**Suggested fix:** Remove the bypass from the routine agent capability, or require a structured distinctness reason plus an immutable audit row and a constrained approval/role. At minimum, separately grant a force-only function to an operator role and test that a box role cannot invoke it.

### P2 — The bi-temporal schema does not bind invalidation fields to its evidence ledger

**Evidence:** `fact_edges.invalidated_by` is only a foreign key to any message ([`extension/v43-fact-edges.sql:115-137`](../../extension/v43-fact-edges.sql#L115)); `fact_edge_episodes` separately permits support or invalidation rows ([`extension/v43-fact-edges.sql:169-179`](../../extension/v43-fact-edges.sql#L169)). No constraint or trigger requires an expired/invalid fact to have an `invalidates` episode, requires `invalidated_by` to match one, or prevents an invalidation episode from contradicting the timestamps.

**Failure scenario:** An importer bug or privileged writer can expire a fact while pointing `invalidated_by` at an unrelated message, or can create an invalidation ledger row while the fact remains live. As-of recall then presents a belief history whose stated provenance is false.

**Suggested fix:** Put fact state changes behind a single invalidation function/trigger that atomically updates timestamps and inserts/verifies the matching episode row. Add consistency checks for `invalidated_by`, invalidation role, and temporal ordering; reject direct writes for agent roles.

### P3 — SECURITY DEFINER cleanup remains executable by PUBLIC unless a prior schema privilege happens to block it

**Evidence:** `brain_selftest_reap` is `SECURITY DEFINER` and performs `DELETE FROM stewards.nodes` ([`extension/v50-lane-write-path.sql:138-153`](../../extension/v50-lane-write-path.sql#L138)). The migration adds a grant to `brain_absorb` ([`extension/v50-lane-write-path.sql:159-163`](../../extension/v50-lane-write-path.sql#L159)) but never issues `REVOKE ALL ... FROM PUBLIC`; contrast with the explicit revoke for the other definer function ([`extension/v49-memory-lanes.sql:49-50`](../../extension/v49-memory-lanes.sql#L49)). PostgreSQL functions are executable by PUBLIC by default.

**Failure scenario:** Any low-privilege login with `USAGE` on `stewards` can invoke a privileged delete of all rows in its derived lane matching the predictable `brainwrite-selftest-%` prefix, even if it was intentionally denied `DELETE` on `nodes`. The prefix limits blast radius but the privilege boundary is still false.

**Suggested fix:** `REVOKE ALL ON FUNCTION stewards.brain_selftest_reap() FROM PUBLIC` before granting it only to the dedicated capability role; make this a standard SECURITY DEFINER checklist and assert the ACL in CI.

### P3 — The hash dedup key makes fact loss an integrity/availability issue under a deliberate MD5 collision

**Evidence:** The live uniqueness key is `md5(fact_norm)` ([`extension/v44-fact-edges-dedup-hash.sql:40-44`](../../extension/v44-fact-edges-dedup-hash.sql#L40)); the migration acknowledges that a collision causes “spurious dedup” ([`extension/v44-fact-edges-dedup-hash.sql:22-29`](../../extension/v44-fact-edges-dedup-hash.sql#L22)).

**Failure scenario:** A writer able to add facts for the same `(src,dst)` can arrange a chosen-prefix MD5 collision and make a materially different live fact fail as a duplicate. This is a targeted fact-suppression/DoS primitive, not merely a theoretical storage optimization trade-off.

**Suggested fix:** Use a collision-resistant digest generated through an immutable helper (or retain a collision-verifying secondary comparison after index conflict) and make collision handling report/park rather than silently deduplicate distinct text.

## Test and release observations

The v50 selftest checks collision behavior only serially ([`extension/v50-lane-write-path.sql:172-192`](../../extension/v50-lane-write-path.sql#L172)) and its manual verifier documents that it cannot exercise the real remote-identity reap path ([`extension/verify-50-lane-write-path.sql:60-68`](../../extension/verify-50-lane-write-path.sql#L60)). These are not separate findings from the CI/concurrency issues above; they explain why those defects remained invisible.

## Delta vs prior audit

I read the July synthesis only after writing the findings above. It is a
substantially earlier, strategic audit, so several differences are chronology
rather than disagreement.

**It caught that I did not:** the then-existing `target_table` injection seam
(recorded there as fixed), first-run model/provider onboarding, stale version
labels, and the general risk of multiply re-authored SQL bodies. Its warning
that the manifest must be the deploy contract also describes a real historical
class, although `scripts/migrate.sh` now consumes an overlay manifest when one
exists ([`scripts/migrate.sh:197-265`](../../scripts/migrate.sh#L197)).

**This audit caught that it did not:** the current hard clean-install break from
undefined `brain_read`/`brain_absorb` roles; the v49/v50 coverage hole; v50's
add/amend races and force bypass; caller-forgeable lane ordering; INSERT-only
lane attribution; the fact-edge evidence-integrity gap; and recall's
whole-graph/unbounded work factor. Those features postdate the July document,
so their absence there is expected, but they are release blockers now.

---

## Addendum — independent confirmations (2026-08-11, appended by workspace-basecamp)

- **P0 confirmed twice, independently.** basecamp: repo-wide grep — zero `CREATE ROLE`
  in the shipping chain (only `.spec/` prose mentions one). threadchip: fresh clone at
  HEAD (6d3e37a), adding the decisive second fact — **v49/v50 ARE registered in
  `lib.rs` (lines 597, 610)**, which is what makes the missing roles fire fatally
  during `CREATE EXTENSION` rather than sit dormant. No `.sh`/`.yaml`/Dockerfile/
  entrypoint creates the roles either; there is no container-init escape hatch.
- **threadchip's structural read:** this is the *inverse* of its 2026-08-09 find
  (v45–v48 absent from `lib.rs`; a night's work silently unapplied). Same defect
  class, opposite sign: the manifest and the files disagree, and fixing one direction
  exposed the other. Twice now, a clean-machine install found what CI didn't.
- **threadchip exposure check:** none — `brain-drill.sh` pins ref `29b399f`, never
  builds HEAD, fails loudly if the pinned image is absent. Forward risk noted
  separately: catalog assert mismatch if origin's extension version passes the pin.
- **Sol's follow-up recommendation (room msg #793, awaiting Michael's ruling):** hard
  stop on v51 and feature work; P0 + virgin-cluster CI through v50 + both v50 write
  races = one release-critical batch; roles fixed via operator bootstrap/fixture,
  never extension-owned; cheap authority fixes (PUBLIC on SECURITY DEFINER,
  caller-chosen lane, UPDATE origin forgery, agent-accessible p_force) fold into the
  same hardening pass; MD5 + ledger coupling follow; v51 spike resumes only on the
  repaired, concurrency-tested substrate.
