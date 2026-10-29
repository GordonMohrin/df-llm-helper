-- FR-98 (Gordon's goal G16, the military clears the caverns): runner's half of the cavern sweep. A plugged explore shaft
-- (CAVERN_PLUG done: walls on its two top tiles) is opened by the `unplug` project (the top wall removed with quickfort `n`,
-- a constructed down stair and a hatch cover in its place, then the lower wall removed and an up/down stair below) and
-- walled again by a `plug` project (the stair removed, a wall; the hatch on top stays above the lower wall). While the
-- sweep runs, runner.cavern_open leaves the shaft out (readiness keeps no R0 `caverns` for a guarded opening); once no
-- sweep runs on it, it counts as open. k_mock + runner_world (fake quickfort, snapshot.tile).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local AX, AY, AZ = 40, 40, 100

local function explore_doc()
  local chunks = {}
  for w = 0, -8, -1 do
    local key = w == 0 and 'j' or (w == -8 and 'u' or 'i')
    chunks[#chunks + 1] = {pos = {AX, AY + 1, AZ + w}, cells = {{0, 0, 0, key}}}
  end
  return {v = 2, tpl = 'explore', site = 'S1', class = 'infra', params = {depth = 8, arm = 2, every = 4, avoid = ''},
          anchor = {AX, AY, AZ}, rot = 0, stages = {{label = 'dig', mode = 'dig', orders = 0, defense = 0, chunks = chunks}},
          manifest = {v = 2}, materials = {}}
end

-- a fort whose explore shaft 40,41 z100-95 broke into a cavern lake and was plugged (both walls stand, CAVERN_PLUG done)
local function plugged(tag, sweeping)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  runner.CFG.plug_wait = 4 * DAY
  require('dfllm.aqshaft').CFG.on = true
  local W = H.world{tag = tag}
  W.load(runner)
  if sweeping ~= nil then
    W.load{name = 'cavern', every = {ticks = 100}, running = function(K, id) return sweeping[id] == true end}
  end
  H.place(W, 'e1', explore_doc())
  H.runs(W, 1)
  for zz = AZ, 95, -1 do
    local t = W.tile(AX, AY + 1, zz)
    t.c, t.dig = zz == AZ and '>' or 'X', ''
  end
  for zz = 94, 95 do
    for y = 30, 52 do for x = 41, 60 do local t = W.tile(x, y, zz); t.c, t.flow, t.cav = '~', 7, true end end
  end
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 95}})
  W.frame(1)
  for _ = 1, 3 do H.runs(W, 2); H.dig(W); H.runs(W, 2); H.build(W) end
  H.runs(W, 2)
  T.eq({W.tile(AX, AY + 1, 100).c, W.tile(AX, AY + 1, 99).c}, {'C', 'C'}, 'the plug walls stand')
  T.eq(select(2, W.K.call('runner', 'cav_state', 'e1')), 'done')
  return W
end

local function cav_open(W) return (select(2, W.K.call('runner', 'cavern_open'))) end
local function work(W, n)
  for _ = 1, n or 6 do H.runs(W, 2); H.dig(W); H.runs(W, 2); H.build(W) end
  H.runs(W, 2)
end

