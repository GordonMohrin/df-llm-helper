# BUG-574 A silk mood never gets web collection or silk weaving
Status: fixed (offline, live-untested)
Severity: high (a Fey mood died with 4003 webs in the fort)
Found: 2026-11-06, Run 16a i1 Basementflew y429 (Fey 26880 needed silk; the Loom sheet's CollectWebs task was cancelled seven times `Needs undisturbed thread`; the player's manual CollectWebs x3 order came two days before the death)
Module: `lua/dfllm/economy.lua` (`silk_chain`, `plan_cloth`, `care_hooks`), `lua/dfllm/care.lua` (`mood_report` wants), `lua/dfllm/orderlib.lua` (`O.WS`)

## Actual
The kernel's only step was the Loom sheet task; `plan_cloth` wove nothing because the cloth stock of the other kinds was over the target.

## Root cause
`plan_cloth` worked from the total cloth deficit and `thread_<kind>` stock; a silk want (`care.mood_wants` carried no kind) neither created a deficit nor a CollectWebs work order, and `CollectWebs` had no workshop in `orderlib.WS`.

## Fix
Wants carry `sub` (silk); `care_hooks` sums `silk_cloth` / `silk_thread`; new `M.silk_chain`: no silk thread -> a `CollectWebs` work order at the Loom (`cloth.webs`, webs the citizens reach); silk thread and a cloth(silk) want -> a `WeaveCloth` silk order ahead of the other kinds; reasons (no Loom, webs off the walk group) in `st.silk`. `CollectWebs` -> Loom in `O.WS`; tags `dfllm:webs` in MOOD_TOP / PRUNE_KEEP.

## Tests
`tests/lua/test_bug573_575_mood_materials.lua`: webs and no silk thread -> CollectWebs x3 despite 25 plant cloth; silk thread -> silk weave first, no web order; no Loom / no near webs -> no order.

## Live check
A silk mood with webs on the walk group: `dfllm:webs` work order within a run, then `dfllm:cloth_silk`.
