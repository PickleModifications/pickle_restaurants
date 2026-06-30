-- =============================================
--  pickle_restaurants | core/server.lua
--  Database bootstrap, seeding, caches & shared server API.
--
--  Everything is database-driven. On first boot every table is created with
--  CREATE TABLE IF NOT EXISTS and sensible defaults (settings + cookable
--  recipes for the streamed food models) are seeded. There is no config.lua.
-- =============================================

RestaurantCache = {}   -- [id]            = row (json fields decoded)
PropCache       = {}    -- [id]            = prop row
RecipeCache     = {}    -- array of recipe rows
RecipeByInput   = {}    -- [input_item]    = recipe
EmployeeCache   = {}    -- [restaurantId][identifier] = employee row
StockCache      = {}    -- [restaurantId][item] = count
SettingsCache   = {}    -- [key]           = decoded value

PERMISSIONS = { "cook", "sell", "manage_menu", "manage_props", "manage_employees", "view_finances", "manage_balance" }
ALL_PERMS   = {}
for _, p in ipairs(PERMISSIONS) do ALL_PERMS[p] = true end

-- ─── json helpers ────────────────────────────────────────────────────────────

local function dec(v, default)
    if type(v) == "table" then return v end
    if type(v) == "string" and v ~= "" then
        local ok, res = pcall(json.decode, v)
        if ok and res ~= nil then return res end
    end
    return default
end

-- ─── settings ────────────────────────────────────────────────────────────────

function GetSetting(key, default)
    local v = SettingsCache[key]
    if v == nil then return default end
    return v
end

function SetSetting(key, value)
    SettingsCache[key] = value
    MySQL.update("INSERT INTO pickle_restaurant_settings (setting_key, setting_value) VALUES (?, ?) "
        .. "ON DUPLICATE KEY UPDATE setting_value = VALUES(setting_value)", { key, json.encode(value) })
end

local DEFAULT_SETTINGS = {
    admin_command   = "restaurants",
    currency        = "money",
    starting_balance = 0,
    default_commission = 10,
    blip            = { sprite = 93, color = 1, scale = 0.8, enabled = true },
    default_roles   = {
        ["0"] = { label = "Trainee", commission = 5,  permissions = { cook = true } },
        ["1"] = { label = "Cook",    commission = 10, permissions = { cook = true, sell = true } },
        ["2"] = { label = "Manager", commission = 15, permissions = {
            cook = true, sell = true, manage_menu = true, manage_props = true,
            manage_employees = true, view_finances = true,
        } },
    },
    npc = {
        enabled  = true,
        max      = 2,
        interval = 45000,
        patience = 60000,
        models   = { "a_m_y_business_01", "a_f_y_business_02", "a_m_m_business_01", "a_f_y_hipster_02", "a_m_y_skater_01" },
    },
    -- Soda machine fill definitions: dragged cup item -> filled drink item.
    drinks = {
        { input = "empty_cup", output = "soda", label = "Soda", model = "pickle_drink_container_01", fill_ms = 3000 },
    },
    -- Kitchen-prep assembly: combine components -> output item.
    assembly = {
        { output = "burger", label = "Burger", model = "pickle_bread_bun_01",
          components = { "bun", "cooked_beef_patty" } },
        { output = "cheeseburger", label = "Cheeseburger", model = "pickle_bread_bun_01",
          components = { "bun", "cooked_beef_patty", "cheese" } },
        { output = "chicken_sandwich", label = "Chicken Sandwich", model = "pickle_bread_bun_01",
          components = { "bun", "cooked_chicken_patty" } },
        -- Veg toppings are whole ingredients (lettuce topping = lettuce, etc.).
        { output = "deluxe_burger", label = "Deluxe Burger", model = "pickle_bread_bun_01",
          components = { "bun", "cooked_beef_patty", "cheese", "lettuce", "tomato", "pickle" } },
        -- Pizza: top a dough at kitchen prep, then bake the raw pizza in the oven.
        { output = "raw_pizza", label = "Pizza (uncooked)", model = "pickle_pizza_dough_01",
          components = { "pizza_dough", "pizza_sauce", "pizza_cheese", "pepperoni" } },
        -- Bakery decoration: finish a fried doughnut / baked cake with frosting + sprinkles.
        { output = "frosted_doughnut", label = "Frosted Doughnut", model = "pickle_doughnut_topping_01",
          components = { "cooked_doughnut", "frosting", "sprinkles" } },
        { output = "decorated_cake", label = "Decorated Cake", model = "pickle_cake_04",
          components = { "cooked_cake", "frosting", "sprinkles" } },
    },
}

