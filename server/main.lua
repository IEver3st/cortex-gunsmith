-- Server authority for the bench. A player opens a session on the weapon in
-- their hand; every fit, tint and camo colour is checked against the catalog,
-- the session and the inventory before anything moves. The client only ever
-- shows what this side answered.
local C, R, B = Config, GunsmithRules, GunsmithBridge
local RESOURCE = GetCurrentResourceName()
local sessions, rates, serial = {}, {}, 0

local function ok(data) return { ok = true, data = data } end
local function fail(code, data) return { ok = false, error = { code = code }, data = data } end
local function log(...) print(('[%s]'):format(RESOURCE), ...) end
local function debug(...) if C.debug then log(...) end end

local function limited(src, kind, ms)
    local now = GetGameTimer()
    rates[src] = rates[src] or {}
    local last = rates[src][kind]
    if last and now - last < ms then return true end
    rates[src][kind] = now
    return false
end

local function u32(hash)
    if type(hash) ~= 'number' then return nil end
    hash = math.floor(hash)
    return hash < 0 and hash + 4294967296 or hash
end

local blocked = {}
for _, name in ipairs(C.blockedWeapons or {}) do blocked[tostring(name):upper()] = true end

local function allowed(src)
    local rule = C.access
    if type(rule) ~= 'table' or not rule.ace then return true end
    return IsPlayerAceAllowed(src, rule.ace)
end

-- The weapon the player's ped really holds (OneSync).
local function holding(src, name)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    return u32(GetSelectedPedWeapon(ped)) == u32(GetHashKey(name))
end

local function token()
    serial = serial + 1
    return ('%x%x%x'):format(math.random(0x10000000, 0x7fffffff), GetGameTimer() & 0xffffff, serial)
end

local function claimFrom(payload)
    if type(payload) ~= 'table' then return nil end
    local name = type(payload.weapon) == 'string' and #payload.weapon <= 48 and payload.weapon:upper() or nil
    local slot = math.type(payload.slot) == 'integer' and payload.slot >= 1 and payload.slot <= 512 and payload.slot or nil
    local session = type(payload.session) == 'string' and #payload.session <= 128 and payload.session or nil
    return name and { name = name, slot = slot, session = session } or nil
end

-- What the client draws: the fitted state, part counts and what may change.
local function view(session)
    local adapter = session.adapter
    return {
        token = session.token, weapon = session.name, adapter = adapter.name,
        holster = adapter.holster == true, free = adapter.free == true,
        tint = C.tint.enabled ~= false and adapter.tint == true and R.tintCount(session.name) > 0,
        tintItem = C.tint.item and true or false,
        livery = C.livery.enabled ~= false and adapter.livery == true and R.liveryCount(session.name) > 0,
        state = session.state, owned = session.owned,
    }
end

-- Re-read the weapon and the inventory after a change (or a failed one), so
-- the session holds what the inventory says, not what was planned.
-- A session works on one item. A re-read that finds another weapon in its
-- place (swapped slot, new serial) never becomes the bench's weapon.
local function sameItem(a, b)
    local sa, sb = type(a.metadata) == 'table' and a.metadata.serial, type(b.metadata) == 'table' and b.metadata.serial
    return a.name == b.name and a.slot == b.slot and a.id == b.id and sa == sb
end

local function refresh(src, session, planned)
    local adapter = session.adapter
    local weapon = adapter.weapon(src, session.claim)
    if weapon and sameItem(weapon, session.weapon) then
        session.weapon = weapon
        session.state = adapter.state(src, weapon)
    elseif planned then
        session.state = planned
    end
    -- Pockets belong to the player, whichever weapon the slot holds now.
    local owned = adapter.owned(src, weapon or session.weapon, B.partItems(session.name))
    if owned then session.owned = owned end
end

local function sessionFor(src, payload)
    local session = sessions[src]
    if not session or type(payload) ~= 'table' or payload.token ~= session.token then return nil, 'NO_SESSION' end
    if session.busy then return nil, 'BUSY' end
    if not session.adapter.holster and not holding(src, session.name) then return nil, 'NO_WEAPON' end
    return session
end

