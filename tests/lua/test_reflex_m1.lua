-- reflex, package M1 (Run 14 note 74): the lockdown's confined_need decision (a mood dwarf or a patient dying of thirst
-- inside the confinement) is about citizens only; a resident in the census (sense.lua counts isCitizen or isResident) is none.
-- BUG-103. Fails on the commit before the package (32994bb). The scenario is test_reflex.lua's 'BUG-065 ... mood dwarf'.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local function door(W, id, x, y, forbidden)
  local b = W.add_building{id = id, _kind = 'door', x1 = x, y1 = y, x2 = x, y2 = y, z = Z, centerx = x, centery = y,
                           door_flags = {forbidden = forbidden == true}}
  b.getType = function() return df.building_type.Door end
  df.global.world.buildings.other.DOOR:insert('#', b)
  return b
end

-- the siege world plus doors, open-sky tiles north of O1, a snapshot stand-in (real outside_near), the reflex module
-- and the arbiter. opts.manifest = false: the bridges and levers exist, the fort has no manifest (Run 9).
local function setup(opts)
  opts = opts or {}
  local dir = H.tmpdir(opts.tag or 'r')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{manifest = opts.manifest, units = opts.units or S.fort_units(), dfpath = dir, cfg = opts.cfg,
                    ms_per_frame = opts.ms_per_frame, tiefe = opts.tiefe, kern = opts.kern, mode = opts.mode,
                    persist = opts.persist}
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
  W.act_result('dismiss_popup', function(kind)        -- act.lua: close the front popup
    local p = df.global.world.status.popups
    if #p == 0 then return false, 'no popup' end
    p:erase(0)
    return true, kind
  end)
  W.tiles = {}
  for x = 40, 70 do W.tiles[x .. ',7,' .. Z] = {des = {outside = true}} end
  W.doors = {entrance = door(W, 501, 51, 8), inner = door(W, 502, 60, 70), own = door(W, 503, 52, 8, true)}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far(K, x, y, z) return W.far_fn ~= nil and W.far_fn(x, y, z) or false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  local mods = {S.military(), snap}
  if opts.reflex ~= false then mods[#mods + 1] = require('dfllm.reflex') end
  mods[#mods + 1] = require('dfllm.arbiter')
  for _, m in ipairs(opts.extra or {}) do mods[#mods + 1] = m end
  S.load(W, mods)
  return W
end

local function events(W, t)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == t then r[#r + 1] = e end end
  return r
end
local ELK, GOB, GREM = 88, 89, 90
local function raws()
  local elk = {flags = {CAN_LEARN = false, CAN_SPEAK = false, MOUNT_EXOTIC = true}}
  local gob = {flags = {CAN_LEARN = true, CAN_SPEAK = true}}
  df.creature_raw = {find = function(r)
    if r == ELK then return {caste = {[0] = elk}} elseif r == GOB or r == GREM then return {caste = {[0] = gob}} end
  end}
end
local function add(W, spec, race)
  local u = W.add_unit(spec)
  u.race, u.caste = race, 0
  return u
end
local function gremlin(W, id, x, y, size)
  local u = add(W, S.inv(id, x, y, Z, {race = 'GREMLIN'}), GREM)
  u.body = {size_info = {size_cur = size or 4000}}
  return u
end
local function decisions(W, id)
  local r = {}
  for _, e in ipairs(events(W, 'DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end

-- a lockdown for one small intruder near a citizen, the alert sounding; unit 3 stands at thirst 63,513 in a strange mood
local function lockdown(tag, resident)
  local W = setup{tag = tag, manifest = false}
  raws()
  W.move(2, 100, 20, Z)
  gremlin(W, 300, 110, 20)
  S.run(W, 120)
  W.inbox('ack', {})
  S.run(W, 2600)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1)
  W.inbox('ack', {})
  local u = W.unit(3)
  if resident then u._m.citizen, u._m.resident = false, true end      -- sense still counts him: isCitizen or isResident
  u.mood, u.counters2 = 1, {thirst_timer = 63513, hunger_timer = 0}
  S.run(W, 700)
  return W
end

T.test('BUG-103: a resident (no citizen) in the census with the same thirst raises no confined_need and ends no lockdown; ' ..
       'the citizen of the control run does', function()
  local C = lockdown('m1ctl', false)
  local d = decisions(C, 'confined_need')
  T.eq(#d, 1, 'control: a citizen is reported')
  T.eq({d[1].d.units, d[1].d.why}, {{3}, 'mood'})
  local W = lockdown('m1res', true)
  T.eq(W.unit(3)._m.citizen, false)
  local seen = false
  for _, id in ipairs(W.K.census.u.ids) do if id == 3 then seen = true end end
  T.ok(seen, 'unit 3 is in census.u.ids as a resident')
  T.eq(#decisions(W, 'confined_need'), 0, 'nothing is asked of the player for a resident')
  T.eq(#events(W, 'LOCKDOWN_END'), 0, 'and the lockdown does not end for him')
end)
T.done()
