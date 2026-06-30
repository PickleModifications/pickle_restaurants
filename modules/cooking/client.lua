-- =============================================
--  modules/cooking | client.lua
--  The interactive station experience: a full-width bottom NUI bar of
--  ingredients you drag out into the 3D world (spawns the real food prop,
--  which cooks 01->02->03), plus draggable on-screen chips over each world
--  food prop that you drag back onto the bar to collect into your inventory.
--
--  Both placing a new ingredient and re-dragging an already-placed prop move
--  the *real* world prop live under the cursor (collision off, so the cursor
--  ray passes through it).
--
--  Beef patties are dual-sided: one logical item rendered as two stacked props
--  (the down face rolled 180 so it faces the pan). Only the down face cooks;
--  clicking the patty flips it to cook the other side. Each side's cook state
--  is independent.
-- =============================================

local CookObjects = {} -- [uid] = entity (single items; for dual = the up-facing prop)
local CookState   = {} -- [uid] = state string (single items)
local CookCoords  = {} -- [uid] = { x, y, z }

-- Dual-sided patties: two props per uid, one per face.
local CookDual      = {} -- [uid] = { ent = {[1],[2]}, modelName = {}, sides = {}, flipped, input }
local CookEntityUid = {} -- [entity] = uid (reverse lookup for hover/click hit-testing)
local DualTween     = {} -- [uid] = tween token (cancels an in-flight flip animation)

cookingOpen      = false
currentCookProp  = nil

local placing = nil -- live drag-to-place preview: { entity, kind, item, hit, coords }
local moving  = nil -- live drag of an already-placed prop: { uid, hit, coords, origin }

-- Stacked-face framing for dual patties. Two face props stacked back-to-back:
-- the BOTTOM face sits on the grill and is the one that cooks; the TOP face is
-- the visible side and doesn't cook until you flip it down.
local DUAL = {
    -- Roll (deg) of each face. If the patty looks upside-down, swap these two.
    top_roll    = 180.0,   -- the visible (not-cooking) face on top
    bottom_roll = 0.0, -- the grill-facing (cooking) face below
    -- The top face sits this far ABOVE the bottom (cooking) face. Set it to
    -- roughly the patty's thickness so the two don't overlap / z-fight.
    face_gap    = 0.0075,
    -- The whole patty is raised by this so the bottom (cooking) face rests ON the
    -- grill instead of sinking through it (we drop on the surface point, but the
    -- bottom face has its own height below that). Tune up until it sits flush.
    base_lift   = 0.0075,
    tween_ms    = 250,
}

-- A slice of cheese melted on the patty's visible (up) face. Sits a hair above
-- the top face; the model swaps from applied -> melted. z/roll need in-game tuning.
local CHEESE = {
    model_applied = "pickle_cheese_applied_01",
    model_melted  = "pickle_cheese_applied_02",
    z    = 0.01,
    roll = 180.0,
}

-- Interactive prep build: a free-form pile of draggable parts on the prep table.
-- Each placed part is its own entity (or set, for a dual patty) that you can grab
-- and restack however you like — dropping onto/over another part rests it on top.
-- step = minimum stack spacing when a model reports ~no height.
local PREP = { step = 0.03 }
-- A bun is two halves you stack: bottom (_02) then top (_01).
local BUN = { bottom = "pickle_bread_bun_02", top = "pickle_bread_bun_01" }
-- [puid] = { id, ents = {…}, dual, item, source, cheese, half, base = {x,y,z}, height, foot }
local PrepParts = {}
local prepUid     = 0
local prepHovered = nil  -- puid under the cursor (for grabbing)
local prepMoving  = nil  -- { puid, hit, coords } while re-dragging a placed part
local prepPlacing = nil  -- { id?, ents, dual, item, source, cheese, half, hit, coords } while placing a new part

-- ─── world food props (synced for everyone) ──────────────────────────────────

-- Food props are local, non-mission objects (CreateProp -> CreateObject(...,
-- false, false, false)). DeleteEntity silently no-ops on those unless we first
-- take ownership by flagging them as a mission entity, otherwise removed/
-- collected food lingers in the world.
local function SafeDeleteEntity(ent)
    if not ent or not DoesEntityExist(ent) then return end
    SetEntityAsMissionEntity(ent, true, true)
    DeleteEntity(ent)
end

local function SpawnCookObject(uid, model, x, y, z, state)
    if CookObjects[uid] then SafeDeleteEntity(CookObjects[uid]) end
    local ent = CreateProp(model, x, y, z, false, false, false)
    if not ent or not DoesEntityExist(ent) then return end
    -- CreateProp seats the model's bounds at z; the drag preview and live-move
    -- both place the raw origin with SetEntityCoordsNoOffset, so match them here
    -- or the synced prop lands at a slightly different (nearby) spot than dragged.
    SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
    SetEntityCollision(ent, false, false)
    FreezeEntityPosition(ent, true)
    CookObjects[uid] = ent
    CookState[uid]   = state
    CookCoords[uid]  = { x = x, y = y, z = z }
end

-- ─── dual-sided patties ──────────────────────────────────────────────────────

local function modelForSide(input, state)
    local r = RecipesByInput and RecipesByInput[input]
    if not r then return nil end
    if state == "cooked" then return r.cooked_model
    elseif state == "burnt" then return r.burnt_model
    else return r.raw_model end
end

-- Which side is the cooking side (server `down`) — it sits on the grill (bottom,
-- hidden); the OTHER side faces up where you can see it.
local function cookSide(flipped) return flipped and 2 or 1 end

