# BUG-434: Trade planning has no wishlist for mood materials (whole cloth, full thread, shearable animals, desert seeds)

- **Status:** open (feature gap with deadly consequences)
- **Severity:** S2
- **Area:** `lua/claude/handel.lua` (`plan`), `tools/scopes/handel-regeln.md`
- **Reported:** 2026-10-04, commit `eb0f007`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack), fort Windrings year 182-183 (Run 5)

## Command / steps
```
dfhack-run claude/handel list 0
dfhack-run claude/handel list 1
```
Two caravans (Catten, Muboomon) with this wishlist: whole silk/yarn cloth (min dimension 10000), full thread (dimension 15000), live sheep/alpaca/llama, desert seeds, coke.

## Expected
`plan` supports wishlist rules (item type, material class, min dimension, species), shows the purchase plan before the broker moves, and reports unavailable items up front so the player can choose alternatives before pausing.

## Actual
Four citizens died of thirst in strange moods because no whole silk or yarn cloth existed (Zas 20:34, Zasit 21:37, Urvad 22:20; Atir was lucky). Neither caravan offered cloth: Catten had only 3 whole silk threads, 1 giant-spider thread and a bag; Muboomon offered 3 yarn threads, 23 wood, barrels, cheese, fish, meat. `handel` has no wishlist or `min_dimension` rule and does not know that weaving needs "unused collected thread" (trader threads only count after purchase; wild web threads in the caverns never count without CollectWebs). It buys by value and ratio only.

## Evidence
none needed.

## Analysis (reporter's hypothesis)
`handel-regeln.md` has per-category rules for common goods but nothing for CLOTH min_dimension, animals or seeds. Mood stock rules live in `claude/mood` (`tuch.ganz`, `faden_ganz`) and are not connected to trade.

## Suggested fix
Add `wishlist:` to `handel-regeln.md` with `tuch.ganz.<seide|garn|pflanze> < 3` and `faden_ganz < 10` as top buy priorities, `animals: shearable pairs >= 2`, `seeds: desert`; read the numbers from `claude/mood vorrat`; `handel list` prints a "matches wishlist" summary.

## Info needed
`handel list` outputs of several caravans to calibrate which silk/yarn goods merchants of this civilisation actually offer.
