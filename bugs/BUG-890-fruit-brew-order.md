# BUG-890 Fruit brew orders without fruit stay for ever and fill the Stills and the cancel tally
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i3 / i4: 'Brew drink from fruit: Needs unrotten fermentable leaf or fruit' 100-180x a week while brew_p is 12000-16000 plant items (i4 df_reason: census holds 16512 growths, the scan found none).
Module: `lua/dfllm/economy.lua` (`plan_supply`, `M.fruit_off`, `M.brew_share`)

## Root cause
CONFIRMED by code and live words (C7): the supply entry `dfllm:drink_fruit` is made whenever the census `brew_g` > 0 (PLANT_GROWTH with DRINK_MAT that passes the kernel's own skip mask, not DF's UNROTTEN / reachable / unclaimed finder); `keep_order` exempts every BREW_ reaction from the cancel-count removal, so DF cancels it for ever and the Still slots are taken. Why the census sees growths the finder does not: not confirmed.

## Fix
`M.fruit_off`: with `fruit_off_n` (10) cancels of 'Brew drink from fruit' whose reason holds 'unrotten' in the cancel window, `p.fruitoff` is stamped, the open fruit order is removed (`order_remove`) and not made for `fruit_hold_d` (30) days; `brew_share` gives the plant order the whole share meanwhile; after the hold one order is made again and the count decides again. kern.log 'fruit brew off: ...'. Config `economy.cancel.fruit_off_n` (0 = off), `fruit_hold_d`.

## Tests
`tests/lua/test_bug887_891_fass.lua` (12000 fruit: order made; 14 DF cancels: order removed, state set, no new order for 5 days; 36 days later ordered again; share to the plant order).

## Live-Erwartung
i3/i4: the fruit cancel count falls below 5 per 7 d within a week and stays low except one retry (about 5-10 cancels) per 30 days. NOT promised: fruit being brewed when DF's finder cannot see it.
