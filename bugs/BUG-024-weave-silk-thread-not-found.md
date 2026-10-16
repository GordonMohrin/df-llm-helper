# BUG-024 weaving silk never starts: "Needs 1 unused collected silk thread" although 6500 reachable silk threads lie in the fort
Status: open
Severity: medium (84 of 120 citizens are naked for years; Clothiers, Loom and 30+30+30 clothing orders wait)
Found: 2026-10-16 09:20, Run 10 fort Handlelock (region2-site97, y411), dfpilot main 95fe16d + local trade fix
Module: economy / order library (`library/basic` WeaveCloth orders 15-17, own order 427 `WeaveCloth` `material_category: ["silk"]`)

## Actual
Loom (100,134,124) and Clothiers (100,138,124) built and 3/3; `order.add WeaveCloth x40 silk` and MakeArmor/MakePants/MakeShoes with `ITEM_ARMOR_SHIRT / ITEM_PANTS_PANTS / ITEM_SHOES_SOCKS` x30 each (silk) are accepted (active, validated).
The Loom never gets a job. Reports: `Planter cancels Weave thread into silk: Needs 1 unused collected silk thread.`, `Make silk shirt: Needs 1 unused silk cloth.`, `Weave thread into cloth: Needs silk thread.`
Lua: THREAD items `cave spider silk` 6502 reachable (not forbidden, not in a job, no container) + 134 giant cave spider silk + 1993 on unwalkable tiles; 90 citizens have WEAVER on.
A hand-made job (`WeaveCloth` at the Loom, job_item THREAD flags2.silk, BUILDING_HOLDER ref, `linkIntoWorld`) is dropped within seconds (0 jobs after 30 s), unlike the CutGems job built the same way (BUG-016 notes) which ran.

## Expected
Silk thread is woven into cloth (Clothiers get their cloth), or the kernel says which thread filter is not met (`collected` flag, container, weight...).

## Fix proposal
Read the job_item the game uses for "Weave thread into silk" from a real order job and compare with the thread items' flags (`collected`? spun vs. gathered); add a `CLOTHING` stock line to `status` and an A event when naked citizens > 20 for a game month; trade for cloth/leather or hunt for hides as fallback.

Related: BUG-016 (mood materials), BUG-023 (equipment not fetched)
