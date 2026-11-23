-- startset (Neuausrichtung 1, decision E4; docs/v2/NEU1-startset.md): the survival start set of week 1, phase 0.
-- Run 16a i1 Manorsubtle (y372-y374, 20 dead of thirst on a good site), Bachwald and Mansionlauded: still, farm, office and
-- stockpiles hung on the dug fort core; when the core dig stalled the fort had none of them, and an office zone without its
-- table left the manager idle (BUG-396). ONE rule, once a game day, independent of the core and of the LLM's plan:
--
--   while the set is not handed over, every part that neither stands nor is under construction is requested
--   (PROJECT_REQUEST why=startset, follow places it on the surface beside the wagon, or in the core when one exists);
--   the set is handed over once the core exists (manifest zones.Z4) AND every part stands; then the module is idle for good.
--
-- Parts (config baseline.startset.parts): shops (the workshop types of startset.shops, default Still and Carpenters), farm (a farm
-- plot), pile (a food stockpile), office (an Office zone with a BUILT chair AND a BUILT table: the manager's hard precondition),
-- water (water.drink_access: an accepted source or a bank the citizens reach; missing -> the existing BUG-424 cistern request
-- with the nearest water tile, never free digging). Fail closed: a read that fails counts the part as missing; unknown water is
-- missing but not requested. Bounded: a part is asked at most max_tries times, retry_days apart, never while it is under
-- construction. Total escalation (verifier, NEU1 retry): EVERY part that is not ok, whatever the reason (missing after its
-- tries, planned but never built, water with no tile to pipe from, water never scanned, a failing read), raises
-- DECISION_NEEDED startset (A) once after giveup_days (default max_tries * retry_days) days not ok, with the cause; so phase 0
-- can never hold silently. runner's P0 deliverable `startset` asks M.done; runner auto-waives it once the set escalated and
-- fortcore stage 1 exists (M.escalated).
-- Fair play: read-only (buildings, zones, the water module); every placement is follow's bp.place, a player's blueprint.
local M = {name = 'startset', every = {ticks = 1200}, verbs = {}, on = {}}

M.DAY = 1200
M.PARTS = {'shops', 'farm', 'pile', 'office', 'water'}
M.DEFAULTS = {on = true, parts = M.PARTS, shops = {'Still', 'Carpenters'}, retry_days = 7, max_tries = 3}
-- the template each part asks for (follow, dfpilot/wake.py STARTSET_TPLS)
M.TPL = {shops = 'workshops', farm = 'farms', pile = 'foodpile', office = 'office', water = 'cistern'}
M.FOOD_PILES = {['dfllm-start'] = true, ['dfllm-stock'] = true, ['dfllm-drink'] = true}

local st      -- persisted m.startset {v, d (1 handed over), t (tick of the hand-over), r = {part -> {n tries, t last, s first tick
              -- seen not ok, g 1 escalated}}}
local pub     -- the state key ss
local last    -- the last facts (tests, inspect)

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function save(K) K.persist.set('m.startset', st) end

-- config baseline.startset with defaults (a bad value keeps the default; lint --config reports it)
function M.conf(K)
  local b = type(K.cfg) == 'table' and type(K.cfg.baseline) == 'table' and K.cfg.baseline.startset or nil
  local c = {}
  for k, v in pairs(M.DEFAULTS) do c[k] = v end
  if type(b) ~= 'table' then return c end
  if type(b.on) == 'boolean' then c.on = b.on end
  if type(b.parts) == 'table' then
    local ok, p = true, {}
    for _, x in ipairs(b.parts) do
      local known = false
      for _, y in ipairs(M.PARTS) do if x == y then known = true end end
      if known then p[#p + 1] = x else ok = false end
    end
    if ok then c.parts = p end
  end
  if type(b.shops) == 'table' and #b.shops > 0 then
    local s = {}
    for _, x in ipairs(b.shops) do if type(x) == 'string' then s[#s + 1] = x end end
    if #s == #b.shops then c.shops = s end
  end
  local rd, mt = int(b.retry_days), int(b.max_tries)
  if rd and rd >= 1 and rd <= 120 then c.retry_days = rd end
  if mt and mt >= 1 and mt <= 20 then c.max_tries = mt end
  local gd = int(b.giveup_days)
  if gd and gd >= 1 and gd <= 360 then c.giveup_days = gd end
  return c
end

---------------------------------------------------------------- reads (df; replaced in tests)
local function built(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return ok and r == true                -- fail closed: a building whose stage cannot be read is not counted as standing
end

local function in_zone(z, x, y, zz)
  if zz ~= z.z or x < z.x1 or x > z.x2 or y < z.y1 or y > z.y2 then return false end
  local fn = dfhack.buildings and dfhack.buildings.containsTile
  if not fn then return true end
  local ok, yes = pcall(fn, z, x, y)
  return not ok or yes == true
end

-- the facts the rule needs: {shops = {type -> 'built'|'planned'}, farm, pile, office = 'built'|'planned'|nil, water =
-- 'ok'|'no'|'unknown', near = {x,y,z}|nil, core = bool}. A part whose read fails stays nil (missing: fail closed).
function M.read(K)
  local f = {shops = {}}
  local bo = df.global.world.buildings.other
  pcall(function()
    for _, b in ipairs(bo.WORKSHOP_ANY) do
      local t = df.workshop_type[b.type]
      if t then f.shops[t] = (f.shops[t] == 'built' or built(b)) and 'built' or 'planned' end
    end
  end)
  pcall(function()
    for _, b in ipairs(bo.FARM_PLOT) do f.farm = (f.farm == 'built' or built(b)) and 'built' or 'planned' end
  end)
  pcall(function()
    for _, sp in ipairs(bo.STOCKPILE) do
      local food = false
      pcall(function() food = sp.settings.flags.food == true end)
      if not food then food = M.FOOD_PILES[dfhack.df2utf(sp.name or ''):lower()] == true end
      if food then f.pile = 'built' end
    end
  end)
  pcall(function()
    for _, z in ipairs(bo.ACTIVITY_ZONE) do
      if z.type == df.civzone_type.Office then
        local have = {chair = 0, table = 0, chair_p = 0, table_p = 0}
        for kind, vec in pairs({chair = 'CHAIR', table = 'TABLE'}) do
          for _, b in ipairs(bo[vec]) do
            if in_zone(z, b.x1 or b.centerx or -1, b.y1 or b.centery or -1, b.z) then
              if built(b) then have[kind] = have[kind] + 1 else have[kind .. '_p'] = have[kind .. '_p'] + 1 end
            end
          end
        end
        if have.chair > 0 and have.table > 0 then f.office = 'built'
        elseif f.office ~= 'built' and (have.chair + have.chair_p > 0) and (have.table + have.table_p > 0) then
          f.office = 'planned'            -- the furniture is placed: under construction (buildingplan waits for the items)
        end
      end
    end
  end)
  local ok, acc = K.call('water', 'drink_access')
  if ok and type(acc) == 'table' and acc.known == true then
    f.water = acc.ok == true and 'ok' or 'no'
    local n = type(acc.near) == 'table' and acc.near or (type(acc.bat) == 'table' and acc.bat) or nil
    if n and int(n[1]) and int(n[2]) and int(n[3]) then f.near = {int(n[1]), int(n[2]), int(n[3])} end
  else f.water = 'unknown' end
  local man = K.manifest()
  local z4 = type(man) == 'table' and type(man.zones) == 'table' and man.zones.Z4
  f.core = type(z4) == 'table' and #z4 > 0
  return f
end

---------------------------------------------------------------- the rule (pure)
-- per part: 'ok' (stands), 'wip' (under construction), 'miss' (neither), 'unknown' (water not scanned yet); missing shop types
function M.judge(f, c)
  local out, types = {}, {}
  for _, p in ipairs(c.parts) do
    if p == 'shops' then
      local wip = false
      for _, t in ipairs(c.shops) do
        local s = f.shops and f.shops[t]
        if s ~= 'built' then types[#types + 1] = t; if s == 'planned' then wip = true end end
      end
      out.shops = #types == 0 and 'ok' or (wip and 'wip' or 'miss')
    elseif p == 'water' then
      out.water = (f.water == 'ok' and 'ok') or (f.water == 'no' and 'miss') or 'unknown'
    else
      local s = f[p]
      out[p] = (s == 'built' and 'ok') or (s == 'planned' and 'wip') or 'miss'
    end
  end
  return out, types
end

-- the cause a part is not ok, for the escalation text
M.CAUSE = {wip = 'planned but not built (materials?)', water = 'no tile to pipe from / not scanned',
           miss = 'missing after requests'}

-- days a part may stay not ok before the one-time escalation
function M.giveup_days(c) return int(c.giveup_days) or (c.max_tries * c.retry_days) end

-- what to do now: {req = {{part, tpl, types?, at?}}, gave_up = {parts newly given up}, why = {part -> cause}, done = bool
-- (hand over), dirty = the state changed (persist)}. Total: every part not ok, for any reason, escalates once after giveup_days.
function M.decide(f, s, c, now)
  local res, types = M.judge(f, c)
  local out = {req = {}, gave_up = {}, why = {}, res = res, types = types}
  local all = true
  for _, p in ipairs(c.parts) do if res[p] ~= 'ok' then all = false end end
  if all and f.core then out.done = true; return out end
  s.r = type(s.r) == 'table' and s.r or {}
  local gd = M.giveup_days(c) * M.DAY
  for _, p in ipairs(c.parts) do
    local r = type(s.r[p]) == 'table' and s.r[p] or {n = 0}
    s.r[p] = r
    if res[p] == 'ok' then                               -- a part that stands again may be asked afresh if it is lost
      if r.s or r.g or (int(r.n) or 0) > 0 then out.dirty = true end
      r.n, r.t, r.g, r.s = 0, nil, nil, nil
    else
      local since = int(r.s)
      if not since then since = now; r.s = now; out.dirty = true end
      local can_ask = res[p] == 'miss' and not (p == 'water' and not f.near)
      local cause = (res[p] == 'wip' and M.CAUSE.wip) or ((p == 'water' and not can_ask) and M.CAUSE.water) or M.CAUSE.miss
      local tries_over = false
      if can_ask then
        local n, t = int(r.n) or 0, int(r.t)
        if n < c.max_tries then
          if not t or now - t >= c.retry_days * M.DAY then
            r.n, r.t = n + 1, now
            out.req[#out.req + 1] = {part = p, tpl = M.TPL[p], types = p == 'shops' and types or nil,
                                     at = p == 'water' and f.near or nil}
          end
        elseif t and now - t >= c.retry_days * M.DAY then
          tries_over = true
        end
      end
      if not r.g and (tries_over or now - since >= gd) then
        r.g = 1
        out.gave_up[#out.gave_up + 1] = p
        out.why[p] = cause
      end
    end
  end
  return out
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.startset')
  st = type(p) == 'table' and p or {}
  st.v = 2
  pub, last = nil, nil
end

local HINT = {shops = 'bp sites workshops surface=1 --fresh', farm = 'bp sites farms surface=1 --fresh',
              pile = 'bp sites foodpile --fresh', office = 'bp sites office surface=1 --fresh',
              water = 'inspect what=water_sources'}

function M.step(K)
  local c = M.conf(K)
  if not c.on then pub = nil; return end
  if st.d == 1 then pub = {d = 1}; return end
  local ok, f = pcall(M.read, K)
  if not ok or type(f) ~= 'table' then
    K.log('warn', 'startset read: %s', tostring(f))
    f = {shops = {}, water = 'unknown'}             -- fail closed: every part missing, nothing handed over
  end
  last = f
  local now = K.now().tick
  local d = M.decide(f, st, c, now)
  if d.done then
    st.d, st.t = 1, now
    save(K)
    K.log('info', 'startset handed over to the core: every part stands and the core exists; no more start-set requests')
    pub = {d = 1}
    return
  end
  for _, q in ipairs(d.req) do
    local data = {tpl = q.tpl, why = 'startset', n = 1}
    if q.types then data.types = q.types end
    local msg
    if q.part == 'water' then
      data.why = 'no_water'                          -- the existing BUG-424 route: a piped cistern from the nearest water
      data.at = q.at
      msg = string.format('startset: no water the citizens reach: cistern from %d,%d,%d', q.at[1], q.at[2], q.at[3])
    else
      msg = string.format('startset: %s missing%s: %s requested (try %d/%d)', q.part,
                          q.types and (' (' .. table.concat(q.types, ',') .. ')') or '', q.tpl, st.r[q.part].n, c.max_tries)
    end
    K.log('warn', '%s', msg)
    K.emit('PROJECT_REQUEST', 'B', msg:sub(1, 200), data)
  end
  if #d.gave_up > 0 then
    local cmds, parts = {}, {}
    for _, p in ipairs(d.gave_up) do parts[#parts + 1] = p .. ': ' .. d.why[p]; cmds[#cmds + 1] = 'dfllm ' .. HINT[p] end
    local why = table.concat(parts, '; ')               -- schema DECISION_NEEDED why:s: 'office: planned but not built (materials?)'
    local q = string.format('start set not ok for %d days: %s. Place by hand (d.cmds) or phase.waive startset',
                            M.giveup_days(c), table.concat(parts, '; '))
    K.log('warn', '%s', q)
    K.emit('DECISION_NEEDED', 'A', q:sub(1, 200), {id = 'startset', q = q:sub(1, 200), cmds = cmds, why = why:sub(1, 200)})
  end
  if #d.req > 0 or #d.gave_up > 0 or d.dirty then save(K) end
  local m, g = {}, {}
  for _, p in ipairs(c.parts) do
    if d.res[p] ~= 'ok' then m[#m + 1] = d.res[p] == 'unknown' and (p .. '?') or p end
    if type(st.r) == 'table' and type(st.r[p]) == 'table' and st.r[p].g == 1 and d.res[p] ~= 'ok' then g[#g + 1] = p end
  end
  pub = {d = 0, m = m}
  if #g > 0 then pub.f = g end
end

function M.state() return pub and {ss = pub} or {} end

-- public (runner's P0 deliverable `startset`): the set is complete, handed over, or switched off
function M.done(K)
  local c = M.conf(K)
  if not c.on or (st and st.d == 1) then return true end
  if type(pub) ~= 'table' then return false end     -- no pass yet: fail closed
  return #(pub.m or {}) == 0
end

-- public (runner's auto-waiver of the P0 deliverable): a part that is still not ok was escalated (DECISION_NEEDED startset)
function M.escalated()
  return type(pub) == 'table' and type(pub.f) == 'table' and #pub.f > 0
end

-- public (runner's status text): the parts the set waits for, e.g. 'shops,office'
function M.waiting()
  return type(pub) == 'table' and table.concat(pub.m or {}, ',') or ''
end

function M.last() return last end

return M
