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
Condiments       = {}    -- squeeze-bottle condiments: { item, container_model, applied_model }
Baking           = {}    -- fill tools, a LIST: one { mix_item, mix_model, rub_dist, trays } per tool
Crafts           = {}    -- code-less combine recipes: { id, label, group, components, modifiers }
Ingredients      = {}    -- [item]  = synced ingredient config { item, model, group?, box_base?, halves?, melts? }
IngredientsByModel = {}  -- [model] = its ingredient entry (reverse lookup incl. halves/melt models)
BoxBaseModels    = {}    -- model names the pizza box accepts as a carried pile's BOTTOM layer
StackTweaks      = {}    -- [model] = { sink?, rise? } manual stacking corrections (synced setting)
ConfigGen        = 0     -- bumped every sync so lazily-built hash caches invalidate
BagItem          = "restaurant_bag" -- the ONE item every craft becomes
BagModel         = "pickle_restaurant_bag_01" -- the Restaurant Bag vessel prop

-- prop_type → localization key (resolved via _L at interaction-build time)
local STATION_LABELS = {
    soda_machine = "main_station_soda",
    fryer        = "main_station_fryer",
    stovetop     = "main_station_stovetop",
    kitchen_prep = "main_station_kitchen_prep",
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
local propsById          = {} -- [propId]        = synced prop row (stations, seats, virtual points)

-- A virtual session (modules/virtual) spawns its station as a LOCAL prop inside
-- the kitchen shell and registers it here so everything that anchors to "the
-- station entity" — the scripted camera, oven doors, fryer baskets, slot seating —
-- resolves to the virtual one for that point's prop id.
local virtualStations = {} -- [propId] = entity while a virtual session is open

function RegisterVirtualStation(propId, ent) virtualStations[propId] = ent end
function GetClientProp(propId) return propsById[propId] end

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

function GetStationEntity(propId) return virtualStations[propId] or spawnedProps[propId] end

local function SpawnProp(prop)
    -- A seat is an INVISIBLE sit anchor: no world model spawns — just a "Sit"
    -- interaction at the point. Players sit on the restaurant's own furniture here
    -- (the seating module plays the pose). Cleaned up via propInteractions like any
    -- other placed prop (ClearWorld / propRemoved).
    if prop.prop_type == "seat" then
        -- Generous reach: the anchor sits at the seated pose (often up on a chair),
        -- so a tight radius reads as "too far" even standing right at it. These are
        -- forgiving enough to sit from beside the chair in both target and
        -- keypress interaction modes.
        propInteractions[prop.id] = CreateInteraction({
            coords         = vector3(prop.x, prop.y, prop.z),
            label          = _L("main_sit"),
            icon           = "fa-solid fa-chair",
            radius         = 1.2,
            interactRadius = 2.5,
            distance       = 2.5,
        }, function()
            if SitOnSeat then SitOnSeat(prop) end
        end)
        return
    end

    -- A virtual point is an INVISIBLE anchor like a seat: nothing spawns here —
    -- using it fades out and builds the restaurant's kitchen shell (with this
    -- point's station inside) locally for just this player (modules/virtual).
    if prop.prop_type == "virtual_point" then
        local target = prop.metadata and prop.metadata.target
        local label = _L(STATION_LABELS[target] or "main_station_generic")
        propInteractions[prop.id] = CreateInteraction({
            coords         = vector3(prop.x, prop.y, prop.z),
            label          = _L("main_use_virtual", label),
            icon           = STATION_ICONS[target] or "fa-solid fa-utensils",
            radius         = 1.2,
            interactRadius = 1.8,
        }, function()
            if OpenVirtualStation then OpenVirtualStation(prop) end
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

    -- A kiosk is a real world prop but NOT a cooking station: its interaction opens
    -- the self-service order NUI (modules/sales OpenKiosk) so a customer can place
    -- an order without a cashier — the order still becomes a kitchen ticket a worker
    -- fulfils. Re-assert any configured brand now the model exists (its screen is a
    -- render-target texture; AddReplaceTexture only takes on a streamed model).
    if prop.prop_type == "kiosk" or prop.prop_type == "kiosk_ground" then
        if ReassertBrandFor then ReassertBrandFor(prop.model) end
        propInteractions[prop.id] = CreateInteraction({
            coords         = vector3(prop.x, prop.y, prop.z),
            label          = _L("main_use_kiosk"),
            icon           = "fa-solid fa-utensils",
            radius         = 1.2,
            interactRadius = 1.8,
        }, function()
            if OpenKiosk then OpenKiosk(prop.restaurant_id) end
        end)
        return
    end

    -- A menu / orders SCREEN is a placed but NON-INTERACTABLE prop: its branded
    -- screen texture is replaced at runtime by a DUI (modules/screens) rendering the
    -- restaurant's live menu / open tickets. Re-assert the screen render now the model
    -- exists (AddReplaceTexture only takes on a streamed model), and spawn no
    -- interaction — players just read it.
    if prop.prop_type == "menu_screen" or prop.prop_type == "orders_screen" then
        if ReassertScreenFor then ReassertScreenFor(prop.model) end
        return
    end

    -- Stovetops carry two oven doors that render + sync independently.
    if prop.prop_type == "stovetop" and SpawnOvenDoors then SpawnOvenDoors(prop, ent) end
    -- Let the cooking module (re)seat any oven/fryer items on this station and pick up
    -- the fryer basket's synced up/down state, now the station entity exists.
    if OnStationSpawned then OnStationSpawned(prop) end

    local label = _L(STATION_LABELS[prop.prop_type] or "main_station_generic")
    propInteractions[prop.id] = CreateInteraction({
        coords         = vector3(prop.x, prop.y, prop.z),
        label          = _L("main_use_station", label),
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
            { label = _L("main_staff_register"), icon = "fa-solid fa-cash-register" },
            { label = _L("main_management"),     icon = "fa-solid fa-users-gear" },
        },
    }, function(selection)
        if selection == 1 then
            OpenRegister(restaurant.id)
        elseif selection == 2 then
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
    Restaurants, RecipesByInput, RecipesByStation, Drinks, Assembly, Finishes, Condiments = {}, {}, {}, {}, {}, {}, {}

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
        Condiments = payload.settings.condiments or {}
        Baking   = payload.settings.baking or {}
        Crafts   = payload.settings.crafts or {}
        BagItem  = payload.settings.bag_item or "restaurant_bag"
        BagModel = payload.settings.bag_model or "pickle_restaurant_bag_01"
        SideContainerModel = payload.settings.side_container_model or ""
        -- Synced ingredient config (only installed items ship): the item map plus a
        -- reverse map from EVERY model an ingredient can render as (its base model,
        -- its halves pair, its melt topping's applied/melted looks) back to the entry.
        Ingredients, IngredientsByModel = {}, {}
        for _, ing in ipairs(payload.settings.ingredients or {}) do
            if ing.item then Ingredients[ing.item] = ing end
            if ing.model then IngredientsByModel[ing.model] = ing end
            local hv = ing.halves
            if hv then
                if hv.top_model then IngredientsByModel[hv.top_model] = ing end
                if hv.bottom_model then IngredientsByModel[hv.bottom_model] = ing end
            end
            local ml = ing.melts
            if ml then
                if ml.applied_model then IngredientsByModel[ml.applied_model] = ing end
                if ml.melted_model then IngredientsByModel[ml.melted_model] = ing end
            end
        end
        BoxBaseModels = payload.settings.box_base_models or {}
        StackTweaks   = payload.settings.stack_tweaks or {}
        -- invalidate lazily-built hash caches (e.g. the cooking module's boxable set)
        ConfigGen = (ConfigGen or 0) + 1
    end

    propsById = {}
    for _, prop in ipairs(payload.props or {}) do
        propsById[prop.id] = prop
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
    -- Same for the info SCREENS: their props were just (re)spawned above, so re-assert
    -- each screen's render-target replacement while the fresh prop exists and re-push
    -- its data (menu may have changed). RefreshScreens is in modules/screens/client.lua.
    if RefreshScreens then RefreshScreens() end
end

RegisterNetEvent("pickle_restaurants:sync", ApplySync)

RegisterNetEvent("pickle_restaurants:propPlaced", function(prop)
    propsById[prop.id] = prop
    if Restaurants[prop.restaurant_id] then
        table.insert(Restaurants[prop.restaurant_id].props, prop)
    end
    SpawnProp(prop)
end)

RegisterNetEvent("pickle_restaurants:propRemoved", function(propId)
    if DespawnOvenDoors then DespawnOvenDoors(propId) end
    if DespawnFryerBaskets then DespawnFryerBaskets(propId) end
    local prop = propsById[propId]
    -- Delete the entity we're tracking. Note whether we actually held a live one.
    local hadEntity = spawnedProps[propId] and DoesEntityExist(spawnedProps[propId])
    SafeDeleteEntity(spawnedProps[propId])
    spawnedProps[propId] = nil
    -- Safety sweep: if our tracked handle was already gone (the prop streamed out and
    -- back, or was placed before we cached its entity), the world object could linger
    -- until a resource restart. Delete any object of this model still sitting at the
    -- prop's point so a "removed" station can't stay in the world. Skipped for
    -- modelless anchors (seats / virtual points spawn no world prop).
    if not hadEntity and prop and prop.model and prop.model ~= "" then
        local hash = (type(prop.model) == "number") and prop.model or GetHashKey(prop.model)
        local ghost = GetClosestObjectOfType(prop.x + 0.0, prop.y + 0.0, prop.z + 0.0, 1.5, hash, false, false, false)
        if ghost and ghost ~= 0 and DoesEntityExist(ghost) then SafeDeleteEntity(ghost) end
    end
    -- Prune the client cache so nothing keeps treating the prop as still placed —
    -- notably the screens driver (modules/screens), which scans r.props to decide a
    -- board still exists and would otherwise leave its texture replacement bound
    -- until the next full sync / restart.
    propsById[propId] = nil
    if prop and Restaurants[prop.restaurant_id] then
        local list = Restaurants[prop.restaurant_id].props or {}
        for i = #list, 1, -1 do if list[i].id == propId then table.remove(list, i) end end
    end
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
