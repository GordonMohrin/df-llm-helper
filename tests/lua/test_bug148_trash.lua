-- BUG-148 (live test i1, 2026-10-28): `inspect what=items key=trash` said "ok" while 1056 items were marked to dump and the
-- game made no DumpItem job for 1.5 game months, and it named the first (2-tile) zone instead of the 12-tile one. A zone
-- placed by zone.place (quickfort) kept site_realization_building_id/sul_id 0, the game's zones have -1.
local T = require('testlib')
local F = require('wp8_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local actlib = require('dfllm.act')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

-- citizens on walk group 1; zone tiles carry their group and building occupancy (as in tests/lua/test_m7_dump.lua)
local function twold(zones)
  local W = F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true}, {id = 2, citizen = true}}}
  df.civzone_type = df.civzone_type or {}
  df.civzone_type.Dump = 'Dump'
  W.tiles, W.groups = {}, {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  local function key(p) return p[1] .. ',' .. p[2] .. ',' .. p[3] end
  function snap.groups(K, pts) local o = {} for i, p in ipairs(pts) do o[i] = W.groups[key(p)] or 0 end return o end
  function snap.occupied(K, pts)
    local o = {}
    for i, p in ipairs(pts) do local t = W.tiles[key(p)]; o[i] = t and t.occ.building or -1 end
    return o
  end
  function snap.far(K, x, y, z) local g = W.groups[key({x, y, z})]; return g ~= nil and g ~= 0 and g ~= 1 end
  W.load(snap)
  for _, id in ipairs({1, 2}) do W.unit(id).pos = {x = 10, y = 10, z = 5} end
  W.groups['10,10,5'] = 1
  for _, zn in ipairs(zones or {}) do
    F.building(W, 'ACTIVITY_ZONE', {id = zn.id, type = 'Dump', x1 = zn.x1, y1 = zn.y1, x2 = zn.x2, y2 = zn.y2, z = 5, location_id = -1})
    for x = zn.x1, zn.x2 do
      for y = zn.y1, zn.y2 do
        local k = x .. ',' .. y .. ',5'
        W.groups[k] = 1
        W.tiles[k] = {des = {}, occ = {building = 0}}
      end
    end
  end
  df.job_type.DumpItem = df.job_type.DumpItem or 99
  df.global.world.jobs = {list = {next = nil}}
  return W
end

local function item(W, spec)
  local p = spec.pos or {x = 50, y = 50, z = 5}
  local k = p.x .. ',' .. p.y .. ',' .. p.z
  W.tiles[k] = W.tiles[k] or {des = {}, occ = {building = 0}}
  if spec.group then W.groups[k] = spec.group end
  df.global.world.items.other.IN_PLAY:insert('#', {flags = {on_ground = true, dump = spec.dump, forbid = spec.forbid,
                                                            in_building = spec.in_building}, pos = p})
end

T.test('BUG-148: marked items and no dump job: the reason is no_jobs instead of ok, and the counts say what keeps them', function()
  local W = twold{{id = 24812, x1 = 100, y1 = 100, x2 = 101, y2 = 100}, {id = 26126, x1 = 110, y1 = 110, x2 = 113, y2 = 112}}
  local E = fresh('economy')
  fresh('trash')
  W.load(E)
  for _ = 1, 4 do item(W, {dump = true}) end
  item(W, {dump = true, forbid = true})
  item(W, {dump = true, pos = {x = 70, y = 70, z = 5}, group = 6})          -- on another walk group: nobody walks there
  item(W, {dump = true, in_building = true})                                  -- marked, but inside a building
  item(W, {})
  local r = W.inbox('inspect', {what = 'items', key = 'trash'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.reason, 'no_jobs')                                              -- main: 'ok'
  T.eq({r.data.marked, r.data.marked_forbid, r.data.marked_far, r.data.marked_bld}, {6, 1, 1, 1})
  T.ok(r.msg:find('no dump job for 6 marked (1 forbidden, 1 off the walk group, 1 in a building): check refuse hauling',
                  1, true), r.msg)
  T.ok(#r.msg < 300, 'the reply cap (300) keeps it whole')
  T.ok(r.msg:find('dump zone 26126 is reachable with 12 free of 12 tiles', 1, true), 'the bigger zone is named: ' .. r.msg)
end)

T.test('BUG-148: with a dump job or nothing marked the reason stays ok; the view names the zone with the most free tiles', function()
  local W = twold{{id = 1, x1 = 100, y1 = 100, x2 = 101, y2 = 100}, {id = 2, x1 = 110, y1 = 110, x2 = 112, y2 = 110}}
  local E = fresh('economy')
  local TR = fresh('trash')
  W.load(E)
  local _, _, code, text = TR.view(W.K)
  T.eq({code, text}, {'ok', 'dump zone 2 is reachable with 3 free of 3 tiles'})
  item(W, {})
  local r = W.inbox('inspect', {what = 'items', key = 'trash'})
  T.eq(r.data.reason, 'ok')
  item(W, {dump = true})
  df.global.world.jobs = {list = {next = {item = {job_type = 99}}}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function() return nil end
  r = W.inbox('inspect', {what = 'items', key = 'trash'})
  T.eq(r.data.reason, 'ok', r.msg)
end)

T.test('BUG-148: a zone from zone.place gets site_realization_building_id/sul_id -1 like a zone the player draws', function()
  local W = H.world{tag = 'zp148'}
  local zones = kmock.vec{}
  df.global.world.buildings.other.ACTIVITY_ZONE = zones
  zones:insert('#', {id = 5, site_realization_building_id = 3, site_realization_sul_id = 4})     -- an old zone: untouched
  W.scripts['quickfort'] = {apply_blueprint = function()
    zones:insert('#', {id = 101, site_realization_building_id = 0, site_realization_sul_id = 0})
    return {zone_designated = {label = 'Zones designated', value = 1}}
  end}
  local api = actlib.new{who = function() return 'runner' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
                         log_cmd = function() end, fail = function() end}
  local ok, res = api.zone_place({cell = 'd(4x3)', pos = {10, 20, 5}})
  T.ok(ok)
  T.eq(res.ids, {101})
  T.eq({zones[1].site_realization_building_id, zones[1].site_realization_sul_id}, {-1, -1})   -- main: 0, 0
  T.eq({zones[0].site_realization_building_id, zones[0].site_realization_sul_id}, {3, 4})
end)

T.done()
