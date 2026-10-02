-- claude/pilot_batch <request.json>   (dfpilot F10, NOT TESTED LIVE: checked in the cloud against a mock DFHack only)
-- Runs several DFHack commands in ONE dfhack-run session and returns a JSON list:
--   Input (file): {"cmds": [["claude/status"], ["claude/mil", "tabelle"], ...], "max_bytes": 20000}
--   Output (stdout, one line): [{"ok": true, "out": "..."}, {"ok": false, "out": "...", "err": "..."}, ...]
-- An error in one sub-command does not stop the others (pcall per command).
-- Fair play: dfpilot checks every sub-command BEFORE writing the request (fairplay.check_command + linter).
local json = require('json')

local path = ({ ... })[1]
if not path then print(json.encode({ { ok = false, out = '', err = 'Usage: claude/pilot_batch <request.json>' } })) return end
local f = io.open(path, 'r')
if not f then print(json.encode({ { ok = false, out = '', err = 'Request not readable: ' .. path } })) return end
local raw = f:read('*a')
f:close()
local okd, req = pcall(json.decode, raw)
if not okd or type(req) ~= 'table' or type(req.cmds) ~= 'table' then
  print(json.encode({ { ok = false, out = '', err = 'Request is not valid JSON' } }))
  return
end
local max_bytes = tonumber(req.max_bytes) or 20000

local results = {}
for i, parts in ipairs(req.cmds) do
  local okc, out, status = pcall(dfhack.run_command_silent, table.unpack(parts))
  local r = {}
  if not okc then
    r.ok, r.out, r.err = false, '', tostring(out)
  else
    out = out or ''
    if #out > max_bytes then out = out:sub(1, max_bytes) .. '\n... truncated (' .. #out .. ' Bytes)' end
    r.ok = (status == nil) or (status == 0) or (status == CR_OK)
    r.out = out
    if not r.ok then r.err = 'Status ' .. tostring(status) end
  end
  results[i] = r
end
print(json.encode(results))
