-- BUG-769 (Run 16d i4 Pagedsculpture y407: one citizen on walk group 1778 at 119,109,143, a one-level drop over the fort's group,
-- thirst 39,960 -> 51,860, STRANDED 'no rescue (no raised bridge leads to drink and food)'; nothing dug a way back): in quiet PEACE the
-- kernel designates ONE ramp (act.rescue_ramp) on a plain wall tile that joins the stranded group to the group with drink and food, never
-- near water, an aquifer or an open shaft, never under open sky, once per episode; STRANDED says what it did or why it did not.
-- The real sense, threat, siege and seal on a k_mock world (seal_world: DF-like walk groups); the three drawbridges of test_stranded stay
-- down (no raised bridge leads anywhere: the old 'no rescue' branch).
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local Z = 5
local FP = {O1 = {30, 15, Z, 30, 15, Z}, B1 = {40, 15, Z, 40, 15, Z}, B2 = {45, 15, Z, 45, 15, Z}}
local LEVER = {O1 = {58, 9}, B1 = {59, 9}, B2 = {60, 9}}
local ROLE = {O1 = 'outer', B1 = 'inner', B2 = 'core'}

-- z5: rock everywhere, the core x46-60 y8-22 (beds, drink, food), a field outside x0-29. z6: a walkable top x61-63 y10-11 (a floor over
-- the rock east of the core: one level above the core's floor, joined to it by nothing); z4 rock under all of it.
-- opts.water: a water tile at that z5 spot; opts.extra: a function(W) run before the groups are read
local function fort(opts)
  opts = opts or {}
  local man = {v = 2, bridges = {}, burrows = {['Kern+'] = {role = 'kern'}}, aquifer_levels = opts.aquifer}
  for n, fp in pairs(FP) do
    man.bridges[n] = {role = ROLE[n], fp = fp, levers = {{LEVER[n][1], LEVER[n][2], Z}}}
  end
  local W = SW.new{persist = {manifest = man}}
  W.ms_per_frame = 100
  SW.fill(W, Z - 1, 0, 0, 63, 30, '#')
  SW.fill(W, Z, 0, 0, 63, 30, '#')
  SW.fill(W, Z, 0, 0, 29, 30, ',')
  SW.fill(W, Z, 31, 13, 39, 17, '.')
  SW.fill(W, Z, 41, 14, 44, 16, '.')
  SW.fill(W, Z, 46, 8, 60, 22, '.')
  SW.draw(W, Z, {'bb'}, 50, 10)
  SW.fill(W, Z + 1, 61, 10, 63, 11, '.')
  if opts.water then SW.draw(W, Z, {'~'}, opts.water[1], opts.water[2]) end
  W.bridge, W.lever = {}, {}
  for n, fp in pairs(FP) do
    SW.draw(W, Z, {'.'}, fp[1], fp[2])
    local b = SW.bridge(W, fp, false, n)
    local lv = SW.lever(W, LEVER[n][1], LEVER[n][2], Z, b)
    lv.bridge = b
    W.bridge[n], W.lever[n] = b, lv
  end
  SW.regroup(W)
  SW.item(W, 'DRINK', 55, 20, Z, 40)
  SW.item(W, 'FOOD', 56, 20, Z, 40)
  for i, p in ipairs({{50, 15}, {51, 16}, {52, 17}}) do
    W.add_unit{id = i, pos = {p[1], p[2], Z}, citizen = true, adult = true}
  end
  W.add_unit{id = 11, pos = {62, 10, Z + 1}, citizen = true, adult = true}
  W.unit(11).counters2 = {thirst_timer = 40000, hunger_timer = 0}
  W.burrow('Kern+', {46, 8, Z, 60, 22, Z})
  W.act_result('alert_burrows', function(names) W.alert_burrows = names; return true, #names end)
  W.ramps = {}
  W.act_result('rescue_ramp', function(pos)
    W.ramps[#W.ramps + 1] = {pos[1], pos[2], pos[3]}
    W.tiles[SW.key(pos[1], pos[2], pos[3])].des.dig = 1        -- designated: the Miners dig it later
    return true, 1
  end)
  dfhack.job = {getWorker = function(j) return j._worker end}
  local mods = {S.military(), SW.fake('economy', {state = function() return {stock = {drink_d = 100, food_d = 100}} end})}
  package.loaded['dfllm.seal'] = nil
  mods[#mods + 1] = require('dfllm.seal')
  S.load(W, mods)
  return W
end

local function run(W, ticks)
  local done = 0
  while done < ticks do W.frame(9); done = done + 9 end
end
local function evs(W, t) return W.find_events(t) end

local function stranded_refused(W)
  local n, e = 0, nil
  while n < 60 and not e do
    run(W, 100)
    n = n + 1
    for _, x in ipairs(evs(W, 'STRANDED')) do if x.d.phase == 'refused' then e = x end end
  end
  return e
end

T.test('PEACE: the stranded citizen on the one-level top gets a ramp, once; STRANDED says where and that nothing is carried', function()
  local W = fort{}
  run(W, 1200)
  local e = stranded_refused(W)
  T.ok(e ~= nil, 'a STRANDED refused')
  T.eq(W.ramps, {{61, 10, Z}}, 'one ramp on the wall tile under the top beside the core')
  T.eq({e.d.ramp_state, e.d.ramp_at}, {'dug', {61, 10, Z}})
  T.ok(e.msg:find('ramp designated at 61,10,5', 1, true), e.msg)
  T.ok(e.d.ramp:find('nothing is carried across the drop', 1, true), e.d.ramp)
  run(W, 6000)
  T.eq(#W.ramps, 1, 'once per episode, not every 100 ticks')
end)

T.test('water within three tiles of the wall tile: nothing is dug, the answer names the water', function()
  local W = fort{water = {62, 12}}
  run(W, 1200)
  local e = stranded_refused(W)
  T.ok(e ~= nil, 'a STRANDED refused')
  T.eq(#W.ramps, 0, 'no ramp beside water')
  T.eq(e.d.ramp_state, 'none')
  T.ok(e.msg:find('no safe ramp: water at', 1, true), e.msg)
end)

T.test('a level the manifest knows as aquifer: nothing is dug', function()
  local W = fort{aquifer = {Z + 1}}
  run(W, 1200)
  local e = stranded_refused(W)
  T.ok(e ~= nil, 'a STRANDED refused')
  T.eq(#W.ramps, 0)
  T.ok(e.msg:find('no safe ramp: the aquifer level z6', 1, true), e.msg)
end)

T.test('an open shaft within three tiles: nothing is dug', function()
  local W = fort{}
  SW.draw(W, Z, {'_'}, 63, 9)
  SW.draw(W, Z - 1, {'_'}, 63, 9)
  run(W, 1200)
  local e = stranded_refused(W)
  T.ok(e ~= nil, 'a STRANDED refused')
  T.eq(#W.ramps, 0)
  T.ok(e.msg:find('no safe ramp: an open shaft at', 1, true), e.msg)
end)

T.test('a wall tile with an unrevealed neighbour is never dug (what lies behind is not known)', function()
  local W = fort{}
  for _, p in ipairs({{61, 10}, {61, 9}, {61, 11}, {60, 9}}) do
    local t = W.tiles[SW.key(p[1], p[2], Z - 1)]
    if t then t.des.hidden = true end
  end
  run(W, 1200)
  local e = stranded_refused(W)
  T.ok(e ~= nil, 'a STRANDED refused')
  T.eq(#W.ramps, 0, 'no ramp')
  T.eq(e.d.ramp_state, 'none')
end)

T.test('not in quiet PEACE nothing is dug (a way in is a way out)', function()
  local W = fort{}
  run(W, 1200)
  local seal = require('dfllm.seal')
  local ok, r = W.K.call('seal', 'rescue_dig', {62, 10, Z + 1}, false)
  T.ok(ok and r, 'rescue_dig answers')
  T.eq(r.state, 'none')
  T.ok(r.txt:find('not in quiet PEACE', 1, true), r.txt)
  T.eq(#W.ramps, 0)
  local ok2, r2 = W.K.call('seal', 'rescue_dig', {50, 12, Z}, true)
  T.eq(r2, nil, 'a group with drink and food needs no ramp')
end)

T.test('the ramp is done: the groups join and STRANDED ends (no new refusal)', function()
  local W = fort{}
  run(W, 1200)
  T.ok(stranded_refused(W) ~= nil)
  SW.draw(W, Z, {'r'}, 61, 10)                       -- DF dug it: a ramp with its top above
  SW.draw(W, Z + 1, {'^'}, 61, 10)
  SW.regroup(W)
  local n = #evs(W, 'STRANDED')
  run(W, 4000)
  T.eq(#W.ramps, 1)
  for i = n + 1, #evs(W, 'STRANDED') do
    T.ok(evs(W, 'STRANDED')[i].d.phase ~= 'refused' or evs(W, 'STRANDED')[i].d.thirst > 40000, 'no refusal after the ramp: ' .. evs(W, 'STRANDED')[i].msg)
  end
end)

T.done()
