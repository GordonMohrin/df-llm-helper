-- Round 50 (no wood, no hard stone), offline, live-untested.
-- BUG-772 (Run 16c i3 Lancemoment y372: an embark of limestone only, 36 flux boulders, doors / coffins / tables waited; `stone.use limestone` cleared the
-- economic mark and the census still counted the freed stone as flux): a freed flux stone is a plain building stone; a fort with no ore frees its
-- biggest hard flux stone itself.
-- BUG-772 (same fort: no tree): barrels and bins are wood only, named so with the trade request; the drink goes into large pots of rock.
-- BUG-733 (Run 16b i2 Whirledrampart y431: explore done, CLAYSTONE / CHERT dug, 'stone free 0 need 29-32' for 65 days): an unusable boulder (ore, flux,
-- economic, soft, refused) is counted once (rock_nouse, not max(ore + flux, rock_bad)), and a fort with no free stone says where its boulders went
-- (workload stone.why, kern.log 'stone free 0').
-- BUG-734 (Run 16c i3 Doorwings y385-y386: `trade.want stone` bought 'stone BOULDER x4' of magnetite / chalk / clay every caravan, stone.free stayed 0):
-- a plain stone want skips ore, flux, economic and soft boulders; the stone-use setting is the player's through the verb stone.use, named in the
-- no_hard_stone decision when the fort holds only such stone.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')


local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

local function job_list(jobs)
  local head, cur = {}, nil
  cur = head
  for _, j in ipairs(jobs) do
    cur.next = {item = j}
    cur = cur.next
  end
  df.global.world.jobs = {list = head}
end

-- a wall (building material) waiting at x,50,109
local function wall(id, n, x)
  local b = {id = 500 + id, x1 = x or 20, y1 = 50, x2 = x or 20, y2 = 50, z = 109,
             getType = function() return df.building_type.Construction end, getBuildStage = function() return 0 end}
  return {id = id, job_type = df.job_type.ConstructBuilding, flags = {suspend = true}, _holder = b, items = kmock.vec{},
          job_items = {elements = kmock.vec{{item_type = -1, mat_type = -1, mat_index = -1, quantity = n or 1,
                                             flags2 = {building_material = true}}}}}
end

-- opts: boulders (material 7, z 1), chert (material 9, z 1), nowalk (z 38: a tile with no walkable group), busy (in a job), logs, refuse (set of
-- material indexes the game's own filter refuses), bp (buildingplan settings), jobs, rock_orders, setup
local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, 20 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'ConstructBuilding', 'Dig', 'MakeWeapon', 'HarvestPlants'})
  local ids = {}
  for i = 1, 20 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
  end
  W.set_census('u', F.census_u(ids))
  df.global.plotinfo.main = {fortress_entity = {positions = {
    own = kmock.vec{{id = 3, code = 'MANAGER', flags = {ACTIVE = true}}},
    assignments = kmock.vec{{id = 1, position_id = 3, histfig = 5769, histfig2 = 5769}}}}}
  W.unit(2).hist_figure_id = 5769
  dfhack.items.getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end
  dfhack.job.getWorker = function(j) return j._worker end
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = {isPlannedBuilding = function() return true end,
                                            getGlobalSettings = function()
                                              return opts.bp or {blocks = true, boulders = true, logs = true, bars = false}
                                            end}
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  for _ = 1, opts.logs or 0 do F.item(W, 'WOOD', {mat_type = 420, mat_index = 0}) end
  for _ = 1, opts.boulders or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end
  for _ = 1, opts.chert or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 9, _pos = {5, 6, 1}}) end
  for _ = 1, opts.nowalk or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {6, 6, 38}}) end
  for _ = 1, opts.busy or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 7, 1}, flags = {in_job = true}}) end
  for _, name in ipairs({'Masons', 'Carpenters', 'Mechanics'}) do F.workshop(W, name) end
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          state = function() return {phase = 'P1'} end})
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.items_at() return {} end
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far(K, x, y, z, strict) return z == 37 or (strict == true and z == 38) end
  function snap.reach() return true end
  function snap.outside_near(K, pts) local r = {}; for i = 1, #pts do r[i] = 0 end; return r end
  W.load(snap)
  -- two hard building stones (raws: ITEMS_HARD, no ore, no flux), not marked economic
  local d0 = dfhack.matinfo.decode
  dfhack.matinfo.decode = function(t, i)
    local m = d0(t, i)
    if m and t == 0 then m.inorganic = {metal_ore = {mat_index = {}}}; m.material.reaction_class = {} end
    return m
  end
  F.mat(W, 0, 7, {token = 'INORGANIC:SANDSTONE', flags = {ITEMS_HARD = true}})
  F.mat(W, 0, 9, {token = 'INORGANIC:CHERT', flags = {ITEMS_HARD = true}})
  df.global.plotinfo.economic_stone = {}
  if opts.refuse then            -- act.mat_refused: the game's own verdict (DFHack's isSuitableMaterial on a non_economic + hard BOULDER filter)
    W.act_result('mat_refused', function(idx) return opts.refuse[idx] == true end)
  end
  W.act_result('stone_economic', function(idx, on) return true, 'cleared' end)
  local one = df.workquota_frequency_type.OneTime
  if (opts.rock_orders or 0) > 0 then
    F.order(W, {job_type = df.job_type.ConstructTable, mat_type = 0, mat_index = -1, amount_left = opts.rock_orders,
                amount_total = opts.rock_orders, frequency = one, material_category = {}, _name = 'Construct rock Table'})
  end
  if opts.setup then opts.setup(W) end
  job_list(opts.jobs and opts.jobs() or {})
  local eco = fresh('economy')
  if opts.ask_df == false then eco.ASK_DF = false end
  W.load(eco)
  return W
