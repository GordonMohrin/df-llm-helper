-- WP11: tools/embark/embark.lua end to end against fake dfhack/df/gui globals that are backed
-- by the fake embark screens (tools/embark/fixtures/fake_df.lua). Checks the DF bindings
-- (reads, the UI-state writers, the frame loop, status/result files), not DF itself.
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path
local T = require('testlib')
local json = require('dfllm.util.json')
local F = require('embark.fixtures.fake_df')

-- fixed folder: Lua cannot remove directories on Windows; the files are removed at the end
local tmp = (os.getenv('TEMP') or os.getenv('TMP') or '.'):gsub('\\', '/') .. '/dfllm-embark-test'
local OUT = tmp .. '/dfllm-runtime/embark'

local SKILL_IDS = {MINING = 0, WOODCUTTING = 1, CARPENTRY = 2, ENGRAVE_STONE = 3, MASONRY = 4, BREWING = 5,
  PLANT = 6, MECHANICS = 7, COOK = 8, DIAGNOSE = 9, SURGERY = 10, SET_BONE = 11, SUTURE = 12}

-- install fake globals for one fake DF `D`; returns the frame pump
local function install(D)
  local timers, lines = {}, nil
  local writes = {}
  local function cs_screen() return D.source().cs() ~= nil end
  local function prep_screen() return D.source().prep() ~= nil end
  local vec = function(t) return setmetatable({}, {__index = function(_, i) return t[i + 1] end,
    __len = function() return #t end}) end
  local scr = setmetatable({}, {
    __index = function(_, k)
      local cs = D.source().cs() or {}
      if k == 'zoomed_in' then return cs.zoomed_in end
      if k == 'choosing_embark' then return cs.choosing_embark end
      if k == 'doing_site_finder' then return false end
      if k == 'location' then
        local m, x, r = D.rect()
        r, m, x = r or {-1, -1}, m or {-1, -1}, x or {-1, -1}
        return {region_pos = {x = r[1], y = r[2]}, embark_pos_min = {x = m[1], y = m[2]},
          embark_pos_max = {x = x[1], y = x[2]}}
      end
      if k == 'region_cent_x' then return D.cent[1] elseif k == 'region_cent_y' then return D.cent[2] end
      if k == 'zoom_cent_x' then return D.zoom[1] elseif k == 'zoom_cent_y' then return D.zoom[2] end
      if k == 'selected_u' then return D.selected end
      if k == 'points_remaining' then return D.points end
      if k == 'dwarf_info' then
        local t = {}
        for i, u in ipairs(D.units) do
          t[i] = {skill_picks_left = u.picks, skilllevel = setmetatable({}, {__index = function(_, id)
            for n, sid in pairs(SKILL_IDS) do if sid == id then return u.lv[n] or 0 end end
          end})}
        end
        return vec(t)
      end
    end,
    __newindex = function(_, k, v)
      writes[#writes + 1] = k
      if k == 'region_cent_x' then D.cent[1] = v elseif k == 'region_cent_y' then D.cent[2] = v
      elseif k == 'zoom_cent_x' then D.zoom[1] = v elseif k == 'zoom_cent_y' then D.zoom[2] = v
      elseif k == 'selected_u' then D.selected = v
      else error('unexpected screen write ' .. k) end
    end})
  local gps = {tile_pixel_x = D.tpx, tile_pixel_y = D.tpy, mouse_x = 0, mouse_y = 0, precise_mouse_x = 0, precise_mouse_y = 0}
  local attrs = {}
  for n, id in pairs(SKILL_IDS) do attrs[id] = {caption = F.CAPTION[n]} end
  local job_skill = {attrs = attrs}
  for n, id in pairs(SKILL_IDS) do job_skill[n] = id end
  _G.df = {global = {gps = gps}, job_skill = job_skill,
    viewscreen_choose_start_sitest = {is_instance = function(_, s) return s == scr and cs_screen() end},
    viewscreen_setupdwarfgamest = {is_instance = function(_, s) return s == scr and prep_screen() end}}
  _G.dfhack = {
    getDFPath = function() return tmp end,
    getTickCount = function() return D.ms end,
    filesystem = {mkdir_recursive = function(p) return luahost.mkdir_recursive(p) end},
    timeout = function(n, mode, cb) assert(mode == 'frames') timers[#timers + 1] = cb return #timers end,
    gui = {getDFViewscreen = function() return scr end, getFocusStrings = function() return D.source().focus() end},
    screen = {getWindowSize = function() lines = D.lines() return D.w, D.h end,
      readTile = function(x, y) return {ch = (lines or D.lines())[y + 1]:byte(x + 1)} end},
  }
  _G.qerror = function(m) error(m, 0) end
  package.loaded.gui = {simulateInput = function(s, keys)
    assert(s == scr)
    D.mouse = {gps.mouse_x, gps.mouse_y, gps.precise_mouse_x, gps.precise_mouse_y}
    D.env.sim(keys)
  end}
  local chunk = assert(loadfile(repo .. '/tools/embark/embark.lua'))
  local function cmd(...) return chunk(...) end
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
  return cmd, pump, writes, gps
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

T.test('entry: state reads the placing screen and evaluates the site', function()
  local D = F.new({screen = 'placing'})
  D.zoom = {8 * 16 + 11, 30 * 16 + 4}
  D.emb_min, D.region, D.popup = {8 * 16 + 6, 30 * 16 + 6}, {8, 30}, true  -- read with the popup open
  local cmd = install(D)
  local doc = json.decode(capture_print(function() cmd('state') end))
  T.eq(doc.kind, 'placing')
  T.eq(doc.world, {8, 30})
  T.eq(doc.rec.trees, 'woodland')
  T.eq(doc.verdict.verdict, 'review')  -- dark fortress unknown with the shipped rules.json
  T.eq(doc.cs.emb_min, {134, 486})
end)

T.test('entry: screen dump and capture file', function()
  local D = F.new({screen = 'title'})
  local cmd = install(D)
  local out = capture_print(function() cmd('screen') end)
  T.ok(out:find('Start new game in existing world', 1, true))
  capture_print(function() cmd('screen', 'title1') end)
  T.ok((slurp(OUT .. '/capture/title1.txt') or ''):find('focus title/Default', 1, true))
end)

local PREFS = tmp .. '/prefs/d_init.txt'
local function prefs(text)
  luahost.mkdir_recursive(tmp .. '/prefs')
  local f = assert(io.open(PREFS, 'wb'))
  f:write(text)
  f:close()
end

T.test('entry: scan refused unless the Confirm popup is always shown', function()
  local D = F.new({screen = 'world'})
  local cmd = install(D)
  luahost.mkdir_recursive(OUT)
  local spec = OUT .. '/spec-t0.json'
  local f = assert(io.open(spec, 'wb'))
  f:write(json.encode({v = 2, id = 't0', mode = 'scan', cands = {{8, 30}}}))
  f:close()
  prefs('[EMBARK_WARNING_ALWAYS:NO]\n')
  T.raises(function() capture_print(function() cmd('run', spec) end) end, 'Confirmation window')
  prefs('[EMBARK_WARNING_ALWAYS:YES]\n[POST_PREPARE_EMBARK_CONFIRMATION:IF_POINTS_REMAIN]\n')
end)

T.test('entry: run a scan through the frame loop; only UI-state writes', function()
  local D = F.new({screen = 'world'})
  local cmd, pump, writes = install(D)
  prefs('[EMBARK_WARNING_ALWAYS:YES]' .. string.char(10))
  local spec = OUT .. '/spec-t1.json'
  luahost.mkdir_recursive(OUT)
  local f = assert(io.open(spec, 'wb'))
  f:write(json.encode({v = 2, id = 't1', mode = 'scan', cands = {{8, 30}}}))
  f:close()
  capture_print(function() cmd('run', spec) end)
  local n = pump()
  T.ok(n > 100, 'frames ' .. n)
  local st = json.decode(slurp(OUT .. '/status.json'))
  T.eq(st.state, 'done', st.msg)
  T.eq(#st.results, 1)
  T.eq(st.results[1].emb, {134, 486})
  local res = json.decode(slurp(OUT .. '/result-t1.json'))
  T.eq(res.id, 't1')
  T.ok(slurp(OUT .. '/capture/t1-site-t1-1.txt') ~= nil, 'site dump written')
  local allowed = {region_cent_x = 1, region_cent_y = 1, zoom_cent_x = 1, zoom_cent_y = 1, selected_u = 1}
  for _, w in ipairs(writes) do T.ok(allowed[w], w) end
  T.ok(#writes >= 4)
end)

T.test('entry: a second run while one is active is refused; stop ends it', function()
  local D = F.new({screen = 'world'})
  local cmd, pump = install(D)
  prefs('[EMBARK_WARNING_ALWAYS:YES]' .. string.char(10))
  local spec = OUT .. '/spec-t2.json'
  local f = assert(io.open(spec, 'wb'))
  f:write(json.encode({v = 2, id = 't2', mode = 'scan', cands = {{8, 30}}}))
  f:close()
  capture_print(function() cmd('run', spec) end)
  pump(5)
  T.raises(function() capture_print(function() cmd('run', spec) end) end, 'is active')
  capture_print(function() cmd('stop') end)
  pump()
  T.eq(json.decode(slurp(OUT .. '/status.json')).state, 'stopped')
end)

-- remove the files written above
os.remove(PREFS)
for _, d in ipairs({OUT .. '/capture', OUT}) do
  for _, name in ipairs(luahost.listdir(d) or {}) do os.remove(d .. '/' .. name) end
end

T.done()
