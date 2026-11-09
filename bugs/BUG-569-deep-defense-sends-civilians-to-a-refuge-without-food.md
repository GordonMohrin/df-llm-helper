# BUG-569 the deep defense sends the civilians to a refuge that holds no food (95 citizens, food 1, 23 beds)
Status: fixed (offline, live-untested)
Severity: critical (about 26 citizens died of hunger and thirst in one 115-day siege)
Found: 2026-11-06, Run 16b i2 Brotherarrow y406 (`runs/run-16b/FR-BUGS.md` "BUG (KRITISCH) SIEGE_DEEP-Refuge Tiefe+ hat 0 Essen", "Hungertod-Welle", "Patient 27722 verdurstet", "Manager Onget validiert 48 Tage nichts")
Module: `lua/dfllm/siege.lua` (`alert_plan`, `refuge_unfit`, `deep_step`), `lua/dfllm/seal.lua` (`refuge_fit`, `fight_rule`/`leave_why`), `lua/dfllm/util/contract.lua`

## Actual
A goblin siege of 36-37 (115+ days): SIEGE_DEEP `army 37 > 3 x 12 soldiers; worn 40 % < 60 %` held all civilians in Tiefe+ (136 tiles, 23 beds for 95 citizens, food 1, drink 23 = the refuge_drink store only) while Kern+ held 4987 food. Eat jobs stood at the stair head for more than 10 days, the hungry died (hunger 100k-132k, DEATHS_PREVENTABLE #9516, DEATHS_3PLUS #9549). `inspect refuge`: choice SIEGE -> Kern+ (ok 1), want Tiefe+ (ok 0), but the status still said `alert Tiefe+ 41 in`.

## Root cause
`siege.lua` `alert_plan` (old line 1189-1191) turned the deep defense into a BREACH ask (`deep and 'BREACH' or mode`), and `seal.lua` `choose` (old line 4049) answers a BREACH ask for the refuge with `held_refuge ... try(refuge, 'WET')`: the WET level counts the drink alone ("no food, bed or size counts"). Tiefe+ had its refuge_drink store, so it passed; food and beds were never looked at, and `fight_rule` then kept it (a held refuge is left only for a reason). Nothing asked whether the refuge could feed the civilians the deep defense sends there for weeks.

## Fix
- `seal.refuge_fit` (seal.lua:4472, public): the refuge exists and holds `refuge.deep_pct` (new, default 90, config/reflex.json) % of the SIEGE need in food (citizens x `food_per_cit`), drink (a wet well covers it) and beds (`bed_pct`, the share asleep at once); returns `fit, why ('food 1<86, beds 18<22'), shares`; nil before the first audit (no verdict, siege asks as before). The audit now stores the beds wanted (`a.bneed`).
- `siege.alert_plan` (siege.lua:1190): in a SIEGE whose deep defense has no building destroyers (`st.deep.bd`, the announced engineers `st.bdx`: they break the line in minutes), an unfit refuge is no civilians' burrow: `deep` is false for the ask, seal gets `SIEGE` and Kern+, the held refuge is left through `release` (now a reason text: `Tiefe+ cannot hold the civilians (food 1<86)`, which REFUGE_SWITCH carries; `true` keeps the BUG-331 text). The squads still hold the core station (`apply`: posture CORE), the bridges close as before.
- `deep_step`: SIEGE_DEEP says `the civilians STAY in Kern+ (Tiefe+ cannot hold them: ...)` and carries `unfit`; a change of the verdict is news (cadence token).
- Not changed: a BREACH keeps the refuge by its own rule (BREACH level, REFUGE_STOCK names what is missing, BUG-464); `refuge.deep_pct` 0 turns the check off.

## Tests
`tests/lua/test_bug569_570_starve_traffic.lua` (1): the deep defense by army, a refuge that cannot feed them: the alert stays on Kern+ (old: Tiefe+), SIEGE_DEEP says so, posture CORE, O1 and B1 up, nobody crushed or shut out; the refuge stocked: they go down. `tests/lua/test_bug569_572_seal.lua`: `refuge_fit` (no food, food at 67 % / 90 %, `deep_pct` 0 / 60 / 100, beds), `alert_burrow` with a release text leaves the held refuge (REFUGE_SWITCH `released` + the text; old: kept), `alert.ref.fd/fn` in the state. `tests/test_bug569_572_f36.py` (config key, schema).

## Live check
`dfllm cmd inspect what=refuge` in a siege with a foodless Tiefe+: `alert` on Kern+, SIEGE_DEEP `STAY in Kern+`; after `plan` brought the refuge food store the same siege sends them down. Watch that the squads at the core station still hold when the civilians stay in Kern+ (the army ratio case).
