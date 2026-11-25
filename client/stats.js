// The gun shop's stat bars: GET_WEAPON_HUD_STATS and
// GET_WEAPON_COMPONENT_HUD_STATS write a struct Lua cannot pass, so they are
// read here. Five int fields, each padded to 8 bytes (0x28 bytes in all):
// damage, speed (fire rate), capacity, accuracy, range. Component values are
// changes to the weapon's. null when the game has no stats for the hash.
'use strict';

function read(native, hash) {
  if (typeof hash !== 'number') return null;
  const data = new Int32Array(10);
  try {
    const ok = Citizen.invokeNative(native, hash | 0, data, Citizen.returnResultAnyway());
    if (!ok) return null;
  } catch (error) {
    return null;
  }
  return { damage: data[0], speed: data[2], capacity: data[4], accuracy: data[6], range: data[8] };
}

exports('weaponStats', (hash) => read('0xD92C739EE34C9EBA', hash));
exports('componentStats', (hash) => read('0xB3CAF387AE12E9F8', hash));
