-- The weapon in your hand wears its setup: when the bench closes, and when
-- you draw a weapon whose parts the inventory does not fit itself
-- (standalone) or that carries a Mk II camo colour.
local R, C = GunsmithRules, Config
local RESOURCE = GetCurrentResourceName()
local hash = GetHashKey

GunsmithApply = {}
local A = GunsmithApply

local names = {}
for name in pairs(GunsmithCatalog.weapons) do names[hash(name)] = name end
function A.nameFor(weaponHash) return names[weaponHash] end

local function pedLivery(ped, weapon, component, colour)
    Citizen.InvokeNative(0x9FE5633880ECD8ED, ped, weapon, hash(component), colour)
end

-- flags = { parts, tint, livery }: which of them this resource puts on.
function A.toPed(name, state, flags)
    local ped = PlayerPedId()
    local weapon = hash(name)
    if not HasPedGotWeapon(ped, weapon, false) then return end
    if flags.parts then
        local wanted = {}
        for _, component in ipairs(R.components(name, state)) do wanted[component] = true end
        for _, component in ipairs(R.allComponents(name)) do
            local h = hash(component)
            local has = HasPedGotWeaponComponent(ped, weapon, h)
            if wanted[component] and not has then GiveWeaponComponentToPed(ped, weapon, h)
            elseif not wanted[component] and has then RemoveWeaponComponentFromPed(ped, weapon, h) end
        end
    end
    if flags.tint and R.tintCount(name) > 0 then SetPedWeaponTintIndex(ped, weapon, state.tint or 0) end
    local camo = state.parts.camo
    if flags.livery and camo and C.livery.enabled ~= false then
        pedLivery(ped, weapon, camo, state.livery or 0)
        local part = R.part(name, camo)
        if part and part.slide then pedLivery(ped, weapon, part.slide, state.livery or 0) end
    end
end

-- Drawing a weapon asks the server for its saved setup. An inventory that fits
-- everything itself answers UNSUPPORTED, which stops the asking.
local supported, asking, last = true, false, 0

local function ask(name)
    asking = true
    CreateThread(function()
        Wait(250) -- let the inventory finish its own equip first
        local ok, result = pcall(function() return lib.callback.await(RESOURCE .. ':setup', false, { weapon = name }) end)
        asking = false
        if not ok or type(result) ~= 'table' then return end
        if result.ok and type(result.data) == 'table' and GetSelectedPedWeapon(PlayerPedId()) == hash(name) then
            A.toPed(name, R.normalize(name, result.data.state), result.data)
        elseif result.error and result.error.code == 'UNSUPPORTED' then
            supported = false
        end
    end)
end

CreateThread(function()
    while true do
        Wait(400)
        if supported and not (GunsmithClient and GunsmithClient.isOpen()) then
            local weapon = GetSelectedPedWeapon(PlayerPedId())
            if weapon ~= last then
                last = weapon
                local name = names[weapon]
                if name and not asking then ask(name) end
            end
        end
    end
end)

local INVENTORIES = { ox_inventory = true, ['qb-core'] = true, qbx_core = true, es_extended = true }
AddEventHandler('onClientResourceStart', function(name)
    if INVENTORIES[name] then supported, last = true, 0 end
end)

-- After the bench: ask again next time even for the same weapon.
function A.forget() last = 0 end
