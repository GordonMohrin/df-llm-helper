-- WP5 test world: a k_mock world (or the real kernel on it) with a fort manifest, Kern+/Tiefe+
-- burrows, bridge and lever buildings, and a simulator for PullLever jobs: a job gets a worker
-- after `worker` ticks (nil = never), is pulled `pull` ticks later, and the linked bridge moves for
-- `move` ticks before gate_flags.closed flips. Also fake military/drill/snapshot modules.
--   local S = require('siege_world')
--   local W = S.world{units = {...}}; S.load(W); S.run(W, 3000)
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local S = {}
S.Z = 10
local Z = S.Z

-- O1 outer (y=10), killbox K1 (y 25-31), B1 inner (y=40), Kern+ from y=41, B2 core seal (y=60)
function S.manifest()
  return {v = 2,
    bridges = {
      O1 = {role = 'outer', fp = {50, 10, Z, 52, 10, Z}, levers = {{55, 45, Z}, {56, 45, Z}}},
      B1 = {role = 'inner', fp = {50, 40, Z, 52, 40, Z}, levers = {{54, 46, Z}, {55, 46, Z}}},
      B2 = {role = 'core', fp = {50, 60, Z, 52, 60, Z}, levers = {{54, 66, Z}, {55, 66, Z}}},
    },
    burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
    refuge = {anchor = {70, 70, Z - 6}, burrow = 'Tiefe+'},
    killboxes = {{id = 'K1', bbox = {48, 25, Z, 54, 31, Z}}},
    stairs = {civ = {{60, 60, Z - 6, Z}}, mil = {{49, 26, Z - 2, Z}}},
    stations = {melee = {51, 44, Z}, gallery = {51, 28, Z + 1}, b2 = {51, 62, Z}},
  }
end
S.KERN = {40, 41, Z - 2, 80, 95, Z}
S.TIEFE = {60, 60, Z - 7, 80, 80, Z - 5}
S.BRIDGE_ID = {O1 = 1, B1 = 2, B2 = 3}
S.LEVERS = {O1 = {11, 12}, B1 = {21, 22}, B2 = {31, 32}}

-- unit specs
function S.cit(id, x, y, z, extra)
  local u = {id = id, pos = {x, y, z or Z}, citizen = true, adult = true}
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end
function S.inv(id, x, y, z, extra)
  local u = {id = id, pos = {x, y, z or Z}, invader = true, race = 'GOBLIN'}
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end
function S.danger(id, x, y, z, extra)
  local u = {id = id, pos = {x, y, z or Z}, danger = true, animal = true}
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end
-- four citizens inside Kern+, one soldier at the B1 station
function S.fort_units()
  return {S.cit(1, 60, 70), S.cit(2, 61, 70), S.cit(3, 62, 71), S.cit(4, 63, 72, Z, {adult = false}),
          S.cit(5, 51, 44, Z, {squad = 1})}
