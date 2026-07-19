-- ─────────────────────────────────────────────────────────────────────────────
-- bridge/phone/qs-smartphone (client) — the Lua→app push path.
--
-- Registration and both notification paths are SERVER exports on Quasar, so they live
-- in the server half of this bridge. All that's left here is pushing live data into
-- the running app page (order feed, driver position, theme changes).
--
-- ⚠ Quasar documents no Lua→iframe push export. Their JS bridge exposes
-- `bridge.onEvent((event, data) => …)` and describes the channel as bidirectional, so
-- a Lua-side emitter is expected to exist — it just isn't in the published export
-- list. So this tries the plausible names and, if none answer, says so ONCE and the
-- app falls back to polling (web/src/phone/store.tsx `pushless` mode). Everything
-- request/response already works regardless: the page's fetchNui POSTs land on this
-- resource's own NUI callbacks no matter who hosts the iframe.
--
-- If your build exposes the emitter under another name, add it to PUSH_EXPORTS —
-- that's the only edit needed to get live push working.
-- ─────────────────────────────────────────────────────────────────────────────
if not QSPhoneResource then return end

local RESOURCE = QSPhoneResource

local PUSH_EXPORTS = {
    "sendCustomAppMessage", "SendCustomAppMessage",
    "emitCustomAppEvent", "sendCustomAppEvent", "customAppEmit",
}

local resolved = nil   -- nil = untried, false = no candidate works

PhoneApp = PhoneApp or {}
PhoneApp.resource = RESOURCE

-- A missing export raises when CALLED, not when indexed, so pcall around the call is
-- the only real test — there's no way to ask "does this export exist" up front.
function PhoneApp.Send(payload)
    if resolved == false then return end
    if resolved then
        pcall(exports[RESOURCE][resolved], nil, PhoneAppMeta.id, payload)
        return
    end
    for _, name in ipairs(PUSH_EXPORTS) do
        if pcall(exports[RESOURCE][name], nil, PhoneAppMeta.id, payload) then
            resolved = name
            print(("[pickle_restaurants] %s: live app push via %s"):format(RESOURCE, name))
            return
        end
    end
    resolved = false
    print(("[pickle_restaurants] %s exposes no Lua→app push export — the app will poll instead. "
        .. "See bridge/phone/qs-smartphone/client.lua"):format(RESOURCE))
end

-- Notifications are a server export on Quasar; a client-side one isn't offered, so a
-- client-initiated notify goes out as an ordinary phone notification instead.
function PhoneApp.Notify(title, content)
    pcall(function() TriggerEvent("phone:notification", _L("phone_notify_join", title, content), "info") end)
end

-- Server-only on Quasar (GetCurrentPhoneNumber(src)); the server resolves it when the
-- client sends none. See bridge/phone/qs-smartphone/server.lua.
function PhoneApp.Number() return nil end

-- Answers modules/phone's `phone:pushSupported` NUI callback, which is what tells the
-- app to poll rather than wait for pushes that will never arrive.
function PhoneApp.PushSupported() return resolved ~= false end

-- Resolve the push path EAGERLY instead of on the first real broadcast: the app asks
-- whether to poll as soon as it opens, and "untried" would answer yes-push and then
-- silently never deliver. `ping` matches no useNuiEvent handler, so a working push
-- costs the page nothing.
CreateThread(function()
    while GetResourceState(RESOURCE) ~= "started" do Wait(500) end
    Wait(2000)
    PhoneApp.Send({ action = "ping" })
end)
