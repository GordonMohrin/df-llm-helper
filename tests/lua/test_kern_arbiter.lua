-- WP1 arbiter: runtime profile + restore.json, tempo by mode (idempotent), inbox tempo/pause holds,
-- honoured foreign pauses, whitelisted popups, crash healing (also on unmarked saves).
local T = require('testlib')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')
local arbiter = require('dfllm.arbiter')
arbiter.PROFILE.overlays = true   -- these tests cover the headless overlay profile (live default since L6: overlays stay, Gordon watches)

local function ts_cmds(W)
  local r = {}
  for _, c in ipairs(W.commands) do if c[1] == 'timestream' then r[#r + 1] = c[4] end end
  return r
end

local function boot(W, extra)
  local mods = {arbiter}
  for _, m in ipairs(extra or {}) do mods[#mods + 1] = m end
  local ok, msg = H.boot(W, {modules = mods})
  assert(ok, msg)
  return kern.K()
end

T.test('boot: originals written to restore.json before the profile is applied; unload restores them', function()
  local W = H.world{tag = 'profile'}
  local g = df.global
  boot(W)
  local r = H.json(W.rt .. '/restore.json')
  T.eq({r.v, r.save, r.active}, {2, 'region1', 1})
  T.eq(r.orig, {gfps = 250, fps_cap = 250, autosave = 'SEASONAL', population_cap = 75, timestream_fps = 250,
                overlays = {['hotkeys.menu'] = true, ['unsuspend.overlay'] = true}})
  T.eq({g.enabler.gfps, g.d_init.feature.autosave, W.ts_fps}, {30, df.d_init_autosave.YEARLY, 500})
  T.eq({W.ov['hotkeys.menu'].enabled, W.ov['unsuspend.overlay'].enabled, W.ov['notify.panel'].enabled}, {false, false, true})
  T.eq(g.d_init.dwarf.visitor_cap, 300, 'D-07 default: unchanged')
  g.d_init.dwarf.population_cap = 55     -- pop-control wrote the global cap meanwhile
  kern.stop()
  T.eq({g.enabler.gfps, g.d_init.feature.autosave, g.d_init.dwarf.population_cap, W.ts_fps},
       {250, df.d_init_autosave.SEASONAL, 75, 250})
  T.eq({W.ov['hotkeys.menu'].enabled, W.ov['unsuspend.overlay'].enabled, W.ov['spare.widget'].enabled}, {true, true, false})
  T.eq(H.json(W.rt .. '/restore.json').active, 0)
  T.eq(json.decode(W.persist_raw['dfllm.restore']).active, 0, 'mirrored in persist')
end)

T.test('population cap original: getBaseDir prefs, then install prefs, then memory (source logged)', function()
  -- Steam, not portable: the live prefs are in getBaseDir() (%APPDATA%/Bay 12 Games/Dwarf Fortress\),
  -- the install folder holds a stale copy
  local W = H.world{tag = 'prefs'}
  local appdata = W.dir .. '/appdata'
  luahost.mkdir_recursive(appdata .. '/prefs')
  luahost.mkdir_recursive(W.dir .. '/prefs')
  H.write(appdata .. '/prefs/d_init.txt', '[AUTOSAVE:YEARLY]\r\n[POPULATION_CAP:90]\r\n[STRICT_POPULATION_CAP:120]\r\n')
  H.write(W.dir .. '/prefs/d_init.txt', '[AUTOSAVE:SEASONAL]\r\n[POPULATION_CAP:75]\r\n[STRICT_POPULATION_CAP:100]\r\n')
  dfhack.filesystem.getBaseDir = function() return appdata .. '\\' end
  df.global.d_init.dwarf.population_cap = 55          -- this fort's pop-control value
  boot(W)
  T.eq(H.json(W.rt .. '/restore.json').orig.population_cap, 90)
  kern.stop()
  T.eq(df.global.d_init.dwarf.population_cap, 90)
  T.ok(H.read(W.sd .. '/kern.log'):find('population cap original 90 from base dir ' .. appdata .. '/prefs/d_init.txt', 1, true))
  -- no base-dir prefs file: the install folder's
  os.remove(appdata .. '/prefs/d_init.txt')
  df.global.d_init.dwarf.population_cap = 55
  boot(W)
  T.eq(H.json(W.rt .. '/restore.json').orig.population_cap, 75)
  kern.stop()
  -- neither (and no getBaseDir): the value in memory
  os.remove(W.dir .. '/prefs/d_init.txt')
  dfhack.filesystem.getBaseDir = nil
  df.global.d_init.dwarf.population_cap = 61
  boot(W)
  T.eq(H.json(W.rt .. '/restore.json').orig.population_cap, 61)
  kern.stop()
  T.ok(H.read(W.sd .. '/kern.log'):find('population cap original 61 from memory', 1, true))
end)

T.test("timestream original is the save's own (persisted at its first boot), not our mode value", function()
  -- timestream persists its fps in the save, so a later boot finds our 500; the save's restore mirror wins
  local W = H.world{tag = 'tsorig', ts_fps = 500,
                    persist = {restore = {v = 2, save = 'region1', wall = 1, active = 1, orig = {timestream_fps = 120}}}}
  boot(W)
  T.eq(H.json(W.rt .. '/restore.json').orig.timestream_fps, 120)
  T.eq(W.ts_fps, 500)
  kern.stop()
  T.eq(W.ts_fps, 120)
end)

T.test('D-07 visitor answer: visitor cap 30 and restored', function()
  local W = H.world{tag = 'd07'}
  luahost.mkdir_recursive(W.dir .. '/config')
  H.write(W.dir .. '/config/decisions.yaml', 'D-07: visitor   # Gordon 2026-10-10\nD-01: A\n')
  boot(W)
  T.eq(df.global.d_init.dwarf.visitor_cap, 30)
  T.eq(kern.K().cfg.decisions['D-07'], 'visitor')
  kern.stop()
  T.eq(df.global.d_init.dwarf.visitor_cap, 300)
end)

T.test('tempo follows the mode in the same call (on.MODE), writes only on change', function()
  local W = H.world{tag = 'tempo'}
  local K = boot(W)
  T.eq(ts_cmds(W), {'500'})
  H.run(W, 300)                          -- ~5 s: no re-writes
  T.eq(ts_cmds(W), {'500'})
  K.set_mode('ALERT', 'test')
  -- FR-51: ALERT caps the vanilla FPS at 100; timestream 250 would skip ticks past that cap, so it is off
  T.eq({W.ts_fps, math.floor(df.global.enabler.fps)}, {-1, 100})
  K.set_mode('SIEGE', 'test')
  T.eq({W.ts_fps, math.floor(df.global.enabler.fps)}, {-1, 30})
  H.run(W, 300)
  T.eq(ts_cmds(W), {'500', '-1'})
  K.set_mode('RECOVERY', 'test')
  T.eq(math.floor(df.global.enabler.fps), 250, 'RECOVERY: the captured original cap')
  K.set_mode('PEACE', 'test')
  T.eq(ts_cmds(W), {'500', '-1', '250', '500'})
  W.ts_fps = 100                         -- someone else changed it: re-asserted within 60 s
  H.run(W, 4000, {ms = 20})
  T.eq(W.ts_fps, 500)
  kern.stop()
end)

T.test('D-11 not accepted: timestream is never touched', function()
  local W = H.world{tag = 'd11'}
  luahost.mkdir_recursive(W.dir .. '/config')
  H.write(W.dir .. '/config/decisions.yaml', 'D-11: rejected\n')
  local K = boot(W)
  K.set_mode('SIEGE', 'x')
  H.run(W, 100)
  T.eq(ts_cmds(W), {})
  T.eq(W.ts_fps, 250)
  kern.stop()
  T.eq(ts_cmds(W), {}, 'nothing to restore either')
end)

T.test('tempo.lower: lowers below the mode value for its TTL, never above, owners.tempo', function()
  local W = H.world{tag = 'tlower', ms_per_frame = 100}
  local K = boot(W)
  H.inbox(W, 't1', 'tempo.lower', {fps = 300, ttl_s = 3})
  H.run(W, 2)
  T.eq(H.outbox(W, 't1').msg, 'tempo 300 for 3 s (FPS cap 250)')
  T.eq(W.ts_fps, 300)
  K.flush(); H.frame(W, 1)
  T.eq(H.state(W).owners, {pause = nil, tempo = 'inbox'})
  T.eq(json.decode(H.read(W.sd .. '/state.' .. (H.state(W).seq % 2 == 1 and 'a' or 'b') .. '.json')).owners.tempo, 'inbox')
  H.run(W, 35)
  T.eq(W.ts_fps, 500, 'TTL expired')
  H.inbox(W, 't2', 'tempo.lower', {fps = 900, ttl_s = 60})
  H.run(W, 6)
  T.eq(W.ts_fps, 500, 'never above the mode value')
  K.set_mode('SIEGE', 'x')
  H.inbox(W, 't3', 'tempo.lower', {fps = 100, ttl_s = 60})
  H.run(W, 6)
  T.eq(W.ts_fps, -1)
  T.ok(H.outbox(W, 't3').msg:find('off in SIEGE'))
  T.eq(math.floor(df.global.enabler.fps), 30, 'the siege cap stays below the inbox value')
  H.inbox(W, 't3b', 'tempo.lower', {fps = 20, ttl_s = 60})
  H.run(W, 6)
  T.eq(math.floor(df.global.enabler.fps), 20, 'STATUS §6 gap 10: tempo.lower lowers the FPS cap too')
  H.inbox(W, 't4', 'tempo.lower', {fps = 5, ttl_s = 60})
  H.run(W, 6)
  T.eq(H.outbox(W, 't4').ok, false)
  kern.stop()
end)

T.test('inbox pause: held for its TTL, then released; PAUSE events; owners.pause', function()
  local W = H.world{tag = 'ipause', ms_per_frame = 100}
  local K = boot(W)
  H.inbox(W, 'p1', 'pause', {ttl_s = 2, why = 'inspect'})
  H.run(W, 2)
  T.eq(H.outbox(W, 'p1').msg, 'paused for 2 s')
  T.eq(df.global.pause_state, true)
  K.flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, 'inbox')
  H.run(W, 25, {paused = true})
  T.eq(df.global.pause_state, false, 'released at TTL')
  kern.stop()
  local p = H.find(H.events(W), 'PAUSE')
  T.eq({p[1].d.on, p[1].d.by, p[1].d.ttl}, {1, 'inbox', 2})
  T.eq({p[#p].d.on, p[#p].d.by}, {0, 'inbox'})
end)

T.test('a pause taken during an inbox hold is foreign: the TTL never unpauses it', function()
  local W = H.world{tag = 'holdsteal', ms_per_frame = 100}
  boot(W)
  H.inbox(W, 'p1', 'pause', {ttl_s = 3})
  H.run(W, 2, {paused = true})
  T.eq(df.global.pause_state, true)
  df.global.pause_state = false          -- Gordon unpauses ...
  H.run(W, 6)
  df.global.pause_state = true           -- ... and pauses again himself
  H.run(W, 60, {paused = true})          -- well past the TTL
  T.eq(df.global.pause_state, true)
  kern.K().flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, 'gordon')
  H.inbox(W, 'p2', 'pause', {ttl_s = 3})
  H.run(W, 6, {paused = true})
  T.eq(H.outbox(W, 'p2').msg, 'already paused by gordon')
  df.global.pause_state = false
  kern.stop()
end)

T.test("Gordon's pause is honoured: no unpause, one DECISION_NEEDED after 10 min, no inbox release (R6)", function()
  local W = H.world{tag = 'gpause', ms_per_frame = 1000}
  boot(W)
  H.run(W, 3)
  df.global.pause_state = true
  H.run(W, 700, {paused = true})        -- 11+ min
  T.eq(df.global.pause_state, true)
  H.inbox(W, 'u1', 'unpause', {}, 'llm')
  H.run(W, 2, {paused = true})
  T.eq(H.outbox(W, 'u1').ok, false)
  T.eq(df.global.pause_state, true)
  H.inbox(W, 'u2', 'unpause', {}, 'gordon')   -- `by` is a label: grants nothing (CONTRACTS §9.5)
  H.run(W, 2, {paused = true})
  T.eq(H.outbox(W, 'u2').ok, false)
  T.eq(df.global.pause_state, true)
  df.global.pause_state = false               -- Gordon unpauses in DF
  H.run(W, 2)
  kern.K().flush(); H.frame(W, 1)
  T.eq(H.state(W).owners.pause, nil)          -- null (decoded: absent)
  kern.stop()
  local dn = H.find(H.events(W), 'DECISION_NEEDED')
  T.eq(#dn, 1)
  T.eq({dn[1].cls, dn[1].d.id}, {'A', 'pause'})
  T.eq(H.find(H.events(W), 'PAUSE')[1].d.by, 'gordon')
end)

T.test('a save loaded paused belongs to df: the inbox cannot release it, the inbox hold it can (R6)', function()
  local W = H.world{tag = 'dfpause'}
  df.global.pause_state = true
  boot(W)
  kern.K().flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, 'df')
  H.inbox(W, 'u1', 'unpause', {}, 'llm')
  H.run(W, 40, {paused = true})
  T.eq(H.outbox(W, 'u1').ok, false)
  T.eq(df.global.pause_state, true)
  df.global.pause_state = false                -- unpaused in DF
  H.run(W, 40)
  H.inbox(W, 'p1', 'pause', {ttl_s = 60}, 'llm')
  H.run(W, 40)
  kern.K().flush(); H.frame(W, 0)
  T.eq({df.global.pause_state, H.state(W).owners.pause}, {true, 'inbox'})
  H.inbox(W, 'u2', 'unpause', {}, 'llm')
  H.run(W, 40, {paused = true})
  T.eq(H.outbox(W, 'u2').msg, 'unpaused')
  T.eq(df.global.pause_state, false)
  kern.stop()
end)

T.test('popups: whitelisted kinds are dismissed and unpaused, others stay (owner popup)', function()
  local W = H.world{tag = 'popup', ms_per_frame = 100}
  boot(W)
  local saved = arbiter.POPUPS
  arbiter.POPUPS = {tutorial = {'Welcome to'}}
  local popups = df.global.world.status.popups
  popups:insert('#', {text = 'Welcome to the fortress'})
  df.global.pause_state = true
  H.run(W, 6, {paused = true})
  T.eq(#popups, 0)
  T.eq(df.global.pause_state, false)
  popups:insert('#', {text = 'The dwarves have found something unusual.'})
  df.global.pause_state = true
  H.run(W, 6, {paused = true})
  T.eq({#popups, df.global.pause_state}, {1, true})
  kern.K().flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, 'popup')
  arbiter.POPUPS = saved
  df.global.pause_state = false
  kern.stop()
end)

T.test('popups (live L0): a popup halts the game with pause_state false; migrants are cleared', function()
  local W = H.world{tag = 'popup2', ms_per_frame = 100}
  boot(W)
  local popups = df.global.world.status.popups
  df.global.pause_state = false
  popups:insert('#', {text = 'Some migrants have arrived.'})
  H.run(W, 6, {paused = false})
  T.eq(#popups, 0, 'the shipped whitelist clears the migrants popup')
  T.eq(df.global.pause_state, false)
  popups:insert('#', {text = 'Merchants have arrived and are unloading their goods.'})   -- live L1b
  H.run(W, 6, {paused = false})
  T.eq(#popups, 0, 'matched without regard to case')
  popups:insert('#', {text = 'A human caravan from Muboomon has arrived.  Overall trade sentiments are cautious.'})
  H.run(W, 6, {paused = false})
  T.eq(#popups, 0, 'a human caravan notice does not halt the fort (live L4)')
  popups:insert('#', {text = 'Atir Adilthabum, Herbalist is throwing a tantrum!'})   -- live L1b
  H.run(W, 6, {paused = false})
  T.eq(#popups, 0, 'a tantrum notice does not halt the fort')
  popups:insert('#', {text = "Atir Kemsoroltar has claimed a Stoneworker's Workshop."})   -- live L1b
  H.run(W, 6, {paused = false})
  T.eq(#popups, 0, 'mood notices do not halt the fort')
  popups:insert('#', {text = 'Meng Iddodok, Stoneworker has bled to death.'})   -- live L2
  H.run(W, 6, {paused = false})
  T.eq(#popups, 0, 'death notices do not halt the fort (care records deaths)')
  popups:insert('#', {text = 'Atir Wallgulf has assumed the position of expedition leader of The Turquoise Whips.'})
  H.run(W, 6, {paused = false})
  T.eq(#popups, 0, 'succession notices do not halt the fort (live L2)')
  popups:insert('#', {text = 'Libash Gebkosoth, Herbalist has gone stark raving mad!'})
  H.run(W, 6, {paused = false})
  T.eq(#popups, 0, 'a failed mood notice does not halt the fort (care reports MOOD_END)')
  popups:insert('#', {text = 'Sodel Stagshilfikod, Dwarven Child has gone berserk!'})    -- live L2/L3
  H.run(W, 6, {paused = false})
  T.eq(#popups, 0, 'a berserk notice no longer halts the fort (live L3)')
  local woke = {}
  for _, e in ipairs(H.events(W)) do if e.type == 'DECISION_NEEDED' and e.d.id == 'berserk' then woke[#woke + 1] = e end end
  T.eq(#woke, 1, 'it wakes the LLM instead')
  T.eq(woke[1].cls, 'A')
  popups:insert('#', {text = 'The dwarves have found something unusual.'})
  H.run(W, 6, {paused = false})
  T.eq(#popups, 1, 'unknown popups stay for Gordon')
  kern.K().flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, 'popup', 'a popup without pause_state still owns the pause')
  popups:erase(0)
  H.run(W, 6, {paused = false})
  kern.K().flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, nil)
  kern.stop()
end)

T.test('crash heal on an unmarked save: only globals still at our profile value + overlays; ts and pop cap untouched', function()
  local W = H.world{tag = 'heal', marker = false}
  luahost.mkdir_recursive(W.rt)
  H.write(W.rt .. '/restore.json', json.encode({v = 2, save = 'region7', wall = 1, active = 1,
    orig = {gfps = 111, autosave = 'NONE', population_cap = 80, timestream_fps = 100, overlays = {['hotkeys.menu'] = true}}}))
  H.write(W.rt .. '/ACTIVE', 'region7')
  local g = df.global
  -- gfps is still our profile value (same process); autosave was reloaded from prefs (SEASONAL);
  -- timestream (this save's own site data) and the pop cap (this fort's pop-control) must stay
  g.enabler.gfps, W.ov['hotkeys.menu'].enabled = 30, false
  g.d_init.dwarf.population_cap = 66
  local ok = H.boot(W, {modules = {arbiter}})
  T.eq(ok, false)
  T.eq({g.enabler.gfps, g.d_init.feature.autosave, g.d_init.dwarf.population_cap, W.ts_fps, W.ov['hotkeys.menu'].enabled},
       {111, df.d_init_autosave.SEASONAL, 66, 250, true})
  T.eq(ts_cmds(W), {}, 'no timestream write into this save')
  T.eq(H.json(W.rt .. '/restore.json').active, 0)
  T.ok(H.read(W.rt .. '/kern.log'):find('restored gfps,overlays; left autosave,timestream_fps,population_cap', 1, true))
  T.eq(luahost.isdir(W.sd), false, 'no save folder for an unmarked save')
  T.eq(next(W.persist_raw), nil, 'persist untouched')
  T.eq(luahost.isfile(W.rt .. '/ACTIVE'), false, 'stale ACTIVE removed')
  T.ok(H.read(W.rt .. '/commands.log'):find('act.setting', 1, true), 'heal logged in the runtime root')
  T.eq(W.repeats, nil)
  -- nothing to do the second time
  g.enabler.gfps = 30
  H.boot(W, {modules = {arbiter}})
  T.eq(g.enabler.gfps, 30)
end)

T.test('crash heal on another marked save: globals healed before the new capture, per-save values not', function()
  local W = H.world{tag = 'heal2'}
  luahost.mkdir_recursive(W.rt)
  H.write(W.rt .. '/restore.json', json.encode({v = 2, save = 'other', wall = 1, active = 1,
                                                orig = {gfps = 200, timestream_fps = 100, population_cap = 80}}))
  df.global.enabler.gfps = 30
  boot(W)
  local r = H.json(W.rt .. '/restore.json')
  T.eq({r.save, r.active, r.orig.gfps, r.orig.timestream_fps, r.orig.population_cap}, {'region1', 1, 200, 250, 75})
  T.eq(ts_cmds(W), {'500'}, "the other save's timestream value is never written here")
  T.eq(df.global.enabler.gfps, 30)
  kern.stop()
  T.eq({df.global.enabler.gfps, W.ts_fps}, {200, 250})
end)

T.test('crash heal on the same marked save: timestream restored, pop cap original carried (not written)', function()
  local W = H.world{tag = 'heal3', ts_fps = 500}      -- the save persisted our PEACE value
  luahost.mkdir_recursive(W.rt)
  H.write(W.rt .. '/restore.json', json.encode({v = 2, save = 'region1', wall = 1, active = 1,
                                                orig = {gfps = 200, timestream_fps = 100, population_cap = 66}}))
  df.global.d_init.dwarf.population_cap = 52           -- pop-control's value for this fort
  boot(W)
  T.eq(ts_cmds(W), {'100', '500'}, 'original first, then the mode value')
  T.eq(df.global.d_init.dwarf.population_cap, 52, "heal does not overwrite pop-control's cap")
  local r = H.json(W.rt .. '/restore.json')
  T.eq({r.active, r.orig.timestream_fps, r.orig.population_cap}, {1, 100, 66}, 'no prefs file: carried original')
  kern.stop()
  T.eq({W.ts_fps, df.global.d_init.dwarf.population_cap}, {100, 66})
end)

T.test('dfllm restore heals without booting', function()
  local W = H.world{tag = 'restorecmd', marker = false}
  luahost.mkdir_recursive(W.rt)
  H.write(W.rt .. '/restore.json', json.encode({v = 2, save = 'x', wall = 1, active = 1, orig = {gfps = 99}}))
  df.global.enabler.gfps = 30                          -- still our profile value
  local ok, msg = kern.restore{modules = {arbiter}}
  T.ok(ok, msg)
  T.eq(df.global.enabler.gfps, 99)
  T.eq({kern.restore{modules = {arbiter}}}, {false, 'nothing to restore'})
  -- on the stopped, marked save that restore.json names, timestream is restored too
  local W2 = H.world{tag = 'restorecmd2', ts_fps = 500}
  luahost.mkdir_recursive(W2.rt)
  H.write(W2.rt .. '/restore.json', json.encode({v = 2, save = 'region1', wall = 1, active = 1, orig = {timestream_fps = 120}}))
  T.ok(kern.restore{modules = {arbiter}})
  T.eq(W2.ts_fps, 120)
end)

T.test('supply brake: economy.alarm or phase P0 hold tempo and FPS cap at BRAKE_FPS; off restores both', function()
  local dir = H.tmpdir('kmockbrake')
  local W = kmock.new{dfpath = dir}
  luahost.mkdir_recursive(dir .. '/dfllm-runtime')
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  local alarm
  local eco = {name = 'economy', every = {ticks = 1200}}
  function eco.alarm(K) return alarm end
  W.load(eco)
  W.load(arbiter)
  local function last(fn, a1)
    local l = W.find_acts(fn)
    for i = #l, 1, -1 do if a1 == nil or l[i].args[1] == a1 then return l[i] end end
  end
  T.eq(last('setting', 'fps_cap'), nil, 'no cap write without a brake')
  alarm = 'thirst 3'
  W.run(40, {paused = true})
  T.eq(last('timestream').args[1], arbiter.BRAKE_FPS)
  T.eq(last('setting', 'fps_cap').args[2], arbiter.BRAKE_FPS)
  T.eq(W.state().owners.tempo, 'brake')
  alarm = nil
  W.run(40, {paused = true})
  T.eq(last('timestream').args[1], 500)
  T.eq(last('setting', 'fps_cap').args[2], 250, 'the captured original cap')
  T.eq(W.state().owners.tempo, 'mode')
  -- SIEGE: timestream is off anyway, no brake
  alarm = 'drink 3 d'
  W.K.set_mode('SIEGE', 'army')
  W.run(40, {paused = true})
  T.eq(last('timestream').args[1], -1)
  T.eq(arbiter.brake_why(W.K), nil)
end)

T.test('FR-51 clock governor: mode caps, the reflex clamp, config override, restore on unload', function()
  local dir = H.tmpdir('kmockclock')
  local W = kmock.new{dfpath = dir, cfg = {reflex = {v = 2, clock = {siege_cap = 20, alert_cap = 5000}}}}
  luahost.mkdir_recursive(dir .. '/dfllm-runtime')
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  local why
  local reflex = {name = 'reflex', every = {ticks = 10}}
  function reflex.holding(K, what) return why end
  W.load(reflex)
  W.load(arbiter)
  W.settings.fps_cap = nil
  local function capv() return W.settings.fps_cap end
  T.eq(capv(), nil, 'PEACE: no cap write')
  T.eq(W.state().clock, {cap = 250, orig = 250, ts = 500, held = 0, why = ''})
  W.K.set_mode('ALERT', 'test')
  T.eq({capv(), W.timestream_fps}, {100, -1}, 'alert_cap out of range (5000): the default 100')
  W.K.set_mode('SIEGE', 'test')
  T.eq(capv(), 20, 'config/reflex.json clock.siege_cap')
  T.eq(W.state().clock, {cap = 20, orig = 250, ts = -1, held = 0, why = 'siege'})
  W.K.set_mode('RECOVERY', 'test')
  T.eq({capv(), W.timestream_fps}, {250, 250})
  why = 'arrival:siege'                         -- the lockdown holds: same step through arbiter.hold
  local ok, c, w = W.K.call('arbiter', 'hold')
  T.eq({ok, c, w}, {true, 20, 'arrival:siege'})
  T.eq({capv(), W.timestream_fps}, {20, -1})
  T.eq(W.state().owners.tempo, 'clock')
  T.eq(W.state().clock.held, 1)
  why = nil
  W.run(40, {paused = true})
  T.eq({capv(), W.timestream_fps, W.state().owners.tempo}, {250, 250, 'mode'})
  why = 'unacked:DEATHS_3PLUS'
  W.run(40, {paused = true})
  W.unload()
  local r = H.json(dir .. '/dfllm-runtime/restore.json')
  T.eq({r.active, r.orig.fps_cap}, {0, 250})
  T.eq(capv(), 250, 'the original cap is back after unload')
end)

T.test('BUG-026 trade clock: trade.clock() caps the FPS at clock.trade_cap, never above the original; released after', function()
  local dir = H.tmpdir('kmocktradeclock')
  local W = kmock.new{dfpath = dir, cfg = {reflex = {v = 2, clock = {trade_cap = 80}}}}
  luahost.mkdir_recursive(dir .. '/dfllm-runtime')
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  local why
  local trade = {name = 'trade', every = {ticks = 100}}
  function trade.clock(K) return why end
  W.load(trade)
  W.load(arbiter)
  W.settings.fps_cap = nil
  W.run(10, {paused = true})
  T.eq(W.settings.fps_cap, nil, 'no cap write while trade holds nothing')
  why = 'trade'
  W.run(40, {paused = true})
  T.eq({W.settings.fps_cap, W.timestream_fps}, {80, -1}, 'clock.trade_cap; timestream above it goes off')
  T.eq(W.state().clock, {cap = 80, orig = 250, ts = -1, held = 0, why = 'trade'})
  W.K.set_mode('SIEGE', 'test')                 -- a lower mode cap wins
  T.eq(W.settings.fps_cap, 30)
  W.K.set_mode('RECOVERY', 'test')
  W.K.set_mode('PEACE', 'test')
  T.eq(W.settings.fps_cap, 80)
  why = nil
  W.run(40, {paused = true})
  T.eq({W.settings.fps_cap, W.timestream_fps}, {250, 500}, 'released: the original cap and the mode tempo')
  local logged
  for _, l in ipairs(W.logs) do if l.msg:find('trade clock on: FPS cap 80', 1, true) then logged = true end end
  T.ok(logged, 'logged')
  -- the default trade_cap (100) and a player cap below it: never raised
  local dir2 = H.tmpdir('kmocktradeclock2')
  local W2 = kmock.new{dfpath = dir2}
  luahost.mkdir_recursive(dir2 .. '/dfllm-runtime')
  df.global.enabler.fps = 60
  local t2 = {name = 'trade', every = {ticks = 100}}
  function t2.clock(K) return 'trade' end
  W2.load(t2)
  W2.load(arbiter)
  W2.run(40, {paused = true})
  T.eq(W2.state().clock.cap, 60, 'the player cap 60 is below trade_cap 100: kept')
end)

T.test('FR-51 crash heal: a lowered FPS cap (any value below the original) is restored', function()
  local W = H.world{tag = 'healcap'}
  luahost.mkdir_recursive(W.rt)
  H.write(W.rt .. '/restore.json', json.encode({v = 2, save = 'region1', wall = 1, active = 1, orig = {fps_cap = 250}}))
  df.global.enabler.fps = 30                    -- the siege cap was in force when the kernel died
  T.ok(kern.restore{modules = {arbiter}})
  T.eq(math.floor(df.global.enabler.fps), 250)
end)

T.test('arbiter on the reference k_mock K (strict contract checks)', function()
  local dir = H.tmpdir('kmockarb')
  local W = kmock.new{dfpath = dir}
  luahost.mkdir_recursive(dir .. '/dfllm-runtime')
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  W.load(arbiter)
  local acts = {}
  for _, a in ipairs(W.acts) do acts[#acts + 1] = a.fn .. ':' .. tostring(a.args[1]) end
  T.eq(acts, {'setting:gfps', 'setting:autosave', 'timestream:500'})
  W.K.set_mode('SIEGE', 'army')
  T.eq(W.find_acts('timestream')[2].args[1], -1)
  W.run(100, {skip = 9})
  T.eq(#W.find_acts('timestream'), 2, 'idempotent')
  local r = W.inbox('pause', {ttl_s = 1})
  T.eq(r.ok, true)
  T.eq(W.state().owners, {pause = 'inbox', tempo = 'mode'})
  W.run(100, {paused = true})
  T.eq(df.global.pause_state, false)
  T.eq(W.find_acts('setting')[3].args, {'fps_cap', 30, n = 2}, 'FR-51: SIEGE caps the vanilla FPS')
  W.unload()
  local restored = {}
  for i = 4, #W.find_acts('setting') do local a = W.find_acts('setting')[i].args; restored[a[1]] = a[2] end
  T.eq({restored.gfps, restored.fps_cap}, {250, 250}, 'restore on UNLOAD')
  T.eq(H.json(dir .. '/dfllm-runtime/restore.json').active, 0)
end)

T.done()
