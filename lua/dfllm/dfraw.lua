-- dfraw: NEU3 diagnostics. The raw fields the game keeps about a manager order, a job, an item need and the manager, printed WITHOUT interpretation
-- (`inspect what=raw key=<order:ID | brew | job:ID | items:<logs|plants|barrels|VECTOR> | manager>`, CLI `dfpilot why <key> --raw`), and the
-- compact discriminator line the stall watches log (R.stall_line). A library like jobwhy: it only READS game state, writes nothing, cures nothing.
--
-- docs/v2/NEU3-diagnose.md: the hypotheses H1..H8 and the line of a dump that confirms or refutes each.
--
-- No DF structure source is installed next to the game (only symbols.xml), so no field name here is taken on trust: every read goes through pcall,
-- an unreadable field prints "?" (never 0, never an error), and each struct is also dumped generically (`pairs`) so that the real field names show
-- up even where a name below is wrong. Output is bounded: R.MAX_LINES lines of R.LINE characters, vectors shown with their first few elements.
local JW = require('dfllm.jobwhy')
local json = require('dfllm.util.json')
local PL = require('dfllm.pilelib')      -- NEU5 BUG-848: the barrel limit field, version tolerant
local U = JW.util
local int, pget, ename, each, uname = U.int, U.pget, U.ename, U.each, U.uname

local R = {}
R.MAX_LINES = 140             -- lines of one dump
R.LINE = 290                  -- characters of one line
R.ITEMS_MAX = 6000            -- item records scanned by an items dump
R.POS_MAX = 3000              -- items whose tile is checked (walk group, hidden)
R.HOLDERS_MAX = 30            -- holders listed one by one
R.SHOPS_MAX = 6               -- workshops dumped per order / kind
R.JOBS_MAX = 12               -- jobs listed per workshop
R.ORDERS_MAX = 8              -- orders dumped by `brew`
R.ORDERS_DETAIL = 2           -- NEU4 BUG-846: of them in full (shops and holders); the rest one compact block, the shops summarized
R.PAGE_BYTES = 6000           -- NEU4 BUG-846: one reply page (the kernel sends no data over 8 KB: the page stays well under)
R.SAMPLE_MAX = 10             -- NEU4 BUG-843: items of an items dump described one by one

---------------------------------------------------------------- values
local function clip(s, n) s = tostring(s); return #s > n and (s:sub(1, n - 1) .. '~') or s end
local describe

