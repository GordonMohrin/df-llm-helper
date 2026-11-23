-- NEU1 (decision E4, docs/v2/NEU1-startset.md): lua/dfllm/startset.lua, the survival start set of week 1 (phase 0).
-- Run 16a i1 Manorsubtle (y372-y374): still, office and farm hung on the dug core, the core stalled, 20 died of thirst; Bachwald: an
-- office without table and chair, the manager validated nothing. The module asks for every missing part (PROJECT_REQUEST
-- why=startset), never twice while one is under construction, at most max_tries, then DECISION_NEEDED startset once; it hands the
-- set over to the core once the core exists and every part stands, and is idle for good after that.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local C = require('dfllm.util.contract')

local DAY = 1200
local function fresh() package.loaded['dfllm.startset'] = nil; return require('dfllm.startset') end

local function world(o)
  o = o or {}
  local W = kmock.new{cfg = {baseline = {v = 2, startset = o.cfg}},
                      persist = {manifest = o.man or {v = 2}}}
  df.workshop_type = kmock.enum({'Carpenters', 'Farmers', 'Masons', 'Craftsdwarfs', 'Jewelers', 'MetalsmithsForge',
                                 'MagmaForge', 'Bowyers', 'Mechanics', 'Siege', 'Butchers', 'Leatherworks', 'Tanners',
                                 'Clothiers', 'Fishery', 'Still', 'Loom', 'Quern', 'Kennels', 'Kitchen', 'Ashery', 'Dyers',
                                 'Millstone', 'Custom', 'Tool'})
  df.civzone_type = {Office = 7}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.df2utf = dfhack.df2utf or function(s) return s end
  W.water = o.water or {known = true, ok = true}
  local wm = {name = 'water', every = {ticks = 1200}}
  function wm.drink_access() return W.water end
  W.load(wm)
  return W
end

local function stage(n) return {getBuildStage = function() return n end, getMaxBuildStage = function() return 1 end} end
local function shop(W, t, done)
  local b = stage(done == false and 0 or 1)
  b.type = df.workshop_type[t]
  df.global.world.buildings.other.WORKSHOP_ANY:insert('#', b)
  return b
end
local function plot(W, done)
  df.global.world.buildings.other.FARM_PLOT:insert('#', stage(done == false and 0 or 1))
end
local function pile(W, name)
  local b = {name = name or 'x', settings = {flags = {food = name == nil}}}
  df.global.world.buildings.other.STOCKPILE:insert('#', b)
end
local function office(W, chair, tab)
  df.global.world.buildings.other.ACTIVITY_ZONE:insert('#', {type = df.civzone_type.Office, x1 = 10, y1 = 10, x2 = 12, y2 = 12, z = 5})
  if chair ~= nil then
    local c = stage(chair and 1 or 0); c.x1, c.y1, c.z = 10, 11, 5
    df.global.world.buildings.other.CHAIR:insert('#', c)
  end
  if tab ~= nil then
    local t = stage(tab and 1 or 0); t.x1, t.y1, t.z = 11, 11, 5
    df.global.world.buildings.other.TABLE:insert('#', t)
  end
end
local function full_set(W)
  shop(W, 'Still'); shop(W, 'Carpenters'); plot(W); pile(W); office(W, true, true)
