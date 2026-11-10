# BUG-657 The phantom seal of a hatch on a HIDDEN tile comes back every year (BUG-638 only knew revealed rock)
Status: fixed (offline, live-untested)
Severity: medium (SEAL_STUCK / DECISION seal_stalled and a build_lost seal after every plan; `plan check` REJECTED for P2 while the seal stood out)
Found: 2026-11-10, Run 16c i3 Wallfree y400-y404 (seals y400s0b0, y401s0b0, y402s0b0, y403s0b0, y404s0b0 for the hatch 67,44,139: 'nothing stands at 67,44,139', no PROJECT_BLOCKED phantom in 6,195 events), Run 16b i2 Valleyhame y378 (hatch 107,88,126: `plan check` forced `seal at=refuge`, phase_target P2 REJECTED, only P0 applicable)
Module: `lua/dfllm/runner.lua` (`Q.phantom_cells`, `Q.phantom_scan`, runner.lua ~6352-6420), `dfpilot/cmd.py` (`PHANTOM_WINDOW_YEARS`, `phantom_tiles`, `refuge_stair`)

## Actual
Round 41's BUG-638 was meant to drop the seal for a stair that was never dug. It did not: in Wallfree and Valleyhame the kernel logs show no `phantom` anywhere (`grep phantom kern.log` is empty), and the plan drafted `seal at=refuge` again at y400, y401, y402, y403, y404, each one 'lost pieces placed again (4/4)', 'built nothing for 3 days ... cause: not placed', SEAL_STUCK after 10 days, until a player cancelled it.

## Root cause
1. `Q.phantom_cells` (runner.lua ~6357) asks `snapshot.tile` and counts only a REVEALED tile whose char is '#' or 'S'. The tile of a stair nobody dug is not revealed (`snapshot.lua:276`: `des.hidden` -> nil, fair play), so `ok and v == nil`: the cell is no phantom, the scan finds nothing, no event is written, and `cmd.phantom_tiles` has no record. (Valleyhame y377s0b1 and Wallfree y376s0b0 had the same hidden tile; BUG-638 was made from the dump of a revealed one.)
2. Even with an event, `cmd.PHANTOM_WINDOW_YEARS = 2` let the record age out: the plan of the third year after drafted the hatch again.

## Fix
`Q.phantom_cells(K, d, from, built, hidden)`: with `hidden` a cell whose tile reads nil (hidden) and where no building stands or is planned (`Q.bld_at`) is a phantom too, written 'x,y,z ?'. Only `Q.phantom_scan` passes it (a seal already build_lost, or SEAL_STUCK after the retries and the stuck clock): `bp.place` still places a seal on a hidden tile (a hidden tile says nothing yet; refusing would stop a seal for a real, unseen opening). The event text says 'solid rock or never revealed'. `PHANTOM_WINDOW_YEARS` 2 -> 20: a stair dug later is read from the revealed tile first (`refuge_stair`), so the demand comes back by itself.

## Tests
`tests/lua/test_bug657_hidden_phantom.lua` (3: a build_lost seal on a hidden tile is cancelled once, a fresh seal and a seal with an open tile stay, no repeat; bp.place on a hidden tile still places; a hidden tile with a planned building is no phantom), `tests/test_bug657_658_f43_seal.py::test_a_phantom_record_of_a_hidden_hatch_tile_counts_for_years` (a record 5 years old still ends the refuge demand; with the old window the hatch came back).

## Live check
A seal for a never-dug stair: 'built nothing for 3 days' / SEAL_STUCK, then one PROJECT_BLOCKED `phantom: ['x,y,z ?']` and the project is gone; the next `plan propose` has no `seal at=refuge`, `plan check` has no refuge-hatch ERROR (state `nostair`). A real opening is not touched before it is build_lost.

## Residual risk
A real stair whose tile is hidden for another reason and whose seal is build_lost with nothing planned ('not placed') would be cancelled once too; a seal is then drafted again by the entrance check (not by the manifest head), so nothing is lost for good.
