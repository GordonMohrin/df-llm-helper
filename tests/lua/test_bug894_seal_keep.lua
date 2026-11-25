-- NEU14 BUG-894 (Run 17d i4 Girderroots y437-y460: three seal projects for 98,86,143 'set aside' for 186 / 333 / 714 days beside 'PERIMETER OPEN 625 days': idle_keep
-- exempted a seal only in SIEGE / BREACH, so in PEACE it lost its slot after 30 days; a new seal on the same tile adopted the planned wall, was cancelled after 3 days,
-- and the player placed it again).
-- (1) a seal or plug is never set aside while the perimeter is open, in any mode; (2) bp.place of a seal whose wall cells another seal project plans already is refused with
-- 'already planned by project X, job Y, state Z'; (3) the runner names the tiles of its seals for the economy (seal_tiles).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local Z = 129
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world(tag, mode, perim)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}, mode = mode}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, 94, 88, Z, 100, 96)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          build_state = function(K, x, y, z)
            local id = W.bld_at[x .. ',' .. y .. ',' .. z]
            if not id then return {none = true, line = 'nothing stands'} end
            return {job = 1733178, susp = false, work = false, items = 1, line = 'job 1733178 not suspended, no builder has taken it'}
          end})
  if perim then W.load({name = 'readiness', every = {ticks = 100000}, perim_open = function() return perim, '1 way in' end}) end
  return W
end

local function seal_doc(x, y)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = x .. ',' .. y .. ',129 floor', close = 'wall'},
          anchor = {x, y, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1, chunks = {{pos = {x, y, Z}, cells = {{0, 0, 0, 'Cw'}}}}}},
          manifest = {v = 2}, materials = {wall = 1}}
end
local function row(W, id) for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end end

T.test('BUG-894: a seal with no progress is set aside after idle_days in PEACE when the perimeter is closed (as before)', function()
  local W = world('keep0')
  W.load(runner)
  H.place(W, 'sa', seal_doc(97, 92))
  for _ = 1, 2 * 40 do H.runs(W, 1) end
  local r = row(W, 'sa')
  T.ok(r and r[4]:find('set aside', 1, true), T.show(r))
end)

T.test('BUG-894: the same seal while the perimeter stands open (readiness.perim_open) is never set aside, 60 days in PEACE', function()
  local W = world('keep1', nil, 40)
  W.load(runner)
  H.place(W, 'sa', seal_doc(97, 92))
  for _ = 1, 2 * 60 do H.runs(W, 1) end
  local r = row(W, 'sa')
  T.ok(r and not r[4]:find('set aside', 1, true), T.show(r))
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do T.ok(not e.d.idle, 'no set-aside event: ' .. tostring(e.msg)) end
end)

T.test('BUG-894: a seal already set aside comes back once the perimeter is reported open', function()
  local W = world('keep2')
  W.load(runner)
  H.place(W, 'sa', seal_doc(97, 92))
  for _ = 1, 2 * 40 do H.runs(W, 1) end
  T.ok(row(W, 'sa')[4]:find('set aside', 1, true))
  W.load({name = 'readiness', every = {ticks = 100000}, perim_open = function() return 41, '1 way in' end})
  H.runs(W, 2)
  T.ok(not row(W, 'sa')[4]:find('set aside', 1, true), T.show(row(W, 'sa')))
end)

T.test('BUG-894: runner.seal_tiles names the tiles of the open seal projects (set x,y,z); a done or cancelled one has none', function()
  local W = world('keep3')
  W.load(runner)
  H.place(W, 'sa', seal_doc(97, 92))
  local ok, set = W.K.call('runner', 'seal_tiles')
  T.ok(ok)
  T.eq(set, {['97,92,129'] = true})
end)

T.test('BUG-894: bp.place of a seal on a wall another seal plans already is refused with project, job and state; another tile is queued; no copy to cancel later', function()
  local W = world('dup0')
  W.load(runner)
  local r1 = H.place(W, 'sa', seal_doc(97, 92))
  T.ok(r1.ok, T.show(r1))
  H.runs(W, 4)
  T.ok(W.bld_at['97,92,129'], 'the wall is planned')
  local r2 = H.place(W, 'sb', seal_doc(97, 92))
  T.ok(not r2.ok, 'refused: ' .. T.show(r2))
  local msg = tostring(r2.msg or r2.err or r2.text or '')
  T.ok(msg:find('already planned by project sa (seal), job 1733178, state no builder', 1, true), msg)
  T.eq(H.proj(W, 'sb'), nil, 'no second project')
  local r3 = H.place(W, 'sc', seal_doc(95, 90))
  T.ok(r3.ok, T.show(r3))
end)

T.test('BUG-894: the same seal after the first one is done (the wall stands) is not the refused case; a hatch stage does not count', function()
  local W = world('dup1')
  W.load(runner)
  H.place(W, 'sa', seal_doc(97, 92))
  H.runs(W, 4)
  H.build(W)
  H.runs(W, 2)
  local r2 = H.place(W, 'sb', seal_doc(97, 92))
  local msg = tostring(r2.msg or r2.err or r2.text or '')
  T.ok(not msg:find('already planned', 1, true), msg)
end)

T.done()
