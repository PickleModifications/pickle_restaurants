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
