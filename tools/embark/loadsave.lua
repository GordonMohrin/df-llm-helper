-- tools/embark/loadsave.lua: load a saved fortress from the title screen with the vanilla UI only (K2).
--
-- Why: DFHack 53.16-r3 renamed viewscreen_titlest.sel_menu_line to `selected`, so the stock `load-save` fails
-- ("Cannot write field viewscreen_titlest.sel_menu_line: not found") and writing the new field plus
-- simulateInput(SELECT) moves nothing: the title menu follows the mouse. This module is the click path of
-- `dfpilot supervise` (and of `embark.py load`): the same hover-then-click engine as the embark steps
-- (input.lua, runner.lua; clicks on visible text, proven live for the title menu in L0).
--
-- Fair play (binding): it only reads the text buffer (view.lua) and clicks visible text, and only on the title
-- family of screens: the main menu (Continue / Load game), the list of saved games, a confirmation popup. On a
-- fort, a map, a loading screen or any other screen it clicks nothing. It never edits the game: no field of the
-- title screen is written, no save file is touched, no other save is chosen than the one named (the list entry
-- must show the folder name as a whole token, `autosave 1` is not `autosave 10`, `region2` not `region2-spr-0050`).
--
-- Not decided offline (the first live use decides, the run logs the rows it saw and the pixel it clicked in
-- status.json `results`): the exact labels of the main menu and the list in 53.16-r3, whether the list shows the
-- folder name at all, whether a click needs a second click (the steps click again when the screen did not
-- change: `tries`, `stale`), whether an entry loads at once or needs a Load button. Calibration without a code
-- change: `ui.json` `load` (tries, timeouts), `embark.py load SAVE --entry TEXT` (the text to click in the list).
--
-- Pure functions (no DF calls; tests/lua/test_loadsave.lua): norm, token, find_all, choose_entry, target, is_main,
-- main_button, confirm_button, danger, loading, screen, brief, signature. Steps: L.steps(spec, cfg).
local V = require('embark.view')
local L = {}

-- ---------------------------------------------------------------- text helpers
-- lowercase ASCII, every run of non-alphanumerics becomes one space, trimmed
function L.norm(s)
  s = V.lower(tostring(s or '')):gsub('[^%w]+', ' ')
  return (s:gsub('^ +', ''):gsub(' +$', ''))
end

-- characters a save folder name is made of; a match inside a longer name is another save
local function wordc(c) return c ~= '' and c:match('[%w_%-]') ~= nil end

-- first whole-token match of `name` in `line` (case-insensitive): 0-based x and the length, else nil
function L.token(line, name)
  name = tostring(name or '')
  if name == '' then return nil end
  local l, n = V.lower(line), V.lower(name)
  local init = 1
  while true do
    local s, e = l:find(n, init, true)
    if not s then return nil end
    if not wordc(l:sub(s - 1, s - 1)) and not wordc(l:sub(e + 1, e + 1)) then return s - 1, e - s + 1 end
    init = s + 1
  end
end

