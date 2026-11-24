# BUG-852 The container cure said nothing when its gate opened or closed or when the pile limit was written or refused
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17d i4 Girderroots (main 55e827ed), 24.11.2026 23:50: `cx_gate` is evaluated inside brew_watch and leaves no trace of its own; the only pile line was `brew stall: stockpile N (name) takes no new barrel: limit old -> new` per written pile and one error line for an unreadable field. A pile whose limit was readable but could not be written (`PL.set` false) was dropped silently, and a freeze that changed nothing said nothing.
Module: `lua/dfllm/economy.lua` (`M.cx_log`, `M.cx_freeze`, `M.watch`), `lua/dfllm/act.lua` (`I.pile_barrels` returns `failed` and `kept`)

## Root cause
No code path logged the gate itself. `act.pile_barrels('freeze')` returned only the piles it wrote.

## Fix
- `M.cx_log` (run from `M.watch`, after every look): one kern.log info line when the gate opens - `container cure ON: DF cancelled brew 12x in 7 d: Needs empty food storage item (>= 5)` - and when it closes - `container cure OFF: DF cancelled brew 0x in 7 d: Needs empty food storage item (< 5)` or `container cure OFF: switch economy.diag.cx_cure is off (DF cancelled brew Nx ...)`. At most one such line per game day (a count hovering at the threshold writes no line per look).
- `M.cx_freeze` logs ONE summary line: `container cure: pile barrel limit written on 2 piles: 41 -1 -> 3, 42 -1 -> 2`, plus `; CANNOT WRITE n: <id> (limit L, k barrels in it)` (a warn) and `; left alone: <id> (limit L, k barrels: no barrel inside | limit already low)` (at most 6). The same words again at most once per game week. The per-pile warn lines stay.
- `act.pile_barrels('freeze')` returns `res.failed` (readable, `PL.set` refused) and `res.kept`.

## Tests
`tests/lua/test_bug847_848_reader_pile.lua`: summary line with old -> new for 2 piles, a repeat adds at most one line, a pile whose `max_barrels` refuses the write is named `CANNOT WRITE 1: 41` (warn) while the other is written. `tests/lua/test_bug851_gamelog_cadence.lua`: exactly one ON line within 7 game days of DF starting to cancel and exactly one OFF line within 8 game days of the last cancel (800 t/s run).

## Live-Erwartung
1. On i4, within about 3 game days of running: kern.log `container cure ON: DF cancelled brew Nx in 7 d: Needs empty food storage item (>= 5)` (once). PROMISED if DF keeps printing the cancels and `economy.diag.cx_cure` is true (baseline.json sets it).
2. At the next brew stall check of cause `nobarrel` (a few game days): `container cure: pile barrel limit written on N piles: <id> <old> -> <new>, ...`, or `written on no pile; left alone: ...`, or `CANNOT WRITE ...`. One of the three is PROMISED when such a check happens; whether a pile is written depends on the field (BUG-848) and on piles that hold a barrel (EXPECTED, not promised).
3. `container cure OFF ...` when the cancels stop for a game week; never more than one ON or OFF line per game day.
