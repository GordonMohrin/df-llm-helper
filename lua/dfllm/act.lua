-- act: the ONLY code that writes game state (CONTRACTS §5, DESIGN §11.2). Every function maps to a
-- UI action, returns ok, res_or_err, never raises, logs one commands.log line and emits ACT_FAIL (B)
-- on failure. Callers are checked against contract.ACT. [S#] marks behaviour a live spike must confirm.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local A = {}

A.ORDER_LIBS = {['library/basic'] = true, ['library/furnace'] = true, ['library/smelting'] = true,
                ['library/military'] = true, ['library/rockstock'] = true, ['library/glassstock'] = true}
local QF_MODES = {dig = true, build = true, place = true, zone = true, burrow = true}
local QF_COMMANDS = {run = true, orders = true, undo = true}
local ITEM_FLAGS = {forbid = true, dump = true, melt = true}

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

-- commands.log args: compact JSON, quickfort data summarized, ≤300 bytes
local function describe(fn, args)
  local a = {}
  for i = 1, args.n do a[i] = args[i] end
  if fn == 'quickfort' and type(a[1]) == 'table' then
    local p, n = a[1], 0
    if type(p.data) == 'table' then
      for _, g in pairs(p.data) do for _, r in pairs(g) do for _ in pairs(r) do n = n + 1 end end end
    end
    a = {{mode = p.mode, command = p.command or 'run', pos = p.pos, cells = n}}
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

  -- military module (Lua API.txt:1973-1993) [S2]
  function I.squad_create(name, opts)
    local aid = int((opts or {}).assignment_id)
    if not aid then return false, 'assignment_id required [S2]' end
    local sq = dfhack.military.makeSquad(aid)
    if not sq then return false, 'makeSquad failed' end
    if type(name) == 'string' and name ~= '' then
      local cp = dfhack.utf2df(name)
      sq.alias = cp
      pcall(function() sq.name.nickname = cp end)   -- "consider setting squad.name.nickname" (Lua API.txt:1973)
    end
    return true, sq.id
  end

  -- CONTRACTS §5 R4: appoint the leader through the squad's position assignment (the squads screen).
  -- The UI path is unverified until spike S2; military asks Gordon (DECISION_NEEDED) meanwhile.
  function I.squad_leader(squad_id, unit_id)
    return false, 'squad_leader not implemented until spike S2 (appoint the leader in the squads screen)'
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

  function I.squad_uniform(squad_id, spec)
    return false, 'squad_uniform not implemented until spike S2'
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

  function I.orders_import(lib)
    if not A.ORDER_LIBS[lib] then return false, 'unknown orders library ' .. tostring(lib) end
    return cmd_run('orders', 'import', lib)
  end

  function I.orders(sub)
    if sub ~= 'sort' and sub ~= 'recheck' then return false, 'orders sub must be sort or recheck' end
    return cmd_run('orders', sub)
  end

  -- workorder <json> (tools/workorder.txt); the new order is the one at manager_order_next_id
  function I.workorder(spec)
    if type(spec) ~= 'table' then return false, 'spec must be a table' end
    if type(spec.tag) ~= 'string' or spec.tag:sub(1, 6) ~= 'dfllm:' then return false, 'spec.tag must start with dfllm:' end
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
      local ok, res
      if who ~= nil and who ~= 'kern' and not owners[fn][who] then
        ok, res = false, 'not owner'
      elseif not f then
        ok, res = false, 'not implemented'
      else
        local pok, a, b = pcall(f, ...)
        if not pok then ok, res = false, tostring(a)
        else ok, res = a and true or false, b end
      end
      local result = ok and 'ok' or ('ERR ' .. tostring(res))
      env.log_cmd(who or 'kern', 'act.' .. fn, describe(fn, args), result)
      if not ok then env.fail(fn, trim(res, 160), who or 'kern') end
      return ok, res
    end
  end
  return setmetatable(api, {__index = function(_, k) error('act.' .. tostring(k) .. ' does not exist', 2) end})
end

return A
