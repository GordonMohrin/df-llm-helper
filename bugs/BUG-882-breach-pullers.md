# BUG-882 BREACH 'O1 not up at T+900' with the hostiles outside takes the pullers of the O1/B1 lever room away
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17d i4 Girderroots y418 (events #13466/#13467, T+905): `lever pullers dfllm-levers = {} (BREACH)`; O1 rose at +2203, B1 at +2794.
Module: `lua/dfllm/gate.lua` (`allowed`, `duty`, `breach_pulls`)

## Root cause
`allowed()` in BREACH let only rooms with role core (and no outer/inner role) keep pullers, as BREACH meant attackers inside Kern+. A BREACH from `gate_fail` (a bridge not up at T+900 with nothing inside) removed exactly the pullers of the bridges that had failed; the alert list churned Hebel+ in and out and the pulls were 'blocked (levers outside the alert burrow)'.

## Fix
`breach_pulls`: in BREACH a room whose bridge is still wanted up and not up keeps (and is on duty with) its pullers while the census is fresh, no hostile is inside Kern+ and none within BREACH_LEVER_NEAR (6) tiles of the room.

## Tests
`tests/lua/test_bug881_886_ankunft.lua` (BREACH, army outside: citizen 6 is a puller of dfllm-levers, O1 rises; fails on main). Suites test_bug342, test_bug141 unchanged.

## Live-Erwartung
A BREACH with reason gate_fail and nothing inside: kern.log keeps `lever pullers dfllm-levers = {..}` (not {}), O1/B1 rise within the lever latency of the BREACH. With a hostile inside Kern+ or within 6 tiles of the lever room the old rule holds. NOT promised: that the lever room is reachable for the pullers (a BREACH alert of Tiefe+ still routes them through B2).
