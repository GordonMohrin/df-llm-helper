# BUG-452 A lockdown past its limit in SIEGE/BREACH has no consequence; 33 goblins are 'harmless'
Status: fixed (offline, live-untested)
Severity: high (151 days at 30 t/s, the fort cannot work)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y385 autumn (`runs/run-16a/FR-BUGS.md` "OBS Hinterhalt/Belagerung y385")
Module: `lua/dfllm/reflex.lua` (`cause_scan`, new `overlimit_step`), `dfpilot/wake.py`

## Actual
SIEGE_START d48 with 13 invaders, then 32; lockdown (arrival:invasion) 151 days, the brief "past the limit", the cause "harmless" (size 5200-7100 under `confine.harmless_size` 20000) with "+32 more"; no sortie offer, the soldiers (14, worn 85%) stayed on their stations.

## Root causes
1. `reflex.cause_scan` set `hl` from the nearest unit alone; `confine_picture` and `lone_picture` apply `lone_max`, the cause line did not: a group of 33 showed "harmless".
2. The confinement limit (`confine_step`) and `offer_step` (needs ALERT) never run in SIEGE/BREACH; the lone-intruder clock needs a lone picture. A group in a SIEGE had no clock at all.

## Fix
- `cause_scan`: `hl` is 1 only when the picture is a lone one (`n <= confine.lone_max`); a harmless-sized unit in a larger group reads `dangerous (group of N)`.
- `reflex.overlimit_step` (SIEGE/BREACH, lockdown older than `confine.max_days`, fresh census): DECISION_NEEDED `lockdown_long` (A, again after `max_days` days): days, mode, hostiles counted and the nearest, inside Kern+, `calm` (nothing near or inside), the `squad.sortie` command with the armour verdict when a squad can go, else why not.
  The kernel does not end the lockdown itself (ending it hands the mode to threat's quiet clock: a real SIEGE would fall to RECOVERY, `test_m3_lone` regression). `wake.lockdown_long_hint`. No gate or bridge logic touched.

## Tests
`tests/lua/test_m3_lone.lua` (20 goblins far away: group of 20, one decision after max_days with the sortie command, none again inside max_days, mode stays SIEGE), `tests/test_bug450_456_ops.py` (wake line).

## Live check
A SIEGE lockdown older than `confine.max_days` (10): `dfllm status` cause "dangerous (group of N)" and a class-A `lockdown_long` with the sortie command. Open: the 30 t/s clock itself (arbiter) is unchanged.
