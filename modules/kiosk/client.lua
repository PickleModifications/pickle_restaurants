-- =============================================
--  modules/kiosk | client.lua
--  The self-service kiosk as an INTERACTIVE in-world DUI screen, not a fullscreen
--  NUI. Idle, the kiosk shows the restaurant's BRAND (modules/rendertarget paints
--  `kiosk_large_brand`). On interact we:
--    1. SUSPEND the brand render target for the kiosk (SuspendBrandTarget), so it
--       stops driving `kiosk_large_brand`, and
--    2. take over that same texture with OUR order-page DUI (the built React app in
--       "#kiosk" mode — views/KioskDui.tsx), pointed at the model the player is at.
--  A scripted camera frames the screen head-on and the player drives a VIRTUAL
--  CURSOR (mouse-look deltas → SendDuiMouse*) over the page. Placing an order or
--  stepping away restores the brand (ResumeBrandTarget).
--
--  There is NO fullscreen focus grab: the game stays in control, we just disable
--  input for the duration and forward the cursor to the DUI. The order still becomes
--  an ordinary kitchen ticket (modules/sales `sales:kioskOrder`), so nothing about
--  the fulfilment flow changes.
--
--  Everything geometry-shaped here (camera framing, cursor speed, DUI aspect) is a
--  best-guess default — TUNE IN-GAME with /pickle_kiosk_cam and /pickle_kiosk_res.
-- =============================================

-- The DUI runs the built React app at this resolution = the kiosk screen's pixel
-- aspect (matches the brand target's kiosk res, portrait). TUNE IN-GAME.
local KIOSK = {
    w = 1080, h = 1920,
    -- Virtual-cursor speed relative to raw mouse-look delta (higher = faster).
    -- TUNE IN-GAME with /pickle_kiosk_sens <n>.
    sensitivity = 0.5,
    -- Per-model framing, in the PROP'S local space (y = the prop's forward):
    --   cam  = where the camera sits (in front of the screen, looking back at it)
    --   look = the screen centre the camera aims at
    --   fov  = camera field of view (smaller = tighter crop on the screen)
    -- The two kiosk models differ only in screen height off the ground.
    geo = {
        ["kiosk"]        = { cam = vec3(0.0, -1.85, 0.0), look = vec3(0.0, 0.0, 0.0), fov = 42.0 },
        ["kiosk_ground"] = { cam = vec3(0.0, -1.85, 1.25), look = vec3(0.0, 0.0, 1.25), fov = 44.0 },
    },
}

-- ─── order-page DUI (created once, reused) ───────────────────────────────────

local dui, duiReady, duiGen = nil, false, 0

local function rtNames()
    return ("pickle_kiosk_txd_%d"):format(duiGen), ("pickle_kiosk_tex_%d"):format(duiGen)
end

local function ensureDui()
    if dui then return end
    duiGen = duiGen + 1
    duiReady = false
    local url = ("https://cfx-nui-%s/nui/index.html#kiosk"):format(GetCurrentResourceName())
    dui = CreateDui(url, KIOSK.w, KIOSK.h)
    local txdName, texName = rtNames()
    local txd = CreateRuntimeTxd(txdName)
    CreateRuntimeTextureFromDuiHandle(txd, texName, GetDuiHandle(dui))
    CreateThread(function()
        local mine = duiGen
        while dui and duiGen == mine and not IsDuiAvailable(dui) do Wait(50) end
        if duiGen == mine then duiReady = true end
    end)
end

-- Which kiosk model our order DUI currently replaces (nil = not applied). The
-- replacement is per-txd, so we only take over the model the player is actually at.
local appliedModel = nil
-- The data payload currently being shown/pushed (identity-checked so a stale retry
-- loop from an earlier open stops the moment a new push begins).
local pendingPayload = nil

-- Session state, declared up here so the helper closures below capture the LOCALS
-- (a later declaration would leave those closures reading a stray global instead).
local active = nil          -- { model, ent, rid } while a kiosk is open, else nil
local vx, vy = 0.5, 0.5     -- virtual cursor, normalised [0..1]
local lastCurX, lastCurY    -- last cursor pos pushed to the page (skip idle resends)
local lastDown              -- last button-down state pushed to the page

