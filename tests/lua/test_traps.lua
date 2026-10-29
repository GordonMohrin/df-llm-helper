-- FR-96/97 (goal G14): the trap upkeep module. Counts the manifest's trap tiles against the trap buildings (status
-- `traps N/M`), the ways whose lane is complete, full cage traps (census caged -> cage -> holder building), free cages,
-- lost traps; orders wooden cages in PEACE only, once per live order. Fails on 64df679 (no module traps).
local T = require('testlib')
local F = require('wp8_world')
local C = require('dfllm.util.contract')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function day(W) W.run(1200, {skip = 100}); settle(W) end

local MAN = {v = 2, zones = {Z2 = {{10, 20, 5, 14, 20, 5}}},
             traps = {{id = 'T30_30_5', kind = 'cage', way = {30, 30, 5}, tiles = {{30, 29, 5}, {29, 29, 5}, {31, 29, 5}}},
                      {id = 'T40_30_5', kind = 'cage', way = {40, 30, 5}, tiles = {{40, 29, 5}}},
                      {id = 'Z2', kind = 'stone', tiles = {{11, 20, 5}, {12, 20, 5}, {13, 20, 5}}}}}

local function trap(W, x, y, z, kind, spec)
  spec = spec or {}
  local b = F.building(W, 'TRAP', {centerx = x, centery = y, z = z, trap_type = df.trap_type[kind],
                                   ready_timeout = spec.rt or 0, contained_items = spec.items or {},
                                   getBuildStage = function() return spec.stage or 1 end,
                                   getMaxBuildStage = function() return 1 end})
  return b
end

local function world(opts)
  opts = opts or {}
  local W = F.world{persist = {manifest = opts.man or MAN}, units = opts.units}
  df.trap_type = require('dfllm.util.k_mock').enum({'Lever', 'PressurePlate', 'CageTrap', 'StoneFallTrap', 'WeaponTrap',
                                                    'TrackStop'})
  df.item_cagest = {is_instance = function(_, it) return type(it) == 'table' and it._cage == true end}
  W.set_census('u', F.census_u({}, {caged = opts.caged or {}}))
  return W
end

local function cage(W, spec) spec = spec or {}; spec._cage = true; return F.item(W, 'CAGE', spec) end

T.test('contract: traps is a module, owns state traps.*, may give work orders', function()
  local listed = false
  for _, m in ipairs(C.MODULES) do if m.name == 'traps' then listed = true end end
  T.ok(listed, 'traps in contract.MODULES')
  T.eq(C.STATE_OWNERS['traps.*'], 'traps')
  local can = false
  for _, o in ipairs(C.ACT.workorder) do if o == 'traps' then can = true end end
  T.ok(can, 'workorder owner')
end)

T.test('tally: armed of listed, built, ways trapped, lost hall tiles; status key valid', function()
  local W = world()
  for _, t in ipairs({{30, 29}, {29, 29}, {31, 29}}) do trap(W, t[1], t[2], 5, 'CageTrap', {items = {{item = cage(W, {flags = {in_building = true}})}}}) end
  trap(W, 40, 29, 5, 'CageTrap', {stage = 0})                          -- planned, not built yet
  trap(W, 11, 20, 5, 'StoneFallTrap')
  trap(W, 12, 20, 5, 'StoneFallTrap', {rt = 50})                       -- re-arming
  W.load(fresh('traps'))
  day(W)
  local s = W.state().traps
  T.eq({s.n, s.m, s.b, s.w, s.wn, s.l, s.lh, s.f}, {4, 7, 5, 1, 2, 1, 1, 0})
  T.eq(C.check_state(W.state()), {})
end)

T.test('a cage trap that caught a goblin is full; cages are ordered in PEACE (wood, tagged), once per live order', function()
  local W = world({units = {{id = 7, invader = true}}, caged = {7}})
  local held = {}
  for i, t in ipairs({{30, 29}, {29, 29}, {31, 29}}) do
    local c = cage(W, {flags = {in_building = true}})
    held[i] = trap(W, t[1], t[2], 5, 'CageTrap', {items = {{item = c}}})
    c._holder = held[i]
    if i == 1 then W.unit(7)._cage = c end
  end
  W.load(fresh('traps'))
  day(W)
  local s = W.state().traps
  T.eq({s.f, s.c, s.n}, {1, 0, 2})
  local orders = W.find_acts('workorder')
  T.eq(#orders, 1)
  local spec = orders[1].args[1]
  T.eq({spec.job, spec.amount_total, spec.tag, spec.material_category}, {'MakeCage', 3, 'dfllm:traps', {'wood'}})
  T.eq(s.ord, 'MakeCage x3 ordered')
  for _ = 1, 3 do day(W) end
  T.eq(#W.find_acts('workorder'), 1, 'the live order is not repeated')
end)

T.test('no order outside PEACE, none with enough free cages, none without cage traps', function()
  local W = world({units = {{id = 7, invader = true}}, caged = {7}})
  local c = cage(W, {flags = {in_building = true}})
  local b = trap(W, 30, 29, 5, 'CageTrap', {items = {{item = c}}})
  c._holder = b
  W.unit(7)._cage = c
  W.set_mode('SIEGE')
  W.load(fresh('traps'))
  day(W)
  T.eq(#W.find_acts('workorder'), 0, 'SIEGE: the kernel orders nothing')
  W.set_mode('PEACE')
  for _ = 1, 3 do cage(W) end                                          -- 3 free cages >= 1 full + 2 spare
  day(W)
  T.eq(#W.find_acts('workorder'), 0, 'enough free cages')
  local W2 = world({man = {v = 2, traps = {{id = 'Z2', kind = 'stone', tiles = {{11, 20, 5}}}}}})
  trap(W2, 11, 20, 5, 'StoneFallTrap')
  W2.load(fresh('traps'))
  day(W2)
  T.eq(#W2.find_acts('workorder'), 0, 'no cage traps: no cages')
  T.eq({W2.state().traps.n, W2.state().traps.m}, {1, 1})
end)

T.test('a fort without listed traps publishes no traps key; need() counts the lost tiles', function()
  local W = world({man = {v = 2}})
  local mod = fresh('traps')
  W.load(mod)
  day(W)
  T.eq(W.state().traps, nil)
  local W2 = world()
  local m2 = fresh('traps')
  W2.load(m2)
  day(W2)
  T.eq(select(2, W2.K.call('traps', 'need')), 7)
end)

T.test('cage_need: full + without a cage + spare - free, capped by the batch', function()
  local M = fresh('traps')
  local c = {cage_spare = 2, cage_batch = 5}
  T.eq(M.cage_need({cages = 0, f = 3}, 0, c), 0)
  T.eq(M.cage_need({cages = 4, f = 1, nocage = 1}, 1, c), 3)
  T.eq(M.cage_need({cages = 9, f = 6, nocage = 3}, 0, c), 5)
  T.eq(M.cage_need({cages = 2, f = 0, nocage = 0}, 5, c), 0)
end)

T.done()
