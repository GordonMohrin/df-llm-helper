# BUG-296 fishing: water under a ramp top has no bank
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15c (Inkintense, FR-BUGS Runde 2)
Module: `lua/dfllm/economy.lua` (M.fish_bank)

## Actual
Run 15c Inkintense: kern.log `water sources: 188 tiles >= 4/7 in 5 bodies, 0 with a bank or a dig`, `fishing: no safe fishing water (160 no bank on the walk group) around 84,95`; the snapshot shows 164 water tiles on z132 (x68-113, y77-118), 117 of them under a ramp top `v` on z133. Root cause: economy.lua M.fish_bank looked one level up only over open space `_` (or a standable brook top); a ramp top `v` is open too but was no bank, and M.FISH_STAND has no `v`.

## Fix
A ramp top over the water counts as open space: the bank is a standable floor beside it, one level up (`up = true`, the fishing zone covers that level too). A ramp top with no floor beside it stays no bank.

## Tests
`tests/lua/test_fix10_economy.lua` (BUG-296). Fail on 05dc764.

## Live check
kern.log `fishing: zone dfllm-fish at x,y,132 (...; bank x,y,133)` at the next food_low/famine scan; `dfllm status` food blockers no longer list fish_zone; the Fisherdwarves detail gets members.
