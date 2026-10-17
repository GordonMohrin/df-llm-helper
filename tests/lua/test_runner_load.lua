-- BUG-033 (Run 11, Kilrudrabed site98 y438, kernel e3a62ab): `dfllm doctor` in PEACE: runner 35 ms/s on average,
-- frames up to 447 ms. The daily shaft and cavern check (8cc2e8e) was the worst offender found offline:
--   * every boot it decoded each bp file of the fort (Run 11: years of placements), the non-explores twice, 8 a run;
--   * every look at a finished explore decoded its bp file again and rebuilt its tiles;
--   * up to 4 shafts a run in one slice, each candidate tile with a 25 x 25 x 3 water read (lake_r) as soon as one
--     wet tile touched it, also for a pocket of seepage, every day, for every shaft ever dug.
-- Now: only an explore's file is decoded, once a boot (S.xdoc); one shaft a slice; the water box grows (1, lake_r0,
-- lake_r) only while the flood reaches its edge; candidates inside a flood already read are skipped; a finished shaft
-- with water in reach but no cavern is looked at every fin_every (dry ones and live explores stay daily).
-- k_mock + runner_world with a counting snapshot (rect-based liquids).
local T = require('testlib')
local H = require('runner_world')
local json = require('dfllm.util.json')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function explore_doc(ax, ay, az, depth, arm, every)
  local tun = {}
  for k = every, depth, every do tun[-k] = true end
  tun[-depth] = true
  local chunks = {}
  for w = 0, -depth, -1 do
    local key = w == 0 and 'j' or (w == -depth and 'u' or 'i')
    local cells, x0 = {{0, 0, 0, key}}, ax
    if tun[w] and arm > 0 then
      x0 = ax - arm
      cells = {{0, 0, 0, string.format('d(%dx1)', arm)}, {arm, 0, 0, key}, {arm + 1, 0, 0, string.format('d(%dx1)', arm)},
               {arm, 1, 0, string.format('d(1x%d)', arm)}}
    end
    chunks[#chunks + 1] = {pos = {x0, ay + 1, az + w}, cells = cells}
  end
  return {v = 2, tpl = 'explore', site = 'S1', class = 'infra',
          params = {depth = depth, arm = arm, every = every, avoid = ''}, anchor = {ax, ay, az}, rot = 0,
          stages = {{label = 'dig', mode = 'dig', orders = 0, defense = 0, chunks = chunks}}, manifest = {v = 2},
          materials = {}}
end

-- another template's bp file, ~20 KB (what years of placements leave in <save>/bp)
local function other_doc()
  local cells = {}
  for i = 1, 40 do cells[i] = {i % 8, i // 8, 0, 'Cw'} end
  return {v = 2, tpl = 'bedrooms', site = 'S1', class = 'living', params = {n = 4}, anchor = {1, 1, 100}, rot = 0,
          stages = {{label = 'b', mode = 'build', orders = 0, defense = 0, chunks = {{pos = {1, 1, 100}, cells = cells}}}},
          manifest = {v = 2, rooms = {}}, materials = {}, notes = string.rep('x', 20000)}
end

local function shaft_xy(i) return 20 + (i % 6) * 36, 20 + (i // 6) * 50 end

-- n explores dug and done, their bottoms (z91) beside water: even ones a 20-tile run of seepage (no cavern, reaches
-- past lake_r0), odd ones a small pocket; files other bp files. Then a reload: the world the check runs on.
local function fort(tag, n, files)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  runner.CFG.active = 4
  local W = H.world{tag = tag}
  W.load(runner)
  for i = 1, n do
    local x, y = shaft_xy(i)
    H.place(W, 'x' .. i, explore_doc(x, y, 100, 9, 6, 3))
    if i % 4 == 0 then H.runs(W, 1) end
  end
  for _ = 1, 30 do H.runs(W, 1); H.dig(W) end
  H.runs(W, 3)
  for i = 1, n do
    local x, y = shaft_xy(i)
    if i % 2 == 0 then
      for dx = 1, 20 do local t = W.tile(x + dx, y + 2, 91); t.c, t.flow = 'w', 2 end
    else
      for dx = 1, 2 do for dy = 2, 3 do local t = W.tile(x - dx, y + dy, 91); t.c, t.flow = 'w', 2 end end
    end
  end
  local persist = H.reloaded(W)
  local W2 = H.world{tag = tag .. 'b', persist = persist}
  W2.map = W.map
  for i = 1, files do H.put(W2, 'zz' .. i, other_doc()) end
  for i = 1, n do local x, y = shaft_xy(i); H.put(W2, 'x' .. i, explore_doc(x, y, 100, 9, 6, 3)) end
  -- the counting snapshot: tile calls and the tiles liquids reads (rect-based, as snapshot.liquids)
  local c = {tile = 0, lq = 0, step_max = 0, step = 0}
  W2.count = c
  local tile0 = W2.snap.tile
  W2.snap.tile = function(...) c.tile, c.step = c.tile + 1, c.step + 1; return tile0(...) end
  W2.snap.liquids = function(K, x0, y0, x1, y1, z, min)
    local out = {}
    for y = y0, y1 do
      for x = x0, x1 do
        c.lq, c.step = c.lq + 1, c.step + 1
        local t = W2.map[x .. ',' .. y .. ',' .. z]
        local f = t and (t.flow or ((t.c == '~' and 7) or (t.c == 'w' and 2) or 0)) or 0
        if t and not t.hidden and f >= (min or 1) then out[#out + 1] = {x, y, f} end
      end
    end
    return out
  end
  return W2
end

-- the reads of each runner slice (one W.frame runs at most one): the largest
local function wrap_steps(W)
  local step = runner.step
  local c = W.count
  W.runner_step = step
  runner.step = function(...)
    c.step = 0
    local r = step(...)
    if c.step > c.step_max then c.step_max = c.step end
    return r
  end
end

T.test('BUG-033: the bp folder after a boot: each file read once, only the explores decoded', function()
  local W = fort('boot', 12, 60)
  local opens, decodes = {}, 0
  local oopen, odec = io.open, json.try_decode
  io.open = function(p, m)
    local id = tostring(p):match('/bp/([^/]+)%.json$')
    if id and (m or 'r'):find('r') then opens[id] = (opens[id] or 0) + 1 end
    return oopen(p, m)
  end
  json.try_decode = function(s, ...)
    if type(s) == 'string' and s:find('"tpl":"bedrooms"', 1, true) then decodes = decodes + 1 end
    return odec(s, ...)
  end
  local ok, err = pcall(function()
    W.load(runner)
    H.runs(W, 20)                                  -- 10 days: the scan of 72 files (scan_n a run) is through
  end)
  io.open, json.try_decode = oopen, odec
  assert(ok, err)
  local most, n = 0, 0
  for id, k in pairs(opens) do most, n = math.max(most, k), n + 1 end
  T.eq(decodes, 0, 'no other template\'s file decoded (the old runner: each, twice)')
  T.eq(most, 1, 'each file opened once a boot (the old runner: twice, and an explore\'s at every look)')
  T.ok(n >= 60, 'the scan went through the folder: ' .. n)
end)

T.test('BUG-033: one shaft a slice; seepage reads the small box; a finished wet shaft every fin_every, a dry one daily',
       function()
  local W = fort('steady', 12, 0)
  wrap_steps(W)
  local ok, err = pcall(function()
    W.load(runner)
    H.runs(W, 12)                                  -- 6 days after the boot: every shaft seen once
    local c = W.count
    c.tile, c.lq, c.step_max = 0, 0, 0
    local days = 16
    H.runs(W, days * 2)
    local per_day = (c.tile + c.lq) // days
    print(string.format('# 12 finished explores beside seepage: %d tile + %d water reads a day, largest slice %d reads',
                        c.tile // days, c.lq // days, c.step_max))
    -- 12 finished wet shafts at fin_every 8 days: 1.5 looks a day; the old runner: 8 looks a day, each one 1,900+
    -- water tiles a candidate and every explore file decoded again
    T.ok(per_day <= 2600, 'tile + water reads a day: ' .. per_day .. ' (tile ' .. c.tile .. ', water ' .. c.lq .. ')')
    T.ok(c.step_max <= 2400, 'reads of the largest slice (one shaft): ' .. c.step_max)
    local looks = {}
    for _, l in ipairs(W.logs) do
      for id in l.msg:gmatch('(x%d+) %d+,%d+ z') do looks[id] = (looks[id] or 0) + 1 end
    end
    -- the odd shafts' pocket (4 tiles beside the bottom): read in the 9 x 9 box
    T.ok(not W.logs[#W.logs].msg:find('more next run'), 'the check keeps up: ' .. W.logs[#W.logs].msg)
  end)
  runner.step = W.runner_step
  assert(ok, err)
  -- a dry finished shaft stays daily (test_runner_shaft: a lake beside a done one is plugged within a day)
  local W2 = fort('dry', 2, 0)
  for i = 1, 2 do
    local x, y = shaft_xy(i)
    for dx = 1, 20 do local t = W2.tile(x + dx, y + 2, 91); t.c, t.flow = '#', 0 end
    for dx = 1, 2 do for dy = 2, 3 do local t = W2.tile(x - dx, y + dy, 91); t.c, t.flow = '#', 0 end end
  end
  W2.load(runner)
  H.runs(W2, 4)
  local n0 = 0
  for _, l in ipairs(W2.logs) do if l.msg:find('^cavern check: ') then n0 = n0 + 1 end end
  H.runs(W2, 8)                                    -- 4 days
  local n1 = 0
  for _, l in ipairs(W2.logs) do if l.msg:find('^cavern check: ') then n1 = n1 + 1 end end
  local lines = {}
  for _, l in ipairs(W2.logs) do if l.msg:find('^cavern check: ') then lines[#lines + 1] = l.msg end end
  T.ok(n1 - n0 >= 4, 'dry finished shafts: looked at daily (' .. (n1 - n0) .. ' lines in 4 days): ' .. table.concat(lines, ' | '))
end)

T.test('BUG-033: a seal past remake_max asks economy nothing more (the cell reads came before the budget check)', function()
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local asked = 0
  local W = H.world{tag = 'remake'}
  W.load{name = 'economy', every = {ticks = 1200}, mat_for = function() asked = asked + 1; return true, 'rock' end}
  W.load(runner)
  local P = {id = 's1', tpl = 'seal', stage = 0}
  local d = {stages = {{label = 'seal.build', mode = 'build', chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'd'}}}}}}}
  local R = {rm = runner.CFG.remake_max}
  T.eq(runner.remake(W.K, P, d, R), false)
  T.eq(asked, 0)
  R.rm = 0
  T.eq(runner.remake(W.K, P, d, R), true)
  T.eq(asked, 1)
end)

T.done()
