-- =============================================
--  modules/dining | client.lua
--  EAT-IN. A meal is the sit-down half of the takeaway bag: it can only be eaten
--  while SEATED at one of the restaurant's placed seat anchors, and using it lays
--  the real tray out on the table in front of you as an INTERACTIVE VIEW — the same
--  shape as the kiosk / register: a scripted camera frames it, the NUI takes the
--  cursor, and you click the food you want. The customer never leaves the seat: the
--  ped keeps its sit loop the whole time (nothing here touches its tasks).
--
--  The arrangement is rendered by the KITCHEN's own machinery (SpawnMealRender in
--  modules/cooking/client.lua), so a meal on a diner's table is pixel-identical to
--  the one the cook built — same props, same offsets, same stacking corrections.
--
--  Eating a pile removes exactly the metadata layers it was made of; when the last
--  one goes the meal item is gone from the inventory and the view closes itself.
-- =============================================

-- Where the meal lands and how it's framed. TUNE IN-GAME.
local DINE = {
    reach      = 0.62,  -- how far in front of the seated ped the tray is set down
    probe_up   = 0.75,  -- start the surface probe this far above the seat
    probe_down = 1.30,  -- and cast this far down looking for the table top
    fallback_z = 0.70,  -- table height above the seat anchor when no surface is found
    cam_back   = 0.55,  -- camera: metres behind the tray (toward the diner)
    cam_up     = 0.62,  -- camera: metres above it
    cam_fov    = 42.0,
    fade_ms    = 700,   -- camera ease in/out (deliberately unhurried: this plays
                        -- on every bite, and a quick cut reads as a glitch)
    hover_r    = 0.075, -- normalized-screen radius that counts as hovering a pile
}

local render = nil   -- the live SpawnMealRender handle
local vessel = nil   -- { item, slot } of the meal being eaten
local labels = {}    -- [pileIndex] = { label, image, drink }
local cam    = nil
local hovered = nil
local open   = false
-- True for the length of a mouthful. The hover loop keeps running while the view is
-- open, so without this the cursor would carry on picking out (and outlining) food
-- mid-bite, leaving something highlighted under a camera that has flipped away and
-- letting a second click queue up against a tray that's already being changed.
local busy   = false
-- Where the current arrangement was laid out. Kept so a bite that changed nothing
-- on the table can re-frame the camera without re-running the whole layout.
local laidAt = nil

local function stopCam()
    if not cam then return end
    RenderScriptCams(false, true, DINE.fade_ms, true, true)
    DestroyCam(cam, false)
    cam = nil
end

-- Frame the tray from just over the diner's shoulder: close enough to read the
-- food, angled down like someone looking at their own plate.
local function startCam(x, y, z, yaw)
    local hr = math.rad(yaw)
    cam = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA",
        x - math.sin(hr) * -DINE.cam_back, y + math.cos(hr) * -DINE.cam_back, z + DINE.cam_up,
        0.0, 0.0, 0.0, DINE.cam_fov, false, 0)
    PointCamAtCoord(cam, x, y, z + 0.05)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, DINE.fade_ms, true, true)
end

-- Where this seat's meal goes. An admin-placed tray point (the third seat gizmo)
-- wins outright: a probe can only find whatever geometry happens to be under the
-- diner's reach, which is right for a plain table and wrong for a booth's fixed
-- table, a bar top, or a bench with no table at all. Falls back to the probe below
-- for every seat placed without one.
local function placedTrayPoint()
    local seat = CurrentSeat and CurrentSeat()
    local t = seat and seat.metadata and seat.metadata.tray
    if not (t and t.x and t.y and t.z) then return nil end
    return t.x + 0.0, t.y + 0.0, t.z + 0.0, (t.heading or 0.0) + 0.0
end

-- The surface in front of a seated diner: probe straight down from above the point
-- they'd reach to. A table/counter hit gives its exact top; with nothing under the
-- cursor (an outdoor bench) the meal rests at a sensible table height instead.
local function tablePoint(ped)
    local p = GetOffsetFromEntityInWorldCoords(ped, 0.0, DINE.reach, DINE.probe_up)
    -- SYNCHRONOUS probe: an async shape test only has a result a frame later, and
    -- the meal is laid out immediately on this one.
    local ray = StartExpensiveSynchronousShapeTestLosProbe(
        p.x, p.y, p.z, p.x, p.y, p.z - DINE.probe_down,
        1 | 16, ped, 7) -- world + objects, ignoring the diner
    local _, hit, pos = GetShapeTestResult(ray)
    if hit == 1 and pos then return pos.x, pos.y, pos.z end
    local base = GetEntityCoords(ped)
    return p.x, p.y, base.z + DINE.fallback_z
