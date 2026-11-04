# BUG-331 a long calm siege keeps the fort locked down for months: no easing, no attack question
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 15b (Earthboat, i3, `runs/run-15b-earthboat/FR-BUGS.md` Runde 4), kernel main 9b6f614
Module: `lua/dfllm/siege.lua` (new long_step, deep_step, step, on.MODE, init, state)

## Actual
Earthboat y385: SIEGE_START #6658 (tick 155285731, 19 invaders) and still SIEGE at #7028 (tick 155370107: 70 game days), 35
visible all the time (SIEGE_STATUS `35 visible, 2 lost`). The goblins stood 37-84 tiles from the citizens and entrances
(INTRUDER `far: 45..84 tiles`, #6762-#6996); none came inside Kern+ (no BREACH), nobody attacked them. SIEGE_DEEP #6846 `worn 56% <
60%; civilians to Tiefe+` held the whole time: the civilians sat in the dry Tiefe+ (`refuge dry`, `Tiefe+ no drink`), drink fell
133 -> 122 days, patient 26629 died of thirst outside it (BUG-330). Nothing ever asked the player to attack.

Root cause: siege.lua (9b6f614) leaves SIEGE only on 2,400 quiet ticks (`quiet_for`, decide :830-838), and quiet needs no visible
invader (threat.lua `a.quiet`): an army that waits in sight holds SIEGE for ever. `deep_step` (:1963) keeps the deep defense while
its reason holds (weak squads do not get stronger in a siege), so the alert stays on the refuge; reflex's lockdown limit
(`confine.max_days`, `kill_lone_intruder`) covers a lone harmless intruder only, never an army.

## Fix
siege `long_step` (config/reflex.json `siege_long`: on true, days 10, near 25): a SIEGE (never a BREACH) with a fresh census,
nobody hostile inside Kern+ and every measured distance of a visible hostile (to O1, every bridge footprint, every citizen outside
Kern+) over `near` tiles is calm; calm for `days` game days in a row eases the siege (persisted `m.siege` lc/lg):
- the deep defense ends unless building destroyers are in sight, and does not start again while eased: the civilians go back to
  Kern+ (its food, drink and patients; seal still audits the burrow), the squads to the inner station;
- DECISION_NEEDED `siege_long` (A, once per easing): days, calm days, nearest hostile, visible, `lifted`, the ready
  `squad.sortie` command at the hostile nearest to O1 (`cmd`, `approve:true` is the player's call), else `no squad to send`;
  wake hint `siege_long_hint`;
- state `wave.lg` (ticks since eased), the brief's intake line `eased N d: calm, civilians in Kern+`.
A hostile within `near` or inside, or no distance measured, ends the easing (kern.log `the eased siege ends after N ticks: ...`)
and restarts the clock; the deep defense comes back on its own reasons. The bridges stay up and the civ alert stays on: the
easing changes the burrow, never the seal. BUG-330's care burrow lets carriers to a patient outside the alert burrow meanwhile.

## Tests
`tests/lua/test_bug331_siege_long.lua` (3 BUG-331 tests: eased + asked once, ends on approach and the deep defense comes back,
off / near army), `tests/test_bug330_331_lockdown.py` (config lint, wake hint, state key). All fail on 9b6f614.

## Live check
Earthboat (SIEGE since tick 155285731, goblins 37+ tiles out): after a kernel reload and 10 calm days kern.log `siege: SIEGE N
days, M calm: no hostile inside Kern+ or within 25 tiles ...`, DECISION_NEEDED siege_long with `cmd`, `dfllm status` intake line
`eased`, the alerts screen on Kern+ instead of Tiefe+. Uncertain: whether Earthboat's distances stay over 25 (INTRUDER lines without
`far` at 79,141,140 and 41,68,140 = 37 tiles: likely yes, but the calm clock restarts on every approach); whether Kern+ passes
seal's audit for the whole population (else seal keeps another burrow).

## Open
No automatic attack: the sortie stays the player's decision (an army of 35 against weak squads is no kernel call). The siege
still ends only when the army leaves (DF) or is killed.
