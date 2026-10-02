-- claude/pilot_wd mode <work_detail> <EverybodyDoesThis|OnlySelectedDoesThis|NobodyDoesThis> [--apply]
-- df-llm-helper, runbook rb02_grabstau. NOT TESTED LIVE (checked in the cloud against a mock DFHack only).
-- Corresponds in the game to: labor -> work details -> group -> mode. Without --apply display only (dry run).
-- Installation: copy to hack/scripts/claude/pilot_wd.lua (see docs/INTEGRATION.md).
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local apply = false
for _, x in ipairs(a) do if x == '--apply' then apply = true end end
local cmd, name, mode = a[1], a[2], a[3]
local M = df.work_detail_mode

if cmd ~= 'mode' or not name or not mode or M[mode] == nil then
  util.emit({ error = 'Usage: claude/pilot_wd mode <work_detail> <EverybodyDoesThis|OnlySelectedDoesThis|NobodyDoesThis> [--apply]' })
  return
end

local wds = df.global.plotinfo.labor_info.work_details
local d
for i = 0, #wds - 1 do if wds[i].name == name then d = wds[i] end end
if not d then util.emit({ error = 'no work detail "' .. tostring(name) .. '"' }) return end

local before = M[d.flags.mode]
if apply and before ~= mode then d.flags.mode = M[mode] end
util.emit({ name = name, before = before, after = apply and mode or before, applied = apply, dry = not apply })
