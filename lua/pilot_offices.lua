-- claude/pilot_offices status          (df-llm-helper FEATURE-001 offices watch, LIVE-UNTESTED)
-- status: READ ONLY. One call for `python -m df_llm_helper offices`:
--   positions: every position assignment of the fort entity (code, holder histfig, holder unit with fitness fields,
--              dead flag when the assignment still points at a dead histfig - Run 5: captain, commander and chief
--              medical dwarf stayed assigned to dead units through a whole siege)
--   citizens:  living citizens with the fields the successor score needs (skills, stress, mood, wounds, squad,
--              profession, care labors, pickaxe, offices held, depot reachable)
--   patients:  number of citizens that cannot stand or rest in bed (a doctor is not taken away from them)
-- Writes nothing. Appointing goes through claude/aemter assign/vacate (the nobles menu equivalent), never from here.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'status'

local function safe(f, d) local ok, v = pcall(f) if ok and v ~= nil then return v end return d end

local SKILLS = { 'APPRAISAL', 'NEGOTIATION', 'JUDGING_INTENT', 'LEADERSHIP', 'ORGANIZATION', 'RECORD_KEEPING',
                 'TEACHING', 'DISCIPLINE', 'MILITARY_TACTICS', 'MELEE_COMBAT', 'AXE', 'SWORD', 'MACE', 'HAMMER',
                 'SPEAR', 'CROSSBOW', 'DIAGNOSE', 'SURGERY', 'SET_BONE', 'SUTURE', 'DRESS_WOUNDS' }
local CARE = { 'DIAGNOSE', 'SURGERY', 'BONE_SETTING', 'SUTURING', 'DRESSING_WOUNDS', 'FEED_WATER_CIVILIANS' }

local function is_dead(u)
  if safe(function() return dfhack.units.isDead(u) end, false) then return true end
  return not safe(function() return dfhack.units.isAlive(u) end, true)
end

local function has_pick(u)
  for _, inv in ipairs(safe(function() return u.inventory end, {})) do
    local it = inv.item
    if safe(function() return it:getType() == df.item_type.WEAPON and it.subtype.skill_melee == df.job_skill.MINING end,
            false) then
      return true
    end
  end
  return false
end

-- first trade depot (center tile) for the broker's reachability
local DEPOT = nil
for _, b in ipairs(safe(function() return df.global.world.buildings.other.TRADE_DEPOT end, {})) do
  DEPOT = xyz2pos(b.centerx, b.centery, b.z)
  break
end

local function depot_reach(u)
  if not DEPOT then return nil end
  return safe(function() return dfhack.maps.canWalkBetween(xyz2pos(u.pos.x, u.pos.y, u.pos.z), DEPOT) end, false)
end

local function offices_of(u)
  local out = {}
  for _, p in ipairs(safe(function() return dfhack.units.getNoblePositions(u) end, nil) or {}) do
    local c = safe(function() return p.position.code end, nil)
    if c then out[#out + 1] = c end
  end
  return out
end

-- every field the Python side needs to judge a holder or a candidate
local function info(u)
  local j = safe(function() return u.job.current_job end, nil)
  local job = j and safe(function() return df.job_type[j.job_type] end, '?') or nil
  local skills = {}
  for _, s in ipairs(SKILLS) do
    local v = safe(function() return dfhack.units.getNominalSkill(u, df.job_skill[s]) end, 0)
    if v > 0 then skills[s] = v end
  end
  local care = 0
  for _, L in ipairs(CARE) do
    if safe(function() return u.status.labors[df.unit_labor[L]] end, false) then care = care + 1 end
  end
  local cant_stand = safe(function() return u.status2.limbs_stand_count == 0 end, false)
  return {
    id = u.id, name = dfhack.units.getReadableName(u), hf = safe(function() return u.hist_figure_id end, -1),
    prof = safe(function() return dfhack.units.getProfessionName(u) end, '?'),
    alive = not is_dead(u), citizen = safe(function() return dfhack.units.isCitizen(u) end, false),
    adult = safe(function() return dfhack.units.isAdult(u) end, true),
    mood = safe(function() return u.mood >= 0 end, false),
    stress = safe(function() return u.status.current_soul.personality.stress end, 0),
    wounds = safe(function() return #u.body.wounds end, 0), cant_stand = cant_stand,
    patient = cant_stand or job == 'Rest', job = job,
    prisoner = safe(function() return u.flags1.caged or u.flags1.chained end, false),
    squad = safe(function() return u.military.squad_id ~= -1 end, false),
    squad_leader = safe(function() return u.military.squad_id ~= -1 and u.military.squad_position == 0 end, false),
    skills = skills, care = care, pick = has_pick(u), offices = offices_of(u), depot_reach = depot_reach(u),
  }
end

if cmd == 'status' then
  local ent = df.historical_entity.find(df.global.plotinfo.group_id)
  if not ent then util.emit({ ok = false, error = 'fort entity not found' }) return end
  local own = {}
  for _, p in ipairs(ent.positions.own) do own[p.id] = p end
  local positions = {}
  for idx, asg in ipairs(ent.positions.assignments) do
    local pos = own[asg.position_id]
    local hfid = (safe(function() return asg.histfig2 end, -1) >= 0) and asg.histfig2 or asg.histfig
    local holder = nil
    if hfid and hfid >= 0 then
      local hf = df.historical_figure.find(hfid)
      local u = hf and df.unit.find(hf.unit_id) or nil
      if u then
        holder = info(u)
      else
        -- the assignment points at a histfig without a unit on the map: dead (died_year set) or gone
        holder = { hf = hfid, alive = false, dead = hf ~= nil and safe(function() return hf.died_year ~= -1 end, false),
                   gone = true, name = hf and safe(function() return dfhack.TranslateName(hf.name) end, nil) or nil }
      end
    end
    positions[#positions + 1] = { code = pos and pos.code or '?', idx = idx, assignment = asg.id, hf = hfid,
                                  holder = holder }
  end
  local cits, patients = {}, 0
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    local c = info(u)
    if c.alive then
      cits[#cits + 1] = c
      if c.patient then patients = patients + 1 end
    end
  end
  util.emit({ ok = true, positions = positions, citizens = cits, patients = patients, depot = DEPOT ~= nil,
              tick = safe(function() return df.global.cur_year * 403200 + df.global.cur_year_tick end, 0) })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_offices status' })
end
