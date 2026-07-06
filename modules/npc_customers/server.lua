-- =============================================
--  modules/npc_customers | server.lua
--  Generates walk-up NPC orders for active restaurants and lets on-duty staff
--  serve them for commission. The money path is RestaurantSell (modules/sales).
-- =============================================

local PendingOrders = {} -- [rid] = { [orderId] = order }
local orderSeq = 0
local NAMES = { "Mike", "Sara", "Tom", "Lily", "Jay", "Nina", "Carl", "Rosa", "Ben", "Mia", "Leo", "Eva" }

function GetPendingOrders(rid)
    local list = {}
    for _, o in pairs(PendingOrders[rid] or {}) do
        list[#list + 1] = { orderId = o.orderId, item = o.item, label = o.label, price = o.price, name = o.name }
    end
    return list
end

local function countOrders(rid)
    local n = 0
    for _ in pairs(PendingOrders[rid] or {}) do n = n + 1 end
    return n
end

local function availableMenu(rid)
    local rows = MySQL.query.await(
        "SELECT item, label, price FROM pickle_restaurant_menu WHERE restaurant_id = ? AND enabled = 1", { rid }) or {}
    local avail = {}
    for _, r in ipairs(rows) do
        if GetStockCount(rid, r.item) > 0 then avail[#avail + 1] = r end
    end
    return avail
end

local function addOrder(rid)
    local avail = availableMenu(rid)
    if #avail == 0 then return end
    local pick = avail[math.random(#avail)]
    orderSeq = orderSeq + 1
    local oid = orderSeq
    local order = {
        orderId = oid, rid = rid, item = pick.item, label = pick.label,
        price = math.floor(tonumber(pick.price) or 0), name = NAMES[math.random(#NAMES)],
    }
    PendingOrders[rid] = PendingOrders[rid] or {}
    PendingOrders[rid][oid] = order
    TriggerClientEvent("pickle_restaurants:npc:orderAdded", -1, rid, oid, GetRestaurant(rid).counter)

    local patience = (GetSetting("npc", {}).patience) or 60000
    SetTimeout(patience, function()
        if PendingOrders[rid] and PendingOrders[rid][oid] then
            PendingOrders[rid][oid] = nil
            TriggerClientEvent("pickle_restaurants:npc:orderRemoved", -1, rid, oid)
        end
    end)
end

CreateThread(function()
    while not RestaurantsReady do Wait(500) end
    while true do
        local cfg = GetSetting("npc", {})
        local interval = cfg.interval or 45000
        if cfg.enabled ~= false then
            for rid, r in pairs(RestaurantCache) do
                if r.counter and countOrders(rid) < (cfg.max or 2) then
                    addOrder(rid)
                end
            end
        end
        Wait(interval)
    end
end)

lib.callback.register("pickle_restaurants:npc:serve", function(src, d)
    local rid = tonumber(d.id)
    local oid = tonumber(d.orderId)
    if not HasPerm(rid, src, "sell") then return { ok = false, error = _L("no_permission") } end
    local order = PendingOrders[rid] and PendingOrders[rid][oid]
    if not order then return { ok = false, error = _L("npc_customer_left") } end
    if GetStockCount(rid, order.item) < 1 then return { ok = false, error = _L("npc_no_stock_item") } end
    if not RestaurantSell(rid, order.item, order.price, src, "Customer " .. order.name) then
        return { ok = false, error = _L("npc_no_stock") }
    end
    PendingOrders[rid][oid] = nil
    TriggerClientEvent("pickle_restaurants:npc:orderRemoved", -1, rid, oid)
    local emp = EmployeeCache[rid] and EmployeeCache[rid][GetIdentifier(src)]
    local rate = emp and tonumber(emp.commission_rate) or 0
    return { ok = true, commission = RoundMoney(order.price * rate / 100) }
end)
