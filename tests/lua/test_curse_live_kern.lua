-- The live test i2 of the curse package on the real kernel: BUG-139 (two LOCKDOWNs 1-9 ticks apart for every unacked
-- TRANSFORM: the event care emitted from a REPORT was delivered twice) and BUG-136 (the watch pass: its own tick clock,
-- outside the module's cadence). Every test here fails on the commit before the package (dec5132).
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')

local function report(id, tname, text)
  df.global.world.status.reports:insert('#', {id = id, type = df.announcement_type[tname], text = text, pos = {x = 1, y = 2, z = 3}})
  package.loaded['plugins.eventful'].onReport.dfllm(id)
end

T.test('BUG-139: an event a REPORT handler emits arrives once at its listeners, in the next frame', function()
  local W = H.world{tag = 'dup'}
  local got = {}
  local care = {name = 'care', every = {ticks = 100000}, reports = {CARAVAN_ARRIVAL = true}, report_text = {'has transformed'},
                on = {REPORT = function(K, ev) K.emit('TRANSFORM', 'A', 'Olon turned into a werecavy', {n = 1, dir = 'beast'}) end}}
  local listen = {name = 'test_listen', every = {ticks = 100000},
                  on = {['EV:TRANSFORM'] = function(K, ev) got[#got + 1] = ev.n end}}
  local ok, msg = H.boot(W, {modules = {care, listen}})
  assert(ok, msg)
  report(1, 'CANCEL_JOB', 'Olon Gatizbomrek, Axe Lord has transformed into a werecavy!')
  for _ = 1, 4 do H.frame(W, 1) end
  T.eq(#got, 1, 'live: reflex recorded every TRANSFORM twice and applied its default twice')
  report(2, 'CANCEL_JOB', 'Urvad Kubukarban, Planter has transformed into a werecavy!')
  for _ = 1, 4 do H.frame(W, 1) end
  T.eq(#got, 2)
  T.ok(got[1] ~= got[2])
  kern.stop()
end)

T.test('BUG-136: kern runs a module\'s M.watch every watch_every ticks, whatever the cadence of its step', function()
  local W = H.world{tag = 'watch'}
  local m = H.counter('care', {ticks = 1000000}, {watch_every = {ticks = 100}})
  local n = 0
  m.watch = function(K) n = n + 1 end
  local ok, msg = H.boot(W, {modules = {m}})
  assert(ok, msg)
  H.run(W, 1000, {skip = 10})
  T.ok(n >= 9 and n <= 11, 'watch calls: ' .. n)
  T.eq(#m.runs, 1, 'the step keeps its own cadence')
  H.run(W, 50, {paused = true})
  local before = n
  H.run(W, 50, {paused = true})
  T.eq(n, before, 'a tick clock: no watch while paused')
  kern.stop()
end)

T.done()
