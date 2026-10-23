-- Integration audit J1: the militia rotation (FR-79, BUG-076) read together with the defence code merged before and after it.
--  * A3 military.danger (BUG-050 unstick, BUG-051 drill gate, FR-79 turnover) x C1 BUG-065 / Run 11 (the hostiles reflex
--    cleared: a harmless intruder released at the confinement limit, invaders whose lockdown expired far; the wildlife
--    out of reach): threat and siege count them for nothing, military counted every visible hostile for ever (BUG-087)
--  * D1 rotation pool x I4 BUG-085 (the squads screen lists living adult citizens only): the census holds residents too
--    (BUG-088)
--  * D1 rotation log x timestream speed: a hold keyed by a moving number is logged at every upkeep (BUG-089)
local T = require('testlib')
local X = require('wp6_world')

local YEAR, MONTH, DAY = 403200, 33600, 1200
local function mil() return X.mod('military') end
local function abs(W) return df.global.cur_year * YEAR + df.global.cur_year_tick end
local function run_to(W, y, m, d)
  local dt = y * YEAR + m * MONTH + (d or 0) * DAY - abs(W)
  assert(dt >= 0, 'run_to goes back in time')
  W.run(dt, {skip = 600})
end
-- n citizens (ids 1..n unless opts.units), year 3 month 5, the squads staffed (as test_military_d1.lua)
local function fort(n, opts, before_load)
  opts = opts or {}
  opts.n = n or 60
  opts.ytick = opts.ytick or (5 * MONTH + 100)
  local W = X.world(opts)
  if before_load then before_load(W) end
  X.load(W, {'military'}, {X.runner('P5')}, {'sense', 'threat'})
  W.state()
  W.run(9, {skip = 9})
  W.run(3600 * 4, {skip = 600})
  return W
