-- tools/embark/embark.lua: in-game embark helper, run BEFORE `dfllm adopt` (no kernel yet).
--   dfhack-run lua -f <repo>/tools/embark/embark.lua <cmd> [args]
--   state | check | screen [name] | click <text> [occ] | key <KEY> | run <spec.json> | status | stop
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
      return {zoomed_in = b(scr.zoomed_in), choosing_embark = b(scr.choosing_embark),
        finder = b(scr.doing_site_finder), region = {l.region_pos.x, l.region_pos.y},
        emb_min = {l.embark_pos_min.x, l.embark_pos_min.y}, emb_max = {l.embark_pos_max.x, l.embark_pos_max.y},
        cam_world = {scr.region_cent_x, scr.region_cent_y}, cam_local = {scr.zoom_cent_x, scr.zoom_cent_y}}
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
function W.mouse(tx, ty, px, py)  -- required for simulated clicks (Lua API.txt:4208-4212)
  local g = df.global.gps
  g.mouse_x, g.mouse_y, g.precise_mouse_x, g.precise_mouse_y = tx, ty, px, py
end
function W.sim(keys) gui.simulateInput(native(), keys) end                       -- gui.lua:58
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
  return {now = dfhack.getTickCount, mouse = W.mouse, sim = W.sim,
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
    return
  end
  if more then dfhack.timeout(1, 'frames', loop) end
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
else
  qerror('unknown command ' .. cmd)
end
