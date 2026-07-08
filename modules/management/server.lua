-- =============================================
--  modules/management | server.lua
--  Employees (hire/fire/promote/demote/commission), finances (deposit/
--  withdraw/ledger) and the per-restaurant sellable menu.
-- =============================================

local function rolesOf(r)
    return r.roles or GetSetting("default_roles", {})
end

local function maxGrade(roles)
    local mg = 0
    for k in pairs(roles) do
        local n = tonumber(k); if n and n > mg then mg = n end
    end
    return mg
end

local function rolesArray(roles)
    local arr = {}
    for k, v in pairs(roles) do
        arr[#arr + 1] = { grade = tonumber(k) or 0, label = v.label, commission = v.commission }
    end
    table.sort(arr, function(a, b) return a.grade < b.grade end)
    return arr
end

local function buildEmployees(rid, roles)
    local list = {}
    for _, emp in pairs(EmployeeCache[rid] or {}) do
        local role = roles[tostring(emp.grade)] or {}
        list[#list + 1] = {
            identifier = emp.identifier, name = emp.name, grade = emp.grade,
            gradeLabel = role.label or ("Grade " .. emp.grade), commission = emp.commission_rate,
        }
    end
    return list
end

-- ─── open ────────────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:management:getData", function(src, d)
    local id = tonumber(d.id)
    local r = GetRestaurant(id); if not r then return { ok = false } end
    local perms, isOwner = ResolvePerms(id, src)
    if not perms then return { ok = false, error = _L("no_work_here") } end
    local effective = isOwner and ALL_PERMS or perms
    local roles = rolesOf(r)

    local ledger = {}
    if effective.view_finances then
        ledger = MySQL.query.await(
            "SELECT type, amount, description, identifier, created_at FROM pickle_restaurant_ledger WHERE restaurant_id = ? ORDER BY id DESC LIMIT 50",
            { id }) or {}
    end

    -- The POS price list: every sellable this restaurant can access (group-
    -- filtered), joined with its price row. Rows priced for something no longer
    -- in the catalog (item uninstalled / group removed) surface as `stale` so
    -- the owner can clean them up.
    local priceList, priced = BuildPricedCatalog(id, false)
    local stale = {}
    do
        local inCatalog = {}
        for _, e in ipairs(priceList) do inCatalog[e.key] = true end
        for key, p in pairs(priced) do
            if not inCatalog[key] then
                local item, variant = key:match("^(.-)::(.+)$")
                if not item then item, variant = key, "" end
                stale[#stale + 1] = { key = key, item = item, variant = variant,
                                      label = GetItemLabel(item) .. (variant ~= "" and (" (" .. variant .. ")") or ""),
                                      price = p.price }
            end
        end
        table.sort(stale, function(a, b) return a.key < b.key end)
    end

    local props = {}
    for _, p in pairs(PropCache) do if p.restaurant_id == id then props[#props + 1] = { id = p.id, prop_type = p.prop_type } end end

    -- Supplies: the raw ingredients the restaurant can buy into its shared stock
    -- pool (the `ingredient_costs` map), each with its per-unit cost and the count
    -- currently in the larder. Cooking consumes from this pool.
    local supplies = {}
    if effective.manage_stock then
        for item, cost in pairs(GetSetting("ingredient_costs", {})) do
            supplies[#supplies + 1] = {
                item = item, label = GetItemLabel(item), image = GetItemImage(item),
                cost = math.max(0, math.floor(tonumber(cost) or 0)),
                stock = GetStockCount(id, item), installed = ItemExists(item),
            }
        end
        table.sort(supplies, function(a, b) return (a.label or a.item):lower() < (b.label or b.item):lower() end)
    end

    return {
        ok        = true,
        restaurant = { id = r.id, label = r.label, balance = r.balance, owner = r.owner_identifier,
                       brand_image  = r.metadata and r.metadata.brand_image or nil,
                       brand_images = r.metadata and r.metadata.brand_images or nil },
        perms     = effective,
        roles     = rolesArray(roles),
        employees = buildEmployees(id, roles),
        ledger    = ledger,
        priceList = priceList,
        stale     = stale,
        supplies  = supplies,
        props     = props,
        nearby    = effective.manage_employees and NearbyPlayers(src, 10.0) or {},
    }
end)

-- ─── employees ───────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:management:hire", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_employees") then return { ok = false, error = _L("no_permission") } end
    local target = tonumber(d.target)
    local identifier = GetIdentifier(target)
    if not identifier then return { ok = false, error = _L("mgmt_player_not_found") } end
    if EmployeeCache[id] and EmployeeCache[id][identifier] then return { ok = false, error = _L("mgmt_already_employed") } end
    local r = GetRestaurant(id)
    if r.owner_identifier == identifier then return { ok = false, error = _L("mgmt_player_owns") } end

    local roles = rolesOf(r)
    local grade = tonumber(d.grade) or 0
    local commission = (roles[tostring(grade)] and roles[tostring(grade)].commission) or GetSetting("default_commission", 10)
    local name = GetPlayerCharacterName(target)
    MySQL.insert.await(
        "INSERT INTO pickle_restaurant_employees (restaurant_id, identifier, name, grade, commission_rate) VALUES (?, ?, ?, ?, ?)",
        { id, identifier, name, grade, commission })
    CacheEmployee(id, { restaurant_id = id, identifier = identifier, name = name, grade = grade, commission_rate = commission })
    ShowNotification(target, _L("mgmt_hired_at", r.label))
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:management:fire", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_employees") then return { ok = false, error = _L("no_permission") } end
    MySQL.update.await("DELETE FROM pickle_restaurant_employees WHERE restaurant_id = ? AND identifier = ?", { id, d.identifier })
    UncacheEmployee(id, d.identifier)
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:management:setGrade", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_employees") then return { ok = false, error = _L("no_permission") } end
    local emp = EmployeeCache[id] and EmployeeCache[id][d.identifier]
    if not emp then return { ok = false } end
    local roles = rolesOf(GetRestaurant(id))
    local grade = math.max(0, math.min(maxGrade(roles), tonumber(d.grade) or 0))
    MySQL.update.await("UPDATE pickle_restaurant_employees SET grade = ? WHERE restaurant_id = ? AND identifier = ?", { grade, id, d.identifier })
    emp.grade = grade
    ShowNotification(src, _L("mgmt_role_saved"))
    return { ok = true, grade = grade }
