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
-- Yield to a bridge that already claimed the API: a server runs ONE phone, and
-- lb-phone owning it shouldn't be clobbered by a qs resource that merely exists on disk.
if not RESOURCE or PhoneAppNotify then return end

QSPhoneResource = RESOURCE   -- read by the client half

local function AddApp()
    -- Quasar's registration shape: `id` / `label` / `icon`, and the page goes in a
    -- nested `iframe.url` (lb-phone takes a flat `ui`). The app is auto-removed when
    -- THIS resource stops, so there's no teardown to write.
    local ok, err = pcall(function()
        exports[RESOURCE]:addCustomApp({
            id          = PhoneAppMeta.id,
            label       = PhoneAppMeta.name,
            description = PhoneAppDescription(),
            developer   = PhoneAppMeta.developer,
            icon        = PhoneAppIcon(),
            iframe      = { url = PhoneAppUI() },
        })
    end)
    if not ok then
        print(("[pickle_restaurants] %s addCustomApp failed: %s"):format(RESOURCE, tostring(err)))
    end
end

CreateThread(function()
    while GetResourceState(RESOURCE) ~= "started" do Wait(500) end
    Wait(1000)   -- let the exports come up
    AddApp()
end)

-- The phone restarting drops every registered app, so add ours back.
AddEventHandler("onResourceStart", function(res)
    if res == RESOURCE then Wait(1000); AddApp() end
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
