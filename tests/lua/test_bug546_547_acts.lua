-- BUG-546 / BUG-547: the two new act functions on the real act.lua. act.labor_set(unit, which, on) switches ONE labor of the labors screen,
-- only the way the kernel needs: `mechanic` on (a lever's link job needs a Mechanic), `farm` off (the manager at the fields validates
-- no order); anything else is refused. act.cancel_link_job(lever) takes down the LinkBuildingToTrigger jobs of one lever that no dwarf
-- works on (the only job removal besides cancel_own_lever_job) and nothing else; both are owned by one module each.
local T = require('testlib')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local actlib = require('dfllm.act')

local function mk(who)
  local env = {who_v = who, fails = {}}
  env.api = actlib.new{
    who = function() return env.who_v end,
    allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
    log_cmd = function() end,
    fail = function(fn, err, module) env.fails[#env.fails + 1] = {fn, err, module} end,
  }
  return env
end

T.test('act.labor_set: mechanic goes on for an adult living citizen, farm goes off; the other directions and other names are refused', function()
  local W = H.world{tag = 'labor', units = {{id = 7, citizen = true}, {id = 8, citizen = true, adult = false},
                                            {id = 9, dead = true}, {id = 10, citizen = true}}}
  df.unit_labor = {PLANT = 1, MECHANIC = 2}
  for _, id in ipairs({7, 8, 9, 10}) do W.unit(id).status.labors = {[1] = true, [2] = false} end
  local env = mk('economy')
  T.eq({env.api.labor_set(7, 'mechanic', true)}, {true, 'enabled'})
  T.eq(W.unit(7).status.labors, {[1] = true, [2] = true})
  T.eq({env.api.labor_set(7, 'mechanic', true)}, {true, 'already'})
  T.eq({env.api.labor_set(7, 'mechanic', false)}, {false, 'mechanic can only be switched on'})
  T.eq({env.api.labor_set(7, 'farm', true)}, {false, 'farm can only be switched off'})
  T.eq({env.api.labor_set(7, 'farm', false)}, {true, 'disabled'})
  T.eq(W.unit(7).status.labors, {[1] = false, [2] = true})
  T.eq({env.api.labor_set(7, 'farm', false)}, {true, 'already'})
  T.eq({env.api.labor_set(7, 'mason', true)}, {false, 'which must be mechanic, farm or cook'})
  T.eq({env.api.labor_set(8, 'mechanic', true)}, {false, 'not an adult living citizen'})
  T.eq({env.api.labor_set(9, 'mechanic', true)}, {false, 'not an adult living citizen'})
  T.eq({env.api.labor_set(99, 'farm', false)}, {false, 'no unit 99'})
  env.who_v = 'care'
  T.eq({env.api.labor_set(10, 'mechanic', true)}, {false, 'not owner'})
  T.eq(W.unit(10).status.labors[2], false)
end)

T.test('act.cancel_link_job: the unworked link jobs of one lever go, a job with a worker, a pull and other levers stay; only gate may', function()
  local W = H.world{tag = 'linkcancel'}
  df.building_type = {Trap = 20}
  df.trap_type = {Lever = 1}
  df.job_type = {PullLever = 223, LinkBuildingToTrigger = 146}
  df.building_trapst = {is_instance = function(_, b) return type(b) == 'table' and b._kind == 'trap' end}
  local removed = {}
  dfhack.job = {getWorker = function(j) return j._worker end,
                removeJob = function(j)
                  removed[#removed + 1] = j.id
                  for _, b in ipairs({W.lv1, W.lv2}) do
                    for i = #b.jobs - 1, 0, -1 do if b.jobs[i] == j then b.jobs:erase(i) end end
                  end
                  return true
                end}
  local function lever(id)
    local b = W.add_building{id = id, _kind = 'trap', trap_type = 1, x1 = 5, y1 = 5, x2 = 5, y2 = 5, z = 1}
    b.jobs = kmock.vec{}
    return b
  end
  W.lv1, W.lv2 = lever(31), lever(32)
  local j1 = {id = 1, job_type = 146}
  local j2 = {id = 2, job_type = 146, _worker = {id = 3}}
  local j3 = {id = 3, job_type = 223}
  local j4 = {id = 4, job_type = 146}
  W.lv1.jobs:insert('#', j1); W.lv1.jobs:insert('#', j2); W.lv1.jobs:insert('#', j3); W.lv2.jobs:insert('#', j4)
  local env = mk('gate')
  T.eq({env.api.cancel_link_job(31)}, {true, 1})
  T.eq(removed, {1})
  T.eq({#W.lv1.jobs, #W.lv2.jobs}, {2, 1})
  T.eq({env.api.cancel_link_job(31)}, {true, 0}, 'the job with a worker and the pull stay')
  T.eq(removed, {1})
  T.eq({env.api.cancel_link_job(5)}, {false, 'not a lever'})
  env.who_v = 'economy'
  T.eq({env.api.cancel_link_job(32)}, {false, 'not owner'})
  T.eq(#W.lv2.jobs, 1)
end)

T.done()
