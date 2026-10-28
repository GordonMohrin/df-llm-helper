-- BUG-115 on the real kernel: a report is routed by its text whatever its announcement type (the type name of
-- "has been cursed by" cannot be verified offline), and the arbiter leaves curse and transformation popups for the player.
-- Every test here fails on the commit before the package (32994bb).
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')
local arbiter = require('dfllm.arbiter')
arbiter.PROFILE.overlays = true

local function reports(W, id, tname, text)
  df.global.world.status.reports:insert('#', {id = id, type = df.announcement_type[tname], text = text, pos = {x = 1, y = 2, z = 3}})
  package.loaded['plugins.eventful'].onReport.dfllm(id)
end

T.test('BUG-115: kern routes a report to a module by M.report_text, whatever its announcement type; others stay filtered', function()
  local W = H.world{tag = 'curse_route'}
  local got = {}
  local plain = {}
  local m = {name = 'care', every = {ticks = 1000}, reports = {CARAVAN_ARRIVAL = true},
             report_text = {'has been cursed', 'transformed into'}, on = {
    REPORT = function(K, ev) got[#got + 1] = ev.type .. ':' .. ev.text end}}
  local other = {name = 'economy', every = {ticks = 1000}, reports = {CARAVAN_ARRIVAL = true}, on = {   -- no report_text: opt-in
    REPORT = function(K, ev) plain[#plain + 1] = ev.type end}}
  H.boot(W, {modules = {m, other}})
  reports(W, 1, 'CANCEL_JOB', 'Oddom Letmoscog, Miner has been cursed by Ok!')
  reports(W, 2, 'CANCEL_JOB', 'Something else entirely')
  reports(W, 3, 'FOOD_WARNING', 'Oddom Letmoscog has TRANSFORMED INTO a werecavy!')
  reports(W, 4, 'CARAVAN_ARRIVAL', 'A caravan has arrived')
  H.frame(W, 1)
  T.eq(got, {'CANCEL_JOB:Oddom Letmoscog, Miner has been cursed by Ok!',
             'FOOD_WARNING:Oddom Letmoscog has TRANSFORMED INTO a werecavy!', 'CARAVAN_ARRIVAL:A caravan has arrived'})
  T.eq(plain, {'CARAVAN_ARRIVAL'}, 'a module without report_text sees only the types it lists')
  kern.stop()
end)

T.test('BUG-115: a curse or transformation popup is not cleared, not even by popups.other; "were" needs a letter after it', function()
  local W = H.world{tag = 'curse_popup', ms_per_frame = 100}
  local seen = {}
  local care = {name = 'care', every = {ticks = 1000}, curse_text = function(K, text) seen[#seen + 1] = text; return true end}
  local ok, msg = H.boot(W, {modules = {arbiter, care}})
  assert(ok, msg)
  local K = kern.K()
  local popups = df.global.world.status.popups
  df.global.pause_state = false
  K.cfg.reflex = {v = 2, popups = {other = true, other_s = 20, log_s = 900}}
  for _, text in ipairs({'Oddom Letmoscog, Miner has been cursed by Ok!', 'Oddom Letmoscog has transformed into a werecavy!',
                         'A werewolf bit Urist.', 'Shem is a vampire.'}) do
    popups:insert('#', {text = text})
  end
  H.run(W, 400, {paused = false})
  T.eq(#popups, 4, 'none of them is cleared by the catch-all')
  T.eq(#seen, 1, 'care is told of the front popup once, not every step it stands')
  T.ok(seen[1]:find('cursed', 1, true))
  T.eq(arbiter.were('the dwarves were happy'), false)
  T.eq(arbiter.were("they weren't there"), false)
  T.eq(arbiter.were('a werecavy'), true)
  T.eq(arbiter.were('werewolves'), true)
  for _, w in ipairs({'cursed', 'transformed', 'vampire', 'werebeast'}) do
    local found = false
    for _, d in ipairs(arbiter.DENY) do if d == w then found = true end end
    T.ok(found, w .. ' is on the DENY list')
  end
  while #popups > 0 do popups:erase(0) end
  popups:insert('#', {text = 'Some migrants have arrived.'})            -- the known kinds are still cleared
  df.global.pause_state = false
  H.run(W, 40, {paused = false})
  T.eq(#popups, 0)
  popups:insert('#', {text = 'Urist, Mason have arrived and were welcomed.'})   -- "were " is no were-word
  df.global.pause_state = false
  H.run(W, 40, {paused = false})
  T.eq(#popups, 0, 'an arrival popup with the plain word were is cleared')
  kern.stop()
end)

T.done()
