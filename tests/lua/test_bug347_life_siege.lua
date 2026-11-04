-- BUG-347 (Run 15 Guildcleans y386-387, i2): the hospital, the stockroom and gallery_o1 stood 'dig 0% BLOCKED:frozen'
-- through a siege of 150+ days (runner.lua allowed: SIEGE ran only defense projects inside Z3/Z4); patient 26739 died of
-- thirst before the hospital was dug. Life support (hospital, cistern, refuge drink; farms / stockroom in a food or drink
-- emergency) now runs in a SIEGE while every tile of its stage lies inside the burrow the sounding civ alert holds the
-- citizens in (Kern+ without one); a stage with a tile outside stays frozen and says how many. Fail on 14ff5a3.
local T = require('testlib')
local H = require('runner_world')
local kmock = require('dfllm.util.k_mock')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function dug(W)
  local xs = {}
  for _, c in ipairs(H.qf_calls(W, 'dig')) do xs[c.pos[1] .. ',' .. c.pos[2]] = true end
  return xs
end

-- o: tag, mode, alert (true: the civ alert sounds on Kern+), stock, manifest
local function world(o)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = o.tag, mode = o.mode or 'SIEGE',
                    persist = {manifest = o.manifest or {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  local kern = W.burrow('Kern+', {0, 0, 90, 40, 40, 110})
  W.burrow('Pflege+', {0, 0, 90, 200, 200, 110})          -- the care burrow reaches everywhere: it never counts
  if o.alert then
    local care = dfhack.burrows.findByName('Pflege+')
    df.global.plotinfo.alerts.list = kmock.vec{{burrows = kmock.vec{}}, {burrows = kmock.vec{care.id, kern.id}}}
    df.global.plotinfo.alerts.civ_alert_idx = 1
  end
  W.ctl = {stock = o.stock or {food_d = 200, drink_d = 300}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = W.ctl.stock} end})
  W.load(runner)
  return W
end

T.test('BUG-347: in a SIEGE the hospital inside the alert burrow digs; outside it, and a bedroom inside, stay frozen ' ..
       '(the row names the tiles off the burrow)', function()
  local W = world{tag = 'b347a', alert = true}
  H.place(W, 'hosp', H.doc{x = 10, y = 10, tpl = 'hospital', class = 'living'})
  H.place(W, 'bed', H.doc{x = 10, y = 20, tpl = 'bedrooms', class = 'living'})
  H.place(W, 'far', H.doc{x = 60, y = 10, tpl = 'hospital', class = 'living'})
  H.settle(W); W.frame(1); H.settle(W)
  local xs = dug(W)
  T.ok(xs['10,10'], 'old code: the hospital inside Kern+ was frozen in the SIEGE')
  T.ok(not xs['10,20'] and not xs['60,10'], 'a bedroom and a hospital off the burrow stay frozen')
  T.eq(row(W, 'bed')[4], 'frozen')
  T.eq(row(W, 'far')[4], 'frozen: 10/10 tiles off Kern+')
  T.eq(W.K.mode(), 'SIEGE')
end)

