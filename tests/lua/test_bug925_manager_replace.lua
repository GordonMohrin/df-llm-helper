-- NEU19 BUG-925 (Run 17 i2 Whirledrampart y564: manager Cerol, a hospital patient for ~2,900 game days, 66 orders unvalidated, `appoint {"code":"MANAGER","unit":29544}` said
-- "MANAGER is alive and among the citizens (no replacement)", the kernel only warned once, manager_absent): a manager who cannot work (resting / injured) for
-- orders.manager_replace_days (30) while orders wait is replaced by the best free adult citizen; the verb `appoint replace:true` takes the same case.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local HF = 5443
-- 8 citizens; unit 2 is the manager (hf 5443, resting); the others' roles are set per test
local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, 8 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  df.job_skill.ORGANIZATION, df.job_skill[44] = 44, 'ORGANIZATION'
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs({'Rest', 'ConstructCoffin', 'ManageWorkOrders'}) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
  local ids = {}
  for i = 1, 8 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.hist_figure_id = 100 + i
    u.mood = -1
    u._m.skills = {ORGANIZATION = i}                     -- the best free one is the highest id that is fit
  end
  W.set_census('u', F.census_u(ids))
  df.global.plotinfo.main = {fortress_entity = {positions = {
    own = kmock.vec{{id = 3, code = 'MANAGER', flags = {ACTIVE = true}}},
    assignments = kmock.vec{{id = 1, position_id = 3, histfig = HF, histfig2 = HF}}}}}
  local mg = W.unit(2)
  mg.hist_figure_id = HF
  mg._m.name = 'Cerol Quillkeeper, Manager'
  mg.job.current_job = {id = 902, job_type = df.job_type.Rest}
  W.calls = {}
  W.act_result('appoint', function(code, id, replace)
    W.calls[#W.calls + 1] = {code, id, replace}
    if W.refuse then return false, 'refused by the fake' end
    for _, a in ipairs(df.global.plotinfo.main.fortress_entity.positions.assignments) do
      if a.position_id == 3 then a.histfig, a.histfig2 = 100 + id, 100 + id end
    end
    W.unit(id).job = {current_job = {id = 990}}
    return true, 7
  end)
  F.order(W, {job_type = df.job_type.ConstructCoffin, mat_type = -1, mat_index = -1, amount_left = 4,
              material_category = {wood = true}, status = {validated = false}, _name = 'Construct wooden coffin'})
  if opts.setup then opts.setup(W) end
  local E = fresh('economy')
  W.load(E)
  return W, E
end
local function events(W)
  local out = {}
  for _, e in ipairs(W.find_events('MANAGER_REPLACED')) do out[#out + 1] = e end
  return out
end

T.test('BUG-925: a manager resting 30 game days with orders waiting is replaced by the best FREE adult (never a soldier, a child, a patient, a unit in a mood); one event', function()
  local W = world{setup = function(W)
    W.unit(8).military.squad_id = 4                                   -- the best skill, but a soldier on duty
    W.unit(7)._m.adult = false                                         -- a child
    W.unit(6).health = {flags = {needs_healthcare = true}}             -- a patient
    W.unit(5).mood = 3                                                 -- in a strange mood
  end}
  days(W, 28)
  T.eq(#W.calls, 0, 'not before 30 days')
  days(W, 4)
  T.eq(#W.calls, 1, 'one appointment')
  T.eq(W.calls[1], {'MANAGER', 4, true}, 'unit 4: the highest ORGANIZATION among the free adults')
  local ev = events(W)
  T.eq(#ev, 1, 'one event')
  T.eq({ev[1].d.code, ev[1].d.old, ev[1].d.new, ev[1].d.how}, {'MANAGER', 2, 4, 'kernel'})
  T.ok(ev[1].d.days >= 30 and ev[1].d.why == 'resting/injured', ev[1].msg)
  T.ok(ev[1].msg:find('unit 2', 1, true) and ev[1].msg:find('unit 4', 1, true), ev[1].msg)
  T.eq(W.unit(2).job.current_job.job_type, df.job_type.Rest, 'the old manager is not touched')
  days(W, 40)
  T.eq(#W.calls, 1, 'the new manager works: nothing more')
  T.eq(#events(W), 1)
end)

T.test('BUG-925: bounded - a manager who still cannot work after the replacement is replaced again only after another span; no candidate: no appointment, no event', function()
  local W = world{}
  W.act_result('appoint', function(code, id, replace) W.calls[#W.calls + 1] = {code, id, replace}; return true, 7 end)   -- the fake does not change the holder
  days(W, 31)
  T.eq(#W.calls, 1)
  days(W, 25)
  T.eq(#W.calls, 1, 'one per position per span (30 days)')
  days(W, 10)
  T.eq(#W.calls, 2, 'the next span')
  local W2 = world{setup = function(W) for i = 1, 8 do if i ~= 2 then W.unit(i).military.squad_id = 4 end end end}
  days(W2, 40)
  T.eq(#W2.calls, 0, 'only soldiers: nobody to appoint')
  T.eq(#events(W2), 0)
end)

T.test('BUG-925: a manager who works (not resting, nothing waiting) is never replaced; config manager_replace_days 0 switches it off', function()
  local W = world{setup = function(W) W.unit(2).job.current_job = {id = 903} end}
  days(W, 45)
  T.eq(#W.calls, 0, 'a working manager')
  local W2 = world{setup = function(W) W.K.cfg.baseline.economy.orders = {manager_days = 3, unval_days = 2, manager_replace_days = 0} end}
  days(W2, 45)
  T.eq(#W2.calls, 0, 'off')
end)

T.test('BUG-925: verb appoint replace:true takes a manager who cannot work after the span (the fit unit only), refuses clearly before it and for a healthy manager', function()
  local W = world{}
  W.refuse = true                                                    -- the kernel's own tries are refused by the fake
  days(W, 5)
  local r = W.inbox('appoint', {code = 'MANAGER', unit = 8, replace = true})
  T.eq(r.ok, false)
  T.ok(r.msg:find('replace refused', 1, true) and r.msg:find('unable to work for 4 of 30 days', 1, true), r.msg)
  days(W, 26)                                                          -- the kernel's own try at day 30 was refused by the fake
  T.ok(#W.calls >= 1, 'the kernel tried and was refused')
  W.refuse = false
  local tries = #W.calls
  W.unit(8).military.squad_id = 4
  r = W.inbox('appoint', {code = 'MANAGER', unit = 8, replace = true})
  T.eq(r.ok, false)
  T.ok(r.msg:find('squad member', 1, true), r.msg)
  W.unit(8).military.squad_id = -1
  W.unit(8).health = {flags = {needs_healthcare = true}}
  r = W.inbox('appoint', {code = 'MANAGER', unit = 8, replace = true})
  T.eq({r.ok}, {false})
  T.ok(r.msg:find('patient or resting', 1, true), r.msg)
  W.unit(8).health = nil
  r = W.inbox('appoint', {code = 'MANAGER', unit = 8, replace = true})
  T.eq(r.ok, true, r.msg)
  T.eq(#W.calls, tries + 1)
  T.eq(W.calls[#W.calls], {'MANAGER', 8, true})
  local ev = events(W)
  T.eq(#ev, 1)
  T.eq({ev[1].d.old, ev[1].d.new, ev[1].d.how}, {2, 8, 'verb'})
  -- a healthy manager: the old refusal stays
  local W2 = world{setup = function(W) W.unit(2).job.current_job = {id = 903} end}
  days(W2, 40)
  local r2 = W2.inbox('appoint', {code = 'MANAGER', unit = 8, replace = true})
  T.eq(r2.ok, false)
  T.ok(r2.msg:find('lives and stands among the citizens', 1, true), r2.msg)
end)

T.done()
