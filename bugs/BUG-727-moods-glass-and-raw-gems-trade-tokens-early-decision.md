# BUG-727 Mood material the caravans were never asked for: glass has no trade token, a rough gem got the cut-gem token
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y420-y425 (7+ citizens dead of failed moods; a Fey mood needed glass_green, 'Make raw glass: no sand', `trade.want add=["glass"]` answered 'ignored (no item type): glass'; gems 'none reachable'; MetalsmithsForge 58 % for 500+ days)
Module: `lua/dfllm/trade.lua` (`L.KINDS`, `L.CAPS`), `lua/dfllm/reserve.lua` (`R.BUY`, `R.token`), `lua/dfllm/economy.lua` (`M.glass_stuck`), `lua/dfllm/care.lua` (`early_kind`, `mood_early`, `mood_report`)

## Root cause
- `trade.lua:L.KINDS` had no `glass` kind: a glass item is no item type, so the token was dropped as 'no item type' and no caravan was ever asked for the one thing the Fey mood needed.
- `reserve.lua:R.BUY` had no class `glass` (a raw-glass slot's `buy` was `''`) and answered `gem` (SMALLGEM, the cut gem) for a rough-gem slot, so the caravans were asked for the wrong form.
- `care.lua:early_kind` (BUG-575) named bars, rough gems, hard stone and silk at the first report, but not raw glass the fort's chain cannot make (no sand revealed, no furnace and no stone), so the first word came at 15 days from insanity.

## Fix
- `L.KINDS.glass = {ROUGH, SMALLGEM, word 'glass'}` (a raw or cut glass item by its description, cap 6); `trade.want add=["glass"]` is accepted, `rough` (ROUGH) was a token already.
- `R.BUY.glass = 'glass'`; `R.token` answers `rough` for a ROUGH gem slot, `gem` stays for the cut form.
- `economy.glass_stuck(K)` -> `true, text` when the glass chain cannot make raw glass in time (`mood_hint('glass')` impossible, or glass_plan's blockers `no_sand` / `sand_invalid`); `early_kind` takes it as the early kind `glass`; `mood_early` adds `raw glass: <text> (trade.want glass)` to the DECISION_NEEDED `mood_deadline` (early 1) with the `trade.want` command of the mood's tokens.
- Hint text (verifier round): a rough-gem need named `trade.want gem` (the cut SMALLGEM, which does not satisfy a rough-gem mood); now `trade.want rough` in `economy.lua:7327` (`glass_route`), `care.lua:3826` (`ways` for `seen.rough`) and `reserve.lua:50` (`R.HINT.gems`). `economy.lua:7340` keeps `trade.want gem`: that line is the cut-gems / cut-glass route (`via='glass'`), where a cut gem is right.

## Tests
`tests/lua/test_bug727_glass_token.lua` (3): the token and its matching, the buy tokens of glass / rough / cut, the early decision for a raw-glass slot with `glass_stuck` true (names it, `trade.want` with `"glass"`) and none when the chain can make it.

## Live check
`dfllm cmd trade.want '{"add":["glass"]}'` reports no `ignored`; a Fey mood for glass in a fort without sand gets DECISION_NEEDED `mood_deadline` early 1 at once. Open: whether caravans carry raw glass at all; the workshop placement priority (MetalsmithsForge 58 %) is the runner's queue, not changed here; the 7 mood deaths had other causes too (stone, silk, forge shop).
Open (accepted): the forge placement priority (MetalsmithsForge 58 % for 500+ d) is not changed; only glass has the early mood decision.
