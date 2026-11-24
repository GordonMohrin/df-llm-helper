# BUG-836 dfpilot why answered 'unknown' / 'labor not known' / '0 match' for MakeBarrel, item-conditioned brews and plants in barrels
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-24, Run 17 i2 Whirledrampart (cli.log 1218-1267 'order 5745 MakeBarrel: 1 job, none worked; the labor this job needs is not known; the inputs lie free'; kern.log 2686 'none: plant (DRINK_MAT) x1: 0 match, 0 free' beside 6932 plants in the census), i4 ('none: fish_raw x1: 0 match' beside 1763 raw fish), i1 ('no job made: N item conditions DF checks itself')
Module: `lua/dfllm/jobwhy.lua` (`J.labors`, `J.conditions`, `J.census_count`, `J.input_cause`, `J.order`)

## Root cause
`J.labors` knew a labor only from the job type attrs, the material class (a MakeBarrel job carries a material category, so none) or orderlib's table with `'any'` (MakeBarrel has no `any` key): the worker check was skipped and the text fell to 'not known'. Item conditions were only counted, never read. The input scan reported `no_input` for 0 matches even where the census holds thousands (the scan or the census is wrong; the scan was never verified live).

## Fix
- `J.labors(..., skey)`: the shop's key names the labor (Carpenters -> CARPENTER); `no_labor` is named for an order whose job nobody can work.
- `J.conditions(o)`: every item condition read as `AtLeast 10 plant: 3 found`; an unmet one is cause `cond_unmet` (proven), all met = `conditions` (not proven) with the list.
- `J.census_count` + `scan_unreliable` (not proven): scan 0 where the census (`ctx.inv`: brew_p / brew_g, fish_raw, barrels_empty) holds 10 or more says so instead of `no_input`.

## Tests
`tests/lua/test_bug834_838_brew_chain.lua` (MakeBarrel job with no Carpentry holder -> `no_labor`, with a holder the labor is read; unmet condition with count; scan unreliable beside census 6978, plain no_input without a census).

## Live-Erwartung
1. `dfpilot why order:ID` for a MakeBarrel order names `nobody holds the CARPENTER labor` or the holder states (free / busy / burrow).
2. `dfpilot why brew` on an i2-like state: either `scan_unreliable` (the scan is wrong: fix `item_fits` / SKIP next) or a real blocker with counts.
3. A brew order with a condition names the unmet one with the number found.
