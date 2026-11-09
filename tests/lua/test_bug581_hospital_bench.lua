-- BUG-581 (Run 16a i1 Basementflew y423-y426: the hospital project stood 'build_lost at build' at 28 % for 8 retries and 300 days, patients dying
-- of thirst beside a room with its beds: the traction bench needs a mechanism and the fort had no reachable hard stone). The bench is optional
-- for the hospital: a bench quickfort refused (its tile stays empty) is no lost piece, a bench placed but waiting for its mechanism is not
-- awaited; the rest of the room is built and the project is done. Any other missing piece still ends build_lost. Every test fails before.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function fresh(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag}
  W.real_bench = true
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  return W
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end
-- three beds and a traction bench in one build stage (cells at y 10 and y 11)
local function doc(tpl, extra)
  local d = H.doc{tpl = tpl, class = 'living', params = {}, manifest = {v = 2}}
  d.stages[2].chunks[1].cells = {{0, 0, 0, 'b'}, {1, 0, 0, 'b'}, {2, 0, 0, 'b'}, {0, 1, 0, 'R'}}
  for _, c in ipairs(extra or {}) do d.stages[2].chunks[1].cells[#d.stages[2].chunks[1].cells + 1] = c end
  return d
end
local function run_project(W, d, finish)
  H.floor(W, 10, 10, 100, 14, 11)
  H.place(W, 'dr', d)
  H.runs(W, 6)
  H.dig(W)
  for _ = 1, 8 do finish(W); H.runs(W, 1) end
end
local function build_all_but_bench(W)
  for _, b in pairs(W.buildings) do
    if b._t ~= df.building_type.TractionBench then b._st = 1 end
  end
end
local function proj(W) return H.proj(W, 'dr') end

T.test('BUG-581: a traction bench quickfort refused is no lost piece: the hospital is done without it', function()
  local W = fresh('hb1')
  W.unsuitable['10,11,100'] = true
  run_project(W, doc('hospital'), build_all_but_bench)
  T.eq(proj(W).done, 1, 'the hospital went on past its build stage: ' .. T.show(proj(W)))
  T.ok(proj(W).blocked ~= 'build_lost', 'not build_lost')
  T.ok(logged(W, 'BUG-581'), 'logged')
end)

T.test('BUG-581: a traction bench placed and waiting for its mechanism is not awaited', function()
  local W = fresh('hb2')
  run_project(W, doc('hospital'), build_all_but_bench)
  local bench = W.buildings[W.bld_at['10,11,100']]
  T.eq(bench._t, df.building_type.TractionBench, 'a real bench was placed')
  T.ok(bench._st == 0, 'the bench itself is not built')
  T.eq(proj(W).done, 1, 'done: ' .. T.show(proj(W)))
  T.ok(logged(W, 'optional piece'), 'logged')
end)

T.test('BUG-581: another missing piece of the hospital still ends build_lost (only the bench is optional)', function()
  local W = fresh('hb3')
  W.unsuitable['10,11,100'] = true
  W.unsuitable['11,10,100'] = true
  W.unsuitable['12,10,100'] = true
  run_project(W, doc('hospital'), build_all_but_bench)
  T.ok(proj(W).done ~= 1, 'not done: ' .. T.show(proj(W)))
  T.eq(proj(W).blocked, 'build_lost')
end)

T.test('BUG-581: bedrooms keep the old rule: a refused piece of another template is a loss', function()
  local W = fresh('hb4')
  W.unsuitable['10,11,100'] = true
  run_project(W, doc('bedrooms'), build_all_but_bench)
  T.ok(proj(W).done ~= 1, 'not done: ' .. T.show(proj(W)))
  T.eq(proj(W).blocked, 'build_lost')
end)

T.done()
