-- care K3 (BUG-100, Run 14 note 72): a Weaponsmith's strange mood died of thirst while MOOD_RISK and DECISION_NEEDED said
-- "blocks: no source in the fort" for 55 days with 225 blocks in the stock. Every open slot of the mood job is reported
-- with its own filter, three counts (in the fort / free / reachable) and the real blocker in a fixed vocabulary:
-- none in the fort / none free / none reachable / enough exist. The other unmet slots are named too.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local json = require('dfllm.util.json')

local IRON, GRANITE = 9, 20

-- a filter spec; the item type is resolved when the mood job is made (df exists once the world does)
local function filter(t, spec)
  local f = {_t = t, mat_type = -1, mat_index = -1, quantity = 1, flags1 = {}, flags2 = {}, flags3 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

-- an item that answers DFHack's material questions
local function item(W, cat, id, mi, flags, pos)
  local it = F.item(W, cat, {id = id, mat_type = 0, mat_index = mi, flags = flags or {}, _pos = pos or {10, 10, 5}})
  it.getSubtype = function() return -1 end
  it.getMaterial = function(self) return self.mat_type end
  it.getMaterialIndex = function(self) return self.mat_index end
  return it
end

local function moody(W, id, kind, filters, attached)
  local u = W.unit(id)
  for _, f in ipairs(filters) do f.item_type = f._t and df.item_type[f._t] or -1 end
  u.mood = df.mood_type[kind]
  u.job.current_job = CW.mood_job(W, 900 + id, F.workshop(W, 'MetalsmithsForge'), filters, attached)
  return u
end

-- DFHack's own veto for the metal-only block filter (job_item flags3.metal): only a metal serves it
local saved
local function metal_veto()
  saved = {dfhack.job.isSuitableItem, dfhack.job.isSuitableMaterial}
  dfhack.job.isSuitableItem = function() return true end
  dfhack.job.isSuitableMaterial = function(ji, mt, mi)
    if ji.flags3 and ji.flags3.metal then return mt == 0 and mi == IRON end
    return true
  end
end
local function restore()
  if saved then dfhack.job.isSuitableItem, dfhack.job.isSuitableMaterial = saved[1], saved[2]; saved = nil end
end

local function mats(W)
  F.mat(W, 0, IRON, {token = 'INORGANIC:IRON'})
  F.mat(W, 0, GRANITE, {token = 'INORGANIC:GRANITE'})
end

local function slot_of(msg, name)                 -- the text of one slot in a message, or nil
  return msg:match('(' .. name:gsub('%p', '%%%0') .. ' x%d+: [^;]*)')
end

T.test('K3 (note 72): a metal-only block filter with 225 stone blocks: the filter, the counts and the cloth wall are named',
       function()
  local W = CW.world{census_i = {thread = 0, cloth = 0}, setup = function(W)
    metal_veto()
    mats(W)
    local bar = item(W, 'BAR', 10, IRON, {in_job = true}, {9, 9, 5})
    moody(W, 1, 'Fey', {
      filter('BAR', {mat_type = 0, mat_index = IRON, quantity = 150}),               -- 1 bar, attached: met
      filter('BLOCKS', {mat_type = 0, quantity = 2, flags3 = {metal = true}}),       -- 2 metal blocks
      filter('BOULDER', {mat_type = 0}),                                             -- 1 boulder
      filter('CLOTH', {quantity = 20000}),                                           -- 2 cloth, any material
    }, {{job_item_idx = 0, item = bar}})
    for i = 1, 225 do item(W, 'BLOCKS', 1000 + i, GRANITE) end                       -- free stone blocks in Kern+
    item(W, 'BOULDER', 20, GRANITE)
    W.unit(1).counters2 = {thirst_timer = 10000, hunger_timer = 0}
  end}
  W.run(4)                                      -- 225 blocks and 225+ items: the scan spans frames
  local r = W.find_events('MOOD_RISK')
  T.eq(#r, 1)
  local msg = r[1].msg
  T.ok(msg:find('blocks(metal) x2: none in the fort [0/0/0 of 225]', 1, true), msg)
  T.ok(msg:find('cloth x2: none in the fort [0/0/0, thread 0]', 1, true), msg)
  T.ok(msg:find('boulders x1: enough exist', 1, true), 'the other slot the dwarf can fill is named: ' .. msg)
  T.eq(msg:find('bars', 1, true), nil, 'the attached bar is met: never reported')
  T.eq(msg:find('no source', 1, true), nil, msg)
  T.ok(#msg <= 200, #msg)
  T.eq(r[1].d.missing, {'other', 'cloth'})
  T.eq(r[1].d.slots, {'blocks(metal) x2: none in the fort [0/0/0 of 225]', 'cloth x2: none in the fort [0/0/0, thread 0]',
                      'boulders x1: enough exist'})
  local n = W.find_events('MOOD_NEED')[1]
  T.ok(n.msg:find('blocks(metal) x2: none in the fort', 1, true) and n.msg:find('cloth x2: none in the fort', 1, true), n.msg)
  T.ok(#n.msg <= 200 and #json.encode(n.d) <= 1024, #json.encode(n.d))
  -- the same text two days on: the question names both walls
  CW.day(W, 2)
  local dn = W.find_events('DECISION_NEEDED')
  T.eq(#dn, 1)
  T.ok(dn[1].d.q:find('blocks(metal) x2: none in the fort [0/0/0 of 225]', 1, true), dn[1].d.q)
  T.ok(dn[1].d.q:find('cloth x2: none in the fort', 1, true) and #dn[1].d.q <= 200, dn[1].d.q)
  -- the thirst line (the dwarf is a day from the line) names the filter too, and the slot that is still open only
  W.unit(1).counters2.thirst_timer = 31000
  CW.day(W)
  local th
  for _, e in ipairs(W.find_events('MOOD_RISK')) do if e.d.why == 'thirst' then th = e end end
  T.ok(th and th.msg:find('missing blocks(metal) x2: none in the fort [0/0/0 of 225]', 1, true), th and th.msg)
  T.ok(th.msg:find('cloth x2: none in the fort', 1, true) and #th.msg <= 200, th.msg)
  T.eq(W.bad_vectors, {})
  restore()
end)

T.test('K3: a metal block among 225 stone ones is the one that counts: the slot is fetchable, the cloth is the wall', function()
  local W = CW.world{setup = function(W)
    metal_veto()
    mats(W)
    moody(W, 1, 'Fey', {filter('BLOCKS', {mat_type = 0, quantity = 1, flags3 = {metal = true}}),
                        filter('CLOTH', {quantity = 10000})})
    for i = 1, 225 do item(W, 'BLOCKS', 1000 + i, GRANITE) end
    item(W, 'BLOCKS', 2000, IRON)
  end}
  W.run(4)
  local n = W.find_events('MOOD_NEED')[1]
  T.ok(n.msg:find('cloth x1: none in the fort', 1, true), n.msg)
  T.ok(n.msg:find('blocks(metal) x1: enough exist', 1, true), n.msg)
  T.eq(n.d.need, 'cloth x1')
  restore()
end)

-- one slot, one stock: the text of its MOOD_NEED
local function need_of(spec)
  local W = CW.world{reach = spec.reach, census_i = spec.census_i, setup = function(W)
    mats(W)
    moody(W, 1, 'Fey', spec.filters)
    if spec.items then spec.items(W) end
  end}
  W.run(1)
  return W, W.find_events('MOOD_NEED')[1]
end

T.test('K3: none in the fort - nothing of the type, or nothing that fits the filter, exists', function()
  local _, n = need_of{filters = {filter('BLOCKS', {mat_type = 0, quantity = 2})}}
  T.ok(n.msg:find('blocks x2: none in the fort [0/0/0]', 1, true), n.msg)
  local _, n2 = need_of{filters = {filter('BLOCKS', {mat_type = 0, quantity = 2, flags3 = {metal = true}})},
                        items = function(W) metal_veto(); for i = 1, 4 do item(W, 'BLOCKS', 100 + i, GRANITE) end end}
  T.ok(n2.msg:find('blocks(metal) x2: none in the fort [0/0/0 of 4]', 1, true), n2.msg)
  restore()
end)

T.test('K3: none free - the items exist but are in use, owned, claimed or forbidden where care cannot free them', function()
  local _, n = need_of{filters = {filter('BLOCKS', {mat_type = 0, quantity = 2})},
                       items = function(W)
    item(W, 'BLOCKS', 101, GRANITE, {in_job = true})
    item(W, 'BLOCKS', 102, GRANITE, {owned = true})
    item(W, 'BLOCKS', 103, GRANITE, {forbid = true}, {100, 100, 5})        -- forbidden outside Kern+: care leaves it
  end}
  T.ok(n.msg:find('blocks x2: none free [3/0/0, 1 forbidden]', 1, true), n.msg)
  -- an item the fort lost sight of is not counted as stock
  local _, n2 = need_of{filters = {filter('BLOCKS', {mat_type = 0, quantity = 1})},
                        items = function(W) item(W, 'BLOCKS', 101, GRANITE, {removed = true}); item(W, 'BLOCKS', 102, GRANITE, {in_building = true}) end}
  T.ok(n2.msg:find('blocks x1: none in the fort [0/0/0]', 1, true), n2.msg)
end)

T.test('K3: none reachable - free items the walk-group hook says the dwarf cannot walk to', function()
  local W, n = need_of{reach = function(a, b) return b.x ~= 30 end, filters = {filter('BLOCKS', {mat_type = 0, quantity = 2})},
                       items = function(W)
    item(W, 'BLOCKS', 101, GRANITE, {}, {30, 10, 5})
    item(W, 'BLOCKS', 102, GRANITE, {}, {30, 11, 5})
  end}
  T.ok(n.msg:find('blocks x2: none reachable [2/2/0]', 1, true), n.msg)
  T.eq(n.d.far, 2)
end)

T.test('K3: enough exist - the dwarf has not fetched them yet, so the blocker is the other slot', function()
  local _, n = need_of{filters = {filter('BLOCKS', {mat_type = 0, quantity = 2}), filter('SKIN_TANNED', {quantity = 1})},
                       items = function(W) for i = 1, 3 do item(W, 'BLOCKS', 100 + i, GRANITE) end end}
  T.eq(n.d.need, 'leather x1')
  T.ok(n.msg:find('leather x1: none in the fort [0/0/0]; blocks x2: enough exist', 1, true), n.msg)
  -- every slot fillable: nobody is told anything
  local W2, n2 = need_of{filters = {filter('BLOCKS', {mat_type = 0, quantity = 2})},
                         items = function(W) for i = 1, 3 do item(W, 'BLOCKS', 100 + i, GRANITE) end end}
  T.eq(n2, nil)
  T.eq(W2.find_events('MOOD_RISK'), {})
end)

T.test('K3: two slots unmet for different reasons: both are named, the one that blocks first', function()
  local _, n = need_of{reach = function(a, b) return b.x ~= 30 end,
                       filters = {filter('BLOCKS', {mat_type = 0, quantity = 1}), filter('SKIN_TANNED', {quantity = 2}),
                                  filter('BAR', {mat_type = 0, mat_index = IRON, quantity = 150})},
                       items = function(W)
    item(W, 'BLOCKS', 101, GRANITE, {}, {30, 10, 5})                             -- free, unreachable
    item(W, 'SKIN_TANNED', 102, GRANITE, {in_job = true})                       -- in use
    item(W, 'BAR', 103, IRON)                                                    -- fetchable
  end}
  T.eq(n.d.need, 'blocks x1, leather x2')
  T.ok(n.msg:find('blocks x1: none reachable [1/1/0]; leather x2: none free [1/0/0]; bars(iron) x1: enough exist', 1, true), n.msg)
  T.eq(n.d.slots, {'blocks x1: none reachable [1/1/0]', 'leather x2: none free [1/0/0]', 'bars(iron) x1: enough exist'})
end)

T.test('K3: a cloth slot names the thread stock (the wall of note 72: no thread, no plant cloth)', function()
  local _, n = need_of{census_i = {thread = 6}, filters = {filter('CLOTH', {quantity = 10000, flags2 = {plant = true}})}}
  T.ok(n.msg:find('cloth(plant) x1: none in the fort [0/0/0, thread 6]', 1, true), n.msg)
end)

T.test('K3: the texts fit the 200-byte limit of d and the 1,024 bytes of an event with eight slots of long names', function()
  local fs = {}
  local W = CW.world{setup = function(W)
    mats(W)
    for i = 1, 8 do
      F.mat(W, 0, 100 + i, {token = 'INORGANIC:A_VERY_LONG_METAL_NAME_NUMBER_' .. i})
      fs[i] = filter('BAR', {mat_type = 0, mat_index = 100 + i, quantity = 150})
    end
    moody(W, 1, 'Fey', fs)
    W.unit(1).counters2 = {thirst_timer = 31000, hunger_timer = 0}
  end}
  CW.day(W, 3)
  local seen = 0
  for _, ty in ipairs({'MOOD_RISK', 'MOOD_NEED', 'DECISION_NEEDED'}) do
    for _, e in ipairs(W.find_events(ty)) do
      seen = seen + 1
      T.ok(#e.msg <= 200, ty .. ' msg ' .. #e.msg)
      T.ok(#json.encode(e.d) <= 1024, ty .. ' d ' .. #json.encode(e.d))
      for k, v in pairs(e.d) do
        if type(v) == 'string' then T.ok(#v <= 200, ty .. '.' .. k .. ' ' .. #v) end
        if type(v) == 'table' then for _, x in ipairs(v) do if type(x) == 'string' then T.ok(#x <= 200, ty .. '.' .. k) end end end
      end
    end
  end
  T.ok(seen >= 4, seen)
  local n = W.find_events('MOOD_NEED')[1]
  T.ok(n.msg:find('+', 1, true) and n.msg:find(' more', 1, true), 'slots that do not fit are counted: ' .. n.msg)
  local q = W.find_events('DECISION_NEEDED')[1].d.q
  T.ok(q:find('smelt ore or trade.want bar', 1, true), 'the hint survives the slot list: ' .. q)
end)

T.test('K3: a changed blocker is reported again (after the cadence), the same blocker is not', function()
  local reach_ok = true
  local W = CW.world{reach = function() return reach_ok end, setup = function(W)
    mats(W)
    moody(W, 1, 'Fey', {filter('BLOCKS', {mat_type = 0, quantity = 1})})
  end}
  W.run(1)
  T.eq(#W.find_events('MOOD_NEED'), 1)
  CW.day(W, 2)
  T.eq(#W.find_events('MOOD_NEED'), 1, 'nothing changed: not repeated')
  T.eq(#W.find_events('DECISION_NEEDED'), 1, 'day 2: the first question')
  -- an unreachable block appears: the blocker changes from none in the fort to none reachable
  reach_ok = false
  item(W, 'BLOCKS', 101, GRANITE, {}, {30, 10, 5})
  CW.day(W)
  T.eq(#W.find_events('MOOD_NEED'), 1, 'the cadence (2 days and 10 minutes) holds the news back')
  W.ms = W.ms + 600000
  CW.day(W)
  local n = W.find_events('MOOD_NEED')
  T.eq(#n, 2)
  T.ok(n[2].msg:find('blocks x1: none reachable [1/1/0]', 1, true), n[2].msg)
  local dn = W.find_events('DECISION_NEEDED')
  T.eq(#dn, 2, 'the question follows the news')
  T.ok(dn[2].d.q:find('blocks x1: none reachable', 1, true), dn[2].d.q)
  CW.day(W, 3)
  T.eq({#W.find_events('MOOD_NEED'), #W.find_events('DECISION_NEEDED')}, {2, 2}, 'the same blocker: quiet')
end)

T.test('K3: an older state (a mood record without slots or announcement record) does not repeat the question at once', function()
  local persist = {['m.care'] = {v = 2, dead = {}, deaths = {}, petitions = {}, reserve = {held = {}},
                                 moods = {['1'] = {kind = 'Fey', since = 1200000, nojob = -1, ws = 0, checked = 1200000, needs = {},
                                                   unres = {since = 1200000, sig = 'blocks x1', woke = 1209600}}}}}
  local W = CW.world{persist = persist, setup = function(W)
    mats(W)
    moody(W, 1, 'Fey', {filter('BLOCKS', {mat_type = 0, quantity = 1})})
  end}
  CW.day(W, 2)
  T.eq(W.find_events('DECISION_NEEDED'), {}, 'woke two days ago: the weekly reminder is not due yet')
  T.eq(#W.find_events('MOOD_NEED'), 0, 'the list is the same: no new MOOD_NEED')
end)

T.done()
