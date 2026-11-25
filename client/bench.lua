-- The 3D bench: the weapon floating in front of the player, seen in first
-- person from a camera fixed at their eyes, the key light and every part
-- move. It knows
-- nothing about inventories or the NUI: main.lua tells it what to show and
-- reads back where things are on screen.
--
-- Parts move as proxies: the component's own model, attached to the weapon
-- at the part's attach bone (exactly where the game seats it) and slid along
-- the slot's axis. When a proxy lands, the real component goes on the weapon
-- object and the proxy is dropped a frame later, so nothing ever pops.
local Rig, R, C = GunsmithRig, GunsmithRules, Config
local v, add, sub, scale, dot, cross, unit, length = Rig.v, Rig.add, Rig.sub, Rig.scale, Rig.dot, Rig.cross, Rig.unit, Rig.length
local rotate, qmul, qaxis, qslerp = Rig.rotate, Rig.qmul, Rig.qaxis, Rig.qslerp
local UP, clamp, clamp01, approach = Rig.UP, Rig.clamp, Rig.clamp01, Rig.approach
local rad, sin, cos, tan, abs, max, min, pi, floor = math.rad, math.sin, math.cos, math.tan, math.abs, math.max, math.min, math.pi, math.floor

GunsmithBench = { reduced = false }
local B = GunsmithBench
local bench = nil

local function vec(p) return v(p.x, p.y, p.z) end
local hash = GetHashKey

