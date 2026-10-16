# dfpilot v2: contracts (frozen at wave 0)

Status: **FROZEN 2026-10-10** (WP0), **amended 2026-10-10 after review round 1** (§19 lists what changed and which WP must follow). Every WP implements against this file, `lua/dfllm/util/contract.lua` (the same tables as Lua data) and `dfpilot/schema.py` (validators). If a contract is wrong or missing, implement the closest compliant thing and report the change you need to the orchestrator; only the orchestrator edits this file. A change here must change `contract.lua` and `schema.py` in the same commit; `tests/test_schema.py` fails when they disagree or when the appendix is stale.

DESIGN.md is the *why*; this file is the *what*. Where they differ, this file wins (deviations are listed in §18).

---

## 1. Conventions

### 1.1 Numbers, strings, ids
- **Integers only** in every file Lua writes. Lua `dfllm.util.json` rounds floats half away from zero and writes NaN/inf as `null`. Percentages are integers 0-100. Booleans are JSON `true/false` where the schema says `bool`, and `0/1` where it says `flag` (both appear in DESIGN examples; the schema is exact per field).
- Python writes integers too (plan, bp, inbox). Validators reject floats where an integer is required and reject `true/false` where an integer is required (Python `bool` is not an `int` here).
- **Strings are UTF-8.** DF strings are CP437: convert with `dfhack.df2utf(s)` (Lua API.txt:1012) before putting them in any file or event. `json.encode` replaces invalid UTF-8 with U+FFFD as a last line of defence.
- **Locale.** Never format numbers with `tostring` or `%f`/`%g` into files: the C locale may be German (decimal comma). Use `json.encode` or `string.format('%d', n)`. Lua patterns `%a %c %l %u %w %p %s` depend on `LC_CTYPE`; use explicit byte ranges in parsers.
- **Ids.** Command ids, snapshot ids and project ids match `^[A-Za-z0-9_-]{1,40}$` (`ID_RE`). Bridge names match `^[A-Z][A-Za-z0-9]{0,7}$` (O1, B1, B2). Template names match `^[a-z][a-z0-9_]{1,31}$`. Module names match `^[a-z][a-z_]{1,15}$`.

### 1.2 Time
| Name | Meaning |
|---|---|
| `ytick` | `df.global.cur_year_tick` (0 … 403,199) |
| `year` | `df.global.cur_year` |
| **`tick`** (abs) | `year * 403200 + ytick`. Monotonic, survives year rollover and timestream skips of up to 9 ticks. Every `tick` field in events, persist and snapshots is absolute unless the schema says `ytick`. |
| `ms` | `dfhack.getTickCount()` (Lua API.txt:996), real milliseconds, also advances while paused. It wraps Win32 `GetTickCount` (imported by `hack/dfhack.dll`), which advances in **15-16 ms steps** here even after `timeBeginPeriod(1)`: good for cadences, useless for timing one call |
| cost | `os.clock()` differences × 1000, rounded (as in `hack/lua/profiler.lua:190`). On `lua53.dll` this is MSVC `clock()`: wall time from QueryPerformanceCounter with **1 ms steps** (measured offline 2026-10-10; spike S1 confirms it in game). All kernel cost accounting (§3.3.6-3.3.7, `k.ms_s`, perf.csv) uses it |
| `wall` | `os.time()` epoch seconds (integer) |
| season | `ytick // 100800` → 0 spring, 1 summer, 2 autumn, 3 winter |
| day | 1,200 ticks; month 33,600; season 100,800; year 403,200 (`contract.TICKS`) |

Gameplay cadences use abs-tick deltas (`now.tick - last >= period`), never equality, so skipped ticks cannot skip a run. I/O cadences use `ms`.

### 1.3 Coordinates and boxes
- A position is `[x, y, z]` (JSON array of 3 ints) in files and `{x=, y=, z=}` in Lua APIs that talk to DFHack (`xyz2pos`). Lua module APIs in this file take `{x,y,z}` tables unless stated.
- A **bbox** is `[x0, y0, z0, x1, y1, z1]`, inclusive, `x0<=x1, y0<=y1, z0<=z1`.
- **Distance** is 3D Chebyshev: `max(|dx|, |dy|, |dz|)` (`geom.dist`).

### 1.4 Fair play (binding for every Lua file)
- Only `act.lua` assigns to `df.*`, inserts/erases DF vectors, calls mutating DFHack APIs or runs commands (`dfhack.run_command*`, `reqscript(...)` mutators). Everything else calls `K.act.*`.
- Only `sense.lua` and `snapshot.lua` **iterate** units (`world.units.*`) or map tiles; `seal.lua` also reads revealed tiles and walk groups for the reach and seal audits (FR-22/54, units only by census id). Other modules may look up a citizen or soldier **by id** (ids from `K.census.u` or squad positions) with `df.unit.find(id)` to read its inventory, skills or stress. Hostile units are known only through `K.census.h`.
- Hostiles count only if `dfhack.units.isVisible(u) and not dfhack.units.isHidden(u) and not u.flags1.caged` (Lua API.txt:1460, :1512). Tiles count only if revealed (`not designation.hidden`); hidden tiles are `?` in snapshots.
- Banned anywhere: `createitem`, `dig-now`, `build-now`, `reveal`, `teleport`, `fastdwarf`, `--instant`, `water_table` reads, prospect/locate-ore, writes to skills/body/pos/timers, `removeJob` (except inside `act.cancel_own_lever_job`).
- No `items.all`, `buildings.all`, `reqscript` or `require` inside loops; cache `reqscript` results at module load or init.
- Exempt: `util/k_mock.lua` and `tests/**` (test doubles that fake DF state; never loaded in game).

---

## 2. Lua utilities (WP0 + WP1)

### 2.1 `dfllm.util.json` (WP0)
```lua
local json = require('dfllm.util.json')
json.encode(v) -> string          -- compact, object keys sorted, ints only (see §1.1)
json.decode(s) -> value           -- raises 'json: <msg> at byte N'
json.try_decode(s) -> value | nil, err
json.null                         -- sentinel; encodes as null
json.array(t) / json.object(t)    -- tag a table (needed for empty containers)
json.is_array(t) -> bool          -- true for decoded arrays and json.array tables
json.utf8_clean(s) -> s           -- invalid UTF-8 bytes -> U+FFFD
```
- **Empty plain table encodes as `[]`.** Use `json.object{}` where an empty object is required (e.g. `d`, `data`).
- A plain table whose keys are exactly `1..n` is an array; any other table is an object (integer keys become `"%d"` strings). Float/boolean keys, functions, userdata, cycles and depth > 64 raise.
- Decode: integral numbers become Lua integers (`2.5e1` → `25`), others floats (parsing is locale-proof). `null` in an object drops the key; in an array it becomes `json.null`; a top-level `null` returns `json.null`. Decoded tables carry the array/object tag, so they re-encode identically.

### 2.2 `dfllm.util.contract` (WP0)
Pure Lua (requires only `util/json`), mirrored by `schema.py`: `V, TICKS, abs_tick(), MODES, TRANSITIONS, MODE_SETTERS, POSTURES, MODULES, EVENTS, VERBS, VERB_BY, ACT, STATE_OWNERS, PERSIST, persist_key(), DECISIONS, parse_decisions(text, into?), KERN, REPORTS, SNAP_LEGEND, STATE_SPEC, FMT, check_state(doc), prune_state(doc)`. kern and k_mock use it for validation; do not copy its tables or re-implement its functions.
- `C.check_state(doc) -> errs` (strings `'<path>: <msg>'`, `{}` = valid) judges a Lua state table exactly as `util/json` will write it: a nil field is absent (use `json.null` for null), a plain empty table is an array, floats count as the integers `json.encode` writes. `tests/test_schema.py` checks that `STATE_SPEC` equals `schema.STATE` and that both validators report the same error paths on shared vectors.
- `C.prune_state(doc) -> dropped_keys, errs` removes every **optional** top-level key that has an error (required keys are never removed).
- `C.parse_decisions(text, into?) -> map` is the only Lua reader of `decisions.yaml` (§9.16).
- `C.KERN` holds the fault/backoff and slowness numbers of §3.3.5-3.3.6.

### 2.3 `dfllm.util.geom` (owner **WP1**, needed by W2)
```lua
geom.pos(x, y, z) -> {x=,y=,z=}          geom.arr(p) -> {x,y,z} as array
geom.dist(a, b) -> int                    -- 3D Chebyshev, a/b are {x,y,z} tables
geom.in_bbox(p, bbox) -> bool             -- bbox = {x0,y0,z0,x1,y1,z1}
geom.bbox_center(bbox) -> {x,y,z}
geom.bbox_union(a, b) -> bbox             geom.bbox_size(bbox) -> w, h, d
geom.near_any(p, list, r) -> bool         -- any of list within distance r
```

---

## 3. Module system

### 3.1 Files and loading
- Repo `lua/` is on DFHack `script-paths.txt`. `lua/dfllm.lua` is the only script (commands `dfllm boot|adopt|stop|status|selftest|restore`). At start it prepends its own directory to `package.path` (`<dir>/?.lua`) and loads modules with plain `require('dfllm.<name>')`. Offline, `tools/luahost.py` puts `<repo>/lua` on `package.path`, so the same `require` works.
- A module file has **no side effects at load**: it only defines and returns its table. No `dfhack.onStateChange`, no `repeat-util`, no eventful registration outside kern.
- Modules never `require` other gameplay modules. Cross-module calls go through `K.call` (§4). Utilities (`dfllm.util.*`) may be required directly.

### 3.2 Module table
```lua
local M = {
  name = 'gate',                         -- == file name, see contract.MODULES
  every = {ticks = 25},                  -- or {ms = 500}; may be reassigned at runtime (read each frame)
  critical = true,                       -- optional: never demoted (sense, threat, siege, gate, arbiter)
  reports = {CARAVAN_ARRIVAL = true},    -- optional REPORT filter (df.announcement_type names)
  share = 3,                             -- optional: pacing share in ms per real second (§3.3.8)
  scale = true,                          -- optional: stretch the cadence with the fort-size load (§3.3.8)
}
function M.init(K) end                   -- once per boot, after persist/plan/cfg are loaded
function M.step(K, budget_ms, ctx) end   -- return 'more' to get another slice next frame
M.on = {MODE = function(K, ev) end, REPORT = ..., INVASION = ..., UNIT_DEATH = ...,
        UNLOAD = ..., ['EV:SIEGE_START'] = ...}
M.verbs = {lever = function(K, args, cmd) return ok, msg, data end}
function M.state(K) return {bridges = {...}} end   -- partial state doc, see §9.3
function M.want(K, bridge, want, why) end          -- public API: first arg is always K
return M
```
- `ctx = {dt = <ticks since this module's previous step start; 0 on the first run and on continuation slices>, dt_ms = <same in ms>, cont = <true on a 'more' continuation>, slice = <n-th slice of this run, 1-based>, load = <fort-size load factor >= 1, §3.3.8>}`.
- `budget_ms` is advisory (2 for normal, 1 for critical modules). Slice by work units (≤2,000 tiles, ≤200 items, ≤50 units per slice), not by measuring time.
- `state(K)` must be O(1)-cheap (return precomputed values) and only contain keys the module owns (§9.3).

### 3.3 Scheduling semantics (kern and k_mock implement exactly this)
1. Each frame (`repeat-util` 1 frame), kern computes `now`, delivers queued events (§4.1), then runs modules in `contract.MODULES` order.
2. A tick module is **due** when `now.tick - last_start >= every.ticks * factor`; an ms module when `now.ms - last_start_ms >= every.ms * factor`. `factor` is 1, doubled on demotion. A never-run module is due on its first frame after `init`.
3. Tick modules do not run while paused (ticks do not advance). ms modules run while paused.
4. A step returning `'more'` is called again on the next frame with `ctx.cont = true` regardless of cadence; `last_start` is the first slice's start, so cadence is start-to-start.
5. Every call (init, step, handler, verb, state, `K.call` target) runs in `pcall`. A fault is logged. **3 faults within 10 min (real time) back the module off; no module is ever disabled for good** (the fort must keep defending itself; numbers in `contract.KERN`):
   - the module is skipped (`K.call` returns `false, 'disabled'`, `K.enabled` false, listed in `k.disabled`) for its **backoff**: critical modules 30 s, others 10 min; each further back-off in the same boot doubles it (max 8 min critical, 1 h others); 1 h without a fault resets the doubling;
   - every back-off emits `KERN_FAULT` (A) with `d = {module, err, n, backoff_s}`;
   - when the backoff is over, the module is re-enabled with an empty fault window (no second `init`; its state is kept);
   - the inbox verb `module.enable {module}` (§13) re-enables at once and resets the doubling;
   - a new boot starts with every module enabled (persist `kern.disabled` is diagnostic only).
6. **Demotion.** Per-call cost is measured with the **cost clock** (§1.2, `os.clock()`), never with `getTickCount`. A step, handler or verb call above 5 ms is a *slow call*. **3 slow calls within 10 min** (real time; older ones expire):
   - non-critical module: `factor *= 2` (max 8), `KERNEL_SLOW` (B), the count restarts;
   - critical module: cadence kept, `KERN_FAULT` (A, `err:'slow'`) at most once per 10 min per module.
   - **promotion:** a demoted module gets `factor //= 2` after 10 min of quiet *running* time (frames in which it could run: ticks advancing, or any frame for an ms module) with at least 3 quiet steps (logged; `k.slow` lists only modules with factor > 1). **Hysteresis (FR-62):** a demotion within 1 h of a promotion doubles the quiet time the next promotion needs (at most 16x); `KERNEL_SLOW` is emitted once per module per 6 h, later demotions are only logged.
7. Budget: total kernel time ≤ 25 ms per real second, summed from cost-clock measurements over a 10 s window, cross-checked with `dfhack.internal.getPerfCounters()` (script-manager.lua:293). The selftest `budget` check (FR-62) uses the last minute and the budget for the fort size, `25 + 6 * (units / 150 - 1)` ms/s (at least 25, at most 40; critical modules scan every unit), and names the top cost owners when it fails.
8. **Pacing and load (FR-62, `util/sched.lua`, shared with k_mock).** Every call's cost is booked to its module (a module's own persist keys too); kern's own housekeeping is booked as `k.state`, `k.io`, `k.persist`, `k.inbox`, `k.events`, the rest as `kern`. A non-critical module spends at most its `share` (ms per real second; default 2, seal 4, economy 3, runner 4, snapshot 6, trade 3) on average: while its debt exceeds one second of share, its due runs and `'more'` slices wait. In PEACE the shares of the modules that had to wait in the last 10 s are scaled down together when they exceed what the 25 ms/s budget leaves after the unpaced cost (at least 4 ms/s; a share keeps at least half); outside PEACE shares are 4x and unscaled. `K.load()` = `{units, items, f}` with `f = max(1, units / 150, items / 6000)`; the cadence of economy and care (or a module with `scale = true`) is multiplied by `min(f, 3)`. Critical modules are never paced or stretched.

### 3.4 Modules, owners, cadences
| Module | WP | critical | default `every` | Purpose |
|---|---|---|---|---|
| sense | WP5 | yes | 10 ticks (internally 10/25/50 hostile scan, 100 citizens) | fills `K.census.u`, `K.census.h` |
| threat | WP5 | yes | 25 | arming on INVASION/reports, `threat` state |
| siege | WP5 | yes | 25 | mode FSM, civ alert, posture, SIEGE_* events |
| gate | WP5 | yes | 25 in SIEGE/BREACH/DRILL, else 600 | bridges, single pending pull; lockdown of every lever-linked bridge, peace gates (D-14), lever latency (FR-49/55) |
| reflex | WP5 | yes | 10 | arrival lockdown and interrupt channel (FR-36/49/51/52/53/58): §7, §9.18, §12 |
| military | WP6 | | 3,600 | squads, uniforms, posture, KPIs |
| drill | WP6 | | 600 | drill runs and results |
| readiness | WP6 | | 33,600 + on audit/stage | levels R0-R3, pop cap |
| arbiter | WP1 | yes | 500 ms | pause, tempo, runtime settings, popups |
| runner | WP7 | | 600 | projects, phases, manifest |
| snapshot | WP7 | | 100 (slices while exporting) | snapshot export, tile queries |
| seal | WP7 | | 50 (sliced jobs, `'more'`) | FR-22/24/33/37/54/56/57: reach audit + CUTOFF, entrance check (walk groups, bounded BFS), perimeter manifest and post-siege repair, bridge truth, burrow audits and the civ-alert burrow choice |
| economy | WP8 | | 1,200 | orders, stock days, labor, `K.census.i` |
| care | WP8 | | 1,200 | moods, burial, tomb repair and entomb, ghosts, doctors and hospital posts, captives, stress, hospital water |
| water | WP8 | | 1,200 | patients' thirst, hospital/refuge wells and Water Source zones (accepted: water ≥ 4/7), hospital gate, water sources scan, buckets, cistern flood alarm (iter2; acts item_flag, workorder) |
| trade | WP9 | | 100 | caravan port |
| baseline | WP8 | | 33,600 (+ init) | native baseline idempotent |
| perf | WP1 | | 1,000 ms | perf.csv, frame-gap meter, PERF_DEGRADED |
| selftest | WP1 | | 60,000 ms | in-game selftest |

Kernel files that are not modules: `kern.lua, io.lua, persist.lua, act.lua` (WP1), `util/json.lua, util/contract.lua, util/k_mock.lua` (WP0), `util/geom.lua` (WP1). `snapshot.lua` is assigned to WP7 here (DESIGN §12 does not list it).

### 3.5 Boot, adopt, unload (kern, WP1)
- kern loads every name of `contract.MODULES` with `pcall(require, 'dfllm.' .. name)`; a missing file is skipped and logged, so WPs can land independently. A module whose table fails §3.2 checks (name, `every`) is skipped.
- `dfllm adopt` (once per new fort): writes the marker `{v:2, adopted:tick, save, fort:df2utf(name), acceptance:0, baseline:0, boots:0}`, loads `<repo>/plans/year1.json` into persist `plan.phases`, then boots.
- `dfllm boot` (from `onMapLoad.init`, i.e. `SC_MAP_LOADED`): without the marker it returns at once. Otherwise: heal a crashed `restore.json` (§9.13), write `ACTIVE`, load cfg, persist (`mode`, `kern.ev/seq`), plan; call `init(K)` of every module in order; register eventful; start the `repeat-util` frame callback; emit `BOOT` (C). Modules must expect `init` after every load, possibly mid-siege (mode restored from persist).
- `SC_MAP_UNLOADED`: `on.UNLOAD` for every module (arbiter restores runtime settings), flush persist and files, stop the callback, delete `ACTIVE`, emit `UNLOAD` (C). `dfllm stop` does the same without unloading.

---

## 4. K interface
`K` is one table passed to every module function. Fields are read-only for modules unless stated.