end)

lib.callback.register("pickle_restaurants:management:setCommission", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_employees") then return { ok = false, error = _L("no_permission") } end
    local emp = EmployeeCache[id] and EmployeeCache[id][d.identifier]
    if not emp then return { ok = false } end
    local rate = math.max(0, math.min(100, tonumber(d.commission) or 0))
    MySQL.update.await("UPDATE pickle_restaurant_employees SET commission_rate = ? WHERE restaurant_id = ? AND identifier = ?", { rate, id, d.identifier })
    emp.commission_rate = rate
    ShowNotification(src, _L("mgmt_commission_saved"))
    return { ok = true }
end)

-- ─── price list (POS menu) ───────────────────────────────────────────────────
-- Prices are set per catalog entry (`key` = item, or item::flavor for drinks).
-- The key is resolved against the restaurant's live sellable catalog — a price
-- can never be written for something the restaurant can't actually make.

lib.callback.register("pickle_restaurants:management:saveMenuItem", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_menu") then return { ok = false, error = _L("no_permission") } end
    local entry
    for _, e in ipairs(BuildSellableCatalog(id)) do
        if e.key == d.key then entry = e break end
    end
    if not entry then return { ok = false, error = _L("mgmt_item_required") } end
    MySQL.update.await([[
        INSERT INTO pickle_restaurant_menu (restaurant_id, item, variant, label, price, category, enabled)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE label = VALUES(label), price = VALUES(price), category = VALUES(category), enabled = VALUES(enabled)
    ]], { id, entry.item, entry.variant or "", entry.label, math.max(0, math.floor(tonumber(d.price) or 0)),
          entry.kind, d.enabled and 1 or 0 })
    ShowNotification(src, _L("mgmt_menu_saved"))
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:management:deleteMenuItem", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_menu") then return { ok = false, error = _L("no_permission") } end
    local item, variant = tostring(d.key or ""):match("^(.-)::(.+)$")
    if not item then item, variant = tostring(d.key or ""), "" end
    MySQL.update.await("DELETE FROM pickle_restaurant_menu WHERE restaurant_id = ? AND item = ? AND variant = ?",
        { id, item, variant })
    ShowNotification(src, _L("mgmt_menu_removed"))
    return { ok = true }
end)

-- ─── supplies (shared stock pool) ────────────────────────────────────────────
-- Buy raw ingredients into the restaurant's shared stock pool, paid out of the
-- restaurant balance at the configured ingredient cost. Cooking consumes from
-- this pool, so a restaurant must keep it stocked to keep the kitchen running.

