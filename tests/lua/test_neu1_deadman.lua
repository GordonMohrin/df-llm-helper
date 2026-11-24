-- Neuausrichtung 1 / P3 (docs/v2/NEU1-wecken.md, BUG-792 context): the arbiter's dead-man switch pauses the game when no live
-- player session wrote <save>/session.json for reflex.json deadman.timeout_s real seconds; pause only, never unpause. The verb
-- `park` pauses on purpose (owner park, nothing wakes); `resume` releases pause:deadman and pause:park. Interactions: a load
-- pause (df) and Gordon's pause are left alone, an inbox TTL hold is taken over, popups do not unpause it, a human who
-- unpauses it in DF is not fought.
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')
local arbiter = require('dfllm.arbiter')
arbiter.PROFILE.overlays = true

local W, K

local DM = {v = 2, deadman = {on = true, timeout_s = 600, max_ticks = 0, check_s = 1, grace_s = 0}}

-- opts: session (false = none, a number = its age in s), paused (a save loaded paused), reflex (K.cfg.reflex)
local function world(opts)
  opts = opts or {}
  W = H.world{tag = opts.tag or 'deadman', ms_per_frame = 1000}
  W.hb_auto = false                                   -- this suite writes every heartbeat itself
  dfhack.gui = dfhack.gui or {}
  dfhack.gui.getDFViewscreen = function() return 'df_main' end
  package.loaded.gui = {simulateInput = function(_, key)
    if key == 'D_PAUSE' then df.global.pause_state = not df.global.pause_state end
  end}
  df.global.pause_state = opts.paused == true
  local ok, msg = H.boot(W, {modules = {arbiter}, session = opts.session})
  assert(ok, msg)
  K = kern.K()
  K.cfg.reflex = opts.reflex or DM
  return W
end

