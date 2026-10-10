-- WP8 modules on the REAL kernel (kern.lua + act.lua + persist.lua) with the repo's config files:
-- every baseline command must pass config/allowlist.json, state and persist must be written.
local T = require('testlib')
local H = require('kern_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function has_cmd(W, line)
  for _, c in ipairs(W.commands) do
    local parts = {}
    for i = 1, c.n do parts[#parts + 1] = tostring(c[i]) end
    if table.concat(parts, ' ') == line then return true end
  end
  return false
end

local function boot(tag)
  local units = {}
  for i = 1, 8 do units[i] = {id = i, citizen = true} end
  local W = H.world{tag = tag, units = units}
  F.install(W)
  for i = 1, 8 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.inventory = kmock.vec{}
    u.status = {current_soul = {personality = {emotions = kmock.vec{}}}}
  end
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true}})
  for _ = 1, 4 do F.item(W, 'DRINK', {stack_size = 5}) end
  local ok, msg = H.boot(W, {repo = F.REPO, modules = {fresh('baseline'), fresh('economy'), fresh('care')}})
  assert(ok, msg)
  local K = H.kern().K()
  K.census.u = F.census_u({1, 2, 3, 4, 5, 6, 7, 8})
  return W, K
end

T.test('real kernel: baseline applies through the real allowlist while paused', function()
  local W, K = boot('base')
  T.eq(K.cfg.baseline.v, 2, 'config/baseline.json loaded')
  H.run(W, 40, {paused = true})
  for _, line in ipairs({'control-panel enable autochop', 'control-panel enable pop-control', 'enable logistics',
                         'prioritize -aq defaults', 'autochop target 150 60', 'pop-control set wave-size 8',
                         'labormanager mode monitor', 'labormanager enable', 'seedwatch clear',
                         'seedwatch MUSHROOM_HELMET_PLUMP 0',
                         'ban-cooking booze honey milk oil tallow', 'tailor materials silk cloth yarn'}) do
    T.ok(has_cmd(W, line), 'not run: ' .. line)
  end
  for _, e in ipairs(H.events(W)) do
    if e.type == 'ACT_FAIL' then T.ok(e.d.fn ~= 'run', 'refused: ' .. e.msg) end
  end
  T.ok(K.call('baseline', 'done'))
  H.kern().stop('test')
  local p = json.decode(W.persist_raw['dfllm.m.baseline'])
  T.eq(p.done, 1)
end)

T.test('real kernel: economy and care publish state; kitchen exclusion through real act', function()
  local W, K = boot('state')
  H.run(W, 40, {paused = true})
  H.run(W, 1300, {skip = 9})
  local s = H.state(W)
  T.ok(s.stock and s.stock.drink_d and s.stock.food_d and s.stock.meals ~= nil, 'stock')
  T.eq(s.stock.hosp_water, 0)
  T.eq(s.labor.idle, 100)
  T.ok(s.care and s.care.naked == 8 and s.care.tombs_free == 0)
  T.eq(#W.kitchen, 1, 'PLUMP_HELMET cook exclusion')
  local lows = H.find(H.events(W), 'STOCK_LOW')
  T.ok(#lows >= 1)
  H.kern().stop('test')
  T.ok(W.persist_raw['dfllm.m.economy'], 'economy persist flushed')
  T.ok(W.persist_raw['dfllm.m.care'], 'care persist flushed')
end)

T.done()
