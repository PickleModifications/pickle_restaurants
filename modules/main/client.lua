-- =============================================
--  modules/main | client.lua
--  Receives the server sync, spawns placed station props, blips and the
--  interactions that open cooking / ordering / management.
-- =============================================

Restaurants      = {}   -- [id]            = restaurant data
RecipesByInput   = {}    -- [input_item]    = recipe
RecipesByStation = {}    -- [station]       = { recipe, ... }
Drinks           = {}    -- soda definitions
Assembly         = {}    -- kitchen-prep definitions
Finishes         = {}    -- finish tools (frosting…): tool -> targets -> flavors

local STATION_LABELS = {
    soda_machine = "Soda Machine",
    fryer        = "Fryer",
    stovetop     = "Stovetop",
    kitchen_prep = "Kitchen Prep",
}

local STATION_ICONS = {
    soda_machine = "fa-solid fa-cup-straw",
    fryer        = "fa-solid fa-fire-burner",
    stovetop     = "fa-solid fa-fire",
    kitchen_prep = "fa-solid fa-bowl-food",
}

local spawnedProps       = {} -- [propId]        = entity
local propInteractions   = {} -- [propId]        = interaction index
local restaurantBlips    = {} -- [restaurantId]  = blip
local counterInteractions = {} -- [restaurantId] = interaction index

-- ─── world cleanup ───────────────────────────────────────────────────────────

-- Props are spawned as local, non-mission objects (CreateObject(..., false,
-- false, false)). DeleteEntity silently no-ops on those unless we first take
-- ownership by flagging them as a mission entity, which is why "removed in the
-- menu" stations used to linger in the world.
local function SafeDeleteEntity(ent)
    if not ent or not DoesEntityExist(ent) then return end
    SetEntityAsMissionEntity(ent, true, true)
    DeleteEntity(ent)
end

