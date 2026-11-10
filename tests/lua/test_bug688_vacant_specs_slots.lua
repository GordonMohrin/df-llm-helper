-- BUG-688 (Run 16d i4 Trumpetrealms y447-y456: 'squad.uniform B melee: 10 positions', B stays at armor 0 / fit 0 with 12-22 free body armors; worn
-- 82 -> 29 % over the years, 0 of 11 soldiers fully equipped; kern.log 'N gear pieces DF kept assigned ... given back' every 160 s with the same
-- ids, 5-12 of them 'for a vacant position'; Run 16a i1: worn 13-75 %, 5 of 12 fit): the squads have 10 positions each and 3-11 soldiers, the
-- uniform went to ALL positions (first uniform, squad.uniform verb) and a dead soldier's position kept hers, so DF reserved the free gear for
-- the specs of the vacant positions and release_kit gave it back for it to be reserved again.
--   * ensure_uniform and squad.uniform spec the occupied positions only; military.vacant_sweep clears specs and assigned gear of vacant positions
--     (act.squad_unequip); a position is specced the upkeep it is occupied
--   * military.slot_why / slot_report / inspect what=military: per soldier and empty slot the reason (nospec / assigned + what is wrong with the
--     piece / mat / unlisted / none + what keeps the lying pieces back)
local T = require('testlib')
local X = require('wp6_world')
local vec = require('dfllm.util.k_mock').vec

local function mil() return X.mod('military') end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return true end end
  return false
end
local saved = {}
local function fakes()
  saved.def, saved.pos, saved.cont, saved.holder = dfhack.items.getSubtypeDef, dfhack.items.getPosition, dfhack.items.getContainer,
                                                   dfhack.items.getHolderUnit
  local real = saved.def
  dfhack.items.getSubtypeDef = function(t, sub)
    if t == df.item_type.ARMOR then return {id = 'ITEM_ARMOR_BREASTPLATE', armorlevel = 1} end
    return real(t, sub)
  end
  dfhack.items.getPosition = function(it) return it._x or 10, 10, 10 end
  dfhack.items.getContainer = function(it) return it._cont end
  dfhack.items.getHolderUnit = function(it) return it._unit end
  df.global.plotinfo.race_id = 1
  df.global.plotinfo.equipment = {items_assigned = {WEAPON = vec{}, ARMOR = vec{}, HELM = vec{}, PANTS = vec{}, GLOVES = vec{},
                                                     SHOES = vec{}, SHIELD = vec{}}}
end
local function unfake()
  dfhack.items.getSubtypeDef, dfhack.items.getPosition = saved.def, saved.pos
  dfhack.items.getContainer, dfhack.items.getHolderUnit = saved.cont, saved.holder
