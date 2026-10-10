-- WP1 misc: util/geom, decisions.yaml parsing, the real module loader, selftest, dfllm.lua entry.
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local geom = require('dfllm.util.geom')
local fio = require('dfllm.io')
local kern = require('dfllm.kern')

local REPO = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/'):gsub('/tests/lua/[^/]+$', '')

T.test('geom: Chebyshev distance, bbox helpers, both position forms', function()
  T.eq(geom.dist({x = 1, y = 2, z = 3}, {4, 0, 3}), 3)
  T.eq(geom.dist({0, 0, 0}, {0, 0, -7}), 7)
  T.ok(geom.in_bbox({x = 5, y = 5, z = 1}, {0, 0, 1, 5, 5, 1}))
  T.ok(not geom.in_bbox({6, 5, 1}, {0, 0, 1, 5, 5, 1}))
  T.eq(geom.bbox_center({50, 10, 130, 52, 12, 130}), {x = 51, y = 11, z = 130})
  T.eq(geom.bbox_union({0, 0, 0, 1, 1, 1}, {-2, 3, 0, 0, 4, 9}), {-2, 0, 0, 1, 4, 9})
  T.eq({geom.bbox_size({50, 10, 130, 52, 12, 130})}, {3, 3, 1})
  T.ok(geom.near_any({0, 0, 0}, {{10, 0, 0}, {3, 3, 3}}, 3))
  T.ok(not geom.near_any({0, 0, 0}, {{10, 0, 0}}, 3))
  T.eq(geom.arr({x = 1, y = 2, z = 3}), {1, 2, 3})
  T.eq(geom.pos(1, 2, 3), {x = 1, y = 2, z = 3})
end)

T.test('decisions.yaml: flat lines, comments, defaults kept', function()
  local d = {}
  for k, v in pairs(C.DECISIONS) do d[k] = v end
  kern.parse_decisions('# header\r\nD-07: visitor  # Gordon\r\nD-01 :B\nD-99\nD-03:\nnoise: 1\n', d)
  T.eq({d['D-07'], d['D-01'], d['D-03'], d['D-12']}, {'visitor', 'B', 'rule', '15/20'})
end)

T.test('io helpers: rotated names, last_line, write_new collisions', function()
  T.eq(fio.rotated('/a/events.jsonl'), '/a/events.1.jsonl')
  T.eq(fio.rotated('/a/kern.log'), '/a/kern.1.log')
  T.eq(fio.basename('C:\\DF\\save\\region3\\'), 'region3')
  H.world{tag = 'io'}   -- dfhack.filesystem fakes
  local d = H.tmpdir('io-files')
  H.write(d .. '/x.jsonl', '{"n":1}\n{"n":2}\n{"n":3')
  T.eq(fio.last_line(d .. '/x.jsonl'), '{"n":2}')
  T.eq(fio.write_new(d, 'r.json', '1'), d .. '/r.json')
  T.eq(fio.write_new(d, 'r.json', '2'), d .. '/r-1.json')
  T.eq(H.read(d .. '/r.json'), '1')
  T.eq(luahost.isfile(d .. '/r.json.tmp'), false)
end)

T.test('real loader: contract order, missing and broken modules skipped and logged', function()
  local W = H.world{tag = 'loader'}
  local seen = {}
  for _, m in ipairs(C.MODULES) do
    if m.wp ~= 'WP1' then
      package.loaded['dfllm.' .. m.name] = nil
      package.preload['dfllm.' .. m.name] = function()
        if m.name == 'trade' then return nil end                       -- not landed yet
        if m.name == 'care' then error('syntax-ish error in care') end
        if m.name == 'economy' then return {name = 'economie', every = {ticks = 1200}} end
        if m.name == 'runner' then return {name = 'runner', every = {seconds = 3}} end
        return {name = m.name, every = m.every, init = function() seen[#seen + 1] = m.name end}
      end
    end
  end
  local ok, msg = kern.boot{repo = W.dir}
  T.ok(ok, msg)
  local names = {}
  for _, m in ipairs(kern.status().modules) do names[#names + 1] = m.name end
  T.eq(names, {'sense', 'threat', 'siege', 'gate', 'military', 'drill', 'readiness', 'arbiter', 'snapshot',
               'baseline', 'perf', 'selftest'})
  T.eq(seen, {'sense', 'threat', 'siege', 'gate', 'military', 'drill', 'readiness', 'snapshot', 'baseline'})
  kern.stop()
  local log = H.read(W.sd .. '/kern.log')
  T.ok(log:find('syntax-ish error in care', 1, true), 'load error logged')
  T.ok(log:find('dfllm.economy does not return its module table', 1, true))
  T.ok(log:find('runner.every must be', 1, true))
  for _, m in ipairs(C.MODULES) do
    if m.wp ~= 'WP1' then package.preload['dfllm.' .. m.name] = nil; package.loaded['dfllm.' .. m.name] = nil end
  end
end)

T.test('selftest: verb quick/full, periodic step, mock check, exec refused without DFLLM_DEV', function()
  local W = H.world{tag = 'selftest', ms_per_frame = 1000}
  local selftest = require('dfllm.selftest')
  H.boot(W, {modules = {require('dfllm.arbiter'), require('dfllm.perf'), selftest}})
  H.run(W, 3)
  H.inbox(W, 's1', 'selftest', {suite = 'full'})
  H.inbox(W, 's2', 'selftest', {})
  H.run(W, 2)
  local r1, r2 = H.outbox(W, 's1'), H.outbox(W, 's2')
  T.eq({r1.ok, r1.data.fail}, {true, 0}, r1.msg)
  T.ok(r1.data.pass >= 9)
  T.eq({r2.ok, r2.data.pass}, {true, 6})
  T.eq(selftest.mock_check(), {pass = 1, fail = 0, failed = {}})
  local K = kern.K()
  T.eq({selftest.exec(K, W.dir .. '/x.lua')}, {false, 'set DFLLM_DEV=1 to use --exec'})
  kern.stop()   -- flushes persist
  T.eq(json.decode(W.persist_raw['dfllm.m.selftest']).runs, 1)
end)

T.test('dfllm.lua entry: usage, status when stopped, selftest --mock, restore with nothing to do', function()
  H.world{tag = 'entry'}
  dfhack.findScript = function(name) return REPO .. '/lua/' .. name .. '.lua' end
  local out = {}
  local saved_print = print
  print = function(...) out[#out + 1] = table.concat({...}, '\t') end
  local chunk = assert(loadfile(REPO .. '/lua/dfllm.lua'))
  chunk()
  chunk('status')
  chunk('selftest', '--mock')
  chunk('restore')
  print = saved_print
  T.ok(out[1]:find('^usage: dfllm boot'), out[1])
  T.eq(out[2], 'dfllm: kernel not running')
  T.eq(out[3], 'dfllm selftest: 1 pass, 0 fail ')
  T.eq(out[4], 'dfllm: nothing to restore')
end)

T.done()
