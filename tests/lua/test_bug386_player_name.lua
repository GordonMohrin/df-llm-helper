-- BUG-386 (Run 16 i2): the save-as name is gone once DF renames the save to 'autosave N'; the re-key finds it again
-- (marker.want from the running kernel, else the newest BOOT event of the fort's runtime folder).
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')

local function marker(extra)
  local m = {v = 2, adopted = 5, save = 'region1-site97', base = 'region1', fort = 'Mockfort', acceptance = 0, baseline = 0,
             boots = 1}
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

T.test('BUG-386: player_name order and shape', function()
  T.eq(kern.player_name(marker(), 'r16b-ostgate', nil), 'r16b-ostgate')
  T.eq(kern.player_name(marker({want = 'wanted'}), 'autosave 3', nil), 'wanted')
  T.eq(kern.player_name(marker(), 'autosave 3', nil), nil, 'no root, no want')
  T.ok(not kern.player_save('autosave 1') and not kern.player_save('current') and not kern.player_save('../x'))
  T.ok(kern.player_save('r16b-ostgate'))
end)

T.test('BUG-386: boot in autosave N re-keys by marker.want, old data moves along', function()
  local W = H.world{tag = 'want', save = 'autosave 3'}
  luahost.mkdir_recursive(W.rt .. '/region1-site97')
  H.write(W.rt .. '/region1-site97/plan.json', '{"keep":1}')
  dfhack.persistent.saveSiteDataString('dfllm', json.encode(marker({want = 'r16b-ostgate'})))
  local ok, msg = H.boot(W, {modules = {}})
  T.ok(ok, msg)
  T.ok(msg:find('r16b-ostgate-site97', 1, true), msg)
  T.eq(H.read(W.rt .. '/ACTIVE'), 'r16b-ostgate-site97')
  T.eq(H.read(W.rt .. '/r16b-ostgate-site97/plan.json'), '{"keep":1}')
  local m = json.decode(dfhack.persistent.getSiteDataString('dfllm'))
  T.eq({m.save, m.base, m.want}, {'r16b-ostgate-site97', 'r16b-ostgate', nil})
  kern.stop()
end)

T.test('BUG-386: an older fort without want: the newest player-named BOOT event gives the name', function()
  local W = H.world{tag = 'want2', save = 'autosave 3'}
  luahost.mkdir_recursive(W.rt .. '/region1-site97')
  H.write(W.rt .. '/region1-site97/events.jsonl',
    '{"cls":"C","d":{"boots":1,"save":"region1","v":2},"msg":"boot region1 #1","n":2,"tick":1,"type":"BOOT"}\n' ..
    '{"cls":"C","d":{"boots":2,"save":"r16b-ostgate","v":2},"msg":"boot r16b-ostgate #2","n":6,"tick":2,"type":"BOOT"}\n' ..
    '{"cls":"C","d":{"boots":3,"save":"autosave 2","v":2},"msg":"boot autosave 2 #3","n":9,"tick":3,"type":"BOOT"}\n' ..
    '{"cls":"B","d":{},"msg":"x","n":10,"tick":4,"type":"PAUSE"}\n')
  dfhack.persistent.saveSiteDataString('dfllm', json.encode(marker()))
  local ok, msg = H.boot(W, {modules = {}})
  T.ok(ok, msg)
  T.ok(msg:find('r16b-ostgate-site97', 1, true), msg)
  T.eq(H.read(W.rt .. '/ACTIVE'), 'r16b-ostgate-site97')
  kern.stop()
end)

T.test('BUG-386: the running kernel notes a player-named save folder in the marker once', function()
  H.world{tag = 'want3', save = 'region1'}
  dfhack.persistent.saveSiteDataString('dfllm', json.encode(marker()))
  local logs = {}
  local st = {marked = true, log_as = function(_, _, msg) logs[#logs + 1] = msg end}
  T.ok(not kern.note_player_save(st, 'autosave 2'), 'autosave: nothing')
  T.ok(not kern.note_player_save(st, 'region1'), 'the adopt folder: nothing')
  T.ok(kern.note_player_save(st, 'r16b-ostgate'))
  T.eq(json.decode(dfhack.persistent.getSiteDataString('dfllm')).want, 'r16b-ostgate')
  T.ok(not kern.note_player_save(st, 'r16b-ostgate'), 'noted once')
  T.eq(#logs, 1)
  T.ok(not kern.note_player_save({marked = false, log_as = function() end}, 'x'), 'unmarked: never')
end)

T.done()
