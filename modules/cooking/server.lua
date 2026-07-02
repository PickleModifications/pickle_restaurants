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

-- Interactive prep reservations live here. Declared up top (defined further down)
-- so the ingredient/tray callbacks can subtract what a build has reserved from the
-- counts they show — items aren't consumed until Make, but the bar reflects them
-- as "spoken for" the moment they're placed on the table.
local PrepBuilds = {} -- [src] = { prop_id, rid, seq, layers = { {id, source, item, cheese, half} … } }
local layerUnits      -- fwd: units a single layer contributes (bun half = 0.5)
local reservedUnits   -- fwd: units of (source,item,cheese) a build already reserved

local function findDrink(item)
    for _, d in ipairs(GetSetting("drinks", {})) do
        if d.input == item then return d end
    end
end

local function findAssembly(output)
    for _, a in ipairs(GetSetting("assembly", {})) do
        if a.output == output then return a end
    end
end

local function broadcastSpawn(it)
    TriggerClientEvent("pickle_restaurants:cooking:spawn", -1, it.uid, it.model, it.x, it.y, it.z, it.state)
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
-- per-face state + cook progress, and which face is on the grill.
local function dualPayload(it)
    local give = dualGiveItem(it)
    return {
        uid = it.uid, dual = true, input = it.recipe.input_item,
        x = it.x, y = it.y, z = it.z,
        sides = { sideProgress(it, 1), sideProgress(it, 2) },
        cooking = it.down, flipped = it.flipped, cheese = it.cheese or "none",
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
            TriggerClientEvent("pickle_restaurants:cooking:update", -1, uid, cur.model, cur.state)
        end
        broadcastGate(cur)
        armGateTimer(cur)
    end)
end

-- one sync entry for a (re)connecting / station-opening client
local function activeEntry(it)
    if it.dual then return dualPayload(it) end
    if it.method == "oven" or it.method == "fry" then
        local give = cookGiveItem(it)
        return { uid = it.uid, method = it.method, model = it.model, prop_id = it.prop_id,
                 door = it.door, slot = it.slot, state = it.state, prog = singleProgress(it),
                 stack = it.stack,
                 give = give, giveLabel = give and GetItemLabel(give) or nil,
                 giveImage = give and GetItemImage(give) or nil }
    end
    return { uid = it.uid, model = it.model, x = it.x, y = it.y, z = it.z, state = it.state }
end

-- A world model for an item: cook recipe outputs/inputs, assembly outputs, drink
-- outputs, else the configurable `prep_models` map (raw veg, toppings, doughs — any
-- item an admin maps to a prop). nil = no prop, and the item falls back to a flat
-- 2D chip. Used so the prep station can spawn a live 3D prop to drag out and stack.
function itemModel(item)
    -- An explicit prep_models mapping wins over the derived defaults below — that's
    -- how a fryer batch output (cooked as the basket-pile model) is held/stacked as
    -- its single-serving prop instead.
    local mapped = GetSetting("prep_models", {})[item]
    if mapped then return mapped end
    for _, r in ipairs(RecipeCache) do
        if r.output_cooked_item == item then return r.cooked_model end
        if r.output_burnt_item == item then return r.burnt_model end
        if r.input_item == item then return r.raw_model end
    end
    for _, a in ipairs(GetSetting("assembly", {})) do if a.output == item then return a.model end end
    for _, dd in ipairs(GetSetting("drinks", {})) do if dd.output == item then return dd.model end end
    -- The cheese slice is ALWAYS the unmelted slice (_01). _02 is the melted variant,
    -- used only for the stovetop cook animation — never as a stackable/applied slice.
    if item == "cheese" then return "pickle_cheese_applied_01" end
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
    for _, a in ipairs(GetSetting("assembly", {})) do
        if a.output == item then return true end
    end
    return false
end