| Member | Signature | Semantics |
|---|---|---|
| `K.now()` | `-> T` | `T = {tick, ytick, year, season, ms, wall, paused, frame}`. Same table for the whole frame; do not mutate or keep. |
| `K.emit` | `(type, cls, msg, d) -> n` | Append an event (§12). `type` must be registered; the registry class wins if `cls` differs (logged). `msg` ≤ 200 bytes (truncated at a UTF-8 boundary), `d` an object ≤ 1 KB encoded (else replaced by `{trunc=1}`); nil `d` → `{}`. Class A events flush to disk in the same frame, B/C within 1 s. Returns the event number `n`. Emitting only on change is the emitter's job. |
| `K.census` | table | `{u=..., h=..., i=...}` (§6). Owners replace the subtables wholesale; readers never mutate. |
| `K.mode()` | `-> string` | current mode (§14) |
| `K.mode_since()` | `-> tick` | abs tick the mode was entered |
| `K.set_mode` | `(mode, why) -> ok, err` | Only callers allowed by `contract.MODE_SETTERS` and transitions in `contract.TRANSITIONS`. Synchronously calls every module's `on.MODE(K, {from, to, why, tick})` (each in pcall), persists `mode`, emits `MODE` (C) and flushes state in the same frame. Calling it from inside an `on.MODE` handler returns `false, 'reentrant'`. |
| `K.act` | table | the act API (§5). The calling module is implicit (kern knows who runs). |
| `K.persist` | `.get(key) -> table|nil`, `.set(key, value)`, `.touch(key)` | Site data (§10). `get` returns the cached decoded table; mutate it and call `touch(key)`, or `set` a new table (`nil` deletes). kern writes dirty keys at most every 10 s, on mode change and before unload. Keys are contract names (`'manifest'`, `'m.runner'`, `'bp.c123'`), not DFHack keys. |
| `K.plan` | table | Active plan (§9.7) with defaults filled; never nil (defaults when no plan). Replaced on `plan.reload`, so read `K.plan` each time. `K.plan.phases` holds the phase list (§9.9). |
| `K.cfg` | table | `{decisions={['D-01']='A',...}, allowlist=<§9.14>, baseline=<config/baseline.json>, reflex=<config/reflex.json §9.18, {v=2} when missing>, paths={df, runtime, save, repo}, save=<folder>, dev=bool, acceptance=bool}` |
| `K.log` | `(level, fmt, ...)` | level `'debug'|'info'|'warn'|'error'`; to `kern.log`; `error` also `dfhack.printerr`. |
| `K.call` | `(module, fn, ...) -> ok, ...` | Calls `M[fn](K, ...)` of another module in pcall. Faults count against the callee. Returns `true` followed by the callee's return values, or `false, 'no module'|'disabled'|'no function <fn>'|err`. |
| `K.view()` | `-> doc` | the last composed state document (§9.3) as a Lua table; how modules read other modules' published KPIs |
| `K.manifest()` | `-> table` | `K.persist.get('manifest')` or an empty manifest skeleton (never nil) |
| `K.flush()` | | compose and write state at the end of this frame |
| `K.enabled(module)` | `-> bool` | module loaded and not backed off (§3.3.5) |
| `K.load()` | `-> {units, items, f}` | fort size (§3.3.8): visible units (sense's count, −1 unknown), `#world.items.all`, load factor `f` ≥ 1; refreshed every 5 s |

### 4.1 Event delivery to modules
- kern registers eventful (`require('plugins.eventful')`, frequency INVASION 10, REPORT 10, UNIT_DEATH 100) on `SC_MAP_LOADED`. Callbacks only enqueue. Queued items are delivered at the start of the next frame:
  - `on.INVASION(K, {id, tick})`
  - `on.REPORT(K, {id, type, text, pos, tick})`: `type` = `df.announcement_type[report.type]` name, `text` = UTF-8 ≤ 200 bytes, `pos` = `{x,y,z}` or nil. Delivered only to modules whose `M.reports` contains `type` (or that have no `reports` filter).
  - `on.UNIT_DEATH(K, {unit, tick})`
  - `on['EV:<TYPE>'](K, event)` for events emitted in the previous frame (event = the §12 record).
- `on.MODE` is synchronous inside `K.set_mode`. `on.UNLOAD(K, {})` runs on `SC_MAP_UNLOADED` before persist is flushed (arbiter restores settings there).
- Routing hints for report types are in `contract.REPORTS` (names from `data/init/announcements.txt`; confirm with spike S7).

---

## 5. act API (`lua/dfllm/act.lua`, WP1)
Every function returns `ok, res_or_err`, never raises, writes one line to `commands.log` (§9.12) with the calling module, and emits `ACT_FAIL` (B) on failure. kern refuses calls from modules not listed in `contract.ACT[fn]` (`false, 'not owner'`). Positions are `{x,y,z}`.

| Function | Args | UI equivalent / implementation | Caller |
|---|---|---|---|
| `set_paused(on)` | bool | pause button (`df.global.pause_state`) | arbiter |
| `timestream(fps)` | int, −1 = off | `timestream set fps N` | arbiter |
| `setting(name, value)` → `ok, old` | `gfps` int, `fps_cap` int (vanilla FPS cap; the clock governor: mode caps, the reflex clamp, supply brake, `tempo.lower`), `autosave` enum name [S8], `visitor_cap` int, `population_cap` int (restore only), `weather` bool (D-07) | vanilla Settings screen | arbiter |
| `overlay(name, on)` → `ok, old` | string, bool | `overlay enable/disable <name>` | arbiter |
| `dismiss_popup(kind)` | whitelisted kind string | close the popup | arbiter |
| `civ_alert(on)` | bool | gui/civ-alert `sound_alarm()`/`clear_alarm()` (civ-alert.lua:27,36) | siege |
| `alert_burrows(names)` | array of burrow names | set the civ-alert burrow list to exactly these (civ-alert.lua:40,45) | siege |
| `squad_create(name, opts)` → `ok, squad_id` | `opts = {assignment_id?, leader?}` (live L2) | squads screen "create squad": `dfhack.military.makeSquad` (Lua API.txt:1973) on a vacant MILITIA_COMMANDER/CAPTAIN assignment, else on a new MILITIA_CAPTAIN assignment (the screen adds one per squad), + nickname; with `leader` the leader is seated at once (`squad_leader`) | military |
| `squad_leader(squad_id, unit_id)` → `ok, assignment_id` | ints (live L2) | squad screen: choose the leader = appoint the citizen to `squad.leader_assignment` (assignment histfig + position link + `assignments_by_type`, as `appoint`), fill position 0, `unit.military.squad_id/squad_position`, equipment update. The officer holds a POSITION link, no SQUAD link (DFHack Military.cpp removeFromSquad). The only way to staff a new squad: `addToSquad` cannot set position 0 and fails while the leader slot is vacant (Lua API.txt:1989-1993). | military |
| `squad_add(squad_id, unit_id)` / `squad_remove(squad_id, unit_id)` | ints | `addToSquad(unit, squad, -1)` (positions ≥ 1 only; call `squad_leader` first) / `removeFromSquad` (:1985-1993) | military |
| `squad_routine(squad_id, routine_name)` | string, resolved by name [S2] | routine dropdown (`cur_routine_idx`) | military |
| `squad_order(squad_id, order)` | `{kind='station', pos}` \| `{kind='kill', units={ids}}` \| `{kind='train'}` \| `{kind='clear'}` | squad orders | military |
| `squad_uniform(squad_id, spec)` → `ok, positions` | `{mode='replace'|'over', items={{cat, type, subtype?, mat='metal'|'leather'|'any', choice?}}, positions?, ammo?}` (live L2) | squads screen > assign uniform: one `squad_uniform_spec` per item and position (material class Armor/Leather/none, indiv choice), flags replace_clothing/exact_matches, squad ammo spec; equipment update | military |
| `squad_unequip(squad_id, positions?, cats?)` → `ok, items` | int, 0-based positions (default all), uniform categories (default all) (live L6) | squads screen > equip > remove: the positions' uniform specs (of `cats`) are deleted and their assigned items released (`equipment.assigned_items`; without `cats` also the quiver/backpack/flask slots, as uniform-unstick.lua remove_item_from_position), equipment update; military calls it before it releases soldiers (targets 0 by the tools rule or a phase before P2) and for an individual-choice weapon spec that could take the civilians' last axe or picks | military |
| `pull(lever_building_id)` → `ok, job_id` | int | `reqscript('lever').leverPullJob(lever, true)` (lever.lua:4, priority) | gate |
| `door_forbid(building_id, on, close?)` → `ok, old` | int, bool, bool (FR-49/52) | door sheet forbid ("locked") toggle: `door_flags.forbidden`; doors only; `old` lets the caller undo only its own change; BUG-015: `close` (with `on`) also sets `door_flags.closed` (reflex's one retry of a door whose flag fell back, nobody in the doorway) | reflex |
| `cancel_own_lever_job(job_id)` | int, only ids returned by `pull` this session | cancel the queued pull | gate |
| `link_lever(lever_id, target_id)` → `ok, job_id|'linked'` | ints (live L2, [S3]) | lever sheet "link up": one `LinkBuildingToTrigger` job on the lever (building holder ref = lever, trigger target ref = target) with two mechanisms attached (roles LinkToTrigger/LinkToTarget), chosen like the screen: free, reachable (walk groups), nearest; refused while a link job is pending or either building is unbuilt | gate |
| `burrow_tiles(name, tiles, create?)` → `ok, n` | burrow name, `[[x,y,z]]` ≤ 2,000 (FR-33) | burrows screen > add burrow (with `create`) / paint: the tiles are added (`dfhack.burrows.setAssignedTile`); n = tiles newly added; seal paints the whole-interior alert burrow `Innen+` | seal |
| `burrow_units(name, unit_ids)` → `ok, n` | burrow name, array of ints (live L3, [S3] fallback) | burrows screen > units: the burrow's unit list becomes exactly these living citizens (`dfhack.burrows.setAssignedUnit`, Lua API.txt:2424; the screen's per-unit toggle, sort/unitselector.lua:122); gate's lever pullers in the `dfllm-levers*` rooms | gate |
| `popcap(n)` | int | `pop-control set max-pop N` | readiness |
| `quickfort(p)` → `ok, stats` | `{mode, data, pos, command='run'|'orders'|'undo', priority?, marker?, dry_run?}` | `reqscript('quickfort').apply_blueprint(p)` (quickfort.txt:156) | runner |
| `orders_import(lib)` | `'library/basic'` … | `orders import <lib>` | economy |
| `orders(sub)` | `'sort'|'recheck'` | `orders sort|recheck` | economy |
| `workorder(spec)` → `ok, order_id` | workorder JSON table; `spec.tag` must start with `dfllm:` | `workorder <json>`; refuses an item-definition job (MakeArmor/Pants/Shoes/Gloves/Helm/Weapon/Ammo/Shield/TrapComponent/Tool/Toy, `orderlib.SUBTYPE_JOBS`) without `item_subtype`: DF 53.16 crashes when a dwarf takes such a job (FR-39) | economy, water, care (FR-61: ConstructCoffin, tag `dfllm:coffin`) |
| `order_suspend(order_id, on)` | int, bool | suspend button | economy |
| `order_remove(order_id)` → `ok, 'removed'` | int | work orders screen: remove the order (FR-10 "Needs" pruner, FR-39 crash guard); jobs it made keep running | economy |
| `job_resume(job_ids)` → `ok, n` | int[] (≤ 200) | building/job sheet "Resume": clears the suspend toggle of these suspended ConstructBuilding jobs only (FR-16) | economy |
| `farm_crop(plot_id, season, plant)` → `ok, plant` | ints, season 0-3, plant raw index or −1 | farm plot sheet: the crop of one season slot (FR-17) | economy |
| `plant_gather(positions)` → `ok, marked` | `[[x,y,z]]` (≤ 200), revealed and reachable (the caller asks snapshot) | gather-plants designation on the shrubs there (`dfhack.designations.markPlant`; trees never) (FR-25) | economy |
| `work_detail_prune(living_ids)` → `ok, n` | int[] (census citizens) | work details screen lists living citizens only: ids of dead or departed units leave every detail; no labor of a living unit changes (FR-40) | economy |
| `kitchen_exclude(item_type, subtype, mat_type, mat_index, what)` | `what='Cook'|'Brew'` | kitchen screen (`dfhack.kitchen.addExclusion`, :2658) | economy |
| `appoint(code, unit_id)` → `ok, assignment_id` | position code (`MANAGER`, `BOOKKEEPER`, `BROKER`), int | nobles screen: choose a citizen for a vacant fort position (assignment histfig + the figure's position link; adult living citizen; position offered, `flags.ACTIVE`) | economy |
| `work_detail(name, unit_id, on)` → `ok, 'added'|'already'|'removed'|'not a member'` | `Miners`, `Woodcutters`, `Hunters` or `Fisherdwarves` (builtin tool details only; Fisherdwarves since live L5), and in a starvation `Planters` and the plant-gathering detail (`Plant gatherers`, `Gatherers` or `Herbalists`, FR-25), int, bool | work details screen: add an adult citizen to the detail (sorted `assigned_units`, the detail's labors switched on) or remove a unit (a unit that left the fort is only taken off the list; a labor is switched off only when no other detail of the unit, or an everybody-does-this detail, grants it; as DFHack's autofish.lua does) (live L1b) | economy |
| `order_material(order_id, 'wood')` → `ok, 'wood'` | int, `'wood'` | work orders screen: cancel an open one-time rock furniture order (door, cabinet, chest, coffin, table, throne, armor stand, weapon rack, hatch cover, grate, floodgate) and enter it again in wood for the amount left; only the material changes (live L3: quickfort `orders` always picks rock; soil embark with 8 boulders and 82 logs) | economy |
| `animal_slaughter(unit_id, on)` → `ok, 'marked'|'already'|'cleared'` | int, bool (live L6) | animal sheet "slaughter" toggle (`flags2.slaughter`; marking clears the gelding and adoption marks, DFHack zone.lua AnimalActionsWidget); tame fort-controlled non-citizens only, never a pet; economy's famine/food_low slaughter of surplus animals | economy |
| `zone_remove(name)` → `ok, n` | `dfllm-*` zone name (live L6) | zones screen > remove: every activity zone of that name is deconstructed (`dfhack.buildings.deconstruct`, as quickfort's zone undo does, but only these zones); the runner's temporary gather zone | runner |
| `item_flag(item_id, flag, on)` | `flag='forbid'|'dump'|'melt'` | item flag toggles | care, water; economy (FR-23/25/50: forbidden drink/food/seed containers, seeds, food in a starvation), military (FR-46: invaders' metal gear); only on revealed, reachable tiles in PEACE/RECOVERY |
| `zone_assign(zone_building_id, unit_id)` | ints | assign a caged unit to a pit/pond zone | care |
| `tomb_zone(op, zone_id, unit_id?)` → `ok, 'removed'|'freed'|'opened'|'assigned'|'already'` | `op='remove'|'free'|'open'|'assign'`, ints (FR-27/41/42) | tomb zone sheet: remove the zone (owner link dropped first, then `dfhack.buildings.deconstruct`), unassign it (and allow citizens), allow citizens, or assign it to a dead citizen (`dfhack.buildings.setOwner`, as entomb.lua does); tomb zones only | care |
| `medic(unit_id, on)` → `ok, 'enabled'|'disabled'|'already'` | int, bool (FR-48) | labors screen: DIAGNOSE, SURGERY and BONE_SETTING of one adult living citizen on or off | care |
| `hospital_post(occupation_id, unit_id)` → `ok, 'filled'|'already'` | ints (FR-48) | location sheet > occupations: a hospital post (doctor, diagnostician, surgeon, bone doctor) that is vacant or held by a dead unit gets a living adult citizen (a dead holder is unlinked first); a living holder is never replaced | care |
| `trade(op, args)` | `op='request_broker'|'broker_job'|'open'|'mark'|'offer'|'close'` [WP9 audit; `broker_job` live L4] | depot and trade screen; `broker_job {depot, assign?}` posts the TradeAtDepot job the broker request stands for (DF 53 never posted it from the toggle: 'time' failures L1-L3), one per depot; `assign` gives a job nobody took to the broker only while he has no job | trade |
| `run(cmd, ...)` → `ok, output` | command + string args | `dfhack.run_command_silent` after the allowlist check (§9.14); `'r'` entries are read-only queries | see `contract.ACT.run` |

Not in act on purpose: labor writes other than the builtin tool details and the doctor labors (labormanager owns every other labor and detail; live L1b gave economy the Miners/Woodcutters/Hunters memberships, see DESIGN §3; FR-48 gave care DIAGNOSE/SURGERY/BONE_SETTING through `medic`), unit/skill/position writes, job removal (except our own lever job), item creation, tile edits.

---

## 6. Census (`K.census`)
All counts are integers; lists are bounded. Readers must handle a missing subtable (before the first scan) as "unknown", not zero.

### 6.1 `K.census.u` (sense; citizens; refreshed every 100 ticks and on mode change)
| Field | Meaning |
|---|---|
| `tick` | abs tick of the scan |
| `cit` | `#dfhack.units.getCitizens()` (Lua API.txt:1696) |
| `adults`, `children` | citizens with `isAdult` / the rest |
| `soldiers` | citizens with `military.squad_id >= 0` |
| `ids`, `soldier_ids` | sorted arrays of citizen / soldier unit ids |
| `outside` | non-soldier citizens not on a `Kern+` tile (`dfhack.burrows.isAssignedTile`, :2436); −1 when `Kern+` does not exist |
| `outside_ids` | up to 20 of them |
| `on_bridge` | `{<bridge>=n}` citizens on each manifest bridge footprint |
| `stressed` | citizens with `getStressCategory(u) <= 1` |
| `caged` | ids of caged hostile units (visible cages only) |

### 6.2 `K.census.h` (sense; hostiles; every 50 ticks in PEACE, 25 in other modes, 10 while `armed`)
| Field | Meaning |
|---|---|
| `tick` | abs tick of the scan |
| `vis` | visible hostiles: active, `isVisible ∧ ¬isHidden ∧ ¬caged`, and `isInvader` or `isDanger`, **excluding fort members of any sanity**: not `dfhack.units.isCitizen(u, true)`, not `isResident(u, true)`, not `isTame(u)`. Plain `isCitizen(u)` drops insane citizens (Lua API.txt:1464) while `isDanger` includes crazed units (:1668), so a berserk dwarf would otherwise count as an enemy, and inside Kern+ push the FSM to ALERT and BREACH |
| `crazed` | visible fort members (`isCitizen(u, true) ∨ isResident(u, true)`) that are not sane (`¬isSane` or `isCrazed`, :1500-1504); for military/care only, never part of `vis`, `inv`, `inside`, `near_*` or `list` |
| `inv`, `great`, `undead` | visible invaders; visible `isGreatDanger ∨ isMegabeast ∨ isForgottenBeast ∨ isTitan`; visible `isUndead` |
| `inside` | visible hostiles on a `Kern+` tile |
| `near_o1`, `near_cit` | min distance hostile → O1 footprint center / → a citizen outside Kern+; −1 if none |
| `near_bridge` | `{<bridge>=dist}` min hostile distance per manifest bridge (−1 none) |
| `list` | ≤ 40 nearest: `{id, x, y, z, k='inv'|'great'|'undead'|'danger', d_o1}` |
| `armed` | 1 while an INVASION (or a threat report) armed the fast scan (2,400 ticks), else 0 |

### 6.3 `K.census.i` (economy; items; every 1,200 ticks, sliced over `items.other` vectors)
`tick, drink, food, meals, meal_kinds, cloth, leather, bone, shell, gems, bars, bolts, wood` (units, i.e. stack sizes summed, excluding forbidden items and items in caravans). Weapons and gear (`w_pick`, `w_axe`, `w_xbow`, `w_bow`, `g_*`) also exclude foreign items (`flags.foreign`, merchant leftovers; live L6). Drink, food and seeds in a forbidden container of any item type count as forbidden (`drink_forb`, `food_forb`, `seeds_forb`; FR-50, FR-23); `seeds_ok` = usable seeds; `w_pick_free`, `w_axe_free` = tools nobody carries (FR-40); `farm_plots`, `farm_empty` = built plots and empty season slots (FR-17).

### 6.4 `K.census.a` (sense; the fort's tame animals; with the unit count, every 1,000 ticks; live L6)
`{tick, n, list = [{id, race, female, adult, pet, slaughter, war}]}` (≤ 120): visible, tame, fort-controlled, living non-citizens (`isTame ∧ isFortControlled ∧ ¬isCitizen(u, true)`); `war` = war or hunting animal. economy marks surplus ones for slaughter (`act.animal_slaughter`) while the famine or the food_low pre-alarm runs: per race one adult female and one adult male stay; pets, war animals and marked ones are left alone; only with a butcher's shop, weekly, ≤ 10.

---

## 7. Cross-module public APIs (`K.call(module, fn, ...)`)
Only these are public across WPs; anything else is module-internal. "Returns" are the callee's return values; through `K.call` they follow a leading `true` (`local ok, r1, r2 = K.call('gate', 'want', 'O1', 'up', 'siege')`), or `K.call` returns `false, err`.

| Call | Returns | Notes |
|---|---|---|
| `gate.want(bridge, 'up'|'down', why)` | `ok, msg` | A request merged into the gate's desired state. `up` requests are always honoured; `down` requests are refused in SIEGE/BREACH/DRILL and while a hostile is visible within 30 tiles of that bridge. The single-pending-pull invariant (DESIGN §4) is the gate's job. |
| `gate.state(bridge)` | `'up'|'down'|'moving'|'unknown', pending_job_id|nil` | from `gate_flags.closed/closing/opening` |
| `gate.kpi()` | `{double_toggles=, last_raise_ticks={B1=...}}` | counters since `gate.reset_kpi()` |
| `gate.reset_kpi()` | | called by drill at drill start |
| `military.posture(P)` | `ok` | P ∈ `contract.POSTURES`. Idempotent. Mode → posture: PEACE TRAIN, ALERT STATION_B1, SIEGE/DRILL READY_STATION, BREACH B2_HOLD, RECOVERY STATION_B1. siege calls it. |
| `military.kpi()` | `{squads, soldiers, worn, cv, metal_pct, on_station}` | worn = items worn ÷ uniform slots (%) |
| `military.kill(unit_ids)` | `ok, n` | only targets inside `manifest.killboxes`, never on stair/shaft tiles |
| `readiness.level()` | `0..3` | |
| `readiness.cap()` | `int` | the allowed max-pop now |
| `drill.start(why)` | `ok, msg` | PEACE only, no merchants on map |
| `snapshot.export(opts)` | `ok, id` | `opts = {id?, bbox?, purpose='audit'|'sites'|'debug'}`; sliced; emits `SNAPSHOT_READY` |
| `snapshot.tile(x, y, z)` | `nil` (hidden/invalid) or `{c=<legend char>, dig=<designation or ''>, bld=<building type or ''>}` | the only tile read for other modules; `dig='job'` when a designation job (Dig, channel, …) sits on the tile, because DF clears `designation.dig` while a miner works it (live L1) |
| `economy.imported(lib)` | `bool` | orders library already imported |
| `economy.alarm()` | `why` or `nil` | supply alarm (thirst/hunger of >= 2 citizens, drink or food < 10 days); arbiter brakes tempo while set (live L1) |
| `runner.dig_backlog()` | `int` | tiles still to dig in the dig stage of every running project (tile count minus the last measured progress); economy sizes the Miners detail from it (live L1b) |
| `runner.pending(tpl)` | `int` | projects of `tpl` not done yet (care waits for them before asking again) |
| `runner.bboxes()` | `[bbox]` | bboxes of the projects not done yet; readiness widens the audit snapshot with them (live L2: a dig in progress ran past the box edge and read as a bypass) |
| `trade.done()` | `int` | caravans traded this fort |
| `runner.depot_keep(why)` | `ok, proj id | 'standing' | reason` | FR-43: in PEACE/RECOVERY, no TRADE_DEPOT building at all -> a one-stage `depot` project (5x5 `D(5x5)`, prio 2) at manifest.depot, else at the last depot the runner saw; one at a time. The runner calls it every run in PEACE/RECOVERY, trade when a caravan finds no depot |
| `gate.rooms(mode, main?)` | `[burrow name]` | the lever-puller rooms (`dfllm-levers*` manifest burrows) siege adds to the alert list in that mode; in BREACH only a room whose bridge has no linked lever inside the refuge (iter2). BUG-013: then `seal.lever_burrow`'s name while a pull is pending on a bridge none of whose linked levers lies on `main` (the alert's burrow) or those rooms (not in BREACH): a confined civilian takes only jobs inside the alert's burrows but walks outside them to get there |
| `gate.pulls()` | `{want, up, left, out, foot, nolever, lat_t, lb?}` | BUG-013, from the last pass: bridges wanted up, already up, still to pull (`left`), of those blocked by the sounding alert (`out`: no linked lever inside its burrows), waiting for a citizen on the footprint, without a linked lever; `lat_t` the last lever latency in ticks (−1 never); `lb` the lever burrow while the alert lists it. The reflex's deferred alert and its text read it |
| `seal.lever_burrow(tiles)` | name or `nil, why` | BUG-013: the lever burrow `seal.CFG.levers` (`Hebel+`; burrows screen add + paint, `act.burrow_tiles`) holds `[[x,y,z]]` (gate's linked lever tiles, ≤ 64); a missing tile is painted at once, tiles are never removed |
| `siege.alert_names()` | `[burrow name]` | BUG-013: the burrows the sounding civ alert holds the civilians in (siege's last list), `[]` while it is silent |
| `gate.pullers(bridge)` | `[unit id]` | citizens assigned to that bridge's lever room (iter2) |
| `snapshot.reach(a, b)` | `bool` | walk groups (`dfhack.maps.canWalkBetween`) between two known positions `{x,y,z}`; bad args or a fault answer `true` (iter2; care's mood reach) |
| `snapshot.outside_near(pts, r)` | `[1|0|-1]` | per position `{x,y,z}`: 1 when a revealed tile within `r` (0-3, Chebyshev xy, same z) is open sky (`designation.outside`), 0 none, −1 bad position; hidden tiles never count (FR-49/52: entrance doors, roofed tiles) |
| `snapshot.units_at(x0, y0, x1, y1, z)` | `[{id, x, y}]` or `nil, err` | visible living units on the revealed tiles of a level rect (≤ 400 tiles), sorted by id; hidden units and tiles never (BUG-015: what stands on and next to a lockdown door) |
| `reflex.holding(what?)` | `why` or `nil` | why a lockdown holds `what` (`clock`, `gates`, `doors`, `alert`; nil = any). The arbiter, gate and siege ask it on every pass (level-triggered) |
| `reflex.announce(kind, text, src)` | `ok, summary` | arbiter hands over a threat popup (`siege`, `ambush`, `snatcher`, `beast`) or `no_depot`; the reflexes are issued before it returns (FR-36) |
| `arbiter.hold()` | `cap, why` | apply the clock now (the reflex changed its lockdown); the FPS cap driven and why it is lowered (`''` free) |
| `gate.lockdown()` | `{want, up, pend, names}` + `gate.pulls()` fields | run the gate pass now with a fresh lever scan; bridges wanted up, already up, our pulls queued (`pend`) |
| `gate.sealed()` | `bool` | every gate bridge (manifest outer/inner, else the unmanaged ones in hand) is up; siege's `sealed_ticks` without fortcore |
| `gate.points()` | `[{x,y,z}]` | entrance points for the arrival ETA: manifest outer bridge centres, else the unmanaged bridges |
| `siege.hold_alert()` | `text, short`: `'<burrow>'|'<burrow> (<note>)'|'<burrow> kept (<note>)'|'pending <burrow>'|'none (<note>)'|'off'` | apply the civ alert now (the reflex changed its lockdown), with the same decision as siege's step (BUG-011: one owner; nothing switches the alert off while a lockdown holds it). The answer is what holds (the burrow sounded, `none` = wanted but not sounded), `note` seal's REFUGE_FAIL reason; `short` is the same with seal's short note (event texts) |
| `economy.need(key, n, who, days?)` | `ok, route` | a short-term need of a supply key (wood, rock, bone, shell, leather, cloth, thread, bars, gems, fuel, hides): target and floor >= n for `days`; `ok=false` = no production route; n = 0 clears (iter2) |
| `economy.reserve(key, n, who)` | `ok, floor` | a standing floor economy's own consumers never go below; floor = max of config, holders and needs; n = 0 drops the holder (iter2; care pushes the mood reserve) |
| `economy.supply()` | `{key = {have, held, want, floor, route}}` | read-only (iter2) |
| `care.reserved()` | `{class = n}` | items care holds forbidden as the mood-material reserve (iter2) |
| `care.mood_wants()` | `[{cls, n, unit, label, acq, buy}]` | what open strange moods still miss, read from the mood job's `job_items` (orchestrator decision iter2); economy turns it into needs; `buy` is the trade token, for cloth and thread with the kind the filter names (`cloth:plant`, `cloth:silk`, `cloth:yarn`, `thread:*`; plain `cloth` when any kind fits; BUG-017) |
| `snapshot.liquids(x0, y0, x1, y1, z, min?)` | `[{x, y, flow}]` or `nil, err` | revealed non-magma water tiles of one level rect with depth ≥ `min` (default 1); ≤ 4,096 tiles read, ≤ 512 returned per call; hidden tiles never (FR-47, water's scan) |
| `care.inspect(what, key?)` / `water.inspect(what, key?)` | `ok, msg, data` | kern's `inspect` routes `what=tombs` to care and `what=water_sources` to water (FR-27, FR-47); data ≤ 8 KB |
| `seal.alert_burrow(mode, default, hold?)` | burrow name or `nil`, `note`, `short` | FR-33/37/57: the civ-alert burrow siege confines to while the alert is wanted. `default` = siege's choice (Kern+, the refuge in BREACH). After a BREACH the refuge is held until `seal.CFG.back_days` days without a visible hostile. A burrow without drink, food and beds for the population (or too small) is refused: Kern+, then the interior burrow `Innen+`, else `nil` = no confinement (siege turns the alert off); a refusal emits REFUGE_FAIL. `hold` (BUG-011: a reflex lockdown holds the alert): when every burrow fails, `Innen+` is kept if it is big enough (it holds every stock, bed and well inside; the lockdown keeps citizens off the surface), and a missing or too small one is painted at once (urgent, at most daily). `note`/`short`: why the answer is not `default` (`'REFUGE_FAIL <burrow>: <why>[; ...]'` / `'REFUGE_FAIL <burrow>[, lockdown fallback]'`), `nil` when it is. Without seal (missing/backed off) siege keeps its own choice |
| `seal.entrances()` | `[[x,y,z]], r` or `nil` | FR-33: entrance tiles (openings of the last entrance check, O1 centre, manifest edge); sense counts a wild large predator outside the fort only within `r` tiles of one |
| `seal.door_outside(ids)` | `{[id] = n}, n` | BUG-012 safety: per door, the citizens (soldiers excluded) on its outside side: on a revealed open-sky tile of the door's walk group, on the porch of an opening it closes (the inside tiles between the opening and its doors, last entrance check), or in the doorway; and the distinct count. The reflex forbids a door only once its count is 0 (or a hostile is near, or the deadline passed) |
| `seal.entrance_doors(refresh?)` | `{tick, sealed, routes, doors:[{id, pos}], open:[{pos, kind}]}` or `nil` | BUG-012: the doors of the last entrance check's openings (a door on an opening, the first door on its BFS route toward the citizens within `door_route` tiles, every door within `door_near` steps inside it; revealed tiles only) and the openings with neither a door nor a bridge; `tick` = its BFS. `refresh` queues an urgent check with a fresh BFS (reflex, at a lockdown's start); the reflex forbids the doors and names the open ones |
| `seal.closing(proj, tpl, class, chunk)` | `n` | FR-22: runner calls it before a build chunk goes to quickfort; seal remembers its closing cells (walls, fortifications, doors, hatches, bridges, floodgates, grates, bars, statues) for blame and the perimeter and takes a reach baseline |
| `runner.repair(cells, why)` | `ok, proj` | FR-56: a `repair` project (class defense, one build stage, no orders) that builds `[[x,y,z,text]]` quickfort cells again; seal re-queues lost perimeter pieces with it |
| `runner.coffins(tiles, why, prio?)` | `ok, proj` | FR-61: a `tombs` project (class living, site `care`, prio default 3) for `[[x,y,z]]` coffin tiles (1-60) that care's coffin provisioner chose in dug space that stands: stage `tombs.build` places a coffin (`n`) on each, without quickfort orders (care orders ConstructCoffin in a material the fort can use, buildingplan waits for the coffins), stage `tombs.zone` a 1x1 tomb zone (`T(1x1)`) over each. Called without tiles it refuses (`need 1-60 tiles`): care's feature probe |

Mode-driven duties (no call needed): arbiter applies tempo and the FPS cap per mode in `on.MODE`; siege applies civ alert, alert burrows and posture; gate recomputes desired bridges; runner freezes; readiness freezes growth outside PEACE.

---

## 8. Runtime folder
`<DF>` = `dfhack.getDFPath()`. Root `<DF>/dfllm-runtime/`:

| Path | Writer | Notes |
|---|---|---|
| `ACTIVE` | kern | one line: save folder name (`dfhack.getSavePath()` basename). Written at boot, deleted at unload. |
| `restore.json` | arbiter | global (settings leak across saves); §9.13 |
| `live.lock` | Python only | §9.15 |
| `<save>/state.a.json`, `state.b.json` | kern | §9.3; slot = `a` when `seq` is odd, `b` when even; written in place (`io.open(...,'w')`) |
| `<save>/heartbeat` | kern | §9.2, every 5 s real time, also while paused |
| `<save>/events.jsonl` (+ `events.1.jsonl`) | kern | §9.4; rotated at 5 MB: remove `.1`, rename current to `.1`, start new |
| `<save>/inbox/<ts>-<id>.json` | Python | §9.5; kern lists every 0.5 s, handles ≤ 4 per frame in name order, deletes each after reading. Names starting with `.` or not ending in `.json` are ignored. |
| `<save>/outbox/<id>.json` | kern | §9.6; Python deletes after reading |
| `<save>/plan.json` | Python (`plan apply`) | §9.7; kern reads on `plan.reload` |
| `<save>/bp/<id>.json` | Python | §9.8 blueprint project files; the runner reads one on `bp.place`, and plan builds when their season is due, **at most one bp file per frame**, and copies it into persist once |
| `<save>/snap/<id>.json` | kern (snapshot) | §9.10; Python prunes old ones |
| `<save>/alarm.txt` | reflex | FR-53 interrupt channel, rewritten in place in the step an interrupt is emitted and on every ack or DEFCON change: line 1 `DEFCON <n> | mode <MODE> | unacked <k>[ (oldest <s> s)] | last <n> | ack <n> | lockdown <why (acts)|off>[ | eta ~<t> t]`, then one line per recent interrupt (≤ 20, oldest first) `n \t wall \t tick \t TYPE \t acked|unacked|default \t msg`; read by `dfllm wait`, `dfllm ack` and Monitors |
| `<save>/manifest.json` | kern | §11 fort manifest, rewritten in place at boot and whenever persist `manifest` is flushed (live L1); Python reads it instead of `inspect manifest` (no 8 KB limit) |
| `<save>/perf.csv` | kern (perf) | §9.11 |
| `<save>/commands.log`, `kern.log` | kern | §9.12; rotated at 1 MB to `.1` |
| `<save>/.follow.hb` | Python (`dfllm follow`) | `{v:2, wall, last_n}` rewritten every 10 s; `status` prints `follow: OFF (last heartbeat …)` and `doctor` warns when it is older than 60 s (FR-29) |

**Write rules.** Lua never renames onto an existing file (Windows `os.rename` fails with "File exists"). New files (outbox, snap) are written to `<name>.tmp` and renamed to a name that does not exist; if it exists, use `<id>-<n>.json`. Python writes inbox/plan/bp files to `.<name>.tmp` in the same folder and `os.replace`s them. Readers retry a failed parse once after 50 ms.

---

## 9. File formats
Field notation: `int`, `str`, `bool`, `flag` (int 0/1), `pos` (`[x,y,z]`), `bbox` (§1.3), `?` = optional. Objects are **closed** (unknown keys are errors) unless marked *open*. The machine-readable JSON Schemas are in Appendix A; `dfpilot.schema.validate(kind, doc)` is the reference validator.

### 9.1 `ACTIVE`
Text, one line, the save folder name, UTF-8, no trailing spaces.

### 9.2 `heartbeat` (kind `heartbeat`)
One JSON line, rewritten in place: `{v:2, wall:int, frame:int, tick:int, paused:bool, mode:str, seq:int}`. Liveness = file mtime < 120 s old; a torn line is ignored (use mtime).
<!-- ex:heartbeat -->
```json
{"v":2,"wall":1791676800,"frame":918273,"tick":1333056,"paused":false,"mode":"PEACE","seq":812}
```

### 9.3 `state.a.json` / `state.b.json` (kind `state`)
≤ 4 KB. Written every ≥ 2 s (real time) and on every mode change. **Always present:** `v, seq, t, mode, k, ev`.

**Validation on both ends.** Before writing, kern runs `contract.prune_state(doc)`: an optional top-level key with any error is dropped and logged (`kern.log` error naming the key, the module and the first error), so one module's slip cannot blind status, brief and plan check; errors in kern's own required keys are logged and the document is written anyway. k_mock in strict mode raises on any error instead. **Readers** parse both slots and use `schema.prune_state(doc)`: a slot is discarded only when it does not parse or a *required* key is invalid; invalid optional keys are dropped (and reported as diagnostics); the higher `seq` of the remaining slots wins. Every other top-level key appears once its owner has published (a disabled or not yet loaded module leaves it out); `pop` and `stock` have two owners, so their sub-keys are individually optional. Other objects are complete when present.

| Key | Type | Owner | Meaning |
|---|---|---|---|
| `v` | 2 | kern | |
| `seq` | int ≥ 0 | kern | increments per write; persisted across boots |
| `t` | `{y:int, tick:int (ytick), season:0-3, tps:int, paused:bool, abs?:int, wall?:int, frame?:int}` | kern | `tps` = calendar ticks per real second, 10 s window |
| `mode` | mode | kern | |
| `phase` | `P0`..`P7` | runner | |
| `save?` | str | kern | save folder |
| `pop` | `{cit, adults, soldiers}` (sense) + `{cap, gate_cap}` (readiness), all int | | `cap` = pop-control max-pop now; `gate_cap` = readiness ceiling |
| `ready` | `{lvl:0-3, worn:0-100, cv:int, drill_age:int, audit:{ok:flag, age:int, min_traps:int}, fail:[str ≤24]≤8}` | readiness | `drill_age` = ticks since the last *passed* drill, −1 never; `audit.age` −1 never |
| `stock` | `{drink_d, food_d, meals}` (economy) + `{hosp_water:flag}` (care) | | days of stock; `meals` = distinct meal kinds |
| `care` | `{stressed_pct, naked, ghosts, corpses_old, tombs_free, moods, coffins?, died?}` | care | ints; `coffins` (FR-61, while the coffin provisioner is active) = `{want, short, stock, order, proj:str ≤40}`: free usable tombs wanted (unburied citizen bodies without a usable tomb + `care.coffin_reserve`), coffin slots still missing (want minus free, planned and unzoned built coffins), free coffin items, coffins in open orders that can run, the provisioner's pending project (`''` none); `died` (FR-64, when any) = `{<cause>: n}` citizen deaths of the last season (100,800 ticks) by cause (§12 DEATH; a death not found yet counts as `unknown`) |
| `labor` | `{starving, idle}` | economy | starving postings; idle % |
| `orders?` | `{n, bad, stuck}` ints | economy | open manager orders; `bad` = make-item orders without item_subtype still listed (FR-39, doctor flags them); `stuck` = orders that cannot run for `orders.stuck_days` (FR-01) |
| `threat` | `{vis, armed:flag}` | threat | |
| `proj` | `[[id:str, stage:str, pct:0-100, blocked:str]]` ≤ 8 | runner | `blocked` = `""` or a reason code |
| `bridges` | `{<bridge>: 'up'|'down'|'moving'|'unknown'}` | gate | |
| `k` | `{ms_s, gap_max_ms, slow:[module], faults, disabled?:[module], ms_max?}` | kern | kernel ms per real second (10 s window), max frame gap (ms), demoted modules, fault count |
| `owners` | `{pause: null|'inbox'|'gordon'|'popup'|'df', tempo: 'mode'|'inbox'|'brake'|'clock'}` | arbiter | who holds pause/tempo; `brake` = the supply brake (P0 or `economy.alarm()`); `clock` = the reflex clamp (FR-51) |
| `ev` | int | kern | last event number written |
| `mil?` | `{squads, soldiers, worn, cv, metal_pct, on_station, free?}` | military | `free` = `{weapon?, body?, head?, pants?, gloves?, shoes?, shield?, ammo?}` free metal gear per category (ammo in units, loot included; categories without any are left out) (FR-46) |
| `trade?` | `{caravan:flag, ratio:int, done:int}` | trade | ratio ×100 (150 = 1.5) |
| `clock?` | `{cap:int, orig:int, ts:int −1..1000, held:flag, why:str ≤24}` | arbiter | FR-51: vanilla FPS cap driven now and the captured original; desired timestream fps (−1 off); `held` = the reflex clamp; `why` = what lowers the cap (`siege`, `alert`, `brake`, `inbox`, the clamp's why; `''` free) |
| `alarm?` | `{defcon:1-5, unacked:int, last:int, ack:int, lock:flag, why:str ≤24, eta?:int, doors?:int, dwait?:int, dout?:int, dref?:int}` | reflex | FR-53: DEFCON 1 (BREACH, hostile inside, unacked INTRUDER) .. 5 (PEACE, nothing open); unacked interrupts; newest interrupt n; acked n; lockdown held and why; FR-58 ticks to first contact (−1 unknown); BUG-012, a lockdown with the doors action: doors it forbade, doors waiting and the citizens outside they wait for; BUG-015: doors refused (their forbidden flag fell back before the next pass) |
| `lever?` | `{lat_s:int, lat_t:int, pend:int, wait_s:int}` | gate | FR-55: last lever latency (our queued pull → bridge in the wanted state) in real s and ticks (−1 never); own pulls pending and the oldest one's wait (s) |
| `alert?` | `{want:str, burrow:str, tiles:int, inside:int, ok:flag, why?:str}` | seal | FR-33/37: the civ-alert burrow for the current mode (ALERT's in PEACE): `want` = Kern+ or the refuge, `burrow` = the audited choice (`""` = no confinement; during a reflex lockdown `Innen+` when it is kept although it fails, BUG-011), its size and the citizens inside it, `ok` = want passed its audit, `why` = the refusal |

Module `state(K)` returns partial docs; kern deep-merges them (two levels) into the document. Leaf owners are `contract.STATE_OWNERS`; a module returning a key it does not own is a contract bug (k_mock raises). A published object is complete (all its required keys); write `json.null` for null (a nil field is simply absent, e.g. `owners.pause`) and `json.object{}` for an empty object (`bridges` with no bridge), because a plain empty table encodes as `[]`.

DESIGN §6 example (valid as-is):
<!-- ex:state -->
```json
{"v":2,"seq":812,"t":{"y":3,"tick":123456,"season":1,"tps":462,"paused":false},"mode":"PEACE","phase":"P3",
 "pop":{"cit":52,"adults":44,"cap":55,"gate_cap":55,"soldiers":8},"ready":{"lvl":1,"worn":94,"cv":13,"drill_age":40000,
 "audit":{"ok":1,"age":9000,"min_traps":22},"fail":["traps<30"]},"stock":{"drink_d":182,"food_d":75,"meals":6,"hosp_water":1},
 "care":{"stressed_pct":4,"naked":0,"ghosts":0,"corpses_old":0,"tombs_free":9,"moods":0},"labor":{"starving":0,"idle":31},
 "threat":{"vis":0,"armed":0},"proj":[["fortcore","s2.build",64,""]],"bridges":{"O1":"down","B1":"down","B2":"down"},
 "k":{"ms_s":11,"gap_max_ms":420,"slow":[],"faults":0},"owners":{"pause":null,"tempo":"mode"},"ev":8812}
```

### 9.4 `events.jsonl` (kind `event`)
Append-only, one object per line, `\n`-terminated; Python only consumes complete lines. `{n:int, tick:int (abs), type:str, cls:'A'|'B'|'C', msg:str ≤200, d:object}`. `n` is strictly increasing; at boot kern continues from `max(last n in events.jsonl, persist kern.ev) + 1`, so loading an older save never repeats a number. `type`/`cls` must match the registry (§12); `d` is *open* but known keys are typed per type.
<!-- ex:event -->
```json
{"n":8812,"tick":1234500,"type":"SIEGE_END","cls":"A","msg":"149 hostiles, 31 killed, 0 lost, sealed 6.1 d","d":{}}
```

### 9.5 `inbox/<ts>-<id>.json` (kind `inbox`)
File name: `ts` = 13-digit zero-padded epoch ms, `id` = the command id; the JSON `id` must equal the file-name id. `{id:str, verb:str, args:object, by:'llm'|'gordon'|'cli'|'follow'|'supervise'|'test', ts?:int (epoch ms)}`. `args` is validated per verb (§13).

**`by` is an origin label, not authentication** (anyone who can write a file can write any `by`). It is logged in `commands.log` and never grants a right by itself:
- Gordon's channel is the game itself: he releases his own pause in the DF UI. No inbox verb releases a pause owned by `gordon`, `df` or `popup`, whatever `by` says (§13 `unpause`).
- `contract.VERB_BY` / `schema.VERB_BY` restrict a few verbs to origins: `audit` only from `follow` or `test`. kern and `schema.validate('inbox')` reject other origins. This is the second line; the first is the hook.
- The hook and lint (WP4, §13 trust rules) keep the LLM from claiming another origin and from writing runtime or config files directly.
<!-- ex:inbox -->
```json
{"id":"c123","verb":"bp.place","args":{"tpl":"bedrooms","site":"S2","n":20},"by":"llm"}
```

### 9.6 `outbox/<id>.json` (kind `outbox`)
`{id:str, ok:bool, msg:str ≤300, verb?:str, tick?:int, data?:object (open)}`. Exactly one reply per inbox file (also for unparsable files: `id` from the file name, `ok:false, msg:'bad json'`).
<!-- ex:outbox -->
```json
{"id":"c123","ok":true,"msg":"queued P7"}
```

### 9.7 `plan.json` (kind `plan`)
Written only by `dfllm plan apply` after `plan check`; loaded by kern on `plan.reload`, stored in persist `plan`, exposed as `K.plan`.

| Key | Type | Default |
|---|---|---|
| `v` | 2 | |
| `year` | int ≥ 0 | |
| `policy` | `{option:'A'|'B', pop_ceiling:int 0-250, beauty:'none'|'used_rooms'}` | |
| `phase_target` | `P0`..`P7` | |
| `seasons` | exactly 4 × `{build:[build], orders?:{import:[lib]}, notes?:str}` | |
| `military?` | `{pct:0-50, squads:{melee:0-4, xbow:0-2}, cv_min:0-200}` | `{15, {2,1}, 12}` |
| `supply?` | `{drink_d, food_d, mood_stock}` ints | `{170, 60, 10}` |
| `orders?` | `{import:[lib]}` | `{import:[]}` |
| `trade?` | `{want:[token], sell:[token]}` | `{[],[]}` |
| `notes?` | str ≤ 2,000 | `""` |

`build = {tpl:str, site:str, p?:object (scalars), prio?:1-7}`. `lib` ∈ `library/basic, library/furnace, library/smelting, library/military, library/rockstock, library/glassstock`. Trade token `^[a-z_]+(:[a-z_]+)?$` (`bar:iron`, `anvil`). `plan check` (WP2) adds semantic rules: `pop_ceiling ≤` the cap of the current readiness level, option B needs D-01 = B. Build entry `i` of season `s` refers to the blueprint file `bp/y<year>s<s>b<i>.json`, which `plan apply` writes first; its project id is `y<year>s<s>b<i>`.
<!-- ex:plan -->
```json
{"v":2,"year":3,"policy":{"option":"A","pop_ceiling":75,"beauty":"used_rooms"},"phase_target":"P6",
 "seasons":[{"build":[{"tpl":"bedrooms","site":"S2","p":{"n":20,"tier":500}}]},{"build":[]},{"build":[]},{"build":[]}],
 "military":{"pct":15,"squads":{"melee":2,"xbow":1},"cv_min":12},"supply":{"drink_d":170,"food_d":60,"mood_stock":10},
 "orders":{"import":["library/smelting"]},"trade":{"want":["bar:iron","anvil","cloth"],"sell":["crafts"]},"notes":""}
```

### 9.8 `bp/<id>.json` blueprint project (kind `bp`)
Written by Python from `bp.emit` (WP3) **before** the inbox `bp.place` (file id = command id) or by `plan apply` (id `y<Y>s<S>b<I>`). The runner (WP7) copies it into persist `bp.<id>` and applies it chunk by chunk.

| Key | Type | Meaning |
|---|---|---|
| `v`, `id`, `tpl`, `site` | 2, id, tpl, str | `site` is the label from `bp sites` (S1-S3) |
| `class` | `'defense'|'infra'|'living'|'beauty'` | mode gating: ALERT allows defense+infra, SIEGE defense only (repairs inside), beauty only PEACE with R1 |
| `params` | object (scalars) | template params |
| `anchor`, `rot` | pos, 0-3 | where and how it was placed |
| `stages` | 1-64 × stage | applied in order |
| `manifest` | manifest fragment (§11) | merged into the fort manifest when the project is done (100 %); split defense geometry into separate projects if the gate needs it earlier |
| `materials` | `{<material>: int}` | for `bp preview`, not used in game |

**Size caps** (main-thread budget; `schema.validate('bp')` enforces them, so `bp` emit, `plan check`, `plan apply` and `cmd bp.place` refuse bigger documents): **≤ 1,000 cells in total** (`schema.BP_MAX_CELLS`) and **≤ 24 KB of compact JSON** (`json.dumps(separators=(',',':'), ensure_ascii=False)` in UTF-8, `schema.BP_MAX_BYTES` = 24,576). The kernel decodes a whole bp in one call: on lua53.dll that costs about 14 ms per 1,000 cells (13 KB) and 0.75-3 s for 40,000 cells. A bigger template is emitted as several projects (fortcore already emits one per stage); quickfort area syntax (`d(10x5)`) keeps the cell count low (the largest golden template has 161 cells, 6.8 KB).

`stage = {label:str ≤24, mode:'dig'|'build'|'place'|'zone'|'burrow', orders:flag, defense:flag, chunks:[chunk] 1-500}`; `orders:1` → runner calls `act.quickfort{command='orders'}` for the whole stage before `run`, sliced into calls of ≤ `runner.CFG.orders_cells` (8) cells grouped by building key, one call per slice (live L1b: one 19-cell call cost 60 ms); `defense:1` → readiness re-audits after the stage. `chunk = {pos, cells:[[dx,dy,dz,text]] 1-40}`; the runner builds `data[dz][dy][dx] = text` (integer keys) and calls `act.quickfort{mode, data, pos}`. `text` ≤ 64 chars of quickfort cell syntax (e.g. `d`, `Cw`, `trackstop`, `bedroom/location=…`).
<!-- ex:bp -->
```json
{"v":2,"id":"c123","tpl":"bedrooms","site":"S2","class":"living","params":{"n":20,"tier":500},
 "anchor":[60,40,120],"rot":0,
 "stages":[{"label":"s1.dig","mode":"dig","orders":0,"defense":0,"chunks":[{"pos":[60,40,120],"cells":[[0,0,0,"d"],[1,0,0,"d"]]}]},
           {"label":"s1.build","mode":"build","orders":1,"defense":0,"chunks":[{"pos":[60,40,120],"cells":[[0,0,0,"b"],[1,0,0,"h"]]}]},
           {"label":"s1.zone","mode":"zone","orders":0,"defense":0,"chunks":[{"pos":[60,40,120],"cells":[[0,0,0,"b(2x1)"]]}]}],
 "manifest":{"v":2,"rooms":[{"id":"c123","tpl":"bedrooms","use":"used","bbox":[60,40,120,61,40,120],"tier":500}]},
 "materials":{"bed":1,"cabinet":1}}
```

### 9.9 `plans/year1.json` phases (kind `phases`, WP11 writes, kern loads at adopt into `K.plan.phases`)
`{v:2, kind:'phases', phases:[{id:'P0'..'P7', title:str, approve:bool, deliver:[deliverable]}]}`. A phase with `approve:true` (★) is entered only when `K.plan.phase_target >= id`. The runner advances `phase` when every deliverable of the current phase passes:

| `k` | Extra keys | Passes when |
|---|---|---|
| `baseline` | | persist `marker.baseline == 1` |
| `proj` | `tpl`, `stage?` | a project with this template is done (or reached stage index `stage`) |
| `squads` | `n` | `K.view().mil.squads >= n` |
| `drill` | | `K.view().ready.drill_age >= 0` |
| `workshops` | `types` (array, or `["moodable"]`) | manifest `workshops` or a built workshop/furnace of the fort covers the types (moodable = the 12 of DESIGN §5.9; live L1b: also a workshop built by hand counts) |
| `stock` | `key`, `min` | `K.view().stock[key] >= min` |
| `orders` | `lib` | `K.call('economy','imported', lib)` |
| `trade` | `n` | `K.call('trade','done') >= n` |
| `ready` | `lvl` | `K.view().ready.lvl >= lvl` |
| `metal` | `pct` | `K.view().mil.metal_pct >= pct` |
| `bolts` | `n` | `K.census.i.bolts >= n` |
<!-- ex:phases -->
```json
{"v":2,"kind":"phases","phases":[
 {"id":"P0","title":"baseline and stage 1","approve":false,"deliver":[{"k":"baseline"},{"k":"proj","tpl":"fortcore","stage":1}]},
 {"id":"P6","title":"iron kits and R2","approve":true,"deliver":[{"k":"metal","pct":80},{"k":"bolts","n":300},{"k":"ready","lvl":2}]}]}
```

### 9.10 `snap/<id>.json` (kind `snapshot`)
`{v:2, id, tick, purpose:'audit'|'sites'|'debug', bbox, rows:{"z<N>":[str]}, bridges:{<bridge>:state}, traps:[[x,y,z,type,n,ready?]], marks?:{<name>:[pos] ≤500}}`. For every z in `z0..z1` there is a key `"z<z>"` with `y1-y0+1` strings of exactly `x1-x0+1` legend chars; `rows["z<z>"][y-y0+1]` (1-based in Lua) char `x-x0+1`. Trap `type` ∈ `W` weapon, `S` stone-fall, `C` cage, `P` pressure plate, `X` other; `n` = weapon components (0 for others); `ready` flag (1 = loaded/armed, default 1). `marks` names: `damp`, `warm`, `cavern`, `water`, `refuge` (free list for the audit).

| Char | Tile | Char | Tile |
|---|---|---|---|
| `?` | not revealed | `X` | up/down stair |
| `_` | open space (no floor) | `r` / `v` | ramp / ramp top |
| `.` | walkable floor (incl. passable furniture) | `+` | door or hatch (never a barrier) |
| `#` | natural wall, rough (climbable) | `=` / `H` | bridge footprint lowered / raised (barrier) |
| `S` | natural wall, smoothed or engraved | `^` | trap (details in `traps`) |
| `C` | constructed wall | `B` | impassable building tile |
| `F` | fortification | `w` / `~` | water 1-3 (walkable) / 4-7 |
| `<` / `>` | up / down stair | `%` / `T` | magma / tree trunk |
<!-- ex:snapshot -->
```json
{"v":2,"id":"c200","tick":1333056,"purpose":"audit","bbox":[10,20,120,15,21,121],
 "rows":{"z120":["#..=.#","#^.H.#"],"z121":["??____","CCC.CC"]},
 "bridges":{"B1":"up"},"traps":[[11,21,120,"W",3,1]],"marks":{"damp":[[15,21,121]]}}
```

### 9.11 `perf.csv`
Header (first line of a new file) and one row per 30 s, integers only:
`wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods` where `ms_s` = kernel ms per second, `gaps3` = frame gaps > 3 s in the window, `mods` = `name=ms;name=ms` (ms summed over the 30 s window, no commas inside). Names are the cost owners of §3.3.8 (modules, `k.*`, `kern`); `repeat` is DFHack's own counter for the whole `dfllm` repeat-util callback (unpaused frames, `getTickCount` clock), the same time as `ms_s` measured again: a cross-check, not an owner (FR-62).
```
wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods
1791676800,1333056,PEACE,462,52,180,9120,11,420,0,sense=41;siege=9;runner=120
```

### 9.12 `commands.log` and `kern.log`
Tab-separated text lines. `commands.log`: `wall \t tick \t origin \t what \t args_json \t result` where `origin` = module name or `inbox:<id>:<by>`, `what` = `act.<fn>` or `verb:<verb>`, `result` = `ok` or `ERR <msg>`. `kern.log`: `wall \t tick \t level \t module \t msg`. Only kern writes these; Python logs to its own `cli.log`.

### 9.13 `restore.json` (kind `restore`)
`{v:2, save:str, wall:int, active:flag, orig:{gfps?:int, autosave?:str, visitor_cap?:int, population_cap?:int, timestream_fps?:int, weather?:bool, fps_cap?:int, overlays?:{<name>:bool}}}` (`fps_cap` = the vanilla FPS cap, `enabler.fps`, which the clock governor lowers: mode caps, the reflex clamp, the supply brake, `tempo.lower`; the arbiter only ever lowers it, so the crash heal restores any live cap below `orig.fps_cap`). Written by arbiter **before** its first change at boot (`active:1`), set `active:0` after the restore at unload. At the next boot of *any* save, `active:1` means a crash: restore first. Mirrored in persist `restore`.
<!-- ex:restore -->
```json
{"v":2,"save":"region3","wall":1791676800,"active":1,"orig":{"gfps":250,"autosave":"SEASONAL","visitor_cap":300,"population_cap":75,"timestream_fps":-1,"overlays":{"hotkeys.menu":true}}}
```

### 9.14 `config/allowlist.json` (kind `allowlist`, WP4 fills it, act and lint read it)
`{v:2, commands:{<cmd>:{rw:'r'|'w', args:[pattern]}}, blocked:[str], armok_exceptions:[str]}`. A call `act.run(cmd, a1, a2, ...)` is allowed iff `cmd` is in `commands`, no `blocked` entry matches, and the joined args match one pattern: space-separated tokens, `*` = exactly one token, `**` = any rest (also none), `""` = no arguments; an empty `args` list allows only the bare command. A `blocked` entry is a token prefix of the command line (`fastdwarf`, `caravan extend`, `lever pull --instant`) or a single flag that is blocked anywhere in it (`--instant`, `--hidden`); `blocked` wins over `commands`. At boot kern cross-checks `helpdb.get_tag_data('armok')`: an allowlisted armok command must be in `armok_exceptions`.
<!-- ex:allowlist -->
```json
{"v":2,"commands":{"control-panel":{"rw":"w","args":["enable *","disable *"]},"labormanager":{"rw":"r","args":["status"]},
 "seedwatch":{"rw":"w","args":["**"]},"uniform-unstick":{"rw":"w","args":["--all --drop --free"]}},
 "blocked":["digv","digvx","fastdwarf","reveal","createitem","dig-now","build-now","fix/retrieve-units"],"armok_exceptions":[]}
```

### 9.15 `live.lock` (kind `lock`, Python only)
`{holder:str, purpose:str, expires:int (wall, ≤ now + 1800)}`.
<!-- ex:lock -->
```json
{"holder":"WP5","purpose":"drill L3","expires":1791678600}
```

### 9.16 `config/decisions.yaml` (WP4)
Flat lines `D-NN: value  # comment`; values are bare words or integers, no nesting, no quotes. There are exactly two readers, `schema.parse_decisions(text)` and `contract.parse_decisions(text, into?)` (kern and every Lua module use the latter; no other copies), and both apply exactly:
1. strip one UTF-8 BOM at the start of the text;
2. split on `\n` (LF only);
3. strip spaces, tabs and `\r` at both ends of each line (nothing else: no other Unicode whitespace);
4. match `^(D-[0-9][0-9])[ \t]*:[ \t]*([^#]*?)[ \t]*(#.*)?$` (ASCII digits only);
5. skip lines that do not match or whose value is empty; a later line for the same id wins.

So an indented `  D-07: visitor30` counts, a commented `#   D-07: …` does not. Shared vectors (BOM, indentation, tabs, CRLF, empty value, inline `#`, duplicates, junk): `fixtures/v2/decisions_vectors.json`, run against both readers by `tests/test_schema.py`. Missing ids take the defaults of `contract.DECISIONS` (DESIGN §15): D-01 `A`, D-02 `unchanged`, D-03 `rule`, D-04 `off`, D-05 `off`, D-06 `off`, D-07 `unchanged`, D-08 `dropped`, D-09 `no`, D-10 `off`, D-11 `accepted`, D-12 `15/20`, D-13 `no`, D-14 `down` (peace_gates, FR-55).

### 9.17 `config/baseline.json` (WP8)
A JSON object read by kern into `K.cfg.baseline`; its keys are WP8-internal (`v:2` required).

### 9.18 `config/reflex.json` (FR-51/52/53)
A JSON object read by kern into `K.cfg.reflex` (`{v:2}` when missing or invalid; every bad key falls back to its built-in default, fail-open; `python -m dfpilot.lint --config` reports bad keys): `{v:2, about?:str, clock?:{siege_cap?:int 10-1000 (30), alert_cap?:int 10-1000 (100)}, hold_quiet_days?:int 0-30 (2), ack_timeout_s?:int 5-3600 (60), defaults?:{<interrupt type>:[action]}}`. Actions: `clock` (timestream off, FPS cap at `siege_cap`), `gates` (every linked drawbridge up), `doors` (entrance doors forbidden: built doors next to revealed open sky and `seal.entrance_doors`; each one only once no citizen (soldiers excluded) is on its outside side (`seal.door_outside`; without seal, sense's citizens outside Kern+), at once with a visible hostile within 15 tiles of it, and in any case 450 ticks after the civ alert began to call them in (BUG-013; without the `alert` action, after the lockdown first wanted the doors); the undo after quiet opens exactly the doors it forbade), `alert` (civ alert, burrow by seal: Kern+, else `Innen+`, kept for the lockdown when every burrow fails; once no lever pull of the lockdown is pending (`gate.pulls`), at the latest after 2x the last measured lever latency (450-1500 ticks, 900 before the first measurement; BUG-013), at once when the lockdown raises no gate or a hostile is ≤ 30 tiles from a citizen outside Kern+: the alert keeps civilians away from levers outside its burrows, live L3; while pulls are pending the alert lists seal's lever burrow `Hebel+` too, see `gate.rooms`). `defaults.ARRIVAL` is also the set issued at once on an arrival; the other entries apply when that interrupt stands unacked for `ack_timeout_s` (defaults: INTRUDER all four, PREDATOR clock+alert, DEATHS_3PLUS clock, NO_DEPOT none).

---

## 10. Persistent site data
Stored with `dfhack.persistent.saveSiteDataString(key, json.encode(v))` and read with `getSiteDataString` + `json.decode` (Lua API.txt:750-758), always through `K.persist`. **Without the marker the kernel does nothing** (`dfllm boot` is a no-op; Inchcraft stays untouched).

| Contract key | DFHack key | Owner | Schema (kind) |
|---|---|---|---|
| `marker` | `dfllm` | kern (`dfllm adopt`) | `{v:2, adopted:tick, save:str, fort:str, acceptance:flag, baseline:flag, boots:int}` (`persist.marker`) |
| `manifest` | `dfllm.manifest` | runner | §11 (`manifest`) |
| `projects` | `dfllm.projects` | runner | `{v:2, list:[{id, tpl, site, class, prio:1-7, stage:int (0-based), chunk:int, pct:0-100, blocked:str, since:tick, created:tick, done:flag, orders_done:flag}]}` (`persist.projects`) |
| `bp.<id>` | `dfllm.bp.<id>` | runner | the §9.8 document (≤ 24 KB, §9.8). **Written once** when the project is registered and never `touch`ed or re-set; progress (`stage`, `chunk`, `pct`) lives only in `projects`. Deleted when the project is done or cancelled. The runner decodes at most one bp (file or uncached `bp.<id>`) per frame. |
| `plan` | `dfllm.plan` | kern | `{v:2, plan:<§9.7>|null, phases:<§9.9>|null, loaded:tick}` (`persist.plan`) |
| `phase` | `dfllm.phase` | runner | `{v:2, phase:'P0'.., since:tick, done:[phase ids]}` (`persist.phase`) |
| `mode` | `dfllm.mode` | kern (inside `K.set_mode`) | `{v:2, mode, since:tick, why:str, prev:mode}` (`persist.mode`) |
| `drill` | `dfllm.drill` | drill | `{v:2, streak_fail:int, last:[{tick, pass:flag, raised:int (ticks to last bridge up, −1), worn:int, outside:int, dbl:int, fails:[str]}] ≤5}` (`persist.drill`) |
| `restore` | `dfllm.restore` | arbiter | §9.13 (`restore`) |
| `kern` | `dfllm.kern` | kern | `{v:2, ev:int, seq:int, boots:int, disabled:[module]}` (`persist.kern`) |
| `m.<module>` | `dfllm.m.<module>` | that module | module-private, `v:2` required |

---

## 11. Manifest (kind `manifest`)
The fort-specific geometry, written by templates (bp `manifest` fragments) and merged by the runner. Absolute coordinates. All keys optional except `v`.

| Key | Type | Meaning |
|---|---|---|
| `bridges` | `{<bridge>:{role:'outer'|'inner'|'core', fp:bbox (z0==z1), levers:[pos] 1-4}}` | O1 outer, B1 inner, B2 core seal; R1 needs 2 levers each |
| `stations` | `{melee?:pos, gallery?:pos, b2?:pos}` | squad stations (melee inside B1, crossbows in the gallery, B2 hold) |
| `killboxes` | `[{id, bbox}]` | the only places kill orders may target |
| `burrows` | `{<name>:{role:'kern'|'refuge'|'other'}}` | `Kern+` (Z3+Z4), `Tiefe+`; trailing `+` = burrow plugin auto-expand |
| `edge` | `[pos]` | attacker source tiles outside O1 (empty = all revealed walkable map-edge tiles) |
| `refuge` | `{anchor:pos, burrow:str}` | |
| `stairs` | `{civ:[[x,y,z0,z1]], mil:[[x,y,z0,z1]]}` | stair columns |
| `zones` | `{Z1?:[bbox], Z2?:[bbox], Z3?:[bbox], Z4?:[bbox]}` | doctrine zones |
| `rooms` | `[{id, tpl, use:'used'|'utility', bbox, tier:int}]` | beauty applies only to `used` |
| `workshops` | `[{type:str, pos}]` | df.workshop_type / furnace names |
| `pit?`, `depot?` | pos | captive pit zone; trade depot |

**Merge rule** (fragment → fort manifest): maps (`bridges`, `stations`, `burrows`, `zones` keys) are replaced per key; arrays of objects with `id` (`killboxes`, `rooms`) are replaced per id; `workshops` per `pos`; plain arrays (`edge`, `stairs.civ`, `stairs.mil`, zone bbox lists) are appended without duplicates; scalars are replaced.
<!-- ex:manifest -->
```json
{"v":2,"bridges":{"O1":{"role":"outer","fp":[50,10,130,52,12,130],"levers":[[55,20,130],[56,20,130]]},
  "B1":{"role":"inner","fp":[50,40,130,52,40,130],"levers":[[54,45,130],[55,45,130]]}},
 "stations":{"melee":[51,44,130],"gallery":[51,30,131],"b2":[51,60,125]},
 "killboxes":[{"id":"K1","bbox":[48,30,130,54,36,130]}],
 "burrows":{"Kern+":{"role":"kern"},"Tiefe+":{"role":"refuge"}},
 "edge":[[51,0,130]],"refuge":{"anchor":[70,70,110],"burrow":"Tiefe+"},
 "stairs":{"civ":[[60,60,110,130]],"mil":[[45,45,120,130]]},
 "zones":{"Z2":[[40,12,130,60,29,130]]},
 "rooms":[{"id":"dining1","tpl":"dining","use":"used","bbox":[62,50,125,70,58,125],"tier":2500}],
 "workshops":[{"type":"Craftsdwarfs","pos":[64,62,125]}],"pit":[80,80,110],"depot":[51,8,130]}
```

---

## 12. Event type registry
`by` = the only emitter (`any` = any module). Known `d` keys are typed (int unless noted); **bold** keys are required; other keys are allowed. Rate rules (the emitter's job): emit on change only; the same A event (type and `d`) at most once per 1,200 ticks.

| Type | Cls | By | `d` |
|---|---|---|---|
| SIEGE_END | A | siege | hostiles, killed, lost, captures, sealed_ticks |
| GATE_FAIL | A | gate | **bridge** (str), want (str), why (str: no_worker, timeout, blocked, no_lever) |
| BREACH | A | siege | **why** (str: gate_fail, inside), bridge (str) |
| DEATHS_3PLUS | A | care | n, ids (int[]), causes (str[] `unit:cause`) — the text names the causes (`3 citizens died within a day: drowned 2, dehydrated 1`) |
| DRILL_FAIL | A | drill | streak, fails (str[]) — emitted on the 2nd consecutive failed drill |
| KERN_FAULT | A | kern | **module** (str), err (str), n, backoff_s — every back-off (§3.3.5); `err:'slow'` for a slow critical module (§3.3.6) |
| PERF_DEGRADED | A | perf | tps, base, pct, why (str) |
| DECISION_NEEDED | A | any | **id** (str, e.g. D-07), q (str) |
| PLAN_EXHAUSTED | A | runner | phase (str), year |
| PROJECT_BLOCKED | A | runner | **proj** (str), tpl (str), stage (str), why (str), ticks — after > 2 days blocked |
| YEAR_REVIEW | A | kern | year |
| GHOSTS | A | care | ghosts, corpses, old, units (int[]), causes (str[] `unit:cause+cause`) — FR-04/26: a citizen ghost exists or a citizen body lies unburied longer than `corpse_old`; again only when the set grew or a new cause appeared, not before max(7 game days, 10 min wall clock) (BUG-008) |
| HOSPITAL_DRY | A | water | **why** (str), patients, zone, near, recipe (str) — FR-31/34: a hospital location (or a pending hospital project with no accepted water at all) without a well over water or a Water Source zone on water ≥ 4/7 within `near` tiles; at the start of the dry episode, then weekly with patients, else monthly |
| MOOD_RISK | A | care | **unit**, **why** (str: missing, thirst, hunger), kind (str), missing (str[] classes), thirst, hunger, nosrc (str[] classes without any item in the fort) — FR-44: a strange mood starts without its materials, or the moody dwarf passes the thirst/hunger line (every 2 days); the mood job is never cancelled; BUG-017: only filters without an attached item count (read again at report time; an attached item without a filter index covers a filter it fits), and a class nothing in the fort can supply is named (`leather: no source in the fort`) |
| SIEGE_START | A | siege | vis, inv, great, why (str) — class A since Run 9: it wakes at once |
| INVASION | A | threat | id — class A since Run 9 |
| ARRIVAL | A | any (reflex; arbiter as fallback) | **kind** (str: siege, ambush, snatcher, beast, invasion, invader), src (str: popup, report, invasion, sighting), text (str), raised, doors, alert (str: what holds, siege.hold_alert, or `after the gates (<= n ticks)`), clock, out, eta, up, left, blocked (BUG-013: bridges up, pulls left, pulls the alert blocks) — an arrival and the lockdown issued for it (interrupt); the text puts clock, alert, doors (`doors N forbidden, W waiting for C citizens outside`, `partial lockdown: <kind> x,y,z has no door`) and gates (`gates: 2 of 4 up, 2 pulls pending (levers in Hebel+)`, `... 2 pulls blocked (levers outside the alert burrow)`) first and the announcement last; LOCKDOWN the same |
| INTRUDER | A | reflex | n, id, pos (int[3]), k (str) — a visible invader, undead or great danger on the citizens' walkable group (interrupt) |
| PREDATOR | A | reflex | n, id, pos (int[3]) — a visible wild danger on a roofed tile of that group (interrupt) |
| NO_DEPOT | A | reflex | text (str) — merchants need a trade depot (interrupt); once per caravan visit (BUG-008) |
| LOCKDOWN | A | reflex | **why** (str: ack_timeout), n, type (str), raised, doors, alert (str, as ARRIVAL), clock — the kernel applied an interrupt's lockdown default itself |
| DEPOT_MISSING | A | trade | civ (str), planned (flag: a planned depot progresses: job running with a builder or stage > 0), stalled (flag), why (str: why the planned one does not progress), proj (str: the depot project runner.depot_keep queued) — a caravan on the map and no built trade depot, once per visit (FR-43, BUG-005) |
| ORDER_BAD | A | economy | **order**, **job** (str), dropped (flag) — a make-item order without item_subtype (DF 53.16 crash, FR-39); economy removes it at once (`order_guard.drop`) |
| CUTOFF | A | seal | **cls** (str: food, drink, bed), **n** (citizens), pos (int[3], the tile that did it), why (str: wall, door, bridge, … or unknown), grp, main — more citizens than before stand on a walk group without that class (FR-22); a raised bridge outside PEACE (the gate raises it on purpose) is a SEAL instead |
| SEAL_LEAK | A | seal | **routes**, pos (int[3], first leak), bld (str), state (str: locked, open, down …), why (str: lever, siege, construction, periodic) — the outer/inner bridges are up and a route from the map edge to the citizens remains (FR-54) |
| PERIMETER_BROKEN | A | seal | **n**, pos (int[3]), kinds (str[]), requeued, why (str) — perimeter pieces lost during an episode (a siege, an ALERT, a reflex lockdown; diffed at RECOVERY and once the fort is quiet again: PEACE without a lockdown); walls/doors re-queued as a `repair` project (FR-56) |
| AUTOLABOR_LEGACY | A | baseline | **fixed** (flag: set to monitor; 0 since BUG-014), why (str: boot, apply, economy daily), after (str: the engine read back) — autolabor found enabled in legacy mode, the engine of the Run 9 crashes (BUG-010), and the switch to monitor failed; a switch that worked (read back with `autolabor mode`) is one kern.log line (BUG-014) |
| REFUGE_FAIL | A | seal | **burrow** (str, refused), fallback (str, `""` = no confinement), why (str), tiles, inside, mode (str) — the civ alert refused a burrow without drink/food/beds for the population (FR-37/57) |
| LOCKDOWN_PARTIAL | A | reflex | **doors** (held now), refused (int[] door ids), pos (int[3], the newest refused), retry (flag: its one retry is left), items, units (on or next to its tile) — BUG-015: an entrance door the lockdown forbade read back unforbidden on the next pass (`partial lockdown: door 16970 (74,70,117) refused (flag reset; 2 items, 0 units on or next to its tile), one retry (forbidden + closed) once that changes (<= 1200 ticks), doors 0 held`); the door leaves the count and the undo, the doors text names it (`partial lockdown: door … refused (flag reset)`), and it is tried once more when the units or items there changed, at the latest 1,200 ticks later; cadence: the first refusal of a lockdown at once, a new door or a failed retry again after max(7 days, 10 min) |
| DEATHS_PREVENTABLE | A | care | as DEATH_CLUSTER — FR-64: the class-A twin of a DEATH_CLUSTER whose cause is `dehydrated` or `starved` (preventable: drink or food forbidden, unreachable, or not brought to patients); the text puts the stock days and the next step (`inspect reach`, `inspect refuge`, patients: hospital water) before the units |
| ALERT_START / ALERT_END | B | siege | vis |
| LOCKDOWN_END | B | reflex | why (str), ticks, doors, refused — threat 0 for `hold_quiet_days`: doors opened (only those whose flag the kernel held), clock and alert back to the mode; BUG-015: `refused` doors never held (`, 1 refused (flag reset)`) |
| MOOD_START / MOOD_NEED / MOOD_END | B | care | unit, kind (str), need (str), ok (flag) |
| CARAVAN | B | trade | phase (str: arrive, traded, left), ratio, civ (str) |
| MIGRANTS | B | economy | n |
| PETITION | B | care | kind (str) |
| STOCK_LOW | B | economy | **key** (str), days, min |
| CANCEL_LOOP | B | economy | order, job (str), n |
| LABOR_STARVED | B | economy | **labor** (str), cycles, to (str: managed, monitor) — a supply labor labormanager starved: a builtin tool labor becomes managed, otherwise labormanager falls back to monitor (live L1) |
| WORK_DETAIL | B | economy | **detail** (str), **unit**, **on** (1 added, 0 removed), n (target), why (str) — economy changed a builtin tool detail (live L1b) |
| CAPTURE | B | care | unit, race (str) |
| BREACH_STOP | B | runner | proj (str), why (str: damp, warm, cavern, water), pos (int[3]) |
| KERNEL_SLOW | B | kern | **module** (str), ms, factor |
| WEALTH | B | siege | created, exported, imported |
| DRILL_RESULT | B | drill | pass (flag), raised, worn, outside, dbl |
| READY_CHANGE | B | readiness | from, to, fail (str[]) |
| POPCAP | B | readiness | **cap**, why (str) |
| AUDIT | B | readiness | ok (flag), fails (str[]), min_traps |
| PROJECT_DONE | B | runner | **proj** (str), tpl (str) |
| PROJECT_REQUEST | B | any | **tpl** (str), n, why (str) — follow auto-places `tombs`, `workshops`, `bedrooms` why=mood_rock (prio 1) and `farms` why=food (p.plots = n, 1-4, prio 1; economy, live L5) at the top site; others go to the digest |
| PHASE | B | runner | from (str), to (str) |
| PAUSE | B | arbiter | **on** (flag), by (str), ttl |
| DEATH | B | care | unit, citizen (flag), cause (str: dehydrated, starved, killed, drowned, suffocated, bled, mood, old_age, crushed, burned, infection, unknown), src (str: incident, unit, report, timer, mood, none — what decided), why (str: the evidence, e.g. `incident THIRST; thirst 18879; patient`), found (flag: 0 while the unit list shows the dwarf as missing; nothing else is read then), dtype (str, df.death_type), by (str: the killer's race, a name from the report, `trap`), killer, mood (str: the strange mood's kind), thirst, hunger, patient (flag), pos (int[3]), job (str: the last job), revised (flag: the second DEATH of a death found later) — FR-64; the msg is `citizen <id> died: <cause> (<why>)` (`found dead` when revised) |
| DEATH_CLUSTER | B | care | **cause** (str: a DEATH cause or `mixed`), **n**, units (int[] ≤ 10), causes (str[] `unit:cause[ by x]`), total (deaths in the window), days (window), patients, pos (int[3], the newest death), job (str), hint (str), stock (drink or food days) — FR-64: ≥ `care.death_same` (2) citizens died of one cause (not `unknown`, not missing) or ≥ `care.death_any` (3) of any within `care.death_window` (28 days); again only when a new death joined, not before max(`care.death_every` ticks, `care.wake_wall_s`) (BUG-008); a same-cause line names the total, so the `mixed` line is left out for the same deaths |
| ACT_FAIL | B | kern | **fn** (str), err (str), module (str) |
| ORDER_STUCK | B | economy | **order**, **job** (str), **why** (str), n, days, dropped (flag) — an order that cannot run for `orders.stuck_days` (workshop, input on the citizens' walk group, worker; FR-01), or removed after `orders.needs_drop` "Needs ..." cancels (FR-10) |
| TRADE_LEDGER | B | trade | civ (str), ok (flag), ratio, sold, sold_v, bought, bought_v (units and values), unmet (str[] `token:why`, why = none / value / part / the failure reason) — one per finished visit; the last 3 stay in persist `m.trade.ledger` and `inspect what=trade` (FR-32) |
| JOBS_SUSPENDED | B | economy | suspended, released (resumes that held a frame), resuspended, kept, planned, why (str), forbidden, other (items on the footprints), unforbidden, missing (str: classes none of in reach), blocked — suspended ConstructBuilding jobs: resumed, kept by suspendmanager, waiting for buildingplan (FR-16, BUG-009/004); emitted when the numbers change |
| SEAL | B | seal | routes, pos (int[3]), why (str), sealed (flag) — an entrance check ("seal verified: no route" or the leak); also citizens shut out by a raised bridge outside PEACE |
| REACH | B | seal | flags (str[]), cut, stairs — the reach audit's flags changed (classes off the main citizen group, stairs without counterpart) |
| SIEGE_STATUS | C | siege | vis, worn, on_station, deaths, captures |
| SEASON | C | kern | year, season |
| PROJECT_STAGE | C | runner | **proj** (str), stage (str), pct |
| MODE | C | kern | **from** (str), **to** (str), why (str) |
| GATE | C | gate | **bridge** (str), state (str) |
| LEVER | C | gate | **bridge** (str), lever, job |
| SNAPSHOT_READY | C | snapshot | **id** (str), **path** (str, relative to `<save>`, e.g. `snap/c200.json`), purpose (str) |
| CMD | C | kern | **id** (str), **verb** (str), **ok** (flag) |
| BOOT | C | kern | save (str), v, boots |
| UNLOAD | C | kern | |

Class semantics (DESIGN §6): **A** wakes the LLM (follow rate limits apply), **B** goes into the digest/brief, **C** is log only (follow still reads `SNAPSHOT_READY` to run the audit).

**Interrupts** (FR-53, `contract.INTERRUPTS` / `schema.INTERRUPTS`): ARRIVAL, INTRUDER, PREDATOR, DEATHS_3PLUS, NO_DEPOT. The reflex module writes each to `<save>/alarm.txt` in the step it is emitted; `dfllm wait --until-interrupt` returns on it; `ack` acknowledges it. Unacked for `ack_timeout_s` (real seconds, §9.18), the kernel applies the type's default and emits LOCKDOWN. `follow` wakes at once (no merge wait, no hourly limit, one per type per 60 s) on BREACH, SIEGE_START, INVASION, LOCKDOWN and every interrupt.

---

## 13. Inbox verbs (closed set)
Python (`dfllm cmd`, `plan apply`, follow) validates every inbox document with `schema.validate('inbox', doc)` before writing it. kern validates the envelope (id, known verb, `args` is an object, `by`, `contract.VERB_BY`), checks `modes` and `approve`, routes to the handler `M.verbs[verb](K, args, cmd)` (`cmd = {id, verb, by, ts}`) which returns `ok, msg, data`, and writes the outbox reply. Handlers still type-check the args they use and reply `ok:false` on bad input (a handler error is answered `ok:false, msg:'handler error'`). A handler may accept and defer (reply `ok:true` with msg `queued …`). Unknown verbs, wrong modes, missing approval and disabled modules are answered `ok:false` without calling the handler.

| Verb | Handler | Modes | Args (closed objects) | Reply `data` |
|---|---|---|---|---|
| `plan.reload` | kern | any | `{}`; `{phases: true}` = replace the save's phase list with the repo's `plans/year1.json` (plan and current phase id kept; live L1b) | `{year, builds}`; `{phases}` |
| `bp.place` | runner | any (queued while frozen) | `{tpl, site, p?:object, prio?:1-7}` + any other scalar key is merged into `p`; reads `bp/<cmd id>.json`. FR-27: a tomb cell (`T`) of a zone stage with any tile already in a tomb zone is cut from the project (the reply says how many); a document whose every tomb cell was cut is refused | `{proj}` |
| `bp.cancel` | runner | any | `{proj, undo?:bool}` | |
| `drill` | drill | PEACE | `{why?:str}` | |
| `snapshot` | snapshot | any | `{bbox?:bbox, purpose?:'audit'|'sites'|'debug'}` (snap id = cmd id) | `{id}` |
| `audit` | readiness | any; **by `follow`/`test` only** (`VERB_BY`) | `{snap:id, ok:bool, fails:[str], min_traps:int, bypass:bool, refuge_sep:bool, civ_sep:bool, caverns:bool}` = `bp.topo.audit` result. readiness accepts it only if `snap` names a snapshot that **this boot** exported with purpose `audit` (it records `EV:SNAPSHOT_READY`) and that no earlier `audit` used; otherwise `ok:false, msg:'unknown snap'` | `{lvl}` |
| `popcap.lower` | readiness | any | `{cap:int 0-250}` (lowers the ceiling only) | `{cap}` |
| `tempo.lower` | arbiter | any | `{fps:int 10-1000, ttl_s:int 1-3600}` (never above the mode value; lowers the vanilla FPS cap too, FR-51) | |
| `pause` | arbiter | any | `{ttl_s:int 1-600, why?:str}` | |
| `unpause` | arbiter | any | `{}`: releases **only the inbox hold** (`owners.pause == 'inbox'`). A pause owned by `gordon`, `df` or `popup` is never released through the inbox, whatever `by` says; Gordon unpauses in the game | |
| `trade.want` | trade | any | `{want?:[token], sell?:[token]}` | |
| `squad.sortie` | military | ALERT, SIEGE, BREACH, RECOVERY | `{squad:'A'|'B'|'C', target:str (killbox id) or pos, approve:true}` | |
| `lever` | gate | PEACE | `{bridge, want:'up'|'down'}` | `{job?}` |
| `inspect` | kern | any | `{what:'state'|'modules'|'census'|'manifest'|'projects'|'persist'|'perf'|'mode'|'plan'|'tombs'|'water_sources'|'orders'|'workload'|'trade'|'reach'|'entrances'|'defense'|'perimeter'|'refuge', key?:str}`; `tombs` and `water_sources` are answered by care and water (§7; `tombs` carries `prov`, the coffin provisioner's numbers, FR-61); any other `what` kern does not answer goes to the module with `M.inspect[what]` (economy: `orders` FR-01, `workload` FR-40; trade: `trade` FR-18/32; seal: `reach`, `entrances` (each opening with its doors, BUG-012), `defense`, `perimeter`, `refuge` (with the `LOCKDOWN` choice, BUG-011), where `key:'refresh'` re-runs the audit first) | ≤ 8 KB |
| `selftest` | selftest | any | `{suite?:'quick'|'full'}` | `{pass, fail}` |
| `module.enable` | kern | any | `{module:str}` (module name, §1.1) | `{module}`; re-enables a backed-off module now and resets its backoff doubling (§3.3.5); `ok:false` for an unknown module |
| `tombs.repair` | care | any | `{}` (FR-27): the next care run repairs the tombs in any mode (also with `tomb_repair` off) and gives every unburied citizen body a fresh `entomb` try | `{queued}` |
| `ack` | reflex | any | `{n?:int ≥ 0}` (default: the newest interrupt) | `{n, open, defcon}`; the operator saw the interrupts up to `n`; their ack-timeout default no longer applies (FR-53) |
| `order.add` | economy | any | `{job:str, amount:1-999, item_subtype?:'ITEM_…', material?:str, material_category?:[str], reaction?:str, frequency?:'OneTime'|'Daily'|'Monthly'|'Seasonally'|'Yearly'}`; a make-item job without `item_subtype` is refused (FR-39; `schema.validate_args` refuses it before sending) | `{order}` |
| `jobs.release` | economy | any (resumes refused in SIEGE/BREACH/DRILL) | `{all?:bool, preventblocking?:bool}`: resumes suspended ConstructBuilding jobs nobody keeps (all = also the ones suspendmanager keeps; buildingplan's never); `preventblocking` sets suspendmanager's option, a persisted fort decision economy applies again after every load (FR-16) | `{resumed, suspended, kept, planned, why}` |
| `perimeter.record` | seal | any | `{}` (FR-60): the next entrance check (urgent) records the perimeter: every wall, door, gate or bridge around a known opening that is sealed now and, on a sealed fort, the closers on the boundary of the citizens' group (forts without a fortcore manifest); `inspect perimeter` shows the pieces and `rec` | `{queued, n, open}` |

There is no arbitrary Lua.

**Trust rules** (files cannot be authenticated, so origins are guarded where the LLM acts; WP4 implements them in `hook`/`lint`, WP2 in `cmd`):
- In LLM tool calls (Bash, PowerShell) the hook rejects `--by` with any value other than `llm` or `cli`, any inbox JSON containing `"by"`, and `dfllm cmd audit` (audit results come only from `dfllm follow`).
- The hook also covers the Write/Edit/NotebookEdit tools: the LLM may not write anything under `dfllm-runtime/` (inbox, plan, bp, state …) or `config/decisions.yaml`; those are written by `dfllm` commands and by Gordon.
- `dfllm cmd` writes `by:'cli'` by default; `follow` and `supervise` write their own origin; `by:'gordon'` is only a log label for commands Gordon types in his own terminal. `audit` semantics: `bypass:true` = an edge→Z3 path avoids the trap hall (bad); `refuge_sep`, `civ_sep`: true is good; `caverns:true` = caverns sealed (good).

---

## 14. Modes
`PEACE, ALERT, SIEGE, BREACH, RECOVERY, DRILL`; entry conditions, timings and actuator values are DESIGN §3-§4 (mode table and siege reflex). Allowed transitions (`contract.TRANSITIONS`):

| From | To |
|---|---|
| PEACE | ALERT, SIEGE, DRILL |
| ALERT | PEACE, SIEGE, BREACH |
| SIEGE | BREACH, RECOVERY |
| BREACH | RECOVERY |
| RECOVERY | PEACE, ALERT, SIEGE, BREACH |
| DRILL | PEACE, ALERT, SIEGE |

`siege` may set any allowed transition; `drill` only PEACE→DRILL and DRILL→PEACE. The mode is persisted (`mode` key) and restored at boot, so a reload mid-siege stays in SIEGE.

---

## 15. Python interfaces (stdlib only)
| Module (WP) | Interface |
|---|---|
| `schema` (WP0) | `validate(kind, doc) -> list[str]`, `check(kind, doc) -> doc` (raises `SchemaError`), `validate_args(verb, args) -> list[str]`, `prune_state(doc) -> (doc|None, errors)` (§9.3 reader rule), `json_schema(kind) -> dict`, `parse_decisions(text) -> dict`, `decision(id, decisions=None) -> str`, `inbox_name(id, ts_ms) -> str`, `INBOX_NAME_RE`, `KINDS`, constants `MODES, EVENTS, VERBS, VERB_BY, ACT, MODULES, DECISIONS, KERN, BP_MAX_CELLS, BP_MAX_BYTES, SNAP_LEGEND, ORDER_LIBS, ID_RE`; CLI `python -m dfpilot.schema validate <kind> <file>` (`.jsonl`: every line), `--json-schema <kind>`, `--appendix`, `--write-appendix docs/v2/CONTRACTS.md` |
| `paths` (WP2) | `df_dir()`, `runtime_root()`, `active_save() -> str|None`, `save_dir(save=None) -> Path` |
| `files` (WP2) | `read_state(save_dir) -> dict|None` (both slots through `schema.prune_state`, best remaining `seq`, one retry), `tail_events(save_dir, since_n) -> list[dict]` (handles rotation), `write_inbox(save_dir, verb, args, by) -> id`, `read_outbox(save_dir, id, timeout_s) -> dict|None` |
| `bp.emit` (WP3) | `emit(tpl, params, site) -> dict` = a §9.8 document without `id` (caller sets it) |
| `bp.topo` (WP3) | `audit(snap, manifest) -> {ok, fails, min_traps, bypass, refuge_sep, civ_sep, caverns}` (exactly the `audit` verb args minus `snap`) |
| `bp.sites` (WP3) | `rank(snap, tpl, params=None) -> [{id:'S1'.., anchor:[x,y,z], rot, score:int, why:str}]` (top 3) |
| `lint` (WP4) | `lua(paths) -> [{file, line, rule, msg}]`, `cmd(text) -> (allowed: bool, reason: str)` (includes the §13 trust rules) |
| `fairplay` (WP4) | `get_decision(id) -> str` (reads `config/decisions.yaml`, defaults from `schema.DECISIONS`) |
| `supervise` (WP10) | `once(now=None) -> dict` (liveness from heartbeat mtime > 120 s, DEGRADED rule, restart only in PEACE right after an autosave) |
| `alarm` (FR-53) | `read_alarm(save_dir) -> dict|None` (`<save>/alarm.txt`), `wait_interrupt(save_dir, since=None, timeout=15) -> (items, alarm)`; CLI `dfllm wait --until-interrupt [--timeout S] [--since N]` (exit 0 interrupt, 1 timeout), `dfllm ack [--n N]` |

---

## 16. Offline testing
- **luahost.** `python tools/luahost.py [--path DIR] file.lua [args]` runs a file on DFHack's `hack/lua53.dll` (Lua 5.3, C++-mangled exports parsed from the PE table; override with `DFLLM_LUA53`). Fresh state per run; `print`/`io.write` captured; `os.exit(n)` returns `n`; CPU-time limit (default 30 s, exit 124). `package.path` = `--path` dirs + `<repo>/lua`. Global `luahost` provides `listdir, isdir, isfile, mkdir_recursive, mtime, now_ms` for io tests. `__ipairs`/`__pairs` metamethods work (verified), so 0-based DF vector fakes behave like DFHack's.
- **Lua tests.** `tests/lua/test_*.lua` use `local T = require('testlib')` (`T.test, T.eq, T.ok, T.raises, T.done`) and exit 0 on success. `pytest tests/test_luahost.py` runs all of them (tests/lua on the path). From Python: `from luahost import run_file` with `tools/` on `sys.path`.
- **k_mock.** `local W = require('dfllm.util.k_mock').new(opts)` builds a mock world and a contract-checking `K` (`W.K`). It installs fake `df`, `dfhack`, `reqscript`, `CR_OK` globals (unless `opts.globals == false`), implements §3.3 scheduling and §4 exactly, records `act` calls, validates events, verbs (incl. `VERB_BY`), mode transitions, act owners, state ownership and the **state schema** (`contract.check_state` on every compose) against `contract.lua`. API:

| Call | Effect |
|---|---|
| `kmock.new{year=3, ytick=0, ms=0, ms_per_frame=16, mode='PEACE', units={...}, persist={<contract key>=table}, plan=, phases=, cfg={decisions=, allowlist=, baseline=}, census={u=,h=,i=}, marker=true, strict=true, globals=true}` (`cfg` also takes `reflex=`, §9.18) | `strict=true` raises on any contract violation or module error (with the module name), including any state-schema error; `strict=false` drops invalid optional state keys like kern and logs it; `marker=false` starts without the site marker |
| unit spec | `{id, pos={x,y,z}, citizen, resident, insane, adult=true, baby, visible=true, hidden, caged, invader, danger, great, megabeast, fb, titan, demon, undead, dead, offmap, tame, merchant, visitor, animal, squad=-1, stress=3, race, name}`; `dfhack.units.*` predicates read the spec; `u.pos`, `u.flags1.caged/inactive`, `u.flags2.killed` are read-only views of it. `insane` (a berserk or raving citizen): `isCitizen(u)`/`isResident(u)` false but true with `include_insane`, `isSane` false, `isCrazed` and `isDanger` true; `getCitizens(exclude_residents, include_insane)` follows Lua API.txt:1696 |
| `W.load(M)` | register a module (its name must be in contract.MODULES or start with `test_`), call `init(K)`; dispatch order = contract order |
| `W.frame(dt, paused)` | one frame of `dt` ticks (default 1): calendar (SEASON/YEAR_REVIEW), queued eventful events, events emitted last frame (`EV:`), due modules, state compose (every 2 s of mock ms or after `K.flush`) |
| `W.run(ticks, {skip=9})` | frames of `skip` ticks (number or array cycled, last frame partial) until `ticks` passed; `W.run(n, {paused=true})` = n frames, ms only |
| `W.event(name, ev)` | queue an eventful event for the next frame: `('INVASION', {id})`, `('REPORT', {type, text, pos})`, `('UNIT_DEATH', {unit})` |
| `W.inbox(verb, args, {id=, by=})` | route a verb exactly like kern (`VERB_BY`, modes, approval, kern verbs `plan.reload` from `W.plan_file`, `inspect` and `module.enable`); `by` defaults to `'test'`; returns the reply `{id, ok, msg, verb, tick, data}` |
| `W.set_census(part, tbl)` | set `K.census.u|h|i|a` directly (tests without sense/economy) |
| `W.add_unit(spec)`, `W.unit(id)`, `W.move(id, x, y, z)`, `W.kill(id)` | edit the fake world (change other flags via `W.unit(id)._m`) |
| `W.burrow(name, bbox)`, `W.add_building(spec)`, `W.tiles['x,y,z'] = {des=, occ=, tt=}`, `W.map_size` | burrows (`dfhack.burrows`), buildings (`df.building.find`), tiles (`dfhack.maps.getTileFlags/getTileType`) |
| `W.set_mode(m)`, `W.set_plan(plan)`, `W.plan_file`, `W.unload()` | force a mode; replace `K.plan`; the plan.json `plan.reload` reads; run `on.UNLOAD` |
| `W.act_result(fn, f)` | override an act function: `f(args...) -> ok, res` (default: ok; `pull` returns job ids and fills `W.jobs`; `civ_alert`, `set_paused`, `popcap` change the fake globals) |
| `W.cost[name] = ms` | simulated cost-clock ms per step, drives §3.3.6 exactly: slow calls expire after 10 min of mock ms, demotion (`KERNEL_SLOW`), promotion after 10 quiet minutes, rate-limited `KERN_FAULT` for critical modules |
| `W.scripts[name]`, `W.cmd_outputs[cmd]` | fakes returned by `reqscript(name)` (quickfort, lever, gui/civ-alert provided) and output of `dfhack.run_command_silent` |
| `W.acts`, `W.find_acts(fn)`, `W.events`, `W.find_events(type)`, `W.replies`, `W.logs`, `W.commands`, `W.state()`, `W.clear()` | recorders; `W.state()` composes and returns the state doc |
| `W.persist_raw` | DFHack key → JSON string (what the save would hold) |
| `W.faults` | `{module, where, err}` list (with `strict=false`; 3 faults in 10 min back the module off like kern: skipped for 30 s (critical) or 10 min (others), doubling, then re-enabled; `W.inbox('module.enable', {module=})` re-enables at once) |

`k_mock.lua` is test-only: kern must never `require` it in game.

---

## 17. Ownership of files (W1/W2)
| WP | Files |
|---|---|
| WP0 | docs/v2/CONTRACTS.md, dfpilot/schema.py, dfpilot/bp/__init__.py (empty skeleton, WP3 may extend), lua/dfllm/util/{json,contract,k_mock}.lua, tools/luahost.py, tests/lua/{testlib,test_json,test_k_mock,dump_contract,contract_probe}.lua, tests/test_luahost.py, tests/test_schema.py, fixtures/v2/decisions_vectors.json; skeleton dirs config/, plans/, tests/bp/, fixtures/v2/ |
| WP1 | lua/dfllm.lua, lua/dfllm/{kern,io,persist,arbiter,act,perf,selftest}.lua, lua/dfllm/util/geom.lua |
| WP2 | dfpilot/{__main__,cli,paths,files,wake,brief,plan,cmd,doctor,events}.py |
| WP3 | dfpilot/bp/*.py, tests/bp/ |
| WP4 | dfpilot/{fairplay,lint,hook}.py, config/{allowlist.json,decisions.yaml}, docs/v2/DECISIONS.md, .claude/settings.json |
| WP5 | lua/dfllm/{sense,threat,gate,siege}.lua, tests/lua/test_siege.lua |
| WP6 | lua/dfllm/{military,readiness,drill}.lua |
| WP7 | lua/dfllm/{runner,snapshot}.lua |
| WP8 | lua/dfllm/{baseline,economy,care}.lua, config/baseline.json |
| WP9 | lua/dfllm/trade.lua |
| WP10 | dfpilot/supervise.py, tools/migrate_v2.py, tools/win/vdesk_move.ps1 |
| WP11 | tools/embark/*, plans/year1.json, RULES.md, docs/v2/MIGRATION.md (written as QUICKSTART.md + V1-LEGACY.md) |

Each WP may add its own `tests/lua/test_<module>.lua` and `tests/test_<module>.py`.

## 18. Deviations from DESIGN (decided at the freeze)
1. `snapshot.lua` and `util/geom.lua` were not assigned in DESIGN §12: snapshot → WP7, geom → WP1. `util/contract.lua`, `tests/lua/testlib.lua` and `tests/lua/dump_contract.lua` are new WP0 files.
2. `K.call(module, fn, ...)` and `K.view()` are added to K for cross-module calls and published KPIs; `K.mode` is split into `K.mode()`, `K.mode_since()`, `K.set_mode()`.
3. Item census (`K.census.i`) is owned by economy, not sense.
4. Care does not call the runner for a dug tombs room; it emits `PROJECT_REQUEST` and `dfllm follow` auto-places tombs. Since FR-61 care's coffin provisioner places coffin rows in dug space that already stands itself (`runner.coffins`) and emits `PROJECT_REQUEST tombs why=no_space` only when it finds none.
5. Extra event types: INVASION, DRILL_RESULT, READY_CHANGE, POPCAP, AUDIT, PROJECT_DONE, PROJECT_REQUEST, PHASE, PAUSE, DEATH, ACT_FAIL, MODE, GATE, LEVER, SNAPSHOT_READY, CMD, BOOT, UNLOAD. DRILL_FAIL is class A and emitted only on the 2nd consecutive failure (DESIGN "DRILL_FAIL×2").
6. Optional state keys `t.abs`, `t.wall`, `t.frame`, `save`, `k.disabled`, `k.ms_max`, `mil`, `trade`.
7. `bp.place` reads the emitted blueprint from `bp/<cmd id>.json` (the DESIGN inbox example stays valid); plan builds use `bp/y<Y>s<S>b<I>.json`.
8. (review round 1) Kernel cost is timed with `os.clock()`, not `getTickCount` (DESIGN §0/§4 say "ms only"; `getTickCount` actually moves in 15.6 ms steps). Slow calls decay and demoted modules are promoted back.
9. (review round 1) DESIGN §4 "three faults in 10 min disable that module" becomes a backoff with automatic re-enable and the `module.enable` verb; critical modules are retried after 30 s.
10. (review round 1) `by:'gordon'` grants nothing in the inbox (DESIGN §3 "A pause by Gordon is honoured" holds: the inbox cannot release it); `audit` is accepted only from `follow` with a snapshot this boot exported.
11. (review round 1) Blueprint documents are capped at 1,000 cells and 24 KB; `bp.<id>` is persisted once and never re-encoded.
12. (Run 9, FR-51) DESIGN §3/§16 keep FPS_CAP 250 in SIEGE ("no slow motion"). With the live prefs at 500 that let DF run ~400 ticks/s while 39 of 48 citizens died in 76 s of real time, so SIEGE/BREACH/DRILL now cap the vanilla FPS at `siege_cap` (30) and ALERT at `alert_cap` (100), and a reflex lockdown holds the siege cap from the arrival announcement on (§9.18). DESIGN §14's "SIEGE/DRILL ≥100 ticks/s" KPI becomes "≥ siege_cap".

## 19. Changes after the freeze (review round 1, 2026-10-10)
Each item names the WP that must adapt its code; WP0 changed the contract, `contract.lua`, `schema.py` and k_mock.

| # | Change | Sections | Follow-up |
|---|---|---|---|
| R1 | State schema in Lua (`contract.STATE_SPEC/check_state/prune_state`); k_mock strict raises on any state error; kern prunes invalid optional keys before writing; readers drop only invalid optional keys (`schema.prune_state`) | §2.2, §9.3 | **WP1** kern.compose calls `C.prune_state` and logs drops; **WP2** `files.read_state_ex` uses `schema.prune_state`; **all module WPs**: k_mock now fails tests whose `state()` is incomplete (e.g. nil `owners.pause`, empty plain `bridges`) |
| R2 | Cost clock `os.clock()`; slow-call decay (3 within 10 min) and promotion; critical slow `KERN_FAULT` at most once per 10 min | §1.2, §3.3.6-3.3.7 | **WP1** kern `call_in`/`charge`/perf window, spike S1 confirms the clock in game |
| R3 | Hostiles exclude `isCitizen(u, true)`/`isResident(u, true)`; new `census.h.crazed` | §6.2 | **WP5** sense.lua (the citizen test before `vis`), plus a scenario with an insane citizen inside Kern+; **WP6/WP8** may read `crazed` |
| R4 | New act `squad_leader(squad_id, unit_id)` (military, [S2]); `squad_add` only for positions ≥ 1 | §5 | **WP1** act.lua implements it (S2 confirms the UI path); **WP6** military assigns the leader before `squad_add` |
| R5 | One decisions reader per language with exact preprocessing; `contract.parse_decisions`; shared vectors | §9.16 | **WP1** kern uses `C.parse_decisions` (test_schema has an xfail that turns into XPASS); **WP4** fairplay unaffected |
| R6 | `by` is a label; `unpause` releases only the inbox hold; `audit` only from follow/test with a snapshot of this boot; hook/lint trust rules | §9.5, §13 | **WP1** kern checks `VERB_BY`, arbiter `unpause`; **WP6** readiness records `EV:SNAPSHOT_READY` ids (purpose audit) and refuses others; **WP4** hook/lint rules incl. Write/Edit; **WP2** `cmd` must not offer `audit`/`--by follow` to the LLM path (follow writes audits itself) |
| R7 | bp caps 1,000 cells / 24 KB (`schema.validate('bp')`); `bp.<id>` written once; at most one bp decode per frame | §8, §9.8, §10 | **WP3** emitters stay under the caps; **WP7** runner reads ≤ 1 bp per frame (today `plan_loads = 4`); **WP2** gets the caps through `schema.validate` |
| R8 | No permanent disable: backoff (critical 30 s, others 10 min, doubling), auto re-enable, `module.enable` verb, `KERN_FAULT.d.backoff_s` | §3.3.5, §12, §13 | **WP1** kern fault/backoff + `module.enable` handler |
| L2 | `act.link_lever` (gate links built, unlinked manifest levers in PEACE/ALERT/RECOVERY; LEVER event `link`); `squad_create` makes a captain assignment, `squad_leader` and `squad_uniform` implemented; fortcore traps are stage 4 (bridges and levers first) | §5, §9.8 | done in live slot L2 (act, gate, military, bp, plans) |
| FR51-55 | Run 9 alarm-to-action: SIEGE_START/INVASION class A; module `reflex` (arrival lockdown, interrupt channel, `<save>/alarm.txt`, verb `ack`); `act.door_forbid`; state `clock`/`alarm`/`lever`, `owners.tempo` `clock`; events ARRIVAL/INTRUDER/PREDATOR/NO_DEPOT/LOCKDOWN (A), LOCKDOWN_END (B); `contract.INTERRUPTS`; D-14 peace_gates; `config/reflex.json` | §3.4, §4, §5, §7, §8, §9.3, §9.13, §9.16, §9.18, §12, §13, §15, §18 | done (offline; live-untested) |
| FR | seal module (FR-22/24/33/37/54/56/57, 2026-10-15): reads revealed tiles and walk groups (lint role); its entrance BFS runs in game, sliced (`seal.CFG.work` units per frame) and bounded (`bfs_max` 60,000 tiles), only when walk groups show a route, because the leak must be known after a lever pull or a siege without a snapshot round trip (deviation from DESIGN §10 "no in-game BFS"); state `alert`; events CUTOFF, SEAL_LEAK, PERIMETER_BROKEN, REFUGE_FAIL (A), SEAL, REACH (B); act `burrow_tiles`; `inspect` module views; public `seal.alert_burrow/entrances/closing`, `runner.repair`; siege asks `seal.alert_burrow` for the civ-alert burrow, sense asks `seal.entrances` for wild predators | §1.4, §3.4, §5, §7, §9.3, §12, §13 | done (seal, siege, sense, runner, act, kern, k_mock, lint) |
| L1b | economy owns the builtin tool details (`act.work_detail`, event WORK_DETAIL, `runner.dig_backlog`); the `workshops` deliverable also counts built workshops; `plan.reload {phases:true}`; the runner slices the stage `orders` call (`orders_cells`) | §5, §7, §9.9, §12, §13 | done in live slot L1b (economy, act, runner, kern, lint) |

---

## Appendix A. JSON Schemas (generated)
Generated by `python -m dfpilot.schema --write-appendix docs/v2/CONTRACTS.md`; `tests/test_schema.py` fails if this block is stale. The digest covers every schema and registry in `schema.py`, so any contract change shows up here.

<!-- BEGIN GENERATED SCHEMAS -->
Contract digest: `55d1c60e46e9f08490852b260027243904d2e588a04305add8bf88708e922faa`

DESIGN §6 formats and the inbox verb args. Other kinds: `python -m dfpilot.schema --json-schema <kind>` with kind in heartbeat, phases, bp, restore, lock, allowlist, persist.marker, persist.projects, persist.plan, persist.phase, persist.mode, persist.drill, persist.kern. Per-type event `d` (§12) and per-verb `args` are checked by `validate()`; the envelopes leave them open. Compact JSON, keys sorted.

**state**
```json
{"$defs":{"id":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"},"mode":{"enum":["PEACE","ALERT","SIEGE","BREACH","RECOVERY","DRILL"],"type":"string"},"module":{"pattern":"^[a-z][a-z_]{1,15}$","type":"string"},"phase":{"pattern":"^P[0-7]$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"alarm":{"additionalProperties":false,"properties":{"ack":{"minimum":0,"type":"integer"},"defcon":{"maximum":5,"minimum":1,"type":"integer"},"doors":{"minimum":0,"type":"integer"},"dout":{"minimum":0,"type":"integer"},"dref":{"minimum":0,"type":"integer"},"dwait":{"minimum":0,"type":"integer"},"eta":{"minimum":-1,"type":"integer"},"last":{"minimum":0,"type":"integer"},"lock":{"maximum":1,"minimum":0,"type":"integer"},"unacked":{"minimum":0,"type":"integer"},"why":{"maxLength":24,"type":"string"}},"required":["defcon","unacked","last","ack","lock","why"],"type":"object"},"alert":{"additionalProperties":false,"properties":{"burrow":{"maxLength":24,"type":"string"},"inside":{"minimum":0,"type":"integer"},"ok":{"maximum":1,"minimum":0,"type":"integer"},"tiles":{"minimum":0,"type":"integer"},"want":{"maxLength":24,"type":"string"},"why":{"maxLength":40,"type":"string"}},"required":["want","burrow","tiles","inside","ok"],"type":"object"},"bridges":{"additionalProperties":{"enum":["up","down","moving","unknown"],"type":"string"},"propertyNames":{"pattern":"^[A-Z][A-Za-z0-9]{0,7}$"},"type":"object"},"care":{"additionalProperties":false,"properties":{"coffins":{"additionalProperties":false,"properties":{"order":{"minimum":0,"type":"integer"},"proj":{"maxLength":40,"type":"string"},"short":{"minimum":0,"type":"integer"},"stock":{"minimum":0,"type":"integer"},"want":{"minimum":0,"type":"integer"}},"required":["want","short","stock","order","proj"],"type":"object"},"corpses_old":{"minimum":0,"type":"integer"},"died":{"additionalProperties":{"minimum":0,"type":"integer"},"type":"object"},"ghosts":{"minimum":0,"type":"integer"},"moods":{"minimum":0,"type":"integer"},"naked":{"minimum":0,"type":"integer"},"stressed_pct":{"maximum":100,"minimum":0,"type":"integer"},"tombs_free":{"minimum":0,"type":"integer"}},"required":["stressed_pct","naked","ghosts","corpses_old","tombs_free","moods"],"type":"object"},"clock":{"additionalProperties":false,"properties":{"cap":{"minimum":0,"type":"integer"},"held":{"maximum":1,"minimum":0,"type":"integer"},"orig":{"minimum":0,"type":"integer"},"ts":{"maximum":1000,"minimum":-1,"type":"integer"},"why":{"maxLength":24,"type":"string"}},"required":["cap","orig","ts","held","why"],"type":"object"},"ev":{"minimum":0,"type":"integer"},"k":{"additionalProperties":false,"properties":{"disabled":{"items":{"$ref":"#/$defs/module"},"type":"array"},"faults":{"minimum":0,"type":"integer"},"gap_max_ms":{"minimum":0,"type":"integer"},"ms_max":{"minimum":0,"type":"integer"},"ms_s":{"minimum":0,"type":"integer"},"slow":{"items":{"$ref":"#/$defs/module"},"type":"array"}},"required":["ms_s","gap_max_ms","slow","faults"],"type":"object"},"labor":{"additionalProperties":false,"properties":{"idle":{"maximum":100,"minimum":0,"type":"integer"},"starving":{"minimum":0,"type":"integer"}},"required":["starving","idle"],"type":"object"},"lever":{"additionalProperties":false,"properties":{"lat_s":{"minimum":-1,"type":"integer"},"lat_t":{"minimum":-1,"type":"integer"},"pend":{"minimum":0,"type":"integer"},"wait_s":{"minimum":0,"type":"integer"}},"required":["lat_s","lat_t","pend","wait_s"],"type":"object"},"mil":{"additionalProperties":false,"properties":{"cv":{"minimum":0,"type":"integer"},"free":{"additionalProperties":false,"properties":{"ammo":{"minimum":0,"type":"integer"},"body":{"minimum":0,"type":"integer"},"gloves":{"minimum":0,"type":"integer"},"head":{"minimum":0,"type":"integer"},"pants":{"minimum":0,"type":"integer"},"shield":{"minimum":0,"type":"integer"},"shoes":{"minimum":0,"type":"integer"},"weapon":{"minimum":0,"type":"integer"}},"type":"object"},"metal_pct":{"maximum":100,"minimum":0,"type":"integer"},"on_station":{"minimum":0,"type":"integer"},"soldiers":{"minimum":0,"type":"integer"},"squads":{"minimum":0,"type":"integer"},"worn":{"maximum":100,"minimum":0,"type":"integer"}},"required":["squads","soldiers","worn","cv","metal_pct","on_station"],"type":"object"},"mode":{"$ref":"#/$defs/mode"},"orders":{"additionalProperties":false,"properties":{"bad":{"minimum":0,"type":"integer"},"n":{"minimum":0,"type":"integer"},"stuck":{"minimum":0,"type":"integer"}},"required":["n","bad","stuck"],"type":"object"},"owners":{"additionalProperties":false,"properties":{"pause":{"anyOf":[{"type":"null"},{"enum":["inbox","gordon","popup","df"],"type":"string"}]},"tempo":{"enum":["mode","inbox","brake","clock"],"type":"string"}},"required":["pause","tempo"],"type":"object"},"phase":{"$ref":"#/$defs/phase"},"pop":{"additionalProperties":false,"properties":{"adults":{"minimum":0,"type":"integer"},"cap":{"minimum":0,"type":"integer"},"cit":{"minimum":0,"type":"integer"},"gate_cap":{"minimum":0,"type":"integer"},"soldiers":{"minimum":0,"type":"integer"}},"type":"object"},"proj":{"items":{"items":false,"maxItems":4,"minItems":4,"prefixItems":[{"$ref":"#/$defs/id"},{"maxLength":24,"type":"string"},{"maximum":100,"minimum":0,"type":"integer"},{"maxLength":40,"type":"string"}],"type":"array"},"maxItems":8,"type":"array"},"ready":{"additionalProperties":false,"properties":{"audit":{"additionalProperties":false,"properties":{"age":{"minimum":-1,"type":"integer"},"min_traps":{"minimum":0,"type":"integer"},"ok":{"maximum":1,"minimum":0,"type":"integer"}},"required":["ok","age","min_traps"],"type":"object"},"cv":{"minimum":0,"type":"integer"},"drill_age":{"minimum":-1,"type":"integer"},"fail":{"items":{"maxLength":24,"type":"string"},"maxItems":8,"type":"array"},"lvl":{"maximum":3,"minimum":0,"type":"integer"},"worn":{"maximum":100,"minimum":0,"type":"integer"}},"required":["lvl","worn","cv","drill_age","audit","fail"],"type":"object"},"save":{"maxLength":120,"type":"string"},"seq":{"minimum":0,"type":"integer"},"stock":{"additionalProperties":false,"properties":{"drink_d":{"minimum":0,"type":"integer"},"food_d":{"minimum":0,"type":"integer"},"hosp_water":{"maximum":1,"minimum":0,"type":"integer"},"meals":{"minimum":0,"type":"integer"}},"type":"object"},"t":{"additionalProperties":false,"properties":{"abs":{"minimum":0,"type":"integer"},"frame":{"minimum":0,"type":"integer"},"paused":{"type":"boolean"},"season":{"maximum":3,"minimum":0,"type":"integer"},"tick":{"maximum":403199,"minimum":0,"type":"integer"},"tps":{"minimum":0,"type":"integer"},"wall":{"minimum":0,"type":"integer"},"y":{"minimum":0,"type":"integer"}},"required":["y","tick","season","tps","paused"],"type":"object"},"threat":{"additionalProperties":false,"properties":{"armed":{"maximum":1,"minimum":0,"type":"integer"},"vis":{"minimum":0,"type":"integer"}},"required":["vis","armed"],"type":"object"},"trade":{"additionalProperties":false,"properties":{"caravan":{"maximum":1,"minimum":0,"type":"integer"},"done":{"minimum":0,"type":"integer"},"ratio":{"minimum":0,"type":"integer"}},"required":["caravan","ratio","done"],"type":"object"},"v":{"const":2}},"required":["v","seq","t","mode","k","ev"],"title":"state","type":"object"}
```

**event**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"cls":{"enum":["A","B","C"],"type":"string"},"d":{"additionalProperties":{},"type":"object"},"msg":{"maxLength":200,"type":"string"},"n":{"minimum":0,"type":"integer"},"tick":{"minimum":0,"type":"integer"},"type":{"pattern":"^[A-Z][A-Z0-9_]{1,31}$","type":"string"}},"required":["n","tick","type","cls","msg","d"],"title":"event","type":"object"}
```

**inbox**
```json
{"$defs":{"id":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"args":{"additionalProperties":{},"type":"object"},"by":{"enum":["llm","gordon","cli","follow","supervise","test"],"type":"string"},"id":{"$ref":"#/$defs/id"},"ts":{"minimum":0,"type":"integer"},"verb":{"enum":["plan.reload","bp.place","bp.cancel","drill","snapshot","audit","popcap.lower","tempo.lower","pause","unpause","trade.want","squad.sortie","lever","inspect","selftest","module.enable","tombs.repair","ack","order.add","jobs.release","perimeter.record"],"type":"string"}},"required":["id","verb","args","by"],"title":"inbox","type":"object"}
```

**outbox**
```json
{"$defs":{"id":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"data":{"additionalProperties":{},"type":"object"},"id":{"$ref":"#/$defs/id"},"msg":{"maxLength":300,"type":"string"},"ok":{"type":"boolean"},"tick":{"minimum":0,"type":"integer"},"verb":{"maxLength":40,"type":"string"}},"required":["id","ok","msg"],"title":"outbox","type":"object"}
```

**plan**
```json
{"$defs":{"phase":{"pattern":"^P[0-7]$","type":"string"},"scalar":{"anyOf":[{"type":"integer"},{"maxLength":200,"type":"string"},{"type":"boolean"}]},"token":{"pattern":"^[a-z_]+(:[a-z_]+)?$","type":"string"},"tpl":{"pattern":"^[a-z][a-z0-9_]{1,31}$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"military":{"additionalProperties":false,"properties":{"cv_min":{"maximum":200,"minimum":0,"type":"integer"},"pct":{"maximum":50,"minimum":0,"type":"integer"},"squads":{"additionalProperties":false,"properties":{"melee":{"maximum":4,"minimum":0,"type":"integer"},"xbow":{"maximum":2,"minimum":0,"type":"integer"}},"required":["melee","xbow"],"type":"object"}},"required":["pct","squads","cv_min"],"type":"object"},"notes":{"maxLength":2000,"type":"string"},"orders":{"additionalProperties":false,"properties":{"import":{"items":{"enum":["library/basic","library/furnace","library/smelting","library/military","library/rockstock","library/glassstock"],"type":"string"},"maxItems":6,"type":"array"}},"required":["import"],"type":"object"},"phase_target":{"$ref":"#/$defs/phase"},"policy":{"additionalProperties":false,"properties":{"beauty":{"enum":["none","used_rooms"],"type":"string"},"option":{"enum":["A","B"],"type":"string"},"pop_ceiling":{"maximum":250,"minimum":0,"type":"integer"}},"required":["option","pop_ceiling","beauty"],"type":"object"},"seasons":{"items":{"additionalProperties":false,"properties":{"build":{"items":{"additionalProperties":false,"properties":{"p":{"additionalProperties":{"$ref":"#/$defs/scalar"},"type":"object"},"prio":{"maximum":7,"minimum":1,"type":"integer"},"site":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"},"tpl":{"$ref":"#/$defs/tpl"}},"required":["tpl","site"],"type":"object"},"maxItems":20,"type":"array"},"notes":{"maxLength":500,"type":"string"},"orders":{"additionalProperties":false,"properties":{"import":{"items":{"enum":["library/basic","library/furnace","library/smelting","library/military","library/rockstock","library/glassstock"],"type":"string"},"maxItems":6,"type":"array"}},"required":["import"],"type":"object"}},"required":["build"],"type":"object"},"maxItems":4,"minItems":4,"type":"array"},"supply":{"additionalProperties":false,"properties":{"drink_d":{"minimum":0,"type":"integer"},"food_d":{"minimum":0,"type":"integer"},"mood_stock":{"minimum":0,"type":"integer"}},"required":["drink_d","food_d","mood_stock"],"type":"object"},"trade":{"additionalProperties":false,"properties":{"sell":{"items":{"$ref":"#/$defs/token"},"maxItems":40,"type":"array"},"want":{"items":{"$ref":"#/$defs/token"},"maxItems":40,"type":"array"}},"required":["want","sell"],"type":"object"},"v":{"const":2},"year":{"minimum":0,"type":"integer"}},"required":["v","year","policy","phase_target","seasons"],"title":"plan","type":"object"}
```

**manifest**
```json
{"$defs":{"bbox":{"description":"[x0,y0,z0,x1,y1,z1] inclusive","items":false,"maxItems":6,"minItems":6,"prefixItems":[{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"}],"type":"array"},"id":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"},"pos":{"items":false,"maxItems":3,"minItems":3,"prefixItems":[{"type":"integer"},{"type":"integer"},{"type":"integer"}],"type":"array"},"tpl":{"pattern":"^[a-z][a-z0-9_]{1,31}$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"bridges":{"additionalProperties":{"additionalProperties":false,"description":"bridge footprint on one z","properties":{"fp":{"$ref":"#/$defs/bbox"},"levers":{"items":{"$ref":"#/$defs/pos"},"maxItems":4,"minItems":1,"type":"array"},"role":{"enum":["outer","inner","core"],"type":"string"}},"required":["role","fp","levers"],"type":"object"},"propertyNames":{"pattern":"^[A-Z][A-Za-z0-9]{0,7}$"},"type":"object"},"burrows":{"additionalProperties":{"additionalProperties":false,"properties":{"role":{"enum":["kern","refuge","other"],"type":"string"}},"required":["role"],"type":"object"},"propertyNames":{"pattern":"^.{1,40}$"},"type":"object"},"depot":{"$ref":"#/$defs/pos"},"edge":{"items":{"$ref":"#/$defs/pos"},"maxItems":200,"type":"array"},"killboxes":{"items":{"additionalProperties":false,"properties":{"bbox":{"$ref":"#/$defs/bbox"},"id":{"$ref":"#/$defs/id"}},"required":["id","bbox"],"type":"object"},"maxItems":20,"type":"array"},"pit":{"$ref":"#/$defs/pos"},"refuge":{"additionalProperties":false,"properties":{"anchor":{"$ref":"#/$defs/pos"},"burrow":{"maxLength":40,"type":"string"}},"required":["anchor","burrow"],"type":"object"},"rooms":{"items":{"additionalProperties":false,"properties":{"bbox":{"$ref":"#/$defs/bbox"},"id":{"$ref":"#/$defs/id"},"tier":{"minimum":0,"type":"integer"},"tpl":{"$ref":"#/$defs/tpl"},"use":{"enum":["used","utility"],"type":"string"}},"required":["id","tpl","use","bbox","tier"],"type":"object"},"maxItems":200,"type":"array"},"stairs":{"additionalProperties":false,"properties":{"civ":{"items":{"items":false,"maxItems":4,"minItems":4,"prefixItems":[{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"}],"type":"array"},"maxItems":8,"type":"array"},"mil":{"items":{"items":false,"maxItems":4,"minItems":4,"prefixItems":[{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"}],"type":"array"},"maxItems":8,"type":"array"}},"type":"object"},"stations":{"additionalProperties":false,"properties":{"b2":{"$ref":"#/$defs/pos"},"gallery":{"$ref":"#/$defs/pos"},"melee":{"$ref":"#/$defs/pos"}},"type":"object"},"v":{"const":2},"workshops":{"items":{"additionalProperties":false,"properties":{"pos":{"$ref":"#/$defs/pos"},"type":{"maxLength":40,"type":"string"}},"required":["type","pos"],"type":"object"},"maxItems":100,"type":"array"},"zones":{"additionalProperties":false,"properties":{"Z1":{"items":{"$ref":"#/$defs/bbox"},"maxItems":50,"type":"array"},"Z2":{"items":{"$ref":"#/$defs/bbox"},"maxItems":50,"type":"array"},"Z3":{"items":{"$ref":"#/$defs/bbox"},"maxItems":50,"type":"array"},"Z4":{"items":{"$ref":"#/$defs/bbox"},"maxItems":50,"type":"array"}},"type":"object"}},"required":["v"],"title":"manifest","type":"object"}
```

**snapshot**
```json
{"$defs":{"bbox":{"description":"[x0,y0,z0,x1,y1,z1] inclusive","items":false,"maxItems":6,"minItems":6,"prefixItems":[{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"}],"type":"array"},"id":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"},"pos":{"items":false,"maxItems":3,"minItems":3,"prefixItems":[{"type":"integer"},{"type":"integer"},{"type":"integer"}],"type":"array"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"bbox":{"$ref":"#/$defs/bbox"},"bridges":{"additionalProperties":{"enum":["up","down","moving","unknown"],"type":"string"},"propertyNames":{"pattern":"^[A-Z][A-Za-z0-9]{0,7}$"},"type":"object"},"id":{"$ref":"#/$defs/id"},"marks":{"additionalProperties":{"items":{"$ref":"#/$defs/pos"},"maxItems":500,"type":"array"},"propertyNames":{"pattern":"^[a-z_]{1,20}$"},"type":"object"},"purpose":{"enum":["audit","sites","debug"],"type":"string"},"rows":{"additionalProperties":{"items":{"pattern":"^[?_.#SCF<>Xrv+=H\\^Bw~%T]*$","type":"string"},"type":"array"},"propertyNames":{"pattern":"^z-?\\d+$"},"type":"object"},"tick":{"minimum":0,"type":"integer"},"traps":{"items":{"items":false,"maxItems":6,"minItems":5,"prefixItems":[{"type":"integer"},{"type":"integer"},{"type":"integer"},{"enum":["W","S","C","P","X"],"type":"string"},{"minimum":0,"type":"integer"},{"maximum":1,"minimum":0,"type":"integer"}],"type":"array"},"type":"array"},"v":{"const":2}},"required":["v","id","tick","purpose","bbox","rows","bridges","traps"],"title":"snapshot","type":"object"}
```

**inbox.args.plan.reload**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"phases":{"type":"boolean"}},"title":"inbox.args.plan.reload","type":"object"}
```

**inbox.args.bp.place**
```json
{"$defs":{"scalar":{"anyOf":[{"type":"integer"},{"maxLength":200,"type":"string"},{"type":"boolean"}]},"tpl":{"pattern":"^[a-z][a-z0-9_]{1,31}$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":{"$ref":"#/$defs/scalar"},"properties":{"p":{"additionalProperties":{"$ref":"#/$defs/scalar"},"type":"object"},"prio":{"maximum":7,"minimum":1,"type":"integer"},"site":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"},"tpl":{"$ref":"#/$defs/tpl"}},"required":["tpl","site"],"title":"inbox.args.bp.place","type":"object"}
```

**inbox.args.bp.cancel**
```json
{"$defs":{"id":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"proj":{"$ref":"#/$defs/id"},"undo":{"type":"boolean"}},"required":["proj"],"title":"inbox.args.bp.cancel","type":"object"}
```

**inbox.args.drill**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"why":{"maxLength":200,"type":"string"}},"title":"inbox.args.drill","type":"object"}
```

**inbox.args.snapshot**
```json
{"$defs":{"bbox":{"description":"[x0,y0,z0,x1,y1,z1] inclusive","items":false,"maxItems":6,"minItems":6,"prefixItems":[{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"},{"type":"integer"}],"type":"array"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"bbox":{"$ref":"#/$defs/bbox"},"purpose":{"enum":["audit","sites","debug"],"type":"string"}},"title":"inbox.args.snapshot","type":"object"}
```

**inbox.args.audit**
```json
{"$defs":{"id":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"bypass":{"type":"boolean"},"caverns":{"type":"boolean"},"civ_sep":{"type":"boolean"},"fails":{"items":{"maxLength":80,"type":"string"},"maxItems":50,"type":"array"},"min_traps":{"minimum":0,"type":"integer"},"ok":{"type":"boolean"},"refuge_sep":{"type":"boolean"},"snap":{"$ref":"#/$defs/id"}},"required":["snap","ok","fails","min_traps","bypass","refuge_sep","civ_sep","caverns"],"title":"inbox.args.audit","type":"object"}
```

**inbox.args.popcap.lower**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"cap":{"maximum":250,"minimum":0,"type":"integer"}},"required":["cap"],"title":"inbox.args.popcap.lower","type":"object"}
```

**inbox.args.tempo.lower**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"fps":{"maximum":1000,"minimum":10,"type":"integer"},"ttl_s":{"maximum":3600,"minimum":1,"type":"integer"}},"required":["fps","ttl_s"],"title":"inbox.args.tempo.lower","type":"object"}
```

**inbox.args.pause**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"ttl_s":{"maximum":600,"minimum":1,"type":"integer"},"why":{"maxLength":200,"type":"string"}},"required":["ttl_s"],"title":"inbox.args.pause","type":"object"}
```

**inbox.args.unpause**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"title":"inbox.args.unpause","type":"object"}
```

**inbox.args.trade.want**
```json
{"$defs":{"token":{"pattern":"^[a-z_]+(:[a-z_]+)?$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"sell":{"items":{"$ref":"#/$defs/token"},"maxItems":40,"type":"array"},"want":{"items":{"$ref":"#/$defs/token"},"maxItems":40,"type":"array"}},"title":"inbox.args.trade.want","type":"object"}
```

**inbox.args.squad.sortie**
```json
{"$defs":{"id":{"pattern":"^[A-Za-z0-9_-]{1,40}$","type":"string"},"pos":{"items":false,"maxItems":3,"minItems":3,"prefixItems":[{"type":"integer"},{"type":"integer"},{"type":"integer"}],"type":"array"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"approve":{"const":true},"squad":{"enum":["A","B","C"],"type":"string"},"target":{"anyOf":[{"$ref":"#/$defs/id"},{"$ref":"#/$defs/pos"}]}},"required":["squad","target","approve"],"title":"inbox.args.squad.sortie","type":"object"}
```

**inbox.args.lever**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"bridge":{"pattern":"^[A-Z][A-Za-z0-9]{0,7}$","type":"string"},"want":{"enum":["up","down"],"type":"string"}},"required":["bridge","want"],"title":"inbox.args.lever","type":"object"}
```

**inbox.args.inspect**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"key":{"maxLength":80,"type":"string"},"what":{"enum":["state","modules","census","manifest","projects","persist","perf","mode","plan","tombs","water_sources","orders","workload","trade","reach","entrances","defense","perimeter","refuge"],"type":"string"}},"required":["what"],"title":"inbox.args.inspect","type":"object"}
```

**inbox.args.selftest**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"suite":{"enum":["quick","full"],"type":"string"}},"title":"inbox.args.selftest","type":"object"}
```

**inbox.args.module.enable**
```json
{"$defs":{"module":{"pattern":"^[a-z][a-z_]{1,15}$","type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"module":{"$ref":"#/$defs/module"}},"required":["module"],"title":"inbox.args.module.enable","type":"object"}
```

**inbox.args.tombs.repair**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"title":"inbox.args.tombs.repair","type":"object"}
```

**inbox.args.ack**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"n":{"minimum":0,"type":"integer"}},"title":"inbox.args.ack","type":"object"}
```

**inbox.args.order.add**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"description":"item-definition jobs need item_subtype (FR-39)","properties":{"amount":{"maximum":999,"minimum":1,"type":"integer"},"frequency":{"enum":["OneTime","Daily","Monthly","Seasonally","Yearly"],"type":"string"},"item_subtype":{"pattern":"^ITEM_[A-Z0-9_]{1,60}$","type":"string"},"job":{"pattern":"^[A-Za-z]{2,40}$","type":"string"},"material":{"pattern":"^[A-Z0-9_:]{1,80}$","type":"string"},"material_category":{"items":{"pattern":"^[a-z0-9_]{1,20}$","type":"string"},"maxItems":8,"minItems":1,"type":"array"},"reaction":{"pattern":"^[A-Z0-9_]{1,60}$","type":"string"}},"required":["job","amount"],"title":"inbox.args.order.add","type":"object"}
```

**inbox.args.jobs.release**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"properties":{"all":{"type":"boolean"},"preventblocking":{"type":"boolean"}},"title":"inbox.args.jobs.release","type":"object"}
```

**inbox.args.perimeter.record**
```json
{"$schema":"https://json-schema.org/draft/2020-12/schema","additionalProperties":false,"title":"inbox.args.perimeter.record","type":"object"}
```
<!-- END GENERATED SCHEMAS -->
