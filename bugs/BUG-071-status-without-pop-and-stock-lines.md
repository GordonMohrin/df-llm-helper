# BUG-071 `dfllm status` shows only the clock line after a year change or a hang
Status: fixed in c80a2fe (offline, live-untested): status keeps the pop and stock lines by rank (long UNREADY/alarm lines
are cut first), the kernel publishes the last known pop/stock/labor values with their age (`stale`, across a reboot too),
a >4 KB state document sheds other keys before them
Severity: medium (the first look at a fort in trouble shows nothing about population and supplies)
Found: 2026-10-22, Runs 11-13, from the game session (note 4)
Module: `dfpilot/brief.py` (`status_text`, `fit_ranked`, `line_pop`, `line_supply`), `lua/dfllm/kern.lua` (`compose`,
`M.carry`, `SHRINK`), `lua/dfllm/economy.lua` (`M.state`)

## Actual
`dfllm status` printed the `DEFCON | save clock mode ... hb` line and nothing else (no `pop`, no `stock`), right after a year
change or after the game hung.

## Cause
Four independent ways to the same picture, each proven from the code and reproduced:
1. **The 300-token fit dropped the lines from the end (base brief.py:491-499, 625-640).** `status_text` put every line in
   one section; `fit` removes the last line until the text fits. UNREADY (`SIEGE UNREADY (R0): ... next: ...`, 400-900
   characters when the audit, the route and the refuge fail) plus the alarm lines (lockdown, doors, recall, eta) use the
   budget, so everything behind them goes, `pop` and `stock` included. A year change and a hang are exactly when readiness
   falls to R0 and the alarm lines fill. Test: a state with a long UNREADY and a lockdown shows no `pop` on the base.
2. **The state document sheds `pop` and `stock` early (base kern.lua:657, 758-763).** Over 4096 bytes the kernel dropped
   `proj, alert, mil, trade, care, labor, stock, ready, bridges, threat, pop, phase` in that order: `stock` and `labor`
   went before `ready`, `bridges` and `threat`, and each drop was logged on every 2-s compose (kern.log flood). A fort with
   many bridge entries or a long `alert` loses its stock line first.
3. **A module that publishes nothing leaves its keys out (kern.lua compose; economy.lua:6837-6842).** `economy.M.state`
   returns `stock` and `labor` only when `st.out` exists, and `st.out` is set only when a daily run ends (economy.lua:6627).
   After every boot (a restart after a hang, `dfllm boot`, a load) the stock and labor lines are missing until the first
   completed daily run, which is sliced and paced (hours of real time in a big fort); a disabled module (fault backoff)
   leaves its keys out for as long.
4. **No valid state at all** (both slots torn or invalid): `_no_state` prints the reason; unchanged (rare: the writer
   replaces the files in place, the reader retries once).

## Fix
- **Reader (brief.py):** `fit_ranked`: clock line and rank-1 lines (pop, stock/labor, GUARD/follow/QUICKSAVE warnings)
  stay; over budget whole lines of rank 3-4 (def, sched, proj, kern, snap) go first, then UNREADY/alarm are cut to 90
  tokens, then dropped, and only then the rank-1 lines are shortened. Output order is unchanged.
- **Kernel carry (`M.carry`):** `pop.cit/adults/soldiers`, `stock.drink_d/food_d/meals`, `labor.starving/idle` missing from
  the composed document are filled from the last published integer and `stale = {pop|stock|labor: ticks}` says how old
  they are (status: `pop 36 (30ad 6sol) cap 55 gate 55 (last known 2d ago)`). Kept in `persist.kern.carry` (oldest leaf's
  tick) so a reboot starts with them; used for `perf.carry_days` 28 game days (config `perf`, 0 = never), never read from a
  persist record younger than the clock (an older save).
- **Shrink order:** `proj, alert, mil, trade, care, ready, bridges, threat, labor, stock, pop, stale, phase` (`stale` after the values it marks: a carried value never shows as a live one; review); the warning
  is logged once per key per 10 minutes.

## Not decided offline (live data that decides it)
Which of 1-3 produced the Run 13 pictures: `dfllm status` raw (is the UNREADY line there? then 1), `state.a.json` and
`state.b.json` sizes and kern.log `state > 4 KB: dropped ...` / `contract: state.X dropped` lines (2), kern.log boot time
and `economy` disabled/paced lines and the time of the first `economy` daily run after it (3). `dfllm doctor` shows
`state seq` and the disabled modules.

## Tests
`tests/test_status_keep.py` (new, 7: long UNREADY + lockdown keep pop and stock; rank order; `last known` ages; the idle
clause; the config mirror and validation), `tests/lua/test_kern_gaps.lua` (a silent module keeps its values with age; they
survive a reboot; `carry_days` 0 switches it off; a 4 KB document sheds `bridges` before `stock`, once in the log; a carried value keeps its `stale` marker while others are shed).
