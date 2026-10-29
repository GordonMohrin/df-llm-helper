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
-- title screen is written but the scroll positions of its two lists (BUG-230, = the mouse wheel), no save file is touched, no other save is chosen than the one named (the list entry
-- must show the folder name as a whole token, `autosave 1` is not `autosave 10`, `region2` not `region2-spr-0050`).
--
-- Not decided offline (the first live use decides, the run logs the rows it saw and the pixel it clicked in
-- status.json `results`): the exact labels of the main menu and the list in 53.16-r3, whether the list shows the
-- folder name at all, whether a click needs a second click (the steps click again when the screen did not
-- change: `tries`, `stale`), whether an entry loads at once or needs a Load button. Calibration without a code
-- change: `ui.json` `load` (tries, timeouts), `embark.py load SAVE --entry TEXT` (the text to click in the list).
--
-- Pure functions (no DF calls; tests/lua/test_loadsave.lua): norm, token, find_all, choose_entry, target, is_main,
-- main_button, confirm_button, danger, loading, screen, brief, dump, signature. Steps: L.steps(spec, cfg).
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

-- FR-91 (Run 14 note 99): everything the labels of the 53.16-r3 title menu are unknown offline. When the run cannot find a
-- label it records WHAT THE SCREEN SHOWS, once per run, bounded: the viewscreen stack (focus strings), the kind the model
-- derives, the screen size, the viewscreen_titlest fields, the non-blank rows (<= 40, <= 100 columns) and the text cells with
-- their tile (<= 60). Read only; the data decides the labels (`--entry`, MAIN_MARKERS, OK_BUTTONS) without another run.
L.DUMP_ROWS, L.DUMP_COLS, L.DUMP_CELLS = 40, 100, 60
function L.dump(v, why)
  local rows, cells = {}, {}
  for y, line in ipairs(v.lines) do
    local t = line:gsub(' +$', '')
    if #t > 0 and #rows < L.DUMP_ROWS then rows[#rows + 1] = string.format('%d %s', y - 1, t:sub(1, L.DUMP_COLS)) end
  end
  for _, c in ipairs(v:cells()) do
    if #cells < L.DUMP_CELLS then cells[#cells + 1] = string.format('%d,%d %s', c.x, c.y, c.text:sub(1, 40)) end
  end
  return {why = tostring(why or ''), focus = table.concat(v.focus or {}, '|'), kind = v:kind(), size = v.w .. 'x' .. v.h,
    title = v.title, rows = rows, cells = cells}
end

-- what the screen looks like, for the runner's "no progress" count
function L.signature(v) return table.concat(v.focus or {}, '|') .. '#' .. L.brief(v, 4000) end

-- ---------------------------------------------------------------- BUG-230: the header lists of the title screen
-- Run 15 (i2): two worlds of the same name could not be told apart by their row text, and a save below the visible
-- part of a list was never reached. viewscreen_titlest holds the lists behind the rows (read only, embark.lua
-- source().title): `worlds` = savegame_header_world, `games` = savegame_header_game, `saves` = savegame_header,
-- each entry {folder = filename_noext, world = world_name, fort = fort_name}, and the lists' scroll positions
-- `scroll_world` / `scroll_game` (scroll_position_world_choice / _game_choice). DF's list shows entry
-- scroll + 1, scroll + 2, ... top down, so the n-th row that shows a label is the n-th entry from `scroll` on with
-- that label: the save's own entry is found by its folder, its row by counting same-labelled entries above it.
-- A target above or below the visible rows is brought to the top by setting the scroll position (= scrolling the
-- list with the wheel; w.scroll). Nothing else of the title screen is written.

-- header text (CP437 bytes) as the screen shows it (view.lua: accents read as '?')
function L.shown(s)
  return (tostring(s or ''):gsub('.', function(c) return V.char(c:byte()) end))
end

local function same(a, b) return a ~= nil and b ~= nil and L.norm(L.shown(a)) == L.norm(L.shown(b)) end

-- 1-based index of the entry whose folder is `folder`, else nil
function L.index_of(list, folder)
  for i, e in ipairs(list or {}) do
    if same(e.folder, folder) then return i end
  end
  return nil
end

