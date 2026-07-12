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
local function MealItemName() return GetSetting("meal_item", "meal") end

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
    -- frosting + sprinkles, a cake's frosting flavor): each finish tool becomes a
    -- single-choice GROUP and every flavor a pick-one option (colored swatch). Only
    -- finishes that keep the SAME item (t.item == t.output — every collapsed finish:
    -- doughnut frosting/sprinkles, cake frosting) become modifiers, so the item
    -- stays ONE sellable. Ticket instructions only — the cook applies the finish.
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
                -- a component is a real item OR a cooked-pool product (a patty) — the
                -- latter is valid without being installed (IsProductItem), so a burger
                -- still sells even though its patty is a pool-only intermediate
                if not ItemExists(comp) and not IsProductItem(comp) then ok = false end
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

-- A compact projection of the orderable menu for the customer-facing MENU SCREEN
-- (modules/screens): just what a board needs to show — label, price, image and a
-- coarse `kind` for sectioning. Rides the restaurant sync payload so a placed screen
-- always shows the current, live menu (re-synced whenever the menu is edited).
function BuildMenuBoard(rid)
    local out = {}
    for _, e in ipairs((BuildPricedCatalog(rid, true))) do
        out[#out + 1] = { label = e.label or e.item, price = e.price,
                          image = e.image or GetItemImage(e.item), kind = e.kind }
    end
    return out
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

-- ─── ticket fulfillment planner (restaurant-wide cooked-items pool) ──────────
-- Tickets are fulfilled from the UNION of every cook's tray for the restaurant
-- (PoolCount*/PoolConsume* in core), not the cashier's inventory — so cooks needn't
-- double as cashiers. Matching is by BASE ITEM (the menu entry): a burger fills any
-- burger order, a cake any cake, regardless of modifiers/toppings — customisations
-- (cheese, frosting, no-lettuce…) are ticket instructions the cook should honour,
-- never a hard completion gate, so an honest mistake still fulfils the order.
-- DRINKS are the one exception: each flavor is its OWN menu product (a distinct
-- sellable/variant), so a drink line matches only its flavor — a Cola order is never
-- filled by a Sprite. At most ONE meal may be used, covering the lines its layers'
-- items match.

