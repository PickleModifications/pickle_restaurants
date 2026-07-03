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
local CookYaw     = {} -- [uid] = heading of the station the item sits on (its props face it)

-- Dual-sided patties: two props per uid, one per face.
local CookDual      = {} -- [uid] = { ent = {[1],[2]}, modelName = {}, sides = {}, flipped, input }
local CookEntityUid = {} -- [entity] = uid (reverse lookup for hover/click hit-testing)
local DualTween     = {} -- [uid] = tween token (cancels an in-flight flip animation)

cookingOpen      = false
currentCookProp  = nil

local placing = nil -- live drag-to-place preview: { entity, kind, item, hit, coords }
local moving  = nil -- live drag of an already-placed prop: { uid, hit, coords, origin }
-- live finish-tool (frosting…) drag: the tube prop follows the cursor and is
-- rubbed over a placed prep part; the result prop fades in with tool travel.
-- { tube, cfg, flavor, ghosts = {[pid] = {ent, sid, idx}}, coverage = {[pid] = m}, last, applying }
local finishing = nil

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
local prepDrag = nil     -- { parts = {…}, fromSid?, hit, coords, targetSid, targetTid, tray?, piles? } while placing/moving

-- The SERVING TRAY: a tray + paper liner placed on the prep table. Food dropped
-- over it anchors WHERE you drop it on the paper (a free 2D arrangement inside
-- the rim — piles still stack), and the whole arrangement becomes ONE meal item
-- whose metadata records every layer with its (dx, dy) offset from the tray
-- centre, so a meal set back down re-renders 1:1: tray, paper, and each item
-- exactly where it was. A stack sitting on a tray is a normal PrepStack that
-- additionally carries `tid` + its offset.
local TRAYP = {
    tray_model  = "pickle_tray_01",
    paper_model = "pickle_tray_paper_01",
    paper_dz  = 0.012, -- tray-bed height: paper liner above the tray's mesh BASE. TUNE IN-GAME.
    rim_inset = 0.05,  -- shrink the droppable area vs the model bounds (rim + physics margin)
    pick_pad  = 0.03,  -- extra grab margin (m) around the tray's footprint
    pick_dz   = 0.4,   -- max height difference between the cursor's surface hit and the tray
}
local PrepTrays = {}    -- [tid] = { x, y, z, ents = { trayEnt, paperEnt } }
local prepTid = 0       -- monotonic tray id
local trayHovered = nil -- tid under the cursor (grab / make-meal tooltip)

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

-- Minimum vertical gap between two stacked layers. Flat toppings (pizza sauce/cheese)
-- are near-zero-height decals, so their modelHeight is ~0 and consecutive ones would
-- land at the SAME z, z-fight, and hide each other (the cheese vanishing under the
-- sauce). Enforcing a small floor guarantees each layer sits visibly above the one
-- below while still reading as a flat pizza. Tune in-game if layers look too spaced.
local STACK_MIN_GAP = 0.008
local function stackLayerHeight(model)
    return math.max(modelHeight(model), STACK_MIN_GAP)
end

-- Recipe containers (cake tin…) are authored like the serving tray: their origin
-- isn't reliably at the mesh bottom, so seating the ORIGIN on the oven rack / prep
-- table sinks the tin through the surface (food props like pizza dough are
-- centre-bottom and unaffected). When a stack's base layer is some recipe's
-- container prop, lift the WHOLE stack so the container's mesh bottom rests at the
-- anchor — the same physics-margin correction the serving tray's modelBaseLift
-- uses. For a true centre-bottom model this computes ~0, so nothing else moves.
local STACK_PHYS_MARGIN = 0.04
local function stackBaseLift(model)
    if not model then return 0.0 end
    local isContainer = false
    for _, r in pairs(RecipesByInput or {}) do
        if r.container_model == model then isContainer = true break end
    end
    if not isContainer then return 0.0 end
    local mn = GetModelDimensions(EnsureModel(model))
    return mn and math.max(-(mn.z + STACK_PHYS_MARGIN), 0.0) or 0.0
end

-- A stacked topping (pizza cheese/pepperoni) that has a cooked look follows the
-- _01/_02/_03 (raw/cooked/burnt) model convention. When the bake is cooked/burnt, swap
-- a raw (_01) layer to its cooked (_02) / burnt (_03) variant — but only if that model
-- actually exists in the game index, so toppings without one (e.g. sauce has only _01)
-- and a missing burnt look safely stay put instead of showing an error prop. The crust
-- is already the recipe's cooked/burnt model (not _01), so it passes through untouched.
local function cookedVariant(model, state)
    if type(model) ~= "string" or (state ~= "cooked" and state ~= "burnt") then return model end
    local function variant(suffix)
        local m = (model:gsub("_01$", suffix))
        if m ~= model and IsModelInCdimage(GetHashKey(m)) then return m end
        return nil
    end
    if state == "burnt" then return variant("_03") or variant("_02") or model end
    return variant("_02") or model
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

-- Heading (yaw) of a station's world entity, so everything interactive placed on
-- it — food, patties, prep parts, trays, previews — faces the station instead of
-- the world axes. Falls back to the stored prop heading before the station entity
-- has streamed in.
local function stationHeadingZ(propId, prop)
    local ent = GetStationEntity and GetStationEntity(propId)
    if ent and DoesEntityExist(ent) then return GetEntityRotation(ent, 2).z end
    return (prop and prop.heading) or 0.0
end

-- The open station's heading — the yaw every interactive object spawned from this
-- UI (prep parts, serving trays, drag previews, toppings, finish tools) adopts.
local function curYaw()
    local p = currentCookProp
    return p and stationHeadingZ(p.id, p) or 0.0
end

local function SpawnCookObject(uid, model, x, y, z, state, propId)
    if CookObjects[uid] then SafeDeleteEntity(CookObjects[uid]) end
    local ent = SpawnProp(model, x, y, z)
    if not ent then return end
    -- CreateProp seats the model's bounds at z; the drag preview and live-move
    -- both place the raw origin with SetEntityCoordsNoOffset, so match them here
    -- or the synced prop lands at a slightly different (nearby) spot than dragged.
    SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
    -- the item faces the station it sits on, not the world axes
    if propId then CookYaw[uid] = stationHeadingZ(propId) end
    SetEntityRotation(ent, 0.0, 0.0, CookYaw[uid] or 0.0, 2, true)
    CookObjects[uid] = ent
    CookState[uid]   = state
    CookCoords[uid]  = { x = x, y = y, z = z }
end

-- ─── oven / fryer slot items ─────────────────────────────────────────────────
--  Oven bakes and fryer fries are seated at fixed slots inside the station mesh
--  (not free-placed). The oven's cavity slots live in modules/stovetop (SeatOvenSlot);
--  the fryer basket slots live here. Cooking only advances while the door is closed /
--  the basket is lowered — the server owns that gate; we just render.

local CookSlot   = {} -- [uid] = { propId, method, door, slot }
local CookSlotStack = {} -- [uid] = { ents = {…}, heights = {…} } full build stack (bottom-to-top) for an uncooked assembled slot item
local CookProg   = {} -- [uid] = last server progress payload { prog, give, … , start }
local FryerDown  = {} -- [propId] = { [slot] = basket lowered? } (per-basket, like oven doors)
local FryerBaskets = {} -- [propId] = { [slot] = ent } always-visible basket props
local FryerBasketDown = {} -- [propId .. ":" .. slot] = that basket currently rendered lowered?
local SlotBasketTween = {} -- [propId .. ":" .. slot] = per-basket tween token
local updateSlotBasket, spawnFryerBaskets -- fwd: defined after slotOccupied below

local function slotDown(propId, slot)
    local t = FryerDown[propId]
    return t ~= nil and t[slot] == true
end

-- Fryer basket slots, LOCAL to the fryer prop (x,y); z is raised_z, or lowered_z when
-- the basket is dunked. pickle_fryer_01 has TWO basket wells (left/right). TUNE IN-GAME.
local FRYER = {
    slots     = { { x = -0.11, y = 0.0 }, { x = 0.11, y = 0.0 } },
    raised_z  = 1.0,
    lowered_z = 0.90,
    dip_ms    = 400,
    basket_model = "pickle_fryer_basket_01",
    basket_dz    = 0.0, -- basket origin offset vs the fry-item seat. TUNE IN-GAME.
}

local function fryerSlotWorld(propId, slot, lowered)
    local station = GetStationEntity and GetStationEntity(propId)
    local o = FRYER.slots[slot]
    if not station or not DoesEntityExist(station) or not o then return nil end
    return GetOffsetFromEntityInWorldCoords(station, o.x, o.y, lowered and FRYER.lowered_z or FRYER.raised_z)
end

local function alignToStation(propId, ent)
    local station = GetStationEntity and GetStationEntity(propId)
    if station and DoesEntityExist(station) and ent and DoesEntityExist(ent) then
        local sr = GetEntityRotation(station, 2)
        SetEntityRotation(ent, sr.x, sr.y, sr.z, 2, true)
    end
end

-- Delete a slot item's extra build-stack props (the base prop lives in CookObjects
-- and is handled by the caller).
local function clearSlotStack(uid)
    local st = CookSlotStack[uid]
    if not st then return end
    for _, e in ipairs(st.ents) do CookEntityUid[e] = nil; SafeDeleteEntity(e) end
    CookSlotStack[uid] = nil
end

