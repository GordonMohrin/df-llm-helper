-- Helper for tests/test_schema.py (not a test itself): runs the Lua side of the shared vectors.
--   contract_probe.lua <in.json>   in = {state = [doc], decisions = [text]}
-- The string NULL_MARK stands for JSON null (util/json drops null object members on decode).
-- Prints {state = [[error path]], decisions = [map], kern = [map] | null, kern_err = str}.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local NULL_MARK = '\0null'
local function restore(v)
  if v == NULL_MARK then return json.null end
  if type(v) ~= 'table' then return v end
  for k, x in pairs(v) do v[k] = restore(x) end
  return v
end

local f = assert(io.open(arg[1], 'rb'))
local input = json.decode(f:read('a'))
f:close()

local out = {state = {}, decisions = {}, kern = json.null, kern_err = ''}
for i, doc in ipairs(input.state or {}) do
  local paths, seen = {}, {}
  for _, e in ipairs(C.check_state(restore(doc))) do
    local p = e:match('^(.-): ')
    if p and not seen[p] then seen[p] = true; paths[#paths + 1] = p end
  end
  table.sort(paths)
  out.state[i] = json.array(paths)
end
for i, text in ipairs(input.decisions or {}) do out.decisions[i] = json.object(C.parse_decisions(text)) end

-- the kernel's own reader, when kern.lua loads offline (WP1 must delegate to C.parse_decisions)
require('dfllm.util.k_mock').new{}
local ok, kern = pcall(require, 'dfllm.kern')
if ok and type(kern) == 'table' and type(kern.parse_decisions) == 'function' then
  out.kern = {}
  for i, text in ipairs(input.decisions or {}) do out.kern[i] = json.object(kern.parse_decisions(text)) end
else
  out.kern_err = tostring(kern)
end
print(json.encode(out))
