-- NEU6 (BUG-851): the gamelog reader decoupled from the economy run. Live (main 55e827ed, i4 Girderroots, 530-860 ticks/s): the reader looked once per FRESH economy
-- run, two of which lay 10-20 game days apart; the source fell back to 'report' (3 days fresh), the 7-day window held almost nothing and the container gate
-- (>= 5 "Needs empty food storage item" cancels in 7 days) never fired although DF wrote ~110 such lines per 400 gamelog lines. Offline: the real kernel
-- (kern_world) drives economy's M.watch every watch_every ticks; the log grows while the game runs; economy's own step only runs every 10 game days.
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')
local GL = require('dfllm.gamelog')

local DAYT = 1200
local PLANT = 'Iden Urist, Woodcrafter cancels Brew drink from plant: Needs empty food storage item.\n'
local FRUIT = 'Domas Urist, militia captain cancels Brew drink from fruit: Needs unrotten fermentable leaf or fruit.\n'
local WELL = 'Mebzuth Urist, Peasant cancels Drink: Well dry.\n'
local BORING = 'The Dwarven caravan from Foo has arrived.\n'

local function append(path, s)
  local f = assert(io.open(path, 'ab'))
  f:write(s)
  f:close()
end
local function tmp(tag)
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_bug851-' .. tag
  luahost.mkdir_recursive(dir)
  os.remove(dir .. '/gamelog.txt')
  return dir, dir .. '/gamelog.txt'