-- Runs one change: plan, check, commit, re-read. Exactly one at a time.
local function change(src, session, kind, next, exchange, slot)
    if not session.adapter.free and exchange then
        local take = exchange.take
        -- Counts were read at open; a part picked up since then still counts.
        if take and (session.owned[take] or 0) < 1 and not pcall(refresh, src, session) then
            return fail('UNKNOWN', view(session))
        end
        if take and (session.owned[take] or 0) < 1 then return fail('NO_ITEM', view(session)) end
    else
        exchange = {}
    end
    session.busy = true
    -- A raising adapter must never leave the session busy for good.
    local called, done, code = pcall(session.adapter.commit, src, session.weapon,
        { kind = kind, slot = slot, next = next, take = exchange.take, give = exchange.give })
    if not called then
        log(('%s write raised for player %d: %s'):format(session.adapter.name, src, tostring(done)))
        done, code = nil, 'UNKNOWN'
    end
    local outcome = done == true
    local unknown = done == nil
    local reread, why = pcall(refresh, src, session, outcome and next or nil)
    if not reread then log(('%s re-read raised for player %d: %s'):format(session.adapter.name, src, tostring(why))) end
    session.busy = false
    if outcome then
        debug(('player %d %s on %s'):format(src, kind, session.name))
        return ok(view(session))
    end
    debug(('player %d %s refused: %s'):format(src, kind, tostring(code)))
    return fail(unknown and 'UNKNOWN' or code or 'UNKNOWN', view(session))
end

lib.callback.register(RESOURCE .. ':open', function(src, payload)
    if limited(src, 'open', 600) then return fail('BUSY') end
    if not allowed(src) then return fail('ACCESS') end
    local claim = claimFrom(payload)
    if not claim or not R.weapon(claim.name) then return fail('NO_WEAPON') end
    if blocked[claim.name] then return fail('BLOCKED') end
    if sessions[src] and sessions[src].busy then return fail('BUSY') end
    local adapter = B.pick()
    if not adapter then return fail('NOT_READY') end
    if not holding(src, claim.name) then return fail('NO_WEAPON') end
    local weapon, code = adapter.weapon(src, claim)
    if not weapon then return fail(code or 'NOT_READY') end
    if weapon.name ~= claim.name then return fail('STALE') end
    if adapter.holster and not weapon.equipped then return fail('STALE') end
    local session = { token = token(), adapter = adapter, name = weapon.name, claim = claim, weapon = weapon, busy = false }
    session.state = adapter.state(src, weapon)
    session.owned = adapter.owned(src, weapon, B.partItems(weapon.name)) or {}
    sessions[src] = session
    debug(('player %d opened %s through %s'):format(src, weapon.name, adapter.name))
    return ok(view(session))
end)

lib.callback.register(RESOURCE .. ':apply', function(src, payload)
    local session, code = sessionFor(src, payload)
    if not session then return fail(code) end
    if limited(src, 'apply', 120) then return fail('BUSY') end
    local slot = type(payload.slot) == 'string' and payload.slot or nil
    local component = type(payload.component) == 'string' and #payload.component <= 64 and payload.component or nil
    local next, err, exchange = R.plan(session.name, session.state, slot, component)
    if not next then return fail(err, view(session)) end
    -- A part no item carries can only be fitted where parts are free.
    local part = component and R.part(session.name, component)
    if part and not part.stock and not part.item and not session.adapter.free then return fail('NO_ITEM', view(session)) end
    return change(src, session, 'part', next, exchange, slot)
end)

lib.callback.register(RESOURCE .. ':tint', function(src, payload)
    local session, code = sessionFor(src, payload)
    if not session then return fail(code) end
    if not view(session).tint then return fail('UNSUPPORTED') end
    if limited(src, 'tint', 120) then return fail('BUSY') end
    local next, err = R.planTint(session.name, session.state, payload.tint)
    if not next then return fail(err, view(session)) end
    -- Config.tint.item: one is used per change (checked in change()).
    return change(src, session, 'tint', next, { take = C.tint.item or nil }, nil)
end)

lib.callback.register(RESOURCE .. ':livery', function(src, payload)
    local session, code = sessionFor(src, payload)
    if not session then return fail(code) end
    if not view(session).livery then return fail('UNSUPPORTED') end
    if limited(src, 'livery', 120) then return fail('BUSY') end
    local next, err = R.planLivery(session.name, session.state, payload.livery)
    if not next then return fail(err, view(session)) end
    return change(src, session, 'livery', next, {}, nil)
end)

lib.callback.register(RESOURCE .. ':close', function(src, payload)
    local session = sessions[src]
    if session and type(payload) == 'table' and payload.token == session.token then sessions[src] = nil end
    return ok()
end)

