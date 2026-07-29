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
                                      -- a stale entry still renders with its picture: it may
                                      -- have left the catalog but the item's art usually
                                      -- still resolves, and a label alone doesn't identify it
                                      image = GetItemImage(item),
                                      price = p.price }
            end
        end
        table.sort(stale, function(a, b) return a.key < b.key end)
    end

    local props = {}
    for _, p in pairs(PropCache) do
        if p.restaurant_id == id then props[#props + 1] = PropSummary(p) end
    end

    -- Supplies: the raw ingredients the restaurant can buy into its shared stock
    -- pool (the `ingredient_costs` map), each with its per-unit cost and the count
    -- currently in the larder. Cooking consumes from this pool.
    local supplies = {}
    if effective.manage_stock then
        -- Keys here are STOCK KEYS, not necessarily item names: a multi-faced
        -- ingredient is priced and stocked per face (`restaurant_toy:lardboy`), so
        -- the larder shows one row per toy at its own price. `item` stays the REAL
        -- item — it's what the deposit/withdraw buttons would move and what decides
        -- whether the row is installed at all.
        for key, cost in pairs(IngredientCosts()) do
            local item, vid = SplitStockKey(key)
            supplies[#supplies + 1] = {
                key = key, item = item, variant = vid,
                label = StockKeyLabel(key), image = StockKeyImage(key),
                cost = math.max(0, math.floor(tonumber(cost) or 0)),
                stock = GetStockCount(id, key), installed = ItemExists(item),
                -- how many the manager is personally carrying (offer to deposit).
                -- A FACE can't move between pocket and larder: the inventory item is
                -- generic, so a deposited toy has no face to name and a withdrawn one
                -- would launder a dear toy into a cheap one. Buying is per face;
                -- moving isn't offered for one.
                held = vid and 0 or (Inventory.GetItemCount(src, item) or 0),
                movable = (vid == nil) or nil,
            }
        end
        table.sort(supplies, function(a, b) return (a.label or a.item):lower() < (b.label or b.item):lower() end)
    end

    -- ─── Dashboard ───────────────────────────────────────────────────────────
    -- The at-a-glance tab EVERY employee sees, permission-free: clocking in is not a
    -- management action, it's how you start your shift at the register. Shift state is
    -- read straight from the phone module's ShiftCache and mutated through the SAME
    -- clockIn/clockOut callbacks the phone uses, so the two surfaces can never drift.
    -- Everything else is a read-only summary assembled from caches we already hold;
    -- the money figures are gated on view_finances like the rest of the panel.
    local employees = buildEmployees(id, roles)
    local dash
    do
        local myId = GetIdentifier(src)
        local shifts = ShiftCache and ShiftCache[id] or {}
        local mine = shifts[myId]
        local roster = {}
        for _, sh in pairs(shifts) do
            roster[#roster + 1] = { name = sh.name, tips = sh.tips or 0,
                                    since = sh.clock_in_ts, cooked = sh.cooked or 0 }
        end
        table.sort(roster, function(a, b) return (a.since or 0) < (b.since or 0) end)

        -- the register queue at a glance (the same open tickets the POS shows)
        local openCount, openValue = 0, 0
        for _, o in ipairs(GetOpenOrders(id) or {}) do
            openCount = openCount + 1
            openValue = openValue + (tonumber(o.total) or 0)
        end

        -- how many registers/kiosks this place actually has, so a dashboard opened at
        -- one says what else is out there
        local registers, kiosks, seats = 0, 0, 0
        for _, p in ipairs(props) do
            if p.prop_type == "counter" or p.prop_type == "virtual_register" then registers = registers + 1
            elseif p.prop_type == "kiosk" or p.prop_type == "kiosk_ground" then kiosks = kiosks + 1
            elseif p.prop_type == "seat" then seats = seats + 1 end
        end

        -- supplies already run dry (nothing left in the larder) — the one thing that
        -- silently stops a kitchen mid-service
        local out = {}
        for _, s in ipairs(supplies) do
            if s.installed and s.stock <= 0 then out[#out + 1] = { item = s.item, label = s.label, image = s.image } end
        end

        dash = {
            now        = os.time(),   -- server clock, so the NUI's timer never drifts on a stale page
            clockedIn  = mine ~= nil,
            since      = mine and mine.clock_in_ts or nil,
            tips       = mine and mine.tips or 0,
            cooked     = mine and mine.cooked or 0,
            roster     = roster,
            openOrders = openCount,
            openValue  = effective.view_finances and RoundMoney(openValue) or nil,
            employees  = #employees,
            registers  = registers, kiosks = kiosks, seats = seats,
            menuSize   = #priceList,
            outOfStock = out,
        }
        if effective.view_finances then
            local row = MySQL.single.await(
                "SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM pickle_restaurant_ledger " ..
                "WHERE restaurant_id = ? AND type = 'sale' AND created_at >= CURDATE()", { id })
            dash.todaySales  = RoundMoney(tonumber(row and row.total) or 0)
            dash.todayOrders = tonumber(row and row.n) or 0
        end
    end

    return {
        ok        = true,
        dashboard = dash,
        restaurant = { id = r.id, label = r.label, name = r.name, balance = r.balance, owner = r.owner_identifier,
                       hasShell     = (r.metadata and r.metadata.shell) ~= nil,
                       hasNpcSpawn  = (r.metadata and r.metadata.npc_spawn) ~= nil,
                       brand_image  = r.metadata and r.metadata.brand_image or nil,
                       brand_images = r.metadata and r.metadata.brand_images or nil,
                       phone_image  = r.metadata and r.metadata.phone_image or nil,
                       theme        = r.metadata and r.metadata.theme or nil },
        theme     = r.metadata and r.metadata.theme or nil, -- App-level: skins the open panel
        perms     = effective,
        -- Owner-or-admin. Gates the rename card in the Brand tab, which is NOT a
        -- staff permission (see management:setName).
        isOwner   = isOwner or false,
        roles     = rolesArray(roles),
        employees = employees,
        ledger    = ledger,
        priceList = priceList,
        stale     = stale,
        supplies  = supplies,
        props     = props,
        nearby    = effective.manage_employees and NearbyPlayers(src, 10.0) or {},
        -- Brand-texture aspects for the crop UI, from the ONE render-target registry
        -- (core/shared.lua) so the panel never hardcodes a resolution that drifts.
        renderTargets = BrandRenderTargets(),
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
    SyncToClient(-1) -- refresh the customer-facing menu SCREEN board (modules/screens)
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
    SyncToClient(-1) -- refresh the customer-facing menu SCREEN board (modules/screens)
    return { ok = true }
end)

-- ─── supplies (shared stock pool) ────────────────────────────────────────────
-- Buy raw ingredients into the restaurant's shared stock pool, paid out of the
-- restaurant balance at the configured ingredient cost. Cooking consumes from
-- this pool, so a restaurant must keep it stocked to keep the kitchen running.

lib.callback.register("pickle_restaurants:management:buyStock", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_stock") then return { ok = false, error = _L("no_permission") } end
    -- A STOCK KEY, which for a multi-faced ingredient names the face being bought
    -- (`restaurant_toy:lardboy`). It is validated the same way any other is — by
    -- having a price — so a forged key buys nothing.
    local key = tostring(d.key or d.item or "")
    local costs = IngredientCosts()
    if costs[key] == nil then return { ok = false, error = _L("mgmt_item_required") } end
    local qty = math.max(1, math.min(1000, math.floor(tonumber(d.qty) or 0)))
    local unit = math.max(0, math.floor(tonumber(costs[key]) or 0))
    local total = unit * qty
    local r = GetRestaurant(id); if not r then return { ok = false } end
    if (r.balance or 0) < total then return { ok = false, error = _L("mgmt_insufficient_funds") } end
    local label = StockKeyLabel(key)
    if total > 0 then
        AdjustBalance(id, -total)
        AddLedger(id, "supply", -total, _L("ledger_restock", qty, label), GetIdentifier(src))
    end
    AddStock(id, key, qty)
    ShowNotification(src, _L("mgmt_stock_bought", qty, label))
    return { ok = true, balance = GetRestaurant(id).balance, stock = GetStockCount(id, key) }
end)

-- Move ingredients between a manager's own pockets and the shared pool — the
-- companion to buying. Both gated on manage_stock. Deposit takes items OUT of the
-- player's inventory INTO the pool (free, no balance change); withdraw takes them
-- back OUT of the pool INTO the player's inventory. Only a configured, installed
-- ingredient (an `ingredient_costs` entry that is a real item) can move, and both
-- are logged to the ledger (amount 0) as an audit trail of who moved what.
lib.callback.register("pickle_restaurants:management:depositStock", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_stock") then return { ok = false, error = _L("no_permission") } end
    -- Deposit/withdraw move REAL inventory items, so a per-face stock key can never
    -- be one end of the trade: the pocket item is generic, so a deposit would have no
    -- face to record and a withdrawal would turn a dear toy into a cheap one. Buying
    -- is per face; moving is not offered for one, and says so.
    local key = tostring(d.key or d.item or "")
    local item, vid = SplitStockKey(key)
    if vid then return { ok = false, error = _L("mgmt_variant_not_movable") } end
    local costs = IngredientCosts()
    if costs[item] == nil or not ItemExists(item) then return { ok = false, error = _L("mgmt_item_required") } end
    local qty = math.max(1, math.min(1000, math.floor(tonumber(d.qty) or 0)))
    if (Inventory.GetItemCount(src, item) or 0) < qty then return { ok = false, error = _L("mgmt_not_enough_held") } end
    Inventory.RemoveItem(src, item, qty)
    AddStock(id, item, qty)
    AddLedger(id, "supply", 0, _L("ledger_stock_deposit", qty, GetItemLabel(item)), GetIdentifier(src))
    ShowNotification(src, _L("mgmt_stock_deposited", qty, GetItemLabel(item)))
    return { ok = true, stock = GetStockCount(id, item), held = Inventory.GetItemCount(src, item) or 0 }
end)

lib.callback.register("pickle_restaurants:management:withdrawStock", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_stock") then return { ok = false, error = _L("no_permission") } end
    -- Deposit/withdraw move REAL inventory items, so a per-face stock key can never
    -- be one end of the trade: the pocket item is generic, so a deposit would have no
    -- face to record and a withdrawal would turn a dear toy into a cheap one. Buying
    -- is per face; moving is not offered for one, and says so.
    local key = tostring(d.key or d.item or "")
    local item, vid = SplitStockKey(key)
    if vid then return { ok = false, error = _L("mgmt_variant_not_movable") } end
    local costs = IngredientCosts()
    if costs[item] == nil or not ItemExists(item) then return { ok = false, error = _L("mgmt_item_required") } end
    local qty = math.max(1, math.min(1000, math.floor(tonumber(d.qty) or 0)))
    if GetStockCount(id, item) < qty then return { ok = false, error = _L("mgmt_not_enough_stock") } end
    if Inventory.CanCarryItem and not Inventory.CanCarryItem(src, item, qty) then
        return { ok = false, error = _L("mgmt_cant_carry") }
    end
    -- pull from the pool FIRST (write-through + fails if raced dry), then give
    if not RemoveStock(id, item, qty) then return { ok = false, error = _L("mgmt_not_enough_stock") } end
    Inventory.AddItem(src, item, qty)
    AddLedger(id, "supply", 0, _L("ledger_stock_withdraw", qty, GetItemLabel(item)), GetIdentifier(src))
    ShowNotification(src, _L("mgmt_stock_withdrawn", qty, GetItemLabel(item)))
    return { ok = true, stock = GetStockCount(id, item), held = Inventory.GetItemCount(src, item) or 0 }
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
    AddLedger(id, "deposit", amount, _L("ledger_deposit"), GetIdentifier(src))
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
    AddLedger(id, "withdraw", -amount, _L("ledger_withdrawal"), GetIdentifier(src))
    return { ok = true, balance = GetRestaurant(id).balance }
end)

-- ─── branding ────────────────────────────────────────────────────────────────

-- The restaurant's brand image URLs, stored in the metadata blob and synced to
-- clients. The client render-target module draws them onto the food-packaging props
-- (pizza box, cup, tray paper, side container). Without `key` this sets the SHARED
-- default (`brand_image`, used by any texture with no override); with a `key` it sets
-- that one texture's override (`brand_images[key]`). Blank clears the entry.
-- Derived from the render-target registry (BrandRenderTargets) so a new brand target
-- is editable without touching this whitelist.
local BRAND_KEYS = {}
for _, t in ipairs(BrandRenderTargets()) do BRAND_KEYS[t.key] = true end

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
    if key == "phone" then
        -- The storefront image the companion phone app shows for this restaurant (feed card +
        -- menu header). Separate from the packaging default so the phone can differ.
        r.metadata.phone_image = (url ~= "") and url or nil
    elseif key ~= nil and key ~= "" then
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

-- ─── theme ───────────────────────────────────────────────────────────────────

-- The restaurant's NUI theme seed, stored in the metadata blob and synced to
-- clients. The whole panel palette is DERIVED from these three values on the
-- React side (CSS relative colors), so this is the entire theme config:
-- primary #rrggbb, mode dark|paper, radius sharp|soft|round.
local THEME_MODES = { dark = true, paper = true }
local THEME_RADII = { sharp = true, soft = true, round = true }

-- Global so the admin panel's app-theme callback can reuse it (the NUI is
-- untrusted; only whitelisted seed values are ever stored).
function SanitizeTheme(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    local p = tostring(t.primary or ""):lower()
    if p:match("^#%x%x%x%x%x%x$") then out.primary = p end
    if THEME_MODES[t.mode] then out.mode = t.mode end
    if THEME_RADII[t.radius] then out.radius = t.radius end
    if next(out) == nil then return nil end
    return out
end

-- Set a restaurant's theme seed and re-sync. `theme` nil/empty clears it back to
-- the default kit. Shared by the boss (management) and admin panels — each gates
-- its own permission before calling.
function SetRestaurantTheme(id, theme)
    local r = GetRestaurant(id); if not r then return { ok = false, error = _L("mgmt_no_restaurant") } end
    r.metadata = r.metadata or {}
    r.metadata.theme = SanitizeTheme(theme)
    MySQL.update.await("UPDATE pickle_restaurants SET metadata = ? WHERE id = ?", { json.encode(r.metadata), id })
    SyncToClient(-1) -- the theme rides the restaurant sync payload
    return { ok = true }
end

lib.callback.register("pickle_restaurants:management:setTheme", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_props") then return { ok = false, error = _L("no_permission") } end
    local res = SetRestaurantTheme(id, d.theme)
    if res and res.ok then ShowNotification(src, _L("theme_saved")) end
    return res
end)

-- ─── identity (rename) ───────────────────────────────────────────────────────

-- Caps mirror the `pickle_restaurants` columns (label VARCHAR(100), name
-- VARCHAR(60)) so a long name is trimmed here rather than truncated by MySQL.
local MAX_LABEL_LEN = 100
local MAX_NAME_LEN  = 60

-- The internal codename is DERIVED from the display label — exactly what the
-- admin panel's create form does (admins never type a raw slug), but slugged
-- SERVER-side so a rename can't plant a codename the untrusted NUI made up.
local function restSlug(s)
    return (tostring(s or ""):lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

-- Rename a restaurant. Shared by the boss (management) and admin panels — each
-- gates its own permission before calling. Write-through to BOTH the cache and
-- MySQL (the mutator pattern), then re-sync so the blip, station labels, menu/
-- orders boards and the phone all pick the new name up without a restart.
function SetRestaurantName(id, label)
    id = tonumber(id)
    local r = GetRestaurant(id); if not r then return { ok = false, error = _L("mgmt_no_restaurant") } end
    label = tostring(label or ""):gsub("^%s+", ""):gsub("%s+$", "")
    label = label:sub(1, MAX_LABEL_LEN)
    if label == "" then return { ok = false, error = _L("mgmt_name_required") } end
    local name = restSlug(label):sub(1, MAX_NAME_LEN)
    if name == "" then name = r.name end -- a label of pure symbols keeps the old key
    MySQL.update.await("UPDATE pickle_restaurants SET name = ?, label = ? WHERE id = ?", { name, label, id })
    r.name, r.label = name, label
    SyncToClient(-1)
    return { ok = true, name = name, label = label }
end

lib.callback.register("pickle_restaurants:management:setName", function(src, d)
    local id = tonumber(d.id)
    -- Renaming the business is an OWNER-level act, not a staff one: there is no
    -- per-employee permission for it in PERMISSIONS, and the name lands on every
    -- customer-facing surface (blip, screens, phone, receipts). ResolvePerms'
    -- second return is exactly "owner or server admin", so gate on that rather
    -- than inventing a perm or borrowing manage_props (which a shift lead may hold).
    local perms, isOwner = ResolvePerms(id, src)
    if not perms or not isOwner then return { ok = false, error = _L("no_permission") } end
    local res = SetRestaurantName(id, d.label)
    if res and res.ok then ShowNotification(src, _L("mgmt_name_saved", res.label)) end
    return res
end)
