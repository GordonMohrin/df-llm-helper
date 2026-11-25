# BUG-915 `why` prints '0 match' for every job item with an item_type: scan the type's vector, say 'scan unverified' otherwise
Status: fixed (offline, live-untested)
Severity: medium (read-only text and the cause code; no game state)
Found: BUG-836 (Run 17 i2 'plant (DRINK_MAT) x1: 0 match'), BUG-868, BUG-896 (boulder 0 match / 0 free beside 53 free boulders), Run 17 i2 order 6936 'wood x1: 0 match' (job item `item_type=5(WOOD) vector_id=18`) beside 202 free logs. The one text with item_type -1 matched ('input empty possible_container x1: 31 match').
Module: `lua/dfllm/jobwhy.lua` (`J.inputs` l.439, `J.input_text`, `J.input_cause`)

## Cause (what the code shows, what stays open)
`J.inputs` walked the vector `ename(df.items_other_id, ji.vector_id)`; `act.lua` (`ws_task` l.1750, `mood_task` l.1794) writes the same field from `df.job_item_vector_id`, and `brewsnap.lua` (`B.vector_id` l.243) decodes it as `items_other_id` too. Whether the two enums share values (WOOD = 18?) cannot be decided offline: no struct file ships in the DF folder. A job item with an item_type can only be met by items of that type, so the scan now walks `world.items.other[<type name>]` (the vector of the item's own type) when the type has one; the decoded `vector_id` stays as `vdec`, a name that differs is printed ('job_item.vector_id decodes as X, the scan walked the WOOD vector'), so one live reading decides the question. The `item_fits` filter (`isSuitableItem` / `isSuitableMaterial`, flags) itself is untouched: if it is wrong for logs, the new text says so instead of '0 match'.

## Fix
A typed scan that matches nothing although items of that type exist (`ntype > 0`, not clipped) is `e.unverified`: text `wood x1: scan unverified (202 items of that type exist, 190 near)` (near = of the first 200 of them, on the workshop's walk group) instead of '0 match, 0 free'; the cause is `scan_unreliable` (not proven, never `no_input`); `attach_df` puts DF's own cancel reason first. '0 match' / `no_input` stay only where no item of the type exists at all.

## Tests
`tests/lua/test_neu1_jobwhy.lua` (3 new: a WOOD job item whose vector_id decodes to FISH_RAW finds the 5 logs; 7 logs exist, none fits: 'scan unverified (7 items of that type exist, 4 near)', `scan_unreliable`, df_reason first; no log at all: '0 match' and no_input; the two old no_input assertions for a rotten plant / a plant without DRINK_MAT are `scan_unreliable` now).

## Live-Erwartung
`dfpilot why order:6936` on i2: either the logs match ('202 match') through the type vector, or `wood x1: scan unverified (N items of that type exist, K near)` with 'job_item.vector_id decodes as <NAME>' if the decoded vector differs; never '0 match, 0 free'. NOT promised: the cause of DF's 'Needs logs' (the position of the logs, BUG-910, is the working hypothesis).