local function ClearWorld()
    for id, ent in pairs(spawnedProps) do
        if DespawnOvenDoors then DespawnOvenDoors(id) end
        if DespawnFryerBaskets then DespawnFryerBaskets(id) end
        SafeDeleteEntity(ent)
        spawnedProps[id] = nil
    end
    for id, idx in pairs(propInteractions) do
        DeleteInteraction(idx); propInteractions[id] = nil
    end
    for id, idx in pairs(counterInteractions) do
        DeleteInteraction(idx); counterInteractions[id] = nil
    end
    for id, blip in pairs(restaurantBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
        restaurantBlips[id] = nil
    end
end

-- ─── prop spawning + interaction ─────────────────────────────────────────────

function GetStationEntity(propId) return spawnedProps[propId] end

local function SpawnProp(prop)
    -- A seat is an INVISIBLE sit anchor: no world model spawns — just a "Sit"
    -- interaction at the point. Players sit on the restaurant's own furniture here
    -- (the seating module plays the pose). Cleaned up via propInteractions like any
    -- other placed prop (ClearWorld / propRemoved).
    if prop.prop_type == "seat" then
        propInteractions[prop.id] = CreateInteraction({
            coords         = vector3(prop.x, prop.y, prop.z),
            label          = "Sit",
            icon           = "fa-solid fa-chair",
            radius         = 0.9,
            interactRadius = 1.4,
        }, function()
            if SitOnSeat then SitOnSeat(prop) end
        end)
        return
    end

    -- Spawn the model ourselves (rather than core's CreateProp) so we can log
    -- exactly why a station doesn't appear. Watch the F8 / server console.
    local hash = (type(prop.model) == "number") and prop.model or GetHashKey(prop.model)
    if not IsModelInCdimage(hash) then
        print(("[pickle_restaurants] ^1Model '%s' (prop #%s) is not in the game index.^7 "
            .. "Check that stream/%s.ydr exists and that data/pickle_restaurants.ytyp declares this archetype.")
            :format(tostring(prop.model), tostring(prop.id), tostring(prop.model)))
        return
    end
    RequestModel(hash)
    local started = GetGameTimer()
    while not HasModelLoaded(hash) do
        Wait(0)
        if GetGameTimer() - started > 10000 then
            print(("[pickle_restaurants] ^1Model '%s' failed to load within 10s.^7"):format(tostring(prop.model)))
            return
        end
    end
    local ent = CreateObject(hash, prop.x, prop.y, prop.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ent or not DoesEntityExist(ent) then
        print(("[pickle_restaurants] ^1CreateObject failed for '%s'.^7"):format(tostring(prop.model)))
        return
    end
    SetEntityCoordsNoOffset(ent, prop.x, prop.y, prop.z, false, false, false)
    SetEntityHeading(ent, prop.heading or 0.0)
    FreezeEntityPosition(ent, true)
    SetEntityCollision(ent, true, true)
    spawnedProps[prop.id] = ent
    debugPrint(("Spawned prop #%s '%s' at %.2f %.2f %.2f"):format(prop.id, prop.model, prop.x, prop.y, prop.z))

    -- Stovetops carry two oven doors that render + sync independently.
    if prop.prop_type == "stovetop" and SpawnOvenDoors then SpawnOvenDoors(prop, ent) end
    -- Let the cooking module (re)seat any oven/fryer items on this station and pick up
    -- the fryer basket's synced up/down state, now the station entity exists.
    if OnStationSpawned then OnStationSpawned(prop) end

    local label = STATION_LABELS[prop.prop_type] or "Station"
    propInteractions[prop.id] = CreateInteraction({
        coords         = vector3(prop.x, prop.y, prop.z),
        label          = "Use " .. label,
        icon           = STATION_ICONS[prop.prop_type] or "fa-solid fa-utensils",
        radius         = 1.2,
        interactRadius = 1.8,
    }, function()
        OpenCookingStation(prop)
    end)
end

local function SetupCounter(restaurant)
    local c = restaurant.counter
    if not c then return end
    counterInteractions[restaurant.id] = CreateInteraction({
        coords         = vector3(c.x, c.y, c.z),
        label          = restaurant.label,
        icon           = "fa-solid fa-cash-register",
        radius         = 1.5,
        interactRadius = 2.0,
        title          = restaurant.label,
        options        = {
            { label = "Order Food",     icon = "fa-solid fa-burger" },
            { label = "Staff Register", icon = "fa-solid fa-cash-register" },
            { label = "Management",     icon = "fa-solid fa-users-gear" },
        },
    }, function(selection)
        if selection == 1 then
            OpenOrderMenu(restaurant.id)
        elseif selection == 2 then
            OpenRegister(restaurant.id)
        elseif selection == 3 then
            OpenManagement(restaurant.id)
        end
    end)
end

local function SetupBlip(restaurant)
    local b = restaurant.blip or { sprite = 93, color = 1, scale = 0.8, enabled = true }
    if b.enabled == false then return end
    local coords = restaurant.counter
    if not coords then
        for _, prop in ipairs(restaurant.props or {}) do
            coords = { x = prop.x, y = prop.y, z = prop.z }; break
        end
    end
    if not coords then return end
    local blip = AddBlipForCoord(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)
    SetBlipSprite(blip, b.sprite or 93)
    SetBlipColour(blip, b.color or 1)
    SetBlipScale(blip, b.scale or 0.8)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(restaurant.label or "Restaurant")
    EndTextCommandSetBlipName(blip)
    restaurantBlips[restaurant.id] = blip
end

-- ─── sync handler ────────────────────────────────────────────────────────────

local function ApplySync(payload)
    ClearWorld()
    Restaurants, RecipesByInput, RecipesByStation, Drinks, Assembly, Finishes = {}, {}, {}, {}, {}, {}

    for _, r in ipairs(payload.restaurants or {}) do
        r.props = {}
        Restaurants[r.id] = r
    end
    for _, recipe in ipairs(payload.recipes or {}) do
        RecipesByInput[recipe.input_item] = recipe
        RecipesByStation[recipe.station] = RecipesByStation[recipe.station] or {}
        table.insert(RecipesByStation[recipe.station], recipe)
    end
    if payload.settings then
        Drinks   = payload.settings.drinks or {}
        Assembly = payload.settings.assembly or {}
        Finishes = payload.settings.finishes or {}
        SideContainerModel = payload.settings.side_container_model or ""
    end

    for _, prop in ipairs(payload.props or {}) do
        if Restaurants[prop.restaurant_id] then
            table.insert(Restaurants[prop.restaurant_id].props, prop)
        end
    end
    for _, prop in ipairs(payload.props or {}) do
        SpawnProp(prop)
    end
    for _, r in pairs(Restaurants) do
        SetupBlip(r)
        SetupCounter(r)
    end
    -- Re-assert brand render-target bindings now that brand_images may have changed,
    -- so a brand edit takes effect after re-streaming the item (no resource restart).
    -- RefreshBrands is defined in modules/rendertarget/client.lua (same client).
    if RefreshBrands then RefreshBrands() end
end

RegisterNetEvent("pickle_restaurants:sync", ApplySync)

RegisterNetEvent("pickle_restaurants:propPlaced", function(prop)
    if Restaurants[prop.restaurant_id] then
        table.insert(Restaurants[prop.restaurant_id].props, prop)
    end
    SpawnProp(prop)
end)

RegisterNetEvent("pickle_restaurants:propRemoved", function(propId)
    if DespawnOvenDoors then DespawnOvenDoors(propId) end
    if DespawnFryerBaskets then DespawnFryerBaskets(propId) end
    SafeDeleteEntity(spawnedProps[propId])
    spawnedProps[propId] = nil
    if propInteractions[propId] then DeleteInteraction(propInteractions[propId]); propInteractions[propId] = nil end
end)

-- ─── boot ────────────────────────────────────────────────────────────────────

CreateThread(function()
    -- Don't gate on Inventory.Ready: under ESX/QB the client inventory mirror
    -- only flips to Ready once the server answers requestSync with the item
    -- list, so requesting the sync is what unblocks it.
    Wait(1000)
    TriggerServerEvent("pickle_restaurants:requestSync")
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    ClearWorld()
end)

function GetRestaurantById(id) return Restaurants[id] end
