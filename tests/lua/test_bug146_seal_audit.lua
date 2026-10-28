-- BUG-146 (live test i3, Trussroads y717): seal's refuge audit (reach, refuge levels, REFUGE_STOCK's floor) was weeks of
-- game time old while other seal jobs held the slices; the refuge choice ran on that data. Fixture of test_seal.lua.
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end
local function evs(W, t) return W.find_events(t) end
local function inspect(W, what, key)
  local r = W.inbox('inspect', {what = what, key = key})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end
local function has(list, pat)
  for _, s in ipairs(list or {}) do if tostring(s):find(pat, 1, true) then return true end end
  return false
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end

---------------------------------------------------------------- the reach fort (z 5)
-- room A x2-8 y2-8 (beds, drink, food), corridor y5 x9-11, room B x12-18 y2-8 (seeds); citizens 1-2 in A, 3-5 in B
local Z = 5
local function fort(opts)
  opts = opts or {}
  local W = SW.new{persist = opts.persist}
  SW.fill(W, Z, 0, 0, 20, 10, '#')
  SW.fill(W, Z, 2, 2, 8, 8, '.')
  SW.fill(W, Z, 12, 2, 18, 8, '.')
  SW.fill(W, Z, 9, 5, 11, 5, '.')
  SW.draw(W, Z, {'bb'}, 3, 3)
  if opts.draw then opts.draw(W) end
  SW.regroup(W)
  SW.citizens(W, {{1, 4, 4, Z}, {2, 5, 5, Z}, {3, 14, 4, Z}, {4, 15, 5, Z}, {5, 16, 6, Z}})
  if opts.items ~= false then
    SW.item(W, 'DRINK', 6, 6, Z, 10)
    SW.item(W, 'PLANT', 7, 7, Z, 20)
    SW.item(W, 'SEEDS', 16, 7, Z, 5)
  end
  for _, m in ipairs(opts.mods or {}) do W.load(m) end
  local M = seal()
  W.load(M)
  return W, M
end


T.test('BUG-146 (live i3: refuge audit data 60,000 ticks old while seal ran other jobs): an audit older than 2 x ' ..
       'audit_every runs as an urgent job, even while background work must wait; before that it still waits', function()
  local busy = false
  local trade = {name = 'trade', every = {ticks = 10}}
  function trade.step(K) if busy then K.boost('trade screen', true) else K.unboost() end end
  local W = fort{mods = {trade}}
  W.run(2400, {skip = 9})
  local runs0 = inspect(W, 'reach').runs
  T.ok((runs0.audit or 0) >= 1, 'the boot audit ran')
  busy = true                                             -- background work waits from here on (BUG-026)
  W.run(4200, {skip = 9})
  T.eq(inspect(W, 'reach').runs.audit, runs0.audit, 'past audit_every: still waits (BUG-026 unchanged)')
  W.run(3600, {skip = 9})                                 -- past 2 x audit_every
  T.ok(inspect(W, 'reach').runs.audit > runs0.audit, 'old code: the audit starves for as long as the wait lasts')
  T.ok(logged(W, 'refuge audit is overdue'), 'kern.log says why it runs now')
end)

T.done()
