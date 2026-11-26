# BUG-925 a manager who cannot work stays in office for years: `appoint` refuses the replacement, the kernel only warns
Status: fixed (offline, live-untested)
Severity: high (every new work order of the fort unvalidated: brewing, barrels, doors, slabs wait for a patient)
Found: Run 17 i2 Whirledrampart y564 (26.11.): manager Cerol (unit 29240) a hospital patient (job Rest, wounds 23, thirst ~30,500) since the kernel appointed him (kern.1.log `224265659 MANAGER appointed`), 66 of 182 orders unvalidated, `inspect orders` id 7100 ConstructSlab 2,997 days, id 7135 MakeBarrel 2,127 days; `d.sh cmd appoint {"code":"MANAGER","unit":29544}` -> `ERR appoint: MANAGER has no vacant assignment; MANAGER is alive and among the citizens (no replacement)`. Diagnosis `leitung/neu10/DIAGNOSE-i2-manager.md` (1)-(4).
Module: `lua/dfllm/economy.lua` (`M.manager_watch`, `M.manager_replace`, `M.mgr_candidate`, `M.mgr_unfit`, `M.mgr_seated`, `M.replace_ok`, `M.verbs.appoint`), `lua/dfllm/util/contract.lua` (event), `config/baseline.json`

## Cause (PROVEN in the code, diagnosis (1) and (2))
- `appoint` fills a VACANT assignment only (`act.lua` `I.appoint`: `a.histfig == -1`). `replace:true` goes through `M.replace_ok`, which allowed MANAGER / BROKER only for a holder who stood off the citizens' walk group for 7 days (`out_watch`, `snapshot.far`); a bed-ridden holder inside the fort never qualified.
- `M.manager_watch` knew the state (`manager_state` says `resting/injured` for `needs_healthcare` or job Rest) and only warned (DECISION_NEEDED `manager_absent`, once per manager and reason); its comment said "the kernel never replaces a holder". Nothing replaced him in 2,900 game days.

## Fix
- `manager_watch`: after `orders.manager_days` the case is reported as before; in addition, once `orders.manager_replace_days` (default 30, `0` = never; baseline.json, `fairplay` limit 0..400) game days have passed with orders unvalidated and the manager `resting/injured` (`M.mgr_cannot_work`), `M.manager_replace` appoints the best free adult citizen: `M.mgr_candidate` (ORGANIZATION skill ranking as `appoint_vacant`) over `M.mgr_unfit`: never a soldier on duty (squad member), a child, a dead unit, a unit in a mood, a patient (`needs_healthcare` or job Rest), a unit outside the citizens' walk group, nobody who already holds another post. `K.act.appoint('MANAGER', id, true)` vacates the old assignment and unlinks the old figure (`act.lua` `I.appoint`, BUG-458): the old manager is not touched. Bounded: one replacement per position per span (`p.mrep.t`), a refused try waits a game day (`p.mrep.try`), no candidate: one kern.log line.
- Event `MANAGER_REPLACED` (class B): `code`, `old`, `new`, `why`, `days`, `orders`, `how` (`kernel` | `verb`), `span`.
- Verb `appoint {code:MANAGER, unit, replace:true}`: `M.replace_ok` also accepts the holder who cannot work for the span (`down`); before the span: `appoint replace refused: MANAGER Cerol has been unable to work for 12 of 30 days (manager Cerol resting/injured)`; the new unit must pass the same `M.mgr_unfit` (`unit 8 is a soldier on duty` / `is a patient or resting` / `is a child` ...); a healthy manager keeps the old refusal ("lives and stands among the citizens"). BROKER keeps the outside-the-fort rule only.

## Not done / unproven
- BOOKKEEPER and BROKER have no `manager_state` equivalent: no automatic replacement for them (the code covers the MANAGER).
- The case "no order validated although orders wait" with an ABLE manager and a complete office (`mgr_stuck`, BUG-450) stays a question to the player: the cause there is not the holder.
- The status line's "economy counts 0 unvalidated for 0 days" with 66 open orders (`st.unval = nil` while `manager_watch` holds, diagnosis (3)) is NOT changed: `st.unval.n` also drives `office_request`; it needs its own field.
- That the new holder walks to an office zone and validates (`M.office_check` assigns one) is the path of any vacant appointment, not measured here.

## Tests
`tests/lua/test_bug925_manager_replace.lua` (4): replace after 30 days with the ranking (soldier, child, patient, moody skipped), bounded per span, no candidate, healthy manager, off switch, the verb before / after the span and its refusals.

## Live-Erwartung
On a fort with a long-time patient manager and unvalidated orders: after 30 game days (`manager_replace_days`) kern.log `MANAGER replaced (kernel): unit 29240 could not work for 30 days (resting/injured), unit N appointed`, event MANAGER_REPLACED with `old 29240`, `new N`; `inspect what=manager` names the new unit and orders validate within days (`inspect what=orders` `valid 1`). With `appoint {"code":"MANAGER","unit":29544,"replace":true}` before the span: the refusal names the days.
