-- K2 (BUG-098/099): tools/embark/loadsave.lua, the click path that loads a saved fort from the title screen
-- after DFHack 53.16-r3 broke load-save. Pure functions on text, then the steps on the fake DF
-- (tools/embark/fixtures/fake_df.lua: title, savelist, loadpopup, loadsave screens).
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local json = require('dfllm.util.json')
local V = require('embark.view')
local I = require('embark.input')
local R = require('embark.runner')
local S = require('embark.steps')
local F = require('embark.fixtures.fake_df')
local LS = require('embark.loadsave')

local function slurp(p)
  local f = assert(io.open(p, 'rb'))
  local s = f:read('a')
  f:close()
  return s
end
local CFG = json.decode(slurp(repo .. '/tools/embark/ui.json'))
local LOADOUT = json.decode(slurp(repo .. '/tools/embark/loadout.json'))

---------------------------------------------------------------- pure functions
T.test('norm: lowercase ASCII, one space between words', function()
  T.eq(LS.norm('  Continue   Playing! '), 'continue playing')
  T.eq(LS.norm('autosave 1'), 'autosave 1')
  T.eq(LS.norm(nil), '')
end)

T.test('token: a save name counts as a whole token only (autosave 1 is not autosave 10)', function()
  T.eq({LS.token('  autosave 1   Year 52', 'autosave 1')}, {2, 10})
  T.eq({LS.token('Region2 (Year 3)', 'region2')}, {0, 7}, 'case-insensitive')
  T.eq({LS.token('autosave 10', 'autosave 1')}, {}, 'a longer number is another save')
  T.eq({LS.token('region2-spr-0050', 'region2')}, {}, 'a season suffix is another save')
  T.eq({LS.token('xautosave 1', 'autosave 1')}, {})
  T.eq({LS.token('autosave 10  autosave 1', 'autosave 1')}, {13, 10}, 'the second one on the row')
  T.eq({LS.token('autosave 1', '')}, {})
  T.eq({LS.token('autosave 1.', 'autosave 1')}, {0, 10})
end)