-- The roll a given face sits at: the cooking face is the grill-facing bottom one.
local function dualTargetRoll(rec, side)
    return (side == cookSide(rec.flipped)) and DUAL.bottom_roll or DUAL.top_roll
end

-- The vertical offset a face sits at: the whole patty is raised by base_lift so
-- the bottom (cooking) face clears the grill; within that, the cooking face is on
-- the bottom and the visible face sits face_gap above it.
local function dualTargetZ(rec, side)
    return DUAL.base_lift + ((side == cookSide(rec.flipped)) and 0.0 or DUAL.face_gap)
end

-- Position a pair of face entities at coords: the cooking face on the grill, the
-- visible face stacked on top. Used for both the live placement preview and
-- placed/dragged patties so they look identical throughout.
local function orientPair(ents, x, y, z, flipped)
    local cook = cookSide(flipped)
    for s = 1, 2 do
        local ent = ents[s]
        if ent and DoesEntityExist(ent) then
            local isCook = s == cook
            local roll   = isCook and DUAL.bottom_roll or DUAL.top_roll
            local dz     = DUAL.base_lift + (isCook and 0.0 or DUAL.face_gap)
            SetEntityCoordsNoOffset(ent, x, y, z + dz, false, false, false)
            SetEntityRotation(ent, 0.0, roll, 0.0, 2, true)
        end
    end
end

-- Keep the cheese slice (if any) sitting on the visible (up) face.
local function placeCheese(uid)
    local rec, c = CookDual[uid], CookCoords[uid]
    if not rec or not c then return end
    local ent = rec.cheeseEnt
    if not ent or not DoesEntityExist(ent) then return end
    local dz = DUAL.base_lift + DUAL.face_gap + CHEESE.z
    SetEntityCoordsNoOffset(ent, c.x, c.y, c.z + dz, false, false, false)
    SetEntityRotation(ent, 0.0, DUAL.top_roll + CHEESE.roll, 0.0, 2, true)
end

local function orientDualSnap(uid)
    local rec, c = CookDual[uid], CookCoords[uid]
    if not rec or not c then return end
    orientPair(rec.ent, c.x, c.y, c.z, rec.flipped)
    placeCheese(uid)
end

-- Animate a flip: the patty turns over as one rigid body, so BOTH faces rotate
-- the SAME way (each +180 from its pre-flip roll) rather than toward each other.
-- Their heights cross over at the same time (cooking face <-> visible face).
local function tweenDualFlip(uid)
    local rec = CookDual[uid]; if not rec then return end
    DualTween[uid] = (DualTween[uid] or 0) + 1
    local token = DualTween[uid]
    -- a flip swapped which side is on the grill, so each face starts at the
    -- opposite side's resting roll/height
    local fromRoll, fromZ = {}, {}
    for s = 1, 2 do
        fromRoll[s] = (dualTargetRoll(rec, s) == DUAL.bottom_roll) and DUAL.top_roll or DUAL.bottom_roll
        fromZ[s]    = (dualTargetZ(rec, s) == DUAL.base_lift) and (DUAL.base_lift + DUAL.face_gap) or DUAL.base_lift
    end
    CreateThread(function()
        local started = GetGameTimer()
        while true do
            local r, c = CookDual[uid], CookCoords[uid]
            if not r or not c or DualTween[uid] ~= token then return end
            local t = math.min((GetGameTimer() - started) / DUAL.tween_ms, 1.0)
            for s = 1, 2 do
                local ent = r.ent[s]
                if ent and DoesEntityExist(ent) then
                    local roll = fromRoll[s] + 180.0 * t -- same direction for both faces
                    local dz   = fromZ[s] + (dualTargetZ(r, s) - fromZ[s]) * t
                    SetEntityCoordsNoOffset(ent, c.x, c.y, c.z + dz, false, false, false)
                    SetEntityRotation(ent, 0.0, roll, 0.0, 2, true)
                end
            end
            if t >= 1.0 then
                orientDualSnap(uid) -- normalise to the exact resting rolls/heights
                return
            end
            Wait(0)
        end
    end)
end

