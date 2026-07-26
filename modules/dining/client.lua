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
    fade_ms    = 350,   -- camera ease in/out
    hover_r    = 0.075, -- normalized-screen radius that counts as hovering a pile
}

local render = nil   -- the live SpawnMealRender handle
local vessel = nil   -- { item, slot } of the meal being eaten
local labels = {}    -- [pileIndex] = { label, image, drink }
local cam    = nil
local hovered = nil
local open   = false

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

-- Eat the hovered pile: the server drops exactly its layers and tells us what it
-- was, the ped eats it (the sit pose resumes afterwards), and the view either
-- re-renders what's left or closes on the last mouthful.
local function eatPile(idx)
    if not (open and render and vessel) then return end
    local indices = MealRenderPileIndices(render, idx)
    if not indices or #indices == 0 then return end
    local pile = labels[idx] or {}
    -- take the food off the table BEFORE the animation, so it reads as picked up
    OutlineMealPile(render, nil)
    local res = lib.callback.await("pickle_restaurants:consume:eat", false,
        { item = vessel.item, slot = vessel.slot, indices = indices })
    if not (res and res.ok) then
        if res and res.error then ShowNotification(res.error) end
        return
    end
    ConsumeAnim(res.drink, res.label or pile.label, res.anim)
    ShowNotification(_L(res.drink and "consume_drank" or "consume_ate", res.label or pile.label))
    if res.emptied or #(res.contents or {}) == 0 then return CloseMealView() end
    -- re-lay what's left (indices shift as layers are removed, so the whole
    -- arrangement is rebuilt from the server's fresh view of the slot)
    RefreshMealView()
end

-- (Re)build the laid-out meal from the slot's CURRENT metadata.
function RefreshMealView()
    if not (open and vessel) then return end
    local res = lib.callback.await("pickle_restaurants:consume:mealSpecs", false,
        { item = vessel.item, slot = vessel.slot })
    if not (res and res.ok and res.parts and #res.parts > 0) then return CloseMealView() end
    if render then DeleteMealRender(render); render = nil end
    local ped = PlayerPedId()
    local x, y, z = tablePoint(ped)
    local yaw = GetEntityHeading(ped)
    render = SpawnMealRender(res.parts, res.box and "box" or "tray", x, y, z, yaw)
    -- one label per PILE, taken from the pile's bottom layer (the thing it is)
    labels = {}
    for i, pile in ipairs(render.piles or {}) do
        local first = pile.parts[1]
        for _, spec in ipairs(res.parts) do
            if first and spec.id == first.id then
                labels[i] = { label = spec.label, image = spec.image, drink = spec.drink }
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
    OpenNUI("dining", {})
    RefreshMealView()
    if not open then return end -- RefreshMealView bailed (nothing readable in the slot)

    -- hover loop: project each pile, pick the one nearest the cursor, and feed the
    -- NUI its label/image for the tooltip (the same hover language the kitchen uses)
    CreateThread(function()
        while open do
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
                             drink = l and l.drink })
            -- ESC leaves the meal on the table (it goes back in the inventory intact)
            if IsControlJustReleased(0, 322) then CloseMealView() break end
            Wait(50)
        end
    end)
end

-- A click anywhere in the view eats what the cursor is over (the NUI can't put a
-- DOM target on a world prop, so the world hover decides — exactly like the
-- kitchen's worldClick).
RegisterNUICallback("dining:click", function(_, cb)
    if hovered then eatPile(hovered) end
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
