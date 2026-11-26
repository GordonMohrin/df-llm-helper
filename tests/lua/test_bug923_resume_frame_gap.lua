-- BUG-923 (Run 17 i3: a `resume` sent in the yearly autosave frame gap was handled when the gap ended, refused with "still paused
-- after the pause key", the game stayed pause:park and the CLI only said "no reply yet"): a key that did not take right after a frame
-- gap is pressed ONCE more a moment later; a park / pause / unpause that came in between wins; no gap, no retry.
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')
local arbiter = require('dfllm.arbiter')
arbiter.PROFILE.overlays = true

local W, K, keys, key_works

local function world(tag)
  keys, key_works = {}, true
  W = H.world{tag = tag, ms_per_frame = 1000}
  dfhack.gui = dfhack.gui or {}
  dfhack.gui.getDFViewscreen = function() return 'df_main' end
  package.loaded.gui = {simulateInput = function(scr, key)
    keys[#keys + 1] = {scr, key}
    if key == 'D_PAUSE' and key_works then df.global.pause_state = not df.global.pause_state end
  end}
  df.global.pause_state = false
  local ok, msg = H.boot(W, {modules = {arbiter}})
  assert(ok, msg)
  K = kern.K()
  H.run(W, 3)
  H.inbox(W, 'pk', 'park', {}, 'llm')
  H.run(W, 3, {paused = true})
  assert(df.global.pause_state == true, 'parked')
end

-- the resume is sent inside the freeze: DF is stuck, the key does not take; the gap ends and the command is handled
local function resume_in_gap(id)
  key_works = false
  H.inbox(W, id, 'resume', {}, 'cli')
  H.frame(W, 0, 25000)
  local r = H.outbox(W, id)
  for _ = 1, 3 do                                    -- one frame at a time: the reply is read the moment it exists
    if r then break end
    H.frame(W, 0)
    r = H.outbox(W, id)
  end
  assert(r, 'no reply')
  return r
end

T.test('BUG-923: a resume refused right after a frame gap is retried once; the game runs again', function()
  world('b923_retry')
  local r = resume_in_gap('r1')
  T.ok(not r.ok and r.msg:find('still paused', 1, true), r.msg)
  T.ok(r.msg:find('presses the key once more', 1, true), r.msg)
  T.eq(r.data.retry, 1)
  T.eq(#keys, 1)
  key_works = true                                   -- DF's frame is alive again
  H.run(W, 4, {paused = true})
  T.eq(#keys, 1, 'BUG-936: not before the frames have been regular for retry_quiet_s (8 s)')
  H.run(W, 8, {paused = true})
  T.eq(#keys, 2, 'one press now')
  T.eq(df.global.pause_state, false)
  K.flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, nil)
  kern.stop()
end)

T.test('BUG-923 / BUG-936: the retries are bounded (retry_max 3): a key that keeps failing is not pressed a fifth time', function()
  world('b923_once')
  resume_in_gap('r1')
  H.run(W, 60, {paused = true})
  T.eq(#keys, 4, '1 + 3 retries')
  T.eq(df.global.pause_state, true)
  kern.stop()
end)

T.test('BUG-923: a later park wins over the pending retry', function()
  world('b923_park')
  resume_in_gap('r1')
  H.inbox(W, 'pk2', 'park', {}, 'llm')
  key_works = true
  H.run(W, 6, {paused = true})
  T.eq(#keys, 1, 'no retry after a park')
  T.eq(df.global.pause_state, true)
  K.flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, 'park')
  kern.stop()
end)

T.test('BUG-923: no frame gap, no retry (the refusal stays as it was)', function()
  world('b923_nogap')
  key_works = false
  H.inbox(W, 'r1', 'resume', {}, 'cli')
  H.run(W, 3, {paused = true})
  local r = H.outbox(W, 'r1')
  T.ok(not r.ok and r.msg:find('still paused', 1, true), r.msg)
  T.ok(not r.msg:find('once more', 1, true), r.msg)
  key_works = true
  H.run(W, 10, {paused = true})
  T.eq(#keys, 1)
  T.eq(df.global.pause_state, true)
  kern.stop()
end)

T.test('BUG-923: a SIEGE popup (safety pause) arriving before the retry wins: no key, the game stays paused', function()
  world('b923_siege')
  resume_in_gap('r1')
  T.eq(#keys, 1)
  df.global.world.status.popups:insert('#', {text = 'A vile force of darkness has arrived! The siege has begun.'})
  key_works = true
  H.run(W, 8, {paused = true})
  T.eq(#keys, 1, 'no retry key while a siege popup stands')
  T.eq(df.global.pause_state, true)
  while #df.global.world.status.popups > 0 do df.global.world.status.popups:erase(0) end   -- whatever the arbiter left of it
  H.run(W, 40, {paused = true})
  T.eq(#keys, 1, 'the retry is gone for good, it does not come back once the popup is closed')
  T.eq(df.global.pause_state, true)
  kern.stop()
end)

T.test('BUG-923: a dead-man pause due before the retry wins: no key, the game stays paused', function()
  world('b923_deadman')
  K.cfg.reflex = {v = 2, deadman = {on = true, timeout_s = 600, max_ticks = 0, check_s = 1, grace_s = 0}}
  W.hb_auto = false
  local json = require('dfllm.util.json')
  H.write(W.sd .. '/session.json', json.encode({v = 2, wall = os.time(), by = 'wait'}))
  resume_in_gap('r1')
  T.eq(#keys, 1)
  H.write(W.sd .. '/session.json', json.encode({v = 2, wall = os.time() - 1000, by = 'wait'}))   -- the session died meanwhile
  key_works = true
  H.run(W, 40, {paused = true})
  T.eq(#keys, 1, 'no retry key against a dead-man pause')
  T.eq(df.global.pause_state, true, 'paused at the end')
  K.flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, 'park', "the dead-man leaves a standing pause's owner alone")
  kern.stop()
end)

T.done()
