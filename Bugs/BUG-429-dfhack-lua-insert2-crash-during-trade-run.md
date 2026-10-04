# BUG-429: DF crashes (lua_insert2 / stl_string lua_write) during a trade run; about 9 minutes of play rolled back

- **Status:** open
- **Severity:** S1
- **Area:** `lua/claude/handel.lua` (`select --dry`), possibly `lua/claude/mil.lua` (`schedule`)
- **Reported:** 2026-10-04, commit `eb0f007`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack), fort Windrings year 182 (Run 5)

## Command / steps
```
dfhack-run claude/handel open
dfhack-run claude/handel list 0
dfhack-run claude/handel list 1
dfhack-run claude/handel select --dry
```
1. Caravan Catten at the depot, broker job started, trade window open; `list 0` and `list 1` ran without error.
2. `claude/handel select --dry` was running (planned 73 purchases worth 1103) when Dwarf Fortress.exe died.

## Expected
`select --dry` only prints a plan; it never writes game state and never crashes the game.

## Actual
DF process gone at 22:08:17, `dfhack-run` segfaults (MSVCP140.dll, 0xc0000005), the supervisor logs `DF laeuft nicht`. After the restart the 21:59 autosave was loaded: everything between 21:59 and 22:08 was lost (caravan 29 had not arrived yet in the reloaded state, a strange mood, new squads/buildings).
Crash stack (`Bugs/evidence/BUG-429/crash_2026-10-04-22-08-17.txt`):
```
8> dfhack!DFHack::container_identity::lua_insert2+0x4B
9> dfhack!df::stl_string_identity::lua_write+0x1F7B
10> lua53!lua_setlocal+0xE16
...
23> dfhack!DFHack::Lua::SafeCall+0xD4
24> dfhack!DFHack::Lua::RunCoreQueryLoop+0x356
```

## Evidence
`Bugs/evidence/BUG-429/crash_2026-10-04-22-08-17.txt`, `Bugs/evidence/BUG-429/README.md`.

## Analysis (reporter's hypothesis)
The faulting frame is a Lua insert on a DF container that writes a string. Two scripts did such things in that minute: (a) `handel select --dry` (trade agent), (b) the new `mil schedule` command (military agent), which inserts into squad schedule structures from Lua. The military agent has disabled `mil schedule` (rotation now only via `cur_routine_idx`) and says it matches the stack; the trade agent suspected `select`. Not proven which one. A third, weaker suspect is a 2-tick `repeat-util` observer that read THREAD items. A "dry run" must never touch DF vectors.

## Suggested fix
`select --dry` should work on a plain Lua copy of the goods list and never assign to `trade.goodflag` / `trade.good`. Wrap every `insert` on a DF vector in a helper that checks the element type (use `vec:insert('#', df.<type>:new())` for pointer vectors, never a bare string). Add a self-test that runs the helper on a throw-away vector.

## Info needed
Reproduce on a fresh load with only `select --dry` running (no `mil schedule`, no 2-tick observers) and report whether it crashes.