-- every row of the view that holds `name` as a token: {x, y (0-based), len, line}
function L.find_all(v, name)
  local out = {}
  for y, line in ipairs(v.lines) do
    local x, len = L.token(line, name)
    if x then out[#out + 1] = {x = x, y = y - 1, len = len, line = V.trim(line)} end
  end
  return out
end

-- the entry of the list to click: the topmost row that shows `name` as a whole token (a heading above the list cannot
-- hide it, a look-alike is no match); nil and why when no row shows it; a note when more than one does
function L.choose_entry(v, name)
  local m = L.find_all(v, name)
  if #m == 0 then return nil, '"' .. tostring(name) .. '" is not on the screen' end
  return m[1], (#m > 1) and (#m .. ' rows show "' .. tostring(name) .. '", the topmost is clicked') or nil
end

-- the tile to click for a match (the middle of the text) and the pixel of that tile's centre
-- (CLAUDE.md: precise_mouse = x * 12 + 6, y * 18 + 9 at 12x18 px tiles; the tile size is read from gps)
function L.target(m, tpx, tpy)
  local tx, ty = m.x + m.len // 2, m.y
  return {tx = tx, ty = ty, px = tx * tpx + tpx // 2, py = ty * tpy + tpy // 2}
end

-- the visible cells of the view joined for a log line or a message (cells = runs of text split at 2+ spaces)
function L.brief(v, max)
  local parts = {}
  for _, c in ipairs(v:cells()) do
    if c.text ~= '' then parts[#parts + 1] = c.text end
  end
  local s = table.concat(parts, ' | ')
  max = max or 240
  if #s > max then s = s:sub(1, max - 3) .. '...' end
  return s
end

-- what the screen looks like, for the runner's "no progress" count
function L.signature(v) return table.concat(v.focus or {}, '|') .. '#' .. L.brief(v, 4000) end

-- ---------------------------------------------------------------- the screens
-- text that only the main menu shows (title.new is proven live: 'Start new game in existing world')
L.MAIN_MARKERS = {'start new game in existing world', 'create new world'}
-- buttons that confirm a popup on the way to the game; 'continue' is one only off the main menu
L.OK_BUTTONS = {okay = true, ok = true, yes = true, confirm = true, load = true, ['load anyway'] = true,
  ['continue anyway'] = true, proceed = true, accept = true, continue = true}
-- words in a popup that stop the run: it is the player's decision (we click Okay only on harmless popups)
L.DANGER = {'delete', 'erase', 'overwrite', 'abandon', 'retire'}

function L.is_main(v)
  for _, line in ipairs(v.lines) do
    local n = L.norm(line)
    for _, m in ipairs(L.MAIN_MARKERS) do
      if n:find(m, 1, true) then return true end
    end
  end
  return false
end

-- the main-menu entry to click: "Continue ..." first (the player's own click), then "Load ..."; the topmost wins
function L.main_button(v)
  local best
  for _, c in ipairs(v:cells()) do
    local n = L.norm(c.text)
    local rank = ((n == 'continue' or n:match('^continue ')) and 1) or ((n == 'load' or n:match('^load ')) and 2) or nil
    if rank and (not best or rank < best.rank) then best = {rank = rank, cell = c} end
  end
  if best then return best.cell, best.rank end
  return nil
end

function L.confirm_button(v)
  for _, c in ipairs(v:cells()) do
    if L.OK_BUTTONS[L.norm(c.text)] then return c end
  end
  return nil
end

-- the first danger word on the screen, else nil
function L.danger(v)
  for _, line in ipairs(v.lines) do
    local n = ' ' .. L.norm(line) .. ' '
    for _, w in ipairs(L.DANGER) do
      if n:find(' ' .. w, 1, true) then return w end
    end
  end
  return nil
end

function L.loading(v)
  for _, line in ipairs(v.lines) do
    local n = ' ' .. L.norm(line) .. ' '
    if n:find(' loading ', 1, true) or n:find(' please wait ', 1, true) then return true end
  end
  return false
end

-- 'fort' | 'loading' | 'main' | 'list' | 'confirm' | 'other'; for 'other' also why and 'foreign' (a screen that is
-- not the title family: nothing is ever clicked there) or 'title' (a title screen that shows neither the main menu
-- nor the save)
function L.screen(v, name)
  local k = v:kind()
  if k == 'fort' then return 'fort' end
  if L.loading(v) then return 'loading' end
  local on_title = k == 'title' or v:focus_has('loadgame') or v.title ~= nil
  if not on_title then return 'other', 'not the title screen (' .. k .. ')', 'foreign' end
  if L.is_main(v) then return 'main' end
  if name and #L.find_all(v, name) > 0 then return 'list' end
  if L.confirm_button(v) then return 'confirm' end
  return 'other', 'a title screen with neither the main menu nor "' .. tostring(name) .. '"', 'title'
end

-- ---------------------------------------------------------------- steps
local function results(ctx)
  ctx.results = ctx.results or {}
  local r = ctx.results
  r.clicks = r.clicks or {}
  return r
end

-- queue one click on `m` ({x, y, len}) and log it: the pixel is what the run reports for the calibration
local function click(ui, ctx, mem, m, text, kind)
  local tpx, tpy = ui.env.tile_px()
  local t = L.target(m, tpx, tpy)
  ui:click_px(t.px, t.py)
  mem.clicks = (mem.clicks or 0) + 1
  local r = results(ctx)
  r.clicks[#r.clicks + 1] = {kind = kind, text = text, tx = t.tx, ty = t.ty, px = t.px, py = t.py, n = mem.clicks}
  return nil, string.format('clicked %s "%s" at tile %d,%d pixel %d,%d', kind, text, t.tx, t.ty, t.px, t.py)
end

-- DFHack's own load-save first, but only where the field it writes exists (sel_menu_line: DFHack before r3)
local function stock_step(spec)
  return {id = 'load.stock', live = 'untested', optional = true, tries = 1, timeout_ms = 15000,
    act = function(ui, v, ctx, w, mem)
      if v.title then results(ctx).title = v.title end   -- the first look at the title screen's fields
      if spec.stock == false then return 'skip', 'stock load-save not requested' end
      if not (v.title and v.title.old_field) then
        return 'skip', 'no viewscreen_titlest.sel_menu_line (DFHack r3 or later): the stock load-save cannot work'
      end
      if mem.ran then return 'wait', 'stock load-save called' end
      mem.ran = true
      local ok, msg = w.stock_load(spec.save)
      results(ctx).stock = tostring(msg):sub(1, 120)
      if not ok then return 'fail', 'stock load-save: ' .. tostring(msg):sub(1, 120) end
      ctx.stock_ok = true
      return nil, 'stock load-save called'
    end,
    done = function(v, ctx)
      local s = L.screen(v, spec.entry or spec.save)
      if s == 'loading' or s == 'fort' then return true, 'stock load-save: ' .. s end
      return false, 'still on the ' .. s .. ' screen'
    end}
end

local function drive_step(spec, name, c)
  local unknown_polls = c.unknown_polls or 12
  -- left the menus after our own action: loading, or the fort itself
  local function left(s, ctx, mem)
    return (s == 'loading' or s == 'fort') and ((mem.clicks or 0) > 0 or ctx.stock_ok == true)
  end
  return {id = 'load.drive', live = 'untested', tries = c.tries or 14, timeout_ms = c.timeout_ms or 120000,
    settle_ms = c.settle_ms or 2500, stale = c.stale or 4, progress = L.signature,
    act = function(ui, v, ctx, w, mem)
      local r = results(ctx)
      local s, why = L.screen(v, name)
      r.screen, r.rows = s, L.brief(v)
      if v.title then r.title = v.title end   -- viewscreen_titlest fields as read now (does `selected` follow the hover?)
      if s ~= 'other' then mem.unk = 0 end
      if left(s, ctx, mem) then
        r.outcome = s
        return 'done', 'left the title screen: ' .. s
      elseif s == 'fort' then
        return 'fail', 'a fort is already loaded; nothing was clicked'
      elseif s == 'loading' then
        return 'wait', 'loading (nothing clicked yet)'
      elseif s == 'main' then
        local cell = L.main_button(v)
        if not cell then
          return 'fail', 'the title menu has no Continue or Load entry; rows: ' .. L.brief(v)
        end
        return click(ui, ctx, mem, {x = cell.x, y = cell.y, len = #cell.text}, cell.text, 'main')
      elseif s == 'list' then
        mem.list = (mem.list or 0) + 1
        -- the first visit clicks the entry; if the screen is still the list afterwards, a confirming button
        -- (an entry that only selects, a Load button) on even visits, the entry again otherwise
        if mem.list % 2 == 0 then
          local b = L.confirm_button(v)
          if b then return click(ui, ctx, mem, {x = b.x, y = b.y, len = #b.text}, b.text, 'confirm') end
        end
        local m, note = L.choose_entry(v, name)
        if note then results(ctx).note = note end
        return click(ui, ctx, mem, m, v.lines[m.y + 1]:sub(m.x + 1, m.x + m.len), 'entry')
      elseif s == 'confirm' then
        local d = L.danger(v)
        if d then
          return 'fail', 'a popup mentions "' .. d .. '", left to the player; rows: ' .. L.brief(v)
        end
        local b = L.confirm_button(v)
        return click(ui, ctx, mem, {x = b.x, y = b.y, len = #b.text}, b.text, 'confirm')
      end
      -- a screen we do not know: nothing is clicked; wait for a transition, then say what was seen
      mem.unk = (mem.unk or 0) + 1
      if mem.unk > unknown_polls then
        return 'fail', tostring(why) .. ' (nothing clicked here); rows: ' .. L.brief(v)
      end
      return 'wait', tostring(why)
    end,
    done = function(v, ctx, mem)
      local s = L.screen(v, name)
      if left(s, ctx, mem) then
        results(ctx).outcome = s
        return true, 'left the title screen: ' .. s
      end
      return false, 'screen: ' .. s
    end}
end

function L.steps(spec, cfg)
  if type(spec.save) ~= 'string' or spec.save == '' then error('load: spec.save (the save folder name) is missing') end
  local c = (cfg or {}).load or {}
  return {stock_step(spec), drive_step(spec, spec.entry or spec.save, c)}
end

return L
