# BUG-153 `inspect what=hospital` reports `no_suture` while 48 citizens suture (the labor is SUTURING in DF 53.16); the patient diagnosis cannot name a civ alert siege did not raise
Status: fixed (offline, live-untested)
Severity: high (a false hospital gap and a wrong labor name in the text; the `alert` reason of a dying patient never fires after a reload)
Found: 2026-10-28, live test i4 (E:/DF-test4, region2-site90 Trussroads, y717-y719), verified on port 5003
Module: `lua/dfllm/water.lua` (`MEDIC`, `MEDIC_LABOR`, `alert_burrows`, `give_diag`), `lua/dfllm/orderlib.lua` (`JOB_LABOR`)

## Actual
- `inspect what=hospital`: gaps `outside, no_diag, no_suture, no_plaster, no_soap`, `doctors.suture {on: 0}`, `no adult citizen has the SUTURE labor on`.
  In the same game `df.unit_labor` is 18 DIAGNOSE, 19 SURGERY, 20 BONE_SETTING, 21 SUTURING, 22 DRESSING_WOUNDS, `df.unit_labor.SUTURE` is nil and
  46-48 citizens have SUTURING on. The unit test hid it: its fake enum had `SUTURE = 53`.
- `orderlib.JOB_LABOR.EngraveSlab = 'ENGRAVER'`: no such labor in 53.16 (slabs are engraved with DETAIL), so the order check never looked for a holder.
- `give_diag` (patient_thirst / PATIENT_DYING `key`): the civ alert reason came only from siege's in-memory alert list (`mem.alist`, runtime only).
  After a kernel reload during an alert, or for an alert the player raised, the list is `{}` and `inside = #names == 0` counted the patient as inside:
  `alert` could never fire.

## Fix
- water: labor names `{'SUTURING', 'SUTURE'}` for the lookup, `MEDIC_LABOR.suture = 'SUTURING'` (the gap text); the skills stay SET_BONE, SUTURE,
  DRESS_WOUNDS (df.job_skill names).
- orderlib: `EngraveSlab = 'DETAIL'`.
- water `M.alert_burrows(idx)`: the burrows of the sounding alert read from the game (`plotinfo.alerts.list[civ_alert_idx].burrows`, the alerts
  screen's list); `give_diag` uses it when siege names none.

## Tests
- `tests/lua/test_water_m1.lua`: the fake enum uses the 53.16 names (SUTURING); a citizen with SUTURING on is a suturer (no `no_suture`); a sounding
  alert with an empty siege list names Kern+ from the game's alert (both fail on main 2c0ffa3).
- `tests/lua/test_care_live_i4.lua`: every labor name the kernel looks up (orderlib, water, care, act, economy) is a df.unit_labor name of 53.16
  (fails on main: ENGRAVER, SUTURE).

## Live check
`dfllm cmd inspect '{"what":"hospital"}'` on a fort with suturers: no `no_suture`, `doctors.suture.on` > 0. Raise a civ alert by hand with a thirsty
patient outside its burrow: patient_thirst `key alert` names the burrow.
