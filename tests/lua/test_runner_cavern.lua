-- Run 11 (Kilrudrabed site98): the explore shaft 136,73 broke into a cavern lake on z127 (1146 visible water tiles) and
-- BREACH_STOP said 'damp'. A breach is held against the revealed tiles (cavern lake / open cavern / seepage), and an
-- explore shaft open to a cavern is plugged at once: a constructed wall on its two top stair tiles (each channelled
-- first: walls cannot stand on stairs), CAVERN_PLUG (A) names the shaft and the plug, readiness keeps R0 `caverns`
-- (runner.cavern_open) until the top wall stands. k_mock + runner_world (fake quickfort, snapshot.tile/liquids).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(opts)
  W.load(runner)
  return W
end
local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function plug_proj(W)
  for _, P in ipairs(W.K.persist.get('projects').list) do if P.tpl == 'plug' then return P end end
end
local function cav_open(W) return (select(2, W.K.call('runner', 'cavern_open'))) end

-- the explore template as bp.emit writes it (rot 0, anchor 40,40,100, depth 8, arm 2, every 4): j at 40,41,100, i down
-- to z93, u at z92, W/E/S arms of 2 tiles at z96 and z92; one chunk per level
local AX, AY, AZ = 40, 40, 100
local function explore_doc()
  local chunks = {}
  for w = 0, -8, -1 do
    local key = w == 0 and 'j' or (w == -8 and 'u' or 'i')
    local cells = {{0, 0, 0, key}}
    local x0 = AX
    if w == -4 or w == -8 then
      x0 = AX - 2
      cells = {{0, 0, 0, 'd(2x1)'}, {2, 0, 0, key}, {3, 0, 0, 'd(2x1)'}, {2, 1, 0, 'd'}, {2, 2, 0, 'd'}}
    end
    chunks[#chunks + 1] = {pos = {x0, AY + 1, AZ + w}, cells = cells}
  end
  return {v = 2, tpl = 'explore', site = 'S1', class = 'infra', params = {depth = 8, arm = 2, every = 4, avoid = ''},
          anchor = {AX, AY, AZ}, rot = 0, stages = {{label = 'dig', mode = 'dig', orders = 0, defense = 0, chunks = chunks}},
          manifest = {v = 2}, materials = {}}
end

-- the miners dug the shaft from the core level down to z (stairs, no designation left there)
local function dug_to(W, z)
  for zz = AZ, z, -1 do
    local t = W.tile(AX, AY + 1, zz)
    t.c, t.dig = zz == AZ and '>' or 'X', ''
  end
end

-- a revealed cavern lake east of the shaft on levels z and z - 1 (x 41-60, y 30-52), cavern tiles (feature_global);
-- cav false: no cavern flag; outside: under the open sky (a surface river)
local function lake(W, z, cav, outside)
  for zz = z - 1, z do
    for y = 30, 52 do
      for x = 41, 60 do
        local t = W.tile(x, y, zz)
        t.c, t.flow, t.cav, t.outside = '~', 7, cav ~= false, outside
      end
    end
  end
end

T.test('a damp report beside a revealed cavern lake is a cavern lake: BREACH_STOP names it, the shaft gets a plug', function()
  local W = fresh{tag = 'lake'}
  H.place(W, 'e1', explore_doc())
  H.runs(W, 1)
  dug_to(W, 95)
  W.tile(AX, AY + 1, 95).c = '~'                  -- the shaft bottom flooded from the lake beside it
  lake(W, 95)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'Damp stone located', pos = {x = AX, y = AY + 1, z = 95}})
  W.frame(1)
  T.eq(H.proj(W, 'e1').blocked, 'breach:cavern_lake')
  local ev = W.find_events('BREACH_STOP')
  T.eq(#ev, 1)
  T.eq({ev[1].d.why, ev[1].d.was, ev[1].d.src}, {'cavern_lake', 'damp', 'report'})
  T.eq(ev[1].d.n, 12 * 23 * 2, 'the lake tiles within lake_r (x 41-52) on both levels, not the own shaft tile')
  T.ok(ev[1].msg:find('cavern lake (report, not damp: 552 water tiles in reach)', 1, true), ev[1].msg)
  local cp = W.find_events('CAVERN_PLUG')
  T.eq(#cp, 1)
  T.eq(cp[1].cls, 'A')
  local d = cp[1].d
  T.eq({d.phase, d.proj, d.why, d.shaft, d.z1, d.walls}, {'queued', 'e1', 'cavern_lake', {40, 41, 100}, 95,
                                                          {'40,41,99', '40,41,100'}})
  T.ok(cp[1].msg:find('the shaft 40,41 z100-95 opens into a cavern lake at 40,41,95; plug ' .. d.plug, 1, true), cp[1].msg)
  local P = plug_proj(W)
  T.eq({P.id, P.prio, P.class, P.blocked}, {d.plug, 1, 'defense', ''})
  local labels = {}
  for _, st in ipairs(W.K.persist.get('bp.' .. P.id).stages) do labels[#labels + 1] = st.label .. ':' .. st.mode end
  T.eq(labels, {'p1.dig:dig', 'p1.wall:build', 'p0.dig:dig', 'p0.wall:build'})
  T.eq(cav_open(W), 1)
  T.eq(select(3, W.K.call('runner', 'cavern_open')), {{40, 41, 100, 95}})
end)

T.test('the plug: the lower stair channelled and walled first, then the top one; CAVERN_PLUG done, cavern_open 0', function()
  local W = fresh{tag = 'plugrun'}
  runner.CFG.plug_wait = 4 * DAY
  H.place(W, 'e1', explore_doc())
  H.runs(W, 1)
  dug_to(W, 95)
  lake(W, 95)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 95}})
  W.frame(1)
  local id = plug_proj(W).id
  H.runs(W, 2)                                    -- the explore's undo, then the plug's first channel
  T.eq(W.tile(AX, AY + 1, 99).dig, 'h', 'S1 designated for a channel')
  T.eq(W.tile(AX, AY + 1, 100).dig, '', 'the top tile waits: the miner reaches S1 through it')
  T.eq(W.tile(AX, AY + 1, 94).dig, '', 'the explore designations below are undone')
  H.dig(W)
  T.eq(W.tile(AX, AY + 1, 99).c, '_')
  H.runs(W, 2)
  local walls = 0
  for _, b in pairs(W.buildings) do if b._key == 'Cw' then walls = walls + 1; T.eq(b._pos, {AX, AY + 1, 99}) end end
  T.eq(walls, 1, 'a constructed wall on the open space of S1')
  H.build(W)
  T.eq(W.tile(AX, AY + 1, 99).c, 'C')
  H.runs(W, 2)
  T.eq(W.tile(AX, AY + 1, 100).dig, 'h', 'then the top stair is channelled (from the core floor beside it)')
  H.dig(W)
  H.runs(W, 2)
  H.build(W)
  H.runs(W, 2)
  T.eq(W.tile(AX, AY + 1, 100).c, 'C')
  T.eq(H.proj(W, id).done, 1)
  local cp = W.find_events('CAVERN_PLUG')
  T.eq({#cp, cp[2].d.phase}, {2, 'done'})
  T.ok(cp[2].msg:find('constructed wall on 40,41,100 and on 40,41,99; the shaft to the cavern lake is closed', 1, true),
       cp[2].msg)
  T.eq(cav_open(W), 0)
  H.runs(W, 5)
  T.eq(#W.find_events('CAVERN_PLUG'), 2, 'once')
end)

T.test('the lower wall is given up after plug_wait (DF never reached it); quickfort refusing the top one fails', function()
  local W = fresh{tag = 'plugwait'}
  H.place(W, 'e1', explore_doc())
  H.runs(W, 1)
  dug_to(W, 95)
  lake(W, 95)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 95}})
  W.frame(1)
  local id = plug_proj(W).id
  H.runs(W, runner.CFG.plug_wait // 600 + 2)      -- nobody channels S1
  T.eq(W.tile(AX, AY + 1, 99).dig, '', 'its designation undone')
  T.ok(logged(W, 'warn', '^' .. id .. ': lower wall %(p1.dig%) given up: not done within 1 day'))
  T.eq(W.tile(AX, AY + 1, 100).dig, 'h')
  H.dig(W)
  H.runs(W, 2)
  H.build(W)
  H.runs(W, 2)
  local cp = W.find_events('CAVERN_PLUG')
  T.eq(cp[#cp].d.phase, 'done')
  T.ok(cp[#cp].msg:find('on 40,41,100; no wall below it (not done within 1 day)', 1, true), cp[#cp].msg)
  -- a second fort: quickfort refuses both channels (the stair takes none): the plug fails at once, R0 stays
  local W2 = fresh{tag = 'plugrefuse'}
  H.place(W2, 'e1', explore_doc())
  H.runs(W2, 1)
  dug_to(W2, 95)
  lake(W2, 95)
  W2.no_channel = {['40,41,99'] = true, ['40,41,100'] = true}
  W2.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 95}})
  W2.frame(1)
  H.runs(W2, 3)
  local P = plug_proj(W2)
  T.eq(P.blocked, 'plug_refused')
  local fail = W2.find_events('CAVERN_PLUG')
  T.eq({#fail, fail[2].d.phase, fail[2].d.hint}, {2, 'failed', 'refused p0.dig'})
  T.ok(fail[2].msg:find('quickfort refused p0.dig at 40,41,100: build a constructed wall there by hand', 1, true),
       fail[2].msg)
  T.eq(cav_open(W2), 1, 'R0 until a wall stands')
  W2.tile(AX, AY + 1, 100).c = 'C'                -- the player walled it by hand
  H.runs(W2, 1)
  T.eq({W2.find_events('CAVERN_PLUG')[3].d.phase, cav_open(W2)}, {'done', 0})
end)

T.test('seepage stays damp: water only in the own shaft, no cavern tile -> BREACH_STOP damp, no plug, also later', function()
  local W = fresh{tag = 'seep'}
  H.place(W, 'e1', explore_doc())
  H.runs(W, 1)
  dug_to(W, 95)
  W.tile(AX, AY + 1, 95).c = '~'                  -- 7/7 from a light aquifer: our own tile
  W.tile(AX, AY + 1, 96).c = '~'
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 95}})
  W.frame(1)
  local ev = W.find_events('BREACH_STOP')
  T.eq(ev[1].d, {proj = 'e1', why = 'damp', pos = {40, 41, 95}, src = 'report'})
  T.eq(ev[1].msg, 'e1: damp (report), digging stopped')
  H.runs(W, 6)                                    -- rechecks: still nothing but our own water
  T.eq({H.proj(W, 'e1').blocked, #W.find_events('BREACH_STOP'), #W.find_events('CAVERN_PLUG')}, {'breach:damp', 1, 0})
  T.eq(cav_open(W), 0)
  -- a big body of water under the open sky without a cavern tile (a river): water, still no plug
  lake(W, 95, false, true)
  H.runs(W, 3)
  T.eq({H.proj(W, 'e1').blocked, #W.find_events('CAVERN_PLUG')}, {'breach:damp', 0})
end)

T.test('an underground lake without the cavern flag is a cavern lake too (no water under the open sky)', function()
  local W = fresh{tag = 'lakenocav'}
  H.place(W, 'e1', explore_doc())
  H.runs(W, 1)
  dug_to(W, 95)
  lake(W, 95, false)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 95}})
  W.frame(1)
  T.eq({H.proj(W, 'e1').blocked, W.find_events('CAVERN_PLUG')[1].d.phase}, {'breach:cavern_lake', 'queued'})
end)

T.test('recheck (the live Run 11 shaft): a damp stop from before, the lake beside its bottom now shows -> plugged', function()
  local W = fresh{tag = 'recheck'}
  H.place(W, 'e1', explore_doc())
  H.runs(W, 1)
  dug_to(W, 95)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 96}})
  W.frame(1)
  T.eq(H.proj(W, 'e1').blocked, 'breach:damp')    -- nothing visible yet: damp is right
  H.runs(W, 1)
  W.K.persist.get('m.runner').br.e1 = nil          -- as the old code left it: no breach record
  W.tile(AX, AY + 1, 95).c = '~'                  -- the lake broke into the shaft bottom
  lake(W, 95)
  H.runs(W, 1)
  T.eq(H.proj(W, 'e1').blocked, 'breach:cavern_lake')
  local ev = W.find_events('BREACH_STOP')
  T.eq({#ev, ev[2].d.why, ev[2].d.was, ev[2].d.src, ev[2].d.pos}, {2, 'cavern_lake', 'damp', 'recheck', {40, 41, 95}})
  local cp = W.find_events('CAVERN_PLUG')
  T.eq({#cp, cp[1].d.phase, cp[1].d.walls}, {1, 'queued', {'40,41,99', '40,41,100'}})
  T.eq(cav_open(W), 1)
  H.runs(W, 4)
  T.eq(#W.find_events('CAVERN_PLUG'), 1, 'one plug per project')
end)

T.test('an open cavern (no water): FEATURE_DISCOVERY beside the bottom plugs; a probe in a dry room: none (by hand)', function()
  local W = fresh{tag = 'cave'}
  runner.CFG.active = 4
  H.place(W, 'e1', explore_doc())
  H.place(W, 'r1', H.dig_doc(2, {x = 80, y = 80, tpl = 'bedrooms', class = 'living'}))
  H.runs(W, 1)
  dug_to(W, 97)
  for x = 41, 44 do W.tile(x, AY + 1, 97).c, W.tile(x, AY + 1, 97).cav = '.', true end   -- cavern floor beside it
  W.event('REPORT', {type = 'FEATURE_DISCOVERY', text = 'You have discovered an expansive cavern deep underground.',
                     pos = {x = AX + 1, y = AY + 1, z = 97}})
  W.frame(1)
  T.eq(H.proj(W, 'e1').blocked, 'breach:cavern')
  T.eq(W.find_events('CAVERN_PLUG')[1].d.walls, {'40,41,99', '40,41,100'})
  -- a room dig hits revealed lake water (the probe): cavern lake, but its stairs may be the fort's own: by hand
  H.runs(W, 1)
  for y = 70, 79 do for x = 78, 92 do local t = W.tile(x, y, 100); t.c, t.cav = '~', true end end
  W.tile(81, 80, 100).c = '~'
  H.runs(W, 1)
  T.eq(H.proj(W, 'r1').blocked, 'breach:cavern_lake')
  local none = W.find_events('CAVERN_PLUG')[2]
  T.eq({none.d.phase, none.d.proj, none.d.plug, none.d.hint}, {'none', 'r1', '', 'no automatic plug for bedrooms'})
  T.ok(none.msg:find('r1 (bedrooms): cavern lake at 81,80,100; no automatic plug for bedrooms: wall the way in by hand',
                     1, true), none.msg)
  T.eq(cav_open(W), 1, 'only the explore shaft counts here (the audit sees the room)')
end)

T.test('the plug runs in every mode and no hazard stops it (damp report, water on its tile)', function()
  local W = fresh{tag = 'plugsiege'}
  runner.CFG.plug_wait = 4 * DAY
  H.place(W, 'e1', explore_doc())
  H.runs(W, 1)
  dug_to(W, 95)
  lake(W, 95)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 95}})
  W.frame(1)
  local P = plug_proj(W)
  W.set_mode('SIEGE')
  H.runs(W, 2)
  T.eq(W.tile(AX, AY + 1, 99).dig, 'h', 'worked in SIEGE')
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 99}})
  W.frame(1)
  T.eq(P.blocked, '')
  H.dig(W)
  W.tile(AX, AY + 1, 99).flow = 3                  -- a little water on the channelled tile
  H.runs(W, 2)
  T.eq(P.blocked, '')
  T.eq(#W.find_events('BREACH_STOP'), 1)
  T.eq(P.stage, 1, 'p1.wall')
end)

