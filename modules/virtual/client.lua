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

-- Verbose session tracing. Toggle live in-game with /virtual_debug (registered at
-- the bottom of this file) so positions/entities can be reported without a
-- restart. Everything prints to BOTH F8 and the client console (txAdmin live
-- console mirrors it) prefixed [pickle_restaurants][virtual].
local DEBUG = false
local function vlog(fmt, ...)
    if not DEBUG then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print(("[pickle_restaurants][virtual] " .. (ok and msg or fmt)))
end
local function vpos(label, v)
    if not DEBUG or not v then return end
    vlog("%s = %.3f, %.3f, %.3f", label, v.x, v.y, v.z)
end

-- The open session: { vp, rid, sessionProp, shellEnt, stationEnts = {[type]=ent},
-- cancelled }. `Opening` latches the whole enter flow (claim -> fade -> build ->
-- OpenCookingStation) so a double-trigger can't build two environments.
local Session = nil
local Opening = false
local Tuning = false -- /virtual_tune offset-tuning scene is up (blocks real opens)

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
        vlog("^1ABORT^7 bad target=%s (point #%s)", tostring(target), tostring(vp.id))
        ShowNotification(_L("virtual_shell_missing"))
        return nil
    end
    local shellHash = LoadModelTimeout(SHELL_MODEL)
    if not shellHash then
        vlog("^1ABORT^7 shell model '%s' not in cdimage / failed to load", SHELL_MODEL)
        ShowNotification(_L("virtual_shell_missing"))
        return nil
    end

    local anchor = rest.shell
    vlog("building point #%s target=%s", tostring(vp.id), target)
    vpos("shell anchor", anchor)
    vlog("shell heading = %.1f", anchor.heading or 0.0)
    local shellEnt = spawnLocal(shellHash, vector3(anchor.x, anchor.y, anchor.z), anchor.heading or 0.0)
    if not shellEnt then
        vlog("^1ABORT^7 shell CreateObject failed")
        return nil
    end
    vpos("shell entity coords", GetEntityCoords(shellEnt))
    vlog("shell entity=%s exists=%s visible=%s", tostring(shellEnt),
        tostring(DoesEntityExist(shellEnt)), tostring(IsEntityVisible(shellEnt)))

    Session = { vp = vp, rid = vp.restaurant_id, shellEnt = shellEnt, stationEnts = {} }

    for stype, seat in pairs(SHELL_STATIONS) do
        local hash = LoadModelTimeout(PLACEABLE_MODELS[stype])
        if hash then
            local pos = GetOffsetFromEntityInWorldCoords(shellEnt, seat.offset.x, seat.offset.y, seat.offset.z)
            local ent = spawnLocal(hash, pos, ((anchor.heading or 0.0) + seat.heading) % 360.0)
            Session.stationEnts[stype] = ent
            vlog("station %-13s model=%s offset=(%.2f,%.2f,%.2f)", stype,
                PLACEABLE_MODELS[stype], seat.offset.x, seat.offset.y, seat.offset.z)
            vpos("  -> world", pos)
            vlog("  -> entity=%s exists=%s", tostring(ent), tostring(ent and DoesEntityExist(ent)))
        else
            vlog("^3station %s model '%s' failed to load^7", stype, tostring(PLACEABLE_MODELS[stype]))
        end
    end

    local stationEnt = Session.stationEnts[target]
    if not stationEnt then
        vlog("^1ABORT^7 target station '%s' entity missing after spawn", target)
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

    vlog("target station '%s' pose:", target)
    vpos("  coords", pos)
    vlog("  heading = %.1f", sessionProp.heading)
    vpos("player ped", GetEntityCoords(PlayerPedId()))

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
    vlog("scene load %s after %dms", tostring(loaded), GetGameTimer() - t0)
    return sessionProp
end

-- ─── session flow ─────────────────────────────────────────────────────────────

