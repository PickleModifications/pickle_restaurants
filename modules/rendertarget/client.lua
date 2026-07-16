-- =============================================
--  modules/rendertarget | client.lua
--  Runtime brand-texture replacement for food-packaging props.
--
--  Each branded packaging texture (cup wrap, pizza box, tray paper, side box) gets
--  its OWN DUI rendering an HTML page (html/brand.html) into a runtime texture, then
--  AddReplaceTexture swaps that runtime texture in for the model's branded texture.
--
--  Why one DUI PER texture (not one shared square surface):
--   • Separate image URLs — a restaurant can put a different image on each piece of
--     packaging (the cup wrap ≠ the pizza-box lid). Each target also falls back to
--     the restaurant's shared brand image when its own URL is blank.
--   • Correct framing — every texture has its OWN aspect ratio (its w×h in TARGETS).
--     The management panel crops the image to that aspect with an adjustable size, and
--     the resulting crop rectangle is drawn pixel-for-pixel onto this DUI, so what the
--     owner cropped is exactly what shows on the prop. With no crop set, the image is
--     just `cover`-cropped to the texture's aspect (centred).
--
--  AddReplaceTexture is GLOBAL (per txd + txn), not per-entity — so there is only
--  ever one brand active at a time. We drive it from the NEAREST restaurant that has
--  any brand configured, swapping images as the player moves between restaurants and
--  removing the replacement (restoring the original texture) when none is in range.
--
--  Finding a texture's resolution: the numbers in TARGETS below define each texture's
--  aspect ratio. Run /pickle_brand_debug (no url) to spawn every branded model with a
--  CALIBRATION grid (a circle + WxH label) drawn on each — a squashed circle means the
--  aspect is wrong. /pickle_brand_res <key> <w> <h> re-sizes a texture's DUI live so
--  you can dial it in, then bake the final numbers in here. NOTE: keep these w/h in
--  sync with BRAND_TEXTURES in web/src/views/Management.tsx (the crop UI's aspects).
-- =============================================

-- The branded textures this module paints are the "packaging" and "kiosk" render
-- targets — a filtered VIEW of the ONE registry in core/shared.lua
-- (`Config.RenderTargets`), so resolution/orientation live in exactly one place and
-- the NUI crop UI reads the same numbers (BrandRenderTargets). Each entry:
--   key/txd/txn — the config id, the model's txd, the texture inside it we replace
--   w/h         — DUI resolution = the texture's real pixel aspect (rot turns it)
--   rot/flipx/flipy — orientation brand.html applies (a pure canvas transform; it does
--                 NOT change what the owner crops). Tune with /pickle_brand_orient.
--   debugGap    — /pickle_brand_debug row footprint (the big kiosk needs more room)
--   blackDefault / configKey — kiosk screens: black when unbranded, and the floor
--                 kiosk borrows the wall kiosk's brand config.
-- The debug commands mutate w/h/rot on these entries live; bake the tuned numbers back
-- into Config.RenderTargets. flipx/flipy default nil (falsey) when omitted there.
local TARGETS = RenderTargetsByGroup("packaging", "kiosk")
local TARGET_BY_KEY, TARGET_BY_MODEL = {}, {}
for _, t in ipairs(TARGETS) do TARGET_BY_KEY[t.key] = t; TARGET_BY_MODEL[t.txd] = t end

local RANGE   = 150.0  -- how near a branded restaurant must be to apply
local TICK_MS = 1000   -- how often we re-pick the nearest restaurant

-- forced state while debugging: a spec shown on EVERY target, pausing the nearest-
-- restaurant logic. nil = normal production driver.
local debugForce = nil  -- { url = "..." } | { calib = true } | nil

-- ─── per-target DUI + runtime texture ────────────────────────────────────────

-- Each target carries its live render state on itself:
--   dui, ready  — the CEF surface + whether brand.html has painted a frame
--   applied     — is AddReplaceTexture currently active for this target
--   sig, cur    — the descriptor currently pushed to the DUI (+ a signature for it,
--                 so we don't re-push an unchanged image every tick)
--   gen         — bumped on every (re)create so the runtime txd/tex names are fresh,
--                 avoiding a stale binding when a DUI is destroyed to resize
local function rtNames(t) return
    ("pickle_brand_txd_%s_%d"):format(t.key, t.gen or 0),
    ("pickle_brand_tex_%s_%d"):format(t.key, t.gen or 0)
end

-- A stable string for a show descriptor, so an unchanged brand isn't re-pushed.
local function specSig(spec)
    if not spec then return "nil" end
    if spec.black then return "black" end
    if spec.calib then return "calib" end
    local c = spec.crop
    local cs = c and ("%s,%s,%s,%s"):format(c.x or 0, c.y or 0, c.w or 0, c.h or 0) or ""
    return "b:" .. (spec.url or "") .. "|" .. cs
end

-- Returns true only if the image was actually sent. A DUI that isn't ready yet drops
-- the push — the caller must NOT mark the image as delivered, so the driver keeps
-- retrying until it lands (the real cause of the blank-on-load: a push made before the
-- DUI was ready was silently lost and never retried).
local function pushToDui(t)
    if not (t.dui and t.ready) then return false end
    local spec = t.cur
    if not spec then return false end
    -- brand.html sizes its canvas to the SURFACE (w/h it receives) and swaps internally
    -- for a 90/270 turn, so it must get the surface dims — derived from the upright
    -- config aspect + rot (RenderTargetSurface), never the raw config w/h.
    local sw, sh = RenderTargetSurface(t)
    if spec.black then
        SendDuiMessage(t.dui, json.encode({ action = "black", w = sw, h = sh,
            key = t.key, res = GetCurrentResourceName() }))
    elseif spec.calib then
        SendDuiMessage(t.dui, json.encode({ action = "calibrate", w = sw, h = sh, key = t.key,
            rot = t.rot or 0, flipx = t.flipx or false, flipy = t.flipy or false }))
    else
        SendDuiMessage(t.dui, json.encode({ action = "brand", url = spec.url or "", crop = spec.crop, w = sw, h = sh,
            rot = t.rot or 0, flipx = t.flipx or false, flipy = t.flipy or false,
            -- key + res let brand.html POST back the moment it has painted (rt:painted)
            key = t.key, res = GetCurrentResourceName() }))
    end
    return true
end

local function ensureDui(t)
    if t.dui then return end
    t.gen = (t.gen or 0) + 1
    t.ready = false
    local url = ("https://cfx-nui-%s/html/brand.html"):format(GetCurrentResourceName())
    -- The DUI surface is the texture's own pixel aspect (upright config w/h swapped for
    -- a 90/270 turn); brand.html rotates the content back upright.
    local sw, sh = RenderTargetSurface(t)
    t.dui = CreateDui(url, sw, sh)
    local txdName, texName = rtNames(t)
    -- CreateRuntimeTxd returns the txd HANDLE (needed by CreateRuntimeTextureFrom-
    -- DuiHandle); AddReplaceTexture keys off the txd NAME.
    local txd = CreateRuntimeTxd(txdName)
    CreateRuntimeTextureFromDuiHandle(txd, texName, GetDuiHandle(t.dui))
    -- brand.html loads asynchronously; wait for it, then (re)push the current image.
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

-- Supersede any pending rebind (a newer brand/image, or a clear).
local function cancelRebind(t) t.rebindSeq = (t.rebindSeq or 0) + 1 end

-- THE fix for the persistent-blank bug: a txd binds to whatever frame the runtime
-- texture holds AT AddReplaceTexture time. brand.html paints its image ASYNC (the
-- image is fetched after we SendDuiMessage), so the bind made when the brand is first
-- applied captures a not-yet-painted (blank/white) surface and the prop stays blank —
-- forever, because the bind doesn't retroactively pick up a later paint. So after the
-- image has actually painted we RE-bind (RemoveReplaceTexture + AddReplaceTexture) to
-- the now-painted surface. Two passes cover an instant local paint and a slower remote
-- image load. The model still has to STREAM IN after the final rebind (cook/hold the
-- item) — that's the engine's stream-after constraint, unchanged.
local function rebindAfterPaint(t)
    t.rebindSeq = (t.rebindSeq or 0) + 1
    local mine = t.rebindSeq
    CreateThread(function()
        local tries = 0
        while t.dui and not IsDuiAvailable(t.dui) and tries < 150 do Wait(30); tries = tries + 1 end
        if not t.dui or t.rebindSeq ~= mine then return end
        -- One safety re-bind in case the brand.html rt:painted POST is ever missed;
        -- normally rt:painted has already rebound precisely by now, making this a no-op.
        Wait(2500)
        if t.dui and t.rebindSeq == mine and t.applied then
            removeReplacement(t)
            applyReplacement(t)
        end
    end)
end

-- Show a spec on this target's packaging, or nil to restore the original texture.
--   spec = { url = "...", crop = { x, y, w, h }? }  — an image, optionally cropped
--          | { calib = true }                        — the calibration grid
local function setTargetBrand(t, spec)
    if spec ~= nil then
        local firstApply = not t.applied
        ensureDui(t)
        applyReplacement(t)
        local sig = specSig(spec)
        local changed = sig ~= t.sig
        if changed then
            t.cur = spec
            -- commit the sig ONLY once the image actually reached the DUI; if the DUI
            -- wasn't ready the push is dropped and t.sig stays, so the next poll tick
            -- re-pushes until it lands. This is what fixes the blank-on-load.
            if pushToDui(t) then t.sig = sig end
        end
        if firstApply or changed then rebindAfterPaint(t) end
    else
        cancelRebind(t)
        removeReplacement(t)
        t.cur, t.sig = nil, nil
    end
end

-- Destroy + rebuild a target's DUI at its current w/h (used by the live-resize debug
-- command). Bumps gen so the fresh runtime texture gets fresh names, and re-applies
-- whatever it was showing.
local function recreateDui(t)
    local wasApplied, wasSpec = t.applied, t.cur
    removeReplacement(t)
    if t.dui then DestroyDui(t.dui); t.dui = nil end
    t.ready, t.cur, t.sig = false, nil, nil
    if wasApplied or wasSpec ~= nil then setTargetBrand(t, wasSpec) end
