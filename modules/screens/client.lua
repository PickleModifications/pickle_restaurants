-- =============================================
--  modules/screens | client.lua
--  Two customer-facing INFO SCREENS, rendered onto placed props by the same
--  render-target trick modules/rendertarget uses for packaging brands — a DUI paints
--  an HTML page (html/screens.html) into a runtime texture, and AddReplaceTexture
--  swaps it in for the prop's branded screen texture. Unlike a brand image the page
--  is DYNAMIC and fed live data each tick:
--
--    menu   — pickle_screen_menu_01 / texture s_m_brand
--             what the restaurant is selling: a paged slideshow of its priced menu
--             (image + name + price), sized to read from across the room. One page if
--             everything fits. Tracks menu edits (the menu rides the restaurant sync).
--    orders — pickle_screen_orders_01 / texture s_o_brand
--             open tickets in progress, NEWEST FIRST, with a PREPARING/READY chip.
--             Kept live off the sales orders broadcast (seeded once on arrival).
--
--  AddReplaceTexture is GLOBAL per (txd + txn) — so, exactly like the packaging brand,
--  only ONE restaurant's board shows on a given screen model at a time. We drive each
--  screen from the NEAREST restaurant that actually has that screen prop placed, so a
--  player reading a restaurant's board sees that restaurant's data. The two screens use
--  different models AND different textures, so they never collide with each other or
--  with the packaging brands.
--
--  Aspect + orientation are TUNED IN-GAME like the brand textures: /pickle_screen_res
--  and /pickle_screen_orient (plus /pickle_screen_debug to spawn both screens on a wall
--  with live data), then bake the numbers into SCREENS below.
-- =============================================

-- One entry per screen. `txd` is the model's embedded texture dictionary (== the model
-- name for these props) and `txn` the branded screen texture inside it. `w`/`h` is the
-- DUI resolution = the screen's pixel aspect (TUNE IN-GAME — best-guess defaults: a
-- landscape menu board, a portrait orders board). rot/flipx/flipy correct a rotated or
-- mirrored UV, same as the brand targets.
local SCREENS = {
    { key = "menu",   kind = "menu",   prop_type = "menu_screen",   txd = "pickle_screen_menu_01",   txn = "s_m_brand", w = 1080, h = 1920, rot = 90, flipx = false, flipy = false, gap = 3.5 },
    { key = "orders", kind = "orders", prop_type = "orders_screen", txd = "pickle_screen_orders_01", txn = "s_o_brand", w = 1080, h = 1920, rot = 90, flipx = false, flipy = false, gap = 3.5 },
}
local SCREEN_BY_KEY, SCREEN_BY_MODEL = {}, {}
for _, t in ipairs(SCREENS) do SCREEN_BY_KEY[t.key] = t; SCREEN_BY_MODEL[t.txd] = t end

local TICK_MS = 1000   -- driver cadence: re-pick nearest + re-push changed data

-- forced state while debugging (a fixed rid shown on every screen), else nil.
local debugForce = nil  -- { rid = <id> } | nil

-- Live open-order lists, per restaurant, projected for the orders board and kept
-- current by the sales orders broadcast below. Seeded once per restaurant the first
-- time its board goes active (a player who arrives between broadcasts).
local ScreenOrders = {}   -- [rid] = projected orders list (newest first)
local seededOrders = {}   -- [rid] = true once the one-shot seed has been requested

-- ─── per-screen DUI + runtime texture (mirrors modules/rendertarget) ──────────

local function rtNames(t) return
    ("pickle_screen_txd_%s_%d"):format(t.key, t.gen or 0),
    ("pickle_screen_tex_%s_%d"):format(t.key, t.gen or 0)
end

-- Deliver the current payload to the DUI. A DUI that hasn't loaded yet drops the push
-- and returns false, so the caller keeps t.sig unset and retries next tick (the same
-- blank-on-load fix modules/rendertarget documents).
local function pushToDui(t)
    if not (t.dui and t.ready and t.cur) then return false end
    local d = t.cur
    d.w, d.h = t.w, t.h
    d.rot, d.flipx, d.flipy = t.rot or 0, t.flipx or false, t.flipy or false
    d.key, d.res = t.key, GetCurrentResourceName()
    SendDuiMessage(t.dui, json.encode(d))
    return true
