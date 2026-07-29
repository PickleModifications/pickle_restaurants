-- =============================================
--  modules/virtual | client.lua
--  Virtual kitchen sessions. A virtual point (an invisible anchor placed like a
--  seat) opens its station INSIDE the restaurant's kitchen shell: the screen
--  fades, the shell + all four stations are built as LOCAL props only for this
--  player, the normal station camera/NUI runs against the point's station, and
--  the whole environment is removed behind another fade on the way out.
--
--  The player never teleports — only the scripted camera moves. Cooking state is
--  server-authoritative and keyed by the POINT's prop id, so every point is its
--  own kitchen: two points for the same station type share nothing, and items
--  left cooking keep cooking (and are re-rendered on the next session there).
-- =============================================

local SHELL_MODEL = "pickle_restaurant_shell_01"

-- Where each station sits INSIDE the shell, local to the shell origin
-- (x right, y forward, z up) + heading relative to the shell's. All four spawn
-- every session so the kitchen reads as a kitchen, whichever one is in use.
-- TUNE IN-GAME against the shell interior.
local SHELL_STATIONS = {
    stovetop     = { offset = vector3(1.00, 0.92, 0.00), heading = -90.0 },
    fryer        = { offset = vector3(1.00, 2.00, 0.00), heading = -90.0 },
    soda_machine = { offset = vector3(1.00, -1.84, 0.00), heading = -90.0 },
    kitchen_prep = { offset = vector3(1.00, -0.68, 0.00), heading = -90.0 },
}

local FADE_MS = 400
function VirtualFadeMs() return FADE_MS end -- StopCooking fades the exit with this
function VirtualShellModel() return SHELL_MODEL end -- the admin placement preview spawns the same shell

-- The open session: { vp, rid, sessionProp, shellEnt, stationEnts = {[type]=ent},
-- cancelled }. `Opening` latches the whole enter flow (claim -> fade -> build ->
-- OpenCookingStation) so a double-trigger can't build two environments.
local Session = nil
local Opening = false

-- ─── env build / teardown ─────────────────────────────────────────────────────

-- Bounded model load; also used by the shell placement view (modules/placement)
-- so the preview and the session build can't drift.
function LoadModelTimeout(name)
    local hash = GetHashKey(name)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local started = GetGameTimer()
    while not HasModelLoaded(hash) do
        Wait(0)
        if GetGameTimer() - started > 10000 then return nil end
    end
    return hash
end

