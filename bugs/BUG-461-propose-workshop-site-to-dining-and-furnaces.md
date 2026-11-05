# BUG-461 `plan propose` gave the only workshop site to dining and furnaces
Status: fixed (offline, live-untested)
Severity: high (Still and Butchers could not be placed with drink at 1 day)
Found: 2026-11-05, Run 16d i4 Orbblock y372 (`runs/run-16d/FR-BUGS.md` "Plan nimmt den einzigen Werkstatt-Platz fuer dining/furnaces weg")
Module: `dfpilot/plan.py` (`reserve_shop_room`, `ESSENTIAL_SHOPS`, `SHOP_SPACE_USERS`, `run`)

## Actual
One ranked `workshops` site (fortcore stage 1 not dug yet). `plan propose` set `dining@S1` and `furnaces@S1` on that tile; `bp.place tpl=workshops` was refused ("taken by y372s1b1/y372s2b1") while phase P0 waited for Still and Butchers and drink was 1 day. The player cancelled both by hand.

## Root cause
`apply` resolves `S<k>` in plan order against the free sites, and `propose` drafted the builds in phase-list order: the room builds that share the workshop floor (dining, furnaces, ...) came before the `workshops` build with the essential shops, or the draft had none. Nothing ranked the essential shops first.

## Fix
`plan.reserve_shop_room` (propose, before `fit_placeable`): the shops of `ESSENTIAL_SHOPS` (Still, Kitchen, Butchers, Farmers, Masons, Carpenters, Mechanics) that no workshop of the fort manifest has, built or planned, are drafted ahead of the first new build of `SHOP_SPACE_USERS` (dining, furnaces, tavern, temple, captives): a `workshops` build of the draft that makes one moves in front of it, none in the draft: `workshops only=<missing>` is drafted there. Builds of the applied plan of the same year keep their place. The notes and the CLI print a `BUG-461` line.

## Tests
`tests/test_bug458_461_f28d.py` (drafted ahead, moved ahead, nothing changes when the shops stand / come first / nobody competes / the manifest is unreadable, applied builds stay).

## Live check
`dfllm plan propose` in a fort missing Still/Butchers with dining in the plan: `workshops only=...` precedes dining/furnaces in the draft and `plan check` places it first.
Open: the order decides who gets the floor; if even the first build finds no site, `fit_placeable` leaves it out as before.
