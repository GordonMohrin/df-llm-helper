# BUG-348 a single far "harmless" goblin holds the lockdown and the siege again after every invasion; the sortie offer says nothing about the armour
Status: partly fixed (offline, live-untested): a static far cleared intruder is cleared again when the newcomer is gone, the
calm clock restart is logged, every sortie offer says whether it is recommended (worn vs sortie.worn 80 %); open: the 26-40 tile
army that never stays beyond siege_long.near
Severity: high
Found: 2026-11-04, Run 15 (i2 Guildcleans y386-390, `runs/run-15-guildcleans/FR-BUGS.md` Runde 2 "Sortie gegen weit entfernten
Einzel-Goblin" and "Fix-Runde 15 live"), kernel main 14ff5a3
Module: `lua/dfllm/reflex.lua` (far_scan, was :677-686; new rc_note / rc_scan), `lua/dfllm/siege.lua` (long_step),
`lua/dfllm/military.lua` (new sortie_advice), `dfpilot/wake.py` (armour_note)

## Actual
i2 Guildcleans (r15-guildcleans-site97):
- Goblin 24649 stood at 1,136,117 (101-114 tiles out) from y386 to y390 without moving. LOCKDOWN_END #6764 (tick 156114369)
  `confinement limit of 10 days reached ... harmless: inv 24649 GOBLIN at 1,136,117`, after that the same limit end three more
  times, each with only this goblin: #7184 (ticks 15632 = 13 days), #8132 (14786), #8521 (13459).
- Each time a new invasion came, kern.log said at the very tick of the SIEGE_START `reflex: another hostile is in sight: 1 cleared
  harmless intruder count again` (156235795, 156991564, 157294068, 157450667). The newcomers died or left within hours
  (`siege again (bridge_stuck): ... 1 visible, 1 invaders` 3,000-4,000 ticks later), and the lone static goblin held SIEGE and
  lockdown until the next 10-day limit. FR-BUGS: "Lockdown-Ende bei 'lone harmless' schon nach wenigen Tagen statt 173 von 10".
- The 173 days were the army siege before (SIEGE 155926277-156116788, 26-40 visible). BUG-331's easing was loaded (reload
  153873559, fix14-lockdown merged before) and fired only at 156112333 (`SIEGE 155 days, 10 calm ... nearest 28, 1 visible`) once
  the army had gone: the army stood 26-40 tiles out (INTRUDER #6070 `dist 26`, FR "30-40 Tiles"), so its distance kept touching
  siege_long.near 25 and the calm clock restarted without a word (long_step logged only the end of an easing).
- DECISION_NEEDED kill_lone_intruder #7150 and siege_long #7189/#8137 offered `squad.sortie` with a ready command and no word on
  the armour; the player held back by Gordon's 80 % rule (worn 61 %, later 43 %).

Root cause: reflex.lua far_scan (14ff5a3 :677-686, BUG-065): any hostile in sight that is not on the cleared list drops every
cleared harmless intruder from `far.ids/hl` for good; nothing ever puts it back when the newcomer is gone, so the static far
goblin counts as an invader again (threat.assess `inv`, siege quiet never comes) until reflex's confinement limit clears it 10+
days later. siege.lua long_step (:2094) restarts the calm clock silently.

## Fix
- reflex: the cleared ones a newcomer makes count again are noted (`m.reflex` `far.rc`: id, where it stood, ig). Once no hostile
  but them and the still-cleared ones is in sight, each that stands within `RC_MOVE` (2) tiles of that spot and is not near
  (lockdown_near of a citizen or an entrance, or inside) is cleared again at once (kern.log `no other hostile in sight: 1 harmless
  intruder that stood still cleared again: inv 24649 at 1,136,117 (114 tiles)`); threat counts it for nothing, the SIEGE ends by
  its quiet clock (2,400 ticks) and the lockdown by its own. One that moved or came near stays counted (kern.log names it); one
  out of sight for 2,400 ticks is forgotten. Persisted across a reload.
- siege: a calm clock of a game day or more that restarts is a kern.log line (`siege: the calm clock restarts after N of D days:
  a hostile 22 tiles from the fort (near 25)`), so the next long siege says why it is not eased.
- military `sortie_advice(key)`: the squad's worn % against `sortie.worn` (80, the threshold the gate sortie refuses below);
  DECISION_NEEDED kill_lone_intruder, intruder_sortie and siege_long carry `worn`, `need`, `rec` and say `sortie (not)
  recommended: worn W% >= / < 80%` before the command (kern.log keeps the whole sentence; d.q is cut at 200 bytes); the wake hints
  say `sortie NOT recommended: worn 43% < 80%; wait` or `sortie recommended`.

## Tests
`tests/lua/test_reflex.lua` (+2 BUG-348: cleared again when the newcomer is gone; one that moved stays counted),
`tests/lua/test_bug331_siege_long.lua` (+1 calm clock restart line, +1 check: worn/need/rec on siege_long),
`tests/lua/test_military.lua` (+1 sortie_advice), `tests/test_bug348_sortie_advice.py` (2: the wake hints). All fail on 14ff5a3.

## Live check
i2 Guildcleans with 24649 still at 1,136,117: at the next invasion `count again`, then after the newcomer is gone `cleared again`
and SIEGE>RECOVERY quiet within about 2 days, no LOCKDOWN_END limit; DECISION_NEEDED kill_lone_intruder/siege_long with `worn`,
`rec`; a long siege kern.log `the calm clock restarts after ...`.

## Open
- An army that keeps standing 26-40 tiles out is still never calm with siege_long.near 25 (now visible in kern.log): whether
  `near` should be lower, or a static army should ease, is a design call (the easing lifts the deep defense).
- The sortie stays the player's decision; the kernel only says whether the armour meets the rule.
