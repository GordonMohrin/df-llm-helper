-- BUG-066 (Run 14 y560: a toppled MetalsmithsForge at 73,62,129 stayed `built` in manifest.json, "bp sites workshops" said
-- "nothing left to build" while a mood dwarf had no workshop) and FR-76 (Run 12 Trussroads, a reclaimed fort: workshops no
-- project of ours built, no carpenter, no craftsdwarf, no kitchen; the kernel only said "short coffins"): once a game day
-- the runner compares the manifest's workshops with the workshops that stand. A missing one leaves the manifest after
-- `gone_scans` scans (and is listed in manifest.gone), a standing built one the manifest lacks is adopted, the mandatory
-- workshops a reclaimed fort lacks are asked for (PROJECT_REQUEST workshops why=mandatory).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(opts)
  df.workshop_type = {Carpenters = 1, Masons = 2, Craftsdwarfs = 3, MetalsmithsForge = 5, Still = 6, Kitchen = 7, Custom = 9,
                      [1] = 'Carpenters', [2] = 'Masons', [3] = 'Craftsdwarfs', [5] = 'MetalsmithsForge', [6] = 'Still',
                      [7] = 'Kitchen', [9] = 'Custom'}
  df.furnace_type = {Smelter = 1, [1] = 'Smelter'}
  W.load(runner)
  return W
end

-- a standing 3x3 workshop centred on x,y
local function shop(name, x, y, z, unbuilt, furnace)
  local b = {type = (furnace and df.furnace_type or df.workshop_type)[name], x1 = x - 1, y1 = y - 1, x2 = x + 1, y2 = y + 1,
             z = z, getBuildStage = function() return unbuilt and 0 or 1 end, getMaxBuildStage = function() return 1 end}
  df.global.world.buildings.other[furnace and 'FURNACE_ANY' or 'WORKSHOP_ANY']:insert('#', b)
  return b
end

local function remove(vec, b)
  for i = 0, #vec - 1 do if vec[i] == b then vec:erase(i); return end end
end

