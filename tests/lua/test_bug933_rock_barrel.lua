-- NEU20a (holz-fass) BUG-933: Run 17 i1 Diedplank orders 709 / 710 / 1399 `order.add MakeBarrel mat=rock`: commands.log shows material INORGANIC reached act.workorder (the order was a ROCK barrel
-- order: job 'boulder x1: 0 match, 0 free'), but `why order:N` led with DF's tally of 'make wooden barrel: Needs logs' and the player read 'mat ignored'; the ladder named the rock order beside 0 free
-- boulders. (1) why matches DF's cancels against the kind of THIS order, (2) order.add mat=rock for a barrel is refused with the reason when the census holds no usable boulder, (3) the ladder
-- (tests/test_bug933_ladder_rock.py) does not name it then.
local T = require('testlib')
local F = require('wp8_world')
local JW = require('dfllm.jobwhy')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function jt(name)
  if df.job_type[name] == nil then
    local n = 0
    for _, v in pairs(df.job_type) do if type(v) == 'number' and v > n then n = v end end
    df.job_type[name] = n + 1; df.job_type[n + 1] = name
  end
end

T.test('BUG-933: DF cancel kinds are matched by the order\'s material: a rock order is not told "make wooden barrel: Needs logs"', function()
  F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true}}}
  jt('MakeBarrel')
  local wood = JW.df_match({kind = 'order', job = 'MakeBarrel', mat = 'wood'})
  local rock = JW.df_match({kind = 'order', job = 'MakeBarrel', mat = 'rock'})
  local any = JW.df_match({kind = 'order', job = 'MakeBarrel'})
  T.ok(wood('make wooden barrel') and not wood('make rock barrel'))
  T.ok(rock('make rock barrel') and rock('make stone barrel') and not rock('make wooden barrel'))
  T.ok(any('make wooden barrel') and any('make rock barrel'), 'an order of unknown material keeps the old match')
  T.ok(not rock('make wooden door'), 'still only barrels')
end)

local function world(inv)
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  jt('MakeBarrel')
  W.load(fresh('economy'))
  W.K.census.i = inv
  return W
end

T.test('BUG-933: order.add MakeBarrel mat=rock is refused with the reason when no boulder a job may take is in the census; mat=wood and material=INORGANIC are not', function()
  local W = world({rock = 0, boulders = 40, rock_nouse = 0, wood = 3})
  local r = W.inbox('order.add', {job = 'MakeBarrel', amount = 15, mat = 'rock'})
  T.eq(r.ok, false)
  T.ok(r.msg:find('no boulder a rock barrel may take', 1, true), r.msg)
  T.ok(r.msg:find('40 boulders, 0 usable', 1, true) and r.msg:find('material=INORGANIC', 1, true), r.msg)
  T.eq(W.inbox('order.add', {job = 'MakeBarrel', amount = 15, mat = 'wood'}).ok, true, 'wood is untouched')
  T.eq(W.inbox('order.add', {job = 'MakeBarrel', amount = 15, material = 'INORGANIC'}).ok, true, 'the explicit material is the player\'s call')
  T.eq(W.inbox('order.add', {job = 'ConstructDoor', amount = 2, mat = 'rock'}).ok, true, 'only barrels')
end)

T.test('BUG-933: with a usable boulder the order is made as before (material INORGANIC reaches the workorder)', function()
  local W = world({rock = 12, boulders = 40, rock_nouse = 0})
  local r = W.inbox('order.add', {job = 'MakeBarrel', amount = 15, mat = 'rock'})
  T.eq(r.ok, true, r.msg)
  local n = 0
  for _, a in ipairs(W.find_acts('workorder')) do
    local sp = a.args[1]
    if type(sp) == 'table' and sp.job == 'MakeBarrel' and sp.material == 'INORGANIC' and sp.material_category == nil then n = n + 1 end
  end
  T.eq(n, 1, 'one ROCK barrel order reached the workorder act')
end)

T.done()
