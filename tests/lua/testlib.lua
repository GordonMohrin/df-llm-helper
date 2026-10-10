-- Tiny test harness for tests/lua/test_*.lua (run by tools/luahost.py; tests/lua is on package.path).
--   local T = require('testlib')
--   T.test('name', function() T.eq(1 + 1, 2) end)
--   T.done()   -- prints the summary and exits 0 (all passed) or 1
local T = {passed = 0, failed = 0}

local function show(v, depth)
  depth = depth or 0
  if type(v) == 'string' then return string.format('%q', v) end
  if type(v) ~= 'table' then return tostring(v) end
  if depth > 3 then return '{...}' end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. '=' .. show(v[k], depth + 1) end
  return '{' .. table.concat(parts, ', ') .. '}'
end
T.show = show

-- deep equality; metatables are ignored
local function deq(a, b, path)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then
    if type(a) == 'number' and type(b) == 'number' and a == b then return true end
    return false, path .. ': ' .. show(a) .. ' ~= ' .. show(b)
  end
  for k, v in pairs(a) do
    local ok, why = deq(v, b[k], path .. '.' .. tostring(k))
    if not ok then return false, why end
  end
  for k, v in pairs(b) do
    if a[k] == nil then return false, path .. '.' .. tostring(k) .. ': missing, expected ' .. show(v) end
  end
  return true
end
T.deq = deq

function T.eq(actual, expected, msg)
  local ok, why = deq(actual, expected, '$')
  if not ok then error((msg and (msg .. ': ') or '') .. why, 2) end
end

function T.ok(v, msg)
  if not v then error(msg or 'expected truthy value', 2) end
end

function T.raises(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then error((msg or 'expected an error') .. (pattern and (' matching ' .. pattern) or ''), 2) end
  if pattern and not tostring(err):find(pattern) then
    error(string.format('error %q does not match %q', tostring(err), pattern), 2)
  end
  return err
end

function T.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    T.passed = T.passed + 1
    print('ok - ' .. name)
  else
    T.failed = T.failed + 1
    print('not ok - ' .. name .. '\n    ' .. tostring(err):gsub('\n', '\n    '))
  end
end

function T.done()
  print(string.format('# passed %d, failed %d', T.passed, T.failed))
  os.exit(T.failed == 0 and 0 or 1)
end

return T
