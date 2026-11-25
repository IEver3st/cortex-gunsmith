-- Small 3D toolkit for the bench: vectors, quaternions, easing and springs.
-- Pure Lua with no natives, so the same code runs in game and in the offline
-- specs. Vectors are plain { x, y, z } tables; anything with .x/.y/.z (a
-- native vector3) is accepted as input.

GunsmithRig = {}
local R = GunsmithRig
local sqrt, sin, cos, atan, asin, exp, abs, pi = math.sqrt, math.sin, math.cos, math.atan, math.asin, math.exp, math.abs, math.pi
local min, max = math.min, math.max

-- Vectors ---------------------------------------------------------------------

local function v(x, y, z) return { x = x + 0.0, y = y + 0.0, z = z + 0.0 } end
R.v = v
function R.copy(a) return v(a.x, a.y, a.z) end
function R.add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
function R.sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
function R.scale(a, s) return v(a.x * s, a.y * s, a.z * s) end
function R.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function R.cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
function R.length(a) return sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
function R.lerp(a, b, t) return v(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t) end
function R.unit(a, fallback)
    local l = R.length(a)
    if l < 1e-6 then return fallback and R.copy(fallback) or v(0, 0, 0) end
    return v(a.x / l, a.y / l, a.z / l)
end
-- Component of a perpendicular to the unit axis n.
function R.reject(a, n) return R.sub(a, R.scale(n, R.dot(a, n))) end

R.UP = v(0, 0, 1)

-- Quaternions: { x, y, z, w }, unit length, rotating vectors as q * v * q^-1.

local function q(x, y, z, w) return { x = x + 0.0, y = y + 0.0, z = z + 0.0, w = w + 0.0 } end
R.q = q
R.IDENTITY = q(0, 0, 0, 1)

