-- =============================================
--  modules/seating | client.lua
--  Player sitting on the invisible seat anchors (prop_type "seat") admins place.
--  A seat spawns NO world prop — the anchor is just a point + heading + STYLE, and
--  the player sits on the restaurant's own furniture there. main/client attaches
--  the "Sit" interaction on a seat prop and calls SitOnSeat here.
--
--  THE RULE: a player sits EXACTLY where the anchor is. Nothing gets a vote.
--
--    * We set the coords ourselves and freeze. A frozen ped is skipped by the
--      collision depenetration pass, which is what used to shove players up out of
--      an MLO chair's mesh — there is nothing to fight because physics never runs.
--    * The pose is a looping clip, played at those coords. The PLACEMENT GHOST
--      plays the same clip at the same point, so what an admin positions is
--      literally what a player gets — that is the whole value of a placed anchor.
--
--  NOT scenarios. `TaskStartScenarioAtPosition` was tried and reverted: it decides
--  for itself where to put the ped (players ended up through the floor), and the
--  natives that report whether a ped is in a scenario are unreliable enough that
--  the repair tick re-tasked it forever — an endless sit-down loop. Both problems
--  are the same problem: handing placement to something that places it elsewhere.
--
--  Styles (posture + height trim) live in Config.SeatStyles (core/shared.lua).
-- =============================================

local SIT_CONTROL = 51 -- INPUT_CONTEXT (E) — same key sits and stands
-- The pose can read as "not playing" for a frame or two after it starts, so the
-- loop doesn't police it until either it's confirmed playing or this expires.
local SETTLE_MS   = 3000
-- How often the loop may re-assert a pose that has genuinely dropped. Rate-limited
-- on purpose: re-tasking every frame is what turned a repair into a loop.
local REPAIR_MS   = 1000

-- ─── style helpers ───────────────────────────────────────────────────────────

-- The style table for a seat row (defaults for anchors placed before styles, or
-- naming a style a later version dropped — GetSeatStyle never returns nil).
local function styleFor(seat)
    return GetSeatStyle(seat and seat.metadata and seat.metadata.style)
end

-- Exposed for the placement gizmo, which previews a GHOST PED in the seated pose.
-- It MUST use these — ghost and sit sharing one clip and one offset is what makes
-- placement WYSIWYG. Both take an optional style id (nil = default).
function SeatPreviewAnim(styleId)
    local s = GetSeatStyle(styleId)
    return s.anim.dict, s.anim.clip
end

function SeatSitOffsetZ(styleId)
    return GetSeatStyle(styleId).dz or 0.0
end

-- ─── the pose ────────────────────────────────────────────────────────────────

local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local t = GetGameTimer()
    while not HasAnimDictLoaded(dict) and GetGameTimer() - t < 2000 do Wait(0) end
    return HasAnimDictLoaded(dict)
end

-- flag 1 = looping, holds indefinitely.
local function playSit(ped, style)
    TaskPlayAnim(ped, style.anim.dict, style.anim.clip, 8.0, -8.0, -1, 1, 0.0, false, false, false)
end

local function isPlayingSit(ped, style)
    return IsEntityPlayingAnim(ped, style.anim.dict, style.anim.clip, 3)
end

-- ─── state ───────────────────────────────────────────────────────────────────

local seatedSeat = nil -- the seat prop we're currently sitting on (nil = standing)

function IsSeated() return seatedSeat ~= nil end

-- The seat row we're sitting on (nil = standing). modules/dining reads its
-- `metadata.tray` to lay the meal out on THIS seat's placed table spot.
function CurrentSeat() return seatedSeat end

local function helpText(msg)
    BeginTextCommandDisplayHelp("STRING")
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

-- ─── standing up ─────────────────────────────────────────────────────────────

