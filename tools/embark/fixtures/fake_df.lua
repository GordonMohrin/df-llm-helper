-- tools/embark/fixtures/fake_df.lua: a tiny state machine of the embark screens for offline
-- tests of steps.lua + runner.lua. NOT DF: layouts, costs and transitions are invented; only
-- the button labels and messages are DF 53.16 strings. Imperfections are built in on purpose:
-- the world-map centre click lands one tile off, the rectangle offset differs from ui.json,
-- the placing rectangle follows the mouse until a click opens the Confirm popup, and preparing
-- the map / loading the fort take opt.prep_frames / opt.load_frames frames (20 ms each).
-- K2 (load a saved fort from the title screen): opt.saves = {{name=, label=?}, ...} adds a "Continue playing"
-- button to the title screen and the screens savelist, loadpopup and loadsave; opt.flow = 'list' (Continue opens
-- the list, an entry loads) | 'direct' (Continue loads the latest at once) | 'confirm' (an entry opens a popup
-- first) | 'danger' (... a popup that talks of deleting) | 'select_load' (an entry only selects, Load loads); opt.skip = {[text] = n} ignores the
-- first n clicks on that text (a menu that needs a second click); opt.old_field makes the stock load-save work.
local V = require('embark.view')
local F = {}

local GOOD = {'Temperate Broadleaf Forest', '', 'Temperature: Temperate', 'Trees: Woodland',
  'Other Vegetation: Moderate', 'Surroundings: Calm', '', 'Brook: Yes', '', 'Little soil', 'Flux stone layer',
  'Iron Copper'}
