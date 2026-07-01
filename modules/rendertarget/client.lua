-- =============================================
--  modules/rendertarget | client.lua
--  Runtime brand-texture replacement for food-packaging props.
--
--  A single DUI renders the active restaurant's brand image (an HTML page,
--  html/brand.html, so the image is drawn full-cover) into a runtime texture.
--  AddReplaceTexture then swaps that texture in for the branded texture on each
--  packaging prop, so a cup / pizza box / tray / side box shows the restaurant's
--  logo.
--
--  AddReplaceTexture is GLOBAL (per texture dictionary + texture name), not
--  per-entity — so there is only ever one brand active at a time. We drive it from
--  the NEAREST restaurant that has a brand image configured, swapping the DUI's
--  image as the player moves between restaurants and removing the replacement
--  entirely (restoring the original texture) when none is in range.
-- =============================================

-- Each target = the original texture to replace. `txd` is the model's embedded
-- texture dictionary (which equals the model name for these props) and `txn` is the
-- branded texture inside it. If a replacement doesn't take, verify these two names
-- against the model in OpenIV / CodeWalker and adjust here.
local TARGETS = {
    { txd = "pickle_pizza_box_02",       txn = "pizza_brand" },
    { txd = "pickle_drink_container_01", txn = "cup_brand" },
    { txd = "pickle_tray_paper_01",      txn = "tray_paper" },
    { txd = "pickle_side_container_01",  txn = "side_container_brand_01" },
}

local RT_TXD   = "pickle_brand_txd" -- runtime texture dictionary name
local RT_TEX   = "pickle_brand_tex" -- runtime texture name (fed by the DUI)
local DUI_SIZE = 1024               -- DUI surface (square; each prop's UVs map it)
local RANGE    = 150.0              -- how near a branded restaurant must be to apply
local TICK_MS  = 1000               -- how often we re-pick the nearest restaurant

local dui, duiReady, applied = nil, false, false
local currentUrl = nil  -- the image currently pushed to the DUI (nil = none)
local debugUrl   = nil  -- when set, forces this image and pauses the nearest logic

-- ─── DUI + runtime texture ───────────────────────────────────────────────────

local function ensureDui()
    if dui then return end
    local url = ("https://cfx-nui-%s/html/brand.html"):format(GetCurrentResourceName())
    dui = CreateDui(url, DUI_SIZE, DUI_SIZE)
    -- CreateRuntimeTxd returns the txd HANDLE, which is what
    -- CreateRuntimeTextureFromDuiHandle needs (AddReplaceTexture uses the txd NAME).
    local txd = CreateRuntimeTxd(RT_TXD)
    CreateRuntimeTextureFromDuiHandle(txd, RT_TEX, GetDuiHandle(dui))
    -- brand.html loads asynchronously; wait for it, then (re)push the current image.
    CreateThread(function()
        while dui and not IsDuiAvailable(dui) do Wait(50) end
        duiReady = true
        if currentUrl then SendDuiMessage(dui, json.encode({ action = "brand", url = currentUrl })) end
    end)
end

local function pushImage(url)
    currentUrl = url
    if dui and duiReady then SendDuiMessage(dui, json.encode({ action = "brand", url = url or "" })) end
end

local function applyReplacements()
    if applied then return end
    for _, t in ipairs(TARGETS) do AddReplaceTexture(t.txd, t.txn, RT_TXD, RT_TEX) end
    applied = true
end

local function removeReplacements()
    if not applied then return end
    for _, t in ipairs(TARGETS) do RemoveReplaceTexture(t.txd, t.txn) end
    applied = false
end

-- Show `url` on every branded prop, or pass nil to restore the original textures.
local function setBrand(url)
    if url and url ~= "" then
        ensureDui()
        applyReplacements()
        if url ~= currentUrl then pushImage(url) end
    else
        removeReplacements()
        currentUrl = nil
    end
end

-- Warm the DUI at resource start: create the surface and let brand.html paint a
-- frame BEFORE any replacement or model streaming. A COLD DUI (created the instant
-- the replacement registered) was why the first debug run only branded one prop and
-- a second run fixed the rest — the runtime texture wasn't painted yet, so most
-- models' txds bound to nothing. This only creates + paints; it doesn't replace any
-- texture until setBrand() is called.
CreateThread(function()
    Wait(500) -- let CEF settle after the resource starts
    ensureDui()
    while dui and not IsDuiAvailable(dui) do Wait(50) end
    pushImage("") -- paint a (white) frame so the runtime texture is warm/valid
end)

-- ─── nearest-restaurant driver ───────────────────────────────────────────────

-- A restaurant's world anchor: its counter, else its first prop.
local function restaurantCoord(r)
    if r.counter and r.counter.x then
        return vector3(r.counter.x + 0.0, r.counter.y + 0.0, r.counter.z + 0.0)
    end
    local p = r.props and r.props[1]
    if p then return vector3(p.x + 0.0, p.y + 0.0, p.z + 0.0) end
    return nil
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        if debugUrl then
            setBrand(debugUrl)
        else
            local here = GetEntityCoords(PlayerPedId())
            local bestUrl, bestDist
            for _, r in pairs(Restaurants or {}) do
                local url = r.brand_image
                if url and url ~= "" then
                    local c = restaurantCoord(r)
                    if c then
                        local dist = #(here - c)
                        if dist <= RANGE and (not bestDist or dist < bestDist) then
                            bestDist, bestUrl = dist, url
                        end
                    end
                end
            end
            setBrand(bestUrl)
        end
    end
end)

