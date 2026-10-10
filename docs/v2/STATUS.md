# df-llm-helper v2: status after the integration check

Date 2026-10-10. Branch `v2`, nothing committed yet. **Offline only:** no v2 code has run in Dwarf
Fortress. Everything below was checked with pytest, luahost (Lua 5.3 on `hack/lua53.dll`) and k_mock.

## 1. Summary
- **Complete offline.** All 16 modules of `contract.MODULES` exist, including `snapshot.lua`, which no
  package had written (CONTRACTS §17 gives it to WP7) and which was added here. The Python side is
  complete: CLI, follow and wake, brief, plan, bp, doctor, supervise, lint and hook. So are the embark
  tool and `plans/year1.json`. `dfllm adopt` on a fake save boots all 16 modules without a fault.
- **Tests.** v2 pytest set: **1087 passed, 0 failed**. It includes 26 Lua suites (426 Lua cases).
  `dfllm lint lua/dfllm`: **0 findings**. `lint --config`: ok.
- **What blocks year 1 live** (§6): three actions have no act function and need Gordon in the UI
  until spikes S2/S3 land:
  - **lever linking**: without it bridges cannot be raised, so a siege ends in BREACH and R1 fails;
  - **squad leaders**;
  - **uniforms**: without them worn = 0 %, so drill 1, P5 and R2 fail.

  A trade pile also has to be made by hand.

