-- tools/embark/steps.lua: the embark procedure as data for runner.lua.
-- Every action is a vanilla UI action: a simulated click on visible text or on the map,
-- a right click, or a view-only write (camera centre, list selection) through `w`.
-- live = where the pattern was proven: 'run4-6' (v1 scripts did the same thing live) or
-- 'untested' (new in v2, never run in game). See README.md.
local V = require('embark.view')
local panel = require('embark.panel')
local checklist = require('embark.checklist')
local S = {}

local function cell(v, text, from_bottom)  -- exact cell match
  local cells, best = v:cells(), nil
  for _, c in ipairs(cells) do
    if c.text == text then
      best = c
      if not from_bottom then break end
    end
  end
  return best
end
S.cell = cell

-- queue a click on the middle of visible text; returns true if found
local function tap(ui, v, text, opt)
  opt = opt or {}
  local x, y
  local c = opt.exact and cell(v, text, opt.from_bottom)
  if c then x, y = c.x, c.y
  elseif not opt.exact then x, y = v:find(text, opt.occ, opt.from_bottom) end
  if not x then return false end
  ui:click_tile(x + #text // 2 + (opt.dx or 0), y, opt)
  return true
end
S.tap = tap

local function kind_in(v, ...)
  local k = v:kind()
  for _, want in ipairs({...}) do if k == want then return true end end
  return false
end

-- the popup's Abort button is the 'Abort' cell nearest to 'Confirm' (the bottom bar has
-- its own Abort button that leaves the embark screen: never click that one)
local function popup_abort(v)
  local cf = cell(v, 'Confirm')
  if not cf then return nil end
  local best
  for _, c in ipairs(v:cells()) do
    if c.text == 'Abort' and math.abs(c.y - cf.y) <= 3 and (not best or math.abs(c.y - cf.y) < math.abs(best.y - cf.y)) then
      best = c
    end
  end
  return best
end

-- right click on the map: zooms out (local view) or aborts placing
local function rclick(ui, cfg)
  ui:click_pct(cfg.world_click[1], cfg.world_click[2], {button = 'R', hover_ms = 300})
end

-- Screen-changing buttons (Confirm, Play now!, Embark!, I am ready!): click ONCE, then 'wait'
-- (runner: no try spent) until done() or the step timeout. DF needs many seconds to prepare the
-- map or load the fort, and a second click is never sent: v1 saw a fast double click crash DF
-- (scan2.sh). An ignored click therefore ends in the timeout. mem = the runner's per-step table.
local function press_once(ui, v, mem, text, opt)
  if mem[text] then return 'wait', 'clicked ' .. text .. ', waiting' end
  if not tap(ui, v, text, opt) then return nil, text .. ' not shown' end
  mem[text] = true
  return nil, 'clicked ' .. text
end
S.press_once = press_once

local function same_rect(v, ex, ey)
  local m = v.cs and v.cs.emb_min
  if m and m[1] == ex and m[2] == ey then return true end
  return false, 'rectangle at ' .. (m and (m[1] .. ',' .. m[2]) or '?') .. ', target ' .. ex .. ',' .. ey
end

---------------------------------------------------------------- title -> world map
-- Resumable (L0): a step whose screen is already behind us is skipped, so `newgame` can be re-run
-- after a failure. Live 53.16: clicking the world name first shows "Loading world to start new
-- game" (focus adopt_region) for minutes; only then comes "Select a game type".
local LATER = {
  ['title.new'] = {loading_world = true, game_type = true, world = true, ['local'] = true, placing = true},
  ['title.world'] = {loading_world = true, game_type = true, world = true, ['local'] = true, placing = true},
  ['title.fortress'] = {world = true, ['local'] = true, placing = true},
}
local function later(id, v) return LATER[id][v:kind()] == true end

