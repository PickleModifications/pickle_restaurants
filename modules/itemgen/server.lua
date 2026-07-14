-- =============================================
--  modules/itemgen | server.lua
--  Derives every inventory item referenced by the current recipes, drinks,
--  assembly recipes and restaurant menus, then writes ready-to-install item
--  definitions for ox_inventory, ESX (SQL) and QBCore. Admin-run so the export
--  always reflects the *live* in-game configuration.
--
--    /restaurants_items            (admin command, in-game or server console)
--
--  Output lands in this resource's generated_items/ folder.
-- =============================================

-- ─── known defaults so generated labels/weights look sensible ─────────────────
-- These only seed nicer labels/weights; any item not listed still exports with
-- a humanised label and a default weight.

local KNOWN = {
    raw_drumstick        = { label = "Raw Drumstick",        weight = 220 },
    raw_fries            = { label = "Raw Cut Fries",        weight = 180 },
    raw_nuggets          = { label = "Raw Nuggets",          weight = 180 },
    raw_beef_patty       = { label = "Raw Beef Patty",       weight = 220 },
    raw_chicken_patty    = { label = "Raw Chicken Patty",    weight = 220 },
    cooked_drumstick     = { label = "Fried Drumstick",      weight = 220, hunger = 150000 },
    cooked_fries         = { label = "Fries",                weight = 180, hunger = 120000 },
    cooked_nuggets       = { label = "Chicken Nuggets",      weight = 180, hunger = 120000 },
    cooked_beef_patty    = { label = "Beef Patty",           weight = 220, hunger = 100000 },
    cooked_chicken_patty = { label = "Fried Chicken Patty",  weight = 220, hunger = 100000 },
    burnt_drumstick      = { label = "Burnt Drumstick",      weight = 220 },
    burnt_fries          = { label = "Burnt Fries",          weight = 180 },
    burnt_nuggets        = { label = "Burnt Nuggets",        weight = 180 },
    burnt_beef_patty     = { label = "Burnt Beef Patty",     weight = 220 },
    burnt_chicken_patty  = { label = "Burnt Chicken Patty",  weight = 220 },
    raw_doughnut         = { label = "Raw Doughnut",         weight = 150 },
    cooked_doughnut      = { label = "Doughnut",             weight = 150, hunger = 120000 },
    burnt_doughnut       = { label = "Burnt Doughnut",       weight = 150 },
    raw_cookie           = { label = "Cookie Dough",         weight = 120 },
    cooked_cookie        = { label = "Cookie",               weight = 120, hunger = 90000  },
    burnt_cookie         = { label = "Burnt Cookie",         weight = 120 },
    raw_cake             = { label = "Cake Batter",          weight = 400 },
    baking_mix           = { label = "Baking Mix",           weight = 400 },
    cooked_cake          = { label = "Cake",                 weight = 400, hunger = 200000 },
    burnt_cake           = { label = "Burnt Cake",           weight = 400 },
    lettuce              = { label = "Lettuce",              weight = 80  },
    tomato               = { label = "Tomato",               weight = 90  },
    pickle               = { label = "Pickle",               weight = 40  },
    deluxe_burger        = { label = "Deluxe Burger",        weight = 420, hunger = 300000 },
    pizza_dough          = { label = "Pizza Dough",          weight = 300 },
    pizza_sauce          = { label = "Pizza Sauce",          weight = 100 },
    pizza_cheese         = { label = "Shredded Cheese",      weight = 120 },
    pepperoni            = { label = "Pepperoni",            weight = 80  },
    raw_pizza            = { label = "Uncooked Pizza",       weight = 500 },
    cooked_pizza         = { label = "Pizza",                weight = 500, hunger = 350000 },
    burnt_pizza          = { label = "Burnt Pizza",          weight = 500 },
    frosting             = { label = "Frosting",             weight = 100 },
    sprinkles            = { label = "Sprinkles",            weight = 40  },
    frosted_doughnut     = { label = "Frosted Doughnut",     weight = 160, hunger = 130000 },
    sprinkled_doughnut   = { label = "Sprinkled Doughnut",   weight = 160, hunger = 135000 },
    decorated_cake       = { label = "Decorated Cake",       weight = 420, hunger = 220000 },
    empty_cup            = { label = "Empty Cup",            weight = 100 },
    soda                 = { label = "Classic Cola",         weight = 300, thirst = 200000 },
    water                = { label = "Pure Aqua",            weight = 300, thirst = 250000 },
    lemonade             = { label = "Lemonade Bliss",       weight = 300, thirst = 200000 },
    diet_cola            = { label = "Diet Cola",            weight = 300, thirst = 200000 },
    grape_soda           = { label = "Grape Zap",            weight = 300, thirst = 200000 },
    coffee               = { label = "Coffee",               weight = 300, thirst = 150000 },
    bun                  = { label = "Burger Bun",           weight = 120 },
    cheese               = { label = "Cheese Slice",         weight = 60  },
    burger               = { label = "Burger",               weight = 350, hunger = 250000 },
    cheeseburger         = { label = "Cheeseburger",         weight = 380, hunger = 280000 },
    chicken_sandwich     = { label = "Chicken Sandwich",     weight = 350, hunger = 250000 },
    meal                 = { label = "Meal",                 weight = 800, hunger = 400000 },
    drink                = { label = "Restaurant Drink",     weight = 300, thirst = 200000 },
    restaurant_bag       = { label = "Restaurant Bag",       weight = 800, hunger = 300000 },
    receipt              = { label = "Receipt",              weight = 10 },
}

