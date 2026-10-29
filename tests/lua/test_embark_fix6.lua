-- fix6-embark-tools (Run 15 player reports): BUG-245 newgame --world-folder, BUG-246 intro popup, BUG-247 one-hold
-- placement and scan --hover, BUG-248 hard stone, BUG-250 embark --here, save-as, brook points. Fake DF screens.
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local json = require('dfllm.util.json')
local V = require('embark.view')
local P = require('embark.panel')
local C = require('embark.checklist')
local I = require('embark.input')
local R = require('embark.runner')
local S = require('embark.steps')
local F = require('embark.fixtures.fake_df')

local function slurp(p)
  local f = assert(io.open(p, 'rb'))
  local s = f:read('a')
  f:close()
  return s
end
local CFG = json.decode(slurp(repo .. '/tools/embark/ui.json'))
local RULES = json.decode(slurp(repo .. '/tools/embark/rules.json'))
local LOADOUT = json.decode(slurp(repo .. '/tools/embark/loadout.json'))
local far_df = {{name = 'far', w = {0, 0}}}
local function rules_far()
  local r = {}
  for k, v in pairs(RULES) do r[k] = v end
  r.dark_fortresses_seen = far_df
  return r
end
local function has(list, x)
  for _, v in ipairs(list or {}) do if v == x then return true end end
  return false
end
local function item(r, id) for _, it in ipairs(r.items) do if it.id == id then return it end end end

