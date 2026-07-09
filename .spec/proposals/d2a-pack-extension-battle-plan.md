# D2A battle plan — packs as real Postgres extensions (#319)

**Written 2026-07-09 at the close of the foreman/voice-forge session, for the
~3-hour Fable window before Sunday.** Purpose: start that window at full speed —
this is the spec, the constitution, and the test plan, pre-agreed. Michael's
framing: "work out those mechanics and get them tested."

## The proof target: `stewards_companion`

Package the companion pack (forge.sql + companion.sql + steward-tools.sql) as a
real extension. It is the best possible proof subject because it exercises every
mechanic packs will ever need: two schemas (forge, companion), a table with USER
DATA (companion.reminders — survives upgrades, must survive dump/restore), a
pipeline row, tool_defs rows, config mutations (the allowlist), seeded intent,
and a deliberate uninstall posture (forged tools outlive the pack).

## The mechanics to work out (the actual session content)

1. **Plain-SQL extension, no pgrx.** Packs are pure SQL — so this is
   `stewards_companion.control` + `stewards_companion--0.1.0.sql` in SHAREDIR.
   No Rust, no cargo. The core stays pgrx; packs stay SQL. Decide once: this IS
   the pack packaging story (pgrx only if a pack ever needs native code).
2. **`requires` + schema behavior.** Control file: `requires = 'REPLACE_WITH_CORE_EXT_NAME'`
   (⚠ FIRST TASK of the window: confirm the core extension's exact name from
   extension/*.control — do not trust memory), `relocatable = false`,
   `schema = companion`? No — the pack creates TWO schemas itself; keep
   `relocatable = false` with explicit `CREATE SCHEMA` in the script and no
   `schema =` line. Verify CREATE EXTENSION ordering: core first, error message
   quality when it's missing.
3. **Membership vs DATA — the subtle one.** Objects created by the extension
   script belong to the extension (dropped on DROP EXTENSION). But:
   - **Rows are not objects.** tool_defs INSERTs, config_set calls, the intent
     row, the pipelines row — these survive DROP EXTENSION unless the script
     pairs them with an uninstall hook. Decide the posture per row-kind and
     write it down in the control-file comment: tool_defs rows = leave-and-
     deactivate? pipelines row = leave (history references it)? allowlist
     config = SHRINK on drop (security-relevant!) — this one likely needs an
     event trigger or documented manual step. Get honest about what DROP
     EXTENSION can and cannot clean.
   - **`pg_extension_config_dump('companion.reminders', '')`** so user
     reminders survive pg_dump/restore. Test it (dump/restore in scratch).
4. **Upgrade path.** Ship `--0.1.0--0.2.0.sql` as a real proof: 0.1.0 = forge +
   companion; 0.2.0 = + steward-tools (this matches actual history!). Prove
   `ALTER EXTENSION stewards_companion UPDATE` applies only the delta and that a
   fresh `CREATE EXTENSION` lands at 0.2.0 directly (default_version).
5. **Idempotence collision.** The live DB already has these objects applied as
   loose SQL. Mechanics for adopting them:
   `CREATE EXTENSION ... ` will fail on pre-existing schemas — the adoption path
   is `ALTER EXTENSION ... ADD` scripts or (cleaner for the proof) demonstrate
   on VIRGIN scratch only, and write the live-adoption recipe as a documented
   follow-up. Don't burn window time force-adopting live.
6. **Ship path.** Where the files land: Dockerfile COPY into
   `$(pg_config --sharedir)/extension/`; packs/ keeps the loose-SQL apply as the
   dev path (README documents both). No sha-ledger involvement — extensions
   version themselves; that's the point.

## The oracle (write FIRST in the window, then grind)

Scratch-container script, exit 0 = green (`packs/companion/test-extension.sh`):
1. Virgin pg + core extension → `CREATE EXTENSION stewards_companion VERSION '0.1.0'`
2. smoke.sql subset for 0.1.0 (forge happy+refusals, reminders, bell)
3. `ALTER EXTENSION stewards_companion UPDATE TO '0.2.0'` → steward-tools smoke
   (unstick refusals, model_health shape, forge_start rate guard)
4. Fresh second DB → `CREATE EXTENSION` straight to 0.2.0 → same smoke
5. `pg_dump`/restore → reminders row survives (config_dump proof)
6. `DROP EXTENSION` → objects gone; assert the DOCUMENTED survivors list exactly
   (nothing more, nothing less — the posture from mechanic #3, made executable)

Grindable (scratch resets) + oracled = the window can iterate fast.

## Constitution (goes to any staffed worker AND the checkers)

1. The core pgrx extension is untouched — packs never modify extension/.
2. Live pg is never restarted and never gets the experimental extension; all
   proofs on scratch containers.
3. Every mechanic above has an executable assertion in test-extension.sh.
4. The loose-SQL apply path keeps working (CI parity: same objects either way —
   diff `\d+`-style catalogs between loose-apply DB and extension DB).
5. README gains an "install as extension" section only after the oracle is green.

## Suggested window shape (foreman discipline, Fable-lean)

- **Pre-window (cheap seats, zero Fable):** a sonnet worker can scaffold the
  mechanical skeleton from this plan — control file, split of existing SQL into
  0.1.0/0.2.0 scripts (verbatim moves, no edits), Dockerfile COPY, empty
  test-extension.sh with the six stages stubbed. Blind-check: files exist, SQL
  byte-identical to sources, nothing edited.
- **Window hour 1 (Fable):** mechanics #2/#3/#5 decisions live on scratch —
  the parts that need judgment.
- **Hour 2:** oracle green end-to-end, including the dump/restore and DROP
  survivor assertions.
- **Hour 3:** catalog-parity check (constitution #4), README, PR for the Hinge,
  and if time remains: extract the generic recipe (`docs/packs-as-extensions.md`)
  so future packs are mechanical.

## Open questions to settle in the window (not before)

- Whether DROP-time allowlist shrinking is worth an event trigger or a
  documented manual step (leaning: documented step + a `companion_uninstall()`
  helper the script installs).
- Version naming: track pack versions independently (0.x) vs mirror OSS_VERSION.
- Whether `stewards_workspace` (the overlays pack from the original D2A wording)
  becomes proof #2 using the recipe, or waits for real need.
