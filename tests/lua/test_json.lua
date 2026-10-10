-- dfllm.util.json: integers only, comma locale, UTF-8, structure, errors, round trip.
local T = require('testlib')
local json = require('dfllm.util.json')
local enc, dec = json.encode, json.decode

T.test('integers', function()
  T.eq(enc(0), '0')
  T.eq(enc(-5), '-5')
  T.eq(enc(math.maxinteger), '9223372036854775807')
  T.eq(enc(math.mininteger), '-9223372036854775808')
  T.eq(enc(9007199254740993), '9007199254740993')
end)

T.test('floats are rounded to integers', function()
  T.eq(enc(1.5), '2')
  T.eq(enc(2.5), '3')
  T.eq(enc(-1.5), '-2')
  T.eq(enc(0.49), '0')
  T.eq(enc(-0.0), '0')
  T.eq(enc(100.0), '100')
  T.ok(enc(1e300):match('^%d+$'), 'huge float has digits only')
  T.eq(enc(0 / 0), 'null')
  T.eq(enc(math.huge), 'null')
  T.eq(enc(-math.huge), 'null')
end)

T.test('comma locale does not leak into output', function()
  local prev = os.setlocale(nil, 'numeric')
  local loc = os.setlocale('German_Germany.1252', 'numeric') or os.setlocale('de-DE', 'numeric')
           or os.setlocale('de_DE.UTF-8', 'numeric')
  local ok, err = pcall(function()
    if loc then T.eq(tostring(1.5), '1,5', 'locale really uses a decimal comma') end
    T.eq(enc({a = 1.25, b = 1234567, c = {0.5, 2.5}}), '{"a":1,"b":1234567,"c":[1,3]}')
    T.eq(enc(12345678.9), '12345679')
    T.eq(dec('{"x":1.5}').x, 1.5)
    T.eq(dec('[2.5e1]')[1], 25)
    T.eq(math.type(dec('[2.5e1]')[1]), 'integer')
    T.eq(dec('-0.25'), -0.25)
  end)
  os.setlocale(prev, 'numeric')
  if not ok then error(err, 0) end
end)

T.test('umlauts and UTF-8 pass through', function()
  local s = 'Grüße, Ünal – Öl 😀'
  T.eq(enc(s), '"' .. s .. '"')
  T.eq(dec(enc(s)), s)
  T.eq(dec('"\\u00fc\\u00e4"'), 'üä')
  T.eq(dec('"\\ud83d\\ude00"'), '😀')
  T.eq(dec('"Kr\\u00e4uter"'), 'Kräuter')
end)

T.test('invalid UTF-8 becomes U+FFFD', function()
  T.eq(enc('a\255b'), '"a\239\191\189b"')
  T.eq(enc('\129'), '"\239\191\189"')             -- lone CP437 byte (ü in DF encoding)
  T.eq(enc('\192\128'), '"\239\191\189\239\191\189"') -- overlong NUL
  T.eq(enc('\237\160\128'), '"\239\191\189\239\191\189\239\191\189"') -- UTF-8 surrogate
  T.eq(enc('ab\195'), '"ab\239\191\189"')          -- truncated sequence
  T.eq(dec('"\\udc00x"'), '\239\191\189x')         -- lone low surrogate escape
  T.eq(dec('"\\ud800x"'), '\239\191\189x')         -- lone high surrogate escape
end)

T.test('escapes', function()
  T.eq(enc('a"b\\c'), '"a\\"b\\\\c"')
  T.eq(enc('l1\nl2\tx\r'), '"l1\\nl2\\tx\\r"')
  T.eq(enc('\1\31\127'), '"\\u0001\\u001f\\u007f"')
  T.eq(dec('"a\\/b\\b\\f"'), 'a/b\b\f')
  T.eq(dec('"\127"'), '\127')
end)