-- BUG-245 (Run 15c/15d): "Start new game in existing world" lists same-named worlds (three "World: Zilirr?th"), each
-- with a folder row below it ("Portable Folder: region1" = <DF>/save, "Folder: region1" = AppData). A tap on the name
-- picks the topmost world. With --world-folder the run clicks the folder row instead: every row that shows
-- "folder:" followed by the folder name as a whole word; `portable` true/false keeps only that kind.
-- -> {{x, y, len, portable, text}} (x, y 0-based, len = the clicked text)
function S.folder_rows(v, folder)
  local out, want = {}, V.lower(tostring(folder or ''))
  if want == '' then return out end
  for y, line in ipairs(v.lines) do
    local l, init = V.lower(line), 1
    while true do
      local s, e = l:find('folder:', init, true)
      if not s then break end
      local sp, name = l:sub(e + 1):match('^( *)([^ ]+)')
      if name == want then
        local pre = l:sub(1, s - 1)
        local ps = pre:find('portable *$')
        local x0 = ps or s
        local x1 = e + #sp + #name
        out[#out + 1] = {x = x0 - 1, y = y - 1, len = x1 - x0 + 1, portable = ps ~= nil, text = line:sub(x0, x1)}
      end
      init = e + 1
    end
  end
  return out
end

-- the one folder row to click, else nil and why (none, or several and no --portable/--appdata to tell them apart)
function S.pick_folder(v, folder, portable)
  local rows, keep = S.folder_rows(v, folder), {}
  for _, r in ipairs(rows) do
    if portable == nil or r.portable == portable then keep[#keep + 1] = r end
  end
  if #keep == 1 then return keep[1] end
  local kinds = {}
  for _, r in ipairs(rows) do kinds[#kinds + 1] = r.portable and 'portable' or 'appdata' end
  if #keep == 0 then
    return nil, 'no row shows "' .. (portable and 'Portable ' or '') .. 'Folder: ' .. tostring(folder) .. '"' ..
      (#rows > 0 and (' (rows: ' .. table.concat(kinds, ', ') .. ')') or '')
  end
  return nil, #keep .. ' rows show the folder "' .. tostring(folder) .. '" (' .. table.concat(kinds, ', ') ..
    '): pass --portable or --appdata'
end

-- BUG-245: the title screen's region_choice (read only, embark.lua source().title.regions = {path, portable}) must
-- hold the folder (of that kind) when DFHack shows it; nil = fine or not shown
function S.region_check(title, folder, portable)
  local regs = type(title) == 'table' and title.regions
  if type(regs) ~= 'table' or #regs == 0 then return nil end
  local seen = {}
  for _, r in ipairs(regs) do
    local p = tostring(r.path or ''):gsub('\\', '/'):gsub('/+$', '')
    local name = p:match('([^/]+)$') or p
    seen[#seen + 1] = name .. (r.portable == true and ' (portable)' or r.portable == false and ' (appdata)' or '')
    if V.lower(name) == V.lower(tostring(folder)) and (portable == nil or r.portable == nil or r.portable == portable) then
      return nil
    end
  end
  return 'region_choice holds no world folder "' .. tostring(folder) .. '"' ..
    (portable == true and ' (portable)' or portable == false and ' (appdata)' or '') .. ': ' .. table.concat(seen, ', ')
end

function S.newgame(world, folder, portable)
  local new = 'Start new game in existing world'
  return {
    {id = 'title.new', live = 'run4-6', timeout_ms = 30000,
     wait = function(v) return v:has(new) or later('title.new', v) end,
     act = function(ui, v)
       if later('title.new', v) then return 'skip', 'already past the title' end
       tap(ui, v, new)
     end,
     done = function(v) return not v:has(new) end},
    {id = 'title.world', live = 'run4-6', timeout_ms = 30000,
     wait = function(v) return v:has(world) or (folder and #S.folder_rows(v, folder) > 0) or later('title.world', v) end,
     act = function(ui, v, ctx)
       if later('title.world', v) then return 'skip', 'world already chosen' end
       if folder then   -- BUG-245: the folder row, never the (shared) world name
         local bad = S.region_check(v.title, folder, portable)
         if bad then return 'fail', bad end
         local r, why = S.pick_folder(v, folder, portable)
         if not r then return 'fail', why end
         ui:click_tile(r.x + r.len // 2, r.y)
         ctx.results = ctx.results or {}
         ctx.results.world_row = {text = V.trim(r.text), x = r.x, y = r.y, portable = r.portable}
         return nil, 'clicked "' .. V.trim(r.text) .. '" (row ' .. r.y .. ')'
       end
       tap(ui, v, world)
     end,
     done = function(v) return not v:has(world) or v:has('Fortress') end},
    {id = 'title.fortress', live = 'L0', timeout_ms = 600000,  -- the world loads before this screen
     wait = function(v) return v:has('Fortress') or later('title.fortress', v) end,
     act = function(ui, v)
       if later('title.fortress', v) then return 'skip', 'game type already chosen' end
       tap(ui, v, 'Fortress', {exact = true})
     end,
     done = function(v) return not v:has('Select a game type') end},
    {id = 'title.load', live = 'run4-6', timeout_ms = 600000,  -- loading a big world takes minutes
     act = function() return 'wait', 'loading' end,
     done = function(v) return kind_in(v, 'world', 'local') or v:has('Skip tutorial'), 'loading' end},
    -- live L0: the world map shows up about one poll before the tutorial prompt is drawn, so
    -- look for the prompt for up to 20 polls (about 5 s) before skipping the step
    {id = 'title.tutorial', live = 'L0', optional = true,
     act = function(ui, v, ctx, w, mem)
       if v:has('Skip tutorial') then tap(ui, v, 'Skip tutorial'); mem.clicked = true return end
       mem.n = (mem.n or 0) + 1
       if mem.clicked or mem.n > 20 then return 'skip', 'no tutorial prompt' end
       return 'wait', 'waiting for the tutorial prompt'
     end,
     done = function(v, ctx, mem)
       if v:has('Skip tutorial') then return false, 'tutorial prompt shown' end
       return mem.clicked == true, 'no prompt yet'
     end},
    {id = 'title.okay', live = 'run4-6', optional = true,
     act = function(ui, v)
       if kind_in(v, 'world') and cell(v, 'Okay') then tap(ui, v, 'Okay', {exact = true}) return end
       return 'skip', 'no Okay popup'
     end,
     done = function(v) return not cell(v, 'Okay') end},
    {id = 'title.ready', live = 'run4-6', done = function(v) return kind_in(v, 'world'), v:kind() end},
  }
end

---------------------------------------------------------------- world map -> local view
-- closed loop: set the camera, click the map centre, read location.region_pos, learn the
-- offset and repeat (the centre pixel is not exactly the map centre, Run 6)
-- live 53.16: the zoomed tile is cs.zoom_world (zoom_cent // 16); location.region_pos only
-- changes once a rectangle is placed, so it is the fallback for old captures only
local function zoomed_tile(v)
  local cs = v.cs
  if not cs then return nil end
  return cs.zoom_world or cs.region
end
function S.goto_world(wx, wy, cfg)
  return {id = 'world.goto', live = 'L0', tries = 8, timeout_ms = 90000,
    wait = function(v) return kind_in(v, 'world', 'local', 'placing') end,
    act = function(ui, v, ctx, w)
      ui:release()
      if w and w.inject and ctx.injected ~= nil then w.inject(false); ctx.injected = nil end
      local r = zoomed_tile(v)
      if kind_in(v, 'local') and r and r[1] == wx and r[2] == wy then return 'done', 'already there' end
      ctx.w_new = false
      if not kind_in(v, 'world') then rclick(ui, cfg) return nil, 'zooming out' end
      local e = ctx.wofs or {0, 0}
      ctx.w_cam, ctx.w_new = {wx - e[1], wy - e[2]}, true
      w.camera('world', ctx.w_cam[1], ctx.w_cam[2])
      ui:wait(cfg.camera_ms)
      ui:click_pct(cfg.world_click[1], cfg.world_click[2])
    end,
    done = function(v, ctx)
      local r = zoomed_tile(v)
      if not kind_in(v, 'local') or not r then return false, 'not zoomed in' end
      if r[1] == wx and r[2] == wy then return true, 'at world tile ' .. wx .. ',' .. wy end
      if ctx.w_new then ctx.wofs = {r[1] - ctx.w_cam[1], r[2] - ctx.w_cam[2]} end
      return false, 'landed on ' .. r[1] .. ',' .. r[2]
    end}
end

---------------------------------------------------------------- local view -> rectangle
-- Live 53.16 (L0, DF on a hidden desktop, mouse focus claimed by W.mouse): in placing mode the
-- rectangle follows a mouse that is HELD over the map every frame, 16 px per embark tile:
--   rect_min = cam_local + k + floor((P - C) / s)    C = window centre px, s = cfg.local_tile_px
-- (measured k = -1,0 at 1716x1000). No camera write and no click are needed to place it: hold
-- the pixel for the target, read the rectangle, learn k from the first miss, hold again.
-- A click in placing mode does NOT move the rectangle; it opens the Confirm popup on it.
local function centre_px(ui)
  local w, h = ui.env.win()
  local tpx, tpy = ui.env.tile_px()
  return w * tpx // 2, h * tpy // 2
end
-- The cached OS cursor (input.lua probe) wins every render frame while the focus is claimed, so
-- when it lies over the map the camera is moved until THAT pixel is on the target and the hold
-- uses the same pixel: logic and render frames then agree. Otherwise a computed pixel is held.
local function over_map(ui, r)
  local w, h = ui.env.win()
  local tpx, tpy = ui.env.tile_px()
  return r and r[1] >= 40 and r[2] >= 60 and r[1] < w * tpx - 420 and r[2] < h * tpy - 90
end
-- the mouse injector and the cursor probe, once per run: true, msg while one of them was queued
local function mouse_ready(ui, ctx, w, cfg)
  if w and w.inject and ctx.injected == nil then  -- embark.lua mouse injector (render-time mouse)
    ctx.injected = w.inject(true)
    return true, 'mouse injector ' .. (ctx.injected and 'on' or 'unavailable')
  end
  if ctx.real == nil and ui.probe then
    if ui.real == nil then ui:probe(cfg.probe_frames or 150) return true, 'probing the cursor' end
    ctx.real = ui.real
  end
  return false
end

-- BUG-247: the ONE pixel every placement and hover holds: the probed OS cursor when it lies over the map, else the
-- middle of the window's centre tile. It never changes during a run; only the camera moves.
local function hold_pixel(ui, ctx, s)
  local cx, cy = centre_px(ui)
  local r = ctx.real
  if over_map(ui, r) then return {r[1], r[2]}, cx, cy end
  return {cx + s // 2, cy + s // 2}, cx, cy
end
S.hold_pixel = hold_pixel

-- BUG-247 (Run 15d on i4, 174x75 tiles): the old loop moved the HELD PIXEL by the learnt k and learnt k again from
-- every miss; when the rectangle did not follow, k grew and the held pixel ran out of the window (437,-16 ...
-- -7083,-9104) until 34/180 steps. Now: one fixed pixel P (hold_pixel), the camera at target - k - floor((P - C) / s),
-- one hold. A miss counts when the same camera shows the same wrong rectangle on two checks (DF still takes the
-- real OS cursor about one frame in 15, live L0). The first confirmed miss measures k once (|k| <= local_k_max,
-- else the rectangle is not following at all); the second fails with what was held and seen.
function S.place(ex, ey, cfg)
  local s = cfg.local_tile_px or 16
  local kmax = cfg.local_k_max or 48
  return {id = 'local.place', live = 'L0', tries = 8, timeout_ms = 120000,
    wait = function(v) return kind_in(v, 'local', 'placing') end,
    act = function(ui, v, ctx, w)
      if popup_abort(v) then ui:release(); tap(ui, v, 'Abort', {exact = true}); ctx.p_px = nil return nil, 'closing popup' end
      if kind_in(v, 'local') then
        ui:release()
        if not tap(ui, v, 'Embark', {exact = true, from_bottom = true}) then return nil, 'no Embark button' end
        ctx.p_px = nil
        return nil, 'Embark button'
      end
      local zc = v.cs and v.cs.cam_local
      if not zc then return 'fail', 'no local camera' end
      local busy, msg = mouse_ready(ui, ctx, w, cfg)
      if busy then return nil, msg end
      local k = ctx.pk or cfg.local_k or {0, 0}
      local p, cx, cy = hold_pixel(ui, ctx, s)
      local want = {ex - k[1] - (p[1] - cx) // s, ey - k[2] - (p[2] - cy) // s}
      if zc[1] ~= want[1] or zc[2] ~= want[2] then
        w.camera('local', want[1], want[2])
        ui:wait(cfg.local_camera_ms or 300)
      end
      ui:hold(p[1], p[2])
      ctx.p_px, ctx.p_c = {p[1], p[2]}, {cx, cy}
      return nil, 'camera ' .. want[1] .. ',' .. want[2] .. ', holding ' .. p[1] .. ',' .. p[2]
    end,
    done = function(v, ctx, mem)
      local m = v.cs and v.cs.emb_min
      if not m or not ctx.p_px then return false, 'no rectangle yet' end
      if not v.cs.choosing_embark or popup_abort(v) then return false, 'not placing' end
      if m[1] == ex and m[2] == ey then mem.seen = nil return true, 'rectangle at ' .. ex .. ',' .. ey end
      local p, zc, c = ctx.p_px, v.cs.cam_local, ctx.p_c
      if not zc then return false, 'no local camera' end
      local key = zc[1] .. ',' .. zc[2] .. '>' .. m[1] .. ',' .. m[2]
      if mem.seen ~= key then
        mem.seen = key
        return false, 'rectangle at ' .. m[1] .. ',' .. m[2] .. ' (camera ' .. zc[1] .. ',' .. zc[2] .. ')'
      end
      mem.seen = nil
      local base = {zc[1] + (p[1] - c[1]) // s, zc[2] + (p[2] - c[2]) // s}   -- rect_min - k
      local k = {m[1] - base[1], m[2] - base[2]}
      local o = mem.miss
      if o or math.abs(k[1]) > kmax or math.abs(k[2]) > kmax then
        local first = o and string.format('held %d,%d (camera %d,%d, rectangle %d,%d) and ', o.p[1], o.p[2], o.zc[1],
          o.zc[2], o.m[1], o.m[2]) or ''
        return 'fail', string.format('rectangle does not follow the mouse: %sheld %d,%d (camera %d,%d), rectangle stays ' ..
          'at %d,%d, target %d,%d; offset %d,%d%s; read the panels by hover instead: embark.py scan ... --hover',
          first, p[1], p[2], zc[1], zc[2], m[1], m[2], ex, ey, k[1], k[2],
          o and '' or (' beyond +-' .. kmax))
      end
      mem.miss = {p = {p[1], p[2]}, zc = {zc[1], zc[2]}, m = {m[1], m[2]}}
      ctx.pk = k
      return false, 'rectangle at ' .. m[1] .. ',' .. m[2] .. ': offset ' .. k[1] .. ',' .. k[2] .. ' measured'
    end}
end

---------------------------------------------------------------- read the site
-- Live 53.16 (L0): the right-hand site panel (biome, temperature, trees, surroundings, soil,
-- aquifer line, metals, flux, Neighbors with "Nearest site: ...") is drawn only in placing mode
-- WITHOUT the popup and only while the mouse is held over the map; the Confirm popup hides it.
-- So the read takes two views of the same rectangle: (1) the panel while local.place holds the
-- mouse on the target, (2) one click on that pixel opens the popup (the rectangle stays fixed)
-- and its warning sentences are merged in. Both views must show the target rectangle.
local function merge_popup(rec, pop)
  local seen = {}
  for _, w in ipairs(rec.warnings) do seen[w] = true end
  for _, w in ipairs(pop.warnings) do
    if not seen[w] then seen[w] = true; rec.warnings[#rec.warnings + 1] = w end
  end
  if seen.heavy_aquifer then rec.aquifer = 'heavy'
  elseif seen.light_aquifer and (rec.aquifer == nil or rec.aquifer == 'none') then rec.aquifer = 'light' end
  return rec
end
S.merge_popup = merge_popup

-- Live L0: the panel describes the region of the HOVERED tile, not the whole rectangle (the
-- popup covers the rectangle). With tiles=true the rectangle's 16 tiles are hovered one by one
-- (local.place on a shifted rectangle + site.tile) and merged here: water, trees and metals are
-- the best found, flux any, evil/savagery/aquifer the worst, neighbours the nearest per race.
local TREE_RANK = {none = 0, scarce = 1, sparse = 2, woodland = 3, heavily_forested = 4}
local EVIL_RANK = {good = 0, neutral = 1, evil = 2}
local SAV_RANK = {low = 0, medium = 1, high = 2}
local AQ_RANK = {none = 0, light = 1, varied = 2, heavy = 3}
-- soil depth, shallowest first: the stone criterion takes the best tile (a fort is dug where stone is near)
local SOIL_RANK = {none = 0, little = 1, shallow_sand = 2, shallow_clay = 2, some = 3, deep = 4, very_deep = 5,
  extremely_deep = 6}
local function merge_tiles(rec, tiles)
  if not tiles or #tiles == 0 then return rec end
  local seen_r, seen_m, seen_l = {}, {}, {}
  for _, r in ipairs(rec.rivers or {}) do seen_r[r] = true end
  for _, m in ipairs(rec.metals or {}) do seen_m[m] = true end
  for _, l in ipairs(rec.layers or {}) do seen_l[l] = true end
  rec.stone_soil = rec.soil
  local near = {}
  for _, n in ipairs(rec.neighbors or {}) do near[n.race] = n end
  local nw, nt, nmw, nter = 0, 0, 0, 0
  local wat = {}   -- BUG-250: the hovered tiles that showed a brook or river (the scan summary's brook distance)
  for _, t in ipairs(tiles) do
    if t.water and type(t.at) == 'table' and #wat < 16 then wat[#wat + 1] = {t.at[1], t.at[2]} end
    if t.terrain then   -- BUG-229: tiles whose biome DF does not embark on (mountain, lake, ocean)
      nter = nter + 1
      if t.terrain == 'mountain' or t.terrain == 'water' then nmw = nmw + 1 end
    end
    for _, r in ipairs(t.rivers or {}) do
      if not seen_r[r] then seen_r[r] = true; rec.rivers[#rec.rivers + 1] = r end
    end
    if t.water then nw = nw + 1 end
    if (TREE_RANK[t.trees] or -1) > (TREE_RANK[rec.trees] or -1) then rec.trees = t.trees end
    if (TREE_RANK[t.trees] or 0) >= 3 then nt = nt + 1 end
    for _, m in ipairs(t.metals or {}) do
      if not seen_m[m] then seen_m[m] = true; rec.metals = rec.metals or {}; rec.metals[#rec.metals + 1] = m end
    end
    for _, l in ipairs(t.layers or {}) do
      if not seen_l[l] then seen_l[l] = true; rec.layers = rec.layers or {}; rec.layers[#rec.layers + 1] = l end
    end
    if (SOIL_RANK[t.soil] or 99) < (SOIL_RANK[rec.stone_soil] or 99) then rec.stone_soil = t.soil end
    if t.flux then rec.flux = true end
    if (EVIL_RANK[t.evil] or -1) > (EVIL_RANK[rec.evil] or -1) then rec.evil = t.evil end
    if (SAV_RANK[t.savagery] or -1) > (SAV_RANK[rec.savagery] or -1) then rec.savagery = t.savagery end
    if (AQ_RANK[t.aquifer] or -1) > (AQ_RANK[rec.aquifer] or -1) then rec.aquifer = t.aquifer end
    for _, n in ipairs(t.neighbors or {}) do
      local o = near[n.race]
      if not o or (n.rank or 99) < (o.rank or 99) then near[n.race] = n end
    end
  end
  for _, w in ipairs(panel.WATER) do
    if seen_r[w] then rec.water = w break end
  end
  local nb = {}
  for _, n in pairs(near) do nb[#nb + 1] = n end
  table.sort(nb, function(a, b) return (a.rank or 99) < (b.rank or 99) end)
  if #nb > 0 then rec.neighbors = nb end
  rec.tiles = {n = #tiles, water = nw, wood = nt}
  if nter > 0 then rec.tiles.terrain, rec.tiles.mw = nter, nmw end
  if #wat > 0 then rec.tiles.water_at = wat end
  return rec
end
S.merge_tiles = merge_tiles

-- a stable text key of a panel record (facts the checklist uses)
local function json_key(rec)
  local nb = {}
  for _, n in ipairs(rec.neighbors or {}) do nb[#nb + 1] = tostring(n.race) .. ':' .. tostring(n.travel) end
  return table.concat({tostring(rec.trees), tostring(rec.water), tostring(rec.aquifer), tostring(rec.surroundings),
    tostring(rec.temperature), tostring(rec.soil), table.concat(rec.metals or {}, '+'), tostring(rec.flux),
    table.concat(nb, ',')}, '|')
end
S.json_key = json_key

-- read the panel of one hovered tile (the rectangle was shifted there by local.place)
function S.tile_read(n, rx, ry, at)
  return {id = 'site.tile.' .. n, live = 'L0', optional = true, timeout_ms = 15000,
    wait = function(v) return kind_in(v, 'placing') end,
    act = function(ui, v, ctx, w, mem)
      local ok = same_rect(v, rx, ry)
      local rec = ok and panel.parse(v)
      -- live L0: a single read once listed goblins that no other read of the same tile showed;
      -- accept a tile only when two consecutive reads agree
      local key = rec and rec.read > 0 and json_key(rec)
      if not key or key ~= mem.key then
        mem.key = key
        mem.n = (mem.n or 0) + 1
        if mem.n > 16 then return 'skip', 'tile ' .. n .. ' not read' end
        return 'wait', 'waiting for tile ' .. n
      end
      rec.at = at   -- BUG-250: the hovered embark tile (embark --here and the brook distance use it)
      ctx.tile_recs = ctx.tile_recs or {}
      ctx.tile_recs[#ctx.tile_recs + 1] = rec
      local gob = ''
      for _, nb in ipairs(rec.neighbors or {}) do
        if nb.race == 'goblins' then gob = ' goblins ' .. tostring(nb.travel) end
      end
      return 'done', 'tile ' .. n .. ': ' .. tostring(rec.trees) .. '/' .. tostring(rec.water or '-') .. '/' .. tostring(rec.aquifer) .. gob
    end,
    done = function() return false, 'reading tile' end}
end

-- a deep copy of a panel record (merge_tiles changes the record it gets)
local function copy(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, x in pairs(t) do o[k] = copy(x) end
  return o
end
S.copy = copy

-- where = {world, emb, size, hover} (hover scan, embark --here); default: the rectangle on the screen.
-- The row keeps the hovered tiles' records as `parts` ({at = {x, y}, ...}): embark --here gates a rectangle placed
-- by hand on them (BUG-250).
local function record(ctx, tag, v, rec, where)
  local parts = ctx.tile_recs
  rec = merge_tiles(rec, parts)
  ctx.tile_recs = nil
  if not where then
    local cs = v.cs
    where = {world = {cs.emb_min[1] // 16, cs.emb_min[2] // 16}, emb = {cs.emb_min[1], cs.emb_min[2]},
      size = cs.emb_max and {cs.emb_max[1] - cs.emb_min[1] + 1, cs.emb_max[2] - cs.emb_min[2] + 1}}
  end
  local verdict = checklist.evaluate(rec, ctx.rules, {world = where.world, size = where.size})
  ctx.results = ctx.results or {}
  local row = {tag = tag, world = where.world, emb = where.emb, size = where.size, hover = where.hover,
    verdict = verdict.verdict, score = verdict.score, fails = verdict.fails, warns = verdict.warns,
    unknown = verdict.unknown, items = verdict.items, rec = rec, parts = parts}
  ctx.results[#ctx.results + 1] = row
  ctx.last = row
  return 'done', tag .. ' ' .. verdict.verdict .. ' ' .. verdict.score
end

---------------------------------------------------------------- BUG-247: scan by hover only
-- Run 15d (i4): the rectangle followed the mouse only on the first hold after a change, the panel ALWAYS. The hover
-- scan never needs the rectangle: per candidate world tile it hovers a 4x4 grid of embark tiles (camera moved so
-- the fixed held pixel lies on the tile; hovered tile = camera + floor((P - C) / s) + hover_k) and reads each panel
-- twice alike; the row merges them (no size: the rectangle is placed later, by hand or by embark).
function S.enter_placing()
  return {id = 'local.embark', live = 'L0', tries = 4,
    wait = function(v) return kind_in(v, 'local', 'placing') end,
    act = function(ui, v)
      if kind_in(v, 'placing') then return 'done', 'placing' end
      if popup_abort(v) then tap(ui, v, 'Abort', {exact = true}) return nil, 'closing popup' end
      if not tap(ui, v, 'Embark', {exact = true, from_bottom = true}) then return nil, 'no Embark button' end
      return nil, 'Embark button'
    end,
    done = function(v) return kind_in(v, 'placing'), v:kind() end}
end

function S.hover_tile(n, tx, ty, cfg)
  local s = cfg.local_tile_px or 16
  return {id = 'site.hover.' .. n, live = 'untested', optional = true, timeout_ms = 20000, tries = 6,
    wait = function(v) return kind_in(v, 'placing') end,
    act = function(ui, v, ctx, w, mem)
      if popup_abort(v) then ui:release(); tap(ui, v, 'Abort', {exact = true}) mem.held = nil return nil, 'closing popup' end
      if not mem.held then
        local busy, msg = mouse_ready(ui, ctx, w, cfg)
        if busy then return nil, msg end
        local zc = v.cs and v.cs.cam_local
        if not zc then return 'fail', 'no local camera' end
        local kh = cfg.hover_k or {0, 0}
        local p, cx, cy = hold_pixel(ui, ctx, s)
        local cam = {tx - kh[1] - (p[1] - cx) // s, ty - kh[2] - (p[2] - cy) // s}
        w.camera('local', cam[1], cam[2])
        ui:wait(cfg.local_camera_ms or 300)
        ui:hold(p[1], p[2])
        mem.held, ctx.p_px, ctx.p_c = cam, {p[1], p[2]}, {cx, cy}
        return nil, 'hovering ' .. tx .. ',' .. ty .. ' (camera ' .. cam[1] .. ',' .. cam[2] .. ')'
      end
      local zc = v.cs and v.cs.cam_local
      if zc and (zc[1] ~= mem.held[1] or zc[2] ~= mem.held[2]) then mem.held = nil return nil, 'camera moved' end
      local rec = panel.parse(v)
      local key = rec.read > 0 and json_key(rec)
      if not key or key ~= mem.key then
        mem.key = key
        mem.n = (mem.n or 0) + 1
        if mem.n > 16 then return 'skip', 'tile ' .. tx .. ',' .. ty .. ' not read' end
        return 'wait', 'waiting for the panel of ' .. tx .. ',' .. ty
      end
      rec.at = {tx, ty}
      ctx.tile_recs = ctx.tile_recs or {}
      ctx.tile_recs[#ctx.tile_recs + 1] = rec
      return 'done', 'tile ' .. tx .. ',' .. ty .. ': ' .. tostring(rec.trees) .. '/' .. tostring(rec.water or '-') ..
        '/' .. tostring(rec.aquifer) .. '/' .. tostring(rec.soil)
    end,
    done = function() return false, 'reading tile' end}
end

function S.hover_record(tag, wx, wy, ex, ey)
  return {id = 'site.hover.read', live = 'untested',
    act = function(ui, v, ctx)
      ui:release()
      local tiles = ctx.tile_recs or {}
      local base = copy(tiles[1]) or {read = 0, warnings = {}, rivers = {}, neighbors = {}}
      base.at = nil
      return record(ctx, tag, v, base, {world = {wx, wy}, emb = {ex, ey}, hover = true})
    end}
end

local function hover_cand(out, c, cfg, tag)
  local ex = 16 * c[1] + (c[3] or cfg.default_local[1])
  local ey = 16 * c[2] + (c[4] or cfg.default_local[2])
  out[#out + 1] = S.goto_world(c[1], c[2], cfg)
  out[#out + 1] = S.enter_placing()
  local n = 0
  for dy = 0, 3 do
    for dx = 0, 3 do
      n = n + 1
      out[#out + 1] = S.hover_tile(n, ex + dx, ey + dy, cfg)
    end
  end
  out[#out + 1] = S.hover_record(tag, c[1], c[2], ex, ey)
end

---------------------------------------------------------------- BUG-250: embark --here
-- Run 15d: local.place failed, the player placed the rectangle by hand (and opened its Confirm popup), then had to
-- click Confirm himself: no checklist gate, no accept.log. embark --here takes the rectangle on the screen (popup
-- open) and gates it on the panels read before (embark.py passes the rows of earlier scan/embark results as
-- spec.prior): the hovered tiles that lie inside the rectangle, and a row of exactly this rectangle; the popup's
-- warning sentences are merged in. No panel of the rectangle read: refused.
local function inside(at, m, x)
  return type(at) == 'table' and at[1] >= m[1] and at[1] <= x[1] and at[2] >= m[2] and at[2] <= x[2]
end
function S.here_rec(prior, m, x)
  local parts, seen, exact = {}, {}, nil
  for _, row in ipairs(prior or {}) do
    local e, sz = row.emb, row.size
    if not exact and type(e) == 'table' and e[1] == m[1] and e[2] == m[2] and type(sz) == 'table'
      and sz[1] == x[1] - m[1] + 1 and sz[2] == x[2] - m[2] + 1 and type(row.rec) == 'table' then
      exact = row
    end
    for _, p in ipairs(row.parts or {}) do
      local k = type(p.at) == 'table' and (p.at[1] .. ',' .. p.at[2])
      if k and not seen[k] and inside(p.at, m, x) then seen[k] = true; parts[#parts + 1] = p end
    end
  end
  local base = exact and copy(exact.rec) or (parts[1] and copy(parts[1]))
  if not base then return nil end
  base.at = nil
  return {base = base, parts = parts, exact = exact ~= nil, tag = exact and exact.tag}
end

function S.here(tag, prior)
  return {id = 'site.here', live = 'untested', timeout_ms = 15000,
    wait = function(v) return kind_in(v, 'placing', 'local') end,
    act = function(ui, v, ctx)
      if not (cell(v, 'Confirm') and popup_abort(v)) then
        return 'fail', 'no Confirm popup: place the rectangle and click it so its Confirm popup is open, then embark --here'
      end
      local m, x = v.cs and v.cs.emb_min, v.cs and v.cs.emb_max
      if not (m and x) then return 'fail', 'no rectangle on the screen' end
      local pick = S.here_rec(prior, m, x)
      if not pick then
        return 'fail', string.format('no panel read for the rectangle %d,%d-%d,%d: scan it first (embark.py scan %d,%d ' ..
          '--hover or --tiles)', m[1], m[2], x[1], x[2], m[1] // 16, m[2] // 16)
      end
      ctx.here = {m[1], m[2]}
      ctx.warnings = ctx.warnings or {}
      local want = (x[1] - m[1] + 1) * (x[2] - m[2] + 1)
      if #pick.parts < want then
        ctx.warnings[#ctx.warnings + 1] = string.format('site.here: %d of %d tiles of the rectangle were hovered%s',
          #pick.parts, want, pick.exact and (', plus the read of ' .. tostring(pick.tag)) or '')
      end
      ctx.tile_recs = #pick.parts > 0 and pick.parts or nil
      return record(ctx, tag, v, merge_popup(pick.base, panel.parse(v)))
    end}
end
-- Stages (mem.stage): 'panel' (hovered; read the panel, then give the mouse focus back) ->
-- 'click' (unfocused: the rectangle no longer moves; if it is still the target, click it) ->
-- 'popup' (read the warnings; a popup on another rectangle is aborted and the read restarts).
-- The real OS cursor can win a frame while the focus is claimed (see local.place), hence the
-- re-checks and bounded retries.
function S.read_site(tag, ex, ey)
  return {id = 'site.read', live = 'L0', timeout_ms = 90000, tries = 16,
    wait = function(v) return kind_in(v, 'placing') end,
    act = function(ui, v, ctx, w, mem)
      local ok, why = same_rect(v, ex, ey)
      local p = ctx.p_px
      if not p then return 'fail', 'no held pixel (local.place did not run)' end
      local stage = mem.stage or 'panel'
      local function restart(msg)
        mem.retry = (mem.retry or 0) + 1
        if mem.retry > 4 then return 'fail', (why or 'rectangle on target') .. ': ' .. msg end
        mem.stage, mem.miss, mem.empty = 'panel', 0, 0
        ui:hold(p[1], p[2])
        return nil, msg .. ', retrying'
      end
      if stage == 'panel' then
        if popup_abort(v) then
          if not mem.retry then return 'fail', 'popup open before the panel was read' end
          tap(ui, v, 'Abort', {exact = true})
          ui:hold(p[1], p[2])
          return nil, 'closing a popup on the wrong rectangle'
        end
        if not ok then
          mem.miss = (mem.miss or 0) + 1
          if mem.miss < 40 then ui:hold(p[1], p[2]) return 'wait', why end
          return 'fail', why .. ': read not attributable to the target'
        end
        local rec = panel.parse(v)
        if rec.read == 0 then
          mem.empty = (mem.empty or 0) + 1
          if mem.empty < 8 then return 'wait', 'panel not drawn yet' end
        end
        local key = json_key(rec)  -- two consecutive reads must agree (see site.tile)
        if key ~= mem.pkey and (mem.empty or 0) < 8 then
          mem.pkey, mem.empty = key, (mem.empty or 0) + 1
          return 'wait', 'panel read once'
        end
        mem.panel, mem.stage = rec, 'click'
        if ctx.dump then ctx.dump('site-' .. tag .. '-panel', v) end
        -- live L0: on an existing site the panel says "Cannot embark on another site." and a
        -- click opens no popup: record the reject without clicking
        -- BUG-229: "Cannot embark entirely on water or mountains." is the same kind of refusal
        for _, wid in ipairs(rec.warnings) do
          if S.REFUSED[wid] then ui:release() return record(ctx, tag, v, rec) end
        end
        -- give the focus back NOW, in the frame whose capture showed the target: unfocused, the
        -- rectangle stays where it is (live L0); a later unfocus could catch a render frame
        ui:release()
        if w and w.unfocus then w.unfocus() end
        return nil, 'panel read (' .. rec.read .. ' facts), mouse released'
      elseif stage == 'click' then
        if popup_abort(v) then return restart('popup opened early') end
        if not ok then return restart('rectangle moved before the click') end
        mem.stage = 'popup'
        ui:click_px(p[1], p[2], {hover_ms = 100})
        return nil, 'opening the popup'
      end
      if not cell(v, 'Confirm') then
        -- BUG-229: DF answers the click with its refusal instead of the popup: record the reject, no retry
        local ref = ok and S.refusal(v)
        if ref then return record(ctx, tag, v, merge_popup(mem.panel, {warnings = {ref}})) end
        mem.wait_pop = (mem.wait_pop or 0) + 1
        if mem.wait_pop > 20 then return restart('no popup after the click') end
        return 'wait', 'waiting for the popup'
      end
      if not ok then
        tap(ui, v, 'Abort', {exact = true})
        return restart('popup on the wrong rectangle')
      end
      if ctx.dump then ctx.dump('site-' .. tag, v) end
      return record(ctx, tag, v, merge_popup(mem.panel, panel.parse(v)))
    end,
    done = function() return false, 'reading' end}
end

-- BUG-229: the warnings that mean DF refuses the rectangle (no popup follows a click there)
S.REFUSED = {cannot = true, water_mountain = true}
function S.refusal(v)
  for _, wid in ipairs(panel.parse(v).warnings) do
    if S.REFUSED[wid] then return wid end
  end
  return nil
end

-- close the popup with its own Abort (scan: next candidate; never the bottom-bar Abort)
function S.abort_popup()
  return {id = 'site.abort', live = 'run4-6',
    act = function(ui, v)
      ui:release()
      if not popup_abort(v) then return 'done', 'no popup' end
      tap(ui, v, 'Abort', {exact = true})
    end,
    done = function(v) return popup_abort(v) == nil end}
end

-- Refuse to embark unless every criterion passed or warned. A criterion the panel did not show
-- ('unknown') passes only if it is named in `waive` (embark.py --waive ID, checked by eye); a criterion that
-- FAILED passes only if it is named in `accept` with a reason (FR-08, embark.py --accept ID --reason TEXT: a
-- known trade-off such as no metal ore); there is no blanket waiver. Used waivers and acceptances (with their
-- reason) go into the run warnings.
-- BUG-248 (Run 15 Guildcleans, Earthboat): 'stone' was accepted on deep-soil sites and the forts later had no hard
-- stone for levers, mechanisms and moods. Waiving or accepting a criterion of checklist.NEEDS_PLAN ('stone') now
-- needs an explore-first plan (embark.py --explore-first TEXT: how the fort reaches stone in its first season); the
-- plan goes into the warnings.
function S.gate(waive, accept, plan)
  local named, took, why = {}, {}, {}
  for _, id in ipairs(waive or {}) do named[id] = true end
  for _, a in ipairs(accept or {}) do
    local id = type(a) == 'table' and a.id or a
    took[id], why[id] = true, type(a) == 'table' and a.why or nil
  end
  local planned = type(plan) == 'string' and #plan:gsub('^%s+', ''):gsub('%s+$', '') >= 10
  return {id = 'site.gate', live = 'untested',
    act = function(ui, v, ctx)
      for id in pairs(named) do
        if not checklist.WAIVABLE_SET[id] then return 'fail', 'cannot waive ' .. tostring(id) end
      end
      for id in pairs(took) do
        if not checklist.ACCEPTABLE_SET[id] then return 'fail', 'cannot accept ' .. tostring(id) end
        if type(why[id]) ~= 'string' or #why[id]:gsub('^[ \t]+', '') < 3 then
          return 'fail', 'accepting ' .. id .. ' needs a reason'
        end
      end
      for _, set in ipairs({named, took}) do
        for id in pairs(set) do
          if checklist.NEEDS_PLAN[id] and not planned then
            return 'fail', (set == named and 'waiving ' or 'accepting ') .. id .. ' needs an explore-first plan ' ..
              '(embark.py --explore-first TEXT, 10+ characters): ' .. checklist.NEEDS_PLAN[id]
          end
        end
      end
      local r = ctx.last
      if not r then return 'fail', 'no site read' end
      local refused, accepted = {}, {}
      for _, id in ipairs(r.fails) do
        if took[id] then accepted[#accepted + 1] = id else refused[#refused + 1] = id end
      end
      if #refused > 0 then return 'fail', 'site rejected (fails: ' .. table.concat(refused, ',') .. ')' end
      local open, used = {}, {}
      for _, id in ipairs(r.unknown) do
        if named[id] or took[id] then used[#used + 1] = id else open[#open + 1] = id end
      end
      if #open > 0 then return 'fail', 'unknown and not waived: ' .. table.concat(open, ',') end
      ctx.warnings = ctx.warnings or {}
      if #used > 0 then ctx.warnings[#ctx.warnings + 1] = 'site.gate: waived ' .. table.concat(used, ',') end
      for _, id in ipairs(accepted) do
        ctx.warnings[#ctx.warnings + 1] = 'site.gate: accepted ' .. id .. ' (' .. why[id] .. ')'
      end
      if planned and (named.stone or took.stone) then
        ctx.warnings[#ctx.warnings + 1] = 'site.gate: explore first (' .. plan .. ')'
      end
      local notes = {}
      if #used > 0 then notes[#notes + 1] = 'waived ' .. table.concat(used, ',') end
      if #accepted > 0 then notes[#notes + 1] = 'accepted ' .. table.concat(accepted, ',') end
      return 'done', r.verdict .. (#notes > 0 and (', ' .. table.concat(notes, ', ')) or '')
    end}
end

-- the popup is still open from site.read; the rectangle must not have moved since
function S.confirm(ex, ey)
  return {id = 'site.confirm', live = 'run4-6', timeout_ms = 180000, tries = 3,
    wait = function(v) return cell(v, 'Confirm') ~= nil end,
    act = function(ui, v, ctx, w, mem)
      if not mem.Confirm then
        local here = ctx.here or {}   -- embark --here: the rectangle site.here read
        local ok, why = same_rect(v, ex or here[1] or -1, ey or here[2] or -1)
        if not ok then return 'fail', why end
        -- the popup freezes the rectangle; drop the mouse injector before DF changes screens
        ui:release()
        if w and w.inject and ctx.injected ~= nil then w.inject(false); ctx.injected = nil end
      end
      return press_once(ui, v, mem, 'Confirm', {exact = true})
    end,
    done = function(v) return v:kind():sub(1, 4) == 'prep', 'preparing map' end}
end

---------------------------------------------------------------- prepare carefully
function S.prepare(play_now)
  local label = play_now and 'Play now!' or 'Prepare for the journey carefully'
  return {id = 'prep.choice', live = 'run4-6', timeout_ms = play_now and 600000 or 30000, tries = 3,
    wait = function(v) return v:has(label) end,
    act = function(ui, v, ctx, w, mem) return press_once(ui, v, mem, label) end,
    done = function(v)
      if play_now then return kind_in(v, 'fort'), 'loading fort' end
      return kind_in(v, 'prep_dwarves'), v:kind()
    end}
end

local function role_done(u, role)
  if u.picks <= 0 then return true end
  for _, sk in ipairs(role.skills) do
    if (u.lv[sk[1]] or 0) < sk[2] then return false end
  end
  return true
end

-- one step per dwarf: select it (click the list row; after 2 misses select it like
-- DFHack's startdwarf overlay does, startdwarf.lua:48), then click skill rows until the
-- role is complete or no picks are left. Verified by reading skill levels and picks.
function S.skills(i, role, cfg)
  local c = cfg.citizens
  return {id = 'prep.skills.' .. i, live = 'untested', tries = 80, stale = 4, timeout_ms = 180000,
    wait = function(v) return kind_in(v, 'prep_dwarves') and v.prep ~= nil end,
    act = function(ui, v, ctx, w)
      local p = v.prep
      if p.selected ~= i - 1 then
        ctx.sel_miss = (ctx.sel_miss or 0) + 1
        if ctx.sel_miss <= 2 then ui:click_tile(c[1], c[2] + (i - 1) * c[3]) else w.select_unit(i - 1) end
        return nil, 'selecting dwarf ' .. i
      end
      ctx.sel_miss = 0
      local u = p.units[i]
      if not u then return 'skip', 'no dwarf ' .. i end
      if role_done(u, role) then return 'done', role.role end
      for _, sk in ipairs(role.skills) do
        if (u.lv[sk[1]] or 0) < sk[2] then
          local cap = ctx.caption(sk[1])
          if tap(ui, v, cap, {exact = true}) or tap(ui, v, cap) then return nil, cap end
          return nil, cap .. ' not on screen'
        end
      end
    end,
    done = function(v)
      local u = v.prep and v.prep.units[i]
      if not u then return false, 'no data' end
      return role_done(u, role), 'picks left ' .. u.picks
    end,
    progress = function(v)
      local u = v.prep and v.prep.units[i]
      if not u then return '' end
      local s = 0
      for _, l in pairs(u.lv) do s = s + l end
      return (v.prep.selected or -1) .. ':' .. u.picks .. ':' .. s
    end}
end

function S.tab(name, kind, cfg)
  return {id = 'prep.tab.' .. name, live = 'untested', tries = 4,
    wait = function(v) return v:kind():sub(1, 4) == 'prep' end,
    act = function(ui, v)
      if kind_in(v, kind) then return 'done', 'already on ' .. name end
      if not tap(ui, v, cfg.tabs[name], {exact = true}) then return nil, 'tab ' .. cfg.tabs[name] .. ' not shown' end
    end,
    done = function(v) return kind_in(v, kind), v:kind() end}
end

-- click an item/animal row `add` times; a click counts when points_remaining drops.
-- optional: a missing row is logged and the run goes on. entry.rest: buy until a click
-- no longer lowers the points (spends the leftovers; Run 6 left 324 points unspent).
function S.buy(entry, kind, cfg)
  local name = entry.name
  return {id = 'prep.buy.' .. name:gsub('[^A-Za-z0-9]', '_'), live = 'untested', optional = true,
    tries = (entry.add or 1) * 3 + 3, stale = 3, timeout_ms = entry.rest and 900000 or 180000,
    settle_ms = cfg.buy_settle_ms,
    wait = function(v) return kind_in(v, kind) and v.prep ~= nil end,
    act = function(ui, v, ctx)
      ctx.bought = ctx.bought or {}
      local got = ctx.bought[name] or 0
      if got >= (entry.add or 1) then return 'done', name .. ' x' .. got end
      if v.prep.points < (entry.min_points or 1) then return 'done', 'no points left' end
      local x, y
      for _, n in ipairs({name, table.unpack(entry.alt or {})}) do
        x, y = v:find(n)
        if not x then x, y = v:find(n:sub(1, 1):upper() .. n:sub(2)) end
        if x then break end
      end
      if not x then return nil, name .. ' not listed' end
      local px = cfg.buy.abs_x or (x + cfg.buy.dx)
      ui:click_tile(px, y, {hover_ms = cfg.buy_hover_ms, after_ms = cfg.buy_after_ms})
      ctx.buy_click = {name, v.prep.points}
    end,
    done = function(v, ctx)
      local bc = ctx.buy_click
      ctx.buy_click = nil
      if bc and v.prep.points < bc[2] then ctx.bought[bc[1]] = (ctx.bought[bc[1]] or 0) + 1
      elseif bc and entry.rest then return true, 'cannot buy more ' .. name .. ', points ' .. v.prep.points end
      local got = ctx.bought[name] or 0
      return got >= (entry.add or 1) or v.prep.points <= 0, name .. ' x' .. got .. ', points ' .. v.prep.points
    end,
    progress = function(v) return v.prep.points end}
end

function S.embark(allow_unspent)
  return {id = 'prep.embark', live = 'untested', timeout_ms = 600000, tries = 3,
    wait = function(v) return v:kind():sub(1, 4) == 'prep' or kind_in(v, 'fort') end,
    act = function(ui, v, ctx, w, mem)
      if kind_in(v, 'fort') then return 'done', 'fort loaded' end
      if mem['I am ready!'] then return 'wait', 'loading the fort' end
      if v:has('I am ready!') or v:has('Are you sure?') then
        if allow_unspent then return press_once(ui, v, mem, 'I am ready!') end
        tap(ui, v, 'Go back')
        return 'fail', 'DF warns about unspent points or unpicked skills'
      end
      if not mem['Embark!'] and v.prep and v.prep.points > 0 and not allow_unspent then
        ctx.warnings = ctx.warnings or {}
        ctx.warnings[#ctx.warnings + 1] = 'points left: ' .. v.prep.points
      end
      return press_once(ui, v, mem, 'Embark!', {exact = true})
    end,
    done = function(v) return kind_in(v, 'fort'), 'waiting for the map' end}
end

-- live L6 (Perplexrooms): the kernel erased the intro popup ("... Strike the earth!") from the popup
-- vector and no dwarf ever took a job; Okay clicked like a player starts the fort (Castlerisen,
-- Paddletribes). So the embark run ends by clicking it, before `dfllm adopt`.
-- BUG-246 (Run 15c, --play-now): the popup that stayed open read "A Dwarven Outpost ... Okay" without a visible
-- "Strike the earth", and the fort shows up a few polls before the popup is drawn. So any of these markers is the
-- intro, the step looks for it for intro_polls polls (about 10 s) before it says there is none, and Okay is
-- clicked again (at most 3 times) when the popup is still open 12 polls after a click. Okay is clicked only while a
-- marker is shown.
S.INTRO = {'Strike the earth', 'Dwarven Outpost', 'expedition has arrived'}
function S.intro_shown(v)
  for _, m in ipairs(S.INTRO) do
    if v:has(m) then return m end
  end
  return nil
end
function S.intro(cfg)
  local polls = (cfg and cfg.intro_polls) or 40
  return {id = 'fort.intro', live = 'L6', timeout_ms = 120000, tries = 4, optional = true,
    wait = function(v) return kind_in(v, 'fort') end,
    act = function(ui, v, ctx, w, mem)
      local m = S.intro_shown(v)
      if not m then
        if mem.clicks then return 'done', 'intro popup closed' end
        mem.n = (mem.n or 0) + 1
        if mem.n > polls then return 'done', 'no intro popup' end
        return 'wait', 'waiting for the intro popup'
      end
      if (mem.clicks or 0) >= 3 then return 'fail', 'intro popup ("' .. m .. '") still open after 3 clicks on Okay' end
      mem.since = (mem.since or 0) + 1
      if mem.clicks and mem.since < 12 then return 'wait', 'clicked Okay, waiting' end
      if not cell(v, 'Okay') then return 'wait', 'intro popup ("' .. m .. '") without an Okay button yet' end
      tap(ui, v, 'Okay', {exact = true})
      mem.clicks, mem.since, mem.mark = (mem.clicks or 0) + 1, 0, m
      return nil, 'clicked Okay on the intro popup ("' .. m .. '")'
    end,
    done = function(v, ctx, mem)
      if S.intro_shown(v) then return false, 'intro popup open' end
      if mem.clicks then return true, 'intro popup ("' .. tostring(mem.mark) .. '") closed by Okay' end
      return false, 'no intro popup yet'
    end}
end

---------------------------------------------------------------- BUG-250: save under a new name
-- Run 15c/15d: "Save and continue playing" under a new name had no tool. Live: simulateInput LEAVESCREEN does not
-- open the Esc menu in fort mode (15c), {_STRING = ...} types nothing into the name field, STRING_A<code> per
-- character plus SELECT does (15d). So: fort.menu waits for the Esc menu (embark.py save-as posts one Esc key to
-- this DF's window, as a player presses it), the menu entry is clicked once, the old name is erased (STRING_A000 =
-- backspace) and the new one typed key by key, the field must show it before SELECT, and the run ends when
-- dfhack.getSavePath() names the new folder and the menu is gone.
S.SAVE_LABEL = 'Save and continue playing'
local function save_named(v, name)
  local p = tostring(v.save_path or ''):gsub('\\', '/')
  return p:sub(-(#name + 1)) == '/' .. name
end
S.save_named = save_named

function S.save_steps(name, cfg)
  local back = (cfg and cfg.save_erase) or 48
  return {
    -- fort.menu logs whether the menu was open; embark.py posts Esc only during fort.menu.wait after the log line
    -- 'fort.menu: Esc menu not open' (an Esc on an open menu would close it)
    {id = 'fort.menu', live = 'untested',
     wait = function(v) return kind_in(v, 'fort') end,
     act = function(ui, v)
       if v:has(S.SAVE_LABEL) then return 'done', 'Esc menu open' end
       return 'done', 'Esc menu not open'
     end},
    {id = 'fort.menu.wait', live = 'untested', timeout_ms = 60000,
     wait = function(v) return kind_in(v, 'fort') end,
     act = function(ui, v)
       if v:has(S.SAVE_LABEL) then return 'done', 'Esc menu open' end
       return 'wait', 'waiting for the Esc menu (press Esc in DF; embark.py save-as posts it)'
     end,
     done = function(v) return v:has(S.SAVE_LABEL), 'Esc menu not open' end},
    {id = 'fort.save', live = 'untested', timeout_ms = 30000, tries = 3,
     wait = function(v) return v:has(S.SAVE_LABEL) end,
     act = function(ui, v, ctx, w, mem) return press_once(ui, v, mem, S.SAVE_LABEL, {exact = true}) end,
     done = function(v) return not v:has(S.SAVE_LABEL), 'menu still shown' end},
    {id = 'fort.save.name', live = 'untested', timeout_ms = 120000, tries = 3,
     wait = function(v) return kind_in(v, 'fort') and not v:has(S.SAVE_LABEL) end,
     act = function(ui, v, ctx, w, mem)
       if not mem.typed then
         for _ = 1, back do ui:key('STRING_A000', {after_ms = 20}) end
         for i = 1, #name do ui:key(string.format('STRING_A%03d', name:byte(i)), {after_ms = 40}) end
         mem.typed = true
         return nil, 'typed "' .. name .. '"'
       end
       if not mem.sel then
         if not v:has(name) then return 'fail', 'the name field does not show "' .. name .. '" after typing' end
         ui:key('SELECT')
         mem.sel = true
         return nil, 'SELECT'
       end
       return 'wait', 'saving'
     end,
     done = function(v, ctx, mem) return mem.sel == true, 'name typed' end},
    {id = 'fort.save.done', live = 'untested', timeout_ms = 600000,
     act = function(ui, v)
       if save_named(v, name) and kind_in(v, 'fort') and not v:has(S.SAVE_LABEL) then
         return 'done', 'saved as ' .. tostring(v.save_path)
       end
       return 'wait', 'saving (save path ' .. tostring(v.save_path) .. ')'
     end,
     done = function(v) return save_named(v, name) and not v:has(S.SAVE_LABEL), 'save path ' .. tostring(v.save_path) end},
  }
end

---------------------------------------------------------------- run specs
-- spec = {v=2, id, mode='newgame'|'scan'|'embark'|'here'|'prep'|'saveas', world='Zilirr', world_folder, portable,
--         cands={{wx,wy,lx,ly}}, hover=bool, site={wx,wy,lx,ly}, waive={criterion ids}, accept={{id, why}},
--         explore_first=TEXT, prior={rows of earlier results}, name=save folder, play_now=bool, allow_unspent=bool}
local function place_and_read(out, c, cfg, tag, tiles)
  local ex = 16 * c[1] + (c[3] or cfg.default_local[1])
  local ey = 16 * c[2] + (c[4] or cfg.default_local[2])
  out[#out + 1] = S.goto_world(c[1], c[2], cfg)
  if tiles then  -- hover every tile of the target rectangle (hovered tile = rect min + hover offset)
    local h = cfg.hover_offset or {1, 0}
    local n = 0
    for dy = 0, 3 do
      for dx = 0, 3 do
        n = n + 1
        local rx, ry = ex + dx - h[1], ey + dy - h[2]
        local st = S.place(rx, ry, cfg)
        st.id, st.optional = 'local.place.t' .. n, true
        out[#out + 1] = st
        out[#out + 1] = S.tile_read(n, rx, ry, {ex + dx, ey + dy})
      end
    end
  end
  out[#out + 1] = S.place(ex, ey, cfg)
  out[#out + 1] = S.read_site(tag, ex, ey)
  return ex, ey
end

local function prep_steps(out, spec, cfg, loadout)
  out[#out + 1] = S.prepare(spec.play_now)
  if spec.play_now then out[#out + 1] = S.intro(cfg); return end
  for i, role in ipairs(loadout.roles) do out[#out + 1] = S.skills(i, role, cfg) end
  out[#out + 1] = S.tab('items', 'prep_items', cfg)
  for _, it in ipairs(loadout.items) do out[#out + 1] = S.buy(it, 'prep_items', cfg) end
  out[#out + 1] = S.tab('animals', 'prep_animals', cfg)
  for _, a in ipairs(loadout.animals) do out[#out + 1] = S.buy(a, 'prep_animals', cfg) end
  out[#out + 1] = S.tab('items', 'prep_items', cfg)
  for _, n in ipairs(loadout.rest) do out[#out + 1] = S.buy({name = n, add = 999, rest = true}, 'prep_items', cfg) end
  out[#out + 1] = S.embark(spec.allow_unspent)
  out[#out + 1] = S.intro(cfg)
end

function S.build(spec, cfg, loadout)
  if spec.accept_review ~= nil then error('accept_review was removed: name each waived criterion in waive') end
  local out = {}
  if spec.mode == 'newgame' then
    out = S.newgame(spec.world, spec.world_folder, spec.portable)
  elseif spec.mode == 'scan' then
    for n, c in ipairs(spec.cands or {}) do
      if spec.hover then   -- BUG-247: panels by hover only, no rectangle
        hover_cand(out, c, cfg, spec.id .. '-' .. n)
      else
        place_and_read(out, c, cfg, spec.id .. '-' .. n, spec.tiles == true)
        out[#out + 1] = S.abort_popup()
      end
    end
  elseif spec.mode == 'embark' then
    -- read, gate and confirm the same placed rectangle; the popup stays open in between
    local ex, ey = place_and_read(out, spec.site, cfg, spec.id, spec.tiles ~= false)
    out[#out + 1] = S.gate(spec.waive, spec.accept, spec.explore_first)
    out[#out + 1] = S.confirm(ex, ey)
    prep_steps(out, spec, cfg, loadout)
  elseif spec.mode == 'here' then  -- BUG-250: the rectangle on the screen (popup open), gated on earlier reads
    out[#out + 1] = S.here(spec.id, spec.prior)
    out[#out + 1] = S.gate(spec.waive, spec.accept, spec.explore_first)
    out[#out + 1] = S.confirm()
    prep_steps(out, spec, cfg, loadout)
  elseif spec.mode == 'saveas' then  -- BUG-250
    if type(spec.name) ~= 'string' or not spec.name:match('^[%w][%w _%-]*$') then
      error('saveas: spec.name must be letters, digits, space, _ or -')
    end
    out = S.save_steps(spec.name, cfg)
  elseif spec.mode == 'prep' then
    prep_steps(out, spec, cfg, loadout)
  elseif spec.mode == 'steps' then  -- Lua-built step list (embark.lua 'click')
    out = spec.steps
  elseif spec.mode == 'load' then   -- K2: a saved fort from the title screen (loadsave.lua)
    out = require('embark.loadsave').steps(spec, cfg)
  else
    error('unknown mode ' .. tostring(spec.mode))
  end
  return out
end

return S
