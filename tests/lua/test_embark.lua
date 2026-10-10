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

T.test('checklist: light aquifer and deep soil warn, evil rejects', function()
  local r = eval('site_aquifer_popup', {dark_fortresses_seen = far_df})
  T.eq(r.verdict, 'ok')
  T.ok(has(r.warns, 'aquifer') and has(r.warns, 'soil') and has(r.warns, 'trees') and has(r.warns, 'popup'))
  T.ok(r.score < 60)
  r = eval('site_evil_popup', {dark_fortresses_seen = far_df})
  T.eq(r.verdict, 'reject')
  for _, id in ipairs({'evil', 'trees', 'water', 'popup'}) do T.ok(has(r.fails, id), id) end
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
  T.eq(mouse, {3, 4, 35, 67})
  T.eq(#log, 2)
  T.eq(log[1], {_MOUSE_L = true, _MOUSE_L_DOWN = true})
  T.eq(log[2], 'LEAVESCREEN')
  T.ok(q:idle())
  q:click_pct(50, 50, {button = 'R', hover_ms = 0})
  for _ = 1, 10 do q:frame(); t = t + 10 end
  T.eq(mouse, {50, 30, 500, 450})
  T.eq(log[3], {_MOUSE_R = true, _MOUSE_R_DOWN = true})
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
    'Brook: Yes', 'Little soil'}}}})
  run = start(D, {v = 2, id = 'e7', mode = 'embark', site = {8, 30}, waive = {'dark_fortress'}})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('not waived: evil,savagery', 1, true), run.msg)
  D = F.new({screen = 'world'})
  run = start(D, {v = 2, id = 'e8', mode = 'embark', site = {8, 30}, waive = {'all'}})
  T.eq(run.state, 'failed'); T.ok(run.msg:find('cannot waive all', 1, true), run.msg)
  T.raises(function() S.build({id = 'x', mode = 'embark', site = {1, 2}, accept_review = true}, CFG, LOADOUT) end,
    'accept_review was removed')
end)

T.test('runner: a read that is not of the placed target fails (rectangle follows the mouse)', function()
  local D = F.new({screen = 'world'})
  local run, _, ctx = start(D, {v = 2, id = 's2', mode = 'scan', cands = {{8, 30}}})
  T.eq(run.state, 'done', run.msg)
  local target = {8 * 16 + 6, 30 * 16 + 6}
  T.eq(ctx.results[1].emb, target, 'read with the popup open')
  local moved = D.rect()
  T.ok(moved[1] ~= target[1] or moved[2] ~= target[2], 'after Abort the rectangle sits under the mouse')
  -- the same read step on a popup whose rectangle is not the target
  D = F.new({screen = 'placing'})
  D.emb_min, D.region, D.popup = {moved[1], moved[2]}, {moved[1] // 16, moved[2] // 16}, true
  local st = S.read_site('t', target[1], target[2])
  local v = D.capture()
  T.ok(st.wait(v))
  local r, msg = st.act(nil, v, {rules = RULES})
  T.eq(r, 'fail'); T.ok(msg:find('not attributable', 1, true), msg)
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
  local e = S.build({id = 'e', mode = 'embark', site = {1, 2}}, CFG, LOADOUT)
  local ids = {}
  for _, st in ipairs(e) do
    ids[#ids + 1] = st.id
    T.ok(st.live == 'run4-6' or st.live == 'untested', st.id)
  end
  T.eq({ids[1], ids[2], ids[3], ids[4], ids[5]}, {'world.goto', 'local.place', 'site.read', 'site.gate', 'site.confirm'})
  T.eq(ids[#ids], 'prep.embark')
  T.raises(function() S.build({mode = 'x'}, CFG, LOADOUT) end, 'unknown mode')
end)

T.done()
