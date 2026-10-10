-- baseline (WP8): native baseline idempotent on adopt/load, allowlisted, sliced, monthly re-check.
local T = require('testlib')
local F = require('wp8_world')
local json = require('dfllm.util.json')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function world(opts)
  opts = opts or {}
  local W = F.world{cfg = {baseline = opts.cfg or F.cfg(), decisions = opts.decisions}, persist = opts.persist}
  if opts.readiness then W.load({name = 'readiness', every = {ticks = 33600}}) end
  if opts.setup then opts.setup(W) end
  local B = fresh('baseline')
  W.load(B)
  return W, B
end

local function drain(W, frames) W.run(frames or 40, {paused = true}) end

T.test('config/baseline.json mirrors baseline.DEFAULTS', function()
  local B = fresh('baseline')
  T.eq(F.read_json('config/baseline.json').baseline, B.DEFAULTS)
end)

T.test('full apply on boot: native list, settings, labormanager monitor, crops, bans', function()
  local W, B = world()
  T.eq(B.every, B.APPLY_EVERY, 'ms cadence while pending')
  drain(W)
  local r = F.runs(W)
  for _, want in ipairs({
    'control-panel enable suspendmanager', 'control-panel enable autochop', 'control-panel enable autobutcher',
    'control-panel enable autonestbox', 'control-panel enable nestboxes', 'control-panel enable autoslab',
    'control-panel enable preserve-tombs', 'control-panel enable tailor', 'control-panel enable seedwatch',
    'control-panel enable prioritize', 'control-panel enable pop-control', 'control-panel enable fix/dead-units',
    'control-panel enable fix/empty-wheelbarrows', 'control-panel enable combine', 'control-panel enable timestream',
    'enable buildingplan', 'enable logistics', 'enable preserve-rooms', 'enable burrow',
    'prioritize -aq defaults', 'autochop target 150 60', 'autobutcher target 2 1 2 1 all',
    'autobutcher target 0 0 1 1 CAT', 'tailor materials silk cloth yarn', 'tailor confiscate false',
    'pop-control set wave-size 8', 'pop-control set max-pop 55', 'labormanager mode monitor', 'labormanager enable',
    'seedwatch clear', 'seedwatch MUSHROOM_HELMET_PLUMP 0', 'ban-cooking booze honey milk oil tallow',
    'burial -c'}) do
    T.ok(F.has(r, want), 'missing: ' .. want)
  end
  for _, bad in ipairs({'labormanager mode modern', 'labormanager balance balanced',
                        'labormanager labor MINE unmanaged', 'seedwatch MUSHROOM_HELMET_PLUMP 12'}) do
    T.ok(not F.has(r, bad), 'must not run: ' .. bad)
  end
  T.ok(not F.has(r, 'control-panel enable work-now'), 'D-04 default off')
  T.ok(not F.has(r, 'control-panel enable autotraining'), 'autotraining is military business')
  -- 'all' before the CAT target (autobutcher 'all' resets every watched race)
  local ia, ic
  for i, s in ipairs(r) do
    if s == 'autobutcher target 2 1 2 1 all' then ia = i end
    if s == 'autobutcher target 0 0 1 1 CAT' then ic = i end
  end
  T.ok(ia < ic)
  T.eq(B.every, B.IDLE_EVERY)
  local p = W.K.persist.get('m.baseline')
  T.eq(p.done, 1)
  T.eq(p.lm, 'monitor')
  T.eq(p.ab, {stage = 'A', a = {0, 0}, b = {0, 0}, win = ''})
  T.eq(p.pending, {'idle_crafting', 'melt', 'trade_piles'})
  T.ok(B.done(W.K))
  T.eq(W.find_acts('popcap'), {}, 'baseline never calls act.popcap')
end)

