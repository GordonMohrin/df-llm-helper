-- BUG-464 / BUG-462 (Run 16a i1 Syrupobeyed y387, Pop 96 -> 1): in the BREACH that broke the outer line the alert burrow
-- Tiefe+ was refused for 'no food for 1 hungry citizen' (a dry mark, siege's relax_step) at every level: 'no confinement,
-- citizens flee on their own' while the trolls walked in. The refuge is the retreat of a BREACH and of a lost outer line: a
-- few dry citizens do not refuse it, and with every other burrow breached it takes them in whatever it lacks (REFUGE_STOCK).
-- Fixtures: tests/lua/test_seal_refuge.lua's fort (Kern+ hall, door at the entrance, the dead end Tiefe+ behind a stair).
local T = require('testlib')
local SW = require('seal_world')

local function evs(W, t) return W.find_events(t) end
local function inspect(W, what, key)
  local r = W.inbox('inspect', {what = what, key = key})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end

---------------------------------------------------------------- the fort
-- surface z 10: a field x0-40 y0-30 (outside, it reaches the map edge) with a down stair at 20,10. Fort z 9: the hall
-- x5-15 y5-15 (Kern+: the citizens, 2 beds, drink, food), a corridor y10 x16-19 to the up stair 20,10 (the entrance;
-- opts.door: a door at 19,10 right behind it). opts.shaft (default): a down stair at 6,6 in the hall, a shaft z6-8 and a
-- room x5-8 y5-8 on z5: the dead end behind the stair (19 tiles)
local Z = 9
local function fort(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = opts.man or {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  SW.fill(W, Z + 1, 0, 0, 40, 30, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 30, '#')
  SW.fill(W, Z, 5, 5, 15, 15, '.')
  SW.fill(W, Z, 16, 10, 19, 10, '.')
  SW.draw(W, Z, {'<'}, 20, 10)
  if opts.door then SW.draw(W, Z, {'+'}, 19, 10) end
  SW.draw(W, Z, {'bb'}, 12, 12)
  if opts.bed3 then SW.draw(W, Z, {'b'}, 17, 10) end           -- a third bed in the corridor (outside Kern+)
  if opts.shaft ~= false then
    SW.draw(W, Z, {'>'}, 6, 6)
    for z = Z - 3, Z - 1 do
      SW.fill(W, z, 0, 0, 40, 30, '#')
      SW.draw(W, z, {'X'}, 6, 6)
    end
    SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
    SW.fill(W, Z - 4, 5, 5, 8, 8, '.')
    SW.draw(W, Z - 4, {'<'}, 6, 6)
  end
  SW.regroup(W)
  local cits = {}
  for i = 1, opts.citizens or 3 do cits[i] = {i, 8 + i % 6, 9 + i // 6, Z} end
  SW.citizens(W, cits)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
  if opts.cfg then W.K.cfg.reflex = {v = 2, refuge = opts.cfg} end
  if opts.well then SW.draw(W, Z - 4, {'W'}, 7, 7) end          -- BUG-040: a well in the dead end (a dry cistern's)
  for _, m in ipairs(opts.mods or {}) do W.load(m) end
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  W.load(M)
  W.run(opts.settle or 2400, {skip = 9})
  return W, M
end

local HOSTILE_IN = {{id = 300, x = 10, y = 12, z = Z}}
local function hostile_inside(W)
  W.set_census('h', {tick = W.K.now().tick, vis = 1, armed = 1, inside = 1, list = HOSTILE_IN})
end

-- Tiefe+ with its drink (WET) and no food, one hungry citizen marked dry in it
local function dry_refuge(W, n, need)
  SW.item(W, 'DRINK', 6, 7, Z - 4, 5)
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  local ok, marked = W.K.call('seal', 'dry', 'Tiefe+', need or {food = true}, n or 1)
  T.ok(marked, 'Tiefe+ is marked dry (no food in it)')
end

T.test('BUG-464: BREACH, Tiefe+ marked dry for ONE hungry citizen, Kern+ breached: the refuge takes them in (old: no pick, ' ..
       '"no food for 1 hungry citizen", the citizens flee), REFUGE_STOCK names the missing food', function()
  local W = fort{door = true}
  dry_refuge(W, 1)
  W.set_mode('BREACH')
  hostile_inside(W)
  local ok, pick, note, short, flee = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq({ok, pick, flee}, {true, 'Tiefe+', false}, tostring(note))
  local s = evs(W, 'REFUGE_STOCK')
  T.eq(#s, 1)
  T.eq({s[1].d.burrow, s[1].d.short, s[1].d.fight}, {'Tiefe+', 'food', 1})
  T.ok(s[1].msg:find('took the citizens in short of food', 1, true), s[1].msg)
  ok, pick = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq(#evs(W, 'REFUGE_STOCK'), 1, 'asked once per game day')
end)

T.test('BUG-464: the outer line lost: the citizens held in the refuge are not sent out for a few dry citizens (old: ' ..
       'REFUGE_SWITCH dry to Kern+ or to none); a big mark (30 citizens) still is; without the loss a BREACH sends them to the closed Kern+', function()
  local W = fort{door = true}
  dry_refuge(W, 2)
  W.set_mode('BREACH')
  local ok0, pick0 = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+', false, 'Tiefe+')
  T.eq(pick0, 'Kern+', 'no loss, Kern+ closed: the dry refuge is left as before (test_stranded)')
  local nsw = #evs(W, 'REFUGE_SWITCH')
  W.K.call('seal', 'lost', 'O1')
  local ok, pick, note, short, flee = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+', false, 'Tiefe+')
  T.eq({ok, pick, flee}, {true, 'Tiefe+', false}, tostring(note))
  T.eq(#evs(W, 'REFUGE_SWITCH'), nsw, 'kept, no switch')
  -- the same mark for 30 citizens is a real dryness: Kern+ (a hall with its stock) takes them
  W.K.call('seal', 'dry', 'Tiefe+', {food = true}, 30)
  ok, pick, note = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+', false, 'Tiefe+')
  T.eq(pick, 'Kern+', tostring(note))
end)

T.test('BUG-464: last resort: Kern+ breached, the refuge marked dry for 40 citizens and short of everything: it still takes ' ..
       'them in inside the breach days (old: no confinement, flee); a hostile in the refuge itself or the spent breach days refuse it', function()
  local W = fort{door = true}
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  local ok, marked = W.K.call('seal', 'dry', 'Tiefe+', {food = true, drink = true}, 40)
  T.ok(marked, 'Tiefe+ holds neither drink nor food')
  W.set_mode('BREACH')
  hostile_inside(W)
  local _, pick, note, short, flee = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq({pick, flee}, {'Tiefe+', false}, tostring(note))
  local rf = evs(W, 'REFUGE_FAIL')
  T.ok(#rf >= 1 and rf[#rf].d.fallback == 'Tiefe+', 'REFUGE_FAIL names the pick: ' .. T.show(rf[#rf] and rf[#rf].d))
  local f = evs(W, 'REFUGE_STOCK')
  T.eq(#f >= 1 and f[1].d.fight, 1)
  -- without a BREACH/lost line the old rule stands: a SIEGE ask is still refused for the dry mark
  W.set_mode('SIEGE')
  W.set_census('h', {tick = W.K.now().tick, vis = 0, armed = 0, inside = 0, list = {}})
  local _, p2, _, _, fl2 = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.ok(p2 ~= 'Tiefe+', 'SIEGE keeps the dry refuge refused')
end)

T.test('BUG-462: seal.lost (an outer or inner bridge destroyed) makes the refuge the retreat of the episode even in a ' ..
       'SIEGE ask; it is news once, persists, and ends with the episode', function()
  local W = fort{door = true}
  dry_refuge(W, 1)
  W.set_mode('SIEGE')
  hostile_inside(W)
  local _, pick0 = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.ok(pick0 ~= 'Tiefe+', 'before the loss a SIEGE ask does not take the dry refuge (' .. tostring(pick0) .. ')')
  local ok, fresh = W.K.call('seal', 'lost', 'O1')
  T.eq({ok, fresh}, {true, true})
  ok, fresh = W.K.call('seal', 'lost', 'B2')
  T.eq({ok, fresh}, {true, false}, 'news once')
  W.set_census('h', {tick = W.K.now().tick, vis = 1, armed = 1, inside = 1, list = HOSTILE_IN})
  local _, pick = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq(pick, 'Tiefe+')
  T.eq(inspect(W, 'refuge').lostb, nil, 'not in the audit state')
  W.set_mode('PEACE')
  W.run(2400, {skip = 9})
  local _, fresh2 = W.K.call('seal', 'lost', 'O1')
  T.eq(fresh2, false, 'PEACE: no episode, nothing to retreat from')
end)

T.done()
