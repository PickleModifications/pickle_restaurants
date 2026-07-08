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
-- The PIZZA BOX: the serving tray's sibling (kind "box") — a base + hinged-lid
-- pair placed on the prep table. Clicking the lid swings it open/closed (a
-- smooth hinged rotation, never a pop); only a pizza goes inside (the carried
-- pile's BOTTOM layer must be a pizza crust, any cook state), ONE per box, and
-- boxing it up makes the same meal item a serving tray does — flagged so it
-- sets back down as its box.
local BOXP = {
    base_model = "pickle_pizza_box_01",
    lid_model  = "pickle_pizza_box_02",
    -- the pizza crust at every cook state (raw/cooked/burnt) — what the box accepts
    dough_models = { "pickle_pizza_dough_01", "pickle_pizza_dough_02", "pickle_pizza_dough_03" },
    -- Where the pizza SEATS inside the box: height of the pile's base above the
    -- surface the box sits on. This is THE pizza-in-box offset — raise it if the
    -- pizza clips the bed, lower it (negative allowed) if it floats/rides the
    -- rim. Applies to drops, moves, set-down meals and previews alike (all food
    -- z's come through trayFoodDz). TUNE IN-GAME.
    food_dz   = 0.0,
    rim_inset = 0.06,  -- shrink the droppable area vs the model bounds
    pick_pad  = 0.03,  -- extra grab margin (m) around the box's footprint
    pick_dz   = 0.4,   -- max height difference between the cursor's surface hit and the box
    -- Lid: the lid model's ORIGIN is authored on its hinge edge, so it seats a
    -- fixed step forward of the base's origin (lid_fwd, set ONCE at placement)
    -- and the whole open/close swing is ROTATION only — the box's heading plus
    -- the opening pitch. TUNE IN-GAME.
    open_deg  = 100.0, -- how far the lid swings open (pitch; boxLidSwing negates it)
    open_ms   = 350,   -- open/close swing duration
    lid_fwd   = 0.1535,   -- lid origin's forward offset from the base's origin (m)
}
local PrepTrays = {}    -- [tid] = { x, y, z, kind, ents, open?, openT?, animSeq? }
                        -- kind "tray": ents = { trayEnt, paperEnt }; kind "box":
                        -- ents = { baseEnt, lidEnt } + lid open state/progress
local prepTid = 0       -- monotonic tray id
local trayHovered = nil -- tid under the cursor (grab / make-meal tooltip / lid click)

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

-- Manual per-model stacking corrections, applied on top of the measured model
-- heights — modelHeight/stackLayerHeight are ALWAYS the baseline; add an entry
-- here only when a specific prop needs a nudge. TUNE IN-GAME.
--   sink = shift THIS layer's seat by this much (negative sinks it into the layer
--          below); everything stacked on top of it follows it down/up. Clamped so
--          a layer can never sink to (or below) the seat of the one under it —
--          a flat topping only rises STACK_MIN_GAP, so keep sinks smaller than
--          that or the clamp eats the difference.
--   rise = REPLACE the model's measured layer height (how far the NEXT layer sits
--          above this one) instead of the computed value.
local STACK_TWEAKS = {
    -- the shredded-cheese sheet reads a touch high over the sauce on a pizza
    ["pickle_pizza_sauce_01"] = { sink = -0.004 },
    ["pickle_pizza_cheese_01"] = { sink = -0.004 },
    ["pickle_pizza_cheese_02"] = { sink = -0.004 },
}
local function stackSink(model)
    local t = model and STACK_TWEAKS[model]
    return (t and t.sink) or 0.0
end

local function stackLayerHeight(model)
    local t = model and STACK_TWEAKS[model]
    if t and t.rise then return t.rise end
    -- The side-serving container (fries box) holds its food at its OWN base — both
    -- are bottom-origin, so the serving sits INSIDE the box, not stacked on top of
    -- it. Zero stacking height means the next layer keeps the same base Z.
    if SideContainerModel and SideContainerModel ~= "" and model == SideContainerModel then return 0.03 end
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
    local isContainer = SideContainerModel and SideContainerModel ~= "" and model == SideContainerModel
    if not isContainer then
        for _, r in pairs(RecipesByInput or {}) do
            if r.container_model == model then isContainer = true break end
        end
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

-- Is this model one of a dual-sided (beef patty) recipe's face props? Matched by
-- the raw / cooked / burnt model of any dual_sided recipe.
local function dualModelRecipe(model)
    if type(model) ~= "string" then return nil end
    for _, r in pairs(RecipesByInput or {}) do
        if (r.dual_sided == true or tonumber(r.dual_sided) == 1)
            and (r.raw_model == model or r.cooked_model == model or r.burnt_model == model) then
            return r
        end
    end
end