-- How far a part travels on and off (metres, for a 75 cm rifle; scaled by the
-- weapon's length), and where it waits in the exploded view.
local TRAVEL = { muzzle = 0.11, barrel = 0.13, optic = 0.10, light = 0.09, grip = 0.09, mag = 0.12 }
-- Muzzle devices thread on: two turns over the travel.
local SPIN = { muzzle = 720.0 }
local IN_MS, OUT_MS, EXPLODE_MS, STAGGER_MS, INTRO_MS, OUTRO_MS = 300, 210, 420, 55, 900, 450
-- The particle asset the dry fire's effects come from.
local FX_ASSET = 'core'

-- Reduced motion (Cortex settings): the camera cuts instead of gliding and
-- nothing spins for show. Parts still slide; that is what they do.
local function introMs() return B.reduced and 0 or INTRO_MS end
local function outroMs() return B.reduced and 0 or OUTRO_MS end

local function objectLivery(object, camo, colour) Citizen.InvokeNative(0x5DA825A85D0EA6E6, object, hash(camo), colour) end

-- Assets -------------------------------------------------------------------------

-- A finish's own versions of the parts: the gold finishes swap in a gold
-- magazine, scope, grip, light and suppressor (ExtraComponents in the game's
-- weaponcomponents.meta). While the finish is on, the game draws a part with
-- its version and draws nothing when that model isn't loaded.
local function extras(b, component)
    local list = b.extras[component]
    if list == nil then
        list = {}
        local h = hash(component)
        for i = 0, (GetWeaponComponentVariantExtraComponentCount(h) or 0) - 1 do
            local m = GetWeaponComponentVariantExtraComponentModel(h, i)
            if m and m ~= 0 and IsModelInCdimage(m) then list[#list + 1] = m end
        end
        b.extras[component] = list
    end
    return list
end

-- Returns the model when it is loaded (with a finish's part versions), or nil
-- plus true when the part has no model at all (nothing to stream or slide).
local function model(b, component)
    local m = b.models[component]
    if m == nil then
        m = GetWeaponComponentTypeModel(hash(component))
        m = m ~= 0 and m or false
        b.models[component] = m
    end
    if not m then return nil, true end
    local loaded = HasModelLoaded(m)
    if not loaded then RequestModel(m) end
    for _, extra in ipairs(extras(b, component)) do
        if not HasModelLoaded(extra) then RequestModel(extra); loaded = false end
    end
    if loaded then return m end
    return nil, false
end

local function waitModel(b, component, deadline)
    while true do
        local m, missing = model(b, component)
        if m or missing or GetGameTimer() > deadline then return m end
        Wait(0)
    end
end

-- Part boxes measured from the game's models (client/bounds.lua), by model
-- hash. The box GetModelDimensions reads is off the mesh for some parts, which
-- shrank them in their windows or pushed them out; it is only the fallback.
local MEASURED = {}
for name, box in pairs(GunsmithBounds) do MEASURED[hash(name) & 0xFFFFFFFF] = box end

local function dims(b, m)
    local cached = b.dims[m]
    if not cached then
        local box = MEASURED[m & 0xFFFFFFFF]
        if box then
            cached = { v(box[1], box[2], box[3]), v(box[4], box[5], box[6]) }
        else
            local mins, maxs = GetModelDimensions(m)
            cached = { vec(mins), vec(maxs) }
        end
        b.dims[m] = cached
    end
    return cached[1], cached[2]
end

-- The dark plate behind the part windows (see Part windows): a base-game prop
-- with one flat dark grey texture, and its mesh's box.
local PLATE = { model = hash('prop_airdancer_base'), lo = v(-0.2, -0.203, -0.098), hi = v(0.2, 0.2, 0.188) }

-- Frames ---------------------------------------------------------------------------

local function boneIndex(entity, name)
    if not name then return -1 end
    local index = GetEntityBoneIndexByName(entity, name)
    if index == -1 then index = GetEntityBoneIndexByName(entity, name:lower()) end
    return index
end

-- A bone's position in the weapon's own frame.
local function boneLocal(entity, index)
    if index == -1 then return nil end
    local world = GetWorldPositionOfEntityBone(entity, index)
    return vec(GetOffsetFromEntityGivenWorldCoords(entity, world.x, world.y, world.z))
end

local function axisOf(p)
    if abs(p.x) >= abs(p.y) and abs(p.x) >= abs(p.z) then return 'x' end
    if abs(p.y) >= abs(p.z) then return 'y' end
    return 'z'
end

-- The barrel axis in the weapon's frame, snapped to a model axis. Weapon
-- models are built upright (+Z), so only forward needs finding.
local function barrelAxis(muzzle, mins, maxs)
    if muzzle and (abs(muzzle.x) > 0.02 or abs(muzzle.y) > 0.02) then
        if abs(muzzle.x) >= abs(muzzle.y) then return v(muzzle.x > 0 and 1 or -1, 0, 0) end
        return v(0, muzzle.y > 0 and 1 or -1, 0)
    end
    return (maxs.x - mins.x) >= (maxs.y - mins.y) and v(1, 0, 0) or v(0, 1, 0)
end

-- The direction a slot's part leaves along, in the weapon frame. Top or
-- bottom follows the bone: a top-loading magazine lifts out upwards.
local function slotAxis(b, slot, bone)
    if slot == 'muzzle' or slot == 'barrel' or slot == 'light' then return b.fwdL end
    local sign = slot == 'optic' and 1 or -1
    if bone and b.boreZ then
        local above = dot(bone, b.upL) - b.boreZ
        if abs(above) > 0.015 then sign = above > 0 and 1 or -1 end
    end
    return scale(b.upL, sign)
end

-- Pose ----------------------------------------------------------------------------

-- The weapon's world rotation: the presented base, then the player's pitch
-- and turn, the flourish spin, the click kick and a shot's muzzle rise.
local function orientation(b)
    local q = qmul(qaxis(b.camRight, b.pitch.now + b.kick.x), b.qBase)
    q = qmul(qaxis(UP, b.yaw.now + b.spin.angle), q)
    if b.rise.x == 0 then return q end
    -- About the level line across the barrel: the muzzle climbs.
    return qmul(qaxis(unit(cross(rotate(q, b.fwdL), UP), b.camF), b.rise.x), q)
end

local function centreWorld(b) return add(b.P, scale(b.joltDir, b.jolt.x)) end

local function place(b, centre, q)
    local origin = sub(centre, rotate(q, b.centreL))
    local o, k = b.placed, b.q
    if o and k and abs(o.x - origin.x) + abs(o.y - origin.y) + abs(o.z - origin.z) < 1e-5
        and abs(k.x - q.x) + abs(k.y - q.y) + abs(k.z - q.z) + abs(k.w - q.w) < 1e-6 then return false end
    SetEntityCoordsNoOffset(b.object, origin.x, origin.y, origin.z, false, false, false)
    SetEntityQuaternion(b.object, q.x, q.y, q.z, q.w)
    b.placed, b.q = origin, q
    return true
end

local function toWorld(b, p) return add(b.placed, rotate(b.q, p)) end

-- Components on the weapon object ------------------------------------------------------

local function giveObject(b, component)
    GiveWeaponComponentToWeaponObject(b.object, hash(component))
    local part = R.part(b.name, component)
    if part and part.slide then GiveWeaponComponentToWeaponObject(b.object, hash(part.slide)) end
    local finish = C.debug and b.seats.finish and b.seats.finish.shown
    if finish and part and part.slot ~= 'finish' then
        local list, ready = extras(b, finish), 0
        for _, m in ipairs(list) do if HasModelLoaded(m) then ready = ready + 1 end end
        print(('[cortex-gunsmith] part %s on finish %s: part versions loaded %d/%d, on object %s'):format(
            component, finish, ready, #list, tostring(HasWeaponGotWeaponComponent(b.object, hash(component)))))
    end
end

local function takeObject(b, component)
    if HasWeaponGotWeaponComponent(b.object, hash(component)) then RemoveWeaponComponentFromWeaponObject(b.object, hash(component)) end
    local part = R.part(b.name, component)
    if part and part.slide and HasWeaponGotWeaponComponent(b.object, hash(part.slide)) then
        RemoveWeaponComponentFromWeaponObject(b.object, hash(part.slide))
    end
end

-- Leave at most `keep` on the weapon in this slot.
local function clearSlot(b, slot, keep)
    for _, part in ipairs(R.options(b.name, slot)) do
        if part.component ~= keep then takeObject(b, part.component) end
    end
end

local function dropEntity(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        DetachEntity(entity, false, false)
        SetEntityAsMissionEntity(entity, true, true)
        DeleteEntity(entity)
    end
end

-- Proxies ------------------------------------------------------------------------------

-- A moving copy of one part. from/to are fractions of the slot's travel
-- (0 = seated). opts: easing, alpha = { from, to }, delay, hold (stay when
-- landed), onStart(p) as it appears, done(p) as it lands.
local function proxy(b, seat, component, from, to, duration, opts)
    local m = model(b, component)
    if not m then return nil end
    local bone = boneIndex(b.object, seat.bone)
    local entity = CreateObjectNoOffset(m, b.placed.x, b.placed.y, b.placed.z, false, false, false)
    if entity == 0 then return nil end
    SetEntityCollision(entity, false, false)
    SetEntityAlpha(entity, 0, false)
    AttachEntityToEntity(entity, b.object, bone == -1 and 0 or bone, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
    local p = { entity = entity, component = component, bone = bone == -1 and 0 or bone, from = from, to = to, f = from,
        duration = duration, easing = opts.easing or 'cortex', alpha = opts.alpha or { 255, 255 }, delay = opts.delay or 0,
        hold = opts.hold, onStart = opts.onStart, done = opts.done, spin = SPIN[seat.slot] or 0.0,
        travel = seat.travel, axisL = seat.axisL }
    seat.proxies[#seat.proxies + 1] = p
    return p
end

local function attachAt(b, p, f)
    local off = scale(p.dir, p.travel * f)
    local turn = p.spin * f
    local rx, ry, rz = 0.0, 0.0, 0.0
    if p.spinAxis == 'x' then rx = turn elseif p.spinAxis == 'y' then ry = turn else rz = turn end
    AttachEntityToEntity(p.entity, b.object, p.bone, off.x, off.y, off.z, rx, ry, rz, false, false, false, false, 2, true)
end

-- Restart a proxy towards a new fraction.
local function retarget(p, to, duration, easing, now, delay, alpha)
    p.from, p.to, p.duration, p.easing = p.f, to, duration, easing
    p.startAt, p.started = now + (delay or 0), p.started
    p.alpha = alpha or { 255, 255 }
    p.hold = false
end

-- Returns false once the proxy is gone.
local function stepProxy(b, p, now)
    if p.lingering then dropEntity(p.entity); return false end
    if not p.ready then
        -- The frame after attaching: read the bone's frame off the proxy and
        -- express the slot axis in it, so the slide follows the real seat.
        local origin = GetEntityCoords(p.entity)
        local function axis(x, y, z, fallback)
            return unit(sub(vec(GetOffsetFromEntityInWorldCoords(p.entity, x, y, z)), origin), fallback)
        end
        local ax, ay, az = axis(1.0, 0.0, 0.0, v(1, 0, 0)), axis(0.0, 1.0, 0.0, v(0, 1, 0)), axis(0.0, 0.0, 1.0, v(0, 0, 1))
        local w = rotate(b.q, p.axisL)
        p.dir = v(dot(w, ax), dot(w, ay), dot(w, az))
        p.spinAxis = axisOf(p.dir)
        p.ready, p.startAt = true, now + p.delay
        attachAt(b, p, p.from)
    end
    if now < p.startAt then return true end
    if not p.started then
        p.started = true
        SetEntityAlpha(p.entity, p.alpha[1], false)
        if p.onStart then p.onStart(p) end
    end
    if p.hold and p.f == p.to then return true end
    local t = p.duration > 0 and clamp01((now - p.startAt) / p.duration) or 1
    p.f = p.from + (p.to - p.from) * (Rig.ease[p.easing] or Rig.ease.cortex)(t)
    attachAt(b, p, p.f)
    local a = floor(p.alpha[1] + (p.alpha[2] - p.alpha[1]) * t + 0.5)
    if a >= 255 then ResetEntityAlpha(p.entity) else SetEntityAlpha(p.entity, a, false) end
    if t < 1 then return true end
    p.f = p.to
    local done = p.done
    p.done = nil
    if done then done(p) end
    if p.hold then return true end
    -- The real part is on the weapon now (or the copy has faded): one more frame.
    p.lingering = true
    return true
end

-- Click feedback: the weapon gives along the seat axis, kicks a little and
-- the key light lifts.
local function click(b, axisL, strength)
    strength = strength or 1.0
    b.joltDir = rotate(b.q, axisL)
    b.jolt.vx = b.jolt.vx - 0.16 * strength * b.k
    b.kick.vx = b.kick.vx + rad(38.0) * strength * (abs(dot(axisL, b.fwdL)) > 0.9 and 0.4 or 1.0)
    b.pulse = max(b.pulse, 0.55 * strength)
end

local function wanted(b, slot)
    local component = b.display.parts[slot]
    if component then return component end
    local stock = R.stock(b.name, slot)
    return stock and stock.component or nil
end

local function busy(seat)
    local n = #seat.proxies
    return n > 0 and not (seat.held and n == 1)
end

-- Bring one seat towards what should be shown. One transition at a time per
-- slot; the next frame looks again, so fast browsing coalesces.
local function settle(b, seat, now)
    if busy(seat) then return end
    local target = wanted(b, seat.slot)
    if seat.shown == target then return end
    if target then
        local m, missing = model(b, target)
        if not m and not missing then return end -- still streaming in
        if missing then clearSlot(b, seat.slot, target); giveObject(b, target); seat.shown = target; return end
    end
    local old = seat.shown
    if old then
        if b.exploded and seat.held then
            -- Already off the weapon: the waiting copy drifts out and fades.
            local held = seat.held
            seat.held = nil
            retarget(held, 1.7, OUT_MS, 'in', now, 0, { 255, 0 })
        else
            local p = proxy(b, seat, old, 0, 1.15, OUT_MS, { easing = 'in', alpha = { 255, 0 },
                onStart = function() clearSlot(b, seat.slot, nil) end })
            if not p then clearSlot(b, seat.slot, nil) end
        end
    end
    seat.shown = target
    if not target then return end
    local delay = old and floor(OUT_MS * 0.45) or 0
    if b.exploded then
        seat.held = proxy(b, seat, target, 1.7, 1, IN_MS, { alpha = { 0, 255 }, delay = delay, hold = true })
    else
        local p = proxy(b, seat, target, 1.0, 0, IN_MS, { alpha = { 0, 255 }, delay = delay, done = function()
            clearSlot(b, seat.slot, target)
            giveObject(b, target)
            if seat.slot == 'camo' and b.display.livery then objectLivery(b.object, target, b.display.livery) end
            click(b, seat.axisL, 0.55)
        end })
        if not p then clearSlot(b, seat.slot, target); giveObject(b, target) end
    end
end

-- Finishes are variant models: another model of the whole weapon. The game
-- draws a weapon object with the model it was created with, so giving one a
-- finish records it and keeps the old look. A new finish makes the copy again
-- with the finish's model (CREATE_WEAPON_OBJECT's customModelHash) and carries
-- over its place, the parts on it and the parts sliding against it.
local function remake(b, m)
    local old = b.object
    local pos = b.placed or vec(GetEntityCoords(old))
    local qx, qy, qz, qw
    if b.q then qx, qy, qz, qw = b.q.x, b.q.y, b.q.z, b.q.w else qx, qy, qz, qw = GetEntityQuaternion(old) end
    local object = CreateWeaponObject(b.hash, 0, pos.x, pos.y, pos.z, true, 1.0, m or 0)
    if not object or object == 0 then return false end
    if NetworkGetEntityIsNetworked(object) then NetworkUnregisterNetworkedEntity(object) end
    SetEntityAsMissionEntity(object, true, true)
    SetEntityCollision(object, false, false)
    FreezeEntityPosition(object, true)
    SetEntityCoordsNoOffset(object, pos.x, pos.y, pos.z, false, false, false)
    SetEntityQuaternion(object, qx, qy, qz, qw)
    for _, component in ipairs(R.allComponents(b.name)) do
        local h = hash(component)
        local on, has = HasWeaponGotWeaponComponent(old, h), HasWeaponGotWeaponComponent(object, h)
        if on and not has then GiveWeaponComponentToWeaponObject(object, h)
        elseif has and not on then RemoveWeaponComponentFromWeaponObject(object, h) end
    end
    b.object, b.drawn = object, m
    for _, seat in pairs(b.seats) do
        local bone = boneIndex(object, seat.bone)
        bone = bone == -1 and 0 or bone
        for _, p in ipairs(seat.proxies) do
            p.bone = bone
            if p.ready then attachAt(b, p, p.f)
            else AttachEntityToEntity(p.entity, object, bone, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true) end
        end
    end
    dropEntity(old)
    -- The tint and camo colour go on again with the next applySurface.
    b.shownTint, b.shownLivery, b.shownCamo = nil, nil, nil
    return true
end

-- Show `finish` (nil for none) on the copy; its model must be loaded.
local function dressFinish(b, finish)
    local m = finish and model(b, finish) or nil
    if m ~= b.drawn then
        local made = remake(b, m)
        if C.debug then
            print(('[cortex-gunsmith] finish %s: model %s, remade %s, object model %s'):format(finish or 'none',
                m and ('%08x'):format(m & 0xFFFFFFFF) or 'base', tostring(made), ('%08x'):format(GetEntityModel(b.object) & 0xFFFFFFFF)))
        end
    end
    clearSlot(b, 'finish', finish)
    if finish then giveObject(b, finish) end
end

-- Nothing, or a part whose model is loaded or that has none.
local function streamed(b, component)
    if not component then return true end
    local m, missing = model(b, component)
    return m ~= nil or missing
end

-- Surface slots (finish, camo) swap in place.
local function settleSurface(b, seat)
    local target = wanted(b, seat.slot)
    if seat.shown == target then return end
    if not streamed(b, target) then return end
    if seat.slot == 'finish' then dressFinish(b, target)
    else
        clearSlot(b, seat.slot, target)
        if target then giveObject(b, target) end
    end
    seat.shown = target
end

local function applySurface(b)
    local tint = b.display.tint or 0
    if b.shownTint ~= tint then
        SetWeaponObjectTintIndex(b.object, tint)
        b.shownTint = tint
    end
    local camo = b.seats.camo and b.seats.camo.shown
    local livery = camo and b.display.livery or 0
    if b.shownLivery ~= livery or b.shownCamo ~= camo then
        if camo then objectLivery(b.object, camo, livery) end
        b.shownLivery, b.shownCamo = livery, camo
    end
end

-- Camera helpers ------------------------------------------------------------------------

local function gameplayPose()
    local rot = GetGameplayCamRot(2)
    local pitch, yaw = rad(rot.x), rad(rot.z)
    return vec(GetGameplayCamCoord()), v(-sin(yaw) * cos(pitch), cos(yaw) * cos(pitch), sin(pitch)), GetGameplayCamFov()
end

local function aspect()
    local ratio = GetAspectRatio(false)
    return (type(ratio) == 'number' and ratio > 0.5) and ratio or 16 / 9
end

local function chest(ped) return add(vec(GetEntityCoords(ped)), v(0, 0, 0.45)) end

-- The NUI's columns, in 1080p units (--u follows the screen height): the slot
-- index down the left, the drawer on the right while a slot is open (wider by
-- the rail of part windows on a part slot; Drawer.svelte). `drawer` is the
-- drawer's width or false. Returns the free band's left edge and width as
-- fractions of the screen width.
local INDEX_U, DRAWER_U, RAIL_U, MARGIN_U = 440, 440, 120, 60
local function band(drawer)
    local per = 1 / (1080 * aspect())
    local left = INDEX_U * per
    return left, max(0.3, 1 - left - (drawer or MARGIN_U) * per)
end

-- Camera distance that fits the whole weapon in a band of the screen.
local function fitDistance(b, width)
    return b.length / (2 * tan(rad(b.fov) * 0.5) * aspect() * 0.82 * width)
end

-- Room along a direction, up to `reach` metres.
local function clearance(from, dir, reach, ped)
    local to = add(from, scale(dir, reach))
    local handle = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1 | 2 | 16, ped, 7)
    local _, hit, at = GetShapeTestResult(handle)
    if hit == 1 or hit == true then return length(sub(vec(at), from)) end
    return reach
end

-- The heading (degrees) nearest the player's own with room in front for the
-- weapon at its furthest, or nil when there is none.
function B.room(ped)
    local heading = GetEntityHeading(ped)
    local from = chest(ped)
    local need = 1.5
    for _, turn in ipairs({ 0, 35, -35, 70, -70, 110, -110, 150, -150, 180 }) do
        local dir = Rig.forwardFromHeading(heading + turn)
        if clearance(from, dir, need, ped) >= need and clearance(add(from, v(0, 0, 0.3)), dir, need, ped) >= need then
            return heading + turn
        end
    end
    return nil
end

-- Open / close ------------------------------------------------------------------------

-- Build the bench; yields while assets stream. opts:
--   ped, heading, state (fitted, GunsmithRules shape), focus,
--   handoff = { pos, q } (the weapon in hand: where the flight starts)
function B.open(name, opts)
    if bench then return false, 'BUSY' end
    local weaponHash = hash(name)
    RequestWeaponAsset(weaponHash, 31, 0)
    local deadline = GetGameTimer() + 4000
    while not HasWeaponAssetLoaded(weaponHash) do
        if GetGameTimer() > deadline then return false, 'NOT_READY' end
        Wait(0)
    end
    local ped = opts.ped
    local origin = vec(GetEntityCoords(ped))
    local handoff = opts.handoff
    local start = handoff and handoff.pos or add(origin, v(0, 0, 0.2))
    local object = CreateWeaponObject(weaponHash, 0, start.x, start.y, start.z, true, 1.0, 0)
    if not object or object == 0 then RemoveWeaponAsset(weaponHash); return false, 'NOT_READY' end
    -- The bench copy is for this player's camera only. CREATE_WEAPON_OBJECT has
    -- no network flag; if the game registered it anyway, take it off the network.
    local networked = NetworkGetEntityIsNetworked(object)
    if networked then NetworkUnregisterNetworkedEntity(object) end
    if C.debug then print(('[cortex-gunsmith] bench object networked at creation: %s, now: %s'):format(
        tostring(networked), tostring(NetworkGetEntityIsNetworked(object)))) end
    SetEntityAsMissionEntity(object, true, true)
    SetEntityCollision(object, false, false)
    FreezeEntityPosition(object, true)

    local b = {
        name = name, hash = weaponHash, object = object, ped = ped, models = {}, extras = {}, dims = {}, seats = {},
        display = R.copy(opts.state), exploded = false, phase = 'intro', focus = nil,
        yaw = { now = 0.0, target = 0.0 }, pitch = { now = 0.0, target = 0.0 }, zoom = { now = 1.0, target = 1.0 },
        spin = { angle = 0.0 }, jolt = { x = 0.0, vx = 0.0 }, kick = { x = 0.0, vx = 0.0 }, pulse = 0.0,
        rise = { x = 0.0, vx = 0.0 }, fling = nil, flash = nil, firedAt = 0, beam = 0.0,
        joltDir = v(0, 0, 0), drawer = false, fov = C.bench.fov + 0.0, thumbs = {},
        group = GunsmithCatalog.weapons[name].group,
    }

    -- Measure the weapon in its own frame.
    SetEntityQuaternion(object, 0.0, 0.0, 0.0, 1.0)
    local mins, maxs = GetModelDimensions(GetEntityModel(object))
    mins, maxs = vec(mins), vec(maxs)
    local muzzle = boneLocal(object, boneIndex(object, 'Gun_Muzzle'))
    b.fwdL, b.upL = barrelAxis(muzzle, mins, maxs), v(0, 0, 1)
    b.boreZ = muzzle and muzzle.z or nil
    b.muzzleL = muzzle
    b.centreL, b.boundsL = scale(add(mins, maxs), 0.5), { mins, maxs }
    b.length = max(0.2, abs(dot(sub(maxs, mins), b.fwdL)))
    b.k = clamp(b.length / 0.75, 0.55, 1.4)

    -- First person: the camera is your eyes, fixed for the whole session,
    -- looking ahead and a little down. The weapon floats in front of them.
    -- The eyes are found from the root and the head's height, so a heading
    -- set this frame (bones not yet updated) can't skew them.
    local heading = opts.heading or GetEntityHeading(ped)
    local forward = Rig.forwardFromHeading(heading)
    local head = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0)
    local eyeZ = head.z > origin.z + 0.3 and head.z + 0.06 or origin.z + 0.72
    b.eye = add(v(origin.x, origin.y, eyeZ), scale(forward, 0.13))
    local tilt = rad(C.bench.lookDown or 12.0)
    b.camF = unit(v(forward.x * cos(tilt), forward.y * cos(tilt), -sin(tilt)))
    b.camRight = unit(cross(b.camF, UP))
    -- Barrel along the screen to the right, top up: the ejection side faces you.
    b.qBase = Rig.qalign(b.fwdL, b.upL, b.camRight, UP)
    local left, width = band(false)
    b.d, b.cx, b.off = fitDistance(b, width), left + width * 0.5, v(0, 0, 0)
    b.P = add(b.eye, scale(b.camF, b.d))

    -- One seat per slot this weapon has a part for.
    for _, slot in ipairs(R.SLOTS) do
        local options = R.options(name, slot)
        if #options > 0 then
            local bone = options[1].bone
            local boneL = boneLocal(object, boneIndex(object, bone))
            local seat = { slot = slot, bone = bone, boneL = boneL, proxies = {}, surface = R.SURFACE[slot] == true,
                travel = (TRAVEL[slot] or 0.1) * b.k }
            seat.axisL = slotAxis(b, slot, boneL)
            b.seats[slot] = seat
        end
    end

    -- The dry fire's flash, smoke and case.
    RequestNamedPtfxAsset(FX_ASSET)

    -- Stream every part now so browsing never waits, and dress the weapon.
    for _, part in ipairs(GunsmithCatalog.weapons[name].parts) do model(b, part.component) end
    RequestModel(PLATE.model)
    local wantedSet = {}
    for _, component in ipairs(R.components(name, b.display)) do wantedSet[component] = true end
    for _, component in ipairs(R.allComponents(name)) do
        if not wantedSet[component] and HasWeaponGotWeaponComponent(object, hash(component)) then
            RemoveWeaponComponentFromWeaponObject(object, hash(component))
        end
    end
    deadline = GetGameTimer() + 2500
    for _, slot in ipairs(R.SLOTS) do
        local seat = b.seats[slot]
        if seat then
            local component = wanted(b, slot)
            if component then waitModel(b, component, deadline) end
            if slot == 'finish' then
                if streamed(b, component) then dressFinish(b, component) else component = false end
            elseif component then giveObject(b, component) end
            seat.shown = component
        end
    end
    applySurface(b)

    -- The camera starts exactly where the gameplay camera is.
    local g0, d0, fov0 = gameplayPose()
    b.cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', g0.x, g0.y, g0.z, 0.0, 0.0, 0.0, fov0 + 0.0, false, 2)
    local q0 = handoff and handoff.q or b.qBase
    b.intro = { startAt = GetGameTimer(), q0 = q0, c0 = add(start, rotate(q0, b.centreL)), g0 = g0, d0 = d0, fov0 = fov0 }
    place(b, b.intro.c0, q0)
    SetCamActive(b.cam, true)
    RenderScriptCams(true, false, 0, true, true)
    if C.bench.dof then
        SetCamUseShallowDofMode(b.cam, true)
        SetCamDofStrength(b.cam, 1.0)
    end
    bench = b
    B.setFocus(opts.focus)
    return true
end

function B.isOpen() return bench ~= nil end
function B.phase() return bench and bench.phase or nil end

-- Fly the weapon back to `target` ({ pos, q }: the hand) and the camera back
-- to the gameplay camera. `track()` returns the real weapon's { pos, q } once
-- it is back in your hand: the flight follows it and lands exactly on it, and
-- the bench waits (briefly) for it, so the copy can hand over in one frame.
-- B.phase() reads 'done' when both have landed. `track()` returning nil, true
-- means the weapon isn't coming (the hand-back failed): stop waiting at once.
local HANDOVER_MS = 350
function B.close(target, track)
    local b = bench
    if not b or b.phase == 'outro' or b.phase == 'done' then return end
    if b.exploded then B.explode(false) end
    b.phase, b.fling = 'outro', nil
    b.outro = { startAt = GetGameTimer(), track = track, hand = target and target.pos, q1 = target and target.q or b.q,
        c0 = add(b.placed, rotate(b.q, b.centreL)), q0 = b.q, camPos = b.camPos or b.intro.g0, camDir = b.camDir or b.intro.d0,
        fov0 = b.fovNow or b.intro.fov0 }
end

-- Tear everything down at once (death, resource stop, the end of the outro).
function B.destroy()
    local b = bench
    if not b then return end
    bench = nil
    for _, t in pairs(b.thumbs) do dropEntity(t.entity) end
    b.thumbs = {}
    dropEntity(b.plate)
    for _, seat in pairs(b.seats) do
        for _, p in ipairs(seat.proxies) do dropEntity(p.entity) end
        seat.proxies = {}
    end
    dropEntity(b.object)
    RenderScriptCams(false, false, 0, true, true)
    if b.cam then DestroyCam(b.cam, false) end
    for _, m in pairs(b.models) do if m then SetModelAsNoLongerNeeded(m) end end
    for _, list in pairs(b.extras) do for _, m in ipairs(list) do SetModelAsNoLongerNeeded(m) end end
    SetModelAsNoLongerNeeded(PLATE.model)
    RemoveWeaponAsset(b.hash)
end

-- Controls ------------------------------------------------------------------------------

-- Turns that present a slot to the camera (degrees: yaw, pitch). Negative yaw
-- swings the muzzle towards you; pitch tips the slot's side up. Kept small:
-- the whole weapon stays in view, and a big swing stretches its near end.
local PRESENT = { muzzle = { -16, 4 }, barrel = { -10, 4 }, optic = { -8, 24 }, light = { -8, 0 },
    grip = { -10, 24 }, mag = { -8, 20 } }
local VERTICAL = { optic = true, grip = true, mag = true }

local function wrap(a) return (a + pi) % (2 * pi) - pi end

function B.setFocus(slot)
    local b = bench
    if not b then return end
    local seat = b.seats[slot or '']
    b.focus = seat and slot or nil
    local preset = seat and not seat.surface and PRESENT[slot]
    if preset then
        local pitch = preset[2]
        if VERTICAL[slot] then pitch = abs(pitch) * (dot(seat.axisL, b.upL) >= 0 and 1 or -1) end
        b.yaw.target, b.pitch.target = rad(preset[1]), rad(pitch)
    else
        b.yaw.target, b.pitch.target = 0.0, 0.0
    end
    -- Unwind whole turns so the weapon takes the short way back.
    b.yaw.now = wrap(b.yaw.now)
    b.fling = nil
    b.zoom.target = 1.0
end

-- The options drawer covers the right of the screen: frame the weapon left of
-- it. `rail`: the drawer carries part pictures (any slot but tint and colour).
function B.drawer(open, rail)
    if not bench then return end
    bench.drawer = open == true and DRAWER_U + (rail and RAIL_U or 0) or false
    if not open then B.thumbs(nil, {}) end
end

local function turnSpeed() return rad(0.32) * (C.bench.turnSpeed or 1.0) end

function B.turn(dx, dy)
    local b = bench
    if not b or b.phase ~= 'idle' then return end
    local speed = turnSpeed()
    b.yaw.target = b.yaw.target + dx * speed
    b.pitch.target = clamp(b.pitch.target + dy * speed, rad(-70), rad(70))
end

-- Fling: let go of a drag while it moves and the weapon keeps turning,
-- slowing to a stop; take hold again to catch it. A turn arriving late
-- (the page batches them) only adds to it. `vx`: the drag's speed as
-- it let go (1080p pixels a second). Reduced motion doesn't coast.
local FLING_MIN, FLING_MAX, FLING_FRICTION, FLING_STOP = rad(90.0), rad(1080.0), 2.4, rad(6.0)
function B.grab() if bench then bench.fling = nil end end

function B.release(vx)
    local b = bench
    if not b or b.phase ~= 'idle' or B.reduced then return end
    local speed = vx * turnSpeed()
    b.fling = abs(speed) >= FLING_MIN and clamp(speed, -FLING_MAX, FLING_MAX) or nil
end

function B.zoom(steps)
    local b = bench
    if b then b.zoom.target = clamp(b.zoom.target * (1 - steps * 0.12), 0.42, 1.45) end
end

function B.resetView() if bench then B.setFocus(bench.focus) end end

-- Show this state: fitted parts plus whatever is being previewed. Parts
-- slide on and off to match it; `instant` dresses the weapon at once.
function B.show(state, instant)
    local b = bench
    if not b then return end
    b.display = R.copy(state)
    if not instant then return end
    for _, slot in ipairs(R.SLOTS) do
        local seat = b.seats[slot]
        if seat then
            for _, p in ipairs(seat.proxies) do dropEntity(p.entity) end
            seat.proxies, seat.held = {}, nil
            local target = wanted(b, slot)
            if slot == 'finish' then
                -- A finish still streaming in goes on when it lands (settleSurface).
                if streamed(b, target) then dressFinish(b, target) else target = false end
            else
                clearSlot(b, slot, target)
                if target then giveObject(b, target) end
            end
            seat.shown = target
        end
    end
    -- The camo was given again: its colour goes back on too.
    b.shownLivery, b.shownCamo = nil, nil
    applySurface(b)
end

-- A turntable turn back round to the front; `swap` runs when the back of the
-- weapon faces you, so a new finish is revealed rather than switched.
function B.flourish(swap)
    local b = bench
    if not b then return end
    if b.spin.swap then b.spin.swap() end
    if B.reduced then if swap then swap() end; return end
    local from = b.spin.angle % (2 * pi)
    b.spin = { angle = from, from = from, startAt = GetGameTimer(), duration = 820, swap = swap }
end

-- A committed change: a firm click on the slot's axis.
function B.seated(slot)
    local b = bench
    if not b or not b.q then return end
    local seat = b.seats[slot or '']
    click(b, seat and not seat.surface and seat.axisL or b.upL, 1.0)
end

-- Every mechanical part steps out along its axis, staggered; again to reassemble.
function B.explode(on)
    local b = bench
    if not b or b.exploded == on or b.phase ~= 'idle' and on then return end
    b.exploded = on
    local now, i = GetGameTimer(), 0
    for _, slot in ipairs(R.SLOTS) do
        local seat = b.seats[slot]
        if seat and not seat.surface and seat.shown then
            local delay = i * STAGGER_MS
            i = i + 1
            local component = seat.shown
            if on then
                -- Land any slide first: the exploded copy starts seated.
                for _, p in ipairs(seat.proxies) do dropEntity(p.entity) end
                seat.proxies = {}
                clearSlot(b, slot, component)
                giveObject(b, component)
                seat.held = proxy(b, seat, component, 0, 1, EXPLODE_MS, { hold = true, delay = delay,
                    onStart = function() takeObject(b, component) end })
            elseif seat.held then
                local p = seat.held
                seat.held = nil
                retarget(p, 0, EXPLODE_MS - 60, 'cortex', now, delay)
                p.done = function()
                    clearSlot(b, slot, component)
                    giveObject(b, component)
                    if slot == 'camo' and b.display.livery then objectLivery(b.object, component, b.display.livery) end
                    click(b, seat.axisL, 0.45)
                    local sound = C.sounds.navigate
                    if sound then PlaySoundFrontend(-1, sound[1], sound[2], true) end
                end
            end
        end
    end
end

function B.isExploded() return bench ~= nil and bench.exploded end

-- Dry fire ------------------------------------------------------------------------------
-- A blank, for show: the muzzle flashes (hardly at all through a
-- suppressor), smoke drifts off it, a case flies from the action and the
-- weapon kicks back and climbs. No bullet, and nobody else sees or hears it:
-- the effects are on this screen only. Effect names differ by weapon type;
-- each list is tried in order until the game starts one. rise: how far the
-- muzzle climbs (degrees).
local FIRE = {
    pistol = { flash = { 'muz_pistol' }, shell = { 'eject_pistol' }, rise = 9.0 },
    smg = { flash = { 'muz_smg', 'muz_pistol' }, shell = { 'eject_smg', 'eject_pistol' }, rise = 5.0 },
    rifle = { flash = { 'muz_assault_rifle' }, shell = { 'eject_auto' }, rise = 6.0 },
    mg = { flash = { 'muz_mg', 'muz_assault_rifle' }, shell = { 'eject_mg', 'eject_auto' }, rise = 6.0 },
    shotgun = { flash = { 'muz_shotgun', 'muz_assault_rifle' }, shell = { 'eject_shotgun', 'eject_auto' }, rise = 12.0 },
    sniper = { flash = { 'muz_sniper', 'muz_assault_rifle' }, shell = { 'eject_sniper', 'eject_auto' }, rise = 11.0 },
}
local SMOKE = { 'muz_smoking_barrel' }
local FIRE_GAP_MS, FLASH_MS = 140, 60
-- The climb's spring, and the start speed that peaks at one unit.
local RISE_STIFFNESS = 140.0
local RISE_PEAK = math.sqrt(RISE_STIFFNESS) * math.exp(1)
local started = {} -- per effect list: the name the game had

local function play(b, list, at, rot, size)
    local known = started[list]
    for i = 0, #list do
        local name = i == 0 and known or list[i]
        if name and (i == 0 or name ~= known) then
            UseParticleFxAsset(FX_ASSET)
            if StartParticleFxNonLoopedOnEntity(name, b.object, at.x, at.y, at.z, rot.x, rot.y, rot.z, size + 0.0, false, false, false) then
                started[list] = name
                return true
            end
        end
    end
    return false
end

-- Effects play along their own +X, as they do on a weapon's muzzle bone:
-- turn that onto the barrel.
local function alongBarrel(b)
    local f = b.fwdL
    if abs(f.x) >= abs(f.y) then return v(0, 0, f.x >= 0 and 0 or 180) end
    return v(0, 0, f.y >= 0 and 90 or -90)
end

-- The end of the barrel, or of the device on it.
local function muzzleTip(b)
    local tip = b.muzzleL or add(b.centreL, scale(b.fwdL, b.length * 0.5))
    local seat = b.seats.muzzle
    local m = seat and seat.shown and seat.boneL and b.models[seat.shown]
    if m then
        local device = add(seat.boneL, scale(b.fwdL, Rig.reach(dims(b, m))))
        if dot(device, b.fwdL) > dot(tip, b.fwdL) then tip = device end
    end
    return tip
end

-- Where the case leaves: the action, just ahead of the middle, a little
-- above the bore.
local function ejectPort(b)
    local top = dot(b.boundsL[2], b.upL)
    local bore = b.boreZ or dot(b.centreL, b.upL)
    local p = add(b.centreL, scale(b.fwdL, b.length * 0.08))
    return add(sub(p, scale(b.upL, dot(p, b.upL))), scale(b.upL, bore + (top - bore) * 0.4))
end

-- Returns true when it fired.
function B.fire()
    local b = bench
    local kind = b and C.bench.fire ~= false and FIRE[b.group]
    if not kind or b.phase ~= 'idle' or b.exploded or not b.placed then return false end
    local now = GetGameTimer()
    if now - b.firedAt < FIRE_GAP_MS then return false end
    b.firedAt = now
    local seat = b.seats.muzzle
    local quiet = seat ~= nil and seat.shown ~= nil and seat.shown:find('_SUPP', 1, true) ~= nil
    local tip, rot = muzzleTip(b), alongBarrel(b)
    if HasNamedPtfxAssetLoaded(FX_ASSET) then
        play(b, kind.flash, tip, rot, quiet and 0.3 or 1.0)
        play(b, SMOKE, tip, rot, quiet and 1.2 or 0.8)
        play(b, kind.shell, ejectPort(b), rot, 1.0)
    else
        RequestNamedPtfxAsset(FX_ASSET)
    end
    if not quiet then b.flash = { at = tip, untilAt = now + FLASH_MS } end
    -- The kick: back along the barrel, the muzzle climbing, the light lifting.
    b.joltDir = rotate(b.q, b.fwdL)
    b.jolt.vx = b.jolt.vx - 1.4 * b.k
    b.rise.vx = b.rise.vx + rad(kind.rise * (quiet and 0.85 or 1.0)) * RISE_PEAK
    b.pulse = max(b.pulse, quiet and 0.1 or 0.35)
    return true
end

function B.canFire() return bench ~= nil and C.bench.fire ~= false and FIRE[bench.group] ~= nil end

-- The flash lights the weapon and the street for a moment.
local function flash(b, now)
    local f = b.flash
    if not f then return end
    if now >= f.untilAt then b.flash = nil; return end
    local p = toWorld(b, add(f.at, scale(b.fwdL, 0.04 * b.k)))
    DrawLightWithRange(p.x, p.y, p.z, 255, 178, 92, 4.0, 9.0 * (f.untilAt - now) / FLASH_MS)
end

-- Flashlight ----------------------------------------------------------------------------
-- A flashlight on the weapon is switched on: a beam from its lens down the
-- barrel and out into the street, and the lens itself lit. On while it sits
-- seated (not sliding on or off, not stripped down) on an open bench.
local BEAM = { range = 25.0, brightness = 9.0, hardness = 0.15, angle = 20.0, falloff = 30.0, colour = { 255, 246, 232 } }

local function beam(b, dt)
    local seat = b.seats.light
    local on = C.bench.beam ~= false and b.phase == 'idle' and seat ~= nil and seat.shown ~= nil and #seat.proxies == 0 and not b.exploded
    if on and b.lensFor ~= seat.shown then
        local m = b.models[seat.shown]
        b.lensL = add(seat.boneL or b.centreL, scale(b.fwdL, (m and Rig.reach(dims(b, m)) or 0.0) + 0.005))
        -- Measured again once a model still streaming in has arrived.
        if not m or HasModelLoaded(m) then b.lensFor = seat.shown end
    end
    b.beam = b.beam + ((on and 1 or 0) - b.beam) * approach(on and 16.0 or 22.0, dt)
    if b.beam < 0.01 or not b.lensL then b.beam = on and b.beam or 0.0; return end
    local o, d, c, k = toWorld(b, b.lensL), rotate(b.q, b.fwdL), BEAM.colour, b.beam
    DrawSpotLight(o.x, o.y, o.z, d.x, d.y, d.z, c[1], c[2], c[3], BEAM.range, BEAM.brightness * k, BEAM.hardness, BEAM.angle, BEAM.falloff)
    local g = add(o, scale(d, 0.02))
    DrawLightWithRange(g.x, g.y, g.z, c[1], c[2], c[3], 0.18, 2.0 * k)
end

-- Part windows ------------------------------------------------------------------------
-- Each option of an open part slot has a window cut into the drawer beside
-- its row. The part's own model is drawn in it: a copy held just in front of
-- the camera, scaled down to fit the window, turned three-quarters (still:
-- there is nothing to watch) and lit by a small light of its own. Behind the windows sits one flat backing, so a part
-- never shows against the street. The NUI reports where the windows and
-- their column are (screen fractions), and cuts the windows only once this
-- side has them. A part not carried is lit low: entity alpha would draw it
-- dithered.
--
-- The backing is drawn after the game's depth of field and edge smoothing,
-- so on its own those still found the street behind each part and mixed it
-- into the part's edges: trees showed as green rims, and every leaf or car
-- that moved behind made the edges shimmer. A dark grey prop pressed flat
-- just behind the backing is what the game sees there instead: a still, dark
-- ground. The backing hides its face. Its box is the mesh's, measured; its
-- corners are rounded (about 8% of each side), so it reaches past the column
-- into the panel's padding (UI units, as the page's --u).

local THUMB_DEPTH, WELL_DEPTH, TURN = 0.3, 0.38, rad(-18.0)
local WELL = { 29, 30, 32 }
local PLATE_DEPTH, PLATE_THICK, PLATE_PAD = 0.39, 0.004, { left = 20, right = 40, y = 20 }

-- windows: { { id = component, x0, y0, x1, y1, dim } }; well: { x0, y0, x1, y1 }
-- (the windows' column) or nil; slot nil clears.
function B.thumbs(slot, windows, well)
    local b = bench
    if not b then return end
    if slot ~= b.thumbSlot then
        for _, t in pairs(b.thumbs) do dropEntity(t.entity) end
        b.thumbs, b.thumbSlot = {}, slot
    end
    b.well = slot and well or nil
    if not slot then return end
    local seen = {}
    for _, w in ipairs(windows) do
        local t = b.thumbs[w.id]
        if not t then
            local m = model(b, w.id)
            local entity = m and CreateObjectNoOffset(m, b.eye.x, b.eye.y, b.eye.z, false, false, false) or 0
            if entity ~= 0 then
                SetEntityCollision(entity, false, false)
                FreezeEntityPosition(entity, true)
                SetEntityVisible(entity, false, false)
                t = { entity = entity, box = Rig.windowBox(dims(b, m)), shown = false }
                b.thumbs[w.id] = t
            end
        end
        if t then t.rect, t.dim = { w.x0, w.y0, w.x1, w.y1 }, w.dim == true; seen[w.id] = true end
    end
    -- Scrolled out of view: kept, but hidden until its window comes back.
    for id, t in pairs(b.thumbs) do if not seen[id] then t.rect = nil end end
end

-- A flat quad, both windings (a poly is drawn from one side only).
local function quad(a, b, c, d, col)
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, col[1], col[2], col[3], 255)
    DrawPoly(a.x, a.y, a.z, c.x, c.y, c.z, d.x, d.y, d.z, col[1], col[2], col[3], 255)
    DrawPoly(c.x, c.y, c.z, b.x, b.y, b.z, a.x, a.y, a.z, col[1], col[2], col[3], 255)
    DrawPoly(d.x, d.y, d.z, c.x, c.y, c.z, a.x, a.y, a.z, col[1], col[2], col[3], 255)
end

-- The plate behind the column (well), or hidden without one.
local function placePlate(b, cam, tanV, ratio, well)
    local e = b.plate
    if not well then
        if e and b.plateShown then SetEntityVisible(e, false, false); b.plateShown = false end
        return
    end
    if not e then
        if not HasModelLoaded(PLATE.model) then RequestModel(PLATE.model); return end
        e = CreateObjectNoOffset(PLATE.model, b.eye.x, b.eye.y, b.eye.z, false, false, false)
        if e == 0 then return end
        SetEntityCollision(e, false, false)
        FreezeEntityPosition(e, true)
        b.plate, b.plateShown = e, true
    end
    local ux, uy = 1 / (1080 * ratio), 1 / 1080
    local rect = { well[1] - PLATE_PAD.left * ux, well[2] - PLATE_PAD.y * uy, well[3] + PLATE_PAD.right * ux, well[4] + PLATE_PAD.y * uy }
    local x, y, z, origin = Rig.flatPose(cam, tanV, ratio, rect, PLATE_DEPTH, PLATE_THICK, PLATE.lo, PLATE.hi)
    SetEntityMatrix(e, y.x, y.y, y.z, x.x, x.y, x.z, z.x, z.y, z.z, origin.x, origin.y, origin.z)
    if not b.plateShown then SetEntityVisible(e, true, false); b.plateShown = true end
end

local function placeThumbs(b)
    local well = b.phase == 'idle' and b.well
    if not well and not next(b.thumbs) and not b.plateShown then return end
    local r = unit(cross(b.camDir, UP), b.camRight)
    local cam = { pos = b.camPos, dir = b.camDir, right = r, up = cross(r, b.camDir) }
    local tanV, ratio = tan(rad(b.fovNow) * 0.5), aspect()
    placePlate(b, cam, tanV, ratio, well)
    if well then
        -- A few pixels larger than the windows' column: the NUI panel covers
        -- the edges (and shows them only faintly; it isn't quite opaque).
        local function at(fx, fy) return Rig.screenPoint(cam, tanV, ratio, fx, fy, WELL_DEPTH) end
        local x0, y0, x1, y1 = well[1] - 0.003, well[2] - 0.006, well[3] + 0.003, well[4] + 0.006
        quad(at(x0, y0), at(x1, y0), at(x1, y1), at(x0, y1), WELL)
    end
    local L = C.bench.light
    local glow = L and L.enabled and tonumber(L.parts) or 0
    for _, t in pairs(b.thumbs) do
        local rect = b.phase == 'idle' and t.rect
        if not rect then
            if t.shown ~= false then SetEntityVisible(t.entity, false, false); t.shown = false end
        else
            local q, s, origin = Rig.windowPose(cam, tanV, ratio, rect, THUMB_DEPTH, t.box, TURN)
            t.scale, t.q, t.origin = s, q, origin
            local x, y, k = scale(rotate(q, v(1, 0, 0)), s), scale(rotate(q, v(0, 1, 0)), s), scale(rotate(q, UP), s)
            -- The entity matrix carries the scale; it is set again every frame.
            SetEntityMatrix(t.entity, y.x, y.y, y.z, x.x, x.y, x.z, k.x, k.y, k.z, origin.x, origin.y, origin.z)
            if t.shown ~= true then SetEntityVisible(t.entity, true, false); t.shown = true end
            if glow > 0 then
                -- Just in front of the part, up and to the left; its reach
                -- stops short of the backing.
                local p = Rig.screenPoint(cam, tanV, ratio, (rect[1] + rect[3]) * 0.5, (rect[2] + rect[4]) * 0.5, THUMB_DEPTH - 0.07)
                p = add(add(p, scale(cam.up, 0.025)), scale(cam.right, -0.015))
                local c = L.colour
                DrawLightWithRange(p.x, p.y, p.z, floor(c[1]), floor(c[2]), floor(c[3]), 0.12, glow * (t.dim and 0.35 or 1.0) + 0.0)
            end
        end
    end
end
-- Frame ---------------------------------------------------------------------------------

local function setCamera(b, pos, dir, fov)
    local rot = Rig.lookRotation(dir)
    SetCamCoord(b.cam, pos.x, pos.y, pos.z)
    SetCamRot(b.cam, rot.x, 0.0, rot.z, 2)
    SetCamFov(b.cam, fov + 0.0)
    b.camPos, b.camDir, b.fovNow = pos, dir, fov
end

-- clear (0..1) opens the focus until nothing is blurred: the blur fades in
-- with the intro and out with the close, instead of switching at the ends.
local function dof(b, focusAt, clear)
    if not C.bench.dof then return end
    SetUseHiDof()
    local near = max(0.05, focusAt - 0.22 * b.k)
    -- Keep the part windows and their backing sharp: they sit nearer than
    -- the weapon.
    if b.well or next(b.thumbs) then near = min(near, 0.22) end
    SetCamNearDof(b.cam, near * (1 - clear))
    SetCamFarDof(b.cam, focusAt + 0.3 * b.k + clear * clear * 200.0)
end

local function light(b)
    local L = C.bench.light
    if not L or not L.enabled or not b.camPos then return end
    local key = add(add(b.camPos, scale(UP, 0.42)), scale(b.camRight, -0.28))
    local c = L.colour
    DrawLightWithRange(key.x, key.y, key.z, floor(c[1]), floor(c[2]), floor(c[3]), L.range + 0.0, L.intensity * (1.0 + b.pulse) + 0.0)
end

-- Where a seat's part is: its model's centre at the seat (approximate: the
-- model's bounds taken in the weapon frame), or the attach point when the
-- slot is empty. Exploded parts are where they wait.
local function anchorLocal(b, seat)
    local base = seat.boneL or b.centreL
    local m = seat.shown and b.models[seat.shown]
    if m then
        local mins, maxs = dims(b, m)
        base = add(base, scale(add(mins, maxs), 0.5))
    end
    local held = seat.held
    if held and held.ready then base = add(base, scale(seat.axisL, held.f * seat.travel)) end
    return base
end

-- Advance one frame. Returns true when something on screen moved.
function B.frame(now, dt)
    local b = bench
    if not b then return false end
    local a = approach(12.0, dt)
    local turning = abs(b.yaw.target - b.yaw.now) > 1e-4 or abs(b.pitch.target - b.pitch.now) > 1e-4
    b.yaw.now = b.yaw.now + (b.yaw.target - b.yaw.now) * a
    b.pitch.now = b.pitch.now + (b.pitch.target - b.pitch.now) * a
    b.zoom.now = b.zoom.now + (b.zoom.target - b.zoom.now) * approach(10.0, dt)
    Rig.spring(b.jolt, 260.0, dt)
    Rig.spring(b.kick, 190.0, dt)
    Rig.spring(b.rise, RISE_STIFFNESS, dt)
    if b.fling then
        local speed, went = Rig.coast(b.fling, FLING_FRICTION, min(dt, 0.1), FLING_STOP)
        b.yaw.target = b.yaw.target + went
        b.fling = speed ~= 0 and speed or nil
    end
    b.pulse = b.pulse > 0.002 and b.pulse * (1 - approach(7.0, dt)) or 0.0
    local spin = b.spin
    if spin.startAt then
        local t = clamp01((now - spin.startAt) / spin.duration)
        spin.angle = spin.from + (2 * pi - spin.from) * Rig.ease.inOut(t)
        if spin.swap and t >= 0.5 then local swap = spin.swap; spin.swap = nil; swap() end
        if t >= 1 then b.spin = { angle = 0.0 } end
    end

    -- Framing. The camera is your eyes and never moves; the weapon does. It
    -- floats far enough out that the whole of it fits the free band between
    -- the NUI columns, centred in that band; an open part is marked, not
    -- zoomed to. Zooming in brings the weapon closer and slides the open part
    -- towards the middle, all the way by 60% zoom.
    local left, width = band(b.drawer)
    local seat = b.seats[b.focus or '']
    local lean = seat and not seat.surface and clamp01((1 - b.zoom.now) / 0.4) or 0
    b.d = b.d + (fitDistance(b, width) * b.zoom.now - b.d) * approach(9.0, dt)
    b.cx = b.cx + (left + width * 0.5 - b.cx) * approach(8.0, dt)
    local aim = lean > 0 and scale(rotate(orientation(b), sub(anchorLocal(b, seat), b.centreL)), lean) or v(0, 0, 0)
    b.off = Rig.lerp(b.off, aim, approach(10.0, dt))
    local pan = (1 - 2 * b.cx) * b.d * tan(rad(b.fov) * 0.5) * aspect()
    b.P = sub(add(add(b.eye, scale(b.camF, b.d)), scale(b.camRight, -pan)), b.off)

    local q, centre
    if b.phase == 'intro' then
        local t = Rig.progress(now, b.intro.startAt, introMs(), 'cortex')
        q = qslerp(b.intro.q0, orientation(b), t)
        centre = add(Rig.lerp(b.intro.c0, centreWorld(b), t), scale(UP, 0.07 * sin(pi * t)))
        if t >= 1 then b.phase = 'idle' end
    elseif b.phase == 'outro' or b.phase == 'done' then
        local o = b.outro
        local t = Rig.progress(now, o.startAt, outroMs(), 'inOut')
        local live, gone
        if o.track then live, gone = o.track() end
        if live then o.hand, o.q1 = live.pos, live.q or o.q1 end
        local hand = o.hand or add(vec(GetEntityCoords(b.ped)), v(0, 0, 0.1))
        q = qslerp(o.q0, o.q1, t)
        centre = add(Rig.lerp(o.c0, add(hand, rotate(o.q1, b.centreL)), t), scale(UP, 0.05 * sin(pi * t)))
        if t >= 1 and (live or gone or not o.track or now - o.startAt > outroMs() + HANDOVER_MS) then
            b.phase = 'done'
            B.lastHandover = { by = live and 'weapon' or gone and 'gone' or (o.track and 'timeout' or 'untracked'), ms = now - o.startAt }
        end
    else
        q, centre = orientation(b), centreWorld(b)
    end
    local moved = place(b, centre, q) or turning

    for _, slot in ipairs(R.SLOTS) do
        local seat = b.seats[slot]
        if seat then
            local keep = {}
            for _, p in ipairs(seat.proxies) do
                if stepProxy(b, p, now) then
                    keep[#keep + 1] = p
                    if p.ready and p.f ~= p.to then moved = true end
                elseif seat.held == p then
                    seat.held = nil
                end
            end
            seat.proxies = keep
            if b.phase == 'idle' or b.phase == 'intro' then
                if not seat.surface then settle(b, seat, now) elseif not b.spin.swap then settleSurface(b, seat) end
            end
        end
    end
    if not b.spin.swap then applySurface(b) end

    -- Camera: glides from the gameplay camera into your eyes, and back out;
    -- the blur comes and goes with it.
    local pos, dir, fov, clear = b.eye, b.camF, b.fov, 0
    if b.phase == 'intro' then
        local t = Rig.progress(now, b.intro.startAt, introMs(), 'cortex')
        pos, dir = Rig.lerp(b.intro.g0, pos, t), Rig.blendDir(b.intro.d0, dir, t)
        fov = b.intro.fov0 + (b.fov - b.intro.fov0) * t
        clear = 1 - t
    elseif b.phase == 'outro' or b.phase == 'done' then
        local o = b.outro
        local t = Rig.progress(now, o.startAt, outroMs(), 'inOut')
        local g, d, gfov = gameplayPose()
        pos, dir = Rig.lerp(o.camPos, g, t), Rig.blendDir(o.camDir, d, t)
        fov = o.fov0 + (gfov - o.fov0) * t
        clear = t
    end
    setCamera(b, pos, dir, fov)
    placeThumbs(b)
    -- A camera this close would sit inside your own head and shoulders: hide
    -- your character on this screen only (everyone else still sees the pose).
    if length(sub(pos, b.eye)) < 0.9 then SetEntityLocallyInvisible(b.ped) end
    dof(b, length(sub(add(centre, b.off), pos)), clear)
    light(b)
    beam(b, dt)
    flash(b, now)
    return moved or b.phase ~= 'idle'
end

-- Projection ------------------------------------------------------------------------------

local function screen(p)
    local on, x, y = GetScreenCoordFromWorldCoord(p.x, p.y, p.z)
    if not on then return nil end
    return x, y
end

local function q4(x) return floor(x * 5000 + 0.5) / 5000 end

-- A screen box round a seat's part, from its model bounds.
local function box(b, seat)
    local base = seat.boneL or b.centreL
    local held = seat.held
    if held and held.ready then base = add(base, scale(seat.axisL, held.f * seat.travel)) end
    local m = seat.shown and b.models[seat.shown]
    local mins, maxs
    if m then mins, maxs = dims(b, m) else
        local s = 0.025 * b.k
        mins, maxs = v(-s, -s, -s), v(s, s, s)
    end
    local x0, y0, x1, y1 = 1, 1, 0, 0
    for _, cx in ipairs({ mins.x, maxs.x }) do
        for _, cy in ipairs({ mins.y, maxs.y }) do
            for _, cz in ipairs({ mins.z, maxs.z }) do
                local x, y = screen(toWorld(b, add(base, v(cx, cy, cz))))
                if x then x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y) end
            end
        end
    end
    if x1 < x0 then return nil end
    return { q4(x0), q4(y0), q4(x1), q4(y1) }
end

-- Screen positions for the NUI (0..1): an anchor per mechanical seat, the
-- weapon's centre and the focused part's box.
function B.project()
    local b = bench
    if not b or not b.placed then return nil end
    local out = { anchors = {}, centre = nil, box = nil }
    local cx, cy = screen(toWorld(b, b.centreL))
    if cx then out.centre = { q4(cx), q4(cy) } end
    for _, slot in ipairs(R.SLOTS) do
        local seat = b.seats[slot]
        if seat and not seat.surface then
            local x, y = screen(toWorld(b, anchorLocal(b, seat)))
            if x then out.anchors[slot] = { q4(x), q4(y) } end
        end
    end
    local seat = b.seats[b.focus or '']
    if seat and not seat.surface then out.box = box(b, seat) end
    return out
end

-- Slots this weapon has seats for (bench order).
function B.seatSlots()
    local out = {}
    if not bench then return out end
    for _, slot in ipairs(R.SLOTS) do if bench.seats[slot] then out[#out + 1] = slot end end
    return out
end

-- Debug: where the camera is against the eyes it should sit at, how far out
-- the weapon floats (metres) and its bounds on screen against the free band
-- it should fit.
function B.cameraState()
    local b = bench
    if not b or not b.camPos then return nil end
    local function r(x) return floor(x * 1000 + 0.5) / 1000 end
    local gun, lo, hi = { 1, 1, 0, 0 }, b.boundsL[1], b.boundsL[2]
    for i = 0, 7 do
        local corner = v(i % 2 == 0 and lo.x or hi.x, i % 4 < 2 and lo.y or hi.y, i < 4 and lo.z or hi.z)
        local w = add(b.placed, rotate(b.q, corner))
        local seen, sx, sy = GetScreenCoordFromWorldCoord(w.x, w.y, w.z)
        if not seen then gun = false; break end
        gun = { min(gun[1], sx), min(gun[2], sy), max(gun[3], sx), max(gun[4], sy) }
    end
    local left, width = band(b.drawer)
    -- Each part window: shown, the part's box (m), the scale it took and how
    -- much of the window that box spans on screen.
    local thumbs = {}
    for id, t in pairs(b.thumbs) do
        local h, span = t.box.half, false
        if t.shown and t.rect and t.q then
            local x0, y0, x1, y1 = 1, 1, 0, 0
            for i = 0, 7 do
                local c = add(t.box.centre, v(i % 2 == 0 and -h.x or h.x, i % 4 < 2 and -h.y or h.y, i < 4 and -h.z or h.z))
                local w = add(t.origin, scale(rotate(t.q, c), t.scale))
                local _, sx, sy = GetScreenCoordFromWorldCoord(w.x, w.y, w.z)
                x0, y0, x1, y1 = min(x0, sx), min(y0, sy), max(x1, sx), max(y1, sy)
            end
            local rect = t.rect
            span = { x = r((x1 - x0) / (rect[3] - rect[1])), y = r((y1 - y0) / (rect[4] - rect[2])),
                inside = x0 >= rect[1] and x1 <= rect[3] and y0 >= rect[2] and y1 <= rect[4] }
        end
        thumbs[id] = { shown = t.shown, size = { r(2 * h.x), r(2 * h.y), r(2 * h.z) }, scale = t.scale and r(t.scale) or false, span = span }
    end
    return { fromEyes = r(length(sub(b.camPos, b.eye))), weapon = r(length(sub(add(b.P, b.off), b.eye))), fov = r(b.fovNow),
        phase = b.phase, drawer = b.drawer,
        gun = gun and { r(gun[1]), r(gun[2]), r(gun[3]), r(gun[4]) } or false, band = { r(left), r(left + width) },
        zoom = r(b.zoom.now), focus = b.focus or false, thumbs = thumbs, well = b.well ~= nil, plate = b.plateShown == true }
end

-- Debug: the barrel axis and every seat's bone, position and slide axis.
function B.report()
    local b = bench
    if not b then return {} end
    local lines = { ('%s forward %d,%d,%d length %.2f'):format(b.name, floor(b.fwdL.x), floor(b.fwdL.y), floor(b.fwdL.z), b.length) }
    for _, slot in ipairs(R.SLOTS) do
        local seat = b.seats[slot]
        if seat then
            local p = seat.boneL
            lines[#lines + 1] = ('%s %s %s axis %.0f,%.0f,%.0f'):format(slot, seat.bone,
                p and ('%.3f,%.3f,%.3f'):format(p.x, p.y, p.z) or 'missing', seat.axisL.x, seat.axisL.y, seat.axisL.z)
        end
    end
    return lines
end

return B