end

-- Warm every DUI at resource start: create the surface and let brand.html paint a
-- frame BEFORE any replacement or model streaming. A COLD DUI (created the instant
-- the replacement registered) branded only one prop on the first run — the runtime
-- texture wasn't painted yet, so most models' txds bound to nothing. This only
-- creates + paints a blank frame; it doesn't replace any texture until a brand is set.
CreateThread(function()
    Wait(500) -- let CEF settle after the resource starts
    for _, t in ipairs(TARGETS) do
        ensureDui(t)
        -- Screen targets warm to solid BLACK (their unbranded default); the packaging
        -- targets warm to a white/blank frame (their paper/packaging default).
        local spec = t.blackDefault and { black = true } or { url = "" }
        t.cur, t.sig = spec, specSig(spec)
        pushToDui(t)
    end
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

-- Any brand configured at all (a per-texture url or the shared default)?
local function hasBrand(r)
    if r.brand_image and r.brand_image ~= "" then return true end
    if r.brand_images then
        for _, o in pairs(r.brand_images) do
            local u = (type(o) == "table") and o.url or o
            if u and u ~= "" then return true end
        end
    end
    return false
end

-- The image + crop a given texture should show for this restaurant: its own
-- per-texture override when set, else the restaurant's shared brand image (no crop),
-- else nil (restore original). Returns a spec table or nil.
local function specForTarget(r, t)
    if not r then return nil end
    -- A target may borrow another's brand config (the floor kiosk reads the wall
    -- kiosk's image) via `configKey`; otherwise it reads its own key.
    local key = t.configKey or t.key
    local o = r.brand_images and r.brand_images[key]
    if type(o) == "table" and o.url and o.url ~= "" then
        return { url = o.url, crop = o.crop }
    elseif type(o) == "string" and o ~= "" then
        return { url = o }
    end
    if r.brand_image and r.brand_image ~= "" then return { url = r.brand_image } end
    return nil
end

-- Push a restaurant's branding across every target (nil restaurant = clear all).
local function applyBrand(r)
    for _, t in ipairs(TARGETS) do
        local spec = specForTarget(r, t)
        -- Screen targets (the kiosks) default to solid black when no brand is configured,
        -- rather than reverting to the model's baked-in placeholder texture (the packaging
        -- targets keep restoring their original texture).
        if not spec and t.blackDefault then spec = { black = true } end
        setTargetBrand(t, spec)
    end