T.test('BUG-347: farms run in a SIEGE only in a food or drink emergency; the cistern always; BREACH freezes them all',
       function()
  local W = world{tag = 'b347b', alert = true}
  H.place(W, 'farm', H.dig_doc(1, {x = 10, y = 10, tpl = 'farms', class = 'infra'}))
  H.place(W, 'cis', H.dig_doc(1, {x = 10, y = 20, tpl = 'cistern', class = 'infra'}))
  H.settle(W); W.frame(1); H.settle(W)
  local xs = dug(W)
  T.ok(xs['10,20'] and not xs['10,10'], 'the cistern digs, the farms wait while food holds')
  W.ctl.stock = {food_d = 12, drink_d = 300}                 -- a famine
  H.runs(W, 2)
  T.ok(dug(W)['10,10'], 'old code: farms frozen in the SIEGE during a famine')
  local W2 = world{tag = 'b347c', alert = true, mode = 'BREACH'}
  H.place(W2, 'cis', H.dig_doc(1, {x = 10, y = 20, tpl = 'cistern', class = 'infra'}))
  H.settle(W2); W2.frame(1); H.settle(W2)
  T.eq(#H.qf_calls(W2, 'dig'), 0, 'a BREACH freezes life support too')
end)

T.test('BUG-347: no civ alert sounding: Kern+ (manifest role kern) is the burrow in ALERT; ALERT runs the hospital inside it',
       function()
  local W = world{tag = 'b347d', mode = 'ALERT'}
  H.place(W, 'hosp', H.doc{x = 10, y = 10, tpl = 'hospital', class = 'living'})
  H.settle(W); W.frame(1); H.settle(W)
  T.ok(dug(W)['10,10'], 'the hospital inside Kern+ digs in ALERT without a sounding alert')
  local W2 = world{tag = 'b347e', mode = 'ALERT', manifest = {v = 2}}
  H.place(W2, 'hosp', H.doc{x = 10, y = 10, tpl = 'hospital', class = 'living'})
  H.settle(W2); W2.frame(1); H.settle(W2)
  T.eq(#H.qf_calls(W2, 'dig'), 0, 'no alert and no Kern+ in the manifest: nothing to measure, frozen')
  T.eq(row(W2, 'hosp')[4], 'frozen: no alert burrow')
  local W3 = world{tag = 'b347f', mode = 'ALERT', alert = true}
  H.place(W3, 'hosp', H.doc{x = 10, y = 10, tpl = 'hospital', class = 'living'})
  H.settle(W3); W3.frame(1); H.settle(W3)
  T.ok(dug(W3)['10,10'], 'old code: a living project, frozen in ALERT')
end)

-- review fix (merge16): a SIEGE with a silent civ alert (seal 'flee' / BUG-031 relax: civ_alert_idx 0) holds the
-- citizens nowhere; the Kern+ fallback let the hospital run with free citizens hauling from the surface. No fallback in
-- a SIEGE: frozen. Fail on cc65ee4 (the hospital dug).
T.test('review fix merge16: a SIEGE with civ_alert_idx 0 keeps the hospital inside Kern+ frozen', function()
  local W = world{tag = 'b347r'}
  T.eq(df.global.plotinfo.alerts.civ_alert_idx or 0, 0)
  H.place(W, 'hosp', H.doc{x = 10, y = 10, tpl = 'hospital', class = 'living'})
  H.settle(W); W.frame(1); H.settle(W)
  T.eq(#H.qf_calls(W, 'dig'), 0, 'old code: Kern+ fallback in a SIEGE, the hospital dug with unheld citizens')
  T.eq(row(W, 'hosp')[4], 'frozen: no civ alert sounding')
  T.eq(W.K.mode(), 'SIEGE')
end)

-- verifier pass 2: the S.life measure (LIFE_TTL 1200) is taken again when the alert burrow switches (Kern+ <-> Tiefe+),
-- and a BREACH row does not show the tile count measured in the SIEGE before it
T.test('BUG-347: an alert burrow switch measures again at once; a BREACH row says plain frozen, not an old tile count',
       function()
  local W = world{tag = 'b347g', alert = true}
  H.place(W, 'far', H.doc{x = 60, y = 10, tpl = 'hospital', class = 'living'})
  H.settle(W); W.frame(1); H.settle(W)
  T.eq(row(W, 'far')[4], 'frozen: 10/10 tiles off Kern+')
  local tiefe = W.burrow('Tiefe+', {50, 0, 90, 80, 40, 110})
  df.global.plotinfo.alerts.list = kmock.vec{{burrows = kmock.vec{}}, {burrows = kmock.vec{}}, {burrows = kmock.vec{tiefe.id}}}
  df.global.plotinfo.alerts.civ_alert_idx = 2            -- the alert now sounds on Tiefe+
  H.runs(W, 1)                                           -- 600 ticks: inside LIFE_TTL
  T.ok(dug(W)['60,10'], 'old code: the Kern+ measure held for LIFE_TTL ticks')
  local W2 = world{tag = 'b347h', alert = true}
  H.place(W2, 'far', H.doc{x = 60, y = 10, tpl = 'hospital', class = 'living'})
  H.settle(W2); W2.frame(1); H.settle(W2)
  T.eq(row(W2, 'far')[4], 'frozen: 10/10 tiles off Kern+')
  W2.mode = 'BREACH'
  H.runs(W2, 1)
  T.eq(row(W2, 'far')[4], 'frozen', 'old code: the SIEGE tile count in a BREACH row')
end)

T.done()
