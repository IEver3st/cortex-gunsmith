-- Inventory adapters. Each one answers three questions for the weapon a
-- player holds (what is fitted, which parts they carry, and can this change
-- be committed) and nothing else. The bench never trusts the client for any
-- of them.
--
-- weapon(src, claim) -> { name, slot, metadata, ... } or nil, code
-- state(src, weapon) -> fitted state (GunsmithRules shape)
-- owned(src, weapon, items) -> { [item] = count }
-- commit(src, weapon, change) -> true, or false/nil plus a code
--   change = { kind = 'part' | 'tint' | 'livery', slot, next, take, give }
--
-- Codes: NO_WEAPON STALE NO_ITEM NO_ROOM NOT_COMPATIBLE HOLSTER UNSUPPORTED
-- NOT_READY UNKNOWN. nil means the inventory did not answer: nothing is
-- assumed, and the bench says so instead of guessing.

GunsmithBridge = {}
local B = GunsmithBridge
local Rules = GunsmithRules
local RESOURCE = GetCurrentResourceName()

local function started(name) return GetResourceState(name) == 'started' end
local function log(...) print(('[%s]'):format(RESOURCE), ...) end
local function debug(...) if Config.debug then log(...) end end
local function call(fn, ...)
    local result = table.pack(pcall(fn, ...))
    if not result[1] then debug('adapter call failed:', result[2]); return nil end
    return table.unpack(result, 2, result.n)
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

-- Config.items maps the at_* names to the server's own item names.
function B.itemName(item) return item and (Config.items[item] or item) or nil end
local reverse
function B.logicalItem(name)
    if not reverse then
        reverse = {}
        for logical, actual in pairs(Config.items) do reverse[actual] = logical end
    end
    return reverse[name] or name
end