F.GOOD = GOOD
-- a Neighbors section without near goblins (appended to a site's panel when listed)
F.NEIGHBORS_FAR = {'', 'Neighbors:', 'Humans', "Nearest site: 3 days' travel", 'Goblins',
  "Nearest site: 9 days' travel"}
F.CAPTION = {MINING = 'Mining', ENGRAVE_STONE = 'Engraving', MASONRY = 'Masonry', CARPENTRY = 'Carpentry',
  WOODCUTTING = 'Woodcutting', BREWING = 'Brewing', PLANT = 'Growing', MECHANICS = 'Mechanics', COOK = 'Cooking',
  DIAGNOSE = 'Diagnostics', SURGERY = 'Surgery', SET_BONE = 'Bone Setting', SUTURE = 'Suturing'}
local SKILLS = {'MINING', 'ENGRAVE_STONE', 'MASONRY', 'CARPENTRY', 'WOODCUTTING', 'BREWING', 'PLANT',
  'MECHANICS', 'COOK', 'DIAGNOSE', 'SURGERY', 'SET_BONE', 'SUTURE'}
local COST = {pick = 12, ['iron bar'] = 8, ['plump helmet spawn'] = 1, seeds = 1, log = 1, Turkey = 5, Pig = 10}
local ITEMS = {'pick', 'iron bar', 'plump helmet spawn', 'seeds', 'log'}
local ANIMALS = {'Turkey', 'Pig'}
-- interface tile under ui.json place_px (600, 400) at 10x15 px tiles: a click there puts the
-- rectangle at camera + k; elsewhere it is shifted by the mouse offset from this tile
F.MAP_REF = {60, 26}

function F.new(opt)
  opt = opt or {}
  local D = {screen = opt.screen or 'title', ms = 0, w = 171, h = 66, tpx = 10, tpy = 15, mouse = {0, 0, 0, 0},
    cent = {10, 10}, zoom = {0, 0}, world_err = opt.world_err or {1, 0}, k = opt.k or {-5, 2},
    sites = opt.sites or {}, points = opt.points or 200, selected = 0, units = {}, frames = 0,
    row_select = opt.row_select ~= false, skill_clicks = opt.skill_clicks ~= false, bought = {}, clicks = 0,
    prep_frames = opt.prep_frames or 40, load_frames = opt.load_frames or 40, follow = opt.follow ~= false,
    ignore = opt.ignore or {}, pressed = {}, saves = opt.saves, flow = opt.flow or 'list', skip = opt.skip or {},
    old_field = opt.old_field == true, continue_label = opt.continue_label or 'Continue playing', loaded = nil,
    chosen = nil, stock_calls = {}, other_text = opt.other_text, tracking = opt.tracking,
    -- BUG-230: opt.worlds = {{name=, folder=, saves={{name=, fort=?}, ...}}, ...}: Continue opens the world list,
    -- a world row opens its game list, a game row loads; opt.rows rows are visible per list (scroll positions)
    worlds = opt.worlds, rows = opt.rows or 3, scroll_world = 0, scroll_game = 0, world = nil}

  for i = 1, 7 do D.units[i] = {picks = 10, lv = {}} end

  -- the highlighted rectangle: fixed while the popup is open, else (placing) under the mouse.
  -- Live L0 model: 16 px per embark tile around the window centre pixel,
  --   rect_min = zoom + k + floor((mouse px - centre px) / 16)
  function D.rect()
    local m, r = D.emb_min, D.region
    -- BUG-228: opt.tracking() false (live: enabler.tracking_on 0) = DF ignores the written mouse
    if D.screen == 'placing' and not D.popup and D.follow and D.tracks() then
      local cx, cy = D.w * D.tpx // 2, D.h * D.tpy // 2
      m = {D.zoom[1] + D.k[1] + (D.mouse[3] - cx) // 16, D.zoom[2] + D.k[2] + (D.mouse[4] - cy) // 16}
      r = {m[1] // 16, m[2] // 16}
    end
    if not m then return nil, nil, r end
    return m, {m[1] + 3, m[2] + 3}, r
  end

  function D.tracks() return D.tracking == nil or D.tracking() == true end

  local function site()
    local _, _, r = D.rect()
    return r and D.sites[r[1] .. ',' .. r[2]] or {}
  end

  -- {x, y, text, fn} for the current screen
  function D.buttons()
    local s, b = D.screen, {}
    local function add(x, y, t, fn) b[#b + 1] = {x, y, t, fn} end
    local function go(to) return function() D.screen = to; D.frames = 0 end end
    if s == 'title' and D.worlds then
      add(60, 18, D.continue_label, go('worldlist'))
      add(60, 22, 'Start new game in existing world', go('worlds'))
    elseif s == 'worldlist' then
      add(50, 6, 'Select a world')
      for r = 1, D.rows do
        local i = D.scroll_world + r
        local wd = D.worlds[i]
        if wd then add(30, 8 + 2 * r, wd.name, function() D.world = i; D.scroll_game = 0; go('gamelist')() end) end
      end
      add(100, 44, 'Back', go('title'))
    elseif s == 'gamelist' then
      add(50, 6, 'Select a game to continue')
      local saves = D.worlds[D.world].saves
      for r = 1, D.rows do
        local sv = saves[D.scroll_game + r]
        if sv then add(30, 8 + 2 * r, sv.name, function() D.chosen = sv.name; D.chosen_world = D.world; go('loadsave')() end) end
      end
      add(100, 44, 'Back', go('worldlist'))
    elseif s == 'title' then
      if D.saves then
        add(60, 18, D.continue_label, go(D.flow == 'direct' and 'loadsave' or 'savelist'))
      end
      add(60, 22, 'Start new game in existing world', go('worlds'))
      if D.other_text then add(60, 40, D.other_text) end
    elseif s == 'savelist' then
      add(50, 6, 'Select a game to continue')
      for i, sv in ipairs(D.saves or {}) do
        add(30, 10 + 2 * (i - 1), sv.label or sv.name, function()
          D.chosen = sv.name
          if D.flow == 'select_load' then return end
          go(D.flow == 'confirm' and 'loadpopup' or D.flow == 'danger' and 'loadpopup_danger' or 'loadsave')()
        end)
      end
      if D.flow == 'select_load' then add(100, 40, 'Load', function() if D.chosen then go('loadsave')() end end) end
      add(100, 44, 'Back', go('title'))
    elseif s == 'loadpopup' then
      add(50, 20, 'This game was saved with a different version.'); add(50, 21, 'Load it anyway?')
      add(55, 24, 'Okay', go('loadsave')); add(75, 24, 'Cancel', go('savelist'))
    elseif s == 'loadpopup_danger' then
      add(50, 20, 'This will delete the save.'); add(50, 21, 'Are you sure?'); add(55, 24, 'Okay', go('loadsave'))
    elseif s == 'loadsave' then add(60, 20, 'Loading game...')
    elseif s == 'worlds' then add(60, 22, 'Zilirr?th', go('gametype'))
    elseif s == 'gametype' then add(50, 10, 'Select a game type to begin!'); add(60, 20, 'Fortress', go('loading'))
    elseif s == 'loading' then add(50, 20, 'Loading world to start new game')
    elseif s == 'tutorial' then add(70, 30, 'Skip tutorial', go('okay'))
    elseif s == 'okay' then add(75, 30, 'Okay', go('world'))
    elseif s == 'world' then add(10, 62, 'Click the map to zoom in and choose your embark location.')
    elseif s == 'local' or s == 'placing' then
      if s == 'local' then add(10, 62, 'Click "Embark" to place your fortress.  Right click to zoom out.')
      else add(10, 62, 'Click on the map to embark!  Right click to abort.') end
      add(40, 64, 'Abort', function() D.screen = 'title' end)  -- the bottom Abort leaves the embark screen
      add(120, 64, 'Embark', function() if D.screen == 'local' then D.screen = 'placing' end end)
      if D.refused and s == 'placing' then   -- BUG-229: DF's refusal after a click (site.refuse), no popup
        for i, l in ipairs(D.refused) do add(55, 25 + i, l) end
      end
      if D.popup then
        for i, l in ipairs(site().popup or {}) do add(55, 25 + i, l) end
        add(60, 30, 'Confirm', function() D.popup = false; D.screen = 'preparing'; D.frames = 0 end)
        add(80, 30, 'Abort', function() D.popup = false end)
      end
      if D.rect() and s == 'placing' and not D.popup and D.tracks() then  -- live L0: the popup hides the panel
        local lines = {}
        for _, l in ipairs(site().panel or GOOD) do lines[#lines + 1] = l end
        for _, l in ipairs(site().neighbors or {}) do lines[#lines + 1] = l end
        for i, l in ipairs(lines) do if l ~= '' then add(125, 1 + i, l) end end
      end
    elseif s == 'preparing' then add(60, 20, 'Preparing map...')
    elseif s == 'loading_fort' then add(60, 20, 'Loading...')
    elseif s == 'prep_default' then
      add(60, 20, 'Play now!', go('loading_fort')); add(60, 24, 'Prepare for the journey carefully', go('prep_dwarves'))
    elseif s:sub(1, 5) == 'prep_' then
      add(10, 3, 'Dwarves', go('prep_dwarves')); add(25, 3, 'Items', go('prep_items')); add(40, 3, 'Animals', go('prep_animals'))
      add(100, 3, 'Points Left: ' .. D.points)
      add(150, 60, 'Embark!', function()
        if D.points > 0 then D.back = D.screen; D.screen = 'prep_sure' else D.screen = 'loading_fort'; D.frames = 0 end
      end)
      if s == 'prep_dwarves' then
        for i = 1, 7 do add(6, 9 + 3 * (i - 1), 'Dwarf ' .. i, function() if D.row_select then D.selected = i - 1 end end) end
        add(60, 8, 'Available Skills')
        local u = D.units[D.selected + 1]
        add(100, 8, u.picks .. ' skill picks left')
        for j, sk in ipairs(SKILLS) do
          add(60, 9 + j, F.CAPTION[sk], function()
            if D.skill_clicks and u.picks > 0 and (u.lv[sk] or 0) < 5 then u.lv[sk] = (u.lv[sk] or 0) + 1; u.picks = u.picks - 1 end
          end)
        end
      elseif s == 'prep_items' or s == 'prep_animals' then
        for j, name in ipairs(s == 'prep_items' and ITEMS or ANIMALS) do
          add(60, 9 + j, name, function()
            if D.points >= COST[name] then D.points = D.points - COST[name]; D.bought[name] = (D.bought[name] or 0) + 1 end
          end)
        end
      elseif s == 'prep_sure' then
        add(60, 20, 'Are you sure?'); add(60, 24, 'Go back', function() D.screen = D.back end)
        add(80, 24, 'I am ready!', go('loading_fort'))
      end
    end
    return b
  end

  function D.lines()
    local blank, out = string.rep(' ', D.w), {}
    for y = 1, D.h do out[y] = blank end
    for _, b in ipairs(D.buttons()) do
      local row, x, t = out[b[2] + 1], b[1], b[3]
      out[b[2] + 1] = (row:sub(1, x) .. t .. row:sub(x + #t + 1)):sub(1, D.w)
    end
    return out
  end

  local FOCUS = {title = 'title/Default', worlds = 'title/Default', gametype = 'choose_game_type',
    savelist = 'title/Default', loadpopup = 'title/Default', loadpopup_danger = 'title/Default',
    worldlist = 'title/Default', gamelist = 'title/Default',
    loadsave = 'title/Default',
    loading = 'adopt_region', preparing = 'choose_start_site', fort = 'dwarfmode/Default', loading_fort = 'loadgame',
    prep_default = 'setupdwarfgame/Default', prep_dwarves = 'setupdwarfgame/Dwarves',
    prep_items = 'setupdwarfgame/Items', prep_animals = 'setupdwarfgame/Animals', prep_sure = 'setupdwarfgame/Dwarves'}
  function D.source()
    local lines = D.lines()
    return {
      size = function() return D.w, D.h end,
      ch = function(x, y) return lines[y + 1]:byte(x + 1) end,
      lines = function() return lines end,  -- shortcut for V.capture (ASCII only)
      focus = function() return {FOCUS[D.screen] or 'choose_start_site'} end,
      cs = function()
        if FOCUS[D.screen] and D.screen ~= 'preparing' then return nil end
        local m, x, r = D.rect()
        local zoomed = D.screen == 'local' or D.screen == 'placing'
        return {zoomed_in = zoomed, choosing_embark = D.screen == 'placing',
          finder = false, region = r, emb_min = m, emb_max = x, cam_local = {D.zoom[1], D.zoom[2]},
          zoom_world = zoomed and {D.zoom[1] // 16, D.zoom[2] // 16} or nil}
      end,
      prep = function()
        if D.screen:sub(1, 5) ~= 'prep_' then return nil end
        return {selected = D.selected, points = D.points, units = D.units}
      end,
      title = function()  -- the viewscreen_titlest fields (embark.lua reads them with pcall); only with saved games
        if not (D.saves or D.worlds) or FOCUS[D.screen] ~= 'title/Default' then return nil end
        local t = {old_field = D.old_field, selected = 0, selected_r = -1, mode = 0}
        if D.worlds then   -- BUG-230: the header lists (folder = filename_noext)
          t.worlds, t.saves, t.scroll_world, t.scroll_game = {}, {}, D.scroll_world, D.scroll_game
          for _, wd in ipairs(D.worlds) do
            t.worlds[#t.worlds + 1] = {folder = wd.folder, world = wd.name}
            for _, sv in ipairs(wd.saves) do t.saves[#t.saves + 1] = {folder = sv.name, world = wd.name, fort = sv.fort} end
          end
          if D.world and D.screen == 'gamelist' then
            t.games = {}
            for _, sv in ipairs(D.worlds[D.world].saves) do
              t.games[#t.games + 1] = {folder = sv.name, world = D.worlds[D.world].name, fort = sv.fort}
            end
          end
        end
        return t
      end,
    }
  end

  local function click(button)
    D.clicks = D.clicks + 1
    local tx, ty = D.mouse[1], D.mouse[2]
    if button == 'L' then
      for _, b in ipairs(D.buttons()) do
        if b[4] and ty == b[2] and tx >= b[1] and tx < b[1] + #b[3] then
          D.pressed[b[3]] = (D.pressed[b[3]] or 0) + 1
          if D.ignore[b[3]] then return end
          if (D.skip[b[3]] or 0) > 0 then D.skip[b[3]] = D.skip[b[3]] - 1 return end
          return b[4]()
        end
      end
      if D.screen == 'world' then
        D.region = {D.cent[1] + D.world_err[1], D.cent[2] + D.world_err[2]}
        D.zoom = {D.region[1] * 16 + 8, D.region[2] * 16 + 8}  -- live L0: the local view centres the tile
        D.screen = 'local'
      elseif D.screen == 'placing' and not D.popup then
        local m, _, r = D.rect()
        if not D.follow then m = {D.zoom[1] + D.k[1], D.zoom[2] + D.k[2]}; r = {m[1] // 16, m[2] // 16} end
        if site().refuse then D.refused = site().refuse return end
        D.emb_min, D.region, D.popup = m, r, true
      end
    else
      D.refused = nil
      if D.screen == 'placing' and not D.popup then D.screen = 'local'
      elseif D.screen == 'local' then D.screen = 'world' end
    end
  end

  D.env = {now = function() return D.ms end, mouse = function(tx, ty, px, py) D.mouse = {tx, ty, px, py} end,
    sim = function(keys)
      if keys == 'LEAVESCREEN' and D.screen == 'gamelist' then D.screen = 'worldlist' return end   -- BUG-230
      if type(keys) == 'table' and keys._MOUSE_L then click('L') elseif type(keys) == 'table' and keys._MOUSE_R then click('R') end
    end,
    tile_px = function() return D.tpx, D.tpy end, win = function() return D.w, D.h end}
  D.w_api = {camera = function(which, x, y) if which == 'world' then D.cent = {x, y} else D.zoom = {x, y} end end,
    select_unit = function(i) D.selected = i end,
    scroll = function(which, n)   -- BUG-230: DF clamps the scroll so the last rows stay filled
      local list = which == 'world' and D.worlds or (D.world and D.worlds[D.world].saves) or {}
      local v = math.max(0, math.min(n, #list - D.rows))
      if which == 'world' then D.scroll_world = v else D.scroll_game = v end
      D.scrolls = (D.scrolls or 0) + 1
      return true
    end,
    -- DFHack's stock load-save: works only where the old field exists (DFHack before 53.16-r3)
    stock_load = function(save)
      D.stock_calls[#D.stock_calls + 1] = save
      if not D.old_field then return false, 'Cannot write field viewscreen_titlest.sel_menu_line: not found.' end
      D.chosen = save
      D.screen, D.frames = 'loadsave', 0
      return true, 'loading ' .. save
    end}

  function D.tick()
    D.frames = D.frames + 1
    if D.screen == 'loading' and D.frames > 40 then D.screen = 'tutorial' end
    if D.screen == 'preparing' and D.frames > D.prep_frames then D.screen = 'prep_default' end
    if D.screen == 'loading_fort' and D.frames > D.load_frames then D.screen = 'fort' end
    if D.screen == 'loadsave' and D.frames > D.load_frames then
      D.screen, D.loaded = 'fort', D.chosen or '(latest)'
    end
  end

  function D.capture() return V.capture(D.source()) end
  return D
end

-- play a run to the end; returns frames used
function F.play(D, run, max_frames)
  local n = 0
  while n < (max_frames or 200000) do
    n = n + 1
    local more = run:frame()
    D.ms = D.ms + 20
    D.tick()
    if not more then break end
  end
  return n
end

return F
