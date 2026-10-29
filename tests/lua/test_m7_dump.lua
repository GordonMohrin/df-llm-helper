-- FR-90 (Run 14 note 98): the garbage dump zone. zone.place type=dump (away from paths and water), inspect what=items key=trash
-- (loose items, dump jobs, zones, the reason), and the reason CANCEL_LOOP names for "Dump item cancelled 5 times today".
local T = require('testlib')
local F = require('wp8_world')
local Z = require('dfllm.zonelib')
local json = require('dfllm.util.json')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

---------------------------------------------------------------- the verb
local function zworld(opts)
  opts = opts or {}
  local cfg = F.cfg()
  if opts.zones then cfg.zones = opts.zones end
  local W = F.world{cfg = {baseline = cfg}, units = {{id = 1, citizen = true}}}
  W.tiles2 = opts.tiles or {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z)
    local t = W.tiles2[x .. ',' .. y .. ',' .. z]
    if t == false then return nil end
    return t or {c = '.', dig = '', bld = ''}
  end
  local runner = {name = 'runner', every = {ticks = 600}, verbs = {}}
  runner.verbs['zone.place'] = function(K, args, cmd) return Z.verb(K, args, cmd) end
  W.created = {}
  W.act_result('zone_place', function(spec)
    W.created[#W.created + 1] = spec
    return true, {ids = {700 + #W.created}, pond = spec.pond}
  end)
  W.load(snap)
  W.load(runner)
  return W
end

T.test('FR-90: the dump zone cell is quickfort zone key d; a name goes in', function()
  local box = {x0 = 10, y0 = 20, x1 = 12, y1 = 22, z = 5}
  T.eq((Z.cell('dump', box)), 'd(3x3)')
  T.eq((Z.cell('dump', box, 'trash')), 'd{name=trash}(3x3)')
  T.ok(Z.is_dump('Dump') and Z.is_dump('GarbageDump') and not Z.is_dump('Pen') and not Z.is_dump(nil))
end)

T.test('FR-90: zone.place type=dump draws the zone on clear floor', function()
  local W = zworld()
  local r = W.inbox('zone.place', {type = 'dump', bbox = {10, 20, 5, 12, 22, 5}, name = 'trash'})
  T.ok(r.ok, r.msg)
  T.eq(r.msg, 'dump zone 701 at 10,20-12,22 z5')
  T.eq({W.created[1].cell, W.created[1].pos, W.created[1].ztype}, {'d{name=trash}(3x3)', {10, 20, 5}, 'Dump'})
end)

T.test('FR-90: a dump zone is refused in or beside water, near a walking route, on a building', function()
  local W = zworld{tiles = {['13,21,5'] = {c = 'w'}, ['9,19,6'] = {c = '~'}, ['30,31,5'] = {c = '<'}, ['38,40,5'] = {c = '+'},
                            ['60,60,5'] = {c = '.', bld = 'Well'}, ['70,70,5'] = {c = '.', flow = 3}, ['80,80,5'] = {c = 'r'}}}
  local function refused(bbox, needle)
    local r = W.inbox('zone.place', {type = 'dump', bbox = bbox})
    T.ok(not r.ok, 'expected a refusal: ' .. tostring(r.msg))
    T.ok(r.msg:find(needle, 1, true), r.msg)
  end
  refused({10, 20, 5, 12, 22, 5}, 'tile 13,21,5 is water in or beside the box')            -- the ring, not the box
  refused({10, 20, 5, 13, 22, 5}, 'is water: only a fishing zone covers water')              -- the box itself (tiles_ok first)
  refused({69, 69, 5, 69, 69, 5}, 'tile 70,70,5 is water in or beside the box')              -- shallow flow in the ring
  refused({32, 32, 5, 34, 34, 5}, 'tile 30,31,5 is a stair, a walking route within 2 tile(s) of the box')
  refused({40, 41, 5, 41, 42, 5}, 'tile 38,40,5 is a door, a walking route within 2 tile(s)')
  refused({78, 78, 5, 79, 79, 5}, 'tile 80,80,5 is a ramp')
  refused({60, 60, 5, 61, 61, 5}, 'tile 60,60,5 holds a building (Well)')
  -- the stair at x30: gap 2 reaches x32 only; a box from x33 is clear, a pen is not held to the path rule at all
  T.ok(W.inbox('zone.place', {type = 'dump', bbox = {33, 33, 5, 34, 34, 5}}).ok, 'x30 is 3 tiles from x33')
  T.ok(W.inbox('zone.place', {type = 'pen', bbox = {32, 32, 5, 34, 34, 5}}).ok, 'a pen may lie beside a stair')
end)

T.test('FR-90: zones.dump_path_gap: 0 allows a stair beside the box, a bad value keeps 2', function()
  local W = zworld{zones = {max_tiles = 400, dump_path_gap = 0}, tiles = {['30,31,5'] = {c = '<'}}}
  T.ok(W.inbox('zone.place', {type = 'dump', bbox = {32, 32, 5, 34, 34, 5}}).ok, 'gap 0')
  T.ok(not W.inbox('zone.place', {type = 'dump', bbox = {30, 30, 5, 31, 31, 5}}).ok, 'gap 0 still refuses a stair inside the box')
  local W2 = zworld{zones = {max_tiles = 400, dump_path_gap = 99}, tiles = {['30,31,5'] = {c = '<'}}}
  T.ok(not W2.inbox('zone.place', {type = 'dump', bbox = {32, 32, 5, 34, 34, 5}}).ok, 'out of range keeps the default 2')
end)

T.test('FR-90: a dump zone does not overlap rooms, pens, ponds, meeting areas, locations or another dump zone; others not over it', function()
  local W = zworld{tiles = {['141,101,7'] = {c = '.', dig = '', bld = '', sand = true}}}   -- BUG-303: a sand zone needs a sand floor
  df.civzone_type = df.civzone_type or {}
  for _, n in ipairs({'Barracks', 'Pen', 'Dump', 'MeetingHall'}) do df.civzone_type[n] = n end
  F.building(W, 'ACTIVITY_ZONE', {id = 1, type = 'Barracks', x1 = 100, y1 = 100, x2 = 110, y2 = 105, z = 7, location_id = -1})
  F.building(W, 'ACTIVITY_ZONE', {id = 2, type = 'Pen', x1 = 120, y1 = 100, x2 = 125, y2 = 105, z = 7, location_id = -1})
  F.building(W, 'ACTIVITY_ZONE', {id = 3, type = 'Dump', x1 = 140, y1 = 100, x2 = 143, y2 = 103, z = 7, location_id = -1})
  F.building(W, 'ACTIVITY_ZONE', {id = 4, type = 'MeetingHall', x1 = 160, y1 = 100, x2 = 163, y2 = 103, z = 7, location_id = 8})
  local function refused(ty, bbox, needle)
    local r = W.inbox('zone.place', {type = ty, bbox = bbox})
    T.ok(not r.ok and r.msg:find(needle, 1, true), tostring(r.msg))
  end
  refused('dump', {105, 102, 7, 108, 104, 7}, 'overlaps zone 1 (Barracks) at 100-110,100-105 z7, which is a room zone')
  refused('dump', {122, 102, 7, 124, 104, 7}, 'zone 2 (Pen)')
  refused('dump', {142, 102, 7, 145, 104, 7}, 'zone 3 (Dump) at 140-143,100-103 z7, which has the same type')
  refused('dump', {162, 102, 7, 164, 104, 7}, 'is a location')
  refused('pen', {141, 101, 7, 142, 102, 7}, 'zone 3 (Dump)')
  refused('meeting', {141, 101, 7, 142, 102, 7}, 'which is a dump zone')
  refused('pit', {141, 101, 7, 142, 102, 7}, 'which is a dump zone')
  T.ok(W.inbox('zone.place', {type = 'sand', bbox = {141, 101, 7, 142, 102, 7}}).ok, 'a sand zone is no conflict of ours')
  T.ok(W.inbox('zone.place', {type = 'dump', bbox = {180, 100, 7, 182, 102, 7}}).ok, 'clear ground')
end)

---------------------------------------------------------------- trash: the view, inspect and the CANCEL_LOOP reason
-- a fort of citizens on walk group 1; zone tiles carry their group and building occupancy in W.tiles
local function twold(opts)
  opts = opts or {}
  local W = F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true}, {id = 2, citizen = true}}}
  df.civzone_type = df.civzone_type or {}
  for _, n in ipairs({'Dump'}) do df.civzone_type[n] = n end
  W.tiles = W.tiles or {}
  W.groups = {}
  -- the snapshot module answers the walk groups, the occupancy and "another group than the citizens" (units stand on group 1)
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
  for _, id in ipairs({1, 2}) do
    local u = W.unit(id)
    u.pos = {x = 10, y = 10, z = 5}
  end
  W.groups['10,10,5'] = 1
  for _, zn in ipairs(opts.zones or {}) do
    F.building(W, 'ACTIVITY_ZONE', {id = zn.id, type = 'Dump', x1 = zn.x1, y1 = zn.y1, x2 = zn.x2, y2 = zn.y2, z = 5, location_id = -1})
    for x = zn.x1, zn.x2 do
      for y = zn.y1, zn.y2 do
        local k = x .. ',' .. y .. ',5'
        W.groups[k] = zn.group or 1
        W.tiles[k] = {des = {}, occ = {building = (zn.built and zn.built[k]) and 7 or 0}}
      end
    end
  end
  return W
