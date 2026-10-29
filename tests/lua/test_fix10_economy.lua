-- Run 15c Inkintense famine (fix10-famine), economy: the hunters a drill took off come back as soon as it ends (BUG-295),
-- water under a ramp top has its bank one level up (BUG-296), a seal piece outside the burrow its builders keep to is
-- named (BUG-298), an empty food stock is no "cannot reach food" (BUG-299). Every test fails on 05dc764.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

---------------------------------------------------------------- BUG-295 hunters back after the drill
-- the world of tests/lua/test_economy_chains.lua's hunters test: 10 citizens, Miners/Woodcutters/Hunters, 2 crossbows
local function hw(opts)
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.subdefs[3] = {id = 'ITEM_WEAPON_CROSSBOW', skill_melee = df.job_skill.CROSSBOW, skill_ranged = df.job_skill.CROSSBOW}
  W.subdefs[4] = {id = 'ITEM_AMMO_BOLTS'}
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P1'} end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = opts.food or 2000, subtype = 1})
  for _ = 1, 100 do F.item(W, 'WOOD', {}) end
  for _, ws in ipairs({'Craftsdwarfs', 'Tanners'}) do F.workshop(W, ws) end
  local ctl = {}
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

T.test('BUG-295 (Inkintense #1408/#1409, #1492/#1493: the drill took both hunters off, back 30,000+ ticks later in a ' ..
       'famine): the members a DRILL took off return when the mode is PEACE again, WORK_DETAIL why "drill over"', function()
  local W, ctl = hw{food = 1}
  days(W, 2)
  T.eq(#ctl.wds.Hunters.assigned_units, 2, 'famine in PEACE: two hunters')
  W.K.set_mode('DRILL', 'test')
  W.run(150, {skip = 50}); settle(W)
  T.eq(#ctl.wds.Hunters.assigned_units, 0, 'off at once in the drill (nobody outside at T+1,200)')
  local p = W.K.persist.get('m.economy')
  T.eq(#p.drill_off.Hunters, 2)
  W.K.set_mode('PEACE', 'drill done')
  T.eq(#ctl.wds.Hunters.assigned_units, 2, 'old code: back only with a later full run')
  local back = 0
  for _, e in ipairs(W.find_events('WORK_DETAIL')) do if e.d.why == 'drill over' and e.d.on == 1 then back = back + 1 end end
  T.eq(back, 2)
  T.eq(W.K.persist.get('m.economy').drill_off, nil)
  -- an ALERT takes them off as before and keeps no drill list (they come back by the usual tools pass)
  W.K.set_mode('ALERT', 'test')
  W.run(150, {skip = 50}); settle(W)
  T.eq(#ctl.wds.Hunters.assigned_units, 0)
  T.eq(W.K.persist.get('m.economy').drill_off, nil)
  -- review: a drill that ends in RECOVERY (a siege came) keeps the list until the fort is in PEACE again
  W.K.set_mode('PEACE', 'test')
  days(W, 2)
  T.eq(#ctl.wds.Hunters.assigned_units, 2)
  W.K.set_mode('DRILL', 'test')
  W.run(150, {skip = 50}); settle(W)
  T.eq(#W.K.persist.get('m.economy').drill_off.Hunters, 2)
  W.K.set_mode('SIEGE', 'a siege during the drill')
  W.K.set_mode('RECOVERY', 'siege over')
  T.eq(#W.K.persist.get('m.economy').drill_off.Hunters, 2, 'no restore in RECOVERY')
  W.K.set_mode('PEACE', 'quiet')
  T.eq(W.K.persist.get('m.economy').drill_off, nil, 'restored in PEACE')
end)

---------------------------------------------------------------- BUG-296 a ramp top over the water
local function fake_k(tiles)
  return {call = function(mod, fn, x, y, z)
    if mod == 'snapshot' and fn == 'tile' then return true, tiles[x .. ',' .. y .. ',' .. z] or {c = '#'} end
    if mod == 'snapshot' and fn == 'far' then return true, false end
    return false
  end}
end

T.test('BUG-296 (Inkintense: 117 of 164 water tiles on z132 under a ramp top "v", "160 no bank on the walk group"): ' ..
       'the bank is the floor beside the ramp top, one level up', function()
  F.world{cfg = {baseline = F.cfg()}, units = {}}
  local E = fresh('economy')
  local K = fake_k({['10,10,132'] = {c = '~', flow = 7}, ['10,10,133'] = {c = 'v'}, ['11,10,133'] = {c = '.'},
                    ['20,10,132'] = {c = '~', flow = 7}, ['20,10,133'] = {c = 'v'}})
  local site = E.fish_bank(K, {10, 10, 132})
  T.ok(site, 'old code: nil (a ramp top is no bank)')
  T.eq(site.bank, {11, 10, 133})
  T.eq(site.up, true)
  T.eq((E.fish_bank(K, {20, 10, 132})), nil, 'a ramp top with no floor beside it is no bank')
  local K2 = fake_k({['10,10,132'] = {c = '~', flow = 7}, ['10,10,133'] = {c = '_'}, ['9,9,133'] = {c = '.'}})
  T.eq(E.fish_bank(K2, {10, 10, 132}).bank, {9, 9, 133}, 'open space above as before')
end)

---------------------------------------------------------------- BUG-298 outside the builders' burrow
T.test('BUG-298 (Inkintense seal door 92,99,133 untaken for years): economy.burrow_out names the burrow most free ' ..
       'citizens are assigned to when it lacks the tile, and a civil alert burrow that lacks it', function()
  local units = {}
  for i = 1, 6 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 6 do ids[i] = i end
  W.set_census('u', F.census_u(ids))
  local E = fresh('economy')
  local kern = {id = 7, name = 'Kern+', tiles = {['50,40,131'] = true}}
  local lev = {id = 8, name = 'dfllm-levers', tiles = {}}
  df.burrow = {find = function(id) return ({[7] = kern, [8] = lev})[id] end}
  dfhack.burrows = dfhack.burrows or {}
  dfhack.burrows.isAssignedTile = function(b, pos) return b.tiles[pos.x .. ',' .. pos.y .. ',' .. pos.z] == true end
  xyz2pos = xyz2pos or function(x, y, z) return {x = x, y = y, z = z} end
  df.global.plotinfo.alerts = {civ_alert_idx = 0, list = {}}
  for i = 1, 6 do W.unit(i).burrows = {} end
  T.eq(E.burrow_out(W.K, 92, 99, 133), nil, 'nobody assigned: no restriction')
  for i = 1, 4 do W.unit(i).burrows = {7} end
  local bo = E.burrow_out(W.K, 92, 99, 133)
  T.eq({bo.name, bo.why, bo.n, bo.of}, {'Kern+', 'assigned', 4, 6})
  T.eq(bo.text, 'outside the burrow Kern+ (4 of 6 free citizens assigned to it)')
  T.eq(E.burrow_out(W.K, 50, 40, 131), nil, 'inside Kern+')
  for i = 1, 3 do W.unit(i).burrows = {} end
  T.eq(E.burrow_out(W.K, 92, 99, 133), nil, '1 of 6 kept: the others build it')
  df.global.plotinfo.alerts = {civ_alert_idx = 1, list = {[1] = {burrows = {7}}}}
  T.eq(E.burrow_out(W.K, 92, 99, 133).text, 'outside the burrow Kern+ (civil alert on)')
end)

---------------------------------------------------------------- BUG-299 an empty stock is not "cannot reach"
local function sworld(opts)
  local units = {}
  for i = 1, 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local cfg = F.cfg()
  cfg.economy.starve.days = 10
  local W = F.world{cfg = {baseline = cfg}, units = units}
  local ids = {}
  for i = 1, 6 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = 0, hunger_timer = i <= 3 and 70000 or 0}
  end
  W.set_census('u', F.census_u(ids))
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 500})
  if opts.food then F.item(W, 'FOOD', {stack_size = opts.food, subtype = 1, _pos = {1, 1, 100}}) end
  df.global.plotinfo.labor_info = {work_details = kmock.vec{}}
  df.global.world.plants = {shrub_dry = kmock.vec{}, shrub_wet = kmock.vec{}}
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end,
          far = function() return false end, reach = function(K, a, b) return a.x ~= 13 end})
  W.load(fresh('economy'))
  return W
end
local function starvation(W)
  local dn
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'starvation' then dn = e end end
  return dn
end

T.test('BUG-299 (Inkintense: "28 cannot reach food" at food 0 d, all 50 citizens and 176 food items on one walk group): ' ..
       'with no edible food lying free nobody is cut off; the line says the stock is empty', function()
  local W = sworld{}
  days(W, 1)
  local dn = starvation(W)
  T.ok(dn, 'starvation report')
  T.eq(dn.msg, 'starvation: 3 hungry, food 0 days, no food left', 'old code: "3 cannot reach food"')
  T.ok(dn.d.q:find('no food left to eat (the stock is empty, not cut off)', 1, true), dn.d.q)
  local W2 = sworld{food = 1}
  days(W2, 1)
  local d2 = starvation(W2)
  T.ok(d2.msg:find('1 cannot reach food', 1, true), d2.msg)
  T.ok(d2.d.q:find('cannot reach food: Urist 3', 1, true), d2.d.q)
end)

T.done()
