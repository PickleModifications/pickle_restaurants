-- =============================================
--  modules/sales | server.lua
--  Counter point-of-sale. Walk-in players buy from stock; staff stock cooked
--  food and serve NPC customers. RestaurantSell() is the shared money path
--  (also used by modules/npc_customers).
-- =============================================

-- Core sale: pull one unit of `item` from stock, credit the restaurant, and
-- (if an employee served it) pay their commission out of the take.
function RestaurantSell(rid, item, price, servingSrc, customerLabel)
    if not RemoveStock(rid, item, 1) then return false, "no_stock" end
    AdjustBalance(rid, price)
    AddLedger(rid, "sale", price, (customerLabel or "Sale") .. ": " .. GetItemLabel(item), servingSrc and GetIdentifier(servingSrc) or nil)
    if servingSrc then
        local id = GetIdentifier(servingSrc)
        local emp = EmployeeCache[rid] and EmployeeCache[rid][id]
        local rate = emp and tonumber(emp.commission_rate) or 0
        local commission = RoundMoney(price * rate / 100)
        if commission > 0 then
            AdjustBalance(rid, -commission)
            AddMoney(servingSrc, commission, "money")
            AddLedger(rid, "payroll", -commission, "Commission: " .. GetItemLabel(item), id)
        end
    end
    return true
end

-- ─── walk-in ordering (any player) ───────────────────────────────────────────

lib.callback.register("pickle_restaurants:sales:getMenu", function(_, d)
    local id = tonumber(d.id)
    local r = GetRestaurant(id); if not r then return { ok = false } end
    local rows = MySQL.query.await(
        "SELECT item, label, price, category FROM pickle_restaurant_menu WHERE restaurant_id = ? AND enabled = 1 ORDER BY category, label",
        { id }) or {}
    for _, row in ipairs(rows) do row.stock = GetStockCount(id, row.item) end
    return { ok = true, label = r.label, menu = rows }
end)

lib.callback.register("pickle_restaurants:sales:buy", function(src, d)
    local id = tonumber(d.id)
    local r = GetRestaurant(id); if not r then return { ok = false } end
    local row = MySQL.single.await("SELECT item, label, price FROM pickle_restaurant_menu WHERE restaurant_id = ? AND item = ? AND enabled = 1", { id, d.item })
    if not row then return { ok = false, error = "Not on the menu." } end
    if GetStockCount(id, row.item) < 1 then return { ok = false, error = "Out of stock." } end
    local price = math.floor(tonumber(row.price) or 0)
    if GetMoney(src, "money") < price then return { ok = false, error = "Not enough cash." } end
    if not (Inventory.CanCarryItem == nil or Inventory.CanCarryItem(src, row.item, 1)) then
        return { ok = false, error = "You can't carry that." }
    end
    RemoveMoney(src, price, "money")
    local ok = RestaurantSell(id, row.item, price, nil, "Walk-in")
    if not ok then
        AddMoney(src, price, "money") -- refund race on stock
        return { ok = false, error = "Out of stock." }
    end
    Inventory.AddItem(src, row.item, 1)
    return { ok = true, item = row.item, label = row.label }
end)

-- ─── staff register ──────────────────────────────────────────────────────────

local function buildRegister(src, id)
    local emp = EmployeeCache[id] and EmployeeCache[id][GetIdentifier(src)]
    local stock = {}
    for item, count in pairs(StockCache[id] or {}) do stock[#stock + 1] = { item = item, label = GetItemLabel(item), count = count } end
    return {
        ok         = true,
        restaurantId = id,
        balance    = GetRestaurant(id).balance,
        commission = emp and emp.commission_rate or 0,
        stock      = stock,
        inventory  = Inventory.GetInventory(src) or {},
        orders     = (type(GetPendingOrders) == "function") and GetPendingOrders(id) or {},
    }
end

lib.callback.register("pickle_restaurants:sales:getRegister", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "sell") then return { ok = false, error = "You don't work here." } end
    return buildRegister(src, id)
end)

lib.callback.register("pickle_restaurants:sales:stock", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "sell") then return { ok = false, error = "No permission." } end
    local count = math.max(1, math.floor(tonumber(d.count) or 1))
    if (Inventory.GetItemCount(src, d.item) or 0) < count then return { ok = false, error = "You don't have that many." } end
    Inventory.RemoveItem(src, d.item, count)
    AddStock(id, d.item, count)
    return buildRegister(src, id)
end)
