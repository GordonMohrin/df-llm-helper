# BUG-831 the kernel's own quiet PEACE raise of the inner gate crushed citizens: nothing kept the footprint clear for the lever latency
Status: fixed (offline, live-untested)
Severity: critical (loses citizens)
Found: 2026-11-24, Run 17d i4 Girderroots y374 (region1-site97): events #895 (citizen 26276, aut d15), #1441/#1442 (soldier 26528), #1631/#1632 (citizen 26278): `BRIDGE_CRUSH ... bridge B1 up (pulled at ...), last seen on it at 65,85,142`; 9 `GATE_CRUSH_RISK` on 45 B1 raises in the same log
Module: `lua/dfllm/gate.lua` (`peace_want`, `control`, `M.quiet_raise`, `M.peace_busy`, `M.peace_wait`, `M.peace_lock`, `M.neu_cfg`)

## Actual
Since NEU1 P5 (D-14 `inner`, docs/v2/NEU1-tore.md) B1 is wanted up in quiet PEACE. In all three deaths the sequence was the same (events.jsonl, kern.log): the return window (`B1 opens for 600 ticks`) ended, `peace_want` wanted B1 up at once (`LEVER pull B1 up` in the same tick as `GATE B1 down`), gate queued the pull while nobody stood within the 1-tile margin or had a readable path onto the footprint, a worker took it 24-235 ticks later (`pull taken 90 ticks after queueing`), the lever was pulled, and the bridge then MOVED for about 300 ticks (`B1 moving` 151490682, `B1 up` 151490983: 536 ticks queue-to-up). DF treats the footprint as passable until the bridge is up, so a unit that started a walk over B1 after the pull was done (nothing can cancel a pulled lever) stepped on it and was crushed (`GATE_CRUSH_RISK B1 moving up with soldier 26528 on the footprint`, `BRIDGE_CRUSH` 4 ticks later). The existing holders (margin 1, `crossers` path <= 20 steps, `raise_movers` 3 tiles) only look until the lever is pulled and only see units with a readable path.
B1 was the main traffic path of i4: 9 of its 45 raises had a unit on the footprint while it moved (20 %), 3 died (6.7 % per raise).

## Fix
A raise in quiet PEACE (why `peace_gates`, PEACE, no lockdown: `gate.quiet_raise`) is no longer pulled until (a) no living unit that is not hostile (citizens, children, pets, visitors, merchants, insane; soldiers at their own station excepted) stood within `gate.peace_clear_r` tiles (default 20) of the footprint for the whole lever latency window `max(gate.peace_clear (600), measured queue-to-up ticks)`; GATE (C) state `peace_wait` names the unit once a game day; (b) while the pull is pending any such unit cancels it (cancel `peace`, no give-up count, no `gate_traffic` question) and the quiet window starts again. (c) A `GATE_CRUSH_RISK` or crush of such a raise locks the bridge down in PEACE for `gate.peace_lock_days` (3) game days, doubled per further risk up to 28 (`m.gate.pq`, GATE state `peace_traffic`); a bridge that is up stays, the windows lower it. (d) `gate.peace_raise` false: no PEACE raise at all (the pre-NEU1 D-14 `down`). SIEGE, BREACH, a lockdown, a window's end and the player's `lever up` are not touched.
Decision from the evidence: a busy inner gate has no safe PEACE raise rule (no signal says who will start walking in the next ~540 ticks), so the fail-safe is the quiet window plus the lock: in a fort where B1 is the main path it stays DOWN in PEACE and goes up on threat (the pre-NEU1 behaviour), in a quiet fort it still rises. The siege reflex is unchanged.

## Open
The rule cannot see a unit farther than `peace_clear_r` that starts a long run, or one that appears (migrants) after the pull; the lock after the first risk bounds that. Dwarves idling within 20 tiles of B1 keep it down in PEACE (fail safe).

## Tests
`tests/lua/test_bug831_833_peace_bridge.lua` (PEACE traffic test: a citizen starts for the footprint after the lever was pulled; fails on main with `crushed: 60 on B1`, passes now; quiet raise; lock; `peace_raise` false; SIEGE traffic test: attackers with civilians outside, bridges up and held, nobody crushed, the shut-out come in after); `tests/test_bug831_833_config.py`; `tests/lua/test_neu1_tore.lua` and four more fixtures given the quiet window.

## Live-Erwartung
1. Zero `BRIDGE_CRUSH` and zero `GATE_CRUSH_RISK` for B1 raises in PEACE (`GATE B1 up` after `LEVER pull B1 up` with why peace_gates) in the i4 / next logs.
2. `GATE` events with `state=peace_wait` name the unit that makes a raise wait (once a game day per bridge); `state=peace_traffic` appears after any risk and B1 then stays down in PEACE for the named days.
3. In a siege `B1`/`O1` still rise within the pull latency (no `peace_wait` in SIEGE/BREACH).
