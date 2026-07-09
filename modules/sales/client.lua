-- =============================================
--  modules/sales | client.lua
--  Opens the staff POS register NUI, relays its order callbacks, and hosts the
--  customer-side payment confirm (a server-awaited prompt that ALWAYS answers).
-- =============================================

-- The restaurant whose register this client currently has open (nil = none). Used
-- to decide whether an incoming live-ticket broadcast applies to us.
local OpenRid = nil

function OpenRegister(restaurantId)
    local data = lib.callback.await("pickle_restaurants:sales:getRegister", false, { id = restaurantId })
    if not data or not data.ok then return ShowNotification((data and data.error) or _L("sales_no_work")) end
    OpenRid = restaurantId
    OpenNUI("register", data)
end

-- Live ticket list: the server broadcasts the fresh open-order list whenever it
-- changes (create/cancel/complete, from ANY cashier). We apply it only if this
-- client has that restaurant's register open, and only ever update the ticket
-- LIST — never the whole panel — so the catalog/cart are untouched and nothing
-- flickers. This is the single source of truth for what tickets are shown.
RegisterNetEvent("pickle_restaurants:sales:orders", function(rid, orders)
    if OpenRid == rid and NUIView == "register" then
        SendNUIMessage({ action = "orders", orders = orders })
    end
end)

-- POS actions just report ok/error; the ticket list refreshes itself via the
-- broadcast above. The await carries a timeout (not `false`) so a server-side
-- failure can never leave the register spinning — it returns nil, the NUI
-- un-busies, and the cashier can retry.
local function relayOrder(event)
    RegisterNUICallback(event, function(d, cb)
        -- Longer than the server's 35s customer-confirm window so a legitimately
        -- slow confirm never trips it; short enough to recover from a real hang.
        local res = lib.callback.await("pickle_restaurants:" .. event, 45000, d)
        if res and res.error then ShowNotification(res.error) end
        -- Update the acting cashier's ticket list straight from the response (the
        -- broadcast covers coworkers) so the panel never depends on the round-trip.
        if res and res.tickets then SendNUIMessage({ action = "orders", orders = res.tickets }) end
        -- Re-assert focus after every action: an order flow (receipt add/remove,
        -- the customer confirm) can drop the NUI cursor, and then the NEXT click —
        -- charging a new order, cancelling the next ticket — silently no-ops. Keep
        -- the panel clickable so back-to-back create/cancel/create always works.
        if NUIView == "register" then
            SetNuiFocus(true, true)
            SetNuiFocusKeepInput(false)
        end
        cb(res or { ok = false })
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