T.test('damp_dig (light aquifer, live L6) keeps working: seepage <= seep_max digs on, a damp report re-designates', function()
  local W = fresh{tag = 'dampdig'}
  runner.CFG.damp_dig = true
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 2)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = 12, y = 10, z = 100}})
  W.frame(1)
  T.eq(H.proj(W, 'c1').blocked, '', 'a damp report is no stop on a light aquifer site')
  W.tile(11, 10, 100).dig = ''                    -- DF cancelled the damp stone: designated again
  H.runs(W, 1)
  T.eq(W.tile(11, 10, 100).dig, 'd')
  T.ok(logged(W, 'warn', 'damp stone at 11,10,100 designated again %(light aquifer, 1/6%)'))
  H.dig(W)
  W.tile(12, 11, 100).c = 'w'                     -- 2/7 seepage on a dug tile
  H.runs(W, 2)
  T.eq({H.proj(W, 'c1').done, #W.find_events('BREACH_STOP')}, {1, 0})
  -- deep water stops, and a lake beside the report is a cavern even on a light aquifer site
  H.place(W, 'c2', H.dig_doc(2, {x = 40}))
  H.runs(W, 2)
  for y = 5, 16 do for x = 45, 60 do local t = W.tile(x, y, 100); t.c, t.cav = '~', true end end
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = 44, y = 11, z = 100}})
  W.frame(1)
  T.eq(H.proj(W, 'c2').blocked, 'breach:cavern_lake')
end)

T.done()
