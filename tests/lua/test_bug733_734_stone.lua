-- Round 47 (stone supply), offline, live-untested.
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

T.test('BUG-733: an ore that is also economic, a flux stone and an economic stone are each counted once: 6 plain boulders are 6 usable', function()
  local W = world{boulders = 6, logs = 10, setup = function(W)
    mats(W)
    boulders(W, 11, 5)          -- ore (and economic)
    boulders(W, 12, 3)          -- flux
    boulders(W, 13, 4)          -- economic only
  end}
  days(W, 1)
  local i = W.K.census.i
  T.eq(i.rock, 18, T.show(i))
  T.eq(i.rock_nouse, 12, 'ore 5 + flux 3 + economic 4, each once')
  T.eq(stock(W).rock, 6, 'the old max(ore + flux, rock_bad) = max(8, 9) would have given 9')
  local eco = require('dfllm.economy')
  T.eq(eco.usable_n({rock = 10, ore = 4, flux = 1, rock_bad = 2}), 5, 'a census without rock_nouse keeps the old formula')
end)

T.test('BUG-733: stone wanted, none free: workload stone.why says how many boulders were out of reach, held, unusable, kept back; kern.log says it once', function()
  local W = world{boulders = 0, nowalk = 7, busy = 3, logs = 40, rock_orders = 4, setup = function(W)
    mats(W)
    boulders(W, 13, 5)
  end}
  days(W, 2)
  local r = W.inbox('inspect', {what = 'workload'})
  local s = r and r.data and r.data.stone or {}
  T.eq(s.free, 0, T.show(s))
  T.ok(type(s.why) == 'table', T.show(s))
  T.eq({s.why.boulders, s.why.far, s.why.busy, s.why.rock, s.why.nouse, s.why.usable, s.why.free}, {15, 7, 3, 5, 5, 0, 0}, T.show(s.why))
  local m = logged(W, 'stone free 0 (need')
  T.ok(m and m:find('7 out of reach', 1, true) and m:find('3 held by a job', 1, true) and m:find('5 ore, flux, economic or soft stone', 1, true), tostring(m))
  local n = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('stone free 0 (need', 1, true) then n = n + 1 end end
  T.eq(n, 1, 'once in three game days')
end)

-- BUG-734 -------------------------------------------------------------------------------------------------------------------------------
local L = require('dfllm.trade').lib
local function info(mat, nouse) return {type = 'BOULDER', mat = mat, desc = mat:lower() .. ' boulder', nouse = nouse} end

T.test('BUG-734 trade: a plain stone want skips ore, flux, economic and soft boulders; a named stone, flux and a sell token do not', function()
  local plain, ore = info('INORGANIC:CONGLOMERATE'), info('INORGANIC:MAGNETITE', true)
  for _, s in ipairs({'stone', 'boulder'}) do
    local tk = L.token(s)
    T.ok(L.match(tk, plain), s .. ' takes conglomerate')
    T.ok(not L.match(tk, ore), s .. ' skips magnetite')
  end
  T.ok(L.match(L.token('stone:magnetite'), ore), 'a named stone is asked for on purpose')
  T.ok(L.match(L.token('flux'), info('INORGANIC:CHALK', true) and {type = 'BOULDER', mat = 'INORGANIC:CHALK', desc = 'chalk boulder', flux = true, nouse = true}), 'flux wants flux')
  local sell = L.token('stone')
  sell.sell = true
  T.ok(L.match(sell, ore), 'a sell token never filters')
end)

T.test('BUG-734 trade: item_info marks ore, flux, economic and soft boulders (nouse), a plain hard stone is none', function()
  local W = world{logs = 1, setup = function(W) mats(W) end}
  F.mat(W, 0, 14, {token = 'INORGANIC:SILTY_CLAY', flags = {}})
  local tr = fresh('trade')
  W.load(tr)
  local function nouse(mi)
    local it = F.item(W, 'BOULDER', {mat_type = 0, mat_index = mi, _pos = {5, 5, 1}})
    it.getType = function() return df.item_type.BOULDER end
    it.getMaterial = function() return 0 end
    it.getMaterialIndex = function() return mi end
    it.getStackSize = function() return 1 end
    local ok, inf = pcall(tr.item_info, it, nil, false, false)
    return ok and inf and inf.nouse or nil, ok
  end
  local a, b, c, d, e = (nouse(7)), (nouse(11)), (nouse(12)), (nouse(13)), (nouse(14))
  T.eq({a, b, c, d, e}, {nil, true, true, true, true}, T.show({select(2, nouse(14))}))
end)

T.test('BUG-734: stone.use frees a stone type the fort holds for furniture (and marks it again); the no_hard_stone decision names it', function()
  local W = world{boulders = 0, chert = 0, logs = 10, rock_orders = 40, setup = function(W)
    mats(W)
    boulders(W, 12, 36)          -- chalk, flux
    boulders(W, 11, 25)          -- magnetite, ore
    boulders(W, 14 , 3)
  end}
  F.mat(W, 0, 14, {token = 'INORGANIC:SILTY_CLAY', flags = {}})
  local calls = {}
  W.act_result('stone_economic', function(idx, on) calls[#calls + 1] = {idx, on}; return true, on and 'marked' or 'cleared' end)
  days(W, 1)
  cancel(W, 3)
  local d = decisions(W, 'no_hard_stone')
  T.ok(#d >= 1, 'the decision is asked')
  T.eq(d[1].d.mat, 'chalk', 'the plain economic or flux stone first, an ore after it: ' .. T.show(d[1].d))
  local has = false
  for _, c in ipairs(d[1].d.cmds or {}) do if tostring(c):find('stone.use', 1, true) and tostring(c):find('chalk', 1, true) then has = true end end
  T.ok(has, 'the command is in the decision: ' .. T.show(d[1].d.cmds))
  local r = W.inbox('stone.use', {mat = 'chalk'})
  T.ok(r and r.ok, T.show(r))
  T.eq(calls[#calls], {12, false})
  local r2 = W.inbox('stone.use', {mat = 'INORGANIC:Chalk', economic = true})
  T.ok(r2 and r2.ok, T.show(r2))
  T.eq(calls[#calls], {12, true})
  local bad = W.inbox('stone.use', {mat = 'granite'})
  T.ok(bad and not bad.ok and tostring(bad.msg or bad.err or bad.error or ''):find('no granite boulder', 1, true), T.show(bad))
  local soft = W.inbox('stone.use', {mat = 'silty_clay'})
  T.ok(soft and not soft.ok and tostring(soft.msg or soft.err or soft.error or ''):find('soft stone', 1, true), T.show(soft))
end)

T.done()
