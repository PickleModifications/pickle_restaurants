-- ─────────────────────────────────────────────────────────────────────────────
-- bridge/phone/qs-smartphone (server) — the Quasar Smartphone implementation.
--
-- Unlike lb-phone, Quasar's custom-app API is SERVER-side: `addCustomApp`,
-- `sendPhoneNotification` and `GetCurrentPhoneNumber` are all server exports. So this
-- file owns registration and both pushes, and the client half only carries the
-- app-message path. (bridge/phone/lb-phone is the mirror image — see its client file.)
--
-- Presence, not readiness: a phone often starts after the jobs that register apps on
-- it, so a started-check here would leave the bridge undefined forever.
-- ─────────────────────────────────────────────────────────────────────────────

local QS_RESOURCES = { "qs-smartphone", "qs-smartphone-pro" }

local RESOURCE
for _, res in ipairs(QS_RESOURCES) do
    if GetResourceState(res) ~= "missing" then RESOURCE = res break end
end
-- Yield to a bridge that already claimed the API — but not to one whose phone is
-- sitting stopped in the resources folder. See PhoneBridgeClaim in bridge/phone/shared.
if not RESOURCE then return end
if not PhoneBridgeClaim(RESOURCE) then return end

QSPhoneResource = RESOURCE   -- server-side only; the client half detects for itself

-- Quasar has moved its custom-app registration between names AND payload shapes
-- across builds (and the pro fork differs again), and none of it is in the published
-- export list — so the whole matrix is tried (PhoneTryRegister, bridge/phone/shared)
-- and the winning cell announced, rather than one guessed call silently doing nothing.
QSAppRegistered = false      -- read by the client half's fallback probe
local lastErr

-- The app is auto-removed when THIS resource stops, so there's no teardown to write.
local function AddApp()
    if QSAppRegistered then return true end
    local name, shape, err = PhoneTryRegister(RESOURCE)
    if not name then lastErr = err return false end
    QSAppRegistered = true
    print(("[pickle_restaurants] %s: app registered via %s (shape %d)"):format(RESOURCE, name, shape))
    return true
end

CreateThread(function()
    while GetResourceState(RESOURCE) ~= "started" do Wait(500) end
    Wait(1000)   -- let the exports come up
    if AddApp() then return end
    -- Server-side registration is out. The client half gets a shot (the pro fork
    -- registers per-player), and if that misses too the admin still has the values.
    print(("[pickle_restaurants] %s: no server-side app registration export answered (last error: %s)")
        :format(RESOURCE, tostring(lastErr)))
    TriggerClientEvent("pickle_restaurants:phone:qsClientRegister", -1)
    PrintPhoneAppInstall(("%s did not accept a runtime app registration."):format(RESOURCE))
end)

-- A client that joined after the probe ran still needs telling to try its own side.
RegisterNetEvent("pickle_restaurants:phone:qsAsk", function()
    if not QSAppRegistered then
        TriggerClientEvent("pickle_restaurants:phone:qsClientRegister", source)
    end
end)

-- The phone restarting drops every registered app, so add ours back.
AddEventHandler("onResourceStart", function(res)
    if res == RESOURCE then
        Wait(1000)
        QSAppRegistered = false
        if not AddApp() then TriggerClientEvent("pickle_restaurants:phone:qsClientRegister", -1) end
    end
end)

function PhoneAppNotify(src, title, content, thumbnail)
    pcall(function()
        exports[RESOURCE]:sendPhoneNotification(src, {
            appId = PhoneAppMeta.id,
            title = title,
            text  = content,          -- Quasar calls the body `text`, lb-phone `content`
            image = thumbnail,
        })
    end)
end

function PhoneAppNumber(src)
    local ok, num = pcall(function() return exports[RESOURCE]:GetCurrentPhoneNumber(src) end)
    return ok and num or nil
end
