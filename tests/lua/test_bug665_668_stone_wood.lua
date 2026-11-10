-- BUG-665 (Run 16a i1 Basementflew: 30 boulders "counted usable" beside DF's "Needs non-economic hard stone" for 100+ days; Run 16b i2 Valleyhame:
-- 46-84 boulders, every mood and rock job "none hard stone", a berserk mood killed 2): the stone census counts only the stone a job can take: a
-- boulder on a tile with no walkable group and one a job already holds are counted apart (rock_far / rock_busy), a material the game itself refuses
-- (dfhack.job.isSuitableMaterial on a non_economic + hard BOULDER filter) is rock_bad, and a denial that stays names where the boulders lie.
-- BUG-666 (Run 16d i4 Trumpetrealms y438: the only door order 'Make rock door' beside 99 logs and 0 usable stone): a rock order made again by
-- T.stale goes to the Carpenters when no stone is free, a seal door is paid from the defense floor.
-- BUG-667 (the same fort after the collapse: depot and seal wall waiting for 'building material: blocks' with 99 logs): once the stone is refused a
-- building takes logs, buildingplan's boulders go off and come back when the stone is usable again.
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

T.test('BUG-665: a boulder on a tile with no walkable group is out of reach (rock_far), one a job holds is busy (rock_busy): neither is stone', function()
  local W = world{boulders = 5, nowalk = 7, busy = 3, logs = 40}
  days(W, 1)
  local i = W.K.census.i
  T.eq({i.rock, i.rock_far, i.rock_busy}, {5, 7, 3}, T.show(i))
  T.eq(i.boulders, 15, 'the whole vector is still counted')
  T.eq(stock(W).rock, 5)
end)

T.test('BUG-665: with the one-word flag mask the in_job bit comes from the same word (no extra flag read per boulder)', function()
  local function census(with_bit)
    local BITS = {trader = 1, garbage_collect = 2, removed = 3, dump = 4, hostile = 5, in_building = 6, construction = 7, rotten = 8,
                  forbid = 9, in_inventory = 10, in_job = with_bit and 11 or nil}
    local reads = 0
    local W = world{boulders = 0, logs = 3, setup = function(W)
      df.item_flags = BITS
      for i = 1, 20 do
        local whole = i <= 6 and (1 << 11) or 0
        local set = {in_job = i <= 6}
        F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}, flags = setmetatable({}, {__index = function(_, k)
          reads = reads + 1
          if k == 'whole' then return whole end
          return set[k] == true
        end})})
      end
    end}
    days(W, 1)
    df.item_flags = nil
    local i = W.K.census.i
    return {i.rock, i.rock_busy, i.rock_far}, reads
  end
  local a, with = census(true)
  local b, without = census(false)
  T.eq(a, {14, 6, 0})
  T.eq(b, {14, 6, 0}, 'the same census without the bit in the mask (per-flag read)')
  T.ok(without - with >= 18, string.format('one flag read less per boulder: %d with the bit, %d without', with, without))
end)

T.test('BUG-665: the plain far read keeps group 0 near (snapshot.far without strict): logs and food are not judged by it', function()
  local seen = {}
  local W = world{boulders = 2, logs = 3, setup = function(W)
    F.item(W, 'WOOD', {mat_type = 420, mat_index = 0, _pos = {6, 6, 38}})
  end}
  days(W, 1)
  local i = W.K.census.i
  T.eq(i.wood, 4, 'the log on the no-group tile stays a log (plain far)')
  T.eq(i.rock, 2)
end)

T.test('BUG-665 (Valleyhame): the game refuses CHERT as non-economic hard stone although the raws say hard: it is rock_bad, named in kern.log', function()
  local W = world{boulders = 6, chert = 4, refuse = {[9] = true}, logs = 0, rock_orders = 40}
  days(W, 1)
  local i = W.K.census.i
  T.eq({i.rock, i.rock_bad}, {10, 4}, T.show(i))
  T.eq(stock(W).rock, 6, 'six usable boulders, not ten')
  -- DF cancels anyway: the report names the materials with the game's verdict
  cancel(W, 3)
  local m = logged(W, 'free boulders by material')
  T.ok(m and m:find('CHERT x4 (hard, refused by the game)', 1, true) and m:find('SANDSTONE x6 (hard)', 1, true), tostring(m))
  -- the question is off by the module switch: ASK_DF false keeps the old census
  local W2 = world{boulders = 6, chert = 4, refuse = {[9] = true}, logs = 0, ask_df = false}
  days(W2, 1)
  T.eq(W2.K.census.i.rock_bad or 0, 0, 'ASK_DF off: the census does not ask the game')
end)

