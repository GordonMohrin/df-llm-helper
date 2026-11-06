# BUG-549 Finished explore probes and a heavy-stopped aqshaft hold their whole area for good; `bp.cancel` cannot free them
Status: fixed (offline, live-untested)
Severity: high (every room, deepcore and aqshaft site of the fort is taken by dead probes; the year plan cannot place anything)
Found: 2026-11-06, Run 16b i2 Brotherarrow y398 spr d85 and Run 16a i1 Basementflew y395-y415 (`runs/run-16b/FR-BUGS.md` "Fertige explore/aqshaft-Projekte halten ihre Flaeche fuer immer", `runs/run-16a/FR-BUGS.md` "bp sites aqshaft: alle 805 Kandidaten lie on or beside placed projects"; `E:/DF-test2/dfllm-runtime/r16b4-brotherarrow-site97/` and the i1 folder read only)
Module: `dfpilot/cmd.py` (`occupancy`, `shaft_column`, `aq_bottoms`, `no_site_hint`, `run`)

## Actual
`bp sites deepcore` -> `none (3 ranked, 3 project(s) hold them): taken by y374s1b0 (explore), y379s0b0 (explore), y381s0b0 (explore) ... bp.cancel proj=<id> frees them`; `bp.cancel` of each answers `ERR bp.cancel: no project` (the kernel forgets a project when it is done). `bp sites aqshaft` said `all 805 candidate site(s) lie on or beside placed projects` (42 holders). The i2 fort had 25 finished explore probes of 85 tiles (a 13-level stair column and side tunnels at four levels), each held with an 8-neighbour rock tile around it; workshops, suites, stockroom, hospital and deepcore ranked 0 free sites at pop 60.

## Root cause
`cmd.occupancy` (the one place every site test reads the placed projects) added the FULL footprint of every bp file that was not cancelled: "Done projects stay in: their tiles are dug". That is right for a room (it stands), not for an ore probe: the tunnels are open floor the next sites snapshot shows (the ranking meets them as open tiles and keeps off them itself), and no one builds in a dead end. BUG-502 released the planned-but-undug rest of a finished aqshaft (AQ_PASS_DONE `bot`), but a shaft that stopped on a heavy aquifer (AQ_HEAVY, project parked `breach:heavy_aquifer` for good) kept its whole plan (16 or 20 levels), and an explore never got the treatment. The hint (`cmd.no_site_hint`) promised `bp.cancel ... frees them` for finished holders too.

## Fix
- `occupancy`: a finished explore (PROJECT_DONE) is added with `shaft_column(bp_cells(doc))` only: the (x, y) that the most levels share (a stair column of depth + 1 levels; the tunnels lie at a few levels); no column of two levels = all cells. Unfinished probes keep their whole footprint.
- `aq_bottoms`: an `AQ_HEAVY` event of a project (`z`) bounds its held levels like AQ_PASS_DONE `bot` (a shaft stopped for good never dug below it).
- `no_site_hint`: a holder with a PROJECT_DONE and no state row is named `(explore finished)`; the text says a finished project is dug space the kernel no longer has (`bp.cancel` answers `no project`; an explore holds only its shaft column, an aqshaft the levels it dug) and promises `bp.cancel ... frees them` only for the others. `cmd bp.cancel proj=<finished>` prints a note saying the same.
Kept: a finished room, fortcore stage or seal holds its dug tiles; a parked or running probe holds its footprint until `bp.cancel`; cancelled projects (moved to bp/.cancelled) and orphans (BUG-442) are out as before.

## Tests
`tests/test_bug549_553_f35.py`: a finished explore holds 13 shaft tiles, the unfinished one all 100+; `shaft_column` of a bare shaft / no column; an aqshaft with AQ_HEAVY z125 holds z129..z125; the hint names a finished holder and does not promise a cancel.

## Live check
`bp sites deepcore|stockroom|workshops|suites|aqshaft` on a fort with finished explore probes: sites appear where they were `0 free`; `bp.cancel` on a finished probe prints the BUG-549 note. A room placed beside a finished probe's old tunnel may open into the tunnel (a dead end, no effect on the sealed core expected).
Open: a probe's shaft column still holds its stair tiles (and the rock tile around them); a project the kernel cancelled itself without a PROJECT_DONE, whose events rotated out, stays until the orphan sweep can prove it never finished (BUG-442).
