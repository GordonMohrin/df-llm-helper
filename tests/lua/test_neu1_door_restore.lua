-- NEU1 P7 BUG-812 (docs/v2/NEU1-notausgang.md): door.lock may never leave a door forbidden for good. The real reflex lockdown on the
-- siege world (k_mock, strict contract) plus the player module with a thirsty patient that keeps the emergency exit open.
-- (1) the player locks a door the lockdown forbade: the lockdown's release inside the grace window unlocks it (an unlock is never held);
-- (2) the player locks an open door: the exit's close unlocks it again.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local C = require('dfllm.util.contract')
local Z = S.Z
local DAY = C.TICKS.DAY

local function door(W, id, x, y, forbidden)
  local b = W.add_building{id = id, _kind = 'door', x1 = x, y1 = y, x2 = x, y2 = y, z = Z, centerx = x, centery = y,
                           door_flags = {forbidden = forbidden == true}}
  b.getType = function() return df.building_type.Door end
  df.global.world.buildings.other.DOOR:insert('#', b)
  return b
end

local function setup(tag)
  local dir = H.tmpdir(tag)
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{manifest = false, units = S.fort_units(), dfpath = dir,
                    cfg = {baseline = {v = 2, player = {exit_days = 0}}}}
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
  W.act_result('dismiss_popup', function()
    local p = df.global.world.status.popups
    if #p == 0 then return false, 'no popup' end
    p:erase(0)
    return true
  end)
  W.tiles = {}
  for x = 40, 70 do W.tiles[x .. ',7,' .. Z] = {des = {outside = true}} end
  W.doors = {entrance = door(W, 501, 51, 8), inner = door(W, 502, 60, 70)}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  W.thirst = 61000
  local water = {name = 'water', every = {ticks = 1200}}
  function water.state()
    return {water = {patients = W.thirst and 1 or 0, thirst_max = W.thirst or 0, hosp_ok = 1, refuge_ok = 1, buckets_free = 3,
                     hosp = 1, src = {}}}
  end
  for _, n in ipairs({'reflex', 'arbiter', 'player'}) do package.loaded['dfllm.' .. n] = nil end
  S.load(W, {S.military(), snap, water, require('dfllm.reflex'), require('dfllm.arbiter'), require('dfllm.player')})
  return W
end