end

local function ensureDui(t)
    if t.dui then return end
    t.gen = (t.gen or 0) + 1
    t.ready = false
    local url = ("https://cfx-nui-%s/html/screens.html"):format(GetCurrentResourceName())
    t.dui = CreateDui(url, t.w, t.h)
    local txdName, texName = rtNames(t)
    local txd = CreateRuntimeTxd(txdName)
    CreateRuntimeTextureFromDuiHandle(txd, texName, GetDuiHandle(t.dui))
    CreateThread(function()
        local mine = t.gen
        while t.dui and t.gen == mine and not IsDuiAvailable(t.dui) do Wait(50) end
        if t.gen ~= mine then return end
        t.ready = true
        pushToDui(t)
    end)
end

local function applyReplacement(t)
    if t.applied then return end
    local txdName, texName = rtNames(t)
    AddReplaceTexture(t.txd, t.txn, txdName, texName)
    t.applied = true
end

local function removeReplacement(t)
    if not t.applied then return end
    RemoveReplaceTexture(t.txd, t.txn)
    t.applied = false
end

-- One re-bind after the page has painted its first real frame, against a live surface
-- instead of the blank one the initial bind would catch (the render-target blank-on-
-- load fix). The DUI then updates the prop LIVE every frame — the slideshow animates
-- and later data pushes show without any further rebinding.
local function rebindAfterPaint(t)
    t.rebindSeq = (t.rebindSeq or 0) + 1
    local mine = t.rebindSeq
    CreateThread(function()
        local tries = 0
        while t.dui and not IsDuiAvailable(t.dui) and tries < 150 do Wait(30); tries = tries + 1 end
        if not t.dui or t.rebindSeq ~= mine then return end
        Wait(600) -- let screens.html lay out + fetch its images before the safety rebind
        if t.dui and t.rebindSeq == mine and t.applied then
            removeReplacement(t); applyReplacement(t)
        end
    end)
end

-- ─── data payloads ────────────────────────────────────────────────────────────

-- Accent colour for a board = the restaurant's theme primary, else a warm default.
local function restaurantAccent(r)
    return (r and r.theme and r.theme.primary) or "#ff7a00"
end

-- Project a restaurant's live open orders for the board: newest ticket first, only
-- what a public "now preparing" display should show — ticket #, the item lines
-- (qty + label + image) and whether the kitchen has it ready. No customer identity.
local function projectOrders(orders)
    local out = {}
    for _, o in ipairs(orders or {}) do
        local items = {}
        for _, l in ipairs(o.lines or {}) do
            items[#items + 1] = { label = l.label or l.item, qty = l.qty or 1, image = l.image }
        end
        out[#out + 1] = { ticket = o.ticket, items = items,
                          ready = (o.fulfill and o.fulfill.ready) == true }
    end
    table.sort(out, function(a, b) return (a.ticket or 0) > (b.ticket or 0) end) -- newest first
    return out
end

-- The payload a screen should currently show for restaurant `r`, or nil if there's
-- nothing to render (no menu / no orders yet — the page draws its own empty state).
local function payloadFor(t, r)
    if not r then return nil end
    if t.kind == "menu" then
        return { action = "menu", title = r.label, accent = restaurantAccent(r),
                 items = r.menu or {}, combos = r.combos or {} }
    else
        return { action = "orders", title = r.label, accent = restaurantAccent(r),
                 orders = ScreenOrders[r.id] or {} }
    end
end

-- A stable signature so unchanged data isn't re-pushed every tick (the slideshow /
-- board animate client-side; we only re-push when the CONTENT actually changes).
local function payloadSig(rid, d)
    if not d then return "nil" end
    return tostring(rid) .. "|" .. json.encode(d)
end

-- ─── nearest-screen driver ───────────────────────────────────────────────────

