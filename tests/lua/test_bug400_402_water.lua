-- BUG-400 (Run 16a Mansionlauded, Bachwald: 13 of 16 dead of thirst beside a frozen river): the sites export lists the ice
-- tiles and keeps no water char on them; BUG-401: the early drink check -- no water the citizens reach and no brewable
-- plant -> DECISION_NEEDED no_water at once, no 'they drink water' all-clear, gatherers and caravans; water.drink_access
-- says whether any water is reachable. Every test fails on 503bb8b.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local SW = require('snapshot_world')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

---------------------------------------------------------------- BUG-400: the snapshot lists ice
local Z = 10
T.test('BUG-400: an ice floor is no water char even with a flow left on it; the sites export lists the ice tiles', function()
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_bug400'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  local W = kmock.new{persist = {manifest = {v = 2}}, ms_per_frame = 100, dfpath = dir,
                      units = {{id = 1, citizen = true, pos = {0, 0, Z}}}}
  SW.install(W)
  SW.draw(W, Z, {'.ii~.'}, 0, 0)                   -- floor, ice, ice, open water 6/7, floor
  SW.draw(W, Z - 1, {'.~~~.'}, 0, 0)               -- the water under the ice
  package.loaded['dfllm.snapshot'] = nil
  W.load(require('dfllm.snapshot'))
  W.inbox('snapshot', {purpose = 'sites', bbox = {0, 0, Z - 1, 4, 0, Z}}, {id = 'ice1', by = 'cli'})
  for _ = 1, 20 do W.frame(0, true) end
  local doc
  for _, e in ipairs(W.find_events('SNAPSHOT_READY')) do
    if e.d.id == 'ice1' then
      local f = assert(io.open(dir .. '/dfllm-runtime/mock/' .. e.d.path, 'rb'))
      doc = json.decode(f:read('a'))
      f:close()
    end
  end
  T.ok(doc, 'written')
  T.eq(doc.rows['z' .. Z][1], '...~.', 'old code: ".~~~." (the ice carried its flow as water)')
  T.eq(doc.ice, {{1, 0, Z}, {2, 0, Z}}, 'the ice tiles, x y z')
  T.eq(doc.rows['z' .. (Z - 1)][1], '.~~~.', 'the water under it stays water')
end)

---------------------------------------------------------------- BUG-401: the drink check
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
local function log_has(W, s)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then return true end end
  return false
end

