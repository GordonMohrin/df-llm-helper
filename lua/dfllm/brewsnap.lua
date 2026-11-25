-- brewsnap: NEU13 BUG-887 round 3, the measurement that decides WHY DF cancels a brew with "Needs empty food storage item" although our census counts free empty barrels.
-- Seven rounds of cures were built on guesses (trader barrels, mood-pile barrels, plant piles, pile limits, distance, Still count). The diagnosis of 25.11. (four forts)
-- could not say which barrel attribute DF rejects. This library only READS: it scans the empty food-storage items (barrels, large pots), splits them by state, names
-- the nearest free one, the Stills and their brew jobs, one brew job's job_item filter, and the cancel / completion counts of the window. It never writes a game
-- field, never creates a job, never moves an item. A library like cancelwhy / gamelog: the game readers are parameters (env), the tests hand mocks.
local B = {}

B.ITEMS_MAX = 6000        -- barrels + tools looked at per snapshot (one per game day at most)
B.FILTER_MAX = 4          -- job_item lines kept

local function names(bits)
  local out = {}
  local ok = pcall(function()
    for k, v in pairs(bits) do if v == true and type(k) == 'string' then out[#out + 1] = k end end
  end)
  table.sort(out)
  return ok and table.concat(out, '|') or '?'
end
B.names = names

local function enum_name(e, v)
  local ok, n = pcall(function() return e[v] end)
  return ok and type(n) == 'string' and n or tostring(v)
end

local function vec(name)
  local ok, v = pcall(function() return df.global.world.items.other[name] end)
  return ok and v or nil
end

-- the job that holds an item (specific ref JOB) -> its job type name, or nil
local function job_of(it)
  local ok, name = pcall(function()
    local ref = dfhack.items.getSpecificRef(it, df.specific_ref_type.JOB)
    local j = ref and ref.data and ref.data.job
    if not j then return nil end
    return enum_name(df.job_type, j.job_type)
  end)
  return ok and name or nil
end

-- the Stills: count, brew jobs, the first Still that holds a brew job (the cancelling Still is not named by DF's log line), one brew job's filter
function B.stills(env)
  local r = {n = 0, jobs = 0, list = {}}
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      if enum_name(df.workshop_type, b.type) == 'Still' then
        r.n = r.n + 1
        local x, y = b.centerx or b.x1, b.centery or b.y1
        local e = {id = b.id, x = x, y = y, z = b.z, jobs = 0}
        for _, j in ipairs(b.jobs or {}) do
          local tn = enum_name(df.job_type, j.job_type)
          if env.is_brew and env.is_brew(tn, j.reaction_name) then
            e.jobs, r.jobs = e.jobs + 1, r.jobs + 1
            if not r.job then r.job, r.job_still = j, e end
          end
        end
        if #r.list < 40 then r.list[#r.list + 1] = e end
      end
    end
  end)
  return r
end

-- the job_item filter of one brew job: {line, ...}; attached items by job_item_idx
function B.filter(env, j)
  local out = {}
  if not j then return out end
  local list = env.job_items and env.job_items(j) or nil
  if type(list) ~= 'table' then return out end
  local filled = {}
  pcall(function() for _, ref in ipairs(j.items) do filled[ref.job_item_idx] = (filled[ref.job_item_idx] or 0) + 1 end end)
  for i, ji in ipairs(list) do
    if i > B.FILTER_MAX then break end
    local function g(f) local ok, v = pcall(f); return ok and v ~= nil and tostring(v) or '?' end
    out[#out + 1] = string.format('item[%d] type=%s q=%s f1=[%s] f2=[%s] f3=[%s] f4=[%s] f5=[%s] rc=%s prod=%s tool=%s min_dim=%s vec=%s filled=%d', i - 1,
      g(function() return enum_name(df.item_type, ji.item_type) end), g(function() return ji.quantity end),
      g(function() return names(ji.flags1) end), g(function() return names(ji.flags2) end), g(function() return names(ji.flags3) end),
      g(function() return names(ji.flags4) end), g(function() return names(ji.flags5) end),
      g(function() return ji.reaction_class end), g(function() return ji.has_material_reaction_product end), g(function() return ji.has_tool_use end),
      g(function() return ji.min_dimension end), g(function() return ji.vector_id end), filled[i - 1] or 0)
  end
  return out
end

-- one look. env = {skipped = fn(flags) -> bool, trader = fn(item) -> bool, pot = fn(item) -> bool, far = fn(item) -> bool, surface = fn(x, y, z) -> bool, is_brew = fn(jobtypename, reaction) -> bool,
-- job_items = fn(job) -> list, inv = census inv, cancels = n, done = n | nil, days = window days, now = tick}
function B.collect(env)
  local s = {now = env.now, days = env.days, cancels = env.cancels, done = env.done, inv = env.inv or {}}
  local st = B.stills(env)
  s.stills, s.brewjobs = st.n, st.jobs
  local at = st.job_still or st.list[1]
  if at then s.still = {id = at.id, x = at.x, y = at.y, z = at.z, named = st.job_still ~= nil} end
  -- empties by type and state
  local E = {}
  for _, k in ipairs({'barrel', 'pot'}) do E[k] = {total = 0, empty = 0, free = 0, forb = 0, job = 0, haul = 0, trader = 0, far = 0, other = 0, out = 0} end
  s.jobs = {}
  local seen, near = 0, nil
  local function look(it, kind)
    seen = seen + 1
    local e = E[kind]
    e.total = e.total + 1
    local ok = pcall(function()
      if #dfhack.items.getContainedItems(it) ~= 0 then return end
      e.empty = e.empty + 1
      local f = it.flags
      if f.forbid then e.forb = e.forb + 1; return end
      if env.skipped and env.skipped(f) then e.other = e.other + 1; return end
      if kind == 'barrel' and env.trader and env.trader(it) then e.trader = e.trader + 1; return end
      if f.in_job then
        e.job = e.job + 1
        local jn = job_of(it) or '?'
        s.jobs[jn] = (s.jobs[jn] or 0) + 1
        if jn:find('^Store') or jn:find('Haul') or jn:find('^Fetch') then e.haul = e.haul + 1 end
        return
      end
      if env.far and env.far(it) then e.far = e.far + 1; return end
      e.free = e.free + 1
      local x, y, z = dfhack.items.getPosition(it)
      if x then
        if env.surface and env.surface(x, y, z) then e.out = e.out + 1 end
        if at then
          local d = math.abs(x - at.x) + math.abs(y - at.y) + math.abs(z - at.z)
          if not near or d < near.d then near = {d = d, x = x, y = y, z = z, dz = z - at.z, kind = kind} end
        end
      end
    end)
    if not ok then e.err = (e.err or 0) + 1 end
  end
  for _, it in ipairs(vec('BARREL') or {}) do
    if seen >= B.ITEMS_MAX then s.capped = true; break end
    look(it, 'barrel')
  end
  for _, it in ipairs(vec('TOOL') or {}) do
    if seen >= B.ITEMS_MAX then s.capped = true; break end
    if env.pot and env.pot(it) then look(it, 'pot') end
  end
  s.e, s.near = E, near
  s.filter = B.filter(env, st.job)
  return s
end

local function sum(s, k) return (s.e.barrel[k] or 0) + (s.e.pot[k] or 0) end
B.sum = sum

local function jobs_text(s)
  local ks = {}
  for k in pairs(s.jobs or {}) do ks[#ks + 1] = k end
  table.sort(ks)
  local out = {}
  for _, k in ipairs(ks) do out[#out + 1] = k .. ' ' .. s.jobs[k] end
  return table.concat(out, ', ')
end

-- the compact kern.log line
function B.line(s)
  local b, p = s.e.barrel, s.e.pot
  return string.format('brew cancel snapshot: DF cancelled Brew %s x in %s d, completed %s; %d Stills, %d brew jobs in them%s; empty barrels %d (free %d, forbidden %d, in a job %d [hauling %d], trader %d, far %d, other %d, outside %d), empty pots %d (free %d); plants %s, fruit %s; nearest free %s',
    tostring(s.cancels or '?'), tostring(s.days or '?'), tostring(s.done == nil and '?' or s.done), s.stills or 0, s.brewjobs or 0,
    s.still and string.format(' (Still %d at %d,%d,%d%s)', s.still.id, s.still.x, s.still.y, s.still.z, s.still.named and ', holds a brew job' or ', first') or '',
    b.empty, b.free, b.forb, b.job, b.haul, b.trader, b.far, b.other, b.out, p.empty, p.free,
    tostring(s.inv.brew_p or '?'), tostring(s.inv.brew_g or '?'),
    s.near and string.format('%s at %d,%d,%d dist %d dz %d', s.near.kind, s.near.x, s.near.y, s.near.z, s.near.d, s.near.dz) or 'none')
end

-- the event fields (JSON-able, nil dropped)
function B.fields(s)
  local b, p = s.e.barrel, s.e.pot
  local f = {stills = s.stills or 0, jobs = s.brewjobs or 0, empties = b.empty, free = b.free, forb = b.forb, job = b.job, haul = b.haul, trader = b.trader,
             far = b.far, other = b.other, out = b.out, pots = p.empty, pots_free = p.free, cancels = s.cancels, done = s.done,
             plants = s.inv.brew_p, fruit = s.inv.brew_g}
  if s.still then f.still = s.still.id end
  if s.near then f.near = s.near.d; f.dz = s.near.dz end
  if s.filter and s.filter[2] then f.filter = s.filter[2]:sub(1, 200) end
  return f
end

-- the block `why brew --raw` prints
function B.lines(s)
  local out = {B.line(s)}
  out[#out + 1] = string.format('  barrels: total %d empty %d free %d forbidden %d held-by-job %d (hauling/fetch %d) trader %d far %d other %d outside %d; pots: empty %d free %d forbidden %d held-by-job %d far %d',
    s.e.barrel.total, s.e.barrel.empty, s.e.barrel.free, s.e.barrel.forb, s.e.barrel.job, s.e.barrel.haul, s.e.barrel.trader, s.e.barrel.far, s.e.barrel.other, s.e.barrel.out,
    s.e.pot.empty, s.e.pot.free, s.e.pot.forb, s.e.pot.job, s.e.pot.far)
  local jt = jobs_text(s)
  if jt ~= '' then out[#out + 1] = '  jobs that hold an empty: ' .. jt end
  if s.capped then out[#out + 1] = '  (scan capped at ' .. B.ITEMS_MAX .. ' items)' end
  if s.near then out[#out + 1] = string.format('  nearest free empty %s at %d,%d,%d: distance %d (x+y+z), dz %d from the Still', s.near.kind, s.near.x, s.near.y, s.near.z, s.near.d, s.near.dz) end
  if #s.filter == 0 then out[#out + 1] = '  no brew job in a Still now: no filter to show'
  else for _, l in ipairs(s.filter) do out[#out + 1] = '  brew job ' .. l end end
  return out
end

return B
