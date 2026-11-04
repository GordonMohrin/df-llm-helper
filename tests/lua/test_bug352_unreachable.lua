-- BUG-352 (Run 16c site97, 04.11.2026): fortcore stage 1 placed on soil beyond the brook (another walk group than the 13
-- citizens'), 30 d at s1.dig 0 %, 'unreachable DigChannel'. The runner now names it after reach_days (3): PROJECT_BLOCKED
-- d.why 'unreachable' with the cancel / sites / place commands, the project's row says 'unreachable N d'; a reachable
-- dig, a tile with no walk group and a hidden one claim nothing.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local G, FAR = 1562, 1
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world(tag, g)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, census = {u = {cit = 2, adults = 2, ids = {1, 2}}}}
  for _, x in ipairs({8, 9}) do W.tile(x, 10, 100).c, W.tile(x, 10, 100).g = '.', G end
  W.add_unit{id = 1, citizen = true, pos = {8, 10, 100}}
  W.add_unit{id = 2, citizen = true, pos = {9, 10, 100}}
  for x = 30, 34 do
    local t = W.tile(x, 30, 100)
    t.c, t.g = '#', g
  end
  W.load(runner)
  W.state()
  return W
end

local function row(W, id) for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end end
local function events(W)
  local out = {}
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.why == 'unreachable' then out[#out + 1] = e end end
  return out
end

T.test('BUG-352: a dig stage in another walk group is named unreachable after reach_days, once, with the commands', function()
  local W = world('b352far', FAR)
  H.place(W, 'cx', H.dig_doc(1, {x = 30, y = 30, z = 100}))
  H.runs(W, 2 * 2)                                   -- 2 days: not yet
  T.eq(#events(W), 0, 'not before reach_days')
  H.runs(W, 2 * 4)
  local ev = events(W)
  T.eq(#ev, 1, 'announced once')
  T.eq(ev[1].d.proj, 'cx')
  T.eq(ev[1].d.tpl, 'fortcore')
  T.ok(ev[1].d.unreach >= 3, 'days')
  T.ok(ev[1].msg:find('unreachable: no citizen reaches the s1.dig dig (walk groups 1; citizens 1562)', 1, true), ev[1].msg)
  T.ok(ev[1].d.cmd:find('bp.cancel proj=cx', 1, true) and ev[1].d.cmd:find('dfllm bp sites fortcore --fresh', 1, true)
       and ev[1].d.cmd:find('bp.place tpl=fortcore site=S1 stage=1', 1, true), ev[1].d.cmd)
  local r = row(W, 'cx')
  T.ok(r[4]:find('^unreachable %d+ d: bp.cancel, place again$'), T.show(r))
  H.runs(W, 2 * 5)
  T.eq(#events(W), 1, 'no repeat')
end)

T.test('BUG-352: a dig the citizens reach, a tile without a walk group and a hidden one give no claim', function()
  local W = world('b352near', G)
  H.place(W, 'cx', H.dig_doc(1, {x = 30, y = 30, z = 100}))
  H.runs(W, 2 * 8)
  T.eq(#events(W), 0, 'reachable')
  T.ok(not (row(W, 'cx') or {'', '', 0, ''})[4]:find('unreachable', 1, true))
  local W2 = world('b352none', 0)
  H.place(W2, 'cx', H.dig_doc(1, {x = 30, y = 30, z = 100}))
  H.runs(W2, 2 * 8)
  T.eq(#events(W2), 0, 'no walk group: no claim')
  local W3 = world('b352hid', FAR)
  for x = 30, 34 do W3.tile(x, 30, 100).hidden = true end
  H.place(W3, 'cx', H.dig_doc(1, {x = 30, y = 30, z = 100}))
  H.runs(W3, 2 * 8)
  T.eq(#events(W3), 0, 'hidden: unknown, no claim')
end)

T.done()
