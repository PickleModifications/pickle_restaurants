-- =============================================
--  modules/cooking | server.lua
--  Authoritative state for food being cooked on stations. Clients render the
--  3D props; the server owns placement, the raw->cooked->burnt timeline, and
--  hand-back into the player's inventory.
--
--  Beef patties (recipes flagged dual_sided) cook per-face: only the down side
--  advances, and the player flips them to cook the other side. State is tracked
--  per side and never shared.
-- =============================================

local CookingItems = {} -- [uid] = { uid, rid, prop_id, station, kind, recipe, drink, output, state, model, x, y, z, dual, sides, flipped, down, elapsed, timerToken, phaseStart }
local cookUid = 0

-- ─── exclusive station use ───────────────────────────────────────────────────
-- One player per station entity at a time — physical stations and virtual points
-- alike (same pattern as the seating module's SeatOccupancy). Claimed when a
-- cooking session opens, freed when it closes, the player drops, or the prop is
-- deleted. Re-claiming a station you already hold is a no-op success: the virtual
-- flow claims early (before fading) and OpenCookingStation claims again.
local StationOccupancy = {} -- [propId] = src currently cooking there

lib.callback.register("pickle_restaurants:cooking:openStation", function(src, d)
    local propId = tonumber(d and d.prop_id)
    local prop = propId and PropCache[propId]
    if not prop or prop.prop_type == "seat" then return { ok = false } end
    if not HasPerm(prop.restaurant_id, src, "cook") then return { ok = false, error = _L("no_work_here") } end
    local holder = StationOccupancy[propId]
    if holder and holder ~= src then return { ok = false, error = _L("cook_station_busy") } end
    StationOccupancy[propId] = src
    -- live metadata rides along: a virtual session rebuilds its oven doors /
    -- fryer baskets from this (the synced row can be stale — door/basket flips
    -- mutate the cache without a full re-sync)
    return { ok = true, metadata = prop.metadata }
end)

RegisterNetEvent("pickle_restaurants:cooking:closeStation", function(propId)
    propId = tonumber(propId)
    if propId and StationOccupancy[propId] == source then StationOccupancy[propId] = nil end
end)

AddEventHandler("playerDropped", function()
    for propId, holder in pairs(StationOccupancy) do
        if holder == source then StationOccupancy[propId] = nil end
    end
end)

-- Interactive prep reservations live here. Declared up top (defined further down)
-- so the ingredient/tray callbacks can subtract what a build has reserved from the
-- counts they show — items aren't consumed until Make, but the bar reflects them
-- as "spoken for" the moment they're placed on the table.
local PrepBuilds = {} -- [src] = { prop_id, rid, seq, layers = { {id, source, item, half, sig} … } }
                      -- (a layer's topping, if any, is resolved from the reserved
                      -- instance's meta by `sig` in consumeLayers)
-- Filled baking trays awaiting collection. Rubbing the mix into a tray consumes 1
-- mix immediately (cheat-safe: you can't conjure a raw bake without spending mix)
-- and records a pending credit here; dragging the filled tray to the hotbar redeems
-- one credit for its output item. Un-redeemed credits are refunded to the pool when
-- the cook leaves the station or disconnects.
--   BakePending[src] = { rid, mix, outs = { [output_item] = count } }
local BakePending = {}
local layerUnits      -- fwd: units a single layer contributes (bun half = 0.5)
local reservedUnits   -- fwd: units of (source,item,cheese) a build already reserved

-- ─── soda machine taps ───────────────────────────────────────────────────────
-- The fountain has SEVEN nozzles: the MIDDLE one dispenses ice, the other six
-- pour the first six valid `drinks` entries left-to-right (config order = tap
-- order; the client derives the same mapping from its synced Drinks payload).
-- Cups are slot items like fryer fries: seated under a tap, poured by clicking
-- THAT tap, and moved between taps with the normal reslot drag (ice, then soda).

local SODA_SLOTS    = 7
local SODA_ICE_SLOT = 4

-- Tap N = the Nth `drinks` CONFIG entry (raw position, valid or not), so tap
-- positions are STABLE: a flavor whose item isn't installed leaves its tap dark
-- instead of every flavor sliding down a slot. The client mirrors this via the
-- `tap` index BuildSyncPayload stamps on each synced drink.
local function flavorForSlot(slot, rid)
    if slot == SODA_ICE_SLOT then return nil end
    local idx = (slot < SODA_ICE_SLOT) and slot or (slot - 1)
    local d = GetDrinks()[idx]
    -- only the cup (input) is a real item — `output` is the flavor KEY (every
    -- poured drink collects as the one `drink_item` item, flavor in metadata)
    -- With `rid`, a flavor whose group this restaurant doesn't carry leaves its
    -- tap dark, exactly like an uninstalled cup item.
    if d and ItemExists(d.input) and (rid == nil or RestaurantHasAccess(rid, d.group)) then return d end
end

-- The valid drinks that actually hold a tap (first six config entries only).
-- With `rid`, group-inaccessible flavors are skipped (their taps stay dark).
local function sodaFlavors(rid)
    local out = {}
    local list = GetDrinks()
    for i = 1, math.min(#list, SODA_SLOTS - 1) do
        local d = list[i]
        if ItemExists(d.input) and (rid == nil or RestaurantHasAccess(rid, d.group)) then out[#out + 1] = d end
    end
    return out
end

local function findAssembly(output)
    for _, a in ipairs(GetAssembly()) do
        if a.output == output then return a end
    end
end

-- The craft a Restaurant Bag's metadata records, by id (the bag's variation identity).
local function findCraft(id)
    if not id or id == "" then return nil end
    for _, cr in ipairs(GetCrafts()) do
        if cr.id == id then return cr end
    end
end

-- ─── finish tools (frosting …) ───────────────────────────────────────────────
-- A finish tool is an inventory item whose prop the player rubs over a finished
-- product at kitchen prep (`finishes` setting): pick a flavor on the tool's card,
-- rub to full coverage, and the target is consumed into the flavored output.

-- Resolve the (tool, target item, flavor id) config triple. Returns whatever
-- levels matched: cfg[, target[, flavor]].
local function findFinish(tool, targetItem, flavorId)
    for _, f in ipairs(GetFinishes()) do
        if f.tool == tool then
            for _, t in ipairs(f.targets or {}) do
                if t.item == targetItem then
                    for _, fl in ipairs(t.flavors or {}) do
                        if fl.id == flavorId then return f, t, fl end
                    end
                    return f, t, nil
                end
            end
            return f, nil, nil
        end
    end
end

-- The finish target an OUTPUT item came from (first match), for rendering and
-- classifying finished products (they live in the tray like any other product).
-- NOTE: with the doughnut collapse, cooked_doughnut is BOTH a plain fryer output and
-- a finish output, so this item-only lookup can't tell plain from frosted — callers
-- that need that distinction must use finishFor(item, meta) below, never this alone.
local function finishForOutput(item)
    for _, f in ipairs(GetFinishes()) do
        for _, t in ipairs(f.targets or {}) do
            if t.output == item then return t, f end
        end
    end
end

-- The target's flavor entry a finished item's meta records (nil when the meta is
-- missing — e.g. stripped by a framework without slot metadata).
local function metaFlavor(target, meta)
    local l = type(meta) == "table" and meta[1]
    local fid = type(l) == "table" and l.flavor or nil
    if not fid or not target then return nil end
    for _, fl in ipairs(target.flavors or {}) do
        if fl.id == fid then return fl end
    end
end

-- The finish a meta layer names by its recorded tool (collapsed scheme: the layer
-- carries `tool`). Returns target, cfg, flavor — nil when the meta names no tool.
local function finishFromMeta(meta)
    local l = type(meta) == "table" and meta[1]
    if type(l) ~= "table" or not l.tool then return nil end
    local f, t, fl = findFinish(l.tool, l.item, l.flavor)
    if t then return t, f, fl end
end

-- Whether/how an INSTANCE is a finished product, metadata-driven. Prefers the tool
-- named in the meta (new collapsed scheme); else, ONLY if the meta records a flavor
-- (legacy meta had no `tool`), falls back to the item's finish output. Returns
-- target, cfg, flavor, or nil. A plain cooked_doughnut (no meta) returns nil, so it
-- is never rendered/treated as frosted — this is the guard the collapse depends on.
local function finishFor(item, meta)
    local t, f, fl = finishFromMeta(meta)
    if t then return t, f, fl end
    local l = type(meta) == "table" and meta[1]
    if type(l) == "table" and l.flavor then
        local t2, f2 = finishForOutput(item)
        if t2 then return t2, f2, metaFlavor(t2, meta) end
    end
end

-- The item a serving-tray arrangement becomes (kitchen prep). Its metadata is the
-- tray's exact layout — every layer with its (dx, dy) offset from the tray centre —
-- so a meal re-renders 1:1 (tray, paper, and each item where it was) whenever it's
-- set back down at prep, and survives the tray/inventory round trips like any other
-- build variation.
local function MealItem() return GetSetting("meal_item", "meal") end

local function broadcastSpawn(it)
    -- prop_id rides along so every client can face the item to its station's heading
    TriggerClientEvent("pickle_restaurants:cooking:spawn", -1, it.uid, it.model, it.x, it.y, it.z, it.state, it.prop_id)
end

-- ─── dual-sided patties ──────────────────────────────────────────────────────

-- The single item a dual patty hands back: burnt dominates, then raw, else
-- cooked. (raw/cooked -> raw, cooked/burnt -> burnt, raw/burnt -> burnt.)
local function combineDualState(sides)
    if sides[1] == "burnt" or sides[2] == "burnt" then return "burnt" end
    if sides[1] == "raw" or sides[2] == "raw" then return "raw" end
    return "cooked"
end

-- The item handed back at the current combined state — also what the hover panel
-- previews as "what you'd collect right now".
local function dualGiveItem(it)
    local state = combineDualState(it.sides)
    if state == "raw" then return it.recipe.input_item
    elseif state == "cooked" then return it.recipe.output_cooked_item
    else return it.recipe.output_burnt_item end
end

-- Per-face cook progress. Only the grill side has a running timer, so the other
-- side's elapsed is frozen at whatever it had banked.
local function sideProgress(it, s)
    local phase = it.sides[s]                          -- raw|cooked = cooking toward next; burnt = done
    local total = (phase == "raw") and it.recipe.cook_ms
               or (phase == "cooked") and it.recipe.burn_ms or 0
    local elapsed = it.elapsed[s] or 0
    if s == it.down and it.phaseStart then
        elapsed = elapsed + (GetGameTimer() - it.phaseStart)
    end
    return { state = phase, total = total or 0, elapsed = elapsed }
end

-- Everything a client needs to render a dual patty and its live status panel:
-- per-face state + cook progress, which face is on the grill, and the melting
-- topping riding the up face (model resolved server-side so the client needs no
-- config lookup).
local function dualPayload(it)
    local give = dualGiveItem(it)
    return {
        uid = it.uid, dual = true, input = it.recipe.input_item,
        x = it.x, y = it.y, z = it.z, prop_id = it.prop_id,
        sides = { sideProgress(it, 1), sideProgress(it, 2) },
        cooking = it.down, flipped = it.flipped,
        topping = it.topping and { item = it.topping.item, state = it.topping.state,
                                   model = ToppingModel(it.topping) } or nil,
        give = give, giveLabel = give and GetItemLabel(give) or nil,
        giveImage = give and GetItemImage(give) or nil,
    }
end

local function broadcastDual(it)
    TriggerClientEvent("pickle_restaurants:cooking:dual", -1, dualPayload(it))
end

-- Banking the down face's accrued cook time and cancelling its pending timeout,
-- so a flip can resume the other face from where it left off.
local function clearSideTimer(it)
    if it.phaseStart then
        local s = it.down
        it.elapsed[s] = (it.elapsed[s] or 0) + (GetGameTimer() - it.phaseStart)
        it.phaseStart = nil
    end
    it.timerToken = (it.timerToken or 0) + 1
end

-- Run the cook timeline for whichever face is currently down. A per-item token
-- invalidates any timeout left over from a previous side/phase.
local function armSideTimer(it)
    local s = it.down
    local st = it.sides[s]
    if st == "burnt" then return end -- this face is done; nothing left to advance
    local total = (st == "raw") and it.recipe.cook_ms or it.recipe.burn_ms
    local remain = math.max(0, (total or 15000) - (it.elapsed[s] or 0))
    it.timerToken = (it.timerToken or 0) + 1
    local token = it.timerToken
    it.phaseStart = GetGameTimer()
    local uid = it.uid
    SetTimeout(remain, function()
        local cur = CookingItems[uid]
        if not cur or cur.timerToken ~= token then return end
        local ds = cur.down
        cur.sides[ds] = (cur.sides[ds] == "raw") and "cooked" or "burnt"
        cur.elapsed[ds] = 0
        cur.phaseStart = nil
        broadcastDual(cur)
        armSideTimer(cur) -- continue cooked -> burnt on the same face
    end)
end

-- ─── oven / fryer (single-state, gated) ──────────────────────────────────────
-- Bakeable/fryable items cook on one raw->cooked->burnt timeline that only advances
-- while a "gate" is open: the oven door is CLOSED, or the fryer basket is LOWERED.
-- Same bank-elapsed + token trick as the per-face patty timer, on a single scalar.

-- Whether an oven door is open (true) — in-memory door state on the prop.
local function doorOpen(prop, door)
    local doors = prop and prop.metadata and prop.metadata.doors
    return doors ~= nil and doors[door] == true
end

-- Whether ONE fryer basket is lowered (frying) — per-slot in-memory state on the
-- prop, mirroring the oven's per-door pattern.
local function basketDown(prop, slot)
    local baskets = prop and prop.metadata and prop.metadata.basketsDown
    return baskets ~= nil and baskets[slot] == true
end

-- Is a station slot free? (oven slots are per-door; fryer slots per-prop.)
local function slotFree(propId, method, door, slot)
    for _, it in pairs(CookingItems) do
        if it.method == method and it.prop_id == propId and it.slot == slot
            and (method ~= "oven" or it.door == door) then
            return false
        end
    end
    return true
end

-- The item you'd collect from a single-state cook right now.
local function cookGiveItem(it)
    if it.state == "raw" then return it.recipe.input_item
    elseif it.state == "cooked" then return it.recipe.output_cooked_item
    else return it.recipe.output_burnt_item end
end

local function singleProgress(it)
    local total = (it.state == "raw") and it.recipe.cook_ms
               or (it.state == "cooked") and it.recipe.burn_ms or 0
    local elapsed = it.elapsed or 0
    if it.gate and it.phaseStart then elapsed = elapsed + (GetGameTimer() - it.phaseStart) end
    return { state = it.state, total = total or 0, elapsed = elapsed, gate = it.gate and true or false }
end

-- Push a live progress snapshot for the hover (mirrors broadcastDual).
local function broadcastGate(it)
    local give = cookGiveItem(it)
    TriggerClientEvent("pickle_restaurants:cooking:progress", -1, {
        uid = it.uid, method = it.method, prog = singleProgress(it),
        give = give, giveLabel = give and GetItemLabel(give) or nil,
        giveImage = give and GetItemImage(give) or nil,
    })
end

-- Bank elapsed + cancel the pending timeout (pause: door opened / basket raised).
local function clearGateTimer(it)
    if it.phaseStart then
        it.elapsed = (it.elapsed or 0) + (GetGameTimer() - it.phaseStart)
        it.phaseStart = nil
    end
    it.timerToken = (it.timerToken or 0) + 1
end

-- Advance raw->cooked->burnt while gated; no-op while the gate is shut.
local function armGateTimer(it)
    if not it.gate or it.state == "burnt" then return end
    local total = (it.state == "raw") and it.recipe.cook_ms or it.recipe.burn_ms
    local remain = math.max(0, (total or 15000) - (it.elapsed or 0))
    it.timerToken = (it.timerToken or 0) + 1
    local token = it.timerToken
    it.phaseStart = GetGameTimer()
    local uid = it.uid
    SetTimeout(remain, function()
        local cur = CookingItems[uid]
        if not cur or cur.timerToken ~= token then return end
        cur.state = (cur.state == "raw") and "cooked" or "burnt"
        cur.model = (cur.state == "cooked") and cur.recipe.cooked_model or cur.recipe.burnt_model
        cur.elapsed = 0; cur.phaseStart = nil
        if cur.stack then
            -- Only the crust layer transforms as it bakes; the toppings stay on top, so
            -- swap that one layer and re-render the whole stack — collapsing to a single
            -- prop is what dropped the sauce/cheese once cooked.
            cur.stack[cur.stackBase or 1] = cur.model
            TriggerClientEvent("pickle_restaurants:cooking:slotSpawn", -1, {
                uid = uid, model = cur.model, prop_id = cur.prop_id, method = cur.method,
                door = cur.door, slot = cur.slot, state = cur.state, stack = cur.stack })
        else
            TriggerClientEvent("pickle_restaurants:cooking:update", -1, uid, cur.model, cur.state, cur.prop_id)
        end
        broadcastGate(cur)
        armGateTimer(cur)
    end)
end

-- ─── soda cups (slot items on a fountain tap) ────────────────────────────────
-- A cup's timeline: empty -> (click a tap) filling -> filled -> (lid) capped.
-- Ice is an independent flag the middle nozzle sets; it can go in before or
-- after the drink but never through a lid.

-- What collecting this cup right now hands back: the poured drink once filled
-- (capped or not), else the empty cup item.
local function sodaGiveItem(it)
    if it.state == "filled" or it.state == "capped" then return it.output end
    return it.input
end

-- The hover chip's label for what collecting hands back: a poured drink reads as
-- its flavor's configured label — the flavor key isn't an inventory item anymore
-- (drinks collect as the one generic `drink_item`), so GetItemLabel can't name it.
local function sodaGiveLabel(it, give)
    if give == it.output then
        for _, dd in ipairs(GetDrinks()) do
            if dd.output == it.output then return dd.label or GetItemLabel(give) end
        end
    end
    return give and GetItemLabel(give) or nil
end

local function sodaProgress(it)
    local elapsed = 0
    if it.state == "filling" and it.phaseStart then elapsed = GetGameTimer() - it.phaseStart end
    return { state = it.state, total = it.fillTotal or 0, elapsed = elapsed,
             gate = it.state == "filling", ice = it.ice and true or false,
             -- what the tap is dispensing while filling ("ice"/"drink") — drives
             -- the client's pour visuals (falling cubes vs. liquid stream)
             fillKind = (it.state == "filling") and it.fillKind or nil,
             needLid = (it.state == "filled") or nil }
end

-- Push a live status snapshot for the cup's hover panel (mirrors broadcastGate).
local function broadcastSoda(it)
    local give = sodaGiveItem(it)
    TriggerClientEvent("pickle_restaurants:cooking:progress", -1, {
        uid = it.uid, method = "soda", prog = sodaProgress(it),
        give = give, giveLabel = sodaGiveLabel(it, give),
        giveImage = give and GetItemImage(give) or nil,
    })
end

-- (Re)spawn payload for a cup at its tap; a capped cup carries the cup+lid build
-- stack so everyone renders the lid through the normal slot-stack machinery, and
-- `ice` drives the client's loose-cube cluster at the rim (hidden once capped).
local function sodaSpawnPayload(it)
    return { uid = it.uid, model = it.model, prop_id = it.prop_id, method = "soda",
             slot = it.slot, state = it.state, stack = it.stack, ice = it.ice or nil }
end

-- one sync entry for a (re)connecting / station-opening client
local function activeEntry(it)
    if it.dual then return dualPayload(it) end
    if it.method == "soda" then
        local give = sodaGiveItem(it)
        return { uid = it.uid, method = "soda", model = it.model, prop_id = it.prop_id,
                 slot = it.slot, state = it.state, prog = sodaProgress(it),
                 stack = it.stack, ice = it.ice or nil,
                 give = give, giveLabel = sodaGiveLabel(it, give),
                 giveImage = give and GetItemImage(give) or nil }
    end
    if it.method == "oven" or it.method == "fry" then
        local give = cookGiveItem(it)
        return { uid = it.uid, method = it.method, model = it.model, prop_id = it.prop_id,
                 door = it.door, slot = it.slot, state = it.state, prog = singleProgress(it),
                 stack = it.stack,
                 give = give, giveLabel = give and GetItemLabel(give) or nil,
                 giveImage = give and GetItemImage(give) or nil }
    end
    return { uid = it.uid, model = it.model, x = it.x, y = it.y, z = it.z, state = it.state, prop_id = it.prop_id }
end

-- A world model for an item: cook recipe outputs/inputs, assembly outputs, drink
-- outputs, else the configurable `prep_models` map (raw veg, toppings, doughs — any
-- item an admin maps to a prop). nil = no prop, and the item falls back to a flat
-- 2D chip. Used so the prep station can spawn a live 3D prop to drag out and stack.
function itemModel(item)
    -- An explicit item->prop mapping (an ingredient's prep prop / a recipe's
    -- serving model) wins over the derived defaults below — that's how a fryer
    -- batch output (cooked as the basket-pile model) is held/stacked as its
    -- single-serving prop instead.
    local mapped = GetPrepModels()[item]
    if mapped then return mapped end
    for _, r in ipairs(RecipeCache) do
        if r.output_cooked_item == item then return r.cooked_model end
        if r.output_burnt_item == item then return r.burnt_model end
        if r.input_item == item then return r.raw_model end
    end
    for _, a in ipairs(GetAssembly()) do if a.output == item then return a.model end end
    for _, dd in ipairs(GetDrinks()) do if dd.output == item then return dd.model end end
    -- A finished/held Restaurant Bag renders as the vessel prop (a sealed bag; its
    -- contents aren't re-rendered once bagged, like a closed box).
    if item == BagItemName() then return BagModel() end
    -- A made takeout box renders as its BASE prop; the hinged lid + the food image
    -- quad inside it are added by the client's takeout branch (compSpec flags it).
    if item == BoxItemName() then return BoxBaseModel() end
    -- A melting-topping ingredient with no explicit prep prop falls back to its
    -- APPLIED (unmelted) slice — the melted variant is only ever a live melt
    -- state, never the stackable/held slice.
    local melting = MeltingToppingFor(item)
    if melting then return melting.melts.applied_model end
    -- A layer-tool (condiment) item renders as its `applied_model` sauce everywhere
    -- it appears in a build stack (prep table, tray, meal, decompose) — the bottle
    -- is only the drag applicator, never the stacked prop.
    for _, c in ipairs(GetCondiments()) do
        if c.item == item then return c.applied_model end
    end
    -- A finish output with no recorded flavor (plain instance / a framework that
    -- strips slot metadata): first flavor for a replace-mode product, the bare
    -- target's prop for an overlay-mode one. finishRender handles flavored metas.
    local ft = finishForOutput(item)
    if ft then
        if (ft.mode or "replace") ~= "overlay" then
            local fl = (ft.flavors or {})[1]
            if fl and fl.model then return fl.model end
        end
        return itemModel(ft.item)
    end
end

-- The dual-sided recipe an item belongs to (matched by raw input or cooked/burnt
-- output), or nil. Used so a cooked patty pulled from the tray renders as the
-- full two-faced patty (+ cheese) while dragging, not a single half.
local function dualRecipeForItem(item)
    for _, r in ipairs(RecipeCache) do
        if (r.dual_sided == true or tonumber(r.dual_sided) == 1)
            and (r.output_cooked_item == item or r.output_burnt_item == item or r.input_item == item) then
            return r
        end
    end
end

-- Where an item lives: cook/assembly outputs are held in the per-player "Cooked
-- Items" tray, everything else (raw components) in the real inventory. Governs
-- which store a decomposed component is refunded to and which reservation source
-- it uses so the existing build/remove/refund paths keep working unchanged.
local function isTrayItem(item)
    for _, r in ipairs(RecipeCache) do
        if r.output_cooked_item == item or r.output_burnt_item == item then return true end
    end
    for _, a in ipairs(GetAssembly()) do
        if a.output == item then return true end
    end
    if finishForOutput(item) then return true end -- finished products are products
    -- the generic collected drink lives in the tray too (its flavor is metadata),
    -- so a drink layer in a meal refunds back to the tray with its flavor intact
    if item == GetSetting("drink_item", "drink") then return true end
    -- both takeaway vessels are kitchen PRODUCTS: a made takeout box (a bag-kind
    -- food) and a packed Restaurant Bag are collected into the tray, never bought
    -- into the ingredient pool
    if item == BoxItemName() or item == BagItemName() then return true end
    -- a baking-tray output (an assembled-but-uncooked batter/dough) is a tray-only
    -- uncooked intermediate — it lives in the tray until it's baked
    for _, b in ipairs(GetBakingList()) do
        for _, t in ipairs(b.trays or {}) do
            if t.output == item then return true end
        end
    end
    return false
end

-- A "pool item" is a raw simple ingredient (raw patty, bun, cheese, cup, finish
-- tool…) — anything that is NOT a tray-held PRODUCT and not the meal item. These
-- are drawn PREFERENTIALLY from the shared restaurant STOCK POOL (StockCache),
-- falling back to the cook's personal inventory when the pool is dry (see
-- poolInvCount/poolInvConsume), and are refunded to the pool. Products keep their
-- build-stack metadata and continue to live in the tray / inventory slots.
local function isPoolItem(item)
    return item ~= nil and item ~= "" and not isTrayItem(item) and item ~= MealItem()
end

-- Hybrid raw-ingredient sourcing. A pool item is drawn from the shared restaurant
-- STOCK POOL whenever the pool CARRIES it, and falls back to the cook's PERSONAL
-- inventory only when the pool is dry — a stocked larder is always spent before
-- anyone's pockets. The ingredient bar therefore shows the pool figure when there
-- is stock and the personal figure otherwise (never both). Products / the meal
-- item are never pool items and always come from inventory.
--   poolInvCount  -> (count, fromPool) available to `src` for one raw ingredient.
--   poolInvConsume-> spend `n` (default 1), mirroring poolInvCount's pool-first
--                    choice. Call only once poolInvCount confirmed enough is held.
-- (Both are yield-free, so a count immediately followed by a consume always agree.)
local function poolInvCount(src, rid, item)
    if isPoolItem(item) and (GetStockCount(rid, item) or 0) > 0 then
        return GetStockCount(rid, item), true
    end
    return (Inventory.GetItemCount(src, item) or 0), false
end

local function poolInvConsume(src, rid, item, n)
    n = n or 1
    if isPoolItem(item) and (GetStockCount(rid, item) or 0) > 0 then
        RemoveStock(rid, item, n)
    else
        Inventory.RemoveItem(src, item, n)
    end
end

-- The migrated form of a bare topped instance is a one-layer "self stack"
-- ({ { item = <the item>, top = ... } }, written by the tray-cheese migration and
-- by collect below). Returns that layer's topping — normalized via LayerTopping,
-- so a legacy numeric-cheese layer decodes too — or nil for any other meta shape.
local function selfStackTop(item, meta)
    if type(meta) == "table" and #meta == 1 and type(meta[1]) == "table"
        and meta[1].item == item and not meta[1].stack then
        return LayerTopping(meta[1])
    end
    return nil
end

-- The ordered component layers a product decomposes into: its stored build stack
-- (order, topping and half-split intact) or, failing that, the recipe's plain
-- components. Tolerates the older aggregated `count` metadata format; a legacy
-- layer's numeric cheese normalizes into `top` here (LayerTopping), so nothing
-- downstream ever reads the retired field.
local function compsFromMeta(asm, meta)
    local comps = {}
    if type(meta) == "table" and #meta > 0 then
        for _, m in ipairs(meta) do
            for _ = 1, (tonumber(m.count) or 1) do
                -- a product layer keeps its own nested build stack (m.stack) so a
                -- pizza inside a burger comes back out as THAT pizza, toppings intact;
                -- a meal layer keeps its (dx, dy) tray offset so the arrangement survives
                comps[#comps + 1] = { item = m.item, top = LayerTopping(m), half = m.half,
                                      stack = (type(m.stack) == "table" and #m.stack > 0) and m.stack or nil,
                                      dx = tonumber(m.dx), dy = tonumber(m.dy) }
            end
        end
    else
        for _, c in ipairs(asm.components or {}) do comps[#comps + 1] = { item = c } end
    end
    return comps
end

-- The ordered component MODELS a build stack renders as — the given `meta`
-- resolved to props, bottom-to-top (falling back to the item's assembly components
-- when it has no recorded stack). nil when it resolves to fewer than two props
-- (nothing to stack; the base model suffices). Shared by the oven/fryer placement
-- and the tray payload so the drag preview and the placed prop render the same stack.
-- A `halves` ingredient (a bun) is ONE item rendered as two HALF props (top/bottom)
-- so a burger sits bottom-half → fillings → top-half. itemModel only knows the
-- single prep prop, so the render stack must pick the half-specific model here or
-- the build comes out with two identical crowns. The client mirrors the same
-- halves config from the synced `ingredients` payload.
local function layerModel(c)
    if c.half then
        local h = IngredientHalves(c.item)
        local m = h and ((c.half == "top") and h.top_model or h.bottom_model)
        if m then return m end
    end
    return itemModel(c.item)
end

local function stackModelsFromMeta(item, meta)
    local asm = findAssembly(item)
    if not asm and not (type(meta) == "table" and #meta > 0) then return nil end
    local models = {}
    for _, c in ipairs(compsFromMeta(asm or { components = {} }, meta)) do
        local m = layerModel(c)
        if m then models[#models + 1] = m end
        -- a topped layer inside a product tower renders its melt prop right on top
        local tm = c.top and ToppingModel(c.top) or nil
        if tm then models[#models + 1] = tm end
    end
    return (#models > 1) and models or nil
end

-- The recipe (and cook state) an item is the OUTPUT of — how a cooked/burnt
-- product (cooked_pizza) finds its way back to the raw recipe/assembly it was
-- baked from, so its recorded build stack can still be rendered and described.
local function recipeForOutput(item)
    for _, r in ipairs(RecipeCache) do
        if r.output_cooked_item == item then return r, "cooked" end
        if r.output_burnt_item == item then return r, "burnt" end
    end
end

-- ─── tray expiration (freshness) ─────────────────────────────────────────────
-- How long (seconds) a collected item stays fresh in the tray: the recipe's own
-- `expire_seconds` if set (NULL = fall through), else the global default setting.
-- 0 = never expires. Non-recipe items (assembled products, meals, drinks) only use
-- the global default.
local function ExpireSecondsFor(item)
    local r = recipeForOutput(item)
    if r and r.expire_seconds ~= nil then
        local n = tonumber(r.expire_seconds)
        if n and n >= 0 then return n end
    end
    return math.max(0, math.floor(tonumber(GetSetting("cooked_expire_seconds", 0)) or 0))
end

-- The epoch second a tray row expires at, or nil if it never expires.
local function TrayExpiresAt(item, cookedAt)
    local secs = ExpireSecondsFor(item)
    if secs <= 0 or not cookedAt or cookedAt <= 0 then return nil end
    return cookedAt + secs
end

-- Drop every spoiled row from one player's tray (cache + DB). Returns true if it
-- removed anything (so callers can resync). Uses GetTray's grouped entries only for
-- the cookedAt/item; removal is by the full item row.
local function PurgeExpiredTray(rid, identifier)
    local byKey = TrayCache[rid] and TrayCache[rid][identifier]
    if not byKey then return false end
    local now = os.time()
    local removed = false
    -- collect first (don't mutate while iterating), then remove whole rows
    local spoiled = {}
    for _, e in pairs(byKey) do
        local exp = TrayExpiresAt(e.item, e.cookedAt)
        if exp and now >= exp and (e.count or 0) > 0 then
            spoiled[#spoiled + 1] = { item = e.item, count = e.count }
        end
    end
    for _, s in ipairs(spoiled) do
        if RemoveTray(rid, identifier, s.item, s.count) then removed = true end
    end
    return removed
end

-- The online source for an identifier, or nil (offline). GetPlayers() returns
-- string ids; GetIdentifier resolves each to its framework identifier.
local function sourceForIdentifier(identifier)
    for _, src in ipairs(GetPlayers()) do
        local s = tonumber(src)
        if s and GetIdentifier(s) == identifier then return s end
    end
end

-- Sweep every tray periodically so food spoils even when no one has the station
-- open. When a sweep clears anything for an ONLINE player, nudge them to re-fetch
-- the tray so the NUI drops it (the client also counts down locally between sweeps).
CreateThread(function()
    while true do
        Wait(15000)
        for rid, byId in pairs(TrayCache or {}) do
            for identifier in pairs(byId) do
                if PurgeExpiredTray(rid, identifier) then
                    local src = sourceForIdentifier(identifier)
                    if src then TriggerClientEvent("pickle_restaurants:cooking:trayDirty", src) end
                end
            end
        end
    end
end)

-- Prepend a recipe's container tray to a cooked/burnt output's render stack, so a
-- containered bake (the cake sheet in its tin) renders as container + food
-- everywhere it appears. Returns the (possibly created) stack, or nil untouched.
local function withContainer(recipe, models, baseModel)
    if not (recipe and recipe.container_model and recipe.container_model ~= "") then return models end
    -- A batch recipe (output_count > 1, e.g. the six-cookie tray) is collected as
    -- individual servings, so the container tray rides only the cooking batch in the
    -- oven — never each collected output. A whole bake (cake, output_count 1) keeps it.
    if (tonumber(recipe.output_count) or 1) > 1 then return models end
    models = models or { baseModel }
    table.insert(models, 1, recipe.container_model)
    return models
end

-- A collected drink is a CAPPED cup — the lid always presses on before it
-- collects — so a drink output renders as its cup+lid tower everywhere at prep
-- (bar card, dragged/placed part, meal layer), never the bare cup. Mirrors
-- withContainer: returns models untouched for anything that isn't a drink.
local function withLid(item, models, baseModel)
    local isDrink = false
    for _, dd in ipairs(GetDrinks()) do
        if dd.output == item then isDrink = true break end
    end
    if not isDrink then return models end
    models = models or { baseModel }
    models[#models + 1] = GetSetting("drink_lid_model", "pickle_drink_lid_01")
    return models
end

-- A "side" (fries…) is served INSIDE a container box — kitchen equipment like the
-- drink lid (no inventory item; visual-only). The box is the BASE layer (food sits
-- in it), so it prepends to the build stack the way the cake tin does in
-- withContainer. Returns models untouched for anything that isn't a listed side.
local function withSideContainer(item, models, baseModel)
    local box = GetSetting("side_container_model", "pickle_side_container_01")
    if not box or box == "" then return models end
    local isSide = false
    for _, s in ipairs(GetSetting("side_container_items", {})) do
        if s == item then isSide = true break end
    end
    if not isSide then return models end
    models = models or { baseModel }
    table.insert(models, 1, box) -- box first = the base the serving rests in
    return models
end

-- The serving-container stack a bare collected item renders as: a drink's cup+lid,
-- a side's box+food. Visual-only equipment either way. nil for anything served
-- bare (so callers keep whatever stack they already built).
local function servedStack(item, baseModel)
    return withLid(item, nil, baseModel) or withSideContainer(item, nil, baseModel)
end

-- ─── the ONE generic drink item ──────────────────────────────────────────────
-- Every poured drink collects as the `drink_item` setting's item ("Restaurant
-- Drink"), the flavor riding as build-stack metadata — ONE meta layer holding the
-- drinks[].output key ({ { item = "soda" } }) — exactly like meals. TraySig makes
-- each flavor its own tray/inventory variation; the flavor key still resolves its
-- cup model via the drinks config even though it's no longer an item.
local function DrinkItem() return GetSetting("drink_item", "drink") end

-- The flavor config a drink instance's meta records, or nil for a plain/unknown one.
local function drinkFlavor(meta)
    local l = type(meta) == "table" and meta[1]
    if type(l) ~= "table" or not l.item then return nil end
    for _, dd in ipairs(GetDrinks()) do
        if dd.output == l.item then return dd end
    end
end

-- A flavor's capped-cup render (drinks always collect capped).
local function drinkRender(dd)
    return { dd.model, GetSetting("drink_lid_model", "pickle_drink_lid_01") }
end

-- How a finished (frosted…) item renders: replace-mode = the recorded flavor's
-- model IS the whole product; overlay-mode = the target's prop with the flavor
-- model stacked on top. Metadata-driven (finishFor) so a plain instance renders
-- as nothing here (its caller keeps the base model). Returns model, stack (one nil).
local function finishRender(item, meta)
    local target, _, ffl = finishFor(item, meta)
    if not target then return nil, nil end
    local fl = ffl or (target.flavors or {})[1]
    -- Applied OVER another finished product (e.g. sprinkles on a frosted doughnut):
    -- render that nested product's whole tower as the base so its flavor (the
    -- frosting) still shows, then stack this flavor (the sprinkles) on top of it.
    local nested = type(meta) == "table" and meta[1] and meta[1].stack
    local baseStack
    if type(nested) == "table" and nested[1] and (nested[1].tool or nested[1].flavor)
        and finishFor(target.item, nested) then
        local nm, ns = finishRender(target.item, nested)
        baseStack = ns or (nm and { nm }) or nil
    end
    local base = itemModel(target.item)
    if (target.mode or "replace") == "overlay" then
        if baseStack then
            if fl and fl.model then baseStack[#baseStack + 1] = fl.model end
            return nil, baseStack
        end
        if fl and fl.model and base then return nil, { base, fl.model } end
        return base, nil
    end
    return (fl and fl.model) or base, nil
end

-- ─── the two takeaway vessels ────────────────────────────────────────────────
-- A TAKEOUT BOX instance is a bag-kind food (soup, salad…): its food id rides the
-- first meta layer (the `craft` field — the same flag TraySig appends `~` for, so
-- the POS variation grammar is byte-stable across the rename). Returns that id, or
-- nil. LEGACY SHIM: before the takeout box existed these foods were made in — and
-- collected as — the Restaurant Bag, so a bag instance carrying the flag is read as
-- a box too (player inventory slots can't be migrated server-side).
local function boxFoodId(item, meta)
    if item ~= BoxItemName() and item ~= BagItemName() then return nil end
    local id = type(meta) == "table" and meta[1] and meta[1].craft
    return (type(id) == "string" and id ~= "") and id or nil
end

-- An ABSOLUTE image url for an item — what a DUI/render target needs (the NUI can
-- resolve a bare filename itself, a CEF page loading a texture cannot). An admin
-- override is already absolute; a catalogue filename is resolved against the
-- inventory's image folder.
function AbsItemImage(item)
    if not item or item == "" then return nil end
    local img = GetItemImage(item)
    if type(img) == "string" and (img:find("^nui://") or img:find("^https?://")) then return img end
    return InvImageUrl(InventoryImageBase(), item, img)
end

-- What a MADE takeout box shows, all authored on the food itself — it never borrows
-- an inventory item's identity. Returns its label, the ITEM picture (the hotbar/tray
-- card, the POS, the inventory slot) and the BOX picture (painted on the quad inside
-- the open box, falling back to the item picture). Both fall back further to the
-- legacy display item's art and then the box item's, so nothing is ever blank.
local function boxFoodRender(cr)
    if not cr then return nil, nil, nil, nil end
    local box = BoxItemName()
    local boxUrl, boxCrop = FoodBoxImageUrl(cr, box)
    return cr.label, FoodImageUrl(cr, box), boxUrl, boxCrop
end

-- ONE build-stack layer described for a CONSUMER: what a customer sees when they
-- open a Restaurant Bag or look at a meal in front of them. Every generic item
-- resolves to what it actually is — a drink to its flavor, a takeout box to its
-- food, everything else to its own label/art. `drink` marks it for the drinking
-- animation (and thirst rather than hunger). Global: the consume + dining modules
-- read it, and they must agree with the kitchen's own naming exactly.
function LayerDisplay(l)
    if type(l) ~= "table" or not l.item then return nil end
    local item = l.item
    local food = FoodForItem(item, l.stack)
    local out = { item = item,
                  label = (food and food.label) or GetItemLabel(item),
                  image = FoodImageUrl(food, item) }
    if item == DrinkItem() then
        local dd = drinkFlavor(l.stack)
        if dd then
            out.label = dd.label or out.label
            out.drink = true
            if DrinkFlavorImage then out.image = DrinkFlavorImage(dd.output) or out.image end
        else
            out.drink = true
        end
        return out
    end
    local fid = boxFoodId(item, l.stack)
    if fid then
        local label, image = boxFoodRender(findCraft(fid))
        out.label = label or out.label
        out.image = image or out.image
        return out
    end
    return out
end

-- How a build-stack layer is COUNTED and NAMED in a contents list. Normally that's
-- just its item, but a GENERIC VESSEL item is only told apart by what it holds — a
-- takeout box by its food, a drink by its flavor — so a meal tray or a bag lists
-- "Soup" and "Cola" with their own art instead of two indistinguishable "Takeout
-- Box" rows. Returns: grouping key, label, image, real item name.
local function layerIdentity(l)
    local d = LayerDisplay(l)
    local key = l.item
    local fid = boxFoodId(l.item, l.stack)
    if fid then
        key = "craft:" .. fid
    elseif l.item == DrinkItem() then
        local flavor = type(l.stack) == "table" and l.stack[1] and l.stack[1].item
        if flavor then key = "drink:" .. tostring(flavor) end
    end
    return key, (d and d.label) or GetItemLabel(l.item), (d and d.image) or GetItemImage(l.item), l.item
end

-- A client part spec for one decomposed layer (no reservation id — that's stamped on
-- when the take-apart actually commits). Shared by the drag preview and the commit so
-- the previewed stack and the placed stack are identical.
local function compSpec(c)
    local dual = dualRecipeForItem(c.item) and true or false
    local topv = LayerTopping(c) -- the comp's `top` topping (nil if none)
    local spec = {
        item = c.item, source = isTrayItem(c.item) and "tray" or "inv", half = c.half,
        model = itemModel(c.item), dual = dual,
        -- the melting topping riding this part; the model is resolved server-side
        -- and only rendered on a dual (two-faced) part, like the grill melt
        top = topv,
        topModel = (topv and dual) and ToppingModel(topv) or nil,
        dx = c.dx, dy = c.dy, -- meal layers ride with their tray offset
    }
    -- a finished (frosted…) product renders by its recorded flavor — the flavor
    -- model itself (replace) or target + flavor overlay (overlay). Metadata-driven so
    -- a plain cooked_doughnut (no finish meta) falls through to the normal path.
    local ft, ftcfg = finishFor(c.item, c.stack)
    if ft then
        local model, stack = finishRender(c.item, c.stack)
        if model then spec.model = model end
        if stack then spec.stack = stack end
        if c.stack then spec.sig = TraySig(c.stack) end
        spec.finishTool = ftcfg and ftcfg.tool
        return spec
    end
    -- the generic drink item renders as its recorded flavor's capped cup — the
    -- flavor key (meta layer) resolves the cup model from the drinks config
    if c.item == DrinkItem() then
        local dd = drinkFlavor(c.stack)
        if dd then
            spec.model = dd.model
            spec.stack = drinkRender(dd)
            if c.stack then spec.sig = TraySig(c.stack) end
            return spec
        end
    end
    -- a made takeout box renders as the box PAIR (base + hinged lid, swung open) with
    -- the food's image drawn on a quad inside it — the components themselves are never
    -- re-rendered (a soup has no tower). The client's takeout branch owns the pair.
    local fid = boxFoodId(c.item, c.stack)
    if fid then
        local label, _, boxImage, boxCrop = boxFoodRender(findCraft(fid))
        spec.takeout = true
        spec.model   = BoxBaseModel()
        spec.lidModel = BoxLidModel()
        spec.label   = label
        spec.image   = boxImage -- makePart paints this on the quad inside the box
        spec.imageCrop = boxCrop
        spec.stack   = nil
        if c.stack then spec.sig = TraySig(c.stack) end
        return spec
    end
    -- the generic restaurant_bag renders as its SEALED vessel prop — the contents
    -- aren't shown once bagged (like a closed box). The contents ride in meta only,
    -- for POS matching and for the customer eating out of it.
    if c.item == BagItemName() then
        spec.model = BagModel()
        spec.stack = nil
        if c.stack then spec.sig = TraySig(c.stack) end
        return spec
    end
    -- a nested product renders as its whole recorded stack (crust swapped to its
    -- cook state), not its single base model, and addresses that exact variation.
    -- A stackless legacy instance of an assembled cook output (a cooked pizza
    -- collected before stacks survived the cook) falls back to its BASE recipe
    -- stack so it never renders as a bare crust.
    local models = c.stack and stackModelsFromMeta(c.item, c.stack) or nil
    if c.stack then spec.sig = TraySig(c.stack) end
    if not models and not c.stack then
        local rout = recipeForOutput(c.item)
        if rout and findAssembly(rout.input_item) then
            models = stackModelsFromMeta(rout.input_item, nil)
        end
    end
    if models then
        local rout, state = recipeForOutput(c.item)
        if rout then
            for i, m in ipairs(models) do
                if m == rout.raw_model then
                    models[i] = (state == "burnt") and rout.burnt_model or rout.cooked_model
                    break
                end
            end
            spec.state = state
        end
        spec.stack = models
    end
    -- a collected drink renders cup+lid, a side renders in its box — never bare
    if not spec.stack and spec.model then
        spec.stack = servedStack(c.item, spec.model)
    end
    return spec
end

-- A readable component list for an item's build stack (half layers collapse to one
-- whole item) — drives the inventory tooltip so a variation reads e.g. "Bun, Beef
-- Patty, Lettuce, Tomato".
local function stackDescription(stack)
    if type(stack) ~= "table" then return nil end
    -- a finished product's single flavor layer reads as its flavor, not a parts
    -- list: "Strawberry Cake" instead of "Cake"
    if #stack == 1 and type(stack[1]) == "table" and stack[1].flavorLabel then
        return stack[1].flavorLabel .. " " .. GetItemLabel(stack[1].item)
    end
    local order, counts, labels = {}, {}, {}
    for _, l in ipairs(stack) do
        local key, label = layerIdentity(l)
        if not counts[key] then order[#order + 1] = key; counts[key] = 0; labels[key] = label end
        counts[key] = counts[key] + (l.half and 0.5 or 1.0)
    end
    local parts = {}
    for _, key in ipairs(order) do
        local n = math.ceil(counts[key])
        local lbl = labels[key]
        parts[#parts + 1] = (n > 1) and (n .. "x " .. lbl) or lbl
    end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

-- The build stack as a structured, ordered component list ({item, label, image,
-- count} per distinct component, half layers collapsing to one whole) — drives the
-- tray hover tooltip so a variation shows exactly what it's made of, with icons.
local function stackComponents(meta)
    if type(meta) ~= "table" or #meta == 0 then return nil end
    local order, counts, view = {}, {}, {}
    for _, l in ipairs(meta) do
        local key, label, image, item = layerIdentity(l)
        for _ = 1, (tonumber(l.count) or 1) do
            if not counts[key] then
                order[#order + 1] = key; counts[key] = 0
                view[key] = { item = item, label = label, image = image }
            end
            counts[key] = counts[key] + (l.half and 0.5 or 1.0)
        end
    end
    local out = {}
    for _, key in ipairs(order) do
        local v = view[key]
        out[#out + 1] = { item = v.item, label = v.label, image = v.image, count = math.ceil(counts[key]) }
    end
    return out
end

-- What a build stack has ON TOP of its base recipe — the toppings that tell two
-- otherwise-identical tray entries apart, structured ({item, label, image, count})
-- so the card can render topping icons. The base recipe is the item's own assembly
-- or, for a cook output, the assembly of its raw input. nil when the stack is
-- exactly the base recipe (no toppings worth calling out).
local function extrasComponents(item, meta)
    if type(meta) ~= "table" or #meta == 0 then return nil end
    local order, counts, view = {}, {}, {}
    for _, l in ipairs(meta) do
        local key, label, image, lit = layerIdentity(l)
        for _ = 1, (tonumber(l.count) or 1) do
            if not counts[key] then
                order[#order + 1] = key; counts[key] = 0
                view[key] = { item = lit, label = label, image = image }
            end
            counts[key] = counts[key] + (l.half and 0.5 or 1.0)
        end
    end
    local asm = findAssembly(item)
    if not asm then
        local r = recipeForOutput(item)
        asm = r and findAssembly(r.input_item)
    end
    -- a base component is a plain ingredient, so its identity key IS its item name
    for _, c in ipairs(asm and asm.components or {}) do
        if counts[c] then counts[c] = counts[c] - 1 end
    end
    local parts = {}
    for _, key in ipairs(order) do
        local n = math.ceil(counts[key])
        if n > 0 then
            local v = view[key]
            parts[#parts + 1] = { item = v.item, label = v.label, image = v.image, count = n }
        end
    end
    return #parts > 0 and parts or nil
end

-- ─── inventory variations ────────────────────────────────────────────────────
-- An inventory-held product carries its build stack on its SLOT metadata (written
-- by trayToInventory's buildInvMeta). Where the bridge exposes slots (ox_inventory /
-- qb), these helpers group and consume by exact variation, so a pepperoni pizza item
-- stays a pepperoni pizza through the round-trip. Without slot access they degrade to
-- plain per-item counts.

-- The distinct build-stack (sig) variations of an item in a player's inventory:
-- array of { sig, count, meta }.
local function invVariations(src, item)
    if not Inventory.GetItemSlots then
        local count = Inventory.GetItemCount(src, item) or 0
        return (count > 0) and { { sig = "", count = count } } or {}
    end
    local groups, order = {}, {}
    for _, s in ipairs(Inventory.GetItemSlots(src, item) or {}) do
        local m = type(s.metadata) == "table" and s.metadata or {}
        local stack = type(m.stack) == "table" and m.stack or nil
        local sig = TraySig(stack)
        if not groups[sig] then
            groups[sig] = { sig = sig, count = 0, meta = stack }
            order[#order + 1] = sig
        end
        groups[sig].count = groups[sig].count + (s.count or 1)
    end
    local out = {}
    for _, k in ipairs(order) do out[#out + 1] = groups[k] end
    return out
end

-- Count / stack-meta / remove for one exact inventory variation. sig nil = the
-- whole item regardless of metadata (the raw-component behaviour).
local function invVariationCount(src, item, sig)
    if sig == nil then return Inventory.GetItemCount(src, item) or 0 end
    local n = 0
    for _, v in ipairs(invVariations(src, item)) do
        if v.sig == sig then n = n + v.count end
    end
    return n
end

local function invVariationMeta(src, item, sig)
    if sig == nil then return nil end
    for _, v in ipairs(invVariations(src, item)) do
        if v.sig == sig then return v.meta end
    end
end

local function removeInvVariation(src, item, sig, count)
    if sig == nil or not Inventory.GetItemSlots then
        Inventory.RemoveItem(src, item, count)
        return
    end
    for _, s in ipairs(Inventory.GetItemSlots(src, item) or {}) do
        if count <= 0 then return end
        local m = type(s.metadata) == "table" and s.metadata or {}
        local stack = type(m.stack) == "table" and m.stack or nil
        if TraySig(stack) == sig then
            local take = math.min(count, s.count or 1)
            Inventory.RemoveItemSlot(src, item, take, s.slot)
            count = count - take
        end
    end
end

-- ─── ingredient list for the bottom bar ──────────────────────────────────────

lib.callback.register("pickle_restaurants:cooking:getIngredients", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return {} end
    local station = StationType(prop)
    local rid = prop.restaurant_id -- raw ingredients are counted from the restaurant's shared stock pool
    local out = {}

    if station == "fryer" or station == "stovetop" then
        for _, recipe in ipairs(RecipeCache) do
            -- Recipes that reference a missing item are hidden until fixed. Inputs
            -- that are themselves a PRODUCT/INTERMEDIATE aren't raw ingredients — they
            -- file under the "Uncooked Items" tab (getTray flags them) and are dragged
            -- into their station from there: an assembled uncooked pizza (findAssembly)
            -- OR a tray-held bake intermediate (cookie dough / cake batter — raw_cookie /
            -- raw_cake, isTrayItem). Only true raw pool ingredients (a raw patty) belong
            -- on this bar. A recipe whose group this restaurant doesn't carry is hidden too.
            if recipe.station == station and IsRecipeValid(recipe)
                and not findAssembly(recipe.input_item) and not isTrayItem(recipe.input_item)
                and RestaurantHasAccess(prop.restaurant_id, recipe.group) then
                local count = poolInvCount(src, rid, recipe.input_item)
                if count and count > 0 then
                    out[#out + 1] = { kind = "cook", item = recipe.input_item, label = GetItemLabel(recipe.input_item),
                                      image = GetItemImage(recipe.input_item), count = count }
                end
            end
        end
        -- Melting toppings (a cheese slice…): every `melts`-flagged ingredient is a
        -- card you drag onto a cooked dual-sided item (stovetop only). Each renders
        -- its real applied-slice prop in 3D as it drags (no 2D pill).
        if station == "stovetop" then
            for _, ing in ipairs(GetIngredientsCfg()) do
                if type(ing.melts) == "table" and ing.melts.applied_model and ItemExists(ing.item) then
                    local count = poolInvCount(src, rid, ing.item)
                    if count > 0 then
                        out[#out + 1] = { kind = "topping", item = ing.item, label = GetItemLabel(ing.item),
                                          image = GetItemImage(ing.item), count = count,
                                          model = ing.melts.applied_model or ing.model }
                    end
                end
            end
        end
    elseif station == "soda_machine" then
        -- ONE cup card per distinct cup item across the taps (the default flavors
        -- all share one cup) — the flavor is picked at the tap, not on the bar.
        local seen = {}
        for _, drink in ipairs(sodaFlavors(prop.restaurant_id)) do
            if not seen[drink.input] then
                seen[drink.input] = true
                local count = poolInvCount(src, rid, drink.input)
                out[#out + 1] = { kind = "drink", item = drink.input, label = GetItemLabel(drink.input),
                                  image = GetItemImage(drink.input), count = count }
            end
        end
        -- The lid pressed onto a filled cup: kitchen EQUIPMENT like the prep
        -- station's serving tray, not an inventory item — cups come with lids,
        -- so the tool is always on the bar and never consumed.
        out[#out + 1] = { kind = "lid", item = "cup_lid", label = _L("cook_equip_cup_lid"),
                          model = GetSetting("drink_lid_model", "pickle_drink_lid_01") }
    elseif station == "kitchen_prep" then
        -- Interactive build: the bar lists the raw components (held in inventory) used
        -- across assembly recipes, PLUS any other mapped prep ingredient — optional
        -- toppings like pepperoni that aren't a *required* component of a recipe but can
        -- be added to a stack as an alteration. Cooked components come from the tray.
        -- The serving tray leads the bar: kitchen equipment (not an inventory item)
        -- you drag onto the table, arrange food on, and turn into ONE meal item.
        -- Never gated on the meal item existing — equipment doesn't require items;
        -- the meal lives in the tray holding either way (only "→ inventory" needs
        -- the item installed).
        out[#out + 1] = { kind = "tray", item = MealItem(), label = _L("cook_equip_serving_tray"),
                          image = GetItemImage(MealItem()) }
        -- The pizza box rides right next to it: the same equipment pattern (never
        -- an inventory item). Drag it onto the table, click the lid to swing it
        -- open, drop a pizza in (crust-based piles only), and box it up into the
        -- same meal item — flagged so it sets back down as its box, not a tray.
        out[#out + 1] = { kind = "pizzabox", item = MealItem(), label = _L("cook_equip_pizza_box"),
                          image = GetItemImage(MealItem()) }
        -- The TAKEOUT BOX: where every bag-KIND food is created (soup, salad — the
        -- non-stack miscellaneous foods). Same free-equipment pattern, same hinged
        -- lid as the pizza box. Drag it out, open the lid, drop the food's
        -- components in (each seats as its 3D prop, or a 2D pill if the item has no
        -- model), then "Create <food>" — the contents become ONE takeout_box showing
        -- that food's image inside.
        out[#out + 1] = { kind = "takeout", item = BoxItemName(), label = _L("cook_equip_takeout_box"),
                          image = GetItemImage(BoxItemName()),
                          model = BoxBaseModel() }
        -- The RESTAURANT BAG: the takeaway carrier — the serving tray's sibling for
        -- food leaving the restaurant. Drop finished foods and drinks in, "Bag It
        -- Up", and they become ONE restaurant_bag the customer eats out of. Only
        -- "→ inventory" needs the bag item installed; the bag lives in the tray
        -- holding either way, like the tray.
        out[#out + 1] = { kind = "bag", item = BagItemName(), label = _L("cook_equip_bag"),
                          image = GetItemImage(BagItemName()),
                          model = BagModel() }
        -- Baking trays (cake tin / cookie tray) follow the same free-equipment
        -- pattern: drag one out, rub the matching fill tool's mix over it to fill
        -- it, then drag the filled tray into the hotbar to collect its oven-ready
        -- output. Also filed under the COOKED ITEMS tab. Every fill tool's mix is
        -- captured in `bakeMix` so the component loop below can exclude the mixes
        -- (each has its own applicator card, like the finish tools).
        local bakeMix = {}
        for _, b in ipairs(GetBakingList()) do
            if b.mix_item then bakeMix[b.mix_item] = true end
            for _, t in ipairs(b.trays or {}) do
                -- the output is a tray-only uncooked intermediate (batter/dough),
                -- so it needn't be an installed item — just a configured tray kind +
                -- model the client can render (BuildSyncPayload ships it as a product)
                if t.kind and t.tray_model
                    and RestaurantHasAccess(prop.restaurant_id, t.group) then
                    out[#out + 1] = { kind = "baketray", subkind = t.kind, label = t.label or t.kind }
                end
            end
        end
        -- Finish tools (frosting…) are draggable applicators, flavor picked on the
        -- card itself. The card shows the union of every valid target's flavors;
        -- per-target validity is enforced while rubbing and again at apply time.
        local finishTools = {}
        for _, f in ipairs(GetFinishes()) do
            if f.tool and ItemExists(f.tool) and RestaurantHasAccess(prop.restaurant_id, f.group) then
                finishTools[f.tool] = true
                local count = poolInvCount(src, rid, f.tool)
                if count > 0 then
                    local flavors, seenFl = {}, {}
                    for _, t in ipairs(f.targets or {}) do
                        -- a target/output that's a tray PRODUCT (a frosted doughnut is
                        -- a finish output, never an installed item) is valid too, so the
                        -- tool shows whenever it's held — same as frosting.
                        if (ItemExists(t.item) or isTrayItem(t.item))
                            and (ItemExists(t.output) or isTrayItem(t.output)) then
                            for _, fl in ipairs(t.flavors or {}) do
                                if fl.id and not seenFl[fl.id] then
                                    seenFl[fl.id] = true
                                    flavors[#flavors + 1] = { id = fl.id, label = fl.label or fl.id, color = fl.color }
                                end
                            end
                        end
                    end
                    if #flavors > 0 then
                        out[#out + 1] = { kind = "finish", item = f.tool, label = GetItemLabel(f.tool),
                                          image = GetItemImage(f.tool), count = count,
                                          model = f.tool_model, flavors = flavors }
                    end
                end
            end
        end
        -- Condiment squeeze bottles (ketchup / mustard / mayo): draggable applicators
        -- like the finish tools, but they lay a sauce LAYER on a build stack instead of
        -- re-traying a product. Shown whenever the bottle is in the shared pool (personal
        -- inventory once dry). Ungrouped — a condiment is a universal topping, so it
        -- isn't gated on a restaurant's recipe groups. Kept in `condimentTools` so the
        -- plain-component loop below doesn't also list the bottle as an ingredient.
        local condimentTools = {}
        for _, c in ipairs(GetCondiments()) do
            if c.item and c.container_model and c.applied_model and ItemExists(c.item) then
                condimentTools[c.item] = true
                local count = poolInvCount(src, rid, c.item)
                if count > 0 then
                    out[#out + 1] = { kind = "condiment", item = c.item, label = GetItemLabel(c.item),
                                      image = GetItemImage(c.item), count = count,
                                      model = c.container_model }
                end
            end
        end
        -- The mix applicator cards: ONE per fill tool, rubbed over that tool's
        -- placed trays to fill them. Held from the shared pool like a finish tool;
        -- shown only when in stock (and only if the restaurant has access to at
        -- least one of the tool's tray groups).
        for _, b in ipairs(GetBakingList()) do
            if b.mix_item and ItemExists(b.mix_item) then
                local hasTrayAccess = false
                for _, t in ipairs(b.trays or {}) do
                    if RestaurantHasAccess(prop.restaurant_id, t.group) then hasTrayAccess = true break end
                end
                local count = hasTrayAccess and poolInvCount(src, rid, b.mix_item) or 0
                if count > 0 then
                    out[#out + 1] = { kind = "bakemix", item = b.mix_item, label = GetItemLabel(b.mix_item),
                                      image = GetItemImage(b.mix_item), count = count,
                                      model = b.mix_model }
                end
            end
        end
        local build = PrepBuilds[src]
        local seen = {}
        local function addComp(comp)
            -- Products (cook/assembly outputs — a cooked patty, a burger) are never
            -- "ingredients": inventory-held ones file under the Cooked/Uncooked tabs.
            -- Finish tools already have their own applicator card above.
            if seen[comp] or finishTools[comp] or condimentTools[comp] or bakeMix[comp] or not ItemExists(comp) or isTrayItem(comp) then return end
            seen[comp] = true
            local count = poolInvCount(src, rid, comp)
            if count <= 0 then return end
            -- Placed-but-not-yet-built parts are "spoken for": show what's left after
            -- this build's reservations (inv layers always reserve at cheese 0).
            local reserved = build and math.ceil(reservedUnits(build, "inv", comp, 0)) or 0
            local entry = { kind = "component", item = comp, label = GetItemLabel(comp),
                            image = GetItemImage(comp), count = math.max(0, count - reserved),
                            model = itemModel(comp) }
            -- a beef/dual patty renders as the full two-faced patty, same as one
            -- pulled from the tray (raw components carry no cheese)
            if dualRecipeForItem(comp) then entry.dual = true end
            -- a collected drink drags/places as its capped cup+lid tower
            if entry.model then entry.stack = withLid(comp, nil, entry.model) end
            out[#out + 1] = entry
        end
        for _, asm in ipairs(GetAssembly()) do
            if RestaurantHasAccess(prop.restaurant_id, asm.group) then
                for _, comp in ipairs(asm.components or {}) do addComp(comp) end
            end
        end
        -- Craft components too: a craft's inputs (soup's broth/veg) are draggable
        -- prep ingredients — the bar is where they come from before going in the bag.
        -- A component with no prop model still lists (addComp doesn't gate on model);
        -- it drags into the bag as a 2D pill.
        for _, cr in ipairs(GetCrafts()) do
            if RestaurantHasAccess(prop.restaurant_id, cr.group) then
                for _, comp in ipairs(cr.components or {}) do addComp(comp) end
            end
        end
        for comp in pairs(GetPrepModels()) do addComp(comp) end
    end
    return out
end)

-- send all in-progress items to a (re)connecting / station-opening client;
-- with a prop_id, only that station's items (a virtual session replaying its point)
lib.callback.register("pickle_restaurants:cooking:getActive", function(_, d)
    local propId = d and tonumber(d.prop_id) or nil
    local list = {}
    for _, it in pairs(CookingItems) do
        if not propId or it.prop_id == propId then
            list[#list + 1] = activeEntry(it)
        end
    end
    return list
end)

-- ─── placement (bar -> world) ────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:cooking:place", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false, error = _L("no_work_here") } end
    local station = StationType(prop)

    cookUid = cookUid + 1
    local uid = cookUid
    -- oven/fryer placements carry a slot instead of world coords, so default xyz
    local it = { uid = uid, rid = rid, prop_id = prop.id, station = station,
                 x = tonumber(d.x) or 0.0, y = tonumber(d.y) or 0.0, z = tonumber(d.z) or 0.0 }

    if (station == "fryer" or station == "stovetop") and d.kind == "cook" then
        local recipe = RecipeByInput[d.item]
        if not recipe or recipe.station ~= station then return { ok = false, error = _L("cook_cant_cook_here") } end
        -- group access is re-checked here — the bar never offers an inaccessible
        -- recipe, but the NUI is untrusted
        if not RestaurantHasAccess(rid, recipe.group) then return { ok = false, error = _L("cook_cant_cook_here") } end
        local method = RecipeMethod(recipe)

        -- Raw cook-inputs can come from the player's inventory OR from the "Uncooked
        -- Items" tray (e.g. an assembled uncooked pizza dragged straight to the oven).
        -- `sig` pins the pull — tray or inventory slot — to the exact build variation
        -- that was dragged (nil for plain Ingredients-bar drags).
        local id = GetIdentifier(src)
        local fromTray = d.source == "tray"
        local sig = (type(d.sig) == "string") and d.sig or nil
        -- A raw simple ingredient comes from the shared restaurant stock POOL while
        -- the pool carries it, and from the cook's personal inventory once it runs
        -- dry; an assembled/uncooked product dragged from inventory keeps its
        -- slot-metadata variation pull (so a pepperoni pizza stays a pepperoni pizza).
        local fromPool = (not fromTray) and isPoolItem(d.item)
            and (GetStockCount(rid, d.item) or 0) > 0
        local have
        if fromTray then
            have = GetTrayCount(rid, id, d.item, sig)
        elseif fromPool then
            have = GetStockCount(rid, d.item)
        else
            have = invVariationCount(src, d.item, sig)
        end
        if have < 1 then return { ok = false, error = _L("cook_missing_ingredient") } end
        local function consume()
            if fromTray then RemoveTray(rid, id, d.item, 1, sig)
            elseif fromPool then RemoveStock(rid, d.item, 1)
            else removeInvVariation(src, d.item, sig, 1) end
        end

        -- Oven / fryer: seat into a station slot and cook on a gated single timeline
        -- (bakes while the door is closed / fries while the basket is lowered).
        if method == "oven" or method == "fry" then
            local door = (method == "oven") and tonumber(d.door) or nil
            local slot = tonumber(d.slot)
            if not slot or (method == "oven" and door ~= 1 and door ~= 2) then
                return { ok = false, error = _L("cook_pick_spot") }
            end
            if not slotFree(prop.id, method, door, slot) then return { ok = false, error = _L("cook_spot_taken") } end

            -- An uncooked assembled input (e.g. a topped pizza) carries a build stack;
            -- capture it BEFORE consuming so the station renders the whole stack — not
            -- just the base model — and so collecting it back (raw OR cooked) returns
            -- the exact stack to the tray.
            local stackMeta
            if fromTray then
                stackMeta = TrayTopMeta(rid, id, d.item, sig)
            else
                stackMeta = invVariationMeta(src, d.item, sig)
            end
            -- An assembled input whose recorded stack ISN'T readable (a plain/legacy
            -- tray instance, or an inventory slot on a bridge without slot metadata)
            -- still cooks as its BASE recipe — synthesize that meta instead of losing
            -- it, or the collected product comes out stackless and renders as a bare
            -- base (a cooked pizza with no sauce/cheese) everywhere downstream.
            if not stackMeta then
                local asm = findAssembly(d.item)
                if asm and type(asm.components) == "table" and #asm.components > 0 then
                    stackMeta = {}
                    for _, comp in ipairs(asm.components) do
                        stackMeta[#stackMeta + 1] = { item = comp }
                    end
                end
            end
            local stackModels = stackModelsFromMeta(d.item, stackMeta)

            -- A containered bake (cake tin, cookie tray…) renders as container +
            -- food, folded into the existing build-stack machinery: only the
            -- stackBase layer swaps models as it cooks; the container rides along
            -- un-swapped and despawns with the stack. Never an item.
            if recipe.container_model and recipe.container_model ~= "" then
                local n = tonumber(recipe.output_count) or 1
                if n > 1 and not (stackModels and #stackModels > 1) then
                    -- A batch bake (the six-cookie tray): the container holds N copies of
                    -- the raw model, laid out as a grid client-side. They cook together
                    -- (the client swaps every matching layer by cook state) and collect as
                    -- N individual servings when done.
                    stackModels = { recipe.container_model }
                    for _ = 1, n do stackModels[#stackModels + 1] = recipe.raw_model end
                else
                    stackModels = stackModels or { recipe.raw_model }
                    table.insert(stackModels, 1, recipe.container_model)
                end
            end

            consume()
            it.kind, it.recipe, it.method, it.door, it.slot = "cook", recipe, method, door, slot
            it.state, it.model, it.elapsed = "raw", recipe.raw_model, 0
            it.stack, it.stackMeta = stackModels, stackMeta
            -- Which stack layer is the crust that actually cooks (the recipe's raw model).
            -- Only that layer swaps to the cooked/burnt model as it bakes; the toppings
            -- (sauce/cheese) ride along on top unchanged.
            if stackModels then
                it.stackBase = 1
                for i, m in ipairs(stackModels) do
                    if m == recipe.raw_model then it.stackBase = i; break end
                end
            end
            if method == "oven" then it.gate = not doorOpen(prop, door)
            else it.gate = basketDown(prop, slot) end
            CookingItems[uid] = it
            TriggerClientEvent("pickle_restaurants:cooking:slotSpawn", -1, {
                uid = uid, model = it.model, prop_id = prop.id, method = method,
                door = door, slot = slot, state = it.state, stack = it.stack })
            armGateTimer(it)
            broadcastGate(it)
            return { ok = true, uid = uid }
        end

        consume()
        it.kind, it.recipe = "cook", recipe

        -- oxmysql maps TINYINT(1) to a Lua boolean, so accept true or 1.
        local isDual = recipe.dual_sided == true or tonumber(recipe.dual_sided) == 1

        -- Dual-sided: render two faces, cook only the down one, flip to swap.
        -- (it.topping stays nil until a melting topping is applied.)
        if isDual then
            it.dual    = true
            it.sides   = { "raw", "raw" }
            it.elapsed = { 0, 0 }
            it.flipped = false
            it.down    = 1
            CookingItems[uid] = it
            broadcastDual(it)
            armSideTimer(it)
            return { ok = true, uid = uid }
        end

        it.state, it.model = "raw", recipe.raw_model
        CookingItems[uid] = it
        broadcastSpawn(it)
        SetTimeout(recipe.cook_ms, function()
            local cur = CookingItems[uid]; if not cur or cur.state ~= "raw" then return end
            cur.state, cur.model = "cooked", recipe.cooked_model
            TriggerClientEvent("pickle_restaurants:cooking:update", -1, uid, cur.model, cur.state, cur.prop_id)
            SetTimeout(recipe.burn_ms, function()
                local c2 = CookingItems[uid]; if not c2 or c2.state ~= "cooked" then return end
                c2.state, c2.model = "burnt", recipe.burnt_model
                TriggerClientEvent("pickle_restaurants:cooking:update", -1, uid, c2.model, c2.state, c2.prop_id)
            end)
        end)
        return { ok = true, uid = uid }

    elseif station == "soda_machine" and d.kind == "drink" then
        -- A cup seats under a tap (slot placement, like a fryer basket). Nothing
        -- pours yet — the player clicks the tap (middle nozzle = ice) once seated.
        local slot = tonumber(d.slot)
        if not slot or slot < 1 or slot > SODA_SLOTS
            or (slot ~= SODA_ICE_SLOT and not flavorForSlot(slot, rid)) then
            return { ok = false, error = _L("cook_cup_under_tap") }
        end
        if not slotFree(prop.id, "soda", nil, slot) then return { ok = false, error = _L("cook_spot_taken") } end
        -- one cup per fountain: reject a second cup anywhere on this machine
        -- (moving the seated cup between taps goes through reslot, not here)
        for _, c in pairs(CookingItems) do
            if c.method == "soda" and c.prop_id == prop.id then
                return { ok = false, error = _L("cook_already_cup") }
            end
        end
        local cup, model
        for _, dd in ipairs(sodaFlavors(rid)) do
            if dd.input == d.item then cup, model = dd.input, dd.model break end
        end
        if not cup then return { ok = false, error = _L("cook_unknown_cup") } end
        -- cups come from the shared restaurant stock pool (personal inventory once dry)
        if poolInvCount(src, rid, cup) < 1 then return { ok = false, error = _L("cook_need_cup") } end
        poolInvConsume(src, rid, cup, 1)
        it.kind, it.method, it.slot = "drink", "soda", slot
        it.input, it.state, it.ice = cup, "empty", false
        it.model = model or "pickle_drink_container_01"
        CookingItems[uid] = it
        TriggerClientEvent("pickle_restaurants:cooking:slotSpawn", -1, sodaSpawnPayload(it))
        broadcastSoda(it)
        return { ok = true, uid = uid }

    elseif station == "kitchen_prep" and d.kind == "assembly" then
        local asm = findAssembly(d.item)
        if not asm then return { ok = false, error = _L("cook_unknown_recipe") } end
        if not RestaurantHasAccess(rid, asm.group) then return { ok = false, error = _L("cook_unknown_recipe") } end
        -- raw components come from the stock pool (personal inventory once dry); a
        -- product component (e.g. a cooked patty cashed to inventory) always comes
        -- from personal inventory. Two-pass: verify everything is available, then
        -- consume, so a partial build never leaves stock/inventory half-spent.
        for _, comp in ipairs(asm.components or {}) do
            local have = poolInvCount(src, rid, comp)
            if have < 1 then return { ok = false, error = _L("cook_missing_components") } end
        end
        for _, comp in ipairs(asm.components or {}) do
            poolInvConsume(src, rid, comp, 1)
        end
        it.kind, it.output, it.state, it.model = "assembly", asm.output, "done", asm.model
        CookingItems[uid] = it
        broadcastSpawn(it)
        return { ok = true, uid = uid }
    end

    return { ok = false, error = _L("cook_invalid_action") }
end)

-- ─── oven door gate + fryer basket ───────────────────────────────────────────

-- The stovetop door RPC fires this after toggling a door: (re)gate every oven item
-- in that cavity — a closed door bakes, an open door pauses.
AddEventHandler("pickle_restaurants:oven:gate", function(propId, door, open)
    for _, it in pairs(CookingItems) do
        if it.method == "oven" and it.prop_id == propId and it.door == door then
            clearGateTimer(it)
            it.gate = not open
            armGateTimer(it)
            broadcastGate(it)
        end
    end
end)

-- Lower/raise ONE fryer basket: gate the fry item in that slot (lowered = frying).
-- Baskets are individually controlled, like oven doors.
lib.callback.register("pickle_restaurants:cooking:fryerDip", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop or StationType(prop) ~= "fryer" then return { ok = false } end
    if not HasPerm(prop.restaurant_id, src, "cook") then return { ok = false } end
    local slot = tonumber(d.slot)
    if not slot then return { ok = false } end
    local lowered = d.lowered and true or false
    prop.metadata = prop.metadata or {}
    prop.metadata.basketsDown = prop.metadata.basketsDown or {}
    prop.metadata.basketsDown[slot] = lowered or nil -- in-memory; rides the sync payload
    for _, it in pairs(CookingItems) do
        if it.method == "fry" and it.prop_id == prop.id and it.slot == slot then
            clearGateTimer(it)
            it.gate = lowered
            armGateTimer(it)
            broadcastGate(it)
        end
    end
    TriggerClientEvent("pickle_restaurants:fryer:dip", -1, prop.id, slot, lowered)
    return { ok = true, lowered = lowered }
end)

-- ─── soda machine: tap pour + lid ────────────────────────────────────────────

-- Click a tap with a cup seated under it: the middle nozzle dispenses ice, any
-- other pours that tap's drink into an empty cup. One drink per cup; ice can go
-- in before or after the drink, but never through a lid.
lib.callback.register("pickle_restaurants:cooking:sodaTap", function(src, d)
    local prop = PropCache[tonumber(d and d.prop_id)]
    if not prop or StationType(prop) ~= "soda_machine" then return { ok = false } end
    if not HasPerm(prop.restaurant_id, src, "cook") then return { ok = false } end
    local slot = tonumber(d.slot)
    if not slot then return { ok = false } end
    local it
    for _, c in pairs(CookingItems) do
        if c.method == "soda" and c.prop_id == prop.id and c.slot == slot then it = c break end
    end
    if not it then return { ok = false, error = _L("cook_cup_under_tap_first") } end
    if it.state == "filling" then return { ok = false, error = _L("cook_still_pouring") } end
    if it.state == "capped" then return { ok = false, error = _L("cook_lid_already_on") } end

    local uid = it.uid
    it.timerToken = (it.timerToken or 0) + 1
    local token = it.timerToken

    if slot == SODA_ICE_SLOT then
        if it.ice then return { ok = false, error = _L("cook_already_ice") } end
        local prev = it.state -- ice drops into an empty OR an already-filled cup
        it.state, it.fillTotal, it.phaseStart, it.fillKind = "filling", GetSetting("soda_ice_ms", 1500), GetGameTimer(), "ice"
        SetTimeout(it.fillTotal, function()
            local cur = CookingItems[uid]
            if not cur or cur.timerToken ~= token then return end
            cur.ice, cur.state, cur.phaseStart = true, prev, nil
            -- full slotSpawn (not update) so the payload carries the new ice flag
            -- and every client spawns the rim cubes
            TriggerClientEvent("pickle_restaurants:cooking:slotSpawn", -1, sodaSpawnPayload(cur))
            broadcastSoda(cur)
        end)
    else
        -- rid-gated: an inaccessible flavor's tap is dark for this restaurant
        local drink = flavorForSlot(slot, it.rid)
        if not drink then return { ok = false, error = _L("cook_nothing_on_tap") } end
        if it.state ~= "empty" then return { ok = false, error = _L("cook_cup_full") } end
        if drink.input ~= it.input then return { ok = false, error = _L("cook_wrong_cup") } end
        it.state, it.fillTotal, it.phaseStart, it.fillKind = "filling", tonumber(drink.fill_ms) or 3000, GetGameTimer(), "drink"
        it.drink, it.output = drink, drink.output
        if drink.model then it.model = drink.model end
        SetTimeout(it.fillTotal, function()
            local cur = CookingItems[uid]
            if not cur or cur.timerToken ~= token then return end
            cur.state, cur.phaseStart = "filled", nil
            TriggerClientEvent("pickle_restaurants:cooking:update", -1, uid, cur.model, cur.state, cur.prop_id)
            broadcastSoda(cur)
        end)
    end
    broadcastSoda(it)
    return { ok = true }
end)

-- Press a lid onto a filled cup (the lid card dragged over it). The lid is
-- kitchen equipment (cups come with lids) — nothing is consumed; the capped cup
-- renders cup+lid through the normal slot build stack.
lib.callback.register("pickle_restaurants:cooking:applyLid", function(src, d)
    local it = CookingItems[tonumber(d and d.uid)]
    if not it or it.method ~= "soda" then return { ok = false } end
    if not HasPerm(it.rid, src, "cook") then return { ok = false } end
    if it.state == "capped" then return { ok = false, error = _L("cook_already_lid") } end
    if it.state ~= "filled" then return { ok = false, error = _L("cook_fill_cup_first") } end
    it.state = "capped"
    it.stack = { it.model, GetSetting("drink_lid_model", "pickle_drink_lid_01") }
    TriggerClientEvent("pickle_restaurants:cooking:slotSpawn", -1, sodaSpawnPayload(it))
    broadcastSoda(it)
    return { ok = true, label = GetItemLabel(it.output) }
end)

-- ─── flip (dual-sided patties) ───────────────────────────────────────────────

lib.callback.register("pickle_restaurants:cooking:flip", function(src, d)
    local it = CookingItems[tonumber(d.uid)]
    if not it or not it.dual then return { ok = false } end
    if not HasPerm(it.rid, src, "cook") then return { ok = false } end
    clearSideTimer(it)
    it.flipped = not it.flipped
    it.down = it.flipped and 2 or 1
    broadcastDual(it)
    armSideTimer(it)
    return { ok = true }
end)

-- ─── melting toppings (dual-sided grill items) ───────────────────────────────

-- Drop a `melts`-flagged ingredient (a cheese slice…) on the up (visible) face —
-- only once it's cooked. It transitions applied → melted after the ingredient's
-- melt timer. One topping per item.
lib.callback.register("pickle_restaurants:cooking:applyTopping", function(src, d)
    local it = CookingItems[tonumber(d and d.uid)]
    if not it or not it.dual then return { ok = false } end
    if not HasPerm(it.rid, src, "cook") then return { ok = false } end
    local item = d and d.item
    if type(item) ~= "string" or not MeltingToppingFor(item) then
        return { ok = false, error = _L("cook_cant_apply") }
    end
    if it.topping then return { ok = false, error = _L("cook_already_topping") } end

    local up = (it.down == 1) and 2 or 1
    if it.sides[up] ~= "cooked" then return { ok = false, error = _L("cook_cook_side_first") } end
    -- toppings come from the shared restaurant stock pool (personal inventory once dry)
    if poolInvCount(src, it.rid, item) < 1 then
        return { ok = false, error = _L("cook_no_tool_left", GetItemLabel(item)) }
    end
    poolInvConsume(src, it.rid, item, 1)

    it.topping = { item = item, state = "applied" }
    broadcastDual(it)
    local uid = it.uid
    SetTimeout(ToppingMeltMs(item), function()
        local cur = CookingItems[uid]
        if not cur or not cur.topping or cur.topping.item ~= item
            or cur.topping.state ~= "applied" then return end
        cur.topping.state = "melted"
        broadcastDual(cur)
    end)
    return { ok = true }
end)

-- ─── move (drag within world) ────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:cooking:move", function(src, d)
    local it = CookingItems[tonumber(d.uid)]
    if not it then return { ok = false } end
    if not HasPerm(it.rid, src, "cook") then return { ok = false } end
    it.x, it.y, it.z = d.x + 0.0, d.y + 0.0, d.z + 0.0
    TriggerClientEvent("pickle_restaurants:cooking:move", -1, it.uid, it.x, it.y, it.z, it.prop_id)
    return { ok = true }
end)

-- Re-slot an oven/fryer item onto another rack mid-cook — the same open-slot snapping
-- as placement. Cook progress carries over (elapsed is banked then resumed) and the gate
-- is recomputed for the new door.
lib.callback.register("pickle_restaurants:cooking:reslot", function(src, d)
    local it = CookingItems[tonumber(d and d.uid)]
    if not it then return { ok = false } end
    if not HasPerm(it.rid, src, "cook") then return { ok = false } end
    if it.method ~= "oven" and it.method ~= "fry" and it.method ~= "soda" then return { ok = false } end
    local prop = PropCache[it.prop_id]
    if not prop then return { ok = false } end
    -- A soda cup moved to another tap (ice first, then a flavor). No door/gate —
    -- just re-seat it, as long as nothing is mid-pour.
    if it.method == "soda" then
        local slot = tonumber(d.slot)
        if not slot or (slot ~= SODA_ICE_SLOT and not flavorForSlot(slot, it.rid)) then
            return { ok = false, error = _L("cook_pick_tap") }
        end
        if it.slot == slot then return { ok = false } end -- already there
        if it.state == "filling" then return { ok = false, error = _L("cook_still_pouring") } end
        if not slotFree(it.prop_id, "soda", nil, slot) then return { ok = false, error = _L("cook_spot_taken") } end
        it.slot = slot
        TriggerClientEvent("pickle_restaurants:cooking:slotSpawn", -1, sodaSpawnPayload(it))
        broadcastSoda(it)
        return { ok = true }
    end
    local door = (it.method == "oven") and tonumber(d.door) or nil
    local slot = tonumber(d.slot)
    if not slot or (it.method == "oven" and door ~= 1 and door ~= 2) then return { ok = false, error = _L("cook_pick_spot") } end
    if it.slot == slot and (it.method ~= "oven" or it.door == door) then return { ok = false } end -- already there
    if not slotFree(it.prop_id, it.method, door, slot) then return { ok = false, error = _L("cook_spot_taken") } end
    -- can't fish food out of a lowered basket either — raise it first
    if it.method == "fry" and basketDown(prop, it.slot) then return { ok = false, error = _L("cook_raise_basket") } end

    it.door, it.slot = door, slot
    -- A different door may be open/closed — or a different basket lowered/raised —
    -- so re-gate (banking any accrued time).
    clearGateTimer(it)
    if it.method == "oven" then it.gate = not doorOpen(prop, door)
    else it.gate = basketDown(prop, slot) end
    armGateTimer(it)
    TriggerClientEvent("pickle_restaurants:cooking:slotSpawn", -1, {
        uid = it.uid, model = it.model, prop_id = it.prop_id, method = it.method,
        door = it.door, slot = it.slot, state = it.state, stack = it.stack })
    broadcastGate(it)
    return { ok = true }
end)

-- ─── collect (drag back to the bar / inventory) ──────────────────────────────

lib.callback.register("pickle_restaurants:cooking:collect", function(src, d)
    local it = CookingItems[tonumber(d.uid)]
    if not it then return { ok = false } end
    if not HasPerm(it.rid, src, "cook") then return { ok = false } end
    -- Can't reach into a closed oven — the door has to be open to take a bake out.
    if it.method == "oven" and not doorOpen(PropCache[it.prop_id], it.door) then
        return { ok = false, error = _L("cook_open_door") }
    end
    -- Nor into hot oil — the basket has to be raised to take a fry out.
    if it.method == "fry" and basketDown(PropCache[it.prop_id], it.slot) then
        return { ok = false, error = _L("cook_raise_basket") }
    end

    local giveItem, giveLabel
    if it.kind == "cook" then
        if it.dual then
            giveItem = dualGiveItem(it)
        elseif it.state == "raw" then giveItem = it.recipe.input_item
        elseif it.state == "cooked" then giveItem = it.recipe.output_cooked_item
        else giveItem = it.recipe.output_burnt_item end
    elseif it.kind == "drink" then
        -- An empty cup collects straight back; a poured drink always needs its
        -- lid pressed on first (the lid tool is free — cups come with lids).
        if it.state == "filling" then return { ok = false, error = _L("cook_still_pouring") } end
        if it.state == "filled" then return { ok = false, error = _L("cook_press_lid") } end
        giveItem = sodaGiveItem(it)
        -- a poured drink collects as the ONE generic drink item, its flavor (the
        -- drinks[].output key) riding as build-stack metadata — like a meal
        if giveItem == it.output then
            local dd
            for _, cfg in ipairs(GetDrinks()) do
                if cfg.output == it.output then dd = cfg break end
            end
            giveItem = DrinkItem()
            it.stackMeta = { { item = it.output } }
            giveLabel = dd and dd.label or nil
        end
    elseif it.kind == "assembly" then
        giveItem = it.output
    end

    -- An assembled item taken out of the oven/fryer keeps its exact build stack so
    -- nothing is lost — RAW or COOKED. A cooked pizza must carry its toppings/sauce
    -- forward (to the tray, then the inventory slot) or it comes out a bare base.
    local giveMeta = it.stackMeta
    -- A melting topping rides the build-stack metadata forward at its exact melt
    -- state: stamped onto the stack's own layer when one exists, else recorded as
    -- the one-layer SELF stack (the same form the tray-cheese migration writes for
    -- bare topped instances). Tray rows are always cheese-0 now.
    if it.topping then
        local top = { item = it.topping.item, state = it.topping.state }
        if type(giveMeta) == "table" and #giveMeta > 0 then
            local li = 1
            for i, l in ipairs(giveMeta) do
                if l.item == giveItem or l.item == it.recipe.input_item then li = i break end
            end
            giveMeta[li].top = top
        else
            giveMeta = { { item = giveItem, top = top } }
        end
    end
    -- A finished cook yields the recipe's serving size (a basket of fries is a
    -- batch of fries, not one giant fry). Raw items collected back stay 1:1.
    local giveCount = 1
    if it.kind == "cook" and (it.state == "cooked" or it.state == "burnt") then
        giveCount = math.max(1, tonumber(it.recipe.output_count) or 1)
    end
    -- A raw simple ingredient taken back off a station returns to the shared
    -- stock POOL (symmetric with placing it); cooked/assembled products and drinks
    -- (tray items, with build metadata) go to the per-player tray.
    if giveItem then
        if isPoolItem(giveItem) then AddStock(it.rid, giveItem, giveCount)
        else AddTray(it.rid, GetIdentifier(src), giveItem, giveCount, giveMeta) end
    end
    CookingItems[it.uid] = nil
    TriggerClientEvent("pickle_restaurants:cooking:remove", -1, it.uid)
    return { ok = true, item = giveItem,
             label = giveLabel or (giveItem and GetItemLabel(giveItem)) or nil }
end)

-- ─── cooked-items tray ───────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:cooking:getTray", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return {} end
    if not HasPerm(prop.restaurant_id, src, "cook") then return {} end
    PurgeExpiredTray(prop.restaurant_id, GetIdentifier(src)) -- drop spoiled rows before listing
    local list = GetTray(prop.restaurant_id, GetIdentifier(src))
    local mealItem = MealItem()
    local drinkItem = DrinkItem()
    local bagItem = BagItemName()
    -- At the prep table, cooked items placed on a build are spoken for — subtract
    -- the reservations so the tray shows what's still free to grab.
    local isPrep = StationType(prop) == "kitchen_prep"
    local build = isPrep and PrepBuilds[src] or nil
    local out = {}
    for _, e in ipairs(list) do
        if build then
            e.count = e.count - math.ceil(reservedUnits(build, "tray", e.item, e.sig))
        end
        if e.count > 0 then
            e.model = itemModel(e.item)
            -- a dual patty renders as two faces; its melting topping rides the visible
            -- face at the melt state it was collected in, seated identically to the
            -- stovetop. A bare topped instance stores as the one-layer SELF stack —
            -- fold it into top/topModel and SUPPRESS the stack render (the two-faced
            -- render owns the topping; a one-model "stack" would double-draw it).
            local topv = nil
            if dualRecipeForItem(e.item) then
                e.dual = true
                topv = selfStackTop(e.item, e.meta)
                if topv then e.meta = nil end
            end
            if topv then
                e.top = topv
                e.topModel = ToppingModel(topv)
            end
            -- an assembled product (burger etc.) can be dropped on the prep table to
            -- be taken back apart into its component stack; a meal sets back down as
            -- its full tray (same un-make flow, tray + layout preserved). A finished
            -- (frosted) instance is terminal — never decomposable, even on servers
            -- whose DB still carries the legacy stack-assembly recipe for the same
            -- output item (taking it apart would destroy the applied frosting).
            -- metadata-driven: a plain cooked_doughnut (no finish meta) resolves nil,
            -- so it is NOT finished/terminal even though cooked_doughnut is now also a
            -- frosting output item.
            local ftarget, ftcfg, ftfl = finishFor(e.item, e.meta)
            local isFinished = ftarget ~= nil
            if e.item == mealItem then
                e.meal = true
                -- a meal made in a pizza box (flag on the first meta layer) — the
                -- NUI says so, and setting it down recreates the box, not a tray
                if type(e.meta) == "table" and e.meta[1] ~= nil and e.meta[1].box then e.boxed = true end
            end
            -- the generic drink item: resolve its label + capped-cup render from the
            -- flavor its metadata records (the drinks[].output key)
            if e.item == drinkItem then
                local dd = drinkFlavor(e.meta)
                if dd then
                    e.label = dd.label or e.label
                    e.model = dd.model
                    e.stack = drinkRender(dd)
                    e.flavor = dd.output -- flavor key → per-flavor NUI card art (items/<output>.png)
                end
            end
            -- a made takeout box: labelled as the food it holds, rendered as the box
            -- pair with that food's image on the quad inside. Terminal — not
            -- decomposable (a soup can't be taken back apart).
            local trayFid = boxFoodId(e.item, e.meta)
            if trayFid then
                local label, image, boxImage, boxCrop = boxFoodRender(findCraft(trayFid))
                e.label    = label or e.label
                e.image    = image or e.image  -- the card in the bar
                e.takeout  = true
                e.quad     = boxImage          -- what's painted inside the box
                e.quadCrop = boxCrop           -- …at exactly the rect that was cropped
                e.model    = BoxBaseModel()
                e.lidModel = BoxLidModel()
                e.stack    = { e.model }
            elseif e.item == bagItem then
                -- the packed Restaurant Bag: the SEALED vessel (contents hidden once
                -- bagged, like a closed box), counted in the label so staff can tell
                -- two bags apart on the shelf. Terminal — not decomposable.
                e.bag = true
                e.contents = #(type(e.meta) == "table" and e.meta or {})
                e.model = BagModel()
                e.stack = { e.model }
            end
            if isPrep and (findAssembly(e.item) or e.meal) and not isFinished then e.decompose = true end
            -- still-raw items that are a cook-recipe input (e.g. an uncooked pizza) go
            -- to the oven/fryer next; the NUI files them under "Uncooked Items" and lets
            -- them be dragged straight into their station (cookStation) to cook.
            local rin = RecipeByInput[e.item]
            if rin then
                e.uncooked = true; e.cookStation = rin.station
                -- the full build stack (component models) so the drag-to-oven preview
                -- can render every layer, matching what actually gets placed
                e.stack = stackModelsFromMeta(e.item, e.meta)
            else
                -- A cooked/burnt product that carries a build stack (e.g. a cooked
                -- pizza) still renders as the WHOLE stack — its crust layer swapped
                -- to the recipe's cooked/burnt model, toppings riding along (the
                -- client swaps their looks by stackState) — so dragging it at prep
                -- shows the full pizza, not a bare dough base. A containered bake
                -- (the cake sheet) renders inside its container tray either way.
                local rout, state = recipeForOutput(e.item)
                -- burnt outputs are flagged so the NUI can sort them last and offer the bin
                if state == "burnt" then e.burnt = true end
                if rout then
                    -- a legacy stackless instance (collected before stacks were
                    -- preserved through the cook) still renders its BASE recipe
                    -- stack — same fallback the inventory path below uses
                    local models = (e.meta and stackModelsFromMeta(e.item, e.meta))
                        or (findAssembly(rout.input_item) and stackModelsFromMeta(rout.input_item, nil)) or nil
                    if models then
                        for i, m in ipairs(models) do
                            if m == rout.raw_model then
                                models[i] = (state == "burnt") and rout.burnt_model or rout.cooked_model
                                break
                            end
                        end
                    end
                    models = withContainer(rout, models, (state == "burnt") and rout.burnt_model or rout.cooked_model)
                    if models then e.stack, e.stackState = models, state end
                end
            end
            -- a finished (frosted…) product renders by its recorded flavor and
            -- shows a flavor badge instead of a parts/toppings breakdown
            if ftarget then
                local model, stack = finishRender(e.item, e.meta)
                if model then e.model = model end
                if stack then e.stack = stack end
                if ftfl then e.flavorLabel = ftfl.label or ftfl.id end
                e.finishTool = ftcfg and ftcfg.tool
            end
            -- a collected drink renders cup+lid, a side renders in its box — never bare
            if not e.stack then e.stack = servedStack(e.item, e.model) end
            -- how this variation differs from the base recipe (its toppings), plus
            -- the full component list for the hover tooltip. A drink's meta is just
            -- its flavor key — already the card label, not a topping.
            if e.meta and not ftarget and e.item ~= drinkItem and e.item ~= bagItem and not e.takeout then
                e.extras = extrasComponents(e.item, e.meta)
                e.comps  = stackComponents(e.meta)
            end
            -- a bag / takeout box has no base recipe to diff against — just list
            -- what's inside it
            if (e.item == bagItem or e.takeout) and e.meta then e.comps = stackComponents(e.meta) end
            e.meta = nil -- the NUI keys variations by sig; no need to ship the raw stack
            -- freshness clock: SECONDS LEFT until this item spoils (nil = never). Sent as
            -- a remaining count, not an epoch, so the NUI counts down against its own
            -- clock (no server-time sync needed) and re-syncs on each tray refresh.
            local exp = TrayExpiresAt(e.item, e.cookedAt)
            e.expiresIn = exp and math.max(0, exp - os.time()) or nil
            e.cookedAt = nil
            out[#out + 1] = e
        end
    end

    -- Inventory-held PRODUCTS join the tabs too, marked source "inv" ("Item" pill in
    -- the NUI): cook outputs and assembled products file under "Cooked Items",
    -- assembled-but-raw cook inputs (an uncooked pizza item) under "Uncooked Items".
    -- The Ingredients bar keeps only true raw components — a cooked patty in your
    -- inventory is not an "ingredient". Where the bridge exposes slot metadata,
    -- each build variation is its own entry (exact stack, toppings);
    -- otherwise everything groups under the base-recipe look.
    local function addInvEntries(item)
        if not ItemExists(item) then return end
        for _, v in ipairs(invVariations(src, item)) do
            local count = v.count
            if build then count = count - math.ceil(reservedUnits(build, "inv", item, v.sig)) end
            if count > 0 then
                local entry = { item = item, count = count, source = "inv", sig = v.sig,
                                label = GetItemLabel(item), image = GetItemImage(item), model = itemModel(item) }
                -- the generic drink item: label + capped-cup render from its
                -- recorded flavor (mirrors the tray path above)
                if item == drinkItem then
                    local dd = drinkFlavor(v.meta)
                    if dd then
                        entry.label = dd.label or entry.label
                        entry.model = dd.model
                        entry.stack = drinkRender(dd)
                        entry.flavor = dd.output -- flavor key → per-flavor NUI card art (items/<output>.png)
                    end
                end
                -- a made takeout box (or a legacy bag food): the food's label + the
                -- box pair with its image on the quad inside. The bag proper is the
                -- sealed carrier.
                local invFid = boxFoodId(item, v.meta)
                if invFid then
                    local label, image, boxImage, boxCrop = boxFoodRender(findCraft(invFid))
                    entry.label    = label or entry.label
                    entry.image    = image or entry.image
                    entry.takeout  = true
                    entry.quad     = boxImage
                    entry.quadCrop = boxCrop
                    entry.model    = BoxBaseModel()
                    entry.lidModel = BoxLidModel()
                    entry.stack    = { entry.model }
                elseif item == bagItem then
                    entry.bag = true
                    entry.contents = #(type(v.meta) == "table" and v.meta or {})
                    entry.model = BagModel()
                    entry.stack = { entry.model }
                end
                -- a dual patty renders two-faced; a bare topped instance stores as the
                -- one-layer SELF stack (fold to top/topModel, suppress the stack render)
                local topv = nil
                if dualRecipeForItem(item) then
                    entry.dual = true
                    topv = selfStackTop(item, v.meta)
                    if topv then v.meta = nil end
                end
                if topv then
                    entry.top = topv
                    entry.topModel = ToppingModel(topv)
                end
                local rin = RecipeByInput[item]
                if rin then
                    entry.uncooked = true; entry.cookStation = rin.station
                    entry.stack = stackModelsFromMeta(item, v.meta) -- exact stack, or base recipe
                else
                    -- a cooked/burnt product renders its recorded stack (else the
                    -- base recipe), crust swapped to its cooked/burnt model, inside
                    -- its container tray when the recipe bakes in one
                    local rout, state = recipeForOutput(item)
                    if state == "burnt" then entry.burnt = true end
                    if rout then
                        local models = v.meta and stackModelsFromMeta(item, v.meta)
                            or (findAssembly(rout.input_item) and stackModelsFromMeta(rout.input_item, nil))
                        if models then
                            for i, m in ipairs(models) do
                                if m == rout.raw_model then
                                    models[i] = (state == "burnt") and rout.burnt_model or rout.cooked_model
                                    break
                                end
                            end
                        end
                        models = withContainer(rout, models, (state == "burnt") and rout.burnt_model or rout.cooked_model)
                        if models then entry.stack, entry.stackState = models, state end
                    end
                end
                -- finished (frosted…) products render by their recorded flavor —
                -- metadata-driven so a plain cooked_doughnut in inventory stays plain
                local ftarget, ftcfg, ftfl = finishFor(item, v.meta)
                if ftarget then
                    local model, stack = finishRender(item, v.meta)
                    if model then entry.model = model end
                    if stack then entry.stack = stack end
                    if ftfl then entry.flavorLabel = ftfl.label or ftfl.id end
                    entry.finishTool = ftcfg and ftcfg.tool
                end
                -- An inventory-held assembled product (a burger, an uncooked pizza) can be
                -- taken apart on the prep table exactly like a tray one — drop it, add/remove
                -- toppings, rebuild. Without this it drops as ONE solid part, so a topping
                -- added to it can't merge and the rebuild forms no recipe (it re-adds the
                -- same item unchanged). Mirrors the tray path; a finished/frosted instance
                -- is terminal (never comes apart).
                local isFinishedInv = ftarget ~= nil
                if isPrep and findAssembly(item) and not isFinishedInv then
                    entry.decompose = true
                end
                -- a collected drink renders cup+lid, a side renders in its box — never bare
                if not entry.stack then entry.stack = servedStack(item, entry.model) end
                if v.meta and not ftarget and item ~= drinkItem and not entry.takeout and not entry.bag then
                    entry.extras = extrasComponents(item, v.meta)
                    entry.comps  = stackComponents(v.meta)
                end
                -- an inventory-held meal can be set back down (un-made) at prep too
                if item == mealItem then
                    entry.meal = true
                    if type(v.meta) == "table" and v.meta[1] ~= nil and v.meta[1].box then entry.boxed = true end
                    if isPrep then entry.decompose = true end
                end
                out[#out + 1] = entry
            end
        end
    end
    local seenInv = {}
    local function once(item) if item and not seenInv[item] then seenInv[item] = true; addInvEntries(item) end end
    for _, r in ipairs(RecipeCache) do
        once(r.output_cooked_item); once(r.output_burnt_item)
    end
    for _, a in ipairs(GetAssembly()) do once(a.output) end
    for _, f in ipairs(GetFinishes()) do
        for _, t in ipairs(f.targets or {}) do once(t.output) end
    end
    once(mealItem)  -- meals aren't a recipe/assembly output, so list them explicitly
    once(drinkItem) -- neither is the generic drink item (flavor rides its metadata)
    once(BoxItemName()) -- nor a made takeout box (the food id rides its metadata)
    once(bagItem)       -- nor a packed Restaurant Bag (its contents ride its metadata)

    return out
end)

-- Inventory-slot metadata for a cooked item leaving the tray: its exact build stack
-- (so the variation survives) + a readable description. Returns nil for a plain item
-- with nothing to preserve (keeps stacks clean). Frameworks without slot metadata
-- (ESX) ignore whatever we pass. Toppings ride inside `meta` (the `top` field).
-- Global so the POS register (modules/sales) can hand pool-fulfilled cooked
-- instances to the customer with the same slot metadata a cook gets on cash-out.
-- `item` (optional): when it's a made TAKEOUT BOX, stamp the FOOD's own label +
-- picture onto the slot so the box reads in the inventory as the food it holds
-- (ox_inventory honours `label`/`imageurl` natively). A packed RESTAURANT BAG
-- describes itself by what's inside it.
function BuildInvMeta(meta, item)
    local m
    if type(meta) == "table" and #meta > 0 then
        m = { stack = meta, description = stackDescription(meta) }
    end
    local fid = item and boxFoodId(item, meta) or nil
    if fid then
        local cr = findCraft(fid)
        if cr then
            local label, url = boxFoodRender(cr)
            if label then
                m = m or {}
                m.label = label
                m.description = label
            end
            if url then m = m or {}; m.imageurl = url end
        end
    end
    return m
end
local buildInvMeta = BuildInvMeta

-- The render specs for a MEAL held in a player's inventory — what modules/dining
-- lays out on the table in front of a seated customer. Each recorded layer becomes
-- one compSpec (the very same the prep table builds from, so a meal looks identical
-- wherever it is set down) stamped with its INDEX in the metadata, which is what the
-- eat callback addresses. `box` reports the meal was packed in a pizza box, so it is
-- laid out in its box rather than on a tray.
lib.callback.register("pickle_restaurants:consume:mealSpecs", function(src, d)
    local item = d and d.item
    if not item or item ~= MealItem() then return { ok = false } end
    if not (Inventory and Inventory.GetItemSlots) then return { ok = false } end
    local meta
    for _, s in ipairs(Inventory.GetItemSlots(src, item) or {}) do
        if not d.slot or s.slot == tonumber(d.slot) then meta = s.metadata break end
    end
    local stack = (type(meta) == "table" and type(meta.stack) == "table") and meta.stack or nil
    if not stack or #stack == 0 then return { ok = false } end
    local parts = {}
    for i, l in ipairs(stack) do
        local spec = compSpec(l)
        spec.id = i          -- the layer this pile eats
        spec.dx, spec.dy = l.dx, l.dy
        local disp = LayerDisplay(l)
        spec.label = disp and disp.label or spec.label
        spec.image = disp and disp.image or spec.image
        spec.drink = disp and disp.drink or nil
        parts[#parts + 1] = spec
    end
    return { ok = true, box = (stack[1] and stack[1].box) and true or nil, parts = parts }
end)

-- cash a tray item out into the real inventory (so it can be stocked/sold)
lib.callback.register("pickle_restaurants:cooking:trayToInventory", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    local id = GetIdentifier(src)
    local item   = d.item
    local sig    = (type(d.sig) == "string") and d.sig or nil
    local count  = tonumber(d.count) or 1
    if not item or GetTrayCount(rid, id, item, sig) < count then return { ok = false, error = _L("cook_not_enough") } end
    -- Burnt food is UNEXCHANGEABLE: it can never leave the tray into real inventory —
    -- the only way to get rid of it is the bin (trayDiscard), where it's destroyed for
    -- good. See memory: burnt-unexchangeable-destroyed.
    do
        local _, state = recipeForOutput(item)
        if state == "burnt" then return { ok = false, error = _L("cook_cant_take_burnt") } end
    end
    -- The tray holding accepts anything (e.g. a meal made before its item was
    -- installed), but the real inventory can't — don't consume the tray entry
    -- into an item the framework doesn't know (it would just vanish).
    if not ItemExists(item) then
        return { ok = false, error = _L("cook_item_not_installed", item) }
    end
    -- Move one instance at a time so each keeps its OWN build variation on the
    -- inventory slot (ox/qb slot metadata). TrayTopMeta must be read before the
    -- matching RemoveTray, which pops that instance's stack (LIFO).
    for _ = 1, count do
        local meta = TrayTopMeta(rid, id, item, sig)
        if not RemoveTray(rid, id, item, 1, sig) then break end
        Inventory.AddItem(src, item, 1, buildInvMeta(meta, item))
    end
    return { ok = true, item = item, count = count, label = GetItemLabel(item) }
end)

-- throw a tray entry in the bin — gone for good, nothing refunded. The only way
-- to get rid of burnt food (it never needs its item installed, unlike
-- trayToInventory). `burnt_only` sweeps every burnt cook output off the tray.
lib.callback.register("pickle_restaurants:cooking:trayDiscard", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    local id = GetIdentifier(src)
    if d.burnt_only then
        local n = 0
        for _, e in ipairs(GetTray(rid, id)) do
            local _, state = recipeForOutput(e.item)
            if state == "burnt" and e.count > 0 and RemoveTray(rid, id, e.item, e.count, e.sig) then
                n = n + e.count
            end
        end
        if n == 0 then return { ok = false, error = _L("cook_nothing_burnt") } end
        return { ok = true, count = n }
    end
    local item   = d.item
    local sig    = (type(d.sig) == "string") and d.sig or nil
    local count  = tonumber(d.count) or 1
    if not item or count < 1 then return { ok = false } end
    count = math.min(count, GetTrayCount(rid, id, item, sig))
    if count < 1 or not RemoveTray(rid, id, item, count, sig) then
        return { ok = false, error = _L("cook_not_enough") }
    end
    return { ok = true, item = item, count = count, label = GetItemLabel(item) }
end)

-- ─── interactive prep build (kitchen_prep) ───────────────────────────────────

-- A `halves` ingredient (a bun) is one inventory item rendered as two stackable
-- halves (top/bottom), so each half only counts as half — one or two halves = one
-- whole. `half` is only ever set for a halves-configured ingredient (prepAdd guards
-- it), so a plain `l.half` test is generic.
function layerUnits(l)
    if l.half then return 0.5 end
    return 1.0
end

-- The multiset of items a build provides (a topped patty also provides its topping
-- item; halves round up so a lone bottom half still satisfies a "1 whole" recipe).
local function buildProvides(layers)
    local units = {}
    for _, l in ipairs(layers) do
        units[l.item] = (units[l.item] or 0) + layerUnits(l)
        -- a melting topping riding this layer (its `top` field) counts as one unit
        -- of its item
        local topv = LayerTopping(l)
        if topv then units[topv.item] = (units[topv.item] or 0) + 1 end
    end
    local p = {}
    for k, v in pairs(units) do p[k] = math.ceil(v) end
    return p
end

-- Units of (source,item,cheese[,sig]) this build already reserved — layers only
-- reserve; nothing is pulled from the tray/inventory until Make, so this guards
-- against reserving more than the player actually holds. `sig` (tray layers only)
-- narrows the match to one build variation; nil matches any.
function reservedUnits(b, source, item, sig)
    local n = 0
    for _, l in ipairs(b.layers) do
        if l.source == source and l.item == item
            and (sig == nil or (l.sig or "") == sig) then
            n = n + layerUnits(l)
        end
    end
    return n
end

lib.callback.register("pickle_restaurants:cooking:prepAdd", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop or StationType(prop) ~= "kitchen_prep" then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    local item = d.item
    if not item then return { ok = false } end
    -- a layer's topping rides in the reserved instance's meta, resolved by `sig` in
    -- consumeLayers — there is no separate cheese/topping dimension on the reservation.
    -- only a halves-configured ingredient may reserve a half (the NUI is untrusted)
    local half = ((d.half == "top" or d.half == "bottom") and IngredientHalves(item)) and d.half or nil
    -- the build variation this layer reserves (so a pepperoni pizza layer holds
    -- the pepperoni instance — tray or inventory slot — not whichever is on top);
    -- nil for plain Ingredients-bar components
    local sig = (type(d.sig) == "string") and d.sig or nil

    -- starting/continuing a build at this prop; a build at another prop is dropped
    -- (nothing was consumed, so there's nothing to return).
    local b = PrepBuilds[src]
    if b and b.prop_id ~= prop.id then b = nil end
    if not b then b = { prop_id = prop.id, rid = rid, seq = 0, layers = {} }; PrepBuilds[src] = b end

    -- Reserve only — DON'T remove from the tray/inventory yet (that happens on
    -- Make). Validate against what's left after this build's existing reservations.
    local addUnits = (half and 0.5) or 1.0
    if d.source == "tray" then
        local needed = math.ceil(reservedUnits(b, "tray", item, sig) + addUnits)
        if GetTrayCount(rid, GetIdentifier(src), item, sig) < needed then
            return { ok = false, error = _L("cook_not_enough_tray") }
        end
    elseif sig then
        -- an inventory-held PRODUCT reserves its exact variation (cheese + sig)
        local needed = math.ceil(reservedUnits(b, "inv", item, sig) + addUnits)
        if invVariationCount(src, item, sig) < needed then
            return { ok = false, error = _L("cook_missing_item") }
        end
    else
        -- a plain raw component comes from the shared restaurant stock pool (personal
        -- inventory once dry) — only reserved here; consumed on Make. Reservations are
        -- per-cook, so two cooks can optimistically reserve the same units — the pool
        -- (or inventory) re-checks on Make.
        local needed = math.ceil(reservedUnits(b, "inv", item) + addUnits)
        local have = poolInvCount(src, rid, item)
        if have < needed then
            return { ok = false, error = _L("cook_missing_item") }
        end
    end

    b.seq = (b.seq or 0) + 1
    -- the topping (if any) is resolved from the reserved instance's meta by `sig` in
    -- consumeLayers, so the reservation only needs item/half/sig.
    b.layers[#b.layers + 1] = { id = b.seq, source = d.source, item = item,
                                half = half, sig = sig }
    return { ok = true, id = b.seq }
end)

-- pull one placed part back out of the build (drag-to-bar removal); nothing was
-- consumed, so this just drops the reservation.
lib.callback.register("pickle_restaurants:cooking:prepRemove", function(src, d)
    local b = PrepBuilds[src]; if not b then return { ok = true } end
    local id = tonumber(d.id)
    for i, l in ipairs(b.layers) do
        if l.id == id then table.remove(b.layers, i); break end
    end
    if #b.layers == 0 then PrepBuilds[src] = nil end
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:cooking:prepClear", function(src, _)
    PrepBuilds[src] = nil -- nothing was consumed; just discard the reservation
    return { ok = true }
end)

-- The recipe catalogue the prep tooltip ranks against: each buildable assembly
-- with its output + component labels/images resolved (the NUI can't resolve item
-- images itself). Recipes referencing a missing item are hidden until fixed.
lib.callback.register("pickle_restaurants:cooking:getRecipes", function(src, d)
    local prop = PropCache[tonumber(d and d.prop_id)]
    if not prop or StationType(prop) ~= "kitchen_prep" then return {} end
    if not HasPerm(prop.restaurant_id, src, "cook") then return {} end
    local out = {}
    for _, asm in ipairs(GetAssembly()) do
        local valid = ItemExists(asm.output)
            and RestaurantHasAccess(prop.restaurant_id, asm.group) -- group-gated per restaurant
        local comps = {}
        for _, c in ipairs(asm.components or {}) do
            -- a component is a real item OR a cooked-pool product (a patty) — the latter
            -- is valid without being installed (IsProductItem)
            if not ItemExists(c) and not IsProductItem(c) then valid = false end
            comps[#comps + 1] = { item = c, label = GetItemLabel(c), image = GetItemImage(c) }
        end
        if valid then
            out[#out + 1] = {
                output = asm.output, label = asm.label or GetItemLabel(asm.output),
                image = GetItemImage(asm.output), components = comps,
            }
        end
    end
    return out
end)

-- The CRAFT catalogue the Restaurant Bag's tooltip ranks its contents against —
-- mirrors getRecipes but over the `crafts` setting. Every craft collapses to the ONE
-- bag item, so the craft `id` is its display identity and the bag item supplies the
-- thumbnail; components are resolved to labels/images (the NUI can't resolve item
-- images itself). Crafts with no id / no components, gated out by group, or naming a
-- missing component (that isn't a cooked-pool product) are hidden until fixed.
lib.callback.register("pickle_restaurants:cooking:getCrafts", function(src, d)
    local prop = PropCache[tonumber(d and d.prop_id)]
    if not prop or StationType(prop) ~= "kitchen_prep" then return {} end
    if not HasPerm(prop.restaurant_id, src, "cook") then return {} end
    -- a bag-kind food shows its OWN authored picture in the takeout box's tooltip
    -- ranking, falling back to the box item's image
    local out = {}
    for _, cr in ipairs(GetCrafts()) do
        if cr.id and cr.id ~= "" and cr.components and #cr.components > 0
            and RestaurantHasAccess(prop.restaurant_id, cr.group) then
            local valid = true
            local comps = {}
            for _, c in ipairs(cr.components) do
                if not ItemExists(c) and not IsProductItem(c) then valid = false end
                comps[#comps + 1] = { item = c, label = GetItemLabel(c), image = GetItemImage(c) }
            end
            if valid then
                out[#out + 1] = {
                    output = cr.id, label = cr.label or cr.id,
                    image = FoodImageUrl(cr, BoxItemName()),
                    components = comps,
                }
            end
        end
    end
    return out
end)

-- The layers of `b` whose reservation id is in `ids`, in the SAME order as ids
-- (which arrive bottom-to-top from the client stack).
local function orderedLayers(b, ids)
    local byId = {}
    for _, l in ipairs(b.layers) do if l.id then byId[l.id] = l end end
    local out = {}
    for _, v in ipairs(ids or {}) do
        local l = byId[tonumber(v)]
        if l then out[#out + 1] = l end
    end
    return out
end

-- Does a stack (its buildProvides multiset) contain everything a recipe requires?
-- Extras are allowed — that's how alterations/variations pass.
local function stackSatisfies(provides, asm)
    for _, c in ipairs(asm.components or {}) do
        local need = 0
        for _, c2 in ipairs(asm.components) do if c2 == c then need = need + 1 end end
        if (provides[c] or 0) < need then return false end
    end
    return true
end

-- The CLOSEST product a stack forms: among every recipe whose required components are
-- all present (extras = variations), the most specific one (most components). nil if
-- the stack forms no product at all.
local function bestAssemblyForLayers(layers, rid)
    if #layers == 0 then return nil end
    local provides = buildProvides(layers)
    local best, bestScore
    for _, asm in ipairs(GetAssembly()) do
        -- a recipe whose group this restaurant doesn't carry can't be made here
        if stackSatisfies(provides, asm) and (rid == nil or RestaurantHasAccess(rid, asm.group)) then
            local score = #(asm.components or {})
            if not bestScore or score > bestScore then best, bestScore = asm, score end
        end
    end
    return best
end

-- The most specific CRAFT a bag's contents form: among crafts whose required
-- components are all present (extras ride as variation), the one with the most
-- components. nil if the contents match no craft. Mirrors bestAssemblyForLayers but
-- over the `crafts` setting (stackSatisfies reads .components, so it works as-is).
local function bestCraftForLayers(layers, rid)
    if #layers == 0 then return nil end
    local provides = buildProvides(layers)
    local best, bestScore
    for _, cr in ipairs(GetCrafts()) do
        if cr.id and cr.id ~= "" and cr.components and #cr.components > 0
            and stackSatisfies(provides, cr) and (rid == nil or RestaurantHasAccess(rid, cr.group)) then
            local score = #cr.components
            if not bestScore or score > bestScore then best, bestScore = cr, score end
        end
    end
    return best
end

-- Capture each product layer's own build stack off the exact instance being
-- consumed (BEFORE removal, so the nested variation survives inside the output's
-- meta), then tally consumption per source (bun halves round up to whole buns),
-- verify, and remove. Layers consume the exact build variation they reserved
-- (sig) — from the tray, or from the matching inventory slot for "inv" products.
-- Shared by recipe makes and meal makes. Returns true, or nil + error message.
local function consumeLayers(src, b, id, layers)
    for _, l in ipairs(layers) do
        if l.sig and l.sig ~= "" then
            l.stack = (l.source == "tray")
                and TrayTopMeta(b.rid, id, l.item, l.sig)
                or invVariationMeta(src, l.item, l.sig)
            -- A bare TOPPED product (a cheesed patty) is stored standalone as its
            -- one-layer SELF stack; flatten it back onto the layer so this layer
            -- records `top` directly (like a grill-cheesed patty) instead of a
            -- redundant nested tower — keeps the rebuilt product's meta 1:1 with an
            -- originally-topped one.
            local top = selfStackTop(l.item, l.stack)
            if top then
                l.top = l.top or top
                l.half = l.half or (l.stack[1].half)
                l.stack = nil
            end
        end
    end

    local trayUnits, invUnits = {}, {}
    for _, l in ipairs(layers) do
        local k = l.item .. "|" .. (l.sig or "")
        local units = (l.source == "tray") and trayUnits or invUnits
        units[k] = units[k] or { item = l.item, sig = l.sig, u = 0 }
        units[k].u = units[k].u + layerUnits(l)
    end
    local needTray, needInv = {}, {}
    for k, t in pairs(trayUnits) do needTray[k] = { item = t.item, sig = t.sig, n = math.ceil(t.u) } end
    for k, t in pairs(invUnits) do needInv[k] = { item = t.item, sig = t.sig, n = math.ceil(t.u) } end

    for _, t in pairs(needTray) do
        if GetTrayCount(b.rid, id, t.item, t.sig) < t.n then
            return nil, _L("cook_cooked_changed")
        end
    end
    for _, t in pairs(needInv) do
        -- raw components come from the shared stock pool (personal inventory once
        -- dry); inventory-held products (with a build-stack signature) come from the
        -- matching inventory slot. A pool item's variation is always plain.
        local fromPool = isPoolItem(t.item) and (GetStockCount(b.rid, t.item) or 0) > 0
        local have = fromPool and GetStockCount(b.rid, t.item)
            or invVariationCount(src, t.item, t.sig)
        if have < t.n then
            return nil, _L("cook_missing_components")
        end
    end
    for _, t in pairs(needTray) do RemoveTray(b.rid, id, t.item, t.n, t.sig) end
    for _, t in pairs(needInv) do
        if isPoolItem(t.item) and (GetStockCount(b.rid, t.item) or 0) >= t.n then
            RemoveStock(b.rid, t.item, t.n)
        else removeInvVariation(src, t.item, t.sig, t.n) end
    end
    return true
end

-- Drop just these layers' reservations; other stacks keep building.
local function dropLayerReservations(src, b, layers)
    local wanted = {}
    for _, l in ipairs(layers) do wanted[l.id] = true end
    local keep = {}
    for _, l in ipairs(b.layers) do if not (l.id and wanted[l.id]) then keep[#keep + 1] = l end end
    b.layers = keep
    if #b.layers == 0 then PrepBuilds[src] = nil end
end

-- Consume a stack's reserved layers and produce `asm`'s output into the tray, tagged
-- with the EXACT ordered build stack (order/cheese/bun-half) so it stays that exact
-- variation — takeable apart later, and preserved through to delivery. The whole pile
-- is consumed, extras included. Assumes the superset match is already verified.
local function makeStack(src, b, id, ids, asm)
    local layers = orderedLayers(b, ids)
    if #layers == 0 then return { ok = false, error = _L("cook_nothing_to_build") } end
    local ok, err = consumeLayers(src, b, id, layers)
    if not ok then return { ok = false, error = err } end
    dropLayerReservations(src, b, layers)

    -- The exact ordered stack (bottom-to-top), each layer's topping + half kept,
    -- plus any nested build stack a product layer carried in. New layers record
    -- `top` (never a numeric cheese field).
    local stackMeta = {}
    for _, l in ipairs(layers) do
        stackMeta[#stackMeta + 1] = { item = l.item, top = l.top, half = l.half, stack = l.stack }
    end
    AddTray(b.rid, id, asm.output, 1, stackMeta)
    -- sig + a render spec for the made product, so the client can seat it back in
    -- place (a burger built directly on a serving tray stays on the tray).
    return { ok = true, output = asm.output, label = asm.label or asm.output,
             sig = TraySig(stackMeta), spec = compSpec({ item = asm.output, stack = stackMeta }) }
end

-- Turn everything arranged on a serving tray into ONE meal item. The client sends
-- the tray's piles — each pile's reservation ids (bottom-to-top) plus its (dx, dy)
-- offset from the tray centre — and the meal's metadata records every layer WITH
-- its position, so it re-renders 1:1 (tray, paper, and each item exactly where it
-- was) wherever it's set back down. Offsets are clamped and quantized to 1cm so
-- the layout is part of the variation signature (TraySig) deterministically.
local function quantOffset(v)
    v = tonumber(v) or 0.0
    if v > 2.0 then v = 2.0 elseif v < -2.0 then v = -2.0 end
    return math.floor(v * 100 + 0.5) / 100
end

-- Does this layer sit on a boxable base? The box only takes builds whose bottom
-- layer is (or derives from) a `box_base` ingredient (the pizza dough by default):
-- the pile's bottom layer must be a box_base ingredient itself, a product whose
-- recorded build stack starts with one, or (stackless legacy instance) a product
-- whose base recipe's first component is one — any cook state.
local function isBoxBase(item)
    local d = IngredientDef(item)
    return d and d.box_base == true
end
local function boxBaseLayer(l)
    if not l then return false end
    if isBoxBase(l.item) then return true end
    local st = type(l.stack) == "table" and l.stack[1] or nil
    if type(st) == "table" and isBoxBase(st.item) then return true end
    local asm = findAssembly(l.item)
    if not asm then
        local rout = recipeForOutput(l.item)
        asm = rout and findAssembly(rout.input_item) or nil
    end
    return (asm and type(asm.components) == "table" and isBoxBase(asm.components[1])) and true or false
end

lib.callback.register("pickle_restaurants:cooking:prepMakeMeal", function(src, d)
    local b = PrepBuilds[src]; if not b then return { ok = false } end
    if not HasPerm(b.rid, src, "cook") then return { ok = false } end
    -- The meal item is what gets GENERATED — never a requirement. It lands in the
    -- tray holding (our own store) whether or not the item is installed yet; only
    -- trayToInventory needs the real item.
    local mealItem = MealItem()
    local id = GetIdentifier(src)
    -- box = the arrangement was made in a pizza box, not on a serving tray. The
    -- client gates the drop too, but the NUI is untrusted — re-check every pile.
    local boxed = (d and d.box) and true or false
    -- Keep the piles grouped (each is one thing dropped on the tray) AND a flat list
    -- of every layer to consume. A pile whose raw parts form a recipe (a bun + patty
    -- the cook never pressed "Make" on) is auto-assembled into that product below, so
    -- the meal records ONE burger layer — not loose bun + patty. Each pile also
    -- remembers its best assembly so we don't re-run the match after consumption.
    local piles, layers = {}, {}
    for _, pile in ipairs((d and d.items) or {}) do
        local dx, dy = quantOffset(pile.dx), quantOffset(pile.dy)
        local ordered = orderedLayers(b, pile.ids)
        if boxed and not boxBaseLayer(ordered[1]) then
            return { ok = false, error = _L("cook_only_boxable_in_box") }
        end
        piles[#piles + 1] = { ordered = ordered, dx = dx, dy = dy,
                              asm = bestAssemblyForLayers(ordered, b.rid) }
        for _, l in ipairs(ordered) do layers[#layers + 1] = l end
    end
    if #layers == 0 then return { ok = false, error = boxed and _L("cook_nothing_in_box") or _L("cook_nothing_on_tray") } end
    -- consumeLayers pins each product layer's nested stack onto l.stack (read below).
    local ok, err = consumeLayers(src, b, id, layers)
    if not ok then return { ok = false, error = err } end
    dropLayerReservations(src, b, layers)

    local meta = {}
    for _, pile in ipairs(piles) do
        if pile.asm then
            -- the pile satisfies a recipe → emit the assembled product as ONE meal
            -- layer, its components nested (exactly like makeStack's stackMeta), so a
            -- built-but-unmade burger is indistinguishable from a pre-made one
            local compStack = {}
            for _, l in ipairs(pile.ordered) do
                compStack[#compStack + 1] = { item = l.item, top = l.top, half = l.half, stack = l.stack }
            end
            meta[#meta + 1] = { item = pile.asm.output, stack = compStack, dx = pile.dx, dy = pile.dy }
        else
            for _, l in ipairs(pile.ordered) do
                meta[#meta + 1] = { item = l.item, top = l.top, half = l.half,
                                    stack = l.stack, dx = pile.dx, dy = pile.dy }
            end
        end
    end
    -- the box flag rides the FIRST layer (layer tables are dicts, so it's JSON-safe;
    -- TraySig appends ^box) — that's what makes it set back down as its box
    if boxed then meta[1].box = true end
    AddTray(b.rid, id, mealItem, 1, meta)
    return { ok = true, output = mealItem,
             label = (boxed and "Boxed " or "") .. GetItemLabel(mealItem) }
end)

-- Turn everything dropped in the TAKEOUT BOX into ONE takeout_box item — how every
-- bag-KIND food (soup, salad…) is created. Unlike a meal, arrangement doesn't
-- matter: the contents must MATCH a defined food (all its required components
-- present; the most specific wins). The food id rides the FIRST meta layer (TraySig
-- appends ~id), so each food is its own POS variation; the component layers are
-- recorded so the box's contents stay readable. The box item is what gets
-- GENERATED — never a requirement; it lands in the tray holding whether or not
-- installed (only → inventory needs it).
lib.callback.register("pickle_restaurants:cooking:prepMakeBox", function(src, d)
    local b = PrepBuilds[src]; if not b then return { ok = false } end
    if not HasPerm(b.rid, src, "cook") then return { ok = false } end
    local boxItem = BoxItemName()
    local id = GetIdentifier(src)
    -- flatten every dropped pile into one component list (arrangement is irrelevant)
    local layers = {}
    for _, pile in ipairs((d and d.items) or {}) do
        for _, l in ipairs(orderedLayers(b, pile.ids)) do layers[#layers + 1] = l end
    end
    if #layers == 0 then return { ok = false, error = _L("cook_nothing_in_box_food") } end
    -- must form a defined food; re-checked server-side (the NUI is untrusted)
    local cr = bestCraftForLayers(layers, b.rid)
    if not cr then return { ok = false, error = _L("cook_no_craft_match") } end
    local ok, err = consumeLayers(src, b, id, layers) -- pins each product layer's nested stack
    if not ok then return { ok = false, error = err } end
    dropLayerReservations(src, b, layers)

    -- component layers recorded (each keeping topping/half/nested stack); the food
    -- id flagged on the first layer so TraySig makes it its own variation
    local meta = {}
    for _, l in ipairs(layers) do
        meta[#meta + 1] = { item = l.item, top = l.top, half = l.half, stack = l.stack }
    end
    meta[1].craft = cr.id
    AddTray(b.rid, id, boxItem, 1, meta)
    local label = boxFoodRender(cr)
    return { ok = true, output = boxItem, craft = cr.id,
             label = label or GetItemLabel(boxItem),
             sig = TraySig(meta), spec = compSpec({ item = boxItem, stack = meta }) }
end)

-- Pack everything dropped in the RESTAURANT BAG into ONE restaurant_bag item — the
-- takeaway carrier (the eat-in serving tray's counterpart). No recipe matching and
-- no arrangement: whatever finished food and drink is in the bag is recorded, one
-- meta layer per pile, and the customer eats it back out one item at a time. A pile
-- of loose parts that happens to form a recipe is assembled into that product first
-- (exactly like the serving tray), so a bagged burger is one burger, not four parts.
lib.callback.register("pickle_restaurants:cooking:prepMakeBag", function(src, d)
    local b = PrepBuilds[src]; if not b then return { ok = false } end
    if not HasPerm(b.rid, src, "cook") then return { ok = false } end
    local bagItem = BagItemName()
    local id = GetIdentifier(src)
    local piles, layers = {}, {}
    for _, pile in ipairs((d and d.items) or {}) do
        local ordered = orderedLayers(b, pile.ids)
        piles[#piles + 1] = { ordered = ordered, asm = bestAssemblyForLayers(ordered, b.rid) }
        for _, l in ipairs(ordered) do layers[#layers + 1] = l end
    end
    if #layers == 0 then return { ok = false, error = _L("cook_nothing_in_bag") } end
    local ok, err = consumeLayers(src, b, id, layers)
    if not ok then return { ok = false, error = err } end
    dropLayerReservations(src, b, layers)

    local meta = {}
    for _, pile in ipairs(piles) do
        if pile.asm then
            local compStack = {}
            for _, l in ipairs(pile.ordered) do
                compStack[#compStack + 1] = { item = l.item, top = l.top, half = l.half, stack = l.stack }
            end
            meta[#meta + 1] = { item = pile.asm.output, stack = compStack }
        else
            for _, l in ipairs(pile.ordered) do
                meta[#meta + 1] = { item = l.item, top = l.top, half = l.half, stack = l.stack }
            end
        end
    end
    AddTray(b.rid, id, bagItem, 1, meta)
    return { ok = true, output = bagItem, count = #meta,
             label = GetItemLabel(bagItem),
             sig = TraySig(meta), spec = compSpec({ item = bagItem, stack = meta }) }
end)

-- Build ONE stack into a chosen recipe (the tooltip's Make). The client sends the
-- output plus the stack's reservation ids (bottom-to-top). Alterations are allowed:
-- the stack only needs to CONTAIN the recipe's required components.
lib.callback.register("pickle_restaurants:cooking:prepMakeStack", function(src, d)
    local b = PrepBuilds[src]; if not b then return { ok = false } end
    if not HasPerm(b.rid, src, "cook") then return { ok = false } end
    local asm = findAssembly(d and d.output)
    if not asm then return { ok = false, error = _L("cook_unknown_recipe") } end
    if not RestaurantHasAccess(b.rid, asm.group) then return { ok = false, error = _L("cook_unknown_recipe") } end
    local layers = orderedLayers(b, d.ids)
    if #layers == 0 then return { ok = false, error = _L("cook_nothing_to_build") } end
    if not stackSatisfies(buildProvides(layers), asm) then return { ok = false, error = _L("cook_missing_components") } end
    return makeStack(src, b, GetIdentifier(src), d.ids, asm)
end)

-- Apply a finish tool (frosting…) to ONE reserved part on the prep table. The
-- client owns the rub/coverage animation; everything consumable is re-validated
-- here — the reservation, the (tool, target, flavor) config triple, and the tool
-- item — before the target layer is consumed together with 1 tool item. The
-- finished output lands in the tray with the flavor recorded as its build-stack
-- metadata (part of the TraySig, so each flavor is its own variation), and the
-- response carries sig + a render spec so the client can seat the finished prop
-- exactly where the target was.
lib.callback.register("pickle_restaurants:cooking:applyFinish", function(src, d)
    local prop = PropCache[tonumber(d and d.prop_id)]
    if not prop or StationType(prop) ~= "kitchen_prep" then return { ok = false } end
    if not HasPerm(prop.restaurant_id, src, "cook") then return { ok = false } end
    local b = PrepBuilds[src]
    if not b or b.prop_id ~= prop.id then return { ok = false, error = _L("cook_item_changed") } end
    local layer
    for _, l in ipairs(b.layers) do
        if l.id == tonumber(d and d.id) then layer = l break end
    end
    if not layer then return { ok = false, error = _L("cook_item_changed") } end
    -- Only configured (cooked) targets pass; raw/burnt items never match a target.
    local cfg, target, flavor = findFinish(d and d.tool, layer.item, d and d.flavor)
    if not cfg or not target or not flavor then return { ok = false, error = _L("cook_cant_apply") } end
    if not RestaurantHasAccess(prop.restaurant_id, cfg.group) then return { ok = false, error = _L("cook_cant_apply") } end
    if not ItemExists(cfg.tool) then return { ok = false } end
    -- finish tools come from the shared restaurant stock pool (personal inventory once dry)
    if poolInvCount(src, prop.restaurant_id, cfg.tool) < 1 then
        return { ok = false, error = _L("cook_no_tool_left", GetItemLabel(cfg.tool)) }
    end

    local id = GetIdentifier(src)
    -- Gate: a target may require the part to ALREADY carry another finish (sprinkles
    -- require frosting). Since a frosted doughnut is now the same cooked_doughnut item,
    -- this is enforced on METADATA — peek the reserved instance's build stack read-only
    -- (same source consumeLayers uses) so nothing is consumed when the gate rejects.
    if target.requires_finish then
        local pmeta = (layer.sig and layer.sig ~= "")
            and ((layer.source == "tray")
                and TrayTopMeta(b.rid, id, layer.item, layer.sig)
                or invVariationMeta(src, layer.item, layer.sig)) or nil
        local top = type(pmeta) == "table" and pmeta[1]
        if not (type(top) == "table" and top.tool == target.requires_finish) then
            return { ok = false, error = _L("cook_frost_first") }
        end
    end

    local ok, err = consumeLayers(src, b, id, { layer }) -- sig-pinned; captures the target's own nested stack
    if not ok then return { ok = false, error = err } end
    dropLayerReservations(src, b, { layer })
    poolInvConsume(src, prop.restaurant_id, cfg.tool, 1)

    -- ONE meta layer: the finished target with its flavor and the TOOL that applied it
    -- (so a collapsed cooked_doughnut resolves its finish from meta), plus whatever
    -- nested stack it carried, so the exact variation survives every round trip.
    local meta = { { item = layer.item, top = layer.top, half = layer.half,
                     stack = layer.stack, tool = cfg.tool,
                     flavor = flavor.id, flavorLabel = flavor.label or flavor.id } }
    AddTray(b.rid, id, target.output, 1, meta)
    return { ok = true, output = target.output,
             label = (flavor.label or flavor.id) .. " " .. GetItemLabel(target.output),
             sig = TraySig(meta), spec = compSpec({ item = target.output, stack = meta }) }
end)

-- Refund any un-redeemed filled-tray credits back to the shared pool. Refunds to the
-- larder even if the mix originally came from a cook's pockets (the abandoned-fill
-- edge case) — never destroys value, at worst gifts the restaurant a little stock.
local function refundBakePending(src)
    local p = BakePending[src]
    if not p then return end
    local total = 0
    for _, n in pairs(p.outs or {}) do total = total + (tonumber(n) or 0) end
    if total > 0 and p.mix and p.rid then AddStock(p.rid, p.mix, total) end
    BakePending[src] = nil
end

-- Rub-to-fill: a placed cake tin / cookie tray is filled with the shared baking mix.
-- Consumes 1 mix from the pool (personal inventory once dry) and records a pending
-- credit for the tray's oven-ready output. The tray itself is free client equipment.
lib.callback.register("pickle_restaurants:cooking:fillBakeTray", function(src, d)
    local prop = PropCache[tonumber(d and d.prop_id)]
    if not prop or StationType(prop) ~= "kitchen_prep" then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    -- resolve the fill tool that owns the requested tray kind (the baking config is
    -- a LIST, one entry per fill tool — each mix fills only its own trays)
    local mix, tray
    for _, b in ipairs(GetBakingList()) do
        if b.mix_item and ItemExists(b.mix_item) then
            for _, t in ipairs(b.trays or {}) do
                if t.kind == (d and d.kind) then mix, tray = b.mix_item, t break end
            end
        end
        if tray then break end
    end
    if not mix or not tray or not tray.output then return { ok = false } end
    if not RestaurantHasAccess(rid, tray.group) then return { ok = false, error = _L("cook_cant_apply") } end
    -- The output is a tray-only uncooked intermediate (raw_cake / raw_cookie), collected
    -- into the cooked-items tray — never required to be an installed inventory item.
    if poolInvCount(src, rid, mix) < 1 then
        return { ok = false, error = _L("cook_no_tool_left", GetItemLabel(mix)) }
    end
    poolInvConsume(src, rid, mix, 1)
    local p = BakePending[src]
    -- switching restaurants without a station close: refund the old larder's un-redeemed
    -- credits before starting a fresh tally, so they're never silently dropped
    if p and p.rid ~= rid then refundBakePending(src); p = nil end
    if not p then p = { rid = rid, mix = mix, outs = {} }; BakePending[src] = p end
    p.outs[tray.output] = (p.outs[tray.output] or 0) + 1
    return { ok = true, output = tray.output, label = GetItemLabel(tray.output) }
end)

-- Collect a filled baking tray: redeems one pending credit for its oven-ready output.
-- The output (raw_cake / raw_cookie) is an assembled-but-uncooked INTERMEDIATE — it's
-- tray-only, never a real inventory item (like raw_pizza), so it lands in the
-- per-player cooked-items tray, where getTray flags it "uncooked" (it's a cook-recipe
-- input) and files it under the Uncooked Items tab to be dragged into the oven. The
-- mix was already spent at fill time, so this only grants the tray credit.
lib.callback.register("pickle_restaurants:cooking:bakeTrayToInv", function(src, d)
    local prop = PropCache[tonumber(d and d.prop_id)]
    if not prop then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    local output = d and d.output
    local p = BakePending[src]
    if not output or not p or (p.outs[output] or 0) < 1 then
        return { ok = false, error = _L("cook_item_changed") }
    end
    p.outs[output] = p.outs[output] - 1
    AddTray(rid, GetIdentifier(src), output, 1, nil)
    return { ok = true, output = output, label = GetItemLabel(output) }
end)

-- Save a whole stack as its CLOSEST product — the drag-whole-stack-to-hotbar and
-- exit path. Auto-picks the most specific recipe the stack satisfies and makes it,
-- variation preserved; returns noMatch when the stack forms no product (the caller
-- then just returns the parts to holdings).
lib.callback.register("pickle_restaurants:cooking:prepSaveStack", function(src, d)
    local b = PrepBuilds[src]; if not b then return { ok = false } end
    if not HasPerm(b.rid, src, "cook") then return { ok = false } end
    local layers = orderedLayers(b, d and d.ids)
    if #layers == 0 then return { ok = false } end
    local asm = bestAssemblyForLayers(layers, b.rid)
    if not asm then return { ok = false, noMatch = true } end
    return makeStack(src, b, GetIdentifier(src), d.ids, asm)
end)

-- Take a finished product back apart on the prep table. It's "un-made": the one
-- assembled item is consumed from the tray and each of its components is credited
-- back into the player's holdings (tray for cooked parts, inventory for raw ones),
-- then immediately reserved as a placed part. From there everything is a normal
-- staged component — drag one off to keep it, or rebuild the same/lesser item — so
-- removal and exit-refund flow through the existing reservation paths untouched.
lib.callback.register("pickle_restaurants:cooking:prepDecompose", function(src, d)
    local prop = PropCache[tonumber(d and d.prop_id)]
    if not prop or StationType(prop) ~= "kitchen_prep" then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    local item = d and d.item
    -- a MEAL un-makes the same way — no recipe; its recorded layout IS the definition
    local isMeal = item ~= nil and item == MealItem()
    local asm = findAssembly(item)
    if not asm and not isMeal then return { ok = false, error = _L("cook_cant_take_apart") } end
    local id = GetIdentifier(src)
    local sig = (type(d.sig) == "string") and d.sig or nil

    -- A finished (frosted…) instance is terminal: the applied frosting can't be
    -- recovered, so it never comes apart — checked on the meta (per-instance)
    -- because a legacy stack-assembled instance of the same output item may
    -- legitimately still decompose on servers whose DB keeps the old recipe.
    local function isFinishedMeta(m)
        return type(m) == "table" and m[1] ~= nil and m[1].flavor ~= nil
    end

    -- Products/meals are stored at cheese 0 — in the tray, or (source "inv") on an
    -- inventory slot whose metadata carries the exact build/layout.
    local meta
    if d.source == "inv" then
        if invVariationCount(src, item, 0, sig) < 1 then return { ok = false, error = _L("cook_none_to_take") } end
        meta = invVariationMeta(src, item, 0, sig)
        if isMeal and not (type(meta) == "table" and #meta > 0) then
            return { ok = false, error = _L("cook_meal_empty") }
        end
        if isFinishedMeta(meta) then return { ok = false, error = _L("cook_cant_take_apart") } end
        removeInvVariation(src, item, 0, sig, 1)
    else
        if GetTrayCount(rid, id, item, sig) < 1 then return { ok = false, error = _L("cook_none_to_take") } end
        -- The exact stack this was built from (order/cheese/bun-half intact), else recipe.
        meta = TrayTopMeta(rid, id, item, sig)
        if isMeal and not (type(meta) == "table" and #meta > 0) then
            return { ok = false, error = _L("cook_meal_empty") }
        end
        if isFinishedMeta(meta) then return { ok = false, error = _L("cook_cant_take_apart") } end
        RemoveTray(rid, id, item, 1, sig)
    end
    local comps = compsFromMeta(asm or { components = {} }, meta)

    local b = PrepBuilds[src]
    if b and b.prop_id ~= prop.id then b = nil end
    if not b then b = { prop_id = prop.id, rid = rid, seq = 0, layers = {} }; PrepBuilds[src] = b end

    -- The tray meta a component carries as a STANDALONE instance: its own nested
    -- build stack (a pizza), or — for a bare topped product (a cheesed patty) — the
    -- one-layer self stack that preserves its topping through the tray round trip.
    -- nil for a plain component (refunded as a simple count).
    local function compStack(c)
        if c.stack then return c.stack end
        if c.top and isTrayItem(c.item) then return { { item = c.item, top = c.top } } end
        return nil
    end

    -- Refund the item back into holdings, aggregated per item so a bun's two halves
    -- round up to one whole; the layers below stay separate for the stack. A product
    -- with a build stack (or a topping) refunds ONE AT A TIME with that stack as the
    -- instance meta, so the pizza (or cheesed patty) that came out is still exact.
    -- All tray rows are cheese-0 now.
    local refund = {}
    for _, c in ipairs(comps) do
        local st = compStack(c)
        if st and isTrayItem(c.item) then
            AddTray(rid, id, c.item, 1, st)
        else
            local u = c.half and 0.5 or 1.0
            local key = c.item
            refund[key] = refund[key] or { item = c.item, tray = isTrayItem(c.item), units = 0 }
            refund[key].units = refund[key].units + u
        end
    end
    for _, r in pairs(refund) do
        local n = math.ceil(r.units)
        -- a raw component pulled out of a decomposed product returns to the shared
        -- stock POOL (symmetric with how it was consumed); tray products go to the
        -- tray, anything else falls back to personal inventory
        if r.tray then AddTray(rid, id, r.item, n)
        elseif isPoolItem(r.item) then AddStock(rid, r.item, n)
        else Inventory.AddItem(src, r.item, n) end
    end

    -- Recreate one reserved part per layer, IN ORDER (no sorting), so the rebuilt
    -- stack is identical to what was taken apart — positions and duplicates and all.
    -- A product layer reserves its exact variation (sig of its standalone stack); a
    -- plain topped part reserves `top` directly.
    local parts = {}
    for _, c in ipairs(comps) do
        local st = compStack(c)
        b.seq = (b.seq or 0) + 1
        b.layers[#b.layers + 1] = { id = b.seq, source = isTrayItem(c.item) and "tray" or "inv",
                                    item = c.item, half = c.half,
                                    top = (not st) and c.top or nil,
                                    sig = (st and isTrayItem(c.item)) and TraySig(st) or nil, stack = st }
        local spec = compSpec(c); spec.id = b.seq
        parts[#parts + 1] = spec
    end
    -- a boxed meal (flag on the first meta layer) sets back down as its pizza box
    local isBox = isMeal and type(meta) == "table" and meta[1] ~= nil and meta[1].box and true or nil
    return { ok = true, parts = parts, meal = isMeal or nil, box = isBox }
end)

-- Read-only preview: the component parts a product WOULD decompose into, without
-- consuming or reserving anything. Drives the full-stack drag preview so the whole
-- stack follows the cursor (not just the product's single prop).
lib.callback.register("pickle_restaurants:cooking:prepDecomposePeek", function(src, d)
    local prop = PropCache[tonumber(d and d.prop_id)]
    if not prop or StationType(prop) ~= "kitchen_prep" then return { ok = false } end
    if not HasPerm(prop.restaurant_id, src, "cook") then return { ok = false } end
    local item = d and d.item
    local isMeal = item ~= nil and item == MealItem()
    local asm = findAssembly(item)
    if not asm and not isMeal then return { ok = false } end
    local id = GetIdentifier(src)
    local sig = (type(d.sig) == "string") and d.sig or nil
    local meta
    if d.source == "inv" then
        if invVariationCount(src, item, 0, sig) < 1 then return { ok = false } end
        meta = invVariationMeta(src, item, 0, sig)
    else
        if GetTrayCount(prop.restaurant_id, id, item, sig) < 1 then return { ok = false } end
        meta = TrayTopMeta(prop.restaurant_id, id, item, sig)
    end
    if isMeal and not (type(meta) == "table" and #meta > 0) then return { ok = false } end
    -- finished (frosted) instances never come apart — mirror prepDecompose
    if type(meta) == "table" and meta[1] ~= nil and meta[1].flavor ~= nil then return { ok = false } end
    local comps = compsFromMeta(asm or { components = {} }, meta)
    local parts = {}
    for _, c in ipairs(comps) do parts[#parts + 1] = compSpec(c) end
    -- a boxed meal previews as its pizza box, not a serving tray
    local isBox = isMeal and type(meta) == "table" and meta[1] ~= nil and meta[1].box and true or nil
    return { ok = true, parts = parts, meal = isMeal or nil, box = isBox }
end)

-- closing the station / dropping just discards the reservation (nothing consumed)
RegisterNetEvent("pickle_restaurants:cooking:prepClose", function()
    PrepBuilds[source] = nil
    refundBakePending(source)
end)
AddEventHandler("playerDropped", function()
    PrepBuilds[source] = nil
    refundBakePending(source)
end)

-- send active items to clients that (re)sync
RegisterNetEvent("pickle_restaurants:requestSync", function()
    local list = {}
    for _, it in pairs(CookingItems) do
        list[#list + 1] = activeEntry(it)
    end
    TriggerClientEvent("pickle_restaurants:cooking:bulk", source, list)
end)

-- drop a prop's cooking items if the prop is deleted
AddEventHandler("pickle_restaurants:propDeleted", function(propId)
    StationOccupancy[tonumber(propId)] = nil
    for uid, it in pairs(CookingItems) do
        if it.prop_id == propId then
            CookingItems[uid] = nil
            TriggerClientEvent("pickle_restaurants:cooking:remove", -1, uid)
        end
    end
end)

-- The admin re-placed a restaurant's kitchen shell: carry that restaurant's
-- free-placed virtual items along (translate + rotate about the shell origin).
-- Slot items (oven/fry/soda) seat relative to the station entity and need
-- nothing. No client event: virtual items only render inside a session, any
-- live session there is force-closed by the mirrored client shellMoved, and
-- the next session replays the shifted coords fresh via getActive — pushing
-- moves would only teleport props on-screen for the closing occupant.
AddEventHandler("pickle_restaurants:shellMoved", function(rid, old, new)
    if not old then return end
    local dh = math.rad((new.heading or 0.0) - (old.heading or 0.0))
    local c, s = math.cos(dh), math.sin(dh)
    for _, it in pairs(CookingItems) do
        local prop = PropCache[it.prop_id]
        if it.rid == rid and prop and prop.prop_type == "virtual_point" and not it.method and it.x then
            local rx, ry = it.x - old.x, it.y - old.y
            it.x = new.x + (rx * c - ry * s)
            it.y = new.y + (rx * s + ry * c)
            it.z = it.z + (new.z - old.z)
        end
    end
end)
