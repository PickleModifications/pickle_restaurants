-- =============================================
--  modules/cookfx | server.lua
--  KITCHEN FIRES. Food left burning on a station eventually sets the station
--  alight. While a station is on fire nobody can work it, and putting the fire out
--  destroys whatever was on it — so a burnt tray isn't free to ignore.
--
--  Server-authoritative, like every other cooking state: the fire keeps burning
--  while nobody is looking, survives players leaving, and every client renders the
--  same one (modules/cookfx/client.lua owns only the particles).
--
--  It POLLS `BurntCookingItems()` rather than hooking each burn transition: burnt
--  food arrives through several paths (the single-state timer, either grill face,
--  an item placed already-burnt) and leaves through even more (collected, binned,
--  the prop deleted, a restart). One periodic reconcile can't miss a path or leak
--  a timer the way a dozen call-site hooks would.
-- =============================================

local Fires      = {} -- [propId] = { rid = restaurantId, since = os.time() }
local BurntSince = {} -- [uid]    = os.time() this item was FIRST seen burnt

local function cfg()
    local c = GetSetting("kitchen_fires", {})
    return type(c) == "table" and c or {}
end

-- Is this station burning? Read by cooking's openStation gate.
function StationOnFire(propId)
    return Fires[tonumber(propId) or -1] ~= nil
end

