# BUG-894 A seal is set aside in PEACE while the perimeter stands open; a new seal on a planned wall is cancelled after 3 days and placed again
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17d i4 Girderroots: y444s0b0 (186 d), c1a213a80b9291ad96 (714 d) and y447s0b0 (333 d), all aiming at 98,86,143, 'set aside' beside 'PERIMETER OPEN 625 days'; each new seal adopted the planned wall of the one before ('occupied', cancelled after 3 days by BUG-720) and the player was led to place it again.
Module: `lua/dfllm/runner.lua` (`Q.idle_keep` ~l.6920, `Q.dup_planned` ~l.1679, `M.seal_tiles`, `bp.place`), `lua/dfllm/readiness.lua` (`M.perim_open`)

## Cause
`Q.idle_keep` exempted a seal from the set-aside rule only in SIEGE and BREACH; in PEACE a seal without own progress for 30 days lost its slot while the wall it waits for is a DF job. `bp.place` of a seal only checked reach and rock, not that another seal project already plans the wall on every one of its cells.

## Fix
`Q.idle_keep`: a seal or plug is never set aside while `readiness.perim_open` reports the perimeter open (any mode); a set-aside one comes back (the existing 'back after N days set aside (...)' path). `bp.place` of a seal whose every 'Cw' cell lies on a wall that another seal / plug project not done plans (and that is not built yet): refused with 'already planned by project X (seal), job Y, state Z (project set aside) at x,y,z: ...; placing it again only adopts that wall'; no project is created. A seal on another tile, or when the first wall stands, is queued as before. `M.seal_tiles` names the tiles for BUG-892.

## Tests
`tests/lua/test_bug894_seal_keep.lua` (set aside after 30 days with a closed perimeter as before; not set aside in 60 days with an open one; a set-aside one comes back; seal_tiles; the refusal names project, job, state and creates no project; a seal on another tile is queued; a finished first wall is not the refused case). The SIEGE/BREACH rule is the old one; no bridge, gate, refuge or lockdown behaviour changes.

## Live-Erwartung
While 'PERIMETER OPEN' stands, no seal project shows 'set aside' (the three i4 projects return to a runner slot after the reload, kern.log 'back after N days set aside (a seal while the perimeter is open (N d))'); `bp.place tpl=seal` for 98,86,143 answers 'refused: already planned by project y447s0b0 (seal), job 1733178, state no builder ...' instead of queueing a copy. NOT promised: that the three old projects merge (they stay; `bp.cancel` for two of them is the player's call).
