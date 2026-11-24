# BUG-828 Leiter hint "N freie weapon im Lager, die Soldaten tragen sie nicht" counted picks, axes, forbidden and reserved items
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-24, Run 17 i2 ("92 freie weapon"), i1 ("122"), i3 ("3"): the number is `state mil.free.weapon`, every free metal item of the WEAPON vector (military loot census), while the kernel's own census (`weapon 51/6 ok`, g_weapon) and `inspect military` ("free usable: weapons 44 ...; lying free but out of reach: 25 bin, 13 far, 12 reserved, 18 stuck") are far smaller; i3's 4 free weapons were picks and axes kept for the civilians
Module: `dfpilot/leiter.py` `blocked_evidence` (kind `free`)

## Actual
The BLOCKIERT line told the player that weapons lay unworn in stock and sent them hunting for a fetch bug, while the real binder was the growth gate (squad size, 0 real melee weapons).

## Fix
The hint keeps its number but states what it counts ("mit Hacken/Spitzhacken, gesperrten und reservierten"), drops the claim that soldiers could take them, and for weapons appends the growth gate's own text when `ready.gh.halt == 'squad'` ("Wachstums-Tor squad: <need>, Trupp A x von y bewaffnet" from `mil.kit.sqw/sq`, BUG-829).

## Tests
`tests/test_neu1_wertung_leiter.py::test_blocked_evidence_free_weapon_truthful`.

## Live-Erwartung
1. `python -m dfpilot leiter` on i2/i3 prints "BLOCKIERT Ruestung I: N freie weapon im Lager (state mil.free: ...); Wachstums-Tor squad: first squad: ..." and never "die Soldaten tragen sie nicht".
