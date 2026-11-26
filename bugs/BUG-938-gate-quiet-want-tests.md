# BUG-938 Test debt of round 19b: the quiet-want branch of gate.lua check_fail had no test
Status: fixed (offline, live-untested) -- tests only, no behaviour change
Severity: low
Found: verifier round 2 of BUG-928 (round 19b): the two new quiet returns of `check_fail` (a leftover `peace_gates` / `window_end` want in ALERT / RECOVERY without lockdown; the reach hold) were pinned only through the reach-hold scenarios.
Module: `tests/lua/test_bug938_gate_quiet_want.lua` (gate.lua unchanged)

## Tests (3)
B1 up under the PEACE want `peace_gates` (D-14 up), the mode ALERT (and RECOVERY via SIEGE), B1 lowered from outside, its deadline passed: `br.failed` true, exactly one `kpi.fails` entry `B1:<why>`, no GATE_FAIL, also not 600 ticks later, nobody crushed (the state is read through the gate's own `st` / `rt` upvalues). A raised B1 in ALERT with a stale PEACE deadline (5000 ticks old): `failed` stays false, no kpi entry, not in `not_up`. No defect found: gate.lua is unchanged.

## Live-Erwartung
None (test debt). Note: RECOVERY is reached only after a SIEGE in the test world and the leftover want is set by hand there (SIEGE / RECOVERY rewrite the want); a quiet want in a live RECOVERY is not shown to occur.