T.test('find_all: rows that hold the name, with the tile of the first character', function()
  local v = V.from_lines({'', '   region2', '   autosave 10', '       autosave 1  Year 5', ' x autosave 1'})
  local m = LS.find_all(v, 'autosave 1')
  T.eq(#m, 2)
  T.eq({m[1].x, m[1].y, m[1].len}, {7, 3, 10})
  T.eq({m[2].x, m[2].y}, {3, 4})
  T.eq(#LS.find_all(v, 'region3'), 0)
end)

T.test('choose_entry: the topmost row that shows the name; a look-alike is no entry; why when there is none', function()
  local v = V.from_lines({'  Select a game: autosave 1 or autosave 2', '', '   autosave 10', '   autosave 1  Year 5',
                          '   region2'})
  local m, note = LS.choose_entry(v, 'autosave 1')
  T.eq({m.x, m.y, m.len}, {17, 0, 10}, 'the heading is a row too: the topmost')
  T.ok(note:find('2 rows', 1, true), note)
  m, note = LS.choose_entry(V.from_lines({'  autosave 10', '  region2'}), 'autosave 1')
  T.eq({m, note}, {nil, '"autosave 1" is not on the screen'})
  m, note = LS.choose_entry(V.from_lines({'  autosave 10', '  autosave 1'}), 'autosave 1')
  T.eq({m.y, note}, {1, nil})
end)

T.test('target: the middle of the text, the pixel of that tile centre (10x15 and 12x18 px tiles)', function()
  local m = {x = 4, y = 6, len = 11}
  T.eq(LS.target(m, 10, 15), {tx = 9, ty = 6, px = 95, py = 97})
  T.eq(LS.target(m, 12, 18), {tx = 9, ty = 6, px = 9 * 12 + 6, py = 6 * 18 + 9}, 'CLAUDE.md: x*12+6, y*18+9')
end)

T.test('main menu: Continue first, then Load; nothing else is a button', function()
  local main = V.from_lines({'', '        Continue playing', '', '        Start new game in existing world'},
                            {focus = {'title/Default'}})
  T.ok(LS.is_main(main))
  local c, rank = LS.main_button(main)
  T.eq({c.text, c.x, c.y, rank}, {'Continue playing', 8, 1, 1})
  local both = V.from_lines({'  Load game', '  Continue active game', '  Start new game in existing world'})
  c, rank = LS.main_button(both)
  T.eq({c.text, rank}, {'Continue active game', 1}, 'Continue wins over Load')
  local load = V.from_lines({'  Load a saved game', '  Create new world!'})
  c, rank = LS.main_button(load)
  T.eq({c.text, rank}, {'Load a saved game', 2})
  T.ok(LS.is_main(load))
  T.eq(LS.main_button(V.from_lines({'  Loading game...', '  Start new game in existing world'})), nil,
       'Loading is not a Load button')
  T.eq(LS.main_button(V.from_lines({'  Start new game in existing world'})), nil)
  T.ok(not LS.is_main(V.from_lines({'  autosave 1', '  region2'})))
end)

T.test('confirm buttons and danger words', function()
  local pop = V.from_lines({'  This game was saved with a different version.', '  Okay    Cancel'})
  T.eq(LS.confirm_button(pop).text, 'Okay')
  T.eq(LS.danger(pop), nil)
  T.eq(LS.danger(V.from_lines({'  This will Delete the save.', '  Okay'})), 'delete')
  T.eq(LS.danger(V.from_lines({'  Please overwrite nothing'})), 'overwrite')
  T.eq(LS.confirm_button(V.from_lines({'  autosave 1', '  region2'})), nil)
  T.ok(LS.confirm_button(V.from_lines({'  Continue'})), 'exact Continue confirms off the main menu')
end)

T.test('screen: fort, loading, main, list, confirm, other (foreign screens are never title screens)', function()
  local function s(lines, focus, title) return {LS.screen(V.from_lines(lines, {focus = focus, title = title}), 'autosave 1')} end
  T.eq(s({'x'}, {'dwarfmode/Default'})[1], 'fort')
  T.eq(s({'  Loading game...'}, {'title/Default'})[1], 'loading')
  T.eq(s({'  Continue playing', '  Start new game in existing world'}, {'title/Default'})[1], 'main')
  T.eq(s({'  autosave 1'}, {'title/Default'})[1], 'list')
  T.eq(s({'  Okay'}, {'title/Default'})[1], 'confirm')
  T.eq(s({'  Okay'}, {'loadgame'})[1], 'confirm', 'the old load game focus is a title screen too')
  local o = s({'  something else'}, {'title/Default'})
  T.eq({o[1], o[3]}, {'other', 'title'})
  o = s({'  Click the map to zoom in'}, {'choose_start_site'})
  T.eq({o[1], o[3]}, {'other', 'foreign'})
  T.eq(s({'  Okay'}, {'choose_start_site'})[1], 'other', 'an Okay on the embark map is not ours')
  T.eq(s({'  Okay'}, {'unknown/x'}, {old_field = false})[1], 'confirm', 'viewscreen_titlest by type counts as title')
end)

T.test('brief: the cells of the screen on one line, clipped', function()
  local v = V.from_lines({'  Continue playing', '', '  Start new game in existing world'})
  T.eq(LS.brief(v), 'Continue playing | Start new game in existing world')
  T.eq(#LS.brief(V.from_lines({string.rep('word ', 100)}), 40) <= 40, true)
end)

T.test('fuzz: random title-ish screens never raise; an entry is only ever a whole-token match of the name', function()
  local words = {'autosave', '1', '10', 'autosave 1', 'autosave 10', 'region2', 'region2-spr-0050', 'Continue', 'playing',
    'Load', 'game', 'Okay', 'Delete', 'Loading', 'Start new game in existing world', 'x', '', '   ', 'AUTOSAVE 1'}
  local seed = 12345
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return seed % n + 1 end
  local found = 0
  for _ = 1, 600 do
    local lines = {}
    for i = 1, rnd(8) do
      local parts = {}
      for _ = 1, rnd(4) do parts[#parts + 1] = words[rnd(#words)] end
      lines[i] = string.rep(' ', rnd(6) - 1) .. table.concat(parts, rnd(2) == 1 and ' ' or '   ')
    end
    for _, focus in ipairs({'title/Default', 'dwarfmode/Default', 'choose_start_site'}) do
      local v = V.from_lines(lines, {focus = {focus}})
      local kind = LS.screen(v, 'autosave 1')
      if focus ~= 'title/Default' then
        T.ok(kind == 'fort' or kind == 'other' or kind == 'loading', 'a non-title screen is never main/list/confirm: ' .. kind)
      end
      LS.main_button(v); LS.confirm_button(v); LS.danger(v); LS.brief(v); LS.signature(v)
    end
    local v = V.from_lines(lines, {focus = {'title/Default'}})
    local m = LS.choose_entry(v, 'autosave 1')
    if m then
      found = found + 1
      local line = v.lines[m.y + 1]
      T.eq(LS.norm(line:sub(m.x + 1, m.x + m.len)), 'autosave 1')
      T.ok(not line:sub(m.x, m.x):match('[%w_%-]') and not line:sub(m.x + m.len + 1, m.x + m.len + 1):match('[%w_%-]'))
    end
  end
  T.ok(found > 50, 'the generator does produce matches: ' .. found)
end)

T.test('steps: need a save name; two steps; the stock step comes first', function()
  T.raises(function() LS.steps({}, CFG) end, 'spec.save')
  local st = LS.steps({save = 'autosave 1'}, CFG)
  T.eq({#st, st[1].id, st[2].id}, {2, 'load.stock', 'load.drive'})
  T.ok(st[1].optional and not st[2].optional)
  T.eq(S.build({v = 2, id = 'l1', mode = 'load', save = 'autosave 1'}, CFG, LOADOUT)[2].id, 'load.drive')
end)

---------------------------------------------------------------- the steps on the fake DF
local SAVES = {{name = 'autosave 10'}, {name = 'autosave 1'}, {name = 'region2'}}

local function cfg_with(load)   -- a copy of ui.json with other `load` values
  local c = json.decode(json.encode(CFG))
  c.load = load
  return c
end

local function start(D, spec, cfg)
  cfg = cfg or CFG
  local docs, dumps = {}, {}
  local env = {capture = D.capture, now = D.env.now, ui = I.new(D.env, cfg), w = D.w_api,
    status = function(doc) docs[#docs + 1] = json.decode(json.encode(doc)) end,
    dump = function(name) dumps[#dumps + 1] = name end}
  local ctx = {spec = spec, results = {}, warnings = {}}
  local run = R.new(spec.id, LS.steps(spec, cfg), env, ctx, cfg)
  F.play(D, run)
  return run, docs, ctx, dumps
end
local function spec(save, extra)
  local s = {v = 2, id = 'l1', mode = 'load', save = save, stock = false}
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end
local function texts(ctx)
  local t = {}
  for _, c in ipairs(ctx.results.clicks or {}) do t[#t + 1] = c.kind .. ':' .. c.text end
  return t
end

T.test('flow list: Continue, then the entry named, never the look-alikes', function()
  local D = F.new({saves = SAVES, load_frames = 400})   -- still loading when the run looks (8 s)
  local run, docs, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(D.chosen, 'autosave 1', 'exactly the named save')
  T.eq(texts(ctx), {'main:Continue playing', 'entry:autosave 1'})
  T.eq(ctx.results.outcome, 'loading')
  local c = ctx.results.clicks[2]   -- list row 2 of the fake: x 30, y 12, "autosave 1" is 10 wide
  T.eq({c.tx, c.ty, c.px, c.py}, {35, 12, 355, 187}, 'the pixel the run clicked is in the result')
  T.eq(docs[#docs].state, 'done')
  T.ok(json.encode(docs[#docs]):find('"clicks"', 1, true), 'status.json carries the clicks')
end)

T.test('flow list: a numbered look-alike is chosen when its own name is asked for', function()
  local D = F.new({saves = SAVES})
  local run, _, ctx = start(D, spec('autosave 10'))
  T.eq(run.state, 'done', run.msg)
  T.eq(D.loaded, 'autosave 10')
  T.eq(texts(ctx)[2], 'entry:autosave 10')
end)

T.test('flow direct: Continue loads the latest save at once', function()
  local D = F.new({saves = SAVES, flow = 'direct'})
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'done', run.msg)
  T.eq(D.loaded, '(latest)')
  T.eq(texts(ctx), {'main:Continue playing'})
end)

T.test('flow confirm: the popup after the entry is confirmed', function()
  local D = F.new({saves = SAVES, flow = 'confirm'})
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(D.loaded, 'autosave 1')
  T.eq(texts(ctx), {'main:Continue playing', 'entry:autosave 1', 'confirm:Okay'})
end)

T.test('flow select_load: an entry that only selects needs the Load button', function()
  local D = F.new({saves = SAVES, flow = 'select_load'})
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(D.loaded, 'autosave 1')
  T.eq(texts(ctx), {'main:Continue playing', 'entry:autosave 1', 'confirm:Load'})
end)

T.test('a click that needs a second click: the screen did not change, so it is sent again', function()
  local D = F.new({saves = SAVES, skip = {['Continue playing'] = 1}})
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'done', run.msg)
  T.eq(D.loaded, 'autosave 1')
  T.eq(texts(ctx), {'main:Continue playing', 'main:Continue playing', 'entry:autosave 1'})
  T.eq(D.pressed['Continue playing'], 2)
end)

T.test('a menu that ignores every click fails with the rows and the pixel, after a bounded number of clicks', function()
  local D = F.new({saves = SAVES, ignore = {['Continue playing'] = true}})
  local run, _, ctx, dumps = start(D, spec('autosave 1'))
  T.eq(run.state, 'failed')
  T.ok(run.msg:find('no progress', 1, true), run.msg)
  T.ok(#ctx.results.clicks >= 3 and #ctx.results.clicks <= 6, 'clicks ' .. #ctx.results.clicks)
  T.ok(ctx.results.rows:find('Continue playing', 1, true), 'the last rows are in the result')
  T.eq(D.loaded, nil)
  T.eq(dumps[1], 'fail-load.drive', 'a screen dump is written')
end)

T.test('the save is not on the list: fail, nothing but Continue was clicked', function()
  local D = F.new({saves = {{name = 'region2'}, {name = 'autosave 10'}}})
  local run, _, ctx = start(D, spec('autosave 1'), cfg_with({unknown_polls = 3}))
  T.eq(run.state, 'failed', run.msg)
  T.ok(run.msg:find('"autosave 1"', 1, true), run.msg)
  T.ok(run.msg:find('autosave 10', 1, true) and run.msg:find('region2', 1, true), 'the rows are in the message: ' .. run.msg)
  T.eq(texts(ctx), {'main:Continue playing'})
  T.eq(D.loaded, nil)
end)

T.test('a title menu without Continue or Load fails and clicks nothing', function()
  local D = F.new({})   -- the plain title screen: only "Start new game in existing world"
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'failed')
  T.ok(run.msg:find('no Continue or Load', 1, true), run.msg)
  T.eq(#(ctx.results.clicks or {}), 0)
end)

T.test('a fort that is already loaded is never clicked', function()
  local D = F.new({saves = SAVES, screen = 'fort'})
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'failed')
  T.ok(run.msg:find('already loaded', 1, true), run.msg)
  T.eq(D.clicks, 0)
  T.eq(#(ctx.results.clicks or {}), 0)
end)

T.test('screens that are not the title family are never clicked (embark map, world list)', function()
  local small = cfg_with({unknown_polls = 3})
  for _, screen in ipairs({'world', 'local', 'prep_default', 'worlds'}) do
    local D = F.new({saves = SAVES, screen = screen})
    local run, _, ctx = start(D, spec('autosave 1'), small)
    T.eq(run.state, 'failed', screen)
    T.eq(D.clicks, 0, screen .. ' was clicked')
    T.eq(#(ctx.results.clicks or {}), 0, screen)
  end
end)

T.test('a popup that talks of deleting is left to the player', function()
  local D = F.new({saves = SAVES, flow = 'danger'})
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'failed')
  T.ok(run.msg:find('delete', 1, true) and run.msg:find('player', 1, true), run.msg)
  T.eq(texts(ctx), {'main:Continue playing', 'entry:autosave 1'})
  T.eq(D.loaded, nil)
end)

T.test('loading with nothing clicked yet is waited for, not counted as success', function()
  local D = F.new({saves = SAVES, screen = 'loadsave', load_frames = 100000})
  local run, _, ctx = start(D, spec('autosave 1'), cfg_with({timeout_ms = 3000}))
  T.eq(run.state, 'failed')
  T.ok(run.msg:find('timeout', 1, true), run.msg)
  T.eq(ctx.results.outcome, nil)
  T.eq(D.clicks, 0)
end)

T.test('stock first: where sel_menu_line exists the stock load-save runs and no click is needed', function()
  local D = F.new({saves = SAVES, old_field = true})
  local run, _, ctx = start(D, spec('autosave 1', {stock = true}))
  T.eq(run.state, 'done', run.msg)
  T.eq(D.stock_calls, {'autosave 1'})
  T.eq(D.loaded, 'autosave 1')
  T.eq(#(ctx.results.clicks or {}), 0, 'no click')
end)

T.test('stock first: without the old field (r3) the stock step is skipped with a reason, then the clicks', function()
  local D = F.new({saves = SAVES, old_field = false})
  local run, _, ctx = start(D, spec('autosave 1', {stock = true}))
  T.eq(run.state, 'done', run.msg)
  T.eq(D.stock_calls, {}, 'the stock script was not called')
  T.eq(D.loaded, 'autosave 1')
  T.eq(texts(ctx), {'main:Continue playing', 'entry:autosave 1'})
  local skipped = false
  for _, l in ipairs(run.log) do if l:find('sel_menu_line', 1, true) and l:find('skipped', 1, true) then skipped = true end end
  T.ok(skipped, table.concat(run.log, '\n'))
end)

T.test('stock: not requested (supervise tried it already) means not called even where the field exists', function()
  local D = F.new({saves = SAVES, old_field = true})
  local run = start(D, spec('autosave 1', {stock = false}))
  T.eq(run.state, 'done', run.msg)
  T.eq(D.stock_calls, {})
  T.eq(D.loaded, 'autosave 1')
end)

T.test('the entry text can be set for the list (calibration): entry replaces the folder name', function()
  local D = F.new({saves = {{name = 'autosave 1', label = 'Ostlysh the Hammers, Year 52'}}})
  local run, _, ctx = start(D, spec('autosave 1', {entry = 'Ostlysh'}))
  T.eq(run.state, 'done', run.msg)
  T.eq(D.loaded, 'autosave 1')
  T.eq(texts(ctx)[2], 'entry:Ostlysh')
end)

T.test('the Load button of the main menu is used when there is no Continue', function()
  local D = F.new({saves = SAVES, continue_label = 'Load game'})
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'done', run.msg)
  T.eq(texts(ctx)[1], 'main:Load game')
  T.eq(D.loaded, 'autosave 1')
end)

T.done()
