-- Round 28 (fix28-water): BUG-446 a brook (1-3/7, tiletype BROOK_BED / BROOK_TOP) is water the scan sees and the citizens drink at, and
-- water only far away is no supply when the drink runs out; BUG-448 a finished aqshaft / cistern queues the water scan; BUG-449 the
-- GiveWater verdict says when the accepted water lies on another walk group than the patient, and the decisions carry commands.
-- Every test fails on ca237a0.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local C = require('dfllm.util.contract')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DEPTH = {['~'] = 7, w = 2, b = 2}              -- b: a brook tile (1-3/7 over a BROOK_BED)

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'pond_remove'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

-- tiles {['x,y,z'] = c}; the water scan world of test_bug288_291 with the brook flag of snapshot.liquids
local function world(opts)
  opts = opts or {}
  owners()
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, pos = {12, 12, 5}} end
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 199, 199, 20}}}}
  local cfg = F.cfg()
  cfg.water = opts.water
  local W = F.world{cfg = {baseline = cfg}, units = units, persist = {manifest = man}}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.civzone_type.Pond, df.civzone_type[11] = 11, 'Pond'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  local ids = {}
  for i = 1, 4 do
    ids[i] = i
    W.unit(i).counters2 = {thirst_timer = 1000}
    W.unit(i).job = {current_job = nil}
  end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 199, 199, 20})
  W.cmap = opts.tiles or {}
  W.brook_arg = {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z)
    local c = W.cmap[x .. ',' .. y .. ',' .. z] or '#'
    if c == '?' then return nil end
    return {c = c == 'b' and 'w' or c, dig = '', bld = '', flow = DEPTH[c] or 0, aq = false}
  end
  function snap.liquids(K, x0, y0, x1, y1, z, min, ice, lat, brook)
    W.brook_arg[#W.brook_arg + 1] = brook or false
    min = min or 1
    local out = {}
    local area = (x1 - x0 + 1) * (y1 - y0 + 1)
    if (lat and (area + lat - 1) // lat or area) > 4096 then return nil, 'rect too large' end
    local need = (brook and brook >= 1 and brook < min) and brook or min
    for y = y0, y1 do
      for x = x0, x1 do
        if not lat or (x + 2 * y) % lat == 0 then
          local c = W.cmap[x .. ',' .. y .. ',' .. z] or ''
          local f = DEPTH[c] or 0
          if f >= need then
            local br = f < min and c == 'b'
            if f >= min or br then out[#out + 1] = {x, y, f, 0, nil, br and 1 or nil} end
          end
        end
      end
    end
    return out
  end
  function snap.reach(K, a, b) return true end
  W.groups = {}
  function snap.groups(K, pts)
    local out = {}
    for i, p in ipairs(pts) do out[i] = W.groups[p.x .. ',' .. p.y .. ',' .. p.z] or -1 end
    return out
  end
  function snap.map_size() return 192, 192, 20 end
  function snap.surface_z() return 7 end
  W.load(snap)
  W.load({name = 'runner', every = {ticks = 600}, pending = function() return 0 end,
          kept_in = function() return nil end, bp_params = function() return {} end,
          aq_seen = function() return true end})
  F.hospital(W, {10, 10, 14, 14, 5})
  local M = fresh('water')
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, n or 1 do W.run(1200, {skip = 10}) end end
local function ws(W, M)
  local ok, msg, d = M.inspect(W.K, 'water_sources')
  T.ok(ok, msg)
  return msg, d
end
local function line(tiles, ch, y, x0, x1, z)
  for x = x0, x1 do
    tiles[x .. ',' .. y .. ',' .. z] = ch
    tiles[x .. ',' .. (y - 1) .. ',' .. z] = '.'
  end
  return tiles
end

---------------------------------------------------------------- BUG-446: the brook
T.test('BUG-446 (Run 16b i2 / 16c i3: brook=in on the embark scan, the water scan met nothing): a brook of 2/7 far from the fort is a body ' ..
       'with a bank, it counts for drink_access, but it is no zone candidate and gets its own recipe', function()
  local W, M = world{tiles = line({}, 'b', 150, 120, 170, 7)}
  day(W, 3)
  local msg, d = ws(W, M)
  local found
  for _, b in ipairs(d.bodies) do if b.z == 7 and b.n >= 40 then found = b end end
  T.ok(found, 'old code: tiles under deep (4/7) are never read: ' .. msg)
  T.eq(found.brook, 1, 'flagged as a shallow brook')
  T.ok(found.bank ~= nil, 'its bank is reachable')
  T.ok(found.pit == nil, 'no well spot over 2/7')
  T.ok(tostring(d.way):find('brook', 1, true), tostring(d.way))
  T.eq(#M.zone_cands(d), 0, 'the game takes no Water Source zone below 4/7')
  local a = M.drink_access(W.K)
  T.ok(a.ok and a.bank >= 1, 'the brook counts as water the citizens reach')
  local saw = false
  for _, b in ipairs(W.brook_arg) do if b == 1 then saw = true end end
  T.ok(saw, 'the scan reads brook tiles from brook_min up')
  T.ok(M.recipe(M.conf(W.K), nil, W.K, true, true):find('brook at 120,150,7', 1, true), M.recipe(M.conf(W.K), nil, W.K, true, true))
end)

T.test('BUG-446: brook_min 0 switches it off (the old scan: only >= 4/7)', function()
  local W, M = world{tiles = line({}, 'b', 150, 120, 170, 7), water = {brook_min = 0}}
  day(W, 3)
  local _, d = ws(W, M)
  local found
  for _, b in ipairs(d.bodies) do if b.z == 7 then found = b end end
  T.eq(found, nil)
  for _, b in ipairs(W.brook_arg) do T.eq(b, false) end
end)

T.test('BUG-446 (Run 16b i2 Roadvises: a pond 72 tiles away was "reachable water", drink 0 days): drink_access marks water only farther ' ..
       'than drink_far tiles as far, with the nearest water tile; a near one is not', function()
  local W, M = world{tiles = line({}, '~', 150, 120, 170, 7)}
  day(W, 3)
  local a = M.drink_access(W.K)
  T.ok(a.ok and a.far == true, 'far: ' .. tostring(a.far))
  T.ok(a.bd and a.bd > 40, tostring(a.bd))
  T.ok(type(a.bat) == 'table' and a.bat[3] == 7, 'the water tile to pipe from')
  local W2, M2 = world{tiles = line({}, '~', 30, 20, 40, 5)}
  day(W2, 3)
  local a2 = M2.drink_access(W2.K)
  T.ok(a2.ok and a2.far == nil, 'a pond 18 tiles away is near')
end)

---------------------------------------------------------------- BUG-446: economy asks when the water is far
local SEASONS = {SPRING = true, SUMMER = true, AUTUMN = true, WINTER = true}
local function raw(id, flags, depth)
  local f = {SEED = true}
  for k, v in pairs(flags) do f[k] = v end
  return {id = id, flags = f, underground_depth_min = depth or 0, growths = kmock.vec{}}
end
local function days(W, n)
  for _ = 1, n do
    W.run(1200, {skip = 100})
    for _ = 1, 60 do W.run(1) end
  end
end
local function decisions(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function econ_world(opts)
  local cit = 7
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local cfg = F.cfg()
  cfg.economy.standing = false
  local W = F.world{cfg = {baseline = cfg}, units = units}
  local ids = {}
  for i = 1, cit do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.set_census('u', F.census_u(ids))
  df.global.world.raws.plants.all = kmock.vec{raw('MUSHROOM_HELMET_PLUMP', SEASONS, 1)}
  F.mat(W, 419, 60, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:SEED'})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = opts.drinks or 70})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  if (opts.plants or 0) > 0 then F.item(W, 'PLANT', {stack_size = opts.plants, mat_type = 419, mat_index = 60}) end
  W.load({name = 'water', every = {ticks = 100000}, drink_access = function() return opts.access end,
          drink_fix = function()
            return 'no accepted water; the water at 25,153,122 (7/7) is 72 tiles off: zone it from the bank', {'dfllm cmd inspect what=water_sources'}
          end})
  F.workshop(W, 'Still')
  F.workshop(W, 'Kitchen')
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.', bld = '', dig = ''} end,
          plot_under = function() return true end})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          state = function() return {phase = 'P1'} end})
  W.load(fresh('economy'))
  return W
end
local FAR = {known = true, ok = true, acc = 0, bank = 1, bodies = 1, partial = 0, far = true, far_d = 120, bd = 72, bat = {25, 153, 122}}

T.test('BUG-446: water reachable only 72 tiles off, no accepted source, no brewable plant, drink short: DECISION_NEEDED no_water that says so ' ..
       'and names the cistern command at the nearest water; a PROJECT_REQUEST cistern follows', function()
  local W = econ_world{access = FAR, drinks = 30}      -- ~80 drink days < drink_far_d (120)
  days(W, 1)
  local d = decisions(W, 'no_water')
  T.eq(#d, 1, 'old code: ok = bank > 0, no question')
  T.eq(d[1].cls, 'A')
  T.ok(d[1].msg:find('72 tiles', 1, true), d[1].msg)
  local joined = table.concat(d[1].d.cmds, '\n')
  T.ok(joined:find('cistern --near 25,153,122', 1, true) and joined:find('trade.want', 1, true), joined)
  local rq
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == 'no_water' then rq = e end end
  T.ok(rq and rq.d.tpl == 'cistern' and rq.d.at[1] == 25 and rq.d.n == 72, 'request at the water')
end)

T.test('BUG-446: far water but a brewable plant in stock, or plenty of drink, or a near source: no question', function()
  for name, o in pairs({plants = {access = FAR, plants = 40, drinks = 30}, stock = {access = FAR, drinks = 5000},
                        near = {access = {known = true, ok = true, acc = 0, bank = 1, bodies = 1, partial = 0}, drinks = 30}}) do
    local W = econ_world(o)
    days(W, 2)
    T.eq(#decisions(W, 'no_water'), 0, name)
  end
end)

---------------------------------------------------------------- BUG-448: the scan after a finished aqshaft / cistern
T.test('BUG-448 (Run 16d i4: aqshaft and cistern 100 %, the water scan 7.3 M ticks old): PROJECT_DONE of an aqshaft or cistern queues the ' ..
       'scan at once and once more ws_redo ticks later; other templates do not', function()
  local W, M = world{tiles = line({}, '~', 30, 20, 40, 5)}
  day(W, 2)
  local _, d0 = ws(W, M)
  T.ok(d0.tick, 'first scan done')
  M.on['EV:PROJECT_DONE'](W.K, {d = {tpl = 'bedrooms', proj = 'y1s0b0'}})
  local _, dq = ws(W, M)
  T.eq(dq.queued, 0, 'a bedrooms project changes no water')
  M.on['EV:PROJECT_DONE'](W.K, {d = {tpl = 'aqshaft', proj = 'y403s1b2'}})
  local _, d1 = ws(W, M)
  T.eq(d1.queued, 1, 'old code: nothing queued')
  day(W, 2)
  local _, d2 = ws(W, M)
  T.ok(d2.tick > d0.tick, 'scanned again after the aqshaft')
  day(W, 3)
  local _, d3 = ws(W, M)
  T.ok(d3.tick > d2.tick, 'and once more after ws_redo (3 days), the cistern fills')
  local logged = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('aqshaft y403s1b2 finished', 1, true) then logged = true end end
  T.ok(logged, 'kern.log names it')
end)

---------------------------------------------------------------- BUG-449: the water on another walk group
T.test('BUG-449 (Run 16a i1 Syrupobeyed: patients at 94,113,135 died under "2 GiveWater jobs running", the zone at 106,109,139): src_reach says ' ..
       'when no accepted source lies on the patient\'s walk group; give_diag names it, the decision carries commands', function()
  local W, M = world{}
  local groups = W.groups
  groups['94,113,135'] = 5
  groups['106,109,139'] = 9
  local r = {sources = {{kind = 'zone', id = 17697, x = 106, y = 109, z = 139, wet = true}}, carers = {}, carers_idle = 0, cpos = {},
             buckets = 25, hosp = {}}
  local top = {id = 26664, x = 94, y = 113, z = 135, thirst = 40000}
  local sr = M.src_reach(W.K, r, top)
  T.eq(sr.ok, false, 'old code: no such test')
  T.eq({sr.g, sr.gs, sr.d}, {5, 9, 12})
  local gv = M.give_diag(W.K, M.conf(W.K), r, {read = true, w_open = 0, w_run = 2, stuck = 0}, 15, top)
  T.eq(gv.key, 'srcreach')
  T.ok(gv.reason:find('walk group 5', 1, true) and gv.reason:find('zone 17697 at 106,109,139', 1, true), gv.reason)
  local cmds = table.concat(M.patient_cmds(gv, top), '\n')
  T.ok(cmds:find('bp sites cistern --near 94,113,135', 1, true) and cmds:find('inspect what=unit key=26664', 1, true), cmds)
  groups['106,109,139'] = 5                      -- the same group: the verdict is the old one
  local gv2 = M.give_diag(W.K, M.conf(W.K), r, {read = true, w_open = 0, w_run = 2, stuck = 0}, 15, top)
  T.eq(gv2.key, 'run')
  T.eq(M.src_reach(W.K, r, top).ok, true)
  groups['106,109,139'] = -1                     -- unread: unknown, not a verdict
  T.eq(M.src_reach(W.K, r, top), nil)
end)

T.test('BUG-449: src_near: the accepted source near a position, none when it stands inside Kern+ / Tiefe+ (then water did not draw them out)', function()
  local W, M = world{}
  T.eq(M.src_near(W.K, 164, 170, 137, 20), nil, 'before the first run')
end)

T.done()
