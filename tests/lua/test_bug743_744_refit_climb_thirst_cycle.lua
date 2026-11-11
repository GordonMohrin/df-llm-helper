-- BUG-743 (Run 16d i4 Pagedsculpture y384-y402: kern.log 'pants of 3 positions to metal material (free metal pieces cover them)', 11,000 ticks
-- later 'to any material (the slot stayed empty ...)', again 'to metal' ...; worn 76 % -> 21 % -> 76 %; 139 squad.uniform acts in 15 years):
-- a position moved DOWN to any material climbed back to metal as soon as the stock counted a free metal piece (the stock counts copper and
-- silver, the spec's armor class does not take them), the soldier dropped what he wore, the metal spec stayed empty, the refit moved it down
-- again. Every position moved down is held from the climb for RF_HOLD ticks, twice as long for each repeat; and a gear piece DF keeps
-- assigned to a position and nobody fetches is no piece of the fort's gear (economy's census counts it missing, a fresh one is ordered).
-- BUG-744 (Run 16b i2 Whirledrampart, 16a i1 patient 26925: thirst 700 -> 30,200 -> 700 and a DECISION patient_thirst at every crossing with
-- 'GiveWater jobs running, 0 stuck'): DF hands a patient water at about the alarm line; the alarm is news when it lasts, climbs past DF's
-- service point or the verdict says nobody gives water.
local T = require('testlib')
local X = require('wp6_world')
local KIT = require('dfllm.kit')

local function mil() return X.mod('military') end
local DAY = 1200

local function pos(i, mat, empty, soft)
  return {pos = i, p = {equipment = {uniform = {body = {{material_class = X.MAT_CLASS[mat] or -1}}, head = {}, pants = {}, gloves = {},
                                                shoes = {}}}},
          kit = {empty = empty and {body = true} or {}, soft = soft and {body = true} or {}}}
end

T.test('BUG-743: refit_plan reports every position moved down to any material (not only the stuck ones)', function()
  X.world{n = 5}
  local a = pos(0, 'metal', true)
  local plan, _, stuck, freed = KIT.refit_plan({a}, function() return {metal = 0, leather = 0, any = 2} end)
  T.eq(plan, {{cat = 'body', mat = 'any', positions = {0}}})
  T.eq(stuck, {}, 'not stuck: its own material count was 0')
  T.eq(freed, {body = {[0] = true}}, 'but freed: the caller holds it from the climb')
end)

T.test('BUG-743: the climb to metal waits for a held position; an unheld soft slot still climbs', function()
  X.world{n = 5}
  local soft = pos(2, 'any', false, true)
  local stock = function() return {metal = 3, leather = 0, any = 3} end
  T.eq(KIT.refit_plan({soft}, stock), {{cat = 'body', mat = 'metal', positions = {2}}}, 'free metal: up')
  T.eq(KIT.refit_plan({soft}, stock, {hold = {body = {[2] = true}}}), {}, 'held: stays on any material')
  T.eq(KIT.refit_plan({soft}, stock, {hold = {body = {[7] = true}}}), {{cat = 'body', mat = 'metal', positions = {2}}}, 'another position held')
end)

T.test('BUG-743: the hold grows with every repeat (60 game days, then 120 ... at most 8x) and survives a reload', function()
  local W = X.world{n = 20}
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  local M = mil()
  T.eq({M.refit_hold_ticks(1), M.refit_hold_ticks(2), M.refit_hold_ticks(3)}, {72000, 144000, 288000})
  T.eq(M.refit_hold_ticks(4), 576000)
  T.eq(M.refit_hold_ticks(9), 576000, 'capped')
  T.eq(M.refit_hold_ticks(nil), 72000)
  local saved = M.refit_hold_save({body = {[3] = {t = 100, n = 2}}})
  T.eq(saved, {body = {['3'] = {t = 100, n = 2}}}, 'JSON string keys')
  T.eq(M.refit_hold_load(saved), {body = {[3] = {t = 100, n = 2}}})
  T.eq(M.refit_hold_load({body = {['x'] = {t = 5}}, junk = 7}), nil)
  T.eq(M.refit_hold_load(nil), nil)
end)

T.test('BUG-743: the refit writes the hold of a position it moved down (squad record rh)', function()
  local W = X.world{n = 50, training = true}
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  local M = mil()
  local A = X.squad_of(W, 'A')
  X.set_uniform(A, {items = {{cat = 'body', type = 'ARMOR', mat = 'metal'}}})
  local stock = {body = {metal = 1, leather = 4, any = 5}}
  local real = M.stock_mats
  M.stock_mats = function(cat) return stock[cat] or {metal = 0, leather = 0, any = 0} end
  W.set_mode('ALERT')
  W.run(8 * DAY, {skip = 9})
  local rec = (W.K.persist.get('m.military') or {sq = {}}).sq.A
  T.ok(rec and rec.rh and rec.rh.body, 'the squad record holds the positions moved down: ' .. T.show(rec and rec.rh))
  local any
  for _, r in pairs(rec.rh.body) do any = r; break end
  T.ok(any and any.t and (any.n or 0) >= 1, T.show(rec.rh))
  M.stock_mats = real
end)

T.test('BUG-743: stuck_ids: the pieces military wrote off (stuck, or reserved out of reach) are no gear of the fort', function()
  local W = X.world{n = 20}
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  local M = mil()
  T.eq(M.stuck_ids(), {})
end)

T.test('BUG-744: alarm_ripe: a crossing is news after the grace, past the margin, or when nobody gives water; not while DF serves him', function()
  local W = X.world{n = 5}
  X.load(W, {'water'}, {}, {'sense'})
  local M = X.mod('water')
  local c = M.DEFAULTS
  T.eq(M.alarm_ripe(c, 100, 30500, {key = 'run'}, false), false, 'just over the line, jobs running: DF is serving him')
  T.eq(M.alarm_ripe(c, c.alarm_grace, 30500, {key = 'run'}, false), true, 'over the line for alarm_grace ticks')
  T.eq(M.alarm_ripe(c, 100, c.thirst_alarm + c.alarm_margin, {key = 'run'}, false), true, 'climbed past DF\'s service point')
  T.eq(M.alarm_ripe(c, 100, 30500, {key = 'noeffect'}, false), true, 'a job without effect is news at once')
  T.eq(M.alarm_ripe(c, 100, 30500, {key = 'nowater'}, false), true, 'no water is news at once')
  T.eq(M.alarm_ripe(c, 100, 30500, nil, false), false, 'no verdict yet: wait')
  T.eq(M.alarm_ripe(c, 100, 30500, {key = 'nojob'}, true), false, 'no hospital: no GiveWater job by design')
  T.eq(M.alarm_ripe(c, 100, 30500, {key = 'nojob'}, false), true, 'a hospital without a job is news')
end)

T.done()
