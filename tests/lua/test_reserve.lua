-- dfllm.reserve (live L4): mood filters, item matching, reserve sizes; care's mood reserve on the fake world
-- (stockpiles inside Kern+, critical supply first, moods take from it, hooks for economy and trade).
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local function lib()
  package.loaded['dfllm.reserve'] = nil
  return require('dfllm.reserve')
end

-- a bare world for the pure helpers (enums, matinfo, items)
local function bare()
  local W = F.world{}
  F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
  F.mat(W, 50, 1, {token = 'PLANT:FLAX:THREAD', flags = {THREAD_PLANT = true}})
  F.mat(W, 51, 2, {token = 'CREATURE:SPIDER_CAVE_GIANT:SILK', flags = {SILK = true}})
  return W
end

local function ji(t, spec)
  local f = {item_type = t and df.item_type[t] or -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

T.test('config/baseline.json "reserve" mirrors reserve.DEFAULTS', function()
  T.eq(F.read_json('config/baseline.json').reserve, lib().DEFAULTS)
end)

T.test('hold: phase, smelter, critical supply first, never more than the fort has', function()
  local R = lib()
  local c = R.DEFAULTS
  local base = {phase = 'P1', smelter = false, alarm = false, total = 100, barrels_empty = 10, coffins_missing = 0}
  local function h(cls, over)
    local f = {}
    for k, v in pairs(base) do f[k] = v end
    for k, v in pairs(over or {}) do f[k] = v end
    return R.hold(c, cls, f)
  end
  T.eq({h('boulders'), h('logs'), h('bone'), h('shell'), h('leather'), h('cloth'), h('thread'), h('gems')},
       {20, 20, 10, 2, 10, 10, 10, 5})
  T.eq(h('boulders', {phase = 'P0'}), 0, 'before from_phase')
  T.eq(h('bars'), 0, 'no smelter')
  T.eq(h('bars', {smelter = true}), 5)
  T.eq(h('bone', {total = 3}), 3, 'what the fort has')
  T.eq(h('logs', {alarm = true}), 0, 'supply alarm: drink and food first')
  T.eq(h('logs', {total = 9, barrels_empty = 1}), 6, 'logs for 3 missing barrels stay free')
  T.eq(h('logs', {total = 9, barrels_empty = 1, coffins_missing = 2}), 4, 'and for 2 missing coffins')
  T.eq(h('boulders', {total = 8, coffins_missing = 3}), 5, 'coffins before the boulder reserve')
  T.eq(h('boulders', {total = 2, coffins_missing = 3}), 0)
  T.eq(h('cloth', {phase = 'P4', total = 30}), 10)
  T.eq(h('thread', {total = 12, cloth_short = 7}), 5, 'thread for the missing cloth stays free for the loom')
end)

T.test('job_needs: quantities (bars x150, cloth x10000), attached items, classes, labels; mood jobs only', function()
  local W = bare()
  local R = lib()
  local job = {job_type = df.job_type.StrangeMoodCrafter, items = kmock.vec{{job_item_idx = 0}, {job_item_idx = 3}},
               job_items = {elements = kmock.vec{
                 ji('BAR', {mat_type = 0, mat_index = 9, quantity = 450}),          -- 3 iron bars, 1 brought
                 ji('CLOTH', {quantity = 10000, flags2 = {silk = true}}),
                 ji(nil, {quantity = 2, flags2 = {shell = true, body_part = true}}),
                 ji('BOULDER', {mat_type = 0, flags2 = {non_economic = true}}),      -- brought
                 ji('ROUGH', {mat_type = 3}),                                         -- raw green glass
                 ji('ROUGH', {mat_type = 0}),                                         -- a rough gem
                 ji(nil, {quantity = 1, flags2 = {horn = true}}),
                 ji('CLOTH', {quantity = 2}),                                         -- items, not dimension
                 ji('TOOL', {quantity = 1}),
               }}}
  local needs = R.job_needs(job)
  local got = {}
  for _, nd in ipairs(needs) do got[#got + 1] = {nd.idx, nd.cls, nd.n, nd.label} end
  T.eq(got, {{0, 'bars', 2, 'bars x2 (iron)'}, {1, 'cloth', 1, 'cloth(silk) x1'}, {2, 'shell', 2, 'shell x2'},
             {4, 'glass', 1, 'glass x1'}, {5, 'gems', 1, 'gems x1'}, {6, 'bone', 1, 'horn x1'},
             {7, 'cloth', 2, 'cloth x2'}, {8, 'other', 1, 'tool x1'}})
  T.eq({needs[1].vecs, needs[3].vecs, needs[3].part, needs[8].vecs}, {{'BAR'}, {'CORPSEPIECE'}, 'shell', {'TOOL'}})
  T.eq(R.job_needs({job_type = df.job_type.PrepareMeal, job_items = job.job_items, items = kmock.vec{}}), nil)
  T.eq(R.job_needs({job_type = df.job_type.StrangeMoodCrafter, items = kmock.vec{}}), nil, 'unreadable filters')
  T.eq(R.job_needs({job_type = df.job_type.StrangeMoodCrafter, items = kmock.vec{{job_item_idx = 0}},
                    job_items = {elements = kmock.vec{ji('WOOD')}}}), {}, 'everything brought')
  T.eq(R.token(needs[1]), 'bar:iron')
  T.eq({R.token(needs[2]), R.token(needs[3]), R.token(needs[5])}, {'cloth', nil, 'gem'})
end)

T.test('match: type, material, metal bars, gems vs raw glass, corpse parts, cloth kind, DFHack veto', function()
  local W = bare()
  local R = lib()
  local function nd(t, spec) return R.need_of(ji(t, spec), 0, 0) end
  local iron = F.item(W, 'BAR', {mat_type = 0, mat_index = 9})
  local copper = F.item(W, 'BAR', {mat_type = 0, mat_index = 8})
  local coal = F.item(W, 'BAR', {mat_type = 7, mat_index = -1})
  T.eq({R.match(nd('BAR', {mat_type = 0, mat_index = 9}), iron), R.match(nd('BAR', {mat_type = 0, mat_index = 9}), copper)},
       {true, false})
  T.eq({R.match(nd('BAR'), copper), R.match(nd('BAR'), coal)}, {true, false}, 'metal only')
  local gem, glass = F.item(W, 'ROUGH', {mat_type = 0, mat_index = 3}), F.item(W, 'ROUGH', {mat_type = 3})
  T.eq({R.match(nd('ROUGH', {mat_type = 0}), gem), R.match(nd('ROUGH', {mat_type = 0}), glass),
        R.match(nd('ROUGH', {mat_type = 3}), glass), R.match(nd('ROUGH', {mat_type = 3}), gem)}, {true, false, true, false})
  local legacy = R.legacy_need('rough')
  T.eq({R.match(legacy, gem), R.match(legacy, glass)}, {true, true}, 'a glass furnace mood (workshop classes)')
  local bone = F.item(W, 'CORPSEPIECE', {corpse_flags = {bone = true}})
  local shell = F.item(W, 'CORPSEPIECE', {corpse_flags = {shell = true}})
  local raw = F.item(W, 'CORPSEPIECE', {corpse_flags = {bone = true, unbutchered = true}})
  local bn = nd(nil, {flags2 = {bone = true}})
  T.eq({R.match(bn, bone), R.match(bn, shell), R.match(bn, raw)}, {true, false, false})
  local horn = F.item(W, 'CORPSEPIECE', {corpse_flags = {horn = true}})
  local hn = nd(nil, {flags2 = {horn = true, body_part = true}})
  T.eq({R.match(hn, horn), R.match(hn, shell)}, {true, false}, 'horn needs a horn')
  local pearl = F.item(W, 'CORPSEPIECE', {corpse_flags = {pearl = true}})
  T.eq({R.match(nd(nil, {flags2 = {pearl = true}}), shell), R.match(nd(nil, {flags2 = {pearl = true}}), pearl)},
       {false, true}, 'a pearl needs a pearl: a bone counted for it would hide the missing material')
  T.eq(nd(nil, {flags2 = {pearl = true, body_part = true}}).label, 'pearl x1')
  T.eq(R.match(nd(nil, {flags2 = {body_part = true}}), shell), true, 'a body part alone: any butchered part')
  local flax, silk = F.item(W, 'CLOTH', {mat_type = 50, mat_index = 1}), F.item(W, 'CLOTH', {mat_type = 51, mat_index = 2})
  local sn = nd('CLOTH', {flags2 = {silk = true}})
  T.eq({R.match(sn, flax), R.match(sn, silk), R.match(nd('CLOTH'), flax)}, {false, true, true})
  df.global.plotinfo.economic_stone = {[4] = true}
  local ore, stone = F.item(W, 'BOULDER', {mat_index = 4}), F.item(W, 'BOULDER', {mat_index = 6})
  local ne = nd('BOULDER', {mat_type = 0, flags2 = {non_economic = true}})
  T.eq({R.match(ne, ore), R.match(ne, stone), R.match(nd('BOULDER', {mat_type = 0}), ore)}, {false, true, true})
  df.global.plotinfo.economic_stone = {[4] = 1, [6] = 0}           -- DF keeps bytes there
  T.eq({R.economic(ore), R.economic(stone)}, {true, false})
  df.global.plotinfo.economic_stone = nil
  -- DFHack's own checks veto (Lua API.txt:1404-1410); an error in them is ignored
  for _, it in ipairs({iron, copper}) do
    it.getSubtype = function() return -1 end
    it.getMaterial = function(self) return self.mat_type end
    it.getMaterialIndex = function(self) return self.mat_index end
  end
  dfhack.job.isSuitableItem = function() return true end
  dfhack.job.isSuitableMaterial = function(j, mt, mi) return mi ~= 8 end
  T.eq({R.match(nd('BAR'), iron), R.match(nd('BAR'), copper)}, {true, false})
  dfhack.job.isSuitableMaterial = function() error('no such job item') end
  T.eq(R.match(nd('BAR'), copper), true)
  dfhack.job.isSuitableItem, dfhack.job.isSuitableMaterial = nil, nil
end)

T.test('item_class, busy, carried', function()
  local W = bare()
  local R = lib()
  local function cls(cat, spec) return R.item_class(F.item(W, cat, spec or {})) end
  T.eq({cls('BOULDER'), cls('WOOD'), cls('CORPSEPIECE', {corpse_flags = {bone = true}}),
        cls('CORPSEPIECE', {corpse_flags = {shell = true}}), cls('SKIN_TANNED'), cls('CLOTH'), cls('THREAD'),
        cls('SMALLGEM'), cls('ROUGH'), cls('BAR')},
       {'boulders', 'logs', 'bone', 'shell', 'leather', 'cloth', 'thread', 'gems', 'gems', 'bars'})
  T.eq({cls('ROUGH', {mat_type = 3}), cls('BAR', {mat_type = 7}), cls('CORPSEPIECE', {corpse_flags = {unbutchered = true,
        bone = true}}), cls('DOOR')}, {nil, nil, nil, nil})
  local bin = F.item(W, 'BIN', {flags = {}})
  local held = F.item(W, 'CLOTH', {flags = {in_inventory = true}})
  local binned = F.item(W, 'CLOTH', {flags = {in_inventory = true}, _cont = bin})
  T.eq({R.carried(held), R.carried(binned)}, {true, false})
  bin.flags.in_job = true
  T.eq(R.carried(binned), true, 'the bin is being hauled')
  T.eq({R.busy(F.item(W, 'CLOTH', {flags = {owned = true}})), R.busy(F.item(W, 'CLOTH'))}, {true, false})
  T.eq(R.busy(F.item(W, 'THREAD', {flags = {spider_web = true}})), true, 'an uncollected cavern web is no stock')
  T.eq({R.is_container(F.item(W, 'BIN', {flags = {container = true}})), R.is_container(F.item(W, 'BIN'))},
       {true, false})
end)

---------------------------------------------------------------- care's reserve on the fake world
local function stock(W, n, cat, spec, pos)
  local out = {}
  for i = 1, n do
    local s = {flags = {}, _pos = pos or {10, 10, 5}}
    for k, v in pairs(spec or {}) do s[k] = v end
    out[i] = F.item(W, cat, s)
  end
  return out
end

local function join(...)
  local r = {}
  for _, l in ipairs({...}) do for _, x in ipairs(l) do r[#r + 1] = x end end
  return r
end

local function ids(list)
  local r = {}
  for i, it in ipairs(list) do r[i] = it.id end
  table.sort(r)
  return r
end

-- a fort in P1 with stock in a dfllm-reserve pile, an unnamed pile and the trade pile
local function fort(opts)
  opts = opts or {}
  local S = {}
  local W, Cm = CW.world{phase = opts.phase or 'P1', mode = opts.mode, alarm = opts.alarm, reserve = opts.reserve,
                         census_i = opts.census_i or {boulders = 31, rock = 31, wood = 25, bone = 13, cloth = 3},
                         persist = opts.persist, economy = opts.economy, economy_reserve = opts.economy_reserve,
                         strict = opts.strict,
                         setup = function(W)
    df.global.plotinfo.economic_stone = {[4] = true}
    S.r_boulders = stock(W, 3, 'BOULDER', {mat_index = 6})
    S.r_logs = stock(W, 2, 'WOOD')
    CW.pile(W, 'dfllm-reserve', join(S.r_boulders, S.r_logs))
    S.boulders = stock(W, 25, 'BOULDER', {mat_index = 6})
    S.ore = stock(W, 1, 'BOULDER', {mat_index = 4})                         -- economic: never held
    S.outside = stock(W, 1, 'BOULDER', {mat_index = 6}, {100, 100, 5})      -- outside Kern+
    S.hidden = stock(W, 1, 'BOULDER', {mat_index = 6}, {33, 33, 5})
    W.hidden['33,33,5'] = true
    S.busy = join(stock(W, 1, 'BOULDER', {mat_index = 6, flags = {in_job = true}}),
                  stock(W, 1, 'BOULDER', {mat_index = 6, flags = {dump = true}}),
                  stock(W, 1, 'BOULDER', {mat_index = 6, flags = {forbid = true}}))
    S.logs = stock(W, 25, 'WOOD')
    S.bones = stock(W, 12, 'CORPSEPIECE', {unit_id = 700, corpse_flags = {bone = true}})
    S.citizen_bone = stock(W, 1, 'CORPSEPIECE', {unit_id = 2, corpse_flags = {bone = true}})
    S.cloth = stock(W, 3, 'CLOTH')
    S.bars = stock(W, 6, 'BAR', {mat_type = 0, mat_index = 9})
    CW.pile(W, '', join(S.busy, S.ore, S.outside, S.hidden, S.boulders, S.logs, S.citizen_bone, S.bones, S.cloth, S.bars))
    S.trade_cloth = stock(W, 5, 'CLOTH')
    CW.pile(W, 'dfllm-trade', S.trade_cloth)
    if opts.setup then opts.setup(W, S) end
  end}
  return W, Cm, S
end

local function count_held(W)
  local n = 0
  for _, l in pairs(CW.held(W)) do n = n + #l end
  return n
end

T.test('reserve: fills from stockpiles inside Kern+ (dfllm-reserve first), 20 writes a run, the right items only', function()
  local W, Cm, S = fort{economy = true}
  W.run(1)
  T.eq(count_held(W), 20, 'per_run')
  local first = {}
  for i = 1, 5 do first[i] = W.find_acts('item_flag')[i].args[1] end
  table.sort(first)
  T.eq(first, ids(join(S.r_boulders, S.r_logs)), 'the dfllm-reserve pile first')
  CW.day(W, 3)
  local h = CW.held(W)
  T.eq({#h.boulders, #h.logs, #h.bone, #h.cloth, h.bars, h.leather}, {20, 20, 10, 3, nil, nil})
  local held = {}
  for _, l in pairs(h) do for _, id in ipairs(l) do held[id] = true end end
  for _, it in ipairs(join(S.ore, S.outside, S.hidden, S.busy, S.citizen_bone, S.trade_cloth, S.bars)) do
    T.ok(not held[it.id], 'not held: ' .. it.id)
  end
  for _, a in ipairs(W.find_acts('item_flag')) do T.eq({a.args[2], a.args[3]}, {'forbid', true}) end
  T.eq(Cm.reserved(W.K), {boulders = 20, logs = 20, bone = 10, shell = 0, leather = 0, cloth = 3, thread = 0, gems = 0,
                          bars = 0})
  T.eq(Cm.mood_wants(W.K), {}, 'no mood')
  T.ok(json.encode(Cm.reserved(W.K)))
  -- the floors economy's own consumers keep (economy.reserve = the hold, pushed on change and once per boot);
  -- the fake census keeps 3 free cloth, so the cloth floor rose to 3 + 3 held once the cloth was held
  T.eq(W.floors, {boulders = 20, logs = 20, bone = 10, shell = 0, leather = 0, cloth = 6, thread = 0, gems = 0,
                  bars = 0})
  T.eq({W.floor_calls, W.floor_who}, {10, 'care'}, 'unchanged floors are not sent again (cloth changed once)')
  df.global.plotinfo.economic_stone = nil
end)

T.test('reserve: the floor push follows the alarm; a faulting economy hook is not called again this boot', function()
  local W = fort{economy = true, alarm = false}
  W.run(1)
  T.eq(W.floors.logs, 20)
  W.alarm = 'thirst 2'
  CW.day(W)
  T.eq({W.floors.logs, W.floor_calls}, {0, 10}, 'wood floor down to 0 in the supply alarm, nothing else sent')
  local calls = 0
  local W2 = fort{economy = true, strict = false,
                  economy_reserve = function() calls = calls + 1; error('other signature') end}
  CW.day(W2, 3)
  T.eq(calls, 1)
  T.eq(#W2.faults, 1, 'one fault against economy, not one a day')
  T.ok(count_held(W2) > 0, 'the reserve itself works on')
  df.global.plotinfo.economic_stone = nil
end)

T.test('reserve: nothing before P1, nothing without the item census, nothing topped up in a siege', function()
  local W = fort{phase = 'P0'}
  CW.day(W, 2)
  T.eq(W.find_acts('item_flag'), {})
  W.phase = 'P1'
  W.state()
  CW.day(W, 2)
  T.ok(count_held(W) > 0, 'P1 reached: filled')
  local W2 = fort{}
  W2.set_census('i', nil)
  CW.day(W2, 2)
  T.eq(W2.find_acts('item_flag'), {})
  local W3 = fort{mode = 'SIEGE'}
  CW.day(W3, 2)
  T.eq(W3.find_acts('item_flag'), {})
  df.global.plotinfo.economic_stone = nil
end)

T.test('reserve: no phase yet (first frames after a boot): the held items stay held', function()
  local persist = {['m.care'] = {v = 2, dead = {}, deaths = {}, petitions = {}, reserve = {held = {logs = {8801, 8802}}}}}
  local W = CW.world{persist = persist, census_i = {wood = 0}, setup = function(W)
    local a = F.item(W, 'WOOD', {id = 8801, flags = {forbid = true}, _pos = {10, 10, 5}})
    local b = F.item(W, 'WOOD', {id = 8802, flags = {forbid = true}, _pos = {10, 11, 5}})
    CW.pile(W, '', {a, b})
  end}
  CW.day(W, 2)
  T.eq(W.find_acts('item_flag'), {})
  T.eq(CW.held(W), {logs = {8801, 8802}})
end)

T.test('reserve: a class nothing was found for is not searched daily (until its stock changes or a week passed)', function()
  local calls = 0
  local W = CW.world{phase = 'P1', census_i = {leather = 5}, setup = function(W)
    CW.pile(W, '', {F.item(W, 'CLOTH', {_pos = {10, 10, 5}})})
  end}
  dfhack.buildings.getStockpileContents = function(sp) calls = calls + 1; return sp._items or {} end
  W.run(1)
  T.eq(calls, 1, 'one full pass: no leather in any pile')
  CW.day(W, 3)
  T.eq(calls, 1, 'not again for the same stock')
  W.set_census('i', CW.census_i{leather = 6})
  CW.day(W)
  T.eq(calls, 2, 'the stock changed')
  CW.day(W, 8)
  T.eq(calls, 3, 'and once a week')
end)

T.test('reserve: bars only with a smelter', function()
  local W = fort{reserve = {per_run = 100}, census_i = {boulders = 31, rock = 31, wood = 25, bone = 13, cloth = 3, bars = 6},
                 setup = function(W) F.workshop(W, 'Smelter', true) end}
  W.run(1)
  T.eq(#CW.held(W).bars, 5)
  df.global.plotinfo.economic_stone = nil
end)

T.test('reserve: critical supply first: missing barrels and the supply alarm release logs', function()
  local W = fort{reserve = {per_run = 100}, alarm = false}
  W.run(1)
  T.eq(#CW.held(W).logs, 20)
  local c = CW.census_i{boulders = 31, wood = 0, bone = 3, cloth = 0, barrels_empty = 2}
  W.set_census('i', c)                            -- every log is held now; 2 empty barrels are missing
  W.clear()
  CW.day(W)
  T.eq(#CW.held(W).logs, 18, 'two logs for barrels')
  T.eq(#CW.flags(W, 'forbid'), 2)
  for _, f in ipairs(CW.flags(W)) do T.eq({f[2], f[3]}, {'forbid', false}) end
  W.alarm = 'thirst 3'
  CW.day(W)
  T.eq(CW.held(W).logs, nil, 'supply alarm: no wood held')
  T.eq(#CW.held(W).boulders, 20, 'the alarm releases wood only')
  df.global.plotinfo.economic_stone = nil
end)

T.test('reserve: coffins for open citizen corpses come before boulders and logs', function()
  local W = fort{reserve = {per_run = 100}, census_i = {boulders = 22, rock = 22, wood = 21}, setup = function(W, S)
    W.kill(3)
    for i = 1, 3 do F.item(W, 'ANY_CORPSE', {unit_id = 3, flags = {}, _pos = {5, 5, 5}}) end
    W.kill(4)
    F.item(W, 'ANY_CORPSE', {unit_id = 4, flags = {}, _pos = {5, 6, 5}})
  end}
  W.run(1)
  local h = CW.held(W)
  T.eq({#h.boulders, #h.logs}, {20, 19}, '2 open corpses, no free tomb: 2 coffins stay buildable')
  df.global.plotinfo.economic_stone = nil
end)

T.test('reserve: a mood takes from it; the class is not topped up while the mood needs it', function()
  local W = fort{reserve = {per_run = 100}, setup = function(W, S)
    S.extra = stock(W, 3, 'CLOTH')
    CW.pile(W, 'cloth pile', S.extra)                -- free cloth the mood does not need
  end}
  W.run(1)
  local cloth = CW.held(W).cloth
  T.eq(#cloth, 3)
  local u = W.unit(1)
  u.mood = df.mood_type.Fey
  u.job.current_job = CW.mood_job(W, 901, F.workshop(W, 'Clothiers'), {
    {item_type = df.item_type.CLOTH, mat_type = -1, mat_index = -1, quantity = 20000, flags2 = {}}})
  W.set_census('i', CW.census_i{boulders = 31, wood = 5, bone = 3, cloth = 5})
  W.clear()
  CW.day(W)
  T.eq(#CW.flags(W, 'forbid'), 2, 'two held cloth freed for the mood')
  T.eq(#CW.held(W).cloth, 1, 'and none forbidden again while the mood needs cloth')
  T.eq(W.find_events('MOOD_NEED'), {})
  u.mood = -1
  u.job.current_job = nil
  CW.day(W, 2)                                       -- the census after the mood's release comes first
  T.ok(#CW.held(W).cloth >= 3, 'mood over: topped up')
  df.global.plotinfo.economic_stone = nil
end)

T.test('reserve: held items that left (consumed, unforbidden by a player, built in) drop off the list', function()
  local W, Cm, S = fort{reserve = {per_run = 100}}
  W.run(1)
  local logs = CW.held(W).logs
  W.items_by_id[logs[1]] = nil                       -- consumed
  W.items_by_id[logs[2]].flags.forbid = false        -- a player unforbade it
  W.items_by_id[logs[3]].flags.in_building = true
  W.set_census('i', CW.census_i{boulders = 31, wood = 1, bone = 3, cloth = 0})   -- the unforbidden log is free stock
  CW.day(W)
  T.eq(#CW.held(W).logs, 17, 'three dropped; no top-up on a census older than the last write')
  CW.day(W)
  T.eq(#CW.held(W).logs, 18, 'a fresh census: one free log held again (17 held + 1 free)')
  for _, id in ipairs(CW.held(W).logs) do T.ok(id ~= logs[1] and id ~= logs[3], 'gone or built in: ' .. id) end
  df.global.plotinfo.economic_stone = nil
end)

T.test('reserve: a census older than the last write counts nothing twice (the critical part stays free)', function()
  -- 9 logs in a pile, 3 open citizen corpses and no free tomb: 6 may be held, 3 stay for coffins. The census
  -- skips forbidden items, but until economy's next census it still shows all 9 logs as free.
  local W = CW.world{phase = 'P1', census_i = {wood = 9}, reserve = {per_run = 100}, setup = function(W)
    local logs = {}
    for i = 1, 9 do logs[i] = F.item(W, 'WOOD', {_pos = {10, 10, 5}}) end
    CW.pile(W, '', logs)
    for _, id in ipairs({3, 4, 2}) do
      W.kill(id)
      F.item(W, 'ANY_CORPSE', {unit_id = id, flags = {}, _pos = {5, 5, 5}})
    end
  end}
  W.run(1)
  T.eq(#CW.held(W).logs, 6)
  W.run(1200, {skip = 100})                          -- the next run, still on the old census
  T.eq(#CW.held(W).logs, 6, 'not 9: census 9 + held 6 would read as 15 logs')
  W.set_census('i', CW.census_i{wood = 3})           -- the census after the write: 3 free
  CW.day(W, 2)
  T.eq(#CW.held(W).logs, 6, 'steady')
  T.eq(#CW.flags(W, 'forbid'), 6, 'no forbid / unforbid flapping')
end)

T.test('reserve: boulders sized from free non-economic stone, thread from collected thread', function()
  -- the BOULDER vector holds built-in, economic and cavern stone (300); 8 free boulders, 2 of them ore; 2 open
  -- corpses: 4 boulders may be held. 40 cavern webs but 3 collected threads, 10 cloth short: none held.
  local W = CW.world{phase = 'P1', reserve = {per_run = 100},
                     census_i = {boulders = 300, rock = 8, ore = 2, flux = 0, thread = 3, cloth = 0}, setup = function(W)
    local items = {}
    for i = 1, 6 do items[#items + 1] = F.item(W, 'BOULDER', {mat_index = 6, _pos = {10, 10, 5}}) end
    for i = 1, 3 do items[#items + 1] = F.item(W, 'THREAD', {_pos = {10, 10, 5}}) end
    for i = 1, 40 do F.item(W, 'THREAD', {flags = {spider_web = true}, _pos = {40, 40, 5}}) end
    CW.pile(W, '', items)
    for _, id in ipairs({3, 4}) do
      W.kill(id)
      F.item(W, 'ANY_CORPSE', {unit_id = id, flags = {}, _pos = {5, 5, 5}})
    end
  end}
  W.run(1)
  local h = CW.held(W)
  T.eq({#(h.boulders or {}), h.thread}, {4, nil})
  local W2 = CW.world{phase = 'P1', census_i = {boulders = 300}, setup = function(W)   -- an economy without `rock`
    CW.pile(W, '', {F.item(W, 'BOULDER', {mat_index = 6, _pos = {10, 10, 5}})})
  end}
  CW.day(W2, 2)
  T.eq(CW.held(W2).boulders, nil, 'free stone unknown: nothing new held')
end)

T.test('reserve: items in a pile\'s bins are held too; a pile removed between frames is skipped', function()
  local W = CW.world{phase = 'P1', census_i = {cloth = 4, gems = 2}, setup = function(W)
    local cloth = {}
    for i = 1, 4 do cloth[i] = F.item(W, 'CLOTH', {flags = {in_inventory = true}, _pos = {10, 10, 5}}) end
    local bin = F.item(W, 'BIN', {flags = {container = true}, _contents = cloth, _pos = {10, 10, 5}})
    for _, c in ipairs(cloth) do c._cont = bin end
    CW.pile(W, '', {bin})
    W.gone = CW.pile(W, 'gone', {F.item(W, 'SMALLGEM', {_pos = {10, 10, 5}})})
  end}
  W.buildings[W.gone.id] = nil                       -- removed by a player before the reserve reached it
  W.run(1)
  T.eq(#CW.held(W).cloth, 4, 'getStockpileContents lists the bin, not what it holds')
  T.eq(CW.held(W).gems, nil)
end)

T.test('reserve: a held log that left Kern+ (its bin was moved) is released in PEACE, not held forever', function()
  local persist = {['m.care'] = {v = 2, dead = {}, deaths = {}, petitions = {}, reserve = {held = {logs = {8801}}}}}
  local W = CW.world{phase = 'P1', persist = persist, alarm = 'thirst 2', census_i = {wood = 0}, setup = function(W)
    F.item(W, 'WOOD', {id = 8801, flags = {forbid = true}, _pos = {100, 100, 5}})
  end}
  W.run(1)
  T.eq(CW.flags(W), {{8801, 'forbid', false}}, 'supply alarm: no wood held, wherever it lies')
  T.eq(CW.held(W), {})
end)

T.test('reserve: a held bone near the approach is no corpse to dump', function()
  local persist = {['m.care'] = {v = 2, dead = {}, deaths = {}, petitions = {}, reserve = {held = {bone = {7777}}}}}
  local W = fort{reserve = {per_run = 100}, persist = persist, setup = function(W, S)
    local b = F.item(W, 'CORPSEPIECE', {id = 7777, unit_id = 705, corpse_flags = {bone = true}, flags = {forbid = true},
                                        _pos = {21, 21, 9}})        -- within 15 tiles of O1, inside Kern+
    df.global.world.items.other.ANY_CORPSE:insert('#', b)
  end}
  CW.day(W, 2)
  T.eq(CW.flags(W, 'dump'), {}, 'never dumped while held')
  local held = {}
  for _, id in ipairs(CW.held(W).bone) do held[id] = true end
  T.ok(held[7777], 'still held')
  df.global.plotinfo.economic_stone = nil
end)

T.test('hooks through K.call: economy reads care.reserved and care.mood_wants', function()
  local seen = {}
  local W = fort{reserve = {per_run = 100}, setup = function(W)
    W.load({name = 'test_hook', every = {ticks = 1200}, step = function(K)
      local ok, r = K.call('care', 'reserved')
      local ok2, w = K.call('care', 'mood_wants')
      seen[#seen + 1] = {ok and r.boulders, ok2 and #w}
    end})
  end}
  CW.day(W, 2)
  T.eq(seen[#seen], {20, 0})
  df.global.plotinfo.economic_stone = nil
end)

T.done()
