-- WP6 on the REAL kernel (kern.lua + act.lua): squad creation through the real act.squad_create
-- (makeSquad on the vacant MILITIA_COMMANDER assignment, no leader appointment yet [S2]),
-- the pop cap through the real act.popcap -> pop-control, and uniform-unstick through the allowlist.
local T = require('testlib')
local H = require('kern_world')
local S = require('siege_world')
local X = require('wp6_world')
local json = require('dfllm.util.json')

local REPO = (arg and arg[0] or ''):match('^(.*)/tests/lua/[^/]+$') or '.'

local function boot(tag, setup)
  local W = H.world{tag = tag, units = X.citizens(50, 1, {skills = {AXE = 6, SHIELD = 3}}),
                    persist = {manifest = S.manifest()}, ms_per_frame = 50}
  S.install(W, {})
  X.install(W, {})
  X.real_act(W)
  if setup then setup(W) end
  local mods = {}
  for _, n in ipairs({'sense', 'gate', 'military', 'readiness'}) do
    package.loaded['dfllm.' .. n] = nil
    mods[#mods + 1] = require('dfllm.' .. n)
  end
  mods[#mods + 1] = X.economy()
  local ok, msg = H.boot(W, {repo = REPO, modules = mods})
  assert(ok, msg)
  return W, H.kern().K()
end

local function cmds(W, fn)
  local r = {}
  for _, l in ipairs(H.lines(W.sd .. '/commands.log')) do
    local c = {}
    for f in (l .. '\t'):gmatch('([^\t]*)\t') do c[#c + 1] = f end
    if c[4] == 'act.' .. fn then r[#r + 1] = c end
  end
  return r
end

T.test('real act: squad A from the vacant commander assignment, no leader -> not filled, B and C wait', function()
  local W, K = boot('create')
  H.run(W, 20, {skip = 9})
  H.run(W, 40, {paused = true})                         -- logs reach the files within 1 s
  local A = X.squad_of(W, 'A')
  T.ok(A ~= nil, 'makeSquad(10) + alias A')
  T.eq(X.members(A), 0, 'act.squad_create does not seat the leader yet [S2]')
  T.eq(#cmds(W, 'squad_add'), 0, 'military never adds to a leaderless squad')
  local creates = cmds(W, 'squad_create')
  T.eq(#creates, 1, 'no more squads while the one dfllm made has no leader')
  T.eq(creates[1][6], 'ok')
  T.eq(#cmds(W, 'squad_uniform'), 0, 'an empty squad needs no uniform yet')
  local dn = H.find(H.events(W), 'DECISION_NEEDED')
  T.eq(#dn, 1)
  T.eq(dn[1].d.id, 'squads')
  T.ok(dn[1].msg:find('militia commander', 1, true) and dn[1].msg:find('squad A', 1, true), dn[1].msg)
  T.ok(dn[1].d.q:find('create squads named B (melee), C (crossbows)', 1, true), dn[1].d.q)
  H.kern().stop('test')
  local p = json.decode(W.persist_raw['dfllm.m.military'])
  T.eq(p.sq.A.id, A.id)
  T.eq(p.sq.A.auto, 1)
  T.eq(p.sq.B, nil)
end)

T.test('real act: a UI squad A with a leader, made after dfllm\'s leaderless A, is adopted and filled', function()
  local W, K = boot('switch')
  H.run(W, 20, {skip = 9})
  local auto = X.squad_of(W, 'A')
  T.ok(auto ~= nil and X.members(auto) == 0, 'dfllm made squad A without a leader')
  local ui = X.new_squad(W, 'A')                        -- Gordon: squad screen, leader seated
  X.seat(W, ui, 0, 30)
  X.set_uniform(ui, package.loaded['dfllm.military'].UNIFORM.melee)
  H.run(W, 3600 * 3, {skip = 9})
  H.run(W, 40, {paused = true})
  T.eq(X.members(ui), 3, 'filled to target A = 3 through addToSquad')
  T.eq(X.members(auto), 0)
  T.eq(#cmds(W, 'squad_add'), 2)
  local s = H.state(W)
  T.eq(s.mil.soldiers, 3)
  H.kern().stop('test')
  T.eq(json.decode(W.persist_raw['dfllm.m.military']).sq.A.id, ui.id)
end)

T.test('real act: popcap runs pop-control set max-pop; squads from the UI are filled via addToSquad', function()
  local W, K = boot('fill', function(W)
    local M = package.loaded['dfllm.military'] or require('dfllm.military')
    for i, sp in ipairs({{key = 'A', kind = 'melee'}, {key = 'B', kind = 'melee'}, {key = 'C', kind = 'xbow'}}) do
      local s = X.new_squad(W, sp.key)
      X.seat(W, s, 0, 20 + i)
      X.set_uniform(s, M.UNIFORM[sp.kind])
    end
  end)
  H.run(W, 20, {skip = 9})
  H.run(W, 40, {paused = true})                         -- logs reach the files within 1 s
  T.eq(#cmds(W, 'squad_add'), 5)
  T.eq(X.members(X.squad_of(W, 'A')) + X.members(X.squad_of(W, 'B')) + X.members(X.squad_of(W, 'C')), 8)
  local found = false
  for _, c in ipairs(W.commands) do
    if c[1] == 'pop-control' and c[2] == 'set' and c[3] == 'max-pop' and c[4] == '55' then found = true end
  end
  T.ok(found, 'pop-control set max-pop 55')
  T.eq(df.global.d_init.dwarf.population_cap, 55)
  H.run(W, 3700, {skip = 9})                            -- the next upkeep: uniform-unstick (allowlisted)
  local un = false
  for _, c in ipairs(W.commands) do
    if c[1] == 'uniform-unstick' and c[2] == '--all' and c[3] == '--drop' and c[4] == '--free' then un = true end
  end
  T.ok(un, 'uniform-unstick --all --drop --free ran through act.run')
  H.run(W, 40, {paused = true})
  for _, e in ipairs(H.events(W)) do T.ok(e.type ~= 'ACT_FAIL' and e.type ~= 'KERN_FAULT', e.msg) end
  local s = H.state(W)
  T.eq(s.mil.soldiers, 8)
  T.eq(s.pop.cap, 55)
  H.kern().stop('test')
end)

T.done()
