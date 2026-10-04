-- claude/binwacht [start|stop|status|once] - haelt immer BIN_FREI_MIN (20) leere, freie METALL-Bins vorraetig (Gordon 03.10.2026:
-- "es sollten immer 20 frei sein. mach einen Auftrag fuer den Manager. nur Metal Bins").
--   Frei = Bin ohne Inhalt, nicht verboten, nicht in Job/Gebaeude. Holz-Bins zaehlen nicht (Holz ist Notreserve).
--   Fehlen welche: Manager-Auftrag ConstructBin aus Eisen (workorder), Menge = Fehlbestand (max 10 je Lauf, max 20 offen),
--   nur solange freie Eisenbarren >= IRON_MIN (25; Eisen kommt aus dem Einschmelzen).
--   Kein neuer Auftrag, solange ein ConstructBin-Eisenauftrag offen ist.
-- Werte: BIN_WACHT in claude/config.lua. Nach jedem Laden neu starten (claude/wachen).
local util = reqscript('claude/util')
local cfg = reqscript('claude/config')
local repeatUtil = require('repeat-util')
local KEY = 'claude-binwacht'
local C = cfg.BIN_WACHT or {}
local BIN_FREI_MIN = C.free_min or 20
local IRON_MIN = C.iron_min or 25
local MAX_PER_RUN = C.max_per_run or 10
local MAX_OPEN = C.max_open or 20
local FRAMES = 200
local PERIOD_S = C.period_s or 120

local function metal_ok(it)
  local mi = dfhack.matinfo.decode(it)
  if not mi then return false end
  local s = mi:toString():lower()
  for _, m in ipairs({ 'iron', 'bronze', 'copper', 'zinc', 'steel', 'lead', 'tin', 'brass', 'silver', 'gold' }) do
    if s:find(m, 1, true) then return true end
  end
  return false
end

local function count()
  local free, total = 0, 0
  for _, it in ipairs(df.global.world.items.other.BIN) do
    local f = it.flags
    if not f.garbage_collect and not f.removed then
      total = total + 1
      if metal_ok(it) and not (f.in_job or f.forbid or f.in_building or f.in_inventory or f.dump) then
        if #dfhack.items.getContainedItems(it) == 0 then free = free + 1 end
      end
    end
  end
  return free, total
end

local function iron_bars()
  local n = 0
  for _, it in ipairs(df.global.world.items.other.BAR) do
    local f = it.flags
    if not (f.in_job or f.forbid or f.in_building or f.in_inventory or f.removed or f.garbage_collect) then
      local mi = dfhack.matinfo.decode(it)
      if mi and mi:toString():lower() == 'iron' then n = n + it:getStackSize() end
    end
  end
  return n
end

local function open_orders()
  local n = 0
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if df.job_type[o.job_type] == 'ConstructBin' and o.amount_left > 0 then
      n = n + o.amount_left
    end
  end
  return n
end

local function run(dry)
  local free, total = count()
  local iron = iron_bars()
  local open = open_orders()
  local info = { frei_metall_bins = free, bins_gesamt = total, eisenbarren = iron, offene_bin_auftraege = open, ziel = BIN_FREI_MIN }
  if free + open >= BIN_FREI_MIN then info.aktion = 'genug'; return info end
  if iron < IRON_MIN then info.aktion = 'kein Eisen (< ' .. IRON_MIN .. ')'; return info end
  if open >= MAX_OPEN then info.aktion = 'viele offen'; return info end
  local want = math.min(MAX_PER_RUN, BIN_FREI_MIN - free - open, iron - IRON_MIN)
  if want <= 0 then info.aktion = 'nichts'; return info end
  info.bestellt = want
  if not dry then
    local ok, err = pcall(dfhack.run_command, 'workorder',
      '{"job":"ConstructBin","material":"IRON","amount_total":' .. want .. '}')
    info.aktion = ok and 'bestellt' or ('Fehler: ' .. tostring(err))
  else
    info.aktion = 'dry'
  end
  return info
end

local args = { ... }
local cmd = args[1] or 'status'
if cmd == 'start' then
  local lastrun = 0
  repeatUtil.scheduleEvery(KEY, FRAMES, 'frames', function()
    if os.time() - lastrun < PERIOD_S then return end
    lastrun = os.time()
    pcall(run, false)
  end)
  util.emit({ running = true, ziel = BIN_FREI_MIN, periode_s = PERIOD_S })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'once' then
  util.emit(run(false))
else
  local info = run(true)
  info.laeuft = repeatUtil.isScheduled(KEY)
  util.emit(info)
end
