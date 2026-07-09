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

-- Model validity can only be checked client-side (it's a game native), so we
-- annotate each recipe's invalid models on the way back from the server.
local function modelInvalid(model)
    if not model or model == "" then return false end
    return not IsModelInCdimage(GetHashKey(model))
end

local function annotateModels(res)
    if type(res) == "table" and type(res.recipes) == "table" then
        for _, r in ipairs(res.recipes) do
            local bad = {}
            for _, m in ipairs({ r.raw_model, r.cooked_model, r.burnt_model }) do
                if modelInvalid(m) then bad[#bad + 1] = m end
            end
            r.invalid_models = bad
        end
    end
    return res
end

-- Re-fetch the admin dataset and reopen the panel — used after a placement/gizmo
-- flow hands control back, so the admin lands back in the menu (with the just-
-- placed prop/seat already in the fresh data) instead of a closed screen. `focus`
-- (restaurant id + section) tells the NUI to reopen that restaurant and scroll to
-- its stations/seating so another can be placed immediately.
local function ReopenAdmin(restaurantId, section)
    local res = annotateModels(lib.callback.await("pickle_restaurants:admin:getData", false, {}))
    if type(res) == "table" and res.ok ~= false then
        if restaurantId then res.focus = { restaurant = restaurantId, section = section } end
        OpenNUI("admin", res)
    end
end

RegisterNUICallback("admin:getData", function(d, cb)
    cb(annotateModels(lib.callback.await("pickle_restaurants:admin:getData", false, d)) or {})
end)
RegisterNUICallback("admin:create",       relay("pickle_restaurants:admin:create"))
RegisterNUICallback("admin:delete",       relay("pickle_restaurants:admin:delete"))
RegisterNUICallback("admin:setOwner",     relay("pickle_restaurants:admin:setOwner"))
RegisterNUICallback("admin:setBrandImage", relay("pickle_restaurants:admin:setBrandImage"))
RegisterNUICallback("admin:saveSetting",  relay("pickle_restaurants:admin:saveSetting"))
RegisterNUICallback("admin:saveSettings", relay("pickle_restaurants:admin:saveSettings"))
RegisterNUICallback("admin:saveRecipe",   relay("pickle_restaurants:admin:saveRecipe"))
RegisterNUICallback("admin:deleteRecipe", relay("pickle_restaurants:admin:deleteRecipe"))
RegisterNUICallback("admin:resetRecipes", relay("pickle_restaurants:admin:resetRecipes"))

-- Admins resolve to full permissions, so the placement remove callback accepts
-- them; this keeps the panel open and lets the React side refresh in place.
RegisterNUICallback("admin:removeProp", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:placement:removeProp", false, { id = d.propId })
    cb(res or {})
end)

-- These close the NUI and hand off to the (blocking) gizmo placement flow, then
-- reopen the admin panel with fresh data so another entity can be placed without
-- reopening the menu by hand — on both a successful placement and a cancel.
RegisterNUICallback("admin:placeProp", function(d, cb)
    CloseNUI()
    cb({})
    StartPropPlacement(d.id, d.prop_type)
    ReopenAdmin(d.id, "stations")
end)

RegisterNUICallback("admin:setCounter", function(d, cb)
    CloseNUI()
    cb({})
    StartCounterPlacement(d.id)
    ReopenAdmin(d.id, "stations")
end)

RegisterNUICallback("admin:placeSeat", function(d, cb)
    CloseNUI()
    cb({})
    StartSeatPlacement(d.id)
    ReopenAdmin(d.id, "seating")
end)
