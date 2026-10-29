-- tools/embark/checklist.lua: DESIGN 5.1 site checklist over a panel record.
-- evaluate(rec, rules, ctx) -> {verdict='ok'|'review'|'reject', score=0..100, items={...},
--   fails={ids}, warns={ids}, unknown={ids}}
-- ctx = {world={wx,wy}, size={w,h}}; rules = rules.json (defaults below fill gaps).
local C = {}

C.DEFAULT = {
  dark_fortress_min = 10, old_site_min = 10, goblin_min_rank = 6,
  old_sites = {}, dark_fortresses_seen = {},
  temperature_ok = {'temperate'}, temperature_warn = {'warm', 'cold'},
  trees_ok = {'heavily_forested', 'woodland'}, trees_warn = {'sparse'},
  aquifer_ok = {'none'}, aquifer_warn = {'light'},
  soil_ok = {'little', 'some'}, soil_warn = {'deep', 'very_deep', 'extremely_deep', 'shallow_sand', 'shallow_clay', 'none'},
  -- live L6 (Laborkings: light aquifer, soil down to z125, no boulders for a year) and the Run 9 postmortem
  -- (lesson 1: embark only where metal and a hard stone layer are within reach): soil this deep means no stone
  -- layer in the upper levels, so the site is refused unless `stone` is accepted with a reason
  stone_fail_soil = {'deep', 'very_deep', 'extremely_deep'},
  -- BUG-248: hard stone must lie within hard_stone_levels levels (soil depth estimate per panel category)
  hard_stone_levels = 6,
  soil_levels = {none = 0, little = 1, shallow_sand = 2, shallow_clay = 2, some = 3, deep = 8, very_deep = 15,
    extremely_deep = 25},
  sizes = {{3, 3}, {4, 4}},
  fail_popups = {'heavy_aquifer', 'salt_water', 'evil', 'savage', 'necro', 'early_invasion', 'no_stone', 'cannot',
    'water_mountain'},
  warn_popups = {'light_aquifer', 'dead_civ', 'narrow', 'smallest', 'large', 'very_large', 'largest', 'hard',
    'few_resources', 'unpleasant', 'wildlife'},
}

