-- selftest (WP1, 60 s): in-game invariants of the kernel. The periodic step runs the quick suite and
-- logs failures; the 'selftest' verb and `dfllm selftest` run quick or full and report {pass, fail}.
-- `dfllm selftest --mock` checks the scheduling contract on util/k_mock without touching the game;
-- `--exec FILE` (DFLLM_DEV=1 only, refused under the acceptance flag) runs a dev script, logged.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local fio = require('dfllm.io')
local actlib = require('dfllm.act')   -- only the pure allowlist matcher (A.allowed), no game writes

local M = {name = 'selftest', every = {ms = 60000}, verbs = {}}

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
  {'budget', 'quick', function(K)
    local k = K.view().k
    return type(k) == 'table' and k.ms_s <= 25
  end},
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

function M.run(K, suite)
  suite = suite == 'full' and 'full' or 'quick'
  local pass, fail, failed = 0, 0, {}
  for _, c in ipairs(CHECKS) do
    if suite == 'full' or c[2] == 'quick' then
      local ok, r = pcall(c[3], K)
      if ok and r then pass = pass + 1 else fail = fail + 1; failed[#failed + 1] = c[1] end
    end
  end
  return {pass = pass, fail = fail, failed = failed}
end

function M.init(K) M.last = nil end

function M.step(K)
  local r = M.run(K, 'quick')
  local key = table.concat(r.failed, ',')
  if r.fail > 0 and key ~= (M.last and M.last.key) then K.log('warn', 'selftest quick failed: %s', key) end
  r.key = key
  M.last = r
end

M.verbs.selftest = function(K, args)
  local suite = args.suite or 'quick'
  if suite ~= 'quick' and suite ~= 'full' then return false, 'suite must be quick or full' end
  local r = M.run(K, suite)
  local msg = string.format('%s: %d pass, %d fail', suite, r.pass, r.fail)
  if r.fail > 0 then msg = msg .. ' (' .. table.concat(r.failed, ', ') .. ')' end
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
