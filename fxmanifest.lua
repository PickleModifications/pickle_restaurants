fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Pickle Modifications'
description 'pickle_restaurants - fully in-game configurable restaurant system'
version '1.0.1'

shared_scripts {
    '@ox_lib/init.lua',
    'core/shared.lua',
    'bridge/**/shared.lua',
    'locales/locale.lua',
    'locales/translations/*.lua',
}

client_scripts {
    'bridge/**/client.lua',
    'core/client.lua',
    'modules/**/client.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/**/server.lua',
    'core/server.lua',
    'modules/**/server.lua',
}

ui_page 'nui/index.html'

files {
    'nui/index.html',
    'nui/**/*',
    'html/brand.html', -- DUI page for the render-target brand texture
    'html/screens.html', -- DUI page for the menu / orders info screens (modules/screens)
    'html/quad.html', -- DUI page for the food image drawn inside a takeout box (modules/quad)
}

dependencies {
    'ox_lib',
    'oxmysql',
}

-- __INSTALL/ is operator paperwork, not runtime code: the item definitions to paste
-- into your inventory and the icons to drop in its image folder. Escrow would
-- otherwise encrypt the .lua files in there and hand the buyer a blob they can't
-- read — which is the one thing those files exist to be. Kept open.
escrow_ignore {
    '__INSTALL/**',
}
