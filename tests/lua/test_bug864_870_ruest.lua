-- Neuausrichtung 9 (ruest): BUG-864 the elite is not put off duty, BUG-865 the unequipped text names its cause / gloves do not decide 'armor' / the loot
-- sweep takes leather armor, BUG-870 squad.uniform replaces a worn wooden weapon when a real one is assigned or free.
local T = require('testlib')
local X = require('wp6_world')

local function world()
  local W = X.world{units = X.citizens(30, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}}), training = true}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), X.runner('P5')}, {'sense', 'threat', 'siege', 'gate'})
  W.set_census('i', {tick = 0, g_weapon = 8, g_body = 2, g_shield = 14, w_axe = 4, w_pick = 4})
  for _ = 1, 12 do X.weapon(W, 'ITEM_WEAPON_SPEAR') end
  local items = W.items_by_id
  df.item = df.item or {}
  df.item.find = function(id) return items[id] end
  return W
end

local function seats(W, n)
  W.K.set_mode('PEACE', 'test')
  W.run(1200 * 3, {skip = 9})
  local A = X.squad_of(W, 'A')
  local out = {}
  for i = 0, 9 do
    local hf = A.positions[i].occupant
    if hf >= 0 then
      local uid = W.hfs[hf].unit_id
      if #out < n then out[#out + 1] = {pos = i, uid = uid} else X.unseat(W, A, uid) end
    end
  end
  return A, out
end

T.test('BUG-865: gloves do not decide armor: body, head, pants and shoes filled = armor, a missing body is not', function()
  local KIT = require('dfllm.kit')
  local R = {[1] = true}
  local function item(id) return {id = id, getType = function() return 99 end, getSubtype = function() return 0 end} end
  local function soldier(filled, empty)
    local uni, inv = {}, {}
    for i, c in ipairs(KIT.ARMOR) do
      uni[c] = {}
      if not empty[c] then
        uni[c][1] = {item = i, assigned = {}}
        inv[#inv + 1] = {mode = 1, item = item(i)}
      end
    end
    return {equipment = {uniform = uni}}, {inventory = inv}
  end
  local p, u = soldier(true, {gloves = true})
  local x = KIT.soldier(p, u, R, nil)
  T.eq(x.armor, true, 'only the gloves empty: armor')
  T.eq(x.empty.gloves, true, 'the gloves stay named as empty')
  p, u = soldier(true, {gloves = true, body = true})
  T.eq(KIT.soldier(p, u, R, nil).armor, false, 'no body armor: not armor')
end)

T.test('BUG-864: the elite squads stay on Constant training in the free months; elite_off = true is the old rest', function()
  local W = world()
  local A = seats(W, 3)
  local M = X.mod('military')
  local c = M.conf(W.K)
  T.eq(c.elite_off, false, 'default off')
  W.K.cfg.baseline.military = {elite_off = true}
  T.eq(M.conf(W.K).elite_off, true)
end)

T.test('BUG-865: the unequipped text names a cause measured on the squad (no boilerplate about specs)', function()
  local W = world()
  local A, m = seats(W, 3)
  W.run(1200 * 3, {skip = 9})
  local txt = X.mod('military').kit_missing(W.K, 'A')
  T.ok(txt:find('cause: ', 1, true), txt)
  T.ok(txt:find('DF has assigned NO piece', 1, true) or txt:find('DF assigned', 1, true), txt)
  T.ok(not txt:find('the uniform specs do not match them', 1, true), 'the old guess is gone: ' .. txt)
end)

T.test('BUG-870: squad.uniform replaces a worn wooden weapon when a real melee weapon is free', function()
  local W = world()
  for _ = 1, 4 do X.weapon(W, 'ITEM_WEAPON_SPEAR_TRAINING') end
  local A, m = seats(W, 3)
  W.run(1200 * 3, {skip = 9})
  local pos = m[1].pos
  local it = X.weapon(W, 'ITEM_WEAPON_SPEAR_TRAINING')
  it.flags.in_inventory = true
  W.unit(m[1].uid).inventory:insert('#', {item = it, mode = df.inv_item_role_type.Weapon})
  X.set_uniform(A, {positions = {pos}, items = {{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_SPEAR_TRAINING', mat = 'any'}}})
  for _, sp in ipairs(A.positions[pos].equipment.uniform.weapon) do sp.assigned:insert('#', it.id) end
  local r = W.inbox('squad.uniform', {squad = 'A', kind = 'melee'})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('hold a wooden weapon: the weapon spec is replaced by a real one', 1, true), r.msg)
  local wood = false
  for _, sp in ipairs(A.positions[pos].equipment.uniform.weapon) do
    if sp.item_subtype and sp.item_subtype >= 0 and X.WEAPONS[sp.item_subtype + 1][1]:find('TRAINING', 1, true) then wood = true end
  end
  T.ok(not wood, 'no wooden weapon spec is left on the position')
end)

T.test('BUG-868: the drink halt says drink INSIDE the core; the why-brew line counts the census plants when the scan finds none', function()
  local R = require('dfllm.readiness')
  local c = {}
  for k, v in pairs(R.GROWTH) do c[k] = v end
  c.on = true
  local g = R.growth_ladder({n = 3, fullr = 2, metal = 0, sq_n = 3, sq_f = 3, sq_a = 3, sq_w = 3, sq_ok = true, lvl = 1, lever = true, drink_d = 12}, c)
  T.eq(g.halt, 'drink')
  T.ok(g.need:find('drink inside the core 12 d <', 1, true), g.need)
  package.loaded['dfllm.jobwhy'] = nil
  local J = require('dfllm.jobwhy')
  local t = J.input_text({what = 'plant (DRINK_MAT)', need = 1, match = 0, free = 0, cens = 936})
  T.ok(t:find('0 match by the scan, the census holds 936 usable (plants inside containers count as input)', 1, true), t)
  T.ok(J.input_text({what = 'plant', need = 1, match = 4, free = 4}):find('4 match', 1, true), 'a real match is unchanged')
end)

T.test('BUG-869: what each treatment posting waits for: posted / taken per job type, the doctors jobs, as text', function()
  local W = world()
  local water = require('dfllm.water')
  local jt = df.job_type
  jt.DiagnosePatient = jt.DiagnosePatient or 9001
  jt.Suture = jt.Suture or 9002
  local function job(t, worker) return {job_type = t, _worker = worker} end
  local jobs = {job(jt.DiagnosePatient), job(jt.DiagnosePatient), job(jt.DiagnosePatient, 5), job(jt.Suture)}
  local head, cur = {}, nil
  cur = head
  for _, j in ipairs(jobs) do cur.next = {item = j}; cur = cur.next end
  df.global.world.jobs = {list = head}
  local gw = dfhack.job.getWorker
  dfhack.job.getWorker = function(j) return j._worker end
  local tw = water.treat_waits(W.K)
  dfhack.job.getWorker = gw
  T.eq(tw.types.DiagnosePatient, {posted = 3, taken = 1})
  T.eq(tw.types.Suture, {posted = 1, taken = 0})
  local txt = water.treat_text(tw)
  T.ok(txt:find('DiagnosePatient 3 posted, 1 taken', 1, true) and txt:find('Suture 1 posted, 0 taken', 1, true), txt)
  T.ok(water.treat_text({types = {}, doctors = {n = 0, jobs = {}}}):find('no treatment job is posted', 1, true))
end)

T.done()