end
local function loose(W, n, spec)
  spec = spec or {}
  for _ = 1, n do
    local p = spec.pos or {x = 50, y = 50, z = 5}
    W.tiles[p.x .. ',' .. p.y .. ',' .. p.z] = W.tiles[p.x .. ',' .. p.y .. ',' .. p.z] or {des = {}, occ = {building = spec.built and 5 or 0}}
    df.global.world.items.other.IN_PLAY:insert('#', {flags = {on_ground = true, dump = spec.dump, in_building = spec.in_building},
                                                      pos = p})
  end
end

T.test('FR-90 trash.view: reasons from facts: no zone, unreachable, no free tile, ok', function()
  local TR = fresh('trash')
  local W = twold()
  local _, _, code, text = TR.view(W.K)
  T.eq(code, 'no_zone')
  T.ok(text:find('zone.place type=dump', 1, true), text)
  W = twold{zones = {{id = 31, x1 = 100, y1 = 100, x2 = 102, y2 = 102, group = 9}}}
  _, _, code, text = TR.view(W.K)
  T.eq(code, 'unreachable')
  T.ok(text:find('dump zone 31 not reachable', 1, true), text)
  local built = {}
  for x = 100, 101 do for y = 100, 101 do built[x .. ',' .. y .. ',5'] = true end end
  W = twold{zones = {{id = 32, x1 = 100, y1 = 100, x2 = 101, y2 = 101, built = built}}}
  _, _, code, text = TR.view(W.K)
  T.eq(code, 'no_free_tile')
  T.ok(text:find('every reachable tile is covered by a building (4 of 4 tiles walkable)', 1, true), text)
  W = twold{zones = {{id = 33, x1 = 100, y1 = 100, x2 = 102, y2 = 102}}}
  _, _, code, text = TR.view(W.K)
  T.eq(code, 'ok')
  T.eq(text, 'dump zone 33 is reachable with 9 free of 9 tiles')
end)

