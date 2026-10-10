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
  sizes = {{3, 3}, {4, 4}},
  fail_popups = {'heavy_aquifer', 'salt_water', 'evil', 'savage', 'necro', 'early_invasion', 'no_stone', 'cannot'},
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
C.WAIVABLE = {'old_sites', 'dark_fortress', 'evil', 'savagery', 'trees', 'water', 'aquifer', 'soil',
  'temperature', 'size'}
C.WAIVABLE_SET = set(C.WAIVABLE)

local function cheb(a, b) return math.max(math.abs(a[1] - b[1]), math.abs(a[2] - b[2])) end

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
    local d = cheb(w, s.w)
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
  elseif (rec.read or 0) > 0 then put('water', 'fail', 'no brook or river shown')
  else put('water', 'unknown', 'not shown') end
  tiered('aquifer', rec.aquifer, rules.aquifer_ok, rules.aquifer_warn)
  put('flux', rec.flux and 'pass' or 'warn', rec.flux and 'flux stone layer' or 'no flux shown')
  if not rec.metals then put('ore', 'skip', 'not shown')
  else
    local m = set(rec.metals)
    if m.iron then put('ore', 'pass', 'iron')
    elseif m.copper and m.tin then put('ore', 'warn', 'bronze only')
    else put('ore', 'warn', 'no iron') end
  end
  tiered('soil', rec.soil, rules.soil_ok, rules.soil_warn)
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
    if fp[w] then put('popup', 'fail', w) elseif wp[w] then put('popup', 'warn', w) end
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
