-- cancelwhy: DF's own reason for a job it cancelled, kept as a small rolling tally (NEU4, BUG-841). A library like jobwhy / dfraw: no game access.
--
-- DF creates the jobs itself and cancels them with a reason ("<unit> cancels Brew drink from plant: Needs empty food storage item."); the kernel
-- saw only "no job yet" for months. economy's REPORT handler (the CANCEL_JOB announcements eventful delivers, orderlib.cancel_parts) feeds
-- C.note; every consumer (why, brew_watch, ORDER_STUCK, the stall line, the status / ladder text) asks C.top / C.find.
--
-- The tally is persisted (m.economy `cw`): {v = 1, d = {[day] = {[kind] = {[reason] = n}}}, last = {[kind] = {[reason] = tick}}}. `kind` is DF's own
-- job name in lower case ("brew drink from plant", "make wooden door"), `reason` DF's words without the final dot (at most 60 bytes). Bounded:
-- C.KEEP days, C.MAX_KINDS kinds a day, C.MAX_REASONS reasons a kind and day (the rest counts under '(other)'). A count is a lower bound: the
-- eventful queue drops reports when it is full, and a message DF folds into a repeat count is one report.
local C = {}
local DAY = 1200
C.DAY = DAY
C.KEEP = 14           -- days kept
C.DAYS = 7            -- the default window of a question (config economy.cancel_days)
C.MAX_KINDS = 40      -- kinds per day
C.MAX_REASONS = 8     -- reasons per kind and day
C.OTHER = '(other)'

local function int(v) return math.tointeger(type(v) == 'string' and tonumber(v) or v) end

function C.fresh() return {v = 1, d = {}, last = {}} end

-- a persisted table (maybe decoded: an empty map is an array) -> a usable tally
function C.norm(t)
  if type(t) ~= 'table' or type(t.d) ~= 'table' or type(t.last) ~= 'table' or #t.d > 0 then return C.fresh() end
  return t
end

function C.prune(t, day)
  for k in pairs(t.d) do
    local dn = int(k)
    if not dn or dn < day - C.KEEP then t.d[k] = nil end
  end
  t.pruned = day
end

-- one cancel (or `n` of the same kind and reason, NEU6: a look of the gamelog reader groups its lines first): kind (DF's job name, any case), reason (DF's
-- words), tick
function C.note(t, kind, why, tick, n)
  kind, why, tick = tostring(kind or ''):lower():sub(1, 60), tostring(why or ''):gsub('%.$', ''):sub(1, 60), int(tick)
  n = int(n) or 1
  if kind == '' or not tick or n < 1 then return false end
  if why == '' then why = '?' end
  local day = tick // DAY
  if t.pruned ~= day then C.prune(t, day) end
  local dk = tostring(day)
  local d = t.d[dk]
  if type(d) ~= 'table' then d = {}; t.d[dk] = d end
  local k = d[kind]
  if not k then
    local nk = 0
    for _ in pairs(d) do nk = nk + 1 end
    if nk >= C.MAX_KINDS then kind = C.OTHER; k = d[kind] end
    if not k then k = {}; d[kind] = k end
  end
  if k[why] == nil then
    local nr = 0
    for _ in pairs(k) do nr = nr + 1 end
    if nr >= C.MAX_REASONS then why = C.OTHER end
  end
  k[why] = (k[why] or 0) + n
  local l = t.last[kind]
  if type(l) ~= 'table' then
    local nl = 0
    for _ in pairs(t.last) do nl = nl + 1 end
    if nl >= 4 * C.MAX_KINDS then
      for kk in pairs(t.last) do t.last[kk] = nil; break end       -- a bounded index: the oldest slot of the table order goes
    end
    l = {}; t.last[kind] = l
  end
  l[why] = tick
  return true
end