-- Interaction handler for a virtual point anchor (wired in main's SpawnProp).
function OpenVirtualStation(vp)
    if Tuning then return ShowNotification(_L("virtual_tuning_busy")) end
    if Opening or Session or (IsCookingOpen and IsCookingOpen()) then
        vlog("open ignored: Opening=%s Session=%s cooking=%s", tostring(Opening),
            tostring(Session ~= nil), tostring(IsCookingOpen and IsCookingOpen()))
        return
    end
    if IsSeated and IsSeated() then return end
    local rest = GetRestaurantById(vp.restaurant_id)
    if not rest or not rest.shell then
        vlog("open rejected: restaurant #%s has no shell anchor", tostring(vp.restaurant_id))
        return ShowNotification(_L("virtual_no_shell"))
    end
    vlog("=== open point #%s (restaurant #%s, target=%s) ===", tostring(vp.id),
        tostring(vp.restaurant_id), tostring(vp.metadata and vp.metadata.target))
    Opening = true

    -- claim the point BEFORE fading so a taken station rejects instantly.
    -- OpenCookingStation skips its own claim for virtual props — this is the one.
    local claim = lib.callback.await("pickle_restaurants:cooking:openStation", false, { prop_id = vp.id })
    if not (claim and claim.ok) then
        vlog("claim rejected: %s", tostring(claim and claim.error))
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
        vlog("^1abort after build^7 (sessionProp=%s invalidated=%s)",
            tostring(sessionProp ~= nil), tostring(enterInvalidated()))
        return abort()
    end

    -- normal station session: camera ease, ingredients, NUI — all against the
    -- virtual station entity via GetStationEntity(vp.id)
    OpenCookingStation(sessionProp)
    if not (IsCookingOpen and IsCookingOpen()) then
        -- it declined (a competing open won during its yields): don't let the
        -- environment outlive the session that never started
        vlog("^1abort^7: OpenCookingStation did not open")
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
    vlog("=== open complete, faded in ===")
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

-- ─── debug ────────────────────────────────────────────────────────────────────

-- Read by the shared station camera (modules/camera) so it logs its own resolved
-- world position/target when a virtual session traces.
function VirtualDebugOn() return DEBUG end

-- Toggle tracing without a restart, and dump the current session's live state.
RegisterCommand("virtual_debug", function()
    DEBUG = not DEBUG
    print(("[pickle_restaurants][virtual] tracing %s"):format(DEBUG and "^2ON^7" or "^1OFF^7"))
    if DEBUG and Session then
        vlog("live session: point #%s restaurant #%s", tostring(Session.vp.id), tostring(Session.rid))
        if Session.shellEnt and DoesEntityExist(Session.shellEnt) then
            vpos("  shell", GetEntityCoords(Session.shellEnt))
        end
        for stype, ent in pairs(Session.stationEnts or {}) do
            if ent and DoesEntityExist(ent) then vpos("  station " .. stype, GetEntityCoords(ent)) end
        end
        vpos("  player ped", GetEntityCoords(PlayerPedId()))
        if StationCam and DoesCamExist(StationCam) then
            vpos("  station cam", GetCamCoord(StationCam))
        end
    end
end, false)

-- ─── offset tuning (/virtual_tune) ────────────────────────────────────────────
-- A throwaway in-game editor for the SHELL_STATIONS table. It spawns a shell +
-- all four stations RIGHT WHERE YOU STAND (above ground, lit — offsets are
-- relative to the shell, so the world spot is irrelevant), lets you nudge each
-- station in the shell's local frame with an orbit camera, and prints a
-- paste-ready SHELL_STATIONS block to F8. Nothing is saved — you copy the
-- numbers into this file. Run it somewhere open.

local TUNE_ORDER = { "stovetop", "fryer", "soda_machine", "kitchen_prep" }

local function fmtStations(work)
    local lines = { "local SHELL_STATIONS = {" }
    for _, k in ipairs(TUNE_ORDER) do
        local s = work[k]
        if s then
            lines[#lines + 1] = string.format(
                "    %-12s = { offset = vector3(%.2f, %.2f, %.2f), heading = %.1f },",
                k, s.offset.x, s.offset.y, s.offset.z, s.heading)
        end
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

RegisterCommand("virtual_tune", function()
    if Tuning then return end
    if Session or (IsCookingOpen and IsCookingOpen()) then
        return ShowNotification(_L("virtual_tuning_busy"))
    end
    local shellHash = LoadModelTimeout(SHELL_MODEL)
    if not shellHash then
        return print(("[pickle_restaurants][virtual] ^1shell model '%s' missing^7"):format(SHELL_MODEL))
    end
    Tuning = true

    local ped = PlayerPedId()
    local pc = GetEntityCoords(ped)
    local shellHeading = 0.0
    local shellEnt = spawnLocal(shellHash, vector3(pc.x, pc.y, pc.z), shellHeading)
    if not shellEnt then Tuning = false return end

    -- working copy of the offsets we mutate, + the live station entities
    local work, ents = {}, {}
    for _, k in ipairs(TUNE_ORDER) do
        local base = SHELL_STATIONS[k]
        work[k] = { offset = vector3(base.offset.x, base.offset.y, base.offset.z), heading = base.heading }
        local hash = LoadModelTimeout(PLACEABLE_MODELS[k])
        if hash then
            local wp = GetOffsetFromEntityInWorldCoords(shellEnt, base.offset.x, base.offset.y, base.offset.z)
            ents[k] = spawnLocal(hash, wp, (shellHeading + base.heading) % 360.0)
        end
    end

    local cam = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA", pc.x, pc.y, pc.z + 2.0, 0.0, 0.0, 0.0, 50.0, false, 0)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    SetFocusPosAndVel(pc.x, pc.y, pc.z, 0.0, 0.0, 0.0)

    print("[pickle_restaurants][virtual] ^2tuning started^7 — [1-4] select, [WASD]+[SPACE/CTRL] move, "
        .. "[< >] rotate, mouse orbit, wheel zoom, [ENTER] print, [BACKSPACE] finish")

    local sel = 1
    local camYaw, camPitch, camDist = 0.0, 20.0, 4.0

    CreateThread(function()
        while Tuning do
            DisableAllControlActions(0)
            local fast = IsDisabledControlPressed(0, 21) and 4.0 or 1.0

            if IsDisabledControlJustPressed(0, 157) then sel = 1 end
            if IsDisabledControlJustPressed(0, 158) then sel = 2 end
            if IsDisabledControlJustPressed(0, 159) then sel = 3 end
            if IsDisabledControlJustPressed(0, 160) then sel = 4 end
            local key = TUNE_ORDER[sel]
            local w = work[key]
            local ent = ents[key]

            -- move selected in the shell's LOCAL frame (WASD = X/Y, SPACE/CTRL = Z)
            local step = 0.02 * fast
            local dx, dy, dz = 0.0, 0.0, 0.0
            if IsDisabledControlPressed(0, 32) then dy = dy + step end -- W forward (+Y)
            if IsDisabledControlPressed(0, 33) then dy = dy - step end -- S back
            if IsDisabledControlPressed(0, 35) then dx = dx + step end -- D right (+X)
            if IsDisabledControlPressed(0, 34) then dx = dx - step end -- A left
            if IsDisabledControlPressed(0, 22) then dz = dz + step end -- SPACE up (+Z)
            if IsDisabledControlPressed(0, 36) then dz = dz - step end -- L-CTRL down
            if dx ~= 0.0 or dy ~= 0.0 or dz ~= 0.0 then
                w.offset = vector3(w.offset.x + dx, w.offset.y + dy, w.offset.z + dz)
            end
            if IsDisabledControlPressed(0, 174) then w.heading = (w.heading - 1.0 * fast) % 360.0 end
            if IsDisabledControlPressed(0, 175) then w.heading = (w.heading + 1.0 * fast) % 360.0 end

            -- reposition the selected station + outline it; clear others' outline
            for k2, e2 in pairs(ents) do
                if e2 and DoesEntityExist(e2) then SetEntityDrawOutline(e2, k2 == key) end
            end
            if ent and DoesEntityExist(ent) then
                local wp = GetOffsetFromEntityInWorldCoords(shellEnt, w.offset.x, w.offset.y, w.offset.z)
                SetEntityCoordsNoOffset(ent, wp.x, wp.y, wp.z, false, false, false)
                SetEntityHeading(ent, (shellHeading + w.heading) % 360.0)
            end

            -- orbit camera around the selected station (mouse) + zoom (wheel)
            camYaw = camYaw + GetDisabledControlNormal(0, 1) * 4.0
            camPitch = math.max(-80.0, math.min(80.0, camPitch - GetDisabledControlNormal(0, 2) * 4.0))
            if IsDisabledControlPressed(0, 15) then camDist = math.max(1.0, camDist - 0.1) end
            if IsDisabledControlPressed(0, 14) then camDist = camDist + 0.1 end
            local tgt = (ent and DoesEntityExist(ent)) and GetEntityCoords(ent) or GetEntityCoords(shellEnt)
            local pr, yr = math.rad(camPitch), math.rad(camYaw)
            local ox = camDist * math.cos(pr) * math.sin(yr)
            local oy = camDist * math.cos(pr) * math.cos(yr)
            local oz = camDist * math.sin(pr)
            SetCamCoord(cam, tgt.x - ox, tgt.y - oy, tgt.z + oz)
            PointCamAtCoord(cam, tgt.x, tgt.y, tgt.z)

            ShowInteractText(
                string.format('[1-4]     - %s: ^2%s^7  \n', _L("virtual_tune_select"), key) ..
                '[WASD] [SPACE/CTRL]     - ' .. _L("virtual_tune_move") .. '  \n' ..
                '[< / >]     - ' .. _L("virtual_tune_rotate") .. '  \n' ..
                '[MOUSE / WHEEL]     - ' .. _L("virtual_tune_camera") .. '  \n' ..
                string.format('offset = ^3%.2f, %.2f, %.2f^7   heading = ^3%.1f^7  \n',
                    w.offset.x, w.offset.y, w.offset.z, w.heading) ..
                '[ENTER]     - ' .. _L("virtual_tune_print") .. '  \n' ..
                '[BACKSPACE]     - ' .. _L("objects_save")
            )

            if IsPauseMenuActive() then
                SetFrontendActive(false)
                ActivateFrontendMenu(`FE_MENU_VERSION_EMPTY_NO_BACKGROUND`, true, -1)
            end
            if IsDisabledControlJustPressed(0, 18) then -- ENTER: dump current values
                print("[pickle_restaurants][virtual] offsets:\n" .. fmtStations(work))
            end
            if IsDisabledControlJustPressed(0, 177) -- BACKSPACE
                or IsDisabledControlJustPressed(0, 202)
                or IsDisabledControlJustPressed(0, 200) then
                break
            end
            Wait(0)
        end

        print("[pickle_restaurants][virtual] ^2final offsets^7 (paste into modules/virtual/client.lua):\n"
            .. fmtStations(work))
        for _, e in pairs(ents) do safeDelete(e) end
        safeDelete(shellEnt)
        RenderScriptCams(false, false, 0, true, true)
        if cam and DoesCamExist(cam) then DestroyCam(cam, false) end
        FreezeEntityPosition(ped, false)
        SetEntityVisible(ped, true, false)
        ClearFocus()
        Tuning = false
    end)
end, false)
