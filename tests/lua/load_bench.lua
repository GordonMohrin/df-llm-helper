-- FR-62 measurement (not a test): the real kernel with the real sense, economy, care, baseline, arbiter, perf
-- and selftest on a Run 9-sized fort (load_world: 402 units, 18.7k items) plus a seal stand-in (a sliced job
-- every frame and a 1,500-piece persist record, like seal's perimeter), timed on the real cost clock
-- (os.clock in this interpreter). Prints ms per simulated second per cost owner.
--   python tools/luahost.py --path tests/lua tests/lua/load_bench.lua [seconds] [fps]
local L = require('load_world')
local H = require('kern_world')
local kern = require('dfllm.kern')

local secs = tonumber(arg and arg[1]) or 120
local fps = tonumber(arg and arg[2]) or 100
local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local W = L.world{tag = 'bench', ms_per_frame = 1000 // fps}
L.count_unit_calls(W)
local seal = {name = 'seal', every = {ticks = 50}, slices = 0}
local perim = {}
for i = 1, 1500 do perim['p' .. i] = {k = 'wall', pos = {i % 200, i // 200, 100}, t = i} end
function seal.step(K)
  seal.slices = seal.slices + 1
  local x = 0
  for i = 1, 800 do x = x + i % 7 end                  -- CFG.work 800 work units per frame
  if seal.slices % 400 == 0 then K.persist.set('m.seal', {v = 2, perim = perim, n = seal.slices}) end
  return 'more'
end
function seal.entrances() return nil end
local mods = {fresh('sense'), fresh('arbiter'), seal, fresh('economy'), fresh('care'), fresh('baseline'),
              fresh('perf'), fresh('selftest')}
assert(H.boot(W, {repo = require('wp8_world').REPO, modules = mods}))
kern.cost_clock = function() return os.clock() * 1000 end
local K = kern.K()
local t0 = os.clock()
local frames = secs * fps
local skips = {4, 5}
for i = 1, frames do H.frame(W, skips[i % 2 + 1]) end
local real = os.clock() - t0
local p = L.profile(W, secs // 30)
local list = {}
for k, v in pairs(p.mods) do list[#list + 1] = {k, v} end
table.sort(list, function(a, b) return a[2] > b[2] end)
print(string.format('# %d units, %d items, load x%.2f, budget %d ms/s; %d frames (%d fps) in %.1f s real',
                    #df.global.world.units.active, W.n_items, K.load and K.load().f or 1, kern.budget and kern.budget() or 25,
                    frames, fps, real))
print(string.format('# kernel %.1f ms per simulated second (perf.csv rows: %d)', p.ms_s, p.rows))
for _, x in ipairs(list) do print(string.format('#   %-10s %6.2f ms/s', x[1], x[2])) end
print(string.format('# sense: %d unit predicate calls, %d raw lookups; seal slices %d', W.unit_calls, W.raw_finds,
                    seal.slices))
for _, m in ipairs(kern.status().modules) do
  if m.paced and m.paced > 0 then print(string.format('#   paced %-10s %d frames (share %s ms/s)', m.name, m.paced, tostring(m.share))) end
end
kern.stop('bench')