local function fireList()
    local out = {}
    for propId, f in pairs(Fires) do
        out[#out + 1] = { prop_id = propId, rid = f.rid }
    end
    return out
end

-- The two tunables the CLIENT needs (how long fighting a fire takes, how close you
-- have to be) ride along with the list, so an admin's retune applies immediately
-- instead of the client holding a second, stale copy of the settings.
local function broadcastFires(target)
    local c = cfg()
    TriggerClientEvent("pickle_restaurants:cookfx:fires", target or -1, fireList(), {
        ms    = math.max(500, tonumber(c.extinguish_ms) or 5000),
        reach = math.max(1.0, tonumber(c.reach) or 4.0),
    })
end

local function ignite(propId, rid)
    if Fires[propId] then return end
    Fires[propId] = { rid = rid, since = os.time() }
    -- Whoever was working this station is thrown out of it client-side; the claim
    -- they were holding has to be released here or the station stays "busy" for
    -- everyone, forever — re-opening it is exactly what the fire forbids.
    if ReleaseStationClaim then ReleaseStationClaim(propId) end
    broadcastFires()
end

local function douse(propId)
    if not Fires[propId] then return false end
    Fires[propId] = nil
    broadcastFires()
    return true
end

-- ─── the reconcile ───────────────────────────────────────────────────────────
CreateThread(function()
    while true do
        Wait(5000)
        local c = cfg()
        if c.enabled == false then
            -- switched off mid-service: put out anything still burning rather than
            -- leaving an un-extinguishable fire painted on a station forever.
            if next(Fires) then Fires = {}; broadcastFires() end
            BurntSince = {}
            goto continue
        end

        local delay = math.max(5, tonumber(c.delay_seconds) or 90)
        local now   = os.time()
        local seen  = {}
        for _, b in ipairs(BurntCookingItems and BurntCookingItems() or {}) do
            seen[b.uid] = true
            BurntSince[b.uid] = BurntSince[b.uid] or now
            if not Fires[b.prop_id] and (now - BurntSince[b.uid]) >= delay then
                ignite(b.prop_id, b.rid)
            end
        end
        -- forget items that are no longer burnt/present, so taking the food off
        -- (or serving it) genuinely resets the clock rather than banking it
        for uid in pairs(BurntSince) do
            if not seen[uid] then BurntSince[uid] = nil end
        end
        ::continue::
    end
end)

-- ─── extinguishing ───────────────────────────────────────────────────────────
-- Anyone standing at the station may fight the fire — deliberately NOT gated on
-- `cook`: a burning kitchen is everyone's problem, and gating it would let one
-- absent employee strand a restaurant. What it IS gated on is being there, and
-- (when the server installs one) carrying an extinguisher.
lib.callback.register("pickle_restaurants:cookfx:extinguish", function(src, d)
    local propId = tonumber(d and d.prop_id)
    local prop   = propId and PropCache[propId]
    if not prop then return { ok = false } end
    if not Fires[propId] then return { ok = false, error = _L("fire_already_out") } end

    local c    = cfg()
    local ped  = GetPlayerPed(src)
    local pos  = ped ~= 0 and GetEntityCoords(ped) or nil
    local reach = math.max(1.0, tonumber(c.reach) or 4.0)
    if not pos or #(pos - vector3(prop.x, prop.y, prop.z)) > reach + 1.5 then
        return { ok = false, error = _L("fire_too_far") }
    end

    -- The extinguisher is EQUIPMENT: you have to be holding one, but it is never
    -- consumed. A server that never installed the item skips the requirement.
    local item = c.extinguisher_item
    if type(item) == "string" and item ~= "" and ItemExists(item) then
        if (Inventory.GetItemCount(src, item) or 0) < 1 then
            return { ok = false, error = _L("fire_need_extinguisher", GetItemLabel(item)) }
        end
    end

    douse(propId)
    -- Everything the station was holding is ruined — including whatever burnt badly
    -- enough to start this.
    local lost = DestroyStationCookingItems and DestroyStationCookingItems(propId) or 0
    ShowNotification(src, lost > 0 and _L("fire_out_ruined", lost) or _L("fire_out"))
    return { ok = true, ruined = lost }
end)

-- ─── tuning ──────────────────────────────────────────────────────────────────
-- Waiting for food to burn and then sitting through `delay_seconds` is a slow way
-- to look at a fire, so: light the nearest station now. Admin only, and it goes
-- through the same ignite() as the real thing (same broadcast, same claim release,
-- same extinguisher rules) — it starts a REAL fire, it doesn't fake one.
RegisterCommand("pickle_fire", function(src, args)
    if src == 0 or not IsPlayerAdmin(src) then return end
    local ped = GetPlayerPed(src)
    local pos = ped ~= 0 and GetEntityCoords(ped)
    if not pos then return end
    local best, bestD
    for propId, prop in pairs(PropCache) do
        if prop.prop_type ~= "seat" and prop.prop_type ~= "virtual_point" then
            local d = #(pos - vector3(prop.x + 0.0, prop.y + 0.0, prop.z + 0.0))
            if not bestD or d < bestD then best, bestD = propId, d end
        end
    end
    if not best or bestD > 15.0 then
        return ShowNotification(src, ("[pickle_fire] no station within 15m (nearest %s)"):format(
            bestD and ("%.1fm"):format(bestD) or "none"))
    end
    if Fires[best] then
        douse(best)
        return ShowNotification(src, ("[pickle_fire] put prop #%d out"):format(best))
    end
    ignite(best, PropCache[best].restaurant_id)
    ShowNotification(src, ("[pickle_fire] prop #%d (%s) is alight"):format(best, PropCache[best].prop_type))
end, false)

-- Why a station hasn't caught fire. Every input the state machine reads, printed:
-- whether the feature is on, how long the delay is, what it currently considers
-- burnt and for how long, and what is already alight. "The fires don't happen" is
-- one of four things — disabled, nothing registering as burnt, the clock not
-- elapsed, or the fire lit but not drawn — and this says which.
RegisterCommand("pickle_fire_state", function(src)
    if src ~= 0 and not IsPlayerAdmin(src) then return end
    local c = cfg()
    local delay = math.max(5, tonumber(c.delay_seconds) or 90)
    print(("[pickle_fire] enabled=%s delay=%ss extinguish=%sms reach=%s item=%s"):format(
        tostring(c.enabled ~= false), delay, math.max(500, tonumber(c.extinguish_ms) or 5000),
        math.max(1.0, tonumber(c.reach) or 4.0), tostring(c.extinguisher_item)))
    if c.enabled == false then print("  ^3kitchen fires are DISABLED in Settings -> Kitchen fires^7") end
    local burnt, now = BurntCookingItems and BurntCookingItems() or {}, os.time()
    print(("  burnt items on stations: %d"):format(#burnt))
    for _, b in ipairs(burnt) do
        local since = BurntSince[b.uid]
        print(("    uid=%s prop=%s burnt for %ss / %ss%s"):format(
            tostring(b.uid), tostring(b.prop_id),
            since and (now - since) or 0, delay,
            Fires[b.prop_id] and "  (station ALIGHT)" or ""))
    end
    local n = 0
    for propId, f in pairs(Fires) do
        n = n + 1
        print(("  FIRE prop=%s restaurant=%s burning %ss"):format(propId, tostring(f.rid), now - f.since))
    end
    if n == 0 then print("  no stations on fire") end
end, false)

-- A removed station takes its fire with it.
AddEventHandler("pickle_restaurants:propDeleted", function(propId)
    douse(tonumber(propId))
end)

-- A (re)syncing client needs the current fires, exactly like the cooking bulk push.
RegisterNetEvent("pickle_restaurants:requestSync", function()
    broadcastFires(source)
end)