lib.callback.register("pickle_restaurants:management:buyStock", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_stock") then return { ok = false, error = _L("no_permission") } end
    local item = tostring(d.item or "")
    local costs = GetSetting("ingredient_costs", {})
    if costs[item] == nil then return { ok = false, error = _L("mgmt_item_required") } end
    local qty = math.max(1, math.min(1000, math.floor(tonumber(d.qty) or 0)))
    local unit = math.max(0, math.floor(tonumber(costs[item]) or 0))
    local total = unit * qty
    local r = GetRestaurant(id); if not r then return { ok = false } end
    if (r.balance or 0) < total then return { ok = false, error = _L("mgmt_insufficient_funds") } end
    if total > 0 then
        AdjustBalance(id, -total)
        AddLedger(id, "supply", -total, ("Restock: %d x %s"):format(qty, GetItemLabel(item)), GetIdentifier(src))
    end
    AddStock(id, item, qty)
    ShowNotification(src, _L("mgmt_stock_bought", qty, GetItemLabel(item)))
    return { ok = true, balance = GetRestaurant(id).balance, stock = GetStockCount(id, item) }
end)

-- ─── finances ────────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:management:deposit", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_balance") then return { ok = false, error = _L("no_permission") } end
    local amount = math.floor(tonumber(d.amount) or 0)
    if amount <= 0 then return { ok = false } end
    if GetMoney(src, "money") < amount then return { ok = false, error = _L("not_enough_cash") } end
    RemoveMoney(src, amount, "money")
    AdjustBalance(id, amount)
    AddLedger(id, "deposit", amount, "Deposit", GetIdentifier(src))
    return { ok = true, balance = GetRestaurant(id).balance }
end)

lib.callback.register("pickle_restaurants:management:withdraw", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_balance") then return { ok = false, error = _L("no_permission") } end
    local amount = math.floor(tonumber(d.amount) or 0)
    if amount <= 0 then return { ok = false } end
    if GetRestaurant(id).balance < amount then return { ok = false, error = _L("mgmt_insufficient_funds") } end
    AdjustBalance(id, -amount)
    AddMoney(src, amount, "money")
    AddLedger(id, "withdraw", -amount, "Withdrawal", GetIdentifier(src))
    return { ok = true, balance = GetRestaurant(id).balance }
end)

-- ─── branding ────────────────────────────────────────────────────────────────

-- The restaurant's brand image URLs, stored in the metadata blob and synced to
-- clients. The client render-target module draws them onto the food-packaging props
-- (pizza box, cup, tray paper, side container). Without `key` this sets the SHARED
-- default (`brand_image`, used by any texture with no override); with a `key` it sets
-- that one texture's override (`brand_images[key]`). Blank clears the entry.
local BRAND_KEYS = { pizza_box = true, cup = true, tray = true, side = true }

-- A crop is a normalised SOURCE rectangle { x, y, w, h } (0..1) into the image; the
-- client draws exactly that region onto the texture. Sanitise to 4 numbers within
-- bounds with a positive size, else drop it (falls back to a centred cover crop).
local function sanitizeCrop(c)
    if type(c) ~= "table" then return nil end
    local x, y, w, h = tonumber(c.x), tonumber(c.y), tonumber(c.w), tonumber(c.h)
    if not (x and y and w and h) or w <= 0 or h <= 0 then return nil end
    local function clamp(v) return math.max(0.0, math.min(1.0, v)) end
    x, y = clamp(x), clamp(y)
    w, h = math.min(w, 1.0 - x), math.min(h, 1.0 - y)
    if w <= 0 or h <= 0 then return nil end
    return { x = x, y = y, w = w, h = h }
end

-- Set a restaurant's branding and re-sync. `key` nil/"" sets the shared default image
-- (`brand_image`); a texture key sets that one texture's { url, crop } override. Blank
-- url clears the entry. Shared by the boss (management) and admin panels — each gates
-- its own permission before calling. Returns ok/error.
function SetRestaurantBrand(id, key, url, crop)
    local r = GetRestaurant(id); if not r then return { ok = false, error = _L("mgmt_no_restaurant") } end
    url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    r.metadata = r.metadata or {}
    if key ~= nil and key ~= "" then
        if not BRAND_KEYS[key] then return { ok = false, error = _L("mgmt_unknown_texture") } end
        r.metadata.brand_images = r.metadata.brand_images or {}
        r.metadata.brand_images[key] = (url ~= "") and { url = url, crop = sanitizeCrop(crop) } or nil
        if next(r.metadata.brand_images) == nil then r.metadata.brand_images = nil end
    else
        r.metadata.brand_image = (url ~= "") and url or nil
    end
    MySQL.update.await("UPDATE pickle_restaurants SET metadata = ? WHERE id = ?", { json.encode(r.metadata), id })
    SyncToClient(-1) -- push the new branding to every client's render target
    return { ok = true }
end

lib.callback.register("pickle_restaurants:management:setBrandImage", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_props") then return { ok = false, error = _L("no_permission") } end
    local res = SetRestaurantBrand(id, d.key, d.url, d.crop)
    if res and res.ok then ShowNotification(src, _L("branding_saved")) end
    return res
end)
