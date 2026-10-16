-- care (live L4): strange moods from the mood job's item filters (Gordon's decision 2026-10-11), concrete
-- items, acquisitions, MOOD_NEED and the 2-day class-A wake, children's moods, the walk-group hook.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local json = require('dfllm.util.json')

local function bar(W, id, mi, flags, pos)
  return F.item(W, 'BAR', {id = id, mat_type = 0, mat_index = mi, flags = flags or {}, _pos = pos or {10, 10, 5}})
end

local function filter(t, spec)
  local f = {item_type = t and df.item_type[t] or -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

local function reqs(W, tpl)                     -- PROJECT_REQUEST events of one template (tombs come too)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.tpl == tpl then r[#r + 1] = e end end
  return r
end

local function moody(W, id, kind, filters, attached)
  local u = W.unit(id)
  u.mood = df.mood_type[kind]
  u.job.current_job = CW.mood_job(W, 900 + id, F.workshop(W, 'Craftsdwarfs'), filters, attached)
  return u
end

T.test('mood filters: concrete items per filter, forbidden ones freed, MOOD_NEED lists only what is missing', function()
  local W, Cm = CW.world{setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    F.mat(W, 0, 8, {token = 'INORGANIC:COPPER'})
    F.mat(W, 50, 1, {token = 'PLANT:FLAX:THREAD', flags = {THREAD_PLANT = true}})
    local got = bar(W, 10, 9, {in_job = true}, {9, 9, 5})
    moody(W, 1, 'Fey', {
      filter('BAR', {mat_type = 0, mat_index = 9, quantity = 300}),               -- 2 iron bars, 1 brought
      filter('CLOTH', {quantity = 10000, flags2 = {silk = true}}),                -- 1 silk cloth
      filter(nil, {quantity = 3, flags2 = {bone = true, body_part = true}}),     -- 3 bones
    }, {{job_item_idx = 0, item = got}})
    bar(W, 11, 8)                                                                 -- copper: not iron
    bar(W, 12, 9, {forbid = true})                                                -- iron, forbidden: freed
    F.item(W, 'CLOTH', {id = 20, mat_type = 50, mat_index = 1, _pos = {10, 10, 5}})   -- plant cloth, not silk
    F.item(W, 'CORPSEPIECE', {id = 30, unit_id = 700, corpse_flags = {bone = true}, _pos = {11, 10, 5}})
    F.item(W, 'CORPSEPIECE', {id = 31, unit_id = 701, corpse_flags = {bone = true}, _pos = {11, 10, 5}})
    F.item(W, 'CORPSEPIECE', {id = 32, unit_id = 2, corpse_flags = {bone = true}, flags = {forbid = true},
                              _pos = {11, 10, 5}})                                -- a citizen's remains
    F.item(W, 'CORPSEPIECE', {id = 33, unit_id = 702, corpse_flags = {bone = true, unbutchered = true},
                              _pos = {11, 10, 5}})
    F.item(W, 'CORPSEPIECE', {id = 34, unit_id = 703, corpse_flags = {bone = true}, flags = {forbid = true},
                              _pos = {12, 10, 5}})
    W.kill(2)
  end}
  W.run(1)
  -- live L4: the third bone stays forbidden while the silk cloth before it is missing (filter order)
  T.eq(CW.flags(W), {{12, 'forbid', false}}, 'the second iron bar; not the third bone yet')
  local need = W.find_events('MOOD_NEED')
  T.eq(#need, 1)
  T.eq({need[1].d.unit, need[1].d.need, need[1].d.via, need[1].d.ws, need[1].d.child}, {1, 'cloth(silk) x1', 'job',
       'Craftsdwarfs', 0})
  T.eq(need[1].d.list, {'cloth(silk) x1'})
  T.eq(F.runs(W), {}, 'cloth needs no butcher')
  local w = Cm.mood_wants(W.K)
  -- BUG-017 (Run 10 y418): the filter names the kind, so trade is asked for silk cloth
  T.eq(w, {{unit = 1, cls = 'cloth', n = 1, label = 'cloth(silk) x1', acq = 'order:WeaveCloth,buy', buy = 'cloth:silk'}})
  w[1].n = 99
  T.eq(Cm.mood_wants(W.K)[1].n, 1, 'a fresh copy each call')
  T.ok(#json.encode(w) < 1024)
  T.eq(W.find_events('DECISION_NEEDED'), {})
  CW.day(W)
  T.eq(#W.find_events('MOOD_NEED'), 1, 'same list: not repeated')
  T.eq(W.find_events('DECISION_NEEDED'), {}, 'one game day: not yet')
  CW.day(W)
  local dn = W.find_events('DECISION_NEEDED')
  T.eq({#dn, dn[1].d.id}, {1, 'mood_material'}, 'unresolved for 2 game days: class A')
  T.ok(dn[1].d.q:find('cloth(silk) x1', 1, true) and dn[1].d.q:find('trade.want cloth', 1, true), dn[1].d.q)
  T.eq(W.bad_vectors, {})
end)

T.test('a resolved need wakes nobody; a new item clears the need', function()
  local W = CW.world{setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    moody(W, 1, 'Fell', {filter('BAR', {mat_type = 0, mat_index = 9, quantity = 150})})
  end}
  W.run(1)
  T.eq(W.find_events('MOOD_NEED')[1].d.need, 'bars x1 (iron)')
  bar(W, 40, 9, {dump = true})
  CW.day(W)
  T.eq(CW.flags(W), {{40, 'dump', false}})
  CW.day(W, 3)
  T.eq(W.find_events('DECISION_NEEDED'), {}, 'the bar came in time')
  T.eq(W.K.persist.get('m.care').moods['1'].unres, nil)
end)

T.test('a child\'s mood: held reserve boulders are freed; economic stone and hidden tiles are skipped', function()
  local persist = {['m.care'] = {v = 2, dead = {}, deaths = {}, petitions = {}, reserve = {held = {boulders = {40, 41, 42}}}}}
  local W = CW.world{persist = persist, setup = function(W)
    df.global.plotinfo.economic_stone = {[5] = true}
    W.unit(3)._m.adult = false                                         -- live L3: children aged 1-7 took 3 of 4 moods
    moody(W, 3, 'Possessed', {filter('BOULDER', {mat_type = 0, flags2 = {non_economic = true}})})
    F.item(W, 'BOULDER', {id = 40, mat_index = 5, flags = {forbid = true}, _pos = {10, 10, 5}})   -- flux/ore
    F.item(W, 'BOULDER', {id = 42, mat_index = 6, flags = {forbid = true}, _pos = {30, 30, 5}})   -- hidden tile
    F.item(W, 'BOULDER', {id = 41, mat_index = 6, flags = {forbid = true}, _pos = {10, 11, 5}})
    W.hidden['30,30,5'] = true
  end}
  W.run(1)
  local st = W.find_events('MOOD_START')
  T.eq({#st, st[1].d.unit, st[1].d.child}, {1, 3, 1})
  T.ok(st[1].msg:find('(child)', 1, true))
  T.eq(CW.flags(W), {{41, 'forbid', false}})
  T.eq(W.find_events('MOOD_NEED'), {})
  T.eq(CW.held(W), {boulders = {40, 42}}, 'the freed boulder left the reserve')
  df.global.plotinfo.economic_stone = nil
end)

T.test('live L4: a held boulder for a later filter stays held while an earlier filter (bone) is missing', function()
  local persist = {['m.care'] = {v = 2, dead = {}, deaths = {}, petitions = {}, reserve = {held = {boulders = {41}}}}}
  local W = CW.world{persist = persist, setup = function(W)
    moody(W, 3, 'Possessed', {
      filter(nil, {quantity = 2, flags2 = {bone = true, body_part = true}}),   -- 2 bones: none on the map
      filter('BOULDER', {mat_type = 0}),
    })
    F.item(W, 'BOULDER', {id = 41, mat_index = 6, flags = {forbid = true}, _pos = {10, 11, 5}})
  end}
  W.run(1)
  T.eq(CW.flags(W), {}, 'not freed while the bones are missing')
  local need = W.find_events('MOOD_NEED')
  T.eq(need[#need].d.list, {'bone x2'}, 'the held boulder counts as there')
  CW.day(W)
  T.eq(CW.flags(W), {}, 'still held a day later')
  T.eq(CW.held(W), {boulders = {41}})
  F.item(W, 'CORPSEPIECE', {id = 30, unit_id = 700, corpse_flags = {bone = true}, _pos = {11, 10, 5}})
  F.item(W, 'CORPSEPIECE', {id = 31, unit_id = 701, corpse_flags = {bone = true}, _pos = {11, 10, 5}})
  CW.day(W)
  T.eq(CW.flags(W), {{41, 'forbid', false}}, 'freed once the bones are there')
end)

T.test('a child without a workshop: the hint says any moodable shop', function()
  local W = CW.world{setup = function(W)
    W.unit(2)._m.adult = false
    W.unit(2).mood = df.mood_type.Fey
  end}
  CW.day(W, 2)
  local n = W.find_events('MOOD_NEED')
  T.eq({#n, n[1].d.need}, {1, 'workshop'})
  T.ok(n[1].d.skill:find('child', 1, true), n[1].d.skill)
  T.eq(W.find_events('DECISION_NEEDED')[1].d.id, 'mood_workshop')
end)

T.test('acquisitions: autobutcher policy run and a stone dig request, rate-limited; the wake repeats weekly', function()
  local W = CW.world{setup = function(W)
    moody(W, 1, 'Macabre', {filter(nil, {quantity = 2, flags2 = {bone = true}}), filter('BOULDER', {mat_type = 0})})
  end}
  W.run(1)
  local runs = F.runs(W)
  T.eq(runs, {'autobutcher now'})
  T.eq(F.bad_runs(W), {}, 'allowlisted')
  local req = reqs(W, 'bedrooms')
  T.eq({#req, req[1].d.n, req[1].d.why}, {1, 4, 'mood_rock'})
  T.eq(W.find_events('MOOD_NEED')[1].d.need, 'bone x2, boulders x1')
  CW.day(W)
  T.eq(#F.runs(W), 1, 'not daily')
  CW.day(W)
  T.eq(#W.find_events('DECISION_NEEDED'), 1, 'day 2: class A')
  T.ok(W.find_events('DECISION_NEEDED')[1].d.q:find('bp.place bedrooms', 1, true))
  CW.day(W)
  T.eq(#F.runs(W), 2, 'again after butcher_every')
  T.eq(#reqs(W, 'bedrooms'), 2, 'the dig request again after 3 days')
  CW.day(W, 5)
  T.eq(#W.find_events('DECISION_NEEDED'), 1, 'day 8: still one')
  CW.day(W)
  T.eq(#W.find_events('DECISION_NEEDED'), 2, 'a week after the first wake')
end)

T.test('a pending bedrooms project: no second dig request', function()
  local W = CW.world{pending = {bedrooms = 1}, setup = function(W)
    moody(W, 1, 'Secretive', {filter('BOULDER', {mat_type = 0})})
  end}
  CW.day(W, 4)
  T.eq(reqs(W, 'bedrooms'), {})
end)

T.test('a need without any acquisition path wakes at once', function()
  local W = CW.world{setup = function(W)
    moody(W, 1, 'Fey', {filter('TOOL', {quantity = 1})})
  end}
  W.run(1)
  T.eq(W.find_events('MOOD_NEED')[1].d.need, 'tool x1')
  T.eq(#W.find_events('DECISION_NEEDED'), 1)
end)

T.test('the walk-group hook decides reachability per item (asked each time, from the moody unit)', function()
  local froms = {}
  local W = CW.world{reach = function(a, b)
    froms[#froms + 1] = a.x .. ',' .. a.y .. ',' .. a.z
    return b.x ~= 20
  end, setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    moody(W, 1, 'Fell', {filter('BAR', {mat_type = 0, quantity = 1})})
    bar(W, 50, 9, {}, {20, 10, 5})                       -- free but unreachable
    bar(W, 51, 9, {forbid = true}, {20, 11, 5})          -- forbidden and unreachable
    bar(W, 52, 9, {forbid = true}, {21, 11, 5})          -- forbidden, reachable: freed
  end}
  W.run(1)
  T.eq(CW.flags(W), {{52, 'forbid', false}})
  T.eq(froms[1], '5,5,5')
  CW.day(W)
  T.ok(W.reach_calls >= 4, 'asked again the next day, nothing cached')
end)

T.test('without the walk-group hook a free item outside Kern+ is not counted (v1: cavern stock), MOOD_NEED says so',
       function()
  local W = CW.world{setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    moody(W, 1, 'Fell', {filter('BAR', {mat_type = 0, quantity = 300})})
    bar(W, 50, 9, {}, {10, 10, 5})                       -- inside Kern+: counted
    bar(W, 51, 9, {}, {100, 100, 5})                     -- revealed, outside Kern+: maybe behind a closed shaft
  end}
  W.run(1)
  local n = W.find_events('MOOD_NEED')
  T.eq({#n, n[1].d.need, n[1].d.far}, {1, 'bars x1', 1})
  T.eq(CW.flags(W), {}, 'nothing to free')
  CW.day(W, 2)
  local q = W.find_events('DECISION_NEEDED')[1].d.q
  T.ok(q:find('1 outside Kern+', 1, true) and #q <= 200, q)
  local W2 = CW.world{reach = function() return true end, setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    moody(W, 1, 'Fell', {filter('BAR', {mat_type = 0, quantity = 300})})
    bar(W, 50, 9, {}, {10, 10, 5})
    bar(W, 51, 9, {}, {100, 100, 5})
  end}
  W2.run(1)
  T.eq(W2.find_events('MOOD_NEED'), {}, 'the hook says reachable: counted')
end)

T.test('a faulting walk-group hook is asked once per boot, then Kern+ stands in', function()
  local calls = 0
  local W = CW.world{strict = false, reach = function() calls = calls + 1; error('bad signature') end,
                     setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    moody(W, 1, 'Fell', {filter('BAR', {mat_type = 0, quantity = 150})})
    bar(W, 50, 9, {}, {100, 100, 5})
    bar(W, 51, 9, {}, {10, 10, 5})
  end}
  CW.day(W, 3)
  T.eq(calls, 1, 'one fault against snapshot, not one per run (three back it off)')
  T.eq(W.find_events('MOOD_NEED'), {}, 'the bar inside Kern+ serves the mood')
end)

T.test('a mood job freed between two frames of a sliced run: its job_items are never touched again', function()
  local old, calls_after = nil, 0
  local W = CW.world{setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    local u = moody(W, 1, 'Fey', {filter('BAR', {mat_type = 0, quantity = 150})})
    old = u.job.current_job.job_items.elements[0]
    for i = 1, 450 do                                    -- more than one slice: the scan spans frames
      local it = bar(W, 6000 + i, 9, {}, {10, 10, 5})
      it.getSubtype = function() return -1 end
      it.getMaterial = function(self) return self.mat_type end
      it.getMaterialIndex = function(self) return self.mat_index end
    end
  end}
  dfhack.job.isSuitableItem = function(ji)
    if ji._freed then calls_after = calls_after + 1 end
    return true
  end
  dfhack.job.isSuitableMaterial = function() return false end   -- DFHack vetoes every bar: the whole vector
  W.run(1)                                                       -- frame 1: the scan starts
  old._freed = true                                              -- the artifact is done: DF frees the job
  W.unit(1).job.current_job = nil
  W.run(1)
  W.run(1)
  W.run(1)
  T.eq(calls_after, 0, 'no job_item pointer from an earlier frame')
  T.eq(W.find_events('MOOD_NEED'), {}, 'the finished job drops out of this run')
  dfhack.job.isSuitableItem, dfhack.job.isSuitableMaterial = nil, nil
end)

T.test('job_items are read only from a StrangeMood job', function()
  local W = CW.world{setup = function(W)
    local u = W.unit(1)
    u.mood = df.mood_type.Fey
    u.job.current_job = CW.counting_job(W, 901, F.workshop(W, 'Jewelers'), df.job_type.PrepareMeal)
    F.item(W, 'ROUGH', {id = 60, flags = {forbid = true}, _pos = {10, 10, 5}})
  end}
  CW.day(W, 2)
  T.eq(W.job_items_reads, nil)
  T.eq(CW.flags(W), {{60, 'forbid', false}}, 'the workshop classes as before')
end)

T.test('long need lists stay within the event limits', function()
  local W = CW.world{setup = function(W)
    local fs = {}
    for i = 1, 12 do
      F.mat(W, 0, 100 + i, {token = 'INORGANIC:METAL_WITH_A_LONG_NAME_' .. i})
      fs[i] = filter('BAR', {mat_type = 0, mat_index = 100 + i, quantity = 150})
    end
    moody(W, 1, 'Fell', fs)
  end}
  CW.day(W, 3)
  local n = W.find_events('MOOD_NEED')[1].d
  T.ok(#n.need <= 200 and #n.list == 8 and #json.encode(n) <= 1024, #n.need)
  local q = W.find_events('DECISION_NEEDED')[1].d.q
  T.ok(#q <= 200, #q)
  -- labels at their 60-byte cap: the list is cut by bytes, so d never exceeds kern's 1,024 (it would become
  -- {"trunc":1} and lose the unit id)
  local W2 = CW.world{setup = function(W)
    local fs = {}
    for i = 1, 12 do
      F.mat(W, 0, 200 + i, {token = 'INORGANIC:' .. string.rep('X', 70) .. i})
      fs[i] = filter('BAR', {mat_type = 0, mat_index = 200 + i, quantity = 150})
    end
    moody(W, 1, 'Fell', fs)
  end}
  W2.run(1)
  local d = W2.find_events('MOOD_NEED')[1].d
  T.ok(d.unit == 1 and #d.list >= 1 and #d.list < 8 and #json.encode(d) <= 1024, #json.encode(d))
end)

-- BUG-017 (test fort y374: "MOOD_RISK ... starts without bars x1 (inorganic), cloth(silk) x1, bone x1, logs x1", then
-- "thirst 40197 ... missing bars,cloth,bone,logs" while the job of unit 26325 held all its items; 4 moods died with
-- leather in their list and 0 tanned leather in the fort)
T.test('BUG-017: the dwarf attached every item since the last report: the thirst MOOD_RISK says nothing missing',
       function()
  local W = CW.world{setup = function(W)
    local u = moody(W, 1, 'Fey', {
      filter('BAR', {mat_type = 0, quantity = 150}),
      filter('CLOTH', {quantity = 10000, flags2 = {silk = true}}),
      filter(nil, {quantity = 1, flags2 = {bone = true, body_part = true}}),
      filter('WOOD'),
    })
    u.counters2 = {thirst_timer = 10000, hunger_timer = 0}
  end}
  W.run(1)
  local r = W.find_events('MOOD_RISK')
  T.eq({#r, r[1].d.missing}, {1, {'bars', 'cloth', 'bone', 'logs'}})
  -- he collects all four (a caravan brought them, a log was cut) and his thirst passes the line before care's next run
  local job = W.unit(1).job.current_job
  for i, cat in ipairs({'BAR', 'CLOTH', 'CORPSEPIECE', 'WOOD'}) do
    local it = F.item(W, cat, {id = 70 + i, flags = {in_job = true}, _pos = {9, 9, 5}})
    job.items:insert('#', {job_item_idx = i - 1, item = it})
  end
  W.unit(1).counters2.thirst_timer = 40197
  CW.day(W)
  r = W.find_events('MOOD_RISK')
  T.eq(#r, 2)
  T.eq({r[2].d.why, r[2].d.thirst, r[2].d.missing}, {'thirst', 40197, {}})
  T.ok(r[2].msg:find('nothing missing', 1, true) and not r[2].msg:find('supply it', 1, true), r[2].msg)
  T.eq(W.K.persist.get('m.care').moods['1'].missing, {})
end)

T.test('BUG-017: items attached without a filter index still cover the filters they fit', function()
  local W = CW.world{setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    F.mat(W, 60, 1, {token = 'CREATURE:SPIDER_CAVE:SILK', flags = {SILK = true}})
    local att = {}
    local function held(cat, spec)
      spec.flags, spec._pos = {in_job = true}, {9, 9, 5}
      att[#att + 1] = {job_item_idx = -1, item = F.item(W, cat, spec)}
    end
    held('BAR', {id = 81, mat_type = 0, mat_index = 9})
    held('CLOTH', {id = 82, mat_type = 60, mat_index = 1})
    held('CORPSEPIECE', {id = 83, unit_id = 700, corpse_flags = {bone = true}})
    held('BOULDER', {id = 84})
    moody(W, 1, 'Fey', {
      filter('BOULDER', {mat_type = 0, quantity = 2}),              -- 1 of 2 attached: one boulder short
      filter('BAR', {mat_type = 0, quantity = 150}),
      filter('CLOTH', {quantity = 10000, flags2 = {silk = true}}),
      filter(nil, {quantity = 1, flags2 = {bone = true, body_part = true}}),
    }, att)
  end}
  W.run(1)
  local r = W.find_events('MOOD_RISK')
  T.eq(#r, 1)
  T.eq(r[1].d.missing, {'boulders'})
  T.ok(r[1].msg:find('starts without boulders x1;', 1, true), r[1].msg)
  T.eq(W.find_events('MOOD_NEED')[1].d.list, {'boulders x1'})
end)

T.test('BUG-017: an item the dwarf attaches while the run scans the stock is not reported missing', function()
  local job, far
  local W = CW.world{reach = function(a, b)
    if job and #job.items == 0 then                                 -- meanwhile he picked up the far bar
      far.flags.in_job = true
      job.items:insert('#', {job_item_idx = 0, item = far})
    end
    return false
  end, setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    job = moody(W, 1, 'Fell', {filter('BAR', {mat_type = 0, quantity = 150})}).job.current_job
    far = bar(W, 50, 9, {}, {20, 10, 5})                            -- free, not reachable from the unit
  end}
  W.run(1)
  T.eq(#job.items, 1, 'attached during the scan')
  T.eq(W.find_events('MOOD_RISK'), {})
  T.eq(W.find_events('MOOD_NEED'), {})
end)

T.test('BUG-017: a class without any item in the fort is named: leather: no source in the fort', function()
  local W = CW.world{setup = function(W)
    moody(W, 1, 'Macabre', {
      filter('SKIN_TANNED'),
      filter(nil, {quantity = 1, flags2 = {bone = true, body_part = true}}),
    })
    -- a bone exists (forbidden, outside Kern+): a source, not usable now
    F.item(W, 'CORPSEPIECE', {id = 30, unit_id = 700, corpse_flags = {bone = true}, flags = {forbid = true},
                              _pos = {100, 100, 5}})
    W.unit(1).counters2 = {thirst_timer = 10000, hunger_timer = 0}
  end}
  W.run(1)
  local r = W.find_events('MOOD_RISK')
  T.eq(#r, 1)
  T.eq({r[1].d.missing, r[1].d.nosrc}, {{'leather', 'bone'}, {'leather'}})
  T.ok(r[1].msg:find('starts without leather x1, bone x1; leather: no source in the fort', 1, true), r[1].msg)
  local n = W.find_events('MOOD_NEED')[1]
  T.ok(n.msg:find('; leather: no source in the fort', 1, true), n.msg)
  T.eq(n.d.nosrc, {'leather'})
  W.unit(1).counters2.thirst_timer = 31000
  CW.day(W)
  r = W.find_events('MOOD_RISK')
  T.ok(r[2] and r[2].msg:find('missing leather,bone (leather: no source in the fort); a mood job', 1, true),
       r[2] and r[2].msg)
  CW.day(W, 2)
  local dn = W.find_events('DECISION_NEEDED')
  T.ok(dn[1] and dn[1].d.q:find('leather: no source in the fort', 1, true), dn[1] and dn[1].d.q)
end)

T.test('BUG-017 (Run 10 y418): a plant-cloth mood next to wool cloth: the kind is named with its stock, trade is ' ..
       'asked for cloth:plant', function()
  local W, Cm = CW.world{setup = function(W)
    F.mat(W, 50, 1, {token = 'PLANT:FLAX:THREAD', flags = {THREAD_PLANT = true}})
    F.mat(W, 52, 3, {token = 'CREATURE:SHEEP:HAIR', flags = {YARN = true}})
    moody(W, 1, 'Fey', {filter('CLOTH', {quantity = 10000, flags2 = {plant = true}}),
                        filter('THREAD', {quantity = 15000, flags2 = {yarn = true}})})
    for i = 1, 7 do F.item(W, 'CLOTH', {id = 40 + i, mat_type = 52, mat_index = 3, _pos = {10, 10, 5}}) end   -- wool
    F.item(W, 'THREAD', {id = 60, mat_type = 52, mat_index = 3, flags = {forbid = true}, _pos = {100, 100, 5}})
  end}
  W.run(1)
  local r = W.find_events('MOOD_RISK')
  T.eq(#r, 1)
  T.ok(r[1].msg:find('starts without cloth(plant) x1, thread(yarn) x1; cloth(plant) 0 in stock; thread(yarn) 1 in ' ..
       'stock', 1, true), r[1].msg)
  T.eq({r[1].d.missing, r[1].d.nosrc}, {{'cloth', 'thread'}, {'cloth(plant)'}})
  local w = Cm.mood_wants(W.K)
  T.eq({w[1].cls, w[1].buy, w[2].cls, w[2].buy}, {'cloth', 'cloth:plant', 'thread', 'thread:yarn'})
end)

T.done()
