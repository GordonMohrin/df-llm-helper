-- BUG-133 (Run 14 region2-site90, y502-y716: ghosts 0 -> 49, 47 EngraveSlab orders removed, no memorial ever placed,
-- `tombs: freed 20, opened 0, assigned 0, entomb 0` 631 times): care's memorial phase places each ghost's loose engraved
-- slab (Build > Furniture > Slab with that slab chosen, act.slab_place) on a free roofed floor tile inside a free 3x3 near
-- the crypt, never on a way; the slab state per ghost (none, order, loose, build, placed) in GHOSTS d and inspect tombs;
-- the tomb repair knows several bodies per coffin, never frees a zone over an occupied coffin, and assigns before it
-- removes or frees; inspect tombs counts every ghost. Every test fails on dec5132.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local kmock = require('dfllm.util.k_mock')

F.ITEM_TYPES[#F.ITEM_TYPES + 1] = 'SLAB'       -- a real items_other vector the WP8 fakes do not list

local function key(x, y, z) return x .. ',' .. y .. ',' .. z end

local function floor_of(rects)
  local floor = {}
  for _, r in ipairs(rects) do
    for y = r[2], r[4] do for x = r[1], r[3] do floor[key(x, y, r[5])] = true end end
  end
  return floor
end

local function dead(W, id, ghost)
  W.kill(id)
  if ghost then W.unit(id)._m.ghost = true end
  W.event('UNIT_DEATH', {unit = id})
end

local function corpse(W, uid, pos, extra)
  local spec = {unit_id = uid, _pos = pos or {5, 5, 5}}
  for k, v in pairs(extra or {}) do spec[k] = v end
  return F.item(W, 'ANY_CORPSE', spec)
end

-- an engraved memorial slab for the historical figure hf (engraving_type Memorial = 0, topic = the figure)
local function memorial(W, hf, pos, flags)
  return F.item(W, 'SLAB', {engraving_type = 0, topic = hf, _pos = pos or {12, 12, 5}, flags = flags or {}})
end

-- the slab building act.slab_place makes (planned: the build job holds the slab; build_slabs(W) finishes them)
local function slab_acts(W)
  W.slabs_placed = {}
  if not require('dfllm.util.contract').ACT.slab_place then return end      -- dec5132: no such act (the tests say why)
  W.act_result('slab_place', function(id, x, y, z)
    local it = W.items_by_id[id]
    if not it then return false, 'no item' end
    if W.slab_refuse then return false, W.slab_refuse end
    local b = F.building(W, 'SLAB', {x1 = x, y1 = y, x2 = x, y2 = y, z = z, _st = 0})
    b.getBuildStage = function(self) return self._st end
    b.getMaxBuildStage = function() return 1 end
    -- as Buildings::constructWithItems: the slab is attached to the ConstructBuilding job, contained_items stays empty
    b.jobs = kmock.vec{{job_type = df.job_type.ConstructBuilding, items = kmock.vec{{item = it, role = 0}}}}
    b.contained_items = kmock.vec{}
    it.flags.in_job, it.flags.forbid = true, false
    W.slabs_placed[#W.slabs_placed + 1] = {id, x, y, z}
    return true, b.id
  end)
end
local function build_slabs(W)
  do
    for _, b in ipairs(df.global.world.buildings.other.SLAB) do
      b._st = 1
      local items = {}
      for _, j in ipairs(b.jobs or {}) do for _, ref in ipairs(j.items) do items[#items + 1] = {item = ref.item, use_mode = 2} end end
      b.jobs, b.contained_items = kmock.vec{}, kmock.vec(items)
      for _, ci in ipairs(b.contained_items) do ci.item.flags.in_job, ci.item.flags.in_building = false, true end
    end
  end
end

-- o: floor (rects; default the 7x7 hall 20..26 on z 5), outside (set of 'x,y,z'), ents, ghosts ({unit = hf}), cit,
--    setup(W), care (config overrides)
local function world(o)
  o = o or {}
  local floor = floor_of(o.floor or {{20, 20, 26, 26, 5}})
  local W, Cm = CW.world{
    cit = o.cit or 8, census_i = {rock = 50, wood = 40}, pending = {},
    tile = function(x, y, z) return {c = floor[key(x, y, z)] and '.' or '#', dig = '', bld = ''} end,
    snap = {
      outside_near = function(K, pts)
        local out = {}
        for i, p in ipairs(pts) do out[i] = (o.outside or {})[key(p[1], p[2], p[3])] and 1 or 0 end
        return out
      end,
      far = function(K, x, y, z) return (o.far or {})[key(x, y, z)] == true end,
    },
    setup = function(W)
      df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
      df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
      df.job_type.EngraveSlab, df.job_type[91] = 91, 'EngraveSlab'
      df.slab_engraving_type = {Slab = -1, Memorial = 0, [-1] = 'Slab', [0] = 'Memorial'}
      df.building_type.Slab, df.building_type[40] = 40, 'Slab'
      CW.tomb_acts(W)
      slab_acts(W)
      if o.ents then W.load{name = 'seal', every = {ticks = 100000}, entrances = function() return o.ents, 25 end} end
      for uid, hf in pairs(o.ghosts or {}) do
        W.unit(uid).hist_figure_id = hf
        dead(W, uid, true)
      end
      if o.setup then o.setup(W) end
      df.global.building_next_id = #df.global.world.buildings.all + 1
    end}
  W.K.cfg.baseline.care = o.care
  return W, Cm
end

local function inspect(W)
  local r = W.inbox('inspect', {what = 'tombs'})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end

local function ghost_row(d, uid)
  for _, g in ipairs(d.ghosts) do if g[1] == uid then return g end end
end

---------------------------------------------------------------- the memorial phase
T.test('BUG-133: a ghost\'s loose memorial is placed on a free roofed tile inside a free 3x3 nearest the core; ' ..
       'loose -> build -> placed in GHOSTS d and inspect tombs', function()
  local W = world{ghosts = {[7] = 7007}, setup = function(W) W.slab = memorial(W, 7007) end}
  CW.day(W)
  T.eq(W.slabs_placed, {{W.slab.id, 25, 25, 5}}, 'the core seed 25,25,5: the inner tile of the hall nearest to it')
  local g = W.find_events('GHOSTS')
  T.ok(#g >= 1, 'GHOSTS')
  T.eq({g[1].d.units, g[1].d.slabs}, {{7}, {'build'}}, 'the slab state per listed ghost')
  local d, msg = inspect(W)
  T.eq(ghost_row(d, 7), {7, 'no_body', 'build'})
  T.ok(msg:find('memorials: 1 build', 1, true), msg)
  -- review: a day later, still planned (the slab sits in the ConstructBuilding job, not in contained_items): build
  CW.day(W)
  T.eq(#W.slabs_placed, 1, 'not placed twice while planned')
  d = inspect(W)
  T.eq(ghost_row(d, 7), {7, 'no_body', 'build'}, 'the planned building\'s job holds the slab')
  build_slabs(W)
  CW.day(W)
  T.eq(#W.slabs_placed, 1, 'placed once')
  d = inspect(W)
  T.eq(ghost_row(d, 7), {7, 'no_body', 'placed'})
  T.eq(d.mem, {none = 0, order = 0, loose = 0, build = 0, placed = 1})
end)

T.test('BUG-133: never on a way: a corridor or a hall narrower than 3 gets no slab; the reason is said', function()
  local W = world{ghosts = {[7] = 7007}, floor = {{10, 25, 40, 25, 5}, {30, 20, 31, 30, 5}},
                  setup = function(W) memorial(W, 7007) end}
  CW.day(W)
  T.eq(W.slabs_placed, {})
  local d, msg = inspect(W)
  T.eq(ghost_row(d, 7), {7, 'no_body', 'loose'})
  T.ok(msg:find('no free 3x3 floor', 1, true), msg)
end)

T.test('BUG-133: open sky, a tile beside an entrance and a forbidden or held memorial: none of them; the slab is ' ..
       'unforbidden by the act (the item sheet toggle), a slab in a job is left', function()
  local out = {}
  for y = 20, 26 do for x = 20, 26 do out[key(x, y, 5)] = true end end
  local W = world{ghosts = {[7] = 7007}, outside = out, setup = function(W) memorial(W, 7007) end}
  CW.day(W)
  T.eq(W.slabs_placed, {}, 'no roof')
  local W2 = world{ghosts = {[7] = 7007}, ents = {{25, 25, 5}}, floor = {{20, 20, 26, 26, 5}, {36, 36, 42, 42, 5}},
                   setup = function(W) memorial(W, 7007) end}
  CW.day(W2)
  T.eq(#W2.slabs_placed, 1)
  local p = W2.slabs_placed[1]
  T.eq({p[2], p[3], p[4]}, {37, 37, 5}, 'the hall within coffin_entrance_r of the entrance is left out')
  local W3 = world{ghosts = {[7] = 7007}, setup = function(W) W.slab = memorial(W, 7007, nil, {in_job = true}) end}
  CW.day(W3)
  T.eq(W3.slabs_placed, {}, 'a slab a job holds (hauled) is not chosen')
  T.eq(ghost_row(inspect(W3), 7)[3], 'loose')
  local W4 = world{ghosts = {[7] = 7007}, setup = function(W) memorial(W, 7007, nil, {forbid = true}) end}
  CW.day(W4)
  T.eq(#W4.slabs_placed, 1, 'a forbidden memorial is placed (act.slab_place clears the forbid toggle)')
end)

T.test('BUG-133: the slab states: none, order (an EngraveSlab order for the figure), loose, build, placed; a refused ' ..
       'placement is tried again after a day, three times', function()
  local W = world{ghosts = {[5] = 7005, [6] = 7006, [7] = 7007}, setup = function(W)
    F.order(W, {job_type = df.job_type.EngraveSlab, amount_left = 1, specdata = {hist_figure_id = 7006}})
    memorial(W, 7007)
  end}
  W.slab_refuse = 'not reachable'
  CW.day(W)
  local d = inspect(W)
  T.eq({ghost_row(d, 5)[3], ghost_row(d, 6)[3], ghost_row(d, 7)[3]}, {'none', 'order', 'loose'})
  T.eq(d.mem, {none = 1, order = 1, loose = 1, build = 0, placed = 0})
  T.eq(#W.find_acts('slab_place'), 1)
  T.ok(inspect(W).mem_why:find('not reachable', 1, true), 'the refusal is said')
  for _ = 1, 5 do CW.day(W) end
  T.eq(#W.find_acts('slab_place'), 3, 'three tries in all')
end)

---------------------------------------------------------------- the tomb repair
T.test('BUG-133: a coffin holds two bodies: the zone of the first is not freed as "elsewhere"', function()
  local W = world{cit = 6, setup = function(W)
    local cof, zn = CW.tomb(W, 30, 10, 5, {unit = 3})
    for _, uid in ipairs({3, 4}) do
      dead(W, uid)
      corpse(W, uid, {30, 10, 5}, {flags = {in_building = true}, _holder = cof})
    end
    W.zone = zn
  end}
  CW.day(W)
  T.eq(CW.tacts(W, 'free'), {}, 'old code: freed as elsewhere, DF gave it to the next body')
  T.eq(W.zone.assigned_unit_id, 3)
end)

T.test('BUG-133: never a free over an occupied coffin (a stale owner, a bad one): DF would give the zone away again', function()
  local W = world{cit = 6, setup = function(W)
    local cof = CW.tomb(W, 30, 10, 5, {unit = 5})                -- unit 5: dead, no remains (stale)
    dead(W, 5)
    dead(W, 4)
    corpse(W, 4, {30, 10, 5}, {flags = {in_building = true}, _holder = cof})
    CW.tomb(W, 32, 10, 5, {unit = 3})                             -- unit 3's own zone over a coffin holding unit 2
    local cof2 = df.global.world.buildings.other.COFFIN[1]
    dead(W, 2)
    corpse(W, 2, {32, 10, 5}, {flags = {in_building = true}, _holder = cof2})
    dead(W, 3)
    corpse(W, 3, {8, 8, 5})
  end}
  CW.day(W)
  T.eq(CW.tacts(W, 'free'), {})
  T.eq(inspect(W).acts.kept_occ, 2, 'the frees left out are counted')
end)

T.test('BUG-133: assignments have their own budget ahead of removals and frees (old: removed 20, assigned 0)', function()
  local W = world{cit = 8, setup = function(W)
    for i = 0, 24 do CW.tomb(W, 40 + i, 30, 5, {coffin = false}) end      -- 25 1x1 zones without a coffin
    for i = 0, 2 do CW.tomb(W, 30 + i, 10, 5) end                         -- three free tombs
    for _, uid in ipairs({3, 4, 5}) do dead(W, uid); corpse(W, uid, {8, 8, 5}) end
  end}
  W.run(2)
  CW.day(W)
  local first = W.find_acts('tomb_zone')
  local assigned, removed = 0, 0
  for i, a in ipairs(first) do
    if a.args[1] == 'assign' then assigned = assigned + 1 end
    if a.args[1] == 'remove' then removed = removed + 1 end
    if i == 3 then T.eq(assigned, 3, 'the three assignments come first') end
  end
  T.eq(assigned, 3)
  T.ok(removed >= 17, 'the removals follow on their own budget: ' .. removed)
end)

---------------------------------------------------------------- the ghost count
T.test('BUG-133: inspect tombs counts every ghost (28, not the 20 listed) and says how many more there are', function()
  local W = world{cit = 6}
  local ids = {}
  for i = 0, 27 do ids[#ids + 1] = 100 + i end
  W.K.census.g = {tick = W.K.now().tick, n = #ids, ids = ids}
  CW.day(W)
  W.K.census.g.tick = W.K.now().tick
  CW.day(W)
  local d, msg = inspect(W)
  T.eq({d.ghosts_n, #d.ghosts}, {28, 20})
  T.ok(msg:find('28 ghosts (+8 more not listed)', 1, true), msg)
end)

T.done()
