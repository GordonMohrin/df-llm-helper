-- Run 16d i4 Trumpetrealms y407 (BUG-560): two strange moods died while the slot read 'leather x2: none free [12/0/0, 12
-- forbidden]' in PEACE. need_item freed a forbidden item only on Kern+ (`inside` does not read clean_ok while the fort has a Kern+
-- burrow), so forbidden material outside it stayed forbidden with no danger around. Now: no danger (PEACE, RECOVERY after a
-- day, a DRILL) frees a reachable forbidden mood item wherever it lies; in a SIEGE it stays, and the slot says why.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F

local function bar(W, id, mi, flags, pos)
  return F.item(W, 'BAR', {id = id, mat_type = 0, mat_index = mi, flags = flags or {}, _pos = pos or {10, 10, 5}})
end
local function filter(t, spec)
  local f = {item_type = t and df.item_type[t] or -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end
local function moody(W, id, kind, filters)
  local u = W.unit(id)
  u.mood = df.mood_type[kind]
  u.job.current_job = CW.mood_job(W, 900 + id, F.workshop(W, 'Craftsdwarfs'), filters)
  return u
end
local function logged(W, needle)
  for _, l in ipairs(W.logs) do if tostring(l.msg or ''):find(needle, 1, true) then return true end end
  return false
end

local function world(mode)
  return CW.world{mode = mode, reach = function() return true end, setup = function(W)
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    moody(W, 1, 'Fell', {filter('BAR', {mat_type = 0, quantity = 2})})
    bar(W, 51, 9, {forbid = true}, {100, 100, 5})          -- forbidden, outside Kern+ (0..50), reachable
    bar(W, 52, 9, {forbid = true}, {101, 100, 5})
    bar(W, 53, 9, {forbid = true}, {102, 100, 5})
    W.unit(1).counters2 = {thirst_timer = 10000, hunger_timer = 0}
  end}
end

T.test('BUG-560: PEACE: a reachable forbidden mood item outside Kern+ is freed (two for two bars), kern.log says so', function()
  local W = world('PEACE')
  W.run(1)
  T.eq(CW.flags(W), {{51, 'forbid', false}, {52, 'forbid', false}}, 'old code: nothing freed outside Kern+')
  T.ok(logged(W, 'care: mood unit 1: unforbade item 51 for'), 'kern.log')
  T.ok(logged(W, 'outside Kern+, no danger'), 'kern.log names the reason')
end)

T.test('BUG-560: DRILL is no danger either; SIEGE keeps the item forbidden and the slot names why', function()
  local W = world('DRILL')
  W.run(1)
  T.eq(#CW.flags(W), 2)
  local W2 = world('SIEGE')
  W2.run(1)
  T.eq(CW.flags(W2), {}, 'a SIEGE: outside Kern+ stays forbidden')
  local n = W2.find_events('MOOD_NEED')
  T.ok(#n >= 1 and n[1].msg:find('3 forbidden (Kern+ only, SIEGE)', 1, true), n[1] and n[1].msg)
end)

T.done()
