# BUG-437 our own stone-fall traps killed three citizens in the trap hall
Status: fixed (offline, live-untested)
Severity: critical (loses citizens)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y378 (`runs/run-16a/FR-BUGS.md` "BUG Eigene Fallen toeten Zwerge", events.jsonl DEATH #1937, #1943, #1963)
Module: `dfpilot/bp/traps.py`, `dfpilot/bp/fortcore.py` (stage 4), `dfpilot/plan.py`, `dfpilot/cmd.py`, `lua/dfllm/traps.lua`

## Actual
Three citizens died "killed by trap (incident TRAP)" at (76,106,138) twice and (80,111,138): tiles of the manifest's Z2 trap hall (fortcore stage 4, 41 stone-fall traps, every tile of the
1-wide hall) and of the stone bridge lane T91_110_138. Two of them were past thirst 23000 (24659, 23695), the third thirst 38380 / hunger 50665. The fort had no water inside (drink 0 d, no
hospital, levers unlinked for lack of mechanisms), so thirsty citizens walked the hall, the fort's only way out. The kernel reported only `traps 38`, no rule for its own citizens.

## Cause
- `dfpilot/bp/traps.py` (docstring "Safety (citizens)") and `dfpilot/bp/fortcore.py` (stage 4) assumed that DF's traps do not fire on citizens. Stone-fall and weapon traps hit anyone who steps on
  them; only cage traps pass the fort's own (that part is still live-untested). The hall is the way out (O1 -> bailey -> Z2 hall -> field), so every citizen that leaves walks it.
- `plan.py` drafted the hall as a P6 deliverable and, via BUG-377 (`defense_gaps` 'traps 0'), even before growth, with no look at whether the citizens had to leave for water or food;
  `traps.draft` drafted `at=bridges` the same way; `bp.place` accepted both at any time.
- `lua/dfllm/traps.lua` only counted traps; a citizen death by trap raised nothing beyond care's class-B DEATH.

## Fix
- `plan.trap_hold(state)`: the hold applies while `emergency` (drink or food < 30 d, no accepted water) or state `traps.ck` > 0. `propose` drafts neither the hall nor `traps at=bridges` then
  (`traps.draft(hold=True)`; the cage lanes at the doors stay) and says so in the notes; `check` warns for each such build (`trap_hold_gate`); `bp.place` refuses fortcore stage 4 and
  `traps at=hall|bridges|b..` (`cmd.stone_fall_refusal`, called in `cmd.send`) with the reason and the way out (drink and food inside first; cage lanes stay allowed).
- `lua/dfllm/traps.lua`: `EV:DEATH` with `by = trap` for a citizen is counted (state `traps.ck` = those within a year, persisted in `m.traps`) and raises DECISION_NEEDED `trap_friendly` (A,
  q <= 200 bytes, n, unit, pos, cmds, opts), at most once a game day. Contract: `util/contract.lua` + `schema.py` `traps.ck`, CONTRACTS.md, schema appendix.
- Comments in `bp/traps.py` / `bp/fortcore.py` corrected.

## Tests
`tests/lua/test_bug437_trap_friendly.lua` (2), `tests/test_bug437_440_f27.py` (hold, draft, check, bp.place refusal, schema).

## Live check
A fort with the hall built and a thirsty citizen: the DEATH by trap raises `trap_friendly` once; `dfllm plan propose` with drink < 30 d drafts no stage 4 / bridge lane and the notes say BUG-437;
`bp.place` of fortcore stage 4 is refused until drink and food stand. Open risks: whether cage traps really pass citizens (the template assumed it; live-untested), and the hall of an existing
fort is not removed (with `traps.ck` the question tells the player what to weigh: drink inside, B1 up).