-- The kiosk screen's texture ORIENTATION, borrowed from the brand target each open
-- (kiosk_large_brand's rot/flip). The order page must paint with the SAME transform
-- to land upright on the prop, so we forward it to KioskDui AND apply it to the
-- cursor→surface mapping below.
local orient = { rot = 0, flipx = false, flipy = false }

-- Map the virtual cursor (u,v — the UPRIGHT content the player sees, [0..1]) to a
-- pixel on the DUI SURFACE, applying the exact transform brand.html's withOrient
-- uses (rotate about centre + flips). For a 90/270 turn the content box is landscape
-- (W/H swapped) — which is also why the order UI gets a proper wide layout there.
local function surfacePoint(u, v)
    local W, H = KIOSK.w, KIOSK.h
    local rot = orient.rot % 360
    local swap = (rot == 90 or rot == 270)
    local DW = swap and H or W
    local DH = swap and W or H
    local fx = orient.flipx and -1.0 or 1.0
    local fy = orient.flipy and -1.0 or 1.0
    local cx = (u - 0.5) * DW * fx
    local cy = (v - 0.5) * DH * fy
    local rad = math.rad(rot)
    local cos, sin = math.cos(rad), math.sin(rad)
    local sx = W * 0.5 + (cos * cx - sin * cy)
    local sy = H * 0.5 + (sin * cx + cos * cy)
    return math.floor(sx + 0.5), math.floor(sy + 0.5)
end

local function applyOrderScreen(model)
    if appliedModel == model then return end
    if appliedModel then RemoveReplaceTexture(appliedModel, "kiosk_large_brand") end
    local txdName, texName = rtNames()
    AddReplaceTexture(model, "kiosk_large_brand", txdName, texName)
    appliedModel = model
end

local function removeOrderScreen()
    if not appliedModel then return end
    RemoveReplaceTexture(appliedModel, "kiosk_large_brand")
    appliedModel = nil
end

-- Re-bind once the page has actually painted a real frame, so the texture binds to
-- live content instead of the blank surface the first bind would catch (the same
-- blank-on-load fix modules/rendertarget / modules/screens use).
local function rebindAfterPaint(model)
    CreateThread(function()
        local tries = 0
        while dui and not IsDuiAvailable(dui) and tries < 150 do Wait(30); tries = tries + 1 end
        if not dui or appliedModel ~= model then return end
        Wait(500)
        if dui and appliedModel == model then
            RemoveReplaceTexture(model, "kiosk_large_brand")
            local txdName, texName = rtNames()
            AddReplaceTexture(model, "kiosk_large_brand", txdName, texName)
        end
    end)
end

-- KioskDui POSTs here the instant it has rendered the order UI (i.e. it received our
-- data). That both ACKs the data push (so we stop resending) and lets us bind the
-- texture against a live frame (mirrors rt:painted / screen:painted).
local dataAcked = false
RegisterNUICallback("kiosk:painted", function(_, cb)
    dataAcked = true
    if dui and appliedModel then
        RemoveReplaceTexture(appliedModel, "kiosk_large_brand")
        local txdName, texName = rtNames()
        AddReplaceTexture(appliedModel, "kiosk_large_brand", txdName, texName)
    end
    cb("ok")
end)

-- Push the order data to the page, resending until it acknowledges (kiosk:painted).
-- On the FIRST open the DUI is still loading the React bundle, so a single send would
-- be lost before the page's message listener exists — hence the retry loop.
local function pushKioskData(payload)
    dataAcked = false
    local mine = payload
    CreateThread(function()
        local tries = 0
        while active and pendingPayload == mine and not dataAcked and tries < 60 do
            if dui then SendDuiMessage(dui, json.encode({ action = "kioskData", data = mine, orient = orient })) end
            tries = tries + 1
            Wait(200)
        end
    end)
end

-- ─── scripted framing camera ─────────────────────────────────────────────────

local kioskCam = nil

-- World position of a prop-local offset, from the entity when we have it (exact),
-- else computed from the placed heading (fallback if the prop isn't streamed).
local function localToWorld(prop, ent, off)
    if ent and DoesEntityExist(ent) then
        return GetOffsetFromEntityInWorldCoords(ent, off.x, off.y, off.z)
    end
    local h = math.rad(prop.heading or 0.0)
    local c, s = math.cos(h), math.sin(h)
    return vec3(prop.x + (off.x * c - off.y * s), prop.y + (off.x * s + off.y * c), (prop.z or 0.0) + off.z)
end

local function setupCam(prop, ent, geo)
    if kioskCam then DestroyCam(kioskCam, false); kioskCam = nil end -- re-frame: no leak
    local camPos  = localToWorld(prop, ent, geo.cam)
    local lookPos = localToWorld(prop, ent, geo.look)
    kioskCam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(kioskCam, camPos.x, camPos.y, camPos.z)
    PointCamAtCoord(kioskCam, lookPos.x, lookPos.y, lookPos.z)
    SetCamFov(kioskCam, geo.fov or 42.0)
    SetCamActive(kioskCam, true)
    RenderScriptCams(true, true, 350, true, true)
end

local function teardownCam()
    RenderScriptCams(false, true, 350, true, true)
    if kioskCam then DestroyCam(kioskCam, false); kioskCam = nil end
end

-- ─── the interactive session ─────────────────────────────────────────────────

local function helpThisFrame()
    -- Re-arm only once the last bubble has expired, so we don't re-trigger the beep
    -- every frame (the message lingers ~7s on its own).
    if IsHelpMessageBeingDisplayed() then return end
    AddTextEntry("pk_kiosk_help", _L("kiosk_exit_hint"))
    BeginTextCommandDisplayHelp("pk_kiosk_help")
    EndTextCommandDisplayHelp(0, false, true, -1)
end

function CloseKioskScreen()
    if not active then return end
    local brandKey = active.brandKey or "kiosk"
    active = nil
    if dui then SendDuiMouseUp(dui, "l") end -- release a held button, just in case
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    teardownCam()
    removeOrderScreen()
    if ResumeBrandTarget then ResumeBrandTarget(brandKey) end
    if dui then SendDuiMessage(dui, json.encode({ action = "kioskReset" })) end
end

-- Opened from main's kiosk interaction (both wall `kiosk` and floor `kiosk_ground`).
function OpenKioskScreen(prop, ent)
    if active then return end
    local rid = prop.restaurant_id
    local data = lib.callback.await("pickle_restaurants:sales:getKiosk", false, { id = rid })
    if not data or not data.ok then
        return ShowNotification((data and data.error) or _L("sales_kiosk_unavailable"))
    end
    local geo = KIOSK.geo[prop.prop_type] or KIOSK.geo["kiosk"]

    -- Which brand target owns THIS kiosk model. The wall (`kiosk`) and floor
    -- (`kiosk_ground`) paint the shared texture at different rotations, so we must
    -- borrow the orientation of — and suspend — the one for the model we're at.
    local brandKey = (GetBrandKeyForModel and GetBrandKeyForModel(prop.model)) or "kiosk"

    -- match that brand target's orientation so the order page lands upright, exactly
    -- like the brand image does (rot/flip of kiosk_large_brand on this model).
    if GetBrandTargetOrient then
        local o = GetBrandTargetOrient(brandKey)
        if o then orient = { rot = o.rot or 0, flipx = o.flipx or false, flipy = o.flipy or false } end
    end

    ensureDui()
    -- take the kiosk texture over from the brand driver, on THIS model only
    if SuspendBrandTarget then SuspendBrandTarget(brandKey) end
    applyOrderScreen(prop.model)

    setupCam(prop, ent, geo)
    vx, vy = 0.5, 0.5
    lastCurX, lastCurY = nil, nil -- force the cursor to (re)show, centred, this open
    -- Hide the player for the duration, like stepping into an interactive entity:
    -- the scripted camera frames only the screen, so the ped shouldn't be in shot.
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    active = { model = prop.model, ent = ent, rid = rid, brandKey = brandKey }

    pendingPayload = data
    pushKioskData(data)         -- resends until the page acknowledges
    rebindAfterPaint(prop.model)
end

-- KioskDui's "Done" button asks us to step away.
RegisterNUICallback("kiosk:exit", function(_, cb)
    CloseKioskScreen()
    cb("ok")
end)

-- The focus / cursor loop: only spins while a kiosk is open.
CreateThread(function()
    while true do
        if active then
            DisableAllControlActions(0)
            HideHudAndRadarThisFrame()
            helpThisFrame()

            -- mouse-look deltas drive the virtual cursor (read even while disabled).
            -- Two things happen with (vx,vy): the DUI mouse is moved to the matching
            -- SURFACE pixel (so clicks hit-test correctly), and the page is told the
            -- UPRIGHT position so it can draw the cursor ITSELF. CEF doesn't composite
            -- its own cursor onto the runtime texture in this build, and a world-drawn
            -- sprite lives in a different projection than the click — so the page draws
            -- the cursor inside its rotated stage, guaranteeing it sits exactly where a
            -- click lands. Both are the same (vx,vy), so cursor and click always agree.
            local dx = GetDisabledControlNormal(0, 1) -- LookLeftRight
            local dy = GetDisabledControlNormal(0, 2) -- LookUpDown
            -- Left mouse, detected two ways for robustness: INPUT_ATTACK (24) and
            -- INPUT_CURSOR_ACCEPT (237). Whichever the build reports for a disabled
            -- left-click, we forward it to the DUI.
            local pressed     = IsDisabledControlPressed(0, 24)     or IsDisabledControlPressed(0, 237)
            local justPressed = IsDisabledControlJustPressed(0, 24)  or IsDisabledControlJustPressed(0, 237)
            local justUp      = IsDisabledControlJustReleased(0, 24) or IsDisabledControlJustReleased(0, 237)
            -- FREEZE the cursor while the button is held OR being released this frame:
            -- the mousedown and mouseup must land on the SAME element for the browser
            -- to fire a `click`, and a physical mouse always drifts a little as you
            -- press/release. (The release frame also has to stay put — moving it before
            -- SendDuiMouseUp would send the up on a different element.)
            if not pressed and not justUp then
                -- The cursor lives in normalised [0..1] space, but the surface is
                -- PORTRAIT — one unit of vy spans DH pixels, one unit of vx spans DW,
                -- and DH > DW — so equal mouse travel would move the cursor MORE pixels
                -- vertically (it feels faster up/down). Scale each axis by its share of
                -- the SHORTER side so a given mouse motion covers the same number of
                -- pixels either way. (swap for a 90/270 screen, matching surfacePoint.)
                local rot  = orient.rot % 360
                local swap = (rot == 90 or rot == 270)
                local DW   = swap and KIOSK.h or KIOSK.w
                local DH   = swap and KIOSK.w or KIOSK.h
                local ref  = math.min(DW, DH)
                vx = math.max(0.0, math.min(1.0, vx + dx * KIOSK.sensitivity * (ref / DW)))
                vy = math.max(0.0, math.min(1.0, vy + dy * KIOSK.sensitivity * (ref / DH)))
            end
            if dui then
                local sx, sy = surfacePoint(vx, vy)
                SendDuiMouseMove(dui, sx, sy)
                -- push the cursor when it moves OR the button state changes (so the
                -- page can tint it while pressed — a live check that Lua sees the click)
                if vx ~= lastCurX or vy ~= lastCurY or pressed ~= lastDown then
                    lastCurX, lastCurY, lastDown = vx, vy, pressed
                    SendDuiMessage(dui, json.encode({ action = "kioskCursor", x = vx, y = vy, down = pressed }))
                end
                -- wheel scroll (mouse wheel up / down)
                if IsDisabledControlPressed(0, 241) then SendDuiMouseWheel(dui, 45, 0) end
                if IsDisabledControlPressed(0, 242) then SendDuiMouseWheel(dui, -45, 0) end
                -- CLICK. CEF's SendDuiMouseDown/Up don't resolve to a page click in
                -- this build (they don't reuse the last SendDuiMouseMove position, so
                -- the click lands at the surface origin, not under the cursor). So we
                -- hand the page the exact SURFACE pixel and let it hit-test + dispatch
                -- a real DOM click there itself (kioskClick) — build-independent.
                if justPressed then
                    SendDuiMessage(dui, json.encode({ action = "kioskClick", x = sx, y = sy }))
                end
            end

            -- step away: ESC / Backspace
            if IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 202)
                or IsDisabledControlJustPressed(0, 322) or IsDisabledControlJustPressed(0, 194) then
                CloseKioskScreen()
            end

            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- ─── in-game tuning ──────────────────────────────────────────────────────────
-- /pickle_kiosk_cam — while standing at an OPEN kiosk, nudge the framing live:
--   fov <n>            set field of view
--   cam <x> <y> <z>    camera offset (prop-local)
--   look <x> <y> <z>   look-at offset (prop-local)
-- Then bake the numbers into KIOSK.geo above.
RegisterCommand("pickle_kiosk_cam", function(_, args)
    if not active then return print("[kiosk] open a kiosk first, then tune its camera") end
    -- resolve the geo of the model we're at
    local key = (active.model == "pickle_kiosk_large_02") and "kiosk_ground" or "kiosk"
    local geo = KIOSK.geo[key]
    local sub = args[1]
    if sub == "fov" and tonumber(args[2]) then
        geo.fov = tonumber(args[2]) + 0.0
    elseif sub == "cam" and tonumber(args[4]) then
        geo.cam = vec3(tonumber(args[2]) + 0.0, tonumber(args[3]) + 0.0, tonumber(args[4]) + 0.0)
    elseif sub == "look" and tonumber(args[4]) then
        geo.look = vec3(tonumber(args[2]) + 0.0, tonumber(args[3]) + 0.0, tonumber(args[4]) + 0.0)
    else
        print(("[kiosk] %s  fov=%.1f cam=%.2f,%.2f,%.2f look=%.2f,%.2f,%.2f"):format(
            key, geo.fov, geo.cam.x, geo.cam.y, geo.cam.z, geo.look.x, geo.look.y, geo.look.z))
        return print("[kiosk] usage: /pickle_kiosk_cam <fov n | cam x y z | look x y z>")
    end
    -- reframe live
    if active.ent then setupCam({ x = 0, y = 0, z = 0, heading = 0 }, active.ent, geo) end
    print(("[kiosk] %s reframed"):format(key))
end, false)

-- /pickle_kiosk_sens [n] — cursor speed. No arg prints the current value. Bake the
-- number you like into KIOSK.sensitivity above.
RegisterCommand("pickle_kiosk_sens", function(_, args)
    local n = tonumber(args[1])
    if not n or n <= 0 then
        return print(("[kiosk] sensitivity %.2f — usage: /pickle_kiosk_sens <n>"):format(KIOSK.sensitivity))
    end
    KIOSK.sensitivity = n + 0.0
    print(("[kiosk] sensitivity set to %.2f — bake it into KIOSK.sensitivity when it feels right"):format(KIOSK.sensitivity))
end, false)

RegisterCommand("pickle_kiosk_res", function(_, args)
    local w, h = tonumber(args[1]), tonumber(args[2])
    if not (w and h and w > 0 and h > 0) then
        return print(("[kiosk] resolution %dx%d — usage: /pickle_kiosk_res <w> <h>"):format(KIOSK.w, KIOSK.h))
    end
    KIOSK.w, KIOSK.h = math.floor(w), math.floor(h)
    -- rebuild the DUI at the new aspect
    local wasModel = appliedModel
    removeOrderScreen()
    if dui then DestroyDui(dui); dui = nil; duiReady = false end
    ensureDui()
    if wasModel then applyOrderScreen(wasModel); rebindAfterPaint(wasModel) end
    print(("[kiosk] DUI resized to %dx%d"):format(KIOSK.w, KIOSK.h))
end, false)

-- ─── teardown ────────────────────────────────────────────────────────────────

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    if active then
        RenderScriptCams(false, false, 0, true, true)
        if kioskCam then DestroyCam(kioskCam, false) end
        local ped = PlayerPedId()
        SetEntityVisible(ped, true, false)
        FreezeEntityPosition(ped, false)
    end
    removeOrderScreen()
    if dui then DestroyDui(dui); dui = nil end
end)
