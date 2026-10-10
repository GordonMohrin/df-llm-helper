-- tools/embark/input.lua: queue of UI input actions played out over frames.
-- A click = hover (mouse held on the target for hover_ms), one simulated press, then hold
-- for after_ms. Run 6 showed that buttons and list rows often ignore a click without the
-- hover phase. All DF writes are done by the env functions that embark.lua provides:
--   env.now() -> ms              env.mouse(tx, ty, px, py)   (gps mouse fields, view only)
--   env.sim(keys)                (gui.simulateInput on the native DF screen)
--   env.tile_px() -> tpx, tpy    (gps.tile_pixel_x/y; changes with the window size)
--   env.win() -> w, h            (window size in tiles, dfhack.screen.getWindowSize)
local I = {}
local Q = {}
Q.__index = Q

function I.new(env, cfg)
  cfg = cfg or {}
  return setmetatable({env = env, q = {}, hover_ms = cfg.hover_ms or 1000, after_ms = cfg.after_ms or 600,
    key_ms = cfg.key_ms or 300, done = 0}, Q)
end

function Q:idle() return #self.q == 0 end

-- interface tile (tx, ty): precise pixel = tile centre
function Q:click_tile(tx, ty, opt)
  opt = opt or {}
  local tpx, tpy = self.env.tile_px()
  self.q[#self.q + 1] = {kind = 'click', tx = tx, ty = ty, px = tx * tpx + tpx // 2, py = ty * tpy + tpy // 2,
    button = opt.button or 'L', hover = opt.hover_ms or self.hover_ms, after = opt.after_ms or self.after_ms}
end

-- screen pixel (map ports read precise_mouse_x/y, Lua API.txt "simulateInput")
function Q:click_px(px, py, opt)
  opt = opt or {}
  local tpx, tpy = self.env.tile_px()
  self.q[#self.q + 1] = {kind = 'click', tx = px // tpx, ty = py // tpy, px = px, py = py,
    button = opt.button or 'L', hover = opt.hover_ms or self.hover_ms, after = opt.after_ms or self.after_ms}
end

-- percent of the window (integers), e.g. 50, 50 = centre; env.win() -> width, height in tiles
function Q:click_pct(fx, fy, opt)
  local w, h = self.env.win()
  local tpx, tpy = self.env.tile_px()
  self:click_px(w * tpx * fx // 100, h * tpy * fy // 100, opt)
end

function Q:key(name, opt)
  self.q[#self.q + 1] = {kind = 'key', name = name, after = (opt and opt.after_ms) or self.key_ms}
end

function Q:wait(ms) self.q[#self.q + 1] = {kind = 'wait', after = ms} end

function Q:clear() self.q = {} end

-- advance the head action; call once per frame
function Q:frame()
  local a = self.q[1]
  if not a then return end
  local now = self.env.now()
  if a.kind == 'click' then
    self.env.mouse(a.tx, a.ty, a.px, a.py)
    if not a.t0 then a.t0 = now end
    if not a.pressed and now - a.t0 >= a.hover then
      local b = a.button
      self.env.sim({['_MOUSE_' .. b] = true, ['_MOUSE_' .. b .. '_DOWN'] = true})  -- gui.lua:46-52
      a.pressed, a.t1 = true, now
    elseif a.pressed and now - a.t1 >= a.after then
      table.remove(self.q, 1); self.done = self.done + 1
    end
  elseif a.kind == 'key' then
    if not a.t1 then self.env.sim(a.name); a.t1 = now
    elseif now - a.t1 >= a.after then table.remove(self.q, 1); self.done = self.done + 1 end
  elseif a.kind == 'wait' then
    a.t1 = a.t1 or now
    if now - a.t1 >= a.after then table.remove(self.q, 1); self.done = self.done + 1 end
  end
end

return I
