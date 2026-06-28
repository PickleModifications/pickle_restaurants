-- Standalone bridge (client). Only runs when no supported framework is present.
if GetResourceState('es_extended') == 'started' then return end
if GetResourceState('qb-core') == 'started' then return end

function ShowNotification(text)
    lib.notify({ description = text })
end

RegisterNetEvent(GetCurrentResourceName() .. ":showNotification", function(text)
    ShowNotification(text)
end)

-- Inventory mirror (client). ox_inventory exposes a client export we wrap so
-- the cooking bar can render the player's items without a server round-trip.
CreateThread(function()
    Wait(100)
    if InitializeInventory then return InitializeInventory() end
    Inventory = {}
    Inventory.Items = {}
    Inventory.Ready = true
end)
