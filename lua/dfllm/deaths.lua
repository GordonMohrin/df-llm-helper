-- dfllm.deaths (FR-64): library (not a kernel module) for care: the cause of a citizen's death and the death
-- clusters. Run 9 live test (STATUS 0h, 2026-10-15): every DEATH read `citizen 25889 died (NONE) [cause=NONE]`
-- (unit.counters.death_cause stays NONE in DF 53.16) while the announcement log said "... has been found dead,
-- dehydrated."; two of three deaths within 15 real minutes were dehydration and the stream gave no hint.
-- Categories (D.CATS): dehydrated, starved, killed (by a race / unit), drowned, suffocated, bled, mood (a strange
-- mood that ended the dwarf), old_age, crushed (cave-in, falling rocks, a drawbridge), burned, infection, unknown.
-- The cause comes from what the player sees (the unit list's dead or missing entry and the unit sheet, the
-- announcement log), in this order:
--   1. the death incident (unit.counters.death_id -> df.incident: death_cause, criminal / criminal_race) -> the
--      category of its df.death_type; `killed` names the killer's race and unit id;
--   2. unit.counters.death_cause (NONE in the Run 9 test);
--   3. the death announcement that names the unit (world.status.reports, continuation lines joined, not older
--      than the death): the victim is the subject of a passive death phrase ("has been found dead, dehydrated.",
--      "has been found, starved to death.", "has bled to death.", "has been murdered by <name>!");
--   4. the thirst / hunger timer at death past the unit sheet's Dehydrated (50,000) / Starving (75,000) line.
-- A strange mood wins over that: a dwarf that went insane after a failed mood (Melancholy, Raving, Berserk) died of
-- the mood, whatever finished it; a dwarf that died in a strange mood died of it when it starved, dehydrated or
-- nothing else is known (a moody dwarf neither eats nor drinks), else of the accident or the attacker.
-- Fair play: a death whose incident is not discovered yet (the unit list says "missing") gets no cause until the
-- incident is discovered or an announcement names the unit; care asks again every run. Without a readable incident
-- the unit sheet's fields count. Evidence that rides along: the deciding source, the thirst and hunger timers, the
-- patient flag (needs health care, or resting in bed), the last job, the position.
local C = require('dfllm.util.contract')

local D = {}

D.CATS = {'dehydrated', 'starved', 'killed', 'drowned', 'suffocated', 'bled', 'mood', 'old_age', 'crushed', 'burned',
          'infection', 'unknown'}
