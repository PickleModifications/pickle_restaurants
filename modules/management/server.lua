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

local function nearbyPlayers(src)
    local ped = GetPlayerPed(src)
    local c = GetEntityCoords(ped)
    local list = {}
    for _, p in ipairs(GetPlayers()) do
        p = tonumber(p)
        if p ~= src then
            local pc = GetEntityCoords(GetPlayerPed(p))
            if #(c - pc) < 10.0 then list[#list + 1] = { id = p, name = GetPlayerCharacterName(p) } end
        end
    end
    return list
end

-- ─── open ────────────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:management:getData", function(src, d)
    local id = tonumber(d.id)
    local r = GetRestaurant(id); if not r then return { ok = false } end
    local perms, isOwner = ResolvePerms(id, src)
    if not perms then return { ok = false, error = "You don't work here." } end
    local effective = isOwner and ALL_PERMS or perms
    local roles = rolesOf(r)

    local ledger, menu = {}, {}
    if effective.view_finances then
        ledger = MySQL.query.await(
            "SELECT type, amount, description, identifier, created_at FROM pickle_restaurant_ledger WHERE restaurant_id = ? ORDER BY id DESC LIMIT 50",
            { id }) or {}
    end
    menu = MySQL.query.await(
        "SELECT item, label, price, category, enabled FROM pickle_restaurant_menu WHERE restaurant_id = ? ORDER BY category, label",
        { id }) or {}

    local stock = {}
    for item, count in pairs(StockCache[id] or {}) do stock[#stock + 1] = { item = item, label = GetItemLabel(item), count = count } end
    local props = {}
    for _, p in pairs(PropCache) do if p.restaurant_id == id then props[#props + 1] = { id = p.id, prop_type = p.prop_type } end end

    return {
        ok        = true,
        restaurant = { id = r.id, label = r.label, balance = r.balance, owner = r.owner_identifier },
        perms     = effective,
        roles     = rolesArray(roles),
        employees = buildEmployees(id, roles),
        ledger    = ledger,
        menu      = menu,
        stock     = stock,
        props     = props,
        nearby    = effective.manage_employees and nearbyPlayers(src) or {},
    }
end)

-- ─── employees ───────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:management:hire", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_employees") then return { ok = false, error = "No permission." } end
    local target = tonumber(d.target)
    local identifier = GetIdentifier(target)
    if not identifier then return { ok = false, error = "Player not found." } end
    if EmployeeCache[id] and EmployeeCache[id][identifier] then return { ok = false, error = "Already employed." } end
    local r = GetRestaurant(id)
    if r.owner_identifier == identifier then return { ok = false, error = "That player owns this place." } end

    local roles = rolesOf(r)
    local grade = tonumber(d.grade) or 0
    local commission = (roles[tostring(grade)] and roles[tostring(grade)].commission) or GetSetting("default_commission", 10)
    local name = GetPlayerCharacterName(target)
    MySQL.insert.await(
        "INSERT INTO pickle_restaurant_employees (restaurant_id, identifier, name, grade, commission_rate) VALUES (?, ?, ?, ?, ?)",
        { id, identifier, name, grade, commission })
    CacheEmployee(id, { restaurant_id = id, identifier = identifier, name = name, grade = grade, commission_rate = commission })
    ShowNotification(target, ("You were hired at %s."):format(r.label))
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:management:fire", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_employees") then return { ok = false, error = "No permission." } end
    MySQL.update.await("DELETE FROM pickle_restaurant_employees WHERE restaurant_id = ? AND identifier = ?", { id, d.identifier })
    UncacheEmployee(id, d.identifier)
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:management:setGrade", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_employees") then return { ok = false, error = "No permission." } end
    local emp = EmployeeCache[id] and EmployeeCache[id][d.identifier]
    if not emp then return { ok = false } end
    local roles = rolesOf(GetRestaurant(id))
    local grade = math.max(0, math.min(maxGrade(roles), tonumber(d.grade) or 0))
    MySQL.update.await("UPDATE pickle_restaurant_employees SET grade = ? WHERE restaurant_id = ? AND identifier = ?", { grade, id, d.identifier })
    emp.grade = grade
    return { ok = true, grade = grade }
end)

lib.callback.register("pickle_restaurants:management:setCommission", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_employees") then return { ok = false, error = "No permission." } end
    local emp = EmployeeCache[id] and EmployeeCache[id][d.identifier]
    if not emp then return { ok = false } end
    local rate = math.max(0, math.min(100, tonumber(d.commission) or 0))
    MySQL.update.await("UPDATE pickle_restaurant_employees SET commission_rate = ? WHERE restaurant_id = ? AND identifier = ?", { rate, id, d.identifier })
    emp.commission_rate = rate
    return { ok = true }
end)

-- ─── menu ────────────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:management:saveMenuItem", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_menu") then return { ok = false, error = "No permission." } end
    if not d.item or d.item == "" then return { ok = false, error = "Item required." } end
    MySQL.update.await([[
        INSERT INTO pickle_restaurant_menu (restaurant_id, item, label, price, category, enabled)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE label = VALUES(label), price = VALUES(price), category = VALUES(category), enabled = VALUES(enabled)
    ]], { id, d.item, d.label or d.item, tonumber(d.price) or 0, d.category or "food", d.enabled and 1 or 0 })
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:management:deleteMenuItem", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_menu") then return { ok = false, error = "No permission." } end
    MySQL.update.await("DELETE FROM pickle_restaurant_menu WHERE restaurant_id = ? AND item = ?", { id, d.item })
    return { ok = true }
end)

-- ─── finances ────────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:management:deposit", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_balance") then return { ok = false, error = "No permission." } end
    local amount = math.floor(tonumber(d.amount) or 0)
    if amount <= 0 then return { ok = false } end
    if GetMoney(src, "money") < amount then return { ok = false, error = "Not enough cash." } end
    RemoveMoney(src, amount, "money")
    AdjustBalance(id, amount)
    AddLedger(id, "deposit", amount, "Deposit", GetIdentifier(src))
    return { ok = true, balance = GetRestaurant(id).balance }
end)

lib.callback.register("pickle_restaurants:management:withdraw", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "manage_balance") then return { ok = false, error = "No permission." } end
    local amount = math.floor(tonumber(d.amount) or 0)
    if amount <= 0 then return { ok = false } end
    if GetRestaurant(id).balance < amount then return { ok = false, error = "Insufficient funds." } end
    AdjustBalance(id, -amount)
    AddMoney(src, amount, "money")
    AddLedger(id, "withdraw", -amount, "Withdrawal", GetIdentifier(src))
    return { ok = true, balance = GetRestaurant(id).balance }
end)
