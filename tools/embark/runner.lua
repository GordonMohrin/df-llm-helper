-- tools/embark/runner.lua: plays a list of steps against the live screen, one phase per poll.
-- step = {id, live, wait(v,ctx)->bool, act(ui,v,ctx,w,mem)->nil|'done'|'skip'|'fail'|'wait',msg,
--         done(v,ctx,mem)->true|false|'fail',msg, progress(v,ctx)->value, optional,
--         timeout_ms, tries, stale, settle_ms}
-- Phases: wait (precondition) -> act (queue input) -> settle (input played + settle_ms)
-- -> check (postcondition; not done = act again until tries/stale/timeout run out).
-- act 'wait' = nothing queued, check again at the next poll WITHOUT spending a try (slow screen
-- changes: preparing the map, loading the fort); only the step timeout ends it.
-- mem = a fresh table per step (e.g. "this button was clicked").
-- env = {capture()->view, now()->ms, ui=<input queue>, w=<UI-state writers>, status(doc)}
local R = {}
local Run = {}
Run.__index = Run

function R.new(id, steps, env, ctx, cfg)
  cfg = cfg or {}
  return setmetatable({id = id, steps = steps, env = env, ctx = ctx or {}, i = 1, phase = 'wait', mem = {},
    tries = 0, stale = 0, state = 'running', msg = '', poll_ms = cfg.poll_ms or 250,
    settle_ms = cfg.settle_ms or 800, timeout_ms = cfg.timeout_ms or 20000, t0 = env.now(), log = {}}, Run)
end

function Run:note(s)
  local st = self.steps[self.i]
  self.log[#self.log + 1] = string.format('%d %s: %s', (self.env.now() - self.t0) // 1000, st and st.id or '-', s)
  if #self.log > 40 then table.remove(self.log, 1) end
end

function Run:doc()
  local s = self.steps[self.i]
  return {v = 2, id = self.id, state = self.state, step = s and s.id or '', live = s and s.live or '',
    i = self.i, n = #self.steps, phase = self.phase, tries = self.tries, msg = self.msg,
    elapsed_ms = self.env.now() - self.t0, log = self.log, results = self.ctx.results or {},
    warnings = self.ctx.warnings or {}}
end

function Run:push() if self.env.status then self.env.status(self:doc()) end end

function Run:set_phase(p) self.phase, self.t_phase, self.t_poll = p, self.env.now(), nil end

function Run:next(msg)
  if msg and msg ~= '' then self:note(msg) end
  self.i, self.tries, self.stale, self.last_p, self.t_step = self.i + 1, 0, 0, nil, nil
  self.mem, self.last_r = {}, nil
  self:set_phase('wait')
  if self.i > #self.steps then return self:finish('done', 'all steps done') end
  self:push()
  return true
end

function Run:finish(state, msg)
  self.state, self.msg = state, msg or ''
  self:note(state .. ' ' .. self.msg)
  self:push()
  return not self.env.ui:idle()  -- keep framing until queued input (e.g. 'Go back') is played
end

function Run:fail(msg)
  local s = self.steps[self.i]
  msg = (msg or '?') .. (self.last_msg and (' (' .. self.last_msg .. ')') or '')
  if s and s.optional then
    self.ctx.warnings = self.ctx.warnings or {}
    self.ctx.warnings[#self.ctx.warnings + 1] = s.id .. ': ' .. msg
    return self:next('optional step failed: ' .. msg)
  end
  if self.env.dump then self.env.dump('fail-' .. (s and s.id or 'x')) end
  return self:finish('failed', (s and s.id or '?') .. ': ' .. msg)
end

function Run:stop(msg)
  self.env.ui:clear()
  return self:finish('stopped', msg or 'stopped')
end

-- one frame; returns true while the run needs more frames
function Run:frame()
  self.env.ui:frame()
  if self.state ~= 'running' then return not self.env.ui:idle() end
  local now = self.env.now()
  local s = self.steps[self.i]
  if not s then return self:finish('done', 'no steps') end
  self.t_step = self.t_step or now
  self.t_phase = self.t_phase or now
  if now - self.t_step > (s.timeout_ms or self.timeout_ms) then
    return self:fail('timeout ' .. (self.last_r == 'wait' and 'while waiting' or ('in ' .. self.phase)))
  end
  if self.phase == 'settle' then
    if self.env.ui:idle() and now - self.t_phase >= (s.settle_ms or self.settle_ms) then self:set_phase('check') end
    return true
  end
  if self.t_poll and now - self.t_poll < self.poll_ms then return true end
  self.t_poll = now
  local v = self.env.capture()
  if self.phase == 'wait' then
    if s.wait and not s.wait(v, self.ctx) then return true end
    self:set_phase('act')
    self.t_poll = now
  end
  if self.phase == 'act' then
    local r, msg = nil, nil
    if s.act then r, msg = s.act(self.env.ui, v, self.ctx, self.env.w, self.mem) end
    self.last_msg, self.last_r = msg, r
    if r == 'skip' then return self:next('skipped' .. (msg and (': ' .. msg) or '')) end
    if r == 'fail' then return self:fail(msg) end
    if r == 'done' then return self:next(msg) end
    if r ~= 'wait' then
      self.tries = self.tries + 1
      self:set_phase('settle')
      self:push()
      return true
    end
    self.phase = 'check'  -- 'wait': nothing queued, check this same view, no try spent
  end
  -- check
  local d, msg = true, nil
  if s.done then d, msg = s.done(v, self.ctx, self.mem) end
  if d == true then return self:next(msg) end
  if d == 'fail' then return self:fail(msg) end
  self.msg = msg or ''
  if self.last_r == 'wait' then  -- still waiting: act again at the next poll; no try, no stale count
    self:set_phase('act')
    self.t_poll = now
    return true
  end
  if s.progress then
    local p = tostring(s.progress(v, self.ctx))
    if p == self.last_p then self.stale = self.stale + 1 else self.stale = 0 end
    self.last_p = p
    if self.stale >= (s.stale or 3) then return self:fail('no progress: ' .. (msg or '')) end
  end
  if self.tries >= (s.tries or 3) then return self:fail('not done after ' .. self.tries .. ' tries: ' .. (msg or '')) end
  self:set_phase('act')
  return true
end

return R