-- the world list entry to open for `save`: the entry of that folder; else (spec.world_folder) the world entry of
-- that folder; else the only world entry named like the save's world (title.saves). nil and why when the save is
-- unknown or two worlds share the name (the folders are named so the player can pass --world-folder).
function L.world_index(title, save, world_folder)
  local worlds = title and title.worlds
  if not worlds or #worlds == 0 then return nil, 'no world list' end
  if world_folder then
    local i = L.index_of(worlds, world_folder)
    if i then return i end
    return nil, 'no world with the folder "' .. tostring(world_folder) .. '"'
  end
  local i = L.index_of(worlds, save)
  if i then return i end
  local si = L.index_of(title.saves, save)
  local wname = si and title.saves[si].world
  if not wname then return nil, '"' .. tostring(save) .. '" is in no header of the title screen' end
  local hits, folders = {}, {}
  for j, e in ipairs(worlds) do
    if same(e.world, wname) then hits[#hits + 1] = j; folders[#folders + 1] = tostring(e.folder) end
  end
  if #hits == 1 then return hits[1] end
  if #hits == 0 then return nil, 'no world named "' .. L.shown(wname) .. '" in the world list' end
  return nil, #hits .. ' worlds are named "' .. L.shown(wname) .. '" (folders ' .. table.concat(folders, ', ') ..
    ')', wname, hits
end

-- where to click entry `idx` of `list` (labels by `label(e)`): the match on the screen ({x, y, len}) or
-- nil, the scroll position that brings the entry to the top (or nil when scrolling cannot help), and why
function L.list_row(v, list, idx, scroll, label)
  scroll = tonumber(scroll) or 0
  local text = label(list[idx])
  if not text or text == '' then return nil, nil, 'entry ' .. idx .. ' has no label' end
  if idx - 1 < scroll then return nil, idx - 1, 'entry ' .. idx .. ' is above the visible rows (scroll ' .. scroll .. ')' end
  local k = 1
  for j = scroll + 1, idx - 1 do
    if same(label(list[j]), text) then k = k + 1 end
  end
  local m = L.find_all(v, L.shown(text))
  if m[k] then return m[k], nil, nil end
  if scroll ~= idx - 1 then
    return nil, idx - 1, 'entry ' .. idx .. ' "' .. L.shown(text) .. '" is not among the visible rows (scroll ' .. scroll .. ')'
  end
  return nil, nil, 'entry ' .. idx .. ' "' .. L.shown(text) .. '" is not on the screen at scroll ' .. scroll
end

-- the list step for the header lists: {which = 'game'|'world', m = match | nil, scroll = n | nil, why, idx, text}
-- or nil when the title screen gives no header lists for this save (the text-only path then decides)
-- tried = {[world index] = true}: same-named worlds already opened whose game list did not hold the save;
-- opened = a world row was clicked by this run. Then a game list without the save answers {which = 'back'} (Esc,
-- back to the world list) and the next same-named world is opened.
local function game_pick(v, t, spec, gi)
  local target, save = t.games[gi], spec.save
  local ways = {
    {spec.entry, function(e) return e == target and spec.entry or e.folder end},
    {save, function(e) return e.folder end},
    {target.fort, function(e) return e.fort end}}
  local first
  for _, w in ipairs(ways) do
    if w[1] and w[1] ~= '' and #L.find_all(v, L.shown(w[1])) > 0 then
      local m, sc, why = L.list_row(v, t.games, gi, t.scroll_game, w[2])
      local pick = {which = 'game', m = m, scroll = sc, why = why, idx = gi, text = w[1]}
      if m then return pick end
      first = first or pick
    end
  end
  return first   -- nil: no label of the save is on the screen (maybe not the game list)
end

local function world_pick(v, t, spec, tried)
  if type(t.worlds) ~= 'table' or #t.worlds == 0 then return nil end
  local wi, why, wname, hits = L.world_index(t, spec.save, spec.world_folder)
  for _, h in ipairs(hits or {}) do   -- same-named worlds: the first one not opened yet
    if not tried[h] then wi = h break end
  end
  if not wi then   -- a refusal only on the world list itself (the name is shown)
    if wname and #L.find_all(v, L.shown(wname)) > 0 then
      return {which = 'world', refuse = true, why = why .. (hits and (', none holds "' .. tostring(spec.save) ..
        '"; name one with --world-folder') or '')}
    end
    return nil
  end
  local name = t.worlds[wi].world
  local listed = false   -- the world list is shown when a row shows the name of one of its entries
  for _, e in ipairs(t.worlds) do
    if e.world and #L.find_all(v, L.shown(e.world)) > 0 then listed = true break end
  end
  if not listed then return nil end
  local m, sc, why2 = L.list_row(v, t.worlds, wi, t.scroll_world, function(e) return e.world end)
  return {which = 'world', m = m, scroll = sc, why = why2, idx = wi, text = name}
end

function L.header_pick(v, spec, tried, opened)
  local t = v.title
  if type(t) ~= 'table' or (type(t.games) ~= 'table' and type(t.worlds) ~= 'table') then return nil end
  tried = tried or {}
  local gi = L.index_of(t.games, spec.save)
  local gp = gi and game_pick(v, t, spec, gi)
  if gp then return gp end
  if opened and not gi and type(t.games) == 'table' and #t.games > 0 then
    return {which = 'back', why = 'the game list of this world does not hold "' .. tostring(spec.save) .. '"'}
  end
  local wp = world_pick(v, t, spec, tried)
  if wp then return wp end
  if gi then   -- the save's row is not visible: scroll the game list to it
    local m, sc, why = L.list_row(v, t.games, gi, t.scroll_game, function(e) return e.folder end)
    return {which = 'game', m = m, scroll = sc, why = why, idx = gi, text = spec.save}
  end
  return nil
end

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

-- the first screen a label was missing on is dumped (L.dump); later ones are not: once per run
local function dump_once(ctx, v, why)
  local r = results(ctx)
  if not r.dump then r.dump = L.dump(v, why) end
end

-- queue one click on `m` ({x, y, len}) and log it: the pixel is what the run reports for the calibration
local function click(ui, ctx, mem, m, text, kind, v)
  local tpx, tpy = ui.env.tile_px()
  local t = L.target(m, tpx, tpy)
  ui:click_px(t.px, t.py)
  mem.clicks = (mem.clicks or 0) + 1
  local r = results(ctx)
  r.clicks[#r.clicks + 1] = {kind = kind, text = text, tx = t.tx, ty = t.ty, px = t.px, py = t.py, n = mem.clicks}
  if mem.clicks >= 3 then   -- the third click and the screen still is not ours: look at it (once per run)
    dump_once(ctx, v, 'clicked ' .. mem.clicks .. ' times; the last was ' .. kind .. ' "' .. text .. '"')
  end
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
      local s, why, kind = L.screen(v, name)
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
          dump_once(ctx, v, 'the title menu has no Continue or Load entry')
          return 'fail', 'the title menu has no Continue or Load entry; rows: ' .. L.brief(v)
        end
        return click(ui, ctx, mem, {x = cell.x, y = cell.y, len = #cell.text}, cell.text, 'main', v)
      end
      -- BUG-230: the header lists decide which row is the save (same-named worlds) and scroll to it
      mem.tried = mem.tried or {}
      local hp = (s == 'list' or (s == 'other' and kind == 'title'))
        and L.header_pick(v, spec, mem.tried, mem.cur_world ~= nil) or nil
      if hp and hp.which == 'back' then
        mem.tried[mem.cur_world], mem.cur_world = true, nil
        ui:key('LEAVESCREEN')   -- Esc: back to the world list (a vanilla key)
        local r2 = results(ctx)
        r2.clicks[#r2.clicks + 1] = {kind = 'back', text = 'Esc', n = (mem.clicks or 0)}
        return nil, hp.why .. ': back to the world list'
      end
      if hp and hp.refuse then
        dump_once(ctx, v, hp.why)
        return 'fail', hp.why .. '; rows: ' .. L.brief(v)
      elseif hp and hp.m then
        mem.unk = 0
        mem.hl = (mem.hl or 0) + 1
        if hp.which == 'game' and mem.hl % 2 == 0 then   -- the entry only selected: a Load button (as below)
          local b = L.confirm_button(v)
          if b then return click(ui, ctx, mem, {x = b.x, y = b.y, len = #b.text}, b.text, 'confirm', v) end
        end
        if hp.which == 'world' then mem.cur_world = hp.idx end
        return click(ui, ctx, mem, hp.m, v.lines[hp.m.y + 1]:sub(hp.m.x + 1, hp.m.x + hp.m.len), hp.which, v)
      elseif hp and hp.scroll and w and w.scroll then
        mem.unk = 0
        mem.scrolls = (mem.scrolls or 0) + 1
        if mem.scrolls > 4 then return 'fail', 'the ' .. hp.which .. ' list does not scroll: ' .. tostring(hp.why) end
        w.scroll(hp.which, hp.scroll)
        local r2 = results(ctx)
        r2.scrolls = r2.scrolls or {}
        r2.scrolls[#r2.scrolls + 1] = {which = hp.which, to = hp.scroll, idx = hp.idx}
        return nil, 'scrolled the ' .. hp.which .. ' list to ' .. hp.scroll .. ' (' .. tostring(hp.why) .. ')'
      end
      if s == 'list' then
        mem.list = (mem.list or 0) + 1
        -- the first visit clicks the entry; if the screen is still the list afterwards, a confirming button
        -- (an entry that only selects, a Load button) on even visits, the entry again otherwise
        if mem.list % 2 == 0 then
          local b = L.confirm_button(v)
          if b then return click(ui, ctx, mem, {x = b.x, y = b.y, len = #b.text}, b.text, 'confirm', v) end
        end
        local m, note = L.choose_entry(v, name)
        if note then results(ctx).note = note end
        return click(ui, ctx, mem, m, v.lines[m.y + 1]:sub(m.x + 1, m.x + m.len), 'entry', v)
      elseif s == 'confirm' then
        local d = L.danger(v)
        if d then
          return 'fail', 'a popup mentions "' .. d .. '", left to the player; rows: ' .. L.brief(v)
        end
        local b = L.confirm_button(v)
        return click(ui, ctx, mem, {x = b.x, y = b.y, len = #b.text}, b.text, 'confirm', v)
      end
      -- a screen we do not know: nothing is clicked; wait for a transition, then say what was seen
      mem.unk = (mem.unk or 0) + 1
      dump_once(ctx, v, why)
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
