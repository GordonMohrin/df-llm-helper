-- Scenario for tests/test_trade_files.py: trade on the REAL kernel (kern, act, persist, io) with the
-- repo's config files, writing into <outdir>.
--   python tools/luahost.py --path tests/lua tests/lua/trade_scenario.lua <outdir> stub|proposal
-- stub:     act.trade replaced by a 'not implemented' stub -> one graceful failure
-- proposal: the real act.lua act.trade (A.install_trade) on the click-level fake UI -> traded
local H = require('kern_world')
local F = require('trade_world')
local json = require('dfllm.util.json')

local outdir = assert(arg[1], 'usage: trade_scenario.lua <outdir> stub|proposal'):gsub('\\', '/')
local variant = arg[2] or 'stub'
local manifest = {v = 2, depot = {22, 22, 10},
                  bridges = {O1 = {role = 'outer', fp = {30, 5, 10, 32, 5, 10}, levers = {{35, 8, 10}}}}}
local W = H.world{dfpath = outdir, persist = {manifest = manifest}, ms_per_frame = 16}
F.install(W)
local d = F.depot(W, {})
local goods = {F.item(W, {type = 'BAR', mat = 'INORGANIC:IRON', desc = 'iron bars', value = 100, stack = 5}),
               F.item(W, {type = 'ANVIL', mat = 'INORGANIC:IRON', desc = 'iron anvil', value = 300}),
               F.item(W, {type = 'CLOTH', mat = 'CREATURE:SPIDER_CAVE_GIANT:SILK', desc = 'silk cloth', value = 60})}
local c = F.caravan(W, {state = 'Approaching', goods = goods, civ = 'Guild of \xc3\x9crist'})   -- UTF-8 name
F.goods(W, d, {{type = 'FIGURINE', value = 400}, {type = 'RING', value = 300}, {type = 'CROWN', value = 250},
               {type = 'AMULET', value = 200}, {type = 'TOTEM', value = 120}})
W.broker = W.add_unit{id = 901, citizen = true, pos = {0, 0, 0}}

local U
local A = require('dfllm.act')
if variant == 'proposal' then
  local gui
  U, gui = F.dfui(W, d, c, {prompt = true})
  package.loaded['gui'] = gui          -- act.lua requires DFHack's gui library on first use
else
  local orig = A.new
  A.new = function(env)                -- the real act table with act.trade failing as 'not implemented'
    local api = orig(env)
    rawset(api, 'trade', function(op, args)
      local who = env.who() or 'kern'
      env.log_cmd(who, 'act.trade', json.encode(json.array({op})), 'ERR trade not implemented (stub)')
      env.fail('trade', 'trade not implemented (stub)', who)
      return false, 'trade not implemented (stub)'
    end)
    return api
  end
end

-- gate test double: state(bridge), want() recorded
W.bridge_state = {O1 = 'up'}
local wants = {}
local gate = {name = 'gate', every = {ticks = 600}}
function gate.state(K, b) if b == nil then return {} end return W.bridge_state[b] or 'unknown' end
function gate.want(K, b, w, why) wants[#wants + 1] = {b, w, why}; W.bridge_state[b] = w; return true, 'wanted' end

local kern = require('dfllm.kern')
local ok, msg = H.boot(W, {repo = F.REPO, modules = {gate, require('dfllm.trade')}})
assert(ok, msg)
local K = kern.K()
local function quiet() K.census.h = {tick = K.now().tick, vis = 0} end

quiet(); H.run(W, 300, {skip = 9})
F.set_state(c, 'AtDepot')
F.trader(W, d, true)
for _ = 1, 20 do quiet(); H.run(W, 100, {skip = 9}) end
for _ = 1, 600 do H.frame(W, 1) end                -- UI phases run on real time
H.inbox(W, 'tw1', 'trade.want', {want = {'bar:steel', 'bolts'}})
H.inbox(W, 'tw2', 'trade.want', {want = {'Not A Token'}})
H.run(W, 60, {skip = 1})
F.remove_caravans()
H.run(W, 300, {skip = 9})
kern.stop('scenario end')
H.write(outdir .. '/persist_dump.json', json.encode(json.object(W.persist_raw)))
print('summary ' .. json.encode({wants = #wants, trades = U and U.trades or 0, misclicks = U and U.misclicks or 0,
                                 wrong_screen = U and U.wrong_screen or 0, prompts = U and U.dialogs or 0,
                                 requested = d.trade_flags.trader_requested, anyone = d.trade_flags.anyone_can_trade,
                                 paused = df.global.pause_state == true, focus = W.focus[1]}))
print('scenario done')
