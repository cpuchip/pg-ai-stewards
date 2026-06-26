# Proposal: Rigor Mode v2 — the verify pass

**Status:** ratified-in-design; v2 ships the contract + critic layers (`66-rigor-verify.sql`); the
deterministic oracle layer is operator/overlay content (schema-specific). Pairs with `65` (Rigor Mode v1).

## The finding that shaped v2

v1 was tested against a real curated bucket. The result reframed the problem:

- **Citations are not the gap.** Every observation citation in the critiqued output *resolved* — a
  "does this id exist" check passed 100%. The failure was **claim-to-evidence fidelity**:
  - a **single record** (one call, one interview, one registry row) generalized to a region/segment/population;
  - a **single-question subset** (e.g. "of the N who answered question X in one wave, P% chose Y") restated as
    a flat **population statistic** with no denominator;
  - a citation that **resolves but describes a different thing** — a different place, a competitor's product,
    a different scenario than the claim.
- **A prompt rule is necessary but not sufficient.** With v1's "verify the specific claims first" loaded, a
  strong model *still* tagged a single-record finding "well-supported" and *still* rolled single records up
  into a "recommended regions" list. The distortion re-enters at the **orient/interpret** step. Rigor has to
  be **structural — a check that re-derives fidelity — not a request that the model be careful.**

## The three layers (defense in depth)

| Layer | What it does | Where | Enforcement |
|---|---|---|---|
| **1. Contract** (`research-rigor` v2) | Ground-or-flag; re-read each cited source before shipping; never generalize a single record / never state a subset as a population stat; reconcile specifics; calibrate; separate observation from recommendation | `66` §1 (skill) | prompt — necessary, not sufficient |
| **2. Critic gate** (trajectory-critic) | Sees the trajectory (retrieved vs claimed); fails over-generalization, subset-as-population, over-confident tags, wrong-source citations — even when a citation is present | `66` §2 (the `grounding` dimension, sharpened) + `64` auto_critique | standing, post-completion — catches what the contract misses |
| **3. Deterministic oracle** (optional, bucket-specific) | A tool the agent must call before shipping: re-fetch each cited record, return its actual claim + a computed caveat (`sample_n<=1` → "single record, don't generalize"; `measure_basis=segment` + wave → "subset, not a population stat"; not-found → "fabricated") | operator/overlay (schema-specific) | strongest — the model confronts ground truth it cannot soften |

Layer 3 is the most effective but cannot be core: it needs a structured observation layer (a per-record
`sample_n` / `measure_basis` / `confidence`). A bucket that has one should add it; the pattern:

```
fidelity_check({refs:[ids the answer cited]}) -> for each: {found, claim, sample_n, measure_basis,
  confidence, caveat}   -- caveat computed deterministically from the structured fields
```
and the contract's rule 2 requires calling it and honoring every caveat. (Reference implementation lives in
an operator overlay, not core, because the columns are bucket-specific.)

## Why layer 2 is in core and layer 3 is not
Layer 2 (the critic) judges fidelity from the **trajectory itself** — what the agent retrieved vs what it
finally claimed — so it is bucket-agnostic and ships in core. Layer 3 reads a record's **structured
provenance columns**, which only some buckets have, so it is operator content. Together: the contract asks,
the oracle (if present) makes the ground truth unavoidable, and the critic catches the residue.

## Open / next
- **Pre-emit vs post-hoc.** The critic (layer 2) is post-completion — it grades and feeds the
  self-improvement loop; it does not block the first answer to the user. A pre-emit gate (hold the answer
  until fidelity passes) is stronger but needs the chat loop to support a verify-then-emit step. The oracle
  (layer 3) is the inline pre-emit check where a bucket supports it.
- **Model strength matters.** A stronger reasoning model honors the contract + caveats more faithfully;
  a weaker one needs the oracle/critic more. Calibrate which layers you run to the model you route to.