end
function S.army(n, x, y, first)
  local r = {}
  for i = 1, n do r[i] = S.inv((first or 200) + i, x + (i - 1) % 3, y + (i - 1) // 3) end
  return r
end

---------------------------------------------------------------- DF fakes
function S.install(W, opts)
  opts = opts or {}
  local g = df.global
  df.building_type = {Bridge = 19, Trap = 20}
  df.trap_type = {Lever = 1, PressurePlate = 2}
  df.job_type = {PullLever = 223, Other = 1}
  df.general_ref_type = {BUILDING_HOLDER = 6}
  df.building_trapst = {is_instance = function(_, b) return type(b) == 'table' and b._kind == 'trap' end}
  -- insane citizens: unit spec insane=true (k_mock: isCitizen/isResident/getCitizens honour
  -- include_insane like Lua API.txt:1464-1470, :1696)
  g.plotinfo.alerts.list = kmock.vec{{id = 0, burrows = kmock.vec{}}, {id = 1, name = 'civ-alert', burrows = kmock.vec{}}}
  g.plotinfo.tasks = {wealth = {total = 12000, exported = 300, imported = 900}}
  W.burrow('Kern+', opts.kern or S.KERN)
  if opts.tiefe ~= false then W.burrow('Tiefe+', S.TIEFE) end
  W.flips, W.toggles, W.levers, W.bridges = {}, {}, {}, {}
  W.lever_cfg = opts.lever_cfg or {}
  W.lever_default = opts.lever_default or {worker = 30, pull = 40}
  W.move_ticks = opts.move or 20
  W.job_seq, W.own = 5000, {}
  W.max_pending, W.pending_violations = 0, 0
  local man = opts.manifest or S.manifest()
  for name, spec in pairs(man.bridges or {}) do
    local fp = spec.fp
    local b = W.add_building{id = S.BRIDGE_ID[name] or (100 + #W.bridges), _kind = 'bridge', name = name,
                             x1 = fp[1], y1 = fp[2], x2 = fp[4], y2 = fp[5], z = fp[3],
                             centerx = (fp[1] + fp[4]) // 2, centery = (fp[2] + fp[5]) // 2,
                             gate_flags = {closed = false, closing = false, opening = false}}
    b.getType = function() return df.building_type.Bridge end
    b.jobs = kmock.vec{}
    W.bridges[name] = b
    g.world.buildings.other.BRIDGE:insert('#', b)
    for i, p in ipairs(spec.levers or {}) do
      local lv = W.add_building{id = (S.LEVERS[name] or {})[i] or (200 + #W.levers), _kind = 'trap',
                                trap_type = df.trap_type.Lever, x1 = p[1], y1 = p[2], x2 = p[1], y2 = p[2], z = p[3],
                                centerx = p[1], centery = p[2], state = 0, bridge = name}
      lv.jobs = kmock.vec{}
      local target = b
      lv.linked_mechanisms = kmock.vec{{_ref = {getBuilding = function() return target end}}}
      W.levers[#W.levers + 1] = lv
      g.world.buildings.other.TRAP:insert('#', lv)
    end
  end
  table.sort(W.levers, function(a, b) return a.id < b.id end)
  dfhack.buildings = {findAtTile = function(x, y, z)
    if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
    for _, b in pairs(W.buildings) do
      local hidden = W.hide_raised and b._kind == 'bridge' and b.gate_flags.closed   -- opts: raised = not at tile
      if not hidden and b.z == z and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
    end
  end}
  dfhack.items = {getGeneralRef = function(m, t) return m._ref end}
  dfhack.job = {getWorker = function(j) return j._worker end,
                removeJob = function(j) return S.remove_job(W, j.id) end}
  -- hack/scripts/lever.lua:4 shape: a PullLever job appended to lever.jobs
  W.scripts['lever'] = {leverPullJob = function(lever, priority) return S.new_job(W, lever) end,
                        leverPullInstant = function() error('lever --instant is armok') end}
  local ca = W.scripts['gui/civ-alert']
  local function civ() return g.plotinfo.alerts.list[1].burrows end
  ca.sound_alarm = function() if #civ() > 0 then g.plotinfo.alerts.civ_alert_idx = 1 end end
  ca.add_civalert_burrow = function(id) civ():insert('#', id) end
  ca.remove_civalert_burrow = function(id)
    local v = civ()
    for i = #v - 1, 0, -1 do if v[i] == id then v:erase(i) end end
    if #v == 0 then g.plotinfo.alerts.civ_alert_idx = 0 end
  end
  -- k_mock act fakes go through the same simulator (the real act.lua uses the script above)
  if W.act_result then
    W.act_result('pull', function(lid)
      local lv = W.buildings[lid]
      if not lv or lv._kind ~= 'trap' then return false, 'not a lever' end
      local j = S.new_job(W, lv)
      W.own[j.id] = true
      return true, j.id
    end)
    W.act_result('cancel_own_lever_job', function(id)
      if not W.own[id] then return false, 'not our job' end
      W.own[id] = nil
      if S.remove_job(W, id) then return true end
      return false, 'job no longer pending'
    end)
    W.act_result('alert_burrows', function(names)
      for _, n in ipairs(names) do if not dfhack.burrows.findByName(n) then return false, 'no burrow ' .. n end end
      W.alert_burrows = names
      return true, #names
    end)
  end
  return W
end

function S.world(opts)
  opts = opts or {}
  local persist = opts.persist or {}
  if persist.manifest == nil and opts.manifest ~= false then persist.manifest = opts.manifest or S.manifest() end
  local W = kmock.new{units = opts.units, mode = opts.mode, persist = persist, strict = opts.strict ~= false,
                      year = opts.year or 3, ytick = opts.ytick or 1000, ms_per_frame = opts.ms_per_frame or 16}
  return S.install(W, opts)
end

---------------------------------------------------------------- job / bridge simulator
local function abs_now() return df.global.cur_year * 403200 + df.global.cur_year_tick end
S.abs_now = abs_now

function S.new_job(W, lever)
  W.job_seq = W.job_seq + 1
  local j = {id = W.job_seq, job_type = df.job_type.PullLever, _lever = lever.id, _q = abs_now()}
  lever.jobs:insert('#', j)
  return j
end

function S.remove_job(W, id)
  for _, lv in ipairs(W.levers) do
    for i = #lv.jobs - 1, 0, -1 do
      if lv.jobs[i].id == id then lv.jobs:erase(i); return true end
    end
  end
  return false
end

-- a job that is not ours (Gordon's, or ours from before a reload)
function S.foreign_job(W, lever_id, worker)
  local lv = W.buildings[lever_id]
  local j = S.new_job(W, lv)
  if worker then j._worker = {id = 9999} end
  return j
end

function S.move_bridge(W, name, now, instant)
  local b = W.bridges[name]
  local gf = b.gate_flags
  local up = not gf.closed
  W.toggles[name] = (W.toggles[name] or 0) + 1
  W.flips[#W.flips + 1] = {tick = now, bridge = name, to = up and 'up' or 'down'}
  if instant then gf.closed = up; return end
  gf.closing, gf.opening = up, not up
  b._move_end = now + W.move_ticks
end

function S.sim(W)
  local now = abs_now()
  for _, lv in ipairs(W.levers) do
    local cfg = W.lever_cfg[lv.id] or W.lever_default
    for i = #lv.jobs - 1, 0, -1 do
      local j = lv.jobs[i]
      if not j._worker and cfg.worker ~= nil and now - j._q >= cfg.worker then j._worker, j._w = {id = 9999}, now end
      if j._worker and now - (j._w or j._q) >= (cfg.pull or 40) then
        lv.jobs:erase(i)
        S.move_bridge(W, lv.bridge, now)
      end
    end
  end
  for name, b in pairs(W.bridges) do
    local gf = b.gate_flags
    if (gf.closing or gf.opening) and b._move_end and now >= b._move_end then
      gf.closed = gf.closing
      gf.closing, gf.opening, b._move_end = false, false, nil
    end
    local n = 0
    for _, lv in ipairs(W.levers) do
      if lv.bridge == name then
        for _, j in ipairs(lv.jobs) do if j.job_type == df.job_type.PullLever then n = n + 1 end end
      end
    end
    if n > W.max_pending then W.max_pending = n end
    if n > 1 then W.pending_violations = W.pending_violations + 1 end
  end
end

function S.bstate(W, name)
  local gf = W.bridges[name].gate_flags
  if gf.closing or gf.opening then return 'moving' end
  return gf.closed and 'up' or 'down'
end

-- run `ticks` game ticks in frames of opts.skip (default 9); opts.at = {{t, fn}, ...} relative to the
-- start (fn(W, now) runs once, before the first frame at or after t); opts.frame = fn(dt) override
function S.run(W, ticks, opts)
  opts = opts or {}
  local skip = opts.skip or 9
  local start = abs_now()
  W.t_start = W.t_start or start
  local at = {}
  for _, a in ipairs(opts.at or {}) do at[#at + 1] = {t = a[1], fn = a[2]} end
  table.sort(at, function(a, b) return a.t < b.t end)
  local done, k = 0, 1
  local frame = opts.frame or W.frame
  while done < ticks do
    while at[k] and done >= at[k].t do at[k].fn(W, abs_now()); k = k + 1 end
    local step = math.min(skip, ticks - done)
    frame(step)
    S.sim(W)
    done = done + step
  end
  while at[k] do at[k].fn(W, abs_now()); k = k + 1 end
end

---------------------------------------------------------------- fake modules of other WPs
-- kill({}) = withdraw the held kill orders (the WP5 proposal for CONTRACTS §7, see siege.withdraw)
function S.military()
  local M = {name = 'military', every = {ticks = 3600}, postures = {}, kills = {}, withdrawn = {}}
  function M.posture(K, P, force)
    M.postures[#M.postures + 1] = {P = P, tick = K.now().tick, force = force}
    return true
  end
  function M.kpi(K) return {squads = 3, soldiers = 8, worn = 95, cv = 13, metal_pct = 0, on_station = 7} end
  function M.kill(K, ids)
    if #ids == 0 then M.withdrawn[#M.withdrawn + 1] = K.now().tick; return true, 0 end
    M.kills[#M.kills + 1] = {ids = ids, tick = K.now().tick}
    return true, #ids
  end
  return M
end

-- drill (WP6 stand-in): start() enters DRILL; at T+1,200 it reads gate.kpi and ends the drill
function S.drill()
  local M = {name = 'drill', every = {ticks = 25}}
  function M.start(K)
    local ok, err = K.call('gate', 'reset_kpi')
    M.t0 = K.now().tick
    return K.set_mode('DRILL', 'test drill')
  end
  function M.step(K)
    if K.mode() == 'DRILL' and M.t0 and K.now().tick - M.t0 >= 1200 then
      local _, kpi = K.call('gate', 'kpi')
      M.kpi = kpi
      M.t0 = nil
      K.set_mode('PEACE', 'drill done')
    end
  end
  return M
end

function S.snapshot(chars)
  local M = {name = 'snapshot', every = {ticks = 100}}
  function M.tile(K, x, y, z) return {c = chars[x .. ',' .. y .. ',' .. z] or '.', dig = '', bld = ''} end
  return M
end

function S.load(W, extra)
  for _, n in ipairs({'sense', 'threat', 'siege', 'gate'}) do
    package.loaded['dfllm.' .. n] = nil       -- a fresh module table per world
    W.load(require('dfllm.' .. n))
  end
  for _, m in ipairs(extra or {}) do W.load(m) end
  return W
end

---------------------------------------------------------------- recorders
function S.modes(W)
  local r = {}
  for _, ev in ipairs(W.find_events('MODE')) do r[#r + 1] = ev.d.from .. '>' .. ev.d.to end
  return r
end

function S.mode_tick(W, tr, nth)
  local n = 0
  for _, ev in ipairs(W.find_events('MODE')) do
    if ev.d.from .. '>' .. ev.d.to == tr then
      n = n + 1
      if n == (nth or 1) then return ev.tick end
    end
  end
end

function S.pulls(W, bridge)
  local r = {}
  for _, a in ipairs(W.find_acts('pull')) do
    local lv = W.buildings[a.args[1]]
    if a.ok and (bridge == nil or (lv and lv.bridge == bridge)) then r[#r + 1] = {tick = a.tick, lever = a.args[1], job = a.res} end
  end
  return r
end

function S.acts(W, fn, pred)
  local r = {}
  for _, a in ipairs(W.find_acts(fn)) do if pred == nil or pred(a) then r[#r + 1] = a end end
  return r
end

function S.flips(W, bridge)
  local r = {}
  for _, f in ipairs(W.flips) do if f.bridge == bridge then r[#r + 1] = f end end
  return r
end

function S.kpi(W)
  local ok, k = W.K.call('gate', 'kpi')
  return k
end

S.json = json
return S
