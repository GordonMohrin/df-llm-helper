-- claude/positions                       - positions (nobles menu) and who holds them.
-- DEPRECATED (run 3): assign ONLY with claude/aemter from now on (this script did not set position_vector_idx/assignments_by_type -> ineffective).
-- claude/positions assign <position> <unit_id> - fill a position (as in the nobles menu), e.g. MANAGER.
-- claude/positions vacate <position>          - vacate a position.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local ent = df.historical_entity.find(df.global.plotinfo.group_id)
if not ent then util.emit({ error = 'keine Festungs-Gruppe gefunden' }) return end

local function holder(asg)
  if asg.histfig2 and asg.histfig2 >= 0 then
    local hf = df.historical_figure.find(asg.histfig2)
    local u = hf and df.unit.find(hf.unit_id)
    return u and { id = u.id, name = dfhack.units.getReadableName(u) } or { hf = asg.histfig2 }
  end
  return nil
end

local function positions()
  local out = {}
  for _, asg in ipairs(ent.positions.assignments) do
    local pos
    for _, p in ipairs(ent.positions.own) do if p.id == asg.position_id then pos = p end end
    out[#out + 1] = {
      code = pos and pos.code, name = pos and pos.name[0], assignment = asg.id,
      holder = holder(asg),
    }
  end
  return out
end

if a[1] == nil then util.emit({ positions = positions() }) return end

local code = a[2] and a[2]:upper()
local target
for _, asg in ipairs(ent.positions.assignments) do
  for _, p in ipairs(ent.positions.own) do
    if p.id == asg.position_id and p.code == code then target = asg end
  end
end
if not target then util.emit({ error = 'unbekanntes Amt: ' .. tostring(a[2]), positions = positions() }) return end

-- Filling as in the nobles menu: set the assignment and maintain the position link on the historical figure.
local function unlink(asg)
  local old = (asg.histfig2 and asg.histfig2 >= 0) and asg.histfig2 or asg.histfig
  local hf = old and old >= 0 and df.historical_figure.find(old)
  if hf then
    for k, v in ipairs(hf.entity_links) do
      if df.histfig_entity_link_positionst:is_instance(v) and v.assignment_id == asg.id
         and v.entity_id == ent.id then
        hf.entity_links:erase(k)
        v:delete()
        break
      end
    end
  end
  asg.histfig, asg.histfig2 = -1, -1
end

if (a[1] == 'assign' or a[1] == 'vacate') and not a.force then
  util.emit({ error = 'veraltet: bitte claude/aemter assign|vacate benutzen (siehe AEMTER.md)' }) return
end

if a[1] == 'assign' then
  local u = df.unit.find(tonumber(a[3]) or -1)
  if not u or not dfhack.units.isCitizen(u) then util.emit({ error = 'kein Buerger mit id ' .. tostring(a[3]) }) return end
  local hf = u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id)
  if not hf then util.emit({ error = 'Zwerg hat keine Geschichtsfigur' }) return end
  unlink(target)
  target.histfig, target.histfig2 = hf.id, hf.id
  local idx = 0
  for i, asg in ipairs(ent.positions.assignments) do if asg.id == target.id then idx = i - 1 end end
  hf.entity_links:insert('#', { new = df.histfig_entity_link_positionst, entity_id = ent.id,
    link_strength = 100, assignment_id = target.id, assignment_vector_idx = idx,
    start_year = df.global.cur_year })
  util.emit({ done = 'assign', positions = positions() })
elseif a[1] == 'vacate' then
  unlink(target)
  util.emit({ done = 'vacate', positions = positions() })
else
  util.emit({ error = 'unbekannter Unterbefehl' })
end
