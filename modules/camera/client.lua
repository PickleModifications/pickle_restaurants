-- =============================================
--  modules/camera | client.lua
--  Smooth scripted-camera entry/exit for the station experience. When a player
--  opens one of the four station props we ease from the gameplay camera into a
--  framed view of the station, and ease back out when they leave. The cooking
--  cursor raycast (modules/interactive) reads StationCam so drag-to-place still
--  lines up with what the player is actually looking at.
-- =============================================

StationCam = nil

local EASE_MS = 650

local function normalizeFlat(v)
    local flat = vector3(v.x, v.y, 0.0)
    local len = #flat
    if len < 0.01 then return vector3(0.0, 1.0, 0.0) end
    return flat / len
end

-- Frame the station from the side the player is standing on, slightly raised
-- and angled down at the worktop — reads like leaning over the counter.
function StartStationCamera(prop)
    if StationCam then StopStationCamera() end
    local station = vector3(prop.x + 0.0, prop.y + 0.0, prop.z + 0.0)
    local ped     = PlayerPedId()
    local dir     = normalizeFlat(GetEntityCoords(ped) - station)

    local camPos  = station + dir * 1.15 + vector3(0.0, 0.0, 0.85)
    local lookAt  = station + vector3(0.0, 0.0, 0.12)

    local cam = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA",
        camPos.x, camPos.y, camPos.z, 0.0, 0.0, 0.0, 42.0, false, 0)
    PointCamAtCoord(cam, lookAt.x, lookAt.y, lookAt.z)
    SetCamActive(cam, true)
    -- ease = true interpolates from the live gameplay camera into this one.
    RenderScriptCams(true, true, EASE_MS, true, true)
    StationCam = cam
    return cam
end

function StopStationCamera()
    local cam = StationCam
    if not cam then return end
    StationCam = nil
    -- Ease back to the gameplay camera, then tear the scripted cam down once the
    -- transition has finished so the hand-off stays smooth.
    RenderScriptCams(false, true, EASE_MS, true, true)
    CreateThread(function()
        Wait(EASE_MS + 50)
        if DoesCamExist(cam) then DestroyCam(cam, false) end
    end)
end

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    if StationCam and DoesCamExist(StationCam) then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(StationCam, false)
        StationCam = nil
    end
end)
