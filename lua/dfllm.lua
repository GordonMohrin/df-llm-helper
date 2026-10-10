-- dfllm: df-llm-helper v2 kernel entry (DESIGN §7, CONTRACTS §3.1, §3.5).
--   dfllm boot                      start the kernel (onMapLoad.init); a no-op on saves without the marker
--   dfllm adopt [--acceptance]      mark this fort as dfllm-managed (once), load plans/year1.json, boot
--   dfllm stop                      unload the kernel (restores runtime settings)
--   dfllm status                    one-screen summary
--   dfllm selftest [quick|full] [--mock] [--exec FILE]
--   dfllm restore                   restore runtime settings from dfllm-runtime/restore.json

-- put <repo>/lua on package.path so plain require('dfllm.<name>') works (CONTRACTS §3.1)
local function setup_path()
  local me = dfhack.findScript('dfllm')               -- dfhack.lua:987
  if not me then return '.' end
  local dir = me:gsub('[/\\]dfllm%.lua$', '')
  local entry = dir .. '/?.lua'
  if not package.path:find(entry, 1, true) then package.path = entry .. ';' .. package.path end
  return (dir:gsub('[/\\][^/\\]+$', ''))
end

local repo = setup_path()
local kern = require('dfllm.kern')
local args = {...}
local cmd = args[1] or 'help'

local function has(flag)
  for i = 2, #args do if args[i] == flag then return true end end
  return false
end

local function say(ok, msg) print('dfllm: ' .. tostring(msg)); return ok end

if cmd == 'boot' then
  say(kern.boot{repo = repo})
elseif cmd == 'adopt' then
  say(kern.adopt{repo = repo, acceptance = has('--acceptance')})
elseif cmd == 'stop' then
  say(kern.stop('stop'))
elseif cmd == 'restore' then
  say(kern.restore{repo = repo})
elseif cmd == 'status' then
  local s = kern.status()
  if not s then print('dfllm: kernel not running'); return end
  print(string.format('dfllm %s  mode %s  seq %d  ev %d  boots %d  frame %d', s.save, s.mode, s.seq, s.ev,
                      s.boots or 0, s.frame))
  print(string.format('  kernel %d ms/s  %d ticks/s  max gap %d ms  frame faults %d  dropped events %d',
                      s.ms_s, s.tps, s.gap_max_ms, s.kern_faults, s.dropped))
  for _, m in ipairs(s.modules) do
    print(string.format('  %-10s %s  x%d  %d ms  %d faults', m.name, m.disabled and 'DISABLED' or 'ok',
                        m.factor, m.ms, m.faults))
  end
  print('  runtime: ' .. tostring(s.runtime))
elseif cmd == 'selftest' then
  local st = require('dfllm.selftest')
  local r
  if has('--mock') then
    r = st.mock_check()
  else
    local K = kern.K()
    if not K then print('dfllm: kernel not running'); return end
    if has('--exec') then
      local file
      for i = 2, #args do if args[i] == '--exec' then file = args[i + 1] end end
      say(st.exec(K, file))
      return
    end
    r = st.run(K, args[2] == 'full' and 'full' or 'quick')
  end
  print(string.format('dfllm selftest: %d pass, %d fail %s', r.pass, r.fail,
                      #r.failed > 0 and ('(' .. table.concat(r.failed, ', ') .. ')') or ''))
else
  print('usage: dfllm boot | adopt [--acceptance] | stop | status | selftest [quick|full] [--mock] [--exec FILE] | restore')
end
