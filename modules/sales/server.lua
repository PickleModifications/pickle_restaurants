-- =============================================
--  modules/sales | server.lua
--  Fast-food POS. The cashier rings up a NEW ORDER from the restaurant's
--  priced, group-accessible sellable catalog; the customer pays at order time
--  (another player gets a confirm prompt; "Myself" charges the cashier) and
--  receives a RECEIPT whose metadata carries the ticket. The order sits in the
--  kitchen queue until staff cook the items and Complete it at the register —
--  the food (build-stack metadata intact) is handed to the receipt holder —
--  or Cancel it (full refund). Nothing sells "from stock" any more.
-- =============================================

local function ReceiptItem() return GetSetting("receipt_item", "receipt") end
local function DrinkItemName() return GetSetting("drink_item", "drink") end

-- ─── sellable catalog ────────────────────────────────────────────────────────
-- Everything a restaurant may put a price on: cooked recipe outputs, assembled
-- products, drink flavors and finish outputs — group-filtered per restaurant and
-- validity-filtered like the sync payload. Intermediates never sell: a recipe
-- output that is an assembly COMPONENT (a cooked patty) and an assembly output
-- that is a recipe INPUT (raw_pizza) are kitchen-internal. Meals aren't listed
-- either — a meal is an arbitrary arrangement, not a priceable product.
-- `variant` disambiguates drinks: every flavor collects as the ONE drink item,
-- so a price row is keyed (item, variant = flavor key); '' for everything else.
function BuildSellableCatalog(rid)
    local out, seen = {}, {}
    -- `cost` is the raw ingredient cost of this sellable; the computed default
    -- menu price is that cost marked up by the global profit margin.
    local function add(item, variant, label, kind, cost, modifiers)
        variant = variant or ""
        local key = item .. (variant ~= "" and ("::" .. variant) or "")
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = { key = key, item = item, variant = variant,
                          label = label or GetItemLabel(item), kind = kind,
                          image = GetItemImage(item), defaultPrice = MarkupPrice(cost or 0),
                          -- POS customisations the customer can pick (add cheese, no lettuce…)
                          modifiers = (type(modifiers) == "table" and #modifiers > 0) and modifiers or nil }
    end

    -- components of any assembly recipe are kitchen-internal (patties, buns…)
    local isComponent = {}
    for _, a in ipairs(GetSetting("assembly", {})) do
        for _, c in ipairs(a.components or {}) do isComponent[c] = true end
    end

    -- POS modifiers derived from IN-PLACE finishes on a cooked item (a doughnut's
    -- frosting + sprinkles): each finish tool becomes a single-choice GROUP and
    -- every flavor a pick-one option (colored swatch). Only finishes that keep the
    -- SAME item (t.item == t.output — the overlay doughnut finishes) become
    -- modifiers; a finish that changes the item (cake → decorated_cake) stays its
    -- own sellable. Ticket instructions only — the cook applies the finish.
    local function finishModsFor(item)
        local mods = {}
        for _, f in ipairs(GetSetting("finishes", {})) do
            if ItemExists(f.tool) then
                local groupLabel = GetItemLabel(f.tool)
                for _, t in ipairs(f.targets or {}) do
                    if t.item == item and t.output == item then
                        for _, fl in ipairs(t.flavors or {}) do
                            mods[#mods + 1] = { id = f.tool .. ":" .. tostring(fl.id),
                                                label = fl.label or fl.id, group = groupLabel,
                                                color = fl.color, price = 0 }
                        end
                    end
                end
            end
        end
        return (#mods > 0) and mods or nil
    end

    for _, r in ipairs(RecipeCache) do
        local outItem = r.output_cooked_item
        if IsRecipeValid(r) and RestaurantHasAccess(rid, r.group)
            and ItemExists(outItem) and not isComponent[outItem] then
            add(outItem, nil, nil, "recipe", ResolveItemCost(outItem), finishModsFor(outItem))
        end
    end

    for _, a in ipairs(GetSetting("assembly", {})) do
        -- an assembly output that is some recipe's input is tray-only (raw_pizza)
        if not RecipeByInput[a.output] and ItemExists(a.output)
            and RestaurantHasAccess(rid, a.group) then
            local ok = true
            for _, comp in ipairs(a.components or {}) do
                if not ItemExists(comp) then ok = false end
            end
            -- enrich each modifier with its item's image + a clean price for the
            -- POS grid (the raw config price/default/id survive for order pricing)
            local mods
            if type(a.modifiers) == "table" and #a.modifiers > 0 then
                mods = {}
                for _, m in ipairs(a.modifiers) do
                    mods[#mods + 1] = {
                        id = m.id, label = m.label,
                        price = math.max(0, math.floor(tonumber(m.price) or 0)),
                        default = (m.default == true or m.default == 1) or nil,
                        image = (m.item and m.item ~= "") and GetItemImage(m.item) or nil,
                    }
                end
            end
            if ok then add(a.output, nil, a.label, "assembly", ResolveItemCost(a.output), mods) end
        end
    end

    local drinkItem = DrinkItemName()
    if ItemExists(drinkItem) then
        for _, d in ipairs(GetSetting("drinks", {})) do
            if ItemExists(d.input) and RestaurantHasAccess(rid, d.group) then
                add(drinkItem, d.output, d.label or d.output, "drink", ResolveItemCost(d.input))
            end
        end
    end

    for _, f in ipairs(GetSetting("finishes", {})) do
        if ItemExists(f.tool) and RestaurantHasAccess(rid, f.group) then
            for _, t in ipairs(f.targets or {}) do
                if ItemExists(t.output) then
                    add(t.output, nil, nil, "finish", ResolveItemCost(f.tool) + ResolveItemCost(t.item))
                end
            end
        end
    end

    table.sort(out, function(a, b) return (a.label or a.item):lower() < (b.label or b.item):lower() end)
    return out
end

-- The catalog joined against the restaurant's price list (`pickle_restaurant_menu`,
-- keyed item+variant). Every entry carries price/enabled; `pricedOnly` keeps just
-- the orderable ones (priced above zero AND enabled) for the POS grid.
function BuildPricedCatalog(rid, pricedOnly)
    local rows = MySQL.query.await(
        "SELECT item, variant, price, enabled FROM pickle_restaurant_menu WHERE restaurant_id = ?", { rid }) or {}
    local priced = {}
    for _, m in ipairs(rows) do
        priced[m.item .. ((m.variant and m.variant ~= "") and ("::" .. m.variant) or "")] =
            { price = math.floor(tonumber(m.price) or 0), enabled = (m.enabled == 1 or m.enabled == true) }
    end
    local catalog, out = BuildSellableCatalog(rid), {}
    for _, e in ipairs(catalog) do
        local p = priced[e.key]
        if p then
            -- explicit per-restaurant row: honoured verbatim (incl. an explicit
            -- 0/disabled — a boss can deliberately pull an item)
            e.price = p.price
            e.enabled = p.enabled
            e.priceIsDefault = false
        else
            -- no row set: fall back to the ingredient-cost default so the item is
            -- orderable out of the box (a $0 default → not orderable, safe)
            e.price = e.defaultPrice or 0
            e.enabled = e.price > 0
            e.priceIsDefault = true
        end
        if not pricedOnly or (e.enabled and e.price > 0) then out[#out + 1] = e end
    end
    return out, priced
end

-- ─── shared money bits ───────────────────────────────────────────────────────

-- Pay the serving employee's commission out of the restaurant's take (the same
-- flow the old per-item sale used, now per ORDER). Owners/admins have no
-- employee row, so they simply earn no commission.
local function payCommission(rid, src, amount, ticket)
    local id = GetIdentifier(src)
    local emp = EmployeeCache[rid] and EmployeeCache[rid][id]
    local rate = emp and tonumber(emp.commission_rate) or 0
    local commission = RoundMoney(amount * rate / 100)
    if commission > 0 then
        AdjustBalance(rid, -commission)
        AddMoney(src, commission, "money")
        AddLedger(rid, "payroll", -commission, ("Commission: Ticket #%d"):format(ticket), id)
    end
    return commission
end

-- ─── register payload ────────────────────────────────────────────────────────

local function buildRegister(src, id)
    local emp = EmployeeCache[id] and EmployeeCache[id][GetIdentifier(src)]
    return {
        ok           = true,
        restaurantId = id,
        label        = GetRestaurant(id).label,
        balance      = GetRestaurant(id).balance,
        commission   = emp and emp.commission_rate or 0,
        catalog      = (BuildPricedCatalog(id, true)),
        tickets      = GetOpenOrders(id),
        nearby       = NearbyPlayers(src, 6.0),
        receiptOk    = ItemExists(ReceiptItem()),
    }
end

lib.callback.register("pickle_restaurants:sales:getRegister", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "sell") then return { ok = false, error = _L("no_work_here") } end
    return buildRegister(src, id)
end)

-- ─── order helpers ───────────────────────────────────────────────────────────

local function findPlayerByIdentifier(identifier)
    for _, p in ipairs(GetPlayers()) do
        p = tonumber(p)
        if GetIdentifier(p) == identifier then return p end
    end
end

local function playersNear(a, b, dist)
    local pa, pb = GetPlayerPed(a), GetPlayerPed(b)
    if pa == 0 or pb == 0 then return false end
    return #(GetEntityCoords(pa) - GetEntityCoords(pb)) <= dist
end

-- A compact modifier string for a line ("+Cheese, no Lettuce"), or "" for none.
local function modSummary(mods)
    if type(mods) ~= "table" or #mods == 0 then return "" end
    local parts = {}
    for _, m in ipairs(mods) do
        local label = tostring(m.label or m.id or "?")
        parts[#parts + 1] = (m.removed and ("no " .. label) or ("+" .. label))
    end
    return table.concat(parts, ", ")
end

-- One readable "2× Burger (+Cheese), 1× Cola" line for ledger rows & receipt metadata.
local function orderSummary(lines)
    local parts = {}
    for _, l in ipairs(lines) do
        local s = ("%d× %s"):format(l.qty, l.label)
        local m = modSummary(l.mods)
        if m ~= "" then s = s .. " (" .. m .. ")" end
        parts[#parts + 1] = s
    end
    return table.concat(parts, ", ")
end

-- A drink line's exact build signature (the flavor layer every poured drink
-- carries) — computed with the real TraySig so it can never drift from the
-- cooking module's own signatures.
local function drinkSig(variant)
    return TraySig({ { item = variant } })
end

-- ─── create order ────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:sales:createOrder", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "sell") then return { ok = false, error = _L("no_work_here") } end
    local r = GetRestaurant(id); if not r then return { ok = false } end

    -- Re-derive the priced catalog server-side; the cart is only keys + counts.
    local priced = select(1, BuildPricedCatalog(id, true))
    local byKey = {}
    for _, e in ipairs(priced) do byKey[e.key] = e end

    local lines, total = {}, 0
    for _, c in ipairs(type(d.cart) == "table" and d.cart or {}) do
        local e = type(c) == "table" and byKey[c.key] or nil
        if not e then return { ok = false, error = _L("order_not_priced") } end
        local qty = math.max(1, math.min(10, math.floor(tonumber(c.qty) or 1)))

        -- Resolve the customer's selected modifiers against the entry's allowed
        -- set (the NUI is untrusted): record only real additions (a non-default
        -- modifier that's on → +price) and removals (a default that's off). Mods
        -- are ticket instructions + pricing; the kitchen match is item-only.
        local unit, mods = e.price, {}
        if type(e.modifiers) == "table" then
            local sel, groupTaken = {}, {}
            if type(c.mods) == "table" then
                for _, mid in ipairs(c.mods) do sel[tostring(mid)] = true end
            end
            for _, m in ipairs(e.modifiers) do
                local isDefault = m.default == true or m.default == 1
                local on = sel[tostring(m.id)] == true
                -- a grouped modifier is single-choice — only the first selected in
                -- its group counts (the NUI enforces this; re-enforced here)
                if on and m.group and groupTaken[m.group] then on = false end
                if on and not isDefault then
                    if m.group then groupTaken[m.group] = true end
                    local price = math.max(0, math.floor(tonumber(m.price) or 0))
                    unit = unit + price
                    local label = m.group and (tostring(m.group) .. ": " .. tostring(m.label)) or m.label
                    mods[#mods + 1] = { id = m.id, label = label, price = price, added = true }
                elseif isDefault and not on then
                    mods[#mods + 1] = { id = m.id, label = m.label, removed = true }
                end
            end
        end

        lines[#lines + 1] = { item = e.item, variant = e.variant, label = e.label,
                              price = unit, qty = qty, kind = e.kind,
                              mods = (#mods > 0) and mods or nil }
        total = total + unit * qty
    end
    if #lines == 0 then return { ok = false, error = _L("order_nothing_selected") } end
    total = RoundMoney(total)

    -- Resolve the paying customer: 0/nil = the cashier buys their own meal.
    local customerSrc = src
    local target = tonumber(d.customer) or 0
    if target ~= 0 then
        local near = false
        for _, p in ipairs(NearbyPlayers(src, 6.0)) do
            if p.id == target then near = true break end
        end
        if not near then return { ok = false, error = _L("order_customer_missing") } end
        customerSrc = target
        -- The customer confirms the charge on their screen. The client handler
        -- ALWAYS answers (decline button, 30s countdown, view-close watcher),
        -- and pcall covers a mid-await disconnect.
        local okc, accepted = pcall(lib.callback.await, "pickle_restaurants:sales:confirmCharge", customerSrc, {
            restaurant = r.label,
            cashier    = GetPlayerCharacterName(src),
            lines      = lines,
            total      = total,
        })
        if not okc or accepted ~= true then return { ok = false, error = _L("order_declined") } end
    end

    -- Charge (re-checked after the confirm — money may have moved meanwhile).
    if GetMoney(customerSrc, "money") < total then return { ok = false, error = _L("not_enough_cash") } end

    -- Create the ticket, charge, and do the bookkeeping under ONE guard. The
    -- client's register callback has NO timeout — a thrown error anywhere here
    -- would hang the POS forever with the money already gone ("charged, no
    -- ticket"). So: create the row FIRST (a create failure never takes money),
    -- then charge, then best-effort side-effects — and whatever happens, log the
    -- real error and fall through to returning a fresh register below.
    local customerId = GetIdentifier(customerSrc)
    local ok, err = pcall(function()
        local order = CreateOrder(id, {
            customer_identifier = customerId,
            customer_name       = GetPlayerCharacterName(customerSrc),
            cashier_identifier  = GetIdentifier(src),
            lines               = lines,
            total               = total,
        })

        RemoveMoney(customerSrc, total, "money")
        AdjustBalance(id, total)

        local summary = orderSummary(lines)
        AddLedger(id, "sale", total, ("Ticket #%d — %s"):format(order.ticket, summary):sub(1, 255), customerId)
        payCommission(id, src, total, order.ticket)

        -- Hand the customer their receipt (metadata carries the ticket, so the same
        -- item verifies the right order at completion). Skipped gracefully when the
        -- receipt item isn't installed — the ticket alone still drives fulfillment.
        if ItemExists(ReceiptItem()) then
            Inventory.AddItem(customerSrc, ReceiptItem(), 1, {
                order_id      = order.id,
                restaurant_id = id,
                ticket        = order.ticket,
                description   = ("%s — Ticket #%d: %s (%s)"):format(r.label, order.ticket, summary, GetCurrencyString(total)),
            })
        end

        ShowNotification(src, _L("order_placed", order.ticket))
        if customerSrc ~= src then ShowNotification(customerSrc, _L("order_charged", order.ticket, GetCurrencyString(total))) end
    end)
    if not ok then print(("[pickle_restaurants] createOrder failed: %s"):format(tostring(err))) end

    -- ALWAYS answer the cashier's POS with a fresh register (never hang). A
    -- created ticket shows immediately; buildRegister is itself guarded so even a
    -- catalog error still returns the open tickets.
    local okReg, reg = pcall(buildRegister, src, id)
    if okReg then return reg end
    print(("[pickle_restaurants] buildRegister failed: %s"):format(tostring(reg)))
    return { ok = true, restaurantId = id, tickets = GetOpenOrders(id) }
end)

-- ─── complete order ──────────────────────────────────────────────────────────

-- What the completing staff member is missing for `lines`, using slot metadata
-- where the bridge exposes it (a drink line must match its flavor's exact sig).
-- Returns nil when everything is on hand, else a list of "2× Cola" strings.
local function missingForLines(src, lines)
    local missing = {}
    for _, l in ipairs(lines) do
        local have
        if l.kind == "drink" and Inventory.GetItemSlots then
            have = 0
            local want = drinkSig(l.variant)
            for _, s in ipairs(Inventory.GetItemSlots(src, l.item) or {}) do
                local m = type(s.metadata) == "table" and s.metadata or {}
                if TraySig(type(m.stack) == "table" and m.stack or nil) == want then
                    have = have + (s.count or 1)
                end
            end
        else
            -- no slot metadata (bare ESX) → any instance of the item qualifies
            have = Inventory.GetItemCount(src, l.item) or 0
        end
        if have < l.qty then
            missing[#missing + 1] = ("%d× %s"):format(l.qty - have, l.label)
        end
    end
    return #missing > 0 and missing or nil
end

-- Move one line's items from the staff inventory to the customer, one unit at a
-- time so every unit keeps its OWN slot metadata (the trayToInventory precedent
-- — a pepperoni pizza arrives as that exact pepperoni pizza).
local function transferLine(src, customerSrc, l)
    local wantSig = (l.kind == "drink") and drinkSig(l.variant) or nil
    local left = l.qty
    if Inventory.GetItemSlots then
        while left > 0 do
            local slot
            for _, s in ipairs(Inventory.GetItemSlots(src, l.item) or {}) do
                if not wantSig then slot = s break end
                local m = type(s.metadata) == "table" and s.metadata or {}
                if TraySig(type(m.stack) == "table" and m.stack or nil) == wantSig then slot = s break end
            end
            if not slot then return false end -- vanished mid-transfer (shouldn't happen; pre-verified)
            Inventory.RemoveItemSlot(src, l.item, 1, slot.slot)
            Inventory.AddItem(customerSrc, l.item, 1, slot.metadata)
            left = left - 1
        end
        return true
    end
    -- bare ESX: plain counts, no metadata to preserve
    if (Inventory.GetItemCount(src, l.item) or 0) < left then return false end
    Inventory.RemoveItem(src, l.item, left)
    Inventory.AddItem(customerSrc, l.item, left)
    return true
end

-- The order's receipt on the customer. With slot metadata the exact order's
-- receipt is required (metadata.order_id); bare ESX settles for any one receipt
-- item. `consume` false just verifies it's there. Returns false only when the
-- receipt is REQUIRED (item installed) and absent.
local function takeReceipt(customerSrc, order, consume)
    local item = ReceiptItem()
    if not ItemExists(item) then return true end -- receipts not installed → not required
    if Inventory.GetItemSlots then
        for _, s in ipairs(Inventory.GetItemSlots(customerSrc, item) or {}) do
            local m = type(s.metadata) == "table" and s.metadata or {}
            if tonumber(m.order_id) == order.id then
                if consume then Inventory.RemoveItemSlot(customerSrc, item, 1, s.slot) end
                return true
            end
        end
        return false
    end
    if (Inventory.GetItemCount(customerSrc, item) or 0) < 1 then return false end
    if consume then Inventory.RemoveItem(customerSrc, item, 1) end
    return true
end

lib.callback.register("pickle_restaurants:sales:completeOrder", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "sell") then return { ok = false, error = _L("no_work_here") } end
    local o = OrderCache[id] and OrderCache[id][tonumber(d.orderId)]
    if not o or o.status ~= "open" then return { ok = false, error = _L("order_not_open") } end
    -- Claim the ticket BEFORE the first yield so a double-click (or two cashiers)
    -- can't complete it twice; every early return below must release the claim.
    o.status = "completing"
    local function fail(err)
        o.status = "open"
        local res = buildRegister(src, id)
        res.ok, res.error = false, err
        return res
    end

    local customerSrc = findPlayerByIdentifier(o.customer_identifier)
    if not customerSrc or not playersNear(src, customerSrc, 8.0) then
        return fail(_L("order_customer_missing"))
    end
    -- Verify the receipt WITHOUT consuming it yet — it's taken last, once the
    -- food has actually changed hands.
    if not takeReceipt(customerSrc, o, false) then
        return fail(_L("order_no_receipt"))
    end

    -- Everything is verified across ALL lines before anything moves, so a
    -- missing item can never leave a half-handed-over order.
    local missing = missingForLines(src, o.lines)
    if missing then
        return fail(_L("order_missing_items", table.concat(missing, ", ")))
    end
    for _, l in ipairs(o.lines) do
        if Inventory.CanCarryItem and not Inventory.CanCarryItem(customerSrc, l.item, l.qty) then
            return fail(_L("order_cant_carry", l.label))
        end
    end
    for _, l in ipairs(o.lines) do
        if not transferLine(src, customerSrc, l) then
            return fail(_L("order_missing_items", l.label))
        end
    end
    takeReceipt(customerSrc, o, true) -- verified above; best-effort by now

    CloseOrder(id, o.id, "completed")
    ShowNotification(src, _L("order_completed", o.ticket))
    if customerSrc ~= src then ShowNotification(customerSrc, _L("order_received", o.ticket)) end
    return buildRegister(src, id)
end)

-- ─── cancel order (refund) ───────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:sales:cancelOrder", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "sell") then return { ok = false, error = _L("no_work_here") } end
    local o = OrderCache[id] and OrderCache[id][tonumber(d.orderId)]
    if not o or o.status ~= "open" then return { ok = false, error = _L("order_not_open") } end
    o.status = "cancelling"
    local function fail(err)
        o.status = "open"
        local res = buildRegister(src, id)
        res.ok, res.error = false, err
        return res
    end

    -- Refunding needs a live player to hand the money back to.
    local customerSrc = findPlayerByIdentifier(o.customer_identifier)
    if not customerSrc then return fail(_L("order_customer_offline")) end

    AdjustBalance(id, -o.total)
    AddMoney(customerSrc, o.total, "money")
    AddLedger(id, "refund", -o.total, ("Ticket #%d cancelled"):format(o.ticket), o.customer_identifier)

    -- Void the receipt if it's still on them (best-effort — a lost receipt
    -- doesn't block the refund).
    local item = ReceiptItem()
    if ItemExists(item) then
        if Inventory.GetItemSlots then
            for _, s in ipairs(Inventory.GetItemSlots(customerSrc, item) or {}) do
                local m = type(s.metadata) == "table" and s.metadata or {}
                if tonumber(m.order_id) == o.id then
                    Inventory.RemoveItemSlot(customerSrc, item, 1, s.slot)
                    break
                end
            end
        elseif (Inventory.GetItemCount(customerSrc, item) or 0) >= 1 then
            Inventory.RemoveItem(customerSrc, item, 1)
        end
    end

    CloseOrder(id, o.id, "cancelled")
    ShowNotification(src, _L("order_cancelled", o.ticket))
    if customerSrc ~= src then ShowNotification(customerSrc, _L("order_refunded", o.ticket, GetCurrencyString(o.total))) end
    return buildRegister(src, id)
end)
