-- fix22-embark (Run 16 player reports): BUG-409 brook geometry (edge-only brook), BUG-410 sweep (pre-rank rows),
-- BUG-411 worst-case hover merge (aquifer, stone). Fake DF screens (the hover fake of test_embark_fix6.lua).
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local json = require('dfllm.util.json')
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
local RULES_FAR = {}
for k, v in pairs(RULES) do RULES_FAR[k] = v end
RULES_FAR.dark_fortresses_seen = {{name = 'far', w = {0, 0}}}

local function item(r, id) for _, it in ipairs(r.items) do if it.id == id then return it end end end

local function start(D, spec)
  local steps = S.build(spec, CFG, LOADOUT)
  local env = {capture = D.capture, now = D.env.now, ui = I.new(D.env, CFG), w = D.w_api, status = function() end}
  local ctx = {spec = spec, rules = RULES_FAR, caption = function(n) return F.CAPTION[n] or n end, results = {}, warnings = {}}
  local run = R.new(spec.id, steps, env, ctx, CFG)
  F.play(D, run)
  return run, ctx
end

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

local function hover_fake(tiles)
  local D = F.new({screen = 'world', follow = false})
  D.emb_min, D.region = {224, 132}, {14, 8}
  extend(D, 'placing', function(add)
    if D.popup then return end
    local cx, cy = D.w * D.tpx // 2, D.h * D.tpy // 2
    local t = {D.zoom[1] + (D.mouse[3] - cx) // 16, D.zoom[2] + (D.mouse[4] - cy) // 16}
    local lines = tiles[t[1] .. ',' .. t[2]] or tiles.default
    for i, l in ipairs(lines) do if l ~= '' then add(125, 1 + i, l) end end
  end, function(x) return x[1] == 125 end)
  return D
end
local function panel(extra, soil, aq)
  local out = {'Temperate Broadleaf Forest', 'Temperature: Temperate', 'Trees: Woodland', 'Surroundings: Calm',
    soil or 'Little soil', 'Iron', '', 'Neighbors:', 'Goblins', "Nearest site: 9 days' travel"}
  if aq then table.insert(out, 5, aq) end
  if extra then table.insert(out, 5, extra) end
  return out
end

---------------------------------------------------------------- BUG-409
T.test('BUG-409: water_geometry counts the brook tiles inside the rectangle, the inner ones and the centre distance', function()
  local emb = {294, 358}
  -- i1 18,22 (embark result): brook on the top row and the right column of the 4x4
  local g = S.water_geometry({{296, 358}, {297, 358}, {297, 359}}, emb, {4, 4})
  T.eq({g.n, g.core, g.d2}, {3, 0, 3}, 'edge only: nearest 1.5 tiles from the centre')
  g = S.water_geometry({{296, 358}, {296, 359}, {300, 359}}, emb, {4, 4})
  T.eq({g.n, g.core, g.d2}, {2, 1, 1}, 'one inner tile 0.5 tiles away; the tile beyond the box does not count')
  g = S.water_geometry({{1, 1}}, emb)
  T.eq({g.n, g.core, g.d2}, {0, 0, nil})
  g = S.water_geometry({{295, 359}}, emb, {3, 3})
  T.eq({g.n, g.core, g.d2}, {1, 1, 0}, 'the middle tile of a 3x3')
end)

T.test('BUG-409: a hover row whose brook lies only on the outer ring warns on water; an inner brook passes', function()
  local ex, ey = 8 * 16 + 6, 30 * 16 + 6
  local D = hover_fake({default = panel(), [(ex + 3) .. ',' .. ey] = panel('Brook: Yes')})
  local run, ctx = start(D, {v = 2, id = 'g1', mode = 'scan', hover = true, cands = {{8, 30}}})
  T.eq(run.state, 'done', run.msg)
  local r = ctx.results[1]
  T.eq(r.rec.water, 'brook')
  T.eq({r.rec.tiles.water_n, r.rec.tiles.water_core, r.rec.tiles.water_d2}, {1, 0, 3})
  local w = item(r, 'water')
  T.eq(w.res, 'warn'); T.ok(w.why:find('only on the edge tiles', 1, true) and w.why:find('about 72 steps', 1, true), w.why)
  D = hover_fake({default = panel(), [(ex + 1) .. ',' .. (ey + 1)] = panel('Brook: Yes')})
  run, ctx = start(D, {v = 2, id = 'g2', mode = 'scan', hover = true, cands = {{8, 30}}})
  r = ctx.results[1]
  T.eq(item(r, 'water').res, 'pass'); T.eq(r.rec.tiles.water_core, 1)
end)

---------------------------------------------------------------- BUG-411
T.test('BUG-411: a hover row merges the worst aquifer and the deepest soil of its tiles', function()
  local ex, ey = 8 * 16 + 6, 30 * 16 + 6
  local D = hover_fake({default = panel('Brook: Yes', 'Little soil'),
    [(ex + 2) .. ',' .. (ey + 2)] = panel('Brook: Yes', 'Very deep soil', 'Heavy aquifer'),
    [(ex + 1) .. ',' .. ey] = panel('Brook: Yes', 'Little soil', 'Light aquifer')})
  local run, ctx = start(D, {v = 2, id = 'w1', mode = 'scan', hover = true, cands = {{8, 30}}})
  T.eq(run.state, 'done', run.msg)
  local r = ctx.results[1]
  T.eq(r.rec.aquifer, 'heavy'); T.eq(r.rec.stone_soil, 'very_deep', 'the deepest soil, not the shallowest')
  T.eq(r.rec.tiles.aq_best, 'none'); T.ok(r.rec.tiles.worst_stone)
  T.eq(item(r, 'aquifer').res, 'fail')
  T.ok(item(r, 'aquifer').why:find('best none', 1, true), item(r, 'aquifer').why)
  T.eq(item(r, 'stone').res, 'fail'); T.ok(item(r, 'stone').why:find('deepest soil of the hovered tiles', 1, true))
  -- a placed rectangle keeps the best tile for stone (its popup is exact)
  local m = S.merge_tiles({soil = 'little', rivers = {}, warnings = {}}, {{soil = 'little'}, {soil = 'deep'}})
  T.eq(m.stone_soil, 'little')
  m = S.merge_tiles({soil = 'little', rivers = {}, warnings = {}}, {{soil = 'little'}, {soil = 'deep'}}, {worst_stone = true})
  T.eq(m.stone_soil, 'deep')
end)

---------------------------------------------------------------- BUG-410
T.test('BUG-410: sweep hovers the chosen tiles per world tile and keeps one compact row, brook absent is a warn', function()
  local ids = {}
  for _, st in ipairs(S.build({id = 's', mode = 'scan', hover = true, sweep = 4, cands = {{1, 2}, {3, 4}}}, CFG, LOADOUT)) do
    ids[#ids + 1] = st.id
  end
  T.eq(#ids, 14, '2 x (goto, embark, 4 hovers, record)')
  T.eq({ids[3], ids[6], ids[7]}, {'site.hover.1', 'site.hover.4', 'site.hover.read'})
  T.eq(#S.build({id = 's', mode = 'scan', hover = true, sweep = 1, cands = {{1, 2}}}, CFG, LOADOUT), 4)
  T.eq(#S.build({id = 's', mode = 'scan', hover = true, sweep = 9, cands = {{1, 2}}}, CFG, LOADOUT), 12)
  T.eq(#S.build({id = 's', mode = 'scan', hover = true, cands = {{1, 2}}}, CFG, LOADOUT), 19, 'no sweep: all 16')
  local ex, ey = 8 * 16 + 6, 30 * 16 + 6
  local D = hover_fake({default = panel(), [(ex + 3) .. ',' .. (ey + 3)] = panel(nil, 'Little soil', 'Light aquifer')})
  local run, ctx = start(D, {v = 2, id = 's1', mode = 'scan', hover = true, sweep = 4, cands = {{8, 30}}})
  T.eq(run.state, 'done', run.msg)
  local r = ctx.results[1]
  T.eq({r.sweep, r.hover, r.world, r.emb}, {true, true, {8, 30}, {ex, ey}})
  T.eq({r.items, r.parts, r.size}, {nil, nil, nil}, 'compact: no items, no parts')
  T.eq(r.rec.tiles.n, 4); T.eq(r.rec.aquifer, 'light')
  T.eq(r.rec.goblins, "9 days' travel", 'the goblins line is kept for the rank')
  T.eq(r.verdict, 'ok', 'size 4x4 is nominal; a missing brook is a warning: ' .. json.encode(r.fails) .. json.encode(r.unknown))
  local seen = false
  for _, w in ipairs(r.warns) do if w == 'water' then seen = true end end
  T.ok(seen, 'water warns (no brook in the sampled tiles): ' .. json.encode(r.warns))
end)

T.done()