-- Spawn or update a dual patty from a server payload: (re)create each face prop
-- whose model changed, keep both at the shared coords, orient (animating on
-- flip), and stash the live cook-progress so the hover panel can count up.
local function RebuildDual(p)
    local uid = p.uid
    local x, y, z = p.x, p.y, p.z
    CookCoords[uid] = { x = x, y = y, z = z }
    local flipped = p.flipped and true or false
    local input = p.input
    local ps = p.sides or {}
    local sides = { (ps[1] and ps[1].state) or "raw", (ps[2] and ps[2].state) or "raw" }
    local rec = CookDual[uid]
    if not rec then
        rec = { ent = {}, modelName = {}, sides = sides, flipped = flipped, input = input }
        CookDual[uid] = rec
    end

    for s = 1, 2 do
        local model = modelForSide(input, sides[s])
        local ent = rec.ent[s]
        if (not ent) or (not DoesEntityExist(ent)) or rec.modelName[s] ~= model then
            if ent then CookEntityUid[ent] = nil; SafeDeleteEntity(ent) end
            ent = model and CreateProp(model, x, y, z, false, false, false) or nil
            if ent and DoesEntityExist(ent) then
                SetEntityCollision(ent, false, false)
                FreezeEntityPosition(ent, true)
                rec.ent[s] = ent
                rec.modelName[s] = model
                CookEntityUid[ent] = uid
            else
                rec.ent[s] = nil
            end
        end
    end

    -- melted/applied cheese on the visible face (spawn/swap/remove as needed)
    local cheese = p.cheese or "none"
    if cheese ~= "none" then
        local model = (cheese == "melted") and CHEESE.model_melted or CHEESE.model_applied
        if (not rec.cheeseEnt) or (not DoesEntityExist(rec.cheeseEnt)) or rec.cheeseModel ~= model then
            if rec.cheeseEnt then SafeDeleteEntity(rec.cheeseEnt) end
            rec.cheeseEnt = CreateProp(model, x, y, z, false, false, false)
            if rec.cheeseEnt and DoesEntityExist(rec.cheeseEnt) then
                SetEntityCollision(rec.cheeseEnt, false, false)
                FreezeEntityPosition(rec.cheeseEnt, true)
                rec.cheeseModel = model
            else
                rec.cheeseEnt = nil
            end
        end
    elseif rec.cheeseEnt then
        SafeDeleteEntity(rec.cheeseEnt); rec.cheeseEnt, rec.cheeseModel = nil, nil
    end

    local flipChanged = rec.flipped ~= flipped
    rec.sides, rec.input, rec.flipped, rec.cheese = sides, input, flipped, cheese
    -- live cook progress per face, timestamped against our own clock so the grill
    -- side's % counts up smoothly between server messages (the other is frozen).
    rec.prog = {
        cooking = p.cooking or 1, start = GetGameTimer(),
        sides = { ps[1] or {}, ps[2] or {} }, cheese = cheese,
        give = p.give, giveLabel = p.giveLabel, giveImage = p.giveImage,
    }
    -- chips project from the visible top face (the side NOT on the grill)
    local visible = (cookSide(flipped) == 1) and 2 or 1
    CookObjects[uid] = rec.ent[visible] or rec.ent[1] or rec.ent[2]
    CookState[uid]   = sides[1]

    if flipChanged then tweenDualFlip(uid) else orientDualSnap(uid) end
end

local function RemoveDual(uid)
    local rec = CookDual[uid]; if not rec then return false end
    for s = 1, 2 do
        local ent = rec.ent[s]
        if ent then CookEntityUid[ent] = nil; SafeDeleteEntity(ent) end
    end
    if rec.cheeseEnt then SafeDeleteEntity(rec.cheeseEnt) end
    CookDual[uid], DualTween[uid] = nil, nil
    return true
end

-- Move all entities for a uid (single prop or both dual faces) and remember the
-- new coords so a state/flip re-spawn lands in the right place.
local function MoveCookObjectLocal(uid, x, y, z)
    CookCoords[uid] = { x = x, y = y, z = z }
    local rec = CookDual[uid]
    if rec then
        for s = 1, 2 do
            local ent = rec.ent[s]
            if ent and DoesEntityExist(ent) then
                SetEntityCoordsNoOffset(ent, x, y, z + dualTargetZ(rec, s), false, false, false)
                SetEntityRotation(ent, 0.0, dualTargetRoll(rec, s), 0.0, 2, true)
            end
        end
        placeCheese(uid)
    else
        local ent = CookObjects[uid]
        if ent and DoesEntityExist(ent) then
            SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
        end
    end
end

-- ─── live drag-to-place ──────────────────────────────────────────────────────

-- The world model to preview for a dragged bar item (raw food / drink / recipe).
local function previewModel(kind, item)
    if kind == "cook" then
        local r = RecipesByInput and RecipesByInput[item]
        return r and r.raw_model
    elseif kind == "drink" then
        for _, dd in ipairs(Drinks or {}) do if dd.input == item then return dd.model end end
    elseif kind == "assembly" then
        for _, a in ipairs(Assembly or {}) do if a.output == item then return a.model end end
    end
    return nil
end

-- Delete a placement preview's entity/entities (dual previews carry two).
local function deletePreview(p)
    if not p then return end
    if p.dual then
        for _, e in ipairs(p.ent) do SafeDeleteEntity(e) end
    else
        SafeDeleteEntity(p.entity)
    end
    if p.cheeseEnt then SafeDeleteEntity(p.cheeseEnt) end
end

local function cancelPlace()
    local p = placing; placing = nil
    deletePreview(p)
end

local function cancelMove()
    moving = nil
end

RegisterNetEvent("pickle_restaurants:cooking:spawn", function(uid, model, x, y, z, state)
    SpawnCookObject(uid, model, x, y, z, state)
end)

RegisterNetEvent("pickle_restaurants:cooking:update", function(uid, model, state)
    local c = CookCoords[uid]; if not c then return end
    SpawnCookObject(uid, model, c.x, c.y, c.z, state)
end)

-- spawn or update a dual-sided patty (both faces + live status in one payload)
RegisterNetEvent("pickle_restaurants:cooking:dual", function(p)
    if p then RebuildDual(p) end
end)

RegisterNetEvent("pickle_restaurants:cooking:move", function(uid, x, y, z)
    MoveCookObjectLocal(uid, x, y, z)
end)

RegisterNetEvent("pickle_restaurants:cooking:remove", function(uid)
    if not RemoveDual(uid) then
        SafeDeleteEntity(CookObjects[uid])
    end
    CookObjects[uid], CookState[uid], CookCoords[uid] = nil, nil, nil
end)

RegisterNetEvent("pickle_restaurants:cooking:bulk", function(list)
    for _, it in ipairs(list or {}) do
        if it.dual then
            RebuildDual(it)
        else
            SpawnCookObject(it.uid, it.model, it.x, it.y, it.z, it.state)
        end
    end
end)

