-- =============================================
--  modules/interactive | client.lua
--  Shared NUI focus helpers + the cursor->world raycast used to drag
--  ingredients out of the bottom bar into the 3D world.
-- =============================================

NUIView = "none"

function OpenNUI(view, data)
    NUIView = view
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = "setView", view = view, data = data })
end

function CloseNUI()
    NUIView = "none"
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "setView", view = "none" })
end

RegisterNUICallback("close", function(_, cb)
    CloseNUI()
    cb({})
end)

-- ESC closes whatever panel is open (cooking handles its own escape).
CreateThread(function()
    while true do
        local wait = 500
        if NUIView ~= "none" and NUIView ~= "cooking" then
            wait = 0
            if IsControlJustReleased(0, 322) then -- ESC
                CloseNUI()
            end
        end
        Wait(wait)
    end
end)

-- Raycast from the live NUI cursor position into the world. Reuses the gizmo's
-- ScreenToWorld helper (defined in modules/gizmo/client.lua). When the station
-- camera is active we raycast from *that* camera so drag-to-place lines up with
-- what the player actually sees.
function CursorToWorld()
    local camPos, camRot
    if StationCam and DoesCamExist(StationCam) then
        camPos = GetCamCoord(StationCam)
        camRot = GetCamRot(StationCam, 2)
    else
        camPos = GetGameplayCamCoord()
        camRot = GetGameplayCamRot(2)
    end
    return GetCursorRaycast(camPos, camRot)
end