-- the entries of a table / struct / vector: {{k, v}, ...}; nil when it cannot be iterated
local function entries(v, cap)
  local out = {}
  local ok = pcall(function()
    for k, x in pairs(v) do
      out[#out + 1] = {k, x}
      if #out >= (cap or 40) then break end
    end
  end)
  if not ok then return nil end
  return out
end

-- a bitfield / flags table as '[a,b]' (the names that are true), '?' when unreadable
local function FL(v)
  if v == nil then return '?' end
  local e = entries(v, 200)
  if not e then return '?' end
  local names = {}
  for _, kv in ipairs(e) do
    if kv[2] == true then names[#names + 1] = tostring(kv[1]) end
  end
  table.sort(names)
  return '[' .. table.concat(names, ',') .. ']'
end

-- any value as short text; depth 0 expands one level of struct
function describe(v, depth)
  local t = type(v)
  if t == 'nil' then return '?' end
  if t == 'boolean' or t == 'number' then return tostring(v) end
  if t == 'string' then return clip(v, 200) end
  if t ~= 'table' and t ~= 'userdata' then return '<' .. t .. '>' end
  local okn, n = pcall(function() return #v end)
  if okn and type(n) == 'number' and n > 0 then               -- a vector: its first elements
    local parts = {}
    for i = 1, math.min(n, 8) do
      local ok, x = pcall(function() return v[i - 1] end)       -- DF vectors are 0-based, a Lua list is 1-based
      if not ok or x == nil then ok, x = pcall(function() return v[i] end) end
      parts[#parts + 1] = ok and (type(x) == 'table' or type(x) == 'userdata') and '<s>' or ok and tostring(x) or '?'
    end
    return 'vec' .. n .. '(' .. table.concat(parts, ',') .. (n > 8 and ',..' or '') .. ')'
  end
  local e = entries(v, 40)
  if not e then return '<?>' end
  if #e == 0 then return '[]' end
  local allb, anytrue = true, false
  for _, kv in ipairs(e) do
    if type(kv[2]) ~= 'boolean' then allb = false elseif kv[2] then anytrue = true end
  end
  if allb then return FL(v) end
  local parts = {}
  for _, kv in ipairs(e) do
    local x = kv[2]
    local s
    if type(x) == 'table' or type(x) == 'userdata' then s = (depth or 0) > 0 and '<s>' or describe(x, 1) else s = describe(x, 1) end
    parts[#parts + 1] = tostring(kv[1]) .. '=' .. s
    if #parts >= 14 then parts[#parts + 1] = '..'; break end
  end
  return '{' .. table.concat(parts, ' ') .. '}'
end

-- the text of a field read: '?' when the read raises or gives nothing
local function V(f)
  local ok, v = pcall(f)
  if not ok or v == nil then return '?' end
  return describe(v, 0)
end
local function N(f)                       -- a number or nil
  local ok, v = pcall(f)
  if ok then return int(v) end
end
-- number with the enum's name: '12(MakeBarrel)'
local function E(enum, f)
  local ok, v = pcall(f)
  if not ok or v == nil then return '?' end
  local n = int(v)
  local name = n and enum and ename(enum, n)
  return tostring(v) .. (name and ('(' .. name .. ')') or '')
end

-- a line buffer with the bounds
local function buf() return {l = {}, clipped = false} end
local function add(b, s)
  if #b.l >= R.MAX_LINES then b.clipped = true; return end
  b.l[#b.l + 1] = clip(s, R.LINE)
end
-- every field of a struct, generically (the real names), in at most `lines` lines
local function dump_struct(b, label, s, lines)
  if s == nil then add(b, label .. ' ?'); return end
  local e = entries(s, 80)
  if not e then add(b, label .. ' <unreadable>'); return end
  table.sort(e, function(x, y) return tostring(x[1]) < tostring(y[1]) end)
  local cur, n = label, 0
  for _, kv in ipairs(e) do
    local piece = ' ' .. tostring(kv[1]) .. '=' .. describe(kv[2], 1)
    if #cur + #piece > R.LINE - 4 then
      add(b, cur); n = n + 1; cur = label .. '+'
      if n >= (lines or 3) then return end
    end
    cur = cur .. piece
  end
  add(b, cur)
end

local function posb(b)
  local x1, y1, x2, y2, z = N(function() return b.x1 end), N(function() return b.y1 end), N(function() return b.x2 end), N(function() return b.y2 end),
                            N(function() return b.z end)
  if not (x1 and y1 and x2 and y2 and z) then return '?' end
  return string.format('%d,%d,%d box %d-%d,%d-%d', (x1 + x2) // 2, (y1 + y2) // 2, z, x1, x2, y1, y2)
end

---------------------------------------------------------------- the citizens and walk groups
local function citizens(K)
  local cu = K.census and K.census.u
  return type(cu) == 'table' and type(cu.ids) == 'table' and cu or nil
end

-- the walk group most citizens stand in: {group, n, of}; nil when unknown
function R.main_group(K)
  local cu = citizens(K)
  if not cu then return nil end
  local pts, who = {}, {}
  for _, id in ipairs(cu.ids) do
    local u = pget(df.unit.find, id)
    if u and #pts < 60 then pts[#pts + 1] = {u.pos.x, u.pos.y, u.pos.z}; who[#pts] = id end
  end
  local g = U.walk_groups(K, pts)
  if not g then return nil end
  local cnt, best = {}, nil
  for _, x in ipairs(g) do
    if int(x) and x > 0 then
      cnt[x] = (cnt[x] or 0) + 1
      if not best or cnt[x] > cnt[best] then best = x end
    end
  end
  return best and {group = best, n = cnt[best], of = #pts} or nil
end

---------------------------------------------------------------- the workshop
-- one workshop: header, building flags, profile, jobs, stockpile links
function R.shop(K, b, bld, detail)
  local id = N(function() return bld.id end)
  local s = pget(JW.shop, bld, K) or {}
  local jobs = each(pget(function() return bld.jobs end))
  local decon = false
  for _, j in ipairs(jobs) do
    local tn = ename(df.job_type, N(function() return j.job_type end) or -1)
    if tn == 'DestroyBuilding' then decon = true end
  end
  local gs = {}
  for g in pairs(s.groups or {}) do gs[#gs + 1] = g end
  table.sort(gs)
  add(b, string.format('ws %s %s at %s stage %s/%s flags=%s forbid_flag=%s deconstructing=%s walk_groups=%s burrow_limits=%s', tostring(id), tostring(s.key or '?'),
                       posb(bld), V(function() return bld:getBuildStage() end), V(function() return bld:getMaxBuildStage() end),
                       V(function() return FL(bld.flags) end), V(function() return bld.flags.forbidden end), tostring(decon),
                       #gs > 0 and table.concat(gs, ',') or '?', s.lim and #s.lim > 0 and table.concat(s.lim, ',') or 'none'))
  if not detail then return s end
  local pr = pget(function() return bld.profile end)
  if pr then
    local pw = each(pget(function() return pr.permitted_workers end))
    local ids = {}
    for i = 1, math.min(#pw, 12) do ids[#ids + 1] = tostring(pw[i]) end
    add(b, string.format('  profile: max_general_orders=%s min_level=%s max_level=%s permitted_workers=%d%s blocked_labors=%s', V(function() return pr.max_general_orders end),
                         V(function() return pr.min_level end), V(function() return pr.max_level end), #pw, #pw > 0 and (' [' .. table.concat(ids, ',') .. (#pw > 12 and ',..' or '') .. ']') or ' (none listed: all)',
                         V(function() return pr.blocked_labors end)))
  else
    add(b, '  profile: ?')
  end
  add(b, string.format('  jobs: %d (the shop takes at most %d)', #jobs, JW.SHOP_MAX_JOBS))
  for i, j in ipairs(jobs) do
    if i > R.JOBS_MAX then add(b, '  ... ' .. (#jobs - R.JOBS_MAX) .. ' more'); break end
    local w = pget(dfhack.job.getWorker, j)
    add(b, string.format('  job %s %s flags=%s order=%s worker=%s completion=%s repeat=%s', V(function() return j.id end), E(df.job_type, function() return j.job_type end),
                         V(function() return FL(j.flags) end), V(function() return j.order_id end), w ~= nil and tostring(pget(function() return w.id end) or '?') or 'none',
                         V(function() return j.completion_timer end), V(function() return j.flags['repeat'] end)))
  end
  local function ids(f)
    local out = {}
    for _, x in ipairs(each(pget(f))) do out[#out + 1] = tostring(pget(function() return x.id end) or x) end
    return #out > 0 and table.concat(out, ',') or 'none'
  end
  add(b, string.format('  links: give_to_pile=%s take_from_pile=%s give_to_workshop=%s take_from_workshop=%s', ids(function() return bld.profile.links.give_to_pile end),
                       ids(function() return bld.profile.links.take_from_pile end), ids(function() return bld.profile.links.give_to_workshop end),
                       ids(function() return bld.profile.links.take_from_workshop end)))
  return s
end

---------------------------------------------------------------- the holders of a labor
local UNIT_FLAG_WORDS = {inactive = true, caged = true, chained = true, left = true, incoming = true, merchant = true, diplomat = true, forest = true,
                         invader_origin = true, hidden_in_ambush = true, projectile = true, on_ground = true, move_state = true}
-- the citizens holding any of `labors` at workshop `s`: {n, by = {status = n}, lines = {...}}
function R.holders(K, labors, sk, s, ctx)
  local cu = citizens(K)
  local out = {n = 0, by = {}, lines = {}, known = cu ~= nil, total = cu and #cu.ids or nil}
  if not cu then return out end
  local sold = {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  local civ = U.civ_burrows()
  local main = R.main_group(K)
  out.civ, out.main = civ, main
  local at = s and s.at
  local uni, ids, helds = {}, {}, {}
  for _, id in ipairs(cu.ids) do
    local u = pget(df.unit.find, id)
    if u then
      local held
      for _, l in ipairs(labors or {}) do
        if pget(function() return u.status.labors[l] end) == true then held = l; break end
      end
      if held ~= nil then uni[#uni + 1] = u; ids[#ids + 1] = {u.pos.x, u.pos.y, u.pos.z}; helds[#uni] = held end
    end
  end
  local ug = U.walk_groups(K, ids) or {}
  for i, u in ipairs(uni) do
    out.n = out.n + 1
    local cj = pget(function() return u.job.current_job end)
    local mine = {}
    pcall(function() for _, bid in ipairs(u.burrows) do mine[#mine + 1] = bid end end)
    local own, civin, same            -- true / false / nil = unknown (never `a and b or nil`: false would turn into nil)
    if #mine > 0 and at then own = U.in_burrows(mine, at) end
    if civ and at then civin = U.in_burrows(civ, at) end
    local g = ug[i]
    if s and s.groups and int(g) and g > 0 then same = s.groups[g] == true end
    local st = 'free'
    local pr, prwhy = s and s.prof, nil                      -- the workshop profile keeps him out (H4)
    if pr then
      if pr.permit and not pr.permit[u.id] then prwhy = 'not on the permitted list'
      elseif pr.blocked ~= nil and pget(function() return pr.blocked[helds[i]] end) == true then prwhy = 'labor blocked there'
      elseif sk and pr.minl and pr.maxl and (pr.minl > 0 or pr.maxl < 3000) then
        local lv = int(pget(dfhack.units.getNominalSkill, u, sk, true))
        if lv and (lv < pr.minl or lv > pr.maxl) then prwhy = 'skill ' .. lv .. ' outside ' .. pr.minl .. '-' .. pr.maxl end
      end
    end
    if int(pget(function() return u.mood end)) and u.mood >= 0 then st = 'mood'
    elseif sold[u.id] then st = 'soldier'
    elseif prwhy then st = 'profile'
    elseif own == false then st = 'burrow_own'
    elseif civin == false then st = 'burrow_civ'
    elseif same == false then st = 'far'
    elseif cj ~= nil then st = 'busy'
    elseif dfhack.units.isJobAvailable and pget(dfhack.units.isJobAvailable, u) == false then st = 'unavailable' end
    out.by[st] = (out.by[st] or 0) + 1
    if #out.lines < R.HOLDERS_MAX then
      local fl1 = {}
      for _, kv in ipairs(entries(pget(function() return u.flags1 end) or {}, 200) or {}) do
        if kv[2] == true and UNIT_FLAG_WORDS[tostring(kv[1])] then fl1[#fl1 + 1] = tostring(kv[1]) end
      end
      out.lines[#out.lines + 1] = string.format('  holder %s %s job=%s burrows=%s in_own_burrow_with_shop=%s civ_alert=%s in_civ_burrow=%s walk_group=%s same_as_shop=%s squad=%s soldier=%s '
                                                .. 'mood=%s flags=[%s] child_or_baby=%s job_available=%s status=%s%s',
        tostring(u.id), clip(uname(u), 22), cj ~= nil and (ename(df.job_type, N(function() return cj.job_type end) or -1) or '?') or 'none',
        #mine > 0 and table.concat(mine, ',') or 'none', own == nil and (#mine > 0 and '?' or 'n/a') or tostring(own),
        civ and table.concat(civ, ',') or 'off', civ and (civin == nil and '?' or tostring(civin)) or 'n/a',
        tostring(int(g) or '?'), same == nil and '?' or tostring(same), V(function() return u.military.squad_id end), tostring(sold[u.id] == true),
        V(function() return u.mood end), table.concat(fl1, ','),
        tostring(pget(function() return dfhack.units.isChild(u) or dfhack.units.isBaby(u) end) or false),
        tostring(pget(dfhack.units.isJobAvailable or function() return nil end, u)), st, prwhy and (' (' .. prwhy .. ')') or '')
    end
  end
  return out
end

local function holders_head(b, labors, w, s)
  local names = {}
  for _, l in ipairs(labors or {}) do names[#names + 1] = ename(df.unit_labor, l) or tostring(l) end
  local parts = {}
  for k, n in pairs(w.by) do parts[#parts + 1] = k .. '=' .. n end
  table.sort(parts)
  add(b, string.format('labor %s: %d holder(s)%s [%s]; citizens\' main walk group %s; civ alert burrows %s', #names > 0 and table.concat(names, '|') or '? (no labor derived)', w.n,
                       w.total and string.format(' of %d citizens', w.total) or '', table.concat(parts, ' '), w.main and (w.main.group .. ' (' .. w.main.n .. '/' .. w.main.of .. ' sampled)') or '?',
                       w.civ and table.concat(w.civ, ',') or 'off'))
  for _, l in ipairs(w.lines) do add(b, l) end
  if w.n > #w.lines then add(b, '  ... ' .. (w.n - #w.lines) .. ' more holders') end
end

---------------------------------------------------------------- the order
local function order_head(b, o)
  local jt = N(function() return o.job_type end)
  add(b, string.format('order %s job_type=%s reaction=%s amount_left=%s amount_total=%s status=%s frequency=%s workshop_id=%s mat_type=%s mat_index=%s material_category=%s '
                       .. 'item_subtype=%s max_workshops=%s conditions=%s', V(function() return o.id end), E(df.job_type, function() return o.job_type end),
                       V(function() return o.reaction_name end), V(function() return o.amount_left end), V(function() return o.amount_total end),
                       V(function() return FL(o.status) end), V(function() return o.frequency end), V(function() return o.workshop_id end),
                       V(function() return o.mat_type end), V(function() return o.mat_index end), V(function() return FL(o.material_category) end),
                       V(function() return o.item_subtype end), V(function() return o.max_workshops end), tostring(#each(pget(function() return o.item_conditions end)))))
  dump_struct(b, '  fields:', o, 3)
  for i, c in ipairs(each(pget(function() return o.item_conditions end))) do
    add(b, string.format('  cond %d: compare=%s value=%s item_type=%s subtype=%s mat=%s,%s flags1=%s flags2=%s flags3=%s reaction_class=%s product=%s min_dim=%s', i,
                         V(function() return c.compare_type or c.condition end), V(function() return c.compare_val or c.value end),
                         E(df.item_type, function() return c.item_type end), V(function() return c.item_subtype end), V(function() return c.mat_type end),
                         V(function() return c.mat_index end), V(function() return FL(c.flags1) end), V(function() return FL(c.flags2) end),
                         V(function() return FL(c.flags3) end), V(function() return c.reaction_class end), V(function() return c.has_material_reaction_product end),
                         V(function() return c.min_dimension end)))
    dump_struct(b, '    cond' .. i .. ':', c, 2)
  end
  return jt
end

-- the workshops that could take order `o`: the pinned one and every workshop of the order's kind
local function order_shops(o)
  local tn = ename(df.job_type, N(function() return o.job_type end) or -1) or '?'
  local rn = pget(function() return o.reaction_name end)
  local keys = JW.shop_keys(tn, rn, pget(function() return o.mat_type end), pget(function() return o.mat_index end))
  local want = {}
  for _, k in ipairs(keys or {}) do want[k] = true end
  local pin = N(function() return o.workshop_id end)
  local out, seen = {}, {}
  for _, bld in ipairs(U.shops_all()) do
    local id = N(function() return bld.id end)
    local s = pget(JW.shop, bld, nil)
    if id and not seen[id] and ((s and s.key and want[s.key]) or (pin and pin >= 0 and id == pin)) then seen[id] = true; out[#out + 1] = bld end
  end
  table.sort(out, function(x, y) return (N(function() return x.id end) or 0) < (N(function() return y.id end) or 0) end)
  return out, keys, pin
end

function R.order(K, o, ctx, b, shown, compact, max_full)
  b = b or buf()
  shown = shown or {}
  if compact then                                    -- NEU4: the head in one line, the shops by id only
    local jt = N(function() return o.job_type end)
    local _, keys, pin = order_shops(o)
    add(b, string.format('order %s %s reaction=%s left=%s/%s status=%s workshop_id=%s conditions=%d shops=%s', V(function() return o.id end), E(df.job_type, function() return o.job_type end),
                         V(function() return o.reaction_name end), V(function() return o.amount_left end), V(function() return o.amount_total end),
                         V(function() return FL(o.status) end), V(function() return o.workshop_id end), #each(pget(function() return o.item_conditions end)),
                         keys and table.concat(keys, '|') or '?'))
    return b
  end
  order_head(b, o)
  local shops, keys, pin = order_shops(o)
  add(b, string.format('  shops for this order: %s%s', keys and table.concat(keys, '|') or '? (job type not in the kernel table)', pin and pin >= 0 and (' ; pinned to workshop ' .. pin) or ''))
  if pin and pin >= 0 and not pget(df.building.find, pin) then add(b, '  pinned workshop ' .. pin .. ' does not exist') end
  for i, bld in ipairs(shops) do
    if i > R.SHOPS_MAX then add(b, '  ... ' .. (#shops - R.SHOPS_MAX) .. ' more workshops'); break end
    local id = N(function() return bld.id end)
    if shown[id] then add(b, '  ws ' .. tostring(id) .. ' (shown above)')
    else
      shown[id] = true
      if max_full and i > max_full then R.shop(K, b, bld, false); goto next_shop end      -- NEU4 BUG-846: the other shops one line each
      local s = R.shop(K, b, bld, true)
      local jt = N(function() return o.job_type end)
      local labors, sk = JW.labors(jt, pget(function() return o.reaction_name end), pget(function() return o.mat_type end), pget(function() return o.mat_index end), s and s.key)
      if labors then holders_head(b, labors, R.holders(K, labors, sk, s, ctx), s) end
    end
    ::next_shop::
  end
  return b
end

function R.brew(K, ctx)
  local b = buf()
  local orders = {}
  for _, o in ipairs(each(pget(function() return df.global.world.manager_orders.all end))) do
    local tn = ename(df.job_type, N(function() return o.job_type end) or -1) or '?'
    if JW.KINDS.brew(tn, pget(function() return o.reaction_name end)) or tn == 'BrewDrink' then orders[#orders + 1] = o end
  end
  local ids = {}
  for _, o in ipairs(orders) do ids[#ids + 1] = tostring(pget(function() return o.id end) or '?') end
  add(b, string.format('brew: %d order(s) [%s]', #orders, table.concat(ids, ',')))
  local shown = {}
  for i, o in ipairs(orders) do
    if i > R.ORDERS_MAX then add(b, '... ' .. (#orders - R.ORDERS_MAX) .. ' more orders'); break end
    R.order(K, o, ctx, b, shown, i > R.ORDERS_DETAIL, 1)
  end
  -- NEU4 BUG-846: the Stills after the orders, one line each (`why ws:<id> --raw` is the full sheet of one)
  local stills = 0
  for _, bld in ipairs(U.shops_all()) do
    local s = pget(JW.shop, bld, nil)
    if s and s.key == 'workshop:Still' then
      stills = stills + 1
      local id = N(function() return bld.id end)
      if not shown[id] and stills <= R.SHOPS_MAX * 3 then
        local njobs = #each(pget(function() return bld.jobs end))
        add(b, string.format('still %s at %s jobs=%d maxgen=%s (full sheet: why ws:%s --raw)', tostring(id), posb(bld), njobs, V(function() return bld.profile.max_general_orders end), tostring(id)))
      end
    end
  end
  add(b, 'stills: ' .. stills)
  -- NEU13 BUG-887 round 3: the cancel snapshot (read only, economy.snap_lines): empties by state, nearest free one, the brew job's filter
  local okp, oks, sl = pcall(K.call, 'economy', 'snap_lines')
  oks = okp and oks
  if oks and type(sl) == 'table' then for _, l in ipairs(sl) do add(b, l) end end
  return b
end

---------------------------------------------------------------- the job
function R.job(K, j, ctx)
  local b = buf()
  local hb = pget(dfhack.job.getHolder, j)
  local w = pget(dfhack.job.getWorker, j)
  add(b, string.format('job %s job_type=%s flags=%s order_id=%s worker=%s holder_building=%s pos=%s material_category=%s mat=%s,%s reaction=%s', V(function() return j.id end),
                       E(df.job_type, function() return j.job_type end), V(function() return FL(j.flags) end), V(function() return j.order_id end),
                       w ~= nil and tostring(pget(function() return w.id end) or '?') or 'none', hb and tostring(pget(function() return hb.id end) or '?') or 'none',
                       V(function() return j.pos.x .. ',' .. j.pos.y .. ',' .. j.pos.z end), V(function() return FL(j.material_category) end),
                       V(function() return j.mat_type end), V(function() return j.mat_index end), V(function() return j.reaction_name end)))
  dump_struct(b, '  fields:', j, 3)
  local jt = N(function() return j.job_type end)
  local a = jt and pget(function() return df.job_type.attrs[jt] end)
  add(b, string.format('  job_type attrs: labor=%s skill=%s%s', a and V(function() return a.labor end) or '?', a and V(function() return a.skill end) or '?',
                       a and (' skill_stone=' .. V(function() return a.skill_stone end) .. ' skill_wood=' .. V(function() return a.skill_wood end) .. ' skill_metal=' .. V(function() return a.skill_metal end)) or ''))
  local s
  if hb then
    s = R.shop(K, b, hb, true)
  else
    add(b, '  no holder building')
  end
  local labors, sk = JW.labors(jt, pget(function() return j.reaction_name end), pget(function() return j.mat_type end), pget(function() return j.mat_index end), s and s.key)
  local lnames = {}
  for _, l in ipairs(labors or {}) do lnames[#lnames + 1] = ename(df.unit_labor, l) or tostring(l) end
  add(b, string.format('  derived labor: %s skill: %s', #lnames > 0 and table.concat(lnames, '|') or '? (none derived)', sk and (ename(df.job_skill, sk) or tostring(sk)) or '?'))
  if s and s.kind then              -- NEU14 BUG-893: the holder is a wall, a floor, a door ...: no workshop, and the labor it needs is named
    add(b, string.format('  holder building is a %s, not a workshop: DF needs the labor %s to build it (holders below)', s.kind,
                         #lnames > 0 and table.concat(lnames, '|') or '? (not known for this building type)'))
  end
  -- the job items
  local list = JW.job_items(j)
  local filled = {}
  for _, ref in ipairs(each(pget(function() return j.items end))) do
    local k = N(function() return ref.job_item_idx end)
    if k then filled[k] = (filled[k] or 0) + 1 end
  end
  if list == nil then add(b, '  job_items: ? (list not readable)')
  else
    add(b, string.format('  job_items: %d', #list))
    for i, ji in ipairs(list) do
      add(b, string.format('  item[%d] item_type=%s subtype=%s mat=%s,%s quantity=%s min_dimension=%s vector_id=%s reaction_class=%s product=%s tool_use=%s filled=%d flags1=%s flags2=%s flags3=%s flags4=%s flags5=%s',
                           i - 1, E(df.item_type, function() return ji.item_type end), V(function() return ji.item_subtype end), V(function() return ji.mat_type end),
                           V(function() return ji.mat_index end), V(function() return ji.quantity end), V(function() return ji.min_dimension end),
                           V(function() return ji.vector_id end), V(function() return ji.reaction_class end), V(function() return ji.has_material_reaction_product end),
                           V(function() return ji.has_tool_use end), filled[i - 1] or 0, V(function() return FL(ji.flags1) end), V(function() return FL(ji.flags2) end),
                           V(function() return FL(ji.flags3) end), V(function() return FL(ji.flags4) end), V(function() return FL(ji.flags5) end)))
    end
  end
  for i, ref in ipairs(each(pget(function() return j.general_refs end))) do
    if i > 8 then add(b, '  ... more general_refs'); break end
    local t = pget(function() return ref:getType() end)
    add(b, string.format('  general_ref %d: type=%s %s', i, t ~= nil and (ename(df.general_ref_type, t) or tostring(t)) or '?', describe(ref, 0)))
  end
  for i, ref in ipairs(each(pget(function() return j.items end))) do
    if i > 8 then add(b, '  ... more attached items'); break end
    add(b, string.format('  attached item: item_id=%s role=%s job_item_idx=%s', V(function() return ref.item.id end), V(function() return ref.role end), V(function() return ref.job_item_idx end)))
  end
  if labors then holders_head(b, labors, R.holders(K, labors, sk, s, ctx), s) end
  return b
end

---------------------------------------------------------------- items
local function has_str(vec, want)
  for _, x in ipairs(each(vec)) do
    if tostring(pget(function() return x.value end) or x) == want then return true end
  end
  return false
end

R.ITEMS = {
  logs = {vec = {'WOOD'}, cen = {'wood'}},
  plants = {vec = {'PLANT', 'PLANT_GROWTH'}, cen = {'brew_p', 'brew_g'}, brew = true},
  barrels = {vec = {'BARREL'}, cen = {'barrels', 'barrels_empty', 'cont_free'}, empty = true},
}

-- the reasons DF may skip an item, in the order the first is counted as THE reason
R.REASONS = {'gone', 'forbid', 'dump', 'in_job', 'in_building', 'built', 'on_fire', 'rotten', 'owned', 'trader', 'melt', 'hostile', 'in_claimed_container', 'outside_civ_burrow',
             'other_walk_group', 'unwalkable_tile', 'hidden_tile'}

-- NEU14 BUG-896 (Run 17d i4: 'why ConstructCoffin: boulder x1: 0 match' beside 'items:BOULDER: no exclusion 53'; the sample showed no material): a boulder's material and
-- whether a mason job's stone filter (job item flags2 non_economic, flags3 hard) would take it: {tok, hard, econ, pass}. econ = the stone-use screen's economic mark
-- (plotinfo.economic_stone[mat_index]); hard = the material's ITEMS_HARD; pass = hard and not economic (ore and flux are economic by default)
function R.stone_info(it)
  local mt, mi = pget(function() return it.mat_type end), pget(function() return it.mat_index end)
  local m = mt and pget(dfhack.matinfo.decode, mt, mi or -1)
  local mat = m and pget(function() return m.material end)
  local tok = m and pget(function() return m:getToken() end)
  local hard = mat ~= nil and pget(function() return mat.flags.ITEMS_HARD end) == true
  local es = mi and pget(function() return df.global.plotinfo.economic_stone[mi] end)
  local econ = es ~= nil and es ~= 0 and es ~= false
  return {tok = tostring(tok or ('mat ' .. tostring(mt) .. ',' .. tostring(mi))):gsub('^INORGANIC:', ''), hard = hard, econ = econ, pass = hard and not econ}
end

-- counts of the items of `spec` by exclusion reason: {total, scanned, clipped, ok, first = {}, hits = {}, unread = {}, pos_checked, cen = {}}
function R.itemscan(K, spec, ctx)
  local r = {total = 0, scanned = 0, ok = 0, first = {}, hits = {}, unread = {}, skipped = 0, cen = {}, vec = table.concat(spec.vec, '+')}
  local cap = R.ITEMS_MAX
  local civ = U.civ_burrows()
  local main = R.main_group(K)
  r.civ, r.main = civ, main
  local recs = {}
  local function flag(it, name)
    local ok, v = pcall(function() return it.flags[name] end)
    if not ok then r.unread[name] = (r.unread[name] or 0) + 1; return false end
    return v == true
  end
  for _, vn in ipairs(spec.vec) do
    local vec = pget(function() return df.global.world.items.other[vn] end)
    if vec == nil then r.unread['vector ' .. vn] = 1
    else
      pcall(function()
        for _, it in ipairs(vec) do
          r.total = r.total + 1
          if r.scanned >= cap then r.clipped = true; break end
          local keep = true
          if spec.brew then
            local mt, mi = pget(function() return it.mat_type end), pget(function() return it.mat_index end)
            local m = mt and pget(dfhack.matinfo.decode, mt, mi or -1)
            local mat = m and pget(function() return m.material end)
            keep = mat ~= nil and has_str(pget(function() return mat.reaction_product.id end), 'DRINK_MAT')
          elseif spec.empty then
            local inside = pget(dfhack.items.getContainedItems, it)
            keep = inside ~= nil and #each(inside) == 0
          end
          if keep then
            r.scanned = r.scanned + 1
            recs[#recs + 1] = it
          else r.skipped = r.skipped + 1 end
        end
      end)
    end
  end
  -- positions: one walk-group and one hidden call for the first POS_MAX items
  local pts, at = {}, {}
  for i, it in ipairs(recs) do
    if #pts < R.POS_MAX then
      local okp, x, y, z = pcall(dfhack.items.getPosition, it)
      if not okp then x = nil end
      if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
      if int(x) and int(y) and int(z) then pts[#pts + 1] = {x, y, z}; at[#pts] = i end
    end
  end
  r.pos_checked = #pts
  local grp = U.walk_groups(K, pts) or {}
  local okc, okh, hid = pcall(K.call, 'snapshot', 'hidden', pts)
  local hidden = okc and okh and type(hid) == 'table' and hid or {}
  local rec = {}                                           -- item index -> {group, hidden, pos}
  for k, i in ipairs(at) do rec[i] = {g = grp[k], h = hidden[k], p = pts[k]} end
  for i, it in ipairs(recs) do
    local why = {}
    local function hit(name) why[#why + 1] = name end
    if flag(it, 'garbage_collect') or flag(it, 'removed') then hit('gone') end
    if flag(it, 'forbid') then hit('forbid') end
    if flag(it, 'dump') then hit('dump') end
    if flag(it, 'in_job') then hit('in_job') end
    if flag(it, 'in_building') then hit('in_building') end
    -- NEU7 BUG-855 (Run 17 i4: 336 of 365 logs 'unwalkable_tile', every sample flags=[construction]): a log built into a wall is no stock, not a walk problem
    if flag(it, 'construction') then hit('built') end
    if flag(it, 'on_fire') then hit('on_fire') end
    if flag(it, 'rotten') then hit('rotten') end
    if flag(it, 'owned') then hit('owned') end
    if flag(it, 'trader') then hit('trader') end
    if flag(it, 'melt') then hit('melt') end
    if flag(it, 'hostile') then hit('hostile') end
    local c = pget(dfhack.items.getContainer, it)
    if c then
      r.in_container = (r.in_container or 0) + 1
      if pget(function() return c.flags.in_job == true or c.flags.forbid == true end) then hit('in_claimed_container') end
    end
    local q = rec[i]
    if q then
      if civ and U.in_burrows(civ, q.p) == false then hit('outside_civ_burrow') end
      if int(q.g) and main then
        if q.g == 0 and not flag(it, 'construction') then hit('unwalkable_tile') elseif q.g > 0 and q.g ~= main.group then hit('other_walk_group') end
      end
      if q.h == true then hit('hidden_tile') end
    else
      r.nopos = (r.nopos or 0) + 1
    end
    r.whys = r.whys or {}
    r.whys[i] = why
    if #why == 0 then
      r.ok = r.ok + 1
      if spec.stone then                                          -- NEU14 BUG-896: of the free boulders, the ones a mason's stone filter takes
        local si = R.stone_info(recs[i])
        r.stone = r.stone or {free = 0, pass = 0, by = {}}
        r.stone.free = r.stone.free + 1
        if si.pass then r.stone.pass = r.stone.pass + 1 end
        local e = r.stone.by[si.tok] or {n = 0, hard = si.hard, econ = si.econ}
        e.n = e.n + 1
        r.stone.by[si.tok] = e
      end
    else r.first[why[1]] = (r.first[why[1]] or 0) + 1 end
    for _, w in ipairs(why) do r.hits[w] = (r.hits[w] or 0) + 1 end
    for _, w in ipairs(why) do if w == 'built' or w == 'in_building' then r.builtn = (r.builtn or 0) + 1; break end end
  end
  -- NEU4 BUG-843: up to SAMPLE_MAX items described one by one: the excluded ones (a few of each first reason) and the ones with no exclusion
  r.sample = {}
  local per, taken = {}, {}
  -- pass 1: up to 2 of every first reason (3 of the free ones) so that each kind of exclusion shows; pass 2 fills up to SAMPLE_MAX
  for pass = 1, 2 do
    for i, it in ipairs(recs) do
      if #r.sample >= R.SAMPLE_MAX then break end
      local why = r.whys and r.whys[i] or {}
      local key = why[1] or 'ok'
      local lim = pass == 1 and (key == 'ok' and 3 or 2) or 4
      if not taken[i] and (per[key] or 0) < lim then
        per[key], taken[i] = (per[key] or 0) + 1, true
        r.sample[#r.sample + 1] = R.sample_item(K, it, rec[i], why, spec)
      end
    end
  end
  local inv = K.census and K.census.i
  if type(inv) == 'table' then
    for _, k in ipairs(spec.cen or {}) do r.cen[k] = inv[k] end
  end
  return r
end

-- one sampled item: id, tile, what the tile is, the container, the stockpile, the item's flags, the reasons
function R.sample_item(K, it, q, why, spec)
  local id = N(function() return it.id end)
  local x, y, z = nil, nil, nil
  if q and q.p then x, y, z = q.p[1], q.p[2], q.p[3] end
  local parts = {'#' .. tostring(id or '?'), (x and string.format('at %d,%d,%d', x, y, z) or 'no tile')}
  if x then
    -- the tile through snapshot (the one reader of the map): legend char, shape, material, liquid depth, magma, building type, occupancy; nil = hidden
    local okp, okk, t2 = pcall(K.call, 'snapshot', 'tile', x, y, z)
    local ti2 = okp and okk and type(t2) == 'table' and t2 or nil
    if ti2 then
      parts[#parts + 1] = string.format('tile=%s/%s/%s', tostring(ti2.c), tostring(ti2.shape or '?'), tostring(ti2.mat or '?'))
      if (ti2.flow or 0) > 0 then parts[#parts + 1] = 'liquid=' .. (ti2.magma and 'magma' or 'water') .. tostring(ti2.flow) end
      if ti2.bld and ti2.bld ~= '' then parts[#parts + 1] = 'building=' .. tostring(ti2.bld) end
      if ti2.cav then parts[#parts + 1] = 'cavern' end
    else
      parts[#parts + 1] = 'tile=? (hidden or unread)'
    end
    local sp
    pcall(function()
      for _, s in ipairs(df.global.world.buildings.other.STOCKPILE) do
        if s.z == z and x >= s.x1 and x <= s.x2 and y >= s.y1 and y <= s.y2 then sp = s; break end
      end
    end)
    if sp then
      parts[#parts + 1] = 'stockpile=#' .. tostring(N(function() return sp.id end)) .. '(' .. tostring(pget(function() return dfhack.df2utf(sp.name or '') end) or '') .. ' max_barrels=' .. (function() local v, c = PL.get(sp); return v and (tostring(v) .. '@' .. c) or '? (no field of ' .. PL.tried() .. ' reads)' end)() .. ')'
    end
    parts[#parts + 1] = 'group=' .. tostring(q.g == nil and '?' or q.g)
  end
  local c = pget(dfhack.items.getContainer, it)
  if c then parts[#parts + 1] = 'in ' .. tostring(ename(df.item_type, pget(function() return c:getType() end) or -1) or '?') .. '#' .. tostring(N(function() return c.id end)) end
  if spec and spec.empty then
    local inside = pget(dfhack.items.getContainedItems, it)
    parts[#parts + 1] = 'contents=' .. tostring(inside and #each(inside) or '?')
  end
  if spec and spec.stone then                                     -- NEU14 BUG-896
    local si = R.stone_info(it)
    parts[#parts + 1] = string.format('mat=%s hard=%s economic=%s mason_filter=%s', si.tok, tostring(si.hard), tostring(si.econ), si.pass and 'pass' or 'fail')
  end
  parts[#parts + 1] = 'flags=' .. V(function() return FL(it.flags) end)
  parts[#parts + 1] = 'refs=' .. V(function()
    local out = {}
    for _, ref in ipairs(each(it.general_refs)) do out[#out + 1] = tostring(ename(df.general_ref_type, ref:getType()) or '?') end
    return #out > 0 and table.concat(out, ',') or 'none'
  end)
  parts[#parts + 1] = 'reason=' .. (#why > 0 and table.concat(why, '+') or 'none (free as DF sees it)')
  return table.concat(parts, ' ')
end

local function counts_text(t, order)
  local parts = {}
  for _, k in ipairs(order) do if t[k] then parts[#parts + 1] = k .. '=' .. t[k] end end
  for k, n in pairs(t) do
    local known = false
    for _, o in ipairs(order) do if o == k then known = true end end
    if not known then parts[#parts + 1] = k .. '=' .. n end
  end
  return #parts > 0 and table.concat(parts, ' ') or 'none'
end

-- NEU14 BUG-896: item vectors by the names a player says (`why items:door --raw`), and the census keys that count them
R.ALIAS = {door = 'DOOR', doors = 'DOOR', bed = 'BED', beds = 'BED', cabinet = 'CABINET', box = 'BOX', chest = 'BOX', coffin = 'COFFIN', table = 'TABLE',
           chair = 'CHAIR', throne = 'THRONE', hatch = 'HATCH_COVER', grate = 'GRATE', floodgate = 'FLOODGATE', slab = 'SLAB', boulder = 'BOULDER',
           boulders = 'BOULDER', block = 'BLOCKS', blocks = 'BLOCKS', barrel = 'BARREL'}
R.CEN = {DOOR = {'doors'}, BOULDER = {'rock', 'rock_bad', 'rock_far', 'boulders'}, BLOCKS = {'blocks_free'}, HATCH_COVER = {'hatches'}, GRATE = {'grates'}}
local function spec_of(key)
  local name = tostring(key or ''):lower()
  if R.ITEMS[name] then return R.ITEMS[name], name end
  local vn = R.ALIAS[name] or tostring(key or ''):upper()
  if vn ~= '' and vn:match('^[A-Z_]+$') and pget(function() return df.global.world.items.other[vn] end) ~= nil then
    return {vec = {vn}, cen = R.CEN[vn] or {}, stone = vn == 'BOULDER' or nil}, vn:lower()
  end
  return nil
end

function R.items(K, key, ctx)
  local b = buf()
  local spec, name = spec_of(key)
  if not spec then
    add(b, 'items: key must be one of ' .. 'logs, plants, barrels or an item vector name (BOOK, BLOCKS, ...)')
    return b, false
  end
  local r = R.itemscan(K, spec, ctx)
  add(b, string.format('items %s (vector %s): %d records, %d looked at%s%s; skipped as not a candidate (%s): %d', name, r.vec, r.total, r.scanned, r.clipped and ' (clipped)' or '',
                       r.nopos and (' (' .. r.nopos .. ' without a tile)') or '', spec.brew and 'no DRINK_MAT' or spec.empty and 'not empty' or 'none', r.skipped))
  add(b, string.format('  no exclusion (free as DF sees it): %d', r.ok))
  if spec.stone then                                              -- NEU14 BUG-896
    local sf = r.stone or {free = 0, pass = 0, by = {}}
    add(b, string.format('  boulders: %d free, of them %d hard non-economic (a mason job takes only those: flags2 non_economic, flags3 hard)', sf.free, sf.pass))
    local mats = {}
    for tok, e in pairs(sf.by) do mats[#mats + 1] = {tok, e} end
    table.sort(mats, function(x, y) if x[2].n ~= y[2].n then return x[2].n > y[2].n end return x[1] < y[1] end)
    local out = {}
    for i, m in ipairs(mats) do
      if i > 6 then break end
      out[#out + 1] = string.format('%s x%d (%s%s)', m[1], m[2].n, m[2].hard and 'hard' or 'soft', m[2].econ and ', economic' or '')
    end
    if #out > 0 then add(b, '  free boulders by material: ' .. table.concat(out, '; ')) end
  end
  add(b, '  excluded, first reason only: ' .. counts_text(r.first, R.REASONS))
  add(b, '  hit counts (an item may hit several): ' .. counts_text(r.hits, R.REASONS))
  -- NEU7 BUG-855: items built into constructions or buildings are no stock; shown apart (their tile is a wall: not a walk problem)
  if (r.hits.built or 0) + (r.hits.in_building or 0) > 0 then
    add(b, string.format('  built into constructions or buildings: %d (no stock: built %d, in a building %d)', r.builtn or 0, r.hits.built or 0, r.hits.in_building or 0))
  end
  add(b, string.format('  in a container: %d; tiles checked: %d; citizens\' main walk group %s; civ alert burrows %s', r.in_container or 0, r.pos_checked,
                       r.main and (r.main.group .. ' (' .. r.main.n .. '/' .. r.main.of .. ')') or '?', r.civ and table.concat(r.civ, ',') or 'off'))
  local un = {}
  for k, n in pairs(r.unread) do un[#un + 1] = k .. '=' .. n end
  if #un > 0 then table.sort(un); add(b, '  fields not readable on this DF (counted as not set): ' .. table.concat(un, ' ')) end
  local cen = {}
  for k, v in pairs(r.cen) do cen[#cen + 1] = k .. '=' .. tostring(v) end
  table.sort(cen)
  add(b, '  census says: ' .. (#cen > 0 and table.concat(cen, ' ') or '(no census key for this vector)'))
  if r.sample and #r.sample > 0 then
    add(b, '  sample (' .. #r.sample .. ' items; excluded first, then free ones):')
    for _, ln in ipairs(r.sample) do add(b, '    ' .. ln) end
  end
  return b, true, r
end

---------------------------------------------------------------- the manager
function R.manager(K, ctx)
  local b = buf()
  local f = ctx and ctx.manager and pget(ctx.manager) or nil
  if type(f) ~= 'table' then add(b, 'manager: not read (no economy facts)'); return b end
  add(b, string.format('manager unit=%s name=%s state=%s job=%s squad=%s mood=%s pos=%s out_days=%s', tostring(f.unit), tostring(f.name), tostring(f.state), tostring(f.job),
                       tostring(f.squad), tostring(f.mood), f.pos and table.concat(f.pos, ',') or '?', tostring(f.out)))
  local u = f.unit and pget(df.unit.find, f.unit)
  if u then
    local on = {}
    for _, kv in ipairs(entries(pget(function() return u.status.labors end) or {}, 200) or {}) do
      if kv[2] == true then on[#on + 1] = ename(df.unit_labor, kv[1]) or tostring(kv[1]) end
    end
    table.sort(on)
    add(b, '  labors on: ' .. (#on > 0 and table.concat(on, ',') or 'none/?'))
    local cj = pget(function() return u.job.current_job end)
    if cj ~= nil then add(b, string.format('  current job: id=%s type=%s flags=%s', V(function() return cj.id end), E(df.job_type, function() return cj.job_type end), V(function() return FL(cj.flags) end))) end
    local main = R.main_group(K)
    local g = (U.walk_groups(K, {{u.pos.x, u.pos.y, u.pos.z}}) or {})[1]
    add(b, string.format('  walk group: him %s, citizens\' main %s; civ alert burrows %s', tostring(g or '?'), main and tostring(main.group) or '?', U.civ_burrows() and table.concat(U.civ_burrows(), ',') or 'off'))
  end
  local o = f.office or {}
  add(b, string.format('  office: zone=%s box=%s chair_built=%s (planned %s) table_built=%s (planned %s) assigned=%s walk_path_from_him=%s required_room_value=%s room=%s',
                       tostring(o.zone), o.box and describe(o.box, 1) or '?', tostring(o.chair), tostring(o.chair_p), tostring(o.table), tostring(o.table_p), tostring(o.assigned),
                       tostring(o.walk), tostring(o.required), tostring(o.room)))
  local zone = type(o.zone) == 'number' and pget(df.building.find, o.zone) or nil
  if zone then
    local zg = pget(function()
      local x, y, z = (zone.x1 + zone.x2) // 2, (zone.y1 + zone.y2) // 2, zone.z
      return (U.walk_groups(K, {{x, y, z}}) or {})[1]
    end)
    add(b, string.format('  office zone: %s walk_group=%s', posb(zone), tostring(zg or '?')))
  end
  -- the orders: validated or not, raw
  local n, unv, act = 0, 0, 0
  for _, od in ipairs(each(pget(function() return df.global.world.manager_orders.all end))) do
    n = n + 1
    if pget(function() return od.status.validated end) == false then unv = unv + 1 end
    if pget(function() return od.status.active end) == true then act = act + 1 end
  end
  add(b, string.format('  orders: %d, unvalidated %d, active %d; economy counts %s unvalidated for %s days; ManageWorkOrders jobs %s (his %s)', n, unv, act, tostring((f.orders or {}).n),
                       tostring((f.orders or {}).d), tostring((f.orders or {}).mjobs), tostring((f.orders or {}).mjobs_his)))
  local timer
  for _, nm in ipairs({'manager_timer', 'manager_wait', 'work_order_timer', 'orders_timer'}) do
    local v = pget(function() return df.global.plotinfo[nm] end)
    if v == nil then v = pget(function() return df.global.world[nm] end) end
    if v ~= nil then timer = nm .. '=' .. describe(v, 1); break end
  end
  add(b, '  DF manager timer: ' .. (timer or '? (no such field found)'))
  for _, c in ipairs(f.causes or {}) do add(b, '  kernel cause: ' .. tostring(c)) end
  return b
end

---------------------------------------------------------------- the stockpile (NEU5 BUG-848)
-- a stockpile building by id (nil when the id is no stockpile)
function R.find_pile(id)
  local b = pget(df.building.find, id)
  if not b then return nil end
  local isp = pget(function() return df.building_type[b:getType()] == 'Stockpile' end)
  if isp then return b end
  for _, sp in ipairs(each(pget(function() return df.global.world.buildings.other.STOCKPILE end))) do
    if pget(function() return sp.id end) == id then return sp end
  end
end

-- `pile:<id>`: every field of a stockpile building, generically (the real names), with its storage / container settings and its links
function R.pile(K, sp)
  local b = buf()
  local id = N(function() return sp.id end)
  local v, cand = PL.get(sp)
  add(b, string.format('pile %s %s at %s barrel limit %s (field %s; candidates %s) number=%s', tostring(id), tostring(pget(function() return dfhack.df2utf(sp.name or '') end) or ''),
                       posb(sp), v and tostring(v) or '?', cand or 'NOT READABLE', PL.tried(), V(function() return sp.stockpile_number end)))
  add(b, '  building flags=' .. V(function() return FL(sp.flags) end))
  dump_struct(b, '  storage', pget(function() return sp.storage end), 4)
  dump_struct(b, '  stockpile_flag', pget(function() return sp.stockpile_flag end), 2)
  local fl = pget(function() return sp.settings.flags end)
  add(b, '  settings.flags=' .. (fl ~= nil and FL(fl) or '?') .. ' (the item groups this pile takes)')
  local links = pget(function() return sp.links end)
  if links ~= nil then
    local e = entries(links, 20) or {}
    table.sort(e, function(x, y) return tostring(x[1]) < tostring(y[1]) end)
    for _, kv in ipairs(e) do
      local ids = {}
      for _, x in ipairs(each(kv[2])) do ids[#ids + 1] = tostring(pget(function() return x.id end) or '?') end
      add(b, string.format('  link %s: %s', tostring(kv[1]), #ids > 0 and table.concat(ids, ',') or 'none'))
    end
  else add(b, '  links: ?') end
  local here, full, empty = 0, 0, 0
  for _, it in ipairs(each(pget(function() return df.global.world.items.other.BARREL end))) do
    local p = pget(function() return it.pos end)
    local x1, x2, y1, y2, z = N(function() return sp.x1 end), N(function() return sp.x2 end), N(function() return sp.y1 end), N(function() return sp.y2 end), N(function() return sp.z end)
    if p and z and p.z == z and p.x >= x1 and p.x <= x2 and p.y >= y1 and p.y <= y2 then
      here = here + 1
      local inside = pget(dfhack.items.getContainedItems, it)
      if inside and #each(inside) > 0 then full = full + 1 else empty = empty + 1 end
    end
  end
  add(b, string.format('  barrels lying in the pile: %d (%d with contents, %d empty)', here, full, empty))
  dump_struct(b, '  fields', sp, 6)
  return b
end

---------------------------------------------------------------- the entry
-- key: order:<id> | brew | job:<id> | items:<name> | manager | ws:<id>  ->  ok, text (first line), {kind, key, lines, clipped}
-- NEU4 BUG-846: the lines cut into pages of at most R.PAGE_BYTES encoded bytes: lines of page `page`, the page used, the number of pages
function R.paginate(lines, page)
  local pages, cur, size = {}, {}, 0
  for _, ln in ipairs(lines) do
    local n = #json.encode(ln) + 2
    if #cur > 0 and size + n > R.PAGE_BYTES then pages[#pages + 1] = cur; cur, size = {}, 0 end
    cur[#cur + 1] = ln
    size = size + n
  end
  pages[#pages + 1] = cur
  page = math.max(1, math.min(#pages, math.tointeger(tonumber(page)) or 1))
  return pages[page], page, #pages
end

function R.find(K, key, ctx, page)
  local s = tostring(key or ''):gsub('^%s+', ''):gsub('%s+$', '')
  local low = s:lower()
  local pre, rest = s:match('^(%a+):(.+)$')
  pre = pre and pre:lower()
  local b, kind
  if low == 'brew' then b, kind = R.brew(K, ctx), 'brew'
  elseif low == 'manager' then b, kind = R.manager(K, ctx), 'manager'
  elseif pre == 'pile' then
    local id = int(rest)
    if not id then return false, 'key pile:<stockpile id>' end
    local sp = R.find_pile(id)
    if not sp then return false, 'no stockpile ' .. id end
    b, kind = R.pile(K, sp), 'pile'
  elseif pre == 'order' or pre == 'job' or pre == 'ws' then
    local id = int(rest)
    if not id then return false, 'key ' .. pre .. ':<number>' end
    if pre == 'order' then
      local o = U.find_order(id)
      if not o then return false, 'no manager order ' .. id end
      b, kind = R.order(K, o, ctx), 'order'
    elseif pre == 'job' then
      local j = U.find_job(id)
      if not j then return false, 'no job ' .. id end
      b, kind = R.job(K, j, ctx), 'job'
    else
      local bld = U.find_shop(id)
      if not bld then
        local sp = R.find_pile(id)             -- NEU5: ws:<id> takes a stockpile id too
        if not sp then return false, 'no workshop, furnace or stockpile ' .. id end
        b, kind = R.pile(K, sp), 'pile'
      else
        b = buf(); R.shop(K, b, bld, true); kind = 'ws'
      end
    end
  elseif pre == 'items' then
    local ok
    b, ok = R.items(K, rest, ctx)
    if not ok then return false, b.l[1] end
    kind = 'items'
  else
    return false, 'key: order:<id>, brew, job:<id>, items:<logs|plants|barrels|VECTOR>, manager, ws:<id> or pile:<stockpile id>'
  end
  if b.clipped then b.l[#b.l + 1] = '... (output clipped at ' .. R.MAX_LINES .. ' lines)' end
  local lines, pg, pages = R.paginate(b.l, page)
  local msg = b.l[1] or (kind .. ': nothing')
  if pages > 1 then msg = string.format('page %d of %d (--page N for the others): %s', pg, pages, msg) end
  return true, msg, {kind = kind, key = s, lines = lines, n = #b.l, page = pg, pages = pages, clipped = b.clipped or false}
end

---------------------------------------------------------------- the stall line
-- ONE compact line of raw discriminators for a stall (kern.log), read-only: what a player's `inspect what=raw` would show, in a line.
--   kind brew:  the brew orders (n, validated, pinned shop and its state), the Stills (jobs, suspended, working), the BREWER holders at the first Still by status,
--               the plants and the empty barrels by exclusion reason.
--   kind order: one order (key 'order:<id>'): its flags, pinned shop, holders of its labor.
--   kind build: the labor holders of a build job at its site.
function R.stall_line(K, kind, arg, ctx)
  local parts = {}
  local function put(s) parts[#parts + 1] = s end
  if kind == 'brew' then
    local n, valid, active, pinned, left = 0, 0, 0, {}, 0
    for _, o in ipairs(each(pget(function() return df.global.world.manager_orders.all end))) do
      local tn = ename(df.job_type, N(function() return o.job_type end) or -1) or '?'
      if JW.KINDS.brew(tn, pget(function() return o.reaction_name end)) or tn == 'BrewDrink' then
        n = n + 1
        if pget(function() return o.status.validated end) == true then valid = valid + 1 end
        if pget(function() return o.status.active end) == true then active = active + 1 end
        left = left + (N(function() return o.amount_left end) or 0)
        local pin = N(function() return o.workshop_id end)
        if pin and pin >= 0 then pinned[#pinned + 1] = tostring(pin) end
      end
    end
    put(string.format('orders=%d valid=%d active=%d left=%d pinned=[%s]', n, valid, active, left, table.concat(pinned, ',')))
    local first
    local stills = {}
    for _, bld in ipairs(U.shops_all()) do
      local s = pget(JW.shop, bld, K)
      if s and s.key == 'workshop:Still' then
        first = first or s
        local jobs = each(pget(function() return bld.jobs end))
        local susp, work = 0, 0
        for _, j in ipairs(jobs) do
          if pget(function() return j.flags.suspend end) == true then susp = susp + 1 end
          if pget(dfhack.job.getWorker, j) ~= nil then work = work + 1 end
        end
        local pid = N(function() return bld.id end)
        local pin = false
        for _, x in ipairs(pinned) do if x == tostring(pid) then pin = true end end
        stills[#stills + 1] = string.format('%s(stage %s/%s jobs=%d susp=%d work=%d maxgen=%s pinned=%s forbid=%s)', tostring(pid), V(function() return bld:getBuildStage() end),
                                            V(function() return bld:getMaxBuildStage() end), #jobs, susp, work, V(function() return bld.profile.max_general_orders end), tostring(pin),
                                            V(function() return bld.flags.forbidden end))
      end
    end
    put('stills=' .. (#stills > 0 and table.concat(stills, ' ') or 'none'))
    -- NEU5 BUG-848: the stockpile barrel limit field, never silent: which candidate answers, or that none does
    local piles = each(pget(function() return df.global.world.buildings.other.STOCKPILE end))
    if #piles > 0 then
      local pr = PL.probe(piles)
      put(pr.ok > 0 and string.format('pile limit field=%s (%d of %d piles read)', pr.cand, pr.ok, pr.n)
                    or string.format('pile limit field UNREADABLE on %d piles (tried %s): the barrel cure cannot act', pr.n, pr.tried))
    end
    for _, id in ipairs(pinned) do
      local pb = pget(df.building.find, tonumber(id))
      if not pb then put('pin ' .. id .. ' missing') end
    end
    local lab = df.unit_labor and df.unit_labor.BREWER
    if lab and first then
      local w = R.holders(K, {lab}, nil, first, ctx)
      local by = {}
      for k, c in pairs(w.by) do by[#by + 1] = k .. '=' .. c end
      table.sort(by)
      put(string.format('brewers=%d [%s]', w.n, table.concat(by, ' ')))
    else put('brewers=?') end
    for _, nm in ipairs({'plants', 'barrels'}) do
      local r = R.itemscan(K, R.ITEMS[nm], ctx)
      put(string.format('%s: seen=%d ok=%d first[%s] census[%s]', nm, r.scanned, r.ok, counts_text(r.first, R.REASONS),
                        (function() local c = {}; for k, v in pairs(r.cen) do c[#c + 1] = k .. '=' .. tostring(v) end; table.sort(c); return table.concat(c, ' ') end)()))
    end
  elseif kind == 'order' then
    local o = U.find_order(int(arg) or -1)
    if not o then return nil end
    put(string.format('order %s %s left=%s status=%s pin=%s conds=%d', V(function() return o.id end), E(df.job_type, function() return o.job_type end), V(function() return o.amount_left end),
                      V(function() return FL(o.status) end), V(function() return o.workshop_id end), #each(pget(function() return o.item_conditions end))))
    local shops = order_shops(o)
    local first = shops[1] and pget(JW.shop, shops[1], K)
    if first then
      put(string.format('shop %s stage %s/%s jobs=%d maxgen=%s', tostring(first.id), V(function() return shops[1]:getBuildStage() end), V(function() return shops[1]:getMaxBuildStage() end),
                        #each(pget(function() return shops[1].jobs end)), V(function() return shops[1].profile.max_general_orders end)))
      local labors, sk = JW.labors(N(function() return o.job_type end), pget(function() return o.reaction_name end), pget(function() return o.mat_type end), pget(function() return o.mat_index end), first.key)
      if labors then
        local w = R.holders(K, labors, sk, first, ctx)
        local by = {}
        for k, c in pairs(w.by) do by[#by + 1] = k .. '=' .. c end
        table.sort(by)
        put(string.format('holders=%d [%s]', w.n, table.concat(by, ' ')))
      else put('holders=? (no labor derived)') end
    else put('shops=none') end
  elseif kind == 'build' then
    local p = arg
    put('site ' .. tostring(p and p.at or '?'))
    local labs = {}
    for _, nm in ipairs({'CARPENTER', 'MASON', 'ARCHITECT', 'BUILD_CONSTRUCTION'}) do
      local l = df.unit_labor and df.unit_labor[nm]
      if l then labs[#labs + 1] = l end
    end
    local sitebox = p and p.pos and {at = p.pos} or nil
    if p and p.labor and df.unit_labor and df.unit_labor[p.labor] then labs = {df.unit_labor[p.labor]} end
    local w = R.holders(K, labs, nil, sitebox, ctx)
    local by = {}
    for k, c in pairs(w.by) do by[#by + 1] = k .. '=' .. c end
    table.sort(by)
    put(string.format('builders=%d [%s] main_group=%s civ_alert=%s', w.n, table.concat(by, ' '), w.main and tostring(w.main.group) or '?', w.civ and table.concat(w.civ, ',') or 'off'))
  else
    return nil
  end
  -- NEU4 BUG-841: DF's own reason leads the line (the weekly raw stall line): what DF cancelled and why, from the cancel tally
  local lead
  if type(ctx) == 'table' and type(ctx.df) == 'function' then
    local m
    if kind == 'brew' then m = {'brew '}
    elseif kind == 'order' then
      local o = type(arg) == 'string' and arg:match('^order:(%d+)$') and U.find_order(int(arg:match('%d+')))
      m = o and JW.df_match({job = ename(df.job_type, N(function() return o.job_type end) or -1) or '?'}) or nil
    elseif kind == 'build' then m = function(k) return k:sub(1, 9) == 'construct' or k:sub(1, 5) == 'build' end end
    local e = m and pget(ctx.df, m)
    lead = e and e.text or nil
  end
  -- NEU5 BUG-847: the cancel reader's health beside it (an empty tally is not a blind reader): "DF cancel lines seen in window: N (source gamelog|report ...)"
  local health = type(ctx) == 'table' and type(ctx.health) == 'function' and pget(ctx.health) or nil
  return ('raw stall %s: %s%s%s'):format(kind, 'DF: ' .. (lead or 'no cancel reason seen') .. ' | ', type(health) == 'string' and (health .. ' | ') or '',
                                         table.concat(parts, ' | ')):sub(1, 900)
end

return R
