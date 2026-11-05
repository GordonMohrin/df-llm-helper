-- BUG-480 (Run 16c i3 Castletongs y403): the siege popup 'With them come monstrous siege engineers!' names building destroyers.
-- reflex.announce (popup) and the REPORT path tell siege first (siege.expect_destroyers), so the first alert is the refuge's; a
-- popup without engineers or trolls changes nothing. Fixture of test_bug143_145_reflex (siege world, the real reflex).
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')

local function setup()
  local dir = H.tmpdir('b480')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{units = S.fort_units(), dfpath = dir}
  W.dir = dir
  df.building_type.Door = 23
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return 100 end}
  package.loaded['plugins.overlay'] = nil
  W.act_result('door_forbid', function(id, on) return true, false end)
  W.tiles = {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  local mil = S.military()
  W.mil = mil
  S.load(W, {mil, snap, require('dfllm.reflex'), require('dfllm.arbiter')})
  return W
end

local POPUP = 'A vile force of darkness has arrived![B]The army is commanded by the goblin Iva Showerripe, a competent ' ..
              'commander.[B]Beware their mounted goblin spearmen![B]With them come monstrous siege engineers!'

T.test('BUG-480: a siege popup naming siege engineers calls siege.expect_destroyers before the lockdown is engaged', function()
  local W = setup()
  W.run(100, {skip = 9})
  local ok, kind = W.K.call('reflex', 'announce', 'siege', POPUP, 'popup')
  T.ok(ok)
  T.ok(W.K.persist.get('m.siege').bdx ~= nil, 'siege knows: ' .. T.show(W.K.persist.get('m.siege').bdx))
  T.ok(#W.find_events('ARRIVAL') >= 1, 'the arrival came')
end)

T.test('BUG-480: a popup without engineers or trolls changes nothing; trolls count as building destroyers too', function()
  local W = setup()
  W.run(100, {skip = 9})
  W.K.call('reflex', 'announce', 'siege', 'A vile force of darkness has arrived![B]Beware their goblin spearmen!', 'popup')
  T.eq(W.K.persist.get('m.siege').bdx, nil, 'goblin spearmen only: nothing expected')
  local W2 = setup()
  W2.run(100, {skip = 9})
  W2.K.call('reflex', 'announce', 'siege', 'A vile force of darkness has arrived![B]With them come trolls!', 'popup')
  T.ok(W2.K.persist.get('m.siege').bdx ~= nil, 'trolls are building destroyers too')
  T.ok(require('dfllm.reflex').destroyer_words('MONSTROUS SIEGE ENGINEERS'))
  T.ok(not require('dfllm.reflex').destroyer_words('goblin spearmen'))
end)

T.done()