-- Seat a slot item at its cavity/basket position (oven via stovetop module; fryer
-- here). An uncooked assembled item (e.g. a topped pizza) carries a full build stack
-- — every component prop, seated bottom-to-top so it renders exactly as it was built,
-- not just the base model. `fryerZ` overrides the basket height mid-dip tween.
local function seatSlotItem(uid, fryerZ)
    local s, ent = CookSlot[uid], CookObjects[uid]
    if not s or not (ent and DoesEntityExist(ent)) then return end
    local st = CookSlotStack[uid]
    if s.method == "oven" then
        if st then
            if SeatOvenSlotStack then SeatOvenSlotStack(s.propId, s.door, s.slot, st.ents, st.heights, st.baseDz) end
        elseif SeatOvenSlot then SeatOvenSlot(s.propId, s.door, s.slot, ent) end
    else
        local station = GetStationEntity and GetStationEntity(s.propId)
        local o = FRYER.slots[s.slot]
        if not station or not DoesEntityExist(station) or not o then return end
        local z = fryerZ or (slotDown(s.propId, s.slot) and FRYER.lowered_z or FRYER.raised_z)
        local sr = GetEntityRotation(station, 2)
        local function seatAt(e, lift)
            if not (e and DoesEntityExist(e)) then return end
            local pos = GetOffsetFromEntityInWorldCoords(station, o.x, o.y, z + lift)
            SetEntityCoordsNoOffset(e, pos.x, pos.y, pos.z, false, false, false)
            SetEntityRotation(e, sr.x, sr.y, sr.z, 2, true)
        end
        if st then
            local lift = st.baseDz or 0.0
            for i, e in ipairs(st.ents) do seatAt(e, lift); lift = lift + (st.heights[i] or 0.0) end
        else
            seatAt(ent, 0.0)
        end
    end
end

