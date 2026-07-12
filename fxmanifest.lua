fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Pickle Modifications'
description 'pickle_restaurants - fully in-game configurable restaurant system'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'core/shared.lua',
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
}

dependencies {
    'ox_lib',
    'oxmysql',
}
