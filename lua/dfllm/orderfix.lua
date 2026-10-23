-- orderfix: B2 (BUG-060 stale orders, BUG-061 the EngraveSlab jam, FR-73 standing cloth orders). A library, not a kernel
-- module (like orderlib.lua): economy requires it. Readers of what DF holds and the pure rules; it never writes.
--   * OF.slabs: the slab census (items.other.SLAB). item_slabst has `engraving_type` (df.slab_engraving_type: Slab = -1 is
--     a blank slab, Memorial = 0) and `topic` (the historical figure of a memorial); DFHack's autoslab.cpp reads the
--     same two fields.
--   * OF.shops: the job lists of the built workshops and furnaces (building.jobs); every job names its manager order
--     (job.order_id, since 0.43.01), so "an order without a job" is a fact, not a guess.
--   * OF.engrave_split: how many EngraveSlab orders may stand (a blank slab each, at most `max`).
--   * OF.restock: how many blank slabs to order (ConstructSlab) for the ghosts and the open engrave orders.
--   * OF.simple_spec: an order that can be made again from its fields (workorder spec), or nil.
local OF = {}

OF.SLAB_SKIP = {'forbid', 'in_job', 'in_building', 'trader', 'removed', 'garbage_collect', 'dump', 'hostile',
                'construction'}

local function get(o, k)
  if o == nil then return nil end
  local ok, v = pcall(function() return o[k] end)
  if ok then return v end
end

-- the engraving_type of a blank slab (df.slab_engraving_type.Slab, -1)
function OF.blank_type()
  local t = df.slab_engraving_type
  return type(t) == 'table' and math.tointeger(t.Slab) or -1
end
function OF.memorial_type()
  local t = df.slab_engraving_type
  return type(t) == 'table' and math.tointeger(t.Memorial) or 0
end

-- {blank = free blank slabs (not forbidden, in a job, built or carried off), busy = blank slabs a running job holds
--  (its order must stay), held = the other blank slabs that are not free (built = of those, the ones standing as a
--  building: no job takes them again), memorial = engraved memorials, other =
--  engraved otherwise, n = items read, topics = {hf id = true} of the memorials}; at most `limit` items are read
function OF.slabs(limit)
  local r = {blank = 0, busy = 0, held = 0, built = 0, memorial = 0, other = 0, n = 0, topics = {}}
  local ok, vec = pcall(function() return df.global.world.items.other.SLAB end)
  if not ok or vec == nil then return r end
  local blank, mem = OF.blank_type(), OF.memorial_type()
  for _, it in ipairs(vec) do
    if r.n >= (limit or 2000) then break end
    r.n = r.n + 1
    local et = math.tointeger(get(it, 'engraving_type'))
    if et == nil or et == blank then
      local f = get(it, 'flags')
      local skip = false
      for _, k in ipairs(OF.SLAB_SKIP) do
        if get(f, k) == true then skip = true; break end
      end
      if get(f, 'in_job') == true then r.busy = r.busy + 1
      elseif skip then
        r.held = r.held + 1
        if get(f, 'in_building') == true then r.built = r.built + 1 end    -- BUG-078: a slab standing as a building
      else r.blank = r.blank + 1 end
    elseif et == mem then
      r.memorial = r.memorial + 1
      local hf = math.tointeger(get(it, 'topic'))
      if hf then r.topics[hf] = true end
    else
      r.other = r.other + 1
    end
  end
  return r
end

-- the job lists of the built workshops and furnaces:
-- {keys = {['workshop:Masons'] = {shops, jobs, working, list = {{job, order, working}}}}, by_order = {order id = n},
--  n = jobs read}; at most `limit` jobs are read (a job past it counts for nothing)
function OF.shops(built, limit)
  local r = {keys = {}, by_order = {}, n = 0}
  limit = limit or 2000
  local function one(b, key)
    if built and not built(b) then return end
    local e = r.keys[key]
    if not e then e = {shops = 0, jobs = 0, working = 0, list = {}}; r.keys[key] = e end
    e.shops = e.shops + 1
    local okj, jobs = pcall(function() return b.jobs end)
    if not okj or jobs == nil then return end
    for _, j in ipairs(jobs) do
      if r.n >= limit then return end
      r.n = r.n + 1
      local jt = get(j, 'job_type')
      local name = jt ~= nil and df.job_type and df.job_type[jt] or nil
      local oid = math.tointeger(get(j, 'order_id')) or -1
      local working = get(get(j, 'flags'), 'working') == true
      e.jobs = e.jobs + 1
      if working then e.working = e.working + 1 end
      if #e.list < 200 then e.list[#e.list + 1] = {job = tostring(name or jt), order = oid, working = working} end
      if oid >= 0 then r.by_order[oid] = (r.by_order[oid] or 0) + 1 end
    end
  end
  local w = df.workshop_type
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local n = w and w[b.type]
      if n then one(b, 'workshop:' .. n) end
    end
  end)
  local f = df.furnace_type
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.FURNACE_ANY) do
      local n = f and f[b.type]
      if n then one(b, 'furnace:' .. n) end
    end
  end)
  return r
