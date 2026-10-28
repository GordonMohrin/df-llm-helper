-- BUG-143..145 (live test i3, Trussroads y717): reflex texts printed decimals with the locale's comma; the lockdown cause
-- did not say why a unit is dangerous; a dead intruder's kill order stayed in the status for
-- the next one, LOCKDOWN_END named a far unit twice, an interrupt delivered twice was recorded twice.
-- Fixture of test_m3_lone (siege world, the real reflex).
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local Z = S.Z

local GOB = 89
local kills, kill_answer, sol
local function setup(opts)
  opts = opts or {}
  local dir = H.tmpdir(opts.tag or 'm3')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{units = opts.units or S.fort_units(), dfpath = dir, cfg = opts.cfg}
  W.dir = dir
  df.building_type.Door = 23
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  W.act_result('door_forbid', function(id, on)
    local b = W.buildings[id]
    if not b or b._kind ~= 'door' then return false, 'not a door' end
    local old = b.door_flags.forbidden
    b.door_flags.forbidden = on and true or false
    return true, old
  end)
  W.tiles = {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  kills, kill_answer = {}, {true, 'kill order on 300'}
  sol = {soldiers = 8, on_station = 7}
  local mil = S.military()
  mil.sortie_squad = function() return 'A', 6 end
  mil.kpi = function() return {squads = 3, soldiers = sol.soldiers, worn = 95, cv = 13, metal_pct = 0, on_station = sol.on_station} end
  mil.kill_lone = function(K, ids, by) kills[#kills + 1] = {ids = ids, by = by, tick = K.now().tick}; return kill_answer[1], kill_answer[2] end
  W.mil = mil
  S.load(W, {mil, snap, require('dfllm.reflex'), require('dfllm.arbiter')})
  return W
end
local function raws()
  local gob = {flags = {CAN_LEARN = true, CAN_SPEAK = true}}
  df.creature_raw = {find = function(r) if r == GOB then return {caste = {[0] = gob}} end end}
end
local function goblin(W, id, x, y, z, size)
  local u = W.add_unit(S.inv(id, x, y, z or Z))
  u.race, u.caste = GOB, 0
  u.body = {size_info = {size_cur = size or 6486}}
  return u
end
local function events(W, t)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == t then r[#r + 1] = e end end
  return r
end
local function decisions(W, id)
  local r = {}
  for _, e in ipairs(events(W, 'DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function cap(W) return W.settings.fps_cap end
local CF = {reflex = {v = 2, confine = {max_days = 3, ask_days = 1, kill_hours = 12}}}

local R = function() return require('dfllm.reflex') end

-- run fn with LC_NUMERIC set to the German locale of the live machine (decimal comma); false when the host lacks it
local function german(fn)
  local old = os.setlocale(nil, 'numeric')
  local ok = os.setlocale('German_Germany.utf8', 'numeric') or os.setlocale('de_DE.UTF-8', 'numeric')
  if not ok then return false end
  local okr, err = pcall(fn)
  os.setlocale(old or 'C', 'numeric')
  if not okr then error(err, 0) end
  return true
end
local function logs(W, pat)
  local r = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then r[#r + 1] = tostring(l.msg) end end
  return r
end

---------------------------------------------------------------- BUG-143 decimals without the locale's comma
T.test('BUG-143: util.num.dec writes a decimal point under a comma locale; string.format does not (the bug)', function()
  local N = require('dfllm.util.num')
  local ran = german(function()
    T.eq(string.format('%.1f', 4.8), '4,8', 'the host shows the live bug')
    T.eq({N.dec(4.8), N.dec(10), N.dec(4.75), N.dec(-0.04), N.dec(3, 2), N.dec(1234.5, 0), N.dec(-2.25, 1)},
         {'4.8', '10.0', '4.8', '0.0', '3.00', '1235', '-2.3'})
  end)
  T.ok(ran, 'German_Germany.utf8 numeric locale available')
  T.eq({N.dec(0 / 0), N.dec(math.huge), N.dec('x')}, {'nan', 'inf', 'x'})
end)

T.test('BUG-143: kill_lone_intruder q and the release log line read "1.0 days" under a comma locale (old: "1,0")', function()
  german(function()
    local W = setup{tag = 'loc', cfg = CF}
    raws()
    goblin(W, 300, 61, 70, Z)
    S.run(W, 4000)
    local d = decisions(W, 'kill_lone_intruder')
    T.ok(#d >= 1, 'asked')
    T.ok(d[1].d.q:find('for %d+%.%d days') and not d[1].d.q:find('%d,%d days'), d[1].d.q)
    local l = logs(W, 'cleared after')
    T.ok(#l >= 1 and l[1]:find('after %d+%.%d days') and not l[1]:find('%d,%d days'), l[1] or 'no release log')
  end)
end)

---------------------------------------------------------------- BUG-144 the reason a unit is dangerous
T.test('BUG-144: the cause names why it is dangerous (alarm.by.hw): size over harmless_size, large predator, ...', function()
  local W = setup{tag = 'hw', cfg = CF}
  raws()
  goblin(W, 300, 61, 70, Z, 60000)                       -- adult size inside Kern+
  S.run(W, 400)
  local a = W.state().alarm
  T.eq({a.by.hl, a.by.hw}, {0, 'size 60000 > 20000'}, 'old code: dangerous with no reason')
  T.eq(C.check_state(W.state()), {})
  local dw = R().danger_why
  local c = {harmless_size = 20000, harmless_races = {}}
  T.eq({dw({k = 'great', id = 1}, c), dw({k = 'undead', id = 1}, c), dw({k = 'inv', bd = 1, dz = 1, id = 1}, c),
        dw({k = 'inv', pr = 1, id = 1}, c), dw({k = 'inv', dz = 1, id = 1}, c), dw({k = 'inv', id = 1}, c),
        dw({k = 'inv', id = 1, sz = 500}, c)},
       {'great danger', 'undead', 'building destroyer', 'large predator', 'flier/trap avoider', 'size unknown', nil})
end)

---------------------------------------------------------------- BUG-145 stale or doubled records
T.test('BUG-145: the kernel kill order of a dead intruder is not shown for the next lone intruder (alarm.ln.kill)', function()
  local W = setup{tag = 'klstale', cfg = CF}
  raws()
  goblin(W, 300, 61, 70, Z)
  S.run(W, 1000)
  T.eq(#kills, 1)
  T.eq(W.state().alarm.ln.kill, 'kill order on 300')
  W.kill(300); W.event('UNIT_DEATH', {unit = 300})
  goblin(W, 301, 150, 150, Z)                            -- the next one, far outside: no new kill order
  S.run(W, 300)
  local ln = W.state().alarm.ln
  T.ok(ln ~= nil, 'the new lone picture')
  T.eq(ln.kill, nil, 'old code: "kill order on 300" for the next intruder')
end)

T.test('BUG-145: LOCKDOWN_END at the SIEGE limit names a far lone intruder once (old: twice, nfar 2)', function()
  local W = setup{tag = 'fardup', cfg = CF, units = S.fort_units()}
  raws()
  for i = 1, 6 do goblin(W, 300 + i, 150 + i, 150, Z, 60000) end
  S.run(W, 300)
  for i = 2, 6 do W.kill(300 + i); W.event('UNIT_DEATH', {unit = 300 + i}) end
  W.unit(301)._m.x, W.unit(301)._m.y = 150, 150
  W.unit(301).body = {size_info = {size_cur = 6486}}
  S.run(W, 4500)
  local e = events(W, 'LOCKDOWN_END')
  T.eq(#e, 1)
  T.eq({#e[1].d.far, e[1].d.nfar}, {1, 1}, table.concat(e[1].d.far or {}, ' | '))
end)

T.test('BUG-145: an interrupt delivered twice is recorded once (old: two alarm records, two ack timeouts)', function()
  local W = setup{tag = 'irq'}
  S.run(W, 50)
  local ev = {n = 77, type = 'DEATHS_3PLUS', msg = '3 citizens died within a day: unknown 3'}
  R().on['EV:DEATHS_3PLUS'](W.K, ev)
  S.run(W, 2)
  R().on['EV:DEATHS_3PLUS'](W.K, ev)
  T.eq(W.state().alarm.unacked, 1, 'old code: 2')
end)

T.done()
