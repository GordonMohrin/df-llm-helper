-- BUG-393..395 (Run 16 i1/i2/i3, 2026-11-04: moods kept failing for materials the fort lacked: i3 Yawninggilt 4 mood deaths for
-- 'boulders(hard) x1 / blocks x1: none in the fort', i2 5 failed moods, i1 a Possessed dwarf with no Craftsdwarfs). Every test here
-- fails on bb87afb.
--   BUG-393: a mood short of boulders/blocks that are none in the fort gets a stone dig of care's own (runner.stonedig), at the
--            nearest safe revealed hard-stone wall: not near water, magma, aquifer or caverns, not soil or vein, PEACE only
--   BUG-395: within mood_decide days of insanity DECISION_NEEDED mood_deadline with ready commands (trade.want, workshops surface=1)
-- BUG-394 (follow places the mood's shops on the surface when no room site is free) is Python: tests/test_bug393_395_mood_stone.py
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local json = require('dfllm.util.json')

local DAY = 1200

local function filter(t, spec)
  local f = {item_type = t and df.item_type[t] or -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

-- the tile reader: o.walls(x, y) true = stone wall (default x >= 11), o.over(x, y) -> a table that replaces the tile
local function tiles(o)
  o = o or {}
  return function(x, y, z)
    if o.over then
      local t = o.over(x, y, z)
      if t then
        t.dig, t.bld = t.dig or '', t.bld or ''
        return t
      end
    end
    local wall = (o.walls or function(px) return px >= 11 and px <= 16 end)(x, y)
    if wall then return {c = '#', dig = '', bld = '', shape = 'WALL', mat = 'STONE', flow = 0} end
    return {c = '.', dig = '', bld = '', shape = 'FLOOR', flow = 0}
  end
end

local function stone_world(o)
  o = o or {}
  return CW.world{cit = 4, runner = true, mode = o.mode, tile = tiles(o), setup = function(W)
    local u = W.unit(1)
    u.mood = df.mood_type.Secretive
    u.counters2 = {thirst_timer = 1000, hunger_timer = 500}
    u.job.mood_timeout = (o.days or 40) * DAY
    local shop = F.workshop(W, 'Craftsdwarfs')
    shop.x1, shop.y1, shop.x2, shop.y2, shop.z = 4, 4, 6, 6, 5
    -- boulders(hard) x1: 57 boulders of economic/soft stone lie in the fort (none usable), as in i3
    u.job.current_job = CW.mood_job(W, 901, shop, {filter('BOULDER', {mat_type = 0, flags2 = {non_economic = true}})})
    if o.setup then o.setup(W) end
  end}
end

local function deadline_events(W)
  local ds = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' then ds[#ds + 1] = e end end
  return ds
end

local function projects(W)
  local pd = W.K.persist.get('projects')
  local r = {}
  for _, P in ipairs(pd and pd.list or {}) do if P.tpl == 'stonedig' then r[#r + 1] = P end end
  return r
end

local function cells(W, id)
  local d = W.K.persist.get('bp.' .. id)
  local out = {}
  for _, st in ipairs(d.stages) do
    for _, ch in ipairs(st.chunks) do
      for _, c in ipairs(ch.cells) do
        out[#out + 1] = {ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3], c[4]}
      end
    end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

T.test('BUG-393: a mood short of boulders (none in the fort) gets a stone dig at the nearest hard-stone wall, no fortcore needed', function()
  local W = stone_world()
  W.run(1)
  local ps = projects(W)
  T.eq(#ps, 1, 'old code: only PROJECT_REQUEST bedrooms (needs a fortcore room site), no dig of its own')
  local d = W.K.persist.get('bp.' .. ps[1].id)
  T.eq({d.tpl, d.class, d.stages[1].mode, #d.stages}, {'stonedig', 'living', 'dig', 1})
  local cs = cells(W, ps[1].id)
  T.eq(#cs, 3, 'one boulder short + 2')
  T.eq({cs[1][1], cs[1][2], cs[1][3], cs[1][4]}, {11, 5, 5, 'd'}, 'the wall tile beside the floor at x=10, the dwarf at 5,5')
  T.eq({cs[2][1], cs[3][1]}, {12, 13}, 'a straight tunnel into the rock')
  local rec = W.K.persist.get('m.care').moods['1']
  T.eq({rec.sdig.n, rec.sdig.at, rec.sdig_n}, {3, '11,5,5', 1})
end)

T.test('BUG-393: no dig within stone_wet tiles of water, magma, an aquifer or a cavern; a vein and soil are no stone to dig', function()
  -- water at 14,5: every wall tile of the tunnel line within 3 tiles of it is out
  local W = stone_world{over = function(x, y)
    if x == 14 and y == 5 then return {c = 'w', flow = 3} end
  end}
  W.run(1)
  local ps = projects(W)
  T.eq(#ps, 1)
  for _, c in ipairs(cells(W, ps[1].id)) do
    T.ok(math.max(math.abs(c[1] - 14), math.abs(c[2] - 5)) > 3, 'dug ' .. c[1] .. ',' .. c[2] .. ' beside the water')
  end
  -- every wall an aquifer / a vein / soil: nothing to dig, and the reason is named
  for _, case in ipairs({{'aq', {aq = true}}, {'vein', {mat = 'MINERAL'}}, {'soil', {soilmat = true}}, {'cavern', {cav = true}}}) do
    local W2 = stone_world{over = function(x, y)
      if x >= 11 and x <= 16 then
        local t = {c = '#', shape = 'WALL', mat = 'STONE', flow = 0}
        for k, v in pairs(case[2]) do t[k] = v end
        return t
      end
    end}
    W2.run(1)
    T.eq(#projects(W2), 0, case[1] .. ': no dig')
    local rec = W2.K.persist.get('m.care').moods['1']
    T.ok(type(rec.sdig_why) == 'string' and rec.sdig_why ~= '', case[1] .. ': why is named')
  end
end)

T.test('BUG-393: PEACE only; one dig at a time; the line of the mood names the dig or why none', function()
  local W = stone_world{mode = 'ALERT'}
  W.run(1)
  T.eq(#projects(W), 0)
  T.eq(W.K.persist.get('m.care').moods['1'].sdig_why, 'digs run in PEACE only')
  local W2 = stone_world()
  W2.run(1)
  CW.day(W2, 1)
  W2.ms = W2.ms + 60000
  CW.day(W2, 1)
  T.eq(#projects(W2), 1, 'the dig is queued once, not every run')
  local ev = W2.find_events('MOOD_CRITICAL')
  T.ok(#ev >= 1)
  T.ok(ev[#ev].msg:find('stone dig', 1, true), ev[#ev].msg)
end)

T.test('BUG-393: no revealed stone at all is named; a hidden wall is no candidate', function()
  local W = stone_world{walls = function() return false end}
  W.run(1)
  T.eq(#projects(W), 0)
  T.ok(tostring(W.K.persist.get('m.care').moods['1'].sdig_why):find('no revealed stone wall', 1, true), tostring(W.K.persist.get('m.care').moods['1'].sdig_why))
end)

T.test('BUG-395: within 15 days of insanity a mood short of stone gets DECISION_NEEDED mood_deadline with ready commands', function()
  local W = stone_world{days = 40}
  W.run(1)
  CW.day(W, 1)
  T.eq(#deadline_events(W), 0, '40 days left: not yet')
  W.unit(1).job.mood_timeout = 14 * DAY
  W.ms = W.ms + 60000
  CW.day(W, 1)
  local ds = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' then ds[#ds + 1] = e end end
  T.ok(#ds >= 1, 'old code: MOOD_CRITICAL only, nothing to send')
  local d = ds[1].d
  T.eq(ds[1].cls, 'A')
  T.ok(d.q:find('d to insanity', 1, true) and d.q:find('boulders', 1, true), d.q)
  T.ok(#d.cmds >= 1)
  local line = d.cmds[1]
  T.ok(line:find("^dfllm cmd trade.want '"), line)
  local arg = json.decode(line:match("'(.*)'$"))
  T.ok(arg.add[1] == 'stone' and arg.want == nil, 'the caravans are asked for stone (BUG-440: added, not replacing)')
  T.eq(d.opts[1], 'trade.want')
  for _, c in ipairs(d.cmds) do T.ok(#c <= 200) end
  T.ok(#json.encode(d) < 1024, 'd stays under the kernel limit')
  -- again at the next step (5 days), not in between
  local n0 = #ds
  W.unit(1).job.mood_timeout = 12 * DAY
  W.ms = W.ms + 60000
  CW.day(W, 1)
  local n1 = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' then n1 = n1 + 1 end end
  T.eq(n1, n0, 'same step: not repeated')
  W.unit(1).job.mood_timeout = 4 * DAY
  W.ms = W.ms + 60000
  CW.day(W, 1)
  n1 = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' then n1 = n1 + 1 end end
  T.eq(n1, n0 + 1, 'the 5-day step says it again')
end)

T.test('BUG-395: a mood short of a workshop gets the surface placement as a ready command', function()
  local W, Cm = CW.world{cit = 4, setup = function(W)
    local u = W.unit(1)
    u.mood = df.mood_type.Fey
    u.counters2 = {thirst_timer = 2000, hunger_timer = 1000}
    u.job.mood_timeout = 8 * DAY
    u.job.current_job = CW.mood_job(W, 901, nil, {filter('BAR', {mat_type = 0, mat_index = 9, quantity = 150})})
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
  end}
  local u = W.unit(1)
  local rec = {sl = {}, nosrc = {'bars'}, buy = {'bar:iron'}}
  Cm.mood_deadline(W.K, Cm.DEFAULTS, u, rec, 'Fey', 'Udil', 8, {'workshop', 'material'}, {'bars'}, {'Jewelers', 'Craftsdwarfs'}, nil)
  local ds = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' then ds[#ds + 1] = e end end
  T.eq(#ds, 1)
  local d = ds[1].d
  T.eq(d.opts, {'trade.want', 'workshops'})
  T.ok(d.cmds[1]:find('"bar:iron"', 1, true), d.cmds[1])
  local arg = json.decode(d.cmds[2]:match("'(.*)'$"))
  T.eq({arg.tpl, arg.site, arg.p.only, arg.p.surface}, {'workshops', 'S1', 'Jewelers,Craftsdwarfs', 1})
  Cm.mood_deadline(W.K, Cm.DEFAULTS, u, rec, 'Fey', 'Udil', 8, {'workshop', 'material'}, {'bars'}, {'Jewelers'}, nil)
  local n = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' then n = n + 1 end end
  T.eq(n, 1, 'the same step: once')
  -- a mood that only runs out the clock (nothing short) is no decision
  Cm.mood_deadline(W.K, Cm.DEFAULTS, u, {}, 'Fey', 'Udil', 2, {'timer'}, {}, {}, 'Craftsdwarfs')
  n = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' then n = n + 1 end end
  T.eq(n, 1)
end)

T.done()
