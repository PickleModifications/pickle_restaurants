-- =============================================
--  modules/management | client.lua
--  Opens the management NUI and relays its actions to the server.
-- =============================================

function OpenManagement(restaurantId)
    local data = lib.callback.await("pickle_restaurants:management:getData", false, { id = restaurantId })
    if not data or not data.ok then
        return ShowNotification((data and data.error) or _L("manage_no_access"))
    end
    data.restaurantId = restaurantId
    OpenNUI("management", data)
end

local function relayThenRefresh(callbackName)
    return function(d, cb)
        local res = lib.callback.await(callbackName, false, d)
        if res and res.error then ShowNotification(res.error) end
        -- hand the fresh dataset back so the panel re-renders
        if d.id then
            local data = lib.callback.await("pickle_restaurants:management:getData", false, { id = d.id })
            if data and data.ok then
                data.restaurantId = d.id
                SendNUIMessage({ action = "setView", view = "management", data = data })
            end
        end
        cb(res or {})
    end
end

RegisterNUICallback("management:hire",           relayThenRefresh("pickle_restaurants:management:hire"))
RegisterNUICallback("management:fire",           relayThenRefresh("pickle_restaurants:management:fire"))
RegisterNUICallback("management:setGrade",       relayThenRefresh("pickle_restaurants:management:setGrade"))
RegisterNUICallback("management:setCommission",  relayThenRefresh("pickle_restaurants:management:setCommission"))
RegisterNUICallback("management:saveMenuItem",   relayThenRefresh("pickle_restaurants:management:saveMenuItem"))
RegisterNUICallback("management:deleteMenuItem", relayThenRefresh("pickle_restaurants:management:deleteMenuItem"))
RegisterNUICallback("management:deposit",        relayThenRefresh("pickle_restaurants:management:deposit"))
RegisterNUICallback("management:withdraw",       relayThenRefresh("pickle_restaurants:management:withdraw"))

-- Branding saves DON'T refresh the panel — that would remount the crop UI mid-setup.
-- The React side keeps its own optimistic copy; the server sync drives the props.
RegisterNUICallback("management:setBrandImage", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:management:setBrandImage", false, d)
    if res and res.error then ShowNotification(res.error) end
    cb(res or {})
end)

RegisterNUICallback("management:removeProp", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:placement:removeProp", false, { id = d.propId })
    if res and res.error then ShowNotification(res.error) end
    if d.id then
        local data = lib.callback.await("pickle_restaurants:management:getData", false, { id = d.id })
        if data and data.ok then
            data.restaurantId = d.id
            SendNUIMessage({ action = "setView", view = "management", data = data })
        end
    end
    cb(res or {})
end)

RegisterNUICallback("management:placeProp", function(d, cb)
    CloseNUI()
    cb({})
    StartPropPlacement(d.id, d.prop_type)
end)

RegisterNUICallback("management:setCounter", function(d, cb)
    CloseNUI()
    cb({})
    StartCounterPlacement(d.id)
end)

RegisterNUICallback("management:placeSeat", function(d, cb)
    CloseNUI()
    cb({})
    StartSeatPlacement(d.id)
end)
