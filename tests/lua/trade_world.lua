-- WP9 test world: k_mock plus the DF fakes trade.lua reads (caravans, depot, items, materials,
-- entities, the trade screen, focus strings, the screen buffer) and a simulated vanilla depot/trade
-- UI behind act.trade, laid out like DF 53.16 + DFHack confirm. Test-only (CONTRACTS §1.4 exempts tests/**).
--   local F = require('trade_world'); local W = F.world{}; local d = F.depot(W, {})
--   local c = F.caravan(W, {state = 'Approaching', goods = {F.item(W, {type = 'BAR', mat = 'INORGANIC:IRON'})}})
local kmock = require('dfllm.util.k_mock')
local vec = kmock.vec

local F = {}
F.REPO = (arg and arg[0] or ''):match('^(.*)/tests/lua/[^/]+$') or '.'

F.ITEM_TYPES = {'BAR', 'SMALLGEM', 'BLOCKS', 'ROUGH', 'BOULDER', 'WOOD', 'DOOR', 'BED', 'CHAIR', 'CAGE', 'BARREL',
  'BIN', 'BOX', 'WEAPON', 'ARMOR', 'SHOES', 'SHIELD', 'HELM', 'GLOVES', 'PANTS', 'FIGURINE', 'AMULET', 'SCEPTER',
  'AMMO', 'CROWN', 'RING', 'EARRING', 'BRACELET', 'ANVIL', 'MEAT', 'FISH', 'SEEDS', 'PLANT', 'SKIN_TANNED', 'THREAD',
  'CLOTH', 'TOTEM', 'DRINK', 'CHEESE', 'FOOD', 'TOOL', 'EGG', 'GOBLET', 'INSTRUMENT', 'TOY', 'SPLINT', 'LIQUID_MISC'}
-- df.builtin_mats in DF's order (0 = INORGANIC); other materials get fake codes from 100
F.BUILTIN = {'INORGANIC', 'AMBER', 'CORAL', 'GLASS_GREEN', 'GLASS_CLEAR', 'GLASS_CRYSTAL', 'WATER', 'COAL', 'POTASH',
  'ASH', 'PEARLASH', 'LYE', 'MUD', 'VOMIT', 'SALT', 'FILTH_B', 'FILTH_Y', 'UNKNOWN_SUBSTANCE', 'GRIME'}
F.METALS = {IRON = true, PIG_IRON = true, STEEL = true, COPPER = true, BRONZE = true, BISMUTH_BRONZE = true,
            GOLD = true, SILVER = true, TIN = true}

-- DFHack's confirm prompt texts (hack/scripts/internal/confirm/specs.lua:108,158-176)
F.MSG_CONFIRM = 'Are you sure you want to trade the selected goods?'
F.MSG_ETHICS = '\n\nYou have items selected that will offend the merchants. Proceeding with this trade will anger'
  .. ' them. You can click on the Ethics warning badge to see which items the merchants will find offensive.'
F.MSG_CANCEL = 'Are you sure you want leave this screen? Selected items will not be saved.'

-- the screen size and the trade screen's bottom buttons where DFHack confirm's frames put them
-- (interface rect = whole window): Trade {l=0,r=23,w=11}, Seize {l=0,r=73,w=11}, Offer {l=40,r=5,w=19}
function F.set_size(w, h)
  F.SW, F.SH = w, h
  F.TRADE_BTN = {x = (w - 34) // 2 + 3, y = h - 6}
  F.SEIZE_BTN = {x = (w - 84) // 2 + 3, y = h - 6}
  F.OFFER_BTN = {x = 40 + (w - 64) // 2 + 3, y = h - 6}
end
F.set_size(160, 60)

local function enum(names, first)
  local t = {}
  for i, n in ipairs(names) do t[n] = first + i - 1; t[first + i - 1] = n end
  return t
end

-- verbatim copy of hack/lua/gui.lua:111-113,150-180 (mkdims_wh, align_coord, compute_frame_rect);
-- test_trade_act.lua checks it against the installed gui.lua
function F.compute_frame_rect(wavail, havail, spec, xgap, ygap)
  local function mkdims_wh(x1, y1, w, h) return {x1 = x1, y1 = y1, x2 = x1 + w - 1, y2 = y1 + h - 1, width = w, height = h} end
  local function align_coord(gap, align, lv, rv)
    if gap <= 0 then return 0 end
    if not align then
      if rv and not lv then align = 1.0 elseif lv and not rv then align = 0.0 else align = 0.5 end
    end
    return math.floor(gap * align)
  end
  if not spec then return mkdims_wh(0, 0, wavail, havail) end
  local sw = wavail - (spec.l or 0) - (spec.r or 0)
  local sh = havail - (spec.t or 0) - (spec.b or 0)
  local rqw = math.min(sw, (spec.w or sw) + xgap)
  local rqh = math.min(sh, (spec.h or sh) + ygap)
  local ax = align_coord(sw - rqw, spec.xalign, spec.l, spec.r)
  local ay = align_coord(sh - rqh, spec.yalign, spec.t, spec.b)
  local rect = mkdims_wh((spec.l or 0) + ax, (spec.t or 0) + ay, rqw, rqh)
  rect.wgap = sw - rqw
  rect.hgap = sh - rqh
  return rect
end

-- screen buffer helpers: rows are 0-based {[y] = string of F.SW chars}
function F.blank_rows()
  local r = {}
  for y = 0, F.SH - 1 do r[y] = string.rep(' ', F.SW) end
  return r
end
function F.put(rows, x, y, s) rows[y] = rows[y]:sub(1, x) .. s .. rows[y]:sub(x + #s + 1) end

-- greedy word wrap (string:wrap, hack/lua/dfhack.lua:673)
function F.wrap(s, width)
  local out = {}
  for para in (s .. '\n'):gmatch('([^\n]*)\n') do
    local line = ''
    for word in para:gmatch('%S+') do
      if line == '' then line = word
      elseif #line + 1 + #word <= width then line = line .. ' ' .. word
      else out[#out + 1] = line; line = word end
    end
    out[#out + 1] = line
  end
  return out
end

-- a confirm yes/no prompt laid out like gui/dialogs.lua:60-75,159-172: message wrapped at 45,
-- min width 39, 2 extra rows, inset+gap 2 per side, centred on the window
function F.dialog(rows, title, msg)
  local lines = F.wrap(msg, 45)
  local tw = 0
  for _, l in ipairs(lines) do tw = math.max(tw, #l) end
  local fw, fh = math.max(39, tw + 1) + 4, #lines + 3 + 2 + 4
  local x1, y1 = (F.SW - fw) // 2, (F.SH - fh) // 2
  for y = y1, y1 + fh - 1 do F.put(rows, x1, y, string.rep(' ', fw)) end
  F.put(rows, x1 + 2, y1, ' ' .. title .. ' ')
  for i, l in ipairs(lines) do F.put(rows, x1 + 2, y1 + 1 + i, l) end
  F.put(rows, x1 + 2, y1 + fh - 4, 'Shift+P: Pause this confirmation')
  F.put(rows, x1 + 2, y1 + fh - 2, 'Enter: Yes, proceed')
end

function F.world(opts)
  opts = opts or {}
  return F.install(kmock.new{units = opts.units, persist = opts.persist, plan = opts.plan, mode = opts.mode,
                             cfg = opts.cfg, census = opts.census})
end

-- material token -> mat_type, mat_index
local function mat_code(W, tok)
  local head, rest = tok:match('^([A-Z_]+):?(.*)$')
  local b = df.builtin_mats[head]
  if b and head ~= 'INORGANIC' then return b, (head == 'COAL' and rest == 'CHARCOAL') and 1 or 0 end
  for k, v in pairs(W.mats) do if v == tok then return k, 0 end end
  W.mat_n = W.mat_n + 1
  W.mats[100 + W.mat_n] = tok
  return 100 + W.mat_n, 0
end

local function decode(W, t, i)
  local name, tok, mode, flags = df.builtin_mats[t], nil, 'builtin', {}
  if t and t > 0 and t < #F.BUILTIN and name then
    tok = name == 'COAL' and (i == 1 and 'COAL:CHARCOAL' or 'COAL:COKE') or name
  else
    tok = W.mats[t]
    if not tok then return nil end
    local head, a, b = tok:match('^([A-Z_]+):?([A-Z_]*):?([A-Z_]*)$')
    if head == 'INORGANIC' then mode, flags = 'inorganic', {IS_METAL = F.METALS[a] == true}
    elseif head == 'PLANT' then mode, flags = 'plant', {WOOD = b == 'WOOD', STRUCTURAL_PLANT_MAT = b == 'STRUCTURAL'}
    elseif head == 'CREATURE' then mode = 'creature' end
  end
  return {type = t, index = i, mode = mode, material = {flags = flags}, getToken = function() return tok end}
end

-- the WP9 fakes on an existing k_mock world (also on top of tests/lua/kern_world.lua)
function F.install(W)
  local g = df.global
  df.item_type = enum(F.ITEM_TYPES, 0)
  df.builtin_mats = enum(F.BUILTIN, 0)
  df.job_type = enum({'TradeAtDepot', 'PullLever', 'BringItemToDepot'}, 0)
  df.caravan_state = {T_trade_state = enum({'None', 'Approaching', 'AtDepot', 'Leaving', 'Stuck'}, 0)}
  df.ethic_type = enum({'KILL_ANIMAL', 'KILL_PLANT'}, 0)
  df.ethic_response = enum({'NOT_APPLICABLE', 'ACCEPTABLE', 'JUSTIFIED_IF_SELF_DEFENSE', 'JUSTIFIED_IF_EXTREME_REASON',
    'MISGUIDED', 'SHUN', 'APPALLING', 'PUNISH_REPRIMAND', 'PUNISH_SERIOUS', 'PUNISH_EXILE', 'PUNISH_CAPITAL',
    'UNTHINKABLE', 'REQUIRED'}, 0)
  df.view_sheet_type = enum({'UNIT', 'ITEM', 'BUILDING'}, 0)
  df.building_tradedepotst = {is_instance = function(_, b) return type(b) == 'table' and b._depot == true end}
  W.entities, W.mats, W.mat_n, W.item_seq, W.items_by_id = {}, {}, 0, 7000, {}
  df.historical_entity = {find = function(id) return W.entities[id] end}
  g.plotinfo.caravans = vec{}
  g.game = {main_interface = {trade = {open = false, choosing_merchant = false, stillunloading = 0, havetalker = 0,
                                        good = {[0] = vec{}, [1] = vec{}}, goodflag = {[0] = vec{}, [1] = vec{}}},
                              view_sheets = {open = false, active_id = -1}}}
  g.gps = {mouse_x = -1, mouse_y = -1}
  W.focus = {'dwarfmode/Default'}
  W.rows = F.blank_rows()
  W.broker = nil
  dfhack.translation = {translateName = function(n) return n end}
  dfhack.gui = {getCurFocus = function() return W.focus end,
                getDFViewscreen = function() return 'df_screen' end, getCurViewscreen = function() return 'top_screen' end,
                revealInDwarfmodeMap = function(p) W.revealed = p end}
  dfhack.screen = {
    getWindowSize = function() return F.SW, F.SH end,
    readTile = function(x, y)
      local r = W.rows[y]
      if not r or x < 0 or x >= #r then return nil end
      W.reads = (W.reads or 0) + 1
      return {ch = r:byte(x + 1)}
    end,
  }
  dfhack.units.getUnitByNobleRole = function(role) return role == 'broker' and W.broker or nil end
  dfhack.job = {getWorker = function(j) return j._worker end}
  dfhack.matinfo = {decode = function(t, i) return decode(W, t, i) end}
  dfhack.items = {
    getValue = function(it, mer) return it._value end,
    getContainedItems = function(it) return it._contents or {} end,
    getReadableDescription = function(it) return it._desc end,
    checkMandates = function(it) return not it._banned end,
  }
  return W
end

-- items: {type, mat = token, desc, value, stack, flags, contents = {items}, animal, banned,
-- improvements = {mat tokens} (decorations), grown}
function F.item(W, spec)
  W.item_seq = W.item_seq + 1
  local mt, mi = mat_code(W, spec.mat or 'INORGANIC:GRANITE')
  local imps = {}
  for _, tok in ipairs(spec.improvements or {}) do
    local t, i = mat_code(W, tok)
    imps[#imps + 1] = {mat_type = t, mat_index = i}
  end
  local it = {id = spec.id or W.item_seq, flags = spec.flags or {}, flags2 = {grown = spec.grown == true},
              improvements = vec(imps), _type = spec.type, _value = spec.value or 10, _stack = spec.stack or 1,
              _desc = spec.desc or spec.type:lower(), _contents = spec.contents, _mt = mt, _mi = mi,
              _animal = spec.animal, _banned = spec.banned}
  function it.getType(self) return df.item_type[self._type] end
  function it.getStackSize(self) return self._stack end
  function it.getMaterial(self) return self._mt end
  function it.getMaterialIndex(self) return self._mi end
  function it.isAnimalProduct(self) return self._animal == true end
  function it.hasImprovements(self) return #self.improvements > 0 end
  W.items_by_id[it.id] = it
  return it
end

-- a caravan: {entity, state, tr, goods = {items}, civ, wood = bool (elven KILL_PLANT ethic), seized}
function F.caravan(W, spec)
  local ent = spec.entity or 7
  local ids = {}
  for _, it in ipairs(spec.goods or {}) do
    it.flags.trader = true
    ids[#ids + 1] = it.id
  end
  local c = {entity = ent, trade_state = df.caravan_state.T_trade_state[spec.state or 'Approaching'],
             time_remaining = spec.tr or 1500, flags = {seized = spec.seized == true, offended = false},
             goods = vec(ids), _items = spec.goods or {}}
  df.global.plotinfo.caravans:insert('#', c)
  local R = df.ethic_response
  W.entities[ent] = {name = spec.civ or 'The Merchant Guild',
                     entity_raw = {ethic = {[df.ethic_type.KILL_ANIMAL] = R.ACCEPTABLE,
                                            [df.ethic_type.KILL_PLANT] = spec.wood and R.UNTHINKABLE or R.ACCEPTABLE}}}
  return c
end

function F.set_state(c, s) c.trade_state = df.caravan_state.T_trade_state[s] end

function F.remove_caravans() df.global.plotinfo.caravans = vec{} end

-- a built 5x5 trade depot
function F.depot(W, spec)
  spec = spec or {}
  local x, y, z = spec.x or 20, spec.y or 20, spec.z or 10
  local d = W.add_building{id = spec.id or 50, x1 = x, y1 = y, x2 = x + 4, y2 = y + 4, z = z, centerx = x + 2,
                           centery = y + 2, _depot = true}
  d.trade_flags = {trader_requested = false, anyone_can_trade = false}
  d.jobs, d.contained_items = vec{}, vec{}
  d._stage = spec.stage or 1
  function d.getBuildStage(self) return self._stage end
  function d.getMaxBuildStage() return 1 end
  df.global.world.buildings.other.TRADE_DEPOT:insert('#', d)
  return d
end

-- our goods brought to the depot (flags.in_building)
function F.goods(W, d, specs)
  local r = {}
  for _, s in ipairs(specs) do
    s.flags = s.flags or {}
    if s.flags.in_building == nil then s.flags.in_building = true end
    local it = F.item(W, s)
    d.contained_items:insert('#', {item = it})
    r[#r + 1] = it
  end
  return r
end

-- the game's TradeAtDepot job with a worker inside (or outside) the depot
function F.trader(W, d, inside)
  local u = W.add_unit{id = 900, citizen = true, pos = inside == false and {d.x1 - 5, d.y1, d.z} or {d.x1 + 1, d.y1 + 1, d.z}}
  d.jobs:insert('#', {id = 4400, job_type = df.job_type.TradeAtDepot, _worker = u})
  return u
end

---------------------------------------------------------------- simulated vanilla UI behind act.trade
-- opts: disp = display/getValue factor on the merchant side, accept = ratio the merchant needs,
-- unloading = number of opens with stillunloading=1, button = {x, y} of the sheet's Trade label,
-- prompt = DFHack confirm is enabled (prompt after the Trade click, "Cancel trade" on leaving with a
-- selection), ethics = the prompt carries the ethics warning, excess = show "Excess Weight".
-- Open prompts force the pause like a ZScreenModal (gui.lua:1057-1072, dismiss :1034-1040).
function F.ui(W, d, c, opts)
  opts = opts or {}
  local U = {disp = opts.disp or 1.25, accept = opts.accept or 1.2, unloading = opts.unloading or 0,
             button = opts.button or {x = F.SW - 60, y = 20}, prompt = opts.prompt, excess = opts.excess,
             ethics = opts.ethics, offers = 0, trades = 0, calls = {}, reply = nil, dialogs = 0}
  local mi = df.global.game.main_interface
  local t = mi.trade

  local function sel_values()
    local th, ou = 0, 0
    for i = 0, #t.good[0] - 1 do if t.goodflag[0][i].selected then th = th + t.good[0][i]._value end end
    for i = 0, #t.good[1] - 1 do if t.goodflag[1][i].selected then ou = ou + t.good[1][i]._value end end
    return math.floor(th * U.disp), ou
  end
  function U.any_selected()
    for side = 0, 1 do for i = 0, #t.goodflag[side] - 1 do if t.goodflag[side][i].selected then return true end end end
    return false
  end
  function U.is_dialog() return U.screen == 'dialog' or U.screen == 'cancel' end
  function U.open_dialog(kind)
    if not U.is_dialog() then U.saved_pause = df.global.pause_state == true end
    U.screen, W.focus, U.dialogs = kind, {'dfhack/lua/MessageBox'}, U.dialogs + 1
    df.global.pause_state = true
  end
  function U.close_dialog(to)
    if U.is_dialog() then df.global.pause_state = df.global.pause_state and U.saved_pause end
    U.screen, W.focus = to or 'trade', {'dwarfmode/Trade/Default'}
  end
  function U.draw()
    local rows = F.blank_rows()
    if U.screen == 'sheet' then
      F.put(rows, F.SW - 100, 2, 'Trade depot')
      F.put(rows, F.SW - 100, 5, 'Broker requested at depot')
      F.put(rows, F.SW - 100, 7, 'Move goods to/from depot')
      F.put(rows, U.button.x, U.button.y, 'Trade')
    elseif U.screen == 'trade' or U.is_dialog() then
      F.put(rows, 6, 1, 'Merchants from ' .. W.entities[c.entity].name)
      if U.reply then F.put(rows, 6, 3, U.reply) end
      for i = 0, math.min(5, #t.good[0]) - 1 do F.put(rows, 45, 10 + i * 3, 'Value: ~' .. t.good[0][i]._value) end
      local th, ou = sel_values()
      F.put(rows, 6, F.SH - 3, 'Value: ' .. th)
      F.put(rows, 76, F.SH - 3, 'Value: ' .. ou)
      if U.excess then F.put(rows, 6, F.SH - 2, 'Excess Weight: 120') end
      F.put(rows, F.SEIZE_BTN.x, F.SEIZE_BTN.y, 'Seize')
      F.put(rows, F.TRADE_BTN.x, F.TRADE_BTN.y, 'Trade')
      F.put(rows, F.OFFER_BTN.x, F.OFFER_BTN.y, 'Offer')
      if U.screen == 'dialog' then F.dialog(rows, 'Confirm trade', F.MSG_CONFIRM .. (U.ethics and F.MSG_ETHICS or '')) end
      if U.screen == 'cancel' then F.dialog(rows, 'Cancel trade', F.MSG_CANCEL) end
    end
    W.rows = rows
  end
  U.render = U.draw
  local function open_trade()
    t.open, t.mer, t.havetalker, t.choosing_merchant = true, c, 1, false
    t.stillunloading = U.unloading > 0 and 1 or 0
    if U.unloading > 0 then U.unloading = U.unloading - 1 end
    local g0, f0, g1, f1 = {}, {}, {}, {}
    for _, it in ipairs(c._items) do
      if it.flags.trader then g0[#g0 + 1] = it; f0[#f0 + 1] = {selected = false, contained = false, filtered_off = false} end
    end
    for _, e in ipairs(d.contained_items) do
      local it = e.item
      if it.flags.in_building and not it.flags.trader then
        g1[#g1 + 1] = it; f1[#f1 + 1] = {selected = false, contained = false, filtered_off = it._filtered == true}
      end
    end
    t.good = {[0] = vec(g0), [1] = vec(g1)}
    t.goodflag = {[0] = vec(f0), [1] = vec(f1)}
    U.screen, W.focus = 'trade', {'dwarfmode/Trade/Default'}
  end
  local ops = {}
  function ops.request_broker(a)
    local old = {requested = d.trade_flags.trader_requested, anyone = d.trade_flags.anyone_can_trade}
    if a.requested ~= nil then d.trade_flags.trader_requested = a.requested end
    if a.anyone ~= nil then d.trade_flags.anyone_can_trade = a.anyone end
    return true, old
  end
  function ops.open(a)
    if t.open then return true, 'open' end
    if U.screen == 'sheet' then
      if a.x ~= U.button.x or a.y ~= U.button.y then return false, 'no Trade label there' end
      open_trade(); U.render()
      return true, 'clicked'
    end
    if W.focus[1] ~= 'dwarfmode/Default' then return false, 'busy' end
    U.screen, W.focus = 'sheet', {'dwarfmode/ViewSheets/BUILDING/TradeDepot'}
    mi.view_sheets.active_id = a.depot
    U.render()
    return true, 'sheet'
  end
  function ops.mark(a)
    if not t.open then return false, 'trade screen not ready' end
    for side = 0, 1 do for i = 0, #t.goodflag[side] - 1 do t.goodflag[side][i].selected = false end end
    for _, i in ipairs(a.buy) do t.goodflag[0][i].selected = true end
    for _, i in ipairs(a.sell) do t.goodflag[1][i].selected = true end
    U.marks = (U.marks or 0) + 1
    U.render()
    return true, {buy = #a.buy, sell = #a.sell}
  end
  local function evaluate()
    U.offers = U.offers + 1
    local th, ou = sel_values()
    U.last = {theirs = th, ours = ou}
    if th > 0 and ou >= th * U.accept then
      for i = 0, #t.good[0] - 1 do
        if t.goodflag[0][i].selected then t.good[0][i].flags.trader = false end
        t.goodflag[0][i].selected = false
      end
      for i = 0, #t.good[1] - 1 do t.goodflag[1][i].selected = false end
      U.trades, U.reply = U.trades + 1, 'That seems fair.  You have yourself a deal.'
    else
      U.reply = "I won't trade at a loss."
    end
  end
  U.evaluate = evaluate
  function ops.offer(a)
    if U.screen == 'dialog' then
      if U.ethics then U.close_dialog('trade'); U.render(); return false, 'ethics warning in the confirm prompt: dismissed' end
      evaluate(); U.close_dialog('trade'); U.render()
      return true, 'confirmed'
    end
    if not t.open then return false, 'trade screen not ready' end
    if U.prompt and U.any_selected() then U.open_dialog('dialog'); U.render(); return true, 'clicked' end
    evaluate(); U.render()
    return true, 'clicked'
  end
  function ops.close(a)
    if a.clear ~= false and t.open then
      for side = 0, 1 do for i = 0, #t.goodflag[side] - 1 do t.goodflag[side][i].selected = false end end
    end
    if U.is_dialog() then U.close_dialog('trade') end
    t.open, U.screen, W.focus = false, nil, {'dwarfmode/Default'}
    U.render()
    return true, 1
  end
  W.act_result('trade', function(op, a)
    U.calls[#U.calls + 1] = op
    return ops[op](a or {})
  end)
  U.ops = ops
  return U
end

-- the same simulated UI one level lower, for act.trade = the WP9 proposal: it only sees fields,
-- clicks and keys (view_sheets writes, gps + simulateInput, goodflag). The screen buffer is drawn
-- once per frame (at its first read), so what changes later in a frame, like a prompt opened by a
-- key we just sent, is not on the screen yet. Extra opts: eat_select = the prompt ignores SELECT.
-- Returns U and a gui fake.
function F.dfui(W, d, c, opts)
  local U = F.ui(W, d, c, opts)
  U.eat_select = opts and opts.eat_select
  local mi = df.global.game.main_interface
  local vs = {open = false, active_id = -1}
  local drawn_ms
  U.render = function() end
  mi.view_sheets = setmetatable({}, {__index = vs, __newindex = function(_, k, v)
    vs[k] = v
    if k == 'open' and v == true and W.focus[1] == 'dwarfmode/Default' then
      U.screen, W.focus = 'sheet', {'dwarfmode/ViewSheets/BUILDING/TradeDepot'}
    end
  end})
  local readTile = dfhack.screen.readTile
  dfhack.screen.readTile = function(x, y)
    if drawn_ms ~= W.ms then drawn_ms = W.ms; U.draw() end
    return readTile(x, y)
  end
  local function on_label(x, y, b) return y == b.y and x >= b.x and x < b.x + 5 end
  U.misclicks, U.wrong_screen = 0, 0
  local gui = {
    get_interface_rect = function() return {x1 = 0, y1 = 0, x2 = F.SW - 1, y2 = F.SH - 1, width = F.SW, height = F.SH} end,
    compute_frame_rect = F.compute_frame_rect,
    simulateInput = function(scr, key)
      local x, y = df.global.gps.mouse_x, df.global.gps.mouse_y
      local want = U.is_dialog() and 'top_screen' or 'df_screen'
      if key == 'SELECT' or key == 'LEAVESCREEN' then
        if scr ~= want and not (scr == 'top_screen' and not U.is_dialog()) then U.wrong_screen = U.wrong_screen + 1; return end
      end
      if key == '_MOUSE_L' then
        if U.screen == 'sheet' and on_label(x, y, U.button) then U.ops.open({depot = d.id, x = U.button.x, y = U.button.y})
        elseif U.screen == 'trade' and on_label(x, y, F.TRADE_BTN) then U.ops.offer({})
        else U.misclicks = U.misclicks + 1 end
      elseif key == 'SELECT' then
        if U.screen == 'dialog' and not U.eat_select then U.evaluate(); U.close_dialog('trade')
        elseif U.screen == 'cancel' then U.close_dialog('sheet'); mi.trade.open = false
          W.focus = {'dwarfmode/ViewSheets/BUILDING/TradeDepot'} end
      elseif key == 'LEAVESCREEN' then
        if U.is_dialog() then U.close_dialog('trade')                    -- Esc = "No"
        elseif U.screen == 'trade' then
          if U.prompt and U.any_selected() then U.open_dialog('cancel')  -- confirm 'trade-cancel'
          else mi.trade.open, U.screen, W.focus = false, 'sheet', {'dwarfmode/ViewSheets/BUILDING/TradeDepot'} end
        elseif U.screen == 'sheet' then
          vs.open, U.screen, W.focus = false, nil, {'dwarfmode/Default'}
        end
      end
      U.render()
    end,
  }
  return U, gui
end

-- a fake gate (K.call target): state(bridge) from W.bridge_state, want() recorded
function F.gate(W, manifest_bridges)
  W.bridge_state, W.gate_wants = {}, {}
  local G = {name = 'gate', every = {ticks = 600}}
  function G.state(K, b) if b == nil then return {} end return W.bridge_state[b] or 'unknown' end
  function G.want(K, b, w, why) W.gate_wants[#W.gate_wants + 1] = {b, w, why}; W.bridge_state[b] = w; return true, 'wanted' end
  W.load(G)
  return G
end

-- n frames of 1 tick each (16 ms per frame in k_mock)
function F.frames(W, n) for _ = 1, n do W.frame(1) end end

-- run until cond() or max frames; returns frames used or nil
function F.until_(W, cond, max)
  for i = 1, max or 2000 do
    if cond() then return i end
    W.frame(1)
  end
  return cond() and (max or 2000) or nil
end

function F.calls(W, fn)
  local r = {}
  for _, a in ipairs(W.find_acts(fn)) do r[#r + 1] = a end
  return r
end

function F.events(W, phase)
  local r = {}
  for _, e in ipairs(W.find_events('CARAVAN')) do if phase == nil or e.d.phase == phase then r[#r + 1] = e end end
  return r
end

return F
