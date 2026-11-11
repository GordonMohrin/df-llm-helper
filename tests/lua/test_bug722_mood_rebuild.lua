-- BUG-722 (Run 16d i4 Trumpetrealms y461: the MOOD line recommended {tpl:workshops,site:S1,p:{only:Jewelers}}, refused '0 free sites'; with p.rebuild=1
-- (BUG-562) the shop went back): a moodable shop the manifest lists as gone is asked for with rebuild=1 (one type), a shop that never stood without.
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end

local function world(gone)
  local units = {}
  for i = 1, 8 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 8 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, state = function() return {phase = 'P2'} end})
  for _, t in ipairs({'Carpenters', 'Masons', 'Craftsdwarfs', 'MetalsmithsForge', 'Bowyers', 'Clothiers', 'Leatherworks', 'Loom', 'Mechanics', 'Tanners'}) do
    F.workshop(W, t)
  end
  F.workshop(W, 'GlassFurnace', true)
  if gone then W.K.persist.set('manifest', {v = 2, gone = {{type = 'Jewelers', pos = {99, 119, 134}}}}) end
  W.load(fresh('economy'))
  settle(W)
  return W
end

T.test('BUG-722: a shop the manifest lists as gone is asked for with rebuild=1', function()
  local W = world(true)
  local care = fresh('care')
  local cmd = care.ws_fix(W.K, 'CUTGEM')
  T.ok(cmd and cmd:find('"only":"Jewelers","rebuild":1', 1, true), tostring(cmd))
end)

T.test('BUG-722: a shop that never stood is asked for as before (no rebuild)', function()
  local W = world(false)
  local care = fresh('care')
  local cmd = care.ws_fix(W.K, 'CUTGEM')
  T.ok(cmd and cmd:find('"only":"Jewelers"}}', 1, true) and not cmd:find('rebuild', 1, true), tostring(cmd))
end)

T.done()
