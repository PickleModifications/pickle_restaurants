-- =============================================
--  modules/seating | client.lua
--  Player sitting on the invisible seat anchors (prop_type "seat") admins place.
--  A seat spawns NO world prop — the anchor is just a point + heading the player
--  sits at, on the restaurant's own furniture. main/client attaches the "Sit"
--  interaction on a seat prop and calls SitOnSeat here.
-- =============================================

-- The seated pose. PROP_HUMAN_SEAT_CHAIR_FOOD is an eating-at-a-table scenario,
-- which fits a restaurant; swap to PROP_HUMAN_SEAT_CHAIR for a plain sit.
local SIT_SCENARIO = "PROP_HUMAN_SEAT_CHAIR_FOOD"
-- How far BELOW the placed anchor the seated pose is rooted. The anchor is placed
-- with a standing ghost ped (feet on the floor); seated scenarios root a little
-- lower so the body settles onto the chair. TUNE IN-GAME per your seat models.
local SIT_OFFSET_Z = 0.5
local SIT_CONTROL  = 51 -- INPUT_CONTEXT (E) — same key sits and stands

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
    ClearPedTasks(ped) -- plays the get-up, unlike ...Immediately
    EnableInteraction = true -- re-arm the interaction engine (sitting disabled it)
    TriggerServerEvent("pickle_restaurants:seating:stand", seat.id)
end

-- Sit on a placed seat anchor. Reserves it server-side first (so two players can't
-- share one anchor), then plays the seated scenario at the anchor's point/heading.
function SitOnSeat(seat)
    if not seat then return end
    if seatedSeat then return ShowNotification("You're already sitting.") end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) or IsEntityDead(ped) then return end

    local res = lib.callback.await("pickle_restaurants:seating:sit", false, { id = seat.id })
    if not (res and res.ok) then
        return ShowNotification((res and res.error) or "That seat is taken.")
    end

    seatedSeat = seat
    EnableInteraction = false -- no other interactions (incl. re-sitting) while seated
    ClearPedTasksImmediately(ped)
    TaskStartScenarioAtPosition(ped, SIT_SCENARIO,
        seat.x + 0.0, seat.y + 0.0, seat.z - SIT_OFFSET_Z, (seat.heading or 0.0) + 0.0,
        -1, true, true)

    CreateThread(function()
        -- swallow the sit keypress so its release doesn't instantly stand us again
        while IsControlPressed(0, SIT_CONTROL) do Wait(0) end
        -- don't police the pose until the sit-down enter animation has settled
        -- (IsPedUsingScenario reads false mid-animation), capped so we never hang
        local settled, startT = false, GetGameTimer()
        while seatedSeat == seat do
            if not settled and (IsPedUsingScenario(ped, SIT_SCENARIO) or GetGameTimer() - startT > 3000) then
                settled = true
            end
            helpText("Press ~INPUT_CONTEXT~ to stand up")
            -- stand on demand, on death, or once the pose breaks (ragdolled / warped)
            if IsControlJustPressed(0, SIT_CONTROL)
                or IsEntityDead(ped)
                or (settled and not IsPedUsingScenario(ped, SIT_SCENARIO)) then
                StandUp()
                break
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
