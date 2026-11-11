# BUG-760 DECISION drink_low says "auto: brew" while nothing brews, and order.add has no brew job
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y443-445: drink 176 -> 59 -> 24 -> 0 days; events #15772 / #15868 "drink 59 d (57 cit, 3177 brewable plants, 14 empty barrels); auto: 8 brews ordered", block [] ; the player saw no brew order and no Still in the manifest, placed `bp.place workshops only=Still`; kern.log "drink 0 days: 8 brews wait, 7 of 139 barrels empty". Run 16c i3 Doorwings: drink 0 repeatedly with no brewable plant (BUG-397/406 cover the plants and farm side).
Module: `lua/dfllm/economy.lua` (`M.drink_block`, `M.verbs['order.add']`, `M.BREW_JOBS`)

## Actual
`M.drink_block` added `auto: brew` whenever one BREW_ order stood open, whether or not it could ever run or had moved; a Still cut off from the citizens (`f['cut:Still']`) was reported as "no still" only by accident of the same flag being unset, and a stalled order was invisible. `order.add` took job names only: `Brew`/`BrewDrink` raised "unknown job" or built an order DF does not know (DF brews through the CustomReaction BREW_DRINK_FROM_PLANT / _GROWTH).

## Root cause
`economy.lua` `drink_block` (the `auto[#auto + 1] = {'brew', ...}` line, near the `labor_holder` check) did not look at blockers already found nor at progress; `order.add` (`M.verbs['order.add']`) had no brew alias.

## Fix
- `drink_block`: `auto: brew` only with a Still the citizens reach and open brews that moved within 7 days (their count fell or the drink days rose, `st.bstall`); otherwise a block entry `brewstall` "N brews ordered, none ran for D days (still stands|missing, plants P, empty barrels B)". A Still that stands but is cut off from every walk group says so ("Still cut off from the citizens walk groups"). A missing Still keeps going through `drink_fix` (PROJECT_REQUEST workshops types=[Still], BUG-255).
- `order.add`: `job` Brew / BrewDrink (BREW_DRINK_FROM_PLANT) and BrewFruit (BREW_DRINK_FROM_PLANT_GROWTH) make the CustomReaction order; the answer names what keeps it from running (no still / no brewable plants / no empty barrel / nobody brews).

## Open
Why the 8 brews stood in i2 with Still, plants, barrels and brewers all present per the census is not readable offline (a Still the census counts but nobody can reach, forbidden or unreachable plants, a busy brewer); the stall text now says it stood still instead of claiming an automatic fix, and the player can read the pieces. No digging is involved. Needs a Kernel reload.

## Tests
`tests/lua/test_bug760_brew_honest.lua` (order.add Brew / BrewFruit / reaction clash; no `auto: brew` beside a missing Still; stall named after 7 days with a Still standing).
