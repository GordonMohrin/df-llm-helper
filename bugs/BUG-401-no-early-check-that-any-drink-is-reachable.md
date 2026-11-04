# BUG-401 no early check that any drink is reachable
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16a (i1 Mansionlauded, Bachwald), main 503bb8b
Module: `lua/dfllm/economy.lua`, `lua/dfllm/water.lua`, `dfpilot/plan.py`, `dfpilot/wake.py`

## Actual
Mansionlauded: 7 citizens, 48 drink days at y372 spr d56, no accepted water (the dug well 17738 `shallow 1/7, no source`), no brewable
plant ('50 seeds but no brewable plants'), no office. The kernel's questions were `drink_low` (the stills) and, from y373 spr d28,
`thirst` / `stranded_drink` when citizens were already thirsty; economy logged `drink 8 days but nobody thirsty: the citizens drink
water`. Every drink question named stills, barrels and brewers, none said that no water could be reached at all. The plan was fortcore,
shops, office. Pop 16 -> 2.

## Root cause
Nothing in economy asked whether the citizens can reach water: `alarm_check` waited for a thirsty citizen (BUG-259 made 'nobody
thirsty' an all-clear), `drink_low` looked at stills/plants/barrels only below 60 days, `water.lua` knew `st.src` and the scan (bodies,
banks) but only for the hospital. `plan.emergency` reacted to an empty `water.src`, but with no fill source (`_cistern_due` false) it
drafted nothing for water and its note said 'no water or food build left to draft'.

## Fix
- `water.lua M.drink_access(K)`: `{known, ok, acc, bank, bodies, partial}` from the last scan and the accepted sources; ok = a Water
  Source zone / wet well, or a body (not cavern) with a bank the citizens reach.
- `economy.lua M.no_water` (first in the daily watch): not ok, no brewable plant (`brew_p + brew_g` 0), citizens present -> `st.nowater`;
  DECISION_NEEDED `no_water` (A) at once and weekly while it holds (new token per week): `q`, `drink`, `water` (the water module's fix
  text, `M.drink_fix`), `cmds` (`inspect what=water_sources`, `bp sites cistern`, `inspect what=reach`, `trade.want plant/drink/seeds`),
  `auto`. `st.nowater` also: the supply alarm counts low drink days as dry (no 'nobody thirsty' all-clear), `drink_why` / state
  `stock.dwhy` starts `no reachable water` even with plenty of days, the gatherers start (`st.bshort`) and the caravans are asked for
  plants and drink (`fd_wants`) at once.
- `wake.py`: `no_water` is an urgent decision and its first command goes into the wake line (`food_hint`).
- `plan.py no_water_note`: when `stock.dwhy` says `no reachable water`, `plan propose` puts a first note: water before every build, with
  where the commands are.

## Open
- Judged from the scan: a scan that stops at its read cap (`partial`) can miss a bank; the text says `(scan partial)`. The decision is
  advice, nothing is built from it.
- The kernel builds no well or zone by itself here (it needs a site); `bp sites cistern` and the zone stay commands.
- Water behind a wall the scan calls a dig (`b.dig`) counts as no water: nobody can drink there yet.

## Tests
tests/lua/test_bug400_402_water.lua (4 for 401 incl. `drink_access`), tests/test_bug400_402_water.py (wake, plan note).

## Live check
A new fort beside frozen or walled-off water with no plants: within the first game day kern.log `no reachable water and no brewable
plant`, `events --cls A` shows `no_water` with `d.cmds`, `status` drink line starts `no reachable water`; a fort beside a brook with a
bank or with a brewable plant in stock shows none of it.
