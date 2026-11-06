-- BUG-518 (Run 16b i2 Brotherarrow y385: a ghost scared a citizen to death, five corpses lay in tree crowns without a walk group so
-- no coffin, zone or hauler could bury them): the dead citizens whose bodies nobody can walk to get their memorial slab before the
-- ghost comes (care's memorial phase, economy's slab pass), and tombs.repair / inspect tombs say it instead of 'queued' alone.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F

local function corpse(W, uid, pos)
  return F.item(W, 'ANY_CORPSE', {unit_id = uid, _pos = pos})
end
local function dead(W, id, hf)
  W.unit(id).hist_figure_id = hf
  W.kill(id)
  W.event('UNIT_DEATH', {unit = id})
end

local function crown_world(setup)
  local units = {}
  for i = 0, 5 do units[#units + 1] = {id = 6100 + i, citizen = true, pos = {5, 5, 5}} end
  return CW.world{cit = 6, units = units,
    reach = function(a, b) return not (a.x >= 100 or b.x >= 100) end,
    tile = function(x, y, z)
      if x >= 120 then return {c = '.', dig = '', bld = '', shape = 'BRANCH'} end
      return {c = '.', dig = '', bld = '', shape = 'FLOOR'}
    end,
    snap = {groups = function(K, pts)
      local r = {}
      for i, p in ipairs(pts) do r[i] = (p.x >= 130) and 0 or ((p.x >= 100) and 859 or 9) end
      return r
    end},
    setup = setup}
end

T.test('BUG-518: bodies in tree crowns are listed by care.unreach_ids (with a figure only), inspect tombs shows them with their slab state', function()
  local W, Cm = crown_world(function(W)
    dead(W, 6100, 700); corpse(W, 6100, {120, 64, 133})
    dead(W, 6101, 701); corpse(W, 6101, {121, 64, 133})
    dead(W, 6102, -1); corpse(W, 6102, {122, 64, 133})            -- no historical figure: no slab can name it
  end)
  CW.day(W, 4)
  T.eq(Cm.unreach_ids(W.K), {6100, 6101})
  local ins = W.inbox('inspect', {what = 'tombs'})
  T.ok(ins.ok, ins.msg)
  T.eq(ins.data.unreach, {{6100, 'none'}, {6101, 'none'}})
  T.eq(ins.data.unreach_n, 3, 'the old count still has all three')
  local logged = false
  for _, l in ipairs(W.logs) do if tostring(l.msg or l[3] or l):find('nobody can path to', 1, true) then logged = true end end
  T.ok(logged, 'one warn line says it')
end)

T.test('BUG-518: tombs.repair says that bodies nobody can walk to are no burial work and that a memorial slab is their burial', function()
  local W = crown_world(function(W)
    dead(W, 6100, 700); corpse(W, 6100, {120, 64, 133})
    dead(W, 6101, 701); corpse(W, 6101, {121, 64, 133})
  end)
  CW.day(W, 4)
  local r = W.inbox('tombs.repair', {})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('^queued: the next care run repairs the tombs'), r.msg)
  T.ok(r.msg:find('2 citizen bodies lie where nobody can walk', 1, true) and r.msg:find('memorial slab is their burial', 1, true), r.msg)
  T.eq({r.data.unreach_n, r.data.unreach}, {2, {{6100, 'none'}, {6101, 'none'}}})
  -- nothing unreachable: the old short answer
  local W2 = crown_world(function(W) end)
  CW.day(W2, 2)
  local r2 = W2.inbox('tombs.repair', {})
  T.eq(r2.msg, 'queued: the next care run repairs the tombs and retries entomb for every unburied citizen')
end)

T.done()
