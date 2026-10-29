-- dfllm.mood (BUG-282..285, Run 15: four strange moods failed in three forts within ~3 game years and no MOOD_CRITICAL
-- came for three of them): the emergency rules of a strange mood. A library of care (no kernel module, no events of its
-- own: care emits and acts, so the registry's `by = care` holds). Pure helpers, no DF writes:
--   * MD.left: the ticks until DF's insanity line. DF counts it in unit.job.mood_timeout (df-structures: counts down from
--     50000, insanity at 0; DFHack's strangemood sets 50000). Live Run 15: Drillchamber's glassmaker went insane 54,481
--     ticks after he claimed the Glass Furnace (30 days after the mood began), the Possessed carpenter ~53,000 ticks after his
--     claim; thirst was 13,991 at that death, so the thirst bar (mood_crit 50,000) never came. Unreadable field: the claim
--     tick + mood_timer (an estimate, said so); no claim yet: unknown.
--   * MD.reasons: why a mood is an emergency now (workshop, material, waiting, timer), MD.step: the days-left step whose
--     change says MOOD_CRITICAL again (20, 10, 5, 2 days).
--   * MD.chain: the workshops a missing material class is made in (cloth/thread: Loom; leather: Tanners, Butchers; glass:
--     Glass Furnace; gems: Jewelers (cut glass: the Glass Furnace too); bone/shell: Butchers).
--   * MD.line: the status/brief line 'MOOD <name> <kind> needs <items>: <have/missing>, <days left>'.
local C = require('dfllm.util.contract')
local DAY = C.TICKS.DAY

local MD = {}

MD.TIMER = 50000                     -- DF's mood_timeout start value (ticks), the estimate's base
MD.STEPS = {20, 10, 5, 2}            -- days left: each step is news for MOOD_CRITICAL
MD.BK_HAVE = 'enough exist'          -- care's slot blocker for a slot the dwarf can fill (care.lua BK_HAVE)

-- the shops a missing class is made in (df.workshop_type / df.furnace_type names; Butchers is no moodable shop: follow
-- places it through `add`). `glassy`: a gems slot that cut glass serves (care's rec.glass): the Glass Furnace as well
MD.CHAIN = {cloth = {'Loom'}, thread = {'Loom'}, leather = {'Tanners', 'Butchers'}, glass = {'GlassFurnace'},
            gems = {'Jewelers'}, bone = {'Butchers'}, shell = {'Butchers'}}
-- a built shop that stands for a wanted one (economy.MOOD_ALT: a mood claims either)
MD.ALT = {MetalsmithsForge = 'MagmaForge', GlassFurnace = 'MagmaGlassFurnace'}

local function int(v) return math.tointeger(type(v) == 'string' and tonumber(v) or v) end

local function trunc(s, n)                      -- cut at a UTF-8 boundary
  s = tostring(s or '')
  if #s <= n then return s end
  local cut = n
  while cut > 0 and (s:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return s:sub(1, cut)
end
MD.trunc = trunc

-- DF's own clock of the mood (ticks to insanity), nil when the field is unreadable or out of range
function MD.timer(u)
  local ok, v = pcall(function() return u.job.mood_timeout end)
  v = ok and int(v) or nil
  if v and v >= 0 and v <= 10 * MD.TIMER then return v end
  return nil
end

-- ticks left until insanity and their source: 'timer' (DF's field, > 0), 'est' (the claim + mood_timer), nil (no claim yet;
-- DF starts the clock at the claim). rec.claim = the tick care first saw the claimed workshop
-- BUG-307 (Run 15 Earthboat y382: the MOOD line said '41 d left' from DF's timer while the Secretive bowyer stood at thirst 53,516,
-- ~18 days from death): a moody dwarf neither drinks nor eats, so thirst and hunger rise one a tick to the death line (care's
-- 'dies at 75000'). The ticks left are the nearest of the mood clock and the two body clocks; src 'thirst'/'hunger' then.
MD.DIE = 75000
function MD.body(u)
  local th, hu
  pcall(function() th = int(u.counters2.thirst_timer) end)
  pcall(function() hu = int(u.counters2.hunger_timer) end)
  return th, hu
end
function MD.left(u, rec, now, c)
  local left, src
  local t = MD.timer(u)
  if t and t > 0 then left, src = t, 'timer'
  else
    local claim = int(rec and rec.claim)
    if claim then left, src = math.max(0, claim + (int(c and c.mood_timer) or MD.TIMER) - now), 'est' end
  end
  local th, hu = MD.body(u)
  local die = int(c and c.mood_die) or MD.DIE
  for _, b in ipairs({{th, 'thirst'}, {hu, 'hunger'}}) do
    if b[1] and b[1] > 0 then
      local l = math.max(0, die - b[1])
      if left == nil or l < left then left, src = l, b[2] end
    end
  end
  return left, src
end

-- the step token of `days` left: 'd20' .. 'd2' (the smallest step it is within), 'far' above the first, nil = unknown
function MD.step(days)
  if days == nil then return nil end
  local tok = 'far'
  for _, s in ipairs(MD.STEPS) do if days <= s then tok = 'd' .. s end end
  return tok
end

-- why the mood is an emergency now, weightiest first. o = {now, ws (claimed type or nil), shop (the type his skill needs,
-- missing on the map, or nil), left (ticks or nil), nosrc (rec.nosrc), unres_since (tick a material went missing or nil),
-- since (mood start)}; c = care's config (mood_crit_nows ticks, mood_crit_wait / mood_crit_left days)
function MD.reasons(c, o)
  local out = {}
  local nows = int(c.mood_crit_nows) or DAY
  if o.shop or (not o.ws and (o.now - (int(o.since) or o.now)) >= nows) then out[#out + 1] = 'workshop' end
  if type(o.nosrc) == 'table' and #o.nosrc > 0 then out[#out + 1] = 'material' end
  local wait = (int(c.mood_crit_wait) or 5) * DAY
  if o.unres_since and o.now - o.unres_since >= wait then out[#out + 1] = 'waiting' end
  if o.left and o.left <= (int(c.mood_crit_left) or 10) * DAY then out[#out + 1] = 'timer' end
  return out
end

-- the shops of the missing classes `miss` that `missing` (a set of types missing on the map) lacks, in a stable order,
-- without duplicates
function MD.chain(miss, missing, glassy)
  local out, seen = {}, {}
  local function add(t)
    if missing[t] and not seen[t] then seen[t] = true; out[#out + 1] = t end
  end
  for _, cls in ipairs(type(miss) == 'table' and miss or {}) do
    for _, t in ipairs(MD.CHAIN[cls] or {}) do add(t) end
    if cls == 'gems' and glassy then add('GlassFurnace') end
  end
  return out
end

-- the set of types missing on the map from economy.mood_shops' answer ({missing = {...}}), {} when unknown
function MD.missing_set(ms)
  local set = {}
  for _, t in ipairs(type(ms) == 'table' and type(ms.missing) == 'table' and ms.missing or {}) do set[t] = true end
  return set
end

-- the chain shops that are no moodable type (economy.mood_shops never lists them): Butchers for leather, bone and shell.
-- Review fix: without this the typed request never named the Butchers. Read-only (the built workshops); added to `set`
-- when none of the type is built; unreadable buildings: unchanged
MD.EXTRA = {'Butchers'}
function MD.extra_missing(set)
  pcall(function()
    local have = {}
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local n = df.workshop_type[b.type]
      local okb, done = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
      if n and (not okb or done) then have[n] = true end
    end
    for _, t in ipairs(MD.EXTRA) do if not have[t] then set[t] = true end end
  end)
  return set
end

-- the short name of a unit sheet name ('Udil Monangasob "Drilledboard", Brewer' -> 'Udil Monangasob')
function MD.short_name(n)
  local s = tostring(n or '')
  s = s:gsub('%s*".-"', ''):gsub(',.*$', '')
  s = s:match('^%s*(.-)%s*$') or s
  return trunc(s, 28)
end

-- 'glass x2: none in the fort [0/0/0 of 11]' -> name 'glass x2', blocker 'none in the fort'
local function slot_parts(e)
  local t = type(e) == 'table' and tostring(e.t or '') or tostring(e or '')
  local name, rest = t:match('^(.-): (.*)$')
  if not name then return t, '' end
  return name, (rest:gsub('%s*%[.*$', ''))
end
MD.slot_parts = slot_parts

-- what the slots of the last report say: names (every open slot), ok (the dwarf can fill them), bad ({name, blocker})
function MD.slots(sl)
  local names, ok, bad = {}, 0, {}
  for _, e in ipairs(type(sl) == 'table' and sl or {}) do
    local name, bk = slot_parts(e)
    names[#names + 1] = name
    if bk == MD.BK_HAVE then ok = ok + 1 else bad[#bad + 1] = {name, bk} end
  end
  return names, ok, bad
end

-- '34 d left' (DF's timer) | '~34 d left (est. from the claim)' | 'time unknown (DF starts it at the claim)'
function MD.left_text(left, src)
  if not left then return 'time unknown (DF starts it at the claim)' end
  local d = left // DAY
  if src == 'timer' then return string.format('%d d left', d) end
  if src == 'thirst' or src == 'hunger' then                       -- BUG-307: '17 d left (thirst 53516)'
    return string.format('%d d left (%s %d)', d, src, math.max(0, MD.DIE - left))
  end
  return string.format('~%d d left (est. from the claim)', d)
end

-- the status/brief line (<= 200 bytes): 'MOOD <name> <kind> needs <items>: <have/missing>, <days left>'. o = {name, kind,
-- sl (care's rec.sl), miss (classes, when no slots), ws (claimed), shop (missing type), left, src}
function MD.line(o)
  local names, ok, bad = MD.slots(o.sl)
  local needs = #names > 0 and table.concat(names, ', ') or
                ((type(o.miss) == 'table' and #o.miss > 0) and table.concat(o.miss, ', ') or 'its materials')
  local hm
  if #names == 0 then
    hm = (type(o.miss) == 'table' and #o.miss > 0) and ('missing ' .. table.concat(o.miss, ',')) or 'nothing missing'
  else
    local b = {}
    for _, x in ipairs(bad) do b[#b + 1] = x[2] ~= '' and (x[1] .. ' (' .. x[2] .. ')') or x[1] end
    hm = string.format('have %d/%d', ok, #names) .. (#b > 0 and ('; missing ' .. table.concat(b, ', ')) or '')
  end
  if o.shop then hm = hm .. '; no ' .. o.shop
  elseif not o.ws then hm = hm .. '; no workshop claimed' end
  local tail = ', ' .. MD.left_text(o.left, o.src)
  local head = string.format('MOOD %s %s needs ', o.name ~= '' and o.name or ('unit ' .. tostring(o.unit or '?')),
                             o.kind or '?')
  local room = 200 - #head - #tail - 2
  local body = trunc(needs, math.max(20, room // 2))
  body = body .. ': ' .. trunc(hm, math.max(20, room - #body))
  return trunc(head .. body .. tail, 200)
end

return MD
