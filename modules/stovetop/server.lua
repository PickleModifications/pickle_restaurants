-- =============================================
--  modules/stovetop | server.lua
--  Server-side stovetop-station state (more coming). Today: authoritative
--  open/closed state for the oven doors. State is kept only in the in-memory
--  PropCache (so it rides the normal sync to clients and to late joiners) — it
--  is intentionally NOT persisted, so doors just reset closed on restart.
-- =============================================

lib.callback.register("pickle_restaurants:doors:toggle", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop or prop.prop_type ~= "stovetop" then return { ok = false } end
    if not HasPerm(prop.restaurant_id, src, "cook") then return { ok = false, error = _L("no_work_here") } end

    local door = tonumber(d.door)
    if door ~= 1 and door ~= 2 then return { ok = false } end

    prop.metadata = prop.metadata or {}
    local doors = prop.metadata.doors or {}
    doors[1] = doors[1] == true
    doors[2] = doors[2] == true
    doors[door] = not doors[door]
    prop.metadata.doors = doors -- in-memory only; rides the sync payload

    TriggerClientEvent("pickle_restaurants:doors:set", -1, prop.id, door, doors[door])
    -- drive the bake gate: closing a door starts baking its cavity, opening pauses it
    TriggerEvent("pickle_restaurants:oven:gate", prop.id, door, doors[door])
    return { ok = true, open = doors[door] }
end)
