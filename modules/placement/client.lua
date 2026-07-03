-- =============================================
--  modules/placement | client.lua
--  Drives the gizmo (modules/gizmo) to place the four station props and the
--  counter point, then persists them through the server.
-- =============================================

PLACEABLE_MODELS = {
    soda_machine = "pickle_soda_fountain_01",
    fryer        = "pickle_fryer_01",
    stovetop     = "pickle_stovetop_01",
    kitchen_prep = "pickle_kitchen_prep_01",
}

function StartPropPlacement(restaurantId, propType)
    local model = PLACEABLE_MODELS[propType]
    if not model then return ShowNotification("Unknown station type.") end
    Wait(250) -- let the NUI fully release focus before the gizmo takes input
    local result = StartGizmoEditor({ model = GetHashKey(model), enableCancel = true, deleteEntity = true })
    if not result or not result.position then return end
    local res = lib.callback.await("pickle_restaurants:placement:saveProp", false, {
        restaurant_id = restaurantId,
        prop_type     = propType,
        model         = model,
        x = result.position.x, y = result.position.y, z = result.position.z,
        heading = (result.rotation and result.rotation.z) or 0.0,
    })
    if res and res.ok then
        ShowNotification("Station placed.")
    else
        ShowNotification((res and res.error) or "Failed to place station.")
    end
end

-- The ghost ped shown while positioning a seat anchor, so the admin can see where
-- (and which way) a player will be seated. Reuses one of the NPC-customer models.
local SEAT_PREVIEW_PED = "a_m_y_business_01"

-- Place an invisible seat anchor: the gizmo shows a ghost person; we persist only
-- the point + facing. No model/prop is spawned at runtime — players sit on the
-- restaurant's existing furniture here.
function StartSeatPlacement(restaurantId)
    Wait(250)
    local result = StartGizmoEditor({ isPed = true, model = SEAT_PREVIEW_PED, enableCancel = true, deleteEntity = true })
    if not result or not result.position then return end
    local res = lib.callback.await("pickle_restaurants:placement:saveSeat", false, {
        restaurant_id = restaurantId,
        x = result.position.x, y = result.position.y, z = result.position.z,
        heading = (result.rotation and result.rotation.z) or 0.0,
    })
    if res and res.ok then
        ShowNotification("Seat placed.")
    else
        ShowNotification((res and res.error) or "Failed to place seat.")
    end
end

function StartCounterPlacement(restaurantId)
    Wait(250)
    local result = StartGizmoEditor({ model = "prop_till_01", enableCancel = true, deleteEntity = true })
    if not result or not result.position then return end
    local res = lib.callback.await("pickle_restaurants:placement:saveCounter", false, {
        restaurant_id = restaurantId,
        x = result.position.x, y = result.position.y, z = result.position.z,
        heading = (result.rotation and result.rotation.z) or 0.0,
    })
    if res and res.ok then
        ShowNotification("Counter set.")
    else
        ShowNotification((res and res.error) or "Failed to set counter.")
    end
end
