# BUG-570 a hunger or thirst emergency in a long SIEGE lockdown never escalates (no relief, food stays forbidden, only a hopeless sortie on offer)
Status: fixed (offline, live-untested); open: the doors the lockdown forbids are not released, a BREACH is not covered
Severity: critical (the same death wave as BUG-569: 78-82 hungry beside 675-712 days of food, 9+ dead in 20 days)
Found: 2026-11-06, Run 16b i2 Brotherarrow y406 (`runs/run-16b/FR-BUGS.md` "BUG (KRITISCH) SIEGE_DEEP-Refuge Tiefe+ hat 0 Essen", "Hungertod-Welle", "Patient 27722 verdurstet", "Manager Onget validiert 48 Tage nichts")
Module: `lua/dfllm/siege.lua` (`starve_step`, `starve_state`, `alert_plan`), `lua/dfllm/economy.lua` (`T.forbid`, `siege_starving`), `lua/dfllm/reflex.lua` (`overlimit_step`), `dfpilot/wake.py`, `dfpilot/fairplay.py`, `dfpilot/brief.py`

## Actual
In the 115-day lockdown: `stock HUNGRY 43`, DECISION thirst_unit #9349 with 5 citizens at hunger 70-74k, 4 forbidden foods `unforbid held back: mode SIEGE`, 28 doors forbidden, `lockdown_long` (limit 10 d) long passed with `lockdown_long` offering only a sortie against 36 goblins (rec 0). Nothing widened the burrow, freed the food or said what to do.

## Root cause
- `siege.lua` `relax_step` (BUG-031) lets citizens out of the alert burrow only through `seal.dry`, which marks a burrow dry when its audit finds NONE of the food (`food == 0`, seal.lua `M.dry`); Tiefe+ held food 1, so it never counted, and the fight mark (hunger 75,000) comes after the first deaths. No rule looked at the citizens' hunger as such.
- `economy.lua` `T.forbid` (old line 11787) returned at once outside `FORBID_MODES` (PEACE, RECOVERY, ALERT, DRILL), and forbidden food is unforbidden only in a starvation of the stock (`p.starve`) or a bulk burst.
- `reflex.lua` `overlimit_step` offered the sortie and `wait` and knew nothing of the hunger.

## Fix
`siege.lua` section BUG-570 (`starve_step`, config `siege_starve`: `on` true, `min` 3, `mark` 50,000, `near` 25, `death_days` 10 - `fairplay.SIEGE_STARVE_LIM`): in a SIEGE, `min` citizens (patients excluded: water's business) over `mark` of hunger or thirst, or one after a DEATHS_PREVENTABLE (starved/dehydrated, event `EV:DEATHS_PREVENTABLE`) of the last `death_days`, is an emergency (`starve_state`, state `wave.sv`).
- Relief (`mem.sv.relief`) while nobody hostile is inside Kern+ and none within `near` tiles of O1, a bridge or a citizen outside (the distances of `long_step`; no hostile in sight counts as far): `alert_plan` drops the deep defense's refuge for the civilians and asks seal for Kern+ with the release reason `starvation relief: N citizens hungry or thirsty and no hostile near Kern+`. The bridges stay up, the squads keep the core station: only the burrow widens. A hostile coming within `near` (or inside) ends it at once (kern.log `starvation relief OFF`) and the burrow goes back to the deep defense's pick; it ends a game day after the last citizen over the mark (no flapping).
- `economy.T.forbid`: while the emergency stands (relief or not) SIEGE unforbids food and drink too (up to 200 a day, `forbid_note` no longer says `mode SIEGE`).
- DECISION_NEEDED `starve_lockdown` (A; again after 3 game days or when the relief changes): `n`, `hunger`, `thirst`, `units`, `relief`, `near`, `inside`, `to`, and with no relief the ready `squad.sortie` command; wake hint `wake.starve_lockdown_hint`, the status line (`DEEP ...: civilians in Kern+ (BUG-570 starvation relief)` / `HUNGER: no relief, a hostile is near`). `lockdown_long` names the emergency and no longer says `wait` while it stands.

## Tests
`tests/lua/test_bug569_570_starve_traffic.lua` (2)-(4): announced engineers keep the civilians in Tiefe+; 4 citizens at 90,000 hunger with the army 100 tiles off: Kern+ at once (old: Tiefe+ for ever), starve_lockdown relief 1, release reason in the seal ask; a goblin 20 tiles from O1: back in Tiefe+, the decision says why not; far again: relief again; fed for a game day: over; O1 and B1 never lowered, nobody crushed or shut out, one pull at a time; a hostile near from the start: no relief; two hungry (min 3) and `siege_starve.on` false: the old rule. `tests/lua/test_economy_supply.lua`: SIEGE with the emergency unforbids 20 drink stacks and 5 food items (old: none). `tests/test_bug569_572_f36.py`: config limits = Lua defaults, wake hint, schema (`wave.sv`).

## Live check
Make a siege with hungry citizens in the refuge (or `reflex.json siege_starve.min` 1 with one hungry citizen): `kern.log` `starvation in the lockdown`, `relief ON`, the alert on Kern+, DECISION `starve_lockdown`; with a goblin placed within 25 tiles of O1 `relief OFF`. Not done: the doors the lockdown forbids (28 in the report) stay forbidden; a BREACH is not widened (its refuge is the hold of the fight); `inspect what=starving` with a way diagnosis (wish 3 of the report).
