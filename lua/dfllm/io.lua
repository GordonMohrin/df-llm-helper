-- dfllm file I/O (CONTRACTS §8). Binary mode everywhere (no CRLF), integers only via util/json.
-- Write rules: Lua never renames onto an existing file (Windows os.rename fails with "File exists"):
-- state/heartbeat are rewritten in place, new files go to <name>.tmp and are renamed to a free name.
local json = require('dfllm.util.json')

local F = {}

F.EVENTS_MAX = 5 * 1024 * 1024   -- events.jsonl rotation
F.LOG_MAX = 1024 * 1024          -- kern.log / commands.log rotation

local function fs() return dfhack.filesystem end

function F.basename(p)
  p = tostring(p or ''):gsub('[/\\]+$', '')
  return p:match('([^/\\]+)$') or p
end

-- <DF>/dfllm-runtime[/<save>] paths; save may be nil (heal-only boot of an unmarked save)
function F.paths(df_path, save)
  local root = (df_path or '.'):gsub('[/\\]+$', '') .. '/dfllm-runtime'
  local p = {df = df_path, runtime = root, save_name = save}
  if save then
    local s = root .. '/' .. save
    p.save, p.inbox, p.outbox, p.snap, p.bp = s, s .. '/inbox', s .. '/outbox', s .. '/snap', s .. '/bp'
  end
  return p
end

function F.ensure(p)
  local ok = fs().mkdir_recursive(p.runtime)
  if p.save then
    for _, d in ipairs({p.save, p.inbox, p.outbox, p.snap, p.bp}) do ok = fs().mkdir_recursive(d) and ok end
  end
  return ok
end

function F.exists(path) return fs().exists(path) == true end
function F.listdir(path) return fs().listdir(path) or {} end
function F.remove(path) return os.remove(path) ~= nil end

function F.read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

-- decoded value, or nil + reason ('missing' or the decode error)
function F.read_json(path)
  local s = F.read(path)
  if not s then return nil, 'missing' end
  return json.try_decode(s)
end

-- write in place (truncate); used for state slots, heartbeat, ACTIVE, restore.json
function F.write(path, s)
  local f, err = io.open(path, 'wb')
  if not f then return false, err end
  local ok, werr = f:write(s)
  f:close()
  if not ok then return false, werr end
  return true
end

-- events.jsonl -> events.1.jsonl, kern.log -> kern.1.log
function F.rotated(path)
  local stem, ext = path:match('^(.*)(%.[^./\\]+)$')
  if not stem then return path .. '.1' end
  return stem .. '.1' .. ext
end

-- append s; rotate first when the file would exceed max bytes. Returns ok, err, rot_err:
-- ok=false only when nothing was written (the caller keeps its buffer and retries). A failed
-- rotation (Windows: another process holds the file without FILE_SHARE_DELETE) is not fatal: s is
-- appended to the current file anyway (over max) and rot_err says why; the next call retries.
function F.append(path, s, max)
  local f, err = io.open(path, 'ab')
  if not f then return false, err end
  local size = f:seek('end') or 0
  local rot_err
  if max and size > 0 and size + #s > max then
    f:close()
    local old = F.rotated(path)
    os.remove(old)
    local ok, rerr = os.rename(path, old)
    if not ok then rot_err = tostring(rerr or 'rename failed') end
    f, err = io.open(path, 'ab')
    if not f then return false, err, rot_err end
  end
  local ok, werr = f:write(s)
  f:close()
  if not ok then return false, werr, rot_err end
  return true, nil, rot_err
end

-- write dir/name via a .tmp file and rename onto a name that does not exist yet
-- (<stem>-<n><ext> when taken); returns the final path or nil, err
function F.write_new(dir, name, s)
  local tmp = dir .. '/' .. name .. '.tmp'
  local ok, err = F.write(tmp, s)
  if not ok then return nil, err end
  local stem, ext = name:match('^(.*)(%.[^.]+)$')
  stem, ext = stem or name, ext or ''
  local target = dir .. '/' .. name
  local n = 0
  while F.exists(target) do
    n = n + 1
    if n > 99 then os.remove(tmp); return nil, 'no free name for ' .. name end
    target = string.format('%s/%s-%d%s', dir, stem, n, ext)
  end
  local rok, rerr = os.rename(tmp, target)
  if not rok then os.remove(tmp); return nil, rerr end
  return target
end

-- last complete ('\n'-terminated) line of a file, reading at most the last 64 KB
function F.last_line(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local size = f:seek('end') or 0
  local n = math.min(size, 65536)
  f:seek('set', size - n)
  local s = f:read(n) or ''
  f:close()
  local last
  for line in s:gmatch('([^\n]*)\n') do
    if #line > 0 then last = line end
  end
  return last
end

return F
