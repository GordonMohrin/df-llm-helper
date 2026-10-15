-- BUG-013 (Run 9 forced arrival on 677bc3e: the civ alert held every civilian in Kern+ within 6 s of the popup, the
-- four gate levers lay outside Kern+, their PullLever jobs stayed unclaimed for minutes, 1-3 of 4 bridges rose): the
-- real sense, threat, siege, gate, reflex and seal on one k_mock world without a fort manifest
-- (tests/lua/seal_world.lua: DF-like walk groups, burrows painted by seal), four lever-linked drawbridges whose levers
-- lie in a lever room outside Kern+, and a PullLever simulator that follows DF's burrow rule: while the civ alert
-- sounds a civilian takes a job only when its tile lies in one of the alert's burrows (the path there may cross
-- other tiles). Checked: every pull gets done with the alert on, the alert burrow list holds the lever tiles (seal's
-- Hebel+) only while pulls are pending, the alert waits for the pulls or its deadline (2x the lever latency,
-- 450..1500 ticks, 900 unmeasured) and sounds at once with a hostile near a citizen, the texts say what holds, a
-- door waits for a citizen outside from the alert on, and LOCKDOWN_END lowers the bridges after the alert.
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local Z = 5                                    -- the fort level; the surface is Z + 1
local BRIDGES = {{30, 5}, {32, 5}, {34, 5}, {36, 5}}          -- surface drawbridges, lowered
local LEVERS = {{14, 7}, {15, 7}, {16, 7}, {17, 7}}           -- the lever room, outside Kern+

local function key(p) return p[1] .. ',' .. p[2] .. ',' .. p[3] end

