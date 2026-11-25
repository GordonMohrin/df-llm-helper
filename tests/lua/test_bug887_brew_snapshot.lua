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
  T.ok(all:find('attached to the brew job: #' .. tostring(taken.id), 1, true), all)
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
  T.ok(all:find('nothing taken to compare', 1, true) and all:find('taken by DF none attached', 1, true), all)
end)

T.done()
