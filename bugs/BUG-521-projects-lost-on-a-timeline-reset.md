# BUG-521 After "TIMELINE RESET" the projects placed in the discarded timeline are gone from the kernel and nobody says so
Status: fixed (offline, live-untested)
Severity: medium (a finished refuge retrofit vanished; the player found out at the next `inspect defense`)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y388-y389 (`runs/run-16d/FR-BUGS.md` "Start Runde 11 ... TIMELINE RESET ... der Retrofit fortcore st3 vom Vorlauf war weg"; events.jsonl #6167 TIMELINE_RESET `tick 156735937 -> 156710269`; read only). Earlier: BUG-121 (the marker), BUG-350 (stale bp files)
Module: `lua/dfllm/runner.lua` (`Q.requeue_reset`, `Q.reset_cmds`), `lua/dfllm/kern.lua` (`K.reset`)

## Actual
The player loaded an older save (autosave). The runner's projects live in that save (`persist projects`), so everything placed after it was gone: the fortcore `retrofit=2 stage=3` project (bp.place ok, finished in the discarded timeline) had to be placed again by hand. The runtime folder still held its bp file and the commands.log line `inbox:c1a1adfb5e77e85301:cli verb:bp.place {...} ok`.

## Root cause
Nothing connected the two: kern wrote TIMELINE_RESET (BUG-121) and dfpilot dropped the events of the discarded line, but the kernel did not look at the commands it had accepted in that line.

## Fix
`kern.lua` gives `K.reset` the two clocks. At the runner's first step after such a boot (`K.reset.kind == 'clock'`) `Q.requeue_reset` reads commands.log (and its rotated half), takes the stretch after the older save's tick that ends where this boot's lines begin (the last place the tick falls), and places the `bp.place` commands of that stretch again through the `bp.place` verb itself (every check runs again) when their result was ok, no `bp.cancel` followed, the loaded save does not have the project and the bp file still exists; at most `CFG.requeue_max` (12), in their order. PROJECTS_REQUEUED (B, runner) names the queued ids, the refused ones with the reason and the number left out. Plan builds are not read (the plan lives in the save and `plan.reload` makes them again). A project nobody wants is cancelled like any other.

## Tests
`tests/lua/test_bug521_requeue.lua` (3: re-queue, cancelled / refused / shared / existing left alone, once per boot and not without a reset, the limit), `tests/test_bug518_522_f32.py` (the event in schema and contract).

## Live check
After loading an older save: `events` shows TIMELINE_RESET followed by PROJECTS_REQUEUED with the ids; `inspect what=projects` lists them.
Open: a project placed in the discarded timeline whose stages were finished there is dug and built again from stage 1 (the runner measures the world and finds most of it done); a placement whose `p.at` depends on the state of the discarded world may be refused (listed under `failed`); commands.log rotates at 1 MB, an older stretch is not read.