end

-- One pass of the production driver: force the debug spec on everything, or apply
-- the nearest branded restaurant (nil = none in range → restore original textures).
local function driveOnce()
    if debugForce then
        for _, t in ipairs(TARGETS) do setTargetBrand(t, debugForce) end
        return
    end
    local here = GetEntityCoords(PlayerPedId())
    local best, bestDist
    for _, r in pairs(Restaurants or {}) do
        if hasBrand(r) then
            local c = restaurantCoord(r)
            if c then
                local dist = #(here - c)
                if dist <= RANGE and (not bestDist or dist < bestDist) then
                    bestDist, best = dist, r
                end
            end
        end
    end
    applyBrand(best)
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        driveOnce()
    end
end)

-- Re-assert every replacement from scratch, forcing the image to re-push and — via
-- setTargetBrand → rebindAfterPaint — the txd to re-bind once brand.html has PAINTED
-- the image (not against the blank surface it would otherwise catch). Runs on the
-- sync handler the instant brand_images changes, plus /pickle_brand_reload. You still
-- need the branded model to STREAM IN after the final rebind (cook/hold the item) —
-- AddReplaceTexture only takes on txds streamed while it's active.
function RefreshBrands()
    if debugForce then return end -- don't fight an active debug session
    for _, t in ipairs(TARGETS) do
        removeReplacement(t) -- drop the stale binding so setTargetBrand re-binds fresh
        t.sig = nil          -- force the current image to re-push to the (warm) DUI
    end
    driveOnce()
