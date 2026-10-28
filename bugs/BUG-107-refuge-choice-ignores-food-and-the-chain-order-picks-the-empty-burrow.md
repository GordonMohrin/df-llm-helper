# BUG-107 The civ-alert burrow is chosen without looking at the food: WET takes the first burrow with a well, the held burrow is never left for a fed one, a fed burrow that is too small is never offered, and nothing keeps a floor of food and drink inside a refuge
Status: fixed in the M2 commit (offline, live-untested): level FED, the best supplied burrow at WET, REFUGE_FAIL with the counts (also for the wanted burrow), REFUGE_SWITCH `supply`, the standing floor REFUGE_STOCK
Severity: critical (Run 14 y641: 37 dead in hours during a siege)
Found: 2026-10-24, Run 14 (Trussroads), game session note 78
Module: `lua/dfllm/seal.lua` (`burrow_audit`, `rate`, `choose`, `leave_why`, `alert_burrow`, `RF.floor`), `config/reflex.json` (`refuge`)

## Actual
Note 78: during a SIEGE the citizens were confined to Kern+ (food 1, drink 0, need 63 each) while Innen+ held food 12100 and drink 3156
but failed the area (56 tiles < 63) and the beds (6 < 16). REFUGE_FAIL said `Kern+: food 0<86` several times and nothing followed.
The note reads `inspect refuge` `choice.SIEGE.want = Kern+` as "hard-coded Kern+".

