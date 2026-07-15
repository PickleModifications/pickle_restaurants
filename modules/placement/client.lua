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
    -- The kiosk is a customer-facing SELF-ORDER terminal, not a cooking station:
    -- its interaction opens the order NUI (modules/sales OpenKiosk), and the order
    -- becomes an ordinary kitchen ticket a worker fulfils. Physical-only (no virtual
    -- point — it must be a reachable world prop), so it is NOT in VIRTUAL_TARGETS.
    -- Two body styles: the WALL-mounted terminal (_01, pushed off the wall so it
    -- doesn't bury into it) and a free-standing GROUND kiosk (_02) that sits on the
    -- floor like any other prop. Both are `kiosk`-family props everywhere downstream.
    kiosk        = "pickle_kiosk_large_01",
    kiosk_ground = "pickle_kiosk_large_02",
    -- Customer-facing INFO SCREENS: non-interactable wall props whose branded screen
    -- texture is replaced at runtime by a DUI (modules/screens). The menu board slideshows
    -- what the restaurant sells; the orders board shows tickets in progress, latest first.
    menu_screen   = "pickle_screen_menu_01",
    orders_screen = "pickle_screen_orders_01",
}

-- Wall-mounted props sit flush against the wall the admin aims at, so their origin
-- lands ON the wall face and half the body buries into it. These get pushed back off
-- the wall (toward the placer) by ~half their depth in the gizmo. Ground props place
-- normally (origin on the floor).
local WALL_MOUNTED = { kiosk = true, menu_screen = true, orders_screen = true }

-- Half the model's front-to-back depth (its local Y extent) — how far to nudge a
-- wall-mounted prop off the wall so its BACK rests against it instead of its centre.
local function WallMountDepth(model)
    local hash = GetHashKey(model)
    RequestModel(hash)
    local t = GetGameTimer()
    while not HasModelLoaded(hash) and GetGameTimer() - t < 1000 do Wait(0) end
    local mn, mx = GetModelDimensions(hash)
    if mn and mx then return math.max((mx.y - mn.y) * 0.5, 0.1) end
    return 0.35 -- fallback depth (m) if the model's bounds aren't ready
end

function StartPropPlacement(restaurantId, propType)
    local model = PLACEABLE_MODELS[propType]
    if not model then return ShowNotification(_L("place_unknown_station")) end
    Wait(250) -- let the NUI fully release focus before the gizmo takes input
    local opts = { model = GetHashKey(model), enableCancel = true, deleteEntity = true }
    if WALL_MOUNTED[propType] then opts.wallOffset = WallMountDepth(model) end
    local result = StartGizmoEditor(opts)
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

-- Place the per-restaurant NPC customer spawn point: where AI customers appear
-- before walking up to the counter to queue. A standing ghost ped previews exactly
-- where (and facing which way) a customer will materialise, so admins put it on a
-- clear, reachable spot near the register — the old behaviour spawned them a fixed
-- distance back along the queue line, which often landed inside props and stuck them.
-- Only the point + heading are saved (no runtime prop).
function StartNpcSpawnPlacement(restaurantId)
    Wait(250)
    local result = StartGizmoEditor({
        isPed        = true,
        model        = SEAT_PREVIEW_PED,
        enableCancel = true,
        deleteEntity = true,
    })
    if not result or not result.position then return end
    local res = lib.callback.await("pickle_restaurants:placement:saveNpcSpawn", false, {
        restaurant_id = restaurantId,
        x = result.position.x, y = result.position.y, z = result.position.z,
        heading = (result.rotation and result.rotation.z) or 0.0,
    })
    if res and res.ok then
        ShowNotification(_L("place_npc_spawn_set"))
    else
        ShowNotification((res and res.error) or _L("place_npc_spawn_fail"))
    end
end

-- The small marker prop used to position a virtual point. A virtual point is an
-- invisible, interaction-only anchor (the station spawns in the kitchen shell at
-- runtime), so previewing the whole station prop just buries the spot — a tennis
-- ball marks the exact anchor without hiding what's under it.
local VIRTUAL_PLACE_MODEL = "prop_tennis_ball"

