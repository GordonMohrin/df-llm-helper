-- tools/embark/input.lua: queue of UI input actions played out over frames.
-- A click = hover (mouse held on the target for hover_ms), one simulated press, then hold
-- for after_ms. Run 6 showed that buttons and list rows often ignore a click without the
-- hover phase. All DF writes are done by the env functions that embark.lua provides:
--   env.now() -> ms              env.mouse(tx, ty, px, py, focus)   (gps mouse fields + mouse focus, view only)
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

-- Live L0 (DF on a hidden virtual desktop, so DF has no mouse focus and resets the mouse to -1
-- every frame):
-- * hold(px, py) keeps the mouse on a pixel every frame while no click plays AND claims the
--   mouse focus (env.mouse(..., true)); only then does the placing rectangle follow the mouse and
--   the site panel get drawn. release() ends the hold.
-- * clicks do NOT claim the focus: with the focus DF takes the real OS cursor (wherever Gordon's
--   mouse is) for the click, so a map click would open the popup on the wrong rectangle. Without
--   the focus a map click opens the popup on the rectangle as it is. Every click therefore gives
--   the focus back first (env.unfocus); unfocus() queues the same as a separate action.
function Q:hold(px, py)
  local tpx, tpy = self.env.tile_px()
  self.held = {px // tpx, py // tpy, px, py}
end
function Q:release() self.held = nil end
function Q:unfocus(ms)
  self.held = nil
  self.q[#self.q + 1] = {kind = 'unfocus', after = ms or 100}
end
-- * With the focus claimed DF also writes the cached OS cursor position into the mouse on every
--   render frame, so a held pixel alternates with that position (and a click takes it). probe()
--   claims the focus for `frames` frames without writing the mouse and stores the most frequent
--   position DF wrote in self.real ({px, py}) or false. Holding exactly that pixel removes the
--   conflict (local.place moves the camera so that it lands on the target).
function Q:probe(frames)
  self.held, self.real = nil, nil
  self.q[#self.q + 1] = {kind = 'probe', n = frames or 120, seen = {}}
end

local function click(self, tx, ty, px, py, opt)
  self.q[#self.q + 1] = {kind = 'click', tx = tx, ty = ty, px = px, py = py, focus = opt.focus == true,
    button = opt.button or 'L', hover = opt.hover_ms or self.hover_ms, after = opt.after_ms or self.after_ms}
end

-- interface tile (tx, ty): precise pixel = tile centre
function Q:click_tile(tx, ty, opt)
  opt = opt or {}
  local tpx, tpy = self.env.tile_px()
  click(self, tx, ty, tx * tpx + tpx // 2, ty * tpy + tpy // 2, opt)
end

-- screen pixel (map ports read precise_mouse_x/y, Lua API.txt "simulateInput")
function Q:click_px(px, py, opt)
  opt = opt or {}
  local tpx, tpy = self.env.tile_px()
  click(self, px // tpx, py // tpy, px, py, opt)
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

function Q:clear() self.q, self.held = {}, nil end

-- advance the head action; call once per frame
function Q:frame()
  local a = self.q[1]
  if self.held and (not a or a.kind ~= 'click') then
    local h = self.held
    self.env.mouse(h[1], h[2], h[3], h[4], true)
  end
  if not a then return end
  local now = self.env.now()
  if a.kind == 'click' then
    if not a.focus and not a.unfocused then  -- a hold may have left the focus claimed
      if self.env.unfocus then self.env.unfocus() end
      a.unfocused = true
    end
    self.env.mouse(a.tx, a.ty, a.px, a.py, a.focus)
    if not a.t0 then a.t0 = now end
    if not a.pressed and now - a.t0 >= a.hover then
      local b = a.button
      self.env.sim({['_MOUSE_' .. b] = true, ['_MOUSE_' .. b .. '_DOWN'] = true})  -- gui.lua:46-52
      a.pressed, a.t1 = true, now
    elseif a.pressed and now - a.t1 >= a.after then
      table.remove(self.q, 1); self.done = self.done + 1
    end
  elseif a.kind == 'probe' then
    if self.env.claim then self.env.claim() end
    local x, y = -1, -1
    if self.env.peek then x, y = self.env.peek() end
    if x >= 0 and y >= 0 then
      local k = x .. ',' .. y
      a.seen[k] = (a.seen[k] or 0) + 1
    end
    a.n = a.n - 1
    if a.n <= 0 then
      local best, bn = nil, 0
      for k, n in pairs(a.seen) do if n > bn then best, bn = k, n end end
      if best then
        local px, py = best:match('^(%-?%d+),(%-?%d+)$')
        self.real = {tonumber(px), tonumber(py)}
      else
        self.real = false
      end
      table.remove(self.q, 1); self.done = self.done + 1
    end
  elseif a.kind == 'unfocus' then
    if not a.t1 then
      if self.env.unfocus then self.env.unfocus() end
      a.t1 = now
    elseif now - a.t1 >= a.after then table.remove(self.q, 1); self.done = self.done + 1 end
  elseif a.kind == 'key' then
    if not a.t1 then self.env.sim(a.name); a.t1 = now
    elseif now - a.t1 >= a.after then table.remove(self.q, 1); self.done = self.done + 1 end
  elseif a.kind == 'wait' then
    a.t1 = a.t1 or now
    if now - a.t1 >= a.after then table.remove(self.q, 1); self.done = self.done + 1 end
  end
end

return I
