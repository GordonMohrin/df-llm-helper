-- tools/embark/steps.lua: the embark procedure as data for runner.lua.
-- Every action is a vanilla UI action: a simulated click on visible text or on the map,
-- a right click, or a view-only write (camera centre, list selection) through `w`.
-- live = where the pattern was proven: 'run4-6' (v1 scripts did the same thing live) or
-- 'untested' (new in v2, never run in game). See README.md.
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
function S.newgame(world)
  local new = 'Start new game in existing world'
  return {
    {id = 'title.new', live = 'run4-6', timeout_ms = 30000,
     wait = function(v) return v:has(new) end,
     act = function(ui, v) tap(ui, v, new) end,
     done = function(v) return not v:has(new) end},
    {id = 'title.world', live = 'run4-6', timeout_ms = 30000,
     wait = function(v) return v:has(world) end,
     act = function(ui, v) tap(ui, v, world) end,
     done = function(v) return not v:has(world) or v:has('Fortress') end},
    {id = 'title.fortress', live = 'run4-6', timeout_ms = 30000,
     wait = function(v) return v:has('Fortress') end,
     act = function(ui, v) tap(ui, v, 'Fortress', {exact = true}) end,
     done = function(v) return not v:has('Select a game type') end},
    {id = 'title.load', live = 'run4-6', timeout_ms = 600000,  -- loading a big world takes minutes
     act = function() return 'wait', 'loading' end,
     done = function(v) return kind_in(v, 'world', 'local') or v:has('Skip tutorial'), 'loading' end},
    {id = 'title.tutorial', live = 'run4-6', optional = true,
     act = function(ui, v)
       if v:has('Skip tutorial') then tap(ui, v, 'Skip tutorial') return end
       return 'skip', 'no tutorial prompt'
     end,
     done = function(v) return not v:has('Skip tutorial') end},
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
function S.goto_world(wx, wy, cfg)
  return {id = 'world.goto', live = 'run4-6', tries = 8, timeout_ms = 90000,
    wait = function(v) return kind_in(v, 'world', 'local', 'placing') end,
    act = function(ui, v, ctx, w)
      local r = v.cs and v.cs.region
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
      local r = v.cs and v.cs.region
      if not kind_in(v, 'local') or not r then return false, 'not zoomed in' end
      if r[1] == wx and r[2] == wy then return true, 'at world tile ' .. wx .. ',' .. wy end
      if ctx.w_new then ctx.wofs = {r[1] - ctx.w_cam[1], r[2] - ctx.w_cam[2]} end
      return false, 'landed on ' .. r[1] .. ',' .. r[2]
    end}
end

---------------------------------------------------------------- local view -> rectangle
-- rectangle min = camera + k (k depends on the window; Run 6: -7,0). Measure k after
-- the first click, then place exactly.
function S.place(ex, ey, cfg)
  return {id = 'local.place', live = 'run4-6', tries = 10, timeout_ms = 120000,
    wait = function(v) return kind_in(v, 'local', 'placing') end,
    act = function(ui, v, ctx, w)
      local ab = popup_abort(v)
      if ab then tap(ui, v, 'Abort', {exact = true}); ctx.p_new = false return nil, 'closing popup' end
      if kind_in(v, 'local') then
        if not tap(ui, v, 'Embark', {exact = true, from_bottom = true}) then return nil, 'no Embark button' end
        ctx.p_new = false
        return nil, 'Embark button'
      end
      local k = ctx.pk or cfg.place_k
      ctx.p_cam, ctx.p_new = {ex - k[1], ey - k[2]}, true
      w.camera('local', ctx.p_cam[1], ctx.p_cam[2])
      ui:wait(cfg.camera_ms)
      ui:click_px(cfg.place_px[1], cfg.place_px[2], {hover_ms = cfg.place_hover_ms})
    end,
    done = function(v, ctx)
      local m = v.cs and v.cs.emb_min
      if not m or not ctx.p_cam then return false, 'no rectangle yet' end
      if ctx.p_new and m[1] == ex and m[2] == ey then return true, 'rectangle at ' .. ex .. ',' .. ey end
      if ctx.p_new then ctx.pk = {m[1] - ctx.p_cam[1], m[2] - ctx.p_cam[2]} end
      return false, 'rectangle at ' .. m[1] .. ',' .. m[2]
    end}
end

---------------------------------------------------------------- read the site
-- ONE capture while the Confirm popup is open: the click fixed the rectangle, so popup, panel,
-- Neighbors section and cs all describe the placed rectangle (v1 probe.sh, Runs 4-5, read popup
-- and panel together this way; RUN6-START.md: the right panel lists aquifer, trees, metals,
-- soil and the neighbours with distances). Without the popup the rectangle follows the mouse,
-- so the rectangle must still be the target (ex, ey) that local.place verified.
function S.read_site(tag, ex, ey)
  return {id = 'site.read', live = 'run4-6', timeout_ms = 15000,
    wait = function(v) return cell(v, 'Confirm') ~= nil end,
    act = function(ui, v, ctx)
      local ok, why = same_rect(v, ex, ey)
      if not ok then return 'fail', why .. ': read not attributable to the target' end
      local rec = panel.parse(v)
      local cs = v.cs
      local world = {cs.emb_min[1] // 16, cs.emb_min[2] // 16}
      local size = cs.emb_max and {cs.emb_max[1] - cs.emb_min[1] + 1, cs.emb_max[2] - cs.emb_min[2] + 1}
      local verdict = checklist.evaluate(rec, ctx.rules, {world = world, size = size})
      ctx.results = ctx.results or {}
      local row = {tag = tag, world = world, emb = {cs.emb_min[1], cs.emb_min[2]}, size = size,
        verdict = verdict.verdict, score = verdict.score, fails = verdict.fails, warns = verdict.warns,
        unknown = verdict.unknown, items = verdict.items, rec = rec}
      ctx.results[#ctx.results + 1] = row
      ctx.last = row
      if ctx.dump then ctx.dump('site-' .. tag, v) end
      return 'done', tag .. ' ' .. verdict.verdict .. ' ' .. verdict.score
    end}
end

-- close the popup with its own Abort (scan: next candidate; never the bottom-bar Abort)
function S.abort_popup()
  return {id = 'site.abort', live = 'run4-6',
    act = function(ui, v)
      if not popup_abort(v) then return 'done', 'no popup' end
      tap(ui, v, 'Abort', {exact = true})
    end,
    done = function(v) return popup_abort(v) == nil end}
end

-- Refuse to embark unless every criterion passed or warned. A criterion the panel did not show
-- ('unknown') passes only if it is named in `waive` (embark.py --waive ID, checked by eye);
-- there is no blanket waiver. Used waivers go into the run warnings.
function S.gate(waive)
  local named = {}
  for _, id in ipairs(waive or {}) do named[id] = true end
  return {id = 'site.gate', live = 'untested',
    act = function(ui, v, ctx)
      for id in pairs(named) do
        if not checklist.WAIVABLE_SET[id] then return 'fail', 'cannot waive ' .. tostring(id) end
      end
      local r = ctx.last
      if not r then return 'fail', 'no site read' end
      if #r.fails > 0 then return 'fail', 'site rejected (fails: ' .. table.concat(r.fails, ',') .. ')' end
      local open, used = {}, {}
      for _, id in ipairs(r.unknown) do
        if named[id] then used[#used + 1] = id else open[#open + 1] = id end
      end
      if #open > 0 then return 'fail', 'unknown and not waived: ' .. table.concat(open, ',') end
      if #used > 0 then
        ctx.warnings = ctx.warnings or {}
        ctx.warnings[#ctx.warnings + 1] = 'site.gate: waived ' .. table.concat(used, ',')
      end
      return 'done', r.verdict .. (#used > 0 and (', waived ' .. table.concat(used, ',')) or '')
    end}
end

-- the popup is still open from site.read; the rectangle must not have moved since
function S.confirm(ex, ey)
  return {id = 'site.confirm', live = 'run4-6', timeout_ms = 180000, tries = 3,
    wait = function(v) return cell(v, 'Confirm') ~= nil end,
    act = function(ui, v, ctx, w, mem)
      if not mem.Confirm then
        local ok, why = same_rect(v, ex, ey)
        if not ok then return 'fail', why end
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

---------------------------------------------------------------- run specs
-- spec = {v=2, id, mode='newgame'|'scan'|'embark'|'prep', world='Zilirr', cands={{wx,wy,lx,ly}},
--         site={wx,wy,lx,ly}, waive={criterion ids}, play_now=bool, allow_unspent=bool}
local function place_and_read(out, c, cfg, tag)
  local ex = 16 * c[1] + (c[3] or cfg.default_local[1])
  local ey = 16 * c[2] + (c[4] or cfg.default_local[2])
  out[#out + 1] = S.goto_world(c[1], c[2], cfg)
  out[#out + 1] = S.place(ex, ey, cfg)
  out[#out + 1] = S.read_site(tag, ex, ey)
  return ex, ey
end

local function prep_steps(out, spec, cfg, loadout)
  out[#out + 1] = S.prepare(spec.play_now)
  if spec.play_now then return end
  for i, role in ipairs(loadout.roles) do out[#out + 1] = S.skills(i, role, cfg) end
  out[#out + 1] = S.tab('items', 'prep_items', cfg)
  for _, it in ipairs(loadout.items) do out[#out + 1] = S.buy(it, 'prep_items', cfg) end
  out[#out + 1] = S.tab('animals', 'prep_animals', cfg)
  for _, a in ipairs(loadout.animals) do out[#out + 1] = S.buy(a, 'prep_animals', cfg) end
  out[#out + 1] = S.tab('items', 'prep_items', cfg)
  for _, n in ipairs(loadout.rest) do out[#out + 1] = S.buy({name = n, add = 999, rest = true}, 'prep_items', cfg) end
  out[#out + 1] = S.embark(spec.allow_unspent)
end

function S.build(spec, cfg, loadout)
  if spec.accept_review ~= nil then error('accept_review was removed: name each waived criterion in waive') end
  local out = {}
  if spec.mode == 'newgame' then
    out = S.newgame(spec.world)
  elseif spec.mode == 'scan' then
    for n, c in ipairs(spec.cands or {}) do
      place_and_read(out, c, cfg, spec.id .. '-' .. n)
      out[#out + 1] = S.abort_popup()
    end
  elseif spec.mode == 'embark' then
    -- read, gate and confirm the same placed rectangle; the popup stays open in between
    local ex, ey = place_and_read(out, spec.site, cfg, spec.id)
    out[#out + 1] = S.gate(spec.waive)
    out[#out + 1] = S.confirm(ex, ey)
    prep_steps(out, spec, cfg, loadout)
  elseif spec.mode == 'prep' then
    prep_steps(out, spec, cfg, loadout)
  elseif spec.mode == 'steps' then  -- Lua-built step list (embark.lua 'click')
    out = spec.steps
  else
    error('unknown mode ' .. tostring(spec.mode))
  end
  return out
end

return S