end
local function logs_with(W, pat)
  local out = {}
  for _, l in ipairs(H.lines(W.sd .. '/kern.log')) do
    if l:find(pat, 1, true) then out[#out + 1] = l end
  end
  return out
end

-- ---------------------------------------------------------------------------------------------------------------- the library
T.test('BUG-851 gamelog: several chunks per look read a flooded backlog, the prefilter hands only " cancels " lines to the parser, s.behind says what is left', function()
  local _, path = tmp('lib')
  append(path, 'head\n')
  local s = GL.new(path)
  GL.poll(s, {})
  local flood = {}
  for i = 1, 3000 do flood[#flood + 1] = (i % 2 == 0) and WELL or ((i % 5 == 0) and PLANT or BORING) end
  append(path, table.concat(flood))
  local size = #table.concat(flood)
  local r = GL.poll(s, {max = 8192})                                  -- one chunk: 8 KB only
  T.ok(s.behind > 0 and s.behind < size, 'behind ' .. s.behind)
  T.eq(s.lastlook.bytes <= 8192, true)
  local one = #r
  local r2 = GL.poll(s, {max = 8192, chunks = 64})                     -- many chunks in ONE look: all of it
  T.eq(s.behind, 0)
  T.eq(one + #r2, 1500 + 300, 'every cancel line of the flood (1500 Drink + 300 Brew)')
  T.eq(s.lines, 3000)
  local seen = 0
  local r3 = GL.poll(s, {parse = function(line) seen = seen + 1 end})   -- a custom parser still sees every line (no prefilter)
  T.eq({#r3, seen}, {0, 0})
  append(path, BORING .. BORING)
  GL.poll(s, {parse = function(line) seen = seen + 1 end})
  T.eq(seen, 2)
end)

-- ---------------------------------------------------------------------------------------------------------------- economy on the real kernel
local function econ_module(tag, step_every, on_step)
  local dir, path = tmp(tag)
  local W = H.world{tag = 'k851-' .. tag, dfpath = dir}
  append(path, 'start of the log' .. string.char(10))
  package.loaded['dfllm.economy'] = nil
  local E = require('dfllm.economy')
  local box = {W = W, E = E, path = path, runs = {}}
  -- the real economy's watch pass and gate, a stub for its heavy step: a fresh run only every `step_every` ticks (live: 10-20 game days apart at 800 t/s)
  local mod = {name = 'economy', every = {ticks = step_every}, watch_every = E.watch_every, watch = E.watch,
               init = function(K) box.K = K; E.init(K) end,
               step = function(K)
                 box.runs[#box.runs + 1] = {tick = K.now().tick, gate = E.cx_gate(K, nil, K.now().tick), h = E.cw_health(K)}
                 if on_step then on_step(box, K) end
               end}
  local ok, msg = H.boot(W, {modules = {mod}})
  assert(ok, msg)
  return box
end

T.test('BUG-851: a quiet log keeps the source gamelog (no fallback to report), the health says quiet, looks made and backlog 0', function()
  local b = econ_module('quiet', 12000)
  H.run(b.W, 5 * DAYT, {skip = 16})
  local h = b.E.cw_health(b.K)
  T.ok(h.source == 'gamelog', h.text)
  T.ok(h.text:find('the log is quiet', 1, true) and h.text:find(' looks, 0 B behind', 1, true), h.text)
  local looks = b.E.cw_health(b.K).text:match('(%d+) looks')
  T.ok(tonumber(looks) >= 9, 'one look per half game day: ' .. tostring(looks))
  kern.stop()
end)

T.test('BUG-851 + BUG-852: 800 ticks/s, economy runs 10 game days apart, a growing flooded log: the gate opens within a game week of DF starting to cancel, ON and OFF are logged once', function()
  local b = econ_module('flood', 12000)
  local W = b.W
  local t0 = b.K.now().tick
  local frame_ticks = 16                                          -- 50 frames/s * 16 = 800 ticks/s
  local start = t0 + 4 * DAYT                                     -- DF cancels from the 4th game day on
  local stop = t0 + 40 * DAYT                                     -- ... and stops at day 40
  local started = false
  local f = 0
  local gate_seen
  while b.K.now().tick < t0 + 80 * DAYT do
    local now = b.K.now().tick
    if now >= start and now < stop then
      started = true
      append(b.path, PLANT .. WELL .. WELL .. WELL .. BORING)    -- 3 of 5 lines are "Drink: Well dry."
    end
    H.frame(W, frame_ticks, 20)
    f = f + 1
    if not gate_seen and b.E.cx_gate(b.K, nil, b.K.now().tick) then gate_seen = b.K.now().tick end
  end
  T.ok(started)
  T.ok(gate_seen, 'the gate opened')
  T.ok(gate_seen - start <= 7 * DAYT, string.format('gate %.2f game days after DF started to cancel', (gate_seen - start) / DAYT))
  local on = logs_with(W, 'container cure ON: DF cancelled brew')
  T.eq(#on, 1, 'one ON line: ' .. table.concat(on, ' / '))
  T.ok(on[1]:find('x in 7 d: Needs empty food storage item', 1, true))
  local ton = tonumber(on[1]:match('^%d+%s+(%d+)'))
  T.ok(ton and ton - start <= 7 * DAYT, 'the line stands at tick ' .. tostring(ton))
  local off = logs_with(W, 'container cure OFF: DF cancelled brew')
  T.eq(#off, 1, 'one OFF line: ' .. table.concat(off, ' / '))
  local toff = tonumber(off[1]:match('^%d+%s+(%d+)'))
  T.ok(toff and toff > stop and toff - stop <= 24 * DAYT, 'BUG-867: OFF after the window (7 d) and 14 quiet game days: ' .. tostring(toff and (toff - stop) / DAYT))
  -- the economy's own runs were 10 game days apart: the first run after DF started saw an open gate (the old reader looked only there)
  local gaps = {}
  for i = 2, #b.runs do gaps[#gaps + 1] = (b.runs[i].tick - b.runs[i - 1].tick) / DAYT end
  T.ok(#b.runs >= 5 and gaps[1] >= 9.9, 'economy runs ' .. #b.runs .. ', gap ' .. tostring(gaps[1]))
  local seen
  for _, r in ipairs(b.runs) do if r.tick >= start and r.tick < stop then seen = seen or r end end
  T.ok(seen and seen.gate and seen.gate >= 5, 'the first economy run in the flood sees the gate: ' .. T.show(seen and seen.gate))
  T.ok(seen.h.source == 'gamelog' and seen.h.text:find(' looks, ', 1, true) and seen.h.text:find(' behind', 1, true), seen.h.text)
  T.ok((b.E.df_reason(b.K, 'drink', nil, stop) or {}).why == 'Well dry', 'the drink cancels are in the tally too')
  local h = b.E.cw_health(b.K).text
  T.ok(h:find('source gamelog', 1, true), h)
  kern.stop()
end)

T.test('BUG-851: a backlog the size of a long pause is read in ONE look (chunks) and the bytes behind show what is left', function()
  local b = econ_module('backlog', 1000000)
  H.run(b.W, 700, {skip = 16})                                    -- one look made
  local flood = {}
  for i = 1, 6000 do flood[#flood + 1] = (i % 2 == 0) and WELL or PLANT end
  append(b.path, table.concat(flood))
  local sz = #table.concat(flood)
  T.ok(sz > 131072 * 3 and sz < 1048576, 'bigger than three chunks: ' .. sz)
  H.run(b.W, 700, {skip = 16})
  T.eq(b.E.cw_health(b.K).n, 6000)
  T.ok(b.E.cw_health(b.K).text:find(' 0 B behind', 1, true), b.E.cw_health(b.K).text)
  kern.stop()
end)

T.done()