-- Nearest restaurant that has THIS screen prop placed, using the prop's own world
-- position (so the board belongs to the screen you're standing at). No range gate:
-- these are placed world props we spawn ourselves, so the replacement stays active
-- whenever the screen exists at all — AddReplaceTexture is global anyway, and only the
-- DATA (which restaurant's board) depends on which screen you're nearest. Returns nil
-- only when NO restaurant has this screen placed (→ restore the native texture).
local function nearestFor(t)
    local here = GetEntityCoords(PlayerPedId())
    local best, bestDist
    for _, r in pairs(Restaurants or {}) do
        for _, p in ipairs(r.props or {}) do
            if p.prop_type == t.prop_type then
                local dist = #(here - vector3(p.x + 0.0, p.y + 0.0, p.z + 0.0))
                if not bestDist or dist < bestDist then bestDist, best = dist, r end
            end
        end
    end
    return best
end

-- Ensure the orders board has a current list for `rid`: it stays live off the
-- broadcast, but the first time a restaurant's board activates we ask the server once
-- (a player standing there before any order changes would otherwise see it empty).
local function seedOrders(rid)
    if not rid or seededOrders[rid] then return end
    seededOrders[rid] = true
    CreateThread(function()
        local res = lib.callback.await("pickle_restaurants:screens:getOrders", false, { id = rid })
        ScreenOrders[rid] = projectOrders(res and res.orders)
    end)
end

-- Show restaurant `r`'s data on screen `t` (nil = nothing in range → restore texture).
local function driveScreen(t, r)
    if not r then
        t.rid = nil
        removeReplacement(t)
        t.cur, t.sig = nil, nil
        return
    end
    if t.kind == "orders" then seedOrders(r.id) end
    local firstApply = not t.applied
    local ridChanged = t.rid ~= r.id
    t.rid = r.id
    ensureDui(t)
    applyReplacement(t)
    local payload = payloadFor(t, r)
    local sig = payloadSig(r.id, payload)
    if sig ~= t.sig then
        t.cur = payload
        if pushToDui(t) then t.sig = sig end
    end
    if firstApply or ridChanged then rebindAfterPaint(t) end
end

local function driveOnce()
    for _, t in ipairs(SCREENS) do
        local r = debugForce and Restaurants[debugForce.rid] or nearestFor(t)
        driveScreen(t, r)
    end
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        driveOnce()
    end
end)

-- Warm both DUIs at start (create + paint an empty frame) BEFORE any replacement or
-- model streaming, so the runtime texture holds a real frame when a board first binds
-- — the same cold-DUI fix modules/rendertarget applies.
CreateThread(function()
    Wait(700)
    for _, t in ipairs(SCREENS) do
        ensureDui(t)
        t.cur = { action = t.kind, title = "", accent = "#ff7a00",
                  items = {}, orders = {} }
        t.sig = "warm"
        pushToDui(t)
    end
end)

-- Live orders: the sales module broadcasts the full open-ticket list to EVERYONE on
-- every change. Cache the projection for any restaurant so its board is current the
-- next driver tick — whether or not we're near it right now.
RegisterNetEvent("pickle_restaurants:sales:orders", function(rid, orders)
    if not rid then return end
    ScreenOrders[rid] = projectOrders(orders)
    seededOrders[rid] = true -- a broadcast supersedes any need to seed
end)

-- screens.html POSTs here the instant it has painted a real frame, so we bind the
-- replacement against live content rather than the blank surface the first bind would
-- catch. Idempotent; only fires for a board that has content.
RegisterNUICallback("screen:painted", function(d, cb)
    local t = d and d.key and SCREEN_BY_KEY[d.key]
    if t and t.dui and t.applied and not debugForce then
        removeReplacement(t); applyReplacement(t)
    end
    cb("ok")
end)

-- Called by main's SpawnProp the instant a screen prop streams in. This is our ONE
-- reliable binding opportunity: AddReplaceTexture only takes while a prop of the model
-- actually EXISTS, and a placed screen never re-streams on its own (unlike packaging,
-- which re-streams every time an item is cooked/held). So force the replacement ACTIVE
-- and (re)bound now, while the prop is present — even if the driver hasn't picked this
-- restaurant yet (the DUI shows its warm frame until the next tick pushes real data).
function ReassertScreenFor(model)
    local t = model and SCREEN_BY_MODEL[model]
    if not t or debugForce then return end
    ensureDui(t)
    applyReplacement(t)   -- remove+add path is inside rebindAfterPaint below
    rebindAfterPaint(t)   -- re-bind against the painted surface while the prop exists
end

-- Re-assert every screen after a world (re)build. main's ApplySync respawns all props
-- and then calls this (mirroring RefreshBrands): re-push the current data and re-bind
-- each active screen while its freshly-spawned prop exists.
function RefreshScreens()
    if debugForce then return end
    for _, t in ipairs(SCREENS) do t.sig = nil end -- force a re-push with fresh data
    driveOnce()
    for _, t in ipairs(SCREENS) do
        if t.applied then rebindAfterPaint(t) end
    end
end

-- ─── debug / calibration ──────────────────────────────────────────────────────
-- /pickle_screen_debug [rid]  — spawn both screen models on a wall with the given
--   restaurant's live data forced on (defaults to the nearest restaurant that has any
--   menu); a second call tears the debug zone down.
-- /pickle_screen_res [key w h] — list, or resize a screen's DUI live to find the
--   aspect that makes its content un-stretched, then bake it into SCREENS.
-- /pickle_screen_orient [key rot flipx flipy] — list, or set a screen's rotation/mirror
--   live so the content lands upright on the prop, then bake it into SCREENS.

