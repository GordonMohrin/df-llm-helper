-- BUG-121 (Run 14 note 101): after the player loads an OLDER save of the same fort, events.jsonl, alarm.txt and the state
-- slots in the runtime folder still hold the discarded timeline. The kernel notices at boot that the game clock jumped
-- back and writes the class-B marker TIMELINE_RESET (n_alt, tick_alt, tick_neu) before BOOT; a boot with the clock
-- moving forward (timestream), a first boot and every later boot after the reset must not write one.
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local contract = require('dfllm.util.contract')
local kern = require('dfllm.kern')

local YEAR = 403200
local function mods() return {H.counter('test_a', {ticks = 10})} end
local function abs() return df.global.cur_year * YEAR + df.global.cur_year_tick end
local function resets(W) return H.find(H.events(W), 'TIMELINE_RESET') end
local function last_n(W) local ev = H.events(W); return ev[#ev].n end

-- one session: boot, play `ticks` game ticks, stop; returns the last event number
local function session(W, ticks)
  local ok, msg = H.boot(W, {modules = mods()})
  T.ok(ok, msg)
  H.run(W, ticks, {skip = 5})
  kern.stop('test')
  return last_n(W)
end

T.test('contract: TIMELINE_RESET is a class-B kern event', function()
  T.eq({contract.EVENTS.TIMELINE_RESET.cls, contract.EVENTS.TIMELINE_RESET.by}, {'B', 'kern'})
end)

T.test('an older save: TIMELINE_RESET before BOOT with n_alt, tick_alt, tick_neu; the old alarm.txt goes', function()
  local W = H.world{tag = 'reset', year = 3, ytick = 1000}
  local n_alt = session(W, 600)                      -- the abandoned line: clock 1000 -> 1600
  local tick_alt = abs()
  H.write(W.sd .. '/alarm.txt', 'DEFCON 1 | mode BREACH | unacked 2 | last 9 | ack 0 | lockdown breach (gates)\n')
  df.global.cur_year_tick = 1300                     -- the player loaded an older save (the clock stands at 1300)
  local tick_neu = abs()
  local ok, msg = H.boot(W, {modules = mods()})
  T.ok(ok, msg)
  local ev = H.events(W)
  local r = H.find(ev, 'TIMELINE_RESET')
  T.eq(#r, 1)
  T.eq({r[1].cls, r[1].tick}, {'B', tick_neu})
  T.eq({r[1].d.n_alt, r[1].d.tick_alt, r[1].d.tick_neu}, {n_alt, tick_alt, tick_neu})
  T.ok(#json.encode(r[1].d) < 200, 'd stays under 200 bytes')
  T.ok(r[1].n > n_alt, 'event numbers continue')
  local boots = H.find(ev, 'BOOT')
  T.ok(boots[#boots].n > r[1].n, 'the marker comes before this boot\'s BOOT event')
  T.eq(luahost.isfile(W.sd .. '/alarm.txt'), false, 'the alarm.txt of the discarded line is not taken over')
  kern.stop('test')
end)

T.test('a timestream restart (clock moving forward) writes no marker', function()
  local W = H.world{tag = 'forward', year = 3, ytick = 1000}
  session(W, 400)
  df.global.cur_year_tick = df.global.cur_year_tick + 5000      -- timestream skipped ahead while the kernel was down
  H.boot(W, {modules = mods()})
  T.eq(#resets(W), 0)
  kern.stop('test')
end)

T.test('the clock at the very tick of the last event (a plain reboot) writes no marker', function()
  local W = H.world{tag = 'same', year = 3, ytick = 1000}
  session(W, 400)
  H.boot(W, {modules = mods()})
  T.eq(#resets(W), 0)
  kern.stop('test')
end)

T.test('a first boot without an event log writes no marker', function()
  local W = H.world{tag = 'first', year = 3, ytick = 1000}
  H.boot(W, {modules = mods()})
  T.eq(#resets(W), 0)
  T.eq(#H.find(H.events(W), 'BOOT'), 1)
  kern.stop('test')
end)

T.test('boots after a reset do not write a second marker', function()
  local W = H.world{tag = 'again', year = 3, ytick = 1000}
  session(W, 600)
  df.global.cur_year_tick = 1300
  session(W, 0)                                       -- the reset boot
  H.boot(W, {modules = mods()})                       -- reboot at the same tick
  kern.stop('test')
  df.global.cur_year_tick = df.global.cur_year_tick + 100
  session(W, 50)                                      -- and one with the clock forward
  T.eq(#resets(W), 1)
end)

T.test('the state slot the reset boot did not rewrite yet still carries the old tick: no second marker', function()
  local W = H.world{tag = 'slot', year = 3, ytick = 1000}
  session(W, 600)
  df.global.cur_year_tick = 1300
  session(W, 0)
  local low                                           -- the slot with the lower seq = the one of the old line
  for _, s in ipairs({'a', 'b'}) do
    local d = json.decode(H.read(W.sd .. '/state.' .. s .. '.json'))
    if not low or d.seq < low.d.seq then low = {s = s, d = d} end
  end
  low.d.t.abs = 3 * YEAR + 1600
  H.write(W.sd .. '/state.' .. low.s .. '.json', json.encode(low.d))
  H.boot(W, {modules = mods()})
  T.eq(#resets(W), 1)
  kern.stop('test')
end)

T.test('without an event log the newest state slot still tells the clock jumped back', function()
  local W = H.world{tag = 'nolog', year = 3, ytick = 1000}
  local n_alt = session(W, 600)
  os.remove(W.sd .. '/events.jsonl')
  df.global.cur_year_tick = 1300
  H.boot(W, {modules = mods()})
  local r = resets(W)
  T.eq(#r, 1)
  T.eq({r[1].d.tick_alt, r[1].d.tick_neu, r[1].d.n_alt}, {3 * YEAR + 1600, 3 * YEAR + 1300, n_alt}, 'n_alt = the persisted kern.ev')
  kern.stop('test')
end)

T.test('a rotated log: the newest line of events.jsonl decides, events.1.jsonl only when the current file is empty', function()
  local W = H.world{tag = 'rot', year = 3, ytick = 1000}
  session(W, 600)
  local f = assert(io.open(W.sd .. '/events.jsonl', 'rb')); local body = f:read('a'); f:close()
  H.write(W.sd .. '/events.1.jsonl', body)
  H.write(W.sd .. '/events.jsonl', '')
  df.global.cur_year_tick = 1300
  H.boot(W, {modules = mods()})
  T.eq(#resets(W), 1)
  kern.stop('test')
end)

T.test('reflex: an interrupt and a lockdown hold stamped after the clock are not taken over; older ones are', function()
  local W = H.world{tag = 'reflex', year = 3, ytick = 1000}
  local now = 3 * YEAR + 1000
  W.persist_raw['dfllm.m.reflex'] = json.encode{v = 2, ack = {n = 11, wall = 1}, irq = {
    {n = 11, type = 'INTRUDER', tick = now - 50, wall = 1, ms = 1, msg = 'older line, before the save', done = 0},
    {n = 12, type = 'BREACH_X', tick = now + 900, wall = 2, ms = 1, msg = 'discarded line, after the save', done = 0},
  }, hold = {why = 'intruder', kinds = {intruder = true}, acts = {gates = true}, since = now + 800, last = now + 900}}
  package.loaded['dfllm.reflex'] = nil
  local ok, msg = H.boot(W, {modules = {require('dfllm.reflex')}})
  T.ok(ok, msg)
  H.run(W, 40, {skip = 5})
  local text = H.read(W.sd .. '/alarm.txt') or ''
  T.ok(text:find('older line, before the save', 1, true), 'the interrupt before the clock stays: ' .. text)
  T.eq(text:find('discarded line', 1, true), nil, 'the interrupt after the clock is dropped')
  T.ok(text:find('lockdown off', 1, true), 'the lockdown of the discarded line is not taken over: ' .. text)
  kern.stop('test')
end)

T.done()
