-- claude/alert            - status of the civilian alert
-- claude/alert on|off     - switch the civilian alert on/off (civilians retreat into the underground burrow),
--                            as in the game: Alerts menu (Civilian alert).
-- BUG-423: `off` writes tools/alert-manual-off.flag; watchdog/gefahr then keep the alert off for config.ALERT_MANUAL_HOLD_S seconds
-- unless the enemies near the fort grow by more than config.ALERT_MANUAL_GROW or a new major threat appears. `on` deletes the flag.
-- Both report the refuge supply (drink/food/water in the burrow 'Zuflucht').
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

local okg, G = pcall(reqscript, 'claude/gefahr')
if not okg then G = nil end
local extra = {}
if cmd == 'on' then
  local idx
  for i, a in ipairs(al.list) do
    if a.name == 'civ-alert' or (i > 0 and #a.burrows > 0) then idx = i break end
  end
  if not idx then util.emit({ error = 'keine Zivilwarnung mit Erdbau definiert', info = info() }) return end
  al.civ_alert_idx = idx
  if G then pcall(G.manual_off_clear) end
elseif cmd == 'off' then
  al.civ_alert_idx = 0
  if G then
    local n, nA = 0, 0
    local oks, S = pcall(G.scan)
    if oks and S then n, nA = S.alarm or 0, S.alarm_A or 0 end
    pcall(G.manual_off_set, n, nA)
    local m = G.manual_off_get and G.manual_off_get()
    if m then extra.manual_off_until, extra.enemies_near = os.date('%H:%M:%S', m.until_t), n end
  end
end
local res = info()
if G then
  local oks, sup = pcall(G.refuge_supply, nil, true)
  if oks and sup then res.refuge_supply = { drink = sup.drink, food = sup.food, wells = sup.wells, water_tiles = sup.water_tiles, ok = sup.ok, problems = sup.problems } end
end
for k, v in pairs(extra) do res[k] = v end
util.emit(res)

