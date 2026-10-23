# BUG-052 Siege 14: `on_station=0`, soldiers 16 -> 6 and 20 -> 9; the report cannot say why the squads were not on station
Status: fixed in 63191ea and 927d14e (offline, live-untested; the cause itself is not decided offline): "on station" counts within
`station_r` + (n-1)//4 tiles of the station, `kpi.off` names why a soldier is off it, the siege episode keeps the soldiers it
started with, the best on-station count and when half stood (SIEGE_END `sol0`/`soldiers`/`on_station`/`on_t`, SIEGE_STATUS
`off`), and a squad still under half 1,800 ticks in gets its posture issued again (once logged; never over a wave, a sortie or a
kill order)
Severity: high (wrong decision: the report said 0 on station and nothing could say which of six causes held; losses of 24 and 36
citizens in one fort)
Found: 2026-10-23 (note 23 of bugs/RUN11-offene-bugs-und-FR.md and "the earlier sieges"), Run 11 Kilrudrabed, siege 14 y497 summer
d23-29, from the game session
Module: `lua/dfllm/military.lua` (`compute`, `M.station_radius`, `off_reason`, `M.conf`), `lua/dfllm/siege.lua`
(`station_watch`, `off_text`, `go`, `status`), `dfpilot/schema.py` (SIEGE_END, SIEGE_STATUS)

## Actual
Note 23: "Siege 14 (y497 summer d23-29): 24 losses (pop 49 -> 26; 'on_station=0', so no soldiers at the station). The two open
entrances 113,73,143 and 115,73,143 were open again; recall '10 of 30 still outside Tiefe+, 10 cannot come'." Soldiers 16 -> 6
and 20 -> 9 in two sieges. The brief shows `station N` from `mil.on_station`.

## Expected
The squads stand at their stations when the siege comes, and when they do not the report says which of the possible reasons
holds.

## Cause (what the code at f17e2b3 can and cannot prove)
Proven from the code - four ways `on_station` reads 0 or the squads are not there:
1. **The KPI is narrower than DF's formation.** `military.lua:1807`: a soldier counts only on the station's level and within
   `M.STATION_R` = 3 tiles (Chebyshev). DF spreads a squad over the tiles around the station point: 10 soldiers in a corridor
   or a relocated station (BUG-032 moves a station to the nearest plain floor clear of the bridges) stand in a line, so a
   squad at its post reads far below its size. It also gated the intake waves (`siege.lua` muster: `on >= sol` or half) -
   a squad that stood "off" aborted waves with `x of y soldiers on station`.
2. **A station that is not found counts as 0 without a word.** `compute` took `spos = rt.station[sp.key]` (1797) and skipped
   the count when it was nil (no manifest station for the posture: a reclaimed fort, a fort that never built fortcore stage 2);
   the squad then keeps `Constant training` or `Ready` without an order (`apply_squad`, 1343/1363) and the report was 0.
3. **The kit.** The monthly `uniform-unstick --drop` (BUG-050, `military.lua:1898`) put soldiers into PickupEquipment for
   weeks; a soldier on his way to the armory is not at the station, and the kit he lacks is the `worn 36 %` of the note.
4. **No pre-positioning before the siege.** `reflex.lua` makes no call into `military` (0 hits); the posture changes only in
   `siege.apply` on the mode (`POSTURE`, `siege.lua:57`: PEACE = TRAIN). An ARRIVAL lockdown in PEACE keeps the elite on
   `Off duty` in months 9-11 (`off_season`, 1322-1327) and the militia off the stations all year; they walk when SIEGE starts,
   and a squad outside the doors is shut out by the raise (`siege.raise`, T+600).
Not provable from the code: which of them held in siege 14, and whether DF itself kept the squads from the station (a station
behind a raised bridge, a path blocked by the army). No event recorded the number over time: SIEGE_STATUS (C) carried one
`on_station` per 600 ticks and SIEGE_END none.

## Fix
- **`military.station_radius(n, base)`:** `conf.station_r` (3, 1-10) + `(n - 1) // 4` tiles: 10 soldiers stand up to 5 tiles
  away. A squad of 1-4 keeps 3.
- **`kpi.off`** (left out when empty; `K.call('military', 'kpi')`): `{equip, hurt, level, far, nost}` counts the soldiers who are
  off their station: `equip` a PickupEquipment job (BUG-050), `hurt` a wound / unconscious / thirsty or hungry past
  `SIEGE_THIRST`/`SIEGE_HUNGER`, `level` another z, `far` the same z beyond the radius, `nost` the posture names a station for the
  squad and none was found.
- **siege.lua:** the episode keeps `sol0` (soldiers at the first look), `onmax` and `ont` (ticks from the start until half
  stood, -1 never), read every `STATION_LOOK` (100) ticks (`station_watch`, persisted in `m.siege`). SIEGE_END: `sol0`,
  `soldiers`, `on_station` (the best seen), `on_t`; its text `...; soldiers 16 -> 6, on station 9 (half after 340 ticks)` or
  `(never half)`. SIEGE_STATUS: `off` = `equip 5, far 2`.
- **Re-issue:** `STATION_WAIT` (1,800) ticks into SIEGE/BREACH with under half on station, `military.posture(P, force)` once
  per `STATION_WAIT` while it lasts, and one kern.log warning per episode: `siege: N ticks into the SIEGE only 3 of 16 soldiers
  stand at their stations (equip 5, far 2): the orders are issued again`. Skipped while an intake wave or a sortie runs
  (`wave_busy`) or a kill order stands (`mem.kill_set`): the squads are elsewhere on purpose and a station order would replace
  the kill order.
- Contracts: SIEGE_END / SIEGE_STATUS fields (schema.py, CONTRACTS §12), `military.kpi` (§7), RULES §7 SIEGE_END row. Config
  `military.station_r`.

## Not decided offline
- **Which cause held in siege 14.** Decides: the next siege's SIEGE_STATUS `on_station` and `off` at T0, +600 and +1,200 (one per
  600 ticks) and SIEGE_END `sol0 -> soldiers`, `on_t`; `off.far` high with `on_station` low = the radius or a corridor
  station; `off.equip` = BUG-050's kit; `off.level` = a station behind a raised bridge or a squad outside the doors;
  `off.nost` = no manifest station. `inspect` `what=defense` and the squads' orders (`squad_info`) show where DF stands them.
- **Pre-positioning during an arrival lockdown** (cause 4) is not done: a lone-thief lockdown (DECISIONS 12) would keep the
  militia citizens at the stations for days. If the T0 numbers show the squads walk from far away, `lockdown -> READY_IN` for
  the elite squads only is the next step (siege.lua `apply`).

## Tests (fail on f17e2b3)
`tests/lua/test_siege_a3.lua` (new: SIEGE_END with the soldiers 16 -> 6, the best count and `on_t`; never on station: `on_t` -1, `off`
text, one warning, the forced posture; half on station: nothing forced and the numbers in SIEGE_END; a running kill order is
left alone), `tests/lua/test_military_a3.lua` (the radius, `kpi.off`, `nost`), `tests/test_military_a3.py` (event fields).

## Live check
See the CHANGELOG entry (2026-10-23, package A3).

Related: BUG-050 (the dropped kit), BUG-029/BUG-032 (stations behind bridges, on a bridge), BUG-030 (deep defense), note 23