end

-- how a shop's slots are described: "masons' slots"
local SHOP_WORDS = {Masons = "masons'", Carpenters = "carpenters'", Craftsdwarfs = "craftsdwarfs'", Farmers = "farmers'",
                    Kitchen = "kitchen's", Still = "stills'", Loom = "looms'", Clothiers = "clothiers'",
                    Leatherworks = "leatherworkers'", MetalsmithsForge = "forges'", Jewelers = "jewelers'",
                    Bowyers = "bowyers'", Mechanics = "mechanics'", Tanners = "tanners'", Butchers = "butchers'"}
function OF.shop_word(key)
  local n = tostring(key):match(':(.+)$') or tostring(key)
  return SHOP_WORDS[n] or (n .. ' shops')
end

-- the jam line of one workshop key: its jobs (e.list) whose order is blocked (blocked[order id] = true), the most
-- common jobs first; nil when fewer than `min` of them are blocked or fewer than half of the jobs
-- "masons' slots full of cancelling jobs (EngraveSlab x5: no unengraved slab)"
function OF.jam_text(key, e, blocked, why, min)
  local n, by = 0, {}
  for _, j in ipairs(e.list) do
    if blocked[j.order] then
      n = n + 1
      by[j.job] = (by[j.job] or 0) + 1
    end
  end
  if n < (min or 3) or n * 2 < e.jobs then return nil, n end
  local top, tn = nil, 0
  for job, c in pairs(by) do
    if c > tn or (c == tn and job < top) then top, tn = job, c end
  end
  local w = why and why[top]
  return string.format('%s slots full of cancelling jobs (%s x%d%s)', OF.shop_word(key), tostring(top), tn,
                       w and (': ' .. w) or ''), n
end

-- the EngraveSlab orders (ids, oldest first) that may stand: min(max, blank slabs); the rest go. A blank slab count
-- of nil (unknown) keeps `max`.
function OF.engrave_split(ids, blank, max)
  local keep = math.max(0, math.min(max or 3, blank or (max or 3)))
  local k, drop = {}, {}
  for i, id in ipairs(ids) do
    if i <= keep then k[#k + 1] = id else drop[#drop + 1] = id end
  end
  return k, drop
end

-- blank slabs to order: the ghosts and the open engrave orders want one each (at most `cap`), the stock and the open
-- ConstructSlab orders count
function OF.restock(blank, cons_left, ghosts, engrave, cap)
  local want = 0
  if (ghosts or 0) > 0 or (engrave or 0) > 0 then want = math.min(cap or 5, math.max(ghosts or 0, engrave or 0)) end
  return math.max(0, want - (blank or 0) - (cons_left or 0)), want
end

-- jobs an order can be made again for from its fields: {job name -> true}
OF.REDO_JOBS = {ConstructDoor = true, ConstructCabinet = true, ConstructChest = true, ConstructCoffin = true,
                ConstructTable = true, ConstructThrone = true, ConstructArmorStand = true, ConstructWeaponRack = true,
                ConstructHatchCover = true, ConstructGrate = true, ConstructFloodgate = true, ConstructBed = true,
                ConstructBlocks = true, ConstructSlab = true}

-- a workorder spec for an order made of nothing but its job, a material class (stone or wood) and an amount, or nil
-- (conditions, item subtypes, reactions, other materials: not made again by the kernel)
function OF.simple_spec(o, job, mc)
  if not OF.REDO_JOBS[job] then return nil end
  local left = math.tointeger(get(o, 'amount_left')) or 0
  if left <= 0 then return nil end
  local nc = get(o, 'item_conditions')
  if nc ~= nil and #nc > 0 then return nil end
  if (math.tointeger(get(o, 'item_subtype')) or -1) >= 0 then return nil end
  local rn = get(o, 'reaction_name')
  if rn ~= nil and tostring(rn) ~= '' then return nil end
  -- a stone the order names (obsidian, marble) is not "any stone": the player's choice stays, nothing is made again
  if (math.tointeger(get(o, 'mat_type')) or -1) == 0 and (math.tointeger(get(o, 'mat_index')) or -1) >= 0 then return nil end
  local spec = {job = job, amount_total = left, frequency = 'OneTime'}
  if mc == 'rock' then spec.material = 'INORGANIC'
  elseif mc == 'wood' then spec.material_category = {'wood'}
  else return nil end
  return spec
end

return OF