-- ─── click-to-flip hover ─────────────────────────────────────────────────────

local hoveredPatty = nil

local function setPattyOutline(uid, on)
    local rec = CookDual[uid]; if not rec then return end
    for s = 1, 2 do
        local ent = rec.ent[s]
        if ent and DoesEntityExist(ent) then
            SetEntityDrawOutline(ent, on)
            if on then SetEntityDrawOutlineColor(255, 180, 40, 255) end
        end
    end
end

local function HoverPatty(uid)
    if hoveredPatty == uid then return end
    if hoveredPatty then setPattyOutline(hoveredPatty, false) end
    hoveredPatty = uid
    if uid then setPattyOutline(uid, true) end
end

-- ─── open / close ────────────────────────────────────────────────────────────

local function RefreshBar()
    if not cookingOpen or not currentCookProp then return end
    local ing = lib.callback.await("pickle_restaurants:cooking:getIngredients", false, { prop_id = currentCookProp.id })
    SendNUIMessage({ action = "cookingIngredients", ingredients = ing })
end

local function RefreshTray()
    if not cookingOpen or not currentCookProp then return end
    local tray = lib.callback.await("pickle_restaurants:cooking:getTray", false, { prop_id = currentCookProp.id })
    SendNUIMessage({ action = "cookingTray", tray = tray })
end

-- ─── interactive prep build (free-form stacking) ─────────────────────────────

-- Vertical extent of a part (so the next one rests right on top of it) and a
-- footprint radius (so dropping within it counts as stacking onto it).
local function partMetrics(ent)
    if not ent or not DoesEntityExist(ent) then return PREP.step, 0.1 end
    local mn, mx = GetModelDimensions(GetEntityModel(ent))
    local h = (mn and mx) and (mx.z - mn.z) or 0.0
    if h < PREP.step then h = PREP.step end
    local rx = (mn and mx) and math.abs(mx.x - mn.x) * 0.5 or 0.1
    local ry = (mn and mx) and math.abs(mx.y - mn.y) * 0.5 or 0.1
    return h, math.max(rx, ry, 0.05)
end

-- Spawn the prop(s) for a part. dual = two stacked faces (+ optional cheese on
-- the visible one); otherwise a single prop. Returns the ents array (or nil).
local function spawnPartEntities(model, dual, cheeseModel, x, y, z)
    local ents = {}
    if dual then
        local e1 = CreateProp(model, x, y, z, false, false, false)
        local e2 = CreateProp(model, x, y, z, false, false, false)
        if not e1 or not e2 or not DoesEntityExist(e1) or not DoesEntityExist(e2) then
            SafeDeleteEntity(e1); SafeDeleteEntity(e2); return nil
        end
        SetEntityCollision(e1, false, false); FreezeEntityPosition(e1, true)
        SetEntityCollision(e2, false, false); FreezeEntityPosition(e2, true)
        ents[1], ents[2] = e1, e2
        if cheeseModel then
            local ce = CreateProp(cheeseModel, x, y, z, false, false, false)
            if ce and DoesEntityExist(ce) then
                SetEntityCollision(ce, false, false); FreezeEntityPosition(ce, true); ents[3] = ce
            end
        end
    else
        local e = CreateProp(model, x, y, z, false, false, false)
        if not e or not DoesEntityExist(e) then return nil end
        SetEntityCollision(e, false, false); FreezeEntityPosition(e, true)
        ents[1] = e
    end
    return ents
end

local function deletePartEntities(ents)
    for _, e in ipairs(ents or {}) do SafeDeleteEntity(e) end
end

-- Place a part's prop(s) at a base point (dual faces lie flat with cheese on top).
local function positionPart(part, x, y, z)
    part.base = { x = x, y = y, z = z }
    if part.dual then
        orientPair(part.ents, x, y, z, false)
        local ce = part.ents[3]
        if ce and DoesEntityExist(ce) then
            local dz = DUAL.base_lift + DUAL.face_gap + CHEESE.z
            SetEntityCoordsNoOffset(ce, x, y, z + dz, false, false, false)
            SetEntityRotation(ce, 0.0, DUAL.top_roll + CHEESE.roll, 0.0, 2, true)
        end
    else
        local e = part.ents[1]
        if e and DoesEntityExist(e) then SetEntityCoordsNoOffset(e, x, y, z, false, false, false) end
    end
end

-- Resolve where a dragged part should rest: if the cursor point falls within
-- another part's footprint, snap onto the top of that (highest) part's column;
-- otherwise sit on the surface point under the cursor.
local function resolvePrepDrop(coords, excludePuid)
    local topPart, topZ
    for puid, part in pairs(PrepParts) do
        if puid ~= excludePuid and part.base then
            local dx, dy = coords.x - part.base.x, coords.y - part.base.y
            local r = part.foot or 0.1
            if (dx * dx + dy * dy) <= (r * r) then
                local z = part.base.z + (part.height or PREP.step)
                if not topZ or z > topZ then topZ, topPart = z, part end
            end
        end
    end
    if topPart then return topPart.base.x, topPart.base.y, topZ end
    return coords.x, coords.y, coords.z
end

local function removePrepPart(puid)
    local part = PrepParts[puid]; if not part then return end
    deletePartEntities(part.ents)
    PrepParts[puid] = nil
end

local function clearPrepParts()
    for puid in pairs(PrepParts) do removePrepPart(puid) end
    PrepParts = {}
    prepHovered, prepMoving = nil, nil
    if prepPlacing then deletePartEntities(prepPlacing.ents); prepPlacing = nil end