-- surface z 6: an open field x0-40 y0-24 with a down stair at 20,10 and four 1x1 drawbridges. Fort z 5: hall x2-12
-- y4-16 (beds, drink, food, the citizens, Kern+: it passes its audit), corridor y10 x13-18 to a door at 19,10 and the
-- up stair at 20,10, a lever room x14-17 y6-8 off the corridor (15,9) with one lever per bridge.
local function fort(opts)
  opts = opts or {}
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}
  if opts.lat then persist['m.gate'] = {v = 2, br = {}, kpi = {}, lat = {s = 20, t = opts.lat}} end
  local W = SW.new{persist = persist}
  W.ms_per_frame = 100
  SW.fill(W, Z + 1, 0, 0, 40, 24, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 24, '#')
  SW.fill(W, Z, 2, 4, 12, 16, '.')
  SW.fill(W, Z, 13, 10, 18, 10, '.')
  SW.draw(W, Z, {'+<'}, 19, 10)
  SW.fill(W, Z, 14, 6, 17, 8, '.')
  SW.draw(W, Z, {'.'}, 15, 9)
  SW.draw(W, Z, {'bb'}, 3, 5)
  W.bridge, W.levers = {}, {}
  for i, p in ipairs(BRIDGES) do
    local b = SW.bridge(W, {p[1], p[2], Z + 1, p[1], p[2], Z + 1}, false)
    local lv = SW.lever(W, LEVERS[i][1], LEVERS[i][2], Z, b)
    lv.bridge = b
    W.bridge[i], W.levers[i] = b, lv
  end
  SW.regroup(W)
  SW.item(W, 'DRINK', 5, 6, Z, 20)
  SW.item(W, 'FOOD', 6, 6, Z, 20)
  for _, c in ipairs({{1, 5, 8}, {2, 6, 9}, {3, 7, 10}, {4, 8, 11}}) do
    W.add_unit{id = c[1], pos = {c[2], c[3], Z}, citizen = true, adult = true}
  end
  for _, u in ipairs(opts.units or {}) do W.add_unit(u) end
  W.burrow('Kern+', {2, 4, Z, 12, 16, Z})
  -- the burrows screen, the civ-alert screen, the lever sheet (pull, cancel)
  W.alert_hist = {}
  W.act_result('alert_burrows', function(names)
    for _, n in ipairs(names) do if not dfhack.burrows.findByName(n) then return false, 'no burrow ' .. n end end
    W.alert_burrows = names
    W.alert_hist[#W.alert_hist + 1] = {tick = W.K.now().tick, names = names}
    return true, #names
  end)
  W.act_result('door_forbid', function(id, on)
    local b = W.buildings[id]
    if not b or not b.door_flags then return false, 'not a door' end
    local old = b.door_flags.forbidden
    b.door_flags.forbidden = on and true or false
    return true, old
  end)
  W.job_seq, W.own = 7000, {}
  W.act_result('pull', function(lid)
    local lv = W.buildings[lid]
    if not (lv and lv.trap_type == df.trap_type.Lever) then return false, 'not a lever' end
    W.job_seq = W.job_seq + 1
    lv.jobs:insert('#', {id = W.job_seq, job_type = df.job_type.PullLever, _q = W.K.now().tick})
    W.own[W.job_seq] = lv
    return true, W.job_seq
  end)
  W.act_result('cancel_own_lever_job', function(id)
    local lv = W.own[id]
    if not lv then return false, 'not our job' end
    W.own[id] = nil
    for i = #lv.jobs - 1, 0, -1 do if lv.jobs[i].id == id then lv.jobs:erase(i); return true end end
    return false, 'job no longer pending'
  end)
  dfhack.job = {getWorker = function(j) return j._worker end}
  if opts.no_paint then W.act_result('burrow_tiles', function() return false, 'test: paint refused' end) end
  W.take = opts.take or 60                     -- ticks a free civilian needs to take an allowed job ...
  W.pull_t, W.move_t = 30, 20                  -- ... to pull it, and the bridge to move
  W.busy_until = opts.busy_until               -- abs tick before which nobody is free
  local snap = {name = 'snapshot', every = {ticks = 100}}
  snap.outside_near = require('dfllm.snapshot').outside_near
  function snap.far() return false end
  for _, n in ipairs({'reflex', 'seal'}) do package.loaded['dfllm.' .. n] = nil end
  S.load(W, {S.military(), snap, require('dfllm.reflex'), require('dfllm.seal')})
  return W
end

-- DF's burrow rule for the PullLever jobs: with the civ alert on, a civilian takes a job only on a tile of one of the
-- alert's burrows (he may walk outside them to get there); the bridge moves after the pull
local function in_alert(W, p)
  for _, n in ipairs(W.alert_burrows or {}) do
    local b = dfhack.burrows.findByName(n)
    if b and dfhack.burrows.isAssignedTile(b, {x = p[1], y = p[2], z = p[3]}) then return true end
  end
  return false
end

local function sim(W)
  local now = W.K.now().tick
  local alert = df.global.plotinfo.alerts.civ_alert_idx ~= 0
  local free = not W.busy_until or now >= W.busy_until
  for _, lv in ipairs(W.levers) do
    for i = #lv.jobs - 1, 0, -1 do
      local j = lv.jobs[i]
      if not j._worker then
        local ok = free and (not alert or in_alert(W, {lv.x1, lv.y1, lv.z}))
        if ok then j._ok = j._ok or now else j._ok = nil end
        if j._ok and now - j._ok >= W.take then
          j._worker, j._w = {id = 1}, now
          W.taken = W.taken or {}
          W.taken[#W.taken + 1] = {tick = now, lever = lv.id, alert = alert}
        end
      end
      if j._worker and now - j._w >= W.pull_t then
        lv.jobs:erase(i)
        W.own[j.id] = nil
        local gf = lv.bridge.gate_flags
        gf.raising, gf.lowering = not gf.raised, gf.raised
        lv.bridge._end = now + W.move_t
      end
    end
  end
  for _, b in ipairs(W.bridge) do
    local gf = b.gate_flags
    if b._end and now >= b._end then
      gf.raised = gf.raising
      gf.raising, gf.lowering, b._end = false, false, nil
      W.flips = W.flips or {}
      W.flips[#W.flips + 1] = {tick = now, id = b.id, up = gf.raised}
      SW.regroup(W)
    end
  end
end

local function run(W, ticks, each)
  local done = 0
  while done < ticks do
    W.frame(9)
    sim(W)
    if each then each(W) end
    done = done + 9
  end
end

local function up(W)
  local n = 0
  for _, b in ipairs(W.bridge) do if b.gate_flags.raised then n = n + 1 end end
  return n
end
local function idx() return df.global.plotinfo.alerts.civ_alert_idx end
local function acts(W, fn, val)
  local r = {}
  for i, a in ipairs(W.acts) do
    if a.fn == fn and (val == nil or a.args[1] == val) then a.i = i; r[#r + 1] = a end
  end
  return r
end
local function has(list, x) for _, v in ipairs(list or {}) do if v == x then return true end end return false end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end
local function last_flip(W)
  local t = -1
  for _, f in ipairs(W.flips or {}) do if f.up and f.tick > t then t = f.tick end end
  return t
end

local function settle(W) run(W, 1800) end      -- seal's first audit and entrance check, Kern+ ok

T.test('the fort: Kern+ passes its audit, the four levers lie outside it, no manifest bridge', function()
  local W = fort()
  settle(W)
  local r = W.inbox('inspect', {what = 'refuge'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.burrows['Kern+'].ok, 1, r.data.burrows['Kern+'].why)
  local kern = dfhack.burrows.findByName('Kern+')
  for _, p in ipairs(LEVERS) do T.eq(dfhack.burrows.isAssignedTile(kern, {x = p[1], y = p[2], z = Z}), false) end
  T.eq(W.K.manifest().bridges, nil)
  T.eq(#acts(W, 'pull'), 0, 'PEACE: nothing pulled')
end)

T.test('BUG-013: a hostile near a citizen sounds the alert at once; every pull is done with the alert on, the alert ' ..
       'list holds Hebel+ with the lever tiles while pulls are pending, and only then', function()
  -- a woodcutter on the field at 24,9; a goblin comes into sight at 24,13 (4 tiles from him)
  local W = fort{units = {{id = 9, pos = {24, 9, Z + 1}, citizen = true, adult = true},
                          S.inv(300, 24, 13, Z + 1, {hidden = true})}}
  settle(W)
  W.unit(300)._m.hidden = false
  run(W, 30)
  local arr = W.find_events('ARRIVAL')
  T.eq({#arr, arr[1] and arr[1].d.kind}, {1, 'invader'})
  W.inbox('ack', {})
  local t0 = arr[1].tick
  T.ok(arr[1].msg:find('alert: Kern+, doors 1 forbidden, gates: 0 of 4 up, 4 pulls pending (levers in Hebel+)', 1,
       true), arr[1].msg)
  T.eq({arr[1].d.raised, arr[1].d.up, arr[1].d.left, arr[1].d.blocked}, {4, 0, 4, 0})
  T.eq(idx(), 1, 'a hostile near a citizen: the alert at once')
  local on = acts(W, 'civ_alert', true)
  T.ok(#on == 1 and on[1].tick - t0 <= 10, 'sounded in the trigger step')
  -- the alert list: Kern+ and the lever burrow, which holds every lever tile
  T.eq(W.alert_burrows, {'Kern+', 'Hebel+'})
  local hb = dfhack.burrows.findByName('Hebel+')
  T.ok(hb ~= nil, 'seal painted the lever burrow')
  for _, p in ipairs(LEVERS) do
    T.eq(dfhack.burrows.isAssignedTile(hb, {x = p[1], y = p[2], z = Z}), true, 'lever tile ' .. key({p[1], p[2], Z}))
  end
  T.ok(logged(W, 'seal: Hebel+ painted with 4 lever tiles'), 'kern.log names the paint')
  run(W, 400)
  T.eq(up(W), 4, 'all four bridges up with the alert on')
  for _, tk in ipairs(W.taken or {}) do T.eq(tk.alert, true, 'pull taken under the alert at ' .. tk.tick) end
  T.eq(#(W.taken or {}), 4)
  T.eq(idx(), 1)
  T.eq(W.alert_burrows, {'Kern+'}, 'the pulls are done: the lever burrow left the list')
  local drop
  for _, h in ipairs(W.alert_hist) do if h.tick > t0 and not has(h.names, 'Hebel+') then drop = drop or h.tick end end
  T.ok(drop and drop >= last_flip(W), 'Hebel+ dropped only after the last bridge was up')
  T.eq(#W.find_events('GATE_FAIL'), 0)
  T.ok(logged(W, 'reflex: alert on, gates: 0 of 4 up, 4 pulls pending (levers in Hebel+)'), 'kern.log says what holds')
end)

T.test('BUG-013: no hostile near: the alert waits for the pulls and sounds once the gates are up, long before the ' ..
       'deadline; Hebel+ is never listed; LOCKDOWN_END lowers the bridges only after the alert is off', function()
  local W = fort()
  settle(W)
  W.event('INVASION', {id = 1})
  run(W, 30)
  W.inbox('ack', {})
  local arr = W.find_events('ARRIVAL')[1]
  local t0 = arr.tick
  T.ok(arr.msg:find('alert: after the gates (<= 900 ticks)', 1, true), 'no lever latency measured yet: ' .. arr.msg)
  T.ok(arr.msg:find('gates: 0 of 4 up, 4 pulls pending', 1, true), arr.msg)
  T.eq(idx(), 0)
  run(W, 300)
  T.eq(up(W), 4)
  local on = acts(W, 'civ_alert', true)
  T.eq(#on, 1)
  local lu = last_flip(W)
  T.ok(on[1].tick >= lu and on[1].tick - lu <= 20, string.format('alert %d, last bridge up %d', on[1].tick, lu))
  T.ok(on[1].tick - t0 < 450, 'before any deadline: ' .. (on[1].tick - t0))
  T.ok(logged(W, 'reflex: civ alert: Kern+ (gates up); gates: 4 of 4 up'), 'kern.log')
  for _, h in ipairs(W.alert_hist) do T.eq(has(h.names, 'Hebel+'), false) end
  local st = W.state()
  T.ok(st.lever.lat_t > 0 and st.lever.lat_t < 200, 'latency measured: ' .. st.lever.lat_t)
  -- threat 0 for 2 days: LOCKDOWN_END, the alert off, then the lowering pulls (D-14 down)
  local n = 0
  while #W.find_events('LOCKDOWN_END') == 0 and n < 80 do run(W, 100); n = n + 1 end
  local e = W.find_events('LOCKDOWN_END')
  T.eq(#e, 1)
  run(W, 400)
  T.eq(up(W), 0, 'the bridges the lockdown raised are lowered again')
  local off = acts(W, 'civ_alert', false)
  T.eq(#off, 1)
  local downs = {}
  for _, a in ipairs(acts(W, 'pull')) do if a.tick >= e[1].tick then downs[#downs + 1] = a end end
  T.eq(#downs, 4)
  T.ok(off[1].i < downs[1].i, 'the alert went off before the first lowering pull was queued')
  for _, tk in ipairs(W.taken) do if tk.tick >= e[1].tick then T.eq(tk.alert, false) end end
end)

T.test('BUG-013: pulls left at the deadline (unmeasured latency: 900 ticks): the alert sounds with Hebel+ listed ' ..
       'and the pulls are done under it', function()
  local W = fort()
  settle(W)
  W.busy_until = W.K.now().tick + 1150          -- nobody free for the levers until T+1,150
  W.event('INVASION', {id = 2})
  run(W, 30)
  W.inbox('ack', {})
  local t0 = W.find_events('ARRIVAL')[1].tick
  run(W, 850)
  T.eq(idx(), 0, 'still waiting for the pulls')
  run(W, 100)
  T.eq(idx(), 1, 'the deadline')
  local on = acts(W, 'civ_alert', true)[1]
  T.ok(on.tick - t0 >= 900 and on.tick - t0 <= 920, 'T+' .. (on.tick - t0))
  T.eq(W.alert_burrows, {'Kern+', 'Hebel+'}, 'pulls pending: the lever tiles are in the alert')
  T.ok(logged(W, 'reflex: civ alert: Kern+ (deadline 900 ticks, 4 pulls left); gates: 0 of 4 up, 4 pulls pending'),
       'kern.log')
  run(W, 600)
  T.eq(up(W), 4, 'every pull done with the alert on')
  for _, tk in ipairs(W.taken) do T.eq(tk.alert, true) end
  T.eq(idx(), 1)
  T.eq(W.alert_burrows, {'Kern+'})
  local gf = W.find_events('GATE_FAIL')
  for _, g in ipairs(gf) do T.eq(g.d.why, 'no_worker', 'nobody was free; the alert did not keep them away') end
end)

T.test('BUG-013: the deadline follows the measured lever latency: 2x, at least 450, at most 1500 ticks', function()
  for _, c in ipairs({{lat = 600, wait = 1200}, {lat = 100, wait = 450}, {lat = 2000, wait = 1500}}) do
    local W = fort{lat = c.lat}
    settle(W)
    W.busy_until = W.K.now().tick + 1700
    W.event('INVASION', {id = 3})
    run(W, 30)
    W.inbox('ack', {})
    local arr = W.find_events('ARRIVAL')[1]
    T.ok(arr.msg:find(string.format('alert: after the gates (<= %d ticks)', c.wait), 1, true), arr.msg)
    run(W, c.wait - 60)
    T.eq(idx(), 0, 'lat ' .. c.lat .. ': still waiting')
    run(W, 100)
    T.eq(idx(), 1, 'lat ' .. c.lat .. ': the deadline')
    local d = acts(W, 'civ_alert', true)[1].tick - arr.tick
    T.ok(d >= c.wait and d <= c.wait + 20, string.format('lat %d: T+%d, want %d', c.lat, d, c.wait))
  end
end)

T.test('BUG-013 + BUG-012: a door waits for a citizen outside ALERT_AFTER ticks after the alert began to call him ' ..
       'in, not after the trigger (the alert waited for the pulls)', function()
  local W = fort{units = {{id = 9, pos = {24, 9, Z + 1}, citizen = true, adult = true}}}
  settle(W)
  local door = W.dyn[SW.key(19, 10, Z)]
  W.busy_until = W.K.now().tick + 300           -- the pulls take a while: the alert sounds at about T+400
  W.event('INVASION', {id = 5})
  run(W, 30)
  W.inbox('ack', {})
  local arr = W.find_events('ARRIVAL')[1]
  local t0 = arr.tick
  T.ok(arr.msg:find('1 waiting for 1 citizen outside', 1, true), arr.msg)
  run(W, 1200)
  local on = acts(W, 'civ_alert', true)[1]
  local f = acts(W, 'door_forbid', door.id)[1]
  T.ok(on and on.tick - t0 > 300, 'the alert waited for the pulls: T+' .. (on and on.tick - t0 or -1))
  T.ok(f and f.tick - on.tick >= 450 and f.tick - on.tick <= 480,
       string.format('door at T+%d, alert at T+%d', f and f.tick - t0 or -1, on.tick - t0))
  T.eq(door.door_flags.forbidden, true)
end)

T.test('BUG-013: seal.lever_burrow keeps the lever tiles current: a new lever is painted, an erased tile comes back',
       function()
  local W = fort()
  settle(W)
  local tiles = {{14, 7, Z}, {15, 7, Z}}
  T.eq({W.K.call('seal', 'lever_burrow', tiles)}, {true, 'Hebel+'})
  local hb = dfhack.burrows.findByName('Hebel+')
  local function paints()
    local n = 0
    for _, a in ipairs(W.find_acts('burrow_tiles')) do if a.args[1] == 'Hebel+' then n = n + 1 end end
    return n
  end
  T.eq(paints(), 1)
  W.K.call('seal', 'lever_burrow', tiles)
  T.eq(paints(), 1, 'unchanged: no paint')
  tiles[3] = {16, 7, Z}
  W.K.call('seal', 'lever_burrow', tiles)
  T.eq(paints(), 2, 'a new linked lever')
  T.eq(W.find_acts('burrow_tiles')[#W.find_acts('burrow_tiles')].args[2], {{16, 7, Z}}, 'only the missing tile')
  dfhack.burrows.setAssignedTile(hb, {x = 14, y = 7, z = Z}, false)   -- the player erases a tile
  W.K.call('seal', 'lever_burrow', tiles)
  T.eq(paints(), 2, 'trusted for lever_check ticks')
  run(W, 120)
  W.K.call('seal', 'lever_burrow', tiles)
  T.eq(paints(), 3, 'read again and repainted')
  T.eq(dfhack.burrows.isAssignedTile(hb, {x = 14, y = 7, z = Z}), true)
  T.eq({W.K.call('seal', 'lever_burrow', {})}, {true, nil, 'no lever'})
end)

T.test('BUG-013: without the lever burrow (painting refused) the alert blocks the pulls, and the texts say so',
       function()
  local W = fort{no_paint = true, lat = 100}    -- deadline 450
  W.K.cfg.reflex.ack_timeout_s = 15             -- the default re-issues the lockdown while it still holds
  settle(W)
  T.eq(W.inbox('inspect', {what = 'refuge'}).data.burrows['Kern+'].ok, 1, 'Kern+ still holds the alert')
  W.busy_until = W.K.now().tick + 600
  W.event('INVASION', {id = 4})
  run(W, 30)
  local t0 = W.find_events('ARRIVAL')[1].tick
  run(W, 1200)
  T.eq(idx(), 1)
  T.eq(W.alert_burrows, {'Kern+'}, 'no lever burrow')
  T.eq(up(W), 0, 'DF\'s rule: nobody may take a pull outside the alert burrow')
  T.eq(#(W.taken or {}), 0)
  T.ok(logged(W, 'reflex: alert on, gates: 0 of 4 up, 4 pulls blocked (levers outside the alert burrow)'), 'kern.log')
  local gf = W.find_events('GATE_FAIL')
  T.ok(#gf >= 1, 'GATE_FAIL')
  T.eq(gf[1].d.why, 'outside_alert')
  T.ok(gf[1].msg:find('no worker: its levers lie outside the alert burrow', 1, true), gf[1].msg)
  T.ok(gf[1].tick - t0 >= 900, 'at the gate deadline')
  local tries = 0
  for _, a in ipairs(W.find_acts('burrow_tiles')) do if a.args[1] == 'Hebel+' then tries = tries + 1 end end
  T.ok(tries >= 1 and tries <= 3, 'a refused paint is retried every 600 ticks, not every step: ' .. tries)
  -- unacked: the ack timeout re-issues the lockdown and LOCKDOWN says what holds
  local n = 0
  while #W.find_events('LOCKDOWN') == 0 and n < 60 do run(W, 100); n = n + 1 end
  local l = W.find_events('LOCKDOWN')
  T.eq(#l, 1)
  T.ok(l[1].msg:find('gates: 0 of 4 up, 4 pulls blocked (levers outside the alert burrow)', 1, true), l[1].msg)
  T.eq(l[1].d.blocked, 4)
end)

T.done()
