-- selftest (WP1, 60 s): in-game invariants of the kernel. The periodic step runs the quick suite and
-- logs failures; the 'selftest' verb and `dfllm selftest` run quick or full and report {pass, fail}.
-- budget (FR-62): kernel ms per real second over the last minute (kern.costs(), cumulative) against the
-- budget for the fort size (util/sched.lua: 25 on the reference fort, more with more units); a failure
-- names the top cost owners and is logged again every 10 min while it lasts.
-- `dfllm selftest --mock` checks the scheduling contract on util/k_mock without touching the game;
-- `--exec FILE` (DFLLM_DEV=1 only, refused under the acceptance flag) runs a dev script, logged.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local fio = require('dfllm.io')
local actlib = require('dfllm.act')   -- only the pure allowlist matcher (A.allowed), no game writes
local sched = require('dfllm.util.sched')

local M = {name = 'selftest', every = {ms = 60000}, verbs = {}}
M.MIN_WINDOW_MS = 20000      -- the budget check needs at least this much history (else it passes)
M.RELOG_MS = 600000          -- a lasting failure is logged again this often

-- cumulative cost samples {ms, at, mods} taken at each periodic run (newest last, at most 3)
local samples = {}

local function owners(c, base, dt)
  local top = {}
  for k, v in pairs(c.mods) do
    local d = (v - (base.mods[k] or 0)) * 1000 / dt
    if d >= 0.5 then top[#top + 1] = {k, d} end
  end
  table.sort(top, function(a, b) return a[2] > b[2] end)
  local parts = {}
  for i = 1, math.min(3, #top) do parts[i] = string.format('%s %d', top[i][1], math.floor(top[i][2] + 0.5)) end
  return table.concat(parts, ', ')
end

-- ok, detail: kernel ms/s over the last minute <= the budget for the fort size
local function budget(K)
  local kern = package.loaded['dfllm.kern']
  local c = kern and kern.running and kern.running() and kern.costs()
  if not c then                                -- k_mock: the state's 10 s window against the base budget
    local k = K.view().k
    return type(k) == 'table' and k.ms_s <= sched.budget(nil)
  end
  local load = kern.load() or {units = -1}
  local limit = kern.budget()
  local base
  for i = #samples, 1, -1 do
    if c.at - samples[i].at >= M.MIN_WINDOW_MS then base = samples[i]; break end
  end
  if not base then return true end             -- right after boot: nothing to judge yet
  local dt = c.at - base.at
  local ms_s = (c.ms - base.ms) * 1000 / dt
  if ms_s <= limit then return true end
  return false, string.format('%d ms/s > %d for %d units over %d s (top %s)', math.floor(ms_s + 0.5), limit,
                              load.units, dt // 1000, owners(c, base, dt))
end

local CHECKS = {
  {'json', 'quick', function(K)
    local d = json.decode(json.encode({a = {1, 2}, b = 'Grüße', f = 2.5}))
    return d.a[2] == 2 and d.b == 'Grüße' and d.f == 3
  end},
  {'mode', 'quick', function(K) return C.TRANSITIONS[K.mode()] ~= nil end},
  {'marker', 'quick', function(K) return K.persist.get('marker') ~= nil end},
  {'state_fresh', 'quick', function(K)
    local v = K.view()
    return type(v.t) == 'table' and math.abs((v.t.wall or 0) - K.now().wall) <= 10
  end},
  {'budget', 'quick', budget},
  {'no_disabled', 'quick', function(K)
    local k = K.view().k
    return type(k) == 'table' and (k.disabled == nil or #k.disabled == 0)
  end},
  {'runtime_dir', 'full', function(K)
    local p = K.cfg.paths.save .. '/selftest.probe'
    local ok = fio.write(p, 'probe')
    local back = fio.read(p)
    os.remove(p)
    return ok and back == 'probe'
  end},
  {'persist', 'full', function(K)
    local d = K.persist.get('m.selftest') or {v = 2, runs = 0}
    d.runs = (math.tointeger(d.runs) or 0) + 1
    K.persist.set('m.selftest', d)
    return K.persist.get('m.selftest').runs == d.runs
  end},
  {'allowlist_blocks', 'full', function(K)
    local al = K.cfg.allowlist
    for _, b in ipairs(al.blocked or {}) do
      local cmd, rest = b:match('^([^ ]+) ?(.*)$')
      if cmd and cmd:sub(1, 1) ~= '-' and actlib.allowed(al, cmd, {rest}) then return false end
    end
    return not actlib.allowed(al, 'lua', {'print(1)'})
  end},
}

-- {pass, fail, failed = {names}, detail = {name = why}} (a check returns ok[, why])
function M.run(K, suite)
  suite = suite == 'full' and 'full' or 'quick'
  local pass, fail, failed, detail = 0, 0, {}, {}
  for _, c in ipairs(CHECKS) do
    if suite == 'full' or c[2] == 'quick' then
      local ok, r, why = pcall(c[3], K)
      if ok and r then pass = pass + 1
      else
        fail = fail + 1
        failed[#failed + 1] = c[1]
        if not ok then why = r end
        if why ~= nil then detail[c[1]] = tostring(why) end
      end
    end
  end
  return {pass = pass, fail = fail, failed = failed, detail = detail}
end

-- 'budget (41 ms/s > 33 ...), no_disabled'
function M.describe(r)
  local parts = {}
  for _, name in ipairs(r.failed) do
    parts[#parts + 1] = r.detail[name] and (name .. ' (' .. r.detail[name] .. ')') or name
  end
  return table.concat(parts, ', ')
end

function M.init(K)
  M.last, M.last_log = nil, nil
  samples = {}
end

function M.step(K)
  local r = M.run(K, 'quick')
  local key = table.concat(r.failed, ',')
  local now = K.now().ms
  if r.fail > 0 and (key ~= (M.last and M.last.key) or now - (M.last_log or now) >= M.RELOG_MS) then
    K.log('warn', 'selftest quick failed: %s', M.describe(r))
    M.last_log = now
  end
  r.key = key
  M.last = r
  local kern = package.loaded['dfllm.kern']
  local c = kern and kern.running and kern.running() and kern.costs()
  if c then
    samples[#samples + 1] = c
    if #samples > 3 then table.remove(samples, 1) end
  end
end

M.verbs.selftest = function(K, args)
  local suite = args.suite or 'quick'
  if suite ~= 'quick' and suite ~= 'full' then return false, 'suite must be quick or full' end
  local r = M.run(K, suite)
  local msg = string.format('%s: %d pass, %d fail', suite, r.pass, r.fail)
  if r.fail > 0 then msg = msg .. ' (' .. M.describe(r) .. ')' end
  return r.fail == 0, msg, {pass = r.pass, fail = r.fail}
end

-- scheduling contract on k_mock (no game access: globals stay untouched)
function M.mock_check()
  local kmock = require('dfllm.util.k_mock')
  local W = kmock.new{globals = false}
  local runs = {}
  W.load({name = 'test_cadence', every = {ticks = 25}, step = function(K) runs[#runs + 1] = K.now().tick end})
  W.run(100, {skip = 9})
  local ok = #runs == 4
  for i = 2, #runs do ok = ok and runs[i] - runs[i - 1] >= 25 end
  return {pass = ok and 1 or 0, fail = ok and 0 or 1, failed = ok and {} or {'cadence'}}
end

-- dev only: run a Lua file with K in scope
function M.exec(K, file)
  if not K.cfg.dev then return false, 'set DFLLM_DEV=1 to use --exec' end
  if K.cfg.acceptance then return false, 'refused: the save has the acceptance flag' end
  if type(file) ~= 'string' or not file:match('%.lua$') then return false, 'need a .lua file' end
  local chunk, err = loadfile(file, 't', setmetatable({K = K}, {__index = _G}))
  if not chunk then return false, err end
  K.log('warn', 'selftest --exec %s', file)
  local ok, res = pcall(chunk)
  return ok, tostring(res)
end

return M
