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

-- Clocking in/out from the panel's Dashboard tab. These go to the PHONE module's
-- callbacks on purpose — one ShiftCache, one tip pool, one set of shift rows, so the
-- register dashboard and the phone can never disagree about whether you're on shift.
-- They refresh like any other action, since the dashboard's roster/timer come down in
-- the getData payload.
RegisterNUICallback("management:clockIn",  relayThenRefresh("pickle_restaurants:phone:clockIn"))
RegisterNUICallback("management:clockOut", relayThenRefresh("pickle_restaurants:phone:clockOut"))

-- Plain refresh, no mutation: the Dashboard polls this so its shift timer, ticket
-- queue and roster stay live while the panel sits open.
RegisterNUICallback("management:refresh", function(d, cb)
    local data = d.id and lib.callback.await("pickle_restaurants:management:getData", false, { id = d.id })
    if data and data.ok then
        data.restaurantId = d.id
        return cb(data)
    end
    cb({ ok = false })
end)

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

-- PLACEMENT LIVES IN THE ADMIN PANEL ONLY. Stations, counters, seats, virtual
-- points and the NPC spawn point are all placed from /restaurants by an admin —
-- the boss panel has no Stations tab any more, and the placement/removal server
-- callbacks are gated on IsPlayerAdmin, so a forged `management:*` NUI post has
-- nothing to reach. `manage_props` still governs the Branding tab.
