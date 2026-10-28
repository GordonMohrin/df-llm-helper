# BUG-149 `supervise --saves` and the save choice named the wrong fort: every region2 save read as Wheelsblows (site84)
Status: fixed (offline, live-untested); a save written before the fix stays ambiguous until the kernel boots and DF saves again
Severity: high (the restart chain and `--load` match saves by marker: a save of the played fort could be skipped as "another fort")
Found: 2026-10-28, live test i1 (region2-site90 Trussroads), NEW1; confirmed by the verifier
Module: `dfpilot/supervise.py` (`marker_of`, `scan_saves`, `ident_of`, `pick_save`), `dfpilot/save.py`, `dfpilot/loadnow.py`, `lua/dfllm/kern.lua`

## Actual
`t1-trussroads` holds `dfhack-entity-84.dat` (Wheelsblows), `-90` (Trussroads) ... `-98`, each with a `dfllm` marker: a world save keeps
the site data of every fort dfllm ever adopted in that world. `marker_of` returned the first file in name order, so the lowest entity id won.
The newest "adopted" would not help (Wheelsblows 203409054 > Trussroads 200668472).

## Fix
- kern: every boot of a marked save writes the world data key `dfllm.active` = `{save: <runtime key>, fort}` (`kern.ACTIVE_KEY`).
- supervise: `markers_of` reads every marker and the active key (from any `dfhack-*.dat`); `marker_of` returns the active fort's marker,
  the only one, or for several without the key `["?", null, "? (N forts: ...)"]`; scan entries carry `markers`. `same_fort`/`fort_ids`
  match an ident against any fort of an ambiguous folder; `ident_of(saves, folder, key)` picks the fort by the runtime key. `pick_save`, the
  backup size check, `save.py` (fresh autosave, quicksave wait) and `loadnow.choose` use them.
- Limit: a player's own unadopted fort played later in the same world leaves the last `dfllm.active` in place (that save also holds our
  marker; the kernel does not boot there, so nothing overwrites it).

## Tests
- `tests/test_bug149_save_marker.py`: the active fort wins over file order, an ambiguous folder names none and matches both, pick_save does
  not call Trussroads "another fort" (all fail on main); a single marker as before (pin).
- `tests/lua/test_bug149_active_fort.lua`: boot writes `dfllm.active` (fails on main); an unmarked save writes nothing (pin).