local function set(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

-- criteria that can be 'unknown' and may be waived one by one at the embark gate
-- (steps.gate, embark.py --waive; tests/test_embark.py keeps embark.py's list equal)
C.WAIVABLE = {'old_sites', 'dark_fortress', 'evil', 'savagery', 'trees', 'water', 'aquifer', 'soil', 'stone',
  'ore', 'temperature', 'size'}
C.WAIVABLE_SET = set(C.WAIVABLE)
-- FR-08: criteria a player may accept although they FAILED (a known trade-off: an old fort nearby, scarce trees,
-- no metal ore), one by one and with a logged reason (steps.gate, embark.py --accept ID --reason TEXT). Never the
-- unreadable panel or a failing warning popup (heavy aquifer, evil, savage, necromancer, early invasion).
C.ACCEPTABLE = {'old_sites', 'dark_fortress', 'evil', 'savagery', 'trees', 'water', 'aquifer', 'soil', 'stone',
  'ore', 'temperature', 'size'}
C.ACCEPTABLE_SET = set(C.ACCEPTABLE)
-- warning popups judged by their own criterion, not by 'popup' ("difficult to obtain stone" is the stone rule)
C.POPUP_OWNER = {no_stone = 'stone', water_mountain = 'terrain'}
-- BUG-248 (Run 15 Guildcleans 'stone free 0', Earthboat 'no hard stone' for mechanisms): criteria a new fort may
-- waive or accept only with an explore-first plan (steps.gate, embark.py --explore-first TEXT); value = why
C.NEEDS_PLAN = {stone = 'no hard stone within reach means no levers, mechanisms or mood boulders'}

-- BUG-248: the levels of soil above the first stone layer, estimated from the panel's soil depth
-- (rules.soil_levels, rules.hard_stone_levels; calibrate live); nil = depth not shown
function C.soil_levels(soil, rules)
  local t = (rules and rules.soil_levels) or C.DEFAULT.soil_levels
  return soil ~= nil and t[soil] or nil
end

local function cheb(a, b) return math.max(math.abs(a[1] - b[1]), math.abs(a[2] - b[2])) end

-- BUG-229: the world tile of an old site. `g` = its global embark tile (world_site.global_min_x/y, or the
-- rectangle's embark_pos_min the embark showed) wins: world tile = g // 16, the same as ctx.world (emb_min // 16).
-- world_site.pos was up to 2 tiles off live (Questmetal: pos 4,10, global_min 6,12 -> world tile 6,12); `w` is the
-- hand-entered world tile and is used only without `g`.
function C.site_world(s)
  if type(s.g) == 'table' and s.g[1] and s.g[2] then return {s.g[1] // 16, s.g[2] // 16} end
  return s.w
end

function C.rules(over)
  local r = {}
  for k, v in pairs(C.DEFAULT) do r[k] = v end
  for k, v in pairs(over or {}) do r[k] = v end
  return r
end

-- nearest listed site to world tile w: dist, name
local function nearest(w, sites)
  local best, name
  for _, s in ipairs(sites or {}) do
    local d = cheb(w, C.site_world(s))
    if not best or d < best then best, name = d, s.name end
  end
  return best, name
end

function C.evaluate(rec, rules, ctx)
  rules, ctx = C.rules(rules), ctx or {}
  local items, out = {}, {fails = {}, warns = {}, unknown = {}}
  local function put(id, res, why)
    items[#items + 1] = {id = id, res = res, why = why or ''}
    if res == 'fail' then out.fails[#out.fails + 1] = id
    elseif res == 'warn' then out.warns[#out.warns + 1] = id
    elseif res == 'unknown' then out.unknown[#out.unknown + 1] = id end
  end
  local function tiered(id, val, ok, warn, missing)
    if val == nil then return put(id, missing or 'unknown', 'not shown') end
    if set(ok)[val] then return put(id, 'pass', val) end
    if set(warn)[val] then return put(id, 'warn', val) end
    put(id, 'fail', val)
  end
  local pop = set(rec.warnings)

  if (rec.read or 0) == 0 then put('panel', 'fail', 'embark panel not readable') end
  -- distances (world tiles, Chebyshev): old forts from Gordon's history, dark fortresses as
  -- seen on the world map; plus vanilla evidence (popup, Neighbors section)
  if ctx.world then
    local d, name = nearest(ctx.world, rules.old_sites)
    if not d then put('old_sites', 'unknown', 'no old sites listed')
    elseif d < rules.old_site_min then put('old_sites', 'fail', name .. ' at ' .. d)
    else put('old_sites', 'pass', 'nearest ' .. name .. ' at ' .. d) end
  else put('old_sites', 'unknown', 'world tile unknown') end
  local df_res, df_why = 'unknown', 'no dark fortress data'
  if pop.early_invasion then df_res, df_why = 'fail', 'popup: invaded very early'
  else
    local d, name
    if ctx.world then d, name = nearest(ctx.world, rules.dark_fortresses_seen) end
    for _, n in ipairs(rec.neighbors or {}) do
      if n.race == 'goblins' and n.rank and n.rank < rules.goblin_min_rank then
        df_res, df_why = 'fail', 'goblins: ' .. n.travel
      end
    end
    if df_res ~= 'fail' and d then
      if d < rules.dark_fortress_min then df_res, df_why = 'fail', name .. ' at ' .. d
      else df_res, df_why = 'pass', 'nearest seen ' .. name .. ' at ' .. d end
    elseif df_res ~= 'fail' and #(rec.neighbors or {}) > 0 then
      df_res, df_why = 'pass', 'no near goblins in Neighbors'
    elseif df_res ~= 'fail' and rec.neighbors_shown then
      df_why = 'Neighbors shown but no entry parsed'  -- stays unknown: recalibrate panel.lua
    end
  end
  put('dark_fortress', df_res, df_why)

  local evil, sav = rec.evil, rec.savagery
  if pop.evil then evil = 'evil' end
  if pop.savage then sav = 'high' end
  tiered('evil', evil, {'neutral', 'good'}, {})
  tiered('savagery', sav, {'low', 'medium'}, {})
  tiered('trees', rec.trees, rules.trees_ok, rules.trees_warn)
  if rec.water then put('water', 'pass', rec.water)
  elseif rec.aquifer == 'light' then put('water', 'warn', 'no stream shown; light aquifer as well source')
  elseif (rec.read or 0) > 0 then put('water', 'fail', 'no brook or river shown')
  else put('water', 'unknown', 'not shown') end
  tiered('aquifer', rec.aquifer, rules.aquifer_ok, rules.aquifer_warn)
  put('flux', rec.flux and 'pass' or 'warn', rec.flux and 'flux stone layer' or 'no flux shown')
  -- Run 9 postmortem lesson 1: a metal ore within reach is required; the panel lists the site's metals
  if (rec.read or 0) == 0 then put('ore', 'unknown', 'panel not read')
  elseif not rec.metals then put('ore', 'fail', 'no metal ore shown')
  else
    local m = set(rec.metals)
    if m.iron then put('ore', 'pass', 'iron')
    elseif m.copper and m.tin then put('ore', 'warn', 'bronze only (' .. table.concat(rec.metals, ', ') .. ')')
    else put('ore', 'warn', 'no iron (' .. table.concat(rec.metals, ', ') .. ')') end
  end
  tiered('soil', rec.soil, rules.soil_ok, rules.soil_warn)
  -- a hard stone layer within reach (live L6, Run 9 lesson 1): deep soil = no stone layer in the upper levels
  -- (boulders, blocks, mechanisms); the best tile of the rectangle counts (stone_soil, steps.merge_tiles)
  local soil = rec.stone_soil or rec.soil
  local layers = rec.layers and #rec.layers > 0 and table.concat(rec.layers, ', ') or nil
  -- BUG-248: and the estimated soil levels above the stone must not exceed hard_stone_levels
  local lv, maxlv = C.soil_levels(soil, rules), rules.hard_stone_levels
  local too_deep = lv ~= nil and maxlv ~= nil and lv > maxlv
  if pop.no_stone then put('stone', 'fail', 'popup: difficult to obtain stone')
  elseif soil ~= nil and (set(rules.stone_fail_soil or rules.stone_warn_soil)[soil] or too_deep) then
    local aq = rec.aquifer == 'light' or rec.aquifer == 'varied'
    put('stone', 'fail', soil .. ' soil: no stone layer in the upper levels' ..
        (aq and ', the first stone lies below the aquifer (Laborkings: no boulders)' or ' (boulders scarce)') ..
        (lv and maxlv and string.format('; about %d levels of soil, hard stone wanted within %d', lv, maxlv) or ''))
  elseif soil ~= nil then
    put('stone', 'pass', 'stone near the surface (' .. (soil == 'none' and 'no' or soil) .. ' soil' ..
        (layers and (', ' .. layers) or '') .. ')')
  elseif layers then put('stone', 'pass', 'stone layers ' .. layers)
  else put('stone', 'unknown', 'soil depth not shown') end
  -- BUG-229: DF refuses a rectangle entirely on water or mountains; the site finder's matches can be such rectangles
  local tl = rec.tiles
  if pop.water_mountain then put('terrain', 'fail', 'popup: cannot embark entirely on water or mountains')
  elseif tl and (tl.terrain or 0) > 0 then
    if tl.mw == tl.terrain and tl.terrain >= 16 then
      put('terrain', 'fail', 'all ' .. tl.terrain .. ' tiles are mountain or water (DF refuses the embark)')
    elseif tl.mw == tl.terrain then
      put('terrain', 'warn', 'all ' .. tl.terrain .. ' read tiles are mountain or water (' .. tl.n .. ' of 16 read)')
    else put('terrain', 'pass', (tl.terrain - tl.mw) .. ' of ' .. tl.terrain .. ' read tiles are land') end
  elseif rec.terrain == 'mountain' or rec.terrain == 'water' then
    put('terrain', 'warn', 'the hovered tile is ' .. rec.terrain .. ' (' .. tostring(rec.biome) .. '); scan --tiles')
  elseif rec.terrain then put('terrain', 'pass', tostring(rec.biome)) end
  if rec.ice then put('temperature', 'fail', 'ice')
  else tiered('temperature', rec.temperature, rules.temperature_ok, rules.temperature_warn) end
  if ctx.size then
    local okz = false
    for _, s in ipairs(rules.sizes) do
      if s[1] == ctx.size[1] and s[2] == ctx.size[2] then okz = true end
    end
    put('size', okz and 'pass' or 'fail', ctx.size[1] .. 'x' .. ctx.size[2])
  else put('size', 'unknown', 'rectangle unknown') end
  local fp, wp = set(rules.fail_popups), set(rules.warn_popups)
  for _, w in ipairs(rec.warnings or {}) do
    if C.POPUP_OWNER[w] then -- judged by its own criterion above
    elseif fp[w] then put('popup', 'fail', w) elseif wp[w] then put('popup', 'warn', w) end
  end

  out.items = items
  out.score = math.max(0, 100 - 12 * #out.warns - 4 * #out.unknown - 30 * #out.fails)
  out.verdict = (#out.fails > 0 and 'reject') or (#out.unknown > 0 and 'review') or 'ok'
  return out
end

-- rank results: ok before review before reject, then score
function C.rank(results)
  local order = {ok = 1, review = 2, reject = 3}
  table.sort(results, function(a, b)
    local va, vb = order[a.verdict.verdict], order[b.verdict.verdict]
    if va ~= vb then return va < vb end
    return a.verdict.score > b.verdict.score
  end)
  return results
end

return C
