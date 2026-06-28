-- =============================================
--  modules/admin | client.lua
--  Opens the admin NUI and relays its actions to the server callbacks.
-- =============================================

RegisterNetEvent("pickle_restaurants:openAdmin", function(data)
    OpenNUI("admin", data)
end)

-- Generic relay: forward a NUI action straight to a server callback and
-- return the result to the NUI.
local function relay(callbackName)
    return function(d, cb)
        local res = lib.callback.await(callbackName, false, d)
        cb(res or {})
    end
end

RegisterNUICallback("admin:getData",      relay("pickle_restaurants:admin:getData"))
RegisterNUICallback("admin:create",       relay("pickle_restaurants:admin:create"))
RegisterNUICallback("admin:delete",       relay("pickle_restaurants:admin:delete"))
RegisterNUICallback("admin:setOwner",     relay("pickle_restaurants:admin:setOwner"))
RegisterNUICallback("admin:saveSetting",  relay("pickle_restaurants:admin:saveSetting"))
RegisterNUICallback("admin:saveRecipe",   relay("pickle_restaurants:admin:saveRecipe"))
RegisterNUICallback("admin:deleteRecipe", relay("pickle_restaurants:admin:deleteRecipe"))

-- These close the NUI and hand off to the gizmo placement flow.
RegisterNUICallback("admin:placeProp", function(d, cb)
    CloseNUI()
    cb({})
    StartPropPlacement(d.id, d.prop_type)
end)

RegisterNUICallback("admin:setCounter", function(d, cb)
    CloseNUI()
    cb({})
    StartCounterPlacement(d.id)
end)
