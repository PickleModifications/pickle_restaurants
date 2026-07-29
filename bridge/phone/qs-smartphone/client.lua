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
-- Detect on THIS side. This used to gate on `QSPhoneResource`, which the SERVER half
-- sets — a server global is not visible in the client runtime, so the check was always
-- nil and every line below was dead code: on Quasar, `PhoneApp` was never defined at
-- all, so there was no live push into the app page and no phone-close for the doorstep
-- hand-off.
local QS_RESOURCES = { "qs-smartphone", "qs-smartphone-pro" }

local RESOURCE
for _, res in ipairs(QS_RESOURCES) do
    if GetResourceState(res) ~= "missing" then RESOURCE = res break end
end
if not RESOURCE then return end
-- Stand down for a bridge that already claimed the API — unless its phone is sitting
-- STOPPED in the resources folder, which is a leftover, not the server's phone.
if not PhoneBridgeClaim(RESOURCE) then return end   -- also stamps PhoneApp.resource

-- ─── client-side registration fallback ───────────────────────────────────────
-- Registration is a SERVER export on Quasar proper, but the pro fork registers
-- per-player from the client, so a server-only attempt is how an app "just never
-- appears" with nothing obviously broken. The server half tells us when its own
-- probe came up empty (`qsClientRegister`) and we run the same matrix here.
local registered = false

local function TryClientRegister()
    if registered then return end
    local name, shape = PhoneTryRegister(RESOURCE)
    if name then
        registered = true
        return print(("[pickle_restaurants] %s: app registered client-side via %s (shape %d)")
            :format(RESOURCE, name, shape))
    end
    print(("[pickle_restaurants] %s: client-side app registration found no export either — "
        .. "add the app by hand (run `pickle_phoneapp` in the server console for the values)")
        :format(RESOURCE))
end

RegisterNetEvent("pickle_restaurants:phone:qsClientRegister", function()
    while GetResourceState(RESOURCE) ~= "started" do Wait(500) end
    Wait(1000)
    TryClientRegister()
end)

-- Ask on spawn: a player who joined after the server ran its probe never saw the
-- broadcast, and this is the only side that can register for them.
CreateThread(function()
    Wait(5000)
    TriggerServerEvent("pickle_restaurants:phone:qsAsk")
end)

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

-- Put the phone away for the doorstep hand-off (bridge/phone/shared.lua explains why).
-- Quasar publishes no close in its export list either, so these are the plausible names
-- and the documented close EVENT as the fallback. Add yours here if your build differs.
local CLOSE_EXPORTS = { "ClosePhone", "closePhone", "CloseCustomPhone" }
local CLOSE_EVENTS  = { "qs-smartphone:client:closePhone" }

function PhoneApp.Close()
    PhoneCloseVia(RESOURCE, CLOSE_EXPORTS, CLOSE_EVENTS)
end

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
