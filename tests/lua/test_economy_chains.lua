-- economy (live L4): supply chains (wood, barrels, leather, cloth, metal), soldiers' gear, the hook API
-- (need/reserve/supply), care's pull hooks (reserved, mood_wants) and the sliced daily run.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

F.ITEM_TYPES[#F.ITEM_TYPES + 1] = 'QUIVER'     -- a real items_other vector the WP8 fakes do not list

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

-- materials: inorganic 50.. metals, 60.. ores; organic 37 leather, 419 plants
local METALS = {[50] = 'COPPER', [51] = 'IRON', [52] = 'TIN', [53] = 'BRONZE'}
local ORES = {[60] = {'MALACHITE', {50}}, [61] = {'CASSITERITE', {52}}, [62] = {'HEMATITE', {51}}}

-- W, ctl: ctl.phase, ctl.per (military targets per squad key), ctl.held/wants (care hooks), ctl.naked
local function world(opts)
  opts = opts or {}
  local ctl = {phase = opts.phase or 'P3', per = opts.per, held = opts.held, wants = opts.wants,
               naked = opts.naked or 0}
  local units = {}
  for i = 1, opts.cit or 10 do units[i] = {id = i, citizen = true} end
  local cfg = F.cfg()
  for k, v in pairs(opts.eco or {}) do cfg.economy[k] = v end
  local W = F.world{cfg = {baseline = cfg}, units = units, mode = opts.mode, strict = opts.strict}
  local ids = {}
  for i = 1, opts.cit or 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  for i, name in pairs(METALS) do F.mat(W, 0, i, {token = 'INORGANIC:' .. name, flags = {IS_METAL = true}}) end
  for i, o in pairs(ORES) do F.mat(W, 0, i, {token = 'INORGANIC:' .. o[1], flags = {}}) end
  F.mat(W, 37, 5, {token = 'CREATURE:COW:LEATHER', flags = {LEATHER = true}})
  F.mat(W, 419, 70, {token = 'PLANT:GRASS_TAIL_PIG:SEED', flags = {}})
  F.mat(W, 419, 71, {token = 'PLANT:GRASS_TAIL_PIG:THREAD', flags = {THREAD_PLANT = true}})
  F.mat(W, 419, 72, {token = 'CREATURE:SPIDER_CAVE_GIANT:SILK', flags = {SILK = true}})
  local decode = dfhack.matinfo.decode
  dfhack.matinfo.decode = function(t, i)                 -- inorganic raws: metal_ore, reaction classes
    if type(t) == 'table' then t, i = t.mat_type, t.mat_index end
    local m = decode(t, i)
    if m and t == 0 then
      local o = ORES[i]
      m.inorganic = {metal_ore = {mat_index = kmock.vec(o and o[2] or {})}}
      m.material.reaction_class = kmock.vec{}
    end
    return m
  end
  W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
  W.subdefs[2] = {id = 'ITEM_WEAPON_AXE_BATTLE', skill_melee = df.job_skill.AXE, skill_ranged = -1}
  W.subdefs[3] = {id = 'ITEM_WEAPON_CROSSBOW', skill_melee = df.job_skill.CROSSBOW, skill_ranged = df.job_skill.CROSSBOW}
  W.subdefs[4] = {id = 'ITEM_AMMO_BOLTS'}
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = ctl.phase} end})
  if ctl.per then
    W.load({name = 'military', every = {ticks = 3600},
            targets = function() local n = 0; for _, v in pairs(ctl.per) do n = n + v end; return n, ctl.per end,
            kpi = function() return {worn = 15, slots = 20, specs = 20} end})
  end
  if opts.care then
    W.load({name = 'care', every = {ticks = 1200},
            reserved = opts.care_reserved or function() return ctl.held end,
            mood_wants = function() return ctl.wants end,
            state = function() return {care = {stressed_pct = 0, naked = ctl.naked, ghosts = 0, corpses_old = 0,
                                               tombs_free = 0, moods = 0}} end})
  end
  for _ = 1, opts.barrels or 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = opts.drinks or 2000})
  F.item(W, 'FOOD', {stack_size = opts.food or 2000, subtype = 1})
  for _ = 1, opts.wood or 0 do F.item(W, 'WOOD', {}) end
  for _, ws in ipairs(opts.shops or {}) do F.workshop(W, ws) end
  for _, ws in ipairs(opts.furnaces or {}) do F.workshop(W, ws, true) end
  if opts.setup then opts.setup(W, ctl) end
  local E = fresh('economy')
  W.load(E)
  ctl.E = E
  return W, ctl
end

