-- Run 15c Inkintense round 3 (fix13-hunters, BUG-326): an automatic drill at food 35-42 d took the hunters and fishers off
-- (#1714, #1717-#1721), seven short ALERTs did it again (#1769-#1772) and a SIEGE of two lone goblins took the hunters
-- (#1583/#1584). Now no automatic drill below 60 food or drink days or while that stock falls (below 120 d), and the
-- hunters and fishers keep their detail in every mode except a real siege, after which they return at once.
-- Every test fails on 1d17c7e.
local T = require('testlib')
local X = require('wp6_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

---------------------------------------------------------------- the drill's supply hold
local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local function dworld(stock)
  local units = X.citizens(30, 1, {skills = SKILLS})
  local W = X.world{units = units}
  W.runner = X.runner('P5')
  W.econ = X.economy(stock)
  X.load(W, nil, {W.econ, X.snapshot(), W.runner})
  X.run(W, 1200)
  X.equip_all(W)
  X.run(W, 50)
  return W
end
local function stock(W, f, d)
  W.econ.stock.food_d, W.econ.stock.drink_d = f, d or W.econ.stock.drink_d
  W.state()
end

T.test('BUG-326 (Inkintense #1714: auto drill at food 35-42 d): no automatic drill below 60 food or drink days', function()
  local W = dworld({drink_d = 200, food_d = 42, meals = 1})
  X.run(W, 3600)
  T.eq(W.K.mode(), 'PEACE', 'old code: auto: first at food 42 d (BUG-294 held only below 30)')
  T.eq(X.call(W, 'drill', 'hold'), 'supply: food 42 d')
  stock(W, 200, 59)
  T.eq(X.call(W, 'drill', 'hold'), 'supply: drink 59 d')
end)

T.test('BUG-326 (Inkintense #1883: auto drill at food 31 d, falling to 24 d): no automatic drill while food or drink ' ..
       'falls below 120 days; above that, or steady, it runs', function()
  local W = dworld({drink_d = 200, food_d = 115, meals = 1})
  X.run(W, 1300)
  stock(W, 100)
  X.run(W, 1300)
  T.eq(X.call(W, 'drill', 'hold'), 'supply: food falls 100 d', 'old code: no trend, the drill was due')
  T.eq(W.K.mode(), 'PEACE')
  T.eq(#W.K.persist.get('m.drill').sh >= 2, true, 'the daily samples are persisted')
  local W2 = dworld({drink_d = 300, food_d = 200, meals = 1})
  X.run(W2, 1300)
  stock(W2, 150, 250)
  X.run(W2, 1300)
  local h2 = X.call(W2, 'drill', 'hold')
  T.ok(W2.K.mode() == 'DRILL' or h2 == 'just drilled', 'falling but above 120 days: the drill runs: ' .. tostring(h2))
end)

---------------------------------------------------------------- hunters keep their detail
-- the world of tests/lua/test_fix10_economy.lua (10 citizens, Miners/Woodcutters/Hunters, 2 crossbows, food 1: famine)
local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function hw(opts)
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.subdefs[3] = {id = 'ITEM_WEAPON_CROSSBOW', skill_melee = df.job_skill.CROSSBOW, skill_ranged = df.job_skill.CROSSBOW}
  W.subdefs[4] = {id = 'ITEM_AMMO_BOLTS'}
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P1'} end})
  local lone = {ids = nil}
  W.load({name = 'reflex', every = {ticks = 100000}, lone_ids = function() return lone.ids end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 1, subtype = 1})
  for _ = 1, 100 do F.item(W, 'WOOD', {}) end
  for _, ws in ipairs({'Craftsdwarfs', 'Tanners'}) do F.workshop(W, ws) end
  local ctl = {lone = lone}
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
  ctl.E = fresh('economy')
  W.load(ctl.E)
  for i = 1, 10 do W.unit(i).status.labors = {}; W.unit(i).mood = -1 end
  return W, ctl
end
local function n_hunters(ctl) return #ctl.wds.Hunters.assigned_units end
local function offs(W)
  local n = 0
  for _, e in ipairs(W.find_events('WORK_DETAIL')) do if e.d.detail == 'Hunters' and e.d.on == 0 then n = n + 1 end end
  return n
end

T.test('BUG-326 (Inkintense #1717/#1718 DRILL, #1769 ALERT: hunters taken off in a famine): a DRILL and an ALERT ' ..
       'keep the hunters on their detail', function()
  local W, ctl = hw{}
  days(W, 2)
  T.eq(n_hunters(ctl), 2, 'famine in PEACE: two hunters')
  for _, m in ipairs({'DRILL', 'ALERT'}) do
    W.K.set_mode(m, 'test')
    W.run(150, {skip = 50}); settle(W)
    days(W, 4)
    T.eq(n_hunters(ctl), 2, 'old code: off at once in ' .. m)
    W.K.set_mode('PEACE', 'test')
    settle(W)
  end
  T.eq(offs(W), 0, 'no WORK_DETAIL off')
  T.eq(W.K.persist.get('m.economy').drill_off, nil)
end)

T.test('BUG-326 (Inkintense #1583/#1584: SIEGE of two lone goblins): a real siege takes the hunters off at once and they ' ..
       'are back as soon as it ends (RECOVERY); a siege of the lone harmless picture keeps them', function()
  local W, ctl = hw{}
  days(W, 2)
  T.eq(n_hunters(ctl), 2)
  ctl.lone.ids = {77}
  W.K.set_mode('SIEGE', 'two lone goblins')
  W.run(150, {skip = 50}); settle(W)
  days(W, 2)
  T.eq(n_hunters(ctl), 2, 'old code: off at once (mode SIEGE)')
  ctl.lone.ids = nil
  W.run(1200, {skip = 100}); settle(W)
  T.eq(n_hunters(ctl), 0, 'a real siege: off at the next run')
  T.eq(#W.K.persist.get('m.economy').drill_off.Hunters, 2)
  W.K.set_mode('RECOVERY', 'quiet')
  T.eq(n_hunters(ctl), 2, 'old code: back only in PEACE (and only after a drill)')
  T.eq(W.K.persist.get('m.economy').drill_off, nil)
  days(W, 4)
  T.eq(n_hunters(ctl), 2, 'RECOVERY keeps them (hold)')
  W.K.set_mode('PEACE', 'recovered')
  -- the siege turns out to be the lone harmless picture: they go back while the mode is still SIEGE
  W.K.set_mode('SIEGE', 'again')
  W.run(150, {skip = 50}); settle(W)
  T.eq(n_hunters(ctl), 0)
  ctl.lone.ids = {78}
  W.run(1200, {skip = 100}); settle(W)
  T.eq(n_hunters(ctl), 2, 'lone harmless: no real siege, back at the next run')
end)

T.done()