function R.qmul(a, b)
    return q(
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
end

function R.qnorm(a)
    local l = sqrt(a.x * a.x + a.y * a.y + a.z * a.z + a.w * a.w)
    if l < 1e-9 then return q(0, 0, 0, 1) end
    return q(a.x / l, a.y / l, a.z / l, a.w / l)
end

function R.qconj(a) return q(-a.x, -a.y, -a.z, a.w) end

-- Rotation of `angle` radians around the unit axis.
function R.qaxis(axis, angle)
    local s = sin(angle * 0.5)
    return q(axis.x * s, axis.y * s, axis.z * s, cos(angle * 0.5))
end

function R.rotate(a, p)
    -- t = 2 * cross(q.xyz, p); p' = p + w * t + cross(q.xyz, t)
    local tx = 2 * (a.y * p.z - a.z * p.y)
    local ty = 2 * (a.z * p.x - a.x * p.z)
    local tz = 2 * (a.x * p.y - a.y * p.x)
    return v(
        p.x + a.w * tx + (a.y * tz - a.z * ty),
        p.y + a.w * ty + (a.z * tx - a.x * tz),
        p.z + a.w * tz + (a.x * ty - a.y * tx))
end

-- Quaternion of the rotation matrix whose columns are the images of the
-- x, y and z axes (an orthonormal, right-handed basis).
function R.qbasis(cx, cy, cz)
    local m00, m01, m02 = cx.x, cy.x, cz.x
    local m10, m11, m12 = cx.y, cy.y, cz.y
    local m20, m21, m22 = cx.z, cy.z, cz.z
    local trace = m00 + m11 + m22
    if trace > 0 then
        local s = sqrt(trace + 1.0) * 2
        return R.qnorm(q((m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s))
    elseif m00 > m11 and m00 > m22 then
        local s = sqrt(1.0 + m00 - m11 - m22) * 2
        return R.qnorm(q(0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s))
    elseif m11 > m22 then
        local s = sqrt(1.0 + m11 - m00 - m22) * 2
        return R.qnorm(q((m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s))
    end
    local s = sqrt(1.0 + m22 - m00 - m11) * 2
    return R.qnorm(q((m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s))
end

-- Orthonormal basis from a primary axis and a rough secondary one: returns
-- (primary, secondary made perpendicular, primary x secondary).
function R.frame(primary, secondary)
    local a = R.unit(primary, v(1, 0, 0))
    local b = R.unit(R.reject(secondary, a))
    if R.length(b) < 0.5 then
        b = R.unit(R.reject(abs(a.z) < 0.9 and R.UP or v(0, 1, 0), a))
    end
    return a, b, R.cross(a, b)
end

-- The rotation taking local axes (la, lb) onto world axes (wa, wb). Used to
-- lay a weapon's barrel along the screen with its top up.
function R.qalign(la, lb, wa, wb)
    local l1, l2, l3 = R.frame(la, lb)
    local w1, w2, w3 = R.frame(wa, wb)
    -- R = W * L^T, built column by column as images of the world x, y, z axes.
    local function col(e)
        local c1, c2, c3 = l1[e], l2[e], l3[e]
        return v(w1.x * c1 + w2.x * c2 + w3.x * c3, w1.y * c1 + w2.y * c2 + w3.y * c3, w1.z * c1 + w2.z * c2 + w3.z * c3)
    end
    return R.qbasis(col('x'), col('y'), col('z'))
end

function R.qslerp(a, b, t)
    local d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    if d < 0 then b, d = q(-b.x, -b.y, -b.z, -b.w), -d end
    if d > 0.9995 then
        return R.qnorm(q(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t))
    end
    local theta = math.acos(min(1, d))
    local s = sin(theta)
    local wa, wb = sin((1 - t) * theta) / s, sin(t * theta) / s
    return q(a.x * wa + b.x * wb, a.y * wa + b.y * wb, a.z * wa + b.z * wb, a.w * wa + b.w * wb)
end

-- Camera rotation (degrees, rotation order 2) looking along a direction.
-- GTA headings turn counter-clockwise from +Y.
function R.lookRotation(dir)
    local d = R.unit(dir, v(0, 1, 0))
    return v(math.deg(asin(max(-1, min(1, d.z)))), 0, math.deg(atan(-d.x, d.y)))
end

function R.heading(dir) return math.deg(atan(-dir.x, dir.y)) end
function R.forwardFromHeading(deg)
    local r = math.rad(deg)
    return v(-sin(r), cos(r), 0)
end

-- Blend two view directions by heading and pitch, the short way round, so a
-- camera turning to face the other way pans instead of flipping through zero.
function R.blendDir(a, b, t)
    local ra, rb = R.lookRotation(a), R.lookRotation(b)
    local turn = (rb.z - ra.z + 180.0) % 360.0 - 180.0
    local h, p = math.rad(ra.z + turn * t), math.rad(ra.x + (rb.x - ra.x) * t)
    return v(-sin(h) * cos(p), cos(h) * cos(p), sin(p))
end

-- Part windows -----------------------------------------------------------------
-- A model drawn inside a screen window (the drawer's part rail): laid with its
-- longest side across, its top up, tipped 12 degrees towards you and turned
-- `rock` radians about the view's up, scaled so the whole of it stays inside.

-- What the fit needs from a model's bounds (its own frame, Z up).
function R.windowBox(mins, maxs)
    local ex, ey, ez = maxs.x - mins.x, maxs.y - mins.y, maxs.z - mins.z
    return { centre = v((mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5, (mins.z + maxs.z) * 0.5),
        long = ex >= ey and v(1, 0, 0) or v(0, 1, 0), half = v(ex * 0.5, ey * 0.5, ez * 0.5) }
end

-- cam = { pos, dir, right, up } (unit, right-handed); tanV = tan(vfov / 2).
-- The world point `depth` out along dir that lands on screen fractions fx, fy.
function R.screenPoint(cam, tanV, aspect, fx, fy, depth)
    return R.add(R.add(R.add(cam.pos, R.scale(cam.dir, depth)), R.scale(cam.right, (2 * fx - 1) * tanV * aspect * depth)),
        R.scale(cam.up, (1 - 2 * fy) * tanV * depth))
end

-- Space kept clear inside a window, per side, as a share of its width and height.
R.WINDOW_MARGIN = { x = 0.08, y = 0.1 }

-- rect = { x0, y0, x1, y1 } in screen fractions; depth along dir; grow scales
-- the fit (default 1). Returns the rotation, the scale and the entity origin.
-- The scale is the largest that keeps every corner of the turned box inside
-- the window less its margins, in perspective. So a short muzzle brake fills
-- its window as fully as a long suppressor, and a part's near end (larger, and
-- pushed away from the screen's middle) never crosses the edge. Grown from the
-- window's centre, each corner moves in a straight line, so each window edge
-- caps the scale once per corner.
function R.windowPose(cam, tanV, aspect, rect, depth, box, rock, grow)
    local cx, cy = (rect[1] + rect[3]) * 0.5, (rect[2] + rect[4]) * 0.5
    local centre = R.screenPoint(cam, tanV, aspect, cx, cy, depth)
    local q = R.qmul(R.qaxis(cam.up, rock), R.qmul(R.qaxis(cam.right, math.rad(12.0)), R.qalign(box.long, R.UP, cam.right, cam.up)))
    -- A point `across` along an axis and `deep` along dir sits on an edge when
    -- across = slope * deep. Each edge: axis, the centre's across, slope, side.
    local mx, my = (rect[3] - rect[1]) * R.WINDOW_MARGIN.x, (rect[4] - rect[2]) * R.WINDOW_MARGIN.y
    local sx, sy = tanV * aspect, tanV
    local ax, ay = (2 * cx - 1) * sx * depth, (1 - 2 * cy) * sy * depth
    local edges = {
        { cam.right, ax, (2 * (rect[1] + mx) - 1) * sx, -1 }, { cam.right, ax, (2 * (rect[3] - mx) - 1) * sx, 1 },
        { cam.up, ay, (1 - 2 * (rect[4] - my)) * sy, -1 }, { cam.up, ay, (1 - 2 * (rect[2] + my)) * sy, 1 },
    }
    local hx, hy, hz = R.rotate(q, v(box.half.x, 0, 0)), R.rotate(q, v(0, box.half.y, 0)), R.rotate(q, v(0, 0, box.half.z))
    local s = 10.0
    for i = 0, 7 do
        local c = R.add(R.add(R.scale(hx, i % 2 < 1 and 1 or -1), R.scale(hy, i % 4 < 2 and 1 or -1)), R.scale(hz, i < 4 and 1 or -1))
        local along = R.dot(c, cam.dir)
        for _, e in ipairs(edges) do
            local rate = e[4] * (R.dot(c, e[1]) - e[3] * along)
            if rate > 1e-9 then s = min(s, e[4] * (e[3] * depth - e[2]) / rate) end
        end
    end
    s = s * (grow or 1)
    return q, s, R.sub(centre, R.scale(R.rotate(q, box.centre), s))
end

-- A model pressed flat behind a screen rect: its box (mins, maxs) stretched so
-- its top spans exactly `rect` at `depth`, facing the camera, `thick` deep.
-- Returns the world vectors its X, Y and Z axes take (scaled: X across the
-- screen, Y up it, Z towards you) and the entity origin.
function R.flatPose(cam, tanV, aspect, rect, depth, thick, mins, maxs)
    local size = R.sub(maxs, mins)
    local x = R.scale(cam.right, (rect[3] - rect[1]) * 2 * tanV * aspect * depth / size.x)
    local y = R.scale(cam.up, (rect[4] - rect[2]) * 2 * tanV * depth / size.y)
    local z = R.scale(cam.dir, -thick / size.z)
    local face = R.screenPoint(cam, tanV, aspect, (rect[1] + rect[3]) * 0.5, (rect[2] + rect[4]) * 0.5, depth)
    local top = R.add(R.add(R.scale(x, (mins.x + maxs.x) * 0.5), R.scale(y, (mins.y + maxs.y) * 0.5)), R.scale(z, maxs.z))
    return x, y, z, R.sub(face, top)
end

-- Easing -----------------------------------------------------------------------

local function clamp01(t) return t < 0 and 0 or (t > 1 and 1 or t) end
R.clamp01 = clamp01
function R.clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end

R.ease = {
    linear = function(t) return t end,
    out = function(t) t = 1 - t; return 1 - t * t * t end,           -- cubic out
    ['in'] = function(t) return t * t * t end,                     -- cubic in
    inOut = function(t) return t < 0.5 and 4 * t * t * t or 1 - (-2 * t + 2) ^ 3 / 2 end,
    -- A mechanical seat: accelerates into the stop, no overshoot.
    seat = function(t) return t * t end,
}

-- cubic-bezier(0.2, 0.8, 0.2, 1): the Cortex --ease, solved for x.
do
    local x1, y1, x2, y2 = 0.2, 0.8, 0.2, 1.0
    local function bx(s) return 3 * (1 - s) ^ 2 * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s end
    local function by(s) return 3 * (1 - s) ^ 2 * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s end
    R.ease.cortex = function(t)
        -- Exact ends: the solver only gets within 2^-19 of them, and callers
        -- finish a move on progress >= 1.
        if t <= 0 then return 0.0 elseif t >= 1 then return 1.0 end
        local lo, hi = 0.0, 1.0
        for _ = 1, 18 do
            local mid = (lo + hi) * 0.5
            if bx(mid) < t then lo = mid else hi = mid end
        end
        return by((lo + hi) * 0.5)
    end
end

-- Progress of a timed move: start time, duration (ms), easing name.
function R.progress(now, startAt, duration, easing)
    if duration <= 0 then return 1 end
    local t = clamp01((now - startAt) / duration)
    return (R.ease[easing or 'cortex'] or R.ease.cortex)(t)
end

-- Frame-rate independent approach: fraction to move this frame.
function R.approach(rate, dt) return 1 - exp(-rate * dt) end

-- A critically damped spring towards zero: the bench's "click" kicks.
-- state = { x, vx }; returns the new displacement.
function R.spring(state, stiffness, dt)
    dt = min(dt, 0.05)
    local omega = sqrt(stiffness)
    local x, vx = state.x, state.vx
    -- Exact solution of the critically damped oscillator over dt.
    local e = exp(-omega * dt)
    local a = x
    local b = vx + omega * x
    state.x = (a + b * dt) * e
    state.vx = (b - omega * (a + b * dt)) * e
    if abs(state.x) < 1e-5 and abs(state.vx) < 1e-4 then state.x, state.vx = 0.0, 0.0 end
    return state.x
end

function R.springActive(state) return state.x ~= 0 or state.vx ~= 0 end

-- A flung turn coasting to a stop: `speed` (per second) under `friction`
-- (per second) for dt. Returns the new speed, 0 once it is below `stop`, and
-- how far it went: exact, so the frame rate changes neither.
function R.coast(speed, friction, dt, stop)
    local e = exp(-friction * dt)
    local went = speed * (1 - e) / friction
    local now = speed * e
    if abs(now) < stop then now = 0.0 end
    return now, went
end

-- Where a part reaches furthest from its own origin, along its longest
-- side: the tip of a muzzle device, the lens of a flashlight.
function R.reach(mins, maxs)
    local dx, dy, dz = maxs.x - mins.x, maxs.y - mins.y, maxs.z - mins.z
    if dx >= dy and dx >= dz then return max(abs(mins.x), abs(maxs.x)) end
    if dy >= dz then return max(abs(mins.y), abs(maxs.y)) end
    return max(abs(mins.z), abs(maxs.z))
end

return R
