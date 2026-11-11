-- BUG-692 / BUG-693, the reflex and siege traffic half (Run 16d i4 Trumpetrealms y461 winter: one goblin inside Kern+ killed 49 of 69 citizens in
-- a BREACH at 30 t/s; three DEATHS_3PLUS defaults re-applied the same lockdown, nothing sent the squads):
--   (1) BREACH, one goblin inside Kern+ that killed: reflex.inside_step asks military.kill_inside, again every KILL_RETRY ticks;
--   (2) the unacked DEATHS_3PLUS default of that BREACH sends the squads too, the LOCKDOWN event says so (d.fight), the lockdown still stands;
--   (3) siege traffic: a goblin siege with nobody inside, and a BREACH with a hostile that never killed, produce the same event trace and
--       the same mode / clock / lockdown with and without military.kill_inside (the new step is a no-op there, it only asks).
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z
local GOB = 89

local calls
local function setup(tag, with_kill, cfg)
  local dir = H.tmpdir(tag)
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{units = S.fort_units(), dfpath = dir, cfg = cfg, ms_per_frame = 500}
  W.dir = dir
  df.building_type.Door = 23
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  W.act_result('door_forbid', function(id, on) return true, false end)
  W.tiles = {}
  for x = 40, 70 do W.tiles[x .. ',7,' .. Z] = {des = {outside = true}} end
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  snap.outer_groups, snap.group_at = require('dfllm.snapshot').outer_groups, require('dfllm.snapshot').group_at
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  calls = {}
  local mil = S.military()
  if with_kill then
    function mil.kill_inside(K, by)
      calls[#calls + 1] = {by = by, tick = K.now().tick}
      if with_kill == 'nobody' then return false, 'nobody inside' end
      return true, '3 squads sent against 300 inside'
    end
  end
  S.load(W, {mil, snap, require('dfllm.reflex'), require('dfllm.arbiter')})
  df.creature_raw = {find = function(r) if r == GOB then return {caste = {[0] = {flags = {CAN_LEARN = true, CAN_SPEAK = true}}}} end end}
  return W
end
local function goblin(W, id, x, y, z, size)
  local u = W.add_unit(S.inv(id, x, y, z or Z))
  u.race, u.caste = GOB, 0
  u.body = {size_info = {size_cur = size or 6795}}
  return u
end
local function trace(W)
  local r = {}
  for _, e in ipairs(W.events) do r[#r + 1] = e.type .. ':' .. tostring(e.cls) end
  return table.concat(r, ',')
end
local CF = {reflex = {v = 2, ack_timeout_s = 10}}

T.test('BUG-692 (1): BREACH with a goblin that killed inside Kern+: the kernel asks kill_inside, again every KILL_RETRY ticks', function()
  local W = setup('i1', true, CF)
  goblin(W, 300, 61, 70)
  S.run(W, 200)
  T.eq(W.K.mode(), 'BREACH')
  T.eq(#calls, 1, 'asked at the first look: ' .. #calls)
  T.eq(calls[1].by, 'reflex')
  S.run(W, 700)
  T.ok(#calls >= 2, 'asked again after KILL_RETRY ticks: ' .. #calls)
  W.K.call('sense', 'mark_killer', 300)
  S.run(W, 700)
  T.ok(#calls >= 3, 'and again: ' .. #calls)
end)

T.test('BUG-692 (2): the unacked DEATHS_3PLUS default in that BREACH also sends the squads; the lockdown still stands', function()
  local W = setup('i2', true, CF)
  goblin(W, 300, 61, 70)
  S.run(W, 200)
  T.eq(W.K.mode(), 'BREACH')
  local before = #calls
  local ev = {n = 77, type = 'DEATHS_3PLUS', msg = '13 citizens died within a day: bled 6, killed 6, siege 1'}
  require('dfllm.reflex').on['EV:DEATHS_3PLUS'](W.K, ev)
  S.run(W, 9 * 30 + 60)
  local l = W.find_events('LOCKDOWN')
  T.ok(#l >= 1, 'the default fired')
  local last = l[#l]
  T.eq(last.d.why, 'ack_timeout')
  T.ok(last.d.fight and last.d.fight:find('squads sent against', 1, true), tostring(last.d.fight))
  T.ok(last.msg:find('squads sent against', 1, true), last.msg)
  T.ok(#calls > before, 'kill_inside was asked by the default')
  T.eq(W.state().alarm.lock, 1, 'the lockdown holds')
end)

T.test('BUG-692 (3) siege traffic: a goblin siege outside, and a harmless lone intruder inside: same trace with and without the new ask', function()
  local out = {}
  for i, with in ipairs({false, 'nobody'}) do
    local W = setup('t' .. i, with, CF)
    for k = 1, 6 do goblin(W, 400 + k, 50 + k, 30) end              -- an army outside the fort
    S.run(W, 2400)
    local W2 = setup('u' .. i, with, CF)
    goblin(W2, 300, 61, 70)                                         -- one inside, never killed
    S.run(W2, 2400)
    out[i] = {trace(W), W.K.mode(), W.state().alarm.lock, trace(W2), W2.K.mode(), W2.state().alarm.lock}
  end
  T.eq(out[1], out[2], 'the same events, mode and lockdown')
end)

T.done()
