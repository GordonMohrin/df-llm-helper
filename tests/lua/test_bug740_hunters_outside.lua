-- BUG-740 (Run 16d i4 Pagedsculpture y386: the militia captain Rovod, a Bone Carver, hunted vermin outside the walls and died of
-- thirst at z110): (1) a squad member never stays on the hunters' detail (the player's entry too) and his Hunting labor is switched
-- off (economy.soldier_hunt_off, act.labor_set 'hunt', once a day); (2) a large wild predator at the water near a citizen (sense
-- census.w.hold) takes the hunters off the detail at once, a famine too, and they come back when the hold ends.
local T = require('testlib')
local X = require('wp6_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

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


T.test('BUG-740: a squad member on the hunters detail (the player put him there) is taken off it, the others stay', function()
  local W, ctl = hw{}
  local cap = 1
  ctl.wds.Hunters.assigned_units:insert('#', cap)         -- the player's entry, not the kernel's
  W.unit(cap).military.squad_id = 5                       -- the captain has a squad
  days(W, 2)
  local left = {}
  for i = 0, #ctl.wds.Hunters.assigned_units - 1 do left[ctl.wds.Hunters.assigned_units[i]] = true end
  T.eq(left[cap], nil, 'the squad member is off the hunters detail')
  T.ok(offs(W) >= 1, 'WORK_DETAIL off')
  T.eq(n_hunters(ctl), 2, 'the famine hunters are civilians')
end)

T.test('BUG-740: a squad member with the Hunting labor on loses it (labor_set hunt off), WORK_DETAIL why soldier, once a day', function()
  local W, ctl = hw{}
  local calls = {}
  W.act_result('labor_set', function(id, which, on)
    calls[#calls + 1] = {id, which, on}
    W.unit(id).status.labors.HUNT = false
    return true, 'disabled'
  end)
  W.unit(9).military.squad_id = 3
  W.unit(9).status.labors.HUNT = true
  W.unit(8).status.labors.HUNT = true                     -- a civilian keeps his labor
  W.set_census('u', F.census_u({1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, {soldier_ids = {9}, soldiers = 1}))
  days(W, 2)
  T.eq(calls, {{9, 'hunt', false}}, 'only the soldier, once')
  local n = 0
  for _, e in ipairs(W.find_events('WORK_DETAIL')) do
    if e.d.why == 'soldier' then n = n + 1; T.eq({e.d.unit, e.d.on}, {9, 0}) end
  end
  T.eq(n, 1)
  T.eq(W.unit(8).status.labors.HUNT, true)
end)

T.test('BUG-741 (Doorwings y385: a Gem Cutter on HuntVermin 70 tiles out, in no detail): a civilian with the Hunting labor on who is no ' ..
       'member of the Hunters detail loses it (why stray); a member keeps it; not in a famine', function()
  local function run(famine)
    local W, ctl = hw{}
    if not famine then F.item(W, 'FOOD', {stack_size = 3000, subtype = 1}) end
    local calls = {}
    W.act_result('labor_set', function(id, which, on)
      calls[#calls + 1] = {id, which, on}
      W.unit(id).status.labors.HUNT = false
      return true, 'disabled'
    end)
    ctl.wds.Hunters.assigned_units:insert('#', 9)           -- a member of the detail
    W.unit(9).status.labors.HUNT = true
    W.unit(8).status.labors.HUNT = true                     -- the stray
    days(W, 2)
    return W, calls
  end
  local W, calls = run(false)
  T.eq(calls, {{8, 'hunt', false}}, 'only the stray, once a day')
  local ev = {}
  for _, e in ipairs(W.find_events('WORK_DETAIL')) do if e.d.why == 'stray' then ev[#ev + 1] = e.d.unit end end
  T.eq(ev, {8})
  T.eq(W.unit(9).status.labors.HUNT, true)
  local _, calls2 = run(true)
  T.eq(calls2, {}, 'a famine wants hunters: no sweep')
end)

T.test('BUG-740: a predator at the water (census.w.hold) takes the hunters off at once, in a famine too; they return with the release', function()
  local W, ctl = hw{}
  days(W, 2)
  T.eq(n_hunters(ctl), 2, 'famine in PEACE: two hunters')
  W.set_census('w', {tick = 0, n = 1, list = {}, near = 10, hold = 1})
  days(W, 1)
  T.eq(n_hunters(ctl), 0, 'off at the next run')
  days(W, 3)
  T.eq(n_hunters(ctl), 0, 'and nobody is added while the beast is there')
  W.set_census('w', {tick = 0, n = 0, list = {}, near = -1, hold = 0})
  days(W, 2)
  T.eq(n_hunters(ctl), 2, 'back once sense releases the hold')
end)

T.done()
