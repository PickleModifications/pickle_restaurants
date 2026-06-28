-- =============================================
--  modules/sales | client.lua
--  Opens the walk-in order menu and the staff register NUI.
-- =============================================

function OpenOrderMenu(restaurantId)
    local data = lib.callback.await("pickle_restaurants:sales:getMenu", false, { id = restaurantId })
    if not data or not data.ok then return ShowNotification("This place isn't serving right now.") end
    data.restaurantId = restaurantId
    OpenNUI("order", data)
end

function OpenRegister(restaurantId)
    local data = lib.callback.await("pickle_restaurants:sales:getRegister", false, { id = restaurantId })
    if not data or not data.ok then return ShowNotification((data and data.error) or "You don't work here.") end
    OpenNUI("register", data)
end

RegisterNUICallback("sales:buy", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:sales:buy", false, d)
    if res and res.ok then
        ShowNotification("Bought " .. (res.label or res.item))
        local data = lib.callback.await("pickle_restaurants:sales:getMenu", false, { id = d.id })
        if data and data.ok then data.restaurantId = d.id; SendNUIMessage({ action = "setView", view = "order", data = data }) end
    elseif res and res.error then
        ShowNotification(res.error)
    end
    cb(res or {})
end)

local function refreshRegister(id)
    local data = lib.callback.await("pickle_restaurants:sales:getRegister", false, { id = id })
    if data and data.ok then SendNUIMessage({ action = "setView", view = "register", data = data }) end
end

RegisterNUICallback("sales:stock", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:sales:stock", false, d)
    if res and res.error then ShowNotification(res.error) end
    if res and res.ok then SendNUIMessage({ action = "setView", view = "register", data = (function() res.restaurantId = d.id; return res end)() }) end
    cb(res or {})
end)

RegisterNUICallback("sales:serve", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:npc:serve", false, d)
    if res and res.ok then
        ShowNotification("Order served (+" .. GetCurrencyString(res.commission or 0) .. ")")
    elseif res and res.error then
        ShowNotification(res.error)
    end
    refreshRegister(d.id)
    cb(res or {})
end)
