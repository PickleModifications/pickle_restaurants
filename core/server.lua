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
TrayCache       = {}    -- [restaurantId][identifier][item.."|"..cheese] = { item, cheese, count, metas } (metas: one build stack — or false — per counted instance; TraySig(meta) addresses a variation)
SettingsCache   = {}    -- [key]           = decoded value
OrderCache      = {}    -- [restaurantId][orderId] = open POS ticket row (lines decoded)
NextTicket      = {}    -- [restaurantId]  = next kitchen ticket number
OrdersDirty     = {}    -- [restaurantId]  = true when the pool changed → register needs a live SyncOrders (coalesced flusher in modules/sales)

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
    cheese_melt_ms  = 8000, -- how long applied cheese takes to melt on a patty
    -- Global default freshness window (seconds) for collected cooked items in the
    -- tray before they spoil and are swept. Default 900 = 15 minutes; 0 = never
    -- expire. A recipe's own `expire_seconds` overrides this per item (NULL on a
    -- recipe = use this default).
    cooked_expire_seconds = 900,
    -- The inventory item a serving-tray arrangement becomes at kitchen prep. The
    -- meal's metadata records every item WITH its position on the tray, so it
    -- re-renders 1:1 wherever it's set back down. The item is what gets GENERATED
    -- (itemgen exports it) — never a requirement to use the tray; only moving a
    -- meal into the real inventory needs it installed.
    meal_item       = "meal",
    -- The inventory item EVERY poured drink becomes ("Restaurant Drink") — one
    -- item for all flavors, the flavor riding as build-stack metadata (a layer
    -- holding the drinks[].output key), exactly like the meal item. The per-flavor
    -- `output` keys below stop being items; itemgen exports only this one.
    drink_item      = "drink",
    -- The inventory item a paying customer receives when a POS order is rung up —
    -- its slot metadata carries the order id/ticket so completion can verify the
    -- holder. Like meal_item it's what gets GENERATED (itemgen exports it); if the
    -- item isn't installed the POS still works, just without a physical receipt.
    receipt_item    = "receipt",
    blip            = { sprite = 93, color = 1, scale = 0.8, enabled = true },
    default_roles   = {
        ["0"] = { label = "Trainee", commission = 5,  permissions = { cook = true } },
        ["1"] = { label = "Cook",    commission = 10, permissions = { cook = true, sell = true } },
        ["2"] = { label = "Manager", commission = 15, permissions = {
            cook = true, sell = true, manage_menu = true, manage_props = true,
            manage_employees = true, view_finances = true, manage_stock = true,
        } },
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
    -- Sides (fries…) are served IN a container box — kitchen equipment like the drink
    -- lid (no inventory item; visual-only). `side_container_model` is the box prop;
    -- `side_container_items` lists the collected item(s) rendered inside it. The box
    -- prepends to the item's build stack, so a served side shows box + food as ONE
    -- unit everywhere (bar, dragged, placed, meal layer) — never a bare loose serving.
    -- Add nuggets (cooked_nuggets/burnt_nuggets) here to box them too.
    side_container_model = "pickle_side_container_01",
    side_container_items = { "cooked_fries", "burnt_fries" },
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
        -- (Cookies need no override: pickle_cookie_02/03 are already single cooked/burnt
        -- cookies, so a collected cookie matches what baked on the tray. The six-cookie
        -- tray layout is done by the batch-grid render, not the item model.)
    },
    -- Kitchen-prep assembly: combine components -> output item. ONE base item per
    -- food family (one-item consolidation rule): a cheeseburger / deluxe burger is
    -- just a Burger with modifiers, not a separate item. `modifiers` are the POS
    -- customisations a customer can pick (add cheese, no lettuce…): each has an
    -- optional `price` delta and an optional `default` (included on the base build,
    -- so toggling it off reads as "no X"). `item` names the referenced component so
    -- the kitchen ticket knows what to build; modifiers are ticket instructions +
    -- pricing, never a completion gate (food orders match by item).
    assembly = {
        { output = "burger", label = "Burger", model = "pickle_bread_bun_01", group = "Fast Food",
          components = { "bun", "cooked_beef_patty" },
          modifiers = {
            { id = "cheese",  label = "Cheese",  item = "cheese",  price = 2 },
            { id = "lettuce", label = "Lettuce", item = "lettuce", price = 0 },
            { id = "tomato",  label = "Tomato",  item = "tomato",  price = 0 },
            { id = "pickle",  label = "Pickle",  item = "pickle",  price = 0 },
          } },
        { output = "chicken_sandwich", label = "Chicken Sandwich", model = "pickle_bread_bun_01", group = "Fast Food",
          components = { "bun", "cooked_chicken_patty" },
          modifiers = {
            { id = "cheese",  label = "Cheese",  item = "cheese",  price = 2 },
            { id = "lettuce", label = "Lettuce", item = "lettuce", price = 0 },
            { id = "tomato",  label = "Tomato",  item = "tomato",  price = 0 },
            { id = "pickle",  label = "Pickle",  item = "pickle",  price = 0 },
          } },
        -- Pizza: a cheese base (dough + sauce + cheese) assembled at kitchen prep, then
        -- baked in the oven. Pepperoni (and any other prep topping) is optional — add it
        -- on the stack as an alteration; it rides along as a variation.
        { output = "raw_pizza", label = "Pizza (uncooked)", model = "pickle_pizza_dough_01", group = "Pizza",
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
        { tool = "frosting", tool_model = "pickle_frosting_tube_01", rub_dist = 1.2, group = "Bakery",
          targets = {
            -- A decorated cake is NOT a separate item (same collapse as doughnuts):
            -- it stays `cooked_cake` and the frosting flavor rides as build-stack
            -- metadata (distinguished by TraySig), so the ordering terminal shows
            -- ONE "Cake" with a pick-one frosting flavor (finishModsFor). Replace-mode:
            -- the chosen whole-cake model IS the finished product.
            { item = "cooked_cake", output = "cooked_cake", mode = "replace",
              -- color drives the flavor swatch on the NUI card (falls back to a
              -- built-in palette by flavor id when omitted)
              flavors = {
                { id = "strawberry", label = "Strawberry", model = "pickle_cake_01", color = "#f472b6" },
                { id = "chocolate",  label = "Chocolate",  model = "pickle_cake_02", color = "#8b5a2b" },
                { id = "vanilla",    label = "Vanilla",    model = "pickle_cake_03", color = "#f3e5ab" },
                { id = "pickle",     label = "Pickle",     model = "pickle_cake_04", color = "#65a30d" },
              } },
            -- A frosted doughnut is NOT a separate item: it stays `cooked_doughnut`
            -- and the frosting rides as build-stack metadata (flavor recorded on the
            -- layer, distinguished by TraySig). Overlay-mode, so the frosting model
            -- stacks on the fried-doughnut prop. All doughnut variants collapse to
            -- the one `cooked_doughnut` item.
            { item = "cooked_doughnut", output = "cooked_doughnut", mode = "overlay",
              flavors = {
                { id = "strawberry", label = "Strawberry", model = "pickle_doughnut_topping_01", color = "#f472b6" },
                { id = "chocolate",  label = "Chocolate",  model = "pickle_doughnut_topping_02", color = "#8b5a2b" },
                { id = "glazed",     label = "Glazed",     model = "pickle_doughnut_topping_03", color = "#f0c36d" },
                { id = "vanilla",    label = "Vanilla",    model = "pickle_doughnut_topping_04", color = "#f3e5ab" },
                { id = "pickle",     label = "Pickle",     model = "pickle_doughnut_topping_05", color = "#65a30d" },
              } },
          } },
        -- Sprinkles: a second finish tool, DONUTS ONLY, and only AFTER frosting. It
        -- also targets `cooked_doughnut` (all doughnuts are one item now), but
        -- `requires_finish = "frosting"` gates it so it applies ONLY to a doughnut
        -- whose metadata already carries a frosting layer — a plain fried doughnut is
        -- rejected. Overlay-mode: the sprinkles stack over the frosting (finishRender
        -- composes the nested tower from the meta). Output is again `cooked_doughnut`;
        -- the frosting+sprinkles flavors live entirely in build metadata. Variant prop
        -- prefix `pickle_doughnut_sprinkles_NN` — 01 vanilla, 02 chocolate.
        { tool = "sprinkles", tool_model = "pickle_sprinkles_tube_01", rub_dist = 1.2, group = "Bakery",
          targets = {
            { item = "cooked_doughnut", output = "cooked_doughnut", mode = "overlay",
              requires_finish = "frosting",
              flavors = {
                { id = "vanilla",   label = "Vanilla",   model = "pickle_doughnut_sprinkles_01", color = "#f3e5ab" },
                { id = "chocolate", label = "Chocolate", model = "pickle_doughnut_sprinkles_02", color = "#8b5a2b" },
              } },
          } },
    },
    -- Condiments (ketchup / mustard / mayo). A squeeze-bottle applicator, sibling to
    -- the finish tools but with a distinct gesture and a distinct EFFECT. Drag the
    -- bottle out of the prep bar and hold it over a build stack: the `container_model`
    -- flips 180° (nozzle down) and squeezes DOWN-and-UP once, laying its `applied_model`
    -- sauce on top as a new build-stack LAYER. Unlike a finish (which consumes a
    -- FINISHED tray product and re-trays a decorated one), a condiment adds a layer to
    -- an in-progress prep BUILD exactly like adding pepperoni — it rides along as a
    -- build-stack variation (TraySig) and is consumed from the shared stock pool at
    -- Make. A condiment can NEVER be a stack's FIRST layer (there'd be nothing to sauce)
    -- — enforced client-side in the applicator loop. `item` is the consumed inventory
    -- item; every condiment prop shares a CENTRE-BOTTOM origin (bottle contains the
    -- sauce, so only the two props per flavor are needed — no separate sauce item).
    condiments = {
        { item = "ketchup", container_model = "pickle_ketchup_container_01", applied_model = "pickle_ketchup_applied_01" },
        { item = "mustard", container_model = "pickle_mustard_container_01", applied_model = "pickle_mustard_applied_01" },
        { item = "mayo",    container_model = "pickle_mayo_container_01",    applied_model = "pickle_mayo_applied_01" },
    },
    -- Baking mix + trays. One shared `mix_item` (a raw ingredient bought into the
    -- shared stock pool, like any `ingredient_costs` entry) is rubbed into a tray to
    -- produce that tray's `output` (an oven-ready raw bake). The trays themselves are
    -- FREE kitchen equipment (like the serving tray / pizza box — never an item, never
    -- consumed): drag a tray card out of the prep station's equipment strip, rub the
    -- mix over it (coverage accrues with cursor travel, `rub_dist` metres = full),
    -- then drag the filled tray into the hotbar to collect its `output`. The oven then
    -- bakes it inside its `container_model` (set on the matching recipe). `raw_model`
    -- is the raw sheet/dough shown in the tray as it fills.
    baking = {
        mix_item  = "baking_mix",
        mix_model = "pickle_cake_mix_01",  -- the mix bowl that follows the cursor while rubbing
        rub_dist  = 1.2,                   -- metres of cursor travel over the tray to fill it
        trays = {
            { kind = "caketin",    label = "Cake Tin",    tray_model = "pickle_cake_container_01",
              output = "raw_cake",   raw_model = "pickle_cake_mix_pour_02", group = "Bakery" },
            { kind = "cookietray", label = "Cookie Tray", tray_model = "pickle_cookie_tray_01",
              output = "raw_cookie", raw_model = "pickle_cookie_01", slots = 6, group = "Bakery" },
        },
    },
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

