# BUG-567 `plan check` refuses a phase raise with an ERROR for a freshly dug opening and names no tile
Status: fixed (offline, live-untested)
Severity: medium (the year plan could not be applied after every gallery / explore dig; the player lowered phase_target by hand)
Found: 2026-11-06, Run 16c i3 Sealcertain y372-y375 (`runs/run-16c/FR-BUGS.md` "Nach jeder Galerie-/Explore-Grabung entstehen 3-10 neue offene Wege; seal at=last musste ich in y372, y373, y374, y375 je 1-2x neu platzieren")
Module: `dfpilot/plan.py` (`perimeter_gate`, `PERIMETER_FRESH_D`)

## Actual
`perimeter: raising phase_target P3 -> P5 while the perimeter is open for 1 day (3 ways in; readiness R0 open_perimeter): seal first ...` as an ERROR one day after a dig opened ways in; the text named no tile.

## Root cause
`perimeter_gate` refused every raise from P2 on while `ready.fail` had `open_perimeter`, whatever its age, and printed only `ready.pw` ("3 ways in"), not `ready.ents`.

## Fix
`perimeter_gate`: the tiles of `ready.ents` are in every perimeter message (`3 ways in at 58,64,142 floor, 73,89,142 floor, ...`); a spell younger than `PERIMETER_FRESH_D` (2) days is a warning (`a fresh opening (a dig, a seal not built yet) ... seal first ...; the raise goes on, max-pop stays held`), older ones refuse as before (the BUG-349 waiver is unchanged). `plan propose` follows (its draft keeps the raise for a fresh spell).

## Tests
`tests/test_bug564_568_f35.py`: a 1-day spell is a warning naming the three tiles (old: ERROR), a 5-day spell still refuses and names them, before P2 and a plan that keeps the phase are unchanged.

## Live check
`dfllm plan check` the day after a gallery dig: a perimeter warning with the tiles, no ERROR; two days later the ERROR with the tiles if the seal has not closed them.
