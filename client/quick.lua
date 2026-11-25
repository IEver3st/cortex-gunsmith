-- Quick swap: change parts mid-fight without the bench. Hold the quick key
-- with a weapon out and its part slots show beside the crosshair. Scroll
-- (arrow keys, D-pad up and down) to a slot and fire (left mouse, right
-- trigger) to step it to the next part you carry, round to nothing. Let go
-- and every change is fitted in one session with the server, under the
-- bench's own checks. You keep moving and aiming the whole time; only firing
-- and the weapon wheel are taken while the key is down.
--
-- An inventory that changes parts on a holstered weapon only puts the
-- weapon away for the swap and gives it back changed.
--
-- Idle cost is the key mappings. The frame loop only runs while the key is
-- held.
local C, R, Apply = Config, GunsmithRules, GunsmithApply
local S = GunsmithClient
local K = S.kit
local hash = GetHashKey

local RESOURCE = GetCurrentResourceName()
local UNARMED = hash('WEAPON_UNARMED')
-- How long the inventory may take to put the weapon away before the swap
-- gives up (it can wait for minutes).
local HOLSTER_MS = 8000

local quick = nil      -- the swap being chosen or fitted
local handing = nil    -- a swap whose weapon is on its way back to your hands
local remembered = {}  -- the slot each weapon's last swap ended on

-- Taken while choosing: firing (it changes the slot instead) and the weapon
-- wheel, its scroll and the phone keys (they choose the slot).
local TAKEN = { 24, 257, 140, 141, 142, 143, 263, 264, 14, 15, 16, 17, 37, 27, 172, 173, 20 }

function S.quickBusy() return quick ~= nil or (handing ~= nil and handing.reequip == 'pending') end

-- Rows ---------------------------------------------------------------------------------

-- What the weapon in hand wears now, before the server has said.
local function fittedOnPed(options, ped, weapon)
    local stock, none
    for i, o in ipairs(options) do
        if o.none then none = i
        elseif HasPedGotWeaponComponent(ped, weapon, hash(o.component)) then
            if not o.stock then return i end
            stock = stock or i
        end
    end
    return stock or none or 1
end

local function indexOf(options, id)
    for i, o in ipairs(options) do if o.id == id then return i end end
    return 1
end

