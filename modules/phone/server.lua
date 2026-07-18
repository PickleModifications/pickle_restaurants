-- ─────────────────────────────────────────────────────────────────────────────
-- modules/phone — lb-phone companion app backend
--
-- A DoorDash/Uber-Eats-style phone app for pickle_restaurants. The UI is the React
-- build served at nui/phone.html and hosted inside lb-phone's app iframe; this file
-- is the SERVER contract behind it. It leans on the existing engine globals for the
-- heavy lifting (BuildPricedCatalog / CreateOrder / AdjustBalance / HasPerm / the
-- sales:orders broadcast) and only OWNS the genuinely-new customer/staff/social
-- surfaces: reviews, loyalty punch-cards, favorites, shifts + tip pool, promotions,
-- reservations, the sales-analytics rollup, the top-chef leaderboard, and cooking
-- achievements.
--
-- Order PLACEMENT + COMPLETION stay in modules/sales/server.lua (that's where the
-- private pricing/fulfilment machinery lives) — this module only reads/annotates
-- them and reacts to the `pickle_restaurants:internal:orderCompleted` seam sales
-- fires on a completed ticket.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─── caches (module-global, write-through like the rest of the engine) ─────────
ReviewCache      = {}   -- [restaurantId] = { rows = { review, ... }, avg, count }
LoyaltyCache     = {}   -- [restaurantId][identifier] = { punches, redeemed }
PromoCache       = {}   -- [restaurantId] = { promo, ... } (active only)
ReservationCache = {}   -- [restaurantId][id] = reservation row
ShiftCache       = {}   -- [restaurantId][identifier] = open shift row (clocked in)
CookStatCache    = {}   -- [restaurantId][identifier] = { name, cooked, revenue }
AchievementCache = {}   -- [identifier][key] = { progress, unlocked }

-- Cooking achievement ladder (progress = lifetime tickets cooked by this player).
-- Purely additive/social — unlocking one just posts a phone notification + badge.
PHONE_ACHIEVEMENTS = {
    { key = "first_cook",  label = "First Ticket",   desc = "Cook your first order",        goal = 1 },
    { key = "line_cook",   label = "Line Cook",      desc = "Cook 25 orders",               goal = 25 },
    { key = "sous_chef",   label = "Sous Chef",      desc = "Cook 100 orders",              goal = 100 },
    { key = "head_chef",   label = "Head Chef",      desc = "Cook 500 orders",              goal = 500 },
    { key = "iron_chef",   label = "Iron Chef",      desc = "Cook 1000 orders",             goal = 1000 },
}

local function LoyaltyGoal()  return math.max(2, math.floor(tonumber(GetSetting("loyalty_goal", 8)) or 8)) end
local function LoyaltyOn()    return GetSetting("loyalty_enabled", true) ~= false end

-- ─── schema ────────────────────────────────────────────────────────────────────
local function EnsureColumn(tbl, col, ddl)
    local exists = MySQL.scalar.await(
        "SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?",
        { tbl, col })
    if not exists then MySQL.query.await(("ALTER TABLE `%s` ADD COLUMN %s"):format(tbl, ddl)) end
end

