-- BUG-937 (Run 17 i3 y500 #53454: a megacerops, a big plant eater (sense hb) inside the fort; the ack came ~22 s after the event, the 10 s quick default of
-- BUG-729 had already clamped the clock and recalled everybody): the quick default is for animals that can kill; a plant eater that never killed waits
-- the full ack_timeout_s, a smilodon-like animal keeps the 10 s. Plus the sortie half: tests/lua/test_bug937_sortie_alert.lua.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local function setup(tag, units, bridges)
  local dir = H.tmpdir(tag)
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{manifest = (not bridges) and false or nil, units = units, dfpath = dir, ms_per_frame = 500}
  W.dir = dir
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  W.tiles = {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  S.load(W, {S.military(), snap, require('dfllm.reflex'), require('dfllm.arbiter')})
  return W
end
local function events(W, t)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == t then r[#r + 1] = e end end
  return r
end

local function herbivore_world(tag, race)
  local units = S.fort_units()
  units[#units + 1] = S.danger(400, 62, 72, Z, {race = race or 'STEGOSAURUS'})
  local W = setup(tag, units)
  W.unit(400).body = {size_info = {size_cur = 301263}}
  dfhack.maps.getWalkableGroup = function() return 7 end
  W.tiles = W.tiles or {}
  W.tiles['62,72,' .. Z] = {des = {outside = false, hidden = false}}      -- roofed, revealed (BUG-439: a big wild unit counts there)
  return W
end

T.test('BUG-937: a plant eater inside the fort does not get the 10 s default; the ack at ~20 s is honoured (no LOCKDOWN)', function()
  local W = herbivore_world('p937a')
  S.run(W, 36)
  local p = events(W, 'PREDATOR')
  T.eq(#p, 1)
  T.eq(p[1].d.hb, 1, 'the census marks it a plant eater')
  S.run(W, 330)                                          -- ~20 s of frames: the old rule fired at 10 s
  T.eq(#events(W, 'LOCKDOWN'), 0, 'no default after 20 s')
  W.inbox('ack', {})
  S.run(W, 1200)                                         -- well past 60 s
  T.eq(#events(W, 'LOCKDOWN'), 0, 'the ack was honoured: no default at all')
end)

T.test('BUG-937: an unacked plant eater still gets its default at ack_timeout_s (60 s), nothing is dropped', function()
  local W = herbivore_world('p937b')
  S.run(W, 330)
  T.eq(#events(W, 'LOCKDOWN'), 0)
  S.run(W, 900)
  local l = events(W, 'LOCKDOWN')
  T.ok(#l >= 1 and l[1].d.why == 'ack_timeout', 'the 60 s default came: ' .. #l)
end)

T.test('BUG-937: an animal that killed (hb gone) keeps the quick 10 s default (BUG-729 unchanged)', function()
  local W = herbivore_world('p937c')
  T.eq({W.K.call('sense', 'mark_killer', 400)}, {true, true})
  S.run(W, 36)
  S.run(W, 300)
  local l = events(W, 'LOCKDOWN')
  T.ok(#l >= 1 and l[1].d.why == 'ack_timeout', 'the quick default came: ' .. #l)
end)

T.done()