-- ─── default cookable recipes (one per streamed 3-variant food model) ─────────

local DEFAULT_RECIPES = {
    -- The fryer batch models render a basketful, so one fry yields a serving of
    -- individual items (output_count) when collected cooked/burnt.
    { input = "raw_drumstick", station = "fryer", method = "fry", group = "Fast Food",
      raw = "pickle_fryer_drumstick_01", cooked = "pickle_fryer_drumstick_02", burnt = "pickle_fryer_drumstick_03",
      out_cooked = "cooked_drumstick", out_burnt = "burnt_drumstick", cook_ms = 15000, burn_ms = 15000,
      output_count = 4 },
    { input = "raw_fries", station = "fryer", method = "fry", group = "Fast Food",
      raw = "pickle_fryer_fries_01", cooked = "pickle_fryer_fries_02", burnt = "pickle_fryer_fries_03",
      out_cooked = "cooked_fries", out_burnt = "burnt_fries", cook_ms = 12000, burn_ms = 12000,
      output_count = 4 },
    { input = "raw_nuggets", station = "fryer", method = "fry", group = "Fast Food",
      raw = "pickle_fryer_nuggets_01", cooked = "pickle_fryer_nuggets_02", burnt = "pickle_fryer_nuggets_03",
      out_cooked = "cooked_nuggets", out_burnt = "burnt_nuggets", cook_ms = 12000, burn_ms = 12000,
      output_count = 20 },
    { input = "raw_beef_patty", station = "stovetop", method = "grill", group = "Fast Food",
      raw = "pickle_patty_beef_01", cooked = "pickle_patty_beef_02", burnt = "pickle_patty_beef_03",
      out_cooked = "cooked_beef_patty", out_burnt = "burnt_beef_patty", cook_ms = 18000, burn_ms = 15000,
      dual_sided = 1 },
    -- A fried chicken patty (its model is pickle_patty_friedchicken) — cooks in the
    -- fryer basket, not on the grill.
    { input = "raw_chicken_patty", station = "fryer", method = "fry", group = "Fast Food",
      raw = "pickle_patty_friedchicken_01", cooked = "pickle_patty_friedchicken_02", burnt = "pickle_patty_friedchicken_03",
      out_cooked = "cooked_chicken_patty", out_burnt = "burnt_chicken_patty", cook_ms = 18000, burn_ms = 15000 },
    -- Doughnuts are fried.
    { input = "raw_doughnut", station = "fryer", method = "fry", group = "Bakery",
      raw = "pickle_doughnut_01", cooked = "pickle_doughnut_02", burnt = "pickle_doughnut_03",
      out_cooked = "cooked_doughnut", out_burnt = "burnt_doughnut", cook_ms = 12000, burn_ms = 12000 },
    -- Cookies + cake bake inside the oven doors (on their own trays). The cookie
    -- dough bakes as a batch on its tray (the container rides along visually, never
    -- an item) — same container machinery as the cake tin.
    -- The cookie models render a six-slot tray-batch, so one raw tray yields six
    -- individual cookies (output_count) when collected — each carried/stacked as a
    -- single cookie (prep_models `cooked_cookie`), like the fryer batch servings.
    { input = "raw_cookie", station = "stovetop", method = "oven", group = "Bakery",
      raw = "pickle_cookie_01", cooked = "pickle_cookie_02", burnt = "pickle_cookie_03",
      container = "pickle_cookie_tray_01", output_count = 6,
      out_cooked = "cooked_cookie", out_burnt = "burnt_cookie", cook_ms = 20000, burn_ms = 18000 },
    -- Cake batter bakes as a thin sheet inside its container tray (the container
    -- rides along visually, never an item). pickle_cake_01..04 are the four whole
    -- flavored cakes the frosting finish tool produces — not cook states.
    { input = "raw_cake", station = "stovetop", method = "oven", group = "Bakery",
      raw = "pickle_cake_mix_pour_02", cooked = "pickle_cake_mix_pour_03", burnt = "pickle_cake_mix_pour_04",
      container = "pickle_cake_container_01",
      out_cooked = "cooked_cake", out_burnt = "burnt_cake", cook_ms = 30000, burn_ms = 25000 },
    -- Pizza bakes bare on the oven rack; the raw (topped) pizza is assembled at kitchen prep first.
    { input = "raw_pizza", station = "stovetop", method = "oven", group = "Pizza",
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
            -- how long (seconds) a collected cooked/burnt item of this recipe stays
            -- fresh in the tray before it spoils; NULL = use the global default
            -- (`cooked_expire_seconds` setting), 0 = never expires.
            `expire_seconds`     INT          DEFAULT NULL,
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
            -- UNIX seconds the row's items were cooked (freshness clock for expiration);
            -- set when the row is created, preserved as more are stacked onto it.
            `cooked_at`     BIGINT       NOT NULL DEFAULT 0,
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
            PRIMARY KEY (`id`),
            KEY `idx_rest_status` (`restaurant_id`, `status`)
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

    -- Optional per-recipe freshness window (expiration). Added in place for servers
    -- that predate the column; NULL means "use the global cooked_expire_seconds".
    local expCol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_recipes` LIKE 'expire_seconds'")
    if not expCol or #expCol == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_recipes` ADD COLUMN `expire_seconds` INT DEFAULT NULL")
    end

    -- The tray freshness clock. Added in place for servers that predate it.
    local caCol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_cooked_items` LIKE 'cooked_at'")
    if not caCol or #caCol == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_cooked_items` ADD COLUMN `cooked_at` BIGINT NOT NULL DEFAULT 0")
    end
    -- Backfill any row that still has no freshness clock (0) to "now" — both the
    -- one-time column add above and any pre-existing tray items — so existing cooked
    -- items get a fresh window on upgrade instead of an instant spoil (0 = never).
    -- Idempotent: new AddTray rows always store a non-zero cooked_at.
    MySQL.query.await("UPDATE `pickle_restaurant_cooked_items` SET `cooked_at` = UNIX_TIMESTAMP() WHERE `cooked_at` = 0")

    -- Recipe access groups. A recipe's optional `group` ("bakery", "pizza"…) limits
    -- it to restaurants that carry that group; NULL/'' = every restaurant. `group`
    -- is a MySQL reserved word — always backtick it in explicit SQL (SELECT * picks
    -- it up untouched).
    local gcol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_recipes` LIKE 'group'")
    if not gcol or #gcol == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_recipes` ADD COLUMN `group` VARCHAR(40) DEFAULT NULL")
    end

    -- The restaurant side of recipe access: a JSON array of the group names this
    -- restaurant carries. NULL/empty = only ungrouped content is available.
    local rgcol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurants` LIKE 'groups'")
    if not rgcol or #rgcol == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurants` ADD COLUMN `groups` JSON DEFAULT NULL")
    end

    -- POS price list variants: drinks are ONE item (`drink_item`) with the flavor as
    -- metadata, so per-flavor pricing needs a `variant` dimension on the menu key
    -- (item = the drink item, variant = the drinks[].output flavor key; '' for
    -- everything else). NOT NULL DEFAULT '' — never NULL — so the widened unique key
    -- upserts reliably (MySQL treats NULLs in unique keys as distinct).
    local vcol = MySQL.query.await("SHOW COLUMNS FROM `pickle_restaurant_menu` LIKE 'variant'")
    if not vcol or #vcol == 0 then
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_menu` ADD COLUMN `variant` VARCHAR(60) NOT NULL DEFAULT ''")
        MySQL.query.await(
            "ALTER TABLE `pickle_restaurant_menu` DROP INDEX `uniq_item`, ADD UNIQUE KEY `uniq_item` (`restaurant_id`, `item`, `variant`)")
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
    mergeListDefaults("condiments", "item")

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
    -- Back-fill any newly-added npc_customers sub-key (a new tunable in a later
    -- release) without clobbering an admin's edits. `models` is a list value inside
    -- the map — mergeMapDefaults only adds it if the whole key is missing, which is
    -- correct (an admin who edited the list keeps theirs).
    mergeMapDefaults("npc_customers")

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

    -- One-time: the cooked-item expiry default shipped as 0 (never) before it became
    -- 15 minutes. Bump servers still on the old 0 default up to the real default —
    -- flag-gated so an admin who deliberately sets 0 later isn't overridden.
    if not GetSetting("cooked_expire_default_seeded", false) then
        if (tonumber(GetSetting("cooked_expire_seconds", 0)) or 0) == 0 then
            SetSetting("cooked_expire_seconds", DEFAULT_SETTINGS.cooked_expire_seconds or 900)
        end
        SetSetting("cooked_expire_default_seeded", true)
    end

    -- One-time: the default NPC patience grew from 4 to 5 minutes. Bump a stored
    -- npc_customers map that still holds the OLD 240s default up to the new 300s —
    -- gated, and only when it's still exactly the old default, so an admin who tuned
    -- patience to any other value keeps theirs.
    if not GetSetting("npc_patience_default_seeded", false) then
        local npc = SettingsCache.npc_customers
        if type(npc) == "table" and (tonumber(npc.patience_seconds) or 0) == 240 then
            npc.patience_seconds = 300
            SetSetting("npc_customers", npc)
        end
        SetSetting("npc_patience_default_seeded", true)
    end

    -- One-time: the sprinkles finish shipped with a single generic "Sprinkles"
    -- flavor; it now offers picker variants (vanilla/chocolate) like frosting. Swap
    -- the lone legacy flavor on the stored sprinkles entry for the new default set —
    -- gated, and only when it still holds the old single "sprinkles" flavor, so an
    -- admin who edited the sprinkle flavors keeps theirs.
    if not GetSetting("sprinkle_flavors_seeded", false) then
        local fs = SettingsCache.finishes
        if type(fs) == "table" then
            local defFlavors
            for _, def in ipairs(DEFAULT_SETTINGS.finishes) do
                if def.tool == "sprinkles" then defFlavors = (def.targets[1] or {}).flavors end
            end
            local changed = false
            if defFlavors then
                for _, f in ipairs(fs) do
                    if f.tool == "sprinkles" then
                        for _, t in ipairs(f.targets or {}) do
                            local fl = t.flavors or {}
                            if #fl == 1 and fl[1].id == "sprinkles" then
                                t.flavors = defFlavors; changed = true
                            end
                        end
                    end
                end
            end
            if changed then SetSetting("finishes", fs) end
        end
        SetSetting("sprinkle_flavors_seeded", true)
    end

    -- One-time: doughnut variants collapsed into the single `cooked_doughnut` item —
    -- frosting/sprinkles are now build-stack METADATA, not separate output items. On
    -- a DB seeded with the old finishes config, repoint the frosting-doughnut target
    -- (output frosted_doughnut → cooked_doughnut) and the sprinkles target (item &
    -- output frosted_doughnut/sprinkled_doughnut → cooked_doughnut, + requires_finish
    -- so it still only applies over frosting). Only touches entries still holding the
    -- exact old defaults, so an admin's customised targets are left alone. (The cake
    -- target collapses the same way — see cake_finish_collapsed below.)
    if not GetSetting("doughnut_finish_collapsed", false) then
        local fs = SettingsCache.finishes
        if type(fs) == "table" then
            local changed = false
            for _, f in ipairs(fs) do
                if f.tool == "frosting" then
                    for _, t in ipairs(f.targets or {}) do
                        if t.item == "cooked_doughnut" and t.output == "frosted_doughnut" then
                            t.output = "cooked_doughnut"; changed = true
                        end
                    end
                elseif f.tool == "sprinkles" then
                    for _, t in ipairs(f.targets or {}) do
                        if t.item == "frosted_doughnut" and t.output == "sprinkled_doughnut" then
                            t.item, t.output, t.requires_finish = "cooked_doughnut", "cooked_doughnut", "frosting"
                            changed = true
                        end
                    end
                end
            end
            if changed then SetSetting("finishes", fs) end
        end
        SetSetting("doughnut_finish_collapsed", true)
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

    -- One-time: stamp default access groups onto the seeded assembly + finish
    -- entries so a fresh menu is organised (Fast Food / Pizza / Bakery). Only sets
    -- a group on an entry that still has none — an admin's own grouping is kept.
    if not GetSetting("food_groups_seeded", false) then
        local wantAsm = { burger = "Fast Food", cheeseburger = "Fast Food",
                          chicken_sandwich = "Fast Food", deluxe_burger = "Fast Food",
                          raw_pizza = "Pizza" }
        local asm = SettingsCache.assembly
        if type(asm) == "table" then
            local changed = false
            for _, a in ipairs(asm) do
                if (a.group == nil or a.group == "") and wantAsm[a.output] then
                    a.group = wantAsm[a.output]; changed = true
                end
            end
            if changed then SetSetting("assembly", asm) end
        end
        local fs = SettingsCache.finishes
        if type(fs) == "table" then
            local changed = false
            for _, f in ipairs(fs) do
                if (f.group == nil or f.group == "") and (f.tool == "frosting" or f.tool == "sprinkles") then
                    f.group = "Bakery"; changed = true
                end
            end
            if changed then SetSetting("finishes", fs) end
        end
        SetSetting("food_groups_seeded", true)
    end

    -- One-time: consolidate the burger family into ONE Burger with modifiers.
    -- A cheeseburger / deluxe burger that still holds its shipped components is
    -- retired (its extras are now customer modifiers on the base burger); an admin
    -- who customised the entry keeps it. The two surviving burger-family bases get
    -- the default modifier set if they have none.
    if not GetSetting("burger_consolidated", false) then
        local asm = SettingsCache.assembly
        if type(asm) == "table" then
            local function sameList(a, b)
                if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
                for i = 1, #a do if a[i] ~= b[i] then return false end end
                return true
            end
            local retire = {
                cheeseburger  = { "bun", "cooked_beef_patty", "cheese" },
                deluxe_burger = { "bun", "cooked_beef_patty", "cheese", "lettuce", "tomato", "pickle" },
            }
            local defMods
            for _, a in ipairs(DEFAULT_SETTINGS.assembly) do
                if a.output == "burger" then defMods = a.modifiers end
            end
            local kept, changed = {}, false
            for _, a in ipairs(asm) do
                if retire[a.output] and sameList(a.components, retire[a.output]) then
                    changed = true -- retire the still-default variant item
                else
                    kept[#kept + 1] = a
                    if (a.output == "burger" or a.output == "chicken_sandwich")
                        and (type(a.modifiers) ~= "table" or #a.modifiers == 0) and defMods then
                        a.modifiers = dec(json.encode(defMods), nil) -- independent copy
                        changed = true
                    end
                end
            end
            if changed then SetSetting("assembly", kept) end
        end
        SetSetting("burger_consolidated", true)
    end

    -- One-time (v2): guarantee the doughnut is ONE item. The v1 collapse only
    -- repointed the exact old defaults; this repoints ANY frosting/sprinkles target
    -- on a doughnut (or a legacy frosted_doughnut) to output cooked_doughnut, so no
    -- separate "Frosted Doughnut" sellable survives.
    if not GetSetting("doughnut_finish_collapsed_v2", false) then
        local fs = SettingsCache.finishes
        if type(fs) == "table" then
            local changed = false
            for _, f in ipairs(fs) do
                if f.tool == "frosting" or f.tool == "sprinkles" then
                    for _, t in ipairs(f.targets or {}) do
                        if t.item == "frosted_doughnut" then t.item = "cooked_doughnut"; changed = true end
                        if (t.item == "cooked_doughnut") and t.output ~= "cooked_doughnut" then
                            t.output = "cooked_doughnut"; changed = true
                        end
                    end
                end
            end
            if changed then SetSetting("finishes", fs) end
        end
        SetSetting("doughnut_finish_collapsed_v2", true)
    end

    -- One-time: collapse the cake the same way the doughnut collapsed — a frosted
    -- ("decorated") cake is NOT a separate item; it stays `cooked_cake` with the
    -- frosting flavor as build-stack metadata, so the ordering terminal lists ONE
    -- "Cake" with a pick-one frosting flavor. Repoint any frosting target on a cake
    -- (output decorated_cake → cooked_cake) so no separate "Decorated Cake" sellable
    -- survives; an admin who repointed it elsewhere keeps theirs.
    if not GetSetting("cake_finish_collapsed", false) then
        local fs = SettingsCache.finishes
        if type(fs) == "table" then
            local changed = false
            for _, f in ipairs(fs) do
                if f.tool == "frosting" then
                    for _, t in ipairs(f.targets or {}) do
                        if t.item == "cooked_cake" and t.output == "decorated_cake" then
                            t.output = "cooked_cake"; changed = true
                        end
                    end
                end
            end
            if changed then SetSetting("finishes", fs) end
        end
        SetSetting("cake_finish_collapsed", true)
    end
end

local function SeedRecipes()
    -- Insert any default recipe that isn't present yet (keyed by the unique
    -- input_item). This means newly-added defaults show up on the next restart
    -- without wiping the table or overwriting recipes an admin has customised.
    for _, r in ipairs(DEFAULT_RECIPES) do
        MySQL.insert.await([[
            INSERT INTO pickle_restaurant_recipes
                (input_item, station, raw_model, cooked_model, burnt_model, output_cooked_item, output_burnt_item, cook_ms, burn_ms, dual_sided, method, output_count, container_model, `group`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE input_item = input_item
        ]], { r.input, r.station, r.raw, r.cooked, r.burnt, r.out_cooked, r.out_burnt, r.cook_ms, r.burn_ms, r.dual_sided or 0, r.method or "grill", r.output_count or 1, r.container, r.group })
    end

    -- One-time: stamp default access groups (Fast Food / Bakery / Pizza) onto the
    -- default recipes on servers seeded before recipes were grouped. Only sets a
    -- group on a row that still has none, so an admin's own grouping is preserved.
    if not GetSetting("default_groups_seeded", false) then
        for _, r in ipairs(DEFAULT_RECIPES) do
            if r.group then
                MySQL.update.await(
                    "UPDATE pickle_restaurant_recipes SET `group` = ? WHERE input_item = ? AND (`group` IS NULL OR `group` = '')",
                    { r.group, r.input })
            end
        end
        SetSetting("default_groups_seeded", true)
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

    -- One-time: cookies now bake inside a tray like the cake tin. Point the stored
    -- cookie recipe at its container tray, but ONLY while it still has none, so an
    -- admin who set (or cleared) a container in the recipe editor keeps theirs.
    if not GetSetting("cookie_container_seeded", false) then
        MySQL.update.await([[
            UPDATE pickle_restaurant_recipes
               SET container_model = ?
             WHERE input_item = 'raw_cookie' AND (container_model IS NULL OR container_model = '')
        ]], { "pickle_cookie_tray_01" })
        SetSetting("cookie_container_seeded", true)
    end

    -- One-time: a cookie tray now bakes into six cookies. Bump the stored cookie
    -- recipe's yield, but ONLY while it still holds the old single-cookie default, so
    -- an admin who set their own yield keeps it. (output_count_seeded already ran, so
    -- this needs its own flag.)
    if not GetSetting("cookie_yield_seeded", false) then
        MySQL.update.await([[
            UPDATE pickle_restaurant_recipes
               SET output_count = 6
             WHERE input_item = 'raw_cookie' AND output_count = 1
        ]])
        SetSetting("cookie_yield_seeded", true)
    end

    -- One-time: switch the Supplies pool from buying finished cake batter / cookie
    -- dough to buying the shared baking mix. Only drops raw_cake/raw_cookie while
    -- they still hold their original default costs (6 / 2) — an admin who repriced
    -- either owns it and keeps it. Always ensures a baking_mix cost exists.
    if not GetSetting("baking_mix_seeded", false) then
        local costs = GetSetting("ingredient_costs", {})
        if type(costs) == "table" then
            if tonumber(costs.raw_cake) == 6 then costs.raw_cake = nil end
            if tonumber(costs.raw_cookie) == 2 then costs.raw_cookie = nil end
            if costs.baking_mix == nil then costs.baking_mix = 4 end
            SetSetting("ingredient_costs", costs)
        end
        SetSetting("baking_mix_seeded", true)
    end

    -- One-time: the chicken patty is FRIED, so move it from the grill to the fryer
    -- on servers seeded with the old stovetop/grill default — only while the row
    -- still holds that exact default, so an admin who re-stationed it keeps theirs.
    if not GetSetting("chicken_patty_fryer_seeded", false) then
        MySQL.update.await([[
            UPDATE pickle_restaurant_recipes
               SET station = 'fryer', method = 'fry'
             WHERE input_item = 'raw_chicken_patty' AND station = 'stovetop' AND method = 'grill'
        ]])
        SetSetting("chicken_patty_fryer_seeded", true)
    end
end

-- Wipe every recipe and re-insert the built-in defaults verbatim (the admin
-- "Reset all recipes" action). Unlike SeedRecipes (which only fills gaps), this
-- deliberately discards customisations. DEFAULT_RECIPES already holds the
-- corrected cake/chicken models, so no post-insert backfills are needed.
function ResetRecipesToDefault()
    MySQL.query.await("DELETE FROM pickle_restaurant_recipes")
    for _, r in ipairs(DEFAULT_RECIPES) do
        MySQL.insert.await([[
            INSERT INTO pickle_restaurant_recipes
                (input_item, station, raw_model, cooked_model, burnt_model, output_cooked_item, output_burnt_item, cook_ms, burn_ms, dual_sided, method, output_count, container_model, `group`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], { r.input, r.station, r.raw, r.cooked, r.burnt, r.out_cooked, r.out_burnt, r.cook_ms, r.burn_ms, r.dual_sided or 0, r.method or "grill", r.output_count or 1, r.container, r.group })
    end
    LoadRecipes()
end

function LoadRecipes()
    RecipeCache, RecipeByInput, RecipeByOutput = {}, {}, {}
    local rows = MySQL.query.await("SELECT * FROM pickle_restaurant_recipes") or {}
    for _, row in ipairs(rows) do
        RecipeCache[#RecipeCache + 1] = row
        RecipeByInput[row.input_item] = row
        if row.output_cooked_item and row.output_cooked_item ~= "" then
            RecipeByOutput[row.output_cooked_item] = row
        end
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
                { item = row.item, cheese = cheese, count = row.count, metas = dec(row.metadata, {}),
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
    for _, r in ipairs(RecipeCache) do add(r.group) end
    for _, a in ipairs(GetSetting("assembly", {})) do add(a.group) end
    for _, d in ipairs(GetSetting("drinks", {})) do add(d.group) end
    for _, f in ipairs(GetSetting("finishes", {})) do add(f.group) end
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
    for _, a in ipairs(GetSetting("assembly", {})) do
        if a.output == item then
            local sum = 0
            for _, c in ipairs(a.components or {}) do sum = sum + ResolveItemCost(c, seen) end
            return sum
        end
    end
    -- A baking-tray output (raw_cake / raw_cookie) is produced by rubbing the shared
    -- baking mix into a free tray, so it costs one baking mix.
    local baking = GetSetting("baking", {})
    if type(baking) == "table" then
        for _, t in ipairs(baking.trays or {}) do
            if t.output == item then return ResolveItemCost(baking.mix_item, seen) end
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
    for _, a in ipairs(GetSetting("assembly", {})) do
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
    if not ItemExists(r.input_item) then missing[#missing + 1] = r.input_item end
    if not IsAssemblyComponent(r.output_cooked_item) and not ItemExists(r.output_cooked_item) then
        missing[#missing + 1] = r.output_cooked_item
    end
    return missing
end

function IsRecipeValid(r) return #RecipeMissingItems(r) == 0 end

-- How a recipe is cooked: "grill" (cooktop surface), "oven" (inside a door), or
-- "fry" (fryer basket). Defaults to grill for legacy/untagged rows.
function RecipeMethod(r) return (r and r.method) or "grill" end

-- Drinks / assembly entries reference items too; same validity rules apply.
local function drinkMissing(d)
    -- only the cup (input) is a real item — the output is a flavor KEY: every
    -- poured drink collects as the ONE `drink_item` item, flavor as metadata
    local missing = {}
    if not ItemExists(d.input) then missing[#missing + 1] = d.input end
    return missing
end

local function assemblyMissing(a)
    -- the output is a kitchen product (tray-held) — never required to be an installed
    -- item (raw_pizza isn't one). A component is a real consumed item UNLESS it's itself
    -- a kitchen PRODUCT (a cooked patty pulled from the cooked pool) — those are valid
    -- without being installed, exactly like the recipe outputs that make them.
    local missing = {}
    for _, comp in ipairs(a.components or {}) do
        if not ItemExists(comp) and not IsProductItem(comp) then missing[#missing + 1] = comp end
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
        copy.defaultPrice = MarkupPrice(ResolveItemCost(r.output_cooked_item))
        out[#out + 1] = copy
    end
    return out
end

function AnnotateDrinks()
    -- Every poured drink collects as the ONE generic drink item; if that item
    -- isn't installed in the framework inventory NO drink can be sold (the POS
    -- filters them all out), so flag it so the admin panel can say why.
    local drinkInstalled = ItemExists(GetSetting("drink_item", "drink"))
    local out = {}
    for _, d in ipairs(GetSetting("drinks", {})) do
        local missing = drinkMissing(d)
        local copy = {}; for k, v in pairs(d) do copy[k] = v end
        copy.valid, copy.missing = #missing == 0, missing
        copy.drink_item_installed = drinkInstalled
        copy.defaultPrice = MarkupPrice(ResolveItemCost(d.input))
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
        copy.defaultPrice = MarkupPrice(ResolveItemCost(a.output))
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
            -- a target/output that's a tray PRODUCT is valid without being installed
            if not IsProductItem(t.item)   and not ItemExists(t.item)   then missing[#missing + 1] = t.item end
            if not IsProductItem(t.output) and not ItemExists(t.output) then missing[#missing + 1] = t.output end
        end
        local copy = {}; for k, v in pairs(f) do copy[k] = v end
        copy.valid, copy.missing = #missing == 0, missing
        out[#out + 1] = copy
    end
    return out
end

-- Diagnostic: a finish tool card only appears on the prep bar when its tool AND
-- at least one target's (item + output) are all installed inventory items — so a
-- tool you're carrying still stays hidden if its target/output items are missing.
-- Prints exactly what each finish tool is missing so a hidden card can be traced
-- to the item(s) still needing /restaurants_items + install.
CreateThread(function()
    while not RestaurantsReady do Wait(200) end
    RegisterCommand("restaurants_finishes", function(src)
        if src ~= 0 and not IsPlayerAdmin(src) then return ShowNotification(src, _L("no_permission")) end
        local function line(s) print(s); if src ~= 0 then ShowNotification(src, s) end end
        line("[pickle_restaurants] Finish tools:")
        for _, f in ipairs(GetSetting("finishes", {})) do
            local toolOk = ItemExists(f.tool)
            line((" • %s  tool=%s%s"):format(f.tool or "?", tostring(f.tool), toolOk and " ✓" or " ✗ NOT INSTALLED"))
            for _, t in ipairs(f.targets or {}) do
                -- a tray PRODUCT (recipe/assembly/finish output) is valid uninstalled
                local iOk = ItemExists(t.item)   and " ✓" or (IsProductItem(t.item)   and " ✓ (cooked item)" or " ✗ NOT INSTALLED")
                local oOk = ItemExists(t.output) and " ✓" or (IsProductItem(t.output) and " ✓ (cooked item)" or " ✗ NOT INSTALLED")
                line(("     target %s%s  ->  %s%s"):format(tostring(t.item), iOk, tostring(t.output), oOk))
            end
        end
    end, false)
end)

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
    o.status = status
    MySQL.update("UPDATE pickle_restaurant_orders SET status = ?, closed_at = NOW() WHERE id = ?",
        { status, orderId })
    OrderCache[restaurantId][orderId] = nil
    return true
end

-- Drop a restaurant's entire order state (used when a restaurant is deleted).
function ClearOrders(restaurantId)
    OrderCache[restaurantId] = nil
    NextTicket[restaurantId] = nil
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
            -- a meal made in a pizza box (flag on the first layer) is a different
            -- variation from the same pizza arranged on a serving tray
            if l.box then
                part = part .. "^box"
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
        e = { item = item, cheese = cheese, count = 0, metas = {}, cookedAt = os.time() }
        TrayCache[rid][identifier][key] = e
    end
    e.metas = e.metas or {}
    e.count = e.count + count
    -- EVERY add restamps the row's freshness clock: the newest instance is fresh,
    -- and the row expires as one unit — so topping a slot up gives the whole stack
    -- the full window again instead of inheriting the oldest instance's leftovers.
    e.cookedAt = os.time()
    for _ = 1, count do e.metas[#e.metas + 1] = meta or false end
    MySQL.update("INSERT INTO pickle_restaurant_cooked_items (restaurant_id, identifier, item, cheese, count, metadata, cooked_at) "
        .. "VALUES (?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE count = count + VALUES(count), metadata = VALUES(metadata), cooked_at = VALUES(cooked_at)",
        { rid, identifier, item, cheese, count, json.encode(e.metas), e.cookedAt })
    MarkOrdersDirty(rid)
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
                    item = e.item, cheese = e.cheese, count = groups[s].count,
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
                n = n + GetTrayCount(rid, identifier, item, e.cheese, matchSig)
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
                local m = TrayTopMeta(rid, identifier, item, e.cheese, matchSig)
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
-- any cheese, LIFO within each row). Returns a list of { cheese, meta } for every
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
                local cheese = e.cheese
                while #taken < count and GetTrayCount(rid, identifier, item, cheese, matchSig) > 0 do
                    local meta = TrayTopMeta(rid, identifier, item, cheese, matchSig)
                    if not RemoveTray(rid, identifier, item, cheese, 1, matchSig) then break end
                    taken[#taken + 1] = { cheese = cheese, meta = meta }
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
-- identifier/cheese, LIFO within each row). Returns { {cheese, meta}, … } for every
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
                local cheese = e.cheese
                local i = e.count or 0
                while #taken < count and i >= 1 do
                    local m = e.metas and e.metas[i]
                    local mt = (type(m) == "table") and m or nil
                    if match(mt) then
                        local sig = traySigAt(e, i)
                        if RemoveTray(rid, identifier, item, cheese, 1, sig) then
                            taken[#taken + 1] = { cheese = cheese, meta = mt }
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
    for _, a in ipairs(GetSetting("assembly", {})) do
        if a.output == item then return true end
    end
    for _, f in ipairs(GetSetting("finishes", {})) do
        for _, t in ipairs(f.targets or {}) do
            if t.output == item then return true end
        end
    end
    -- a baking-tray output (raw_cake / raw_cookie) is a tray-only uncooked
    -- intermediate (like raw_pizza) — a kitchen product, never a carried item
    local baking = GetSetting("baking", {})
    if type(baking) == "table" then
        for _, t in ipairs(baking.trays or {}) do
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
    for i, d in ipairs(GetSetting("drinks", {})) do
        -- only the cup (input) must be an installed item — the output is a flavor
        -- KEY (poured drinks collect as the one `drink_item` item, flavor in meta)
        if ItemExists(d.input) then
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
    -- Finish tools ship with only their valid targets: the tool must be a real
    -- (consumed) inventory item, but a target/output may be a tray-only PRODUCT
    -- (a frosted doughnut is a finish output, never installed) — FinishItemOk. An
    -- entry with no surviving targets is dropped entirely.
    local finishes = {}
    for _, f in ipairs(GetSetting("finishes", {})) do
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

    -- Condiments: shipped only when the bottle's inventory item is real (consumed) and
    -- both of its props are configured. An entry missing any of these is dropped — the
    -- client's applicator would have nothing to spawn otherwise.
    local condiments = {}
    for _, c in ipairs(GetSetting("condiments", {})) do
        if c.item and ItemExists(c.item) and c.container_model and c.applied_model then
            condiments[#condiments + 1] = c
        end
    end

    -- Baking mix + trays: shipped only when the shared mix is a real (consumed)
    -- inventory item; individual trays are dropped unless their output is a usable
    -- item/product (raw_cake/raw_cookie are real items — needed for bakeTrayToInv).
    local baking = nil
    do
        local b = GetSetting("baking", {})
        if type(b) == "table" and b.mix_item and ItemExists(b.mix_item) then
            local trays = {}
            for _, t in ipairs(b.trays or {}) do
                if t.kind and t.tray_model and FinishItemOk(t.output) then trays[#trays + 1] = t end
            end
            if #trays > 0 then
                baking = { mix_item = b.mix_item, mix_model = b.mix_model,
                           rub_dist = b.rub_dist, trays = trays }
            end
        end
    end

    local payload = { restaurants = {}, props = {}, recipes = recipes, settings = {
        drinks   = drinks,
        assembly = assembly,
        finishes = finishes,
        condiments = condiments,
        baking   = baking,
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
        SeedRecipes()
        LoadRecipes()
        LoadRestaurants()
        LoadProps()
        LoadEmployees()
        LoadStock()
        LoadOrders()
        LoadCookedItems()
        RestaurantsReady = true
        debugPrint(("Booted: %d restaurants, %d props, %d recipes."):format(
            #BuildSyncPayload().restaurants, #BuildSyncPayload().props, #RecipeCache))
        -- Push to anyone already connected (resource restart mid-session).
        SyncToClient(-1)
    end)
end)
