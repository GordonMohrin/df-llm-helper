-- BUG-357 (Run 16b i2 y372 d28-60, Run 16c i3): farms and two workshops projects stood 32 days at build 50% "waits for door
-- (0 free, 3 ordered)" for a door that only a Carpenter's or Mason's workshop makes, while no such workshop stood for 130
-- days (ConstructDoor "no Carpenters workshop", ConstructBlocks "no Masons workshop"). measure_build waited for ever on the
-- pending door. The stage now goes on without a door while neither shop stands built (rooms, farms; a seal keeps its
-- doors), logs it, and a new fort asks for the mandatory shops like a reclaimed one. Every test fails on 595364a.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function fresh(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag}
  W.real_doors = true
  df.workshop_type = require('dfllm.util.k_mock').enum{'Carpenters', 'Masons', 'Still'}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  return W
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end
local function shop(W, name, stage)
  local b = W.add_building{type = df.workshop_type[name], getBuildStage = function() return stage end,
                           getMaxBuildStage = function() return 1 end}
  df.global.world.buildings.other.WORKSHOP_ANY:insert('#', b)
end
-- the beds and the wall get built, the door never (its item needs a shop)
local function build_all_but_doors(W)
  for _, b in pairs(W.buildings) do
    if b._t ~= df.building_type.Door then b._st = 1 end
  end
end
-- two beds, a wall and a door in one build stage
local function doc(tpl, class)
  local d = H.doc{tpl = tpl, class = class, params = {}, manifest = {v = 2}}
  d.stages[2].chunks[1].cells[#d.stages[2].chunks[1].cells + 1] = {1, 0, 0, 'd'}
  return d
end
local function run_project(W, d)
  H.floor(W, 10, 10, 100, 14, 11)
  H.place(W, 'dr', d)
  H.runs(W, 6)
  H.dig(W)
  for _ = 1, 8 do build_all_but_doors(W); H.runs(W, 1) end
end
local function proj(W) return H.proj(W, 'dr') end

T.test('BUG-357: a farms project does not wait for a door while no Carpenters or Masons workshop stands', function()
  local W = fresh('dd1')
  run_project(W, doc('farms', 'infra'))
  local door = W.buildings[W.bld_at['11,10,100']]
  T.eq(door._t, df.building_type.Door, 'a real door was placed')
  T.ok(door._st == 0, 'the door itself is not built')
  T.eq(proj(W).done, 1, 'the project went on past its door stage: ' .. T.show(proj(W)))
  T.ok(logged(W, '1 door(s) not awaited'), 'logged')
  T.ok(logged(W, 'BUG-357'), 'names the bug')
end)

T.test('BUG-357: with a built Carpenters workshop the door is awaited as before', function()
  local W = fresh('dd2')
  shop(W, 'Carpenters', 1)
  run_project(W, doc('farms', 'infra'))
  T.ok(proj(W).done ~= 1, 'still waiting for the door: ' .. T.show(proj(W)))
  T.ok(not logged(W, 'not awaited'), 'no deferral logged')
end)

T.test('BUG-357: a Carpenters workshop still under construction is no shop: the door is not awaited', function()
  local W = fresh('dd3')
  shop(W, 'Carpenters', 0)
  run_project(W, doc('farms', 'infra'))
  T.eq(proj(W).done, 1)
  T.ok(logged(W, 'not awaited'))
end)

T.test('BUG-357: a seal keeps its doors (a way in is not left open for want of a shop)', function()
  local W = fresh('dd4')
  run_project(W, doc('seal', 'defense'))
  T.ok(proj(W) == nil or proj(W).done ~= 1, 'the seal still waits: ' .. T.show(proj(W)))
  T.ok(not logged(W, 'not awaited'), 'no deferral logged')
end)

T.test('BUG-357: a new fort whose stage deferred a door asks for the mandatory shops (PROJECT_REQUEST workshops ' ..
       'why=mandatory) like a reclaimed one; one that deferred nothing asks for nothing', function()
  local W = fresh('dd5')
  df.workshop_type = {Carpenters = 1, Masons = 2, Craftsdwarfs = 3, Still = 6, Kitchen = 7,
                      [1] = 'Carpenters', [2] = 'Masons', [3] = 'Craftsdwarfs', [6] = 'Still', [7] = 'Kitchen'}
  df.furnace_type = {Smelter = 1, [1] = 'Smelter'}
  run_project(W, doc('farms', 'infra'))
  H.runs(W, 2 * 4)
  local ev = W.find_events('PROJECT_REQUEST')
  T.eq(#ev, 1, T.show(ev))
  T.eq({ev[1].d.tpl, ev[1].d.why}, {'workshops', 'mandatory'})
  local has = {}
  for _, t in ipairs(ev[1].d.types) do has[t] = true end
  T.ok(has.Carpenters and has.Masons and has.Still and has.Kitchen, T.show(ev[1].d.types))
  local W2 = fresh('dd6')
  df.workshop_type = {Carpenters = 1, [1] = 'Carpenters'}
  df.furnace_type = {Smelter = 1, [1] = 'Smelter'}
  shop(W2, 'Carpenters', 1)
  run_project(W2, doc('farms', 'infra'))
  H.runs(W2, 2 * 8)
  T.eq(#W2.find_events('PROJECT_REQUEST'), 0, 'a fort with a carpenter and no deferred door asks for nothing')
end)

T.done()