local function CreatePhoneTables()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_reviews` (
            `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `identifier` VARCHAR(80) NOT NULL,
            `name` VARCHAR(100) DEFAULT NULL,
            `rating` TINYINT UNSIGNED NOT NULL DEFAULT 5,
            `comment` TEXT DEFAULT NULL,
            `photo` TEXT DEFAULT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_rest` (`restaurant_id`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_loyalty` (
            `restaurant_id` INT UNSIGNED NOT NULL,
            `identifier` VARCHAR(80) NOT NULL,
            `punches` INT UNSIGNED NOT NULL DEFAULT 0,
            `redeemed` INT UNSIGNED NOT NULL DEFAULT 0,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`restaurant_id`, `identifier`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_favorites` (
            `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `identifier` VARCHAR(80) NOT NULL,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `label` VARCHAR(80) DEFAULT NULL,
            `cart` JSON NOT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_owner` (`identifier`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_shifts` (
            `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `identifier` VARCHAR(80) NOT NULL,
            `name` VARCHAR(100) DEFAULT NULL,
            `clock_in` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `clock_out` TIMESTAMP NULL DEFAULT NULL,
            `seconds` INT UNSIGNED NOT NULL DEFAULT 0,
            `tips` INT NOT NULL DEFAULT 0,
            `orders_cooked` INT UNSIGNED NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`),
            KEY `idx_rest_open` (`restaurant_id`, `clock_out`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_promos` (
            `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `label` VARCHAR(80) NOT NULL,
            `percent` TINYINT UNSIGNED NOT NULL DEFAULT 10,
            `kind` VARCHAR(16) NOT NULL DEFAULT 'discount',
            `active` TINYINT UNSIGNED NOT NULL DEFAULT 1,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_rest` (`restaurant_id`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_reservations` (
            `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `restaurant_id` INT UNSIGNED NOT NULL,
            `identifier` VARCHAR(80) NOT NULL,
            `name` VARCHAR(100) DEFAULT NULL,
            `party` TINYINT UNSIGNED NOT NULL DEFAULT 2,
            `slot` VARCHAR(20) DEFAULT NULL,
            `status` VARCHAR(12) NOT NULL DEFAULT 'booked',
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_rest` (`restaurant_id`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_achievements` (
            `identifier` VARCHAR(80) NOT NULL,
            `akey` VARCHAR(40) NOT NULL,
            `progress` INT UNSIGNED NOT NULL DEFAULT 0,
            `unlocked_at` TIMESTAMP NULL DEFAULT NULL,
            PRIMARY KEY (`identifier`, `akey`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_cook_stats` (
            `restaurant_id` INT UNSIGNED NOT NULL,
            `identifier` VARCHAR(80) NOT NULL,
            `name` VARCHAR(100) DEFAULT NULL,
            `cooked` INT UNSIGNED NOT NULL DEFAULT 0,
            `revenue` BIGINT NOT NULL DEFAULT 0,
            PRIMARY KEY (`restaurant_id`, `identifier`)
        )
    ]])

    -- Additive order columns for delivery/pickup/dine-in + order-ahead. The base
    -- pickle_restaurant_orders table predates the phone; these are nullable so the
    -- register/kiosk paths (which never set them) keep working untouched.
    EnsureColumn("pickle_restaurant_orders", "order_type",   "`order_type` VARCHAR(12) NOT NULL DEFAULT 'pickup'")
    EnsureColumn("pickle_restaurant_orders", "scheduled_for","`scheduled_for` VARCHAR(20) DEFAULT NULL")
    EnsureColumn("pickle_restaurant_orders", "address",      "`address` VARCHAR(160) DEFAULT NULL")
    EnsureColumn("pickle_restaurant_orders", "phone_number", "`phone_number` VARCHAR(24) DEFAULT NULL")
    EnsureColumn("pickle_restaurant_orders", "rated",        "`rated` TINYINT UNSIGNED NOT NULL DEFAULT 0")

    if GetSetting("loyalty_goal", nil) == nil then SetSetting("loyalty_goal", 8) end
    if GetSetting("loyalty_enabled", nil) == nil then SetSetting("loyalty_enabled", true) end
end

-- ─── cache loaders ──────────────────────────────────────────────────────────────
local function ReviewAvg(rows)
    if #rows == 0 then return 0 end
    local sum = 0
    for _, r in ipairs(rows) do sum = sum + (tonumber(r.rating) or 0) end
    return math.floor((sum / #rows) * 10 + 0.5) / 10
end

local function LoadReviews()
    ReviewCache = {}
    local rows = MySQL.query.await(
        "SELECT id, restaurant_id, identifier, name, rating, comment, photo, created_at FROM pickle_restaurant_reviews ORDER BY id DESC") or {}
    for _, row in ipairs(rows) do
        local rid = row.restaurant_id
        ReviewCache[rid] = ReviewCache[rid] or { rows = {}, avg = 0, count = 0 }
        ReviewCache[rid].rows[#ReviewCache[rid].rows + 1] = row
    end
    for _, entry in pairs(ReviewCache) do
        entry.count = #entry.rows
        entry.avg = ReviewAvg(entry.rows)
    end
end

local function LoadLoyalty()
    LoyaltyCache = {}
    for _, row in ipairs(MySQL.query.await("SELECT restaurant_id, identifier, punches, redeemed FROM pickle_restaurant_loyalty") or {}) do
        LoyaltyCache[row.restaurant_id] = LoyaltyCache[row.restaurant_id] or {}
        LoyaltyCache[row.restaurant_id][row.identifier] = { punches = row.punches, redeemed = row.redeemed }
    end
end

local function LoadPromos()
    PromoCache = {}
    for _, row in ipairs(MySQL.query.await("SELECT id, restaurant_id, label, percent, kind, active FROM pickle_restaurant_promos WHERE active = 1") or {}) do
        PromoCache[row.restaurant_id] = PromoCache[row.restaurant_id] or {}
        PromoCache[row.restaurant_id][#PromoCache[row.restaurant_id] + 1] = row
    end
end

local function LoadReservations()
    ReservationCache = {}
    for _, row in ipairs(MySQL.query.await("SELECT id, restaurant_id, identifier, name, party, slot, status FROM pickle_restaurant_reservations WHERE status = 'booked'") or {}) do
        ReservationCache[row.restaurant_id] = ReservationCache[row.restaurant_id] or {}
        ReservationCache[row.restaurant_id][row.id] = row
    end
end

local function LoadCookStats()
    CookStatCache = {}
    for _, row in ipairs(MySQL.query.await("SELECT restaurant_id, identifier, name, cooked, revenue FROM pickle_restaurant_cook_stats") or {}) do
        CookStatCache[row.restaurant_id] = CookStatCache[row.restaurant_id] or {}
        CookStatCache[row.restaurant_id][row.identifier] = { name = row.name, cooked = row.cooked, revenue = row.revenue }
    end
end

local function LoadAchievements()
    AchievementCache = {}
    for _, row in ipairs(MySQL.query.await("SELECT identifier, akey, progress, unlocked_at FROM pickle_restaurant_achievements") or {}) do
        AchievementCache[row.identifier] = AchievementCache[row.identifier] or {}
        AchievementCache[row.identifier][row.akey] = { progress = row.progress, unlocked = row.unlocked_at ~= nil }
    end
end

-- Reopen shifts that were open when the resource restarted (best-effort — a crash
-- mid-shift shouldn't strand someone clocked-in forever, so we just drop them here;
-- they clock in fresh). We don't auto-close in DB, just skip stale cache seeding.
CreateThread(function()
    while not RestaurantsReady do Wait(200) end
    CreatePhoneTables()
    LoadReviews(); LoadLoyalty(); LoadPromos(); LoadReservations(); LoadCookStats(); LoadAchievements()
    PhoneReady = true
    print("[pickle_restaurants] phone companion backend ready")
end)

-- ─── helpers ─────────────────────────────────────────────────────────────────────
local function Now() return os.time() end

-- Best active promo for a restaurant → { label, percent, kind } or nil. Happy-hour
-- and flat discounts both just reduce the cart total by `percent`; the biggest wins.
function ActivePromo(rid)
    local best
    for _, p in ipairs(PromoCache[rid] or {}) do
        if not best or p.percent > best.percent then best = p end
    end
    if not best then return nil end
    return { id = best.id, label = best.label, percent = best.percent, kind = best.kind }
end

-- The employment context for a source at every restaurant they can act on: which
-- ones they work at, their effective perms, and whether they're the owner/admin.
-- Used to decide which phone tabs (Kitchen / Manage) to surface.
local function EmploymentFor(src)
    local id = GetIdentifier(src)
    local out = {}
    for rid, r in pairs(RestaurantCache) do
        local perms, isOwner = ResolvePerms(rid, src)
        if perms then
            out[#out + 1] = {
                id = rid, label = r.label, isOwner = isOwner or false,
                perms = perms,
                clockedIn = ShiftCache[rid] ~= nil and ShiftCache[rid][id] ~= nil,
            }
        end
    end
    return out
end

-- A compact, display-safe restaurant card for the customer feed.
function RestaurantCard(r, playerCoords)
    local rev = ReviewCache[r.id]
    local counter = r.counter
    local dist
    if playerCoords and counter and counter.x then
        local dx, dy = counter.x - playerCoords.x, counter.y - playerCoords.y
        dist = math.floor(math.sqrt(dx * dx + dy * dy))
    end
    -- "Open" heuristic: staff clocked in, else has a counter anchor + menu enabled.
    local staffOn = false
    for _ in pairs(ShiftCache[r.id] or {}) do staffOn = true break end
    return {
        id      = r.id,
        label   = r.label or r.name,
        theme   = r.metadata and r.metadata.theme or nil,
        brand   = r.metadata and r.metadata.brand_image or nil,
        coords  = counter and { x = counter.x, y = counter.y } or nil,
        rating  = rev and rev.avg or 0,
        reviews = rev and rev.count or 0,
        promo   = ActivePromo(r.id),
        dist    = dist,
        open    = (r.menu_enabled ~= 0) and (staffOn or (counter ~= nil)),
        staffOn = staffOn,
    }
end

-- ─── notifications through lb-phone ──────────────────────────────────────────────
-- Server-side push to a player's equipped phone. Guarded so a missing lb-phone (or
-- a phone-less player) never errors a callback.
function PhoneNotify(src, title, content, thumbnail)
    if GetResourceState("lb-phone") ~= "started" then return end
    pcall(function()
        exports["lb-phone"]:SendNotification(src, {
            app = "pickle_food",
            title = title,
            content = content,
            thumbnail = thumbnail,
        })
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HOME — the app bootstrap for a customer opening the app.
-- ─────────────────────────────────────────────────────────────────────────────
lib.callback.register("pickle_restaurants:phone:home", function(src, d)
    if not PhoneReady then return { ok = false, error = "Loading…" } end
    local id = GetIdentifier(src)
    local coords = d and d.coords or nil

    local cards = {}
    for _, r in pairs(RestaurantCache) do
        cards[#cards + 1] = RestaurantCard(r, coords)
    end
    table.sort(cards, function(a, b)
        if a.open ~= b.open then return a.open end
        if (a.dist or 1e9) ~= (b.dist or 1e9) then return (a.dist or 1e9) < (b.dist or 1e9) end
        return (a.rating or 0) > (b.rating or 0)
    end)

    -- Favorites (saved carts) for the reorder shortcut.
    local favorites = MySQL.query.await(
        "SELECT id, restaurant_id, label, cart, created_at FROM pickle_restaurant_favorites WHERE identifier = ? ORDER BY id DESC LIMIT 20", { id }) or {}
    for _, f in ipairs(favorites) do
        f.cart = f.cart and json.decode(f.cart) or {}
        local r = GetRestaurant(f.restaurant_id)
        f.restaurant = r and (r.label or r.name) or "Closed"
    end

    -- The player's own live + recent orders (across all restaurants).
    local orders = PlayerOrders(id, 8)

    -- Loyalty summary across restaurants the player has punches at.
    local loyalty = {}
    for rid, byId in pairs(LoyaltyCache) do
        local l = byId[id]
        if l and (l.punches > 0 or l.redeemed > 0) then
            local r = GetRestaurant(rid)
            loyalty[#loyalty + 1] = {
                id = rid, label = r and (r.label or r.name) or ("#" .. rid),
                punches = l.punches, goal = LoyaltyGoal(), redeemed = l.redeemed,
            }
        end
    end

    return {
        ok         = true,
        name       = GetPlayerCharacterName(src),
        currency   = GetSetting("currency", "$"),
        -- ONE global phone skin (the `phone_theme` setting) — NOT per-restaurant. The
        -- app applies this once on boot and keeps it for every storefront it browses.
        theme      = GetSetting("phone_theme", nil),
        restaurants= cards,
        favorites  = favorites,
        orders     = orders,
        loyalty    = loyalty,
        loyaltyGoal= LoyaltyGoal(),
        loyaltyOn  = LoyaltyOn(),
        employment = EmploymentFor(src),
        achievements = PlayerAchievements(id),
    }
end)

-- Player's orders (live open + recent closed), newest first. Reads the orders table
-- directly (cache only holds OPEN rows) and annotates each with a coarse phone
-- status for the tracking screen.
function PlayerOrders(identifier, limit)
    local rows = MySQL.query.await([[
        SELECT o.id, o.restaurant_id, o.ticket, o.total, o.status, o.order_type,
               o.scheduled_for, o.address, o.rated, o.created_at, o.closed_at, o.`lines`
          FROM `pickle_restaurant_orders` o
         WHERE o.customer_identifier = ?
         ORDER BY o.id DESC LIMIT ?
    ]], { identifier, limit or 12 }) or {}
    local out = {}
    for _, o in ipairs(rows) do
        local r = GetRestaurant(o.restaurant_id)
        local lines = o.lines and json.decode(o.lines) or {}
        -- Live fulfilment readiness (only meaningful while open + cached).
        local ready = false
        local cached = OrderCache[o.restaurant_id] and OrderCache[o.restaurant_id][o.id]
        if cached and OrderReadyForPickup then ready = OrderReadyForPickup(o.restaurant_id, o.id) end
        out[#out + 1] = {
            orderId    = o.id,
            ticket     = o.ticket,
            restaurant = r and (r.label or r.name) or ("Restaurant #" .. o.restaurant_id),
            restaurantId = o.restaurant_id,
            theme      = r and r.metadata and r.metadata.theme or nil,
            total      = o.total,
            status     = o.status,
            type       = o.order_type or "pickup",
            scheduled  = o.scheduled_for,
            address    = o.address,
            rated      = (o.rated or 0) == 1,
            ready      = ready,
            lines      = lines,
            createdAt  = o.created_at,
            closedAt   = o.closed_at,
        }
    end
    return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MENU — the storefront for one restaurant (public, display-safe).
-- ─────────────────────────────────────────────────────────────────────────────
lib.callback.register("pickle_restaurants:phone:menu", function(src, d)
    local id = tonumber(d and d.id)
    local r = GetRestaurant(id)
    if not r then return { ok = false, error = "That restaurant is unavailable." } end

    local catalog = select(1, BuildPricedCatalog(id, true))
    local combos  = BuildComboCatalog(id)
    local rev = ReviewCache[id]
    local reviews = {}
    if rev then
        for i = 1, math.min(#rev.rows, 30) do
            local row = rev.rows[i]
            reviews[#reviews + 1] = {
                name = row.name or "Guest", rating = row.rating,
                comment = row.comment, photo = row.photo, createdAt = row.created_at,
            }
        end
    end

    local pid = GetIdentifier(src)
    local l = LoyaltyCache[id] and LoyaltyCache[id][pid]
    return {
        ok        = true,
        id        = id,
        label     = r.label or r.name,
        theme     = r.metadata and r.metadata.theme or nil,
        brand     = r.metadata and r.metadata.brand_image or nil,
        catalog   = catalog,
        combos    = combos,
        promo     = ActivePromo(id),
        rating    = rev and rev.avg or 0,
        reviewCount = rev and rev.count or 0,
        reviews   = reviews,
        loyalty   = { punches = l and l.punches or 0, goal = LoyaltyGoal(), on = LoyaltyOn() },
        currency  = GetSetting("currency", "$"),
    }
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- FAVORITES / reorder
-- ─────────────────────────────────────────────────────────────────────────────
lib.callback.register("pickle_restaurants:phone:saveFavorite", function(src, d)
    local id = GetIdentifier(src)
    local rid = tonumber(d and d.id)
    if not GetRestaurant(rid) then return { ok = false } end
    local cart = d.cart
    if type(cart) ~= "table" or #cart == 0 then return { ok = false, error = "Nothing to save." } end
    local label = tostring(d.label or "Favorite"):sub(1, 60)
    local fid = MySQL.insert.await(
        "INSERT INTO pickle_restaurant_favorites (identifier, restaurant_id, label, cart) VALUES (?, ?, ?, ?)",
        { id, rid, label, json.encode(cart) })
    return { ok = fid ~= nil, id = fid }
end)

lib.callback.register("pickle_restaurants:phone:deleteFavorite", function(src, d)
    local id = GetIdentifier(src)
    MySQL.update.await("DELETE FROM pickle_restaurant_favorites WHERE id = ? AND identifier = ?", { tonumber(d.id), id })
    return { ok = true }
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- REVIEWS & RATINGS
-- ─────────────────────────────────────────────────────────────────────────────
lib.callback.register("pickle_restaurants:phone:submitReview", function(src, d)
    local id = GetIdentifier(src)
    local rid = tonumber(d and d.id)
    if not GetRestaurant(rid) then return { ok = false } end
    local rating = math.max(1, math.min(5, math.floor(tonumber(d.rating) or 5)))
    -- Only guests who have actually ordered here may review (soft trust gate).
    local ordered = MySQL.scalar.await(
        "SELECT 1 FROM pickle_restaurant_orders WHERE restaurant_id = ? AND customer_identifier = ? LIMIT 1", { rid, id })
    if not ordered then return { ok = false, error = "Order here before leaving a review." } end
    local comment = d.comment and tostring(d.comment):sub(1, 400) or nil
    local photo = d.photo and tostring(d.photo):sub(1, 300) or nil
    MySQL.insert.await(
        "INSERT INTO pickle_restaurant_reviews (restaurant_id, identifier, name, rating, comment, photo) VALUES (?, ?, ?, ?, ?, ?)",
        { rid, id, GetPlayerCharacterName(src), rating, comment, photo })
    if d.orderId then
        MySQL.update("UPDATE pickle_restaurant_orders SET rated = 1 WHERE id = ? AND customer_identifier = ?", { tonumber(d.orderId), id })
    end
    LoadReviews()
    return { ok = true }
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- LOYALTY — punch on every completed order; redeem a free item at the goal.
-- Incremented from the orderCompleted seam below.
-- ─────────────────────────────────────────────────────────────────────────────
local function LoyaltyPunch(rid, identifier)
    if not LoyaltyOn() then return end
    LoyaltyCache[rid] = LoyaltyCache[rid] or {}
    local l = LoyaltyCache[rid][identifier] or { punches = 0, redeemed = 0 }
    l.punches = l.punches + 1
    LoyaltyCache[rid][identifier] = l
    MySQL.query.await([[
        INSERT INTO pickle_restaurant_loyalty (restaurant_id, identifier, punches) VALUES (?, ?, 1)
        ON DUPLICATE KEY UPDATE punches = punches + 1
    ]], { rid, identifier })
    return l.punches
end

-- Redemption is applied ATOMICALLY inside sales:placeOrder (a free item = the
-- cheapest line's price off the total). These two globals are the check + commit
-- it calls, so a failed order never burns a punch card.
function PhoneCanRedeem(rid, identifier)
    if not LoyaltyOn() then return false end
    local l = LoyaltyCache[rid] and LoyaltyCache[rid][identifier]
    return l ~= nil and l.punches >= LoyaltyGoal()
end

function PhoneCommitRedeem(rid, identifier)
    local goal = LoyaltyGoal()
    local l = LoyaltyCache[rid] and LoyaltyCache[rid][identifier]
    if not l or l.punches < goal then return false end
    l.punches = l.punches - goal
    l.redeemed = l.redeemed + 1
    MySQL.query.await("UPDATE pickle_restaurant_loyalty SET punches = ?, redeemed = ? WHERE restaurant_id = ? AND identifier = ?",
        { l.punches, l.redeemed, rid, identifier })
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- RESERVATIONS — book a private booth; the client teleports into an instanced
-- routing bucket on enter (see modules/phone/client.lua).
-- ─────────────────────────────────────────────────────────────────────────────
lib.callback.register("pickle_restaurants:phone:reserve", function(src, d)
    local id = GetIdentifier(src)
    local rid = tonumber(d and d.id)
    if not GetRestaurant(rid) then return { ok = false } end
    local party = math.max(1, math.min(12, math.floor(tonumber(d.party) or 2)))
    local slot = d.slot and tostring(d.slot):sub(1, 20) or nil
    local resId = MySQL.insert.await(
        "INSERT INTO pickle_restaurant_reservations (restaurant_id, identifier, name, party, slot) VALUES (?, ?, ?, ?, ?)",
        { rid, id, GetPlayerCharacterName(src), party, slot })
    ReservationCache[rid] = ReservationCache[rid] or {}
    ReservationCache[rid][resId] = { id = resId, restaurant_id = rid, identifier = id,
        name = GetPlayerCharacterName(src), party = party, slot = slot, status = "booked" }
    return { ok = true, id = resId }
end)

lib.callback.register("pickle_restaurants:phone:cancelReservation", function(src, d)
    local id = GetIdentifier(src)
    local resId = tonumber(d and d.id)
    MySQL.update.await("UPDATE pickle_restaurant_reservations SET status = 'cancelled' WHERE id = ? AND identifier = ?", { resId, id })
    for _, byId in pairs(ReservationCache) do byId[resId] = nil end
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:phone:myReservations", function(src, d)
    local id = GetIdentifier(src)
    local rows = MySQL.query.await(
        "SELECT id, restaurant_id, party, slot, status, created_at FROM pickle_restaurant_reservations WHERE identifier = ? AND status = 'booked' ORDER BY id DESC", { id }) or {}
    for _, row in ipairs(rows) do
        local r = GetRestaurant(row.restaurant_id)
        row.restaurant = r and (r.label or r.name) or ("#" .. row.restaurant_id)
    end
    return { ok = true, reservations = rows }
end)

-- Enter the private dining booth for a reservation: put the player in an instanced
-- routing bucket (so the booth is theirs) and hand the client the booth coords to
-- teleport to. The client teleports + remembers where to return them on leave.
PhoneBoothReturn = {} -- [src] = { x, y, z, heading, bucket } prior state
lib.callback.register("pickle_restaurants:phone:enterBooth", function(src, d)
    local id = GetIdentifier(src)
    local resId = tonumber(d and d.id)
    local res = ReservationCache[tonumber(d.rid)] and ReservationCache[tonumber(d.rid)][resId]
    if not res or res.identifier ~= id then return { ok = false, error = "No reservation found." } end
    local bucket = 6000 + resId
    SetPlayerRoutingBucket(tostring(src), bucket)
    return { ok = true, bucket = bucket }
end)

lib.callback.register("pickle_restaurants:phone:leaveBooth", function(src)
    SetPlayerRoutingBucket(tostring(src), 0)
    return { ok = true }
end)

AddEventHandler("playerDropped", function()
    local src = source
    if GetPlayerRoutingBucket(tostring(src)) ~= 0 then SetPlayerRoutingBucket(tostring(src), 0) end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- STAFF — clock in / out + tip-pool accrual
-- ─────────────────────────────────────────────────────────────────────────────
lib.callback.register("pickle_restaurants:phone:shiftStatus", function(src, d)
    local id = GetIdentifier(src)
    local rid = tonumber(d and d.id)
    local perms = ResolvePerms(rid, src)
    if not perms then return { ok = false, error = "You don't work here." } end
    local open = ShiftCache[rid] and ShiftCache[rid][id]
    -- Roster: everyone currently clocked in here (for the tip-pool split preview).
    local roster = {}
    for pid, sh in pairs(ShiftCache[rid] or {}) do
        roster[#roster + 1] = { name = sh.name, tips = sh.tips or 0, since = sh.clock_in_ts }
    end
    return {
        ok = true,
        clockedIn = open ~= nil,
        since = open and open.clock_in_ts or nil,
        tips = open and open.tips or 0,
        roster = roster,
    }
end)

lib.callback.register("pickle_restaurants:phone:clockIn", function(src, d)
    local id = GetIdentifier(src)
    local rid = tonumber(d and d.id)
    local perms = ResolvePerms(rid, src)
    if not perms then return { ok = false, error = "You don't work here." } end
    if ShiftCache[rid] and ShiftCache[rid][id] then return { ok = true } end
    local name = GetPlayerCharacterName(src)
    local shiftId = MySQL.insert.await(
        "INSERT INTO pickle_restaurant_shifts (restaurant_id, identifier, name) VALUES (?, ?, ?)", { rid, id, name })
    ShiftCache[rid] = ShiftCache[rid] or {}
    ShiftCache[rid][id] = { shiftId = shiftId, name = name, tips = 0, cooked = 0, clock_in_ts = Now() }
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:phone:clockOut", function(src, d)
    local id = GetIdentifier(src)
    local rid = tonumber(d and d.id)
    local sh = ShiftCache[rid] and ShiftCache[rid][id]
    if not sh then return { ok = false, error = "You're not clocked in." } end
    local secs = Now() - (sh.clock_in_ts or Now())
    MySQL.update.await(
        "UPDATE pickle_restaurant_shifts SET clock_out = NOW(), seconds = ?, tips = ?, orders_cooked = ? WHERE id = ?",
        { secs, sh.tips or 0, sh.cooked or 0, sh.shiftId })
    ShiftCache[rid][id] = nil
    return { ok = true, seconds = secs, tips = sh.tips or 0 }
end)

-- Called by the sales tip path (see the orderCompleted seam) to split a tip across
-- everyone currently on shift at that restaurant. Even split, remainder to the cook.
function DistributeTip(rid, amount, cookIdentifier)
    local onShift = {}
    for pid, sh in pairs(ShiftCache[rid] or {}) do onShift[#onShift + 1] = pid end
    if #onShift == 0 then return end
    local each = math.floor(amount / #onShift)
    local rem = amount - each * #onShift
    for _, pid in ipairs(onShift) do
        local sh = ShiftCache[rid][pid]
        sh.tips = (sh.tips or 0) + each + (pid == cookIdentifier and rem or 0)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- OWNER — sales analytics rollup + promotions
-- ─────────────────────────────────────────────────────────────────────────────
lib.callback.register("pickle_restaurants:phone:analytics", function(src, d)
    local rid = tonumber(d and d.id)
    if not HasPerm(rid, src, "view_finances") then return { ok = false, error = "No access." } end
    local r = GetRestaurant(rid)

    -- Revenue / payroll / refunds from the ledger (last 30 days).
    local ledger = MySQL.query.await([[
        SELECT type, amount, created_at FROM pickle_restaurant_ledger
         WHERE restaurant_id = ? AND created_at >= (NOW() - INTERVAL 30 DAY)
    ]], { rid }) or {}
    local revenue, payroll, refunds = 0, 0, 0
    local byDay = {}   -- yyyy-mm-dd → revenue
    for _, e in ipairs(ledger) do
        local day = tostring(e.created_at):sub(1, 10)
        if e.type == "sale" then revenue = revenue + e.amount; byDay[day] = (byDay[day] or 0) + e.amount
        elseif e.type == "payroll" then payroll = payroll + e.amount
        elseif e.type == "refund" then refunds = refunds + math.abs(e.amount) end
    end
    local days = {}
    for day, amt in pairs(byDay) do days[#days + 1] = { day = day, revenue = amt } end
    table.sort(days, function(a, b) return a.day < b.day end)

    -- Best-sellers + peak hours from completed orders (last 30 days).
    local orders = MySQL.query.await([[
        SELECT `lines`, total, created_at FROM `pickle_restaurant_orders`
         WHERE restaurant_id = ? AND status = 'completed' AND created_at >= (NOW() - INTERVAL 30 DAY)
    ]], { rid }) or {}
    local sellers, hours, ticketCount = {}, {}, 0
    for h = 0, 23 do hours[h] = 0 end
    for _, o in ipairs(orders) do
        ticketCount = ticketCount + 1
        local hr = tonumber(tostring(o.created_at):sub(12, 13)) or 0
        hours[hr] = (hours[hr] or 0) + 1
        for _, line in ipairs(o.lines and json.decode(o.lines) or {}) do
            local key = line.label or line.item
            sellers[key] = sellers[key] or { label = key, qty = 0, image = line.image }
            sellers[key].qty = sellers[key].qty + (line.qty or 1)
        end
    end
    local best = {}
    for _, s in pairs(sellers) do best[#best + 1] = s end
    table.sort(best, function(a, b) return a.qty > b.qty end)
    while #best > 8 do table.remove(best) end
    local peak = {}
    for h = 0, 23 do peak[#peak + 1] = { hour = h, orders = hours[h] } end

    return {
        ok = true,
        balance = r and r.balance or 0,
        revenue = revenue, payroll = payroll, refunds = refunds,
        tickets = ticketCount,
        avgTicket = ticketCount > 0 and math.floor(revenue / ticketCount) or 0,
        days = days, bestSellers = best, peak = peak,
        currency = GetSetting("currency", "$"),
    }
end)

lib.callback.register("pickle_restaurants:phone:promos", function(src, d)
    local rid = tonumber(d and d.id)
    if not HasPerm(rid, src, "manage_menu") then return { ok = false, error = "No access." } end
    local rows = MySQL.query.await("SELECT id, label, percent, kind, active FROM pickle_restaurant_promos WHERE restaurant_id = ? ORDER BY id DESC", { rid }) or {}
    return { ok = true, promos = rows }
end)

lib.callback.register("pickle_restaurants:phone:savePromo", function(src, d)
    local rid = tonumber(d and d.id)
    if not HasPerm(rid, src, "manage_menu") then return { ok = false, error = "No access." } end
    local label = tostring(d.label or "Promo"):sub(1, 60)
    local percent = math.max(1, math.min(90, math.floor(tonumber(d.percent) or 10)))
    local kind = (d.kind == "happy_hour") and "happy_hour" or "discount"
    local active = d.active ~= false
    local promoId = d.promoId and tonumber(d.promoId)
    if promoId then
        MySQL.update.await("UPDATE pickle_restaurant_promos SET label=?, percent=?, kind=?, active=? WHERE id=? AND restaurant_id=?",
            { label, percent, kind, active and 1 or 0, promoId, rid })
    else
        promoId = MySQL.insert.await("INSERT INTO pickle_restaurant_promos (restaurant_id, label, percent, kind, active) VALUES (?, ?, ?, ?, ?)",
            { rid, label, percent, kind, active and 1 or 0 })
    end
    LoadPromos()
    SyncToClient(-1)
    -- Broadcast the promo to every phone as a push, DoorDash-style.
    if active then
        local r = GetRestaurant(rid)
        TriggerClientEvent("pickle_restaurants:phone:pushPromo", -1, {
            title = ("%s — %d%% off"):format(r and (r.label or r.name) or "Restaurant", percent),
            content = label, rid = rid,
        })
    end
    return { ok = true, id = promoId }
end)

lib.callback.register("pickle_restaurants:phone:deletePromo", function(src, d)
    local rid = tonumber(d and d.id)
    if not HasPerm(rid, src, "manage_menu") then return { ok = false, error = "No access." } end
    MySQL.update.await("DELETE FROM pickle_restaurant_promos WHERE id = ? AND restaurant_id = ?", { tonumber(d.promoId), rid })
    LoadPromos()
    return { ok = true }
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- SOCIAL — top-chef leaderboard + achievements
-- ─────────────────────────────────────────────────────────────────────────────
lib.callback.register("pickle_restaurants:phone:leaderboard", function(src, d)
    local rid = tonumber(d and d.id)   -- nil = global across all restaurants
    local tally = {}
    local function add(identifier, name, cooked, revenue)
        tally[identifier] = tally[identifier] or { name = name, cooked = 0, revenue = 0 }
        tally[identifier].cooked = tally[identifier].cooked + cooked
        tally[identifier].revenue = tally[identifier].revenue + revenue
        if name then tally[identifier].name = name end
    end
    if rid then
        for pid, s in pairs(CookStatCache[rid] or {}) do add(pid, s.name, s.cooked, s.revenue) end
    else
        for _, byId in pairs(CookStatCache) do
            for pid, s in pairs(byId) do add(pid, s.name, s.cooked, s.revenue) end
        end
    end
    local list = {}
    local myId = GetIdentifier(src)
    for pid, s in pairs(tally) do
        list[#list + 1] = { name = s.name or "Chef", cooked = s.cooked, revenue = s.revenue, me = pid == myId }
    end
    table.sort(list, function(a, b) return a.cooked > b.cooked end)
    while #list > 25 do table.remove(list) end
    return { ok = true, leaderboard = list }
end)

function PlayerAchievements(identifier)
    local mine = AchievementCache[identifier] or {}
    -- Lifetime cooked = max progress recorded on any milestone (they share the counter).
    local cooked = 0
    for _, a in pairs(mine) do cooked = math.max(cooked, a.progress or 0) end
    local out = {}
    for _, def in ipairs(PHONE_ACHIEVEMENTS) do
        local a = mine[def.key]
        out[#out + 1] = {
            key = def.key, label = def.label, desc = def.desc, goal = def.goal,
            progress = math.min(cooked, def.goal),
            unlocked = (a and a.unlocked) or cooked >= def.goal,
        }
    end
    return out
end

-- Record one cooked ticket against a player's milestones; unlock + notify on cross.
local function BumpAchievements(src, identifier)
    AchievementCache[identifier] = AchievementCache[identifier] or {}
    local mine = AchievementCache[identifier]
    local cooked = 0
    for _, a in pairs(mine) do cooked = math.max(cooked, a.progress or 0) end
    cooked = cooked + 1
    for _, def in ipairs(PHONE_ACHIEVEMENTS) do
        local a = mine[def.key] or { progress = 0, unlocked = false }
        a.progress = cooked
        if not a.unlocked and cooked >= def.goal then
            a.unlocked = true
            MySQL.query.await([[
                INSERT INTO pickle_restaurant_achievements (identifier, akey, progress, unlocked_at)
                VALUES (?, ?, ?, NOW())
                ON DUPLICATE KEY UPDATE progress = VALUES(progress), unlocked_at = NOW()
            ]], { identifier, def.key, cooked })
            if src then PhoneNotify(src, "Achievement unlocked", def.label .. " — " .. def.desc) end
        else
            MySQL.query.await([[
                INSERT INTO pickle_restaurant_achievements (identifier, akey, progress)
                VALUES (?, ?, ?)
                ON DUPLICATE KEY UPDATE progress = VALUES(progress)
            ]], { identifier, def.key, cooked })
        end
        mine[def.key] = a
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- The completion seam. modules/sales fires this on a completed ticket:
--   TriggerEvent("pickle_restaurants:internal:orderCompleted", rid, order, cookSrc, tip)
-- We use it for loyalty punches (customer), cook stats + achievements + leaderboard
-- (cook), and tip-pool accrual.
-- ─────────────────────────────────────────────────────────────────────────────
AddEventHandler("pickle_restaurants:internal:orderCompleted", function(rid, order, cookSrc, tip)
    if not order then return end
    -- Loyalty punch for a real player customer (skip NPCs / anon).
    local cust = order.customer_identifier
    if cust and not tostring(cust):find("^npc:") then
        local punches = LoyaltyPunch(rid, cust)
        if punches and punches >= LoyaltyGoal() then
            local custSrc = SourceForIdentifier and SourceForIdentifier(cust)
            if custSrc then PhoneNotify(custSrc, "Free item unlocked!", "You've earned a reward. Redeem it at checkout.") end
        end
    end

    -- Cook credit: stats, achievements, leaderboard, tip pool.
    if cookSrc then
        local cookId = GetIdentifier(cookSrc)
        if cookId then
            CookStatCache[rid] = CookStatCache[rid] or {}
            local s = CookStatCache[rid][cookId] or { name = GetPlayerCharacterName(cookSrc), cooked = 0, revenue = 0 }
            s.cooked = s.cooked + 1
            s.revenue = s.revenue + (order.total or 0)
            s.name = GetPlayerCharacterName(cookSrc)
            CookStatCache[rid][cookId] = s
            MySQL.query.await([[
                INSERT INTO pickle_restaurant_cook_stats (restaurant_id, identifier, name, cooked, revenue)
                VALUES (?, ?, ?, 1, ?)
                ON DUPLICATE KEY UPDATE cooked = cooked + 1, revenue = revenue + VALUES(revenue), name = VALUES(name)
            ]], { rid, cookId, s.name, order.total or 0 })
            BumpAchievements(cookSrc, cookId)
            local sh = ShiftCache[rid] and ShiftCache[rid][cookId]
            if sh then sh.cooked = (sh.cooked or 0) + 1 end
        end
        if tip and tip > 0 then DistributeTip(rid, tip, GetIdentifier(cookSrc)) end
    end

    -- Nudge the customer's phone that their food is ready / on the way.
    local custSrc = SourceForIdentifier and SourceForIdentifier(order.customer_identifier)
    if custSrc then
        local r = GetRestaurant(rid)
        local verb = (order.order_type == "delivery") and "is on the way" or "is ready for pickup"
        PhoneNotify(custSrc, "Order ready", ("%s — Ticket #%s %s"):format(r and (r.label or r.name) or "Your order", order.ticket or "?", verb))
    end
end)

-- Resolve an online player's source from their identifier (for push notifications).
function SourceForIdentifier(identifier)
    for _, src in ipairs(GetPlayers()) do
        if GetIdentifier(tonumber(src)) == identifier then return tonumber(src) end
    end
    return nil
end
