-- BUG-513 (Run 16d i4 Trumpetrealms y388-y389: the fortcore refuge-lever retrofit stood at 100 %, `inspect defense` showed the refuge levers
-- `linked 0`, DECISION_NEEDED refuge_levers asked for the retrofit again every 30 days, three retrofits were placed, no LEVER link and no
-- ACT_FAIL followed for 3.5 million ticks): gate reads every manifest lever into a state (none / site / built / job / linked), publishes
-- the refuge ones (gate.refuge_levers), links the refuge lever of a bridge before its other levers while mechanisms are scarce (a link
-- takes 2), and readiness' question names what the levers wait for (a mechanism for the site, 2 free mechanisms for the link, a mechanic
-- for a stale link job) instead of asking for the retrofit again; with no lever standing it asks for the retrofit as before.
local T = require('testlib')
local X = require('wp6_world')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z
local kv = kmock.vec

-- the siege_world manifest with a third lever per bridge inside Tiefe+ (x 70..72, y 70, z Z-6)
local REF = {O1 = {70, 70, Z - 6}, B1 = {71, 70, Z - 6}, B2 = {72, 70, Z - 6}}
local function manifest()
  local m = S.manifest()
  for name, p in pairs(REF) do table.insert(m.bridges[name].levers, p) end
  return m
end

local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end

local function built(b, on)
  b.getBuildStage = function() return on and 1 or 0 end
  b.getMaxBuildStage = function() return 1 end
end
local function is_ref(lv)
  for _, p in pairs(REF) do if lv.x1 == p[1] and lv.y1 == p[2] and lv.z == p[3] then return true end end
  return false
end

