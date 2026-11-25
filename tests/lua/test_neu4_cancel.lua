-- NEU4 (BUG-841..846): DF's own reason is the source of truth. DF creates the jobs and cancels them with a reason; the kernel tallies the announcements
-- (cancelwhy.lua), says them in why / brew_watch / the stall line / the drink cause, counts stock the way DF can use it (wood 0 usable of 204), switches the
-- container cures on only while DF names the shortage, and the raw dumps are paged and sampled. Live states: i1 Diedplank (204 logs, 198 on tiles with no
-- walk group, 'Needs logs'), i2 Whirledrampart (348 barrels, 322 full, 7 phantom free, 400 cancels 'Needs empty food storage item').
-- acting cures of the 'fass' round behind economy.diag switches that default OFF, J.labors for a MakeBarrel job. Offline, against the fake world.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200
local BREWER, CARPENTER = 6, 7

local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, o.n or 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local base = F.cfg()
  if o.diag then base.economy.diag = o.diag end
  local W = F.world{cfg = {baseline = base}, units = units}
  if df.job_type.Dig == nil then df.job_type.Dig = 990; df.job_type[990] = 'Dig' end
  if df.job_type.MakeBarrel == nil then df.job_type.MakeBarrel = 991; df.job_type[991] = 'MakeBarrel' end
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER', CARPENTER = CARPENTER, [CARPENTER] = 'CARPENTER'}
  df.job_skill = df.job_skill or {}
  df.items_other_id = kmock.enum({'IN_PLAY', 'PLANT', 'PLANT_GROWTH', 'BARREL', 'FISH_RAW', 'FOOD_STORAGE', 'WOOD'})
  for _, v in ipairs({'PLANT', 'PLANT_GROWTH', 'BARREL', 'WOOD', 'FOOD_STORAGE'}) do rawset(df.global.world.items.other, v, rawget(df.global.world.items.other, v) or kmock.vec{}) end
  df.job_type.attrs = setmetatable({}, {__index = function() return {labor = -1, skill = -1} end})
  df.global.world.raws.reactions = {reactions = kmock.vec{
    {code = 'BREW_DRINK_FROM_PLANT', skill = 60, building = {type = kmock.vec{df.building_type.Workshop}, subtype = kmock.vec{df.workshop_type.Still}}}}}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.job.isSuitableItem = function() return true end
  dfhack.job.isSuitableMaterial = function() return true end
  dfhack.units.isJobAvailable = function(u) return u._m.avail ~= false end
  dfhack.units.getNominalSkill = function() return 0 end
  dfhack.units.isChild = function() return false end
  dfhack.units.isBaby = function() return false end
  for i = 1, o.n or 6 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
    u.burrows = kmock.vec{}
    u.flags1 = {}
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  for _, id in ipairs(o.brewers or {1, 2}) do W.unit(id).status.labors[BREWER] = true end
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 20000})
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end,
          groups = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[1] >= 500 and 2 or 1 end; return g end,
          hidden = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[2] >= 900 end; return g end})
  W.load(fresh('economy'))
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z, b.centerx, b.centery = 20, 20, 22, 22, 100, 21, 21
  b.getBuildStage = function() return 1 end
  b.getMaxBuildStage = function() return 1 end
  b.jobs = kmock.vec{}
  b.flags = {}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local ord = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = o.left or 5, amount_total = o.left or 5,
                          mat_type = -1, mat_index = -1, workshop_id = o.pinned or -1, status = {validated = true, active = true}, frequency = 0,
                          item_conditions = kmock.vec{{compare_type = 'AtLeast', compare_val = 1, item_type = -1, flags1 = {empty = true}, flags3 = {food_storage = true}}}})
  return W, b, ord
end

local function raw(W, key)
  return W.inbox('inspect', {what = 'raw', key = key})
end
local function text(r) return table.concat((r.data and r.data.lines) or {}, '\n') end

local CW = require('dfllm.cancelwhy')
local BREWWHY = 'Needs empty food storage item'
local function feed(econ, K, n, tick, why, job)
  for _ = 1, n do
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels ' .. (job or 'Brew drink from plant') .. ': ' .. (why or BREWWHY) .. '.'})
  end
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l.msg end end
end

