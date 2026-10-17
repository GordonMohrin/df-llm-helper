-- act: the ONLY code that writes game state (CONTRACTS §5, DESIGN §11.2). Every function maps to a
-- UI action, returns ok, res_or_err, never raises, logs one commands.log line and emits ACT_FAIL (B)
-- on failure. Callers are checked against contract.ACT. [S#] marks behaviour a live spike must confirm.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local OL = require('dfllm.orderlib')

local A = {}

A.ORDER_LIBS = {['library/basic'] = true, ['library/furnace'] = true, ['library/smelting'] = true,
                ['library/military'] = true, ['library/rockstock'] = true, ['library/glassstock'] = true}
local QF_MODES = {dig = true, build = true, place = true, zone = true, burrow = true}
local QF_COMMANDS = {run = true, orders = true, undo = true}
local ITEM_FLAGS = {forbid = true, dump = true, melt = true}
-- builtin work details whose membership act.work_detail may change (each holds one tool labor; live L5: the
-- fishers too, economy staffs them while food is short and a fishing zone exists; FR-25: the planters and the
-- plant gatherers in a starvation, by the names DF 53 may give the gathering detail [live-untested])
A.TOOL_DETAILS = {Miners = true, Woodcutters = true, Hunters = true, Fisherdwarves = true, Planters = true,
                  ['Plant gatherers'] = true, Gatherers = true, Herbalists = true}
-- the details whose labor needs a tool (pick, axe, crossbow, rod): a specialist (work_detail opts.only) keeps them
A.TOOL_LABOR_DETAILS = {Miners = true, Woodcutters = true, Hunters = true, Fisherdwarves = true}
-- BUG-023 (Run 11): the tool labors one dwarf may hold only one of (DFHack manipulator.cpp `special` columns: MINE,
-- CUTWOOD, HUNT are "mutually exclusive"; autolabor: "all the exclusive labors require equipment"), by their detail
A.TOOL_EXCL = {Miners = 'MINE', Woodcutters = 'CUTWOOD', Hunters = 'HUNT'}
-- the doctor labors act.medic switches and the hospital posts act.hospital_post fills (FR-48)
A.MEDIC_LABORS = {'DIAGNOSE', 'SURGERY', 'BONE_SETTING'}
A.HOSPITAL_POSTS = {DOCTOR = true, DIAGNOSTICIAN = true, SURGEON = true, BONE_DOCTOR = true}
-- one-time furniture orders act.order_material may re-enter in wood (carpenter's variants of the mason jobs)
A.WOOD_JOBS = {ConstructDoor = true, ConstructCabinet = true, ConstructChest = true, ConstructCoffin = true,
               ConstructTable = true, ConstructThrone = true, ConstructArmorStand = true, ConstructWeaponRack = true,
               ConstructHatchCover = true, ConstructGrate = true, ConstructFloodgate = true}

-- Used when config/allowlist.json (WP4) is missing: read-only status queries only.
A.BUILTIN_ALLOWLIST = {v = 2, builtin = true, blocked = {}, armok_exceptions = {}, commands = {
  ['labormanager'] = {rw = 'r', args = {'status'}},
  ['pop-control'] = {rw = 'r', args = {'', 'status'}},
  ['timestream'] = {rw = 'r', args = {'', 'status'}},
}}

---------------------------------------------------------------- allowlist (CONTRACTS §9.14)
local function tokens(list)
  local t = {}
  for _, a in ipairs(list) do
    for tok in tostring(a):gmatch('[^ \t]+') do t[#t + 1] = tok end
  end
  return t
end

local function match_pattern(pat, toks)
  local p = tokens({pat})
  for i, pt in ipairs(p) do
    if pt == '**' then return true end
    if toks[i] == nil then return false end
    if pt ~= '*' and pt ~= toks[i] then return false end
  end
  return #toks == #p
end

-- ok, why: is `cmd args...` allowed by allowlist doc `al`?
function A.allowed(al, cmd, args)
  if type(cmd) ~= 'string' or not cmd:match('^[a-z0-9][a-z0-9/_%-]*$') then return false, 'bad command name' end
  local toks = tokens(args or {})
  local line = {cmd}
  for _, t in ipairs(toks) do line[#line + 1] = t end
  for _, b in ipairs(al.blocked or {}) do
    local bt = tokens({b})
    if #bt == 1 and bt[1]:sub(1, 1) == '-' then
      for _, t in ipairs(toks) do
        if t == bt[1] or t:sub(1, #bt[1] + 1) == bt[1] .. '=' then return false, 'blocked flag ' .. bt[1] end
      end
    elseif #bt > 0 then
      local prefix = true
      for i, w in ipairs(bt) do if line[i] ~= w then prefix = false; break end end
      if prefix then return false, 'blocked: ' .. b end
    end
  end
  local entry = (al.commands or {})[cmd]
  if not entry then return false, 'not allowlisted: ' .. cmd end
  local pats = entry.args or {}
  if #pats == 0 then
    if #toks == 0 then return true end
    return false, cmd .. ' takes no arguments'
  end
  for _, pat in ipairs(pats) do
    if match_pattern(pat, toks) then return true, entry end
  end
  return false, 'arguments not allowlisted for ' .. cmd
end

-- drop allowlisted commands tagged armok (helpdb.get_tag_data list) unless listed as exceptions
function A.armok_filter(al, armok_names)
  local exc, removed = {}, {}
  for _, n in ipairs(al.armok_exceptions or {}) do exc[n] = true end
  for _, n in ipairs(armok_names or {}) do
    if al.commands and al.commands[n] and not exc[n] then
      al.commands[n] = nil
      removed[#removed + 1] = n
    end
  end
  table.sort(removed)
  return removed
end

---------------------------------------------------------------- helpers
local function cr_ok() return rawget(_G, 'CR_OK') or 0 end
local function int(v) return math.type(v) == 'integer' and v or math.tointeger(v) end
local function xyz(p)
  if type(p) ~= 'table' then return nil end
  if p.x ~= nil then return p.x, p.y, p.z end
  return p[1], p[2], p[3]
end
local function trim(s, n)
  s = tostring(s or ''):gsub('[ \t\r\n]+$', '')
  if #s > (n or 300) then s = s:sub(1, n or 300) end
  return s
end
local function cmd_run(...)
  local out, cr = dfhack.run_command_silent(...)
  if cr ~= cr_ok() then return false, trim(out ~= '' and out or ('command failed: ' .. tostring(cr))) end
  return true, trim(out, 4000)
end

-- commands.log args: compact JSON, quickfort data summarized, ≤300 bytes. `ms` = cost of the call on
-- the cost clock (spike S6: apply_blueprint ms per chunk), quickfort only.
local function describe(fn, args, ms)
  local a = {}
  for i = 1, args.n do a[i] = args[i] end
  if fn == 'quickfort' and type(a[1]) == 'table' then
    local p, n = a[1], 0
    if type(p.data) == 'table' then
      for _, g in pairs(p.data) do for _, r in pairs(g) do for _ in pairs(r) do n = n + 1 end end end
    end
    a = {{mode = p.mode, command = p.command or 'run', pos = p.pos, cells = n, ms = ms,
          dry = p.dry_run == true and 1 or nil}}
  elseif fn == 'burrow_tiles' and type(a[2]) == 'table' then
    a = {a[1], {tiles = #a[2], first = a[2][1]}, a[3]}
  end
  local ok, s = pcall(json.encode, json.array(a))
  if not ok then s = '"?"' end
  if #s > 300 then s = s:sub(1, 297) .. '...' end
  return s
end

-- DFHack's gui library (hack/lua/gui.lua), required on first use: act.lua loads without it offline
local function gui_proxy()
  local g
  return setmetatable({}, {__index = function(_, k)
    if g == nil then
      local ok, m = pcall(require, 'gui')
      if not ok then error('gui library unavailable: ' .. tostring(m), 2) end
      g = m
    end
    return g[k]
  end})
end

---------------------------------------------------------------- act.trade (WP9, CONTRACTS §5)
-- I.trade(op, args), op = request_broker|open|mark|offer|close. tests/lua/trade_act_proposal.lua
-- re-exports this function for the click-level UI tests. [live-untested]
function A.install_trade(I, gui, int)
  -- BEGIN act.trade
  -- Depot sheet and trade screen as a player uses them. The Trade button sits in DFHack confirm's
  -- frame {l=0, r=23, b=4, w=11, h=3} of the interface rect (hack/scripts/internal/confirm/specs.lua:172,
  -- confirm.lua:69-76); with l and r both set gui.compute_frame_rect centres it (gui.lua:150-180).
  -- Offer (gift) and Seize are elsewhere and every click first reads its label "Trade" on the screen.
  -- DFHack's confirm prompts are modal ZScreens that force the pause (gui/dialogs.lua:83,
  -- gui.lua:1057-1072, :1200): only our own two prompts are ever answered or dismissed (Esc = "No").
  local TR = {}
  local TRADE_FRAME = {l = 0, r = 23, b = 4, w = 11, h = 3}
  local OUR_PROMPTS = {'trade the selected', 'selected items will not be saved'}   -- specs.lua:108,168
  local function tr_focus()
    local ok, f = pcall(dfhack.gui.getCurFocus, true)                   -- Lua API.txt:1144
    return ok and type(f) == 'table' and f or {}
  end
  local function tr_has(pat)
    for _, s in ipairs(tr_focus()) do if s:match(pat) then return true end end
    return false
  end
  local function tr_row(y, x1, x2)                                        -- Lua API.txt:2716
    local t = {}
    for x = x1, x2 do
      local p = dfhack.screen.readTile(x, y, false)
      local ch = p and p.ch
      t[#t + 1] = (type(ch) == 'number' and ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(t)
  end
  local function tr_label(x, y, word)       -- `word` at x.., no letter right before or after it
    local s = tr_row(y, x - 1, x + #word)
    return s:sub(2, #word + 1) == word and not s:sub(1, 1):match('[A-Za-z]') and not s:sub(-1):match('[A-Za-z]')
  end
  local function tr_click(x, y)             -- a mouse click at a UI tile (v1 handel.lua:700-703)
    df.global.gps.mouse_x, df.global.gps.mouse_y = x, y
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), '_MOUSE_L')
  end
  -- text of the DFHack dialog on top: DialogWindow is centred on the window (gui/dialogs.lua:62-75)
  -- and confirm wraps its message at 45 columns (confirm.lua:142), so rows h/2-8..h/2+8 and columns
  -- w/2-27..w/2+27 hold it (<= 935 tiles; drawn on the next render, not when the prompt opens)
  local function tr_dialog_text()
    local w, h = dfhack.screen.getWindowSize()                         -- Lua API.txt:2690
    local cx, cy, rows = w // 2, h // 2, {}
    for y = math.max(0, cy - 8), math.min(h - 1, cy + 8) do
      rows[#rows + 1] = tr_row(y, math.max(0, cx - 27), math.min(w - 1, cx + 27))
    end
    return table.concat(rows, '\n'):lower()
  end
  local function tr_our_prompt()            -- text of our confirm prompt on top, or nil
    if not tr_has('^dfhack/lua/MessageBox') then return nil end
    local s = tr_dialog_text()
    for _, p in ipairs(OUR_PROMPTS) do if s:find(p, 1, true) then return s end end
  end
  local function tr_dismiss()               -- Esc: ZScreen:onInput dismisses the dialog (gui.lua:1126)
    gui.simulateInput(dfhack.gui.getCurViewscreen(true), 'LEAVESCREEN')
  end
  local function tr_depot(id)
    local b = df.building.find(int(id) or -1)
    if not b or not df.building_tradedepotst:is_instance(b) then return nil end
    return b
  end
  local function tr_ready(t)
    if not t.open or t.choosing_merchant then return false, 'trade screen not ready' end
    if tr_has('^dfhack/') or not tr_has('^dwarfmode/Trade/Default') then return false, 'focus is not the trade screen' end
    if #t.good[0] ~= #t.goodflag[0] or #t.good[1] ~= #t.goodflag[1] then return false, 'trade lists out of sync' end
    return true
  end

  -- depot sheet toggles "Broker requested at depot" / "Anyone can Trade"; returns the old values
  function TR.request_broker(a)
    local d = tr_depot(a.depot)
    if not d then return false, 'no trade depot ' .. tostring(a.depot) end
    local tf = d.trade_flags
    local old = {requested = tf.trader_requested == true, anyone = tf.anyone_can_trade == true}
    if a.requested ~= nil then tf.trader_requested = a.requested == true end
    if a.anyone ~= nil then tf.anyone_can_trade = a.anyone == true end
    return true, old
  end

  -- live L4: DF 53 never posted the depot's TradeAtDepot job from the request toggle alone (Castlerisen
  -- y291: "Broker requested" and "Anyone can Trade" set for 27,500 ticks with the caravan at the depot, no
  -- job, no trade; v1 Run 6 saw the same and traded only once the job existed). This posts the job the
  -- request stands for: one TradeAtDepot job on the depot (building holder ref, like every workshop job),
  -- linked into the world for DF's own job picker. a.assign: a posted job nobody took is given to the
  -- broker, only while he has no job (nothing of his is cancelled; never anyone else). Refused while a
  -- TradeAtDepot job is on the depot already (one per depot), and never removes a job.
  function TR.broker_job(a)
    local d = tr_depot(a.depot)
    if not d then return false, 'no trade depot ' .. tostring(a.depot) end
    local jt = df.job_type.TradeAtDepot
    local job
    for _, j in ipairs(d.jobs) do if j.job_type == jt then job = j; break end end
    if job then
      if not a.assign then return true, 'exists' end
      if dfhack.job.getWorker(job) then return true, 'taken' end
      local u = dfhack.units.getUnitByNobleRole('broker')                -- Lua API.txt:1688
      if not u or dfhack.units.isDead(u) or not dfhack.units.isCitizen(u) or u.mood >= 0 then
        return false, 'no broker to assign'
      end
      if u.job.current_job then return true, 'broker busy' end   -- a no-op, not a failure (no ACT_FAIL)
      if not dfhack.job.addWorker(job, u) then return false, 'addWorker refused' end   -- Lua API.txt:1366
      return true, 'assigned'
    end
    job = df.job:new()
    job.job_type = jt
    job.pos = xyz2pos(d.centerx, d.centery, d.z)
    local ref = df.general_ref_building_holderst:new()
    ref.building_id = d.id
    job.general_refs:insert('#', ref)
    d.jobs:insert('#', job)
    dfhack.job.linkIntoWorld(job, true)                                 -- Lua API.txt:1338
    return true, 'posted'
  end

  -- map -> depot sheet (like clicking the depot, v1 handel.lua:676-681); sheet -> click the Trade
  -- label the caller found at {x, y}, verified here first
  function TR.open(a)
    local d = tr_depot(a.depot)
    if not d then return false, 'no trade depot ' .. tostring(a.depot) end
    local mi = df.global.game.main_interface
    if mi.trade.open then return true, 'open' end
    if tr_has('^dfhack/') then return false, 'a DFHack screen is on top' end
    if tr_has('^dwarfmode/ViewSheets/BUILDING/TradeDepot') then
      local x, y = int(a.x), int(a.y)
      if not x or not y then return false, 'Trade button position required' end
      if mi.view_sheets.active_id ~= d.id then return false, 'the sheet shows another depot' end
      local after = tr_row(y, x + 5, x + 11):lower()
      if not tr_label(x, y, 'Trade') or after:match('^ ?depot') or after:match('^ ?goods') then
        return false, string.format('no Trade button label at %d,%d', x, y)
      end
      tr_click(x + 2, y)
      return true, 'clicked'
    end
    if not tr_has('^dwarfmode/Default') then return false, 'busy: ' .. table.concat(tr_focus(), '|') end
    dfhack.gui.revealInDwarfmodeMap(xyz2pos(d.centerx, d.centery, d.z), true)   -- Lua API.txt:1220
    local vs = mi.view_sheets
    vs.open, vs.active_sheet, vs.active_id, vs.viewing_bldid = true, df.view_sheet_type.BUILDING, d.id, d.id
    return true, 'sheet'
  end

  -- tick exactly these checkboxes (0-based indices; DFHack's own trade UI writes goodflag.selected,
  -- internal/caravan/trade.lua:444-455); everything else is unticked
  function TR.mark(a)
    local t = df.global.game.main_interface.trade
    local ok, why = tr_ready(t)
    if not ok then return false, why end
    local want = {[0] = {}, [1] = {}}
    for side = 0, 1 do
      local list = side == 0 and a.buy or a.sell
      if type(list) ~= 'table' then return false, 'buy and sell must be index lists' end
      for _, i in ipairs(list) do
        i = int(i)
        if not i or i < 0 or i >= #t.good[side] then return false, 'index out of range' end
        if t.goodflag[side][i].filtered_off then return false, 'item is filtered off' end
        want[side][i] = true
      end
    end
    local n = {[0] = 0, [1] = 0}
    for side = 0, 1 do
      local flags = t.goodflag[side]
      for i = 0, #flags - 1 do
        local on = want[side][i] == true
        flags[i].selected = on
        if on then n[side] = n[side] + 1 end
      end
    end
    return true, {buy = n[0], sell = n[1]}
  end

  -- the Trade button; on DFHack's "Confirm trade" prompt (specs.lua:167-176) SELECT ("Yes, proceed",
  -- gui/dialogs.lua:33,166); a prompt with the ethics warning (specs.lua:158-165) is dismissed (No)
  function TR.offer(a)
    if tr_has('^dfhack/') then
      local s = tr_our_prompt()
      if not s or not s:find('trade the selected', 1, true) then return false, 'unknown dialog' end
      if s:find('offend', 1, true) then
        tr_dismiss()
        return false, 'ethics warning in the confirm prompt: dismissed'
      end
      gui.simulateInput(dfhack.gui.getCurViewscreen(true), 'SELECT')
      return true, 'confirmed'
    end
    local t = df.global.game.main_interface.trade
    local ok, why = tr_ready(t)
    if not ok then return false, why end
    local r = gui.get_interface_rect()                                   -- lua/gui.lua:124
    local fr = gui.compute_frame_rect(r.width, r.height, TRADE_FRAME, 0, 0)   -- lua/gui.lua:166-180
    local x1, x2, y1, y2 = r.x1 + fr.x1, r.x1 + fr.x2, r.y1 + fr.y1, r.y1 + fr.y2
    for y = y1, y2 do
      local s = tr_row(y, x1, x2):find('Trade', 1, true)
      if s and tr_label(x1 + s - 1, y, 'Trade') then
        tr_click(x1 + s + 1, y)
        return true, 'clicked'
      end
    end
    return false, 'no Trade label in the Trade button frame'
  end

  -- untick our selection (no "Cancel trade" prompt then), answer a drawn prompt of ours ("Confirm
  -- trade": No = Esc; "Cancel trade", specs.lua:105-112: Yes = leave, as intended) and LEAVESCREEN
  -- out of trade screen/sheet. Any other DFHack dialog, or one that opened during this call (not
  -- drawn yet; trade.lua comes back for it), stops here.
  function TR.close(a)
    local t = df.global.game.main_interface.trade
    if a.clear ~= false and t.open and not t.choosing_merchant then
      for side = 0, 1 do
        local flags = t.goodflag[side]
        for i = 0, #flags - 1 do flags[i].selected = false end
      end
    end
    local n = 0
    for _ = 1, 4 do
      if tr_has('^dfhack/') then
        local s = n == 0 and tr_our_prompt()
        if not s then break end
        if s:find('selected items will not be saved', 1, true) then
          gui.simulateInput(dfhack.gui.getCurViewscreen(true), 'SELECT')
        else
          tr_dismiss()
        end
      elseif tr_has('^dwarfmode/Trade') or tr_has('^dwarfmode/ViewSheets') then
        gui.simulateInput(dfhack.gui.getDFViewscreen(true), 'LEAVESCREEN')
      else
        break
      end
      n = n + 1
    end
    return true, n
  end

  -- live L6 (Laborkings y307): only 2 of 32 crafts reached the depot because no autotrade pile held
  -- them; the trade sold 33 value. Like the depot's "Move goods to/from depot" screen: mark up to a.max
  -- free items of the given item types (a.types = {'AMULET', ...}) for the haulers.
  local BRING_SKIP = {'foreign', 'forbid', 'in_job', 'in_building', 'trader', 'owned', 'artifact', 'garbage_collect',
                      'removed', 'dump', 'melt', 'construction', 'in_inventory'}
  function TR.bring(a)
    local d = tr_depot(a.depot)
    if not d then return false, 'no trade depot ' .. tostring(a.depot) end
    if not dfhack.items.markForTrade then return false, 'markForTrade not implemented' end
    local n, max = 0, tonumber(a.max) or 60
    for _, tn in ipairs(type(a.types) == 'table' and a.types or {}) do
      local t = df.item_type[tn]
      local list = t and df.global.world.items.other[tn]
      for _, it in ipairs(list or {}) do
        if n >= max then break end
        local skip = false
        for _, fl in ipairs(BRING_SKIP) do if it.flags[fl] then skip = true; break end end
        if not skip and it.flags.on_ground and dfhack.items.markForTrade(it, d) then n = n + 1 end
      end
    end
    return true, n
  end

  function I.trade(op, args)
    local f = TR[op]
    if not f then return false, 'unknown trade op ' .. tostring(op) end
    return f(type(args) == 'table' and args or {})
  end
  -- END act.trade
end

---------------------------------------------------------------- implementations
-- each returns ok, res_or_err; may raise (the wrapper converts errors)
local function impls(state)
  local I = {}
  local scripts = {}
  local function script(name)       -- reqscript once, then cached (no reqscript in loops)
    if not scripts[name] then scripts[name] = reqscript(name) end
    return scripts[name]
  end
  local plugin_cache = {}
  local function plugin(name)
    if plugin_cache[name] == nil then
      local ok, m = pcall(require, 'plugins.' .. name)
      plugin_cache[name] = ok and m or false
    end
    return plugin_cache[name] or nil
  end
  state.plugin = plugin

  function I.set_paused(on)
    df.global.pause_state = on and true or false
    return true
  end

  function I.timestream(fps)
    fps = int(fps)
    if not fps or (fps ~= -1 and (fps < 10 or fps > 1000)) then return false, 'fps must be -1 or 10..1000' end
    local old
    local ts = plugin('timestream')
    if ts then
      local ok, v = pcall(function() return ts.timestream_getFps() end)
      if ok then old = int(v) end
    end
    local ok, err = cmd_run('timestream', 'set', 'fps', string.format('%d', fps))
    if not ok then return false, err end
    return true, old
  end

  -- vanilla Settings screen values (d_init/enabler globals; gui/settings-manager.lua:1016, pop-control.lua:31,
  -- open-legends.lua:88 for d_init.feature.autosave)
  local SETTINGS = {
    gfps = {get = function() return df.global.enabler.gfps end,
            set = function(v) df.global.enabler.gfps = v end, lo = 1, hi = 1000},
    -- the vanilla FPS cap (Settings, prefs FPS_CAP; enabler.fps is a float): the only way to run slower
    -- than DF's own frame rate, since timestream never slows below it (live L1 supply brake)
    fps_cap = {get = function() return math.floor((df.global.enabler.fps or 0) + 0.5) end,
               set = function(v) df.global.enabler.fps = v end, lo = 10, hi = 1000},
    visitor_cap = {get = function() return df.global.d_init.dwarf.visitor_cap end,
                   set = function(v) df.global.d_init.dwarf.visitor_cap = v end, lo = 0, hi = 10000},
    population_cap = {get = function() return df.global.d_init.dwarf.population_cap end,
                      set = function(v) df.global.d_init.dwarf.population_cap = v end, lo = 0, hi = 10000},
    autosave = {  -- enum df.d_init_autosave, value passed by name [S8]
      get = function()
        local v = df.global.d_init.feature.autosave
        if type(v) == 'number' and df.d_init_autosave then return df.d_init_autosave[v] end
        return v
      end,
      set = function(name)
        if type(name) ~= 'string' or not name:match('^[A-Z_]+$') then error('autosave needs an enum name') end
        local e = df.d_init_autosave
        if e then
          local n = e[name]
          if type(n) ~= 'number' then error('unknown autosave value ' .. name) end
          df.global.d_init.feature.autosave = n
        else
          df.global.d_init.feature.autosave = name
        end
      end},
    weather = {  -- D-07 only [S8: field unverified]
      get = function() return df.global.d_init.feature.flags.WEATHER == true end,
      set = function(on) df.global.d_init.feature.flags.WEATHER = on and true or false end, bool = true},
  }
  function I.setting(name, value)
    local s = SETTINGS[name]
    if not s then return false, 'unknown setting ' .. tostring(name) end
    if s.lo then
      value = int(value)
      if not value or value < s.lo or value > s.hi then return false, name .. ' out of range' end
    elseif s.bool and type(value) ~= 'boolean' then
      return false, name .. ' needs a boolean'
    end
    local old = s.get()
    s.set(value)
    return true, old
  end

  -- overlay enable/disable <names...> (plugins/overlay.lua:164,195); old = enabled state before
  function I.overlay(names, on)
    local single = type(names) == 'string'
    if single then names = {names} end
    if type(names) ~= 'table' or #names == 0 then return false, 'overlay names required' end
    local ov, old = plugin('overlay'), {}
    for _, n in ipairs(names) do
      if type(n) ~= 'string' or not n:match('^[A-Za-z0-9._/%-]+$') then return false, 'bad overlay name' end
      old[n] = ov and ov.isOverlayEnabled(n) == true or false
    end
    local ok, err = cmd_run('overlay', on and 'enable' or 'disable', table.unpack(names))
    if not ok then return false, err end
    if single then return true, old[names[1]] end
    return true, old
  end

  -- close the front popup (world.status.popups, cf. modtools/create-unit.lua:135); the caller (arbiter)
  -- decides which kinds are whitelisted. The object is not deleted (DF may still reference it) [S8].
  function I.dismiss_popup(kind)
    if type(kind) ~= 'string' or not kind:match('^[a-z_]+$') then return false, 'bad popup kind' end
    local popups = df.global.world.status.popups
    if #popups == 0 then return false, 'no popup' end
    -- live L6: the embark intro is never erased (arbiter; tools/embark clicks its Okay): erasing it left
    -- Perplexrooms a fort where nobody ever took a job. A SELECT key did not close popups either.
    popups:erase(0)
    return true, kind
  end

  -- gui/civ-alert public API (civ-alert.lua:21-50)
  function I.civ_alert(on)
    local ca = script('gui/civ-alert')
    if on then
      ca.sound_alarm()
      if df.global.plotinfo.alerts.civ_alert_idx == 0 then return false, 'no alert burrows' end
    else
      ca.clear_alarm()
    end
    return true
  end

  function I.alert_burrows(names)
    if type(names) ~= 'table' then return false, 'names must be a list' end
    local ca = script('gui/civ-alert')
    local want, want_l = {}, {}
    for _, n in ipairs(names) do
      local b = dfhack.burrows.findByName(n)
      if not b then return false, 'no burrow ' .. tostring(n) end
      if not want[b.id] then want[b.id] = true; want_l[#want_l + 1] = b.id end
    end
    local cur, cur_l = {}, {}
    local list = df.global.plotinfo.alerts.list
    if #list >= 2 then
      for _, id in ipairs(list[1].burrows) do cur[id] = true; cur_l[#cur_l + 1] = id end
    end
    table.sort(want_l)
    for _, id in ipairs(want_l) do if not cur[id] then ca.add_civalert_burrow(id) end end
    for _, id in ipairs(cur_l) do if not want[id] then ca.remove_civalert_burrow(id) end end  -- add first: never empty
    return true, #want_l
  end

  ---------------------------------------------------------------- positions (nobles and squads screens)
  local function fort_entity() return df.global.plotinfo.main.fortress_entity end
  local function own_position(ent, pred)
    for i, p in ipairs(ent.positions.own) do if pred(p) then return p, i end end
  end
  local function assignment_by_id(ent, id)
    for i, a in ipairs(ent.positions.assignments) do if a.id == id then return a, i end end
  end
  local function entity_index(ent)            -- index of the entity in world.entities.all (the links carry it)
    for i, e in ipairs(df.global.world.entities.all) do if e.id == ent.id then return i end end
    return ent.id
  end

  -- the two records the nobles screen (and the squads screen's "choose leader") writes when a citizen takes
  -- a vacant position: the assignment names the citizen's historical figure, and the figure gets a position
  -- link to the fortress entity (live L1: the expedition leader's records; make-monarch.lua for the civ).
  -- DF finds the holder of a duty through entity.assignments_by_type[responsibility] (live L1: without it the
  -- manager never validated an order). position_vector_idx = the position's index in positions.own (read
  -- live L2 on every filled assignment).
  local function seat_figure(ent, pos, pidx, asg, aidx, hf)
    asg.histfig, asg.histfig2 = hf.id, hf.id
    asg.position_vector_idx = pidx
    hf.entity_links:insert('#', {new = df.histfig_entity_link_positionst, entity_id = ent.id, link_strength = 100,
                                 entity_vector_idx = entity_index(ent), assignment_id = asg.id,
                                 assignment_vector_idx = aidx, start_year = df.global.cur_year})
    for r, on in pairs(pos.responsibilities) do
      if on then
        local v, has = ent.assignments_by_type[r], false
        for _, x in ipairs(v) do if x.id == asg.id then has = true; break end end
        if not has then v:insert('#', asg) end
      end
    end
  end

  -- what DFHack's addToSquad sets after a membership change (Military.cpp: squad.ammo.update and
  -- plotinfo.equipment.update): the equipment pass re-assigns uniforms
  local EQUIP_UPDATE = {'weapon', 'armor', 'shoes', 'shield', 'helm', 'gloves', 'ammo', 'pants', 'backpack', 'quiver',
                        'flask'}
  local function equipment_update(sq)
    for _, f in ipairs(EQUIP_UPDATE) do
      pcall(function() sq.ammo.update[f] = true end)
      pcall(function() df.global.plotinfo.equipment.update[f] = true end)
    end
  end

  -- militia positions only (CAPTAIN_OF_THE_GUARD also has a squad size: that is the law squad)
  local SQUAD_CODES = {MILITIA_COMMANDER = true, MILITIA_CAPTAIN = true}

  -- squads screen "create squad": the vacant leader assignment the new squad belongs to. A vacant militia
  -- commander/captain assignment without a squad first (the commander leads the first squad); otherwise a
  -- new militia captain assignment, which the screen adds for every further squad (live L2: the fort had
  -- one commander assignment, already holding squad A).
  local function squad_assignment(ent)
    local codes = {}
    for _, p in ipairs(ent.positions.own) do if SQUAD_CODES[p.code] then codes[p.id] = true end end
    for _, a in ipairs(ent.positions.assignments) do
      if codes[a.position_id] and a.squad_id == -1 and a.histfig == -1 then return a end
    end
    local cap = own_position(ent, function(p) return p.code == 'MILITIA_CAPTAIN' end)
    if not cap then return nil end
    local a = df.entity_position_assignment:new()
    a.id = ent.positions.next_assignment_id
    ent.positions.next_assignment_id = a.id + 1
    a.histfig, a.histfig2, a.position_id, a.position_vector_idx, a.squad_id = -1, -1, cap.id, -1, -1
    a.assigned_army_controller_id = -1
    a.flags[0] = true                       -- set on every assignment of an offered position (read live L2)
    ent.positions.assignments:insert('#', a)
    return a
  end

  -- military module (Lua API.txt:1973-1993, DFHack library/modules/Military.cpp) [S2, live L2]
  -- opts = {assignment_id?, leader?}: without an assignment the squads screen's one is used (above); with a
  -- leader the new squad's position 0 is filled at once (squad_leader). A squad whose leader could not be
  -- seated is still created (ok, id): the caller sees the vacant slot.
  function I.squad_create(name, opts)
    opts = type(opts) == 'table' and opts or {}
    local ent = fort_entity()
    if not ent then return false, 'no fortress entity' end
    local aid, asg = int(opts.assignment_id), nil
    if aid then asg = assignment_by_id(ent, aid) else asg = squad_assignment(ent) end
    if not asg then return false, 'no militia assignment for a new squad' end
    local sq = dfhack.military.makeSquad(asg.id)
    if not sq then return false, 'makeSquad failed' end
    if type(name) == 'string' and name ~= '' then
      local cp = dfhack.utf2df(name)
      sq.alias = cp
      pcall(function() sq.name.nickname = cp end)   -- "consider setting squad.name.nickname" (Lua API.txt:1973)
    end
    if int(opts.leader) then I.squad_leader(sq.id, opts.leader) end
    return true, sq.id
  end

  -- CONTRACTS §5 R4: the squads screen's "choose leader" = appoint the citizen to the position assignment
  -- the squad belongs to (squad.leader_assignment). It fills position 0, which addToSquad refuses
  -- (Military.cpp:453). The officer has a POSITION link, no SQUAD link (removeFromSquad position 0 calls
  -- remove_officer_entity_link, Military.cpp:345-412).
  function I.squad_leader(squad_id, unit_id)
    local sq = df.squad.find(int(squad_id) or -1)
    if not sq or sq.entity_id ~= df.global.plotinfo.group_id then return false, 'no fort squad ' .. tostring(squad_id) end
    if #sq.positions == 0 then return false, 'squad has no positions' end
    local p0 = sq.positions[0]
    local u = df.unit.find(int(unit_id) or -1)
    if not u then return false, 'no unit ' .. tostring(unit_id) end
    if not dfhack.units.isCitizen(u) or not dfhack.units.isAdult(u) or dfhack.units.isDead(u) then
      return false, 'not an adult living citizen'
    end
    local hf = df.historical_figure.find(u.hist_figure_id)
    if not hf then return false, 'no historical figure' end
    if p0.occupant == hf.id then return true, 'already' end
    if p0.occupant ~= -1 then return false, 'leader already seated' end
    if u.military.squad_id ~= -1 then return false, 'unit is in a squad' end
    local ent = fort_entity()
    local asg, aidx = assignment_by_id(ent, sq.leader_assignment)
    if not asg or asg.squad_id ~= sq.id then return false, 'squad has no leader assignment' end
    if asg.histfig ~= -1 then return false, 'leader assignment held by figure ' .. tostring(asg.histfig) end
    local pos, pidx = own_position(ent, function(p) return p.id == asg.position_id end)
    if not pos then return false, 'no position ' .. tostring(asg.position_id) end
    seat_figure(ent, pos, pidx, asg, aidx, hf)
    p0.occupant = hf.id
    u.military.squad_id, u.military.squad_position = sq.id, 0
    equipment_update(sq)
    return true, asg.id
  end

  function I.squad_add(squad_id, unit_id)
    local ok = dfhack.military.addToSquad(unit_id, squad_id, -1)
    if not ok then return false, 'addToSquad refused' end
    return true, squad_id
  end

  function I.squad_remove(squad_id, unit_id)
    local u = df.unit.find(unit_id)
    if not u or u.military.squad_id ~= squad_id then return false, 'unit not in squad' end
    if not dfhack.military.removeFromSquad(unit_id) then return false, 'removeFromSquad refused' end
    return true
  end

  -- routine dropdown, resolved by name [S2: plotinfo.alerts.routines layout]
  function I.squad_routine(squad_id, routine_name)
    local sq = df.squad.find(squad_id)
    if not sq then return false, 'no squad ' .. tostring(squad_id) end
    if type(routine_name) ~= 'string' then return false, 'routine name required' end
    local want, idx = routine_name:lower(), nil
    for i, r in ipairs(df.global.plotinfo.alerts.routines) do
      if dfhack.df2utf(r.name):lower() == want then idx = i; break end
    end
    if not idx then return false, 'no routine named ' .. routine_name end
    sq.cur_routine_idx = idx
    return true, idx
  end

  local function clear_orders(sq)
    for i = #sq.orders - 1, 0, -1 do
      local o = sq.orders[i]
      sq.orders:erase(i)
      pcall(function() o:delete() end)
    end
  end

  -- a new squad order replaces the old ones, like the squad screen [S2]
  function I.squad_order(squad_id, order)
    local sq = df.squad.find(squad_id)
    if not sq then return false, 'no squad ' .. tostring(squad_id) end
    local kind = type(order) == 'table' and order.kind
    if kind ~= 'station' and kind ~= 'kill' and kind ~= 'train' and kind ~= 'clear' then
      return false, 'order.kind must be station, kill, train or clear'
    end
    local o
    if kind == 'station' then
      local x, y, z = xyz(order.pos)
      if not x then return false, 'station needs pos' end
      o = df.squad_order_movest:new()
      o.pos.x, o.pos.y, o.pos.z = x, y, z
    elseif kind == 'kill' then
      if type(order.units) ~= 'table' or #order.units == 0 then return false, 'kill needs units' end
      o = df.squad_order_kill_listst:new()
      for _, id in ipairs(order.units) do o.units:insert('#', id) end
    end
    clear_orders(sq)          -- 'train' and 'clear': training follows the routine
    if o then
      o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
      sq.orders:insert('#', o)
    end
    return true, kind
  end

  -- squads screen > equip > assign uniform [S2, live L2]: per position and category, the squad_uniform_spec
  -- records the screen creates from a uniform template (entity.uniforms: item type, subtype, material class,
  -- indiv choice; flags replace_clothing/exact_matches), then the equipment update. spec = {mode='replace'|
  -- 'over', items = {{cat, type, subtype?, mat = 'metal'|'leather'|'any', choice = 'melee'|'ranged'|'any'}},
  -- positions = {0-based}? (default all), ammo = {type, subtype, n}?}. Only the categories named in items
  -- are replaced on those positions. mat: 'metal' = material class Armor (the "metal armor" templates),
  -- 'leather' = Leather, 'any' = no class.
  local UNIFORM_CAT = {body = true, head = true, pants = true, gloves = true, shoes = true, shield = true, weapon = true}
  local MAT_CLASS = {metal = 'Armor', leather = 'Leather'}
  local ITEMDEFS = {WEAPON = 'weapons', AMMO = 'ammo', ARMOR = 'armor', HELM = 'helms', PANTS = 'pants',
                    GLOVES = 'gloves', SHOES = 'shoes', SHIELD = 'shields'}
  local function subtype_of(typ, token)
    if token == nil or token == -1 then return -1 end
    if math.type(token) == 'integer' then return token end
    local list = df.global.world.raws.itemdefs[ITEMDEFS[typ] or '']
    for i, d in ipairs(list or {}) do if d.id == token then return d.subtype or i end end
    return nil
  end
  local function clear_specs(vec)
    for i = #vec - 1, 0, -1 do
      local sp = vec[i]
      vec:erase(i)
      pcall(function() sp:delete() end)
    end
  end
  -- BUG-023 (v1 E18 Run 5, Run 10 "3 reserved by squad uniforms"): an item whose spec is gone stays in
  -- plotinfo.equipment.items_assigned ("assigned, never picked up"), and DF never hands a reserved pick or axe out as a
  -- work tool. As the squads screen's removal does, an item that no position lists any more and nobody carries goes
  -- back to items_unassigned (sorted). Returns the number released.
  local function release_items(ids)
    if #ids == 0 then return 0 end
    local n = 0
    pcall(function()
      local refd = {}
      for _, s in ipairs(df.global.world.squads.all) do
        for _, p in ipairs(s.positions) do
          for _, id in ipairs(p.equipment.assigned_items) do refd[id] = true end
        end
      end
      local eq = df.global.plotinfo.equipment
      for _, id in ipairs(ids) do
        local it = df.item.find(id)
        if it and not refd[id] and not dfhack.items.getHolderUnit(it) then
          local key = df.item_type[it:getType()]
          local va, vu = eq.items_assigned[key], eq.items_unassigned[key]
          local was = false
          for j = #va - 1, 0, -1 do if va[j] == id then va:erase(j); was = true end end
          if was then
            local at, have = #vu, false
            for j = 0, #vu - 1 do
              if vu[j] == id then have = true end
              if at == #vu and vu[j] > id then at = j end
            end
            if not have then vu:insert(at, id) end
            n = n + 1
          end
        end
      end
    end)
    return n
  end
  function I.squad_uniform(squad_id, spec)
    local sq = df.squad.find(int(squad_id) or -1)
    if not sq or sq.entity_id ~= df.global.plotinfo.group_id then return false, 'no fort squad ' .. tostring(squad_id) end
    if type(spec) ~= 'table' or type(spec.items) ~= 'table' or #spec.items == 0 then return false, 'spec.items required' end
    local recs, cats = {}, {}
    for _, it in ipairs(spec.items) do
      if not UNIFORM_CAT[it.cat] then return false, 'bad uniform category ' .. tostring(it.cat) end
      local t = df.item_type[it.type]
      if type(t) ~= 'number' then return false, 'bad item type ' .. tostring(it.type) end
      local st = subtype_of(it.type, it.subtype)
      if not st then return false, 'unknown subtype ' .. tostring(it.subtype) end
      local mc = -1
      if MAT_CLASS[it.mat] then mc = df.entity_material_category[MAT_CLASS[it.mat]] end
      recs[#recs + 1] = {cat = it.cat, t = t, st = st, mc = mc, choice = it.choice}
      cats[it.cat] = true
    end
    local only
    if type(spec.positions) == 'table' then
      only = {}
      for _, i in ipairs(spec.positions) do only[i] = true end
    end
    local n, freed = 0, {}
    for i, p in ipairs(sq.positions) do
      if not only or only[i] then
        local u = p.equipment.uniform
        -- the replaced specs' items leave the position (else they stay reserved for it, BUG-023)
        local ai = p.equipment.assigned_items
        for c in pairs(cats) do
          for _, sp in ipairs(u[c]) do
            for _, id in ipairs(sp.assigned or {}) do
              freed[#freed + 1] = id
              if ai then for j = #ai - 1, 0, -1 do if ai[j] == id then ai:erase(j) end end end
            end
          end
        end
        for c in pairs(cats) do clear_specs(u[c]) end
        for _, r in ipairs(recs) do
          local sp = df.squad_uniform_spec:new()
          sp.item, sp.item_type, sp.item_subtype = -1, r.t, r.st
          sp.material_class, sp.mattype, sp.matindex, sp.color = r.mc, -1, -1, -1
          sp.indiv_choice.any = r.choice == 'any'
          sp.indiv_choice.melee = r.choice == 'melee'
          sp.indiv_choice.ranged = r.choice == 'ranged'
          u[r.cat]:insert('#', sp)
        end
        p.equipment.flags.replace_clothing = spec.mode ~= 'over'
        p.equipment.flags.exact_matches = true            -- as every vanilla template (read live L2)
        n = n + 1
      end
    end
    if type(spec.ammo) == 'table' then                     -- squads screen > ammunition
      local at = df.item_type[spec.ammo.type or 'AMMO']
      local ast = subtype_of(spec.ammo.type or 'AMMO', spec.ammo.subtype)
      if type(at) ~= 'number' or not ast then return false, 'bad ammo spec' end
      local have = false
      for _, a in ipairs(sq.ammo.ammunition) do if a.item_type == at and a.item_subtype == ast then have = true end end
      if not have then
        local a = df.squad_ammo_spec:new()
        a.item_type, a.item_subtype, a.material_class, a.mattype, a.matindex = at, ast, -1, -1, -1
        a.amount = int(spec.ammo.n) or 100
        a.flags.use_combat, a.flags.use_training = true, true
        sq.ammo.ammunition:insert('#', a)
      end
    end
    release_items(freed)
    equipment_update(sq)
    return true, n
  end

  -- squads screen > equip > remove uniform / unassign (live L6, Laborkings: soldiers held the fort's only battle
  -- axes and picks for a year): per position (0-based `positions`, default all) every uniform spec is deleted,
  -- the position's assigned items are released (equipment.assigned_items, the quiver/backpack/flask slots; the
  -- same records uniform-unstick.lua remove_item_from_position clears), then the equipment update. The items
  -- go back to the fort's free stock, so civilians take the picks and axes again. Returns ok, items released.
  -- `cats` (uniform categories) limits it to those specs and their assigned items (military: a weapon spec that
  -- could take the civilians' tools).
  local POS_ITEMS = {'quiver', 'backpack', 'flask'}
  function I.squad_unequip(squad_id, positions, cats)
    local sq = df.squad.find(int(squad_id) or -1)
    if not sq or sq.entity_id ~= df.global.plotinfo.group_id then return false, 'no fort squad ' .. tostring(squad_id) end
    local only
    if positions ~= nil then
      if type(positions) ~= 'table' then return false, 'positions must be a list' end
      only = {}
      for _, i in ipairs(positions) do only[i] = true end
    end
    local which = UNIFORM_CAT
    if cats ~= nil then
      if type(cats) ~= 'table' or #cats == 0 then return false, 'cats must be a list of uniform categories' end
      which = {}
      for _, c in ipairs(cats) do
        if not UNIFORM_CAT[c] then return false, 'bad uniform category ' .. tostring(c) end
        which[c] = true
      end
    end
    local n, freed = 0, {}
    for i, p in ipairs(sq.positions) do
      if not only or only[i] then
        local eq = p.equipment
        local ai = eq.assigned_items
        if not cats then for _, id in ipairs(ai) do freed[#freed + 1] = id end end
        for c in pairs(which) do
          for _, sp in ipairs(eq.uniform[c]) do
            for _, id in ipairs(sp.assigned) do
              n = n + 1
              freed[#freed + 1] = id
              if cats then
                for j = #ai - 1, 0, -1 do if ai[j] == id then ai:erase(j) end end
              end
            end
          end
          clear_specs(eq.uniform[c])
        end
        if not cats then
          for j = #ai - 1, 0, -1 do ai:erase(j) end
          for _, k in ipairs(POS_ITEMS) do
            pcall(function() if eq[k] ~= -1 then eq[k] = -1; n = n + 1 end end)
          end
        end
      end
    end
    release_items(freed)
    equipment_update(sq)
    return true, n
  end

  -- squads screen > equip > unassign an item (BUG-023, Run 10: 6 of 9 picks stayed in items_assigned after their specs
  -- were given up, so the miners never got one): each listed item that nobody carries leaves every fort position's
  -- assigned_items and spec lists; one that no position lists any more goes back to items_unassigned. Equipment update
  -- of the squads touched. Returns ok, released.
  function I.squad_release(item_ids)
    if type(item_ids) ~= 'table' then return false, 'item ids required' end
    local ids, n = {}, 0
    for _, id in ipairs(item_ids) do
      local it = df.item.find(int(id) or -1)
      if it and not dfhack.items.getHolderUnit(it) then ids[it.id] = true end
    end
    local list = {}
    for _, sq in ipairs(df.global.world.squads.all) do
      if sq.entity_id == df.global.plotinfo.group_id then
        local touched = false
        for _, p in ipairs(sq.positions) do
          local ai = p.equipment.assigned_items
          for j = #ai - 1, 0, -1 do if ids[ai[j]] then ai:erase(j); touched = true end end
          for c in pairs(UNIFORM_CAT) do
            for _, sp in ipairs(p.equipment.uniform[c] or {}) do
              local v = sp.assigned
              for j = #(v or {}) - 1, 0, -1 do if ids[v[j]] then v:erase(j); touched = true end end
            end
          end
        end
        if touched then equipment_update(sq) end
      end
    end
    for id in pairs(ids) do list[#list + 1] = id end
    table.sort(list)
    n = release_items(list)
    return true, n
  end

  -- animal sheet > "slaughter" toggle (live L6: a famine with idle grazers; DFHack zone.lua
  -- AnimalActionsWidget:set_slaughter_flag: flags2.slaughter, and marking clears the gelding and adoption marks
  -- as the vanilla sheet does). Only a tame, fort-controlled animal that is nobody's pet; a butcher's shop
  -- takes the job. Returns ok, 'marked'|'already'|'cleared'.
  function I.animal_slaughter(unit_id, on)
    local u = df.unit.find(int(unit_id) or -1)
    if not u then return false, 'no unit ' .. tostring(unit_id) end
    local U = dfhack.units
    if U.isDead(u) or U.isCitizen(u, true) then return false, 'not a living animal' end
    if not U.isTame(u) or not U.isFortControlled(u) then return false, 'not a tame fort animal' end
    if U.isPet and U.isPet(u) then return false, 'a pet' end
    if on then
      if u.flags2.slaughter then return true, 'already' end
      u.flags3.marked_for_gelding = false
      u.flags3.available_for_adoption = false
      u.flags2.slaughter = true
      return true, 'marked'
    end
    u.flags2.slaughter = false
    return true, 'cleared'
  end

  -- zones screen > select zone > remove (live L6: the runner's temporary gather zone): every activity zone
  -- named `name` (dfllm-* only) is removed with dfhack.buildings.deconstruct, as quickfort's zone undo does
  -- (internal/quickfort/zone.lua do_undo) but only for these zones, never for others on the same tiles.
  -- Returns ok, zones removed.
  function I.zone_remove(name)
    if type(name) ~= 'string' or not name:match('^dfllm%-[%w_%-]+$') then return false, 'zone name must be dfllm-*' end
    local list = {}
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
      if dfhack.df2utf(z.name or '') == name then list[#list + 1] = z end
    end
    local sel = dfhack.gui and dfhack.gui.getSelectedCivZone and dfhack.gui.getSelectedCivZone(true) or nil
    local n = 0
    for _, z in ipairs(list) do
      if z ~= sel and dfhack.buildings.deconstruct(z) then n = n + 1 end
    end
    return true, n
  end

  -- zones screen > add zone > Sand (Run 11, Kilrudrabed: no gem vein, raw glass for strange moods): one 1x1 sand
  -- collection zone named dfllm-sand at pos, quickfort zone mode (internal/quickfort/zone.lua key `s`), as the runner
  -- draws its gather zone. The caller picks a revealed sand floor (snapshot's sand marks, snapshot.tile; act reads no
  -- tiles). Returns ok, zones designated (0 = quickfort skipped the tile: refused).
  function I.sand_zone(pos)
    local x, y, z = xyz(pos)
    x, y, z = int(x), int(y), int(z)
    if not (x and y and z) then return false, 'pos must be {x,y,z}' end
    local ok, stats = I.quickfort({mode = 'zone', data = {[0] = {[0] = {[0] = 's{name=dfllm-sand}'}}}, pos = {x, y, z}})
    if not ok then return false, stats end
    local n = type(stats) == 'table' and int(stats.zone_designated) or nil
    if n == 0 then return false, 'quickfort designated no zone there' end
    return true, n or 1
  end

  -- zones screen > add zone > Fishing (Run 11, Kilrudrabed: food 24 days, the Fisherdwarves detail waited for a fishing
  -- zone and the kernel only read zones): a side x side fishing zone named dfllm-fish centred on the water tile pos,
  -- quickfort zone mode (internal/quickfort/zone.lua key `f`), and with `up` the same rectangle one level higher (the
  -- fisher's bank stands above the water: a river bank or a brook top). The caller picks revealed, liquid, non-cavern
  -- water with a bank on the citizens' walk group (economy's fishing search; act reads no tiles). Returns ok, zones
  -- designated (0 = quickfort skipped every tile: refused).
  function I.fish_zone(pos, side, up)
    local x, y, z = xyz(pos)
    x, y, z = int(x), int(y), int(z)
    if not (x and y and z) then return false, 'pos must be {x,y,z}' end
    side = math.max(1, math.min(int(side) or 3, 7))
    local cell = string.format('f{name=dfllm-fish}(%dx%d)', side, side)
    local n = 0
    for _, zz in ipairs(up == true and {z, z + 1} or {z}) do
      local ok, stats = I.quickfort({mode = 'zone', data = {[0] = {[0] = {[0] = cell}}},
                                     pos = {x - side // 2, y - side // 2, zz}})
      if not ok then return false, stats end
      n = n + (type(stats) == 'table' and int(stats.zone_designated) or 1)
    end
    if n == 0 then return false, 'quickfort designated no zone there' end
    return true, n
  end

  -- live L6 (Paddletribes): removes ONE Pond zone by id (as the player deletes the zone on its sheet); water
  -- uses it for ponds that only recycle the water of the well beside them. Never touches other zones.
  function I.pond_remove(id)
    id = math.tointeger(id)
    if not id then return false, 'bad zone id' end
    local pondt = df.civzone_type.Pond
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
      if z.id == id then
        if z.type ~= pondt then return false, 'not a pond zone' end
        if dfhack.buildings.deconstruct(z) then return true, 1 end
        return false, 'deconstruct refused'
      end
    end
    return false, 'no such zone'
  end

  -- BUG-034 (Run 11, Kilrudrabed y439: 5 bedridden patients died of thirst in a hospital without water; the game session
  -- removed its 5 zones by hand and GiveWater jobs brought water again): zones screen > select the zone > remove, for ONE
  -- activity zone of a hospital location (its location_id names a HOSPITAL abstract building of the site, as water
  -- reads it from buildings.other.ANY_ZONE). dfhack.buildings.deconstruct, as pond_remove and quickfort's zone undo do;
  -- the location itself stays (the locations screen keeps it). Never another zone, never the one open on the zone
  -- sheet. Returns ok, 1.
  function I.hospital_remove(id)
    id = math.tointeger(id)
    if not id then return false, 'bad zone id' end
    local hosp = {}
    local site = dfhack.world.getCurrentSite()
    local htype = df.abstract_building_type.HOSPITAL
    for _, l in ipairs(site and site.buildings or {}) do
      if l:getType() == htype then hosp[l.id] = true end
    end
    for _, z in ipairs(df.global.world.buildings.other.ANY_ZONE) do
      if z.id == id then
        if not hosp[z.location_id] then return false, 'not a hospital zone' end
        local sel = dfhack.gui and dfhack.gui.getSelectedCivZone and dfhack.gui.getSelectedCivZone(true) or nil
        if sel == z then return false, 'zone sheet open' end
        if dfhack.buildings.deconstruct(z) then return true, 1 end
        return false, 'deconstruct refused'
      end
    end
    return false, 'no such zone'
  end

  -- live L6 (reclaimed Paddletribes): the office zone had no owner, so the manager validated no order
  -- (117 of 118 waiting, the stills idle, drink 0). Assigns an unowned Office zone to the manager, as the
  -- zone sheet's "Assign" does (dfhack.buildings.setOwner). Never takes an office someone owns.
  function I.manager_office()
    local m = dfhack.units.getUnitByNobleRole('manager')
    if not m or dfhack.units.isDead(m) then return false, 'no manager' end
    local free
    for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
      if z.type == df.civzone_type.Office then
        if z.assigned_unit_id == m.id then return true, 'has office' end
        if z.assigned_unit_id == -1 and not free then free = z end
      end
    end
    if not free then return false, 'no free office zone' end
    if not dfhack.buildings.setOwner(free, m) then return false, 'setOwner refused' end
    return true, 'assigned'
  end

  -- lever.lua:4 leverPullJob(lever, priority) returns nothing: the new job is found on lever.jobs
  local own_jobs = state.own_jobs
  local function is_lever(b)
    local ok, r = pcall(function()
      return df.building_trapst:is_instance(b) and b.trap_type == df.trap_type.Lever
    end)
    return ok and r
  end
  function I.pull(lever_id)
    local lever = df.building.find(lever_id)
    if not lever then return false, 'no building ' .. tostring(lever_id) end
    if not is_lever(lever) then return false, 'not a lever' end
    local before = {}
    for _, j in ipairs(lever.jobs) do before[j.id] = true end
    script('lever').leverPullJob(lever, true)
    local id
    for _, j in ipairs(lever.jobs) do
      if not before[j.id] and j.job_type == df.job_type.PullLever then id = j.id end
    end
    if not id then return false, 'no pull job created' end
    own_jobs[id] = lever_id
    return true, id
  end

  -- door sheet > forbid ("locked"; FR-49/52 lockdown): the door's passage toggle (building_doorst door_flags.forbidden,
  -- the flag the sheet's forbid button sets). Doors only; returns the old value so the caller can undo its own change.
  -- BUG-015: `close` (with on) also sets door_flags.closed, the state a locked door takes once its doorway is clear;
  -- reflex asks for it only on the retry of a door whose flag fell back, with nobody standing in the doorway.
  function I.door_forbid(building_id, on, close)
    local b = df.building.find(building_id)
    if not b then return false, 'no building ' .. tostring(building_id) end
    local okt, is_door = pcall(function()
      if df.building_type and b.getType then return b:getType() == df.building_type.Door end
      return b.door_flags ~= nil
    end)
    if not (okt and is_door) then return false, 'not a door' end
    local old = b.door_flags.forbidden == true
    b.door_flags.forbidden = on and true or false
    if on and close == true then pcall(function() b.door_flags.closed = true end) end
    return true, old
  end

  -- burrows screen > units (live L3, gate's lever pullers): the burrow's unit list becomes exactly `ids`,
  -- living citizens only; dfhack.burrows.setAssignedUnit (Lua API.txt:2424) is the screen's per-unit toggle
  -- (hack/lua/plugins/sort/unitselector.lua:122). Units no longer found stay listed (fix/dead-units --burrow).
  function I.burrow_units(name, ids)
    if type(name) ~= 'string' or type(ids) ~= 'table' then return false, 'need a burrow name and unit ids' end
    local b = dfhack.burrows.findByName(name)
    if not b then return false, 'no burrow ' .. name end
    local want, units = {}, {}
    for _, id in ipairs(ids) do
      local u = math.type(id) == 'integer' and df.unit.find(id) or nil
      if not (u and dfhack.units.isCitizen(u) and not dfhack.units.isDead(u)) then
        return false, 'not a living citizen: ' .. tostring(id)
      end
      if not want[id] then want[id], units[#units + 1] = true, u end
    end
    local drop = {}
    for _, id in ipairs(b.units) do if not want[id] then drop[#drop + 1] = id end end
    for _, id in ipairs(drop) do
      local u = df.unit.find(id)
      if u then dfhack.burrows.setAssignedUnit(b, u, false) end
    end
    for _, u in ipairs(units) do
      if not dfhack.burrows.isAssignedUnit(b, u) then dfhack.burrows.setAssignedUnit(b, u, true) end
    end
    return true, #units
  end

  -- burrows screen > add burrow / paint (FR-33, seal's whole-interior alert burrow): the tiles {{x,y,z},...} are
  -- added to the burrow (dfhack.burrows.setAssignedTile, Lua API.txt:2436; the screen's paint brush). With `create`
  -- a missing burrow is made the way the screen's "add burrow" does (v1 Run 4 created 'Zuflucht' the same way).
  -- Returns the number of tiles newly added.
  function I.burrow_tiles(name, tiles, create)
    if type(name) ~= 'string' or not name:match('^[%w%+%-_ ]+$') or #name > 40 then return false, 'bad burrow name' end
    if type(tiles) ~= 'table' or #tiles > 2000 then return false, 'need at most 2000 tiles' end
    local b = dfhack.burrows.findByName(name)
    if not b then
      if not create then return false, 'no burrow ' .. name end
      local list = df.global.plotinfo.burrows
      b = df.burrow:new()
      b.id = list.next_id
      list.next_id = b.id + 1
      b.name = name
      b.symbol_index, b.texture_r, b.texture_g, b.texture_b = 5, 60, 160, 255
      b.texture_br, b.texture_bg, b.texture_bb = 195, 95, 0
      list.list:insert('#', b)
    end
    local n = 0
    for _, p in ipairs(tiles) do
      local x, y, z = xyz(p)
      x, y, z = int(x), int(y), int(z)
      if x and y and z then
        local pos = xyz2pos(x, y, z)
        if not dfhack.burrows.isAssignedTile(b, pos) then
          dfhack.burrows.setAssignedTile(b, pos, true)
          n = n + 1
        end
      end
    end
    return true, n
  end

  -- the only job removal in v2 (DESIGN §5.9): our own queued pull (Lua API.txt:1336)
  function I.cancel_own_lever_job(job_id)
    local lever_id = own_jobs[job_id]
    if not lever_id then return false, 'not our job' end
    own_jobs[job_id] = nil
    local lever, job = df.building.find(lever_id), nil
    if lever then
      for _, j in ipairs(lever.jobs) do if j.id == job_id then job = j end end
    end
    if not job then return false, 'job no longer pending' end
    if not dfhack.job.removeJob(job) then return false, 'removeJob failed' end
    return true
  end

  -- lever sheet > "link up" > target building > mechanisms [S3, live L2]: the UI queues one
  -- LinkBuildingToTrigger job on the lever with two chosen mechanisms (view_sheets.linking_lever_mech_lever_id
  -- and _target_id), a building holder ref (the lever) and a trigger target ref (the target). A mechanic
  -- fetches both, puts one into each building, and the lever's linked_mechanisms then holds the target's
  -- mechanism (its BUILDING_HOLDER ref = the target; lever.lua:24-27, gui/mechanisms.lua:40-54). The
  -- mechanisms are chosen as the screen offers them: free (not forbidden, not in a job or building, not
  -- held by a unit), reachable from the lever, nearest first. Returns ok, job id | 'linked'.
  local MECH_FLAGS = {'forbid', 'in_job', 'in_building', 'trader', 'garbage_collect', 'removed', 'dump', 'melt',
                      'hostile', 'owned', 'construction', 'encased', 'spider_web', 'on_fire', 'rotten'}
  local function link_jobs(b)
    local r = {}
    for _, j in ipairs(b.jobs) do if j.job_type == df.job_type.LinkBuildingToTrigger then r[#r + 1] = j end end
    return r
  end
  local function linked_to(lever, target_id)
    for _, m in ipairs(lever.linked_mechanisms) do
      local ref = dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_HOLDER)
      if ref and ref.building_id == target_id then return true end
    end
    return false
  end
  local function free_mechanisms(at, n)
    local cand = {}
    for _, it in ipairs(df.global.world.items.other.TRAPPARTS) do
      local f, ok = it.flags, true
      for _, k in ipairs(MECH_FLAGS) do if f[k] then ok = false; break end end
      if ok and f.in_inventory and dfhack.items.getHolderUnit(it) then ok = false end
      if ok then
        local x, y, z = dfhack.items.getPosition(it)
        if x and dfhack.maps.canWalkBetween(xyz2pos(x, y, z), at) then
          cand[#cand + 1] = {it = it, d = math.max(math.abs(x - at.x), math.abs(y - at.y), math.abs(z - at.z))}
        end
      end
    end
    table.sort(cand, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.it.id < b.it.id end)
    local r = {}
    for i = 1, math.min(n, #cand) do r[i] = cand[i].it end
    return r, #cand
  end
  function I.link_lever(lever_id, target_id)
    local lever, target = df.building.find(int(lever_id) or -1), df.building.find(int(target_id) or -1)
    if not lever or not is_lever(lever) then return false, 'not a lever' end
    if not target or target.id == lever.id then return false, 'no target building' end
    if lever:getBuildStage() < lever:getMaxBuildStage() then return false, 'lever not built' end
    if target:getBuildStage() < target:getMaxBuildStage() then return false, 'target not built' end
    if linked_to(lever, target.id) then return true, 'linked' end
    if #link_jobs(lever) > 0 then return false, 'a link job is pending on this lever' end
    local at = xyz2pos(lever.centerx, lever.centery, lever.z)
    local mech, n = free_mechanisms(at, 2)
    if #mech < 2 then return false, string.format('needs 2 free reachable mechanisms, %d found', n) end
    local job = df.job:new()
    job.job_type = df.job_type.LinkBuildingToTrigger
    job.pos = at
    if not dfhack.job.attachJobItem(job, mech[1], df.job_role_type.LinkToTrigger, -1, -1)
       or not dfhack.job.attachJobItem(job, mech[2], df.job_role_type.LinkToTarget, -1, -1) then
      job:delete()
      return false, 'attachJobItem failed'
    end
    dfhack.job.addGeneralRef(job, df.general_ref_type.BUILDING_HOLDER, lever.id)
    dfhack.job.addGeneralRef(job, df.general_ref_type.BUILDING_TRIGGERTARGET, target.id)
    lever.jobs:insert('#', job)
    dfhack.job.linkIntoWorld(job, true)
    dfhack.job.checkBuildingsNow()
    return true, job.id
  end

  -- nobles screen (info > administrators > choose a candidate for a vacant fort position). The screen's
  -- result is two records: the assignment names the citizen's historical figure (histfig, histfig2), and
  -- the figure gets a position link to the fortress entity (the same records as the expedition leader's,
  -- read live in L1, and hack/scripts/make-monarch.lua for the civ). Candidates as in the screen: an adult
  -- citizen, alive; the position must be offered (flags.ACTIVE: population and market requirements met).
  function I.appoint(code, unit_id)
    if type(code) ~= 'string' or not code:match('^[A-Z_]+$') then return false, 'bad position code' end
    local ent = fort_entity()
    if not ent then return false, 'no fortress entity' end
    local u = df.unit.find(int(unit_id) or -1)
    if not u then return false, 'no unit ' .. tostring(unit_id) end
    if not dfhack.units.isCitizen(u) or not dfhack.units.isAdult(u) or dfhack.units.isDead(u) then
      return false, 'not an adult living citizen'
    end
    local hf = df.historical_figure.find(u.hist_figure_id)
    if not hf then return false, 'no historical figure' end
    local pos, pidx = own_position(ent, function(p) return p.code == code end)
    if not pos then return false, 'no position ' .. code end
    if not pos.flags.ACTIVE then return false, code .. ' is not offered yet' end
    local asg, idx
    for i, a in ipairs(ent.positions.assignments) do
      if a.position_id == pos.id then
        if a.histfig == hf.id then return true, a.id end
        if a.histfig == -1 and not asg then asg, idx = a, i end
      end
    end
    if not asg then return false, code .. ' has no vacant assignment' end
    seat_figure(ent, pos, pidx, asg, idx, hf)
    return true, asg.id
  end

  function I.popcap(n)
    n = int(n)
    if not n or n < 0 or n > 250 then return false, 'cap must be 0..250' end
    return cmd_run('pop-control', 'set', 'max-pop', string.format('%d', n))
  end

  -- quickfort.apply_blueprint (quickfort.lua:43, docs tools/quickfort.txt:156-190)
  function I.quickfort(p)
    if type(p) ~= 'table' then return false, 'params must be a table' end
    if not QF_MODES[p.mode] then return false, 'bad quickfort mode ' .. tostring(p.mode) end
    local command = p.command or 'run'
    if not QF_COMMANDS[command] then return false, 'bad quickfort command ' .. tostring(command) end
    if type(p.data) ~= 'table' and type(p.data) ~= 'string' then return false, 'data required' end
    local x, y, z = xyz(p.pos)
    local params = {mode = p.mode, data = p.data, command = command, dry_run = p.dry_run == true,
                    pos = x and {x = x, y = y, z = z} or nil}   -- blueprint reference point
    if p.priority ~= nil then
      local pr = int(p.priority)
      if not pr or pr < 1 or pr > 7 then return false, 'priority must be 1..7' end
      params.priority = pr
    end
    if type(p.marker) == 'table' then params.marker = p.marker end
    local stats
    if command == 'orders' then
      -- apply_blueprint (quickfort.lua:43-56) only queues order specs; the manager orders are created
      -- by orders.create_orders (orders.lua:173), which only the CLI path calls (command.lua:183
      -- finish_commands). Same steps as apply_blueprint, plus that call (= `quickfort orders`).
      local api = script('internal/quickfort/api')
      local qcmd = script('internal/quickfort/command')
      local qord = script('internal/quickfort/orders')
      local data, cursor = api.normalize_data(params.data, params.pos)
      local ctx = api.init_api_ctx(params, cursor)
      for z, grid in pairs(data) do qcmd.do_command_raw(params.mode, z, grid, ctx) end
      qord.create_orders(ctx)
      stats = api.clean_stats(ctx.stats)
    else
      stats = script('quickfort').apply_blueprint(params)
    end
    local out = {}
    for k, v in pairs(stats or {}) do
      if type(v) == 'table' and type(v.value) == 'number' then out[k] = v.value end
    end
    return true, out
  end

  -- work orders screen > an order's up arrow, pressed until it stands first (Run 11 siege 8, seal first: ~110 rock
  -- orders stood before a seal's door): the named manager orders (<= 32 ids) move to the top of the list in the given
  -- order, the others keep theirs; ids not in the list are skipped. Returns ok, the number moved.
  function I.order_top(ids)
    if type(ids) ~= 'table' or #ids == 0 or #ids > 32 then return false, 'need 1-32 order ids' end
    local rank = {}
    for i, v in ipairs(ids) do
      local id = int(v)
      if not id then return false, 'bad order id ' .. tostring(v) end
      rank[id] = rank[id] or i
    end
    local all = df.global.world.manager_orders.all
    local pick = {}
    for i = #all - 1, 0, -1 do
      local o = all[i]
      if rank[o.id] then pick[#pick + 1] = o; all:erase(i) end
    end
    table.sort(pick, function(a, b) return rank[a.id] < rank[b.id] end)
    for i = #pick, 1, -1 do all:insert(0, pick[i]) end
    return true, #pick
  end

  function I.orders_import(lib)
    if not A.ORDER_LIBS[lib] then return false, 'unknown orders library ' .. tostring(lib) end
    return cmd_run('orders', 'import', lib)
  end

  function I.orders(sub)
    if sub ~= 'sort' and sub ~= 'recheck' then return false, 'orders sub must be sort or recheck' end
    return cmd_run('orders', sub)
  end

  -- workorder <json> (tools/workorder.txt); the new order is the one at manager_order_next_id.
  -- FR-39: an item-definition job (MakeArmor/Pants/Shoes/Gloves/Helm/Weapon/Ammo/Shield, ...) without an
  -- item_subtype is refused: DF 53.16 crashes when a dwarf takes such a job (four crashes on 14.10.2026)
  function I.workorder(spec)
    if type(spec) ~= 'table' then return false, 'spec must be a table' end
    if type(spec.tag) ~= 'string' or spec.tag:sub(1, 6) ~= 'dfllm:' then return false, 'spec.tag must start with dfllm:' end
    if OL.unsafe(spec.job, spec.item_subtype) then
      return false, tostring(spec.job) .. ' needs item_subtype (ITEM_...): DF 53.16 crashes without one (FR-39)'
    end
    local body = {}
    for k, v in pairs(spec) do if k ~= 'tag' then body[k] = v end end
    local mo = df.global.world.manager_orders
    local want = mo.manager_order_next_id
    local ok, out = cmd_run('workorder', json.encode(body))
    if not ok then return false, out end
    for i = #mo.all - 1, 0, -1 do
      if mo.all[i].id == want then return true, want end
      if mo.all[i].id < want then break end
    end
    return false, 'no order created: ' .. trim(out, 120)
  end

  function I.order_suspend(order_id, on)
    return false, 'manager orders have no verified suspend flag in DF 53 [S5]'
  end

  -- work orders screen > remove (FR-10, FR-39): the order leaves the manager's list, as the screen's cancel
  -- button removes it (DFHack `orders clear` deletes the same records); jobs it already made keep running.
  -- Returns ok, 'removed'.
  function I.order_remove(order_id)
    local id = int(order_id)
    if not id then return false, 'order id required' end
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do
      local o = all[i]
      if o.id == id then
        all:erase(i)
        pcall(function() o:delete() end)
        return true, 'removed'
      end
    end
    return false, 'no order ' .. tostring(order_id)
  end

  -- building / job sheet > "Resume" (FR-16): the suspended ConstructBuilding jobs with these ids get the
  -- vanilla suspend toggle cleared; any other job is left alone (no job is created or removed). Returns ok, n.
  function I.job_resume(ids)
    if type(ids) ~= 'table' then return false, 'job ids required' end
    local want, n = {}, 0
    for i, id in ipairs(ids) do
      if i > 200 then break end
      if int(id) then want[int(id)] = true end
    end
    local cb = df.job_type.ConstructBuilding
    local link, guard = df.global.world.jobs.list.next, 0
    while link and guard < 50000 do
      local j = link.item
      if j and want[j.id] and j.job_type == cb and j.flags.suspend then
        j.flags.suspend = false
        n = n + 1
      end
      link, guard = link.next, guard + 1
    end
    return true, n
  end

  -- farm plot sheet > crop per season (FR-17): plant_id[season] of a farm plot, as the player picks the crop;
  -- -1 = none. Returns ok, plant index.
  function I.farm_crop(bld_id, season, plant)
    local b = df.building.find(int(bld_id) or -1)
    if not b then return false, 'no building ' .. tostring(bld_id) end
    local okf, isf = pcall(function() return b:getType() == df.building_type.FarmPlot end)
    if not (okf and isf) then return false, 'not a farm plot' end
    season, plant = int(season), int(plant)
    if not season or season < 0 or season > 3 then return false, 'season must be 0..3' end
    if not plant or plant < -1 then return false, 'bad plant index' end
    if plant >= 0 and not df.global.world.raws.plants.all[plant] then return false, 'no plant ' .. tostring(plant) end
    b.plant_id[season] = plant
    return true, plant
  end

  -- designations > gather plants (FR-25): the shrubs at these positions get the player's gather designation
  -- (dfhack.designations.markPlant; trees are never marked here). The caller passes revealed, reachable
  -- positions only (snapshot). positions = {{x,y,z}} (<= 200). Returns ok, marked.
  function I.plant_gather(positions)
    if type(positions) ~= 'table' then return false, 'positions required' end
    local want, n = {}, 0
    for i, p in ipairs(positions) do
      if i > 200 then break end
      local x, y, z = xyz(p)
      x, y, z = int(x), int(y), int(z)
      if x and y and z then want[string.format('%d,%d,%d', x, y, z)] = true; n = n + 1 end
    end
    if n == 0 then return true, 0 end
    local des = dfhack.designations
    local marked = 0
    for _, vn in ipairs({'shrub_dry', 'shrub_wet'}) do
      local okv, vec = pcall(function() return df.global.world.plants[vn] end)
      for _, pl in ipairs(okv and vec or {}) do
        local p = pl.pos
        local k = string.format('%d,%d,%d', p.x, p.y, p.z)
        if want[k] then
          want[k] = nil
          if not des.isPlantMarked(pl) and des.markPlant(pl) then marked = marked + 1 end
        end
      end
    end
    return true, marked
  end

  -- kitchen screen (Lua API.txt:2650-2660); idempotent
  function I.kitchen_exclude(item_type, subtype, mat_type, mat_index, what)
    if what ~= 'Cook' and what ~= 'Brew' then return false, "what must be 'Cook' or 'Brew'" end
    local it = type(item_type) == 'string' and df.item_type[item_type] or item_type
    if type(it) ~= 'number' then return false, 'unknown item type ' .. tostring(item_type) end
    local flags = {[what] = true}
    if dfhack.kitchen.findExclusion(flags, it, subtype, mat_type, mat_index) >= 0 then return true, 'exists' end
    if not dfhack.kitchen.addExclusion(flags, it, subtype, mat_type, mat_index) then return false, 'addExclusion failed' end
    return true, 'added'
  end

  -- forbid/dump toggles; melt through dfhack.items.markForMelting/cancelMelting (Lua API.txt:2135-2141)
  function I.item_flag(item_id, flag, on)
    if not ITEM_FLAGS[flag] then return false, 'flag must be forbid, dump or melt' end
    local item = df.item.find(item_id)
    if not item then return false, 'no item ' .. tostring(item_id) end
    if flag == 'melt' then
      local changed
      if on then changed = dfhack.items.markForMelting(item) else changed = dfhack.items.cancelMelting(item) end
      return true, changed and true or false
    end
    item.flags[flag] = on and true or false
    return true
  end

  -- assign a unit to a pit/pond zone exactly like DFHack's assign screen (plugins/zone.lua:960-968)
  function I.zone_assign(zone_id, unit_id)
    local zone, u = df.building.find(zone_id), df.unit.find(unit_id)
    if not zone or not u then return false, 'no zone or unit' end
    for _, ref in ipairs(u.general_refs) do
      if df.general_ref_building_civzone_assignedst:is_instance(ref) then return false, 'unit already assigned' end
    end
    local ref = df.new(df.general_ref_building_civzone_assignedst)
    ref.building_id = zone.id
    u.general_refs:insert('#', ref)
    local vec, pos = zone.assigned_units, #zone.assigned_units
    for i = 0, #vec - 1 do
      if vec[i] == unit_id then return true, 'already' end
      if vec[i] > unit_id then pos = i; break end
    end
    vec:insert(pos, unit_id)
    return true
  end

  -- tomb zone sheet (FR-27/41/42, Run 9: stacked zones on one coffin, zones without a coffin, zones held by
  -- bodiless dead): op 'remove' (zones screen > remove: the owner link is dropped first, then the zone is
  -- deconstructed like quickfort's zone undo), 'free' (unassign; open to citizens), 'open' (the sheet's "allow
  -- citizens" toggle) or 'assign' (the sheet's assign button for a dead citizen; dfhack.buildings.setOwner as
  -- entomb.lua does). Tomb zones only. Returns ok, 'removed'|'freed'|'opened'|'assigned'|'already'.
  local function tomb_zone_of(id)
    local z = df.building.find(int(id) or -1)
    if not z then return nil, 'no zone ' .. tostring(id) end
    local okc, civ = pcall(function() return df.building_civzonest:is_instance(z) end)
    if okc and not civ then return nil, 'not a zone' end
    local okt, tomb = pcall(function() return z.type == df.civzone_type.Tomb end)
    if not (okt and tomb) then return nil, 'not a tomb zone' end
    return z
  end
  function I.tomb_zone(op, zone_id, unit_id)
    local z, why = tomb_zone_of(zone_id)
    if not z then return false, why end
    local owner = int(z.assigned_unit_id) or -1
    if op == 'remove' then
      if owner >= 0 and not dfhack.buildings.setOwner(z, nil) then return false, 'setOwner refused' end
      if dfhack.buildings.deconstruct(z) then return true, 'removed' end
      return false, 'deconstruct refused'
    elseif op == 'free' or op == 'open' then
      if op == 'free' and owner >= 0 and not dfhack.buildings.setOwner(z, nil) then return false, 'setOwner refused' end
      local f = z.zone_settings.tomb.flags
      local was = f.no_citizens
      f.no_citizens = false
      if op == 'free' then return true, 'freed' end
      return true, was and 'opened' or 'already'
    elseif op == 'assign' then
      local u = df.unit.find(int(unit_id) or -1)
      if not u or not dfhack.units.isDead(u) then return false, 'not a dead unit' end
      if owner == u.id then return true, 'already' end
      if owner >= 0 then return false, 'zone held by unit ' .. string.format('%d', owner) end
      if not dfhack.buildings.setOwner(z, u) then return false, 'setOwner refused' end
      return true, 'assigned'
    end
    return false, 'op must be remove, free, open or assign'
  end

  -- labors screen (FR-48, Run 9: all three doctors dead, DIAGNOSE/SURGERY/BONE_SETTING on nobody, 7 patients
  -- waiting for a diagnosis): the doctor labors of one citizen on or off. Adult living citizens only.
  function I.medic(unit_id, on)
    local u = df.unit.find(int(unit_id) or -1)
    if not u then return false, 'no unit ' .. tostring(unit_id) end
    if on and (not dfhack.units.isCitizen(u) or not dfhack.units.isAdult(u) or dfhack.units.isDead(u)) then
      return false, 'not an adult living citizen'
    end
    local n = 0
    for _, name in ipairs(A.MEDIC_LABORS) do
      local l = df.unit_labor[name]
      if l == nil then return false, 'no labor ' .. name end
      if (u.status.labors[l] == true) ~= (on == true) then
        u.status.labors[l] = on and true or false
        n = n + 1
      end
    end
    return true, n == 0 and 'already' or (on and 'enabled' or 'disabled')
  end

  -- location sheet > occupations (FR-48; v1 FEATURE-004 live note: with no hospital post filled the game posts
  -- no care jobs, and a post keeps pointing at its dead holder): fill one hospital post with a living adult
  -- citizen; a dead holder is unlinked first. A post held by a living citizen is never taken.
  local function site_hospital(loc_id)
    local site = dfhack.world.getCurrentSite()
    for _, l in ipairs(site and site.buildings or {}) do
      if l.id == loc_id then return l:getType() == df.abstract_building_type.HOSPITAL end
    end
    return false
  end
  function I.hospital_post(occ_id, unit_id)
    local id = int(occ_id)
    local occ
    for _, o in ipairs(df.global.world.occupations.all) do
      if o.id == id then occ = o; break end
    end
    if not occ then return false, 'no occupation ' .. tostring(occ_id) end
    if not A.HOSPITAL_POSTS[df.occupation_type[occ.type] or ''] or not site_hospital(occ.location_id) then
      return false, 'not a hospital post'
    end
    local u = df.unit.find(int(unit_id) or -1)
    if not u or not dfhack.units.isCitizen(u) or not dfhack.units.isAdult(u) or dfhack.units.isDead(u) then
      return false, 'not an adult living citizen'
    end
    local old = occ.unit_id >= 0 and df.unit.find(occ.unit_id) or nil
    if old and old.id == u.id then return true, 'already' end
    if old and not dfhack.units.isDead(old) then return false, 'post held by a living unit' end
    if old then
      for i = #old.occupations - 1, 0, -1 do
        if old.occupations[i].id == occ.id then old.occupations:erase(i) end
      end
    end
    occ.unit_id = u.id
    occ.histfig_id = u.hist_figure_id
    u.occupations:insert('#', occ)
    return true, 'filled'
  end

  -- work details screen (labor > work details): add a citizen to, or remove one from, a builtin tool
  -- detail (live L1b: economy owns these memberships while labormanager runs in monitor mode). The
  -- screen applies a detail's labors to its members; as DFHack's autofish.lua:77-92 does, the unit's
  -- labors follow the detail here. Leaving a detail clears a labor only when no other detail of the
  -- unit (or an everybody-does-this detail) still grants it.
  -- opts (live Run 10, Handlelock: six of eight miners sat in Planters, an everybody-does-this detail, and took the
  -- farm jobs while 25 dig jobs waited):
  --   only = true   the member does its tool detail's work only: it leaves every everybody-does-this detail that is no
  --                 tool detail (A.TOOL_LABOR_DETAILS) and those details' labors go off, except labors of the tool
  --                 detail itself, of another detail the unit is a selected member of, and opts.keep (labor names);
  --                 removing such a member (on = false) gives it the everybody labors back.
  --   equip = true  [live-untested, off by default: needs the player's yes, BUG-023] a tool labor switched on also marks
  --                 the dwarf for an equipment update (unit.uniform.pickup_flags.update and plotinfo.equipment.update.weapon,
  --                 the request the engine hands work picks and axes out on; v1 E18 Run 5 measurement). The dwarf still
  --                 walks to the tool and picks it up himself; no item is moved.
  --   select = true [live-untested, BUG-038] with on: a detail on "nobody does this" (it grants nothing) is set to
  --                 "only selected do this" (the work details screen's toggle); every other mode stays.
  -- Joining Miners, Woodcutters or Hunters (BUG-023, Run 11) also switches off the other two tool labors (A.TOOL_EXCL)
  -- when no detail grants them (a selected detail the unit is a member of, or an everybody-does-this one): DF's own
  -- labor pass clears them too, and the labors screen never lets a dwarf hold two of them (each wants its own tool).
  -- A second tool detail the unit is a member of (the player's choice) keeps its labor.
  function I.work_detail(name, unit_id, on, opts)
    if not A.TOOL_DETAILS[name] then return false, 'not a builtin tool detail: ' .. tostring(name) end
    opts = type(opts) == 'table' and opts or {}
    local every_mode = function() return df.work_detail_mode and df.work_detail_mode.EverybodyDoesThis end
    local function wd_member(w, id)
      for _, x in ipairs(w.assigned_units) do if x == id then return true end end
      return false
    end
    local function keep_set(names)
      local s = {}
      for _, n in ipairs(type(names) == 'table' and names or {}) do
        local l = df.unit_labor and df.unit_labor[n]
        if type(l) == 'number' then s[l] = true end
      end
      return s
    end
    -- the everybody-does-this details a specialist leaves (not the tool details, not `own`)
    local function everybody_details(details, own)
      local every, r = every_mode(), {}
      if not every then return r end
      for _, w in ipairs(details) do
        if w ~= own and w.flags.mode == every and not A.TOOL_LABOR_DETAILS[dfhack.df2utf(w.name)] then r[#r + 1] = w end
      end
      return r
    end
    local function specialize(details, wd, u, id, keep)
      local away, every, n = everybody_details(details, wd), every_mode(), 0
      local leave = {}
      for _, w in ipairs(away) do
        leave[w] = true
        local vec = w.assigned_units
        for i = #vec - 1, 0, -1 do if vec[i] == id then vec:erase(i) end end
      end
      for _, w in ipairs(away) do
        local al = w.allowed_labors
        for l = 0, #al - 1 do
          if al[l] and u.status.labors[l] and not wd.allowed_labors[l] and not keep[l] then
            local held = false
            local nobody = df.work_detail_mode.NobodyDoesThis
            for _, x in ipairs(details) do
              local m = x.flags.mode
              if not leave[x] and x ~= wd and m ~= every and m ~= nobody and x.allowed_labors[l] and wd_member(x, id) then
                held = true
              end
            end
            if not held then u.status.labors[l] = false; n = n + 1 end
          end
        end
      end
      return n
    end
    local function generalize(details, wd, u)
      local n = 0
      for _, w in ipairs(everybody_details(details, wd)) do
        local al = w.allowed_labors
        for l = 0, #al - 1 do
          if al[l] and not u.status.labors[l] then u.status.labors[l] = true; n = n + 1 end
        end
      end
      return n
    end
    local function equip_update(u)
      pcall(function() u.uniform.pickup_flags.update = true end)
      pcall(function() df.global.plotinfo.equipment.update.weapon = true end)
    end
    -- the other tool labors (A.TOOL_EXCL) no detail grants the unit go off (see above)
    local function stray_tools(details, wd, u, id)
      local every, nobody = every_mode(), df.work_detail_mode and df.work_detail_mode.NobodyDoesThis
      for dn, ln in pairs(A.TOOL_EXCL) do
        local l = df.unit_labor and df.unit_labor[ln]
        if dn ~= name and type(l) == 'number' and u.status.labors[l] and not wd.allowed_labors[l] then
          local held = false
          for _, x in ipairs(details) do
            local m = x.flags.mode
            if x ~= wd and x.allowed_labors[l] and (nobody == nil or m ~= nobody) and
               ((every ~= nil and m == every) or wd_member(x, id)) then
              held = true
            end
          end
          if not held then u.status.labors[l] = false end
        end
      end
    end
    local details = df.global.plotinfo.labor_info.work_details
    local wd
    for _, w in ipairs(details) do
      if dfhack.df2utf(w.name) == name then wd = w; break end
    end
    if not wd then return false, 'no work detail ' .. name end
    local id = int(unit_id)
    if not id then return false, 'unit id required' end
    local u = df.unit.find(id)
    if on and (not u or not dfhack.units.isCitizen(u) or not dfhack.units.isAdult(u)) then
      return false, 'not an adult citizen'
    end
    local vec, at, pos = wd.assigned_units, nil, #wd.assigned_units
    for i = 0, #vec - 1 do
      if vec[i] == id then at = i end
      if vec[i] > id and pos == #vec then pos = i end
    end
    local al = wd.allowed_labors
    if on then
      local sel = ''
      local wm = df.work_detail_mode
      if opts.select and wm and wm.NobodyDoesThis ~= nil and wm.OnlySelectedDoesThis ~= nil
         and wd.flags.mode == wm.NobodyDoesThis then
        wd.flags.mode = wm.OnlySelectedDoesThis
        sel = '; only selected do this now'
      end
      if not at then vec:insert(pos, id) end
      local turned = false
      for l = 0, #al - 1 do
        if al[l] then
          if not u.status.labors[l] then turned = true end
          u.status.labors[l] = true
        end
      end
      if opts.only then specialize(details, wd, u, id, keep_set(opts.keep)) end
      if A.TOOL_EXCL[name] then stray_tools(details, wd, u, id) end
      -- opts.equip = true: with a labor switched on / a new member; 'force': also for a member that already has it
      -- (economy's tool repair, Run 10: members added before tools.equip_update was on never got the request)
      if opts.equip and A.TOOL_LABOR_DETAILS[name] and (turned or not at or opts.equip == 'force') then equip_update(u) end
      return true, (at and 'already' or 'added') .. sel
    end
    if not at then return true, 'not a member' end
    vec:erase(at)                              -- a unit that left the fort (or died) is only taken off the list
    if not u then return true, 'removed' end
    if opts.only then generalize(details, wd, u) end
    local every = df.work_detail_mode and df.work_detail_mode.EverybodyDoesThis
    for l = 0, #al - 1 do
      if al[l] then
        local keep = false
        for _, w in ipairs(details) do
          if dfhack.df2utf(w.name) ~= name and w.allowed_labors[l] then
            if every and w.flags.mode == every then keep = true end
            for _, x in ipairs(w.assigned_units) do if x == id then keep = true end end
          end
        end
        if not keep then u.status.labors[l] = false end
      end
    end
    return true, 'removed'
  end

  -- work details screen (FR-40): the screen lists living citizens only; ids of units that died or left the
  -- fort stay in assigned_units and made a detail of 14 dead planters look full (119 PlantSeeds jobs unclaimed).
  -- Every id that is not in `living` (the census) and is no living citizen is taken off the list, as
  -- act.work_detail does for one unit and fix/dead-units for burrows; no labor of a living unit changes.
  function I.work_detail_prune(living)
    if type(living) ~= 'table' then return false, 'living citizen ids required' end
    local keep = {}
    for _, id in ipairs(living) do if int(id) then keep[int(id)] = true end end
    local n = 0
    for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do
      local vec = w.assigned_units
      for i = #vec - 1, 0, -1 do
        local id = vec[i]
        if not keep[id] then
          local u = df.unit.find(id)
          if not u or dfhack.units.isDead(u) or not dfhack.units.isCitizen(u, true) then
            vec:erase(i)
            n = n + 1
          end
        end
      end
    end
    return true, n
  end

  -- work orders screen: cancel a one-time rock furniture order and enter it again in wood for the amount left
  -- (live L3: quickfort's `orders` always picks rock; on this soil embark 43 doors, cabinets, coffers,
  -- coffins, tables and chairs waited for two years with 8 boulders and 82 logs in the fort). Only the
  -- material changes; job type, amount and conditions stay, like the re-entered order.
  function I.order_material(order_id, material)
    if material ~= 'wood' then return false, 'material must be wood' end
    local id = int(order_id)
    if not id then return false, 'order id required' end
    local o
    for _, x in ipairs(df.global.world.manager_orders.all) do
      if x.id == id then o = x; break end
    end
    if not o then return false, 'no order ' .. tostring(order_id) end
    if not A.WOOD_JOBS[df.job_type[o.job_type] or ''] then return false, 'no wood variant for this job' end
    if o.frequency ~= df.workquota_frequency_type.OneTime then return false, 'repeating order' end
    if o.mat_type ~= 0 or o.amount_left <= 0 then return false, 'not an open rock order' end
    o.mat_type, o.mat_index = -1, -1
    o.material_category.wood = true
    return true, 'wood'
  end

  A.install_trade(I, gui_proxy(), int)

  function I.run(cmd, ...)
    local args = table.pack(...)
    for i = 1, args.n do
      if type(args[i]) ~= 'string' then return false, 'run args must be strings' end
    end
    local ok, entry = A.allowed(state.allowlist(), cmd, args)
    if not ok then return false, entry end
    if state.who() == 'selftest' and (type(entry) ~= 'table' or entry.rw ~= 'r') then
      return false, 'selftest may only run read-only commands'
    end
    return cmd_run(cmd, ...)
  end

  return I
end

---------------------------------------------------------------- the act table K.act
-- env = {who = fn() -> module|nil, tick = fn() -> abs tick, allowlist = fn() -> doc,
--        log_cmd = fn(origin, what, args_json, result), fail = fn(fn, err, module)}
function A.new(env)
  local state = {own_jobs = {}, who = env.who, allowlist = env.allowlist}
  local I = impls(state)
  local owners = {}
  for fn, list in pairs(C.ACT) do
    owners[fn] = {}
    for _, m in ipairs(list) do owners[fn][m] = true end
  end
  local api = {}
  for fn in pairs(C.ACT) do
    local f = I[fn]
    api[fn] = function(...)
      local who = env.who()
      local args = table.pack(...)
      local ok, res, cost
      if who ~= nil and who ~= 'kern' and not owners[fn][who] then
        ok, res = false, 'not owner'
      elseif not f then
        ok, res = false, 'not implemented'
      else
        local c0 = os.clock()
        local pok, a, b = pcall(f, ...)
        cost = math.floor((os.clock() - c0) * 1000 + 0.5)
        if not pok then ok, res = false, tostring(a)
        else ok, res = a and true or false, b end
      end
      local result = ok and 'ok' or ('ERR ' .. tostring(res))
      env.log_cmd(who or 'kern', 'act.' .. fn, describe(fn, args, cost), result)
      if not ok then env.fail(fn, trim(res, 160), who or 'kern') end
      return ok, res
    end
  end
  return setmetatable(api, {__index = function(_, k) error('act.' .. tostring(k) .. ' does not exist', 2) end})
end

return A
