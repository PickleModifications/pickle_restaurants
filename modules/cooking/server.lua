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

-- one sync entry for a (re)connecting / station-opening client
local function activeEntry(it)
    if it.dual then return dualPayload(it) end
    return { uid = it.uid, model = it.model, x = it.x, y = it.y, z = it.z, state = it.state }
end

-- A world model for an item: cook recipe outputs/inputs, assembly outputs, drink
-- outputs, else the configurable `prep_models` map (raw veg, toppings, doughs — any
-- item an admin maps to a prop). nil = no prop, and the item falls back to a flat
-- 2D chip. Used so the prep station can spawn a live 3D prop to drag out and stack.
function itemModel(item)
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
    return GetSetting("prep_models", {})[item]
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

-- ─── ingredient list for the bottom bar ──────────────────────────────────────

lib.callback.register("pickle_restaurants:cooking:getIngredients", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return {} end
    local station = prop.prop_type
    local out = {}

    if station == "fryer" or station == "stovetop" then
        for _, recipe in ipairs(RecipeCache) do
            -- Recipes that reference a missing item are hidden until fixed.
            if recipe.station == station and IsRecipeValid(recipe) then
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
        -- Interactive build: the bar lists the raw components (held in inventory)
        -- used across assembly recipes; cooked components come from the tray.
        local build = PrepBuilds[src]
        local seen = {}
        for _, asm in ipairs(GetSetting("assembly", {})) do
            for _, comp in ipairs(asm.components or {}) do
                if not seen[comp] and ItemExists(comp) then
                    seen[comp] = true
                    local count = Inventory.GetItemCount(src, comp) or 0
                    if count > 0 then
                        -- Placed-but-not-yet-built parts are "spoken for": show what's
                        -- left after this build's reservations so the player sees their
                        -- remaining stock (inv layers always reserve at cheese 0).
                        local reserved = build and math.ceil(reservedUnits(build, "inv", comp, 0)) or 0
                        local entry = { kind = "component", item = comp, label = GetItemLabel(comp),
                                        image = GetItemImage(comp), count = math.max(0, count - reserved),
                                        model = itemModel(comp) }
                        -- a beef/dual patty renders as the full two-faced patty, same
                        -- as one pulled from the tray (raw components carry no cheese)
                        if dualRecipeForItem(comp) then entry.dual = true end
                        out[#out + 1] = entry
                    end
                end
            end
        end
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
    local it = { uid = uid, rid = rid, prop_id = prop.id, station = station,
                 x = d.x + 0.0, y = d.y + 0.0, z = d.z + 0.0 }

    if (station == "fryer" or station == "stovetop") and d.kind == "cook" then
        local recipe = RecipeByInput[d.item]
        if not recipe or recipe.station ~= station then return { ok = false, error = "Can't cook that here." } end
        if (Inventory.GetItemCount(src, d.item) or 0) < 1 then return { ok = false, error = "Missing ingredient." } end
        Inventory.RemoveItem(src, d.item, 1)
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

-- ─── collect (drag back to the bar / inventory) ──────────────────────────────

lib.callback.register("pickle_restaurants:cooking:collect", function(src, d)
    local it = CookingItems[tonumber(d.uid)]
    if not it then return { ok = false } end
    if not HasPerm(it.rid, src, "cook") then return { ok = false } end

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
    if giveItem then AddTray(it.rid, GetIdentifier(src), giveItem, cheese, 1) end
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
            e.count = e.count - math.ceil(reservedUnits(build, "tray", e.item, e.cheese))
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
            out[#out + 1] = e
        end
    end
    return out
end)

-- cash a tray item out into the real inventory (so it can be stocked/sold)
lib.callback.register("pickle_restaurants:cooking:trayToInventory", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return { ok = false } end
    local rid = prop.restaurant_id
    if not HasPerm(rid, src, "cook") then return { ok = false } end
    local id = GetIdentifier(src)
    local item   = d.item
    local cheese = CheeseVal(d.cheese)
    local count  = tonumber(d.count) or 1
    if not item or not RemoveTray(rid, id, item, cheese, count) then return { ok = false, error = "Not enough." } end
    Inventory.AddItem(src, item, count)
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

-- Units of (source,item,cheese) this build already reserved — layers only
-- reserve; nothing is pulled from the tray/inventory until Make, so this guards
-- against reserving more than the player actually holds.
function reservedUnits(b, source, item, cheese)
    local n = 0
    for _, l in ipairs(b.layers) do
        if l.source == source and l.item == item and (l.cheese or 0) == (cheese or 0) then n = n + layerUnits(l) end
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

    -- starting/continuing a build at this prop; a build at another prop is dropped
    -- (nothing was consumed, so there's nothing to return).
    local b = PrepBuilds[src]
    if b and b.prop_id ~= prop.id then b = nil end
    if not b then b = { prop_id = prop.id, rid = rid, seq = 0, layers = {} }; PrepBuilds[src] = b end

    -- Reserve only — DON'T remove from the tray/inventory yet (that happens on
    -- Make). Validate against what's left after this build's existing reservations.
    local addUnits = (half and 0.5) or 1.0
    if d.source == "tray" then
        local needed = math.ceil(reservedUnits(b, "tray", item, cheese) + addUnits)
        if GetTrayCount(rid, GetIdentifier(src), item, cheese) < needed then
            return { ok = false, error = "Not enough in tray." }
        end
    else
        cheese = 0
        local needed = math.ceil(reservedUnits(b, "inv", item, 0) + addUnits)
        if (Inventory.GetItemCount(src, item) or 0) < needed then
            return { ok = false, error = "Missing item." }
        end
    end

    b.seq = (b.seq or 0) + 1
    b.layers[#b.layers + 1] = { id = b.seq, source = d.source, item = item, cheese = cheese, half = half }
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

-- Build ONE stack into its recipe. The client sends the chosen output plus the
-- reservation ids that make up that single stack; the server owns consumption.
-- Alterations are allowed: the stack only needs to CONTAIN the recipe's required
-- components (a burger with a donut on it still builds a burger). Because the pile
-- IS the product, the whole stack is consumed — extras included.
lib.callback.register("pickle_restaurants:cooking:prepMakeStack", function(src, d)
    local b = PrepBuilds[src]; if not b then return { ok = false } end
    if not HasPerm(b.rid, src, "cook") then return { ok = false } end
    local asm = findAssembly(d and d.output)
    if not asm then return { ok = false, error = "Unknown recipe." } end
    local id = GetIdentifier(src)

    -- The layers belonging to this stack (by reservation id).
    local wanted = {}
    for _, v in ipairs(d.ids or {}) do wanted[tonumber(v)] = true end
    local layers = {}
    for _, l in ipairs(b.layers) do if l.id and wanted[l.id] then layers[#layers + 1] = l end end
    if #layers == 0 then return { ok = false, error = "Nothing to build." } end

    -- Superset check: every required component must be present on the stack
    -- (extras are fine — that's the alteration). Cheese on a patty counts as cheese.
    local provides = buildProvides(layers)
    local need = {}
    for _, c in ipairs(asm.components or {}) do need[c] = (need[c] or 0) + 1 end
    for k, v in pairs(need) do
        if (provides[k] or 0) < v then return { ok = false, error = "Missing components." } end
    end

    -- Consume the whole stack — tally per source (bun halves round up to whole
    -- buns), verify everything is still present, then remove it all at once.
    local trayUnits, invUnits = {}, {}
    for _, l in ipairs(layers) do
        if l.source == "tray" then
            local k = l.item .. "|" .. (l.cheese or 0)
            trayUnits[k] = trayUnits[k] or { item = l.item, cheese = l.cheese or 0, u = 0 }
            trayUnits[k].u = trayUnits[k].u + layerUnits(l)
        else
            invUnits[l.item] = (invUnits[l.item] or 0) + layerUnits(l)
        end
    end
    local needTray, needInv = {}, {}
    for k, t in pairs(trayUnits) do needTray[k] = { item = t.item, cheese = t.cheese, n = math.ceil(t.u) } end
    for item, u in pairs(invUnits) do needInv[item] = math.ceil(u) end

    for _, t in pairs(needTray) do
        if GetTrayCount(b.rid, id, t.item, t.cheese) < t.n then
            return { ok = false, error = "Cooked items changed — rebuild." }
        end
    end
    for item, n in pairs(needInv) do
        if (Inventory.GetItemCount(src, item) or 0) < n then
            return { ok = false, error = "Missing components." }
        end
    end
    for _, t in pairs(needTray) do RemoveTray(b.rid, id, t.item, t.cheese, t.n) end
    for item, n in pairs(needInv) do Inventory.RemoveItem(src, item, n) end

    -- Drop just this stack's reservations; other stacks keep building.
    local keep = {}
    for _, l in ipairs(b.layers) do if not (l.id and wanted[l.id]) then keep[#keep + 1] = l end end
    b.layers = keep
    if #b.layers == 0 then PrepBuilds[src] = nil end

    AddTray(b.rid, id, asm.output, 0, 1)
    return { ok = true, output = asm.output, label = asm.label or asm.output }
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
