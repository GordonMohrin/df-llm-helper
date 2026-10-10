-- WP9 act.trade proposal (tests/lua/trade_act_proposal.lua): label-verified clicks, checkbox
-- ticking, depot toggles, confirm prompts, close. Fakes the DF UI fields it touches; live-untested.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local F = require('trade_world')
local P = require('trade_act_proposal')

local function int(v) return math.type(v) == 'integer' and v or math.tointeger(v) end

local function env()
  local W = kmock.new{}
  local E = {inputs = {}, focus = {'dwarfmode/Default'}, rows = F.blank_rows()}
  df.building_tradedepotst = {is_instance = function(_, b) return type(b) == 'table' and b._depot == true end}
  df.view_sheet_type = {UNIT = 0, ITEM = 1, BUILDING = 2}
  local d = W.add_building{id = 50, _depot = true, centerx = 22, centery = 22, z = 10}
  d.trade_flags = {trader_requested = false, anyone_can_trade = false}
  W.add_building{id = 51}
  df.global.gps = {mouse_x = -1, mouse_y = -1}
  local t = {open = false, choosing_merchant = false, good = {[0] = kmock.vec{}, [1] = kmock.vec{}},
             goodflag = {[0] = kmock.vec{}, [1] = kmock.vec{}}}
  df.global.game = {main_interface = {trade = t, view_sheets = {open = false, active_id = -1}}}
  dfhack.gui = {getCurFocus = function() return E.focus end, getDFViewscreen = function() return 'df' end,
                getCurViewscreen = function() return 'top' end, revealInDwarfmodeMap = function(p, c) E.reveal = p end}
  E.reads = 0
  dfhack.screen = {getWindowSize = function() return F.SW, F.SH end,
                   readTile = function(x, y)
                     E.reads = E.reads + 1
                     local r = E.rows[y]
                     if not r or x < 0 or x >= #r then return nil end
                     return {ch = r:byte(x + 1)}
                   end}
  local gui = {
    simulateInput = function(scr, key)
      E.inputs[#E.inputs + 1] = {scr = scr, key = key, x = df.global.gps.mouse_x, y = df.global.gps.mouse_y}
      if E.on_input then E.on_input(key) end
    end,
    get_interface_rect = function() return {x1 = 0, y1 = 0, x2 = F.SW - 1, y2 = F.SH - 1, width = F.SW, height = F.SH} end,
    compute_frame_rect = F.compute_frame_rect,
  }
  local I = {}
  P.install(I, gui, int)
  E.I, E.d, E.t, E.W = I, d, t, W
  return E
end

local function lists(E, n0, n1)
  local g0, f0, g1, f1 = {}, {}, {}, {}
  for i = 1, n0 do g0[i] = {id = i}; f0[i] = {selected = false, filtered_off = false} end
  for i = 1, n1 do g1[i] = {id = 100 + i}; f1[i] = {selected = false, filtered_off = false} end
  E.t.good = {[0] = kmock.vec(g0), [1] = kmock.vec(g1)}
  E.t.goodflag = {[0] = kmock.vec(f0), [1] = kmock.vec(f1)}
  E.t.open = true
  E.focus = {'dwarfmode/Trade/Default'}
end

---------------------------------------------------------------- confirm's frame geometry
-- the installed DFHack's gui.lua compute_frame_rect, loaded from its source (nil if not readable)
local function installed_compute_frame_rect()
  local dll = os.getenv('DFLLM_LUA53') or 'E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack/lua53.dll'
  local f = io.open((dll:gsub('\\', '/'):gsub('[^/]+$', '')) .. 'lua/gui.lua', 'r')
  if not f then return nil end
  local src = f:read('a'); f:close()
  local a = src:find('local function align_coord', 1, true)
  local b = src:find('function compute_frame_rect', 1, true)
  local e = b and select(2, src:find('\n    return rect\nend\n', b, true))
  if not (a and e) then return nil end
  local chunk = 'local function mkdims_wh(x1,y1,w,h) return {x1=x1,y1=y1,x2=x1+w-1,y2=y1+h-1,width=w,height=h} end\n'
    .. src:sub(a, e) .. '\nreturn compute_frame_rect'
  local fn = assert(load(chunk, '=gui.lua', 't', {math = math}))
  return fn()
end

T.test('frame: the Trade button frame is centred in [0, W-23) like DFHack lays it out', function()
  local TRADE = {l = 0, r = 23, b = 4, w = 11, h = 3}
  local want = {[114] = {40, 50}, [160] = {63, 73}, [240] = {103, 113}}      -- not W-34..W-24
  for w, x in pairs(want) do
    local r = F.compute_frame_rect(w, 60, TRADE, 0, 0)
    T.eq({r.x1, r.x2, r.y1, r.y2}, {x[1], x[2], 53, 55}, 'width ' .. w)
  end
  local real = installed_compute_frame_rect()
  if not real then print('# skip: installed hack/lua/gui.lua not readable'); return end
  local specs = {TRADE, {l = 0, r = 73, b = 4, w = 11, h = 3}, {l = 40, r = 5, b = 4, w = 19, h = 3},
                 {r = 47, b = 7, w = 12, h = 3}, {w = 50, h = 17}}
  for _, w in ipairs({114, 131, 160, 199, 240}) do
    for _, h in ipairs({50, 60, 90}) do
      for _, s in ipairs(specs) do T.eq(F.compute_frame_rect(w, h, s, 0, 0), real(w, h, s, 0, 0)) end
    end
  end
end)

T.test('frame: the fake trade screen puts Seize, Trade and Offer into their confirm frames', function()
  for _, size in ipairs({{114, 50}, {160, 60}, {240, 90}}) do
    F.set_size(size[1], size[2])
    for name, spec in pairs({TRADE_BTN = {l = 0, r = 23, b = 4, w = 11, h = 3}, SEIZE_BTN = {l = 0, r = 73, b = 4, w = 11, h = 3},
                             OFFER_BTN = {l = 40, r = 5, b = 4, w = 19, h = 3}}) do
      local r, b = F.compute_frame_rect(F.SW, F.SH, spec, 0, 0), F[name]
      T.ok(b.x >= r.x1 and b.x + 4 <= r.x2 and b.y >= r.y1 and b.y <= r.y2, name .. ' at ' .. F.SW)
    end
  end
  F.set_size(160, 60)
end)

---------------------------------------------------------------- ops
T.test('request_broker: sets the depot toggles, returns the old ones', function()
  local E = env()
  T.eq({E.I.trade('request_broker', {depot = 99})}, {false, 'no trade depot 99'})
  T.eq(E.I.trade('request_broker', {depot = 51}), false)                  -- not a depot
  local ok, old = E.I.trade('request_broker', {depot = 50, requested = true})
  T.eq({ok, old}, {true, {requested = false, anyone = false}})
  T.eq(E.d.trade_flags, {trader_requested = true, anyone_can_trade = false})
  local _, old2 = E.I.trade('request_broker', {depot = 50, anyone = true})
  T.eq(old2, {requested = true, anyone = false})
  T.eq(E.d.trade_flags, {trader_requested = true, anyone_can_trade = true})
  E.I.trade('request_broker', {depot = 50, requested = false, anyone = false})
  T.eq(E.d.trade_flags, {trader_requested = false, anyone_can_trade = false})
  T.eq(#E.inputs, 0)
end)

T.test('open: map -> depot sheet like clicking the depot', function()
  local E = env()
  T.eq({E.I.trade('open', {depot = 50})}, {true, 'sheet'})
  local vs = df.global.game.main_interface.view_sheets
  T.eq({vs.open, vs.active_sheet, vs.active_id, vs.viewing_bldid}, {true, 2, 50, 50})
  T.eq(E.reveal, {x = 22, y = 22, z = 10})
  E.focus = {'dwarfmode/Stocks/Default'}
  local ok, why = E.I.trade('open', {depot = 50})
  T.eq(ok, false); T.ok(why:find('busy', 1, true))
  E.focus = {'dfhack/lua/MessageBox', 'dwarfmode/Default'}
  T.eq(E.I.trade('open', {depot = 50}), false)
  T.eq(#E.inputs, 0)
end)

T.test('open: the sheet click only lands on a verified "Trade" label', function()
  local E = env()
  E.focus = {'dwarfmode/ViewSheets/BUILDING/TradeDepot'}
  df.global.game.main_interface.view_sheets.active_id = 50
  F.put(E.rows, 60, 2, 'Trade depot'); F.put(E.rows, 100, 20, 'Trade'); F.put(E.rows, 10, 30, 'Traders')
  T.eq(E.I.trade('open', {depot = 50}), false)                           -- position required
  T.eq(E.I.trade('open', {depot = 50, x = 101, y = 20}), false)          -- not the label start
  T.eq(E.I.trade('open', {depot = 50, x = 10, y = 30}), false)           -- 'Traders'
  T.eq(E.I.trade('open', {depot = 50, x = 60, y = 2}), false)            -- 'Trade depot' is the title
  T.eq(#E.inputs, 0)
  T.eq({E.I.trade('open', {depot = 50, x = 100, y = 20})}, {true, 'clicked'})
  T.eq(E.inputs, {{scr = 'df', key = '_MOUSE_L', x = 102, y = 20}})
  df.global.game.main_interface.view_sheets.active_id = 51
  T.eq(E.I.trade('open', {depot = 50, x = 100, y = 20}), false)          -- another building's sheet
  E.t.open = true
  T.eq({E.I.trade('open', {depot = 50})}, {true, 'open'})
end)

T.test('mark: ticks exactly the given checkboxes, validates first', function()
  local E = env()
  T.eq(E.I.trade('mark', {buy = {0}, sell = {0}}), false)                -- screen closed
  lists(E, 3, 4)
  E.focus = {'dfhack/lua/MessageBox', 'dwarfmode/Trade/Default'}
  T.eq(E.I.trade('mark', {buy = {0}, sell = {0}}), false)                -- a dialog on top
  E.focus = {'dwarfmode/Trade/Default'}
  T.eq(E.I.trade('mark', {buy = {3}, sell = {0}}), false)                -- out of range
  T.eq(E.I.trade('mark', {buy = {0}}), false)                            -- sell missing
  E.t.goodflag[1][2].filtered_off = true
  T.eq(E.I.trade('mark', {buy = {0}, sell = {2}}), false)
  E.t.goodflag[1][3].selected = true                                     -- stale selection is cleared
  local ok, n = E.I.trade('mark', {buy = {0, 2}, sell = {1}})
  T.eq({ok, n}, {true, {buy = 2, sell = 1}})
  local s = {}
  for side = 0, 1 do for i = 0, #E.t.goodflag[side] - 1 do if E.t.goodflag[side][i].selected then s[#s + 1] = side .. ':' .. i end end end
  T.eq(s, {'0:0', '0:2', '1:1'})
  E.t.good[1]:insert('#', {id = 999})                                    -- lists out of sync
  T.eq(E.I.trade('mark', {buy = {}, sell = {}}), false)
  T.eq(#E.inputs, 0)
end)

T.test('offer: clicks Trade inside its centred button frame, never Seize/Offer', function()
  local E = env()
  lists(E, 2, 2)
  -- frame {l=0, r=23, b=4, w=11, h=3}: x 63..73, y 53..55 on a 160x60 screen
  F.put(E.rows, F.SEIZE_BTN.x, F.SEIZE_BTN.y, 'Seize'); F.put(E.rows, F.OFFER_BTN.x, F.OFFER_BTN.y, 'Offer')
  F.put(E.rows, 129, 54, 'Trade')                                        -- the old right-aligned guess
  T.eq({E.I.trade('offer', {})}, {false, 'no Trade label in the Trade button frame'})
  T.eq(#E.inputs, 0)
  T.ok(E.reads <= 3 * 11 + 7, 'reads ' .. E.reads)                       -- only the button frame
  F.put(E.rows, F.TRADE_BTN.x, F.TRADE_BTN.y, 'Trade')
  T.eq({F.TRADE_BTN.x, F.TRADE_BTN.y}, {66, 54})
  T.eq({E.I.trade('offer', {})}, {true, 'clicked'})
  T.eq(E.inputs, {{scr = 'df', key = '_MOUSE_L', x = 68, y = 54}})
  E.t.choosing_merchant = true
  T.eq(E.I.trade('offer', {}), false)
end)

T.test('offer: SELECT only on our drawn confirm prompt; the ethics prompt is dismissed', function()
  local E = env()
  E.focus = {'dfhack/lua/MessageBox'}
  F.dialog(E.rows, 'Leave', 'Are you sure you want leave this screen?')
  T.eq({E.I.trade('offer', {})}, {false, 'unknown dialog'})
  E.rows = F.blank_rows()                                                -- ours, not drawn yet
  T.eq({E.I.trade('offer', {})}, {false, 'unknown dialog'})
  T.eq(#E.inputs, 0)
  E.reads = 0
  F.dialog(E.rows, 'Confirm trade', F.MSG_CONFIRM)
  T.eq({E.I.trade('offer', {})}, {true, 'confirmed'})
  T.eq(E.inputs, {{scr = 'top', key = 'SELECT', x = -1, y = -1}})
  T.ok(E.reads <= 17 * 55, 'dialog reads ' .. E.reads)                   -- the centred dialog rect only
  E.rows = F.blank_rows()
  F.dialog(E.rows, 'Confirm trade', F.MSG_CONFIRM .. F.MSG_ETHICS)
  local ok, why = E.I.trade('offer', {})
  T.eq(ok, false); T.ok(why:find('ethics', 1, true), why)
  T.eq(E.inputs[2], {scr = 'top', key = 'LEAVESCREEN', x = -1, y = -1}) -- Esc = "No"
  T.eq(#E.inputs, 2)
  for _, size in ipairs({{114, 50}, {240, 90}}) do                       -- found at other window sizes
    F.set_size(size[1], size[2])
    E.rows, E.inputs = F.blank_rows(), {}
    F.dialog(E.rows, 'Confirm trade', F.MSG_CONFIRM .. F.MSG_ETHICS)
    T.eq(E.I.trade('offer', {}), false)
    T.eq(E.inputs[1].key, 'LEAVESCREEN', 'size ' .. size[1])
  end
  F.set_size(160, 60)
end)

T.test('close: clears our selection, LEAVESCREEN while trade/sheet is on top', function()
  local E = env()
  lists(E, 2, 2)
  E.t.goodflag[0][1].selected, E.t.goodflag[1][0].selected = true, true
  local steps = {{'dwarfmode/ViewSheets/BUILDING/TradeDepot'}, {'dwarfmode/Default'}}
  E.on_input = function(key) if key == 'LEAVESCREEN' then E.focus = table.remove(steps, 1) end end
  T.eq({E.I.trade('close', {})}, {true, 2})
  T.eq({E.t.goodflag[0][1].selected, E.t.goodflag[1][0].selected}, {false, false})
  T.eq(E.inputs[1].key, 'LEAVESCREEN')
  T.eq(E.inputs[1].scr, 'df')
end)

T.test('close: answers our drawn Confirm/Cancel prompt first, never a foreign dialog', function()
  -- "Confirm trade": Esc (No) back to the trade screen, then out; "Cancel trade": Yes = leave it
  for _, case in ipairs({{F.MSG_CONFIRM, {'top:LEAVESCREEN', 'df:LEAVESCREEN', 'df:LEAVESCREEN'}},
                         {F.MSG_CONFIRM .. F.MSG_ETHICS, {'top:LEAVESCREEN', 'df:LEAVESCREEN', 'df:LEAVESCREEN'}},
                         {F.MSG_CANCEL, {'top:SELECT', 'df:LEAVESCREEN'}}}) do
    local E = env()
    lists(E, 1, 1)
    E.t.goodflag[1][0].selected = true
    E.focus = {'dfhack/lua/MessageBox'}
    F.dialog(E.rows, 'Trade', case[1])
    local steps = {{'dwarfmode/Trade/Default'}, {'dwarfmode/ViewSheets/BUILDING/TradeDepot'}, {'dwarfmode/Default'}}
    E.on_input = function(key)
      if key == 'SELECT' then table.remove(steps, 1) end         -- "Yes": the trade screen is left
      E.focus = table.remove(steps, 1)
    end
    T.eq({E.I.trade('close', {clear = true})}, {true, #case[2]})
    local seen = {}
    for _, i in ipairs(E.inputs) do seen[#seen + 1] = i.scr .. ':' .. i.key end
    T.eq(seen, case[2])
    T.eq(E.focus, {'dwarfmode/Default'})
    T.eq(E.t.goodflag[1][0].selected, false)
  end
  local E2 = env()
  lists(E2, 1, 1)
  E2.t.goodflag[0][0].selected = true
  E2.focus = {'dfhack/lua/MessageBox'}
  F.dialog(E2.rows, 'Delete uniform', 'Are you sure you want to delete this uniform?')
  T.eq({E2.I.trade('close', {clear = false})}, {true, 0})                -- never closes a foreign dialog
  T.eq(E2.t.goodflag[0][0].selected, true)
  T.eq(#E2.inputs, 0)
  -- a prompt that opens on our LEAVESCREEN is not drawn yet: stop (trade.lua sweeps it later)
  local E3 = env()
  lists(E3, 1, 1)
  E3.on_input = function(key) if key == 'LEAVESCREEN' then E3.focus = {'dfhack/lua/MessageBox'} end end
  T.eq({E3.I.trade('close', {})}, {true, 1})
  T.eq(#E3.inputs, 1)
end)

---------------------------------------------------------------- trade.lua driving the proposal
-- on a field/click-level fake UI: the label positions trade.lua finds are the ones act verifies,
-- no click misses, prompts force the pause until they are answered or dismissed
local function integration(opts, o)
  o = o or {}
  local W = F.world{}
  local d = F.depot(W, {})
  local goods = {F.item(W, {type = 'BAR', mat = 'INORGANIC:IRON', desc = 'iron bars', value = 100, stack = 5}),
                 F.item(W, {type = 'CLOTH', mat = 'CREATURE:SPIDER_CAVE_GIANT:SILK', desc = 'silk cloth', value = 60})}
  local c = F.caravan(W, {state = 'Approaching', goods = goods})
  F.goods(W, d, {{type = 'FIGURINE', value = 300}, {type = 'RING', value = 200}, {type = 'CROWN', value = 120}})
  W.broker = W.add_unit{id = 901, citizen = true, pos = {0, 0, 0}}
  local U, gui = F.dfui(W, d, c, opts)
  local I = {}
  P.install(I, gui, int)
  W.act_result('trade', function(op, a) return I.trade(op, a) end)
  package.loaded['dfllm.trade'] = nil
  local M = require('dfllm.trade')
  W.load(M)
  local frame, R = W.frame, {worst = 0}           -- screen reads (trade.lua + act) in every frame
  W.frame = function(...)
    W.reads = 0
    frame(...)
    R.worst = math.max(R.worst, W.reads)
    if o.hook then o.hook(W, U) end
  end
  W.frame(1)
  W.run(200, {skip = 9})
  F.set_state(c, 'AtDepot')
  F.trader(W, d, true)
  W.run(900, {skip = 9})
  for _ = 1, o.frames or 600 do
    W.frame(1)
    if o.stop and o.stop(W, U) then break end
    if not o.stop and #F.events(W, 'traded') > 0 then break end
  end
  return W, U, d, R.worst, M
end

local function no_prompt_left(W, U)
  for _, s in ipairs(W.focus) do T.ok(not s:find('^dfhack/'), 'focus ' .. s) end
  T.eq(df.global.pause_state, false)
  T.ok(not U.is_dialog(), tostring(U.screen))
end

T.test('integration: trade.lua + proposal: depot sheet, Trade label, ratio, close', function()
  local W, U, d = integration({})
  T.eq(#F.events(W, 'traded'), 1)
  T.eq(U.trades, 1)
  T.eq({U.misclicks, U.wrong_screen}, {0, 0})
  T.ok(U.last.ours * 100 >= U.last.theirs * 150)
  F.frames(W, 10)
  T.eq(U.screen, nil)                                -- back on the map after two LEAVESCREEN
  T.eq(d.trade_flags.trader_requested, false)
  T.eq(#W.find_events('ACT_FAIL'), 0)
end)

T.test('integration: with the DFHack confirm prompt and a display factor above the guess', function()
  local W, U = integration({prompt = true, disp = 1.9})
  T.eq(U.trades, 1)
  T.eq({U.misclicks, U.wrong_screen}, {0, 0})
  local marks, offers = 0, 0
  for _, a in ipairs(W.find_acts('trade')) do
    if a.args[1] == 'mark' then marks = marks + 1 end
    if a.args[1] == 'offer' then offers = offers + 1 end
  end
  T.ok(marks >= 2, 'recalibrated: ' .. marks .. ' marks')
  T.eq(offers, 2)                                    -- the Trade click and the prompt's SELECT
  F.frames(W, 10)
  no_prompt_left(W, U)
  T.eq(U.dialogs, 1)                                 -- no "Cancel trade" prompt: selection was cleared
end)

T.test('integration: an ethics prompt is dismissed, the visit fails, nothing stays paused', function()
  local function failed(W) return #F.events(W, 'failed') > 0 end
  local W, U = integration({prompt = true, ethics = true}, {stop = failed})
  T.ok(failed(W), 'failed')
  T.eq(F.events(W, 'failed')[1].d.why, 'ethics')
  T.eq(U.trades, 0)
  F.frames(W, 10)
  no_prompt_left(W, U)
  T.eq(U.screen, nil)
  T.eq({U.misclicks, U.wrong_screen}, {0, 0})
end)

T.test('integration: a prompt that ignores SELECT is dismissed on give-up, nothing stays paused', function()
  local function failed(W) return #F.events(W, 'failed') > 0 end
  local W, U = integration({prompt = true, eat_select = true}, {stop = failed})
  T.ok(failed(W), 'failed')
  T.eq(F.events(W, 'failed')[1].d.why, 'dialog')
  F.frames(W, 10)
  no_prompt_left(W, U)
  T.eq(U.screen, nil)
end)

T.test('integration: a "Cancel trade" prompt left by a stale selection is swept', function()
  -- a selection the close cannot clear (the merchant side re-ticks itself): LEAVESCREEN opens the
  -- prompt during act close; it is not drawn yet, so the sweep dismisses it on a later frame
  local function failed(W) return #F.events(W, 'failed') > 0 end
  local W, U = integration({prompt = true, accept = 50, eat_select = false}, {stop = function(W)
    local t = df.global.game.main_interface.trade
    if t.open and #t.goodflag[0] > 0 and not W._sticky then
      W._sticky = true
      local f0 = t.goodflag[0][0]
      t.goodflag[0][0] = setmetatable({}, {__index = function(_, k) if k == 'selected' then return true end return f0[k] end,
                                           __newindex = function(_, k, v) if k ~= 'selected' then f0[k] = v end end})
    end
    return failed(W) or #F.events(W, 'retry') > 0
  end, frames = 1500})
  T.ok(#F.events(W, 'retry') + #F.events(W, 'failed') > 0, 'gave up')
  T.ok(U.dialogs >= 2, 'cancel prompt opened: ' .. U.dialogs)
  F.frames(W, 40)
  no_prompt_left(W, U)
end)

T.test('integration: SIEGE in the frame of the Trade click: the undrawn prompt is swept, no pause stays', function()
  local seen
  local W, U = integration({prompt = true}, {frames = 100, hook = function(W, U)
    if seen == nil and U.is_dialog() then
      seen = df.global.pause_state == true
      W.K.set_mode('SIEGE', 'test')                  -- before the prompt was ever drawn
      seen = seen and U.is_dialog()                  -- not dismissed unread
    end
  end})
  T.eq(seen, true)
  no_prompt_left(W, U)
  T.eq(U.screen, nil)
  T.eq(U.trades, 0)
  T.eq({U.misclicks, U.wrong_screen}, {0, 0})
end)

T.test('integration: screen reads per frame <= 1,000 at 240x90 (trade.lua and act, prompt on)', function()
  F.set_size(240, 90)
  local W, U, _, worst, M = integration({prompt = true, disp = 1.9})
  F.set_size(160, 60)
  T.eq(U.trades, 1)
  T.eq({U.misclicks, U.wrong_screen}, {0, 0})
  T.ok(worst <= 1000 and worst <= M.CFG.READS, 'reads per frame ' .. worst)
  T.ok(worst > 900, 'budget used: ' .. worst)
end)

T.test('integration: a sheet button outside the sheet region is found on the whole screen', function()
  local W, U, _, worst = integration({button = {x = 10, y = 45}})
  T.eq(U.trades, 1)
  T.eq(U.misclicks, 0)
  T.ok(worst <= 1000, 'reads per frame ' .. worst)
end)

T.test('dispatcher: unknown ops refused, missing args tolerated', function()
  local E = env()
  T.eq({E.I.trade('seize', {})}, {false, 'unknown trade op seize'})
  T.eq(E.I.trade('request_broker'), false)
  T.eq({E.I.trade('close')}, {true, 0})
end)

T.done()