-- Place an invisible virtual point anchor: the gizmo previews a small ball at the
-- anchor (NOT the whole station), and only the point + heading are saved — at
-- runtime the anchor is interaction-only, and the station itself spawns inside the
-- restaurant's kitchen shell when the point is used.
function StartVirtualPointPlacement(restaurantId, target)
    local model = PLACEABLE_MODELS[target]
    if not model then return ShowNotification(_L("place_unknown_station")) end
    Wait(250)
    local result = StartGizmoEditor({ model = GetHashKey(VIRTUAL_PLACE_MODEL), enableCancel = true, deleteEntity = true })
    if not result or not result.position then return end
    local res = lib.callback.await("pickle_restaurants:placement:saveVirtualPoint", false, {
        restaurant_id = restaurantId,
        target        = target,
        x = result.position.x, y = result.position.y, z = result.position.z,
        heading = (result.rotation and result.rotation.z) or 0.0,
    })
    if res and res.ok then
        ShowNotification(_L("place_virtual_placed"))
    else
        ShowNotification((res and res.error) or _L("place_virtual_fail"))
    end
end

-- ─── kitchen shell placement ─────────────────────────────────────────────────
-- The shell's XY is pinned to the restaurant's counter (its blip/center anchor);
-- this view only chooses HEIGHT + facing, so it's a dedicated loop with its own
-- scripted camera rather than the raycast gizmo: scroll moves the shell up/down,
-- arrows rotate it, and the camera tracks the shell so the admin always sees
-- where it sits relative to the restaurant below. The shell model + loader are
-- shared with modules/virtual so the preview and the session build can't drift.
local SHELL_CAM     = { back = -18.0, up = 8.0, fov = 50.0, lookUp = 2.0 } -- framing offsets. TUNE IN-GAME.
local SHELL_Z_STEP  = 2.5 -- meters per scroll notch (x4 with SHIFT)

function StartShellPlacement(restaurantId)
    local rest = GetRestaurantById(restaurantId)
    if not rest or not rest.counter then return ShowNotification(_L("place_shell_needs_counter")) end
    Wait(250) -- let the NUI fully release focus before the loop takes input

    local hash = LoadModelTimeout(VirtualShellModel())
    if not hash then return ShowNotification(_L("virtual_shell_missing")) end

    local c = rest.counter
    local z = (rest.shell and rest.shell.z) or c.z
    local heading = (rest.shell and rest.shell.heading) or 0.0
    local shell = CreateObject(hash, c.x, c.y, z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not shell or not DoesEntityExist(shell) then return end
    FreezeEntityPosition(shell, true)
    SetEntityCollision(shell, false, false)

    local cam = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA",
        c.x, c.y - SHELL_CAM.back, z + SHELL_CAM.up, 0.0, 0.0, 0.0, SHELL_CAM.fov, false, 2)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, 650, true, true)
    -- the camera is detached from the ped: park the player and take ALL gameplay
    -- controls (scroll doubles as weapon-cycle, LMB fires) — inputs are read
    -- through the Disabled variants below
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)

    local saved = false
    local dirty = true -- (re)seat the shell + camera only when z/heading change
    while true do
        DisableAllControlActions(0)
        local speedMode = IsDisabledControlPressed(0, 21) and 4 or 1

        -- scroll = height, arrows = facing
        if IsDisabledControlJustPressed(0, 15) then z = z + SHELL_Z_STEP * speedMode dirty = true end
        if IsDisabledControlJustPressed(0, 14) then z = z - SHELL_Z_STEP * speedMode dirty = true end
        if IsDisabledControlPressed(0, 174) then heading = (heading - 1.0 * speedMode) % 360.0 dirty = true end
        if IsDisabledControlPressed(0, 175) then heading = (heading + 1.0 * speedMode) % 360.0 dirty = true end
        if dirty then
            SetEntityCoordsNoOffset(shell, c.x, c.y, z, false, false, false)
            SetEntityHeading(shell, heading)
            -- track the shell from behind its facing so rotation reads naturally
            local camPos = GetOffsetFromEntityInWorldCoords(shell, 0.0, SHELL_CAM.back, SHELL_CAM.up)
            SetCamCoord(cam, camPos.x, camPos.y, camPos.z)
            PointCamAtCoord(cam, c.x, c.y, z + SHELL_CAM.lookUp)
            dirty = false
        end

        -- ground reference: ring at the counter + a plumb line up to the shell
        DrawMarker(1, c.x, c.y, c.z - 0.98, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            3.0, 3.0, 2.0, 255, 255, 255, 90, false, false, 2, false, nil, nil, false)
        DrawLine(c.x, c.y, c.z, c.x, c.y, z, 255, 255, 255, 160)

        ShowInteractText(
            '[SCROLL]     - ' .. _L("place_shell_height", z - c.z) .. '  \n' ..
            '[< / >]     - ' .. _L("place_shell_rotate") .. '  \n' ..
            '[E]     - ' .. _L("objects_save") .. '  \n' ..
            '[ESC / BACKSPACE]     - ' .. _L("objects_cancel")
        )

        -- pause-menu suppression (same working pattern as the gizmo loop)
        if IsPauseMenuActive() then
            SetFrontendActive(false)
            ActivateFrontendMenu(`FE_MENU_VERSION_EMPTY_NO_BACKGROUND`, true, -1)
        end
        if IsDisabledControlJustPressed(0, 202)
            or IsDisabledControlJustReleased(0, 199)
            or IsDisabledControlJustReleased(0, 200)
            or IsDisabledControlJustReleased(0, 322) then
            break
        end
        if IsDisabledControlJustPressed(0, 51) then saved = true break end
        Wait(0)
    end

    FreezeEntityPosition(ped, false)
    RenderScriptCams(false, true, 650, true, true)
    CreateThread(function()
        Wait(700) -- let the ease back finish before the cam handle dies
        if cam then DestroyCam(cam, false) end
    end)
    SetEntityAsMissionEntity(shell, true, true)
    DeleteEntity(shell)

    if not saved then return end
    local res = lib.callback.await("pickle_restaurants:placement:saveShell", false, {
        restaurant_id = restaurantId, z = z, heading = heading,
    })
    if res and res.ok then
        ShowNotification(_L("place_shell_saved"))
    else
        ShowNotification((res and res.error) or _L("place_shell_fail"))
    end
