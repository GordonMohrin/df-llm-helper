-- dfllm.curse (library of care, BUG-115, FR-83, FR-84): curses and transformations, and the unit sheet.
-- Run 14 y707: a miner toppled a statue in a tantrum, "has been cursed by Ok!", became a werecavy, and 23 dwarves followed
-- him (pop 54 -> 10); no event, no wake: the game's reports were read by nobody (care listened to the toppled-building
-- reports only). Readers of this library:
--   * care.on.REPORT -> M.report: "<name> has been cursed by <god>!" and "<name> has transformed into a <race>!" (any
--     announcement type: kern routes a report by M.TEXTS too, because the type name cannot be verified offline);
--   * care's unit scan -> M.look: what the unit sheet shows (unit.curse name, the were-form race), so units cursed before
--     the kernel booted, and transformations nobody announced, are found;
--   * care's run end -> M.finish: forget the dead, emit what the cadence allows (CURSED, TRANSFORM, CURSE_MOON, the
--     DECISION_NEEDED `curse_kill` question), publish state `curse`;
--   * `inspect what=curse` (the whole bounded list) and `inspect what=unit key=<id|name>` (FR-83, the unit sheet).
-- State: persisted care.cur = {u = {[unit id | 'n:<name>'] = record}, mt = tick of the last transformation wave, ev = cadence
-- records, dead = cursed units that died}. A record = {n name, g god, t first seen, k were|vampire|?, f form, tf 1 =
-- transformed now, tt last change, s source report|sheet|transform, tr trigger, a announcement type}. Bounded by
-- `curse_keep`. Plain values only. The kill order stays the player's decision (DECISION_NEEDED curse_kill).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local CAD = require('dfllm.util.cadence')

local M = {}
local DAY, YEAR = C.TICKS.DAY, C.TICKS.YEAR

-- lower case plain markers kern routes a report by (care.report_text); the announcement type name is not needed
M.TEXTS = {'has been cursed', 'been cursed by', 'transformed into', 'has transformed', 'transforms into'}
M.STRESS = {[0] = 'desperate', [1] = 'unhappy', [2] = 'troubled', [3] = 'content', [4] = 'good', [5] = 'happy', [6] = 'ecstatic'}

local S = {}                        -- runtime: name index, queues, race cache, the last published view

function M.reset() S = {q = {}, last = {}} end
M.reset()

