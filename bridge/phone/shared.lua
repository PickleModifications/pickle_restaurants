-- ─────────────────────────────────────────────────────────────────────────────
-- bridge/phone (shared) — the companion app's identity, in ONE place
--
-- Every phone bridge registers the same app; only the export names differ. So the
-- metadata that describes it (id, name, icon, which page to load) lives here rather
-- than being copy-pasted into each variant — change the icon or the blurb once and
-- every supported phone picks it up.
--
-- APP_ID is also what the SERVER stamps on notifications, so it has to match on both
-- sides — hence shared, not client-only.
-- ─────────────────────────────────────────────────────────────────────────────

PhoneAppMeta = {
    id          = "pickle_food",
    name        = "Pickle Eats",
    developer   = "Pickle Modifications",
    size        = 48000,
}

-- Absolute URLs into THIS resource. A phone loads the app page in an iframe, so both
-- have to be reachable from the phone's own NUI origin — a relative path would
-- resolve against the phone resource, not ours.
function PhoneAppUI()
    return ("https://cfx-nui-%s/nui/phone.html"):format(GetCurrentResourceName())
end

function PhoneAppIcon()
    return ("https://cfx-nui-%s/nui/phone-icon.png"):format(GetCurrentResourceName())
end

-- The store blurb is the one piece of app metadata a player reads, so it is
-- localized. It is a FUNCTION, not a `PhoneAppMeta` field: this file is a shared
-- script and loads before `locales/locale.lua`, so `_L` does not exist yet at the
-- point the table above is built. Every caller resolves it at registration time.
function PhoneAppDescription()
    return _L("phone_app_description")
end

-- ─── closing the phone ────────────────────────────────────────────────────────
-- `PhoneApp.Close()` (each client bridge defines it) puts the phone away. The
-- doorstep hand-off is the caller: serving a delivery from the app means the phone is
-- open and IN THE PED'S HAND as the knock starts, and its hold/put-away animation
-- fights ours (modules/doorstep/client.lua).
--
-- Only lb-phone publishes an unambiguous close (`ToggleOpen(false)`), so the other
-- bridges hand this helper the plausible export names and the first that doesn't raise
-- wins, resolved once — the same treatment the Quasar push path gets. A missing export
-- raises when CALLED, not when indexed, so pcall around the call is the only real test.
--
-- Events are the LAST resort and are fired every time rather than resolved: TriggerEvent
-- succeeds whether or not anything is listening, so there is nothing to learn from it.
-- Never list a TOGGLE here — on an already-closed phone a toggle would open it.
local closeExport = {}   -- resource → export name, or false once every candidate failed

function PhoneCloseVia(resource, candidates, events)
    local resolved = closeExport[resource]
    if resolved then
        pcall(exports[resource][resolved], nil)
        return true
    end
    if resolved == nil then
        for _, name in ipairs(candidates or {}) do
            if pcall(exports[resource][name], nil) then
                closeExport[resource] = name
                return true
            end
        end
        closeExport[resource] = false
    end
    for _, ev in ipairs(events or {}) do TriggerEvent(ev) end
    return false
end