local function spawnLocal(hash, pos, heading)
    local ent = CreateObject(hash, pos.x, pos.y, pos.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ent or not DoesEntityExist(ent) then return nil end
    SetEntityCoordsNoOffset(ent, pos.x, pos.y, pos.z, false, false, false)
    SetEntityHeading(ent, heading or 0.0)
    FreezeEntityPosition(ent, true)
    SetEntityCollision(ent, true, true) -- the cursor raycast needs real surfaces
    return ent
end

local function safeDelete(ent)
    if not ent or not DoesEntityExist(ent) then return end
    SetEntityAsMissionEntity(ent, true, true)
    DeleteEntity(ent)
end

-- Remove every local prop this session created (doors/baskets/items included)
-- and release the anchors. Safe to call on a half-built environment.
local function teardownEnv()
    if not Session then return end
    if DespawnOvenDoors then DespawnOvenDoors(Session.vp.id) end
    if DespawnFryerBaskets then DespawnFryerBaskets(Session.vp.id) end
    if DropItemsFor then DropItemsFor(Session.vp.id) end
    RegisterVirtualStation(Session.vp.id, nil)
    for _, ent in pairs(Session.stationEnts or {}) do safeDelete(ent) end
    safeDelete(Session.shellEnt)
    ClearFocus()
    Session = nil
end

-- Build the shell + stations at the restaurant's shell anchor. Returns the
-- synthesized "prop row" the cooking session runs against, or nil on failure.
-- `liveMeta` is the point's CURRENT server-side metadata (doors/baskets), fresher
-- than the last-synced row.
local function buildEnv(rest, vp, liveMeta)
    -- On ANY nil return the caller owns cleanup (teardownEnv is half-built-safe);
    -- don't tear down in here.
    local target = vp.metadata and vp.metadata.target
    if not target or not SHELL_STATIONS[target] then
        ShowNotification(_L("virtual_shell_missing"))
        return nil
    end
    local shellHash = LoadModelTimeout(SHELL_MODEL)
    if not shellHash then
        ShowNotification(_L("virtual_shell_missing"))
        return nil
    end

    local anchor = rest.shell
    local shellEnt = spawnLocal(shellHash, vector3(anchor.x, anchor.y, anchor.z), anchor.heading or 0.0)
    if not shellEnt then
        return nil
    end

    Session = { vp = vp, rid = vp.restaurant_id, shellEnt = shellEnt, stationEnts = {} }

    for stype, seat in pairs(SHELL_STATIONS) do
        local hash = LoadModelTimeout(PLACEABLE_MODELS[stype])
        if hash then
            local pos = GetOffsetFromEntityInWorldCoords(shellEnt, seat.offset.x, seat.offset.y, seat.offset.z)
            local ent = spawnLocal(hash, pos, ((anchor.heading or 0.0) + seat.heading) % 360.0)
            Session.stationEnts[stype] = ent
        else
        end
    end

    local stationEnt = Session.stationEnts[target]
    if not stationEnt then
        ShowNotification(_L("virtual_shell_missing"))
        return nil
    end

    -- everything that anchors to "the station entity" for this prop id — the
    -- scripted camera, oven doors, baskets, slot seating — now resolves here
    RegisterVirtualStation(vp.id, stationEnt)

    -- The session runs against the point's prop id but the TARGET's behavior and
    -- the virtual station's world pose. Metadata (oven-door / basket states, kept
    -- per point on the server) comes from the claim response, falling back to the
    -- synced row.
    local live = (GetClientProp and GetClientProp(vp.id)) or vp
    local pos = GetEntityCoords(stationEnt)
    local sessionProp = {
        id = vp.id, restaurant_id = vp.restaurant_id,
        prop_type = target, model = PLACEABLE_MODELS[target],
        x = pos.x, y = pos.y, z = pos.z, heading = GetEntityHeading(stationEnt),
        metadata = liveMeta or live.metadata, virtual = true,
    }
    Session.sessionProp = sessionProp


    if target == "stovetop" and SpawnOvenDoors then SpawnOvenDoors(sessionProp, stationEnt) end
    if OnStationSpawned then OnStationSpawned(sessionProp) end

    -- keep the world streamed around the shell while the camera lives there
    SetFocusPosAndVel(anchor.x, anchor.y, anchor.z, 0.0, 0.0, 0.0)
    -- The shell can sit far from the player (underground / in the sky). We're
    -- behind a black fade here, so force-load the scene at the shell before the
    -- camera reveals it — otherwise the first frame is an unstreamed/unlit void.
    RequestCollisionAtCoord(anchor.x, anchor.y, anchor.z)
    NewLoadSceneStartSphere(anchor.x, anchor.y, anchor.z, 60.0, 0)
    local t0 = GetGameTimer()
    while not IsNewLoadSceneLoaded() and GetGameTimer() - t0 < 1500 do Wait(0) end
    local loaded = IsNewLoadSceneLoaded()
    NewLoadSceneStop()
    return sessionProp
end

-- ─── session flow ─────────────────────────────────────────────────────────────

