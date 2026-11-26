-- jobwhy: "why is this job not running" (P8, Neuausrichtung 1; docs/v2/NEU1-jobfrage.md). A library, not a kernel
-- module (like orderlib): economy requires it for `inspect what=why` (CLI `dfpilot why <k>`) and its stall watches
-- (brew, fish, stale orders). It only READS game state and never writes or cures.
--
-- Brew and fish stalls were "fixed" several times on guessed causes (BUG-716, BUG-767 'DF did not assign it (path or
-- burrow?)', 'DF counts items its own way'). This reads the blocker off the game, in DF's own order of assignment:
--   job:   worker -> suspended -> the labor's holders (mood, soldier, workshop profile, burrows, walk group, busy, not
--          looking for work) -> the job items it still lacks (none / forbidden / claimed / out of reach).
--   order: open? -> validated (the manager) -> its jobs -> a fitting workshop (pinned, built, profile, full) -> conditions.
--   shop:  its first unworked job, else the first open order of its type.
-- Fail closed: a check without data (no API, an error, labor unknown, walk group 0) never names a cause; all clear
-- is `unknown`, with what was seen. Result: {kind, id, job, cause, text, shop?, at?, workers?, inputs?, sub?}.
local O = require('dfllm.orderlib')

local J = {}
J.ITEMS_MAX = 4000            -- item records looked at per missing job item (config economy.jobwhy.items_max)
J.SHOP_MAX_JOBS = 10          -- DF: a workshop holds at most ten jobs (dfhack.job.assignToWorkshop)
-- the worker statuses that block, in the order a tie is broken
J.BLOCK = {'profile', 'burrow', 'far', 'soldier', 'mood'}
J.WORDS = {profile = 'kept out by the workshop profile', burrow = 'kept out by burrows', far = 'off the workshop\'s walk group',
           soldier = 'soldiers', mood = 'in a strange mood', busy = 'busy', unavailable = 'not looking for work', free = 'free'}
-- kinds a player names: an order / job predicate on (job type name, reaction name)
J.KINDS = {
  brew = function(tn, rn) return tostring(rn or ''):sub(1, 5) == 'BREW_' end,
  fish = function(tn) return tn == 'PrepareRawFish' end,
  cook = function(tn) return tn == 'PrepareMeal' end,
}

local function int(v) return math.tointeger(type(v) == 'string' and tonumber(v) or v) end
local function pget(f, ...)
  local ok, v = pcall(f, ...)
  if ok then return v end
end
local function ename(e, v)
  local n = pget(function() return e[v] end)
  return type(n) == 'string' and n or nil
end
local function plural(n, one, many) return n == 1 and one or (many or (one .. 's')) end
local function at_text(p) return p and string.format('%d,%d,%d', p[1], p[2], p[3]) or '?' end
local function uname(u)
  local n = pget(function() return dfhack.units.getReadableName(u) end)
  if type(n) ~= 'string' or n == '' then n = pget(function() return dfhack.TranslateName(dfhack.units.getVisibleName(u)) end) end
  return type(n) == 'string' and n ~= '' and n:sub(1, 30) or ('unit ' .. tostring(u.id))
