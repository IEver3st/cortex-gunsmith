-- Cortex Gunsmith: attachment items ox_inventory does not ship (Mk II rounds and
-- weapon kits). Without them those parts show on the bench as not carried.
--
-- Copy every line between the two markers into the Components table of
-- ox_inventory/data/weapons.lua, then restart the server.
return {
-- copy from here -------------------------------------------------------------
['at_ammo_armorpiercing'] = {
    label = 'Armor Piercing Rounds',
    type = 'magazine',
    weight = 280,
    client = {
        component = { `COMPONENT_ASSAULTRIFLE_MK2_CLIP_ARMORPIERCING`, `COMPONENT_BULLPUPRIFLE_MK2_CLIP_ARMORPIERCING`, `COMPONENT_CARBINERIFLE_MK2_CLIP_ARMORPIERCING`, `COMPONENT_COMBATMG_MK2_CLIP_ARMORPIERCING`, `COMPONENT_HEAVYSNIPER_MK2_CLIP_ARMORPIERCING`, `COMPONENT_MARKSMANRIFLE_MK2_CLIP_ARMORPIERCING`, `COMPONENT_PUMPSHOTGUN_MK2_CLIP_ARMORPIERCING`, `COMPONENT_SPECIALCARBINE_MK2_CLIP_ARMORPIERCING` },
        usetime = 2500
    }
},
['at_ammo_explosive'] = {
    label = 'Explosive Rounds',
    type = 'magazine',
    weight = 280,
    client = {
        component = { `COMPONENT_HEAVYSNIPER_MK2_CLIP_EXPLOSIVE`, `COMPONENT_PUMPSHOTGUN_MK2_CLIP_EXPLOSIVE` },
        usetime = 2500
    }
},
['at_ammo_fmj'] = {
    label = 'Full Metal Jacket Rounds',
    type = 'magazine',
    weight = 280,
    client = {
        component = { `COMPONENT_ASSAULTRIFLE_MK2_CLIP_FMJ`, `COMPONENT_BULLPUPRIFLE_MK2_CLIP_FMJ`, `COMPONENT_CARBINERIFLE_MK2_CLIP_FMJ`, `COMPONENT_COMBATMG_MK2_CLIP_FMJ`, `COMPONENT_HEAVYSNIPER_MK2_CLIP_FMJ`, `COMPONENT_MARKSMANRIFLE_MK2_CLIP_FMJ`, `COMPONENT_PISTOL_MK2_CLIP_FMJ`, `COMPONENT_REVOLVER_MK2_CLIP_FMJ`, `COMPONENT_SMG_MK2_CLIP_FMJ`, `COMPONENT_SNSPISTOL_MK2_CLIP_FMJ`, `COMPONENT_SPECIALCARBINE_MK2_CLIP_FMJ` },
        usetime = 2500
    }
},
['at_ammo_hollowpoint'] = {
    label = 'Hollow Point Rounds',
    type = 'magazine',
    weight = 280,
    client = {
        component = { `COMPONENT_PISTOL_MK2_CLIP_HOLLOWPOINT`, `COMPONENT_PUMPSHOTGUN_MK2_CLIP_HOLLOWPOINT`, `COMPONENT_REVOLVER_MK2_CLIP_HOLLOWPOINT`, `COMPONENT_SMG_MK2_CLIP_HOLLOWPOINT`, `COMPONENT_SNSPISTOL_MK2_CLIP_HOLLOWPOINT` },
        usetime = 2500
    }
},
['at_ammo_incendiary'] = {
    label = 'Incendiary Rounds',
    type = 'magazine',
    weight = 280,
    client = {
        component = { `COMPONENT_ASSAULTRIFLE_MK2_CLIP_INCENDIARY`, `COMPONENT_BULLPUPRIFLE_MK2_CLIP_INCENDIARY`, `COMPONENT_CARBINERIFLE_MK2_CLIP_INCENDIARY`, `COMPONENT_COMBATMG_MK2_CLIP_INCENDIARY`, `COMPONENT_HEAVYSNIPER_MK2_CLIP_INCENDIARY`, `COMPONENT_MARKSMANRIFLE_MK2_CLIP_INCENDIARY`, `COMPONENT_PISTOL_MK2_CLIP_INCENDIARY`, `COMPONENT_PUMPSHOTGUN_MK2_CLIP_INCENDIARY`, `COMPONENT_REVOLVER_MK2_CLIP_INCENDIARY`, `COMPONENT_SMG_MK2_CLIP_INCENDIARY`, `COMPONENT_SNSPISTOL_MK2_CLIP_INCENDIARY`, `COMPONENT_SPECIALCARBINE_MK2_CLIP_INCENDIARY` },
        usetime = 2500
    }
},
['at_ammo_tracer'] = {
    label = 'Tracer Rounds',
    type = 'magazine',
    weight = 280,
    client = {
        component = { `COMPONENT_ASSAULTRIFLE_MK2_CLIP_TRACER`, `COMPONENT_BULLPUPRIFLE_MK2_CLIP_TRACER`, `COMPONENT_CARBINERIFLE_MK2_CLIP_TRACER`, `COMPONENT_COMBATMG_MK2_CLIP_TRACER`, `COMPONENT_MARKSMANRIFLE_MK2_CLIP_TRACER`, `COMPONENT_PISTOL_MK2_CLIP_TRACER`, `COMPONENT_REVOLVER_MK2_CLIP_TRACER`, `COMPONENT_SMG_MK2_CLIP_TRACER`, `COMPONENT_SNSPISTOL_MK2_CLIP_TRACER`, `COMPONENT_SPECIALCARBINE_MK2_CLIP_TRACER` },
        usetime = 2500
    }
},
['at_skin_dildodude'] = {
    label = 'Dildodude Weapon Kit',
    type = 'skin',
    weight = 50,
    client = {
        component = { `COMPONENT_MICROSMG_VARMOD_XM3`, `COMPONENT_PUMPSHOTGUN_VARMOD_XM3` },
        usetime = 2500
    }
},
['at_skin_eyes'] = {
    label = 'Eyes Weapon Kit',
    type = 'skin',
    weight = 50,
    client = {
        component = { `COMPONENT_KNIFE_VARMOD_XM3` },
        usetime = 2500
    }
},
['at_skin_flames'] = {
    label = 'Flames Weapon Kit',
    type = 'skin',
    weight = 50,
    client = {
        component = { `COMPONENT_KNIFE_VARMOD_XM3_02` },
        usetime = 2500
    }
},
['at_skin_lightning'] = {
    label = 'Lightning Weapon Kit',
    type = 'skin',
    weight = 50,
    client = {
        component = { `COMPONENT_KNIFE_VARMOD_XM3_03` },
        usetime = 2500
    }
},
['at_skin_orangotang'] = {
    label = 'Orang-O-Tang Weapon Kit',
    type = 'skin',
    weight = 50,
    client = {
        component = { `COMPONENT_KNIFE_VARMOD_XM3_09` },
        usetime = 2500
    }
},
['at_skin_pills'] = {
    label = 'Pills Weapon Kit',
    type = 'skin',
    weight = 50,
    client = {
        component = { `COMPONENT_KNIFE_VARMOD_XM3_04` },
        usetime = 2500
    }
},
['at_skin_seasonsgreetings'] = {
    label = 'Season\'s Greetings Weapon Kit',
    type = 'skin',
    weight = 50,
    client = {
        component = { `COMPONENT_PISTOL_MK2_VARMOD_XM3` },
        usetime = 2500
    }
},
['at_skin_snakeskin'] = {
    label = 'Snakeskin Weapon Kit',
    type = 'skin',
    weight = 50,
    client = {
        component = { `COMPONENT_KNIFE_VARMOD_XM3_05` },
        usetime = 2500
    }
},
['at_skin_tequilya'] = {
    label = 'Tequilya Weapon Kit',
    type = 'skin',
    weight = 50,
    client = {
        component = { `COMPONENT_KNIFE_VARMOD_XM3_08` },
        usetime = 2500
    }
},
-- to here ---------------------------------------------------------------------
}
