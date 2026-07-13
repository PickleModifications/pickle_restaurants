-- =============================================
--  modules/npc_customers | server.lua
--  AI customers that walk up to a restaurant's counter, queue, and place a REAL POS
--  ticket off the restaurant's priced menu. Staff cook the items from the shared
--  cooked-items pool and hit Complete at the register exactly as they would for a
--  player order — the NPC then pays into the restaurant balance (+ maybe a tip) and
--  walks away. An NPC that waits past its patience leaves unserved (no money moves).
--
--  The whole thing reuses modules/sales: an NPC order is an ordinary ticket whose
--  `customer_identifier` carries an "npc:" prefix (IsNpcOrder). OrderCache, CreateOrder,
--  GetOpenOrders, AnnotateOrders, PlanFulfillment, SyncOrders and the register/Tickets
--  widget all treat it like any other ticket. The completion/cancel BRANCH for NPCs
--  lives in modules/sales/server.lua and calls the globals exposed at the bottom here.
--
--  The server is authoritative over the queue (NpcState); clients (modules/npc_customers
--  /client.lua) render frozen local peds positioned from the counter transform + geometry
--  that rides in every broadcast.
-- =============================================

-- ─── config (validate on read) ───────────────────────────────────────────────
-- Mirror the drinks/finishes precedent: never trust the raw NUI-written setting.
-- NpcConfig() merges the stored map over safe code defaults and CLAMPS every number,
-- so a bad admin edit can throttle/disable the system but can never break the world.

local CFG_DEFAULTS = {
    enabled          = true,
    require_staff    = true,
    staff_radius     = 30.0,
    spawn_interval   = 45,
    max_queue        = 4,
    patience_seconds = 300,
    min_items        = 1,
    max_items        = 2,
    tip_chance       = 25,
    tip_max_percent  = 15,
    counter_offset   = 1.0,
    queue_spacing    = 0.85,
    spawn_distance   = 6.0,
    models = { "a_m_y_business_01", "a_f_y_business_02", "a_m_m_business_01",
               "a_f_y_hipster_02", "a_m_y_hipster_01", "a_f_m_business_02" },
}

local function num(v, default, lo, hi)
    v = tonumber(v)
    if v == nil then v = default end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

