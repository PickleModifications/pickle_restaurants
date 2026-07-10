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
    if not model then return ShowNotification(_L("place_unknown_station")) end
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
        ShowNotification(_L("place_station_placed"))
    else
        ShowNotification((res and res.error) or _L("place_station_fail"))
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
    -- Preview the ghost ped in the SEATED pose at exactly where they'll sit: the
    -- gizmo plays the same looping sit animation the real sit uses and drops the ped
    -- by the sit z-offset, while the SAVED anchor stays the ground point the seating
    -- code expects (result.position adds the offset back). WYSIWYG placement.
    local sitDict, sitAnim = SeatPreviewAnim()
    local result = StartGizmoEditor({
        isPed        = true,
        model        = SEAT_PREVIEW_PED,
        anim         = { dict = sitDict, name = sitAnim },
        coordsOffset = vector3(0.0, 0.0, -SeatSitOffsetZ()),
        enableCancel = true,
        deleteEntity = true,
    })
    if not result or not result.position then return end
    local res = lib.callback.await("pickle_restaurants:placement:saveSeat", false, {
        restaurant_id = restaurantId,
        x = result.position.x, y = result.position.y, z = result.position.z,
        heading = (result.rotation and result.rotation.z) or 0.0,
    })
    if res and res.ok then
        ShowNotification(_L("place_seat_placed"))
    else
        ShowNotification((res and res.error) or _L("place_seat_fail"))
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
        ShowNotification(_L("place_counter_set"))
    else
        ShowNotification((res and res.error) or _L("place_counter_fail"))
    end
end