-- opts: access (water.drink_access's answer), drinks, plants (brewable plant stacks)
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
            return 'no accepted water; zone the water at 58,0,158 (7/7) as Water Source',
                   {'dfllm cmd inspect what=water_sources', 'dfllm bp sites cistern'}
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

local NONE = {known = true, ok = false, acc = 0, bank = 0, bodies = 1, partial = 1}

T.test('BUG-401: no water the citizens reach and no brewable plant: DECISION_NEEDED no_water on the first day, with the ' ..
       'commands; the status line says it, no "they drink water"', function()
  local W = econ_world{access = NONE}
  days(W, 1)
  local d = decisions(W, 'no_water')
  T.eq(#d, 1, 'old code: only drink_low later, thirst when they are thirsty')
  T.eq(d[1].cls, 'A')
  local joined = table.concat(d[1].d.cmds, '\n')
  T.ok(joined:find('inspect what=water_sources', 1, true) and joined:find('bp sites cistern', 1, true)
       and joined:find('trade.want', 1, true) and joined:find('inspect what=reach', 1, true), joined)
  T.ok((d[1].d.water[1] or ''):find('Water Source', 1, true), 'the fix text is in d.water')
  local dwhy = W.state().stock.dwhy or ''
  T.ok(dwhy:find('no reachable water', 1, true) and not dwhy:find('nobody thirsty', 1, true), dwhy .. ' / ' .. json.encode(W.state().stock))
  T.ok(not log_has(W, 'nobody thirsty'), 'no all-clear line')
  T.ok(log_has(W, 'no reachable water and no brewable plant'), 'kern.log')
  days(W, 3)
  T.eq(#decisions(W, 'no_water'), 1, 'once a week, not daily')
  W.wall0 = W.wall0 + 3600                       -- the wall clock gate (10 min) is the longer one at speed
  days(W, 5)
  T.eq(#decisions(W, 'no_water'), 2, 'again after 7 days while it holds')
end)

T.test('BUG-401: the caravans are asked for plants and drink at once (state stock, trade wants), not only below 60 days', function()
  local W = econ_world{access = NONE, drinks = 200}
  days(W, 1)
  local seen = false
  for _, w in ipairs(select(2, W.K.call('economy', 'trade_wants')) or {}) do
    if w.buy == 'plant' or w.buy == 'drink' then seen = true end
  end
  T.ok(seen, 'plant/drink wants with 200+ drink days')
end)

T.test('BUG-401: reachable water, or a brewable plant in stock, or no scan yet: no question', function()
  for name, o in pairs({water = {access = {known = true, ok = true, acc = 0, bank = 1, bodies = 1, partial = 0}},
                        plants = {access = NONE, plants = 40},
                        noscan = {access = {known = false, ok = true, acc = 0, bank = 0, bodies = 0}}}) do
    local W = econ_world(o)
    days(W, 2)
    T.eq(#decisions(W, 'no_water'), 0, name)
    T.eq(W.state().stock.dwhy == nil or not tostring(W.state().stock.dwhy):find('no reachable water', 1, true), true, name)
  end
end)

---------------------------------------------------------------- water.drink_access
local DEPTH = {['~'] = 7, w = 2}
local function water_world(unreach_bank)
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, pos = {12, 12, 5}} end
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 199, 199, 20}}}}
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'pond_remove'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = {manifest = man}}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.civzone_type.Pond, df.civzone_type[11] = 11, 'Pond'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  local ids = {}
  for i = 1, 4 do ids[i] = i; W.unit(i).counters2 = {thirst_timer = 1000}; W.unit(i).job = {current_job = nil} end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 199, 199, 20})
  local tiles = {}
  for x = 20, 40 do tiles[x .. ',30,5'] = '~'; tiles[x .. ',29,5'] = '.' end      -- a brook, its bank on the north side
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z)
    local c = tiles[x .. ',' .. y .. ',' .. z] or '#'
    return {c = c, dig = '', bld = '', flow = DEPTH[c] or 0}
  end
  function snap.liquids(K, x0, y0, x1, y1, z, min)
    local out = {}
    for y = y0, y1 do
      for x = x0, x1 do
        local f = DEPTH[tiles[x .. ',' .. y .. ',' .. z] or ''] or 0
        if f >= (min or 1) then out[#out + 1] = {x, y, f, 0} end
      end
    end
    return out
  end
  function snap.reach(K, a, b) return not (unreach_bank and b.y == 29) end            -- the bank is ice-bound / walled off
  W.load(snap)
  W.load({name = 'runner', every = {ticks = 600}, pending = function() return 0 end,
          kept_in = function() return nil end, bp_params = function() return {} end})
  local M = fresh('water')
  W.load(M)
  return W, M
end

T.test('BUG-401: water.drink_access: a brook with a reachable bank is drink; the same brook with no reachable bank is not', function()
  local W, M = water_world(false)
  T.eq(M.drink_access(W.K).known, false, 'no scan finished yet: unknown, not dry')
  days(W, 3)
  local a = M.drink_access(W.K)
  T.eq({a.known, a.ok}, {true, true})
  T.ok(a.bank >= 1, 'a bank the citizens reach')
  local W2, M2 = water_world(true)
  days(W2, 3)
  local b = M2.drink_access(W2.K)
  T.eq({b.known, b.ok, b.acc, b.bank}, {true, false, 0, 0})
  T.ok(b.bodies >= 1, 'the body is known, only unreachable')
end)

T.done()
