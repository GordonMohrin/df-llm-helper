-- viewlib: the verb `view` (FR-88, Run 14 note 95). A library, not a kernel module (like zonelib.lua): the arbiter hosts
-- the verb and calls V.verb(K, st, args, cmd) and, every step, V.step(K, st); `st` is the arbiter's state table.
--
-- Run 14 y707: Gordon wanted the camera on the goblin 39230 and on dwarves by name; dfpilot could only print coordinates
-- he had to find himself. The verb does what a player does: a click on a report ("zoom to") or "follow unit" on the unit
-- sheet. act.view_to centres the main viewport on a tile and sets the level (dfhack.gui.revealInDwarfmodeMap, the call the
-- trade sheet already uses). Only a view: no pause, no unit or building is touched, no zoom is changed.
--
-- args {target?, follow?, ttl_s?, why?}; target = a unit id (integer), [x,y,z] or "x,y,z", "bld:<id>" (a building), a project
-- id (its bp file's anchor), or part of a unit's name (snapshot.find_units; more than one match = refused with the list).
-- No target: the camera goes back to where the player had it before the first view of the series (st.home), unless he has
-- moved it since (then it is already his).
-- Fair play (RULES 1.1: only what a player can do): only tiles the player has discovered (snapshot.tile: hidden or off the
-- map = refused, so never under the map and never an unexplored tile), only units that are visible and alive; in a fight
-- (SIEGE, BREACH, ALERT, DRILL) the camera is the player's: refused unless the command is by=gordon (his own order); a
-- follow ends at ttl_s (default view.default_ttl_s 300, at most view.max_ttl_s 900), when the unit is gone or hidden, when a
-- fight starts (not for by=gordon) and at once when the player moves the camera himself.
local json = require('dfllm.util.json')

local V = {}
V.CFG = {on = true, default_ttl_s = 300, max_ttl_s = 900}     -- config/baseline.json "view"
V.FIGHT = {SIEGE = true, BREACH = true, ALERT = true, DRILL = true}
V.MOVED = 3          -- tiles the viewport may differ from where we left it before the player is taken to have moved it
V.STEP_MS = 1500     -- follow: how often the unit's tile is read
V.RECENTER = 4       -- follow: tiles the unit walks before the view is centred again (each centring is one logged act)
V.NAMES = 4          -- units listed when a name matches more than one

local function int(v) return math.type(v) == 'integer' and v or math.tointeger(v) end

-- config/baseline.json "view": {on, default_ttl_s, max_ttl_s}; a value of another type or out of range keeps the default
function V.cfg(K)
  local c = {on = V.CFG.on, default_ttl_s = V.CFG.default_ttl_s, max_ttl_s = V.CFG.max_ttl_s}
  local r = type(K.cfg.baseline) == 'table' and K.cfg.baseline.view
  if type(r) == 'table' then
    if type(r.on) == 'boolean' then c.on = r.on end
    local a, b = int(r.default_ttl_s), int(r.max_ttl_s)
    if a and a >= 1 and a <= 3600 then c.default_ttl_s = a end
    if b and b >= 1 and b <= 3600 then c.max_ttl_s = b end
  end
  if c.default_ttl_s > c.max_ttl_s then c.default_ttl_s = c.max_ttl_s end
  return c
end

-- the main viewport's scroll position {window_x, window_y, window_z}, nil when this DF does not show it
function V.cam()
  local ok, r = pcall(function() local g = df.global; return {int(g.window_x), int(g.window_y), int(g.window_z)} end)
  if ok and type(r) == 'table' and r[1] and r[2] and r[3] then return r end
  return nil
end

local function moved(a, b)
  return a[3] ~= b[3] or math.abs(a[1] - b[1]) > V.MOVED or math.abs(a[2] - b[2]) > V.MOVED
end

-- a tile the player has seen: {x, y, z, kind, label} or nil, why
local function place(K, x, y, z, kind, label)
  local okc, t = K.call('snapshot', 'tile', x, y, z)
  if not okc then return nil, 'no tile reader (snapshot is not running): the camera goes nowhere nobody read' end
  if not t then
    return nil, string.format('tile %d,%d,%d is not revealed or off the map: the camera goes only where the player has seen', x, y, z)
  end
  return {x = x, y = y, z = z, kind = kind, label = label}
end

local function unit(K, id)
  local u = df.unit.find(id)
  if not u then return nil, 'no unit ' .. id end
  if dfhack.units.isDead(u) then return nil, 'unit ' .. id .. ' is dead' end
  if u.flags1.inactive then return nil, 'unit ' .. id .. ' is not on the map' end
  if dfhack.units.isHidden(u) then return nil, 'unit ' .. id .. ' is hidden: the player cannot see it either' end
  local p = u.pos
  local ok, name = pcall(function() return dfhack.df2utf(dfhack.units.getReadableName(u)) end)   -- BUG-137: CP437 -> UTF-8
  local t, why = place(K, p.x, p.y, p.z, 'unit', ok and name or ('unit ' .. id))
  if not t then return nil, 'unit ' .. id .. ': ' .. why end
  t.id = id
  return t
end

local function project(K, id)
  local f = io.open(K.cfg.paths.save .. '/bp/' .. id .. '.json', 'rb')
  if not f then return nil end
  local txt = f:read('a')
  f:close()
  local ok, doc = pcall(json.decode, txt)
  local a = ok and type(doc) == 'table' and doc.anchor
  local x, y, z = type(a) == 'table' and int(a[1]), type(a) == 'table' and int(a[2]), type(a) == 'table' and int(a[3])
  if not (x and y and z) then return nil, 'project ' .. id .. ' has no anchor' end
  local t, why = place(K, x, y, z, 'project', id)
  if not t then return nil, 'project ' .. id .. ': ' .. why end
  t.id = id
  return t
end

local function named(K, query)
  local ok, list, total = K.call('snapshot', 'find_units', query, V.NAMES)
  if not ok then return nil, 'no unit reader (snapshot is not running)' end
  list = type(list) == 'table' and list or {}
  if #list == 0 then return nil, 'no visible living unit with "' .. query:sub(1, 40) .. '" in its name' end
  if #list > 1 or (total or #list) > 1 then
    local parts = {}
    for i, e in ipairs(list) do parts[i] = e.id .. ' ' .. tostring(e.name):sub(1, 40) end
    return nil, string.format('%d units match "%s": %s%s; give the id', total or #list, query:sub(1, 30),
                              table.concat(parts, '; '), (total or #list) > #list and '; ...' or '')
  end
  return unit(K, list[1].id)
end

-- the tile the target means: {x, y, z, kind, label, id?} or nil, why
function V.resolve(K, target)
  local t = target
  if math.type(t) == 'integer' then return unit(K, t) end
  if type(t) == 'table' then
    local x, y, z = int(t[1]), int(t[2]), int(t[3])
    if #t ~= 3 or not (x and y and z) then return nil, 'a position is [x,y,z], three integers' end
    return place(K, x, y, z, 'pos', string.format('%d,%d,%d', x, y, z))
  end
  if type(t) ~= 'string' then return nil, 'target must be a unit id, x,y,z, bld:<id>, a project id or part of a name' end
  local a, b, c = t:match('^%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*$')
  if a then return place(K, int(a), int(b), int(c), 'pos', string.format('%d,%d,%d', int(a), int(b), int(c))) end
  local bid = t:match('^bld:(%d+)$')
  if bid then
    local ok, b2 = pcall(df.building.find, int(bid))
    if not ok or not b2 then return nil, 'no building ' .. bid end
    local tl, why = place(K, b2.centerx, b2.centery, b2.z, 'building', 'building ' .. bid)
    if not tl then return nil, 'building ' .. bid .. ': ' .. why end
    tl.id = int(bid)
    return tl
  end
  if t:match('^[A-Za-z0-9_-]+$') and #t <= 40 then
    local tl, why = project(K, t)
    if tl or why then return tl, why end
  end
  return named(K, t)
end

local function label(t)
  return (t.kind == 'unit' and (tostring(t.label) .. ' (' .. t.id .. ') at ') or t.kind == 'pos' and '' or (tostring(t.label) .. ' at '))
         .. string.format('%d,%d z%d', t.x, t.y, t.z)
end

-- the verb: ok, msg, data
function V.verb(K, st, args, cmd)
  local c = V.cfg(K)
  if not c.on then return false, 'view: switched off (config view.on)' end
  local by = cmd and cmd.by
  local mode = K.mode()
  if V.FIGHT[mode] and by ~= 'gordon' then
    return false, string.format('view: %s is a fight: the camera is the player\'s (only a command by=gordon moves it)', mode)
  end
  if args.target == nil then
    local h = st.home
    if not h then return false, 'view: no saved player position (no view has moved the camera yet)' end
    local now = V.cam()
    st.view = nil
    if st.after and now and moved(now, st.after) then
      st.home, st.after = nil, nil
      return true, 'the player has moved the camera since the last view: it is his, nothing to restore'
    end
    local ok, err = K.act.view_window(h[1], h[2], h[3])
    if not ok then return false, 'view: ' .. tostring(err) end
    st.home, st.after = nil, V.cam()
    return true, string.format('camera back at %d,%d z%d', h[1], h[2], h[3]), {back = h}
  end
  local t, why = V.resolve(K, args.target)
  if not t then return false, 'view: ' .. why end
  if st.home == nil then st.home = V.cam() end              -- the player's position before the first view of a series
  local ok, err = K.act.view_to(t.x, t.y, t.z)
  if not ok then return false, 'view: ' .. tostring(err) end
  st.after = V.cam()
  st.view = nil
  local msg = 'camera on ' .. label(t)
  local data = {kind = t.kind, pos = {t.x, t.y, t.z}, id = t.id}
  if args.follow == true then
    if t.kind ~= 'unit' then
      msg = msg .. ' (follow needs a unit: centred once)'
    else
      local ttl = int(args.ttl_s) or c.default_ttl_s
      if ttl > c.max_ttl_s then ttl = c.max_ttl_s end
      st.view = {id = t.id, pos = {t.x, t.y, t.z}, cam = st.after, until_ms = K.now().ms + ttl * 1000, by = by,
                 read_ms = K.now().ms, label = t.label}
      msg = msg .. string.format(', following for %d s (until the player moves the camera)', ttl)
      data.follow, data.ttl_s = true, ttl
    end
  end
  K.log('info', 'view: %s%s%s', msg, by and (' by ' .. by) or '', type(args.why) == 'string' and (': ' .. args.why:sub(1, 80)) or '')
  return true, msg, data
end

-- every arbiter step: keep a follow going, end it when it has run its course
function V.step(K, st)
  local v = st.view
  if not v then return end
  local now = K.now().ms
  local function stop(why)
    st.view = nil
    K.log('info', 'view: follow of %s ended: %s', tostring(v.label), why)
  end
  if now >= v.until_ms then return stop('ttl') end
  if now - v.read_ms < V.STEP_MS and now >= v.read_ms then return end
  v.read_ms = now
  if V.FIGHT[K.mode()] and v.by ~= 'gordon' then return stop(K.mode() .. ' (the camera is the player\'s in a fight)') end
  local cam = V.cam()
  if cam and v.cam and moved(cam, v.cam) then
    st.home, st.after = nil, nil                            -- his camera now: nothing to give back
    return stop('the player moved the camera')
  end
  local u = df.unit.find(v.id)
  if not u or dfhack.units.isDead(u) or u.flags1.inactive or dfhack.units.isHidden(u) then return stop('the unit is gone or hidden') end
  local p = u.pos
  if p.z ~= v.pos[3] or math.abs(p.x - v.pos[1]) >= V.RECENTER or math.abs(p.y - v.pos[2]) >= V.RECENTER then
    local t = place(K, p.x, p.y, p.z, 'unit', v.label)
    if not t then return stop('the unit left the revealed map') end
    local ok = K.act.view_to(p.x, p.y, p.z)
    if not ok then return stop('the camera could not be moved') end
    v.pos, v.cam, st.after = {p.x, p.y, p.z}, V.cam(), V.cam()
  end
end

return V