-- ─── debug zone ──────────────────────────────────────────────────────────────
-- /pickle_brand_debug [url]  — spawns every branded model in a row at the debug
-- zone with the render target forced on (so you can eyeball all replacements at
-- once), teleports you there, and toggles off on a second call.

local DEBUG_COORD = vector3(-1190.8749, -891.9343, 14.8598)
local debugProps  = {}

local function spawnModel(model, x, y, z)
    local hash = GetHashKey(model)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local started = GetGameTimer()
    while not HasModelLoaded(hash) and GetGameTimer() - started < 5000 do Wait(0) end
    if not HasModelLoaded(hash) then return nil end
    local ent = CreateObject(hash, x, y, z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ent or not DoesEntityExist(ent) then return nil end
    SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
    FreezeEntityPosition(ent, true)
    return ent
end

local function clearDebug()
    for _, e in ipairs(debugProps) do
        if DoesEntityExist(e) then SetEntityAsMissionEntity(e, true, true); DeleteEntity(e) end
    end
    debugProps = {}
    debugUrl = nil
end

RegisterCommand("pickle_brand_debug", function(_, args)
    if #debugProps > 0 then -- second call: clean up
        clearDebug()
        setBrand(nil)
        print("[brand] debug zone cleared")
        return
    end
    debugUrl = (args[1] and args[1] ~= "" and args[1])
        or "https://placehold.co/512x512/orange/white/png?text=BRAND"

    -- Register the replacement and load the DUI image FIRST — AddReplaceTexture only
    -- takes on textures streamed *after* it's active, so the models must spawn after.
    setBrand(debugUrl)
    SetEntityCoords(PlayerPedId(), DEBUG_COORD.x, DEBUG_COORD.y - 1.5, DEBUG_COORD.z, false, false, false, false)
    CreateThread(function()
        local t0 = GetGameTimer()
        while dui and not IsDuiAvailable(dui) and GetGameTimer() - t0 < 3000 do Wait(50) end
        Wait(300) -- let brand.html fetch + paint the image before the props stream in
        local i = 0
        for _, t in ipairs(TARGETS) do
            -- txd == model name for these props, so it doubles as the model to spawn
            local ent = spawnModel(t.txd, DEBUG_COORD.x + i * 0.8, DEBUG_COORD.y, DEBUG_COORD.z)
            if ent then debugProps[#debugProps + 1] = ent end
            i = i + 1
        end
        print(("[brand] debug zone: spawned %d/%d models with render target -> %s")
            :format(#debugProps, #TARGETS, debugUrl))
    end)
end, false)

-- ─── teardown ────────────────────────────────────────────────────────────────

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    removeReplacements()
    clearDebug()
    if dui then DestroyDui(dui); dui = nil end
end)
