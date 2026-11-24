# BUG-844 the container cures were off (guessed cause); now on, but only while DF's own reason names the shortage
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i2: 30+ brews open, 1,334 usable plants, drink 0 and a MakeBarrel job nobody took for 54 days; BUG-834/835 cures (pile freeze, Carpentry labor, direct MakeBarrel tasks) were switched off by BUG-840 until a live look named the cause. The look (24.11.) did: DF cancels every brew 'Needs empty food storage item'.
Module: `lua/dfllm/economy.lua` (`M.cx_gate`, `cx_expire`, `cx_freeze`, `cx_labor`, `plan_contx`, `labor_assign`, `M.unit_far`, `brew_watch`, `brew_cause`), `lua/dfllm/act.lua` (`pile_barrels`), `config/baseline.json`, `dfpilot/fairplay.py`

## Root cause
The switches defaulted OFF for want of proof; the proof (DF's reason) was not readable.

## Fix
`economy.diag.cx_cure` is ON by default but acts only while DF cancelled brews with 'Needs empty food storage item' at least `cancel.cx_min_n` (5) times within `cancel.days` (7): then the census' free-container count is not trusted (phantom = 0 at once, not after 12 days), the plant piles' barrel limit is frozen (`pile_barrels`, never a pile that holds no barrel), CARPENTER goes to up to 2 + brews/10 (3..6) reachable citizens (off-group citizens are skipped), Stone crafting to 2, direct MakeBarrel tasks go on the Carpenter sheet. The freeze is time limited: given back when the reason is gone from the window, or after `cancel.cx_pile_days` (14) days (and not renewed for another 14). THE ONE RELIEF for a fort with drink 0: rock pots beside the barrels (`plan_pots`, up to 6 at once): the plant piles take barrels and never a large pot, no food is dumped or cooked, the order path exists (BUG-772), and pots need no logs (i1 has none usable). Kitchen cooking and dumping plant barrels were rejected: the cook takes only EDIBLE_COOKED plants the kernel bans from the kitchen on purpose and refills barrels at once; dumping destroys food and the piles refill the emptied barrel before a Still job takes it. No DF reason: no cure (constant reserve 3, no phantom, no freeze, no labor).

## Tests
`tests/lua/test_neu4_cancel.lua` (i2 live state: verdict proven, freeze, Carpentry; no reason / 4 cancels / switch off: nothing acts; freeze given back; time limit; an empty pile is never frozen), `tests/lua/test_bug834_838_brew_chain.lua` and `test_neu3_diag.lua` adapted.

## Live-Erwartung
1. i2 within ~3 game days of the reload: kern.log 'brew stall: stockpile N (...) takes no new barrel', 'Carpentry labor on for unit ...', 'brewing stalled ...: no empty barrel or pot ...; DF cancelled Brew N x ...' (no 'by my count'), MakeBarrel / pot orders get a worker; empty barrels and drink days rise within ~10-20 game days if the brewers then take jobs.
2. When DF stops cancelling for 7 days kern.log says 'stockpile barrel limits given back'. NOT promised: drink days rise (DF may find another reason after the containers exist; the weekly raw stall line then names it); the pile freeze does not empty a full barrel.