local DEFAULT_WEIGHT = 200

-- ─── retired items kept for a grace release ───────────────────────────────────
-- Outputs no code references anymore after various one-item consolidations
-- (collapsed doughnut/cake/burger variants, retired intermediates). Exported one
-- more release so ox_inventory doesn't PURGE legacy stacks players still hold.
-- Stored as a self-seeded `itemgen_retained_items` setting so it's admin-visible
-- config before it sunsets (a later release empties it). The list literal here is
-- the seed only — read the setting at generate time.
local RETAIN_SEED = { "frosted_doughnut", "sprinkled_doughnut", "raw_pizza", "cheeseburger", "deluxe_burger", "decorated_cake", "raw_cake", "raw_cookie" }

local function retainedItems()
    local r = GetSetting("itemgen_retained_items", nil)
    if type(r) ~= "table" then
        r = RETAIN_SEED
        SetSetting("itemgen_retained_items", r)
    end
    return r
end

-- ─── helpers ──────────────────────────────────────────────────────────────────

local function humanize(name)
    local s = (name or ""):gsub("_", " ")
    return (s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

-- Cook outputs that only ever exist to be assembled into something else (a cooked
-- patty → burger) are tray-only intermediates, never standalone inventory items.
-- Derived rather than hardcoded: an output tray-only iff it's an assembly component
-- (its burnt sibling too — burnt food is never handed out), MINUS anything a
-- restaurant sells directly (safety valve: never drop a sold item from the export).
local function trayOnlyOutputs(menuItems)
    local set = {}
    for _, r in ipairs(RecipeCache) do
        if IsAssemblyComponent(r.output_cooked_item) then
            set[r.output_cooked_item] = true
            if r.output_burnt_item and r.output_burnt_item ~= "" then set[r.output_burnt_item] = true end
        end
    end
    for it in pairs(menuItems or {}) do set[it] = nil end
    return set
end

-- Build a de-duplicated, sorted list of every item the system references.
local function collectItems()
    -- Menu items are queried FIRST so the tray-only derivation can exempt anything
    -- a restaurant sells directly.
    local menuItems = {}
    local menu = MySQL.query.await("SELECT DISTINCT item FROM pickle_restaurant_menu") or {}
    for _, m in ipairs(menu) do if m.item and m.item ~= "" then menuItems[m.item] = true end end

    local trayOnly = trayOnlyOutputs(menuItems)
    local set = {}
    local function add(n) if n and n ~= "" and not trayOnly[n] then set[n] = true end end
    local assembled = {}
    for _, a in ipairs(GetAssembly()) do assembled[a.output] = true end
    -- bake-tray outputs (raw_cake / raw_cookie) are tray-only uncooked intermediates
    -- too — produced by rubbing a fill tool's mix into a tray, never carried — so
    -- exclude them from the carried-input export (grace-retained one release instead)
    local bakeOnly = {}
    for _, b in ipairs(GetBakingList()) do
        for _, t in ipairs(b.trays or {}) do if t.output then bakeOnly[t.output] = true end end
    end

    for _, r in ipairs(RecipeCache) do
        -- an ASSEMBLED cook input (raw_pizza) or a bake-tray output (raw_cookie) is
        -- tray-only, never an item — you build/fill it at prep and bake it; only true
        -- raw inputs are carried as items
        if not assembled[r.input_item] and not bakeOnly[r.input_item] then add(r.input_item) end
        add(r.output_cooked_item); add(r.output_burnt_item)
    end
    -- Drinks are ONE generic item (`drink_item`, "Restaurant Drink") — the flavor
    -- rides as metadata, so per-flavor `output` keys aren't items anymore. Only the
    -- cup (input) and the generic item export. GRACE: keep exporting the flavor
    -- outputs one release so legacy stacks players still hold aren't purged — drop
    -- the `add(d.output)` (and their KNOWN rows) once the window has passed.
    for _, d in ipairs(GetDrinks()) do add(d.input); add(d.output) end
    add(GetSetting("drink_item", "drink"))
    -- (no lid item: the cup lid is kitchen equipment — cups come with lids)
    for _, a in ipairs(GetAssembly()) do
        -- an assembled-but-uncooked INTERMEDIATE (raw_pizza: an assembly output that
        -- is some recipe's input) is never an item — it stays in the cooked-items
        -- tray, metadata intact, until it's cooked into the real output item
        if not RecipeByInput[a.output] then add(a.output) end
        for _, c in ipairs(a.components or {}) do add(c) end
    end
    -- bag foods: every bag food collapses to the ONE bag item (per-food variants are
    -- NEVER separate items — one-item consolidation), so export the bag item once
    -- plus each food's components. Modifier items ride along too. `display_item`s are
    -- NOT exported (they must already be installed to be picked).
    add(BagItemName())
    for _, cr in ipairs(GetCrafts()) do
        for _, c in ipairs(cr.components or {}) do add(c) end
        for _, m in ipairs(cr.modifiers or {}) do if m.item then add(m.item) end end
    end
    -- decorate tools (frosting…) + their targets/outputs
    for _, f in ipairs(GetFinishes()) do
        add(f.tool)
        for _, t in ipairs(f.targets or {}) do add(t.item); add(t.output) end
    end
    -- layer tools (ketchup / mustard / mayo): each is a real consumed pool item,
    -- laid as a sauce layer on a build stack (the applied prop is visual-only, no item)
    for _, c in ipairs(GetCondiments()) do add(c.item) end
    -- fill tools (baking mix): each mix is a real (consumed) raw ingredient — a recipe
    -- input the loop above wouldn't pick up on its own. (The trays are free equipment,
    -- their outputs are tray-only intermediates — see bakeOnly above.)
    for _, b in ipairs(GetBakingList()) do add(b.mix_item) end
    -- any item mapped to a prep prop is a real item too (sprinkles etc., optional
    -- toppings that aren't a required component of any recipe)
    for item in pairs(GetPrepModels()) do add(item) end
    for it in pairs(menuItems) do add(it) end
    -- the serving-tray meal item (kitchen prep) isn't a recipe/assembly output
    add(GetSetting("meal_item", "meal"))
    -- the POS receipt handed to a paying customer (metadata carries the ticket)
    add(GetSetting("receipt_item", "receipt"))
    -- retired outputs: no longer referenced, exported one more release so players'
    -- existing stacks aren't purged (see retainedItems above)
    for _, n in ipairs(retainedItems()) do add(n) end

    -- Admin-authored ingredient cosmetics take precedence over the KNOWN seed table,
    -- so a custom ingredient exports with its own label.
    local ingCos = {}
    for _, ing in ipairs(GetIngredientsCfg()) do if ing.item then ingCos[ing.item] = ing end end

    local list = {}
    for name in pairs(set) do
        local k = KNOWN[name] or {}
        local ing = ingCos[name]
        list[#list + 1] = {
            name   = name,
            label  = (ing and ing.label) or k.label or humanize(name),
            weight = (ing and ing.weight) or k.weight or DEFAULT_WEIGHT,
            hunger = (ing and ing.hunger) or k.hunger,
            thirst = (ing and ing.thirst) or k.thirst,
        }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- ─── format builders ──────────────────────────────────────────────────────────

local HEADER = "-- Generated by pickle_restaurants — items derived from current recipes, drinks, assembly & menus.\n"
    .. "-- Re-run /restaurants_items after changing your configuration to regenerate.\n\n"

local function buildOx(items)
    local lines = { HEADER, "-- Paste these entries into ox_inventory/data/items.lua\n" }
    for _, it in ipairs(items) do
        local parts = {
            ("    ['%s'] = {"):format(it.name),
            ("        label  = '%s',"):format(it.label:gsub("'", "\\'")),
            ("        weight = %d,"):format(it.weight),
            "        stack  = true,",
            "        close  = true,",
        }
        if it.hunger or it.thirst then
            parts[#parts + 1] = "        client = {"
            parts[#parts + 1] = "            status = {" ..
                (it.hunger and (" hunger = " .. it.hunger .. ",") or "") ..
                (it.thirst and (" thirst = " .. it.thirst .. ",") or "") .. " },"
            parts[#parts + 1] = it.thirst
                and "            anim = { dict = 'mp_player_intdrink', clip = 'loop_bottle' }, usetime = 2500,"
                or  "            anim = { dict = 'mp_player_inteat@burger', clip = 'mp_player_int_eat_burger' }, usetime = 2500,"
            parts[#parts + 1] = "        },"
            parts[#parts + 1] = "        consume = 1,"
        end
        parts[#parts + 1] = "    },"
        lines[#lines + 1] = table.concat(parts, "\n")
    end
    return table.concat(lines, "\n") .. "\n"
end

local function buildEsxSql(items)
    local lines = {
        "-- Generated by pickle_restaurants — ESX `items` table inserts.",
        "-- Re-run /restaurants_items after changing your configuration to regenerate.",
        "",
    }
    for _, it in ipairs(items) do
        lines[#lines + 1] = ("INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES ('%s', '%s', %d, 0, 1) ON DUPLICATE KEY UPDATE `label` = VALUES(`label`);")
            :format(it.name, it.label:gsub("'", "''"), math.max(1, math.floor(it.weight / 100)))
    end
    return table.concat(lines, "\n") .. "\n"
end

local function buildQbCore(items)
    local lines = { HEADER, "-- Paste these entries into qb-core/shared/items.lua\n" }
    for _, it in ipairs(items) do
        local useful = (it.hunger or it.thirst) and "true" or "true"
        lines[#lines + 1] = ("    ['%s'] = { name = '%s', label = '%s', weight = %d, type = 'item', image = '%s.png', unique = false, useable = %s, shouldClose = true, combinable = nil, description = '%s' },")
            :format(it.name, it.name, it.label:gsub("'", "\\'"), it.weight, it.name, useful, it.label:gsub("'", "\\'"))
    end
    return table.concat(lines, "\n") .. "\n"
end

-- ─── export ───────────────────────────────────────────────────────────────────

function GenerateItemFiles()
    local items = collectItems()
    local res = GetCurrentResourceName()
    SaveResourceFile(res, "generated_items/ox_inventory.lua", buildOx(items), -1)
    SaveResourceFile(res, "generated_items/esx_items.sql",    buildEsxSql(items), -1)
    SaveResourceFile(res, "generated_items/qbcore_items.lua", buildQbCore(items), -1)
    SaveResourceFile(res, "generated_items/README.md", ([[# Generated restaurant items

These files were generated from the **current** recipes, drinks, assembly recipes
and restaurant menus configured in-game. They contain every inventory item the
restaurant system references. Re-run `/restaurants_items` after editing your
configuration to regenerate them.

%d items were exported.

## Install (pick the one matching your inventory)

- **ox_inventory** – copy the entries from `ox_inventory.lua` into
  `ox_inventory/data/items.lua`. Add a matching `<name>.png` to
  `ox_inventory/web/images/` for each item.
- **ESX (legacy `items` table)** – import `esx_items.sql` into your database.
- **QBCore** – copy the entries from `qbcore_items.lua` into
  `qb-core/shared/items.lua`, and add `<name>.png` to `qb-inventory/html/images/`.

Items already present in your inventory are safe to skip; the ESX SQL uses
`ON DUPLICATE KEY UPDATE` so re-importing only refreshes labels.
]]):format(#items), -1)
    return #items
end

CreateThread(function()
    while not RestaurantsReady do Wait(200) end
    RegisterCommand("restaurants_items", function(src)
        if src ~= 0 and not IsPlayerAdmin(src) then
            return ShowNotification(src, _L("no_permission"))
        end
        local count = GenerateItemFiles()
        local msg = ("[pickle_restaurants] Exported %d items to generated_items/ (ox_inventory.lua, esx_items.sql, qbcore_items.lua)."):format(count)
        print(msg)
        if src ~= 0 then ShowNotification(src, _L("items_exported", count)) end
    end, false)
end)