end
local function boot(opts)
  opts = opts or {}
  opts.n = opts.n or 50
  local W = X.world(opts)
  local snap = X.snapshot()
  function snap.far(K, x, y, z) return x == 99 end
  X.load(W, {'military'}, {X.runner('P5'), snap}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  W.run(3600, {skip = 9})                 -- the members seated after the squad was made have their specs
  return W
end
local function body(W, over)
  local it = X.item(W, 'ARMOR')
  it._sub, it.flags = 1, {}
  it.getSubtype = function(self) return self._sub end
  for k, v in pairs(over or {}) do it[k] = v end
  df.global.world.items.other.ARMOR:insert('#', it)
  return it
end
local function specs_of(s, pos)
  local n = 0
  for _, c in ipairs(X.CATS) do n = n + #s.positions[pos].equipment.uniform[c] end
  return n
end

T.test('BUG-688: a fresh squad is specced on its occupied positions only; a vacant position holds no spec and no claim', function()
  local W = boot()
  local A = X.squad_of(W, 'A')
  for pos = 0, 9 do
    if A.positions[pos].occupant >= 0 then T.ok(specs_of(A, pos) > 0, 'occupied position ' .. pos .. ' has its specs')
    else T.eq(specs_of(A, pos), 0, 'vacant position ' .. pos .. ' has none') end
  end
end)

T.test('BUG-688: vacant positions that hold specs and assigned gear (a dead soldier\'s, an old uniform) are cleared; a new soldier gets his specs ' ..
       'the next upkeep; the soldiers\' own specs stay', function()
  local W = boot()
  fakes()
  df.global.world.items.other.ARMOR = vec{}
  local A = X.squad_of(W, 'A')
  local occ = {}
  for pos = 0, 9 do if A.positions[pos].occupant >= 0 then occ[#occ + 1] = pos end end
  T.ok(#occ >= 2 and #occ < 10, 'a squad with vacant positions')
  local keep = {}
  for _, pos in ipairs(occ) do keep[pos] = #A.positions[pos].equipment.uniform.body end
  local claimed = body(W)
  X.set_uniform(A, {positions = {7, 8, 9}, items = {{cat = 'body', type = 'ARMOR', mat = 'any'}, {cat = 'head', type = 'HELM', mat = 'any'}}})
  A.positions[8].equipment.assigned_items:insert('#', claimed.id)
  A.positions[8].equipment.uniform.body[0].assigned:insert('#', claimed.id)
  local before = #X.acts(W, 'squad_unequip')
  W.run(3600 * 2, {skip = 9})
  local acts = X.acts(W, 'squad_unequip')
  T.ok(#acts > before, 'squad_unequip was sent')
  local sent = {}
  for i = before + 1, #acts do for _, p in ipairs(acts[i].args[2] or {}) do sent[p] = true end end
  T.ok(sent[7] and sent[8] and sent[9], 'for the vacant positions: ' .. T.show(sent))
  for _, pos in ipairs(occ) do T.ok(not sent[pos], 'never an occupied position (' .. pos .. ')'); T.eq(#A.positions[pos].equipment.uniform.body, keep[pos]) end
  for pos = 7, 9 do T.eq(specs_of(A, pos), 0, 'cleared ' .. pos); T.eq(#A.positions[pos].equipment.assigned_items, 0) end
  T.ok(logged(W, 'vacant positions held uniform specs and the gear DF reserved for them: cleared'), 'kern.log says so')
  local n = #X.acts(W, 'squad_unequip')
  W.run(3600 * 2, {skip = 9})
  T.eq(#X.acts(W, 'squad_unequip'), n, 'nothing to clear: no further call (no churn)')
  -- a soldier takes position 7: his specs come with the next upkeep
  local uid
  for i = 1, 50 do
    local u = W.unit(i)
    if u and (u.military.squad_id or -1) < 0 and not uid and i > 30 then uid = i end
  end
  X.seat(W, A, 7, uid)
  T.eq(specs_of(A, 7), 0, 'bare when seated')
  W.run(3600, {skip = 9})
  T.ok(specs_of(A, 7) > 0, 'specced by ensure_uniform')
  unfake()
end)

T.test('BUG-688: the squad.uniform verb specs the occupied positions only and says how many', function()
  local W = boot()
  local A = X.squad_of(W, 'A')
  local occ = 0
  for pos = 0, 9 do if A.positions[pos].occupant >= 0 then occ = occ + 1 end end
  T.ok(occ < 10, 'vacant positions exist')
  local r = W.inbox('squad.uniform', {squad = 'A', kind = 'melee'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.positions, occ, 'the occupied positions: ' .. r.msg)   -- (old code: 10)
  T.ok(r.msg:find(('uniform on %d positions'):format(occ), 1, true), r.msg)
  for pos = 0, 9 do
    if A.positions[pos].occupant < 0 then T.eq(specs_of(A, pos), 0, 'vacant ' .. pos) end
  end
end)

T.test('BUG-688: slot_report names per soldier and slot why it is empty: no spec, the piece DF assigned and what is wrong with it, material, ' ..
       'nothing assigned though pieces lie free, no piece at all', function()
  local W = boot()
  fakes()
  df.global.world.items.other.ARMOR = vec{}
  df.global.world.items.other.HELM = vec{}
  local M, K = mil(), W.K
  local A = X.squad_of(W, 'A')
  local occ = {}
  for pos = 0, 9 do if A.positions[pos].occupant >= 0 then occ[#occ + 1] = pos end end
  T.ok(#occ >= 3, 'three soldiers')
  local p0, p1, p2 = occ[1], occ[2], occ[3]
  -- p0: no body spec; p1: a metal spec while only pieces of no metal lie free; p2: a spec DF assigned a forbidden piece
  A.positions[p0].equipment.uniform.body = vec{}
  X.set_uniform(A, {positions = {p1}, items = {{cat = 'body', type = 'ARMOR', mat = 'metal'}}})
  local frob = body(W, {flags = {forbid = true}})
  X.set_uniform(A, {positions = {p2}, items = {{cat = 'body', type = 'ARMOR', mat = 'any'}}})
  A.positions[p2].equipment.uniform.body[0].assigned:insert('#', frob.id)
  body(W); body(W)                                                       -- two usable pieces of no metal / leather
  W.run(9, {skip = 9})
  local out, counts = M.slot_report(K, A)
  T.eq(#out, #occ)
  local by = {}
  for _, m in ipairs(out) do by[m.pos] = m end
  T.eq(by[p0].slots.body.code, 'nospec')
  T.eq(by[p1].slots.body.code, 'mat', by[p1].slots.body.why)
  T.ok(by[p1].slots.body.why:find('spec metal, 0 free metal pieces, 2 of other material lie free', 1, true), by[p1].slots.body.why)
  T.eq(by[p2].slots.body.code, 'assigned')
  T.eq(by[p2].slots.body.item, frob.id)
  T.ok(by[p2].slots.body.why:find('forbidden', 1, true), by[p2].slots.body.why)
  -- head: specs everywhere, no helm in the fort
  T.eq(by[p1].slots.head.code, 'none')
  T.ok(by[p1].slots.head.why:find('no free piece', 1, true), by[p1].slots.head.why)
  T.eq(counts.body, {nospec = 1, mat = 1, assigned = 1})
  -- an any-material spec with free pieces and nothing assigned: DF has not handed them out
  X.set_uniform(A, {positions = {p1}, items = {{cat = 'body', type = 'ARMOR', mat = 'any'}}})
  local _, c2 = M.slot_report(K, A)
  T.eq(c2.body.unlisted, 1)
  -- a piece out of reach is named in the 'none' text
  local alien = body(W, {maker_race = 7})
  df.global.world.items.other.ARMOR = vec{}
  df.global.world.items.other.ARMOR:insert('#', alien)
  local code, why = M.slot_why(K, {p = A.positions[p1], unit = W.unit(0) or {id = 0}}, 'body', {})
  T.eq(code, 'none')
  T.ok(why:find('1 made by another race', 1, true), why)
  -- inspect carries it: data.squads[].members / why / lack
  local r = W.inbox('inspect', {what = 'military'})
  T.ok(r.ok, tostring(r.msg))
  local sq
  for _, x in ipairs(r.data.squads) do if x.key == 'A' then sq = x end end
  T.ok(sq and sq.members and #sq.members == #occ and sq.why and sq.lack, 'per-slot data in inspect')
  T.ok(sq.lack:find('body', 1, true), sq.lack)
  unfake()
end)

T.done()
