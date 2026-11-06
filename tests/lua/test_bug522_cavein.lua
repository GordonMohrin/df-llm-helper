-- BUG-522 (Run 16c i3 Sealcertain y385 d11: two citizens 'found dead: crushed (incident CAVEIN)', no event named a dig): the runner
-- reads, before it designates a dig chunk, the roof tile above every dug tile; a revealed FLOOR tile without a revealed WALL
-- neighbour hangs free above the new hole (cave_check 'warn' logs and records it, 'block' stops the project: cavein_risk); a CAVEIN
-- death names the digs within 12 tiles (runner.dig_near, care's DEATH d.dig).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function reset() for k, v in pairs(CFG0) do runner.CFG[k] = v end end

local function floor_over(W, x, y, z)       -- a free-hanging floor tile at x,y,z+1: floor, walls nowhere near (all revealed)
  for dy = -1, 1 do for dx = -1, 1 do
    local t = W.tile(x + dx, y + dy, z + 1)
    t.c, t.shape = '.', 'FLOOR'
  end end
end

local function world(tag, mode)
  reset()
  runner.CFG.cave_check = mode
  local W = H.world({tag = tag})
  W.load(runner)
  -- the fake snapshot gives c/dig; the roof test reads shape too (the real one returns the tiletype shape)
  local base = W.snap.tile
  W.snap.tile = function(K, x, y, z)
    local v = base(K, x, y, z)
    if v then v.shape = W.tile(x, y, z).shape or (v.c == '#' and 'WALL' or nil) end
    return v
  end
  return W
end

T.test('BUG-522: warn mode (default): a free-hanging floor above the hole is logged and recorded, the dig goes on', function()
  local W = world('c522a', 'warn')
  floor_over(W, 40, 40, 5)
  local rr = H.place(W, 'cv1', H.doc{x = 40, y = 40, z = 5, n = 1, tpl = 'bedrooms'}, {tpl = 'bedrooms', site = 'S1'})
  H.settle(W); W.frame(1); H.settle(W)
  T.ok(#H.qf_calls(W, 'dig', 'run') >= 1, 'the chunk was designated')
  local rec = W.K.persist.get('m.runner').cv.cv1
  T.ok(type(rec) == 'table' and rec.n >= 1 and rec.at:find('^40,40,6') or rec.at:find(',6$'), tostring(rec and rec.at))
  local logged = false
  for _, l in ipairs(W.logs) do if tostring(l.msg or l[3] or l):find('free-hanging floor', 1, true) then logged = true end end
  T.ok(logged, 'one warn line')
  T.eq(H.proj(W, 'cv1').blocked, '')
  local ok, l = W.K.call('runner', 'dig_near', {40, 41, 5}, 12)
  T.ok(ok and #l == 1 and l[1].proj == 'cv1' and l[1].risk ~= nil, 'dig_near names the project with its risk')
  ok, l = W.K.call('runner', 'dig_near', {200, 200, 5}, 12)
  T.eq(l, {}, 'far away: none')
  reset()
end)

T.test('BUG-522: block mode stops the project before the designation: cavein_risk; wall neighbours or an unrevealed one are no risk', function()
  local W = world('c522b', 'block')
  floor_over(W, 40, 40, 5)
  H.place(W, 'cv2', H.doc{x = 40, y = 40, z = 5, n = 1, tpl = 'bedrooms'}, {tpl = 'bedrooms', site = 'S1'})
  H.settle(W); W.frame(1); H.settle(W)
  T.eq(H.proj(W, 'cv2').blocked, 'cavein_risk')
  T.eq(#H.qf_calls(W, 'dig', 'run'), 0, 'nothing designated')
  -- a wall beside the roof tile holds it
  local W2 = world('c522c', 'block')
  floor_over(W2, 40, 40, 5)
  local w = W2.tile(41, 40, 6); w.c, w.shape = '#', 'WALL'
  H.place(W2, 'cv3', H.doc{x = 40, y = 40, z = 5, n = 1, tpl = 'bedrooms'}, {tpl = 'bedrooms', site = 'S1'})
  H.settle(W2); W2.frame(1); H.settle(W2)
  T.eq(H.proj(W2, 'cv3').blocked, '')
  T.ok(#H.qf_calls(W2, 'dig', 'run') >= 1, 'designated')
  -- an unrevealed neighbour: no verdict
  local W3 = world('c522d', 'block')
  floor_over(W3, 40, 40, 5)
  W3.tile(39, 39, 6).hidden = true
  H.place(W3, 'cv4', H.doc{x = 40, y = 40, z = 5, n = 1, tpl = 'bedrooms'}, {tpl = 'bedrooms', site = 'S1'})
  H.settle(W3); W3.frame(1); H.settle(W3)
  T.eq(H.proj(W3, 'cv4').blocked, '')
  -- off: not even read
  local W4 = world('c522e', 'off')
  floor_over(W4, 40, 40, 5)
  H.place(W4, 'cv5', H.doc{x = 40, y = 40, z = 5, n = 1, tpl = 'bedrooms'}, {tpl = 'bedrooms', site = 'S1'})
  H.settle(W4); W4.frame(1); H.settle(W4)
  T.eq(H.proj(W4, 'cv5').blocked, '')
  reset()
end)

---------------------------------------------------------------- care: the CAVEIN death names the digs near
local CW = require('care_world')
T.test('BUG-522: a CAVEIN death names the dfpilot digs within 12 tiles (d.dig and the text), or says none lies near', function()
  local incidents = {}
  local near = {}
  local W = CW.world{cit = 4, setup = function(W)
    df.incident = {find = function(id) return incidents[id] end}
    for i = 1, 4 do
      local u = W.unit(i)
      u.counters = {death_cause = -1, death_id = -1}
      u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
      u.name = {first_name = 'u' .. i, nickname = ''}
    end
    W.load({name = 'runner', every = {ticks = 600}, dig_near = function(K, pos, r) return near end})
  end}
  local function die(id)
    local u = W.unit(id)
    W.kill(id)
    u.counters.death_id = 500 + id
    incidents[500 + id] = {death_cause = df.death_type.CAVEIN, criminal = -1, flags = {discovered = true}}
    u.pos = {x = 15, y = 13, z = 141}
    W.event('UNIT_DEATH', {unit = id})
  end
  near = {{proj = 'c1a1ad01', tpl = 'hospital', stage = 0, dist = 3, risk = '15,13,142'}}
  die(1)
  W.run(1)
  local by = {}
  for _, e in ipairs(W.find_events('DEATH')) do by[e.d.unit] = e end
  T.eq(by[1].d.dtype, 'CAVEIN')
  T.eq(#by[1].d.dig, 1)
  T.ok(by[1].d.dig[1]:find('c1a1ad01 hospital s0 3t risk 15,13,142', 1, true), by[1].d.dig[1])
  T.ok(by[1].msg:find('dig near: c1a1ad01 3 tiles (free-hanging floor above)', 1, true), by[1].msg)
  near = {}
  die(2)
  W.run(1)
  by = {}
  for _, e in ipairs(W.find_events('DEATH')) do by[e.d.unit] = e end
  T.eq(by[2].d.dig, {})
  T.ok(by[2].msg:find('no dfpilot dig within 12 tiles', 1, true), by[2].msg)
  T.ok(#by[2].msg <= 200)
end)

T.done()
