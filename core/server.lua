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
TrayCache       = {}    -- [restaurantId][identifier][item.."|"..cheese] = { item, cheese, count, metas } (metas: one build stack — or false — per counted instance; TraySig(meta) addresses a variation)
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
    cheese_melt_ms  = 8000, -- how long applied cheese takes to melt on a patty
    -- The inventory item a serving-tray arrangement becomes at kitchen prep. The
    -- meal's metadata records every item WITH its position on the tray, so it
    -- re-renders 1:1 wherever it's set back down. The item is what gets GENERATED
    -- (itemgen exports it) — never a requirement to use the tray; only moving a
    -- meal into the real inventory needs it installed.
    meal_item       = "meal",
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
    -- Soda machine taps: dragged cup item -> filled drink item. The first SIX
    -- valid entries appear left-to-right as the fountain's flavor taps (the
    -- middle nozzle always dispenses ice, so the physical order is 1,2,3, ICE,
    -- 4,5,6). Order here = tap order; reorder to re-arrange the fountain.
    -- `color` = the {r,g,b} of the poured liquid stream (marker droplets), sampled
    -- from each tap's flavor art on the fountain model.
    drinks = {
        { input = "empty_cup", output = "water",      label = "Pure Aqua",      model = "pickle_drink_container_01", fill_ms = 3000, color = { 160, 205, 230 } },
        { input = "empty_cup", output = "lemonade",   label = "Lemonade Bliss", model = "pickle_drink_container_01", fill_ms = 3000, color = { 235, 215, 90 } },
        { input = "empty_cup", output = "soda",       label = "Classic Cola",   model = "pickle_drink_container_01", fill_ms = 3000, color = { 90, 50, 25 } },
        { input = "empty_cup", output = "diet_cola",  label = "Diet Cola",      model = "pickle_drink_container_01", fill_ms = 3000, color = { 120, 80, 55 } },
        { input = "empty_cup", output = "grape_soda", label = "Grape Zap",      model = "pickle_drink_container_01", fill_ms = 3000, color = { 135, 70, 170 } },
        { input = "empty_cup", output = "coffee",     label = "Coffee",         model = "pickle_drink_container_01", fill_ms = 3000, color = { 80, 50, 30 } },
    },
    -- The lid pressed onto a filled cup before it can be collected — kitchen
    -- equipment like the serving tray (no inventory item; cups come with lids),
    -- only its world model is configurable.
    drink_lid_model = "pickle_drink_lid_01",
    soda_ice_ms     = 1500, -- how long the middle (ice) nozzle takes to dispense
    -- World prop for a prep component that isn't a cook/assembly/drink output (raw
    -- veg, toppings, doughs…). Any item mapped here becomes a real 3D prop you can
    -- drag out and stack on the kitchen-prep table; add a row for any new item.
    prep_models = {
        bun          = "pickle_bread_bun_01",
        -- cheese is handled in itemModel (always the unmelted _01 slice), not here
        lettuce      = "pickle_lettuce_applied_01",
        tomato       = "pickle_tomato_applied_01",
        pickle       = "pickle_pickle_applied_01",
        pizza_dough  = "pickle_pizza_dough_01",
        pizza_sauce  = "pickle_pizza_sauce_01",
        pizza_cheese = "pickle_pizza_cheese_01",
        pepperoni    = "pickle_pizza_pepperoni_01",
        frosting     = "pickle_frosting_tube_01",
        sprinkles    = "pickle_sprinkles_tube_01",
        -- Single-serving props for the fryer batch outputs: the batch cooks as the
        -- basket pile (the recipe's models) but each collected item is held/stacked
        -- as one serving. An explicit mapping here overrides the recipe-derived
        -- model in itemModel.
        cooked_drumstick = "pickle_chicken_drumstick_02",
        burnt_drumstick  = "pickle_chicken_drumstick_03",
        cooked_fries     = "pickle_side_fries_02",
        burnt_fries      = "pickle_side_fries_03",
        cooked_nuggets   = "pickle_side_nuggets_02",
        burnt_nuggets    = "pickle_side_nuggets_03",
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
        -- Pizza: a cheese base (dough + sauce + cheese) assembled at kitchen prep, then
        -- baked in the oven. Pepperoni (and any other prep topping) is optional — add it
        -- on the stack as an alteration; it rides along as a variation.
        { output = "raw_pizza", label = "Pizza (uncooked)", model = "pickle_pizza_dough_01",
          components = { "pizza_dough", "pizza_sauce", "pizza_cheese" } },
    },
    -- Gradual "finish tools": an inventory item whose prop the player rubs over a
    -- finished product on the kitchen-prep table. Coverage builds with cursor
    -- movement (rub_dist metres of tool travel = fully applied); at 100% the target
    -- is consumed together with 1 tool item and the output lands in the tray with
    -- the chosen flavor recorded as build-stack metadata (so it survives every
    -- tray/inventory round trip as its own variation).
    --   mode = "replace": the target's props (e.g. container + batter sheet) are
    --          deleted and the flavor model IS the whole finished product.
    --   mode = "overlay": the flavor model stacks on top of the target's prop,
    --          which stays (e.g. frosting coats a doughnut).
    finishes = {
        { tool = "frosting", tool_model = "pickle_frosting_tube_01", rub_dist = 1.2,
          targets = {
            { item = "cooked_cake", output = "decorated_cake", mode = "replace",
              -- color drives the flavor swatch on the NUI card (falls back to a
              -- built-in palette by flavor id when omitted)
              flavors = {
                { id = "strawberry", label = "Strawberry", model = "pickle_cake_01", color = "#f472b6" },
                { id = "chocolate",  label = "Chocolate",  model = "pickle_cake_02", color = "#8b5a2b" },
                { id = "vanilla",    label = "Vanilla",    model = "pickle_cake_03", color = "#f3e5ab" },
                { id = "pickle",     label = "Pickle",     model = "pickle_cake_04", color = "#65a30d" },
              } },
            { item = "cooked_doughnut", output = "frosted_doughnut", mode = "overlay",
              flavors = {
                { id = "strawberry", label = "Strawberry", model = "pickle_doughnut_topping_01", color = "#f472b6" },
                { id = "chocolate",  label = "Chocolate",  model = "pickle_doughnut_topping_02", color = "#8b5a2b" },
                { id = "glazed",     label = "Glazed",     model = "pickle_doughnut_topping_03", color = "#f0c36d" },
                { id = "vanilla",    label = "Vanilla",    model = "pickle_doughnut_topping_04", color = "#f3e5ab" },
                { id = "pickle",     label = "Pickle",     model = "pickle_doughnut_topping_05", color = "#65a30d" },
              } },
          } },
    },
}

