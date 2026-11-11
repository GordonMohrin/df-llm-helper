-- BUG-736 (Run 16c i3 Doorwings y381/y382: the aqshaft ring wall at z140 'unbuilt for 31-32 d' with 385-440 logs, census blocks 132 / blocks_free 0, every
-- boulder ore, flux, reserved or out of reach; ConstructBlocks orders 'removed: no logs for it (426 logs)'; ghosts 27541 / 28225 'no ConstructSlab: 0 free
-- boulders'): a wall that waits for material is switched to the material the fort has (logs: buildingplan boulders off; else ore / flux boulders) and
-- the stall names it, claimed blocks are counted (blocks_busy), a rock block order is re-entered in wood, the slab text names the stone the fort has.
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
  add_jobs({'ConstructBuilding', 'Dig', 'MakeWeapon', 'HarvestPlants', 'ConstructBlocks'})
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


local function stock(W) return select(2, W.K.call('economy', 'wall_stock')) end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l.msg end end
end

T.test('BUG-736: blocks a job holds are counted apart (blocks_busy), wall_stock names them and does not count them', function()
  local W = world{boulders = 0, logs = 40, setup = function(W)
    for _ = 1, 5 do F.item(W, 'BLOCKS', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end
    for _ = 1, 7 do F.item(W, 'BLOCKS', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}, flags = {in_job = true}}) end
  end}
  days(W, 1)
  local i = W.K.census.i
  T.eq({i.blocks_free, i.blocks_busy, i.blocks}, {5, 7, 12}, T.show(i))
  local s = stock(W)
  T.eq({s.blocks, s.busy}, {5, 7}, T.show(s))
end)

T.test('BUG-736 (Doorwings): no free stone, no free block, 40 logs: wall_alt switches buildingplan boulders off, names the logs, and the wall route is logs', function()
  local W = world{boulders = 0, logs = 40, jobs = function() return {wall(1, 7)} end}
  days(W, 1)
  local ok, t = W.K.call('economy', 'wall_alt')
  T.ok(ok and type(t) == 'string' and t:find('built of logs', 1, true), T.show(t))
  T.ok(t:find('no free stone and no free block', 1, true), t)
  T.ok(F.has(F.runs(W), 'buildingplan set boulders false'), table.concat(F.runs(W), ' | '))
  T.eq(F.bad_runs(W), {}, 'allowlisted')
  T.ok(logged(W, 'buildingplan boulders off'), 'logged')
  T.eq(select(2, W.K.call('economy', 'mat_for', 'wall', 1)), 'logs')
end)

T.test('BUG-736: stone free (or a free block): wall_alt answers nothing and touches no setting', function()
  local W = world{boulders = 30, logs = 40}
  days(W, 1)
  T.eq(select(2, W.K.call('economy', 'wall_alt')), nil)
  T.ok(not F.has(F.runs(W), 'buildingplan set boulders'), 'no switch')
  local W2 = world{boulders = 0, logs = 40, setup = function(W)
    for _ = 1, 4 do F.item(W, 'BLOCKS', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end
  end}
  days(W2, 1)
  T.eq(select(2, W2.K.call('economy', 'wall_alt')), nil, 'a free block is wall material')
end)

T.test('BUG-736: no logs either, ore / flux boulders only: they are the wall material (boulders stay on), named in the text', function()
  local W = world{boulders = 0, logs = 0, bp = {blocks = true, boulders = false, logs = true, bars = false}}
  days(W, 1)
  local i = W.K.census.i
  i.ore, i.flux, i.rock, i.wood = 6, 4, 10, 0
  i.rock_nouse = 10   -- BUG-733: the census counts the boulders no mason may take (ore + flux here)
  local ok, t = W.K.call('economy', 'wall_alt')
  T.ok(ok and type(t) == 'string' and t:find('ore / flux boulders', 1, true), T.show(t))
  T.ok(F.has(F.runs(W), 'buildingplan set boulders true'), table.concat(F.runs(W), ' | '))
  local s = stock(W)
  T.eq({s.alt, s.have}, {10, 0}, T.show(s))
end)

T.test('BUG-736: boulders switched off for a wall come back on only when 8 stones are free again (no flapping with logs there)', function()
  local W = world{boulders = 0, logs = 40, jobs = function() return {wall(1, 7)} end}
  days(W, 1)
  W.K.call('economy', 'wall_alt')
  T.eq(W.K.persist.get('m.economy').bpoff, 'wall')
  days(W, 2)
  T.ok(not F.has(F.runs(W), 'buildingplan set boulders true'), 'no stone came: stays off ' .. table.concat(F.runs(W), ' | '))
  for _ = 1, 10 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end
  days(W, 2)
  T.ok(F.has(F.runs(W), 'buildingplan set boulders true'), table.concat(F.runs(W), ' | '))
end)

T.test('BUG-736 (Doorwings): a rock ConstructBlocks order cancelled "Needs non-economic hard stone" with logs and a carpenter goes to wood, not away', function()
  local re = {}
  local W = world{boulders = 0, logs = 99, setup = function(W)
    F.order(W, {job_type = df.job_type.ConstructBlocks, mat_type = 0, mat_index = -1, amount_left = 2, amount_total = 2,
                frequency = df.workquota_frequency_type.OneTime, material_category = {}, _name = 'Construct rock Blocks'})
  end}
  W.act_result('order_material', function(id, mat) re[#re + 1] = {id, mat}; return true end)
  days(W, 1)
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Mason cancels Construct rock Blocks: Needs non-economic hard stone boulders.'})
  settle(W)
  T.ok(#re >= 1 and re[1][2] == 'wood', T.show(re))
end)

T.done()