-- Every part slot with a choice. Finish and camo stay on the bench.
local function rowsFor(name, ped, weapon)
    local rows = {}
    for _, slot in ipairs(R.slots(name)) do
        if not R.SURFACE[slot] then
            local options = K.optionsFor(name, slot)
            if #options > 1 then
                local fitted = fittedOnPed(options, ped, weapon)
                rows[#rows + 1] = { slot = slot, label = L('slot.' .. slot), options = options, fitted = fitted, chosen = fitted }
            end
        end
    end
    return rows
end

-- Whether a choice can be fitted. Until the server has said what you carry,
-- any can: it checks again on the way.
local function allowed(q, row, i)
    local o = row.options[i]
    if i == row.fitted or o.none or o.stock or not q.view or q.view.free then return true end
    return o.item ~= nil and (q.view.owned[o.item] or 0) > 0
end

local function changed(q)
    for _, row in ipairs(q.rows) do if row.chosen ~= row.fitted then return true end end
    return false
end

-- Overlay --------------------------------------------------------------------------------

-- The parts the change key steps to next (up to two, in its order), and
-- where the choice sits among the parts it can reach.
local function ahead(q, row)
    local function can(i) return allowed(q, row, i) end
    local at, of = 0, 0
    for i = 1, #row.options do
        if can(i) then
            of = of + 1
            if i == row.chosen then at = of end
        end
    end
    local next, i = {}, row.chosen
    for _ = 1, 2 do
        i = R.nextChoice(#row.options, i, can)
        if not i or i == row.chosen then break end
        next[#next + 1] = row.options[i].label
    end
    return next, at, of
end

local function show(q)
    local rows = {}
    for i, row in ipairs(q.rows) do
        local next, at, of = ahead(q, row)
        rows[i] = { id = row.slot, label = row.label, part = row.options[row.chosen].label, changed = row.chosen ~= row.fitted,
            next = next, at = at, of = of }
    end
    local hints, step = false, false
    if K.prefs.legend then
        hints = { { key = q.pad and 'UP DOWN' or L('legend.wheel'), label = L('quick.choose') } }
        step = q.pad and 'RT' or 'LMB'
    end
    K.send('quick', { phase = q.phase, weapon = q.label, rows = rows, cursor = q.cursor, hints = hints, step = step,
        release = L('quick.release') })
end

local function close(q)
    if quick == q then quick = nil end
    K.send('quickClose', {})
end

-- The server session ends; a swap that never got one has nothing to end.
local function endSession(q)
    if q.view then
        local token = q.view.token
        CreateThread(function() K.await('close', { token = token }) end)
    end
end

-- Fitting ----------------------------------------------------------------------------------

local function normalized(name, view)
    view.state = R.normalize(name, view.state)
    view.owned = type(view.owned) == 'table' and view.owned or {}
    return view
end

-- Back in your hands (holstering inventories) as the inventory now has it, unless
-- you drew something else meanwhile or died: then it stays put away, changed.
local function handBack(q)
    local ped = PlayerPedId()
    local selected = GetSelectedPedWeapon(ped)
    if IsEntityDead(ped) or selected ~= UNARMED and selected ~= q.hash then return end
    handing = q
    K.reequip(q)
end

-- Holstering inventories: out of your hands first. True once it is; a weapon that
-- only goes away after the swap gave up is handed straight back.
local function holster(q)
    if not q.claim then return false end
    local state = 'pending'
    CreateThread(function()
        local okUse, done = pcall(K.holsterUse, q.claim.slot)
        local away = okUse and done and true or false
        if state == 'abandoned' then
            if away then q.holster = { slot = q.claim.slot, state = 'done' }; handBack(q) end
            return
        end
        state = away and 'done' or 'failed'
    end)
    local deadline = GetGameTimer() + HOLSTER_MS
    while state == 'pending' and GetGameTimer() < deadline do Wait(50) end
    if state == 'pending' then state = 'abandoned' end
    if state ~= 'done' then return false end
    q.holster = { slot = q.claim.slot, state = 'done' }
    return true
end

-- Every changed slot, one at a time and in slot order, the way the bench
-- fits them. The first refusal is what the player hears about.
local function commit(q)
    if q.committing then return end
    q.committing = true
    local changes = {}
    for _, row in ipairs(q.rows) do if row.chosen ~= row.fitted then changes[#changes + 1] = row end end
    CreateThread(function()
        local view, failed = q.view, nil
        if view.holster and not holster(q) then
            K.sound('error')
            K.notify('code.HOLSTER')
            endSession(q)
            close(q)
            return
        end
        -- Whatever goes wrong below, the swap ends and the weapon comes back.
        local fine, why = pcall(function()
            local last = 0
            for _, row in ipairs(changes) do
                local o, result = row.options[row.chosen], nil
                for _ = 1, 2 do
                    -- The server takes one change per 120 ms, counted as each
                    -- arrives: wait from the last answer, and once more if
                    -- it still says BUSY.
                    local gap = 140 - (GetGameTimer() - last)
                    if gap > 0 then Wait(gap) end
                    result = K.await('apply', { token = view.token, slot = row.slot, component = o.component })
                    last = GetGameTimer()
                    if result.ok or K.codeOf(result) ~= 'BUSY' then break end
                end
                if type(result.data) == 'table' and result.data.token == view.token then view = normalized(q.name, result.data) end
                if not result.ok and K.codeOf(result) ~= 'UNCHANGED' then failed = failed or K.codeOf(result) end
            end
        end)
        if not fine then
            print(('[%s] quick swap failed while fitting: %s'):format(RESOURCE, tostring(why)))
            failed = failed or 'UNKNOWN'
        end
        q.view = view
        endSession(q)
        if q.holster then handBack(q)
        else pcall(Apply.toPed, q.name, view.state, { parts = true, tint = view.tint, livery = view.livery }) end
        if failed then
            K.sound('error')
            K.notify('code.' .. failed)
        else
            K.sound('fit')
            K.rumble('fit')
        end
        close(q)
    end)
end

-- Holding ------------------------------------------------------------------------------------

local function cancel(q)
    endSession(q)
    q.cancelled = true
    close(q)
end

-- One frame while the key is down; false when the swap has to stop.
local function frame(q)
    for _, control in ipairs(TAKEN) do DisableControlAction(0, control, true) end
    local ped = PlayerPedId()
    if IsEntityDead(ped) or IsPedRagdoll(ped) or IsPedInAnyVehicle(ped, true) or IsPedSwimming(ped) or IsPauseMenuActive()
        or GetSelectedPedWeapon(ped) ~= q.hash then
        cancel(q)
        return false
    end
    local dirty = false
    local pad = not IsUsingKeyboard(0)
    if pad ~= q.pad then q.pad, dirty = pad, true end
    local function pressed(c) return IsDisabledControlJustPressed(0, c) end
    local delta = (pressed(173) or not pad and pressed(14)) and 1 or (pressed(172) or not pad and pressed(15)) and -1 or 0
    if delta ~= 0 and #q.rows > 1 then
        q.cursor = (q.cursor - 1 + delta) % #q.rows + 1
        K.sound('navigate')
        dirty = true
    end
    if pressed(24) then
        local row = q.rows[q.cursor]
        local next = R.nextChoice(#row.options, row.chosen, function(i) return allowed(q, row, i) end)
        if next then
            row.chosen = next
            K.sound('navigate')
            K.rumble('step')
            dirty = true
        else
            K.sound('error')
        end
    end
    if dirty then show(q) end
    return true
end

-- The server's word on what is fitted and what you carry.
local function adopt(q, view)
    q.view = normalized(q.name, view)
    for _, row in ipairs(q.rows) do
        row.fitted = indexOf(row.options, K.fittedId(q.name, q.view.state, row.slot))
        if not allowed(q, row, row.chosen) then row.chosen = row.fitted end
    end
    show(q)
end

local function begin()
    if quick or S.isOpen() or K.benchBusy() or S.quickBusy() then return end
    local ped = PlayerPedId()
    local why = K.blocked(ped)
    if why then K.notify(why); return end
    local weapon = GetSelectedPedWeapon(ped)
    local name = Apply.nameFor(weapon)
    if not name then K.notify('notify.noWeapon'); return end
    for _, blockedName in ipairs(C.blockedWeapons or {}) do
        if tostring(blockedName):upper() == name then K.notify('notify.blocked'); return end
    end
    local rows = rowsFor(name, ped, weapon)
    if #rows == 0 then K.notify('notify.nothing'); return end
    local cursor = 1
    for i, row in ipairs(rows) do if row.slot == remembered[name] then cursor = i end end
    local q = { name = name, hash = weapon, label = GunsmithCatalog.weapons[name].label, rows = rows, cursor = cursor,
        phase = 'open', pad = not IsUsingKeyboard(0), torn = false }
    quick = q
    show(q)
    K.sound('navigate')
    -- A session with the server, as the bench opens one.
    CreateThread(function()
        local claim = K.nativeClaim()
        local payload = { weapon = name }
        if claim and claim.name == name then payload.slot, payload.session = claim.slot, claim.session end
        local result
        for _ = 1, 4 do
            result = K.await('open', payload)
            -- One open per 600 ms: a quick second swap waits its turn.
            if result.ok or K.codeOf(result) ~= 'BUSY' or q.cancelled then break end
            Wait(250)
        end
        if q.cancelled or quick ~= q then
            if result.ok and type(result.data) == 'table' then CreateThread(function() K.await('close', { token = result.data.token }) end) end
            return
        end
        if not result.ok or type(result.data) ~= 'table' then
            K.sound('error')
            K.notify('code.' .. K.codeOf(result))
            close(q)
            return
        end
        q.claim = claim
        adopt(q, result.data)
        -- Let go while this was on its way.
        if q.released then
            if changed(q) then commit(q) else endSession(q); close(q) end
        end
    end)
    CreateThread(function()
        while quick == q and q.phase == 'open' do
            local fine, going = pcall(frame, q)
            if not fine then
                print(('[%s] quick swap frame failed, cancelling it: %s'):format(RESOURCE, tostring(going)))
                cancel(q)
                return
            end
            if not going then return end
            Wait(0)
        end
    end)
end

local function release()
    local q = quick
    if not q or q.phase ~= 'open' then return end
    remembered[q.name] = q.rows[q.cursor] and q.rows[q.cursor].slot
    q.released = true
    if not changed(q) then
        endSession(q)
        q.cancelled = true
        close(q)
        return
    end
    q.phase = 'fitting'
    show(q)
    if q.view then commit(q) end
end

if type(C.quick) == 'table' and C.quick.enabled ~= false then
    RegisterCommand('+cortexgunsmithquick', begin, false)
    RegisterCommand('-cortexgunsmithquick', release, false)
    RegisterKeyMapping('+cortexgunsmithquick', L('keys.quick'), C.quick.mapper or 'keyboard', C.quick.key or '')
    RegisterCommand('+cortexgunsmithquickpad', begin, false)
    RegisterCommand('-cortexgunsmithquickpad', release, false)
    RegisterKeyMapping('+cortexgunsmithquickpad', L('keys.quick') .. ' (' .. L('keys.controller') .. ')', 'PAD_DIGITALBUTTONANY', C.quick.padKey or '')
end

AddEventHandler('onClientResourceStop', function(name)
    if name == GetCurrentResourceName() and quick then cancel(quick) end
end)

if C.debug then
    -- Development hooks (dev/bridge_client.lua): hold, step and let go as a
    -- player would, and read what the swap is doing.
    S.quickTest = { begin = begin, release = release,
        step = function(kind)
            local q = quick
            if not q or q.phase ~= 'open' then return false end
            if kind == 'down' or kind == 'up' then
                q.cursor = (q.cursor - 1 + (kind == 'down' and 1 or -1)) % #q.rows + 1
            else
                local row = q.rows[q.cursor]
                local next = R.nextChoice(#row.options, row.chosen, function(i) return allowed(q, row, i) end)
                if not next then return false end
                row.chosen = next
            end
            show(q)
            return true
        end,
        state = function()
            local q = quick or handing
            if not q then return { active = false } end
            local rows = {}
            for i, row in ipairs(q.rows) do rows[i] = { slot = row.slot, fitted = row.options[row.fitted].id, chosen = row.options[row.chosen].id } end
            return { active = quick ~= nil, phase = q.phase, cursor = q.cursor, rows = rows, view = q.view ~= nil,
                holster = q.holster and q.holster.state or nil, reequip = q.reequip }
        end,
    }
end