function NpcConfig()
    local raw = GetSetting("npc_customers", {})
    if type(raw) ~= "table" then raw = {} end
    local models = {}
    if type(raw.models) == "table" then
        for _, m in ipairs(raw.models) do
            if type(m) == "string" and m ~= "" then models[#models + 1] = m end
        end
    end
    if #models == 0 then models = CFG_DEFAULTS.models end
    local minI = num(raw.min_items, CFG_DEFAULTS.min_items, 1, 5)
    local maxI = num(raw.max_items, CFG_DEFAULTS.max_items, 1, 5)
    if maxI < minI then maxI = minI end
    return {
        enabled          = (raw.enabled ~= false),
        require_staff    = (raw.require_staff ~= false),
        staff_radius     = num(raw.staff_radius, CFG_DEFAULTS.staff_radius, 3.0, 200.0),
        spawn_interval   = num(raw.spawn_interval, CFG_DEFAULTS.spawn_interval, 5, 3600),
        max_queue        = math.floor(num(raw.max_queue, CFG_DEFAULTS.max_queue, 1, 12)),
        patience_seconds = num(raw.patience_seconds, CFG_DEFAULTS.patience_seconds, 15, 3600),
        min_items        = math.floor(minI),
        max_items        = math.floor(maxI),
        tip_chance       = num(raw.tip_chance, CFG_DEFAULTS.tip_chance, 0, 100),
        tip_max_percent  = num(raw.tip_max_percent, CFG_DEFAULTS.tip_max_percent, 0, 100),
        counter_offset   = num(raw.counter_offset, CFG_DEFAULTS.counter_offset, 0.0, 5.0),
        queue_spacing    = num(raw.queue_spacing, CFG_DEFAULTS.queue_spacing, 0.3, 3.0),
        spawn_distance   = num(raw.spawn_distance, CFG_DEFAULTS.spawn_distance, 1.0, 30.0),
        models           = models,
    }
end

-- Just the client-facing geometry knobs, folded into every broadcast so the client
-- lays the queue out exactly as configured without its own copy of the settings.
local function geometry(cfg)
    return { counter_offset = cfg.counter_offset,
             queue_spacing  = cfg.queue_spacing,
             spawn_distance  = cfg.spawn_distance }
end

-- ─── runtime state ───────────────────────────────────────────────────────────

-- NpcState[rid] = { queue = { { orderId, model, expiresAt }, ... }, lastSpawn = os.time() }
local NpcState = {}
local NpcSeq   = 0 -- monotonic id for the "npc:<n>" customer identifier

local FIRST_NAMES = {
    "Alex", "Sam", "Jordan", "Casey", "Riley", "Morgan", "Taylor", "Jamie", "Drew",
    "Quinn", "Avery", "Reese", "Skyler", "Devon", "Harper", "Rowan", "Emerson", "Micah",
}
local LAST_NAMES = {
    "Reed", "Cole", "Vance", "Boyle", "Frost", "Nash", "Ellis", "Dorset", "Kline",
    "Marsh", "Pike", "Rhodes", "Sable", "Tarrow", "Voss", "Wynn", "Ashby", "Barlow",
}
local function randomName()
    return FIRST_NAMES[math.random(#FIRST_NAMES)] .. " " .. LAST_NAMES[math.random(#LAST_NAMES)]
end

local function counterVec(r)
    local c = r and r.counter
    if not c then return nil end
    return vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0)
end

-- The admin-placed spawn point for this restaurant (metadata.npc_spawn), or nil.
-- When set, clients start a new customer's walk-in HERE; when nil they fall back to
-- the legacy computed point (spawn_distance back along the queue line).
local function spawnPoint(r)
    return r and r.metadata and r.metadata.npc_spawn or nil
end

-- ─── presence gating ─────────────────────────────────────────────────────────
-- Returns anyoneNear (a player is within `radius` of the counter — worth rendering
-- for at all) and staffNear (that player can work this restaurant).

local function scanCounter(rid, coords, radius)
    local anyoneNear, staffNear = false, false
    for _, p in ipairs(GetPlayers()) do
        p = tonumber(p)
        local ped = GetPlayerPed(p)
        if ped and ped ~= 0 then
            if #(GetEntityCoords(ped) - coords) <= radius then
                anyoneNear = true
                if HasPerm(rid, p, "sell") or HasPerm(rid, p, "cook") then
                    staffNear = true
                    break
                end
            end
        end
    end
    return anyoneNear, staffNear
end

-- ─── queue helpers ───────────────────────────────────────────────────────────

local function queueIndexOf(st, orderId)
    for i, e in ipairs(st.queue) do
        if e.orderId == orderId then return i - 1 end -- 0-based, front = 0
    end
    return nil
end

-- Broadcast the current queue-index map so every client walks its NPCs to the right
-- slots after someone joins/leaves.
local function broadcastQueue(rid, r, cfg)
    local st = NpcState[rid]
    if not st then return end
    local map = {}
    for i, e in ipairs(st.queue) do map[tostring(e.orderId)] = i - 1 end
    TriggerClientEvent("pickle_restaurants:npc:queue", -1, {
        rid = rid, counter = r.counter, geo = geometry(cfg), queue = map,
    })
end

-- Remove an order from the queue and tell clients to walk the NPC away (happy or not),
-- then re-slot the rest. Does NOT touch the order lifecycle — the caller owns that.
function NpcDropOrder(rid, orderId, happy)
    local st = NpcState[rid]
    if not st then return end
    local removed = false
    for i, e in ipairs(st.queue) do
        if e.orderId == orderId then table.remove(st.queue, i); removed = true; break end
    end
    if not removed then return end
    TriggerClientEvent("pickle_restaurants:npc:despawn", -1, rid, orderId, happy == true)
    local r = GetRestaurant(rid)
    if r then broadcastQueue(rid, r, NpcConfig()) end
end

-- An NPC gives up waiting: cancel its ticket (no refund — NPCs pay on serve) and leave.
local function abandonNpcOrder(rid, orderId)
    local o = OrderCache[rid] and OrderCache[rid][orderId]
    if o and o.status == "open" then CloseOrder(rid, orderId, "cancelled") end
    NpcDropOrder(rid, orderId, false)
    if SyncOrders then SyncOrders(rid) end
end

-- ─── spawning ────────────────────────────────────────────────────────────────

-- Build one POS line from a priced-catalog entry, in the exact shape sales:createOrder
-- produces, so PlanFulfillment / completeOrder read an NPC line identically to a player's.
local function lineFromEntry(e, qty)
    local variant, mods = e.variant, nil
    -- Drinks are ONE sellable with the flavor as a single-choice modifier; an NPC
    -- picks a random flavor so its ticket pins one (kitchen matching + a chip on the
    -- receipt), mirroring what resolveLineModifiers records for a player's order.
    if e.kind == "drink" and type(e.modifiers) == "table" and #e.modifiers > 0 then
        local m = e.modifiers[math.random(#e.modifiers)]
        variant = m.variant or e.variant
        local label = m.group and (tostring(m.group) .. ": " .. tostring(m.label)) or m.label
        mods = { { id = m.id, label = label, price = 0, added = true, image = m.image, color = m.color } }
    end
    return {
        item    = e.item,
        variant = variant,
        label   = e.label,
        image   = e.image or GetItemImage(e.item),
        price   = e.price,
        qty     = qty or 1,
        kind    = e.kind,
        mods    = mods,
    }
end

local function spawnNpcCustomer(rid, r, cfg)
    -- Orderable menu (priced + enabled + valid). Empty menu → nothing to sell.
    local catalog = BuildPricedCatalog(rid, true)
    if not catalog or #catalog == 0 then return end

    local count = math.random(cfg.min_items, cfg.max_items)
    local lines, total = {}, 0
    for _ = 1, count do
        local e = catalog[math.random(#catalog)]
        local qty = 1
        lines[#lines + 1] = lineFromEntry(e, qty)
        total = total + e.price * qty
    end
    if #lines == 0 then return end
    total = RoundMoney(total)

    NpcSeq = NpcSeq + 1
    local order = CreateOrder(rid, {
        customer_identifier = "npc:" .. NpcSeq,
        customer_name       = randomName(),
        cashier_identifier  = "",
        lines               = lines,
        total               = total,
    })
    if not order or not order.id then return end

    local st = NpcState[rid]
    local model = cfg.models[math.random(#cfg.models)]
    st.queue[#st.queue + 1] = {
        orderId   = order.id,
        model     = model,
        expiresAt = os.time() + cfg.patience_seconds,
        patience  = cfg.patience_seconds, -- the full window, for the ticket UI's radial
    }
    st.lastSpawn = os.time()

    -- Ticket appears in every open register / Tickets widget.
    if SyncOrders then SyncOrders(rid) end
    -- Spawn the ped on all clients (each renders a local, distance-gated copy).
    TriggerClientEvent("pickle_restaurants:npc:spawn", -1, {
        rid        = rid,
        orderId    = order.id,
        model      = model,
        counter    = r.counter,
        spawn      = spawnPoint(r),
        geo        = geometry(cfg),
        queueIndex = #st.queue - 1,
        ticket     = order.ticket,
    })
end

-- ─── scheduler ───────────────────────────────────────────────────────────────
-- One thread drives every restaurant: it expires impatient NPCs, then spawns new
-- ones where the gates allow. Cheap — the heavy BuildPricedCatalog runs only on an
-- actual spawn (throttled by spawn_interval + max_queue).

CreateThread(function()
    -- Wait for the DB caches (restaurants, next-ticket numbers) before creating any
    -- order — the same gate admin/itemgen/core use.
    while not RestaurantsReady do Wait(200) end
    while true do
        Wait(3000)
        local cfg = NpcConfig()
        local now = os.time()
        for rid, r in pairs(RestaurantCache) do
            local coords = counterVec(r)
            local st = NpcState[rid]

            -- No counter (or system off): drop any lingering NPCs for this restaurant.
            if not coords or not cfg.enabled then
                if st and #st.queue > 0 then
                    for i = #st.queue, 1, -1 do abandonNpcOrder(rid, st.queue[i].orderId) end
                end
            else
                st = st or { queue = {}, lastSpawn = 0 }
                NpcState[rid] = st

                -- Expire the impatient (walk away unserved; ticket cancelled).
                for i = #st.queue, 1, -1 do
                    local e = st.queue[i]
                    local o = OrderCache[rid] and OrderCache[rid][e.orderId]
                    if not o or o.status ~= "open" or now >= e.expiresAt then
                        abandonNpcOrder(rid, e.orderId)
                    end
                end

                -- Spawn gating: presence, queue capacity, and the spawn interval.
                if #st.queue < cfg.max_queue and (now - (st.lastSpawn or 0)) >= cfg.spawn_interval then
                    local anyoneNear, staffNear = scanCounter(rid, coords, cfg.staff_radius)
                    local ok = anyoneNear and (not cfg.require_staff or staffNear)
                    if ok then spawnNpcCustomer(rid, r, cfg) end
                end
            end
        end
    end
end)

-- ─── late-joiner / approacher resync ─────────────────────────────────────────
-- A client that just booted or walked up asks for the current queues so it can render
-- NPCs that spawned before it arrived. We reply only to that source.

RegisterNetEvent("pickle_restaurants:npc:requestState", function()
    local src = source
    local cfg = NpcConfig()
    local out = {}
    for rid, st in pairs(NpcState) do
        local r = GetRestaurant(rid)
        if r and r.counter and #st.queue > 0 then
            local entries = {}
            for i, e in ipairs(st.queue) do
                local o = OrderCache[rid] and OrderCache[rid][e.orderId]
                entries[#entries + 1] = {
                    orderId    = e.orderId,
                    model      = e.model,
                    queueIndex = i - 1,
                    ticket     = o and o.ticket or nil,
                }
            end
            out[#out + 1] = { rid = rid, counter = r.counter, spawn = spawnPoint(r), geo = geometry(cfg), entries = entries }
        end
    end
    TriggerClientEvent("pickle_restaurants:npc:state", src, out)
end)

-- ─── globals for modules/sales (NPC completion branch) ───────────────────────

-- An order placed by an NPC customer (its ticket carries the "npc:" identifier).
function IsNpcOrder(o)
    return o and type(o.customer_identifier) == "string" and o.customer_identifier:sub(1, 4) == "npc:"
end

-- Is this NPC still waiting at the counter (not already served / walked off)?
function NpcOrderPresent(rid, orderId)
    local st = NpcState[rid]
    if not st then return false end
    return queueIndexOf(st, orderId) ~= nil
end

-- Remaining patience for an NPC's ticket, for the ticket UI's live countdown +
-- radial indicator: returns (secondsLeft, patienceWindow) — seconds left clamped
-- to >= 0, and the full patience window that is the radial's denominator. Returns
-- nil when this order isn't a currently-waiting NPC (a player ticket, or an NPC
-- that already walked). The client ticks the value down locally between broadcasts.
function NpcOrderTimer(rid, orderId)
    local st = NpcState[rid]
    if not st then return nil end
    for _, e in ipairs(st.queue) do
        if e.orderId == orderId then
            local left = e.expiresAt - os.time()
            if left < 0 then left = 0 end
            return left, (e.patience or left)
        end
    end
    return nil
end

-- A configured tip on a served order: 0 unless the roll hits, then 0..tip_max_percent%.
function NpcRollTip(total)
    local cfg = NpcConfig()
    if cfg.tip_chance <= 0 or cfg.tip_max_percent <= 0 then return 0 end
    if math.random(100) > cfg.tip_chance then return 0 end
    local pct = math.random(0, math.floor(cfg.tip_max_percent))
    return RoundMoney((tonumber(total) or 0) * pct / 100)
end
