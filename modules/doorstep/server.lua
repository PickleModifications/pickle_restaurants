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