end
local function each(v)                         -- a DF vector or a Lua list, 0- or 1-based, as a Lua list
  local out = {}
  if v == nil then return out end
  local ok = pcall(function() for _, x in ipairs(v) do out[#out + 1] = x end end)
  if not ok then out = {} end
  return out
end
-- walk groups of points {x, y, z} through snapshot (the one module that reads the map): a list, -1 = unknown, 0 = no walkable tile;
-- nil when snapshot does not answer (every reach check is then skipped: fail closed)
local function walk_groups(K, pts)
  if #pts == 0 then return {} end
  local okc, ok, g = pcall(K.call, 'snapshot', 'groups', pts, false)
  if not okc or not ok or type(g) ~= 'table' then return nil end
  return g
end

---------------------------------------------------------------- what a job needs: labors and skill
-- the reaction raw of `name`: {skill, ws = {'workshop:Still', ...}} or nil
function J.reaction(name)
  if type(name) ~= 'string' or name == '' then return nil end
  return pget(function()
    for _, rx in ipairs(df.global.world.raws.reactions.reactions) do
      if rx.code == name then
        local r = {skill = int(rx.skill), ws = {}}
        local bt = df.building_type
        for i, t in ipairs(rx.building.type) do
          local sub = rx.building.subtype[i]
          local wn = t == bt.Workshop and ename(df.workshop_type, sub) or t == bt.Furnace and ename(df.furnace_type, sub) or nil
          if wn and wn ~= 'Custom' then r.ws[#r.ws + 1] = (t == bt.Workshop and 'workshop:' or 'furnace:') .. wn end
        end
        return r
      end
    end
  end)
end

local function skill_labor(s)
  if not (int(s) and s >= 0) then return nil end
  local l = pget(function() return df.job_skill.attrs[s].labor end)
  return int(l) and l >= 0 and l or nil
end

-- the material class of (mat_type, mat_index): 'wood' | 'rock' | 'metal' | nil
local function mat_class(mt, mi)
  if not (int(mt) and mt >= 0) then return nil end
  local m = pget(dfhack.matinfo.decode, mt, mi)
  local f = m and pget(function() return m.material.flags end)
  if not f then return nil end
  if pget(function() return f.WOOD end) then return 'wood' end
  if pget(function() return f.IS_METAL end) then return 'metal' end
  if pget(function() return f.IS_STONE end) then return 'rock' end
  return nil
end

-- NEU14 BUG-893: the labor of a ConstructBuilding job whose holder is no workshop: a wall / floor construction is built with Building construction (BUG-009, BUG-745),
-- a road with Road building. The other building kinds: economy.BUILD_LABOR (the kernel's own table); unknown = nil
J.BUILD_LABOR = {Construction = 'BUILD_CONSTRUCTION', Road = 'BUILD_ROAD'}

-- labor ids (any of them) and the skill id for a job / order of type `jt`; nil labors = unknown
function J.labors(jt, rname, mt, mi, skey)
  local tn = ename(df.job_type, jt)
  local bk = type(skey) == 'string' and skey:match('^building:(.+)$')
  if bk then                                           -- NEU14 BUG-893: a building that is no workshop (a wall, a floor): not 'workshop:Farmers'
    local l = J.BUILD_LABOR[bk] and df.unit_labor and df.unit_labor[J.BUILD_LABOR[bk]]
    if tn == 'ConstructBuilding' and int(l) then return {l}, nil end
    return nil, nil
  end
  local skills = {}
  if tn == 'CustomReaction' then
    local rx = J.reaction(rname)
    if rx and int(rx.skill) then skills[1] = rx.skill end
  else
    local a = pget(function() return df.job_type.attrs[jt] end)
    local l = a and int(pget(function() return a.labor end))
    local s = a and int(pget(function() return a.skill end))
    if l and l >= 0 then return {l}, s end
    if s and s >= 0 then skills[1] = s
    elseif a then
      local mc = mat_class(mt, mi)
      for _, k in ipairs({'skill_stone', 'skill_wood', 'skill_metal'}) do
        local sk = int(pget(function() return a[k] end))
        local want = mc == nil or (k == 'skill_stone' and mc == 'rock') or (k == 'skill_wood' and mc == 'wood') or (k == 'skill_metal' and mc == 'metal')
        if sk and sk >= 0 and want then skills[#skills + 1] = sk end
      end
    end
  end
  local labors, seen = {}, {}
  for _, s in ipairs(skills) do
    local l = skill_labor(s)
    if l and not seen[l] then seen[l] = true; labors[#labors + 1] = l end
  end
  if #labors == 0 and tn then                          -- orderlib's table (FR-01) as the fallback
    local mc = mat_class(mt, mi)
    local ws = O.workshops(tn, mc or 'any')
    -- BUG-835 (Run 17 i2: MakeBarrel 'the labor this job needs is not known'): a job whose material arrives as a category has no class; its shop names it
    if ws == nil and skey then ws, mc = {skey}, mc or (skey == 'workshop:Craftsdwarfs' and 'rock' or nil) end
    -- NEU3: a job with no material class and no workshop known (a bare job record): the material the kernel makes it in first (wood, then rock)
    if ws == nil and mc == nil then
      for _, c2 in ipairs({'wood', 'rock'}) do
        local w2 = O.workshops(tn, c2)
        if w2 then ws, mc = w2, c2; break end
      end
    end
    for _, ln in ipairs(O.labors(tn, mc or 'any', ws) or {}) do
      local l = df.unit_labor and df.unit_labor[ln]
      if int(l) and not seen[l] then seen[l] = true; labors[#labors + 1] = l end
    end
  end
  return #labors > 0 and labors or nil, skills[1]
end

---------------------------------------------------------------- the workshop
-- {id, b, type ('Still'), key ('workshop:Still'), at, groups (set or nil = unknown), njobs, prof {permit, minl, maxl, maxg, blocked}, lim (burrow ids)}
function J.shop(b, K)
  local s = {id = int(b.id), b = b, njobs = #each(pget(function() return b.jobs end))}
  local bt = pget(function() return b:getType() end)
  local sub = pget(function() return b:getSubtype() end) or b.type
  if bt ~= nil and df.building_type and df.building_type.Workshop ~= nil and bt ~= df.building_type.Workshop and bt ~= df.building_type.Furnace then
    -- NEU14 BUG-893 (Run 17d i4: 'why job:1733178' read a wall construction as 'ws 19342 workshop:Farmers ... derived labor PROCESS_PLANT': the construction type
    -- number was taken for a workshop type): a building that is no workshop or furnace is named by its own type
    s.kind = ename(df.building_type, bt)
    s.key = s.kind and ('building:' .. s.kind)
  elseif bt == (df.building_type and df.building_type.Furnace) then
    s.type = ename(df.furnace_type, sub); s.key = s.type and ('furnace:' .. s.type)
  else
    s.type = ename(df.workshop_type, sub); s.key = s.type and ('workshop:' .. s.type)
  end
  local x1, y1, x2, y2, z = int(b.x1), int(b.y1), int(b.x2), int(b.y2), int(b.z)
  local cx, cy = int(pget(function() return b.centerx end)), int(pget(function() return b.centery end))
  if x1 and y1 and x2 and y2 and z then
    s.at = {cx or (x1 + x2) // 2, cy or (y1 + y2) // 2, z}
    local pts = {}
    for x = x1 - 1, x2 + 1 do
      for y = y1 - 1, y2 + 1 do if #pts < 64 then pts[#pts + 1] = {x, y, z} end end
    end
    local gl = K and walk_groups(K, pts) or nil
    local gs, any = {}, false
    for _, g in ipairs(gl or {}) do
      if int(g) and g > 0 then gs[g] = true; any = true end
    end
    s.groups = any and gs or nil
  end
  local pr = pget(function() return b.profile end)
  if pr then
    s.prof = {maxg = int(pget(function() return pr.max_general_orders end)), minl = int(pget(function() return pr.min_level end)),
              maxl = int(pget(function() return pr.max_level end))}
    local pw = each(pget(function() return pr.permitted_workers end))
    if #pw > 0 then
      s.prof.permit = {}
      for _, id in ipairs(pw) do s.prof.permit[id] = true end
    end
    s.prof.blocked = pget(function() return pr.blocked_labors end)
  end
  -- burrows that limit their workshops to their members and hold this one (DF 50 burrow flag limit_workshops)
  if s.at then
    s.lim = {}
    pcall(function()
      for _, bw in ipairs(df.global.plotinfo.burrows.list) do
        if pget(function() return bw.flags.limit_workshops end) == true
           and dfhack.burrows.isAssignedTile(bw, {x = s.at[1], y = s.at[2], z = s.at[3]}) then s.lim[#s.lim + 1] = bw.id end
      end
    end)
  end
  return s
end

local function in_burrows(ids, p)
  local want = {}
  for _, id in ipairs(ids) do want[id] = true end
  local ok, yes = pcall(function()
    for _, bw in ipairs(df.global.plotinfo.burrows.list) do
      if want[bw.id] and dfhack.burrows.isAssignedTile(bw, {x = p[1], y = p[2], z = p[3]}) then return true end
    end
    return false
  end)
  if not ok then return nil end
  return yes
end

local function civ_burrows()
  return pget(function()
    local al = df.global.plotinfo.alerts
    local i = al.civ_alert_idx
    if not i or i == 0 then return nil end
    local r = {}
    for _, id in ipairs(al.list[i].burrows) do r[#r + 1] = id end
    return #r > 0 and r or nil
  end)
end

---------------------------------------------------------------- the workers
-- one holder's status at shop `s` for labor `lid` (skill `sk`): status, detail
local function holder_status(K, u, lid, sk, s, soldier, civ)
  local mine = {}
  pcall(function() for _, id in ipairs(u.burrows) do mine[#mine + 1] = id end end)
  local lim = civ or (#mine > 0 and mine or nil)          -- the burrows DF keeps him (and the items he fetches) to
  if int(u.mood) and u.mood >= 0 then return 'mood' end
  if soldier then return 'soldier' end
  local pr = s and s.prof
  if pr then
    if pr.permit and not pr.permit[u.id] then return 'profile', 'not on the permitted list' end
    if sk and pr.minl and pr.maxl and (pr.minl > 0 or pr.maxl < 3000) then
      local lv = int(pget(dfhack.units.getNominalSkill, u, sk, true))
      if lv and (lv < pr.minl or lv > pr.maxl) then return 'profile', string.format('skill %d outside %d-%d', lv, pr.minl, pr.maxl) end
    end
    if pr.blocked ~= nil and pget(function() return pr.blocked[lid] end) == true then return 'profile', 'labor blocked there' end
  end
  if s and s.at then
    if lim and in_burrows(lim, s.at) == false then return 'burrow', civ and 'the civ alert holds him' or 'his burrows' end
    if s.lim and #s.lim > 0 then
      local member = false
      for _, a in ipairs(mine) do for _, b in ipairs(s.lim) do if a == b then member = true end end end
      if not member then return 'burrow', 'a workshop-limiting burrow' end
    end
    if s.groups then
      local g = (walk_groups(K, {{u.pos.x, u.pos.y, u.pos.z}}) or {})[1]
      if int(g) and g > 0 and not s.groups[g] then return 'far', 'walk group ' .. g end
    end
  end
  local j = pget(function() return u.job.current_job end)
  if j ~= nil then return 'busy', ename(df.job_type, j.job_type) or '?' end
  if dfhack.units.isJobAvailable then
    local av = pget(dfhack.units.isJobAvailable, u)
    if av == false then return 'unavailable' end
  end
  return 'free', nil, lim
end

-- the citizens holding any labor of `labors`, each with a status at shop `s`: {n, free, by = {status = n}, who = {...}}
function J.workers(K, labors, sk, s, ctx)
  local cu = (ctx and ctx.census) or K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return nil end
  local sold = {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  local civ = civ_burrows()
  local w = {n = 0, free = 0, by = {}, who = {}, lims = {}}
  for _, id in ipairs(cu.ids) do
    local u = df.unit.find(id)
    local adult = u and pget(dfhack.units.isAdult, u)
    if u and adult ~= false then
      local held
      for _, l in ipairs(labors) do
        if pget(function() return u.status.labors[l] end) == true then held = l; break end
      end
      if held then
        local stt, det, lim = holder_status(K, u, held, sk, s, sold[id], not sold[id] and civ or nil)
        w.n = w.n + 1
        w.by[stt] = (w.by[stt] or 0) + 1
        if stt == 'free' then
          w.free = w.free + 1
          if lim then w.lims[#w.lims + 1] = lim else w.unlimited = true end
        end
        if #w.who < 6 then w.who[#w.who + 1] = {id = id, name = uname(u), st = stt, det = det} end
      end
    end
  end
  return w
end

local function labor_names(labors)
  local r = {}
  for _, l in ipairs(labors or {}) do r[#r + 1] = ename(df.unit_labor, l) or tostring(l) end
  return table.concat(r, '/')
end

function J.workers_text(w, labors)
  local parts = {}
  for _, k in ipairs({'free', 'busy', 'unavailable', 'profile', 'burrow', 'far', 'soldier', 'mood'}) do
    if (w.by[k] or 0) > 0 then parts[#parts + 1] = string.format('%d %s', w.by[k], J.WORDS[k]) end
  end
  local who = {}
  for _, e in ipairs(w.who) do
    if #who < 3 then who[#who + 1] = string.format('%s %d (%s%s)', e.name, e.id, e.st, e.det and (': ' .. e.det) or '') end
  end
  return string.format('%d %s %s: %s%s', w.n, labor_names(labors), plural(w.n, 'holder'), table.concat(parts, ', '),
                       #who > 0 and (' [' .. table.concat(who, '; ') .. ']') or '')
end

-- the worker cause: nil when a free holder exists (or unknown), else code, text
function J.worker_cause(w, labors)
  if not w then return nil end
  if w.n == 0 then return 'no_labor', string.format('nobody holds the %s labor', labor_names(labors)) end
  if w.free > 0 then return nil end
  local best, bn = nil, 0
  for _, k in ipairs(J.BLOCK) do
    if (w.by[k] or 0) > bn then best, bn = k, w.by[k] end
  end
  -- a structural blocker (profile, burrow, walk group, ...) that holds at least half the holders outranks busy: the holders
  -- that are busy now come free, the ones kept out never do (the text lists both)
  local nb = (w.by.busy or 0) + (w.by.unavailable or 0)
  if nb > 0 and not (best and 2 * bn >= w.n) then return 'busy', J.workers_text(w, labors) end
  if best then return best, J.workers_text(w, labors) end
  return nil
end

---------------------------------------------------------------- the inputs
local function has_str(vec, want)
  for _, x in ipairs(each(vec)) do
    local s = pget(function() return x.value end) or x
    if tostring(s) == want then return true end
  end
  return false
end

-- does item `it` match job item `ji`? true / false; approx = a check could not be made
local function item_fits(ji, it)
  local approx = false
  local t = pget(function() return it:getType() end)
  local jt = int(pget(function() return ji.item_type end)) or -1
  if jt >= 0 and t ~= jt then return false end
  local js = int(pget(function() return ji.item_subtype end)) or -1
  if js >= 0 then
    local sub = pget(function() return it:getSubtype() end)
    if sub == nil then approx = true elseif sub ~= js then return false end
  end
  local mt = pget(function() return it:getMaterial() end)
  local mi = pget(function() return it:getMaterialIndex() end)
  if mt == nil then mt, mi = it.mat_type, it.mat_index end
  local jm = int(pget(function() return ji.mat_type end)) or -1
  if jm >= 0 then
    if mt ~= jm then return false end
    local jx = int(pget(function() return ji.mat_index end)) or -1
    if jx >= 0 and mi ~= jx then return false end
  end
  if dfhack.job.isSuitableItem and t ~= nil then
    local ok, yes = pcall(dfhack.job.isSuitableItem, ji, t, pget(function() return it:getSubtype() end) or -1)
    if not ok then approx = true elseif not yes then return false end
  else approx = true end
  if dfhack.job.isSuitableMaterial and mt ~= nil then
    local ok, yes = pcall(dfhack.job.isSuitableMaterial, ji, mt, mi or -1, t or -1)
    if not ok then approx = true elseif not yes then return false end
  else approx = true end
  local f1 = pget(function() return ji.flags1 end)
  if f1 and pget(function() return f1.unrotten end) == true and pget(function() return it.flags.rotten end) == true then return false end
  if f1 and pget(function() return f1.empty end) == true then
    local inside = pget(dfhack.items.getContainedItems, it)
    if inside == nil then approx = true elseif #each(inside) > 0 then return false end
  end
  local rp = pget(function() return ji.has_material_reaction_product end)
  local rc = pget(function() return ji.reaction_class end)
  rp, rc = rp and tostring(rp) or '', rc and tostring(rc) or ''
  if rp ~= '' or rc ~= '' then
    local m = mt and pget(dfhack.matinfo.decode, mt, mi or -1)
    local mat = m and pget(function() return m.material end)
    if not mat then approx = true
    else
      if rp ~= '' and not has_str(pget(function() return mat.reaction_product.id end), rp) then return false end
      if rc ~= '' and not has_str(pget(function() return mat.reaction_class end), rc) then return false end
    end
  end
  return true, approx
end

local SKIP = {'garbage_collect', 'removed', 'in_building', 'construction', 'trader', 'hostile', 'spider_web'}

-- the job items `job` still lacks: {{idx, what, need, match, free, forbid, claimed, far, container, approx, clipped}}; nil = unknown
-- DF 50+ (53): job.job_items is a job_item_vector struct, the list is its `.elements` (act.lua, care.lua read it so too); an old
-- build: the vector itself. A list that cannot be read is nil (unknown), never {} ("nothing missing" would be a claim on unread data).
local function list_of(v)
  if v == nil or type(v) == 'string' or type(v) == 'number' or type(v) == 'boolean' then return nil end
  local out = {}
  if not pcall(function() for _, x in ipairs(v) do out[#out + 1] = x end end) then return nil end
  return out
end
function J.job_items(job)
  local l = list_of(pget(function() return job.job_items.elements end))
  if l == nil then
    local v = pget(function() return job.job_items end)
    if v ~= nil and pget(function() return v.elements end) == nil then l = list_of(v) end   -- a struct without a list is no list
  end
  return l
end

function J.inputs(K, job, s, ctx)
  local list = J.job_items(job)
  if list == nil then return nil end
  local filled = {}
  for _, ref in ipairs(each(pget(function() return job.items end))) do
    local k = int(pget(function() return ref.job_item_idx end))
    if k then filled[k] = true end
  end
  local cap = math.max(100, int(ctx and ctx.items_max) or J.ITEMS_MAX)
  local out = {}
  for i, ji in ipairs(list) do
    local idx = i - 1                                   -- job_item_idx is 0-based
    if not filled[idx] then
      local e = {_pts = {}, idx = idx, need = int(pget(function() return ji.quantity end)) or 1, match = 0, free = 0, forbid = 0, claimed = 0, far = 0}
      local vid = int(pget(function() return ji.vector_id end)) or -1
      local it = int(pget(function() return ji.item_type end)) or -1
      -- NEU16 BUG-915 (BUG-836 / BUG-868 / BUG-896: '0 match' for EVERY job item that has an item_type: wood, plant, plant growth; the one text with item_type -1 matched): the vector
      -- the scan walked came from `ename(df.items_other_id, ji.vector_id)`, while act.lua writes the same field from df.job_item_vector_id (act.ws_task, mood_task) and brewsnap reads
      -- it as items_other_id too. The live reading 'item_type=5(WOOD) vector_id=18' cannot say that items_other_id[18] is WOOD (the two enums are not proven to share values; not
      -- decidable offline). A job item with an item_type can only be met by items of that type, and world.items.other has a vector of the same name for the types the scans
      -- care about: that vector is walked first (e.vec 'type'); the decoded vector_id stays as `vdec` and a name that differs is printed (`vec_mismatch`), so one live reading decides.
      local vdec = vid >= 0 and ename(df.items_other_id, vid) or nil
      local tname = it >= 0 and ename(df.item_type, it) or nil
      local tvec = tname and pget(function() return df.global.world.items.other[tname] end) or nil
      local vname = (tvec ~= nil and tname) or vdec or tname or 'IN_PLAY'
      e.vec = (tvec ~= nil and 'type') or (vdec and 'vector_id') or 'type'
      e.vdec, e.tname = vdec, tname
      e.vec_mismatch = (tvec ~= nil and vdec and vdec ~= tname) and vdec or nil
      e.itype = it >= 0 or nil
      e.what = (it >= 0 and ename(df.item_type, it) or vname):lower()
      local f1 = pget(function() return ji.flags1 end)
      e.bfilter = vname == 'BOULDER' and pget(function() return ji.flags2.non_economic end) == true and pget(function() return ji.flags3.hard end) == true or nil
      if f1 and pget(function() return f1.empty end) == true then e.container = true; e.what = 'empty ' .. e.what end
      local rp = pget(function() return ji.has_material_reaction_product end)
      if rp and tostring(rp) ~= '' then e.what = e.what .. ' (' .. tostring(rp) .. ')' end
      local vec = pget(function() return df.global.world.items.other[vname] end)
      if vec == nil then e.unknown = true
      else
        local n, open = 0, {}
        local okscan = pcall(function()
          for _, item in ipairs(vec) do
            n = n + 1
            if n > cap then e.clipped = true; break end
            local fl, skip = item.flags, false            -- item_flags names (DF 53); a missing one ends the scan: unknown
            for _, k in ipairs(SKIP) do if fl[k] == true then skip = true; break end end
            if not skip then
              e.ntype = (e.ntype or 0) + 1                  -- NEU16 BUG-915: the items of the scanned vector that DF's job picker could look at (not built in, not a trader's ...)
              if #(e._tpts or {}) < 200 then
                e._tpts = e._tpts or {}
                local tx, ty, tz = pget(dfhack.items.getPosition, item)
                if type(tx) == 'table' then tx, ty, tz = tx.x, tx.y, tx.z end
                if int(tx) then e._tpts[#e._tpts + 1] = {tx, ty, tz} end
              end
              if vname == 'BOULDER' and not (item.flags.forbid or item.flags.dump or item.flags.in_job) then e.btot = (e.btot or 0) + 1 end   -- NEU14 BUG-896
              local fit, approx = item_fits(ji, item)
              if fit then
                if approx then e.approx = true end
                e.match = e.match + 1
                if item.flags.forbid or item.flags.dump then e.forbid = e.forbid + 1
                elseif item.flags.in_job then e.claimed = e.claimed + 1
                else
                  local x, y, z = pget(dfhack.items.getPosition, item)
                  if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
                  open[#open + 1] = int(x) and {x, y, z} or false
                end
              end
            end
          end
        end)
        if not okscan then e.unknown = true end
        -- the free ones: on the workshop's walk group (one snapshot call for all; unknown counts as free)
        local pts, at = {}, {}
        for k, p in ipairs(open) do if p and s and s.groups then pts[#pts + 1] = p; at[#pts] = k end end
        local gl = s and s.groups and walk_groups(K, pts) or nil
        local far = {}
        for i, g in ipairs(gl or {}) do if int(g) and g > 0 and not s.groups[g] then far[at[i]] = true end end
        for k = 1, #open do
          if far[k] then e.far = e.far + 1
          else
            e.free = e.free + 1
            if open[k] and #e._pts < 200 then e._pts[#e._pts + 1] = open[k] end
          end
        end
      end
      -- NEU16 BUG-915: a typed scan that matched nothing although items of the type exist is NOT 'none': it says so with the counts (items of the type, those on the workshop's walk
      -- group among the first 200); no_input is never concluded from it (DF's own cancel reason leads: attach_df)
      if e.itype and not e.btot and e.match == 0 and (e.ntype or 0) > 0 and not e.unknown and not e.clipped then      -- a boulder item states its own filter (BUG-896 counts)
        e.unverified = true
        if s and s.groups and e._tpts and #e._tpts > 0 then
          local gl = walk_groups(K, e._tpts)
          if gl then
            local k = 0
            for _, g in ipairs(gl) do if int(g) and g > 0 and s.groups[g] then k = k + 1 end end
            e.tnear = k
          end
        end
      end
      e._tpts = nil
      -- BUG-836 (Run 17 i2: 'plant (DRINK_MAT) x1: 0 match' beside 6,932 plants in the census): a scan that finds none where the census holds many
      e.cens = J.census_count(ctx and ctx.inv, e)
      out[#out + 1] = e
    end
  end
  return out
end

-- the census count of the item a job item asks for (economy's keys), nil when there is no key for it
function J.census_count(inv, e)
  if type(inv) ~= 'table' then return nil end
  local w = tostring(e.what or '')
  if w:find('^plant') and w:find('DRINK_MAT', 1, true) then return (int(inv.brew_p) or 0) + (int(inv.brew_g) or 0) end
  if w:find('^fish') then return int(inv.fish_raw) end
  if w:find('^empty barrel') then return int(inv.barrels_empty) end
  return nil
end

function J.input_text(e)
  if e.unverified then       -- NEU16 BUG-915: never '0 match, 0 free' for a typed scan while items of that type exist
    return string.format('%s x%d: scan unverified (%d items of that type exist, %s near)%s%s', e.what, e.need, e.ntype or 0, e.tnear ~= nil and tostring(e.tnear) or '?',
                         e.vec_mismatch and string.format('; job_item.vector_id decodes as %s, the scan walked the %s vector', e.vec_mismatch, tostring(e.tname)) or '',
                         e.cens and e.cens > 0 and string.format('; the census holds %d usable', e.cens) or '')
  end
  -- BUG-868 (Run 17 i2 'plant (DRINK_MAT) x1: 0 match' beside 'items:plants 936 free, 923 in a container'): plants in a container are DF's normal
  -- case and count as input; a scan that finds none while the census holds some says so instead of claiming none
  local parts = {(e.match == 0 and (e.cens or 0) > 0) and string.format('0 match by the scan, the census holds %d usable (plants inside containers count as input)', e.cens)
                 or string.format('%d match', e.match)}
  for _, k in ipairs({'free', 'forbid', 'claimed', 'far'}) do
    if k == 'free' or (e[k] or 0) > 0 then parts[#parts + 1] = string.format('%d %s', e[k], k == 'claimed' and 'held by another job' or
                                                                              k == 'far' and 'off its walk group' or k == 'forbid' and 'forbidden' or k) end
  end
  if e.inb then parts[#parts + 1] = string.format('%d inside the free holders burrows', e.inb) end
  -- NEU14 BUG-896: a mason's boulder: of all the free boulders the ones its stone filter (non_economic, hard) takes
  if e.btot then parts[#parts + 1] = string.format('%d of %d free boulders are %s', (e.free or 0) + (e.far or 0), e.btot, e.bfilter and 'hard non-economic stone' or 'taken by this job') end
  return string.format('%s x%d: %s%s%s', e.what, e.need, table.concat(parts, ', '), e.clipped and ' (first records only)' or '',
                       e.approx and ' (approximate match)' or '')
end

-- every free holder is held to burrows (his own or the civ alert's): the free items inside them (DF's burrowed workers fetch
-- only those); e.inb = the count, nil when a free holder may go anywhere
function J.burrow_inputs(wk, ins)
  if not wk or wk.free == 0 or wk.unlimited or #wk.lims == 0 then return end
  local ids, seen = {}, {}
  for _, l in ipairs(wk.lims) do for _, id in ipairs(l) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end end
  for _, e in ipairs(ins or {}) do
    if e.free > 0 and #e._pts == e.free then              -- every free one known by position
      local n, sure = 0, true
      for _, p in ipairs(e._pts) do
        local yes = in_burrows(ids, p)
        if yes == nil then sure = false elseif yes then n = n + 1 end
      end
      if sure then e.inb = n end
    end
  end
end

-- the input cause: nil when every missing item has a free one (or unknown), else code, text
function J.input_cause(ins)
  for _, e in ipairs(ins or {}) do
    if not e.unknown and e.free > 0 and e.inb == 0 then
      return 'input_burrow', J.input_text(e) .. ': none inside the burrows the free holders are held to'
    end
    if not e.unknown and not e.clipped and e.free == 0 then
      if e.unverified then
        return 'scan_unreliable', J.input_text(e) .. ' (the scan may be wrong: not a proven cause; the own cancel reason of DF leads)'
      end
      if e.match == 0 and (e.cens or 0) >= 10 then
        return 'scan_unreliable', string.format('census holds %d, the scan found none: %s (the scan may be wrong: not a proven cause)', e.cens, J.input_text(e))
      end
      if e.match == 0 then                           -- a looser match (approx) finding none is still none
        return e.container and 'no_container' or 'no_input', 'none: ' .. J.input_text(e)
      end
      local best, bn = 'input_forbidden', e.forbid
      if e.claimed > bn then best, bn = 'input_claimed', e.claimed end
      if e.far > bn then best = 'input_far' end
      return best, J.input_text(e)
    end
  end
  return nil
end

---------------------------------------------------------------- one job
local function job_label(j)
  local tn = ename(df.job_type, j.job_type) or '?'
  local rn = pget(function() return j.reaction_name end)
  if tn == 'CustomReaction' and type(rn) == 'string' and rn ~= '' then return rn end
  return tn
end

function J.job(K, j, ctx, s)
  local r = {kind = 'job', id = int(j.id), job = job_label(j)}
  local b = pget(dfhack.job.getHolder, j)
  s = s or (b and J.shop(b, K)) or nil
  if s then r.shop, r.at = s.id, s.at
  else
    local p = pget(function() return j.pos end)
    if p and int(p.x) then r.at = {p.x, p.y, p.z} end
  end
  local w = pget(dfhack.job.getWorker, j)
  if w ~= nil then
    r.cause, r.text = 'working', string.format('%s %d works it', uname(w), w.id)
    return r
  end
  local labors, sk = J.labors(j.job_type, pget(function() return j.reaction_name end), pget(function() return j.mat_type end),
                              pget(function() return j.mat_index end), s and s.key)
  local wk = labors and J.workers(K, labors, sk, s, ctx) or nil
  local ins = J.inputs(K, j, s, ctx)
  if wk then r.workers = {n = wk.n, free = wk.free, by = wk.by, who = wk.who, labor = labor_names(labors)} end
  if ins then r.inputs = ins end
  local facts = {}
  if wk then facts[#facts + 1] = J.workers_text(wk, labors) end
  for _, e in ipairs(ins or {}) do facts[#facts + 1] = J.input_text(e) end
  local susp = pget(function() return j.flags.suspend end) == true
  J.burrow_inputs(wk, ins)
  local wc, wt = J.worker_cause(wk, labors)
  local ic, it = J.input_cause(ins)
  if susp then
    r.cause, r.text = 'suspended', 'the job is suspended' .. (#facts > 0 and ('; ' .. table.concat(facts, '; ')) or '')
  elseif wc then r.cause, r.text = wc, wt .. (ic and ('; ' .. it) or '')
  elseif ic then r.cause, r.text = ic, it .. (wk and ('; ' .. J.workers_text(wk, labors)) or '')
  else
    -- unknown: say only what was read (BUG-817: an unread job_items list once read as 'the inputs lie free')
    local sure = ins ~= nil
    for _, e in ipairs(ins or {}) do if e.unknown or e.clipped then sure = false end end
    local who = not wk and 'the labor this job needs is not known'
                or (wk.free or 0) > 0 and 'a free holder reaches it' or 'no holder is named as blocked'
    local what = ins == nil and 'its inputs not read' or not sure and 'its inputs not fully read'
                 or 'the inputs lie free: DF has not given it out (cooldown, path cost?)'
    r.cause = 'unknown'
    r.text = who .. '; ' .. what .. (#facts > 0 and ('; ' .. table.concat(facts, '; ')) or '')
  end
  return r
end

---------------------------------------------------------------- one order
local function shops_all()
  local r = {}
  for _, cat in ipairs({'WORKSHOP_ANY', 'FURNACE_ANY'}) do
    for _, b in ipairs(each(pget(function() return df.global.world.buildings.other[cat] end))) do r[#r + 1] = b end
  end
  return r
end

local function built(b)
  local st = pget(function() return b:getBuildStage() end)
  local mx = pget(function() return b:getMaxBuildStage() end)
  if st == nil or mx == nil then return true end
  return st >= mx
end

-- the open jobs of order `oid` in the workshops (job.order_id), with their shop records
function J.order_jobs(oid)
  local r = {}
  for _, b in ipairs(shops_all()) do
    for _, j in ipairs(each(pget(function() return b.jobs end))) do
      if int(pget(function() return j.order_id end)) == oid then r[#r + 1] = {j = j, b = b} end
    end
  end
  return r
end

-- the workshop keys ('workshop:Still') an order / job of `tn` (reaction `rn`, material class `mc`) runs in; nil = unknown
function J.shop_keys(tn, rn, mt, mi)
  if tn == 'CustomReaction' then
    local rx = J.reaction(rn)
    return rx and #rx.ws > 0 and rx.ws or nil
  end
  local mc = mat_class(mt, mi)
  return O.workshops(tn, mc or 'any') or (mc == nil and O.workshops(tn, 'rock')) or nil
end

-- BUG-836: the manager order's item conditions read like the job items (same field names): {text, met} per condition; met = nil when the
-- count could not be made. Counted over the item vector, not by rotten / hostile / building items (SKIP); DF's own count can differ.
local CMP = {AtLeast = function(n, v) return n >= v end, AtMost = function(n, v) return n <= v end, GreaterThan = function(n, v) return n > v end,
             LessThan = function(n, v) return n < v end, Exactly = function(n, v) return n == v end, NotExactly = function(n, v) return n ~= v end}
function J.conditions(o, ctx)
  local out = {}
  local cap = math.max(100, int(ctx and ctx.items_max) or J.ITEMS_MAX)
  for _, c in ipairs(each(pget(function() return o.item_conditions end))) do
    local cmp = pget(function() return c.compare_type end) or pget(function() return c.condition end)
    cmp = tostring(cmp or 'AtLeast')
    local val = int(pget(function() return c.compare_val end)) or int(pget(function() return c.value end)) or 0
    local it = pget(function() return c.item_type end)
    if type(it) == 'string' then it = df.item_type[it] end
    it = int(it) or -1
    local what = it >= 0 and ename(df.item_type, it) or nil
    local rp = pget(function() return c.has_material_reaction_product end)
    local e = {text = string.format('%s %d %s%s', cmp, val, what and what:lower() or 'any item', (rp and tostring(rp) ~= '') and (' (' .. tostring(rp) .. ')') or '')}
    local vec = what and pget(function() return df.global.world.items.other[what] end)
    local f = CMP[cmp]
    if vec and f then
      local n = 0
      local okscan = pcall(function()
        local seen = 0
        for _, item in ipairs(vec) do
          seen = seen + 1
          if seen > cap then error('clipped') end
          local skip = false
          for _, k in ipairs(SKIP) do if item.flags[k] == true then skip = true; break end end
          if not skip and item_fits(c, item) then n = n + (int(pget(function() return item:getStackSize() end)) or 1) end
        end
      end)
      if okscan then
        e.n, e.met = n, f(n, val); e.text = e.text .. string.format(': %d found', n)
        -- BUG-836 retry: a scan that finds none where the census holds many is not a proof (Run 17: 'plant (DRINK_MAT) x1: 0 match' beside 6,932)
        local cens = J.census_count(ctx and ctx.inv, {what = what:lower() .. (rp and tostring(rp):find('DRINK_MAT', 1, true) and ' DRINK_MAT' or '')})
        if n == 0 and (cens or 0) >= 10 then
          e.met, e.cens = nil, cens
          e.text = e.text .. string.format(' (census holds %d: the scan may be wrong)', cens)
        end
      end
    elseif it < 0 then
      -- 'empty food_storage' (the kernel's own brew condition has no item_type): read against the census empties
      local f1, f3 = pget(function() return c.flags1 end), pget(function() return c.flags3 end)
      local empty = f1 and pget(function() return f1.empty end) == true
      local store = f3 and pget(function() return f3.food_storage end) == true
      local inv = ctx and ctx.inv
      if empty and store and f and type(inv) == 'table' then
        local ce = int(inv.cont_free) or int(inv.barrels_empty)
        if ce then
          e.text = 'AtLeast ' .. tostring(val) .. ' empty food storage item'
          e.cens = ce
          -- the census count is what we have; DF counts its own way, so it is a hint, never a met / unmet verdict
          e.text = e.text .. string.format(': %d empty by the census (DF counts its own way)', ce)
        end
      end
    end
    out[#out + 1] = e
  end
  return out
end

function J.order(K, o, ctx)
  local tn = ename(df.job_type, o.job_type) or '?'
  local rn = pget(function() return o.reaction_name end)
  local r = {kind = 'order', id = int(o.id), job = (tn == 'CustomReaction' and type(rn) == 'string' and rn ~= '') and rn or tn,
             left = int(o.amount_left) or 0}
  if r.left <= 0 then r.cause, r.text = 'done', 'nothing left to make'; return r end
  if pget(function() return o.status.validated end) == false then
    local mf = ctx and ctx.manager and pget(ctx.manager) or nil
    local why = mf and mf.causes and mf.causes[1]
    if mf and not why and mf.job and mf.job ~= 'none' then why = 'the manager works as ' .. tostring(mf.job) .. ', not at his office' end     -- BUG-837
    if mf and not mf.unit then r.cause = 'no_manager'
    else r.cause = 'not_validated' end
    r.text = 'the manager has not validated it' .. (why and (': ' .. tostring(why)) or (mf and '' or ' (manager not read)'))
    return r
  end
  local jobs = J.order_jobs(r.id)
  for _, e in ipairs(jobs) do
    local w = pget(dfhack.job.getWorker, e.j)
    if w ~= nil then
      r.cause, r.text = 'working', string.format('%s %d works its job %d', uname(w), w.id, int(e.j.id) or -1)
      return r
    end
  end
  if #jobs > 0 then
    local sub = J.job(K, jobs[1].j, ctx, J.shop(jobs[1].b, K))
    r.sub, r.cause, r.shop, r.at = sub, sub.cause, sub.shop, sub.at
    r.text = string.format('%d %s, none worked; job %d: %s', #jobs, plural(#jobs, 'job'), sub.id or -1, sub.text)
    return r
  end
  local wid = int(pget(function() return o.workshop_id end)) or -1
  local cand = {}
  if wid >= 0 then
    local b = pget(df.building.find, wid)
    if not b then r.cause, r.text = 'pinned', string.format('pinned to workshop %d, which is gone', wid); return r end
    cand[1] = J.shop(b, K)
  else
    local keys = J.shop_keys(tn, rn, pget(function() return o.mat_type end), pget(function() return o.mat_index end))
    if keys then
      local want = {}
      for _, k in ipairs(keys) do want[k] = true end
      for _, b in ipairs(shops_all()) do
        if built(b) then
          local s = J.shop(b, K)
          if s.key and want[s.key] then cand[#cand + 1] = s end
        end
      end
      if #cand == 0 then r.cause, r.text = 'no_workshop', 'no built ' .. table.concat(keys, ' or '); return r end
    end
  end
  if #cand > 0 then
    local closed, full = 0, 0
    for _, s in ipairs(cand) do
      if s.prof and s.prof.maxg and s.prof.maxg < 1 then closed = closed + 1 end
      if s.njobs >= J.SHOP_MAX_JOBS then full = full + 1 end
    end
    r.shop, r.at = cand[1].id, cand[1].at
    if closed == #cand then
      r.cause, r.text = 'profile_orders', string.format('%d fitting %s take no general orders (max_general_orders 0)', #cand, plural(#cand, 'workshop'))
      return r
    end
    if full == #cand then
      r.cause, r.text = 'shop_full', string.format('%d fitting %s hold %d jobs each (the most DF allows)', #cand, plural(#cand, 'workshop'), J.SHOP_MAX_JOBS)
      return r
    end
  end
  local nc = #each(pget(function() return o.item_conditions end))
  local labors, sk = J.labors(o.job_type, rn, pget(function() return o.mat_type end), pget(function() return o.mat_index end), cand[1] and cand[1].key)
  local wk = labors and J.workers(K, labors, sk, cand[1], ctx) or nil
  local wtxt = wk and ('; ' .. J.workers_text(wk, labors)) or ''
  if wk then r.workers = {n = wk.n, free = wk.free, by = wk.by, who = wk.who, labor = labor_names(labors)} end
  -- BUG-836: nobody holds the labor: that is the cause, whatever else the order lacks
  local wc, wct = J.worker_cause(wk, labors)
  if nc > 0 then
    local cl = J.conditions(o, ctx)
    local unmet = {}
    for _, e in ipairs(cl) do if e.met == false then unmet[#unmet + 1] = e.text end end
    if #unmet > 0 then
      r.cause = 'cond_unmet'
      r.text = string.format('no job made: item condition not met: %s%s', table.concat(unmet, '; '):sub(1, 300), wtxt)
    elseif wc == 'no_labor' then r.cause, r.text = wc, wct
    else
      local all = {}
      for _, e in ipairs(cl) do all[#all + 1] = e.text end
      r.cause = 'conditions'
      r.text = string.format('no job made: %d item %s by my count met (%s), DF counts items its own way%s', nc, plural(nc, 'condition'),
                             table.concat(all, '; '):sub(1, 300), wtxt)
    end
    return r
  end
  if wc == 'no_labor' then r.cause, r.text = wc, wct; return r end
  r.cause, r.text = 'unknown', 'validated, a workshop has room, no condition, no job yet (the manager makes jobs on his own pace)' .. wtxt
  return r
end

---------------------------------------------------------------- a workshop, a kind, a key
function J.workshop(K, b, ctx)
  local s = J.shop(b, K)
  local jobs = each(pget(function() return b.jobs end))
  local r = {kind = 'shop', id = s.id, job = s.type or '?', shop = s.id, at = s.at}
  local worked = 0
  for _, j in ipairs(jobs) do
    if pget(dfhack.job.getWorker, j) == nil then
      local sub = J.job(K, j, ctx, s)
      r.sub, r.cause = sub, sub.cause
      r.text = string.format('%s %d (%d %s, %d worked); job %d %s: %s', s.type or '?', s.id or -1, #jobs, plural(#jobs, 'job'), worked,
                             sub.id or -1, sub.job, sub.text)
      return r
    end
    worked = worked + 1
  end
  if #jobs > 0 then r.cause, r.text = 'working', string.format('all %d %s worked', #jobs, plural(#jobs, 'job')); return r end
  for _, o in ipairs(each(pget(function() return df.global.world.manager_orders.all end))) do
    if (int(o.amount_left) or 0) > 0 then
      local tn = ename(df.job_type, o.job_type)
      local keys = tn and J.shop_keys(tn, pget(function() return o.reaction_name end), o.mat_type, o.mat_index)
      local wid = int(pget(function() return o.workshop_id end)) or -1
      local fits = wid == s.id
      for _, k in ipairs(keys or {}) do if k == s.key and wid < 0 then fits = true end end
      if fits then
        local sub = J.order(K, o, ctx)
        r.sub, r.cause = sub, sub.cause
        r.text = string.format('%s %d has no job; order %d %s: %s', s.type or '?', s.id or -1, sub.id or -1, sub.job, sub.text)
        return r
      end
    end
  end
  r.cause, r.text = 'no_order', string.format('%s %d has no job and no open order fits it', s.type or '?', s.id or -1)
  return r
end

local function kind_pred(key)
  local f = J.KINDS[key]
  if f then return f end
  if df.job_type[key] ~= nil and type(df.job_type[key]) == 'number' then return function(tn) return tn == key end end
  return nil
end

-- every unworked workshop job of a kind (the concrete stall), then every open order of it: the first that does not run, else the first
function J.kind(K, key, ctx)
  local pred = kind_pred(key)
  if not pred then return nil, 'unknown kind ' .. tostring(key) end
  local first, n = nil, 0
  for _, b in ipairs(shops_all()) do
    for _, j in ipairs(each(pget(function() return b.jobs end))) do
      if n < 12 and pred(ename(df.job_type, j.job_type), pget(function() return j.reaction_name end)) then
        n = n + 1
        local r = J.job(K, j, ctx)
        first = first or r
        if r.cause ~= 'working' then return r end
      end
    end
  end
  for _, o in ipairs(each(pget(function() return df.global.world.manager_orders.all end))) do
    if n < 18 and (int(o.amount_left) or 0) > 0 and pred(ename(df.job_type, o.job_type), pget(function() return o.reaction_name end)) then
      n = n + 1
      local r = J.order(K, o, ctx)
      first = first or r
      if r.cause ~= 'working' then return r end
    end
  end
  if first then return first end
  return {kind = 'kind', id = 0, job = key, cause = 'none_open', text = 'no open order and no job of this kind'}
end

-- causes read off the game that name a blocker (the others: running, nothing open, or not proven)
J.NOT_PROVEN = {unknown = true, working = true, conditions = true, none_open = true, done = true, scan_unreliable = true}
function J.proven(r) return type(r) == 'table' and r.cause ~= nil and not J.NOT_PROVEN[r.cause] end

local function find_job(id)
  for _, b in ipairs(shops_all()) do
    for _, j in ipairs(each(pget(function() return b.jobs end))) do if int(j.id) == id then return j end end
  end
  return pget(function()
    local link, i = df.global.world.jobs.list.next, 0
    while link and i < 20000 do
      local j = link.item
      if j and j.id == id then return j end
      link, i = link.next, i + 1
    end
  end)
end

local function find_order(id)
  for _, o in ipairs(each(pget(function() return df.global.world.manager_orders.all end))) do if int(o.id) == id then return o end end
end

local function find_shop(id)
  local b = pget(df.building.find, id)
  if b then
    local bt = pget(function() return b:getType() end)
    if bt == df.building_type.Workshop or bt == df.building_type.Furnace then return b end
  end
end

-- NEU4 BUG-841: DF's own reason. The job kinds DF names in "<unit> cancels <job>: <reason>": brew -> every 'brew ...'; a job type -> its caption
-- ('Make barrel' matches 'make wooden barrel': first and last word); a workshop -> the jobs of its type (not matched: no job type)
function J.df_match(r)
  local job = tostring(r.job or '')
  if J.KINDS.brew(nil, job) or job == 'BrewDrink' or job == 'brew' then return {'brew '} end
  if job == 'fish' then return {'prepare raw fish', 'clean fish'} end
  if job == 'cook' then return {'prepare '} end
  local cap
  local jt = pget(function() return df.job_type[job] end)
  if type(jt) == 'number' then cap = pget(function() return df.job_type.attrs[jt].caption end) end
  if type(cap) ~= 'string' or cap == '' then cap = job:gsub('(%l)(%u)', '%1 %2') end
  cap = cap:lower()
  local first, last = cap:match('^(%S+)'), cap:match('(%S+)$')
  if not first then return nil end
  return function(kind) return kind:sub(1, #first) == first and kind:sub(-#last) == last end
end

-- the result r (and its sub) carries DF's reason when the cancel tally has one: r.df = {why, n, days, last, text}; a cause that is only a guess
-- (unknown, conditions, ...) becomes 'df_reason' with DF's words first
function J.attach_df(r, ctx)
  if type(r) ~= 'table' or type(ctx) ~= 'table' or type(ctx.df) ~= 'function' then return r end
  local m = J.df_match(r)
  local e = m and pget(ctx.df, m)
  if e and (e.n or 0) > 0 then
    r.df = {why = e.why, n = e.n, days = e.days, last = e.last, text = e.text}
    r.text = (e.text or '') .. ' | ' .. (r.text or '')
    if r.cause == nil or J.NOT_PROVEN[r.cause] and r.cause ~= 'working' and r.cause ~= 'done' and r.cause ~= 'none_open' then r.cause = 'df_reason' end
  end
  if not (e and (e.n or 0) > 0) and type(ctx.health) == 'function' then     -- NEU5 BUG-847: no reason: say whether the reader sees anything at all
    local h = pget(ctx.health)
    if type(h) == 'string' and h ~= '' then r.dfh = h end
  end
  if type(r.sub) == 'table' then J.attach_df(r.sub, ctx) end
  return r
end

-- key: 'ws:<id>' | 'bld:<id>' | 'shop:<id>' | 'order:<id>' | 'job:<id>' | <id> (order, then workshop, then job) | a kind
-- -> result or nil, error
function J.find(K, key, ctx)
  local r, err = J.find0(K, key, ctx)
  if r and r.kind ~= 'workshop' then J.attach_df(r, ctx) end
  return r, err
end
function J.find0(K, key, ctx)
  local s = tostring(key or ''):gsub('^%s+', ''):gsub('%s+$', '')
  local pre, num = s:match('^(%a+):(%d+)$')
  local id = int(num) or int(s:match('^(%d+)$'))
  if pre then
    pre = pre:lower()
    if pre == 'ws' or pre == 'bld' or pre == 'shop' then
      local b = find_shop(id)
      if not b then
        -- NEU5 BUG-848: a stockpile id is no workshop: say so and name the dump that takes it
        for _, sp in ipairs(each(pget(function() return df.global.world.buildings.other.STOCKPILE end))) do
          if pget(function() return sp.id end) == id then
            return nil, 'building ' .. tostring(id) .. ' is a stockpile, not a workshop: why ' .. tostring(id) .. ' --raw (key pile:' .. tostring(id) .. ') dumps it'
          end
        end
        return nil, 'no workshop or furnace ' .. tostring(id)
      end
      return J.workshop(K, b, ctx)
    elseif pre == 'order' then
      local o = find_order(id)
      if not o then return nil, 'no manager order ' .. tostring(id) end
      return J.order(K, o, ctx)
    elseif pre == 'job' then
      local j = find_job(id)
      if not j then return nil, 'no job ' .. tostring(id) end
      return J.job(K, j, ctx)
    end
    return nil, 'prefix ' .. pre .. ': ws, order or job'
  end
  if id then
    local o = find_order(id)
    if o then local r = J.order(K, o, ctx); r.guess = 'order'; return r end
    local b = find_shop(id)
    if b then local r = J.workshop(K, b, ctx); r.guess = 'shop'; return r end
    local j = find_job(id)
    if j then local r = J.job(K, j, ctx); r.guess = 'job'; return r end
    return nil, 'no order, workshop or job ' .. tostring(id)
  end
  if s == '' then return nil, 'key: ws:<id>, order:<id>, job:<id>, brew, fish, cook or a job type' end
  return J.kind(K, J.KINDS[s:lower()] and s:lower() or s, ctx)
end

-- one line: '<kind> <id> <job>: <cause>: <text>'
function J.line(r)
  local text = r.text or ''
  local lead = ''
  -- NEU5 BUG-847: DF's own reason is the first thing of the line (attach_df put it first in the text; the kind / id / cause follow)
  local dt = type(r.df) == 'table' and r.df.text
  if type(dt) == 'string' and dt ~= '' then
    if text:sub(1, #dt + 3) == dt .. ' | ' then text = text:sub(#dt + 4) elseif text == dt then text = '' end
    lead = dt .. ' | '
  end
  local tail = (not dt and type(r.dfh) == 'string') and (' | ' .. r.dfh) or ''
  return lead .. string.format('%s %s %s%s: %s: %s', r.kind, tostring(r.id), tostring(r.job), r.at and (' at ' .. at_text(r.at)) or '', r.cause,
                               text) .. tail
end

local function ins_data(ins)
  if not ins then return nil end
  local out = {}
  for i, e in ipairs(ins) do
    local c = {}
    for k, v in pairs(e) do if k ~= '_pts' then c[k] = v end end
    out[i] = c
  end
  return out
end

-- the result without the nested job / order records, small enough for an event or the outbox (sub kept one level)
function J.data(r)
  local function flat(x)
    return {kind = x.kind, id = x.id, job = x.job, cause = x.cause, text = (x.text or ''):sub(1, 400), shop = x.shop, at = x.at,
            left = x.left, workers = x.workers, inputs = ins_data(x.inputs), guess = x.guess, df = x.df, dfh = x.dfh}
  end
  local d = flat(r)
  if r.sub then d.sub = flat(r.sub) end
  return d
end

-- NEU3: the helpers dfraw.lua (inspect what=raw) shares, so that both read the game the same way
J.util = {int = int, pget = pget, ename = ename, each = each, uname = uname, walk_groups = walk_groups, in_burrows = in_burrows, civ_burrows = civ_burrows,
          shops_all = shops_all, find_job = find_job, find_order = find_order, find_shop = find_shop, built = built, at_text = at_text}

return J
