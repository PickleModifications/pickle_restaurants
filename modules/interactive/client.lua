-- =============================================
--  modules/interactive | client.lua
--  Shared NUI focus helpers + the cursor->world raycast used to drag
--  ingredients out of the bottom bar into the 3D world.
-- =============================================

NUIView = "none"
-- The theme seed of the most recently opened panel (admin app theme / boss
-- restaurant theme). Kept so an in-world flow that runs WHILE the panel is
-- closed — object placement — can re-skin its NUI overlay to that panel's
-- theme instead of the default kit CloseNUI resets to. See ReassertNUITheme.
LastNUITheme = nil

function OpenNUI(view, data)
    NUIView = view
    LastNUITheme = data and data.theme or nil
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = "setView", view = view, data = data })
    -- The read-only corner "Tickets" widget rides along in restaurant-scoped
    -- experiences where staff can't reach the POS ticket tab (the kitchen station
    -- and the boss panel). The register has its own Tickets tab, and the admin
    -- panel is franchise-wide with no single restaurant — both skip the widget.
    local rid = data and (data.restaurantId or data.restaurant_id)
    if rid and ShowTicketWidget and (view == "cooking" or view == "management") then
        ShowTicketWidget(rid, data.theme)
    elseif HideTicketWidget then
        HideTicketWidget()
    end
end

function CloseNUI()
    NUIView = "none"
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "setView", view = "none" })
    if HideTicketWidget then HideTicketWidget() end
end

-- Re-skin the NUI to the last panel's theme WITHOUT reopening a view. The
-- object-placement gizmo runs with the panel closed but still draws a NUI
-- overlay (the [E]/[G] control hints via ShowInteractText); closing for
-- placement reset the theme to the default kit, so the hints rendered off-brand.
-- Called once as placement begins to carry the launching panel's theme through
-- it; the theme is restored anyway when the panel reopens afterward.
function ReassertNUITheme()
    SendNUIMessage({ action = "applyTheme", theme = LastNUITheme })
end

RegisterNUICallback("close", function(_, cb)
    CloseNUI()
    cb({})
end)

-- ESC closes whatever panel is open (cooking handles its own escape).
CreateThread(function()
    while true do
        local wait = 500
        -- the cooking station and the eat-in meal view own their own ESC (they have
        -- world props + a camera to tear down first)
        if NUIView ~= "none" and NUIView ~= "cooking" and NUIView ~= "dining" then
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