end
local function reqs(W)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do r[#r + 1] = e end
  return r
end
local function day(W) W.run(DAY, {skip = 100}); for _ = 1, 20 do W.run(1) end end

T.test('contract: startset is a module, owns state ss.*, P0 lists the startset deliverable first', function()
  local listed = false
  for _, m in ipairs(C.MODULES) do if m.name == 'startset' then listed = true end end
  T.ok(listed, 'startset in contract.MODULES')
  T.eq(C.STATE_OWNERS['ss.*'], 'startset')
end)

T.test('a fresh embark: every missing part is requested once with why=startset, the state names them', function()
  local W = world{water = {known = true, ok = false, near = {40, 41, 5}}}
  local S = fresh()
  W.load(S)
  day(W)
  local got = {}
  for _, e in ipairs(reqs(W)) do got[e.d.tpl] = e.d end
  T.eq(got.workshops.why, 'startset')
  T.eq(got.workshops.types, {'Still', 'Carpenters'})
  T.eq(got.farms.why, 'startset'); T.eq(got.foodpile.why, 'startset'); T.eq(got.office.why, 'startset')
  T.eq(got.cistern.why, 'no_water'); T.eq(got.cistern.at, {40, 41, 5})   -- the BUG-424 route, never free digging
  local ss = W.state().ss
  T.eq(ss.d, 0); T.eq(ss.m, {'shops', 'farm', 'pile', 'office', 'water'})
  T.eq(S.done(W.K), false)
  local n = #reqs(W)
  day(W)                                                -- the next day: retry_days (7) not over, nothing asked again
  T.eq(#reqs(W), n)
end)

T.test('under construction is not asked again; built is delivered; office needs a BUILT chair and table', function()
  local W = world()
  local S = fresh()
  shop(W, 'Still', false); shop(W, 'Carpenters'); plot(W, false); pile(W, 'dfllm-start'); office(W, true, false)
  W.load(S)
  day(W)
  T.eq(#reqs(W), 0, 'shops, farm and office under construction, the pile stands')
  T.eq(W.state().ss.m, {'shops', 'farm', 'office'})
  T.eq(S.done(W.K), false)
  local W2 = world()
  local S2 = fresh()
  shop(W2, 'Still'); shop(W2, 'Carpenters'); plot(W2); pile(W2)
  office(W2)                                            -- an Office zone with no furniture at all
  W2.load(S2)
  day(W2)
  local r = reqs(W2)
  T.eq(#r, 1); T.eq(r[1].d.tpl, 'office')
  T.eq(W2.state().ss.m, {'office'})
end)

T.test('bounded: max_tries requests retry_days apart, then DECISION_NEEDED startset once', function()
  local W = world{cfg = {retry_days = 1, max_tries = 2, parts = {'pile'}}}
  local S = fresh()
  W.load(S)
  for _ = 1, 6 do day(W) end
  T.eq(#reqs(W), 2)
  local dn = W.find_events('DECISION_NEEDED')
  T.eq(#dn, 1); T.eq(dn[1].d.id, 'startset')
  T.ok(dn[1].d.cmds[1]:find('foodpile', 1, true) ~= nil, 'names the command')
  T.eq(W.state().ss.f, {'pile'})
end)

T.test('complete without a core: P0 passes, not handed over; a lost part is asked again', function()
  local W = world()
  local S = fresh()
  full_set(W)
  W.load(S)
  day(W)
  T.eq(#reqs(W), 0); T.eq(S.done(W.K), true); T.eq(W.state().ss.d, 0)
  df.global.world.buildings.other.FARM_PLOT:erase(0)      -- the plot is gone (a siege)
  day(W)
  local r = reqs(W)
  T.eq(#r, 1); T.eq(r[1].d.tpl, 'farms')
end)

T.test('hand-over: core (Z4) and every part stand -> idle for good, nothing asked when a part is lost later', function()
  local W = world{man = {v = 2, zones = {Z4 = {{0, 0, 3, 10, 10, 3}}}}}
  local S = fresh()
  full_set(W)
  W.load(S)
  day(W)
  T.eq(W.state().ss, {d = 1}); T.eq(S.done(W.K), true)
  df.global.world.buildings.other.WORKSHOP_ANY:erase(0)
  for _ = 1, 10 do day(W) end
  T.eq(#reqs(W), 0)
  T.eq(W.K.persist.get('m.startset').d, 1)
end)

T.test('fail closed: water not scanned yet is missing but not requested; a failing read asks for nothing as delivered', function()
  local W = world{water = {known = false, ok = true}}
  local S = fresh()
  full_set(W)
  W.load(S)
  day(W)
  T.eq(W.state().ss.m, {'water?'}); T.eq(S.done(W.K), false); T.eq(#reqs(W), 0)
  local f = {shops = {}, water = 'unknown'}
  local d = S.decide(f, {}, S.conf(W.K), 0)
  T.eq(d.done, nil)
  T.eq(#d.req, 4, 'shops, farm, pile, office asked; water without a tile is not')
end)

T.test('switch off: idle, the deliverable passes', function()
  local W = world{cfg = {on = false}}
  local S = fresh()
  W.load(S)
  day(W)
  T.eq(#reqs(W), 0); T.eq(W.state().ss, nil); T.eq(S.done(W.K), true)
end)

T.done()
