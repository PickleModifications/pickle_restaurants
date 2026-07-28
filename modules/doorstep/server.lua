-- =============================================
--  modules/doorstep | server.lua
--  Answers ONE question for the delivery client: "is this order's drop point an
--  admin-placed delivery door, and where is it?" — so the driver's client can run
--  the knock / hand-off sequence (modules/doorstep/client.lua) before completing.
--
--  It grants nothing. Completion is still `sales:completeOrder`, with all of its
--  own claim + distance + fulfilment checks; this only tells a client whether to
--  play a doorstep scene first. A forged answer would buy an attacker an animation.
-- =============================================

lib.callback.register("pickle_restaurants:doorstep:point", function(src, d)
    local rid, oid = tonumber(d and d.rid), tonumber(d and d.orderId)
    if not (rid and oid) then return nil end
    local o = OrderCache[rid] and OrderCache[rid][oid]
    if not o or o.status ~= "open" or o.order_type ~= "delivery" then return nil end
    -- Only the assigned driver gets the doorstep — the sequence spawns a ped and
    -- locks the player into animations, which nobody else's client should be told
    -- to do on this order's behalf.
    if not o.driver_identifier or o.driver_identifier ~= GetIdentifier(src) then return nil end

    local t = DeliveryTargets[oid]
    if not (t and t.door) then return nil end -- a plain coordinate drop: no door
    local prop = PropCache[t.door]
    if not prop or prop.prop_type ~= "delivery_door" then return nil end

    return {
        x = prop.x + 0.0, y = prop.y + 0.0, z = prop.z + 0.0,
        heading = (prop.heading or 0.0) + 0.0,
        name = o.customer_name,
    }
end)

-- DEBUG. Watch the hand-off without a delivery behind it: no ticket, no assigned
-- driver, nothing in your inventory to hand over — just the scene, so the timings
-- in the client's DOOR table can be tuned in one command instead of by placing an
-- order and driving it. Grants nothing: it plays an animation and spawns a ped on
-- the caller's own client (see doorstep/client.lua), exactly as a real hand-off
-- would, and never touches an order.
--
-- Uses the nearest placed delivery door when you're standing AT one (within the
-- client's own DOOR.reach, so the scene can't refuse the point this command just
-- handed it), and what you see is then that door's real facing. Otherwise it
-- rehearses a doorway 1.5m in front of you, facing back at you — the way a door
-- prop's heading points OUT of its doorway — so the scene plays anywhere.
local DEBUG_NEAR = 6.0
RegisterCommand("pickle_doorstep", function(src)
    if src == 0 or not IsPlayerAdmin(src) then return end
    local ped = GetPlayerPed(src)
    local pos = ped ~= 0 and GetEntityCoords(ped)
    if not pos then return end

    local best, bestD
    for propId, prop in pairs(PropCache) do
        if prop.prop_type == "delivery_door" then
            local d = #(pos - vector3(prop.x + 0.0, prop.y + 0.0, prop.z + 0.0))
            if not bestD or d < bestD then best, bestD = propId, d end
        end
    end

    -- The restaurant the rehearsal "delivers" for — it brands the bag prop, so a
    -- debug run shows the same packaging a real one would. A door belongs to one;
    -- otherwise take whichever restaurant is nearest the caller.
    local function nearestRestaurant()
        local rid, rd
        for id, r in pairs(RestaurantCache) do
            local c = r.counter
            if c and c.x then
                local d = #(pos - vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0))
                if not rd or d < rd then rid, rd = id, d end
            end
        end
        return rid
    end

    if best and bestD <= DEBUG_NEAR then
        local prop = PropCache[best]
        return TriggerClientEvent("pickle_restaurants:doorstep:debug", src, {
            prop = best, rid = prop.restaurant_id,
            x = prop.x + 0.0, y = prop.y + 0.0, z = prop.z + 0.0,
            heading = (prop.heading or 0.0) + 0.0,
        })
    end

    -- no door nearby: a doorway conjured in front of the caller, facing them
    local h   = GetEntityHeading(ped) or 0.0
    local rad = math.rad(h)
    local fx, fy = -math.sin(rad), math.cos(rad)
    TriggerClientEvent("pickle_restaurants:doorstep:debug", src, {
        fake = true, rid = nearestRestaurant(),
        x = pos.x + fx * 1.5, y = pos.y + fy * 1.5, z = pos.z,
        heading = (h + 180.0) % 360.0,
    })
end, false)
