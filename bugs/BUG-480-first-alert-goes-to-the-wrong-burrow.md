# BUG-480 The siege popup named the engineers; the first alert still went to Kern+ and 83 citizens crossed the gates a second time
Status: fixed (offline, live-untested); open: citizens 100+ tiles away at the alert, patients in beds outside Kern+, outdoor work before the popup
Severity: critical (Castletongs: 3 deaths before the lockdown, the traffic jam kept O1 down)
Found: 2026-11-05, Run 16c i3 Castletongs y403 spring d6-d9 (#5447 ARRIVAL, #5451 SIEGE_DEEP, #5458, #5489, #5511, #5537) and Run 16a i1 Syrupobeyed y385 (3 dead in an ambush), y387
Module: `lua/dfllm/reflex.lua` (`announce`, REPORT), `lua/dfllm/siege.lua` (`expect_destroyers`, `alert_plan`, `deep_step`)

## Actual (log)
- The recall began at the first sight (ARRIVAL tick 162496539, 11 citizens outside Kern+): it was NOT late. But the popup text itself said "With them come monstrous siege engineers!" and nobody read it: the alert sounded on Kern+ ("units on a bridge"), the census saw five trolls 9 ticks later, SIEGE_DEEP moved the alert to Tiefe+ and reflex recorded "83 citizens not in Tiefe+ now (+73 more out since)". The whole fort walked down the civilians' stair over B2's landing and the B1/B2 footprints while O1/B1/B2 waited for them ("B2 up waits for citizen ... +15 more", O1 pull cancelled x6): BREACH at T+900.
- Deaths 20104 (a patient lying outside at 125,100,127: 'PATIENTS_OUT' only came in the BREACH, hospital none since y380), 27139 and 27075 (idle at 31,20,123 and 33,14,123, 100+ tiles out at the alert; they came in within 2650 ticks but stopped idle at 122,112-113 north of B1 when it rose: no path to Tiefe+).
- Hunters were taken off the detail 244 ticks after the sighting (economy rush_ticks), not at the sighting.

## Root cause
The kernel decided the burrow from the hostile census only; the popup's list of creatures (a reliable T0 signal: siege engineers/trolls are the building destroyers) was never read. The late switch doubled the traffic through the gates at the worst moment.

## Fix
- `reflex.announce` (popup) and the REPORT path call `siege.expect_destroyers(text)` when a siege text names `siege engineer` or `troll` (`reflex.destroyer_words`), before the lockdown is engaged.
- `siege.expect_destroyers`: persists `m.siege.bdx`, applies the alert plan in the same pass: `alert_plan` treats the announcement like the deep defense (refuge burrow) in PEACE/ALERT/SIEGE; `deep_step` adds the reason `announced` (SIEGE_DEEP says "the siege popup announced siege engineers") and latches `bd` so the plug (BUG-479) is asked; expires after `BDX_HOLD` (3600) ticks without a siege, cleared by PEACE.
- siege keeps the history of its sieges (`siege.history`: largest army, count, destroyers; persisted `m.siege.hist`), used by BUG-481.
- Not done: wanderers 100+ tiles out and patients outside cannot be saved by a recall (the kernel has no escort or rescue); the hospital inside the refuge (R0 `hospital_out`) and a leash on outdoor work are plan items. The gate traffic logic is untouched.

## Tests
`tests/lua/test_bug478_481_siege_traffic.lua` (the siege traffic test with trolls and citizens returning: the first alert is Tiefe+, SIEGE_DEEP `announced` at once, nobody crushed or shut out, B1 up before the army, no GATE_FAIL; control without the announcement sounds Kern+ first; expiry), `tests/lua/test_bug480_announce.lua` (popup text -> siege.expect_destroyers; goblins only change nothing).

## Live check
The next siege popup with "siege engineers": ARRIVAL alert `Tiefe+`, SIEGE_DEEP with why `announced` within one pass, no `REFUGE_SWITCH Kern+ -> Tiefe+`.
