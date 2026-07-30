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

-- ESC closes whatever panel is open. A view that owns world props / a camera and
-- has to tear them down first (the cooking station, the eat-in meal view) registers
-- its own closer here instead of polling for the key itself — one per-frame reader
-- for everything, so nothing misses a keypress on a slow tick.
EscapeHandlers = {} -- NUIView name -> function called instead of CloseNUI
function SetEscapeHandler(view, fn) EscapeHandlers[view] = fn end

-- NUI focus alone does NOT stop ESC from reaching the frontend: the game still
-- processes the pause controls, so escaping a panel also opened the pause menu.
-- They are DISABLED every frame a panel is up (and the menu shoved closed if one
-- slipped through), and the key is read back with the Disabled* variants.
-- BACKSPACE (194 / 202) is accepted as the alternate "step out" key.
CreateThread(function()
    while true do
        if NUIView ~= "none" then
            DisableControlAction(0, 199, true) -- INPUT_FRONTEND_PAUSE
            DisableControlAction(0, 200, true) -- INPUT_FRONTEND_PAUSE_ALTERNATE
            DisableControlAction(0, 322, true) -- ESC
            -- Same working pattern as the gizmo/placement loops: force the frontend
            -- back closed before the key is read, so a single tap can't paint a frame
            -- of pause menu on its way to closing the panel.
            if IsPauseMenuActive() then
                SetFrontendActive(false)
                ActivateFrontendMenu(`FE_MENU_VERSION_EMPTY_NO_BACKGROUND`, true, -1)
            end
            if IsDisabledControlJustReleased(0, 322) or IsDisabledControlJustReleased(0, 200)
                or IsDisabledControlJustReleased(0, 202) or IsDisabledControlJustReleased(0, 194) then
                local handler = EscapeHandlers[NUIView]
                if handler then handler() else CloseNUI() end
            end
            Wait(0)
        else
            Wait(250)
        end
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

-- ─── hiding your OWN body, and only on your own screen ───────────────────────
-- Every in-world interactive view (the station camera, the kiosk, the register) takes
-- the ped out of its own shot. That is a LOCAL presentation choice, and it was being
-- made with `SetEntityVisible(ped, false, false)` — which on a PLAYER ped propagates:
-- everyone else watched the cashier vanish from behind the counter. `SetEntityVisible`
-- has no "local only" mode for a networked ped; the native that does is
-- `SetEntityLocallyInvisible`, documented as "not visible FOR YOURSELF", and it lasts
-- one FRAME, so it has to be re-asserted every tick for as long as the view is open.
--
-- Every consumer goes through here rather than reaching for either native: one loop,
-- one flag, and no way for two views to leave the ped hidden after both have closed.
local pedHidden, pedHideLoop = false, false

function SetLocalPedHidden(on)
    pedHidden = on and true or false
    if not pedHidden then
        -- HEAL a ped hidden by the old networked call (a client that opened a view
        -- before this fix, or a session torn down mid-hide): asserting real visibility
        -- costs nothing when it was never taken away.
        SetEntityVisible(PlayerPedId(), true, false)
        return
    end
    if pedHideLoop then return end
    pedHideLoop = true
    CreateThread(function()
        while pedHidden do
            SetEntityLocallyInvisible(PlayerPedId())
            Wait(0)
        end
        pedHideLoop = false
    end)
end

function IsLocalPedHidden() return pedHidden end

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    -- never leave a player looking at an invisible body of their own
    if pedHidden then SetLocalPedHidden(false) end
end)