-- Interaction handler for a virtual point anchor (wired in main's SpawnProp).
function OpenVirtualStation(vp)
    if Opening or Session or (IsCookingOpen and IsCookingOpen()) then
        return
    end
    if IsSeated and IsSeated() then return end
    local rest = GetRestaurantById(vp.restaurant_id)
    if not rest or not rest.shell then
        return ShowNotification(_L("virtual_no_shell"))
    end
    Opening = true

    -- claim the point BEFORE fading so a taken station rejects instantly.
    -- OpenCookingStation skips its own claim for virtual props — this is the one.
    local claim = lib.callback.await("pickle_restaurants:cooking:openStation", false, { prop_id = vp.id })
    if not (claim and claim.ok) then
        Opening = false
        return ShowNotification((claim and claim.error) or _L("cook_station_busy"))
    end
    if Session or (IsCookingOpen and IsCookingOpen()) then -- re-check: the await yielded
        Opening = false
        TriggerServerEvent("pickle_restaurants:cooking:closeStation", vp.id)
        return
    end

    DoScreenFadeOut(FADE_MS)
    while not IsScreenFadedOut() do Wait(0) end

    -- unwind a failed/cancelled enter: env down, claim released, world back
    local function abort()
        teardownEnv()
        TriggerServerEvent("pickle_restaurants:cooking:closeStation", vp.id)
        DoScreenFadeIn(FADE_MS)
        Opening = false
    end

    -- The point/shell can change under us while this flow yields (fade, model
    -- loads) — BEFORE Session exists for the safety-net handlers to flag. Catch
    -- it by re-reading the synced state: the point still placed, the shell
    -- anchor still the one we're building at.
    local function enterInvalidated()
        if Session and Session.cancelled then return true end
        if GetClientProp and not GetClientProp(vp.id) then return true end -- point deleted
        local now = GetRestaurantById(vp.restaurant_id)
        local s = now and now.shell
        return not s or s.x ~= rest.shell.x or s.y ~= rest.shell.y
            or s.z ~= rest.shell.z or (s.heading or 0.0) ~= (rest.shell.heading or 0.0)
    end

    local sessionProp = buildEnv(rest, vp, claim.metadata)
    if not sessionProp or enterInvalidated() then
        return abort()
    end

    -- normal station session: camera ease, ingredients, NUI — all against the
    -- virtual station entity via GetStationEntity(vp.id)
    OpenCookingStation(sessionProp)
    if not (IsCookingOpen and IsCookingOpen()) then
        -- it declined (a competing open won during its yields): don't let the
        -- environment outlive the session that never started
        return abort()
    end
    if enterInvalidated() then
        -- the point/shell changed mid-open; close through the normal exit now
        Opening = false
        if ForceStopCooking then ForceStopCooking() end
        return
    end

    -- render THIS point's in-progress items inside the fresh shell. Must come
    -- AFTER the session opens: the render gate only admits a virtual point's
    -- items once currentCookProp is this point.
    if ReplayActiveItemsFor then ReplayActiveItemsFor(vp.id) end
    DoScreenFadeIn(FADE_MS)
    Opening = false
end

-- Called by StopCooking after the exit fade + camera/NUI teardown: remove the
-- environment while the screen is still black, then reveal the real world.
function OnVirtualStationClosed(_)
    CreateThread(function()
        Wait(700) -- let the camera's 650ms ease back finish behind the fade
        teardownEnv()
        DoScreenFadeIn(FADE_MS)
    end)
end

-- ─── safety nets ──────────────────────────────────────────────────────────────

-- Close the live session out — or, if the enter flow is still mid-open
-- (cookingOpen not set yet), flag it cancelled so the flow aborts itself at
-- its next checkpoint (ForceStopCooking would no-op in that window).
local function killSession(noticeKey)
    ShowNotification(_L(noticeKey))
    if IsCookingOpen and IsCookingOpen() then
        if ForceStopCooking then ForceStopCooking() end
    elseif Session then
        Session.cancelled = true
    end
end

-- the point itself was deleted while we were inside it
RegisterNetEvent("pickle_restaurants:propRemoved", function(propId)
    if Session and Session.vp.id == tonumber(propId) then
        killSession("virtual_point_removed")
    end
end)

-- an admin re-placed this restaurant's shell: close out cleanly; the next
-- session rebuilds at the new anchor (the server moved any live items along)
RegisterNetEvent("pickle_restaurants:shellMoved", function(rid)
    if Session and Session.rid == tonumber(rid) then
        killSession("virtual_shell_moved")
    end
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    if not Session then return end
    teardownEnv()
    if not IsScreenFadedIn() then DoScreenFadeIn(0) end
end)