end

local function StopCooking()
    local wasPrep = currentCookProp and currentCookProp.prop_type == "kitchen_prep"
    cookingOpen = false
    currentCookProp = nil
    cancelPlace() -- drop any in-progress placement preview
    cancelMove()  -- drop any in-progress drag of a placed prop
    HoverPatty(nil)
    if HoverOvenDoor then HoverOvenDoor(nil, nil) end -- clear any door outline
    clearPrepParts()
    if wasPrep then TriggerServerEvent("pickle_restaurants:cooking:prepClose") end -- drop unfinished build
    StopStationCamera()
    CloseNUI()
    SendNUIMessage({ action = "cookingItems", items = {} })
end

function OpenCookingStation(prop)
    if cookingOpen then return end
    currentCookProp = prop
    cookingOpen = true
    StartStationCamera(prop)
    local ing = lib.callback.await("pickle_restaurants:cooking:getIngredients", false, { prop_id = prop.id })
    OpenNUI("cooking", { station = prop.prop_type, ingredients = ing })
    RefreshTray()

    -- per-frame projection of every world food prop -> NUI chip positions, the
    -- live cook-status for each, and which one the cursor is hovering (so the NUI
    -- can show its status panel and start a drag on it).
    CreateThread(function()
        local HOVER_R = 0.06 -- normalized-screen radius that counts as hovering an item
        while cookingOpen do
            local items = {}
            local now = GetGameTimer()
            -- cursor in normalized (0-1) screen space, for proximity hit-testing
            local cx, cy = GetNuiCursorPosition()
            local sw, sh = GetActiveScreenResolution()
            local cnx = (sw > 0) and (cx / sw) or 0.0
            local cny = (sh > 0) and (cy / sh) or 0.0
            local nearUid, nearDist = nil, nil
            for uid, ent in pairs(CookObjects) do
                if DoesEntityExist(ent) then
                    local coords = GetEntityCoords(ent)
                    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(coords.x, coords.y, coords.z)
                    local rec = CookDual[uid]
                    if rec then
                        local prog  = rec.prog or {}
                        local cookS = prog.cooking or 1
                        local psides = prog.sides or {}
                        local function sideOut(s)
                            local sd = psides[s] or {}
                            local state = sd.state or rec.sides[s] or "raw"
                            local total = sd.total or 0
                            -- only the grill side keeps counting up; the other is frozen
                            local elapsed = (sd.elapsed or 0) + ((s == cookS) and (now - (prog.start or now)) or 0)
                            local percent = 0.0
                            if state == "burnt" then percent = 1.0
                            elseif total > 0 then percent = math.min(1.0, elapsed / total) end
                            return { state = state, percent = percent, cooking = (s == cookS) }
                        end
                        items[#items + 1] = {
                            uid = uid, dual = true, onScreen = onScreen, x = sx, y = sy,
                            sides = { sideOut(1), sideOut(2) }, cooking = cookS,
                            cheese = prog.cheese,
                            give = prog.give, giveLabel = prog.giveLabel, giveImage = prog.giveImage,
                        }
                    else
                        items[#items + 1] = { uid = uid, onScreen = onScreen, x = sx, y = sy,
                                              state = CookState[uid] or "raw" }
                    end
                    -- props have collision off, so a shape-test ray can't hit them;
                    -- pick the item nearest the cursor on screen.
                    if onScreen then
                        local dx, dy = sx - cnx, sy - cny
                        local d2 = dx * dx + dy * dy
                        if not nearDist or d2 < nearDist then nearDist, nearUid = d2, uid end
                    end
                end
            end
            local hoveredUid = (nearDist and nearDist <= HOVER_R * HOVER_R) and nearUid or nil

            -- Kitchen prep: find the placed part under the cursor (to grab + restack)
            -- and outline it. Suppressed while already placing/moving a part.
            local prepHoverUid = nil
            if currentCookProp and currentCookProp.prop_type == "kitchen_prep"
                and not prepMoving and not prepPlacing then
                local near, nd
                for puid, part in pairs(PrepParts) do
                    local e = part.ents and part.ents[1]
                    if e and DoesEntityExist(e) then
                        local c = GetEntityCoords(e)
                        local on, sx, sy = GetScreenCoordFromWorldCoord(c.x, c.y, c.z)
                        if on then
                            local dx, dy = sx - cnx, sy - cny
                            local d2 = dx * dx + dy * dy
                            if not nd or d2 < nd then nd, near = d2, puid end
                        end
                    end
                end
                prepHoverUid = (nd and nd <= HOVER_R * HOVER_R) and near or nil
            end
            if prepHovered ~= prepHoverUid then
                local old = PrepParts[prepHovered]
                if old then for _, e in ipairs(old.ents) do
                    if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end end
                local new = PrepParts[prepHoverUid]
                if new then for _, e in ipairs(new.ents) do
                    if DoesEntityExist(e) then SetEntityDrawOutline(e, true); SetEntityDrawOutlineColor(255, 180, 40, 255) end end end
                prepHovered = prepHoverUid
            end

            SendNUIMessage({ action = "cookingItems", items = items, hovered = hoveredUid, prepHovered = prepHoverUid })

            -- Stovetop: outline the hovered patty (click flips it); otherwise
            -- highlight the oven door under the cursor (click toggles it).
            if not placing and not moving and currentCookProp and currentCookProp.prop_type == "stovetop" then
                if hoveredUid and CookDual[hoveredUid] then
                    HoverPatty(hoveredUid)
                    if HoverOvenDoor then HoverOvenDoor(currentCookProp.id, nil) end
                else
                    HoverPatty(nil)
                    local hit, _, entity = CursorToWorld()
                    local door
                    if hit and entity and entity ~= 0 and GetOvenDoorIndexByEntity then
                        door = GetOvenDoorIndexByEntity(currentCookProp.id, entity)
                    end
                    if HoverOvenDoor then HoverOvenDoor(currentCookProp.id, door) end
                end
            end

            if IsControlJustReleased(0, 322) then StopCooking() end -- ESC fallback
            Wait(50)
        end
    end)
