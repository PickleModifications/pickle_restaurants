-- =============================================
--  modules/cooking | server.lua
--  Authoritative state for food being cooked on stations. Clients render the
--  3D props; the server owns placement, the raw->cooked->burnt timeline, and
--  hand-back into the player's inventory.
-- =============================================

local CookingItems = {} -- [uid] = { uid, rid, prop_id, station, kind, recipe, drink, output, state, model, x, y, z }
local cookUid = 0

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

-- ─── ingredient list for the bottom bar ──────────────────────────────────────

lib.callback.register("pickle_restaurants:cooking:getIngredients", function(src, d)
    local prop = PropCache[tonumber(d.prop_id)]
    if not prop then return {} end
    local station = prop.prop_type
    local out = {}

    if station == "fryer" or station == "stovetop" then
        for _, recipe in ipairs(RecipeCache) do
            if recipe.station == station then
                local count = Inventory.GetItemCount(src, recipe.input_item)
                if count and count > 0 then
                    out[#out + 1] = { kind = "cook", item = recipe.input_item, label = GetItemLabel(recipe.input_item), count = count }
                end
            end
        end
    elseif station == "soda_machine" then
        for _, drink in ipairs(GetSetting("drinks", {})) do
            local count = Inventory.GetItemCount(src, drink.input) or 0
            out[#out + 1] = { kind = "drink", item = drink.input, label = drink.label or GetItemLabel(drink.input), count = count }
        end
    elseif station == "kitchen_prep" then
        for _, asm in ipairs(GetSetting("assembly", {})) do
            local canMake = true
            for _, comp in ipairs(asm.components or {}) do
                if (Inventory.GetItemCount(src, comp) or 0) < 1 then canMake = false break end
            end
            out[#out + 1] = { kind = "assembly", item = asm.output, label = asm.label or asm.output, canMake = canMake,
                              components = asm.components }
        end
    end
    return out
end)

-- send all in-progress items to a (re)connecting / station-opening client
lib.callback.register("pickle_restaurants:cooking:getActive", function(_, _)
    local list = {}
    for _, it in pairs(CookingItems) do
        list[#list + 1] = { uid = it.uid, model = it.model, x = it.x, y = it.y, z = it.z, state = it.state }
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
        it.kind, it.recipe, it.state, it.model = "cook", recipe, "raw", recipe.raw_model
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
        if it.state == "raw" then giveItem = it.recipe.input_item
        elseif it.state == "cooked" then giveItem = it.recipe.output_cooked_item
        else giveItem = it.recipe.output_burnt_item end
    elseif it.kind == "drink" then
        giveItem = (it.state == "done") and it.output or it.drink.input
    elseif it.kind == "assembly" then
        giveItem = it.output
    end

    if giveItem then Inventory.AddItem(src, giveItem, 1) end
    CookingItems[it.uid] = nil
    TriggerClientEvent("pickle_restaurants:cooking:remove", -1, it.uid)
    return { ok = true, item = giveItem, label = giveItem and GetItemLabel(giveItem) or nil }
end)

-- send active items to clients that (re)sync
RegisterNetEvent("pickle_restaurants:requestSync", function()
    local list = {}
    for _, it in pairs(CookingItems) do
        list[#list + 1] = { uid = it.uid, model = it.model, x = it.x, y = it.y, z = it.z, state = it.state }
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
