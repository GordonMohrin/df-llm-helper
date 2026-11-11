-- BUG-751 (Run 16c i3 Doorwings y388-y391: seven citizens died of thirst on the walkable tops of the unfinished bedroom block, a HuntVermin
-- job led them there, CUTOFF 'cause not found'): (1) CUTOFF names the wall top and the drop, and the cut citizen's job; a trip job excuses
-- a citizen for two days only; (2) the errand of a citizen on a group with drink and food whose target lies on a group without is
-- cancelled (act.cancel_stray_job), the others stay; (3) seal.separator names the tile for STRANDED.
-- BUG-752 (Run 16d i4 Pagedsculpture y386/y391: citizens 'missing in the unit list', then found dead): MISSING (A) for a citizen off the
-- map or cut off for days, once per episode, with the last position and the job.
local T = require('testlib')
local SW = require('seal_world')

local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end
local function evs(W, t) return W.find_events(t) end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end

-- room A x2-8 y2-8 (drink, food), corridor y5, room B x12-18 y2-8; z6 above the wall at y9-10 x12-14: a walkable top (its own group),
-- one level over the floor of room B at y8
local Z = 5
local HUNT = 301
local function fort(opts)
  opts = opts or {}
  local W = SW.new{}
  df.job_type.HuntVermin, df.job_type[HUNT] = HUNT, 'HuntVermin'
  SW.fill(W, Z, 0, 0, 20, 12, '#')
  SW.fill(W, Z, 2, 2, 8, 8, '.')
  SW.fill(W, Z, 12, 2, 18, 8, '.')
  SW.fill(W, Z, 9, 5, 11, 5, '.')
  if not opts.rock then SW.fill(W, Z, 12, 9, 14, 10, 'C') end        -- a constructed wall (else natural rock) under the top
  SW.fill(W, Z + 1, 12, 9, 14, 10, '.')
  SW.draw(W, Z, {'bb'}, 3, 3)
  SW.regroup(W)
  local list = {{1, 4, 4, Z}, {2, 5, 5, Z}, {3, 14, 4, Z}, {4, 15, 5, Z}, {5, 16, 6, Z}}
  if opts.top then list[#list + 1] = {6, 13, 9, Z + 1} end
  SW.citizens(W, list)
  SW.item(W, 'DRINK', 6, 6, Z, 10)
  SW.item(W, 'PLANT', 7, 7, Z, 20)
  SW.item(W, 'SEEDS', 16, 7, Z, 5)
  W.cancelled = {}
  W.act_result('cancel_stray_job', function(id)
    local u = W.unit(id)
    local j = u.job and u.job.current_job
    if not j then return true, 'no job' end
    W.cancelled[#W.cancelled + 1] = id
    u.job = {current_job = nil}
    return true, 'HuntVermin'
  end)
  if opts.setup then opts.setup(W) end
  local M = seal()
  W.load(M)
  return W, M
end

T.test('CUTOFF names the wall top and the drop; a citizen with no job is cut off at once', function()
  local W = fort{top = true}
  W.run(600, {skip = 9})
  local ev = evs(W, 'CUTOFF')
  T.eq(#ev, 1)
  T.eq({ev[1].d.cls, ev[1].d.why, ev[1].d.pos, ev[1].d.unit, ev[1].d.upos}, {'food', 'wall top', {13, 9, Z + 1}, 6, {13, 9, Z + 1}})
  T.ok(ev[1].msg:find('wall top at 13,9,6 (drop to 12,8,5)', 1, true), ev[1].msg)
end)

T.test('a top over natural rock is a rock top', function()
  local W = fort{top = true, rock = true}
  W.run(600, {skip = 9})
  T.eq(evs(W, 'CUTOFF')[1].d.why, 'rock top')
end)

T.test('a trip job (HuntVermin) excuses the citizen for two days, then CUTOFF names the job', function()
  local W = fort{top = true, setup = function(W)
    W.unit(6).job = {current_job = {id = 77, job_type = HUNT, pos = {x = 13, y = 9, z = Z + 1}}}
  end}
  W.run(600, {skip = 9})
  T.eq(#evs(W, 'CUTOFF'), 0, 'on a trip')
  W.run(5 * 1200, {skip = 9})
  local ev = evs(W, 'CUTOFF')
  T.eq(#ev, 1)
  T.eq({ev[1].d.why, ev[1].d.job, ev[1].d.pos}, {'wall top', 'HuntVermin', {13, 9, Z + 1}})
  T.ok(ev[1].msg:find('job HuntVermin', 1, true), ev[1].msg)
end)

T.test('seal.separator names the tile, the drop and the job for STRANDED', function()
  local W = fort{top = true, setup = function(W)
    W.unit(6).job = {current_job = {id = 77, job_type = HUNT, pos = {x = 13, y = 9, z = Z + 1}}}
  end}
  W.run(600, {skip = 9})
  local ok, r = W.K.call('seal', 'separator', {13, 9, Z + 1}, 6)
  T.ok(ok and r, 'separator')
  T.eq({r.pos, r.kind, r.to, r.job}, {{13, 9, Z + 1}, 'wall top', 'drop to 12,8,5', 'HuntVermin'})
  local ok2, r2 = W.K.call('seal', 'separator', {4, 4, Z}, 1)
  T.eq(r2, nil, 'a group with drink and food has no separator')
end)

T.test('an errand to a group without drink and food is cancelled, an errand in the fort stays', function()
  local W = fort{setup = function(W)
    W.unit(1).job = {current_job = {id = 71, job_type = HUNT, pos = {x = 13, y = 9, z = Z + 1}}}   -- the wall top
    W.unit(2).job = {current_job = {id = 72, job_type = HUNT, pos = {x = 14, y = 5, z = Z}}}        -- room B
  end}
  W.run(900, {skip = 9})
  T.eq(W.cancelled, {1})
  T.ok(W.unit(2).job.current_job ~= nil, 'the errand inside stays')
  T.ok(logged(W, 'of citizen 1 cancelled'), 'kern.log names it')
  W.run(3000, {skip = 9})
  T.eq(W.cancelled, {1}, 'once')
end)

T.test('MISSING (A): off the map and cut off for days, once, with the last position and job', function()
  local W = fort{top = true, setup = function(W)
    W.unit(6).job = {current_job = {id = 77, job_type = HUNT, pos = {x = 13, y = 9, z = Z + 1}}}
    W.add_unit{id = 7, pos = {}, citizen = true}
    local cu = W.K.census.u
    local ids = {1, 2, 3, 4, 5, 6, 7}
    W.set_census('u', {tick = 0, cit = 7, adults = 7, children = 0, soldiers = 0, ids = ids, soldier_ids = {},
                       outside = 0, outside_ids = {}, on_bridge = {}, stressed = 0, caged = {}})
  end}
  W.run(600, {skip = 9})
  T.eq(#evs(W, 'MISSING'), 0, 'not yet')
  W.run(5 * 1200, {skip = 9})
  local ev = evs(W, 'MISSING')
  local by = {}
  for _, e in ipairs(ev) do by[e.d.unit] = e end
  T.ok(by[6] and by[7], 'two missing: ' .. #ev)
  T.eq({by[6].cls, by[6].d.why, by[6].d.pos, by[6].d.job}, {'A', 'cut', {13, 9, Z + 1}, 'HuntVermin'})
  T.eq(by[7].d.why, 'off_map')
  W.run(3 * 1200, {skip = 9})
  T.eq(#evs(W, 'MISSING'), 2, 'once per episode')
end)

-- the real act.lua: act.cancel_stray_job takes down one outdoor errand of a living citizen and nothing else; owned by seal
T.test('act.cancel_stray_job: an outdoor errand goes, any other job stays, only seal may', function()
  local H = require('kern_world')
  local actlib = require('dfllm.act')
  local W = H.world{tag = 'straycancel', units = {{id = 7, citizen = true}, {id = 8, citizen = true}, {id = 9, dead = true}, {id = 10, citizen = true}}}
  df.job_type = {HuntVermin = 301, PlantSeeds = 302, Mine = 303}
  local removed, dropped = {}, {}
  dfhack.job = {removeWorker = function(j) dropped[#dropped + 1] = j.id; return true end,
                removeJob = function(j) removed[#removed + 1] = j.id; return true end}
  W.unit(7).job = {current_job = {id = 1, job_type = 301}}
  W.unit(8).job = {current_job = {id = 2, job_type = 303}}
  W.unit(9).job = {current_job = {id = 3, job_type = 301}}
  W.unit(10).job = {current_job = nil}
  local env = {who_v = 'seal', fails = {}}
  env.api = actlib.new{who = function() return env.who_v end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
                       log_cmd = function() end, fail = function(fn, err, module) env.fails[#env.fails + 1] = {fn, err, module} end}
  T.eq({env.api.cancel_stray_job(7)}, {true, 'HuntVermin'})
  T.eq({removed, dropped}, {{1}, {1}})
  T.eq({env.api.cancel_stray_job(8)}, {false, 'not an outdoor errand'})
  T.eq({env.api.cancel_stray_job(9)}, {false, 'not a living citizen'})
  T.eq({env.api.cancel_stray_job(10)}, {true, 'no job'})
  T.eq({env.api.cancel_stray_job(99)}, {false, 'no unit 99'})
  T.eq(removed, {1})
  env.who_v = 'economy'
  T.eq({env.api.cancel_stray_job(7)}, {false, 'not owner'})
  T.eq(removed, {1})
end)

T.done()
