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

-- Interactive prep build. The STACK is the first-class object: an ordered array
-- of parts sharing one (x,y) anchor and a table-surface z0. A part's z is never
-- stored — it's always z0 + the sum of the heights below it. modelHeight() gives
-- each part's flush height, so relayout() assigns every z and stacks are flush by
-- construction.
--   PrepStacks[sid] = { x, y, z0, parts = { part, part, ... } }  -- parts[1] on table
--   part = { pid, ents = {…}, height, item, half, source, cheese, id,
--            patty?, faces = {e1,e2}, cheeseEnt? }
-- Most parts are one prop on their centre-bottom origin. A beef patty is a `patty`
-- part: the same two-faced patty (+ cheese) the stovetop renders, so it looks
-- identical in a burger. A bun is dragged as a bottom+top PAIR; a lone top bun sits
-- flipped.
local BUN = { bottom = "pickle_bread_bun_02", top = "pickle_bread_bun_01" }
local PrepStacks = {}
local prepSid = 0        -- monotonic stack id
local prepPid = 0        -- monotonic part id (stable handle for NUI hover/grab)
local prepHovered = nil  -- pid under the cursor (for grabbing)
local prepDrag = nil     -- { parts = {…}, fromSid?, hit, coords, targetSid } while placing/moving

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

-- ─── shared prop primitives (every station + the prep table go through these) ──

-- Stream a model in (bounded wait) and return its hash. CreateProp and
-- GetModelDimensions both silently fall back to the error prop on an un-loaded
-- model, so everything that spawns or measures a model goes through here first.
local function EnsureModel(model)
    local hash = (type(model) == "string") and GetHashKey(model) or model
    if not HasModelLoaded(hash) then
        RequestModel(hash)
        local started = GetGameTimer()
        while not HasModelLoaded(hash) and GetGameTimer() - started < 1000 do Wait(0) end
    end
    return hash
end

-- Flush stacking height = how far a model's visible TOP sits above its centre-bottom
-- origin. GetModelDimensions returns the PHYSICS box, which carries the engine's
-- uniform ~0.04 collision margin on every side: it dips `margin` below the origin
-- (mn.z ≈ -margin) and overshoots the mesh top by the same margin, so the true top
-- is mx.z + mn.z — the margin cancels. (mx.z alone left a one-margin gap; mx.z - mn.z
-- double-counted it.)
local function modelHeight(model)
    local mn, mx = GetModelDimensions(EnsureModel(model))
    if mn and mx then return math.max(mx.z + mn.z, 0.0) end
    return 0.0
end

-- Spawn one frozen, collision-off local prop — the shape every food / topping /
-- stack prop needs. Collision off so the cursor ray passes through it. Returns the
-- entity or nil.
local function SpawnProp(model, x, y, z)
    EnsureModel(model)
    local ent = CreateProp(model, x or 0.0, y or 0.0, z or 0.0, false, false, false)
    if not ent or not DoesEntityExist(ent) then return nil end
    SetEntityCollision(ent, false, false)
    FreezeEntityPosition(ent, true)
    return ent
end

local function SpawnCookObject(uid, model, x, y, z, state)
    if CookObjects[uid] then SafeDeleteEntity(CookObjects[uid]) end
    local ent = SpawnProp(model, x, y, z)
    if not ent then return end
    -- CreateProp seats the model's bounds at z; the drag preview and live-move
    -- both place the raw origin with SetEntityCoordsNoOffset, so match them here
    -- or the synced prop lands at a slightly different (nearby) spot than dragged.
    SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
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

-- Seat a cheese slice on a patty's visible (up) face, given the patty's base
-- (x,y,z). Pure + shared by the stovetop and the prep table; no-op without a slice.
local function placeCheeseAt(ent, x, y, z)
    if not ent or not DoesEntityExist(ent) then return end
    SetEntityCoordsNoOffset(ent, x, y, z + DUAL.base_lift + DUAL.face_gap + CHEESE.z, false, false, false)
    SetEntityRotation(ent, 0.0, DUAL.top_roll + CHEESE.roll, 0.0, 2, true)
