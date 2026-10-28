-- arbiter (WP1, critical, 500 ms): sole writer of pause, timestream fps and runtime settings
-- (DESIGN §3 actuator table, §10 runtime profile; CONTRACTS §9.13 restore.json).
--   * never pauses on its own; holds an inbox pause until its TTL; honours a pause by Gordon
--     (DECISION_NEEDED after 10 min); unpauses only whitelisted popups, which it dismisses.
--   * timestream fps from the mode table, lowered by inbox tempo.lower (TTL), applied idempotently.
--   * supply brake (live L1: a year idled at 500 ticks/s, two dwarves died of hunger and thirst): while
--     the fort is in phase P0 or economy.alarm() reports a supply problem, tempo and the vanilla FPS cap
--     are held at BRAKE_FPS (timestream alone never slows DF below its own frame rate); the original
--     cap is captured in restore.json and put back when the brake ends and on unload.
--   * runtime profile at boot (originals to restore.json first), restored on unload; a restore.json
--     left active by a crash is healed first (also on unmarked saves, called by kern), see M.heal.
--   * clock governor (FR-51, Run 9: 39 of 48 citizens died within 76 s at ~400 ticks/s while timestream was "off"
--     in SIEGE, because the vanilla FPS cap stayed at the prefs' 500): the FPS cap also follows the mode
--     (SIEGE/BREACH/DRILL the siege cap, default 30; ALERT the alert cap, default 100; PEACE/RECOVERY the captured
--     original), and while the reflex module holds a lockdown (an arrival announcement, INVASION or the first armed
--     hostile in sight, until threat 0 for N game days) timestream goes off and the cap holds at the siege cap.
--     Timestream never runs above the cap it is meant to slow (it cannot slow below DF's frame rate): a timestream
--     target above the cap is switched off. Same restore.json mechanism as the supply brake. Knobs: config/reflex.json
--     `clock` (K.cfg.reflex). tempo.lower lowers the cap too (STATUS §6 gap 10).
--   * trade clamp (BUG-026, Run 10: a caravan visit was lost to a ui_timeout at 270-390 ticks/s): while trade.clock()
--     names a reason (from the first trade-screen phase of a visit until the visit ends: traded, failed, left), the FPS
--     cap holds at clock.trade_cap (default 100; timestream above it goes off), never above the captured original.
local json = require('dfllm.util.json')
local fio = require('dfllm.io')
local VL = require('dfllm.viewlib')     -- FR-88: the verb `view` (the camera)

local M = {name = 'arbiter', every = {ms = 500}, critical = true, on = {}, verbs = {}}

M.MODE_FPS = {PEACE = 500, ALERT = 250, SIEGE = -1, BREACH = -1, RECOVERY = 250, DRILL = -1}
M.CLOCK = {siege_cap = 30, alert_cap = 100,   -- FR-51 defaults; config/reflex.json `clock` overrides them
           trade_cap = 100}                   -- BUG-026: while trade holds the clock (trade.clock)
M.MODE_CAP = {SIEGE = 'siege_cap', BREACH = 'siege_cap', DRILL = 'siege_cap', ALERT = 'alert_cap'}
M.BRAKE_FPS = 150                  -- tempo and FPS cap while the supply brake holds
M.P0_SAFE_DAYS = 60                -- P0 brakes only while drink or food is below this
M.PROFILE = {gfps = 30, autosave = 'YEARLY', overlays = false, visitor_cap = 30}
M.KEEP_OVERLAY = 'notify'          -- headless overlay profile keeps widgets whose name contains this
-- kind -> {plain text markers}: dismissed + unpaused. Live L0 (DF 53.16): an announcement popup
-- (world.status.popups) halts the game while pause_state stays false; the only one seen so far is
-- "Some migrants have arrived." (it froze the fort for minutes until it was clicked away), then
-- "A caravan from <civ> has arrived. ...", "The merchants need a trade depot ..." and "The merchants
-- from <civ> will be leaving soon.". Informational popups only; threat popups are M.THREAT_POPUPS (FR-36).
M.POPUPS = {migrants = {'migrants have arrived', 'migrant has arrived'},
            -- live L4: "A human caravan from Muboomon has arrived.  Overall trade sentiments are cautious." halted the fort
            caravan = {'caravan from', 'merchants need a trade depot', 'merchants have arrived',
                       'The merchants from'},
            diplomacy = {'diplomat could not complete a meeting', 'diplomat has arrived', 'liaison has arrived'},
            guild = {'has been established'},
            -- the embark intro ("... Strike the earth!") is never dismissed here: erasing it left Perplexrooms
            -- (live L6) a fort where nobody ever took a job; tools/embark clicks its Okay (S.intro)
            -- live L6: "A raccoon has stolen a (steel battle axe)!" halted the fort (vermin thief; nothing to decide)
            theft = {'has stolen'},
            -- live L6: cavern/pit discovery notices halted the fort; the runner already reacts to FEATURE_DISCOVERY
            discovery = {'You have discovered'},
            ghost = {'has been put to rest'},
            -- deaths are recorded by care (DEATH, DEATHS_3PLUS wakes); the notice alone must not halt the fort
            -- live L2: "<name> has bled to death." halted the fort after a berserk citizen was killed
            death = {'has been found dead', 'has bled to death', 'has been struck down', 'has died of thirst',
                     'has starved to death', 'has drowned', 'has suffocated', 'has died after', 'has been crushed',
                     'has been killed', 'has died from',
                     -- live L7 (Paddletribes): "<name>, Ghostly Tanner has been murdered by <name>!" froze the fort
                     'has been murdered', 'has been slain', 'has been executed',
                     -- live L7: "<name>, Thresher has been found, starved to death." (comma form) halted the fort
                     'starved to death', 'died of thirst', 'has been found, '},
            -- live L1b: a tantrum popup halted the fort; care samples stress, the dwarves deal with it
            stress = {'is throwing a tantrum'},
            -- live L1b: "<name> has claimed a Stoneworker's Workshop." halted the fort mid-mood; care tracks
            -- moods (MOOD_START/NEED/END) and frees the materials
            mood = {'has claimed a', 'is taken by a', 'withdraws from society', 'has begun a mysterious construction',
                    'has created', 'has been possessed', 'has gone stark raving mad', 'has gone melancholy'},
            -- live L2: "<name> has assumed the position of expedition leader of <civ>." halted the fort
            noble = {'has assumed the position', 'has been elected', 'has become a militia', 'has been appointed to the position'},
            -- live L2/L3: "<name> has gone berserk!" halted the fort (3 times in L2, then again in L3 for a child
            -- whose Secretive mood failed). Nothing in v2 reacts while the game is halted, so an unattended fort
            -- stood still; the citizens and soldiers deal with a berserker as after a click on OK. The notice is
            -- dismissed and wakes the LLM (DECISION_NEEDED berserk) so Gordon hears of it.
            berserk = {'has gone berserk'},
            -- FR-75 (Run 14: the game stood on popups about every 15 minutes, until the player's popup.lua ran):
            -- "A gremlin!  Drive it away!" (AMBUSH_MISCHIEVOUS, Run 3 / Run 14) is a pest notice, not an army; the
            -- sighting of the gremlin is reflex's business (BUG-065). 'arrival' is the broad harmless word for visitors,
            -- petitioners and the like: it never clears a notice with a word of M.DENY in it (classify)
            mischief = {'drive it away'},
            arrival = {'has arrived', 'have arrived'}}   -- live L1: "<name>, Ghostly Bowyer has been put to rest."   -- live L1: "The Misty Company, a farmers guild, has been established."
-- FR-36 threat popups (Run 9: "Snatcher! Protect the children!" froze the game for minutes; "A vile force of darkness
-- has arrived!" stood while the army walked in). The reflex module issues the arrival reflexes (gates up, entrance doors
-- forbidden, civ alert, clock held) and emits ARRIVAL (A) with the text; only then is the popup dismissed and the game
-- resumed. live L6 (reclaimed Castlerisen): "An ambush! Drive them out!" for cavern bats came every few seconds;
-- Gordon 11.10.: never stop playing for a question, so they are dismissed too, after the reflex. Without the reflex
-- module the arbiter holds the clock itself for FALLBACK_TICKS and emits ARRIVAL (fail-open).
M.THREAT_POPUPS = {siege = {'vile force of darkness'}, ambush = {'an ambush'}, snatcher = {'snatcher'},
                   beast = {'has come'}}
-- FR-75: words that keep a popup for the player and the reflex, whatever else it says: threats, the undead, the embark
-- intro ("Strike the earth!", live L6: erasing it left a fort where nobody took a job). Lower case, plain markers
M.DENY = {'dead walk', 'undead', 'zombie', 'necromancer', 'ambush', 'siege', 'invad', 'army', 'force of darkness',
          'forgotten beast', 'titan', 'demon', 'werebeast', 'vampire', 'strike the earth', 'snatcher', 'kidnap'}
-- FR-75 knobs (config/reflex.json `popups`): other = also clear popups of unknown text (not M.DENY) after other_s real
-- seconds on the screen (default off: the player decides what the kernel may not name), log_s = real seconds between two
-- kern.log lines per popup kind
M.POPUP_CFG = {other = false, other_s = 20, log_s = 900}
M.PU_MAX = 64              -- texts of unclassified popups remembered for the log cadence
M.DEPOT_POPUP = 'need a trade depot'   -- a caravan popup that is also the NO_DEPOT interrupt (FR-43/53)
M.FALLBACK_TICKS = 4800
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
  for _, k in ipairs({'gfps', 'fps_cap', 'autosave', 'visitor_cap', 'population_cap', 'weather'}) do
    if orig[k] ~= nil then K.act.setting(k, orig[k]) end
  end
  if orig.timestream_fps ~= nil then K.act.timestream(orig.timestream_fps) end
  restore_overlays(K, orig)
end

-- live value of each global the profile changes, and the value the profile writes
local LIVE = {
  gfps = function() return df.global.enabler.gfps end,
  fps_cap = function() return math.floor(df.global.enabler.fps + 0.5) end,
  autosave = autosave_name,
  visitor_cap = function() return df.global.d_init.dwarf.visitor_cap end,
  weather = function() return df.global.d_init.feature.flags.WEATHER == true end,
}
local function profile_value(k)
  if k == 'weather' then return false end
  if k == 'fps_cap' then return M.BRAKE_FPS end      -- only the brake writes the cap
  return M.PROFILE[k]
end

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
  for _, k in ipairs({'gfps', 'fps_cap', 'autosave', 'visitor_cap', 'weather'}) do
    if orig[k] ~= nil then
      local ok, live = pcall(LIVE[k])
      -- the arbiter only ever lowers the FPS cap (brake, mode caps, clamp, tempo.lower): a live cap below the
      -- original is ours; after a process crash DF has reloaded the prefs value and there is nothing to undo
      local ours = ok and (live == profile_value(k) or (k == 'fps_cap' and math.type(live) == 'integer'
                                                         and math.type(orig[k]) == 'integer' and live < orig[k]))
      if ours then
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
  local okc, cap = pcall(LIVE.fps_cap)
  if okc and math.type(cap) == 'integer' and cap > 0 then orig.fps_cap = cap end
  st.cap = orig.fps_cap                          -- the live value: no write until the brake needs one
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
-- why the supply brake holds, or nil: phase P0 (water, brewing, fields and hunting are not there yet)
-- or economy.alarm() (thirst/hunger, drink or food days); only where timestream runs at all
function M.brake_why(K)
  if (M.MODE_FPS[K.mode()] or 250) <= 0 then return nil end
  local v = K.view()
  -- live L6 (Paddletribes): P0 held 150 ticks/s for a season with 143 drink and 632 food days; P0 brakes
  -- only until drink and food each reach P0_SAFE_DAYS (unknown stock keeps the brake)
  if type(v) == 'table' and v.phase == 'P0' then
    local s = type(v.stock) == 'table' and v.stock or {}
    local d, f = tonumber(s.drink_d), tonumber(s.food_d)
    if not (d and f and d >= M.P0_SAFE_DAYS and f >= M.P0_SAFE_DAYS) then return 'P0' end
  end
  local ok, why = K.call('economy', 'alarm')
  if ok and type(why) == 'string' and why ~= '' then return why end
end

-- clock knobs: M.CLOCK, overridden by config/reflex.json `clock` (ints 10..1000)
local function clock_cfg(K)
  local c = {siege_cap = M.CLOCK.siege_cap, alert_cap = M.CLOCK.alert_cap, trade_cap = M.CLOCK.trade_cap}
  local r = type(K.cfg.reflex) == 'table' and type(K.cfg.reflex.clock) == 'table' and K.cfg.reflex.clock or {}
  for k in pairs(c) do
    local v = int(r[k])
    if v and v >= 10 and v <= 1000 then c[k] = v end
  end
  return c
end
M.clock_cfg = clock_cfg

-- the reflex lockdown (FR-51/52): why it holds the clock, or nil; level-triggered (asked on every apply)
local function clamp_why(K)
  local ok, why = K.call('reflex', 'holding', 'clock')
  if ok and type(why) == 'string' and why ~= '' then return why end
  local fb = st.fb                     -- fail-open: a threat popup while the reflex module was unavailable
  if fb and K.now().tick < fb.until_tick and K.now().tick >= fb.since then return fb.why end
end

-- BUG-026: why trade wants the clock lowered (a trade-screen phase of a visit until it ends), or nil; level-triggered
local function trade_why(K)
  local ok, why = K.call('trade', 'clock')
  if ok and type(why) == 'string' and why ~= '' then return why end
end

-- desired timestream fps and its owner, plus the FPS cap to drive (nil = the original) and why
local function desired(K)
  local mode = K.mode()
  local base = M.MODE_FPS[mode] or 250
  local t = st.tempo
  if t and K.now().ms >= t.until_ms then st.tempo, t = nil, nil end
  local cc = clock_cfg(K)
  local cap, cwhy
  if M.MODE_CAP[mode] then cap, cwhy = cc[M.MODE_CAP[mode]], mode:lower() end
  local clamp = st.clamp
  local fps, by = base, 'mode'
  if clamp then
    fps, by = -1, 'clock'
    if not cap or cc.siege_cap < cap then cap, cwhy = cc.siege_cap, clamp end
  end
  if st.trade and (not cap or cc.trade_cap < cap) then cap, cwhy = cc.trade_cap, 'trade' end
  if st.brake and fps > M.BRAKE_FPS then
    fps, by = M.BRAKE_FPS, 'brake'
    if not cap or M.BRAKE_FPS < cap then cap, cwhy = M.BRAKE_FPS, 'brake' end
  end
  if t and fps > 0 and t.fps < fps then fps, by = t.fps, 'inbox' end
  -- tempo.lower: timestream alone never slows below DF's frame rate, so the cap follows it (STATUS §6 gap 10)
  if t and (not cap or t.fps < cap) then cap, cwhy = t.fps, 'inbox' end
  -- a timestream target above the cap would only skip ticks past it: off, the cap governs (ALERT 250 vs cap 100)
  if fps > 0 and cap and fps > cap then fps = -1 end
  return fps, by, cap, cwhy
end

-- the vanilla FPS cap follows desired(): the lowest of mode cap, clamp, brake and inbox tempo, never above the
-- captured original, which comes back as soon as nothing lowers it
local function apply_cap(K, cap, why)
  local orig = st.orig and st.orig.fps_cap
  if not orig then return end
  local want = cap and math.min(orig, cap) or orig
  if st.cap == want then return end
  local ok = K.act.setting('fps_cap', want)
  if ok then
    -- BUG-065 (Run 14: 'timestream at 10 FPS after every gremlin alarm'): every change of the cap says who lowered it
    if (st.cap or orig) ~= want then
      K.log('info', 'fps cap %d -> %d (%s)', st.cap or orig, want, want >= orig and 'free' or tostring(why or '?'))
    end
    st.cap = want
  end
end

-- idempotent: write timestream only when the desired value changed (or the live value drifted);
-- timestream only when Gordon's D-11 is 'accepted' (the default). The FPS cap (a vanilla setting) follows the
-- mode and the reflex clamp either way; the supply brake only where timestream runs.
function M.apply(K)
  local now = K.now()
  local acc = ts_accepted(K)
  local why = acc and M.brake_why(K) or nil
  if why ~= st.brake then
    K.log('info', 'supply brake %s', why and ('on: ' .. why) or 'off')
    st.brake = why
  end
  local clamp = clamp_why(K)
  if clamp ~= st.clamp then
    K.log('info', 'clock clamp %s', clamp and ('on: ' .. clamp) or 'off')
    st.clamp = clamp
  end
  local tw = trade_why(K)
  if tw ~= st.trade then
    K.log('info', 'trade clock %s', tw and ('on: FPS cap ' .. clock_cfg(K).trade_cap .. ' (' .. tw .. ')') or 'off')
    st.trade = tw
  end
  local fps, by, cap, cwhy = desired(K)
  apply_cap(K, cap, cwhy)
  st.cap_why, st.ts_want = cwhy, fps
  if not acc then st.tempo_by = 'mode'; return false end
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
  local fps, by = desired(K)
  return fps, by
end

-- public (FR-51, K.call): the reflex module changed its lockdown; apply the clock now (same step), not at the
-- next 500 ms cadence. Returns the FPS cap now driven (0 = no cap captured) and why it is lowered ('' = free).
function M.hold(K)
  M.apply(K)
  local orig = st.orig and st.orig.fps_cap or 0
  local cap = st.cap or orig
  return cap, (cap < orig or st.clamp) and (st.cap_why or st.clamp or '') or ''
end

---------------------------------------------------------------- pause
local function popup_count()
  local ok, n = pcall(function() return #df.global.world.status.popups end)
  return ok and n or 0
end

-- public (FR-68: the stop guard dismisses the same popups): kind, threat for a popup text; threat = true for
-- M.THREAT_POPUPS (checked first); nil for a popup that stays for the player
local function denied(low)
  for _, w in ipairs(M.DENY) do if low:find(w, 1, true) then return true end end
  return false
end

function M.classify(text)
  if type(text) ~= 'string' then return nil end
  local low = text:lower()                -- live L1b: "Merchants have arrived and ..." starts upper case
  for kind, marks in pairs(M.THREAT_POPUPS) do
    for _, m in ipairs(marks) do if low:find(m:lower(), 1, true) then return kind, true end end
  end
  for kind, marks in pairs(M.POPUPS) do
    if kind ~= 'arrival' then
      for _, m in ipairs(marks) do if low:find(m:lower(), 1, true) then return kind, false end end
    end
  end
  -- FR-75: the broad arrival words last (a caravan keeps its kind) and only without a threat word
  for _, m in ipairs(M.POPUPS.arrival or {}) do
    if low:find(m:lower(), 1, true) and not denied(low) then return 'arrival', false end
  end
end

-- FR-75: the popups config (config/reflex.json `popups`; a bad value keeps the default)
local function popup_cfg(K)
  local c = {other = M.POPUP_CFG.other, other_s = M.POPUP_CFG.other_s, log_s = M.POPUP_CFG.log_s}
  local r = type(K.cfg.reflex) == 'table' and type(K.cfg.reflex.popups) == 'table' and K.cfg.reflex.popups or {}
  if type(r.other) == 'boolean' then c.other = r.other end
  local a, b = int(r.other_s), int(r.log_s)
  if a and a >= 5 and a <= 600 then c.other_s = a end
  if b and b >= 60 and b <= 86400 then c.log_s = b end
  return c
end

-- the text of the front popup (nil: none, unreadable)
local function front_text()
  local ok, text = pcall(function() return dfhack.df2utf(df.global.world.status.popups[0].text) end)
  if ok and type(text) == 'string' then return text end
end

-- kind, text, threat of the front popup
local function popup_kind()
  local text = front_text()
  if not text then return nil end
  local kind, threat = M.classify(text)
  if kind then return kind, text, threat end
end

-- FR-75: one kern.log line per popup kind and period (popup_cfg.log_s real seconds), with the count of the period
-- before it; st.pk[kind] = {n, t}. Text of an unclassified popup that stays for the player: st.pu[text] = t, the same cadence
local function note_ack(K, kind, text)
  local now = K.now().ms
  st.pk = st.pk or {}
  local r = st.pk[kind]
  if not r then r = {n = 0}; st.pk[kind] = r end
  r.n = r.n + 1
  if r.t == nil or now < r.t or now - r.t >= popup_cfg(K).log_s * 1000 then
    K.log('info', 'popup %s acknowledged (%d since the last line): "%s"', kind, r.n, tostring(text):sub(1, 80))
    r.t, r.n = now, 0
  end
end

local function note_left(K, text)
  local now = K.now().ms
  st.pu = st.pu or {}
  local key = text:sub(1, 80)
  local t = st.pu[key]
  if t == nil or now < t or now - t >= popup_cfg(K).log_s * 1000 then
    if t == nil then                                    -- review C1: bounded (texts carry names; forget all past 64)
      st.pu_n = (st.pu_n or 0) + 1
      if st.pu_n > M.PU_MAX then st.pu, st.pu_n = {}, 1 end
    end
    st.pu[key] = now
    K.log('info', 'popup left for the player (unclassified): "%s"', key)
  end
end

-- FR-75, popups.other: the front popup has no kind; with the knob on, it is cleared once it has stood other_s real
-- seconds and carries no word of M.DENY. Returns 'other', text or nil
local function other_popup(K)
  local text = front_text()
  if not text then return nil end
  local c = popup_cfg(K)
  note_left(K, text)
  if not c.other or denied(text:lower()) then st.unk = nil; return nil end
  local now = K.now().ms
  if not st.unk or st.unk.text ~= text or now < st.unk.since then st.unk = {text = text, since = now} end
  if now - st.unk.since < c.other_s * 1000 then return nil end
  st.unk = nil
  return 'other', text
end

-- FR-87 (Run 14 y707: a private routine.lua deleted the curse popup before anyone read it; the fair-play hook was not active
-- in that session): a popup that leaves the screen while the kernel did not dismiss it (act.dismiss_popup counts its own) is
-- logged once per text and period (popups.log_s) with the POPUP_GONE event (C). The player's click looks the same: the line
-- is evidence for `dfllm doctor`, not an accusation. st.pw = the last reading {n, text, erased}.
local function popup_watch(K)
  local n = popup_count()
  local erased = require('dfllm.act').popups_erased or 0
  local pw = st.pw
  st.pw = {n = n, text = front_text(), erased = erased}
  if not pw or n >= pw.n then return end
  local gone = (pw.n - n) - (erased - pw.erased)
  if gone <= 0 then return end
  local text = tostring(pw.text or ''):sub(1, 120)
  local key, now = text:sub(1, 80), K.now().ms
  st.pv = st.pv or {}
  local t = st.pv[key]
  if t ~= nil and now >= t and now - t < popup_cfg(K).log_s * 1000 then return end
  if t == nil then                                         -- bounded: texts carry names (forget all past M.PU_MAX)
    st.pv_n = (st.pv_n or 0) + 1
    if st.pv_n > M.PU_MAX then st.pv, st.pv_n = {}, 1 end
  end
  st.pv[key] = now
  local kind = pw.text and M.classify(pw.text) or nil
  K.log('info', 'popup vanished without a kernel dismiss (%d): "%s"', gone, key)
  local d = {n = gone, text = text}
  if kind then d.kind = kind end
  K.emit('POPUP_GONE', 'C', string.format('%d popup%s gone without a kernel dismiss: "%s"', gone, gone == 1 and '' or 's',
                                          text:sub(1, 100)), d)
end

-- FR-36: hand a threat (or depot) popup to the reflex module once per popup, before anything dismisses it. Without
-- the module: the clock is held here and ARRIVAL emitted (fail-open). Runs whoever holds the pause: the reflexes
-- that need no ticks (doors, alert, clock) take effect at once.
local function announce(K, kind, text, threat)
  local key = kind .. '|' .. text
  if st.announced == key then return end
  st.announced = key
  local rkind = threat and kind or 'no_depot'
  local ok, done, summary = K.call('reflex', 'announce', rkind, text, 'popup')
  if ok and done then
    K.log('info', 'popup %s handed to the reflex: %s', kind, tostring(summary))
    return
  end
  if not threat then return end
  local now = K.now().tick
  st.fb = {why = 'popup:' .. kind, since = now, until_tick = now + M.FALLBACK_TICKS}
  M.apply(K)
  K.emit('ARRIVAL', 'A', string.format('%s (popup, reflex module unavailable) "%s" -> clock %d t/s', kind,
         text:sub(1, 80), st.cap or 0), {kind = kind, src = 'popup', text = text:sub(1, 200), clock = st.cap or 0})
end

local function pause_event(K, on, by, ttl)
  local d = {on = on and 1 or 0, by = by}
  if ttl then d.ttl = ttl end
  K.emit('PAUSE', 'B', (on and 'paused by ' or 'unpaused, was ') .. by, d)
end

-- pause transitions: a pause we did not cause is foreign (a popup's or Gordon's) and ends our hold,
-- so a TTL expiry can never unpause somebody else's pause
local function observe(K)
  -- live L0: a popup halts the game without setting pause_state, so it counts as a pause too
  local paused = df.global.pause_state == true or popup_count() > 0
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
  if popup_count() == 0 then st.announced = nil
  else
    local kind, text, threat = popup_kind()
    if kind and (threat or text:lower():find(M.DEPOT_POPUP, 1, true)) then announce(K, kind, text, threat) end
  end
  if not observe(K) then return end
  -- a whitelisted popup is also cleared once an expired inbox hold is all that is left
  -- live L6 (Perplexrooms): adopt paused the fort, the arrival popup came on top and was then held as
  -- Gordon's pause; with pause_state off, only the popup holds the clock, so a whitelisted one goes too
  local popup_only = popup_count() > 0 and df.global.pause_state ~= true and not st.hold
  if st.pause_by == 'popup' or popup_only or (st.pause_by == 'inbox' and not st.hold and popup_count() > 0) then
    local kind, text = popup_kind()
    if not kind then kind, text = other_popup(K) end            -- FR-75: unknown text, only with popups.other
    if kind and K.act.dismiss_popup(kind) then
      note_ack(K, kind, text)
      if kind == 'berserk' then
        K.emit('DECISION_NEEDED', 'A', 'berserk: ' .. text:sub(1, 120),
               {id = 'berserk', q = text:sub(1, 120) .. ' The fort runs on; citizens and soldiers deal with it. ' ..
                                    'Bury the body at once (ghost risk).'})
      end
      if popup_count() == 0 then K.act.set_paused(false) end
    end
  end
  if st.pause_by ~= 'inbox' and not st.asked and now.ms - st.pause_since >= M.ASK_AFTER_MS then
    st.asked = true
    local what = st.pause_by == 'popup' and front_text()          -- FR-75: say which popup it is
    K.emit('DECISION_NEEDED', 'A', 'game paused by ' .. st.pause_by .. ' for 10 min',
           {id = 'pause', q = 'paused by ' .. st.pause_by .. (what and (' ("' .. what:sub(1, 100) .. '")') or '')
                              .. '; Gordon unpauses in DF (the inbox cannot release it)'})
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
  local okw, errw = pcall(popup_watch, K)                  -- FR-87: evidence only, never a fault of the clock owner
  if not okw then K.log('warn', 'popup watch: %s', tostring(errw)) end
  track_pause(K)
  M.apply(K)
  local okv, errv = pcall(VL.step, K, st)                  -- FR-88: keep a followed camera going
  if not okv then
    st.view = nil
    K.log('warn', 'view step: %s', tostring(errv))
  end
end

function M.on.MODE(K, ev) M.apply(K) end

-- FR-68: `dfllm stop` (kern passes ev.hold_ok) while the fort is in SIEGE/BREACH/ALERT or a reflex lockdown holds
-- the clock: every setting goes back except the FPS cap and timestream, which stay where the clock had them;
-- restore.json stays active (dfllm restore, the next boot or a map unload heals them) and ev.held tells kern what
-- the guard must hold. Any other unload (map unload, reload, restore, --restore-fps) restores everything.
M.HOLD_MODES = {SIEGE = true, BREACH = true, ALERT = true}
function M.on.UNLOAD(K, ev)
  local held
  if type(ev) == 'table' and ev.hold_ok == true and (M.HOLD_MODES[K.mode()] or st.clamp ~= nil) then
    local fps, _, cap = desired(K)
    local c = clock_cfg(K)
    cap = int(cap) or c[M.MODE_CAP[K.mode()] or 'siege_cap'] or c.siege_cap
    -- timestream only where the arbiter drives it at all (D-11 accepted): a rejected D-11 is never touched
    held = {cap = cap, ts_off = fps <= 0 and ts_accepted(K), why = st.clamp and ('lockdown ' .. tostring(st.clamp))
            or K.mode()}
    ev.held = held
  end
  if not st.orig then return end
  if held then
    local rest = {}
    for k, v in pairs(st.orig) do if k ~= 'fps_cap' and k ~= 'timestream_fps' then rest[k] = v end end
    restore(K, rest)
    if math.type(st.cap) ~= 'integer' or st.cap > held.cap then K.act.setting('fps_cap', held.cap) end
    write_restore(K, {v = 2, save = tostring(K.cfg.save or ''), wall = os.time(), active = 1, orig = st.orig})
    return
  end
  restore(K, st.orig)
  write_restore(K, {v = 2, save = tostring(K.cfg.save or ''), wall = os.time(), active = 0, orig = st.orig})
end

function M.state(K)
  local orig = st.orig and st.orig.fps_cap or 0
  local cap = st.cap or orig
  local lowered = cap < orig or st.clamp ~= nil
  return {owners = {pause = st.pause_by or json.null, tempo = st.tempo_by or 'mode'},
          clock = {cap = cap, orig = orig, ts = st.ts_want or -1, held = st.clamp and 1 or 0,
                   why = lowered and tostring(st.cap_why or st.clamp or ''):sub(1, 24) or ''}}
end

M.verbs['tempo.lower'] = function(K, args, cmd)
  local fps, ttl = int(args.fps), int(args.ttl_s)
  if not fps or fps < 10 or fps > 1000 or not ttl or ttl < 1 or ttl > 3600 then
    return false, 'need fps 10..1000 and ttl_s 1..3600'
  end
  st.tempo = {fps = fps, until_ms = K.now().ms + ttl * 1000}
  M.apply(K)
  local base = M.MODE_FPS[K.mode()] or 250
  -- the FPS cap follows (STATUS §6 gap 10): timestream alone never slowed DF below its frame rate
  if base < 0 or st.clamp then
    return true, string.format('timestream is off in %s; FPS cap %d for %d s', K.mode(), st.cap or fps, ttl)
  end
  return true, string.format('tempo %d for %d s (FPS cap %d)', math.min(fps, base), ttl, st.cap or fps)
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

-- FR-88 (Run 14 note 95): the camera; the arbiter hosts it because it owns what the player sees of the clock (lua/dfllm/viewlib.lua)
M.verbs.view = function(K, args, cmd) return VL.verb(K, st, args, cmd) end

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
