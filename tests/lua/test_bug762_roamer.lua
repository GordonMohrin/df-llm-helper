-- BUG-762 (Run 16a i1 Basementflew y530-y534: one Kelenken roamed the whole map, PREDATOR every 1-2 game days, a Kern+ lockdown with the
-- clock at 30 t/s in between; Run 16b i2 a Megalania and a woolly mammoth the same): the same wild unit raises PREDATOR again only when it
-- comes closer to a citizen than at its last raise (or the first time after WANDER_DAYS); a far roamer that never came near gets PREDATOR_FAR.
-- Real threats stay immediate: within WANDER_CLOSE of a citizen, a killer, inside Kern+; and the siege traffic case: real invaders still
-- lock the fort down at once (ARRIVAL), roamer or not.
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
  if opts.sortie then mods[1].sortie_squad = function() return opts.sortie, 5 end end      -- BUG-495
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

local DAY = 1200
local function pred(W) return events(W, 'PREDATOR') end

-- the woodcutter stands at 120,30; the roamer comes by at x (distance to the woodcutter |x - 120|), leaves again (70 tiles: PREDATOR_FAR, a new
-- episode when it comes back) and returns. Roofed tiles all along its way.
local function world(tag)
  local units = S.fort_units()
  units[#units + 1] = S.danger(400, 190, 30, Z, {race = 'KELENKEN'})
  local W = setup{tag = tag, manifest = false, units = units}
  W.unit(400).body = {size_info = {size_cur = 10654}}
  dfhack.maps.getWalkableGroup = function() return 7 end
  for x = 120, 195 do W.tiles[x .. ',30,' .. Z] = {des = {outside = false, hidden = false}} end
  W.move(2, 120, 30, Z)
  S.run(W, 100)
  return W
end
local function visit(W, x, ticks)
  W.move(400, x, 30, Z)
  S.run(W, ticks or 400)
end
local function leave(W, ticks)
  W.move(400, 190, 30, Z)
  S.run(W, ticks or 700)
end

T.test('BUG-762: a roamer raises PREDATOR once, then PREDATOR_FAR until it comes closer; always immediate within 15 tiles', function()
  local W = world('roamer')
  visit(W, 150)                                      -- 30 tiles from the woodcutter: inside predator_near 40
  T.eq(#pred(W), 1, 'the first time: PREDATOR')
  visit(W, 151, 1500)                                -- the same episode goes on: still the one PREDATOR
  T.eq(#pred(W), 1, 'one episode, one PREDATOR')
  leave(W, 1300)                                     -- (PREDATOR_FAR is spaced by REARM too)
  visit(W, 150, 1500)                                -- back at the same distance
  T.eq(#pred(W), 1, 'the same unit at the same distance: no second PREDATOR')
  local fr
  for _, e in ipairs(events(W, 'PREDATOR_FAR')) do if e.d.roam then fr = e end end
  T.ok(fr and fr.d.id == 400 and fr.d.roam == 1 and fr.d.dc == 30, 'PREDATOR_FAR names the roamer')
  T.ok(fr.msg:find('roamer', 1, true), fr.msg)
  T.eq(W.state().alarm.unacked, 1, 'only the first PREDATOR waits for an ack')
  leave(W)
  visit(W, 143)                                      -- 23 tiles: closer by more than the step: PREDATOR again
  T.eq(#pred(W), 2, 'closer than before: PREDATOR')
  leave(W)
  visit(W, 150)                                      -- farther again
  T.eq(#pred(W), 2, 'farther: held back')
  leave(W)
  visit(W, 133)                                      -- 13 tiles: a danger to a citizen, immediate
  T.eq(#pred(W), 3, 'within 15 tiles: PREDATOR at once')
end)

T.test('BUG-762: after the first raise the unit raises again after WANDER_DAYS, then only closer; inside Kern+ is immediate', function()
  local W = world('roamer2')
  visit(W, 150)
  T.eq(#pred(W), 1)
  leave(W, 2 * DAY)
  visit(W, 150)
  T.eq(#pred(W), 1, 'two days: still held back')
  leave(W, 3 * DAY)
  visit(W, 150)
  T.eq(#pred(W), 2, 'after WANDER_DAYS: PREDATOR again')
  leave(W, 6 * DAY)
  visit(W, 150)
  T.eq(#pred(W), 2, 'from the second raise on only closer counts')
  leave(W)
  W.move(400, 62, 72, Z)                             -- inside the fort
  S.run(W, 400)
  T.eq(#pred(W), 3, 'inside Kern+: immediate')
end)

T.test('BUG-762: a roamer that killed is a danger again at once', function()
  local W = world('roamer3')
  visit(W, 150)
  T.eq(#pred(W), 1)
  leave(W)
  visit(W, 150, 2000)
  T.eq(#pred(W), 1)
  T.eq({W.K.call('sense', 'mark_killer', 400)}, {true, true})
  S.run(W, 400)
  T.eq(#pred(W), 2, 'a killer is immediate')
end)

T.test('BUG-762 siege traffic: real invaders lock the fort down at once while a roamer is held back', function()
  local W = world('roamerarmy')
  visit(W, 150)
  leave(W)
  visit(W, 150)
  T.eq(#pred(W), 1)
  for _, u in ipairs(S.army(3, 51, 8)) do W.add_unit(u) end
  S.run(W, 200)
  local arr = events(W, 'ARRIVAL')
  T.ok(#arr >= 1 and arr[1].d.kind == 'invader', 'the army: ARRIVAL at once')
  T.ok(#events(W, 'INTRUDER') >= 1, 'INTRUDER for the army')
  T.eq(#pred(W), 1, 'the roamer stays held back')
end)

T.done()
