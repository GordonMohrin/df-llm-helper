-- M2 / BUG-108 (Run 14 note 88): an unacked DEATHS_3PLUS at threat 0 starts no lockdown (no clock clamp, no civ alert);
-- with a visible hostile, or when the config lists no inner types, the old default applies.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local function setup(opts)
  opts = opts or {}
  local dir = H.tmpdir(opts.tag or 'm2l')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{manifest = false, units = opts.units or S.fort_units(), dfpath = dir, cfg = opts.cfg,
                    ms_per_frame = 500}
  W.dir = dir
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  W.tiles = {}
  for x = 40, 70 do W.tiles[x .. ',7,' .. Z] = {des = {outside = true}} end
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
local function alarm_txt(W) return H.read(W.dir .. '/dfllm-runtime/mock/alarm.txt') end

local function unacked_deaths(W)
  W.K.emit('DEATHS_3PLUS', 'A', '3 citizens died today', {n = 3, ids = {1, 2, 3}})
  S.run(W, 20)
  S.run(W, 9 * 140)                                   -- 140 frames x 0.5 s = 70 s: past ack_timeout_s (60)
end

T.test('BUG-108: unacked DEATHS_3PLUS at threat 0: no lockdown, no clock clamp, no civ alert; the event woke the player', function()
  local W = setup{tag = 'm2l1'}
  unacked_deaths(W)
  T.eq(#events(W, 'LOCKDOWN'), 0, 'no LOCKDOWN event')
  T.eq(W.state().alarm.lock, 0, 'no lockdown held')
  T.ok(W.settings.fps_cap ~= 30, 'the FPS is not clamped to the siege cap')
  T.ok(W.timestream_fps ~= -1, 'the timestream is not taken over by the clock clamp')
  T.eq(#S.pulls(W), 0)
  local ok, why = W.K.call('reflex', 'holding')
  T.eq({ok, why}, {true, nil}, 'nothing holds')
  T.ok(alarm_txt(W):find('\tDEATHS_3PLUS\tfar\t'), 'alarm.txt: no default applied: ' .. alarm_txt(W))
  T.eq(#events(W, 'DEATHS_3PLUS'), 1)
end)

T.test('BUG-108: a visible hostile keeps the old default (LOCKDOWN, clock 30), threat 0 does not', function()
  local W0 = setup{tag = 'm2l2a'}
  unacked_deaths(W0)
  T.eq(#events(W0, 'LOCKDOWN'), 0, 'threat 0: none')
  local units = S.fort_units()
  units[#units + 1] = S.danger(400, 45, 7)           -- a wild danger on the open surface, in sight
  local W = setup{tag = 'm2l2', units = units}
  unacked_deaths(W)
  local l = events(W, 'LOCKDOWN')
  T.eq(#l, 1)
  T.eq({l[1].d.why, l[1].d.type}, {'ack_timeout', 'DEATHS_3PLUS'})
  T.eq(W.settings.fps_cap, 30)
end)

T.test('BUG-108: reflex.inner: a bad entry keeps the built-in list; [] or another type keep the old default', function()
  local W = setup{tag = 'm2l4', cfg = {reflex = {v = 2, inner = {'NOPE'}}}}
  unacked_deaths(W)
  T.eq(#events(W, 'LOCKDOWN'), 0, 'bad entry: DEATHS_3PLUS stays inner')
  W = setup{tag = 'm2l3', cfg = {reflex = {v = 2, inner = {}}}}
  unacked_deaths(W)
  T.eq(#events(W, 'LOCKDOWN'), 1, '[]: the old rule')
  T.eq(W.settings.fps_cap, 30)
  W = setup{tag = 'm2l5', cfg = {reflex = {v = 2, inner = {'INTRUDER'}}}}
  unacked_deaths(W)
  T.eq(#events(W, 'LOCKDOWN'), 1, 'DEATHS_3PLUS not listed: its default applies')
end)

T.done()
