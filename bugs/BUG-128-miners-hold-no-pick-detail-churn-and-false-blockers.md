# BUG-128: the miners hold no pick: detail churn, self-made "pending", a false "upair", pick inflation, an empty tool pile

- **Status:** fixed (offline, live-untested)
- **Severity:** high
- **Module:** lua/dfllm/economy.lua (`tools`, `tool_check`, `tool_diag`/`td_blockers`, `T.toolpile`), lua/dfllm/act.lua (`tool_pile`)
- **Seen:** Run 14 region2-site90 (11 TOOL_BLOCKED, 13 diagnosis lines), also site84, site97, site98 (Run 11: 33 TOOL_BLOCKED, 126 lines)

## What happened
The miners held no pick for most of Run 14 while 97 to 109 free picks lay in the fort.

1. **Detail churn.** The members changed with every TOOL_BLOCKED (ids 29665, 29679, 38261, 39684, 40157, 40631, 42134, ...). WORK_DETAIL
   Miners logged `- basis 0` 23 times and `- basis 4` 12 times: the target fell with the dig backlog, shrink_days (3) later the
   kernel's members left, a new dig job brought new ones. A member who had just been handed a pick or paired by DF left again.
2. **Bad candidates.** The new members were patients (job Rest, needs healthcare), the chief medical dwarf and a bone doctor: they
   never went for a pick.
3. **"for N days" per detail.** `rec.since` counted from the detail's first block, not from a member's: the rotating members all
   showed the same old number.
4. **Self-made "pending".** The tool repair requested the equipment update (`uniform.pickup_flags.update`) and tool_check ran in the
   same pass: `pending` and `update.weapon pending` were the kernel's own fresh request.
5. **False "upair".** `upair` = the member has a work_units pair with a pick that is not one of the TD_PICKS (4) sampled picks. Run 14
   40631 (wu 2108408, loose) and 42134 (wu 2340878, loose): DF had paired them with a loose pick (3 loose of 109, 106 in bins), i.e.
   a fetch, not a blocker.
6. **Pick inflation.** BUG-053's stale count took every unused free pick out of the stock, so the forge and the caravans made up
   picks without end (97 -> 109 picks, 222 free axes).
7. **Empty tool pile.** `dfllm-tools` stood at 44,92,129 while the picks sat in a binned weapons pile at 87,105,123: DF does not
   re-haul items that are stored in a pile that accepts them, so the new pile stayed empty.

## Fix
1. Churn guard (`M.tool_keep`, `M.tool_floor`): a kernel-added member of Miners/Woodcutters never leaves while he holds the tool or
   DF lists a work tool pair for him (work_units), and stays at least `tools.keep_days` (config, default 14; `p.economy.tools[name].at`
   = join ticks). The target never falls below 1 while the detail's jobs (dig / FellTree) exist.
2. Candidates (`M.tool_cand_skip`, `M.tool_prof`): no patients (needs healthcare, job Rest), no unit with a doctor labor (DIAGNOSE,
   SURGERY, BONE_SETTING, SUTURING, DRESSING_WOUNDS); nobles and office holders (the chief medical dwarf included) were already out.
   The best skill first, then the detail's profession (MINER, WOODCUTTER).
3. tool_check: `days` = the oldest member still without the tool (`rec.ms`: id -> first tick without it); a request younger than one
   game day is no `pending` (`upd0` in the unit record; `update.weapon pending` is not shown that day); a member paired with a loose
   (unheld, unforbidden) tool counts as `fetch`, whether that tool was sampled or not; `upair` stays for a pair with a gone, held or
   forbidden tool.
4. Stale cap: the stale count excludes at most stock - (members + 2) of the reachable tools; tools on another walk group (BUG-053
   note 19: nobody can fetch them) may all be excluded.
5. Tool pile: a new `dfllm-tools` is placed with `bins=0` (quickfort `p{... bins=0}`: the stockpile sheet's bin count) and
   `take_from=<id>` of the stockpile the first usable free tool sits in (`M.tool_src_pile`; the sheet's take-from link). Nothing is
   moved by the kernel. A pile that stood before keeps its settings: `stockpiles import` has no library file for containers or links,
   so TOOL_BLOCKED `d.g` tells the player to set dfllm-tools to take from stockpile N (`d.src`).

TOOL_BLOCKED `d.g` names the guards that applied (kept, skipped, request < 1 day, upair->fetch, the stale cap, the pile's source).

## Tests
tests/lua/test_economy_tools_b128.lua (8, each fails on f3f684b); tests/lua/test_act_supply.lua (`tool_pile`: `bins=0`, `take_from`).
Follow-ups: tests/lua/test_economy.lua and test_economy_tools.lua set `keep_days` 0 where they test the shrink order;
test_economy_tools_a3.lua note 34 expects 92 stale picks and no purchase.

## Live check
`dfllm cmd inspect '{"what":"workload","key":"tools"}'` (blocked, stale, pile), the next TOOL_BLOCKED (`d.days`, `d.g`, `d.src`, `d.bk`),
kern.log `tools: Miners blocked` (no `pending` the day of a request, `upd0`), WORK_DETAIL Miners `-` lines (none within 14 days of a `+`).
Reads (read-only Lua through `dfllm cmd inspect`, or the game session's own probe):
`df.global.plotinfo.equipment.work_units` / `work_weapons` (pairs of the members), the members' `u.uniform.pickup_flags.update`,
and for the new pile `sp.storage.max_bins == 0` and `#sp.links.take_from_pile > 0` (the id in `d.src`).
