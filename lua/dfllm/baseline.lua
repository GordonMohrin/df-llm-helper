-- baseline (WP8): the native DFHack baseline (DESIGN §3, §5.5-§5.11), applied idempotently on adopt and
-- on every load, re-checked monthly. Every write is an allowlisted K.act.run; command syntax follows the
-- installed docs hack/docs/docs/tools/<tool>.txt. Not done here on purpose:
--   * max-pop belongs to readiness (act.popcap); baseline sets it only while readiness is not loaded;
--   * the PLUMP_HELMET kitchen exclusion is economy's (act.kitchen_exclude is economy-owned); baseline
--     keeps seedwatch off every plant with a permanent cook exclusion (seedwatch calls
--     Kitchen::allowPlantSeedCookery above target+20, which drops the exclusion; seedwatch.plug.dll
--     imports it) and asks economy to re-check the exclusion after its seedwatch task;
--   * labor assignment belongs to labormanager itself (no work-detail writes anywhere in v2).
-- labormanager (DESIGN §5.5): monitor mode first; after `ab_days` PEACE days an A/B test runs modern
-- (+ balance, unmanaged labors) for as many PEACE days and keeps the mode with fewer starving days
-- (economy reports the daily KPI through labor_day). The chosen mode is persisted and re-applied on load.
-- Tasks run in slices (per_slice per frame). The module switches to an ms cadence while tasks are
-- pending, so the baseline lands even though DF loads saves paused (CONTRACTS §3.2: `every` is re-read).
local C = require('dfllm.util.contract')
local json = require('dfllm.util.json')

local M = {name = 'baseline', every = {ticks = 33600}}
M.APPLY_EVERY = {ms = 200}
M.IDLE_EVERY = {ticks = 33600}

-- mirror of config/baseline.json "baseline" (tests/lua/test_baseline.lua checks they agree)
M.DEFAULTS = {
  per_slice = 4,
  control_panel = {'suspendmanager', 'autochop', 'autobutcher', 'autonestbox', 'nestboxes', 'autoslab',
                   'preserve-tombs', 'tailor', 'seedwatch', 'prioritize', 'pop-control',
                   'fix/dead-units', 'fix/empty-wheelbarrows', 'combine'},
  plugins = {'buildingplan', 'logistics', 'preserve-rooms', 'burrow'},
  timestream = true,
  decision_tools = {['D-04'] = {'work-now'}, ['D-05'] = {'agitation-rebalance'}, ['D-10'] = {'emigration', 'deteriorate'}},
  prioritize = {'-aq', 'defaults'},
  -- logs 60..150: never near the 14-log mood reserve, and above the WOOD>=100 MakeCharcoal order of
  -- library/furnace, the only charcoal source that reaches the COAL>=100 every SmeltOre order needs
  autochop = {max = 150, min = 60},
  autobutcher = {all = {2, 1, 2, 1}, races = {CAT = {0, 0, 1, 1}}},
  tailor = {materials = {'silk', 'cloth', 'yarn'}},
  popcap = {max_pop = 55, wave = 8},
  labormanager = {mode = 'monitor', fallback = 'monitor', ab_to = 'modern', ab_days = 168,
                  balance = 'balanced', unmanaged = {'MINE'}},
  seedwatch = {target = 12, always = {}},
  ban_cooking = {'booze', 'honey', 'milk', 'oil', 'tallow'},
  burial = {'-c'},
  melt_piles = {'dfllm-melt', 'melt', 'goblinite'},
  trade_piles = {'dfllm-trade'},
  idle_crafting = {workshop = 'Craftsdwarfs'},
  retries = 3,
}

local st = {}

local function fmt(n) return string.format('%d', math.tointeger(n) or 0) end

