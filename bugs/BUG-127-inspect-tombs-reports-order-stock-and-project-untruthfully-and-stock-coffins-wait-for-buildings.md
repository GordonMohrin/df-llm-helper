# BUG-127 `inspect tombs` / `brief` reported `order 0, proj cof…` without saying that the order could not run, the project stood still or the order was refused; coffins in stock (19) with 0 burial jobs and 0 free tombs
Status: fixed in the BUG-126 commit (offline, live-untested); the stock-coffin question is answered below
Severity: medium (wrong report: three game years of "short 10" without the cause)
Found: 2026-10-27, Run 14 (y710-y711), game session note 103
Module: `lua/dfllm/care.lua` (`coffin_view`, `inspect`, `state`), `dfpilot/brief.py`, `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Actual
- `order 0` counted only the ConstructCoffin orders that can run; an open order that cannot (no mason's workshop, no stone) was invisible
  (`prov.stuck` existed, the message and the brief did not show it).
- `proj` showed `pc.proj` as stored: a project the runner had dropped (done and pruned, cancelled) stayed named while another tombs project
  (follow's) was pending; the percent came from the runner's rows, which list eight projects at most.
- A refused `workorder` (`oretry` one day) left no trace but a retry; a missing item census made the provisioner return without a word.
- Nothing said how long the project had stood still.

## Fix
- `inspect what=tombs` message: `coffins want W, short S, stock K, on order O (+N stuck: no worker, shop or material), project P 0% (no progress
  D d), 1 stale project(s) dropped, no item census yet: nothing ordered, order refused: <text>, no <why>`; `prov` gains `stale` (days), `dropped`,
  `census`, `oerr`, `stage`; the percent is read from `runner.coffins_state`, not from the capped rows; a project the runner no longer has is
  forgotten, so `proj` is `''`.
- `state.care.coffins` gains the optional `stuck` and `stale` (days, with a project) (schema, `contract.lua`, CONTRACTS appendix); `brief`
  prints `coffins want .. short .. stock .. order .. stuck N proj cof.. (idle Dd)`.
- A refused order is logged (`kern.log coffins: order ConstructCoffin xN in wood refused: ...`) and shown as `oerr`.

## Stock coffins (19) with 0 free tombs and 0 burial jobs: does the kernel place them?
A coffin ITEM is not a tomb. DF buries a body in a coffin BUILDING that stands in a tomb zone, so the 19 items in stock needed 19 planned coffin
buildings (buildingplan then takes the items). The kernel places those buildings only through `runner.coffins` (care's coffin project: the
building 'n', then the 1x1 tomb zone). While the stale project held `pending` above 0, no new rows were placed (BUG-126 cause 2), so items
piled up without a building. With the stale project dropped, the search places rows for the short coffins and the stock is consumed by
their buildings. Tomb zones without a coffin building (empty 1x1 zones) were not removed while a tombs project was pending either; after the
drop the repair removes them (`z.drop = 'empty'`). Not built: re-using such an empty zone as a coffin site (a coffin building on its tile)
instead of removing it and searching free floor elsewhere. It is a different feature (the zone's tile may be a bad site: bedroom, far walk
group), larger than this fix; the cost today is a search for free floor and one more project.

## Tests (`tests/lua/test_care_coffins.lua`)
- inspect and state tell the days a project stands still (fails on f3f684b: no such text or field); a project the runner lost is not shown.
- a rock order that cannot run (no mason) is shown as `4 stuck`, the coffins are ordered in wood (fails on f3f684b: the message had no `stuck`).
- `tests/test_care_coffins_files.py`: `care.coffins.stuck/stale` valid in the state schema; config key `coffin_stale`.
