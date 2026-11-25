# BUG-864 The elite squads were put off duty every winter and DF stripped them
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i4 Girderroots (commands.log: 54 'Off duty' acts of squads A and C, all in game months 9-11; kern.log uniform-unstick: worn 60-80 % in PEACE, dips to 8-23 % once a year for 7 winters; the sortie refusal of y402 fell in such a dip); i3 Orangering (same dips, 89 of 143 'Off duty' acts in month 9).
Module: `lua/dfllm/military.lua` `off_season` (FR-71 free months), `M.conf` (`elite_off`), `config/baseline.json` `military.elite_off`, `dfpilot/fairplay.py`

## Root cause
FR-71 put the elite (squads that are not militia) off duty in `military.free_months` [9,10,11]. A soldier of a squad with no orders is a civilian to DF: he fetches no kit and drops what he wears (BUG-694 already knew it for the stand-down). So the worn share fell once a year exactly when the squads were asked to act (sortie, siege stand-down at the end of a winter).

## Fix
`off_season` returns false for an elite squad unless `military.elite_off` is true (default false): the elite stays on Constant training (the wooden drill, Z5) in the free months. The militia window of B is unchanged (B is on duty only in months 9-11 as before).

## Tests
`tests/lua/test_military_a3.lua` (FR-71 tests: default keeps A and C on Constant training in month 10, `elite_off = true` restores the rest), `tests/lua/test_bug864_870_ruest.lua`, `tests/test_military_a3.py` (config lint).

## Live-Erwartung
On i1/i2/i3/i4 no `act.squad_routine ... 'Off duty'` for squads A or C appears in commands.log in months 9-11 any more, and the `uniform-unstick ... worn X% before, Y% now` series shows no yearly dip to < 30 %. NOT promised: that DF fills every spec (see BUG-865, BUG-870), or that a fort without any free kit gets worn kit.
