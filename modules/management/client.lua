-- =============================================
--  modules/management | client.lua
--  Opens the management NUI and relays its actions to the server.
-- =============================================

-- `section` (optional) tells the NUI to open a specific tab and scroll to it —
-- used after a placement flow so the boss lands back on Stations/Seating.
function OpenManagement(restaurantId, section)
    local data = lib.callback.await("pickle_restaurants:management:getData", false, { id = restaurantId })
    if not data or not data.ok then
        return ShowNotification((data and data.error) or _L("manage_no_access"))
    end
    data.restaurantId = restaurantId
    if section then data.focus = { section = section } end
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
RegisterNUICallback("management:buyStock",       relayThenRefresh("pickle_restaurants:management:buyStock"))
RegisterNUICallback("management:depositStock",   relayThenRefresh("pickle_restaurants:management:depositStock"))
RegisterNUICallback("management:withdrawStock",  relayThenRefresh("pickle_restaurants:management:withdrawStock"))

-- Branding saves DON'T refresh the panel — that would remount the crop UI mid-setup.
-- The React side keeps its own optimistic copy; the server sync drives the props.
RegisterNUICallback("management:setBrandImage", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:management:setBrandImage", false, d)
    if res and res.error then ShowNotification(res.error) end
    cb(res or {})
end)

-- Theme saves also skip the refresh — the NUI already applied the theme live.
RegisterNUICallback("management:setTheme", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:management:setTheme", false, d)
    if res and res.error then ShowNotification(res.error) end
    cb(res or {})
end)

-- Rename also skips the refresh: it auto-saves as you type, and re-fetching getData
-- would remount the Brand tab and yank the cursor out of the field mid-edit.
RegisterNUICallback("management:setName", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:management:setName", false, d)
    if res and res.error then ShowNotification(res.error) end
    cb(res or {})
end)

-- Combos autosave (and delete) from their own optimistic React state — a panel
-- refresh would remount the editor mid-edit (losing the open card / cursor), so
-- these relay to the server WITHOUT re-fetching getData, like the theme/brand saves.
RegisterNUICallback("management:saveCombo", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:management:saveCombo", false, d)
    if res and res.error then ShowNotification(res.error) end
    cb(res or {})
end)

RegisterNUICallback("management:deleteCombo", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:management:deleteCombo", false, d)
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

-- These close the NUI and hand off to the (blocking) gizmo placement flow, then
-- reopen the management panel with fresh data so another entity can be placed
-- without reopening the menu by hand — on both a successful placement and a cancel.
-- OpenManagement re-fetches getData, so the reopened panel is never stale.
RegisterNUICallback("management:placeProp", function(d, cb)
    CloseNUI()
    cb({})
    StartPropPlacement(d.id, d.prop_type)
    OpenManagement(d.id, "stations")
end)

RegisterNUICallback("management:setCounter", function(d, cb)
    CloseNUI()
    cb({})
    StartCounterPlacement(d.id)
    OpenManagement(d.id, "counters")
end)

-- A virtual register anchor (invisible; opens the fullscreen NUI register, no DUI).
RegisterNUICallback("management:setVirtualRegister", function(d, cb)
    CloseNUI()
    cb({})
    StartVirtualRegisterPlacement(d.id)
    OpenManagement(d.id, "counters")
end)

-- Reposition an existing placed prop (station / counter / seat / virtual point),
-- then reopen to its section.
RegisterNUICallback("management:editProp", function(d, cb)
    CloseNUI()
    cb({})
    StartPropReposition(d.propId)
    OpenManagement(d.id, d.section)
end)

-- Purely visual: beam a prop's world point while its card is hovered so the boss
-- can tell which placed thing the card is. No server round-trip.
RegisterNUICallback("management:highlightProp", function(d, cb)
    if SetPropHighlight then SetPropHighlight(d.propId, d.on) end
    cb({})
end)

RegisterNUICallback("management:placeSeat", function(d, cb)
    CloseNUI()
    cb({})
    StartSeatPlacement(d.id)
    OpenManagement(d.id, "seating")
end)

RegisterNUICallback("management:placeNpcSpawn", function(d, cb)
    CloseNUI()
    cb({})
    StartNpcSpawnPlacement(d.id)
    OpenManagement(d.id, "stations")
end)

-- Virtual point anchors (the shell itself is placed from the ADMIN panel only).
RegisterNUICallback("management:placeVirtualPoint", function(d, cb)
    CloseNUI()
    cb({})
    StartVirtualPointPlacement(d.id, d.target)
    OpenManagement(d.id, "virtual")
end)
