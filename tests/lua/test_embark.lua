-- WP11: tools/embark (view, panel, checklist, input, runner + steps on a fake DF).
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

local function fixture(name, cs)
  local lines, focus = V.parse_dump(slurp(repo .. '/tools/embark/fixtures/' .. name .. '.txt'))
  return V.from_lines(lines, {focus = focus, cs = cs})
end
local function has(list, x)
  for _, v in ipairs(list) do if v == x then return true end end
  return false
end
local far_df = {{name = 'far', w = {0, 0}}}
local cs_placing = {zoomed_in = true, choosing_embark = true, emb_min = {8 * 16 + 6, 30 * 16 + 6},
  emb_max = {8 * 16 + 9, 30 * 16 + 9}}

---------------------------------------------------------------- view
T.test('view: char map, cells, paragraphs, find', function()
  T.eq(V.char(65), 'A'); T.eq(V.char(0), ' '); T.eq(V.char(196), ' '); T.eq(V.char(130), '?')
  local v = V.from_lines({'  Trees: Woodland    Abort', '  aquifer.', '      Confirm'})
  local c = v:cells()
  T.eq(#c, 4)
  T.eq(c[1], {x = 2, y = 0, text = 'Trees: Woodland'})
  T.eq(c[2].text, 'Abort'); T.eq(c[2].x, 21)
  local p = v:paras()
  T.eq(p[1].norm, 'trees: woodland aquifer.')
  T.eq({v:find('Abort')}, {21, 0})
  T.eq({v:find('o', 2)}, {11, 0})
  T.eq({v:find('Confirm', 1, true)}, {6, 2})
  T.ok(not v:find('nope'))
end)

T.test('view: dump round trip and kind()', function()
  local v = V.from_lines({'', '  Start new game in existing world'}, {focus = {'title/Default'}})
  local lines, focus = V.parse_dump(v:dump())
  T.eq(lines, {'', '  Start new game in existing world'})
  T.eq(focus, {'title/Default'})
  local k = function(f, cs) return V.from_lines({}, {focus = {f}, cs = cs}):kind() end
  T.eq(k('title/Default'), 'title')
  T.eq(k('choose_start_site', {}), 'world')
  T.eq(k('choose_start_site', {zoomed_in = true}), 'local')
  T.eq(k('choose_start_site', {zoomed_in = true, choosing_embark = true}), 'placing')
  T.eq(k('choose_start_site/SiteFinder', {}), 'finder')
  T.eq(k('choose_start_site/ChooseCiv', {}), 'civ')
  T.eq(k('setupdwarfgame/Default'), 'prep_default')
  T.eq(k('setupdwarfgame/Dwarves'), 'prep_dwarves')
  T.eq(k('dwarfmode/Default'), 'fort')
end)

---------------------------------------------------------------- panel
T.test('panel: good site', function()
  local r = P.parse(fixture('site_good_panel'))
  T.eq(r.temperature, 'temperate'); T.eq(r.trees, 'woodland'); T.eq(r.vegetation, 'moderate')
  T.eq(r.surroundings, 'calm'); T.eq(r.evil, 'neutral'); T.eq(r.savagery, 'low')
  T.eq(r.water, 'brook'); T.eq(r.soil, 'little'); T.eq(r.flux, true); T.eq(r.aquifer, 'none')
  T.eq(r.metals, {'iron', 'copper', 'tin'}); T.eq(r.warnings, {})
  T.ok(r.read >= 7)
end)

T.test('panel: wrapped light-aquifer popup and panel line', function()
  local r = P.parse(fixture('site_aquifer_popup'))
  T.eq(r.aquifer, 'light'); T.eq(r.soil, 'very_deep'); T.eq(r.water, 'river'); T.eq(r.trees, 'sparse')
  T.ok(has(r.warnings, 'light_aquifer'), T.show(r.warnings))
  T.ok(not has(r.warnings, 'heavy_aquifer'))
end)

T.test('panel: evil popup, no river', function()
  local r = P.parse(fixture('site_evil_popup'))
  T.eq(r.evil, 'evil'); T.eq(r.savagery, 'medium'); T.eq(r.temperature, 'cold'); T.eq(r.water, nil)
  T.ok(has(r.warnings, 'evil')); T.ok(has(r.warnings, 'unpleasant'))
end)

T.test('panel: neighbors and travel ranks', function()
  local r = P.parse(fixture('neighbors'))
  T.eq(#r.neighbors, 3)
  T.eq(r.neighbors[1], {race = 'goblins', travel = "a day's travel population: ~3000", rank = 4})
  T.eq(r.neighbors[2].race, 'elves'); T.eq(r.neighbors[2].rank, 5)
  T.eq(r.neighbors[3].race, 'humans'); T.eq(r.neighbors[3].rank, 7)
  T.eq(P.travel_rank("A half day's travel"), 2)
  T.eq(P.travel_rank("Nearly a day's travel"), 3)
  T.eq(P.travel_rank('Inaccessible from your location'), 99)
  T.eq(r.read, 0, 'the Neighbors section alone is not the biome panel')
  T.eq(r.neighbors_shown, true, '"Neighbors:" header')
end)

T.test('panel: one capture with the popup open has popup, panel and Neighbors', function()
  local r = P.parse(fixture('site_good_popup'))
  T.eq(r.trees, 'woodland'); T.eq(r.water, 'brook'); T.eq(r.warnings, {}); T.eq(r.neighbors_shown, true)
  T.eq(#r.neighbors, 2); T.eq(r.neighbors[1].race, 'humans')
  T.eq(r.neighbors[2], {race = 'goblins', travel = "9 days' travel", rank = 13})
  local v = C.evaluate(r, RULES, {world = {8, 30}, size = {4, 4}})
  T.eq(v.verdict, 'ok', T.show(v.unknown))  -- shipped rules: no dark_fortresses_seen, no waiver needed
end)

T.test('panel: live L0 captures (DF 53.16, 171x66): hovered-tile panel, popup, goblin pits', function()
  local r = P.parse(fixture('live/l0_panel_woodland'))
  T.eq(r.trees, 'woodland'); T.eq(r.surroundings, 'mirthful'); T.eq(r.evil, 'good'); T.eq(r.savagery, 'medium')
  T.eq(r.temperature, 'temperate'); T.eq(r.soil, 'very_deep'); T.eq(r.aquifer, 'none'); T.eq(r.water, nil)
  T.eq(r.neighbors_shown, true); T.eq(#r.neighbors, 2)
  T.eq(r.neighbors[1], {race = 'elves', travel = "1/2 day's travel west", rank = 2})
  T.eq(r.neighbors[2].race, 'humans'); T.eq(r.neighbors[2].rank, 6)
  local pop = P.parse(fixture('live/l0_popup_light_aquifer'))
  T.eq(pop.read, 0); T.eq(pop.warnings, {'light_aquifer'})
  local m = S.merge_popup(r, pop)
  T.eq(m.aquifer, 'light')
  local g = P.parse(fixture('live/l0_panel_goblin_pits'))
  T.ok(has(g.warnings, 'cannot'), 'Cannot embark on another site.')
  T.eq(g.water, 'stream'); T.eq(g.temperature, 'hot')
  local gob
  for _, n in ipairs(g.neighbors) do if n.race == 'goblins' then gob = n end end
  T.eq(gob.rank, 0, '"Nearest site: Here"')
  T.eq(C.evaluate(g, RULES, {world = {2, 27}, size = {4, 4}}).verdict, 'reject')
end)

T.test('panel: nothing readable', function()
  local r = P.parse(fixture('title'))
  T.eq(r.read, 0); T.eq(r.aquifer, nil); T.eq(r.soil, nil)
end)

---------------------------------------------------------------- checklist
local function eval(name, rules, ctx)
  rules = rules or {}
  for k, v in pairs(RULES) do if rules[k] == nil then rules[k] = v end end
  return C.evaluate(P.parse(fixture(name)), rules, ctx or {world = {8, 30}, size = {4, 4}})
end

T.test('checklist: good site is ok only with dark-fortress evidence', function()
  local r = eval('site_good_panel')
  T.eq(r.verdict, 'review'); T.eq(r.unknown, {'dark_fortress'}); T.eq(r.fails, {})
  r = eval('site_good_panel', {dark_fortresses_seen = far_df})
  T.eq(r.verdict, 'ok'); T.eq(r.score, 100); T.eq(r.warns, {})
end)

T.test('checklist: light aquifer warns; very deep soil (no stone) and no metal reject; evil rejects', function()
  local r = eval('site_aquifer_popup', {dark_fortresses_seen = far_df})
  T.eq(r.verdict, 'reject')
  T.eq(r.fails, {'ore', 'stone'})
  T.ok(has(r.warns, 'aquifer') and has(r.warns, 'soil') and has(r.warns, 'trees') and has(r.warns, 'popup'))
  T.ok(r.score < 60)
  r = eval('site_evil_popup', {dark_fortresses_seen = far_df})
  T.eq(r.verdict, 'reject')
  for _, id in ipairs({'evil', 'trees', 'water', 'popup'}) do T.ok(has(r.fails, id), id) end
end)

local function item(r, id) for _, it in ipairs(r.items) do if it.id == id then return it end end end
local function ev_rec(rec) return C.evaluate(rec, {dark_fortresses_seen = far_df}, {world = {8, 30}, size = {4, 4}}) end

T.test('checklist (live L6, Run 9 lesson 1): no hard stone layer within reach rejects (deep soil, popup)', function()
  local r = eval('site_aquifer_popup', {dark_fortresses_seen = far_df})   -- very deep soil + light aquifer
  T.ok(has(r.fails, 'stone'))
  T.ok(item(r, 'stone').why:find('below the aquifer', 1, true), item(r, 'stone').why)
  r = eval('site_good_panel', {dark_fortresses_seen = far_df})            -- little soil
  T.eq(item(r, 'stone').res, 'pass'); T.ok(not has(r.fails, 'stone'))
  local rec = P.parse(fixture('site_good_panel'))
  rec.soil, rec.aquifer = 'deep', 'none'
  r = ev_rec(rec)
  T.eq(item(r, 'stone').res, 'fail'); T.ok(item(r, 'stone').why:find('boulders scarce', 1, true))
  T.eq(r.verdict, 'reject')
  rec.stone_soil = 'little'                                               -- another hovered tile: little soil
  T.eq(item(ev_rec(rec), 'stone').res, 'pass')
  rec.stone_soil, rec.soil = nil, nil
  T.eq(item(ev_rec(rec), 'stone').res, 'unknown', 'soil depth not shown')
  rec.layers = {'granite'}
  T.eq({item(ev_rec(rec), 'stone').res, item(ev_rec(rec), 'stone').why}, {'pass', 'stone layers granite'})
  rec.soil, rec.warnings = 'little', {'no_stone'}
  r = ev_rec(rec)
  T.eq({item(r, 'stone').res, item(r, 'stone').why}, {'fail', 'popup: difficult to obtain stone'})
  T.ok(not has(r.fails, 'popup'), 'the no-stone popup is the stone rule, not a blanket popup fail')
end)

T.test('checklist (Run 9 lesson 1): a metal ore must be listed; iron passes, other metals warn', function()
  local rec = P.parse(fixture('site_good_panel'))
  T.eq(item(ev_rec(rec), 'ore').res, 'pass')
  rec.metals = {'copper', 'tin'}
  T.eq({item(ev_rec(rec), 'ore').res, item(ev_rec(rec), 'ore').why}, {'warn', 'bronze only (copper, tin)'})
  rec.metals = {'gold'}
  T.eq({item(ev_rec(rec), 'ore').res, item(ev_rec(rec), 'ore').why}, {'warn', 'no iron (gold)'})
  rec.metals = nil
  local r = ev_rec(rec)
  T.eq({item(r, 'ore').res, item(r, 'ore').why, r.verdict}, {'fail', 'no metal ore shown', 'reject'})
  T.eq(item(C.evaluate(P.parse(fixture('title')), RULES, {}), 'ore').res, 'unknown', 'panel not read')
  for _, id in ipairs({'ore', 'stone'}) do T.ok(C.ACCEPTABLE_SET[id] and C.WAIVABLE_SET[id], id) end
  T.ok(not C.ACCEPTABLE_SET.panel and not C.ACCEPTABLE_SET.popup, 'never the panel or a failing popup')
end)

T.test('panel: stone layer lines (the embark screen\'s layer list) are read as layers, soils are not', function()
  local pad = string.rep(' ', 40)
  local v = V.from_lines({pad .. 'Little soil', pad .. 'Granite, Limestone layers', pad .. 'Rock salt', pad .. 'Clay'},
                         {focus = {'choose_start_site'}})
  local r = P.parse(v)
  T.eq(r.layers, {'granite', 'limestone', 'rock salt'})
  T.eq(r.soil, 'little')
end)

T.test('checklist: distances, size, heavy aquifer, unreadable panel', function()
  local rec = P.parse(fixture('site_good_panel'))
  local r = C.evaluate(rec, RULES, {world = {25, 11}, size = {4, 4}})
  T.ok(has(r.fails, 'old_sites'), 'Windrings 1 tile away')
  r = C.evaluate(rec, {dark_fortresses_seen = {{name = 'Stolenshoved', w = {12, 30}}}}, {world = {8, 30}, size = {5, 5}})
  T.ok(has(r.fails, 'dark_fortress')); T.ok(has(r.fails, 'size'))
  rec.neighbors = {{race = 'goblins', travel = "a day's travel", rank = 4}}
  r = C.evaluate(rec, {dark_fortresses_seen = far_df}, {world = {8, 30}, size = {3, 3}})
  T.ok(has(r.fails, 'dark_fortress'), 'near goblins in Neighbors')
  rec.neighbors, rec.aquifer = {}, 'heavy'
  T.eq(C.evaluate(rec, {dark_fortresses_seen = far_df}, {world = {8, 30}, size = {4, 4}}).verdict, 'reject')
  r = C.evaluate(P.parse(fixture('title')), RULES, {})
  T.eq(r.verdict, 'reject'); T.ok(has(r.fails, 'panel'))
end)

T.test('checklist: Neighbors header without parsed entries stays unknown', function()
  local rec = P.parse(fixture('site_good_panel'))
  rec.neighbors_shown = true
  local r = C.evaluate(rec, RULES, {world = {8, 30}, size = {4, 4}})
  T.eq(r.unknown, {'dark_fortress'})
  for _, it in ipairs(r.items) do
    if it.id == 'dark_fortress' then T.eq(it.why, 'Neighbors shown but no entry parsed') end
  end
  for _, id in ipairs(r.unknown) do T.ok(C.WAIVABLE_SET[id], id) end
end)

T.test('checklist: rank orders ok > review > reject, then score', function()
  local rows = {{verdict = {verdict = 'reject', score = 90}}, {verdict = {verdict = 'ok', score = 50}},
    {verdict = {verdict = 'review', score = 99}}, {verdict = {verdict = 'ok', score = 80}}}
  C.rank(rows)
  T.eq({rows[1].verdict.score, rows[2].verdict.score, rows[3].verdict.verdict, rows[4].verdict.verdict},
    {80, 50, 'review', 'reject'})
end)

---------------------------------------------------------------- input queue
T.test('input: hover, one press, hold; keys; pct', function()
  local t, log, mouse = 0, {}, nil
  local q = I.new({now = function() return t end, mouse = function(...) mouse = {...} end,
    sim = function(k) log[#log + 1] = k end, tile_px = function() return 10, 15 end,
    win = function() return 100, 60 end}, {hover_ms = 100, after_ms = 50})
  q:click_tile(3, 4)
  q:key('LEAVESCREEN')
  for _ = 1, 60 do q:frame(); t = t + 10 end
  T.eq(mouse, {3, 4, 35, 67, false}, 'clicks do not claim the mouse focus')
  T.eq(#log, 2)
  T.eq(log[1], {_MOUSE_L = true, _MOUSE_L_DOWN = true})
  T.eq(log[2], 'LEAVESCREEN')
  T.ok(q:idle())
  q:click_pct(50, 50, {button = 'R', hover_ms = 0})
  for _ = 1, 10 do q:frame(); t = t + 10 end
  T.eq(mouse, {50, 30, 500, 450, false})
  T.eq(log[3], {_MOUSE_R = true, _MOUSE_R_DOWN = true})
end)

T.test('input: hold claims the focus every frame, a click releases it first; probe learns the cursor', function()
  local t, log, mouse, unf, peeks = 0, {}, nil, 0, 0
  local env = {now = function() return t end, mouse = function(...) mouse = {...} end,
    sim = function(k) log[#log + 1] = k end, tile_px = function() return 10, 15 end,
    win = function() return 100, 60 end, unfocus = function() unf = unf + 1 end, claim = function() end,
    peek = function() peeks = peeks + 1 if peeks % 3 == 0 then return 70, 80 end return 12, 34 end}
  local q = I.new(env, {hover_ms = 50, after_ms = 20})
  q:hold(205, 307)
  q:frame()
  T.eq(mouse, {20, 20, 205, 307, true})
  q:click_px(5, 5)
  q:frame()
  T.eq(unf, 1, 'the click gave the focus back once')
  T.eq(mouse, {0, 0, 5, 5, false})
  for _ = 1, 20 do q:frame(); t = t + 10 end
  T.ok(q:idle())
  q:frame()
  T.eq(mouse, {20, 20, 205, 307, true}, 'the hold resumes after the click')
  q:probe(9)
  for _ = 1, 12 do q:frame() end
  T.eq(q.real, {12, 34}, 'most frequent position')
  T.eq(q.held, nil, 'probe ends the hold')
end)

T.test('steps: merge_tiles keeps the best water/trees/metals and the worst evil/savagery/aquifer', function()
  local rec = P.parse(fixture('site_good_panel'))
  rec.water, rec.rivers, rec.metals, rec.flux = nil, {}, nil, nil
  local t1 = {rivers = {'brook'}, water = 'brook', trees = 'none', metals = {'iron'}, flux = true, evil = 'neutral',
    savagery = 'high', aquifer = 'light', neighbors = {{race = 'goblins', travel = 'a short trip', rank = 1}}}
  local t2 = {rivers = {}, trees = 'heavily_forested', evil = 'evil', savagery = 'low', aquifer = 'none', neighbors = {}}
  local m = S.merge_tiles(rec, {t1, t2})
  T.eq(m.water, 'brook'); T.eq(m.trees, 'heavily_forested'); T.eq(m.metals, {'iron'}); T.eq(m.flux, true)
  T.eq(m.evil, 'evil'); T.eq(m.savagery, 'high'); T.eq(m.aquifer, 'light')
  T.eq(m.neighbors[1].race, 'goblins'); T.eq(m.tiles, {n = 2, water = 1, wood = 1})
  local deep = P.parse(fixture('site_aquifer_popup'))                      -- very deep soil on the hovered tile
  local d = S.merge_tiles(deep, {{rivers = {}, soil = 'some', layers = {'granite'}}, {rivers = {}, soil = 'deep'}})
  T.eq({d.soil, d.stone_soil, d.layers}, {'very_deep', 'some', {'granite'}}, 'stone: the shallowest tile counts')
  T.eq(S.merge_tiles(rec, nil), rec)
end)

---------------------------------------------------------------- runner + steps on the fake DF
local function start(D, spec, rules, tweak)
  local steps = S.build(spec, CFG, LOADOUT)
  if tweak then tweak(steps) end
  local docs = {}
  local env = {capture = D.capture, now = D.env.now, ui = I.new(D.env, CFG), w = D.w_api,
    status = function(doc) docs[#docs + 1] = json.decode(json.encode(doc)) end}
  local ctx = {spec = spec, rules = rules or RULES, caption = function(n) return F.CAPTION[n] or n end,
    results = {}, warnings = {}}
  local run = R.new(spec.id, steps, env, ctx, CFG)
  F.play(D, run)
  return run, docs, ctx
end

T.test('runner: new game from the title screen to the world map', function()
  local D = F.new()
  local run, docs = start(D, {v = 2, id = 'ng', mode = 'newgame', world = 'Zilirr'})
  T.eq(run.state, 'done', run.msg)
  T.eq(D.screen, 'world')
  T.eq(docs[#docs].state, 'done')
  T.ok(json.encode(docs[#docs]):find('"live":', 1, true))
end)

T.test('runner: scan learns the map offsets and reads 3 sites', function()
  local D = F.new({screen = 'world', sites = {
    ['9,30'] = {panel = {'Temperate Grassland', 'Temperature: Temperate', 'Trees: Sparse', 'Surroundings: Wilderness',
      'River: Yes', 'Very deep soil', 'Light aquifer'}, popup = {'You have selected an area with a light', 'aquifer.'}},
    ['12,4'] = {panel = {'Taiga', 'Temperature: Cold', 'Trees: Scarce', 'Surroundings: Haunted', 'Some soil'},
      popup = {'You have selected an evil area.'}}}})
  local rules = {}
  for k, v in pairs(RULES) do rules[k] = v end
  rules.dark_fortresses_seen = far_df
  local run, docs, ctx = start(D, {v = 2, id = 's1', mode = 'scan', cands = {{8, 30}, {9, 30, 2, 3}, {12, 4}}}, rules)
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(#ctx.results, 3)
  local a, b, c = ctx.results[1], ctx.results[2], ctx.results[3]
  T.eq(a.emb, {8 * 16 + 6, 30 * 16 + 6}); T.eq(a.world, {8, 30}); T.eq(a.size, {4, 4}); T.eq(a.verdict, 'ok')
  T.eq(b.emb, {9 * 16 + 2, 30 * 16 + 3}); T.eq(b.rec.aquifer, 'light'); T.ok(has(b.rec.warnings, 'light_aquifer'))
  T.eq(c.verdict, 'reject'); T.ok(has(c.fails, 'evil'))
  T.eq(ctx.pk, {-5, 2}, 'learned rectangle offset'); T.eq(ctx.wofs, {1, 0}, 'learned world offset')
  T.eq(#docs[#docs].results, 3)
end)

local GOOD_SITE = {['8,30'] = {neighbors = F.NEIGHBORS_FAR}}

T.test('runner: full embark spends picks and points, lands in the fort', function()
  local D = F.new({screen = 'world', sites = GOOD_SITE})
  local run, _, ctx = start(D, {v = 2, id = 'e1', mode = 'embark', site = {8, 30}})  -- shipped rules
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(D.screen, 'fort')
  T.eq(ctx.results[1].verdict, 'ok', 'dark fortress judged from the Neighbors section')
  T.eq({D.pressed.Confirm, D.pressed['Embark!']}, {1, 1}, 'one click each')
  for i, role in ipairs(LOADOUT.roles) do
    local u = D.units[i]
    T.eq(u.picks, 0, 'dwarf ' .. i)
    for _, sk in ipairs(role.skills) do T.eq(u.lv[sk[1]], sk[2], role.role .. ' ' .. sk[1]) end
  end
  T.eq(D.points, 0)
  T.eq(D.bought.pick, 1); T.eq(D.bought['iron bar'] >= 10, true); T.eq(D.bought.Turkey, 2); T.eq(D.bought.Pig, 2)
  T.eq(ctx.warnings, {})
end)

T.test('runner: slow map preparation and fort load spend no tries (10 s each)', function()
  local D = F.new({screen = 'world', sites = GOOD_SITE, prep_frames = 500, load_frames = 500})
  local run = start(D, {v = 2, id = 'e4', mode = 'embark', site = {8, 30}})
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(D.screen, 'fort')
  T.eq({D.pressed.Confirm, D.pressed['Embark!']}, {1, 1})
  D = F.new({screen = 'world', sites = GOOD_SITE, prep_frames = 500, load_frames = 500})
  run = start(D, {v = 2, id = 'e5', mode = 'embark', site = {8, 30}, play_now = true})
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(D.screen, 'fort'); T.eq({D.pressed.Confirm, D.pressed['Play now!']}, {1, 1})
end)

T.test('runner: an ignored Confirm click is not repeated; the step times out', function()
  local D = F.new({screen = 'world', sites = GOOD_SITE, ignore = {Confirm = true}})
  local run = start(D, {v = 2, id = 'e6', mode = 'embark', site = {8, 30}}, nil, function(steps)
    for _, st in ipairs(steps) do if st.id == 'site.confirm' then st.timeout_ms = 20000 end end  -- test speed
  end)
  T.eq(run.state, 'failed')
  T.ok(run.msg:find('site.confirm: timeout while waiting', 1, true), run.msg)
  T.eq(D.pressed.Confirm, 1)
end)

T.test('runner: the gate needs every unknown criterion waived by name', function()
  local D = F.new({screen = 'world'})  -- no Neighbors section: dark_fortress unknown
  local run = start(D, {v = 2, id = 'e2', mode = 'embark', site = {8, 30}})
  T.eq(run.state, 'failed')
  T.ok(run.msg:find('site.gate: unknown and not waived: dark_fortress', 1, true), run.msg)
  T.eq(D.screen, 'placing', 'never confirmed'); T.eq(D.pressed.Confirm, nil)
  D = F.new({screen = 'world'})
  local ctx
  run, _, ctx = start(D, {v = 2, id = 'e3', mode = 'embark', site = {8, 30}, waive = {'dark_fortress'}, play_now = true})
  T.eq(run.state, 'done', run.msg); T.eq(D.screen, 'fort')
  T.eq(ctx.warnings, {'site.gate: waived dark_fortress'})
  -- unknown evil and savagery (no Surroundings line) are refused although dark_fortress is waived
  D = F.new({screen = 'world', sites = {['8,30'] = {panel = {'Temperature: Temperate', 'Trees: Woodland',
    'Brook: Yes', 'Little soil', 'Iron'}}}})
  run = start(D, {v = 2, id = 'e7', mode = 'embark', site = {8, 30}, waive = {'dark_fortress'}})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('not waived: evil,savagery', 1, true), run.msg)
  D = F.new({screen = 'world'})
  run = start(D, {v = 2, id = 'e8', mode = 'embark', site = {8, 30}, waive = {'all'}})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('cannot waive all', 1, true), run.msg)
  T.raises(function() S.build({id = 'x', mode = 'embark', site = {1, 2}, accept_review = true}, CFG, LOADOUT) end,
    'accept_review was removed')
end)

T.test('runner (FR-08): a failed criterion passes the gate only when accepted by name with a reason', function()
  local nometal = {['8,30'] = {neighbors = F.NEIGHBORS_FAR, panel = {'Temperate Broadleaf Forest', '',
    'Temperature: Temperate', 'Trees: Woodland', 'Other Vegetation: Moderate', 'Surroundings: Calm', '', 'Brook: Yes',
    '', 'Little soil', 'Flux stone layer'}}}
  local D = F.new({screen = 'world', sites = nometal})
  local run = start(D, {v = 2, id = 'a1', mode = 'embark', site = {8, 30}})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('site rejected (fails: ore)', 1, true), run.msg)
  T.eq(D.pressed.Confirm, nil)
  D = F.new({screen = 'world', sites = nometal})
  run = start(D, {v = 2, id = 'a2', mode = 'embark', site = {8, 30}, accept = {{id = 'ore'}}})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('accepting ore needs a reason', 1, true), run.msg)
  D = F.new({screen = 'world', sites = nometal})
  run = start(D, {v = 2, id = 'a3', mode = 'embark', site = {8, 30}, accept = {{id = 'panel', why = 'x x x'}}})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('cannot accept panel', 1, true), run.msg)
  D = F.new({screen = 'world', sites = nometal})
  local ctx
  run, _, ctx = start(D, {v = 2, id = 'a4', mode = 'embark', site = {8, 30}, play_now = true,
                          accept = {{id = 'ore', why = 'bars by trade, iron from the second caravan'}}})
  T.eq(run.state, 'done', run.msg); T.eq(D.screen, 'fort')
  T.eq(ctx.warnings, {'site.gate: accepted ore (bars by trade, iron from the second caravan)'})
end)

T.test('runner: a read that is not of the placed target fails (rectangle follows the mouse)', function()
  local D = F.new({screen = 'world'})
  local run, _, ctx = start(D, {v = 2, id = 's2', mode = 'scan', cands = {{8, 30}}})
  T.eq(run.state, 'done', run.msg)
  local target = {8 * 16 + 6, 30 * 16 + 6}
  T.eq(ctx.results[1].emb, target, 'read with the popup open')
  local moved = D.rect()
  T.ok(moved[1] ~= target[1] or moved[2] ~= target[2], 'after Abort the rectangle sits under the mouse')
  -- the same read step while the rectangle is not the target: it waits (the real cursor can win a
  -- frame, live L0), then fails as not attributable; a popup open before the panel read fails at once
  D = F.new({screen = 'placing', follow = false})
  D.emb_min, D.region, D.popup = {moved[1], moved[2]}, {moved[1] // 16, moved[2] // 16}, false
  local st = S.read_site('t', target[1], target[2])
  local v = D.capture()
  T.ok(st.wait(v))
  local mem, ctx = {}, {rules = RULES, p_px = {1, 1}}
  local ui = I.new(D.env, CFG)
  local r, msg
  for _ = 1, 40 do r, msg = st.act(ui, v, ctx, D.w_api, mem) end
  T.eq(r, 'fail'); T.ok(msg:find('not attributable', 1, true), msg)
  D.popup = true
  r, msg = st.act(ui, D.capture(), ctx, D.w_api, {})
  T.eq(r, 'fail'); T.ok(msg:find('popup open before the panel was read', 1, true), msg)
  r, msg = st.act(ui, v, {rules = RULES}, D.w_api, {})
  T.eq(r, 'fail'); T.ok(msg:find('no held pixel', 1, true), msg)
end)

T.test('BUG-020: a rectangle that stays put whatever is held fails early, k is not learnt from it', function()
  -- live 2026-10-15 (DF restarted, window moved): "rectangle at 224,132 (holding -817,-1449)" after 12 tries; the
  -- rectangle ignored every held pixel and k came from two identical observations.
  -- BUG-247 changed how: one fixed pixel, the camera moves; an offset beyond local_k_max is no offset at all
  local D = F.new({screen = 'world', follow = false})
  D.emb_min, D.region = {224, 132}, {14, 8}
  local run, _, ctx = start(D, {v = 2, id = 's3', mode = 'scan', cands = {{8, 30}}})
  T.eq(run.state, 'failed', run.msg)
  local a, b, x, y = run.msg:match('rectangle does not follow the mouse: held (%-?%d+),(%-?%d+) .*rectangle stays at ' ..
                                   '(%d+),(%d+)')
  T.ok(a, run.msg)
  T.ok(tonumber(a) >= 0 and tonumber(b) >= 0, 'the held pixel stays in the window: ' .. run.msg)
  T.eq({tonumber(x), tonumber(y)}, {224, 132})
  T.ok(run.msg:find('^local%.place:'), run.msg)
  T.ok(run.tries <= 8, 'early: ' .. run.tries .. ' tries, not 12: ' .. table.concat(run.log, ' | '))
  T.eq(ctx.pk, nil, 'no k learnt from a rectangle that does not follow')
end)

---------------------------------------------------------------- BUG-229
local function item_of(r, id)
  for _, it in ipairs(r.items) do if it.id == id then return it end end
  return nil
end

T.test('BUG-229: the refusal "Cannot embark entirely on water or mountains." and the biome line are read', function()
  local pad = string.rep(' ', 40)
  local r = P.parse(V.from_lines({pad .. 'Mountain', pad .. 'Temperature: Cold', '',
    '      Cannot embark entirely on water or mountains.'}, {focus = {'choose_start_site'}}))
  T.eq(r.warnings, {'water_mountain'}, 'one refusal, by its own id')
  T.eq({r.biome, r.terrain}, {'mountain', 'mountain'})
  T.eq(P.parse(V.from_lines({pad .. 'Temperate Freshwater Lake'})).terrain, 'water')
  T.eq(P.parse(V.from_lines({pad .. 'Tropical Ocean'})).terrain, 'water')
  T.eq(P.parse(fixture('site_good_panel')).terrain, 'land')
  T.eq(P.parse(V.from_lines({pad .. 'The Mountain of Doom'})).terrain, nil, 'a region name is no biome')
  T.eq(P.parse(V.from_lines({'  Cannot embark on another site.'})).warnings, {'cannot'})
end)

T.test('BUG-229: checklist terrain: the refusal and an all-mountain/water rectangle reject; a mixed one passes', function()
  local good = P.parse(fixture('site_good_panel'))
  local ctx = {world = {8, 30}, size = {4, 4}}
  local rules = {dark_fortresses_seen = far_df}
  local function with(fn) local r = json.decode(json.encode(good)) fn(r) return C.evaluate(r, rules, ctx) end
  local r = with(function(x) x.warnings[#x.warnings + 1] = 'water_mountain' end)
  T.eq({item_of(r, 'terrain').res, r.verdict}, {'fail', 'reject'})
  T.eq(item_of(r, 'popup'), nil, 'judged by terrain, not twice as a popup')
  r = with(function(x) x.tiles = {n = 16, water = 0, wood = 0, terrain = 16, mw = 16} end)
  T.eq({item_of(r, 'terrain').res, r.verdict}, {'fail', 'reject'})
  T.ok(item_of(r, 'terrain').why:find('DF refuses', 1, true))
  r = with(function(x) x.tiles = {n = 9, water = 0, wood = 0, terrain = 9, mw = 9} end)
  T.eq(item_of(r, 'terrain').res, 'warn', 'all read tiles, but not all 16')
  r = with(function(x) x.tiles = {n = 16, water = 0, wood = 0, terrain = 16, mw = 15} end)
  T.eq(item_of(r, 'terrain').res, 'pass')
  r = with(function(x) x.terrain, x.biome = 'mountain', 'mountain' end)
  T.eq(item_of(r, 'terrain').res, 'warn', 'one hovered mountain tile: read --tiles')
  T.eq(item_of(C.evaluate(good, rules, ctx), 'terrain').res, 'pass')
  T.ok(not C.ACCEPTABLE_SET.terrain and not C.WAIVABLE_SET.terrain, 'DF refuses: never accepted')
  -- merge_tiles counts the tiles by terrain
  local m = S.merge_tiles(json.decode(json.encode(good)), {{rivers = {}, terrain = 'mountain'}, {rivers = {}, terrain = 'water'},
    {rivers = {}}})
  T.eq({m.tiles.terrain, m.tiles.mw}, {2, 2})
end)

T.test('BUG-229: scan flags an all-mountain rectangle (refusal on the panel or after the click) and goes on', function()
  local rules = {}
  for k, v in pairs(RULES) do rules[k] = v end
  rules.dark_fortresses_seen = far_df
  local D = F.new({screen = 'world', sites = {
    ['8,30'] = {panel = {'Mountain', 'Temperature: Cold', 'Trees: None', 'Surroundings: Calm', 'Cannot embark entirely',
      'on water or mountains.'}},
    ['9,30'] = {panel = {'Mountain', 'Temperature: Cold', 'Trees: None', 'Surroundings: Calm'},
      refuse = {'Cannot embark entirely on water or mountains.'}}}})
  local run, _, ctx = start(D, {v = 2, id = 's9', mode = 'scan', cands = {{8, 30}, {9, 30}, {12, 4}}}, rules)
  T.eq(run.state, 'done', run.msg .. ' / ' .. table.concat(run.log, ' | '))
  T.eq(#ctx.results, 3)
  for i = 1, 2 do
    local r = ctx.results[i]
    T.eq(r.verdict, 'reject', i)
    T.ok(has(r.fails, 'terrain'), 'terrain fails ' .. i)
  end
  T.eq(ctx.results[3].verdict, 'ok', 'the next candidate is read as before')
  T.eq(D.pressed.Confirm, nil, 'nothing confirmed')
end)

T.test('BUG-229: an old site given by its global tile (global_min) counts at g // 16, not at a stale w', function()
  local good = P.parse(fixture('site_good_panel'))
  local rules = {dark_fortresses_seen = far_df, old_site_min = 2,
    old_sites = {{name = 'Questmetal', w = {4, 10}, g = {6 * 16 + 3, 12 * 16 + 5}}}}
  local r = C.evaluate(good, rules, {world = {6, 12}, size = {4, 4}})
  T.eq(item_of(r, 'old_sites').res, 'fail', item_of(r, 'old_sites').why)
  T.ok(item_of(r, 'old_sites').why:find('at 0', 1, true), item_of(r, 'old_sites').why)
  rules.old_sites = {{name = 'Questmetal', w = {4, 10}}}
  T.eq(item_of(C.evaluate(good, rules, {world = {6, 12}, size = {4, 4}}), 'old_sites').res, 'pass', 'w alone as before')
  T.eq(C.site_world({g = {100, 33}}), {6, 2})
  T.eq(C.site_world({w = {3, 4}}), {3, 4})
end)

T.test('runner: wait results spend no tries; the timeout still ends them', function()
  local t, k = 0, 0
  local env = {capture = function() return V.from_lines({}) end, now = function() return t end,
    ui = I.new({now = function() return t end}, CFG), w = {}}
  local step = {id = 'slow', tries = 1, timeout_ms = 60000,
    act = function(ui, v, ctx, w, mem) mem.n = (mem.n or 0) + 1 return 'wait', 'waiting' end,
    done = function() k = k + 1 return k >= 100, 'not yet' end}
  local run = R.new('w', {step}, env, {}, CFG)
  while run:frame() and t < 120000 do t = t + 20 end
  T.eq(run.state, 'done', run.msg); T.eq(run.tries, 0); T.ok(t >= 99 * CFG.poll_ms, t)
  k, t = -1e9, 0
  run = R.new('w2', {step}, env, {}, CFG)
  while run:frame() and t < 120000 do t = t + 20 end
  T.eq(run.state, 'failed'); T.ok(run.msg:find('timeout while waiting', 1, true), run.msg)
end)

T.test('runner: ignored skill clicks fail cleanly (Run 6 symptom)', function()
  local D = F.new({screen = 'prep_default', skill_clicks = false})
  local run = start(D, {v = 2, id = 'p1', mode = 'prep'})
  T.eq(run.state, 'failed')
  T.ok(run.msg:find('prep.skills.1', 1, true) and run.msg:find('no progress', 1, true), run.msg)
end)

T.test('runner: list row clicks ignored -> dwarf selected like startdwarf', function()
  local D = F.new({screen = 'prep_default', row_select = false})
  local run = start(D, {v = 2, id = 'p2', mode = 'prep'})
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(D.units[7].picks, 0)
end)

T.test('runner: unspent points -> DF warning -> Go back and fail', function()
  local D = F.new({screen = 'prep_default'})
  local lo = {roles = LOADOUT.roles, items = {}, animals = {}, rest = {}}
  local steps = S.build({v = 2, id = 'p3', mode = 'prep'}, CFG, lo)
  local env = {capture = D.capture, now = D.env.now, ui = I.new(D.env, CFG), w = D.w_api}
  local run = R.new('p3', steps, env, {caption = function(n) return F.CAPTION[n] end, rules = RULES}, CFG)
  F.play(D, run)
  T.eq(run.state, 'failed'); T.ok(run.msg:find('unspent', 1, true), run.msg)
  T.eq(D.screen, 'prep_items', 'Go back was clicked')
end)

T.test('runner: timeout and stop', function()
  local D = F.new({screen = 'title'})
  local env = {capture = D.capture, now = D.env.now, ui = I.new(D.env, CFG), w = D.w_api}
  local run = R.new('t', {{id = 'never', wait = function() return false end, timeout_ms = 1000}}, env, {}, CFG)
  F.play(D, run)
  T.eq(run.state, 'failed'); T.ok(run.msg:find('timeout in wait', 1, true), run.msg)
  run = R.new('t2', {{id = 'never', wait = function() return false end}}, env, {}, CFG)
  run:frame(); run:stop('by test')
  T.eq(run.state, 'stopped'); T.eq(run:frame(), false)
end)

T.test('steps: build covers every mode; unknown mode raises', function()
  T.eq(#S.build({id = 'n', mode = 'newgame', world = 'W'}, CFG, LOADOUT), 7)
  T.eq(#S.build({id = 's', mode = 'scan', cands = {{1, 2}, {3, 4}}}, CFG, LOADOUT), 8)
  local e = S.build({id = 'e', mode = 'embark', site = {1, 2}, tiles = false}, CFG, LOADOUT)
  local ids = {}
  for _, st in ipairs(e) do
    ids[#ids + 1] = st.id
    T.ok(st.live == 'run4-6' or st.live == 'untested' or st.live == 'L0' or st.live == 'L6', st.id)
  end
  T.eq({ids[1], ids[2], ids[3], ids[4], ids[5]}, {'world.goto', 'local.place', 'site.read', 'site.gate', 'site.confirm'})
  T.eq({ids[#ids - 1], ids[#ids]}, {'prep.embark', 'fort.intro'}, 'the intro popup is clicked last (live L6)')
  -- default embark (and scan with tiles=true): 16 hovered tiles before the final placement
  e = S.build({id = 'e', mode = 'embark', site = {1, 2}}, CFG, LOADOUT)
  T.eq({e[2].id, e[3].id, e[33].id, e[34].id, e[35].id, e[36].id},
    {'local.place.t1', 'site.tile.1', 'site.tile.16', 'local.place', 'site.read', 'site.gate'})
  T.eq(#S.build({id = 's', mode = 'scan', cands = {{1, 2}}, tiles = true}, CFG, LOADOUT), 36)
  T.raises(function() S.build({mode = 'x'}, CFG, LOADOUT) end, 'unknown mode')
end)

T.done()