T.test('every act.run is allowed by config/allowlist.json', function()
  local W = world{decisions = {['D-04'] = 'on', ['D-05'] = 'on', ['D-10'] = 'on', ['D-06'] = 'on'},
                  setup = function(W)
                    F.building(W, 'STOCKPILE', {name = 'dfllm-melt', stockpile_number = 7})
                  end}
  drain(W)
  local bad = F.bad_runs(W)
  table.sort(bad)
  -- the D-04/D-05/D-10 tools need an allowlist change first (DECISIONS.md): refused, fail safe
  T.eq(bad, {'control-panel enable agitation-rebalance: arguments not allowlisted for control-panel',
             'control-panel enable deteriorate: arguments not allowlisted for control-panel',
             'control-panel enable emigration: arguments not allowlisted for control-panel',
             'control-panel enable work-now: arguments not allowlisted for control-panel'})
  local W2 = world()
  drain(W2)
  T.eq(F.bad_runs(W2), {})
end)

T.test('apply is sliced: at most per_slice tasks per frame, also while paused', function()
  local W, B = world()
  W.run(1, {paused = true})
  local n1 = #W.find_acts('run')
  T.ok(n1 > 0 and n1 <= 4, 'first slice ran ' .. n1 .. ' commands')
  W.run(1, {paused = true})
  T.ok(#W.find_acts('run') > n1)
  drain(W)
  T.eq(B.every, B.IDLE_EVERY)
end)

T.test('idempotent: every load re-applies the same command list', function()
  local W1 = world()
  drain(W1)
  local raw = {}
  for k, v in pairs(W1.persist_raw) do raw[k] = v end
  local persist = {}
  for k, v in pairs(raw) do
    local key = k:match('^dfllm%.(m%..+)$')
    if key then persist[key] = json.decode(v) end
  end
  local W2 = world{persist = persist}
  drain(W2)
  T.eq(F.runs(W2), F.runs(W1))
  T.eq(W2.K.persist.get('m.baseline').done, 1)
end)

T.test('apply() re-queues the same full baseline', function()
  local W, B = world()
  drain(W)
  local first = F.runs(W)
  W.clear()
  local ok, ok2, n = W.K.call('baseline', 'apply')
  T.ok(ok and ok2 and n > 30)
  T.eq(B.every, B.APPLY_EVERY)
  drain(W)
  T.eq(F.runs(W), first)
end)

T.test('readiness loaded: max-pop is left to readiness, wave size stays', function()
  local W = world{readiness = true}
  drain(W)
  local r = F.runs(W)
  T.ok(F.has(r, 'pop-control set wave-size 8'))
  T.ok(not F.has(r, 'pop-control set max-pop 55'))
end)

T.test('decisions: D-11 rejected, D-06 on', function()
  local W = world{decisions = {['D-11'] = 'rejected', ['D-06'] = 'on'}}
  drain(W)
  local r = F.runs(W)
  T.ok(not F.has(r, 'control-panel enable timestream'))
  T.ok(not F.has(r, 'tailor confiscate false'))
end)

local function lm_runs(W)
  local r = {}
  for _, s in ipairs(F.runs(W)) do if s:match('^labormanager') then r[#r + 1] = s end end
  return r
end

local function in_stage_b(extra)
  local p = {['m.baseline'] = {v = 2, done = 1, applied = 0, lm = 'modern', crops = {}, fails = {}, pending = {},
                               tries = json.object{}, ab = {stage = 'B', a = {168, 20}, b = {3, 0}, win = ''}}}
  for k, v in pairs(extra or {}) do p['m.baseline'][k] = v end
  return p
end

T.test('labormanager A/B: 168 PEACE days monitor, then modern + balance + MINE unmanaged, then compare', function()
  local W, B = world()
  drain(W)
  W.clear()
  for _ = 1, 167 do W.K.call('baseline', 'labor_day', 1) end      -- starving on 167 days ...
  drain(W)
  T.eq(lm_runs(W), {}, 'still testing monitor')
  W.K.call('baseline', 'labor_day', 0)                            -- ... of 168
  T.eq(B.every, B.APPLY_EVERY, 'the switch waits for no month')
  drain(W)
  T.eq(lm_runs(W), {'labormanager mode modern', 'labormanager mode', 'labormanager enable',
                    'labormanager balance balanced', 'labormanager labor MINE unmanaged'})
  local p = W.K.persist.get('m.baseline')
  T.eq({p.lm, p.ab.stage, p.ab.a}, {'modern', 'B', {168, 167}})
  W.clear()
  for _ = 1, 168 do W.K.call('baseline', 'labor_day', 0) end
  drain(W)
  p = W.K.persist.get('m.baseline')
  T.eq({p.lm, p.ab.stage, p.ab.win, p.ab.b}, {'modern', 'done', 'modern', {168, 0}}, 'modern starved less: kept')
  T.eq(lm_runs(W)[1], 'labormanager mode modern')
  W.clear()
  W.K.call('baseline', 'labor_day', 5)
  drain(W)
  T.eq(lm_runs(W), {}, 'done: no more switches')
end)

T.test('labormanager A/B: modern no better -> back to monitor; disabled with ab_days 0', function()
  local W = world{persist = in_stage_b({ab = {stage = 'B', a = {168, 0}, b = {167, 0}, win = ''}})}
  drain(W)
  T.ok(F.has(F.runs(W), 'labormanager mode modern'), 'the stored mode is re-applied on load')
  W.clear()
  W.K.call('baseline', 'labor_day', 0)
  drain(W)
  T.eq(lm_runs(W), {'labormanager mode monitor', 'labormanager mode', 'labormanager enable'})
  T.eq(W.K.persist.get('m.baseline').ab.win, 'monitor')
  local cfg = F.cfg()
  cfg.baseline.labormanager.ab_days = 0
  local W2 = world{cfg = cfg}
  drain(W2)
  for _ = 1, 400 do W2.K.call('baseline', 'labor_day', 3) end
  T.eq(W2.K.persist.get('m.baseline').ab.a, {0, 0})
  T.eq(W2.K.persist.get('m.baseline').lm, 'monitor')
end)

T.test('labormanager: modern refused in the B arm -> monitor fallback, no modern-only settings', function()
  local W = world{persist = in_stage_b(), setup = function(W)
    W.act_result('run', function(cmd, a1, a2)
      if cmd == 'labormanager' and a1 == 'mode' and a2 == 'modern' then return false, 'nope' end
      return true, ''
    end)
  end}
  drain(W)
  local r = F.runs(W)
  T.ok(F.has(r, 'labormanager mode monitor'))
  T.ok(F.has(r, 'labormanager enable'))
  T.ok(not F.has(r, 'labormanager balance balanced'))
  local p = W.K.persist.get('m.baseline')
  T.eq({p.lm, p.ab.stage, p.ab.win}, {'monitor', 'done', 'monitor'})
end)

T.test('labormanager: read-back naming another engine -> fallback', function()
  local W = world{persist = in_stage_b(), setup = function(W)
    W.act_result('run', function(cmd, a1, a2)
      if cmd == 'labormanager' and a1 == 'mode' and a2 == nil then return true, 'Mode: monitor (starvation warnings)' end
      return true, ''
    end)
  end}
  drain(W)
  T.ok(F.has(F.runs(W), 'labormanager mode monitor'))
  T.eq(W.K.persist.get('m.baseline').lm, 'monitor')
end)

T.test('a save from before the A/B record starts over in monitor mode', function()
  local W = world{persist = {['m.baseline'] = {v = 2, done = 1, applied = 0, lm = 'modern', crops = {}, fails = {},
                                               pending = {}, tries = json.object{}}}}
  drain(W)
  T.ok(F.has(F.runs(W), 'labormanager mode monitor'))
  T.ok(not F.has(F.runs(W), 'labormanager mode modern'))
end)

T.test('seedwatch: only farmed crops at 12, never a cook-excluded plant; economy re-checks the kitchen', function()
  local checks = 0
  local W, B = world{setup = function(W)
    local plants = df.global.world.raws.plants.all
    plants:insert('#', {id = 'MUSHROOM_HELMET_PLUMP'})
    plants:insert('#', {id = 'GRASS_TAIL_PIG'})
    plants:insert('#', {id = 'MUSHROOM_CUP_DIMPLE'})
    F.building(W, 'FARM_PLOT', {plant_id = {[0] = 0, [1] = 1, [2] = -1, [3] = -1}})
    W.load({name = 'economy', every = {ticks = 1200}, kitchen_check = function() checks = checks + 1; return true end})
  end}
  drain(W)
  local r = F.runs(W)
  T.ok(F.has(r, 'seedwatch GRASS_TAIL_PIG 12'))
  T.ok(not F.has(r, 'seedwatch MUSHROOM_HELMET_PLUMP 12'), 'farmed, but cook-excluded: seedwatch would lift the ban')
  T.ok(not F.has(r, 'seedwatch MUSHROOM_CUP_DIMPLE 12'))
  local ic, iz
  for i, s in ipairs(r) do
    if s == 'seedwatch clear' then ic = i end
    if s == 'seedwatch MUSHROOM_HELMET_PLUMP 0' then iz = i end
  end
  T.ok(ic and iz and ic < iz, 'explicit unwatch after the clear')
  T.eq(checks, 1, 'kitchen exclusion re-checked right after the seedwatch task')
  T.eq(F.bad_runs(W), {})
  W.clear()
  W.run(33600, {skip = 100})              -- monthly: nothing changed except max-pop (readiness absent)
  T.eq(F.runs(W), {'pop-control set max-pop 55'})
  df.global.world.buildings.other.FARM_PLOT[0].plant_id[2] = 2
  W.clear()
  W.run(33600, {skip = 100})
  r = F.runs(W)
  T.ok(F.has(r, 'seedwatch clear') and F.has(r, 'seedwatch MUSHROOM_CUP_DIMPLE 12'))
  T.ok(not F.has(r, 'control-panel enable autochop'), 'no full re-apply')
end)

T.test('melt pile: pending until a named pile exists, then registered by number', function()
  local W = world()
  drain(W)
  T.ok(not F.has(F.runs(W), 'logistics add melt -s 3'))
  F.building(W, 'STOCKPILE', {name = 'Goblinite', stockpile_number = 3})
  W.clear()
  W.run(33600, {skip = 100})
  T.ok(F.has(F.runs(W), 'logistics add melt -s 3'))
  local p = W.K.persist.get('m.baseline')
  T.eq(p.pending, {'idle_crafting', 'trade_piles'})
end)

T.test('trade pile: a stockpile named dfllm-trade gets logistics add trade (integration, DESIGN §5.8)', function()
  local W = world()
  drain(W)
  T.ok(not F.has(F.runs(W), 'logistics add trade -s 7'))
  F.building(W, 'STOCKPILE', {name = 'dfllm-trade', stockpile_number = 7})
  W.clear()
  W.run(33600, {skip = 100})
  T.ok(F.has(F.runs(W), 'logistics add trade -s 7'))
  T.eq(W.K.persist.get('m.baseline').pending, {'idle_crafting', 'melt'})
end)

T.test('a failed task is retried monthly up to `retries`, and done stays 0 meanwhile', function()
  local W = world{setup = function(W)
    W.act_result('run', function(cmd, a1, a2)
      if cmd == 'autochop' then return false, 'boom' end
      return true, ''
    end)
  end}
  drain(W)
  local p = W.K.persist.get('m.baseline')
  T.eq(p.done, 0)
  T.eq(p.fails, {'autochop'})
  for _ = 1, 4 do W.run(33600, {skip = 200}) end
  local n = 0
  for _, s in ipairs(F.runs(W)) do if s:match('^autochop') then n = n + 1 end end
  T.eq(n, 3, 'initial try + 2 retries')
  T.eq(W.K.persist.get('m.baseline').tries.autochop, 3)
  -- the tries map survives a save/load round trip as an object
  local enc = W.persist_raw['dfllm.m.baseline']
  T.ok(enc:find('"tries":{"autochop":3}', 1, true), enc)
end)

T.test('idle-crafting uses act.idle_crafting when the kernel offers it', function()
  local W = world{setup = function(W)
    F.building(W, 'WORKSHOP_ANY', {id = 42, type = df.workshop_type.Craftsdwarfs})
  end}
  local got
  rawset(W.K.act, 'idle_crafting', function(id, on) got = {id, on}; return true end)
  -- re-plan with the new act function present
  local B = package.loaded['dfllm.baseline']
  B.init(W.K)
  drain(W)
  T.eq(got, {42, true})
  T.eq(W.K.persist.get('m.baseline').pending, {'melt', 'trade_piles'})
end)

T.done()