-- The saved setup of a weapon just drawn, for parts the inventory does not
-- fit itself (standalone) and the Mk II camo colour.
lib.callback.register(RESOURCE .. ':setup', function(src, payload)
    if limited(src, 'setup', 250) then return fail('BUSY') end
    local claim = claimFrom(payload)
    if not claim or not R.weapon(claim.name) or not holding(src, claim.name) then return fail('NO_WEAPON') end
    local adapter = B.pick()
    if not adapter or adapter.holster then return fail('UNSUPPORTED') end
    local weapon = adapter.weapon(src, claim)
    if not weapon then return fail('NO_WEAPON') end
    return ok({ weapon = weapon.name, state = adapter.state(src, weapon),
        parts = not adapter.appliesParts, tint = not adapter.appliesTint,
        -- Only where the camo colour is stored; elsewhere 0 would overwrite another script's.
        livery = C.livery.enabled ~= false and adapter.livery == true })
end)

-- Using a part item opens the bench on that part's slot -------------------------

local usable, frameworkKind = {}, nil
local function framework()
    if GetResourceState('qbx_core') == 'started' then return 'qbx' end
    if GetResourceState('qb-core') == 'started' then return 'qb' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
end

local function useItem(src, name)
    if math.type(src) ~= 'integer' or src < 1 then return end
    local item = B.logicalItem(name)
    if GunsmithCatalog.items[item] then TriggerClientEvent(RESOURCE .. ':use', src, item) end
end

local function registerUse()
    if not C.openOnUse then return end
    local adapter = B.pick()
    -- An inventory that fits attachment items itself (ox_inventory) owns their use.
    if not adapter or adapter.ownsUse then return end
    frameworkKind = framework()
    if not frameworkKind then return end
    local core = frameworkKind == 'qb' and exports['qb-core']:GetCoreObject()
        or frameworkKind == 'esx' and exports.es_extended:getSharedObject() or nil
    for item in pairs(GunsmithCatalog.items) do
        local name = B.itemName(item)
        if not usable[name] then
            local function use(source) useItem(source, name) end
            local taken = false
            if frameworkKind == 'qbx' then
                local claimed = pcall(function() taken = exports.qbx_core:CanUseItem(name) and true or false end)
                if not claimed then taken = false end
                if not taken or GetResourceKvpString('usable:' .. name) == '1' then
                    usable[name] = pcall(function() exports.qbx_core:CreateUseableItem(name, use) end)
                end
            elseif frameworkKind == 'qb' then
                pcall(function() taken = core.Functions.CanUseItem(name) and true or false end)
                if not taken or GetResourceKvpString('usable:' .. name) == '1' then
                    usable[name] = pcall(function() core.Functions.CreateUseableItem(name, use) end)
                end
            else
                usable[name] = pcall(function() core.RegisterUsableItem(name, use) end)
            end
            if usable[name] then SetResourceKvp('usable:' .. name, '1') else usable[name] = nil end
        end
    end
end

-- ox_inventory: give a part item `server = { export = 'cortex-gunsmith.useItem' }`
-- to open the bench from it instead of fitting it straight away (see README).
exports('useItem', function(event, item, inventory)
    if event == 'usingItem' and type(inventory) == 'table' and type(item) == 'table' then
        useItem(inventory.id, item.name)
        return false
    end
end)

-- Lifecycle ---------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    sessions[source], rates[source] = nil, nil
end)

local WATCHED = { ox_inventory = true, ['qb-core'] = true, qbx_core = true, es_extended = true }
-- The inventory resource each adapter reads its sessions from.
local SOURCE = { ox = 'ox_inventory' }
AddEventHandler('onResourceStart', function(name)
    if name ~= RESOURCE and WATCHED[name] then
        CreateThread(function() Wait(500); B.reset(); registerUse() end)
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name == RESOURCE then
        if frameworkKind == 'qbx' then
            for item in pairs(usable) do
                pcall(function() exports.qbx_core:CreateUseableItem(item, nil) end)
                DeleteResourceKvp('usable:' .. item)
            end
        end
        return
    end
    if WATCHED[name] then
        -- The inventory under an open bench went away: those sessions are void.
        for src, session in pairs(sessions) do
            if SOURCE[session.adapter.name] == name then
                sessions[src] = nil
                TriggerClientEvent(RESOURCE .. ':closed', src, 'NOT_READY')
            end
        end
        B.reset()
    end
end)

CreateThread(function()
    Wait(0)
    local adapter = B.pick()
    log(('inventory: %s'):format(adapter and adapter.name or ('%s (not running)'):format(C.inventory)))
    registerUse()
end)

-- Other resources: exports['cortex-gunsmith']:isOpen(source)
exports('isOpen', function(src) return sessions[src] ~= nil end)
