-- BUG-149 (live test i1, 2026-10-28): a world save holds the site marker of every fort dfllm adopted in that world, and the
-- save folder does not say which one is loaded. The kernel writes the fort it boots into world data (dfllm.active), so
-- supervise.marker_of can pick that fort's marker (tests/test_bug149_save_marker.py).
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')

T.test('BUG-149: boot writes the active fort (runtime key and name) into world data', function()
  local W = H.world{tag = 'active'}
  T.eq(W.world_raw[kern.ACTIVE_KEY], nil)
  local ok, msg = H.boot(W, {modules = {}})
  T.ok(ok, msg)
  T.eq(kern.ACTIVE_KEY, 'dfllm.active')
  local a = json.decode(W.world_raw['dfllm.active'] or 'null')
  T.ok(type(a) == 'table', 'world data written')
  T.eq({a.save, a.fort}, {'region1', 'Mockfort'})
  T.ok(#W.world_raw['dfllm.active'] < 200, 'small')
  kern.stop()
end)

T.test('BUG-149: an unmarked save writes nothing (the player\'s own forts stay untouched)', function()
  local W = H.world{tag = 'active2', marker = false}
  local ok = H.boot(W, {modules = {}})
  T.ok(not ok)
  T.eq(W.world_raw['dfllm.active'], nil)
end)

T.done()
