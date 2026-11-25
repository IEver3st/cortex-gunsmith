Config = {}

Config.Locale = 'en' -- locales/<code>.json

-- Opening the bench ------------------------------------------------------------

-- Hold a weapon and press the key (players rebind it under Settings > Key
-- Bindings > FiveM), or type the command. Set either to false to disable it.
Config.key = 'F9'
Config.padKey = false -- e.g. 'LRIGHT_INDEX' for D-pad right; false = no controller default
Config.command = 'gunsmith'

-- Quick swap: hold its key with a weapon out to change parts mid-fight
-- without the bench (scroll to a slot, fire to step it to the next part you
-- carry, let go to fit). It has no default key: players bind it under
-- Settings > Key Bindings > FiveM. Name a key here to give it one (e.g.
-- 'MOUSE_EXTRABTN1' with mapper 'MOUSE_BUTTON'). enabled = false removes it.
Config.quick = { enabled = true, key = false, mapper = 'keyboard', padKey = false }

-- Using an attachment item while holding a weapon opens the bench on that
-- part's slot, ready to fit it (framework usable items; see README).
Config.openOnUse = true

-- Who may use the bench: false = anyone, or { ace = 'gunsmith.use' }.
Config.access = false

-- Spawn names that never open the bench.
Config.blockedWeapons = {}

-- Inventory --------------------------------------------------------------------

-- 'auto' uses the first one running: ox_inventory, QBCore, ESX, then
-- standalone. Or name one: 'ox', 'qb', 'esx', 'standalone'.
Config.inventory = 'auto'

-- Parts are attachment items (at_flashlight, at_scope_medium, ...; full list
-- in README). Fitting one takes it from the inventory; taking it off gives it
-- back. Map a name here when your server calls an item something else:
--   Config.items = { at_flashlight = 'weapon_flashlight' }
Config.items = {}

-- Standalone (no inventory): every part the weapon takes can be fitted for
-- free, and the server remembers each player's setup per weapon.
Config.standalone = { remember = true }

-- Tints are free to change unless an item is named here (one is used per change).
Config.tint = { enabled = true, item = false }
-- Mk II camo colours (the 32 Mk II palette colours on a fitted camo).
Config.livery = { enabled = true }

-- The bench ------------------------------------------------------------------------

Config.bench = {
    -- First person: the camera is your eyes and you're locked in place while
    -- you work. How far the view tips down (degrees), and its vertical field
    -- of view. The weapon floats as far out as it needs to fit the screen.
    lookDown = 12.0,
    fov = 45.0,
    -- Real depth of field on the bench camera.
    dof = true,
    -- A soft key light over the weapon, so it reads at night and indoors.
    -- parts: brightness of the small light on each part in the drawer's
    -- windows (0 = none).
    light = { enabled = true, intensity = 2.2, range = 2.6, colour = { 255, 244, 228 }, parts = 5.0 },
    -- The pose other players see you in while you work: standing, both hands
    -- up in front, looking down at them (you see nothing of it in first
    -- person). false = no pose.
    pose = { dict = 'amb@world_human_tourist_map@male@base', clip = 'base' },
    -- Mouse drag and stick speed when turning the weapon.
    turnSpeed = 1.0,
    -- A fitted flashlight shines while you work, F (Y on a controller) fires
    -- a blank for show (no bullet; only you see it) and a controller rumbles
    -- as parts go on and off. false turns one off.
    beam = true,
    fire = true,
    rumble = true,
}

-- Native game sounds: { name, soundset }. false silences one.
Config.sounds = {
    open = { 'WEAPON_SELECT_RIFLE', 'HUD_AMMO_SHOP_SOUNDSET' },
    navigate = { 'NAV', 'HUD_AMMO_SHOP_SOUNDSET' },
    fit = { 'WEAPON_ATTACHMENT_EQUIP', 'HUD_AMMO_SHOP_SOUNDSET' },
    remove = { 'WEAPON_ATTACHMENT_UNEQUIP', 'HUD_AMMO_SHOP_SOUNDSET' },
    finish = { 'Weapon_Upgrade', 'DLC_GR_Weapon_Upgrade_Soundset' },
    -- The dry fire: the game has no gunshot a script can play without a real
    -- bullet, so the action works instead.
    fire = { 'WEAPON_SELECT_PISTOL', 'HUD_AMMO_SHOP_SOUNDSET' },
    error = { 'ERROR', 'HUD_AMMO_SHOP_SOUNDSET' },
    close = { 'BACK', 'HUD_AMMO_SHOP_SOUNDSET' },
}

-- Prints decisions to F8 and adds /gunsmith_bones (bone and anchor report).
Config.debug = false