end

local function decisions(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function stock(W) return select(2, W.K.call('economy', 'wall_stock')) end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l.msg end end
end
local function cancel(W, n)
  for _ = 1, n or 1 do
    W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Mechanic cancels Make rock mechanisms: Needs non-economic hard stone boulders.'})
  end
  settle(W)
end

-- materials: 7 sandstone (plain), 11 magnetite (ore, marked economic), 12 chalk-like flux stone (reaction class FLUX), 13 clay-stone marked economic only
local function mats(W)
  local d0 = dfhack.matinfo.decode
  dfhack.matinfo.decode = function(t, i)
    local m = d0(t, i)
    if m and t == 0 and i == 11 then m.inorganic = {metal_ore = {mat_index = {1}}} end
    if m and t == 0 and i == 12 then m.material.reaction_class = {{value = 'FLUX'}} end
    return m
  end
  F.mat(W, 0, 11, {token = 'INORGANIC:MAGNETITE', flags = {ITEMS_HARD = true}})
  F.mat(W, 0, 12, {token = 'INORGANIC:CHALK', flags = {ITEMS_HARD = true}})
  F.mat(W, 0, 13, {token = 'INORGANIC:CLAYSTONE', flags = {ITEMS_HARD = true}})
  df.global.plotinfo.economic_stone = {[11] = 1, [13] = 1}
end
local function boulders(W, mi, n, pos)
  for _ = 1, n do F.item(W, 'BOULDER', {mat_type = 0, mat_index = mi, _pos = pos or {5, 5, 1}}) end
end


local function sync_free(W) days(W, 1) end

T.test('BUG-772: a flux-only fort (no ore, no plain stone) frees its flux stone itself; the masons get it at the next census', function()
  local calls = {}
  local W = world{logs = 10, rock_orders = 40, setup = function(W)
    mats(W)
    boulders(W, 12, 36)          -- chalk-like flux stone, 36 boulders
    df.global.plotinfo.economic_stone = {}
  end}
  W.act_result('stone_economic', function(idx, on) calls[#calls + 1] = {idx, on}; return true, 'cleared' end)
  days(W, 1)
  T.eq(stock(W).rock, 0, 'flux is no furniture stone to begin with')
  days(W, 2)
  T.eq(calls[1], {12, false}, 'the economy cleared the mark itself: ' .. T.show(calls))
  T.ok(logged(W, 'freed for doors, coffins, tables, chairs and blocks'), 'kern.log names it')
  days(W, 1)
  T.eq(stock(W).rock, 36, 'the next census counts the 36 boulders usable')
  T.eq(#decisions(W, 'no_hard_stone'), 0, 'no decision is needed any more')
end)

T.test('BUG-772: with ore in the fort the flux stone is kept (steel); stone.use frees it by hand and the census counts it', function()
  local calls = {}
  local W = world{logs = 10, rock_orders = 40, setup = function(W)
    mats(W)
    boulders(W, 12, 36)          -- flux
    boulders(W, 11, 12)          -- magnetite: iron ore
    df.global.plotinfo.economic_stone = {}
  end}
  W.act_result('stone_economic', function(idx, on) calls[#calls + 1] = {idx, on}; return true, 'cleared' end)
  days(W, 4)
  T.eq(#calls, 0, 'ore in the fort: no automatic freeing: ' .. T.show(calls))
  T.eq(stock(W).rock, 0)
  local r = W.inbox('stone.use', {mat = 'chalk'})
  T.ok(r and r.ok, T.show(r))
  days(W, 1)
  T.eq(stock(W).rock, 36, 'freed by stone.use: the 36 flux boulders count')
  local r2 = W.inbox('stone.use', {mat = 'chalk', economic = true})
  T.ok(r2 and r2.ok, T.show(r2))
  days(W, 1)
  T.eq(stock(W).rock, 0, 'marked economic again: no furniture stone')
end)

T.test('BUG-772: the freed flux stone survives a reload of the economy module (persisted in m.economy)', function()
  local W = world{logs = 10, setup = function(W)
    mats(W)
    boulders(W, 12, 20)
    boulders(W, 11, 3)
    df.global.plotinfo.economic_stone = {}
  end}
  days(W, 1)
  local r = W.inbox('stone.use', {mat = 'chalk'})
  T.ok(r and r.ok, T.show(r))
  local list = W.K.persist.get('m.economy').freed
  T.eq(list, {12}, T.show(list))
  local eco = fresh('economy')
  eco.init(W.K)
  T.eq(eco.freed[12], true, 'init reads the persisted list')
end)

T.test('BUG-772: a treeless fort with no empty barrel: barrels and bins are named wood-only, the caravans are asked for logs, pots are ordered', function()
  local W = world{logs = 0, setup = function(W)
    mats(W)
    boulders(W, 7, 30)
    df.global.world.items.other.BARREL = kmock.vec{}
    df.global.world.items.other.DRINK = kmock.vec{}        -- no drink: brewing is due
    F.workshop(W, 'Craftsdwarfs')
  end}
  W.act_result('stone_economic', function(idx, on) return true, 'cleared' end)
  days(W, 24)
  local sw = select(2, W.K.call('economy', 'supply_wants'))
  local wood
  for _, w in ipairs(type(sw) == 'table' and sw or {}) do if w.buy == 'wood' then wood = w end end
  T.ok(wood and wood.why:find('beds, barrels, bins', 1, true), T.show(sw))
  local m = logged(W, 'no material for barrel')
  T.ok(m and m:find('wood only', 1, true) and m:find('pots hold the drink', 1, true), tostring(m))
  local pot
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if o.job_type == df.job_type.MakeTool then pot = o end
  end
  T.ok(pot ~= nil, 'a large pot order was made')
  -- the state carries the treeless flag the plan reads (stock.nowood)
  local ok, stt = W.K.call('economy', 'state')
  T.ok(ok and type(stt) == 'table' and stt.stock and stt.stock.nowood == 1, T.show(stt and stt.stock))
end)

T.test('BUG-772: a fort with logs is no treeless fort; a large pot is a tool whose definition lists FOOD_STORAGE (or is ITEM_TOOL_LARGE_POT)', function()
  local W = world{logs = 10, setup = function(W) mats(W) end}
  days(W, 24)
  local ok, stt = W.K.call('economy', 'state')
  T.ok(ok and stt.stock and stt.stock.nowood == nil, T.show(stt and stt.stock))
  local eco = require('dfllm.economy')
  local g0 = dfhack.items.getSubtypeDef
  dfhack.items.getSubtypeDef = function(t, st) return st == 1 and {id = 'ITEM_TOOL_LARGE_POT', tool_use = {}} or {id = 'ITEM_TOOL_X', tool_use = {'FOOD_STORAGE'}} end
  T.ok(eco.is_pot({getType = function() return 0 end, getSubtype = function() return 1 end}), 'by id')
  T.ok(eco.is_pot({getType = function() return 0 end, getSubtype = function() return 2 end}), 'by use')
  dfhack.items.getSubtypeDef = function() return {id = 'ITEM_TOOL_HIVE', tool_use = {'HIVE'}} end
  T.ok(not eco.is_pot({getType = function() return 0 end, getSubtype = function() return 3 end}), 'a hive is none')
  dfhack.items.getSubtypeDef = g0
end)

T.done()