-- ─── default cookable recipes (one per streamed 3-variant food model) ─────────

local DEFAULT_RECIPES = {
    { input = "raw_drumstick", station = "fryer",
      raw = "pickle_fryer_drumstick_01", cooked = "pickle_fryer_drumstick_02", burnt = "pickle_fryer_drumstick_03",
      out_cooked = "cooked_drumstick", out_burnt = "burnt_drumstick", cook_ms = 15000, burn_ms = 15000 },
    { input = "raw_fries", station = "fryer",
      raw = "pickle_fryer_fries_01", cooked = "pickle_fryer_fries_02", burnt = "pickle_fryer_fries_03",
      out_cooked = "cooked_fries", out_burnt = "burnt_fries", cook_ms = 12000, burn_ms = 12000 },
    { input = "raw_nuggets", station = "fryer",
      raw = "pickle_fryer_nuggets_01", cooked = "pickle_fryer_nuggets_02", burnt = "pickle_fryer_nuggets_03",
      out_cooked = "cooked_nuggets", out_burnt = "burnt_nuggets", cook_ms = 12000, burn_ms = 12000 },
    { input = "raw_beef_patty", station = "stovetop",
      raw = "pickle_patty_beef_01", cooked = "pickle_patty_beef_02", burnt = "pickle_patty_beef_03",
      out_cooked = "cooked_beef_patty", out_burnt = "burnt_beef_patty", cook_ms = 18000, burn_ms = 15000 },
    { input = "raw_chicken_patty", station = "stovetop",
      raw = "pickle_patty_friedchicken_01", cooked = "pickle_patty_friedchicken_02", burnt = "pickle_patty_friedchicken_03",
      out_cooked = "cooked_chicken_patty", out_burnt = "burnt_chicken_patty", cook_ms = 18000, burn_ms = 15000 },
    -- Doughnuts are fried.
    { input = "raw_doughnut", station = "fryer",
      raw = "pickle_doughnut_01", cooked = "pickle_doughnut_02", burnt = "pickle_doughnut_03",
      out_cooked = "cooked_doughnut", out_burnt = "burnt_doughnut", cook_ms = 12000, burn_ms = 12000 },
    -- Cookies + cake bake in the oven (the stovetop station doubles as the oven).
    { input = "raw_cookie", station = "stovetop",
      raw = "pickle_cookie_01", cooked = "pickle_cookie_02", burnt = "pickle_cookie_03",
      out_cooked = "cooked_cookie", out_burnt = "burnt_cookie", cook_ms = 20000, burn_ms = 18000 },
    { input = "raw_cake", station = "stovetop",
      raw = "pickle_cake_01", cooked = "pickle_cake_02", burnt = "pickle_cake_03",
      out_cooked = "cooked_cake", out_burnt = "burnt_cake", cook_ms = 30000, burn_ms = 25000 },
    -- Pizza bakes in the oven; the raw (topped) pizza is assembled at kitchen prep first.
    { input = "raw_pizza", station = "stovetop",
      raw = "pickle_pizza_dough_01", cooked = "pickle_pizza_dough_02", burnt = "pickle_pizza_dough_03",
      out_cooked = "cooked_pizza", out_burnt = "burnt_pizza", cook_ms = 25000, burn_ms = 20000 },
}

-- ─── DB bootstrap ────────────────────────────────────────────────────────────

