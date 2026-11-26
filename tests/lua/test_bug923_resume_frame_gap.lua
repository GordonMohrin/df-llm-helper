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
  T.eq(#keys, 2, 'one retry')
  T.eq(df.global.pause_state, false)
  K.flush(); H.frame(W, 0)
  T.eq(H.state(W).owners.pause, nil)
  kern.stop()
end)

T.test('BUG-923: the retry is one only: a key that fails again is not pressed a third time', function()
  world('b923_once')
  resume_in_gap('r1')
  H.run(W, 40, {paused = true})
  T.eq(#keys, 2)
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

T.done()
