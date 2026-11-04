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

T.test('save_root: getBaseDir first; getSavePath (trailing separator, backslashes) fallback; nil without either', function()
  local old_sp = dfhack.getSavePath
  local old_fs = dfhack.filesystem
  dfhack.filesystem = {}
  dfhack.getSavePath = function() return 'E:\\DF-test2\\save\\r15-guildcleans\\' end
  T.eq(kern.save_root(), 'E:\\DF-test2\\save')
  dfhack.getSavePath = function() return nil end
  dfhack.filesystem = {getBaseDir = function() return 'E:/DF-test4/' end}
  T.eq(kern.save_root(), 'E:/DF-test4/save')
  dfhack.filesystem = {}
  T.eq(kern.save_root(), nil)
  dfhack.getSavePath, dfhack.filesystem = old_sp, old_fs
end)

-- BUG-332 review fix: DFHack's getSavePath() is always getDFPath() .. '/save/' .. save_dir (hack/lua/dfhack.lua:1206),
-- also in a non-portable install whose saves go to getBaseDir() (SDL's pref dir, %APPDATA%/Bay 12 Games/Dwarf Fortress/).
T.test('save_root: non-portable install, getSavePath at <df>/save but getBaseDir at AppData -> the AppData save folder', function()
  local old_sp = dfhack.getSavePath
  local old_fs = dfhack.filesystem
  dfhack.getSavePath = function() return 'C:/Steam/Dwarf Fortress/save/autosave 1' end
  dfhack.filesystem = {getBaseDir = function()
    return 'C:\\Users\\x\\AppData\\Roaming\\Bay 12 Games\\Dwarf Fortress\\' end}
  T.eq(kern.save_root(), 'C:\\Users\\x\\AppData\\Roaming\\Bay 12 Games\\Dwarf Fortress/save')
  dfhack.getSavePath, dfhack.filesystem = old_sp, old_fs
end)

T.done()
