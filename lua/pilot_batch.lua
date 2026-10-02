-- claude/pilot_batch <request.json>   (df-llm-helper F10, NOT TESTED LIVE: checked in the cloud against a mock DFHack only)
-- Runs several DFHack commands in ONE dfhack-run session and returns a JSON list:
--   Input (file): {"cmds": [["claude/status"], ["claude/mil", "tabelle"], ...], "max_bytes": 20000}
--   Output (stdout, JSON list; DFHack's encoder may pretty-print it over several lines): [{"ok": true, "out": "..."}, {"ok": false, "out": "...", "err": "..."}, ...]
-- An error in one sub-command does not stop the others (pcall per command).
-- Fair play: df-llm-helper checks every sub-command BEFORE writing the request (fairplay.check_command + linter).
local json = require('json')

local path = ({ ... })[1]
if not path then print(json.encode({ { ok = false, out = '', err = 'Usage: claude/pilot_batch <request.json>' } })) return end
local f = io.open(path, 'r')
if not f then print(json.encode({ { ok = false, out = '', err = 'Request not readable: ' .. path } })) return end
local raw = f:read('*a')
f:close()
raw = raw:gsub('^\239\187\191', '')   -- UTF-8 BOM (PowerShell Set-Content / >) is not part of the JSON
local okd, req = pcall(json.decode, raw)
if not okd or type(req) ~= 'table' or type(req.cmds) ~= 'table' then
  print(json.encode({ { ok = false, out = '', err = 'Request is not valid JSON' } }))
  return
end
local max_bytes = math.max(0, math.floor(tonumber(req.max_bytes) or 20000))

-- Cut at most max_bytes without splitting a UTF-8 character (the answer must stay valid UTF-8).
local function cut_utf8(s, n)
  local c = n
  while c > 0 do
    local b = s:byte(c + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end   -- the byte after the cut starts a character
    c = c - 1
  end
  return s:sub(1, c)
end

local results = {}
for i, parts in ipairs(req.cmds) do
  local r = {}
  local valid = type(parts) == 'table' and #parts > 0
  if valid then
    for _, p in ipairs(parts) do if type(p) ~= 'string' and type(p) ~= 'number' then valid = false end end
  end
  if not valid then
    r.ok, r.out, r.err = false, '', 'entry is not a list of strings'
  else
    -- table.unpack inside the protected call: a broken entry must not stop the other entries
    local okc, out, status = pcall(function() return dfhack.run_command_silent(table.unpack(parts)) end)
    if not okc then
      r.ok, r.out, r.err = false, '', tostring(out)
    else
      out = out or ''
      if #out > max_bytes then out = cut_utf8(out, max_bytes) .. '\n... truncated (' .. #out .. ' Bytes)' end
      r.ok = (status == nil) or (status == 0) or (status == CR_OK)
      r.out = out
      if not r.ok then r.err = 'Status ' .. tostring(status) end
    end
  end
  results[i] = r
end
print(json.encode(results))