local function orders(W, prefix)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do
    local s = a.args[1]
    if not prefix or s.tag:sub(1, #prefix) == prefix then r[#r + 1] = s end
  end
  return r
end
local function order(W, tag)          -- the last order with exactly this tag
  local o
  for _, s in ipairs(orders(W, tag)) do if s.tag == tag then o = s end end
  return o
end
local function eco_warns(W)
  local r = {}
  for _, l in ipairs(W.logs) do
    local m = tostring(l.msg)
    if l.module == 'economy' and l.level == 'warn' and (m:find('^economy task') or m:find('^tool details') or
       m:find('^wood orders') or m:find('^census') or m:find('^care%.')) then r[#r + 1] = m end
  end
  return r
end
local function persist(W) return json.decode(W.persist_raw['dfllm.m.economy']) end

T.test('hook API: need() raises target and floor, rushes the next run, expires; reserve(); supply(); aliases', function()
  local W, ctl = world{phase = 'P0', wood = 60, shops = {'Tanners', 'Carpenters'}, setup = function(W)
    for _ = 1, 3 do F.item(W, 'CORPSEPIECE', {corpse_flags = {leather = true}}) end    -- raw hides
  end}
  days(W, 1)
  T.eq(order(W, 'dfllm:tan'), nil, 'P0: no mood stock, no tanning')
  local ok, nok, route = W.K.call('economy', 'need', 'leather', 2, 'mood:7')
  T.ok(ok and nok, 'need accepted')
  T.eq(route, 'tan')
  T.eq(ctl.E.every.ticks, 100, 'a new need: the next run within rush_ticks')
  W.run(150, {skip = 50}); settle(W)
  T.eq(ctl.E.every.ticks, 1200, 'back to the daily cadence')
  days(W, 1)
  local tan = order(W, 'dfllm:tan')
  T.ok(tan, 'raw hides older than 2 days are tanned for the need')
  T.eq({tan.job, tan.reaction, tan.amount_total}, {'CustomReaction', 'TAN_A_HIDE', 2})
  local _, sup = W.K.call('economy', 'supply')
  T.eq(sup.leather.floor, 2, 'an open need is a floor too')
  T.eq(sup.leather.want, 2)
  -- reserve: economy's own wood consumers keep 50 logs
  local _, rok, floor = W.K.call('economy', 'reserve', 'logs', 50, 'test')
  T.ok(rok)
  T.eq(floor, 50, 'logs is an alias of wood')
  T.eq(select(2, W.K.call('economy', 'need', 'mithril', 1, 'x')), false, 'unknown key refused')
  local _, rk, why = W.K.call('economy', 'need', 'boulders', 3, 'mood:8')
  T.eq({rk, why}, {false, 'no route: stone dig (runner/LLM)'})
  T.eq(select(2, W.K.call('economy', 'supply')).rock.floor, 3, 'a need without a route still holds the floor')
  -- expiry
  W.K.call('economy', 'need', 'leather', 2, 'mood:7', 1)
  days(W, 2)
  T.eq(select(2, W.K.call('economy', 'supply')).leather.floor, 2, 'expired after its days: the standing reserve (Run 10)')
  T.eq(eco_warns(W), {})
end)

T.test('care hooks: held reserve counts as stock and lowers the floor; mood_wants become needs; a bad hook is dropped', function()
  local W, ctl = world{care = true, phase = 'P1', wood = 30, barrels = 0, drinks = 10,
                       shops = {'Carpenters'}, held = {logs = 20, leather = 3}, wants = {{cls = 'leather', n = 2}}}
  days(W, 1)
  local b = order(W, 'dfllm:barrel')
  T.ok(b, 'barrels ordered (drink low)')
  T.eq(b.item_conditions[1].value, 1, 'care holds 20 logs forbidden: economy keeps no extra floor')
  local _, sup = W.K.call('economy', 'supply')
  T.eq({sup.leather.have, sup.leather.held, sup.wood.held}, {3, 3, 20})
  T.eq(sup.leather.floor, 2, "care's mood want is a need (floor)")
  local raw = W.persist_raw['dfllm.m.economy']
  T.ok(raw:find('"care":{"n":2', 1, true), raw)
  -- a hook with another signature faults once and is then left alone (no daily fault on care)
  local calls = 0
  local W2 = world{care = true, strict = false, care_reserved = function(K, cls) calls = calls + 1; return cls.x end}
  days(W2, 3)
  T.eq(calls, 1, 'called once, then dropped for this boot')
end)

T.test('leather: hunters only with bolts; no catch for 10 days -> 20 days off; bolts ordered for them', function()
  local function hw(opts)
    local W, ctl = world{phase = 'P1', wood = 100, shops = {'Craftsdwarfs', 'Tanners'}, setup = function(W, ctl)
      local function wd(name, labor) return {name = name, assigned_units = kmock.vec{}, allowed_labors = {[labor] = true}, flags = {mode = 3}} end
      ctl.wds = {Miners = wd('Miners', 1), Woodcutters = wd('Woodcutters', 2), Hunters = wd('Hunters', 3)}
      df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wds.Miners, ctl.wds.Woodcutters, ctl.wds.Hunters}}
      W.act_result('run', function(cmd, a1) if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: monitor' end return true, '' end)
      W.act_result('work_detail', function(name, id, on)
        local v = ctl.wds[name].assigned_units
        for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
        if on then v:insert('#', id) end
        return true
      end)
      F.item(W, 'WEAPON', {subtype = 3})
      if opts.bolts then F.item(W, 'AMMO', {subtype = 4, stack_size = opts.bolts}) end
    end}
    for i = 1, 10 do W.unit(i).status.labors = {}; W.unit(i).mood = -1 end
    return W, ctl
  end
  local W, ctl = hw{bolts = 0}
  days(W, 1)
  T.eq(#ctl.wds.Hunters.assigned_units, 0, 'no bolts: no hunter')
  local bolts = order(W, 'dfllm:gear_bolts')
  T.ok(bolts, 'bolts for the hunter')
  T.eq({bolts.job, bolts.item_subtype, bolts.material_category, bolts.amount_total}, {'MakeAmmo', 'ITEM_AMMO_BOLTS', {'wood'}, 1})
  local W2, ctl2 = hw{bolts = 25}
  days(W2, 1)
  T.eq(#ctl2.wds.Hunters.assigned_units, 1, 'leather/bone/shell short, bolts at hand: one hunter')
  days(W2, 11)
  T.ok((persist(W2).hunt_off or 0) > 0, 'nothing caught for 10 days: hunting paused')
  days(W2, 4)
  T.eq(#ctl2.wds.Hunters.assigned_units, 0, 'the hunter left after shrink_days')
  -- a strange mood needs leather: hunting resumes through the pause (two hunters for an open need)
  W2.K.call('economy', 'need', 'leather', 1, 'mood:3')
  W2.run(150, {skip = 50}); settle(W2)
  T.eq(#ctl2.wds.Hunters.assigned_units, 1, 'an unmet mood need hunts despite no game (capped by the one crossbow)')
  -- a catch keeps the trial going
  local W3, ctl3 = hw{bolts = 25}
  days(W3, 6)
  F.item(W3, 'CORPSEPIECE', {corpse_flags = {bone = true}})
  days(W3, 6)
  T.eq(persist(W3).hunt_off, nil, 'a new bone restarted the 10-day trial')
  T.eq(#ctl3.wds.Hunters.assigned_units, 1)
  T.eq(eco_warns(W2), {})
end)

T.test('hunters leave the detail at once when the fort leaves PEACE (MODE rushes the run); no famine hunt in a siege', function()
  local function hw(opts)
    local W, ctl = world{phase = 'P1', wood = 100, mode = opts.mode, food = opts.food, shops = {'Craftsdwarfs', 'Tanners'},
                         setup = function(W, ctl)
      local function wd(name, labor) return {name = name, assigned_units = kmock.vec{}, allowed_labors = {[labor] = true}, flags = {mode = 3}} end
      ctl.wds = {Miners = wd('Miners', 1), Woodcutters = wd('Woodcutters', 2), Hunters = wd('Hunters', 3)}
      df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wds.Miners, ctl.wds.Woodcutters, ctl.wds.Hunters}}
      W.act_result('run', function(cmd, a1) if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: monitor' end return true, '' end)
      W.act_result('work_detail', function(name, id, on)
        local v = ctl.wds[name].assigned_units
        for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
        if on then v:insert('#', id) end
        return true
      end)
      F.item(W, 'WEAPON', {subtype = 3}); F.item(W, 'WEAPON', {subtype = 3})
      F.item(W, 'AMMO', {subtype = 4, stack_size = 50})
    end}
    for i = 1, 10 do W.unit(i).status.labors = {}; W.unit(i).mood = -1 end
    return W, ctl
  end
  local W, ctl = hw{}
  days(W, 1)
  T.eq(#ctl.wds.Hunters.assigned_units, 1, 'PEACE, bone/leather short: one hunter')
  W.K.set_mode('ALERT', 'test')
  T.eq(ctl.E.every.ticks, 100, 'leaving PEACE with a hunter out: the next run within rush_ticks')
  W.run(150, {skip = 50}); settle(W)
  T.eq(#ctl.wds.Hunters.assigned_units, 0, 'off the detail at once, not after shrink_days')
  local off
  for _, e in ipairs(W.find_events('WORK_DETAIL')) do if e.d.detail == 'Hunters' and e.d.on == 0 then off = e end end
  T.ok(off and off.d.why == 'mode ALERT', 'reason logged')
  days(W, 2)
  T.eq(#ctl.wds.Hunters.assigned_units, 0, 'none while not in PEACE')
  -- famine: hunters in PEACE (and RECOVERY), never while invaders are about
  local W2, ctl2 = hw{mode = 'SIEGE', food = 1}
  days(W2, 2)
  T.ok(persist(W2).famine ~= nil, 'famine')
  T.eq(#ctl2.wds.Hunters.assigned_units, 0, 'no famine hunters in a siege')
  local W3, ctl3 = hw{food = 1}
  days(W3, 2)
  T.eq(#ctl3.wds.Hunters.assigned_units, 2, 'famine in PEACE: two hunters')
  local W5, ctl5 = hw{food = 4}                    -- Run 11: 16 food days, the food_low pre-alarm hunts like a famine
  days(W5, 2)
  T.ok(persist(W5).famine == nil and persist(W5).food_pre ~= nil, 'pre-alarm, no famine')
  T.eq(#ctl5.wds.Hunters.assigned_units, 2, 'food low in PEACE: two hunters')
  T.eq(eco_warns(W), {})
  -- the only bolts sit in a soldier's quiver: a hunter would fight in melee, so none is sent
  local W4, ctl4 = hw{}
  local soldier = {military = {squad_id = 1}}
  dfhack.items.getHolderUnit = function(it) return it._unit end
  local v = df.global.world.items.other.AMMO
  for i = 0, #v - 1 do v[i]._cont = {flags = {in_inventory = true}, _unit = soldier} end
  days(W4, 2)
  T.eq(W4.K.census.i.bolts, 50)
  T.eq(W4.K.census.i.bolts_free, 0)
  T.eq(#ctl4.wds.Hunters.assigned_units, 0, "the soldiers' bolts are no hunter's")
  dfhack.items.getHolderUnit = nil
end)

T.test('census: dead citizens remains are no bone; only true armor fills body/head/pants; mood STOCK_LOW sees care held', function()
  local W = world{care = true, phase = 'P1', held = {bone = 10}, setup = function(W)
    F.item(W, 'CORPSEPIECE', {corpse_flags = {bone = true}, flags = {dead_dwarf = true}})     -- a citizen's bones
    F.item(W, 'CORPSEPIECE', {corpse_flags = {bone = true}, stack_size = 2})
    W.subdefs[10] = {id = 'ITEM_ARMOR_CLOAK', armorlevel = 0}
    W.subdefs[11] = {id = 'ITEM_ARMOR_LEATHER', armorlevel = 1}
    F.item(W, 'ARMOR', {subtype = 10, mat_type = 37, mat_index = 5})     -- a dropped leather cloak: clothing
    F.item(W, 'ARMOR', {subtype = 11, mat_type = 37, mat_index = 5})     -- leather armor: a soldier's body slot
    F.item(W, 'HELM', {mat_type = 0, mat_index = 51})                    -- no def known: counted
  end}
  days(W, 2)
  local i = W.K.census.i
  T.eq({i.bone, i.g_body, i.g_head}, {2, 1, 1})
  local keys = {}
  for _, e in ipairs(W.find_events('STOCK_LOW')) do keys[e.d.key] = e.d.n end
  T.eq(keys.bone, nil, '2 free + 10 held by care: the mood stock of bone is not low')
  T.eq(keys.leather, 0, 'leather is')
  T.eq(eco_warns(W), {})
end)

T.test('cloth: target = max(mood stock, naked x 3); weave per thread kind, thread from plants, fiber crops in autofarm', function()
  local W, ctl = world{care = true, phase = 'P1', naked = 4, shops = {'Loom', 'Farmers'}, setup = function(W)
    for _ = 1, 5 do F.item(W, 'THREAD', {mat_type = 419, mat_index = 71}) end
    for _ = 1, 2 do F.item(W, 'THREAD', {mat_type = 419, mat_index = 72}) end
    F.item(W, 'THREAD', {mat_type = 419, mat_index = 72, flags = {spider_web = true}})   -- an uncollected web
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 70, stack_size = 4})
  end}
  days(W, 2)
  local plant, silk, th = order(W, 'dfllm:cloth'), order(W, 'dfllm:cloth_silk'), order(W, 'dfllm:thread')
  T.ok(plant and silk and th, 'weave plant + silk, and thread')
  T.eq({plant.job, plant.material_category, plant.amount_total}, {'WeaveCloth', {'plant'}, 5})
  T.eq(plant.item_conditions, {{condition = 'AtLeast', value = 1, item_type = 'THREAD', flags = {'collected', 'plant'}}})
  T.eq(silk.amount_total, 2)
  T.eq({th.job, th.amount_total}, {'ProcessPlants', 5}, '12 wanted (4 naked x 3) - 7 thread at hand')
  T.ok(F.has(F.runs(W), 'autofarm threshold 100 GRASS_TAIL_PIG'), 'pig tail seeds: autofarm grows thread')
  T.eq(F.bad_runs(W), {})
  -- dressed: cloth enough -> fiber threshold back to autofarm's default (status names none: fiber_off), once
  ctl.naked = 0
  for _ = 1, 12 do F.item(W, 'CLOTH', {}) end
  days(W, 2)
  local n, st = 0, 0
  for _, line in ipairs(F.runs(W)) do
    if line:find('autofarm threshold', 1, true) then n = n + 1 end
    if line == 'autofarm status' then st = st + 1 end
  end
  T.ok(F.has(F.runs(W), 'autofarm threshold 50 GRASS_TAIL_PIG'))
  T.eq({n, st}, {2, 1}, 'one change each way; the default read once a boot')
  T.eq(eco_warns(W), {})
  -- autofarm's own default from its status: never "raised" below it, restored to it
  local W2, ctl2 = world{care = true, phase = 'P1', naked = 4, shops = {'Loom', 'Farmers'}, setup = function(W)
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 70, stack_size = 4})
    W.act_result('run', function(cmd, a1)
      if cmd == 'autofarm' and a1 == 'status' then return true, 'Running.\nDefault: 120\nGRASS_TAIL_PIG: 120' end
      return true, ''
    end)
  end}
  days(W2, 2)
  T.ok(F.has(F.runs(W2), 'autofarm threshold 120 GRASS_TAIL_PIG'), 'fiber_on is at least the default')
  ctl2.naked = 0
  for _ = 1, 12 do F.item(W2, 'CLOTH', {}) end
  days(W2, 2)
  local last
  for _, line in ipairs(F.runs(W2)) do if line:find('autofarm threshold', 1, true) then last = line end end
  T.eq(last, 'autofarm threshold 120 GRASS_TAIL_PIG', 'unchanged: nothing to restore')
end)

T.test('metal: charcoal for the ore, then SmeltOre; bronze from tin + copper ore; exploration without ore', function()
  local W = world{phase = 'P3', per = {A = 2}, wood = 60, shops = {'MetalsmithsForge'}, furnaces = {'Smelter', 'WoodFurnace'},
                  setup = function(W) for _ = 1, 3 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 60}) end end}
  days(W, 1)
  T.eq(W.K.census.i.ore, 3)
  T.eq(#orders(W, 'dfllm:smelt'), 0, 'no fuel yet: no smelting')
  local ch = order(W, 'dfllm:charcoal')
  T.ok(ch, 'charcoal for the ore and the forge jobs')
  T.eq(ch.job, 'MakeCharcoal')
  T.eq(ch.material_category, nil, 'MakeCharcoal takes no material category')
  T.eq(ch.item_conditions, {{condition = 'AtLeast', value = 21, item_type = 'WOOD'}})
  for _ = 1, 5 do F.item(W, 'BAR', {mat_type = 7}) end          -- the charcoal arrived
  days(W, 1)
  local sm = order(W, 'dfllm:smelt_MALACHITE')
  T.ok(sm, 'malachite smelted')
  T.eq({sm.job, sm.material, sm.amount_total}, {'SmeltOre', 'INORGANIC:MALACHITE', 3})
  T.eq(sm.item_conditions[2], {condition = 'AtLeast', value = 1, item_type = 'BAR', material = 'COAL'}, 'fuel condition')
  -- tin and copper ore: BRONZE_MAKING first (8 bars from two ores)
  local W2 = world{phase = 'P3', per = {A = 2}, shops = {'MetalsmithsForge'}, furnaces = {'Smelter'}, setup = function(W)
    F.item(W, 'BOULDER', {mat_type = 0, mat_index = 60}); F.item(W, 'BOULDER', {mat_type = 0, mat_index = 61})
    for _ = 1, 4 do F.item(W, 'BAR', {mat_type = 7}) end
  end}
  days(W2, 1)
  local bz = order(W2, 'dfllm:bronze')
  T.ok(bz, 'bronze')
  T.eq({bz.reaction, bz.amount_total}, {'BRONZE_MAKING', 1})
  T.eq(#orders(W2, 'dfllm:smelt'), 0, 'the two ores went into the alloy')
  -- no ore, no bars: one exploration request a season, the LLM once a year
  local W3 = world{phase = 'P3', per = {A = 2}, shops = {'MetalsmithsForge'}, furnaces = {'Smelter'}}
  days(W3, 3)
  local req = {}
  for _, e in ipairs(W3.find_events('PROJECT_REQUEST')) do if e.d.tpl == 'explore' then req[#req + 1] = e end end
  T.eq(#req, 1)
  T.eq({req[1].d.tpl, req[1].d.why}, {'explore', 'ore'})
  local dec = {}
  for _, e in ipairs(W3.find_events('DECISION_NEEDED')) do if e.d.id == 'metal' then dec[#dec + 1] = e end end
  T.eq(#dec, 1)
  T.eq(order(W3, 'dfllm:charcoal'), nil, 'no ore and no bars: no charcoal (logs stay)')
  T.eq(eco_warns(W), {})
end)

T.test('gear: every wanted position; metal by preference, then leather, then wood; worn inputs reported', function()
  local W = world{phase = 'P5', per = {A = 2, C = 1}, wood = 100, eco = {orders_per_day = 20},
                  shops = {'MetalsmithsForge', 'Leatherworks', 'Carpenters', 'Bowyers', 'Craftsdwarfs'},
                  setup = function(W)
    for _ = 1, 4 do F.item(W, 'BAR', {mat_type = 0, mat_index = 51}) end    -- iron
    for _ = 1, 10 do F.item(W, 'BAR', {mat_type = 0, mat_index = 50}) end   -- copper
    for _ = 1, 10 do F.item(W, 'BAR', {mat_type = 7}) end                   -- fuel
    for _ = 1, 3 do F.item(W, 'SKIN_TANNED', {mat_type = 37, mat_index = 5}) end
    F.item(W, 'ARMOR', {mat_type = 419, mat_index = 71})                  -- a cloth shirt: no armor
    F.item(W, 'HELM', {mat_type = 0, mat_index = 51, flags = {owned = true}})   -- someone's own: not free
  end}
  days(W, 1)
  local function g(cat) return order(W, 'dfllm:gear_' .. cat) end
  T.eq({g('body').material, g('body').item_subtype, g('body').amount_total}, {'INORGANIC:IRON', 'ITEM_ARMOR_BREASTPLATE', 1},
       'iron first: 4 bars make one breastplate')
  T.eq(g('body').item_conditions, {{condition = 'AtLeast', value = 3, item_type = 'BAR', material = 'INORGANIC:IRON'},
                                   {condition = 'AtLeast', value = 1, item_type = 'BAR', material = 'COAL'}})
  T.eq({g('head').material, g('head').amount_total}, {'INORGANIC:IRON', 1}, 'the last iron bar: one helm')
  T.eq({g('pants').material, g('pants').item_subtype, g('pants').amount_total}, {'INORGANIC:COPPER', 'ITEM_PANTS_GREAVES', 3})
  T.eq({g('gloves').material, g('gloves').amount_total}, {'INORGANIC:COPPER', 3}, '6 gauntlets, 2 per job')
  T.eq({g('shoes').material, g('shoes').amount_total}, {'INORGANIC:COPPER', 1}, 'one copper bar left')
  T.eq({g('shield').material_category, g('shield').amount_total}, {{'wood'}, 2}, 'bars gone: wooden shields')
  T.eq(g('weapon'), nil, 'weapons need metal')
  T.eq({g('xbow').item_subtype, g('xbow').amount_total}, {'ITEM_WEAPON_CROSSBOW', 2}, 'squad C and the hunter (leather short)')
  T.eq({g('quiver').job, g('quiver').material_category, g('quiver').amount_total}, {'MakeQuiver', {'leather'}, 1})
  T.eq(g('bolts').amount_total, 5, '100 bolts for the crossbow position + 25 for the hunter, 25 per job')
  local p = persist(W)
  T.eq(p.gear.soldiers, 3)
  T.eq(p.gear.cats.body.route, 'metal:IRON')
  T.eq(p.gear.cats.weapon.route, 'no bars')
  T.eq(p.gear.worn, 15)
  local low = {}
  for _, e in ipairs(W.find_events('STOCK_LOW')) do if e.d.key == 'gear' then low[#low + 1] = e end end
  T.eq(#low, 1)
  T.eq({low[1].d.key, low[1].d.n, low[1].d.min}, {'gear', 0, 27}, '21 armor pieces + 2 shields + 2 weapons + crossbow + quiver')
  -- the ordered pieces are not ordered again
  local n = #orders(W, 'dfllm:gear_')
  days(W, 1)
  T.eq(#orders(W, 'dfllm:gear_'), n, 'open orders cover the slots')
  -- no bars at all: leather armor
  local W2 = world{phase = 'P5', per = {A = 1}, eco = {orders_per_day = 20}, shops = {'Leatherworks', 'MetalsmithsForge'},
                   setup = function(W) for _ = 1, 10 do F.item(W, 'SKIN_TANNED', {mat_type = 37, mat_index = 5}) end end}
  days(W2, 1)
  local body = order(W2, 'dfllm:gear_body')
  T.eq({body.item_subtype, body.material_category, body.amount_total}, {'ITEM_ARMOR_LEATHER', {'leather'}, 1})
  -- the standing leather reserve (2, Run 10: a fey mood died for two leather) stays in the fort
  T.eq(body.item_conditions, {{condition = 'AtLeast', value = 3, item_type = 'SKIN_TANNED'}})
  T.eq(eco_warns(W), {})
end)

T.test('wood: autochop target follows the wood ordered, never below baseline; the floor stays', function()
  local W = world{phase = 'P3', wood = 40, setup = function(W)
    local jt, one = df.job_type, df.workquota_frequency_type.OneTime
    F.order(W, {job_type = jt.ConstructBed, frequency = one, mat_type = -1, mat_index = -1, amount_left = 80,
                amount_total = 80, material_category = {wood = true}, status = {}})
  end}
  days(W, 1)
  T.ok(F.has(F.runs(W), 'autochop target 210 120'), '80 logs ordered + 20 floor + 20 margin')
  T.eq(F.bad_runs(W), {})
  local n = #F.runs(W)
  days(W, 1)
  local again = 0
  for _, line in ipairs(F.runs(W)) do if line:find('autochop', 1, true) then again = again + 1 end end
  T.eq(again, 1, 'unchanged: not sent again')
  T.ok(#F.runs(W) > n)
  local W2 = world{phase = 'P3', wood = 40}
  days(W2, 1)
  for _, line in ipairs(F.runs(W2)) do T.ok(not line:find('autochop', 1, true), 'baseline 150/60 suffices: ' .. line) end
end)

T.test('wood orders: ore boulders are no furniture stone (economic stone stays the smelter\'s)', function()
  local function run(ores)
    local W = world{phase = 'P3', wood = 82, setup = function(W)
      for _ = 1, 25 - ores do F.item(W, 'BOULDER', {}) end
      for _ = 1, ores do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 60}) end
      F.order(W, {job_type = df.job_type.ConstructDoor, frequency = df.workquota_frequency_type.OneTime, mat_type = 0,
                  mat_index = -1, amount_left = 7, amount_total = 7, material_category = {}, status = {}})
      W.act_result('order_material', function() return true, 'wood' end)
    end}
    days(W, 1)
    return #W.find_acts('order_material'), W.K.census.i
  end
  local n, i = run(0)
  T.eq({n, i.rock}, {0, 25}, '25 plain boulders: the doors stay rock')
  n, i = run(20)
  T.eq({n, i.rock, i.ore}, {1, 25, 20}, '5 masonry boulders + 20 malachite: the doors turn wood')
end)

T.test('ore pile: a stockpile named dfllm-ore takes metalore settings once a smelter stands, once per boot', function()
  local pile
  local W = world{phase = 'P3', setup = function(W) pile = F.building(W, 'STOCKPILE', {name = 'dfllm-ore'}) end}
  days(W, 1)
  for _, line in ipairs(F.runs(W)) do T.ok(not line:find('stockpiles', 1, true), 'no smelter yet: ' .. line) end
  F.workshop(W, 'Smelter', true)
  days(W, 2)
  local n = 0
  for _, line in ipairs(F.runs(W)) do if line == 'stockpiles import metalore -s ' .. pile.id then n = n + 1 end end
  T.eq(n, 1)
  T.eq(F.bad_runs(W), {})
end)

T.test('daily run: at most one DF command per frame, a full day still fits in a day', function()
  local W = world{phase = 'P5', per = {A = 2, C = 1}, wood = 100, drinks = 10, food = 0, barrels = 0, eco = {orders_per_day = 20},
                  shops = {'MetalsmithsForge', 'Leatherworks', 'Carpenters', 'Bowyers', 'Craftsdwarfs'}}
  local CMD = {run = true, workorder = true, orders_import = true, orders = true}
  local seen, worst = 0, 0
  local function count() local n = 0; for _, a in ipairs(W.acts) do if CMD[a.fn] then n = n + 1 end end; return n end
  for _ = 1, 300 do
    W.run(1)
    local n = count()
    worst = math.max(worst, n - seen)
    seen = n
  end
  T.eq(worst, 1)
  T.ok(seen >= 8, 'engine, status, imports, orders: ' .. seen)
  T.ok(W.state().labor ~= nil, 'the day finished and published')
end)

-- Run 10 (Handlelock): iron stuck at 8 bars for years while 20 soldiers wore 38-53 %; the explore route waited for 0
-- spare bars and never fired. Now: no ore and fewer bars than the metal slots want -> PROJECT_REQUEST explore, and the
-- state tells plan propose/check (stock.ore, bars, metal)
T.test('Run 10: no ore and 8 iron bars for 20 soldiers: exploration request and state stock.metal explore', function()
  local W = world{phase = 'P3', per = {A = 10, B = 10}, shops = {'MetalsmithsForge'}, furnaces = {'Smelter'},
                  setup = function(W) for _ = 1, 8 do F.item(W, 'BAR', {mat_type = 0, mat_index = 51}) end end}
  days(W, 2)
  local req = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.tpl == 'explore' then req[#req + 1] = e end end
  T.eq(#req, 1, 'one exploration request a season')
  T.eq({req[1].d.why, req[1].d.bars}, {'ore', 8})
  T.ok(req[1].d.short >= 50, 'the soldiers want 60+ bars: ' .. tostring(req[1].d.short))
  T.ok(req[1].msg:find('no ore, 8 bars', 1, true), req[1].msg)
  local dec
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'metal' then dec = e end end
  T.ok(dec and dec.d.q:find('tpl explore', 1, true), dec and dec.d.q)
  local s = W.state()
  T.eq({s.stock.ore, s.stock.bars, s.stock.metal}, {0, 8, 'explore'})
  T.eq(W.K.call('economy', 'route', 'bars') and select(2, W.K.call('economy', 'route', 'bars')),
       'no ore: explore dig (plan), trade.want bar:iron')
  -- ore came in: no exploration route any more
  for _ = 1, 2 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 62}) end      -- hematite
  days(W, 1)
  T.eq(W.state().stock.metal ~= 'explore', true)
  T.eq(W.state().stock.ore, 2)
end)

-- Run 10: a fey mood died for two leather (no tannery, no hunt); the miss outlives the mood
T.test('Run 10: a mood missed leather: hunters through the no-game pause, a tannery request, state mood_miss', function()
  local W, ctl = world{care = true, phase = 'P1', wood = 100, shops = {'Craftsdwarfs'}, wants = {{cls = 'leather', n = 2}},
                       setup = function(W, ctl)
    local function wd(name, labor) return {name = name, assigned_units = kmock.vec{}, allowed_labors = {[labor] = true}, flags = {mode = 3}} end
    ctl.wds = {Miners = wd('Miners', 1), Woodcutters = wd('Woodcutters', 2), Hunters = wd('Hunters', 3)}
    df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wds.Miners, ctl.wds.Woodcutters, ctl.wds.Hunters}}
    W.act_result('run', function(cmd, a1) if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: monitor' end return true, '' end)
    W.act_result('work_detail', function(name, id, on)
      local v = ctl.wds[name].assigned_units
      for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
      if on then v:insert('#', id) end
      return true
    end)
    F.item(W, 'WEAPON', {subtype = 3})
    F.item(W, 'AMMO', {subtype = 4, stack_size = 25})
  end}
  for i = 1, 10 do W.unit(i).status.labors = {}; W.unit(i).mood = -1 end
  days(W, 1)
  local function tan_reqs()
    local r = {}
    for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do
      if e.d.tpl == 'workshops' and e.d.why == 'tannery' then r[#r + 1] = e end
    end
    return r
  end
  T.eq(#tan_reqs(), 1, 'no tanner\'s shop while a mood needs leather: the workshops project is asked for')
  T.ok(tan_reqs()[1].msg:find('a mood missed leather', 1, true), tan_reqs()[1].msg)
  T.eq(#ctl.wds.Hunters.assigned_units, 1, 'an open need hunts (one crossbow)')
  ctl.wants = nil                                    -- the mood ended (the fey dwarf died)
  days(W, 16)
  T.eq(#ctl.wds.Hunters.assigned_units, 1, 'leather still 0 after the mood missed it: hunting goes on through the pause')
  local s = W.state()
  T.eq({s.stock.leather, s.stock.mood_miss}, {0, {'leather'}})
  T.eq(#tan_reqs(), 2, 'asked again after request_days (14)')
  local _, route = W.K.call('economy', 'route', 'leather')
  T.eq(route, 'no tannery (asked), hunt: 1 hunter, butcher, trade.want leather')
  T.eq(eco_warns(W), {})
end)

-- Run 11 (Kilrudrabed y431-y441: no metal ore on the site, bars 0 for ten years, the caravans were never asked for iron;
-- 10 soldiers at worn 58 % lost siege 8): metal short for the soldiers -> economy.trade_wants asks every caravan for
-- picks, axes, bars and metal gear (metal = 1), the fort makes crafts to pay with, state stock.mshort
T.test('Run 11: metal short (no ore, no bars, worn 15 %): trade_wants asks for picks, axes, bars, metal gear; crafts', function()
  -- old code: trade_wants {} (no Miners detail short), no crafts order, no stock.mshort
  local W = world{phase = 'P3', per = {A = 5}, wood = 100, shops = {'MetalsmithsForge', 'Craftsdwarfs'}, furnaces = {'Smelter'}}
  days(W, 2)
  local tw = select(2, W.K.call('economy', 'trade_wants'))
  local buy, n = {}, {}
  for _, e in ipairs(tw) do buy[#buy + 1] = e.buy; n[e.buy] = e.n; T.eq(e.metal, 1, e.buy) end
  T.eq(buy, {'pick', 'axe', 'bar:iron', 'bar:steel', 'armor:metal', 'weapon:metal', 'helm:metal', 'shield', 'pants:metal',
             'gloves:metal', 'shoes:metal', 'bar:bronze', 'bar:bismuth_bronze', 'bar:copper'})
  T.eq({n.pick, n.axe, n['armor:metal'], n['weapon:metal'], n.shield, n['gloves:metal']}, {3, 3, 5, 5, 5, 10},
       'tools up to 3 each (military\'s tools-first rule), the slots\' missing pieces')
  T.eq(n['bar:iron'], 55, 'the bars the metal slots want: 15 + 5 + 10 + 5 + 5 + 10 + 5')
  T.ok(tw[3].why:find('metal short: worn 15%, 0 bars, no ore, 55 bars wanted', 1, true), tw[3].why)
  local s = W.state().stock
  T.eq({s.mshort, s.melt}, {1, 0})
  T.eq(select(2, W.K.call('economy', 'metal')), {short = true, worn = 15, bars = 0, ore = 0, need = 55, melt = 0})
  local cr = order(W, 'dfllm:trade_crafts')
  T.ok(cr, 'crafts to trade for the metal')
  T.eq({cr.job, cr.material_category, cr.amount_total}, {'MakeCrafts', {'wood'}, 10}, 'no free stone: wood above wood_min')
  -- iron ore found: smelting is the route, the caravans are not asked any more
  F.item(W, 'BOULDER', {mat_type = 0, mat_index = 62})                           -- hematite
  days(W, 1)
  T.eq(select(2, W.K.call('economy', 'trade_wants')), {})
  T.eq(W.state().stock.mshort, 0)
  -- no soldiers wanted: not short
  local W2 = world{phase = 'P3', per = {}, wood = 100, shops = {'MetalsmithsForge'}}
  days(W2, 2)
  T.eq({select(2, W2.K.call('economy', 'trade_wants')), W2.state().stock.mshort}, {{}, 0})
  T.eq(eco_warns(W), {})
end)

T.test('Run 11: metal gear marked for melting with no ore and no bar: charcoal for the melt jobs (stock.melt)', function()
  -- old code: no ore and no bars -> no charcoal, so the smelter never melted the invaders' gear
  local W = world{phase = 'P3', per = {A = 2}, wood = 60, shops = {'MetalsmithsForge'}, furnaces = {'Smelter', 'WoodFurnace'},
                  setup = function(W)
    for _ = 1, 3 do F.item(W, 'ARMOR', {mat_type = 0, mat_index = 51, flags = {melt = true}}) end   -- iron, melt pile
    F.item(W, 'ARMOR', {mat_type = 37, mat_index = 5, flags = {melt = true}})                       -- leather: no metal
  end}
  days(W, 1)
  T.eq({W.K.census.i.melt, W.K.census.i.g_body}, {3, 0}, 'marked items are bars to come, no armor to wear')
  local ch = order(W, 'dfllm:charcoal')
  T.ok(ch, 'charcoal for the melt jobs')
  T.eq(ch.job, 'MakeCharcoal')
  T.eq(W.state().stock.melt, 3)
  -- without a smelter nothing melts: no charcoal for it
  local W2 = world{phase = 'P3', per = {A = 2}, wood = 60, shops = {'MetalsmithsForge'}, furnaces = {'WoodFurnace'},
                   setup = function(W) F.item(W, 'ARMOR', {mat_type = 0, mat_index = 51, flags = {melt = true}}) end}
  days(W2, 1)
  T.eq(order(W2, 'dfllm:charcoal'), nil)
end)

T.done()
