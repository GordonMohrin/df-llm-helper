-- claude/alert            - status of the civilian alert
-- claude/alert on|off     - switch the civilian alert on/off (civilians retreat into the underground burrow),
--                            as in the game: Alerts menu (Civilian alert).
local util = reqscript('claude/util')
if not util.require_fort() then return end

local al = df.global.plotinfo.alerts
local cmd = ({ ... })[1]

local function info()
  local list = {}
  for i, a in ipairs(al.list) do
    list[#list + 1] = { index = i, name = a.name, burrows = #a.burrows }
  end
  local tiles = 0
  local names = {}
  for _, b in ipairs(df.global.plotinfo.burrows.list) do
    names[#names + 1] = { name = b.name, tiles = #b.block_x }
  end
  return { active = al.civ_alert_idx, alerts = list, burrows = names }
end

if cmd == 'on' then
  local idx
  for i, a in ipairs(al.list) do
    if a.name == 'civ-alert' or (i > 0 and #a.burrows > 0) then idx = i break end
  end
  if not idx then util.emit({ error = 'keine Zivilwarnung mit Erdbau definiert', info = info() }) return end
  al.civ_alert_idx = idx
elseif cmd == 'off' then
  al.civ_alert_idx = 0
end
util.emit(info())