local function sorted_keys(t)
  local r = {}
  for k in pairs(t or {}) do r[#r + 1] = k end
  table.sort(r)
  return r
end

function M.conf(K)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.baseline
  if type(c) ~= 'table' then return M.DEFAULTS end
  local r = {}
  for k, v in pairs(M.DEFAULTS) do r[k] = v end
  for k, v in pairs(c) do r[k] = v end
  return r
end

local function decision(K, id)
  return tostring((K.cfg.decisions or {})[id] or C.DECISIONS[id] or '')
end

---------------------------------------------------------------- reads (buildings and raws only)
-- plants with a permanent cook exclusion (economy's kitchen config): never watched by seedwatch
M.NO_SEEDWATCH = {'MUSHROOM_HELMET_PLUMP'}         -- used when config/baseline.json has no economy part
function M.excluded_plants(K)
  local eco = type(K.cfg.baseline) == 'table' and K.cfg.baseline.economy
  local list = type(eco) == 'table' and type(eco.kitchen) == 'table' and eco.kitchen or nil
  if not list then return M.NO_SEEDWATCH end
  local set = {}
  for _, e in ipairs(list) do if type(e.plant) == 'string' then set[e.plant] = true end end
  return sorted_keys(set)
end

-- crops planted in any farm plot season (building_farmplotst.plant_id[0..3]) plus the always-list,
-- minus the never-list
function M.farmed_crops(c, never)
  local set, skip = {}, {}
  for _, id in ipairs(never or {}) do skip[id] = true end
  for _, id in ipairs(c.seedwatch.always or {}) do set[id] = true end
  pcall(function()
    local plants = df.global.world.raws.plants.all
    for _, plot in ipairs(df.global.world.buildings.other.FARM_PLOT) do
      for s = 0, 3 do
        local pid = plot.plant_id[s]
        local raw = pid and pid >= 0 and plants[pid]
        if raw then set[raw.id] = true end
      end
    end
  end)
  for id in pairs(skip) do set[id] = nil end
  return sorted_keys(set)
end

-- stockpile numbers of the named piles (logistics add ... -s takes stockpile numbers,
-- hack/lua/plugins/logistics.lua:181-190)
local function named_piles(names)
  local want, nums = {}, {}
  for _, n in ipairs(names or {}) do want[n:lower()] = true end
  pcall(function()
    for _, sp in ipairs(df.global.world.buildings.other.STOCKPILE) do
      if want[dfhack.df2utf(sp.name or ''):lower()] then nums[#nums + 1] = sp.stockpile_number end
    end
  end)
  table.sort(nums)
  return nums
end

local function workshop(name)
  local found
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      if df.workshop_type[b.type] == name then found = b; break end
    end
  end)
  return found
end

---------------------------------------------------------------- composite tasks
local LM_MODES = {'modern', 'monitor', 'legacy'}
-- 'labormanager mode' prints the active engine ("Mode: modern (labormanager)", autolabor.plug.dll strings)
local function lm_confirms(out, mode)
  local s = tostring(out or ''):lower()
  if s:find(mode, 1, true) then return true end
  for _, m in ipairs(LM_MODES) do if s:find(m, 1, true) then return false end end
  return true                                   -- nothing recognisable printed: trust the exit status
end

-- the mode to apply: the persisted choice (A/B state), else the configured start mode
local function lm_want(c)
  local m = st.lm
  for _, x in ipairs(LM_MODES) do if m == x then return m end end
  return c.labormanager.mode
end

-- tools/labormanager.txt: "labormanager mode [legacy|modern|monitor]", then "labormanager enable";
-- balance and unmanaged labors only matter in modern mode (monitor assigns nothing)
local function labor(K, c)
  local lm = c.labormanager
  local mode = lm_want(c)
  st.lm_due = nil                               -- a failure is retried like any task (monthly)
  local ok = K.act.run('labormanager', 'mode', mode)
  if ok then
    local _, out = K.act.run('labormanager', 'mode')
    ok = lm_confirms(out, mode)
  end
  if not ok and lm.fallback and lm.fallback ~= mode then
    mode = lm.fallback
    ok = K.act.run('labormanager', 'mode', mode)
    if st.ab and st.ab.stage == 'B' then st.ab.stage, st.ab.win = 'done', mode end   -- B cannot run
  end
  if not ok then return false, 'labormanager mode failed' end
  if not K.act.run('labormanager', 'enable') then return false, 'labormanager enable failed' end
  if mode == 'modern' then
    if lm.balance then K.act.run('labormanager', 'balance', lm.balance) end
    for _, l in ipairs(lm.unmanaged or {}) do K.act.run('labormanager', 'labor', l, 'unmanaged') end
  end
  st.lm = mode
  return true, mode
end

-- tools/seedwatch.txt: enabling watches every type at 30, so clear first, unwatch the cook-excluded
-- plants explicitly ("<type> 0" removes it), then only farmed crops; finally economy re-checks the
-- kitchen exclusion seedwatch may have dropped meanwhile
local function seeds(K, c)
  local never = M.excluded_plants(K)
  local crops = M.farmed_crops(c, never)
  if not K.act.run('seedwatch', 'clear') then return false, 'seedwatch clear failed' end
  local ok = true
  for _, plant in ipairs(never) do ok = K.act.run('seedwatch', plant, '0') and ok end
  for _, crop in ipairs(crops) do
    ok = K.act.run('seedwatch', crop, fmt(c.seedwatch.target)) and ok
  end
  st.crops = crops
  if K.enabled('economy') then K.call('economy', 'kitchen_check') end
  return ok, #crops
end

local function melt(K, c)
  local nums = named_piles(c.melt_piles)
  if #nums == 0 then return nil, 'no melt pile yet' end
  local ok = true
  for _, n in ipairs(nums) do ok = K.act.run('logistics', 'add', 'melt', '-s', fmt(n)) and ok end
  return ok, #nums
end

-- goods for caravans: trade.lua sells what logistics brings to the depot (DESIGN §5.8), so named trade
-- piles get `logistics add trade`. No template builds one yet: a stockpile named 'dfllm-trade' (made in
-- the UI) is picked up at the next monthly recheck.
local function trade_piles(K, c)
  local nums = named_piles(c.trade_piles)
  if #nums == 0 then return nil, 'no trade pile yet' end
  local ok = true
  for _, n in ipairs(nums) do ok = K.act.run('logistics', 'add', 'trade', '-s', fmt(n)) and ok end
  return ok, #nums
end

-- idle-crafting is enabled per Craftsdwarf's workshop through its overlay toggle only
-- (idle-crafting.lua:672-681); that needs an act function the contract does not have yet
local function idle_crafting(K, c)
  local f = rawget(K.act, 'idle_crafting')
  if type(f) ~= 'function' then return nil, 'act.idle_crafting missing' end
  local ws = workshop(c.idle_crafting.workshop)
  if not ws then return nil, 'no ' .. tostring(c.idle_crafting.workshop) .. ' workshop yet' end
  return f(ws.id, true)
end

---------------------------------------------------------------- the plan
-- every task: {id, fn() -> ok (true | false | nil = pending), info}
function M.plan(K, c)
  local t = {}
  local function add(id, fn) t[#t + 1] = {id = id, fn = fn} end
  local function cmd(id, ...)
    local a = table.pack(...)
    add(id, function() return K.act.run(table.unpack(a, 1, a.n)) end)
  end
  for _, name in ipairs(c.control_panel or {}) do cmd('cp:' .. name, 'control-panel', 'enable', name) end
  if c.timestream and decision(K, 'D-11') == 'accepted' then
    cmd('cp:timestream', 'control-panel', 'enable', 'timestream')
  end
  for _, id in ipairs(sorted_keys(c.decision_tools)) do
    if decision(K, id) == 'on' then
      for _, tool in ipairs(c.decision_tools[id]) do cmd('cp:' .. tool, 'control-panel', 'enable', tool) end
    end
  end
  for _, p in ipairs(c.plugins or {}) do cmd('en:' .. p, 'enable', p) end
  cmd('prioritize', 'prioritize', table.unpack(c.prioritize))
  cmd('autochop', 'autochop', 'target', fmt(c.autochop.max), fmt(c.autochop.min))
  local ab = c.autobutcher
  cmd('autobutcher', 'autobutcher', 'target', fmt(ab.all[1]), fmt(ab.all[2]), fmt(ab.all[3]), fmt(ab.all[4]), 'all')
  for _, race in ipairs(sorted_keys(ab.races)) do      -- after 'all', which resets every watched race
    local r = ab.races[race]
    cmd('autobutcher:' .. race, 'autobutcher', 'target', fmt(r[1]), fmt(r[2]), fmt(r[3]), fmt(r[4]), race)
  end
  cmd('tailor', 'tailor', 'materials', table.unpack(c.tailor.materials))
  if decision(K, 'D-06') ~= 'on' then cmd('tailor:confiscate', 'tailor', 'confiscate', 'false') end
  cmd('popcap:wave', 'pop-control', 'set', 'wave-size', fmt(c.popcap.wave))
  if not K.enabled('readiness') then cmd('popcap:max', 'pop-control', 'set', 'max-pop', fmt(c.popcap.max_pop)) end
  add('labormanager', function() return labor(K, c) end)
  add('seedwatch', function() return seeds(K, c) end)
  cmd('ban-cooking', 'ban-cooking', table.unpack(c.ban_cooking))
  cmd('burial', 'burial', table.unpack(c.burial))
  add('melt', function() return melt(K, c) end)
  add('trade_piles', function() return trade_piles(K, c) end)
  add('idle_crafting', function() return idle_crafting(K, c) end)
  return t
end

-- monthly: changed crops, pending tasks, failed tasks (up to `retries`), max-pop while readiness is absent
local function recheck(K, c)
  local want = {}
  for id, r in pairs(st.res) do
    if r == 'pending' or (r == 'fail' and (st.tries[id] or 0) < (c.retries or 3)) then want[id] = true end
  end
  local crops = M.farmed_crops(c, M.excluded_plants(K))
  if table.concat(crops, ',') ~= table.concat(st.crops or {}, ',') then want.seedwatch = true end
  if not K.enabled('readiness') then want['popcap:max'] = true end
  if st.lm_due then want.labormanager = true end
  local r = {}
  for _, task in ipairs(M.plan(K, c)) do if want[task.id] then r[#r + 1] = task end end
  return r
end

local function save(K)
  local fails, pend = {}, {}
  for _, id in ipairs(sorted_keys(st.res)) do
    if st.res[id] == 'fail' then fails[#fails + 1] = id
    elseif st.res[id] == 'pending' then pend[#pend + 1] = id end
  end
  local tries = {}
  for id, n in pairs(st.tries) do tries[id] = n end
  K.persist.set('m.baseline', {v = 2, done = (st.applied and #fails == 0) and 1 or 0, applied = st.applied or -1,
                               lm = st.lm or '', ab = st.ab, crops = st.crops or {}, fails = fails, pending = pend,
                               tries = json.object(tries)})
  return fails, pend
end

local function finish(K)
  if st.full then st.applied = K.now().tick end
  local fails, pend = save(K)
  K.log(#fails == 0 and 'info' or 'warn', 'baseline %s: %d tasks, failed [%s], pending [%s]',
        st.full and 'applied' or 'rechecked', #st.queue, table.concat(fails, ' '), table.concat(pend, ' '))
  st.queue, st.i, st.full = nil, nil, false
  M.every = st.lm_due and M.APPLY_EVERY or M.IDLE_EVERY       -- a mode switch waits for no month
end

---------------------------------------------------------------- labormanager A/B (DESIGN §5.5, S5)
local function new_ab() return {stage = 'A', a = {0, 0}, b = {0, 0}, win = ''} end

-- WP8-internal, called by economy once per PEACE game day with the parsed starving-postings count.
-- A = start mode, B = ab_to; each arm counts {days, days with starving > 0}. B is kept only when its
-- share of starving days is lower (projects done is not compared: no runner KPI in the contract).
function M.labor_day(K, starving)
  local lm = M.conf(K).labormanager
  local ab, need = st.ab, math.tointeger(lm.ab_days) or 0
  if type(ab) ~= 'table' or ab.stage == 'done' or need <= 0 or not lm.ab_to or lm.ab_to == lm.mode then return end
  local arm = ab.stage == 'A' and ab.a or ab.b
  arm[1] = arm[1] + 1
  if (math.tointeger(starving) or 0) > 0 then arm[2] = arm[2] + 1 end
  if arm[1] >= need then
    if ab.stage == 'A' then
      ab.stage, st.lm = 'B', lm.ab_to
      K.log('info', 'labormanager A/B: %s starved on %d of %d days; testing %s', lm.mode, ab.a[2], ab.a[1], lm.ab_to)
    else
      local keep = ab.b[2] * ab.a[1] < ab.a[2] * ab.b[1]
      ab.stage, ab.win = 'done', keep and lm.ab_to or lm.mode
      st.lm = ab.win
      K.log('info', 'labormanager A/B: %s %d/%d vs %s %d/%d starving days: keeping %s', lm.mode, ab.a[2], ab.a[1],
            lm.ab_to, ab.b[2], ab.b[1], ab.win)
    end
    st.lm_due = true
    M.every = M.APPLY_EVERY
  end
  save(K)
end

---------------------------------------------------------------- module
-- queue the whole baseline (idempotent: every command converges to the same setting); it is applied
-- over the next frames, also while paused
function M.apply(K)
  st.queue, st.i, st.full = M.plan(K, M.conf(K)), 1, true
  M.every = M.APPLY_EVERY
  return true, #st.queue
end

function M.init(K)
  local p = K.persist.get('m.baseline')
  if type(p) ~= 'table' then p = {} end
  st = {res = {}, tries = {}, applied = p.applied ~= -1 and p.applied or nil}
  if type(p.tries) == 'table' then
    for id, n in pairs(p.tries) do st.tries[id] = math.tointeger(n) or 0 end
  end
  st.lm = type(p.lm) == 'string' and p.lm ~= '' and p.lm or nil      -- the chosen mode is re-applied
  local ab = p.ab
  if type(ab) == 'table' and (ab.stage == 'A' or ab.stage == 'B' or ab.stage == 'done')
     and type(ab.a) == 'table' and type(ab.b) == 'table' then
    st.ab = {stage = ab.stage, a = {math.tointeger(ab.a[1]) or 0, math.tointeger(ab.a[2]) or 0},
             b = {math.tointeger(ab.b[1]) or 0, math.tointeger(ab.b[2]) or 0}, win = tostring(ab.win or '')}
  else
    st.ab, st.lm = new_ab(), nil                -- no A/B record: start over from the configured mode
  end
  M.apply(K)                                    -- on adopt and on every load
end

function M.step(K, budget, ctx)
  local c = M.conf(K)
  if not st.queue then
    local q = recheck(K, c)
    if #q == 0 then return end
    st.queue, st.i, st.full = q, 1, false
  end
  local n = math.max(1, math.tointeger(c.per_slice) or 4)
  while n > 0 and st.i <= #st.queue do
    local task = st.queue[st.i]
    st.i, n = st.i + 1, n - 1
    local okc, ok, info = pcall(task.fn)
    if not okc then ok, info = false, ok end
    if ok == nil then st.res[task.id] = 'pending'
    elseif ok then st.res[task.id] = 'ok'
    else
      st.res[task.id] = 'fail'
      st.tries[task.id] = (st.tries[task.id] or 0) + 1
      K.log('warn', 'baseline %s failed: %s', task.id, tostring(info))
    end
  end
  if st.i <= #st.queue then return 'more' end
  finish(K)
end

-- WP8-internal: the P0 'baseline' deliverable (CONTRACTS §9.9 reads marker.baseline, which kern owns)
function M.done(K)
  local p = K.persist.get('m.baseline')
  return type(p) == 'table' and p.done == 1
end

function M.status(K)
  return {pending = st.queue ~= nil, results = st.res, lm = st.lm, crops = st.crops, ab = st.ab}
end

return M
