# BUG-896 Raw fields for the next diagnosis: which free boulders pass the mason filter; items:DOOR; the labor of a construction in `why job:`
Status: fixed (offline, live-untested)
Severity: medium (read-only: no behaviour of the kernel changes)
Found: Run 17d i4 Girderroots: `why ConstructCoffin` / `why ConstructBlocks` 'boulder x1: 0 match, 0 free' while `why items:BOULDER` said 'no exclusion (free as DF sees it): 53' and ORDER_STUCK said '26 / 45 free boulders': no field told which boulders are hard non-economic stone; 'items:DOOR' was not a key the player could use to see why the one free door is never matched.
Module: `lua/dfllm/dfraw.lua` (`R.stone_info`, `R.itemscan`, `spec_of`, `R.ALIAS`, `R.CEN`), `lua/dfllm/jobwhy.lua` (`J.inputs` `btot`, `J.input_text`), `lua/dfllm/economy.lua` (`M.stale_reason`)

## Fix
`why items:BOULDER --raw`: every sample carries `mat=GRANITE hard=true economic=false mason_filter=pass|fail`, the header 'boulders: N free, of them M hard non-economic (a mason job takes only those: flags2 non_economic, flags3 hard)' and 'free boulders by material: ...' (hard = ITEMS_HARD, economic = `plotinfo.economic_stone[mat_index]`, the same two reads the census uses). `items:door`, `items:DOOR`, `bed`, `cabinet`, `box`, `chest`, `coffin`, `table`, `chair`, `throne`, `hatch`, `grate`, `floodgate`, `slab`, `block`, `barrel` are keys (one alias table `R.ALIAS`; a vector this DF does not have is refused; `items:DOOR` already worked as a generic vector name, the aliases add lower case and the census key `doors`). The mason job's input text and the stale-order reason say '0 of 53 free boulders are hard non-economic stone' (`J.inputs` counts the free boulders of the vector next to the matches) instead of '26 free boulders'. `why job:<ConstructBuilding> --raw` prints the labor DF needs and 'N holder(s) of M citizens' (BUG-893).

## Tests
`tests/lua/test_bug896_raw_stone.lua`.

## Live-Erwartung
`dfpilot why items:BOULDER --raw` on i4: 'boulders: 53 free, of them M hard non-economic' with the materials; ORDER_STUCK 'order N ConstructCoffin cannot run for D days: ... 0 of 53 free boulders are hard non-economic stone'; `dfpilot why items:DOOR --raw`: the door item's flags (forbid, in_job, owned), tile, walk group, reason. NOT promised: a cause for the unmatched door (the dump shows the data; the cause is for the next diagnosis).
