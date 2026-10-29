# BUG-231 manager without an office: no order validated for ~330 days, the office waits for its own chair and table
Status: fixed (offline, live-untested)
Severity: high (a fresh fort deadlocks: no door, no seal, no workshop, no tomb, no farm; the perimeter stood open 427 days)
Found: 2026-10-29, Run 15 Guildcleans (pop 20, y372-y373), `runs/run-15-guildcleans/FR-BUGS.md` "Deadlock Büro"
Module: `lua/dfllm/economy.lua` (`validation_watch`, `M.mgr_bypass`, `M.bypass_want`, `M.bypass_days`, `M.bypass_shops`,
`M.bypass_shop`, `M.jneed`, `T.jmake`), `lua/dfllm/act.lua` (`ws_task`), `dfpilot/wake.py` (PROJECT_REQUEST why=manager)

## Actual
brief y372 winter d22: `orders: 13 unvalidated, oldest 58 d: the manager has no office zone`; y373 autumn d19 `inspect what=orders`:
22 orders `valid:0 unvalidated: the manager has no office zone` (#84/#85 Make wooden door 333 days old). The office project
c1a1873b86d5b80201 (placed by hand with `bp.place office`) stood at `build 25% BLOCKED: no progress 222 d`: buildingplan waited
for a chair and a table, and the only orders for them were among the unvalidated ones. No door: SEAL_STUCK, perimeter open 427 d,
workshops, tombs and farms hung (PROJECT_BLOCKED `waits for door x1 (0 free, 3 ordered, 3 not validated)`), a strange mood failed.
DECISION_NEEDED manager_office said `no free chair: add it at a workshop by hand` - a step the AI player cannot take.

## Cause
DF's manager validates work orders only from an office once the fort passes the MANAGER position's office line. Every item the
kernel wanted went through manager orders (quickfort `orders`, T.jmake), including the office's own furniture: a cycle. Nothing
in the kernel made an item without the manager.

## Fix
A player breaks the cycle at the workshop sheet: "add task" needs no manager. New act `ws_task(bld_id, job, mat)`: ONE job of
ConstructThrone / ConstructTable / ConstructDoor / ConstructBed / ConstructBlocks on a built Carpenter's (wood) or Mason's (rock)
workshop, with the job item the task asks for (a log; a non-economic boulder), refused on the wrong shop, an unbuilt one or a full
queue (10). `M.mgr_bypass` (daily, after the validation watch): when the oldest unvalidated order (or the absent manager, or the
office short of its chair/table) is `orders.bypass_days` (5; 0 = off) old, the office's chair and table and the doors, beds and
blocks the planned buildings wait for with none free (T.jmat's classes, `st.jneed`) are added as tasks: wood at a Carpenter's while
logs are free, else stone at a Mason's; the jobs of that type already queued at the shops count (deduped), at most
`orders.bypass_max` (4) a day and `orders.bypass_open` (8) queued at once; kern.log and MANAGER_BYPASS (B). No shop for the material:
PROJECT_REQUEST workshops why=manager types [Carpenters|Masons] at most every 7 days (not while a workshops project or runner's
mandatory request builds it); follow places it like the slabs' Masons.
The logs the unvalidated orders reserve (`M.held_wood`, the same count as scan_orders' `used.wood`) are free for the tasks:
Guildcleans had deep soil and no free stone, and the held wood orders took every log, so `wood_left` alone left nothing to make
a task from. A missing Mason's workshop is asked for only when stone is free. The job item also names DF's item vector (WOOD /
BOULDER) when the build has it.

## Tests
`tests/lua/test_manager_bypass.lua` (the Guildcleans replay, the held wood orders' logs, the doors with bypass_max/bypass_open, stone at the Masons, the shop
request, bypass_days 0), `tests/lua/test_kern_act.lua` `BUG-231 ws_task ...`, `tests/test_bug231_233_manager.py` (contracts, follow
why=manager, knobs). All fail on 6dc0f19.

## Live check
In Guildcleans (or any fort whose orders wait for validation for 5+ days): kern.log `manager orders held N d (no office (chair+table
needed)): workshop tasks chair (wood) at <id>, table (wood) at <id>` and `dfllm events --type MANAGER_BYPASS`; the Carpenter's sheet
lists `Construct wooden chair` / `table` as tasks; a carpenter takes them within a few days, buildingplan attaches them to the office
project, the office zone stands, and `inspect what=orders` shows `valid:1` rows again. If the shop's task list shows no new task or
the job is cancelled at once ("needs ..."), read the job's job_items (item_type, mat_type, flags) read-only: the job item fields are
the [live-untested] part.