local function events(W, t)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == t then r[#r + 1] = e end end
  return r
end
local function last_reply(W) return W.replies[#W.replies] end

T.test('BUG-812: a door the lockdown forbade and the player locked is unlocked by the lockdown\'s release inside the grace window; ' ..
       'a door the player locked that was open is unlocked at EMERGENCY_END', function()
  local W = setup('doorrestore')
  S.run(W, 2 * DAY, {skip = 50})
  T.eq(#events(W, 'EMERGENCY'), 1, 'the thirsty patient opened the exit')
  df.global.world.status.popups:insert('#', {text = 'A vile force of darkness has arrived!'})
  df.global.pause_state = false
  S.run(W, 400)
  T.eq(#events(W, 'ARRIVAL'), 1)
  T.eq(W.doors.entrance.door_flags.forbidden, true, 'the lockdown forbade the entrance')
  W.inbox('door.lock', {door = 501, on = true})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  T.ok(last_reply(W).msg:find('was locked', 1, true), last_reply(W).msg)
  W.inbox('door.lock', {door = 502, on = true})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  T.eq(W.doors.inner.door_flags.forbidden, true)
  -- the threat leaves: the lockdown ends while the patient is still thirsty (exit open, door 501 held by the player)
  W.inbox('ack', {})
  S.run(W, 5200, {skip = 50})
  T.eq(#events(W, 'LOCKDOWN_END'), 1)
  T.eq(#events(W, 'EMERGENCY_END'), 0, 'the exit is still open')
  T.eq(W.doors.entrance.door_flags.forbidden, false, 'the release unlocked it although the player holds it (an unlock is never held)')
  T.eq(W.doors.inner.door_flags.forbidden, true, 'the player\'s own lock stays while the exit is open')
  -- the patient drinks: grace, then EMERGENCY_END unlocks the door the player locked
  W.thirst = nil
  S.run(W, 5 * DAY, {skip = 50})
  local ev = events(W, 'EMERGENCY_END')
  T.eq(#ev, 1)
  T.eq(ev[1].d.doors, 1)
  T.eq({W.doors.entrance.door_flags.forbidden, W.doors.inner.door_flags.forbidden}, {false, false})
  -- after the close no verb is needed: nothing stays forbidden; door.lock is refused again
  W.inbox('door.lock', {door = 502, on = true})
  T.eq(last_reply(W).ok, false)
end)

T.test('second verification (BUG-812): the exit closing under a kernel lockdown leaves the player\'s lock on (fail closed); ' ..
       'the undo waits for PEACE without a lockdown; the player\'s unlock never overrides the lockdown', function()
  local W = setup('doorfailclosed')
  S.run(W, 2 * DAY, {skip = 50})
  T.eq(#events(W, 'EMERGENCY'), 1, 'the thirsty patient opened the exit')
  W.inbox('door.lock', {door = 502, on = true})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  T.eq(W.doors.inner.door_flags.forbidden, true)
  -- the patient drinks; late in the grace (3 days) an army arrives: the lockdown outlasts the exit
  W.thirst = nil
  S.run(W, 2 * DAY + DAY // 2, {skip = 50})
  T.eq(#events(W, 'EMERGENCY_END'), 0, 'still in the grace')
  df.global.world.status.popups:insert('#', {text = 'A vile force of darkness has arrived!'})
  df.global.pause_state = false
  S.run(W, 400)
  T.eq(#events(W, 'ARRIVAL'), 1)
  T.eq(W.doors.entrance.door_flags.forbidden, true, 'the lockdown forbade the entrance')
  local okh, why = W.K.call('reflex', 'holding')
  T.ok(okh == true and why ~= nil, 'the lockdown holds')
  -- the player's unlock of a door during a kernel lockdown is refused: the lockdown owns the doors
  W.inbox('door.lock', {door = 501, on = false})
  T.eq(last_reply(W).ok, false, last_reply(W).msg)
  T.ok(last_reply(W).msg:find('lockdown', 1, true), last_reply(W).msg)
  T.eq(W.doors.entrance.door_flags.forbidden, true, 'still forbidden')
  W.inbox('door.lock', {door = 502, on = false})
  T.eq(last_reply(W).ok, false, 'not even his own lock comes off under the lockdown')
  T.eq(W.doors.inner.door_flags.forbidden, true)
  -- the grace ends while the lockdown still holds: EMERGENCY_END must not unlock door 502
  for _ = 1, 40 do
    if #events(W, 'EMERGENCY_END') > 0 then break end
    S.run(W, 120, {skip = 50})
  end
  T.eq(#events(W, 'LOCKDOWN_END'), 0, 'the lockdown still holds')
  local ev = events(W, 'EMERGENCY_END')
  T.eq(#ev, 1)
  T.eq(ev[1].d.doors, 0, 'nothing unlocked under the lockdown')
  T.eq(ev[1].d.kept, 1, 'one door kept locked until it is safe')
  T.ok(ev[1].msg:find('kernel lockdown', 1, true), ev[1].msg)
  T.eq({W.doors.entrance.door_flags.forbidden, W.doors.inner.door_flags.forbidden}, {true, true})
  -- the lockdown ends: reflex opens its own door, the player module then undoes the player's lock (nothing stays forbidden)
  W.inbox('ack', {})
  S.run(W, 5200, {skip = 50})
  T.eq(#events(W, 'LOCKDOWN_END'), 1)
  S.run(W, 2 * DAY, {skip = 50})
  T.eq({W.doors.entrance.door_flags.forbidden, W.doors.inner.door_flags.forbidden}, {false, false})
end)

T.done()
