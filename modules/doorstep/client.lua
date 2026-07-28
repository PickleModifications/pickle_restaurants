-- =============================================
--  modules/doorstep | client.lua
--  THE DOORSTEP HAND-OFF. An NPC delivery whose drop point is an admin-placed
--  delivery door doesn't complete with a button press at a coordinate: the driver
--  knocks, steps back, and a resident comes out and takes the bag off them.
--
--  Run by the driver's client only, from the phone's "delivered" action — the
--  sequence happens BEFORE `sales:completeOrder`, and a cancelled/failed sequence
--  means the order is not completed. The server grants nothing here (see
--  doorstep/server.lua): it only says whether this order has a door and where.
--
--  The resident is a LOCAL ped. Only the driver is party to the scene, so there is
--  no ped netcode, no ownership to migrate and nothing left behind for other
--  players if this client crashes mid-hand-off.
-- =============================================

-- TUNE IN-GAME. Every dict/clip below is a shipped GTA one.
local DOOR = {
    -- how close the driver must already be to the door for the scene to start
    reach       = 6.0,
    -- knocking
    knock_dict  = "timetable@jimmy@doorknock@",
    knock_clip  = "knockdoor_idle",
    knock_ms    = 2200,
    -- the driver backs off this far from the door (metres, along the door's facing)
    -- and waits there; the resident needs the doorway clear to step into.
    step_back   = 1.6,
    back_ms     = 2500,
    -- the resident: spawned just INSIDE the doorway and walks out to the door point
    inside      = 1.0,   -- metres behind the door point they start at
    answer_ms   = 4000,  -- how long they're given to reach the doorway
    open_delay  = 900,   -- pause between the knock and the door opening
    -- the exchange. `mp_common` givetake1_a / _b is the two-sided hand-over pair
    -- every trade-an-item script uses: _a gives, _b receives.
    give_dict   = "mp_common",
    give_clip   = "givetake1_a",
    take_clip   = "givetake1_b",
    give_ms     = 2400,
    -- resident models, picked at random per delivery
    peds        = { "a_m_y_business_01", "a_f_y_business_02", "a_m_m_eastsa_01",
                    "a_f_m_soucent_01", "a_m_y_hipster_01", "a_f_y_hipster_02" },
}

local running = false

local function loadDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local t = GetGameTimer()
    while not HasAnimDictLoaded(dict) and GetGameTimer() - t < 3000 do Wait(0) end
    return HasAnimDictLoaded(dict)
end

local function loadModel(name)
    local hash = GetHashKey(name)
    RequestModel(hash)
    local t = GetGameTimer()
    while not HasModelLoaded(hash) and GetGameTimer() - t < 5000 do Wait(0) end
    return HasModelLoaded(hash) and hash or nil
end

-- Forward vector of a heading, flat. The door's heading points OUT of the doorway,
-- so +fwd is the street side and -fwd is indoors.
local function fwdOf(heading)
    local rad = math.rad(heading or 0.0)
    return -math.sin(rad), math.cos(rad)
end

local function playFor(ped, dict, clip, ms, flag)
    if not loadDict(dict) then return false end
    TaskPlayAnim(ped, dict, clip, 8.0, -8.0, ms or -1, flag or 0, 0.0, false, false, false)
    return true
end

-- Clean up a resident whatever happened — a delivery that fails mid-scene must not
-- leave a stranger standing in the street forever.
local function despawn(ped)
    if ped and DoesEntityExist(ped) then
        SetEntityAsMissionEntity(ped, true, true)
        DeleteEntity(ped)
    end
end

-- Run the doorstep scene for an order.
--   nil   — this order has no door (a plain coordinate drop): complete normally
--   false — there IS a door but the scene didn't happen (too far, aborted): DON'T
--           complete; the caller shows why
--   true  — the resident took the bag: complete the order
function RunDoorstepHandoff(rid, orderId)
    if running then return false end
    local door = lib.callback.await("pickle_restaurants:doorstep:point", false,
                                    { rid = rid, orderId = orderId })
    if not (door and door.x) then return nil end -- not a doorstep delivery

    local ped = PlayerPedId()
    local at  = vector3(door.x, door.y, door.z)
    if #(GetEntityCoords(ped) - at) > DOOR.reach then
        ShowNotification(_L("door_too_far"))
        return false
    end

    running = true
    local resident
    local ok = pcall(function()
        local fx, fy = fwdOf(door.heading)

        -- 1. knock. Face the door first so the clip reads as knocking ON it.
        TaskTurnPedToFaceCoord(ped, at.x, at.y, at.z, 800)
        Wait(800)
        playFor(ped, DOOR.knock_dict, DOOR.knock_clip, DOOR.knock_ms)
        Wait(DOOR.knock_ms)
        ClearPedTasks(ped)

        -- 2. step back off the doorstep, still facing the door, so the resident has
        --    room to step out into it (and so the exchange isn't nose-to-nose).
        local bx, by = at.x + fx * DOOR.step_back, at.y + fy * DOOR.step_back
        TaskGoStraightToCoord(ped, bx, by, at.z, 1.0, DOOR.back_ms,
                              (door.heading or 0.0) + 180.0, 0.15)
        Wait(DOOR.back_ms)

        -- 3. the door opens: the resident starts INSIDE and walks out to the
        --    doorway, so they arrive rather than appearing on the step.
        Wait(DOOR.open_delay)
        local model = DOOR.peds[math.random(#DOOR.peds)]
        local hash  = loadModel(model)
        if not hash then error("model", 0) end
        resident = CreatePed(4, hash, at.x - fx * DOOR.inside, at.y - fy * DOOR.inside, at.z,
                             door.heading or 0.0, false, false)
        SetModelAsNoLongerNeeded(hash)
        if not (resident and DoesEntityExist(resident)) then error("ped", 0) end
        SetEntityInvincible(resident, true)
        SetBlockingOfNonTemporaryEvents(resident, true) -- don't flee/react to traffic
        SetPedCanRagdoll(resident, false)
        TaskGoStraightToCoord(resident, at.x, at.y, at.z, 1.0, DOOR.answer_ms,
                              door.heading or 0.0, 0.1)
        local t = GetGameTimer()
        while GetGameTimer() - t < DOOR.answer_ms
            and #(GetEntityCoords(resident) - at) > 0.35 do Wait(50) end
        ClearPedTasks(resident)

        -- 4. the exchange: two halves of one clip, started on the same frame so the
        --    hands actually meet.
        TaskTurnPedToFaceEntity(resident, ped, 500)
        TaskTurnPedToFaceEntity(ped, resident, 500)
        Wait(500)
        loadDict(DOOR.give_dict)
        playFor(ped, DOOR.give_dict, DOOR.give_clip, DOOR.give_ms)
        playFor(resident, DOOR.give_dict, DOOR.take_clip, DOOR.give_ms)
        Wait(DOOR.give_ms)
        ClearPedTasks(ped)
    end)

    -- 5. they go back inside regardless of how the scene ended, then vanish out of
    --    sight rather than popping out of existence in front of the driver.
    if resident and DoesEntityExist(resident) then
        local fx, fy = fwdOf(door.heading)
        TaskGoStraightToCoord(resident, at.x - fx * (DOOR.inside + 1.0),
                              at.y - fy * (DOOR.inside + 1.0), at.z, 1.0, 3000,
                              (door.heading or 0.0) + 180.0, 0.1)
        local body = resident
        CreateThread(function() Wait(3000); despawn(body) end)
    end
    running = false
    if not ok then
        ClearPedTasks(PlayerPedId())
        ShowNotification(_L("door_handoff_failed"))
        return false
    end
    return true
end

-- A resource stop mid-scene must not strand the player in an animation.
AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    if running then ClearPedTasks(PlayerPedId()) end
end)