end

-- Called by the cooking module the instant it spawns a branded prop. AddReplaceTexture
-- reliably takes when a prop of the model actually EXISTS, so re-assert the matching
-- target's replacement now (remove + re-add) — this is why a brand only appeared after
-- you pulled the item out AND reloaded: the reload re-asserted while the prop existed.
-- No-op unless that target currently has a brand applied.
function ReassertBrandFor(model)
    local t = model and TARGET_BY_MODEL[model]
    if t and t.applied and not debugForce then
        removeReplacement(t)
        applyReplacement(t)
    end
end

-- brand.html POSTs here the instant it has PAINTED the image into the DUI surface. We
-- (re)bind the replacement now, against a real frame — the definitive fix for a
-- pre-configured brand loading blank because the (remote) image finished painting only
-- AFTER the initial bind caught a blank surface. Only a real image paint fires this
-- (a blank/calibration frame never does), so t.cur is the active brand. Idempotent.
RegisterNUICallback("rt:painted", function(d, cb)
    local t = d and d.key and TARGET_BY_KEY[d.key]
    if t and t.dui and t.cur and not debugForce then
        removeReplacement(t)
        applyReplacement(t)
    end
    cb("ok")
end)

-- ─── debug zone ──────────────────────────────────────────────────────────────
-- /pickle_brand_debug [url]  — spawns every branded model in a row with the render
--   target forced on, teleports you there, and toggles off on a second call. With
--   no url each texture shows a CALIBRATION grid (circle + WxH) so you can spot a
--   wrong aspect ratio per prop; pass a url to preview a real image on all of them.
-- /pickle_brand_res [key w h] — with no args, lists every target + its resolution;
--   with a key + w + h, resizes that texture's DUI live so you can find the number
--   that makes the calibration circle round, then bake it into TARGETS above.
-- /pickle_brand_orient [key rot flipx flipy] — with no args, lists each target's
--   orientation; with a key it sets rot (0/90/180/270) + optional flipx/flipy (0/1)
--   live so you can turn the calibration "UP" arrow upright, then bake it into TARGETS.

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
    debugForce = nil
end

