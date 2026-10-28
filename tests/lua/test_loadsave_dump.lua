-- FR-91 (Run 14 note 99): the title-screen run records WHAT THE SCREEN SHOWS when it cannot find a label: once per run, bounded,
-- read only (viewscreen stack, kind, size, viewscreen_titlest fields, rows, text cells with their tile). The labels of the
-- 53.16-r3 menu are unknown offline; this record decides them in one live look.
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local json = require('dfllm.util.json')
local V = require('embark.view')
local I = require('embark.input')
local R = require('embark.runner')
local F = require('embark.fixtures.fake_df')
local LS = require('embark.loadsave')

local function slurp(p)
  local f = assert(io.open(p, 'rb'))
  local s = f:read('a')
  f:close()
  return s
end
local CFG = json.decode(slurp(repo .. '/tools/embark/ui.json'))

local function start(D, spec, cfg)
  cfg = cfg or CFG
  local docs = {}
  local env = {capture = D.capture, now = D.env.now, ui = I.new(D.env, cfg), w = D.w_api,
    status = function(doc) docs[#docs + 1] = json.decode(json.encode(doc)) end, dump = function() end}
  local ctx = {spec = spec, results = {}, warnings = {}}
  local run = R.new(spec.id, LS.steps(spec, cfg), env, ctx, cfg)
  F.play(D, run)
  return run, docs, ctx
end
local function spec(save) return {v = 2, id = 'l1', mode = 'load', save = save, stock = false} end

T.test('dump: the viewscreen stack, kind, size, title fields, numbered rows and cells with their tile', function()
  local v = V.from_lines({'', '   Continue playing', '', '        Start new game in existing world'},
                         {focus = {'title/Default', 'dwarfmode'}, title = {old_field = false, selected = 2}})
  local d = LS.dump(v, 'why not')
  T.eq(d.why, 'why not')
  T.eq(d.focus, 'title/Default|dwarfmode')
  T.eq(d.size, '40x4')
  T.eq(d.title, {old_field = false, selected = 2})
  T.eq(d.rows, {'1    Continue playing', '3         Start new game in existing world'})
  T.eq(d.cells, {'3,1 Continue playing', '8,3 Start new game in existing world'})
end)

T.test('dump is bounded: rows, columns and cells', function()
  local lines = {}
  for i = 1, 200 do lines[i] = 'row ' .. i .. ' ' .. string.rep('x', 300) .. '   cell' end
  local d = LS.dump(V.from_lines(lines, {focus = {'title/Default'}}), 'many')
  T.eq(#d.rows, LS.DUMP_ROWS)
  T.ok(#d.rows[1] <= LS.DUMP_COLS + 6, #d.rows[1])
  T.eq(#d.cells, LS.DUMP_CELLS)
  T.ok(#json.encode(d) < 12000, 'the record stays small: ' .. #json.encode(d))
end)

T.test('a title menu without Continue or Load: the run fails with a dump of that screen, nothing clicked', function()
  local D = F.new({})
  local run, docs, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'failed')
  local d = ctx.results.dump
  T.ok(d, 'the dump is in the results')
  T.eq(d.why, 'the title menu has no Continue or Load entry')
  T.ok(d.focus:find('title', 1, true), d.focus)
  local rows = table.concat(d.rows, '\n')
  T.ok(rows:find('Start new game in existing world', 1, true), rows)
  T.ok(json.encode(docs[#docs]):find('"dump"', 1, true), 'status.json carries it')
  T.eq(#(ctx.results.clicks or {}), 0)
end)

T.test('a screen that is not ours: dumped once at the first look, clicks nothing, not overwritten by later polls', function()
  local D = F.new({saves = {{name = 'autosave 1'}}, screen = 'world'})
  local small = json.decode(json.encode(CFG))
  small.load = {unknown_polls = 4}
  local run, _, ctx = start(D, spec('autosave 1'), small)
  T.eq(run.state, 'failed')
  T.eq(D.clicks, 0)
  local d = ctx.results.dump
  T.ok(d and d.why:find('not the title screen', 1, true), d and d.why)
  T.ok(d.focus:find('choose_start_site', 1, true), d.focus)
  T.eq(d.kind, 'world')
end)

T.test('a menu that ignores every click: the third click dumps the screen the clicks fall on', function()
  local D = F.new({saves = {{name = 'autosave 10'}, {name = 'autosave 1'}}, ignore = {['Continue playing'] = true}})
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'failed')
  local d = ctx.results.dump
  T.ok(d, 'dump')
  T.ok(d.why:find('clicked 3 times; the last was main "Continue playing"', 1, true), d.why)
  T.ok(table.concat(d.rows, '\n'):find('Continue playing', 1, true))
end)

T.test('a run that finds its labels records no dump', function()
  T.ok(LS.dump, 'the dump function exists')
  local D = F.new({saves = {{name = 'autosave 10'}, {name = 'autosave 1'}}})
  local run, _, ctx = start(D, spec('autosave 1'))
  T.eq(run.state, 'done', run.msg)
  T.eq(ctx.results.dump, nil)
end)

T.done()