end

function CloseMealView()
    if not open then return end
    open = false
    hovered = nil
    if render then OutlineMealPile(render, nil); DeleteMealRender(render); render = nil end
    stopCam()
    labels = {}
    vessel = nil
    CloseNUI()
end

-- ESC/Backspace leaves the meal on the table (it goes back in the inventory
-- intact). Handled by the shared per-frame reader in modules/interactive, which
-- also keeps the key from reaching the pause menu. Registered a frame late: the
-- module glob loads `dining` before `interactive`.
CreateThread(function()
    Wait(0)
    SetEscapeHandler("dining", CloseMealView)
end)

-- Eat the hovered pile: the server drops exactly its layers and tells us what it
-- was, the ped eats it (the sit pose resumes afterwards), and the view either
-- re-renders what's left or closes on the last mouthful.
-- `whole` finishes the serving instead of taking a single bite/sip.
local function eatPile(idx, whole)
    if not (open and render and vessel) or busy then return end
    local indices = MealRenderPileIndices(render, idx)
    if not indices or #indices == 0 then return end
    local pile = labels[idx] or {}
    -- Drop the selection for the whole mouthful: nothing outlined, no tooltip, and
    -- the hover loop parked (it can't target while `busy`). What you're eating has
    -- left the table — there is nothing correct for the cursor to be pointing at.
    busy = true
    hovered = nil
    OutlineMealPile(render, nil)
    SendNUIMessage({ action = "diningHover", index = nil })
    local res = lib.callback.await("pickle_restaurants:consume:eat", false,
        { item = vessel.item, slot = vessel.slot, indices = indices, whole = whole or nil })
    if not (res and res.ok) then
        busy = false
        if res and res.error then ShowNotification(res.error) end
        return
    end
    -- Hand the view back to the GAMEPLAY camera for the mouthful. The tray camera
    -- is framed down at the table, so eating under it is a shot of food with the
    -- diner out of frame — the one moment you actually want to see yourself. The
    -- ease is the same fade the view opened with, so it reads as looking up from
    -- your plate rather than a cut. RefreshMealView re-frames afterwards (it only
    -- starts a camera when there isn't one, and stopCam cleared it).
    stopCam()
    ConsumeAnim(res.drink, res.label or pile.label, res.anim, res.props)
    local name = res.label or pile.label
    local remaining = res.bites and res.bites.left or 0
    if remaining > 0 then
        ShowNotification(_L(res.drink and "consume_sipped_left" or "consume_bit_left", name, remaining))
    else
        ShowNotification(_L(res.drink and "consume_drank" or "consume_ate", name))
    end
    if res.emptied or #(res.contents or {}) == 0 then
        busy = false
        return CloseMealView()
    end
    if res.finished then
        -- a serving actually left the table: indices shift as layers are removed,
        -- so the arrangement is rebuilt from the server's fresh view of the slot
        RefreshMealView()
    else
        -- MID-SERVING: nothing left the table, so nothing is re-laid. Rebuilding
        -- here tore down every prop and respawned it — and a takeout box's picture
        -- is a pooled DUI texture, so dropping the last reference to it freed the
        -- texture and re-created it: the flash. Only the count changed, so only the
        -- count is updated, and the camera is re-framed on the layout still standing.
        if labels[idx] then labels[idx].bitesLeft = res.bites and res.bites.left or nil end
        if not cam and laidAt then startCam(laidAt.x, laidAt.y, laidAt.z, laidAt.yaw) end
    end
    busy = false -- the cursor may target again
end

-- (Re)build the laid-out meal from the slot's CURRENT metadata.
function RefreshMealView()
    if not (open and vessel) then return end
    local res = lib.callback.await("pickle_restaurants:consume:mealSpecs", false,
        { item = vessel.item, slot = vessel.slot })
    if not (res and res.ok and res.parts and #res.parts > 0) then return CloseMealView() end
    if render then DeleteMealRender(render); render = nil end
    local ped = PlayerPedId()
    local x, y, z, yaw = placedTrayPoint()
    if not x then
        x, y, z = tablePoint(ped)
        yaw = GetEntityHeading(ped)
    end
    render = SpawnMealRender(res.parts, res.box and "box" or "tray", x, y, z, yaw)
    laidAt = { x = x, y = y, z = z, yaw = yaw }
    -- one label per PILE, taken from the pile's bottom layer (the thing it is)
    labels = {}
    for i, pile in ipairs(render.piles or {}) do
        local first = pile.parts[1]
        for _, spec in ipairs(res.parts) do
            if first and spec.id == first.id then
                -- tipImage/tipCrop, not `image`: a takeout part's `image` is the
                -- picture painted INSIDE the box, which is not what a card shows.
                labels[i] = { label = spec.label, image = spec.tipImage or spec.image,
                              crop = spec.tipCrop, drink = spec.drink,
                              bitesLeft = spec.bitesLeft }
                break
            end
        end
    end
    if not cam then startCam(x, y, z, yaw) end
end

-- Open the eat-in view. Called from modules/consume once the server has confirmed
-- the player is holding a meal (and this client has confirmed they're seated).
function OpenMealView(v, _contents)
    if open or IsCookingOpen and IsCookingOpen() then return end
    vessel = { item = v.item, slot = v.slot }
    open = true
    -- Re-pick the branding NOW rather than waiting up to a tick for the driver:
    -- packaging is painted for the restaurant you are NEAREST, not the one the meal
    -- came from, so a meal carried across town is eaten out of the local
    -- restaurant's boxes and cups — and it should be right on the first frame the
    -- tray appears, not a second into the shot.
    if RefreshBrands then RefreshBrands() end
    -- Skin the view to the restaurant whose seat this is. Every other
    -- restaurant-scoped panel carries its `theme` in the open payload and App.tsx
    -- applies it; without one, the diner's tooltip sat on the default kit while the
    -- room around it was branded.
    local seat = CurrentSeat and CurrentSeat()
    local rest = seat and Restaurants and Restaurants[seat.restaurant_id]
    OpenNUI("dining", { theme = rest and rest.theme or nil })
    RefreshMealView()
    if not open then return end -- RefreshMealView bailed (nothing readable in the slot)

    -- hover loop: project each pile, pick the one nearest the cursor, and feed the
    -- NUI its label/image for the tooltip (the same hover language the kitchen uses)
    CreateThread(function()
        while open do
            -- Mid-mouthful the cursor targets NOTHING: the food is in the diner's
            -- hand, not on the table, and the camera is off the tray entirely.
            -- Clearing here (rather than only at the start of the bite) also stops a
            -- stale outline reappearing on whatever the cursor happens to sit over.
            if busy then
                if hovered then
                    hovered = nil
                    OutlineMealPile(render, nil)
                    SendNUIMessage({ action = "diningHover", index = nil })
                end
                Wait(50)
                goto continue
            end
            local cx, cy = GetNuiCursorPosition()
            local sw, sh = GetActiveScreenResolution()
            local cnx = (sw > 0) and (cx / sw) or 0.0
            local cny = (sh > 0) and (cy / sh) or 0.0
            local near, nearD, tipX, tipY
            for i in ipairs((render and render.piles) or {}) do
                local px, py, pz = MealRenderPileAnchor(render, i)
                if px then
                    local on, sx, sy = GetScreenCoordFromWorldCoord(px, py, pz)
                    if on then
                        local dx, dy = sx - cnx, sy - cny
                        local d2 = dx * dx + dy * dy
                        if not nearD or d2 < nearD then near, nearD, tipX, tipY = i, d2, sx, sy end
                    end
                end
            end
            if nearD and nearD > DINE.hover_r * DINE.hover_r then near = nil end
            if near ~= hovered then
                hovered = near
                OutlineMealPile(render, near)
            end
            local l = near and labels[near] or nil
            SendNUIMessage({ action = "diningHover", index = near,
                             x = tipX, y = tipY, label = l and l.label, image = l and l.image,
                             crop = l and l.crop,
                             drink = l and l.drink, bitesLeft = l and l.bitesLeft })
            Wait(50)
            ::continue::
        end
    end)
end

-- A click anywhere in the view eats what the cursor is over (the NUI can't put a
-- DOM target on a world prop, so the world hover decides — exactly like the
-- kitchen's worldClick).
-- Both actions come from the tooltip's buttons now — a click on the world itself
-- eats nothing. Clicking to eat and a button to finish were two gestures for the
-- same target with no way to tell them apart until after the fact.
RegisterNUICallback("dining:bite", function(_, cb)
    if hovered then eatPile(hovered, false) end
    cb({ ok = true })
end)

-- The tooltip's "finish it": the same pile, consumed in one go.
RegisterNUICallback("dining:finish", function(_, cb)
    if hovered then eatPile(hovered, true) end
    cb({ ok = true })
end)

RegisterNUICallback("dining:close", function(_, cb)
    CloseMealView()
    cb({ ok = true })
end)

-- Standing up (or being pulled out of the seat) puts the meal away.
AddEventHandler("pickle_restaurants:seating:stood", function() CloseMealView() end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    if render then DeleteMealRender(render) end
    stopCam()
end)
