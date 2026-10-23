-- reserve (WP8): the mood-material library care requires. Not a kernel module (contract.MODULES does not
-- list it, kern never loads it): pure functions over read-only DF objects and the config section
-- config/baseline.json "reserve". care owns every write (K.act.item_flag), event and persist record.
--   * mood needs: Gordon's decision (orchestrator, 2026-10-11, v1 precedent) lets care read the item
--     requirements of a strange-mood job (job.job_items), as a player learns them from the claimed workshop,
--     the job and the dwarf's searching. Only StrangeMood* jobs are read (R.is_mood_job); the job is never
--     edited. R.job_needs turns the filters into needs {cls, n, label, ...}; R.match tests an item;
--   * the reserve: per class a number of stored items care keeps forbidden (the item sheet's forbid toggle,
--     as a player forbids a mood stash), so no order or building consumes them; care unforbids them the
--     moment a mood needs them. R.hold says how many to hold now (critical supply first);
--   * acquisition paths per class (R.ACQ) and trade tokens (R.token) for the hooks other modules read.
local R = {}

-- mirror of config/baseline.json "reserve" (tests/lua/test_reserve.lua checks they agree)
R.DEFAULTS = {
  from_phase = 'P1',               -- the moodable workshops are a P1 deliverable; before it the fort builds stage 1
  share = {boulders = 0.25, logs = 0.25}, share_min = 5,   -- bulk classes: at most this share of the stock
  targets = {boulders = 20, logs = 20, bone = 10, shell = 2, leather = 10, cloth = 10, thread = 10, gems = 5,
             bars = 5},
  smelter = {'bars'},              -- classes held only while the fort has a built smelter
  pile = 'dfllm-reserve',          -- a stockpile of this name is taken first, then every other stockpile
  per_run = 20,                    -- reserve forbid / release writes per care run
  barrels_min = 4,                 -- logs for the empty barrels missing below this stay free (drink first)
  wake_ticks = 2400,               -- a mood need unresolved for 2 game days wakes the LLM (DECISION_NEEDED)
  rewake_ticks = 8400,             -- and again each week while it stays unresolved
  butcher_every = 3600,            -- `autobutcher now` at most every 3 days for a bone, shell or leather need
}

R.CLASSES = {'boulders', 'logs', 'bone', 'shell', 'leather', 'cloth', 'thread', 'gems', 'bars'}
-- items.other vectors per class (glass = raw glass, ROUGH items of a glass material)
R.VECS = {boulders = {'BOULDER'}, logs = {'WOOD'}, bone = {'CORPSEPIECE'}, shell = {'CORPSEPIECE'},
          leather = {'SKIN_TANNED'}, cloth = {'CLOTH'}, thread = {'THREAD'}, gems = {'SMALLGEM', 'ROUGH'},
          bars = {'BAR'}, glass = {'ROUGH'}}
