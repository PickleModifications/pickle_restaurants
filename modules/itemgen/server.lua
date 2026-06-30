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
    decorated_cake       = { label = "Decorated Cake",       weight = 420, hunger = 220000 },
    empty_cup            = { label = "Empty Cup",            weight = 100 },
    soda                 = { label = "Soda",                 weight = 300, thirst = 200000 },
    bun                  = { label = "Burger Bun",           weight = 120 },
    cheese               = { label = "Cheese Slice",         weight = 60  },
    burger               = { label = "Burger",               weight = 350, hunger = 250000 },
    cheeseburger         = { label = "Cheeseburger",         weight = 380, hunger = 280000 },
    chicken_sandwich     = { label = "Chicken Sandwich",     weight = 350, hunger = 250000 },
}

local DEFAULT_WEIGHT = 200

-- ─── helpers ──────────────────────────────────────────────────────────────────

local function humanize(name)
    local s = (name or ""):gsub("_", " ")
    return (s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

-- Build a de-duplicated, sorted list of every item the system references.
local function collectItems()
    local set = {}
    local function add(n) if n and n ~= "" then set[n] = true end end

    for _, r in ipairs(RecipeCache) do
        add(r.input_item); add(r.output_cooked_item); add(r.output_burnt_item)
    end
    for _, d in ipairs(GetSetting("drinks", {})) do add(d.input); add(d.output) end
    for _, a in ipairs(GetSetting("assembly", {})) do
        add(a.output)
        for _, c in ipairs(a.components or {}) do add(c) end
    end
    local menu = MySQL.query.await("SELECT DISTINCT item FROM pickle_restaurant_menu") or {}
    for _, m in ipairs(menu) do add(m.item) end

    local list = {}
    for name in pairs(set) do
        local k = KNOWN[name] or {}
        list[#list + 1] = {
            name   = name,
            label  = k.label or humanize(name),
            weight = k.weight or DEFAULT_WEIGHT,
            hunger = k.hunger,
            thirst = k.thirst,
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
        if src ~= 0 then ShowNotification(src, ("Exported %d items to generated_items/."):format(count)) end
    end, false)
end)
