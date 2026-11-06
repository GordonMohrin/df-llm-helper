# BUG-562 workshops reported `no longer stands` are not rebuilt at the old place: `bp sites workshops` ranks room sites only
Status: fixed (offline, live-untested)
Severity: high (mood workshops missing for a year)
Found: 2026-11-06, Round 35 care/mood/trade (fix35-care), from the Run 16 FR-BUGS files and the runtime logs (read only)
Module: dfpilot/bp/sites.py (_rebuild_shops), dfpilot/bp/rooms.py (_rebuild_shop), dfpilot/plan.py (gone_shops)

## Actual
Run 16b i2 Brotherarrow y398 (kern.log "manifest: workshop Craftsdwarfs at 99,119,134 no longer stands (2 scans)", Clothiers at 107,116,134, 6 entries in
manifest.gone; `runs/run-16b/FR-BUGS.md` "Werkstaetten no longer stands"): R0 `mood_ws` for 417 days, `bp sites workshops --at 99,119,134` "no valid site", `bp.place
workshops only=Craftsdwarfs,Clothiers` "0 free sites"; the places in the fortcore's workshop rooms were free.

## Root cause
The runner (`Q.sync`) prunes a vanished workshop into `manifest.gone` and the plan side counts it as missing, but the only way to build it was the `workshops` template,
whose sites are whole workshop ROOMS (dug box with door) ranked on the Z4 floor. A hall that already stands has no such room site, so nothing could put one shop back on its
old footprint, and `plan propose` drafted a `workshops` build that could not be placed.

## Fix
`workshops rebuild=1` (+ `only=<Type>`, one type): the shop's own footprint (3x3; 1x1 Quern / Millstone; 5x5 Kennels / Siege) centred on a `manifest.gone` position of that
type, newest first. `sites._rebuild_shops` keeps the old places whose footprint is all open floor in the snapshot, clear of the standing workshops, on the citizens' walk
group, and says which and why not; `rooms._rebuild_shop` builds only the workshop (no dig, door, burrow or room). `plan.gone_shops` drafts `workshops only=<Type> rebuild=1`
in seasons[0] for every gone type no workshop of the manifest has and no draft build makes (at most 4). The kernel's kern.log line and the brief's adopt line name the
command. A rebuilt shop's bp file lists it in its manifest, so `manifest.gone` drops it (BUG-066 `Q.ungone`) and `workshops_missing` stops counting it.

## Tests
tests/test_bug559_563_care.py (3): ranked at the old place and emitted (build stage only, manifest lists the shop there, 3x3 from the NW corner), refused with the reason
(a wall on the footprint, a standing shop overlapping, not in gone, several types), propose drafts each gone type once.

## Live check
See CHANGELOG "Round 35 (care)".
