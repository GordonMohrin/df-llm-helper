# BUG-911 DF's own 'Needs logs' cancels outvote the kernel's wood count (WOOD_DISBELIEVED)
Status: fixed (offline, live-untested)
Severity: high (a positive count held the whole wood chain for 1.5 game years)
Found: Run 17 i2 Whirledrampart: three 'cancels Make wooden barrel: Needs logs' (planter, broker) and two 'Make charcoal: Needs logs' (the countess) in the last gamelog lines, census wood 192, scan 202 free. The reader saw the cancels (`M.wood_cancel` logs them every 3 days) but nothing drew a consequence.
Module: `lua/dfllm/economy.lua` (`M.WOODDIS`, `M.wood_disbelieved`, `M.wood_usable`, `M.wood_belief`, `T.chop`, state block), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`, `docs/v2/CONTRACTS.md`

## Fix
`M.wood_belief` (each `T.chop` run): at least 3 cancels with the reason 'Needs logs' (any job kind) within 7 game days in the cancel tally (`M.CW.count`, the gamelog reader's rolling tally) while the census counts near logs > 0 set the state `wdis = {t, n, w}` (persisted in `m.economy`) for 28 game days. While it holds `M.wood_usable` is 0: autochop's gap is the whole need (`T.chop`), `stock.wood` shows 0 and `stock.woodd` the disbelieved count (` [DF cancels 'Needs logs': the count of W is disbelieved]`), `M.wood_cancel` says so. One event WOOD_DISBELIEVED per episode: 'DF cancelled N wood jobs (Needs logs) although the count is W: the count is not what DF can use' (`n`, `w`, `d`). Orders and floors still read the census (DF decides what it takes); the state ends by itself; `economy.wood.disbelieve=false` switches it off; `dis_n`, `dis_days` are settings.

## Tests
`tests/lua/test_bug910_915_holz.lua` (3 cancels set it, once, texts 0, 28 days later it is over; 2 cancels or no near log: nothing), `tests/test_bug910_915_holz.py` (schema, contract, text).

## Live-Erwartung
i2: within one economy run of the reload, with the 'Needs logs' cancels still in the 7 day tally (gamelog reader) the event WOOD_DISBELIEVED appears once ('DF cancelled N wood jobs (Needs logs) although the count is W'), kern.log shows 'wood disbelieved for 28 game days'. If DF keeps cancelling after the felling brought logs near, a new episode needs 3 new cancels after the 28 days. If fewer than 3 cancels lie in the window nothing is set.