RegisterCommand("pickle_brand_debug", function(_, args)
    if #debugProps > 0 then -- second call: clean up
        clearDebug()
        applyBrand(nil)
        print("[brand] debug zone cleared")
        return
    end
    -- no url = calibration grid (default); a url previews a real image on every prop
    debugForce = (args[1] and args[1] ~= "") and { url = args[1] } or { calib = true }

    -- Register the replacements and load the DUI images FIRST — AddReplaceTexture
    -- only takes on textures streamed *after* it's active, so the models spawn after.
    for _, t in ipairs(TARGETS) do setTargetBrand(t, debugForce) end
    SetEntityCoords(PlayerPedId(), DEBUG_COORD.x, DEBUG_COORD.y - 1.5, DEBUG_COORD.z, false, false, false, false)
    CreateThread(function()
        local t0 = GetGameTimer()
        for _, t in ipairs(TARGETS) do
            while t.dui and not IsDuiAvailable(t.dui) and GetGameTimer() - t0 < 3000 do Wait(50) end
        end
        Wait(300) -- let brand.html fetch + paint before the props stream in
        -- Lay the props out along X, each centred in its own footprint (debugGap)
        -- with half-gap padding on both sides, so a wide model (the kiosk) never
        -- overlaps its neighbours the way a fixed 0.8m step did.
        local x = DEBUG_COORD.x
        for _, t in ipairs(TARGETS) do
            local half = (t.debugGap or 0.8) * 0.5
            x = x + half
            -- txd == model name for these props, so it doubles as the model to spawn
            local ent = spawnModel(t.txd, x, DEBUG_COORD.y, DEBUG_COORD.z)
            if ent then debugProps[#debugProps + 1] = ent end
            x = x + half
        end
        print(("[brand] debug zone: spawned %d/%d models -> %s")
            :format(#debugProps, #TARGETS, debugForce.calib and "calibration grid" or debugForce.url))
    end)
end, false)

RegisterCommand("pickle_brand_res", function(_, args)
    local key, w, h = args[1], tonumber(args[2]), tonumber(args[3])
    if not key then
        print("[brand] texture resolutions (bake the tuned values into TARGETS):")
        for _, t in ipairs(TARGETS) do
            print(("  %-10s %s  ->  %d x %d"):format(t.key, t.txd, t.w, t.h))
        end
        print("[brand] usage: /pickle_brand_res <key> <width> <height>")
        return
    end
    local t = TARGET_BY_KEY[key]
    if not t then return print(("[brand] unknown texture key '%s'"):format(key)) end
    if not (w and h and w > 0 and h > 0) then
        return print("[brand] usage: /pickle_brand_res <key> <width> <height>")
    end
    t.w, t.h = math.floor(w), math.floor(h)
    recreateDui(t)
    print(("[brand] %s resized to %d x %d — bake this into TARGETS when it looks right")
        :format(t.key, t.w, t.h))
end, false)

-- /pickle_brand_reload — re-assert the render-target bindings without restarting the
-- resource (what you used to restart for). Run after editing a brand, then re-stream
-- the branded model (cook/hold the item) to see the new art.
RegisterCommand("pickle_brand_reload", function()
    RefreshBrands()
    print("[brand] replacements re-asserted — re-spawn/hold the branded item to see it")
end, false)

RegisterCommand("pickle_brand_orient", function(_, args)
    local key = args[1]
    if not key then
        print("[brand] texture orientations (bake the tuned values into TARGETS):")
        for _, t in ipairs(TARGETS) do
            print(("  %-10s rot=%-3d flipx=%s flipy=%s"):format(
                t.key, t.rot or 0, tostring(t.flipx or false), tostring(t.flipy or false)))
        end
        print("[brand] usage: /pickle_brand_orient <key> <rot 0|90|180|270> [flipx 0|1] [flipy 0|1]")
        return
    end
    local t = TARGET_BY_KEY[key]
    if not t then return print(("[brand] unknown texture key '%s'"):format(key)) end
    local rot = tonumber(args[2])
    if not rot then return print("[brand] usage: /pickle_brand_orient <key> <rot 0|90|180|270> [flipx 0|1] [flipy 0|1]") end
    t.rot   = (math.floor(rot / 90 + 0.5) * 90) % 360
    t.flipx = (args[3] == "1" or args[3] == "true")
    t.flipy = (args[4] == "1" or args[4] == "true")
    -- A 90/270 turn changes the SURFACE aspect (the upright w/h swap), so rebuild the DUI
    -- at the new surface rather than just repainting.
    recreateDui(t)
    print(("[brand] %s orient rot=%d flipx=%s flipy=%s — bake this into Config.RenderTargets when the UP arrow points up")
        :format(t.key, t.rot, tostring(t.flipx), tostring(t.flipy)))
end, false)

-- ─── teardown ────────────────────────────────────────────────────────────────

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, t in ipairs(TARGETS) do
        removeReplacement(t)
        if t.dui then DestroyDui(t.dui); t.dui = nil end
    end
    clearDebug()
end)
