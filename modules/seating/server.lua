-- =============================================
--  modules/seating | server.lua
--  Seat occupancy for the invisible sit anchors (prop_type "seat"). Purely to
--  stop two players sharing one anchor and clipping into each other — the sit
--  itself is a client animation. A seat is freed when its occupant stands, drops,
--  or the seat prop is deleted.
-- =============================================

local SeatOccupancy = {} -- [propId] = src currently seated there

-- Reserve a seat. Rejects an anchor that isn't a seat or is already taken by
-- someone else (re-requesting your own seat is a no-op success).
lib.callback.register("pickle_restaurants:seating:sit", function(src, d)
    local propId = tonumber(d and d.id)
    local prop = propId and PropCache[propId]
    if not prop or prop.prop_type ~= "seat" then return { ok = false, error = _L("seat_cant_sit") } end
    local holder = SeatOccupancy[propId]
    if holder and holder ~= src then return { ok = false, error = _L("seat_taken") } end
    SeatOccupancy[propId] = src
    return { ok = true }
end)

RegisterNetEvent("pickle_restaurants:seating:stand", function(propId)
    propId = tonumber(propId)
    if propId and SeatOccupancy[propId] == source then SeatOccupancy[propId] = nil end
end)

-- Free every seat a leaving player held.
AddEventHandler("playerDropped", function()
    for propId, holder in pairs(SeatOccupancy) do
        if holder == source then SeatOccupancy[propId] = nil end
    end
end)

-- A deleted seat frees its reservation (the occupant's client auto-stands).
AddEventHandler("pickle_restaurants:propDeleted", function(propId)
    SeatOccupancy[tonumber(propId)] = nil
end)