local function session(age) H.write(W.sd .. '/session.json', json.encode({v = 2, wall = os.time() - age, by = 'wait'})) end
local function owner() K.flush(); H.frame(W, 0); return H.state(W).owners.pause end
local function ev(etype)
  K.flush(); H.frame(W, 0)
  local n = {}
  for _, e in ipairs(H.events(W)) do if e.type == etype then n[#n + 1] = e end end
  return n
end
local function verb(id, v, args)
  H.inbox(W, id, v, args or {}, 'llm')
  H.run(W, 3, {paused = true})
  return H.outbox(W, id)
end

T.test('a stale session pauses a running game: owner deadman, one DEADMAN_PAUSE (A) with the age; a fresh one does not', function()
  world{session = 30}
  H.run(W, 20)
  T.eq(df.global.pause_state, false, 'a 30 s old heartbeat is a live session')
  T.eq(owner(), nil)
  session(1000)
  H.run(W, 5)
  T.eq(df.global.pause_state, true)
  T.eq(owner(), 'deadman')
  local d = ev('DEADMAN_PAUSE')
  T.eq(#d, 1)
  T.eq({d[1].cls, d[1].d.timeout, d[1].d.by, d[1].d.mode}, {'A', 600, 'wait', 'PEACE'})
  T.ok(d[1].d.age >= 1000 and d[1].d.age < 1010, tostring(d[1].d.age))
  T.ok(d[1].msg:find('dfllm cmd resume', 1, true), d[1].msg)
  H.run(W, 700, {paused = true})
  T.eq(#ev('DEADMAN_PAUSE'), 1, 'once per heartbeat')
  T.eq(#ev('DECISION_NEEDED'), 0, 'no 10-minute pause question for the kernel\'s own pause')
  T.eq(#ev('PAUSED_BY_DF'), 0)
  kern.stop()
end)

T.test('no session file at all: the pause comes after the boot grace (fail closed), age -1', function()
  world{session = false, reflex = {v = 2, deadman = {timeout_s = 600, check_s = 1, grace_s = 60}}}
  H.run(W, 50)
  T.eq(df.global.pause_state, false, 'inside the grace')
  H.run(W, 20)
  T.eq(owner(), 'deadman')
  local d = ev('DEADMAN_PAUSE')
  T.eq(#d, 1)
  T.eq(d[1].d.age, -1)
  kern.stop()
end)

T.test('deadman.on false: never pauses', function()
  world{session = 5000, reflex = {v = 2, deadman = {on = false}}}
  H.run(W, 100)
  T.eq(df.global.pause_state, false)
  T.eq(#ev('DEADMAN_PAUSE'), 0)
  kern.stop()
end)

T.test('resume releases pause:deadman (a live session wrote the heartbeat): the game runs and stays running', function()
  world{session = 1000}
  H.run(W, 5)
  T.eq(owner(), 'deadman')
  session(0)                                          -- the session's cmd writes its heartbeat first
  local r = verb('r1', 'resume')
  T.ok(r.ok, r.msg)
  T.eq(r.data.was, 'pause:deadman')
  T.eq(df.global.pause_state, false)
  H.run(W, 30)
  T.eq(df.global.pause_state, false)
  T.eq(owner(), nil)
  kern.stop()
end)

T.test('an inbox resume without a session (a supervisor) re-arms the dead-man: it pauses again', function()
  world{session = 1000}
  H.run(W, 5)
  T.eq(owner(), 'deadman')
  local r = verb('r1', 'resume')
  T.ok(r.ok, r.msg)
  H.run(W, 5)
  T.eq(owner(), 'deadman')
  T.eq(#ev('DEADMAN_PAUSE'), 2)
  kern.stop()
end)

T.test('a human who unpauses the dead-man pause in DF is not fought; a newer stale heartbeat fires again', function()
  world{session = 1000}
  H.run(W, 5)
  T.eq(owner(), 'deadman')
  df.global.pause_state = false                       -- Gordon presses space
  H.run(W, 60)
  T.eq(df.global.pause_state, false)
  T.eq(#ev('DEADMAN_PAUSE'), 1)
  session(0)                                          -- a session comes ...
  H.run(W, 5)
  session(900)                                        -- ... and dies again
  H.run(W, 5)
  T.eq(owner(), 'deadman')
  T.eq(#ev('DEADMAN_PAUSE'), 2)
  kern.stop()
end)

T.test('load pause (df) is left alone: no claim, no event; resume by a live session runs the game', function()
  world{session = 1000, paused = true}
  H.run(W, 30, {paused = true})
  T.eq(owner(), 'df')
  T.eq(#ev('DEADMAN_PAUSE'), 0)
  session(0)
  local r = verb('r1', 'resume')
  T.ok(r.ok and r.data.was == 'pause:df', r.msg)
  H.run(W, 30)
  T.eq(df.global.pause_state, false)
  T.eq(#ev('DEADMAN_PAUSE'), 0)
  kern.stop()
end)

T.test('Gordon\'s pause is left alone; when he unpauses with no session the dead-man pauses', function()
  world{session = 30}
  H.run(W, 3)
  df.global.pause_state = true
  H.run(W, 3, {paused = true})
  T.eq(owner(), 'gordon')
  session(1000)
  H.run(W, 10, {paused = true})
  T.eq(owner(), 'gordon')
  T.eq(#ev('DEADMAN_PAUSE'), 0)
  df.global.pause_state = false
  H.run(W, 5)
  T.eq(owner(), 'deadman')
  T.eq(#ev('DEADMAN_PAUSE'), 1)
  kern.stop()
end)

T.test('an inbox TTL pause is taken over (its expiry would unpause): the game stays paused after the TTL', function()
  world{session = 30}
  local r = verb('p1', 'pause', {ttl_s = 20})
  T.ok(r.ok, r.msg)
  T.eq(owner(), 'inbox')
  session(1000)
  H.run(W, 5, {paused = true})
  T.eq(owner(), 'deadman')
  T.eq(ev('DEADMAN_PAUSE')[1].d.took, 'inbox')
  H.run(W, 40, {paused = true})
  T.eq(df.global.pause_state, true)
  T.eq(owner(), 'deadman')
  r = verb('u1', 'unpause')
  T.ok(not r.ok and r.msg:find('paused by deadman', 1, true), r.msg)
  kern.stop()
end)

T.test('a whitelisted popup does not unpause the dead-man pause; a threat popup is still handed on', function()
  world{session = 1000}
  H.run(W, 5)
  T.eq(owner(), 'deadman')
  df.global.world.status.popups:insert('#', {text = 'Some migrants have arrived.'})
  H.run(W, 20, {paused = true})
  T.eq(df.global.pause_state, true)
  T.eq(owner(), 'deadman')
  T.eq(#ev('ARRIVAL'), 0, 'a migrant notice is no threat')
  T.eq(#df.global.world.status.popups, 0, 'BUG-794: acknowledged under the deadman pause, the game stays paused')
  local popups = df.global.world.status.popups
  popups:insert('#', {text = 'Some migrants have arrived.'})            -- a notice in front of a threat behind it
  popups:insert('#', {text = 'A vile force of darkness has arrived!'})
  H.run(W, 20, {paused = true})
  local a = ev('ARRIVAL')
  T.eq(#a, 1, 'the threat popup is handed on (no reflex module here: the arbiter fallback emits ARRIVAL)')
  T.eq(a[1].d.src, 'popup')
  T.eq(#popups, 0, 'handed on first, then acknowledged like under pause:popup (FR-36 order)')
  T.eq(df.global.pause_state, true, 'and the game stays paused')
  T.eq(owner(), 'deadman')
  kern.stop()
end)

T.test('the default switch: timeout_s 180 s, max_ticks 24000 (20 game days)', function()
  T.eq({arbiter.DEADMAN.timeout_s, arbiter.DEADMAN.max_ticks}, {180, 24000})
  world{session = 100, reflex = {v = 2, deadman = {check_s = 1, grace_s = 0}}}
  H.run(W, 5)
  T.eq(owner(), nil, '100 s < 180 s and few ticks')
  session(200)
  H.run(W, 5)
  T.eq(owner(), 'deadman')
  T.eq(ev('DEADMAN_PAUSE')[1].d.why, 'wall')
  kern.stop()
end)

T.test('game-time bound: a fast clock trips max_ticks long before timeout_s; a new heartbeat resets it', function()
  world{session = 0, reflex = {v = 2, deadman = {timeout_s = 600, max_ticks = 12000, check_s = 1, grace_s = 0}}}
  H.run(W, 10000, {skip = 500})                       -- 20 frames = 20 real s at 500 ticks/s
  T.eq(owner(), nil, '10000 ticks <= 12000')
  session(-1)                                         -- the live session refreshes (a new `wall`): the count starts again
  H.run(W, 10000, {skip = 500})
  T.eq(owner(), nil, 'a new wall resets the game-time bound')
  T.eq(#ev('DEADMAN_PAUSE'), 0)
  H.run(W, 3000, {skip = 500})                        -- 13000 ticks since the last heartbeat, < 30 real s
  T.eq(df.global.pause_state, true)
  T.eq(owner(), 'deadman')
  local d = ev('DEADMAN_PAUSE')
  T.eq(#d, 1)
  T.eq({d[1].d.why, d[1].d.max_ticks}, {'ticks', 12000})
  T.ok(d[1].d.ticks > 12000 and d[1].d.ticks <= 12500, tostring(d[1].d.ticks))
  T.ok(d[1].d.age < 600, 'the wall clock bound alone would not have fired')
  T.ok(d[1].msg:find('10 game days', 1, true), d[1].msg)
  kern.stop()
end)

T.test('max_ticks 0: no game-time bound (the wall bound alone)', function()
  world{session = 0, reflex = {v = 2, deadman = {timeout_s = 600, max_ticks = 0, check_s = 1, grace_s = 0}}}
  H.run(W, 50000, {skip = 500})
  T.eq(owner(), nil)
  kern.stop()
end)

T.test('a heartbeat dated in the future is no proof of life (fail closed); a small skew is tolerated', function()
  world{session = -30}                                -- 30 s ahead: tolerated
  H.run(W, 5)
  T.eq(owner(), nil)
  session(-3600)                                      -- an hour ahead: bad clock or writer
  H.run(W, 5)
  T.eq(df.global.pause_state, true)
  T.eq(owner(), 'deadman')
  local d = ev('DEADMAN_PAUSE')
  T.eq(#d, 1)
  T.eq(d[1].d.why, 'future')
  T.ok(d[1].d.age <= -3590, tostring(d[1].d.age))
  T.ok(d[1].msg:find('in the future', 1, true), d[1].msg)
  kern.stop()
end)

T.test('park: owner park from a running game or the dead-man; nothing wakes for hours; resume ends it and re-arms', function()
  world{session = 30}
  local r = verb('k1', 'park', {why = 'night'})
  T.ok(r.ok and r.msg:find('parked: was running', 1, true), r.msg)
  T.eq(owner(), 'park')
  session(5000)
  H.run(W, 900, {paused = true})                      -- 15 real minutes
  T.eq(owner(), 'park')
  T.eq(#ev('DEADMAN_PAUSE'), 0)
  T.eq(#ev('DECISION_NEEDED'), 0)
  T.eq(#ev('PAUSED_BY_DF'), 0)
  r = verb('k2', 'park')
  T.ok(r.ok and r.msg == 'already parked', r.msg)
  r = verb('r1', 'resume')
  T.ok(r.ok and r.data.was == 'pause:park', r.msg)
  H.run(W, 5)
  T.eq(owner(), 'deadman', 'the session is still dead: the dead-man takes it')
  r = verb('k3', 'park')
  T.ok(r.ok and r.msg:find('was deadman', 1, true), r.msg)
  T.eq(owner(), 'park')
  kern.stop()
end)

T.done()
