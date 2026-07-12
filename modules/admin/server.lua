-- =============================================
--  modules/admin | server.lua
--  Admin command + callbacks: create/delete restaurants, assign owner,
--  edit global settings & cookable recipes. All gated by IsPlayerAdmin.
-- =============================================

local function buildAdminData()
    local data = {
        restaurants = {},
        theme       = GetSetting("app_theme", nil), -- App-level: skins /restaurants itself
        settings    = SettingsCache,
        recipes     = AnnotateRecipes(),   -- each row flagged valid/missing
        drinks      = AnnotateDrinks(),
        assembly    = AnnotateAssembly(),
        finishes    = AnnotateFinishes(),  -- finish tools (frosting…), flagged too
        items       = BuildItemList(),     -- catalogue for item-pickers
        groups      = CollectGroups(),     -- every group name in use (UI suggestions)
        players     = {},
    }
    for _, r in pairs(RestaurantCache) do
        local props = {}
        for _, p in pairs(PropCache) do
            if p.restaurant_id == r.id then props[#props + 1] = PropSummary(p) end
        end
        data.restaurants[#data.restaurants + 1] = {
            id           = r.id,
            name         = r.name,
            label        = r.label,
            owner        = r.owner_identifier,
            balance      = r.balance,
            hasCounter   = r.counter ~= nil,
            hasShell     = (r.metadata and r.metadata.shell) ~= nil,
            hasNpcSpawn  = (r.metadata and r.metadata.npc_spawn) ~= nil,
            groups       = r.groups or {},
            props        = props,
            propCount    = #props,
            brand_image  = r.metadata and r.metadata.brand_image or nil,
            brand_images = r.metadata and r.metadata.brand_images or nil,
            theme        = r.metadata and r.metadata.theme or nil,
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
    row.groups   = (type(row.groups) == "string") and json.decode(row.groups) or row.groups
    row.metadata = (type(row.metadata) == "string") and json.decode(row.metadata) or (row.metadata or {})
    RestaurantCache[id] = row
end

lib.callback.register("pickle_restaurants:admin:create", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not d or not d.name or d.name == "" then return { ok = false, error = _L("admin_name_required") } end
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
    MySQL.update.await("DELETE FROM pickle_restaurant_orders WHERE restaurant_id = ?", { id })
    RestaurantCache[id] = nil
    EmployeeCache[id] = nil
    StockCache[id] = nil
    ClearOrders(id) -- drops OrderCache/NextTicket + bumps the rev so a stale register can't re-apply
    for _, pid in ipairs(propIds) do
        PropCache[pid] = nil
        TriggerClientEvent("pickle_restaurants:propRemoved", -1, pid)
        -- release state other modules key on this prop (cooking items, seat
        -- occupancy, station claims) — same notice removeProp gives
        TriggerEvent("pickle_restaurants:propDeleted", pid)
    end
    SyncToClient(-1)
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:admin:setOwner", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local id = tonumber(d.id); if not GetRestaurant(id) then return { ok = false } end
    local identifier = nil
    if d.target then
        identifier = GetIdentifier(tonumber(d.target))
        if not identifier then return { ok = false, error = _L("admin_player_not_found") } end
    end
    MySQL.update.await("UPDATE pickle_restaurants SET owner_identifier = ? WHERE id = ?", { identifier, id })
    RestaurantCache[id].owner_identifier = identifier
    return { ok = true, owner = identifier }
end)

-- Recipe groups carried by a restaurant (what it may cook & sell). Groups are
-- free-form names; content with no group is available to every restaurant.
lib.callback.register("pickle_restaurants:admin:setGroups", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local id = tonumber(d.id); if not GetRestaurant(id) then return { ok = false } end
    local groups, seen = {}, {}
    for _, g in ipairs(type(d.groups) == "table" and d.groups or {}) do
        g = tostring(g):gsub("^%s+", ""):gsub("%s+$", "")
        if g ~= "" and not seen[g] then
            seen[g] = true
            groups[#groups + 1] = g
        end
    end
    MySQL.update.await("UPDATE pickle_restaurants SET `groups` = ? WHERE id = ?",
        { #groups > 0 and json.encode(groups) or nil, id })
    RestaurantCache[id].groups = #groups > 0 and groups or nil
    return { ok = true, groups = groups }
end)

-- Branding: same per-texture URL + crop config as the boss panel, but admin-gated so
-- a server admin can brand any restaurant. Shares SetRestaurantBrand (management).
lib.callback.register("pickle_restaurants:admin:setBrandImage", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local res = SetRestaurantBrand(tonumber(d.id), d.key, d.url, d.crop)
    if res and res.ok then ShowNotification(src, _L("branding_saved")) end
    return res
end)

-- Theme: same seed config as the boss panel, admin-gated. Shares
-- SetRestaurantTheme (management).
lib.callback.register("pickle_restaurants:admin:setTheme", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local res = SetRestaurantTheme(tonumber(d.id), d.theme)
    if res and res.ok then ShowNotification(src, _L("theme_saved")) end
    return res
end)

-- App-level theme: skins the /restaurants admin panel itself, stored as the
-- `app_theme` setting (not per-restaurant). Client-render-only — no world sync.
lib.callback.register("pickle_restaurants:admin:setAppTheme", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    SetSetting("app_theme", SanitizeTheme(d.theme))
    ShowNotification(src, _L("theme_saved"))
    return { ok = true }
end)

-- ─── settings ────────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:admin:saveSetting", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not d.key then return { ok = false } end
    SetSetting(d.key, d.value)
    SyncToClient(-1) -- drinks/assembly/blip may have changed
    ShowNotification(src, _L("admin_settings_saved"))
    return { ok = true }
end)

-- Batch save (the debounced auto-save writes a whole settings group at once): one DB
-- write per key, ONE sync, ONE "saved" notification — so an auto-save of a multi-field
-- group doesn't spam a notification per field.
lib.callback.register("pickle_restaurants:admin:saveSettings", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if type(d.settings) ~= "table" then return { ok = false } end
    local n = 0
    for k, v in pairs(d.settings) do SetSetting(k, v); n = n + 1 end
    if n == 0 then return { ok = false } end
    SyncToClient(-1)
    ShowNotification(src, _L("admin_settings_saved"))
    return { ok = true }
end)

-- ─── recipes ─────────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:admin:saveRecipe", function(src, r)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not r.input_item or r.input_item == "" then return { ok = false, error = _L("admin_input_item_required") } end
    local method = (r.method == "oven" or r.method == "fry") and r.method or "grill"
    -- optional container prop the food cooks in (cake tin…); empty clears it
    local container = (type(r.container_model) == "string" and r.container_model ~= "") and r.container_model or nil
    -- per-recipe freshness window: blank clears it (NULL = use the global default),
    -- a number is clamped to >= 0 (0 = never expires)
    local expire = nil
    if r.expire_seconds ~= nil and r.expire_seconds ~= "" then
        expire = math.max(0, math.floor(tonumber(r.expire_seconds) or 0))
    end
    -- optional access group ("bakery"…); blank clears it (NULL = every restaurant)
    local group = (type(r.group) == "string" and r.group:gsub("^%s+", ""):gsub("%s+$", "") ~= "")
        and r.group:gsub("^%s+", ""):gsub("%s+$", "") or nil
    MySQL.update.await([[
        INSERT INTO pickle_restaurant_recipes
            (input_item, station, raw_model, cooked_model, burnt_model, output_cooked_item, output_burnt_item, cook_ms, burn_ms, dual_sided, method, output_count, container_model, expire_seconds, `group`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            station = VALUES(station), raw_model = VALUES(raw_model), cooked_model = VALUES(cooked_model),
            burnt_model = VALUES(burnt_model), output_cooked_item = VALUES(output_cooked_item),
            output_burnt_item = VALUES(output_burnt_item), cook_ms = VALUES(cook_ms), burn_ms = VALUES(burn_ms),
            dual_sided = VALUES(dual_sided), method = VALUES(method), output_count = VALUES(output_count),
            container_model = VALUES(container_model), expire_seconds = VALUES(expire_seconds), `group` = VALUES(`group`)
    ]], {
        r.input_item, r.station or "fryer", r.raw_model or "", r.cooked_model or "", r.burnt_model or "",
        r.output_cooked_item or "", r.output_burnt_item or "",
        tonumber(r.cook_ms) or 15000, tonumber(r.burn_ms) or 15000,
        (r.dual_sided == true or r.dual_sided == 1) and 1 or 0, method,
        math.max(1, math.floor(tonumber(r.output_count) or 1)),
        container, expire, group,
    })
    LoadRecipes()
    SyncToClient(-1)
    ShowNotification(src, _L("admin_recipe_saved"))
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:admin:deleteRecipe", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    MySQL.update.await("DELETE FROM pickle_restaurant_recipes WHERE input_item = ?", { d.input_item })
    LoadRecipes()
    SyncToClient(-1)
    ShowNotification(src, _L("admin_recipe_deleted"))
    return { ok = true }
end)

-- Wipe all recipes and restore the built-in defaults (Settings → General).
lib.callback.register("pickle_restaurants:admin:resetRecipes", function(src)
    if not IsPlayerAdmin(src) then return { ok = false } end
    ResetRecipesToDefault()
    SyncToClient(-1)
    ShowNotification(src, _L("admin_recipes_reset"))
    return { ok = true }
end)
