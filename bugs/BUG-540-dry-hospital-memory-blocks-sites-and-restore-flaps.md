# BUG-540 A dry hospital memory blocks bp sites for good, hospital.restore on it flaps, and a zone lost before BUG-539 has no way back
Status: fixed (offline, live-untested); open: the zone over a manifest room is the room's bounding box (the old zone's exact shape is not known), `act.hospital_restore` itself is still live-untested (BUG-539)
Severity: high (a fort with patients and no hospital zone, and no command that can fix it)
Found: 2026-11-06, the verifier of BUG-539; Run 16b i2 Brotherarrow (`runs/run-16b/FR-BUGS.md`: "bp sites hospital: no accepted water in Tiefe+ obwohl Zone 17696 ... 12 Kacheln entfernt", "Der Hospital-Raum hospital94_120_137r3 steht noch im Manifest (Betten), nur die Zone fehlt"; read only: `E:/DF-test2/dfllm-runtime/r16b4-brotherarrow-site97/manifest.json`, `bp/y373s2b1.json`, kern.log "1 hospital location(s) without a zone are left alone")
Module: `lua/dfllm/water.lua` (`M.restore`, `M.hrm_count`, `M.orphan_rooms`, verb `hospital.restore`, state `water.hrm`), `dfpilot/bp/sites.py`, `dfpilot/fairplay.py`

## Actual
- `remove_dry` (BUG-034) remembers its zone with `why 'dry'` (BUG-539). Such an entry had no timeout: `water.hrm` counted it for good, and `sites.rank` (sites.py:238) refused `bp sites hospital` / `bp.place hospital` ("the fort's hospital room still stands ...") while it lived, although no water stood near the old room and the kernel itself would not draw it (a dry zone comes back only when `served`).
- `hospital.restore` forced every entry, a dry one too: the zone was drawn, the next water run's `remove_dry` removed it again (a new zone id), the memory was written again: a flap, one removal event per run.
- Brotherarrow (zone 18030 removed on y395 BEFORE BUG-539): nothing was remembered, so neither the kernel nor the verb could do anything. The state at that time (manifest + kern.log): the hospital LOCATION stood without a zone ("1 hospital location(s) without a zone are left alone", BUG-056), the manifest still lists the room `hospital94_120_137r3` (bbox 96,117,137 - 100,123,137, beds), accepted water (the pond zone 17696 at 102,108,138) lay about 10 tiles from it, within `water.near` (30). `bp sites hospital` found no free site (tombs were placed on the old S1 and the ground around is used up), so no hospital at all was possible.

## Root cause
- `water.lua` `M.restore` (old lines ~1534-1571): the `dry` entry was ready when `served`, but with `opt.force` (the verb) it was drawn whatever; no age test anywhere. State `hrm` (old ~3812) counted `#p.hrm`. `sites.py:238` blocked on that count.
- Nothing connected a hospital location without a zone (`r.locs_total - live`, logged only) with the manifest's hospital room.

## Fix
- `conf.hrm_expire` (20 days): `M.restore` forgets older entries (kern.log line).
- `M.restore`: a `dry` entry (and a `room` entry, below) is drawn only when `served` (accepted water within `near` of the old room), force or not; the verb answers with the reason ("zone N (location L): dry: no accepted water within 30 tiles of the old room (nearest: ...); it comes back once water stands near, the memory is forgotten after 20 d"). No flapping.
- `M.hrm_count` (state `water.hrm`, what `bp sites` reads): counts the entries that can come back (not expired; a dry one only with water near) plus the zoneless hospital rooms below, served likewise. A dry memory without water near is 0: `bp sites hospital` is not blocked and finds a site that has water.
- `M.orphan_rooms` (+ `r.orph` from `phase_sites`): the manifest's `tpl hospital` rooms that no live hospital zone overlaps, paired with the zoneless hospital locations of the last water run, become `why 'room'` entries over the room's bounding box (never stored). With no hospital zone standing and water near, the kernel draws the zone after `restore_wait` (half a day); `hospital.restore` does it at once (the Brotherarrow case: the existing room with its beds is reused). `hosp_restore false` keeps only the verb.
- `sites.py`: the message names zones to draw again.

## Tests
`tests/lua/test_bug540_542_hospital.lua` (dry memory: no state key, the verb refuses with the reason, no second removal; water near: the kernel draws it, the verb draws it; expiry after 21 days; the zoneless manifest room is drawn over the room at its old location; without water it is not, with water the state counts it), `tests/test_bug540_542_hospital.py`, `tests/test_bug539_hospital_restore.py`.

## Live check
In a fort whose hospital zone is gone: status `water.hrm`; with accepted water within 30 tiles `hospital.restore` answers "drawn again" and `inspect hospital` lists the zone with the old location; without water it names the reason. Unknown until then: whether `categorize(true)` on the zone is right (BUG-539), whether the manifest bbox equals the old zone.