end
local function seats(W, alias)
  local s, r = X.squad_of(W, alias), {}
  for i = 0, 9 do
    local hf = s.positions[i].occupant
    if hf >= 0 then r[#r + 1] = W.hfs[hf].unit_id end
  end
  return r
end
local function members_of(W, alias)               -- without the leader, sorted
  local r = seats(W, alias)
  table.remove(r, 1)
  table.sort(r)
  return r
end
local function overlap(a, b)
  local set, n = {}, 0
  for _, x in ipairs(a) do set[x] = true end
  for _, x in ipairs(b) do if set[x] then n = n + 1 end end
  return n
end
local function rotated(W) return W.find_events('MILITIA_ROTATED') end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat) then return l end end
end
local function unsticks(W)
  local r = {}
  for _, a in ipairs(X.acts(W, 'run')) do if a.args[1] == 'uniform-unstick' then r[#r + 1] = a end end
  return r
end

-- hostiles in sight, as sense lists them (one entry per counted hostile). Each item is an id (an invader at 10,10: 40
-- tiles from O1, 80 from the nearest citizen outside) or {id, kind, x, y, dc}; `vis` overrides the count (hostiles the
-- list does not show). Returns a function that takes them away again.
local function in_sight(W, items, vis)
  local real, on, list = W.K.census, true, {}
  local h = {inv = 0, great = 0, undead = 0, inside = 0}
  for _, it in ipairs(items) do
    local e = {id = it, k = 'inv', x = 10, y = 10, dc = 80}
    if type(it) == 'table' then e = {id = it[1], k = it[2] or 'inv', x = it[3] or 10, y = it[4] or 10, dc = it[5] or 80} end
    e.z, e.d_o1, e.zn = X.Z, 90, 0
    list[#list + 1] = e
    if e.k == 'inv' then h.inv = h.inv + 1 elseif e.k == 'great' then h.great = h.great + 1 end
  end
  W.K.census = setmetatable({}, {
    __index = function(_, key)
      if key == 'h' and on then
        h.vis, h.tick, h.list = vis or #list, W.K.now().tick, list
        return h
      end
      return real[key]
    end,
    __newindex = function(_, key, v) real[key] = v end})
  return function() on = false end
end
-- reflex's expired-far / cleared list (reflex.far_ids): {[unit id] = true}
local function cleared(W, set)
  local call = W.K.call
  W.K.call = function(mod, fn, ...)
    if mod == 'reflex' and fn == 'far_ids' then return true, set end
    return call(mod, fn, ...)
  end
end

---------------------------------------------------------------- A3 military.danger x C1 cleared hostiles
T.test('J1: military.danger follows threat: a cleared invader and wildlife out of reach are no danger; an invader, a great ' ..
       'danger, a hostile in reach or one the census list does not show still are', function()
  local W = fort(60)
  local K = W.K
  local off = in_sight(W, {900})
  T.eq(mil().danger(K), 'hostile', 'an invader in sight that is not cleared is danger')
  cleared(W, {[900] = true})
  T.eq(mil().danger(K), nil, 'the harmless intruder reflex released (BUG-065) is no danger')
  off()
  in_sight(W, {900, 901})
  T.eq(mil().danger(K), 'hostile', 'a second invader that is not cleared counts')
  in_sight(W, {900}, 2)
  T.eq(mil().danger(K), 'hostile', 'a hostile beyond the listed ones is unknown: it counts')
  in_sight(W, {{900, 'great'}})
  T.eq(mil().danger(K), 'hostile', 'a great danger counts whatever the cleared list says')
  in_sight(W, {{901, 'danger', 300, 300, -1}})
  T.eq(mil().danger(K), nil, 'a wild animal 250 tiles from every bridge and every citizen (Run 11: an ELK_BIRD at the map edge)')
  in_sight(W, {{901, 'danger', 60, 20, -1}})
  T.eq(mil().danger(K), 'hostile', 'the same animal in reach of the bridges counts')
  in_sight(W, {{901, 'danger', 300, 300, 12}})
  T.eq(mil().danger(K), 'hostile', 'and one within 40 tiles of a citizen outside Kern+')
  in_sight(W, {900})
  K.set_mode('ALERT', 'test')
  T.eq(mil().danger(K), 'mode ALERT', 'the mode still comes first')
end)

T.test('J1: a cleared harmless intruder in sight for the whole off period does not stop the militia turnover', function()
  local W = fort(60)
  local B0 = members_of(W, 'B')
  run_to(W, 3, 11, 20)
  in_sight(W, {900})
  cleared(W, {[900] = true})                       -- BUG-065 released it at the confinement limit, it stays in the caves
  run_to(W, 4, 2, 0)
  T.eq(overlap(B0, members_of(W, 'B')), 0, 'squad B was turned over at the close of month 0')
  T.eq(#rotated(W), 1)
  T.eq(logged(W, 'the turnover at the close of month 0 waits'), nil, 'nothing held it')
end)

T.test('J1: the same hostile, not cleared, still holds the turnover until the window reopens (it lapses)', function()
  local W = fort(60)
  local B0 = members_of(W, 'B')
  run_to(W, 3, 11, 20)
  in_sight(W, {900})
  run_to(W, 4, 9, 5)
  T.eq(members_of(W, 'B'), B0)
  T.eq(#rotated(W), 0)
  T.ok(logged(W, 'did not run before the window reopened %(hostile%)'), 'kern.log names the hostile')
end)

T.test('J1: a cleared harmless intruder in sight does not stop the monthly uniform-unstick', function()
  local W = fort(60, nil, function(w) in_sight(w, {900}); cleared(w, {[900] = true}) end)
  W.run(33600 * 3, {skip = 600})
  T.ok(#unsticks(W) >= 1, 'nobody wears his kit and nothing dangerous is near: the unstick runs')
end)

---------------------------------------------------------------- D1 rotation pool, A3 recruits x I4 BUG-085
-- the census holds residents too (sense: getCitizens(false, true), RECALL names them `/res`); the squads screen lists
-- living adult citizens only (BUG-085), so the kernel's own adds must not take a resident either
T.test('J1: a resident is no recruit and no militia candidate: the squads hold citizens only, at the start and after a turnover',
       function()
  local units = X.citizens(60)
  for i = 1, 3 do units[i] = X.cit(i, {citizen = false, resident = true}) end     -- the lowest ids rank first
  local W = fort(nil, {units = units})
  local function resident(ids) for _, id in ipairs(ids) do if id <= 3 then return id end end end
  for _, k in ipairs({'A', 'B', 'C'}) do
    T.eq(#seats(W, k) >= 3, true, 'squad ' .. k .. ' is staffed')
    T.eq(resident(seats(W, k)), nil, 'a resident sits in squad ' .. k)
  end
  local B0 = members_of(W, 'B')
  run_to(W, 4, 1, 0)
  T.eq(overlap(B0, members_of(W, 'B')), 0, 'squad B was turned over')
  T.eq(resident(seats(W, 'B')), nil, 'the cohort holds no resident')
  local acts = X.acts(W, 'squad_add')
  for _, a in ipairs(acts) do T.ok(a.args[2] > 3, 'squad_add took resident ' .. tostring(a.args[2])) end
end)

---------------------------------------------------------------- D1 rotation log x timestream speed
-- "once per close and reason": the hold for the army's worn % carries the % in its text, which moves with every upkeep
-- (8 real seconds apart at ~450 ticks a second), so the signature must not
T.test('J1: a turnover held for the army\'s worn % is logged once per close, not at every upkeep the % moves', function()
  local W = fort()
  for _, id in ipairs(members_of(W, 'B')) do X.equip(W, id) end             -- the leavers wear kit ...
  local worn, real = 20, mil().kpi
  mil().kpi = function(K) local r = real(K); r.worn = worn; return r end    -- ... and the army's worn % moves
  run_to(W, 3, 11, 27)
  for i = 1, 8 do worn = 20 + i; W.run(3600, {skip = 600}) end             -- eight upkeeps after the close
  local n = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('waits %(worn') then n = n + 1 end end
  T.eq(n, 1, 'the log says it once')
  T.ok(logged(W, 'waits %(worn 2%d%% < 40%%%)'), 'and names the % of the first look')
  local m = X.call(W, 'military', 'state').mil.rot.B
  T.ok(m.why:find('held: worn 28% < 40%', 1, true), 'the state shows the current %: ' .. tostring(m.why))
  worn = 100                                                                -- the army wears its kit: the turnover goes
  run_to(W, 4, 2, 0)
  T.eq(#rotated(W) >= 1, true)
end)

T.done()
