-- claude/pilot_siege status | kill <squad_id> <id,id,...> | move <squad_id> <x> <y> <z> | clear <squad_id>
-- df-llm-helper Spec 01 (siege autopilot). NOT TESTED LIVE (structure check + mock DFHack only).
-- Commands mirror the squad menu (kill list, move, clear orders); no unit/item manipulation.
-- status: invaders (isInvader, never citizen/pet/merchant/guest, never caged/chained: BUG-426), berserk citizens (report only),
--   squads with blood/position/thirst/hunger (the flow withdraws orders of starving squads).
local util = reqscript('claude/util')
if not util.require_fort() then return end
local cfg = reqscript('claude/config')

local a = { ... }
local cmd = a[1] or 'status'
local CX, CY, CZ = cfg.FORT_X or 0, cfg.FORT_Y or 0, cfg.SURFACE_Z or 0

local function dist(p) return math.max(math.abs(p.x - CX), math.abs(p.y - CY), math.abs(p.z - CZ)) end

-- Visitors count as friendly only when they are not invaders: isVisitor is also true for Forgotten Beasts
-- (visitor_uninvited, see lua/claude/gefahr.lua), which must stay valid kill targets (BUG-422).
local function friendly(u)
  return dfhack.units.isCitizen(u) or dfhack.units.isFortControlled(u) or dfhack.units.isPet(u)
      or dfhack.units.isMerchant(u) or (dfhack.units.isVisitor(u) and not dfhack.units.isInvader(u))
end

-- BUG-426: prisoners (caged/chained, or held in a cage item) are never targets; older config.lua copies lack is_captive
local function captive(u)
  if cfg.is_captive then return cfg.is_captive(u) end
  return (u.flags1.caged or u.flags1.chained) and true or false
end

local function squad_of(id)
  local s = df.squad.find(tonumber(id) or -1)
  if s and s.entity_id == df.global.plotinfo.group_id then return s end
  return nil
end

local function clear(s)
  local n = 0
  for i = #s.orders - 1, 0, -1 do
    local o = s.orders[i]
    s.orders:erase(i)
    pcall(function() o:delete() end)
    n = n + 1
  end
  return n
end

if cmd == 'status' then
  local inv, berserk = {}, {}
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isAlive(u) and u.pos.x >= 0 and not util.unit_hidden(u) then
      if dfhack.units.isCitizen(u) and dfhack.units.isCrazed(u) then
        berserk[#berserk + 1] = { id = u.id, x = u.pos.x, y = u.pos.y, z = u.pos.z }
      elseif dfhack.units.isInvader(u) and not friendly(u) and not captive(u) then
        local prof = df.profession[u.profession] or tostring(u.profession)
        local race = df.creature_raw.find(u.race)
        inv[#inv + 1] = { id = u.id, hf = u.hist_figure_id, race = race and race.creature_id or '?', prof = prof,
                          x = u.pos.x, y = u.pos.y, z = u.pos.z, dist = dist(u.pos) }
      end
    end
  end
  local squads = {}
  for _, sid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
    local s = squad_of(sid)
    if s then
      local members = {}
      for i = 0, #s.positions - 1 do
        local occ = s.positions[i].occupant
        local hf = occ ~= -1 and df.historical_figure.find(occ) or nil
        local u = hf and df.unit.find(hf.unit_id) or nil
        if u then
          local bmax = u.body.blood_max > 0 and u.body.blood_max or 1
          members[#members + 1] = { id = u.id, alive = dfhack.units.isAlive(u), blood_pct = math.floor(100 * u.body.blood_count / bmax),
                                    x = u.pos.x, y = u.pos.y, z = u.pos.z, dist = dist(u.pos),
                                    thirst = u.counters2 and u.counters2.thirst_timer, hunger = u.counters2 and u.counters2.hunger_timer }
        end
      end
      squads[#squads + 1] = { id = s.id, name = dfhack.military.getSquadName(s.id), orders = #s.orders, members = members }
    end
  end
  util.emit({ invaders = inv, berserk = berserk, squads = squads, civ_alert = df.global.plotinfo.alerts.civ_alert_idx,
              center = { x = CX, y = CY, z = CZ } })
  return
end

if cmd ~= 'clear' and cmd ~= 'kill' and cmd ~= 'move' then
  util.emit({ ok = false, error = 'Usage: claude/pilot_siege status|kill|move|clear' })
  return
end
local s = squad_of(a[2])
if not s then util.emit({ ok = false, error = 'Squad ' .. tostring(a[2]) .. ' unknown' }) return end

if cmd == 'clear' then
  util.emit({ ok = true, cleared = clear(s) })
elseif cmd == 'kill' then
  local o = df.squad_order_kill_listst:new()
  local n = 0
  for id in tostring(a[3] or ''):gmatch('%d+') do
    local u = df.unit.find(tonumber(id))
    if u and dfhack.units.isInvader(u) and not friendly(u) and not captive(u) then     -- never citizens/animals/merchants/prisoners (BUG-426)
      o.units:insert('#', u.id)
      if u.hist_figure_id >= 0 then o.histfigs:insert('#', u.hist_figure_id) end
      n = n + 1
    end
  end
  if n == 0 then pcall(function() o:delete() end) util.emit({ ok = false, error = 'no valid targets' }) return end
  clear(s)
  o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
  s.orders:insert('#', o)
  util.emit({ ok = true, targets = n })
elseif cmd == 'move' then
  local x, y, z = tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
  if not (x and y and z) then util.emit({ ok = false, error = 'move needs x y z' }) return end
  local order = df.squad_order_movest:new()
  order.pos.x, order.pos.y, order.pos.z = x, y, z      -- target of the squad order (no teleport)
  order.year, order.year_tick = df.global.cur_year, df.global.cur_year_tick
  clear(s)
  s.orders:insert('#', order)
  util.emit({ ok = true, move = { x, y, z } })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_siege status|kill|move|clear' })
end
