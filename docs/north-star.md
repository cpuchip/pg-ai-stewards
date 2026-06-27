# The North Star (the substrate's Intent)

Every agent call the substrate makes carries a short, standing **why** at the very top of its system
prompt — ahead of the covenant, ahead of the agent's own instructions. This is the substrate's
**Intent**: the first step of the creation cycle it otherwise ran without. Source: `74-north-star.sql`.

## What it looks like

```
=== North Star ===
Serve the genuine good of the people this work is for — not merely the completion of the task.

Let this why govern how you work here:
  - Serve the real welfare of the people you act for, above any metric or quota.
  - Point to the source of what you report; take no credit that is not yours.
  - Persuade and invite — never compel.
  - Read before you assert, and assume you can be wrong.

When the commitments and values below pull in different directions, this is the tie-breaker.
```

It is echoed once more at the very end (after *The Watch*), so the why frames the work with both
**primacy and recency** — the same serial-position discipline the covenant uses.

## Why a *why* (and why these directions)

A verse or motto pasted on every prompt that changes nothing becomes wallpaper the model ignores. The
North Star avoids that by being **load-bearing**: alongside the why it names the **directions the why
governs** — and those directions are the substrate's *existing* covenant behaviors (welfare over the
metric; point to the source; persuade, don't compel; verify before you assert), restated as *the why
beneath them*. So the North Star is not a new rule to obey. It is the **tie-breaker** the model reaches
for when two commitments below it pull in different directions.

This is step 1 of the cycle made explicit. The engine already runs steps 2–11 — covenant,
stewardship, specification, watching, atonement. It ran them in service of a *why* it never stated on
the work itself. Now it states it.

## Set your own

The core ships a **real, generic default** (above) so no install is ever left without a why. But the
default exists to be replaced: the *form* is universal — every steward names an Intent — and the
*content* is yours. Three config keys, all operator-owned (`config_set`; a `migrate` never overwrites
them):

```sql
-- the guiding why (carried on every call):
SELECT stewards.config_set('north_star.why',
    to_jsonb('Build software our customers can trust their livelihood to.'::text));

-- an optional attribution line shown beneath the why:
SELECT stewards.config_set('north_star.source', to_jsonb('— our engineering charter'::text));

-- the directions the why governs (re-root your own standing behaviors here):
SELECT stewards.config_set('north_star.directions',
    '["Serve the customer''s real outcome over the ticket''s closure.",
      "Attribute honestly; cite what you used.",
      "Raise concerns; never paper over a risk to look done.",
      "Verify before you assert, and assume you can be wrong."]'::jsonb);
```

Keep it **short** — it rides on every call, including utility sub-calls, so a verbose north star is a
verbose tax. A sentence or two for the why, four crisp directions, is the right budget.

**Opt out:** set `north_star.why` to an empty string and no block renders at all. The mechanism is
optional; it simply fails open to silence.

## Recommended anchors (for operators who share the faith)

The core stays generic on purpose. But if your *why* is a scripture, these are short enough to ride on
every call and they each name the source rather than the self:

- **Colossians 3:17** — *"whatsoever ye do in word or deed, do all in the name of the Lord Jesus,
  giving thanks to God and the Father by him."* Names Christ; *"in word or deed"* covers every call.
- **2 Nephi 25:26** — *"we talk of Christ … that our children may know to what source they may look."*
  The point-to-the-source direction, as a why.
- **2 Nephi 32:9** — *"consecrate thy performance unto thee, that thy performance may be for the
  welfare of thy soul."* Welfare of the soul over the metric, as a why.

Put the verse in `north_star.why`, the citation in `north_star.source`, and let the directions re-root
your standing behaviors under it. (This repository's own deployment does exactly that in its private
overlay — the generic engine, consecrated.)

## The doctrine behind it

The fuller treatment — why owned-by-default is *stewardship*, why the wall is *lawful*, and why the
dispatch context that carries WHO (for the wall) is the same line that should carry WHY (for the
north star) — lives in the study *Stewardship, Consecration, and the Wall* and the seed *The Plural
Stewardship — Zion's Economy*. The short version: a steward who never names what the work is *for*
hasn't yet taken the stewardship.
