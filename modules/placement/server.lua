-- =============================================
--  modules/placement | server.lua
--  Persists placed station props / counter points; broadcasts spawns.
-- =============================================

local PLACEABLE_MODELS = {
    soda_machine = "pickle_soda_fountain_01",
    fryer        = "pickle_fryer_01",
    stovetop     = "pickle_stovetop_01",
    kitchen_prep = "pickle_kitchen_prep_01",
}

lib.callback.register("pickle_restaurants:placement:saveProp", function(src, d)
    local id = tonumber(d.restaurant_id)
    if not GetRestaurant(id) then return { ok = false, error = _L("placement_no_restaurant") } end
    if not HasPerm(id, src, "manage_props") then return { ok = false, error = _L("no_permission") } end
    if PLACEABLE_MODELS[d.prop_type] ~= d.model then return { ok = false, error = _L("placement_invalid_station") } end

    local propId = MySQL.insert.await(
        "INSERT INTO pickle_restaurant_props (restaurant_id, prop_type, model, x, y, z, heading) VALUES (?, ?, ?, ?, ?, ?, ?)",
        { id, d.prop_type, d.model, d.x + 0.0, d.y + 0.0, d.z + 0.0, (d.heading or 0.0) + 0.0 })
    if not propId then return { ok = false } end

    local prop = {
        id = propId, restaurant_id = id, prop_type = d.prop_type, model = d.model,
        x = d.x + 0.0, y = d.y + 0.0, z = d.z + 0.0, heading = (d.heading or 0.0) + 0.0, metadata = {},
    }
    PropCache[propId] = prop
    TriggerClientEvent("pickle_restaurants:propPlaced", -1, prop)
    return { ok = true, id = propId }
end)

-- A seat is an INVISIBLE sit anchor (prop_type "seat"): stored in the same props
-- table as stations, but nothing spawns in the world — players sit on the
-- restaurant's own furniture at this point/heading. No model is validated (there's
-- no runtime prop); the placement preview is a ghost ped, position + heading only.
lib.callback.register("pickle_restaurants:placement:saveSeat", function(src, d)
    local id = tonumber(d.restaurant_id)
    if not GetRestaurant(id) then return { ok = false, error = _L("placement_no_restaurant") } end
    if not HasPerm(id, src, "manage_props") then return { ok = false, error = _L("no_permission") } end

    local propId = MySQL.insert.await(
        "INSERT INTO pickle_restaurant_props (restaurant_id, prop_type, model, x, y, z, heading) VALUES (?, 'seat', '', ?, ?, ?, ?)",
        { id, d.x + 0.0, d.y + 0.0, d.z + 0.0, (d.heading or 0.0) + 0.0 })
    if not propId then return { ok = false } end

    local prop = {
        id = propId, restaurant_id = id, prop_type = "seat", model = "",
        x = d.x + 0.0, y = d.y + 0.0, z = d.z + 0.0, heading = (d.heading or 0.0) + 0.0, metadata = {},
    }
    PropCache[propId] = prop
    TriggerClientEvent("pickle_restaurants:propPlaced", -1, prop)
    return { ok = true, id = propId }
end)

lib.callback.register("pickle_restaurants:placement:saveCounter", function(src, d)
    local id = tonumber(d.restaurant_id)
    if not GetRestaurant(id) then return { ok = false, error = _L("placement_no_restaurant") } end
    if not HasPerm(id, src, "manage_props") then return { ok = false, error = _L("no_permission") } end

    local counter = { x = d.x + 0.0, y = d.y + 0.0, z = d.z + 0.0, heading = (d.heading or 0.0) + 0.0 }
    MySQL.update.await("UPDATE pickle_restaurants SET counter = ? WHERE id = ?", { json.encode(counter), id })
    RestaurantCache[id].counter = counter
    SyncToClient(-1) -- rebuild counter interaction + blip everywhere
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:placement:removeProp", function(src, d)
    local propId = tonumber(d.id)
    local prop = PropCache[propId]
    if not prop then return { ok = false } end
    if not HasPerm(prop.restaurant_id, src, "manage_props") then return { ok = false, error = _L("no_permission") } end
    MySQL.update.await("DELETE FROM pickle_restaurant_props WHERE id = ?", { propId })
    PropCache[propId] = nil
    TriggerClientEvent("pickle_restaurants:propRemoved", -1, propId)
    -- server-side notice so other modules can release state tied to this prop
    -- (cooking drops any items cooking on it; seating frees its occupancy)
    TriggerEvent("pickle_restaurants:propDeleted", propId)
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:getProps", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_props") then return {} end
    local list = {}
    for _, p in pairs(PropCache) do
        if p.restaurant_id == id then
            list[#list + 1] = { id = p.id, prop_type = p.prop_type, model = p.model }
        end
    end
    return list
end)
