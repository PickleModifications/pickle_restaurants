-- =============================================
--  pickle_restaurants | core/shared.lua
--  Runtime configuration + shared utilities.
--
--  There is intentionally NO config.lua in this resource. Every piece of
--  gameplay configuration (restaurants, props, recipes, menus, employees,
--  tunables) lives in the database and is created/edited in-game. The table
--  below only holds *engine* constants and values auto-detected at runtime
--  (framework / target / inventory). Tunables that an admin may want to
--  change live in the `pickle_restaurant_settings` DB table instead.
-- =============================================

Config = Config or {}

Config.ResourceName     = GetCurrentResourceName()
Config.Debug            = false
Config.Language         = "en"

-- Interaction engine (consumed by core/client.lua)
Config.InteractDistance = 2.0
Config.RenderDistance   = 50.0
Config.NoModelTargeting = false
Config.Marker           = { enabled = false, id = 1, scale = 0.3, color = { 255, 255, 255, 100 } }

-- Target system is auto-detected; no manual toggle required.
Config.UseTarget =
    (GetResourceState("ox_target") == "started") or
    (GetResourceState("qb-target") == "started") or
    (GetResourceState("qtarget")   == "started")

-- Framework bridge settings (consumed by bridge/*). These are sane defaults;
-- if a server uses a non-default dirty-money item or society system the
-- value can be changed here without it being "content" config.
Config.FrameworkSettings = {
    dirtyMoney = "DEFAULT",       -- QB dirty money item, "DEFAULT" => dirty_money
    society    = "qb-management", -- "qb-management" | "qb-banking"
}

-- Admin groups used by the bridge IsPlayerAdmin() checks.
Config.AdminGroups   = { "admin", "superadmin", "god" }
Config.InventoryLimit = false

-- ─── Generic utilities ───────────────────────────────────────────────────────

Templates = {}

function lerp(a, b, t) return a + (b - a) * t end

function v3(coords) return vec3(coords.x, coords.y, coords.z), coords.w end

function GetRandomInt(min, max, exclude)
    for _ = 1, 1000 do
        local int = math.random(min, max)
        if exclude == nil or exclude ~= int then
            return int
        end
    end
end

function debugPrint(...)
    if Config.Debug then
        print("[pickle_restaurants]", ...)
    end
end

-- Detect the active inventory's nui image base path. Ordered by specificity;
-- the first started resource wins. Covers the inventories people actually run;
-- an unknown one returns nil so the UI shows its placeholder instead of a broken
-- image. Add a row here to support another inventory.
local INVENTORY_IMAGE_BASES = {
    { res = "ox_inventory",     base = "nui://ox_inventory/web/images/" },
    { res = "qs-inventory",     base = "nui://qs-inventory/html/images/" },
    { res = "ps-inventory",     base = "nui://ps-inventory/html/images/" },
    { res = "qb-inventory",     base = "nui://qb-inventory/html/images/" },
    { res = "lj-inventory",     base = "nui://lj-inventory/html/images/" },
    { res = "origen_inventory", base = "nui://origen_inventory/html/images/" },
    { res = "codem-inventory",  base = "nui://codem-inventory/html/itemimages/" },
    { res = "core_inventory",   base = "nui://core_inventory/html/img/" },
    { res = "tgiann-inventory", base = "nui://tgiann-inventory/html/images/" },
}

function InventoryImageBase()
    for _, e in ipairs(INVENTORY_IMAGE_BASES) do
        if GetResourceState(e.res) == "started" then return e.base end
    end
    return nil
end

-- Build an inventory image nui:// url. `base` is the inventory's web image path
-- (nil => no image, returns nil), `name` the item id, `file` the item's
-- configured image (may be nil/extension-less). Falls back to "<name>.png" — the
-- convention our generated items use.
function InvImageUrl(base, name, file)
    if not base then return nil end
    local f = (type(file) == "string" and file ~= "") and file or (tostring(name) .. ".png")
    if not f:find("%.") then f = f .. ".png" end
    return base .. f
end

function NumberWithCommas(x, noCurrency)
    local left, num = string.match(tostring(x), '^([^%d]*%d)(%d*)')
    if not left then return (not noCurrency and "$" or "") .. tostring(x) end
    return (not noCurrency and "$" or "") .. left .. (num:reverse():gsub('(%d%d%d)', '%1,'):reverse())
end

function tolower(str) return string.lower(str) end
function toupper(str) return string.upper(str) end

function GetCurrencyString(amount) return NumberWithCommas(amount) end

function GetItemLabel(name)
    if not name then return "Unknown" end
    if Inventory and Inventory.Items and Inventory.Items[name] then
        return Inventory.Items[name].label
    elseif Inventory and Inventory.Items and Inventory.Items[toupper(name)] then
        return Inventory.Items[toupper(name)].label
    end
    return name
end

function WeightedRandom(weights)
    local total = 0
    for _, w in pairs(weights) do total = total + w end
    if total <= 0 then return nil end
    local roll = math.random() * total
    local cumulative = 0
    for key, w in pairs(weights) do
        cumulative = cumulative + w
        if roll <= cumulative then return key end
    end
    local last
    for key in pairs(weights) do last = key end
    return last
end

-- Rounds to a whole number of dollars; used everywhere money changes hands so
-- commissions never leave fractional cents on a player or a society account.
function RoundMoney(amount)
    return math.floor((tonumber(amount) or 0) + 0.5)
end