end

-- ─── NUI callbacks ───────────────────────────────────────────────────────────

-- drag a bar item out: spawn the real prop right away and have it follow the
-- cursor in the world. Collision is off so the cursor ray passes through it
-- (otherwise it would track its own surface).
RegisterNUICallback("cooking:beginPlace", function(d, cb)
    if not currentCookProp then return cb({ ok = false }) end
    cancelPlace()
    local base = currentCookProp

    -- Dual-sided recipe -> preview BOTH faces so it reads as one two-sided patty
    -- for the entire drag, identical to what spawns on release.
    local recipe = (d.kind == "cook") and RecipesByInput and RecipesByInput[d.item] or nil
    if recipe and (recipe.dual_sided == true or tonumber(recipe.dual_sided) == 1) then
        local model = recipe.raw_model
        local e1 = model and CreateProp(model, base.x, base.y, base.z, false, false, false) or nil
        local e2 = model and CreateProp(model, base.x, base.y, base.z, false, false, false) or nil
        if not e1 or not e2 or not DoesEntityExist(e1) or not DoesEntityExist(e2) then
            SafeDeleteEntity(e1); SafeDeleteEntity(e2)
            return cb({ ok = false })
        end
        SetEntityCollision(e1, false, false); FreezeEntityPosition(e1, true)
        SetEntityCollision(e2, false, false); FreezeEntityPosition(e2, true)
        local p = { dual = true, ent = { e1, e2 }, kind = d.kind, item = d.item, hit = false }
        placing = p
        CreateThread(function()
            while placing == p do
                local hit, coords = CursorToWorld()
                if hit and coords then
                    p.hit, p.coords = true, coords
                    orientPair(p.ent, coords.x, coords.y, coords.z, false)
                else
                    p.hit = false
                end
                Wait(0)
            end
        end)
        return cb({ ok = true })
    end

    local model = previewModel(d.kind, d.item)
    if not model then return cb({ ok = false, error = "Nothing to place." }) end
    local ent = CreateProp(model, base.x, base.y, base.z, false, false, false)
    if not ent or not DoesEntityExist(ent) then return cb({ ok = false }) end
    SetEntityCollision(ent, false, false)
    FreezeEntityPosition(ent, true)
    local p = { entity = ent, kind = d.kind, item = d.item, hit = false }
    placing = p
    CreateThread(function()
        while placing == p do
            local hit, coords = CursorToWorld()
            if hit and coords then
                p.hit, p.coords = true, coords
                SetEntityCoordsNoOffset(ent, coords.x, coords.y, coords.z, false, false, false)
            else
                p.hit = false
            end
            Wait(0)
        end
    end)
    cb({ ok = true })
end)

-- release: drop the local preview and ask the server to spawn the real, synced
-- (cooking) prop at the final spot — unless cancelled (released over the bar) or
-- never over a valid surface.
RegisterNUICallback("cooking:endPlace", function(d, cb)
    local p = placing; placing = nil
    if not p then return cb({ ok = false }) end
    if (d and d.cancel) or not p.hit or not p.coords then
        deletePreview(p)
        return cb({ ok = false })
    end
    local res = lib.callback.await("pickle_restaurants:cooking:place", false, {
        prop_id = currentCookProp and currentCookProp.id, kind = p.kind, item = p.item,
        x = p.coords.x, y = p.coords.y, z = p.coords.z,
    })
    -- Delete the preview only after the server's synced prop has spawned (same
    -- model + coords), so they overlap and there's no visible gap.
    deletePreview(p)
    if res and res.ok then RefreshBar() elseif res and res.error then ShowNotification(res.error) end
    cb(res or { ok = false })
end)

-- chip grabbed: drag the *real* placed prop live under the cursor, the same way
-- a fresh ingredient places. Collision is off so the ray passes through it.
RegisterNUICallback("cooking:beginMove", function(d, cb)
    local uid = d and d.uid
    if not uid or not CookObjects[uid] then return cb({ ok = false }) end
    cancelPlace()
    cancelMove()
    local m = { uid = uid, hit = false, origin = CookCoords[uid] }
    moving = m
    CreateThread(function()
        while moving == m do
            if not CookObjects[uid] then break end -- collected / removed mid-drag
            local hit, coords = CursorToWorld()
            if hit and coords then
                m.hit, m.coords = true, coords
                MoveCookObjectLocal(uid, coords.x, coords.y, coords.z)
            else
                m.hit = false
            end
            Wait(0)
        end
    end)
    cb({ ok = true })
end)

-- release a dragged prop in the world -> commit the final spot to the server
-- (it validates perms + syncs everyone). With no valid surface, snap it back.
RegisterNUICallback("cooking:endMove", function(d, cb)
    local m = moving; moving = nil
    if not m then return cb({ ok = false }) end
    if (d and d.cancel) or not m.hit or not m.coords then
        if m.origin then MoveCookObjectLocal(m.uid, m.origin.x, m.origin.y, m.origin.z) end
        return cb({ ok = false })
    end
    local res = lib.callback.await("pickle_restaurants:cooking:move", false, {
        uid = m.uid, x = m.coords.x, y = m.coords.y, z = m.coords.z,
    })
    cb(res or { ok = false })
end)

