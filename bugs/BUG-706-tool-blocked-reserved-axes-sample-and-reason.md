# BUG-706 TOOL_BLOCKED blames the 3 reserved axes while 17 free ones lie around; 'nothing visible' names no reason
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16a i1 Basementflew (`TOOL_BLOCKED Woodcutters: 1 of 1 hold no axe for 1229 days, 8 FellTree jobs open; 20 free axes (20 loose, 3 reserved by squad uniforms)`, bk `pool` '3 axes not in DF's free equipment list (1521790:assigned 1521816:assigned 1521845:assigned)'; at 814 days bk `none` 'nothing visible')
Module: `lua/dfllm/economy.lua` (`M.tool_listed`, `M.tool_rank`, census WEAPON branch, `M.td_blockers`)

## Root cause
- The census listed the first 8 free tools by item id and `tool_diag` sampled the first 4: the 3 lowest ids were the axes a squad uniform reserved (equipment `items_assigned`), so the sample (and the 'pool' blocker from it) described only those, while 17 usable axes lay in DF's free list. `w_axe_use` also counted a reserved axe as usable.
- When nothing blocked, the text 'nothing visible: ...' named no member, job or pickup list.

## Fix
- A reserved tool is no `use`; `tool_listed` gives its place to a usable one like a far one (`res` / `far` entries are replaced); `tool_rank` puts the reserved last (4), the loops over the ranks read 4 passes.
- New blocker `reserved` (population level): every free tool of the kind is reserved by a squad uniform (the squads screen, equipment); `tool_tell` already has the sentence.
- `none` names the first member's job, the size of his uniform pickup list and the work tool pairs in the fort.

## Tests
`tests/lua/test_bug705_707_wood_axes.lua`: 20 axes / 3 reserved (use 17, no reserved among the 8 listed, no 'pool'), all reserved (`reserved` blocker and text), the `none` text.

## Live check
`inspect what=workload key=tools`: the axes listed first are the usable ones; TOOL_BLOCKED `d.bk` 'reserved' when all are reserved. Open: why DF hands none of the 17 out (the 814-day `none` case) is still not visible in the data we read; the new text names what the member does instead.
