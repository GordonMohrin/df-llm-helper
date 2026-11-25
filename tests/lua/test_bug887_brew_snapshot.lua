-- NEU13 BUG-887 round 3 (Neuausrichtung 13 round 3, 'fass'): the cause of DF's "Needs empty food storage item" beside free empty barrels is NOT confirmed (the 25.11. diagnosis:
-- 99 % of the attempts fail with 20-100 'free' empties, i4 9443 cancels vs 9 completions; hypothesis H1 'phantom empties' unproven). So the kernel MEASURES: when the gamelog reader
-- sees the cancel, once per game day, one kern.log line and one BREW_CANCEL_SNAPSHOT event with the empties by type and state, the nearest free one, the Stills and brew jobs, the
-- cancel / completion counts and the job_item filter of one brew job; `why brew --raw` prints the same block. Read only.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200
local BREWER = 6
local GL = require('dfllm.gamelog')

local function tmpdir(tag)
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_bug887r3-' .. tag
  luahost.mkdir_recursive(dir)
  os.remove(dir .. '/gamelog.txt')
  return dir, dir .. '/gamelog.txt'
end
local function put(path, s, mode) local f = assert(io.open(path, mode or 'ab')); f:write(s); f:close() end
local PLANT = 'Iden Al\134th\148m, Woodcrafter cancels Brew drink from plant: Needs empty food storage item.\n'
local DONE = 'Brew drink from plant (30) has been completed.\n'

local function world(tag)
  local units, ids = {}, {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  if df.job_type.MakeBarrel == nil then df.job_type.MakeBarrel = 991; df.job_type[991] = 'MakeBarrel' end
  df.job_type.StoreItemInStockpile = 992; df.job_type[992] = 'StoreItemInStockpile'
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER'}
  df.job_skill = df.job_skill or {}
  df.specific_ref_type = {JOB = 1}
  df.items_other_id = kmock.enum({'IN_PLAY', 'PLANT', 'PLANT_GROWTH', 'BARREL', 'TOOL', 'WOOD'})
  for _, v in ipairs({'PLANT', 'PLANT_GROWTH', 'BARREL', 'TOOL', 'WOOD'}) do rawset(df.global.world.items.other, v, rawget(df.global.world.items.other, v) or kmock.vec{}) end
  df.job_type.attrs = setmetatable({}, {__index = function() return {labor = -1, skill = -1} end})
  dfhack.items.getSpecificRef = function(it) return it._job and {data = {job = it._job}} or nil end
  for i = 1, 4 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
    u.burrows = kmock.vec{}
    u.flags1 = {}
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 20000})
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end,
          groups = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[1] >= 500 and 2 or 1 end; return g end,
          hidden = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[2] >= 900 end; return g end})
  W.load(fresh('economy'))
  local dir, path = tmpdir(tag)
  W.K.cfg.paths.df = dir
  put(path, 'start\n', 'wb')
  -- a Still with one brew job whose second job_item is the container
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z, b.centerx, b.centery = 20, 20, 22, 22, 100, 21, 21
  b.flags = {}
  b.jobs = kmock.vec{{id = 1412477, job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT',
                      job_items = {elements = {{item_type = 0, quantity = 1, flags1 = {unrotten = true}, flags2 = {}, flags3 = {}, flags4 = {}, flags5 = {}, vector_id = 110},
                                               {item_type = -1, quantity = 1, flags1 = {empty = true}, flags2 = {}, flags3 = {food_storage = true}, flags4 = {}, flags5 = {}, vector_id = 130}}},
                      items = {{job_item_idx = 0}}}}
  return W, b, path
end

local function barrel(W, o)
  return F.item(W, 'BARREL', {_pos = o.pos or {21, 24, 100}, _contents = o.full and {{id = 1}} or nil, flags = o.flags or {}, _job = o.job, general_refs = o.refs})
end