-- The MODIFIER items an assembly output offers (cheese, lettuce…) → the parts that
-- make a customised build differ from the plain one, keyed by item AND by modifier
-- id (with each id's default flag). Returns nil if the item isn't an assembly
-- output. Base components (buns, patties) are deliberately NOT here: a burger's bun
-- is split into a top + bottom HALF (two `bun` layers), so counting raw parts would
-- read a plain burger as "two buns" and never match a one-bun order. Only the
-- presence of an actual modifier item (a cheese slice) is a variation.
local function modifierSpec(item)
    for _, a in ipairs(GetSetting("assembly", {})) do
        if a.output == item then
            local byItem, byId = {}, {}
            for _, m in ipairs(a.modifiers or {}) do
                if m.item and m.item ~= "" then
                    byItem[m.item] = true
                    byId[tostring(m.id)] = { item = m.item, default = (m.default == true or m.default == 1) }
                end
            end
            return { byItem = byItem, byId = byId }
        end
    end
    return nil
end

-- The modifier items a built assembly stack actually carries, as item→count. Two
-- forms count as the "cheese" modifier: a cheese SLICE item layer, OR a patty MELTED
-- with cheese (cheese field ≥ 1) — a burger's cheese is the grill melt on the patty,
-- never a separate slice, so without this a grill-made cheeseburger reads as plain and
-- never matches a "+Cheese" order.
local function assemblyModCounts(spec, stack)
    local count = {}
    if type(stack) == "table" then
        for _, s in ipairs(stack) do
            if spec.byItem[s.item] then
                count[s.item] = (count[s.item] or 0) + 1
            elseif spec.byItem["cheese"] and (tonumber(s.cheese) or 0) >= 1 then
                count["cheese"] = (count["cheese"] or 0) + 1
            end
        end
    end
    return count
end

-- A canonical match key for one cooked instance / meal layer. Matching is by base
-- item (see the section header), so this is "" for everything EXCEPT a drink, whose
-- flavor is its menu identity. Kept in lock-step with lineVariationKey below so a POS
-- line and a cooked instance describe the same thing.
local function variationKey(item, meta)
    if item == DrinkItemName() then
        -- the flavor riding as the drink's one meta layer
        local key = (type(meta) == "table" and meta[1] and meta[1].item) or ""
        return "d:" .. tostring(key)
    end
    return "" -- item-name match: any variation of the item fills the line
end

-- The match key an order line asks for, in the SAME key space as variationKey. Only
-- a drink line pins a flavor (its `variant`); every other line matches by item alone,
-- so modifiers/toppings stay ticket instructions and never block completion.
local function lineVariationKey(line)
    if line.kind == "drink" then return "d:" .. tostring(line.variant or "") end
    return ""
end

-- A predicate an instance's meta must satisfy to fill units of (item, key).
local function variationMatcher(item, key)
    return function(meta) return variationKey(item, meta) == key end
end

-- The order's lines expanded into one { item, key, label } unit per qty.
local function requiredUnits(order)
    local req = {}
    for _, l in ipairs(order.lines or {}) do
        local key = lineVariationKey(l)
        for _ = 1, math.max(1, tonumber(l.qty) or 1) do
            req[#req + 1] = { item = l.item, key = key, label = l.label }
        end
    end
    return req
end

-- Resolve a finish tool:flavor to a display view (label like "Frosting: Strawberry"
-- + the flavor's colour swatch), matching how the POS renders a finish modifier.
local function finishFlavorView(toolId, flavorId)
    for _, f in ipairs(GetSetting("finishes", {})) do
        if f.tool == toolId then
            for _, t in ipairs(f.targets or {}) do
                for _, fl in ipairs(t.flavors or {}) do
                    if fl.id == flavorId then
                        return { label = GetItemLabel(toolId) .. ": " .. (fl.label or fl.id), color = fl.color }
                    end
                end
            end
            return { label = GetItemLabel(toolId) .. ": " .. tostring(flavorId) }
        end
    end
    return { label = tostring(flavorId) }
end

-- Resolve a drink flavor key to a display view (label + colour).
local function drinkFlavorView(key)
    for _, d in ipairs(GetSetting("drinks", {})) do
        if d.output == key then return { label = d.label or key, color = d.color } end
    end
    return { label = tostring(key) }
end

-- The image-rich contents of a meal's build stack for the register's in-depth meal
-- picker: one entry per top-level layer, each with the item's label + image and its
-- toppings (a burger's cheese/lettuce as item images, a cake/doughnut's frosting +
-- sprinkles as coloured swatches, a drink shown by its flavor) so the cashier sees
-- exactly what's inside before fulfilling with it.
local function mealItemsDetail(meta)
    local mealItem = MealItemName()
    local out = {}
    for _, l in ipairs(type(meta) == "table" and meta or {}) do
        if l.item ~= mealItem then
            local entry = { item = l.item, image = GetItemImage(l.item), mods = {} }
            if l.item == DrinkItemName() then
                local key = type(l.stack) == "table" and l.stack[1] and l.stack[1].item or nil
                entry.label = drinkFlavorView(key).label
            else
                local top = type(l.stack) == "table" and l.stack[1] or nil
                entry.label = GetItemLabel(l.item)
                if type(top) == "table" and top.flavor then
                    local cur = top
                    while type(cur) == "table" and cur.flavor do
                        local fv = finishFlavorView(cur.tool, cur.flavor)
                        entry.mods[#entry.mods + 1] = { label = fv.label, color = fv.color }
                        cur = type(cur.stack) == "table" and cur.stack[1] or nil
                    end
                else
                    local spec = modifierSpec(l.item)
                    if spec then
                        for it, n in pairs(assemblyModCounts(spec, l.stack)) do
                            for _ = 1, n do
                                entry.mods[#entry.mods + 1] = { label = GetItemLabel(it), image = GetItemImage(it) }
                            end
                        end
                    end
                end
            end
            out[#out + 1] = entry
        end
    end
    return out
end

-- Given a meal's build stack, remove the required units its top-level layers cover
-- (EXACT variation match — a cheeseburger layer covers a "+cheese" burger line,
-- never a plain-burger line). Returns the leftovers.
local function mealCovers(meta, required)
    local mealItem = MealItemName()
    local provide = {}
    for _, l in ipairs(type(meta) == "table" and meta or {}) do
        if l.item ~= mealItem then -- ignore any nested meal layer
            provide[#provide + 1] = { item = l.item, key = variationKey(l.item, l.stack) }
        end
    end
    local uncovered = {}
    for _, u in ipairs(required) do
        local matched = false
        for _, p in ipairs(provide) do
            if not p.used and p.item == u.item and p.key == u.key then
                p.used, matched = true, true
                break
            end
        end
        if not matched then uncovered[#uncovered + 1] = u end
    end
    return uncovered
end

-- Can the pool complete this order (optionally using the one meal `mealSig`)?
-- Returns { ok, singles = { {item, key, count}, … }, mealSig, missing }.
function PlanFulfillment(rid, order, mealSig)
    local req = requiredUnits(order)
    local usedMealSig = nil
    if type(mealSig) == "string" and mealSig ~= "" then
        local mealItem = MealItemName()
        if PoolCount(rid, mealItem, mealSig) < 1 then
            return { ok = false, missing = { _L("order_meal_gone") } }
        end
        req = mealCovers(PoolTopMeta(rid, mealItem, mealSig), req)
        usedMealSig = mealSig
    end

    -- group the remaining units by (item, variation key) and check pool availability
    local groups, gorder = {}, {}
    for _, u in ipairs(req) do
        local gk = u.item .. "|" .. u.key
        if not groups[gk] then
            groups[gk] = { item = u.item, key = u.key, label = u.label, need = 0 }
            gorder[#gorder + 1] = gk
        end
        groups[gk].need = groups[gk].need + 1
    end

    local singles, missing, ok = {}, {}, true
    for _, gk in ipairs(gorder) do
        local g = groups[gk]
        local have = PoolCountMatch(rid, g.item, variationMatcher(g.item, g.key))
        if have >= g.need then
            singles[#singles + 1] = { item = g.item, key = g.key, count = g.need }
        else
            ok = false
            missing[#missing + 1] = ("%d× %s"):format(g.need - have, g.label or GetItemLabel(g.item))
        end
    end
    return { ok = ok, singles = singles, mealSig = usedMealSig, missing = (#missing > 0) and missing or nil }
end

-- Attach per-ticket fulfillment state:
--   `ok`          — singles ALONE complete the order (the register's one-tap complete).
--   `mealOptions` — each pool meal that (with singles) completes the WHOLE order, so
--                   only completing options are ever offered; each carries its exact
--                   layer contents.
--   `ready`       — the order is completable AT ALL: singles alone OR using one of the
--                   available meals. This is what the read-only Tickets widget shows,
--                   so a meal on the tray counts toward "ready".
--   `missing`     — the shortfall of the BEST plan (singles, or singles + the meal that
--                   covers the most), shown when the order can't be completed yet.
-- The pool is restaurant-wide, so this is identical for every cashier — it rides the
-- SyncOrders broadcast unchanged.
local function AnnotateOrders(rid, list)
    local mealItem = MealItemName()
    -- Only offer meals the customer can actually be handed: single items come from
    -- the sellable catalog (ItemExists-filtered), but a meal can sit in the tray
    -- without being an installed item — never hand over something that'd vanish.
    local meals = ItemExists(mealItem) and PoolVariations(rid, mealItem) or {}
    for _, o in ipairs(list) do
        local base = PlanFulfillment(rid, o)
        local ready = base.ok
        local bestMissing = base.ok and nil or base.missing
        local opts = {}
        for _, m in ipairs(meals) do
            local plan = PlanFulfillment(rid, o, m.sig)
            if plan.ok then
                ready = true
                opts[#opts + 1] = { sig = m.sig, label = GetItemLabel(mealItem),
                                    items = mealItemsDetail(m.meta) }
            elseif not ready and plan.missing
                and (not bestMissing or #plan.missing < #bestMissing) then
                -- this meal covers more than singles alone: report the smaller shortfall
                bestMissing = plan.missing
            end
        end
        local fulfill = { ok = base.ok, ready = ready, missing = (not ready) and bestMissing or nil }
        if #opts > 0 then fulfill.mealOptions = opts end
        o.fulfill = fulfill
    end
    return list
end

-- ─── register payload ────────────────────────────────────────────────────────

local function buildRegister(src, id)
    local emp = EmployeeCache[id] and EmployeeCache[id][GetIdentifier(src)]
    local r = GetRestaurant(id)
    return {
        ok           = true,
        restaurantId = id,
        label        = r.label,
        balance      = r.balance,
        commission   = emp and emp.commission_rate or 0,
        catalog      = (BuildPricedCatalog(id, true)),
        tickets      = AnnotateOrders(id, GetOpenOrders(id)), -- initial list; kept live thereafter by SyncOrders
        nearby       = NearbyPlayers(src, 6.0),
        receiptOk    = ItemExists(ReceiptItem()),
        theme        = r.metadata and r.metadata.theme or nil, -- skins the POS panel
    }
end

lib.callback.register("pickle_restaurants:sales:getRegister", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "sell") then return { ok = false, error = _L("no_work_here") } end
    return buildRegister(src, id)
end)

-- Read-only annotated open tickets for the corner "Tickets" widget shown in every
-- restaurant experience (cooking / management / virtual). Any staff member who
-- can work the restaurant may VIEW them (a cook without `sell` still sees whether
-- the kitchen has cleared each order) — serving stays gated on `sell` in
-- completeOrder. Fulfillment is pool-wide, so this is the same list SyncOrders
-- broadcasts; the widget stays live off that broadcast.
lib.callback.register("pickle_restaurants:sales:getTickets", function(src, d)
    local id = tonumber(d.id)
    if not id or not (HasPerm(id, src, "cook") or HasPerm(id, src, "sell")) then
        return { tickets = {} }
    end
    return { tickets = AnnotateOrders(id, GetOpenOrders(id)) }
end)

-- Seed for the customer-facing ORDERS SCREEN (modules/screens). The screen stays
-- live off the SyncOrders broadcast (sent to everyone), but a player who arrives
-- between changes needs the current list once — this is that one-shot. Public on
-- purpose: an orders board is a "now preparing" display anyone standing in the
-- restaurant can read (the client shows only ticket #, items and ready-state — no
-- customer identity), so it is NOT perm-gated like the staff widget above.
lib.callback.register("pickle_restaurants:screens:getOrders", function(src, d)
    local id = tonumber(d.id)
    if not id or not GetRestaurant(id) then return { orders = {} } end
    return { orders = AnnotateOrders(id, GetOpenOrders(id)) }
end)

-- Push the fresh open-ticket list to every client. Each client applies it if it has
-- THIS restaurant's register open (checked client-side). This is the ONE and ONLY
-- path that mutates an open register's ticket list: create/complete/cancel each call
-- it after their change, so every open register — the acting cashier's and any
-- co-worker's — stays live without re-sending the whole panel (catalog, etc.).
-- Because it's the only path AND FiveM delivers these events reliably and in order,
-- the last list sent is always the last list shown — it can never go stale. (The
-- previous bug was a SECOND update path: the acting cashier ALSO refreshed straight
-- from its callback reply, which could race the broadcast and revive a cancelled
-- ticket. The callbacks now return ok/error ONLY and never touch the list.)
function SyncOrders(id)
    TriggerClientEvent("pickle_restaurants:sales:orders", -1, id, AnnotateOrders(id, GetOpenOrders(id)))
end

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

-- Resolve an untrusted cart ({ key, qty, mods }) against the restaurant's LIVE
-- priced catalog into validated, priced order lines + the rounded total. Shared by
-- the staff register (createOrder) and the self-service kiosk (kioskOrder) so both
-- price, clamp quantities and record/charge modifiers identically. Only real
-- catalog entries, allowed modifiers and 1..10 quantities survive. Returns
-- `lines, total` on success, or `nil, nil, errorMessage`.
local function resolveOrderLines(id, cart)
    -- Re-derive the priced catalog server-side; the cart is only keys + counts.
    local priced = select(1, BuildPricedCatalog(id, true))
    local byKey = {}
    for _, e in ipairs(priced) do byKey[e.key] = e end

    local lines, total = {}, 0
    for _, c in ipairs(type(cart) == "table" and cart or {}) do
        local e = type(c) == "table" and byKey[c.key] or nil
        if not e then return nil, nil, _L("order_not_priced") end
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
                    -- carry the modifier's icon (item image, or flavor colour swatch)
                    -- so the kitchen ticket can render it as an image, not just text
                    mods[#mods + 1] = { id = m.id, label = label, price = price, added = true,
                                        image = m.image, color = m.color }
                elseif isDefault and not on then
                    mods[#mods + 1] = { id = m.id, label = m.label, removed = true,
                                        image = m.image, color = m.color }
                end
            end
        end

        lines[#lines + 1] = { item = e.item, variant = e.variant, label = e.label,
                              image = e.image or GetItemImage(e.item),
                              price = unit, qty = qty, kind = e.kind,
                              mods = (#mods > 0) and mods or nil }
        total = total + unit * qty
    end
    if #lines == 0 then return nil, nil, _L("order_nothing_selected") end
    return lines, RoundMoney(total)
end

-- ─── create order ────────────────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:sales:createOrder", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "sell") then return { ok = false, error = _L("no_work_here") } end
    local r = GetRestaurant(id); if not r then return { ok = false } end

    -- Price the untrusted cart into validated order lines (shared with the kiosk).
    local lines, total, lerr = resolveOrderLines(id, d.cart)
    if not lines then return { ok = false, error = lerr } end

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
            theme      = r.metadata and r.metadata.theme or nil, -- skins the customer receipt
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
    if not ok then
        print(("[pickle_restaurants] createOrder failed: %s"):format(tostring(err)))
        return { ok = false, error = _L("order_failed") }
    end

    -- Broadcast the new ticket to every open register (coworkers'); the acting
    -- cashier also gets the fresh list back in THIS response (reliable, no
    -- dependence on the broadcast round-trip).
    SyncOrders(id)
    -- Reply ok ONLY — the ticket list refreshes via the SyncOrders broadcast above
    -- (which the acting cashier receives too). The reply never carries the list, so
    -- there is no second, racing update path.
    return { ok = true }
end)

-- ─── self-service kiosk ──────────────────────────────────────────────────────
-- A kiosk lets a CUSTOMER order without a cashier: they open the same priced menu
-- the register sells, build a cart, and pay for their OWN order. It still becomes a
-- normal kitchen ticket that staff cook and hand over at the register exactly like a
-- cashier-rung order — the kitchen/fulfillment flow is unchanged. No `sell`
-- permission (the whole point is ordering unattended); the trust boundary is that
-- the ordering player must physically be at one of the restaurant's kiosk props.

local KIOSK_REACH = 4.0
local function PlayerAtKiosk(src, rid)
    local ped = GetPlayerPed(src)
    if ped == 0 then return false end
    local c = GetEntityCoords(ped)
    for _, p in pairs(PropCache) do
        if p.restaurant_id == rid and (p.prop_type == "kiosk" or p.prop_type == "kiosk_ground") then
            if #(c - vector3(p.x + 0.0, p.y + 0.0, p.z + 0.0)) <= KIOSK_REACH then return true end
        end
    end
    return false
end

-- The kiosk's menu payload — the same priced/enabled catalog the register sells,
-- plus the restaurant theme so the order NUI is skinned like every scoped panel.
lib.callback.register("pickle_restaurants:sales:getKiosk", function(src, d)
    local id = tonumber(d.id)
    local r = GetRestaurant(id); if not r then return { ok = false, error = _L("order_failed") } end
    return {
        ok           = true,
        restaurantId = id,
        label        = r.label,
        catalog      = (BuildPricedCatalog(id, true)),
        theme        = r.metadata and r.metadata.theme or nil,
    }
end)

-- Place a self-service order. The customer pays for their own order (there is no
-- cashier to charge someone else) and receives the receipt; the order enters the
-- kitchen queue as an ordinary ticket. No commission is paid at order time (no
-- serving employee yet) — the restaurant keeps the full sale, and staff fulfil the
-- ticket at the register like any other.
lib.callback.register("pickle_restaurants:sales:kioskOrder", function(src, d)
    local id = tonumber(d.id)
    local r = GetRestaurant(id); if not r then return { ok = false, error = _L("order_failed") } end
    if not PlayerAtKiosk(src, id) then return { ok = false, error = _L("kiosk_too_far") } end

    local lines, total, lerr = resolveOrderLines(id, d.cart)
    if not lines then return { ok = false, error = lerr } end

    -- Re-check funds here; the real charge is inside the guarded block below.
    if GetMoney(src, "money") < total then return { ok = false, error = _L("not_enough_cash") } end

    -- Create the row FIRST (a create failure never takes money), then charge, then
    -- best-effort side-effects — mirroring createOrder so a throw can never leave
    -- "charged, no ticket". The customer is their own cashier (self-service).
    local customerId = GetIdentifier(src)
    local ticketNo
    local ok, err = pcall(function()
        local order = CreateOrder(id, {
            customer_identifier = customerId,
            customer_name       = GetPlayerCharacterName(src),
            cashier_identifier  = customerId,
            lines               = lines,
            total               = total,
        })
        ticketNo = order.ticket

        RemoveMoney(src, total, "money")
        AdjustBalance(id, total)

        local summary = orderSummary(lines)
        AddLedger(id, "sale", total, ("Ticket #%d — %s (kiosk)"):format(order.ticket, summary):sub(1, 255), customerId)

        -- Hand the customer their receipt (metadata carries the ticket, so the same
        -- item verifies the right order at completion). Skipped gracefully when the
        -- receipt item isn't installed — the ticket alone still drives fulfillment.
        if ItemExists(ReceiptItem()) then
            Inventory.AddItem(src, ReceiptItem(), 1, {
                order_id      = order.id,
                restaurant_id = id,
                ticket        = order.ticket,
                description   = ("%s — Ticket #%d: %s (%s)"):format(r.label, order.ticket, summary, GetCurrencyString(total)),
            })
        end

        ShowNotification(src, _L("order_placed", order.ticket))
    end)
    if not ok then
        print(("[pickle_restaurants] kioskOrder failed: %s"):format(tostring(err)))
        return { ok = false, error = _L("order_failed") }
    end

    -- Broadcast the new ticket to every open register / Tickets widget.
    SyncOrders(id)
    return { ok = true, ticket = ticketNo }
end)

-- ─── complete order ──────────────────────────────────────────────────────────

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
    -- `o.busy` is a TRANSIENT in-memory claim (double-click / two-cashier guard),
    -- deliberately SEPARATE from o.status: the persisted status stays "open" for the
    -- entire live life of the order. That's the fix for the wedged-ticket bug — a
    -- failure mid-complete can never strand the order in a non-open state that the
    -- guard rejects yet GetOpenOrders still shows. The claim is ALWAYS released on
    -- every failure path below, so the ticket stays actionable without a restart.
    if not o or o.status ~= "open" or o.busy then return { ok = false, error = _L("order_not_open") } end
    o.busy = true
    local function fail(err)
        o.busy = false
        ShowNotification(src, err)
        return { ok = false, error = err }
    end

    -- NPC customer: no player wallet, receipt or inventory hand-off. Verify the NPC is
    -- still waiting at the counter, fulfil from the shared pool (the instances are just
    -- consumed — the NPC "takes" them), then pay the restaurant (+ a possible tip) and
    -- commission the serving staff, and send the ped away happy. The whole player path
    -- below is skipped. (IsNpcOrder/NpcOrderPresent/NpcRollTip/NpcDropOrder are globals
    -- from modules/npc_customers/server.lua.)
    if IsNpcOrder and IsNpcOrder(o) then
        if not NpcOrderPresent(id, o.id) then return fail(_L("order_customer_missing")) end

        local mealSig = (type(d.mealSig) == "string" and d.mealSig ~= "") and d.mealSig or nil
        local plan = PlanFulfillment(id, o, mealSig)
        if not plan.ok then
            return fail(_L("order_missing_items", table.concat(plan.missing or {}, ", ")))
        end
        local mealItem = MealItemName()
        if plan.mealSig and not ItemExists(mealItem) then
            return fail(_L("cook_item_not_installed", mealItem))
        end

        -- Consume from the pool under one guard — no yield since PlanFulfillment, so it
        -- can only come up short if something throws.
        local consumed, cerr = pcall(function()
            if plan.mealSig then
                local taken = PoolConsume(id, mealItem, plan.mealSig, 1)
                if not taken or #taken < 1 then error(GetItemLabel(mealItem), 0) end
            end
            for _, g in ipairs(plan.singles) do
                local taken = PoolConsumeMatch(id, g.item, variationMatcher(g.item, g.key), g.count)
                if not taken or #taken < g.count then error(GetItemLabel(g.item), 0) end
            end
        end)
        if not consumed then return fail(_L("order_missing_items", tostring(cerr))) end

        AdjustBalance(id, o.total)
        local summary = orderSummary(o.lines)
        AddLedger(id, "sale", o.total, ("Ticket #%d — %s"):format(o.ticket, summary):sub(1, 255), o.customer_identifier)
        local tip = (NpcRollTip and NpcRollTip(o.total)) or 0
        if tip > 0 then
            AdjustBalance(id, tip)
            AddLedger(id, "sale", tip, ("Ticket #%d — tip"):format(o.ticket), o.customer_identifier)
        end
        payCommission(id, src, o.total + tip, o.ticket)

        CloseOrder(id, o.id, "completed")
        if NpcDropOrder then NpcDropOrder(id, o.id, true) end
        ShowNotification(src, _L("order_completed", o.ticket))
        SyncOrders(id)
        return { ok = true }
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

    -- Fulfil from the restaurant-wide cooked-items pool (every cook's tray), not
    -- the cashier's inventory. Plan first so a shortfall never half-hands an order;
    -- `d.mealSig` (optional) is the one meal the cashier chose to combine in.
    local mealSig = (type(d.mealSig) == "string" and d.mealSig ~= "") and d.mealSig or nil
    local plan = PlanFulfillment(id, o, mealSig)
    if not plan.ok then
        return fail(_L("order_missing_items", table.concat(plan.missing or {}, ", ")))
    end
    local mealItem = MealItemName()
    if plan.mealSig and not ItemExists(mealItem) then
        return fail(_L("cook_item_not_installed", mealItem))
    end
    if plan.mealSig and Inventory.CanCarryItem and not Inventory.CanCarryItem(customerSrc, mealItem, 1) then
        return fail(_L("order_cant_carry", GetItemLabel(mealItem)))
    end
    for _, g in ipairs(plan.singles) do
        if Inventory.CanCarryItem and not Inventory.CanCarryItem(customerSrc, g.item, g.count) then
            return fail(_L("order_cant_carry", GetItemLabel(g.item)))
        end
    end

    -- Consume from the pool + hand each instance to the customer (build-stack
    -- metadata intact, via BuildInvMeta — a pepperoni pizza arrives as that exact
    -- pizza) + consume the receipt, under ONE guard. There is no yield between the
    -- plan and here, so PoolConsume can't come up short unless something throws.
    local moved, bad = pcall(function()
        if plan.mealSig then
            local taken = PoolConsume(id, mealItem, plan.mealSig, 1)
            if not taken or #taken < 1 then error(GetItemLabel(mealItem), 0) end
            Inventory.AddItem(customerSrc, mealItem, 1, BuildInvMeta(0, taken[1].meta))
        end
        for _, g in ipairs(plan.singles) do
            local taken = PoolConsumeMatch(id, g.item, variationMatcher(g.item, g.key), g.count)
            if not taken or #taken < g.count then error(GetItemLabel(g.item), 0) end
            for _, inst in ipairs(taken) do
                Inventory.AddItem(customerSrc, g.item, 1, BuildInvMeta(inst.cheese, inst.meta))
            end
        end
        takeReceipt(customerSrc, o, true) -- verified above; best-effort by now
    end)
    if not moved then
        return fail(_L("order_missing_items", tostring(bad)))
    end

    CloseOrder(id, o.id, "completed")
    ShowNotification(src, _L("order_completed", o.ticket))
    if customerSrc ~= src then ShowNotification(customerSrc, _L("order_received", o.ticket)) end
    SyncOrders(id)
    -- Reply ok ONLY — the ticket list refreshes via the SyncOrders broadcast above
    -- (which the acting cashier receives too). The reply never carries the list, so
    -- there is no second, racing update path.
    return { ok = true }
end)

-- ─── cancel order (refund) ───────────────────────────────────────────────────

lib.callback.register("pickle_restaurants:sales:cancelOrder", function(src, d)
    local id = tonumber(d.id)
    if not HasPerm(id, src, "sell") then return { ok = false, error = _L("no_work_here") } end
    local o = OrderCache[id] and OrderCache[id][tonumber(d.orderId)]
    -- Transient claim, separate from the persisted status (see completeOrder) —
    -- guarantees the ticket is never wedged in a non-open state by a failure here.
    if not o or o.status ~= "open" or o.busy then return { ok = false, error = _L("order_not_open") } end
    o.busy = true
    local function fail(err)
        o.busy = false
        ShowNotification(src, err)
        return { ok = false, error = err }
    end

    -- NPC customer: it never pre-paid (NPCs pay on serve), so there's nothing to
    -- refund — just close the ticket and send the ped off.
    if IsNpcOrder and IsNpcOrder(o) then
        CloseOrder(id, o.id, "cancelled")
        if NpcDropOrder then NpcDropOrder(id, o.id, false) end
        ShowNotification(src, _L("order_cancelled", o.ticket))
        SyncOrders(id)
        return { ok = true }
    end

    -- Refunding needs a live player to hand the money back to.
    local customerSrc = findPlayerByIdentifier(o.customer_identifier)
    if not customerSrc then return fail(_L("order_customer_offline")) end

    AdjustBalance(id, -o.total)
    AddMoney(customerSrc, o.total, "money")
    AddLedger(id, "refund", -o.total, ("Ticket #%d cancelled"):format(o.ticket), o.customer_identifier)

    -- Void the receipt if it's still on them — truly best-effort: its OWN guard so
    -- an inventory hiccup here can never abort (and thus wedge) the cancel.
    pcall(function()
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
    end)

    CloseOrder(id, o.id, "cancelled")
    ShowNotification(src, _L("order_cancelled", o.ticket))
    if customerSrc ~= src then ShowNotification(customerSrc, _L("order_refunded", o.ticket, GetCurrencyString(o.total))) end
    SyncOrders(id)
    -- Reply ok ONLY — the ticket list refreshes via the SyncOrders broadcast above
    -- (which the acting cashier receives too). The reply never carries the list, so
    -- there is no second, racing update path.
    return { ok = true }
end)

-- ─── live fulfillment refresh ────────────────────────────────────────────────
-- A ticket's Complete/Not-Complete state depends on the shared pool, which
-- changes as cooks cook, cash out, or food expires — none of which touch the
-- order list. The tray mutators flag the restaurant via MarkOrdersDirty (in tight
-- loops), and this coalescing flusher rebroadcasts the (re-annotated) open list
-- through the SAME single SyncOrders path — no new update path, so the staleness
-- invariant holds. Skipped when a flagged restaurant has no open tickets.
CreateThread(function()
    while true do
        Wait(750)
        for rid in pairs(OrdersDirty) do
            OrdersDirty[rid] = nil
            if OrderCache[rid] and next(OrderCache[rid]) then SyncOrders(rid) end
        end
    end
end)
