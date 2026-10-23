-- runner, package L1 (BUG-102; Run 11/14 note 73): a drink-nook project (mood_drink) whose one place call quickfort answers
-- with "Stockpile tiles skipped (tile occupied)" (place_occupied, nothing designated) was finished as if it stood; the
-- refusal is kept on the project and care asks runner.nook_state for it. Every test here fails on 3045b94.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local Z = 143
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world(stats)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = 'nook', map_size = {16, 16, 160}}
  W.load(runner)
  W.state()
  -- the place mode of the fake quickfort answers like quickfort's place.lua (stats place_designated, place_occupied)
  local base = H.fake_qf
  W.act_result('quickfort', function(p)
    local ok, st = base(W, p)
    if ok and p.mode == 'place' and stats then
      for k, v in pairs(stats) do st[k] = v end
    end
    return ok, st
  end)
  H.floor(W, 60, 60, Z, 64, 60)
  return W
end

local function state(W, id)
  local ok, s, at = W.K.call('runner', 'nook_state', id)
  T.ok(ok, tostring(s))
  return s, at
end

T.test('BUG-102: a nook quickfort refuses is a refused project (nook_state), not a standing stockpile', function()
  local W = world{place_designated = 0, place_occupied = 1}
  local _, ok, id = W.K.call('runner', 'mooddrink', {61, 60, Z}, 'dfllm-stock', 'test')
  T.ok(ok, tostring(id))
  T.eq(state(W, id), 'pending')
  H.runs(W, 2)
  T.eq(H.proj(W, id).done, 1)
  local s, at = state(W, id)
  T.eq({s, at}, {'refused', '61,60,143'})
  local done = W.find_events('PROJECT_DONE')
  T.ok(done[#done].msg:find('refused', 1, true), done[#done].msg)
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find('refused by quickfort', 1, true) then n = n + 1 end end
  T.eq(n, 1)
end)

T.test('BUG-102: a placed nook, a fake that reports nothing and an unknown project are not refused', function()
  local W = world{place_designated = 1, place_tiles = 1}
  local _, _, id = W.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  H.runs(W, 2)
  T.eq(state(W, id), 'placed')
  local W2 = world(nil)
  local _, _, id2 = W2.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  H.runs(W2, 2)
  T.eq(state(W2, id2), 'placed', 'no place stats at all: as before')
  T.eq(state(W2, 'mdr-none'), nil)
  -- designated none and nothing counted occupied (off the map, an invalid key): refused too
  local W3 = world{place_designated = 0}
  local _, _, id3 = W3.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  H.runs(W3, 2)
  T.eq(state(W3, id3), 'refused')
end)

T.done()
