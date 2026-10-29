# BUG-281 CUTOFF 'cause not found' between walk groups 4899 and 4898 during the famine
Status: open (cause not verified offline; the CUTOFF now waits for a second audit, BUG-277)
Severity: medium (3 citizens could not reach food in a famine; the alarm named no tile)
Found: 2026-10-29, Run 15 Inkintense (y373), fix6-alarm-noise
Module: `lua/dfllm/seal.lua` (`blame`)

## Actual
`runs/run-15c-inkintense/FR-BUGS.md`: #442 CUTOFF 'cause not found' (group 4899 vs 4898), #477 starvation '3 cannot reach food'.

## Cause
Not found offline. `blame` looks for closers completed since the last audit, raised bridges whose ring separates the groups, a
closer next to the cut group (bounded walk) and stairs without counterpart. A forbidden or locked door is a closer only when its
neighbours lie on two groups; DF's walk groups are not known to split at a locked door or a burrow edge, so a scan of doors and
burrows on the boundary (the triage's guess) would not explain two groups. Not built: no proof which tile split them.

## What changed here
Nothing in `blame`. With BUG-277 a 'cause not found' CUTOFF comes one audit (a game day or more) later and says how long it held
('cause not found (N d)').

## Live check
At the next 'cause not found': `dfllm cmd inspect '{"what":"reach"}'` and the CUTOFF d.upos / d.at; read-only
`dfhack.maps.getWalkableGroup` along a line between the two tiles and the tile types and buildings (door flags forbidden/closed) where
the group number changes. That tile is the cause to teach `blame`.
