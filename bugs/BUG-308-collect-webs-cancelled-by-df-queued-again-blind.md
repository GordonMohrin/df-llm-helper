# BUG-308 collect webs for a silk mood: DF cancels every task, care queues it again blind
Status: fixed (offline, live-untested; DF's cause open)
Severity: high
Found: 2026-10-29, Run 15d (Drillchamber, FR-BUGS Runde 3, y377 win d32 - y378 spr d3)
Module: `lua/dfllm/care.lua` (M.mood_webs), `lua/dfllm/economy.lua` (M.cancel_note, M.cancels_of)

## Actual
Secretive mood 26441 needed cloth(silk); `webs 1694, webs_near 2`; the dwarf went berserk. The player saw "collect webs queued at Loom" at d64 and asked for an earlier start. kern.log shows it started at once: claim popup 152347256, `collect webs queued at Loom 18037` at 152347261, then 25 more times every ~2,950 ticks until the mood failed (152423035). DF's gamelog (E:/DF-test4/gamelog.txt) has 23x `<anyone> cancels Collect webs: Needs undisturbed thread.` from the claim on. So the start was not late; the task never ran. Root cause on our side: care.lua mood_webs queued a new CollectWebs task every `mood_act_every` without asking whether the last one was cancelled, and the line kept saying `queued`. Why DF finds no undisturbed web is not decided offline: older vanilla tasks in the Steam install's gamelog cancel with `Needs 10 undisturbed thread` (a job of 10) or `Forbidden area` (a web found); ours (act.mood_task: a THREAD job item of quantity 1, flags1.undisturbed) is live-untested, and the 2 webs near may be unreachable for DF.

## Fix
economy counts every cancel per job kind with DF's last words (`M.cancels_of(K, 'collect webs')`). care compares that count with the one at its last queue: a new cancel is a failure, kern.log `mood unit N: collect webs cancelled by DF xK (Needs undisturbed thread); buy silk: trade.want cloth:silk`, the same text in MOOD_CRITICAL `d.webs`; from `M.WEBS_FAIL` (3) failures the task is tried only every 3 x `mood_act_every`.

## Tests
`tests/lua/test_bug306_309_moods.lua` (BUG-308), `tests/lua/test_economy_food_run15.lua` (cancels_of). Fail on 9ef2ccb.

## Live check
Next silk mood with webs near: kern.log `collect webs cancelled by DF x1 (...)` after DF's gamelog cancel, the fourth try spaced out. Then read (read-only) the CollectWebs job at the Loom (`job_items[0]`: quantity, flags) and the nearest web (flags `spider_web`, forbid, position, walk group), and compare with a task the player adds from the Loom sheet.
