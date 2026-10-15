-- reflex (FR-36/49/51/52/53/58): the arrival lockdown and the interrupt channel, inside the kernel, fail-open.
-- Run 9 (14.10.2026): an army with two cave dragons walked in over lowered drawbridges and 39 of 48 citizens died
-- within 76 s of real time at ~400 ticks/s. SIEGE_START/INVASION were digest events (the first wake was BREACH, with
-- the enemy inside), the seal "failed closed" without a fortcore manifest (sealed 0 ticks), and every actuator was
-- driven by the operator's polling loop (tools/run_guard.py, run_rescue.py), which could not keep up.
--
-- Arrival lockdown (no LLM in the loop). Triggers: an arrival announcement (a popup the arbiter hands over, or a
-- report: "A vile force of darkness has arrived", "ambush", "snatcher", a beast that "has come"; AMBUSH_*,
-- BEAST_AMBUSH, MEGABEAST/WEREBEAST_ARRIVAL), INVASION, or the first armed hostile in sight (a visible invader, a
-- great danger in reach). In the same step, without waiting for a sighting:
--   clock  the arbiter switches timestream off and holds the vanilla FPS cap at the siege cap (it asks M.holding)
--   gates  gate wants every linked drawbridge up: manifest outer/inner bridges and every lever-linked bridge outside
--          the manifest, so a fort without fortcore is covered (same single-pending-pull invariant)
--   doors  the fort's entrance doors are forbidden through act.door_forbid (the door sheet's forbid toggle): a built
--          door on or next to a revealed open-sky tile, and (BUG-012, Run 9: "0 entrances" with a door one tile behind
--          the east stair) the doors seal's entrance check finds on each opening's route toward the citizens and a few
--          steps inside it (seal.entrance_doors; a fresh check is asked for, its doors are added when it lands). Doors
--          the player had forbidden, or opened again during the lockdown, are left alone; the openings without a door
--          are named ("partial lockdown: ... has no door"). A door waits while a citizen is on its outside side
--          (seal.door_outside; the civ alert calls him in), at most ALERT_AFTER ticks, not at all with a visible
--          hostile within DOOR_NEAR of it: nobody is locked out with the army ("1 waiting for 2 citizens outside")
--   alert  siege sounds the civ alert (it asks M.holding) once the gates are up, ALERT_AFTER ticks after the
--          trigger, or at once when no gate is pending or a hostile is near a citizen outside Kern+ or inside: the
--          alert keeps civilians inside its burrow, and live L3 lost every lever pull to it (GATE_FAIL no_worker).
--          siege owns the alert state and seal picks the burrow (Kern+, else the interior Innen+); the text says what
--          really holds ("alert: Innen+ (REFUGE_FAIL ...)", "alert: none (...)"), never what was asked (BUG-011)
-- then ARRIVAL (A) carries what was done and the text. A popup is dismissed by the arbiter only after this returned
-- (FR-36). The lockdown holds until threat is 0 (no visible invader, great danger in reach or hostile inside, the
-- threat scan not armed, ARM ticks after the last trigger) for hold_quiet_days game days; then the doors it forbade
-- open again, clock and alert follow the mode, and gate lowers the bridges it raised (peace_gates D-14 down) or
-- keeps them up (D-14 up). LOCKDOWN_END (B).
--
-- Interrupt channel (FR-53). INTERRUPTS (contract): ARRIVAL; INTRUDER (a visible invader, undead or great danger on
-- the citizens' walkable group); PREDATOR (a visible wild danger on a roofed tile of that group); DEATHS_3PLUS (care);
-- NO_DEPOT (merchants need a trade depot; once per caravan visit, BUG-008). Each goes to <save>/alarm.txt at once (a DEFCON line, then the last
-- interrupts), `dfllm wait --until-interrupt` returns on it, and verb `ack` records the operator's ack. An interrupt
-- still unacked after ack_timeout_s (real seconds, measured on K.now().ms, which also runs while paused) gets its type's lockdown default (config/reflex.json `defaults`)
-- from the kernel itself, and LOCKDOWN (A) says so. state alarm = {defcon 1 (worst) .. 5, unacked, last, ack, lock,
-- why, eta}. ETA (FR-58): nearest visible invader to the nearest entrance (Chebyshev tiles x ETA_TILE ticks).
-- Reads: census (K.census.h/u), building vectors (doors, via gate the levers), snapshot.far/outside_near for tiles.
local fio = require('dfllm.io')
local geom = require('dfllm.util.geom')
local CAD = require('dfllm.util.cadence')   -- BUG-008: NO_DEPOT without a readable caravan

local M = {name = 'reflex', every = {ticks = 10}, critical = true, verbs = {},
           reports = {AMBUSH_AMBUSHER = true, AMBUSH_SNATCHER = true, BEAST_AMBUSH = true, MEGABEAST_ARRIVAL = true,
                      WEREBEAST_ARRIVAL = true, MERCHANTS_NEED_DEPOT = true}}

M.ACTIONS = {'clock', 'gates', 'doors', 'alert'}   -- the closed action vocabulary, in the order they are issued
M.CFG = {
  hold_quiet_days = 2,     -- game days of threat 0 before a lockdown ends (the clock clamp with it)
  ack_timeout_s = 60,      -- real seconds an interrupt may stand unacked before its default applies
  defaults = {ARRIVAL = {'clock', 'gates', 'doors', 'alert'}, INTRUDER = {'clock', 'gates', 'doors', 'alert'},
              PREDATOR = {'clock', 'alert'}, DEATHS_3PLUS = {'clock'}, NO_DEPOT = {}},
}
M.ARM = 2400               -- ticks after the last trigger before the quiet clock may start (threat's armed window)
M.KEEP = 20                -- interrupts kept for alarm.txt and the ack bookkeeping
M.DOOR_EVERY = 2400        -- ticks between entrance-door scans (a trigger without a fresh list scans at once)
M.DOOR_MAX = 400           -- doors looked at per scan
M.REARM = 1200             -- INTRUDER/PREDATOR again only after this many ticks without one
M.ETA_TILE = 6             -- ticks per tile for the ETA (dwarves and goblins walk ~9, fast beasts less)
M.FRESH = 200              -- census.h older than this is unknown (never quiet, no sighting)
M.ALERT_AFTER = 450        -- the civ alert waits at most this long for the gates (siege's RAISE_BY timer)
M.ALERT_NEAR = 30          -- ... and not at all for a hostile this close to a citizen outside Kern+
-- popup / report text -> kind (lower case plain markers)
M.TEXT = {{'vile force of darkness', 'siege'}, {'an ambush', 'ambush'}, {'snatcher', 'snatcher'},
          {'has come', 'beast'}, {'need a trade depot', 'no_depot'}}
local REPORT_KIND = {AMBUSH_AMBUSHER = 'ambush', BEAST_AMBUSH = 'ambush', AMBUSH_SNATCHER = 'snatcher',
                     MEGABEAST_ARRIVAL = 'beast', WEREBEAST_ARRIVAL = 'beast', MERCHANTS_NEED_DEPOT = 'no_depot'}
local ARMY = {siege = true, invasion = true, beast = true, invader = true}   -- DEFCON 2 kinds

local st      -- persisted m.reflex: {v, hold = {why, kinds, acts, since, last, qs}|nil, doors = {ids}, ack = {n, wall},
              --   irq = {{n, type, tick, wall, ms, msg, done}}}
local rt      -- runtime: door cache, sighting/intruder bookkeeping, alarm.txt signature, eta
local dirty

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function save(K) if dirty then K.persist.set('m.reflex', st); dirty = false end end

---------------------------------------------------------------- config (config/reflex.json via K.cfg.reflex)
local function cfg(K)
  local c = {hold_quiet_days = M.CFG.hold_quiet_days, ack_timeout_s = M.CFG.ack_timeout_s, defaults = {}}
  for t, acts in pairs(M.CFG.defaults) do c.defaults[t] = acts end
  local r = type(K.cfg.reflex) == 'table' and K.cfg.reflex or {}
  local q, a = int(r.hold_quiet_days), int(r.ack_timeout_s)
  if q and q >= 0 and q <= 30 then c.hold_quiet_days = q end
  if a and a >= 5 and a <= 3600 then c.ack_timeout_s = a end
  local valid = {}
  for _, x in ipairs(M.ACTIONS) do valid[x] = true end
  for t, acts in pairs(type(r.defaults) == 'table' and r.defaults or {}) do
    if M.CFG.defaults[t] and type(acts) == 'table' then
      local ok, l = true, {}
      for _, x in ipairs(acts) do if valid[x] then l[#l + 1] = x else ok = false end end
      if ok then c.defaults[t] = l end
    end
  end
  return c
end
M.cfg = cfg

function M.kind_of(text)
  local low = tostring(text or ''):lower()
  for _, m in ipairs(M.TEXT) do
    if low:find(m[1], 1, true) then return m[2] end
  end
end

---------------------------------------------------------------- the entrance doors
local function door_pos(b)
  local ok, x, y, z = pcall(function() return b.centerx or b.x1, b.centery or b.y1, b.z end)
  if ok and int(x) and int(y) and int(z) then return {int(x), int(y), int(z)} end
end

local function built(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return not ok or r == true             -- unknown (no stage API): count it
end

-- built doors next to a revealed open-sky tile: {{id, pos}}; nil when the tile test is unavailable (no snapshot)
local function scan_doors(K, now)
  local cand, pts = {}, {}
  local ok = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.DOOR) do
      if #cand >= M.DOOR_MAX then break end
      local p = built(b) and door_pos(b)
      if p then cand[#cand + 1] = {id = b.id, pos = p}; pts[#pts + 1] = p end
    end
  end)
  if not ok then K.log('warn', 'reflex: door scan failed') end
  local list = {}
  if #cand > 0 then
    local okc, out = K.call('snapshot', 'outside_near', pts, 1)
    if okc and type(out) == 'table' then
      for i, c in ipairs(cand) do if out[i] == 1 then list[#list + 1] = c end end
    else list = nil end                   -- no tile test: forbid nothing (forbidding every door would lock rooms)
  end
  rt.doors = {tick = now, list = list}
  return list
end

local function entrance_doors(K, now, force)
  local d = rt.doors
  if not force and d and now >= d.tick and now - d.tick < M.DOOR_EVERY then return d.list end
  return scan_doors(K, now)
end

-- BUG-012: seal's entrance check (doors on the routes from the openings toward the citizens, openings without a
-- door); `refresh` asks it for a fresh check. Returns the export, or nil and 'pending' (no check yet) | 'none' (no
-- seal module)
local function seal_doors(K, refresh)
  local ok, x = K.call('seal', 'entrance_doors', refresh == true)
  if not ok then return nil, 'none' end
  if type(x) ~= 'table' then return nil, 'pending' end
  return x
end

M.OPEN_SHOWN = 2           -- openings without a door named in the text (the rest counted)
M.DOOR_NEAR = 15           -- a visible hostile this close to a waiting door forbids it at once
M.DOOR_POLL = 20           -- ticks between two looks at the doors still waiting for citizens outside

-- citizens on the outside side of each door (seal.door_outside: open sky of its walk group, the porch of its opening,
-- the doorway); without seal, sense's citizens outside Kern+ hold every door. Returns {[id] = n}, distinct n.
local function door_outside(K, list)
  local ids = {}
  for _, d in ipairs(list) do ids[#ids + 1] = d.id end
  local ok, per, n = K.call('seal', 'door_outside', ids)
  if ok and type(per) == 'table' then return per, int(n) or 0 end
  local cu = K.census.u
  local o = type(cu) == 'table' and int(cu.outside) or 0
  local r = {}
  if o and o > 0 then for _, id in ipairs(ids) do r[id] = o end else o = 0 end
  return r, o
end

-- a visible hostile within DOOR_NEAR of p (a fresh census only)
local function hostile_near(K, p, now)
  local h = K.census.h
  if type(h) ~= 'table' or now - (h.tick or -1e9) > M.FRESH then return false end
  for _, e in ipairs(h.list or {}) do
    if geom.dist(e, {x = p[1], y = p[2], z = p[3]}) <= M.DOOR_NEAR then return true end
  end
  return false
end

-- forbid the entrance doors not forbidden yet: the open-sky scan and seal's entrance doors. A door forbidden by
-- us stays ours (never forbidden twice, never again once the player opened it); a door the player forbade is left
-- alone and never opened. Safety (citizens shut out): a door waits while a citizen is on its outside side (the civ
-- alert calls them in meanwhile) and is forbidden once nobody is left there, at once with a visible hostile within
-- DOOR_NEAR of it, and in any case ALERT_AFTER ticks after the lockdown first wanted the doors. Returns the text part
-- and the number newly forbidden; rt.wait = the doors still waiting, rt.wait_out = the citizens they wait for.
local function forbid_doors(K, now, refresh)
  local near = entrance_doors(K, now, refresh)
  local sd, sstate = seal_doors(K, refresh)
  rt.seal_tick = sd and sd.tick or nil
  rt.wait, rt.wait_out, rt.wait_t = {}, 0, now
  if near == nil and sd == nil then
    return sstate == 'pending' and 'doors: no tile test, entrance check pending' or 'doors: no tile test', 0
  end
  local cand, seen = {}, {}
  for _, l in ipairs({near or {}, sd and sd.doors or {}}) do
    for _, d in ipairs(l) do
      if int(d.id) and not seen[d.id] then seen[d.id] = true; cand[#cand + 1] = d end
    end
  end
  rt.door_pts = cand
  local h = st.hold
  if h and not h.doors_at then h.doors_at, dirty = now, true end
  local late = not h or now - (h.doors_at or now) >= M.ALERT_AFTER
  local mine, n, already, todo = {}, 0, 0, {}
  for _, id in ipairs(st.doors) do mine[id] = true end
  for _, d in ipairs(cand) do
    if not mine[d.id] then
      local b = df.building.find(d.id)
      local f = b and b.door_flags and b.door_flags.forbidden
      if b and not f then todo[#todo + 1] = d
      elseif b and f then already = already + 1 end
    end
  end
  local out, nout = {}, 0
  if #todo > 0 and not late then out, nout = door_outside(K, todo) end
  local wait = {}
  for _, d in ipairs(todo) do
    if late or (out[d.id] or 0) == 0 or hostile_near(K, d.pos, now) then
      if K.act.door_forbid(d.id, true) then
        n, mine[d.id] = n + 1, true
        st.doors[#st.doors + 1] = d.id
        dirty = true
      end
    else wait[#wait + 1] = d.id end
  end
  rt.wait, rt.wait_out = wait, #wait > 0 and nout or 0
  local s = string.format('doors %d forbidden', #st.doors)
  if #wait > 0 then
    s = s .. string.format(', %d waiting for %d citizen%s outside', #wait, rt.wait_out, rt.wait_out == 1 and '' or 's')
  end
  if already > 0 then s = s .. ' (' .. already .. ' were already)' end
  if sd and #sd.open > 0 then
    local l = {}
    for i, o in ipairs(sd.open) do
      if i > M.OPEN_SHOWN then break end
      l[#l + 1] = string.format('%s %d,%d,%d', o.kind, o.pos[1], o.pos[2], o.pos[3])
    end
    local more = #sd.open - #l
    s = s .. string.format(', partial lockdown: %s%s %s no door', table.concat(l, ', '),
                           more > 0 and (' +' .. more) or '', #sd.open == 1 and 'has' or 'have')
  elseif not sd and sstate == 'pending' then s = s .. ', entrance check pending' end
  return s, n
end

-- undo after quiet: exactly the doors this lockdown forbade (st.doors), the ones still forbidden
local function open_doors(K)
  local n = 0
  for _, id in ipairs(st.doors) do
    local b = df.building.find(id)
    if b and b.door_flags and b.door_flags.forbidden then
      if K.act.door_forbid(id, false) then n = n + 1 end
    end
  end
  st.doors, dirty = {}, true
  rt.seal_tick, rt.door_pts, rt.wait, rt.wait_out = nil, nil, nil, nil
  return n
end

---------------------------------------------------------------- hold and the actions
local function holding(K, what)
  local h = st and st.hold
  if not h then return nil end
  if what and not h.acts[what] then return nil end
  if what == 'alert' and not h.alert_on then return nil end   -- deferred until the gates are up (ALERT_AFTER)
  return h.why
end

-- public (K.call): why a lockdown holds `what` ('clock'|'gates'|'alert'|'doors'; nil = any), or nil. The arbiter,
-- gate and siege ask it every pass (level-triggered); after a reload the persisted hold answers at once.
function M.holding(K, what) return holding(K, what) end

local function sorted(set)
  local r = {}
  for k in pairs(set) do r[#r + 1] = k end
  table.sort(r)
  return r
end

M.ALERT_TEXT = 90         -- bytes of the alert's answer in the text (the whole of it is d.alert)
M.MSG_MAX = 200           -- an event text is cut there (kern), and so is alarm.txt's copy

-- prefix .. parts (', ' between) .. tail within MSG_MAX: a part that does not fit is left out whole (its numbers are
-- in d), the tail (the announcement) is cut; Run 9's ARRIVAL lost its alert and doors to the cut
local function compose(prefix, parts, tail)
  local s, first = prefix, true
  for _, p in ipairs(parts) do
    local add = (first and '' or ', ') .. p
    if #s + #add <= M.MSG_MAX then s, first = s .. add, false end
  end
  if tail and #s < M.MSG_MAX then s = s .. tail:sub(1, M.MSG_MAX - #s) end
  return s
end

-- issue `acts` (idempotent); returns the parts of the text, in the order they matter (clock, alert, doors, gates,
-- citizens outside, bridge names), and the d fields for the event
local function issue(K, acts, now)
  local part, d = {}, {}
  local want = {}
  for _, a in ipairs(acts) do want[a] = true end
  if want.clock then
    local ok, cap = K.call('arbiter', 'hold')
    d.clock = ok and int(cap) or 0
    part.clock = ok and string.format('clock %d t/s', d.clock) or 'clock: no arbiter'
  end
  if want.gates then
    local ok, info = K.call('gate', 'lockdown')
    if ok and type(info) == 'table' then
      d.raised = int(info.want) or 0
      rt.gates_up = d.raised > 0 and (int(info.up) or 0) >= d.raised
      part.gates = string.format('gates %d wanted up (%d up)', d.raised, int(info.up) or 0)
      if #(info.names or {}) > 0 then part.names = table.concat(info.names, ',') end
    else
      d.raised = 0
      part.gates = 'gates: no gate module'
    end
  end
  if want.doors then
    part.doors = forbid_doors(K, now, true)
    d.doors = #st.doors
  end
  if want.alert then
    local h = st.hold
    -- no gate pending (none wanted, or all up already), or a hostile already near a citizen: at once
    local gates_done = not want.gates or (d.raised or 0) == 0 or rt.gates_up == true
    local hc = K.census.h
    local near = type(hc) == 'table' and (((hc.near_cit or -1) >= 0 and hc.near_cit <= M.ALERT_NEAR) or (hc.inside or 0) > 0)
    if h and not h.alert_on and (gates_done or near) then h.alert_on, dirty = true, true end
    if not h or h.alert_on then
      -- BUG-011: siege's answer is what holds now (the burrow it sounded, or none and why), never the request
      local ok, r, short = K.call('siege', 'hold_alert')
      d.alert = ok and tostring(r):sub(1, 200) or 'none (no siege module)'
      if ok and type(short) == 'string' then part.alert = short end
    else
      h.alert_at = h.alert_at or now + M.ALERT_AFTER
      d.alert = string.format('after the gates (<= %d ticks)', math.max(0, h.alert_at - now))
    end
    local a = part.alert or d.alert
    part.alert = 'alert: ' .. (#a > M.ALERT_TEXT and (a:sub(1, M.ALERT_TEXT - 3) .. '...') or a)
  end
  local cu = K.census.u
  local out = type(cu) == 'table' and int(cu.outside) or nil
  if out and out > 0 then
    d.out = out
    part.out = out .. ' citizens outside Kern+'
  end
  local parts = {}
  for _, k in ipairs({'clock', 'alert', 'doors', 'gates', 'out', 'names'}) do
    if part[k] then parts[#parts + 1] = part[k] end
  end
  return parts, d
end

-- start or extend the lockdown with `acts`; returns the parts of the text of what is in place, and d
local function engage(K, kind, why, acts, now)
  local h = st.hold
  if not h then
    h = {why = tostring(why):sub(1, 24), kinds = {}, acts = {}, since = now, last = now}
    st.hold = h
  end
  h.last, h.qs = now, nil
  -- an arrival names the lockdown even when an unacked interrupt's default started it (status: reason)
  if tostring(why):find('^arrival:') and not h.why:find('^arrival:') then h.why = tostring(why):sub(1, 24) end
  h.kinds[kind] = true
  for _, a in ipairs(acts) do h.acts[a] = true end
  dirty = true
  local parts, d = issue(K, sorted(h.acts), now)
  save(K)
  return parts, d
end

local function release(K, now)
  local h = st.hold
  if not h then return end
  st.hold, dirty = nil, true
  local n = open_doors(K)
  K.call('arbiter', 'hold')
  K.call('gate', 'lockdown')
  K.call('siege', 'hold_alert')
  local msg = string.format('lockdown over (%s): threat 0 for %d days; %d doors opened', h.why,
                            cfg(K).hold_quiet_days, n)
  K.emit('LOCKDOWN_END', 'B', msg, {why = h.why, ticks = now - h.since, doors = n})
  K.log('info', 'reflex: %s', msg)
end

---------------------------------------------------------------- interrupts and alarm.txt
-- number of unacked interrupts and the age of the oldest one in real seconds
local function unacked(K)
  local ack, n, oldest = st.ack.n or 0, 0, nil
  local ms = K.now().ms
  for _, r in ipairs(st.irq) do
    if r.n > ack then
      n = n + 1
      local age = math.max(0, ms - r.ms) // 1000
      if not oldest or age > oldest then oldest = age end
    end
  end
  return n, oldest
end

local function defcon(K)
  local mode, h = K.mode(), K.census.h
  local inside = type(h) == 'table' and (h.inside or 0) > 0
  local open = {}
  for _, r in ipairs(st.irq) do if r.n > (st.ack.n or 0) then open[r.type] = true end end
  if mode == 'BREACH' or inside or open.INTRUDER then return 1 end
  local army = false
  for k in pairs(st.hold and st.hold.kinds or {}) do if ARMY[k] then army = true end end
  if mode == 'SIEGE' or army or open.ARRIVAL then return 2 end
  if mode == 'ALERT' or st.hold or next(open) then return 3 end
  local ok, armed = K.call('threat', 'armed')
  if mode == 'RECOVERY' or mode == 'DRILL' or (ok and armed == 1) then return 4 end
  return 5
end

local function alarm_text(K, dc)
  local n, oldest = unacked(K)
  local lock = st.hold and (st.hold.why .. ' (' .. table.concat(sorted(st.hold.acts), ',') .. ')') or 'off'
  local head = string.format('DEFCON %d | mode %s | unacked %d%s | last %d | ack %d | lockdown %s', dc, K.mode(), n,
                             oldest and string.format(' (oldest %d s)', oldest) or '',
                             st.irq[#st.irq] and st.irq[#st.irq].n or 0, st.ack.n or 0, lock)
  if rt.eta and rt.eta >= 0 then head = head .. string.format(' | eta ~%d t', rt.eta) end
  local lines = {head}
  for _, r in ipairs(st.irq) do
    local s = r.n <= (st.ack.n or 0) and 'acked' or (r.done == 1 and 'default' or 'unacked')
    lines[#lines + 1] = string.format('%d\t%d\t%d\t%s\t%s\t%s', r.n, r.wall, r.tick, r.type, s,
                                      (tostring(r.msg):gsub('[\t\r\n]', ' ')))
  end
  return table.concat(lines, '\n') .. '\n'
end

-- <save>/alarm.txt, rewritten in place when anything in it changed (FR-53)
local function alarm_write(K, force)
  local dc = defcon(K)
  rt.defcon = dc
  local text = alarm_text(K, dc)
  local sig = text:gsub(' %(oldest %d+ s%)', '')   -- the age alone is no reason to rewrite the file
  if not force and sig == rt.alarm_sig then return end
  local path = tostring(K.cfg.paths and K.cfg.paths.save or '.') .. '/alarm.txt'
  local ok, err = fio.write(path, text)
  if ok then rt.alarm_sig = sig
  elseif not rt.alarm_warned then
    rt.alarm_warned = true
    K.log('warn', 'reflex: cannot write %s: %s', path, tostring(err))
  end
end

local function record(K, n, etype, msg)
  local now = K.now()
  st.irq[#st.irq + 1] = {n = n, type = etype, tick = now.tick, wall = now.wall, ms = now.ms,
                         msg = tostring(msg):sub(1, 200), done = 0}
  while #st.irq > M.KEEP do table.remove(st.irq, 1) end
  dirty = true
  alarm_write(K, true)
end

-- emit a class-A interrupt and put it into alarm.txt in the same step
local function interrupt(K, etype, msg, d)
  local n = K.emit(etype, 'A', msg, d)
  if math.type(n) == 'integer' then record(K, n, etype, msg) end
  return n
end

---------------------------------------------------------------- triggers
-- an arrival: lockdown (cfg defaults.ARRIVAL) and ARRIVAL (A, an interrupt) once per kind and lockdown
-- the caravans on the map (plotinfo.caravans with a trade state other than None), as entity id strings
local function caravans_here()
  local r = {}
  pcall(function()
    for _, c in ipairs(df.global.plotinfo.caravans) do
      local okn, s = pcall(function() return df.caravan_state.T_trade_state[c.trade_state] end)
      if not (okn and s == 'None') then r[#r + 1] = tostring(c.entity) end
    end
  end)
  return r
end

-- BUG-008 (Run 9: NO_DEPOT came again every few game days while the merchants waited, a few seconds apart at
-- timestream speed): one NO_DEPOT per caravan visit. st.depot = {ents = {<entity> = 1} of the visits already told,
-- rec = the cadence record}; a visit is forgotten once its caravan left the map. Without a readable caravan the
-- announcement counts as one visit of 'unknown', repeated only after max(7 game days, 10 min wall clock).
local function no_depot(K, text)
  local dep = st.depot or {ents = {}}
  st.depot = dep
  local cars = caravans_here()
  local here, new = {}, false
  for _, e in ipairs(cars) do
    here[e] = true
    if not dep.ents[e] then new = true end
  end
  local T = K.now()
  if #cars == 0 then
    if not CAD.elapsed(dep.rec, T) then return 'no depot reported' end
    here.unknown, new = true, true
  end
  if not new then return 'no depot reported' end
  for e in pairs(here) do dep.ents[e] = 1 end
  rt.dep_chk = T.tick
  dep.rec, dirty = CAD.mark(T, {}, {}), true
  interrupt(K, 'NO_DEPOT', 'caravan without a trade depot: ' .. tostring(text):sub(1, 140), {text = tostring(text):sub(1, 200)})
  return 'no depot reported'
end

-- a visit is forgotten once its caravan left the map (checked every DEPOT_EVERY ticks while one is remembered)
M.DEPOT_EVERY = 100
local function depot_visits(K, now)
  local dep = st.depot
  if not dep or next(dep.ents) == nil or now - (rt.dep_chk or -M.DEPOT_EVERY) < M.DEPOT_EVERY then return end
  rt.dep_chk = now
  local here = {}
  for _, e in ipairs(caravans_here()) do here[e] = true end
  for e in pairs(dep.ents) do
    if e ~= 'unknown' and not here[e] then dep.ents[e], dirty = nil, true end
  end
end

local function arrival(K, kind, src, text)
  local now = K.now().tick
  if kind == 'no_depot' then return no_depot(K, text) end
  local new = not (st.hold and st.hold.kinds[kind])
  local parts, d = engage(K, kind, 'arrival:' .. kind, cfg(K).defaults.ARRIVAL, now)
  if new then
    d.kind, d.src, d.text = kind, src, tostring(text or ''):sub(1, 200)
    if rt.eta and rt.eta >= 0 then d.eta = rt.eta end
    -- what was done first, the announcement last (the text is cut at 200 bytes; d.text keeps it)
    local quoted = text and text ~= '' and ('; "' .. tostring(text):sub(1, 70) .. '"') or ''
    interrupt(K, 'ARRIVAL', compose(string.format('%s (%s) -> ', kind, src), parts, quoted), d)
  end
  return table.concat(parts, ', ')
end

-- public (K.call, arbiter FR-36): a threat or depot popup; the reflexes are issued before this returns, and the
-- arbiter dismisses the popup only after it. kind = siege|ambush|snatcher|beast|no_depot (arbiter's popup kinds)
function M.announce(K, kind, text, src)
  kind = tostring(kind or M.kind_of(text) or '')
  if kind == '' then return false end
  return true, arrival(K, kind, src or 'popup', text)
end

-- every step: the first armed hostile in sight (a visible invader, a great danger in reach of the fort)
local function sighting(K, h, now)
  if (h.inv or 0) > 0 then
    if not (st.hold and st.hold.kinds.invader) then
      arrival(K, 'invader', 'sighting', string.format('%d armed invaders in sight', h.inv))
    end
    return
  end
  if (h.great or 0) > 0 then
    local ok, a = K.call('threat', 'assess')
    if ok and type(a) == 'table' and (a.great_rel or 0) > 0 and not (st.hold and st.hold.kinds.beast) then
      arrival(K, 'beast', 'sighting', 'a great danger in reach')
    end
  end
end

-- INTRUDER / PREDATOR: a visible hostile on the citizens' walkable group (snapshot.far false; unknown counts as
-- the same group, fail-open); a wild danger counts only on a roofed tile (snapshot.outside_near r 0)
local function inside_scan(K, h, now)
  local hostile, predator, nh, np = nil, nil, 0, 0
  for _, e in ipairs(h.list or {}) do
    local ok, far = K.call('snapshot', 'far', e.x, e.y, e.z)
    if not (ok and far == true) then
      if e.k == 'danger' then
        local oko, out = K.call('snapshot', 'outside_near', {{e.x, e.y, e.z}}, 0)
        if oko and type(out) == 'table' and out[1] == 0 then np = np + 1; predator = predator or e end
      else nh = nh + 1; hostile = hostile or e end
    end
  end
  if hostile then
    if now - (rt.intr_last or -M.REARM) >= M.REARM then
      interrupt(K, 'INTRUDER', string.format('%d hostiles on the citizens\' walkable group (%s %d at %d,%d,%d)', nh,
                hostile.k, hostile.id, hostile.x, hostile.y, hostile.z),
                {n = nh, id = hostile.id, pos = {hostile.x, hostile.y, hostile.z}, k = hostile.k})
    end
    rt.intr_last = now
  end
  if predator then
    if now - (rt.pred_last or -M.REARM) >= M.REARM then
      interrupt(K, 'PREDATOR', string.format('%d wild dangers inside the fort (%d at %d,%d,%d)', np, predator.id,
                predator.x, predator.y, predator.z), {n = np, id = predator.id, pos = {predator.x, predator.y, predator.z}})
    end
    rt.pred_last = now
  end
end

-- FR-58: ticks until the nearest visible invader or great danger could reach the nearest entrance; -1 unknown
local function eta(K, h, now)
  local pts = {}
  local okg, gp = K.call('gate', 'points')
  for _, p in ipairs(okg and type(gp) == 'table' and gp or {}) do pts[#pts + 1] = p end
  for _, d in ipairs(rt.door_pts or rt.doors and rt.doors.list or {}) do
    pts[#pts + 1] = {x = d.pos[1], y = d.pos[2], z = d.pos[3]}
  end
  local best = -1
  if #pts > 0 then
    for _, e in ipairs(h.list or {}) do
      if e.k == 'inv' or e.k == 'great' then
        for _, p in ipairs(pts) do
          local dd = geom.dist(e, p)
          if best < 0 or dd < best then best = dd end
        end
      end
    end
  end
  rt.eta = best >= 0 and best * M.ETA_TILE or -1
end

-- the deferred civ alert of a lockdown: on once the gates are up, after ALERT_AFTER, or when a hostile comes near
local function alert_step(K, h, now)
  local hd = st.hold
  if not (hd and hd.acts.alert and not hd.alert_on) then return end
  local near = type(h) == 'table' and (((h.near_cit or -1) >= 0 and h.near_cit <= M.ALERT_NEAR) or (h.inside or 0) > 0)
  local ok, sealed = K.call('gate', 'sealed')
  local why = (ok and sealed == true and 'gates up') or (near and 'hostile near') or
              (now >= (hd.alert_at or now) and 'timer') or nil
  if not why then return end
  hd.alert_on, dirty = true, true
  local okc, r = K.call('siege', 'hold_alert')
  K.log('info', 'reflex: civ alert: %s (%s)', okc and tostring(r) or 'none (no siege module)', why)
end

-- BUG-012: while a lockdown holds the doors, a new answer of seal's entrance check (the fresh check the lockdown
-- asked for, a lever pull, a construction) may name doors not forbidden yet; they are forbidden at once
-- and the doors still waiting for citizens outside are looked at every DOOR_POLL ticks
local function door_step(K, now)
  local hd = st.hold
  if not (hd and hd.acts.doors) then return end
  local x = seal_doors(K, false)
  local news = x and x.tick ~= rt.seal_tick
  local poll = rt.wait and #rt.wait > 0 and (now - (rt.wait_t or now) >= M.DOOR_POLL or now < (rt.wait_t or now))
  if not (news or poll or (rt.wait == nil and hd.doors_at)) then return end
  local s, n = forbid_doors(K, now, false)
  if n > 0 then K.log('info', 'reflex: %d more entrance doors forbidden: %s', n, s) end
end

-- the quiet clock: no visible invader, great danger in reach or hostile inside, threat not armed, ARM after the
-- last trigger; hold_quiet_days of it end the lockdown
local function quiet_step(K, h, now)
  local hd = st.hold
  if not hd then return end
  local fresh = type(h) == 'table' and now - (h.tick or -1e9) <= M.FRESH
  local quiet = fresh and (h.inv or 0) == 0 and (h.inside or 0) == 0 and now - hd.last >= M.ARM
  if quiet and (h.great or 0) > 0 then
    local ok, a = K.call('threat', 'assess')
    quiet = ok and type(a) == 'table' and (a.great_rel or 0) == 0
  end
  if quiet then
    local ok, armed = K.call('threat', 'armed')
    quiet = not (ok and armed == 1)
  end
  if not quiet then
    if hd.qs then hd.qs, dirty = nil, true end
    return
  end
  if not hd.qs then hd.qs, dirty = now, true end
  if now - hd.qs >= cfg(K).hold_quiet_days * 1200 then release(K, now) end
end

-- ack timeout: an interrupt unacked for ack_timeout_s gets its type's lockdown default, and LOCKDOWN (A) says so
local function ack_step(K, now)
  local c = cfg(K)
  local ms = K.now().ms
  for _, r in ipairs(st.irq) do
    if ms < r.ms then r.ms, dirty = ms, true end     -- the real-time clock restarted (reboot): count again
    local age = (ms - r.ms) // 1000
    if r.n > (st.ack.n or 0) and r.done == 0 and age >= c.ack_timeout_s then
      r.done, dirty = 1, true
      local acts = c.defaults[r.type] or {}
      if #acts == 0 then
        K.log('info', 'reflex: interrupt #%d %s unacked for %d s; no default action', r.n, r.type, age)
      else
        local parts, d = engage(K, 'unacked', 'unacked:' .. r.type, acts, now)
        d.why, d.n, d.type = 'ack_timeout', r.n, r.type
        K.emit('LOCKDOWN', 'A', compose(string.format('interrupt #%d %s unacked for %d s: kernel applied its default: ',
               r.n, r.type, age), parts), d)
      end
      alarm_write(K, true)
    end
  end
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.reflex')
  st = {v = 2, doors = {}, ack = {n = 0, wall = 0}, irq = {}}
  if type(p) == 'table' then
    for _, id in ipairs(type(p.doors) == 'table' and p.doors or {}) do
      if int(id) then st.doors[#st.doors + 1] = int(id) end
    end
    if type(p.ack) == 'table' then st.ack = {n = int(p.ack.n) or 0, wall = int(p.ack.wall) or 0} end
    for _, r in ipairs(type(p.irq) == 'table' and p.irq or {}) do
      if type(r) == 'table' and int(r.n) and type(r.type) == 'string' then
        st.irq[#st.irq + 1] = {n = int(r.n), type = r.type, tick = int(r.tick) or 0, wall = int(r.wall) or 0,
                               ms = int(r.ms) or K.now().ms, msg = tostring(r.msg or ''), done = int(r.done) == 1 and 1 or 0}
      end
    end
    local dp = p.depot
    if type(dp) == 'table' and type(dp.ents) == 'table' then
      st.depot = {ents = {}, rec = type(dp.rec) == 'table' and {t = int(dp.rec.t), w = int(dp.rec.w)} or nil}
      for e, v in pairs(dp.ents) do if v == 1 then st.depot.ents[tostring(e)] = 1 end end
    end
    local h = p.hold
    if type(h) == 'table' and type(h.why) == 'string' then
      st.hold = {why = h.why, kinds = {}, acts = {}, since = int(h.since) or 0, last = int(h.last) or 0, qs = nil,
                 alert_on = h.alert_on == true, alert_at = int(h.alert_at), doors_at = int(h.doors_at)}
      for k, v in pairs(type(h.kinds) == 'table' and h.kinds or {}) do if v == true then st.hold.kinds[k] = true end end
      for k, v in pairs(type(h.acts) == 'table' and h.acts or {}) do if v == true then st.hold.acts[k] = true end end
    end
  end
  rt, dirty = {}, false
end

function M.step(K, budget, ctx)
  local now = K.now().tick
  local h = K.census.h
  local fresh = type(h) == 'table' and now - (h.tick or -1e9) <= M.FRESH
  if fresh and h.tick ~= rt.htick then
    rt.htick = h.tick
    sighting(K, h, now)
    inside_scan(K, h, now)
    eta(K, h, now)
  end
  if not rt.doors or now - rt.doors.tick >= M.DOOR_EVERY or now < rt.doors.tick then entrance_doors(K, now) end
  alert_step(K, h, now)
  door_step(K, now)
  quiet_step(K, h, now)
  ack_step(K, now)
  depot_visits(K, now)
  alarm_write(K)
  save(K)
end

M.on = {
  INVASION = function(K, ev)
    arrival(K, 'invasion', 'invasion', string.format('invasion %d', int(ev.id) or -1))
    alarm_write(K)
  end,
  REPORT = function(K, ev)
    local kind = M.kind_of(ev.text) or REPORT_KIND[ev.type]
    if kind then arrival(K, kind, 'report', ev.text ~= '' and ev.text or ev.type) end
  end,
  ['EV:DEATHS_3PLUS'] = function(K, ev)
    record(K, ev.n, ev.type, ev.msg)
    save(K)
  end,
  MODE = function(K, ev) alarm_write(K) end,
}

-- verb `ack {n?}`: the operator saw the interrupts up to n (default: all); the timeout default no longer applies
M.verbs.ack = function(K, args, cmd)
  local last = st.irq[#st.irq] and st.irq[#st.irq].n or 0
  local n = args.n == nil and last or int(args.n)
  if not n or n < 0 then return false, 'n must be an event number >= 0' end
  if n > (st.ack.n or 0) then st.ack = {n = n, wall = K.now().wall}; dirty = true end
  local open = unacked(K)
  alarm_write(K, true)
  save(K)
  return true, string.format('acked up to #%d (%d interrupts open, DEFCON %d)', st.ack.n, open, rt.defcon or 5),
         {n = st.ack.n, open = open, defcon = rt.defcon or 5}
end

function M.state(K)
  local open = unacked(K)
  local a = {defcon = rt.defcon or defcon(K), unacked = open, last = st.irq[#st.irq] and st.irq[#st.irq].n or 0,
             ack = st.ack.n or 0, lock = st.hold and 1 or 0, why = st.hold and st.hold.why:sub(1, 24) or ''}
  if rt.eta then a.eta = rt.eta end
  if st.hold and st.hold.acts.doors then           -- the lockdown's doors: forbidden, waiting, citizens outside
    a.doors = #st.doors
    if rt.wait and #rt.wait > 0 then a.dwait, a.dout = #rt.wait, rt.wait_out or 0 end
  end
  return {alarm = a}
end

return M
