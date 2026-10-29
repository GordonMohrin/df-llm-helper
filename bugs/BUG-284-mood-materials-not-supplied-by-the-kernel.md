# BUG-284 the kernel supplies no mood material itself: no chain shop, no webs, the needs not first in the next plan
Status: fixed (offline, live-untested)
Severity: high (glass, gems, silk, plant cloth and leather were each the end of a mood in Run 15)
Found: 2026-10-29, Run 15 Drillchamber (26396: silk + plant cloth, `none in the fort [0/0/0 of 6, thread 0]`) and Guildcleans
(26415 gems; 20997 leather + plant cloth with `thread 5`)
Module: `lua/dfllm/care.lua`, `lua/dfllm/act.lua`, `dfpilot/plan.py`

## Actual
care named the route (`route cloth: weave`, `route leather: no tannery (queued)`) and economy ordered what manager orders can
make, but nothing asked for the shops of the chain at once, spider webs on the walk group were only a kern.log hint (economy
`cloth short ... weavers collect them`), and `plan propose` did not put the open mood's needs into trade.want (only leather, after
a year).

## Fix
- The typed shop request (BUG-283) also names the chain shops missing on the map (`dfllm.mood` CHAIN: cloth/thread -> Loom,
  leather -> Tanners + Butchers, glass -> Glass Furnace, gems -> Jewelers and, when cut glass serves, the Glass Furnace,
  bone/shell -> Butchers). The autobutcher run for bone/shell/leather stays (care `acquire`).
- New act `mood_task(bld_id, 'CollectWebs')` (care): the Loom sheet's "Collect webs" task without a manager, one job with an
  undisturbed-web THREAD filter [live-untested job item fields]. care queues it while a silk/cloth/thread slot is short and
  `census.i.webs_near` > 0, every `mood_act_every` ticks at most.
- care keeps the trade tokens of each mood's short needs (`rec.buy`, state `mood[].buy`); trade already puts `care.mood_wants`
  first while a caravan is here; `plan propose` (`draft_supply`, `plan.mood_buys`) puts them first in trade.want.
- The satisfiability per slot (have / missing with the blocker) is the MOOD line (BUG-285) from the mood job's `job_items`.

## Tests
`tests/lua/test_mood_emergency.lua` (CollectWebs at the Loom once; chain types Loom/Tanners), `tests/lua/test_kern_act.lua`
(mood_task fields, owner, refusals), `tests/test_bug282_285_moods.py` (plan propose). Fail on 64df679.

## Live check
A mood with a silk slot and webs near: kern.log `mood unit N: collect webs queued at Loom <id> (K webs near)`, the Loom sheet
lists "Collect webs", a weaver takes it and silk thread appears (`inspect what=economy` thread_silk). If DF cancels the job at
once, read its job_items (item_type, flags1) read-only and fix `act.mood_task`. `plan propose` after a mood: trade.want starts
with the mood's tokens.
