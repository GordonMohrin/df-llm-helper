# BUG-578 The sortie offered against cave dragons says only "worn 85 % >= 80 %, recommended"
Status: fixed (offline, live-untested)
Severity: medium (the player can send three soldiers against a wall of dragons on the armour rule alone)
Found: 2026-11-06, Run 16c i3 Sealcertain y405-y409 (`runs/run-16c/FR-BUGS.md`: DECISION_NEEDED `siege_long` / `kill_lone_intruder` with `sortie recommended: worn 85% >= 80%` and no word on whether the squad can win)
Module: `lua/dfllm/military.lua` (`sortie_advice`, `foe_weight`), `lua/dfllm/siege.lua` (`long_step`), `lua/dfllm/reflex.lua` (`intruder_sortie`, `lockdown_long`, `lone_cmd`), `dfpilot/wake.py` (`armour_note`)

## Root cause
`military.sortie_advice(key)` knew only the squad's worn % against `sortie.worn` (BUG-348). The siege sortie itself refuses a squad whose combat value is under `foes x sortie.foe_cv`, but the offer never made that comparison.

## Fix
`sortie_advice(key, foes)`: with the ids of the hostiles it would face, each weighted by its census body size in dwarves (60,000 cm3, 1 to 12) times `sortie.foe_cv`: `ours` (squad cv), `est`, `foes`, `odds` = good (cv >= 1.5 x est) / even / poor (>= half) / hopeless. Poor and hopeless odds are never recommended, whatever the armour says. The DECISION_NEEDED offers (`siege_long`, `intruder_sortie` / `lockdown_long`, `kill_lone_intruder`) pass the target (siege: the hostiles within `sortie.near` of it) and carry `odds`, `ours`, `est`, `foes`; the text says `odds hopeless (cv 100 vs ~480)`; the wake hint (`armour_note`) repeats it.

## Tests
`tests/lua/test_military.lua` (BUG-578: good / poor-hopeless odds, the cap at 12, no foes = the old answer, `foe_weight`), `tests/test_bug577_580_f37.py` (wake text and schema).

## Live check
`siege_long` q: `sortie recommended: worn 85% >= 80%, odds good (cv N vs ~M)` or `sortie NOT recommended: worn 85% ok, but, odds poor ...`.
Open: the weight by body size is a heuristic, the siege sortie itself still compares cv with `foes x foe_cv` (unweighted) when it starts.
