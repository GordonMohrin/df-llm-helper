-- BUG-655 (Run 16a i1 Basementflew y442-y466: the hospital stage 'build_lost at build, missing b x4' in six projects, 8 retries each, 283 logs in
-- the fort): the blocked event calls a 'b' cell a bed, names what the supply of the beds lacks (economy.piece_supply) and, when the retries are
-- spent, asks as a DECISION (piece_missing) with the command that fixes it.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local X, Y, Z = 20, 20, 50
local function hospital_doc()
  return {v = 2, tpl = 'hospital', site = 'S1', class = 'living', params = {surface = 1, beds = 4, bench = 0}, anchor = {X, Y, Z}, rot = 0,
          stages = {{label = 'build', mode = 'build', orders = 0, defense = 0,
                     chunks = {{pos = {X, Y, Z}, cells = {{0, 0, 0, 'b'}, {1, 0, 0, 'b'}, {2, 0, 0, 'b'}, {3, 0, 0, 'b'}}}}}},
          manifest = {v = 2}, materials = {bed = 4, table = 1}}
end

local function world(tag, supply)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, X, Y, Z, X + 7, Y + 2)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'wood' end,
          piece_supply = function(_K, kind, n)
            if kind ~= 'bed' then return nil end
            return supply, [[dfllm cmd order.add '{"job":"ConstructBed","amount":4}']], 'no_order'
          end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  return W
end

T.test('BUG-655: a bed cell is named "bed" and the supply text says what lacks (old: "missing b x4")', function()
  local W = world('b655a', 'bed x4: ConstructBed x0 open, Carpenters stands, logs 283: nothing makes the missing 4')
  local d = hospital_doc()
  for dx = 0, 3 do W.unsuitable[(X + dx) .. ',' .. Y .. ',' .. Z] = true end      -- quickfort places no bed
  H.place(W, 'hosp', d)
  local P = H.proj(W, 'hosp')
  local sw, cmds = runner.supply_why(W.K, P, d)
  T.ok(sw and sw:find('bed x4: ConstructBed x0 open', 1, true), tostring(sw))
  T.eq(cmds, {[[dfllm cmd order.add '{"job":"ConstructBed","amount":4}']]})
  H.settle(W); W.frame(1); H.settle(W)
  H.runs(W, 12)
  H.runs(W, 4)
  local pb = W.find_events('PROJECT_BLOCKED')
  T.ok(#pb >= 1, 'a PROJECT_BLOCKED')
  T.eq(pb[1].d.missing, {'bed x4'})
  T.ok(pb[1].msg:find('missing bed x4', 1, true), pb[1].msg)
  T.ok(pb[1].d.mat and pb[1].d.mat:find('bed x4: ConstructBed', 1, true), tostring(pb[1].d.mat))
end)

T.test('BUG-655: the retries spent: a DECISION piece_missing with the order.add command, once', function()
  local W = world('b655c', 'bed x4: ConstructBed x0 open, Carpenters stands, logs 283: nothing makes the missing 4')
  runner.CFG.retry_max, runner.CFG.retry_every = 1, 1200
  local d = hospital_doc()
  for dx = 0, 3 do W.unsuitable[(X + dx) .. ',' .. Y .. ',' .. Z] = true end
  H.place(W, 'hosp', d)
  H.settle(W); W.frame(1); H.settle(W)
  H.runs(W, 60)
  local dec = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'piece_missing' then dec[#dec + 1] = e end end
  T.eq(#dec, 1, 'once')
  T.eq(dec[1].d.cmds, {[[dfllm cmd order.add '{"job":"ConstructBed","amount":4}']]})
  T.ok(dec[1].msg:find('bed x4: ConstructBed x0 open', 1, true), dec[1].msg)
  runner.CFG.retry_max, runner.CFG.retry_every = CFG0.retry_max, CFG0.retry_every
end)

T.test('BUG-655: the supply of every piece fine (economy answers nil): no text, no decision', function()
  local W = world('b655b', nil)
  local d = hospital_doc()
  H.place(W, 'hosp', d)
  local P = H.proj(W, 'hosp')
  T.eq(runner.supply_why(W.K, P, d), nil)
end)

T.done()
