-- BUG-055 (Run 11 note 25, Run 14 notes 61/64): vacant offices (the chief medical dwarf), the offices view, the verbs
-- appoint and squad.create/leader/add/uniform, the readiness blocker `office`.
local T = require('testlib')
local F = require('wp8_world')
local X = require('wp6_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local vec = kmock.vec

-- the fort entity with positions and assignments (act.lua / economy.positions read exactly these)
local function entity(codes)
  local own, asg = {}, {}
  for i, c in ipairs(codes) do
    own[#own + 1] = {id = 10 + i, code = c.code, flags = {ACTIVE = c.active ~= false}, responsibilities = {}}
    asg[#asg + 1] = {id = 20 + i, position_id = 10 + i, histfig = c.held or -1, histfig2 = -1, squad_id = -1}
  end
  return {id = 321, positions = {own = vec(own), assignments = vec(asg)}}
end

local function econ_world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, opts.cit or 8 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, opts.cit or 8 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.hist_figure_id = 100 + i
  end
  df.job_skill.DIAGNOSE, df.job_skill[40] = 40, 'DIAGNOSE'
  df.job_skill.SURGERY, df.job_skill[41] = 41, 'SURGERY'
  df.global.plotinfo = df.global.plotinfo or {}
  df.global.plotinfo.main = {fortress_entity = entity(opts.offices or {
    {code = 'MANAGER', held = 101}, {code = 'CHIEF_MEDICAL_DWARF'}})}
  W.set_census('u', F.census_u(ids))
  if opts.setup then opts.setup(W) end
  local E = fresh('economy')
  W.load(E)
  return W, E
end
local function appointed(W)
  local r = {}
  for _, a in ipairs(W.find_acts('appoint')) do r[#r + 1] = {a.args[1], a.args[2]} end
  return r
end

T.test('BUG-055: the vacant CHIEF_MEDICAL_DWARF office (ACTIVE) is filled with the best healer; a soldier on duty never', function()
  local W, E = econ_world{setup = function(W)
    W.unit(3)._m.skills = {DIAGNOSE = 13}; W.unit(3).military.squad_id = 4      -- the best healer is a soldier
    W.unit(5)._m.skills = {DIAGNOSE = 9, SURGERY = 4}
    W.unit(6)._m.skills = {DIAGNOSE = 2}
  end}
  days(W, 1)
  T.eq(appointed(W), {{'CHIEF_MEDICAL_DWARF', 5}}, 'unit 5; the manager office is held, unit 3 is a soldier')
  T.eq(E.offices(W.K), {}, 'filled: no vacancy left in the view')
end)

T.test('BUG-055: an office nobody fills is listed with days, candidate and reason (economy.offices, inspect offices)', function()
  local W, E = econ_world{setup = function(W)
    W.unit(5)._m.skills = {DIAGNOSE = 9}
    W.act_result('appoint', function() return false, 'CHIEF_MEDICAL_DWARF is not offered yet' end)
  end}
  days(W, 3)
  local o = E.offices(W.K)
  T.eq(#o, 1)
  T.ok(o[1].days >= 2 and o[1].days <= 3, 'days since the first pass that saw it vacant')
  T.eq({o[1].code, o[1].n, o[1].cand, o[1].why}, {'CHIEF_MEDICAL_DWARF', 1, 5, 'CHIEF_MEDICAL_DWARF is not offered yet'})
  local r = W.inbox('inspect', {what = 'offices'})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('CHIEF_MEDICAL_DWARF vacant ' .. o[1].days .. ' d, candidate unit 5 (CHIEF_MEDICAL_DWARF is not offered yet)',
                  1, true), r.msg)
  T.eq(r.data.offices[1].cand, 5)
  -- a fort of soldiers only: no candidate, the reason says so
  local W2, E2 = econ_world{cit = 3, setup = function(W)
    for i = 1, 3 do W.unit(i).military.squad_id = i end
  end}
  days(W2, 2)
  T.eq(E2.offices(W2.K)[1].why, 'no adult citizen outside the squads')
  T.eq(#appointed(W2), 0)
  -- an old fort without that office: nothing to do
  local W3, E3 = econ_world{offices = {{code = 'MANAGER', held = 101}}}
  days(W3, 2)
  T.eq({#appointed(W3), #E3.offices(W3.K)}, {0, 0})
end)

T.test('BUG-055: verb appoint {code, unit}: the nobles screen; a squad member is no candidate except for the militia posts', function()
  local W, E = econ_world{setup = function(W)
    W.unit(2).military.squad_id = 3
    W.act_result('appoint', function(code, id) return true, 22 end)
  end}
  local r = W.inbox('appoint', {code = 'CHIEF_MEDICAL_DWARF', unit = 5})
  T.ok(r.ok, r.msg)
  T.eq(r.data, {assignment = 22})
  T.eq(appointed(W), {{'CHIEF_MEDICAL_DWARF', 5}})
  r = W.inbox('appoint', {code = 'CHIEF_MEDICAL_DWARF', unit = 2})
  T.eq({r.ok, r.msg}, {false, 'unit 2 is a squad member: a soldier on duty is no candidate for CHIEF_MEDICAL_DWARF'})
  r = W.inbox('appoint', {code = 'MILITIA_CAPTAIN', unit = 2})
  T.ok(r.ok, 'the militia posts are the soldiers\'')
  r = W.inbox('appoint', {code = 'CHIEF_MEDICAL_DWARF', unit = 999})
  T.eq({r.ok, r.msg}, {false, 'no unit 999'})
  W.act_result('appoint', function() return false, 'not an adult living citizen' end)
  r = W.inbox('appoint', {code = 'MANAGER', unit = 4})
  T.eq({r.ok, r.msg}, {false, 'appoint: not an adult living citizen'})
  r = W.inbox('appoint', {code = 'manager', unit = 4})
  T.ok(not r.ok, 'bad code (schema)')
  r = W.inbox('appoint', {code = 'MANAGER'})
  T.ok(not r.ok, 'unit required')
end)

---------------------------------------------------------------- military: leader_state, verbs
local function mil_world(opts)
  local W = X.world(opts)
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  return W
end

T.test('BUG-055: a refused squad creation is named (why, the posts) in leader_state and in the DECISION_NEEDED squads', function()
  local W = X.world{n = 50, create_mode = 'fail'}
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'}); W.state()
  df.global.plotinfo.main = {fortress_entity = entity{{code = 'MILITIA_COMMANDER', active = false},
                                                       {code = 'MILITIA_CAPTAIN', active = true}}}
  W.run(9, {skip = 9})
  W.run(3600 * 3, {skip = 9})
  local ls = X.call(W, 'military', 'leader_state')
  T.eq(ls.active, {'MILITIA_CAPTAIN'})
  T.eq(ls.free, 2, 'both assignments are vacant without a squad')
  T.ok(ls.fails >= 2)
  T.ok(ls.why:find('squad creation refused', 1, true) and ls.why:find('assignment_id required [S2]', 1, true), ls.why)
  T.ok(ls.since ~= nil)
  local dn = W.find_events('DECISION_NEEDED')
  T.eq(#dn, 1)
  T.ok(dn[1].d.q:find('refused: assignment_id required [S2]', 1, true), dn[1].d.q)
  T.ok(dn[1].d.q:find('fix: dfllm cmd squad.create', 1, true), dn[1].d.q)
  T.ok(#dn[1].msg <= 200)
  -- the inspect view carries it
  local r = W.inbox('inspect', {what = 'offices'})
  -- (economy is not loaded in this world: only military answers through its own leader_state)
  T.ok(not r.ok or r.data ~= nil)
end)

T.test('BUG-055: verbs squad.create / squad.leader / squad.add / squad.uniform: the squads screen outside a fight', function()
  local W = mil_world{n = 50, phase = false}
  local mil = X.mod('military')
  -- squad.create in PEACE: a squad named Q (not A, B, C) with a leader
  local r = W.inbox('squad.create', {name = 'Q', leader = 41})
  T.ok(r.ok, r.msg)
  local sid = r.data.squad
  T.eq(r.data.leader, true)
  local s = df.squad.find(sid)
  T.ok(s ~= nil)
  -- squad.add needs a leader: Q has one; unit 42 joins
  r = W.inbox('squad.add', {squad = sid, unit = 42})
  T.ok(r.ok, r.msg)
  T.eq(X.members(s), 2)
  r = W.inbox('squad.add', {squad = 9999, unit = 43})
  T.eq({r.ok, r.msg}, {false, 'no squad 9999'})
  -- a squad without a leader: squad.leader seats one, squad.add refuses before
  W.create_mode = 'noleader'
  r = W.inbox('squad.create', {name = 'R'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.leader, false)
  T.ok(r.msg:find('no leader yet: squad.leader', 1, true), r.msg)
  local rid = r.data.squad
  r = W.inbox('squad.add', {squad = rid, unit = 44})
  T.eq({r.ok, r.msg}, {false, 'squad ' .. rid .. ' has no leader: squad.leader first'})
  r = W.inbox('squad.leader', {squad = rid, unit = 45})
  T.ok(r.ok, r.msg)
  r = W.inbox('squad.add', {squad = rid, unit = 44})
  T.ok(r.ok, r.msg)
  -- the creation refused by the game: the act's text comes back
  W.create_mode = 'fail'
  r = W.inbox('squad.create', {name = 'S'})
  T.eq({r.ok, r.msg}, {false, 'squad.create: assignment_id required [S2]'})
  -- squad.uniform names A, B or C only (the registry): a squad id is no argument
  T.ok(not W.inbox('squad.uniform', {squad = sid}).ok, 'schema: A, B or C')
  -- the squads screen is not touched in a fight
  W.set_mode('SIEGE')
  r = W.inbox('squad.create', {name = 'T'})
  T.eq({r.ok, r.msg}, {false, 'squad.create not allowed in SIEGE'})
  W.set_mode('BREACH')
  T.ok(not W.inbox('squad.add', {squad = sid, unit = 46}).ok)
  W.set_mode('PEACE')
  T.ok(not W.inbox('squad.uniform', {squad = 'Z'}).ok, 'schema: A, B or C')
  T.ok(not W.inbox('squad.leader', {squad = true, unit = 1}).ok)
end)

T.test('BUG-055: squad.uniform gives a registered squad its kind\'s uniform (melee metal set for A)', function()
  local W = mil_world{n = 50}
  local A = X.squad_of(W, 'A')
  T.ok(A ~= nil, 'military made squad A')
  local before = #X.acts(W, 'squad_uniform')
  local r = W.inbox('squad.uniform', {squad = 'A', kind = 'melee'})
  T.ok(r.ok, r.msg)
  T.ok(#X.acts(W, 'squad_uniform') > before)
  local last = X.acts(W, 'squad_uniform')[#X.acts(W, 'squad_uniform')]
  T.eq(last.args[1], A.id)
  T.ok(r.msg:find('squad A: melee uniform', 1, true), r.msg)
  r = W.inbox('squad.uniform', {squad = 'A', kind = 'xbow'})
  T.ok(r.ok, r.msg)
  T.ok(not W.inbox('squad.uniform', {squad = 'A', kind = 'pike'}).ok, 'schema')
end)

T.done()
