-- claude/orders start|stop|once|status|list|reset - manager order system (scope wirtschaft, Run 3 Razordrums)
-- Idea: instead of direct jobs in workshops, STANDING manager orders (frequency Daily) with conditions (item_conditions:
-- "stock < cap", "wood/stone >= reserve"). The manager (office MANAGER, labors off) validates them and only creates jobs if
-- material is available -> no cancel loops, no overproduction (cap is part of the condition, applies even without this script).
-- The script creates missing orders, keeps dynamic limits current (beds = population+2, cages = 6 + occupied),
-- removes legacy orders (unconditional one-off orders from earlier arbeit.lua) and enforces the trade-goods cap.
-- Orders are recognized by signature (job/material/frequency/condition types) -> no duplicates, even after a restart.
-- NOT here: food/brewing (claude/essen, claude/trinken), iron/weapons/armor/coal (claude/material), coffins (watchdog).
-- No argument (or `once`) = run ONE round now. This default is intended and stays: the orchestrator, the watchdog and
-- the scope agents call `claude/orders` without arguments. Read-only commands are `status` and `list`; any other word prints usage and changes nothing (BUG-407).
local util = reqscript('claude/util')
if not util.require_fort() then return end
local bh = reqscript('claude/bauhelp')
local repeatUtil = require('repeat-util')
local json = require('json')
local KEY = 'claude-orders'
local INTERVAL = 1500
local STATE = reqscript('claude/util').home() .. '/state/orders.json'
local args = { ... }
local cmd = args[1] or 'once'

---------------------------------------------------------------------------------------------------------
-- State (trade-goods boost, idle history)
-- (state file state/orders.json currently unused, kept for future extensions)
local function load_state()
  local ok, t = pcall(json.decode_file, STATE)
  if ok and type(t) == 'table' then return t end
  return { boost = 0, hist = {} }
end
local function save_state(st)
  pcall(json.encode_file, st, STATE)
end

---------------------------------------------------------------------------------------------------------
-- Condition building blocks (format as in DFHack `workorder`/`orders export`)
local function C(cmp, val, item_type, extra)
  local c = { condition = cmp, value = val, item_type = item_type }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end