local DEBUG_COORD = vector3(-1190.8749, -891.9343, 15.5)
local debugProps  = {}

local function recreateDui(t)
    local wasApplied = t.applied
    removeReplacement(t)
    if t.dui then DestroyDui(t.dui); t.dui = nil end
    t.ready, t.cur, t.sig, t.rid = false, nil, nil, nil
    if wasApplied then applyReplacement(t) end -- next tick re-pushes fresh data
end

local function spawnModel(model, x, y, z)
    local hash = GetHashKey(model)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local t0 = GetGameTimer()
    while not HasModelLoaded(hash) and GetGameTimer() - t0 < 5000 do Wait(0) end
    if not HasModelLoaded(hash) then return nil end
    local ent = CreateObject(hash, x, y, z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ent or not DoesEntityExist(ent) then return nil end
    SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
    FreezeEntityPosition(ent, true)
    return ent
end

local function clearScreenDebug()
    for _, e in ipairs(debugProps) do
        if DoesEntityExist(e) then SetEntityAsMissionEntity(e, true, true); DeleteEntity(e) end
    end
    debugProps = {}
    debugForce = nil
end

RegisterCommand("pickle_screen_debug", function(_, args)
    if #debugProps > 0 then
        clearScreenDebug()
        print("[screens] debug zone cleared")
        return
    end
    local rid = tonumber(args[1])
    if not rid then
        -- default: the nearest restaurant that has a menu to show
        local here = GetEntityCoords(PlayerPedId())
        local bestDist
        for _, r in pairs(Restaurants or {}) do
            if r.menu and #r.menu > 0 then
                local c = r.counter and vector3(r.counter.x + 0.0, r.counter.y + 0.0, r.counter.z + 0.0)
                local dist = c and #(here - c) or 0.0
                if not bestDist or dist < bestDist then bestDist, rid = dist, r.id end
            end
        end
    end
    if not rid or not Restaurants[rid] then return print("[screens] no restaurant to preview (pass a valid rid)") end
    debugForce = { rid = rid }
    seededOrders[rid] = nil; seedOrders(rid)
    for _, t in ipairs(SCREENS) do applyReplacement(t) end
    SetEntityCoords(PlayerPedId(), DEBUG_COORD.x, DEBUG_COORD.y - 2.0, DEBUG_COORD.z, false, false, false, false)
    CreateThread(function()
        Wait(400)
        local x = DEBUG_COORD.x
        for _, t in ipairs(SCREENS) do
            local half = (t.gap or 3.0) * 0.5
            x = x + half
            local ent = spawnModel(t.txd, x, DEBUG_COORD.y, DEBUG_COORD.z)
            if ent then debugProps[#debugProps + 1] = ent; ReassertScreenFor(t.txd) end
            x = x + half
        end
        print(("[screens] debug zone: previewing restaurant #%d on %d screens"):format(rid, #debugProps))
    end)
end, false)

-- /pickle_screen_state — dump each screen's live state to F8, to diagnose a black
-- board: is a restaurant found, is the DUI up, is the replacement applied + bound.
RegisterCommand("pickle_screen_state", function()
    print("[screens] state:")
    for _, t in ipairs(SCREENS) do
        local r = debugForce and Restaurants[debugForce.rid] or nearestFor(t)
        local propHere = false
        for _, rr in pairs(Restaurants or {}) do
            for _, p in ipairs(rr.props or {}) do if p.prop_type == t.prop_type then propHere = true end end
        end
        local n = 0
        if r then n = (t.kind == "menu") and #(r.menu or {}) or #(ScreenOrders[r.id] or {}) end
        print(("  %-7s model=%s txn=%s prop_placed=%s dui=%s ready=%s applied=%s rid=%s data=%d")
            :format(t.key, t.txd, t.txn, tostring(propHere), tostring(t.dui ~= nil),
                    tostring(t.ready == true), tostring(t.applied == true), tostring(r and r.id or "-"), n))
    end
    print("[screens] if prop_placed=false → the screen prop isn't placed for any restaurant;")
    print("[screens] if applied=true but still black → try /pickle_screen_res (aspect) or a FULL resource restart (new html file).")
end, false)

RegisterCommand("pickle_screen_res", function(_, args)
    local key, w, h = args[1], tonumber(args[2]), tonumber(args[3])
    if not key then
        print("[screens] resolutions (bake tuned values into SCREENS):")
        for _, t in ipairs(SCREENS) do print(("  %-8s %s  ->  %d x %d"):format(t.key, t.txd, t.w, t.h)) end
        return print("[screens] usage: /pickle_screen_res <menu|orders> <width> <height>")
    end
    local t = SCREEN_BY_KEY[key]; if not t then return print(("[screens] unknown screen '%s'"):format(key)) end
    if not (w and h and w > 0 and h > 0) then return print("[screens] usage: /pickle_screen_res <menu|orders> <width> <height>") end
    t.w, t.h = math.floor(w), math.floor(h)
    recreateDui(t)
    print(("[screens] %s resized to %d x %d"):format(t.key, t.w, t.h))
end, false)

RegisterCommand("pickle_screen_orient", function(_, args)
    local key = args[1]
    if not key then
        print("[screens] orientations (bake tuned values into SCREENS):")
        for _, t in ipairs(SCREENS) do
            print(("  %-8s rot=%-3d flipx=%s flipy=%s"):format(t.key, t.rot or 0, tostring(t.flipx or false), tostring(t.flipy or false)))
        end
        return print("[screens] usage: /pickle_screen_orient <menu|orders> <rot 0|90|180|270> [flipx 0|1] [flipy 0|1]")
    end
    local t = SCREEN_BY_KEY[key]; if not t then return print(("[screens] unknown screen '%s'"):format(key)) end
    local rot = tonumber(args[2]); if not rot then return print("[screens] usage: /pickle_screen_orient <menu|orders> <rot 0|90|180|270> [flipx 0|1] [flipy 0|1]") end
    t.rot   = (math.floor(rot / 90 + 0.5) * 90) % 360
    t.flipx = (args[3] == "1" or args[3] == "true")
    t.flipy = (args[4] == "1" or args[4] == "true")
    t.sig = nil -- force a re-push with the new orientation
    pushToDui(t)
    print(("[screens] %s orient rot=%d flipx=%s flipy=%s"):format(t.key, t.rot, tostring(t.flipx), tostring(t.flipy)))
end, false)

-- ─── teardown ────────────────────────────────────────────────────────────────

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, t in ipairs(SCREENS) do
        removeReplacement(t)
        if t.dui then DestroyDui(t.dui); t.dui = nil end
    end
    clearScreenDebug()
end)
