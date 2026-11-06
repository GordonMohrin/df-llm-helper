# BUG-513 Refuge-lever retrofit "100 %" but the levers stay unlinked, and the question asks for the retrofit again every 30 days
Status: fixed (offline, live-untested): the cause is made visible and the scarce mechanisms go to the refuge lever; why the link job never appeared in i4 is not proven (see Open)
Severity: high (R0/P5 hang, DECISION_NEEDED repeated 99 times, three retrofits placed, O1/B2 pulls impossible for confined civilians)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y388-y389 (FR-BUGS "Refuge-Hebel-Retrofit fertig (100 %), aber Hebel bleiben unverknuepft"); runtime `r16d4-trumpetrealms-site97/events.jsonl` (DECISION_NEEDED refuge_levers #6011 ... #7759, PROJECT_STAGE s3.lever done #6093/#6219/#6760, ACT_FAIL link_lever) and `kern.log` (read only)
Module: `lua/dfllm/gate.lua` (`links`, `lever_report`, `refuge_levers`), `lua/dfllm/readiness.lua` (`reflever_cause`, `ask_reflevers`), `dfpilot/schema.py` (DECISION_NEEDED `cause`)

## Actual
- Manifest of i4: B1 levers `[80,105,139] [80,106,139] [88,111,133]`, B2 `[82,110,139] [82,112,139] [88,109,133]`, O1 `[80,102,139] [80,103,139] [88,110,133]`: the refuge levers (z133) are in the manifest (the retrofit's fragment is merged when the stage is done).
- 99 DECISION_NEEDED refuge_levers (every ~36,000 ticks, tick 156517539-160106419, from #6011), each "build the refuge levers: bp.place tpl=fortcore site=same stage=3 retrofit=2" although `s3.lever done (100%)` came three times (#6093, #6219, #6760).
- The only link activity: `LEVER link B1/B2/O1` and ACT_FAIL `act.link_lever failed for gate: needs 2 free reachable mechanisms, 0/1 found` until tick 156073369 (164 ACT_FAIL, one per day at most); NO link attempt, NO ACT_FAIL and NO LEVER event for the 3.5 million ticks after the retrofit levers were built (156.6M-159.6M). kern.log 156218649: "order 660 ConstructMechanisms x4: no job for 25 days (Mechanics: 1 shop, 0 jobs (0 working), none from this order; 17 free boulders)".

## Root causes
1. `gate.lua links` looped the manifest levers silently: a lever that is not built, has a queued link job (`link_pending`) or is skipped for any other reason left no trace anywhere (no state, no log line, no event); the question could not tell "not placed" from "placed, waits for a mechanism" from "built, waits for 2 mechanisms" from "link job queued, nobody does it".
2. `readiness.ask_reflevers` knew one answer, the retrofit command, whatever the state of the levers; a retrofit re-placed three times asked three more levers for three more mechanisms in a fort that had none.
3. Mechanisms are scarce in such a fort (2 per link, 1 per lever) and `links` spent them in manifest order: a second outside lever of a bridge before its refuge lever.

## Fix
- `gate.lua`: `lever_report` reads every manifest lever of a bridge each pass (at most every `LR_EVERY` 120 ticks, whatever the mode) into `none` / `site` (placed, not built) / `built` (not linked) / `job` (a link job queued) / `linked`, with the tick it has been in that state, and `link_why` (the last refusal of `act.link_lever`); `gate.refuge_levers()` publishes the refuge ones (counts, `age`, `stale` after `LINK_STALE` 14,400 ticks, `why`); `links` links the refuge lever first and, while a refuge lever of a bridge that has a linked lever already waits for its link, no other lever of that bridge (mechanisms are scarce).
- `readiness.lua`: the question says what the levers wait for, `d.cause`: `none` (no lever stands in the refuge: the retrofit command as before), `unbuilt` (placed, a mechanism missing: "do not place the retrofit again: mechanisms need a Mechanics workshop and stone, or a caravan"), `unlinked` (built; 2 free mechanisms, the free count, the economy route and the last refusal), `link_job` / `link_stale` (a Mechanic with the Mechanics labor is missing); no `cmds` for these.

## Tests
`tests/lua/test_bug513_refuge_levers.lua` (4): placed-not-built -> cause `unbuilt`, no retrofit command; built-unlinked -> `unlinked`, refusal text; a queued link job -> `link_job`, stale after 12 days -> `link_stale`; no lever at the refuge tile -> `none` with the retrofit command; a bridge with a linked lever and an unlinked refuge lever tries the refuge lever only; with no linked lever the refuge lever is still first. `test_bug478_481_defense_ready`, `test_siege` (link test), `test_bug491_lost_lever`, `test_m2_bridge`, `test_bridge_rebuild` green.

## Live check
`dfllm status` / DECISION_NEEDED refuge_levers with `cause`; `inspect`: `ready.rg`; the question stops proposing the retrofit once the levers stand; when mechanisms exist the refuge levers are linked first (`LEVER link B2` events, then `refuge_gaps` empty).

## Open
Why no link attempt followed the built levers in i4 is not proven from the logs. The fort had no free mechanism (ACT_FAIL history) and an idle Mechanics shop; the likeliest is a link job or lever site that waited for a mechanism for ever (the new states and the question show which). The Mechanics shop that takes no `ConstructMechanisms` order (17 boulders free, "0 jobs") is an economy/labor question not touched here. Mechanisms for placed-but-unbuilt levers (1 each) are not yet counted by `economy.mech_need` (it counts 2 per unlinked manifest lever).