-- the matcher of a question: a string (exact kind), a list of strings (prefixes of the kind, 'brew ' = every brew), or a function(kind)
local function matcher(m)
  if type(m) == 'function' then return m end
  if type(m) == 'string' then return function(k) return k == m end end
  if type(m) == 'table' then
    return function(k)
      for _, p in ipairs(m) do if k:sub(1, #p) == p then return true end end
      return false
    end
  end
  return function() return true end
end

-- the entries {kind, why, n, last} within `days` game days up to `now`, most cancelled first; second result: all cancels of the window
function C.window(t, now, days, match)
  local pred = matcher(match)
  now, days = int(now) or 0, int(days) or C.DAYS
  local day0 = now // DAY - days + 1
  local sum, total = {}, 0
  for dk, d in pairs(t.d) do
    local dn = int(dk)
    if dn and dn >= day0 and type(d) == 'table' then
      for kind, k in pairs(d) do
        if pred(kind) then
          for why, n in pairs(k) do
            local key = kind .. '\0' .. why
            local e = sum[key]
            if not e then
              local l = type(t.last[kind]) == 'table' and int(t.last[kind][why]) or nil
              e = {kind = kind, why = why, n = 0, last = l}
              sum[key] = e
            end
            e.n = e.n + (int(n) or 0)
            total = total + (int(n) or 0)
          end
        end
      end
    end
  end
  local out = {}
  for _, e in pairs(sum) do out[#out + 1] = e end
  table.sort(out, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    if a.kind ~= b.kind then return a.kind < b.kind end
    return a.why < b.why
  end)
  return out, total
end

-- the most cancelled reason of the matching kinds (n summed over the kinds with that reason), or nil: {kind, why, n, last, days, kinds}
function C.top(t, now, days, match)
  local list = C.window(t, now, days, match)
  if #list == 0 then return nil end
  local by, order = {}, {}
  for _, e in ipairs(list) do
    local g = by[e.why]
    if not g then g = {why = e.why, n = 0, kinds = 0}; by[e.why] = g; order[#order + 1] = g end
    g.n, g.kinds = g.n + e.n, g.kinds + 1
    if not g.kind then g.kind = e.kind end
    if e.last and (not g.last or e.last > g.last) then g.last = e.last end
  end
  table.sort(order, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.why < b.why end)
  local g = order[1]
  g.days = int(days) or C.DAYS
  return g
end

-- n, last tick of the cancels whose reason holds `needle` (lower-case plain text), within the window
function C.count(t, now, days, match, needle)
  local n, last = 0, nil
  needle = tostring(needle or ''):lower()
  for _, e in ipairs(C.window(t, now, days, match)) do
    if e.why:lower():find(needle, 1, true) then
      n = n + e.n
      if e.last and (not last or e.last > last) then last = e.last end
    end
  end
  return n, last
end

-- 'DF cancelled Brew drink from plant 412x in 7 d: Needs empty food storage item (last 2 d ago)'; `e` from top()
function C.text(e, now)
  if type(e) ~= 'table' then return nil end
  local what = e.kind or 'jobs'
  if (e.kinds or 1) > 1 then what = what .. ' and ' .. (e.kinds - 1) .. ' more kind' .. (e.kinds > 2 and 's' or '') end
  local ago = ''
  if e.last and now then
    local d = (int(now) - e.last) // DAY
    ago = d <= 0 and ' (last today)' or string.format(' (last %d d ago)', d)
  end
  return string.format('DF cancelled %s %dx in %d d: %s%s', what, e.n, e.days or C.DAYS, e.why, ago)
end

-- the top reasons of the window for the status line: {{kind, why, n}, ...} at most `max`, every kind at most once
function C.summary(t, now, days, max)
  local out, seen = {}, {}
  for _, e in ipairs(C.window(t, now, days)) do
    if not seen[e.kind] and #out < (max or 3) then
      seen[e.kind] = true
      out[#out + 1] = {kind = e.kind, why = e.why, n = e.n}
    end
  end
  return out
end

return C
