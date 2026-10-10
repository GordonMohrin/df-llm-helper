-- arbiter (WP1, critical, 500 ms): sole writer of pause, timestream fps and runtime settings
-- (DESIGN §3 actuator table, §10 runtime profile; CONTRACTS §9.13 restore.json).
--   * never pauses on its own; holds an inbox pause until its TTL; honours a pause by Gordon
--     (DECISION_NEEDED after 10 min); unpauses only whitelisted popups, which it dismisses.
--   * timestream fps from the mode table, lowered by inbox tempo.lower (TTL), applied idempotently.
--   * runtime profile at boot (originals to restore.json first), restored on unload; a restore.json
--     left active by a crash is healed first (also on unmarked saves, called by kern), see M.heal.
local json = require('dfllm.util.json')
local fio = require('dfllm.io')

local M = {name = 'arbiter', every = {ms = 500}, critical = true, on = {}, verbs = {}}

M.MODE_FPS = {PEACE = 500, ALERT = 250, SIEGE = -1, BREACH = -1, RECOVERY = 250, DRILL = -1}
M.PROFILE = {gfps = 30, autosave = 'YEARLY', overlays = true, visitor_cap = 30}
M.KEEP_OVERLAY = 'notify'          -- headless overlay profile keeps widgets whose name contains this
M.POPUPS = {}                      -- kind -> {plain text markers}: dismissed + unpaused [S8: fill from live]
M.ASK_AFTER_MS = 600000            -- foreign pause older than this -> DECISION_NEEDED
M.REASSERT_MS = 60000              -- re-check the live timestream fps at most this often
M.RETRY_MS = 30000                 -- back-off after a failed timestream write

local st = {}

local function int(v) return math.type(v) == 'integer' and v or math.tointeger(v) end

local function restore_path(K) return K.cfg.paths.runtime .. '/restore.json' end

local function live_fps()
  local ok, v = pcall(function() return require('plugins.timestream').timestream_getFps() end)
  if ok then return int(v) end
end

local function autosave_name()
  local v = df.global.d_init.feature.autosave
  if type(v) == 'number' and df.d_init_autosave then return df.d_init_autosave[v] end
  return v
end

local function ts_accepted(K)
  return tostring(K.cfg.decisions and K.cfg.decisions['D-11'] or 'accepted') == 'accepted'
end

