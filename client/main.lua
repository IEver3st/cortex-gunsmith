-- The player's side of the bench: opening and closing, the NUI, pad input
-- and the round trips to the server. The bench (bench.lua) draws; the server
-- decides; this file owns the session in between.
--
-- Idle cost is one key mapping and the 400 ms weapon watcher in apply.lua.
-- The frame loop only runs while the bench is open.
local C, R, Bench, Apply = Config, GunsmithRules, GunsmithBench, GunsmithApply
local RESOURCE = GetCurrentResourceName()
local TAB = 'gunsmith'
local hash = GetHashKey

GunsmithClient = {}
local S = GunsmithClient

local session = nil
local nuiReady, closedAt, opening = false, 0, false
local prefs = { legend = true, dof = C.bench.dof ~= false }
local STAT_IDS = { 'damage', 'speed', 'capacity', 'accuracy', 'range' }

local function debug(...) if C.debug then print('[cortex-gunsmith]', ...) end end

local function notify(key, kind, vars)
    if lib and lib.notify then lib.notify({ description = L(key, vars), type = kind or 'error' }) end
end

local function sound(name)
    local s = C.sounds[name]
    if s then PlaySoundFrontend(-1, s[1], s[2], true) end
end

-- Controller rumble (Config.bench.rumble): how long (ms) and how hard (0-255).
local RUMBLE = { fit = { 110, 160 }, remove = { 80, 100 }, finish = { 140, 70 }, fire = { 90, 220 }, step = { 40, 80 } }
local function rumble(name)
    local r = C.bench.rumble ~= false and RUMBLE[name]
    if r then SetPadShake(0, r[1], r[2]) end
end

local function hud(visible)
    if GetResourceState('cortex-hud') ~= 'started' then return end
    pcall(function() exports['cortex-hud']:setHudVisibleReason('gunsmith', visible) end)
end

local function await(name, payload)
    local ok, result = pcall(function() return lib.callback.await(RESOURCE .. ':' .. name, false, payload or {}) end)
    if not ok or type(result) ~= 'table' then return { ok = false, error = { code = 'UNKNOWN' } } end
    return result
end

local function codeOf(result) return type(result.error) == 'table' and result.error.code or 'UNKNOWN' end

function S.isOpen() return session ~= nil end
-- quick.lua replaces it: true while a quick swap is held or being fitted.
function S.quickBusy() return false end

-- Options ----------------------------------------------------------------------------