local STONE = { material = 'INORGANIC', flags = { 'non_economic', 'hard' } }   -- stone without ore/gems
local function stone(n) return C('AtLeast', n, 'BOULDER', STONE) end          -- stone reserve
local function wood(n) return C('AtLeast', n, 'WOOD') end                        -- wood reserve (wood gate)
local function less(n, t, fl) return C('LessThan', n, t, fl and { flags = fl } or nil) end -- cap: only produce while stock < n
local CRAFT_TYPES = { 'FIGURINE', 'AMULET', 'SCEPTER', 'CROWN', 'RING', 'EARRING', 'BRACELET' }
local function craft_caps(x)
  local t = {}
  for _, ty in ipairs(CRAFT_TYPES) do t[#t + 1] = less(x.craft_cap, ty) end
  return t
end
local function cat(list, more) for _, c in ipairs(more) do list[#list + 1] = c end return list end

---------------------------------------------------------------------------------------------------------
-- CATALOG. Each entry = 1 standing order. cond(x) returns the conditions (x = dynamic context), amt = quantity per run.
-- Order = priority (manager works the list top to bottom; new orders land at the bottom).
-- Wood gate: wood orders only from >= 20 logs (beds/barrels/buckets/cages); crafts/chests from wood only from >= 80.
local SPECS = {
  -- Basic supply (carpenter) ------------------------------------------------------------------------
  { key = 'bett', werk = 'Tischler', job = 'ConstructBed', mc = 'wood', amt = 4,
    cond = function(x) return { wood(2), less(x.beds_cap, 'BED') } end,   -- Run 5 D7: beds take priority over all wood use (36 dwarves, hardly any beds)
    text = 'Bett (Holz): Holz >= 20, freie Betten < Bevoelkerung+2-gebaute (min 2)' },
  { key = 'faesser', werk = 'Tischler', job = 'MakeBarrel', mc = 'wood', amt = 2,
    cond = function() return { wood(30), less(10, 'BARREL', { 'empty' }) } end,
    text = 'Fass (Holz): Holz >= 30, leere Faesser < 10 (trinken.lua bestellt zusaetzlich nach Bedarf)' },
  { key = 'eimer', werk = 'Tischler', job = 'MakeBucket', mc = 'wood', amt = 2,
    cond = function() return { wood(20), less(4, 'BUCKET', { 'empty' }) } end,
    text = 'Eimer (Holz): Holz >= 20, leere Eimer < 4' },
  -- Run 5 (water tunnel, no wood): metal buckets at the forge (iron); 'Give water' fails with 'Need empty bucket'. With a condition so the LEGACY purge does not delete it.
  { key = 'eimer_eisen', werk = 'Schmiede', job = 'MakeBucket', mat = 'INORGANIC:IRON', amt = 4,
    cond = function() return { less(30, 'BUCKET', { 'empty' }) } end,
    text = 'Eisen-Eimer (Schmiede): leere Eimer < 30 (Wassertunnel/Give water)' },
  { key = 'kaefig', werk = 'Tischler', job = 'MakeCage', mc = 'wood', amt = 2,
    cond = function(x) return { wood(20), less(x.cage_cap, 'CAGE', { 'empty' }) } end,
    text = 'Kaefig (Holz) fuer Kaefigfallen: Holz >= 20, leere Kaefige < 6 + belegte' },
  -- Bins/containers deliberately NOT in the catalog: the manager counted 'empty bins' differently than we do -> runaway (13 -> 25 bins in 1 min).
  { key = 'schiene', werk = 'Tischler', job = 'ConstructSplint', mc = 'wood', amt = 1,
    cond = function() return { wood(30), less(2, 'SPLINT') } end, text = 'Schiene (Hospital): Holz >= 30, < 2' },
  { key = 'kruecke', werk = 'Tischler', job = 'ConstructCrutch', mc = 'wood', amt = 1,
    cond = function() return { wood(30), less(2, 'CRUTCH') } end, text = 'Kruecke (Hospital): Holz >= 30, < 2' },
  -- Run 4 (earth fort, no stone): wooden furniture; wood gate cuts it off while < reserve (no orders without material)
  { key = 'tuer_holz', werk = 'Tischler', job = 'ConstructDoor', mc = 'wood', amt = 2,
    cond = function() return { wood(12), less(6, 'DOOR') } end, text = 'Holztuer: Holz >= 12, freie Tueren < 6' },
  { key = 'tisch_holz', werk = 'Tischler', job = 'ConstructTable', mc = 'wood', amt = 2,
    cond = function() return { wood(12), less(6, 'TABLE') } end, text = 'Holztisch: Holz >= 12, freie Tische < 6' },
  { key = 'stuhl_holz', werk = 'Tischler', job = 'ConstructThrone', mc = 'wood', amt = 2,
    cond = function() return { wood(12), less(12, 'CHAIR') } end, text = 'Holzstuhl: Holz >= 12, freie Stuehle < 12' },
  { key = 'sarg_holz', werk = 'Tischler', job = 'ConstructCoffin', mc = 'wood', amt = 1,
    cond = function() return { wood(16), less(4, 'COFFIN') } end, text = 'Holzsarg: Holz >= 16, freie Saerge < 4' },
  -- Furniture/building parts from stone (mason; stone without ore >= reserve) ---------------------------------------
  { key = 'tuer', werk = 'Steinmetz', job = 'ConstructDoor', mat = 'INORGANIC', amt = 2,
    cond = function(x) return { stone(x.sres), less(4, 'DOOR') } end, text = 'Steintuer: Stein >= 40, freie Tueren < 4' },
  { key = 'truhe', werk = 'Steinmetz', job = 'ConstructChest', mat = 'INORGANIC', amt = 2,
    cond = function(x) return { stone(x.sres), less(math.max(24, x.pop // 2), 'BOX') } end, text = 'Steintruhe: Stein >= 40, freie Truhen < 4' },
  { key = 'schrank', werk = 'Steinmetz', job = 'ConstructCabinet', mat = 'INORGANIC', amt = 2,
    cond = function(x) return { stone(x.sres), less(math.max(20, x.pop // 2), 'CABINET') } end, text = 'Steinschrank: Stein >= 40, freie Schraenke < 4' },
  { key = 'tisch', werk = 'Steinmetz', job = 'ConstructTable', mat = 'INORGANIC', amt = 2,
    cond = function(x) return { stone(x.sres), less(math.max(20, x.pop // 3), 'TABLE') } end, text = 'Steintisch: Stein >= 40, freie Tische < 8 (Bauprogramm Ostfluegel; J88 4 -> 8)' },
  { key = 'stuhl', werk = 'Steinmetz', job = 'ConstructThrone', mat = 'INORGANIC', amt = 2,
    cond = function(x) return { stone(x.sres), less(math.max(30, x.pop // 2), 'CHAIR') } end, text = 'Steinstuhl (Thron): Stein >= 40, freie Stuehle < 14 (Bauprogramm; J88 6 -> 14)' },
  { key = 'waffenregal', werk = 'Steinmetz', job = 'ConstructWeaponRack', mat = 'INORGANIC', amt = 1,
    cond = function(x) return { stone(x.sres), less(6, 'WEAPONRACK') } end, text = 'Waffenregal (Kaserne): Stein >= 40, < 2' },
  { key = 'ruestungsstaender', werk = 'Steinmetz', job = 'ConstructArmorStand', mat = 'INORGANIC', amt = 1,
    cond = function(x) return { stone(x.sres), less(6, 'ARMORSTAND') } end, text = 'Ruestungsstaender (Kaserne): Stein >= 40, < 2' },
  { key = 'luke', werk = 'Steinmetz', job = 'ConstructHatchCover', mat = 'INORGANIC', amt = 1,
    cond = function(x) return { stone(x.sres), less(2, 'HATCH_COVER') } end, text = 'Luke: Stein >= 40, < 2' },
  { key = 'gitter', werk = 'Steinmetz', job = 'ConstructGrate', mat = 'INORGANIC', amt = 1,
    cond = function(x) return { stone(x.sres), less(2, 'GRATE') } end, text = 'Gitter: Stein >= 40, < 2' },
  { key = 'schleuse', werk = 'Steinmetz', job = 'ConstructFloodgate', mat = 'INORGANIC', amt = 1,
    cond = function(x) return { stone(x.sres), less(2, 'FLOODGATE') } end, text = 'Schleuse: Stein >= 40, < 2' },
  { key = 'platte', werk = 'Steinmetz', job = 'ConstructSlab', mat = 'INORGANIC', amt = 1,
    cond = function(x) return { stone(x.sres), less(2, 'SLAB') } end, text = 'Steinplatte (Gedenken): Stein >= 40, < 2' },
  { key = 'bloecke', werk = 'Steinmetz', job = 'ConstructBlocks', mat = 'INORGANIC', amt = 4,
    cond = function(x) return { stone(x.sres + 20), less(400, 'BLOCKS') } end, text = 'Steinbloecke: Stein >= 60, Bloecke < 120 (Bauprogramm: Mauern/Strassen/Werkstaetten; J88 40 -> 120)' },
  -- Run 5 D12 (155 citizens, ~100 idle): statues as a stone sink for masons (room value/wealth), cap 60; only with a large stone reserve
  { key = 'statue', werk = 'Steinmetz', job = 'ConstructStatue', mat = 'INORGANIC', amt = 2, maxws = 2,
    cond = function(x) return { stone(x.sres + 60), less(60, 'STATUE') } end, text = 'Statue: Stein >= Reserve+60, Statuen < 60' },
  -- Mechanic (traps) -------------------------------------------------------------------------------
  { key = 'mechanismen', werk = 'Mechaniker', job = 'ConstructMechanisms', mat = 'INORGANIC', amt = 3,
    cond = function(x) return { stone(x.sres), less(60, 'TRAPPARTS') } end, text = 'Mechanismen (Fallen/Hebel): Stein >= 30, < 30' },
  -- Crafts / trade goods (crafters): cap per kind = craft_cap (100) -----------
  { key = 'krims_stein', werk = 'Handwerker', job = 'MakeCrafts', mat = 'INORGANIC', amt = 8, maxws = 3,
    cond = function(x) return cat({ stone(math.max(6, x.sres - 2)) }, craft_caps(x)) end,   -- Run 5 D3: trade goods before the first caravan, gate 18 -> 8
    text = 'Steinkrims (Ringe/Amulette/Figuren ...): Stein >= 60, jede Sorte < Deckel' },
  { key = 'krims_knochen', werk = 'Handwerker', job = 'MakeCrafts', mc = 'bone', amt = 3, maxws = 2,
    cond = function(x) return cat({ C('AtLeast', 3, nil, { flags = { 'bone', 'body_part' } }) }, craft_caps(x)) end,
    text = 'Knochenkrims (Knochenschnitzer): >= 3 freie Knochen aus Schlachtabfall, jede Sorte < Deckel' },
  { key = 'krims_holz', werk = 'Handwerker', job = 'MakeCrafts', mc = 'wood', amt = 3, maxws = 1,
    cond = function(x) return cat({ wood(80) }, craft_caps(x)) end,
    text = 'Holzkrims: Holz >= 80 (Betten/Faesser gehen vor), jede Sorte < Deckel' },
  { key = 'becher', werk = 'Handwerker', job = 'MakeGoblet', mat = 'INORGANIC', amt = 3,
    -- D13: 406 loose mugs lying around (storage full) -> cap 60
    cond = function(x) return { stone(x.sres), less(60, 'GOBLET') } end,
    text = 'Steinbecher (Trinken aus Bechern, Stimmung; 1 je Buerger, Ziel 80 Buerger): < 60' },
  -- (D3: seide_weben removed - the 'silk thread' is cavern spider-web items, 'Needs 1 unused collected silk thread' cancellations; silk only via trade)
  -- Run 5 (desert, no wood): stone pot (large pot) as container for brewing/storage instead of barrel; cap on pot stock
  { key = 'topf', werk = 'Handwerker', job = 'MakeTool', sub = 'ITEM_TOOL_LARGE_POT', mat = 'INORGANIC', amt = 2,
    cond = function(x) return { stone(x.sres), C('LessThan', 60, 'TOOL', { item_subtype = 'ITEM_TOOL_LARGE_POT' }) } end,
    text = 'Grosser Steintopf (Behaelter Brauen/Lager; kein Holz): Stein >= Reserve, Toepfe < 16' },
  -- Run 5 D10: metal crafts (bronze, Mafol METALCRAFT 10) = high-value trade goods; bronze bar reserve 10 stays for weapons/tools
  { key = 'krims_bronze', werk = 'Handwerker', job = 'MakeCrafts', mat = 'INORGANIC:BRONZE', amt = 4, maxws = 2,
    cond = function(x) return cat({ C('AtLeast', 14, 'BAR', { material = 'INORGANIC:BRONZE' }) }, craft_caps(x)) end,
    text = 'Bronzekrims: Bronzebarren >= 14, jede Sorte < Deckel' },
  -- Jeweler: cutting (grinding raw gems: direct job in arbeit.lua 'cut gems', because the manager demands a gem material) -------
  { key = 'edelsteinfassung', werk = 'Juwelier', job = 'EncrustWithGems', item_category = { 'finished_goods' }, amt = 4,
    cond = function() return { C('AtLeast', 40, 'SMALLGEM') } end,
    text = 'Fertigwaren mit geschliffenen Gems besetzen: Schwelle 40 (J87: 63 Abbrueche Needs gem cut gems - SMALLGEM zaehlt Erz-/Glas-Schliffe mit, die der Job nicht nimmt; erst mit echten Edelsteinen senken)' },
}

-- Emergency brake (runaway protection): the manager counts stock by its own rule (e.g. 'empty', container contents) and deviates from our count
-- (bins: 13 -> 25 in 1 min despite cap). WATCH = { catalog key = {item type, cap} }: if the order is ACTIVE and the real stock
-- (all items of the type except in buildings/removed/trade) >= 1.3 x cap + 2, the order is deleted (and only recreated once stock < cap).
local WATCH = {
  platte = { 'SLAB', 2 }, schiene = { 'SPLINT', 2 }, kruecke = { 'CRUTCH', 2 }, becher = { 'GOBLET', 60 },
  luke = { 'HATCH_COVER', 2 }, gitter = { 'GRATE', 2 }, schleuse = { 'FLOODGATE', 2 }, waffenregal = { 'WEAPONRACK', 6 },
  ruestungsstaender = { 'ARMORSTAND', 6 }, tisch = { 'TABLE', 40 }, stuhl = { 'CHAIR', 60 }, schrank = { 'CABINET', 60 }, truhe = { 'BOX', 60 },
  tuer = { 'DOOR', 4 }, bloecke = { 'BLOCKS', 400 }, mechanismen = { 'TRAPPARTS', 60 }, statue = { 'STATUE', 60 }, bett = { 'BED', 12 },
}
local function real_count(t)
  local n = 0
  for _, it in ipairs(df.global.world.items.other[t] or {}) do
    local f = it.flags
    if not (f.in_building or f.removed or f.trader or f.garbage_collect) then n = n + it:getStackSize() end
  end
  return n
end
local function runaway(key)
  local w = WATCH[key]
  if not w then return false end
  return real_count(w[1]) >= math.floor(1.3 * w[2]) + 2, real_count(w[1])
end

---------------------------------------------------------------------------------------------------------
-- Context (dynamic limits)
local function context(st)
  local x = { pop = 0, beds_built = 0, cages_occ = 0 }
  for _, u in ipairs(dfhack.units.getCitizens()) do x.pop = x.pop + 1 end
  for _, it in ipairs(df.global.world.items.other.BED) do
    if it.flags.in_building then x.beds_built = x.beds_built + 1 end
  end
  for _, it in ipairs(df.global.world.items.other.CAGE) do
    if not it.flags.in_building and not it.flags.removed then
      for _, r in ipairs(it.general_refs) do
        if df.general_ref_contains_unitst:is_instance(r) then x.cages_occ = x.cages_occ + 1 break end
      end
    end
  end
  x.beds_cap = math.max(2, math.min(16, x.pop + 2 - x.beds_built))
  x.cage_cap = 6 + x.cages_occ
  -- Run 5 (desert, 7 dwarves): stone reserve low early (furniture/crafts as occupation), grows with population (walls/workshops need boulders)
  x.sres = (x.pop <= 12) and 10 or ((x.pop <= 25) and 25 or 40)
  x.craft_cap = 450 -- cap per kind; NOTE: the manager also counts pieces in containers/storage (really ~1.5-2x more than loose items)
  return x
end

-- J88: reachable wood (cavern logs behind the sealed shaft D barrier count for the manager -> 'Make bed: Needs logs' 283x,
-- 'Make charcoal' 1120x cancellations). Wood orders (mc = wood) exist only while reachable wood >= their wood reserve.
local function wood_reachable_total()
  local n = 0
  for _, it in ipairs(df.global.world.items.other.WOOD) do
    local f = it.flags
    if not (f.in_building or f.removed or f.trader or f.garbage_collect or f.forbid or f.in_inventory) and bh.item_reachable(it) then n = n + it:getStackSize() end
  end
  return n
end

-- Adult civilians without a job (excluding offices/squad)
local function idle_workers()
  local n, names = 0, {}
  for _, u in ipairs(dfhack.units.getCitizens()) do
    if dfhack.units.isAdult(u) and u.military.squad_id < 0 and not u.job.current_job then
      local office = false
      for _, p in ipairs(dfhack.units.getNoblePositions(u) or {}) do
        local c = p.position.code
        if c == 'MANAGER' or c == 'BOOKKEEPER' or c == 'BROKER' then office = true end
      end
      if not office then n = n + 1; names[#names + 1] = dfhack.units.getReadableName(u):match('^(%S+)') end
    end
  end
  return n, names
end

---------------------------------------------------------------------------------------------------------
-- Signature (order <-> catalog entry)
local function flaglist(f)
  local t = {}
  for k, v in pairs(f) do if v == true then t[#t + 1] = tostring(k) end end
  table.sort(t)
  return table.concat(t, '+')
end

-- flags1..3 of an item condition as one '+' list (concatenating the three lists glued names together,
-- e.g. 'non_economichard', and let different flag combinations share a signature, BUG-422)
local function condflags(c)
  local t = {}
  for _, f in ipairs({ flaglist(c.flags1), flaglist(c.flags2), flaglist(c.flags3) }) do if f ~= '' then t[#t + 1] = f end end
  return table.concat(t, '+')
end

local function order_sig(o)
  local ct = {}
  for _, c in ipairs(o.item_conditions) do ct[#ct + 1] = (df.item_type[c.item_type] or '-') .. ':' .. condflags(c) end
  table.sort(ct)
  return table.concat({ df.job_type[o.job_type], tostring(o.item_subtype), o.reaction_name, tostring(o.mat_type), tostring(o.mat_index),
    flaglist(o.material_category), flaglist(o.specflag.encrust_flags), tostring(o.frequency), tostring(#o.item_conditions) .. '#' .. table.concat(ct, ',') }, '|')
end

-- Spec -> JSON table for workorder + signature via a created test object
local function spec_json(sp, x)
  local j = { job = sp.job, amount_total = sp.amt, frequency = 'Daily', item_conditions = sp.cond(x) }
  if sp.mat then j.material = sp.mat end
  if sp.mc then j.material_category = { sp.mc } end
  if sp.item_category then j.item_category = sp.item_category end
  if sp.maxws then j.max_workshops = sp.maxws end
  if sp.sub then j.item_subtype = sp.sub end
  return j
end

local wo
local function workorder()
  if not wo then wo = reqscript('workorder') end
  return wo
end

local function create(sp, x)
  local mo = df.global.world.manager_orders
  local list = workorder().preprocess_orders(spec_json(sp, x))
  workorder().fillin_defaults(list)
  local before = #mo.all
  workorder().create_orders(list, true)
  if #mo.all > before then return mo.all[#mo.all - 1] end
end

local function erase_order(o)
  local mo = df.global.world.manager_orders
  for i = 0, #mo.all - 1 do
    if mo.all[i] == o then mo.all:erase(i); o:delete(); return true end
  end
end

local sigcache = {}
local function get_sigs(x)
  -- Signature per catalog entry: determine once via a test order (test order is deleted immediately), afterwards from the cache
  local sigs = {}
  for _, sp in ipairs(SPECS) do
    if not sigcache[sp.key] then
      local ok, o = pcall(create, sp, x)
      if ok and o then sigcache[sp.key] = order_sig(o); erase_order(o) end
    end
    sigs[sp.key] = sigcache[sp.key]
  end
  return sigs
end

-- Update condition values in an existing order (dynamic limits), have the order re-evaluated on change
local function update_conditions(o, sp, x)
  local want = sp.cond(x)
  local ch = 0
  for i, c in ipairs(want) do
    local oc = o.item_conditions[i - 1]
    if oc and oc.compare_val ~= c.value then oc.compare_val = c.value; ch = ch + 1 end
  end
  if sp.maxws and o.max_workshops ~= sp.maxws then o.max_workshops = sp.maxws; ch = ch + 1 end
  return ch
end

---------------------------------------------------------------------------------------------------------
local LEGACY_JOBS = { MakeCrafts = true, ConstructBed = true, MakeBucket = true }
local PURGE_JOBS = { WeaveCloth = true }
local PURGE_IRONBED = true   -- D11: delete iron bed order (mat IRON)   -- Run 5 D3: no statues

local function sync()
  local st = load_state()
  local x = context(st)
  local mo = df.global.world.manager_orders
  local res = { created = {}, removed = {}, updated = 0 }
  local idle, names = idle_workers()
  x = context(st)
  local sigs = get_sigs(x)
  -- Stock
  local bysig = {}
  for i = 0, #mo.all - 1 do
    local o = mo.all[i]
    local s = order_sig(o)
    bysig[s] = bysig[s] or {}
    table.insert(bysig[s], o)
  end
  local known = {}
  local wood_have = wood_reachable_total()
  res.wood_reachable = wood_have
  for _, sp in ipairs(SPECS) do
    local sig = sigs[sp.key]
    if sig then
      known[sig] = true
      local have = bysig[sig] or {}
      local run = runaway(sp.key)
      local nowood = false
      if sp.mc == 'wood' then
        local c1 = sp.cond(x)[1]
        if wood_have < (c1 and c1.value or 1) then nowood = true end
      end
      if nowood then
        for _, o in ipairs(have) do if erase_order(o) then res.removed[#res.removed + 1] = sp.key .. '(kein erreichbares Holz)' end end
      elseif #have == 0 then
        if not run then
          local ok, o = pcall(create, sp, x)
          if ok and o then res.created[#res.created + 1] = sp.key end
        end
      elseif run and have[1].status.active then
        if erase_order(have[1]) then res.removed[#res.removed + 1] = sp.key .. '(runaway)' end
      else
        res.updated = res.updated + update_conditions(have[1], sp, x)
        for k = 2, #have do if erase_order(have[k]) then res.removed[#res.removed + 1] = sp.key .. '(doppelt)' end end
      end
    end
  end
  -- Legacy: unconditional one-off orders from earlier arbeit.lua (crafts/bed/bucket)
  local snapshot = {}
  for i = 0, #mo.all - 1 do snapshot[#snapshot + 1] = mo.all[i] end
  for _, o in ipairs(snapshot) do
    if LEGACY_JOBS[df.job_type[o.job_type]] and #o.item_conditions == 0 and o.frequency == df.workquota_frequency_type.OneTime
       and not known[order_sig(o)] then
      if erase_order(o) then res.removed[#res.removed + 1] = df.job_type[o.job_type] .. '(alt)' end
    end
  end
  for _, o in ipairs(snapshot) do
    if PURGE_IRONBED and df.job_type[o.job_type] == 'ConstructBed' and o.mat_type == 0 and o.mat_index >= 0 and #o.material_category == 0 and erase_order(o) then res.removed[#res.removed + 1] = 'bett_eisen(purge)' end
    if PURGE_JOBS[df.job_type[o.job_type]] and erase_order(o) then res.removed[#res.removed + 1] = df.job_type[o.job_type] .. '(purge)' end
  end
  save_state(st)
  res.orders = #mo.all
  res.idle = idle
  res.idle_names = names
  res.craft_cap = x.craft_cap
  res.beds_cap = x.beds_cap
  res.cage_cap = x.cage_cap
  return res
end

---------------------------------------------------------------------------------------------------------
local function cond_text(o)
  local t = {}
  for _, c in ipairs(o.item_conditions) do
    local f = condflags(c)
    t[#t + 1] = string.format('%s %d %s%s', df.logic_condition_type[c.compare_type], c.compare_val, df.item_type[c.item_type] or '*', f ~= '' and ('[' .. f .. ']') or '')
  end
  return table.concat(t, '; ')
end

local function status()
  local st = load_state()
  local x = context(st)
  local mo = df.global.world.manager_orders
  local sigkey = {}
  for k, sg in pairs(get_sigs(x)) do sigkey[sg] = k end
  local rows = {}
  local jobs_by_order = {}
  for i = 0, #mo.all - 1 do
    local o = mo.all[i]
    local mat = o.material_category and flaglist(o.material_category) or ''
    if mat == '' and o.mat_type >= 0 and o.mat_index == -1 and o.mat_type == 0 then mat = 'INORGANIC' end
    rows[#rows + 1] = { id = o.id, job = df.job_type[o.job_type] .. (o.reaction_name ~= '' and (':' .. o.reaction_name) or ''), mat = mat,
      links = o.amount_left .. '/' .. o.amount_total, validiert = o.status.validated, aktiv = o.status.active,
      freq = df.workquota_frequency_type[o.frequency], eigen = sigkey[order_sig(o)] or 'fremd', bed = cond_text(o) }
    local k = sigkey[order_sig(o)]
    if k and WATCH[k] then rows[#rows].bestand = real_count(WATCH[k][1]) .. '/' .. WATCH[k][2] end
  end
  local idle, names = idle_workers()
  return { orders = #mo.all, katalog = #SPECS, craft_cap = x.craft_cap, beds_cap = x.beds_cap, cage_cap = x.cage_cap,
    pop = x.pop, beds_built = x.beds_built, idle_zivilisten = idle, idle_namen = names, liste = rows }
end

local function reset()
  -- removes all OWN catalog orders (foreign ones stay)
  local st = load_state()
  local x = context(st)
  local mo = df.global.world.manager_orders
  local sigs = {}
  for _, sg in pairs(get_sigs(x)) do sigs[sg] = true end
  local n = 0
  local del = {}
  for i = 0, #mo.all - 1 do if sigs[order_sig(mo.all[i])] then del[#del + 1] = mo.all[i] end end
  for _, o in ipairs(del) do if erase_order(o) then n = n + 1 end end
  return { entfernt = n }
end

---------------------------------------------------------------------------------------------------------
if cmd == 'start' then
  repeatUtil.scheduleEvery(KEY, INTERVAL, 'ticks', function() pcall(sync) end)
  local ok, r = pcall(sync)
  util.emit({ running = true, interval = INTERVAL, ok = ok, result = ok and r or tostring(r) })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'status' or cmd == 'list' then
  local ok, r = pcall(status)
  util.emit(ok and r or { error = tostring(r) })
elseif cmd == 'reset' then
  util.emit(reset())
elseif cmd == 'once' then
  local ok, r = pcall(sync)
  util.emit(ok and r or { error = tostring(r) })
else
  -- unknown sub-command (typo, --help, 'status' of a script without one): usage only, no work round (BUG-407)
  util.emit({ error = 'unbekannter Befehl: ' .. tostring(cmd), usage = 'claude/orders start|stop|once|status|list|reset' })
end
