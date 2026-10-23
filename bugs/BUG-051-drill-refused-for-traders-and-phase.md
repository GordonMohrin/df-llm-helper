# BUG-051 The drill is refused while merchants stand on the map and before P5; in Run 13 it never ran
Status: fixed in 63191ea (offline, live-untested): a drill is refused only for danger (a mode other than PEACE, a lockdown, a
hostile in sight: `military.danger`) and for the length of one trade session (`trade.clock`); merchants on the map and the
runner's phase hold nothing; automatic drills need outer/inner bridges, soldiers and a barracks (`military.barracks`); a fort
of 40+ citizens with a barracks staffs its squads before P2 (`military.early`, latched, `military.early_pop`)
Severity: high (wrong decision: no drill for years, worn 9-23 %, the fort fell with untrained squads)
Found: 2026-10-23 (note 2 of bugs/RUN11-offene-bugs-und-FR.md and cause 2 of docs/v2/POSTMORTEM-run13-wheelsblows-y525.md),
Run 11-14, Run 13 Wheelsblows y504-y525, from the game session
Module: `lua/dfllm/drill.lua` (`M.start`, `check`, `M.hold`, `danger`, `M.trading`), `lua/dfllm/military.lua` (`M.barracks`,
`M.early`, `active`, `M.targets`), `config/baseline.json` `military.early_pop`

## Actual
- Note 2: "drill is refused while merchants stand on the map ('merchants on the map'); traders often stay for weeks; the
  training falls out. Wish: block the drill only for danger, not for merchants."
- Run 13 post-mortem: "the drill never ran automatically (phase P0 < P5, 'merchants on the map'), armor 9-23 %"; pop 47-59
  from y506 on, the phase stayed P0 for twenty years (a deliverable never finished), the first drill was started by hand in
  y525, the fort fell in the summer.

## Cause (proved from the code at f17e2b3)
1. **`drill.start` refuses for merchants.** `drill.lua:154`: `if M.merchants(K) then return false, 'merchants on the map'
   end`; `M.merchants` (70-81) is true for a caravan Approaching, AtDepot or Leaving, i.e. for the whole visit. `M.hold`
   reported `merchants` (line 327) the same way, so `ready.dhold`/`status` said "drill never (auto: merchants)".
2. **The automatic drill needs P5.** `drill.lua:300`: `if pn and pn < M.AUTO_PHASE then return nil, 'phase P0<P5'`
   (`M.AUTO_PHASE = 5`, line 40) - checked before the soldiers: the text of the post-mortem.
3. **And no squad exists before P2.** `military.lua:466` (`active`) returns no squad and `military.lua:490` (`targets`)
   `zero = 'phase'` for a known phase below P2: with the runner stuck at P0 the military module staffed nothing and, in
   PEACE, released every soldier it could find (`release`, military.lua:1902, `soldiers released (phase)`); the drill's "no soldiers" check
   could not pass either. A bigger fort at P0 - the Run 13 shape - had neither squads nor a drill.
4. Pinned by tests: `tests/lua/test_drill.lua` (the 'merchants on the map' refusal, `phase P3<P5`), `tests/lua/test_military.lua`
   ('phase gating': no squad at P1 with 50 adults).

## Fix
- **drill.lua:** `danger(K)` = `military.danger`: `mode <M>` (not PEACE), `lockdown` (`reflex.holding`), `hostile`
  (`census.h.vis` > 0). `M.start` refuses with `drill only in PEACE (now ALERT)` (unchanged text), `drill refused: a lockdown
  holds` or `... a hostile is in sight`; `check` returns the same words as the hold reason (`mode ALERT`, `lockdown`,
  `hostile`). Merchants hold nothing. One narrow exception: `M.trading` (`trade.clock` = `trade`, i.e. the kernel's trade
  module is inside a trade-screen phase of a visit): the civ alert of a drill would call the broker home in the middle of
  the trade, so the drill waits for the end of that session (`ready.dhold` `trading`); that is hours, not the weeks of the
  visit.
- **The phase condition is gone; what a drill uses decides.** A drill raises bridges (the manifest must have an outer/inner
  one: `no bridges`), measures squads (`military.kpi` soldiers > 0: `no soldiers`) and sends them to the barracks' stations
  (`military.barracks`: a fortcore melee station - stage 2 builds the gatehouse barracks with it -, a manifest room
  `barracks`, or a Barracks civzone in the game, the player's or a ruin's; `no barracks` only when the zones were read and
  none stands, unknown holds nothing). The P5 gate stood for "stage 3 is built"; a drill earlier than that is a test of
  what exists, and a failure is the digest's DRILL_RESULT, the second one in a row DRILL_FAIL (A).
- **military.lua:** `M.early(K)`: `conf.early_pop` (40, 0 = off) citizens and a barracks lift the phase gate of `active` and
  `targets`, so a big fort stuck at P0/P1 staffs squad A (the `ph < 5` rule still limits P0-P4 to one squad) and the drill
  finds soldiers. Latched in `st.early`: it ends below half of `early_pop` citizens or without a barracks, so a fort at the
  threshold does not release its soldiers and their kit with every death. Small forts (7, 12, 30) keep the phase gate.
- Config `military.early_pop` (`fairplay.MILITARY_LIM`, `lint --config`). Docs: DESIGN §3 mode table and §5.4, CONTRACTS §7
  (`drill.start`, `drill.hold`, `military.danger`, `military.barracks`).

## Not decided offline
- **Does a drill with merchants at the depot cost a trade?** The gate refuses `down` in DRILL (`gate.want`), so the trade
  module's O1 window cannot lower O1 during the ~1,200 ticks of a drill, and a caravan still Approaching may find O1 raised
  (STUCK_APPROACH is 4,800 ticks, trade.lua). Citizens at the depot are called home by the alert. Decides: the next live
  drill with a caravan on the map - CARAVAN events (traded / failed `ui_timeout`), `trade.lua` kern.log, `fix/stuck-merchants`
  lines within a day of the drill.
- **Is `df.civzone_type.Barracks` the 53.16 name?** The read is guarded; if the enum lacks it, `military.barracks` answers
  unknown (`unread`) and only the manifest evidence counts. Decides: `dfhack-run lua "print(df.civzone_type.Barracks)"`.
- **Early squads in a reclaim.** Whether 40 citizens at P0 are better with squad A than without is a judgment; `early_pop 0`
  restores the old rule.

## Tests (fail on f17e2b3)
`tests/lua/test_drill_a3.lua` (new: merchants hold nothing - manual, hold(), automatic -, a trade session defers, a lockdown /
a hostile / ALERT hold with their texts, no phase gate, `no barracks`, unknown is no verdict, early squads at P0 for 45 but
not for 30 citizens or without a barracks, the latch, `early_pop` 0, the automatic drill runs at P0), `tests/lua/test_drill.lua`
and `tests/lua/test_military.lua` (the old phase and merchant expectations), `tests/test_military_a3.py`.

## Live check
See the CHANGELOG entry (2026-10-23, package A3).

Related: BUG-050 (the kit the drill measures), BUG-052 (soldiers on station), FR-65 (`drill.hold`), D-14 (peace gates)
