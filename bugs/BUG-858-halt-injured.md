# BUG-858 The growth halt '(squad)' counted an injured member as unarmed without saying so
Status: fixed (offline, live-untested)
Severity: low
Found: Run 17 i3 Orangering (24.-25.11.): 'growth 30 (squad)' with a badly injured soldier in the first squad.
Module: `lua/dfllm/military.lua` (`M.kit_rows` `u`, `M.kit_stats` `sq_u`), `lua/dfllm/readiness.lua` (`M.growth_ladder`, the status part)

## Fix (reporting only; the gate rule is unchanged)
`kit_stats` counts the first squad's members that hold no real weapon AND are not healthy (a wound that needs treatment, unconscious, thirsty or hungry past the siege marks: military `healthy`) as `sq_u`. `growth_ladder` adds `; N injured` to the need text (`first squad: 2 of 3 members hold a real weapon (need 3+, all armed; 1 injured)`) and `inj` to the halt; the status part reads `growth 30 (squad, 1 injured)`. `halt`, `cap`, the tiers and what passes the step are the same as before.

## Tests
`tests/lua/test_bug858_859_halt_trade.lua`: injured count in the need text and `inj`, halt unchanged, never more injured than unarmed, no count for other halts.

## Live-Erwartung
On a fort whose first squad has a hurt member without a weapon: `status` growth part `growth N (squad, 1 injured)` and the POPCAP `need` text with `; 1 injured` (PROMISED when the kernel's `healthy` test sees the wound). NOT promised: that the gate opens sooner when the injured one heals.