T.test('FR-90 inspect what=items key=trash: loose items, marked ones, items on the zone, dump jobs, zone, reason; read only', function()
  local W = twold{zones = {{id = 33, x1 = 100, y1 = 100, x2 = 102, y2 = 102}}}
  local E = fresh('economy')
  W.load(E)
  loose(W, 5)                                                        -- 5 loose
  loose(W, 2, {dump = true})                                          -- 2 of them marked for dumping (separate tile counts)
  loose(W, 3, {built = true, pos = {x = 60, y = 60, z = 5}})          -- on a building/stockpile tile: not loose
  loose(W, 4, {pos = {x = 101, y = 101, z = 5}})                      -- already on the dump zone
  loose(W, 1, {in_building = true})                                   -- inside a building
  local jobs = {}
  local function job(t, worker) return {item = {job_type = t, worker = worker}} end
  df.job_type.DumpItem = df.job_type.DumpItem or 99
  df.global.world.jobs = {list = {next = {item = {job_type = 99}, next = {item = {job_type = 99, w = true}, next = {item = {job_type = 5}}}}}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return j.w and {} or nil end
  local r = W.inbox('inspect', {what = 'items', key = 'trash'})
  T.ok(r.ok, r.msg)
  T.eq({r.data.loose, r.data.marked, r.data.in_zone}, {7, 2, 4})
  T.eq(r.data.jobs, {total = 2, waiting = 1})
  T.eq(#r.data.zones, 1)
  T.eq({r.data.zones[1].id, r.data.zones[1].tiles, r.data.zones[1].free, r.data.reason}, {33, 9, 9, 'ok'})
  T.ok(r.msg:find('7 loose item(s) (2 marked to dump), 4 on dump zones, 2 dump job(s) (1 waiting), 1 zone(s)', 1, true), r.msg)
  T.ok(not r.msg:find('last cancel', 1, true), 'no cancel seen yet')
  r = W.inbox('inspect', {what = 'items', key = 'garbage'})
  T.ok(not r.ok and r.msg:find('key must be trash', 1, true), r.msg)
  r = W.inbox('inspect', {what = 'items'})
  T.ok(not r.ok)
end)

T.test('FR-90 CANCEL_LOOP: a Dump item loop names the reason (no zone) in the message and d.why; other jobs are unchanged', function()
  local W = twold()
  local E = fresh('economy')
  W.load(E)
  for _ = 1, 5 do W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McHauler, Hauler cancels Dump item: Item inaccessible.'}) end
  W.run(1)
  local ev = W.find_events('CANCEL_LOOP')
  T.eq(#ev, 1)
  T.eq({ev[1].d.job, ev[1].d.n, ev[1].d.why}, {'Dump item', 5, 'no_zone'})
  T.ok(ev[1].msg:find('Dump item cancelled 5 times today: no dump zone exists: zone.place type=dump', 1, true), ev[1].msg)
  local r = W.inbox('inspect', {what = 'items', key = 'trash'})
  T.ok(r.msg:find('last cancel: Item inaccessible', 1, true), r.msg)
  T.eq(r.data.cancels, 5)
  -- another job: no reason, no why
  for _ = 1, 5 do W.event('REPORT', {type = 'CANCEL_JOB', text = 'X cancels Store Item in Stockpile: Interrupted.'}) end
  W.run(1)
  ev = W.find_events('CANCEL_LOOP')
  T.eq(#ev, 2)
  T.eq(ev[2].d.why, nil)
  T.eq(ev[2].msg, 'Store Item in Stockpile cancelled 5 times today')
end)

T.test('FR-90 CANCEL_LOOP: with a reachable zone the reason says so and the game words stay in inspect', function()
  local W = twold{zones = {{id = 33, x1 = 100, y1 = 100, x2 = 102, y2 = 102}}}
  local E = fresh('economy')
  W.load(E)
  for _ = 1, 5 do W.event('REPORT', {type = 'CANCEL_JOB', text = 'A cancels Dump item: No place to put it.'}) end
  W.run(1)
  local ev = W.find_events('CANCEL_LOOP')
  T.eq(ev[1].d.why, 'ok')
  T.ok(ev[1].msg:find('dump zone 33 is reachable with 9 free of 9 tiles', 1, true), ev[1].msg)
end)

T.done()
