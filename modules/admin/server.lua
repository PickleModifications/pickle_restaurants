-- =============================================
--  modules/admin | server.lua
--  Admin command + callbacks: create/delete restaurants, assign owner,
--  edit global settings & cookable recipes. All gated by IsPlayerAdmin.
-- =============================================

local function buildAdminData()
    local data = {
        restaurants = {},
        settings    = SettingsCache,
        recipes     = AnnotateRecipes(),   -- each row flagged valid/missing
        drinks      = AnnotateDrinks(),
        assembly    = AnnotateAssembly(),
        items       = BuildItemList(),     -- catalogue for item-pickers
        players     = {},
    }
    for _, r in pairs(RestaurantCache) do
        local props = {}
        for _, p in pairs(PropCache) do
            if p.restaurant_id == r.id then
                props[#props + 1] = { id = p.id, prop_type = p.prop_type, model = p.model }
            end
        end
        data.restaurants[#data.restaurants + 1] = {
            id         = r.id,
            name       = r.name,
            label      = r.label,
            owner      = r.owner_identifier,
            balance    = r.balance,
            hasCounter = r.counter ~= nil,
            props      = props,
            propCount  = #props,
        }
    end
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        data.players[#data.players + 1] = { id = src, name = GetPlayerCharacterName(src) }
    end
    return data
end

local function openAdmin(src)
    if not IsPlayerAdmin(src) then
        return ShowNotification(src, _L("no_permission"))
    end
    TriggerClientEvent("pickle_restaurants:openAdmin", src, buildAdminData())
end

lib.callback.register("pickle_restaurants:admin:getData", function(src)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local d = buildAdminData()
    d.ok = true
    return d
end)

CreateThread(function()
    while not RestaurantsReady do Wait(200) end
    RegisterCommand(GetSetting("admin_command", "restaurants"), function(src)
        if src == 0 then return print("This command must be run in-game.") end
        openAdmin(src)
    end, false)
end)

-- ─── create / delete ─────────────────────────────────────────────────────────

local function reloadRestaurant(id)
    local row = MySQL.single.await("SELECT * FROM pickle_restaurants WHERE id = ?", { id })
    if not row then RestaurantCache[id] = nil return end
    row.blip     = (type(row.blip) == "string") and json.decode(row.blip) or row.blip
    row.counter  = (type(row.counter) == "string") and json.decode(row.counter) or row.counter
    row.roles    = (type(row.roles) == "string") and json.decode(row.roles) or row.roles
    row.metadata = (type(row.metadata) == "string") and json.decode(row.metadata) or (row.metadata or {})
    RestaurantCache[id] = row
end

lib.callback.register("pickle_restaurants:admin:create", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not d or not d.name or d.name == "" then return { ok = false, error = "Name required" } end
    local id = MySQL.insert.await(
        "INSERT INTO pickle_restaurants (name, label, blip, balance) VALUES (?, ?, ?, ?)",
        { d.name, d.label or d.name, json.encode(GetSetting("blip", {})), GetSetting("starting_balance", 0) })
    if not id then return { ok = false } end
    reloadRestaurant(id)
    SyncToClient(-1)
    return { ok = true, id = id }
end)

lib.callback.register("pickle_restaurants:admin:delete", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local id = tonumber(d.id); if not id then return { ok = false } end
    -- collect props so clients can despawn them
    local propIds = {}
    for pid, p in pairs(PropCache) do if p.restaurant_id == id then propIds[#propIds + 1] = pid end end
    MySQL.update.await("DELETE FROM pickle_restaurants WHERE id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_props WHERE restaurant_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_employees WHERE restaurant_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_menu WHERE restaurant_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_stock WHERE restaurant_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_ledger WHERE restaurant_id = ?", { id })
    RestaurantCache[id] = nil
    EmployeeCache[id] = nil
    StockCache[id] = nil
    for _, pid in ipairs(propIds) do PropCache[pid] = nil; TriggerClientEvent("pickle_restaurants:propRemoved", -1, pid) end
    SyncToClient(-1)
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:admin:setOwner", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local id = tonumber(d.id); if not GetRestaurant(id) then return { ok = false } end
    local identifier = nil
    if d.target then
        identifier = GetIdentifier(tonumber(d.target))
        if not identifier then return { ok = false, error = "Player not found" } end
    end
    MySQL.update.await("UPDATE pickle_restaurants SET owner_identifier = ? WHERE id = ?", { identifier, id })
    RestaurantCache[id].owner_identifier = identifier
    return { ok = true, owner = identifier }
end)

-- ─── settings ────────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:admin:saveSetting", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not d.key then return { ok = false } end
    SetSetting(d.key, d.value)
    SyncToClient(-1) -- drinks/assembly/blip may have changed
    return { ok = true }
end)

-- ─── recipes ─────────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:admin:saveRecipe", function(src, r)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not r.input_item or r.input_item == "" then return { ok = false, error = "input_item required" } end
    MySQL.update.await([[
        INSERT INTO pickle_restaurant_recipes
            (input_item, station, raw_model, cooked_model, burnt_model, output_cooked_item, output_burnt_item, cook_ms, burn_ms, dual_sided)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            station = VALUES(station), raw_model = VALUES(raw_model), cooked_model = VALUES(cooked_model),
            burnt_model = VALUES(burnt_model), output_cooked_item = VALUES(output_cooked_item),
            output_burnt_item = VALUES(output_burnt_item), cook_ms = VALUES(cook_ms), burn_ms = VALUES(burn_ms),
            dual_sided = VALUES(dual_sided)
    ]], {
        r.input_item, r.station or "fryer", r.raw_model or "", r.cooked_model or "", r.burnt_model or "",
        r.output_cooked_item or "", r.output_burnt_item or "",
        tonumber(r.cook_ms) or 15000, tonumber(r.burn_ms) or 15000,
        (r.dual_sided == true or r.dual_sided == 1) and 1 or 0,
    })
    LoadRecipes()
    SyncToClient(-1)
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:admin:deleteRecipe", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    MySQL.update.await("DELETE FROM pickle_restaurant_recipes WHERE input_item = ?", { d.input_item })
    LoadRecipes()
    SyncToClient(-1)
    return { ok = true }
end)
