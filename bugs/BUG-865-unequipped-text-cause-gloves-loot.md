# BUG-865 The 'not equipped' text guessed a spec problem, gloves pinned 'armor 0', the loot sweep took metal only
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i4 Girderroots y402 sortie refusal ('the pieces lie free but are not worn: the uniform specs do not match them or nobody fetched them'), `kit.armor 1 of 8` for years, `gloves 0 usable (72 forbidden, 64 owned or carried ...)`; i3 'armor 0 on everyone'.
Module: `lua/dfllm/military.lua` (`kit_missing`, `M.kit_cause`, `M.KIT_HINT`, `loot_item`), `lua/dfllm/kit.lua` (`KIT.soldier`)

## Root cause
(1) `KIT_HINT` was fixed boilerplate added whenever any free weapon or body armor exists: it proved no spec mismatch. (2) `KIT.soldier` set `armor` only when ALL five categories incl. gloves were filled; every glove in the fort was loot (forbidden by DF's standing order for the dead's items) or a civilian's, so `armor` stayed false beside a worn body armor. (3) The loot sweep unforbade METAL pieces only (`loot_item`), never leather/bone/cloth armor of the dead. NOT changed: squad C was re-ordered every ~25 ticks on i4 (the bridge re-stationing, `rt.over`); that this stops the soldiers' pickup is plausible but not shown, and the loop could not be reproduced in the fake world (8 B2 seal flips gave 3 orders with or without a throttle), so no throttle was shipped.

## Fix
(1) the text says `cause: ` with what the kernel measured on the squad: its routine (OFF DUTY), the pieces DF assigned that no soldier wears yet (count, give-back time), or that DF assigned none, and categories without any spec; the boilerplate stays only as a hint after it. (2) `armor` ignores gloves (they stay named in `empty`). (3) the loot sweep also unforbids reachable true armor of the armor categories (not shields, not pieces made by another race).

## Tests
`tests/lua/test_bug864_870_ruest.lua` (armor without gloves; cause text), `tests/lua/test_military_loot.lua` (leather gloves/body unforbidden, wooden shield and held piece stay).

## Live-Erwartung
i4: the next sortie/stand-down refusal names `cause: ...` (off duty / N pieces assigned and not worn / none assigned); the `kit.armor` count rises on soldiers who wear body, head, pants and shoes; kern.log `loot: N forbidden metal weapons, metal and leather armor and ammo unforbidden`. NOT promised: that the soldiers pick the pieces up (DF), or the items' material.
