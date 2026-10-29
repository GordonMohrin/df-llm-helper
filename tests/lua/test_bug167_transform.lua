-- BUG-167 (live i2, NEW4): LOCKDOWN #33782 'interrupt #33766 TRANSFORM unacked for 60 s: kernel applied its default:
-- clock 30 t/s' for 'Thikut Rulzas is back in dwarf form', 7,500-15,000 ticks after the wave was dead. ack_step applied
-- the TRANSFORM default by wall age alone; now it asks care's curse view first: nobody in were-form = no default.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')

local TF
local function setup(tag, care)
  local dir = H.tmpdir(tag)
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{manifest = false, units = S.fort_units(), dfpath = dir, ms_per_frame = 500}
  W.dir = dir
  df.building_type.Door = 23
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  W.tiles = {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  local mods = {S.military(), snap, require('dfllm.reflex'), require('dfllm.arbiter')}
  if care then
    local c = {name = 'care', every = {ticks = 1200}}
    function c.curse_tf(K) return TF end
    mods[#mods + 1] = c
  end
  S.load(W, mods)
  return W
end
local function lockdowns(W)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == 'LOCKDOWN' then r[#r + 1] = e end end
  return r
end
local function alarm_txt(W) return H.read(W.dir .. '/dfllm-runtime/mock/alarm.txt') or '' end

T.test('BUG-167: a TRANSFORM unacked past ack_timeout_s with nobody in were-form any more gets no default', function()
  TF = 0
  local W = setup('tf0', true)
  W.K.emit('TRANSFORM', 'A', 'Thikut Rulzas is back in dwarf form', {n = 0, dir = 'back', unit = 7})
  S.run(W, 9 * 140)                                  -- 140 frames x 0.5 s = 70 s
  T.eq(#lockdowns(W), 0, 'old code: LOCKDOWN clock 30 t/s')
  T.ok(W.settings.fps_cap ~= 30, 'no clock clamp')
  T.ok(alarm_txt(W):find('\tTRANSFORM\tfar\t', 1, true), 'done 2: ' .. alarm_txt(W))
end)

T.test('BUG-167: with a citizen in were-form the default still applies; without a curse answer it applies too', function()
  TF = 1
  local W = setup('tf1', true)
  W.K.emit('TRANSFORM', 'A', 'Oddom Letmoscog turned into a werecavy', {n = 1, dir = 'beast', unit = 7})
  S.run(W, 9 * 140)
  local l = lockdowns(W)
  T.eq({#l, l[1] and l[1].d.type, W.settings.fps_cap}, {1, 'TRANSFORM', 30})
  local W2 = setup('tfnone', false)
  W2.K.emit('TRANSFORM', 'A', 'Oddom Letmoscog turned into a werecavy', {n = 1, dir = 'beast', unit = 7})
  S.run(W2, 9 * 140)
  T.eq(#lockdowns(W2), 1, 'no care module: the cause is unknown, the default stays')
  TF = nil                                           -- care has not built its curse view since the boot
  local W3 = setup('tfnil', true)
  W3.K.emit('TRANSFORM', 'A', 'Oddom Letmoscog turned into a werecavy', {n = 1, dir = 'beast', unit = 7})
  S.run(W3, 9 * 140)
  T.eq(#lockdowns(W3), 1, 'no curse view yet: unknown, the default stays')
end)

T.test('BUG-167: curse.tf_now is nil until a view was built after the reset, then counts the were-forms', function()
  local CU = require('dfllm.curse')
  CU.reset()
  T.eq(CU.tf_now(), nil, 'after a reload, before care ran: unknown (not 0)')
end)

T.test('BUG-167: care.curse_tf counts the were-forms of the curse view (0 without one)', function()
  local CW = require('care_world')
  local W, care = CW.world{cit = 3}
  df.creature_raw = {find = function(id) return ({[1] = {name = {[0] = 'dwarf'}, creature_id = 'DWARF'}})[id] end}
  for i = 1, 3 do W.unit(i).race = 1 end
  W.unit(2)._m.name = 'Kel Becordastot, Manager'
  -- BUG-172: the boot's state publication builds the curse view from the persisted records, so it is known (0) at once
  T.eq(care.curse_tf(W.K), 0, 'before care ran: the view from the persisted records')
  W.run(3)
  T.eq(care.curse_tf(W.K), 0, 'nobody cursed')
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'Kel Becordastot, Manager has transformed into a werecavy!'})
  W.run(3)
  T.eq(care.curse_tf(W.K), 1)
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'Kel Becordastot, Werecavy has transformed into a dwarf!'})
  W.run(3)
  T.eq(care.curse_tf(W.K), 0, 'back in dwarf form')
end)

T.done()
