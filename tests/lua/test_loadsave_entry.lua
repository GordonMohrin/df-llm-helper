-- K2: tools/embark/embark.lua `load` end to end against fake dfhack/df/gui globals backed by the fake title screens
-- (fixtures/fake_df.lua): the DF bindings (viewscreen_titlest fields with either name, the stock load-save call,
-- the frame loop, status.json), not DF itself.
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path
local T = require('testlib')
local json = require('dfllm.util.json')
local F = require('embark.fixtures.fake_df')

local tmp = (os.getenv('TEMP') or os.getenv('TMP') or '.'):gsub('\\', '/') .. '/dfllm-loadsave-test'
local OUT = tmp .. '/dfllm-runtime/embark'

-- fields: what the fake viewscreen_titlest has (any other name raises like DFHack); returns cmd, pump, ctl
local function install(D, fields)
  local timers, lines = {}, nil
  local ctl = {writes = {}, stock = {}, fields = fields}
  local function titleish()
    return D.screen == 'title' or D.screen == 'savelist' or D.screen == 'loadpopup' or D.screen == 'loadsave'
  end
  local scr = setmetatable({}, {
    __index = function(_, k)
      if ctl.fields[k] ~= nil then return ctl.fields[k] end
      error('Field ' .. k .. ' not found', 2)
    end,
    __newindex = function(_, k) ctl.writes[#ctl.writes + 1] = k; error('the title screen must not be written: ' .. k) end})
  local gps = {tile_pixel_x = D.tpx, tile_pixel_y = D.tpy, mouse_x = 0, mouse_y = 0, precise_mouse_x = 0, precise_mouse_y = 0}
  _G.df = {global = {gps = gps},
    viewscreen_titlest = {is_instance = function(_, s) return s == scr and titleish() end},
    viewscreen_choose_start_sitest = {is_instance = function() return false end},
    viewscreen_setupdwarfgamest = {is_instance = function() return false end}}
  _G.dfhack = {
    getDFPath = function() return tmp end,
    getTickCount = function() return D.ms end,
    filesystem = {mkdir_recursive = function(p) return luahost.mkdir_recursive(p) end},
    timeout = function(n, mode, cb) assert(mode == 'frames') timers[#timers + 1] = cb return #timers end,
    gui = {getDFViewscreen = function() return scr end, getFocusStrings = function() return D.source().focus() end},
    screen = {getWindowSize = function() lines = D.lines() return D.w, D.h end,
      readTile = function(x, y) return {ch = (lines or D.lines())[y + 1]:byte(x + 1)} end},
    run_command_silent = function(name, save)
      ctl.stock[#ctl.stock + 1] = name .. ' ' .. save
      local ok, why = D.w_api.stock_load(save)
      return why, ok and 0 or 1
    end,
  }
  _G.qerror = function(m) error(m, 0) end
  D.mouse = setmetatable({}, {__index = function(_, i)
    return ({gps.mouse_x, gps.mouse_y, gps.precise_mouse_x, gps.precise_mouse_y})[i]
  end})
  package.loaded.gui = {simulateInput = function(s, keys)
    assert(s == scr)
    D.env.sim(keys)
  end}
  local chunk = assert(loadfile(repo .. '/tools/embark/embark.lua'))
  local function pump(max)
    local n = 0
    while #timers > 0 and n < (max or 100000) do
      local cb = table.remove(timers, 1)
      cb()
      D.ms = D.ms + 20
      D.tick()
      n = n + 1
    end
    return n
  end
  return function(...) return chunk(...) end, pump, ctl
end

local function slurp(p)
  local f = io.open(p, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function capture_print(fn)
  local out, old = {}, print
  print = function(...) local t = {} for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end out[#out + 1] = table.concat(t, '\t') end
  local ok, err = pcall(fn)
  print = old
  if not ok then error(err, 0) end
  return table.concat(out, '\n')
end

local SAVES = {{name = 'autosave 10'}, {name = 'autosave 1'}, {name = 'region2'}}

T.test('entry load (DFHack r3 fields): no sel_menu_line, the stock load-save is not called, the clicks load the save', function()
  local D = F.new({saves = SAVES})
  local cmd, pump, ctl = install(D, {selected = 0, selected_r = -1, mode = 0})
  local out = capture_print(function() cmd('load', 'autosave 1') end)
  T.ok(out:find('started', 1, true), out)
  pump()
  local st = json.decode(slurp(OUT .. '/status.json'))
  T.eq(st.state, 'done', st.msg)
  T.eq(D.chosen, 'autosave 1')
  T.eq(ctl.stock, {}, 'no sel_menu_line: the stock script is not called')
  T.eq(ctl.writes, {}, 'nothing is written to the title screen')
  T.eq(st.results.title.old_field, false)
  T.eq({st.results.title.selected, st.results.title.selected_r}, {0, -1}, 'the new fields are read')
  T.eq(#st.results.clicks, 2)
  T.eq(st.results.clicks[1].text, 'Continue playing')
  T.ok(st.results.rows ~= nil)
  T.ok(slurp(OUT .. '/result-' .. st.id .. '.json') ~= nil, 'a result file is written at the end')
end)

T.test('entry load (older DFHack): sel_menu_line exists, the stock load-save runs first, no click', function()
  local D = F.new({saves = SAVES, old_field = true})
  local cmd, pump, ctl = install(D, {sel_menu_line = 2, mode = 0})
  capture_print(function() cmd('load', 'autosave 1') end)
  pump()
  local st = json.decode(slurp(OUT .. '/status.json'))
  T.eq(st.state, 'done', st.msg)
  T.eq(ctl.stock, {'load-save autosave 1'})
  T.eq(D.loaded, 'autosave 1')
  T.eq(st.results.title.old_field, true)
  T.eq(st.results.title.sel_menu_line, 2)
  T.eq(#(st.results.clicks or {}), 0)
end)

T.test('entry load --no-stock and --entry reach the spec', function()
  local D = F.new({saves = {{name = 'autosave 1', label = 'Ostlysh, Year 52'}}, old_field = true})
  local cmd, pump, ctl = install(D, {sel_menu_line = 2})
  capture_print(function() cmd('load', 'autosave 1', '--entry', 'Ostlysh', '--no-stock') end)
  pump()
  local st = json.decode(slurp(OUT .. '/status.json'))
  T.eq(st.state, 'done', st.msg)
  T.eq(ctl.stock, {}, '--no-stock')
  T.eq(st.results.clicks[2].text, 'Ostlysh', '--entry')
end)

T.test('entry load: usage errors', function()
  local D = F.new({saves = SAVES})
  local cmd = install(D, {selected = 0})
  T.raises(function() capture_print(function() cmd('load') end) end, 'usage')
  T.raises(function() capture_print(function() cmd('load', '--no-stock') end) end, 'usage')
  T.raises(function() capture_print(function() cmd('load', 'x', '--bogus') end) end, 'unknown argument')
end)

T.test('entry load: a title screen the fake cannot read as titlest still runs by its focus', function()
  local D = F.new({saves = SAVES})
  local cmd, pump = install(D, {})          -- no field at all
  capture_print(function() cmd('load', 'autosave 1', '--no-stock') end)
  pump()
  local st = json.decode(slurp(OUT .. '/status.json'))
  T.eq(st.state, 'done', st.msg)
  T.eq(st.results.title.old_field, false)
end)

-- remove the files written above
for _, d in ipairs({OUT .. '/capture', OUT}) do
  for _, name in ipairs(luahost.listdir(d) or {}) do os.remove(d .. '/' .. name) end
end

T.done()
