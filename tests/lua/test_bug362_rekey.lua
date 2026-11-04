-- BUG-362 (Run 16 i2): the runtime folder is keyed at the first adopt (the world save 'region1'); after a save-as the next boot
-- re-keys it to the new save folder (<save>-site<N>), moves the folder with its data, and never touches an autosave name.
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')

T.test('BUG-362: rekey_to follows a player save-as only', function()
  local m = {save = 'region1-site97', base = 'region1'}
  T.eq(kern.rekey_to(m, 'r16b-ostgate'), 'r16b-ostgate-site97')
  T.eq(kern.rekey_to({save = 'region1-site97'}, 'r16b-ostgate'), 'r16b-ostgate-site97', 'legacy marker: base from the key')
  T.eq(kern.rekey_to(m, 'region1'), nil, 'same folder')
  T.eq(kern.rekey_to(m, 'autosave 2'), nil, 'DF autosave names never re-key')
  T.eq(kern.rekey_to(m, 'current'), nil)
  T.eq(kern.rekey_to({save = 'region2'}, 'x'), nil, 'a key without -site<N> is legacy: stays')
  T.eq(kern.rekey_to(m, '../x'), nil)
  T.eq(kern.rekey_to({save = 'r16b-ostgate-site97', base = 'r16b-ostgate'}, 'autosave 1'), nil)
  T.eq(kern.rekey_to({save = 'r16b-ostgate-site97', base = 'r16b-ostgate'}, 'r16b-ostgate'), nil, 'second adopt: no change')
end)

T.test('BUG-362: boot after save-as moves the runtime folder and re-keys marker, ACTIVE and world data', function()
  local W = H.world{tag = 'rekey', save = 'r16b-ostgate'}
  local rt = W.rt
  luahost.mkdir_recursive(rt .. '/region1-site97/bp')
  H.write(rt .. '/region1-site97/plan.json', '{"keep":1}')
  local marker = {v = 2, adopted = 5, save = 'region1-site97', base = 'region1', fort = 'Mockfort',
                  acceptance = 0, baseline = 0, boots = 1}
  dfhack.persistent.saveSiteDataString('dfllm', json.encode(marker))
  local ok, msg = H.boot(W, {modules = {}})
  T.ok(ok, msg)
  T.ok(msg:find('r16b-ostgate-site97', 1, true), msg)
  T.eq(H.read(rt .. '/ACTIVE'), 'r16b-ostgate-site97')
  T.eq(H.read(rt .. '/r16b-ostgate-site97/plan.json'), '{"keep":1}', 'the old data moved along')
  T.ok(not luahost.isdir(rt .. '/region1-site97'), 'old folder gone')
  local m = json.decode(dfhack.persistent.getSiteDataString('dfllm'))
  T.eq({m.save, m.base}, {'r16b-ostgate-site97', 'r16b-ostgate'})
  T.eq(json.decode(W.world_raw['dfllm.active']).save, 'r16b-ostgate-site97')
  kern.stop()
end)

T.test('BUG-362: an existing target folder keeps the old key (nothing merged)', function()
  local W = H.world{tag = 'rekey2', save = 'r16b-ostgate'}
  luahost.mkdir_recursive(W.rt .. '/region1-site97')
  luahost.mkdir_recursive(W.rt .. '/r16b-ostgate-site97')
  dfhack.persistent.saveSiteDataString('dfllm', json.encode({v = 2, adopted = 5, save = 'region1-site97', fort = 'F',
                                                              acceptance = 0, baseline = 0, boots = 1}))
  local ok, msg = H.boot(W, {modules = {}})
  T.ok(ok, msg)
  T.ok(msg:find('region1-site97', 1, true), msg)
  T.eq(H.read(W.rt .. '/ACTIVE'), 'region1-site97')
  kern.stop()
end)

T.done()
