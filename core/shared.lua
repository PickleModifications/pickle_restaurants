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
