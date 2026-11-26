-- BUG-936 (Run 17 i3 14:16, i4 16:29): the kernel's resume retry waits until the frame gap is really over (no gap ended within
-- resume.retry_quiet_s real seconds), presses up to resume.retry_max times with the same guards as BUG-923 (a later park / pause,
-- a popup, a due dead-man pause win), and a resume refused only by the 60 s rate limit is honoured when the limit ends.
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

local function reply(id)
  local r
  for _ = 1, 6 do
    r = H.outbox(W, id)
    if r then return r end
    H.frame(W, 0)
  end
  return r
end

local function resume_in_gap(id)
  key_works = false
  H.inbox(W, id, 'resume', {}, 'cli')
  H.frame(W, 0, 25000)
  return reply(id)
end

local function logged(pat)
  K.flush()
  local n = 0
  for line in (H.read(W.sd .. '/kern.log') or ''):gmatch('[^\n]+') do if line:find(pat, 1, true) then n = n + 1 end end
  return n
end

T.test('BUG-936: a second gap right after the first one holds the retry back until the frames are regular', function()
  world('b936_second_gap')
  local r = resume_in_gap('r1')
  T.ok(not r.ok and r.data.retry == 1, r.msg)
  H.run(W, 3, {paused = true})
  T.eq(#keys, 1, 'the old rule pressed here (2 s after the gap)')
  H.frame(W, 0, 27578)                               -- DF freezes again (the live i3 case)
  key_works = true
  H.run(W, 7, {paused = true})
  T.eq(#keys, 1, 'still inside the quiet span of the second gap')
  H.run(W, 5, {paused = true})
  T.eq(#keys, 2)
  T.eq(df.global.pause_state, false)
  kern.stop()
end)

T.test('BUG-936: a key lost twice is pressed a third time; one that works stops the retries', function()
  world('b936_third')
  resume_in_gap('r1')
  for _ = 1, 80 do
    if #keys >= 3 then key_works = true end
    if df.global.pause_state ~= true then break end
    H.frame(W, 0)
  end
  T.eq(#keys, 4, 'initial + 3 attempts, the last one took')
  T.eq(df.global.pause_state, false)
  H.run(W, 30, {paused = true})
  T.eq(#keys, 4, 'nothing after the success')
  kern.stop()
end)

T.test('BUG-936: retry_max from config/reflex.json bounds the attempts (1 = one retry)', function()
  world('b936_max')
  K.cfg.reflex = {v = 2, resume = {retry_max = 1}}
  resume_in_gap('r1')
  H.run(W, 60, {paused = true})
  T.eq(#keys, 2)
  T.eq(df.global.pause_state, true)
  kern.stop()
end)

T.test('BUG-936: a later park / a popup still win over the retries', function()
  world('b936_guards')
  resume_in_gap('r1')
  H.inbox(W, 'pk2', 'park', {}, 'llm')
  key_works = true
  H.run(W, 40, {paused = true})
  T.eq(#keys, 1)
  T.eq(df.global.pause_state, true)
  kern.stop()
  world('b936_popup')
  resume_in_gap('r1')
  H.frame(W, 0, 27000)
  df.global.world.status.popups:insert('#', {text = 'A vile force of darkness has arrived! The siege has begun.'})
  key_works = true
  H.run(W, 40, {paused = true})
  T.eq(#keys, 1)
  T.eq(df.global.pause_state, true)
  while #df.global.world.status.popups > 0 do df.global.world.status.popups:erase(0) end
  kern.stop()
end)

T.test('BUG-936 (i4): a resume refused only by the rate limit says so and is honoured when the limit ends', function()
  world('b936_rate')
  H.inbox(W, 'a', 'resume', {}, 'cli')
  H.run(W, 3, {paused = true})
  T.ok(H.outbox(W, 'a').ok)
  H.inbox(W, 'pk2', 'park', {}, 'llm')               -- the test park of i4
  H.run(W, 3, {paused = true})
  T.eq(df.global.pause_state, true)
  H.inbox(W, 'b', 'resume', {}, 'cli')
  H.run(W, 3, {paused = true})
  local r = H.outbox(W, 'b')
  T.ok(not r.ok and r.msg:find('once per 60 s', 1, true) and r.msg:find('presses the key itself', 1, true), r.msg)
  T.eq({r.data.rate, r.data.retry}, {1, 1})
  T.ok(r.data.wait_s > 0 and r.data.wait_s <= 60, tostring(r.data.wait_s))
  H.run(W, 20, {paused = true})
  T.eq(df.global.pause_state, true, 'not before the limit ends')
  H.run(W, 45, {paused = true})
  T.eq(df.global.pause_state, false, 'honoured')
  T.ok(logged('after the rate limit') >= 1)
  kern.stop()
end)

T.test('BUG-936 (i4): the rate-limited resume is dropped when a later park came in meanwhile', function()
  world('b936_rate_park')
  H.inbox(W, 'a', 'resume', {}, 'cli')
  H.run(W, 3, {paused = true})
  H.inbox(W, 'pk2', 'park', {}, 'llm')
  H.run(W, 3, {paused = true})
  H.inbox(W, 'b', 'resume', {}, 'cli')
  H.run(W, 3, {paused = true})
  T.ok(not H.outbox(W, 'b').ok)
  H.run(W, 10, {paused = true})
  H.inbox(W, 'pk3', 'unpause', {}, 'llm')            -- released and parked again: a new pause
  H.run(W, 3, {paused = true})
  H.inbox(W, 'pk4', 'park', {}, 'llm')
  H.run(W, 3, {paused = true})
  T.eq(df.global.pause_state, true)
  H.run(W, 90, {paused = true})
  T.eq(df.global.pause_state, true, 'the newer park stays')
  kern.stop()
end)

T.done()