end

-- A counter is an invisible register anchor (no runtime prop) — the till is only
-- the gizmo PREVIEW so the admin can aim it at the map's own counter. Placing is
-- additive: a restaurant can have several registers (modules/main gives each one
-- its interaction; the lowest-id counter is the primary blip/shell/NPC anchor).
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

-- Reposition an already-placed prop. Re-runs the gizmo SEEDED at the prop's current
-- transform (starts exactly where it sits) with the same preview its original
-- placement used — physical station, counter till, seated ghost ped, or virtual
-- point ball — then persists the new transform via updateProp.
function StartPropReposition(propId)
    local prop = GetClientProp and GetClientProp(tonumber(propId))
    if not prop then return ShowNotification(_L("place_unknown_station")) end
    Wait(250)

    -- Hide the prop's CURRENT world entity so it doesn't sit as a ghost duplicate
    -- next to the gizmo preview while you drag. On save, the re-sync deletes + respawns
    -- it at the new spot; on cancel / failure we restore its visibility below.
    local liveEnt = GetStationEntity and GetStationEntity(tonumber(propId))
    if liveEnt and DoesEntityExist(liveEnt) then SetEntityVisible(liveEnt, false, false) end
    local function restoreLive()
        if liveEnt and DoesEntityExist(liveEnt) then SetEntityVisible(liveEnt, true, false) end
    end

    local seed = {
        coords       = vector3(prop.x + 0.0, prop.y + 0.0, prop.z + 0.0),
        rotation     = vector3(0.0, 0.0, (prop.heading or 0.0) + 0.0),
        enableCancel = true,
        deleteEntity = true,
    }
    local ptype = prop.prop_type
    if ptype == "seat" then
        local sitDict, sitAnim = SeatPreviewAnim()
        seed.isPed        = true
        seed.model        = SEAT_PREVIEW_PED
        seed.anim         = { dict = sitDict, name = sitAnim }
        seed.coordsOffset = vector3(0.0, 0.0, -SeatSitOffsetZ())
        seed.coords       = vector3(prop.x + 0.0, prop.y + 0.0, prop.z - SeatSitOffsetZ())
    elseif ptype == "counter" then
        seed.model = "prop_till_01"
    elseif ptype == "virtual_point" then
        seed.model = GetHashKey(VIRTUAL_PLACE_MODEL)
    else
        local model = PLACEABLE_MODELS[ptype]
        if not model then restoreLive(); return ShowNotification(_L("place_unknown_station")) end
        seed.model = GetHashKey(model)
        if WALL_MOUNTED[ptype] then seed.wallOffset = WallMountDepth(model) end
    end

    local result = StartGizmoEditor(seed)
    if not result or not result.position then restoreLive(); return end -- cancelled: put it back
    local res = lib.callback.await("pickle_restaurants:placement:updateProp", false, {
        id = propId,
        x = result.position.x, y = result.position.y, z = result.position.z,
        heading = (result.rotation and result.rotation.z) or 0.0,
    })
    if res and res.ok then
        ShowNotification(_L("place_prop_moved"))
        -- leave the old (hidden) entity — the re-sync deletes + respawns it at the new spot
    else
        restoreLive() -- save failed: unhide the original so it isn't lost
        ShowNotification((res and res.error) or _L("place_station_fail"))
    end
end