local function CreateTables()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurants` (
            `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `name`             VARCHAR(60)  NOT NULL,
            `label`            VARCHAR(100) NOT NULL,
            `owner_identifier` VARCHAR(80)  DEFAULT NULL,
            `balance`          BIGINT       NOT NULL DEFAULT 0,
            `blip`             JSON         DEFAULT NULL,
            `counter`          JSON         DEFAULT NULL,
            `roles`            JSON         DEFAULT NULL,
            `menu_enabled`     TINYINT(1)   NOT NULL DEFAULT 1,
            `metadata`         JSON         DEFAULT NULL,
            `created_at`       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at`       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_owner` (`owner_identifier`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_employees` (
            `id`              INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id`   INT UNSIGNED NOT NULL,
            `identifier`      VARCHAR(80)  NOT NULL,
            `name`            VARCHAR(100) DEFAULT NULL,
            `grade`           INT          NOT NULL DEFAULT 0,
            `commission_rate` DECIMAL(5,2) NOT NULL DEFAULT 10.00,
            `hired_at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `metadata`        JSON         DEFAULT NULL,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_emp` (`restaurant_id`, `identifier`),
            KEY `idx_rest` (`restaurant_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_props` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `prop_type`     VARCHAR(30)  NOT NULL,
            `model`         VARCHAR(80)  NOT NULL,
            `x`             DOUBLE       NOT NULL,
            `y`             DOUBLE       NOT NULL,
            `z`             DOUBLE       NOT NULL,
            `heading`       DOUBLE       NOT NULL DEFAULT 0,
            `metadata`      JSON         DEFAULT NULL,
            `created_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_rest` (`restaurant_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_recipes` (
            `id`                 INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `input_item`         VARCHAR(60)  NOT NULL,
            `station`            VARCHAR(30)  NOT NULL,
            `raw_model`          VARCHAR(80)  NOT NULL,
            `cooked_model`       VARCHAR(80)  NOT NULL,
            `burnt_model`        VARCHAR(80)  NOT NULL,
            `output_cooked_item` VARCHAR(60)  NOT NULL,
            `output_burnt_item`  VARCHAR(60)  NOT NULL,
            `cook_ms`            INT          NOT NULL DEFAULT 15000,
            `burn_ms`            INT          NOT NULL DEFAULT 15000,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_input` (`input_item`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_menu` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `item`          VARCHAR(60)  NOT NULL,
            `label`         VARCHAR(100) NOT NULL,
            `price`         INT          NOT NULL DEFAULT 0,
            `category`      VARCHAR(40)  DEFAULT 'food',
            `enabled`       TINYINT(1)   NOT NULL DEFAULT 1,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_item` (`restaurant_id`, `item`),
            KEY `idx_rest` (`restaurant_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_stock` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `item`          VARCHAR(60)  NOT NULL,
            `count`         INT          NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_stock` (`restaurant_id`, `item`),
            KEY `idx_rest` (`restaurant_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_ledger` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `type`          VARCHAR(30)  NOT NULL,
            `amount`        BIGINT       NOT NULL DEFAULT 0,
            `description`   VARCHAR(255) DEFAULT NULL,
            `identifier`    VARCHAR(80)  DEFAULT NULL,
            `created_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_rest` (`restaurant_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_settings` (
            `setting_key`   VARCHAR(60) NOT NULL,
            `setting_value` JSON        NOT NULL,
            PRIMARY KEY (`setting_key`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
end

-- ─── loaders ─────────────────────────────────────────────────────────────────

local function LoadSettings()
    SettingsCache = {}
    local rows = MySQL.query.await("SELECT setting_key, setting_value FROM pickle_restaurant_settings") or {}
    for _, row in ipairs(rows) do
        SettingsCache[row.setting_key] = dec(row.setting_value, nil)
    end
    -- Seed any missing defaults (idempotent; only writes keys that don't exist).
    for key, value in pairs(DEFAULT_SETTINGS) do
        if SettingsCache[key] == nil then SetSetting(key, value) end
    end

    -- Merge in any newly-added default assembly/drink entries (matched by their
    -- output/input) so fresh defaults appear on restart without clobbering ones
    -- an admin customised — mirrors how SeedRecipes upserts missing recipes.
    local function mergeListDefaults(key, idField)
        local list = SettingsCache[key]
        if type(list) ~= "table" then return end
        local seen = {}
        for _, entry in ipairs(list) do seen[entry[idField]] = true end
        local changed = false
        for _, def in ipairs(DEFAULT_SETTINGS[key] or {}) do
            if not seen[def[idField]] then list[#list + 1] = def; changed = true end
        end
        if changed then SetSetting(key, list) end
    end
    mergeListDefaults("assembly", "output")
    mergeListDefaults("drinks", "output")
end

local function SeedRecipes()
    -- Insert any default recipe that isn't present yet (keyed by the unique
    -- input_item). This means newly-added defaults show up on the next restart
    -- without wiping the table or overwriting recipes an admin has customised.
    for _, r in ipairs(DEFAULT_RECIPES) do
        MySQL.insert.await([[
            INSERT INTO pickle_restaurant_recipes
                (input_item, station, raw_model, cooked_model, burnt_model, output_cooked_item, output_burnt_item, cook_ms, burn_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE input_item = input_item
        ]], { r.input, r.station, r.raw, r.cooked, r.burnt, r.out_cooked, r.out_burnt, r.cook_ms, r.burn_ms })
    end
end

function LoadRecipes()
    RecipeCache, RecipeByInput = {}, {}
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurant_recipes") or {}
    for _, row in ipairs(rows) do
        RecipeCache[#RecipeCache + 1] = row
        RecipeByInput[row.input_item] = row
    end
end

local function LoadEmployees()
    EmployeeCache = {}
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurant_employees") or {}
    for _, row in ipairs(rows) do
        EmployeeCache[row.restaurant_id] = EmployeeCache[row.restaurant_id] or {}
        EmployeeCache[row.restaurant_id][row.identifier] = row
    end
end

local function LoadStock()
    StockCache = {}
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurant_stock") or {}
    for _, row in ipairs(rows) do
        StockCache[row.restaurant_id] = StockCache[row.restaurant_id] or {}
        StockCache[row.restaurant_id][row.item] = row.count
    end
end

local function LoadProps()
    PropCache = {}
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurant_props") or {}
    for _, row in ipairs(rows) do
        row.metadata = dec(row.metadata, {})
        PropCache[row.id] = row
    end
end

function LoadRestaurants()
    RestaurantCache = {}
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurants") or {}
    for _, row in ipairs(rows) do
        row.blip     = dec(row.blip, nil)
        row.counter  = dec(row.counter, nil)
        row.roles    = dec(row.roles, nil)
        row.metadata = dec(row.metadata, {})
        RestaurantCache[row.id] = row
    end
end

function GetRestaurant(id) return RestaurantCache[tonumber(id)] end

-- ─── item catalogue / validation ─────────────────────────────────────────────
-- The framework bridge populates Inventory.Items (name -> { label }). The NUI
-- needs that catalogue so configs are built by *picking* real items instead of
-- typing raw codenames, and any config that references a missing item is shown
-- with an error and hidden in-game until it's fixed.

function ItemExists(name)
    if not name or name == "" then return false end
    local items = Inventory and Inventory.Items
    -- If the catalogue hasn't loaded yet we can't validate; don't penalise.
    if not items or next(items) == nil then return true end
    return items[name] ~= nil or items[toupper(name)] ~= nil
end

-- Sorted array of every known item: { { name, label }, ... }
function BuildItemList()
    local list = {}
    local items = (Inventory and Inventory.Items) or {}
    for name, data in pairs(items) do
        list[#list + 1] = { name = name, label = (type(data) == "table" and data.label) or name }
    end
    table.sort(list, function(a, b) return (a.label or a.name):lower() < (b.label or b.name):lower() end)
    return list
end

-- Items a recipe references that don't exist in the catalogue.
function RecipeMissingItems(r)
    local missing = {}
    for _, it in ipairs({ r.input_item, r.output_cooked_item, r.output_burnt_item }) do
        if not ItemExists(it) then missing[#missing + 1] = it end
    end
    return missing
end

function IsRecipeValid(r) return #RecipeMissingItems(r) == 0 end

-- Drinks / assembly entries reference items too; same validity rules apply.
local function drinkMissing(d)
    local missing = {}
    if not ItemExists(d.input) then missing[#missing + 1] = d.input end
    if not ItemExists(d.output) then missing[#missing + 1] = d.output end
    return missing
end

local function assemblyMissing(a)
    local missing = {}
    if not ItemExists(a.output) then missing[#missing + 1] = a.output end
    for _, comp in ipairs(a.components or {}) do
        if not ItemExists(comp) then missing[#missing + 1] = comp end
    end
    return missing
end

-- Annotate a list with valid/missing without mutating the cached source rows.
function AnnotateRecipes()
    local out = {}
    for _, r in ipairs(RecipeCache) do
        local missing = RecipeMissingItems(r)
        local copy = {}
        for k, v in pairs(r) do copy[k] = v end
        copy.valid, copy.missing = #missing == 0, missing
        out[#out + 1] = copy
    end
    return out
end

function AnnotateDrinks()
    local out = {}
    for _, d in ipairs(GetSetting("drinks", {})) do
        local missing = drinkMissing(d)
        local copy = {}; for k, v in pairs(d) do copy[k] = v end
        copy.valid, copy.missing = #missing == 0, missing
        out[#out + 1] = copy
    end
    return out
end

function AnnotateAssembly()
    local out = {}
    for _, a in ipairs(GetSetting("assembly", {})) do
        local missing = assemblyMissing(a)
        local copy = {}; for k, v in pairs(a) do copy[k] = v end
        copy.valid, copy.missing = #missing == 0, missing
        out[#out + 1] = copy
    end
    return out
end

-- ─── permissions ─────────────────────────────────────────────────────────────

-- Returns: permsTable, isOwnerOrAdmin, employeeRow
function ResolvePerms(restaurantId, source)
    local r = GetRestaurant(restaurantId)
    if not r then return nil, false, nil end
    if IsPlayerAdmin(source) then return ALL_PERMS, true, nil end
    local id = GetIdentifier(source)
    if not id then return nil, false, nil end
    if r.owner_identifier and r.owner_identifier == id then return ALL_PERMS, true, nil end
    local emp = EmployeeCache[restaurantId] and EmployeeCache[restaurantId][id]
    if not emp then return nil, false, nil end
    local roles = r.roles or GetSetting("default_roles", {})
    local role = roles[tostring(emp.grade)] or roles[emp.grade]
    return (role and role.permissions) or {}, false, emp
end

function HasPerm(restaurantId, source, perm)
    local perms, isOwner = ResolvePerms(restaurantId, source)
    if not perms then return false end
    if isOwner then return true end
    return perms[perm] == true
end

-- ─── balance / ledger / stock ────────────────────────────────────────────────

function AdjustBalance(restaurantId, delta)
    local r = GetRestaurant(restaurantId); if not r then return end
    r.balance = (r.balance or 0) + RoundMoney(delta)
    MySQL.update("UPDATE pickle_restaurants SET balance = ? WHERE id = ?", { r.balance, restaurantId })
end

function AddLedger(restaurantId, ltype, amount, description, identifier)
    MySQL.insert("INSERT INTO pickle_restaurant_ledger (restaurant_id, type, amount, description, identifier) VALUES (?, ?, ?, ?, ?)",
        { restaurantId, ltype, RoundMoney(amount), description or "", identifier })
end

function GetStockCount(restaurantId, item)
    return (StockCache[restaurantId] and StockCache[restaurantId][item]) or 0
end

function AddStock(restaurantId, item, count)
    StockCache[restaurantId] = StockCache[restaurantId] or {}
    StockCache[restaurantId][item] = (StockCache[restaurantId][item] or 0) + count
    MySQL.update("INSERT INTO pickle_restaurant_stock (restaurant_id, item, count) VALUES (?, ?, ?) "
        .. "ON DUPLICATE KEY UPDATE count = count + VALUES(count)", { restaurantId, item, count })
end

function RemoveStock(restaurantId, item, count)
    if GetStockCount(restaurantId, item) < count then return false end
    StockCache[restaurantId][item] = StockCache[restaurantId][item] - count
    MySQL.update("UPDATE pickle_restaurant_stock SET count = count - ? WHERE restaurant_id = ? AND item = ?",
        { count, restaurantId, item })
    return true
end

-- ─── employee cache mutators (used by management module) ──────────────────────

function CacheEmployee(restaurantId, row)
    EmployeeCache[restaurantId] = EmployeeCache[restaurantId] or {}
    EmployeeCache[restaurantId][row.identifier] = row
end

function UncacheEmployee(restaurantId, identifier)
    if EmployeeCache[restaurantId] then EmployeeCache[restaurantId][identifier] = nil end
end

function GetEmployeesForRestaurant(restaurantId)
    local list = {}
    for _, emp in pairs(EmployeeCache[restaurantId] or {}) do list[#list + 1] = emp end
    return list
end

-- ─── client sync ─────────────────────────────────────────────────────────────

local function BuildClientRestaurant(r)
    return {
        id      = r.id,
        name    = r.name,
        label   = r.label,
        blip    = r.blip,
        counter = r.counter,
    }
end

function BuildSyncPayload()
    -- Only valid configs are shipped to the game world. A recipe / drink /
    -- assembly that references a missing item is hidden until an admin fixes it
    -- (it still shows in the admin panel, flagged, so it *can* be fixed).
    local recipes = {}
    for _, r in ipairs(RecipeCache) do
        if IsRecipeValid(r) then recipes[#recipes + 1] = r end
    end
    local drinks = {}
    for _, d in ipairs(GetSetting("drinks", {})) do
        if ItemExists(d.input) and ItemExists(d.output) then drinks[#drinks + 1] = d end
    end
    local assembly = {}
    for _, a in ipairs(GetSetting("assembly", {})) do
        local ok = ItemExists(a.output)
        for _, comp in ipairs(a.components or {}) do if not ItemExists(comp) then ok = false end end
        if ok then assembly[#assembly + 1] = a end
    end

    local payload = { restaurants = {}, props = {}, recipes = recipes, settings = {
        drinks   = drinks,
        assembly = assembly,
    } }
    for _, r in pairs(RestaurantCache) do payload.restaurants[#payload.restaurants + 1] = BuildClientRestaurant(r) end
    for _, p in pairs(PropCache) do payload.props[#payload.props + 1] = p end
    return payload
end

function SyncToClient(target)
    TriggerClientEvent("pickle_restaurants:sync", target, BuildSyncPayload())
end

RegisterNetEvent("pickle_restaurants:requestSync", function()
    -- Hand the framework bridge's item list to the client so GetItemLabel works
    -- and the client-side Inventory mirror flips to Ready.
    if Inventory and Inventory.Items then
        TriggerClientEvent("pickle_restaurants:setupInventory", source, { items = Inventory.Items })
    end
    SyncToClient(source)
end)

-- ─── boot ────────────────────────────────────────────────────────────────────

CreateThread(function()
    MySQL.ready(function()
        CreateTables()
        LoadSettings()
        SeedRecipes()
        LoadRecipes()
        LoadRestaurants()
        LoadProps()
        LoadEmployees()
        LoadStock()
        RestaurantsReady = true
        debugPrint(("Booted: %d restaurants, %d props, %d recipes."):format(
            #BuildSyncPayload().restaurants, #BuildSyncPayload().props, #RecipeCache))
        -- Push to anyone already connected (resource restart mid-session).
        SyncToClient(-1)
    end)
end)
