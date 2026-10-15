-- tools/embark/panel.lua: parse the vanilla embark panel, warning popup and Neighbors section
-- into a site record. Every phrase below is a literal string of DF 53.16 (found in
-- "Dwarf Fortress.exe"); how the panel lays them out is [LIVE-UNTESTED] until the L0
-- captures replace the synthetic fixtures (tools/embark/fixtures/).
local V = require('embark.view')
local P = {}

-- exact cell phrases (lowercase) -> value
P.SOIL = {['little soil'] = 'little', ['some soil'] = 'some', ['deep soil'] = 'deep',
  ['very deep soil'] = 'very_deep', ['extremely deep soil'] = 'extremely_deep',
  ['shallow sand'] = 'shallow_sand', ['shallow clay'] = 'shallow_clay'}
P.AQUIFER = {['light aquifer'] = 'light', ['heavy aquifer'] = 'heavy', ['varied aquifer'] = 'varied'}
P.TEMP = {freezing = 'freezing', cold = 'cold', temperate = 'temperate', warm = 'warm', hot = 'hot',
  scorching = 'scorching'}
P.TREES = {['heavily forested'] = 'heavily_forested', woodland = 'woodland', sparse = 'sparse',
  scarce = 'scarce', none = 'none'}
P.VEG = {thick = 'thick', moderate = 'moderate', sparse = 'sparse', scarce = 'scarce', none = 'none'}
-- surroundings = alignment x savagery (wiki "Surroundings")
P.SURR = {calm = {'neutral', 'low'}, wilderness = {'neutral', 'medium'}, ['untamed wilds'] = {'neutral', 'high'},
  serene = {'good', 'low'}, mirthful = {'good', 'medium'}, ['joyous wilds'] = {'good', 'high'},
  sinister = {'evil', 'low'}, haunted = {'evil', 'medium'}, terrifying = {'evil', 'high'}}
-- labelled values; longest label first so 'river:' does not shadow 'minor river:'
P.LABELS = {{'other vegetation:', 'vegetation'}, {'major river:', 'major_river'}, {'minor river:', 'minor_river'},
  {'surroundings:', 'surroundings'}, {'temperature:', 'temperature'}, {'nearest site:', 'nearest'},
  {'stream:', 'stream'}, {'trees:', 'trees'}, {'river:', 'river'}, {'brook:', 'brook'}}
P.WATER = {'major_river', 'river', 'minor_river', 'stream', 'brook'}  -- strongest first
-- warning popup sentences -> warning id
P.POPUPS = {
  {'area with a light aquifer', 'light_aquifer'}, {'area with a heavy aquifer', 'heavy_aquifer'},
  {'area with salt water', 'salt_water'}, {'selected an evil area', 'evil'},
  {'selected a savage area', 'savage'}, {"near a necromancer's tower", 'necro'},
  {'invaded very early by powerful foes', 'early_invasion'}, {'difficult to obtain stone', 'no_stone'},
  {'civilization is dead or dying', 'dead_civ'}, {'selected a narrow area', 'narrow'},
  {'smallest possible area', 'smallest'}, {'selected a very large area', 'very_large'},
  {'selected a large area', 'large'}, {'largest possible area', 'largest'},
  {'very difficult to survive', 'hard'}, {'difficult to find resources', 'few_resources'},
  {'very unpleasant environs', 'unpleasant'}, {'wildlife might be very dangerous', 'wildlife'},
  {'cannot embark', 'cannot'}, {'must embark on map', 'cannot'}}
P.FINDER = {{'match found!', 'match'}, {'partial match.', 'partial'}, {'no match.', 'none'}, {'searching', 'searching'}}
P.METALS = {iron = 1, copper = 1, tin = 1, silver = 1, gold = 1, zinc = 1, lead = 1, nickel = 1,
  bismuth = 1, platinum = 1, aluminum = 1}
P.RACES = {dwarves = 1, humans = 1, elves = 1, goblins = 1, kobolds = 1}
-- stone layer names (DF 53.16 inorganic stone layers; Run 9 postmortem lesson 1: embark only where a hard stone
-- layer is within reach, read from the embark screen's layer list). A cell that lists only these names (and
-- optionally "layer"/"layers") is a layer line; soils (clay, sand, loam, silt, peat) are not stone.
P.STONES = {granite = 1, diorite = 1, gabbro = 1, basalt = 1, andesite = 1, dacite = 1, rhyolite = 1, obsidian = 1,
  quartzite = 1, slate = 1, phyllite = 1, schist = 1, gneiss = 1, marble = 1, sandstone = 1, siltstone = 1,
  mudstone = 1, shale = 1, claystone = 1, limestone = 1, dolomite = 1, chalk = 1, chert = 1, conglomerate = 1,
  ['rock salt'] = 1}
-- Neighbors travel phrases -> rank (higher = farther); calibrate against tiles at L0
P.TRAVEL = {{'inaccessible', 99}, {'your location', 0}, {'here', 0}, {'a short trip', 1}, {'a short walk', 1}, {"half day's travel", 2},
  {"1/2 day's travel", 2}, {"nearly a day's travel", 3}, {"more than a day's travel", 5},
  {"a day's travel", 4}}

function P.travel_rank(s)
  s = V.lower(s)
  local n = s:match("([0-9]+) days' travel")
  if n then return 4 + tonumber(n) end
  for _, t in ipairs(P.TRAVEL) do
    if s:find(t[1], 1, true) then return t[2] end
  end
