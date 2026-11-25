-- NEU11 BUG-878..880 (Run 17 i1 Diedplank 25.11.: DF cancelled 'Make wooden barrel: Needs logs' 476x in the last 3000 gamelog lines while the reserve said
-- 'ordered'; the reserve's rock order is byte for byte the players' order.add MakeBarrel mat=rock ({job MakeBarrel, material INORGANIC}, DF: 'Make rock barrel'):
-- the dead orders were WOODEN ones (the reserve's own wood batch after a switch, the ordinary dfllm:barrel), kept for ever because MakeBarrel is in KEEP_JOBS).
-- Offline, against the fake world.
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200
local BREWWHY = 'Needs empty food storage item'

local function world()
  local units, ids = {}, {}
  for i = 1, 8 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  df.unit_labor = {BREWER = 6, [6] = 'BREWER', CARPENTER = 7, [7] = 'CARPENTER', STONE_CRAFT = 8, [8] = 'STONE_CRAFT'}
  df.job_skill = df.job_skill or {}
  for i, n in ipairs({'MakeBarrel', 'BrewDrink'}) do df.job_type[n], df.job_type[900 + i] = 900 + i, n end   -- the fake enum lacks them
  dfhack.units.isChild = function() return false end
  dfhack.units.isBaby = function() return false end
  for i = 1, 8 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
  end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end})
  W.load(fresh('economy'))
  W.removed = {}
  W.act_result('order_remove', function(id) W.removed[#W.removed + 1] = id; return true, 'removed' end)
  return W
end

local function brewcancels(econ, K, n, tick)
  for _ = 1, n do
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels Brew drink from plant: ' .. BREWWHY .. '.'})
  end
end

local function run(W, o)
  local econ = require('dfllm.economy')
  local c = econ.conf(W.K)
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  local r = {now = o.now, day = true, p = p, inv = o.inv, f = o.f or {['workshop:Carpenters'] = true, ['workshop:Craftsdwarfs'] = true, ['workshop:Still'] = true},
             s = {brew = {left = o.brews or 30}, live = o.live or {}, used = o.used or {}}, held = {}, cands = {}, planned = {}, days = {drink_d = 0}, cit = 8}
  local acted = econ.plan_reserve(W.K, c, r)
  return acted, r, p, econ, c
end

local function logs_with(W, needle)
  local out = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(needle, 1, true) then out[#out + 1] = l.msg end end
  return out
end

-- the i1 state: 23 brews open, DF cancels the brews for want of a container, the census says 10 logs and 40 usable boulders
local I1 = {wood = 10, wood_far = 253, boulders = 83, rock = 40, rock_far = 3, rock_busy = 5, barrels = 119, barrels_empty = 22, cont_free = 2}

T.test('BUG-878 i1: a WOODEN batch stands while DF cancels "Make wooden barrel: Needs logs": the order is taken back, the reserve orders the ROCK barrel at once', function()
  local W = world()
  local econ = require('dfllm.economy')
  local t0 = 300 * DAYT
  brewcancels(econ, W.K, 40, t0 + 6 * DAYT)
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:barrelx'] = 77}
  df.global.world.manager_orders.all:insert('#', {id = 77, job_type = df.job_type.MakeBarrel, amount_left = 10, amount_total = 10, material_category = {wood = true}})
  p.rsv = {t0 = t0, at = t0 + 5 * DAYT, mat = 'wood', n = 10, made = 59, open = true, rep = 1, done = t0 + 1}
  -- no cancel of its own job yet: the batch stands, the reserve owns the planning
  local acted, r1 = run(W, {now = t0 + 6 * DAYT, inv = I1, live = {['dfllm:barrelx'] = {}}, brews = 23})
  T.ok(acted and #r1.cands == 0 and #W.removed == 0, 'a wooden batch with no cancel of its job stands')
  -- DF cancels it 24x (one gamelog look groups them as one note)
  econ.cw_note(W.K, 'make wooden barrel', 'Needs logs', t0 + 6 * DAYT + 100, 24)
  local acted2, r2, p2 = run(W, {now = t0 + 6 * DAYT + 200, inv = I1, live = {['dfllm:barrelx'] = {}}, brews = 23})
  T.eq(W.removed, {77}, 'the dead wooden order is removed (the work orders screen)')
  T.eq(p2.orders['dfllm:barrelx'], nil)
  T.ok(acted2 and #r2.cands == 1, 'and the reserve orders again in the same run')
  local cd = r2.cands[1]
  T.eq(cd.spec.job, 'MakeBarrel')
  T.eq(cd.spec.material, 'INORGANIC', 'rock: exactly the players order.add MakeBarrel mat=rock')
  T.eq(cd.spec.material_category, nil)
  T.eq(cd.spec.item_conditions, nil, 'no wood condition kept from the wooden batch')
  T.eq(p2.rsv.mat, 'rock')
  T.eq(p2.rsv.made, 59 - 10 + cd.n, 'the containers never made leave the count, the rock batch adds its own')
  T.ok(p2.rsv.out and p2.rsv.out.wood, 'wood is out')
  T.eq(#logs_with(W, 'taken back'), 1)
  local ord = logs_with(W, 'rock barrels ordered')
  T.eq(#ord, 1)
  T.ok(ord[1]:find('boulders in the census', 1, true), 'the log line names the stone count: ' .. ord[1])
end)

T.test('BUG-878: a ROCK batch that DF cancels is taken back too; the wood batch follows when logs carry it', function()
  local W = world()
  local econ = require('dfllm.economy')
  local t0 = 300 * DAYT
  brewcancels(econ, W.K, 40, t0 + 6 * DAYT)
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:barrelx'] = 78}
  df.global.world.manager_orders.all:insert('#', {id = 78, job_type = df.job_type.MakeBarrel, amount_left = 10, amount_total = 10, mat_type = 0})
  p.rsv = {t0 = t0, at = t0 + 5 * DAYT, mat = 'rock', n = 10, made = 10, open = true}
  econ.cw_note(W.K, 'make rock barrel', 'Needs boulder', t0 + 6 * DAYT, 12)
  local inv = {wood = 40, boulders = 20, rock = 3, barrels = 100, cont_free = 1}
  local _, r = run(W, {now = t0 + 6 * DAYT + 100, inv = inv, live = {['dfllm:barrelx'] = {}}, brews = 23})
  T.eq(W.removed, {78})
  T.eq(#r.cands, 1)
  T.eq(r.cands[1].spec.material_category, {'wood'})
  T.eq(r.cands[1].spec.material, nil)
end)

T.test('BUG-878: DF words win over the census: 12 cancels "Needs logs" in 2 days keep wood out although the census counts 10 usable logs; nothing is called ordered', function()
  local W = world()
  local econ = require('dfllm.economy')
  local t0 = 300 * DAYT
  brewcancels(econ, W.K, 40, t0)
  econ.cw_note(W.K, 'make wooden barrel', 'Needs logs', t0, 12)
  local inv = {wood = 10, wood_far = 253, boulders = 0, rock = 0, barrels = 119}
  local acted, r, p = run(W, {now = t0 + 100, inv = inv, brews = 23})
  T.ok(not acted and #r.cands == 0, 'no wooden batch while DF refuses wood')
  local l = logs_with(W, 'nothing to make them of')
  T.eq(#l, 1)
  T.ok(l[1]:find('DF cancels Make wooden barrel "needs logs" 12x', 1, true), l[1])
  T.eq(#logs_with(W, 'barrels ordered'), 0, 'not counted as ordered')
  T.eq(p.rsv, nil)
  -- logs arrive, DF stops cancelling: 3 game days later wood is back (the cancels left the 2-day window)
  brewcancels(econ, W.K, 10, t0 + 3 * DAYT)
  local _, r3 = run(W, {now = t0 + 3 * DAYT + 50, inv = {wood = 30, boulders = 0, rock = 0, barrels = 119}, brews = 23})
  T.eq(#r3.cands, 1, 'wood again')
  T.ok(r3.cands[1].spec.material_category ~= nil)
end)

T.test('BUG-879 i1: the free-boulder count is the one DF can use: the stone floor is not kept back, open rock orders are taken off, the line names the difference', function()
  local W = world()
  local econ = require('dfllm.economy')
  local t0 = 300 * DAYT
  brewcancels(econ, W.K, 40, t0)
  local c = econ.conf(W.K)
  c.reserve = c.reserve or {}
  c.reserve.rock = 30                                          -- the floor for open needs: the old count was usable 12 - 30 = 0
  local inv = {wood = 0, boulders = 47, rock = 14, rock_far = 0, rock_busy = 2, rock_nouse = 2, barrels = 119}
  local _, r = run(W, {now = t0 + 100, inv = inv, brews = 23, used = {rock = 4}})
  T.eq(#r.cands, 1, 'the old reserve saw 0 free boulders here')
  T.eq(r.cands[1].n, 8, '14 - 2 not usable - 4 held by open rock orders')
  local l = logs_with(W, 'rock barrels ordered')[1]
  T.ok(l:find('47 boulders in the census: 0 out of reach, 2 held by jobs, 31 in buildings / forbidden / dumped, 2 ore, flux, economic or soft', 1, true), l)
  T.ok(l:find('12 usable, 4 held by open rock orders -> 8 free', 1, true), l)
  local rd = {inv = {boulders = 47, rock = 14, rock_nouse = 2}, now = t0, planned = {}, s = {used = {}}}
  T.eq((econ.reserve_stone(c, rd)), 12)
end)

T.test('BUG-878: a wooden MakeBarrel order that DF cancels "Needs logs" while no usable log lies is no kept supply order; rock barrels and forts with logs keep the rule', function()
  local W = world()
  local econ = require('dfllm.economy')
  W.K.census.i = {wood = 0}
  local wooden = {job_type = df.job_type.MakeBarrel, material_category = {wood = true}}
  local rock = {job_type = df.job_type.MakeBarrel, mat_type = 0, material_category = {}}
  T.ok(econ.dead_wood_barrel(W.K, wooden, 'Needs logs'))
  T.ok(not econ.dead_wood_barrel(W.K, rock, 'Needs logs'), 'rock barrel: kept')
  T.ok(not econ.dead_wood_barrel(W.K, wooden, 'Needs empty food storage item'), 'another reason: kept')
  W.K.census.i = {wood = 12}
  T.ok(not econ.dead_wood_barrel(W.K, wooden, 'Needs logs'), 'logs lie: kept')
  T.ok(not econ.dead_wood_barrel(W.K, {job_type = df.job_type.BrewDrink, material_category = {wood = true}}, 'Needs logs'), 'other jobs: kept')
end)

T.test('BUG-880: state stock.rsv says the reserve orders itself (open batch or ordered < 3 days ago, material found); absent when nothing is found', function()
  local W = world()
  local econ = require('dfllm.economy')
  local t0 = 300 * DAYT
  T.ok(not econ.rsv_works(W.K, t0), 'no reserve state')
  brewcancels(econ, W.K, 40, t0)
  run(W, {now = t0 + 100, inv = {wood = 0, boulders = 90, rock = 90, barrels = 9}, brews = 23})
  T.ok(econ.rsv_works(W.K, t0 + 200), 'ordered just now')
  T.ok(not econ.rsv_works(W.K, t0 + 4 * DAYT), 'ordered 4 days ago, no batch open: the reserve is not at work')
  local W2 = world()
  local econ2 = require('dfllm.economy')
  brewcancels(econ2, W2.K, 40, t0)
  run(W2, {now = t0 + 100, inv = {wood = 0, boulders = 0, rock = 0, barrels = 9}, brews = 23})
  T.ok(not econ2.rsv_works(W2.K, t0 + 200), 'nothing to make containers of: the ladder names the players command')
end)

T.done()
