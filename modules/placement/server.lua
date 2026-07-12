-- =============================================
--  modules/placement | server.lua
--  Persists placed station props / counter points; broadcasts spawns.
-- =============================================

local PLACEABLE_MODELS = {
    soda_machine = "pickle_soda_fountain_01",
    fryer        = "pickle_fryer_01",
    stovetop     = "pickle_stovetop_01",
    kitchen_prep = "pickle_kitchen_prep_01",
    -- Self-order kiosk (physical world prop; opens the order NUI, not a station).
    -- Wall-mounted terminal (_01) and free-standing ground kiosk (_02).
    kiosk        = "pickle_kiosk_large_01",
    kiosk_ground = "pickle_kiosk_large_02",
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

-- The station types a virtual point may open. Mirrors PLACEABLE_MODELS' keys —
-- the NUI is untrusted, so the target is whitelisted here.
local VIRTUAL_TARGETS = {
    soda_machine = true, fryer = true, stovetop = true, kitchen_prep = true,
}

-- A virtual point is an INVISIBLE interaction anchor (prop_type "virtual_point"),
-- stored like a seat: no model, just a point + heading. metadata.target names the
-- station type it opens inside the restaurant's virtual kitchen shell. Each row is
-- its own point INSTANCE — the cooking state it holds is keyed by this prop id, so
-- two points for the same station type never share anything.
lib.callback.register("pickle_restaurants:placement:saveVirtualPoint", function(src, d)
    local id = tonumber(d.restaurant_id)
    if not GetRestaurant(id) then return { ok = false, error = _L("placement_no_restaurant") } end
    if not HasPerm(id, src, "manage_props") then return { ok = false, error = _L("no_permission") } end
    if not VIRTUAL_TARGETS[d.target] then return { ok = false, error = _L("placement_invalid_station") } end
    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if not (x and y and z) then return { ok = false } end

    local metadata = { target = d.target }
    local propId = MySQL.insert.await(
        "INSERT INTO pickle_restaurant_props (restaurant_id, prop_type, model, x, y, z, heading, metadata) VALUES (?, 'virtual_point', '', ?, ?, ?, ?, ?)",
        { id, x + 0.0, y + 0.0, z + 0.0, (tonumber(d.heading) or 0.0) + 0.0, json.encode(metadata) })
    if not propId then return { ok = false } end

    local prop = {
        id = propId, restaurant_id = id, prop_type = "virtual_point", model = "",
        x = x + 0.0, y = y + 0.0, z = z + 0.0, heading = (tonumber(d.heading) or 0.0) + 0.0, metadata = metadata,
    }
    PropCache[propId] = prop
    TriggerClientEvent("pickle_restaurants:propPlaced", -1, prop)
    return { ok = true, id = propId }
end)

-- The restaurant's virtual kitchen shell: one per restaurant, stored in
-- metadata.shell. XY is always re-derived from the counter (the blip/center
-- anchor) so the shell can't drift from its restaurant — the admin placement
-- view only chooses height + facing.
lib.callback.register("pickle_restaurants:placement:saveShell", function(src, d)
    local id = tonumber(d.restaurant_id)
    local r = GetRestaurant(id)
    if not r then return { ok = false, error = _L("placement_no_restaurant") } end
    if not IsPlayerAdmin(src) then return { ok = false, error = _L("no_permission") } end
    if not r.counter then return { ok = false, error = _L("place_shell_needs_counter") } end
    local z = tonumber(d.z)
    if not z then return { ok = false } end

    local old = r.metadata and r.metadata.shell
    r.metadata = r.metadata or {}
    r.metadata.shell = {
        x = r.counter.x + 0.0, y = r.counter.y + 0.0,
        z = z + 0.0, heading = (tonumber(d.heading) or 0.0) + 0.0,
    }
    MySQL.update.await("UPDATE pickle_restaurants SET metadata = ? WHERE id = ?", { json.encode(r.metadata), id })
    -- cooking shifts any free-placed virtual items with the shell...
    TriggerEvent("pickle_restaurants:shellMoved", id, old, r.metadata.shell)
    -- ...and any client mid-session inside this shell closes out cleanly.
    TriggerClientEvent("pickle_restaurants:shellMoved", -1, id)
    SyncToClient(-1)
    return { ok = true }
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

-- The per-restaurant NPC customer spawn point (where AI customers appear before
-- walking up to queue). One per restaurant, stored in metadata.npc_spawn like the
-- kitchen shell — a free point + heading. modules/npc_customers folds it into every
-- spawn/state broadcast so clients start the walk-in there instead of a fixed offset
-- back from the counter (which used to bury customers in props and strand them).
lib.callback.register("pickle_restaurants:placement:saveNpcSpawn", function(src, d)
    local id = tonumber(d.restaurant_id)
    local r = GetRestaurant(id)
    if not r then return { ok = false, error = _L("placement_no_restaurant") } end
    if not HasPerm(id, src, "manage_props") then return { ok = false, error = _L("no_permission") } end
    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if not (x and y and z) then return { ok = false } end

    r.metadata = r.metadata or {}
    r.metadata.npc_spawn = { x = x + 0.0, y = y + 0.0, z = z + 0.0, heading = (tonumber(d.heading) or 0.0) + 0.0 }
    MySQL.update.await("UPDATE pickle_restaurants SET metadata = ? WHERE id = ?", { json.encode(r.metadata), id })
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
        if p.restaurant_id == id then list[#list + 1] = PropSummary(p) end
    end
    return list
end)
