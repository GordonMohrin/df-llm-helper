-- Integration audit I1 (state size): the kernel's shared view (K.view, read by gate, care, drill, economy, readiness) is the
-- complete document; only the file the readers see is shed to 4 KB. Before, a fort whose state passed 4 KB lost `trade`
-- (the caravan window of the bridges), `proj`, `bridges` ... for the kernel's own modules as well.
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')

local function big_gate()
  return {name = 'gate', every = {ticks = 10}, state = function()
    local b = {}
    for i = 1, 400 do b[string.format('B%04d', i)] = 'down' end
    return {bridges = b}
  end}
end

local function trade_mod()
  return {name = 'trade', every = {ticks = 10}, state = function()
    return {trade = {caravan = 1, ratio = 100, done = 0}}
  end}
end

T.test('I1: a document over 4 KB is shed in the file, not in K.view() (the kernel modules still see the caravan)', function()
  local W = H.world{tag = 'i1_view', ms_per_frame = 500}
  H.boot(W, {modules = {big_gate(), trade_mod()}, strict = false})
  H.run(W, 100, {skip = 10})
  local s = H.state(W)
  T.ok(#H.read(W.sd .. '/state.a.json') <= 4096, 'the file stays within 4 KB')
  T.eq(s.trade, nil, 'trade was shed in the file (the first of its group)')
  T.eq(s.bridges, nil, 'and the big key too')
  local v = kern.K().view()
  T.eq(v.trade and v.trade.caravan, 1, 'the view keeps trade: gate.window_open, drill.merchants read it')
  T.ok(type(v.bridges) == 'table' and v.bridges.B0001 == 'down', 'and the bridges: economy reads them to tell a split')
  kern.stop()
end)

T.done()
