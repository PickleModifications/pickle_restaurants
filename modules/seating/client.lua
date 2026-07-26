-- =============================================
--  modules/seating | client.lua
--  Player sitting on the invisible seat anchors (prop_type "seat") admins place.
--  A seat spawns NO world prop — the anchor is just a point + heading the player
--  sits at, on the restaurant's own furniture. main/client attaches the "Sit"
--  interaction on a seat prop and calls SitOnSeat here.
-- =============================================

-- The seated pose, played as a LOOPING ANIMATION (not a scenario). Scenarios
-- teleport-root the ped, which desyncs the pose for other players; a looping
-- TaskPlayAnim is a normal networked ped task, so everyone sees the same sit.
-- An UPRIGHT CHAIR sit (feet down, pelvis raised to seat height) — dpemotes'
-- "sitchair2". The plain "sit" clip (anim@amb@business@bgen@bgen_no_work@) roots
-- the pelvis at floor level and reads as sitting ON THE GROUND, which is not what
-- we want on furniture. These are all known shipping clips (they're in dpemotes),
-- so any of them streams in on every ped. Other verified upright options if this
-- posture doesn't match your chairs — swap the pair and re-test in-game:
--   sitchair3: "timetable@reunited@ig_10"  / "base_amanda"
--   sitchair4: "timetable@ron@ig_3_couch"  / "base"          (couch, lower)
--   sitchair6: "timetable@maid@couch@"     / "base"          (couch, lower)
-- TUNE IN-GAME (pose here, height via SIT_OFFSET_Z below).
local SIT_DICT = "timetable@ron@ig_5_p3"
local SIT_ANIM = "ig_5_p3_base"
-- How far BELOW the placed anchor the ped is seated. The anchor is the floor
-- point the admin placed (feet on the floor) and the sit animation seats the
-- body at its own height above that, so this is normally 0. TUNE IN-GAME.
local SIT_OFFSET_Z = 0.0
local SIT_CONTROL  = 51 -- INPUT_CONTEXT (E) — same key sits and stands

-- Stream an anim dict in (bounded wait); returns whether it loaded.
local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local t = GetGameTimer()
    while not HasAnimDictLoaded(dict) and GetGameTimer() - t < 2000 do Wait(0) end
    return HasAnimDictLoaded(dict)
end

-- Play the looping seated pose on a ped (flag 1 = looping, holds indefinitely).
local function playSitAnim(ped)
    if not loadAnimDict(SIT_DICT) then return false end
    TaskPlayAnim(ped, SIT_DICT, SIT_ANIM, 8.0, -8.0, -1, 1, 0.0, false, false, false)
    return true
end

local function isPlayingSit(ped)
    return IsEntityPlayingAnim(ped, SIT_DICT, SIT_ANIM, 3)
end

-- Exposed so the placement gizmo can preview the SEATED pose (not a standing ped)
-- at exactly where a player will sit — the same animation + z-offset the real sit
-- uses, so what the admin positions is what they get.
function SeatPreviewAnim() return SIT_DICT, SIT_ANIM end
function SeatSitOffsetZ() return SIT_OFFSET_Z end

local seatedSeat = nil -- the seat prop we're currently sitting on (nil = standing)

function IsSeated() return seatedSeat ~= nil end

local function helpText(msg)
    BeginTextCommandDisplayHelp("STRING")
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

function StandUp()
    local seat = seatedSeat
    if not seat then return end
    seatedSeat = nil
    local ped = PlayerPedId()
    ClearPedTasks(ped) -- blends out of the sit, unlike ...Immediately
    EnableInteraction = true -- re-arm the interaction engine (sitting disabled it)
    TriggerServerEvent("pickle_restaurants:seating:stand", seat.id)
    -- anything that only makes sense while seated (the eat-in meal view) closes
    TriggerEvent("pickle_restaurants:seating:stood", seat.id)
end

-- Sit on a placed seat anchor. Reserves it server-side first (so two players can't
-- share one anchor), then warps the player onto the anchor's point/heading and
-- plays the looping seated animation.
function SitOnSeat(seat)
    if not seat then return end
    if seatedSeat then return ShowNotification(_L("seat_already_sitting")) end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) or IsEntityDead(ped) then return end

    local res = lib.callback.await("pickle_restaurants:seating:sit", false, { id = seat.id })
    if not (res and res.ok) then
        return ShowNotification((res and res.error) or _L("seat_taken"))
    end

    seatedSeat = seat
    EnableInteraction = false -- no other interactions (incl. re-sitting) while seated
    ClearPedTasksImmediately(ped)
    -- seat the player on the anchor (feet-on-floor point) facing the stored heading;
    -- the looping sit animation seats the body from there (no freeze — a frozen root
    -- can lock the body below the surface, and the loop holds them in place anyway)
    SetEntityCoordsNoOffset(ped, seat.x + 0.0, seat.y + 0.0, seat.z - SIT_OFFSET_Z, false, false, false)
    SetEntityHeading(ped, (seat.heading or 0.0) + 0.0)
    playSitAnim(ped) -- streams the dict in (once) and starts the loop

    CreateThread(function()
        -- swallow the sit keypress so its release doesn't instantly stand us again
        while IsControlPressed(0, SIT_CONTROL) do Wait(0) end
        -- don't police the pose until the sit animation has actually started
        -- (IsEntityPlayingAnim reads false for a frame or two), capped so we never hang
        local settled, startT = false, GetGameTimer()
        while seatedSeat == seat do
            if not settled and (isPlayingSit(ped) or GetGameTimer() - startT > 3000) then
                settled = true
            end
            -- lock the player in the seat: disabling movement (rather than freezing
            -- the entity) keeps them planted the whole time — no 2-second window
            -- where they can walk off — while letting physics settle them onto the
            -- surface so the pose can't lock below the floor
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
            -- something interrupted the loop (damage, a warp) but we're still meant
            -- to be seated: re-assert the pose. NON-blocking (the dict is already
            -- loaded), so this can never stall the loop even if the clip is missing.
            elseif settled and not isPlayingSit(ped) and HasAnimDictLoaded(SIT_DICT) then
                TaskPlayAnim(ped, SIT_DICT, SIT_ANIM, 8.0, -8.0, -1, 1, 0.0, false, false, false)
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
        ClearPedTasks(PlayerPedId())
        EnableInteraction = true
        seatedSeat = nil
    end
end)