T.test('BUG-887 round 3: the snapshot splits the empty barrels by state, names the nearest free one, the Stills and the brew filter; read only', function()
  local W, b = world('collect')
  df.general_ref_type = df.general_ref_type or kmock.enum({'UNIT_TRADEBRINGER', 'CONTAINS_ITEM'})
  local TB = df.general_ref_type.UNIT_TRADEBRINGER
  for _ = 1, 5 do barrel(W, {full = true}) end
  for _ = 1, 3 do barrel(W, {pos = {21, 30, 100}}) end                                   -- free
  barrel(W, {pos = {21, 22, 100}})                                                       -- free, the nearest (1 tile from the Still centre 21,21,100)
  for _ = 1, 2 do barrel(W, {pos = {21, 25, 112}}) end                                   -- free on the surface (outside), z +12
  for _ = 1, 2 do barrel(W, {flags = {forbid = true}}) end
  barrel(W, {flags = {in_job = true}, job = {job_type = df.job_type.StoreItemInStockpile}})
  barrel(W, {flags = {in_job = true}, job = {job_type = df.job_type.MakeBarrel}})
  barrel(W, {refs = {{getType = function() return TB end}}})                              -- a trader's
  barrel(W, {pos = {600, 21, 100}})                                                       -- another walk group
  barrel(W, {flags = {in_building = true}})                                               -- skipped by the census flags
  local acts0 = #W.acts
  local econ = require('dfllm.economy')
  local env = econ.snap_env(W.K)
  env.surface = function(x, y, z) return z >= 110 end
  env.far = function(it) return it._pos[1] >= 500 end              -- the walk-group read itself is snapshot.far's (tested there)
  local s = econ.BS.collect(env)
  local e = s.e.barrel
  T.eq({e.total, e.empty, e.free, e.forb, e.job, e.haul, e.trader, e.far, e.other, e.out}, {18, 13, 6, 2, 2, 1, 1, 1, 1, 2}, 'empty barrels by state')
  T.eq({s.stills, s.brewjobs, s.still.id, s.still.named}, {1, 1, b.id, true}, 'the Still that holds a brew job')
  T.eq({s.near.d, s.near.dz, s.near.y}, {1, 0, 22}, 'nearest free empty: one tile from the Still')
  T.eq(#s.filter, 2, 'both job_items of the brew job')
  T.ok(s.filter[2]:find('f1=[empty]', 1, true) and s.filter[2]:find('f3=[food_storage]', 1, true) and s.filter[2]:find('vec=130', 1, true), s.filter[2])
  T.ok(s.filter[1]:find('filled=1', 1, true), s.filter[1])
  T.eq(#W.acts, acts0, 'read only: no act was called')
  T.eq(#b.jobs, 1, 'no job removed or added')
  local lines = econ.BS.lines(s)
  local all = table.concat(lines, '\n')
  T.ok(lines[1]:find('brew cancel snapshot:', 1, true) and lines[1]:find('empty barrels 13 (free 6, forbidden 2, in a job 2 [hauling 1], trader 1, far 1, other 1, outside 2)', 1, true), lines[1])
  T.ok(all:find('jobs that hold an empty: MakeBarrel 1, StoreItemInStockpile 1', 1, true), all)
  T.ok(all:find('nearest free empty barrel at 21,22,100: distance 1', 1, true), all)
end)

T.test('BUG-887 round 3: a world with no Still and no barrel gives a snapshot, not an error', function()
  local W = world('empty')
  df.global.world.buildings.other.WORKSHOP_ANY = kmock.vec{}
  local econ = require('dfllm.economy')
  local s = econ.brew_snapshot(W.K)
  T.eq({s.stills, s.brewjobs, s.e.barrel.empty, s.e.pot.empty}, {0, 0, 0, 0})
  T.eq(s.near, nil)
  local all = table.concat(econ.snap_lines(W.K), '\n')
  T.ok(all:find('0 Stills', 1, true) and all:find('no brew job in a Still now', 1, true), all)
end)

T.test('BUG-887 round 3: gamelog.brew_done reads the completed brew orders, nothing else', function()
  T.eq(GL.brew_done('Brew drink from plant (30) has been completed.'), 30)
  T.eq(GL.brew_done('Brew drink from fruit (2) has been completed.'), 2)
  T.eq(GL.brew_done('Make wooden barrel (15) has been completed.'), nil)
  T.eq(GL.brew_done('Urist cancels Brew drink from plant: Needs empty food storage item.'), nil)
  local _, path = tmpdir('done')
  put(path, 'start\n', 'wb')
  local s = GL.new(path)
  GL.poll(s, {})
  put(path, DONE .. PLANT .. 'Make wooden barrel (15) has been completed.\n' .. DONE)
  local r = GL.poll(s, {})
  T.eq({#r, s.done, s.lastlook.done}, {1, 60, 60}, 'one cancel, 60 brews completed, the barrel order not counted')
end)

T.test('BUG-887 round 3: DF cancels for a container -> one kern.log line and one BREW_CANCEL_SNAPSHOT a game day, with the cancel and completion counts', function()
  local W, b, path = world('daily')
  for _ = 1, 4 do barrel(W, {pos = {21, 30, 100}}) end
  for _ = 1, 3 do barrel(W, {full = true}) end
  local econ = require('dfllm.economy')
  econ.watch(W.K)                                                   -- first look: from the end of the file
  T.eq(#W.find_events('BREW_CANCEL_SNAPSHOT'), 0, 'nothing cancelled yet: nothing written')
  for _ = 1, 40 do put(path, PLANT) end
  put(path, DONE .. DONE)
  econ.watch(W.K)
  local ev = W.find_events('BREW_CANCEL_SNAPSHOT')
  T.eq(#ev, 1)
  local d = ev[1].d
  T.eq({d.stills, d.jobs, d.empties, d.free, d.cancels, d.done, d.still}, {1, 1, 4, 4, 40, 60, b.id}, T.show(d))
  T.ok(d.filter and d.filter:find('f3=[food_storage]', 1, true), tostring(d.filter))
  local l
  for _, x in ipairs(W.logs) do if tostring(x.msg):find('brew cancel snapshot:', 1, true) then l = x.msg end end
  T.ok(l and l:find('cancelled Brew 40 x in 7 d, completed 60', 1, true) and l:find('empty barrels 4 (free 4', 1, true), tostring(l))
  for _ = 1, 10 do put(path, PLANT) end
  econ.watch(W.K)
  T.eq(#W.find_events('BREW_CANCEL_SNAPSHOT'), 1, 'the same game day: not again')
  W.run(DAYT + 50, {skip = 100})
  for _ = 1, 5 do put(path, PLANT) end
  econ.watch(W.K)
  T.eq(#W.find_events('BREW_CANCEL_SNAPSHOT'), 2, 'the next game day: once more')
  W.run(DAYT + 50, {skip = 100})
  put(path, 'Domas, militia captain cancels Brew drink from fruit: Needs unrotten fermentable leaf or fruit.\n')
  econ.watch(W.K)
  T.eq(#W.find_events('BREW_CANCEL_SNAPSHOT'), 2, 'only the container reason asks for a snapshot')
end)

T.test('BUG-887 round 3: why brew --raw prints the snapshot block', function()
  local W = world('why')
  barrel(W, {pos = {21, 23, 100}})
  local raw = require('dfllm.dfraw')
  local ok, res = pcall(function() return raw.brew(W.K, {}) end)
  T.ok(ok, tostring(res))
  local txt = type(res) == 'table' and table.concat(res.l or res, '\n') or tostring(res)
  T.ok(txt:find('brew cancel snapshot:', 1, true) and txt:find('nearest free empty barrel at 21,23,100', 1, true), txt:sub(1, 600))
end)

T.test('BUG-887 round 3b: the flag census of the empties (container set vs clear, refs) and the barrel DF attached to the brew job decide H1 from the snapshot alone', function()
  local W, b, path = world('census')
  df.general_ref_type = df.general_ref_type or kmock.enum({'UNIT_TRADEBRINGER', 'CONTAINS_ITEM'})
  df.general_ref_type.ENTITY_ITEMOWNER = df.general_ref_type.ENTITY_ITEMOWNER or 77; df.general_ref_type[77] = 'ENTITY_ITEMOWNER'
  local TB, EO = df.general_ref_type.UNIT_TRADEBRINGER, df.general_ref_type.ENTITY_ITEMOWNER
  for _ = 1, 3 do barrel(W, {pos = {21, 30, 100}, flags = {container = true}}) end                        -- free phantoms: container set
  barrel(W, {pos = {21, 31, 100}, flags = {container = true, foreign = true}, refs = {{getType = function() return EO end}}})                 -- free, foreign + an item-owner ref
  barrel(W, {pos = {21, 32, 100}, flags = {container = true}, refs = {{getType = function() return EO end}, {getType = function() return TB end}}})         -- a trader's: counted in 'all', not free
  for _ = 1, 2 do barrel(W, {pos = {21, 33, 100}}) end                                                    -- free, container clear
  barrel(W, {flags = {forbid = true, container = true}})                                                 -- empty but forbidden: in 'all', not in 'free'
  barrel(W, {full = true, flags = {container = true}})                                                    -- full: not an empty at all
  local taken = barrel(W, {pos = {21, 34, 100}, flags = {in_job = true, artifact = true}, refs = {{getType = function() return EO end}}})
  local bj; for _, x in ipairs(b.jobs) do bj = x end
  bj.items[#bj.items + 1] = {job_item_idx = 1, item = taken}
  local acts0 = #W.acts
  local econ = require('dfllm.economy')
  local env = econ.snap_env(W.K)
  env.surface = function() return false end
  env.far = function() return false end
  local s = econ.BS.collect(env)
  T.eq({s.cen.free_set, s.cen.free_clear, s.cen.all_set, s.cen.all_clear}, {4, 2, 6, 3}, 'container set vs clear: free and all')
  T.eq({s.cen.free['container'], s.cen.free['-'], s.cen.free['container+foreign'], s.cen.all['artifact+in_job']}, {3, 2, 1, 1}, T.show(s.cen))
  T.eq({s.cen.refs_free['-'], s.cen.refs_free['ENTITY_ITEMOWNER'], s.cen.refs_all['ENTITY_ITEMOWNER+UNIT_TRADEBRINGER']}, {5, 1, 1}, T.show(s.cen.refs_free))
  T.eq(#s.taken, 1, 'one attached barrel')
  T.ok(s.taken[1]:find('#' .. tostring(taken.id), 1, true) and s.taken[1]:find('artifact', 1, true) and s.taken[1]:find('in_job', 1, true) and s.taken[1]:find('refs=ENTITY_ITEMOWNER', 1, true), s.taken[1])
  T.eq(#W.acts, acts0, 'read only')
  local f = econ.BS.fields(s)
  T.eq({f.fcs, f.fcc, f.acs, f.acc}, {4, 2, 6, 3})
  T.ok(f.combo:find('container=3', 1, true) and f.combo:find('-=2', 1, true) and f.refs:find('ENTITY_ITEMOWNER=1', 1, true) and f.taken:find('artifact', 1, true), T.show(f))
  local all = table.concat(econ.BS.lines(s), '\n')
  T.ok(all:find('flag census, free empties: container set 4, clear 2', 1, true) and all:find('flag census, ALL empties: container set 6, clear 3', 1, true), all)
  T.ok(all:find('attached to a brew job: #' .. tostring(taken.id), 1, true), all)
  T.ok(econ.BS.line(s):find('free empties with container flag 4 / without 2', 1, true), econ.BS.line(s))
  -- the event carries the census, no second scan: the same single pass
  econ.watch(W.K)
  put(path, PLANT)
  econ.watch(W.K)
  local ev = W.find_events('BREW_CANCEL_SNAPSHOT')
  T.eq(#ev, 1)
  T.eq({ev[1].d.fcs, ev[1].d.fcc}, {4, 2})
  T.ok(tostring(ev[1].d.taken):find('artifact', 1, true), T.show(ev[1].d))
end)

T.test('BUG-887 round 3b: no brew job attached barrel -> the census still prints, "nothing taken to compare"', function()
  local W = world('notaken')
  barrel(W, {pos = {21, 23, 100}, flags = {container = true}})
  local econ = require('dfllm.economy')
  local s = econ.brew_snapshot(W.K)
  T.eq({#s.taken, s.cen.free_set}, {0, 1})
  local all = table.concat(econ.snap_lines(W.K), '\n')
  T.ok(all:find('nothing taken to compare', 1, true) and all:find('taken by DF now: 0 barrels', 1, true), all)
end)

local function add_job(b, id, items)
  local j = {id = id, job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', items = items or {}}
  b.jobs:insert('#', j)
  return j
end

T.test('BUG-887 round 4: the attached barrels of ALL brew jobs of ALL Stills are counted (histogram) and at most 8 described', function()
  local W, b = world('all')
  df.general_ref_type = df.general_ref_type or kmock.enum({'UNIT_TRADEBRINGER', 'CONTAINS_ITEM'})
  local b2 = F.workshop(W, 'Still')
  b2.x1, b2.y1, b2.x2, b2.y2, b2.z, b2.centerx, b2.centery = 30, 20, 32, 22, 100, 31, 21
  b2.flags = {}
  b2.jobs = kmock.vec{}
  local j1 = b.jobs[0]
  local second = add_job(b, 2, {})                                    -- a second brew job in the first Still
  local j3 = add_job(b2, 3, {})                                       -- a job in the second Still
  local function att(j, o) local it = barrel(W, o); j.items[#j.items + 1] = {job_item_idx = 1, item = it}; return it end
  att(j1, {flags = {container = true}})                               -- (the first job of the first Still: the old code saw only this)
  for _ = 1, 4 do att(second, {flags = {container = true, foreign = true}}) end
  for _ = 1, 6 do att(j3, {flags = {artifact = true}}) end
  local dup = att(j3, {})
  second.items[#second.items + 1] = {job_item_idx = 1, item = dup}   -- the same barrel in two jobs: counted once
  second.items[#second.items + 1] = {job_item_idx = 0, item = dup}   -- other job_item: ignored
  local econ = require('dfllm.economy')
  local s = econ.BS.collect(econ.snap_env(W.K))
  T.eq({s.stills, s.brewjobs, s.taken_n, #s.taken}, {2, 3, 12, 8}, 'twelve attached barrels in two Stills, eight described')
  T.eq({s.taken_combo['container'], s.taken_combo['container+foreign'], s.taken_combo['artifact'], s.taken_combo['-']}, {1, 4, 6, 1}, T.show(s.taken_combo))
  local all = table.concat(econ.BS.lines(s), '\n')
  T.ok(all:find('attached now: 12 barrels', 1, true) and all:find('4 more attached barrels only in the histogram', 1, true), all)
  T.ok(s.taken[1]:find('refcount=', 1, true) and s.taken[1]:find('specific=', 1, true) and s.taken[1]:find('still=', 1, true), s.taken[1])
  T.eq(econ.BS.fields(s).tn, 12)
end)

T.test('BUG-887 round 4: the accumulator dedups by id, caps ids / keys / last, and survives a JSON round trip', function()
  local BS = require('dfllm.brewsnap')
  local json = require('dfllm.util.json')
  local acc = BS.acc_new()
  T.ok(BS.acc_add(acc, {id = 1, c = 'container', r = '-', nc = 0, w = 0}, 10))
  T.ok(not BS.acc_add(acc, {id = 1, c = 'container', r = '-', nc = 0, w = 0}, 20), 'same id: not again')
  T.ok(BS.acc_add(acc, {id = 2, c = 'artifact', r = 'ENTITY_ITEMOWNER', nc = 0, w = 3}, 30))
  T.eq({acc.n, acc.set, acc.nc0, acc.wear, acc.combo.container, acc.combo.artifact}, {2, 1, 2, 1, 1, 1})
  for i = 10, 10 + BS.ACC_IDS + 20 do BS.acc_add(acc, {id = i, c = 'k' .. i, r = 'r' .. i, nc = 0}, 40) end
  T.eq(#acc.ids, BS.ACC_IDS, 'id ring capped')
  T.eq(#acc.last, BS.ACC_LAST, 'last capped')
  local keys = 0
  for _ in pairs(acc.combo) do keys = keys + 1 end
  T.ok(keys <= BS.ACC_KEYS + 1 and acc.combo['(other)'] and acc.combo['(other)'] > 0, 'histogram keys capped, rest in (other)')
  local back = json.decode(json.encode(acc))
  T.eq({back.n, #back.ids, #back.last, back.combo['(other)'], back.set}, {acc.n, #acc.ids, #acc.last, acc.combo['(other)'], acc.set})
  T.ok(not BS.acc_add(back, {id = acc.ids[#acc.ids], c = 'x', r = 'y'}, 50), 'dedup survives the round trip')
  T.ok(BS.acc_lines(acc)[1]:find('distinct attached barrels', 1, true) and BS.acc_lines(BS.acc_new())[1]:find('EMPTY', 1, true) and BS.acc_lines(BS.acc_new())[1]:find('no refutation', 1, true))
end)

T.test('BUG-887 round 4: M.watch samples the Stills while the container reason is active, persists the accumulator and the snapshot prints it', function()
  local W, b, path = world('sampler')
  local econ = require('dfllm.economy')
  econ.watch(W.K)
  local j = b.jobs[0]
  local it = barrel(W, {pos = {21, 30, 100}, flags = {container = true}})
  j.items[#j.items + 1] = {job_item_idx = 1, item = it}
  econ.watch(W.K)
  local p = W.K.persist.get('m.economy')
  T.eq(p.bacc and p.bacc.n or 0, 0, 'no container cancel seen yet: the sampler is idle')
  put(path, PLANT)
  econ.watch(W.K)                                                    -- the cancel is seen, the same pass samples
  p = W.K.persist.get('m.economy')
  T.eq({p.bacc.n, p.bacc.combo.container, p.bacc.last[1].id}, {1, 1, it.id}, T.show(p.bacc))
  j.items = {}                                                       -- the job ends (about a second): the barrel is gone from the job list
  local it2 = barrel(W, {pos = {21, 31, 100}, flags = {artifact = true}})
  j.items[#j.items + 1] = {job_item_idx = 1, item = it2}
  econ.watch(W.K)
  econ.watch(W.K)
  p = W.K.persist.get('m.economy')
  T.eq({p.bacc.n, p.bacc.combo.artifact}, {2, 1}, 'a later pass adds the next barrel; a repeated pass adds nothing')
  local acts0 = #W.acts
  local txt = table.concat(econ.snap_lines(W.K), '\n')
  T.ok(txt:find('taken-accumulator: 2 distinct attached barrels', 1, true), txt)
  T.eq(#W.acts, acts0, 'read only')
  local f = econ.BS.fields(econ.brew_snapshot(W.K))
  T.eq(f.bn, 2)
end)

T.test('BUG-887 round 4: the free empties carry the extra state counts (ref counts, specific refs, flag set + nothing inside, age split)', function()
  local W = world('extra')
  df.general_ref_type = df.general_ref_type or kmock.enum({'UNIT_TRADEBRINGER', 'CONTAINS_ITEM'})
  df.general_ref_type.ENTITY_ITEMOWNER = df.general_ref_type.ENTITY_ITEMOWNER or 77; df.general_ref_type[77] = 'ENTITY_ITEMOWNER'
  local TB = df.general_ref_type.ENTITY_ITEMOWNER
  local a = barrel(W, {pos = {21, 30, 100}, flags = {container = true}, refs = {{getType = function() return TB end}, {getType = function() return TB end}}})
  a.specific_refs = {{}, {}}
  a.wear = 2
  barrel(W, {pos = {21, 31, 100}, flags = {container = true}})
  barrel(W, {pos = {21, 32, 100}})
  barrel(W, {pos = {21, 33, 100}})
  local econ = require('dfllm.economy')
  local env = econ.snap_env(W.K)
  env.surface = function() return false end
  env.far = function() return false end
  local s = econ.BS.collect(env)
  T.eq({s.cen.rc_free.ENTITY_ITEMOWNER, s.cen.spec_items, s.cen.spec_total, s.cen.wear_free}, {2, 1, 2, 1}, T.show(s.cen))
  T.eq({s.cen.free_set, s.cen.free_clear, s.cen.old + s.cen.new, s.cen.old_set + s.cen.new_set}, {2, 2, 4, 2})
  T.ok(s.cen.old >= 1 and s.cen.new >= 1, 'both halves of the age split are filled')
  local all = table.concat(econ.BS.lines(s), '\n')
  T.ok(all:find('general_refs by type ENTITY_ITEMOWNER:2', 1, true) and all:find('1 items carry specific_refs (2 refs)', 1, true) and all:find('flag set + nothing inside 2 vs flag clear 2', 1, true), all)
end)

-- BUG-887 round 5: vector membership, material / location, cancel timing, completions label, headline, block first on page 1
local function vec130(W)
  local e = df.items_other_id
  e.FOOD_STORAGE, e[130] = 130, 'FOOD_STORAGE'
  rawset(df.global.world.items.other, 'FOOD_STORAGE', kmock.vec{})
  return df.global.world.items.other.FOOD_STORAGE
end
local function with_mat(it, m) it._mat = m; return it end

T.test('BUG-887 round 5: vector membership of the free and the taken barrels in the vector the job_item names (130 = FOOD_STORAGE here)', function()
  local W, b = world('vec5')
  local fs = vec130(W)
  local saved = dfhack.matinfo
  dfhack.matinfo = {decode = function(it) return {getToken = function() return it._mat or '?' end} end}
  local inv = {}
  for i = 1, 4 do inv[i] = with_mat(barrel(W, {pos = {21, 30 + i, 100}}), i <= 3 and 'INORGANIC:CLAYSTONE' or 'PLANT:WILLOW:WOOD') end
  for i = 1, 3 do fs:insert('#', inv[i]) end                                  -- 3 of the 4 free empties are members of vector 130
  local taken = with_mat(barrel(W, {pos = {21, 40, 100}, flags = {in_job = true}}), 'INORGANIC:CLAYSTONE')
  fs:insert('#', taken)
  b.jobs[0].items[#b.jobs[0].items + 1] = {job_item_idx = 1, item = taken}
  local econ = require('dfllm.economy')
  local acts0 = #W.acts
  local env = econ.snap_env(W.K)
  env.surface = function() return false end
  env.far = function() return false end
  local s = econ.BS.collect(env)
  dfhack.matinfo = saved
  T.eq({s.vec.vid, s.vec.name, s.vec.free_in, s.vec.free_n, s.vec.taken_in, s.vec.taken_n, s.vec.n}, {130, 'FOOD_STORAGE', 3, 4, 1, 1, 4}, T.show(s.vec))
  T.ok(s.vec.src:find('job_item of a live brew job', 1, true), s.vec.src)
  T.eq({s.matf['INORGANIC:CLAYSTONE'], s.matf['PLANT:WILLOW:WOOD'], s.taken_mat['INORGANIC:CLAYSTONE']}, {3, 1, 1}, T.show(s.matf))
  T.eq(env.acc.vid, 130, 'the id is remembered in the accumulator')
  local all = table.concat(econ.BS.lines(s), '\n')
  T.ok(all:find('in vector 130 (FOOD_STORAGE; id from job_item of a live brew job; 4 items): free 3 of 4, taken 1 of 1', 1, true), all)
  T.ok(all:find('material: free empties', 1, true) and all:find('INORGANIC:CLAYSTONE=3', 1, true), all)
  T.eq(#W.acts, acts0, 'read only')
  local f = econ.BS.fields(s)
  T.eq({f.vid, f.vname, f.vfree, f.vfreen, f.vtk, f.vtkn}, {130, 'FOOD_STORAGE', 3, 4, 1, 1})
end)

T.test('BUG-887 round 5: no brew job now -> the vector id comes from the accumulator, else from a candidate enum name (labelled GUESS); none -> not measurable', function()
  local W, b = world('vec5b')
  vec130(W)
  barrel(W, {pos = {21, 30, 100}})
  local econ = require('dfllm.economy')
  b.jobs = kmock.vec{}                                               -- no brew job at the moment
  local env = econ.snap_env(W.K)
  env.acc = econ.BS.acc_new()
  local s = econ.BS.collect(env)
  T.ok(s.vec and s.vec.vid == 130 and s.vec.src:find('GUESS: enum name FOOD_STORAGE', 1, true), T.show(s.vec))
  env.acc.vid, env.acc.vname = 77, 'WOOD'
  s = econ.BS.collect(env)
  T.eq({s.vec.vid, s.vec.name}, {77, 'WOOD'})
  T.ok(s.vec.src:find('last seen', 1, true), s.vec.src)
  df.items_other_id = kmock.enum({'IN_PLAY'})
  env.acc = econ.BS.acc_new()
  s = econ.BS.collect(env)
  T.eq(s.vec, nil)
  T.ok(table.concat(econ.BS.lines(s), '\n'):find('vector membership: not measurable', 1, true))
end)

T.test('BUG-887 round 5: location of the free empties (pile tag, z, a building other than a stockpile)', function()
  local W = world('loc5')
  df.building_type.Stockpile = 77; df.building_type[77] = 'Stockpile'
  rawset(df.global.world.buildings.other, 'STOCKPILE', kmock.vec{{name = 'dfllm-drink', x1 = 21, y1 = 30, x2 = 21, y2 = 31, z = 100},
                                                                  {name = 'dfllm-mood', x1 = 25, y1 = 30, x2 = 25, y2 = 30, z = 100}})
  barrel(W, {pos = {21, 30, 100}}); barrel(W, {pos = {21, 31, 100}}); barrel(W, {pos = {25, 30, 100}}); barrel(W, {pos = {30, 30, 101}}); barrel(W, {pos = {31, 30, 101}})
  local saved = dfhack.buildings.findAtTile
  dfhack.buildings.findAtTile = function(x, y, z)
    if x == 21 then return {getType = function() return df.building_type.Stockpile end} end     -- a stockpile: not 'a building other than'
    if x == 31 then return {getType = function() return df.building_type.Door end} end
    return nil
  end
  local econ = require('dfllm.economy')
  local env = econ.snap_env(W.K)
  env.surface = function() return false end
  env.far = function() return false end
  local s = econ.BS.collect(env)
  dfhack.buildings.findAtTile = saved
  T.eq({s.loc['dfllm-drink'], s.loc['dfllm-mood'], s.loc['none'], s.locz['100'], s.locz['101'], s.locn, s.locb['Door']}, {2, 1, 2, 3, 2, 1, 1}, T.show(s))
  T.ok(table.concat(econ.BS.lines(s), '\n'):find('1 lie on a tile with a building other than a stockpile (Door=1)', 1, true))
end)

T.test('BUG-887 round 5: cancel moments (jobs, barrels held, plants held, Stills) are kept at the gamelog look, last 20, min / median / max, jobs per free empty', function()
  local W, b, path = world('moment5')
  local j1 = b.jobs[0]
  add_job(b, 2, {{job_item_idx = 0}, {job_item_idx = 1}})
  add_job(b, 3, {})
  j1.items[#j1.items + 1] = {job_item_idx = 1}
  for _ = 1, 4 do barrel(W, {pos = {21, 30, 100}}) end
  local econ = require('dfllm.economy')
  econ.watch(W.K)
  local acts0 = #W.acts
  put(path, PLANT)
  econ.watch(W.K)
  local p = W.K.persist.get('m.economy')
  local m = p.bacc.moments
  T.eq(#m, 1, T.show(p.bacc))
  T.eq({m[1].st, m[1].j, m[1].b, m[1].p}, {1, 3, 2, 2}, 'three jobs, two hold a barrel, two hold a plant, one Still')
  T.eq(#W.find_events('BREW_CANCEL_SNAPSHOT'), 1)
  put(path, PLANT)
  econ.watch(W.K)                                                    -- the same game day: no second snapshot, but a second moment
  p = W.K.persist.get('m.economy')
  m = p.bacc.moments
  T.eq(#m, 2)
  T.eq(m[2].f, 4, 'the free empties of the last snapshot')
  for _ = 1, 30 do econ.BS.moment(econ.snap_env(W.K), p.bacc, 5, 1) end
  T.eq(#p.bacc.moments, econ.BS.MOMENTS, 'capped at 20')
  local txt = table.concat(econ.BS.moment_lines(p.bacc), '\n')
  T.ok(txt:find('cancel timing (20 moments; min / median / max): brew jobs in all Stills 3 / 3 / 3', 1, true) and txt:find('Stills 1 / 1 / 1', 1, true), txt)
  T.ok(txt:find('brew jobs per free empty (free from the last snapshot) 0.8 / 0.8 / 0.8', 1, true), txt)
  T.eq(#W.acts, acts0, 'read only')
end)

T.test('BUG-887 round 5: the event text is a short headline under 200 characters with the pointer; completions are labelled "not measurable"', function()
  local W, b, path = world('head5')
  vec130(W)
  for i = 1, 4 do barrel(W, {pos = {21, 30 + i, 100}}) end
  local econ = require('dfllm.economy')
  econ.watch(W.K)
  for _ = 1, 40 do put(path, PLANT) end
  put(path, DONE)
  econ.watch(W.K)
  local ev = W.find_events('BREW_CANCEL_SNAPSHOT')
  T.eq(#ev, 1)
  local msg = ev[1].msg
  T.ok(#msg < 200 and msg:find('full block: why brew --raw (first page)', 1, true), msg)
  T.ok(msg:find('brew cancels 40/7d', 1, true) and msg:find('free empties 4', 1, true) and msg:find('vec130 FOOD_STORAGE free 0/4 taken 0/0', 1, true) and msg:find('jobs@cancel med 1', 1, true), msg)
  T.eq(ev[1].d.vid, 130)
  T.eq(ev[1].d.trunc, nil, 'the event data was not dropped as oversized')
  local all = table.concat(econ.snap_lines(W.K), '\n')
  T.ok(all:find('completions: not measurable', 1, true) and all:find('Drink stock instead: 1 stacks (units not counted, no item pass)', 1, true), all)
  -- a long headline keeps its pointer
  local s = econ.brew_snapshot(W.K)
  s.vec.name = string.rep('X', 300)
  local h = econ.BS.headline(s)
  T.ok(#h <= 199 and h:find('full block: why brew --raw (first page)', 1, true), h)
  -- the next look sees the stock delta
  F.item(W, 'DRINK', {stack_size = 5})   -- one more stack
  local s2 = econ.brew_snapshot(W.K)
  T.ok(table.concat(econ.BS.lines(s2), '\n'):find('+1 stacks since the last snapshot', 1, true), table.concat(econ.BS.lines(s2), '\n'))
end)

T.test('BUG-887 round 5: why brew --raw prints the snapshot block FIRST', function()
  local W = world('first5')
  barrel(W, {pos = {21, 23, 100}})
  local raw = require('dfllm.dfraw')
  local res = raw.brew(W.K, {})
  local l = type(res) == 'table' and (res.l or res) or {}
  T.ok(tostring(l[1]):find('brew cancel snapshot:', 1, true), tostring(l[1]))
  local seen_orders
  for i, x in ipairs(l) do if tostring(x):find('^brew: %d+ order') then seen_orders = i end end
  T.ok(seen_orders and seen_orders > 1, 'the order sheets come after the block')
end)

T.test('BUG-887 round 5: the event data fits the 1024 byte / 200 byte-per-string limits of the event layer (the least decisive fields are shed)', function()
  local BS = require('dfllm.brewsnap')
  local json = require('dfllm.util.json')
  local f = {vid = 130, vname = 'FOOD_STORAGE', vfree = 58, vfreen = 64, vtk = 5, vtkn = 6, matf = string.rep('m', 160), cxj = 37, loc = string.rep('l', 160), stills = 37, free = 64}
  for _, k in ipairs({'combo_all', 'refs_all', 'rcnt', 'filter', 'trefs', 'brefs', 'tcombo', 'bcombo', 'taken', 'refs', 'combo', 'locz', 'matt'}) do f[k] = string.rep('x', 300) end
  f = BS.fit(f)
  T.ok(#json.encode(f) <= 1024, #json.encode(f))
  for k, v in pairs(f) do T.ok(type(v) ~= 'string' or #v <= 200, k) end
  T.eq({f.vid, f.vname, f.vfree, f.vtkn, f.cxj}, {130, 'FOOD_STORAGE', 58, 6, 37}, 'the decisive fields stay')
end)

T.test('BUG-887 round 5: cost - one snapshot reads the job_item vector once, the sampler never; the DRINK stock is no item pass', function()
  local W, b = world('cost5')
  local fs = vec130(W)
  local inv = {}
  for i = 1, 3 do inv[i] = barrel(W, {pos = {21, 30 + i, 100}}); fs:insert('#', inv[i]) end
  local taken = barrel(W, {pos = {21, 40, 100}, flags = {in_job = true}})
  fs:insert('#', taken)
  b.jobs[0].items[#b.jobs[0].items + 1] = {job_item_idx = 1, item = taken}
  local econ = require('dfllm.economy')
  local items = df.global.world.items
  local real = items.other
  local reads = {}
  local proxy = setmetatable({}, {__index = function(_, k) reads[tostring(k)] = (reads[tostring(k)] or 0) + 1; return real[k] end})
  rawset(items, 'other', proxy)
  local ok, err = pcall(function()
    local env = econ.snap_env(W.K)
    env.surface = function() return false end
    env.far = function() return false end
    local s = econ.BS.collect(env)
    T.eq((reads.FOOD_STORAGE or 0) + (reads[130] or 0), 1, 'one pass over the job_item vector per snapshot: ' .. T.show(reads))
    T.eq(env.acc.vin, 1, 'accumulator membership comes from that same pass')
    T.eq(type(s.drink and s.drink.n), 'number', 'the DRINK stock is the vector length')
    -- the 600-tick sampler: no read of the vector at all
    reads = {}
    local n = econ.BS.sample(econ.snap_env(W.K), env.acc, 99999)
    T.eq((reads.FOOD_STORAGE or 0) + (reads[130] or 0) + (reads.DRINK or 0) + (reads.BARREL or 0) + (reads.TOOL or 0), 0, 'sampler reads no item vector: ' .. T.show(reads) .. ' n=' .. tostring(n))
  end)
  rawset(items, 'other', real)
  if not ok then error(err, 0) end
end)

---------------------------------------------------------------- BUG-887 round 6: the stockpile-container registry (live i2 25.11.: 3 of 3 free empties registered in a pile's storage.container_item_id)
local function piles6(W, regs)
  -- regs = {{id, name, max, ids}}: stockpiles with their registry vector
  local rows = {}
  for _, r in ipairs(regs) do
    rows[#rows + 1] = {id = r[1], name = r[2], x1 = 0, y1 = 0, x2 = 0, y2 = 0, z = 1, max_barrels = r[3], storage = {container_item_id = kmock.vec(r[4])}}
  end
  df.global.world.buildings.other.STOCKPILE = kmock.vec(rows)
  return rows
end

T.test('BUG-887 round 6: the snapshot counts free / taken / forbidden empties that a stockpile keeps as its own container, by pile tag and barrel limit; headline and fields carry it', function()
  local W, b, path = world('reg')
  local free, regd = {}, {}
  for i = 1, 5 do free[i] = barrel(W, {pos = {21, 30 + i, 100}}) end
  local forb1, forb2 = barrel(W, {flags = {forbid = true}}), barrel(W, {flags = {forbid = true}})
  local taken1, taken2 = barrel(W, {pos = {21, 40, 100}, flags = {in_job = true}}), barrel(W, {pos = {21, 41, 100}, flags = {in_job = true}})
  piles6(W, {{19788, 'dfllm-mood', 1, {free[1].id}}, {19727, 'dfllm-mood', 1, {free[2].id, forb1.id}}, {19387, 'dfllm-stock', 54, {free[3].id, 999999}}, {19846, 'dfllm-drink', 12, {}}})
  local bj = b.jobs[0]
  bj.items[#bj.items + 1] = {job_item_idx = 1, item = taken1}
  local acc_ids = {taken1.id, taken2.id, free[4].id}
  local acts0 = #W.acts
  local econ = require('dfllm.economy')
  local env = econ.snap_env(W.K)
  env.surface = function() return false end
  env.far = function() return false end
  env.acc.ids = acc_ids
  local s = econ.BS.collect(env)
  T.eq({s.rg.free, s.rg.free_n}, {3, 5}, 'three of the five free empties are registered')
  T.eq({s.rg.forb, s.rg.forb_n}, {1, 2}, 'one of the two forbidden empties')
  T.eq({s.rg.acc, s.rg.acc_n}, {0, 3}, 'the accumulator ids: none of them registered')
  T.eq({s.rg.taken, s.rg.taken_n}, {0, 1})
  T.ok(econ.BS.reg_hist(s.reg):find('dfllm-mood(max 1)=2', 1, true) and econ.BS.reg_hist(s.reg):find('dfllm-stock(max 54)=1', 1, true), econ.BS.reg_hist(s.reg))
  local line = econ.BS.line(s)
  T.ok(line:find('pile-registered: free empties 3 of 5, taken-accumulator 0 of 3, forbidden empties 1 of 2', 1, true), line)
  local all = table.concat(econ.BS.lines(s), '\n')
  T.ok(all:find('registering piles by tag (max_barrels): ', 1, true) and all:find('dfllm-mood(max 1)=2', 1, true), all)
  local head = econ.BS.headline(s)
  T.ok(head:find('pile-reg free 3/5 taken-acc 0/3', 1, true) and #head <= 199, head)
  local f = econ.BS.fields(s)
  T.eq({f.rgf, f.rgfn, f.rga, f.rgan, f.rgb, f.rgbn}, {3, 5, 0, 3, 1, 2})
  T.ok(f.rgh:find('dfllm-stock(max 54)=1', 1, true), T.show(f))
  -- the taken ones ARE registered: accumulator K of L
  piles6(W, {{1, 'dfllm-drink', 12, {taken1.id, taken2.id}}})
  env.acc.ids = acc_ids
  s = econ.BS.collect(env)
  T.eq({s.rg.acc, s.rg.acc_n, s.rg.taken}, {2, 3, 1})
  T.eq(#W.acts, acts0, 'read only: no act')
end)

T.test('BUG-887 round 6: `why items:barrels --raw` notes pile_container=#<pile> per sample line and counts the registered empties; it is no exclusion', function()
  local W = world('rawitems')
  local a = barrel(W, {pos = {21, 30, 100}})
  local c = barrel(W, {pos = {21, 31, 100}})
  piles6(W, {{19788, 'dfllm-mood', 1, {a.id}}})
  df.global.world.buildings.other.STOCKPILE[0].x1, df.global.world.buildings.other.STOCKPILE[0].x2 = 21, 21
  local raw = require('dfllm.dfraw')
  local ok, res = pcall(function() return raw.items(W.K, 'barrels', {}) end)
  if not ok or res == nil then ok, res = pcall(function() return raw.R.items and raw.R.items(W.K, 'barrels', {}) end) end
  local txt = type(res) == 'table' and table.concat(res.l or res, '\n') or tostring(res)
  T.ok(txt:find('pile_container=#19788', 1, true), txt:sub(1, 1500))
  T.ok(txt:find('1 of 2 empties are registered', 1, true) or txt:find('1 of', 1, true), txt:sub(1, 1500))
  T.ok(not txt:find('reason=pile_container', 1, true), 'no exclusion')
end)

T.done()
