-- claude/wachen [start|status|load] - startet ALLE Dauer-Wachen der Liste WACHEN_LIST (claude/config.lua).
--   load = aus dfhack-config/init/onMapLoad.init (verzoegert, nur Festung). Idempotent: bereits laufende werden neu eingeplant (scheduleEvery ersetzt).
--   Standardliste: watchdog, mil guard, ueberwacher, gesund, stresswacht, hospitalwacht, geisterwacht, aemterwacht. Optional (per WACHEN_LIST):
--   schmelzwacht, binwacht, tempo load, arbeit, essen, trinken, orders, migranten, auslastung.
local util = reqscript('claude/util')
local cfg = reqscript('claude/config')
-- Liste in claude/config.lua: WACHEN_LIST = { 'tempo load', 'watchdog start', ... } (jeder Eintrag = Skript + Argumente).
local LIST = cfg.WACHEN_LIST or {
  'watchdog start', 'mil guard start', 'ueberwacher start', 'gesund start',
  'stresswacht start', 'hospitalwacht start', 'geisterwacht start', 'aemterwacht start',
}
local function start_all()
  local ok_n, fail = 0, {}
  for _, c in ipairs(LIST) do
    local parts = {}
    for w in c:gmatch('%S+') do parts[#parts + 1] = w end
    local script = 'claude/' .. table.remove(parts, 1)
    local ok, err = pcall(dfhack.run_script, script, table.unpack(parts))
    if ok then ok_n = ok_n + 1 else fail[#fail + 1] = c .. ': ' .. tostring(err) end
  end
  return { gestartet = ok_n, fehler = fail }
end
local cmd = ({ ... })[1] or 'status'
if cmd == 'start' then
  util.emit(start_all())
elseif cmd == 'load' then
  local tries = 0
  local function try()
    tries = tries + 1
    if not util.fort_loaded() then
      if tries < 40 then dfhack.timeout(100, 'frames', try) end
      return
    end
    dfhack.timeout(400, 'frames', function() pcall(start_all) end)
  end
  dfhack.timeout(300, 'frames', try)
else
  local ru = require('repeat-util')
  local r = {}
  for k, _ in pairs(ru.repeating or {}) do if k:find('^claude%-') then r[#r + 1] = k end end
  table.sort(r)
  util.emit({ laufende = r })
end