-- prefs folders in the order DF uses them: dfhack.filesystem.getBaseDir() is the install folder in
-- portable mode, else SDL's pref dir (Steam: %APPDATA%/Bay 12 Games/Dwarf Fortress/), Lua API.txt:3053;
-- it ends in a separator (script-manager.lua:83 appends 'mods/'). The install folder is the fallback.
local function prefs_dirs(K)
  local dirs = {}
  local ok, base = pcall(function()
    local fs = dfhack.filesystem
    return fs.getBaseDir and fs.getBaseDir()
  end)
  if ok and type(base) == 'string' and base ~= '' then
    dirs[#dirs + 1] = {base:gsub('[/\\]+$', '') .. '/prefs', 'base dir'}
  end
  dirs[#dirs + 1] = {tostring(K.cfg.paths.df or '.'):gsub('[/\\]+$', '') .. '/prefs', 'install dir'}
  return dirs
end

-- [KEY:N] from the first prefs/<file> that has it (read only) -> value, source
local function prefs_int(K, file, key)
  for _, d in ipairs(prefs_dirs(K)) do
    local path = d[1] .. '/' .. file
    local s = fio.read(path)
    local v = s and s:match('%[' .. key .. ':([0-9]+)%]')
    if v then return math.tointeger(tonumber(v)), d[2] .. ' ' .. path end
  end
end

-- restore.json, mirrored into this save's persist (unless the doc belongs to another save)
local function write_restore(K, doc, no_mirror)
  doc.orig = json.object(doc.orig or {})
  if doc.orig.overlays then doc.orig.overlays = json.object(doc.orig.overlays) end
  local ok, err = fio.write(restore_path(K), json.encode(doc))
  if not ok then K.log('error', 'restore.json: %s', tostring(err)) end
  if not no_mirror then K.persist.set('restore', doc) end
end

local function restore_overlays(K, orig)
  if type(orig.overlays) ~= 'table' then return end
  local on = {}
  for name, en in pairs(orig.overlays) do if en then on[#on + 1] = name end end
  table.sort(on)
  if #on > 0 then K.act.overlay(on, true) end
end

-- unload / dfllm stop: the same session that changed the settings puts every original back
local function restore(K, orig)
  for _, k in ipairs({'gfps', 'autosave', 'visitor_cap', 'population_cap', 'weather'}) do
    if orig[k] ~= nil then K.act.setting(k, orig[k]) end
  end
  if orig.timestream_fps ~= nil then K.act.timestream(orig.timestream_fps) end
  restore_overlays(K, orig)
end

-- live value of each global the profile changes, and the value the profile writes
local LIVE = {
  gfps = function() return df.global.enabler.gfps end,
  autosave = autosave_name,
  visitor_cap = function() return df.global.d_init.dwarf.visitor_cap end,
  weather = function() return df.global.d_init.feature.flags.WEATHER == true end,
}
local function profile_value(k) if k == 'weather' then return false end return M.PROFILE[k] end

-- restore.json active:1 means the previous session ended without restoring (crash). The heal must
-- not push one fort's values onto another save:
--   * gfps/autosave/visitor_cap/weather only while the live value is still the profile value (after a
--     process crash DF has reloaded them from prefs, so there is nothing to undo);
--   * overlays always (dfhack-config/overlay.json survives a crash);
--   * timestream fps (per-save site data: timestream.plug.dll uses Add/GetPersistentSiteData) only
--     for the same, marked save, never via heal_only;
--   * the population cap never (pop-control writes it for the fort being loaded); the same save
--     carries it as its original (orig_popcap) in case no prefs file is readable.
-- opts.marked: the boot is a marked save (arbiter.init, dfllm restore on a marked save).
function M.heal(K, opts)
  local doc = fio.read_json(restore_path(K))
  if type(doc) ~= 'table' or doc.active ~= 1 then return false end
  local orig = type(doc.orig) == 'table' and doc.orig or {}
  local same = type(opts) == 'table' and opts.marked == true and doc.save == tostring(K.cfg.save or '')
  local done, skipped = {}, {}
  for _, k in ipairs({'gfps', 'autosave', 'visitor_cap', 'weather'}) do
    if orig[k] ~= nil then
      local ok, live = pcall(LIVE[k])
      if ok and live == profile_value(k) then
        K.act.setting(k, orig[k]); done[#done + 1] = k
      else skipped[#skipped + 1] = k end
    end
  end
  if orig.timestream_fps ~= nil then
    if same then K.act.timestream(orig.timestream_fps); done[#done + 1] = 'timestream_fps'
    else skipped[#skipped + 1] = 'timestream_fps' end
  end
  if orig.population_cap ~= nil then skipped[#skipped + 1] = 'population_cap' end   -- carried, see apply_profile
  if type(orig.overlays) == 'table' then restore_overlays(K, orig); done[#done + 1] = 'overlays' end
  if same then st.carry = orig end
  K.log('warn', 'restore.json still active (save %s, booting %s): restored %s; left %s', tostring(doc.save),
        tostring(K.cfg.save or '-'), #done > 0 and table.concat(done, ',') or 'none',
        #skipped > 0 and table.concat(skipped, ',') or 'none')
  doc.active, doc.wall = 0, os.time()
  write_restore(K, doc, not same)
  return true
end

-- the save's own timestream original: timestream persists its fps in the save, so after the first
-- session the live value is our mode value; the originals mirrored into this save win (DESIGN §10)
local function saved_ts_fps(K)
  if st.carry and math.type(st.carry.timestream_fps) == 'integer' then return st.carry.timestream_fps end
  local prev = K.persist.get('restore')
  local o = type(prev) == 'table' and type(prev.orig) == 'table' and prev.orig
  if o and math.type(o.timestream_fps) == 'integer' then return o.timestream_fps end
end

-- population cap original: prefs (base dir, then install dir), then the crashed session's original
-- (same save), then memory. pop-control's SC_MAP_LOADED hook may already have written this fort's
-- cap into d_init before we boot (pop-control.lua:28-40,82, repeat-util.lua:48 runs it at once).
local function orig_popcap(K)
  local v, src = prefs_int(K, 'd_init.txt', 'POPULATION_CAP')
  if not v and st.carry and math.type(st.carry.population_cap) == 'integer' then
    v, src = st.carry.population_cap, 'restore.json of the crashed session'
  end
  if not v then v, src = df.global.d_init.dwarf.population_cap, 'memory (no prefs file; may be pop-control\'s)' end
  K.log('info', 'population cap original %s from %s', tostring(v), src)
  return v
end

-- capture originals (written before the first change), then apply the profile
local function apply_profile(K)
  local g, P = df.global, M.PROFILE
  local d07 = tostring(K.cfg.decisions and K.cfg.decisions['D-07'] or 'unchanged')
  local visitor = P.visitor_cap and d07:find('visitor', 1, true) ~= nil
  local weather_off = d07:find('weather', 1, true) ~= nil
  local ts_fps = ts_accepted(K) and (saved_ts_fps(K) or live_fps()) or nil
  local orig = {gfps = g.enabler.gfps, autosave = autosave_name(), timestream_fps = ts_fps,
                population_cap = orig_popcap(K)}
  if visitor then orig.visitor_cap = g.d_init.dwarf.visitor_cap end
  if weather_off then
    local ok, on = pcall(function() return g.d_init.feature.flags.WEATHER == true end)
    if ok then orig.weather = on else weather_off = false end
  end
  local ov_off = {}
  if P.overlays then
    local ok, ov = pcall(require, 'plugins.overlay')
    local s = ok and type(ov) == 'table' and ov.get_state and ov.get_state()
    if s then
      for _, name in ipairs(s.index or {}) do
        local c = s.config and s.config[name]
        if c and c.enabled and not name:find(M.KEEP_OVERLAY, 1, true) then ov_off[#ov_off + 1] = name end
      end
    end
    if #ov_off > 0 then
      orig.overlays = {}
      for _, n in ipairs(ov_off) do orig.overlays[n] = true end
    end
  end
  st.orig = orig
  write_restore(K, {v = 2, save = tostring(K.cfg.save or ''), wall = os.time(), active = 1, orig = orig})
  if P.gfps then K.act.setting('gfps', P.gfps) end
  if P.autosave then K.act.setting('autosave', P.autosave) end
  if visitor then K.act.setting('visitor_cap', P.visitor_cap) end
  if weather_off then K.act.setting('weather', false) end
  if #ov_off > 0 then K.act.overlay(ov_off, false) end
end

---------------------------------------------------------------- tempo
local function desired(K)
  local base = M.MODE_FPS[K.mode()] or 250
  local t = st.tempo
  if t and K.now().ms >= t.until_ms then st.tempo, t = nil, nil end
  if t and base > 0 and t.fps < base then return t.fps, 'inbox' end
  return base, 'mode'
end

-- idempotent: write timestream only when the desired value changed (or the live value drifted);
-- nothing at all unless Gordon's D-11 (timestream) is 'accepted' (the default)
function M.apply(K)
  if not ts_accepted(K) then return false end
  local now = K.now()
  local fps, by = desired(K)
  st.tempo_by = by
  if st.applied == fps then
    if now.ms - (st.checked_ms or 0) < M.REASSERT_MS then return true end
    st.checked_ms = now.ms
    local live = live_fps()
    if live == nil or live == fps then return true end
  elseif st.fail_until and now.ms < st.fail_until and st.fail_fps == fps then
    return false
  end
  local ok = K.act.timestream(fps)
  if ok then st.applied, st.checked_ms, st.fail_until = fps, now.ms, nil
  else st.fail_until, st.fail_fps = now.ms + M.RETRY_MS, fps end
  return ok
end

-- WP1-internal (perf, via K.call): the desired timestream fps and its owner ('mode' or 'inbox');
-- nil, 'off' when D-11 leaves timestream alone
function M.target(K)
  if not ts_accepted(K) then return nil, 'off' end
  return desired(K)
end

---------------------------------------------------------------- pause
local function popup_count()
  local ok, n = pcall(function() return #df.global.world.status.popups end)
  return ok and n or 0
end

local function popup_kind()
  local ok, text = pcall(function() return dfhack.df2utf(df.global.world.status.popups[0].text) end)
  if not ok or type(text) ~= 'string' then return nil end
  for kind, marks in pairs(M.POPUPS) do
    for _, m in ipairs(marks) do if text:find(m, 1, true) then return kind end end
  end
end

local function pause_event(K, on, by, ttl)
  local d = {on = on and 1 or 0, by = by}
  if ttl then d.ttl = ttl end
  K.emit('PAUSE', 'B', (on and 'paused by ' or 'unpaused, was ') .. by, d)
end

-- pause transitions: a pause we did not cause is foreign (a popup's or Gordon's) and ends our hold,
-- so a TTL expiry can never unpause somebody else's pause
local function observe(K)
  local paused = df.global.pause_state == true
  if paused and not st.pause_by then
    st.pause_by, st.pause_since, st.asked = (popup_count() > 0) and 'popup' or 'gordon', K.now().ms, false
    st.hold = nil
    pause_event(K, true, st.pause_by)
  elseif not paused and st.pause_by then
    pause_event(K, false, st.pause_by)
    st.pause_by = nil
  end
  return paused
end

local function track_pause(K)
  local now = K.now()
  if st.hold and now.ms >= st.hold.until_ms then
    st.hold = nil
    if df.global.pause_state == true and st.pause_by == 'inbox' then K.act.set_paused(false) end
  end
  if not observe(K) then return end
  if st.pause_by == 'popup' then
    local kind = popup_kind()
    if kind and K.act.dismiss_popup(kind) and popup_count() == 0 then K.act.set_paused(false) end
  end
  if st.pause_by ~= 'inbox' and not st.asked and now.ms - st.pause_since >= M.ASK_AFTER_MS then
    st.asked = true
    K.emit('DECISION_NEEDED', 'A', 'game paused by ' .. st.pause_by .. ' for 10 min',
           {id = 'pause', q = 'paused by ' .. st.pause_by .. '; Gordon unpauses in DF (the inbox cannot release it)'})
  end
end

---------------------------------------------------------------- module
function M.init(K)
  st = {}
  M.heal(K, {marked = true})
  local ok, err = pcall(apply_profile, K)
  if not ok then K.log('error', 'runtime profile: %s', tostring(err)) end
  M.apply(K)
  if df.global.pause_state == true then     -- DF loads saves paused: owner 'df', released in DF only (§13)
    st.pause_by, st.pause_since, st.asked = 'df', K.now().ms, false
    pause_event(K, true, 'df')
  end
end

function M.step(K)
  track_pause(K)
  M.apply(K)
end

function M.on.MODE(K, ev) M.apply(K) end

function M.on.UNLOAD(K)
  if st.orig then
    restore(K, st.orig)
    write_restore(K, {v = 2, save = tostring(K.cfg.save or ''), wall = os.time(), active = 0, orig = st.orig})
  end
end

function M.state(K)
  return {owners = {pause = st.pause_by or json.null, tempo = st.tempo_by or 'mode'}}
end

M.verbs['tempo.lower'] = function(K, args, cmd)
  local fps, ttl = int(args.fps), int(args.ttl_s)
  if not fps or fps < 10 or fps > 1000 or not ttl or ttl < 1 or ttl > 3600 then
    return false, 'need fps 10..1000 and ttl_s 1..3600'
  end
  st.tempo = {fps = fps, until_ms = K.now().ms + ttl * 1000}
  M.apply(K)
  local base = M.MODE_FPS[K.mode()] or 250
  if base < 0 then return true, 'timestream is off in ' .. K.mode() .. '; nothing to lower' end
  return true, string.format('tempo %d for %d s', math.min(fps, base), ttl)
end

M.verbs.pause = function(K, args, cmd)
  local ttl = int(args.ttl_s)
  if not ttl or ttl < 1 or ttl > 600 then return false, 'ttl_s must be 1..600' end
  local now = K.now()
  local paused = observe(K)
  if paused and st.pause_by ~= 'inbox' then return true, 'already paused by ' .. st.pause_by end
  st.hold = {until_ms = now.ms + ttl * 1000, by = cmd and cmd.by}
  if not paused then
    local ok, err = K.act.set_paused(true)
    if not ok then st.hold = nil; return false, 'pause failed: ' .. tostring(err) end
  end
  if st.pause_by ~= 'inbox' then
    st.pause_by, st.pause_since, st.asked = 'inbox', now.ms, false
    pause_event(K, true, 'inbox', ttl)
  end
  return true, string.format('paused for %d s', ttl)
end

-- CONTRACTS §13 (R6): `by` is a label, so the inbox releases only its own hold; a pause owned by
-- gordon, df (a save loaded paused) or a popup is released in the game, whatever `by` says
M.verbs.unpause = function(K, args, cmd)
  local paused = observe(K)
  if not paused then st.hold = nil; return true, 'not paused' end
  local by = st.pause_by or 'gordon'
  if by ~= 'inbox' then
    return false, 'paused by ' .. by .. '; the inbox releases only its own pause (unpause in DF)'
  end
  st.hold = nil
  local ok, err = K.act.set_paused(false)
  if not ok then return false, 'unpause failed: ' .. tostring(err) end
  pause_event(K, false, by)
  st.pause_by = nil
  return true, 'unpaused'
end

return M
