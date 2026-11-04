-- BUG-332 (Run 15 i2/i4 29.10.: `dfllm save` said QUICKSAVE_FAILED while DF in portable mode had written 'autosave 1'
-- to <DF>/save; the Python scan looked in %APPDATA%): the kernel writes DF's own save folder (the parent of
-- dfhack.getSavePath()) to <runtime>/SAVEDIR at boot, which supervise.saves_root reads.
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')

T.test('boot writes SAVEDIR = the parent of dfhack.getSavePath()', function()
  local W = H.world{tag = 'savedir'}
  local ok, msg = H.boot(W, {modules = {H.counter('test_a', {ticks = 10})}})
  T.ok(ok, msg)
  T.eq(H.read(W.rt .. '/SAVEDIR'), W.dfpath .. '/save')
  kern.stop()
end)

T.test('save_root: getSavePath with a trailing separator, backslashes; getBaseDir fallback; nil without either', function()
  local old_sp = dfhack.getSavePath
  local old_fs = dfhack.filesystem
  dfhack.getSavePath = function() return 'E:\\DF-test2\\save\\r15-guildcleans\\' end
  T.eq(kern.save_root(), 'E:\\DF-test2\\save')
  dfhack.getSavePath = function() return nil end
  dfhack.filesystem = {getBaseDir = function() return 'E:/DF-test4/' end}
  T.eq(kern.save_root(), 'E:/DF-test4/save')
  dfhack.filesystem = {}
  T.eq(kern.save_root(), nil)
  dfhack.getSavePath, dfhack.filesystem = old_sp, old_fs
end)

T.done()