-- the workshop classes of care.WS_MATS (used when a mood job's filters cannot be read) -> vector, class
R.LEGACY_VEC = {bone = 'CORPSEPIECE', shell = 'CORPSEPIECE', rock = 'BOULDER', wood = 'WOOD', rough = 'ROUGH',
                gems = 'SMALLGEM', bars = 'BAR', leather = 'SKIN_TANNED', cloth = 'CLOTH', thread = 'THREAD'}
R.LEGACY_CLS = {bone = 'bone', shell = 'shell', rock = 'boulders', wood = 'logs', rough = 'gems', gems = 'gems',
                bars = 'bars', leather = 'leather', cloth = 'cloth', thread = 'thread'}
-- how a missing class is acquired: what care starts itself (butcher, PROJECT_REQUEST dig) and what the hooks
-- read through care.mood_wants (economy: hunt, chop, order:<df.job_type>; trade: buy, with the entry's token)
R.ACQ = {bone = {'butcher', 'hunt'}, shell = {'butcher', 'hunt'}, leather = {'butcher', 'hunt', 'order:TAN_A_HIDE'},
         boulders = {'dig'}, logs = {'chop'}, cloth = {'order:WeaveCloth', 'buy'}, thread = {'order:SpinThread', 'buy'},
         gems = {'order:CutGems', 'buy'}, glass = {'order:MakeRawGlass'}, bars = {'order:SmeltOre', 'buy'}}
-- trade.lua token kinds (L.KINDS) per class
R.BUY = {cloth = 'cloth', thread = 'thread', leather = 'leather', gems = 'gem', bars = 'bar', boulders = 'stone',
         logs = 'wood'}
-- what the LLM can do about a class (DECISION_NEEDED q)
R.HINT = {boulders = 'dig stone (bp.place bedrooms prio=1)', logs = 'cut trees', bone = 'butcher/hunt',
          shell = 'butcher/hunt/fish', leather = 'butcher+tan or trade.want leather', cloth = 'trade.want cloth',
          thread = 'trade.want thread', gems = 'trade.want gem', glass = 'glass furnace: sand+fuel',
          bars = 'smelt ore or trade.want bar', other = 'trade.want'}
-- dimension units per item in a mood filter's quantity (DFHack strangemood: bars x150, cloth x10000)
R.DIM = {BAR = 150, CLOTH = 10000, THREAD = 15000}
local GLASS = {[3] = true, [4] = true, [5] = true}       -- df.builtin_mats GLASS_GREEN, GLASS_CLEAR, GLASS_CRYSTAL
local SUBFLAG = {silk = 'SILK', plant = 'THREAD_PLANT', yarn = 'YARN'}   -- material flags of cloth / thread kinds
-- item flags that make an item unusable for a mood or the reserve (claimed, built in, gone, foreign, an
-- uncollected cavern web) (idle-crafting.lua cloth_categories_in_play uses the same set; contained items carry
-- in_inventory). All are df.item_flags names of 53.16 (scripts/forbid.lua, autodump.lua, combine.lua read them).
R.BUSY = {'in_building', 'in_job', 'trader', 'removed', 'garbage_collect', 'construction', 'hostile', 'artifact',
          'on_fire', 'rotten', 'owned', 'encased', 'hidden', 'spider_web'}

-- K3 (BUG-100): of R.BUSY the flags that take an item out of the fort's stock altogether (built in, gone, foreign, a
-- web). The others (in_job, owned, artifact, on_fire, rotten) leave it in the fort but not free: a mood report counts
-- the two apart (in the fort / free / reachable)
R.GONE = {'in_building', 'trader', 'removed', 'garbage_collect', 'construction', 'hostile', 'encased', 'hidden',
          'spider_web'}

local function int(v) return math.type(v) == 'integer' and v or (type(v) == 'number' and math.tointeger(v)) or nil end

-- a field that may not exist (DFHack raises on unknown names); no closure per call: matching runs per item
local function index(o, k) return o[k] end
local function get(o, k)
  if o == nil then return nil end
  local ok, v = pcall(index, o, k)
  if ok then return v end
end

local function bit(fl, k)
  local v = get(fl, k)
  return v == true
end

local function item_type(it) return df.item_type[it:getType()] end
local function tname_of(it)
  local ok, t = pcall(item_type, it)
  return ok and t or nil
end
R.tname = tname_of

-- direct flag reads (every name exists in df.item_flags): this runs for every item of a scanned vector, and
-- a pcall per flag cost about 13 closures per item; the callers' scan pcall catches a broken item
function R.busy(it)
  local f, B = it.flags, R.BUSY
  for i = 1, #B do if f[B[i]] then return true end end
  return false
end

function R.gone(it)
  local f, B = it.flags, R.GONE
  for i = 1, #B do if f[B[i]] then return true end end
  return false
end

-- an item a unit carries or wears is nobody's stock; an item in a bin or bag is fine unless the container is
-- claimed (hauled) itself
function R.carried(it)
  if not get(it.flags, 'in_inventory') then return false end
  local ok, cont = pcall(function() return dfhack.items.getContainer(it) end)   -- Lua API.txt:2035
  if not (ok and cont) then return true end
  return R.busy(cont)
end

-- economic stone (the stone-use screen, plotinfo.economic_stone[index], a byte vector: gui/advfort.lua:70
-- writes 0); unknown -> not economic
function R.economic(it)
  local ok, v = pcall(function() return df.global.plotinfo.economic_stone[it.mat_index] end)
  return ok and (v == true or (type(v) == 'number' and v ~= 0))
end

---------------------------------------------------------------- the strange-mood job
function R.is_mood_job(job)
  local ok, n = pcall(function() return df.job_type[job.job_type] end)
  return ok and type(n) == 'string' and n:sub(1, 11) == 'StrangeMood'
end

local function mat_name(mt, mi)
  if (mt or -1) < 0 then return nil end
  local ok, tok = pcall(function() return dfhack.matinfo.decode(mt, mi):getToken() end)
  if not ok or type(tok) ~= 'string' then return nil end
  return (tok:match('([^:]+)$') or tok):lower()
end

-- class, vectors, corpse part and cloth kind of a mood filter
local function classify(tname, mt, f2)
  local sub = (bit(f2, 'silk') and 'silk') or (bit(f2, 'plant') and 'plant') or
              ((bit(f2, 'yarn') or bit(f2, 'hair_wool')) and 'yarn') or nil
  if tname == 'BOULDER' then return 'boulders', R.VECS.boulders
  elseif tname == 'WOOD' then return 'logs', R.VECS.logs
  elseif tname == 'BAR' then return 'bars', R.VECS.bars
  elseif tname == 'SMALLGEM' then return 'gems', {'SMALLGEM'}
  elseif tname == 'ROUGH' then return (GLASS[mt] and 'glass' or 'gems'), {'ROUGH'}
  elseif tname == 'CLOTH' then return 'cloth', R.VECS.cloth, nil, sub
  elseif tname == 'THREAD' then return 'thread', R.VECS.thread, nil, sub
  elseif tname == 'SKIN_TANNED' then return 'leather', R.VECS.leather
  end
  -- body parts: item type NONE with flags2 bone/shell/horn + body_part (idle-crafting.lua makeBoneCraft); the
  -- butchered pieces carry corpse_flags bone/shell/horn/tooth (idle-crafting.lua categorize_craft)
  local corpse = tname == nil or tname == 'NONE' or tname == 'CORPSEPIECE' or tname == 'CORPSE'
  if corpse and bit(f2, 'shell') then return 'shell', {'CORPSEPIECE'}, 'shell' end
  if corpse and bit(f2, 'bone') then return 'bone', {'CORPSEPIECE'}, 'bone' end
  if corpse and bit(f2, 'horn') then return 'bone', {'CORPSEPIECE'}, 'horn' end
  if corpse and bit(f2, 'ivory_tooth') then return 'bone', {'CORPSEPIECE'}, 'tooth' end
  -- a pearl needs a pearl (corpse_flags.pearl): counting any bone for it would hide a missing material
  if corpse and bit(f2, 'pearl') then return 'bone', {'CORPSEPIECE'}, 'pearl' end
  if corpse and bit(f2, 'body_part') then return 'bone', {'CORPSEPIECE'}, 'part' end
  if tname and tname ~= 'NONE' then return 'other', {tname} end
  return 'other', {}
end

-- 'bars x2 (iron)', 'cloth(silk) x1', 'bone x3'; n overrides the count
function R.label(nd, n)
  local base = nd.cls
  if nd.cls == 'other' then base = (nd.tname or 'item'):lower() end
  if nd.part == 'part' then base = 'body part' elseif nd.part == 'horn' then base = 'horn'
  elseif nd.part == 'tooth' then base = 'ivory' elseif nd.part == 'pearl' then base = 'pearl' end
  if nd.sub then base = base .. '(' .. nd.sub .. ')' end
  local s = string.format('%s x%d', base, n or nd.n)
  local m = mat_name(nd.mat_type, nd.mat_index)
  if m and nd.cls ~= 'bone' and nd.cls ~= 'shell' then s = s .. ' (' .. m .. ')' end
  return s:sub(1, 60)
end

-- K3 (BUG-100): the filter of one job_item in a few words, e.g. 'metal', 'iron', 'plant', 'non_economic'. The cloth kind
-- and a named material first, then the flags a player reads on the job's item list (job_item flags1..3, the material
-- category bits, an ore filter). Only plain strings leave this function: nd.ji is valid in its frame alone.
local FILTER_FLAGS = {'metal', 'hard', 'non_economic', 'soap', 'glass'}
local FILTER_CATS = {'wood', 'cloth', 'silk', 'leather', 'bone', 'shell', 'yarn', 'plant', 'soap'}
function R.words(ji, nd)
  local out, seen = {}, {}
  local function add(w) if w and not seen[w] then seen[w] = true; out[#out + 1] = w end end
  add(nd.sub)
  if (nd.mat_index or -1) >= 0 then add(mat_name(nd.mat_type, nd.mat_index)) end
  local fl = {get(ji, 'flags1'), get(ji, 'flags2'), get(ji, 'flags3')}
  for _, name in ipairs(FILTER_FLAGS) do
    for i = 1, 3 do if fl[i] and bit(fl[i], name) then add(name) end end
  end
  local cat = get(ji, 'material_category')
  if cat then for _, name in ipairs(FILTER_CATS) do if bit(cat, name) then add(name) end end end
  if (int(get(ji, 'metal_ore')) or -1) >= 0 then add('ore') end
  return table.concat(out, '/'):sub(1, 24)
end

-- 'blocks(metal)', 'cloth(plant)', 'bars(iron)', 'bone': the slot as a player names it, the filter in a few words
-- (nd.words, read with the job_item); no filter word: the bare name
function R.slot_name(nd)
  local base = nd.cls
  if nd.cls == 'other' then base = (nd.tname or 'item'):lower() end
  if nd.part == 'part' then base = 'body part' elseif nd.part == 'horn' then base = 'horn'
  elseif nd.part == 'tooth' then base = 'ivory' elseif nd.part == 'pearl' then base = 'pearl' end
  local w = nd.words
  if type(w) == 'string' and w ~= '' then base = base .. '(' .. w .. ')' end
  return base
end

-- one filter -> a need, or nil when the job already holds enough. got = items attached for this filter.
-- nd.ji is the DF job_item itself: valid only in the frame it was read (DF frees it with a finished or
-- cancelled mood job), so a caller that keeps a need across frames looks it up again first (care
-- refresh_moods); every other field is a plain copy
function R.need_of(ji, idx, got)
  local itype = int(get(ji, 'item_type')) or -1
  local tname = itype >= 0 and df.item_type[itype] or nil
  local mt, mi = int(get(ji, 'mat_type')) or -1, int(get(ji, 'mat_index')) or -1
  local q = int(get(ji, 'quantity')) or 1
  local per = tname and R.DIM[tname]
  local n = (per and q >= per) and (q + per - 1) // per or q
  local left = math.min(n, 50) - (got or 0)
  if left <= 0 then return nil end
  local f2 = get(ji, 'flags2')
  local cls, vecs, part, sub = classify(tname, mt, f2)
  local nd = {idx = idx, ji = ji, itype = itype, tname = tname, mat_type = mt, mat_index = mi, cls = cls,
              vecs = vecs, part = part, sub = sub, n = left, non_economic = bit(f2, 'non_economic')}
  nd.label = R.label(nd)
  nd.words = R.words(ji, nd)
  return nd
end

-- the needs of a strange-mood job (only filters still short of items), or nil when it cannot be read.
-- BUG-017 (test fort y374: MOOD_RISK named bars, cloth, bone and logs while the dwarf held all 8 items): an attached
-- item without a filter index (job_item_idx < 0, or an index the filters do not have) still covers a filter it fits;
-- it is matched to the first need still short of that kind
function R.job_needs(job)
  if not R.is_mood_job(job) then return nil end
  local ok, elems = pcall(function() return job.job_items.elements end)
  if not ok or elems == nil then return nil end
  local okn, nel = pcall(function() return #elems end)
  nel = okn and int(nel) or nil
  local got, loose = {}, {}
  for _, ref in ipairs(get(job, 'items') or {}) do
    local i = int(get(ref, 'job_item_idx'))
    if i and i >= 0 and (not nel or i < nel) then got[i] = (got[i] or 0) + 1
    else
      local it = get(ref, 'item')
      if it then loose[#loose + 1] = it end
    end
  end
  local out = {}
  local okl = pcall(function()
    for i, ji in ipairs(elems) do                -- DF vectors iterate from 0, as job_item_idx counts
      local nd = R.need_of(ji, i, got[i] or 0)
      if nd then out[#out + 1] = nd end
    end
  end)
  if not okl then return nil end
  if #loose > 0 then
    for _, it in ipairs(loose) do
      for _, nd in ipairs(out) do
        local okm, yes = pcall(R.match, nd, it)
        if nd.n > 0 and okm and yes then nd.n = nd.n - 1; break end
      end
    end
    local kept = {}
    for _, nd in ipairs(out) do
      if nd.n > 0 then nd.label = R.label(nd); kept[#kept + 1] = nd end
    end
    out = kept
  end
  return out
end

---------------------------------------------------------------- matching items
local function corpse_part(it, part)
  local cf = get(it, 'corpse_flags')
  if not cf or bit(cf, 'unbutchered') then return false end
  if part == 'part' then return true end
  return bit(cf, part)
end

local function mat_flag(it, flag)
  local ok, yes = pcall(function()
    local mi = dfhack.matinfo.decode(it)
    return mi and mi.material and mi.material.flags[flag]
  end)
  if not ok then return nil end
  return yes == true
end

-- does item it satisfy need nd (type, material, class rules; DFHack's own job-item checks veto the rest)
function R.match(nd, it)
  local tn = tname_of(it)
  if not tn then return false end
  if nd.part then                                  -- bones, shells, horns: the corpse flags decide
    return tn == 'CORPSEPIECE' and corpse_part(it, nd.part)
  end
  if nd.tname and nd.tname ~= 'NONE' and tn ~= nd.tname then return false end
  if not nd.tname then
    local ok = false
    for _, v in ipairs(nd.vecs or {}) do if v == tn then ok = true end end
    if not ok then return false end
  end
  if (nd.mat_type or -1) >= 0 and it.mat_type ~= nd.mat_type then return false end
  if (nd.mat_index or -1) >= 0 and it.mat_index ~= nd.mat_index then return false end
  if nd.cls == 'bars' and it.mat_type ~= 0 then return false end              -- metal, not coal or soap
  -- not raw glass (the workshop-class fallback 'rough' keeps both: a glass furnace mood wants raw glass)
  if nd.cls == 'gems' and tn == 'ROUGH' and it.mat_type ~= 0 and not nd.legacy then return false end
  if nd.cls == 'glass' and not GLASS[it.mat_type] then return false end
  if nd.non_economic and tn == 'BOULDER' and R.economic(it) then return false end
  if nd.sub and mat_flag(it, SUBFLAG[nd.sub]) == false then return false end
  if nd.ji and dfhack.job then                     -- Lua API.txt:1404-1410, read-only
    local api = dfhack.job.isSuitableItem
    if api then
      local ok, yes = pcall(function() return api(nd.ji, it:getType(), it:getSubtype()) end)
      if ok and yes == false then return false end
    end
    api = dfhack.job.isSuitableMaterial
    if api then
      local ok, yes = pcall(function() return api(nd.ji, it:getMaterial(), it:getMaterialIndex(), it:getType()) end)
      if ok and yes == false then return false end
    end
  end
  return true
end

-- cloth and thread kinds (BUG-017, Run 10 y418: a plant-cloth mood next to a reserve line "cloth 0/7" that was all
-- wool): the kind of a CLOTH or THREAD item from its material flags (SILK, THREAD_PLANT, YARN), or nil when it cannot
-- be read; cache = {['<mat_type>:<mat_index>'] = kind|false} spares the material lookups of a scan
R.SUBS = {'plant', 'silk', 'yarn'}
R.KINDED = {cloth = true, thread = true}
function R.kind(it, cache)
  local t = tname_of(it)
  if t ~= 'CLOTH' and t ~= 'THREAD' then return nil end
  local key = tostring(get(it, 'mat_type')) .. ':' .. tostring(get(it, 'mat_index'))
  local k = cache and cache[key]
  if k ~= nil then return k or nil end
  k = false
  for _, sub in ipairs(R.SUBS) do
    if mat_flag(it, SUBFLAG[sub]) then k = sub; break end
  end
  if cache then cache[key] = k end
  return k or nil
end

-- the hold of a kinded class split over its kinds (water filling): every kind in stock gets its share, a kind with
-- less stock than its share leaves the rest to the others; stock = {plant = n, silk = n, yarn = n} -> {kind = cap}
function R.split(hold, stock)
  local caps, left, open = {}, math.max(0, int(hold) or 0), {}
  for _, k in ipairs(R.SUBS) do
    caps[k] = 0
    if (int(stock[k]) or 0) > 0 then open[#open + 1] = k end
  end
  while left > 0 and #open > 0 do
    local share, nxt = math.max(1, left // #open), {}
    for _, k in ipairs(open) do
      local add = math.min(share, stock[k] - caps[k], left)
      caps[k], left = caps[k] + add, left - add
      if caps[k] < stock[k] then nxt[#nxt + 1] = k end
    end
    open = nxt
  end
  return caps
end

-- Run 11 (Kilrudrabed, no gem vein: every year the first mood that wanted gems died): what glass does for a need.
-- DF's mood filters (DFHack strangemood.cpp, the game's own rules): a glassmaker's base material and the extra "raw
-- glass" (DF asks for it only once the fort has made that glass) are ROUGH of GLASS_GREEN/CLEAR/CRYSTAL; the extra
-- "cut gems" are SMALLGEM of any material, so cut glass (CutGlass at a jeweler's) serves them; rough gems (a gem
-- cutter's or setter's base, the extra rough gem) are ROUGH of an inorganic: glass never serves those, nor bars,
-- blocks, leather or cloth. 'raw' | 'cut' | nil (a legacy workshop-class need: nil)
function R.glass_ok(nd)
  if type(nd) ~= 'table' or nd.legacy then return nil end
  if nd.cls == 'glass' then return 'raw' end
  if nd.cls == 'gems' and nd.tname == 'SMALLGEM' and ((nd.mat_type or -1) < 0 or GLASS[nd.mat_type]) then return 'cut' end
  return nil
end

-- the class of a whole workshop class (legacy path, no filters): any item of the class's vector
function R.legacy_need(name)
  local v = R.LEGACY_VEC[name]
  if not v then return nil end
  local nd = {cls = R.LEGACY_CLS[name], vecs = {v}, n = 1, legacy = name, mat_type = -1, mat_index = -1}
  if name == 'bone' or name == 'shell' then nd.part = name end
  if name == 'bars' then nd.tname = 'BAR' end
  nd.label = name
  return nd
end

-- an item that holds others (a bin, bag or chest in a stockpile): getStockpileContents lists only the items on
-- the pile's tiles, so binned cloth, thread, gems, bars, leather and bones are reached through it
function R.is_container(it) return get(it.flags, 'container') == true end

-- the reserve class of a stored item, or nil (only plain stock: butchered bones and shells, cut gems (cut glass among
-- them: a "cut gems" filter takes any material), rough inorganic gems and metal bars; raw glass, coal and soap are no
-- mood stock)
function R.item_class(it)
  local t = tname_of(it)
  if t == 'BOULDER' then return 'boulders'
  elseif t == 'WOOD' then return 'logs'
  elseif t == 'CORPSEPIECE' then
    if corpse_part(it, 'bone') then return 'bone' end
    if corpse_part(it, 'shell') then return 'shell' end
  elseif t == 'SKIN_TANNED' then return 'leather'
  elseif t == 'CLOTH' then return 'cloth'
  elseif t == 'THREAD' then return 'thread'
  elseif t == 'SMALLGEM' then return 'gems'
  elseif t == 'ROUGH' then return it.mat_type == 0 and 'gems' or nil
  elseif t == 'BAR' then return it.mat_type == 0 and 'bars' or nil
  end
  return nil
end

---------------------------------------------------------------- reserve sizes
function R.conf(cfg)
  local c = type(cfg) == 'table' and cfg.reserve
  if type(c) ~= 'table' then return R.DEFAULTS end
  local r = {}
  for k, v in pairs(R.DEFAULTS) do r[k] = v end
  for k, v in pairs(c) do r[k] = v end
  return r
end

-- how many items of class cls to hold now. f = {phase, smelter, alarm, total, barrels_empty, coffins_missing,
-- cloth_short}:
--   * nothing before from_phase; smelter classes only with a smelter;
--   * critical supply first: logs for missing empty barrels (drink) and, like boulders, for missing coffins
--     (open citizen corpses beyond the free tombs) stay free; no wood is held during the supply alarm; thread
--     for the cloth the reserve still lacks stays free for the loom;
--   * never more than the fort has (total = held + free) minus that critical part.
function R.hold(c, cls, f)
  local tgt = int((c.targets or {})[cls]) or 0
  if tgt <= 0 or type(f.phase) ~= 'string' or f.phase < (c.from_phase or 'P1') then return 0 end
  for _, s in ipairs(c.smelter or {}) do if s == cls and not f.smelter then return 0 end end
  local crit = 0
  if cls == 'logs' then
    if f.alarm then return 0 end
    crit = math.max(0, (c.barrels_min or 0) - (f.barrels_empty or 0)) + (f.coffins_missing or 0)
  elseif cls == 'boulders' then
    crit = f.coffins_missing or 0
  elseif cls == 'thread' then
    crit = f.cloth_short or 0
  end
  -- live L6 (Paddletribes): 20 of 29 boulders and 20 of 30 logs held forbidden starved masons and carpenters
  -- (42 suspended furniture builds). Bulk classes hold at most a share of the stock (at least share_min)
  local avail = (f.total or 0) - crit
  local sh = (c.share or {})[cls]
  if sh then avail = math.min(avail, math.max(c.share_min or 2, math.floor((f.total or 0) * sh))) end
  return math.max(0, math.min(tgt, avail))
end

-- trade token for a need (trade.lua L.KINDS), or nil. BUG-017 (Run 10 y418): a cloth or thread filter that names
-- its kind asks for that kind ('cloth:plant', 'cloth:silk', 'cloth:yarn', 'thread:*'); plain 'cloth' only when any
-- kind fits
function R.token(nd)
  local k = R.BUY[nd.cls]
  if not k then return nil end
  if R.KINDED[nd.cls] and nd.sub then return k .. ':' .. nd.sub end
  if nd.cls == 'bars' then
    local m = mat_name(nd.mat_type, nd.mat_index)
    if m and m:match('^[a-z_]+$') then return 'bar:' .. m end
  end
  return k
end

return R