-- Every choice in a slot, as the NUI lists it. Slots without a stock part
-- start with "None"; tint and camo colour are slots of their own.
local function optionsFor(name, slot)
    local out = {}
    if slot == 'tint' then
        for _, entry in ipairs(R.tints(name) or {}) do out[#out + 1] = { id = 'tint:' .. entry[1], label = entry[2], tint = entry[1] } end
        return out
    end
    if slot == 'livery' then
        for _, entry in ipairs(R.tints(name) or {}) do out[#out + 1] = { id = 'livery:' .. entry[1], label = entry[2], livery = entry[1] } end
        return out
    end
    if not R.stock(name, slot) then out[1] = { id = 'none:' .. slot, label = L('option.none'), none = true } end
    for _, part in ipairs(R.options(name, slot)) do
        out[#out + 1] = { id = part.component, label = part.label or part.component, component = part.component, item = part.item, stock = part.stock == true }
    end
    return out
end

-- The option id fitted in a slot right now.
local function fittedId(name, state, slot)
    if slot == 'tint' then return 'tint:' .. (state.tint or 0) end
    if slot == 'livery' then return 'livery:' .. (state.livery or 0) end
    local component = state.parts[slot]
    if component then return component end
    local stock = R.stock(name, slot)
    return stock and stock.component or ('none:' .. slot)
end

-- Slots on offer: parts with a choice, then tint, then the camo colour while
-- a Mk II camo is fitted.
local function visibleSlots(s)
    local out = {}
    for _, slot in ipairs(R.slots(s.name)) do out[#out + 1] = slot end
    if s.view.tint then out[#out + 1] = 'tint' end
    if s.view.livery and s.view.state.parts.camo then out[#out + 1] = 'livery' end
    return out
end

local function indexOf(list, value)
    for i, item in ipairs(list) do if item == value or (type(item) == 'table' and item.id == value) then return i end end
end

-- What the bench shows: the fitted state with the option under the cursor,
-- or the weapon as it comes while the stock view is held.
local function displayState(s)
    if s.compare then return R.normalize(s.name, {}) end
    local state = R.copy(s.view.state)
    local option = s.preview
    if option and s.focus then
        if option.tint then state.tint = option.tint
        elseif option.livery then state.livery = option.livery
        else
            state.parts[s.focus] = (option.none or option.stock) and nil or option.component
            if s.focus == 'camo' and not state.parts.camo then state.livery = 0 end
        end
    end
    return state
end

local function affordable(s, option)
    if s.view.free or option.none or option.stock then return true end
    if option.tint then return not C.tint.item or (s.view.owned[C.tint.item] or 0) > 0 end
    if option.livery then return true end
    return option.item ~= nil and (s.view.owned[option.item] or 0) > 0
end

-- Stats ------------------------------------------------------------------------------

local statCache = {}
local function stat(kind, name)
    local key = kind .. name
    local cached = statCache[key]
    if cached == nil then
        local ok, value = pcall(function() return exports[RESOURCE][kind](exports[RESOURCE], hash(name)) end)
        cached = ok and type(value) == 'table' and value or false
        statCache[key] = cached
    end
    return cached or nil
end

local function statLine(name, state)
    local base = stat('weaponStats', name)
    if not base then return nil end
    local out, any = {}, false
    for _, id in ipairs(STAT_IDS) do
        out[id] = tonumber(base[id]) or 0
        if out[id] ~= 0 then any = true end
    end
    if not any then return nil end
    for _, component in ipairs(R.components(name, state)) do
        local delta = stat('componentStats', component)
        if delta then for _, id in ipairs(STAT_IDS) do out[id] = out[id] + (tonumber(delta[id]) or 0) end end
    end
    return out
end

local function stats(s)
    local now, next = statLine(s.name, s.view.state), statLine(s.name, displayState(s))
    if not now or not next then return nil end
    local out = {}
    for _, id in ipairs(STAT_IDS) do
        out[#out + 1] = { id = id, now = math.max(0, math.min(100, now[id])), next = math.max(0, math.min(100, next[id])) }
    end
    return out
end

-- NUI --------------------------------------------------------------------------------

local sent = {}
local function send(action, data)
    SendNUIMessage({ action = 'gunsmith:' .. action, data = data })
    if C.debug then sent[action] = { at = GetGameTimer(), count = (sent[action] and sent[action].count or 0) + 1, phase = data and data.phase } end
end

local function words()
    local out = {}
    for key, value in pairs(Locale.all()) do
        if key:match('^ui%.') or key:match('^slot%.') or key:match('^stat%.') or key:match('^code%.') or key:match('^option%.') then out[key] = value end
    end
    return out
end

local function sendOpen(s)
    local slots = {}
    for _, slot in ipairs(R.slots(s.name)) do slots[#slots + 1] = { id = slot, label = L('slot.' .. slot), options = optionsFor(s.name, slot) } end
    if s.view.tint then slots[#slots + 1] = { id = 'tint', label = L('slot.tint'), options = optionsFor(s.name, 'tint') } end
    if s.view.livery then slots[#slots + 1] = { id = 'livery', label = L('slot.livery'), options = optionsFor(s.name, 'livery') } end
    local weapon = GunsmithCatalog.weapons[s.name]
    send('open', { weapon = { name = s.name, label = weapon.label, group = L('group.' .. weapon.group) },
        slots = slots, flags = { free = s.view.free, holster = s.view.holster, debug = C.debug == true } })
end

local function sendState(s)
    s.dirty = false
    local fitted = {}
    for _, slot in ipairs(visibleSlots(s)) do fitted[slot] = fittedId(s.name, s.view.state, slot) end
    send('state', {
        phase = s.closing and 'closing' or (Bench.phase() == 'intro' and 'intro' or 'open'),
        slots = visibleSlots(s), focus = s.focus, cursor = s.cursor, fitted = fitted,
        preview = s.preview and s.preview.id or nil, owned = s.view.owned, pending = s.pending,
        holstering = s.holster ~= nil and s.holster.state == 'pending', exploded = Bench.isExploded(), compare = s.compare == true,
        stats = stats(s), notice = s.notice, legend = s.legendPx or 0,
    })
end

local function dirty() if session then session.dirty = true end end

-- Projections change every frame something moves; send only real changes.
local function sendFrame(s)
    local p = Bench.project()
    if not p then return end
    local key = {}
    if p.centre then key[#key + 1] = p.centre[1]; key[#key + 1] = p.centre[2] end
    for _, slot in ipairs(R.SLOTS) do
        local a = p.anchors[slot]
        key[#key + 1] = a and a[1] or -1
        key[#key + 1] = a and a[2] or -1
    end
    if p.box then for i = 1, 4 do key[#key + 1] = p.box[i] end end
    local same = s.lastFrame and #s.lastFrame == #key
    if same then for i = 1, #key do if s.lastFrame[i] ~= key[i] then same = false; break end end end
    if same then return end
    s.lastFrame = key
    send('frame', p)
end

-- Help legend (cortex-lib) ---------------------------------------------------------------

-- Only what the screen doesn't already show, for what you're doing: the slots
-- wear their number keys and the drawer its ENTER button. Reset view (R, Y)
-- still works; it's left off to keep the strip short.
local function legend(s)
    if not prefs.legend or not (lib and lib.showHelp) then return end
    local pad = not IsUsingKeyboard(0)
    local mode = (pad and 'pad' or 'keys') .. (s.focus and ' drawer' or '')
    if s.legendMode == mode then return end
    s.legendMode = mode
    local function row(key, value) return { label = L(key), value = value } end
    local rows
    -- The dry fire and the stock view only on the overview, the fire only
    -- for a weapon that shoots.
    local fire = Bench.canFire()
    if pad then
        rows = s.focus and { row('legend.browse', 'UP DOWN'), row('legend.fit', 'A'), row('legend.turn', 'RS'), row('legend.back', 'B') }
            or { row('legend.slot', 'LB RB'), row('legend.turn', 'RS'), row('legend.zoom', 'LT RT'), row('legend.explode', 'X'),
                fire and row('legend.fire', 'Y') or false, row('legend.compare', 'L3'), row('legend.back', 'B') }
    else
        rows = s.focus and { row('legend.browse', 'W S'), row('legend.turn', L('legend.drag')), row('legend.zoom', L('legend.wheel')), row('legend.back', 'ESC') }
            or { row('legend.turn', L('legend.drag')), row('legend.zoom', L('legend.wheel')), row('legend.explode', 'X'),
                fire and row('legend.fire', 'F') or false, row('legend.compare', 'C'), row('legend.back', 'ESC') }
    end
    local packed = {}
    for _, r in ipairs(rows) do if r then packed[#packed + 1] = r end end
    rows = packed
    pcall(lib.showHelp, rows, { compact = true })
end

-- How far cortex-lib's legend reaches up from the bottom of the screen (NUI
-- px): the drawer stops above it rather than covering it.
local function legendClearance(s, now)
    if s.legendAt and now - s.legendAt < 250 then return end
    s.legendAt = now
    local px = prefs.legend and tonumber(LocalPlayer.state.cortexHelpLegend) or 0
    px = px and px == px and px > 0 and px < 4096 and math.floor(px) or 0
    if px ~= s.legendPx then s.legendPx = px; s.dirty = true end
end

local function hideLegend() if lib and lib.hideHelp then pcall(lib.hideHelp) end end

-- Focus and preview -------------------------------------------------------------------

local function refreshBench(s)
    Bench.show(displayState(s))
    dirty()
end

local function focus(s, slot)
    if slot and not indexOf(visibleSlots(s), slot) then return end
    if s.focus == slot then return end
    s.focus, s.preview = slot, nil
    s.options = slot and optionsFor(s.name, slot) or nil
    s.cursor = slot and (indexOf(s.options, fittedId(s.name, s.view.state, slot)) or 1) or nil
    local part = slot ~= 'tint' and slot ~= 'livery'
    -- The old slot's part windows stay until the drawer reports the new
    -- slot's: dropping them now would leave its windows on the street.
    Bench.setFocus(part and slot or nil)
    -- Part windows for every part slot but camo (its models are paint, with
    -- nothing to show on their own); the page decides the same way.
    Bench.drawer(slot ~= nil, part and slot ~= 'camo')
    sound('navigate')
    refreshBench(s)
end

local function moveCursor(s, index)
    if not s.focus or not s.options then return end
    local count = #s.options
    if count == 0 then return end
    index = ((index - 1) % count) + 1
    if index == s.cursor then return end
    s.cursor = index
    local option = s.options[index]
    s.preview = option.id ~= fittedId(s.name, s.view.state, s.focus) and option or nil
    sound('navigate')
    refreshBench(s)
end

-- Hold to see the weapon as it comes: every part slides off, the finish
-- goes back to stock and the stats show the difference; let go for the build.
local function compare(s, on)
    on = on == true
    if (s.compare == true) == on or s.closing then return end
    s.compare = on
    sound('navigate')
    refreshBench(s)
end

-- A blank, for show (bench.lua): no bullet, and only this screen sees it.
local function fire(s)
    if s.closing or not Bench.fire() then return end
    sound('fire')
    rumble('fire')
end

local function stepSlot(s, delta)
    local slots = visibleSlots(s)
    if #slots == 0 then return end
    local at = indexOf(slots, s.focus) or (delta > 0 and 0 or 1)
    focus(s, slots[((at - 1 + delta) % #slots) + 1])
end

-- The server's answer replaces what the session knows, then the view re-derives.
local function adopt(s, view)
    if type(view) ~= 'table' or view.token ~= s.view.token then return end
    view.state = R.normalize(s.name, view.state)
    view.owned = type(view.owned) == 'table' and view.owned or {}
    s.view = view
    if s.focus and not indexOf(visibleSlots(s), s.focus) then
        s.focus, s.options, s.cursor = nil, nil, nil
        Bench.setFocus(nil); Bench.drawer(false)
    end
    if s.focus then
        local option = s.options[s.cursor]
        s.preview = option and option.id ~= fittedId(s.name, view.state, s.focus) and option or nil
    else
        s.preview = nil
    end
    refreshBench(s)
end

local function notice(s, code)
    s.notice = { code = code, at = GetGameTimer() }
    dirty()
end

-- Fit the option under the cursor (or a clicked one).
local function apply(s, index)
    if s.closing or not s.focus or not s.options then return end
    if index then moveCursor(s, index) end
    local option = s.options[s.cursor]
    if not option then return end
    if option.id == fittedId(s.name, s.view.state, s.focus) then return end
    if s.pending then return end
    if s.holster and s.holster.state ~= 'done' then sound('error'); notice(s, 'HOLSTER'); return end
    if not affordable(s, option) then sound('error'); notice(s, 'NO_ITEM'); return end
    s.pending, s.notice = true, nil
    dirty()
    local slot, token = s.focus, s.view.token
    CreateThread(function()
        local result
        if option.tint then result = await('tint', { token = token, tint = option.tint })
        elseif option.livery then result = await('livery', { token = token, livery = option.livery })
        else result = await('apply', { token = token, slot = slot, component = option.component }) end
        if session ~= s then return end
        s.pending = false
        if type(result.data) == 'table' then adopt(s, result.data) end
        if result.ok then
            local surface = R.SURFACE[slot] or slot == 'tint' or slot == 'livery'
            if surface then
                sound('finish')
                rumble('finish')
                -- The new look is already on; the turn shows it off.
                Bench.flourish(nil)
            else
                local off = option.none or option.stock
                sound(off and 'remove' or 'fit')
                rumble(off and 'remove' or 'fit')
                Bench.seated(slot)
            end
        else
            local code = codeOf(result)
            if code ~= 'UNCHANGED' then sound('error'); notice(s, code) end
        end
        dirty()
    end)
end

-- Open / close ------------------------------------------------------------------------

local function blocked(ped)
    if not DoesEntityExist(ped) or IsEntityDead(ped) or IsPedFatallyInjured(ped) then return 'notify.cannot' end
    if IsPedInAnyVehicle(ped, true) then return 'notify.vehicle' end
    if IsPedSwimming(ped) or IsPedSwimmingUnderWater(ped) then return 'notify.water' end
    if IsPedRagdoll(ped) or IsPedFalling(ped) or IsPedClimbing(ped) or IsPedCuffed(ped) or IsPedReloading(ped) then return 'notify.cannot' end
    local state = LocalPlayer.state
    if state.isCuffed or state.isHandcuffed or state.isDead or state.invBusy then return 'notify.cannot' end
    if IsPauseMenuActive() or IsNuiFocused() then return 'notify.menu' end
end

-- Where the weapon in hand is, so the flight starts from it.
local function handPose(ped)
    local entity = GetCurrentPedWeaponEntityIndex(ped, 0)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        local p = GetEntityCoords(entity)
        local x, y, z, w = GetEntityQuaternion(entity)
        return { pos = GunsmithRig.v(p.x, p.y, p.z), q = GunsmithRig.qnorm(GunsmithRig.q(x, y, z, w)) }
    end
    local p = GetPedBoneCoords(ped, 57005, 0.0, 0.0, 0.0)
    return { pos = GunsmithRig.v(p.x, p.y, p.z), q = nil }
end

-- The real weapon back in your hand, once it is: the close lands the bench
-- copy exactly on it. Second result: it isn't coming (the hand-back failed),
-- so the close shouldn't wait for it.
local lastTrack = nil -- debug: what the last close saw of the weapon in hand
local function liveWeapon(s)
    local ped = PlayerPedId()
    local selected = GetSelectedPedWeapon(ped) == s.hash
    if C.debug then lastTrack = { selected = selected, entity = GetCurrentPedWeaponEntityIndex(ped, 0), at = GetGameTimer() } end
    if not selected then return nil, s.reequip == 'failed' or s.reequip == 'missing' end
    local at = handPose(ped)
    return at.q and at or nil
end

-- An inventory that changes parts only on a weapon out of the hand (the
-- server's view.holster) puts the weapon away and gives it back through
-- these. claim(): the weapon item in hand as { slot, session, name }, or nil.
-- use(slot): equip or put away that slot; true once done.
local holsterKit = { claim = function() return nil end, use = function() return false end }

-- Back in hand through the inventory (ammo, parts and all), once. Waits for a
-- fit in flight: the inventory only changes parts on a holstered weapon. Its
-- useSlot gives the weapon back holstered, so it is taken straight into the
-- hand here (no draw animation) for the close to land on, the moment it is
-- back: the inventory's weapon push can come before useSlot answers. If it
-- never comes, say so.
local lastReturn = nil -- debug: how long the last hand-back took (ms from asking)
local function reequip(s)
    if not s.holster or s.holster.state ~= 'done' or s.reequip then return end
    s.reequip = 'pending'
    local from, timing, askedAt, answeredAt = GetGameTimer(), {}, nil, nil
    if C.debug then lastReturn = timing end
    -- The first outcome stands; only a failure tells the player.
    local function settle(state)
        if s.reequip ~= 'pending' then return end
        s.reequip = state
        if state ~= 'done' then notify('notify.reequip') end
    end
    CreateThread(function()
        local deadline = from + 5000
        while s.pending and GetGameTimer() < deadline do Wait(50) end
        askedAt = GetGameTimer()
        local ok, done = pcall(holsterKit.use, s.holster.slot)
        timing.used = GetGameTimer() - from
        if ok and done then answeredAt = GetGameTimer() else settle('failed') end
    end)
    CreateThread(function()
        -- A weapon still on the ped from the open's holster isn't the one
        -- coming back: until useSlot answers, wait to see that one go first.
        local gone = false
        while s.reequip == 'pending' do
            local ped, now = PlayerPedId(), GetGameTimer()
            if GetSelectedPedWeapon(ped) == s.hash then settle('done'); break end
            -- Answered but never handed over, or no answer at all (useSlot
            -- itself can wait for minutes).
            if answeredAt and now - answeredAt > 1500 or askedAt and now - askedAt > 10000 then settle('missing'); break end
            if not HasPedGotWeapon(ped, s.hash, false) then gone = true
            elseif gone or answeredAt then SetCurrentPedWeapon(ped, s.hash, true) end
            Wait(0)
        end
        if s.reequip ~= 'done' then return end
        timing.selected = GetGameTimer() - from
        -- Drawn by the inventory instead (GTA's draw animation): straight into
        -- the hand while the copy is still on its way.
        if not s.torn and GetCurrentPedWeaponEntityIndex(PlayerPedId(), 0) == 0 then SetCurrentPedWeapon(PlayerPedId(), s.hash, true) end
        local deadline = GetGameTimer() + 1500
        while GetCurrentPedWeaponEntityIndex(PlayerPedId(), 0) == 0 and GetGameTimer() < deadline do Wait(0) end
        if GetCurrentPedWeaponEntityIndex(PlayerPedId(), 0) ~= 0 then timing.inHand = GetGameTimer() - from end
        -- Landed after the bench was gone: teardown's show missed it.
        if s.torn then SetPedCurrentWeaponVisible(PlayerPedId(), true, false, false, false) end
    end)
end

local function pose(ped, on)
    local p = C.bench.pose
    if not p or not p.dict then return end
    if on then
        RequestAnimDict(p.dict)
        local deadline = GetGameTimer() + 1000
        while not HasAnimDictLoaded(p.dict) and GetGameTimer() < deadline do Wait(0) end
        if HasAnimDictLoaded(p.dict) then TaskPlayAnim(ped, p.dict, p.clip, 3.0, 3.0, -1, 1, 0.0, false, false, false) end
    else
        StopAnimTask(ped, p.dict, p.clip, 2.0)
        RemoveAnimDict(p.dict)
    end
end

local function nativeClaim() return holsterKit.claim() end

local finish

-- The last frame of a close, animated or not.
local function teardown(s, instant)
    if s.torn then return end
    s.torn = true
    -- Let go first, so nothing below can leave you stuck. Only a lock this
    -- bench made is released (an admin freeze stays).
    if not s.frozen and DoesEntityExist(s.ped) then FreezeEntityPosition(s.ped, false) end
    Bench.destroy()
    local ped = PlayerPedId()
    if instant then pose(ped, false) end
    -- Back in hand (a no-op when the close already started it), and the gun
    -- in hand shown again: it stayed hidden under the copy until now.
    if s.holster then
        if s.holster.state == 'done' then reequip(s) end
    else
        Apply.toPed(s.name, s.view.state, { parts = true, tint = s.view.tint, livery = s.view.livery })
    end
    SetPedCurrentWeaponVisible(ped, true, false, false, false)
    Apply.forget()
    hud(true)
    CreateThread(function()
        local deadline = GetGameTimer() + 5000
        while s.pending and GetGameTimer() < deadline do Wait(50) end
        await('close', { token = s.view.token })
    end)
end

finish = function(instant)
    local s = session
    if not s then return end
    -- Closed while the stock view is held: the copy lands on the real
    -- weapon as it really is, not as it came.
    if s.compare then s.compare = false; Bench.show(s.view.state, true) end
    s.closing = true
    SetNuiFocus(false, false)
    hideLegend()
    send('close', {})
    if instant or not Bench.isOpen() then
        teardown(s, true)
        session, closedAt = nil, GetGameTimer()
        return
    end
    -- Animated: the weapon flies back into your hand; the loop ends it. The
    -- real one goes back in hand now, dressed as the bench left it and kept
    -- hidden (step), so the copy can follow it and hand over in one frame.
    local ped = PlayerPedId()
    pose(ped, false)
    if s.holster then reequip(s)
    else Apply.toPed(s.name, s.view.state, { parts = true, tint = s.view.tint, livery = s.view.livery }) end
    local target = handPose(ped)
    if not target.q then target.q = s.handoff and s.handoff.q end
    Bench.close(target, function() return liveWeapon(s) end)
    dirty()
end

function S.close(instant) finish(instant) end

local function interrupted(s, ped)
    if IsEntityDead(ped) or IsPedRagdoll(ped) or IsPedFalling(ped) or IsPedInAnyVehicle(ped, true) or IsPedSwimming(ped) then return true end
    if GetEntityHealth(ped) < s.health then return true end
    if not s.holster and GetSelectedPedWeapon(ped) ~= s.hash then return true end
    return false
end

-- Pad: right stick turns, triggers zoom, bumpers and D-pad left/right change
-- slot, D-pad up/down browse, A fits, B backs out, X explodes, Y dry-fires,
-- holding the left stick in shows the stock weapon and clicking the right
-- one resets the view.
local PAD = { up = 172, down = 173, left = 174, right = 175, accept = 201, cancel = 202, x = 203, y = 204, lb = 205, rb = 206, ls = 209, rs = 210 }
local function padInput(s)
    if IsUsingKeyboard(0) then return end
    local function pressed(c) return IsDisabledControlJustPressed(0, c) end
    local rx, ry = GetDisabledControlNormal(0, 1), GetDisabledControlNormal(0, 2)
    if math.abs(rx) > 0.12 or math.abs(ry) > 0.12 then Bench.turn(rx * 9.0, ry * 9.0) end
    local zoom = GetDisabledControlNormal(0, 228) - GetDisabledControlNormal(0, 229)
    if math.abs(zoom) > 0.1 then Bench.zoom(zoom * 0.08) end
    if pressed(PAD.left) or pressed(PAD.lb) then stepSlot(s, -1) end
    if pressed(PAD.right) or pressed(PAD.rb) then stepSlot(s, 1) end
    if pressed(PAD.up) and s.focus then moveCursor(s, s.cursor - 1) end
    if pressed(PAD.down) and s.focus then moveCursor(s, s.cursor + 1) end
    if pressed(PAD.accept) then if s.focus then apply(s) else stepSlot(s, 1) end end
    if pressed(PAD.cancel) then if s.focus then focus(s, nil) else finish(false) end end
    if pressed(PAD.x) then Bench.explode(not Bench.isExploded()); sound(Bench.isExploded() and 'remove' or 'navigate'); dirty() end
    if pressed(PAD.y) then fire(s) end
    if pressed(PAD.rs) then Bench.resetView() end
    local held = IsDisabledControlPressed(0, PAD.ls)
    if held ~= (s.padCompare == true) then s.padCompare = held; compare(s, held) end
end

-- One frame; returns true when the bench has ended.
local function step(s)
    local now = GetGameTimer()
    DisableAllControlActions(0)
    EnableControlAction(0, 249, true) -- push to talk
    HideHudAndRadarThisFrame()
    local ped = PlayerPedId()
    -- Closing: the real weapon is back in hand under the flying copy. Keep it
    -- hidden until the copy lands on it (teardown shows it the same frame).
    if s.closing and GetSelectedPedWeapon(ped) == s.hash then SetPedCurrentWeaponVisible(ped, false, false, false, false) end
    if not s.closing then
        if interrupted(s, ped) then finish(true); return true end
        -- The page acknowledges every open. Without that it can't show or take
        -- input, so close rather than leave the player behind NUI focus.
        if not s.acked and now - s.sentAt > 2500 then
            print(('[%s] the bench page never acknowledged the open; closing the bench'):format(RESOURCE))
            notify('notify.noScreen')
            finish(true)
            return true
        end
        padInput(s)
        legend(s)
        legendClearance(s, now)
        if s.notice and now - s.notice.at > 2600 then s.notice = nil; dirty() end
    end
    local moved = Bench.frame(now, GetFrameTime())
    if Bench.phase() == 'done' then
        teardown(s, false)
        session, closedAt = nil, GetGameTimer()
        return true
    end
    if not s.closing then
        if moved or s.dirty then sendFrame(s) end
        if s.dirty or s.phaseSent ~= Bench.phase() then s.phaseSent = Bench.phase(); sendState(s) end
    end
end

local function loop(s)
    CreateThread(function()
        while session == s do
            local fine, ended = pcall(step, s)
            if not fine then
                -- Never leave the player behind NUI focus with the controls off.
                print(('[%s] bench frame failed, closing it: %s'):format(RESOURCE, tostring(ended)))
                SetNuiFocus(false, false)
                if session == s then pcall(finish, true) end
                if session == s then pcall(teardown, s, true); session, closedAt = nil, GetGameTimer() end
                break
            end
            if ended then break end
            Wait(0)
        end
    end)
end

local function open(focusSlot, focusItem, byKey)
    if session or opening or S.quickBusy() then return end
    if GetGameTimer() - closedAt < 600 then return end
    local ped = PlayerPedId()
    local why = blocked(ped)
    -- The open key may mean something else in a vehicle; stay quiet there.
    if why then if not (byKey and why == 'notify.vehicle') then notify(why) end; return end
    local weaponHash = GetSelectedPedWeapon(ped)
    local name = Apply.nameFor(weaponHash)
    if not name then notify('notify.noWeapon'); return end
    for _, blockedName in ipairs(C.blockedWeapons or {}) do
        if tostring(blockedName):upper() == name then notify('notify.blocked'); return end
    end
    if not nuiReady then notify('notify.notReady'); return end
    opening = true
    CreateThread(function()
        local heading = Bench.room(ped)
        if not heading then opening = false; notify('notify.room'); return end
        local claim = nativeClaim()
        local payload = { weapon = name }
        if claim and claim.name == name then payload.slot, payload.session = claim.slot, claim.session end
        local result = await('open', payload)
        if not result.ok then opening = false; notify('code.' .. codeOf(result)); return end
        local view = result.data
        view.state, view.owned = R.normalize(name, view.state), type(view.owned) == 'table' and view.owned or {}
        if blocked(ped) or GetSelectedPedWeapon(ped) ~= weaponHash then
            opening = false
            await('close', { token = view.token })
            return
        end
        local motion = 'full'
        pcall(function() motion = exports['cortex-lib']:getPresentation().profile.motion end)
        Bench.reduced = motion == 'reduced'
        C.bench.dof = prefs.dof
        SetEntityHeading(ped, heading)
        local handoff = handPose(ped)
        local ok, err = Bench.open(name, { ped = ped, heading = heading, state = view.state, handoff = handoff })
        if not ok then
            opening = false
            notify('code.' .. tostring(err))
            await('close', { token = view.token })
            return
        end
        local s = { name = name, hash = weaponHash, view = view, handoff = handoff, dirty = true, health = GetEntityHealth(ped),
            ped = ped, frozen = IsEntityPositionFrozen(ped) }
        session, opening = s, false
        -- Locked in place while you work: the first-person camera is fixed at
        -- your eyes, so nothing may push you out from under it.
        FreezeEntityPosition(ped, true)
        if view.holster and claim then
            s.holster = { slot = claim.slot, state = 'pending' }
            CreateThread(function()
                local okUse, done = pcall(holsterKit.use, claim.slot)
                if session ~= s then
                    -- Closed while it went away: teardown could not re-equip it, so do it here.
                    if okUse and done then s.holster.state = 'done'; reequip(s) end
                    return
                end
                if okUse and done then
                    s.holster.state = 'done'
                    -- Closing already: straight back in hand for the copy to land on.
                    if s.closing then reequip(s) else pose(PlayerPedId(), true) end
                else
                    s.holster.state = 'failed'
                    notify('code.HOLSTER')
                    finish(false)
                end
                dirty()
            end)
        end
        -- The bench copy takes over from the gun in your hand.
        SetPedCurrentWeaponVisible(ped, false, false, false, false)
        pose(ped, true)
        hud(false)
        sound('open')
        s.sentAt = GetGameTimer()
        sendOpen(s)
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(false)
        debug(('open %s: holster=%s free=%s nuiFocused=%s'):format(name, tostring(view.holster), tostring(view.free), tostring(IsNuiFocused())))
        loop(s)
        -- Opened from a part item: straight to its slot, cursor on the part.
        if focusSlot then
            focus(s, focusSlot)
            if focusItem and s.options then
                for i, option in ipairs(s.options) do if option.item == focusItem then moveCursor(s, i) break end end
            end
        end
    end)
end

function S.open() open() end

local function toggle()
    if session then finish(false) else open() end
end
local function toggleKey()
    if session then finish(false) else open(nil, nil, true) end
end

if C.command then RegisterCommand(C.command, toggle, false) end
RegisterCommand('cortexgunsmith', toggleKey, false)
if C.key then RegisterKeyMapping('cortexgunsmith', L('keys.open'), 'keyboard', C.key) end
RegisterCommand('cortexgunsmithpad', toggleKey, false)
if C.padKey then RegisterKeyMapping('cortexgunsmithpad', L('keys.open') .. ' (' .. L('keys.controller') .. ')', 'PAD_DIGITALBUTTONANY', C.padKey) end

-- NUI intents -------------------------------------------------------------------------

local function finite(n, lo, hi) return type(n) == 'number' and n == n and n >= lo and n <= hi end

local INTENTS = {
    slot = function(s, d) if type(d.slot) == 'string' then focus(s, d.slot) end end,
    step = function(s, d) if d.delta == 1 or d.delta == -1 then stepSlot(s, d.delta) end end,
    back = function(s) if s.focus then focus(s, nil) else finish(false) end end,
    move = function(s, d) if (d.delta == 1 or d.delta == -1) and s.cursor then moveCursor(s, s.cursor + d.delta) end end,
    pick = function(s, d) if math.type(d.index) == 'integer' and s.options and s.options[d.index] then moveCursor(s, d.index) end end,
    apply = function(s, d)
        if d.index == nil then apply(s) elseif math.type(d.index) == 'integer' and s.options and s.options[d.index] then apply(s, d.index) end
    end,
    turn = function(_, d) if finite(d.dx, -4000, 4000) and finite(d.dy, -4000, 4000) then Bench.turn(d.dx, d.dy) end end,
    zoom = function(_, d) if finite(d.delta, -20, 20) then Bench.zoom(d.delta) end end,
    explode = function(s)
        Bench.explode(not Bench.isExploded())
        sound(Bench.isExploded() and 'remove' or 'navigate')
        dirty()
    end,
    reset = function() Bench.resetView() end,
    close = function() finish(false) end,
    fire = function(s) fire(s) end,
    compare = function(s, d) if type(d.on) == 'boolean' then compare(s, d.on) end end,
    -- Pressed on the weapon (catches a coasting turn) and let go: the last
    -- bit of the drag, then its speed (1080p px a second) to coast on.
    drag = function(_, d)
        if d.held == true then Bench.grab()
        elseif d.held == false and finite(d.vx, -20000, 20000) and finite(d.dx, -4000, 4000) and finite(d.dy, -4000, 4000) then
            if d.dx ~= 0 or d.dy ~= 0 then Bench.turn(d.dx, d.dy) end
            Bench.release(d.vx)
        end
    end,
}

RegisterNUICallback('intent', function(data, cb)
    cb({ ok = true })
    local s = session
    if not s or s.closing or type(data) ~= 'table' then return end
    local handler = INTENTS[data.type]
    if handler then handler(s, data) end
end)

-- Where the drawer's part windows are (screen fractions), for the bench to
-- draw each part's model in its window. Only parts of the open slot.
RegisterNUICallback('thumbs', function(data, cb)
    cb({ ok = true })
    local s = session
    if not s or s.closing or type(data) ~= 'table' or data.slot ~= s.focus or type(data.items) ~= 'table' then return end
    local windows = {}
    for i, w in ipairs(data.items) do
        if i > 32 then break end
        if type(w) == 'table' and type(w.id) == 'string' and finite(w.x0, 0, 1) and finite(w.y0, 0, 1) and finite(w.x1, 0, 1)
            and finite(w.y1, 0, 1) and w.x1 > w.x0 and w.y1 > w.y0 then
            local part = R.part(s.name, w.id)
            if part and part.slot == s.focus then
                windows[#windows + 1] = { id = part.component, x0 = w.x0, y0 = w.y0, x1 = w.x1, y1 = w.y1, dim = w.dim == true }
            end
        end
    end
    local c = data.well
    local well = type(c) == 'table' and finite(c[1], 0, 1) and finite(c[2], 0, 1) and finite(c[3], 0, 1) and finite(c[4], 0, 1)
        and c[3] > c[1] and c[4] > c[2] and { c[1], c[2], c[3], c[4] } or nil
    Bench.thumbs(s.focus, windows, well)
end)

RegisterNUICallback('opened', function(_, cb)
    cb({ ok = true })
    if session then session.acked = true end
end)

local function clip(value) return tostring(value):gsub('[%c]', ' '):sub(1, 160) end
RegisterNUICallback('diag', function(data, cb)
    cb({ ok = true })
    if not C.debug or type(data) ~= 'table' then return end
    print(('[%s] page %s %s: focus=%s visibility=%s body=%s classes=%s'):format(RESOURCE, clip(data.stage), clip(data.detail),
        clip(data.focus), clip(data.visibility), clip(data.body), clip(data.classes)))
end)

RegisterNUICallback('ready', function(_, cb)
    nuiReady = true
    send('text', words())
    cb({ ok = true })
end)

-- Server pushes ------------------------------------------------------------------------

RegisterNetEvent(RESOURCE .. ':closed', function(code)
    if session then
        if type(code) == 'string' and code:match('^%u[%u_]*$') then notify('code.' .. code) end
        finish(true)
    end
end)

-- A part item was used: open on its slot, or jump to it if already open.
RegisterNetEvent(RESOURCE .. ':use', function(item)
    local entry = type(item) == 'string' and GunsmithCatalog.items[item]
    if not entry then return end
    local name = session and session.name or Apply.nameFor(GetSelectedPedWeapon(PlayerPedId()))
    if not name or not R.partForItem(name, item) then notify('notify.noFit'); return end
    local part = R.partForItem(name, item)
    if session then
        focus(session, part.slot)
        for i, option in ipairs(session.options or {}) do if option.item == item then moveCursor(session, i) break end end
    else
        open(part.slot, item)
    end
end)

-- Settings (Cortex settings > Gunsmith) -------------------------------------------

local function readPrefs()
    local function read(key, fallback)
        local ok, value = pcall(function() return exports['cortex-lib']:getTabSetting(TAB, key) end)
        if ok and value ~= nil then return value end
        return fallback
    end
    prefs.legend = read('legend', true) ~= false
    prefs.dof = read('dof', C.bench.dof ~= false) ~= false
end

local function registerSettings()
    local rows = {
        { key = 'legend', type = 'toggle', label = L('settings.legend'), description = L('settings.legend.help') },
        { key = 'dof', type = 'toggle', label = L('settings.dof'), description = L('settings.dof.help') },
    }
    pcall(function()
        exports['cortex-lib']:registerSettings(TAB, L('settings.tab'), 'cortex-gunsmith:', rows, { legend = true, dof = C.bench.dof ~= false })
    end)
    readPrefs()
end
AddEventHandler('cortex-lib:settingsChanged', function(tabId) if tabId == TAB then readPrefs() end end)
AddEventHandler('onClientResourceStart', function(name) if name == 'cortex-lib' then registerSettings() end end)
CreateThread(function() Wait(250); registerSettings() end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= RESOURCE or not session then return end
    local s = session
    session = nil
    SetNuiFocus(false, false)
    hideLegend()
    teardown(s, true)
end)

-- Shared with quick.lua (quick swap): the same server round trips, part
-- lists, hand-back and feedback as the bench.
S.kit = { await = await, codeOf = codeOf, notify = notify, sound = sound, rumble = rumble, send = send, optionsFor = optionsFor, fittedId = fittedId,
    nativeClaim = nativeClaim, holsterUse = holsterKit.use, reequip = reequip, blocked = blocked, prefs = prefs,
    benchBusy = function() return session ~= nil or opening end }

exports('open', function() open() end)
exports('close', function() finish(false) end)
exports('isOpen', function() return session ~= nil end)

-- Debug ---------------------------------------------------------------------------

if C.debug then
    RegisterCommand('gunsmith_bones', function()
        if not Bench.isOpen() then print('[cortex-gunsmith] open the bench first'); return end
        for _, line in ipairs(Bench.report()) do print('[cortex-gunsmith]', line) end
    end, false)

    -- Development hooks (dev/bridge_client.lua) read and drive the real paths.
    function S.debugState()
        local s, ped = session, PlayerPedId()
        local p = C.bench.pose
        return {
            open = s ~= nil, opening = opening, nuiReady = nuiReady, nuiFocused = IsNuiFocused(), acked = s and s.acked or false,
            phase = Bench.phase(), name = s and s.name, focus = s and s.focus, cursor = s and s.cursor,
            closing = s and s.closing or false, pending = s and s.pending or false,
            holster = s and s.holster and s.holster.state or nil, reequip = s and s.reequip or nil, slots = s and visibleSlots(s) or nil,
            free = s and s.view.free, adapterHolster = s and s.view.holster,
            posePlaying = p and p.dict and IsEntityPlayingAnim(ped, p.dict, p.clip, 3) or false,
            weapon = GetSelectedPedWeapon(ped), sent = sent, frozen = IsEntityPositionFrozen(ped), camera = Bench.cameraState(),
            handover = Bench.lastHandover, track = lastTrack, handback = lastReturn, weaponEntity = GetCurrentPedWeaponEntityIndex(ped, 0), legend = s and s.legendPx or nil, legendMode = s and s.legendMode or nil,
            weaponVisible = (function()
                local entity = GetCurrentPedWeaponEntityIndex(ped, 0)
                return entity ~= 0 and DoesEntityExist(entity) and IsEntityVisible(entity) or false
            end)(),
        }
    end
    function S.intent(data)
        local s = session
        if not s or s.closing or type(data) ~= 'table' then return false end
        local handler = INTENTS[data.type]
        if not handler then return false end
        handler(s, data)
        return true
    end
    -- The page alone, fed the messages a real Carbine Mk II session sends
    -- (no bench, no focus): proves the Lua -> NUI -> render path in CEF.
    function S.nuiTest(show)
        if session or opening then return false end
        if not show then send('close', {}); return true end
        local name = 'WEAPON_CARBINERIFLE_MK2'
        local s = { name = name, view = { state = R.normalize(name, {}), owned = {}, free = false, holster = true, tint = true, livery = true }, dirty = true }
        sendOpen(s)
        sendState(s)
        return true
    end
end
