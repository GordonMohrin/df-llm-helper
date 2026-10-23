-- BUG-096 / BUG-097 / FR-80: the pure rules of seal's burrow guard (lua/dfllm/burrowkeep.lua): runs, shares, judging a
-- reading, what is missing and in which order, the knobs, the persisted record.
local T = require('testlib')
local BK = require('dfllm.burrowkeep')
local json = require('dfllm.util.json')

T.test('pack: rows are sorted by z, y, x0 and merged where they touch or overlap; tiles and runs count all of them', function()
  local flat, tiles, runs, part = BK.pack({{5, 2, 10, 12}, {5, 1, 3, 4}, {5, 2, 13, 15}, {4, 9, 0, 0}, {5, 1, 4, 6}, {5, 2, 20, 21}})
  T.eq(flat, {4, 9, 0, 0, 5, 1, 3, 6, 5, 2, 10, 15, 5, 2, 20, 21})
  T.eq({tiles, runs, part}, {1 + 4 + 6 + 2, 4, false})
  T.eq({BK.size(flat)}, {13, 4})
  local f2, t2, r2, p2 = BK.pack({}, 10)
  T.eq({f2, t2, r2, p2}, {{}, 0, 0, false})
  -- more than max runs: the first max, flagged, the tile count still of all
  local f3, t3, r3, p3 = BK.pack({{1, 1, 0, 3}, {1, 2, 0, 3}, {1, 3, 0, 3}}, 2)
  T.eq({#f3, t3, r3, p3}, {8, 12, 3, true})
end)

T.test('has / same', function()
  local flat = {5, 1, 3, 6, 5, 2, 10, 15}
  T.ok(BK.has(flat, 3, 1, 5) and BK.has(flat, 6, 1, 5) and BK.has(flat, 12, 2, 5))
  T.ok(not BK.has(flat, 7, 1, 5) and not BK.has(flat, 3, 1, 6) and not BK.has(flat, 3, 2, 5) and not BK.has(nil, 1, 1, 1))
  T.ok(BK.same({1, 2}, {1, 2}) and BK.same(nil, nil) and not BK.same({1, 2}, {1, 3}) and not BK.same({1}, nil))
end)

T.test('shrunk: more than pct % lost; a baseline under 20 tiles only when emptied; nothing to lose, nothing lost', function()
  T.ok(BK.shrunk(100, 69, 30) and not BK.shrunk(100, 70, 30) and not BK.shrunk(100, 100, 30) and not BK.shrunk(100, 300, 30))
  T.ok(BK.shrunk(100, 0, 30) and BK.shrunk(3, 0, 30) and not BK.shrunk(0, 0, 30))
  T.ok(not BK.shrunk(19, 1, 30) and BK.shrunk(20, 13, 30) and not BK.shrunk(20, 14, 30))
  T.ok(BK.shrunk(100, 49, 50) and not BK.shrunk(100, 50, 50))
end)

T.test('judge: the seven answers', function()
  local r = {base = 100}
  T.eq(BK.judge(nil, {exists = false, n = 0}, 30), 'none')
  T.eq(BK.judge(nil, {exists = true, n = 50}, 30), 'first')
  T.eq(BK.judge(r, {exists = true, n = 80}, 30), 'ok')
  T.eq(BK.judge(r, {exists = true, n = 60}, 30), 'shrunk')
  T.eq(BK.judge(r, {exists = false, n = 0}, 30), 'gone')
  r.ep = {}
  T.eq(BK.judge(r, {exists = true, n = 60}, 30), 'open')
  T.eq(BK.judge(r, {exists = false, n = 0}, 30), 'open')
  T.eq(BK.judge(r, {exists = true, n = 95}, 30), 'recovered')
end)

T.test('missing: the tiles the burrow lacks, the runs near the points first, at most cap, complete only when all were looked at', function()
  local flat = {5, 1, 0, 9, 5, 30, 0, 4, 5, 60, 0, 9}                   -- three rows
  local have = {}
  local function assigned(x, y, z) return have[x .. ',' .. y .. ',' .. z] == true end
  local out, scanned, complete = BK.missing(flat, assigned, 100, nil, 8)
  T.eq({#out, scanned, complete}, {25, 25, true})
  T.eq(out[1], {0, 1, 5})
  -- a point near the row y30: that row first
  out, _, complete = BK.missing(flat, assigned, 3, {{2, 31, 5}}, 8)
  T.eq({out, complete}, {{{0, 30, 5}, {1, 30, 5}, {2, 30, 5}}, false})
  -- another level is not near
  out = BK.missing(flat, assigned, 2, {{2, 31, 6}}, 8)
  T.eq(out, {{0, 1, 5}, {1, 1, 5}})
  -- tiles it has are not missing
  for x = 0, 9 do have[x .. ',1,5'] = true end
  out, scanned, complete = BK.missing(flat, assigned, 100, nil, 8)
  T.eq({#out, scanned, complete}, {15, 25, true})
  T.eq(out[1], {0, 30, 5})
  -- cap 0 and nonsense
  T.eq({BK.missing(flat, assigned, 0, nil, 8)}, {{}, 0, false})
  T.eq({BK.missing(nil, assigned, 5, nil, 8)}, {{}, 0, false})
  -- cap reached exactly at the end: not complete (the caller does not know)
  have = {}
  out, _, complete = BK.missing({5, 1, 0, 2}, assigned, 3, nil, 8)
  T.eq({#out, complete}, {3, false})
end)

T.test('conf: defaults, the knobs of config/baseline.json burrow.guard, a bad value keeps its default', function()
  T.eq(BK.conf(nil), {on = true, shrink_pct = 30, repair_per_day = 2000, settle_days = 14, every_s = 120})
  T.eq(BK.conf({burrow = {guard = {on = false, shrink_pct = 50, repair_per_day = 0, settle_days = 3, every_s = 10}}}),
       {on = false, shrink_pct = 50, repair_per_day = 0, settle_days = 3, every_s = 10})
  T.eq(BK.conf({burrow = {guard = {on = 'no', shrink_pct = 4, repair_per_day = 20001, settle_days = 'x', every_s = 9}}}), BK.DEF)
  T.eq(BK.conf({burrow = {guard = {shrink_pct = 95.0, repair_per_day = 20000, settle_days = 365, every_s = 3600}}}),
       {on = true, shrink_pct = 95, repair_per_day = 20000, settle_days = 365, every_s = 3600})
  T.eq(BK.conf({burrow = 5}), BK.DEF)
  T.eq(BK.conf({burrow = {guard = 'x'}}), BK.DEF)
  local d = BK.DEF
  T.eq(BK.conf(nil) == d, false, 'a copy')
end)

T.test('load: the record of this adoption is kept (sanitized), another adoption\'s or a malformed one starts empty', function()
  local rec = {v = 2, ad = 5, b = {['Kern+'] = {id = 8, base = 121, nb = 1, t = 99, k = {9, 5, 5, 15}, kp = 1,
                                                 ep = {t = 100, was = 121, now = 9, cause = 'load', gone = 1, fd = 3, fx = 4,
                                                       z = 100, crit = {'well', 'refuge'}}},
                                  junk = 'x', [''] = {base = 1}, big = {base = 'many'}}}
  local out = BK.load(json.decode(json.encode(rec)), 5)
  T.eq(out.ad, 5)
  local k = out.b['Kern+']
  T.eq({k.id, k.base, k.nb, k.t, k.k, k.kp}, {8, 121, 1, 99, {9, 5, 5, 15}, 1})
  T.eq({k.ep.t, k.ep.was, k.ep.now, k.ep.cause, k.ep.gone, k.ep.crit}, {100, 121, 9, 'load', 1, {'well', 'refuge'}})
  T.eq({out.b.junk, out.b[''], out.b.big}, {nil, nil, nil})
  T.eq(BK.load(rec, 6), {v = 2, ad = 6, b = {}}, 'another adoption')
  T.eq(BK.load(nil, 0), {v = 2, ad = 0, b = {}})
  T.eq(BK.load('x', 0), {v = 2, ad = 0, b = {}})
  local bad = BK.load({ad = 0, b = {a = {base = 3, k = {1, 2, 3}}, b = {base = 3, k = {1, 2, 3, 'x'}}, c = {base = 3, k = {}}}}, 0)
  T.eq({bad.b.a.k, bad.b.b.k, bad.b.c.k, bad.b.a.base}, {nil, nil, nil, 3}, 'runs that are not 4n integers are dropped, the record stays')
  local e = BK.load({ad = 0, b = {a = {base = 3, ep = {t = 5, cause = 'whatever', crit = {1, 'well'}}}}}, 0).b.a.ep
  T.eq({e.cause, e.crit, e.was, e.fd}, {'runtime', {'well'}, 0, 0})
  T.eq(BK.load({ad = 0, b = {a = {base = 3, ep = {cause = 'load'}}}}, 0).b.a.ep, nil, 'an episode without a tick is dropped')
end)

T.done()
