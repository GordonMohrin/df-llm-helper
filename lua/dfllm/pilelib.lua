-- pilelib: the barrel limit of a stockpile, read and written through the field names a DFHack version really has (NEU5, BUG-848). A library: no game
-- access of its own besides the stockpile struct it is handed.
--
-- Live (main 4081ef70, DFHack 53.16/53.17, i4 Girderroots): `sp.max_barrels` was unreadable ("max_barrels=?" in every item sample), act.pile_barrels
-- failed without a word. DFHack's own code (scripts/internal/quickfort/place.lua, `storage.max_barrels` assigned with utils.assign(bld, props), and
-- init_containers) keeps the limits in the building's `storage` struct: `bld.storage.max_barrels` (max_bins, max_wheelbarrows beside it); -1 = no limit.
-- The old flat name stays as the second candidate (older structures, the offline fake world).
local P = {}
P.CANDIDATES = {{'storage', 'max_barrels'}, {'max_barrels'}}

function P.name(path) return table.concat(path, '.') end

local function read(sp, path)
  local ok, v = pcall(function()
    local x = sp
    for _, k in ipairs(path) do x = x[k] end
    return x
  end)
  if ok and math.type(v) == 'integer' then return v end
  if ok and type(v) == 'number' and math.tointeger(v) then return math.tointeger(v) end
  return nil
end

-- the limit and the name of the candidate that answered; nil, nil when none does
function P.get(sp)
  for _, path in ipairs(P.CANDIDATES) do
    local v = read(sp, path)
    if v then return v, P.name(path) end
  end
  return nil, nil
end

-- sets the limit through the first candidate that reads; true, name only when the value reads back. false, why otherwise
function P.set(sp, value)
  value = math.tointeger(value)
  if not value then return false, 'not an integer' end
  for _, path in ipairs(P.CANDIDATES) do
    if read(sp, path) then
      local ok = pcall(function()
        local x = sp
        for i = 1, #path - 1 do x = x[path[i]] end
        x[path[#path]] = value
      end)
      if ok and read(sp, path) == value then return true, P.name(path) end
      return false, P.name(path) .. ' did not take the value'
    end
  end
  return false, 'no barrel limit field (tried ' .. P.tried() .. ')'
end

function P.tried()
  local t = {}
  for _, path in ipairs(P.CANDIDATES) do t[#t + 1] = P.name(path) end
  return table.concat(t, ', ')
end

-- over a list of stockpile structs: {n = piles, ok = piles that answered, cand = the name that answered (first), tried}
function P.probe(piles)
  local r = {n = 0, ok = 0, tried = P.tried()}
  for _, sp in ipairs(piles) do
    r.n = r.n + 1
    local v, c = P.get(sp)
    if v then r.ok, r.cand = r.ok + 1, r.cand or c end
  end
  return r
end

return P
