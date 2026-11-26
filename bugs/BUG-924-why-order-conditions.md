# BUG-924 why: order item conditions print the compare TYPE as a number and "N conditions met" counts all of them
Status: fixed (offline, live-untested)
Severity: low (misleading diagnosis text; hid the real blocker, no empty containers)
Found: Run 17 i3, 26.11.: `why brew --raw` order 34 `cond 1: compare=0 value=15 item_type=54(PLANT) ... DRINK_MAT`, `cond 2: compare=0 value=5 item_type=-1 flags1=[empty] flags3=[food_storage]`, `cond 3: compare=1 value=3000 item_type=69(DRINK)`; why printed "0 15 plant (DRINK_MAT)" and "3 item conditions by my count met"; the unmet one was cond 2 (census `cont_free` 0). Diagnosis `leitung/neu10/DIAGNOSE-i3-fasskur.md` section 3.
Module: `lua/dfllm/jobwhy.lua` (`J.conditions`, `J.cmp_name`, `J.CMP_NAMES`, `J.CMP_WORDS`, `J.order`)

## Cause
`CMP` is keyed by name (AtLeast ...); DF's `compare_type` is a number (0 AtLeast, 1 AtMost, 2 GreaterThan, 3 LessThan, 4 Exactly, 5 NotExactly): `CMP[cmp]` was nil, so no scan, `met = nil`, the text started with the number; the summary used `#item_conditions` as the met count.

## Fix
`J.cmp_name` maps the number (a name still works, unknown shows `compare#N`); text in words: `at least 15 plant (DRINK_MAT): 5486 found, met`, `at most 3000 drink: 0 found, met`; every condition ends `, met` / `, unmet` / `, not counted`. The empty-container condition reads the census (`cont_free`, else `barrels_empty`): `at least 5 empty food storage containers: 0 free by the census (DF counts its own way), unmet`; without a census `not counted` (no verdict). The summary is "K of N item conditions met by my count" with K = conditions proven met. An unmet condition gives cause `cond_unmet` (as for the others).

## Tests
`tests/lua/test_bug924_order_conditions.lua`; `tests/lua/test_bug834_838_brew_chain.lua` (wording of two expectations).

## Live-Erwartung
`why brew` on i3: "no job made: item condition not met: at least 5 empty food storage containers: 0 free by the census ..., unmet". Unproven: that the census empties equal DF's own count of fitting containers (barrels in use, forbidden ones); the text keeps the caveat.
