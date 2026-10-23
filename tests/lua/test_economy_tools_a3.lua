-- BUG-053 (notes 19 and 34 of bugs/RUN11-offene-bugs-und-FR.md; the live root cause of BUG-023): the miners held no pick for
-- 1081 days (Run 11 y487: 16 free picks 'loose' at 157,57,139) and 144 days (Run 12 y501, a reclaimed fort: 102 picks,
-- pick_free 100). Proven in the code: the only weapon pile the kernel builds (fortcore's melt pile) refuses picks and axes on
-- purpose, nothing else gives a tool a home, and plan_picks counted every pick in the fort, so with 16 or 100 unusable
-- picks no pick was ever made or asked from a caravan. New: the blockers forbidden / off_group / owned (population level),
-- tools that stay unused for tools.stale_days stop counting as stock, and a weapons stockpile `dfllm-tools` near the
-- mines when usable tools lie loose (act.tool_pile; the kernel never moves an item).
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

-- the group of a point: x < 100 the citizens' (1), else another (2); floor around the mines: x 40-80, y 30-50, z 5
local FLOOR = {x0 = 40, x1 = 80, y0 = 30, y1 = 50, z = 5}
local function snapshot_fake()
  return {name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            if z == FLOOR.z and x >= FLOOR.x0 and x <= FLOOR.x1 and y >= FLOOR.y0 and y <= FLOOR.y1 then
              return {c = '.', dig = '', bld = ''}
            end
          end,
          far = function(K, x, y, z) return x >= 100 end,
          groups = function(K, pts, near)
            local g = {}
            for i, p in ipairs(pts) do g[i] = type(p) == 'table' and ((p.x or p[1]) < 100 and 1 or 2) or -1 end
            return g
          end}
end

-- opts: miners (ids), picks (free), pick_pos, forb_picks, owned (free picks owned), held (ids that carry a pick),
-- dig (open dig jobs at 60+k,40,5), refuse (unforbid refused), pile (stockpile named dfllm-tools already stands)
local function world(opts)
  opts = opts or {}
  local ctl = {wd_opts = {}}
  local units = {}
  for i = 1, opts.cit or 12 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'Dig', 'FellTree', 'PlantSeeds', 'GatherPlants'})
  df.work_detail_mode = {Default = 0, EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3}
  df.unit_labor = {MINE = 1, CUTWOOD = 2, HUNT = 3, PLANT = 4, FEED_WATER_CIVILIANS = 10, RECOVER_WOUNDED = 11}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.items.getHolderUnit = function(it) return it._carrier end
  local function lab_vec(t) return setmetatable(t, {__len = function() return 12 end}) end
  local function wd(name, labor, ids, mode)
    return {name = name, assigned_units = kmock.vec(ids or {}), allowed_labors = lab_vec{[labor] = true},
            flags = {mode = mode or 3}}
  end
  ctl.wds = {Miners = wd('Miners', 1, opts.miners), Woodcutters = wd('Woodcutters', 2, {}),
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
    local v = ctl.wds[name].assigned_units
    for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
    if on then v:insert('#', id) end
    return true
  end)
  W.act_result('item_flag', function(id, flag, on)
    if opts.refuse then return false, 'refused' end
    W.items_by_id[id].flags[flag] = on
    return true
  end)
  ctl.piles = {}
  W.act_result('tool_pile', function(pos, w, h)
    ctl.piles[#ctl.piles + 1] = {pos = pos, w = w, h = h}
    F.building(W, 'STOCKPILE', {name = 'dfllm-tools', stockpile_number = 9, id = 900 + #ctl.piles})
    return true, 1
  end)
  W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
  W.subdefs[2] = {id = 'ITEM_WEAPON_AXE_BATTLE', skill_melee = df.job_skill.AXE, skill_ranged = -1}
  local pp = opts.pick_pos or {30, 40, 5}
  ctl.picks = {}
  for i = 1, opts.picks or 0 do
    local it = F.item(W, 'WEAPON', {subtype = 1, _pos = {pp[1], pp[2], pp[3]}})
    if i <= (opts.owned or 0) then it.flags.owned = true end
    ctl.picks[#ctl.picks + 1] = it
  end
  for _ = 1, opts.forb_picks or 0 do
    ctl.picks[#ctl.picks + 1] = F.item(W, 'WEAPON', {subtype = 1, flags = {forbid = true}, _pos = {pp[1], pp[2], pp[3]}})
  end
  for _ = 1, 200 do F.item(W, 'WOOD', {}) end
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  F.item(W, 'DRINK', {stack_size = 500})
  local jobs = {}
  for k = 1, opts.dig or 0 do jobs[#jobs + 1] = {'Dig', nil, {x = 60 + k % 5, y = 40, z = 5}} end
  job_list(jobs)
  local ids = {}
  for i = 1, opts.cit or 12 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {}
    u.mood = -1
    u._m.skills = {MINING = (i == 5 and 10) or (i == 7 and 6) or 0}
    W.move(i, 55 + i, 40, 5)
  end
  for _, id in ipairs(opts.miners or {}) do W.unit(id).status.labors.MINE = true end
  W.set_census('u', F.census_u(ids))
  W.load(snapshot_fake())
  if opts.pile then F.building(W, 'STOCKPILE', {name = 'dfllm-tools', stockpile_number = 9, id = 990}) end
  if opts.repair_days then W.K.cfg.baseline.economy.tools.repair_days = opts.repair_days end
  W.load(fresh('economy'))
  for _, id in ipairs(opts.held or {}) do
    local it = F.item(W, 'WEAPON', {subtype = 1, flags = {in_inventory = true}})
    it._carrier = W.unit(id)
    W.unit(id).inventory:insert('#', {mode = 1, item = it})
  end
  return W, ctl
end

local function wants(W)
  local ok, r = W.K.call('economy', 'trade_wants')
  return ok and r or {}
end
local function want_of(W, what)
  for _, w in ipairs(wants(W)) do if w.buy == what then return w end end
end

---------------------------------------------------------------- note 19
T.test('BUG-053 note 19 (Run 11 y487): 16 free picks on another walk group: off_group is named and, after stale_days, '
       .. 'the miners\' picks are asked from the caravans (16 picks counted before: nothing was ever asked)', function()
  local W, ctl = world{miners = {1, 2, 3, 4, 5, 6}, picks = 16, pick_pos = {157, 57, 139}, held = {1}, dig = 14}
  days(W, 4)
  local ev = W.find_events('TOOL_BLOCKED')
  T.eq(#ev, 1)
  local d = ev[1].d
  T.eq({d.detail, d.n, d.free, d.pos, d.why}, {'Miners', 5, 16, {157, 57, 139}, 'loose'})
  T.ok((',' .. d.bk .. ','):find(',off_group,', 1, true), d.bk)
  T.ok(d.blk:find('16 of 16 free picks lie on another walk group than the citizens', 1, true), d.blk)
  T.eq(W.K.census.i.w_pick_far, 16)
  T.eq(W.inbox('inspect', {what = 'workload', key = 'tools'}).data.tools.pick_far, 16)
  T.eq(want_of(W, 'pick'), nil, 'before tools.stale_days the loose picks still count')
  days(W, 12)
  local w = want_of(W, 'pick')
  T.ok(w, 'after 16 days the unused picks are no stock: the caravans are asked')
  T.eq(w.n, 5, 'one pick held, five members without')
  T.eq(#ctl.piles, 0, 'haulers cannot bring picks from another walk group: no pile for them')
end)

T.test('BUG-053: members that hold their picks, or a missing labor, make no stale tools and no purchase', function()
  local W = world{miners = {1, 2, 3}, picks = 6, pick_pos = {157, 57, 139}, held = {1, 2, 3}, dig = 14}
  days(W, 20)
  T.eq(want_of(W, 'pick'), nil)
  local W2 = world{miners = {1, 2, 3, 4, 5, 6}, picks = 16, pick_pos = {157, 57, 139}, held = {1}, dig = 14}
  for _, id in ipairs({1, 2, 3, 4, 5, 6}) do W2.unit(id).status.labors.MINE = nil end   -- the labor itself is missing
  days(W2, 4)
  local ev = W2.find_events('TOOL_BLOCKED')
  T.ok(#ev >= 1 and (',' .. ev[1].d.bk .. ','):find(',labor,', 1, true), ev[1] and ev[1].d.bk)
  days(W2, 12)
  T.eq(want_of(W2, 'pick'), nil, 'a member-side cause (labor) is no reason to say the picks are unusable')
end)

---------------------------------------------------------------- note 34
T.test('BUG-053 note 34 (Run 12 y501, a reclaimed fort): 100 usable picks lie loose; after pile_days a stockpile '
       .. 'dfllm-tools stands near the open dig jobs, restricted to picks and axes; after stale_days new picks are asked', function()
  local W, ctl = world{miners = {1, 2, 3, 4, 5, 6}, picks = 100, pick_pos = {30, 40, 5}, dig = 14}
  days(W, 6)
  T.eq(#ctl.piles, 0, 'not before pile_days (7)')
  days(W, 3)
  T.eq(#ctl.piles, 1, 'one tool pile')
  local p = ctl.piles[1]
  T.eq({p.w, p.h}, {3, 2})
  T.ok(p.pos[3] == FLOOR.z and math.abs(p.pos[1] - 62) <= 12 and math.abs(p.pos[2] - 40) <= 12,
       'near the dig jobs at 60-64,40,5: ' .. table.concat(p.pos, ','))
  for dx = 0, 2 do
    for dy = 0, 1 do
      local x, y = p.pos[1] + dx, p.pos[2] + dy
      T.ok(x >= FLOOR.x0 and x <= FLOOR.x1 and y >= FLOOR.y0 and y <= FLOOR.y1, 'the pile lies on revealed floor')
    end
  end
  local runs = F.runs(W)
  T.ok(F.has(runs, 'stockpiles import -m disable cat_weapons -s 901'), table.concat(runs, ' | '))
  T.ok(F.has(runs, 'stockpiles import -m enable cat_weapons -f pick,battle axe -s 901'), table.concat(runs, ' | '))
  W.ms = W.ms + 600000                                  -- util/cadence: a new cause (the pile) is news after 7 days and 10 minutes
  days(W, 2)
  local ev = W.find_events('TOOL_BLOCKED')
  T.ok(ev[#ev].d.pile and ev[#ev].d.pile:find('dfllm-tools placed at', 1, true), tostring(ev[#ev].d.pile))
  local r = W.inbox('inspect', {what = 'workload', key = 'tools'})
  T.eq(r.ok, true, r.msg)
  T.ok(r.data.pile and r.data.pile:find('dfllm-tools placed at', 1, true), tostring(r.data.pile))
  T.eq({r.data.piles, r.data.stale.pick}, {1, 0}, 'one pile; not stale yet (day 12 of 14)')
  days(W, 40)
  T.eq(W.inbox('inspect', {what = 'workload', key = 'tools'}).data.stale.pick, 100, 'the 100 loose picks are stale now')
  T.eq(#ctl.piles, 1, 'a pile named dfllm-tools stands: no second one')
  local n = 0
  for _, r in ipairs(F.runs(W)) do if r:find('stockpiles import', 1, true) then n = n + 1 end end
  T.eq(n, 2, 'the restriction is imported once')
  T.ok(want_of(W, 'pick'), 'the picks nobody got in 14 days are no stock')
end)

T.test('BUG-053: the miners ask for the equipment update again when the tools have a home (not after repair_days)', function()
  local W, ctl = world{miners = {1, 2, 3, 4, 5, 6}, picks = 20, dig = 14, repair_days = 100}
  local function forced()
    local n = 0
    for _, c in ipairs(ctl.wd_opts) do if c.name == 'Miners' and c.opts and c.opts.equip == 'force' then n = n + 1 end end
    return n
  end
  days(W, 2)
  T.eq(forced(), 6, 'the first pass after the load: every member without a pick')
  days(W, 5)
  T.eq({forced(), #ctl.piles}, {6, 0}, 'repair_days (100) holds the requests back, the pile waits for pile_days (7)')
  days(W, 3)
  T.eq(#ctl.piles, 1)
  T.eq(forced(), 18, 'the pile placed and, a day later, restricted to picks and axes: the lacking members ask again each time')
  days(W, 5)
  T.eq(forced(), 18, 'and not again before repair_days')
end)

T.test('BUG-053: the pile switches: tools.pile false asks nothing; a pile that stands is not made again; pile_every holds '
       .. 'a refused attempt back', function()
  local W, ctl = world{miners = {1, 2, 3, 4, 5, 6}, picks = 20, dig = 14}
  W.K.cfg.baseline.economy.tools.pile = false
  days(W, 12)
  T.eq(#ctl.piles, 0)
  local W2, ctl2 = world{miners = {1, 2, 3, 4, 5, 6}, picks = 20, dig = 14, pile = true}
  days(W2, 12)
  T.eq(#ctl2.piles, 0, 'a pile named dfllm-tools already stands')
  local W3, ctl3 = world{miners = {1, 2, 3, 4, 5, 6}, picks = 20, dig = 14}
  W3.act_result('tool_pile', function() ctl3.refused = (ctl3.refused or 0) + 1; return false, 'quickfort designated no stockpile there' end)
  days(W3, 20)
  T.eq(ctl3.refused, 1, 'a refused try waits pile_every (28) days')
  days(W3, 20)
  T.eq(ctl3.refused, 2)
end)

T.test('BUG-053: no revealed floor near the mines: no pile, the reason is kept and logged once', function()
  local W, ctl = world{miners = {1, 2, 3, 4, 5, 6}, picks = 20, dig = 14}
  FLOOR.x1 = 41                                   -- a 2-wide strip: no 3x2 fits
  days(W, 10)
  FLOOR.x1 = 80
  T.eq(#ctl.piles, 0)
  local n = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('tool pile: no site', 1, true) then n = n + 1 end end
  T.eq(n, 1)
end)

T.test('BUG-053: the stale count is fixed when the tools turn stale: picks made later are stock again (no endless picks)', function()
  local W = world{miners = {1, 2, 3, 4, 5, 6}, picks = 16, pick_pos = {157, 57, 139}, held = {1}, dig = 14}
  days(W, 16)
  T.eq(want_of(W, 'pick').n, 5)
  for _ = 1, 5 do F.item(W, 'WEAPON', {subtype = 1, _pos = {30, 40, 5}}) end         -- five new picks, reachable
  days(W, 2)
  T.eq(want_of(W, 'pick'), nil, 'six usable picks for six members: nothing more is asked')
end)

T.test('BUG-053: no tool pile outside PEACE and RECOVERY', function()
  local W, ctl = world{miners = {1, 2, 3, 4, 5, 6}, picks = 20, dig = 14}
  W.K.set_mode('ALERT', 'test')
  days(W, 12)
  T.eq(#ctl.piles, 0)
  W.K.set_mode('PEACE', 'test')
  days(W, 3)
  T.eq(#ctl.piles, 1)
end)

---------------------------------------------------------------- forbidden and owned
T.test('BUG-053: all picks forbidden and the unforbid refused: forbidden is named first; owned picks: owned', function()
  local W = world{miners = {1, 2, 3, 4, 5, 6}, forb_picks = 100, dig = 14, refuse = true}
  days(W, 4)
  local ev = W.find_events('TOOL_BLOCKED')
  T.eq(#ev, 1)
  T.eq({ev[1].d.free, ev[1].d.forb}, {0, 100})
  T.eq(ev[1].d.bk:match('^[^,]+'), 'forbidden', ev[1].d.bk)
  T.ok(ev[1].d.blk:find('all 100 picks are forbidden', 1, true), ev[1].d.blk)
  local W2 = world{miners = {1, 2, 3, 4, 5, 6}, picks = 16, owned = 16, dig = 14}
  days(W2, 4)
  ev = W2.find_events('TOOL_BLOCKED')
  T.eq(#ev, 1)
  T.ok((',' .. ev[1].d.bk .. ','):find(',owned,', 1, true), ev[1].d.bk)
  T.ok(ev[1].d.blk:find('16 of 16 free picks are owned by a dwarf', 1, true), ev[1].d.blk)
  T.eq(#ev[1].d.blk > 0, true)
end)

T.test('BUG-053: the tool list prefers tools on the citizens\' walk group (8 listed: twelve far ones no longer fill it)', function()
  local W = world{miners = {1, 2, 3, 4, 5, 6}, picks = 12, pick_pos = {157, 57, 139}, dig = 14}
  for _ = 1, 3 do F.item(W, 'WEAPON', {subtype = 1, _pos = {30, 40, 5}}) end      -- three reachable ones come last
  days(W, 2)
  local list = package.loaded['dfllm.economy'].tool_list('pick')
  T.eq(#list, 8)
  local near = 0
  for _, e in ipairs(list) do if not e.far then near = near + 1 end end
  T.eq(near, 3, 'the three tools on the citizens\' group are listed although twelve far ones came first')
end)

T.done()
