-- dfllm.util.cadence (BUG-008): when a standing class-A condition may be announced again.
-- Run 9 live test: GHOSTS repeated "weekly" while the set stood, and a game week is 21 s at 400 ticks/s, so `follow`
-- woke for the same text again and again (merge counts x9 .. x31 within 20 real minutes). The rule for every
-- standing class-A condition (GHOSTS, MOOD_RISK, HOSPITAL_DRY, build_blocked, NO_DEPOT without a caravan):
--   * the first announcement of an episode goes out at once;
--   * a repeat needs news: the set grew (an id that was not in the last announcement) or a cause changed (a cause
--     token that was not in the last announcement); an unchanged or shrinking condition is never repeated;
--   * and a repeat waits max(`ticks` game ticks, `wall_s` wall-clock seconds) after the last announcement
--     (default max(7 game days, 10 min)): at timestream speed the wall clock is the longer one.
-- Records are plain values (persistable): {t = tick, w = wall s, ids = {...}, toks = {...}}. K.now().wall is
-- os.time() (seconds; it survives a DF restart, unlike K.now().ms).
local CC = require('dfllm.util.contract')

local M = {}
M.TICKS = 7 * CC.TICKS.DAY
M.WALL_S = 600

local function set_of(list)
  local s = {}
  for _, v in ipairs(type(list) == 'table' and list or {}) do s[v] = true end
  return s
end

local function news(rec, ids, toks)
  local seen, grew = set_of(rec.ids), false
  for _, v in ipairs(ids or {}) do if not seen[v] then grew = true; break end end
  local known, cause = set_of(rec.toks), false
  for _, v in ipairs(toks or {}) do if not known[v] then cause = true; break end end
  return grew, cause
end

-- elapsed(rec, now, ticks, wall_s): both clocks passed since the last announcement (a wall clock that went
-- backwards counts as passed)
function M.elapsed(rec, now, ticks, wall_s)
  if type(rec) ~= 'table' or rec.t == nil then return true end
  local t, w = math.tointeger(rec.t) or 0, math.tointeger(rec.w)
  if (now.tick or 0) - t < (ticks or M.TICKS) then return false end
  if w and now.wall and now.wall >= w and now.wall - w < (wall_s or M.WALL_S) then return false end
  return true
end

-- due(rec, now, ids, toks, o) -> due, why ('first' | 'grew' | 'cause' | nil)
-- rec: the last announcement or nil; ids, toks: the current set and cause tokens (arrays of strings or numbers);
-- o = {ticks = game ticks, wall_s = seconds} (defaults max(7 days, 10 min))
function M.due(rec, now, ids, toks, o)
  o = o or {}
  if type(rec) ~= 'table' or rec.t == nil then return true, 'first' end
  local grew, cause = news(rec, ids, toks)
  if not (grew or cause) then return false end
  if not M.elapsed(rec, now, o.ticks, o.wall_s) then return false end
  return true, grew and 'grew' or 'cause'
end

-- mark(now, ids, toks) -> the record of an announcement made now (copies of the lists)
function M.mark(now, ids, toks)
  local a, b = {}, {}
  for i, v in ipairs(ids or {}) do a[i] = v end
  for i, v in ipairs(toks or {}) do b[i] = v end
  return {t = now.tick, w = now.wall, ids = a, toks = b}
end

-- quiet(rec) -> the record kept while the condition is gone: the times stay (a new episode within the cadence
-- waits for it), the lists empty (everything that comes back is news)
function M.quiet(rec)
  if type(rec) ~= 'table' or rec.t == nil then return nil end
  return {t = rec.t, w = rec.w, ids = {}, toks = {}}
end

return M
