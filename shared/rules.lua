-- What fits a weapon and what a change costs. Pure functions over the
-- generated catalog, shared by the server (which decides) and the client
-- (which shows). A weapon's fitted state is
--   { parts = { [slot] = 'COMPONENT_...' }, tint = 0, livery = 0 }
-- where a slot left empty means its stock part (or nothing).

GunsmithRules = {}
local R = GunsmithRules
local catalog = GunsmithCatalog

-- Slots in bench order: front to back, then the surface.
R.SLOTS = { 'muzzle', 'barrel', 'optic', 'light', 'grip', 'mag', 'finish', 'camo' }
R.SLOT_INDEX = {}
for index, slot in ipairs(R.SLOTS) do R.SLOT_INDEX[slot] = index end
-- Surface slots change the whole weapon; they never slide off an axis.
R.SURFACE = { finish = true, camo = true }

local indexed = {}

local function upper(name) return type(name) == 'string' and name:upper() or nil end

function R.weapon(name)
    name = upper(name)
    return name and catalog.weapons[name] or nil, name
end

-- Per weapon: parts by component, slots with their parts (stock first).
local function index(name)
    local cached = indexed[name]
    if cached then return cached end
    local weapon = catalog.weapons[name]
    if not weapon then return nil end
    cached = { byComponent = {}, byItem = {}, slots = {}, stock = {} }
    for _, part in ipairs(weapon.parts) do
        cached.byComponent[part.component] = part
        if part.item then cached.byItem[part.item] = part end
        local list = cached.slots[part.slot]
        if not list then list = {}; cached.slots[part.slot] = list end
        list[#list + 1] = part
        if part.stock then cached.stock[part.slot] = part end
    end
    for _, list in pairs(cached.slots) do
        table.sort(list, function(a, b)
            if a.stock ~= b.stock then return a.stock == true end
            -- Owners add parts to catalog.lua; a missing label sorts by its component.
            local la, lb = a.label or a.component, b.label or b.component
            if la ~= lb then return la < lb end
            return a.component < b.component
        end)
    end
    indexed[name] = cached
    return cached
end

function R.part(name, component)
    local weapon = index(upper(name) or '')
    return weapon and weapon.byComponent[upper(component) or ''] or nil
end

function R.partForItem(name, item)
    local weapon = index(upper(name) or '')
    return weapon and type(item) == 'string' and weapon.byItem[item] or nil
end

function R.stock(name, slot)
    local weapon = index(upper(name) or '')
    return weapon and weapon.stock[slot] or nil
end

-- Parts for one slot, stock first.
function R.options(name, slot)
    local weapon = index(upper(name) or '')
    return weapon and weapon.slots[slot] or {}
end

-- The slots this weapon offers a choice in. A slot with only its stock part
-- has nothing to change and is left out.
function R.slots(name)
    local weapon = index(upper(name) or '')
    local out = {}
    if not weapon then return out end
    for _, slot in ipairs(R.SLOTS) do
        for _, part in ipairs(weapon.slots[slot] or {}) do
            if not part.stock then out[#out + 1] = slot; break end
        end
    end
    return out
end

function R.tints(name)
    local weapon = catalog.weapons[upper(name) or '']
    return weapon and weapon.tints and catalog.tints[weapon.tints] or nil
end

function R.tintCount(name)
    local tints = R.tints(name)
    return tints and #tints or 0
end

-- Mk II camos take a colour from the same palette as Mk II tints.
function R.liveryCount(name)
    local tints = R.tints(name)
    return tints and #tints >= 32 and #tints or 0
end

-- State ---------------------------------------------------------------------------

function R.empty() return { parts = {}, tint = 0, livery = 0 } end

local function integer(value, lo, hi)
    return math.type(value) == 'integer' and value >= lo and value <= hi
        or (type(value) == 'number' and value == math.floor(value) and value >= lo and value <= hi)
end

-- A copy holding only parts this weapon takes, one per slot, and tint and
-- livery values in range. Stock parts are dropped: empty means stock.
function R.normalize(name, state)
    local out = R.empty()
    if type(state) ~= 'table' then return out end
    local parts = type(state.parts) == 'table' and state.parts or {}
    for _, slot in ipairs(R.SLOTS) do
        local part = R.part(name, parts[slot])
        if part and part.slot == slot and not part.stock then out.parts[slot] = part.component end
    end
    local tints = R.tintCount(name)
    if tints > 0 and integer(state.tint, 0, tints - 1) then out.tint = math.floor(state.tint) end
    local liveries = R.liveryCount(name)
    if out.parts.camo and liveries > 0 and integer(state.livery, 0, liveries - 1) then out.livery = math.floor(state.livery) end
    return out
end

function R.same(a, b)
    for _, slot in ipairs(R.SLOTS) do
        if a.parts[slot] ~= b.parts[slot] then return false end
    end
    return a.tint == b.tint and a.livery == b.livery
end

function R.copy(state)
    local out = R.empty()
    for slot, component in pairs(state.parts) do out.parts[slot] = component end
    out.tint, out.livery = state.tint, state.livery
    return out
end

-- Items <-> state. Inventories that keep attachments as item names
-- (ox_inventory's metadata.components) resolve them per weapon here.
function R.fromItems(name, items, tint, livery)
    local state = R.empty()
    if type(items) == 'table' then
        for key, value in pairs(items) do
            -- Arrays of item names, or maps keyed by item name.
            local item = type(key) == 'string' and key or value
            local part = R.partForItem(name, item)
            if part and not state.parts[part.slot] then state.parts[part.slot] = part.component end
        end
    end
    state.tint, state.livery = tint, livery
    return R.normalize(name, state)
end

function R.items(name, state)
    local out = {}
    for _, slot in ipairs(R.SLOTS) do
        local part = R.part(name, state.parts[slot])
        if part and part.item then out[#out + 1] = part.item end
    end
    return out
end

-- Every component the weapon should carry: fitted parts, stock parts in
-- empty slots and the slide that goes with a Mk II pistol camo.
function R.components(name, state)
    local out = {}
    for _, slot in ipairs(R.SLOTS) do
        local part = R.part(name, state.parts[slot]) or R.stock(name, slot)
        if part then
            out[#out + 1] = part.component
            if part.slide then out[#out + 1] = part.slide end
        end
    end
    return out
end

-- Every component name this weapon could carry (to strip what is not wanted).
function R.allComponents(name)
    local out, weapon = {}, catalog.weapons[upper(name) or '']
    for _, part in ipairs(weapon and weapon.parts or {}) do
        out[#out + 1] = part.component
        if part.slide then out[#out + 1] = part.slide end
    end
    return out
end

-- Changes -------------------------------------------------------------------------

-- Fit `component` in `slot` (nil or the stock part = back to stock). Returns
-- the next state and the item exchange: take = the new part's item, give = the
-- displaced part's item. nil plus an error code when the change is not valid.
function R.plan(name, state, slot, component)
    if not R.SLOT_INDEX[slot] then return nil, 'INVALID_SLOT' end
    local current = state.parts[slot]
    local part = component and R.part(name, component) or nil
    if component and not part then return nil, 'NOT_COMPATIBLE' end
    if part and part.slot ~= slot then return nil, 'NOT_COMPATIBLE' end
    local wanted = part and not part.stock and part.component or nil
    if wanted == current then return nil, 'UNCHANGED' end
    local next = R.copy(state)
    next.parts[slot] = wanted
    if slot == 'camo' and not wanted then next.livery = 0 end
    local old = current and R.part(name, current)
    return next, nil, { take = part and part.item or nil, give = old and old.item or nil }
end

function R.planTint(name, state, tint)
    local count = R.tintCount(name)
    if count == 0 or not integer(tint, 0, count - 1) then return nil, 'INVALID_TINT' end
    if state.tint == tint then return nil, 'UNCHANGED' end
    local next = R.copy(state)
    next.tint = math.floor(tint)
    return next
end

function R.planLivery(name, state, livery)
    local count = R.liveryCount(name)
    if not state.parts.camo or count == 0 or not integer(livery, 0, count - 1) then return nil, 'INVALID_LIVERY' end
    if state.livery == livery then return nil, 'UNCHANGED' end
    local next = R.copy(state)
    next.livery = math.floor(livery)
    return next
end

-- Quick swap: the next of `count` choices after `from` that `allowed(i)`
-- passes, going round; nil when no other choice is allowed.
function R.nextChoice(count, from, allowed)
    for k = 1, count - 1 do
        local i = (from - 1 + k) % count + 1
        if allowed(i) then return i end
    end
    return nil
end

return R