T.test('FR-98: cav_sealed lists the plugged shaft with its two tiles and its bottom', function()
  local W = plugged('sealed')
  local ok, list = W.K.call('runner', 'cav_sealed')
  T.ok(ok)
  T.eq(#list, 1)
  T.eq({list[1].id, list[1].s0, list[1].s1, list[1].bot, list[1].st, list[1].why},
       {'e1', {40, 41, 100}, {40, 41, 99}, 95, 'done', 'cavern_lake'})
  T.eq(cav_open(W), 0)
end)

T.test('FR-98: sweep_open removes the plug walls, builds the stairs and a hatch on the top (top first)', function()
  local W = plugged('open', {})
  local ok, okr, pid = W.K.call('runner', 'sweep_open', 'e1')
  T.ok(ok and okr, tostring(pid))
  local labels = {}
  for _, st in ipairs(W.K.persist.get('bp.' .. pid).stages) do
    labels[#labels + 1] = st.label .. ':' .. st.mode .. ':' .. st.chunks[1].cells[1][4]
  end
  T.eq(labels, {'u0.rm:dig:n', 'u0.stair:build:Cd', 'u0.hatch:build:H', 'u1.rm:dig:n', 'u1.stair:build:Cx'})
  T.eq(select(2, W.K.call('runner', 'cav_state', 'e1')), 'sweep')
  T.eq(cav_open(W), 1, 'no sweep runs on it (the cavern module answers no): the shaft counts as open')
  local again = table.pack(W.K.call('runner', 'sweep_open', 'e1'))
  T.eq({again[2], again[3]}, {false, 'no plugged cavern shaft e1'}, 'only a plugged shaft opens')
  H.runs(W, 2)
  T.eq(W.tile(AX, AY + 1, 100).dig, 'n', 'the top wall is designated for removal first')
  T.eq(W.tile(AX, AY + 1, 99).dig, '', 'the lower wall waits: it closes the shaft while the top is rebuilt')
  work(W)
  T.eq({W.tile(AX, AY + 1, 100).c, W.tile(AX, AY + 1, 99).c}, {'+', 'X'}, 'a hatch over the down stair, a stair below')
  T.eq(H.proj(W, pid).done, 1)
  local okp, ps = W.K.call('runner', 'proj_state', pid)
  T.eq(ps.done, 1)
end)

T.test('FR-98: cavern_open leaves the shaft out while the sweep runs on it', function()
  local W = plugged('running', {e1 = true})
  W.K.call('runner', 'sweep_open', 'e1')
  T.eq(cav_open(W), 0)
end)

T.test('FR-98: sweep_close walls the opened shaft again: the stair removed and walled below the hatch, CAVERN_PLUG done',
       function()
  local W = plugged('close', {})
  local _, _, pid = W.K.call('runner', 'sweep_open', 'e1')
  work(W)
  local n0 = #W.find_events('CAVERN_PLUG')
  local ok, okc, plug = W.K.call('runner', 'sweep_close', 'e1')
  T.ok(ok and okc, tostring(plug))
  local labels = {}
  for _, st in ipairs(W.K.persist.get('bp.' .. plug).stages) do labels[#labels + 1] = st.label .. ':' .. st.chunks[1].cells[1][4] end
  T.eq(labels, {'p1.rm:n', 'p1.wall:Cw', 'p0.free:H', 'p0.rm:n', 'p0.wall:Cw'})
  T.eq(select(2, W.K.call('runner', 'cav_state', 'e1')), 'open', 'R0 caverns while it is walled again')
  T.eq(cav_open(W), 1)
  work(W)
  T.eq({W.tile(AX, AY + 1, 100).c, W.tile(AX, AY + 1, 99).c}, {'+', 'C'}, 'a wall below the hatch closes the shaft')
  local cp = W.find_events('CAVERN_PLUG')
  T.eq({#cp - n0, cp[#cp].d.phase}, {1, 'done'})
  T.eq({select(2, W.K.call('runner', 'cav_state', 'e1')), cav_open(W)}, {'done', 0})
  T.eq(#(select(2, W.K.call('runner', 'cav_sealed'))), 1, 'it can be swept again')
  T.ok(pid ~= plug)
end)

T.test('FR-98: sweep_close of a shaft the unplug left half done cancels it and walls what stands open', function()
  local W = plugged('half', {})
  local _, _, pid = W.K.call('runner', 'sweep_open', 'e1')
  H.runs(W, 2); H.dig(W); H.runs(W, 2)            -- the top wall is gone, nothing built yet
  T.eq(W.tile(AX, AY + 1, 100).c, '_')
  local _, _, plug = W.K.call('runner', 'sweep_close', 'e1')
  T.eq(H.proj(W, pid), nil, 'the unplug project left the list')
  local labels = {}
  for _, st in ipairs(W.K.persist.get('bp.' .. plug).stages) do labels[#labels + 1] = st.label .. ':' .. st.chunks[1].cells[1][4] end
  T.eq(labels, {'p0.free:H', 'p0.wall:Cw'}, 'the lower wall still stands: the planned stair goes, the top is walled')
  work(W)
  T.eq({W.tile(AX, AY + 1, 100).c, (select(2, W.K.call('runner', 'cav_state', 'e1')))}, {'C', 'done'})
  T.eq(W.tile(AX, AY + 1, 99).c, 'C')
end)

T.test('FR-98: a removal the unplug designated and nobody took is taken back when the shaft closes', function()
  local W = plugged('undig', {})
  W.K.call('runner', 'sweep_open', 'e1')
  H.runs(W, 2)
  T.eq(W.tile(AX, AY + 1, 100).dig, 'n')
  W.K.call('runner', 'sweep_close', 'e1')
  T.eq(W.tile(AX, AY + 1, 100).dig, '', 'the designation is undone')
  T.eq({W.tile(AX, AY + 1, 100).c, (select(2, W.K.call('runner', 'cav_state', 'e1')))}, {'C', 'done'},
       'both walls stand: nothing to wall, the record is done again')
end)

T.test('FR-99: the P6 deliverable sweep asks cavern.cleared; an absent cavern module skips it', function()
  local W = H.world{tag = 'deliver'}
  W.load(runner)
  local clr = false
  W.load{name = 'cavern', every = {ticks = 100}, cleared = function() return clr end}
  -- the deliverable check is internal: the phase list with only `sweep` in P0 advances once cleared
  W.set_plan({v = 2, year = 3, phase_target = 'P1', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'B', pop_ceiling = 100, beauty = 'none'},
              phases = {{id = 'P0', title = 't', approve = false, deliver = {{k = 'sweep'}}},
                        {id = 'P1', title = 't', approve = false, deliver = {}}}})
  H.runs(W, 2)
  T.eq(W.K.persist.get('phase').phase, 'P0', 'not cleared: P0 holds')
  clr = true
  H.runs(W, 2)
  T.eq(W.K.persist.get('phase').phase, 'P1')
end)

T.done()
