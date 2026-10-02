-- claude/schacht status | bauen | open [--force] | seal [--force] | notzu | tuer <k1|kopf> zu|auf | cancel   (run 3, scope verteidigung: shaft D)
-- Lesson 30.09.2026: Forgotten beasts have TRAPAVOID (traps ineffective), destroy buildings (buildingdestroyer 2), and a door alone does not hold them
-- (door 1154 stood, it came through). The only real barrier without a lever mechanism: a built WALL (construction). The player (30.09.): "both caverns: at least one door
-- that you can close" -> caverns 1 + 2 hang only off shaft D: ONE barrier = door (lockable) + 2 plug walls in the net tunnel z138, operated from the fort side.
-- LESSON 20:33: Opening the shaft head for building is FORBIDDEN (beasts come up in ~60 s). Logic/docs: lua/claude/sperre.lua, coordinates + rationale: config.KAV_BARRIEREN.
--
--   status : state (head, k1 = net door z138 with plug walls), reachability shaft<->fort, threats, citizens behind the barrier
--   bauen  : ONE-TIME initial build: the outer old wall (137,167,138) is converted into a door BEHIND the two plug walls and locked (never a hole)
--   open   : open caverns 1+2 in a controlled way (unlock door, deconstruct both plug walls; head stays closed). Creates tools/schacht.offen (monitor: intentionally open).
--            Refused when beasts/intruders are reachable near the cave (beast <= 80, wildlife <= 50), unless `--force`
--   seal   : close again: build 2 plug walls + lock door (+ check head wall). Waits while citizens are behind the barrier (lock-in protection); `--force` without protection.
--   notzu  : EMERGENCY: plugs + lock immediately, without lock-in protection
--   tuer   : only lock (`zu`) / unlock (`auf`) the door
--   cancel : stop the guard job, revert deconstruction markers
local util = reqscript('claude/util')
if not util.require_fort() then return end
local S = reqscript('claude/sperre')
local cfg = reqscript('claude/config')

local a = { ... }
local cmd = a[1] or 'status'
local force = false
local args = {}
for i = 2, #a do if a[i] == '--force' then force = true else args[#args + 1] = a[i] end end

local function flag_write(text)
  local f = io.open(cfg.SCHACHT_OFFEN_FLAG, 'w')
  if f then f:write(os.date('%Y-%m-%d %H:%M:%S ') .. text .. '\n') f:close() end
end

local function threat_block(keys, ra, rw)
  ra, rw = ra or 80, rw or 50
  local bad = {}
  for _, k in ipairs(keys) do
    for _, t in ipairs(S.threats(k, 80)) do
      -- blocking: major threat (class A) reachable <= ra, or intruder/wildlife reachable <= rw
      if t.reach and ((t.klasse == 'A' and t.dist <= ra) or t.dist <= rw) then
        bad[#bad + 1] = string.format('%s %s id%d (%d,%d,%d) d=%d an %s', t.klasse, t.race, t.id, t.x, t.y, t.z, t.dist, k)
      end
    end
  end
  return bad
end

if cmd == 'status' then
  util.emit(S.status())

elseif not S.configured() and (cmd == 'bauen' or cmd == 'open' or cmd == 'seal' or cmd == 'notzu' or cmd == 'tuer' or cmd == 'cancel') then
  util.emit({ error = 'keine Kavernen-Sperre konfiguriert (config.KOPF/KAV_BARRIEREN leer)', befehl = cmd })

elseif cmd == 'bauen' or cmd == 'open' or cmd == 'seal' or cmd == 'notzu' then
  local plan
  if cmd == 'bauen' then plan = 'bauen'
  elseif cmd == 'seal' then plan = 'seal'
  elseif cmd == 'notzu' then plan = 'notzu'
  elseif args[1] == 'kopf' then plan = 'openkopf'
  else plan = 'open1' end
  local bad = {}
  if cmd == 'open' then bad = threat_block({ 'k1' }) end   -- the situation only matters when OPENING; building/closing never opens a hole
  if #bad > 0 and not force then
    util.emit({ abgebrochen = 'Bestien/Eindringlinge nahe der Hoehle erreichbar - NICHT oeffnen (mit --force trotzdem). Erst claude/gefahr status pruefen.', gefahr = bad })
    return
  end
  if cmd == 'open' then flag_write('open ' .. (args[1] or '') .. (force and ' --force' or '')) end
  S.start(plan, { force_guard = (cmd == 'seal' and force) })
  util.emit({ gestartet = plan, hinweis = (cmd == 'seal') and 'wartet, bis alle Buerger zurueck sind' or 'Wachjob laeuft; claude/schacht status zeigt den Fortschritt', warnungen = bad })

elseif cmd == 'tuer' then
  local ok, err = S.set_lock(args[1], (args[2] == 'zu' or args[2] == 'lock'))
  util.emit({ ok = ok, fehler = err, status = S.status().barrieren })

elseif cmd == 'cancel' then
  S.cancel()
  util.emit(S.status())

else
  util.emit({ usage = 'status | bauen | open [--force] | seal [--force] | notzu | tuer <k1|kopf> zu|auf | cancel' })
end
