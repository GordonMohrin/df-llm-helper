# BUG-573 A mood's cut-gem want is not met: the reserve counts rough gems, nobody cuts them, the glass chain starts late
Status: fixed (offline, live-untested)
Severity: high (a Fey mood died; the fort had 93 rough gems and a jeweler)
Found: 2026-11-06, Run 16c i3 Sealcertain y416 (Fey 26276 needed `gems(cut) x1`; the reserve line said `gems 5/5`, the brief `none in the fort`; the glass chain started about 26 days before the deadline)
Module: `lua/dfllm/reserve.lua` (`R.item_class`), `lua/dfllm/care.lua` (`class_total`, `reserve_begin`, `mood_push`), `lua/dfllm/economy.lua` (`classify`, `glass_plan`)

## Actual
The reserve held five ROUGH gems under the class `gems` and reported `gems 5/5` while a mood needed a CUT gem; economy's glass plan took `gems` (rough + cut) as stock, so neither a CutGems order nor glass was started until the mood's want had aged; care told economy only at economy's next cycle.

## Root cause
`reserve.lua` `R.item_class` mapped ROUGH (inorganic) to `gems`; `economy.lua` `classify` counted rough and cut gems in one `gems`, and `glass_plan` (standing stock `nat == 0 and ...`) never cut rough gems at all, it only made glass.

## Fix
`R.item_class`: `gems` = cut form only. Census: `gems_cut`, `gems_rough` next to `gems`. `care.class_total` reads `gems_cut` (falls back to `gems` for an older census), `reserve_begin` lets a ROUGH gem an older run held go (unforbid). `glass_plan`: stock = cut gems + care's held ones; a cut-gem want (mood or the reserve target) is covered first by a `CutGems` work order (`glass.gems`) on the rough gems beyond `glass.rough_keep` (2); the glass chain only where none is spare. `care.mood_push`: a new want of a mood goes to `economy.need` at once (rush run). The reserve line says `gems(cut)`.

## Tests
`tests/lua/test_bug573_575_mood_materials.lua`: census counts, 93 rough gems + jeweler -> one CutGems order and no glass, rough_keep, held cut gems, `item_class`, release of held rough gems, `economy.need` once per class and count.

## Live check
A Fey mood with a cut-gem slot in a fort with rough gems: a `dfllm:cutgems` work order within a run, the reserve line `gems(cut) n/5`.
