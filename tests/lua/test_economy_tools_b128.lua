-- BUG-128 (Run 14 region2-site90, also site84/97/98): the miners held no pick although 109 lay in the fort. The tool
-- details churned (members rotated every TOOL_BLOCKED, "- basis 0" 23 times), new members were patients, doctors and the
-- chief medical dwarf, tool_check reported 'pending' for the request it had just made itself and 'upair' for a pair DF had
-- made with a loose pick outside its 4-pick sample, the stale count let the forge make picks without end, and the
-- dfllm-tools pile stayed empty while the picks sat in a binned weapons pile (DF does not re-haul stored items).
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
local function digs(n, kind)
  local jobs = {}
  for k = 1, n do jobs[#jobs + 1] = {kind or 'Dig', nil, {x = 60 + k % 5, y = 40, z = 5}} end
  return jobs
end
local function snapshot_fake()
  return {name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            if z == 5 and x >= 40 and x <= 80 and y >= 30 and y <= 50 then return {c = '.', dig = '', bld = ''} end
          end,
          far = function() return false end,
          groups = function(K, pts)
            local g = {}
            for i, p in ipairs(pts) do g[i] = type(p) == 'table' and 1 or -1 end
            return g
          end}
end
local function equipment(lists)
  local eq = {update = {}}
  for _, k in ipairs({'items_unmanifested', 'items_unassigned', 'items_assigned'}) do
    eq[k] = {WEAPON = kmock.vec(lists[k] or {})}
  end
  eq.work_weapons, eq.work_units = kmock.vec(lists.ww or {}), kmock.vec(lists.wu or {})
  df.global.plotinfo.equipment = eq
end

-- opts: cit, miners/cutters (the player's members), picks/axes (free, at pick_pos), dig/fell (open jobs), wood, setup
local function world(opts)
  opts = opts or {}
  local ctl = {wd_opts = {}, piles = {}}
  local units = {}
  for i = 1, opts.cit or 12 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'Dig', 'FellTree', 'PlantSeeds', 'GatherPlants', 'Rest'})
  df.work_detail_mode = {Default = 0, EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3}
  df.unit_labor = {MINE = 1, CUTWOOD = 2, HUNT = 3, PLANT = 4, FEED_WATER_CIVILIANS = 10, RECOVER_WOUNDED = 11,
                   SURGERY = 12, DIAGNOSE = 13}
  df.profession = {MINER = 1, WOODCUTTER = 2, PEASANT = 3, [1] = 'MINER', [2] = 'WOODCUTTER', [3] = 'PEASANT'}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.items.getHolderUnit = function(it) return it._carrier end
  dfhack.units.getNoblePositions = function(u) return u._noble and {{position = {code = u._noble}}} or nil end
  local function lab_vec(t) return setmetatable(t, {__len = function() return 14 end}) end
  local function wd(name, labor, ids, mode)
    return {name = name, assigned_units = kmock.vec(ids or {}), allowed_labors = lab_vec{[labor] = true},
            flags = {mode = mode or 3}}
  end
  ctl.wds = {Miners = wd('Miners', 1, opts.miners), Woodcutters = wd('Woodcutters', 2, opts.cutters),
             Hunters = wd('Hunters', 3, {}), Planters = wd('Planters', 4, {}, 1)}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wds.Miners, ctl.wds.Woodcutters, ctl.wds.Hunters,
                                                             ctl.wds.Planters}}
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P0'} end})
  W.act_result('run', function(cmd, a1)
    if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: monitor (labormanager)' end
    return true, ''
  end)
  W.act_result('work_detail', function(name, id, on, o)
    ctl.wd_opts[#ctl.wd_opts + 1] = {name = name, id = id, on = on, opts = o}
    local u = W.unit(id)
    local lab = ({Miners = 'MINE', Woodcutters = 'CUTWOOD'})[name]
    if u and lab then u.status.labors[lab] = on and true or nil end
    if u and on and o and o.equip then u.uniform.pickup_flags.update = true end    -- DF's request flag (equip_update)
    local v = ctl.wds[name].assigned_units
    for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
    if on then v:insert('#', id) end
    return true
  end)
  W.act_result('tool_pile', function(pos, w, h, take)
    ctl.piles[#ctl.piles + 1] = {pos = pos, w = w, h = h, take = take}
    F.building(W, 'STOCKPILE', {name = 'dfllm-tools', stockpile_number = 9, id = 900 + #ctl.piles})
    return true, 1
  end)
  W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
  W.subdefs[2] = {id = 'ITEM_WEAPON_AXE_BATTLE', skill_melee = df.job_skill.AXE, skill_ranged = -1}
  local pp = opts.pick_pos or {30, 40, 5}
  ctl.picks = {}
  for _ = 1, opts.picks or 0 do ctl.picks[#ctl.picks + 1] = F.item(W, 'WEAPON', {subtype = 1, _pos = {pp[1], pp[2], pp[3]}}) end
  for _ = 1, opts.axes or 0 do F.item(W, 'WEAPON', {subtype = 2, _pos = {pp[1], pp[2], pp[3]}}) end
  for _ = 1, opts.wood or 200 do F.item(W, 'WOOD', {}) end
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  F.item(W, 'DRINK', {stack_size = 500})
  local jobs = digs(opts.dig or 0)
  for _, j in ipairs(digs(opts.fell or 0, 'FellTree')) do jobs[#jobs + 1] = j end
  job_list(jobs)
  local ids = {}
  for i = 1, opts.cit or 12 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i, job_type = 0}}
    u.status.labors = {}
    u.mood = -1
    u.profession = df.profession.PEASANT
    u.uniform = {pickup_flags = {}, uniform_pickup = kmock.vec{}}
    u._m.skills = {MINING = (i == 5 and 10) or (i == 7 and 6) or 0, WOODCUTTING = i == 9 and 4 or 0}
    W.move(i, 55 + i, 40, 5)
  end
  for _, id in ipairs(opts.miners or {}) do W.unit(id).status.labors.MINE = true end
  for _, id in ipairs(opts.cutters or {}) do W.unit(id).status.labors.CUTWOOD = true end
  W.set_census('u', F.census_u(ids))
  W.load(snapshot_fake())
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  return W, ctl
end

local function members(ctl, name)
  local r = {}
  for _, id in ipairs(ctl.wds[name].assigned_units) do r[#r + 1] = id end
  table.sort(r)
  return r
end
local function give(W, id, sub)
  local it = F.item(W, 'WEAPON', {subtype = sub or 1, flags = {in_inventory = true}})
  it._carrier = W.unit(id)
  W.unit(id).inventory:insert('#', {mode = 1, item = it})
  return it
end
local function log_has(W, s)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then return l.msg end end
end
local function has_key(bk, k) return (',' .. tostring(bk) .. ','):find(',' .. k .. ',', 1, true) ~= nil end

---------------------------------------------------------------- 1. churn guard
T.test('BUG-128: a tool detail keeps a member who holds the tool or has a work tool pair and every member for '
       .. 'tools.keep_days (Run 14: members rotated every event, 23x "- basis 0")', function()
  local W, ctl = world{cit = 22, picks = 8, dig = 40}
  days(W, 1)
  T.eq(members(ctl, 'Miners'), {1, 2, 5, 7}, '40 dig jobs: four miners, the best skills first')
  give(W, 1, 1)
  equipment{items_unassigned = {ctl.picks[1].id}, ww = {ctl.picks[1].id}, wu = {2}}
  job_list({})
  days(W, 6)
  T.eq(members(ctl, 'Miners'), {1, 2, 5, 7}, 'within keep_days (14) nobody leaves (shrink_days 3 took two off before)')
  T.eq(#W.find_events('WORK_DETAIL'), 4, 'only the four additions')
  days(W, 12)
  T.eq(members(ctl, 'Miners'), {1, 2}, 'after keep_days: 1 holds a pick, 2 is DF\'s work tool pair; 5 and 7 hold none')
end)

T.test('BUG-128: the target never shrinks to 0 while the detail\'s jobs exist (woodcutters at wood >= 150 with '
       .. 'FellTree jobs open)', function()
  local W, ctl = world{cit = 12, axes = 3, wood = 30, fell = 6}
  days(W, 1)
  T.eq(members(ctl, 'Woodcutters'), {1, 9}, 'wood 30: two woodcutters')
  for _ = 1, 150 do F.item(W, 'WOOD', {}) end
  days(W, 20)
  T.eq(members(ctl, 'Woodcutters'), {9}, 'wood 180 wants none, but six FellTree jobs wait: the best one stays')
  job_list({})
  days(W, 5)
  T.eq(members(ctl, 'Woodcutters'), {}, 'no FellTree job left: target 0')
end)

---------------------------------------------------------------- 2. candidates
T.test('BUG-128: new tool detail members are no patients, nobles/office holders or doctors; the profession breaks a '
       .. 'skill tie', function()
  local W, ctl = world{cit = 22, picks = 8, dig = 40, setup = function(Wx)
    Wx.unit(5).health = {flags = {needs_healthcare = true}}             -- the best miner, injured
    Wx.unit(7).status.labors.SURGERY = true                             -- the second best, a surgeon
    Wx.unit(1)._noble = 'CHIEF_MEDICAL_DWARF'
    Wx.unit(2).job.current_job = {id = 902, job_type = df.job_type.Rest} -- resting injured
    Wx.unit(11).profession = df.profession.MINER
  end}
  days(W, 1)
  T.eq(members(ctl, 'Miners'), {3, 4, 6, 11}, 'skill 0 for all left: the miner by profession first, then by id')
end)

---------------------------------------------------------------- 3. tool_check
T.test('BUG-128: the blocked days count from the oldest member still without a tool, not from the detail\'s first '
       .. 'block', function()
  local W, ctl = world{cit = 12, picks = 1, dig = 14, miners = {5}}      -- one free pick: the target stays 1
  days(W, 2)
  T.eq(members(ctl, 'Miners'), {5})
  ctl.wds.Miners.assigned_units:insert('#', 7)
  W.unit(7).status.labors.MINE = true
  days(W, 1)
  give(W, 5, 1)
  days(W, 1)
  T.eq(#W.find_events('TOOL_BLOCKED'), 0, 'member 7 lacks a pick for 2 days only (the detail for 4)')
  days(W, 2)
  local ev = W.find_events('TOOL_BLOCKED')
  T.eq(#ev, 1)
  T.eq({ev[1].d.members, ev[1].d.days}, {{7}, 3})
end)

T.test('BUG-128: no "pending" for the equipment request the kernel made less than a game day ago', function()
  local W, ctl = world{cit = 12, picks = 2, dig = 14, miners = {5, 7}, setup = function(Wx, c)
    equipment{items_unassigned = {c.picks[1].id, c.picks[2].id}}
  end}
  days(W, 1)
  local line = log_has(W, 'tools: Miners blocked')
  T.ok(line and not line:find('pending', 1, true), tostring(line))
  T.ok(line and line:find('upd0', 1, true), 'the fresh request is shown as upd0: ' .. tostring(line))
  days(W, 3)
  local ev = W.find_events('TOOL_BLOCKED')
  T.eq(#ev, 1)
  T.ok(has_key(ev[1].d.bk, 'pending'), 'days later DF still has not processed it: pending ' .. tostring(ev[1].d.bk))
end)

T.test('BUG-128: "upair" only when DF paired the member with a tool that is no free tool (Run 14: a loose pick outside '
       .. 'the 4-pick sample)', function()
  local W, ctl = world{cit = 12, picks = 6, dig = 14, miners = {5}, setup = function(Wx, c)
    local ids = {}
    for i, p in ipairs(c.picks) do ids[i] = p.id end
    equipment{items_unassigned = ids, ww = {c.picks[6].id}, wu = {5}}
  end}
  days(W, 4)
  local ev = W.find_events('TOOL_BLOCKED')
  T.eq(#ev, 1)
  T.ok(not has_key(ev[1].d.bk, 'upair'), ev[1].d.bk .. ': ' .. ev[1].d.blk)
  T.ok(has_key(ev[1].d.bk, 'fetch'), ev[1].d.bk)
  T.ok(ev[1].d.g and ev[1].d.g:find('upair->fetch 1', 1, true), tostring(ev[1].d.g))
  -- a pair with a pick another unit holds stays upair
  local W2, c2 = world{cit = 12, picks = 2, dig = 14, miners = {5}}
  local held = give(W2, 9, 1)
  equipment{items_unassigned = {c2.picks[1].id, c2.picks[2].id}, ww = {held.id}, wu = {5}}
  days(W2, 4)
  T.ok(has_key(W2.find_events('TOOL_BLOCKED')[1].d.bk, 'upair'), W2.find_events('TOOL_BLOCKED')[1].d.bk)
end)

---------------------------------------------------------------- 4. stale cap
T.test('BUG-128: the stale tools exclude at most stock - (members + 2): 100 loose picks, 6 miners -> 92 stale, no picks '
       .. 'made or bought (Run 14: 97 -> 109 picks, 222 axes)', function()
  local W = world{cit = 12, picks = 100, dig = 14, miners = {1, 2, 3, 4, 5, 6}}
  days(W, 20)
  local r = W.inbox('inspect', {what = 'workload', key = 'tools'})
  T.eq(r.data.stale.pick, 92)
  T.eq(W.mods.economy.M.tools_have(W.K.census.i, 'pick'), 8)
  local ok, wants = W.K.call('economy', 'trade_wants')
  for _, w in ipairs(ok and wants or {}) do T.ok(w.buy ~= 'pick', 'no pick asked from the caravans') end
  local g = W.mods.economy.M.tool_guards({name = 'Miners'}, 'pick', nil, {stn = 100}, 92)
  T.ok(g and g:find('stale 100->92', 1, true), tostring(g))
end)

---------------------------------------------------------------- 5. tool pile
T.test('BUG-128: the dfllm-tools pile takes from the stockpile the tools sit in (DF does not re-haul stored items)',
       function()
  local W, ctl = world{cit = 12, picks = 20, dig = 14, miners = {1, 2, 3, 4, 5, 6}, setup = function(Wx)
    F.building(Wx, 'STOCKPILE', {name = 'Weapons', id = 77, x1 = 28, y1 = 38, x2 = 32, y2 = 42, z = 5})
  end}
  days(W, 10)
  T.eq(#ctl.piles, 1)
  T.eq(ctl.piles[1].take, 77, 'take from the weapons pile at 28-32,38-42,5')
  local r = W.inbox('inspect', {what = 'workload', key = 'tools'})
  T.ok(r.data.pile and r.data.pile:find('takes from 77', 1, true), tostring(r.data.pile))
  -- a dfllm-tools pile that stood already (no link): the player is told to link it
  local W2 = world{cit = 12, picks = 20, dig = 14, miners = {1, 2, 3, 4, 5, 6}, setup = function(Wx)
    F.building(Wx, 'STOCKPILE', {name = 'Weapons', id = 77, x1 = 28, y1 = 38, x2 = 32, y2 = 42, z = 5})
    F.building(Wx, 'STOCKPILE', {name = 'dfllm-tools', id = 990, x1 = 60, y1 = 40, x2 = 62, y2 = 41, z = 5})
  end}
  days(W2, 4)
  local ev = W2.find_events('TOOL_BLOCKED')
  T.eq(#ev, 1)
  T.eq(ev[1].d.src, 77)
  T.ok(ev[1].d.g and ev[1].d.g:find('take from stockpile 77', 1, true), tostring(ev[1].d.g))
end)

T.done()
