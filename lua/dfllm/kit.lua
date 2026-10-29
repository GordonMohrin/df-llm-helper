-- dfllm.kit (FR-100/FR-101, Gordon's goal G18 "every soldier armor + weapon; sparring always with wooden weapons"):
-- library (not a kernel module) for military. Pure rules and DF reads of one soldier's kit; military owns the squads,
-- the persist record (m.military sq.<key>.tr/td/rf) and every write (K.act.squad_uniform, the squads screen's equip).
--   conf     military.training in config/baseline.json {on, fallback, refit_days} (dfpilot/fairplay.py MILITARY_TRAIN_LIM),
--            the plan's military.training (true/false) wins over `on`. on: every melee squad military makes or adopts goes
--            on the training policy of FR-89 (wooden training weapons in PEACE and DRILL, real ones in any other mode);
--            a player's `squad.uniform kind=melee` turns it off for that squad for good (tr = 0), kind=training on again.
--   soldier  one occupied position: armor = every armor category (body, head, pants, gloves, shoes) has a uniform spec and
--            each spec holds an item the soldier wears; weapon = he holds a weapon; wood = it is a training weapon.
--   refit    the material fallback of the uniform UI: a position whose armor slot of one category stays empty while its
--            spec asks for metal (or leather) and free pieces of that category in another material lie in the fort gets
--            that category re-specced to any material (best available: bone, leather, cloth-free kits fill); a position
--            wearing a non-metal piece in an any-material slot goes back to metal once free metal pieces cover them.
--            Only in PEACE without danger, at most once per refit_days per squad (military M.refit).
local KIT = {}

KIT.ARMOR = {'body', 'head', 'pants', 'gloves', 'shoes'}
KIT.TYPE = {body = 'ARMOR', head = 'HELM', pants = 'PANTS', gloves = 'GLOVES', shoes = 'SHOES'}
-- the classes without a vanilla training raw that have a close relative with one (FR-101); the rest take `fallback`
KIT.ALT = {PIKE = 'SPEAR', DAGGER = 'SWORD'}
KIT.FALLBACKS = {AXE = true, SWORD = true, SPEAR = true, none = true}
KIT.DEF = {on = true, fallback = 'SPEAR', refit_days = 7}
KIT.REFIT_LIM = {0, 56}
KIT.DAY = 1200

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end

-- {on, fallback, refit_days}: config/baseline.json military.training (`t`), the plan's military.training wins over `on`
function KIT.conf(t, plan_mil)
  t = type(t) == 'table' and t or {}
  local c = {on = KIT.DEF.on, fallback = KIT.DEF.fallback, refit_days = KIT.DEF.refit_days}
  if type(t.on) == 'boolean' then c.on = t.on end
  if type(t.fallback) == 'string' and KIT.FALLBACKS[t.fallback] then c.fallback = t.fallback end
  local d = int(t.refit_days)
  if d and d >= KIT.REFIT_LIM[1] and d <= KIT.REFIT_LIM[2] then c.refit_days = d end
  if type(plan_mil) == 'table' and type(plan_mil.training) == 'boolean' then c.on = plan_mil.training end
  return c
end

-- the class a training raw trains ('ITEM_WEAPON_SPEAR_TRAINING' -> 'SPEAR')
function KIT.cls_of(tok)
  return type(tok) == 'string' and tok:match('^ITEM_WEAPON_(%u+)') or nil
end

local function try(f, ...)
  local ok, r = pcall(f, ...)
  if ok then return r end
  return nil
end

-- is a weapon item a training weapon (its raw id ends in _TRAINING)?
function KIT.is_training(it)
  return try(function()
    local d = dfhack.items.getSubtypeDef(df.item_type.WEAPON, it:getSubtype())
    return d ~= nil and tostring(d.id):find('_TRAINING$') ~= nil
  end) == true
end

-- the worn items of a unit: {item id = item} in the roles `R` (military's Worn/Weapon/Strapped set)
local function worn(u, R)
  local on = {}
  try(function()
    for _, inv in ipairs(u.inventory) do
      if R[inv.mode] and inv.item then on[inv.item.id] = inv.item end
    end
  end)
  return on
end

-- is one uniform spec filled (spec.item or one of spec.assigned worn)?
local function filled(sp, on)
  if int(sp.item) and sp.item >= 0 and on[sp.item] then return on[sp.item] end
  for _, id in ipairs(sp.assigned or {}) do if on[id] then return on[id] end end
  return nil
end

-- one soldier: {armor = bool, weapon = bool, wood = bool, empty = {cat = true}, soft = {cat = true}}: empty = armor
-- categories with no spec or a spec nobody fills, soft = categories filled with a piece that is no metal
function KIT.soldier(p, u, R, is_metal)
  local on = worn(u, R)
  local r = {armor = true, weapon = false, wood = false, empty = {}, soft = {}}
  try(function()
    for _, c in ipairs(KIT.ARMOR) do
      local specs = p.equipment.uniform[c]
      if #specs == 0 then r.empty[c] = true end
      for _, sp in ipairs(specs) do
        local it = filled(sp, on)
        if not it then r.empty[c] = true
        elseif is_metal and not is_metal(it) then r.soft[c] = true end
      end
    end
    local W = df.item_type.WEAPON
    for _, it in pairs(on) do
      if it:getType() == W then
        r.weapon = true
        if KIT.is_training(it) then r.wood = true end
      end
    end
  end)
  if next(r.empty) then r.armor = false end
  return r
end

-- material class of a uniform spec: 'metal', 'leather' or 'any' (squad_uniform_spec.material_class, act.lua MAT_CLASS)
function KIT.spec_mat(sp)
  local mc = int(sp.material_class) or -1
  if mc < 0 then return 'any' end
  local E = df.entity_material_category
  if E and mc == E.Armor then return 'metal' end
  if E and mc == E.Leather then return 'leather' end
  return 'other'
end

-- the refit plan of one squad: {{cat, mat, positions}} from the members' kit and the free stock per category
-- (`stock(cat)` = {metal, leather, any}: military.stock_mats). mems = {{pos, p, kit}}
function KIT.refit_plan(mems, stock)
  local down, up = {}, {}
  for _, c in ipairs(KIT.ARMOR) do
    local per = (c == 'gloves' or c == 'shoes') and 2 or 1          -- worn in pairs
    local empty, soft = {metal = {}, leather = {}}, {}
    for _, m in ipairs(mems) do
      local specs = m.p.equipment.uniform[c]
      -- (#specs first: a DF vector raises on an index out of range, the empty categories of a fresh position)
      local sp = specs and #specs > 0 and (specs[0] or specs[1]) or nil
      local mat = sp and KIT.spec_mat(sp)
      if sp and m.kit.empty[c] and empty[mat] then table.insert(empty[mat], m.pos)
      elseif sp and m.kit.soft[c] and mat == 'any' then soft[#soft + 1] = m.pos end
    end
    local n
    for _, mat in ipairs({'metal', 'leather'}) do
      local list = empty[mat]
      if #list > 0 then
        n = n or stock(c)
        -- the free pieces of the spec's own material go to the first ones (DF hands them out); the rest take any other
        local own = (n[mat] or 0) // per
        local other = ((n.any or 0) - (n[mat] or 0)) // per
        for i = own + 1, #list do
          if other <= 0 then break end
          down[c] = down[c] or {}
          table.insert(down[c], list[i])
          other = other - 1
        end
      end
    end
    if #soft > 0 then
      n = n or stock(c)
      if (n.metal or 0) >= #soft * per then up[c] = soft end
    end
  end
  local out = {}
  for _, c in ipairs(KIT.ARMOR) do
    if down[c] then out[#out + 1] = {cat = c, mat = 'any', positions = down[c]} end
    if up[c] then out[#out + 1] = {cat = c, mat = 'metal', positions = up[c]} end
  end
  return out
end

return KIT