end

local function metal_list(t)
  local found = {}
  for w in t:gmatch('[a-z]+') do
    if not P.METALS[w] then return nil end
    found[#found + 1] = w
  end
  return #found > 0 and found or nil
end

local function stone_list(t)
  local s = t:gsub('%f[a-z]layers?%f[^a-z]', ' ')
  local found = {}
  for part in s:gmatch('[^,]+') do
    local name = V.trim(part)
    if name ~= '' then
      if P.STONES[name] then found[#found + 1] = name
      else
        for w in name:gmatch('[a-z]+') do
          if not P.STONES[w] then return nil end
          found[#found + 1] = w
        end
      end
    end
  end
  return #found > 0 and found or nil
end

-- view -> record. rec.read = number of recognised panel facts (0 = panel not visible).
function P.parse(view)
  local rec = {read = 0, warnings = {}, rivers = {}, neighbors = {}}
  local seen = {}
  local function warn(id)
    if not seen[id] then seen[id] = true; rec.warnings[#rec.warnings + 1] = id end
  end
  local cells = view:cells()
  for i, c in ipairs(cells) do
    local t = V.lower(c.text)
    if P.SOIL[t] then rec.soil = P.SOIL[t]; rec.read = rec.read + 1
    elseif P.AQUIFER[t] then rec.aquifer = P.AQUIFER[t]; rec.read = rec.read + 1
    elseif t == 'flux stone layer' then rec.flux = true; rec.read = rec.read + 1
    elseif t == 'ice' then rec.ice = true
    elseif t:sub(1, 10) == 'neighbors:' then rec.neighbors_shown = true  -- section header (exe 53.16)
    elseif P.SURR[t] and not rec.surroundings then rec.surroundings = t  -- unlabelled fallback
    elseif metal_list(t) then rec.metals = metal_list(t)
    elseif stone_list(t) then
      rec.layers = rec.layers or {}
      for _, n in ipairs(stone_list(t)) do rec.layers[#rec.layers + 1] = n end
      rec.read = rec.read + 1
    else
      for _, l in ipairs(P.LABELS) do
        if t:sub(1, #l[1]) == l[1] then
          local val = V.trim(t:sub(#l[1] + 1))
          local nxt = cells[i + 1]
          if val == '' and nxt and nxt.y == c.y then val = V.lower(nxt.text) end
          rec.read = rec.read + 1
          local key = l[2]
          if key == 'temperature' then rec.temperature = P.TEMP[val] or val
          elseif key == 'trees' then rec.trees = P.TREES[val] or val
          elseif key == 'vegetation' then rec.vegetation = P.VEG[val] or val
          elseif key == 'surroundings' then rec.surroundings = val
          elseif key == 'nearest' then rec.read = rec.read - 1  -- Neighbors section, handled below
          else rec.rivers[#rec.rivers + 1] = key end
          break
        end
      end
    end
  end
  if rec.surroundings and P.SURR[rec.surroundings] then
    rec.evil, rec.savagery = P.SURR[rec.surroundings][1], P.SURR[rec.surroundings][2]
  end
  for _, w in ipairs(P.WATER) do
    for _, r in ipairs(rec.rivers) do if r == w and not rec.water then rec.water = w end end
  end
  -- popup sentences and finder status come from paragraphs (wrapped text joined)
  local paras = view:paras()
  for _, p in ipairs(paras) do
    for _, pp in ipairs(P.POPUPS) do
      if p.norm:find(pp[1], 1, true) then warn(pp[2]) end
    end
    for _, f in ipairs(P.FINDER) do
      if not rec.finder and p.norm:find(f[1], 1, true) then rec.finder = f[2] end
    end
  end
  if seen.light_aquifer and not rec.aquifer then rec.aquifer = 'light' end
  if seen.heavy_aquifer then rec.aquifer = 'heavy' end
  -- Neighbors section ("Neighbors:" + race + "Nearest site: ..." on the right panel; v1 scan3.sh
  -- filtered these lines out of the same capture): each "nearest site:" belongs to the last race named before it (in the
  -- same paragraph, else in the paragraph above in the same column)
  local NS = 'nearest site:'
  local function last_race(s)
    local r
    for w in s:gmatch('[a-z]+') do if P.RACES[w] then r = w end end
    return r
  end
  local carry = {}
  for _, p in ipairs(paras) do
    local s, pos, race = p.norm, 1, carry[p.x]
    while true do
      local a = s:find(NS, pos, true)
      if not a then break end
      race = last_race(s:sub(pos, a - 1)) or race
      local b = s:find(NS, a + #NS, true) or (#s + 1)
      local phrase = s:sub(a + #NS, b - 1)
      local cut = #phrase + 1
      for w_at, w in phrase:gmatch('()([a-z]+)') do
        if P.RACES[w] and w_at < cut then cut = w_at end
      end
      phrase = V.trim(phrase:sub(1, cut - 1))
      rec.neighbors[#rec.neighbors + 1] = {race = race or '?', travel = phrase, rank = P.travel_rank(phrase)}
      pos = a + #NS
    end
    carry[p.x] = last_race(s) or carry[p.x]
  end
  if rec.read > 0 and not rec.aquifer then rec.aquifer = 'none' end  -- no aquifer line shown
  if rec.read > 0 and not rec.soil then rec.soil = 'none' end
  return rec
end

return P
