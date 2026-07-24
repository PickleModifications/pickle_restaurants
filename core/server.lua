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
RecipeByOutput  = {}    -- [output_cooked_item] = recipe (reverse map for cost tracing)
EmployeeCache   = {}    -- [restaurantId][identifier] = employee row
StockCache      = {}    -- [restaurantId][item] = count
TrayCache       = {}    -- [restaurantId][identifier][item] = { item, count, metas } (metas: one build stack — or false — per counted instance; TraySig(meta) addresses a variation)
SettingsCache   = {}    -- [key]           = decoded value
OrderCache      = {}    -- [restaurantId][orderId] = open POS ticket row (lines decoded)
NextTicket      = {}    -- [restaurantId]  = next kitchen ticket number
ComboCache      = {}    -- [restaurantId][comboId] = combo-meal row (slots/photo_crop decoded)
OrdersDirty     = {}    -- [restaurantId]  = true when the pool changed → register needs a live SyncOrders (coalesced flusher in modules/sales)
PendingRefunds  = {}    -- [rowId]         = unpaid refund owed to an OFFLINE customer (see RefundOrder / the settle thread)

PERMISSIONS = { "cook", "sell", "manage_menu", "manage_props", "manage_employees", "view_finances", "manage_balance", "manage_stock" }
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
    -- The admin panel's OWN NUI theme (skins /restaurants itself — distinct from
    -- any restaurant's franchise theme). Same seed shape as a restaurant theme:
    -- { primary #rrggbb, mode dark|paper, radius sharp|soft|round }. Edited in
    -- Settings → Appearance; the whole palette is derived from it on the client.
    app_theme       = { primary = "#ff7a2e", mode = "dark", radius = "soft" },
    -- The companion phone app's theme (ONE global look for every player's phone —
    -- NOT per-restaurant; the phone deliberately keeps a single consistent skin so it
    -- reads like a real delivery app rather than reskinning per storefront). Same seed
    -- shape as app_theme; edited in Settings → Appearance, derived on the client.
    phone_theme     = { primary = "#ff7a2e", mode = "dark", radius = "round" },
    currency        = "money",
    starting_balance = 0,
    default_commission = 10,
    -- Menu pricing. A sellable's DEFAULT price is what its ingredients cost the
    -- restaurant to buy (see ingredient_costs) marked up by this profit margin.
    -- A boss can still override any price per-restaurant; an unset price falls
    -- back to this computed default so items are orderable out of the box.
    profit_margin   = 40, -- percent added on top of ingredient cost
    -- What each raw ingredient costs the restaurant to buy from the Supplies tab.
    -- Drives both restocking (money out of the restaurant balance) and the
    -- computed default menu price. Keyed by raw item; anything not listed costs 0
    -- (a product made only from unpriced ingredients defaults to $0 = not
    -- auto-orderable until the boss prices it). Admin-editable in the panel.
    ingredient_costs = {
        raw_drumstick = 4, raw_fries = 2, raw_nuggets = 3,
        raw_beef_patty = 5, raw_chicken_patty = 5,
        raw_doughnut = 2,
        -- raw_cake / raw_cookie are no longer bought directly: they're produced by
        -- rubbing `baking_mix` (below) into a cake tin / cookie tray. Their menu-price
        -- cost traces through the mix in ResolveItemCost.
        baking_mix = 4,
        pizza_dough = 3, pizza_sauce = 1, pizza_cheese = 2, pepperoni = 2,
        bun = 1, cheese = 1, lettuce = 1, tomato = 1, pickle = 1,
        empty_cup = 1, frosting = 2, sprinkles = 1,
        ketchup = 2, mustard = 2, mayo = 2,
    },
    -- Fallback melt duration for a melting topping whose ingredient entry has no
    -- melt_ms of its own (the seeded cheese carries 8000 directly; this survives
    -- for configs written before per-ingredient melts).
    cheese_melt_ms  = 8000,
    -- Decodes tray/inventory metadata written BEFORE toppings were generic: a bare
    -- numeric `cheese` field on a layer/row is resolved to this ingredient. Seed
    -- data only — gameplay code never names the item itself.
    -- Manual per-model stacking corrections applied on top of the measured model
    -- heights (client cooking render). sink = shift a layer's seat (negative sinks
    -- it into the layer below, dragging everything above it along); rise = REPLACE
    -- the measured layer height. Synced to the client; TUNE IN-GAME.
    stack_tweaks = {
        -- the shredded-cheese sheet reads a touch high over the sauce on a pizza
        ["pickle_pizza_sauce_01"]  = { sink = -0.004 },
        ["pickle_pizza_cheese_01"] = { sink = -0.004 },
        ["pickle_pizza_cheese_02"] = { sink = -0.004 },
        ["pickle_patty_beef_02"] = { sink = -1.0 },
    },
    -- Global default freshness window (seconds) for collected cooked items in the
    -- tray before they spoil and are swept. Default 900 = 15 minutes; 0 = never
    -- expire. A recipe's own `expire_seconds` overrides this per item (NULL on a
    -- recipe = use this default).
    cooked_expire_seconds = 900,
    -- The inventory item a serving-tray arrangement becomes at kitchen prep. The
    -- meal's metadata records every item WITH its position on the tray, so it
    -- re-renders 1:1 wherever it's set back down. This is a HANDOUT item (shipped in
    -- the install/ folder) — never a requirement to use the tray; only moving a
    -- meal into the real inventory needs it installed.
    meal_item       = "meal",
    -- The inventory item EVERY poured drink becomes ("Restaurant Drink") — one
    -- item for all flavors, the flavor riding as build-stack metadata (a layer
    -- holding the drinks[].output key), exactly like the meal item. The per-flavor
    -- `output` keys are NOT items; only this one ships in the install/ folder.
    drink_item      = "drink",
    -- The inventory item a paying customer receives when a POS order is rung up —
    -- its slot metadata carries the order id/ticket so completion can verify the
    -- holder. Like meal_item it's a HANDOUT item (shipped in install/); if the item
    -- isn't installed the POS still works, just without a physical receipt.
    receipt_item    = "receipt",
    -- The inventory item EVERY crafted "Restaurant Bag" becomes — one item for
    -- all crafts, the craft identity (`id`) + its component layers riding as
    -- build-stack metadata, exactly like meal_item/drink_item. `bag_model` is the
    -- vessel prop dropped on the prep table (kitchen equipment, never an item) and
    -- the model a finished/held bag renders as. Crafts are code-less combine
    -- recipes (soup, salad…): drop the components into the bag, bag it up, get one
    -- restaurant_bag. Component prop models are OPTIONAL — a component with no
    -- model (via prep_models/itemModel) shows the NUI pill instead of a 3D prop.
    bag_item        = "restaurant_bag",
    bag_model       = "pickle_restaurant_bag_01",
    blip            = { sprite = 93, color = 1, scale = 0.8, enabled = true },
    default_roles   = {
        ["0"] = { label = "Trainee", commission = 5,  permissions = { cook = true } },
        ["1"] = { label = "Cook",    commission = 10, permissions = { cook = true, sell = true } },
        ["2"] = { label = "Manager", commission = 15, permissions = {
            cook = true, sell = true, manage_menu = true, manage_props = true,
            manage_employees = true, view_finances = true, manage_stock = true,
        } },
    },
    -- The lid pressed onto a filled cup before it can be collected — kitchen
    -- equipment like the serving tray (no inventory item; cups come with lids),
    -- only its world model is configurable.
    drink_lid_model = "pickle_drink_lid_01",
    -- Sides (fries…) are served IN a container box — kitchen equipment like the drink
    -- lid (no inventory item; visual-only). `side_container_model` is the box prop;
    -- `side_container_items` lists the collected item(s) rendered inside it. The box
    -- prepends to the item's build stack, so a served side shows box + food as ONE
    -- unit everywhere (bar, dragged, placed, meal layer) — never a bare loose serving.
    -- Add nuggets (cooked_nuggets/burnt_nuggets) here to box them too.
    side_container_model = "pickle_side_container_01",
    side_container_items = { "cooked_fries", "burnt_fries" },
    soda_ice_ms     = 1500, -- how long the middle (ice) nozzle takes to dispense
    -- NPC customers. AI customers walk up to a restaurant's counter, queue, place a
    -- REAL POS ticket (a random pick off the restaurant's priced menu), wait for staff
    -- to cook + serve them at the register, pay into the balance, and walk away — a
    -- living stream of business for a manned restaurant. Edited in the admin panel's
    -- Customers tab (a single map setting like blip/prep_models). modules/npc_customers
    -- reads it through NpcConfig() which clamps every value, so a bad NUI write can
    -- never break the world (the "validate on read" pattern drinks/finishes use).
    npc_customers = {
        enabled          = true,   -- master on/off for the whole system
        require_staff    = true,   -- only spawn while a sell/cook player is near the counter
        staff_radius     = 30.0,   -- how near a staff member must be to count as present
        spawn_interval   = 45,     -- seconds between spawn attempts per restaurant
        max_queue        = 4,      -- concurrent NPC customers per restaurant
        patience_seconds = 300,    -- how long an NPC waits before leaving unserved (5 min)
        min_items        = 1,      -- fewest line items an NPC orders
        max_items        = 2,      -- most line items an NPC orders
        tip_chance       = 25,     -- % of served orders that leave a tip
        tip_max_percent  = 15,     -- tip is 0..this% of the order total
        counter_offset   = 1.0,    -- front NPC's distance in front of the counter (TUNE IN-GAME)
        queue_spacing    = 0.85,   -- lateral gap between queued NPCs (TUNE IN-GAME)
        spawn_distance   = 6.0,    -- how far back NPCs appear before walking up (TUNE IN-GAME)
        -- Ped models an NPC customer may spawn as (picked at random, server-authoritative).
        models = { "a_m_y_business_01", "a_f_y_business_02", "a_m_m_business_01",
                   "a_f_y_hipster_02", "a_m_y_hipster_01", "a_f_m_business_02" },
    },
}


