-- =============================================
--  modules/sales | client.lua
--  Opens the staff POS register NUI, relays its order callbacks, and hosts the
--  customer-side payment confirm (a server-awaited prompt that ALWAYS answers).
-- =============================================

function OpenRegister(restaurantId)
    local data = lib.callback.await("pickle_restaurants:sales:getRegister", false, { id = restaurantId })
    if not data or not data.ok then return ShowNotification((data and data.error) or _L("sales_no_work")) end
    OpenNUI("register", data)
end

-- Every POS action returns a fresh register payload — re-render it in place.
local function relayOrder(event)
    RegisterNUICallback(event, function(d, cb)
        local res = lib.callback.await("pickle_restaurants:" .. event, false, d)
        if res and res.error then ShowNotification(res.error) end
        if res and res.tickets then
            SendNUIMessage({ action = "setView", view = "register", data = res })
        end
        cb(res or {})
    end)
end
relayOrder("sales:createOrder")
relayOrder("sales:completeOrder")
relayOrder("sales:cancelOrder")

-- ─── customer payment confirm ────────────────────────────────────────────────
-- The server awaits this while the cashier's register shows "waiting". The
-- promise is GUARANTEED to resolve: Accept/Decline buttons, the NUI's own 30s
-- countdown, a view-close watcher (ESC closes panels without telling anyone),
-- and a 35s belt-and-suspenders timeout.

local paySettle = nil -- settle(answer): resolves the pending prompt exactly once

RegisterNUICallback("sales:payChoice", function(d, cb)
    if paySettle then paySettle(d and d.accept == true) end
    cb({})
end)

lib.callback.register("pickle_restaurants:sales:confirmCharge", function(data)
    if NUIView ~= "none" then return false end -- busy in another panel → auto-decline
    local p, settled = promise.new(), false
    local function settle(answer)
        if settled then return end
        settled = true
        paySettle = nil
        p:resolve(answer == true)
    end
    paySettle = settle
    OpenNUI("payconfirm", data)

    -- ESC (the generic panel-close) kills the view without answering — watch for it.
    CreateThread(function()
        while not settled and NUIView == "payconfirm" do Wait(100) end
        settle(false)
    end)
    SetTimeout(35000, function() settle(false) end)

    local accepted = Citizen.Await(p)
    if NUIView == "payconfirm" then CloseNUI() end
    return accepted == true
end)
