# BUG-718 The famine decision offers only commands that cannot work and never says that no source exists
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16c i3 Wallfree y387-y432 ('tell Gordon, send the option he picks: trade.want' for years: no farm site, no caravan, no animals; the player wished for an honest 'famine unavoidable, only a caravan helps')
Module: `dfpilot/wake.py` (`food_hint`, `no_source_note`)

## Root cause
BUG-459 dropped the farm command when `plan.farm_site` found none and added `trade.want food, seeds` so the list was never empty. The wake line still read 'tell Gordon, send the option he picks as d.cmds has it: <trade.want>' with a small '[not offered: ...]' tail: a list whose only entry is a request that needs a depot and a caravan visit looked like a real option.

## Fix
`wake.no_source_note` (wake.py line 537): when the farm command was dropped and no command that makes food (bp.place, butcher.mark, gather, zone.place, order.add) is left, the line reads 'NO FOOD SOURCE POSSIBLE by command: <why>; nothing else on the list makes food. What is left: <trade.want> (needs a depot and a visit), the kernel's own work (<d.auto>), popcap.lower; tell Gordon plainly that no new source exists, do not retry the dropped command until a sites snapshot shows a farm site'. A decision with a source command left, or a farm site standing, reads as before.

## Tests
`tests/test_bug715_718_f46b_food.py`: only the caravan left -> the honest line (and not the old one); butcher.mark left, a farm site standing, nothing dropped -> unchanged.

## Live check
`dfllm wake` text for DECISION_NEEDED famine / food_low in a fort whose `bp sites farms surface=1` is empty. Open: the kernel's own DECISION text (Lua, `food_q`) still lists the farm command in `d.cmds`; only the wake line (what the player reads) is honest; `popcap.lower` is named but its validity is not checked.
