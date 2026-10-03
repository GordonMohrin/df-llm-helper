# BUG-424: `claude/pfadcheck` missed bypasses of the trap alley (diagonal rule / box limits); `door_flags.forbidden` is reset by the game after seconds -> doors are no reliable seal

- **Status:** fixed in d385352
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

## Fix
The repo never had the game-folder `claude/pfadcheck`; its three suspect rules are now covered by the repo scanner, and
the game copy is replaced on the next `install-lua`:

- `lua/claude/pfadcheck.lua` (new, same name, so `install-lua --apply` overwrites the old copy): a front end of
  `claude/pilot_perimeter scan` with the fort's config values. Output adds `core_reached` (= old "A"), `bypass`
  (= old "B": reaches the core without a trap tile), `entries` `[x,y,z,core,notrap]` (notrap 1 = bypass tile) and
  `door_entries`.
- Cause (a), diagonal rule: `pilot_perimeter`/`_grid.py` already use DF's rule (8 directions, a diagonal step between
  two corner-touching walls is allowed). Now pinned by the fixture `W.`/`.W` (`DIAG_TXT`) in Python and Lua.
- Cause (b)/(d), doors: `pilot_perimeter` classifies door/hatch tiles as `D` **before** the building-occupancy test,
  so a locked/forbidden door is always a way in, even if the game showed its tile as blocking (mock char `L` =
  door with `Obstacle` occupancy; the previous script returned no entry there). `perimeter seal` no longer leaves a
  door entry to the player: it proposes `Cw` walls on the inside floor behind the door, with the note "door/hatch ...
  is no seal (forbidden/locked doors are reset by the game)"; no door at all on its own -> "deconstruct the door and
  build a wall on its tile". Manual `docs/manual-v3/01-perimeter.md` says doors are never a seal.
- Cause (c), box limits: `perimeter.core` and `perimeter.z_range` default to `null`; `pilot_perimeter` takes `-` for
  them and uses `FORT_REFS[1]` and `Z_MIN..Z_MAX` from `claude/config` (x/y are always the whole map). Without
  FORT_REFS it refuses with a usage error instead of guessing. `perimeter allow` warns near the core taken from the
  last scan or the config fort centre.
- Tests: `tests/test_perimeter.py` (`test_bug424_*`: diagonal gap, 1-tile hole -> `B=Y` and closed -> `B=n`, forbidden
  door in the only gap -> reported open + wall proposal, Lua == Python, locked-door occupancy, `-` arguments with
  `MOCK_CORE`), `tests/test_lua_claude.py` (`test_bug424_pfadcheck_delegates_to_pilot_perimeter`).

## Info needed (live check)
After `install-lua --apply`:
1. `dfhack-run claude/pfadcheck` must report `"bypass": true` while the hole `(91,102,133)` or the side door
   `(97,95,133)` is open, with these tiles (or their inside neighbour) among the `entries` with notrap 1.
2. If it still misses them, record for both tiles: `dfhack.maps.getTileType`, `df.tiletype.attrs[tt].shape`,
   `dfhack.maps.getTileFlags(x,y,z).outside`/`.hidden`, `dfhack.buildings.findAtTile(x,y,z)` type and the block
   `occupancy[x%16][y%16].building` value; then a fixture can reproduce the remaining cause.
3. Do not use door locks as a defence: `python -m df_llm_helper perimeter seal --dry-run` lists the walls instead.

