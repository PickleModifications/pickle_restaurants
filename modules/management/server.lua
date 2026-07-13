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

-- Combos for the boss editor: the RAW stored combos (option keys kept intact so they
-- stay editable) plus a per-slot/option validity annotation against the live sellable
-- catalog — mirrors the price-list `stale` handling so the boss sees an option that
-- points at something the restaurant can no longer make. A combo is `stale` if any
-- slot has no valid option left (that's when the ORDER path hides it).
local function buildComboEditorList(id)
    local index, groupCount = {}, {}
    for _, e in ipairs(BuildSellableCatalog(id)) do
        index[e.key] = e
        if e.group then groupCount[e.group] = (groupCount[e.group] or 0) + 1 end
    end
    local out = {}
    for _, c in pairs(ComboCache[id] or {}) do
        local slots, stale = {}, false
        for _, s in ipairs(c.slots or {}) do
            local options, dead = {}, 0
            for _, o in ipairs(s.options or {}) do
                local key = o.key
                local g = ComboOptionGroup(key)
                if g then
                    -- an "any <group>" reference: valid while the group has ≥1 live member
                    local n = groupCount[g] or 0
                    if n == 0 then dead = dead + 1 end
                    options[#options + 1] = { key = key, group = g, count = n, valid = n > 0 }
                else
                    local e = key and index[key]
                    if not e then dead = dead + 1 end
                    options[#options + 1] = {
                        key = key,
                        label = e and e.label or (key and PrettyItemName((key:gsub("::.*$", "")))) or "?",
                        image = e and e.image or nil,
                        kind = e and e.kind or nil,
                        valid = e ~= nil,
                    }
                end
            end
            local slotStale = (#options == 0) or (dead >= #options)
            if slotStale then stale = true end
            slots[#slots + 1] = { label = s.label or "", options = options, stale = slotStale }
        end
        out[#out + 1] = {
            id = c.id, number = tonumber(c.number) or 1, label = c.label or "",
            price = math.max(0, math.floor(tonumber(c.price) or 0)),
            enabled = c.enabled ~= false,
            photo = (c.photo_url and c.photo_url ~= "") and { url = c.photo_url, crop = c.photo_crop } or nil,
            slots = slots, stale = stale,
        }
    end
    table.sort(out, function(a, b)
        if (a.number or 0) ~= (b.number or 0) then return (a.number or 0) < (b.number or 0) end
        return (a.id or 0) < (b.id or 0)
    end)
    return out
end

-- The access groups a combo slot can reference as "any <group>", each with how many
-- live sellables this restaurant can currently make in it. Only groups with ≥1
-- member are offered (an empty group is a dead slot). Drives the editor's group
-- options; a group option resolves to its members at BuildComboCatalog time.
local function buildComboGroups(id)
    local counts = {}
    for _, e in ipairs(BuildSellableCatalog(id)) do
        if e.group then counts[e.group] = (counts[e.group] or 0) + 1 end
    end
    local out = {}
    for g, n in pairs(counts) do out[#out + 1] = { group = g, count = n } end
    table.sort(out, function(a, b) return a.group:lower() < b.group:lower() end)
    return out
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
    for _, p in pairs(PropCache) do
        if p.restaurant_id == id then props[#props + 1] = PropSummary(p) end
    end

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
                -- how many the manager is personally carrying (offer to deposit)
                held = Inventory.GetItemCount(src, item) or 0,
            }
        end
        table.sort(supplies, function(a, b) return (a.label or a.item):lower() < (b.label or b.item):lower() end)
    end

    return {
        ok        = true,
        restaurant = { id = r.id, label = r.label, balance = r.balance, owner = r.owner_identifier,
                       hasShell     = (r.metadata and r.metadata.shell) ~= nil,
                       hasNpcSpawn  = (r.metadata and r.metadata.npc_spawn) ~= nil,
                       brand_image  = r.metadata and r.metadata.brand_image or nil,
                       brand_images = r.metadata and r.metadata.brand_images or nil,
                       theme        = r.metadata and r.metadata.theme or nil },
        theme     = r.metadata and r.metadata.theme or nil, -- App-level: skins the open panel
        perms     = effective,
        roles     = rolesArray(roles),
        employees = buildEmployees(id, roles),
        ledger    = ledger,
        priceList = priceList,
        stale     = stale,
        combos    = effective.manage_menu and buildComboEditorList(id) or {},
        comboGroups = effective.manage_menu and buildComboGroups(id) or {},
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

-- Move ingredients between a manager's own pockets and the shared pool — the
-- companion to buying. Both gated on manage_stock. Deposit takes items OUT of the
-- player's inventory INTO the pool (free, no balance change); withdraw takes them
-- back OUT of the pool INTO the player's inventory. Only a configured, installed
-- ingredient (an `ingredient_costs` entry that is a real item) can move, and both
-- are logged to the ledger (amount 0) as an audit trail of who moved what.
lib.callback.register("pickle_restaurants:management:depositStock", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_stock") then return { ok = false, error = _L("no_permission") } end
    local item = tostring(d.item or "")
    local costs = GetSetting("ingredient_costs", {})
    if costs[item] == nil or not ItemExists(item) then return { ok = false, error = _L("mgmt_item_required") } end
    local qty = math.max(1, math.min(1000, math.floor(tonumber(d.qty) or 0)))
    if (Inventory.GetItemCount(src, item) or 0) < qty then return { ok = false, error = _L("mgmt_not_enough_held") } end
    Inventory.RemoveItem(src, item, qty)
    AddStock(id, item, qty)
    AddLedger(id, "supply", 0, ("Deposit: %d x %s"):format(qty, GetItemLabel(item)), GetIdentifier(src))
    ShowNotification(src, _L("mgmt_stock_deposited", qty, GetItemLabel(item)))
    return { ok = true, stock = GetStockCount(id, item), held = Inventory.GetItemCount(src, item) or 0 }
end)

lib.callback.register("pickle_restaurants:management:withdrawStock", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_stock") then return { ok = false, error = _L("no_permission") } end
    local item = tostring(d.item or "")
    local costs = GetSetting("ingredient_costs", {})
    if costs[item] == nil or not ItemExists(item) then return { ok = false, error = _L("mgmt_item_required") } end
    local qty = math.max(1, math.min(1000, math.floor(tonumber(d.qty) or 0)))
    if GetStockCount(id, item) < qty then return { ok = false, error = _L("mgmt_not_enough_stock") } end
    if Inventory.CanCarryItem and not Inventory.CanCarryItem(src, item, qty) then
        return { ok = false, error = _L("mgmt_cant_carry") }
    end
    -- pull from the pool FIRST (write-through + fails if raced dry), then give
    if not RemoveStock(id, item, qty) then return { ok = false, error = _L("mgmt_not_enough_stock") } end
    Inventory.AddItem(src, item, qty)
    AddLedger(id, "supply", 0, ("Withdraw: %d x %s"):format(qty, GetItemLabel(item)), GetIdentifier(src))
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
local BRAND_KEYS = { pizza_box = true, cup = true, tray = true, side = true, kiosk = true }

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

-- ─── combo meals ─────────────────────────────────────────────────────────────
-- A combo is a per-restaurant, numbered, priced BUNDLE of existing sellables sold as
-- one entry (see BuildComboCatalog / resolveComboEntry in modules/sales). The boss
-- edits them here (same `manage_menu` perm as the price list). Option keys are stored
-- VERBATIM — never validated away — so a temporarily-uninstalled item doesn't wipe the
-- config; the order path drops dead options and hides an unfulfillable combo, and the
-- editor flags them. Photo reuses the brand-image { url, crop } shape + sanitizeCrop.
local MAX_COMBO_SLOTS   = 8
local MAX_SLOT_OPTIONS  = 12

lib.callback.register("pickle_restaurants:management:saveCombo", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_menu") then return { ok = false, error = _L("no_permission") } end
    if not GetRestaurant(id) then return { ok = false } end

    local label = tostring(d.label or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if label == "" then return { ok = false, error = _L("mgmt_combo_label_required") } end

    -- Sanitize slots: keep the structure + option keys verbatim, cap sizes. A slot
    -- with no option is dropped; at least one slot must survive.
    local slots = {}
    for _, s in ipairs(type(d.slots) == "table" and d.slots or {}) do
        if #slots >= MAX_COMBO_SLOTS then break end
        local options = {}
        for _, o in ipairs(type(s) == "table" and type(s.options) == "table" and s.options or {}) do
            if #options >= MAX_SLOT_OPTIONS then break end
            local key = type(o) == "table" and tostring(o.key or "") or tostring(o or "")
            if key ~= "" then options[#options + 1] = { key = key:sub(1, 80) } end
        end
        if #options > 0 then
            slots[#slots + 1] = { label = tostring(s.label or ""):sub(1, 40), options = options }
        end
    end
    if #slots == 0 then return { ok = false, error = _L("mgmt_combo_needs_slot") } end

    local url = tostring((d.photo and d.photo.url) or ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 512)
    local combo = SaveCombo(id, {
        id         = d.comboId and tonumber(d.comboId) or nil,
        number     = math.max(0, math.floor(tonumber(d.number) or 1)),
        label      = label:sub(1, 80),
        price      = math.max(0, math.floor(tonumber(d.price) or 0)),
        enabled    = d.enabled ~= false,
        photo_url  = (url ~= "") and url or nil,
        photo_crop = (url ~= "") and sanitizeCrop(d.photo and d.photo.crop) or nil,
        slots      = slots,
    })
    if not combo then return { ok = false, error = _L("order_failed") } end
    ShowNotification(src, _L("mgmt_combo_saved"))
    SyncToClient(-1) -- refresh POS + the customer-facing MENU SCREEN board (modules/screens)
    return { ok = true, comboId = combo.id }
end)

lib.callback.register("pickle_restaurants:management:deleteCombo", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_menu") then return { ok = false, error = _L("no_permission") } end
    DeleteCombo(id, tonumber(d.comboId))
    ShowNotification(src, _L("mgmt_combo_removed"))
    SyncToClient(-1)
    return { ok = true }
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
