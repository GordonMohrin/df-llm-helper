-- dfllm.rotation (FR-79): library (not a kernel module) for military: which citizens sit in a militia squad, window by
-- window. Gordon 2026-10-23 (note 67, goal Z12 "every adult citizen who is not elite serves three months a year in the
-- militia"): the kernel follows it by itself. FR-71 gave every militia squad its months (military.conf militia); this file
-- holds the pure rules that turn those months into turnover: the window edges, the ranking of the citizens by the militia
-- windows they served, and the plan that swaps the members of a squad for the next cohort. No DFHack, no state: military
-- reads the game, keeps the counts (persist m.military served/rot) and does the squads screen's squad_remove/squad_add.
--   edge     a window CLOSES at the first month that is not in the set after one that is (months 0-11, cyclic: a window
--            {11, 0, 1} closes in month 2). The turnover happens at the close: the next cohort sits in the squad through
--            the months off duty, is equipped by the time the window opens, and an interrupted turnover (a siege, a
--            lockdown) has the whole off period to run (a window that reopens first lapses: the same cohort serves again).
--   fairness a citizen served once is ranked after everyone who served less (served ascending, then unit id): over a few
--            years everybody serves once before anybody twice.
--   plan     the next cohort is the first `size` of the ranking (military filters the eligible ones: adults, no noble, no
--            mood, no patient, no other squad, no sole holder of a key labor); members who are in it stay (their kit stays),
--            the others leave in swaps with the entrants: out = the most served first, in = the least served first.
local R = {}

R.MONTH = 33600
R.YEAR_MONTHS = 12

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end

local function inwin(win, m) return win[m % 12] == true end

-- absolute month of a game date: year * 12 + month (0-11)
function R.abs_month(year, ytick)
  return (int(year) or 0) * 12 + (int(ytick) or 0) // R.MONTH
end

-- the months of a window set as text: "9-11" (a run), "9,10,11,1" (otherwise); nil for an empty set
function R.months_text(win)
  local ms = {}
  for m = 0, 11 do if win[m] == true then ms[#ms + 1] = m end end
  if #ms == 0 then return nil end
  local run = true
  for i = 2, #ms do if ms[i] ~= ms[i - 1] + 1 then run = false end end
  if run and #ms > 1 then return ms[1] .. '-' .. ms[#ms] end
  return table.concat(ms, ',')
end

-- the window edges around absolute month a, or nil for a set that has none (no month, or all twelve: always on duty)
--   open        a is a month of the window
--   close       the absolute month of the latest close edge at or before a (always within the last twelve months)
--   to_close    months until the next close edge, 0 when a is a close month itself
--   next_close  months until the next close edge after this month (1-12)
function R.edges(win, a)
  if type(win) ~= 'table' or not int(a) then return nil end
  local n = 0
  for m = 0, 11 do if win[m] == true then n = n + 1 end end
  if n == 0 or n == 12 then return nil end
  local r = {open = inwin(win, a)}
  for d = 0, 11 do
    local x = a - d
    if not inwin(win, x) and inwin(win, x - 1) then r.close = x; break end
  end
  for d = 0, 12 do
    local x = a + d
    if not inwin(win, x) and inwin(win, x - 1) then r.to_close = d; break end
  end
  for d = 1, 12 do
    local x = a + d
    if not inwin(win, x) and inwin(win, x - 1) then r.next_close = d; break end
  end
  return r
end

-- game days until the close edge `months` months away (the start of that month); 0 for the current month
function R.days_to(months, ytick)
  if not months or months <= 0 then return 0 end
  local into = (int(ytick) or 0) % R.MONTH
  return (months * R.MONTH - into) // 1200
end

-- ids sorted by served windows ascending, then unit id; `served` is {[id] = n}
function R.rank(ids, served)
  served = served or {}
  local r = {}
  for i, id in ipairs(ids) do r[i] = id end
  table.sort(r, function(x, y)
    local sx, sy = served[x] or 0, served[y] or 0
    if sx ~= sy then return sx < sy end
    return x < y
  end)
  return r
end

-- the first `size` of the ranked candidates that `ok(id)` lets in (ok may keep its own account: it is called in rank
-- order, once per candidate that could still be picked); returns the picks and the ids ok() refused
function R.pick(ranked, size, ok)
  local picks, refused = {}, {}
  for _, id in ipairs(ranked) do
    if #picks >= size then break end
    if ok == nil or ok(id) then picks[#picks + 1] = id else refused[#refused + 1] = id end
  end
  return picks, refused
end

-- the swap plan: members = the ids in the squad that may be replaced (the leader stays and is not listed), picks = the
-- next cohort. out = the members who are not in it, the most served first (then the highest id); into = the picks who are
-- not members yet, in rank order (the least served first).
function R.plan(members, picks, served)
  served = served or {}
  local in_picks, in_members = {}, {}
  for _, id in ipairs(picks) do in_picks[id] = true end
  for _, id in ipairs(members) do in_members[id] = true end
  local out, into = {}, {}
  for _, id in ipairs(members) do if not in_picks[id] then out[#out + 1] = id end end
  table.sort(out, function(x, y)
    local sx, sy = served[x] or 0, served[y] or 0
    if sx ~= sy then return sx > sy end
    return x > y
  end)
  for _, id in ipairs(picks) do if not in_members[id] then into[#into + 1] = id end end
  return out, into
end

-- {min, max} of the served counts of ids (0 for an id without a count); {0, 0} for an empty list
function R.spread(ids, served)
  served = served or {}
  local lo, hi
  for _, id in ipairs(ids) do
    local n = served[id] or 0
    if lo == nil or n < lo then lo = n end
    if hi == nil or n > hi then hi = n end
  end
  return lo or 0, hi or 0
end

return R