local function partItems(name)
    local out, seen = {}, {}
    for _, slot in ipairs(Rules.SLOTS) do
        for _, part in ipairs(Rules.options(name, slot)) do
            if part.item and not seen[part.item] then seen[part.item] = true; out[#out + 1] = part.item end
        end
    end
    if Config.tint.item then out[#out + 1] = Config.tint.item end
    return out
end
B.partItems = partItems


-- ox_inventory ----------------------------------------------------------------------
-- metadata.components holds item names; ox fits them on equip. Tint is
-- metadata.tint. The camo colour is ours (gunsmithLivery) and the bench
-- re-applies it when the weapon is drawn.

local ox = {
    name = 'ox', holster = false, tint = true, livery = true, appliesParts = true, appliesTint = true, ownsUse = true,
    ready = function()
        return started('ox_inventory')
    end,
}

function ox.weapon(src)
    local weapon = call(function() return exports.ox_inventory:GetCurrentWeapon(src) end)
    if type(weapon) ~= 'table' or type(weapon.name) ~= 'string' then return false, 'NO_WEAPON' end
    if not Rules.weapon(weapon.name) then return false, 'NO_WEAPON' end
    return { name = weapon.name:upper(), slot = weapon.slot, metadata = copy(weapon.metadata or {}) }
end

function ox.state(_, weapon)
    local metadata = weapon.metadata
    local items = {}
    for _, name in ipairs(type(metadata.components) == 'table' and metadata.components or {}) do
        items[#items + 1] = B.logicalItem(name)
    end
    return Rules.fromItems(weapon.name, items, metadata.tint or 0, metadata.gunsmithLivery or 0)
end

function ox.owned(src, _, items)
    local out = {}
    for _, item in ipairs(items) do
        out[item] = call(function() return exports.ox_inventory:GetItemCount(src, B.itemName(item)) end) or 0
    end
    return out
end

-- Metadata components the bench does not know (custom items) are kept.
local function mergeItems(name, existing, fitted)
    local out = {}
    for _, item in ipairs(type(existing) == 'table' and existing or {}) do
        if not Rules.partForItem(name, B.logicalItem(item)) then out[#out + 1] = item end
    end
    for _, item in ipairs(fitted) do out[#out + 1] = B.itemName(item) end
    return out
end
B.mergeItems = mergeItems

function ox.commit(src, weapon, change)
    local take, give = B.itemName(change.take), B.itemName(change.give)
    if take and (call(function() return exports.ox_inventory:GetItemCount(src, take) end) or 0) < 1 then return false, 'NO_ITEM' end
    if give and call(function() return exports.ox_inventory:CanCarryItem(src, give, 1) end) ~= true then return false, 'NO_ROOM' end
    local current = ox.weapon(src)
    if not current or current.slot ~= weapon.slot or current.name ~= weapon.name
        or current.metadata.serial ~= weapon.metadata.serial then return false, 'STALE' end
    if take and call(function() return exports.ox_inventory:RemoveItem(src, take, 1) end) ~= true then return false, 'NO_ITEM' end
    local before = copy(current.metadata)
    local metadata = current.metadata
    metadata.components = mergeItems(weapon.name, metadata.components, Rules.items(weapon.name, change.next))
    metadata.tint = change.next.tint
    metadata.gunsmithLivery = change.next.livery ~= 0 and change.next.livery or nil
    local set = call(function() exports.ox_inventory:SetMetadata(src, current.slot, metadata); return true end)
    if not set then
        if take then call(function() return exports.ox_inventory:AddItem(src, take, 1) end) end
        return nil, 'UNKNOWN'
    end
    if give and call(function() return exports.ox_inventory:AddItem(src, give, 1) end) ~= true then
        -- Pockets filled up since the room check: put the weapon and the part back as they were.
        local undone = call(function() exports.ox_inventory:SetMetadata(src, current.slot, before); return true end)
        if undone then
            if take then call(function() return exports.ox_inventory:AddItem(src, take, 1) end) end
            return false, 'NO_ROOM'
        end
        log(('could not return %s to player %d after a change; check their inventory'):format(give, src))
        return nil, 'UNKNOWN'
    end
    return true
end

-- QBCore (qb-inventory and compatible) -----------------------------------------------
-- info.attachments = { { component, label, item } }, the shape qb-weapons fits
-- on equip; info.tint for the tint.

local qbCore
local function qbObject()
    if not qbCore and started('qb-core') then qbCore = call(function() return exports['qb-core']:GetCoreObject() end) end
    return qbCore
end

local qb = {
    name = 'qb', holster = false, tint = true, livery = true, appliesParts = true,
    ready = function() return qbObject() ~= nil end,
}

local function qbPlayer(src)
    local core = qbObject()
    return core and call(function() return core.Functions.GetPlayer(src) end)
end

function qb.weapon(src, claim)
    local player = qbPlayer(src)
    if not player then return nil, 'NOT_READY' end
    local items = player.PlayerData.items or {}
    local item = type(claim) == 'table' and math.type(claim.slot) == 'integer' and items[claim.slot] or nil
    if not item or type(item.name) ~= 'string' or item.name:upper() ~= tostring(claim.name):upper() then
        return false, 'NO_WEAPON'
    end
    if not Rules.weapon(item.name) then return false, 'NO_WEAPON' end
    return { name = item.name:upper(), slot = claim.slot, metadata = copy(item.info or {}) }
end

function qb.state(_, weapon)
    local state = Rules.empty()
    for _, entry in ipairs(type(weapon.metadata.attachments) == 'table' and weapon.metadata.attachments or {}) do
        local part = type(entry) == 'table' and Rules.part(weapon.name, entry.component)
        if part and not state.parts[part.slot] then state.parts[part.slot] = part.component end
    end
    state.tint, state.livery = weapon.metadata.tint or 0, weapon.metadata.gunsmithLivery or 0
    return Rules.normalize(weapon.name, state)
end

local function qbCount(player, item)
    local found = call(function() return player.Functions.GetItemsByName(item) end)
    if type(found) == 'table' then
        local total = 0
        for _, entry in pairs(found) do total = total + (entry.amount or entry.count or 0) end
        return total
    end
    local one = call(function() return player.Functions.GetItemByName(item) end)
    return type(one) == 'table' and (one.amount or one.count or 0) or 0
end

function qb.owned(src, _, items)
    local player, out = qbPlayer(src), {}
    for _, item in ipairs(items) do out[item] = player and qbCount(player, B.itemName(item)) or 0 end
    return out
end

function qb.commit(src, weapon, change)
    local player = qbPlayer(src)
    if not player then return false, 'NOT_READY' end
    local take, give = B.itemName(change.take), B.itemName(change.give)
    if take and qbCount(player, take) < 1 then return false, 'NO_ITEM' end
    if give and started('qb-inventory') then
        local room = call(function() return exports['qb-inventory']:CanAddItem(src, give, 1) end)
        if room == false then return false, 'NO_ROOM' end
    end
    local item = player.PlayerData.items[weapon.slot]
    if not item or tostring(item.name):upper() ~= weapon.name
        or type(item.info) == 'table' and item.info.serial ~= weapon.metadata.serial then return false, 'STALE' end
    if take and call(function() return player.Functions.RemoveItem(take, 1, false, RESOURCE) end) ~= true then return false, 'NO_ITEM' end
    item = player.PlayerData.items[weapon.slot]
    local before = copy(item.info or {})
    local info = copy(item.info or {})
    local attachments = {}
    for _, entry in ipairs(type(info.attachments) == 'table' and info.attachments or {}) do
        if type(entry) == 'table' and not Rules.part(weapon.name, entry.component) then attachments[#attachments + 1] = entry end
    end
    for _, slot in ipairs(Rules.SLOTS) do
        local part = Rules.part(weapon.name, change.next.parts[slot])
        if part then attachments[#attachments + 1] = { component = part.component, label = part.label or part.component, item = B.itemName(part.item) } end
    end
    info.attachments, info.tint = attachments, change.next.tint
    info.gunsmithLivery = change.next.livery ~= 0 and change.next.livery or nil
    local items = player.PlayerData.items
    items[weapon.slot].info = info
    local set = call(function() player.Functions.SetInventory(items, true); return true end)
    if not set then
        if take then call(function() return player.Functions.AddItem(take, 1, false, nil, RESOURCE) end) end
        return nil, 'UNKNOWN'
    end
    if give and call(function() return player.Functions.AddItem(give, 1, false, nil, RESOURCE) end) ~= true then
        -- Pockets filled up since the room check: put the weapon and the part back as they were.
        local undone = call(function()
            local now = player.PlayerData.items
            now[weapon.slot].info = before
            player.Functions.SetInventory(now, true)
            return true
        end)
        if undone then
            if take then call(function() return player.Functions.AddItem(take, 1, false, nil, RESOURCE) end) end
            return false, 'NO_ROOM'
        end
        log(('could not return %s to player %d after a change; check their inventory'):format(give, src))
        return nil, 'UNKNOWN'
    end
    return true
end

-- ESX -------------------------------------------------------------------------------
-- Weapons live in the loadout, with ESX's own component names; parts are
-- inventory items. A part ESX has no name for cannot be fitted there. The
-- loadout has no field for a camo colour, so ESX offers none.

local esxObject
local function esx()
    if not esxObject and started('es_extended') then esxObject = call(function() return exports.es_extended:getSharedObject() end) end
    return esxObject
end

local esxAdapter = {
    name = 'esx', holster = false, tint = true, livery = false, appliesParts = true, appliesTint = true,
    ready = function() return esx() ~= nil end,
}

-- ESX component name <-> GTA component hash for one weapon.
local function esxComponents(name)
    local config = call(function() return esx().GetWeapon(name) end)
    local byHash, byName = {}, {}
    for _, entry in ipairs(type(config) == 'table' and config.components or {}) do
        if type(entry.hash) == 'number' or type(entry.hash) == 'string' then
            local hash = type(entry.hash) == 'string' and GetHashKey(entry.hash) or entry.hash
            byHash[hash], byName[entry.name] = entry.name, hash
        end
    end
    return byHash, byName
end

function esxAdapter.weapon(src, claim)
    local player = call(function() return esx().GetPlayerFromId(src) end)
    if not player then return nil, 'NOT_READY' end
    local name = type(claim) == 'table' and type(claim.name) == 'string' and claim.name:upper() or nil
    if not name or not Rules.weapon(name) then return false, 'NO_WEAPON' end
    local _, weapon = call(function() return player.getWeapon(name) end)
    if type(weapon) ~= 'table' then return false, 'NO_WEAPON' end
    return { name = name, metadata = { components = copy(weapon.components or {}), tint = weapon.tintIndex or 0 } }
end

function esxAdapter.state(_, weapon)
    local byHash = esxComponents(weapon.name)
    local state = Rules.empty()
    for _, part in ipairs(GunsmithCatalog.weapons[weapon.name].parts) do
        local esxName = byHash[GetHashKey(part.component)]
        if esxName and not part.stock then
            for _, fitted in ipairs(weapon.metadata.components) do
                if fitted == esxName and not state.parts[part.slot] then state.parts[part.slot] = part.component end
            end
        end
    end
    state.tint = weapon.metadata.tint
    return Rules.normalize(weapon.name, state)
end

function esxAdapter.owned(src, _, items)
    local player, out = call(function() return esx().GetPlayerFromId(src) end), {}
    for _, item in ipairs(items) do
        local entry = player and call(function() return player.getInventoryItem(B.itemName(item)) end)
        out[item] = type(entry) == 'table' and (entry.count or 0) or 0
    end
    return out
end

function esxAdapter.commit(src, weapon, change)
    local player = call(function() return esx().GetPlayerFromId(src) end)
    if not player then return false, 'NOT_READY' end
    local _, byName = esxComponents(weapon.name)
    local byHash = {}
    for esxName, hash in pairs(byName) do byHash[hash] = esxName end
    local function esxName(component) return component and byHash[GetHashKey(component)] or nil end
    if change.kind ~= 'part' and change.kind ~= 'tint' then return false, 'UNSUPPORTED' end
    local old = change.kind == 'part' and esxAdapter.state(src, weapon).parts[change.slot] or nil
    local new = change.kind == 'part' and change.next.parts[change.slot] or nil
    if new and not esxName(new) then return false, 'UNSUPPORTED' end
    local take, give = B.itemName(change.take), B.itemName(change.give)
    if take then
        local entry = call(function() return player.getInventoryItem(take) end)
        if type(entry) ~= 'table' or (entry.count or 0) < 1 then return false, 'NO_ITEM' end
    end
    if give and call(function() return player.canCarryItem(give, 1) end) == false then return false, 'NO_ROOM' end
    if call(function() return player.hasWeapon(weapon.name) end) ~= true then return false, 'STALE' end
    if take then call(function() player.removeInventoryItem(take, 1) end) end
    if change.kind == 'part' then
        if old and esxName(old) then call(function() player.removeWeaponComponent(weapon.name, esxName(old)) end) end
        if new then call(function() player.addWeaponComponent(weapon.name, esxName(new)) end) end
    elseif change.kind == 'tint' then
        call(function() player.setWeaponTint(weapon.name, change.next.tint) end)
    end
    if give then call(function() player.addInventoryItem(give, 1) end) end
    return true
end

-- Standalone -------------------------------------------------------------------------
-- No inventory: every part is free, and the server remembers each player's
-- setup per weapon (KVP, by license) so it comes back after a reconnect.

local function license(src)
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        if id:sub(1, 8) == 'license:' then return id:sub(9) end
    end
end

local standalone = { name = 'standalone', holster = false, tint = true, livery = true, free = true, ready = function() return true end }

local function standaloneKey(src, name)
    local id = license(src)
    return id and ('setup:%s:%s'):format(id, name) or nil
end

function standalone.weapon(src, claim)
    local name = type(claim) == 'table' and type(claim.name) == 'string' and claim.name:upper() or nil
    if not name or not Rules.weapon(name) then return false, 'NO_WEAPON' end
    return { name = name, metadata = {} }
end

function standalone.state(src, weapon)
    local key = Config.standalone.remember and standaloneKey(src, weapon.name)
    local raw = key and GetResourceKvpString(key)
    local ok, saved = pcall(json.decode, raw or 'null')
    return Rules.normalize(weapon.name, ok and saved or nil)
end

function standalone.owned(_, _, items)
    local out = {}
    for _, item in ipairs(items) do out[item] = 1 end
    return out
end

function standalone.commit(src, weapon, change)
    if not Config.standalone.remember then return true end
    local key = standaloneKey(src, weapon.name)
    if not key then return false, 'NOT_READY' end
    SetResourceKvp(key, json.encode({ parts = change.next.parts, tint = change.next.tint, livery = change.next.livery }))
    return true
end

-- Selection ---------------------------------------------------------------------------

B.adapters = { ox = ox, qb = qb, esx = esxAdapter, standalone = standalone }
local ORDER = { 'ox', 'qb', 'esx' }

function B.pick()
    local wanted = Config.inventory or 'auto'
    if wanted ~= 'auto' then
        local adapter = B.adapters[wanted]
        if adapter and adapter.ready() then return adapter end
        return nil
    end
    for _, name in ipairs(ORDER) do
        if B.adapters[name].ready() then return B.adapters[name] end
    end
    return standalone
end

function B.reset() qbCore, esxObject, reverse = nil, nil, nil end

return B
