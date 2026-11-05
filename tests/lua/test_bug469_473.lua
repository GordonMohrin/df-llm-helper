-- BUG-471 (Run 16a i1 Basementflew): a cancelled fortcore left its refuge, burrow, stair and zones in the manifest where nothing was
-- dug. BUG-472 (i1, i4): a seal that led 'seal first' for months without closing a piece kept bedrooms and workshops paused.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

-- ---------------------------------------------------------------- BUG-471
local function manifest()
  return {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
          refuge = {anchor = {98, 87, 123}, burrow = 'Tiefe+'},
          stairs = {civ = {{98, 87, 123, 130}}},
          zones = {Z4 = {{94, 84, 123, 102, 90, 123}, {60, 60, 130, 70, 70, 130}}},
          rooms = {{id = 'refuge', bbox = {94, 84, 123, 102, 90, 123}}, {id = 'hall', bbox = {60, 60, 130, 70, 70, 130}}},
          bridges = {B2 = {role = 'inner', fp = {98, 80, 123, 100, 82, 123}}}, stations = {b2 = {97, 87, 123}}}
end
local function frag()
  local m = manifest()
  m.burrows = {['Tiefe+'] = {role = 'refuge'}}
  m.zones = {Z4 = {{94, 84, 123, 102, 90, 123}}}
  m.rooms = {m.rooms[1]}
  return m
end

T.test('BUG-471: the undug refuge, its burrow, stair, zone box, room, bridge and station leave the manifest; the dug hall stays', function()
  local man = manifest()
  local gone = runner.unmerge_manifest(man, frag(), function(x, y, z) return z == 123 end)
  T.eq(man.refuge, nil)
  T.eq(man.burrows['Tiefe+'], nil)
  T.eq(man.burrows['Kern+'], {role = 'kern'}, 'the kern burrow is not the fragment\'s')
  T.eq(man.stairs.civ, {}, 'the stair 98,87,123-130: its foot at the refuge level is undug')
  T.eq(#man.zones.Z4, 1, 'the z123 box left, the z130 box of the hall stayed')
  T.eq(man.zones.Z4[1][3], 130)
  T.eq(#man.rooms, 1)
  T.eq(man.rooms[1].id, 'hall')
  T.eq(#gone >= 3, true)
end)

T.test('BUG-471: a dug or unknown tile keeps its part; a part another project wrote differently stays', function()
  local man = manifest()
  local gone = runner.unmerge_manifest(man, frag(), function() return false end)     -- everything dug
  T.eq(#gone, 0)
  T.eq(man.refuge.anchor, {98, 87, 123})
  gone = runner.unmerge_manifest(man, frag(), function() return nil end)             -- unknown
  T.eq(#gone, 0)
  local m2 = manifest()
  m2.refuge = {anchor = {98, 87, 123}, burrow = 'Other'}
  runner.unmerge_manifest(m2, frag(), function() return true end)
  T.eq(m2.refuge.burrow, 'Other', 'not the fragment\'s refuge')
  T.eq(runner.unmerge_manifest({}, {v = 2}, function() return true end), {})
end)

T.test('BUG-471: bp.cancel of a project with an undug fragment cleans the kernel manifest (old: it stayed for ever)', function()
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = 'b471', map_size = {160, 160, 160}, persist = {manifest = manifest()}}
  -- the map reads as solid rock ('#') for the cancel, except where the test digs
  W.load(runner)
  local d = H.doc{tpl = 'fortcore', class = 'defense', x = 98, params = {stage = 3}}
  d.manifest = frag()
  H.place(W, 'fc3', d)
  H.runs(W, 1)
  T.eq(W.K.manifest().refuge.burrow, 'Tiefe+', 'a running project has merged nothing')
  local r = W.inbox('bp.cancel', {proj = 'fc3'})
  T.ok(r.ok, r.msg)
  H.runs(W, 2)
  local m = W.K.manifest()
  T.eq(m.refuge, nil, 'the phantom refuge is gone')
  T.eq(m.burrows['Tiefe+'], nil)
  T.eq(m.burrows['Kern+'], {role = 'kern'})
  T.eq(#m.zones.Z4, 1)
  local seen = false
  for _, l in ipairs(W.logs) do if l.msg:find('its undug manifest parts left the manifest', 1, true) then seen = true end end
  T.ok(seen, 'kern.log says what left')
end)

-- ---------------------------------------------------------------- BUG-472
local SX, SY, Z = 114, 73, 143
local SEAL = 'c1a147c261'

local function world(cfg)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = 'b472', map_size = {16, 16, 160}, cfg = {baseline = {v = 2, runner = cfg}}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX, SY, Z, SX, SY)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  return W
end
local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end

T.test('BUG-472: a seal that led this long without closing a piece pauses nobody; SEAL_STUCK is raised; a closed piece makes it lead again',
       function()
  -- stuck_days 60: the old clock would hold the pause for 60 days; lead_days 2 ends it after 2
  local W = world{seal_first = {stuck_days = 60, lead_days = 2}}
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 10})
  H.place(W, SEAL, {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = SX .. ',' .. SY .. ',' .. Z .. ' floor'},
                    anchor = {SX, SY, Z}, rot = 0,
                    stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                               chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, 'd'}}}}}},
                    manifest = {v = 2}, materials = {door = 1}})
  H.runs(W, 1)
  T.eq(row(W, 'bd')[4], 'paused: seal ' .. SEAL, 'the seal leads first')
  H.runs(W, 3)                                    -- 1.5 days
  T.eq(row(W, 'bd')[4], 'paused: seal ' .. SEAL, 'not yet')
  H.runs(W, 3)                                    -- 3 days: past lead_days
  H.runs(W, 1)
  T.eq(row(W, 'bd')[4], '', 'the others run again')
  T.eq(#W.find_events('SEAL_STUCK'), 1, 'the decision is raised')
  local seen = false
  for _, l in ipairs(W.logs) do if l.msg:find('led %d+ days without closing a piece') then seen = true end end
  T.ok(seen, 'kern.log says so')
  H.runs(W, 6)
  T.eq(#W.find_events('SEAL_STUCK'), 1, 'once')
  H.build(W)
  H.runs(W, 2)
  T.eq(H.proj(W, SEAL).done, 1, 'the door gets built after all')
end)

T.test('BUG-472: the default lead_days is 10 and seal_first.lead_days is read from the baseline', function()
  T.eq(runner.CFG.seal_lead_days, 10)
end)

T.done()
