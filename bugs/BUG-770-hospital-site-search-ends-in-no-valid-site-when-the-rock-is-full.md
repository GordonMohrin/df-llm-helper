# BUG-770 `bp sites hospital` ends in 'no valid site' in a full fort: open-floor hospital as the last tier
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16a i1 Basementflew y540 (round 49): `bp sites hospital --fresh` 'no valid site (3965 no door tile, 1015 rock/water, 0 fit)' beside the BUG-763 compact room; patients 27129 (y535) and 31512 (y538) died of thirst / berserk
Module: `dfpilot/bp/sites.py` (`_rank_hospital`), `dfpilot/cmd.py` (`site_params`)

## Actual
Reproduced offline on the live snapshot (`snap/s218161359-4.json`, manifest of the run, accepted water 120,113,130): 959 anchors, 3836 placements, 3130 with no rock door tile, 706 whose room meets rock-free tiles, 0 fit; the compact 5x4 room, 4x4, 4x3 and 3x2 fit none either (the one-tile wall ring round every room meets the dug rooms). The ladder ended there; `hospital surface=1` (open floor beside the fort) was never tried by itself and has 3 sites (90,105,131 22 tiles from the middle, accepted water 24 tiles).

## Root cause
`dfpilot/bp/sites.py` `_rank_hospital`: room near water, compact near water, (with `carry=1`) the carrier tiers, then the error. Nothing went on to the surface hospital that needs no rock.

## Fix
After the dug tiers fail with 'no valid site' (no placement at all), `_rank_hospital` ranks the hospital on open surface floor (`surface` = 1, nothing dug, the same ranking as `bp sites hospital surface=1`, water rules included). Its sites carry `surface` = 1 and say in `why`: 'HOSPITAL ON OPEN SURFACE FLOOR (nothing dug ...; the patients lie outside the walls, exposed in a siege; `surface=0` forbids it; BUG-770)'; `cmd.site_params` puts `surface` = 1 into the document at place time (as BUG-763 does for `compact`). A given `surface` or `compact` (the player's choice) and `furnish` forbid it; a dug room is always preferred; 'no site within N tiles of accepted water' (water too far, not rock) is not a trigger (that stays the player's call, `carry=1`).

## Open
The open-floor hospital is outside the walls: in a siege the patients are exposed (the kernel's recall / care burrow cover water, not a stone roof). A hospital zone over existing beds, and a far carrier route chosen by itself (the kernel still counts a zone more than `water.near` from accepted water as dry), are not done.

## Tests
`tests/test_bug770_hospital_surface_fallback.py` (5), `tests/test_bug763_hospital_site.py` (the dead-end test forbids the open floor). Checked by hand on the live snapshot: `sites.rank(..., "hospital")` returns surface sites 90,105,131 / 92,117,131 / 132,113,131.

## Live check
`dfllm bp sites hospital --fresh` on Basementflew: 3 sites with 'HOSPITAL ON OPEN SURFACE FLOOR', `bp.place tpl=hospital site=S1` takes it (document `surface` = 1).
