-- claude/workdetail list
-- claude/workdetail assign <unit_id> <work_group> <true|false>
-- Corresponds to the work details menu (Labor -> Work Details) in the game.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local wds = df.global.plotinfo.labor_info.work_details
local M = df.work_detail_mode

local function labors(d)
  local out = {}
  for i = 0, #d.allowed_labors - 1 do
    if d.allowed_labors[i] then out[#out + 1] = df.unit_labor[i] end
  end
  return out
end

local function members(d)
  local out = {}
  for j = 0, #d.assigned_units - 1 do out[#out + 1] = d.assigned_units[j] end
  return out
end

-- May a dwarf perform a job according to all work details?
local function granted(uid, L)
  for i = 0, #wds - 1 do
    local d = wds[i]
    if d.allowed_labors[L] then
      if d.flags.mode == M.EverybodyDoesThis then return true end
      if d.flags.mode ~= M.NobodyDoesThis then
        for j = 0, #d.assigned_units - 1 do
          if d.assigned_units[j] == uid then return true end
        end
      end
    end
  end
  return false
end

if a[1] == nil or a[1] == 'list' then
  local out = {}
  for i = 0, #wds - 1 do
    local d = wds[i]
    out[#out + 1] = { name = d.name, mode = M[d.flags.mode], labors = labors(d), members = members(d) }
  end
  util.emit({ details = out })
  return
end

if a[1] == 'assign' then
  local uid, dname, enable = tonumber(a[2]), a[3], (a[4] == 'true' or a[4] == '1')
  local u = uid and df.unit.find(uid)
  if not u or not dfhack.units.isCitizen(u) then
    util.emit({ error = 'kein Buerger mit id ' .. tostring(a[2]) }) return
  end
  local d
  for i = 0, #wds - 1 do if wds[i].name == dname then d = wds[i] end end
  if not d then util.emit({ error = 'keine Arbeitsgruppe "' .. tostring(dname) .. '"' }) return end

  local idx
  for j = 0, #d.assigned_units - 1 do if d.assigned_units[j] == uid then idx = j end end
  if enable and not idx then d.assigned_units:insert('#', uid)
  elseif not enable and idx then d.assigned_units:erase(idx) end

  -- Recompute the dwarf's work permissions like the game does.
  for i = 0, #d.allowed_labors - 1 do
    if d.allowed_labors[i] then u.status.labors[i] = granted(uid, i) end
  end
  util.emit({ ok = true, unit = dfhack.units.getReadableName(u), detail = dname, member = enable,
              members = members(d) })
  return
end

util.emit({ error = 'unbekannter Unterbefehl: ' .. tostring(a[1]) })