end

-- Keep the stovetop patty's cheese slice (if any) sitting on its visible face.
local function placeCheese(uid)
    local rec, c = CookDual[uid], CookCoords[uid]
    if not rec or not c then return end
    placeCheeseAt(rec.cheeseEnt, c.x, c.y, c.z)
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
            ent = model and SpawnProp(model, x, y, z) or nil
            if ent then
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
            rec.cheeseEnt = SpawnProp(model, x, y, z)
            if rec.cheeseEnt then
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

-- Spawn one part and cache its stacking height. Most parts are a SINGLE prop on
-- their centre-bottom origin. A beef patty is a `dual` part: two face props (the
-- same two-faced patty the stovetop renders, via orientPair) plus, if cheesed, a
-- slice seated on the visible face by placeCheeseAt — one code path, so a patty in
-- a burger looks identical to one on the grill. Every prop spawns at the prep prop
-- and is positioned later by layoutParts.
local function makePart(spec)
    local base = currentCookProp; if not base then return nil end
    prepPid = prepPid + 1
    local part = { pid = prepPid, item = spec.item, half = spec.half,
                   source = spec.source, cheese = spec.cheese or 0, ents = {} }

    if spec.dual then
        local e1 = SpawnProp(spec.model, base.x, base.y, base.z)
        local e2 = SpawnProp(spec.model, base.x, base.y, base.z)
        if not e1 or not e2 then SafeDeleteEntity(e1); SafeDeleteEntity(e2); return nil end
        part.patty  = true
        part.faces  = { e1, e2 }
        part.ents   = { e1, e2 }
        -- The next part rests where a topping sits on the visible face — the EXACT
        -- spot placeCheeseAt seats cheese (base_lift + face_gap above the base, plus
        -- the topping float) — so a topping stacked on the patty matches a patty-borne
        -- one. We do NOT use modelHeight(patty model): the two-faced patty is a stovetop
        -- cook prop, not a centre-bottom stack prop, so its measured height is bogus.
        part.height = DUAL.base_lift + DUAL.face_gap + CHEESE.z
        if spec.cheeseModel then
            local ce = SpawnProp(spec.cheeseModel, base.x, base.y, base.z)
            if ce then
                part.cheeseEnt = ce
                part.ents[#part.ents + 1] = ce
                part.height = math.max(part.height,
                    DUAL.base_lift + DUAL.face_gap + CHEESE.z + modelHeight(spec.cheeseModel))
            end
        end
    else
        local e = SpawnProp(spec.model, base.x, base.y, base.z)
        if not e then return nil end
        part.ents   = { e }
        part.height = modelHeight(spec.model)
    end
    return part
end

local function deleteParts(parts)
    for _, p in ipairs(parts or {}) do
        for _, e in ipairs(p.ents or {}) do SafeDeleteEntity(e) end
    end
end

-- Place a part so its BASE sits at world (x,y,z). A patty is laid flat (unflipped —
-- fully cooked, both faces shown) via the shared stovetop orientPair, with its
-- cheese seated by placeCheeseAt, so it matches the grill exactly. Other parts are a
-- single prop on their centre-bottom origin (z is the origin directly); `flip`
-- renders a lone top bun upturned — flipping 180° about the bottom origin would sink
-- it, so it's raised by its own height to keep resting on the surface.
local function orientPart(part, x, y, z, flip)
    if part.patty then
        orientPair(part.faces, x, y, z, false)
        placeCheeseAt(part.cheeseEnt, x, y, z)
        return
    end
    local e = part.ents[1]
    if e and DoesEntityExist(e) then
        if flip then
            SetEntityCoordsNoOffset(e, x, y, z + part.height, false, false, false)
            SetEntityRotation(e, 0.0, 180.0, 0.0, 2, true)
        else
            SetEntityCoordsNoOffset(e, x, y, z, false, false, false)
            SetEntityRotation(e, 0.0, 0.0, 0.0, 2, true)
        end
    end
end

-- THE single source of truth for every part's z: walk bottom→top from z0, summing
-- heights so each part sits flush on the one below. `lone` (stack has one part)
-- makes a top bun render flipped.
local function layoutParts(parts, x, y, z0, lone)
    local z = z0
    for _, part in ipairs(parts) do
        local flip = lone and part.item == "bun" and part.half == "top"
        orientPart(part, x, y, z, flip)
        z = z + (part.height or 0.0)
    end
end
local function relayout(stack)
    layoutParts(stack.parts, stack.x, stack.y, stack.z0, #stack.parts == 1)
end

-- World z of the top of a stack (where the next part rests) = base + every height.
local function stackTopZ(stack)
    local z = stack.z0
    for _, p in ipairs(stack.parts) do z = z + (p.height or 0.0) end
    return z
end

-- What a stack provides, as a component multiset (mirrors the server's
-- buildProvides): bun halves count as half a bun (rounded up), and any cheese on a
-- patty counts as one "cheese" component. The NUI ranks recipes against this.
local function stackProvides(stack)
    local units = {}
    for _, p in ipairs(stack.parts) do
        local u = (p.item == "bun" and p.half) and 0.5 or 1.0
        units[p.item] = (units[p.item] or 0) + u
        if (p.cheese or 0) >= 1 then units.cheese = (units.cheese or 0) + 1 end
    end
    local out = {}
    for k, v in pairs(units) do out[k] = math.ceil(v) end
    return out
end

-- The placed part under the cursor, by screen proximity to each part's rendered
-- CENTRE (same projection the stovetop hover uses → lines up with the station
-- cam). Returns sid, index, part. `exceptSid` skips one stack (rarely needed).
local function pickPart(exceptSid)
    local cx, cy = GetNuiCursorPosition()
    local sw, sh = GetActiveScreenResolution()
    local cnx = (sw > 0) and (cx / sw) or 0.0
    local cny = (sh > 0) and (cy / sh) or 0.0
    local R = 0.11 -- screen radius (0-1) that counts as pointing at a stack
    local bsid, bidx, bpart, bd
    for sid, stack in pairs(PrepStacks) do
        if sid ~= exceptSid then
            local z = stack.z0
            for i, part in ipairs(stack.parts) do
                local on, sx, sy = GetScreenCoordFromWorldCoord(stack.x, stack.y, z + (part.height or 0.0) * 0.5)
                if on then
                    local dx, dy = sx - cnx, sy - cny
                    local d2 = dx * dx + dy * dy
                    if d2 <= R * R and (not bd or d2 < bd) then bd, bsid, bidx, bpart = d2, sid, i, part end
                end
                z = z + (part.height or 0.0)
            end
        end
    end
    return bsid, bidx, bpart
end

-- Locate a part by its stable id: returns sid, index, part.
local function findPart(pid)
    for sid, stack in pairs(PrepStacks) do
        for i, part in ipairs(stack.parts) do
            if part.pid == pid then return sid, i, part end
        end
    end
end

-- Outline a whole stack (amber for hover, green for a drop target). nil clears.
local outlinedSid, outlinedRGB = nil, nil
local function setOutline(sid, r, g, b)
    local rgb = sid and ((r or 80) .. "," .. (g or 200) .. "," .. (b or 120)) or nil
    if outlinedSid == sid and outlinedRGB == rgb then return end
    local old = outlinedSid and PrepStacks[outlinedSid]
    if old then for _, p in ipairs(old.parts) do for _, e in ipairs(p.ents) do
        if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end end end
    outlinedSid, outlinedRGB = sid, rgb
    local new = sid and PrepStacks[sid]
    if new then for _, p in ipairs(new.parts) do for _, e in ipairs(p.ents) do
        if DoesEntityExist(e) then SetEntityDrawOutline(e, true); SetEntityDrawOutlineColor(r or 80, g or 200, b or 120, 255) end end end end
end

local function removePrepStack(sid)
    local stack = PrepStacks[sid]; if not stack then return end
    deleteParts(stack.parts)
    PrepStacks[sid] = nil
end

local function clearPrepStacks()
    setOutline(nil)
    if prepDrag then deleteParts(prepDrag.parts); prepDrag = nil end
    for sid in pairs(PrepStacks) do removePrepStack(sid) end
    PrepStacks = {}
    prepHovered = nil
end

-- The drag loop shared by placing (new parts from the bar) and moving (parts
-- lifted off a stack): follow the cursor — snap onto the stack under it, else a
-- new stack at the cursor world point — and lay the carried parts flush on top.
local function runDragThread(drag)
    CreateThread(function()
        while prepDrag == drag do
            local hit, coords = CursorToWorld()
            local sid = pickPart(nil) -- stack under the cursor (append to its top)
            if sid then
                local s = PrepStacks[sid]
                local z0 = stackTopZ(s)
                drag.hit, drag.targetSid, drag.coords = true, sid, { x = s.x, y = s.y, z = z0 }
                setOutline(sid, 80, 200, 120)
                layoutParts(drag.parts, s.x, s.y, z0, false)
            elseif hit and coords then
                drag.hit, drag.targetSid, drag.coords = true, nil, { x = coords.x, y = coords.y, z = coords.z }
                setOutline(nil)
                layoutParts(drag.parts, coords.x, coords.y, coords.z, #drag.parts == 1)
            else
                drag.hit = false
            end
            Wait(0)
        end
        setOutline(nil)
    end)
end

local function StopCooking()
    local wasPrep = currentCookProp and currentCookProp.prop_type == "kitchen_prep"
    cookingOpen = false
    currentCookProp = nil
    cancelPlace() -- drop any in-progress placement preview
    cancelMove()  -- drop any in-progress drag of a placed prop
    HoverPatty(nil)
    if HoverOvenDoor then HoverOvenDoor(nil, nil) end -- clear any door outline
    clearPrepStacks()
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

    -- The prep tooltip ranks the player's stacks against the full recipe
    -- catalogue (output + component labels/images), fetched once on open.
    if prop.prop_type == "kitchen_prep" then
        local recipes = lib.callback.await("pickle_restaurants:cooking:getRecipes", false, { prop_id = prop.id })
        SendNUIMessage({ action = "cookingRecipes", recipes = recipes or {} })
    end

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
            -- and outline its stack (amber). Suppressed while dragging. The hovered
            -- stack also drives the recipe tooltip: its provides multiset + a screen
            -- anchor at the top of the pile.
            local prepHoverPid = nil
            local prepTip = nil
            if currentCookProp and currentCookProp.prop_type == "kitchen_prep" and not prepDrag then
                local sid, _, part = pickPart(nil)
                if part then prepHoverPid = part.pid end
                setOutline(sid, 255, 180, 40)
                local stack = sid and PrepStacks[sid]
                if stack then
                    local on, sx, sy = GetScreenCoordFromWorldCoord(stack.x, stack.y, stackTopZ(stack))
                    prepTip = { sid = sid, onScreen = on, x = sx, y = sy, provides = stackProvides(stack) }
                end
            end
            prepHovered = prepHoverPid

            SendNUIMessage({ action = "cookingItems", items = items, hovered = hoveredUid,
                             prepHovered = prepHoverPid, prepTip = prepTip })

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
        local e1 = model and SpawnProp(model, base.x, base.y, base.z) or nil
        local e2 = model and SpawnProp(model, base.x, base.y, base.z) or nil
        if not e1 or not e2 then
            SafeDeleteEntity(e1); SafeDeleteEntity(e2)
            return cb({ ok = false })
        end
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
    local ent = SpawnProp(model, base.x, base.y, base.z)
    if not ent then return cb({ ok = false }) end
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

-- Drag from the bar. A bun spawns as a bottom+top PAIR; everything else is one
-- part. The carried parts follow the cursor and stack onto the pile under it, or
-- start a new pile on empty table (runDragThread).
RegisterNUICallback("cooking:beginPrepPlace", function(d, cb)
    cancelPlace(); cancelMove()
    if prepDrag then deleteParts(prepDrag.parts); prepDrag = nil end
    if not currentCookProp then return cb({ ok = false }) end

    local dual      = (d.dual == 1 or d.dual == true)
    -- cheese carries its melt state (1 = applied, 2 = melted); keep the exact value so
    -- a tray reservation matches, but any value > 0 means "render a slice".
    local cheeseVal = tonumber(d.cheese) or 0
    local cheeseOn  = cheeseVal > 0

    local specs = {}
    if d.item == "bun" then
        specs[1] = { item = "bun", half = "bottom", model = BUN.bottom, source = d.source }
        specs[2] = { item = "bun", half = "top",    model = BUN.top,    source = d.source }
    else
        if not d.model then return cb({ ok = false }) end
        -- cheese only rides a two-faced patty, matching the stovetop
        specs[1] = { item = d.item, model = d.model, source = d.source, half = d.half,
                     dual = dual, cheese = cheeseVal,
                     cheeseModel = (cheeseOn and dual) and d.cheeseModel or nil }
    end

    local parts = {}
    for i, spec in ipairs(specs) do
        local p = makePart(spec)
        if not p then deleteParts(parts); return cb({ ok = false }) end
        parts[i] = p
    end
    prepDrag = { parts = parts, hit = false }
    runDragThread(prepDrag)
    cb({ ok = true })
end)

-- Release new parts: reserve each server-side, then commit into a stack (append
-- to the targeted pile, or start a new one). Cancel / over-bar discards.
RegisterNUICallback("cooking:endPrepPlace", function(d, cb)
    local drag = prepDrag; prepDrag = nil
    setOutline(nil)
    if not drag then return cb({ ok = false }) end
    if (d and d.cancel) or not drag.hit then
        deleteParts(drag.parts)
        return cb({ ok = false })
    end
    -- The authoritative source ("inv"/"tray") arrives on release, so stamp it onto
    -- each carried part before reserving (a bun's two halves share it).
    local res, failed = nil, nil
    for _, p in ipairs(drag.parts) do
        p.source = d and d.source
        res = lib.callback.await("pickle_restaurants:cooking:prepAdd", false, {
            prop_id = currentCookProp and currentCookProp.id, source = p.source,
            item = p.item, cheese = p.cheese, half = p.half,
        })
        if not (res and res.ok) then failed = res; break end
        p.id = res.id
    end
    if failed then
        for _, p in ipairs(drag.parts) do
            if p.id then lib.callback.await("pickle_restaurants:cooking:prepRemove", false, { id = p.id }) end
        end
        deleteParts(drag.parts)
        if failed.error then ShowNotification(failed.error) end
        return cb(failed or { ok = false })
    end
    local stack = drag.targetSid and PrepStacks[drag.targetSid]
    if stack then
        for _, p in ipairs(drag.parts) do stack.parts[#stack.parts + 1] = p end
    else
        prepSid = prepSid + 1
        stack = { x = drag.coords.x, y = drag.coords.y, z0 = drag.coords.z, parts = drag.parts }
        PrepStacks[prepSid] = stack
    end
    relayout(stack)
    RefreshTray(); RefreshBar()
    cb(res or { ok = false })
end)

-- Grab a placed part: lift it and everything above it off its stack (grab the top
-- → one part; grab a lower member → that part and the rest above it). Reuses the
-- same drag loop as placing.
RegisterNUICallback("cooking:prepGrab", function(d, cb)
    cancelPlace(); cancelMove()
    if prepDrag then return cb({ ok = false }) end
    local sid, idx = findPart(d and d.puid)
    if not sid then return cb({ ok = false }) end
    local stack = PrepStacks[sid]
    local lifted = {}
    for i = idx, #stack.parts do lifted[#lifted + 1] = stack.parts[i] end
    for i = #stack.parts, idx, -1 do table.remove(stack.parts, i) end
    local home = { x = stack.x, y = stack.y, z0 = stack.z0 }
    if #stack.parts == 0 then PrepStacks[sid] = nil else relayout(stack) end
    setOutline(nil); prepHovered = nil
    prepDrag = { parts = lifted, home = home,
                 fromSid = (PrepStacks[sid] and sid) or nil, hit = false }
    runDragThread(prepDrag)
    cb({ ok = true })
end)

-- Release moved parts: over the bar removes them (un-reserves); on a pile/table
-- re-homes them; nowhere valid snaps them back to their source.
RegisterNUICallback("cooking:prepDrop", function(d, cb)
    local drag = prepDrag; prepDrag = nil
    setOutline(nil)
    if not drag then return cb({ ok = false }) end
    if d and d.cancel then
        local res
        for _, p in ipairs(drag.parts) do
            if p.id then res = lib.callback.await("pickle_restaurants:cooking:prepRemove", false, { id = p.id }) end
        end
        deleteParts(drag.parts)
        RefreshTray(); RefreshBar()
        return cb(res or { ok = true })
    end
    local stack
    if drag.hit and drag.targetSid and PrepStacks[drag.targetSid] then
        stack = PrepStacks[drag.targetSid]
        for _, p in ipairs(drag.parts) do stack.parts[#stack.parts + 1] = p end
    elseif drag.hit then
        prepSid = prepSid + 1
        stack = { x = drag.coords.x, y = drag.coords.y, z0 = drag.coords.z, parts = drag.parts }
        PrepStacks[prepSid] = stack
    elseif drag.fromSid and PrepStacks[drag.fromSid] then -- snap back onto the source
        stack = PrepStacks[drag.fromSid]
        for _, p in ipairs(drag.parts) do stack.parts[#stack.parts + 1] = p end
    else -- source is gone: recreate the stack where it came from
        prepSid = prepSid + 1
        stack = { x = drag.home.x, y = drag.home.y, z0 = drag.home.z0, parts = drag.parts }
        PrepStacks[prepSid] = stack
    end
    relayout(stack)
    cb({ ok = true })
end)

-- No-model fallback: a component without a world model can't be rendered or
-- stacked, so it can't take part in the per-stack build — it's only reserved (which
-- still updates the bar counts). Default configs give every component a model.
RegisterNUICallback("cooking:prepAdd", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:cooking:prepAdd", false, {
        prop_id = currentCookProp and currentCookProp.id, source = d.source, item = d.item, cheese = d.cheese,
    })
    if res and res.ok then
        RefreshTray(); RefreshBar()
    elseif res and res.error then
        ShowNotification(res.error)
    end
    cb(res or { ok = false })
end)

RegisterNUICallback("cooking:prepClear", function(_, cb)
    local res = lib.callback.await("pickle_restaurants:cooking:prepClear", false, {})
    clearPrepStacks()
    RefreshTray(); RefreshBar()
    cb(res or { ok = true })
end)

-- Build a single stack into the chosen recipe. The stack's reserved part ids go up
-- with the output; on success the server has consumed them, so we tear that stack
-- down (other stacks stay) and refresh the bar/tray counts.
RegisterNUICallback("cooking:prepMakeStack", function(d, cb)
    local sid = tonumber(d and d.sid)
    local stack = sid and PrepStacks[sid]
    if not stack then return cb({ ok = false }) end
    local ids = {}
    for _, p in ipairs(stack.parts) do if p.id then ids[#ids + 1] = p.id end end
    local res = lib.callback.await("pickle_restaurants:cooking:prepMakeStack", false, { output = d.output, ids = ids })
    if res and res.ok then
        removePrepStack(sid)
        if res.label then ShowNotification("Made " .. res.label) end
        RefreshTray(); RefreshBar()
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
    local ent = SpawnProp(model, base.x, base.y, base.z)
    if not ent then return cb({ ok = false }) end
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
    clearPrepStacks()
    deletePreview(placing); placing = nil
end)
