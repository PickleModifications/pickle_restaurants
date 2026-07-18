-- =============================================
--  modules/admin | server.lua
--  Admin command + callbacks: create/delete restaurants, assign owner,
--  edit global settings & cookable recipes. All gated by IsPlayerAdmin.
-- =============================================

local function buildAdminData()
    local data = {
        restaurants = {},
        theme       = GetSetting("app_theme", nil), -- App-level: skins /restaurants itself
        phoneTheme  = GetSetting("phone_theme", nil), -- ONE global skin for the lb-phone app
        settings    = SettingsCache,
        -- The three authored creation kinds, each flagged valid/missing + per-entry
        -- annotations (defaultPrice, tap, duplicate_input, *_installed). The NUI
        -- strips the annotations before saving the array back.
        foods       = AnnotateFoods(),
        tools       = AnnotateTools(),
        ingredients = AnnotateIngredients(),
        -- The shipped default menu, verbatim — feeds the NUI's "Import Defaults"
        -- dialog (restore a deleted default / reset an edited one, no restart).
        defaults    = { foods = DEFAULT_FOODS, tools = DEFAULT_TOOLS, ingredients = DEFAULT_INGREDIENTS },
        items       = BuildItemList(),     -- catalogue for item-pickers
        groups      = CollectGroups(),     -- every group name in use (UI suggestions)
        players     = {},
        -- Brand-texture aspects for the crop UI, from the ONE render-target registry
        -- (core/shared.lua) so the panel never hardcodes a resolution that drifts.
        renderTargets = BrandRenderTargets(),
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
    MySQL.update.await("DELETE FROM pickle_restaurant_combos WHERE restaurant_id = ?", { id })
    RestaurantCache[id] = nil
    EmployeeCache[id] = nil
    StockCache[id] = nil
    ClearOrders(id) -- drops OrderCache/NextTicket + bumps the rev so a stale register can't re-apply
    ClearCombos(id) -- drops the combo cache for the deleted restaurant
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

-- Phone-app theme: ONE global skin for the lb-phone companion app, stored as the
-- `phone_theme` setting (not per-restaurant — the phone keeps a single consistent
-- look). Pushed live to every open phone so the change previews without reopening.
lib.callback.register("pickle_restaurants:admin:setPhoneTheme", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local theme = SanitizeTheme(d.theme)
    SetSetting("phone_theme", theme)
    TriggerClientEvent("pickle_restaurants:phone:pushTheme", -1, theme)
    ShowNotification(src, _L("theme_saved"))
    return { ok = true }
end)

-- ─── settings ────────────────────────────────────────────────────────────────

-- The authored menu arrays (foods/tools/ingredients) are settings like any other,
-- but each is sanitized on the way in (the NUI is untrusted) and triggers a
-- derivation rebuild so the runtime caches (RecipeCache, derived assembly/drinks/
-- crafts/finishes/condiments/baking, prep models) reflect the edit immediately.
local MENU_SANITIZERS = {
    foods       = SanitizeFoods,
    tools       = SanitizeTools,
    ingredients = SanitizeIngredients,
}

-- Apply a settings write, routing the three authored menu keys through their
-- sanitizer. Returns true if a menu key was written (caller rebuilds derived).
local function applySetting(key, value)
    local san = MENU_SANITIZERS[key]
    if san then SetSetting(key, san(value)); return true end
    SetSetting(key, value)
    return false
end

lib.callback.register("pickle_restaurants:admin:saveSetting", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not d.key then return { ok = false } end
    if applySetting(d.key, d.value) then RebuildDerived() end
    SyncToClient(-1) -- foods/tools/blip may have changed
    ShowNotification(src, _L("admin_settings_saved"))
    return { ok = true }
end)

-- Batch save (the debounced auto-save writes a whole settings group at once): one DB
-- write per key, ONE sync, ONE "saved" notification — so an auto-save of a multi-field
-- group doesn't spam a notification per field.
lib.callback.register("pickle_restaurants:admin:saveSettings", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if type(d.settings) ~= "table" then return { ok = false } end
    local n, rebuild = 0, false
    for k, v in pairs(d.settings) do
        if applySetting(k, v) then rebuild = true end
        n = n + 1
    end
    if n == 0 then return { ok = false } end
    if rebuild then RebuildDerived() end
    SyncToClient(-1)
    ShowNotification(src, _L("admin_settings_saved"))
    return { ok = true }
end)

-- ─── menu ────────────────────────────────────────────────────────────────────

-- Reset the whole authored menu (foods + tools + ingredients) to the shipped
-- defaults (Settings → General). Rebuilds derived caches + syncs.
lib.callback.register("pickle_restaurants:admin:resetRecipes", function(src)
    if not IsPlayerAdmin(src) then return { ok = false } end
    ResetMenuToDefault()
    SyncToClient(-1)
    ShowNotification(src, _L("admin_recipes_reset"))
    return { ok = true }
end)
