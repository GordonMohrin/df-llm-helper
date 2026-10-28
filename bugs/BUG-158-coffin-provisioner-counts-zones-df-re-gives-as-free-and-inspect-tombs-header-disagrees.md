# BUG-158 `inspect tombs` says `0 free` while `prov.free` is 20; the provisioner counts the zones it freed and DF hands out again as free tombs
Status: fixed (offline, live-untested)
Severity: medium (the coffins short are understated by about 20 a run in the churn loop; the reply contradicts itself)
Found: 2026-10-28, live test i4 (BUG-127 note, new bug 6): header `555 coffins, 0 free, 80 unburied ... (rebuilt now ...); freed 20` with
`prov.free = 20`, lock `again_owned 20, churn 20` in the same reply (churn 299 in total)
Module: `lua/dfllm/care.lua` (`coffin_census`, `coffin_view`, `inspect`)

## Actual
`r.tombs_free` is taken right after `tomb_repair` freed 20 zones; DF assigns them again before the next look (churn). `coffin_census` used it as
`q.free`, so `short = want - slots` was 20 too small every run. `inspect tombs` copied `prov` from the last run while the header came from the
view rebuilt now.

## Fix
- `coffin_census`: `regive = min(this run's frees, the churn lock_scan saw at the start of the run)`; `q.free = tombs_free - regive`
  (`prov.regive`). A single repair without churn changes nothing.
- `inspect tombs`: `prov.free` is the header's count (the view rebuilt now or the last run's), `prov.free_run` what the provisioner counted.

## Tests
`tests/lua/test_care_live_i4.lua`: a freed zone DF re-gives, freed again: `prov.regive 1`, `free_run = free - 1`, `prov.free` = the header
(fails on main 2c0ffa3).

## Live check
In a fort with tomb churn (`inspect tombs` `again.churn` rising): `prov.regive` > 0 and `short` grows by it; the header's free and `prov.free` agree.
