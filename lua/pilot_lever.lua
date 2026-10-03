-- claude/pilot_lever list | pull <lever_id> | set <lever_id> raised|lowered|open|closed      (df-llm-helper, BUG-427)
-- list: READ ONLY. Every lever with its own state (b.state), queued PullLever jobs and the buildings it is linked to
--       (mechanism -> BUILDING_TRIGGERTARGET ref) with their REAL state, read from the target building:
--         Bridge     gate_flags.raised (fallback gate_flags.closed) -> raised | lowered   (moving while raising/lowering)
--         Floodgate  gate_flags.closed -> closed | open
--         Door/Hatch door_flags.closed -> closed | open
--         other      linked (no state)
--       BUG-427: the earlier lever list printed "raised" for every bridge, whatever the bridge did.
-- pull: queues ONE PullLever job at the lever (what the player does with "Pull the lever"); a pull TOGGLES the linked
--       buildings. Refused while a PullLever job is already queued (a second pull would toggle back).
-- set:  pulls only if a linked target is not in the wanted state (raised/lowered: bridges; open/closed: floodgates,
--       doors, hatches). No pull when already there, while a pull is queued, while a bridge moves, or when the linked
--       targets disagree (a pull would flip all of them).
-- Fair play: a job like the UI lever menu; no building state is written directly.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'list'

local function safe(f, d) local ok, v = pcall(f) if ok and v ~= nil then return v end return d end
local function btype(b) return safe(function() return df.building_type[b:getType()] end, '?') end

-- real state of a linked building -> state, field it was read from
local function target_state(b)
  local t = btype(b)
  if t == 'Bridge' then
    local gf = safe(function() return b.gate_flags end, nil)
    if not gf then return '?', nil end
    for _, k in ipairs({ 'raising', 'lowering', 'opening', 'closing' }) do
      if safe(function() return gf[k] end, false) == true then return 'moving', 'gate_flags.' .. k end
    end
    local r, field = safe(function() return gf.raised end, nil), 'gate_flags.raised'
    if r == nil then r, field = safe(function() return gf.closed end, nil), 'gate_flags.closed' end
    if r == nil then return '?', nil end
    return r and 'raised' or 'lowered', field
  elseif t == 'Floodgate' then
    local c = safe(function() return b.gate_flags.closed end, nil)
    if c == nil then return '?', nil end
    return c and 'closed' or 'open', 'gate_flags.closed'
  elseif t == 'Door' or t == 'Hatch' then
    local c = safe(function() return b.door_flags.closed end, nil)
    if c == nil then return '?', nil end
    return c and 'closed' or 'open', 'door_flags.closed'
  end
  return 'linked', nil
end

local function is_lever(b)
  return btype(b) == 'Trap' and safe(function() return df.trap_type[b.trap_type] end, '') == 'Lever'
end

local function levers()
  local out = {}
  for _, b in ipairs(df.global.world.buildings.other.TRAP) do
    if is_lever(b) then out[#out + 1] = b end
  end
  return out
end

local function targets(lever)
  local out, seen = {}, {}
  for _, m in ipairs(safe(function() return lever.linked_mechanisms end, {})) do
    local ref = safe(function() return dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_TRIGGERTARGET) end, nil)
    local id = ref and safe(function() return ref.building_id end, nil)
    local tb = id and df.building.find(id) or nil
    if tb and not seen[tb.id] then
      seen[tb.id] = true
      local st, field = target_state(tb)
      out[#out + 1] = { id = tb.id, type = btype(tb), state = st, field = field, x = tb.centerx, y = tb.centery,
                        z = tb.z }
    end
  end
  return out
end

local function pending(lever)
  local n = 0
  for _, j in ipairs(safe(function() return lever.jobs end, {})) do
    if safe(function() return df.job_type[j.job_type] end, '') == 'PullLever' then n = n + 1 end
  end
  return n
end

local function describe(b)
  return { id = b.id, x = b.centerx, y = b.centery, z = b.z, lever_state = safe(function() return b.state end, -1),
           pull_jobs = pending(b), targets = targets(b) }
end

local function find_lever(id)
  local b = id and df.building.find(id) or nil
  if not b or not is_lever(b) then return nil end
  return b
end

local function queue_pull(b)
  local job = df.job:new()
  job.job_type = df.job_type.PullLever
  job.pos = { x = b.centerx, y = b.centery, z = b.z }
  local ref = df.general_ref_building_holderst:new()
  ref.building_id = b.id
  job.general_refs:insert('#', ref)
  b.jobs:insert('#', job)
  dfhack.job.linkIntoWorld(job, true)
end

local WANT = { raised = 'Bridge', lowered = 'Bridge', open = 'gate', closed = 'gate' }
local GATE = { Floodgate = true, Door = true, Hatch = true }

if cmd == 'list' then
  local list = {}
  for _, b in ipairs(levers()) do list[#list + 1] = describe(b) end
  util.emit({ ok = true, levers = list })
elseif cmd == 'pull' or cmd == 'set' then
  local id = math.tointeger(tonumber(a[2]) or -1)
  local b = find_lever(id)
  if not b then
    util.emit({ ok = false, error = 'no lever with id ' .. tostring(a[2]) })
    return
  end
  local d = describe(b)
  if d.pull_jobs > 0 then
    util.emit({ ok = true, pulled = false, reason = 'pull already queued', lever = d })
    return
  end
  if cmd == 'set' then
    local want = tostring(a[3] or '')
    local kind = WANT[want]
    if not kind then
      util.emit({ ok = false, error = 'Usage: claude/pilot_lever set <lever_id> raised|lowered|open|closed' })
      return
    end
    local match, differ, moving = 0, 0, 0
    for _, t in ipairs(d.targets) do
      local fits = (kind == 'Bridge' and t.type == 'Bridge') or (kind == 'gate' and GATE[t.type])
      if fits then
        match = match + 1
        if t.state == 'moving' or t.state == '?' then moving = moving + 1
        elseif t.state ~= want then differ = differ + 1 end
      end
    end
    local why = (match == 0 and 'no linked target with state ' .. want)
             or (moving > 0 and 'target moving or state unreadable')
             or (differ == 0 and 'already ' .. want)
             or (differ < match and 'linked targets disagree (a pull flips all of them)')
             or nil
    if why then
      util.emit({ ok = match > 0 and differ == 0 and moving == 0, pulled = false, reason = why, lever = d })
      return
    end
  end
  queue_pull(b)
  util.emit({ ok = true, pulled = true, note = 'PullLever job queued: the linked buildings toggle when a dwarf pulls',
              lever = describe(b) })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_lever list | pull <lever_id> | set <lever_id> raised|lowered|open|closed' })
end