-- Expand a bottom-to-top MODEL list into the props that actually render it, so a
-- dual-sided patty ANYWHERE in a build stack (a pizza topping, a bake) shows the
-- SAME full two-faced patty as one on the grill instead of a lone half. A normal
-- model stays one prop; a patty model becomes TWO stacked faces (bottom/grill dome
-- then the visible dome a hair above, matching orientPair's unflipped patty).
-- Returns three parallel arrays: models, incremental heights (rise to the next
-- layer), and per-prop roll in degrees (0 for everything that isn't a patty face).
-- `state` swaps toppings to their cooked/burnt look, same as before.
local function expandStackLayers(models, state)
    local mdls, heights, rolls = {}, {}, {}
    for _, m0 in ipairs(models or {}) do
        local m = cookedVariant(m0, state)
        -- manual seat correction (STACK_TWEAKS.sink): shift this layer — and
        -- everything riding on it — by folding the offset into the rise below
        -- it, clamped so the layer never sinks to/below the previous layer's
        -- seat (a hair of rise always survives — it can't vanish underneath).
        -- The tower's base layer has nothing below it, so its sink is moot.
        local s = stackSink(m0)
        if s == 0.0 then s = stackSink(m) end
        if s ~= 0.0 and #heights > 0 then heights[#heights] = math.max(heights[#heights] + s, 0.001) end
        if dualModelRecipe(m0) then
            mdls[#mdls + 1] = m; heights[#heights + 1] = DUAL.face_gap;       rolls[#rolls + 1] = DUAL.bottom_roll
            mdls[#mdls + 1] = m; heights[#heights + 1] = stackLayerHeight(m);  rolls[#rolls + 1] = DUAL.top_roll
        else
            mdls[#mdls + 1] = m; heights[#heights + 1] = stackLayerHeight(m);  rolls[#rolls + 1] = 0.0
        end
    end
    return mdls, heights, rolls
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
    -- a branded packaging prop now EXISTS — re-assert its brand texture replacement so
    -- it actually takes (the replacement is set at startup before any prop exists)
    if ReassertBrandFor then ReassertBrandFor(model) end
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

-- Soda fountain taps, LOCAL to pickle_soda_fountain_01 (x = right, y = front,
-- z = up): SEVEN nozzles left-to-right. The MIDDLE one (ice_slot) dispenses ice,
-- with three drink taps to each side. The tap X positions are COMPUTED, not
-- hard-listed: `ice_gap` is the central ice area's half-width (centre → the
-- innermost drink tap on either side) and `gap` is the spacing between adjacent
-- drink taps, so the three left taps sit at -ice_gap, -ice_gap-gap, -ice_gap-2·gap
-- and the three right ones mirror them. A cup seats on the drip tray at cup_z;
-- the clickable nozzle / push-button hover point sits tap_dz above that. The
-- DISPENSE mouth — where ice/liquid visually leaves the machine — is a separate
-- point from the click target: pour_dy/pour_dz offset it from the cup seat so
-- the render origin can be tuned without moving where clicks land. TUNE
-- IN-GAME.
local SODA = {
    slots    = 7,
    ice_slot = 4,
    ice_gap  = 0.078, -- centre → innermost drink tap (= the ice area's half-width)
    gap      = 0.0665, -- spacing between adjacent drink taps
    cup_y    = -0.155,
    cup_z    = 1.121,
    tap_dz   = 0.231, -- clickable nozzle point above the cup seat
    tap_click_r = 0.035, -- click radius (normalised screen) around the push button ONLY —
                         -- deliberately much tighter than SLOT_SNAP_R so a click registers
                         -- on the tap/ice button, not anywhere in the cup's vertical column
    pour_dy  = 0.018,   -- dispense mouth Y offset from the cup seat (render origin only)
    pour_dz  = 0.22,  -- dispense mouth height above the cup seat (render origin only)
}

-- Local X of a tap slot: 0 at the ice nozzle, else stepped out from the ice
-- area's edge by `gap` per tap (negative = left of centre, positive = right).
-- nil for an out-of-range slot (keeps the seat/world guards working).
local function sodaSlotX(slot)
    if type(slot) ~= "number" or slot < 1 or slot > SODA.slots then return nil end
    if slot == SODA.ice_slot then return 0.0 end
    local step = math.abs(slot - SODA.ice_slot) -- 1 = nearest the ice, up to 3
    local mag  = SODA.ice_gap + (step - 1) * SODA.gap
    return (slot < SODA.ice_slot) and -mag or mag
end

-- The drink a tap pours (nil for the ice nozzle / a tap with no valid drink).
-- Each synced drink carries `tap` — its RAW config position, stamped by
-- BuildSyncPayload — so tap positions stay stable even when some flavors are
-- filtered out (missing items) and mirror the server's flavorForSlot exactly.
local function sodaFlavorForSlot(slot)
    if slot == SODA.ice_slot then return nil end
    local idx = (slot < SODA.ice_slot) and slot or (slot - 1)
    for _, d in ipairs(Drinks or {}) do
        if d.tap == idx then return d end
    end
end

-- A tap slot is live when it's the ice nozzle or has a drink on it.
local function sodaSlotLive(slot)
    return slot == SODA.ice_slot or sodaFlavorForSlot(slot) ~= nil
end

-- World position of a tap's cup seat (drip tray), or of its clickable nozzle
-- when `tap` is set.
local function sodaSlotWorld(propId, slot, tap)
    local station = GetStationEntity and GetStationEntity(propId)
    local x = sodaSlotX(slot)
    if not station or not DoesEntityExist(station) or not x then return nil end
    return GetOffsetFromEntityInWorldCoords(station, x, SODA.cup_y, SODA.cup_z + (tap and SODA.tap_dz or 0.0))
end

-- World position of a tap's DISPENSE mouth — where ice/liquid visually leaves
-- the machine. Deliberately separate from the clickable nozzle point (tap_dz):
-- SODA.pour_dy/pour_dz move the render origin without moving the click target.
local function sodaDispenseWorld(propId, slot)
    local station = GetStationEntity and GetStationEntity(propId)
    local x = sodaSlotX(slot)
    if not station or not DoesEntityExist(station) or not x then return nil end
    return GetOffsetFromEntityInWorldCoords(station, x, SODA.cup_y + SODA.pour_dy, SODA.cup_z + SODA.pour_dz)
end

-- Loose ice cubes shown at the cup's rim while it has ice (the vanilla bar-cube
-- props — visual only, like the fryer baskets / cheese slices). A small cluster
-- of the three cube variants at per-cube offsets/yaws so it reads as scooped
-- ice, not a stacked tower; each dz is relative to the cup's measured TOP and
-- slightly negative so the cubes sit sunk into the rim. Hidden again once the
-- lid goes on (the ice is inside). TUNE IN-GAME.
local ICE = {
    cubes = {
        { model = "prop_ice_cube_01", dx =  0.016, dy =  0.010, dz = -0.020, yaw = 0.0 },
        { model = "prop_ice_cube_02", dx = -0.018, dy = -0.008, dz = -0.025, yaw = 55.0 },
        { model = "prop_ice_cube_03", dx =  0.000, dy = -0.017, dz = -0.012, yaw = 110.0 },
    },
}
local SodaIce = {} -- [uid] = { ents = { {ent, c}, … }, topZ } rim cubes on a cup

-- Seat a cup's ice cubes around its rim: (x, y, z) is the cup's seat point,
-- each cube's local (dx, dy) rotated by the station heading, dz off the cup top.
local function seatSodaIce(uid, x, y, z, headingZ)
    local rec = SodaIce[uid]; if not rec then return end
    local h = math.rad(headingZ or 0.0)
    local cosH, sinH = math.cos(h), math.sin(h)
    for _, it in ipairs(rec.ents) do
        local e, c = it.ent, it.c
        -- a cube still mid-fall owns its own position until it lands
        if e and DoesEntityExist(e) and not it.falling then
            SetEntityCoordsNoOffset(e,
                x + c.dx * cosH - c.dy * sinH,
                y + c.dx * sinH + c.dy * cosH,
                z + rec.topZ + c.dz, false, false, false)
            SetEntityRotation(e, 0.0, 0.0, (headingZ or 0.0) + (c.yaw or 0.0), 2, true)
        end
    end
end

local function removeSodaIce(uid)
    local rec = SodaIce[uid]; if not rec then return end
    for _, it in ipairs(rec.ents) do SafeDeleteEntity(it.ent) end
    SodaIce[uid] = nil
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
            if SeatOvenSlotStack then SeatOvenSlotStack(s.propId, s.door, s.slot, st.ents, st.heights, st.baseDz, st.rolls) end
        elseif SeatOvenSlot then SeatOvenSlot(s.propId, s.door, s.slot, ent) end
    else
        local station = GetStationEntity and GetStationEntity(s.propId)
        if not station or not DoesEntityExist(station) then return end
        local o, z
        if s.method == "soda" then -- cup on the fountain's drip tray under its tap
            local x = sodaSlotX(s.slot)
            if not x then return end
            o, z = { x = x, y = SODA.cup_y }, SODA.cup_z
        else
            o = FRYER.slots[s.slot]
            if not o then return end
            z = fryerZ or (slotDown(s.propId, s.slot) and FRYER.lowered_z or FRYER.raised_z)
        end
        local sr = GetEntityRotation(station, 2)
        local function seatAt(e, lift, roll)
            if not (e and DoesEntityExist(e)) then return end
            local pos = GetOffsetFromEntityInWorldCoords(station, o.x, o.y, z + lift)
            SetEntityCoordsNoOffset(e, pos.x, pos.y, pos.z, false, false, false)
            -- add the layer's own roll (a patty face's flip) to the station's roll
            SetEntityRotation(e, sr.x, sr.y + (roll or 0.0), sr.z, 2, true)
        end
        if st then
            local lift = st.baseDz or 0.0
            for i, e in ipairs(st.ents) do
                seatAt(e, lift, st.rolls and st.rolls[i])
                lift = lift + (st.heights[i] or 0.0)
            end
        else
            seatAt(ent, 0.0)
        end
        -- a cup's rim ice rides with it (soda only; no-op without a cluster)
        if s.method == "soda" and SodaIce[uid] then
            local base = GetOffsetFromEntityInWorldCoords(station, o.x, o.y, z)
            seatSodaIce(uid, base.x, base.y, base.z, sr.z)
        end
    end
end

-- (Re)spawn or remove a cup's rim-ice cubes to match its synced state: visible
-- while the cup has ice and no lid (capped ice is inside, under the lid). The
-- cubes' dz rides on the cup model's measured top so they hug whatever cup prop
-- the drink is configured with.
local function updateSodaIce(uid, hasIce, state)
    if not hasIce or state == "capped" then return removeSodaIce(uid) end
    if SodaIce[uid] then return end -- already rendered; seatSlotItem keeps it placed
    local cup = CookObjects[uid]
    local topZ = (cup and DoesEntityExist(cup)) and modelHeight(GetEntityModel(cup)) or 0.12
    local ents = {}
    for _, c in ipairs(ICE.cubes) do
        local e = SpawnProp(c.model, 0.0, 0.0, 0.0)
        if e then ents[#ents + 1] = { ent = e, c = c } end
    end
    if #ents == 0 then return end
    SodaIce[uid] = { ents = ents, topZ = topZ }
    seatSlotItem(uid) -- seat the fresh cubes at the cup's current spot
end

-- Ice DISPENSING: the cubes drop out of the nozzle one at a time and free-fall
-- (0.5·g·t²) into their rim seats — gravity, not a teleport. Runs while the
-- middle tap pours; by the time the server's ice-complete sync lands the cluster
-- already exists, so updateSodaIce is a no-op and nothing pops.
local ICE_FALL = { g = 9.8, stagger_ms = 240 }
local function dropSodaIce(uid)
    if SodaIce[uid] then return end -- already iced / already falling
    local s = CookSlot[uid]
    if not s or s.method ~= "soda" then return end
    local cup = CookObjects[uid]
    local topZ = (cup and DoesEntityExist(cup)) and modelHeight(GetEntityModel(cup)) or 0.12
    local rec = { ents = {}, topZ = topZ }
    SodaIce[uid] = rec
    CreateThread(function()
        for _, c in ipairs(ICE.cubes) do
            if SodaIce[uid] ~= rec then return end -- cup removed mid-pour
            local nozzle = sodaDispenseWorld(s.propId, s.slot)
            local seat   = sodaSlotWorld(s.propId, s.slot)
            if not nozzle or not seat then break end
            local station = GetStationEntity and GetStationEntity(s.propId)
            local headingZ = (station and DoesEntityExist(station)) and GetEntityRotation(station, 2).z or 0.0
            local h = math.rad(headingZ)
            local cosH, sinH = math.cos(h), math.sin(h)
            local tx = seat.x + c.dx * cosH - c.dy * sinH
            local ty = seat.y + c.dx * sinH + c.dy * cosH
            local tz = seat.z + topZ + c.dz
            local e = SpawnProp(c.model, tx, ty, nozzle.z)
            if e then
                local entry = { ent = e, c = c, falling = true }
                rec.ents[#rec.ents + 1] = entry
                SetEntityRotation(e, 0.0, 0.0, headingZ + (c.yaw or 0.0), 2, true)
                CreateThread(function()
                    local z0 = nozzle.z
                    local started = GetGameTimer()
                    while SodaIce[uid] == rec and DoesEntityExist(e) do
                        local t = (GetGameTimer() - started) / 1000.0
                        local z = z0 - 0.5 * ICE_FALL.g * t * t
                        if z <= tz then break end
                        SetEntityCoordsNoOffset(e, tx, ty, z, false, false, false)
                        Wait(0)
                    end
                    entry.falling = nil
                    if SodaIce[uid] == rec and DoesEntityExist(e) then
                        SetEntityCoordsNoOffset(e, tx, ty, tz, false, false, false) -- settle in the seat
                    end
                end)
            end
            Wait(ICE_FALL.stagger_ms)
        end
    end)
end

-- ─── soda pour stream (marker droplets) ──────────────────────────────────────
-- A colored liquid stream from the dispense mouth (SODA.pour_dy/pour_dz) into
-- the cup while a drink pours, drawn as a column of small sphere markers that
-- free-fall (fake gravity) and recycle, so it reads as a continuous flowing
-- stream — and each drink pours in its OWN color (synced `drinks[].color`,
-- sampled from the fountain's flavor art). While it pours, a liquid SURFACE
-- disc rises inside the cup with the fill's progress, from the cup bottom up to
-- `fill_to` of the cup model's height. Drawn each frame for the fill's
-- duration; the state sync also stops it. Markers, not ptfx, so the color is
-- ours and it never fizzles out early. TUNE IN-GAME.
local POUR = {
    droplets    = 7,     -- droplets visible along the stream at once
    radius      = 0.009, -- droplet marker radius (m)
    pool_r0     = 0.022, -- liquid surface radius at the cup BOTTOM (cups taper: narrow base…)
    pool_r1     = 0.034, -- …lerped up to this radius at the top of the fill (fill_to height)
    fill_to     = 0.9,   -- the surface tops out at this fraction of the cup model's height
    cycle_ms    = 220,   -- time a droplet takes to fall the stream (visual speed)
    min_fall    = 0.03,  -- skip drawing the stream if the mouth-to-surface gap is tiny
}
-- Fallback pour colors by drink OUTPUT for the seeded flavors, so the stream is
-- colored even on configs predating the per-drink `color` field. A synced config
-- color always wins over these.
local POUR_COLORS = {
    water      = { 160, 205, 230 }, -- Pure Aqua: pale icy blue
    lemonade   = { 235, 215, 90 },  -- Lemonade Bliss: yellow
    soda       = { 90, 50, 25 },    -- Classic Cola: dark cola
    diet_cola  = { 120, 80, 55 },   -- Diet Cola: lighter cola
    grape_soda = { 135, 70, 170 },  -- Grape Zap: purple
    coffee     = { 80, 50, 30 },    -- Coffee: brown
}
local SodaPour = {} -- [uid] = token (nil = not pouring)

-- The pour color for a cup's tap: its drink's config `color`, else the seeded
-- fallback by output, else a pale default.
local function pourColor(uid)
    local s = CookSlot[uid]
    local d = s and sodaFlavorForSlot(s.slot)
    local c = d and (d.color or (d.output and POUR_COLORS[d.output]))
    if type(c) == "table" then return c[1] or 200, c[2] or 200, c[3] or 210 end
    return 200, 200, 210
end

local function stopSodaPour(uid)
    SodaPour[uid] = nil -- the running thread checks its token and exits
end

-- The poured liquid itself, PERSISTENT: unlike the pour stream, the surface
-- must outlive the pour — a filled cup keeps its drink visible until the lid
-- caps it or the cup leaves. One shared per-frame loop draws every cup's
-- surface disc at its current level, riding the cup ENTITY (so it follows a
-- reslot drag between taps too).
local SodaFill = {} -- [uid] = { f = 0..1 fill fraction, r, g, b }
local sodaFillLoop = false
-- The cup a dragged lid is currently snapped onto: a lid on the rim — preview
-- or applied — hides the liquid, so the surface is suppressed while snapped and
-- comes back if the drag moves off. Set by the lid drag, read by the loop.
local SodaLidPreviewUid = nil

local function drawSodaFillLoop()
    if sodaFillLoop then return end
    sodaFillLoop = true
    CreateThread(function()
        while next(SodaFill) do
            local ped = GetEntityCoords(PlayerPedId())
            for uid, rec in pairs(SodaFill) do
                local cup = CookObjects[uid]
                if uid ~= SodaLidPreviewUid and cup and DoesEntityExist(cup) then
                    local pos = GetEntityCoords(cup)
                    if #(pos - ped) < 30.0 then
                        local cupH = modelHeight(GetEntityModel(cup)) or 0.12
                        local f = rec.f or 0.0
                        -- the surface widens as it rises, tracking the cup's taper
                        local pr = POUR.pool_r0 + (POUR.pool_r1 - POUR.pool_r0) * f
                        DrawMarker(28, pos.x, pos.y, pos.z + f * cupH * POUR.fill_to,
                            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            pr, pr, pr * 0.35,
                            rec.r, rec.g, rec.b, 200,
                            false, false, 2, false, nil, nil, false)
                    end
                end
            end
            Wait(0)
        end
        sodaFillLoop = false
    end)
end

-- Keep a cup's liquid surface in sync with its synced state: pinned full once
-- "filled", removed when the lid caps it (the drink is hidden inside), when
-- the cup is empty, or when it leaves. "filling" is a no-op — the pour thread
-- drives the level up itself, and an ICE fill on an already-poured cup must
-- not wipe the drink that's in it.
local function updateSodaFill(uid, state)
    if state == "filled" then
        local rec = SodaFill[uid]
        if rec then
            rec.f = 1.0
        else -- synced in already-filled (reconnect / station open): appear full
            local r, g, b = pourColor(uid)
            SodaFill[uid] = { f = 1.0, r = r, g = g, b = b }
        end
        drawSodaFillLoop()
    elseif state ~= "filling" then -- empty / capped / removed
        SodaFill[uid] = nil
    end
end

local function startSodaPour(uid, totalMs, elapsedMs)
    local s = CookSlot[uid]
    if not s or s.method ~= "soda" then return end
    SodaPour[uid] = (SodaPour[uid] or 0) + 1
    local token = SodaPour[uid]
    local r, g, b = pourColor(uid)
    -- fill fraction picks up mid-pour on a resync: elapsed0/total is where the
    -- surface already sits when this thread starts
    local total    = math.max(tonumber(totalMs) or 3000, 250)
    local elapsed0 = math.min(math.max(tonumber(elapsedMs) or 0, 0), total)
    local started  = GetGameTimer()
    local endAt    = started + (total - elapsed0)
    -- the rising surface lives in SodaFill (drawn by the shared loop, so it
    -- persists after the pour); this thread only pushes its level up
    SodaFill[uid] = { f = elapsed0 / total, r = r, g = g, b = b }
    drawSodaFillLoop()
    CreateThread(function()
        while SodaPour[uid] == token do
            if GetGameTimer() > endAt then break end -- backstop; the state sync also stops us
            local seat  = sodaSlotWorld(s.propId, s.slot) -- cup seat, directly under the tap
            local mouth = sodaDispenseWorld(s.propId, s.slot)
            if seat and mouth then
                local cup  = CookObjects[uid]
                local cupH = (cup and DoesEntityExist(cup)) and modelHeight(GetEntityModel(cup)) or 0.12
                local now  = GetGameTimer()
                -- the liquid surface rises with fill progress, cup bottom → fill_to of its height
                local f = math.min((elapsed0 + (now - started)) / total, 1.0)
                local rec = SodaFill[uid]
                if rec then rec.f = f end
                local surface = seat.z + f * cupH * POUR.fill_to
                local fall = mouth.z - surface
                if fall > POUR.min_fall then
                    for i = 1, POUR.droplets do
                        -- staggered phase 0..1; quadratic = accelerating fall (fake
                        -- gravity), STRAIGHT down from the dispense mouth
                        local phase = ((now / POUR.cycle_ms) + (i / POUR.droplets)) % 1.0
                        DrawMarker(28, mouth.x, mouth.y,
                            mouth.z - fall * phase * phase, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            POUR.radius, POUR.radius, POUR.radius, r, g, b, 210,
                            false, false, 2, false, nil, nil, false)
                    end
                end
            end
            Wait(0)
        end
        if SodaPour[uid] == token then SodaPour[uid] = nil end
    end)
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
        -- expand a dual patty layer into its two faces; cookedVariant already applied
        local mdls, heights, rolls = expandStackLayers(stack, state)
        local ents, hs, rl = {}, {}, {}
        for i, mdl in ipairs(mdls) do
            local e = SpawnProp(mdl, 0.0, 0.0, 0.0)
            if e then
                ents[#ents + 1] = e
                hs[#hs + 1] = heights[i]
                rl[#rl + 1] = rolls[i]
                CookEntityUid[e] = uid
            end
        end
        if #ents > 0 then
            CookObjects[uid] = ents[1] -- base prop drives the hover chip projection
            CookSlotStack[uid] = { ents = ents, heights = hs, rolls = rl, baseDz = stackBaseLift(stack[1]) }
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

-- The uid of the cup already on a soda fountain (any tap) — a fountain holds
-- ONE cup at a time, so a second cup gets no seat offered.
local function sodaCupUid(propId)
    for uid, s in pairs(CookSlot) do
        if s.method == "soda" and s.propId == propId then return uid end
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
-- `anyDistance` drops the radius gate: the preview LOCKS to the nearest free
-- slot no matter where the cursor is (soda taps — the cup always sits in a
-- seat rather than trailing the cursor around the machine). `ignoreUid` names
-- a slot item being re-slotted, so its own presence doesn't block it (the
-- one-cup-per-fountain rule would otherwise pin a cup to its tap).
local function nearestOpenSlot(method, anyDistance, ignoreUid)
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
        if not anyDistance and d2 > SLOT_SNAP_R * SLOT_SNAP_R then return end -- too far — don't snap
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
    elseif method == "soda" then
        -- one cup per fountain: a machine already holding a cup (other than the
        -- one being moved between taps) offers no seat at all
        local cupUid = sodaCupUid(prop.id)
        if cupUid and cupUid ~= ignoreUid then return nil end
        for slot = 1, SODA.slots do
            if sodaSlotLive(slot) and not slotOccupied("soda", prop.id, nil, slot) then
                local w = sodaSlotWorld(prop.id, slot)
                if w then consider(nil, slot, w) end
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

-- The soda tap nozzle the cursor is over (screen-projected, same convention as
-- the fryer baskets) — click = pour that tap into the cup seated under it.
local function hoveredTapSlot(propId)
    local cx, cy = GetNuiCursorPosition()
    local sw, sh = GetActiveScreenResolution()
    local cnx = (sw > 0) and (cx / sw) or 0.0
    local cny = (sh > 0) and (cy / sh) or 0.0
    local best, bestD
    local r = SODA.tap_click_r -- tight: the push button only, not the cup's whole column
    for slot = 1, SODA.slots do
        if sodaSlotLive(slot) then
            local w = sodaSlotWorld(propId, slot, true)
            if w then
                local on, sx, sy = GetScreenCoordFromWorldCoord(w.x, w.y, w.z)
                if on then
                    local dx, dy = sx - cnx, sy - cny
                    local d = dx * dx + dy * dy
                    if d <= r * r and (not bestD or d < bestD) then best, bestD = slot, d end
                end
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
local function layoutPreviewStack(ents, heights, x, y, z, headingZ, baseDz, rolls)
    local lift = baseDz or 0.0
    for i, e in ipairs(ents) do
        if e and DoesEntityExist(e) then
            SetEntityCoordsNoOffset(e, x, y, z + lift, false, false, false)
            -- a patty face carries its own roll; everything else is flat (0)
            SetEntityRotation(e, 0.0, (rolls and rolls[i]) or 0.0, headingZ or 0.0, 2, true)
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
        layoutPreviewStack(st.ents, st.heights, x, y, z, headingZ, st.baseDz, st.rolls)
    else
        local ent = CookObjects[uid]
        if ent and DoesEntityExist(ent) then
            SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
            SetEntityRotation(ent, 0.0, 0.0, headingZ, 2, true)
        end
    end
    seatSodaIce(uid, x, y, z, headingZ) -- a cup's rim ice rides the drag
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

-- spawn an oven/fryer/soda item at its station slot
RegisterNetEvent("pickle_restaurants:cooking:slotSpawn", function(p)
    if not p then return end
    SpawnSlotObject(p.uid, p.model, p.prop_id, p.method, p.door, p.slot, p.state, p.stack)
    if p.method == "soda" then
        updateSodaIce(p.uid, p.ice, p.state)
        updateSodaFill(p.uid, p.state)
    end
end)

-- live cook progress for an oven/fryer/soda item's hover panel
RegisterNetEvent("pickle_restaurants:cooking:progress", function(p)
    if not (p and p.uid) then return end
    p.start = GetGameTimer()
    CookProg[p.uid] = p
    -- soda dispensing: pour visuals while the tap runs — cubes free-fall from the
    -- ice nozzle, a drink pours a liquid stream — instead of contents appearing
    -- from nowhere at completion.
    if p.method == "soda" then
        local pg = p.prog or {}
        if pg.state == "filling" then
            if pg.fillKind == "ice" then
                dropSodaIce(p.uid)
            else
                startSodaPour(p.uid, pg.total, pg.elapsed)
            end
        else
            stopSodaPour(p.uid)
        end
        updateSodaFill(p.uid, pg.state)
    end
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
    removeSodaIce(uid)
    stopSodaPour(uid)
    SodaFill[uid] = nil
    CookObjects[uid], CookState[uid], CookCoords[uid], CookSlot[uid], CookProg[uid], CookYaw[uid] = nil, nil, nil, nil, nil, nil
end)

RegisterNetEvent("pickle_restaurants:cooking:bulk", function(list)
    for _, it in ipairs(list or {}) do
        if it.dual then
            RebuildDual(it)
        elseif it.method == "oven" or it.method == "fry" or it.method == "soda" then
            SpawnSlotObject(it.uid, it.model, it.prop_id, it.method, it.door, it.slot, it.state, it.stack)
            if it.method == "soda" then
                updateSodaIce(it.uid, it.ice, it.state)
                updateSodaFill(it.uid, it.state) -- a filled cup shows its drink again
                -- resynced mid-pour: pick the dispensing visuals back up
                local pg = it.prog or {}
                if pg.state == "filling" then
                    if pg.fillKind == "ice" then dropSodaIce(it.uid)
                    else startSodaPour(it.uid, pg.total, pg.elapsed) end
                end
            end
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

-- the server swept spoiled items from our tray -> re-pull it so the NUI drops them.
-- Registered here (after RefreshTray is defined) so the local is in scope.
RegisterNetEvent("pickle_restaurants:cooking:trayDirty", function()
    if cookingOpen and currentCookProp then RefreshTray() end
end)

-- The shared restaurant stock pool (raw ingredients) changed — another cook
-- consumed, a decompose refunded, or a manager restocked. Refresh the bottom
-- ingredient bar so its counts stay live.
RegisterNetEvent("pickle_restaurants:cooking:stockDirty", function(_rid)
    if cookingOpen and currentCookProp then RefreshBar() end
end)

-- the NUI's live countdown hit 0 on an item -> re-pull the tray immediately (getTray
-- purges spoiled rows server-side) so it drops without waiting for the periodic sweep.
RegisterNUICallback("cooking:refreshTray", function(_, cb)
    if cookingOpen and currentCookProp then RefreshTray() end
    cb({ ok = true })
end)

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
                   source = spec.source, cheese = spec.cheese or 0, sig = spec.sig,
                   finishTool = spec.finishTool, ents = {} }

    if type(spec.stack) == "table" and #spec.stack > 1 then
        -- A product that carries a build stack (e.g. a cooked pizza) is ONE logical
        -- part rendered as its whole layer tower — crust + sauce + cheese + toppings
        -- — so it never collapses to a bare base prop on the prep table. `state`
        -- (cooked/burnt) swaps each topping to its cooked look, same as the oven.
        -- a container base layer (cake tin) starts the tower at its mesh-bottom
        -- correction so the tin rests ON the table instead of sinking through it
        -- expand a dual patty layer into its two faces; cookedVariant already applied
        local mdls, heights, rolls = expandStackLayers(spec.stack, spec.state)
        local lifts, prolls, lift = {}, {}, stackBaseLift(spec.stack[1])
        for i, mdl in ipairs(mdls) do
            local e = SpawnProp(mdl, base.x, base.y, base.z)
            if e then
                part.ents[#part.ents + 1] = e
                lifts[#lifts + 1] = lift
                prolls[#prolls + 1] = rolls[i]
                lift = lift + heights[i]
            end
        end
        if #part.ents == 0 then return nil end
        part.stacked = true
        part.lifts   = lifts
        part.rolls   = prolls
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
        -- manual seat correction: layoutParts shifts this part (and everything
        -- stacked above it) by this much when it isn't the base of its pile
        local s = stackSink(spec.model)
        if s ~= 0.0 then part.sink = s end
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
        -- a build-stack part lays its layers flush bottom-to-top from the base z;
        -- a patty face in the tower keeps its own roll (the two-faced flip)
        for i, e in ipairs(part.ents) do
            if e and DoesEntityExist(e) then
                SetEntityCoordsNoOffset(e, x, y, z + (part.lifts[i] or 0.0), false, false, false)
                SetEntityRotation(e, 0.0, (part.rolls and part.rolls[i]) or 0.0, yaw, 2, true)
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
-- makes a top bun render flipped. A part's manual seat correction (part.sink,
-- from STACK_TWEAKS) shifts it and everything above it.
local function layoutParts(parts, x, y, z0, lone)
    local z, prevSeat = z0, nil
    for i, part in ipairs(parts) do
        -- the base part rests on the surface; a sunk part is clamped so it never
        -- drops to/below the seat of the part under it (it would vanish inside)
        if i > 1 then z = math.max(z + (part.sink or 0.0), prevSeat + 0.001) end
        local flip = lone and part.item == "bun" and part.half == "top"
        orientPart(part, x, y, z, flip)
        prevSeat = z
        z = z + (part.height or 0.0)
    end
end
local function relayout(stack)
    layoutParts(stack.parts, stack.x, stack.y, stack.z0, #stack.parts == 1)
end

-- Walk a stack bottom→top with the EXACT maths layoutParts commits — each part's
-- height AND its manual sink (STACK_TWEAKS), clamp included — so anything derived
-- from a stack's top (snap previews, tooltip anchors) matches the placed result.
-- Returns the top z (where the next part rests) and the top part's actual seat.
local function stackWalkTop(stack)
    local z, prevSeat = stack.z0, nil
    for i, p in ipairs(stack.parts) do
        if i > 1 then z = math.max(z + (p.sink or 0.0), prevSeat + 0.001) end
        prevSeat = z
        z = z + (p.height or 0.0)
    end
    return z, prevSeat
end

-- World z of the top of a stack (where the next part rests).
local function stackTopZ(stack)
    local z = stackWalkTop(stack)
    return z
end

-- Where a carried pile's FIRST part seats when snapped onto stack `s`: the
-- stack's (sink-aware) top adjusted by that part's own manual sink, with the same
-- never-below-the-layer-under-it clamp layoutParts applies on commit — so the
-- drag preview sits exactly where release puts it, no hop.
local function stackSnapZ(s, first)
    local z0, prevSeat = stackWalkTop(s)
    local sink = first and first.sink or 0.0
    if sink == 0.0 or not prevSeat then return z0 end
    return math.max(z0 + sink, prevSeat + 0.001)
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

-- The serving tray and the pizza box share all the placement/pick machinery —
-- `kind` ("tray" | "box", nil = "tray") picks which pair of props and which
-- config drives the footprint maths.
local function trayCfg(kind)
    return kind == "box" and BOXP or TRAYP
end
local function trayBaseModel(kind)
    return kind == "box" and BOXP.base_model or TRAYP.tray_model
end

-- Food rests on the paper liner (tray) / the box bed: bed height + a hair so it
-- doesn't z-fight the surface under it.
local function trayFoodDz(kind)
    if kind == "box" then return BOXP.food_dz end
    return TRAYP.paper_dz + 0.002
end

-- Droppable half-extents from the tray/box model's bounds, inset past the rim so
-- anchored food reads as ON the paper / INSIDE the box (drop offsets are clamped
-- into this area).
local function trayHalfExtents(kind)
    local mn, mx = GetModelDimensions(EnsureModel(trayBaseModel(kind)))
    if not (mn and mx) then return 0.15, 0.10 end
    local inset = trayCfg(kind).rim_inset
    return math.max((mx.x - mn.x) * 0.5 - inset, 0.05),
           math.max((mx.y - mn.y) * 0.5 - inset, 0.05)
end

-- Seat the pizza-box lid's ORIGIN (authored on its hinge edge): a fixed step
-- forward of the base's origin (BOXP.lid_fwd), along the BASE's yaw-only
-- forward — never the lid's own forward vector, which tips with its pitch
-- mid-swing and would drift the hinge. Position is set ONLY here, when the box
-- is placed/moved; opening and closing never touch it.
local function boxLidSeat(baseEnt, ent)
    if not (baseEnt and ent and DoesEntityExist(baseEnt) and DoesEntityExist(ent)) then return end
    local h = math.rad(GetEntityHeading(baseEnt))
    local coords = GetEntityCoords(baseEnt) + vector3(-math.sin(h) * BOXP.lid_fwd, math.cos(h) * BOXP.lid_fwd, -0.005)
    SetEntityCoordsNoOffset(ent, coords.x, coords.y, coords.z, false, false, false)
end

-- The lid's swing is ROTATION ONLY: the box's heading plus the opening pitch
-- (-open_deg * openT) about the lid's authored hinge origin.
local function boxLidSwing(baseEnt, ent, openT)
    if not (ent and DoesEntityExist(ent)) then return end
    local yaw = (baseEnt and DoesEntityExist(baseEnt)) and GetEntityHeading(baseEnt) or curYaw()
    SetEntityRotation(ent, BOXP.open_deg * (openT or 0.0) * -1, 0.0, yaw, 2, true)
end

-- Seat a tray/box pair at surface point (x, y, z): the base's mesh bottom rests
-- ON the surface; a tray's paper lies on the tray bed (paper_dz above the base),
-- a box's lid seats on its hinge anchor and swings to opening fraction openT —
-- each prop corrected for its own origin offset.
local function layoutTrayAt(ents, x, y, z, kind, openT)
    local yaw = curYaw() -- faces the prep station, not the world axes
    if kind == "box" then
        local base = ents and ents[1]
        if base and DoesEntityExist(base) then
            SetEntityCoordsNoOffset(base, x, y, z + modelBaseLift(BOXP.base_model), false, false, false)
            SetEntityRotation(base, 0.0, 0.0, yaw, 2, true)
        end
        boxLidSeat(base, ents and ents[2])
        boxLidSwing(base, ents and ents[2], openT)
        return
    end
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

local function spawnTrayEnts(x, y, z, kind, openT)
    local m1, m2 = TRAYP.tray_model, TRAYP.paper_model
    if kind == "box" then m1, m2 = BOXP.base_model, BOXP.lid_model end
    local t = SpawnProp(m1, x, y, z)
    local p = SpawnProp(m2, x, y, z)
    if not t or not p then SafeDeleteEntity(t); SafeDeleteEntity(p); return nil end
    local ents = { t, p }
    layoutTrayAt(ents, x, y, z, kind, openT)
    return ents
end

-- Pickable half-extents: the WHOLE tray/box incl. the rim (physics margin
-- trimmed), plus a little grab padding — unlike trayHalfExtents, which is the
-- inner droppable area only.
local function trayPickExtents(kind)
    local mn, mx = GetModelDimensions(EnsureModel(trayBaseModel(kind)))
    if not (mn and mx) then return 0.25, 0.18 end
    local pad = trayCfg(kind).pick_pad
    return (mx.x - mn.x) * 0.5 - TRAY_PHYS_MARGIN + pad,
           (mx.y - mn.y) * 0.5 - TRAY_PHYS_MARGIN + pad
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
        if math.abs(coords.z - t.z) <= trayCfg(t.kind).pick_dz then
            local hx, hy = trayPickExtents(t.kind)
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

-- Size-aware part picking: instead of one generous fixed screen radius, each
-- part is targeted within ITS OWN projected footprint — half its model's
-- horizontal extent (GetModelDimensions), projected at the part's distance from
-- the camera — so a small topping can't steal the cursor from half a table
-- away. pad/min are normalized-screen slack for thin/tiny props. TUNE IN-GAME.
local PART_PICK = { pad = 0.012, min = 0.025 }
local ModelHalfXY = {} -- [model hash] = half the larger horizontal extent (m)

local function modelHalfXY(hash)
    local r = ModelHalfXY[hash]
    if not r then
        local mn, mx = GetModelDimensions(hash)
        r = math.max(mx.x - mn.x, mx.y - mn.y) * 0.5
        ModelHalfXY[hash] = r
    end
    return r
end

-- A part's world pick radius: the widest of its rendered entities (a stacked
-- tower picks by its broadest layer). Cached on the part — its props never
-- change model after spawn.
local function partHalfXY(part)
    local r = part.pickR
    if r then return r end
    r = 0.03
    for _, e in ipairs(part.ents or {}) do
        if DoesEntityExist(e) then r = math.max(r, modelHalfXY(GetEntityModel(e))) end
    end
    part.pickR = r
    return r
end

-- A pile inside a CLOSED pizza box is out of reach — the lid has to swing open
-- before its contents can be hovered, grabbed, or stacked onto.
local function stackSealed(stack)
    local t = stack.tid and PrepTrays[stack.tid]
    return (t and t.kind == "box" and not t.open) and true or false
end

-- The placed part under the cursor, by screen proximity to each part's rendered
-- CENTRE (same projection the stovetop hover uses → lines up with the station
-- cam), within that part's own projected size. Returns sid, index, part.
-- `exceptSid` skips one stack (rarely needed).
local function pickPart(exceptSid)
    local cx, cy = GetNuiCursorPosition()
    local sw, sh = GetActiveScreenResolution()
    local cnx = (sw > 0) and (cx / sw) or 0.0
    local cny = (sh > 0) and (cy / sh) or 0.0
    local bsid, bidx, bpart, bd
    for sid, stack in pairs(PrepStacks) do
        if sid ~= exceptSid and not stackSealed(stack) then
            local z = stack.z0
            for i, part in ipairs(stack.parts) do
                local mz = z + (part.height or 0.0) * 0.5
                local on, sx, sy = GetScreenCoordFromWorldCoord(stack.x, stack.y, mz)
                if on then
                    -- project the part's world radius to a screen radius: how far
                    -- (on screen) a point one radius above the centre lands
                    local rw = partHalfXY(part)
                    local R = PART_PICK.min
                    local on2, sx2, sy2 = GetScreenCoordFromWorldCoord(stack.x, stack.y, mz + rw)
                    if on2 then
                        local rx, ry = sx2 - sx, sy2 - sy
                        R = math.max(math.sqrt(rx * rx + ry * ry) + PART_PICK.pad, PART_PICK.min)
                    end
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

-- Swing a placed pizza box's lid open/closed: eased hinge rotation over
-- BOXP.open_ms (never a pop). Re-toggling mid-swing bumps animSeq so the old
-- thread yields and the new swing picks up from the current angle; grabbing or
-- removing the box kills the thread via the PrepTrays identity check.
local function setBoxOpen(tid, open)
    local t = PrepTrays[tid]
    if not t or t.kind ~= "box" or t.open == open then return end
    t.open = open
    t.animSeq = (t.animSeq or 0) + 1
    local seq = t.animSeq
    CreateThread(function()
        local from = t.openT or (open and 0.0 or 1.0)
        local to = open and 1.0 or 0.0
        local t0 = GetGameTimer()
        while PrepTrays[tid] == t and t.animSeq == seq do
            local k = math.min((GetGameTimer() - t0) / BOXP.open_ms, 1.0)
            k = k * k * (3.0 - 2.0 * k) -- smoothstep ease in-out
            t.openT = from + (to - from) * k
            boxLidSwing(t.ents and t.ents[1], t.ents and t.ents[2], t.openT)
            if k >= 1.0 then break end
            Wait(0)
        end
    end)
end

-- How many parts sit on a tray / inside a box (the tooltip count and the box's
-- one-pizza occupancy check).
local function trayPileCount(tid)
    local n = 0
    for _, s in pairs(PrepStacks) do if s.tid == tid then n = n + #s.parts end end
    return n
end

-- What the pizza box accepts: the carried pile's BOTTOM layer must render a
-- pizza crust. Matched by MODEL so every cook state qualifies — the raw dough
-- component, an assembled uncooked pizza, and a cooked/burnt one all base on a
-- dough_models prop (the server re-validates by item on make).
local BoxDough = nil
local function partsArePizza(parts)
    if not BoxDough then
        BoxDough = {}
        for _, m in ipairs(BOXP.dough_models) do BoxDough[GetHashKey(m)] = true end
    end
    local p = parts and parts[1]
    local e = p and p.ents and p.ents[1]
    return (e and DoesEntityExist(e) and BoxDough[GetEntityModel(e)]) and true or false
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

-- Lay a carried tray/box (+ its piles) at a world point — the live preview while
-- a meal / a grabbed tray follows the cursor.
local function layoutTrayGroup(drag, x, y, z)
    layoutTrayAt(drag.tray, x, y, z, drag.trayKind, drag.openT)
    local fz = z + trayFoodDz(drag.trayKind)
    for _, pile in ipairs(drag.piles or {}) do
        layoutParts(pile.parts, x + pile.dx, y + pile.dy, fz, false)
    end
end

-- Commit a carried tray/box group: (re)create it at (x, y, z) and one stack per
-- pile, anchored at its offset. Used by the meal un-make drop and a tray move.
local function commitTrayGroup(x, y, z, ents, piles, kind, open)
    prepTid = prepTid + 1
    local tid = prepTid
    kind = kind or "tray"
    local isBox = kind == "box"
    PrepTrays[tid] = { x = x, y = y, z = z, kind = kind, ents = ents,
                       open = isBox and (open and true or false) or nil,
                       openT = isBox and (open and 1.0 or 0.0) or nil }
    layoutTrayAt(ents, x, y, z, kind, open and 1.0 or 0.0)
    local fz = z + trayFoodDz(kind)
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

-- Turn a placed tray's / box's arrangement into ONE meal item (the server
-- consumes the reserved parts and records each layer's offset; a box flags the
-- meal so it sets back down as its box). On success the tray and its stacks are
-- torn down. Returns the server result, or nil for an empty tray.
local function makeMealFromTray(tid, silent)
    local t = PrepTrays[tid]; if not t then return nil end
    local piles = collectTrayPiles(tid)
    if #piles == 0 then return nil end
    local items = {}
    for _, p in ipairs(piles) do items[#items + 1] = { ids = p.ids, dx = p.dx, dy = p.dy } end
    local res = lib.callback.await("pickle_restaurants:cooking:prepMakeMeal", false,
        { items = items, box = (t.kind == "box") or nil })
    if res and res.ok then
        for _, p in ipairs(piles) do removePrepStack(p.sid) end
        removePrepTray(tid)
        if not silent and res.label then ShowNotification(_L("cook_made", res.label)) end
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
                drag.boxBlock = nil
                if sid then
                    local s = PrepStacks[sid]
                    local z0 = stackSnapZ(s, drag.parts[1]) -- sink applies in the preview too
                    drag.hit, drag.targetSid, drag.targetTid, drag.coords = true, sid, nil, { x = s.x, y = s.y, z = z0 }
                    setOutline(sid, 80, 200, 120)
                    setTrayOutline(nil)
                    layoutParts(drag.parts, s.x, s.y, z0, false)
                elseif tid and hit and coords and PrepTrays[tid].kind == "box" then
                    -- over a pizza box: it takes exactly ONE pizza — lid open, box
                    -- empty, and the carried pile sitting on a pizza crust (any cook
                    -- state). A qualifying drop seats it in the CENTRE of the box;
                    -- anything else outlines the box red and refuses on release.
                    local t = PrepTrays[tid]
                    local block
                    if not t.open then block = "Open the box first."
                    elseif trayPileCount(tid) > 0 then block = "There's already a pizza in there."
                    elseif not partsArePizza(drag.parts) then block = _L("cook_only_pizza_in_box")
                    end
                    if block then
                        drag.hit, drag.targetSid, drag.targetTid = true, nil, nil
                        drag.coords = { x = coords.x, y = coords.y, z = coords.z }
                        drag.boxBlock = block
                        setOutline(nil)
                        setTrayOutline(tid, 230, 70, 70)
                        layoutParts(drag.parts, coords.x, coords.y, coords.z, false)
                    else
                        local fz = t.z + trayFoodDz("box")
                        drag.hit, drag.targetSid, drag.targetTid = true, nil, tid
                        drag.coords = { x = t.x, y = t.y, z = fz, dx = 0.0, dy = 0.0 }
                        setOutline(nil)
                        setTrayOutline(tid, 80, 200, 120)
                        layoutParts(drag.parts, t.x, t.y, fz, false)
                    end
                elseif tid and hit and coords then
                    -- over a tray: anchor to the paper where the cursor points, clamped
                    -- inside the rim; release starts a new pile at that exact offset
                    local t = PrepTrays[tid]
                    local hx, hy = trayHalfExtents(t.kind)
                    local dx = math.min(math.max(coords.x - t.x, -hx), hx)
                    local dy = math.min(math.max(coords.y - t.y, -hy), hy)
                    local fz = t.z + trayFoodDz(t.kind)
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
                        -- oven/fryer/soda item: single gated timeline; count up locally
                        -- only while the gate is open (door closed / basket down / tap
                        -- pouring).
                        local pr = CookProg[uid]
                        local pg = (pr and pr.prog) or {}
                        local st = pg.state or CookState[uid] or "raw"
                        local total = pg.total or 0
                        local elapsed = (pg.elapsed or 0) + ((pg.gate and pr and pr.start) and (now - pr.start) or 0)
                        local percent = 0.0
                        if st == "burnt" then percent = 1.0 elseif total > 0 then percent = math.min(1.0, elapsed / total) end
                        local slot = CookSlot[uid]
                        -- a poured cup's bar reads full even though no timer is running
                        if slot.method == "soda" and (st == "filled" or st == "capped") then percent = 1.0 end
                        items[#items + 1] = {
                            uid = uid, single = true, onScreen = onScreen, x = sx, y = sy,
                            method = slot.method, state = st, percent = percent,
                            gate = pg.gate and true or false,
                            ice = pg.ice or nil, needLid = pg.needLid or nil,
                            burningSoon = (slot.method ~= "soda" and st == "cooked" and percent > 0.66),
                            -- a fry in a lowered basket / a cup mid-pour can't be
                            -- grabbed — the NUI refuses to even start the drag
                            locked = ((slot.method == "fry" and slotDown(slot.propId, slot.slot))
                                   or (slot.method == "soda" and st == "filling")) or nil,
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
            local prepHoverBox = false -- the hovered tray is a pizza box (click = lid toggle)
            if currentCookProp and currentCookProp.prop_type == "kitchen_prep" and not prepDrag and not finishing then
                local sid, _, part = pickPart(nil)
                local stack = sid and PrepStacks[sid]
                -- A pile sitting ON a serving tray offers only the tray-level "Make
                -- Meal", never a per-stack product make — so hovering it shows the
                -- tray tooltip, not the recipe-make one.
                local onTrayTid = (stack and stack.tid and PrepTrays[stack.tid]) and stack.tid or nil
                -- A pile INSIDE a pizza box belongs to the BOX: hovering it hovers
                -- the box (click = lid toggle, drag = the whole box; the tooltip's
                -- Take Out is how the pizza leaves) — so the part-grab is
                -- suppressed. Serving-tray piles stay directly grabbable.
                local inBox = onTrayTid and PrepTrays[onTrayTid].kind == "box"
                if part and not inBox then prepHoverPid = part.pid end
                setOutline((not inBox) and sid or nil, 255, 180, 40)
                if stack and not onTrayTid then
                    local on, sx, sy = GetScreenCoordFromWorldCoord(stack.x, stack.y, stackTopZ(stack))
                    prepTip = { sid = sid, onScreen = on, x = sx, y = sy, provides = stackProvides(stack) }
                end
                -- The serving tray's "Make Meal" / pizza box's "Box It Up" tooltip:
                -- shown when the cursor is over the tray/box itself OR over any pile
                -- arranged on it. Counts everything on/in it; a box also reports its
                -- lid state (the NUI turns a click on it into a lid toggle).
                prepHoverTid = onTrayTid or ((not sid) and pickTray()) or nil
                setTrayOutline(prepHoverTid, 255, 180, 40)
                if prepHoverTid then
                    local t = PrepTrays[prepHoverTid]
                    local isBox = t.kind == "box"
                    prepHoverBox = isBox
                    local on, sx, sy = GetScreenCoordFromWorldCoord(t.x, t.y, t.z + trayFoodDz(t.kind) + 0.06)
                    prepTip = { tray = true, box = isBox or nil, open = isBox and (t.open and true or false) or nil,
                                boxing = (isBox and t.boxing) and true or nil,
                                tid = prepHoverTid, onScreen = on, x = sx, y = sy, count = trayPileCount(prepHoverTid) }
                end
            end
            prepHovered = prepHoverPid
            trayHovered = prepHoverTid

            -- (Soda taps carry no on-screen label: the fountain model already
            -- prints each flavor, so clicking the printed nozzle — resolved
            -- world-side by hoveredTapSlot on worldClick — is all that's needed.)

            SendNUIMessage({ action = "cookingItems", items = items, hovered = hoveredUid,
                             prepHovered = prepHoverPid, prepTrayHovered = prepHoverTid,
                             prepTrayBox = prepHoverBox, prepTip = prepTip })

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
            -- expand a dual patty layer into its two faces (uncooked preview → no state)
            local mdls, hs, rls = expandStackLayers(stackModels, nil)
            local ents, heights, rolls = {}, {}, {}
            for i, m in ipairs(mdls) do
                local e = SpawnProp(m, base.x, base.y, base.z)
                if e then ents[#ents + 1] = e; heights[#heights + 1] = hs[i]; rolls[#rolls + 1] = rls[i] end
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
                        layoutPreviewStack(ents, heights, best.w.x, best.w.y, best.w.z, headingZ, baseDz, rolls)
                    else
                        p.hit = false
                        local hit, coords = CursorToWorld()
                        if hit and coords then layoutPreviewStack(ents, heights, coords.x, coords.y, coords.z, headingZ, baseDz, rolls) end
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

    -- Soda machine: the cup snaps under the nearest free tap (slot placement,
    -- like the fryer baskets); release seats it on the drip tray.
    if d.kind == "drink" then
        local model = previewModel("drink", d.item)
        local ent = model and SpawnProp(model, base.x, base.y, base.z) or nil
        if not ent then return cb({ ok = false }) end
        SetEntityRotation(ent, 0.0, 0.0, curYaw(), 2, true)
        local p = { entity = ent, kind = d.kind, item = d.item, slotmode = "soda", source = d.source, hit = false }
        placing = p
        CreateThread(function()
            while placing == p do
                -- always LOCK onto the nearest free tap — the cup never trails
                -- the cursor loosely around the machine
                local best = nearestOpenSlot("soda", true)
                if best then
                    p.hit, p.door, p.slot = true, nil, best.slot
                    SetEntityCoordsNoOffset(ent, best.w.x, best.w.y, best.w.z, false, false, false)
                    alignToStation(base.id, ent)
                else
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
    -- Delete the preview only after the server's synced prop has ACTUALLY spawned
    -- (its spawn event can be dispatched a frame or two after this callback resolves),
    -- so the preview and the real prop overlap and there's no gap where nothing exists.
    -- Bounded so a dropped spawn event can't strand the preview forever.
    if res and res.ok and res.uid then
        local uid, tries = res.uid, 0
        while not (CookObjects[uid] or CookDual[uid]) and tries < 60 do Wait(0); tries = tries + 1 end
    end
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
        -- An EMPTY soda cup LOCKs to a tap seat (no loose trailing between nozzles) so
        -- it stays positionable under the ice/flavor buttons. Once it's been POURED
        -- ("filled"/"capped"), it drags freely on the cursor like any other item — you're
        -- past pouring and want to pull it to the bar / reposition it, not re-snap taps.
        local sodaLock = method == "soda"
            and CookState[uid] ~= "filled" and CookState[uid] ~= "capped"
        local m = { uid = uid, slot = true, hit = false }
        moving = m
        CreateThread(function()
            while moving == m do
                if not CookObjects[uid] then break end -- collected / removed mid-drag
                -- Snap onto the nearest OPEN slot (any other rack), exactly like placing a
                -- fresh item — release there re-slots it. Otherwise trail the cursor; a
                -- release off any slot just snaps it back to where it was.
                local best = nearestOpenSlot(method, sodaLock, uid)
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
        if res.label then ShowNotification(_L("cook_collected", res.label)) end
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
        if res.label then ShowNotification(_L("cook_took", res.label)) end
        RefreshTray(); RefreshBar()
    elseif res and res.error then
        ShowNotification(res.error)
    end
    cb(res or { ok = false })
end)

-- throw a tray entry (or, with burnt_only, everything burnt) in the bin
RegisterNUICallback("cooking:trayDiscard", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:cooking:trayDiscard", false, {
        prop_id = currentCookProp and currentCookProp.id, item = d.item, cheese = d.cheese,
        count = d.count, sig = d.sig, burnt_only = d.burnt_only,
    })
    if res and res.ok then
        if res.label then
            ShowNotification(_L("cook_threw", res.label, res.count or 1))
        else
            ShowNotification(_L("cook_threw_burnt", res.count or 0, (res.count or 0) == 1 and "" or "s"))
        end
        RefreshTray()
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
                     stack = stack, state = d.state, finishTool = d.finishTool,
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
    -- released over a pizza box that can't take this (closed / occupied / not a
    -- pizza): nothing was reserved yet, so it's just a refused drop
    if drag.boxBlock then
        deleteParts(drag.parts)
        ShowNotification(drag.boxBlock)
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
                             sig = spec.sig, stack = spec.stack, state = spec.state, finishTool = spec.finishTool })
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
        -- a boxed meal previews as its pizza box, lid open so the pizza shows
        local base = currentCookProp
        local kind = res.box and "box" or "tray"
        local openT = res.box and 1.0 or nil
        local ents = spawnTrayEnts(base.x, base.y, base.z, kind, openT)
        if not ents then deleteParts(parts); return cb({ ok = false }) end
        prepDrag = { tray = ents, trayKind = kind, open = res.box and true or nil, openT = openT,
                     piles = groupPiles(parts), parts = parts, hit = false, decompose = true, meal = true }
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
    local targetSid, targetTid, coords, hit, boxBlock = drag.targetSid, drag.targetTid, drag.coords, drag.hit, drag.boxBlock
    deleteDrag(drag)
    if (d and d.cancel) or not hit then return cb({ ok = false }) end
    -- refused by a pizza box (closed / occupied / not a pizza): nothing consumed
    if boxBlock then ShowNotification(boxBlock); return cb({ ok = false }) end

    local res = lib.callback.await("pickle_restaurants:cooking:prepDecompose", false, {
        prop_id = currentCookProp and currentCookProp.id, item = d and d.item, sig = d and d.sig, source = d and d.source,
    })
    if not (res and res.ok) then
        if res and res.error then ShowNotification(res.error) end
        return cb(res or { ok = false })
    end

    local parts = partsFromDecomposeSpecs(res.parts)
    if #parts == 0 then RefreshTray(); RefreshBar(); return cb({ ok = false }) end

    -- A meal sets down as its whole tray (or its pizza box, lid open): the pair
    -- recreated at the drop point, one editable pile per recorded offset —
    -- exactly the arrangement it was made as.
    if res.meal then
        local kind = res.box and "box" or "tray"
        local ents = spawnTrayEnts(coords.x, coords.y, coords.z, kind, res.box and 1.0 or nil)
        if ents then
            commitTrayGroup(coords.x, coords.y, coords.z, ents, groupPiles(parts), kind, res.box and true or false)
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
            if #items == 0 then -- empty tray/box dropped on the bar: just put it away
                deleteDrag(drag)
                return cb({ ok = true })
            end
            -- a pizza box closes before it's sent off: swing the carried lid shut
            -- where it hovers, give it a beat to settle, then make the meal
            -- (instant when it was carried closed)
            if drag.trayKind == "box" and drag.open then
                local t0 = GetGameTimer()
                while GetGameTimer() - t0 < BOXP.open_ms do
                    local k = (GetGameTimer() - t0) / BOXP.open_ms
                    k = k * k * (3.0 - 2.0 * k)
                    boxLidSwing(drag.tray[1], drag.tray[2], 1.0 - k)
                    Wait(0)
                end
                boxLidSwing(drag.tray[1], drag.tray[2], 0.0)
                drag.open, drag.openT = false, 0.0
                Wait(1000)
            end
            local res = lib.callback.await("pickle_restaurants:cooking:prepMakeMeal", false,
                { items = items, box = (drag.trayKind == "box") or nil })
            if res and res.ok then
                deleteDrag(drag)
                if res.label then ShowNotification(_L("cook_made", res.label)) end
                RefreshTray(); RefreshBar()
                return cb(res)
            end
            if res and res.error then ShowNotification(res.error) end
            -- fall through: put the tray (and everything on it) back down
        end
        local c = (drag.hit and drag.coords) or drag.home
        commitTrayGroup(c.x, c.y, c.z, drag.tray, drag.piles, drag.trayKind, drag.open)
        return cb({ ok = true })
    end
    -- refused by a pizza box (closed / occupied / not a pizza): snap the carried
    -- parts back to where they came from instead of committing into the box
    -- (a drop on the bar still wins — that's the remove/save path below)
    if drag.boxBlock and not (d and d.cancel) then
        ShowNotification(drag.boxBlock)
        drag.hit = false
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
                    if res.label then ShowNotification(_L("cook_saved", res.label)) end
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
                    local s = { x = t.x + (dx or 0.0), y = t.y + (dy or 0.0), z0 = t.z + trayFoodDz(t.kind),
                                tid = tid, dx = dx, dy = dy, parts = parts }
                    PrepStacks[prepSid] = s
                    relayout(s)
                end
            end
        end
        if res.label then ShowNotification(_L("cook_made", res.label)) end
        RefreshTray(); RefreshBar()
    elseif res and res.error then
        ShowNotification(res.error)
    end
    cb(res or { ok = false })
end)

-- ─── serving tray & pizza box (kitchen_prep) ─────────────────────────────────

-- Drag a fresh serving tray (or pizza box, kind "box") out of the bar: the prop
-- pair previews under the cursor; drop on the table places it, ready to arrange
-- food on (a box places closed — click the lid to swing it open).
RegisterNUICallback("cooking:beginTrayPlace", function(d, cb)
    cancelPlace(); cancelMove()
    if prepDrag then deleteDrag(prepDrag); prepDrag = nil end
    setOutline(nil); setTrayOutline(nil)
    local base = currentCookProp
    if not base or base.prop_type ~= "kitchen_prep" then return cb({ ok = false }) end
    local kind = (d and d.kind == "box") and "box" or "tray"
    local ents = spawnTrayEnts(base.x, base.y, base.z, kind, 0.0)
    if not ents then return cb({ ok = false }) end
    prepDrag = { tray = ents, trayKind = kind, openT = 0.0, parts = {}, piles = {}, hit = false }
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
    commitTrayGroup(drag.coords.x, drag.coords.y, drag.coords.z, drag.tray, nil, drag.trayKind, false)
    cb({ ok = true })
end)

-- Click the pizza box's lid: swing it open / closed (smooth hinge, setBoxOpen).
-- Locked while the box is closing to be sent off (boxing).
RegisterNUICallback("cooking:boxToggle", function(d, cb)
    local tid = tonumber(d and d.tid)
    local t = tid and PrepTrays[tid]
    if not t or t.kind ~= "box" or t.boxing then return cb({ ok = false }) end
    setBoxOpen(tid, not t.open)
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
    if t.boxing then return cb({ ok = false }) end -- mid-close, being boxed up
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
    -- a box carries its lid state along (settled, so a mid-swing grab can't
    -- freeze the lid half-open) and puts back down in that same state
    local isBox = t.kind == "box"
    prepDrag = { tray = t.ents, trayKind = t.kind, open = isBox and (t.open and true or false) or nil,
                 openT = isBox and (t.open and 1.0 or 0.0) or nil, piles = piles, parts = parts,
                 home = { x = t.x, y = t.y, z = t.z }, hit = false }
    runDragThread(prepDrag)
    cb({ ok = true })
end)

-- The tray tooltip's Make Meal / the box tooltip's Box It Up: everything arranged
-- on tray/box `tid` becomes one meal item, exact layout preserved. A pizza box
-- CLOSES first: the lid swings shut, settles for a second, and only then is the
-- meal made — instantly when it's already closed. Grabbing/clearing the box
-- mid-close cancels the send.
RegisterNUICallback("cooking:prepMakeMeal", function(d, cb)
    local tid = tonumber(d and d.tid)
    local t = tid and PrepTrays[tid]
    if not t then return cb({ ok = false }) end
    if t.kind == "box" then
        if t.boxing then return cb({ ok = false }) end
        if trayPileCount(tid) == 0 then
            ShowNotification(_L("cook_box_empty"))
            return cb({ ok = false })
        end
        if t.open then
            t.boxing = true
            setBoxOpen(tid, false)
            Wait(BOXP.open_ms + 1000)
            if PrepTrays[tid] ~= t then return cb({ ok = false }) end -- grabbed/cleared mid-close
            t.boxing = nil
        end
    end
    local res = makeMealFromTray(tid, false)
    if not res then
        ShowNotification(t.kind == "box" and _L("cook_box_empty") or _L("cook_tray_empty"))
        return cb({ ok = false })
    end
    if res.ok then RefreshTray(); RefreshBar() end
    cb(res or { ok = false })
end)

-- The box tooltip's Take Out: lift the pizza back OUT of the box — the pile
-- slides from the box bed onto the table beside it (animated, never a pop) and
-- becomes a free, grabbable stack again. A closed lid swings open first.
RegisterNUICallback("cooking:boxTakeOut", function(d, cb)
    local tid = tonumber(d and d.tid)
    local t = tid and PrepTrays[tid]
    if not t or t.kind ~= "box" or t.boxing then return cb({ ok = false }) end
    local sid, stack
    for id2, s in pairs(PrepStacks) do
        if s.tid == tid then sid, stack = id2, s break end
    end
    if not stack then return cb({ ok = false }) end
    local wasClosed = not t.open
    if wasClosed then setBoxOpen(tid, true) end -- can't reach through the lid
    -- land one box-width to the box's local right, resting on the table surface
    local mn, mx = GetModelDimensions(EnsureModel(BOXP.base_model))
    local w = (mn and mx) and math.max((mx.x - mn.x) - TRAY_PHYS_MARGIN * 2, 0.2) or 0.4
    local off = w * 0.5 + (partHalfXY(stack.parts[1]) or 0.15) + 0.05
    local hr = math.rad(curYaw())
    local fx, fy, fz = stack.x, stack.y, stack.z0
    local tx, ty, tz = t.x + math.cos(hr) * off, t.y + math.sin(hr) * off, t.z
    stack.tid, stack.dx, stack.dy = nil, nil, nil
    stack.x, stack.y, stack.z0 = tx, ty, tz
    CreateThread(function()
        if wasClosed then Wait(BOXP.open_ms) end -- let the lid clear the opening
        local t0, dur = GetGameTimer(), 250
        while true do
            local k = math.min((GetGameTimer() - t0) / dur, 1.0)
            k = k * k * (3.0 - 2.0 * k) -- eased slide out
            if PrepStacks[sid] ~= stack then return end -- re-grabbed/consumed mid-slide
            layoutParts(stack.parts, fx + (tx - fx) * k, fy + (ty - fy) * k, fz + (tz - fz) * k, #stack.parts == 1)
            if k >= 1.0 then break end
            Wait(0)
        end
    end)
    cb({ ok = true })
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

-- ─── soda machine lid ────────────────────────────────────────────────────────

-- The fountain's cup when the cursor is over it AND it can take a lid (filled,
-- not yet capped) — the lid drag snaps onto it. Screen-projected against the
-- cup's mid-height, same snap radius as the slot seats.
local function lidSnapCup()
    local prop = currentCookProp; if not prop then return nil end
    local uid = sodaCupUid(prop.id)
    if not uid or CookState[uid] ~= "filled" then return nil end
    local cup = CookObjects[uid]
    if not (cup and DoesEntityExist(cup)) then return nil end
    local pos = GetEntityCoords(cup)
    local cupH = modelHeight(GetEntityModel(cup)) or 0.12
    local on, sx, sy = GetScreenCoordFromWorldCoord(pos.x, pos.y, pos.z + cupH * 0.5)
    if not on then return nil end
    local cx, cy = GetNuiCursorPosition()
    local sw, sh = GetActiveScreenResolution()
    local dx = sx - ((sw > 0) and (cx / sw) or 0.0)
    local dy = sy - ((sh > 0) and (cy / sh) or 0.0)
    if dx * dx + dy * dy > SLOT_SNAP_R * SLOT_SNAP_R then return nil end
    return uid, cup, pos, cupH
end

-- begin dragging a lid: the real lid prop follows the cursor in 3D (exactly like
-- a cheese slice) — but TARGETING the cup snaps it onto the rim right away, so
-- it previews attached, not only on release. Releasing while snapped presses it on.
RegisterNUICallback("cooking:beginLid", function(d, cb)
    cancelPlace()
    cancelMove()
    local model, base = d.model, currentCookProp
    if not model or not base then return cb({ ok = false }) end
    local ent = SpawnProp(model, base.x, base.y, base.z)
    if not ent then return cb({ ok = false }) end
    SetEntityRotation(ent, 0.0, 0.0, curYaw(), 2, true) -- face the station while dragging
    local p = { entity = ent, lid = true, item = d.item, hit = false }
    placing = p
    CreateThread(function()
        while placing == p do
            local uid, cup, pos, cupH = lidSnapCup()
            if uid then
                -- hovering the (filled) cup: seat the lid on its rim, aligned to
                -- it — and hide the liquid underneath while the lid covers it
                p.hit, p.snapUid = true, uid
                SodaLidPreviewUid = uid
                SetEntityCoordsNoOffset(ent, pos.x, pos.y, pos.z + cupH, false, false, false)
                local cr = GetEntityRotation(cup, 2)
                SetEntityRotation(ent, cr.x, cr.y, cr.z, 2, true)
            else
                p.snapUid = nil
                SodaLidPreviewUid = nil
                local hit, coords = CursorToWorld()
                if hit and coords then
                    p.hit, p.coords = true, coords
                    SetEntityCoordsNoOffset(ent, coords.x, coords.y, coords.z, false, false, false)
                else
                    p.hit = false
                end
            end
            Wait(0)
        end
        SodaLidPreviewUid = nil -- drag over (released / cancelled): liquid shows again
    end)
    cb({ ok = true })
end)

-- release a lid drag: drop the preview and, if snapped onto (or released over) a
-- soda cup, press it on (the server validates + consumes the lid and re-renders
-- the capped cup for everyone).
RegisterNUICallback("cooking:endLid", function(d, cb)
    local p = placing; placing = nil
    deletePreview(p)
    local uid = (d and d.uid) or (p and p.snapUid)
    if not (d and d.cancel) and uid and CookSlot[uid] and CookSlot[uid].method == "soda" then
        local res = lib.callback.await("pickle_restaurants:cooking:applyLid", false, { uid = uid })
        if res and res.error then ShowNotification(res.error) end
        -- drop the liquid right away — don't let it flash back in the gap
        -- before the capped-cup sync lands
        if res and res.ok then SodaFill[uid] = nil; RefreshBar() end
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
-- configured targets), the flavor doesn't apply to it (glazed on a cake), or the
-- target requires a prior finish the part doesn't carry (sprinkles need frosting —
-- checked on the part's recorded finishTool, since a frosted doughnut is the same
-- cooked_doughnut item now). Server re-validates on apply regardless.
local function finishTargetFor(cfg, part, flavorId)
    for _, t in ipairs(cfg.targets or {}) do
        if t.item == part.item then
            if t.requires_finish and part.finishTool ~= t.requires_finish then return nil end
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
        if res.label then ShowNotification(_L("cook_made", res.label)) end
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
                target, flavor = finishTargetFor(cfg, part, f.flavor)
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
    elseif currentCookProp and currentCookProp.prop_type == "soda_machine" then
        -- clicking a tap pours it into the cup seated under it (middle = ice)
        local slot = hoveredTapSlot(currentCookProp.id)
        if slot then
            local res = lib.callback.await("pickle_restaurants:cooking:sodaTap", false, {
                prop_id = currentCookProp.id, slot = slot,
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
    for uid in pairs(SodaIce) do removeSodaIce(uid) end
    for uid in pairs(SodaPour) do stopSodaPour(uid) end
    for uid in pairs(SodaFill) do SodaFill[uid] = nil end
    for _, ent in pairs(CookObjects) do
        SafeDeleteEntity(ent)
    end
    -- prep build parts + any in-flight placement/topping/finish previews
    clearPrepStacks()
    deletePreview(placing); placing = nil
    cancelFinish()
end)