D.PREVENTABLE = {dehydrated = true, starved = true}     -- DEATHS_PREVENTABLE (A): supply or access, never fate
-- df.death_type names (DF 53.16, df-structures; deathcause.lua / gui/unit-info-viewer DEATH_TYPES) -> category.
-- Unlisted ones (COLD, ENCASE_ICE, VANISH, CHASM, SCARE, ...) are `unknown` with the type as evidence.
D.TYPE = {
  THIRST = 'dehydrated', HUNGER = 'starved', OLD_AGE = 'old_age', INFECTION = 'infection',
  DROWN = 'drowned', DROWN_ALT = 'drowned',
  SUFFOCATE = 'suffocated', LEAVE_OUT_IN_AIR = 'suffocated', BURY_ALIVE = 'suffocated',
  BLEED = 'bled', DRAIN_BLOOD = 'bled',
  CAVEIN = 'crushed', FALLING_ROCKS = 'crushed', COLLAPSE = 'crushed', DRAWBRIDGE = 'crushed', COLLISION = 'crushed',
  FALLING_OBJECT = 'crushed', VEHICLE = 'crushed',
  MAGMA = 'burned', MAGMA_MIST = 'burned', DRAGONFIRE = 'burned', FIRE = 'burned', SCALD = 'burned', HEAT = 'burned',
  BURN_ALIVE = 'burned', ENCASE_LAVA = 'burned', ENCASE_MAGMA = 'burned', BOIL = 'burned', MELT = 'burned',
  SHOT = 'killed', STRUCK_DOWN = 'killed', MURDER = 'killed', SCUTTLE = 'killed', TRAP = 'killed', SPIKE = 'killed',
  BEHEAD = 'killed', CRUCIFY = 'killed', FEED_TO_BEASTS = 'killed', HACK_TO_PIECES = 'killed', SLAUGHTER = 'killed',
}
D.BY = {TRAP = 'trap', SPIKE = 'spikes'}               -- killed without an attacker
-- the death announcement: the victim is the subject (the arbiter's death popup markers, live L2-L7); a report
-- counts only when the unit's name stands before the first of these
D.MARKS = {'has been found dead', 'has been found, ', 'has bled to death', 'has been struck down', 'has died',
           'has starved', 'starved to death', 'died of thirst', 'has drowned', 'has suffocated', 'has been crushed',
           'has been killed', 'was killed', 'has been murdered', 'has been slain', 'has been executed',
           'has been shot', 'has burned', 'has been burned', 'has been incinerated', 'has succumbed', 'has perished',
           'was struck down'}
-- category phrases, searched (in this order) from the death phrase on, in lower case
D.PHRASES = {{'dehydrat', 'dehydrated'}, {'thirst', 'dehydrated'}, {'starv', 'starved'}, {'drown', 'drowned'},
             {'suffocat', 'suffocated'}, {'choked', 'suffocated'}, {'bled to death', 'bled'},
             {'blood loss', 'bled'}, {'old age', 'old_age'}, {'cave-in', 'crushed'}, {'cave in', 'crushed'},
             {'crushed', 'crushed'}, {'falling rock', 'crushed'}, {'drawbridge', 'crushed'},
             {'falling object', 'crushed'}, {'burn', 'burned'}, {'fire', 'burned'}, {'magma', 'burned'},
             {'incinerat', 'burned'}, {'scald', 'burned'}, {'infection', 'infection'}, {'struck down', 'killed'},
             {'murdered', 'killed'}, {'slain', 'killed'}, {'killed', 'killed'}, {'executed', 'killed'},
             {'shot', 'killed'}}
D.STRANGE = {Fey = true, Secretive = true, Possessed = true, Macabre = true, Fell = true}
D.FAILED = {Melancholy = true, Raving = true, Berserk = true}
-- the cluster line per cause: "<n> citizens <text> within <d> d"
D.TEXT = {dehydrated = 'died of dehydration', starved = 'starved to death', killed = 'were killed',
          drowned = 'drowned', suffocated = 'suffocated', bled = 'bled to death', mood = 'died of a strange mood',
          old_age = 'died of old age', crushed = 'were crushed', burned = 'burned to death',
          infection = 'died of an infection', unknown = 'died', mixed = 'died'}
D.LINES = {thirst = 50000, hunger = 75000, thirsty = 25000, hungry = 50000}   -- unit sheet status lines
D.REPORTS = 400                                         -- newest announcement log entries read

local function int(v) return math.tointeger(v) end
local function utf(s)
  local ok, r = pcall(dfhack.df2utf, s)
  return ok and type(r) == 'string' and r or s
end
local function cut(s, n)                                -- cut at a UTF-8 boundary
  s = tostring(s or '')
  if #s <= n then return s end
  local c = n
  while c > 0 and (s:byte(c + 1) or 0) & 0xC0 == 0x80 do c = c - 1 end
  return s:sub(1, c)
end
D.cut = cut

---------------------------------------------------------------- reads
-- a creature's race name as the unit sheet shows it (getRaceReadableName; creature_raw name[0], deathcause.lua)
local function race_of(k)
  if not k then return nil end
  local ok, s = pcall(function() return dfhack.units.getRaceReadableName(k) end)
  if ok and type(s) == 'string' and s ~= '' then return s end
  ok, s = pcall(function() return df.creature_raw.find(k.race).name[0] end)
  if ok and type(s) == 'string' and s ~= '' then return s end
  ok, s = pcall(function() return dfhack.units.getRaceName(k) end)
  if ok and type(s) == 'string' and s ~= '' then return s:lower() end
end

-- the death incident: {id, found (false only while the incident says undiscovered), cause = df.death_type name or
-- nil, killer = unit id or nil, race = the killer's race or nil}; nil without a readable incident
function D.incident(u)
  local ok, id = pcall(function() return u.counters.death_id end)
  id = ok and int(id) or nil
  if not id or id < 0 then return nil end
  local okf, ic = pcall(function() return df.incident.find(id) end)
  if not okf or ic == nil then return nil end
  local r = {id = id, found = true}
  pcall(function() if ic.flags.discovered == false then r.found = false end end)
  pcall(function()
    local n = df.death_type[ic.death_cause]
    if n and n ~= 'NONE' then r.cause = n end
  end)
  pcall(function()
    local k = int(ic.criminal)
    if k and k >= 0 then r.killer = k end
  end)
  if r.killer then r.race = race_of(df.unit.find(r.killer)) end
  if not r.race then
    pcall(function()
      local s = df.creature_raw.find(ic.criminal_race.race).name[0]
      if type(s) == 'string' and s ~= '' then r.race = s end
    end)
  end
  return r
end

-- the unit sheet's own field (unit.counters.death_cause): a df.death_type name or nil (NONE)
function D.unit_cause(u)
  local ok, n = pcall(function() return df.death_type[u.counters.death_cause] end)
  if ok and type(n) == 'string' and n ~= 'NONE' then return n end
end

-- lower-case name keys to find the unit in an announcement: the first name, the nickname (DF prints it in place of
-- the first name by default) and the first word of the name as the game prints it (capitalized, CP437)
function D.name_keys(u)
  local keys, seen = {}, {}
  local function add(s)
    if type(s) ~= 'string' then return end
    s = s:lower()
    if #s >= 2 and not seen[s] then seen[s] = true; keys[#keys + 1] = s end
  end
  pcall(function() add(u.name.first_name) end)
  pcall(function() add(u.name.nickname) end)
  pcall(function()
    local tr = (dfhack.translation and dfhack.translation.translateName) or dfhack.TranslateName
    add(tostring(tr(u.name) or ''):match('^(%S+)'))
  end)
  return keys
end

local function letter(b) return b ~= nil and (b >= 0x80 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90)
                                               or (b >= 97 and b <= 122)) end
-- first position of `w` in `s` as a whole word, or nil
local function word_at(s, w)
  local i = 1
  while true do
    local a, b = s:find(w, i, true)
    if not a then return nil end
    if not letter(s:byte(a - 1)) and not letter(s:byte(b + 1)) then return a end
    i = a + 1
  end
end

-- one death announcement against the name keys: {cat (nil = no category in the text), by (a killer named after
-- 'by'), text (from the death phrase on, CP437)} or nil
function D.parse(text, keys)
  text = tostring(text or '')
  local low = text:lower()
  local at
  for _, m in ipairs(D.MARKS) do
    local i = low:find(m, 1, true)
    if i and (not at or i < at) then at = i end
  end
  if not at then return nil end
  local named = false
  for _, k in ipairs(keys) do
    local i = word_at(low, k)
    if i and i < at then named = true; break end
  end
  if not named then return nil end
  local rest = low:sub(at)
  local cat
  for _, ph in ipairs(D.PHRASES) do
    if rest:find(ph[1], 1, true) then cat = ph[2]; break end
  end
  local by
  if cat == 'killed' then
    local tail = text:sub(at)
    by = tail:match(' by (.-)[!%.]') or tail:match(' by (.+)$')
  end
  return {cat = cat, by = by, text = text:sub(at)}
end

-- the newest `n` announcement log entries, continuation lines joined to their head: {{text, tick}} oldest first
-- (tick = absolute game tick of the report, nil when unreadable)
function D.report_groups(n)
  local groups = {}
  local ok = pcall(function()
    local reps = df.global.world.status.reports
    local hi = #reps - 1
    local cur
    for i = math.max(0, hi - (n or D.REPORTS) + 1), hi do
      local rep = reps[i]
      local cont = false
      pcall(function() cont = rep.flags.continuation == true end)
      local text = tostring(rep.text or '')
      if cont and cur then
        cur.text = cur.text .. ' ' .. text
      else
        local t
        pcall(function() t = C.abs_tick(int(rep.year), int(rep.time)) end)
        cur = {text = text, tick = t}
        groups[#groups + 1] = cur
      end
    end
  end)
  return ok and groups or {}
end

-- the newest death announcement that names `u`, not older than `since` (abs tick; nil: any): see D.parse
function D.report(u, since, groups)
  local keys = D.name_keys(u)
  if #keys == 0 then return nil end
  groups = groups or D.report_groups()
  for gi = #groups, 1, -1 do
    local g = groups[gi]
    if not (since and g.tick and g.tick < since) then
      local hit = D.parse(g.text, keys)
      if hit then return hit end
    end
  end
end

local function timers(u)
  local th, hu
  pcall(function() th = int(u.counters2.thirst_timer) end)
  pcall(function() hu = int(u.counters2.hunger_timer) end)
  return th, hu
end

-- the unit sheet says "needs health care" (notifications.lua) or the dwarf rests in bed (water.lua's patients)
local function patient(u)
  local ok, yes = pcall(function()
    if u.health and u.health.flags.needs_healthcare then return true end
    local j, rest = u.job and u.job.current_job, df.job_type.Rest
    return j ~= nil and rest ~= nil and j.job_type == rest
  end)
  return ok and yes == true
end

local function last_job(u)
  local ok, n = pcall(function() return df.job_type[u.job.current_job.job_type] end)
  if ok and type(n) == 'string' then return n end
end

local function pos_of(u)
  local ok, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
  if ok and int(x) and x >= 0 then return {x, y, z} end
end

local function unit_mood(u)
  local ok, k = pcall(function() return df.mood_type[u.mood] end)
  if not ok or type(k) ~= 'string' then return nil end
  if D.STRANGE[k] then return {kind = k, state = 'strange'} end
  if D.FAILED[k] then return {kind = k, state = 'failed'} end
end

---------------------------------------------------------------- the cause
-- classify(u, o) -> {cause, src ('incident', 'unit', 'report', 'timer', 'mood', 'none'), why = {evidence...},
--   found (false: not found yet, no cause), dtype, by, killer, mood (kind), thirst, hunger, patient, pos, job}
-- o = {mood = {kind, state = 'strange'|'failed'} (care's own mood records), since = the death tick (abs),
--      groups = D.report_groups() (built when needed, of the newest `reports` entries), thirst = Dehydrated line,
--      hunger = Starving line}
function D.classify(u, o)
  o = o or {}
  local r = {cause = 'unknown', src = 'none', why = {}, found = true}
  local mood = o.mood or unit_mood(u)
  local ic = D.incident(u)
  local function rep()
    if r.rep == nil then
      o.groups = o.groups or D.report_groups(o.reports)
      r.rep = D.report(u, o.since, o.groups) or false
    end
    return r.rep or nil
  end
  if ic and not ic.found and not rep() then        -- the unit list says "missing": nothing to tell yet
    r.found, r.rep = false, nil
    r.why = {'not found yet, missing in the unit list'}
    return r
  end
  local th, hu = timers(u)
  r.thirst, r.hunger, r.pos, r.job = th, hu, pos_of(u), last_job(u)
  r.patient = patient(u) or nil
  local base, src, dtype
  if ic and ic.cause then dtype, src = ic.cause, 'incident' end
  if not dtype then
    dtype = D.unit_cause(u)
    if dtype then src = 'unit' end
  end
  if dtype then base = D.TYPE[dtype] end
  if not base then
    local h = rep()
    if h and h.cat then base, src = h.cat, 'report' end
  end
  if not base then
    if th and th >= (o.thirst or D.LINES.thirst) then base, src = 'dehydrated', 'timer'
    elseif hu and hu >= (o.hunger or D.LINES.hunger) then base, src = 'starved', 'timer' end
  end
  if base == 'killed' then
    local h = r.rep or nil
    r.killer = ic and ic.killer or nil
    r.by = (ic and ic.race) or (h and h.by and utf(h.by)) or D.BY[dtype or ''] or nil
  end
  r.dtype = dtype
  local w = r.why
  if mood and (mood.state == 'failed' or not base or D.PREVENTABLE[base]) then
    r.cause, r.src, r.mood = 'mood', 'mood', mood.kind
    w[#w + 1] = mood.state == 'failed' and ('insane after a failed mood (' .. mood.kind .. ')')
                or ('in a ' .. mood.kind .. ' mood')
  else
    r.cause, r.src = base or 'unknown', src or 'none'
    if mood then w[#w + 1] = 'in a ' .. mood.kind .. ' mood' end
  end
  if dtype then w[#w + 1] = (src == 'unit' and 'unit ' or 'incident ') .. dtype end
  if r.by and r.cause ~= 'killed' then w[#w + 1] = 'by ' .. r.by .. (r.killer and (' ' .. r.killer) or '') end
  local h = r.rep or nil
  if h and (src == 'report' or not dtype) then w[#w + 1] = 'report "' .. cut(utf(h.text), 48) .. '"' end
  if th and (th >= D.LINES.thirsty or r.cause == 'dehydrated' or r.cause == 'mood') then
    w[#w + 1] = 'thirst ' .. th
  end
  if hu and (hu >= D.LINES.hungry or r.cause == 'starved') then w[#w + 1] = 'hunger ' .. hu end
  if r.patient then w[#w + 1] = 'patient' end
  if #w == 0 then w[1] = 'no incident, report or timer' end
  r.rep = nil
  return r
end

-- the DEATH line: "citizen 25889 died: dehydrated (incident THIRST; thirst 18879; patient)"
function D.text(id, r, revised)
  local what = r.cause
  if r.cause == 'killed' and r.by then what = 'killed by ' .. r.by .. (r.killer and (' ' .. r.killer) or '') end
  return cut(string.format('citizen %d %s: %s (%s)', id, revised and 'found dead' or 'died', what,
                           table.concat(r.why, '; ')), 200)
end

---------------------------------------------------------------- clusters
-- deaths (care's records {t, u, c, pend?}) within `win` ticks before `now`, and the same-cause groups of at least
-- `same` deaths ({cause, list}, sorted by cause); a pending (not found) death or an unknown cause never forms one
function D.window(list, now, win, same)
  local w, by, order = {}, {}, {}
  for _, e in ipairs(list or {}) do
    if type(e) == 'table' and int(e.t) and now - e.t <= win then
      w[#w + 1] = e
      if e.pend ~= 1 and e.c ~= 'unknown' then
        if not by[e.c] then by[e.c] = {}; order[#order + 1] = e.c end
        table.insert(by[e.c], e)
      end
    end
  end
  table.sort(order)
  local groups = {}
  for _, cause in ipairs(order) do
    if #by[cause] >= same then groups[#groups + 1] = {cause = cause, list = by[cause]} end
  end
  return w, groups
end

-- causes of a list of records: "dehydrated 2, killed 1" (most first) and the counts
function D.tally(list)
  local n, order = {}, {}
  for _, e in ipairs(list) do
    local c = e.pend == 1 and 'unknown' or e.c
    if not n[c] then order[#order + 1] = c end
    n[c] = (n[c] or 0) + 1
  end
  table.sort(order, function(a, b) return n[a] > n[b] or (n[a] == n[b] and a < b) end)
  local parts = {}
  for i, c in ipairs(order) do parts[i] = c .. ' ' .. n[c] end
  return table.concat(parts, ', '), n
end

return D
