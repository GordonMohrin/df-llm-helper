# BUG-424: `claude/pfadcheck` missed bypasses of the trap alley (diagonal rule / box limits); `door_flags.forbidden` is reset by the game after seconds -> doors are no reliable seal

- **Status:** open
- **Severity:** S2 (the defence plan relied on "enemies can only come through the traps"; two bypasses stayed unnoticed)
- **Area:** `claude/pfadcheck.lua` (orchestrator script, lives only in the game folder `dwarf-fortress/lua/claude/pfadcheck.lua`, **not in the repo**), `lua/pilot_perimeter.lua` (8-neighbour rule, correct), `df_llm_helper` command `perimeter` (`seal` proposal)
- **Reported:** 2026-10-02, commit `22b9b03`
- **Environment:** Windows 11, game running (DF 53.16 + DFHack), siege

## Observed
1. Two bypasses were found by hand but not reported by `claude/pfadcheck`: a hole at `(91,102,z133)` in the south wall of the trap alley and a side door at `(97,95,z133)`.
2. The orchestrator wrote `door_flags.forbidden = true` on doors and refreshed it by a repeat job every 10 ticks; reading it back showed `true`/`false` alternating, i.e. the game resets the flag after a few seconds (observation only, not recorded).

## Command / steps
```
dfhack-run claude/pfadcheck        # game-folder script, reads walkability in box x30..150, y60..135, z127..137
```
Expected: target `A=Y, B=n` only if there is no way around the trap tiles; the two bypasses above must make `B=Y`.

## Actual
`pfadcheck.lua`, lines ~49-52:
```lua
for _,d in ipairs{{1,0},{-1,0},{0,1},{0,-1}} do try(x+d[1],y+d[2],z) end
for _,d in ipairs{{1,1},{1,-1},{-1,1},{-1,-1}} do
  if walk[key(x+d[1],y,z)] or walk[key(x,y+d[2],z)] then try(x+d[1],y+d[2],z) end
end
```
Diagonal steps are decided from *one* free orthogonal neighbour (the orchestrator's summary). `pilot_perimeter.lua` (`neighbors`, line ~91, mirrors `Grid.neighbors` in `_grid.py`) uses the full 8-neighbour rule and is the reference. The script header itself says "Naeherung" (approximation). The exact reason for the two misses is **not proven**; candidates: (a) the diagonal rule differs from the game's, (b) the hole/door tiles are not in the `walk` set because their tile shape/building (door, hatch, wall with hole) is classified differently, (c) the fixed box limits, (d) forbidden doors are treated as walls (script header: "Forbidden Tueren sind fuer Angreifer Waende") although the flag flips back.

## Evidence
none recorded; coordinates above are from the orchestrator's manual check.

## Suggested fix
1. Put the check into the repo (`lua/claude/pfadcheck.lua`, or reuse the `entry` search of `pilot_perimeter`) with the 8-neighbour rule of `_grid.py`; no hard-coded box (take it from `config.FORT_BOX`).
2. **Test fixture idea:** a 2D grid where two wall tiles touch **only diagonally** (pattern `W.` over `.W`, floor on both other tiles of the 2x2): the step between the two floor tiles must count as passable (permeable). A second fixture: a 1-tile hole in an otherwise closed wall line must yield `B=Y`. Add both to `tests/` next to the grid tests of `pilot_perimeter`.
3. Do **not** treat `door_flags.forbidden` doors as walls in the reachability analysis: `perimeter` counts them as passable; `perimeter seal` proposes walls/closed hatches (`build wall`) instead of "forbid door".

## Acceptance
Both fixtures pass; `perimeter` on a fixture with a forbidden door in the only gap reports `open` (not `sealed`) and proposes a wall tile.

## Info needed
Player: raw answers of `claude/pfadcheck` plus the tile type and building at `(91,102,133)` and `(97,95,133)` (`dfhack.maps.getTileType`, `dfhack.buildings.findAtTile`) so that cause (a)-(d) can be fixed in a recorded fixture.
