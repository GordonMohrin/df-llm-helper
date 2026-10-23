-- FR-79: the pure rules of the militia rotation (lua/dfllm/rotation.lua): window edges (also across the year change),
-- the fairness ranking and the swap plan. No DF, no kernel.
local T = require('testlib')
local R = require('dfllm.rotation')

local function set(...) local s = {}; for _, m in ipairs({...}) do s[m] = true end; return s end

T.test('edges: a window 9-11 closes in month 0; open, to_close and next_close count the months', function()
  local w = set(9, 10, 11)
  local a = 3 * 12 + 10                                  -- year 3, month 10: inside the window
  local e = R.edges(w, a)
  T.eq(e.open, true)
  T.eq(e.close, 3 * 12 + 0, 'the close edge before this window opened')
  T.eq(e.to_close, 2, 'month 0 of the next year is two months away')
  T.eq(e.next_close, 2)
  e = R.edges(w, 4 * 12 + 0)                             -- the close month itself
  T.eq({e.open, e.close, e.to_close, e.next_close}, {false, 4 * 12, 0, 12})
  e = R.edges(w, 4 * 12 + 5)
  T.eq({e.open, e.close, e.to_close, e.next_close}, {false, 4 * 12, 7, 7})
end)

T.test('edges: a window across the year change {11, 0, 1} closes in month 2', function()
  local w = set(11, 0, 1)
  local e = R.edges(w, 4 * 12 + 0)
  T.eq(e.open, true)
  T.eq(e.close, 3 * 12 + 2, 'the close edge before: month 2 of year 3')
  T.eq(e.to_close, 2)
  e = R.edges(w, 4 * 12 + 2)
  T.eq({e.open, e.close, e.to_close}, {false, 4 * 12 + 2, 0})
  e = R.edges(w, 4 * 12 + 10)
  T.eq({e.open, e.close, e.to_close}, {false, 4 * 12 + 2, 4})
end)

T.test('edges: two windows in the set give two edges a year; an empty or a full set has none', function()
  local w = set(1, 2, 7)
  T.eq(R.edges(w, 4 * 12 + 4).close, 4 * 12 + 3, 'months 1-2 closed in month 3')
  T.eq(R.edges(w, 4 * 12 + 4).to_close, 4, 'the single month 7 closes in month 8')
  T.eq(R.edges(w, 4 * 12 + 9).close, 4 * 12 + 8)
  T.eq(R.edges({}, 5), nil)
  local all = {}
  for m = 0, 11 do all[m] = true end
  T.eq(R.edges(all, 5), nil)
  T.eq(R.edges(nil, 5), nil)
end)

T.test('days_to: the days until the start of a month that many months away', function()
  T.eq(R.days_to(0, 100), 0)
  T.eq(R.days_to(1, 0), 28)
  T.eq(R.days_to(2, 33600 * 3 + 1200 * 4), 52, 'month 3, day 4 of the month: 2 months = 56 - 4 days')
end)

T.test('months_text: a run reads 9-11, anything else lists the months', function()
  T.eq(R.months_text(set(9, 10, 11)), '9-11')
  T.eq(R.months_text(set(3)), '3')
  T.eq(R.months_text(set(1, 5)), '1,5')
  T.eq(R.months_text({}), nil)
end)

T.test('rank: served ascending, then the unit id', function()
  local r = R.rank({7, 3, 9, 1, 5}, {[3] = 2, [7] = 1, [1] = 1})
  T.eq(r, {5, 9, 1, 7, 3})
end)

T.test('fairness: cohorts of 3 out of 10 serve every citizen once before anyone twice', function()
  local ids, served, seen = {}, {}, {}
  for i = 1, 10 do ids[i] = i end
  for window = 1, 7 do
    local picks = R.pick(R.rank(ids, served), 3)
    for _, id in ipairs(picks) do
      -- nobody who served more than someone not yet picked
      local lo = math.huge
      for _, o in ipairs(ids) do if (served[o] or 0) < lo then lo = served[o] or 0 end end
      T.ok((served[id] or 0) == lo, 'window ' .. window .. ': ' .. id .. ' served ' .. (served[id] or 0) .. ' while someone served ' .. lo)
      served[id] = (served[id] or 0) + 1
      seen[#seen + 1] = id
    end
    if window == 4 then                                 -- 12 places, 10 citizens: the first 10 are all different
      local first = {}
      for i = 1, 10 do first[seen[i]] = true end
      local n = 0
      for _ in pairs(first) do n = n + 1 end
      T.eq(n, 10, 'the first ten places went to ten different citizens')
    end
  end
  local lo, hi = R.spread(ids, served)
  T.ok(hi - lo <= 1, 'the counts differ by at most one: ' .. lo .. '..' .. hi)
end)

T.test('pick: the refused ids are skipped and reported, the rank order holds', function()
  local seen = {}
  local picks, refused = R.pick({1, 2, 3, 4, 5}, 2, function(id) seen[#seen + 1] = id; return id ~= 2 end)
  T.eq(picks, {1, 3})
  T.eq(refused, {2})
  T.eq(seen, {1, 2, 3}, 'ok() is not called past the size')
end)

T.test('plan: members who stay in the cohort keep their place; out = most served first, into = least served first', function()
  local served = {[1] = 2, [2] = 1, [3] = 1, [4] = 0, [5] = 0, [6] = 0}
  local out, into = R.plan({1, 2, 3}, {2, 4, 5}, served)
  T.eq(out, {1, 3}, 'the most served leave first')
  T.eq(into, {4, 5})
  out, into = R.plan({2, 4, 5}, {2, 4, 5}, served)
  T.eq({out, into}, {{}, {}}, 'the same cohort: nothing to do')
  out, into = R.plan({}, {4, 5}, served)
  T.eq({out, into}, {{}, {4, 5}}, 'an empty squad: only entrants')
end)

T.done()
