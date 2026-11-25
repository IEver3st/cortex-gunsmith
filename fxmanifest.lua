fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

name 'cortex-gunsmith'
author 'GSDMODS/CORTEX'
description 'A 3D gunsmith bench for any weapon: fit parts, tints and camos on the real model'
version '1.0.1'

dependencies { 'cortex-lib', '/onesync' }

shared_scripts { '@cortex-lib/init.lua', 'config.lua', 'shared/locale.lua', 'shared/rig.lua', 'shared/catalog.lua', 'shared/rules.lua' }
client_scripts { '@cortex-lib/presentation-client.lua', 'client/stats.js', 'client/bounds.lua', 'client/bench.lua', 'client/apply.lua', 'client/main.lua', 'client/quick.lua' }
server_scripts { 'server/bridge.lua', 'server/main.lua' }

ui_page 'web/dist/index.html'
files { 'web/dist/index.html', 'web/dist/assets/*', 'web/dist/barlow-condensed-OFL.txt', 'locales/*.json' }

escrow_ignore { 'config.lua', 'locales/*.json', 'shared/locale.lua', 'shared/catalog.lua', 'install/*.lua' }
