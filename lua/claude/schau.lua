--@ module = true
-- claude/schau  – Spectate director for the player (Run 3): camera director + in-game text lines (overlay) + tool for agents.
--   claude/schau start [mode]       start director (mode auto|follow|events|combat, default auto)
--   claude/schau stop               stop director (say/show still work)
--   claude/schau status             state as JSON
--   claude/schau mode <mode>        switch mode (off = director off)
--   claude/schau say "<text>" [prio]                 text only (overlay + announcement), no camera
--   claude/schau show <x> <y> <z> "<text>" [prio]    camera to position (holds 10 s) + text
--   claude/schau show unit <id> "<text>" [prio]      same, on a unit
--   claude/schau hold [seconds]     pause director for n s (default 120) / release = free again
--   claude/schau off | on           master switch (off: everything silent, also say/show)
--   claude/schau clear              clear text lines
-- prio: 1 grey (minor) 2 white (default) 3 cyan (important) 4 yellow (warning) 5 red (alarm); or info/wichtig/warn/alarm.
-- SAFETY: only camera (window_x/y/z, follow_unit), announcements (showAnnouncement, no popup, no pause) and an
-- overlay text panel. Never touches pause_state, opens no sheets/windows, sends no input. Acts only with focus
-- 'dwarfmode/Default' and no open menu; pcall everywhere. Docs: SPECTATE.md
local util = reqscript('claude/util')
local repeatUtil = require('repeat-util')
local overlay = require('plugins.overlay')
local gui = require('gui')

local KEY = 'claude-schau'
local TOOLS = reqscript('claude/util').home() .. '/tools/'
local pi = df.global.plotinfo

-- ---------------------------------------------------------------- State (survives reloading the file)
local S = rawget(_G, 'CLAUDE_SCHAU')
if not S then
  S = {}
  rawset(_G, 'CLAUDE_SCHAU', S)
end
local function defaults()
  S.enabled = S.enabled ~= false            -- master switch
  S.mode = S.mode or 'off'                  -- director mode (off until 'start')
  S.lines = S.lines or {}
  S.queue = S.queue or {}
  S.next_eval, S.t_units, S.t_bld, S.t_follow_pick = S.next_eval or 0, S.t_units or 0, S.t_bld or 0, 0
  S.cam_t = S.cam_t or 0
  S.hold_until = S.hold_until or 0
  S.pan_gen = S.pan_gen or 0
  S.recent = S.recent or {}                 -- recently followed units
  S.stats = S.stats or { events = 0, jumps = 0, follows = 0, lines = 0, user_moves = 0, errors = 0 }
  S.announce = S.announce ~= false
end
defaults()

local function now() return dfhack.getTickCount() end

-- ---------------------------------------------------------------- camera profiles (df-llm-helper spec v3-10, LIVE-UNTESTED)
-- `python -m df_llm_helper camera profile <name>` writes <DF_LLM_HELPER_HOME>/tools/schau_profile.json and then calls
-- 'claude/schau profile reload'. Without that file (or after 'claude/schau profile default') the built-in
-- weights and constants below apply unchanged. Only weights/timings change; safety rules stay as they are.
local PROFILE_FILE = TOOLS .. 'schau_profile.json'
local function prof_num(k, d)
  local v = S.profile and tonumber(S.profile[k])
  if v == nil then return d end
  return v
