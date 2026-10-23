-- care, package L1 (BUG-102, FR-82; Run 11/14 note 73): the drink nook of a strange mood refused with "no free floor within
-- 3 tiles" although floor tiles looked free. The refusal now says why in counts (occupied, unreachable, wrong shape,
-- too far), a tile with an item, a plant, a designation or a planned building is no nook, a critical mood (thirst past
-- mood_crit, hunger past mood_crit_hunger) widens the search 3 -> 6 -> 9 tiles, and a nook quickfort refuses ("tile
-- occupied") is skipped: the next site is tried. Every test here fails on the commit before the package (3045b94).
local T = require('testlib')
local CW = require('care_world')
local F = CW.F

local function filter(spec)
  local f = {item_type = -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

-- a strange mood: unit `id` claims a Craftsdwarfs workshop at 22..24,22..24 z5
local function moody(W, id, kind, thirst, hunger)
  local u = W.unit(id)
  u.mood = df.mood_type[kind]
  u.counters2 = {thirst_timer = thirst or 0, hunger_timer = hunger or 0}
  local shop = F.workshop(W, 'Craftsdwarfs')
  shop.x1, shop.y1, shop.x2, shop.y2, shop.z = 22, 22, 24, 24, 5
  u.job.current_job = CW.mood_job(W, 900 + id, shop, {filter({flags2 = {bone = true, body_part = true}})})
  return u, shop
end

local function events(W, name, why)
  local r = {}
  for _, e in ipairs(W.find_events(name)) do if why == nil or e.d.why == why then r[#r + 1] = e end end
  return r
end

-- o.floor(x, y) -> true when the tile is open floor (default: x, y in 18..28); o.cat(x, y) -> 'wall' | 'plant' | 'dig' |
-- 'bld' | 'occ' | nil (what is on the tile); o.items = {'x,y', ...} (item_tiles answers); o.reach(a, b) -> bool;
-- o.cit; o.setup(W); o.qf(p, n) -> ok, stats (the quickfort act; n counts the calls)
local function nook_world(o)
  o = o or {}
  local W
  local items = {}
  for _, k in ipairs(o.items or {}) do items[k] = 1 end
  local floor = o.floor or function(x, y) return x >= 18 and x <= 28 and y >= 18 and y <= 28 end
  local W_, Cm = CW.world{cit = o.cit or 6, runner = true, mode = o.mode, reach = o.reach,
    tile = function(x, y, z)
      W.tile_reads = (W.tile_reads or 0) + 1
      if not floor(x, y) then return {c = '#', dig = '', bld = ''} end
      local cat = o.cat and o.cat(x, y)
      if cat == 'wall' then return {c = '#', dig = '', bld = ''} end
      return {c = '.', dig = cat == 'dig' and 'default' or '', bld = cat == 'bld' and 'Bed' or '',
              plant = cat == 'plant' and 'shrub' or nil, occ = cat == 'occ' and 1 or 0, shape = 'FLOOR'}
    end,
    snap = {item_tiles = function(K, x0, y0, x1, y1, z)
      W.item_calls = (W.item_calls or 0) + 1
      local r = {}
      for k, n in pairs(items) do
        local x, y = k:match('^(%d+),(%d+)$')
        x, y = tonumber(x), tonumber(y)
        if x >= x0 and x <= x1 and y >= y0 and y <= y1 then r[k] = n end
      end
      return r
    end},
    setup = function(Wx)
      df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'       -- what care's tomb phase reads (test_care_b3 world)
      df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
      CW.tomb_acts(Wx)
      df.global.building_next_id = 1000
      Wx.qf = {}
      Wx.act_result('quickfort', function(p)
        Wx.qf[#Wx.qf + 1] = {mode = p.mode, pos = p.pos, data = p.data}
        if o.qf then return o.qf(p, #Wx.qf) end
        return true, {}
      end)
      if o.setup then o.setup(Wx) end
    end}
  W = W_
  W.K.cfg.baseline.care.coffins = false             -- the coffin phase scans a fake map of walls for many frames
  return W, Cm
end

local function projects(W)
  local n, last = 0, nil
  for _, x in ipairs((W.K.persist.get('projects') or {}).list or {}) do
    if x.tpl == 'mood_drink' then n, last = n + 1, x end
  end
  return n, last
end

local function logs(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then n = n + 1 end end
  return n
end

---------------------------------------------------------------- BUG-102: the refusal names the reason
-- rings 1 and 2 around the workshop (22..24 x 22..24) hold one reason each; ring 3 is open floor with items
local function ring_cat(x, y)
  if x == 26 then return 'wall' end
  if y == 20 and x >= 21 and x <= 25 then return 'plant' end
  if y == 26 and x >= 21 and x <= 25 then return 'dig' end
  if y == 25 and x >= 21 and x <= 25 then return 'bld' end
  if x == 25 and y >= 22 and y <= 24 then return 'occ' end
  return nil
end

T.test('BUG-102: a refusal names the reasons in counts (occupied, unreachable, wrong shape, too far), within 200 bytes', function()
  local items = {}
  for x = 21, 25 do items[#items + 1] = x .. ',21' end                       -- ring 1, north row
  for y = 19, 27 do for x = 19, 27 do                                         -- ring 3: all items
    if x == 19 or x == 27 or y == 19 or y == 27 then items[#items + 1] = x .. ',' .. y end
  end end
  local W = nook_world{items = items, cat = ring_cat, reach = function(a) return a.x ~= 20 end,
    setup = function(W)
      F.building(W, 'STOCKPILE', {x1 = 21, y1 = 22, x2 = 21, y2 = 24, z = 5})
    end}
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  local r = events(W, 'MOOD_RISK', 'thirst')
  T.eq(#r, 1)
  -- 72 candidates: 3 zone tiles (no read), 7 x 20 unreachable, 7 x 26 wall; the 40-tile read budget ends in ring 3
  T.ok(r[1].msg:find('no nook within 3: ', 1, true), r[1].msg)
  T.ok(not r[1].msg:find('no free floor', 1, true), r[1].msg)
  T.ok(#r[1].msg <= 200, #r[1].msg)
  T.ok(r[1].msg:find('7 unreachable', 1, true), r[1].msg)
  T.ok(r[1].msg:find('7 wrong shape', 1, true), r[1].msg)
  T.ok(r[1].msg:find('occupied', 1, true) and r[1].msg:find('too far', 1, true), r[1].msg)
  local occ, far = r[1].msg:match('(%d+) occupied'), r[1].msg:match('(%d+) too far')
  T.eq(tonumber(occ) + tonumber(far) + 14, 72, 'every candidate tile is counted once')
  T.eq(projects(W), 0, 'nothing queued')
end)

T.test('BUG-102: the read budget is said as "too far"; a plain refusal text stays short', function()
  local items = {}
  for y = 18, 28 do for x = 18, 28 do items[#items + 1] = x .. ',' .. y end end
  local W = nook_world{items = items}
  W.K.cfg.baseline.care.mood_nook_probes = 5
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  local r = events(W, 'MOOD_RISK', 'thirst')
  T.ok(r[1].msg:find('no nook within 3: 5 occupied, 67 too far', 1, true), r[1].msg)
end)

---------------------------------------------------------------- BUG-102: what is no free tile
T.test('BUG-102: a free-looking tile with an item, a plant, a designation or a planned building is no nook', function()
  local W = nook_world{items = {'22,21', '23,21'}, cat = function(x, y)
    if x == 24 and y == 21 then return 'plant' end
    if x == 21 and y == 22 then return 'dig' end
    if x == 25 and y == 22 then return 'occ' end
    return nil
  end}
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  local r = events(W, 'MOOD_RISK', 'thirst')
  T.ok(r[1].msg:find('drink nook queued at 21,23,5', 1, true), r[1].msg)       -- the old code: 22,21,5
  local _, P = projects(W)
  local c = W.K.persist.get('bp.' .. P.id).stages[1].chunks[1]
  T.eq(c.pos, {21, 23, 5})
end)

T.test('BUG-102: an existing stockpile or zone is no nook; the tile beside it is', function()
  local W = nook_world{setup = function(W)
    F.building(W, 'STOCKPILE', {x1 = 22, y1 = 21, x2 = 23, y2 = 21, z = 5})
    F.building(W, 'ANY_ZONE', {x1 = 24, y1 = 21, x2 = 24, y2 = 21, z = 5})
  end, items = {'21,22'}}
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  T.ok(events(W, 'MOOD_RISK', 'thirst')[1].msg:find('drink nook queued at 25,22,5', 1, true),
       events(W, 'MOOD_RISK', 'thirst')[1].msg)
end)

T.test('BUG-102: a tile reachable from the dwarf but not from the workshop corner is a nook (either anchor)', function()
  -- the dwarf stands at 5,5,5: only tiles with x == 21 are reachable from him, none from the workshop corner
  local W = nook_world{reach = function(a, b) return b.x == 5 and a.x == 21 end}
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  T.ok(events(W, 'MOOD_RISK', 'thirst')[1].msg:find('drink nook queued at 21,22,5', 1, true),
       events(W, 'MOOD_RISK', 'thirst')[1].msg)
end)

---------------------------------------------------------------- FR-82: the search widens for a critical mood
-- all open floor is far: only 22,16 (6 tiles north of the workshop) and 22,32 (8 south) are floor
local function far_floor(extra)
  return function(x, y)
    if x == 22 and y == 16 then return true end
    return extra and extra(x, y) or false
  end
end

T.test('FR-82: a risk (thirst 41,000) does not widen; a critical thirst (51,000) widens to 6 and queues the nook', function()
  local W = nook_world{floor = far_floor()}
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  local r = events(W, 'MOOD_RISK', 'thirst')
  T.ok(r[1].msg:find('no nook within 3: 72 wrong shape', 1, true), r[1].msg)
  T.eq(projects(W), 0)
  -- the same dwarf, still inside the retry window, passes the critical bar: the widening does not wait for the retry
  W.unit(2).counters2.thirst_timer = 51000
  W.run(450, {skip = 50})
  local n, P = projects(W)
  T.eq(n, 1, 'the widened search found 22,16,5')
  T.eq(W.K.persist.get('bp.' .. P.id).stages[1].chunks[1].pos, {22, 16, 5})
  local c = events(W, 'MOOD_CRITICAL')
  T.ok(#c >= 1 and c[1].msg:find('drink nook queued at 22,16,5', 1, true), c[1] and c[1].msg)
  T.ok(c[1].msg:find(' r6', 1, true), 'the line says how far the nook is: ' .. c[1].msg)
  T.ok(#c[1].msg <= 200)
end)

T.test('FR-82: hunger is critical only past mood_crit_hunger (60,000), not past mood_crit (50,000)', function()
  local W = nook_world{floor = far_floor()}
  moody(W, 2, 'Fey', 0, 55000)
  W.run(1)
  T.eq(projects(W), 0, 'hunger 55,000 is a risk, not critical: no widening')
  W.unit(2).counters2.hunger_timer = 61000
  W.run(450, {skip = 50})
  T.eq(projects(W), 1, 'hunger 61,000 is critical: widened')
end)

T.test('FR-82: the steps are 3, 6, 9 (mood_nook_rmax bounds them); a floor 8 tiles out is found only by the 9 step', function()
  local W = nook_world{floor = function(x, y) return x == 33 and y == 23 end}                       -- 9 east of x 24
  moody(W, 2, 'Possessed', 55000, 0)
  W.K.cfg.baseline.care.mood_nook_rmax = 6
  W.run(1)
  T.eq(projects(W), 0, 'mood_nook_rmax 6: 33,23 is 9 tiles out')
  T.ok(events(W, 'MOOD_CRITICAL')[1].msg:find('no nook within 6: ', 1, true), events(W, 'MOOD_CRITICAL')[1].msg)
  local W2 = nook_world{floor = function(x, y) return x == 33 and y == 23 end}
  moody(W2, 2, 'Possessed', 55000, 0)
  W2.run(1)
  T.eq(projects(W2), 1, 'the default steps 3, 6, 9 reach it')
  T.ok(events(W2, 'MOOD_CRITICAL')[1].msg:find('drink nook queued at 33,23,5', 1, true), events(W2, 'MOOD_CRITICAL')[1].msg)
  local W3 = nook_world{floor = function(x, y) return x == 33 and y == 23 end}
  moody(W3, 2, 'Possessed', 55000, 0)
  W3.K.cfg.baseline.care.mood_nook_rmax = 0
  W3.run(1)
  T.eq(projects(W3), 0, 'mood_nook_rmax 0: never widen')
  T.ok(events(W3, 'MOOD_CRITICAL')[1].msg:find('no nook within 3: ', 1, true), events(W3, 'MOOD_CRITICAL')[1].msg)
end)

T.test('FR-82: a widened search still needs a free, reachable tile (items, plants, zones, unreachable all counted)', function()
  local W = nook_world{
    floor = function(x, y) return x >= 22 and x <= 24 and y >= 15 and y <= 17 end,           -- 9 tiles, 5..7 north of the shop
    items = {'22,17', '23,17', '24,17'}, cat = function(x, y) return y == 16 and 'plant' or nil end,
    reach = function(a) return a.y ~= 15 end}
  moody(W, 2, 'Fey', 52000, 0)
  W.run(1)
  T.eq(projects(W), 0)
  local m = events(W, 'MOOD_CRITICAL')[1].msg
  T.ok(m:find('no nook within 9: ', 1, true), m)
  T.ok(m:find('6 occupied', 1, true) and m:find('3 unreachable', 1, true), m)
end)

T.test('FR-82: no reachable floor at all: the widening reads a bounded number of tiles and says so; fort of 7 and 80', function()
  for _, cit in ipairs({7, 80}) do
    local W = nook_world{cit = cit, reach = function() return false end}
    moody(W, 2, 'Fey', 52000, 0)
    W.run(1)
    T.eq(projects(W), 0)
    local m = events(W, 'MOOD_CRITICAL')[1].msg
    T.ok(m:find('no nook within 9: ', 1, true) and m:find('unreachable', 1, true), m)
    T.ok((W.reach_calls or 0) <= 2 * 3 * 40, 'bounded reach reads: ' .. tostring(W.reach_calls))
    T.eq(W.item_calls, 1, 'the items of the box are read once for the whole widened search')
    T.ok(#m <= 200)
  end
end)

T.test('FR-82: a siege queues no nook and reads no tile, critical or not', function()
  local W = nook_world{mode = 'SIEGE', floor = far_floor()}
  moody(W, 2, 'Fey', 55000, 0)
  W.run(1)
  T.eq(projects(W), 0)
  T.eq({W.item_calls or 0, W.reach_calls or 0}, {0, 0}, 'old code: also none; the widening must not add a read')
  local W2 = nook_world{floor = far_floor()}                  -- and in peace the widening does queue (the failing half)
  moody(W2, 2, 'Fey', 55000, 0)
  W2.run(1)
  T.eq(projects(W2), 1)
end)

---------------------------------------------------------------- cadence
T.test('BUG-102: the same refusal for the same unit is logged once and searched once per retry window', function()
  local items = {}
  for y = 18, 28 do for x = 18, 28 do items[#items + 1] = x .. ',' .. y end end
  local W = nook_world{items = items}
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  T.eq(W.item_calls, 1)
  W.run(1500, {skip = 100})
  T.eq(W.item_calls, 1, 'inside mood_nook_retry (3600) nothing is read again')
  W.run(4000, {skip = 100})
  T.eq(W.item_calls, 2, 'after the retry window the search runs again')
  T.eq(logs(W, 'no nook within 3'), 1, 'the same reason for the same unit is logged once')
  T.eq(#events(W, 'MOOD_RISK', 'thirst'), 1, 'MOOD_RISK follows its own cadence')
end)

---------------------------------------------------------------- quickfort refuses the tile
local function refuse_first(n)
  return function(p, k)
    if k <= n then return true, {place_designated = 0, place_occupied = 1} end
    return true, {place_designated = 1, place_tiles = 1}
  end
end

T.test('BUG-102: a nook quickfort refuses ("tile occupied") is skipped: the next site is queued in the same mood', function()
  local W = nook_world{qf = refuse_first(2)}
  moody(W, 2, 'Fey', 41000, 0)
  W.run(2500, {skip = 100})
  local n = projects(W)
  T.eq(n, 3, 'two refused, the third stands')
  T.eq(#W.qf, 3)
  local sites = {}
  for _, q in ipairs(W.qf) do sites[#sites + 1] = q.pos[1] .. ',' .. q.pos[2] end
  T.eq(sites, {'22,21', '23,21', '24,21'}, 'each refused tile is skipped by the next probe')
  T.eq(logs(W, 'refused by quickfort'), 2)
  local nk = W.K.persist.get('m.care').nook['2']
  T.ok(nk.txt:find('drink nook queued at 24,21,5', 1, true), nk.txt)
  W.run(3000, {skip = 100})
  T.eq(projects(W), 3, 'a nook that stands is not queued again')
end)

T.test('BUG-102: re-picks after quickfort refusals are bounded per unit and day (mood_nook_tries)', function()
  local W = nook_world{qf = function() return true, {place_designated = 0, place_occupied = 1} end}
  W.K.cfg.baseline.care.mood_nook_tries = 1
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1100, {skip = 100})
  T.eq(projects(W), 1, 'one attempt in the first game day, then the unit waits')
  W.run(500, {skip = 100})
  local why = W.K.persist.get('m.care').moods['2'].nook_why
  T.ok(why and why:find('quickfort', 1, true), tostring(why))
  W.run(2000, {skip = 100})
  local n = projects(W)
  T.ok(n >= 2 and n <= 3, 'the next game day allows the next attempt, one a day at most: ' .. n)
end)

---------------------------------------------------------------- what stays as it was
T.test('BUG-102: a mood that ends, an old state without the new fields and a legacy nook record are no fault', function()
  local W = nook_world{qf = refuse_first(1)}
  local u = moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  T.eq(projects(W), 1)
  -- the mood ends before the runner has answered
  u.mood = -1
  W.run(1500, {skip = 100})
  T.eq(#W.find_events('MOOD_END'), 1)
  T.eq(projects(W), 1, 'no second nook for a unit that is no longer moody')
  -- a record of the old kernel (no site, no ok) and a runner that does not know the project: the text stays
  local W2 = nook_world{}
  moody(W2, 2, 'Fey', 41000, 0)
  W2.run(1)
  local p = W2.K.persist.get('m.care')
  p.nook['2'] = {t = 1, id = 'mdr-gone', txt = 'drink nook queued at 1,1,5 (mdr-gone)'}
  p.moods['2'].nook_try = nil
  W2.run(450, {skip = 50})
  T.eq(projects(W2), 1, 'unknown project: kept as it was, nothing queued')
  T.eq(#W2.find_events('KERN_FAULT'), 0)
  -- a record of the old kernel (nook_try and nook_why only) meets a critical thirst: the widening starts at once
  local W3 = nook_world{floor = far_floor()}
  moody(W3, 2, 'Fey', 41000, 0)
  W3.run(1)
  local rec = W3.K.persist.get('m.care').moods['2']
  rec.nook_wide, rec.nook_n, rec.nook_day, rec.bad = nil, nil, nil, nil
  W3.unit(2).counters2.thirst_timer = 52000
  W3.run(450, {skip = 50})
  T.eq(projects(W3), 1, 'the old record is widened')
  T.eq(#W3.find_events('KERN_FAULT'), 0)
end)

T.done()
