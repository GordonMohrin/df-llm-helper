-- BUG-365 (Run 16c i3 Yawninggilt, 16a-d): 's1.dig chunk 8: designation at 111,80,124 lost twice without a damp report:
-- blocked' (dig_lost, 4 forts). DF had cancelled the designation on an aquifer tile ('Digging designation cancelled: damp
-- stone located', 56 times in the gamelog) and the announcement log search found no report. The lost tile itself carries the
-- aquifer flag (snapshot.tile aq): that is damp stone. Every test fails on 3d1b3f1 (merge of rounds 14-18).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  require('dfllm.aqshaft').CFG.on = true
  local W = H.world(opts)
  W.load(runner)
  return W
end
local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end

T.test('BUG-365: a lost designation on an aquifer tile is damp stone, not dig_lost (legacy stop)', function()
  local W = fresh{tag = 'b365a'}
  require('dfllm.aqshaft').CFG.on = false              -- FR-95 off: the old breach:damp stop
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 2)
  W.tile(11, 10, 100).aq = true                        -- revealed aquifer tile, no report in the log
  W.tile(11, 10, 100).dig = ''
  H.runs(W, 1)
  local ev = W.find_events('BREACH_STOP')
  T.eq(#ev, 1)
  T.eq(ev[1].d, {proj = 'c1', why = 'damp', pos = {11, 10, 100}, src = 'cancel'})
  T.eq(H.proj(W, 'c1').blocked, 'breach:damp')
  T.ok(not logged(W, 'error', 'lost twice without a damp report'))
end)

T.test('BUG-365: in observe mode the chunk is designated again with the damp marker', function()
  local W = fresh{tag = 'b365b'}
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 2)
  W.tile(11, 10, 100).aq = true
  W.tile(11, 10, 100).dig = ''
  H.runs(W, 2)
  T.ok(logged(W, 'warn', 'damp stone at 11,10,100 designated again with the damp marker'), 'observe mode digs on')
  T.ok(H.proj(W, 'c1').blocked ~= 'dig_lost')
  T.ok(not logged(W, 'error', 'lost twice without a damp report'))
end)

T.test('BUG-365: a lost designation on a dry tile stays dig_lost', function()
  local W = fresh{tag = 'b365c'}
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 2)
  W.tile(11, 10, 100).dig = ''                         -- aq false: nothing says damp
  H.runs(W, 1)
  T.ok(logged(W, 'warn', 'designation at 11,10,100 lost without a damp report: chunk designated again'))
  W.tile(11, 10, 100).dig = ''
  H.runs(W, 1)
  T.eq(H.proj(W, 'c1').blocked, 'dig_lost')
end)

T.done()