T.test('arrays, objects and empties', function()
  T.eq(enc({}), '[]')
  T.eq(enc(json.object{}), '{}')
  T.eq(enc(json.array{}), '[]')
  T.eq(enc({1, 2, 3}), '[1,2,3]')
  T.eq(enc({b = 1, a = {x = true, y = false}}), '{"a":{"x":true,"y":false},"b":1}')
  T.eq(enc({[10] = 'x', [2] = 'y'}), '{"10":"x","2":"y"}')
  T.eq(enc({1, 2, k = 3}), '{"1":1,"2":2,"k":3}')
  T.eq(enc(dec('{}')), '{}')
  T.eq(enc(dec('[]')), '[]')
  T.eq(enc(dec('{"a":[]}')), '{"a":[]}')
  T.ok(json.is_array(dec('[1]')))
  T.eq(enc({n = json.null}), '{"n":null}')
end)

T.test('null handling', function()
  local o = dec('{"a":null,"b":1}')
  T.eq(o.a, nil)
  T.eq(o.b, 1)
  local a = dec('[1,null,3]')
  T.eq(#a, 3)
  T.ok(a[2] == json.null)
  T.ok(dec('null') == json.null)
  T.eq(enc(a), '[1,null,3]')
end)

T.test('encode errors', function()
  T.raises(function() enc(print) end, 'cannot encode function')
  local t = {}
  t.self = t
  T.raises(function() enc(t) end, 'cycle')
  local deep = {}
  local cur = deep
  for _ = 1, 70 do cur[1] = {}; cur = cur[1] end
  T.raises(function() enc(deep) end, 'deeper than 64')
  T.raises(function() enc({[1.5] = 1}) end, 'float')
  T.raises(function() enc({[true] = 1}) end, 'boolean')
  T.raises(function() enc({[1] = 'a', ['1'] = 'b', x = 1}) end, 'duplicate key')
end)

T.test('decode errors', function()
  for _, bad in ipairs({'', '{', '[1,]', '{"a" 1}', '"abc', 'tru', '1 2', '"\1"', '{a:1}',
                        '[1 2]', '"\\x"', '"\\u12"', '01x', '-', '{"a":}'}) do
    T.raises(function() dec(bad) end, '^json: ', 'should reject ' .. string.format('%q', bad))
  end
  local v, err = json.try_decode('[1,')
  T.eq(v, nil)
  T.ok(err:find('at byte'))
  T.raises(function() dec(5) end, 'expects a string')
end)

T.test('numbers decode', function()
  T.eq(math.type(dec('42')), 'integer')
  T.eq(dec('-7'), -7)
  T.eq(math.type(dec('3.0')), 'integer')
  T.eq(dec('1e2'), 100)
  T.eq(dec('1.25'), 1.25)
  T.eq(dec('9223372036854775807'), math.maxinteger)
end)

T.test('BOM and whitespace', function()
  T.eq(dec('\239\187\191 {"a": [ 1 , 2 ] }\r\n').a, {1, 2})
end)

T.test('round trip of the DESIGN state example', function()
  local s = '{"v":2,"seq":812,"t":{"y":3,"tick":123456,"season":1,"tps":462,"paused":false},"mode":"PEACE",' ..
    '"phase":"P3","pop":{"cit":52,"adults":44,"cap":55,"gate_cap":55,"soldiers":8},"ready":{"lvl":1,"worn":94,' ..
    '"cv":13,"drill_age":40000,"audit":{"ok":1,"age":9000,"min_traps":22},"fail":["traps<30"]},' ..
    '"stock":{"drink_d":182,"food_d":75,"meals":6,"hosp_water":1},"care":{"stressed_pct":4,"naked":0,"ghosts":0,' ..
    '"corpses_old":0,"tombs_free":9,"moods":0},"labor":{"starving":0,"idle":31},"threat":{"vis":0,"armed":0},' ..
    '"proj":[["fortcore","s2.build",64,""]],"bridges":{"O1":"down","B1":"down","B2":"down"},' ..
    '"k":{"ms_s":11,"gap_max_ms":420,"slow":[],"faults":0},"owners":{"pause":null,"tempo":"mode"},"ev":8812}'
  local v = dec(s)
  T.eq(v.seq, 812)
  T.eq(v.proj[1][2], 's2.build')
  T.eq(v.owners.pause, nil)
  T.eq(enc(v.k.slow), '[]')
  local again = dec(enc(v))
  T.eq(again, v)
  T.eq(enc(again), enc(v))
end)

T.done()