-- chip dragged back onto the bar -> collect into the Cooked Items tray
RegisterNUICallback("cooking:collect", function(d, cb)
    cancelMove() -- stop the live drag; the server will remove the prop
    local res = lib.callback.await("pickle_restaurants:cooking:collect", false, { uid = d.uid })
    if res and res.ok then
        if res.label then ShowNotification("Collected " .. res.label) end
        RefreshBar()
        RefreshTray()
    end
    cb(res or { ok = false })
end)

-- take a Cooked Items tray entry out into the real inventory
RegisterNUICallback("cooking:trayToInventory", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:cooking:trayToInventory", false, {
        prop_id = currentCookProp and currentCookProp.id, item = d.item, cheese = d.cheese, count = d.count,
    })
    if res and res.ok then
        if res.label then ShowNotification(("Took %s"):format(res.label)) end
        RefreshTray(); RefreshBar()
    elseif res and res.error then
        ShowNotification(res.error)
    end
    cb(res or { ok = false })
end)

-- ─── interactive prep build (free-form stacking) ─────────────────────────────

-- Begin placing a NEW part from the bar: spawn its prop(s) and follow the cursor,
-- resting on the surface or stacking onto whatever part is under the cursor.
RegisterNUICallback("cooking:beginPrepPlace", function(d, cb)
    cancelPlace(); cancelMove()
    if prepPlacing then deletePartEntities(prepPlacing.ents); prepPlacing = nil end
    local base = currentCookProp
    if not base then return cb({ ok = false }) end

    -- a bun is one item rendered as two halves; pick the model for this half
    local model = d.model
    if d.item == "bun" and d.half and BUN[d.half] then model = BUN[d.half] end
    if not model then return cb({ ok = false }) end

    local dual = (d.dual == 1 or d.dual == true)
    local cheeseOn = (d.cheese == 1 or d.cheese == true)
    local cheeseModel = (cheeseOn and dual) and d.cheeseModel or nil
    local ents = spawnPartEntities(model, dual, cheeseModel, base.x, base.y, base.z)
    if not ents then return cb({ ok = false }) end

    local part = { ents = ents, dual = dual, item = d.item, source = d.source,
                   cheese = cheeseOn and 1 or 0, half = d.half, hit = false }
    part.height, part.foot = partMetrics(ents[1])
    prepPlacing = part
    CreateThread(function()
        while prepPlacing == part do
            local hit, coords = CursorToWorld()
            if hit and coords then
                part.hit = true
                local x, y, z = resolvePrepDrop(coords, nil)
                part.coords = { x = x, y = y, z = z }
                positionPart(part, x, y, z)
            else
                part.hit = false
            end
            Wait(0)
        end
    end)
    cb({ ok = true })
end)

-- Release a new part: reserve the layer server-side and keep the prop where it
-- landed (cancel if released over the bar or never over a surface).
RegisterNUICallback("cooking:endPrepPlace", function(d, cb)
    local part = prepPlacing; prepPlacing = nil
    if not part then return cb({ ok = false }) end
    if (d and d.cancel) or not part.hit or not part.coords then
        deletePartEntities(part.ents)
        return cb({ ok = false })
    end
    local res = lib.callback.await("pickle_restaurants:cooking:prepAdd", false, {
        prop_id = currentCookProp and currentCookProp.id, source = part.source,
        item = part.item, cheese = part.cheese, half = part.half,
    })
    if res and res.ok then
        part.id = res.id
        prepUid = prepUid + 1
        PrepParts[prepUid] = part
        SendNUIMessage({ action = "cookingBuild", build = res.build })
        RefreshTray(); RefreshBar()
    else
        deletePartEntities(part.ents)
        if res and res.error then ShowNotification(res.error) end
    end
    cb(res or { ok = false })
end)

-- Grab an already-placed part to restack it freely (follows the cursor, snapping
-- onto whatever part is under it).
RegisterNUICallback("cooking:prepGrab", function(d, cb)
    cancelPlace(); cancelMove()
    local puid = d and d.puid
    local part = puid and PrepParts[puid]
    if not part then return cb({ ok = false }) end
    for _, e in ipairs(part.ents) do if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end
    prepHovered = nil
    local m = { puid = puid, hit = false, origin = part.base }
    prepMoving = m
    CreateThread(function()
        while prepMoving == m do
            if not PrepParts[puid] then break end
            local hit, coords = CursorToWorld()
            if hit and coords then
                m.hit = true
                local x, y, z = resolvePrepDrop(coords, puid)
                m.coords = { x = x, y = y, z = z }
                positionPart(PrepParts[puid], x, y, z)
            else
                m.hit = false
            end
            Wait(0)
        end
    end)
    cb({ ok = true })
end)

-- Release a re-dragged part: dropping on the bar removes it (un-reserves);
-- otherwise it stays where it landed. No valid surface -> snap back to origin.
RegisterNUICallback("cooking:prepDrop", function(d, cb)
    local m = prepMoving; prepMoving = nil
    if not m then return cb({ ok = false }) end
    local part = PrepParts[m.puid]
    if not part then return cb({ ok = false }) end
    if d and d.cancel then
        local res = lib.callback.await("pickle_restaurants:cooking:prepRemove", false, { id = part.id })
        removePrepPart(m.puid)
        SendNUIMessage({ action = "cookingBuild", build = (res and res.build) or { layers = {} } })
        RefreshTray(); RefreshBar()
        return cb(res or { ok = true })
    end
    if (not m.hit or not m.coords) and m.origin then
        positionPart(part, m.origin.x, m.origin.y, m.origin.z) -- snap back
    end
    cb({ ok = true })
end)

