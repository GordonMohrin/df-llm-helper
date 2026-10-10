-- Integration fixes across work packages (docs/v2/STATUS.md): act.quickfort 'orders' creates the
-- manager orders, gate reads DF's bridge flag names, readiness accepts audits only for this boot's
-- audit snapshots (once), military.kill({}) withdraws kill orders, the runner's baseline deliverable.
local T = require('testlib')
local H = require('kern_world')
local actlib = require('dfllm.act')

local function mk()
  local env = {who_v = 'runner', lines = {}, fails = {}}
  env.api = actlib.new{
    who = function() return env.who_v end,
    allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
    log_cmd = function(origin, what, args, result) env.lines[#env.lines + 1] = {origin, what, args, result} end,
    fail = function(fn, err, module) env.fails[#env.fails + 1] = {fn, err, module} end,
  }
  return env
end

T.test("act.quickfort 'orders': the API steps plus orders.create_orders (quickfort.lua:43, command.lua:183)", function()
  local W = H.world{tag = 'qforders'}
  local seq = {}
  W.scripts['quickfort'] = {apply_blueprint = function() seq[#seq + 1] = 'apply_blueprint'; return {} end}
  W.scripts['internal/quickfort/api'] = {
    normalize_data = function(data, pos) seq[#seq + 1] = 'normalize'; return {[pos.z] = data[0]}, pos end,
    init_api_ctx = function(params, cursor)
      seq[#seq + 1] = 'ctx:' .. params.command
      return {stats = {out_of_bounds = {label = 'x', value = 0}}, order_specs = {}}
    end,
    clean_stats = function(stats) return stats end,
  }
  W.scripts['internal/quickfort/command'] = {do_command_raw = function(mode, z, grid, ctx)
    seq[#seq + 1] = 'raw:' .. mode .. ':' .. z
    ctx.order_specs.bed = {quantity = 2}
  end}
  W.scripts['internal/quickfort/orders'] = {create_orders = function(ctx)
    seq[#seq + 1] = 'create_orders'
    for label, spec in pairs(ctx.order_specs) do
      table.insert(ctx.stats, {label = 'Ordered ' .. label, value = spec.quantity, is_order = true})
    end
  end}
  local env = mk()
  local ok, stats = env.api.quickfort{mode = 'build', command = 'orders', data = {[0] = {[0] = {[0] = 'b'}}},
                                      pos = {10, 20, 30}}
  T.ok(ok, tostring(stats))
  T.eq(seq, {'normalize', 'ctx:orders', 'raw:build:30', 'create_orders'})
  T.eq(stats, {[1] = 2, out_of_bounds = 0}, 'orders come back as integer keys (runner counts them)')
  seq = {}
  T.ok((env.api.quickfort{mode = 'build', data = {[0] = {[0] = {[0] = 'b'}}}, pos = {1, 2, 3}}))
  T.eq(seq, {'apply_blueprint'}, 'run still goes through apply_blueprint')
end)

T.test('gate: bridge gate_flags raised/raising/lowering (no closed field, lever.lua:39-41)', function()
  local S = require('siege_world')
  local W = S.world{}
  S.load(W)
  W.run(30, {skip = 9})
  local function strict(t)
    return setmetatable(t, {__index = function(_, k) error('no field ' .. tostring(k)) end})
  end
  W.bridges.O1.gate_flags = strict{raised = true, raising = false, lowering = false}
  W.bridges.B1.gate_flags = strict{raised = false, raising = true, lowering = false}
  W.bridges.B2.gate_flags = strict{raised = false, raising = false, lowering = false}
  T.eq(select(2, W.K.call('gate', 'state', 'O1')), 'up')
  T.eq(select(2, W.K.call('gate', 'state', 'B1')), 'moving')
  T.eq(select(2, W.K.call('gate', 'state', 'B2')), 'down')
  W.run(1300, {skip = 9})                     -- gate steps (and its resolve) read the same flags
  T.eq(W.state().bridges, {O1 = 'up', B1 = 'moving', B2 = 'down'})
  T.eq(#W.faults, 0)
end)

T.test('readiness: audit only for an audit snapshot exported this boot, once (CONTRACTS §13 R6)', function()
  local X = require('wp6_world')
  local W = X.world{units = X.citizens(20)}
  local snap = X.snapshot()
  X.load(W, {'military', 'readiness'}, {X.economy(), snap, X.runner(nil)}, {'sense', 'gate'})
  W.run(1200, {skip = 9})
  local args = {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true, caverns = true}
  local a = {}
  for k, v in pairs(args) do a[k] = v end
  a.snap = 'never-exported'
  local r = W.inbox('audit', a, {by = 'follow'})
  T.eq({r.ok, r.msg}, {false, 'unknown snap'})
  r = X.audit(W, args)
  T.eq(r.ok, true)
  local again = {}
  for k, v in pairs(args) do again[k] = v end
  again.snap = snap.exports and ('snap' .. snap.n)
  r = W.inbox('audit', again, {by = 'follow'})
  T.eq({r.ok, r.msg}, {false, 'unknown snap'}, 'used once')
end)

T.test('military.kill({}) withdraws a running kill order (siege.withdraw, WP5)', function()
  local X = require('wp6_world')
  local Z = 10
  local units = X.citizens(50)
  units[#units + 1] = X.S.inv(201, 50, 27, Z)
  local W = X.world{units = units}
  X.load(W, {'military'}, {X.snapshot()}, {'sense'})
  W.K.set_mode('SIEGE', 'test')
  W.run(30, {skip = 9})
  local _, ok, n = W.K.call('military', 'kill', {201})
  T.eq({ok, n}, {true, 1})
  local C = X.squad_of(W, 'C')
  T.eq(C.orders[0].kind, 'kill')
  local _, ok2, n2 = W.K.call('military', 'kill', {})
  T.eq({ok2, n2}, {true, 0})
  T.ok(#C.orders == 0 or C.orders[0].kind ~= 'kill', 'kill order replaced by the posture order')
  local _, ok3 = W.K.call('military', 'posture', 'READY_STATION', true)
  T.eq(ok3, true, 'posture(P, force) re-issues')
end)

T.test("runner: the P0 'baseline' deliverable passes on baseline.done() (kern owns marker.baseline)", function()
  local R = require('runner_world')
  local W = R.world{tag = 'bl', phases = {v = 2, kind = 'phases', phases = {
    {id = 'P0', title = 'p0', approve = false, deliver = {{k = 'baseline'}}},
    {id = 'P1', title = 'p1', approve = false, deliver = {}}}}}
  W.load(require('dfllm.runner'))
  local done = false
  W.load{name = 'baseline', every = {ticks = 33600}, done = function() return done end}
  R.runs(W, 1)
  T.eq(W.state().phase, 'P0')
  done = true
  R.runs(W, 1)
  T.eq(W.state().phase, 'P1')
end)

T.done()