T.test('BUG-665 (Basementflew): every boulder refused by the game and the cancels come: DECISION no_hard_stone names the rock layer and the way out', function()
  local W = world{boulders = 6, chert = 4, refuse = {[7] = true, [9] = true}, logs = 10, rock_orders = 40}
  days(W, 1)
  local d = decisions(W, 'no_hard_stone')
  T.eq(#d, 1)
  T.eq(d[1].d.cause, 'none')
  local q = d[1].d.q
  T.ok(q:find('0 usable', 1, true) and q:find('sandstone, chert refused', 1, true) and q:find('another rock layer', 1, true), q)
  local cmds = table.concat(d[1].d.cmds or {}, ' | ')
  T.ok(cmds:find('"mat":"wood"', 1, true) and cmds:find('ConstructDoor', 1, true), cmds)
end)

T.test('BUG-665: DF cancels beside boulders the census counts usable: kern.log says where they lie (level, walk groups), the question carries the wooden door', function()
  local W = world{boulders = 30, logs = 10}
  days(W, 1)
  cancel(W, 3)
  local d = decisions(W, 'no_hard_stone')
  T.eq(#d, 1)
  T.eq(d[1].d.cause, 'denied')
  local m = logged(W, 'DF refuses boulders the census counts usable')
  T.ok(m and m:find('30 usable boulders lie at z1 x30', 1, true), tostring(m))
  local cmds = table.concat(d[1].d.cmds or {}, ' | ')
  T.ok(cmds:find('order.add', 1, true) and cmds:find('"mat":"wood"', 1, true), cmds)
  -- no logs: no wooden-door command
  local W2 = world{boulders = 30, logs = 0}
  days(W2, 1)
  cancel(W2, 3)
  local d2 = decisions(W2, 'no_hard_stone')
  T.eq(#d2, 1)
  T.ok(not table.concat(d2[1].d.cmds or {}, ' | '):find('order.add', 1, true), 'no logs, no wooden door')
end)

local function door_order(W, mat_type, left)
  return F.order(W, {job_type = df.job_type.ConstructDoor, mat_type = mat_type, mat_index = -1, amount_left = left or 2, amount_total = left or 2,
                     frequency = df.workquota_frequency_type.OneTime, material_category = {}, _name = 'Construct rock Door'})
end

T.test('BUG-666 (Trumpetrealms): no stone is free, 99 logs: the rock door order goes to the Carpenters, also one T.stale made again in rock', function()
  local re = {}
  local W = world{logs = 99, boulders = 0, setup = function(W) door_order(W, 0, 2) end}
  W.act_result('order_material', function(id, mat) re[#re + 1] = {id, mat}; return true end)
  days(W, 2)
  T.ok(#re >= 1 and re[1][2] == 'wood', T.show(re))
  -- the same order marked as made again (p.ostale redo): with no stone free it can never run in rock, so it goes to wood too;
  -- with stone free (10 boulders, under the 20 of wood_orders.boulders_below) it keeps its material
  local function marked(boulders)
    local got = {}
    local Wm = world{logs = 99, boulders = boulders, setup = function(W) door_order(W, 0, 2) end}
    Wm.act_result('order_material', function(id, mat) got[#got + 1] = {id, mat}; return true end)
    local all = df.global.world.manager_orders.all
    local p = Wm.K.persist.get('m.economy')
    p.ostale[tostring(all[#all - 1].id)] = {redo = 1}
    days(Wm, 2)
    return got
  end
  local none = marked(0)
  T.ok(#none >= 1 and none[1][2] == 'wood', 'stone 0: the made-again order still goes to wood ' .. T.show(none))
  local some = marked(10)
  T.eq(#some, 0, 'stone free: a made-again order keeps its material ' .. T.show(some))
end)

T.test('BUG-667 (Trumpetrealms after the collapse): DF refuses the stone, 99 logs, the depot waits for building material: logs are the route, ' ..
       'buildingplan boulders go off, and on again when the stone is usable', function()
  local W = world{boulders = 30, logs = 99, jobs = function() return {wall(1, 7)} end}
  days(W, 1)
  T.ok(not F.has(F.runs(W), 'buildingplan set boulders false'), 'usable stone: nothing switched')
  cancel(W, 3)                                                    -- DF refuses the 30 boulders: stone counts 0
  days(W, 1)
  T.ok(F.has(F.runs(W), 'buildingplan set boulders false'), table.concat(F.runs(W), ' | '))
  T.eq(F.bad_runs(W), {}, 'allowlisted')
  T.ok(logged(W, 'buildingplan boulders off'), 'logged')
  -- the route itself: the logs, never the refused boulders
  local via = select(2, W.K.call('economy', 'mat_for', 'wall', 1))
  T.eq(via, 'logs')
  -- ten new boulders: the stone is believed again, boulders go back on
  for _ = 1, 10 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end
  days(W, 2)
  T.ok(F.has(F.runs(W), 'buildingplan set boulders true'), table.concat(F.runs(W), ' | '))
  T.ok(logged(W, 'buildingplan boulders on again'), 'logged')
end)

T.test('BUG-667: usable stone, logs beside it: the wall keeps its boulders (nothing changes for a fort without a denial)', function()
  local W = world{boulders = 30, logs = 99, jobs = function() return {wall(1, 7)} end}
  days(W, 2)
  T.ok(not F.has(F.runs(W), 'buildingplan set boulders false'))
  local via = select(2, W.K.call('economy', 'mat_for', 'wall', 1))
  T.ok(via == 'blocks' or via == 'boulders', tostring(via))
end)

T.test('BUG-677: wall_stock counts no boulder when every one is refused (stone_none), says so, and publishes stock.wall', function()
  local W = world{boulders = 6, chert = 4, refuse = {[7] = true, [9] = true}, logs = 40, rock_orders = 40}
  days(W, 1)
  cancel(W, 3)
  local s = stock(W)
  T.eq({s.rock, s.none}, {0, true}, T.show(s))
  T.ok(s.logs > 0, T.show(s))
  T.eq(s.have, s.blocks + s.logs, 'only blocks and logs are wall material')
  local W2 = world{boulders = 6, logs = 40}
  days(W2, 1)
  T.eq(stock(W2).none, false, 'a fort with usable stone')
  T.eq(stock(W2).have >= 6, true)
end)

T.done()