## 2. Implemented (per work package)
| WP | Files | State |
|---|---|---|
| WP0 | CONTRACTS.md, schema.py, util/{json,contract,k_mock}.lua, tools/luahost.py | frozen + review round 1 (§19) |
| WP1 | dfllm.lua, kern, io, persist, act, arbiter, perf, selftest, util/geom | kernel; integration: R1/R2/R5/R6/R8 adopted here (§4) |
| WP2 | __main__, cli, paths, files, wake, brief, plan, cmd, doctor, events | all §7 commands work on the fixture runtime |
| WP3 | df_llm_helper/bp/* | fortcore (3 stage projects) + 8 room templates incl. farms; topo audit; site ranking |
| WP4 | fairplay, lint, hook, config/allowlist.json, decisions.yaml, DECISIONS.md, .claude/settings.json | lint 0 findings; hook covers shell and file tools |
| WP5 | sense, threat, gate, siege | siege reflex, BREACH, RECOVERY on fakes |
| WP6 | military, readiness, drill | squads adopted by name (A/B/C), worn %, R0-R3, drills |
| WP7 | runner (+ snapshot, written at integration) | projects, phases, manifest merge, keepers |
| WP8 | baseline, economy, care, config/baseline.json | native baseline, stock days, moods, burial, captives |
| WP9 | trade (act.trade now in act.lua) | caravan port on the click-level fake UI |
| WP10 | supervise.py, tools/migrate_v2.py | liveness, backup, restart (dry-run tested), migration |
| WP11 | tools/embark/*, plans/year1.json, RULES.md | embark checklist and procedure; Y1 phases P0-P7 |

## 3. Integration check
**Inbox verbs → handlers** (static test `tests/test_integration_v2.py`, kernel tests):

| Verb | Handler | Verb | Handler |
|---|---|---|---|
| plan.reload, inspect, module.enable | kern | audit, popcap.lower | readiness (audit: follow/test only, snapshot of this boot, once) |
| bp.place, bp.cancel | runner | tempo.lower, pause, unpause | arbiter |
| drill | drill | trade.want | trade |
| snapshot | snapshot (new) | squad.sortie | military |
| lever | gate | selftest | selftest |

Before this round `module.enable` fell through to `inspect` ("bad what") and `snapshot` had no module.

**Events.** Every type a module emits is in the registry with that module (or `any`) as the emitter.
This is checked statically and by k_mock strict mode. SNAPSHOT_READY was never emitted before; it is now.

**K.call targets.** All exist. `snapshot.export` and `snapshot.tile` were missing; readiness, runner,
care, military and siege call them.

**Files Lua writes, read by Python:**

| File | Writer | Reader | Check |
|---|---|---|---|
| `ACTIVE`, `heartbeat`, `state.a/b.json` | kern | paths, files.read_state_ex (prune rule), supervise | test_kern_files, test_cli_* |
| `events.jsonl` (+`.1`) | kern | files.EventTail, tail_events | rotation tests |
| `outbox/<id>[-n].json` | kern | files.read_outbox | roundtrip test |
| `snap/<id>.json` | snapshot (new) | files.read_snapshot, bp.topo, bp.sites | test_snapshot_files (schema + audit) |
| `perf.csv`, `commands.log`, `kern.log` | perf, kern | doctor, supervise | header identical |
| `restore.json` | arbiter | supervise (read only) | schema |
| `inbox/<ts>-<id>.json`, `plan.json`, `bp/<id>.json` | Python | kern, runner | schema.validate on both ends |

**act coverage.** Every `contract.ACT` function has an implementation. These are explicit stubs that
need a live spike: `squad_leader` [S2], `squad_uniform` [S2] and `order_suspend` [S5], which is
unsupported in DF 53. `idle_crafting` does not exist in act (baseline skips it while it is missing).

**Config.** All four files validate: `config/allowlist.json`, `config/baseline.json`,
`config/decisions.yaml` and `plans/year1.json`.

## 4. Fixes made in the integration round
- **kern.lua (CONTRACTS R1, R2, R5, R6, R8, which WP1 had not adopted):**
  - prunes invalid optional state keys before writing and logs them;
  - measures cost with `os.clock()` (tests override `kern.cost_clock`);
  - slow calls decay, demoted modules are promoted again, and a slow critical module raises KERN_FAULT at most once per 10 min;
  - faults back a module off (critical 30 s, others 10 min, doubling) and it is re-enabled automatically; KERN_FAULT carries `d.backoff_s`;
  - new `module.enable` verb;
  - `VERB_BY` check;
  - `parse_decisions = contract.parse_decisions`. The test_schema xfail now passes and its marker is removed.
- **perf.lua:** rounds the cost-clock floats (files hold integers only).
- **arbiter.lua (R6):** `unpause` releases only the inbox hold. The pause-DECISION text changed to match.
- **gate.lua:** a bridge's `gate_flags` are `raised/raising/lowering` (lever.lua:39-41, v1 BUG-427), not
  `closed/closing/opening`, and reading `gf.closed` raises in DFHack. Without this fix gate would have
  faulted on the first real bridge. It now probes both name sets.
- **act.lua:**
  - WP9's act.trade is pasted in (`A.install_trade`, `gui` required lazily);
  - `quickfort` with `command='orders'` now runs `orders.create_orders` (apply_blueprint never does);
  - explicit `squad_leader` [S2] stub.
- **snapshot.lua (new):** sliced export (1,000 tiles per frame, ms cadence so it also runs while
  paused), revealed-tile legend, manifest bridges from `gate.state`, traps, marks `soil`/`cavern`,
  `tile()` with pending designations, the inbox verb, and default boxes.
- **readiness.lua (R6):** accepts an audit only for an audit snapshot exported this boot, and only once.
- **military.lua:** `kill({})` withdraws running kill orders; `posture(P, force)`. Both are what siege.withdraw calls.
- **runner.lua:**
  - the P0 `baseline` deliverable also passes on `baseline.done()` (kern owns the marker; P0 could never pass before);
  - at most one plan bp file per run (R7).
- **baseline.lua + config/baseline.json:** stockpiles named `dfllm-trade` get `logistics add trade`.
  Nothing fed the depot before.
- **plans/year1.json:** P0 also needs `farms` (fortcore no longer has farm plots).
- **Python:**
  - `files.read_state_ex` uses `schema.prune_state`;
  - `dfllm cmd` offers only `--by cli|llm|gordon` and refuses `audit`; `plan --by` likewise;
  - the hook enforces the §13 trust rules (`--by`, `cmd audit`, inbox JSON with "by") and guards Write/Edit/MultiEdit/NotebookEdit under `dfllm-runtime/` and on `config/decisions.yaml`. settings.json matcher extended.
- **RULES.md:** unpause, backoff, farms and trade pile updated.
- **Tests:**
  - new: `tests/lua/test_kern_contract.lua`, `test_snapshot.lua`, `test_integration.lua`, `snapshot_world.lua`, `snapshot_scenario.lua`, `tests/test_snapshot_files.py`, `tests/test_integration_v2.py`;
  - updated: arbiter tests (R6), readiness, drill and runner tests, trade_scenario (real act.trade), baseline tests and the runner dump (farms).

## 5. Test results (run from the repo root)
```
python -m pytest -q -o addopts="" tests/test_schema.py tests/test_luahost.py tests/test_cli_cmd.py tests/test_cli_files.py \
  tests/test_cli_lua_roundtrip.py tests/test_cli_plan.py tests/test_cli_status.py tests/test_cli_wake.py tests/bp \
  tests/test_lint.py tests/test_hook.py tests/test_fairplay.py tests/test_supervise.py tests/test_migrate_v2.py \
  tests/test_embark.py tests/test_kern_files.py tests/test_runner.py tests/test_siege_files.py tests/test_trade_files.py \
  tests/test_wp6_files.py tests/test_wp8_files.py tests/test_snapshot_files.py tests/test_integration_v2.py
  -> 1087 passed, 0 failed (48 s)
for f in tests/lua/test_*.lua: python tools/luahost.py --path tests/lua $f   -> 26 suites, 426 passed, 0 failed
python -m df_llm_helper lint lua/dfllm        -> 0 finding(s)
python -m df_llm_helper.lint --config         -> config ok
```
**The whole tree** (`pytest tests --continue-on-collection-errors`) also runs the v1 tests:
- 91 v1 tests fail and 11 v1 modules do not collect;
- the cause is that the v1 CLI, wake and brief modules have been replaced by v2;
- no v2 test fails;
- `tests/test_lint_bus.py` (v1 lint over `lua/`) passes;
- these v1 tests go away with the v1 removal (W3).

## 6. Known gaps, by impact
**Needed for year-1 acceptance (A1):**
1. **Lever linking.** No act function exists. Templates build levers, but nothing links them, so:
   - gate pulls only linked levers, giving GATE_FAIL `no_lever` and then BREACH;
   - R1 needs 2 linked levers per bridge.

   Until `act.link_lever` (the UI link job with 2 mechanisms, [S3]) exists, Gordon links every lever in
   the UI after each fortcore stage. **This is safety-critical.**
2. **Squads.** `act.squad_create` needs a vacant position assignment, and `squad_leader` is a stub.
   Military asks Gordon (DECISION_NEEDED `squads`) to create squads A/B/C with a leader; it then
   adopts and fills them. Needs [S2].
3. **Uniforms.** `act.squad_uniform` is a stub, so worn = 0 %. The drill then fails (`no_uniform`),
   which blocks P5 (drill 1, R1 needs a drill for R2) and R2. Needs [S2]; meanwhile Gordon assigns
   uniforms in the UI.
4. **Trade pile.** No template builds one. Gordon names a stockpile next to the depot `dfllm-trade`,
   which baseline then registers. Without it P4 `{k:trade}` never passes.
5. **No smelter or wood furnace template.** `library/furnace` and `library/smelting` are never
   imported (year1 says so). Metal comes from trade only, which P6 metal ≥ 80 % depends on.
6. **No templates for the captive pit or the melt pile** (care and baseline wait for them).

**Operational:**

7. **A supervised restart leaves the fort paused.** DF loads paused, the owner is `df`, and by R6 only
   Gordon unpauses. Unattended years (A2) need a decision, for example: the arbiter releases a `df`
   pause once after a supervised restart in PEACE.
8. **Supervisor alerts reach only `supervise.json`.** There is no wake line (WP10).
9. **The `inspect manifest` reply is capped at 8 KB.** follow's automatic audit stops (AUTO_FAIL) once
   the manifest grows past that, at roughly 40 room projects. Proposal: kern writes `<save>/manifest.json`.
10. **`tempo.lower` cannot slow below the vanilla FPS cap.** timestream ignores targets below the actual
    FPS (tools/timestream.txt:43). The live prefs have FPS_CAP 500, so tempo.lower is close to a no-op.
11. **v1 scripts stay on the DF script path.** After migration, `lua/claude/*` and `lua/pilot_*.lua`
    are reachable through repo A's `lua/`. The hook blocks `claude/*` for the LLM. Remove them in W3.
12. **Small missing act functions:**
    - `order_suspend` (unsupported; economy uses `orders recheck`);
    - `idle_crafting`;
    - removing the kitchen exclusion for D-09 "yes";
    - stockpile settings (barrels in food piles).
13. **Hook limits:**
    - it does not open script files (`bash x.sh`);
    - `tools/embark/embark.py` spawns `dfhack-run lua -f`, which RULES allows before adopt;
    - Write/Edit are guarded only for the two protected places.
14. **DESIGN.md is stale in places:** §0 prefs, `getTickCount` "ms only", "disable that module", and
    the bridge flag names. CONTRACTS §18 already records most of these.
15. **Size.** Most files are 2-3x the DESIGN line estimates (kern 1.1k lines, runner 1.1k, trade 1.2k,
    lint 1.5k, supervise 1.15k).

## 7. Contract changes to adopt (WP0 / orchestrator; implemented, CONTRACTS.md not edited)
- §3.4: snapshot runs on `every={ms=250}` (an export also runs while paused).
- §7 `snapshot.tile`:
  - `dig` is the lower-case `df.tile_dig_designation` name, `smooth`, `engrave`, `track` or `''`;
  - `bld` is the building type (Door, Hatch, Bridge, Trap, Well…), `passable`, `impassable` or `''`.
- §7 `snapshot.export`:
  - without `bbox` the box is the manifest geometry plus a 16/16/2 margin;
  - without a manifest it is 96×96 around the map centre, from 8 levels below the surface to 3 above;
  - at most 250,000 tiles; 4 exports may queue.
- §7: `military.kill({})` means withdraw, and `military.posture(P, force)`.
- §9.9: `baseline` passes on `marker.baseline == 1` or `baseline.done()`.
- §5 `act.quickfort` with `command='orders'`: creates manager orders; stats carry integer keys holding the order quantities.
- §5: the `act.trade` ops as WP9 listed them.
- §9.10 marks:
  - `soil` uses quickfort's farm rule (SOIL, GRASS_* or PLANT material on FLOOR/SHRUB/SAPLING);
  - `cavern` is `designation.feature_global` of revealed tiles.
- §17: snapshot.lua written at integration (WP7 file).
- DESIGN §0: bridge `gate_flags` are named `raised/raising/lowering`.
- `config/baseline.json` gains `trade_piles`.
- §13: the hook also covers Write, Edit, MultiEdit and NotebookEdit; `plan --by` is restricted like `cmd --by`.
- Earlier WP proposals still open (see the WP reports):
  - `act.link_lever` (WP3);
  - squad_uniform `spec.positions` (WP6);
  - `perf.csv` columns `target` and `paused_pct` (WP1);
  - `siege.recovery()` (WP5);
  - census field additions (WP5, WP8);
  - a `supervise` kind (WP10);
  - Z4 merge cap (WP3).

## 8. Live spikes, in order (one live slot; `dfllm-runtime/live.lock`)
**L0: embark and adopt.**
- Embark calibration (WP11 README §7):
  - popup, panel and Neighbors visible together;
  - rectangle fixed while the popup is open;
  - timings.
- adopt and boot. Check:
  - `DISABLED` is absent in `dfllm status`;
  - `dfllm selftest full` passes;
  - `heartbeat` ticks while paused.
- **S1**: `os.clock` gives 1 ms steps in game; kernel ms/s with 16 modules at timestream 500; the
  repeat-util frame callback runs while paused; unpaused_ms is right.
- **S4**: a/b state with a live Python reader; listdir cost; antivirus locks.
- **S7**: report ids for ambush, beast, undead, caravan and dig-cancel damp/warm.
- **S8**:
  - `getBaseDir` prefs (POPULATION_CAP 90); autosave enum; gfps 30; visitor cap;
  - timestream per-save fps; restore on unload;
  - how tempo.lower behaves under FPS_CAP 500.
- Hook spike: in a Claude Code session in `dfpilot-public`, check that the matcher fires for Monitor,
  the terminal MCP, Write and Edit, and that stdin is UTF-8.

**L1: baseline.**
- control-panel enables, seedwatch, autochop 150/60.
- **S5**: `labormanager status` parse in monitor mode.
- **S6**:
  - `apply_blueprint` ms per 40-tile chunk;
  - `command='orders'` creates manager orders (`N manager orders` in kern.log) and buildingplan picks them up;
  - farm plots only on soil;
  - smoothing of soil walls is skipped.
- Snapshot:
  - ms per 1,000-tile slice;
  - the legend against the vanilla view (raised bridge `H`, door `+`, trap `^`, water `w`/`~`);
  - `marks.soil`.
- Care: a hospital location found through `getCurrentSite().buildings`; UNIT_DEATH `isOwnGroup`; the mood job holder.

**L2: fortcore stages 1-2.**
- Runner stalls and cancels, BREACH_STOP on damp.
- Audit snapshot, then follow, then `audit`, then R1. R1 also needs the levers linked by hand (§6.1).

**L3: military and drill.**
- **S2**:
  - the leader appointment path for `squad_leader`;
  - the uniform spec layout and worn roles;
  - whether "assign uniform" covers vacant positions.
- **S3**:
  - leverPullJob latency;
  - `gate_flags.raised` names live;
  - cancelling our own job;
  - flinging and crushing on the footprint;
  - the link job.
- Drill 1 KPIs (DESIGN §14).

**L4: as events occur.** Trade (WP9 spikes):
- the frame of the Trade button;
- reply and totals rows;
- the depot sheet button;
- the confirm prompt;
- readTile cost.

Moods: the workshop-to-material classes.

**L5: soak.**
- **S9**: one supervised restart onto desktop 1 (warn Gordon first). Check that the autosave blocks
  the main thread; resolve §6.7.
- **S10**: difficulty siege triggers, read only.
- PERF_DEGRADED with no false restarts.

## 9. Live bring-up procedure
Run from `C:\Users\admin\claude gordons projects\dfpilot-public` on branch `v2`. Keep sound muted.
**Never adopt Inchcraft**; without the marker the kernel idles.

1. **Offline gate.** Run the §5 commands; all must be green.
2. **Migrate (DF closed).**
   ```
   python tools/migrate_v2.py              # dry run: read every step
   python tools/migrate_v2.py --apply      # refused while DF runs; journal in <DF>/_archive-v1/
   ```
   - The results:
     - `dfhack-config/script-paths.txt` gets `+…\dfpilot-public\lua`;
     - `onMapLoad.init` becomes `dfllm boot`;
     - the v1 runtime is moved away;
     - the DF-Aufsicht task is disabled.
   - Leave `--repoint-task` until S9.
   - `--plugins` (moves the automelt, channel-safely and confirm DLLs) is optional.
   - Undo with `--revert`.
3. **Prefs check (read only).** AppData `prefs/d_init.txt` has `[EMBARK_WARNING_ALWAYS:YES]`.
4. **Live lock.**
   `python -c "import time;from df_llm_helper import files,paths;files.write_json_atomic(paths.runtime_root()/'live.lock',{'holder':'L0','purpose':'bring-up','expires':int(time.time())+1800})"`
5. **Start DF on desktop 1** without stealing focus:
   `powershell -NoProfile -ExecutionPolicy Bypass -File tools\win\start_df_desktop1.ps1`
6. **New fort** (title screen, same world):
   ```
   python tools/embark/embark.py newgame [--world <name>]
   python tools/embark/embark.py scan WX,WY[,LX,LY] ...      # rank sites, embark nowhere
   python tools/embark/embark.py embark WX,WY[,LX,LY]        # --waive ID only after checking by eye
   ```
   If Prepare carefully fails, Gordon does it by hand (README §6). Loading an existing v2 fort
   instead: the main menu, or `dfhack-run load-save <folder>`.
7. **Adopt (in the fort, once).** Add `--acceptance` for the acceptance run; that disables dev exec.
   ```
   dfhack-run dfllm adopt
   dfhack-run dfllm status          # 16 modules, none DISABLED
   dfhack-run dfllm selftest full   # all pass
   ```
8. **Python side.**
   ```
   python -m df_llm_helper doctor
   python -m df_llm_helper status
   ```
   Gordon unpauses in DF: a pause by DF or by Gordon is never released through the inbox.
9. **Year-1 plan.**
   ```
   python -m df_llm_helper bp sites fortcore --fresh
   python -m df_llm_helper plan propose
   ```
   Edit `<save>/plan.draft.json`, then:
   ```
   python -m df_llm_helper plan check
   python -m df_llm_helper plan apply
   ```
10. **Orchestrator.** Start Claude Code with the project directory `dfpilot-public`, so the PreToolUse
    hook applies. Run `Monitor` on `python -m df_llm_helper follow`, with one subagent per wake line
    (RULES.md §5).
11. **Manual steps until the spikes land** (§6.1-6.4):
    - link levers after each fortcore stage (2 per bridge);
    - create squads A/B/C with leaders when DECISION_NEEDED `squads` arrives;
    - assign uniforms;
    - name a stockpile next to the depot `dfllm-trade`.
12. **Supervisor.** Use `python -m df_llm_helper supervise --once --dry-run` to inspect. The scheduled
    task stays disabled until S9.
