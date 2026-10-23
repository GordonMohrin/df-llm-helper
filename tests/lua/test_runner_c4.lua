-- Package C4 (DECISIONS 7, 10, 11; BUG-072, BUG-074, BUG-075). Every test here fails on f17e2b3.
--  BUG-072  Run 11 y451: one `quickfort place` call with three food stockpiles took 68,603 ms (configure_stockpile imports
--           library/cat_food per pile, the food import copies all raw materials per element). A place chunk with several
--           food piles is applied as one call per pile, one per slice; a pile that stands is not placed again.
--  BUG-074  Run 11 y479: the temporary gather zone covered a 28 x 28 square around the fort, outside the walls too: 46 of
--           its GatherPlants jobs were unreachable. The zone follows the citizens' walk group; the log says how many
--           tiles were left out.
--  BUG-075  a fault inside the seal-first count was a kern.log error line only: KERN_FAULT (A) once per distinct message.
local T = require('testlib')
local H = require('runner_world')
local kmock = require('dfllm.util.k_mock')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end

---------------------------------------------------------------- BUG-072
local function world(tag, o)
  o = o or {}
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, strict = false}
  df.building_type = kmock.enum{'Chair', 'Bed', 'Table', 'Door', 'Construction', 'Trap', 'Workshop', 'Stockpile'}
  W.piles = {}                                     -- 'x,y,z' -> a building (a stockpile that stands)
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return W.piles[x .. ',' .. y .. ',' .. z] or (id and W.buildings[id]) or nil
  end
  W.load{name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
         state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end}
  W.load(runner)
  W.state()
  return W
end

-- a pile that stands: a stockpile building of that name on the corner tiles of its rectangle
local function stand(W, name, x1, y1, x2, y2, z)
  local b = {name = name, getType = function() return df.building_type.Stockpile end}
  W.piles[x1 .. ',' .. y1 .. ',' .. z] = b
  W.piles[x2 .. ',' .. y2 .. ',' .. z] = b
end

-- the stockroom of Run 11 (y451s3b0): a still and three food stockpiles in ONE place chunk
local function place_doc(cells, tpl)
  return {v = 2, tpl = tpl or 'stockroom', site = 'S1', class = 'infra', params = {}, anchor = {10, 10, 100}, rot = 0,
          stages = {{label = 'place', mode = 'place', orders = 0, defense = 0,
                     chunks = {{pos = {10, 10, 100}, cells = cells}}}},
          manifest = {v = 2}, materials = {}}
end
local THREE = {{0, 0, 0, 'f{name=dfllm-stock barrels=3}(5x1)'}, {0, 2, 0, 'f{name=dfllm-stock barrels=2}(2x2)'},
               {3, 2, 0, 'f{name=dfllm-stock barrels=2}(2x2)'}}