-- No-model fallback: a component without a world model (e.g. lettuce) can't be
-- rendered or restacked, so it's just reserved and shown in the build panel.
RegisterNUICallback("cooking:prepAdd", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:cooking:prepAdd", false, {
        prop_id = currentCookProp and currentCookProp.id, source = d.source, item = d.item, cheese = d.cheese,
    })
    if res and res.ok then
        SendNUIMessage({ action = "cookingBuild", build = res.build })
        RefreshTray(); RefreshBar()
    elseif res and res.error then
        ShowNotification(res.error)
    end
    cb(res or { ok = false })
end)

RegisterNUICallback("cooking:prepClear", function(_, cb)
    local res = lib.callback.await("pickle_restaurants:cooking:prepClear", false, {})
    clearPrepParts()
    SendNUIMessage({ action = "cookingBuild", build = (res and res.build) or { layers = {} } })
    RefreshTray(); RefreshBar()
    cb(res or { ok = true })
end)

RegisterNUICallback("cooking:prepFinish", function(_, cb)
    local res = lib.callback.await("pickle_restaurants:cooking:prepFinish", false, {})
    if res and res.ok then
        clearPrepParts()
        if res.label then ShowNotification("Made " .. res.label) end
        SendNUIMessage({ action = "cookingBuild", build = { layers = {} } })
        RefreshTray()
    elseif res and res.error then
        ShowNotification(res.error)
    end
    cb(res or { ok = false })
end)

-- switch the scripted camera between the cooktop and either oven door
RegisterNUICallback("cooking:setView", function(d, cb)
    if currentCookProp and SetStationView then SetStationView(currentCookProp, d.view) end
    cb({ ok = true })
end)

-- click a dual patty -> flip it to cook the other side (server validates + syncs)
RegisterNUICallback("cooking:flip", function(d, cb)
    local uid = d and d.uid
    if uid and CookDual[uid] then
        lib.callback.await("pickle_restaurants:cooking:flip", false, { uid = uid })
    end
    cb({ ok = true })
end)

-- begin dragging a cheese slice: spawn the real slice prop and follow the cursor
-- in 3D (no 2D pill), exactly like placing a patty. Release over a patty applies.
RegisterNUICallback("cooking:beginTopping", function(d, cb)
    cancelPlace()
    cancelMove()
    local model, base = d.model, currentCookProp
    if not model or not base then return cb({ ok = false }) end
    local ent = CreateProp(model, base.x, base.y, base.z, false, false, false)
    if not ent or not DoesEntityExist(ent) then return cb({ ok = false }) end
    SetEntityCollision(ent, false, false)
    FreezeEntityPosition(ent, true)
    local p = { entity = ent, topping = true, item = d.item, hit = false }
    placing = p
    CreateThread(function()
        while placing == p do
            local hit, coords = CursorToWorld()
            if hit and coords then
                p.hit, p.coords = true, coords
                SetEntityCoordsNoOffset(ent, coords.x, coords.y, coords.z, false, false, false)
            else
                p.hit = false
            end
            Wait(0)
        end
    end)
    cb({ ok = true })
end)

-- release a cheese drag: drop the preview slice and, if over a patty, apply it
-- (the server spawns the stuck-on slice). Otherwise just cancel.
RegisterNUICallback("cooking:endTopping", function(d, cb)
    local p = placing; placing = nil
    deletePreview(p)
    local uid = d and d.uid
    if not (d and d.cancel) and uid and CookDual[uid] then
        local res = lib.callback.await("pickle_restaurants:cooking:applyCheese", false, { uid = uid })
        if res and res.error then ShowNotification(res.error) end
        if res and res.ok then RefreshBar() end
        return cb(res or { ok = false })
    end
    cb({ ok = false })
end)

-- drop cheese on a dual patty's cooked up-face (server validates + consumes cheese)
RegisterNUICallback("cooking:applyCheese", function(d, cb)
    local uid = d and d.uid
    if uid and CookDual[uid] then
        local res = lib.callback.await("pickle_restaurants:cooking:applyCheese", false, { uid = uid })
        if res and res.error then ShowNotification(res.error) end
        if res and res.ok then RefreshBar() end
    end
    cb({ ok = true })
end)

-- click empty grill -> toggle the oven door under the cursor (tracked per-frame).
RegisterNUICallback("cooking:worldClick", function(_, cb)
    if currentCookProp and currentCookProp.prop_type == "stovetop" and GetHoveredOvenDoor then
        local door = GetHoveredOvenDoor(currentCookProp.id)
        if door then
            local res = lib.callback.await("pickle_restaurants:doors:toggle", false, {
                prop_id = currentCookProp.id, door = door,
            })
            if res and res.error then ShowNotification(res.error) end
        end
    end
    cb({ ok = true })
end)

RegisterNUICallback("cooking:close", function(_, cb)
    StopCooking()
    cb({})
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for uid in pairs(CookDual) do RemoveDual(uid) end
    for _, ent in pairs(CookObjects) do
        SafeDeleteEntity(ent)
    end
    -- prep build parts + any in-flight placement/topping previews
    clearPrepParts()
    deletePreview(placing); placing = nil
end)
