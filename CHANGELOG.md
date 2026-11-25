# Changelog

## 1.0.1 (2026-10-19)

### Changed
- Cortex Gunsmith is now an escrowed Cfx.re asset, free on Tebex. Claim it on the store and download it from portal.cfx.re > Granted Assets. config.lua, the locale files, shared/catalog.lua and the ox_inventory snippet stay editable.

## 1.0.0 (2026-10-19)

### Added
- First release. Hold a weapon and press F9 (or /gunsmith): the view drops into first person and the weapon floats in front of you on the game's own model, with depth of field and a key light.
- Every part the game has for the weapon, each beside its own 3D model. The old part slides off along its rail and the new one clicks on.
- Strip down (X), tints, Mk II camo colours and finishes, with stat bars that show what a part does before you fit it.
- Fling the weapon to spin it, a fitted flashlight lights the street, F fires a blank (flash, smoke and a flying case), hold C to see it stock, and controllers rumble.
- Quick swap: hold its key with a weapon out to change parts mid-fight. It has no default key; bind it under Settings > Key Bindings > FiveM.
- The server checks every change. Parts are ox_inventory attachment items; without an inventory the bench runs standalone and remembers each player's setup. QBCore and ESX adapters are included as experimental.
- Player settings for the controls hint and depth of field, Cortex Lib's reduced motion, and locale files.