local function ncells(c)
  local n, texts = 0, {}
  H.cells(c, function(_, _, _, _, _, _, text) n = n + 1; texts[#texts + 1] = text end)
  return n, texts
end

T.test('BUG-072 (Run 11 y451: one place call with three food stockpiles took 68.6 s): a place chunk with three piles is ' ..
       'three quickfort calls, one per slice, in the document\'s order; the stage is done after the third', function()
  local W = world('c4pile3')
  T.ok(H.place(W, 'sr', place_doc(THREE)).ok)
  H.runs(W, 1)
  local calls = H.qf_calls(W, 'place')
  T.eq(#calls, 3, 'old: one call with the three piles')
  local frames, seen = {}, {}
  for i, c in ipairs(calls) do
    local n, texts = ncells(c)
    T.eq(n, 1, 'one pile a call')
    seen[i] = texts[1]
    frames[c.frame] = true
  end
  T.eq(seen, {THREE[1][4], THREE[2][4], THREE[3][4]}, 'the document\'s order')
  T.eq({calls[1].pos, calls[2].pos[2], calls[3].pos[1]}, {{10, 10, 100}, 10, 10}, 'positions are the chunk\'s')
  T.ok(calls[1].frame ~= calls[2].frame and calls[2].frame ~= calls[3].frame, 'one call per slice (frame)')
  T.eq(H.proj(W, 'sr').done, 1, 'the stage and the project are done')
  T.eq(#W.find_events('PROJECT_DONE'), 1)
  T.ok(logged(W, 'info', '^sr place chunk 0 call 1/3: quickfort place with 1 food pile took %d+ ms$'), 'the cost of each call is logged')
end)

T.test('BUG-072: cells between the piles stay together (one call), the order of the chunk holds; a chunk with one ' ..
       'food pile (fortcore s1.place) is one call as before', function()
  local W = world('c4mixed')
  local cells = {{0, 0, 0, 'u(2x2)'}, {3, 0, 0, 'f{name=a}(2x2)'}, {6, 0, 0, 'w(2x2)'}, {6, 3, 0, 's(2x2)'},
                 {0, 3, 0, 'f{name=b}(2x2)'}, {3, 6, 0, 'g{name=dfllm-trade autotrade=true}(3x1)'}}
  T.ok(H.place(W, 'mx', place_doc(cells)).ok)
  H.runs(W, 1)
  local got = {}
  for _, c in ipairs(H.qf_calls(W, 'place')) do local _, t = ncells(c); got[#got + 1] = table.concat(t, ' | ') end
  T.eq(got, {'u(2x2)', 'f{name=a}(2x2)', 'w(2x2) | s(2x2)', 'f{name=b}(2x2)', 'g{name=dfllm-trade autotrade=true}(3x1)'})
  local W2 = world('c4one')
  local one = {{0, 0, 0, 'f(5x3)'}, {7, 0, 0, 'w(5x3)'}, {0, 4, 0, 's(5x3)'}, {7, 4, 0, 'u(5x3)'}, {0, 8, 0, 'yr(5x5)'}}
  T.ok(H.place(W2, 'fc', place_doc(one, 'fortcore')).ok)
  H.runs(W2, 1)
  local c2 = H.qf_calls(W2, 'place')
  T.eq(#c2, 1, 'one food pile: the chunk goes whole')
  T.eq((ncells(c2[1])), 5)
end)

T.test('BUG-072: a pile that stands is not placed again (a stockpile of its name on its corner tiles); one of another ' ..
       'name does not stand for it', function()
  local W = world('c4stand')
  stand(W, 'dfllm-stock', 10, 12, 11, 13, 100)       -- the second pile (0,2) 2x2 stands already
  T.ok(H.place(W, 'sr', place_doc(THREE)).ok)
  H.runs(W, 1)
  local calls = H.qf_calls(W, 'place')
  local texts = {}
  for _, c in ipairs(calls) do local _, t = ncells(c); texts[#texts + 1] = t[1] end
  T.eq(texts, {THREE[1][4], THREE[3][4]}, 'old: all three in one call')
  T.ok(logged(W, 'info', '^sr place chunk 0: the food pile at 10,12,100 stands, not placed again$'))
  T.eq(H.proj(W, 'sr').done, 1)
  local W2 = world('c4other')
  stand(W2, 'somebody-elses', 10, 12, 11, 13, 100)
  T.ok(H.place(W2, 'sr', place_doc(THREE)).ok)
  H.runs(W2, 1)
  T.eq(#H.qf_calls(W2, 'place'), 3, 'a pile of another name does not count')
end)

T.test('BUG-072: a reload between two piles continues with the next one (R.pc persists); the piles placed are not ' ..
       'placed twice', function()
  local W = world('c4reload')
  T.ok(H.place(W, 'sr', place_doc(THREE)).ok)
  for _ = 1, 400 do                                  -- until the first call is made
    W.frame(20)
    if #H.qf_calls(W, 'place') >= 1 then break end
  end
  T.eq(#H.qf_calls(W, 'place'), 1)
  T.eq(W.K.persist.get('m.runner').p.sr.pc, {c = 0, n = 1}, 'the calls done are kept')
  W.K.flush()
  local persist = H.reloaded(W)
  local W2 = H.world{tag = 'c4reload2', persist = persist, strict = false}
  W2.load(runner)
  H.runs(W2, 2)
  local calls = H.qf_calls(W2, 'place')
  T.eq(#calls, 2, 'the two piles left')
  local _, t1 = ncells(calls[1])
  T.eq(t1[1], THREE[2][4])
  T.eq(H.proj(W2, 'sr').done, 1)
end)

---------------------------------------------------------------- BUG-074
-- the fort's surface z62 with a wall line at x = 108: west of it (group 7) the citizens live, east of it (group 9) a
-- meadow the wall cuts off. The depot at 100,100,60 centres the 28 x 28 square at x 86-113, y 86-113.
local function gworld(tag, o)
  o = o or {}
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, ytick = o.ytick or 0, census = {u = {ids = o.citizens ~= false and {1, 2} or {}, adults = 2}},
                    persist = {manifest = {v = 2, depot = {100, 100, 60}}, ['m.runner'] = o.rt}}
  W.load(runner)
  W.fd = o.fd or 20
  W.load{name = 'economy', every = {ticks = 1200}, state = function() return {stock = {food_d = W.fd}} end}
  for x = 80, 120 do
    for y = 80, 120 do
      W.map[x .. ',' .. y .. ',62'] = {c = '.', dig = '', g = x < 108 and 7 or (o.east or 9)}
    end
  end
  W.add_unit{id = 1, citizen = true, pos = {95, 100, 62}}
  W.add_unit{id = 2, citizen = true, pos = {90, 95, 62}}
  W.state()
  return W
end
local function zones(W)
  local r = {}
  for _, a in ipairs(W.find_acts('quickfort')) do
    local p = a.args[1]
    if p.mode == 'zone' then
      local cells = {}
      for dy, row in pairs(p.data[0]) do for dx, t in pairs(row) do cells[#cells + 1] = {dx, dy, t} end end
      table.sort(cells, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
      r[#r + 1] = {pos = p.pos, cells = cells}
    end
  end
  return r
end

T.test('BUG-074 (Run 11 y479: 46 GatherPlants jobs of the zone unreachable): the gather zone covers the tiles of the ' ..
       'citizens\' walk group only; the log says how many tiles were left out', function()
  local W = gworld('c4gather')
  H.runs(W, 1)
  local z = zones(W)
  T.eq(#z, 1)
  T.eq(z[1].pos, {86, 86, 62})
  T.eq(z[1].cells, {{0, 0, 'g{name=dfllm-gather}(22x28)'}}, 'x 86-107 only (old: the whole 28x28 square)')
  local l = logged(W, 'warn', '^food 20 days: gather zone at 86,86 on z 62: 616 tiles in 1 rects on the citizens\' walk group 7, ' ..
                              '168 tiles of the 28x28 square left out %(')
  T.ok(l, 'the log names the tiles left out')
  local g = W.K.persist.get('m.runner').gather
  T.eq({g.v, g.g, g.n, g.out}, {2, 7, 616, 168})
  H.runs(W, 12)
  T.eq(#zones(W), 1, 'drawn once')
end)

T.test('BUG-074: an irregular reach (a pond, a wall stub) is drawn as rectangles; the largest are kept under the rect ' ..
       'cap and the tiles dropped count as left out', function()
  local W = gworld('c4rects')
  for y = 90, 96 do for x = 95, 98 do W.map[x .. ',' .. y .. ',62'].g = 11 end end      -- a pond cut off from the group
  H.runs(W, 1)
  local z = zones(W)
  T.eq(#z, 1)
  local area, tiles = 0, {}
  for _, c in ipairs(z[1].cells) do
    local w, h = c[3]:match('%((%d+)x(%d+)%)')
    area = area + w * h
  end
  T.eq(area, 616 - 28, 'the 4x7 pond is not in the zone')
  T.eq(W.K.persist.get('m.runner').gather.out, 168 + 28)
  -- over the cap: only the largest rectangles stay
  local W2 = gworld('c4cap')
  runner.CFG.gather_rects = 2
  for y = 90, 96 do for x = 95, 98 do W2.map[x .. ',' .. y .. ',62'].g = 11 end end
  H.runs(W2, 1)
  T.eq(#zones(W2)[1].cells, 2)
  T.ok(W2.K.persist.get('m.runner').gather.out > 168 + 28, 'the tiles of the dropped rectangles are counted')
  runner.CFG.gather_rects = CFG0.gather_rects
end)

T.test('BUG-074: no citizen read (the walk group unknown): the whole square, as before, and the log says so; nothing ' ..
       'reachable: no zone at all', function()
  local W = gworld('c4unknown', {citizens = false})
  H.runs(W, 1)
  local z = zones(W)
  T.eq(z[1].cells, {{0, 0, 'g{name=dfllm-gather}(28x28)'}})
  T.ok(logged(W, 'warn', 'gather zone 28x28 at 86,86 on z 62 %(784 tiles; the citizens\' walk group is unknown'))
  -- the open tiles around the fort lie on a group the citizens cannot reach (they stand on two tiles of their own): no
  -- zone is drawn, the log says why (old: the whole square, 784 tiles of jobs nobody could do)
  local W2 = gworld('c4none')
  for _, t in pairs(W2.map) do t.g = 9 end
  W2.map['95,100,62'].g, W2.map['90,95,62'].g = 7, 7
  H.runs(W2, 1)
  T.eq(#zones(W2), 0)
  T.ok(logged(W2, 'warn', '^gather zone: no revealed open tile on the citizens\' walk group around 100,100,62$'), 'logged')
end)

T.test('BUG-074: a zone an older kernel drew over the whole square is removed once and drawn again on the citizens\' ' ..
       'walk group while food is short; a zone of this kernel stays', function()
  local old = {gather = {z = {62}, x = 86, y = 86, side = 28, t = 0}}      -- no v: the older kernel
  local W = gworld('c4old', {rt = old})
  H.runs(W, 1)
  local rm = W.find_acts('zone_remove')
  T.eq(#rm, 1, 'the old zone is removed')
  T.eq(rm[1].args[1], 'dfllm-gather')
  T.ok(logged(W, 'info', '^gather zone of an older kernel %(the whole square%) removed'), 'kern.log')
  local z = zones(W)
  T.eq(#z, 1)
  T.eq(z[1].cells, {{0, 0, 'g{name=dfllm-gather}(22x28)'}})
  H.runs(W, 12)
  T.eq(#W.find_acts('zone_remove'), 1, 'once')
  T.eq(#zones(W), 1)
end)

---------------------------------------------------------------- BUG-075
local SX, SY, Z = 114, 73, 143
local function seal_doc(W)
  H.floor(W, SX, SY, Z, SX, SY)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = SX .. ',' .. SY .. ',' .. Z .. ' floor'},
          anchor = {SX, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, 'd'}}}}}},
          manifest = {v = 2}, materials = {door = 1}}
end
local function fault_world(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}, strict = false}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  H.place(W, 'sl', seal_doc(W))
  -- a later stage the seal-first count reads and chokes on (as in test_runner_queue.lua)
  local d = W.K.persist.get('bp.sl')
  d.stages[2] = {label = 'seal.x', mode = 'dig', orders = 0, defense = 1, chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, 7}}}}}
  return W
end

T.test('BUG-075 (DECISIONS 11): a fault inside the seal-first count is a KERN_FAULT (A) from the runner, once per ' ..
       'distinct message (old: a kern.log error line only); the faults go on without a second event', function()
  local W = fault_world('c4fault')
  H.runs(W, 4)
  local ev = W.find_events('KERN_FAULT')
  T.eq(#ev, 1, 'old: no event')
  T.eq(ev[1].cls, 'A')
  T.eq({ev[1].d.module, ev[1].d.backoff_s, ev[1].d.n}, {'runner', 0, 1})
  T.ok(ev[1].d.err:find('^%S+'), ev[1].d.err)
  T.ok(ev[1].msg:find('^runner: seal first/rebuild failed, this run goes on without them: '), ev[1].msg)
  H.runs(W, 6)
  T.eq(#W.find_events('KERN_FAULT'), 1, 'the same message once')
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find('^seal first/rebuild failed') then n = n + 1 end end
  T.eq(n, 1, 'the log line stays once per message too')
end)

T.test('BUG-075: the end of a fault ends its episode; the same or another message after it waits the cadence ' ..
       '(7 game days and 10 minutes), then it is announced again', function()
  local W = fault_world('c4fault2')
  H.runs(W, 2)
  T.eq(#W.find_events('KERN_FAULT'), 1)
  local d = W.K.persist.get('bp.sl')
  local bad = d.stages[2]
  d.stages[2] = nil                                  -- the cause is gone: the count works again
  H.runs(W, 2)
  T.eq(#W.find_events('KERN_FAULT'), 1)
  d.stages[2] = bad                                  -- the same fault again, minutes later: the cadence holds
  H.runs(W, 2)
  T.eq(#W.find_events('KERN_FAULT'), 1, 'within the cadence')
  W.ms = W.ms + 11 * 60 * 1000                       -- ten minutes of wall clock, but under 7 game days
  H.runs(W, 2)
  T.eq(#W.find_events('KERN_FAULT'), 1, 'the game days count too')
  W.run(8 * 1200, {skip = 9})
  W.ms = W.ms + 11 * 60 * 1000
  H.runs(W, 2)
  local ev = W.find_events('KERN_FAULT')
  T.eq(#ev, 2, 'both clocks passed: announced again')
  T.eq(ev[2].d.n >= 1, true)
  T.ok(not ev[1].d.err:find('/', 1, true), 'no install path in the event: ' .. ev[1].d.err)
  -- another message in the same episode waits for the cadence as well
  d.stages[2] = {label = 'seal.x', mode = 'dig', orders = 0, defense = 1, chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, {}}}}}}
  H.runs(W, 2)
  T.eq(#W.find_events('KERN_FAULT'), 2, 'another message inside the cadence')
  W.run(8 * 1200, {skip = 9})
  W.ms = W.ms + 11 * 60 * 1000
  H.runs(W, 2)
  local ev3 = W.find_events('KERN_FAULT')
  T.eq(#ev3, 3)
  T.ok(ev3[3].d.err ~= ev3[2].d.err, 'a distinct message')
end)

T.done()
