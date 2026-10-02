-- claude/bauprog start|stop|status|next|once|reset|force <id>   construction/production program (scope wirtschaft/bau, 30.09.2026 Y88)
-- The player: "Make sure there is enough utilization." Demand is missing, not labor. This script keeps work available for the ~34 free dwarves permanently:
--   PHASES (PHASES below) = fort extensions (east wing x163..186, further bands). Each phase: 1. set dig designations (like claude/dig, walls only),
--   2. once the area is dug free: set quickfort blueprints (workshops, stockpiles, zones, furniture, beds, statues).
--   Downstream, smoothing/engraving (arbeit.lua smooth_supply, box x125..190), stonemason/furniture orders (orders.lua) and hauling generate the work.
-- The next phase starts when fewer than START_UNTER reachable dig designations are open (miners with picks are the bottleneck, not the phase).
-- State: state/bauprog.json (survives restart). RESTART AFTER EVERY LOAD: claude/bauprog start (UEBERWACHUNG.md).
-- Geometry/blueprints: tools/gen_bau.py (generates claude/bau_*.csv), tools/scopes/bau.md section construction program.
local util = reqscript('claude/util')
if not util.require_fort() then return end
local bh = reqscript('claude/bauhelp')
local repeatUtil = require('repeat-util')
local json = require('json')
local KEY, INTERVAL = 'claude-bauprog', 900
local STATE = reqscript('claude/util').home() .. '/state/bauprog.json'
local START_UNTER = 150