local function start(D, spec, rules)
  local steps = S.build(spec, CFG, LOADOUT)
  local docs = {}
  local env = {capture = D.capture, now = D.env.now, ui = I.new(D.env, CFG), w = D.w_api,
    status = function(doc) docs[#docs + 1] = json.decode(json.encode(doc)) end}
  local ctx = {spec = spec, rules = rules or RULES, caption = function(n) return F.CAPTION[n] or n end,
    results = {}, warnings = {}}
  local run = R.new(spec.id, steps, env, ctx, CFG)
  F.play(D, run)
  return run, docs, ctx
end
local function logtxt(run) return table.concat(run.log, ' | ') end

-- extra buttons on one screen of the fake (the fake's own buttons stay, `drop` filters them)
local function extend(D, screen, fn, drop)
  local orig = D.buttons
  D.buttons = function()
    local b = orig()
    if D.screen ~= screen then return b end
    if drop then
      local kept = {}
      for _, x in ipairs(b) do if not drop(x) then kept[#kept + 1] = x end end
      b = kept
    end
    local function add(x, y, t, f) b[#b + 1] = {x, y, t, f} end
    fn(add)
    return b
  end
end

---------------------------------------------------------------- BUG-245
local function three_worlds(D)
  -- Run 15c/15d: three "World: Zilirr?th", region2 (AppData), region1 (portable), region1 (AppData)
  local rows = {{'region2', false}, {'region1', true}, {'region1', false}}
  extend(D, 'worlds', function(add)
    for i, r in ipairs(rows) do
      local pick = function() D.picked = r[1] .. (r[2] and '/portable' or '/appdata'); D.screen = 'gametype'; D.frames = 0 end
      add(60, 20 + 3 * (i - 1), 'World: Zilirr?th', pick)
      add(62, 21 + 3 * (i - 1), (r[2] and 'Portable Folder: ' or 'Folder: ') .. r[1], pick)
    end
  end, function(x) return x[3] == 'Zilirr?th' end)
end

T.test('BUG-245: newgame --world-folder clicks the folder row of the right same-named world', function()
  local D = F.new()
  three_worlds(D)
  local run, docs = start(D, {v = 2, id = 'ng1', mode = 'newgame', world = 'Zilirr', world_folder = 'region1',
    portable = true})
  T.eq(run.state, 'done', run.msg .. ' / ' .. logtxt(run))
  T.eq(D.picked, 'region1/portable', 'not the topmost world (region2)')
  T.eq(D.screen, 'world')
  T.eq(docs[#docs].results.world_row.text, 'Portable Folder: region1')
  D = F.new()
  three_worlds(D)
  run = start(D, {v = 2, id = 'ng2', mode = 'newgame', world = 'Zilirr', world_folder = 'region1', portable = false})
  T.eq({run.state, D.picked}, {'done', 'region1/appdata'})
  D = F.new()
  three_worlds(D)
  run = start(D, {v = 2, id = 'ng3', mode = 'newgame', world = 'Zilirr', world_folder = 'region1'})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('2 rows show the folder "region1"', 1, true), run.msg)
  T.ok(run.msg:find('--portable or --appdata', 1, true), run.msg); T.eq(D.picked, nil, 'nothing clicked')
  D = F.new()
  three_worlds(D)
  run = start(D, {v = 2, id = 'ng4', mode = 'newgame', world = 'Zilirr', world_folder = 'region7'})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('no row shows "Folder: region7"', 1, true), run.msg)
end)

T.test('BUG-245: folder rows are whole words; region_choice must hold the folder of that kind', function()
  local v = V.from_lines({'  World: Zilirr?th', '   Folder: region10', '  World: Zilirr?th',
    '   Portable Folder: region1', '   folder: REGION1'})
  local r = S.folder_rows(v, 'region1')
  T.eq(#r, 2)
  T.eq({r[1].portable, r[1].text, r[1].y, r[1].x}, {true, 'Portable Folder: region1', 3, 3})
  T.eq({r[2].portable, r[2].text}, {false, 'folder: REGION1'})
  T.eq(S.pick_folder(v, 'region1', true).y, 3)
  T.eq(#S.folder_rows(v, 'region10'), 1)
  local title = {regions = {{path = 'C:/Users/x/AppData/Roaming/Bay 12 Games/Dwarf Fortress/save/region2', portable = false},
    {path = 'E:/DF/save/region1', portable = true}}}
  T.eq(S.region_check(title, 'region1', true), nil)
  T.ok(S.region_check(title, 'region1', false):find('no world folder "region1" (appdata): region2 (appdata), ' ..
    'region1 (portable)', 1, true), S.region_check(title, 'region1', false))
  T.eq(S.region_check(nil, 'x'), nil, 'no region_choice shown: the rows decide')
end)

---------------------------------------------------------------- BUG-246
T.test('BUG-246: --play-now clicks Okay on the late "A Dwarven Outpost" intro (no "Strike the earth" shown)', function()
  local D = F.new({screen = 'world', sites = {['8,30'] = {neighbors = F.NEIGHBORS_FAR}}})
  extend(D, 'fort', function(add)
    D.fort_t = D.fort_t or D.ms
    if D.intro_closed or D.ms - D.fort_t < 2000 then return end   -- drawn about 2 s after the fort
    add(40, 20, 'A Dwarven Outpost')
    add(40, 22, 'Your seven dwarves have arrived.')
    add(60, 46, 'Okay', function() D.intro_closed = true end)
  end)
  local run, _, ctx = start(D, {v = 2, id = 'pn', mode = 'embark', site = {8, 30}, play_now = true}, rules_far())
  T.eq(run.state, 'done', run.msg .. ' / ' .. logtxt(run))
  T.eq(D.intro_closed, true, 'intro popup closed: ' .. logtxt(run))
  T.eq(D.pressed.Okay, 1)
  T.ok(logtxt(run):find('Dwarven Outpost', 1, true), logtxt(run))
  T.eq(ctx.warnings, {})
  -- no popup at all: the step ends after its polls, nothing clicked
  D = F.new({screen = 'world', sites = {['8,30'] = {neighbors = F.NEIGHBORS_FAR}}})
  run = start(D, {v = 2, id = 'pn2', mode = 'embark', site = {8, 30}, play_now = true}, rules_far())
  T.eq(run.state, 'done', run.msg); T.eq(D.pressed.Okay, nil)
  T.ok(logtxt(run):find('fort.intro: no intro popup', 1, true), logtxt(run))
end)

---------------------------------------------------------------- BUG-247
-- Run 15d (i4, 174x75 tiles, rectangle corner = camera - (23,12)): the rectangle follows the mouse only on the first
-- read after a camera change; the old loop moved the held pixel instead of the camera, the rectangle stayed and the
-- pixels ran negative
local function i4(D)
  D.w, D.h, D.k = 174, 75, {-23, -12}
  local orig = D.rect
  local zkey, frozen = nil, nil
  D.rect = function()
    if D.screen == 'placing' and not D.popup then
      local z = D.zoom[1] .. ',' .. D.zoom[2]
      if z ~= zkey or not frozen then zkey = z; frozen = {orig()} end
      return frozen[1], frozen[2], frozen[3]
    end
    zkey, frozen = nil, nil
    return orig()
  end
end

T.test('BUG-247: one fixed held pixel, the camera moves; a rectangle that follows only camera changes is placed', function()
  local D = F.new({screen = 'world', sites = {['8,30'] = {neighbors = F.NEIGHBORS_FAR}}})
  i4(D)
  local held = {}
  local mouse = D.env.mouse
  D.env.mouse = function(tx, ty, px, py, focus) if focus then held[px .. ',' .. py] = true end mouse(tx, ty, px, py, focus) end
  local run, _, ctx = start(D, {v = 2, id = 'p1', mode = 'scan', cands = {{8, 30}}}, rules_far())
  T.eq(run.state, 'done', run.msg .. ' / ' .. logtxt(run))
  T.eq(ctx.results[1].emb, {8 * 16 + 6, 30 * 16 + 6})
  T.eq(ctx.pk, {-23, -12}, 'the offset measured once')
  local n = 0
  for k in pairs(held) do
    n = n + 1
    local x, y = k:match('^(%-?%d+),(%-?%d+)$')
    T.ok(tonumber(x) >= 0 and tonumber(y) >= 0, 'held pixel in the window: ' .. k)
  end
  T.eq(n, 1, 'one held pixel for the whole run')
end)

T.test('BUG-247: a second confirmed miss after the measured offset fails at once (no endless loop)', function()
  local D = F.new({screen = 'world'})
  i4(D)
  local orig = D.rect
  local zs, changes = nil, 0
  D.rect = function()   -- every camera change lands 3 tiles further off: k measured once cannot fix it
    local m, x, r = orig()
    if m and D.screen == 'placing' and not D.popup then
      local z = D.zoom[1] .. ',' .. D.zoom[2]
      if z ~= zs then zs, changes = z, changes + 1 end
      return {m[1] + 3 * changes, m[2]}, x, r
    end
    return m, x, r
  end
  local run = start(D, {v = 2, id = 'p2', mode = 'scan', cands = {{8, 30}}}, rules_far())
  T.eq(run.state, 'failed', run.msg)
  T.ok(run.msg:find('rectangle does not follow the mouse: held', 1, true), run.msg)
  T.ok(run.msg:find('--hover', 1, true), 'names the hover scan: ' .. run.msg)
  T.ok(run.tries <= 8, run.tries)
end)

-- hover scan: the rectangle never follows (fixed far away), the panel follows the hovered tile
local function hover_fake(tiles)
  local D = F.new({screen = 'world', follow = false})
  D.emb_min, D.region = {224, 132}, {14, 8}
  local kh = {0, 0}
  extend(D, 'placing', function(add)
    if D.popup then return end
    local cx, cy = D.w * D.tpx // 2, D.h * D.tpy // 2
    local t = {D.zoom[1] + kh[1] + (D.mouse[3] - cx) // 16, D.zoom[2] + kh[2] + (D.mouse[4] - cy) // 16}
    D.hovered = t
    local lines = tiles[t[1] .. ',' .. t[2]] or tiles.default
    for i, l in ipairs(lines) do if l ~= '' then add(125, 1 + i, l) end end
  end, function(x) return x[1] == 125 end)
  return D
end
local NOBROOK = {'Temperate Broadleaf Forest', 'Temperature: Temperate', 'Trees: Woodland', 'Surroundings: Calm',
  'Little soil', 'Iron', '', 'Neighbors:', 'Goblins', "Nearest site: 9 days' travel"}
local BROOK = {'Temperate Grassland', 'Temperature: Temperate', 'Trees: Sparse', 'Surroundings: Calm', 'Brook: Yes',
  'Deep soil', '', 'Neighbors:', 'Goblins', "Nearest site: 9 days' travel"}

T.test('BUG-247: scan --hover reads 16 hovered panels per site without any rectangle and merges them', function()
  local ex, ey = 8 * 16 + 6, 30 * 16 + 6
  local D = hover_fake({default = NOBROOK, [(ex + 3) .. ',' .. (ey + 1)] = BROOK})
  local run, docs, ctx = start(D, {v = 2, id = 'h1', mode = 'scan', hover = true, cands = {{8, 30}}}, rules_far())
  T.eq(run.state, 'done', run.msg .. ' / ' .. logtxt(run))
  local r = ctx.results[1]
  T.eq({r.hover, r.world, r.emb, r.size}, {true, {8, 30}, {ex, ey}, nil})
  T.eq(r.rec.tiles.n, 16, logtxt(run))
  T.eq(r.rec.water, 'brook', 'the brook of one hovered tile')
  T.eq(r.rec.tiles.water_at, {{ex + 3, ey + 1}})
  T.eq(r.rec.stone_soil, 'little')
  T.eq(#r.parts, 16); T.eq(r.parts[1].at, {ex, ey})
  T.eq(D.pressed.Confirm, nil); T.eq(ctx.pk, nil, 'no rectangle offset needed')
  T.eq(#docs[#docs].results[1].parts, 16, 'the parts reach status.json (embark --here)')
  local ids = {}
  for _, st in ipairs(S.build({id = 'h', mode = 'scan', hover = true, cands = {{1, 2}}}, CFG, LOADOUT)) do ids[#ids + 1] = st.id end
  T.eq({ids[1], ids[2], ids[3], ids[18], ids[19], #ids}, {'world.goto', 'local.embark', 'site.hover.1', 'site.hover.16',
    'site.hover.read', 19})
end)

---------------------------------------------------------------- BUG-248
T.test('BUG-248: stone fails when the soil above it is deeper than hard_stone_levels', function()
  local good = P.parse(V.from_lines((function()
    local out = {}
    for _, l in ipairs(F.GOOD) do out[#out + 1] = string.rep(' ', 40) .. l end
    return out
  end)(), {focus = {'choose_start_site'}}))
  good.soil = 'some'
  local ctx = {world = {8, 30}, size = {4, 4}}
  local r = C.evaluate(good, {dark_fortresses_seen = far_df}, ctx)
  T.eq(item(r, 'stone').res, 'pass', 'some soil (about 3 levels) within the shipped 6')
  r = C.evaluate(good, {dark_fortresses_seen = far_df, hard_stone_levels = 2}, ctx)
  T.eq(item(r, 'stone').res, 'fail')
  T.ok(item(r, 'stone').why:find('about 3 levels of soil, hard stone wanted within 2', 1, true), item(r, 'stone').why)
  good.soil = 'deep'
  r = C.evaluate(good, rules_far(), ctx)
  T.ok(item(r, 'stone').why:find('about 8 levels', 1, true), item(r, 'stone').why)
  T.eq(C.soil_levels('very_deep', RULES), 15); T.eq(C.soil_levels(nil, RULES), nil)
  T.eq(RULES.hard_stone_levels, 6)
end)

T.test('BUG-248: waiving or accepting stone needs an explore-first plan at the gate', function()
  local deep = {['8,30'] = {neighbors = F.NEIGHBORS_FAR, panel = {'Temperate Broadleaf Forest', 'Temperature: Temperate',
    'Trees: Woodland', 'Surroundings: Calm', 'Brook: Yes', 'Deep soil', 'Iron'}}}
  local D = F.new({screen = 'world', sites = deep})
  local run = start(D, {v = 2, id = 'g1', mode = 'embark', site = {8, 30}, play_now = true,
    accept = {{id = 'stone', why = 'deep soil, we dig'}}}, rules_far())
  T.eq(run.state, 'failed'); T.ok(run.msg:find('accepting stone needs an explore-first plan', 1, true), run.msg)
  T.eq(D.pressed.Confirm, nil)
  D = F.new({screen = 'world', sites = deep})
  local ctx
  run, _, ctx = start(D, {v = 2, id = 'g2', mode = 'embark', site = {8, 30}, play_now = true,
    accept = {{id = 'stone', why = 'deep soil, we dig'}}, explore_first = 'explore shaft to the first stone in spring'},
    rules_far())
  T.eq(run.state, 'done', run.msg); T.eq(D.screen, 'fort')
  T.ok(has(ctx.warnings, 'site.gate: explore first (explore shaft to the first stone in spring)'), json.encode(ctx.warnings))
  T.ok(C.NEEDS_PLAN.stone ~= nil)
end)

---------------------------------------------------------------- BUG-250: embark --here
local function placed_popup(m)
  local D = F.new({screen = 'placing', follow = false, sites = {[(m[1] // 16) .. ',' .. (m[2] // 16)] = {
    popup = {'You have selected an area with a light', 'aquifer.'}}}})
  D.emb_min, D.region, D.popup, D.zoom = {m[1], m[2]}, {m[1] // 16, m[2] // 16}, true, {m[1] + 2, m[2] + 2}
  return D
end
local function hover_rows(ex, ey)
  local parts = {}
  for dy = 0, 3 do
    for dx = 0, 3 do
      local rec = P.parse(V.from_lines((function()
        local out = {}
        for _, l in ipairs(NOBROOK) do out[#out + 1] = string.rep(' ', 40) .. l end
        if dx == 2 and dy == 2 then out[#out + 1] = string.rep(' ', 40) .. 'Brook: Yes' end
        return out
      end)(), {focus = {'choose_start_site'}}))
      rec.at = {ex + dx, ey + dy}
      parts[#parts + 1] = rec
    end
  end
  return {{tag = 'h1-1', emb = {ex, ey}, hover = true, rec = S.copy(parts[1]), parts = parts}}
end

T.test('BUG-250: embark --here gates the rectangle on the screen on the panels read before, then confirms it', function()
  local m = {8 * 16 + 7, 30 * 16 + 5}               -- placed by hand, one tile off the hover grid
  local prior = hover_rows(8 * 16 + 6, 30 * 16 + 4)
  local D = placed_popup(m)
  local run, _, ctx = start(D, {v = 2, id = 'here1', mode = 'here', prior = json.decode(json.encode(prior)),
    play_now = true}, rules_far())
  T.eq(run.state, 'done', run.msg .. ' / ' .. logtxt(run))
  T.eq(D.screen, 'fort'); T.eq(D.pressed.Confirm, 1)
  local r = ctx.results[1]
  T.eq({r.emb, r.size, r.verdict}, {m, {4, 4}, 'ok'})
  T.eq(r.rec.water, 'brook', 'the brook tile 8*16+8,30*16+6 lies inside the placed rectangle')
  T.eq(r.rec.aquifer, 'light', 'the popup warning merged in')
  T.ok(has(ctx.warnings, 'site.here: 9 of 16 tiles of the rectangle were hovered'), json.encode(ctx.warnings))
end)

T.test('BUG-250: embark --here refuses without a popup, without earlier panels, and gates a failure', function()
  local m = {8 * 16 + 7, 30 * 16 + 5}
  local D = placed_popup(m)
  D.popup = false
  local run = start(D, {v = 2, id = 'here2', mode = 'here', prior = hover_rows(m[1], m[2]), play_now = true}, rules_far())
  T.eq(run.state, 'failed'); T.ok(run.msg:find('no Confirm popup', 1, true), run.msg)
  D = placed_popup(m)
  run = start(D, {v = 2, id = 'here3', mode = 'here', prior = hover_rows(20 * 16, 20 * 16), play_now = true}, rules_far())
  T.eq(run.state, 'failed'); T.ok(run.msg:find('no panel read for the rectangle', 1, true), run.msg)
  T.ok(run.msg:find('scan 8,30 --hover', 1, true), run.msg); T.eq(D.pressed.Confirm, nil)
  D = placed_popup(m)
  local strict = rules_far()
  strict.hard_stone_levels = 0          -- little soil (about 1 level) fails stone
  run = start(D, {v = 2, id = 'here4', mode = 'here', prior = hover_rows(m[1], m[2]), play_now = true}, strict)
  T.eq(run.state, 'failed'); T.ok(run.msg:find('site.gate:', 1, true), run.msg); T.eq(D.pressed.Confirm, nil)
  local pick = S.here_rec(hover_rows(m[1], m[2]), m, {m[1] + 3, m[2] + 3})
  T.eq({#pick.parts, pick.exact}, {16, false})
end)

---------------------------------------------------------------- BUG-250: save-as
local function fort_menu(D)
  D.screen, D.field, D.save_path = 'fort', 'region1-spr-0050', 'E:/DF/save/region1'
  extend(D, 'fort', function(add)
    if D.menu then add(60, 20, 'Save and continue playing', function() D.menu, D.prompt = false, true end) end
    if D.prompt then add(40, 20, 'Name: ' .. D.field) end
  end)
  local sim = D.env.sim
  D.env.sim = function(keys)
    if type(keys) == 'string' and D.prompt then
      local code = keys:match('^STRING_A(%d%d%d)$')
      if code then
        code = tonumber(code)
        D.field = code == 0 and D.field:sub(1, -2) or (D.field .. string.char(code))
        return
      end
      if keys == 'SELECT' then D.prompt, D.saving = false, D.ms; return end
    end
    return sim(keys)
  end
  local tick = D.tick
  D.tick = function()
    tick()
    if D.esc_at and D.ms >= D.esc_at and not D.menu_seen then D.menu, D.menu_seen = true, true end   -- Esc pressed
    if D.saving and D.ms - D.saving > 3000 then D.save_path, D.saving = 'E:/DF/save/' .. D.field, nil end
  end
  local source = D.source
  D.source = function()
    local s = source()
    s.save_path = function() return D.save_path end
    return s
  end
end

T.test('BUG-250: save-as waits for the Esc menu, types the name key by key, SELECT, ends on the new save path', function()
  local D = F.new()
  fort_menu(D)
  D.esc_at = 3000
  local run = start(D, {v = 2, id = 'sv1', mode = 'saveas', name = 'r15-test'})
  T.eq(run.state, 'done', run.msg .. ' / ' .. logtxt(run))
  T.eq(D.save_path, 'E:/DF/save/r15-test')
  T.ok(logtxt(run):find('fort.menu: Esc menu not open', 1, true), 'the log line embark.py posts Esc on')
  T.eq(D.pressed['Save and continue playing'], 1)
  -- the menu already open: no wait; the log says so (embark.py posts nothing)
  D = F.new()
  fort_menu(D)
  D.menu = true
  run = start(D, {v = 2, id = 'sv2', mode = 'saveas', name = 'r15b'})
  T.eq(run.state, 'done', run.msg); T.ok(logtxt(run):find('fort.menu: Esc menu open', 1, true), logtxt(run))
  T.eq(D.save_path, 'E:/DF/save/r15b')
  T.raises(function() S.build({id = 'x', mode = 'saveas', name = '../x'}, CFG, LOADOUT) end, 'saveas')
  T.ok(S.save_named({save_path = 'E:\\DF\\save\\r15b'}, 'r15b')); T.ok(not S.save_named({save_path = 'E:/DF/save/xr15b'}, 'r15b'))
end)

T.test('BUG-250: save-as fails when the field does not show the typed name (typing lost)', function()
  local D = F.new()
  fort_menu(D)
  D.menu = true
  local sim = D.env.sim
  D.env.sim = function(keys) if type(keys) == 'string' and keys:match('^STRING_A') then return end return sim(keys) end
  local run = start(D, {v = 2, id = 'sv3', mode = 'saveas', name = 'r15c'})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('does not show "r15c"', 1, true), run.msg)
  T.eq(D.save_path, 'E:/DF/save/region1', 'nothing saved')
end)

T.done()
