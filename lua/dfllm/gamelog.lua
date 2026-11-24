-- gamelog: an incremental, bounded reader of DF's own <DF>/gamelog.txt (NEU5, BUG-847). A library like cancelwhy / dfraw: no game access, the file
-- opener is a parameter (tests hand it a fixture).
--
-- Why it exists: live (main 4081ef70, i4 Girderroots) the cancel tally stayed empty for ~25 game days while gamelog.txt held 110x "<name>, <profession>
-- cancels Brew drink from plant: Needs empty food storage item." in its last 400 lines. The eventful REPORT queue is a lossy source (it delivers
-- announcements that make a report, capped queue, folded repeats); the gamelog gets every line DF prints. The kernel reads it itself: it is DF's own
-- text log of what a player sees on the announcement screen, read only, and the kernel already reads plain files (io.lua, runner.lua).
--
-- Bounds: at most `chunks` (default 1; economy passes 8) reads of `max` bytes (default 128 KB) per look (NEU6 BUG-851: a flooded log needs more than one); the first look starts at the END of the file (old lines are not today's); a backlog of more
-- than `backlog` bytes (default 1 MB: a long pause between two looks) is skipped, counted in `skipped`, never read; the file is never read whole (it
-- is 300 MB live). Only complete lines count: a half-written last line waits for the next look. Rotation and truncation: a file smaller than the
-- offset, or whose first bytes differ from the remembered ones, restarts at 0. The "*** STARTING NEW GAME ***" marker drops every line before it in
-- the same look (they belong to an older game). Names are CP437 bytes (>= 128): the kind and the reason are cut to ASCII ('?' for any other byte),
-- the names are never kept.
local G = {}
G.MAX = 131072
G.BACKLOG = 1048576
G.MARK = '*** STARTING NEW GAME ***'
G.SIG = 64

-- <unit>, <profession> cancels <job>: <reason>.  ->  job, reason (ASCII, no final dot, no "(x3)" repeat suffix)
function G.parse(line)
  local j, why = tostring(line or ''):match('cancels ([^:]+):%s*(.-)%s*$')
  if not j then return nil end
  j = j:gsub('^[ ]+', ''):gsub('[ ]+$', ''):gsub('[\128-\255]', '?')
  why = why:gsub('%s*%(x%d+%)$', ''):gsub('%.$', ''):gsub('[\128-\255]', '?')
  if j == '' or #j > 60 then return nil end
  return j, why
end

-- a reader state; `off`/`sig` may come from a persisted copy (G.save / G.resume)
function G.new(path)
  return {path = path, off = nil, sig = nil, size = 0, state = 'new', err = nil, lines = 0, cancels = 0, bytes = 0, resets = 0, restarts = 0,
          skipped = 0, looks = 0, behind = 0}
end

-- the persisted part: the offset and the first bytes of the file as hex (a CP437 byte is no valid JSON text)
function G.save(s)
  if not s.off or not s.sig then return nil end
  return {off = s.off, sig = (s.sig:gsub('.', function(c) return string.format('%02x', c:byte()) end))}
end
function G.resume(s, saved)
  local off = type(saved) == 'table' and math.tointeger(saved.off) or nil
  if off and off >= 0 and type(saved.sig) == 'string' and #saved.sig % 2 == 0 and not saved.sig:find('[^0-9a-f]') then
    s.off = off
    s.sig = (saved.sig:gsub('%x%x', function(h) return string.char(tonumber(h, 16)) end))
  end
end

-- one look. o = {open = function(path) -> file, max, chunks, backlog, parse = function(line) -> kind, why, start = 'end' | 'begin'}
-- returns the list {{kind, why}, ...} of the cancels in the new complete lines; s.state is 'ok' | 'missing' | 'error', s.err the cause.
-- NEU6 (BUG-851): up to `chunks` (default 1) reads of `max` bytes per look while a backlog remains (a flooded log: ~110 of 400 lines are cancels), and a
-- cheap prefilter (only lines holding " cancels " reach the parser; a custom `parse` sees every line, as before). s.behind = the bytes still unread after the
-- look (the size seen at its start minus the offset), s.lastlook = {lines, cancels, bytes} of the last look.
G.CANCELS = ' cancels '
function G.poll(s, o)
  o = o or {}
  local max, backlog = math.tointeger(o.max) or G.MAX, math.tointeger(o.backlog) or G.BACKLOG
  local chunks = math.max(1, math.min(64, math.tointeger(o.chunks) or 1))
  local parse = o.parse or G.parse
  local prefilter = o.parse == nil
  s.looks = s.looks + 1
  s.lastlook = {lines = 0, cancels = 0, bytes = 0}
  local f, oerr = (o.open or function(p) return io.open(p, 'rb') end)(s.path)
  if not f then s.state, s.err = 'missing', tostring(oerr or 'cannot open'):sub(1, 120); return {} end
  local out = {}
  local ok, err = pcall(function()
    local size = f:seek('end') or 0
    f:seek('set', 0)
    local head = f:read(G.SIG) or ''
    s.size = size
    if s.sig then
      local n = math.min(#s.sig, #head)
      if #head < #s.sig or head:sub(1, n) ~= s.sig:sub(1, n) then    -- another file under the name (rotated, replaced): from its start
        s.off, s.resets = 0, s.resets + 1
      end
    end
    s.sig = head
    if s.off and size < s.off then s.off, s.resets = 0, s.resets + 1 end
    if not s.off then
      s.off = (o.start == 'begin') and 0 or size
      s.state, s.err = 'ok', nil
      if s.off == size then s.behind = 0; return end
    end
    s.state, s.err = 'ok', nil
    local gap = size - s.off
    if gap > backlog then s.skipped, s.off = s.skipped + gap, size; s.behind = 0; return end
    for _ = 1, chunks do
      gap = size - s.off
      if gap <= 0 then break end
      local n = math.min(gap, max)
      f:seek('set', s.off)
      local chunk = f:read(n) or ''
      local last = 0
      for i = #chunk, 1, -1 do
        if chunk:byte(i) == 10 then last = i; break end
      end
      if last == 0 then
        if #chunk >= max then s.off, s.skipped = s.off + #chunk, s.skipped + #chunk else break end   -- a 'line' longer than a look: garbage; else a half line waits
      else
        chunk = chunk:sub(1, last)
        s.off, s.bytes = s.off + last, s.bytes + last
        s.lastlook.bytes = s.lastlook.bytes + last
        for line in chunk:gmatch('([^\n]*)\n') do
          s.lines = s.lines + 1
          s.lastlook.lines = s.lastlook.lines + 1
          if line:find(G.MARK, 1, true) then
            out, s.restarts = {}, s.restarts + 1
          elseif not prefilter or line:find(G.CANCELS, 1, true) then
            local kind, why = parse(line)
            if kind then out[#out + 1] = {kind, why} end
          end
        end
      end
    end
    s.behind = math.max(0, size - s.off)
  end)
  pcall(function() f:close() end)
  if not ok then s.state, s.err = 'error', tostring(err):sub(1, 120); return {} end
  s.cancels = s.cancels + #out
  s.lastlook.cancels = #out
  return out
end

return G
