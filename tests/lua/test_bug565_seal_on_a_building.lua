-- BUG-565 (Run 16c i3 Sealcertain y405, kern.log c1a1af372f2465d901): `bp.place seal at=55,132,137 close=wall` behind the hatch on the
-- stair head 54,132,137. quickfort 'created no manager orders', the stage read the building already on the tile as the project's own
-- piece ("tracked like ours", pre_occupied), 'built nothing for 0 days ... 0 pieces open', PROJECT_STAGE 100 %, PROJECT_DONE. The audit
-- bypass stayed and nothing said why. A wall wanted on a tile that holds a hatch / door / trap is now no piece of the seal: the seal
-- is blocked 'occupied' (never done), kern.log and PROJECT_BLOCKED name the building and the tile.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local Z = 137
local ID = 'c1a1af372f2465d901'
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, 52, 130, Z, 58, 134)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end})
  return W
end

local function seal_doc(cells, at)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = at or '55,132,137 floor', close = 'wall'},
          anchor = {55, 132, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {55, 132, Z}, cells = cells}}}},
          manifest = {v = 2}, materials = {wall = #cells}}
end

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end

T.test('BUG-565: a wall wanted on a tile that holds a hatch is blocked "occupied", never done; the reason names the hatch and the tile', function()
  local W = world('occ565')
  H.hatch(W, 55, 132, Z, '.')
  W.load(runner)
  H.place(W, ID, seal_doc({{0, 0, 0, 'Cw'}}))
  H.runs(W, 4)
  local P = H.proj(W, ID)
  T.ok(P, 'the project exists')
  T.ok(P.done ~= 1, 'old code: done at 100 % with nothing built')
  T.eq(P.blocked, 'occupied')
  T.eq(#W.find_events('PROJECT_DONE'), 0, 'no PROJECT_DONE')
  T.ok(logged(W, 'warn', ID .. ' %(seal%): nothing built: Door 55,132,137 %(a wall wanted%)'), 'the kern.log line names the building')
  W.K.persist.get('projects')                      -- the blocked announcement comes after blocked_a (2 days)
  H.runs(W, 6, 600)
  local ev = W.find_events('PROJECT_BLOCKED')
  T.ok(#ev >= 1, 'PROJECT_BLOCKED')
  T.eq(ev[1].d.why, 'occupied')
  T.ok(tostring(ev[1].msg):find('55,132,137', 1, true) and tostring(ev[1].msg):find('nothing built', 1, true), 'the msg: ' .. tostring(ev[1].msg))
  T.ok(tostring(ev[1].msg):find('bp.cancel', 1, true), 'and the way out')
end)

T.test('BUG-565: a wall on an empty floor tile is still built and done (control); one occupied piece beside a built one only warns', function()
  local W = world('ok565')
  W.load(runner)
  H.place(W, ID, seal_doc({{0, 0, 0, 'Cw'}}))
  H.runs(W, 1)
  H.build(W)
  H.runs(W, 2)
  local P = H.proj(W, ID)
  T.eq({P.done, P.blocked}, {1, ''}, 'a plain wall is done')
  T.eq(W.tile(55, 132, Z).c, 'C')
  -- two pieces, one tile holds a hatch: the wall that can stand is built, the project finishes and the log names the other
  local W2 = world('mix565')
  H.hatch(W2, 56, 132, Z, '.')
  W2.load(runner)
  local id2 = 'c1a1af372f2465d902'
  H.place(W2, id2, seal_doc({{0, 0, 0, 'Cw'}, {1, 0, 0, 'Cw'}}, '55,132,137 floor;56,132,137 floor'))
  H.runs(W2, 1)
  H.build(W2)
  H.runs(W2, 2)
  local P2 = H.proj(W2, id2)
  T.eq({P2.done, P2.blocked}, {1, ''}, 'the wall that fits stands, the project is done')
  T.ok(logged(W2, 'warn', id2 .. ' %(seal%): a piece tile holds another building: Door 56,132,137'), 'the other tile is named')
end)

T.done()