function StandUp()
    local seat = seatedSeat
    if not seat then return end
    seatedSeat = nil
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetPedCanRagdoll(ped, true)
    ClearPedTasks(ped) -- blends out of the pose, unlike ...Immediately
    -- Stand up AT THE SEAT'S EXIT POINT if it has one. Standing where you sat puts
    -- a booth or bar diner on top of the table — the anchor is on the furniture, so
    -- the place to leave from has to be its own point. No exit point (an open-floor
    -- chair that doesn't need one) = stand where you are, as before.
    local exit = seat.metadata and seat.metadata.exit
    if exit and exit.x and exit.y and exit.z then
        SetEntityCoords(ped, exit.x + 0.0, exit.y + 0.0, exit.z + 0.0, false, false, false, false)
        SetEntityHeading(ped, (exit.heading or 0.0) + 0.0)
    end
    EnableInteraction = true -- re-arm the interaction engine (sitting disabled it)
    TriggerServerEvent("pickle_restaurants:seating:stand", seat.id)
    -- anything that only makes sense while seated (the eat-in meal view) closes
    TriggerEvent("pickle_restaurants:seating:stood", seat.id)
end

-- ─── sitting down ────────────────────────────────────────────────────────────

-- Sit on a placed seat anchor. Reserves it server-side first (so two players can't
-- share one anchor), then plants the ped on the anchor and poses it.
function SitOnSeat(seat)
    if not seat then return end
    if seatedSeat then return ShowNotification(_L("seat_already_sitting")) end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) or IsEntityDead(ped) then return end

    local res = lib.callback.await("pickle_restaurants:seating:sit", false, { id = seat.id })
    if not (res and res.ok) then
        return ShowNotification((res and res.error) or _L("seat_taken"))
    end

    local style = styleFor(seat)
    local x, y  = seat.x + 0.0, seat.y + 0.0
    local z     = seat.z + (style.dz or 0.0)
    local h     = (seat.heading or 0.0) + 0.0

    seatedSeat = seat
    EnableInteraction = false -- no other interactions (incl. re-sitting) while seated

    -- Stream the clip in BEFORE placing the ped: a dict that arrives late would
    -- leave the player frozen in a standing pose until the repair tick noticed.
    -- If a style's clip won't load at all, sit them in the DEFAULT style rather
    -- than freezing them upright — a wrong-looking sit beats a broken one.
    if not loadAnimDict(style.anim.dict) then
        local fb = GetSeatStyle(Config.DefaultSeatStyle)
        if fb.anim.dict ~= style.anim.dict and loadAnimDict(fb.anim.dict) then style = fb end
    end

    ClearPedTasksImmediately(ped)
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    SetEntityHeading(ped, h)
    -- Ragdoll off with the freeze: a shove or a car clipping the furniture would
    -- otherwise break the pose and leave a frozen ped mid-flop.
    SetPedCanRagdoll(ped, false)
    FreezeEntityPosition(ped, true)
    playSit(ped, style)

    CreateThread(function()
        -- swallow the sit keypress so its release doesn't instantly stand us again
        while IsControlPressed(0, SIT_CONTROL) do Wait(0) end
        local settled, startT, nextRepair = false, GetGameTimer(), 0
        while seatedSeat == seat do
            if not settled and (isPlayingSit(ped, style) or GetGameTimer() - startT > SETTLE_MS) then
                settled = true
            end
            -- The freeze holds the POSITION; these hold the INPUT, so a held key
            -- can't walk the player off the seat the moment they stand.
            DisableControlAction(0, 30, true)  -- INPUT_MOVE_LR
            DisableControlAction(0, 31, true)  -- INPUT_MOVE_UD
            DisableControlAction(0, 21, true)  -- INPUT_SPRINT
            DisableControlAction(0, 22, true)  -- INPUT_JUMP
            DisableControlAction(0, 23, true)  -- INPUT_ENTER (vehicle)
            DisableControlAction(0, 36, true)  -- INPUT_DUCK
            helpText(_L("seat_stand_prompt"))

            if IsControlJustPressed(0, SIT_CONTROL) or IsEntityDead(ped) then
                StandUp()
                break
            end

            -- Something interrupted the pose (damage, another script's task) but
            -- we're still meant to be seated: re-assert it. Only once settled, and
            -- only every REPAIR_MS — re-tasking on every frame is a sit-down loop,
            -- not a repair.
            if settled and GetGameTimer() >= nextRepair and not isPlayingSit(ped, style) then
                nextRepair = GetGameTimer() + REPAIR_MS
                if HasAnimDictLoaded(style.anim.dict) then
                    playSit(ped, style)
                    FreezeEntityPosition(ped, true)
                end
            end
            Wait(0)
        end
    end)
end

-- If the seat we're on is deleted out from under us, stand up cleanly.
RegisterNetEvent("pickle_restaurants:propRemoved", function(propId)
    if seatedSeat and seatedSeat.id == tonumber(propId) then StandUp() end
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    if seatedSeat then
        -- never leave a player frozen because the resource restarted mid-sit
        local ped = PlayerPedId()
        FreezeEntityPosition(ped, false)
        SetPedCanRagdoll(ped, true)
        ClearPedTasks(ped)
        EnableInteraction = true
        seatedSeat = nil
    end
end)
