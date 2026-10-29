# BUG-201 A stale door order flips stone -> wood -> stone -> wood (11x 're-entered in wood', 7x 'made again in stone')
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, live test round 3 Earthboat, i-test3 (F6; skeptic confirmed)
Module: `lua/dfllm/economy.lua` (`T.stale` (made-again record))

## Actual
`T.stale` writes the made-again order's record `{left, since, redo}` without `sw`, so the rock gate `rec.sw ~= 1` passes again and the new
stone order is re-entered in wood; that one, stale again, is made again in stone, and so on.

## Fix
- The made-again record keeps `sw = 1` when the old one had it or when the order was made in the other class.

## Tests
`tests/lua/test_economy_b2.lua` (BUG-201). Each fails on bd27973.

## Live check
A stone door order nobody takes: kern.log `re-entered in wood` once, then at most `made again in stone`, then only `made again` for the same
order chain; no second `re-entered in wood`.