local function world()
  local units = X.citizens(50, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}})
  local W = X.world{units = units, manifest = manifest()}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  local snap, runner = X.snapshot(), X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  df.job_type.LinkBuildingToTrigger = 146
  X.load(W, {'military', 'readiness'}, {X.economy(), snap, runner}, {'sense', 'threat', 'siege', 'gate'})
  X.mod('readiness').CAPS = {[0] = 120, [1] = 120, [2] = 120, [3] = 250}
  W.calls, W.lmode = {}, 'fail'
  W.act_result('link_lever', function(lid, bid)
    W.calls[#W.calls + 1] = {lid, bid}
    if W.lmode == 'fail' then return false, 'needs 2 free reachable mechanisms, 1 found' end
    local lv = W.buildings[lid]
    lv.jobs:insert('#', {id = 9000 + #W.calls, job_type = df.job_type.LinkBuildingToTrigger})
    return true, 9000 + #W.calls
  end)
  for _, b in pairs(W.bridges) do built(b, true) end
  for _, lv in ipairs(W.levers) do
    built(lv, true)
    if is_ref(lv) then lv.linked_mechanisms = kv{} end            -- the retrofit's levers: nothing linked yet
  end
  return W
end

local function question(W)
  local q = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'refuge_levers' then q[#q + 1] = e end end
  return q
end
local function refuge(W)
  local ok, r = W.K.call('gate', 'refuge_levers')
  T.ok(ok, tostring(r))
  return r
end

T.test('BUG-513: the refuge levers placed but not built (waiting for a mechanism): gate.refuge_levers says site, the question names the ' ..
       'mechanism and does NOT ask for the retrofit again', function()
  local W = world()
  for _, lv in ipairs(W.levers) do if is_ref(lv) then built(lv, false) end end
  day(W, 3)
  local r = refuge(W)
  T.eq({r.B1.n, r.B1.site, r.B1.linked, r.O1.site, r.B2.site}, {1, 1, 0, 1, 1}, T.show(r))
  day(W, 2)
  local q = question(W)
  T.ok(#q >= 1, 'asked')
  T.eq(q[1].d.cause, 'unbuilt')
  T.eq(q[1].d.cmds, nil, 'no retrofit command: the levers are placed')
  T.ok(q[1].d.q:find('placed, not built', 1, true) and q[1].d.q:find('waits for a mechanism', 1, true), q[1].d.q)
  T.ok(q[1].d.q:find('do not place the retrofit again', 1, true), q[1].d.q)
end)

T.test('BUG-513: built but not linked: refused for the mechanisms; the question names the 2-mechanism link and the last refusal', function()
  local W = world()
  day(W, 3)
  T.ok(#W.calls >= 1, 'gate tried a link')
  local r = refuge(W)
  T.eq({r.B1.built, r.B1.site, r.B1.job}, {1, 0, 0}, T.show(r))
  day(W, 2)
  local q = question(W)
  T.ok(#q >= 1, 'asked')
  T.eq(q[1].d.cause, 'unlinked')
  T.eq(q[1].d.cmds, nil)
  T.ok(q[1].d.q:find('not linked: a link takes 2 free mechanisms', 1, true), q[1].d.q)
  T.ok(q[1].d.q:find('last refusal: needs 2 free reachable mechanisms, 1 found', 1, true), q[1].d.q)
end)

T.test('BUG-513: a link job queued for days that nobody does is named (stale after 12 days); a lever that is not there asks for the ' ..
       'retrofit as before', function()
  local W = world()
  W.lmode = 'ok'
  day(W, 2)
  local r = refuge(W)
  T.eq(r.B1.job, 1, 'the link job is queued: ' .. T.show(r))
  day(W, 14)
  r = refuge(W)
  T.eq(r.B1.stale, true, 'stale after LINK_STALE ticks')
  day(W, 31)                                    -- the next question (ask_days) comes with the stale job
  local q = question(W)
  T.ok(#q >= 2, 'asked again')
  local last = q[#q]
  T.eq(q[1].d.cause, 'link_job', 'the first question: a job is queued')
  T.eq(last.d.cause, 'link_stale')
  T.ok(last.d.q:find('Mechanics labor', 1, true), last.d.q)
  -- no lever stands there: the retrofit
  local W2 = world()
  for _, lv in ipairs(W2.levers) do
    if is_ref(lv) then
      lv.x1, lv.x2, lv.y1, lv.y2 = lv.x1 + 20, lv.x2 + 20, lv.y1 + 20, lv.y2 + 20      -- not at its manifest tile
    end
  end
  day(W2, 5)
  local q2 = question(W2)
  T.ok(#q2 >= 1)
  T.eq(q2[1].d.cause, 'none')
  T.eq(q2[1].d.cmds, {'bp.place tpl=fortcore site=same stage=3 retrofit=2'})
end)

T.test('BUG-513: scarce mechanisms go to the refuge lever first: a bridge with a linked lever and an unlinked refuge lever links the ' ..
       'refuge one before its second outside lever', function()
  local W = world()
  -- B1: lever 21 linked, lever 22 (outside) unlinked, the refuge lever unlinked
  for _, lv in ipairs(W.levers) do
    if lv.bridge == 'B1' and lv.id == 22 then lv.linked_mechanisms = kv{} end
  end
  day(W, 3)
  local b1 = W.bridges.B1.id
  local seq = {}
  for _, c in ipairs(W.calls) do if c[2] == b1 then seq[#seq + 1] = c[1] end end
  T.ok(#seq >= 1, 'a link was tried')
  local ref_id
  for _, lv in ipairs(W.levers) do if lv.bridge == 'B1' and is_ref(lv) then ref_id = lv.id end end
  T.eq(seq[1], ref_id, 'the refuge lever first')
  for _, id in ipairs(seq) do T.eq(id, ref_id, 'the outside lever 22 waits while the refuge lever has no link') end
  -- a bridge with NO linked lever links the refuge lever first too, and the others after it
  W.lmode = 'ok'
  for _, lv in ipairs(W.levers) do if lv.bridge == 'B1' then lv.linked_mechanisms = kv{}; lv.jobs = kv{} end end
  W.calls = {}
  day(W, 4)
  local first
  for _, c in ipairs(W.calls) do if c[2] == b1 then first = first or c[1] end end
  T.eq(first, ref_id, 'no linked lever at all: the refuge lever is still first')
end)

T.done()
