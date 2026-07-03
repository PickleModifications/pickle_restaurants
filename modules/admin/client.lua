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

RegisterNUICallback("admin:getData", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:admin:getData", false, d)
    if type(res) == "table" and type(res.recipes) == "table" then
        for _, r in ipairs(res.recipes) do
            local bad = {}
            for _, m in ipairs({ r.raw_model, r.cooked_model, r.burnt_model }) do
                if modelInvalid(m) then bad[#bad + 1] = m end
            end
            r.invalid_models = bad
        end
    end
    cb(res or {})
end)
RegisterNUICallback("admin:create",       relay("pickle_restaurants:admin:create"))
RegisterNUICallback("admin:delete",       relay("pickle_restaurants:admin:delete"))
RegisterNUICallback("admin:setOwner",     relay("pickle_restaurants:admin:setOwner"))
RegisterNUICallback("admin:saveSetting",  relay("pickle_restaurants:admin:saveSetting"))
RegisterNUICallback("admin:saveRecipe",   relay("pickle_restaurants:admin:saveRecipe"))
RegisterNUICallback("admin:deleteRecipe", relay("pickle_restaurants:admin:deleteRecipe"))

-- Admins resolve to full permissions, so the placement remove callback accepts
-- them; this keeps the panel open and lets the React side refresh in place.
RegisterNUICallback("admin:removeProp", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:placement:removeProp", false, { id = d.propId })
    cb(res or {})
end)

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

RegisterNUICallback("admin:placeSeat", function(d, cb)
    CloseNUI()
    cb({})
    StartSeatPlacement(d.id)
end)
