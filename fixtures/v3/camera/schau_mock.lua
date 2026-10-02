-- SYNTHETIC test harness (not live data): loads lua/claude/schau.lua as a module with a minimal DFHack stub and
-- checks the profile hook (spec v3-10). Usage:
--   MOCK_HOME=<dir with tools/schau_profile.json> lua5.4 schau_mock.lua lua/claude/schau.lua <job|-|=soldier> ...
-- Prints 'LOAD <ok> <name|error>', then per argument 'W <job> <weight> <cat>' ('-' = no job, '=soldier' = soldier
-- without a job), then 'STATUS <profile>'.
local function decode(str)
  local pos = 1
  local function ws() pos = str:find('[^%s]', pos) or #str + 1 end
  local val
  local function strv()
    local out, i = {}, pos + 1
    while true do
      local c = str:sub(i, i)
      if c == '"' then pos = i + 1 return table.concat(out) end
      if c == '\\' then out[#out + 1] = str:sub(i + 1, i + 1) i = i + 2
      elseif c == '' then error('string without end')
      else out[#out + 1] = c i = i + 1 end
    end
  end
  function val()
    ws()
    local c = str:sub(pos, pos)
    if c == '{' then
      local t = {} pos = pos + 1 ws()
      if str:sub(pos, pos) == '}' then pos = pos + 1 return t end
      while true do
        ws() local k = strv() ws() pos = pos + 1
        t[k] = val() ws()
        local d = str:sub(pos, pos) pos = pos + 1
        if d == '}' then return t end
      end
    elseif c == '[' then
      local t = {} pos = pos + 1 ws()
      if str:sub(pos, pos) == ']' then pos = pos + 1 return t end
      while true do
        t[#t + 1] = val() ws()
        local d = str:sub(pos, pos) pos = pos + 1
        if d == ']' then return t end
      end
    elseif c == '"' then return strv()
    elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
    elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
    elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
    else
      local num = str:match('^-?%d+%.?%d*', pos)
      pos = pos + #num
      return tonumber(num)
    end
  end
  return val()
end


local HOME = os.getenv('MOCK_HOME') or '.'
dfhack_flags = { module = true }
package.preload['repeat-util'] = function() return { scheduleEvery = function() end, cancel = function() end } end
package.preload['plugins.overlay'] = function() return { OverlayWidget = {} } end
package.preload['gui'] = function() return {} end
package.preload['json'] = function() return { decode = decode } end
function defclass(_, parent) return setmetatable({ ATTRS = function() end }, { __index = parent }) end
df = { global = { plotinfo = { follow_unit = -1 } } }
dfhack = { getTickCount = function() return 1000 end }
function reqscript(name)
  if name == 'claude/util' then return { home = function() return HOME end } end
  error('reqscript ' .. name)
end
assert(loadfile(arg[1]))()
local ok, r = load_profile()
print('LOAD ' .. tostring(ok) .. ' ' .. tostring(r))
for i = 2, #arg do
  local job, soldier = arg[i], false
  if job == '-' then job = nil elseif job == '=soldier' then job, soldier = nil, true end
  local w, c = weight_for(job, soldier)
  print('W ' .. arg[i] .. ' ' .. string.format('%.4f', w) .. ' ' .. tostring(c))
end
clear_profile()
print('STATUS ' .. ((CLAUDE_SCHAU.profile and 'loaded') or 'builtin'))
