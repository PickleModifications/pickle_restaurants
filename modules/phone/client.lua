-- ─────────────────────────────────────────────────────────────────────────────
-- modules/phone (client) — companion app host glue + world-side features
--
-- Three jobs:
--   1. Register the "Pickle Eats" custom app with whichever phone the server runs
--      (points its iframe at our built nui/phone.html) and re-register when that
--      phone restarts.
--   2. Relay every phone NUI action (POSTed by the iframe to this resource) to the
--      matching server callback, and PUSH server events back into the iframe via the
--      phone's app-message export (a web iframe can't RegisterNetEvent).
--   3. The world side the web app can't do: the live driver GPS blip + the driver's
--      position ping loop, the private-booth teleport, and kitchen backup alerts.
--
-- NOTHING here talks to a specific phone resource — that all lives in bridge/phone/*,
-- which defines the PhoneApp table (Register / Send / Notify / Number). A server with
-- no supported phone installed loads no bridge at all, so PhoneApp is nil and every
-- call site below no-ops.
-- ─────────────────────────────────────────────────────────────────────────────

-- Registering the app is the BRIDGE's job, not this module's — the phones disagree
-- about which side it even happens on (lb-phone: client, Quasar: server), so there's
-- nothing phone-agnostic left to do here.

-- Whether live server→app pushes work on the phone in play. Quasar publishes no
-- Lua→iframe emitter, so its bridge may answer false and the app polls instead.
RegisterNUICallback("phone:pushSupported", function(_, cb)
    cb({ supported = not (PhoneApp and PhoneApp.PushSupported) or PhoneApp.PushSupported() })
end)

-- Push a message into the app iframe. Phones forward the WHOLE table into the page as
-- a window `message`, so we flatten `action` into the payload — useNuiEvent matches on
-- `.action` and the React handlers read the sibling fields (d.rid, d.orders …).
local function ToApp(action, payload)
    if not PhoneApp then return end
    payload = payload or {}
    payload.action = action
    PhoneApp.Send(payload)
end

-- ─── NUI relays ───────────────────────────────────────────────────────────────
-- The iframe's fetchNui("phone:x") POSTs to https://pickle_restaurants/phone:x, so
-- a plain RegisterNUICallback here receives it. Each relay just forwards to the
-- server callback of the same-ish name and resolves the promise with the result.
local function relay(serverCb)
    return function(d, cb)
        cb(lib.callback.await(serverCb, false, d or {}) or {})
    end
end

-- Customer surfaces
RegisterNUICallback("phone:home", function(d, cb)
    d = d or {}
    local c = GetEntityCoords(PlayerPedId())
    d.coords = { x = c.x, y = c.y, z = c.z }   -- for distance sort + delivery address
    cb(lib.callback.await("pickle_restaurants:phone:home", false, d) or {})
end)
RegisterNUICallback("phone:menu",             relay("pickle_restaurants:phone:menu"))
RegisterNUICallback("phone:saveFavorite",     relay("pickle_restaurants:phone:saveFavorite"))
RegisterNUICallback("phone:deleteFavorite",   relay("pickle_restaurants:phone:deleteFavorite"))
RegisterNUICallback("phone:submitReview",     relay("pickle_restaurants:phone:submitReview"))
RegisterNUICallback("phone:reserve",          relay("pickle_restaurants:phone:reserve"))
RegisterNUICallback("phone:reserveAvailability", relay("pickle_restaurants:phone:reserveAvailability"))
RegisterNUICallback("phone:cancelReservation",relay("pickle_restaurants:phone:cancelReservation"))
RegisterNUICallback("phone:myReservations",   relay("pickle_restaurants:phone:myReservations"))
RegisterNUICallback("phone:leaderboard",      relay("pickle_restaurants:phone:leaderboard"))
-- One-shot SEED for the in-app delivery map (last known driver position).
-- The map is otherwise live-events-only, so re-opening a ticket mid-delivery drew
-- nothing until the next broadcast. Server-gated to the order's own customer.
RegisterNUICallback("phone:trackOrder",       relay("pickle_restaurants:phone:trackOrder"))

-- Placing an order: inject live coords (delivery drop / distance).
RegisterNUICallback("phone:placeOrder", function(d, cb)
    d = d or {}
    local c = GetEntityCoords(PlayerPedId())
    d.coords = { x = c.x, y = c.y, z = c.z }
    -- nil on phones that only expose the number server-side (Quasar) — the server
    -- falls back to PhoneAppNumber(src) in that case.
    if PhoneApp then d.phone = PhoneApp.Number() end
    cb(lib.callback.await("pickle_restaurants:phone:placeOrder", false, d) or {})
end)

-- Staff
local ClockedRid = nil
RegisterNUICallback("phone:shiftStatus", relay("pickle_restaurants:phone:shiftStatus"))
RegisterNUICallback("phone:clockIn", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:phone:clockIn", false, d or {})
    if res and res.ok then ClockedRid = tonumber(d.id) end
    cb(res or {})
end)
RegisterNUICallback("phone:clockOut", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:phone:clockOut", false, d or {})
    if res and res.ok then ClockedRid = nil end
    cb(res or {})
end)
RegisterNUICallback("phone:startDelivery", relay("pickle_restaurants:phone:startDelivery"))
RegisterNUICallback("phone:cancelDelivery", relay("pickle_restaurants:phone:cancelDelivery"))

-- Delivery chat (both sides use the same two callbacks; the server decides which side
-- you are and rejects anyone who is neither).
RegisterNUICallback("phone:chatHistory", relay("pickle_restaurants:phone:chatHistory"))
RegisterNUICallback("phone:chatSend",    relay("pickle_restaurants:phone:chatSend"))

-- Set Waypoint. NOT a plain relay: the server only hands back the coordinates (it
-- can't set a waypoint on our behalf), so this one resolves the callback and then
-- does the client-side work itself.
RegisterNUICallback("phone:setWaypoint", function(data, cb)
    local res = lib.callback.await("pickle_restaurants:phone:deliveryTarget", false, data)
    if not res or not res.ok then cb(res or { ok = false }); return end
    SetNewWaypoint(res.x + 0.0, res.y + 0.0)
    ShowNotification(_L("delivery_waypoint_set", tostring(res.ticket or "?")))
    cb({ ok = true })
end)

-- KDS complete/cancel reuse the existing sales callbacks (server perm-gated).
RegisterNUICallback("phone:completeOrder", relay("pickle_restaurants:sales:completeOrder"))
RegisterNUICallback("phone:cancelOrder",   relay("pickle_restaurants:sales:cancelOrder"))
-- KDS ticket seed (public, display-safe + fulfil flags) — live updates ride the
-- sales:orders push forwarded to the app above.
-- NOT a plain relay: the seed has to carry `me` too, exactly like the broadcast below.
-- Without it a delivery already claimed by US reads as someone else's ("With <name>",
-- no Cancel) until the next SyncOrders push happens to arrive.
RegisterNUICallback("phone:tickets", function(data, cb)
    local res = lib.callback.await("pickle_restaurants:register:getPublic", false, data or {})
    res = res or {}
    res.me = GetPlayerServerId(PlayerId())
    cb(res)
end)

-- Owner tools reuse the existing management callbacks (all HasPerm-gated server-side).
RegisterNUICallback("phone:mgmtData",       relay("pickle_restaurants:management:getData"))
RegisterNUICallback("phone:saveMenuItem",   relay("pickle_restaurants:management:saveMenuItem"))
RegisterNUICallback("phone:deleteMenuItem", relay("pickle_restaurants:management:deleteMenuItem"))
RegisterNUICallback("phone:hire",           relay("pickle_restaurants:management:hire"))
RegisterNUICallback("phone:fire",           relay("pickle_restaurants:management:fire"))
RegisterNUICallback("phone:setGrade",       relay("pickle_restaurants:management:setGrade"))
RegisterNUICallback("phone:setCommission",  relay("pickle_restaurants:management:setCommission"))
RegisterNUICallback("phone:buyStock",       relay("pickle_restaurants:management:buyStock"))
RegisterNUICallback("phone:deposit",        relay("pickle_restaurants:management:deposit"))
RegisterNUICallback("phone:withdraw",       relay("pickle_restaurants:management:withdraw"))
RegisterNUICallback("phone:analytics",      relay("pickle_restaurants:phone:analytics"))
RegisterNUICallback("phone:promos",         relay("pickle_restaurants:phone:promos"))
RegisterNUICallback("phone:savePromo",      relay("pickle_restaurants:phone:savePromo"))
RegisterNUICallback("phone:deletePromo",    relay("pickle_restaurants:phone:deletePromo"))

-- ─── live order feed → the app iframe ────────────────────────────────────────
-- The server broadcasts open tickets to everyone via sales:orders. Forward each to
-- the app; the React side filters by the rid(s) it currently cares about (a KDS
-- board, or a customer tracking their own ticket).
RegisterNetEvent("pickle_restaurants:sales:orders", function(rid, orders)
    -- `me` lets the Work screen tell OUR claimed delivery from someone else's: the
    -- ticket list is broadcast to every client, so the claim carries a server id and
    -- the app compares it against this. (The server re-checks by identifier anyway.)
    ToApp("orders", { rid = rid, orders = orders, me = GetPlayerServerId(PlayerId()) })

    -- Kitchen backup alert: while clocked in, warn once when the queue crosses the
    -- threshold (rising edge only, so it doesn't nag every 750ms refresh tick).
    if ClockedRid == rid then
        local n = #orders
        if n >= BACKUP_THRESHOLD and (LastQueue or 0) < BACKUP_THRESHOLD then
            ShowNotification(_L("phone_queue_backup", n))
            ToApp("backup", { rid = rid, count = n })
        end
        LastQueue = n
    end
end)

-- ─── delivery chat push ──────────────────────────────────────────────────────
-- One message, to both parties. The app appends it to whatever thread is open (and
-- flags it unread if that ticket's chat isn't on screen).
RegisterNetEvent("pickle_restaurants:phone:chat", function(d)
    ToApp("chat", d)
end)

-- ─── theme push ──────────────────────────────────────────────────────────────
-- The admin panel changed the ONE global phone theme — forward the new seed to the
-- app so an open phone reskins live (otherwise it lands on the next home refresh).
RegisterNetEvent("pickle_restaurants:phone:pushTheme", function(theme)
    ToApp("theme", { theme = theme })
end)

-- ─── promotions push ─────────────────────────────────────────────────────────
RegisterNetEvent("pickle_restaurants:phone:pushPromo", function(p)
    ToApp("promo", p)
    if PhoneApp then PhoneApp.Notify(p.title, p.content) end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- DELIVERY — driver ping loop + customer GPS blip
-- ─────────────────────────────────────────────────────────────────────────────
local DRIVER_PING_MS = 3000

-- ─── /pickle_delivery_debug ───────────────────────────────────────────────────
-- The delivery chain is four hops across two clients and the server (driver ping
-- net event → server relay gate → customer event → app iframe), and every one of
-- them fails SILENTLY by design. This toggle
-- prints a one-liner at each hop so a broken link is obvious from F8. Run it on the
-- DRIVER for the send side, on the CUSTOMER for the receive side, and
-- `pickle_delivery_debug` on the server console for the relay gate.
local DeliveryDebug = false
local function ddbg(fmt, ...)
    if not DeliveryDebug then return end
    print(("[delivery] " .. fmt):format(...))
end

RegisterCommand("pickle_delivery_debug", function()
    DeliveryDebug = not DeliveryDebug
    print(("[delivery] client debug %s"):format(DeliveryDebug and "ON" or "OFF"))
end, false)


-- How far the driver must get from the drop-off before the 12m ARRIVAL check (which
-- ends the telemetry loop) is allowed to trigger. Comfortably above 12m so leaving
-- and returning can't chatter the two thresholds. TUNE IN-GAME.
local ARRIVE_ARM = 40.0

-- One generation per accepted delivery: a newly accepted run supersedes the previous
-- thread instead of leaving both pinging (the old loop just falls out on its next tick).
local DriveGen = 0

-- Driver side: begin pinging our position to the waiting customer's in-app map.
RegisterNetEvent("pickle_restaurants:phone:beginDriving", function(d)
    if not d or not d.orderId then return end
    local target = d.target
    local rid = d.rid
    -- No target (a ticket placed before dest_x/dest_y persisted, or a customer whose
    -- coords were never captured) = no waypoint and no arrival check. We do NOT invent
    -- a destination; the position pings still run, so the customer's map still works.
    local hasTarget = target ~= nil and target.x ~= nil
    if hasTarget then
        SetNewWaypoint(target.x + 0.0, target.y + 0.0)
        ShowNotification(_L("delivery_accepted"))
        ddbg("beginDriving order %s: waypoint set (%.1f, %.1f)", tostring(d.orderId), target.x + 0.0, target.y + 0.0)
    else
        ddbg("beginDriving order %s: TARGET IS NIL — no waypoint set (driver marker still pings)", tostring(d.orderId))
    end
    DriveGen = DriveGen + 1
    local myGen = DriveGen
    CreateThread(function()
        local since = GetGameTimer()
        -- The arrival check below ENDS this loop, so it must not be armed while the
        -- driver is still standing at the drop-off — which happens whenever the run is
        -- accepted at the destination, and ALWAYS when a player delivers to themself
        -- (driver ped == customer ped, distance 0). Unarmed, the loop fired one ping
        -- and died, so the customer's map only ever drew if it happened to be mounted
        -- for that single tick. Arm it only once the driver has genuinely left.
        local armed = false
        while myGen == DriveGen and GetGameTimer() - since < 20 * 60 * 1000 do -- give up after 20 min
            local c = GetEntityCoords(PlayerPedId())
            TriggerServerEvent("pickle_restaurants:phone:driverPing", {
                orderId = d.orderId, rid = rid, x = c.x, y = c.y })
            ddbg("ping sent order %s rid %s (%.1f, %.1f)", tostring(d.orderId), tostring(rid), c.x, c.y)

            if hasTarget then
                local away = #(vector2(c.x, c.y) - vector2(target.x, target.y))
                if not armed then
                    -- ARRIVE_ARM > the 12m arrival radius, so leaving and coming back
                    -- can't chatter the two thresholds against each other.
                    if away > ARRIVE_ARM then
                        armed = true
                        ddbg("order %s: arrival check ARMED (%.0fm from drop-off)", tostring(d.orderId), away)
                    end
                elseif away < 12.0 then
                    ShowNotification(_L("delivery_arrived"))
                    ddbg("order %s: arrived — telemetry loop ending", tostring(d.orderId))
                    break
                end
            end
            Wait(DRIVER_PING_MS)
        end
    end)
end)

-- Customer side: a driver was assigned — start a blip we move on each ping.
local deliveryBlip = nil
RegisterNetEvent("pickle_restaurants:phone:driverAssigned", function(d)
    ShowNotification(_L("delivery_out_for_delivery"))
    ToApp("delivery", { orderId = d.orderId, state = "driving" })
end)
RegisterNetEvent("pickle_restaurants:phone:driverCoords", function(d)
    if not d or not d.x then ddbg("driverCoords received but EMPTY — not forwarded"); return end
    ddbg("driverCoords received order %s (%.1f, %.1f) → forwarded to app", tostring(d.orderId), d.x + 0.0, d.y + 0.0)
    if not deliveryBlip or not DoesBlipExist(deliveryBlip) then
        deliveryBlip = AddBlipForCoord(d.x + 0.0, d.y + 0.0, 0.0)
        SetBlipSprite(deliveryBlip, 477)     -- delivery/scooter-ish icon
        SetBlipColour(deliveryBlip, 5)       -- yellow
        SetBlipScale(deliveryBlip, 0.9)
        SetBlipAsShortRange(deliveryBlip, false)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentSubstringPlayerName(_L("delivery_blip"))
        EndTextCommandSetBlipName(deliveryBlip)
    else
        SetBlipCoords(deliveryBlip, d.x + 0.0, d.y + 0.0, 0.0)
    end
    -- …and into the app iframe, so the in-app Leaflet map moves the same driver
    -- marker the world blip does. The native blip stays exactly as it was.
    ToApp("driverCoords", { orderId = d.orderId, x = d.x + 0.0, y = d.y + 0.0 })
end)

-- The driver gave the run back (cancelled, or left the server). Clear the world blip
-- and tell the app to drop its marker — the ticket goes back to "preparing" until
-- someone else accepts it.
RegisterNetEvent("pickle_restaurants:phone:driverReleased", function(d)
    if deliveryBlip and DoesBlipExist(deliveryBlip) then RemoveBlip(deliveryBlip) end
    deliveryBlip = nil
    ShowNotification(_L("delivery_driver_dropped"))
    ToApp("driverGone", { orderId = d and d.orderId })
end)

-- Driver side: we cancelled our own run — stop the ping loop and clear our waypoint.
RegisterNetEvent("pickle_restaurants:phone:endDriving", function()
    DriveGen = DriveGen + 1   -- supersedes the running loop; it falls out on its next tick
    ClearGpsMultiRoute()
    SetWaypointOff()
    ShowNotification(_L("delivery_cancelled_driver"))
end)

-- Drop the blip when the order is done (server pushes an updated open list without it,
-- but the customer's own tracking view tells us via this app message).
RegisterNUICallback("phone:endDeliveryBlip", function(_, cb)
    if deliveryBlip and DoesBlipExist(deliveryBlip) then RemoveBlip(deliveryBlip) end
    deliveryBlip = nil
    cb({ ok = true })
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- RESERVATIONS — private dining booth teleport (instanced routing bucket)
-- BOOTH: the interior anchor a reservation teleports into. TUNE IN-GAME.
-- ─────────────────────────────────────────────────────────────────────────────
local BOOTH = { x = -1201.5, y = -895.0, z = 12.9, heading = 35.0 }
local boothReturn = nil

RegisterNUICallback("phone:enterBooth", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:phone:enterBooth", false, d or {})
    if not res or not res.ok then cb(res or {}) return end
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    boothReturn = { x = c.x, y = c.y, z = c.z, h = GetEntityHeading(ped) }
    DoScreenFadeOut(400); Wait(450)
    SetEntityCoords(ped, BOOTH.x, BOOTH.y, BOOTH.z, false, false, false, false)
    SetEntityHeading(ped, BOOTH.heading)
    Wait(300); DoScreenFadeIn(400)
    ShowNotification(_L("reserve_booth_welcome"))
    cb(res)
end)

RegisterNUICallback("phone:leaveBooth", function(_, cb)
    local res = lib.callback.await("pickle_restaurants:phone:leaveBooth", false, {})
    local ped = PlayerPedId()
    DoScreenFadeOut(400); Wait(450)
    if boothReturn then
        SetEntityCoords(ped, boothReturn.x, boothReturn.y, boothReturn.z, false, false, false, false)
        SetEntityHeading(ped, boothReturn.h)
        boothReturn = nil
    end
    Wait(300); DoScreenFadeIn(400)
    cb(res or { ok = true })
end)

-- Tunables (TUNE IN-GAME).
BACKUP_THRESHOLD = 6   -- open tickets that trip the "kitchen backing up" alert
