-- claude/aemter - fill positions (manager, broker, bookkeeper ...) via Lua, WITHOUT desktop control.
-- See dwarf-fortress/AEMTER.md (result, limits).
--
--   claude/aemter status                       - positions, holders, index fields, assignments_by_type, manager orders
--   claude/aemter assign <CODE> <unit_id> [--dry]  - fill a position (CODE e.g. MANAGER, BROKER, BOOKKEEPER)
--   claude/aemter vacate <CODE> [--dry]        - vacate a position
--   claude/aemter nolabors <unit_id> [--dry]   - switch off all labors of the office holder (old values in the log)
--   claude/aemter repair                       - rebuild assignments_by_type from the assignments (add only)
--
-- What the nobles menu does in addition to histfig/link (reproduced here):
--   * assignment.histfig AND histfig2, assignment.position_vector_idx (= index in positions.own)
--   * histfig.entity_links: histfig_entity_link_positionst (assignment_vector_idx = index in positions.assignments,
--     0-based! ipairs() yields 0-based indices in DFHack - the old claude/positions.lua computed i-1 = wrong)
--   * entity.assignments_by_type[<responsibility>] contains the assignment (the game checks MANAGE_PRODUCTION/TRADE/ACCOUNTING there)
-- Before every change the old state is written to tools/out/aemter-log.json (rollback: vacate or the values there).
-- Defensive: everything in pcall, --dry changes nothing.
local util = reqscript('claude/util')
local json = require('json')
if not util.require_fort() then return end