-- The ordered component layers a product decomposes into: its stored build stack
-- (order, cheese and bun-half intact) or, failing that, the recipe's plain
-- components. Tolerates the older aggregated `count` metadata format.
local function compsFromMeta(asm, meta)
    local comps = {}
    if type(meta) == "table" and #meta > 0 then
        for _, m in ipairs(meta) do
            for _ = 1, (tonumber(m.count) or 1) do
                -- a product layer keeps its own nested build stack (m.stack) so a
                -- pizza inside a burger comes back out as THAT pizza, toppings intact
                comps[#comps + 1] = { item = m.item, cheese = CheeseVal(m.cheese), half = m.half,
                                      stack = (type(m.stack) == "table" and #m.stack > 0) and m.stack or nil }
            end
        end
    else
        for _, c in ipairs(asm.components or {}) do comps[#comps + 1] = { item = c, cheese = 0 } end
    end
    return comps
end

-- The ordered component MODELS a build stack renders as — the given `meta`
-- resolved to props, bottom-to-top (falling back to the item's assembly components
-- when it has no recorded stack). nil when it resolves to fewer than two props
-- (nothing to stack; the base model suffices). Shared by the oven/fryer placement
-- and the tray payload so the drag preview and the placed prop render the same stack.
local function stackModelsFromMeta(item, meta)
    local asm = findAssembly(item)
    if not asm and not (type(meta) == "table" and #meta > 0) then return nil end
    local models = {}
    for _, c in ipairs(compsFromMeta(asm or { components = {} }, meta)) do
        local m = itemModel(c.item)
        if m then models[#models + 1] = m end
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

-- A client part spec for one decomposed layer (no reservation id — that's stamped on
-- when the take-apart actually commits). Shared by the drag preview and the commit so
-- the previewed stack and the placed stack are identical.
local function compSpec(c)
    local dual = dualRecipeForItem(c.item) and true or false
    local spec = {
        item = c.item, source = isTrayItem(c.item) and "tray" or "inv", cheese = c.cheese, half = c.half,
        model = itemModel(c.item), dual = dual,
        cheeseModel = (c.cheese >= 1 and dual) and ((c.cheese == 2) and "pickle_cheese_applied_02" or "pickle_cheese_applied_01") or nil,
    }
    -- a nested product renders as its whole recorded stack (crust swapped to its
    -- cook state), not its single base model, and addresses that exact variation
    if c.stack then
        spec.sig = TraySig(c.stack)
        local models = stackModelsFromMeta(c.item, c.stack)
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
    end
    return spec
end

-- A readable component list for an item's build stack (bun halves collapse to one
-- bun) — drives the inventory tooltip so a variation reads e.g. "Bun, Beef Patty,
-- Lettuce, Tomato".
local function stackDescription(stack)
    if type(stack) ~= "table" then return nil end
    local order, counts = {}, {}
    for _, l in ipairs(stack) do
        if not counts[l.item] then order[#order + 1] = l.item; counts[l.item] = 0 end
        counts[l.item] = counts[l.item] + ((l.item == "bun" and l.half) and 0.5 or 1.0)
    end
    local parts = {}
    for _, key in ipairs(order) do
        local n = math.ceil(counts[key])
        local lbl = GetItemLabel(key)
        parts[#parts + 1] = (n > 1) and (n .. "x " .. lbl) or lbl
    end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

-- The build stack as a structured, ordered component list ({item, label, image,
-- count} per distinct component, bun halves collapsing to one bun) — drives the
-- tray hover tooltip so a variation shows exactly what it's made of, with icons.
local function stackComponents(meta)
    if type(meta) ~= "table" or #meta == 0 then return nil end
    local order, counts = {}, {}
    for _, l in ipairs(meta) do
        for _ = 1, (tonumber(l.count) or 1) do
            if not counts[l.item] then order[#order + 1] = l.item; counts[l.item] = 0 end
            counts[l.item] = counts[l.item] + ((l.item == "bun" and l.half) and 0.5 or 1.0)
        end
    end
    local out = {}
    for _, key in ipairs(order) do
        out[#out + 1] = { item = key, label = GetItemLabel(key), image = GetItemImage(key), count = math.ceil(counts[key]) }
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
    local order, counts = {}, {}
    for _, l in ipairs(meta) do
        for _ = 1, (tonumber(l.count) or 1) do
            if not counts[l.item] then order[#order + 1] = l.item; counts[l.item] = 0 end
            counts[l.item] = counts[l.item] + ((l.item == "bun" and l.half) and 0.5 or 1.0)
        end
    end
    local asm = findAssembly(item)
    if not asm then
        local r = recipeForOutput(item)
        asm = r and findAssembly(r.input_item)
    end
    for _, c in ipairs(asm and asm.components or {}) do
        if counts[c] then counts[c] = counts[c] - 1 end
    end
    local parts = {}
    for _, key in ipairs(order) do
        local n = math.ceil(counts[key])
        if n > 0 then
            parts[#parts + 1] = { item = key, label = GetItemLabel(key), image = GetItemImage(key), count = n }
        end
    end
    return #parts > 0 and parts or nil
end

-- ─── inventory variations ────────────────────────────────────────────────────
-- An inventory-held product carries its build stack / cheese state on its SLOT
-- metadata (written by trayToInventory's buildInvMeta). Where the bridge exposes
-- slots (ox_inventory / qb), these helpers group and consume by exact variation,
-- so a pepperoni pizza item stays a pepperoni pizza through the round-trip.
-- Without slot access they degrade to plain per-item counts.

-- The distinct (cheese, sig) variations of an item in a player's inventory:
-- array of { cheese, sig, count, meta }.
local function invVariations(src, item)
    if not Inventory.GetItemSlots then
        local count = Inventory.GetItemCount(src, item) or 0
        return (count > 0) and { { cheese = 0, sig = "", count = count } } or {}
    end
    local groups, order = {}, {}
    for _, s in ipairs(Inventory.GetItemSlots(src, item) or {}) do
        local m = type(s.metadata) == "table" and s.metadata or {}
        local stack = type(m.stack) == "table" and m.stack or nil
        local cheese = CheeseVal(m.cheese)
        local sig = TraySig(stack)
        local key = cheese .. "|" .. sig
        if not groups[key] then
            groups[key] = { cheese = cheese, sig = sig, count = 0, meta = stack }
            order[#order + 1] = key
        end
        groups[key].count = groups[key].count + (s.count or 1)
    end
    local out = {}
    for _, k in ipairs(order) do out[#out + 1] = groups[k] end
    return out
end

-- Count / stack-meta / remove for one exact inventory variation. sig nil = the
-- whole item regardless of metadata (the legacy raw-component behaviour).
local function invVariationCount(src, item, cheese, sig)
    if sig == nil then return Inventory.GetItemCount(src, item) or 0 end
    local n = 0
    for _, v in ipairs(invVariations(src, item)) do
        if v.sig == sig and v.cheese == CheeseVal(cheese) then n = n + v.count end
    end
    return n
end

local function invVariationMeta(src, item, cheese, sig)
    if sig == nil then return nil end
    for _, v in ipairs(invVariations(src, item)) do
        if v.sig == sig and v.cheese == CheeseVal(cheese) then return v.meta end
    end
end

local function removeInvVariation(src, item, cheese, sig, count)
    if sig == nil or not Inventory.GetItemSlots then
        Inventory.RemoveItem(src, item, count)
        return
    end
    cheese = CheeseVal(cheese)
    for _, s in ipairs(Inventory.GetItemSlots(src, item) or {}) do
        if count <= 0 then return end
        local m = type(s.metadata) == "table" and s.metadata or {}
        local stack = type(m.stack) == "table" and m.stack or nil
        if TraySig(stack) == sig and CheeseVal(m.cheese) == cheese then
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
    local station = prop.prop_type
    local out = {}

    if station == "fryer" or station == "stovetop" then
        for _, recipe in ipairs(RecipeCache) do
            -- Recipes that reference a missing item are hidden until fixed. Inputs
            -- that are themselves an assembled product (an uncooked pizza) aren't
            -- raw ingredients — they file under the "Uncooked Items" tab instead.
            if recipe.station == station and IsRecipeValid(recipe) and not findAssembly(recipe.input_item) then
                local count = Inventory.GetItemCount(src, recipe.input_item)
                if count and count > 0 then
                    out[#out + 1] = { kind = "cook", item = recipe.input_item, label = GetItemLabel(recipe.input_item),
                                      image = GetItemImage(recipe.input_item), count = count }
                end
            end
        end
        -- Cheese is a topping you drag onto a cooked patty (stovetop only). It
        -- renders the real fresh-slice prop in 3D as you drag (no 2D pill).
        if station == "stovetop" and ItemExists("cheese") then
            local count = Inventory.GetItemCount(src, "cheese") or 0
            if count > 0 then
                out[#out + 1] = { kind = "topping", item = "cheese", label = GetItemLabel("cheese"),
                                  image = GetItemImage("cheese"), count = count, model = "pickle_cheese_applied_01" }
            end
        end
    elseif station == "soda_machine" then
        for _, drink in ipairs(GetSetting("drinks", {})) do
            if ItemExists(drink.input) and ItemExists(drink.output) then
                local count = Inventory.GetItemCount(src, drink.input) or 0
                out[#out + 1] = { kind = "drink", item = drink.input, label = drink.label or GetItemLabel(drink.input),
                                  image = GetItemImage(drink.input), count = count }
            end
        end
    elseif station == "kitchen_prep" then
        -- Interactive build: the bar lists the raw components (held in inventory) used
        -- across assembly recipes, PLUS any other mapped prep ingredient — optional
        -- toppings like pepperoni that aren't a *required* component of a recipe but can
        -- be added to a stack as an alteration. Cooked components come from the tray.
        local build = PrepBuilds[src]
        local seen = {}
        local function addComp(comp)
            -- Products (cook/assembly outputs — a cooked patty, a burger) are never
            -- "ingredients": inventory-held ones file under the Cooked/Uncooked tabs.
            if seen[comp] or not ItemExists(comp) or isTrayItem(comp) then return end
            seen[comp] = true
            local count = Inventory.GetItemCount(src, comp) or 0
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
            out[#out + 1] = entry
        end
        for _, asm in ipairs(GetSetting("assembly", {})) do
            for _, comp in ipairs(asm.components or {}) do addComp(comp) end
        end
        for comp in pairs(GetSetting("prep_models", {})) do addComp(comp) end
    end
    return out
end)

-- send all in-progress items to a (re)connecting / station-opening client
lib.callback.register("pickle_restaurants:cooking:getActive", function(_, _)
    local list = {}
    for _, it in pairs(CookingItems) do
        list[#list + 1] = activeEntry(it)
    end
    return list
end)

-- ─── placement (bar -> world) ────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:cooking:place", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false, error = "You don't work here." } end
    local station = prop.prop_type

    cookUid = cookUid + 1
    local uid = cookUid
    -- oven/fryer placements carry a slot instead of world coords, so default xyz
    local it = { uid = uid, rid = rid, prop_id = prop.id, station = station,
                 x = tonumber(d.x) or 0.0, y = tonumber(d.y) or 0.0, z = tonumber(d.z) or 0.0 }

    if (station == "fryer" or station == "stovetop") and d.kind == "cook" then
        local recipe = RecipeByInput[d.item]
        if not recipe or recipe.station ~= station then return { ok = false, error = "Can't cook that here." } end
        local method = RecipeMethod(recipe)

        -- Raw cook-inputs can come from the player's inventory OR from the "Uncooked
        -- Items" tray (e.g. an assembled uncooked pizza dragged straight to the oven).
        -- `sig` pins the pull — tray or inventory slot — to the exact build variation
        -- that was dragged (nil for plain Ingredients-bar drags).
        local id = GetIdentifier(src)
        local fromTray = d.source == "tray"
        local sig = (type(d.sig) == "string") and d.sig or nil
        local cheese = CheeseVal(d.cheese)
        local have = fromTray and GetTrayCount(rid, id, d.item, cheese, sig) or invVariationCount(src, d.item, cheese, sig)
        if have < 1 then return { ok = false, error = "Missing ingredient." } end
        local function consume()
            if fromTray then RemoveTray(rid, id, d.item, cheese, 1, sig)
            else removeInvVariation(src, d.item, cheese, sig, 1) end
        end

        -- Oven / fryer: seat into a station slot and cook on a gated single timeline
        -- (bakes while the door is closed / fries while the basket is lowered).
        if method == "oven" or method == "fry" then
            local door = (method == "oven") and tonumber(d.door) or nil
            local slot = tonumber(d.slot)
            if not slot or (method == "oven" and door ~= 1 and door ~= 2) then
                return { ok = false, error = "Pick a spot." }
            end
            if not slotFree(prop.id, method, door, slot) then return { ok = false, error = "That spot's taken." } end

            -- An uncooked assembled input (e.g. a topped pizza) carries a build stack;
            -- capture it BEFORE consuming so the station renders the whole stack — not
            -- just the base model — and so collecting it back while still raw returns the
            -- exact stack to the tray. Cleared the moment it cooks (single product prop).
            local stackMeta, stackModels
            if fromTray then
                stackMeta   = TrayTopMeta(rid, id, d.item, cheese, sig)
                stackModels = stackModelsFromMeta(d.item, stackMeta)
            else
                -- an assembled input pulled from the INVENTORY: its exact recorded
                -- stack when the slot metadata is readable, else the base recipe —
                -- so an inventory pepperoni pizza bakes (and collects) as one
                stackMeta = invVariationMeta(src, d.item, cheese, sig)
                if stackMeta or findAssembly(d.item) then
                    stackModels = stackModelsFromMeta(d.item, stackMeta)
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
            return { ok = true }
        end

        consume()
        it.kind, it.recipe = "cook", recipe

        -- oxmysql maps TINYINT(1) to a Lua boolean, so accept true or 1.
        local isDual = recipe.dual_sided == true or tonumber(recipe.dual_sided) == 1

        -- Dual-sided: render two faces, cook only the down one, flip to swap.
        if isDual then
            it.dual    = true
            it.sides   = { "raw", "raw" }
            it.elapsed = { 0, 0 }
            it.flipped = false
            it.down    = 1
            it.cheese  = "none"
            CookingItems[uid] = it
            broadcastDual(it)
            armSideTimer(it)
            return { ok = true }
        end

        it.state, it.model = "raw", recipe.raw_model
        CookingItems[uid] = it
        broadcastSpawn(it)
        SetTimeout(recipe.cook_ms, function()
            local cur = CookingItems[uid]; if not cur or cur.state ~= "raw" then return end
            cur.state, cur.model = "cooked", recipe.cooked_model
            TriggerClientEvent("pickle_restaurants:cooking:update", -1, uid, cur.model, cur.state)
            SetTimeout(recipe.burn_ms, function()
                local c2 = CookingItems[uid]; if not c2 or c2.state ~= "cooked" then return end
                c2.state, c2.model = "burnt", recipe.burnt_model
                TriggerClientEvent("pickle_restaurants:cooking:update", -1, uid, c2.model, c2.state)
            end)
        end)
        return { ok = true }

    elseif station == "soda_machine" and d.kind == "drink" then
        local drink = findDrink(d.item)
        if not drink then return { ok = false, error = "Unknown drink." } end
        if (Inventory.GetItemCount(src, drink.input) or 0) < 1 then return { ok = false, error = "Need a cup." } end
        Inventory.RemoveItem(src, drink.input, 1)
        it.kind, it.drink, it.output, it.state, it.model = "drink", drink, drink.output, "filling", drink.model
        CookingItems[uid] = it
        broadcastSpawn(it)
        SetTimeout(drink.fill_ms or 3000, function()
            local cur = CookingItems[uid]; if not cur or cur.state ~= "filling" then return end
            cur.state = "done"
            TriggerClientEvent("pickle_restaurants:cooking:update", -1, uid, cur.model, cur.state)
        end)
        return { ok = true }

    elseif station == "kitchen_prep" and d.kind == "assembly" then
        local asm = findAssembly(d.item)
        if not asm then return { ok = false, error = "Unknown recipe." } end
        for _, comp in ipairs(asm.components or {}) do
            if (Inventory.GetItemCount(src, comp) or 0) < 1 then return { ok = false, error = "Missing components." } end
        end
        for _, comp in ipairs(asm.components or {}) do Inventory.RemoveItem(src, comp, 1) end
        it.kind, it.output, it.state, it.model = "assembly", asm.output, "done", asm.model
        CookingItems[uid] = it
        broadcastSpawn(it)
        return { ok = true }
    end

    return { ok = false, error = "Invalid action." }
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
    if not prop or prop.prop_type ~= "fryer" then return { ok = false } end
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

-- ─── cheese (dual-sided patties) ─────────────────────────────────────────────

-- Drop a cheese slice on the up (visible) face — only once it's cooked. It melts
-- after a delay.
lib.callback.register("pickle_restaurants:cooking:applyCheese", function(src, d)
    local it = CookingItems[tonumber(d.uid)]
    if not it or not it.dual then return { ok = false } end
    if not HasPerm(it.rid, src, "cook") then return { ok = false } end
    if (it.cheese or "none") ~= "none" then return { ok = false, error = "Already has cheese." } end

    local up = (it.down == 1) and 2 or 1
    if it.sides[up] ~= "cooked" then return { ok = false, error = "Cook this side first." } end
    if (Inventory.GetItemCount(src, "cheese") or 0) < 1 then return { ok = false, error = "No cheese." } end
    Inventory.RemoveItem(src, "cheese", 1)

    it.cheese = "applied"
    broadcastDual(it)
    local uid = it.uid
    SetTimeout(GetSetting("cheese_melt_ms", 8000), function()
        local cur = CookingItems[uid]
        if not cur or cur.cheese ~= "applied" then return end
        cur.cheese = "melted"
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
    TriggerClientEvent("pickle_restaurants:cooking:move", -1, it.uid, it.x, it.y, it.z)
    return { ok = true }
end)

-- Re-slot an oven/fryer item onto another rack mid-cook — the same open-slot snapping
-- as placement. Cook progress carries over (elapsed is banked then resumed) and the gate
-- is recomputed for the new door.
lib.callback.register("pickle_restaurants:cooking:reslot", function(src, d)
    local it = CookingItems[tonumber(d and d.uid)]
    if not it then return { ok = false } end
    if not HasPerm(it.rid, src, "cook") then return { ok = false } end
    if it.method ~= "oven" and it.method ~= "fry" then return { ok = false } end
    local prop = PropCache[it.prop_id]
    if not prop then return { ok = false } end
    local door = (it.method == "oven") and tonumber(d.door) or nil
    local slot = tonumber(d.slot)
    if not slot or (it.method == "oven" and door ~= 1 and door ~= 2) then return { ok = false, error = "Pick a spot." } end
    if it.slot == slot and (it.method ~= "oven" or it.door == door) then return { ok = false } end -- already there
    if not slotFree(it.prop_id, it.method, door, slot) then return { ok = false, error = "That spot's taken." } end
    -- can't fish food out of a lowered basket either — raise it first
    if it.method == "fry" and basketDown(prop, it.slot) then return { ok = false, error = "Raise the basket first." } end

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
        return { ok = false, error = "Open the door first." }
    end
    -- Nor into hot oil — the basket has to be raised to take a fry out.
    if it.method == "fry" and basketDown(PropCache[it.prop_id], it.slot) then
        return { ok = false, error = "Raise the basket first." }
    end

    local giveItem
    if it.kind == "cook" then
        if it.dual then
            giveItem = dualGiveItem(it)
        elseif it.state == "raw" then giveItem = it.recipe.input_item
        elseif it.state == "cooked" then giveItem = it.recipe.output_cooked_item
        else giveItem = it.recipe.output_burnt_item end
    elseif it.kind == "drink" then
        giveItem = (it.state == "done") and it.output or it.drink.input
    elseif it.kind == "assembly" then
        giveItem = it.output
    end

    -- Cooked products go into the per-player "Cooked Items" tray (a state store),
    -- not the inventory — they're carried between stations and built at prep. The
    -- cheese's melt state is preserved (applied = 1, melted = 2) so the tray renders
    -- it the way it was collected.
    local cheese = (it.cheese == "melted") and 2 or (it.cheese == "applied") and 1 or 0
    -- An assembled item taken out of the oven/fryer keeps its exact build stack so
    -- nothing is lost — RAW or COOKED. A cooked pizza must carry its toppings/sauce
    -- forward (to the tray, then the inventory slot) or it comes out a bare base.
    local giveMeta = it.stackMeta
    -- A finished cook yields the recipe's serving size (a basket of fries is a
    -- batch of fries, not one giant fry). Raw items collected back stay 1:1.
    local giveCount = 1
    if it.kind == "cook" and (it.state == "cooked" or it.state == "burnt") then
        giveCount = math.max(1, tonumber(it.recipe.output_count) or 1)
    end
    if giveItem then AddTray(it.rid, GetIdentifier(src), giveItem, cheese, giveCount, giveMeta) end
    CookingItems[it.uid] = nil
    TriggerClientEvent("pickle_restaurants:cooking:remove", -1, it.uid)
    return { ok = true, item = giveItem, cheese = cheese, label = giveItem and GetItemLabel(giveItem) or nil }
end)

-- ─── cooked-items tray ───────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:cooking:getTray", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return {} end
    if not HasPerm(prop.restaurant_id, src, "cook") then return {} end
    local list = GetTray(prop.restaurant_id, GetIdentifier(src))
    -- At the prep table, cooked items placed on a build are spoken for — subtract
    -- the reservations so the tray shows what's still free to grab.
    local build = (prop.prop_type == "kitchen_prep") and PrepBuilds[src] or nil
    local out = {}
    for _, e in ipairs(list) do
        if build then
            e.count = e.count - math.ceil(reservedUnits(build, "tray", e.item, e.cheese, e.sig))
        end
        if e.count > 0 then
            e.model = itemModel(e.item)
            -- a dual patty renders as two faces; its cheese rides the visible face at the
            -- melt state it was collected in — melted (2) = _02, applied (1) = _01 — seated
            -- by placeCheeseAt, identical to the stovetop. (A standalone cheese *component*
            -- is a fresh _01 slice.)
            if dualRecipeForItem(e.item) then e.dual = true end
            if e.cheese and e.cheese >= 1 then
                e.cheeseModel = (e.cheese == 2) and "pickle_cheese_applied_02" or "pickle_cheese_applied_01"
            end
            -- an assembled product (burger etc.) can be dropped on the prep table to
            -- be taken back apart into its component stack
            if prop.prop_type == "kitchen_prep" and findAssembly(e.item) then e.decompose = true end
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
                -- shows the full pizza, not a bare dough base.
                local rout, state = recipeForOutput(e.item)
                if rout and e.meta then
                    local models = stackModelsFromMeta(e.item, e.meta)
                    if models then
                        for i, m in ipairs(models) do
                            if m == rout.raw_model then
                                models[i] = (state == "burnt") and rout.burnt_model or rout.cooked_model
                                break
                            end
                        end
                        e.stack, e.stackState = models, state
                    end
                end
            end
            -- how this variation differs from the base recipe (its toppings), plus
            -- the full component list for the hover tooltip
            if e.meta then
                e.extras = extrasComponents(e.item, e.meta)
                e.comps  = stackComponents(e.meta)
            end
            e.meta = nil -- the NUI keys variations by sig; no need to ship the raw stack
            out[#out + 1] = e
        end
    end

    -- Inventory-held PRODUCTS join the tabs too, marked source "inv" ("Item" pill in
    -- the NUI): cook outputs and assembled products file under "Cooked Items",
    -- assembled-but-raw cook inputs (an uncooked pizza item) under "Uncooked Items".
    -- The Ingredients bar keeps only true raw components — a cooked patty in your
    -- inventory is not an "ingredient". Where the bridge exposes slot metadata,
    -- each build variation is its own entry (exact stack, toppings, cheese state);
    -- otherwise everything groups under the base-recipe look.
    local function addInvEntries(item)
        if not ItemExists(item) then return end
        for _, v in ipairs(invVariations(src, item)) do
            local count = v.count
            if build then count = count - math.ceil(reservedUnits(build, "inv", item, v.cheese, v.sig)) end
            if count > 0 then
                local entry = { item = item, cheese = v.cheese, count = count, source = "inv", sig = v.sig,
                                label = GetItemLabel(item), image = GetItemImage(item), model = itemModel(item) }
                if dualRecipeForItem(item) then entry.dual = true end
                if v.cheese >= 1 then
                    entry.cheeseModel = (v.cheese == 2) and "pickle_cheese_applied_02" or "pickle_cheese_applied_01"
                end
                local rin = RecipeByInput[item]
                if rin then
                    entry.uncooked = true; entry.cookStation = rin.station
                    entry.stack = stackModelsFromMeta(item, v.meta) -- exact stack, or base recipe
                else
                    -- a cooked/burnt product renders its recorded stack (else the
                    -- base recipe), crust swapped to its cooked/burnt model
                    local rout, state = recipeForOutput(item)
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
                            entry.stack, entry.stackState = models, state
                        end
                    end
                end
                if v.meta then
                    entry.extras = extrasComponents(item, v.meta)
                    entry.comps  = stackComponents(v.meta)
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
    for _, a in ipairs(GetSetting("assembly", {})) do once(a.output) end

    return out
end)

-- Inventory-slot metadata for a cooked item leaving the tray: its exact build stack
-- (so the variation survives) + a readable description, and the cheese state. Returns
-- nil for a plain item with nothing to preserve (keeps stacks clean). Frameworks
-- without slot metadata (ESX) ignore whatever we pass.
local function buildInvMeta(cheese, meta)
    if type(meta) == "table" and #meta > 0 then
        return { stack = meta, cheese = cheese, description = stackDescription(meta) }
    end
    if cheese and cheese >= 1 then return { cheese = cheese } end
    return nil
end

-- cash a tray item out into the real inventory (so it can be stocked/sold)
lib.callback.register("pickle_restaurants:cooking:trayToInventory", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    local id = GetIdentifier(src)
    local item   = d.item
    local cheese = CheeseVal(d.cheese)
    local sig    = (type(d.sig) == "string") and d.sig or nil
    local count  = tonumber(d.count) or 1
    if not item or GetTrayCount(rid, id, item, cheese, sig) < count then return { ok = false, error = "Not enough." } end
    -- Move one instance at a time so each keeps its OWN build variation on the
    -- inventory slot (ox/qb slot metadata). TrayTopMeta must be read before the
    -- matching RemoveTray, which pops that instance's stack (LIFO).
    for _ = 1, count do
        local meta = TrayTopMeta(rid, id, item, cheese, sig)
        if not RemoveTray(rid, id, item, cheese, 1, sig) then break end
        Inventory.AddItem(src, item, 1, buildInvMeta(cheese, meta))
    end
    return { ok = true, item = item, count = count, label = GetItemLabel(item) }
end)

-- ─── interactive prep build (kitchen_prep) ───────────────────────────────────

-- A bun is one inventory item rendered as two stackable halves (top/bottom), so
-- each half only counts as half a bun — one or two halves = one bun.
function layerUnits(l)
    if l.item == "bun" and l.half then return 0.5 end
    return 1.0
end

-- The multiset of items a build provides (a cheesed patty also provides "cheese";
-- bun halves round up so a lone bottom bun still satisfies a "1 bun" recipe).
local function buildProvides(layers)
    local units = {}
    for _, l in ipairs(layers) do
        units[l.item] = (units[l.item] or 0) + layerUnits(l)
        -- any cheese state (applied or melted) counts as one "cheese" component
        if l.cheese and l.cheese >= 1 then units.cheese = (units.cheese or 0) + 1 end
    end
    local p = {}
    for k, v in pairs(units) do p[k] = math.ceil(v) end
    return p
end

-- Units of (source,item,cheese[,sig]) this build already reserved — layers only
-- reserve; nothing is pulled from the tray/inventory until Make, so this guards
-- against reserving more than the player actually holds. `sig` (tray layers only)
-- narrows the match to one build variation; nil matches any.
function reservedUnits(b, source, item, cheese, sig)
    local n = 0
    for _, l in ipairs(b.layers) do
        if l.source == source and l.item == item and (l.cheese or 0) == (cheese or 0)
            and (sig == nil or (l.sig or "") == sig) then
            n = n + layerUnits(l)
        end
    end
    return n
end

lib.callback.register("pickle_restaurants:cooking:prepAdd", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop or prop.prop_type ~= "kitchen_prep" then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    local item = d.item
    if not item then return { ok = false } end
    -- preserve the melt state (1/2) so a tray reservation matches the exact entry
    local cheese = CheeseVal(d.cheese)
    local half = (item == "bun" and (d.half == "top" or d.half == "bottom")) and d.half or nil
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
        local needed = math.ceil(reservedUnits(b, "tray", item, cheese, sig) + addUnits)
        if GetTrayCount(rid, GetIdentifier(src), item, cheese, sig) < needed then
            return { ok = false, error = "Not enough in tray." }
        end
    elseif sig then
        -- an inventory-held PRODUCT reserves its exact variation (cheese + sig)
        local needed = math.ceil(reservedUnits(b, "inv", item, cheese, sig) + addUnits)
        if invVariationCount(src, item, cheese, sig) < needed then
            return { ok = false, error = "Missing item." }
        end
    else
        cheese = 0
        local needed = math.ceil(reservedUnits(b, "inv", item, 0) + addUnits)
        if (Inventory.GetItemCount(src, item) or 0) < needed then
            return { ok = false, error = "Missing item." }
        end
    end

    b.seq = (b.seq or 0) + 1
    b.layers[#b.layers + 1] = { id = b.seq, source = d.source, item = item, cheese = cheese, half = half, sig = sig }
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
    if not prop or prop.prop_type ~= "kitchen_prep" then return {} end
    if not HasPerm(prop.restaurant_id, src, "cook") then return {} end
    local out = {}
    for _, asm in ipairs(GetSetting("assembly", {})) do
        local valid = ItemExists(asm.output)
        local comps = {}
        for _, c in ipairs(asm.components or {}) do
            if not ItemExists(c) then valid = false end
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
local function bestAssemblyForLayers(layers)
    if #layers == 0 then return nil end
    local provides = buildProvides(layers)
    local best, bestScore
    for _, asm in ipairs(GetSetting("assembly", {})) do
        if stackSatisfies(provides, asm) then
            local score = #(asm.components or {})
            if not bestScore or score > bestScore then best, bestScore = asm, score end
        end
    end
    return best
end

-- Consume a stack's reserved layers and produce `asm`'s output into the tray, tagged
-- with the EXACT ordered build stack (order/cheese/bun-half) so it stays that exact
-- variation — takeable apart later, and preserved through to delivery. The whole pile
-- is consumed, extras included. Assumes the superset match is already verified.
local function makeStack(src, b, id, ids, asm)
    local layers = orderedLayers(b, ids)
    if #layers == 0 then return { ok = false, error = "Nothing to build." } end

    -- A layer that is itself a built product (a cooked pizza going into a burger)
    -- keeps its OWN build stack: capture it off the exact instance being consumed —
    -- BEFORE removal below — so the nested variation survives inside the output's
    -- meta and comes back out intact when the product is taken apart.
    for _, l in ipairs(layers) do
        if l.sig and l.sig ~= "" then
            l.stack = (l.source == "tray")
                and TrayTopMeta(b.rid, id, l.item, l.cheese or 0, l.sig)
                or invVariationMeta(src, l.item, l.cheese or 0, l.sig)
        end
    end

    -- Tally consumption per source (bun halves round up to whole buns), verify,
    -- remove. Layers consume the exact build variation they reserved (sig) —
    -- from the tray, or from the matching inventory slot for "inv" products.
    local trayUnits, invUnits = {}, {}
    for _, l in ipairs(layers) do
        local k = l.item .. "|" .. (l.cheese or 0) .. "|" .. (l.sig or "")
        local units = (l.source == "tray") and trayUnits or invUnits
        units[k] = units[k] or { item = l.item, cheese = l.cheese or 0, sig = l.sig, u = 0 }
        units[k].u = units[k].u + layerUnits(l)
    end
    local needTray, needInv = {}, {}
    for k, t in pairs(trayUnits) do needTray[k] = { item = t.item, cheese = t.cheese, sig = t.sig, n = math.ceil(t.u) } end
    for k, t in pairs(invUnits) do needInv[k] = { item = t.item, cheese = t.cheese, sig = t.sig, n = math.ceil(t.u) } end

    for _, t in pairs(needTray) do
        if GetTrayCount(b.rid, id, t.item, t.cheese, t.sig) < t.n then
            return { ok = false, error = "Cooked items changed — rebuild." }
        end
    end
    for _, t in pairs(needInv) do
        if invVariationCount(src, t.item, t.cheese, t.sig) < t.n then
            return { ok = false, error = "Missing components." }
        end
    end
    for _, t in pairs(needTray) do RemoveTray(b.rid, id, t.item, t.cheese, t.n, t.sig) end
    for _, t in pairs(needInv) do removeInvVariation(src, t.item, t.cheese, t.sig, t.n) end

    -- Drop just this stack's reservations; other stacks keep building.
    local wanted = {}
    for _, l in ipairs(layers) do wanted[l.id] = true end
    local keep = {}
    for _, l in ipairs(b.layers) do if not (l.id and wanted[l.id]) then keep[#keep + 1] = l end end
    b.layers = keep
    if #b.layers == 0 then PrepBuilds[src] = nil end

    -- The exact ordered stack (bottom-to-top), each layer's cheese + bun-half kept,
    -- plus any nested build stack a product layer carried in.
    local stackMeta = {}
    for _, l in ipairs(layers) do
        stackMeta[#stackMeta + 1] = { item = l.item, cheese = l.cheese or 0, half = l.half, stack = l.stack }
    end
    AddTray(b.rid, id, asm.output, 0, 1, stackMeta)
    return { ok = true, output = asm.output, label = asm.label or asm.output }
end

-- Build ONE stack into a chosen recipe (the tooltip's Make). The client sends the
-- output plus the stack's reservation ids (bottom-to-top). Alterations are allowed:
-- the stack only needs to CONTAIN the recipe's required components.
lib.callback.register("pickle_restaurants:cooking:prepMakeStack", function(src, d)
    local b = PrepBuilds[src]; if not b then return { ok = false } end
    if not HasPerm(b.rid, src, "cook") then return { ok = false } end
    local asm = findAssembly(d and d.output)
    if not asm then return { ok = false, error = "Unknown recipe." } end
    local layers = orderedLayers(b, d.ids)
    if #layers == 0 then return { ok = false, error = "Nothing to build." } end
    if not stackSatisfies(buildProvides(layers), asm) then return { ok = false, error = "Missing components." } end
    return makeStack(src, b, GetIdentifier(src), d.ids, asm)
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
    local asm = bestAssemblyForLayers(layers)
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
    if not prop or prop.prop_type ~= "kitchen_prep" then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    local asm = findAssembly(d and d.item)
    if not asm then return { ok = false, error = "Can't take that apart." } end
    local id = GetIdentifier(src)
    local sig = (type(d.sig) == "string") and d.sig or nil

    -- assembly outputs are stored in the tray at cheese 0
    if GetTrayCount(rid, id, asm.output, 0, sig) < 1 then return { ok = false, error = "None to take apart." } end
    -- The exact stack this was built from (order/cheese/bun-half intact), else recipe.
    local meta = TrayTopMeta(rid, id, asm.output, 0, sig)
    RemoveTray(rid, id, asm.output, 0, 1, sig)
    local comps = compsFromMeta(asm, meta)

    local b = PrepBuilds[src]
    if b and b.prop_id ~= prop.id then b = nil end
    if not b then b = { prop_id = prop.id, rid = rid, seq = 0, layers = {} }; PrepBuilds[src] = b end

    -- Refund the item back into holdings, aggregated per (item,cheese) so a bun's two
    -- halves round up to one whole bun; the layers below stay separate for the stack.
    -- A nested product refunds ONE AT A TIME with its own build stack as the instance
    -- meta, so the pizza that came out of a burger is still that exact pizza.
    local refund = {}
    for _, c in ipairs(comps) do
        if c.stack and isTrayItem(c.item) then
            AddTray(rid, id, c.item, c.cheese, 1, c.stack)
        else
            local u = (c.item == "bun" and c.half) and 0.5 or 1.0
            local key = c.item .. "|" .. c.cheese
            refund[key] = refund[key] or { item = c.item, cheese = c.cheese, tray = isTrayItem(c.item), units = 0 }
            refund[key].units = refund[key].units + u
        end
    end
    for _, r in pairs(refund) do
        local n = math.ceil(r.units)
        if r.tray then AddTray(rid, id, r.item, r.cheese, n) else Inventory.AddItem(src, r.item, n) end
    end

    -- Recreate one reserved part per layer, IN ORDER (no sorting), so the rebuilt
    -- stack is identical to what was taken apart — positions and duplicates and all.
    -- A nested product's layer reserves its exact variation (sig of its stack).
    local parts = {}
    for _, c in ipairs(comps) do
        b.seq = (b.seq or 0) + 1
        b.layers[#b.layers + 1] = { id = b.seq, source = isTrayItem(c.item) and "tray" or "inv", item = c.item, cheese = c.cheese, half = c.half,
                                    sig = (c.stack and isTrayItem(c.item)) and TraySig(c.stack) or nil, stack = c.stack }
        local spec = compSpec(c); spec.id = b.seq
        parts[#parts + 1] = spec
    end
    return { ok = true, parts = parts }
end)

-- Read-only preview: the component parts a product WOULD decompose into, without
-- consuming or reserving anything. Drives the full-stack drag preview so the whole
-- stack follows the cursor (not just the product's single prop).
lib.callback.register("pickle_restaurants:cooking:prepDecomposePeek", function(src, d)
    local prop = PropCache[tonumber(d and d.prop_id)]
    if not prop or prop.prop_type ~= "kitchen_prep" then return { ok = false } end
    if not HasPerm(prop.restaurant_id, src, "cook") then return { ok = false } end
    local asm = findAssembly(d and d.item)
    if not asm then return { ok = false } end
    local id = GetIdentifier(src)
    local sig = (type(d.sig) == "string") and d.sig or nil
    if GetTrayCount(prop.restaurant_id, id, asm.output, 0, sig) < 1 then return { ok = false } end
    local comps = compsFromMeta(asm, TrayTopMeta(prop.restaurant_id, id, asm.output, 0, sig))
    local parts = {}
    for _, c in ipairs(comps) do parts[#parts + 1] = compSpec(c) end
    return { ok = true, parts = parts }
end)

-- closing the station / dropping just discards the reservation (nothing consumed)
RegisterNetEvent("pickle_restaurants:cooking:prepClose", function() PrepBuilds[source] = nil end)
AddEventHandler("playerDropped", function() PrepBuilds[source] = nil end)

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
    for uid, it in pairs(CookingItems) do
        if it.prop_id == propId then
            CookingItems[uid] = nil
            TriggerClientEvent("pickle_restaurants:cooking:remove", -1, uid)
        end
    end
end)