## Cause (proven from the code at 32994bb; what stays open is under "Not decided offline")
1. **`choice.<mode>.want` is the default, not the pick.** `want` is the caller's default (seal.lua:3106-3108, `want = want or (mode == 'BREACH' and refuge
   or kern)`); the pick is `choice.<mode>.burrow` (seal.lua:5211-5214 `ch`). At the SIEGE and SOFT levels a burrow must pass `a.sup`
   (seal.lua:3083: tiles, drink and food all met, `burrow_audit` 601-620), so Kern+ with food 1 was already refused there. The note's
   reading of `want` is refuted; the defects below are what the code proves.
2. **A fed burrow that lacks the area is offered at no level.** `a.sup` contains the tiles (`burrow_audit` adds `N tiles<M` to the same
   list, seal.lua:606-620): Innen+ with 56 of 63 tiles fails SIEGE and SOFT although it holds all the food and drink. HOLD (seal.lua:3134)
   needs `a.room` (tiles again) and a lockdown. Only WET could take it.
3. **WET counts the drink only and takes the first burrow of the chain.** `rate(..., 'WET')` (seal.lua:3075-3080) asks `a.wet` (drink >= need
   OR a built well), never the food; `choose` takes `for _, n in ipairs(chain) do if try(n, 'WET') then return r end end` (seal.lua:3135),
   and the chain starts with Kern+ (seal.lua:3127-3130). Kern+ with a well and food 1 passes WET and wins over Innen+ with food 12100.
4. **The held burrow is never left for supplies.** In SIEGE/BREACH `fight_rule` (seal.lua:3224) keeps the burrow the alert stands on
   unless `leave_why` (seal.lua:3205-3222) finds gone / dry / unseparated / breached / unreachable / window. `dry` is marked only after
   citizens went thirsty or hungry there (siege.dry). A Kern+ without food stayed the alert's burrow until people were already dying.
5. **A depleted pick that is the wanted burrow says nothing.** REFUGE_FAIL is emitted only for `pick ~= want` (seal.lua:3336); at WET with
   Kern+ the wanted and the only candidate, nothing was reported, and `alert.ok` read 1 (`publish`: `ok = pick == want`).
6. **Nothing keeps a floor.** The one proactive check, `supply_check` (seal.lua:1124-1161), fires SUPPLY_OUTSIDE only when more than 50 % of
   a class lies outside Kern+/the refuge, at most every 28 days and 30 minutes, with a hint but no per-burrow floor.

## Fix
- `burrow_audit` records `fneed` (the food need) and `fed` (wet and food >= need). New level **FED** (after SIEGE and SOFT, before HOLD):
  separated, reachable, no hostile, >= `breach_tiles`, `fed`; the area and the beds are waived. WET takes the **best supplied** burrow of the
  chain (`try_best`: food share, then drink share, chain order on a tie); `r.short` says that even that one lacks food.
- REFUGE_FAIL for a FED pick says `<pick> has the food and drink (food 40/30, drink 40/30) but not the area or beds`, for a short pick `no
  burrow has its food and drink: confining to the best supplied, ...`; new optional field `sup` (the counts of the pick and the others, <= 120
  bytes); a short pick that is the wanted burrow is reported too (cadence: once per episode, again with news). `inspect refuge` carries
  `fed`, `fneed`, `dneed` per burrow.
- `leave_why` gets the reason **supply** (REFUGE_SWITCH `why` supply): the held Kern+ / Innen+ is under `refuge.supply_switch` % (50) of the SIEGE
  need in food or drink while the free pick holds both. Never out of the refuge (its days without counts are the deep defense's plan,
  `window` ends them). Key `refuge.supply_switch` (0-100, 50; 0 = the old rule).
- **Standing floor** (`RF.floor`, run with every audit): Kern+ and the refuge keep `refuge.floor_pct` % (100) of the SIEGE need (citizens x 1
  each; a wet well covers the drink) for forts of `refuge.floor_pop` (30) citizens or more, in PEACE/ALERT/RECOVERY. Under it **REFUGE_STOCK**
  (A) names the burrow, the counts, the fort's own total and the existing command (`bp.place` stockroom with `p.burrow`, `refuge_drink` for the
  refuge's drink), once per episode and again only with news (util/cadence, a game week and 30 minutes). No actuator of its own.
- Not changed: SIEGE/SOFT order, HOLD for a lockdown without a fed burrow, the BREACH/DEAD levels (no counts for `breach_days`), a fed Kern+
  stays first and silent.

## Not decided offline
- **What the live pick was at the time of the 37 deaths.** Live, read-only: `inspect refuge` of that moment (`choice.SIEGE`, `choice.LOCKDOWN`:
  `burrow`, `level`; `burrows[Kern+]`, `burrows[Innen+]`: `food`, `drink`, `wells`, `wet`, `tiles`, `why`), REFUGE_FAIL `fallback`/`level` and
  REFUGE_SWITCH in events.jsonl, and `alert.burrow` in the state. If `fallback` was Innen+ the citizens were sent there and the deaths have
  another cause (reach: the path from Kern+ to Innen+, the beds; `inspect reach`).
- Whether Innen+ was a repaint of the whole interior (seal paints it when Kern+ fails, `repaint` 7 days) that had fewer tiles than the
  citizens at that moment; `kern.log seal: Innen+ painted with N of M interior tiles`.
- Whether the stockroom command REFUGE_STOCK names finds a site in a fort of 80 (`bp sites stockroom`).
- The defaults are judgment calls no live number decides offline: floor 100 % of the SIEGE need (1 food and 1 drink per citizen), forts of 30 or
  more, a siege leaves a burrow under 50 % of its need. A fort of 80 that keeps its stock in a hall outside Kern+ gets one REFUGE_STOCK a week at
  the most (cadence) until the stockroom stands.
- During a fight nothing can be built (the runner gates infra projects), so REFUGE_FAIL's counts and the switch are all the siege can do; the
  floor is meant for the weeks before.

## Tests
`tests/lua/test_m2_refuge.lua` (7: the note-78 fixture with a well, food 1 and a too-small fed Innen+; no burrow fed; the only candidate
short; a fed Kern+ first and silent; REFUGE_SWITCH supply and `supply_switch` 0, never out of the refuge; the floor in PEACE with the stockroom
command, once; young fort, `floor_pct` 0, a fight, a well, the refuge). All fail on 32994bb.
