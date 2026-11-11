-- BUG-705 (Run 16b i2 Whirledrampart y420-y423: census wood 210 beside DF's "Needs logs" on every wooden job; all 210 logs lay on another walk
-- group): the census counts a log on another walk group (wood_far) and a forbidden log (wood_forb) apart, neither is `wood`; a "Needs logs"
-- cancel logs the split and where the logs lie.
-- BUG-706 (Run 16a i1 Basementflew: 20 free axes, 3 reserved by squad uniforms, TOOL_BLOCKED 'axes not in the free equipment list' for 567 days
-- from the three reserved ones): a reserved tool is not `use` and comes last in the list and the sample; all free tools reserved is blocker
-- 'reserved'; 'nothing visible' says what the member does.
-- BUG-707 (Run 16b i2: the Woodcutters without an axe, 'axe 1, free 1, forbidden 1, reserved 1', trade.want held pick and not axe): no usable
-- free axe for the lacking members: the forge is ordered a battle axe, else the caravans are asked for axes.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

local function job_list(jobs)
  local head, cur = {}, nil
  cur = head
  for i, j in ipairs(jobs) do
    local node = {item = {id = 7000 + i, job_type = df.job_type[j[1]], flags = {}, _worker = j[2], pos = j[3]}}
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
end

-- opts: axes (free, loose at 21,20,5), reserved (the first n axes are reserved by a squad uniform), fell (open FellTree jobs), near / far / forb
-- (logs: on the citizens' group, on another walk group z 37, forbidden), forge, bars, cutters
local function world(opts)
  opts = opts or {}
  local ctl = {}
  local units = {}
  for i = 1, 12 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'Dig', 'FellTree', 'MakeWeapon', 'HarvestPlants'})
  df.work_detail_mode = {Default = 0, EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3}
  df.unit_labor = {MINE = 1, CUTWOOD = 2, HUNT = 3}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.items.getHolderUnit = function(it) return it._carrier end
  dfhack.items.getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end
  local function lab_vec(t) return setmetatable(t, {__len = function() return 12 end}) end
  local function wd(name, labor, ids)
    return {name = name, assigned_units = kmock.vec(ids or {}), allowed_labors = lab_vec{[labor] = true}, flags = {mode = 3}}
  end
  ctl.wds = {Miners = wd('Miners', 1, {}), Woodcutters = wd('Woodcutters', 2, opts.cutters or {9}), Hunters = wd('Hunters', 3, {})}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wds.Miners, ctl.wds.Woodcutters, ctl.wds.Hunters}}
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P0'} end})
  W.act_result('run', function() return true, '' end)
  W.act_result('work_detail', function() return true end)
  W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
  W.subdefs[2] = {id = 'ITEM_WEAPON_AXE_BATTLE', skill_melee = df.job_skill.AXE, skill_ranged = -1}
  ctl.axes = {}
  for _ = 1, opts.axes or 0 do ctl.axes[#ctl.axes + 1] = F.item(W, 'WEAPON', {subtype = 2, _pos = {21, 20, 5}}) end
  if (opts.reserved or 0) > 0 then
    local ids = {}
    for i = 1, opts.reserved do ids[i] = ctl.axes[i].id end
    df.global.plotinfo.equipment = {items_assigned = {WEAPON = kmock.vec(ids)}}
  end
  for _ = 1, opts.near or 0 do F.item(W, 'WOOD', {_pos = {5, 5, 1}}) end
  for _ = 1, opts.far or 0 do F.item(W, 'WOOD', {_pos = {5, 6, 37}}) end
  for _ = 1, opts.forb or 0 do F.item(W, 'WOOD', {_pos = {5, 7, 1}, flags = {forbid = true}}) end
  for tok, n in pairs(opts.bars or {}) do
    F.mat(W, 0, 8, {token = 'INORGANIC:' .. tok, flags = {IS_METAL = true}})
    for _ = 1, n do F.item(W, 'BAR', {mat_type = 0, mat_index = 8}) end
  end
  if opts.forge then
    F.workshop(W, 'MetalsmithsForge')
    for _ = 1, 3 do F.item(W, 'BAR', {mat_type = 7, mat_index = 0}) end          -- fuel
  end
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  F.item(W, 'DRINK', {stack_size = 500})
  local jobs = {}
  for _ = 1, opts.fell or 0 do jobs[#jobs + 1] = {'FellTree'} end
  job_list(jobs)
  local ids = {}
  for i = 1, 12 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u._m.skills = {MINING = 0, WOODCUTTING = i == 9 and 4 or 0}
  end
  for _, id in ipairs(opts.cutters or {9}) do W.unit(id).status.labors.CUTWOOD = true end
  W.set_census('u', F.census_u(ids))
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.items_at() return {} end
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far(K, x, y, z) return z == 37 end
  function snap.reach() return true end
  function snap.groups(K, pts) local r = {}; for i = 1, #pts do r[i] = 1 end; return r end
  function snap.outside_near(K, pts) local r = {}; for i = 1, #pts do r[i] = 0 end; return r end
  W.load(snap)
  W.load(fresh('economy'))
  return W, ctl
end

local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l.msg end end
end
local function orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end

T.test('BUG-705: logs on another walk group (wood_far) and forbidden logs (wood_forb) are not `wood`', function()
  local W = world{near = 4, far = 210, forb = 3}
  days(W, 1)
  local i = W.K.census.i
  T.eq({i.wood, i.wood_far, i.wood_forb}, {4, 210, 3})
  local W2 = world{far = 210}
  days(W2, 1)
  T.eq({W2.K.census.i.wood, W2.K.census.i.wood_far}, {0, 210}, 'all 210 far: the fort has no log a job can take')
end)

T.test('BUG-705: a "Needs logs" cancel logs the split: every log on another walk group', function()
  local W = world{far = 210}
  days(W, 1)
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Carpenter cancels Construct Table: Needs logs.'})
  settle(W)
  local l = logged(W, 'DF cancels')
  T.ok(l and l:find('census logs free 0, on another walk group 210, forbidden 0', 1, true), tostring(l))
  T.ok(l:find('another walk group than the citizens', 1, true), l)
  T.ok(l:find('levels z37 x210', 1, true), l)
end)

T.test('BUG-705: "Needs logs" beside free reachable logs names the contradiction', function()
  local W = world{near = 30}
  days(W, 1)
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Carpenter cancels Construct Table: Needs logs.'})
  settle(W)
  local l = logged(W, 'DF cancels')
  T.ok(l and l:find('DF refuses logs the census counts usable', 1, true), tostring(l))
end)

T.test('BUG-706: 20 free axes, the 3 lowest reserved: they are not `use`, the sample holds the usable ones', function()
  local W = world{axes = 20, reserved = 3, fell = 8}
  days(W, 4)
  local i = W.K.census.i
  T.eq({i.w_axe, i.w_axe_free, i.w_axe_res, i.w_axe_use}, {20, 20, 3, 17})
  local list = W.mods.economy.M.tool_list('axe')
  T.eq(#list, 8)
  for _, e in ipairs(list) do T.ok(not e.res, 'no reserved axe among the first 8 listed: ' .. tostring(e.id)) end
  local ev = W.find_events('TOOL_BLOCKED')
  if #ev > 0 then
    T.ok(not tostring(ev[1].d.bk):find('pool', 1, true), 'reserved axes are no pool blocker: ' .. tostring(ev[1].d.bk))
  end
end)

T.test('BUG-706: all free axes reserved: blocker `reserved`', function()
  local W = world{axes = 3, reserved = 3, fell = 8}
  days(W, 4)
  local ev = W.find_events('TOOL_BLOCKED')
  T.eq(#ev, 1)
  T.ok(ev[1].d.bk:find('reserved', 1, true), ev[1].d.bk)
  T.ok(ev[1].d.blk:find('3 of 3 free axes are reserved by squad uniforms', 1, true), ev[1].d.blk)
  T.eq({ev[1].d.reserved, ev[1].d.free}, {3, 3})
end)

T.test('BUG-706: nothing visible names the job and the pickup list of the member', function()
  local E = fresh('economy')
  local dg = {units = {{id = 9, job = 'HarvestPlants', pk = 5, lab = true, xl = {}}}, picks = {}, keys = {}, texts = {}, ww = 4, civ = 0}
  E.td_blockers(dg, {name = 'Woodcutters', labor = 'CUTWOOD', jobs = 'FellTree'}, 'axe', 1)
  T.eq(dg.key, 'none')
  T.ok(dg.why:find('member 9: job HarvestPlants, 5 items on his pickup list, 4 work tool pairs', 1, true), dg.why)
end)

T.test('BUG-707: members without a usable axe: the forge is ordered a battle axe', function()
  local W = world{axes = 3, reserved = 3, fell = 8, forge = true, bars = {IRON = 4}}
  days(W, 4)
  local o = orders(W, 'dfllm:axe')
  T.eq(#o, 1)
  T.eq({o[1].job, o[1].item_subtype, o[1].material}, {'MakeWeapon', 'ITEM_WEAPON_AXE_BATTLE', 'INORGANIC:IRON'})
  for _, e in ipairs(W.mods.economy.M.trade_wants(W.K)) do T.ok(e.buy ~= 'axe', 'the forge makes it: no trade want') end
end)

T.test('BUG-707: no forge or no bar: the caravans are asked for axes; usable free axes: nothing', function()
  local W = world{axes = 3, reserved = 3, fell = 8}
  days(W, 4)
  T.eq(orders(W, 'dfllm:axe'), {})
  local want
  for _, e in ipairs(W.mods.economy.M.trade_wants(W.K)) do if e.buy == 'axe' then want = e end end
  T.ok(want and want.n >= 1, 'axe wanted from the caravans')
  local W2 = world{axes = 6, reserved = 0, fell = 8}
  days(W2, 4)
  T.eq(orders(W2, 'dfllm:axe'), {})
  for _, e in ipairs(W2.mods.economy.M.trade_wants(W2.K)) do T.ok(e.buy ~= 'axe', 'no axe want') end
end)

T.done()