local LOG = reqscript('claude/util').home() .. '/tools/out/aemter-log.json'
local args = { ... }
local dry = false
local pos_args = {}
for _, a in ipairs(args) do
  if a == '--dry' then dry = true else pos_args[#pos_args + 1] = a end
end
local cmd, code_arg, uid_arg = pos_args[1], pos_args[2], pos_args[3]

local ent = df.historical_entity.find(df.global.plotinfo.group_id)
if not ent then util.emit({ error = 'keine Festungs-Gruppe gefunden' }) return end

local function log(t)
  pcall(function()
    t.time = os.date('%Y-%m-%d %H:%M:%S'); t.tick = df.global.cur_year_tick; t.year = df.global.cur_year
    local f = io.open(LOG, 'a'); if f then f:write(json.encode(t), '\n'); f:close() end
  end)
end

local function find_own(pos_id)
  for i = 0, #ent.positions.own - 1 do
    if ent.positions.own[i].id == pos_id then return i, ent.positions.own[i] end
  end
end

local function find_asg(code)
  for i = 0, #ent.positions.assignments - 1 do
    local asg = ent.positions.assignments[i]
    local oi, pos = find_own(asg.position_id)
    if pos and pos.code == code then return i, asg, oi, pos end
  end
end

local function responsibilities(pos)
  local out = {}
  for k, v in pairs(pos.responsibilities) do
    if v then out[#out + 1] = k end
  end
  return out
end

local function by_type_has(rk, asg)
  local vec = ent.assignments_by_type[rk]
  for i = 0, #vec - 1 do if vec[i].id == asg.id then return i end end
end

local function by_type_add(pos, asg)
  for _, rk in ipairs(responsibilities(pos)) do
    if not by_type_has(rk, asg) then ent.assignments_by_type[rk]:insert('#', asg) end
  end
end

local function by_type_remove(pos, asg)
  for _, rk in ipairs(responsibilities(pos)) do
    local i = by_type_has(rk, asg)
    if i then ent.assignments_by_type[rk]:erase(i) end
  end
end

local function unit_of_hf(hfid)
  local hf = hfid and hfid >= 0 and df.historical_figure.find(hfid)
  return hf and df.unit.find(hf.unit_id)
end

local function holder_info(asg)
  local hfid = (asg.histfig2 >= 0) and asg.histfig2 or asg.histfig
  if hfid < 0 then return nil end
  local u = unit_of_hf(hfid)
  return u and { id = u.id, name = dfhack.units.getReadableName(u), hf = hfid } or { hf = hfid }
end

local function status()
  local out = { positions = {} }
  for i = 0, #ent.positions.assignments - 1 do
    local asg = ent.positions.assignments[i]
    local oi, pos = find_own(asg.position_id)
    local resp, inbt = {}, {}
    if pos then
      for _, rk in ipairs(responsibilities(pos)) do
        resp[#resp + 1] = df.entity_position_responsibility[rk]
        inbt[#inbt + 1] = by_type_has(rk, asg) ~= nil
      end
    end
    out.positions[#out.positions + 1] = {
      code = pos and pos.code, idx = i, assignment = asg.id, holder = holder_info(asg),
      histfig = asg.histfig, histfig2 = asg.histfig2, position_vector_idx = asg.position_vector_idx,
      own_idx = oi, responsibilities = resp, in_assignments_by_type = inbt,
      required_office = pos and pos.required_office,
    }
  end
  out.orders = {}
  for i = 0, #df.global.world.manager_orders.all - 1 do
    local o = df.global.world.manager_orders.all[i]
    out.orders[#out.orders + 1] = { id = o.id, job = df.job_type[o.job_type], validated = o.status.validated,
                                    active = o.status.active, left = o.amount_left }
  end
  return out
end

local function unlink(asg, pos)
  local old = (asg.histfig2 >= 0) and asg.histfig2 or asg.histfig
  local hf = old >= 0 and df.historical_figure.find(old)
  if hf then
    for k = #hf.entity_links - 1, 0, -1 do
      local v = hf.entity_links[k]
      if df.histfig_entity_link_positionst:is_instance(v) and v.assignment_id == asg.id and v.entity_id == ent.id then
        hf.entity_links:erase(k)
        v:delete()
      end
    end
  end
  if pos then by_type_remove(pos, asg) end
  asg.histfig, asg.histfig2 = -1, -1
  asg.position_vector_idx = -1
end

local function do_assign(code, uid)
  local ai, asg, oi, pos = find_asg(code)
  if not asg then return { error = 'unbekanntes Amt: ' .. tostring(code) } end
  local u = df.unit.find(tonumber(uid) or -1)
  if not u or not dfhack.units.isCitizen(u) or not dfhack.units.isActive(u) then
    return { error = 'kein aktiver Buerger mit id ' .. tostring(uid) }
  end
  local hf = u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id)
  if not hf then return { error = 'Zwerg hat keine Geschichtsfigur' } end
  -- The unit must not already hold this position elsewhere (avoid double holders)
  local plan = { code = code, unit = u.id, name = dfhack.units.getReadableName(u), hf = hf.id,
                 asg_idx = ai, own_idx = oi, old = holder_info(asg), dry = dry }
  if dry then plan.would = 'assign'; return plan end
  log({ action = 'assign', code = code, asg_id = asg.id, old_histfig = asg.histfig, old_histfig2 = asg.histfig2,
        old_position_vector_idx = asg.position_vector_idx, new_unit = u.id, new_hf = hf.id })
  unlink(asg, pos)
  asg.histfig, asg.histfig2 = hf.id, hf.id
  asg.position_vector_idx = oi
  hf.entity_links:insert('#', { new = df.histfig_entity_link_positionst, entity_id = ent.id,
    entity_vector_idx = ent.id, link_strength = 100, assignment_id = asg.id, assignment_vector_idx = ai,
    start_year = df.global.cur_year })
  by_type_add(pos, asg)
  local nobles = {}
  for _, n in ipairs(dfhack.units.getNoblePositions(u) or {}) do nobles[#nobles + 1] = n.position.code end
  plan.done = 'assign'; plan.nobles_after = nobles
  return plan
end

local function do_vacate(code)
  local ai, asg, oi, pos = find_asg(code)
  if not asg then return { error = 'unbekanntes Amt: ' .. tostring(code) } end
  local res = { code = code, old = holder_info(asg), dry = dry }
  if dry then res.would = 'vacate'; return res end
  log({ action = 'vacate', code = code, asg_id = asg.id, old_histfig = asg.histfig, old_histfig2 = asg.histfig2,
        old_position_vector_idx = asg.position_vector_idx })
  unlink(asg, pos)
  res.done = 'vacate'
  return res
end

local function do_repair()
  local n = 0
  for i = 0, #ent.positions.assignments - 1 do
    local asg = ent.positions.assignments[i]
    local _, pos = find_own(asg.position_id)
    if pos and (asg.histfig >= 0 or asg.histfig2 >= 0) then
      for _, rk in ipairs(responsibilities(pos)) do
        if not by_type_has(rk, asg) then
          n = n + 1
          if not dry then ent.assignments_by_type[rk]:insert('#', asg) end
        end
      end
    end
  end
  return { repaired = n, dry = dry }
end

-- Office holders must not work (otherwise the manager does not validate / the broker does not go to the depot): labors off, old values into the log.
local function do_nolabors(uid)
  local u = df.unit.find(tonumber(uid) or -1)
  if not u or not dfhack.units.isCitizen(u) then return { error = 'kein Buerger mit id ' .. tostring(uid) } end
  local old = {}
  for i = 0, #u.status.labors - 1 do if u.status.labors[i] then old[#old + 1] = df.unit_labor[i] end end
  if dry then return { unit = u.id, would = 'clear', labors = #old, dry = true } end
  log({ action = 'nolabors', unit = u.id, old_labors = old })
  for i = 0, #u.status.labors - 1 do u.status.labors[i] = false end
  return { unit = u.id, done = 'nolabors', cleared = #old }
end

local ok, res = pcall(function()
  if cmd == nil or cmd == 'status' then return status()
  elseif cmd == 'assign' then return do_assign(code_arg and code_arg:upper(), uid_arg)
  elseif cmd == 'vacate' then return do_vacate(code_arg and code_arg:upper())
  elseif cmd == 'repair' then return do_repair()
  elseif cmd == 'nolabors' then return do_nolabors(code_arg)
  else return { error = 'unbekannter Befehl (status|assign|vacate|repair|nolabors)' } end
end)
if not ok then res = { error = 'Ausnahme: ' .. tostring(res) } end
if cmd == 'assign' or cmd == 'vacate' or cmd == 'repair' then
  if not dry and not res.error then res.status = status() end
end
util.emit(res)