local function man(W) return W.K.manifest() end
local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function types(list)
  local r = {}
  for _, w in ipairs(list or {}) do r[#r + 1] = w.type end
  table.sort(r)
  return r
end

T.test('BUG-066: a manifest workshop that no longer stands leaves the manifest after two daily scans and is listed ' ..
       'in manifest.gone; one that stands stays; old code: it stayed `built` for ever', function()
  local W = fresh{tag = 'gone', persist = {manifest = {v = 2, workshops = {{type = 'Carpenters', pos = {5, 5, 10}},
                                                                            {type = 'MetalsmithsForge', pos = {20, 20, 10}}}}}}
  shop('Carpenters', 5, 5, 10)
  local forge = shop('MetalsmithsForge', 20, 20, 10)
  H.runs(W, 2)
  T.eq(types(man(W).workshops), {'Carpenters', 'MetalsmithsForge'}, 'both stand')
  remove(df.global.world.buildings.other.WORKSHOP_ANY, forge)                 -- toppled by a tantrum
  H.runs(W, 2)
  T.eq(types(man(W).workshops), {'Carpenters', 'MetalsmithsForge'}, 'one scan is no proof (a rebuild may be under way)')
  H.runs(W, 2)
  local m = man(W)
  T.eq(types(m.workshops), {'Carpenters'}, 'the second scan: out of the manifest')
  T.eq({#m.gone, m.gone[1].type, m.gone[1].pos}, {1, 'MetalsmithsForge', {20, 20, 10}})
  T.ok(m.gone[1].w > 0, 'the wall clock of the loss')
  T.ok(logged(W, 'warn', 'workshop MetalsmithsForge at 20,20,10 no longer stands'), 'kern.log names it')
  T.eq(W.state().adopt.gone, 1)
  H.runs(W, 4)
  T.eq(#man(W).gone, 1, 'listed once')
end)

T.test('BUG-066: a workshop seen again before the second scan keeps its place; a rebuilt one leaves manifest.gone', function()
  local W = fresh{tag = 'back', persist = {manifest = {v = 2, workshops = {{type = 'Masons', pos = {8, 8, 10}}}}}}
  local m1 = shop('Masons', 8, 8, 10)
  H.runs(W, 2)
  remove(df.global.world.buildings.other.WORKSHOP_ANY, m1)
  H.runs(W, 2)                                                    -- scan 1 without it
  shop('Masons', 8, 8, 10)
  H.runs(W, 4)
  T.eq(types(man(W).workshops), {'Masons'})
  T.eq(man(W).gone, nil, 'never gone')
  -- gone once, then a project finishes with a fragment at the same place: merge_manifest cancels the record
  local dst = {v = 2, workshops = {}, gone = {{type = 'Masons', pos = {8, 8, 10}, w = 5}, {type = 'Still', pos = {1, 1, 1}}}}
  runner.merge_manifest(dst, {v = 2, workshops = {{type = 'Masons', pos = {8, 8, 10}}}})
  T.eq(dst.gone, {{type = 'Still', pos = {1, 1, 1}}})
  T.eq(types(dst.workshops), {'Masons'})
end)

T.test('BUG-066: a failed read of the building vectors prunes nothing; the next readable scan decides', function()
  local W = fresh{tag = 'noread', persist = {manifest = {v = 2, workshops = {{type = 'Masons', pos = {8, 8, 10}}}}}}
  local names = df.workshop_type
  df.workshop_type = nil                                         -- the scan cannot read the type names
  H.runs(W, 8)
  T.eq(types(man(W).workshops), {'Masons'})
  T.eq(man(W).gone, nil)
  T.eq(W.state().adopt, nil, 'no scan, no state')
  df.workshop_type = names
  shop('Masons', 8, 8, 10)
  H.runs(W, 4)
  T.eq(W.state().adopt.ws, 1, 'readable again: the shop stands, nothing is pruned')
  T.eq(types(man(W).workshops), {'Masons'})
end)

T.test('FR-76: a fort with standing workshops and an empty manifest (reclaimed) adopts the built ones, not the unbuilt ' ..
       'and not Custom; the state counts what stands; no second adoption', function()
  local W = fresh{tag = 'adopt'}
  shop('Carpenters', 5, 5, 10)
  shop('Masons', 9, 5, 10)
  shop('Kitchen', 13, 5, 10)
  shop('Still', 17, 5, 10)
  shop('Craftsdwarfs', 21, 5, 10, true)                           -- under construction
  shop('Custom', 25, 5, 10)                                       -- a reaction workshop
  shop('Smelter', 29, 5, 10, false, true)
  local oth = df.global.world.buildings.other
  for i = 1, 4 do oth.BED:insert('#', {}) end
  oth.WELL:insert('#', {})
  H.runs(W, 2)
  local m = man(W)
  T.eq(types(m.workshops), {'Carpenters', 'Kitchen', 'Masons', 'Smelter', 'Still'})
  T.eq(m.workshops[1].pos, {5, 5, 10}, 'the centre of the building')
  local a = W.state().adopt
  T.eq({a.ws, a.new, a.rec, a.beds, a.wells}, {5, 5, 1, 4, 1})
  T.eq(a.miss, nil, 'every mandatory workshop stands (an unbuilt one counts: a project builds it)')
  H.runs(W, 6)
  a = W.state().adopt
  T.eq({a.new, #man(W).workshops}, {5, 5}, 'no second adoption')
end)

T.test('FR-76: a reclaimed fort without a Carpenters and Craftsdwarfs workshop gets PROJECT_REQUEST workshops ' ..
       'why=mandatory with the types after ask_days, once per request cooldown; the status lists them', function()
  local W = fresh{tag = 'mand'}
  shop('Masons', 9, 5, 10)
  shop('Kitchen', 13, 5, 10)
  shop('Still', 17, 5, 10)
  H.runs(W, 2)
  local a = W.state().adopt
  T.eq({a.rec, a.miss}, {1, {'Carpenters', 'Craftsdwarfs'}})
  T.eq(#W.find_events('PROJECT_REQUEST'), 0, 'not yet: ask_days (3) first')
  H.runs(W, 2 * 3)
  local ev = W.find_events('PROJECT_REQUEST')
  T.eq(#ev, 1)
  T.eq({ev[1].d.tpl, ev[1].d.why, ev[1].d.types, ev[1].d.n}, {'workshops', 'mandatory', {'Carpenters', 'Craftsdwarfs'}, 2})
  T.ok(logged(W, 'warn', 'reclaimed fort without Carpenters, Craftsdwarfs'), 'kern.log says what and how')
  H.runs(W, 2 * 6)
  T.eq(#W.find_events('PROJECT_REQUEST'), 1, 'one request per cooldown (7 days)')
  H.runs(W, 2 * 3)
  T.eq(#W.find_events('PROJECT_REQUEST'), 2, 'asked again after the cooldown while they are missing')
  shop('Carpenters', 21, 5, 10)
  shop('Craftsdwarfs', 25, 5, 10)
  H.runs(W, 4)
  T.eq(W.state().adopt.miss, nil, 'built by the request: nothing missing any more')
end)

T.test('FR-76: no request in a SIEGE, with a workshops project pending, for a fort that is not a reclaimed one ' ..
       '(fewer than min_ws adopted at the first scan) or with runner.reclaim.on false', function()
  local W = fresh{tag = 'mand2'}
  shop('Masons', 9, 5, 10)
  shop('Kitchen', 13, 5, 10)
  shop('Still', 17, 5, 10)
  W.K.set_mode('SIEGE', 'test')
  H.runs(W, 2 * 5)
  T.eq(#W.find_events('PROJECT_REQUEST'), 0, 'SIEGE: nothing is asked')
  local Wp = fresh{tag = 'mandp'}
  shop('Masons', 9, 5, 10); shop('Kitchen', 13, 5, 10); shop('Still', 17, 5, 10)
  H.place(Wp, 'wsp', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {}, x = 40, label = 'dig'}))
  H.runs(Wp, 2 * 5)
  T.eq(Wp.runner_pending == nil and runner.pending(Wp.K, 'workshops') or 0, 1)
  T.eq(#Wp.find_events('PROJECT_REQUEST'), 0, 'a workshops project is on its way: nothing is asked')
  local W2 = fresh{tag = 'mand3'}
  shop('Masons', 9, 5, 10)                                        -- 1 standing workshop adopted: below min_ws (3)
  H.runs(W2, 2 * 6)
  T.eq({W2.state().adopt.rec, #W2.find_events('PROJECT_REQUEST')}, {nil, 0})
  local W3 = fresh{tag = 'mand4'}
  W3.K.cfg.baseline = {runner = {reclaim = {on = false}}}
  shop('Masons', 9, 5, 10); shop('Kitchen', 13, 5, 10); shop('Still', 17, 5, 10)
  H.runs(W3, 2 * 6)
  T.eq(W3.state().adopt, nil, 'switched off: no scan, no adoption')
  T.eq(man(W3).workshops, nil)
end)

-- FR-76 (Run 12 Trussroads): fortcore stage 2 "site: same" (y497s3b0) was `done` without its stage 1 (y497s2b0, parked at
-- breach:damp): its tiles were open in the old fort, so it finished at once, and the plan counted stage 1 as delivered
local function stage_doc(stage, x)
  return H.dig_doc(1, {tpl = 'fortcore', class = 'defense', params = {stage = stage}, x = x, label = 's' .. stage .. '.dig'})
end

T.test('FR-76: a fortcore stage 2 that finishes while stage 1 never ran is not counted as delivered (hist, phases); ' ..
       'PROJECT_DONE and kern.log say so; old code counted it', function()
  local ph = {{id = 'P0', title = 'a', approve = false, deliver = {{k = 'proj', tpl = 'fortcore', stage = 1}}},
              {id = 'P1', title = 'b', approve = false, deliver = {}}}
  local W = fresh{tag = 'pre', phases = {v = 2, kind = 'phases', phases = ph}}
  H.floor(W, 40, 10, 100, 44, 10)                                 -- the old fort's rooms: nothing to dig
  H.place(W, 'y497s3b0', stage_doc(2, 40))
  H.runs(W, 3)
  T.eq(H.proj(W, 'y497s3b0').done, 1, 'it finished')
  local h = W.K.persist.get('m.runner').hist.fortcore
  T.eq({h.n, h.ps or 0, h.ls or 0}, {1, 0, 0}, 'stage 2 not counted')
  T.eq(W.state().phase, 'P0', 'the phase still waits for stage 1')
  local ev = W.find_events('PROJECT_DONE')[1]
  T.ok(ev.msg:find('stage 1 never ran: not counted', 1, true), ev.msg)
  T.eq(ev.d.pre, 1)
  T.ok(logged(W, 'warn', 'stage 2 done, but stage 1 never ran'), 'kern.log')
  -- stage 1 first, then stage 2: both counted
  local W1 = fresh{tag = 'pre2'}
  H.floor(W1, 40, 10, 100, 44, 10)
  H.floor(W1, 60, 10, 100, 64, 10)
  H.place(W1, 'f1', stage_doc(1, 40))
  H.runs(W1, 3)
  H.place(W1, 'f2', stage_doc(2, 60))
  H.runs(W1, 3)
  local h1 = W1.K.persist.get('m.runner').hist.fortcore
  T.eq({h1.n, h1.ps}, {2, 2})
  T.eq(W1.find_events('PROJECT_DONE')[2].d.pre, nil)
  -- a manifest with fortcore zones (an older kernel) counts as stage 1 having run
  local W2 = fresh{tag = 'pre3', persist = {manifest = {v = 2, zones = {Z4 = {{1, 1, 100, 9, 9, 100}}}}}}
  H.floor(W2, 40, 10, 100, 44, 10)
  H.place(W2, 'f2', stage_doc(2, 40))
  H.runs(W2, 3)
  T.eq(W2.K.persist.get('m.runner').hist.fortcore.ps, 2, 'zones in the manifest: stage 1 ran in an older kernel')
end)

T.done()
