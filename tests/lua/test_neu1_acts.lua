-- NEU1 P7: the real act.lua (building_remove, labor_set both ways for the player, the held / note env) and the real kern's hold
-- gate: a player verb's act calls are noted and held (player.hold_acts), a kernel module's later call on the held object is refused
-- without ACT_FAIL. docs/v2/NEU1-notausgang.md.
local T = require('testlib')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local actlib = require('dfllm.act')

local function mk(who, env_extra)
  local env = {who_v = who, fails = {}, notes = {}}
  local e = {
    who = function() return env.who_v end,
    allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
    log_cmd = function() end,
    fail = function(fn, err, module) env.fails[#env.fails + 1] = {fn, err, module} end,
  }
  for k, v in pairs(env_extra or {}) do e[k] = v end
  env.api = actlib.new(e)
  return env
end

T.test('act.building_remove: a zone only as a zone, a building only as a building, a bridge or lever only with force; the footprint comes back', function()
  local W = H.world{tag = 'bremove'}
  df.building_type = {Bridge = 1, Workshop = 2, Civzone = 3, Trap = 4, [1] = 'Bridge', [2] = 'Workshop', [3] = 'Civzone', [4] = 'Trap'}
  df.trap_type = {Lever = 1}
  df.building_civzonest = {is_instance = function(_, b) return b._zone == true end}
  df.building_trapst = {is_instance = function(_, b) return b._trap == true end}
  local gone = {}
  dfhack.buildings = {deconstruct = function(b) gone[#gone + 1] = b.id; return b._queued ~= true end,
                      markedForRemoval = function(b) return b._queued == true end}
  local function add(id, t, o)
    local b = W.add_building{id = id, x1 = 10, y1 = 11, x2 = 12, y2 = 13, z = 5}
    b.getType = function() return t end
    for k, v in pairs(o or {}) do b[k] = v end
    return b
  end
  add(1, 3, {_zone = true}); add(2, 2); add(3, 1); add(4, 4, {_trap = true, trap_type = 1}); add(5, 2, {_queued = true})
  local env = mk('player')
  T.eq({env.api.building_remove(1, 'zone')}, {true, {how = 'gone', rect = {10, 11, 12, 13, 5}, type = 'Civzone'}})
  T.eq({env.api.building_remove(2, 'zone')}, {false, 'building 2 is not a zone'})
  T.eq({env.api.building_remove(1, 'building')}, {false, 'building 1 is a zone: use zone.remove'})
  T.eq(env.api.building_remove(2, 'building'), true)
  T.eq({env.api.building_remove(3, 'building')}, {false, 'Bridge 3 is part of the defence or the trade: approve:true removes it'})
  T.eq({env.api.building_remove(4, 'building')}, {false, 'Lever 4 is part of the defence or the trade: approve:true removes it'})
  T.eq(env.api.building_remove(3, 'building', true), true)
  T.eq(select(2, env.api.building_remove(5, 'building')).how, 'queued')
  T.eq({env.api.building_remove(99, 'building')}, {false, 'no building 99'})
  T.eq(gone, {1, 2, 3, 5})
  env.who_v = 'economy'
  T.eq({env.api.building_remove(2, 'building')}, {false, 'not owner'})
end)

T.test('act.labor_set: `any` (the player) switches either way; the kernel keeps its one direction', function()
  local W = H.world{tag = 'laborany', units = {{id = 7, citizen = true}}}
  df.unit_labor = {PLANT = 1, MECHANIC = 2}
  W.unit(7).status.labors = {[1] = false, [2] = true}
  local env = mk('player')
  T.eq({env.api.labor_set(7, 'farm', true, true)}, {true, 'enabled'})
  T.eq({env.api.labor_set(7, 'mechanic', false, true)}, {true, 'disabled'})
  T.eq(W.unit(7).status.labors, {[1] = true, [2] = false})
  env.who_v = 'economy'
  T.eq({env.api.labor_set(7, 'farm', true)}, {false, 'farm can only be switched off'})
end)

T.test('act env: a held call is refused without a fail and without running; a successful call is noted', function()
  local W = H.world{tag = 'heldenv', units = {{id = 7, citizen = true}}}
  df.unit_labor = {PLANT = 1}
  W.unit(7).status.labors = {[1] = true}
  local seen = {}
  local env = mk('economy', {held = function(fn, args) seen[#seen + 1] = fn; if fn == 'labor_set' and args[1] == 7 then return 'labor.set' end end,
                             note = function(fn, args, res) seen[#seen + 1] = 'note:' .. fn end})
  T.eq({env.api.labor_set(7, 'farm', false)}, {false, 'held by the player (labor.set)'})
  T.eq(W.unit(7).status.labors[1], true, 'not run')
  T.eq(env.fails, {}, 'no ACT_FAIL for a held call')
  T.eq(seen, {'labor_set'})
end)

T.test('kern: labor.set through the inbox is held; economy\'s later switch is refused (no ACT_FAIL), another unit is not', function()
  local W = H.world{tag = 'kernhold', units = {{id = 41, citizen = true}, {id = 42, citizen = true}}, ms_per_frame = 100}
  df.unit_labor = {PLANT = 1}
  W.unit(41).status.labors = {[1] = false}
  W.unit(42).status.labors = {[1] = true}
  local eco = {name = 'economy', every = {ticks = 100}}
  function eco.step(K)
    if W.go then W.res = {{K.act.labor_set(41, 'farm', false)}, {K.act.labor_set(42, 'farm', false)}} end
  end
  local ok, msg = H.boot(W, {modules = {require('dfllm.player'), eco}})
  T.ok(ok, msg)
  H.run(W, 20, {skip = 10})
  H.inbox(W, 'c1', 'labor.set', {unit = 41, labor = 'farm', on = true})
  H.run(W, 200, {skip = 10})
  local r = H.outbox(W, 'c1')
  T.eq(r.ok, true, r.msg)
  T.ok(r.msg:find('held 28 days', 1, true), r.msg)
  T.eq(W.unit(41).status.labors[1], true)
  W.go = true
  H.run(W, 300, {skip = 10})
  T.eq(W.res[1], {false, 'held by the player (labor.set)'})
  T.eq(W.res[2][1], true)
  T.eq(W.unit(42).status.labors[1], false, 'an unheld unit is switched')
  T.eq(W.unit(41).status.labors[1], true, 'the player\'s labor stays')
  T.eq(#H.find(H.events(W), 'ACT_FAIL'), 0)
  require('dfllm.kern').stop()
end)

T.test('kern: the open exit lifts the mode list of the VERB_EMG verbs only (lever in SIEGE), a closed or missing one does not', function()
  local W = H.world{tag = 'kernemg', ms_per_frame = 100}
  local gate = {name = 'gate', every = {ticks = 25}, verbs = {}}
  gate.verbs.lever = function(K, args) return true, 'queued ' .. args.bridge end
  local pl = {name = 'player', every = {ticks = 1200}, is = false}
  function pl.open() return pl.is end
  local ok, msg = H.boot(W, {modules = {gate, pl}})
  T.ok(ok, msg)
  require('dfllm.kern').K().set_mode('SIEGE', 'test')
  H.inbox(W, 'l1', 'lever', {bridge = 'O1', want = 'up'})
  H.run(W, 100, {skip = 10})
  T.eq(H.outbox(W, 'l1').msg, 'lever not allowed in SIEGE')
  pl.is = true
  H.inbox(W, 'l2', 'lever', {bridge = 'O1', want = 'up'})
  H.inbox(W, 'd1', 'drill', {})
  H.run(W, 100, {skip = 10})
  T.eq(H.outbox(W, 'l2').msg, 'queued O1')
  T.eq(H.outbox(W, 'd1').msg, 'drill not allowed in SIEGE', 'a verb outside VERB_EMG keeps its modes')
  require('dfllm.kern').stop()
end)

T.done()
