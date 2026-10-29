-- tools/embark/embark.lua: in-game embark helper, run BEFORE `dfllm adopt` (no kernel yet).
--   dfhack-run lua -f <repo>/tools/embark/embark.lua <cmd> [args]
--   state | check | screen [name] | click <text> [occ] | key <KEY> | run <spec.json> | status | stop
--   load <save folder> [--entry TEXT] [--no-stock] [--world-folder F]   K2: load a saved fort (loadsave.lua)
-- Fair play: reads only what the vanilla embark screens show (text buffer, focus strings,
-- the selected rectangle, points/picks left). Writes only UI state, all in W below: mouse
-- position, simulated input, camera centre, list selection. No world data, no hidden tiles,
-- no skill/item/point edits. `run` plays steps over frames in-process (dfhack.timeout
-- 'frames' fires on menus too, Lua API.txt:3285) and reports through status.json.
-- Struct field names (no XML ships with DFHack) were checked against the reflection strings in
-- hack/dfhack.dll 53.16-r2: viewscreen_choose_start_sitest.{zoomed_in, choosing_embark,
-- doing_site_finder, region_cent_x/y, zoom_cent_x/y, location}, embark_location.{region_pos,
-- embark_pos_min/max}, viewscreen_setupdwarfgamest.{dwarf_info, selected_u, points_remaining},
-- startup_charactersheetst.{skill_picks_left, skilllevel}. Usage also in gui/embark-anywhere.lua:36,
-- embark-skills.lua:20-30, startdwarf.lua:48, internal/confirm/specs.lua:521.
local args = {...}
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local here = me:match('^(.*)/[^/]+$') or '.'
local repo = here:match('^(.*)/tools/embark$') or (here .. '/../..')
local function add_path(p) if not package.path:find(p, 1, true) then package.path = p .. ';' .. package.path end end
add_path(repo .. '/lua/?.lua')     -- dfllm.util.json
add_path(repo .. '/tools/?.lua')   -- embark.* = tools/embark/*.lua

local active = package.loaded['embark.active']
if not (active and active.run and active.run.state == 'running') then  -- pick up edits between runs
  for k in pairs(package.loaded) do
    if k:match('^embark%.') and k ~= 'embark.active' then package.loaded[k] = nil end
  end
end
local json = require('dfllm.util.json')
local V = require('embark.view')
local panel = require('embark.panel')
local checklist = require('embark.checklist')
local I = require('embark.input')
local R = require('embark.runner')
local S = require('embark.steps')
local gui = require('gui')

local OUT = dfhack.getDFPath():gsub('\\', '/') .. '/dfllm-runtime/embark'   -- Lua API.txt:980
dfhack.filesystem.mkdir_recursive(OUT .. '/capture')                       -- Lua API.txt:3031

local function read_json(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return json.decode(s)
end
local function write(path, s)
  local f = assert(io.open(path, 'wb'))
  f:write(s)
  f:close()
end
local CFG = read_json(here .. '/ui.json')
local RULES = read_json(here .. '/rules.json')
local LOADOUT = read_json(here .. '/loadout.json')

local function native() return dfhack.gui.getDFViewscreen(true) end      -- Lua API.txt:1152
local function b(x) return x == true or x == 1 end

local function caption(name)  -- skill display name (armoks-blessing.lua:193)
  local id = df.job_skill[name]
  return id and df.job_skill.attrs[id].caption or name
end

local function skill_names()
  local seen, out = {}, {}
  for _, r in ipairs(LOADOUT.roles) do
    for _, sk in ipairs(r.skills) do
      if not seen[sk[1]] then seen[sk[1]] = true; out[#out + 1] = sk[1] end
    end
  end
  return out
end

---------------------------------------------------------------- reads (visible UI state)
local function source()
  local scr = native()
  return {
    size = function() return dfhack.screen.getWindowSize() end,                   -- Lua API.txt:2690
    ch = function(x, y) local p = dfhack.screen.readTile(x, y) return p and p.ch end,  -- :2716
    focus = function() return dfhack.gui.getFocusStrings(scr) end,                -- :1131
    cs = function()
      if not df.viewscreen_choose_start_sitest:is_instance(scr) then return nil end
      local l = scr.location  -- the highlighted rectangle (v1 place.sh read it live in Run 5/6)
      -- live 53.16 (L0): location.region_pos keeps the previous embark tile until a rectangle is
      -- placed; the zoomed-in local view is centred on zoom_cent (absolute embark tiles), so the
      -- world tile shown is zoom_cent // 16
      return {zoomed_in = b(scr.zoomed_in), choosing_embark = b(scr.choosing_embark),
        finder = b(scr.doing_site_finder), region = {l.region_pos.x, l.region_pos.y},
        zoom_world = {scr.zoom_cent_x // 16, scr.zoom_cent_y // 16},
        emb_min = {l.embark_pos_min.x, l.embark_pos_min.y}, emb_max = {l.embark_pos_max.x, l.embark_pos_max.y},
        cam_world = {scr.region_cent_x, scr.region_cent_y}, cam_local = {scr.zoom_cent_x, scr.zoom_cent_y}}
    end,
    -- K2: the fields of viewscreen_titlest the load run logs. DFHack 53.16-r3 renamed sel_menu_line to `selected`
    -- (old_field = the old name still exists); a missing field raises in DFHack, hence pcall. Read only.
    title = function()
      local okc, cls = pcall(function() return df.viewscreen_titlest end)
      if not (okc and cls and cls:is_instance(scr)) then return nil end
      local function field(name)
        local ok, val = pcall(function() return scr[name] end)
        if ok then return tonumber(val) or tostring(val) end
        return nil
      end
      -- BUG-230: the header lists behind the list rows (folder = filename_noext, as DF names the save folder) and
      -- their scroll positions; loadsave.lua finds the save's row by its folder, not by the (shared) world name
      local function headers(name)
        local ok, vec = pcall(function() return scr[name] end)
        if not ok or vec == nil then return nil end
        local okn, n = pcall(function() return #vec end)
        if not okn then return nil end
        local out = {}
        for i = 0, math.min(n, 60) - 1 do   -- bounded: status.json carries the lists
          local okh, h = pcall(function() return vec[i] end)
          local function f(k)
            local okf, val = pcall(function() return h[k] end)
            return (okh and okf and type(val) == 'string') and val or nil
          end
          out[#out + 1] = {folder = f('filename_noext'), world = f('world_name'), fort = f('fort_name')}
        end
        return out
      end
      -- BUG-245: the worlds of "Start new game in existing world" (region_choice: full_path, is_portable; Run 15c/15d
      -- read them live), so newgame --world-folder can check the folder it clicks exists in that kind
      local function regions()
        local ok, vec = pcall(function() return scr.region_choice end)
        if not ok or vec == nil then return nil end
        local okn, n = pcall(function() return #vec end)
        if not okn then return nil end
        local out = {}
        for i = 0, math.min(n, 60) - 1 do
          local okp, path = pcall(function() return vec[i].full_path end)
          local okq, port = pcall(function() return vec[i].is_portable end)
          local portable = nil
          if okq and port ~= nil then portable = (port == true or port == 1) end
          out[#out + 1] = {path = okp and type(path) == 'string' and path or nil, portable = portable}
        end
        return out
      end
      return {old_field = field('sel_menu_line') ~= nil, sel_menu_line = field('sel_menu_line'),
        selected = field('selected'), selected_r = field('selected_r'), mode = field('mode'),
        worlds = headers('savegame_header_world'), games = headers('savegame_header_game'),
        saves = headers('savegame_header'), scroll_world = field('scroll_position_world_choice'),
        scroll_game = field('scroll_position_game_choice'), regions = regions()}
    end,
    -- BUG-250 (save-as): the current save folder, as DFHack names it (read only)
    save_path = function()
      local ok, p = pcall(dfhack.getSavePath)
      return ok and type(p) == 'string' and p or nil
    end,
    prep = function()
      if not df.viewscreen_setupdwarfgamest:is_instance(scr) then return nil end
      local units = {}
      for i = 0, #scr.dwarf_info - 1 do   -- skill picks/levels as shown on "Prepare carefully"
        local d, lv = scr.dwarf_info[i], {}
        for _, name in ipairs(skill_names()) do
          local id = df.job_skill[name]
          if id then lv[name] = d.skilllevel[id] end
        end
        units[i + 1] = {picks = d.skill_picks_left, lv = lv}
      end
      return {selected = scr.selected_u, points = scr.points_remaining, units = units}
    end,
  }
end

local function capture() return V.capture(source()) end

---------------------------------------------------------------- writes (UI state only)
local W = {}
-- Live L0 findings (DF on a hidden virtual desktop, never focused):
-- * DF has no mouse focus (enabler.mouse_focus false) and writes the mouse itself before every
--   render frame: -1 without the focus, the cached OS cursor (wherever Gordon's mouse last was
--   relative to the window) with it. The placing rectangle and the site panel follow the mouse
--   that render frames see, so a mouse written between frames loses on every render frame.
-- * Fix: a pass-through DFHack screen on top of the embark screen (the "mouse injector") writes
--   our mouse right before the embark screen renders, forwards all input to it and runs its
--   logic. It changes nothing but where DF believes the mouse is, i.e. the UI state "mouse over
--   the window at (x, y)"; it is shown only while the local map is used and dismissed before any
--   screen-changing click (Confirm) and at the end of every run.
-- BUG-228 (= the cause of BUG-020, Run 15 embark on i2): DF ignores a written mouse while
-- enabler.tracking_on is 0 (it drops to 0, likely on a mouse-leave of the window): the rectangle sticks and
-- the panel stays empty. The injector therefore sets tracking_on = 1 while it is shown (render and logic
-- frames) and gives the old value back when it is dismissed. Never permanently: without the injector DF then
-- uses the cached OS cursor and the rectangle jumps ("rectangle moved before the click").
-- W.track(true) remembers the value before the injector, W.track(false) restores it (no field: no-op).
-- The old value is kept boxed ({value}) so a boolean false (a bool field) is restored too, not mistaken for "none".
local function tracking(v)   -- read (v nil): true, value | false (no field); write: true when written
  local e = df.global.enabler
  if not e then return false end
  if v == nil then
    local ok, val = pcall(function() return e.tracking_on end)
    return ok and val ~= nil, val
  end
  return (pcall(function() e.tracking_on = v end))
end
function W.track(on)
  if on then
    if W.track_old == nil then
      local has, val = tracking()
      W.track_old = has and {val} or {}
    end
    if W.track_old[1] ~= nil then tracking(type(W.track_old[1]) == 'boolean' and true or 1) end
  elseif W.track_old ~= nil then
    local old = W.track_old[1]
    W.track_old = nil
    if old ~= nil then tracking(old) end
  end
end
local Inj  -- class built on first use (the offline fake DF has no gui.Screen/defclass)
local function inj_class()
  if Inj or not (rawget(_G, 'defclass') and gui.Screen) then return Inj end
  Inj = defclass(nil, gui.Screen)
  Inj.ATTRS{focus_path = 'dfllm-embark/mouse'}
  function Inj:render()
    local p = self.pos
    W.track(true)
    if p then
      local g = df.global.gps
      df.global.enabler.mouse_focus = true
      g.mouse_x, g.mouse_y, g.precise_mouse_x, g.precise_mouse_y = p[1], p[2], p[3], p[4]
    end
    self:renderParent()
  end
  function Inj:onIdle()
    local parent = self._native and self._native.parent
    if not (parent and df.viewscreen_choose_start_sitest:is_instance(parent)) then self:dismiss() return end
    W.track(true)
    parent:logic()
  end
  function Inj:onInput(keys)
    self:sendInputToParent(keys)
    return true
  end
  function Inj:onDismiss()
    if rawget(_G, 'dfllm_embark_inj') == self then _G.dfllm_embark_inj = nil end
    df.global.enabler.mouse_focus = false
    W.track(false)
  end
  return Inj
end
local function inj() local i = rawget(_G, 'dfllm_embark_inj') return (i and i._native) and i or nil end
function W.inject(on)
  local i = inj()
  if on and not i then
    local C = inj_class()
    if not C or not df.viewscreen_choose_start_sitest:is_instance(native()) then return false end
    _G.dfllm_embark_inj = C{}
    _G.dfllm_embark_inj:show()
  elseif not on and i then
    i:dismiss()
  end
  return on and inj() ~= nil or false
end
-- required for simulated clicks (Lua API.txt:4208-4212); a hover (input.lua hold) also claims the
-- mouse focus. With the injector shown the same position is written before every render frame.
local function set_focus(on)  -- enabler.mouse_focus (absent in the offline fake)
  local e = df.global.enabler
  if e then e.mouse_focus = on end
end
function W.mouse(tx, ty, px, py, focus)
  local g = df.global.gps
  if focus then set_focus(true) end
  g.mouse_x, g.mouse_y, g.precise_mouse_x, g.precise_mouse_y = tx, ty, px, py
  local i = inj()
  if i then i.pos = {tx, ty, px, py} end
end
-- only the focus flag (writing mouse -1 would move the placing rectangle); a no-op while the
-- injector is shown: it keeps the focus and the position for render frames
function W.unfocus() if not inj() then set_focus(false) end end
function W.release_all()
  W.inject(false)
  W.track(false)   -- BUG-228: an injector that vanished without onDismiss still gives tracking_on back
  set_focus(false)
end
function W.claim() set_focus(true) end
-- read (not write) the mouse pixel DF holds; input.lua probe() learns the cached OS cursor from it
local function peek() local g = df.global.gps return g.precise_mouse_x, g.precise_mouse_y end
function W.sim(keys) gui.simulateInput(native(), keys) end                       -- gui.lua:58
-- K2: DFHack's own stock `load-save` (RULES 1.2 allows it), called only where viewscreen_titlest still has the
-- field it writes (loadsave.lua checks `old_field`); true, output | false, why
function W.stock_load(save)
  local ok, out, cr = pcall(dfhack.run_command_silent, 'load-save', save)
  if not ok then return false, tostring(out) end
  if cr ~= nil and cr ~= 0 then return false, tostring(out or cr) end
  return true, tostring(out or '')
end
-- BUG-230: = scrolling a title-screen list with the wheel (the scroll position of the world or game list); only on
-- viewscreen_titlest, only the two scroll fields; true when written
function W.scroll(which, n)
  local scr = native()
  local okc, cls = pcall(function() return df.viewscreen_titlest end)
  if not (okc and cls and cls:is_instance(scr)) then return false end
  local key = ({world = 'scroll_position_world_choice', game = 'scroll_position_game_choice'})[which]
  if not key or type(n) ~= 'number' or n < 0 then return false end
  return (pcall(function() scr[key] = math.floor(n) end))
end
function W.camera(which, x, y)  -- = scrolling the map; changes nothing in the world
  local scr = native()
  if not df.viewscreen_choose_start_sitest:is_instance(scr) then return end
  if which == 'world' then scr.region_cent_x, scr.region_cent_y = x, y
  else scr.zoom_cent_x, scr.zoom_cent_y = x, y end
end
function W.select_unit(i)  -- = clicking a dwarf in the list (as startdwarf.lua:48 does)
  local scr = native()
  if df.viewscreen_setupdwarfgamest:is_instance(scr) then scr.selected_u = i end
end

local function input_env()
  return {now = dfhack.getTickCount, mouse = W.mouse, unfocus = W.unfocus, claim = W.claim, peek = peek, sim = W.sim,
    tile_px = function() local g = df.global.gps return g.tile_pixel_x, g.tile_pixel_y end,
    win = function() return dfhack.screen.getWindowSize() end}
end

local function dump(name, v) write(OUT .. '/capture/' .. name .. '.txt', (v or capture()):dump() .. '\n') end

local function site_eval(v)
  local rec = panel.parse(v)
  local ctx = {}
  if v.cs then
    local m, x = v.cs.emb_min, v.cs.emb_max
    ctx.world = {m[1] // 16, m[2] // 16}
    ctx.size = {x[1] - m[1] + 1, x[2] - m[2] + 1}
  end
  return rec, checklist.evaluate(rec, RULES, ctx), ctx
end

---------------------------------------------------------------- run loop
local function loop()
  local a = package.loaded['embark.active']
  if not a or not a.run then return end
  local ok, more = pcall(a.run.frame, a.run)
  if not ok then
    a.run.state, a.run.msg = 'failed', 'lua error: ' .. tostring(more)
    pcall(a.run.push, a.run)
    pcall(W.release_all)
    return
  end
  if more then dfhack.timeout(1, 'frames', loop) else pcall(W.release_all) end
end

-- the steps rely on the Confirm popup after every placement click; without
-- [EMBARK_WARNING_ALWAYS:YES] a click on a warning-free site could embark at once (prefs are only read)
local function confirm_always()
  local f = io.open(dfhack.getDFPath() .. '/prefs/d_init.txt', 'rb')
  if not f then return false end
  local s = f:read('a')
  f:close()
  return s:find('[EMBARK_WARNING_ALWAYS:YES]', 1, true) ~= nil
end

local function start(spec)
  local a = package.loaded['embark.active']
  if a and a.run and a.run.state == 'running' then qerror('run ' .. a.run.id .. ' is active; use stop') end
  if (spec.mode == 'scan' or spec.mode == 'embark') and not confirm_always() then
    qerror('set Settings > "Confirmation window for all embarks" (d_init EMBARK_WARNING_ALWAYS:YES) first')
  end
  local steps = S.build(spec, CFG, LOADOUT)
  W.release_all()  -- a stale injector from an earlier run
  local env = {capture = capture, now = dfhack.getTickCount, ui = I.new(input_env(), CFG), w = W,
    status = function(doc)
      write(OUT .. '/status.json', json.encode(doc) .. '\n')
      if doc.state ~= 'running' then write(OUT .. '/result-' .. doc.id .. '.json', json.encode(doc) .. '\n') end
    end,
    dump = function(name) dump(spec.id .. '-' .. name) end}
  local ctx = {spec = spec, rules = RULES, caption = caption, results = {}, warnings = {},
    dump = function(name, v) dump(spec.id .. '-' .. name, v) end}
  local run = R.new(spec.id, steps, env, ctx, CFG)
  package.loaded['embark.active'] = {run = run}
  run:push()
  dfhack.timeout(1, 'frames', loop)
  print(string.format('embark run %s started: %d steps; status %s/status.json', spec.id, #steps, OUT))
end

---------------------------------------------------------------- commands
local cmd = args[1] or 'state'
if cmd == 'state' or cmd == 'check' then
  local v = capture()
  local rec, verdict, ctx = site_eval(v)
  local doc = {kind = v:kind(), focus = v.focus, cs = v.cs, rec = rec, verdict = verdict, world = ctx.world}
  if cmd == 'state' then
    doc.prep = v.prep and {selected = v.prep.selected, points = v.prep.points, units = v.prep.units} or nil
  end
  print(json.encode(doc))
elseif cmd == 'screen' then
  if args[2] then dump(args[2]) print('wrote ' .. OUT .. '/capture/' .. args[2] .. '.txt')
  else print(capture():dump()) end
elseif cmd == 'click' then
  local text, occ = args[2], tonumber(args[3] or '1')
  start({v = 2, id = 'click' .. os.time(), mode = 'steps', steps = {
    {id = 'click', live = 'run4-6', act = function(ui, v)
      if not S.tap(ui, v, text, {occ = occ}) then return 'fail', text .. ' not found' end
    end}}})
elseif cmd == 'key' then
  W.sim(args[2])
  print('sent ' .. tostring(args[2]))
elseif cmd == 'load' then
  -- K2: load <save folder> [--entry TEXT] [--no-stock] [--world-folder FOLDER]; the same run as `run` with a spec of mode load (embark.py load
  -- and `dfpilot supervise` write the spec file and use `run`)
  local save, entry, stock, world_folder = args[2], nil, true, nil
  if not save or save == '' or save:sub(1, 2) == '--' then qerror('usage: load <save folder> [--entry TEXT] [--no-stock] [--world-folder FOLDER]') end
  local i = 3
  while args[i] do
    if args[i] == '--entry' then entry = args[i + 1]; i = i + 2
    elseif args[i] == '--no-stock' then stock = false; i = i + 1
    elseif args[i] == '--world-folder' then world_folder = args[i + 1]; i = i + 2   -- BUG-230
    else qerror('load: unknown argument ' .. tostring(args[i])) end
  end
  start({v = 2, id = 'load' .. os.time(), mode = 'load', save = save, entry = entry, stock = stock,
    world_folder = world_folder})
elseif cmd == 'run' then
  local spec = read_json(args[2] or '')
  if not spec then qerror('cannot read spec ' .. tostring(args[2])) end
  start(spec)
elseif cmd == 'status' then
  local f = io.open(OUT .. '/status.json', 'rb')
  print(f and f:read('a') or '{}')
  if f then f:close() end
elseif cmd == 'stop' then
  local a = package.loaded['embark.active']
  if a and a.run then a.run:stop('stopped by command') print('stopped ' .. a.run.id) else print('no run') end
  W.release_all()
else
  qerror('unknown command ' .. cmd)
end
