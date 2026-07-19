-- =============================================
--  modules/stovetop | client.lua
--  Stovetop-station features (more coming). Today: the two oven doors every
--  stovetop carries — pickle_stovetop_door_01 props (left = #1, right = #2)
--  positioned from the stove's own transform, so they follow however the
--  station was placed. Doors open/close on click from the cooking UI; their
--  state is server-authoritative and synced to every client.
-- =============================================

-- Door framing, all in the stove's LOCAL space (x = right, y = front, z = up).
-- `offset` places the LEFT door (#1); `offset2` places the RIGHT door (#2) —
-- each tuned independently.
-- closedRot/openRot are pitch,roll,yaw deltas added on top of the stove's
-- rotation — tune openRot for how far / which way the door swings.
local DOOR = {
    model     = "pickle_stovetop_door_01",
    offset    = vector3(-0.305, -0.38, 0.395),
    offset2    = vector3(0.31, -0.38, 0.395),
    closedRot = vector3(0.0, 0.0, 0.0),
    openRot   = vector3(80.0, 0.0, 0.0),
    tween_ms  = 320,
}

-- Baking slots inside each door's cavity, LOCAL to the stove (behind the door front
-- face at y = -0.38, so deeper/less-negative y; a hair lower than the door hinge).
-- TUNE IN-GAME. Cookie/cake carry their own tray, pizza sits bare — all seated here.
local OVEN = {
    slots = {
        [1] = { 
            vector3(-0.305, -0.16, 0.44),
            vector3(-0.305, -0.16, 0.64),
        },
        [2] = { 
            vector3(0.31, -0.16, 0.44),
            vector3(0.31, -0.16, 0.64),
        },
    },
    z_seat = 0.0, -- extra lift so trayed food rests on the cavity floor
}

local OvenDoors = {} -- [propId] = { stove = entity, doors = { [door] = { entity, open, token } } }
local hovered   = { propId = nil, door = nil } -- door the cursor is currently over

local function SafeDeleteEntity(ent)
    if not ent or not DoesEntityExist(ent) then return end
    SetEntityAsMissionEntity(ent, true, true)
    DeleteEntity(ent)
end

local function lerp(a, b, t) return a + (b - a) * t end

-- Each door has its own independently-tuned offset.
local function doorOffset(door)
    return (door == 2) and DOOR.offset2 or DOOR.offset
end

-- Place + orient a door at open fraction t (0 = closed, 1 = open).
local function applyDoorTransform(stove, ent, door, t)
    if not DoesEntityExist(stove) or not DoesEntityExist(ent) then return end
    local o = doorOffset(door)
    local pos = GetOffsetFromEntityInWorldCoords(stove, o.x, o.y, o.z)
    SetEntityCoordsNoOffset(ent, pos.x, pos.y, pos.z, false, false, false)
    local sr = GetEntityRotation(stove, 2)
    local c, op = DOOR.closedRot, DOOR.openRot
    SetEntityRotation(ent,
        sr.x + lerp(c.x, op.x, t),
        sr.y + lerp(c.y, op.y, t),
        sr.z + lerp(c.z, op.z, t), 2, true)
end

-- ─── oven baking slots (used by the cooking module) ─────────────────────────

-- How many baking slots each door cavity holds.
function OvenSlotCount() return #OVEN.slots[1] end

-- World position of an oven slot, or nil if the stove/slot isn't known.
function OvenSlotWorld(propId, door, slot)
    local rec = OvenDoors[propId]
    local o = rec and door and slot and OVEN.slots[door] and OVEN.slots[door][slot]
    if not rec or not o or not DoesEntityExist(rec.stove) then return nil end
    return GetOffsetFromEntityInWorldCoords(rec.stove, o.x, o.y, o.z + OVEN.z_seat)
end

-- Seat a food entity in an oven slot, aligned to the stove's heading.
function SeatOvenSlot(propId, door, slot, ent)
    local rec = OvenDoors[propId]
    local o = rec and OVEN.slots[door] and OVEN.slots[door][slot]
    if not rec or not o or not DoesEntityExist(rec.stove) or not (ent and DoesEntityExist(ent)) then return end
    local pos = GetOffsetFromEntityInWorldCoords(rec.stove, o.x, o.y, o.z + OVEN.z_seat)
    SetEntityCoordsNoOffset(ent, pos.x, pos.y, pos.z, false, false, false)
    local sr = GetEntityRotation(rec.stove, 2)
    SetEntityRotation(ent, sr.x, sr.y, sr.z, 2, true)
end

-- Seat an ordered stack of food entities (bottom-to-top) in an oven slot: each part
-- lifted by the summed height of the parts below it, all aligned to the stove heading.
-- Renders an uncooked assembled bake (e.g. a topped pizza) as its full build stack
-- rather than just the base prop.
-- `offsets` (optional, parallel to ents) spreads layers horizontally in the tray
-- plane instead of stacking them — a batch bake (the six-cookie tray) lays its
-- servings out as a grid ON the tray. Each {dx, dy} is tray-local metres, rotated to
-- the stove's heading so the grid faces the oven like everything else.
function SeatOvenSlotStack(propId, door, slot, ents, heights, baseDz, rolls, offsets)
    local rec = OvenDoors[propId]
    local o = rec and OVEN.slots[door] and OVEN.slots[door][slot]
    if not rec or not o or not DoesEntityExist(rec.stove) then return end
    -- Slot anchor in the world; the stack rises straight UP from here (world Z), NOT
    -- along the stove's local axes. A stove resting with any pitch/roll would otherwise
    -- tip the tower sideways and push its top layer (e.g. the pizza cheese) into the
    -- cavity wall, so it appears to vanish on release. Layers keep only the stove's
    -- heading so they stay flat but still face the oven — matching the drag preview.
    -- `baseDz` (optional) lifts the whole tower: a container base layer's mesh-bottom
    -- correction, so a cake tin rests ON the rack instead of sinking through it.
    local base = GetOffsetFromEntityInWorldCoords(rec.stove, o.x, o.y, o.z + OVEN.z_seat)
    local sr = GetEntityRotation(rec.stove, 2)
    local hr = math.rad(sr.z)
    local lift = baseDz or 0.0
    for i, ent in ipairs(ents or {}) do
        if ent and DoesEntityExist(ent) then
            local wx, wy = base.x, base.y
            local ofs = offsets and offsets[i]
            if ofs then -- spread this layer across the tray plane (rotated to heading)
                wx = wx + ofs.dx * math.cos(hr) - ofs.dy * math.sin(hr)
                wy = wy + ofs.dx * math.sin(hr) + ofs.dy * math.cos(hr)
            end
            SetEntityCoordsNoOffset(ent, wx, wy, base.z + lift, false, false, false)
            -- a patty face in the stack carries its own roll (the two-faced flip)
            SetEntityRotation(ent, 0.0, (rolls and rolls[i]) or 0.0, sr.z, 2, true)
        end
        lift = lift + ((heights and heights[i]) or 0.0)
    end
end

-- Is a given oven door currently open (this client's view of the tween state)?
function IsOvenDoorOpen(propId, door)
    local rec = OvenDoors[propId]
    return (rec and rec.doors[door] and rec.doors[door].open) == true
end

local function loadModel(model)
    local hash = (type(model) == "number") and model or GetHashKey(model)
    if not IsModelInCdimage(hash) then
        print(("[pickle_restaurants] ^1Oven door model '%s' is not in the game index.^7"):format(tostring(model)))
        return nil
    end
    RequestModel(hash)
    local started = GetGameTimer()
    while not HasModelLoaded(hash) do
        Wait(0)
        if GetGameTimer() - started > 10000 then
            print(("[pickle_restaurants] ^1Oven door model '%s' failed to load within 10s.^7"):format(tostring(model)))
            return nil
        end
    end
    return hash
end

local function createDoorEntity(stove, door, open)
    local hash = loadModel(DOOR.model)
    if not hash then return nil end
    local o = doorOffset(door)
    local pos = GetOffsetFromEntityInWorldCoords(stove, o.x, o.y, o.z)
    local ent = CreateObject(hash, pos.x, pos.y, pos.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ent or not DoesEntityExist(ent) then return nil end
    FreezeEntityPosition(ent, true)
    SetEntityCollision(ent, true, true)
    applyDoorTransform(stove, ent, door, open and 1.0 or 0.0)
    return ent
end

function DespawnOvenDoors(propId)
    local rec = OvenDoors[propId]
    if not rec then return end
    if hovered.propId == propId then hovered.propId, hovered.door = nil, nil end
    for _, d in pairs(rec.doors) do SafeDeleteEntity(d.entity) end
    OvenDoors[propId] = nil
end

function SpawnOvenDoors(prop, stove)
    if not prop or prop.prop_type ~= "stovetop" then return end
    if not stove or not DoesEntityExist(stove) then return end
    DespawnOvenDoors(prop.id)
    local states = (prop.metadata and prop.metadata.doors) or {}
    local doors = {}
    for door = 1, 2 do
        local open = states[door] == true
        local ent = createDoorEntity(stove, door, open)
        if ent then doors[door] = { entity = ent, open = open, token = 0 } end
    end
    OvenDoors[prop.id] = { stove = stove, doors = doors }
end

-- ─── cursor hover + click ────────────────────────────────────────────────────
--  The cooking session raycasts the NUI cursor into the world each frame; if it
--  lands on a door we outline it, and a click toggles whatever is hovered.

local function setDoorOutline(ent, on)
    if not ent or not DoesEntityExist(ent) then return end
    SetEntityDrawOutline(ent, on)
    if on then SetEntityDrawOutlineColor(255, 180, 40, 255) end
end

-- Which door (1/2) of this stovetop a raycast-hit entity is, if any.
function GetOvenDoorIndexByEntity(propId, entity)
    local rec = OvenDoors[propId]
    if not rec then return nil end
    for door, d in pairs(rec.doors) do
        if d.entity == entity then return door end
    end
    return nil
end

-- Outline the door under the cursor (door = nil clears the highlight).
function HoverOvenDoor(propId, door)
    if hovered.propId == propId and hovered.door == door then return end
    local prev = hovered.propId and OvenDoors[hovered.propId]
    if prev and hovered.door and prev.doors[hovered.door] then
        setDoorOutline(prev.doors[hovered.door].entity, false)
    end
    hovered.propId, hovered.door = propId, door
    local rec = propId and OvenDoors[propId]
    if rec and door and rec.doors[door] then
        setDoorOutline(rec.doors[door].entity, true)
    end
end

function GetHoveredOvenDoor(propId)
    if hovered.propId == propId then return hovered.door end
    return nil
end

-- Animate a single door to its new state; a per-door token cancels any tween
-- already in flight so rapid toggles don't fight each other.
local function tweenDoor(rec, door, open)
    local d = rec.doors[door]; if not d then return end
    d.open = open
    d.token = d.token + 1
    local token = d.token
    local from  = open and 0.0 or 1.0
    local to    = open and 1.0 or 0.0
    CreateThread(function()
        local started = GetGameTimer()
        while true do
            if rec.doors[door] == nil or d.token ~= token then return end
            local t = math.min((GetGameTimer() - started) / DOOR.tween_ms, 1.0)
            applyDoorTransform(rec.stove, d.entity, door, from + (to - from) * t)
            if t >= 1.0 then return end
            Wait(0)
        end
    end)
end

function SetOvenDoor(propId, door, open)
    local rec = OvenDoors[propId]; if not rec then return end
    if not rec.doors[door] then return end
    tweenDoor(rec, door, open)
end

-- Server broadcast: a door changed state for everyone.
RegisterNetEvent("pickle_restaurants:doors:set", function(propId, door, open)
    SetOvenDoor(propId, door, open)
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for propId in pairs(OvenDoors) do DespawnOvenDoors(propId) end
end)
