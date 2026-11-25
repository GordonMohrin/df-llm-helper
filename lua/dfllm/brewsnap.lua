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

-- the flag census (BUG-887 round 3b): which item flags / general_ref types do the empties carry? H1 'phantom empties' says: free by our scan, rejected by DF through a flag
B.CENSUS_FLAGS = {'container', 'foreign', 'in_inventory', 'artifact', 'spider_web', 'dead_dwarf', 'on_ground', 'owned', 'in_building', 'hostile', 'trader', 'melt', 'dump', 'rotten', 'encased', 'in_job'}
B.COMBO_MAX = 12          -- distinct flag combinations kept per histogram
B.ATTACHED_MAX = 8        -- attached barrels (job_item_idx 1) described in full (the histogram counts all of them)
B.ATTACHED_SCAN = 64      -- attached barrels looked at per pass over the Stills' jobs
B.JOBS_MAX = 200          -- brew jobs walked per pass
B.ACC_IDS = 300           -- barrel ids remembered for the dedup of the accumulator
B.ACC_KEYS = 24           -- distinct flag / ref keys per accumulator histogram (more are counted as '(other)')
B.ACC_LAST = 8            -- last attached barrels kept with their fields

-- the census flags an item carries, sorted, joined by '+' ('-' = none)
local function combo(f)
  local out = {}
  for _, k in ipairs(B.CENSUS_FLAGS) do
    local ok, v = pcall(function() return f[k] end)
    if ok and v == true then out[#out + 1] = k end
  end
  return #out > 0 and table.concat(out, '+') or '-'
end
B.combo = combo

-- the general_ref type names of an item, sorted, joined by '+' ('-' = none)
local function ref_names(it)
  local out, seen = {}, {}
  pcall(function()
    for _, r in ipairs(it.general_refs) do
      local okt, t = pcall(function() return r:getType() end)
      local n = okt and enum_name(df.general_ref_type, t) or '?'
      if not seen[n] then seen[n] = true; out[#out + 1] = n end
    end
  end)
  table.sort(out)
  return #out > 0 and table.concat(out, '+') or '-'
end
B.ref_names = ref_names

local function bump(t, k) t[k] = (t[k] or 0) + 1 end

-- a histogram {key = n} -> 'a=3;b=1' (largest first, at most COMBO_MAX)
local function hist_text(h)
  local ks = {}
  for k in pairs(h or {}) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) if h[a] ~= h[b] then return h[a] > h[b] end return a < b end)
  local out = {}
  for i, k in ipairs(ks) do
    if i > B.COMBO_MAX then out[#out + 1] = '...'; break end
    out[#out + 1] = k .. '=' .. h[k]
  end
  return #out > 0 and table.concat(out, ';') or '-'
end
B.hist_text = hist_text

-- general_ref occurrences by type name {TYPE = n} (every ref counted, unlike ref_names)
local function ref_counts(it)
  local out = {}
  pcall(function()
    for _, r in ipairs(it.general_refs) do
      local okt, t = pcall(function() return r:getType() end)
      bump(out, okt and enum_name(df.general_ref_type, t) or '?')
    end
  end)
  return out
end
B.ref_counts = ref_counts

local function counts_text(h)
  local ks = {}
  for k in pairs(h) do ks[#ks + 1] = k end
  table.sort(ks)
  local out = {}
  for _, k in ipairs(ks) do out[#out + 1] = k .. ':' .. h[k] end
  return #out > 0 and table.concat(out, ',') or '-'
end

local function n_specific(it)
  local n = 0
  pcall(function() n = #it.specific_refs end)
  return n
end

local function mat_of(it)
  local ok, t = pcall(function() return dfhack.matinfo.decode(it):getToken() end)
  return ok and type(t) == 'string' and t or '?'
end

local function wear_of(it)
  local ok, w = pcall(function() return it.wear end)
  return ok and math.tointeger(w) or nil
end

-- one attached barrel as a record {id, c = census combo, r = ref types, rc = ref counts text, sp = specific refs, nc = contents, f = ALL set flags, m = material, w = wear, st, job}
local function record(it, extra)
  local nc = 0
  pcall(function() nc = #dfhack.items.getContainedItems(it) end)
  local r = {id = it.id, c = combo(it.flags), r = ref_names(it), rc = counts_text(ref_counts(it)), sp = n_specific(it), nc = nc, f = names(it.flags), m = mat_of(it), w = wear_of(it)}
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end
B.record = record

local function rec_text(r)
  return string.format('#%s flags=[%s] census=%s refs=%s refcount=%s specific=%s contents=%d mat=%s wear=%s%s', tostring(r.id), tostring(r.f), tostring(r.c), tostring(r.r), tostring(r.rc), tostring(r.sp),
    r.nc or 0, tostring(r.m), tostring(r.w == nil and '?' or r.w), r.st and (' still=' .. tostring(r.st)) or '')
end
B.rec_text = rec_text

-- the barrels DF attached to the brew jobs (job_item_idx 1) of ALL brew jobs of ALL Stills, deduped by item id, at most ATTACHED_SCAN -> {{it, still, job}, ...}
function B.attached_all(env, st)
  local out, seen = {}, {}
  for _, e in ipairs(st.alljobs or {}) do
    pcall(function()
      for _, ref in ipairs(e.job.items) do
        if ref.job_item_idx == 1 and ref.item and #out < B.ATTACHED_SCAN and not seen[ref.item.id] then
          seen[ref.item.id] = true
          out[#out + 1] = {it = ref.item, still = e.still}
        end
      end
    end)
  end
  return out
end

-- the accumulator (kernel's own persisted state): union histograms of the attached barrels' flags / refs, count of distinct barrels, last ones
function B.acc_new() return {n = 0, ids = {}, combo = {}, refs = {}, mat = {}, last = {}, wear = 0, nc0 = 0, set = 0, passes = 0, moments = {}} end
local function acc_bump(h, k)
  if h[k] == nil then
    local n = 0
    for _ in pairs(h) do n = n + 1 end
    if n >= B.ACC_KEYS then k = '(other)' end
  end
  h[k] = (h[k] or 0) + 1
end
-- add one record; false when this barrel id is already known (dedup)
function B.acc_add(acc, r, now)
  acc.ids = type(acc.ids) == 'table' and acc.ids or {}
  for _, id in ipairs(acc.ids) do if id == r.id then return false end end
  acc.ids[#acc.ids + 1] = r.id
  while #acc.ids > B.ACC_IDS do table.remove(acc.ids, 1) end
  acc.combo, acc.refs = type(acc.combo) == 'table' and acc.combo or {}, type(acc.refs) == 'table' and acc.refs or {}
  acc_bump(acc.combo, r.c); acc_bump(acc.refs, r.r)
  acc.mat = type(acc.mat) == 'table' and acc.mat or {}
  acc_bump(acc.mat, tostring(r.m or '?'))
  acc.n = (acc.n or 0) + 1
  if (r.nc or 0) == 0 then acc.nc0 = (acc.nc0 or 0) + 1 end
  if tostring(r.c):find('container', 1, true) then acc.set = (acc.set or 0) + 1 end
  if (r.w or 0) > 0 then acc.wear = (acc.wear or 0) + 1 end
  acc.last = type(acc.last) == 'table' and acc.last or {}
  local keep = {}
  for k, v in pairs(r) do if type(v) == 'string' or type(v) == 'number' or type(v) == 'boolean' then keep[k] = v end end
  keep.t = now
  acc.last[#acc.last + 1] = keep
  while #acc.last > B.ACC_LAST do table.remove(acc.last, 1) end
  return true
end

function B.acc_lines(acc)
  if type(acc) ~= 'table' or (acc.n or 0) == 0 then return {'taken-accumulator: EMPTY (no barrel seen attached to a brew job yet; this leaves H1 undecided, it is no refutation)'} end
  local out = {string.format('taken-accumulator: %d distinct attached barrels (with the container flag %d, nothing inside %d, wear > 0 %d); flag combos %s; refs %s', acc.n, acc.set or 0, acc.nc0 or 0, acc.wear or 0, hist_text(acc.combo), hist_text(acc.refs))}
  out[#out + 1] = '  taken-accumulator materials: ' .. hist_text(acc.mat)
  if acc.vmn then
    out[#out + 1] = string.format('  taken-accumulator vector membership (%s, %s): in vector %d, not in it %d (counted when each barrel was first seen)', tostring(acc.vmn), tostring(acc.vsrc), acc.vin or 0, acc.vout or 0)
  end
  for _, r in ipairs(acc.last or {}) do out[#out + 1] = '  taken: ' .. rec_text(r) .. (r.t and (' seen tick ' .. tostring(r.t)) or '') end
  return out
end

-- the cheap sampler: only a walk over the Stills' job lists, no item-vector scan. Adds every attached barrel not yet known to acc; returns the number added
function B.sample(env, acc, now)
  local st = B.stills(env)
  local added, fresh = 0, {}
  for _, a in ipairs(B.attached_all(env, st)) do
    local ok, r = pcall(record, a.it, {st = a.still and a.still.id})
    if ok and B.acc_add(acc, r, now) then added = added + 1; fresh[#fresh + 1] = r.id end
  end
  acc.passes = (acc.passes or 0) + 1
  if added > 0 then
    pcall(function()
      local v = B.vector_id(env, st, acc)
      if not v then return end
      local set = B.vector_set(v)
      acc.vmn, acc.vsrc = v.vid .. ' ' .. v.name, v.src
      for _, id in ipairs(fresh) do
        if set[id] then acc.vin = (acc.vin or 0) + 1 else acc.vout = (acc.vout or 0) + 1 end
      end
    end)
  end
  return added
end

-- ---------------------------------------------------------------------------------------------------------------------------------------------------------------
-- BUG-887 round 5: vector membership (DF's job item search walks world.items.other[job_item.vector_id]), material / location of the free empties, cancel timing, drink stock
B.VEC_CANDIDATES = {'FOOD_STORAGE', 'ANY_FOOD_STORAGE', 'ANY_GENERIC'}   -- tried by name when no job_item and no remembered vector id is at hand
B.MOMENTS = 20            -- cancel moments kept in the accumulator
B.BLD_MAX = 300           -- findAtTile calls per snapshot

local function median(t)
  if #t == 0 then return nil end
  local c = {}
  for i, v in ipairs(t) do c[i] = v end
  table.sort(c)
  return c[(#c + 1) // 2]
end
B.median = median

local function sdiv(a, b)
  if not a or not b or b == 0 then return nil end
  return a / b
end

-- the vector id of the brew job's container job_item (flags3.food_storage, else the second item): from the live job, else the last one remembered in acc, else a named candidate
-- -> {vid, name, src} or nil
function B.vector_id(env, st, acc)
  local vid, src
  local list = st and st.job and env.job_items and env.job_items(st.job) or nil
  if type(list) == 'table' then
    local pick
    for i, ji in ipairs(list) do
      local ok, fs = pcall(function() return ji.flags3.food_storage == true end)
      if ok and fs then pick = ji; break end
      if i == 2 then pick = pick or ji end
    end
    if pick then
      local ok, v = pcall(function() return math.tointeger(pick.vector_id) end)
      if ok and v and v >= 0 then vid, src = v, 'job_item of a live brew job' end
    end
  end
  if not vid and acc and math.tointeger(acc.vid) then vid, src = math.tointeger(acc.vid), 'last seen in a brew job (accumulator)' end
  if not vid then
    for _, cand in ipairs(B.VEC_CANDIDATES) do
      local ok, v = pcall(function() return df.items_other_id[cand] end)
      if ok and math.tointeger(v) then vid, src = math.tointeger(v), 'GUESS: enum name ' .. cand .. ' (no brew job_item seen yet)'; break end
    end
  end
  if not vid then return nil end
  local name = enum_name(df.items_other_id, vid)
  if acc and src:find('^last seen') and type(acc.vname) == 'string' then name = acc.vname end
  if acc and src:find('^job_item') then acc.vid, acc.vname = vid, name end
  return {vid = vid, name = name, src = src}
end

-- the item ids of world.items.other[vid] as a set -> set, size, capped (one pass, at most ITEMS_MAX)
function B.vector_set(v)
  local set, n, capped = {}, 0, false
  pcall(function()
    local o = df.global.world.items.other
    local vv = o[v.name]
    if vv == nil then vv = o[v.vid] end
    for _, it in ipairs(vv or {}) do
      if n >= B.ITEMS_MAX then capped = true; break end
      set[it.id] = true; n = n + 1
    end
  end)
  return set, n, capped
end

-- the stockpiles as rectangles {name tag, x1, y1, x2, y2, z}; tag = dfllm-... name, 'unnamed pile' or 'other pile'
function B.piles()
  local out = {}
  pcall(function()
    for _, sp in ipairs(df.global.world.buildings.other.STOCKPILE) do
      local nm = sp.name or ''
      local okd, u = pcall(function() return dfhack.df2utf(nm) end)
      if okd and type(u) == 'string' then nm = u end
      local tag = nm:match('^(dfllm%-[%w_]+)') or (nm == '' and 'unnamed pile' or 'other pile')
      out[#out + 1] = {tag, sp.x1, sp.y1, sp.x2, sp.y2, sp.z}
    end
  end)
  return out
end
function B.pile_at(piles, x, y, z)
  for _, q in ipairs(piles) do
    if z == q[6] and x >= q[2] and x <= q[4] and y >= q[3] and y <= q[5] then return q[1] end
  end
  return 'none'
end
-- the building other than a stockpile on a tile -> its type name, or nil
function B.bld_at(x, y, z)
  local ok, b = pcall(dfhack.buildings.findAtTile, x, y, z)
  if not ok or not b then return nil end
  local okt, t = pcall(function() return b:getType() end)
  local pile = false
  pcall(function() pile = okt and df.building_type.Stockpile ~= nil and t == df.building_type.Stockpile end)
  if pile then return nil end
  return okt and enum_name(df.building_type, t) or '?'
end

-- the cheap cancel moment (no item scan): brew jobs in all Stills, how many hold a barrel (job_item_idx 1), how many hold a plant (job_item_idx 0), Stills; the free empties are the last snapshot's
function B.moment(env, acc, now, n)
  local st = B.stills(env)
  local wb, wp = 0, 0
  for _, e in ipairs(st.alljobs) do
    local hb, hp = false, false
    pcall(function()
      for _, ref in ipairs(e.job.items) do
        if ref.job_item_idx == 1 then hb = true elseif ref.job_item_idx == 0 then hp = true end
      end
    end)
    if hb then wb = wb + 1 end
    if hp then wp = wp + 1 end
  end
  acc.moments = type(acc.moments) == 'table' and acc.moments or {}
  acc.moments[#acc.moments + 1] = {t = now, st = st.n, j = st.jobs, b = wb, p = wp, f = math.tointeger(acc.free), n = n or 1}
  while #acc.moments > B.MOMENTS do table.remove(acc.moments, 1) end
  return acc.moments[#acc.moments]
end

local function mm(t)
  if #t == 0 then return '-' end
  local lo, hi = t[1], t[1]
  for _, v in ipairs(t) do if v < lo then lo = v end; if v > hi then hi = v end end
  local md = median(t)
  local function fmt(v) return v == math.floor(v) and string.format('%d', v) or string.format('%.1f', v) end
  return string.format('%s / %s / %s', fmt(lo), fmt(md), fmt(hi))
end

-- the kept moments as number lists
function B.moment_stats(acc)
  local ms = type(acc) == 'table' and type(acc.moments) == 'table' and acc.moments or {}
  local j, b, p, s, r = {}, {}, {}, {}, {}
  for _, m in ipairs(ms) do
    j[#j + 1], b[#b + 1], p[#p + 1], s[#s + 1] = m.j or 0, m.b or 0, m.p or 0, m.st or 0
    local q = sdiv(m.j, m.f)
    if q then r[#r + 1] = q end
  end
  return {n = #ms, j = j, b = b, p = p, s = s, r = r}
end
function B.moment_lines(acc)
  local m = B.moment_stats(acc)
  if m.n == 0 then return {'cancel timing: no cancel moment recorded yet (the gamelog reader records one per look that sees a container cancel)'} end
  return {string.format('cancel timing (%d moments; min / median / max): brew jobs in all Stills %s; jobs already holding a barrel %s; holding a plant %s; Stills %s; brew jobs per free empty (free from the last snapshot) %s',
    m.n, mm(m.j), mm(m.b), mm(m.p), mm(m.s), mm(m.r)),
    '  burst reading: with about one job per Still posted at once, each job beyond the free empties finds them reserved; ratio >= 1 supports a burst artefact, ratio << 1 refutes it'}
end

-- the DRINK stock: units and stacks (one capped pass); the delta since the last snapshot is NET of drinking, no brew count
function B.drink_stock()
  local u, n = 0, 0
  local ok = pcall(function()
    for _, it in ipairs(vec('DRINK') or {}) do
      if n >= B.ITEMS_MAX then break end
      n = n + 1
      u = u + (math.tointeger(it.stack_size) or 0)
    end
  end)
  return ok and {u = u, n = n} or nil
end

-- the Stills: count, brew jobs, the first Still that holds a brew job (the cancelling Still is not named by DF's log line), one brew job's filter
function B.stills(env)
  local r = {n = 0, jobs = 0, list = {}, alljobs = {}}
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
            if #r.alljobs < B.JOBS_MAX then r.alljobs[#r.alljobs + 1] = {job = j, still = e} end
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
  s.matf, s.loc, s.locz, s.locb, s.locn, s.matt = {}, {}, {}, {}, 0, {}
  local piles, bcalls = nil, 0
  -- flag census over ALL empties and over the free ones (container set vs clear), and the general_ref types
  s.cen = {all = {}, free = {}, refs_all = {}, refs_free = {}, free_set = 0, free_clear = 0, all_set = 0, all_clear = 0,
                rc_free = {}, spec_items = 0, spec_total = 0, wear_free = 0, fids = {}}
  local seen, near = 0, nil
  local function look(it, kind)
    seen = seen + 1
    local e = E[kind]
    e.total = e.total + 1
    local ok = pcall(function()
      if #dfhack.items.getContainedItems(it) ~= 0 then return end
      e.empty = e.empty + 1
      local f = it.flags
      local cb, rn = combo(f), ref_names(it)
      local cset = f.container == true
      bump(s.cen.all, cb); bump(s.cen.refs_all, rn)
      if cset then s.cen.all_set = s.cen.all_set + 1 else s.cen.all_clear = s.cen.all_clear + 1 end
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
      bump(s.cen.free, cb); bump(s.cen.refs_free, rn)
      if cset then s.cen.free_set = s.cen.free_set + 1 else s.cen.free_clear = s.cen.free_clear + 1 end
      for k, n in pairs(ref_counts(it)) do s.cen.rc_free[k] = (s.cen.rc_free[k] or 0) + n end
      local sp = n_specific(it)
      if sp > 0 then s.cen.spec_items, s.cen.spec_total = s.cen.spec_items + 1, s.cen.spec_total + sp end
      if (wear_of(it) or 0) > 0 then s.cen.wear_free = s.cen.wear_free + 1 end
      s.cen.fids[#s.cen.fids + 1] = {it.id, cset}
      bump(s.matf, mat_of(it))
      local x, y, z = dfhack.items.getPosition(it)
      if x then
        piles = piles or B.piles()
        bump(s.loc, B.pile_at(piles, x, y, z)); bump(s.locz, tostring(z))
        if bcalls < B.BLD_MAX then
          bcalls = bcalls + 1
          local bn = B.bld_at(x, y, z)
          if bn then s.locn = s.locn + 1; bump(s.locb, bn) end
        end
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
  -- age split of the free empties: item id rank (a lower id is an older item), old = at or below the median id
  local ids = {}
  for _, v in ipairs(s.cen.fids) do ids[#ids + 1] = v[1] end
  table.sort(ids)
  local med = ids[(#ids + 1) // 2]
  s.cen.median = med
  s.cen.old, s.cen.new, s.cen.old_set, s.cen.new_set = 0, 0, 0, 0
  for _, v in ipairs(s.cen.fids) do
    if v[1] <= med then s.cen.old = s.cen.old + 1; if v[2] then s.cen.old_set = s.cen.old_set + 1 end
    else s.cen.new = s.cen.new + 1; if v[2] then s.cen.new_set = s.cen.new_set + 1 end end
  end
  -- BUG-887 round 5: membership of the free empties in the vector DF's job item search walks (job_item.vector_id of the brew job)
  local vset
  local v = B.vector_id(env, st, env.acc)
  if v then
    local set, n, capped = B.vector_set(v)
    vset = set
    s.vec = {vid = v.vid, name = v.name, src = v.src, n = n, capped = capped, free_in = 0, free_n = #s.cen.fids, taken_in = 0, taken_n = 0}
    for _, x in ipairs(s.cen.fids) do if set[x[1]] then s.vec.free_in = s.vec.free_in + 1 end end
    if env.acc then env.acc.vmn, env.acc.vsrc = v.vid .. ' ' .. v.name, v.src end
  end
  s.cen.fids = nil
  -- ALL brew jobs of ALL Stills: the barrels DF attached (job_item_idx 1) now, a histogram of all of them and a full description of at most ATTACHED_MAX
  local att = B.attached_all(env, st)
  s.taken, s.taken_n, s.taken_combo, s.taken_refs, s.taken_old, s.taken_mat = {}, #att, {}, {}, 0, {}
  for _, a in ipairs(att) do
    local ok, r = pcall(record, a.it, {st = a.still and a.still.id})
    if ok then
      bump(s.taken_combo, r.c); bump(s.taken_refs, r.r); bump(s.taken_mat, tostring(r.m or '?'))
      if s.vec then
        s.vec.taken_n = s.vec.taken_n + 1
        if vset and vset[r.id] then s.vec.taken_in = s.vec.taken_in + 1 end
      end
      if med and r.id <= med then s.taken_old = s.taken_old + 1 end
      if #s.taken < B.ATTACHED_MAX then s.taken[#s.taken + 1] = rec_text(r) end
      if env.acc then B.acc_add(env.acc, r, env.now) end
    end
  end
  s.acc = env.acc
  s.free_all = (E.barrel.free or 0) + (E.pot.free or 0)
  s.drink = B.drink_stock()
  if env.acc then
    env.acc.free = s.free_all
    if s.drink then
      s.drink.prev_u, s.drink.prev_t = env.acc.drink_u, env.acc.drink_t
      env.acc.drink_u, env.acc.drink_t = s.drink.u, env.now
    end
  end
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
  return string.format('brew cancel snapshot: DF cancelled Brew %s x in %s d, completed %s; %d Stills, %d brew jobs in them%s; empty barrels %d (free %d, forbidden %d, in a job %d [hauling %d], trader %d, far %d, other %d, outside %d), empty pots %d (free %d); plants %s, fruit %s; nearest free %s; free empties with container flag %d / without %d; free flag combos %s; free refs %s; flag set + nothing inside %d vs clear %d; age old %d (set %d) / new %d (set %d); wear>0 %d; specific refs on %d items; taken by DF now: %d barrels, combos %s, refs %s; accumulator %s',
    tostring(s.cancels or '?'), tostring(s.days or '?'), tostring(s.done == nil and '?' or s.done), s.stills or 0, s.brewjobs or 0,
    s.still and string.format(' (Still %d at %d,%d,%d%s)', s.still.id, s.still.x, s.still.y, s.still.z, s.still.named and ', holds a brew job' or ', first') or '',
    b.empty, b.free, b.forb, b.job, b.haul, b.trader, b.far, b.other, b.out, p.empty, p.free,
    tostring(s.inv.brew_p or '?'), tostring(s.inv.brew_g or '?'),
    s.near and string.format('%s at %d,%d,%d dist %d dz %d', s.near.kind, s.near.x, s.near.y, s.near.z, s.near.d, s.near.dz) or 'none',
    s.cen.free_set, s.cen.free_clear, hist_text(s.cen.free), hist_text(s.cen.refs_free),
    s.cen.free_set, s.cen.free_clear, s.cen.old or 0, s.cen.old_set or 0, s.cen.new or 0, s.cen.new_set or 0, s.cen.wear_free or 0, s.cen.spec_items or 0,
    s.taken_n or 0, hist_text(s.taken_combo), hist_text(s.taken_refs),
    (s.acc and (s.acc.n or 0) > 0) and string.format('%d barrels combos %s refs %s', s.acc.n, hist_text(s.acc.combo), hist_text(s.acc.refs)) or 'EMPTY (undecided)')
end

-- the event text (the event layer cuts at 200 characters): a short headline that keeps its pointer to the full block
B.HEAD_MAX = 199
B.POINTER = 'full block: why brew --raw (first page)'
function B.headline(s)
  local ms = B.moment_stats(s.acc)
  local parts = {string.format('brew cancels %s/%sd', tostring(s.cancels or '?'), tostring(s.days or '?')),
                 string.format('free empties %d', s.free_all or ((s.e.barrel.free or 0) + (s.e.pot.free or 0))),
                 string.format('taken-acc %d', s.acc and s.acc.n or 0)}
  if s.vec then
    parts[#parts + 1] = string.format('vec%d %s free %d/%d taken %d/%d%s', s.vec.vid, s.vec.name, s.vec.free_in, s.vec.free_n, s.vec.taken_in, s.vec.taken_n, s.vec.src:find('^GUESS') and ' (guess)' or '')
  else
    parts[#parts + 1] = 'vec ?'
  end
  parts[#parts + 1] = 'jobs@cancel med ' .. (median(ms.j) and tostring(median(ms.j)) or '?')
  local tail = ' | ' .. B.POINTER
  local head = table.concat(parts, ', ')
  if #head + #tail > B.HEAD_MAX then head = head:sub(1, B.HEAD_MAX - #tail) end
  return head .. tail
end

-- the event fields (JSON-able, nil dropped)
function B.fields(s)
  local b, p = s.e.barrel, s.e.pot
  local f = {stills = s.stills or 0, jobs = s.brewjobs or 0, empties = b.empty, free = b.free, forb = b.forb, job = b.job, haul = b.haul, trader = b.trader,
             far = b.far, other = b.other, out = b.out, pots = p.empty, pots_free = p.free, cancels = s.cancels, done = s.done,
             plants = s.inv.brew_p, fruit = s.inv.brew_g}
  f.fcs, f.fcc = s.cen.free_set, s.cen.free_clear
  f.acs, f.acc = s.cen.all_set, s.cen.all_clear
  f.combo = hist_text(s.cen.free):sub(1, 200)
  f.combo_all = hist_text(s.cen.all):sub(1, 200)
  f.refs = hist_text(s.cen.refs_free):sub(1, 120)
  f.refs_all = hist_text(s.cen.refs_all):sub(1, 120)
  f.taken = #s.taken > 0 and table.concat(s.taken, ' / '):sub(1, 200) or 'none'
  f.tn, f.tcombo, f.trefs = s.taken_n or 0, hist_text(s.taken_combo):sub(1, 200), hist_text(s.taken_refs):sub(1, 120)
  f.rcnt = counts_text(s.cen.rc_free):sub(1, 120)
  f.spec, f.spect, f.wearf = s.cen.spec_items, s.cen.spec_total, s.cen.wear_free
  f.old, f.olds, f.new, f.news, f.med = s.cen.old, s.cen.old_set, s.cen.new, s.cen.new_set, s.cen.median
  f.bn = s.acc and s.acc.n or 0
  if s.acc and (s.acc.n or 0) > 0 then f.bcombo, f.brefs = hist_text(s.acc.combo):sub(1, 200), hist_text(s.acc.refs):sub(1, 120) end
  if s.vec then
    f.vid, f.vname, f.vsrc = s.vec.vid, s.vec.name, s.vec.src:sub(1, 60)
    f.vn, f.vfree, f.vfreen, f.vtk, f.vtkn = s.vec.n, s.vec.free_in, s.vec.free_n, s.vec.taken_in, s.vec.taken_n
  end
  f.matf, f.matt = hist_text(s.matf):sub(1, 160), hist_text(s.taken_mat):sub(1, 160)
  f.loc, f.locz, f.locb = hist_text(s.loc):sub(1, 160), hist_text(s.locz):sub(1, 120), s.locn
  local ms = B.moment_stats(s.acc)
  f.cxn = ms.n
  if ms.n > 0 then f.cxj, f.cxb, f.cxp = median(ms.j), median(ms.b), median(ms.p) end
  if s.drink then f.drinku = s.drink.u end
  if s.still then f.still = s.still.id end
  if s.near then f.near = s.near.d; f.dz = s.near.dz end
  if s.filter and s.filter[2] then f.filter = s.filter[2]:sub(1, 200) end
  return B.fit(f)
end

-- the event layer drops the whole data object when it encodes to more than 1024 bytes (and rejects a string over 200): shed the least decisive fields until it fits
B.FIELDS_MAX = 1000
B.SHED = {'combo_all', 'refs_all', 'rcnt', 'filter', 'trefs', 'brefs', 'tcombo', 'bcombo', 'taken', 'refs', 'combo', 'locz', 'matt'}
function B.fit(f)
  for k, v in pairs(f) do if type(v) == 'string' and #v > 200 then f[k] = v:sub(1, 200) end end
  local okj, json = pcall(require, 'dfllm.util.json')
  if not okj then return f end
  for _, k in ipairs(B.SHED) do
    local ok, enc = pcall(json.encode, f)
    if not ok or #enc <= B.FIELDS_MAX then break end
    f[k] = nil
  end
  return f
end

-- the block `why brew --raw` prints
function B.lines(s)
  local out = {B.line(s)}
  out[#out + 1] = string.format('  barrels: total %d empty %d free %d forbidden %d held-by-job %d (hauling/fetch %d) trader %d far %d other %d outside %d; pots: empty %d free %d forbidden %d held-by-job %d far %d',
    s.e.barrel.total, s.e.barrel.empty, s.e.barrel.free, s.e.barrel.forb, s.e.barrel.job, s.e.barrel.haul, s.e.barrel.trader, s.e.barrel.far, s.e.barrel.other, s.e.barrel.out,
    s.e.pot.empty, s.e.pot.free, s.e.pot.forb, s.e.pot.job, s.e.pot.far)
  out[#out + 1] = string.format('  flag census, free empties: container set %d, clear %d; combos %s; refs %s', s.cen.free_set, s.cen.free_clear, hist_text(s.cen.free), hist_text(s.cen.refs_free))
  out[#out + 1] = string.format('  flag census, ALL empties: container set %d, clear %d; combos %s; refs %s', s.cen.all_set, s.cen.all_clear, hist_text(s.cen.all), hist_text(s.cen.refs_all))
  out[#out + 1] = string.format('  free empties, other state: general_refs by type %s; %d items carry specific_refs (%d refs); flag set + nothing inside %d vs flag clear %d; age by id (median %s): old %d (flag set %d) / new %d (flag set %d); wear > 0 on %d',
    counts_text(s.cen.rc_free), s.cen.spec_items, s.cen.spec_total, s.cen.free_set, s.cen.free_clear, tostring(s.cen.median), s.cen.old or 0, s.cen.old_set or 0, s.cen.new or 0, s.cen.new_set or 0, s.cen.wear_free)
  if (s.taken_n or 0) == 0 then out[#out + 1] = '  no barrel attached to a brew job (job_item_idx 1) now (all Stills, all brew jobs): nothing taken to compare right now'
  else
    out[#out + 1] = string.format('  attached now: %d barrels (%d at or below the median id of the free empties); flag combos %s; refs %s', s.taken_n, s.taken_old or 0, hist_text(s.taken_combo), hist_text(s.taken_refs))
    for _, l in ipairs(s.taken) do out[#out + 1] = '  attached to a brew job: ' .. l end
    if s.taken_n > #s.taken then out[#out + 1] = string.format('  (%d more attached barrels only in the histogram)', s.taken_n - #s.taken) end
  end
  for _, l in ipairs(B.acc_lines(s.acc)) do out[#out + 1] = '  ' .. l end
  -- BUG-887 round 5
  if s.vec then
    out[#out + 1] = string.format('  in vector %d (%s; id from %s; %d items%s): free %d of %d, taken %d of %d', s.vec.vid, s.vec.name, s.vec.src, s.vec.n, s.vec.capped and ', CAPPED at ' .. B.ITEMS_MAX or '',
      s.vec.free_in, s.vec.free_n, s.vec.taken_in, s.vec.taken_n)
  else
    out[#out + 1] = '  vector membership: not measurable (no job_item vector id, none remembered, no candidate enum name)'
  end
  out[#out + 1] = string.format('  material: free empties %s; taken %s', hist_text(s.matf), hist_text(s.taken_mat))
  out[#out + 1] = string.format('  location of free empties: by pile %s; by z %s; %d lie on a tile with a building other than a stockpile (%s)', hist_text(s.loc), hist_text(s.locz), s.locn, hist_text(s.locb))
  for _, l in ipairs(B.moment_lines(s.acc)) do out[#out + 1] = '  ' .. l end
  if s.drink then
    local d = s.drink.prev_u and string.format('; %+d units since the last snapshot (tick %s), NET of drinking, not a brew count', s.drink.u - s.drink.prev_u, tostring(s.drink.prev_t)) or '; no earlier snapshot to compare'
    out[#out + 1] = string.format('  completions: not measurable (the gamelog "has been completed" count %s is per manager order, not per job). Drink stock instead: %d units in %d stacks%s', tostring(s.done == nil and '?' or s.done), s.drink.u, s.drink.n, d)
  else
    out[#out + 1] = '  completions: not measurable'
  end
  local jt = jobs_text(s)
  if jt ~= '' then out[#out + 1] = '  jobs that hold an empty: ' .. jt end
  if s.capped then out[#out + 1] = '  (scan capped at ' .. B.ITEMS_MAX .. ' items)' end
  if s.near then out[#out + 1] = string.format('  nearest free empty %s at %d,%d,%d: distance %d (x+y+z), dz %d from the Still', s.near.kind, s.near.x, s.near.y, s.near.z, s.near.d, s.near.dz) end
  if #s.filter == 0 then out[#out + 1] = '  no brew job in a Still now: no filter to show'
  else for _, l in ipairs(s.filter) do out[#out + 1] = '  brew job ' .. l end end
  return out
end

return B