-- (Re)spawn a slot item's prop at its seat. Registered in CookEntityUid so the hover
-- projection can hit-test it like a dual patty. `stack` (optional, bottom-to-top model
-- list) renders an uncooked assembled item as its whole build stack.
local function SpawnSlotObject(uid, model, propId, method, door, slot, state, stack)
    if CookObjects[uid] then CookEntityUid[CookObjects[uid]] = nil; SafeDeleteEntity(CookObjects[uid]) end
    clearSlotStack(uid)
    CookState[uid] = state
    CookSlot[uid]  = { propId = propId, method = method, door = door, slot = slot }

    if type(stack) == "table" and #stack > 1 then
        local ents, heights = {}, {}
        for _, m in ipairs(stack) do
            local mdl = cookedVariant(m, state) -- cooked/burnt bakes swap toppings to their cooked look
            local e = SpawnProp(mdl, 0.0, 0.0, 0.0)
            if e then
                ents[#ents + 1] = e
                heights[#heights + 1] = stackLayerHeight(mdl)
                CookEntityUid[e] = uid
            end
        end
        if #ents > 0 then
            CookObjects[uid] = ents[1] -- base prop drives the hover chip projection
            CookSlotStack[uid] = { ents = ents, heights = heights, baseDz = stackBaseLift(stack[1]) }
            seatSlotItem(uid)
            return
        end
    end

    local ent = SpawnProp(model, 0.0, 0.0, 0.0)
    if not ent then return end
    CookObjects[uid] = ent
    CookEntityUid[ent] = uid
    seatSlotItem(uid)
end

-- Called by main/client when a station prop (re)spawns: adopt the fryer baskets'
-- synced up/down states and re-seat any slot items that spawned before the station
-- entity (or its oven doors) existed.
function OnStationSpawned(prop)
    if not prop then return end
    if prop.prop_type == "fryer" then
        local down = {}
        for k, v in pairs((prop.metadata and prop.metadata.basketsDown) or {}) do
            if v == true then down[tonumber(k) or k] = true end
        end
        FryerDown[prop.id] = down
        spawnFryerBaskets(prop.id)
    end
    for uid, s in pairs(CookSlot) do
        if s.propId == prop.id then seatSlotItem(uid) end
    end
end

-- Is a slot on this station already taken (by any live slot item)?
local function slotOccupied(method, propId, door, slot)
    for _, s in pairs(CookSlot) do
        if s.method == method and s.propId == propId and s.slot == slot
            and (method ~= "oven" or s.door == door) then return true end
    end
    return false
end

-- ─── always-visible fryer baskets ─────────────────────────────────────────────
-- Every fryer carries one basket prop per slot, spawned with the station so the
-- baskets show whether or not anyone is using it. Each basket is lowered/raised
-- INDIVIDUALLY (click it in-world, like an oven door); its fry item rides along.

local function seatBasket(propId, slot, z)
    local ent = FryerBaskets[propId] and FryerBaskets[propId][slot]
    local station = GetStationEntity and GetStationEntity(propId)
    local o = FRYER.slots[slot]
    if not (ent and DoesEntityExist(ent)) or not (station and DoesEntityExist(station)) or not o then return end
    z = z or (slotDown(propId, slot) and FRYER.lowered_z or FRYER.raised_z)
    local pos = GetOffsetFromEntityInWorldCoords(station, o.x, o.y, z + FRYER.basket_dz)
    SetEntityCoordsNoOffset(ent, pos.x, pos.y, pos.z, false, false, false)
    alignToStation(propId, ent)
end

-- Re-seat one basket AND the fry item riding in it after its state changed; tweens
-- between raised/lowered when the state flipped (animate), else snaps into place.
updateSlotBasket = function(propId, slot, animate)
    local key = propId .. ":" .. slot
    local want = slotDown(propId, slot)
    local function seatAll(z)
        seatBasket(propId, slot, z)
        for uid, s in pairs(CookSlot) do
            if s.method == "fry" and s.propId == propId and s.slot == slot then seatSlotItem(uid, z) end
        end
    end
    if FryerBasketDown[key] == want or not animate then
        FryerBasketDown[key] = want
        return seatAll(nil)
    end
    FryerBasketDown[key] = want
    SlotBasketTween[key] = (SlotBasketTween[key] or 0) + 1
    local token = SlotBasketTween[key]
    local from = want and FRYER.raised_z or FRYER.lowered_z
    local to   = want and FRYER.lowered_z or FRYER.raised_z
    CreateThread(function()
        local started = GetGameTimer()
        while SlotBasketTween[key] == token do
            local t = math.min((GetGameTimer() - started) / FRYER.dip_ms, 1.0)
            seatAll(from + (to - from) * t)
            if t >= 1.0 then return end
            Wait(0)
        end
    end)
end

-- Called by main/client when a fryer station is removed / the world resyncs.
function DespawnFryerBaskets(propId)
    for _, e in pairs(FryerBaskets[propId] or {}) do SafeDeleteEntity(e) end
    FryerBaskets[propId] = nil
    for slot in ipairs(FRYER.slots) do
        local key = propId .. ":" .. slot
        FryerBasketDown[key] = nil
        SlotBasketTween[key] = nil -- also stops any in-flight tween
    end
end

spawnFryerBaskets = function(propId)
    DespawnFryerBaskets(propId)
    FryerBaskets[propId] = {}
    for slot in ipairs(FRYER.slots) do
        local e = SpawnProp(FRYER.basket_model, 0.0, 0.0, 0.0)
        if e then
            FryerBaskets[propId][slot] = e
            FryerBasketDown[propId .. ":" .. slot] = slotDown(propId, slot)
            seatBasket(propId, slot)
        end
    end
end

-- The open slot the cursor is CLOSE TO (within SLOT_SNAP_R normalized-screen radius),
-- for a placement preview: { door?, slot, w }, or nil when the cursor isn't near any
-- slot (so the preview follows the cursor instead of pre-locking onto a slot).
-- Oven only offers slots whose door is open; fryer offers any free basket slot.
local SLOT_SNAP_R = 0.2 -- ~ how near the cursor must be to a slot to snap onto it
local function nearestOpenSlot(method)
    local prop = currentCookProp; if not prop then return nil end
    local cx, cy = GetNuiCursorPosition()
    local sw, sh = GetActiveScreenResolution()
    local cnx = (sw > 0) and (cx / sw) or 0.0
    local cny = (sh > 0) and (cy / sh) or 0.0
    local best
    local function consider(door, slot, w)
        local on, sx, sy = GetScreenCoordFromWorldCoord(w.x, w.y, w.z)
        if not on then return end
        local dx, dy = sx - cnx, sy - cny
        local d2 = dx * dx + dy * dy
        if d2 > SLOT_SNAP_R * SLOT_SNAP_R then return end -- too far — don't snap
        if not best or d2 < best.d2 then best = { door = door, slot = slot, w = w, d2 = d2 } end
    end
    if method == "oven" then
        local n = OvenSlotCount and OvenSlotCount() or 0
        for door = 1, 2 do
            if IsOvenDoorOpen and IsOvenDoorOpen(prop.id, door) then
                for slot = 1, n do
                    if not slotOccupied("oven", prop.id, door, slot) then
                        local w = OvenSlotWorld and OvenSlotWorld(prop.id, door, slot)
                        if w then consider(door, slot, w) end
                    end
                end
            end
        end
    else
        for slot = 1, #FRYER.slots do
            if not slotOccupied("fry", prop.id, nil, slot) then
                local w = fryerSlotWorld(prop.id, slot, slotDown(prop.id, slot))
                if w then consider(nil, slot, w) end
            end
        end
    end
    return best
end

-- The fryer basket the cursor is over (screen-projected, same snap radius as
-- placement) — click-to-dip targets one basket, like clicking an oven door.
local function hoveredBasketSlot(propId)
    local cx, cy = GetNuiCursorPosition()
    local sw, sh = GetActiveScreenResolution()
    local cnx = (sw > 0) and (cx / sw) or 0.0
    local cny = (sh > 0) and (cy / sh) or 0.0
    local best, bestD
    for slot in ipairs(FRYER.slots) do
        local w = fryerSlotWorld(propId, slot, slotDown(propId, slot))
        if w then
            local on, sx, sy = GetScreenCoordFromWorldCoord(w.x, w.y, w.z)
            if on then
                local dx, dy = sx - cnx, sy - cny
                local d = dx * dx + dy * dy
                if d <= SLOT_SNAP_R * SLOT_SNAP_R and (not bestD or d < bestD) then best, bestD = slot, d end
            end
        end
    end
    return best
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
local function orientPair(ents, x, y, z, flipped, yaw)
    local cook = cookSide(flipped)
    for s = 1, 2 do
        local ent = ents[s]
        if ent and DoesEntityExist(ent) then
            local isCook = s == cook
            local roll   = isCook and DUAL.bottom_roll or DUAL.top_roll
            local dz     = DUAL.base_lift + (isCook and 0.0 or DUAL.face_gap)
            SetEntityCoordsNoOffset(ent, x, y, z + dz, false, false, false)
            SetEntityRotation(ent, 0.0, roll, yaw or 0.0, 2, true)
        end
    end
end

-- Seat a cheese slice on a patty's visible (up) face, given the patty's base
-- (x,y,z). Pure + shared by the stovetop and the prep table; no-op without a slice.
local function placeCheeseAt(ent, x, y, z, yaw)
    if not ent or not DoesEntityExist(ent) then return end
    SetEntityCoordsNoOffset(ent, x, y, z + DUAL.base_lift + DUAL.face_gap + CHEESE.z, false, false, false)
    SetEntityRotation(ent, 0.0, DUAL.top_roll + CHEESE.roll, yaw or 0.0, 2, true)
end

-- Keep the stovetop patty's cheese slice (if any) sitting on its visible face.
local function placeCheese(uid)
    local rec, c = CookDual[uid], CookCoords[uid]
    if not rec or not c then return end
    placeCheeseAt(rec.cheeseEnt, c.x, c.y, c.z, CookYaw[uid])
end

local function orientDualSnap(uid)
    local rec, c = CookDual[uid], CookCoords[uid]
    if not rec or not c then return end
    orientPair(rec.ent, c.x, c.y, c.z, rec.flipped, CookYaw[uid])
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
                    SetEntityRotation(ent, 0.0, roll, CookYaw[uid] or 0.0, 2, true)
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
    if p.prop_id then CookYaw[uid] = stationHeadingZ(p.prop_id) end -- face the stove
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
                SetEntityRotation(ent, 0.0, dualTargetRoll(rec, s), CookYaw[uid] or 0.0, 2, true)
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

-- The build stack (ordered component models) of an uncooked assembled tray item,
-- keyed "item|cheese|sig" (sig = the entry's build-variation signature), refreshed
-- from the tray payload. Lets the drag-to-oven preview render the whole stack
-- (matching what gets placed), not just the base model.
local PreviewStacks = {}
local function previewStackKey(item, cheese, sig)
    return tostring(item) .. "|" .. (tonumber(cheese) or 0) .. "|" .. tostring(sig or "")
end
local function previewStackFor(item, cheese, sig)
    return PreviewStacks[previewStackKey(item, cheese, sig)]
end

-- Lay an ordered set of props flush bottom-to-top at (x,y,z), all facing `headingZ`
-- (the station's heading) so the preview, the seated stack, and a dragged-out stack
-- share one consistent rotation.
local function layoutPreviewStack(ents, heights, x, y, z, headingZ, baseDz)
    local lift = baseDz or 0.0
    for i, e in ipairs(ents) do
        if e and DoesEntityExist(e) then
            SetEntityCoordsNoOffset(e, x, y, z + lift, false, false, false)
            SetEntityRotation(e, 0.0, 0.0, headingZ or 0.0, 2, true)
        end
        lift = lift + (heights[i] or 0.0)
    end
end

-- Lift a seated slot item (single prop or full stack) out to follow the cursor while
-- the player drags it toward the bar to collect — the same feel as dragging it in.
-- Keeps the flush layer spacing and the station facing so nothing pops.
local function moveSlotStackTo(uid, x, y, z)
    local s = CookSlot[uid]
    local headingZ = s and stationHeadingZ(s.propId) or 0.0
    local st = CookSlotStack[uid]
    if st then
        layoutPreviewStack(st.ents, st.heights, x, y, z, headingZ, st.baseDz)
    else
        local ent = CookObjects[uid]
        if ent and DoesEntityExist(ent) then
            SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
            SetEntityRotation(ent, 0.0, 0.0, headingZ, 2, true)
        end
    end
end

-- Delete a placement preview's entity/entities (dual + stack previews carry several).
local function deletePreview(p)
    if not p then return end
    if p.dual then
        for _, e in ipairs(p.ent) do SafeDeleteEntity(e) end
    elseif p.stackEnts then
        for _, e in ipairs(p.stackEnts) do SafeDeleteEntity(e) end
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

RegisterNetEvent("pickle_restaurants:cooking:spawn", function(uid, model, x, y, z, state, propId)
    SpawnCookObject(uid, model, x, y, z, state, propId)
end)

RegisterNetEvent("pickle_restaurants:cooking:update", function(uid, model, state)
    local s = CookSlot[uid]
    if s then return SpawnSlotObject(uid, model, s.propId, s.method, s.door, s.slot, state) end
    local c = CookCoords[uid]; if not c then return end
    SpawnCookObject(uid, model, c.x, c.y, c.z, state)
end)

-- spawn or update a dual-sided patty (both faces + live status in one payload)
RegisterNetEvent("pickle_restaurants:cooking:dual", function(p)
    if p then RebuildDual(p) end
end)

-- spawn an oven/fryer item at its station slot
RegisterNetEvent("pickle_restaurants:cooking:slotSpawn", function(p)
    if p then SpawnSlotObject(p.uid, p.model, p.prop_id, p.method, p.door, p.slot, p.state, p.stack) end
end)

-- live cook progress for an oven/fryer item's hover panel
RegisterNetEvent("pickle_restaurants:cooking:progress", function(p)
    if p and p.uid then p.start = GetGameTimer(); CookProg[p.uid] = p end
end)

-- one fryer basket lowered/raised for everyone -> animate that basket + its item
RegisterNetEvent("pickle_restaurants:fryer:dip", function(propId, slot, lowered)
    slot = tonumber(slot); if not slot then return end
    FryerDown[propId] = FryerDown[propId] or {}
    FryerDown[propId][slot] = lowered and true or false
    updateSlotBasket(propId, slot, true)
end)

RegisterNetEvent("pickle_restaurants:cooking:move", function(uid, x, y, z)
    MoveCookObjectLocal(uid, x, y, z)
end)

RegisterNetEvent("pickle_restaurants:cooking:remove", function(uid)
    if CookObjects[uid] then CookEntityUid[CookObjects[uid]] = nil end
    if not RemoveDual(uid) then
        SafeDeleteEntity(CookObjects[uid])
    end
    clearSlotStack(uid)
    CookObjects[uid], CookState[uid], CookCoords[uid], CookSlot[uid], CookProg[uid], CookYaw[uid] = nil, nil, nil, nil, nil, nil
end)

RegisterNetEvent("pickle_restaurants:cooking:bulk", function(list)
    for _, it in ipairs(list or {}) do
        if it.dual then
            RebuildDual(it)
        elseif it.method == "oven" or it.method == "fry" then
            SpawnSlotObject(it.uid, it.model, it.prop_id, it.method, it.door, it.slot, it.state, it.stack)
            it.start = GetGameTimer(); CookProg[it.uid] = it
        else
            SpawnCookObject(it.uid, it.model, it.x, it.y, it.z, it.state, it.prop_id)
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
    -- Cache each uncooked item's build stack so a drag into the oven can preview the
    -- whole stack, exactly what placement will render.
    PreviewStacks = {}
    for _, e in ipairs(tray or {}) do
        if e.stack then PreviewStacks[previewStackKey(e.item, e.cheese, e.sig)] = e.stack end
    end
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
                   source = spec.source, cheese = spec.cheese or 0, sig = spec.sig, ents = {} }

    if type(spec.stack) == "table" and #spec.stack > 1 then
        -- A product that carries a build stack (e.g. a cooked pizza) is ONE logical
        -- part rendered as its whole layer tower — crust + sauce + cheese + toppings
        -- — so it never collapses to a bare base prop on the prep table. `state`
        -- (cooked/burnt) swaps each topping to its cooked look, same as the oven.
        -- a container base layer (cake tin) starts the tower at its mesh-bottom
        -- correction so the tin rests ON the table instead of sinking through it
        local lifts, lift = {}, stackBaseLift(spec.stack[1])
        for _, m in ipairs(spec.stack) do
            local mdl = cookedVariant(m, spec.state)
            local e = SpawnProp(mdl, base.x, base.y, base.z)
            if e then
                part.ents[#part.ents + 1] = e
                lifts[#lifts + 1] = lift
                lift = lift + stackLayerHeight(mdl)
            end
        end
        if #part.ents == 0 then return nil end
        part.stacked = true
        part.lifts   = lifts
        part.height  = lift
        return part
    end

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
        -- floor near-zero (flat decal) layers so stacked pizza toppings stay visible
        part.height = stackLayerHeight(spec.model)
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
    local yaw = curYaw() -- parts face the prep station, not the world axes
    if part.patty then
        orientPair(part.faces, x, y, z, false, yaw)
        placeCheeseAt(part.cheeseEnt, x, y, z, yaw)
        return
    end
    if part.stacked then
        -- a build-stack part lays its layers flush bottom-to-top from the base z
        for i, e in ipairs(part.ents) do
            if e and DoesEntityExist(e) then
                SetEntityCoordsNoOffset(e, x, y, z + (part.lifts[i] or 0.0), false, false, false)
                SetEntityRotation(e, 0.0, 0.0, yaw, 2, true)
            end
        end
        return
    end
    local e = part.ents[1]
    if e and DoesEntityExist(e) then
        if flip then
            SetEntityCoordsNoOffset(e, x, y, z + part.height, false, false, false)
            SetEntityRotation(e, 0.0, 180.0, yaw, 2, true)
        else
            SetEntityCoordsNoOffset(e, x, y, z, false, false, false)
            SetEntityRotation(e, 0.0, 0.0, yaw, 2, true)
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

-- ─── serving tray helpers ────────────────────────────────────────────────────

-- The tray + paper models do NOT share the food props' centre-bottom origin, so
-- placing their raw origin on the surface sinks the tray below the drop point and
-- leaves the paper (offset from the origin, not the tray's real base) floating
-- above it. The physics box dips one ~0.04 margin below the true mesh bottom (see
-- modelHeight), so the true bottom sits at mn.z + margin — lifting the origin by
-- -(mn.z + margin) rests the mesh exactly ON the surface, whatever its origin.
local TRAY_PHYS_MARGIN = 0.04
local trayLiftCache = {}
local function modelBaseLift(model)
    local v = trayLiftCache[model]
    if v then return v end
    local mn = GetModelDimensions(EnsureModel(model))
    v = mn and -(mn.z + TRAY_PHYS_MARGIN) or 0.0
    trayLiftCache[model] = v
    return v
end

-- Food rests on the paper liner: bed height + a hair so it doesn't z-fight the
-- (near-zero-thickness) sheet.
local function trayFoodDz()
    return TRAYP.paper_dz + 0.002
end

-- Droppable half-extents from the tray model's bounds, inset past the rim so
-- anchored food reads as ON the paper (drop offsets are clamped into this box).
local function trayHalfExtents()
    local mn, mx = GetModelDimensions(EnsureModel(TRAYP.tray_model))
    if not (mn and mx) then return 0.15, 0.10 end
    return math.max((mx.x - mn.x) * 0.5 - TRAYP.rim_inset, 0.05),
           math.max((mx.y - mn.y) * 0.5 - TRAYP.rim_inset, 0.05)
end

-- Seat the tray + paper pair at surface point (x, y, z): the tray's mesh bottom
-- rests ON the surface and the paper lies on the tray bed (paper_dz above the
-- base), each corrected for its own origin offset.
local function layoutTrayAt(ents, x, y, z)
    local yaw = curYaw() -- the tray faces the prep station, not the world axes
    local zs = {
        z + modelBaseLift(TRAYP.tray_model),
        z + TRAYP.paper_dz + modelBaseLift(TRAYP.paper_model),
    }
    for i, e in ipairs(ents or {}) do
        if e and DoesEntityExist(e) then
            SetEntityCoordsNoOffset(e, x, y, zs[i] or z, false, false, false)
            SetEntityRotation(e, 0.0, 0.0, yaw, 2, true)
        end
    end
end

local function spawnTrayEnts(x, y, z)
    local t = SpawnProp(TRAYP.tray_model, x, y, z)
    local p = SpawnProp(TRAYP.paper_model, x, y, z)
    if not t or not p then SafeDeleteEntity(t); SafeDeleteEntity(p); return nil end
    local ents = { t, p }
    layoutTrayAt(ents, x, y, z)
    return ents
end

-- Pickable half-extents: the WHOLE tray incl. the rim (physics margin trimmed),
-- plus a little grab padding — unlike trayHalfExtents, which is the inner
-- droppable area only.
local function trayPickExtents()
    local mn, mx = GetModelDimensions(EnsureModel(TRAYP.tray_model))
    if not (mn and mx) then return 0.25, 0.18 end
    return (mx.x - mn.x) * 0.5 - TRAY_PHYS_MARGIN + TRAYP.pick_pad,
           (mx.y - mn.y) * 0.5 - TRAY_PHYS_MARGIN + TRAYP.pick_pad
end

-- The tray under the cursor: raycast the cursor to the surface (tray props have
-- collision off, so the ray lands right under the cursor) and test that world
-- point against each tray's rectangular footprint. A screen-radius test around
-- the centre only ever covered the middle of the tray (the paper), leaving the
-- rim un-grabbable. `coords` (optional) reuses a raycast the caller already did.
-- Parts win over trays — only consulted when no part is hovered.
local function pickTray(coords)
    if not coords then
        local hit, c = CursorToWorld()
        if not hit or not c then return nil end
        coords = c
    end
    local best, bd
    for tid, t in pairs(PrepTrays) do
        if math.abs(coords.z - t.z) <= TRAYP.pick_dz then
            local hx, hy = trayPickExtents()
            local dx, dy = coords.x - t.x, coords.y - t.y
            if math.abs(dx) <= hx and math.abs(dy) <= hy then
                local d2 = dx * dx + dy * dy
                if not bd or d2 < bd then best, bd = tid, d2 end
            end
        end
    end
    return best
end

-- Outline a tray (amber for hover, green for a drop target). nil clears.
local outlinedTid, outlinedTidRGB = nil, nil
local function setTrayOutline(tid, r, g, b)
    local rgb = tid and ((r or 80) .. "," .. (g or 200) .. "," .. (b or 120)) or nil
    if outlinedTid == tid and outlinedTidRGB == rgb then return end
    local old = outlinedTid and PrepTrays[outlinedTid]
    if old then for _, e in ipairs(old.ents) do
        if DoesEntityExist(e) then SetEntityDrawOutline(e, false) end end end
    outlinedTid, outlinedTidRGB = tid, rgb
    local new = tid and PrepTrays[tid]
    if new then for _, e in ipairs(new.ents) do
        if DoesEntityExist(e) then SetEntityDrawOutline(e, true); SetEntityDrawOutlineColor(r or 80, g or 200, b or 120, 255) end end end
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

local function removePrepTray(tid)
    local t = PrepTrays[tid]; if not t then return end
    for _, e in ipairs(t.ents) do SafeDeleteEntity(e) end
    PrepTrays[tid] = nil
end

-- Delete a prep drag's props — the carried parts plus, for a tray drag (a grabbed
-- tray / a meal being set down), the tray + paper pair riding along.
local function deleteDrag(drag)
    if not drag then return end
    deleteParts(drag.parts)
    for _, e in ipairs(drag.tray or {}) do SafeDeleteEntity(e) end
end

-- Drop an in-progress finish-tool drag: the tube and every partially-faded result
-- ghost go away. Nothing was consumed (consumption only happens at full coverage),
-- so coverage simply resets with the drag.
local function cancelFinish()
    local f = finishing; finishing = nil
    if not f then return end
    SafeDeleteEntity(f.tube)
    for _, g in pairs(f.ghosts or {}) do SafeDeleteEntity(g.ent) end
end

-- Group carried parts into piles by their (dx, dy) tray offset — consecutive
-- parts at the same spot stack bottom-to-top, mirroring how the meal was built.
local function groupPiles(parts)
    local piles = {}
    for _, p in ipairs(parts) do
        local dx, dy = tonumber(p.dx) or 0.0, tonumber(p.dy) or 0.0
        local last = piles[#piles]
        if last and math.abs(last.dx - dx) < 0.001 and math.abs(last.dy - dy) < 0.001 then
            last.parts[#last.parts + 1] = p
        else
            piles[#piles + 1] = { dx = dx, dy = dy, parts = { p } }
        end
    end
    return piles
end

-- Lay a carried tray (+ its piles) at a world point — the live preview while a
-- meal / a grabbed tray follows the cursor.
local function layoutTrayGroup(drag, x, y, z)
    layoutTrayAt(drag.tray, x, y, z)
    local fz = z + trayFoodDz()
    for _, pile in ipairs(drag.piles or {}) do
        layoutParts(pile.parts, x + pile.dx, y + pile.dy, fz, false)
    end
end

-- Commit a carried tray group: (re)create the tray at (x, y, z) and one stack per
-- pile, anchored at its offset. Used by the meal un-make drop and a tray move.
local function commitTrayGroup(x, y, z, ents, piles)
    prepTid = prepTid + 1
    local tid = prepTid
    PrepTrays[tid] = { x = x, y = y, z = z, ents = ents }
    layoutTrayAt(ents, x, y, z)
    local fz = z + trayFoodDz()
    for _, pile in ipairs(piles or {}) do
        prepSid = prepSid + 1
        local stack = { x = x + pile.dx, y = y + pile.dy, z0 = fz,
                        tid = tid, dx = pile.dx, dy = pile.dy, parts = pile.parts }
        PrepStacks[prepSid] = stack
        relayout(stack)
    end
    return tid
end

-- The stacks sitting on a tray, as the make-meal payload: each pile's reserved
-- part ids (bottom-to-top) + its offset, sorted deterministically so the same
-- arrangement always produces the same meal signature.
local function collectTrayPiles(tid)
    local piles = {}
    for sid, s in pairs(PrepStacks) do
        if s.tid == tid then
            local ids = {}
            for _, p in ipairs(s.parts) do if p.id then ids[#ids + 1] = p.id end end
            if #ids > 0 then piles[#piles + 1] = { sid = sid, ids = ids, dx = s.dx or 0.0, dy = s.dy or 0.0 } end
        end
    end
    table.sort(piles, function(a, b)
        if math.abs(a.dx - b.dx) > 0.0005 then return a.dx < b.dx end
        return a.dy < b.dy
    end)
    return piles
end

-- Turn a placed tray's arrangement into ONE meal item (the server consumes the
-- reserved parts and records each layer's offset). On success the tray and its
-- stacks are torn down. Returns the server result, or nil for an empty tray.
local function makeMealFromTray(tid, silent)
    local piles = collectTrayPiles(tid)
    if #piles == 0 then return nil end
    local items = {}
    for _, p in ipairs(piles) do items[#items + 1] = { ids = p.ids, dx = p.dx, dy = p.dy } end
    local res = lib.callback.await("pickle_restaurants:cooking:prepMakeMeal", false, { items = items })
    if res and res.ok then
        for _, p in ipairs(piles) do removePrepStack(p.sid) end
        removePrepTray(tid)
        if not silent and res.label then ShowNotification("Made " .. res.label) end
    elseif not silent and res and res.error then
        ShowNotification(res.error)
    end
    return res
end

local function clearPrepStacks()
    setOutline(nil)
    setTrayOutline(nil)
    if prepDrag then deleteDrag(prepDrag); prepDrag = nil end
    for sid in pairs(PrepStacks) do removePrepStack(sid) end
    for tid in pairs(PrepTrays) do removePrepTray(tid) end
    PrepStacks = {}
    prepHovered = nil
    trayHovered = nil
end

-- The drag loop shared by placing (new parts from the bar) and moving (parts
-- lifted off a stack): follow the cursor — snap onto the stack under it, anchor
-- onto the serving tray under it (free 2D placement on the paper), else a new
-- stack at the cursor world point — and lay the carried parts flush on top.
-- A tray drag (drag.tray: a grabbed tray or a meal being set down) is free
-- placement only: trays never stack onto piles or other trays.
local function runDragThread(drag)
    CreateThread(function()
        while prepDrag == drag do
            local hit, coords = CursorToWorld()
            if drag.tray then
                if hit and coords then
                    drag.hit, drag.coords = true, { x = coords.x, y = coords.y, z = coords.z }
                    layoutTrayGroup(drag, coords.x, coords.y, coords.z)
                else
                    drag.hit = false
                end
                Wait(0)
            else
                local sid = pickPart(nil) -- stack under the cursor (append to its top)
                local tid = (not sid and hit and coords) and pickTray(coords) or nil
                if sid then
                    local s = PrepStacks[sid]
                    local z0 = stackTopZ(s)
                    drag.hit, drag.targetSid, drag.targetTid, drag.coords = true, sid, nil, { x = s.x, y = s.y, z = z0 }
                    setOutline(sid, 80, 200, 120)
                    setTrayOutline(nil)
                    layoutParts(drag.parts, s.x, s.y, z0, false)
                elseif tid and hit and coords then
                    -- over a tray: anchor to the paper where the cursor points, clamped
                    -- inside the rim; release starts a new pile at that exact offset
                    local t = PrepTrays[tid]
                    local hx, hy = trayHalfExtents()
                    local dx = math.min(math.max(coords.x - t.x, -hx), hx)
                    local dy = math.min(math.max(coords.y - t.y, -hy), hy)
                    local fz = t.z + trayFoodDz()
                    drag.hit, drag.targetSid, drag.targetTid = true, nil, tid
                    drag.coords = { x = t.x + dx, y = t.y + dy, z = fz, dx = dx, dy = dy }
                    setOutline(nil)
                    setTrayOutline(tid, 80, 200, 120)
                    layoutParts(drag.parts, drag.coords.x, drag.coords.y, fz, false)
                elseif hit and coords then
                    drag.hit, drag.targetSid, drag.targetTid, drag.coords = true, nil, nil, { x = coords.x, y = coords.y, z = coords.z }
                    setOutline(nil)
                    setTrayOutline(nil)
                    layoutParts(drag.parts, coords.x, coords.y, coords.z, #drag.parts == 1)
                else
                    drag.hit = false
                end
                Wait(0)
            end
        end
        setOutline(nil)
        setTrayOutline(nil)
    end)
end

local function StopCooking()
    local wasPrep = currentCookProp and currentCookProp.prop_type == "kitchen_prep"
    -- Deliver completed work on the way out: each stack still on the table is saved as
    -- its closest product (the exact variation preserved). Stacks that form no product
    -- fall through to prepClose below, which drops their reservations — parts stay in
    -- the player's holdings, so nothing is lost either way.
    if wasPrep then
        -- Serving trays first: each arrangement becomes its meal (a failed make
        -- leaves its stacks behind for the per-stack save below; empty trays are
        -- just put away by clearPrepStacks).
        for tid in pairs(PrepTrays) do makeMealFromTray(tid, true) end
        for _, stack in pairs(PrepStacks) do
            local ids = {}
            for _, p in ipairs(stack.parts) do if p.id then ids[#ids + 1] = p.id end end
            if #ids > 0 then
                lib.callback.await("pickle_restaurants:cooking:prepSaveStack", false, { ids = ids })
            end
        end
    end
    cookingOpen = false
    currentCookProp = nil
    cancelPlace() -- drop any in-progress placement preview
    cancelMove()  -- drop any in-progress drag of a placed prop
    cancelFinish() -- drop any in-progress finish-tool (frosting) drag
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
                    elseif CookSlot[uid] then
                        -- oven/fryer item: single gated timeline; count up locally only
                        -- while the gate is open (door closed / basket down).
                        local pr = CookProg[uid]
                        local pg = (pr and pr.prog) or {}
                        local st = pg.state or CookState[uid] or "raw"
                        local total = pg.total or 0
                        local elapsed = (pg.elapsed or 0) + ((pg.gate and pr and pr.start) and (now - pr.start) or 0)
                        local percent = 0.0
                        if st == "burnt" then percent = 1.0 elseif total > 0 then percent = math.min(1.0, elapsed / total) end
                        local slot = CookSlot[uid]
                        items[#items + 1] = {
                            uid = uid, single = true, onScreen = onScreen, x = sx, y = sy,
                            method = slot.method, state = st, percent = percent,
                            gate = pg.gate and true or false,
                            burningSoon = (st == "cooked" and percent > 0.66),
                            -- a fry in a lowered basket can't be grabbed — the NUI
                            -- refuses to even start the drag (raise the basket first)
                            locked = (slot.method == "fry" and slotDown(slot.propId, slot.slot)) or nil,
                            give = pr and pr.give, giveLabel = pr and pr.giveLabel, giveImage = pr and pr.giveImage,
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
            local prepHoverTid = nil
            if currentCookProp and currentCookProp.prop_type == "kitchen_prep" and not prepDrag and not finishing then
                local sid, _, part = pickPart(nil)
                if part then prepHoverPid = part.pid end
                setOutline(sid, 255, 180, 40)
                local stack = sid and PrepStacks[sid]
                if stack then
                    local on, sx, sy = GetScreenCoordFromWorldCoord(stack.x, stack.y, stackTopZ(stack))
                    prepTip = { sid = sid, onScreen = on, x = sx, y = sy, provides = stackProvides(stack) }
                end
                -- No part hovered: the serving tray itself (grab it to move / make the
                -- meal). Its tooltip counts the items arranged on it.
                prepHoverTid = (not sid) and pickTray() or nil
                setTrayOutline(prepHoverTid, 255, 180, 40)
                if prepHoverTid then
                    local t = PrepTrays[prepHoverTid]
                    local n = 0
                    for _, s in pairs(PrepStacks) do if s.tid == prepHoverTid then n = n + #s.parts end end
                    local on, sx, sy = GetScreenCoordFromWorldCoord(t.x, t.y, t.z + trayFoodDz() + 0.06)
                    prepTip = { tray = true, tid = prepHoverTid, onScreen = on, x = sx, y = sy, count = n }
                end
            end
            prepHovered = prepHoverPid
            trayHovered = prepHoverTid

            SendNUIMessage({ action = "cookingItems", items = items, hovered = hoveredUid,
                             prepHovered = prepHoverPid, prepTrayHovered = prepHoverTid, prepTip = prepTip })

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
        local p = { dual = true, ent = { e1, e2 }, kind = d.kind, item = d.item, source = d.source, cheese = d.cheese, hit = false }
        placing = p
        CreateThread(function()
            while placing == p do
                local hit, coords = CursorToWorld()
                if hit and coords then
                    p.hit, p.coords = true, coords
                    orientPair(p.ent, coords.x, coords.y, coords.z, false, curYaw())
                else
                    p.hit = false
                end
                Wait(0)
            end
        end)
        return cb({ ok = true })
    end

    -- Oven / fryer: the preview snaps to the nearest OPEN slot (not a free raycast);
    -- release drops it into that cavity/basket seat.
    local method = recipe and recipe.method or nil
    if recipe and (method == "oven" or method == "fry") then
        -- An uncooked assembled item (topped pizza) previews its WHOLE build stack, so
        -- the drag reads the same as what placement renders — not just the base model.
        local stackModels = (d.source == "tray") and previewStackFor(d.item, d.cheese, d.sig) or nil
        -- A containered bake (cake tin, cookie tray…) previews as container + food,
        -- mirroring what the server folds into the placed stack.
        if recipe.container_model and recipe.container_model ~= "" then
            stackModels = stackModels or { recipe.raw_model }
            if stackModels[1] ~= recipe.container_model then
                table.insert(stackModels, 1, recipe.container_model)
            end
        end
        if stackModels and #stackModels > 1 then
            local ents, heights = {}, {}
            for _, m in ipairs(stackModels) do
                local e = SpawnProp(m, base.x, base.y, base.z)
                if e then ents[#ents + 1] = e; heights[#heights + 1] = stackLayerHeight(m) end
            end
            if #ents == 0 then return cb({ ok = false }) end
            local headingZ = stationHeadingZ(base.id, base)
            local baseDz = stackBaseLift(stackModels[1]) -- container mesh-bottom correction
            local p = { stackEnts = ents, stackHeights = heights, kind = d.kind, item = d.item,
                        slotmode = method, source = d.source, cheese = d.cheese, sig = d.sig, hit = false }
            placing = p
            CreateThread(function()
                while placing == p do
                    local best = nearestOpenSlot(method)
                    if best then
                        p.hit, p.door, p.slot = true, best.door, best.slot
                        layoutPreviewStack(ents, heights, best.w.x, best.w.y, best.w.z, headingZ, baseDz)
                    else
                        p.hit = false
                        local hit, coords = CursorToWorld()
                        if hit and coords then layoutPreviewStack(ents, heights, coords.x, coords.y, coords.z, headingZ, baseDz) end
                    end
                    Wait(0)
                end
            end)
            return cb({ ok = true })
        end

        local model = recipe.raw_model
        local ent = model and SpawnProp(model, base.x, base.y, base.z) or nil
        if not ent then return cb({ ok = false }) end
        SetEntityRotation(ent, 0.0, 0.0, curYaw(), 2, true) -- face the station while dragging
        local p = { entity = ent, kind = d.kind, item = d.item, slotmode = method, source = d.source, cheese = d.cheese, sig = d.sig, hit = false }
        placing = p
        CreateThread(function()
            while placing == p do
                local best = nearestOpenSlot(method)
                if best then
                    -- cursor is near an open slot: snap the preview onto it (droppable)
                    p.hit, p.door, p.slot = true, best.door, best.slot
                    SetEntityCoordsNoOffset(ent, best.w.x, best.w.y, best.w.z, false, false, false)
                    alignToStation(base.id, ent)
                else
                    -- not near a slot: follow the cursor (but it can't be dropped here)
                    p.hit = false
                    local hit, coords = CursorToWorld()
                    if hit and coords then
                        SetEntityCoordsNoOffset(ent, coords.x, coords.y, coords.z, false, false, false)
                    end
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
    SetEntityRotation(ent, 0.0, 0.0, curYaw(), 2, true) -- face the station while dragging
    local p = { entity = ent, kind = d.kind, item = d.item, source = d.source, cheese = d.cheese, hit = false }
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
    if (d and d.cancel) or not p.hit or (not p.slotmode and not p.coords) then
        deletePreview(p)
        return cb({ ok = false })
    end
    local payload = { prop_id = currentCookProp and currentCookProp.id, kind = p.kind, item = p.item,
                      source = p.source, cheese = p.cheese, sig = p.sig } -- source "tray" cooks a tray item (of that exact build variation)
    if p.slotmode then
        payload.door, payload.slot = p.door, p.slot   -- oven/fryer: seat into a slot
    else
        payload.x, payload.y, payload.z = p.coords.x, p.coords.y, p.coords.z
    end
    local res = lib.callback.await("pickle_restaurants:cooking:place", false, payload)
    -- Delete the preview only after the server's synced prop has spawned (same
    -- model + coords), so they overlap and there's no visible gap.
    deletePreview(p)
    if res and res.ok then RefreshBar(); RefreshTray() elseif res and res.error then ShowNotification(res.error) end
    cb(res or { ok = false })
end)

-- chip grabbed: drag the *real* placed prop live under the cursor, the same way
-- a fresh ingredient places. Collision is off so the ray passes through it.
RegisterNUICallback("cooking:beginMove", function(d, cb)
    local uid = d and d.uid
    if not uid or not CookObjects[uid] then return cb({ ok = false }) end
    cancelPlace()
    cancelMove()
    -- Oven/fryer items live in a fixed slot. The drag is only a gesture to collect
    -- (drop on the bar), but lift the item out to follow the cursor while dragging —
    -- same feel as dragging it in — and snap it back into the slot on a world release.
    if CookSlot[uid] then
        local method = CookSlot[uid].method
        local m = { uid = uid, slot = true, hit = false }
        moving = m
        CreateThread(function()
            while moving == m do
                if not CookObjects[uid] then break end -- collected / removed mid-drag
                -- Snap onto the nearest OPEN slot (any other rack), exactly like placing a
                -- fresh item — release there re-slots it. Otherwise trail the cursor; a
                -- release off any slot just snaps it back to where it was.
                local best = nearestOpenSlot(method)
                if best then
                    m.hit, m.targetDoor, m.targetSlot = true, best.door, best.slot
                    moveSlotStackTo(uid, best.w.x, best.w.y, best.w.z)
                else
                    m.hit, m.targetDoor, m.targetSlot = false, nil, nil
                    local hit, coords = CursorToWorld()
                    if hit and coords then moveSlotStackTo(uid, coords.x, coords.y, coords.z) end
                end
                Wait(0)
            end
        end)
        return cb({ ok = true })
    end
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
    -- Slot item: dropped onto another open rack -> move it there (cook progress carries
    -- over); dropped anywhere else (and not collected on the bar) -> snap back to its seat.
    if m.slot then
        if not (d and d.cancel) and m.hit and m.targetSlot and CookObjects[m.uid] then
            local res = lib.callback.await("pickle_restaurants:cooking:reslot", false, {
                uid = m.uid, door = m.targetDoor, slot = m.targetSlot,
            })
            if res and res.ok then return cb(res) end          -- server re-seated it at the new rack
            if res and res.error then ShowNotification(res.error) end
        end
        if CookObjects[m.uid] then seatSlotItem(m.uid) end      -- rejected / no target / cancelled
        return cb({ ok = false })
    end
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
    elseif res and res.error then
        ShowNotification(res.error)
    end
    cb(res or { ok = false })
end)

-- take a Cooked Items tray entry out into the real inventory
RegisterNUICallback("cooking:trayToInventory", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:cooking:trayToInventory", false, {
        prop_id = currentCookProp and currentCookProp.id, item = d.item, cheese = d.cheese, count = d.count, sig = d.sig,
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
    if prepDrag then deleteDrag(prepDrag); prepDrag = nil end
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
        local stack = (type(d.stack) == "table" and #d.stack > 1) and d.stack or nil
        if not d.model and not stack then return cb({ ok = false }) end
        -- cheese only rides a two-faced patty, matching the stovetop. A product with
        -- a build stack (cooked pizza) renders as its whole layer tower; `sig` keeps
        -- the reservation pinned to that exact build variation.
        specs[1] = { item = d.item, model = d.model, source = d.source, half = d.half,
                     dual = dual, cheese = cheeseVal, sig = d.sig,
                     stack = stack, state = d.state,
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
    setOutline(nil); setTrayOutline(nil)
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
            item = p.item, cheese = p.cheese, half = p.half, sig = p.sig,
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
        -- dropped onto a serving tray: the new pile anchors to it at this offset
        if drag.targetTid and PrepTrays[drag.targetTid] then
            stack.tid, stack.dx, stack.dy = drag.targetTid, drag.coords.dx, drag.coords.dy
        end
        PrepStacks[prepSid] = stack
    end
    relayout(stack)
    RefreshTray(); RefreshBar()
    cb(res or { ok = false })
end)

-- Spawn one prep part per decompose spec (a bun layer picks its bottom/top prop, as
-- when built). Reservation ids ride along on committed specs and are nil on a preview.
-- A meal layer's (dx, dy) tray offset rides onto the part for pile grouping.
local function partsFromDecomposeSpecs(specs)
    local parts = {}
    for _, spec in ipairs(specs or {}) do
        local model = spec.model
        if spec.item == "bun" and spec.half and BUN[spec.half] then model = BUN[spec.half] end
        local p = makePart({ item = spec.item, model = model, source = spec.source,
                             dual = spec.dual, cheese = spec.cheese, cheeseModel = spec.cheeseModel, half = spec.half,
                             sig = spec.sig, stack = spec.stack, state = spec.state })
        if p then p.id = spec.id; p.dx, p.dy = spec.dx, spec.dy; parts[#parts + 1] = p end
    end
    return parts
end

-- Begin a decompose drag: preview the WHOLE component stack (peeked read-only, so
-- nothing is consumed yet) following the cursor — not just the product's single prop.
-- A MEAL previews as its full tray: tray + paper + every pile at its exact offset.
RegisterNUICallback("cooking:beginPrepDecompose", function(d, cb)
    cancelPlace(); cancelMove()
    if prepDrag then deleteDrag(prepDrag); prepDrag = nil end
    if not currentCookProp then return cb({ ok = false }) end
    local res = lib.callback.await("pickle_restaurants:cooking:prepDecomposePeek", false, {
        prop_id = currentCookProp.id, item = d and d.item, sig = d and d.sig, source = d and d.source,
    })
    if not (res and res.ok) then return cb({ ok = false }) end
    local parts = partsFromDecomposeSpecs(res.parts)
    if #parts == 0 then return cb({ ok = false }) end
    if res.meal then
        local base = currentCookProp
        local ents = spawnTrayEnts(base.x, base.y, base.z)
        if not ents then deleteParts(parts); return cb({ ok = false }) end
        prepDrag = { tray = ents, piles = groupPiles(parts), parts = parts, hit = false, decompose = true, meal = true }
    else
        prepDrag = { parts = parts, hit = false, decompose = true }
    end
    runDragThread(prepDrag)
    cb({ ok = true })
end)

-- Release a decompose drag: the previewed stack is dropped, the server un-makes the
-- product (consume + refund + reserve), and we spawn the committed stack in place.
RegisterNUICallback("cooking:endPrepDecompose", function(d, cb)
    local drag = prepDrag; prepDrag = nil
    setOutline(nil); setTrayOutline(nil)
    if not drag then return cb({ ok = false }) end
    -- capture the drop target, then drop the (non-reserved) preview stack
    local targetSid, targetTid, coords, hit = drag.targetSid, drag.targetTid, drag.coords, drag.hit
    deleteDrag(drag)
    if (d and d.cancel) or not hit then return cb({ ok = false }) end

    local res = lib.callback.await("pickle_restaurants:cooking:prepDecompose", false, {
        prop_id = currentCookProp and currentCookProp.id, item = d and d.item, sig = d and d.sig, source = d and d.source,
    })
    if not (res and res.ok) then
        if res and res.error then ShowNotification(res.error) end
        return cb(res or { ok = false })
    end

    local parts = partsFromDecomposeSpecs(res.parts)
    if #parts == 0 then RefreshTray(); RefreshBar(); return cb({ ok = false }) end

    -- A meal sets down as its whole tray: tray + paper recreated at the drop point,
    -- one editable pile per recorded offset — exactly the arrangement it was made as.
    if res.meal then
        local ents = spawnTrayEnts(coords.x, coords.y, coords.z)
        if ents then
            commitTrayGroup(coords.x, coords.y, coords.z, ents, groupPiles(parts))
            RefreshTray(); RefreshBar()
            return cb(res)
        end
        -- tray prop failed to spawn: fall through and keep the parts as a plain stack
    end

    local stack = targetSid and PrepStacks[targetSid]
    if stack then
        for _, p in ipairs(parts) do stack.parts[#stack.parts + 1] = p end
    else
        prepSid = prepSid + 1
        stack = { x = coords.x, y = coords.y, z0 = coords.z, parts = parts }
        if targetTid and PrepTrays[targetTid] then
            stack.tid, stack.dx, stack.dy = targetTid, coords.dx, coords.dy
        end
        PrepStacks[prepSid] = stack
    end
    relayout(stack)
    RefreshTray(); RefreshBar()
    cb(res or { ok = true })
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
    -- home keeps the tray anchor too, so a fizzled drag re-homes ONTO the tray
    local home = { x = stack.x, y = stack.y, z0 = stack.z0, tid = stack.tid, dx = stack.dx, dy = stack.dy }
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
    setOutline(nil); setTrayOutline(nil)
    if not drag then return cb({ ok = false }) end
    -- A carried tray (grab-drag): dropped on the bar the arrangement becomes ONE
    -- meal; dropped in the world the tray moves there (piles keep their offsets);
    -- anywhere else it snaps back home.
    if drag.tray then
        if d and d.cancel then
            local items = {}
            for _, pile in ipairs(drag.piles or {}) do
                local pids = {}
                for _, p in ipairs(pile.parts) do if p.id then pids[#pids + 1] = p.id end end
                if #pids > 0 then items[#items + 1] = { ids = pids, dx = pile.dx, dy = pile.dy } end
            end
            if #items == 0 then -- empty tray dropped on the bar: just put it away
                deleteDrag(drag)
                return cb({ ok = true })
            end
            local res = lib.callback.await("pickle_restaurants:cooking:prepMakeMeal", false, { items = items })
            if res and res.ok then
                deleteDrag(drag)
                if res.label then ShowNotification("Made " .. res.label) end
                RefreshTray(); RefreshBar()
                return cb(res)
            end
            if res and res.error then ShowNotification(res.error) end
            -- fall through: put the tray (and everything on it) back down
        end
        local c = (drag.hit and drag.coords) or drag.home
        commitTrayGroup(c.x, c.y, c.z, drag.tray, drag.piles)
        return cb({ ok = true })
    end
    if d and d.cancel then
        -- A WHOLE stack dragged to the hotbar (grab emptied its source → no fromSid)
        -- is saved as its closest product; a grabbed part/sub-stack, or a stack that
        -- forms no product, just returns its parts to holdings.
        if not drag.fromSid then
            local ids = {}
            for _, p in ipairs(drag.parts) do if p.id then ids[#ids + 1] = p.id end end
            if #ids > 0 then
                local res = lib.callback.await("pickle_restaurants:cooking:prepSaveStack", false, { ids = ids })
                if res and res.ok then
                    deleteParts(drag.parts)
                    if res.label then ShowNotification("Saved " .. res.label) end
                    RefreshTray(); RefreshBar()
                    return cb(res)
                end
            end
        end
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
        -- dropped onto a serving tray: the pile anchors to it at this offset
        if drag.targetTid and PrepTrays[drag.targetTid] then
            stack.tid, stack.dx, stack.dy = drag.targetTid, drag.coords.dx, drag.coords.dy
        end
        PrepStacks[prepSid] = stack
    elseif drag.fromSid and PrepStacks[drag.fromSid] then -- snap back onto the source
        stack = PrepStacks[drag.fromSid]
        for _, p in ipairs(drag.parts) do stack.parts[#stack.parts + 1] = p end
    else -- source is gone: recreate the stack where it came from
        prepSid = prepSid + 1
        stack = { x = drag.home.x, y = drag.home.y, z0 = drag.home.z0, parts = drag.parts }
        -- it came off a tray: keep it anchored there if the tray still exists
        if drag.home.tid and PrepTrays[drag.home.tid] then
            stack.tid, stack.dx, stack.dy = drag.home.tid, drag.home.dx, drag.home.dy
        end
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
        prop_id = currentCookProp and currentCookProp.id, source = d.source, item = d.item, cheese = d.cheese, sig = d.sig,
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
        local tid, dx, dy = stack.tid, stack.dx, stack.dy
        removePrepStack(sid)
        -- A pile made into a product while sitting ON a serving tray stays on the
        -- tray: reserve the freshly made product (res.sig addresses it) and seat
        -- its prop at the same spot, instead of it vanishing into the holdings.
        if tid and PrepTrays[tid] and res.spec then
            local add = lib.callback.await("pickle_restaurants:cooking:prepAdd", false, {
                prop_id = currentCookProp and currentCookProp.id, source = res.spec.source,
                item = res.spec.item, cheese = res.spec.cheese or 0, sig = res.spec.sig,
            })
            if add and add.ok then
                local spec = res.spec; spec.id = add.id
                local parts = partsFromDecomposeSpecs({ spec })
                if #parts > 0 then
                    local t = PrepTrays[tid]
                    prepSid = prepSid + 1
                    local s = { x = t.x + (dx or 0.0), y = t.y + (dy or 0.0), z0 = t.z + trayFoodDz(),
                                tid = tid, dx = dx, dy = dy, parts = parts }
                    PrepStacks[prepSid] = s
                    relayout(s)
                end
            end
        end
        if res.label then ShowNotification("Made " .. res.label) end
        RefreshTray(); RefreshBar()
    elseif res and res.error then
        ShowNotification(res.error)
    end
    cb(res or { ok = false })
end)

-- ─── serving tray (kitchen_prep) ─────────────────────────────────────────────

-- Drag a fresh serving tray out of the bar: tray + paper preview following the
-- cursor; drop on the table places it, ready to arrange food on.
RegisterNUICallback("cooking:beginTrayPlace", function(_, cb)
    cancelPlace(); cancelMove()
    if prepDrag then deleteDrag(prepDrag); prepDrag = nil end
    setOutline(nil); setTrayOutline(nil)
    local base = currentCookProp
    if not base or base.prop_type ~= "kitchen_prep" then return cb({ ok = false }) end
    local ents = spawnTrayEnts(base.x, base.y, base.z)
    if not ents then return cb({ ok = false }) end
    prepDrag = { tray = ents, parts = {}, piles = {}, hit = false }
    runDragThread(prepDrag)
    cb({ ok = true })
end)

RegisterNUICallback("cooking:endTrayPlace", function(d, cb)
    local drag = prepDrag; prepDrag = nil
    setOutline(nil); setTrayOutline(nil)
    if not drag then return cb({ ok = false }) end
    if (d and d.cancel) or not drag.hit or not drag.coords then
        deleteDrag(drag)
        return cb({ ok = false })
    end
    commitTrayGroup(drag.coords.x, drag.coords.y, drag.coords.z, drag.tray, nil)
    cb({ ok = true })
end)

-- Grab a placed tray: lift it AND everything arranged on it as one carried group.
-- Released via cooking:prepDrop — back on the table it moves; on the bar the whole
-- arrangement becomes a meal.
RegisterNUICallback("cooking:trayGrab", function(d, cb)
    cancelPlace(); cancelMove()
    if prepDrag then return cb({ ok = false }) end
    local tid = tonumber(d and d.tid)
    local t = tid and PrepTrays[tid]
    if not t then return cb({ ok = false }) end
    setOutline(nil); setTrayOutline(nil); trayHovered = nil
    local piles, parts = {}, {}
    for sid, s in pairs(PrepStacks) do
        if s.tid == tid then
            piles[#piles + 1] = { dx = s.dx or 0.0, dy = s.dy or 0.0, parts = s.parts }
            for _, p in ipairs(s.parts) do parts[#parts + 1] = p end
            PrepStacks[sid] = nil
        end
    end
    -- deterministic pile order so identical arrangements share a meal signature
    table.sort(piles, function(a, b)
        if math.abs(a.dx - b.dx) > 0.0005 then return a.dx < b.dx end
        return a.dy < b.dy
    end)
    PrepTrays[tid] = nil
    prepDrag = { tray = t.ents, piles = piles, parts = parts,
                 home = { x = t.x, y = t.y, z = t.z }, hit = false }
    runDragThread(prepDrag)
    cb({ ok = true })
end)

-- The tray tooltip's Make Meal: everything arranged on tray `tid` becomes one
-- meal item, exact layout preserved.
RegisterNUICallback("cooking:prepMakeMeal", function(d, cb)
    local tid = tonumber(d and d.tid)
    if not tid or not PrepTrays[tid] then return cb({ ok = false }) end
    local res = makeMealFromTray(tid, false)
    if not res then
        ShowNotification("Nothing on the tray.")
        return cb({ ok = false })
    end
    if res.ok then RefreshTray(); RefreshBar() end
    cb(res or { ok = false })
end)

-- switch the scripted camera between the cooktop and either oven door
RegisterNUICallback("cooking:setView", function(d, cb)
    if currentCookProp and SetStationView then SetStationView(currentCookProp, d.view) end
    cb({ ok = true })
end)

-- lower / raise the fryer basket (starts / pauses frying for its items)
RegisterNUICallback("cooking:fryerDip", function(d, cb)
    if not currentCookProp or currentCookProp.prop_type ~= "fryer" then return cb({ ok = false }) end
    local res = lib.callback.await("pickle_restaurants:cooking:fryerDip", false, {
        prop_id = currentCookProp.id, lowered = d and d.lowered and true or false,
    })
    if res and res.error then ShowNotification(res.error) end
    cb(res or { ok = false })
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
    SetEntityRotation(ent, 0.0, 0.0, curYaw(), 2, true) -- face the station while dragging
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

-- ─── finish tools (frosting …) ───────────────────────────────────────────────
-- A finish tool (synced `Finishes` config) is dragged out of the bar as its real
-- tube prop and RUBBED over a placed prep part: coverage accrues with the tool's
-- travel over the target, the flavored result prop fades in (alpha 0→255), and at
-- full coverage the server consumes target + 1 tool item and the finished product
-- is seated exactly where the target sat (a cake's container + batter sheet are
-- deleted; a doughnut keeps its topping overlay).

local FINISH = {
    tool_lift = 0.01, -- extra clearance above the cursor's surface hit (the tube's
                      -- mesh bottom is seated at the hit point via its measured
                      -- origin offset, so this is just a hair of breathing room)
    max_step  = 0.15, -- per-frame travel clamp (m) so a camera jump can't insta-fill
}

-- How far a model's mesh bottom sits below its origin (the serving tray's
-- physics-margin correction) — seats the tube ON the ray hit instead of floating.
local function meshBottomLift(model)
    local mn = GetModelDimensions(EnsureModel(model))
    return mn and math.max(-(mn.z + STACK_PHYS_MARGIN), 0.0) or 0.0
end

-- The (target, flavor) config a hovered part matches for this tool + chosen
-- flavor. nil when the part isn't a valid target (raw/burnt items are never
-- configured targets) or the flavor doesn't apply to it (glazed on a cake).
local function finishTargetFor(cfg, item, flavorId)
    for _, t in ipairs(cfg.targets or {}) do
        if t.item == item then
            for _, fl in ipairs(t.flavors or {}) do
                if fl.id == flavorId then return t, fl end
            end
            return nil
        end
    end
end

-- World z a stack part's BASE sits at (z0 + every height below it) — where a
-- replace-mode result spawns; an overlay-mode one goes on the part's top.
local function partBaseZ(stack, idx)
    local z = stack.z0
    for i = 1, idx - 1 do z = z + (stack.parts[i].height or 0.0) end
    return z
end

-- Swap a finished part in place: the old part's props (container + batter sheet
-- for a cake) are deleted and the freshly made output is re-reserved (res.sig
-- addresses it) and seated at the same spot in its stack — mirrors how
-- prepMakeStack re-seats a product made on a serving tray.
local function replacePartWithFinished(sid, idx, res)
    local stack = PrepStacks[sid]
    if not stack or not stack.parts[idx] then RefreshTray(); RefreshBar(); return end
    deleteParts({ stack.parts[idx] })
    table.remove(stack.parts, idx)
    if res.spec then
        local add = lib.callback.await("pickle_restaurants:cooking:prepAdd", false, {
            prop_id = currentCookProp and currentCookProp.id, source = res.spec.source,
            item = res.spec.item, cheese = res.spec.cheese or 0, sig = res.spec.sig,
        })
        if add and add.ok then
            local spec = res.spec; spec.id = add.id
            local parts = partsFromDecomposeSpecs({ spec })
            if #parts > 0 then table.insert(stack.parts, idx, parts[1]) end
        end
    end
    -- fizzled re-reserve: the output is safely in the tray either way
    if #stack.parts == 0 then PrepStacks[sid] = nil else relayout(stack) end
end

-- Full coverage reached: commit with the server (it re-validates and consumes),
-- tear the drag down, and seat the finished prop in place of the target.
local function applyFinishAt(f, sid, idx, part, _, _)
    local res = lib.callback.await("pickle_restaurants:cooking:applyFinish", false, {
        prop_id = currentCookProp and currentCookProp.id,
        id = part.id, tool = f.cfg.tool, flavor = f.flavor,
    })
    if finishing == f then finishing = nil end
    SafeDeleteEntity(f.tube)
    for _, g in pairs(f.ghosts or {}) do SafeDeleteEntity(g.ent) end
    setOutline(nil)
    if res and res.ok then
        replacePartWithFinished(sid, idx, res)
        if res.label then ShowNotification("Made " .. res.label) end
        RefreshTray(); RefreshBar()
    elseif res and res.error then
        ShowNotification(res.error)
    end
    SendNUIMessage({ action = "cookingFinishDone" })
end

-- begin dragging a finish tool: spawn the real tube prop following the cursor;
-- coverage/ghost state lives per hovered part for the drag's lifetime.
RegisterNUICallback("cooking:beginFinish", function(d, cb)
    cancelPlace(); cancelMove(); cancelFinish()
    if prepDrag then deleteDrag(prepDrag); prepDrag = nil end
    local base = currentCookProp
    if not base or base.prop_type ~= "kitchen_prep" then return cb({ ok = false }) end
    local cfg
    for _, fc in ipairs(Finishes or {}) do
        if fc.tool == (d and d.item) then cfg = fc break end
    end
    if not cfg or not cfg.tool_model or not d.flavor then return cb({ ok = false }) end
    local tube = SpawnProp(cfg.tool_model, base.x, base.y, base.z)
    if not tube then return cb({ ok = false }) end
    SetEntityRotation(tube, 0.0, 0.0, curYaw(), 2, true) -- face the station
    -- seat the tube's MESH bottom at the cursor's surface hit (its origin isn't
    -- reliably at the mesh bottom, so a flat lift floated it too high)
    local tubeLift = meshBottomLift(cfg.tool_model) + FINISH.tool_lift
    local f = { tube = tube, cfg = cfg, flavor = d.flavor, ghosts = {}, coverage = {}, applying = false }
    finishing = f
    CreateThread(function()
        while finishing == f do
            local hit, coords = CursorToWorld()
            local sid, idx, part = pickPart(nil)
            if hit and coords then
                -- Food props have collision off, so the cursor ray passes through
                -- them and hits the TABLE underneath — seat the tube on top of the
                -- pile under the cursor (its summed model heights), not the ray hit,
                -- so it rides over the cake instead of intersecting it.
                local z = coords.z
                local stack = sid and PrepStacks[sid]
                if stack then z = math.max(z, stackTopZ(stack)) end
                SetEntityCoordsNoOffset(tube, coords.x, coords.y, z + tubeLift, false, false, false)
            end
            local target, flavor
            if part and part.id and hit and coords then
                target, flavor = finishTargetFor(cfg, part.item, f.flavor)
            end
            if target then
                setOutline(sid, 80, 200, 120)
                -- coverage accrues with the tool's travel while over the target
                if f.last then
                    local dx, dy = coords.x - f.last.x, coords.y - f.last.y
                    f.coverage[part.pid] = (f.coverage[part.pid] or 0.0)
                        + math.min(math.sqrt(dx * dx + dy * dy), FINISH.max_step)
                end
                -- the flavored result fades in over the target as coverage builds
                local g = f.ghosts[part.pid]
                if not g and flavor.model then
                    local stack = PrepStacks[sid]
                    local gz = partBaseZ(stack, idx)
                    if (target.mode or "replace") == "overlay" then gz = gz + (part.height or 0.0) end
                    local ent = SpawnProp(flavor.model, stack.x, stack.y, gz)
                    if ent then
                        SetEntityCoordsNoOffset(ent, stack.x, stack.y, gz, false, false, false)
                        SetEntityRotation(ent, 0.0, 0.0, curYaw(), 2, true) -- match the target's facing
                        SetEntityAlpha(ent, 0, false)
                        g = { ent = ent }
                        f.ghosts[part.pid] = g
                    end
                end
                local progress = math.min((f.coverage[part.pid] or 0.0) / (tonumber(cfg.rub_dist) or 1.2), 1.0)
                if g and g.ent and DoesEntityExist(g.ent) then
                    SetEntityAlpha(g.ent, math.floor(progress * 255 + 0.5), false)
                end
                if progress >= 1.0 and not f.applying then
                    f.applying = true
                    applyFinishAt(f, sid, idx, part, target, flavor)
                    break
                end
            else
                setOutline(nil)
            end
            f.last = (hit and coords) and { x = coords.x, y = coords.y } or nil
            Wait(0)
        end
        setOutline(nil)
    end)
    cb({ ok = true })
end)

-- release a finish drag before full coverage: everything resets, nothing consumed
RegisterNUICallback("cooking:endFinish", function(_, cb)
    cancelFinish()
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
    elseif currentCookProp and currentCookProp.prop_type == "fryer" then
        -- clicking a basket toggles THAT basket, same convention as oven doors
        local slot = hoveredBasketSlot(currentCookProp.id)
        if slot then
            local res = lib.callback.await("pickle_restaurants:cooking:fryerDip", false, {
                prop_id = currentCookProp.id, slot = slot,
                lowered = not slotDown(currentCookProp.id, slot),
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
    for uid in pairs(CookSlotStack) do clearSlotStack(uid) end
    for _, ent in pairs(CookObjects) do
        SafeDeleteEntity(ent)
    end
    -- prep build parts + any in-flight placement/topping/finish previews
    clearPrepStacks()
    deletePreview(placing); placing = nil
    cancelFinish()
end)