end
function load_profile()
  local f = io.open(PROFILE_FILE, 'r')
  if not f then return false, 'no profile file ' .. PROFILE_FILE end
  local raw = f:read('*a')
  f:close()
  local ok, p = pcall(function() return require('json').decode(raw) end)
  if not ok or type(p) ~= 'table' or type(p.job_weights) ~= 'table' then return false, 'profile file unreadable' end
  local jw = {}
  for _, e in ipairs(p.job_weights) do
    local w = type(e) == 'table' and tonumber(e.w)
    if not (w and w >= 0 and type(e.p) == 'string') then return false, 'invalid weight entry' end
    jw[#jw + 1] = { e.p, w, e.cat }
  end
  p.job_w = jw
  S.profile = p
  return true, tostring(p.name or '?')
end
function clear_profile() S.profile = nil end

-- ---------------------------------------------------------------- Text helpers
-- Command-line arguments arrive as Windows ANSI (cp1252/Latin-1) -> convert to UTF-8.
local function from_arg(s)
  s = tostring(s or '')
  if not s:find('[\128-\255]') then return s end
  if utf8.len(s) then return s end
  local out = {}
  for i = 1, #s do out[#out + 1] = utf8.char(s:byte(i)) end
  return table.concat(out)
end

local function ulen(s) return utf8.len(s) or #s end
local function ucut(s, n)
  if ulen(s) <= n then return s end
  local off = utf8.offset(s, n) or n
  return s:sub(1, off - 1)
end

-- Wrap text into lines of width w (at spaces, max maxrows lines)
local function wrap(s, w, maxrows)
  local rows = {}
  local cur = ''
  for word in s:gmatch('%S+') do
    if cur == '' then cur = word
    elseif ulen(cur) + 1 + ulen(word) <= w then cur = cur .. ' ' .. word
    else rows[#rows + 1] = cur cur = word end
    while ulen(cur) > w do rows[#rows + 1] = ucut(cur, w) cur = cur:sub(#ucut(cur, w) + 1) end
  end
  if cur ~= '' then rows[#rows + 1] = cur end
  while #rows > maxrows do rows[#rows] = nil end
  if #rows == 0 then rows[1] = '' end
  return rows
end

local function strip(s)
  s = tostring(s or '')
  s = s:gsub('%[C:%d+:%d+:%d+%]', ''):gsub('%[B%]', ' '):gsub('%[P%]', ' '):gsub('%s+', ' ')
  return s
end

-- Defuse words in announcements that the message watcher (unpause-guard.ps1) reacts to with CRITICAL/pause
local CRIT = { 'ambush', 'siege', 'invader', 'invasion', 'thief', 'thieves', 'snatcher', 'kidnap', 'forgotten beast', 'megabeast',
  'titan', 'demon', 'werebeast', 'undead', 'zombie', 'vampire', 'berserk', 'tantrum', 'insane', 'went mad', 'found dead',
  'been killed', 'been slain', 'struck down', 'starv', 'dehydrat', 'cave-in', 'collapse', 'flood', 'on fire', 'fire!', 'magma',
  'plague', 'epidemic', 'goblin', 'elves', 'humans arrive', 'army', 'enemy' }
local function defuse(s)
  for _, w in ipairs(CRIT) do
    local pat = w:gsub('[%-%.%!]', '%%%0'):gsub('%a', function(c) return '[' .. c:lower() .. c:upper() .. ']' end)
    s = s:gsub(pat, function(m) return m:sub(1, 1) .. '\194\183' .. m:sub(2) end)   -- middle dot after the 1st letter
  end
  return s
end

local PRIO_WORDS = { info = 2, ok = 2, gut = 2, neben = 1, wichtig = 3, fund = 3, warn = 4, warnung = 4, alarm = 5, kritisch = 5 }
local function parse_prio(v, default)
  if v == nil then return default end
  local n = tonumber(v)
  if n then return math.max(1, math.min(5, math.floor(n))) end
  return PRIO_WORDS[tostring(v):lower()] or default
end

local TTL = { [1] = 9000, [2] = 14000, [3] = 16000, [4] = 24000, [5] = 32000 }
local ACOL = { [1] = COLOR_GREY, [2] = COLOR_WHITE, [3] = COLOR_LIGHTCYAN, [4] = COLOR_YELLOW, [5] = COLOR_LIGHTRED }

-- Add a line for the overlay (utf8). Returns false on duplicate (same text < 20 s).
local function add_line(text, prio)
  text = strip(text)
  if text == '' then return false end
  local t = now()
  for i = #S.lines, math.max(1, #S.lines - 8), -1 do
    local l = S.lines[i]
    if l.text == text and t - l.t < 20000 then return false end
  end
  S.lines[#S.lines + 1] = { t = t, clock = os.date('%H:%M'), text = text, prio = prio or 2, ttl = TTL[prio or 2] or 14000 }
  while #S.lines > 40 do table.remove(S.lines, 1) end
  S.stats.lines = S.stats.lines + 1
  return true
end

local function announce(text, prio)
  if not S.announce then return end
  local t = now()
  if S.last_ann_t and t - S.last_ann_t < 1200 then return end
  S.last_ann_t = t
  pcall(function()
    dfhack.gui.showAnnouncement(dfhack.utf2df(ucut(defuse('Claude: ' .. strip(text)), 110)), ACOL[prio or 2] or COLOR_WHITE, (prio or 2) >= 3)
  end)
end

-- ---------------------------------------------------------------- Protection / focus
local function mi_keys()
  if S.mi_keys then return S.mi_keys end
  local ks = {}
  local mi = df.global.game.main_interface
  for k, v in pairs(mi) do
    local ok, o = pcall(function() return v.open end)
    if ok and type(o) == 'boolean' then ks[#ks + 1] = k end
  end
  S.mi_keys = ks
  return ks
end

-- true only for a calm map view without menu/sheet/popup
local function cam_allowed()
  local ok, res, why = pcall(function()
    if not util.fort_loaded() then return false, 'keine Festung' end
    local f = dfhack.gui.getCurFocus(true)
    if #f ~= 1 or f[1] ~= 'dwarfmode/Default' then return false, 'Fokus ' .. table.concat(f, ',') end
    local mi = df.global.game.main_interface
    for _, k in ipairs(mi_keys()) do
      local v = mi[k]
      if v and v.open then return false, 'Fenster ' .. k end
    end
    if mi.bottom_mode_selected ~= -1 then return false, 'Menue offen (Bottom-Modus)' end
    if mi.main_designation_selected ~= -1 then return false, 'Markierung aktiv' end
    local h = io.open(TOOLS .. 'pause.hold', 'r')
    if h then h:close() return false, 'pause.hold (Hauptthread arbeitet)' end
    return true, 'ok'
  end)
  if not ok then return false, 'Fehler: ' .. tostring(res) end
  return res, why
end

-- ---------------------------------------------------------------- Camera
local function view_size()
  local d = dfhack.gui.getDwarfmodeViewDims()
  return d.map_x2 - d.map_x1 + 1, d.map_y2 - d.map_y1 + 1
end
local function view_center()
  local w, h = view_size()
  return df.global.window_x + w // 2, df.global.window_y + h // 2, df.global.window_z
end
local function set_expect()
  S.expect = { x = df.global.window_x, y = df.global.window_y, z = df.global.window_z, follow = pi.follow_unit }
end

local function unit_pos(u)
  local x, y, z = dfhack.units.getPosition(u)
  if not x then return nil end
  return xyz2pos(x, y, z)
end

-- Pan smoothly to the target (position or unit); then follow the unit if needed. Jump on large distance.
local function move_to(pos, unit_id)
  S.pan_gen = S.pan_gen + 1
  local gen = S.pan_gen
  pi.follow_unit = -1
  local cx, cy = view_center()
  local d = math.max(math.abs(pos.x - cx), math.abs(pos.y - cy))
  local steps = (d <= 4 and 1) or (d > 70 and 1) or math.max(1, math.floor(prof_num('pan_steps', 4)))
  S.panning = true
  local i = 0
  local function step()
    if S.pan_gen ~= gen then return end
    local ok = pcall(function()
      i = i + 1
      local tx, ty, tz = pos.x, pos.y, pos.z
      if unit_id then
        local u = df.unit.find(unit_id)
        local up = u and unit_pos(u)
        if up then tx, ty, tz = up.x, up.y, up.z end
      end
      local f = i / steps
      local px = math.floor(cx + (tx - cx) * f + 0.5)
      local py = math.floor(cy + (ty - cy) * f + 0.5)
      dfhack.gui.revealInDwarfmodeMap(xyz2pos(px, py, (i == 1 or i == steps) and tz or df.global.window_z), true, false)
      if i >= steps then
        if unit_id then pi.follow_unit = unit_id end
        S.panning = false
        set_expect()
      end
    end)
    if not ok then S.panning = false S.expect = nil return end
    if i < steps then dfhack.timeout(7, 'frames', step) end
  end
  step()
end

-- ---------------------------------------------------------------- Event queue
local DWELL = { [0] = 20000, [1] = 8000, [2] = 8000, [3] = 9000, [4] = 10000, [5] = 12000 }
local MIN_GAP, MIN_GAP_HIGHER = 8000, 4000

-- ev: key, prio, pos | unit, text (line), line (bool), cam (bool), ttl
local function submit(ev)
  ev.t = now()
  ev.ttl = ev.ttl or 45000
  if ev.text and ev.line ~= false then add_line(ev.text, ev.prio) end
  S.stats.events = S.stats.events + 1
  if ev.cam == false then return end
  for i, q in ipairs(S.queue) do
    if q.key == ev.key then S.queue[i] = ev return end
  end
  S.queue[#S.queue + 1] = ev
end

local function mode_allows(ev)
  local m = S.mode
  if m == 'follow' then return false end
  if m == 'combat' then return ev.prio >= 4 end
  return m == 'auto' or m == 'events'
end

-- ---------------------------------------------------------------- Detectors
local RT = nil   -- message type -> { label, prio, cam }
local function report_table()
  if RT then return RT end
  RT = {}
  local function add(names, label, prio, cam)
    for _, n in ipairs(names) do
      local id = df.announcement_type[n]
      if id then RT[id] = { label = label, prio = prio, cam = cam } end
    end
  end
  add({ 'CITIZEN_DEATH' }, 'Tod', 4, true)
  add({ 'AMBUSH_DEFENDER', 'AMBUSH_RESIDENT', 'AMBUSH_THIEF', 'AMBUSH_THIEF_SUPPORT_SKULKING', 'AMBUSH_THIEF_SUPPORT_NATURE',
        'AMBUSH_THIEF_SUPPORT', 'AMBUSH_MISCHIEVOUS', 'AMBUSH_SNATCHER', 'AMBUSH_SNATCHER_SUPPORT', 'AMBUSH_AMBUSHER_NATURE',
        'AMBUSH_AMBUSHER', 'AMBUSH_OTHER', 'BEAST_AMBUSH', 'MEGABEAST_ARRIVAL', 'WEREBEAST_ARRIVAL', 'UNDEAD_ATTACK',
        'NIGHT_ATTACK_STARTS', 'GHOST_ATTACK', 'CITIZEN_SNATCHED' }, 'ANGRIFF', 5, true)
  add({ 'BERSERK_CITIZEN', 'CITIZEN_TANTRUM', 'CITIZEN_LOST_TO_STRESS', 'POSSESSED_TANTRUM', 'CAVE_COLLAPSE', 'CITIZEN_MISSING',
        'BUILDING_TOPPLED_BY_GHOST', 'FOOD_WARNING' }, 'Achtung', 4, true)
  add({ 'STRANGE_MOOD', 'MOOD_BUILDING_CLAIMED', 'MADE_ARTIFACT', 'NAMED_ARTIFACT', 'ARTIFACT_BEGUN' }, 'Stimmung', 3, true)
  add({ 'STRUCK_DEEP_METAL', 'STRUCK_MINERAL', 'STRUCK_ECONOMIC_MINERAL', 'FEATURE_DISCOVERY' }, 'Fund', 3, true)
  add({ 'CARAVAN_ARRIVAL', 'FIRST_CARAVAN_ARRIVAL', 'MERCHANTS_UNLOADING', 'MERCHANTS_NEED_DEPOT', 'MERCHANT_WAGONS_BYPASSED',
        'MERCHANTS_LEAVING_SOON', 'DIPLOMAT_ARRIVAL', 'LIAISON_ARRIVAL', 'TRADE_DIPLOMAT_ARRIVAL', 'NOBLE_ARRIVAL',
        'MONARCH_ARRIVAL' }, 'Handel', 3, true)
  add({ 'MIGRANT_ARRIVAL_NAMED', 'MIGRANT_ARRIVAL', 'D_MIGRANTS_ARRIVAL', 'D_MIGRANT_ARRIVAL', 'BIRTH_CITIZEN' }, 'Neue Zwerge', 2, true)
  add({ 'MASTERPIECE_CRAFTED', 'MASTERPIECE_CONSTRUCTION', 'MASTERPIECE_ENGRAVING', 'MASTERFUL_IMPROVEMENT', 'COOKED_MASTERPIECE',
        'DYED_MASTERPIECE' }, 'Meisterwerk', 2, true)
  add({ 'SEASON_SPRING', 'SEASON_SUMMER', 'SEASON_AUTUMN', 'SEASON_WINTER' }, 'Zeit', 1, false)
  -- Combat reports: aggregate all COMBAT_*
  RT.combat = {}
  for i = 0, 400 do
    local n = df.announcement_type[i]
    if n and (n:find('^COMBAT_') or n:find('^UNIT_PROJECTILE')) then RT.combat[i] = true end
  end
  return RT
end

local function valid_pos(p)
  return p and p.x and p.x >= 0 and dfhack.maps.isValidTilePos(p.x, p.y, p.z)
end

local function short(s, n) return ucut(strip(dfhack.df2utf(s)), n) end

local function depot_pos()
  for _, b in ipairs(df.global.world.buildings.all) do
    if df.building_type[b:getType()] == 'TradeDepot' then return xyz2pos((b.x1 + b.x2) // 2, (b.y1 + b.y2) // 2, b.z) end
  end
end

local function detect_reports()
  local rt = report_table()
  local reps = df.global.world.status.reports
  local n = #reps
  if n == 0 then return end
  if not S.last_report then S.last_report = reps[n - 1].id return end
  local newest = S.last_report
  local combat_n, combat_pos, combat_txt = 0, nil, nil
  for i = n - 1, math.max(0, n - 60), -1 do
    local r = reps[i]
    if r.id <= S.last_report then break end
    if r.id > newest then newest = r.id end
    local txt = dfhack.df2utf(r.text)
    if r.type ~= 0 and not txt:find('^Claude:') then
      if rt.combat[r.type] then
        combat_n = combat_n + 1
        if not combat_pos and valid_pos(r.pos) then combat_pos = xyz2pos(r.pos.x, r.pos.y, r.pos.z) end
        combat_txt = combat_txt or short(r.text, 46)
      else
        local m = rt[r.type]
        if m then
          local pos = valid_pos(r.pos) and xyz2pos(r.pos.x, r.pos.y, r.pos.z) or nil
          if not pos and m.label == 'Handel' then pos = depot_pos() end
          submit({ key = 'rep:' .. r.id, prio = m.prio, pos = pos, cam = m.cam and pos ~= nil,
                   text = m.label .. ': ' .. short(r.text, 58), kind = m.label })
        end
      end
    end
  end
  S.last_report = newest
  if combat_n > 0 and (S.enemy_n or 0) > 0 then   -- do not show sparring/training without enemies (the player 01.10.2026)
    local t = now()
    local line = (not S.combat_line_t) or t - S.combat_line_t > 6000
    if line then S.combat_line_t = t end
    submit({ key = 'combat', prio = 5, pos = combat_pos, cam = combat_pos ~= nil, line = line, kind = 'Kampf', ttl = 20000,
             text = 'Kampf: ' .. (combat_txt or '') .. (combat_n > 1 and (' (+' .. (combat_n - 1) .. ')') or '') })
    S.combat_t = t
  end
end

local function cfg() return reqscript('claude/config') end

local function uname(u) return short(dfhack.units.getReadableName(u), 30) end
-- Dwarves: 'First Last (profession)' without nicknames
local function dname(u)
  local ok, r = pcall(function()
    local n = dfhack.df2utf(dfhack.translation.translateName(dfhack.units.getVisibleName(u), false))
    local prof = dfhack.units.getProfessionName(u)
    return ucut(n, 26) .. ' (' .. ucut(tostring(prof), 14) .. ')'
  end)
  return ok and r or uname(u)
end

local function detect_enemies()
  local c = cfg()
  local cits = dfhack.units.getCitizens()
  local list = {}
  for _, u in ipairs(df.global.world.units.active) do
    if u.pos.x >= 0 and c.is_ground_enemy(u) and not util.unit_hidden(u) then list[#list + 1] = u end
  end
  S.enemy_n = #list
  if #list == 0 then S.enemy_ids = {} S.enemy_since = nil return end
  S.enemy_ids = S.enemy_ids or {}
  local seen, new = {}, {}
  local best, bestd
  for _, u in ipairs(list) do
    seen[u.id] = true
    if not S.enemy_ids[u.id] then new[#new + 1] = u end
    local d = 999
    for _, ct in ipairs(cits) do
      local p = ct.pos
      if p.x >= 0 then d = math.min(d, math.max(math.abs(p.x - u.pos.x), math.abs(p.y - u.pos.y)) + 2 * math.abs(p.z - u.pos.z)) end
    end
    if not bestd or d < bestd then best, bestd = u, d end
  end
  S.enemy_ids = seen
  local t = now()
  if #new > 0 then
    submit({ key = 'enemy:new', prio = 5, unit = new[1].id, kind = 'Feind', ttl = 30000, dwell = 12000,
             text = 'FEIND in Sicht: ' .. uname(new[1]) .. ' (' .. #list .. ' gesamt, Abstand ' .. bestd .. ')',
             line = (not S.enemy_line_t) or t - S.enemy_line_t > 15000 })
    S.enemy_line_t = t
    S.enemy_cam_t = t
  elseif t - (S.enemy_cam_t or 0) > (bestd and bestd <= 45 and 15000 or 30000) then
    S.enemy_cam_t = t
    submit({ key = 'enemy:rev', prio = 5, unit = best.id, kind = 'Feind', ttl = 20000, dwell = 10000, line = false,
             text = 'Feind: ' .. uname(best) })
  end
end

local function detect_mood()
  S.mood_seen = S.mood_seen or {}
  local cur = {}
  for _, u in ipairs(dfhack.units.getCitizens()) do
    if u.mood ~= -1 and u.mood ~= nil and dfhack.units.isAlive(u) then
      cur[u.id] = true
      if not S.mood_seen[u.id] and S.mood_baseline then
        submit({ key = 'mood:' .. u.id, prio = 3, unit = u.id, kind = 'Stimmung',
                 text = 'Stimmung: ' .. dname(u) .. ' (' .. tostring(df.mood_type[u.mood]) .. ')' })
      end
    end
  end
  S.mood_seen = cur
  S.mood_baseline = true
end

local function detect_caravan()
  local car = #pi.caravans > 0
  if car and not S.caravan then
    local target
    for _, u in ipairs(df.global.world.units.active) do
      if u.flags1.merchant and dfhack.units.isActive(u) and u.pos.x >= 0 and not util.unit_hidden(u) then target = u break end
    end
    submit({ key = 'caravan', prio = 3, unit = target and target.id or nil, pos = (not target) and depot_pos() or nil,
             kind = 'Handel', text = 'Handel: Karawane ist da' })
  end
  S.caravan = car
end

local function detect_alert()
  local a = pi.alerts.civ_alert_idx ~= 0
  if S.alert_on ~= nil and a ~= S.alert_on then
    add_line(a and 'ALARM: Zivilwarnung AN - Zwerge gehen in Deckung' or 'Zivilwarnung wieder aus', a and 4 or 2)
  end
  S.alert_on = a
end

-- Buildings worth a camera trip (no small stuff like doors/beds/stockpiles)
local BLD_OK = { Workshop = true, Furnace = true, TradeDepot = true, FarmPlot = true, Well = true, Bridge = true, Trap = true,
  Cage = true, SiegeEngine = true, ScrewPump = true, WaterWheel = true, Windmill = true, Weapon = true, Statue = true }
local DE = { Carpenters = 'Tischlerei', Masons = 'Steinmetz', Craftsdwarfs = 'Handwerker', Kitchen = 'Kueche', Still = 'Brennerei',
  Butchers = "Metzger", Farmers = 'Farmer-Werkstatt', Fishery = 'Fischerei', Tanners = 'Gerberei', Loom = 'Webstuhl',
  Clothiers = 'Schneiderei', Leatherworks = 'Lederer', Bowyers = 'Bogner', Mechanics = 'Mechaniker', Jewelers = 'Juwelier',
  Ashery = 'Aescherei', Dyers = 'Faerberei', Quern = 'Muehle', MillStone = 'Muehlstein', Smelter = 'Schmelzofen',
  WoodFurnace = 'Holzkohle-Ofen', MagmaSmelter = 'Magma-Schmelzofen', Kiln = 'Brennofen', GlassFurnace = 'Glasofen',
  MetalsmithsForge = 'Schmiede', Screwpress = 'Presse', Siege = 'Belagerung', TradeDepot = 'Handelsdepot',
  FarmPlot = 'Feld', Well = 'Brunnen', Bridge = 'Bruecke', Trap = 'Falle', Cage = 'Kaefig' }

local function bld_name(b)
  local t = df.building_type[b:getType()] or '?'
  local sub
  if t == 'Workshop' then sub = df.workshop_type[b:getSubtype()]
  elseif t == 'Furnace' then sub = df.furnace_type[b:getSubtype()]
  end
  local n = sub or t
  return DE[n] or n
end

local function bld_complete(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return (not ok) or r
end

local function detect_buildings()
  S.bld_known = S.bld_known or {}    -- id -> 'done' | 'pending'
  local first = not S.bld_baseline
  for _, b in ipairs(df.global.world.buildings.all) do
    local t = df.building_type[b:getType()]
    if BLD_OK[t] then
      local st = S.bld_known[b.id]
      local done = bld_complete(b)
      if st ~= 'done' then
        if done then
          S.bld_known[b.id] = 'done'
          if not first then
            submit({ key = 'bld:' .. b.id, prio = 2, kind = 'Bau', pos = xyz2pos((b.x1 + b.x2) // 2, (b.y1 + b.y2) // 2, b.z),
                     text = 'Bau fertig: ' .. bld_name(b) })
          end
        else
          S.bld_known[b.id] = 'pending'
        end
      end
    end
  end
  S.bld_baseline = true
end

-- Ambience: follow a working dwarf
local JOB_W = {
  -- the player 01.10.2026: prefer furniture/construction, burial, harvest, fetching water over showing fights/sparring
  { '^PlaceItemInTomb', 8 }, { '^ConstructBuilding', 7 }, { '^Construct', 6 }, { '^PlantSeeds', 6 }, { '^HarvestPlants', 6 },
  { '^GatherPlants', 6 }, { '^GiveWater', 7 }, { '^FillWaterskin', 5 }, { '^PullLever', 5 }, { '^DestroyBuilding', 4 },
  { '^PrepareMeal', 4 }, { '^Brew', 4 },
  { '^Dig', 3 }, { '^Carve', 3 }, { '^Fell', 3 }, { '^Gather', 2 },
  { '^Make', 3 }, { '^Construct', 3 }, { '^Brew', 3 }, { '^Prepare', 3 }, { '^Smelt', 3 }, { '^Forge', 3 }, { '^Weave', 3 },
  { '^Spin', 3 }, { '^Cut', 3 }, { '^Engrave', 3 }, { '^Mill', 2 }, { '^Process', 2 }, { '^Butcher', 2 }, { '^Tan', 2 },
  { '^Plant', 2 }, { '^Harvest', 2 }, { '^Fish', 2 }, { '^Hunt', 2 }, { '^Extract', 2 }, { '^Collect', 2 }, { '^Store', 1 },
  { '^Haul', 1 }, { '^Clean', 1 }, { '^Sleep', 0 }, { '^Rest', 0 }, { '^Eat', 0 }, { '^Drink', 0 }, { '^Get', 0 },
}
local function job_cat(n)
  if not n then return 'none' end
  for _, c in ipairs({ 'Dig', 'Carve', 'Construct', 'Plant', 'Harvest', 'Gather', 'PlaceItemInTomb', 'GiveWater', 'Brew', 'Prepare', 'Store', 'Haul', 'Make', 'Engrave', 'Eat', 'Drink' }) do
    if n:find('^' .. c) then return c end
  end
  return n
end
-- Weight of a job name for the ambient pick (profile table if loaded, else JOB_W) and its stats category.
-- n = nil: unit without a job; soldiers without a job (training/sparring) get almost no weight.
function weight_for(n, soldier)
  if not n then
    if soldier then return prof_num('soldier_idle_weight', 0.005), 'soldier_idle' end
    return prof_num('idle_weight', 0.01), 'idle'
  end
  for _, e in ipairs((S.profile and S.profile.job_w) or JOB_W) do
    if n:find(e[1]) then return e[2], e[3] end
  end
  return prof_num('default_weight', 1), nil
end
local function job_weight(u)
  local j = u.job.current_job
  if not j then return (weight_for(nil, u.military.squad_id >= 0)), nil end
  local n = df.job_type[j.job_type] or ''
  return (weight_for(n, false)), n
end

-- category statistics of the last 30 minutes (python -m df_llm_helper camera stats)
local STAT_WINDOW = 30 * 60 * 1000
local function record_pick(cat)
  S.picks = S.picks or {}
  local t = now()
  S.picks[#S.picks + 1] = { t = t, c = cat }
  while #S.picks > 0 and (t - S.picks[1].t > STAT_WINDOW or #S.picks > 2000) do table.remove(S.picks, 1) end
end
function pick_stats()
  local out, t = {}, now()
  for _, p in ipairs(S.picks or {}) do
    if t - p.t <= STAT_WINDOW then out[p.c] = (out[p.c] or 0) + 1 end
  end
  return out
end

local function was_recent(id)
  for _, r in ipairs(S.recent) do if r == id then return true end end
  return false
end

local JOB_DE = { Dig = 'graeb', DigChannel = 'graeb Kanal', ConstructBuilding = 'baut', DestroyBuilding = 'reisst ab', FellTree = 'faellt Baum',
  GatherPlants = 'sammelt', BrewDrink = 'braut', PrepareMeal = 'kocht', CarveUpwardStaircase = 'graeb Treppe',
  CarveDownwardStaircase = 'graeb Treppe', CarveUpDownStaircase = 'graeb Treppe', CarveRamp = 'graeb Rampe',
  StoreItemInStockpile = 'lagert ein', Fish = 'angelt', PlantSeeds = 'pflanzt', HarvestPlants = 'erntet', PlaceItemInTomb = 'bestattet', GiveWater = 'bringt Wasser', FillWaterskin = 'holt Wasser', ConstructBed = 'baut Bett', PullLever = 'zieht Hebel', Brew = 'braut' }
local function caption_for(u)
  local j = u.job.current_job
  local jn = j and (df.job_type[j.job_type] or '') or ''
  local jt = JOB_DE[jn] or (jn ~= '' and jn or 'ruht')
  return 'Blick: ' .. dname(u) .. ' - ' .. jt
end

local function pick_follow()
  local cands, total = {}, 0
  for _, u in ipairs(dfhack.units.getCitizens()) do
    if u.pos.x >= 0 and dfhack.units.isAlive(u) and not u.flags1.inactive then
      local w, jn = job_weight(u)
      if w > 0 then
        if was_recent(u.id) then w = w * prof_num('recent_factor', 0.15) end
        if S.last_cat and job_cat(jn) == S.last_cat then w = w * prof_num('variety_factor', 0.3) end   -- variety: not the same activity twice
        cands[#cands + 1] = { u = u, w = w }
        total = total + w
      end
    end
  end
  if total <= 0 then return nil end
  local pick = cands[#cands]
  local rr = math.random() * total
  for _, c in ipairs(cands) do rr = rr - c.w if rr <= 0 then pick = c break end end
  local _, jn2 = job_weight(pick.u)
  S.last_cat = job_cat(jn2)
  local _, pc = weight_for(jn2, pick.u.military.squad_id >= 0)
  S.pick_cat = pc or job_cat(jn2)
  return pick.u
end

-- ---------------------------------------------------------------- Director loop
local function unit_ok(id)
  local u = id and df.unit.find(id)
  return u and dfhack.units.isActive(u) and not dfhack.units.isDead(u) and u.pos.x >= 0
end

local function apply(ev, ambient_unit)
  local t = now()
  local unit_id = ev.unit or (ambient_unit and ambient_unit.id)
  local pos = ev.pos
  if unit_id then
    local u = df.unit.find(unit_id)
    pos = u and unit_pos(u)
  end
  if not valid_pos(pos) then return false end
  move_to(pos, unit_id)
  S.cam_t = t
  record_pick(((ev.prio or 0) == 0 and (S.pick_cat or 'idle')) or ('event:' .. tostring(ev.kind or '?')))
  S.cur = { prio = ev.prio or 0, key = ev.key, kind = ev.kind or 'Ambiente', unit = unit_id,
            until_ = t + (ev.dwell or DWELL[ev.prio or 0] or 8000), t = t }
  S.caption = ev.caption or ev.text
  if unit_id and not ev.text then
    local u = df.unit.find(unit_id)
    if u then S.caption = caption_for(u) end
  end
  if unit_id then
    table.insert(S.recent, 1, unit_id)
    while #S.recent > 4 do table.remove(S.recent) end
    S.stats.follows = S.stats.follows + 1
  else
    S.stats.jumps = S.stats.jumps + 1
  end
  return true
end

-- Did the player move the view themselves? (follow ended by the game / window differs from our position)
local function user_moved()
  local e = S.expect
  if not e or S.panning then return false end
  if e.follow >= 0 then
    if pi.follow_unit ~= e.follow then return unit_ok(e.follow) end
    -- Follow still set, but the view no longer shows the unit (window moved) -> user scrolled
    local u = df.unit.find(e.follow)
    local p = u and unit_pos(u)
    if p and unit_ok(e.follow) and now() - (S.cam_t or 0) > 2500 then
      local cx, cy, cz = view_center()
      local w, h = view_size()
      if math.abs(p.x - cx) > w // 2 + 4 or math.abs(p.y - cy) > h // 2 + 4 or p.z ~= cz then
        S.off_view = (S.off_view or 0) + 1
        return S.off_view >= 2
      end
    end
    S.off_view = 0
    return false
  end
  return df.global.window_x ~= e.x or df.global.window_y ~= e.y or df.global.window_z ~= e.z
end

local function tick_inner()
  if not util.fort_loaded() then return end
  if not S.enabled or S.mode == 'off' then return end
  local t = now()
  if t < S.next_eval then return end
  S.next_eval = t + 800

  -- Detectors always run (text lines should appear even when the camera is currently locked)
  pcall(detect_reports)
  if t >= S.t_units then
    S.t_units = t + 2000
    pcall(detect_enemies) pcall(detect_mood) pcall(detect_caravan) pcall(detect_alert)
  end
  if t >= S.t_bld then S.t_bld = t + 4000 pcall(detect_buildings) end

  local ok, why = cam_allowed()
  S.gate = why
  if not ok then S.expect = nil return end

  -- User priority
  if user_moved() then
    S.stats.user_moves = S.stats.user_moves + 1
    S.hold_until = t + 45000
    S.hold_override_at = t + 15000
    S.expect, S.cur, S.caption = nil, nil, nil
    add_line('Kamera-Regie pausiert 45 s (Ansicht bewegt)', 1)
    return
  end
  if t < S.hold_until then
    -- User priority: only an alarm (prio 5) may break it after 15 s; explicit hold (main thread) never
    local has5 = false
    for _, q in ipairs(S.queue) do if q.prio >= 5 then has5 = true end end
    if not (has5 and S.hold_override_at and t >= S.hold_override_at) then return end
  end

  -- remove expired events, choose candidates
  local best
  for i = #S.queue, 1, -1 do
    local q = S.queue[i]
    if t - q.t > q.ttl or not mode_allows(q) then table.remove(S.queue, i) end
  end
  for _, q in ipairs(S.queue) do
    if not best or q.prio > best.prio or (q.prio == best.prio and (q.prio >= 4 and q.t > best.t or q.prio < 4 and q.t < best.t)) then
      best = q
    end
  end
  local cur = S.cur
  local since = t - S.cam_t
  local cur_prio = cur and cur.prio or -1
  if best then
    local can = (not cur or (t >= cur.until_ and since >= MIN_GAP)) or (best.prio > cur_prio and since >= MIN_GAP_HIGHER)
    if can then
      for i, q in ipairs(S.queue) do if q == best then table.remove(S.queue, i) break end end
      if apply(best) then return end
    end
  end
  -- maintain current target (update subtitle, replace lost unit)
  if cur and cur.unit and not unit_ok(cur.unit) then S.cur = nil cur = nil end
  if cur and cur.unit and cur.kind == 'Ambiente' then
    local u = df.unit.find(cur.unit)
    if u then S.caption = caption_for(u) end
  end
  -- Ambience mode: follow a working dwarf
  if (S.mode == 'auto' or S.mode == 'follow') and (not cur or (t >= cur.until_ and since >= MIN_GAP)) then
    local u = pick_follow()
    if u then
      local d1, d2 = prof_num('dwell_min_s', 18) * 1000, prof_num('dwell_max_s', 24) * 1000
      apply({ prio = 0, kind = 'Ambiente', dwell = math.floor(d1 + math.random() * math.max(0, d2 - d1)) }, u)
    end
  end
end

function tick()
  local ok, err = pcall(tick_inner)
  if not ok then
    S.stats.errors = S.stats.errors + 1
    S.last_error = tostring(err)
  end
end

-- ---------------------------------------------------------------- Public commands
local MODES = { auto = true, follow = true, events = true, combat = true, off = true }

function start(mode)
  defaults()
  S.enabled = true
  if mode and MODES[mode] and mode ~= 'off' then S.mode = mode elseif S.mode == 'off' then S.mode = 'auto' end
  -- Baselines: do not replay earlier messages/buildings/moods
  S.last_report, S.bld_baseline, S.mood_baseline, S.caravan, S.alert_on = nil, false, false, nil, nil
  S.bld_known, S.queue, S.expect, S.cur, S.caption, S.enemy_ids = {}, {}, nil, nil, nil, {}
  S.next_eval, S.t_units, S.t_bld, S.hold_until = 0, 0, 0, 0
  S.enemy_cam_t = nil
  pcall(load_profile)   -- a profile chosen earlier with python -m df_llm_helper camera (no file: built-in weights)
  repeatUtil.scheduleEvery(KEY, 20, 'frames', tick)
  S.running = true
  add_line('Schau: Kamera-Regie an (' .. S.mode .. ')', 1)
end

function stop()
  repeatUtil.cancel(KEY)
  S.running = false
  S.pan_gen = S.pan_gen + 1
  S.panning = false
  S.expect, S.cur, S.caption = nil, nil, nil
  S.queue = {}
end

function set_mode(m)
  if not MODES[m] then return false end
  if m == 'off' then stop() S.mode = 'off' return true end
  S.mode = m
  if not S.running then start(m) end
  return true
end

function hold(secs)
  S.hold_until = now() + (secs or 120) * 1000
  S.hold_override_at = nil
  S.expect, S.caption = nil, nil
  S.pan_gen = S.pan_gen + 1
  S.panning = false
end
function release() S.hold_until = 0 end

function say(text, prio)
  if not S.enabled then return { ok = false, error = 'schau ist aus (claude/schau on)' } end
  prio = parse_prio(prio, 2)
  text = strip(text)
  local t = now()
  if S.last_say_t and t - S.last_say_t < 700 then return { ok = true, shown = false, why = 'Rate-Limit' } end
  local added = add_line(text, prio)
  if added then S.last_say_t = t announce(text, prio) end
  return { ok = true, shown = added }
end

function show(x, y, z, text, prio, unit_id)
  if not S.enabled then return { ok = false, error = 'schau ist aus (claude/schau on)' } end
  prio = parse_prio(prio, 3)
  text = strip(text)
  local pos, u
  if unit_id then
    u = df.unit.find(unit_id)
    pos = u and unit_pos(u)
    if not pos then return { ok = false, error = 'Einheit nicht gefunden' } end
  else
    if not (x and y and z and dfhack.maps.isValidTilePos(x, y, z)) then return { ok = false, error = 'ungueltige Koordinaten' } end
    pos = xyz2pos(x, y, z)
  end
  local t = now()
  local lt, lp = S.last_show_t, S.last_show_prio or 0
  local limited = lt and (t - lt < 8000) and not (prio > lp and t - lt >= 3000)
  if limited then
    add_line(text, prio)   -- text always counts, only the camera is limited
    return { ok = true, cam = false, why = 'Rate-Limit (max. 1 Kamerafahrt pro 8 s; Text wird trotzdem angezeigt)' }
  end
  add_line(text, prio)
  announce(text, prio)
  local g, why = cam_allowed()
  if not g then return { ok = true, cam = false, why = why .. ' (Text angezeigt)' } end
  if t < S.hold_until and prio < 5 then return { ok = true, cam = false, why = 'Kamera-Vorrang aktiv (Nutzer/Hauptthread) - Text angezeigt' } end
  S.last_show_t, S.last_show_prio = t, prio
  pi.follow_unit = -1
  move_to(pos, nil)
  S.cur = { prio = math.max(prio, 3), kind = 'show', until_ = t + 10000, t = t, key = 'show' }
  S.cam_t = t
  S.caption = 'Zeigt: ' .. ucut(text, 60)
  S.expect = nil
  S.stats.jumps = S.stats.jumps + 1
  return { ok = true, cam = true, x = pos.x, y = pos.y, z = pos.z }
end

function clear() S.lines = {} S.caption = nil end

function set_enabled(on)
  S.enabled = on and true or false
  if not on then stop() S.lines = {} end
end

function status()
  local g, why = cam_allowed()
  local t = now()
  local q = {}
  for _, e in ipairs(S.queue) do q[#q + 1] = e.key .. '/p' .. e.prio end
  local lines = {}
  for i = math.max(1, #S.lines - 4), #S.lines do
    local l = S.lines[i]
    lines[#lines + 1] = l.clock .. ' p' .. l.prio .. ' ' .. dfhack.utf2df(l.text)
  end
  return {
    enabled = S.enabled, running = S.running or false, mode = S.mode, gate = g, gate_reason = why,
    hold_s = math.max(0, math.floor(((S.hold_until or 0) - t) / 1000)),
    cur = S.cur and (S.cur.kind .. ' p' .. S.cur.prio .. ' noch ' .. math.max(0, math.floor((S.cur.until_ - t) / 1000)) .. 's') or nil,
    caption = S.caption and dfhack.utf2df(S.caption) or nil, queue = q, enemies = S.enemy_n or 0,
    stats = S.stats, last_error = S.last_error, announce = S.announce, recent_lines = lines,
    focus = table.concat(dfhack.gui.getCurFocus(true), ','), paused = df.global.pause_state,
    window = { x = df.global.window_x, y = df.global.window_y, z = df.global.window_z, follow = pi.follow_unit },
    profile = S.profile and tostring(S.profile.name or '?') or 'builtin', cats = pick_stats(),
  }
end

-- ---------------------------------------------------------------- Overlay (text panel top left)
local PANEL_W, PANEL_H = 74, 12
local function panel_rows()
  local t = now()
  local rows = {}
  local vis = {}
  for i = #S.lines, 1, -1 do
    local l = S.lines[i]
    if t - l.t < l.ttl then table.insert(vis, 1, l) end
    if #vis >= 8 then break end
  end
  for _, l in ipairs(vis) do
    local w = wrap(l.text, PANEL_W - 2 - 6, 2)
    for k, r in ipairs(w) do
      rows[#rows + 1] = { text = (k == 1 and (l.clock .. ' ') or '      ') .. r, prio = l.prio }
    end
  end
  while #rows > PANEL_H - 1 do table.remove(rows, 1) end
  if S.caption and S.running and S.enabled and S.mode ~= 'off' then
    rows[#rows + 1] = { text = ucut('> ' .. S.caption, PANEL_W - 2), prio = 0 }
  end
  return rows
end

local CAP_COL = COLOR_LIGHTGREEN
SchauLog = defclass(SchauLog, overlay.OverlayWidget)
SchauLog.ATTRS {
  desc = 'Claude-Spectate: kurze Textzeilen zu Ereignissen und Aktionen (nur Anzeige, keine Eingabe).',
  default_pos = { x = 2, y = 6 },
  default_enabled = true,
  viewscreens = 'dwarfmode/Default',
  frame = { w = PANEL_W, h = PANEL_H },
  active = false,   -- nimmt nie Eingaben an
}
function SchauLog:init()
  self.visible = function()
    if not S.enabled then return false end
    local ok, r = pcall(function()
      if S.caption and S.running and S.mode ~= 'off' then return true end
      local t = now()
      for i = #S.lines, math.max(1, #S.lines - 10), -1 do
        local l = S.lines[i]
        if t - l.t < l.ttl then return true end
      end
      return false
    end)
    return ok and r
  end
end
function SchauLog:onRenderBody(dc)
  pcall(function()
    local rows = panel_rows()
    for i, r in ipairs(rows) do
      local col = (r.prio == 0) and CAP_COL or (ACOL[r.prio] or COLOR_WHITE)
      dc:seek(0, i - 1):string(' ' .. dfhack.utf2df(r.text) .. ' ', { fg = col, bg = COLOR_BLACK })
    end
  end)
end

OVERLAY_WIDGETS = { log = SchauLog }

-- ---------------------------------------------------------------- Command line
function cli(a)
  local cmd = a[1] or 'status'
  if cmd == 'start' then
    start(a[2])
    util.emit({ ok = true, started = true, mode = S.mode })
  elseif cmd == 'stop' then
    stop()
    util.emit({ ok = true, stopped = true })
  elseif cmd == 'mode' then
    local ok = set_mode(a[2] or '')
    util.emit({ ok = ok, mode = S.mode, error = (not ok) and 'Modus: auto|follow|events|combat|off' or nil })
  elseif cmd == 'off' then
    set_enabled(false)
    util.emit({ ok = true, enabled = false })
  elseif cmd == 'on' then
    set_enabled(true)
    util.emit({ ok = true, enabled = true, hint = 'Regie mit claude/schau start' })
  elseif cmd == 'clear' then
    clear()
    util.emit({ ok = true })
  elseif cmd == 'hold' then
    hold(tonumber(a[2]) or 120)
    util.emit({ ok = true, hold_s = tonumber(a[2]) or 120 })
  elseif cmd == 'release' then
    release()
    util.emit({ ok = true })
  elseif cmd == 'announce' then
    S.announce = (a[2] ~= 'off')
    util.emit({ ok = true, announce = S.announce })
  elseif cmd == 'say' then
    local words = {}
    for i = 2, #a do words[#words + 1] = from_arg(a[i]) end
    local prio
    if #words >= 2 and (tonumber(words[#words]) or PRIO_WORDS[words[#words]:lower()]) then prio = table.remove(words) end
    util.emit(say(table.concat(words, ' '), prio))
  elseif cmd == 'show' then
    local words = {}
    for i = 2, #a do words[#words + 1] = from_arg(a[i]) end
    local unit_id, x, y, z
    if words[1] == 'unit' then
      unit_id = tonumber(words[2]); table.remove(words, 1); table.remove(words, 1)
    else
      x, y, z = tonumber(words[1]), tonumber(words[2]), tonumber(words[3])
      table.remove(words, 1); table.remove(words, 1); table.remove(words, 1)
    end
    local prio
    if #words >= 2 and (tonumber(words[#words]) or PRIO_WORDS[words[#words]:lower()]) then prio = table.remove(words) end
    util.emit(show(x, y, z, table.concat(words, ' '), prio, unit_id))
  elseif cmd == 'status' then
    util.emit(status())
  elseif cmd == 'profile' then
    if a[2] == 'reload' then
      local ok, r = load_profile()
      util.emit({ ok = ok, profile = ok and r or nil, error = (not ok) and r or nil })
    elseif a[2] == 'default' then
      clear_profile()
      util.emit({ ok = true, profile = 'builtin' })
    else
      util.emit({ ok = true, profile = S.profile and tostring(S.profile.name or '?') or 'builtin', cats = pick_stats() })
    end
  else
    util.emit({ ok = false, error = 'Aufruf: start [modus] | stop | status | mode m | say "text" [prio] | show x y z "text" [prio] | show unit id "text" | hold [s] | release | on | off | clear | announce on|off | profile reload|default' })
  end
end

if dfhack_flags and dfhack_flags.module then return end

if not util.require_fort() then return end
reqscript('claude/schau').cli({ ... })