-- 1. the tally -----------------------------------------------------------------------------------------------------------------------------
T.test('BUG-841 cancelwhy: a rolling tally per job kind and reason, bounded, the window drops old days', function()
  local t = CW.fresh()
  for i = 1, 400 do CW.note(t, 'Brew drink from plant', BREWWHY .. '.', 100 * 1200 + i) end
  for i = 1, 20 do CW.note(t, 'brew drink from fruit', 'Needs unrotten fermentable plant', 99 * 1200 + i) end
  CW.note(t, 'make wooden door', 'Needs logs.', 100 * 1200)
  local e = CW.top(t, 100 * 1200 + 5, 7, {'brew '})
  T.eq({e.kind, e.why, e.n, e.days}, {'brew drink from plant', BREWWHY, 400, 7})
  local txt = CW.text(e, 100 * 1200 + 5 + 2400)
  T.ok(txt:find('400x in 7 d: ' .. BREWWHY, 1, true) and txt:find('(last 1 d ago)', 1, true), txt)
  T.eq(CW.count(t, 100 * 1200 + 5, 7, {'brew '}, 'empty food storage'), 400)
  T.eq(CW.count(t, 120 * 1200, 7, {'brew '}, 'empty food storage'), 0, '20 days later the window is empty')
  local b = CW.fresh()
  for k = 1, 60 do CW.note(b, 'kind ' .. k, 'why', 5000 + k) end
  local nk = 0
  for _ in pairs(b.d[tostring(5000 // 1200)]) do nk = nk + 1 end
  T.ok(nk <= CW.MAX_KINDS + 1, 'kinds per day bounded: ' .. nk)
  local b2 = CW.fresh()
  for k = 1, 30 do CW.note(b2, 'one kind', 'reason ' .. k, 5000 + k) end
  local nr = 0
  for _ in pairs(b2.d[tostring(5000 // 1200)]['one kind']) do nr = nr + 1 end
  T.ok(nr <= CW.MAX_REASONS + 1, 'reasons per kind bounded: ' .. nr)
  CW.note(b, 'old', 'x', 5000 + 30 * 1200)
  T.eq(b.d[tostring(5000 // 1200)], nil, 'days past C.KEEP are pruned')
  T.eq(CW.norm(nil).v, 1)
end)

T.test('BUG-841 economy: CANCEL_JOB reports are tallied (persisted), df_reason names count, window and last tick', function()
  local W = world{}
  local econ = require('dfllm.economy')
  local t0 = 100 * 1200
  feed(econ, W.K, 12, t0)
  feed(econ, W.K, 3, t0 + 1200, 'Needs unrotten fermentable plant')
  local e = econ.df_reason(W.K, {'brew '}, nil, t0 + 2 * 1200)
  T.eq({e.why, e.n}, {BREWWHY, 12})
  T.ok(e.text:find('DF cancelled brew drink from plant 12x in 7 d: ' .. BREWWHY .. ' (last 2 d ago)', 1, true), e.text)
  local p = W.K.persist.get('m.economy')
  T.ok(type(p.cw) == 'table' and type(p.cw.d) == 'table', 'persisted m.economy cw')
  package.loaded['dfllm.economy'] = nil
  local econ2 = require('dfllm.economy')
  econ2.init(W.K)
  T.eq(econ2.df_count(W.K, {'brew '}, 'empty food storage', nil, t0 + 2 * 1200), 12, 'the tally survives a reload')
end)

-- 2. why / stall line / drink cause -------------------------------------------------------------------------------------------------------
T.test('BUG-841 jobwhy: the raw stall line and why name the DF reason verbatim with count, window and last tick; no reason seen stays a guess', function()
  local W, _, ord = world{left = 6}
  local econ = require('dfllm.economy')
  local now = W.K.now().tick
  feed(econ, W.K, 412, now)
  local r, err = econ.jw_ask(W.K, nil, 'order:' .. ord.id)
  T.ok(r, tostring(err))
  T.ok(r.text:find('DF cancelled brew drink from plant 412x in 7 d: ' .. BREWWHY, 1, true), r.text)
  T.ok(r.df and r.df.n == 412 and r.df.why == BREWWHY, T.show(r.df))
  T.ok(r.cause ~= 'unknown', 'DF words replace the guess: ' .. tostring(r.cause))
  local l = econ.stall_log(W.K, 'brew', 'brew')
  T.ok(l and l:find('raw stall brew: DF: DF cancelled brew drink from plant 412x in 7 d: ' .. BREWWHY, 1, true), tostring(l))
  local W2, _, ord2 = world{left = 6}
  local r2 = require('dfllm.economy').jw_ask(W2.K, nil, 'order:' .. ord2.id)
  T.ok(r2 and r2.df == nil and r2.cause ~= 'df_reason', 'no reason seen: ' .. tostring(r2 and r2.cause))
  local JW = require('dfllm.jobwhy')
  local m = JW.df_match({job = 'MakeBarrel'})
  T.ok(type(m) == 'function' and m('make wooden barrel') and not m('make wooden door'), 'Make barrel matches Make wooden barrel')
  T.eq(JW.df_match({job = 'BREW_DRINK_FROM_PLANT'})[1], 'brew ')
end)

T.test('BUG-841 drink cause: DF names the containers -> stock.dwhy leads with DF words (dcx); any other brew reason leads as well', function()
  local W = world{left = 32}
  local econ = require('dfllm.economy')
  local t0 = 100 * 1200
  feed(econ, W.K, 40, t0)
  local why = econ.drink_why(W.K, econ.conf(W.K), {days = {drink_d = 0}, inv = {brew_p = 100, barrels = 10, barrels_empty = 1, cont_free = 1}, now = t0, s = {live = {}}, p = W.K.persist.get('m.economy')})
  T.ok(why and why:find('DF cancels Brew 40x in 7 d: Needs empty food storage item', 1, true), tostring(why))
  T.ok(#why <= 80)
  local W2 = world{left = 32}
  local e2 = require('dfllm.economy')
  feed(e2, W2.K, 40, t0, 'Needs unrotten fermentable plant')
  local why2 = e2.drink_why(W2.K, e2.conf(W2.K), {days = {drink_d = 0}, inv = {brew_p = 100, barrels = 10, barrels_empty = 5, cont_free = 5}, now = t0, s = {live = {}}, p = W2.K.persist.get('m.economy')})
  T.ok(why2 and why2:find('DF cancels Brew 40x in 7 d: Needs unrotten fermentable plant', 1, true), tostring(why2))
end)

-- 3. i2: the cures, gated by DF's reason ---------------------------------------------------------------------------------------------------
local I2 = {brew_p = 1334, barrels = 325, barrels_empty = 7, cont_free = 7, pots = 12, pots_empty = 0}
local function brew_days(W, ord, n, inv, dfn, first)
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  p.orders['dfllm:drink'] = ord.id
  for i = (first or 1), (first or 1) + n - 1 do
    if dfn then feed(econ, W.K, dfn, (100 + i) * 1200) end
    econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = (100 + i) * 1200, p = p, inv = inv, days = {drink_d = 0}, cit = 6})
  end
  return econ, p
end

T.test('BUG-844 i2: 400 DF cancels "Needs empty food storage item" prove the container verdict (no "by my count"), the piles freeze, Carpentry is asked for', function()
  local W, _, ord = world{left = 30, n = 8}
  W.act_result('pile_barrels', function(mode) if mode == 'freeze' then return true, {{id = 41, old = -1, new = 9, name = 'plants'}} end return true, {} end)
  F.workshop(W, 'Carpenters')
  for _ = 1, 40 do F.item(W, 'WOOD', {}) end
  local sets = {}
  W.act_result('labor_set', function(id, which, on) sets[#sets + 1] = which; W.unit(id).status.labors[CARPENTER] = true; return true, 'enabled' end)
  local _, p = brew_days(W, ord, 8, I2, 60)
  local ev
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if tostring(e.msg):find('brewing stalled', 1, true) then ev = e end end
  T.ok(ev, 'the stall is told')
  local full = logged(W, 'brewing stalled') or ev.msg
  T.ok(full:find('DF cancelled Brew 420x in 7 d: ' .. BREWWHY, 1, true), full)
  T.ok(not full:find('by my count', 1, true), 'proven by DF, not a count: ' .. full)
  T.ok(p.contx and p.contx.ph == true, 'the 7 free barrels DF never takes count as 0: ' .. T.show(p.contx))
  local first
  for _, a in ipairs(W.find_acts('pile_barrels')) do if a.args[1] ~= 'zero_mood' then first = first or a end end   -- round 6: the mood piles' one-off call is no freeze
  T.eq(first.args[1], 'freeze')
  T.ok(p.pilecap and p.pilecap['41'] == -1 and p.pilet, 'frozen with a stamp')
  W.K.persist.get('m.economy').contx.since, W.K.persist.get('m.economy').contx.untl = 0, 1e12     -- the daily run at the test clock's own time
  feed(require('dfllm.economy'), W.K, 8, W.K.now().tick)
  for _ = 1, 3 do W.run(1200, {skip = 100}); for _ = 1, 40 do W.run(1) end end
  local carp = 0
  for _, s in ipairs(sets) do if s == 'carpenter' then carp = carp + 1 end end
  T.ok(carp >= 2, 'Carpentry on for citizens: ' .. T.show(sets))
end)

T.test('BUG-844: no DF reason -> no cure (no freeze, no labor), cx_cure on or not; 4 cancels are below cancel.cx_min_n, 5 pass', function()
  local W, _, ord = world{left = 30, n = 8}
  W.act_result('pile_barrels', function() return true, {{id = 41, old = -1, new = 9, name = 'x'}} end)
  F.workshop(W, 'Carpenters')
  for _ = 1, 40 do F.item(W, 'WOOD', {}) end
  W.act_result('labor_set', function() return true, 'enabled' end)
  local _, p = brew_days(W, ord, 30, I2, nil)
  T.eq(#W.find_acts('pile_barrels'), 0)
  T.eq(#W.find_acts('labor_set'), 0)
  T.eq(p.pilecap, nil)
  local W3 = world{left = 30, n = 8}
  local econ3 = require('dfllm.economy')
  feed(econ3, W3.K, 4, 101 * 1200)
  T.eq(econ3.cx_gate(W3.K, nil, 102 * 1200), false, '4 cancels: below the minimum of 5')
  feed(econ3, W3.K, 1, 101 * 1200)
  T.eq(econ3.cx_gate(W3.K, nil, 102 * 1200), 5, '5 cancels pass')
  local W4 = world{left = 30, diag = {cx_cure = false, mgr_chores = false, still_pin = false, stall_line = true}}
  feed(econ3, W4.K, 50, 101 * 1200)
  T.eq(econ3.cx_gate(W4.K, nil, 102 * 1200), false, 'the switch off: reasons are reported, nothing acts')
end)

T.test('BUG-844: the pile freeze is given back when DF stops cancelling, and after cx_pile_days it is not frozen again at once', function()
  local W, _, ord = world{left = 30}
  W.K.cfg.baseline.economy.cancel.stand = false          -- NEU13 BUG-888: the standing cap has no timer and no give-back on a gone reason; this tests the timed freeze
  local back
  W.act_result('pile_barrels', function(mode, arg)
    if mode == 'freeze' then return true, {{id = 41, old = 12, new = 9, name = 'plants'}} end
    back = arg
    return true, {{id = 41, new = 12}}
  end)
  local _, p = brew_days(W, ord, 8, I2, 20)
  T.ok(p.pilecap and p.pilecap['41'] == 12, 'frozen')
  local econ = require('dfllm.economy')
  econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = 130 * 1200, p = p, inv = I2, days = {drink_d = 0}, cit = 6})
  T.eq(back and back['41'], 12, 'the old limit came back when the reason disappeared')
  T.eq(p.pilecap, nil)
  local W2, _, ord2 = world{left = 30}
  W2.K.cfg.baseline.economy.cancel.stand = false
  local frz, rest = 0, 0
  W2.act_result('pile_barrels', function(mode)
    if mode == 'freeze' then frz = frz + 1; return true, {{id = 41, old = 12, new = 9, name = 'plants'}} end
    rest = rest + 1
    return true, {{id = 41, new = 12}}
  end)
  local _, p2 = brew_days(W2, ord2, 30, I2, 20)
  T.ok(rest >= 1, 'the freeze ended after cancel.cx_pile_days although DF still cancels')
  T.eq(p2.pilecap, nil, 'and is not renewed right away')
  T.ok(p2.pilex ~= nil, 'the expiry is stamped')
end)

T.test('BUG-844/845: act.pile_barrels never freezes a pile that holds no barrel; labor.set knows the woodcutter', function()
  local sp = {id = 41, name = 'empty pile', x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 5, max_barrels = -1,
              settings = {flags = {food = true}, food = {drink_plant = kmock.vec{false}, drink_animal = kmock.vec{false}}}}
  df.global.world.buildings.other.STOCKPILE = kmock.vec{sp}
  rawset(df.global.world.items.other, 'BARREL', kmock.vec{})
  local actlib = require('dfllm.act')
  local api = actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end, log_cmd = function() end, fail = function() end}
  local ok, res = api.pile_barrels('freeze', {})
  T.ok(ok and #res == 0 and sp.max_barrels == -1, T.show(res))
  T.ok(actlib.LABOR_SETS.woodcutter.name == 'CUTWOOD' and actlib.LABOR_SETS.woodcutter.on == true, 'labor.set woodcutter')
end)

-- 4. the census: DF's view ---------------------------------------------------------------------------------------------------------------
local function census_world(setup)
  local W = F.world{cfg = {baseline = F.cfg()}, units = (function() local u = {}; for i = 1, 6 do u[i] = {id = i, citizen = true} end; return u end)()}
  local ids = {}
  for i = 1, 6 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  setup(W)
  local snap = {name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end,
                groups = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[1] >= 500 and 0 or (p[1] >= 300 and 2 or 1) end; return g end,
                hidden = function(_, pts) local g = {}; for i = 1, #pts do g[i] = false end; return g end}
  function snap.far(K, x, y, z, strict)
    if x >= 500 then return strict == true, strict == true and 'nowalk' or nil end
    if x >= 300 then return true end
    return false
  end
  W.load(snap)
  W.load(fresh('economy'))
  return W
end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

T.test('BUG-842 i1 Diedplank: 204 logs, 198 on tiles with no walk group, 5 in buildings, 1 on another group: wood 0 usable of 204; DF "Needs logs" names it', function()
  local W = census_world(function(W)
    for _ = 1, 198 do F.item(W, 'WOOD', {_pos = {600, 5, 1}}) end
    for _ = 1, 5 do F.item(W, 'WOOD', {_pos = {5, 5, 1}, flags = {in_building = true}}) end
    F.item(W, 'WOOD', {_pos = {350, 5, 1}})
    F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
    F.item(W, 'DRINK', {stack_size = 500})
  end)
  days(W, 1)
  local i = W.K.census.i
  T.eq({i.wood, i.wood_far, i.wood_nw, i.wood_skip, i.wood_built}, {0, 199, 198, 0, 5}, 'census: usable 0; the 5 logs in buildings are built in (NEU7 BUG-855), not skipped stock')
  local st = W.K.call('economy', 'state')
  local stock = select(2, W.K.call('economy', 'state')).stock
  T.eq({stock.wood, stock.woodt, stock.woodb}, {0, 199, 5}, 'state: wood 0 usable of 199 loose, 5 built in')
  for _ = 1, 30 do W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Carpenter cancels Make wooden door: Needs logs.'}) end
  settle(W)
  local l = logged(W, 'DF cancels')
  T.ok(l and l:find('198 without, 1 on another group', 1, true) and l:find('why items:logs --raw', 1, true), tostring(l))
  local e = require('dfllm.economy').df_reason(W.K, function(k) return k:find('make', 1, true) == 1 end)
  T.ok(e and e.why == 'Needs logs' and e.n == 30, T.show(e))
end)

T.test('BUG-842/843 i2 Whirledrampart: 348 barrels (322 full, 8 forbidden, 11 in buildings, 4 trader, 7 free) + 3 empties out of reach: free = 7; the dump sample describes items', function()
  local W = census_world(function(W)
    for _ = 1, 322 - 8 - 11 - 4 do F.item(W, 'BARREL', {_contents = {{id = 1}}, _pos = {5, 5, 1}}) end
    for _ = 1, 8 do F.item(W, 'BARREL', {flags = {forbid = true}, _pos = {5, 5, 1}}) end
    for _ = 1, 11 do F.item(W, 'BARREL', {flags = {in_building = true}, _pos = {5, 5, 1}}) end
    for _ = 1, 4 do F.item(W, 'BARREL', {flags = {trader = true}, _pos = {5, 5, 1}}) end
    for _ = 1, 7 do F.item(W, 'BARREL', {_pos = {6, 6, 1}}) end
    for _ = 1, 3 do F.item(W, 'BARREL', {_pos = {600, 6, 1}}) end
    F.item(W, 'DRINK', {stack_size = 500})
  end)
  days(W, 1)
  local i = W.K.census.i
  T.eq({i.barrels_empty, i.cont_free}, {10, 7}, 'strict far: the 3 unreachable empties are not free')
  local stock = select(2, W.K.call('economy', 'state')).stock
  T.eq({stock.cont, stock.contt}, {7, 10}, 'state: containers 7 usable of 10 empty')
  local r = raw(W, 'items:barrels')
  T.ok(r.ok, T.show(r))
  local t = text(r)
  T.ok(t:find('sample (', 1, true), 'a per-item sample: ' .. t)
  T.ok(t:find('reason=unwalkable_tile', 1, true) and t:find('reason=none (free as DF sees it)', 1, true), t)
  T.ok(t:find('at 6,6,1 ', 1, true) and t:find('flags=[', 1, true) and t:find('contents=0', 1, true), t)
end)

-- 5. the dumps ---------------------------------------------------------------------------------------------------------------------------
T.test('BUG-846: a dump longer than one reply is paged (never > 8 KB, never empty); brew lists orders first and summarizes the Stills', function()
  local RAW = require('dfllm.dfraw')
  local lines = {}
  for i = 1, 140 do lines[i] = string.rep('x', 200) .. i end
  local l1, p1, n = RAW.paginate(lines, 1)
  T.ok(n >= 4 and p1 == 1 and #l1 < 140, 'pages: ' .. n)
  local json = require('dfllm.util.json')
  T.ok(#json.encode({lines = l1}) < 8000, 'a page fits the 8 KB reply limit')
  local l3, p3 = RAW.paginate(lines, 3)
  T.eq(p3, 3)
  T.ok(l3[1] ~= l1[1])
  T.eq(({RAW.paginate(lines, 99)})[2], n, 'a page past the end is the last')
  local W, b, ord = world{left = 6}
  for _ = 2, 12 do F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 3, amount_total = 3, mat_type = -1, mat_index = -1,
                               workshop_id = -1, status = {validated = true}, item_conditions = kmock.vec{}}) end
  for k = 1, 6 do
    local s = F.workshop(W, 'Still')
    s.x1, s.y1, s.x2, s.y2, s.z = 40 + 5 * k, 20, 42 + 5 * k, 22, 100
    s.jobs, s.flags = kmock.vec{}, {}
    s.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}}
  end
  local r = raw(W, 'brew')
  T.ok(r.ok, T.show(r))
  local t = text(r)
  T.ok(t:find('brew cancel snapshot:', 1, true) == 1, 'BUG-887 round 5: the snapshot block comes first: ' .. t:sub(1, 120))
  T.ok(t:find('brew: ', 1, true) and t:find('still ', 1, true), t:sub(1, 300))
  T.ok(t:find('full sheet: why ws:', 1, true), 'Stills are summarized, not dumped')
  local nfull = select(2, t:gsub('shops for this order:', ''))
  T.ok(nfull <= 12, 'orders: ' .. nfull)
  T.ok(#json.encode(r.data) < 8192, 'the reply fits: ' .. #json.encode(r.data))
end)

T.done()