-- ─── unified menu seed data (foods / tools / ingredients) ─────────────────────
-- THE creation system. Everything the resource ships is expressed here as plain
-- config — no food has bespoke gameplay code. Three kinds:
--   • FOOD ("New Recipe"): a sellable, made either as an interactive experience
--     (ordered `steps`: assemble at prep / cook at a station / pour at the
--     fountain — a multi-step food like pizza is ONE entry) or as a combinable
--     `kind = "bag"` (components dropped into the Restaurant Bag; `display_item`'s
--     label+image ride the bag's slot metadata so it reads as the food itself).
--   • TOOL ("New Tool"): a quantity-based item applied over food. `mode` picks the
--     gesture/effect: "layer" squeezes its `applied_model` onto a build stack
--     (condiments), "decorate" rubs over a finished product (frosting targets +
--     flavors), "fill" rubs into a free bake tray to produce an oven-ready input.
--   • INGREDIENT ("New Ingredient"): a stackable component (item + prep prop +
--     behavior properties): `halves` = renders/splits as top+bottom half props,
--     each worth 0.5 units; `melts` = can be dropped onto a cooking dual-sided
--     item and melts applied_model → melted_model; `box_base` = a build whose
--     bottom layer is (or derives from) this ingredient fits the pizza box.
-- Seeded once and merged idempotently by id/item — admin edits are never
-- clobbered; deleting a default re-seeds on restart (matching legacy behavior).

DEFAULT_INGREDIENTS = {
    { item = "bun", model = "pickle_bread_bun_01",
      halves = { top_model = "pickle_bread_bun_01", bottom_model = "pickle_bread_bun_02" } },
    { item = "cheese", model = "pickle_cheese_applied_01",
      melts = { applied_model = "pickle_cheese_applied_01", melted_model = "pickle_cheese_applied_02", melt_ms = 8000 } },
    { item = "lettuce", model = "pickle_lettuce_applied_01" },
    { item = "tomato",  model = "pickle_tomato_applied_01" },
    { item = "pickle",  model = "pickle_pickle_applied_01" },
    { item = "pizza_dough",  model = "pickle_pizza_dough_01", box_base = true },
    { item = "pizza_sauce",  model = "pickle_pizza_sauce_01" },
    { item = "pizza_cheese", model = "pickle_pizza_cheese_01" },
    { item = "pepperoni",    model = "pickle_pizza_pepperoni_01" },
}

DEFAULT_TOOLS = {
    { id = "frosting", item = "frosting", tool_model = "pickle_frosting_tube_01",
      mode = "decorate", rub_dist = 1.2, group = "Bakery",
      targets = {
        { item = "cooked_cake", output = "cooked_cake", mode = "replace",
          flavors = {
            { id = "strawberry", label = "Strawberry", model = "pickle_cake_01", color = "#f472b6" },
            { id = "chocolate",  label = "Chocolate",  model = "pickle_cake_02", color = "#8b5a2b" },
            { id = "vanilla",    label = "Vanilla",    model = "pickle_cake_03", color = "#f3e5ab" },
            { id = "pickle",     label = "Pickle",     model = "pickle_cake_04", color = "#65a30d" },
          } },
        { item = "cooked_doughnut", output = "cooked_doughnut", mode = "overlay",
          flavors = {
            { id = "strawberry", label = "Strawberry", model = "pickle_doughnut_topping_01", color = "#f472b6" },
            { id = "chocolate",  label = "Chocolate",  model = "pickle_doughnut_topping_02", color = "#8b5a2b" },
            { id = "glazed",     label = "Glazed",     model = "pickle_doughnut_topping_03", color = "#f0c36d" },
            { id = "vanilla",    label = "Vanilla",    model = "pickle_doughnut_topping_04", color = "#f3e5ab" },
            { id = "pickle",     label = "Pickle",     model = "pickle_doughnut_topping_05", color = "#65a30d" },
          } },
      } },
    { id = "sprinkles", item = "sprinkles", tool_model = "pickle_sprinkles_tube_01",
      mode = "decorate", rub_dist = 1.2, group = "Bakery",
      targets = {
        { item = "cooked_doughnut", output = "cooked_doughnut", mode = "overlay",
          requires_finish = "frosting",
          flavors = {
            { id = "vanilla",   label = "Vanilla",   model = "pickle_doughnut_sprinkles_01", color = "#f3e5ab" },
            { id = "chocolate", label = "Chocolate", model = "pickle_doughnut_sprinkles_02", color = "#8b5a2b" },
          } },
      } },
    { id = "ketchup", item = "ketchup", mode = "layer",
      tool_model = "pickle_ketchup_container_01", applied_model = "pickle_ketchup_applied_01" },
    { id = "mustard", item = "mustard", mode = "layer",
      tool_model = "pickle_mustard_container_01", applied_model = "pickle_mustard_applied_01" },
    { id = "mayo", item = "mayo", mode = "layer",
      tool_model = "pickle_mayo_container_01", applied_model = "pickle_mayo_applied_01" },
    { id = "baking_mix", item = "baking_mix", tool_model = "pickle_cake_mix_01",
      mode = "fill", rub_dist = 1.2, group = "Bakery",
      trays = {
        { kind = "caketin",    label = "Cake Tin",    tray_model = "pickle_cake_container_01",
          output = "raw_cake",   raw_model = "pickle_cake_mix_pour_02", group = "Bakery" },
        { kind = "cookietray", label = "Cookie Tray", tray_model = "pickle_cookie_tray_01",
          output = "raw_cookie", raw_model = "pickle_cookie_01", slots = 6, group = "Bakery" },
      } },
}

DEFAULT_FOODS = {
    -- fryer batches: the basket cooks as a pile (the step's models); each collected
    -- serving is held/stacked as one item (serving_model / serving_burnt_model)
    { id = "cooked_drumstick", label = "Drumsticks", kind = "interactive", group = "Fast Food",
      steps = { { type = "cook", input = "raw_drumstick", station = "fryer", method = "fry",
        raw_model = "pickle_fryer_drumstick_01", cooked_model = "pickle_fryer_drumstick_02", burnt_model = "pickle_fryer_drumstick_03",
        output = "cooked_drumstick", output_burnt = "burnt_drumstick", cook_ms = 15000, burn_ms = 15000,
        output_count = 4, serving_model = "pickle_chicken_drumstick_02", serving_burnt_model = "pickle_chicken_drumstick_03" } } },
    { id = "cooked_fries", label = "Fries", kind = "interactive", group = "Fast Food",
      steps = { { type = "cook", input = "raw_fries", station = "fryer", method = "fry",
        raw_model = "pickle_fryer_fries_01", cooked_model = "pickle_fryer_fries_02", burnt_model = "pickle_fryer_fries_03",
        output = "cooked_fries", output_burnt = "burnt_fries", cook_ms = 12000, burn_ms = 12000,
        output_count = 4, serving_model = "pickle_side_fries_02", serving_burnt_model = "pickle_side_fries_03" } } },
    { id = "cooked_nuggets", label = "Nuggets", kind = "interactive", group = "Fast Food",
      steps = { { type = "cook", input = "raw_nuggets", station = "fryer", method = "fry",
        raw_model = "pickle_fryer_nuggets_01", cooked_model = "pickle_fryer_nuggets_02", burnt_model = "pickle_fryer_nuggets_03",
        output = "cooked_nuggets", output_burnt = "burnt_nuggets", cook_ms = 12000, burn_ms = 12000,
        output_count = 20, serving_model = "pickle_side_nuggets_02", serving_burnt_model = "pickle_side_nuggets_03" } } },
    -- cook-then-assemble: the patty grills dual-sided, then builds into the burger
    -- at kitchen prep. ONE entry — the intermediate patty is implied by the steps.
    { id = "burger", label = "Burger", kind = "interactive", group = "Fast Food",
      steps = {
        { type = "cook", input = "raw_beef_patty", station = "stovetop", method = "grill", dual_sided = 1,
          raw_model = "pickle_patty_beef_01", cooked_model = "pickle_patty_beef_02", burnt_model = "pickle_patty_beef_03",
          output = "cooked_beef_patty", output_burnt = "burnt_beef_patty", cook_ms = 18000, burn_ms = 15000 },
        { type = "assemble", output = "burger", model = "pickle_bread_bun_01",
          components = { "bun", "cooked_beef_patty" } },
      },
      modifiers = {
        { id = "cheese",  label = "Cheese",  item = "cheese",  price = 2 },
        { id = "lettuce", label = "Lettuce", item = "lettuce", price = 0 },
        { id = "tomato",  label = "Tomato",  item = "tomato",  price = 0 },
        { id = "pickle",  label = "Pickle",  item = "pickle",  price = 0 },
      } },
    { id = "chicken_sandwich", label = "Chicken Sandwich", kind = "interactive", group = "Fast Food",
      steps = {
        { type = "cook", input = "raw_chicken_patty", station = "fryer", method = "fry",
          raw_model = "pickle_patty_friedchicken_01", cooked_model = "pickle_patty_friedchicken_02", burnt_model = "pickle_patty_friedchicken_03",
          output = "cooked_chicken_patty", output_burnt = "burnt_chicken_patty", cook_ms = 18000, burn_ms = 15000 },
        { type = "assemble", output = "chicken_sandwich", model = "pickle_bread_bun_01",
          components = { "bun", "cooked_chicken_patty" } },
      },
      modifiers = {
        { id = "cheese",  label = "Cheese",  item = "cheese",  price = 2 },
        { id = "lettuce", label = "Lettuce", item = "lettuce", price = 0 },
        { id = "tomato",  label = "Tomato",  item = "tomato",  price = 0 },
        { id = "pickle",  label = "Pickle",  item = "pickle",  price = 0 },
      } },
    { id = "cooked_doughnut", label = "Doughnut", kind = "interactive", group = "Bakery",
      steps = { { type = "cook", input = "raw_doughnut", station = "fryer", method = "fry",
        raw_model = "pickle_doughnut_01", cooked_model = "pickle_doughnut_02", burnt_model = "pickle_doughnut_03",
        output = "cooked_doughnut", output_burnt = "burnt_doughnut", cook_ms = 12000, burn_ms = 12000 } } },
    -- baked goods: the raw input is produced by the baking-mix FILL tool (see
    -- DEFAULT_TOOLS) rubbed into the matching free tray; the oven bakes it inside
    -- its container prop (visual only, never an item).
    { id = "cooked_cookie", label = "Cookies", kind = "interactive", group = "Bakery",
      steps = { { type = "cook", input = "raw_cookie", station = "stovetop", method = "oven",
        raw_model = "pickle_cookie_01", cooked_model = "pickle_cookie_02", burnt_model = "pickle_cookie_03",
        container_model = "pickle_cookie_tray_01", output_count = 6,
        output = "cooked_cookie", output_burnt = "burnt_cookie", cook_ms = 20000, burn_ms = 18000 } } },
    { id = "cooked_cake", label = "Cake", kind = "interactive", group = "Bakery",
      steps = { { type = "cook", input = "raw_cake", station = "stovetop", method = "oven",
        raw_model = "pickle_cake_mix_pour_02", cooked_model = "pickle_cake_mix_pour_03", burnt_model = "pickle_cake_mix_pour_04",
        container_model = "pickle_cake_container_01",
        output = "cooked_cake", output_burnt = "burnt_cake", cook_ms = 30000, burn_ms = 25000 } } },
    -- assemble-then-cook: the raw pizza is built at kitchen prep (dough + sauce +
    -- cheese sheet; pepperoni is an optional topping alteration) then oven-baked.
    -- ONE entry — `raw_pizza` is a kitchen intermediate, never an installed item.
    { id = "cooked_pizza", label = "Pizza", kind = "interactive", group = "Pizza",
      steps = {
        { type = "assemble", output = "raw_pizza", label = "Pizza (uncooked)", model = "pickle_pizza_dough_01",
          components = { "pizza_dough", "pizza_sauce", "pizza_cheese" } },
        { type = "cook", input = "raw_pizza", station = "stovetop", method = "oven",
          raw_model = "pickle_pizza_dough_01", cooked_model = "pickle_pizza_dough_02", burnt_model = "pickle_pizza_dough_03",
          output = "cooked_pizza", output_burnt = "burnt_pizza", cook_ms = 25000, burn_ms = 20000 },
      } },
    -- poured drinks: one food per fountain flavor. Position among the pour foods =
    -- tap order (first six hold the taps); `flavor` is a KEY, not an item — every
    -- poured drink collects as the ONE `drink_item` item with the flavor as
    -- build-stack metadata. `color` tints the poured liquid stream.
    { id = "water", label = "Pure Aqua", kind = "interactive",
      steps = { { type = "pour", input = "empty_cup", flavor = "water", model = "pickle_drink_container_01", fill_ms = 3000, color = { 160, 205, 230 } } } },
    { id = "lemonade", label = "Lemonade Bliss", kind = "interactive",
      steps = { { type = "pour", input = "empty_cup", flavor = "lemonade", model = "pickle_drink_container_01", fill_ms = 3000, color = { 235, 215, 90 } } } },
    { id = "soda", label = "Classic Cola", kind = "interactive",
      steps = { { type = "pour", input = "empty_cup", flavor = "soda", model = "pickle_drink_container_01", fill_ms = 3000, color = { 90, 50, 25 } } } },
    { id = "diet_cola", label = "Diet Cola", kind = "interactive",
      steps = { { type = "pour", input = "empty_cup", flavor = "diet_cola", model = "pickle_drink_container_01", fill_ms = 3000, color = { 120, 80, 55 } } } },
    { id = "grape_soda", label = "Grape Zap", kind = "interactive",
      steps = { { type = "pour", input = "empty_cup", flavor = "grape_soda", model = "pickle_drink_container_01", fill_ms = 3000, color = { 135, 70, 170 } } } },
    { id = "coffee", label = "Coffee", kind = "interactive",
      steps = { { type = "pour", input = "empty_cup", flavor = "coffee", model = "pickle_drink_container_01", fill_ms = 3000, color = { 80, 50, 30 } } } },
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
            `groups`           JSON         DEFAULT NULL,
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
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_menu` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `item`          VARCHAR(60)  NOT NULL,
            -- drinks are ONE item (`drink_item`) with the flavor as metadata, so
            -- per-flavor pricing needs a variant dimension on the menu key (variant =
            -- the drinks[].output flavor key; '' for everything else). NOT NULL so the
            -- unique key upserts reliably (MySQL treats NULLs in unique keys as distinct).
            `variant`       VARCHAR(60)  NOT NULL DEFAULT '',
            `label`         VARCHAR(100) NOT NULL,
            `price`         INT          NOT NULL DEFAULT 0,
            `category`      VARCHAR(40)  DEFAULT 'food',
            `enabled`       TINYINT(1)   NOT NULL DEFAULT 1,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_item` (`restaurant_id`, `item`, `variant`),
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

    -- Per-player, per-restaurant "Cooked Items" tray: cooked products held between
    -- the grill and the prep station. One row per (restaurant, cook, item); every
    -- build variation (toppings, alterations) lives inside the per-instance metadata.
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_cooked_items` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `identifier`    VARCHAR(80)  NOT NULL,
            `item`          VARCHAR(60)  NOT NULL,
            `count`         INT          NOT NULL DEFAULT 0,
            -- Per-instance build stacks (JSON array, one entry per counted item) so an
            -- assembled product remembers what actually went into it — toppings (a
            -- melting cheese slice), alterations and all — and can be taken back apart
            -- faithfully. Melt state rides each layer's `top` field (config-driven,
            -- from the ingredient's `melts`), never a hardcoded column.
            `metadata`      JSON         DEFAULT NULL,
            -- UNIX seconds the row's items were cooked (freshness clock for expiration);
            -- set when the row is created, preserved as more are stacked onto it.
            `cooked_at`     BIGINT       NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_tray` (`restaurant_id`, `identifier`, `item`),
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

    -- POS kitchen tickets. `lines` snapshots {item, variant, label, price, qty, kind}
    -- at order time so later price/menu edits never change an open ticket. `ticket`
    -- is the per-restaurant kitchen number shown to staff & printed on the receipt.
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_orders` (
            `id`                  INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id`       INT UNSIGNED NOT NULL,
            `ticket`              INT UNSIGNED NOT NULL DEFAULT 1,
            `customer_identifier` VARCHAR(80)  NOT NULL,
            `customer_name`       VARCHAR(100) DEFAULT NULL,
            `cashier_identifier`  VARCHAR(80)  DEFAULT NULL,
            `lines`               JSON         NOT NULL,
            `total`               INT          NOT NULL DEFAULT 0,
            `status`              VARCHAR(12)  NOT NULL DEFAULT 'open',
            `created_at`          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `closed_at`           TIMESTAMP    NULL DEFAULT NULL,
            -- refund bookkeeping. `refunded` is the idempotence flag RefundOrder sets
            -- (cache + DB) before paying out, so no cancel/delete/race pays a ticket
            -- twice. `paid_account` is which wallet was charged ('bank' for phone/card
            -- orders, 'cash' for register + kiosk) so a refund returns to it. `redeemed`
            -- marks a loyalty punch-card redemption burned on this order, handed back on
            -- cancel. (modules/phone's EnsureColumn also guards paid_account — no-ops now.)
            `refunded`            TINYINT UNSIGNED NOT NULL DEFAULT 0,
            `paid_account`        VARCHAR(8)   NOT NULL DEFAULT 'cash',
            `redeemed`            TINYINT UNSIGNED NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`),
            KEY `idx_rest_status` (`restaurant_id`, `status`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])


    -- OFFLINE REFUNDS. A cancellation must never be blocked by (or silently
    -- swallow money because of) the customer being disconnected. When there's no
    -- live source to hand the money to, RefundOrder parks the payout here and the
    -- settle thread pays it the moment that identifier is online again. The UNIQUE
    -- key on order_id is a second, database-level guarantee that one ticket can
    -- never queue two payouts.
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_pending_refunds` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `order_id`      INT          NOT NULL,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `identifier`    VARCHAR(80)  NOT NULL,
            `ticket`        INT UNSIGNED NOT NULL DEFAULT 0,
            `amount`        INT          NOT NULL DEFAULT 0,
            `account`       VARCHAR(8)   NOT NULL DEFAULT 'money',
            `reason`        VARCHAR(64)  DEFAULT NULL,
            `created_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `paid_at`       TIMESTAMP    NULL DEFAULT NULL,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_order` (`order_id`),
            KEY `idx_ident_paid` (`identifier`, `paid_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])


    -- Combo meals: a per-restaurant, numbered, priced BUNDLE of existing sellable
    -- items ("Burger + Fries + Cola = The Pickle Meal #3"), sold as one entry and
    -- fulfilled from the pool as its individual component items. `slots` is the
    -- ordered list of choose-slots (each a list of allowed sellable-catalog keys);
    -- `photo_url`/`photo_crop` reuse the brand-image pipeline for the board card.
    -- Identity is `id`; `number` is a plain sortable display field (NO unique key —
    -- renumbering must never deadlock; the editor warns on duplicates instead).
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_combos` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `number`        INT UNSIGNED NOT NULL DEFAULT 1,
            `label`         VARCHAR(80)  NOT NULL,
            `price`         INT          NOT NULL DEFAULT 0,
            `enabled`       TINYINT(1)   NOT NULL DEFAULT 1,
            `photo_url`     VARCHAR(512) DEFAULT NULL,
            `photo_crop`    JSON         DEFAULT NULL,
            `slots`         JSON         NOT NULL,
            `created_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_rest` (`restaurant_id`)
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

    -- Back-fill any newly-added npc_customers sub-key (a new tunable in a later
    -- release) without clobbering an admin's edits. `models` is a list value inside
    -- the map — this only adds it if the whole key is missing, which is correct (an
    -- admin who edited the list keeps theirs).
    do
        local map = SettingsCache.npc_customers
        if type(map) == "table" then
            local changed = false
            for k, v in pairs(DEFAULT_SETTINGS.npc_customers or {}) do
                if map[k] == nil then map[k] = v; changed = true end
            end
            if changed then SetSetting("npc_customers", map) end
        end
    end
end


-- Reset the whole authored menu (foods / tools / ingredients) to the shipped
-- defaults verbatim (the admin "Reset menu" action). Unlike the boot-time seed
-- merge (which only fills gaps), this deliberately discards customisations.
function ResetMenuToDefault()
    SetSetting("foods", dec(json.encode(DEFAULT_FOODS), {}))
    SetSetting("tools", dec(json.encode(DEFAULT_TOOLS), {}))
    SetSetting("ingredients", dec(json.encode(DEFAULT_INGREDIENTS), {}))
    RebuildDerived()
end


-- ─── unified menu: authored config accessors ─────────────────────────────────
-- The three authored settings arrays (the ONLY authoring surface). Everything the
-- runtime consumes is DERIVED from these by RebuildDerived() below.

function GetFoods()          return GetSetting("foods", {}) end
function GetTools()          return GetSetting("tools", {}) end
function GetIngredientsCfg() return GetSetting("ingredients", {}) end

-- The ingredient entry for `item` (nil when unconfigured). Linear scan — the
-- list is tiny and authored, like findAssembly.
function IngredientDef(item)
    if not item or item == "" then return nil end
    for _, ing in ipairs(GetIngredientsCfg()) do
        if ing.item == item then return ing end
    end
    return nil
end

-- `halves` property: the ingredient renders/splits as two half props (top +
-- bottom), each worth 0.5 stack units (buns).
function IngredientHalves(item)
    local d = IngredientDef(item)
    return d and type(d.halves) == "table" and d.halves or nil
end

-- `melts` property: the ingredient can be dropped onto a cooking dual-sided item
-- and transitions applied_model -> melted_model on its melt timer (cheese).
function MeltingToppingFor(item)
    local d = IngredientDef(item)
    if d and type(d.melts) == "table" and d.melts.applied_model then return d end
    return nil
end

-- The topping riding a build-stack layer (or a cook/tray record), normalized:
-- { item, state = "applied"|"melted" } from the layer's `top` field; nil when the
-- layer carries no topping.
function LayerTopping(l)
    if type(l) ~= "table" then return nil end
    if type(l.top) == "table" and l.top.item then
        return { item = l.top.item, state = (l.top.state == "melted") and "melted" or "applied" }
    end
    return nil
end

-- The prop a topping renders as at its current melt state, from its ingredient's
-- `melts` models. nil when the ingredient is unconfigured (caller falls back).
function ToppingModel(top)
    if type(top) ~= "table" or not top.item then return nil end
    local d = IngredientDef(top.item)
    local m = d and d.melts
    if type(m) ~= "table" then return d and d.model or nil end
    if top.state == "melted" then return m.melted_model or m.applied_model end
    return m.applied_model or d.model
end

-- The melt duration for a topping ingredient (its own melt_ms, else the global
-- fallback setting).
function ToppingMeltMs(item)
    local d = MeltingToppingFor(item)
    local ms = d and d.melts and tonumber(d.melts.melt_ms)
    return ms or tonumber(GetSetting("cheese_melt_ms", 8000)) or 8000
end

-- ─── unified menu: sanitizers ─────────────────────────────────────────────────
-- Applied to every admin save (the NUI is untrusted) and to migration output.
-- Liberal: clamp types and drop structurally-empty entries; validity (missing
-- items / models) is annotation, not rejection — a half-built entry must survive
-- the round trip so it can be finished later.

local function trimStr(v) return (type(v) == "string" and v ~= "") and v or nil end
local function numOr(v, d) local n = tonumber(v); return n ~= nil and n or d end

local function sanitizeModifiers(mods)
    if type(mods) ~= "table" then return nil end
    local out = {}
    for _, m in ipairs(mods) do
        if type(m) == "table" and (trimStr(m.id) or trimStr(m.item) or trimStr(m.label)) then
            out[#out + 1] = {
                id      = trimStr(m.id) or trimStr(m.item) or trimStr(m.label),
                label   = trimStr(m.label) or trimStr(m.item) or trimStr(m.id),
                item    = trimStr(m.item),
                price   = RoundMoney(numOr(m.price, 0)),
                default = m.default == true or nil,
            }
        end
    end
    return #out > 0 and out or nil
end

local function sanitizeComponents(comps)
    local out = {}
    for _, c in ipairs(type(comps) == "table" and comps or {}) do
        if type(c) == "string" and c ~= "" then out[#out + 1] = c end
    end
    return out
end

function SanitizeFoods(list)
    local out, seen = {}, {}
    for _, f in ipairs(type(list) == "table" and list or {}) do
        if type(f) == "table" then
            local food = {
                id    = trimStr(f.id),
                label = trimStr(f.label),
                kind  = (f.kind == "bag") and "bag" or "interactive",
                group = trimStr(f.group),
                modifiers = sanitizeModifiers(f.modifiers),
            }
            if food.kind == "bag" then
                food.components   = sanitizeComponents(f.components)
                food.display_item = trimStr(f.display_item)
                food.id = food.id or food.display_item
            else
                local steps, cooks, pours = {}, 0, 0
                local prevOutput = nil
                for _, st in ipairs(type(f.steps) == "table" and f.steps or {}) do
                    if type(st) == "table" then
                        if st.type == "cook" and cooks == 0 then
                            cooks = cooks + 1
                            local station = (st.station == "fryer") and "fryer" or "stovetop"
                            local method = st.method
                            if station == "fryer" then method = "fry"
                            elseif method ~= "oven" then method = "grill" end
                            steps[#steps + 1] = {
                                type = "cook",
                                input = trimStr(st.input) or prevOutput,
                                station = station, method = method,
                                raw_model = trimStr(st.raw_model), cooked_model = trimStr(st.cooked_model),
                                burnt_model = trimStr(st.burnt_model),
                                output = trimStr(st.output), output_burnt = trimStr(st.output_burnt),
                                cook_ms = math.max(1000, math.floor(numOr(st.cook_ms, 15000))),
                                burn_ms = math.max(1000, math.floor(numOr(st.burn_ms, 15000))),
                                dual_sided = (st.dual_sided == 1 or st.dual_sided == true) and 1 or nil,
                                output_count = math.max(1, math.floor(numOr(st.output_count, 1))),
                                container_model = trimStr(st.container_model),
                                expire_seconds = st.expire_seconds ~= nil and st.expire_seconds ~= ""
                                    and math.max(0, math.floor(numOr(st.expire_seconds, 0))) or nil,
                                serving_model = trimStr(st.serving_model),
                                serving_burnt_model = trimStr(st.serving_burnt_model),
                            }
                            prevOutput = steps[#steps].output or prevOutput
                        elseif st.type == "assemble" then
                            steps[#steps + 1] = {
                                type = "assemble",
                                output = trimStr(st.output),
                                label = trimStr(st.label),
                                model = trimStr(st.model),
                                components = sanitizeComponents(st.components),
                            }
                            prevOutput = steps[#steps].output or prevOutput
                        elseif st.type == "pour" and pours == 0 and #steps == 0 then
                            -- a pour step stands alone (the fountain IS the whole make)
                            pours = pours + 1
                            steps[#steps + 1] = {
                                type = "pour",
                                input = trimStr(st.input),
                                flavor = trimStr(st.flavor),
                                model = trimStr(st.model),
                                fill_ms = math.max(500, math.floor(numOr(st.fill_ms, 3000))),
                                color = (type(st.color) == "table") and {
                                    math.floor(numOr(st.color[1] or st.color.r, 200)),
                                    math.floor(numOr(st.color[2] or st.color.g, 200)),
                                    math.floor(numOr(st.color[3] or st.color.b, 210)),
                                } or nil,
                            }
                            prevOutput = steps[#steps].flavor or prevOutput
                        end
                    end
                end
                food.steps = steps
                -- deterministic identity: the final step's output / flavor (this is
                -- what lets the default merge + migration agree on the same id)
                food.id = food.id or prevOutput
            end
            if food.id and not seen[food.id] then
                seen[food.id] = true
                food.label = food.label or GetItemLabel(food.id)
                out[#out + 1] = food
            end
        end
    end
    return out
end

function SanitizeTools(list)
    local out, seen = {}, {}
    for _, t in ipairs(type(list) == "table" and list or {}) do
        if type(t) == "table" and (trimStr(t.item) or trimStr(t.id)) then
            local mode = (t.mode == "layer" or t.mode == "decorate" or t.mode == "fill") and t.mode or "layer"
            local tool = {
                id = trimStr(t.id) or trimStr(t.item),
                item = trimStr(t.item) or trimStr(t.id),
                tool_model = trimStr(t.tool_model),
                mode = mode,
                group = trimStr(t.group),
            }
            if mode == "layer" then
                tool.applied_model = trimStr(t.applied_model)
            elseif mode == "decorate" then
                tool.rub_dist = math.max(0.1, numOr(t.rub_dist, 1.2))
                local targets = {}
                for _, tg in ipairs(type(t.targets) == "table" and t.targets or {}) do
                    if type(tg) == "table" and trimStr(tg.item) then
                        local flavors = {}
                        for _, fl in ipairs(type(tg.flavors) == "table" and tg.flavors or {}) do
                            if type(fl) == "table" and (trimStr(fl.id) or trimStr(fl.label)) then
                                flavors[#flavors + 1] = {
                                    id = trimStr(fl.id) or trimStr(fl.label),
                                    label = trimStr(fl.label) or trimStr(fl.id),
                                    model = trimStr(fl.model),
                                    color = trimStr(fl.color),
                                }
                            end
                        end
                        targets[#targets + 1] = {
                            item = trimStr(tg.item),
                            output = trimStr(tg.output) or trimStr(tg.item),
                            mode = (tg.mode == "replace") and "replace" or "overlay",
                            requires_finish = trimStr(tg.requires_finish),
                            flavors = flavors,
                        }
                    end
                end
                tool.targets = targets
            elseif mode == "fill" then
                tool.rub_dist = math.max(0.1, numOr(t.rub_dist, 1.2))
                local trays = {}
                for _, tr in ipairs(type(t.trays) == "table" and t.trays or {}) do
                    if type(tr) == "table" and trimStr(tr.kind) then
                        trays[#trays + 1] = {
                            kind = trimStr(tr.kind),
                            label = trimStr(tr.label) or trimStr(tr.kind),
                            tray_model = trimStr(tr.tray_model),
                            output = trimStr(tr.output),
                            raw_model = trimStr(tr.raw_model),
                            slots = tonumber(tr.slots) and math.max(1, math.floor(tonumber(tr.slots))) or nil,
                            group = trimStr(tr.group),
                        }
                    end
                end
                tool.trays = trays
            end
            if not seen[tool.id] then
                seen[tool.id] = true
                out[#out + 1] = tool
            end
        end
    end
    return out
end

function SanitizeIngredients(list)
    local out, seen = {}, {}
    for _, ing in ipairs(type(list) == "table" and list or {}) do
        if type(ing) == "table" and trimStr(ing.item) and not seen[ing.item] then
            seen[ing.item] = true
            local e = {
                item = ing.item,
                model = trimStr(ing.model),
                group = trimStr(ing.group),
                box_base = ing.box_base == true or nil,
                label = trimStr(ing.label),
            }
            if type(ing.halves) == "table" and (trimStr(ing.halves.top_model) or trimStr(ing.halves.bottom_model)) then
                e.halves = { top_model = trimStr(ing.halves.top_model),
                             bottom_model = trimStr(ing.halves.bottom_model) }
            end
            if type(ing.melts) == "table" and trimStr(ing.melts.applied_model) then
                e.melts = { applied_model = trimStr(ing.melts.applied_model),
                            melted_model = trimStr(ing.melts.melted_model) or trimStr(ing.melts.applied_model),
                            melt_ms = tonumber(ing.melts.melt_ms) and math.max(500, math.floor(tonumber(ing.melts.melt_ms))) or nil }
            end
            out[#out + 1] = e
        end
    end
    return out
end

-- ─── unified menu: derivation layer ──────────────────────────────────────────
-- Rebuilds the exact legacy runtime shapes the 5k-line cooking engine / sales /
-- sync consume — RecipeCache rows, assembly/drinks/crafts/finishes/
-- condiments lists, the baking config (now a LIST, one per fill tool) and the
-- item->prep-prop map — from the three authored arrays. Run at boot and after
-- every save of foods/tools/ingredients. Gameplay code never reads the authored
-- arrays directly (except IngredientDef, which IS the authored surface).

DerivedAssembly   = {}
DerivedDrinks     = {}
DerivedCrafts     = {}
DerivedFinishes   = {}
DerivedCondiments = {}
DerivedBaking     = {}
DerivedPrepModels = {}

function GetAssembly()   return DerivedAssembly end
function GetDrinks()     return DerivedDrinks end
function GetCrafts()     return DerivedCrafts end
function GetFinishes()   return DerivedFinishes end
function GetCondiments() return DerivedCondiments end
function GetBakingList() return DerivedBaking end
function GetPrepModels() return DerivedPrepModels end

function RebuildDerived()
    RecipeCache, RecipeByInput, RecipeByOutput = {}, {}, {}
    DerivedAssembly, DerivedDrinks, DerivedCrafts = {}, {}, {}
    DerivedFinishes, DerivedCondiments, DerivedBaking = {}, {}, {}
    DerivedPrepModels = {}

    for _, ing in ipairs(GetIngredientsCfg()) do
        if ing.item and ing.model then DerivedPrepModels[ing.item] = ing.model end
    end

    for _, food in ipairs(GetFoods()) do
        if food.kind == "bag" then
            if food.id then
                DerivedCrafts[#DerivedCrafts + 1] = {
                    id = food.id, label = food.label or food.id, group = food.group,
                    components = food.components or {}, modifiers = food.modifiers,
                    display_item = food.display_item, food_id = food.id,
                }
            end
        else
            local steps = food.steps or {}
            local prevOutput = nil
            for si, st in ipairs(steps) do
                local isLast = (si == #steps)
                if st.type == "cook" then
                    local input = st.input or prevOutput
                    if input and st.output and not RecipeByInput[input] then
                        local row = {
                            id = #RecipeCache + 1,
                            input_item = input,
                            station = st.station or "stovetop",
                            method = st.method or "grill",
                            raw_model = st.raw_model, cooked_model = st.cooked_model,
                            burnt_model = st.burnt_model,
                            output_cooked_item = st.output,
                            output_burnt_item = st.output_burnt or "",
                            cook_ms = tonumber(st.cook_ms) or 15000,
                            burn_ms = tonumber(st.burn_ms) or 15000,
                            dual_sided = (st.dual_sided == 1 or st.dual_sided == true) and 1 or 0,
                            output_count = math.max(1, math.floor(tonumber(st.output_count) or 1)),
                            container_model = st.container_model,
                            expire_seconds = st.expire_seconds,
                            group = food.group,
                            food_id = food.id,
                        }
                        RecipeCache[#RecipeCache + 1] = row
                        RecipeByInput[input] = row
                        RecipeByOutput[st.output] = row
                        if st.serving_model then DerivedPrepModels[st.output] = st.serving_model end
                        if st.serving_burnt_model and st.output_burnt then
                            DerivedPrepModels[st.output_burnt] = st.serving_burnt_model
                        end
                    end
                    prevOutput = st.output or prevOutput
                elseif st.type == "assemble" then
                    if st.output then
                        DerivedAssembly[#DerivedAssembly + 1] = {
                            output = st.output,
                            label = isLast and (food.label or st.output)
                                or (st.label or ((food.label or st.output) .. " (uncooked)")),
                            model = st.model, group = food.group,
                            components = st.components or {},
                            modifiers = isLast and food.modifiers or nil,
                            food_id = food.id,
                        }
                    end
                    prevOutput = st.output or prevOutput
                elseif st.type == "pour" then
                    if st.flavor then
                        DerivedDrinks[#DerivedDrinks + 1] = {
                            input = st.input, output = st.flavor,
                            label = food.label or st.flavor,
                            model = st.model, fill_ms = tonumber(st.fill_ms) or 3000,
                            color = st.color, group = food.group, food_id = food.id,
                        }
                    end
                end
            end
        end
    end

    for _, t in ipairs(GetTools()) do
        if t.mode == "decorate" then
            DerivedFinishes[#DerivedFinishes + 1] = {
                tool = t.item, tool_model = t.tool_model, rub_dist = t.rub_dist,
                group = t.group, targets = t.targets or {}, tool_id = t.id,
            }
        elseif t.mode == "layer" then
            DerivedCondiments[#DerivedCondiments + 1] = {
                item = t.item, container_model = t.tool_model,
                applied_model = t.applied_model, tool_id = t.id,
            }
        elseif t.mode == "fill" then
            DerivedBaking[#DerivedBaking + 1] = {
                mix_item = t.item, mix_model = t.tool_model, rub_dist = t.rub_dist,
                trays = t.trays or {}, group = t.group, tool_id = t.id,
            }
        end
    end
end


-- Idempotent default merge for the three authored arrays: create a missing key
-- outright, else append shipped entries whose id/item isn't present. An admin's
-- customised entry (same id) is never touched; a deleted default re-seeds on
-- restart, matching how the legacy kinds always behaved.
local function SeedUnifiedMenu()
    local function merge(key, defaults, idField)
        local list = GetSetting(key, nil)
        if type(list) ~= "table" then
            SetSetting(key, dec(json.encode(defaults), {}))
            return
        end
        local seen = {}
        for _, e in ipairs(list) do if e[idField] then seen[e[idField]] = true end end
        local changed = false
        for _, def in ipairs(defaults) do
            if not seen[def[idField]] then
                list[#list + 1] = dec(json.encode(def), nil)
                changed = true
            end
        end
        if changed then SetSetting(key, list) end
    end
    merge("foods", DEFAULT_FOODS, "id")
    merge("tools", DEFAULT_TOOLS, "id")
    merge("ingredients", DEFAULT_INGREDIENTS, "item")
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

local function LoadOrders()
    OrderCache, NextTicket = {}, {}
    -- NPC orders are ephemeral: each is tied to a live NPC ped + in-memory queue
    -- (NpcState) that cannot survive a restart. Any still 'open' at boot is orphaned
    -- — no ped, no queue entry — so it can never be fulfilled and just clogs every
    -- register's Tickets widget. Cancel them up front (before loading the cache) so
    -- they're gone on restart. Closed rows still count for ticket numbering below.
    MySQL.update.await(
        "UPDATE pickle_restaurant_orders SET status = 'cancelled', closed_at = NOW() "
        .. "WHERE status = 'open' AND customer_identifier LIKE 'npc:%'")
    -- Only open tickets live in the cache; completed/cancelled rows stay in the DB
    -- as history. Ticket numbering continues from the highest ever issued so a
    -- restart never reuses a number a customer's receipt still shows.
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurant_orders WHERE status = 'open'") or {}
    for _, row in ipairs(rows) do
        row.lines = dec(row.lines, {})
        OrderCache[row.restaurant_id] = OrderCache[row.restaurant_id] or {}
        OrderCache[row.restaurant_id][row.id] = row
    end
    local maxes = MySQL.query.await(
        "SELECT restaurant_id, MAX(ticket) AS t FROM pickle_restaurant_orders GROUP BY restaurant_id") or {}
    for _, m in ipairs(maxes) do
        NextTicket[m.restaurant_id] = (tonumber(m.t) or 0) + 1
    end
end

-- Combo meals into the module-global cache. `slots`/`photo_crop` are JSON columns —
-- decode them once here (like OrderCache's `lines`) so every read is a plain table.
local function LoadCombos()
    ComboCache = {}
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurant_combos") or {}
    for _, row in ipairs(rows) do
        row.slots      = dec(row.slots, {})
        row.photo_crop = dec(row.photo_crop, nil)
        row.enabled    = (row.enabled == 1 or row.enabled == true)
        ComboCache[row.restaurant_id] = ComboCache[row.restaurant_id] or {}
        ComboCache[row.restaurant_id][row.id] = row
    end
end

local function LoadCookedItems()
    TrayCache = {}
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurant_cooked_items") or {}
    for _, row in ipairs(rows) do
        if (row.count or 0) > 0 then
            TrayCache[row.restaurant_id] = TrayCache[row.restaurant_id] or {}
            TrayCache[row.restaurant_id][row.identifier] = TrayCache[row.restaurant_id][row.identifier] or {}
            TrayCache[row.restaurant_id][row.identifier][row.item] =
                { item = row.item, count = row.count, metas = dec(row.metadata, {}),
                  cookedAt = tonumber(row.cooked_at) or 0 }
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
        row.groups   = dec(row.groups, nil)
        row.metadata = dec(row.metadata, {})
        RestaurantCache[row.id] = row
    end
end

function GetRestaurant(id) return RestaurantCache[tonumber(id)] end

-- Counters are placeable props (prop_type "counter") — a restaurant can have as
-- many register anchors as it likes, exactly like stations. The `counter` COLUMN
-- lives on as the single PRIMARY anchor everything else pins to (map blip, kitchen
-- shell XY, NPC queue origin, brand render anchor): it's the LOWEST-id counter
-- prop, recomputed whenever a counter is placed / moved / removed. No counter props
-- → nil (no register interaction, no blip). Returns true if the anchor changed.
function RecomputeCounterAnchor(restaurantId)
    restaurantId = tonumber(restaurantId)
    local r = RestaurantCache[restaurantId]
    if not r then return false end
    local best
    for _, p in pairs(PropCache) do
        if p.restaurant_id == restaurantId and p.prop_type == "counter" and (not best or p.id < best.id) then
            best = p
        end
    end
    local counter = best and { x = best.x + 0.0, y = best.y + 0.0, z = best.z + 0.0, heading = (best.heading or 0.0) + 0.0 } or nil
    local cur = r.counter
    local same = (cur == nil and counter == nil) or (cur ~= nil and counter ~= nil
        and cur.x == counter.x and cur.y == counter.y and cur.z == counter.z and cur.heading == counter.heading)
    if same then return false end
    r.counter = counter
    MySQL.update.await("UPDATE pickle_restaurants SET counter = ? WHERE id = ?",
        { counter and json.encode(counter) or nil, restaurantId })
    return true
end


-- The station type a prop row behaves as. A virtual point (an invisible anchor
-- that opens a station inside the restaurant's kitchen shell) cooks as its
-- metadata.target; everything else cooks as its own prop_type. Every cooking
-- read of prop.prop_type goes through this so virtual points inherit the full
-- station behavior while keeping their own per-row (= per point) state.
function StationType(prop)
    if prop and prop.prop_type == "virtual_point" then
        return (prop.metadata and prop.metadata.target) or ""
    end
    return prop and prop.prop_type or ""
end

-- The per-prop shape the panels consume (admin restaurants list, management
-- stations tab, placement getProps) — one place so the views can't drift.
function PropSummary(p)
    return {
        id = p.id, prop_type = p.prop_type, model = p.model,
        target = p.metadata and p.metadata.target, -- virtual points: the station they open
    }
end

-- ─── recipe groups ───────────────────────────────────────────────────────────
-- A recipe / assembly / drink / finish entry may carry an optional `group`
-- ("bakery", "pizza"…). A restaurant carries a `groups` array; it can only cook
-- and sell content whose group it carries. No group on the content = available
-- to EVERY restaurant, so a fresh install behaves exactly as before.

function RestaurantHasAccess(restaurantId, group)
    if group == nil or group == "" then return true end
    local r = GetRestaurant(restaurantId)
    if not r then return false end
    -- No groups set on the restaurant = access to EVERYTHING. Groups are an
    -- opt-in RESTRICTION: leave empty for the full menu, add groups to limit a
    -- restaurant to only those categories.
    if type(r.groups) ~= "table" or #r.groups == 0 then return true end
    for _, g in ipairs(r.groups) do
        if g == group then return true end
    end
    return false
end

-- Every distinct group name in use across recipes + the grouped settings lists —
-- the suggestion pool for the admin UIs (groups exist by being used, not managed).
function CollectGroups()
    local seen, out = {}, {}
    local function add(g)
        if type(g) == "string" and g ~= "" and not seen[g] then
            seen[g] = true
            out[#out + 1] = g
        end
    end
    for _, f in ipairs(GetFoods()) do add(f.group) end
    for _, t in ipairs(GetTools()) do add(t.group) end
    for _, ing in ipairs(GetIngredientsCfg()) do add(ing.group) end
    table.sort(out)
    return out
end

-- ─── ingredient cost & default pricing ───────────────────────────────────────
-- A sellable's DEFAULT menu price is what its ingredients cost the restaurant to
-- buy (the `ingredient_costs` setting) marked up by `profit_margin`. Any item's
-- cost traces down to raw ingredients: an explicit cost wins; a recipe output
-- costs its input (divided by the batch output_count → per serving); an assembly
-- output costs the sum of its components. Recursive, cycle-guarded.
function ResolveItemCost(item, seen)
    if not item then return 0 end
    local costs = GetSetting("ingredient_costs", {})
    if costs[item] ~= nil then return tonumber(costs[item]) or 0 end
    seen = seen or {}
    if seen[item] then return 0 end
    seen[item] = true
    local rec = RecipeByOutput[item]
    if rec then
        local per = math.max(1, tonumber(rec.output_count) or 1)
        return ResolveItemCost(rec.input_item, seen) / per
    end
    for _, a in ipairs(GetAssembly()) do
        if a.output == item then
            local sum = 0
            for _, c in ipairs(a.components or {}) do sum = sum + ResolveItemCost(c, seen) end
            return sum
        end
    end
    -- A bake-tray output (raw_cake / raw_cookie) is produced by rubbing a fill
    -- tool's mix into a free tray, so it costs one mix item.
    for _, b in ipairs(GetBakingList()) do
        for _, t in ipairs(b.trays or {}) do
            if t.output == item then return ResolveItemCost(b.mix_item, seen) end
        end
    end
    return 0
end

-- Apply the global profit margin to a raw cost, rounded to whole dollars.
function MarkupPrice(cost)
    local margin = tonumber(GetSetting("profit_margin", 0)) or 0
    return RoundMoney((tonumber(cost) or 0) * (1 + margin / 100))
end

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

-- Is `item` consumed as a COMPONENT of some assembly recipe? A cooked output that
-- feeds an assembly (a beef/chicken patty → burger/sandwich) is a POOL-ONLY
-- intermediate: it lives in the per-player cooked-items pool and is built into the
-- assembly at prep, never handed to a customer on its own — so it is NEVER an
-- installed inventory item. See memory: cooked-intermediate-not-an-item.
function IsAssemblyComponent(item)
    if not item or item == "" then return false end
    for _, a in ipairs(GetAssembly()) do
        for _, c in ipairs(a.components or {}) do
            if c == item then return true end
        end
    end
    return false
end

-- Items a recipe references that don't exist in the catalogue. Cook OUTPUTS are
-- tray-held products, not necessarily items:
--   • the INPUT is always a real consumed item (bought into the shared stock pool);
--   • the COOKED output must be installed ONLY when it's an END product handed to a
--     customer directly (a side like fries). When it's an assembly COMPONENT (a patty)
--     it's a pool-only intermediate — never an item (aligns recipe validity with
--     IsProductItem, which already treats the patties as products);
--   • the BURNT output is NEVER an item — burnt food is unexchangeable and destroyed
--     when binned, so it's never required to be installed.
function RecipeMissingItems(r)
    local missing = {}
    -- the input must be an installed consumed item UNLESS it's itself a kitchen
    -- product (an assembled/baked intermediate like raw_pizza — tray-only)
    if not ItemExists(r.input_item) and not IsProductItem(r.input_item) then
        missing[#missing + 1] = r.input_item
    end
    if not IsAssemblyComponent(r.output_cooked_item) and not ItemExists(r.output_cooked_item) then
        missing[#missing + 1] = r.output_cooked_item
    end
    return missing
end

function IsRecipeValid(r) return #RecipeMissingItems(r) == 0 end

-- How a recipe is cooked: "grill" (cooktop surface), "oven" (inside a door), or
-- "fry" (fryer basket). Defaults to grill for legacy/untagged rows.
function RecipeMethod(r) return (r and r.method) or "grill" end

-- The item every crafted Restaurant Bag becomes (one item for all bag foods; the
-- food id is its POS variant). Mirrors DrinkItemName/MealItem.
function BagItemName() return GetSetting("bag_item", "restaurant_bag") end

-- A bag food's raw ingredient cost = the sum of its component costs (the bag
-- output itself is free packaging, never an ingredient). Default menu price.
function CraftCost(cr)
    local sum = 0
    for _, c in ipairs(cr.components or {}) do sum = sum + ResolveItemCost(c) end
    return sum
end

-- ─── unified menu: annotation (admin panel payloads) ─────────────────────────
-- Shallow-copied so annotations never leak back into the stored config (the NUI
-- strips them before save regardless). Validity is per the legacy rules:
--   • a raw consumed item (cook input, component, cup, tool bottle) must be an
--     installed inventory item — UNLESS it's itself a kitchen product (an
--     intermediate like raw_pizza / a cooked patty), which is tray-only;
--   • a cook output handed to customers directly must be installed; one that only
--     feeds an assembly is a pool-only intermediate and needn't be;
--   • burnt outputs are never required.

function AnnotateFoods()
    local drinkInstalled = ItemExists(GetSetting("drink_item", "drink"))
    local bagInstalled = ItemExists(BagItemName())
    local inputOwner = {}  -- duplicate cook-input detection (replaces the SQL unique key)
    local pourIndex = 0
    local out = {}
    for _, f in ipairs(GetFoods()) do
        local copy = {}; for k, v in pairs(f) do copy[k] = v end
        local missing = {}
        local function needItem(item)
            if item and not ItemExists(item) and not IsProductItem(item) then
                missing[#missing + 1] = item
            end
        end
        if f.kind == "bag" then
            for _, c in ipairs(f.components or {}) do needItem(c) end
            if f.display_item and not ItemExists(f.display_item) then
                missing[#missing + 1] = f.display_item
            end
            copy.bag_item_installed = bagInstalled
            copy.defaultPrice = MarkupPrice(CraftCost(f))
        else
            local prevOutput, priceItem = nil, nil
            for _, st in ipairs(f.steps or {}) do
                if st.type == "cook" then
                    local input = st.input or prevOutput
                    needItem(input)
                    if input then
                        if inputOwner[input] and inputOwner[input] ~= f.id then
                            copy.duplicate_input = input
                        else
                            inputOwner[input] = f.id
                        end
                    end
                    if st.output and not IsAssemblyComponent(st.output) and not ItemExists(st.output) then
                        missing[#missing + 1] = st.output
                    end
                    prevOutput, priceItem = st.output, st.output
                elseif st.type == "assemble" then
                    for _, c in ipairs(st.components or {}) do needItem(c) end
                    prevOutput, priceItem = st.output, st.output
                elseif st.type == "pour" then
                    if st.input and not ItemExists(st.input) then missing[#missing + 1] = st.input end
                    copy.drink_item_installed = drinkInstalled
                    pourIndex = pourIndex + 1
                    copy.tap = (pourIndex <= 6) and pourIndex or nil
                    priceItem = st.input
                end
            end
            copy.defaultPrice = MarkupPrice(ResolveItemCost(priceItem))
        end
        copy.valid, copy.missing = #missing == 0, missing
        out[#out + 1] = copy
    end
    return out
end

function AnnotateTools()
    local out = {}
    for _, t in ipairs(GetTools()) do
        local copy = {}; for k, v in pairs(t) do copy[k] = v end
        local missing = {}
        if not ItemExists(t.item) then missing[#missing + 1] = t.item end
        if t.mode == "decorate" then
            for _, tg in ipairs(t.targets or {}) do
                -- a target/output that's a tray PRODUCT is valid without being installed
                if not IsProductItem(tg.item)   and not ItemExists(tg.item)   then missing[#missing + 1] = tg.item end
                if not IsProductItem(tg.output) and not ItemExists(tg.output) then missing[#missing + 1] = tg.output end
            end
        elseif t.mode == "fill" then
            for _, tr in ipairs(t.trays or {}) do
                if tr.output and not ItemExists(tr.output) and not IsProductItem(tr.output) then
                    missing[#missing + 1] = tr.output
                end
            end
        end
        copy.valid, copy.missing = #missing == 0, missing
        out[#out + 1] = copy
    end
    return out
end

function AnnotateIngredients()
    local out = {}
    for _, ing in ipairs(GetIngredientsCfg()) do
        local copy = {}; for k, v in pairs(ing) do copy[k] = v end
        local missing = {}
        if not ItemExists(ing.item) then missing[#missing + 1] = ing.item end
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

-- Tell cooks their ingredient bar is stale after the shared stock pool changed
-- (another cook consumed, a decompose refunded, or a manager restocked). Clients
-- refresh only if they're currently at a station; getIngredients is
-- restaurant-scoped server-side, so an unnecessary refresh is harmless.
local function BroadcastStockDirty(restaurantId)
    TriggerClientEvent("pickle_restaurants:cooking:stockDirty", -1, restaurantId)
end

function AddStock(restaurantId, item, count)
    StockCache[restaurantId] = StockCache[restaurantId] or {}
    StockCache[restaurantId][item] = (StockCache[restaurantId][item] or 0) + count
    MySQL.update("INSERT INTO pickle_restaurant_stock (restaurant_id, item, count) VALUES (?, ?, ?) "
        .. "ON DUPLICATE KEY UPDATE count = count + VALUES(count)", { restaurantId, item, count })
    BroadcastStockDirty(restaurantId)
end

function RemoveStock(restaurantId, item, count)
    if GetStockCount(restaurantId, item) < count then return false end
    StockCache[restaurantId][item] = StockCache[restaurantId][item] - count
    MySQL.update("UPDATE pickle_restaurant_stock SET count = count - ? WHERE restaurant_id = ? AND item = ?",
        { count, restaurantId, item })
    BroadcastStockDirty(restaurantId)
    return true
end

-- ─── POS orders (kitchen tickets) ────────────────────────────────────────────
-- Write-through mutators over OrderCache, same pattern as stock/tray. Only OPEN
-- tickets are cached; closing removes the row from the cache but keeps the DB
-- row as history.
--
-- STALENESS FIX — the register's ticket list is kept live by exactly ONE path: the
-- server broadcasts the full open-order list on every change (see SyncOrders), and
-- clients apply it unconditionally. FiveM server→client events are reliable AND
-- ordered per client, so the LAST list the server sends is always the last one a
-- client applies — no sequence numbers, no reconciliation, no race. The bug this
-- replaced came from a SECOND path (the acting cashier also updated straight from
-- its callback reply), which could land out of order against the broadcast and
-- resurrect a just-cancelled ticket. One ordered path can't disagree with itself.

function CreateOrder(restaurantId, order)
    NextTicket[restaurantId] = NextTicket[restaurantId] or 1
    order.restaurant_id = restaurantId
    order.ticket = NextTicket[restaurantId]
    order.status = "open"
    NextTicket[restaurantId] = order.ticket + 1
    -- `lines` is a MariaDB reserved keyword — it MUST be backtick-quoted here just
    -- as it is in CREATE TABLE, or the INSERT is a syntax error and no ticket saves.
    order.id = MySQL.insert.await([[
        INSERT INTO `pickle_restaurant_orders`
            (`restaurant_id`, `ticket`, `customer_identifier`, `customer_name`, `cashier_identifier`, `lines`, `total`)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], { restaurantId, order.ticket, order.customer_identifier, order.customer_name,
          order.cashier_identifier, json.encode(order.lines or {}), order.total or 0 })
    -- Fall back to the ticket-scoped id if the insert didn't return one, so the
    -- order is still cached + completable and never indexes the cache with nil.
    if not order.id then order.id = -order.ticket end
    OrderCache[restaurantId] = OrderCache[restaurantId] or {}
    OrderCache[restaurantId][order.id] = order
    return order
end

function CloseOrder(restaurantId, orderId, status)
    local o = OrderCache[restaurantId] and OrderCache[restaurantId][orderId]
    if not o then return false end
    -- SAFETY NET: closing a ticket as "cancelled" means the customer never got the
    -- food, so the money must have gone back. Callers are expected to have already
    -- gone through RefundOrder (and normally have) — but this makes it structurally
    -- impossible for a NEW cancel path to be added that forgets. RefundOrder is
    -- idempotent, so the normal path's call here is a no-op; only a path that
    -- skipped it actually pays out. NPC tickets no-op inside RefundOrder (they
    -- never pre-paid).
    if status == "cancelled" and o.refunded ~= 1 and o.refunded ~= true then
        local ok, err = pcall(RefundOrder, restaurantId, o, _L("refund_reason_cancelled"))
        if not ok then
            print(("[pickle_restaurants] REFUND FAILED closing ticket #%s (order %s, restaurant %s): %s")
                :format(tostring(o.ticket), tostring(orderId), tostring(restaurantId), tostring(err)))
        end
    end
    o.status = status
    MySQL.update("UPDATE pickle_restaurant_orders SET status = ?, closed_at = NOW() WHERE id = ?",
        { status, orderId })
    OrderCache[restaurantId][orderId] = nil
    -- The last-known driver position/route seed (modules/sales) dies with the ticket.
    -- Cleared HERE rather than in each caller so completed, cancelled and any future
    -- close path all drop it — the cache is keyed by order id and would otherwise leak.
    if DriverTelemetry then DriverTelemetry[orderId] = nil end
    return true
end

-- Drop a restaurant's entire order state (used when a restaurant is deleted).
function ClearOrders(restaurantId)
    OrderCache[restaurantId] = nil
    NextTicket[restaurantId] = nil
end

-- ─── refunds (the ONE path money ever goes back to a customer) ───────────────
-- Every cancellation — cashier cancel at the POS, phone/KDS cancel, an admin
-- deleting a whole restaurant out from under its in-flight tickets, or anything
-- added later — MUST come through RefundOrder. Duplicating "give the money back"
-- per call site is exactly how a path ends up refunding the wrong account, the
-- pre-discount total, or nothing at all.
--
-- IDEMPOTENCE: an order is refundable EXACTLY ONCE. `refunded` is flipped on the
-- cache row (and written through to the DB) BEFORE any payout, with no yield
-- between the check and the set — so a second call, a cancel racing a completion,
-- or a cancel racing an admin delete finds the flag already up and returns false
-- without paying. The flag is PERSISTED, so a restart can't resurrect the ability
-- to refund a ticket that was already paid back.
--
-- OFFLINE: a disconnected customer has no source to AddMoney to. That is NOT a
-- reason to refuse the cancel (which would wedge the ticket open forever) and it
-- is emphatically not a reason to drop the money on the floor: the payout is
-- persisted to pickle_restaurant_pending_refunds and settled on their next login
-- by SettlePendingRefunds.
--
-- Returns ok, amount, deferred.

-- Which wallet a ticket was charged to: phone/card orders take BANK, register and
-- kiosk take cash. "money" is the bridge's cash currency name.
function OrderRefundAccount(order)
    return (order and order.paid_account == "bank") and "bank" or "money"
end

-- Resolve a live source for an identifier. The bridge's GetSourceFromIdentifier is
-- the fast path, but it goes through the framework's own player index, which some
-- setups populate late (multichar) — so fall back to scanning connected players
-- the way modules/sales does. Getting this wrong means a REACHABLE customer gets
-- their refund deferred, so it's worth the second look.
function ResolveSourceForIdentifier(identifier)
    if not identifier then return nil end
    if GetSourceFromIdentifier then
        local src = GetSourceFromIdentifier(identifier)
        if src then return tonumber(src) end
    end
    for _, p in ipairs(GetPlayers()) do
        p = tonumber(p)
        if GetIdentifier(p) == identifier then return p end
    end
    return nil
end

-- Park a payout for an offline customer. Cache + DB write-through; the UNIQUE key
-- on order_id makes a duplicate row impossible even if this were reached twice.
local function QueueRefund(restaurantId, order, amount, account, reason)
    local row = {
        order_id      = order.id,
        restaurant_id = restaurantId,
        identifier    = order.customer_identifier,
        ticket        = order.ticket or 0,
        amount        = amount,
        account       = account,
        reason        = reason,
    }
    local id = MySQL.insert.await([[
        INSERT INTO `pickle_restaurant_pending_refunds`
            (`order_id`, `restaurant_id`, `identifier`, `ticket`, `amount`, `account`, `reason`)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE `order_id` = `order_id`
    ]], { row.order_id, row.restaurant_id, row.identifier, row.ticket, row.amount, row.account, row.reason })
    -- A FALSY-OR-ZERO id means the ON DUPLICATE branch fired (MySQL leaves
    -- LAST_INSERT_ID at 0 for a no-op update) — a payout is already queued for this
    -- ticket, so there's nothing to add. Note `id > 0`, not just `if id`: 0 is TRUTHY
    -- in Lua, and caching a row under key 0 would give it a payout the settle thread
    -- can never mark paid (the UPDATE would match no row), so it would pay out again
    -- on every restart. That is the double-refund bug this whole flag exists to stop.
    id = tonumber(id) or 0
    if id <= 0 then
        -- Either the duplicate branch fired or the insert failed outright. Read the
        -- row back to tell those apart: "already queued" is fine, "no row at all" is
        -- money that has left the restaurant's balance with nothing owing it back —
        -- the one case that must never pass silently.
        local existing = MySQL.query.await(
            "SELECT * FROM `pickle_restaurant_pending_refunds` WHERE `order_id` = ?", { row.order_id })
        local found = existing and existing[1]
        if not found then
            print(("[pickle_restaurants] MONEY LOST — could not queue a refund for ticket #%s (order %s, restaurant %s): %s owed to %s (%s). Pay this back manually.")
                :format(tostring(row.ticket), tostring(row.order_id), tostring(restaurantId),
                        GetCurrencyString(amount), tostring(row.identifier), account))
            return false
        end
        if found.paid_at == nil then PendingRefunds[found.id] = found end
        return true
    end
    row.id = id
    PendingRefunds[id] = row
    print(("[pickle_restaurants] REFUND DEFERRED: ticket #%s (order %s, restaurant %s) owes %s to %s (%s) — customer offline, will pay on next login")
        :format(tostring(row.ticket), tostring(row.order_id), tostring(restaurantId),
                GetCurrencyString(amount), tostring(row.identifier), account))
    return true
end

function RefundOrder(restaurantId, order, reason)
    if not order then return false, 0, false end
    -- Already paid back (or being paid back right now, further down this same
    -- non-yielding block). Never pay twice.
    if order.refunded == 1 or order.refunded == true then return false, 0, false end

    -- NPC customers pay on serve, so an unserved NPC ticket never took money.
    -- Flag it refunded anyway so the accounting is uniform and no later path
    -- mistakes it for an unrefunded charge.
    local isNpc = (IsNpcOrder and IsNpcOrder(order)) or false

    -- CLAIM FIRST. Everything below can yield; nothing below may run twice.
    order.refunded = 1
    if order.id then
        MySQL.update("UPDATE `pickle_restaurant_orders` SET `refunded` = 1 WHERE `id` = ?", { order.id })
    end
    if isNpc then return false, 0, false end

    -- The amount actually CHARGED is what the row stores: resolveOrderLines
    -- rounds it, and the phone path stores the post-discount, post-redemption
    -- finalTotal. Round again defensively — money crossing a boundary is always
    -- whole dollars (house rule), and a legacy row could hold anything.
    local amount  = RoundMoney(order.total or 0)
    local account = OrderRefundAccount(order)

    -- Reverse the restaurant's side of the sale regardless of whether the
    -- customer is reachable — the house never keeps money for an unserved order.
    AdjustBalance(restaurantId, -amount)
    AddLedger(restaurantId, "refund", -amount,
        _L("ledger_refund", tostring(order.ticket), reason or _L("refund_reason_cancelled")), order.customer_identifier)

    -- Hand back a loyalty redemption burned on this order (the free-item punches
    -- were consumed at placeOrder; PhoneRestoreRedeem is a global from
    -- modules/phone, absent if that module isn't loaded).
    if (order.redeemed == 1 or order.redeemed == true) and PhoneRestoreRedeem then
        pcall(PhoneRestoreRedeem, restaurantId, order.customer_identifier)
    end

    if amount <= 0 then return true, 0, false end

    local src = ResolveSourceForIdentifier(order.customer_identifier)
    if not src then
        QueueRefund(restaurantId, order, amount, account, reason)
        return true, amount, true
    end

    AddMoney(src, amount, account)
    ShowNotification(src, _L("order_refunded", order.ticket or 0, GetCurrencyString(amount)))
    return true, amount, false
end

-- Pay out everything owed to one identifier that is now online. Safe to call
-- repeatedly: a row leaves the cache the moment it's paid, and paid_at is set in
-- the DB in the same step, so a restart mid-settle can't pay it a second time.
function SettlePendingRefunds(src)
    if not src then return 0 end
    local identifier = GetIdentifier(src)
    if not identifier then return 0 end
    -- Snapshot first. The loop below removes (and on failure re-adds) cache keys,
    -- and re-adding a key mid-`pairs` is undefined behaviour in Lua — so iterate a
    -- plain array of the rows we intend to settle, never the live table.
    local due = {}
    for id, row in pairs(PendingRefunds) do
        if row.identifier == identifier then due[#due + 1] = { id = id, row = row } end
    end
    local paid = 0
    for _, e in ipairs(due) do
        local id, row = e.id, e.row
        if PendingRefunds[id] then -- still unclaimed (another sweep may have taken it)
            -- Claim before paying, same rule as RefundOrder.
            PendingRefunds[id] = nil
            MySQL.update("UPDATE `pickle_restaurant_pending_refunds` SET `paid_at` = NOW() WHERE `id` = ?", { id })
            local amount = RoundMoney(row.amount or 0)
            if amount > 0 then
                -- Claiming before paying is the right trade (a double payout is worse
                -- than a retried one), but a throw mid-payout would otherwise burn the
                -- row. Put it back and clear paid_at so the next sweep tries again.
                local okp = pcall(AddMoney, src, amount, row.account == "bank" and "bank" or "money")
                if okp then
                    ShowNotification(src, _L("order_refunded", row.ticket or 0, GetCurrencyString(amount)))
                    paid = paid + amount
                else
                    PendingRefunds[id] = row
                    MySQL.update("UPDATE `pickle_restaurant_pending_refunds` SET `paid_at` = NULL WHERE `id` = ?", { id })
                    print(("[pickle_restaurants] refund payout failed for pending row %s (%s to %s) — requeued")
                        :format(tostring(id), GetCurrencyString(amount), tostring(identifier)))
                end
            end
        end
    end
    return paid
end

local function LoadPendingRefunds()
    PendingRefunds = {}
    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_restaurant_pending_refunds` WHERE `paid_at` IS NULL") or {}
    local n = 0
    for _, row in ipairs(rows) do
        PendingRefunds[row.id] = row
        n = n + 1
    end
    if n > 0 then
        print(("[pickle_restaurants] %d unpaid refund(s) queued for offline customers"):format(n))
    end
end

-- Settle queue. Deliberately a poll rather than a framework "player loaded" hook:
-- every bridge (esx / qb / custom) already exposes GetSourceFromIdentifier, none
-- of them expose a common load event, and money owed must not depend on which
-- framework is running. Idle cost is one table scan when nothing is owed.
CreateThread(function()
    while true do
        Wait(20000)
        if next(PendingRefunds) then
            local seen = {}
            for _, row in pairs(PendingRefunds) do
                local ident = row.identifier
                if ident and not seen[ident] then
                    seen[ident] = true
                    local src = ResolveSourceForIdentifier(ident)
                    if src then SettlePendingRefunds(src) end
                end
            end
        end
    end
end)

-- A combo slot option whose key is `group:<Name>` references a whole ACCESS GROUP
-- (any sellable the restaurant can currently make in that group) rather than one
-- fixed item — resolved to its live members at BuildComboCatalog time. Everything
-- else is a plain sellable key. Returns the group name, or nil for a normal option.
COMBO_GROUP_PREFIX = "group:"
function ComboOptionGroup(key)
    if type(key) == "string" and key:sub(1, #COMBO_GROUP_PREFIX) == COMBO_GROUP_PREFIX then
        return key:sub(#COMBO_GROUP_PREFIX + 1)
    end
    return nil
end

-- ─── combo meals (write-through cache) ────────────────────────────────────────
-- Insert or update one combo. `combo` carries { id?, number, label, price, enabled,
-- photo_url, photo_crop, slots } already sanitized by the caller (management). On
-- insert the DB assigns the id; the returned combo is what lands in ComboCache.
function SaveCombo(restaurantId, combo)
    combo.restaurant_id = restaurantId
    local slotsJson = json.encode(combo.slots or {})
    local cropJson  = combo.photo_crop and json.encode(combo.photo_crop) or nil
    if combo.id then
        MySQL.update.await([[
            UPDATE `pickle_restaurant_combos`
               SET `number` = ?, `label` = ?, `price` = ?, `enabled` = ?,
                   `photo_url` = ?, `photo_crop` = ?, `slots` = ?
             WHERE `id` = ? AND `restaurant_id` = ?
        ]], { combo.number, combo.label, combo.price, combo.enabled and 1 or 0,
              combo.photo_url, cropJson, slotsJson, combo.id, restaurantId })
    else
        combo.id = MySQL.insert.await([[
            INSERT INTO `pickle_restaurant_combos`
                (`restaurant_id`, `number`, `label`, `price`, `enabled`, `photo_url`, `photo_crop`, `slots`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ]], { restaurantId, combo.number, combo.label, combo.price, combo.enabled and 1 or 0,
              combo.photo_url, cropJson, slotsJson })
    end
    if not combo.id then return nil end
    ComboCache[restaurantId] = ComboCache[restaurantId] or {}
    ComboCache[restaurantId][combo.id] = combo
    return combo
end

function DeleteCombo(restaurantId, comboId)
    MySQL.update.await("DELETE FROM pickle_restaurant_combos WHERE id = ? AND restaurant_id = ?",
        { comboId, restaurantId })
    if ComboCache[restaurantId] then ComboCache[restaurantId][comboId] = nil end
    return true
end

-- Drop a restaurant's combos (restaurant deleted). Row cleanup is done by the
-- caller's DELETE alongside the other per-restaurant tables.
function ClearCombos(restaurantId)
    ComboCache[restaurantId] = nil
end

-- Open tickets for the register NUI, oldest first (kitchen works the queue in order).
-- Only genuinely-open rows are surfaced: the callbacks hold their transient claim in
-- o.busy (never o.status), so o.status is always "open" here — but the explicit
-- filter is a hard guarantee that a row can never render as a phantom the register
-- shows yet the action guard rejects (the wedged-ticket failure mode).
function GetOpenOrders(restaurantId)
    local list = {}
    for _, o in pairs(OrderCache[restaurantId] or {}) do
        if o.status == "open" then
            -- NPC tickets carry a patience countdown so the POS / kitchen widget can
            -- show the time left (and a radial) before the customer walks. Helpers
            -- are globals from modules/npc_customers; guard so this stays valid even
            -- if that module is absent. Player tickets get npc=false / no timer.
            local isNpc = (IsNpcOrder and IsNpcOrder(o)) or false
            local expiresIn, patience
            if isNpc and NpcOrderTimer then expiresIn, patience = NpcOrderTimer(restaurantId, o.id) end
            list[#list + 1] = {
                orderId   = o.id,
                ticket    = o.ticket,
                customer  = o.customer_name,
                lines     = o.lines,
                total     = o.total,
                status    = o.status,
                npc       = isNpc,
                expiresIn = expiresIn, -- seconds left at send time (client ticks down)
                patience  = patience,  -- full patience window (radial denominator)
                -- Phone companion (modules/phone): delivery/pickup/dine-in + order-ahead.
                -- nil on register/kiosk/NPC tickets (they never set them). Additive.
                orderType = o.order_type,
                scheduled = o.scheduled_for,
                address   = o.address,
                -- The transient delivery claim (modules/sales' startDelivery). This is a
                -- PROJECTION, not the cache row, so anything AnnotateOrders needs has to
                -- be carried across explicitly — without these the driver lookup always
                -- saw nil and the phone's "Accept Delivery" never flipped to "Cancel".
                driver_identifier = o.driver_identifier,
                driver_name       = o.driver_name,
            }
        end
    end
    table.sort(list, function(a, b) return a.ticket < b.ticket end)
    return list
end

-- Players within `radius` of `src`, for pickers (hiring, POS customer select).
function NearbyPlayers(src, radius)
    local ped = GetPlayerPed(src)
    local c = GetEntityCoords(ped)
    local list = {}
    for _, p in ipairs(GetPlayers()) do
        p = tonumber(p)
        if p ~= src then
            local pc = GetEntityCoords(GetPlayerPed(p))
            if #(c - pc) < (radius or 10.0) then list[#list + 1] = { id = p, name = GetPlayerCharacterName(p) } end
        end
    end
    return list
end

-- ─── cooked-items tray (per-player, per-restaurant) ──────────────────────────

-- Flag a restaurant's pool as changed so an open register re-computes ticket
-- fulfillability. Coalesced and flushed via SyncOrders by a thread in modules/sales
-- (the tray mutates in tight loops — a per-op broadcast would spam clients).
function MarkOrdersDirty(rid) if rid then OrdersDirty[rid] = true end end

-- Canonical signature of one instance's build stack: its ordered layers as
-- "item|half" joined with ",". "" = no recorded stack (a plain instance).
-- Two builds of the same item with different stacks (e.g. a pizza with and without
-- pepperoni) get different signatures, so the tray can tell the variations apart
-- instead of merging them into one count and popping the wrong one on removal.
function TraySig(meta)
    if type(meta) ~= "table" or #meta == 0 then return "" end
    local parts = {}
    for _, l in ipairs(meta) do
        -- tolerate the older aggregated `count` layer format
        for _ = 1, (tonumber(l.count) or 1) do
            local part = tostring(l.item) .. "|" .. tostring(l.half or "")
            -- a melting topping riding this layer (its `top` field): its item + melt
            -- state are part of the variation identity
            local topv = LayerTopping(l)
            if topv then
                part = part .. "+" .. tostring(topv.item) .. ":" .. tostring(topv.state)
            end
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
            -- a meal made in a pizza box (flag on the first layer) is a different
            -- variation from the same pizza arranged on a serving tray
            if l.box then
                part = part .. "^box"
            end
            -- a crafted Restaurant Bag carries its craft id (flag on the first
            -- layer): the bag item is generic, so the craft IS its variation
            -- identity — two crafts with the same components stay distinct.
            if l.craft ~= nil then
                part = part .. "~" .. tostring(l.craft)
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
function GetTrayCount(rid, identifier, item, sig)
    local e = TrayCache[rid] and TrayCache[rid][identifier] and TrayCache[rid][identifier][item]
    if not e then return 0 end
    if sig == nil then return e.count or 0 end
    local n = 0
    for i = 1, e.count or 0 do
        if traySigAt(e, i) == sig then n = n + 1 end
    end
    return n
end

-- The build stack of the most-recently-added (matching) instance of a tray entry,
-- or nil for a plain instance with no recorded stack. `metas` holds one entry per
-- counted item (a stack table, or false when that instance wasn't assembled from parts).
function TrayTopMeta(rid, identifier, item, sig)
    local e = TrayCache[rid] and TrayCache[rid][identifier] and TrayCache[rid][identifier][item]
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
function AddTray(rid, identifier, item, count, meta)
    if not rid or not identifier or not item then return end
    count = count or 1
    TrayCache[rid] = TrayCache[rid] or {}
    TrayCache[rid][identifier] = TrayCache[rid][identifier] or {}
    local e = TrayCache[rid][identifier][item]
    if not e then
        e = { item = item, count = 0, metas = {}, cookedAt = os.time() }
        TrayCache[rid][identifier][item] = e
    end
    e.metas = e.metas or {}
    e.count = e.count + count
    -- EVERY add restamps the row's freshness clock: the newest instance is fresh,
    -- and the row expires as one unit — so topping a slot up gives the whole stack
    -- the full window again instead of inheriting the oldest instance's leftovers.
    e.cookedAt = os.time()
    for _ = 1, count do e.metas[#e.metas + 1] = meta or false end
    MySQL.update("INSERT INTO pickle_restaurant_cooked_items (restaurant_id, identifier, item, count, metadata, cooked_at) "
        .. "VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE count = count + VALUES(count), metadata = VALUES(metadata), cooked_at = VALUES(cooked_at)",
        { rid, identifier, item, count, json.encode(e.metas), e.cookedAt })
    MarkOrdersDirty(rid)
end

function RemoveTray(rid, identifier, item, count, sig)
    count = count or 1
    if GetTrayCount(rid, identifier, item, sig) < count then return false end
    local e = TrayCache[rid][identifier][item]
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
        TrayCache[rid][identifier][item] = nil
        MySQL.update("DELETE FROM pickle_restaurant_cooked_items WHERE restaurant_id = ? AND identifier = ? AND item = ?",
            { rid, identifier, item })
    else
        MySQL.update("UPDATE pickle_restaurant_cooked_items SET count = count - ?, metadata = ? WHERE restaurant_id = ? AND identifier = ? AND item = ?",
            { count, json.encode(e.metas), rid, identifier, item })
    end
    MarkOrdersDirty(rid)
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
                    item = e.item, count = groups[s].count,
                    sig = s, meta = groups[s].meta, cookedAt = e.cookedAt or 0,
                    label = GetItemLabel(e.item), image = GetItemImage(e.item),
                }
            end
        end
    end
    return out
end

-- ─── restaurant-wide pool (read/consume across every cook's tray) ─────────────
-- The tray stays per-player; the POS register fulfils from the UNION of a
-- restaurant's trays so cooks don't have to double as cashiers. `matchSig` (nil =
-- any) filters to one build variation exactly as the per-player tray functions do;
-- item matching spans every cheese state (a plain "burger" line is satisfied by a
-- cheesed burger too — item-name matching, same as the old inventory path).

-- Total count of `item` across all identifiers + cheese states matching `matchSig`.
function PoolCount(rid, item, matchSig)
    local byId = TrayCache[rid]
    if not byId then return 0 end
    local n = 0
    for identifier, byKey in pairs(byId) do
        for _, e in pairs(byKey) do
            if e.item == item then
                n = n + GetTrayCount(rid, identifier, item, matchSig)
            end
        end
    end
    return n
end

-- The build stack of some pool instance of `item` matching `matchSig` (any cook),
-- or nil. Read-only — used to compute a meal's coverage before deciding to consume.
function PoolTopMeta(rid, item, matchSig)
    local byId = TrayCache[rid]
    if not byId then return nil end
    for identifier, byKey in pairs(byId) do
        for _, e in pairs(byKey) do
            if e.item == item then
                local m = TrayTopMeta(rid, identifier, item, matchSig)
                if m ~= nil then return m end
            end
        end
    end
    return nil
end

-- Distinct build variations of `item` in the pool, merged across cooks:
-- { { sig, meta, count, label }, … }. For the register's meal picker.
function PoolVariations(rid, item)
    local out, idx = {}, {}
    local byId = TrayCache[rid]
    if not byId then return out end
    for identifier in pairs(byId) do
        for _, e in ipairs(GetTray(rid, identifier)) do
            if e.item == item then
                local k = e.sig or ""
                if not idx[k] then
                    idx[k] = { sig = e.sig, meta = e.meta, count = 0, label = e.label }
                    out[#out + 1] = idx[k]
                end
                idx[k].count = idx[k].count + e.count
            end
        end
    end
    return out
end

-- Consume up to `count` matching instances of `item` from the pool (any identifier,
-- LIFO within each row). Returns a list of { meta } for every
-- consumed instance (meta read BEFORE its RemoveTray, like trayToInventory), or nil
-- if the pool can't cover `count` — in which case nothing is consumed.
function PoolConsume(rid, item, matchSig, count)
    count = count or 1
    if PoolCount(rid, item, matchSig) < count then return nil end
    local taken = {}
    local byId = TrayCache[rid] or {}
    for identifier, byKey in pairs(byId) do
        for _, e in pairs(byKey) do
            if e.item == item then
                while #taken < count and GetTrayCount(rid, identifier, item, matchSig) > 0 do
                    local meta = TrayTopMeta(rid, identifier, item, matchSig)
                    if not RemoveTray(rid, identifier, item, 1, matchSig) then break end
                    taken[#taken + 1] = { meta = meta }
                end
            end
            if #taken >= count then break end
        end
        if #taken >= count then break end
    end
    return taken
end

-- Pool count/consume with a CUSTOM instance matcher `match(meta) -> bool` (meta is
-- one instance's build stack, or nil for a plain/legacy instance). The sales
-- fulfillment planner matches by VARIATION (a cheeseburger ≠ a plain burger, a
-- strawberry cake ≠ a plain one) rather than by the raw TraySig, so it can't use
-- the sig-keyed PoolCount/PoolConsume — it hands the semantics in as a predicate.
function PoolCountMatch(rid, item, match)
    local byId = TrayCache[rid]
    if not byId then return 0 end
    local n = 0
    for _, byKey in pairs(byId) do
        for _, e in pairs(byKey) do
            if e.item == item then
                for i = 1, e.count or 0 do
                    local m = e.metas and e.metas[i]
                    if match((type(m) == "table") and m or nil) then n = n + 1 end
                end
            end
        end
    end
    return n
end

-- Consume up to `count` instances of `item` for which match(meta) is true (any
-- identifier, LIFO within each row). Returns { {meta}, … } for every
-- consumed instance (meta read BEFORE its removal), or nil if the pool can't cover
-- `count` — in which case nothing is consumed. Removal pins the instance's EXACT sig
-- so a broader variation match never pops the wrong stack.
function PoolConsumeMatch(rid, item, match, count)
    count = count or 1
    if PoolCountMatch(rid, item, match) < count then return nil end
    local taken = {}
    local byId = TrayCache[rid] or {}
    for identifier, byKey in pairs(byId) do
        for _, e in pairs(byKey) do
            if e.item == item then
                local i = e.count or 0
                while #taken < count and i >= 1 do
                    local m = e.metas and e.metas[i]
                    local mt = (type(m) == "table") and m or nil
                    if match(mt) then
                        local sig = traySigAt(e, i)
                        if RemoveTray(rid, identifier, item, 1, sig) then
                            taken[#taken + 1] = { meta = mt }
                        end
                        i = e.count or 0 -- the row shrank; rescan from the (new) top
                    else
                        i = i - 1
                    end
                end
            end
            if #taken >= count then break end
        end
        if #taken >= count then break end
    end
    return taken
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
        -- NUI theme seed { primary, mode, radius } — the client passes it along
        -- when it opens a panel scoped to this restaurant (cooking stations).
        theme        = r.metadata and r.metadata.theme or nil,
        -- virtual kitchen shell anchor { x, y, z, heading } — where a virtual
        -- point session builds its local shell + stations (XY = counter).
        shell        = r.metadata and r.metadata.shell or nil,
        -- Compact orderable menu for a placed MENU SCREEN prop (modules/screens):
        -- { label, price, image, kind }. Built from the live priced catalog so the
        -- board tracks menu edits (each menu change re-syncs). Guarded because the
        -- builder lives in the sales module (loaded after core).
        menu         = BuildMenuBoard and BuildMenuBoard(r.id) or nil,
        -- Numbered combo-meal cards for the same board (kept SEPARATE from `menu` —
        -- combo cards carry a number, photo+crop and a component list). Also drives
        -- the POS combo section. Guarded like `menu` (builder lives in sales).
        combos       = BuildComboBoard and BuildComboBoard(r.id) or nil,
    }
end

-- A "product" is anything the kitchen PRODUCES: a recipe cook output, an assembly
-- output, or a finish output. Products live in the per-player cooked-items tray,
-- never the real inventory, so they do NOT need to be installed inventory items to
-- be valid config — a finish can target/output one (a frosted doughnut) that only
-- ever exists as a cooked/tray item. Finish targets & outputs are validated with
-- `ItemExists(x) or IsProductItem(x)` so a tray-only product never hides the tool,
-- exactly like the beef/chicken patties. (Mirrors the cooking module's isTrayItem,
-- but global so the sync/annotate here can use it.)
function IsProductItem(item)
    if not item or item == "" then return false end
    for _, r in ipairs(RecipeCache) do
        if r.output_cooked_item == item or r.output_burnt_item == item then return true end
    end
    for _, a in ipairs(GetAssembly()) do
        if a.output == item then return true end
    end
    for _, f in ipairs(GetFinishes()) do
        for _, t in ipairs(f.targets or {}) do
            if t.output == item then return true end
        end
    end
    -- a bake-tray output (raw_cake / raw_cookie) is a tray-only uncooked
    -- intermediate (like raw_pizza) — a kitchen product, never a carried item
    for _, b in ipairs(GetBakingList()) do
        for _, t in ipairs(b.trays or {}) do
            if t.output == item then return true end
        end
    end
    return false
end

-- A finish target/output item is usable if it's an installed inventory item OR a
-- kitchen product (tray item). The tool itself is NOT a product — it must be real.
local function FinishItemOk(item) return ItemExists(item) or IsProductItem(item) end

function BuildSyncPayload()
    -- Only valid configs are shipped to the game world. A recipe / drink /
    -- assembly that references a missing item is hidden until an admin fixes it
    -- (it still shows in the admin panel, flagged, so it *can* be fixed).
    local recipes = {}
    for _, r in ipairs(RecipeCache) do
        if IsRecipeValid(r) then recipes[#recipes + 1] = r end
    end
    local drinks = {}
    for i, d in ipairs(GetDrinks()) do
        -- only the cup (input) must be an installed item — the output is a flavor
        -- KEY (poured drinks collect as the one `drink_item` item, flavor in meta)
        if ItemExists(d.input) then
            -- `tap` = the entry's RAW config position: the fountain tap it holds
            -- (first six only). Stamped on a copy so the derived row stays clean.
            local copy = {}
            for k, v in pairs(d) do copy[k] = v end
            copy.tap = (i <= 6) and i or nil
            drinks[#drinks + 1] = copy
        end
    end
    local assembly = {}
    for _, a in ipairs(GetAssembly()) do
        -- the OUTPUT is a kitchen product (tray-held, IsProductItem) — it works
        -- without being an installed item (raw_pizza never is; only taking it out
        -- via trayToInventory would need one). Components are real consumed items.
        local ok = true
        for _, comp in ipairs(a.components or {}) do
            -- a component is a real consumed item OR a kitchen product (a cooked patty
            -- from the pool) — the latter needn't be installed (IsProductItem)
            if not ItemExists(comp) and not IsProductItem(comp) then ok = false end
        end
        if ok then assembly[#assembly + 1] = a end
    end
    -- Bag foods: shipped only when the ONE bag item is installed (every bag food
    -- collects as it — no bag item, nothing to hand out) AND every component
    -- resolves (a real consumed item OR a cooked-pool product).
    local crafts = {}
    if ItemExists(BagItemName()) then
        for _, cr in ipairs(GetCrafts()) do
            local ok = (cr.id and cr.id ~= "" and cr.components and #cr.components > 0)
            for _, comp in ipairs(cr.components or {}) do
                if not ItemExists(comp) and not IsProductItem(comp) then ok = false end
            end
            if ok then crafts[#crafts + 1] = cr end
        end
    end
    -- Decorate tools ship with only their valid targets: the tool must be a real
    -- (consumed) inventory item, but a target/output may be a tray-only PRODUCT
    -- (a frosted doughnut is a finish output, never installed) — FinishItemOk. An
    -- entry with no surviving targets is dropped entirely.
    local finishes = {}
    for _, f in ipairs(GetFinishes()) do
        if ItemExists(f.tool) then
            local targets = {}
            for _, t in ipairs(f.targets or {}) do
                if FinishItemOk(t.item) and FinishItemOk(t.output) then targets[#targets + 1] = t end
            end
            if #targets > 0 then
                local copy = {}; for k, v in pairs(f) do copy[k] = v end
                copy.targets = targets
                finishes[#finishes + 1] = copy
            end
        end
    end

    -- Layer tools (condiments): shipped only when the bottle's inventory item is
    -- real (consumed) and both of its props are configured. An entry missing any
    -- of these is dropped — the applicator would have nothing to spawn otherwise.
    local condiments = {}
    for _, c in ipairs(GetCondiments()) do
        if c.item and ItemExists(c.item) and c.container_model and c.applied_model then
            condiments[#condiments + 1] = c
        end
    end

    -- Fill tools (baking): a LIST now (one entry per fill tool). Each ships only
    -- when its mix is a real (consumed) inventory item; individual trays are
    -- dropped unless their output is a usable item/product (raw_cake/raw_cookie
    -- are real items — needed for bakeTrayToInv).
    local baking = {}
    for _, b in ipairs(GetBakingList()) do
        if b.mix_item and ItemExists(b.mix_item) then
            local trays = {}
            for _, t in ipairs(b.trays or {}) do
                if t.kind and t.tray_model and FinishItemOk(t.output) then trays[#trays + 1] = t end
            end
            if #trays > 0 then
                baking[#baking + 1] = { mix_item = b.mix_item, mix_model = b.mix_model,
                                        rub_dist = b.rub_dist, trays = trays }
            end
        end
    end

    -- Ingredients: the client's per-item behavior config (prep prop + halves /
    -- melts properties). Only entries whose item is installed are shipped —
    -- everything the client needs to render toppings, split halves, etc.
    local ingredients = {}
    for _, ing in ipairs(GetIngredientsCfg()) do
        if ing.item and ItemExists(ing.item) then
            ingredients[#ingredients + 1] = ing
        end
    end

    -- Pizza-box acceptance, resolved server-side into a plain MODEL list so the
    -- client's drag preview can hash-match the carried pile's bottom prop: every
    -- box_base ingredient's own prop, plus the cook-state models of any recipe fed
    -- by an assembly whose FIRST component is that ingredient (raw pizza at every
    -- cook state), plus a recipe cooking the ingredient directly.
    local boxSeen, box_base_models = {}, {}
    local function addBoxModel(m)
        if m and m ~= "" and not boxSeen[m] then boxSeen[m] = true; box_base_models[#box_base_models + 1] = m end
    end
    for _, ing in ipairs(GetIngredientsCfg()) do
        if ing.box_base then
            addBoxModel(ing.model)
            local function addRecipeModels(r)
                if r then addBoxModel(r.raw_model); addBoxModel(r.cooked_model); addBoxModel(r.burnt_model) end
            end
            addRecipeModels(RecipeByInput[ing.item])
            for _, a in ipairs(GetAssembly()) do
                if (a.components or {})[1] == ing.item then
                    if a.model then addBoxModel(a.model) end
                    addRecipeModels(RecipeByInput[a.output])
                end
            end
        end
    end

    local payload = { restaurants = {}, props = {}, recipes = recipes, settings = {
        drinks   = drinks,
        assembly = assembly,
        crafts   = crafts,
        -- the Restaurant Bag vessel prop + the one item every bag food becomes, so
        -- the client can spawn the bag equipment and render a finished/held bag
        bag_item  = BagItemName(),
        bag_model = GetSetting("bag_model", "pickle_restaurant_bag_01"),
        finishes = finishes,
        condiments = condiments,
        baking   = baking,
        ingredients = ingredients,
        box_base_models = box_base_models,
        -- per-model manual stacking corrections for the client render (see the
        -- stack_tweaks setting seed)
        stack_tweaks = GetSetting("stack_tweaks", {}),
        -- the side-serving container box (fries…) — shipped so the client can apply
        -- the mesh-bottom base-lift correction when it's the base of a build stack
        side_container_model = GetSetting("side_container_model", ""),
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
        SeedUnifiedMenu()
        RebuildDerived()
        LoadRestaurants()
        LoadProps()
        LoadEmployees()
        LoadStock()
        LoadOrders()
        LoadPendingRefunds() -- refunds owed to customers who were offline at cancel time
        LoadCookedItems()
        LoadCombos()
        RestaurantsReady = true
        debugPrint(("Booted: %d restaurants, %d props, %d recipes."):format(
            #BuildSyncPayload().restaurants, #BuildSyncPayload().props, #RecipeCache))
        -- Push to anyone already connected (resource restart mid-session).
        SyncToClient(-1)
    end)
end)
