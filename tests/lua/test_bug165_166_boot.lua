-- BUG-165/166 (live i2, 'autosave 1' of another instance's line): right after the load status said 'DEFCON 1 ... PEACE,
-- 12 interrupts unacked'. The save's persisted kern.ev (~33436) was ahead of this runtime folder's last event (#32748) and
-- the clock stood later than the folder's last tick, so BUG-121's clock-back test wrote no TIMELINE_RESET; reflex init
-- took over every persisted interrupt (defaults applied 1.5 to 5 game years before, a duplicate #32617 among them),
-- defcon() counted a done=1 INTRUDER as open for ever, and alarm.txt kept the previous line's file until the first step.
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')

local YEAR = 403200
local function mods() return {H.counter('test_a', {ticks = 10})} end
local function abs() return df.global.cur_year * YEAR + df.global.cur_year_tick end
local function resets(W) return H.find(H.events(W), 'TIMELINE_RESET') end
local function last_n(W) local ev = H.events(W); return ev[#ev].n end
local function session(W, ticks)
  local ok, msg = H.boot(W, {modules = mods()})
  T.ok(ok, msg)
  H.run(W, ticks, {skip = 5})
  kern.stop('test')
  return last_n(W)
end
-- the save of another line: its kern.ev runs `ahead` events past this folder's log
local function foreign(W, ahead)
  local kp = json.decode(W.persist_raw['dfllm.kern'])
  kp.ev = kp.ev + ahead
  W.persist_raw['dfllm.kern'] = json.encode(kp)
  return kp.ev
end

T.test('BUG-165: a save whose kern.ev is ahead of the folder\'s log (clock later): TIMELINE_RESET kind foreign, the old ' ..
       'alarm.txt goes', function()
  local W = H.world{tag = 'foreign', year = 3, ytick = 1000}
  local disk = session(W, 600)
  local ev_save = foreign(W, 700)
  H.write(W.sd .. '/alarm.txt', 'DEFCON 3 | mode PEACE | unacked 20 | last 32708 | ack 32253 | lockdown off\n')
  df.global.cur_year_tick = 5000                      -- the other line's save is later than this folder's last tick
  local ok, msg = H.boot(W, {modules = mods()})
  T.ok(ok, msg)
  local r = resets(W)
  T.eq(#r, 1, 'old code: no marker (the clock did not go back)')
  T.eq({r[1].d.kind, r[1].d.n_alt, r[1].d.tick_neu}, {'foreign', disk, abs()})
  T.ok(r[1].n > ev_save, 'event numbers continue after the save\'s kern.ev')
  T.ok(#json.encode(r[1].d) < 200)
  T.eq(luahost.isfile(W.sd .. '/alarm.txt'), false, 'the other line\'s alarm.txt is not taken over')
  kern.stop('test')
end)

T.test('BUG-165: the clock-back marker says kind clock; a plain reboot and a first boot write none', function()
  local W = H.world{tag = 'clockkind', year = 3, ytick = 1000}
  session(W, 600)
  df.global.cur_year_tick = 1300
  session(W, 0)
  local r = resets(W)
  T.eq({#r, r[1].d.kind}, {1, 'clock'})
  H.boot(W, {modules = mods()})                       -- the same line again: kern.ev == the log's last event
  kern.stop('test')
  T.eq(#resets(W), 1)
  local W2 = H.world{tag = 'firstkind', year = 3, ytick = 1000}
  W2.persist_raw['dfllm.kern'] = json.encode{v = 2, ev = 500, seq = 3, boots = 2}   -- a save, but no log in this folder
  H.boot(W2, {modules = mods()})
  T.eq(#resets(W2), 0, 'a first boot without a log is no foreign line')
  kern.stop('test')
end)

-- reflex on the real kernel; irq rows as persisted by an older kernel
local function reflex_boot(W, irq, ack)
  W.persist_raw['dfllm.m.reflex'] = json.encode{v = 2, ack = {n = ack or 0, wall = 1}, irq = irq}
  package.loaded['dfllm.reflex'] = nil
  local ok, msg = H.boot(W, {modules = {require('dfllm.reflex')}})
  T.ok(ok, msg)
end

T.test('BUG-166: a foreign line: the done interrupts of the save are not taken over, open ones are (once); alarm.txt is ' ..
       'written by init, before any step', function()
  local W = H.world{tag = 'rfx_foreign', year = 3, ytick = 1000}
  session(W, 600)
  foreign(W, 700)
  df.global.cur_year_tick = 5000
  local now = abs()
  df.global.pause_state = true
  reflex_boot(W, {
    {n = 40, type = 'INTRUDER', tick = now - 3000, wall = 1, ms = 1, msg = 'goblin long ago', done = 1, u = 9},
    {n = 41, type = 'DEATHS_3PLUS', tick = now - 2000, wall = 1, ms = 1, msg = 'deaths once', done = 2},
    {n = 41, type = 'DEATHS_3PLUS', tick = now - 1998, wall = 1, ms = 1, msg = 'deaths once', done = 2},
    {n = 42, type = 'CURSED', tick = now - 100, wall = 1, ms = 1, msg = 'open curse', done = 0},
    {n = 42, type = 'CURSED', tick = now - 99, wall = 1, ms = 1, msg = 'open curse', done = 0},
  }, 30)
  local text = H.read(W.sd .. '/alarm.txt') or ''
  T.eq(text:find("DEFCON 3 | mode PEACE | unacked 1 ", 1, true), 1, 'old code: no file before the first step; ' .. text)
  T.eq(text:find('goblin long ago', 1, true), nil, 'the INTRUDER whose default ran is not taken over')
  local _, k = text:gsub('open curse', '')
  T.eq(k, 1, 'one record per n')
  df.global.pause_state = false
  kern.stop('test')
end)

T.test('BUG-166: same line: copies dropped, done interrupts older than a game month dropped; a done INTRUDER without a ' ..
       'lockdown is no DEFCON 1', function()
  local W = H.world{tag = 'rfx_same', year = 3, ytick = 1000}
  df.global.cur_year_tick = 100000
  local now = abs()
  reflex_boot(W, {
    {n = 7, type = 'INTRUDER', tick = now - 200000, wall = 1, ms = 1, msg = 'a year-old intruder', done = 1, u = 9},
    {n = 8, type = 'INTRUDER', tick = now - 1200, wall = 1, ms = 1, msg = 'yesterday intruder', done = 1, u = 9},
    {n = 8, type = 'INTRUDER', tick = now - 1199, wall = 1, ms = 1, msg = 'yesterday intruder', done = 1, u = 9},
    {n = 9, type = 'PREDATOR', tick = now - 600, wall = 1, ms = 1, msg = 'far predator', done = 2, u = 10},
  }, 0)
  H.run(W, 40, {skip = 5})
  local text = H.read(W.sd .. '/alarm.txt') or ''
  T.eq(text:find('a year-old intruder', 1, true), nil, 'stale and done: not taken over')
  local _, k = text:gsub('yesterday intruder', '')
  T.eq(k, 1, 'the duplicate is loaded once (old code: twice)')
  T.eq(text:find("DEFCON 5 | mode PEACE | unacked 2 ", 1, true), 1, 'old code: DEFCON 1 for a done INTRUDER; ' .. text)
  kern.stop('test')
end)

T.done()