-- Rectangle = { z, x1, y1, x2, y2 }; dig = list of rectangles (mode d: wall tiles only); steps = blueprints after digging:
-- { bp = 'claude/file.csv', cur = 'x,y,z', need = { rectangles that must be free (FLOOR) } }
local PHASES = {
  { id = 'O1', name = 'Ostfluegel z144: Werkhalle (3 Masons/Crafts, Jeweler, Mechaniker) + Lager', cam = { 175, 150, 144 },
    dig = { { 144, 163, 149, 186, 151 }, { 144, 164, 145, 186, 148 }, { 144, 164, 152, 186, 155 } },
    steps = {
      { bp = 'claude/bau_o1_ws.csv', cur = '165,146,144', need = { { 144, 165, 146, 185, 148 } } },
      { bp = 'claude/bau_o1_sp.csv', cur = '164,152,144', need = { { 144, 164, 152, 186, 154 } } },
      { bp = 'claude/bau_o1_sp2.csv', cur = '164,145,144', need = { { 144, 164, 145, 186, 145 } } },
    } },
  { id = 'O2', name = 'Ostfluegel z143: Speisesaal 2 + 3 Schlafsaele (Dormitory), Tueren, Betten, Statuen', cam = { 175, 150, 143 },
    dig = { { 143, 162, 150, 186, 150 }, { 143, 164, 144, 174, 148 }, { 143, 176, 144, 186, 148 }, { 143, 164, 152, 174, 156 }, { 143, 176, 152, 186, 156 },
      { 143, 169, 149, 169, 149 }, { 143, 181, 149, 181, 149 }, { 143, 169, 151, 169, 151 }, { 143, 181, 151, 181, 151 } },
    steps = {
      { bp = 'claude/bau_o2_zone.csv', cur = '164,144,143', need = { { 143, 164, 144, 174, 148 }, { 143, 176, 144, 186, 148 }, { 143, 164, 152, 174, 156 }, { 143, 176, 152, 186, 156 } } },
      { bp = 'claude/bau_o2_furn.csv', cur = '164,144,143', need = { { 143, 164, 144, 174, 148 }, { 143, 176, 144, 186, 148 }, { 143, 164, 152, 174, 156 }, { 143, 176, 152, 186, 156 },
        { 143, 169, 149, 169, 149 }, { 143, 181, 149, 181, 149 }, { 143, 169, 151, 169, 151 }, { 143, 181, 151, 181, 151 } } },
    } },
  { id = 'O3', name = 'Ostfluegel z142: Bibliothek, Treffpunkt, Hospital 2, Kaserne 2 (Waffenregale/Staender)', cam = { 175, 150, 142 },
    dig = { { 142, 162, 150, 186, 150 }, { 142, 164, 144, 174, 148 }, { 142, 176, 144, 186, 148 }, { 142, 164, 152, 174, 156 }, { 142, 176, 152, 186, 156 },
      { 142, 169, 149, 169, 149 }, { 142, 181, 149, 181, 149 }, { 142, 169, 151, 169, 151 }, { 142, 181, 151, 181, 151 } },
    steps = {
      { bp = 'claude/bau_o3_zone.csv', cur = '164,144,142', need = { { 142, 164, 144, 174, 148 }, { 142, 176, 144, 186, 148 }, { 142, 164, 152, 174, 156 }, { 142, 176, 152, 186, 156 } } },
      { bp = 'claude/bau_o3_furn.csv', cur = '164,144,142', need = { { 142, 164, 144, 174, 148 }, { 142, 176, 144, 186, 148 }, { 142, 164, 152, 174, 156 }, { 142, 176, 152, 186, 156 },
        { 142, 169, 149, 169, 149 }, { 142, 181, 149, 181, 149 }, { 142, 169, 151, 169, 151 }, { 142, 181, 151, 181, 151 } } },
    } },
  { id = 'O4', name = 'Ostfluegel z141: Zuflucht Ost (2. Fluchtraum, nur ueber Treppe Z (161,150), nicht ueber Gang D)', cam = { 175, 150, 141 },
    dig = { { 141, 162, 150, 186, 150 }, { 141, 164, 144, 174, 148 }, { 141, 176, 144, 186, 148 }, { 141, 176, 152, 186, 156 },
      { 141, 169, 149, 169, 149 }, { 141, 181, 149, 181, 149 }, { 141, 181, 151, 181, 151 } },
    steps = {} },
  { id = 'O5', name = 'Ostfluegel z144 Sued: Trainingshalle/Kaserne 2 (Barracks, Waffenregale) + Schiessstand (Archery Range, Ziele)', cam = { 175, 162, 144 },
    dig = { { 144, 175, 156, 175, 156 }, { 144, 164, 157, 186, 166 }, { 144, 175, 167, 175, 167 }, { 144, 164, 168, 186, 170 } },
    steps = {
      { bp = 'claude/bau_o5_zone.csv', cur = '164,157,144', need = { { 144, 164, 157, 186, 166 }, { 144, 164, 168, 186, 170 } } },
      { bp = 'claude/bau_o5_furn.csv', cur = '164,157,144', need = { { 144, 164, 157, 186, 166 }, { 144, 164, 168, 186, 170 } } },
    } },
  { id = 'O6', name = 'Ostfluegel z144 Nord: Grosslager Stein (23x13) fuer die Boulder-Flut', cam = { 175, 135, 144 },
    dig = { { 144, 175, 141, 175, 144 }, { 144, 164, 128, 186, 140 } },
    steps = {
      { bp = 'claude/bau_o6_sp.csv', cur = '164,128,144', need = { { 144, 164, 128, 186, 140 } } },
    } },
}
-- further phases: PHASES_EXTRA from state/bauprog_extra.lua (optional, same structure) -> extendable without script changes
do
  local f = loadfile(reqscript('claude/util').home() .. '/state/bauprog_extra.lua')
  if f then
    local ok, extra = pcall(f)
    if ok and type(extra) == 'table' then for _, p in ipairs(extra) do PHASES[#PHASES + 1] = p end end
  end
end

---------------------------------------------------------------------------------------------------------
local function load_state()
  local ok, t = pcall(json.decode_file, STATE)
  if ok and type(t) == 'table' then return t end
  return { started = {}, steps = {}, log = {} }
end
local function save_state(st) pcall(json.encode_file, st, STATE) end
local function note(st, s)
  st.log = st.log or {}
  st.log[#st.log + 1] = os.date('%H:%M:%S ') .. s
  while #st.log > 30 do table.remove(st.log, 1) end
end

local function shape_at(x, y, z)
  local tt = dfhack.maps.getTileType(x, y, z)
  return tt and df.tiletype_shape[df.tiletype.attrs[tt].shape] or nil
end
local function rect_open(r)
  local z, x1, y1, x2, y2 = table.unpack(r)
  for x = x1, x2 do for y = y1, y2 do
    if shape_at(x, y, z) ~= 'FLOOR' then return false end
  end end
  return true
end
local function rect_walls(r)
  local z, x1, y1, x2, y2 = table.unpack(r)
  local n = 0
  for x = x1, x2 do for y = y1, y2 do if shape_at(x, y, z) == 'WALL' then n = n + 1 end end end
  return n
end

-- reachable open dig work (designations + jobs, without duplicates)
local function dig_open()
  local n = 0
  local seen = {}
  local l = df.global.world.jobs.list.next
  while l do
    local j = l.item
    if j and (j.job_type == df.job_type.Dig or j.job_type == df.job_type.DigChannel or j.job_type == df.job_type.CarveRamp
      or j.job_type == df.job_type.CarveUpwardStaircase or j.job_type == df.job_type.CarveDownwardStaircase or j.job_type == df.job_type.CarveUpDownStaircase) then
      local k = j.pos.x .. ',' .. j.pos.y .. ',' .. j.pos.z
      if not seen[k] and bh.dig_reachable(j.pos.x, j.pos.y, j.pos.z) then seen[k] = true; n = n + 1 end
    end
    l = l.next
  end
  local NO = df.tile_dig_designation.No
  local mx, my = dfhack.maps.getTileSize()
  for z = 100, 146 do
    for bx = 0, mx // 16 - 1 do for by = 0, my // 16 - 1 do
      local b = dfhack.maps.getBlock(bx, by, z)
      if b and b.flags.designated then
        for i = 0, 15 do for j = 0, 15 do
          if b.designation[i][j].dig ~= NO and bh.dig_reachable(b.map_pos.x + i, b.map_pos.y + j, z) then n = n + 1 end
        end end
      end
    end end
  end
  return n
end

local function set_dig(phase)
  local n = 0
  for _, r in ipairs(phase.dig) do
    local z, x1, y1, x2, y2 = table.unpack(r)
    local out = dfhack.run_command_silent({ 'claude/dig', tostring(z), tostring(x1), tostring(y1), tostring(x2), tostring(y2), 'd' })
    local g = tostring(out):match('"gesetzt"%s*:%s*(%d+)')
    n = n + (tonumber(g) or 0)
  end
  return n
end

local function run_step(step)
  local out = dfhack.run_command_silent({ 'quickfort', 'run', step.bp, '-c', step.cur })
  out = tostring(out)
  local des = tonumber(out:match('designated:%s*(%d+)')) or 0
  local unsuit = tonumber(out:match('Unsuitable tiles[^:]*:%s*(%d+)')) or 0
  return des, unsuit, out
end

local function show(phase, text)
  if phase.cam then pcall(dfhack.run_command_silent, { 'claude/schau', 'show', tostring(phase.cam[1]), tostring(phase.cam[2]), tostring(phase.cam[3]), text }) end
end

local function start_phase(st, phase)
  local n = set_dig(phase)
  st.started[phase.id] = os.time()
  note(st, 'Phase ' .. phase.id .. ' gestartet: ' .. n .. ' Grabkacheln')
  show(phase, 'Bauprogramm ' .. phase.id .. ': ' .. phase.name)
  return n
end

local function sync(force_next)
  local st = load_state()
  st.started = st.started or {}
  st.steps = st.steps or {}
  local res = { steps_run = {}, started = nil }
  -- 1. Follow-up steps (blueprints) for started phases
  for _, p in ipairs(PHASES) do
    if st.started[p.id] then
      for i, step in ipairs(p.steps or {}) do
        local sk = p.id .. ':' .. i
        if not st.steps[sk] then
          local ready = true
          for _, r in ipairs(step.need or {}) do if not rect_open(r) then ready = false break end end
          if ready then
            local des, unsuit = run_step(step)
            res.steps_run[#res.steps_run + 1] = { step = sk, bp = step.bp, designated = des, unsuitable = unsuit }
            note(st, string.format('Schritt %s (%s): %d designiert, %d ungeeignet', sk, step.bp, des, unsuit))
            -- only complete if something was designated; otherwise give up after 3 attempts (check the save)
            st.tries = st.tries or {}
            st.tries[sk] = (st.tries[sk] or 0) + 1
            if des > 0 or st.tries[sk] >= 3 then st.steps[sk] = os.time() end
          end
        end
      end
    end
  end
  -- 2. start the next phase
  local open = dig_open()
  res.dig_offen = open
  if force_next or open < START_UNTER then
    for _, p in ipairs(PHASES) do
      if not st.started[p.id] then
        res.started = p.id
        res.grab = start_phase(st, p)
        break
      end
    end
  end
  save_state(st)
  return res
end

local function status()
  local st = load_state()
  local rows = {}
  for _, p in ipairs(PHASES) do
    local walls = 0
    for _, r in ipairs(p.dig) do walls = walls + rect_walls(r) end
    local steps = {}
    for i, _ in ipairs(p.steps or {}) do steps[#steps + 1] = st.steps and st.steps[p.id .. ':' .. i] and 'ok' or '-' end
    rows[#rows + 1] = { id = p.id, name = p.name, gestartet = st.started and st.started[p.id] and true or false, waende_offen = walls, schritte = table.concat(steps, ',') }
  end
  return { phasen = rows, dig_offen = dig_open(), start_unter = START_UNTER, log = st.log }
end

local a = { ... }
local cmd = a[1] or 'status'
if cmd == 'start' then
  repeatUtil.scheduleEvery(KEY, INTERVAL, 'ticks', function() pcall(sync) end)
  local ok, r = pcall(sync)
  util.emit({ running = true, interval = INTERVAL, ok = ok, result = ok and r or tostring(r) })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'next' then
  local ok, r = pcall(sync, true)
  util.emit({ ok = ok, result = ok and r or tostring(r) })
elseif cmd == 'once' then
  local ok, r = pcall(sync)
  util.emit({ ok = ok, result = ok and r or tostring(r) })
elseif cmd == 'reset' then
  save_state({ started = {}, steps = {}, log = {} })
  util.emit({ reset = true })
else
  local ok, r = pcall(status)
  util.emit(ok and r or { error = tostring(r) })
end
