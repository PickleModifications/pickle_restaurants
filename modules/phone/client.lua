-- ─────────────────────────────────────────────────────────────────────────────
-- modules/phone (client) — lb-phone app host glue + world-side features
--
-- Three jobs:
--   1. Register the "Pickle Food" custom app with lb-phone (points its iframe at
--      our built nui/phone.html) and re-register on lb-phone restart.
--   2. Relay every phone NUI action (POSTed by the iframe to this resource) to the
--      matching server callback, and PUSH server events back into the iframe via
--      lb-phone's SendCustomAppMessage (a web iframe can't RegisterNetEvent).
--   3. The world side the web app can't do: the live driver GPS blip + the driver's
--      position ping loop, the private-booth teleport, and kitchen backup alerts.
-- ─────────────────────────────────────────────────────────────────────────────

local APP_ID = "pickle_food"
local RESOURCE = GetCurrentResourceName()

-- ─── register with lb-phone ──────────────────────────────────────────────────
local function AddApp()
    if GetResourceState("lb-phone") ~= "started" then return end
    local ok, err = exports["lb-phone"]:AddCustomApp({
        identifier  = APP_ID,
        name        = "Pickle Food",
        description  = "Order food, track delivery, run your restaurant.",
        developer    = "Pickle Modifications",
        defaultApp   = true,          -- ships pre-installed
        size         = 48000,
        ui           = RESOURCE .. "/nui/phone.html",
        icon         = "https://cfx-nui-" .. RESOURCE .. "/nui/phone-icon.svg",
        fixBlur      = true,          -- our CSS uses rem/em (Tailwind)
    })
    if not ok then print(("[pickle_restaurants] AddCustomApp failed: %s"):format(tostring(err))) end
end

CreateThread(function()
    while GetResourceState("lb-phone") ~= "started" do Wait(500) end
    Wait(1000) -- let the AddCustomApp export come up
    AddApp()
end)

AddEventHandler("onResourceStart", function(res)
    if res == "lb-phone" then Wait(1000); AddApp() end
end)

-- Push a message into the app iframe. lb-phone forwards the WHOLE table as a
-- window `message`, so we flatten `action` into the payload — useNuiEvent matches
-- on `.action` and the React handlers read the sibling fields (d.rid, d.orders …).
local function ToApp(action, payload)
    if GetResourceState("lb-phone") ~= "started" then return end
    payload = payload or {}
    payload.action = action
    pcall(function()
        exports["lb-phone"]:SendCustomAppMessage(APP_ID, payload)
    end)
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

-- Placing an order: inject live coords (delivery drop / distance).
RegisterNUICallback("phone:placeOrder", function(d, cb)
    d = d or {}
    local c = GetEntityCoords(PlayerPedId())
    d.coords = { x = c.x, y = c.y, z = c.z }
    if GetResourceState("lb-phone") == "started" then
        d.phone = exports["lb-phone"]:GetEquippedPhoneNumber()
    end
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

-- KDS complete/cancel reuse the existing sales callbacks (server perm-gated).
RegisterNUICallback("phone:completeOrder", relay("pickle_restaurants:sales:completeOrder"))
RegisterNUICallback("phone:cancelOrder",   relay("pickle_restaurants:sales:cancelOrder"))
-- KDS ticket seed (public, display-safe + fulfil flags) — live updates ride the
-- sales:orders push forwarded to the app above.
RegisterNUICallback("phone:tickets",       relay("pickle_restaurants:register:getPublic"))

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
    ToApp("orders", { rid = rid, orders = orders })

    -- Kitchen backup alert: while clocked in, warn once when the queue crosses the
    -- threshold (rising edge only, so it doesn't nag every 750ms refresh tick).
    if ClockedRid == rid then
        local n = #orders
        if n >= BACKUP_THRESHOLD and (LastQueue or 0) < BACKUP_THRESHOLD then
            ShowNotification(("~o~Tickets backing up — %d orders in the queue."):format(n))
            ToApp("backup", { rid = rid, count = n })
        end
        LastQueue = n
    end
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
    if GetResourceState("lb-phone") == "started" then
        pcall(function() exports["lb-phone"]:SendNotification({ app = APP_ID, title = p.title, content = p.content }) end)
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- DELIVERY — driver ping loop + customer GPS blip
-- ─────────────────────────────────────────────────────────────────────────────
local DRIVER_PING_MS = 3000

-- Driver side: begin pinging our position to the waiting customer + route on the map.
RegisterNetEvent("pickle_restaurants:phone:beginDriving", function(d)
    if not d or not d.orderId then return end
    local target = d.target
    local rid = d.rid
    if target and target.x then
        SetNewWaypoint(target.x + 0.0, target.y + 0.0)
        ShowNotification("~g~Delivery accepted.~s~ Route set to the customer.")
    end
    CreateThread(function()
        local since = GetGameTimer()
        while GetGameTimer() - since < 20 * 60 * 1000 do -- give up after 20 min
            local c = GetEntityCoords(PlayerPedId())
            TriggerServerEvent("pickle_restaurants:phone:driverPing", {
                orderId = d.orderId, rid = rid, x = c.x, y = c.y })
            if target and target.x and #(vector2(c.x, c.y) - vector2(target.x, target.y)) < 12.0 then
                ShowNotification("~g~You've reached the customer.~s~ Complete the order at the register / hand-off.")
                break
            end
            Wait(DRIVER_PING_MS)
        end
    end)
end)

-- Customer side: a driver was assigned — start a blip we move on each ping.
local deliveryBlip = nil
RegisterNetEvent("pickle_restaurants:phone:driverAssigned", function(d)
    ShowNotification("~g~Your order is out for delivery.~s~ Track the driver on your map.")
    ToApp("delivery", { orderId = d.orderId, state = "driving" })
end)
RegisterNetEvent("pickle_restaurants:phone:driverCoords", function(d)
    if not d or not d.x then return end
    if not deliveryBlip or not DoesBlipExist(deliveryBlip) then
        deliveryBlip = AddBlipForCoord(d.x + 0.0, d.y + 0.0, 0.0)
        SetBlipSprite(deliveryBlip, 477)     -- delivery/scooter-ish icon
        SetBlipColour(deliveryBlip, 5)       -- yellow
        SetBlipScale(deliveryBlip, 0.9)
        SetBlipAsShortRange(deliveryBlip, false)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentSubstringPlayerName("Your delivery")
        EndTextCommandSetBlipName(deliveryBlip)
    else
        SetBlipCoords(deliveryBlip, d.x + 0.0, d.y + 0.0, 0.0)
    end
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
    ShowNotification("~g~Welcome to your private table.~s~ Leave from the app when you're done.")
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
