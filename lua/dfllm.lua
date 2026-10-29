-- dfllm: dfpilot v2 kernel entry (DESIGN §7, CONTRACTS §3.1, §3.5).
--   dfllm boot                      start the kernel (onMapLoad.init); a no-op on saves without the marker
--   dfllm adopt [--acceptance]      mark this fort as dfllm-managed (once), load plans/year1.json, boot
--   dfllm stop [--restore-fps]      unload the kernel (restores runtime settings; FR-68: in SIEGE/BREACH/ALERT or a
--                                   lockdown the FPS cap and timestream stay and the guard `dfllm-guard` dismisses
--                                   blocking popups until boot/reload/restore; --restore-fps restores everything)
--   dfllm reload                    stop, drop the cached dfllm modules, boot the code on disk (not on acceptance saves)
--   dfllm status                    one-screen summary
--   dfllm selftest [quick|full] [--mock] [--exec FILE]
--   dfllm restore                   restore runtime settings from dfllm-runtime/restore.json (ends the stop guard)

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
  if not kern.running() and has('--restore-fps') then say(kern.restore{repo = repo})   -- release a stop guard
  else say(kern.stop('stop', {restore_fps = has('--restore-fps')})) end
elseif cmd == 'reload' then
  -- live engineering: stop, drop every cached dfllm module, boot the code on disk (persist is flushed
  -- by stop, so nothing is lost). Refused on acceptance saves.
  local K = kern.K()
  if K and K.cfg and K.cfg.acceptance then say(false, 'reload refused: acceptance save'); return end
  kern.stop('reload')
  for k in pairs(package.loaded) do
    if k:match('^dfllm%.') then package.loaded[k] = nil end
  end
  say(require('dfllm.kern').boot{repo = repo})
elseif cmd == 'restore' then
  say(kern.restore{repo = repo})
elseif cmd == 'status' then
  local s = kern.status()
  if not s then
    local g = require('dfllm.guard').active()
    -- BUG-120 (Run 14 note 99): no map is no fort: the title screen has no cached numbers to show
    local okm, map = pcall(function() return dfhack.isMapLoaded() end)
    if okm and map == false then print('dfllm: DF at title screen: no fort loaded (kernel not running)'); return end
    print('dfllm: kernel not running' .. (g and ('; stop guard on: ' .. g.text .. (g.err and (' (error: ' .. g.err .. ')')
          or '') .. '; dfllm boot resumes, dfllm restore releases the clock') or ''))
    return
  end
  print(string.format('dfllm %s  mode %s  seq %d  ev %d  boots %d  frame %d', s.save, s.mode, s.seq, s.ev,
                      s.boots or 0, s.frame))
  print(string.format('  kernel %d ms/s (budget %d)  %d ticks/s  max gap %d ms  frame faults %d  dropped events %d',
                      s.ms_s, s.budget or 25, s.tps, s.gap_max_ms, s.kern_faults, s.dropped))
  -- BUG-161 (live round 2, i3: 'load x8,89'): DF's LC_NUMERIC is the player's locale; NUM writes a '.'
  local NUM = require('dfllm.util.num')
  if s.load then
    print(string.format('  fort size: %d units, %d items, load x%s', s.load.units, s.load.items,
                        NUM.dec(s.load.f_pct / 100, 2)))
  end
  for _, m in ipairs(s.modules) do
    print(string.format('  %-10s %s  x%d  %d ms  %d faults%s', m.name, m.disabled and 'DISABLED' or 'ok',
                        m.factor, m.ms, m.faults,
                        (m.paced or 0) > 0 and string.format('  paced %d (share %s ms/s)', m.paced, NUM.num(m.share))
                        or ''))
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
                      #r.failed > 0 and ('(' .. (r.detail and st.describe(r) or table.concat(r.failed, ', ')) .. ')') or ''))
else
  print('usage: dfllm boot | adopt [--acceptance] | stop [--restore-fps] | reload | status | selftest [quick|full] [--mock] [--exec FILE] | restore')
end