local function num(v) return math.tointeger(tonumber(v)) end
local function trunc(s, n)
  s = tostring(s or '')
  if #s <= n then return s end
  local cut = n
  while cut > 0 and (s:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return s:sub(1, cut)
end
local function rd(f, default)
  local ok, v = pcall(f)
  if ok and v ~= nil then return v end
  return default
end
local function strip(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('[%s%.!]+$', '')) end
-- BUG-134 (live i2, 53.16: every curse record stayed 'n:<name>', no ids, no curse_kill, the dead never forgotten): the
-- game's texts name a unit without its nickname ('Olon Gatizbomrek, Axe Lord has been cursed by Risen!') while
-- getReadableName carries it ('Olon Gatizbomrek "Fondlewhipped", Axe Lord'). Names are compared without the quoted
-- nickname (", `...', << >>), in UTF-8 (a text still in CP437 is converted first)
local function utf(s)
  s = tostring(s or '')
  if utf8.len(s) then return s end
  local ok, v = pcall(function() return dfhack.df2utf(s) end)
  return ok and type(v) == 'string' and v or s
end
local function nonick(s)
  s = utf(s):gsub('%s*"[^"]*"', ''):gsub("%s*`[^`']*'", ''):gsub('%s*\xC2\xAB.-\xC2\xBB', '')
  return s
end
local function name_key(s) return (nonick(s):lower():gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')) end
local function short(name)
  local n = nonick(name)
  return strip(n:match('^([^,]+)') or n)
end
M.name_key = function(s) return name_key(short(s)) end           -- for tests and readers: the key a name is matched by

-- BUG-173 (live i2: key='Rigoth Savotdumat' -> 'no such citizen'; with a nickname set getReadableName reads
-- "`Blinky' Savotdumat", the real first name is gone): the keys a unit is known by: its sheet name without the nickname,
-- and its real first and last name (u.name.first_name + the last name alone, translateName only_last_name)
local function unit_keys(u, env)
  local keys = {}
  local n = env.nm(u)
  if n ~= '' then keys[1] = name_key(short(n)) end
  local first = rd(function() return strip(utf(u.name.first_name)) end, '')
  if type(first) == 'string' and first ~= '' then
    local last = rd(function() return strip(utf(dfhack.translation.translateName(u.name, false, true))) end, '')
    local k = name_key(first .. (type(last) == 'string' and last ~= '' and (' ' .. last) or ''))
    if k ~= '' and k ~= keys[1] then keys[#keys + 1] = k end
  end
  return keys
end
M.unit_keys = unit_keys

---------------------------------------------------------------- the texts
-- text -> {kind = 'cursed', who, god?, ctype} | {kind = 'transform', who, to, dir = 'beast' | 'back'} | nil
function M.parse(text)
  local t = tostring(text or '')
  local low = t:lower()
  local i, j = low:find(' has been cursed', 1, true)
  if not i then i, j = low:find(' been cursed', 1, true) end
  if i then
    local god = t:sub(j + 1):match('^%s*by%s+(.-)%s*[%.!]*%s*$')
    local who = strip(t:sub(1, i - 1))
    if who == '' then return nil end
    return {kind = 'cursed', who = short(who), full = who, god = god and trunc(strip(god), 24) or nil,
            ctype = low:find('vampire', 1, true) and 'vampire' or (low:find('were', 1, true) and 'were' or '?')}
  end
  for _, mark in ipairs({' has transformed into ', ' transformed into ', ' transforms into '}) do
    local a, b = low:find(mark, 1, true)
    if a then
      local who = strip(t:sub(1, a - 1))
      local to = strip(t:sub(b + 1)):gsub('^[Aa]n?%s+', '')
      if who == '' or to == '' then return nil end
      local were = to:lower():find('were', 1, true) ~= nil
      return {kind = 'transform', who = short(who), full = who, to = trunc(to, 24), dir = were and 'beast' or 'back'}
    end
  end
  return nil
end

---------------------------------------------------------------- the moon
-- Run 14: the transformations came at d155, d180, d206, d232, d258 of one year: 25.85 days = 336 / 13. `mt` = the tick of
-- the last wave seen (it calibrates the phase, the period stays year / cycles); without one the full moons are taken at
-- k x year / cycles from the new year (an estimate; bugs/BUG-115 "Not decided offline"). -> day of the year (1-based) of the
-- next full moon, whole days until it, its tick
function M.moon(tick, cycles, mt)
  cycles = math.max(1, num(cycles) or 13)
  local cyc = YEAR / cycles
  local nxt
  if num(mt) and tick >= mt then
    nxt = mt + (math.floor((tick - mt) / cyc) + 1) * cyc
  elseif num(mt) then
    nxt = mt
  else
    local yt = tick % YEAR
    nxt = tick - yt + (math.floor(yt / cyc) + 1) * cyc
  end
  nxt = math.floor(nxt)
  return (nxt % YEAR) // DAY + 1, math.max(0, math.ceil((nxt - tick) / DAY)), nxt
end

---------------------------------------------------------------- the unit sheet
local function race_info(u)
  local race = rd(function() return u.race end)
  if race == nil then return nil end
  S.races = S.races or {}
  local r = S.races[race]
  if r == nil then
    r = rd(function()
      local raw = df.creature_raw.find(race)
      if not raw then return false end
      local nm = rd(function() return raw.name[0] end, '')
      local id = rd(function() return raw.creature_id end, '')
      local low = (tostring(nm) .. ' ' .. tostring(id)):lower()
      return {name = trunc(nm, 24), were = low:find('were', 1, true) ~= nil}
    end, false)
    S.races[race] = r
  end
  return r or nil
end

-- a field read that fails is noted under its label (miss[label] = true): inspect lists it, the scan logs it once
local function rdm(miss, label, f)
  local ok, v = pcall(f)
  if ok then return v end
  if miss then miss[label] = true end
  return nil
end

-- an active syndrome with a body transformation effect (a were-curse: the deity's or the bite's)
local function were_syn(u)
  local BT = df.creature_interaction_effect_type.BODY_TRANSFORMATION
  for _, s in ipairs(u.syndromes.active) do
    local syn = df.syndrome.find(s.type)
    if syn then
      for _, ce in ipairs(syn.ce) do
        local ok, t = pcall(function() return ce:getType() end)
        if ok and t == BT then return true end
      end
    end
  end
  return false
end

-- what the sheet of a unit shows of a curse: {name, were, vampire, form, tf, hid} or nil.
-- BUG-135 (live i2: `unit.curse` does not exist in DF 53.16, "Cannot read field unit.curse: not found"; the old read was
-- always nil and silent): the shown curse name is u.uwss_display_name_sing while u.uwss_use_display_name is true (a hidden
-- vampire stays hidden); tf = the unit's race is a were-form now (the sheet says "Werecavy Planter"); hid = a were-curse
-- the game keeps on the unit (curse_year >= 0 and an active body-transformation syndrome) before its first full moon:
-- the deity's curse was announced, the bite was in the combat log (bugs/BUG-135 "Decided"). `miss` collects failed reads
function M.sheet(u, miss)
  local cname = ''
  if rdm(miss, 'uwss_use_display_name', function() return u.uwss_use_display_name end) == true then
    local nm = rdm(miss, 'uwss_display_name_sing', function() return u.uwss_display_name_sing end)
    if type(nm) == 'string' then cname = strip(utf(nm)) end                -- a string only: never the text of a struct
  end
  local ri = race_info(u)
  local tf = ri and ri.were == true
  local cy = num(rdm(miss, 'curse_year', function() return u.curse_year end))
  local syn = cy ~= nil and cy >= 0 and rdm(miss, 'syndromes', function() return were_syn(u) end) == true
  if cname == '' and not tf and not syn then return nil end
  local low = cname:lower()
  return {name = trunc(cname, 24), were = tf or syn or low:find('were', 1, true) ~= nil,
          vampire = low:find('vampire', 1, true) ~= nil, form = ri and ri.were and ri.name or '', tf = tf,
          hid = (cname == '' and not tf and syn) or nil}
end

---------------------------------------------------------------- the record
function M.cur(p)
  if type(p.cur) ~= 'table' then p.cur = {} end
  local c = p.cur
  c.u = json.object(type(c.u) == 'table' and c.u or {})
  -- BUG-178 (live i2: m.care.cur.ev was "[]" although CURSE_MOON and curse_kill had marked it): a plain {} encodes as [],
  -- decodes as a json array and stays one whatever keys (moon, kill) are added, so the cadence records never reached the
  -- save. The records are a keyed object
  c.ev = json.object(type(c.ev) == 'table' and c.ev or {})
  c.dead = num(c.dead) or 0
  return c
end

local function counts(cur)
  local n, tf = 0, 0
  for _, r in pairs(cur.u) do
    if r.tf == 1 then tf = tf + 1 else n = n + 1 end
  end
  return n, tf
end

local function ids_of(cur, limit)
  local list = {}
  for k, r in pairs(cur.u) do
    local id = num(k)
    if id then list[#list + 1] = {id = id, tf = r.tf == 1 and 0 or 1, t = num(r.t) or 0} end
  end
  table.sort(list, function(a, b)
    if a.tf ~= b.tf then return a.tf < b.tf end
    if a.t ~= b.t then return a.t < b.t end
    return a.id < b.id
  end)
  local ids = {}
  for i = 1, math.min(limit, #list) do ids[i] = list[i].id end
  return ids, #list
end

-- only the fort's own (citizens, residents, its dead): a sheet the player could open
local function ours(u)
  local U = dfhack.units
  return rd(function() return U.isCitizen(u, true) or U.isResident(u, true) or (U.isOwnGroup and U.isOwnGroup(u)) end, false) == true
end

-- the fort's living own units: the census, or (BUG-134: paused after a load, before sense's first census) sense's
-- own_ids
local function own_ids(K)
  local cu = K.census.u
  local ids = type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or nil
  if ids and #ids > 0 then return ids end
  local ok, r = K.call('sense', 'own_ids')        -- unit iteration belongs to sense (lint unit-iter)
  return ok and type(r) == 'table' and r or {}
end
M.own_ids = own_ids

-- the citizens by name (without the nickname, lower case, the part before the comma) -> unit id, false when two share it
-- (no guess)
local function index(K, p, cur, env)
  local now = K.now().tick
  local ix = S.idx
  if ix and now >= ix.t and now - ix.t < 600 then return ix.map end
  local map = {}
  local function add(id)
    local u = id and df.unit.find(id)
    if not u then return end
    for _, k in ipairs(unit_keys(u, env)) do          -- BUG-173: the real name too
      if map[k] == nil then map[k] = id elseif map[k] ~= id then map[k] = false end
    end
  end
  for _, id in ipairs(own_ids(K)) do add(id) end
  for k in pairs(cur.u) do add(num(k)) end
  S.idx = {t = now, map = map}
  return map
end

local function resolve(K, p, cur, env, who)
  local k = name_key(who)
  local id = index(K, p, cur, env)[k]
  if id then return id end
  return nil
end

-- the toppled building and the tantrum before the curse (care's records, BUG-064)
local function trigger(c, p, id, who, now, env)
  local win = c.curse_trig_win or 4800
  local best
  for _, r in ipairs(type(p.top) == 'table' and p.top or {}) do
    if type(r) == 'table' and now - (num(r.t) or -1e9) <= win and now >= (num(r.t) or 0) then
      local same = (id and num(r.unit) == id) or name_key(short(r.by)) == name_key(who)
      if same and (not best or r.t >= best.t) then best = r end
    end
  end
  local want = name_key(short(who))
  local tantrum = best and best.tantrum == 1
  for k, t in pairs(env.tantrum or {}) do
    if name_key(short(k)) == want and now >= t and now - t <= win then tantrum = true end
  end
  if best then return trunc('toppled ' .. tostring(best.what or 'a building') .. (tantrum and ' in a tantrum' or ''), 40) end
  return tantrum and 'a tantrum' or nil
end

local function bound(c, cur)
  local keep = c.curse_keep or 60
  local n = 0
  for _ in pairs(cur.u) do n = n + 1 end
  if n <= keep then return end
  local list = {}
  for k, r in pairs(cur.u) do list[#list + 1] = {k = k, tf = r.tf == 1 and 1 or 0, t = num(r.t) or 0} end
  table.sort(list, function(a, b)
    if a.tf ~= b.tf then return a.tf < b.tf end        -- the transformed stay longest
    return a.t > b.t                                    -- then the newest
  end)
  for i = keep + 1, #list do cur.u[list[i].k] = nil end
end

local function queue(kind, rec)
  local q = S.q[kind]
  if not q then q = {}; S.q[kind] = q end
  if #q < 40 then q[#q + 1] = rec else q.more = (q.more or 0) + 1 end
end

-- a record for a unit (re-keyed from 'n:<name>' when the id is known now)
local function slot(cur, id, who)
  local nk = 'n:' .. name_key(who)
  local key = id and tostring(id) or nk
  local r = cur.u[key]
  if not r and id and cur.u[nk] then r = cur.u[nk]; cur.u[nk] = nil; cur.u[key] = r end
  return key, r
end

-- state `curse`: counts, the first ids (the transformed first) and the next full moon; nil when nobody is cursed.
-- BUG-136 (live i2: status said 'next full moon ~d77 (in 11 d)' at d101): the moon is computed when the state is
-- published (M.view), from the phase kept here, not frozen at the time the view was built
local function build_view(K, c, cur)
  local n, tfn = counts(cur)
  S.vbuilt = true
  if n + tfn == 0 then S.view = nil; return end
  local view = {n = n, tf = tfn, ids = (ids_of(cur, c.curse_ids or 8))}
  if cur.dead > 0 then view.dead = cur.dead end
  S.view, S.vmoon = view, {cycles = c.curse_moon_cycles, mt = num(cur.mt)}
end

---------------------------------------------------------------- reports
-- BUG-138 (live i2: CURSED d.ann=POPUP: a BOX announcement shows as a popup and pauses the game before its report reaches
-- kern): the announcement type of a popup's text: the type of a recent report with the same text, else the type DF 53.16
-- uses for it (live: DEITY_CURSE for "has been cursed by", BODY_TRANSFORMATION for "has transformed into")
M.LIVE_TYPES = {cursed = 'DEITY_CURSE', transform = 'BODY_TRANSFORMATION'}
function M.popup_type(text)
  local want = strip(utf(text))
  local found = rd(function()
    local reps = df.global.world.status.reports
    for i = #reps - 1, math.max(0, #reps - 50), -1 do
      local rep = reps[i]
      if strip(utf(rep.text)) == want then return df.announcement_type[rep.type] end
    end
  end)
  if type(found) == 'string' and found ~= '' then return found end
  local rec = M.parse(text)
  return rec and M.LIVE_TYPES[rec.kind] or 'POPUP'
end

-- BUG-175 (live i2: 8 BODY_TRANSFORMATION reports of one tick became TRANSFORM '1 were-form' at once and the other seven
-- 1199 ticks later, five of them dead by then, and curse_kill asked after the first): the other curse reports of the same
-- game time (report year and time) as report `id`, from the newest 60 reports: {id, text, type, pos}. A report without a
-- readable time has no wave
function M.wave(id)
  return rd(function()
    local reps = df.global.world.status.reports
    local lo, base = math.max(0, #reps - 60), nil
    for i = #reps - 1, lo, -1 do
      if reps[i].id == id and num(reps[i].time) then base = reps[i]; break end
    end
    local y, t = base and num(base.year), base and num(base.time)
    if not (y and t) then return {} end
    local out = {}
    for i = lo, #reps - 1 do
      local rep = reps[i]
      if rep.id ~= id and num(rep.year) == y and num(rep.time) == t then
        local text = utf(rep.text)
        if M.parse(text) then
          local ps = rep.pos
          out[#out + 1] = {id = rep.id, text = text, type = df.announcement_type[rep.type] or '?',
                           pos = ps and ps.x and ps.x >= 0 and {x = ps.x, y = ps.y, z = ps.z} or nil}
        end
      end
    end
    return out
  end, {})
end

-- a report: this one and the rest of its wave are recorded, then one flush sends them together (a report taken with an
-- earlier one's wave is not taken twice)
function M.report(K, c, p, ev, env)
  local rec = M.parse(ev.text)
  if not rec then return false end
  local rid = num(ev.id)
  S.seen = S.seen or {n = 0, ids = {}}
  if rid and S.seen.ids[rid] then return true end
  local batch = {ev}
  for _, o in ipairs(rid and M.wave(rid) or {}) do
    if not S.seen.ids[o.id] then o.tick = ev.tick; batch[#batch + 1] = o end
  end
  if S.seen.n > 400 then S.seen = {n = 0, ids = {}} end
  local cur = M.cur(p)
  for _, e in ipairs(batch) do
    local id2 = num(e.id)
    if id2 then S.seen.ids[id2] = true; S.seen.n = S.seen.n + 1 end
    M.take(K, c, p, cur, e, e == ev and rec or M.parse(e.text), env)
  end
  M.flush(K, c, p, env)
  build_view(K, c, cur)
  return true
end

-- one report's record and queue entry (M.report)
function M.take(K, c, p, cur, ev, rec, env)
  if not rec then return end
  local now = num(ev.tick) or K.now().tick
  local id = resolve(K, p, cur, env, rec.who)
  local key, r = slot(cur, id, rec.who)
  if rec.kind == 'cursed' then
    local fresh = r == nil
    r = r or {t = now}
    r.n, r.g, r.k, r.s, r.a = trunc(rec.who, 28), rec.god or r.g, rec.ctype, r.s or 'report', trunc(ev.type or '', 24)
    r.tr = r.tr or trigger(c, p, id, rec.who, now, env)
    r.tf = r.tf or 0
    cur.u[key] = r
    bound(c, cur)
    if fresh then queue('CURSED', {id = id, name = r.n, god = r.g, tr = r.tr, k = r.k, a = r.a, pos = ev.pos}) end
  else
    local fresh = r == nil
    r = r or {t = now, n = trunc(rec.who, 28), k = 'were', s = 'transform', a = trunc(ev.type or '', 24)}
    local beast = rec.dir == 'beast'
    local changed = fresh or (r.tf or 0) ~= (beast and 1 or 0)
    r.tf, r.tt, r.f = beast and 1 or 0, now, beast and rec.to or r.f
    if beast then r.k = 'were' end
    cur.u[key] = r
    bound(c, cur)
    if changed then
      -- the first transformation of a wave sets the moon's phase (the same wave's later ones are no news)
      if beast and (not num(cur.mt) or now - cur.mt > YEAR / (c.curse_moon_cycles or 13) / 2) then cur.mt = now end
      -- BUG-138: the type of THIS report (live 53.16: BODY_TRANSFORMATION), not the curse's (r.a, DEITY_CURSE)
      -- BUG-175: bitten = no curse report named him, or the game marks him by the bite's syndrome only (src syndrome)
      queue('TRANSFORM', {id = id, name = r.n, to = rec.to, dir = rec.dir, bite = beast and (fresh or r.s == 'syndrome'),
                          a = trunc(ev.type or '', 24), pos = ev.pos})
    end
  end
end

---------------------------------------------------------------- the unit scan
-- called by care for every citizen of its run: the sheet's curse and form (a unit cursed before the boot, a change nobody
-- announced, a transformation whose "back" text we never match). Queues like a report
function M.look(K, c, p, u, env)
  if rd(function() return dfhack.units.isDead(u) end, false) then return end    -- a dead were-form is no new curse
  local cur = M.cur(p)
  local key = tostring(u.id)
  local r = cur.u[key]
  local now = K.now().tick
  if not r then
    S.miss = S.miss or {}
    local sh = M.sheet(u, S.miss)
    for label in pairs(S.miss) do            -- BUG-135: a field this DF does not have is said once, not hidden
      S.warned = S.warned or {}
      if not S.warned[label] then S.warned[label] = true; K.log('warn', 'care curse: cannot read unit.%s', label) end
    end
    if not sh then return end
    -- BUG-176: the key from the whole name (a 28- or 40-byte cut never matched the report's name again); r.n is for display
    local full = short(env.nm(u))
    local name = trunc(full, 28)
    local old
    for _, k in ipairs(unit_keys(u, env)) do
      old = old or cur.u['n:' .. k]
      cur.u['n:' .. k] = nil
    end
    for _, nk in ipairs({'n:' .. name_key(full), 'n:' .. name_key(name)}) do    -- the 28-byte key of older saves too
      old = old or cur.u[nk]
      cur.u[nk] = nil
    end
    local src = sh.hid and 'syndrome' or 'sheet'
    if sh.vampire and not sh.were then
      r = {t = now, n = name, k = 'vampire', s = 'sheet', f = sh.name, tf = 0}
    else
      r = {t = old and old.t or now, n = name, k = sh.were and 'were' or '?', s = old and old.s or src,
           f = sh.form ~= '' and sh.form or sh.name, tf = 0, g = old and old.g, tr = old and old.tr, a = old and old.a}
    end
    cur.u[key] = r
    bound(c, cur)
    if not old then queue('CURSED', {id = u.id, name = name, k = r.k, a = src}) end
  end
  if r.k == 'vampire' then return end                    -- only a were-curse changes form
  local ri = race_info(u)
  if not ri then return end
  if r.k == '?' then
    if not ri.were then return end                        -- a curse of no known kind: nothing to track by the race
    r.k = 'were'
  end
  local tfn = ri.were and 1 or 0
  if ri.were then r.sw = 1 end                    -- the sheet's race shows the were-form for this unit: it may also say "back"
  if tfn ~= (r.tf or 0) and (ri.were or r.sw == 1) then
    local recent = r.tt and now >= r.tt and now - r.tt < 1200      -- a report said it a moment ago
    r.tf, r.tt = tfn, now
    if ri.were then r.f = ri.name end
    if not recent then
      queue('TRANSFORM', {id = u.id, name = r.n, to = ri.were and ri.name or 'its normal form', dir = ri.were and 'beast' or 'back',
                          a = 'sheet', bite = ri.were and r.s == 'syndrome' or nil})       -- BUG-175
      if ri.were and (not num(cur.mt) or now - cur.mt > YEAR / (c.curse_moon_cycles or 13) / 2) then cur.mt = now end
    end
  end
end

---------------------------------------------------------------- events
-- the dead leave the list (counted in `dead`); BUG-134 (live i1: a popup "Urist McTest has been cursed" kept 'CURSED 1'
-- for good): a record known by name only that no unit matched for one moon cycle expires (not counted as dead)
local function forget(K, c, cur)
  local gone = 0
  local now = K.now().tick
  local cyc = YEAR / math.max(1, num(c.curse_moon_cycles) or 13)
  for k, r in pairs(cur.u) do
    local id = num(k)
    if id then
      local u = df.unit.find(id)
      if not u or dfhack.units.isDead(u) then
        cur.u[k] = nil
        cur.dead = cur.dead + 1
        gone = gone + 1
      end
    elseif now - (num(r.t) or now) > cyc then
      cur.u[k] = nil
      K.log('info', 'care curse: "%s" matched no unit for a moon cycle: dropped', tostring(r.n))
    end
  end
  return gone
end

-- BUG-175: a queued transformation that no longer holds when it goes out: the unit died, or it is back in the other form
-- -> nil (keep) | 'dead' | 'reverted'
local function stale_entry(cur, e)
  if not e.id then return nil end
  local u = df.unit.find(e.id)
  if not u or rd(function() return dfhack.units.isDead(u) end, false) then return 'dead' end
  local r = cur.u[tostring(e.id)]
  if r and (r.tf == 1) ~= (e.dir == 'beast') then return 'reverted' end
  return nil
end

local function idlist(list, limit)
  local ids = {}
  for _, e in ipairs(list) do
    if e.id and #ids < limit then ids[#ids + 1] = e.id end
  end
  return ids
end

local function moon_txt(c, cur, tick)
  local day, mi = M.moon(tick, c.curse_moon_cycles, cur.mt)
  return day, mi, string.format('full moon ~d%d in %d d', day, mi)
end

local function emit_cursed(K, c, p, cur, list, more, env)
  local tick = K.now().tick
  local first = list[1]
  local n = counts(cur)
  local _, tfn = counts(cur)
  local day, mi, mtxt = moon_txt(c, cur, tick)
  local ids = idlist(list, c.curse_ids or 8)
  local msg
  if #list == 1 and more == 0 then
    msg = string.format('%s cursed%s%s; %d cursed in the fort, %s', first.name,
                        first.god and (' by ' .. first.god) or '', first.tr and (' (' .. first.tr .. ')') or '', n + tfn, mtxt)
  else
    local names = {}
    for i = 1, math.min(3, #list) do names[i] = list[i].name end
    msg = string.format('%d cursed: %s%s; %d cursed in the fort, %s', #list + more, table.concat(names, ', '),
                        #list > 3 and ' ...' or '', n + tfn, mtxt)
  end
  local d = {n = n + tfn, name = trunc(first.name, 40), moon = day, mi = mi}
  if first.id then d.unit = first.id end
  if first.god then d.god = first.god end
  if first.tr then d.trig = first.tr end
  if first.k then d.kind = first.k end
  if first.a and first.a ~= '' then d.ann = first.a end
  if #ids > 0 then d.ids = ids end
  if #list + more > 1 then d.more = #list + more - 1 end
  env.emit(K, 'CURSED', trunc(msg, 200), d)
end

local function emit_transform(K, c, p, cur, all, more, env)
  local list, died, back = {}, 0, 0
  for _, e in ipairs(all) do                     -- BUG-175: the dead and the reverted are no news of this wave
    local why = stale_entry(cur, e)
    if why == 'dead' then died = died + 1 elseif why == 'reverted' then back = back + 1 else list[#list + 1] = e end
  end
  if #list == 0 then
    K.log('info', 'care curse: %d queued transformation(s) dropped (%d died, %d changed back)', #all, died, back)
    return
  end
  local n, tfn = counts(cur)
  local first = list[1]
  local beasts = 0
  for _, e in ipairs(list) do if e.dir == 'beast' then beasts = beasts + 1 end end
  local msg
  if #list == 1 and more == 0 then
    if first.dir == 'beast' then
      msg = string.format('%s turned into a %s; %d were-form in the fort now', first.name, first.to or '?', tfn)
    else
      msg = string.format('%s is back in dwarf form; %d were-form in the fort now', first.name, tfn)
    end
  else
    local names = {}
    for i = 1, math.min(3, #list) do names[i] = list[i].name end
    msg = string.format('%d transformed (%d into beasts): %s%s; %d were-form in the fort now', #list + more, beasts,
                        table.concat(names, ', '), #list > 3 and ' ...' or '', tfn)
  end
  if died > 0 then msg = msg .. string.format(' (%d more died first)', died) end
  local d = {n = tfn, name = trunc(first.name, 40), dir = first.dir, cursed = n + tfn}
  if first.id then d.unit = first.id end
  if first.to then d.to = trunc(first.to, 24) end
  if first.a and first.a ~= '' then d.ann = first.a end
  if first.bite then d.bite = 1 end
  local ids = idlist(list, c.curse_ids or 8)
  if #ids > 0 then d.ids = ids end
  if #list + more > 1 then d.more = #list + more - 1 end
  env.emit(K, 'TRANSFORM', trunc(msg, 200), d)
  if beasts > 0 then M.kill_question(K, c, p, cur, env) end
end

-- the player's decision (RULES section 1: citizens are never killed on the kernel's own word): once per set of were-form units
-- BUG-134: a were-form unit known by name only (its id unresolved) is asked about too, by name
function M.kill_question(K, c, p, cur, env)
  local beasts, named = {}, {}
  for k, r in pairs(cur.u) do
    local id = num(k)
    if r.tf == 1 and id then beasts[#beasts + 1] = id
    elseif r.tf == 1 then named[#named + 1] = tostring(k) end
  end
  table.sort(beasts)
  table.sort(named)
  if #beasts + #named == 0 then return end
  local all = {}
  for _, id in ipairs(beasts) do all[#all + 1] = id end
  for _, k in ipairs(named) do all[#all + 1] = k end
  local T = K.now()
  -- BUG-174 (live i2: no curse_kill for the d77, d155 and d181 waves, each under 600 real s after the last question): the
  -- set of were-forms is the news and the game ticks the gate; a wall-clock gate is minutes of game at timestream speed
  if not CAD.due(cur.ev.kill, T, all, {'k'}, {ticks = c.curse_every * 4, wall_s = 0}) then return end
  cur.ev.kill = CAD.mark(T, all, {'k'})
  local shown = {}
  for i = 1, math.min(6, #all) do
    local id = all[i]
    shown[i] = math.type(id) == 'integer' and tostring(id) or (cur.u[id] and cur.u[id].n or tostring(id):sub(3))
  end
  beasts = all
  local q = string.format('%d were-form unit(s) in the fort (%s). A kill order only with your yes (squad.sortie, approve); '
                          .. 'otherwise they are kept apart in a locked room', #beasts, table.concat(shown, ','))
  env.emit(K, 'DECISION_NEEDED', trunc('curse_kill: ' .. q, 200), {id = 'curse_kill', q = trunc(q, 200), n = #beasts})
end

-- send what the cadence allows: at most one event per kind per `curse_every` ticks; the units that came in between wait in
-- the queue and go out together (with `more`)
function M.flush(K, c, p, env)
  local cur = M.cur(p)
  local now = K.now().tick
  if S.q.TRANSFORM and #S.q.TRANSFORM > 0 then forget(K, c, cur) end     -- BUG-175: counts without the dead
  for _, kind in ipairs({'CURSED', 'TRANSFORM'}) do
    local q = S.q[kind]
    if q and #q > 0 then
      local last = S.last[kind]
      if last == nil or now < last or now - last >= (c.curse_every or 600) then
        S.q[kind] = nil
        S.last[kind] = now
        local more = q.more or 0
        local ok, err = pcall(kind == 'CURSED' and emit_cursed or emit_transform, K, c, p, cur, q, more, env)
        if not ok then K.log('warn', 'care curse %s: %s', kind, tostring(err)) end
        K.persist.touch('m.care')
      end
    end
  end
end

---------------------------------------------------------------- the daily pass
-- the full moon is near and units are cursed: CURSE_MOON (A), once per moon and again for a new cursed unit (util/cadence)
local function moon_event(K, c, p, cur, env)
  local n, tfn = counts(cur)
  if n + tfn == 0 then return end
  local tick = K.now().tick
  local day, mi = M.moon(tick, c.curse_moon_cycles, cur.mt)
  if mi > (c.curse_moon_lead or 4) then return end
  local ids = ids_of(cur, 1000)
  local T = K.now()
  local toks = {'m' .. tostring(day)}
  -- BUG-174 (live i2: no CURSE_MOON for the moons within 600 real s of the last one, 60-100 s per moon at timestream
  -- speed): the moon day token limits it to one per moon, the tick gate to one per 4 x curse_every; no wall gate
  if not CAD.due(cur.ev.moon, T, ids_of(cur, 1000), toks, {ticks = c.curse_every * 4, wall_s = 0}) then return end
  cur.ev.moon = CAD.mark(T, ids_of(cur, 1000), toks)
  local shown = ids_of(cur, c.curse_ids or 8)
  env.emit(K, 'CURSE_MOON', trunc(string.format('full moon ~d%d in %d d: %d cursed (%s)%s; put them in one locked room now', day, mi,
                                                n + tfn, table.concat(shown, ','), #ids > #shown and ' ...' or ''), 200),
         {moon = day, mi = mi, n = n + tfn, ids = shown})
end

-- the run's end (care.finish): forget the dead, emit what is due, the state view. `s0` = stress category 0 collected by the scan
function M.finish(K, c, p, env)
  local cur = M.cur(p)
  local named = {}
  for k in pairs(cur.u) do if k:sub(1, 2) == 'n:' then named[#named + 1] = k end end
  for _, k in ipairs(named) do                -- a record kept by name: the unit may be known by now
    local r = cur.u[k]
    local id = resolve(K, p, cur, env, k:sub(3))      -- BUG-176: the whole name's key, not the 28-byte display name
    if id then
      cur.u[k] = nil
      if not cur.u[tostring(id)] then cur.u[tostring(id)] = r end     -- a duplicate of a unit's record is dropped
    end
  end
  forget(K, c, cur)
  M.flush(K, c, p, env)
  local okm, errm = pcall(moon_event, K, c, p, cur, env)
  if not okm then K.log('warn', 'care curse moon: %s', tostring(errm)) end
  build_view(K, c, cur)
  K.persist.touch('m.care')
end

-- BUG-136 (live i2: care's full run came every 10-31 game days under pacing and demotion, so the d77 wave went unseen
-- and CURSE_MOON never came; the 4-day window is shorter than the run): the daily pass on care's own `watch` clock
-- (kern: never paced, never demoted, §3.2): the form of the known cursed, the citizens the game marks as were-cursed
-- (curse_year set: M.sheet decides), then forget, the moon, the view. A few field reads per citizen.
function M.watch(K, c, p, env)
  local cur = M.cur(p)
  local ids, seen = {}, {}
  for k in pairs(cur.u) do
    local id = num(k)
    if id then ids[#ids + 1] = id; seen[id] = true end
  end
  for _, id in ipairs(own_ids(K)) do
    if not seen[id] then
      local u = df.unit.find(id)
      local cy = u and num(rd(function() return u.curse_year end))
      if cy and cy >= 0 then ids[#ids + 1] = id; seen[id] = true end
    end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) then
      local ok, err = pcall(M.look, K, c, p, u, env)
      if not ok then K.log('warn', 'care curse watch %d: %s', id, tostring(err)) end
    end
  end
  M.finish(K, c, p, env)
end

-- the state view with the moon of now (K given) or of the last build (no K: old callers). BUG-172 (live i2: no `curse` in
-- the state for 27 game days after a reload, across a transformation and a death): with c and p (care's config and
-- persist) a view not built since the boot is built from the persisted records at once
M.built = function() return S.vbuilt == true end
function M.view(K, c, p)
  if not S.vbuilt and type(c) == 'table' and type(p) == 'table' then
    local okb, errb = pcall(build_view, K, c, M.cur(p))
    if not okb then S.vbuilt = true; K.log('warn', 'care curse view: %s', tostring(errb)) end
  end
  local v = S.view
  if not v then return nil end
  local out = {}
  for k, x in pairs(v) do out[k] = x end
  local vm = S.vmoon or {}
  local ok, now = pcall(function() return K.now().tick end)
  if ok and math.type(now) == 'integer' then out.mo, out.mi = M.moon(now, vm.cycles, vm.mt) end
  return out
end

---------------------------------------------------------------- inspect
-- inspect what=curse: the whole list (bounded by curse_keep), the moon and the counts
function M.inspect_curse(K, c, p)
  local cur = M.cur(p)
  local n, tfn = counts(cur)
  local day, mi = M.moon(K.now().tick, c.curse_moon_cycles, cur.mt)
  local list, un = {}, {}
  for k, r in pairs(cur.u) do
    local id = num(k)
    list[#list + 1] = {id = id, name = r.n, god = r.g, kind = r.k, form = r.f, tf = r.tf == 1 and 1 or 0, since = r.t, tt = r.tt,
                       src = r.s, trig = r.tr, ann = r.a}
    if not id and #un < 8 then un[#un + 1] = trunc(r.n, 28) end     -- BUG-134: known by name only (no unit matched yet)
  end
  table.sort(un)
  table.sort(list, function(a, b)
    if a.tf ~= b.tf then return a.tf > b.tf end
    return (a.since or 0) < (b.since or 0)
  end)
  while #list > 40 do table.remove(list) end
  local msg = string.format('curse: %d cursed, %d in were-form, %d dead; full moon ~d%d in %d d%s%s', n, tfn, cur.dead, day, mi,
                            num(cur.mt) and '' or ' (an estimate: no transformation seen yet)',
                            #un > 0 and string.format('; %d by name only (no unit matched): %s', #un, table.concat(un, ', ')) or '')
  local d = {cursed = n, transformed = tfn, dead = cur.dead, moon = day, mi = mi, calibrated = num(cur.mt) and 1 or 0, units = list}
  if #un > 0 then d.unresolved = un end
  return true, trunc(msg, 300), d
end

---------------------------------------------------------------- inspect what=unit (FR-83): what the unit sheet shows
-- by id, or by name (BUG-134/137: without the nickname, with it typed or not; the first name alone when one unit has it)
local function find_unit(K, p, key, env)
  local id = num(key)
  if id then
    local u = df.unit.find(id)
    if u and not ours(u) then return nil, id, nil, true end
    return u, id
  end
  local k = name_key(short(key))
  local single = not k:find(' ', 1, true)
  local hits, firsts = {}, {}
  for _, uid in ipairs(own_ids(K)) do
    local u = df.unit.find(uid)
    if u then
      local hit, first = false, false
      for _, nk in ipairs(unit_keys(u, env)) do        -- BUG-173: the sheet name and the real first + last name
        if nk == k then hit = true
        elseif single and (nk:match('^(%S+)') or '') == k then first = true end
      end
      if hit then hits[#hits + 1] = uid elseif first then firsts[#firsts + 1] = uid end
    end
  end
  if #hits == 0 then hits = firsts end
  if #hits == 1 then return df.unit.find(hits[1]), hits[1] end
  return nil, nil, hits
end

local function name_of(hfid)
  return rd(function()
    local hf = df.historical_figure.find(hfid)
    if not hf then return nil end
    return trunc(dfhack.df2utf(dfhack.translation.translateName(hf.name, false)), 28)
  end)
end

local LINKS = {SPOUSE = 'spouse', MOTHER = 'mother', FATHER = 'father', CHILD = 'child', LOVER = 'lover',
           COMPANION = 'companion', DECEASED_SPOUSE = 'late spouse'}

-- BUG-137 (live i2: 'unread':['thoughts','wounds'] for every living unit): the emotions are a 0-based DF vector; an
-- emotion without a thought (-1) names its emotion type. BUG-173 (live i2: every list began with 'ANYTHING'): the empty
-- slots (type ANYTHING, or no thought and strength 0) are skipped, and the vector is not in time order: newest first by
-- (year, year_tick), the vector index breaking ties (the later the newer)
local function thoughts_of(u)
  local out, seen, list = {}, {}, {}
  local vec = u.status.current_soul.personality.emotions
  for i = 0, #vec - 1 do
    local e = vec[i]
    local th = num(rd(function() return e.thought end))
    local et = rd(function() return df.emotion_type[e.type] end)
    local str = num(rd(function() return e.strength end))
    local empty = et == 'ANYTHING' or ((th == nil or th < 0) and str == 0)
    local nm = th and th >= 0 and df.unit_thought_type[th] or nil
    if not nm then nm = et end
    if nm and not empty then
      list[#list + 1] = {nm = tostring(nm), y = num(rd(function() return e.year end)) or -1,
                         t = num(rd(function() return e.year_tick end)) or -1, i = i}
    end
  end
  table.sort(list, function(a, b)
    if a.y ~= b.y then return a.y > b.y end
    if a.t ~= b.t then return a.t > b.t end
    return a.i > b.i
  end)
  for _, e in ipairs(list) do
    if not seen[e.nm] then
      seen[e.nm] = true
      out[#out + 1] = e.nm
      if #out >= 6 then break end
    end
  end
  return out
end

-- BUG-137: unit_wound has no `bleeding`; a wound bleeds when one of its parts does (wd.parts[j].bleeding)
local function wounds_of(u)
  local list = u.body.wounds
  local bleeding = 0
  for _, wd in ipairs(list) do
    for _, pt in ipairs(wd.parts) do
      if (num(pt.bleeding) or 0) > 0 then bleeding = bleeding + 1; break end
    end
  end
  return {n = #list, bleed = bleeding}
end

function M.inspect_unit(K, c, p, key, env)
  if key == nil or tostring(key) == '' then return false, 'inspect what=unit needs key=<unit id or name>' end
  local u, id, hits, foreign = find_unit(K, p, key, env)
  if not u then
    if foreign then return false, 'unit ' .. tostring(id) .. ' is not a citizen or resident of the fort' end
    if hits and #hits > 1 then
      return false, string.format('%d citizens share that name (%s): use the id', #hits, table.concat(hits, ','))
    end
    return false, 'no such citizen: ' .. trunc(key, 40)
  end
  local miss = {}
  local function get(label, f, default)
    local ok, v = pcall(f)
    if ok and v ~= nil then return v end
    miss[#miss + 1] = label
    return default
  end
  local d = {id = id, name = trunc(env.nm(u), 40)}
  d.prof = get('prof', function() return trunc(dfhack.units.getProfessionName(u), 24) end, nil)
  d.dead = rd(function() return dfhack.units.isDead(u) end, false) and 1 or 0
  local stress = get('stress', function() return u.status.current_soul.personality.stress end, nil)
  local cat = get('cat', function() return dfhack.units.getStressCategory(u) end, nil)
  if math.type(stress) == 'integer' then d.stress = stress end
  if math.type(cat) == 'integer' then d.cat = cat; d.level = M.STRESS[cat] end
  local mood = rd(function() return u.mood >= 0 and df.mood_type[u.mood] or nil end)     -- BUG-137: -1 is no mood
  if mood then d.mood = mood end
  for k, t in pairs(env.tantrum or {}) do
    if name_key(short(k)) == name_key(short(env.nm(u))) then d.tantrum_ago = math.max(0, K.now().tick - t) end
  end
  local th = get('thoughts', function() return thoughts_of(u) end, nil)      -- the last thoughts, newest first
  if th then d.thoughts = th end
  -- curse and form (the sheet's own words)
  local smiss = {}
  local sh = M.sheet(u, smiss)
  for label in pairs(smiss) do miss[#miss + 1] = label end
  local cur = M.cur(p)
  local rec = cur.u[tostring(id)]
  if sh or rec then
    d.curse = {name = sh and sh.name ~= '' and sh.name or nil, form = sh and sh.form ~= '' and sh.form or (rec and rec.f) or nil,
               were = ((sh and sh.were) or (rec and rec.k == 'were')) and 1 or nil,
               tf = ((sh and sh.tf) or (rec and rec.tf == 1)) and 1 or 0, god = rec and rec.g or nil,
               since = rec and rec.t or nil, trig = rec and rec.tr or nil}
  end
  local w = get('wounds', function() return wounds_of(u) end, nil)
  if w then d.wound = w end
  local bc, bm = rd(function() return num(u.body.blood_count) end), rd(function() return num(u.body.blood_max) end)
  -- BUG-173 (live: a dead unit showed blood_pct -1): only a living unit with a readable blood count
  if d.dead ~= 1 and bc and bm and bm > 0 and bc >= 0 then d.blood_pct = math.min(100, bc * 100 // bm) end
  -- job and place
  local job = rd(function() return df.job_type[u.job.current_job.job_type] end)
  d.job = job or 'none'
  local okp, x, y, z = pcall(dfhack.units.getPosition, u)
  if okp and x then d.pos = {x, y, z} end
  -- family and companions from the historical figure's links (the sheet's relationships)
  local fam = get('relatives', function()
    local hf = df.historical_figure.find(u.hist_figure_id)
    local out = {}
    if not hf then return out end
    for _, l in ipairs(hf.histfig_links) do
      local nm = df.histfig_hf_link_type[l:getType()]
      local role = nm and LINKS[nm]
      if role and #out < 8 then
        out[#out + 1] = {role = role, hf = l.target_hf, name = name_of(l.target_hf)}
      end
    end
    return out
  end, nil)
  if fam then d.rel = fam end
  if #miss > 0 then d.unread = miss end
  local msg = string.format('unit %d %s%s: %s%s%s, job %s%s', id, d.name, d.dead == 1 and ', DEAD' or '',
                            d.level and ('stress ' .. d.level .. ' (' .. tostring(d.cat) .. ')') or 'stress ?',
                            d.mood and (', mood ' .. d.mood) or '', d.curse and (d.curse.tf == 1 and ', WERE-FORM' or ', cursed') or '',
                            d.job, d.wound and (', wounds ' .. d.wound.n) or '')
  return true, trunc(msg, 200), d
end

return M
