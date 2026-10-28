-- FR-94 (Run 14 note 100): the verb `resume` releases a pause that DF set (a save loaded paused, a restart, a popup) with the
-- player's own key: act.press_pause = gui.simulateInput(main DF viewscreen, 'D_PAUSE'). Only in pause:df / pause:popup, never
-- with a DENY word (curse, transform, were, vampire, ambush, siege ...) in an open popup, at most once per 60 real seconds.
-- The wake PAUSED_BY_DF (class A) comes after reflex.json resume.wake_min minutes.
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')
local arbiter = require('dfllm.arbiter')
arbiter.PROFILE.overlays = true

local W, K, keys, key_works

-- DF's pause key toggles; the stand-in does the same (or nothing, when a test says the key did not take)
local function world(opts)
  opts = opts or {}
  keys, key_works = {}, true
  W = H.world{tag = opts.tag or 'resume', ms_per_frame = 1000}
  dfhack.gui = dfhack.gui or {}
  dfhack.gui.getDFViewscreen = function() return 'df_main' end
  package.loaded.gui = {simulateInput = function(scr, key)
    keys[#keys + 1] = {scr, key}
    if key == 'D_PAUSE' and key_works then df.global.pause_state = not df.global.pause_state end
  end}
  df.global.pause_state = opts.paused == true
  local ok, msg = H.boot(W, {modules = {arbiter}})
  assert(ok, msg)
  K = kern.K()
  if opts.reflex then K.cfg.reflex = opts.reflex end
  return W
end

local function resume(id, args)
  H.inbox(W, id, 'resume', args or {}, 'llm')
  H.run(W, 3, {paused = true})
  return H.outbox(W, id)
end

local function owner() K.flush(); H.frame(W, 0); return H.state(W).owners.pause end
local function settle() H.run(W, 60, {paused = true}); K.flush(); H.frame(W, 0) end
local function ev(etype)
  local n = {}
  for _, e in ipairs(H.events(W)) do if e.type == etype then n[#n + 1] = e end end
  return n
end

T.test('FR-94: a save loaded paused (pause:df) is released with the pause key; the reply names the old reason and the new state', function()
  world{paused = true}
  H.run(W, 3, {paused = true})
  T.eq(owner(), 'df')
  local r = resume('r1')
  T.ok(r.ok, r.msg)
  T.eq(r.msg, 'resumed: was pause:df, now running')
  T.eq(r.data.was, 'pause:df')
  T.eq(r.data.now, 'running')
  T.eq(keys, {{'df_main', 'D_PAUSE'}}, 'one pause key to the main DF viewscreen, no pause_state write')
  T.eq(df.global.pause_state, false)
  T.eq(owner(), nil)
  settle()
  local p = ev('PAUSE')
  T.eq({p[#p].d.on, p[#p].d.by}, {0, 'df'})
  kern.stop()
end)

T.test('FR-94 refusal: not paused, an inbox pause, the player\'s own pause (nothing is pressed)', function()
  world()
  H.run(W, 3)
  local r = resume('n1')
  T.ok(not r.ok and r.msg:find('not paused', 1, true), r.msg)
  H.inbox(W, 'p1', 'pause', {ttl_s = 300}, 'llm')
  H.run(W, 3, {paused = true})
  r = resume('n2')
  T.ok(not r.ok and r.msg:find('paused by inbox', 1, true) and r.msg:find('unpause', 1, true), r.msg)
  H.inbox(W, 'u1', 'unpause', {}, 'llm')
  H.run(W, 3, {paused = true})
  df.global.pause_state = true                       -- the player pauses
  H.run(W, 3, {paused = true})
  T.eq(owner(), 'gordon')
  r = resume('n3')
  T.ok(not r.ok and r.msg:find('paused by gordon', 1, true) and r.msg:find('releases only pause:df and pause:popup', 1, true), r.msg)
  T.eq(keys, {}, 'no key for any refusal')
  T.eq(df.global.pause_state, true)
  df.global.pause_state = false
  kern.stop()
end)

T.test('FR-94 refusal: a popup with a DENY word stays (curse, transformation, were-beast, vampire, ambush, siege, embark intro)', function()
  world{paused = true}
  local popups = df.global.world.status.popups
  local texts = {'Oddom Letmoscog has been cursed by Ok! He transforms.', 'Urist is a werecavy now!', 'A vampire walks among us.',
                 'An ambush!  Drive them out!', 'The siege has begun.', 'Strike the earth!'}
  for i, text in ipairs(texts) do
    popups:insert('#', {text = text})
    H.run(W, 3, {paused = true})
    local r = resume('d' .. i)
    T.ok(not r.ok, text)
    T.ok(r.msg:find('DENY', 1, true) and r.msg:find(text:sub(1, 30), 1, true), r.msg)
    T.eq(#popups, 1, 'the popup is left for the player')
    popups:erase(0)
    H.run(W, 3, {paused = true})
  end
  T.eq(keys, {})
  T.eq(df.global.pause_state, true)
  kern.stop()
end)

T.test('FR-94 refusal: a DENY popup behind an unknown one: the first is read, the DENY stops the dismissals', function()
  world{paused = true}
  local popups = df.global.world.status.popups
  popups:insert('#', {text = 'The dwarves have found something unusual.'})
  popups:insert('#', {text = 'Someone has been cursed by Ok!'})
  H.run(W, 3, {paused = true})
  local r = resume('q1')
  T.ok(not r.ok and r.msg:find('cursed', 1, true), r.msg)
  T.eq(#popups, 2, 'nothing is dismissed while a DENY popup is open')
  T.eq(keys, {})
  popups:erase(0); popups:erase(0)
  kern.stop()
end)

T.test('FR-94 rate limit: once per 60 real seconds, a key that did not take counts too', function()
  world{paused = true}
  H.run(W, 3, {paused = true})
  key_works = false
  local r = resume('t1')
  T.ok(not r.ok and r.msg:find('still paused', 1, true) and r.msg:find('pause:df', 1, true), r.msg)
  T.eq(#keys, 1)
  r = resume('t2')
  T.ok(not r.ok and r.msg:find('once per 60 s', 1, true), r.msg)
  T.eq(#keys, 1, 'the second call pressed nothing')
  H.run(W, 61, {paused = true})
  key_works = true
  r = resume('t3')
  T.ok(r.ok, r.msg)
  T.eq({#keys, df.global.pause_state}, {2, false})
  kern.stop()
end)

T.test('FR-94: an unknown popup is read, named in the reply and dismissed; the next one waits for the rate limit', function()
  world()
  local popups = df.global.world.status.popups
  popups:insert('#', {text = 'The dwarves have found something unusual.'})
  df.global.pause_state = false
  H.run(W, 6, {paused = true})
  T.eq(owner(), 'popup')
  local r = resume('u1')
  T.ok(r.ok, r.msg)
  T.eq(r.msg, 'resumed: was pause:popup, now running; dismissed popup "The dwarves have found something unusual."')
  T.eq(r.data.popups, {'The dwarves have found something unusual.'})
  T.eq({#popups, #keys}, {0, 0}, 'no pause was set, so no key')
  popups:insert('#', {text = 'Another strange notice.'})
  H.run(W, 6, {paused = true})
  r = resume('u2')
  T.ok(not r.ok and r.msg:find('once per 60 s', 1, true), r.msg)
  T.eq(#popups, 1)
  H.run(W, 60, {paused = true})
  r = resume('u3')
  T.ok(r.ok and r.msg:find('Another strange notice.', 1, true), r.msg)
  T.eq(#popups, 0)
  kern.stop()
end)

T.test('FR-94: an unknown popup on top of a pause:df: the popup goes first, then the key; several popups all named', function()
  world{paused = true}
  local popups = df.global.world.status.popups
  popups:insert('#', {text = 'brawling under the influence'})
  popups:insert('#', {text = 'Second notice'})
  H.run(W, 3, {paused = true})
  local r = resume('s1')
  T.ok(r.ok, r.msg)
  T.eq(r.data.popups, {'brawling under the influence', 'Second notice'})
  T.eq(r.data.was, 'pause:df')
  T.eq({#popups, #keys, df.global.pause_state}, {0, 1, false})
  kern.stop()
end)

T.test('FR-94 wake: PAUSED_BY_DF (class A) after resume.wake_min minutes, once per pause, with the popup text; 0 = off', function()
  world{paused = true, tag = 'resumewake'}
  H.run(W, 230, {paused = true})
  settle()                                            -- 290 s of 300
  T.eq(#ev('PAUSED_BY_DF'), 0, 'not yet at 5 min')
  H.run(W, 30, {paused = true})
  settle()
  local w = ev('PAUSED_BY_DF')
  T.eq(#w, 1)
  T.eq({w[1].cls, w[1].d.by, w[1].d.min}, {'A', 'df', 5})
  T.ok(w[1].msg:find('PAUSED_BY_DF for 5 min: dfllm cmd resume', 1, true), w[1].msg)
  H.run(W, 700, {paused = true})
  T.eq(#ev('PAUSED_BY_DF'), 1, 'once per pause')
  kern.stop()
  -- the popup text is in the wake; the key moves the time
  world{paused = true, tag = 'resumewake2', reflex = {v = 2, resume = {wake_min = 2}}}
  df.global.world.status.popups:insert('#', {text = 'The dwarves have found something unusual.'})
  H.run(W, 130, {paused = true})
  settle()
  w = ev('PAUSED_BY_DF')
  T.eq(#w, 1)
  T.eq({w[1].d.by, w[1].d.min, w[1].d.popup}, {'df', 2, 'The dwarves have found something unusual.'})
  T.ok(w[1].msg:find('dfllm cmd resume', 1, true) and w[1].msg:find('The dwarves have found something unusual.', 1, true), w[1].msg)
  T.ok(#w[1].msg < 200, 'a wake line stays short')
  kern.stop()
  world{paused = true, tag = 'resumewake3', reflex = {v = 2, resume = {wake_min = 0}}}
  H.run(W, 2000, {paused = true})
  settle()
  T.eq(#ev('PAUSED_BY_DF'), 0, 'wake_min 0 switches the wake off')
  kern.stop()
end)

T.test('FR-94 wake: a pause by the player never wakes PAUSED_BY_DF (only the old DECISION_NEEDED after 10 min)', function()
  world{tag = 'resumewake4'}
  H.run(W, 3)
  df.global.pause_state = true
  H.run(W, 700, {paused = true})
  settle()
  T.eq(#ev('PAUSED_BY_DF'), 0)
  df.global.pause_state = false
  kern.stop()
end)

T.test('FR-94 wake: a DENY popup is named in the wake and flagged (resume would refuse it)', function()
  world{paused = true, tag = 'resumewake5'}
  df.global.world.status.popups:insert('#', {text = 'Oddom Letmoscog has been cursed by Ok!'})
  H.run(W, 320, {paused = true})
  settle()
  local w = ev('PAUSED_BY_DF')
  T.eq(#w, 1)
  T.eq(w[1].d.deny, 1)
  T.ok(w[1].msg:find('cursed', 1, true), w[1].msg)
  df.global.world.status.popups:erase(0)
  kern.stop()
end)

T.test('FR-94: config/reflex.json carries resume.wake_min next to the other knobs (the kernel default is 5)', function()
  local F = require('wp8_world')
  T.eq(F.read_json('config/reflex.json').resume, {wake_min = arbiter.RESUME.wake_min})
  T.eq(arbiter.RESUME.wake_min, 5)
end)

T.done()