-- ─── default cookable recipes (one per streamed 3-variant food model) ─────────

local DEFAULT_RECIPES = {
    -- The fryer batch models render a basketful, so one fry yields a serving of
    -- individual items (output_count) when collected cooked/burnt.
    { input = "raw_drumstick", station = "fryer", method = "fry",
      raw = "pickle_fryer_drumstick_01", cooked = "pickle_fryer_drumstick_02", burnt = "pickle_fryer_drumstick_03",
      out_cooked = "cooked_drumstick", out_burnt = "burnt_drumstick", cook_ms = 15000, burn_ms = 15000,
      output_count = 4 },
    { input = "raw_fries", station = "fryer", method = "fry",
      raw = "pickle_fryer_fries_01", cooked = "pickle_fryer_fries_02", burnt = "pickle_fryer_fries_03",
      out_cooked = "cooked_fries", out_burnt = "burnt_fries", cook_ms = 12000, burn_ms = 12000,
      output_count = 4 },
    { input = "raw_nuggets", station = "fryer", method = "fry",
      raw = "pickle_fryer_nuggets_01", cooked = "pickle_fryer_nuggets_02", burnt = "pickle_fryer_nuggets_03",
      out_cooked = "cooked_nuggets", out_burnt = "burnt_nuggets", cook_ms = 12000, burn_ms = 12000,
      output_count = 20 },
    { input = "raw_beef_patty", station = "stovetop", method = "grill",
      raw = "pickle_patty_beef_01", cooked = "pickle_patty_beef_02", burnt = "pickle_patty_beef_03",
      out_cooked = "cooked_beef_patty", out_burnt = "burnt_beef_patty", cook_ms = 18000, burn_ms = 15000,
      dual_sided = 1 },
    { input = "raw_chicken_patty", station = "stovetop", method = "grill",
      raw = "pickle_patty_friedchicken_01", cooked = "pickle_patty_friedchicken_02", burnt = "pickle_patty_friedchicken_03",
      out_cooked = "cooked_chicken_patty", out_burnt = "burnt_chicken_patty", cook_ms = 18000, burn_ms = 15000 },
    -- Doughnuts are fried.
    { input = "raw_doughnut", station = "fryer", method = "fry",
      raw = "pickle_doughnut_01", cooked = "pickle_doughnut_02", burnt = "pickle_doughnut_03",
      out_cooked = "cooked_doughnut", out_burnt = "burnt_doughnut", cook_ms = 12000, burn_ms = 12000 },
    -- Cookies + cake bake inside the oven doors (on their own trays).
    { input = "raw_cookie", station = "stovetop", method = "oven",
      raw = "pickle_cookie_01", cooked = "pickle_cookie_02", burnt = "pickle_cookie_03",
      out_cooked = "cooked_cookie", out_burnt = "burnt_cookie", cook_ms = 20000, burn_ms = 18000 },
    -- Cake batter bakes as a thin sheet inside its container tray (the container
    -- rides along visually, never an item). pickle_cake_01..04 are the four whole
    -- flavored cakes the frosting finish tool produces — not cook states.
    { input = "raw_cake", station = "stovetop", method = "oven",
      raw = "pickle_cake_mix_pour_02", cooked = "pickle_cake_mix_pour_03", burnt = "pickle_cake_mix_pour_04",
      container = "pickle_cake_container_01",
      out_cooked = "cooked_cake", out_burnt = "burnt_cake", cook_ms = 30000, burn_ms = 25000 },
    -- Pizza bakes bare on the oven rack; the raw (topped) pizza is assembled at kitchen prep first.
    { input = "raw_pizza", station = "stovetop", method = "oven",
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
            `dual_sided`         TINYINT(1)   NOT NULL DEFAULT 0,
            -- how the item is cooked: grill (cooktop surface), oven (inside a door),
            -- or fry (fryer basket). Governs the station interaction UX.
            `method`             VARCHAR(10)  NOT NULL DEFAULT 'grill',
            -- how many output items one cook yields when collected cooked/burnt
            -- (a basket of fries is a batch, not one giant fry)
            `output_count`       SMALLINT UNSIGNED NOT NULL DEFAULT 1,
            -- optional container prop the food cooks in (cake tin, cookie tray…):
            -- rendered under the cook models everywhere, purely visual, never an item
            `container_model`    VARCHAR(80)  DEFAULT NULL,
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

    -- Per-player, per-restaurant "Cooked Items" tray: cooked products held as a
    -- state (with a cheese flag) between the grill and the prep station.
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_cooked_items` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `identifier`    VARCHAR(80)  NOT NULL,
            `item`          VARCHAR(60)  NOT NULL,
            -- NOT TINYINT(1): oxmysql boolean-casts TINYINT(1), which can't hold the
            -- third cheese state (0=none, 1=applied, 2=melted) — 2 would read back wrong.
            `cheese`        TINYINT UNSIGNED NOT NULL DEFAULT 0,
            `count`         INT          NOT NULL DEFAULT 0,
            -- Per-instance build stacks (JSON array, one entry per counted item) so an
            -- assembled product remembers what actually went into it — alterations and
            -- cheese states included — and can be taken back apart faithfully.
            `metadata`      JSON         DEFAULT NULL,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_tray` (`restaurant_id`, `identifier`, `item`, `cheese`),
            KEY `idx_rest_id` (`restaurant_id`, `identifier`)
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

    -- Migrations for tables that already exist from an earlier version. When the
    -- dual_sided column is first added, turn it on for the default dual recipes
    -- (e.g. beef patties) so existing servers get the feature without an admin
    -- having to tick the box. Runs once — only while the column is missing.
    local cols = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_recipes` LIKE 'dual_sided'")
    if not cols or #cols == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_recipes` ADD COLUMN `dual_sided` TINYINT(1) NOT NULL DEFAULT 0")
        for _, r in ipairs(DEFAULT_RECIPES) do
            if r.dual_sided == 1 then
                MySQL.update.await(
                    "UPDATE `pickle_restaurant_recipes` SET `dual_sided` = 1 WHERE `input_item` = ?", { r.input })
            end
        end
    end

    -- The `method` classifier (grill/oven/fry) drives the cooking UX. On the first
    -- add, backfill the default recipes' methods so existing servers get baking in
    -- the oven + the fryer basket without an admin re-tagging every recipe.
    local mcol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_recipes` LIKE 'method'")
    if not mcol or #mcol == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_recipes` ADD COLUMN `method` VARCHAR(10) NOT NULL DEFAULT 'grill'")
        for _, r in ipairs(DEFAULT_RECIPES) do
            MySQL.update.await(
                "UPDATE `pickle_restaurant_recipes` SET `method` = ? WHERE `input_item` = ?", { r.method or "grill", r.input })
        end
    end

    -- Per-recipe output yield (a fry basket holds a batch). Added in place for
    -- servers that predate the column; the default values are backfilled once in
    -- SeedRecipes (gated by the output_count_seeded flag).
    local ycol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_recipes` LIKE 'output_count'")
    if not ycol or #ycol == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_recipes` ADD COLUMN `output_count` SMALLINT UNSIGNED NOT NULL DEFAULT 1")
    end

    -- Optional per-recipe container prop (cake tin, cookie tray…). Added in place
    -- for servers that predate the column; the cake default is backfilled once in
    -- SeedRecipes (gated by the cake_models_seeded flag).
    local ccol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_recipes` LIKE 'container_model'")
    if not ccol or #ccol == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_recipes` ADD COLUMN `container_model` VARCHAR(80) DEFAULT NULL")
    end

    -- The cooked-items tray's `cheese` column was originally TINYINT(1). oxmysql
    -- boolean-casts TINYINT(1) columns, which silently destroys the melted state
    -- (cheese = 2) on read-back, so a melted patty came back with no cheese after a
    -- restart. Widen it so all three states (0/1/2) round-trip. The stored 2s are
    -- intact in the DB, so this recovers them. Runs only while the column is narrow.
    local cheeseCol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_cooked_items` LIKE 'cheese'")
    if cheeseCol and cheeseCol[1] and tostring(cheeseCol[1].Type):find("tinyint%(1%)") then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_cooked_items` MODIFY COLUMN `cheese` TINYINT UNSIGNED NOT NULL DEFAULT 0")
    end

    -- Add the per-instance build-stack metadata column on servers that predate it.
    local metaCol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_cooked_items` LIKE 'metadata'")
    if not metaCol or #metaCol == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_cooked_items` ADD COLUMN `metadata` JSON DEFAULT NULL")
    end
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
    mergeListDefaults("finishes", "tool")

    -- Same idea for the item->model map: add any newly-defaulted entries without
    -- overwriting models an admin remapped.
    local function mergeMapDefaults(key)
        local map = SettingsCache[key]
        if type(map) ~= "table" then return end
        local changed = false
        for k, v in pairs(DEFAULT_SETTINGS[key] or {}) do
            if map[k] == nil then map[k] = v; changed = true end
        end
        if changed then SetSetting(key, map) end
    end
    mergeMapDefaults("prep_models")

    -- One-time: the soda machine grew per-tap flavors; the original single default
    -- drink ("Soda") becomes the Classic Cola tap. Only relabels an entry still
    -- holding the old default label verbatim — an admin-renamed drink is theirs.
    -- (The 5 new flavor entries themselves arrive via mergeListDefaults above.)
    if not GetSetting("soda_flavors_seeded", false) then
        local dr = SettingsCache.drinks
        if type(dr) == "table" then
            local changed = false
            for _, d in ipairs(dr) do
                if d.output == "soda" and d.label == "Soda" then d.label = "Classic Cola"; changed = true end
            end
            if changed then SetSetting("drinks", dr) end
        end
        SetSetting("soda_flavors_seeded", true)
    end

    -- One-time: tap order matters now (tap N = the Nth `drinks` entry, and the
    -- fountain model's printed flavor strip reads water/lemonade/cola/ICE/diet/
    -- grape/coffee). Move the six default flavors into their printed positions —
    -- legacy DBs have the old lone "soda" first — keeping any admin-added drinks
    -- after them in their existing order. Entries are moved, never modified.
    if not GetSetting("soda_tap_order_seeded", false) then
        local dr = SettingsCache.drinks
        if type(dr) == "table" and #dr > 1 then
            local wantOrder = {}
            for i, d in ipairs(DEFAULT_SETTINGS.drinks) do wantOrder[d.output] = i end
            local defaults, extras = {}, {}
            for _, d in ipairs(dr) do
                if wantOrder[d.output] then defaults[#defaults + 1] = d else extras[#extras + 1] = d end
            end
            table.sort(defaults, function(a, b) return wantOrder[a.output] < wantOrder[b.output] end)
            for _, d in ipairs(extras) do defaults[#defaults + 1] = d end
            SetSetting("drinks", defaults)
        end
        SetSetting("soda_tap_order_seeded", true)
    end

    -- One-time: stamp the default pour colors onto the seeded flavors that predate
    -- the per-drink `color` field (matched by output; an admin-set color is left
    -- alone). The client also has a fallback palette, so this is belt-and-suspenders.
    if not GetSetting("soda_colors_seeded", false) then
        local dr = SettingsCache.drinks
        if type(dr) == "table" then
            local want = {}
            for _, d in ipairs(DEFAULT_SETTINGS.drinks) do want[d.output] = d.color end
            local changed = false
            for _, d in ipairs(dr) do
                if d.color == nil and want[d.output] then d.color = want[d.output]; changed = true end
            end
            if changed then SetSetting("drinks", dr) end
        end
        SetSetting("soda_colors_seeded", true)
    end

    -- One-time: pepperoni became an optional topping rather than a required pizza
    -- component. The merges above never edit an existing recipe, so drop pepperoni
    -- from the stored raw_pizza on servers seeded before this change (gated so it
    -- runs once and never re-adds it if an admin later removes/keeps it themselves).
    if not GetSetting("pizza_pepperoni_optional", false) then
        local asm = SettingsCache.assembly
        if type(asm) == "table" then
            local changed = false
            for _, a in ipairs(asm) do
                if a.output == "raw_pizza" and type(a.components) == "table" then
                    local kept = {}
                    for _, c in ipairs(a.components) do
                        if c == "pepperoni" then changed = true else kept[#kept + 1] = c end
                    end
                    a.components = kept
                end
            end
            if changed then SetSetting("assembly", asm) end
        end
        SetSetting("pizza_pepperoni_optional", true)
    end
end

local function SeedRecipes()
    -- Insert any default recipe that isn't present yet (keyed by the unique
    -- input_item). This means newly-added defaults show up on the next restart
    -- without wiping the table or overwriting recipes an admin has customised.
    for _, r in ipairs(DEFAULT_RECIPES) do
        MySQL.insert.await([[
            INSERT INTO pickle_restaurant_recipes
                (input_item, station, raw_model, cooked_model, burnt_model, output_cooked_item, output_burnt_item, cook_ms, burn_ms, dual_sided, method, output_count, container_model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE input_item = input_item
        ]], { r.input, r.station, r.raw, r.cooked, r.burnt, r.out_cooked, r.out_burnt, r.cook_ms, r.burn_ms, r.dual_sided or 0, r.method or "grill", r.output_count or 1, r.container })
    end

    -- One-time: turn dual_sided on for the default dual recipes (e.g. beef
    -- patties) on servers that predate the feature. Gated by a settings flag so
    -- it runs exactly once even if the column already existed (and so it never
    -- clobbers a later admin choice). The ON DUPLICATE above never updates
    -- dual_sided on rows that already exist, so this is the only thing that sets
    -- it for pre-existing recipes.
    if not GetSetting("dual_sided_seeded", false) then
        for _, r in ipairs(DEFAULT_RECIPES) do
            if r.dual_sided == 1 then
                MySQL.update.await(
                    "UPDATE pickle_restaurant_recipes SET dual_sided = 1 WHERE input_item = ?", { r.input })
            end
        end
        SetSetting("dual_sided_seeded", true)
    end

    -- Same idea for `method`: backfill the default recipes' cook method once (oven
    -- for cookie/cake/pizza, fry for the fryer items, grill for patties) so a server
    -- that predates the column gets the new UX without hand-tagging every recipe.
    if not GetSetting("method_seeded", false) then
        for _, r in ipairs(DEFAULT_RECIPES) do
            MySQL.update.await(
                "UPDATE pickle_restaurant_recipes SET method = ? WHERE input_item = ?", { r.method or "grill", r.input })
        end
        SetSetting("method_seeded", true)
    end

    -- And for `output_count`: backfill the fryer batch yields (fries/drumsticks 4,
    -- nuggets 20) once, so existing servers get servings without re-entering recipes.
    if not GetSetting("output_count_seeded", false) then
        for _, r in ipairs(DEFAULT_RECIPES) do
            if (r.output_count or 1) > 1 then
                MySQL.update.await(
                    "UPDATE pickle_restaurant_recipes SET output_count = ? WHERE input_item = ?", { r.output_count, r.input })
            end
        end
        SetSetting("output_count_seeded", true)
    end

    -- One-time: the original seed wrongly used the four flavored whole cakes
    -- (pickle_cake_01..03) as the cake batter's cook models. Repoint the stored
    -- recipe at the batter-sheet models + container tray — but ONLY while it still
    -- holds the old defaults verbatim (an admin who edited any of the three models
    -- owns the row now; they can set container_model in the recipe editor).
    if not GetSetting("cake_models_seeded", false) then
        MySQL.update.await([[
            UPDATE pickle_restaurant_recipes
               SET raw_model = ?, cooked_model = ?, burnt_model = ?, container_model = ?
             WHERE input_item = 'raw_cake'
               AND raw_model = 'pickle_cake_01' AND cooked_model = 'pickle_cake_02' AND burnt_model = 'pickle_cake_03'
        ]], { "pickle_cake_mix_pour_02", "pickle_cake_mix_pour_03", "pickle_cake_mix_pour_04", "pickle_cake_container_01" })
        SetSetting("cake_models_seeded", true)
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

-- Cheese state on a cooked item: 0 = none, 1 = applied (unmelted), 2 = melted. Kept
-- distinct through the tray + DB so a collected burger renders at the melt state it
-- was in; anything > 0 counts as "has cheese" for recipe matching.
function CheeseVal(v) return tonumber(v) or (v == true and 1) or 0 end

local function LoadCookedItems()
    TrayCache = {}
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurant_cooked_items") or {}
    for _, row in ipairs(rows) do
        if (row.count or 0) > 0 then
            local cheese = CheeseVal(row.cheese)
            TrayCache[row.restaurant_id] = TrayCache[row.restaurant_id] or {}
            TrayCache[row.restaurant_id][row.identifier] = TrayCache[row.restaurant_id][row.identifier] or {}
            TrayCache[row.restaurant_id][row.identifier][row.item .. "|" .. cheese] =
                { item = row.item, cheese = cheese, count = row.count, metas = dec(row.metadata, {}) }
        end
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
    -- Prefer the bridge's live lookup so we never validate against a stale
    -- startup snapshot of the inventory catalogue (an item registered after this
    -- resource booted must still be recognised).
    if Inventory and Inventory.ItemExists then return Inventory.ItemExists(name) end
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
        list[#list + 1] = {
            name  = name,
            label = (type(data) == "table" and data.label) or name,
            image = (type(data) == "table" and data.image) or nil,
        }
    end
    table.sort(list, function(a, b) return (a.label or a.name):lower() < (b.label or b.name):lower() end)
    return list
end

-- The inventory image url for an item (nil when unknown / no catalogue yet).
function GetItemImage(name)
    local items = Inventory and Inventory.Items
    local data = items and (items[name] or items[toupper(name)])
    return (type(data) == "table" and data.image) or nil
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

-- How a recipe is cooked: "grill" (cooktop surface), "oven" (inside a door), or
-- "fry" (fryer basket). Defaults to grill for legacy/untagged rows.
function RecipeMethod(r) return (r and r.method) or "grill" end

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

function AnnotateFinishes()
    local out = {}
    for _, f in ipairs(GetSetting("finishes", {})) do
        local missing = {}
        if not ItemExists(f.tool) then missing[#missing + 1] = f.tool end
        for _, t in ipairs(f.targets or {}) do
            if not ItemExists(t.item) then missing[#missing + 1] = t.item end
            if not ItemExists(t.output) then missing[#missing + 1] = t.output end
        end
        local copy = {}; for k, v in pairs(f) do copy[k] = v end
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

-- ─── cooked-items tray (per-player, per-restaurant) ──────────────────────────

local function trayKey(item, cheese) return item .. "|" .. CheeseVal(cheese) end

-- Canonical signature of one instance's build stack: its ordered layers as
-- "item|cheese|half" joined with ",". "" = no recorded stack (a plain instance).
-- Two builds of the same item with different stacks (e.g. a pizza with and without
-- pepperoni) get different signatures, so the tray can tell the variations apart
-- instead of merging them into one count and popping the wrong one on removal.
function TraySig(meta)
    if type(meta) ~= "table" or #meta == 0 then return "" end
    local parts = {}
    for _, l in ipairs(meta) do
        -- tolerate the older aggregated `count` layer format
        for _ = 1, (tonumber(l.count) or 1) do
            local part = tostring(l.item) .. "|" .. CheeseVal(l.cheese) .. "|" .. tostring(l.half or "")
            -- a layer that is itself a product carries its own nested build stack
            -- (a burger holding a pepperoni pizza ≠ one holding a plain pizza)
            if type(l.stack) == "table" and #l.stack > 0 then
                part = part .. "{" .. TraySig(l.stack) .. "}"
            end
            -- a finished (frosted…) layer carries its flavor: a strawberry cake and
            -- a chocolate one are different variations of the same output item
            if l.flavor ~= nil then
                part = part .. "#" .. tostring(l.flavor)
            end
            -- a meal layer carries its tray offset: the same items in a different
            -- arrangement are a different meal (offsets are quantized to 1cm at
            -- make time, so the format is stable through the JSON round trip)
            if l.dx ~= nil or l.dy ~= nil then
                part = part .. ("@%.2f,%.2f"):format(tonumber(l.dx) or 0.0, tonumber(l.dy) or 0.0)
            end
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, ",")
end

-- Signature of the i-th counted instance. `metas` can be shorter than `count`
-- (legacy rows persisted before per-instance stacks); the tail is plain ("").
local function traySigAt(e, i)
    local m = e.metas and e.metas[i]
    if type(m) ~= "table" then return "" end
    return TraySig(m)
end

-- `sig` (optional, here and below): address only the instances whose build stack
-- matches that signature. nil = any instance (the legacy LIFO behaviour).
function GetTrayCount(rid, identifier, item, cheese, sig)
    local e = TrayCache[rid] and TrayCache[rid][identifier] and TrayCache[rid][identifier][trayKey(item, cheese)]
    if not e then return 0 end
    if sig == nil then return e.count or 0 end
    local n = 0
    for i = 1, e.count or 0 do
        if traySigAt(e, i) == sig then n = n + 1 end
    end
    return n
end

-- The build stack of the most-recently-added (matching) instance of a tray entry,
-- or nil for a plain/legacy instance with no recorded stack. `metas` holds one
-- entry per counted item (a stack table, or false when that instance wasn't
-- assembled from parts).
function TrayTopMeta(rid, identifier, item, cheese, sig)
    local e = TrayCache[rid] and TrayCache[rid][identifier] and TrayCache[rid][identifier][trayKey(item, cheese)]
    if not e then return nil end
    for i = e.count or 0, 1, -1 do
        if sig == nil or traySigAt(e, i) == sig then
            local m = e.metas and e.metas[i]
            return (type(m) == "table") and m or nil
        end
    end
    return nil
end

-- `meta` (optional) is this add's build stack, stored per-instance so an assembled
-- product can later be taken back apart into exactly what went into it.
function AddTray(rid, identifier, item, cheese, count, meta)
    if not rid or not identifier or not item then return end
    cheese = CheeseVal(cheese)
    count = count or 1
    TrayCache[rid] = TrayCache[rid] or {}
    TrayCache[rid][identifier] = TrayCache[rid][identifier] or {}
    local key = trayKey(item, cheese)
    local e = TrayCache[rid][identifier][key]
    if not e then
        e = { item = item, cheese = cheese, count = 0, metas = {} }
        TrayCache[rid][identifier][key] = e
    end
    e.metas = e.metas or {}
    e.count = e.count + count
    for _ = 1, count do e.metas[#e.metas + 1] = meta or false end
    MySQL.update("INSERT INTO pickle_restaurant_cooked_items (restaurant_id, identifier, item, cheese, count, metadata) "
        .. "VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE count = count + VALUES(count), metadata = VALUES(metadata)",
        { rid, identifier, item, cheese, count, json.encode(e.metas) })
end

function RemoveTray(rid, identifier, item, cheese, count, sig)
    cheese = CheeseVal(cheese)
    count = count or 1
    if GetTrayCount(rid, identifier, item, cheese, sig) < count then return false end
    local key = trayKey(item, cheese)
    local e = TrayCache[rid][identifier][key]
    e.metas = e.metas or {}
    -- Drop the newest matching instances alongside the count (LIFO, matching
    -- TrayTopMeta). An instance past #metas is plain (""), so removing it only
    -- decrements the count — it must never pop another instance's stack.
    for _ = 1, count do
        local idx
        for i = e.count, 1, -1 do
            if sig == nil or traySigAt(e, i) == sig then idx = i; break end
        end
        if idx and idx <= #e.metas then table.remove(e.metas, idx) end
        e.count = e.count - 1
    end
    if e.count <= 0 then
        TrayCache[rid][identifier][key] = nil
        MySQL.update("DELETE FROM pickle_restaurant_cooked_items WHERE restaurant_id = ? AND identifier = ? AND item = ? AND cheese = ?",
            { rid, identifier, item, cheese })
    else
        MySQL.update("UPDATE pickle_restaurant_cooked_items SET count = count - ?, metadata = ? WHERE restaurant_id = ? AND identifier = ? AND item = ? AND cheese = ?",
            { count, json.encode(e.metas), rid, identifier, item, cheese })
    end
    return true
end

-- A display list for the NUI: resolves label/image and a cheese flag. Instances
-- with different build stacks are split into separate entries (a pepperoni pizza
-- is not the same thing as a plain one), each carrying its `sig` so every drag /
-- consume can address exactly that variation, plus its `meta` (one instance's
-- stack) for stack rendering and descriptions.
function GetTray(rid, identifier)
    local out = {}
    local byKey = TrayCache[rid] and TrayCache[rid][identifier]
    if not byKey then return out end
    for _, e in pairs(byKey) do
        if e.count > 0 then
            local groups, order = {}, {}
            for i = 1, e.count do
                local s = traySigAt(e, i)
                if not groups[s] then
                    local m = e.metas and e.metas[i]
                    groups[s] = { count = 0, meta = (type(m) == "table") and m or nil }
                    order[#order + 1] = s
                end
                groups[s].count = groups[s].count + 1
            end
            for _, s in ipairs(order) do
                out[#out + 1] = {
                    item = e.item, cheese = e.cheese, count = groups[s].count,
                    sig = s, meta = groups[s].meta,
                    label = GetItemLabel(e.item), image = GetItemImage(e.item),
                }
            end
        end
    end
    return out
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
        -- brand image URLs (drive the runtime texture replacement on packaging props):
        -- `brand_image` is the shared default; `brand_images` holds per-texture
        -- overrides keyed by the rendertarget target key (pizza_box, cup, tray, side).
        brand_image  = r.metadata and r.metadata.brand_image or nil,
        brand_images = r.metadata and r.metadata.brand_images or nil,
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
    for i, d in ipairs(GetSetting("drinks", {})) do
        if ItemExists(d.input) and ItemExists(d.output) then
            -- `tap` = the entry's RAW config position: the fountain tap it holds
            -- (first six only). Stamped on a copy so the cached setting row never
            -- carries the derived field back into the DB.
            local copy = {}
            for k, v in pairs(d) do copy[k] = v end
            copy.tap = (i <= 6) and i or nil
            drinks[#drinks + 1] = copy
        end
    end
    local assembly = {}
    for _, a in ipairs(GetSetting("assembly", {})) do
        local ok = ItemExists(a.output)
        for _, comp in ipairs(a.components or {}) do if not ItemExists(comp) then ok = false end end
        if ok then assembly[#assembly + 1] = a end
    end
    -- Finish tools ship with only their valid targets (tool + target + output items
    -- must all exist); an entry with no surviving targets is dropped entirely.
    local finishes = {}
    for _, f in ipairs(GetSetting("finishes", {})) do
        if ItemExists(f.tool) then
            local targets = {}
            for _, t in ipairs(f.targets or {}) do
                if ItemExists(t.item) and ItemExists(t.output) then targets[#targets + 1] = t end
            end
            if #targets > 0 then
                local copy = {}; for k, v in pairs(f) do copy[k] = v end
                copy.targets = targets
                finishes[#finishes + 1] = copy
            end
        end
    end

    local payload = { restaurants = {}, props = {}, recipes = recipes, settings = {
        drinks   = drinks,
        assembly = assembly,
        finishes = finishes,
    } }
    for _, r in pairs(RestaurantCache) do payload.restaurants[#payload.restaurants + 1] = BuildClientRestaurant(r) end
    for _, p in pairs(PropCache) do payload.props[#payload.props + 1] = p end
    return payload
end

function SyncToClient(target)
    TriggerClientEvent("pickle_restaurants:sync", target, BuildSyncPayload())
end

RegisterNetEvent("pickle_restaurants:requestSync", function()
    -- Rebuild the catalogue from the live inventory first, so newly-registered
    -- items reach the client picker (and validation) without a resource restart.
    if Inventory and Inventory.RefreshItems then Inventory.RefreshItems() end
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
        LoadCookedItems()
        RestaurantsReady = true
        debugPrint(("Booted: %d restaurants, %d props, %d recipes."):format(
            #BuildSyncPayload().restaurants, #BuildSyncPayload().props, #RecipeCache))
        -- Push to anyone already connected (resource restart mid-session).
        SyncToClient(-1)
    end)
end)
