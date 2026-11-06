-- BUG-535 (Run 16d i4 Trumpetrealms: a strange mood said 'gems x1: none in the fort [0/0/0]' while the census held 39 gems): the
-- census counts rough and cut gems together; the slot wanted a ROUGH gem and the fort held only cut ones. The slot names its form,
-- says which gems exist in the other form, a rough-gem slot is no CutGems job, and items a unit carries (or a claimed bin holds) are
-- counted instead of vanishing.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local R = require('dfllm.reserve')

local function filter(t, spec)
  local f = {_t = t, mat_type = -1, mat_index = -1, quantity = 1, flags1 = {}, flags2 = {}, flags3 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

local function item(W, cat, id, mi, flags, pos)
  local it = F.item(W, cat, {id = id, mat_type = 0, mat_index = mi, flags = flags or {}, _pos = pos or {10, 10, 5}})
  it.getSubtype = function() return -1 end
  it.getMaterial = function(self) return self.mat_type end
  it.getMaterialIndex = function(self) return self.mat_index end
  return it
end

local function moody(W, id, kind, filters)
  local u = W.unit(id)
  for _, f in ipairs(filters) do f.item_type = f._t and df.item_type[f._t] or -1 end
  u.mood = df.mood_type[kind]
  u.job.current_job = CW.mood_job(W, 900 + id, F.workshop(W, 'Craftsdwarfs'), filters, {})
  return u
end

T.test('BUG-535: a rough-gem slot with only cut gems in the fort names both forms; the way to get it is buying, not cutting', function()
  local W = CW.world{census_i = {gems = 3}, setup = function(W)
    F.mat(W, 0, 7, {token = 'INORGANIC:AGATE'})
    moody(W, 1, 'Fey', {filter('ROUGH', {mat_type = 0}), filter('SMALLGEM', {})})
    for i = 1, 3 do item(W, 'SMALLGEM', 500 + i, 7) end          -- three cut gems, no rough one
    W.unit(1).counters2 = {thirst_timer = 10000, hunger_timer = 0}
  end}
  W.run(4)
  local r = W.find_events('MOOD_RISK')
  T.eq(#r, 1)
  local msg = r[1].msg
  T.ok(msg:find('gems(rough) x1: none in the fort [0/0/0, 3 cut gems exist, a rough one is needed]', 1, true), msg)
  T.ok(msg:find('gems(cut) x1: enough exist', 1, true), msg)
  local n = W.find_events('MOOD_NEED')[1]
  T.ok(n.d.acq:find('gems:buy', 1, true) and not n.d.acq:find('CutGems', 1, true), n.d.acq)
  T.eq(W.bad_vectors, {})
end)

T.test('BUG-535: a cut-gem slot with only rough gems says a jeweler cuts them; the slot name and the acquisition per form', function()
  local W = CW.world{census_i = {gems = 2}, setup = function(W)
    F.mat(W, 0, 7, {token = 'INORGANIC:AGATE'})
    moody(W, 1, 'Fey', {filter('SMALLGEM', {})})
    for i = 1, 2 do item(W, 'ROUGH', 600 + i, 7) end
    W.unit(1).counters2 = {thirst_timer = 10000, hunger_timer = 0}
  end}
  W.run(4)
  local msg = W.find_events('MOOD_RISK')[1].msg
  T.ok(msg:find('gems(cut) x1: none in the fort [0/0/0, 2 rough gems exist, a jeweler cuts them]', 1, true), msg)
  T.eq(R.acq({cls = 'gems', tname = 'ROUGH'}), {'buy'})
  T.eq(R.acq({cls = 'gems', tname = 'SMALLGEM'}), {'order:CutGems', 'buy'})
  T.eq(R.acq({cls = 'gems', legacy = 'rough', tname = 'ROUGH'}), {'order:CutGems', 'buy'})
  T.eq(R.slot_name({cls = 'gems', tname = 'ROUGH'}), 'gems(rough)')
  T.eq(R.slot_name({cls = 'gems', tname = 'SMALLGEM', words = 'hard'}), 'gems(cut/hard)')
end)

T.test('BUG-535: a gem a unit carries is counted, not invisible', function()
  local W = CW.world{census_i = {gems = 1}, setup = function(W)
    F.mat(W, 0, 7, {token = 'INORGANIC:AGATE'})
    moody(W, 1, 'Fey', {filter('SMALLGEM', {})})
    item(W, 'SMALLGEM', 700, 7, {in_inventory = true})          -- worn / carried, no container
    W.unit(1).counters2 = {thirst_timer = 10000, hunger_timer = 0}
  end}
  W.run(4)
  local msg = W.find_events('MOOD_RISK')[1].msg
  T.ok(msg:find('1 carried/in a claimed bin', 1, true), msg)
end)

T.done()
