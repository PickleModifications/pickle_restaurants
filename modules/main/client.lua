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
BagItem          = "restaurant_bag" -- the ONE takeaway CARRIER item (its contents ride as metadata)
BagModel         = "pickle_restaurant_bag_01" -- the Restaurant Bag vessel prop
BoxItem          = "takeout_box"    -- the ONE item every bag-KIND food (soup, salad…) becomes
BoxBaseModel     = "pickle_takeout_box_01" -- takeout box: base half
BoxLidModel      = "pickle_takeout_box_02" -- takeout box: hinged lid

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
local propInteractions   = {} -- [propId]        = interaction index (stations, seats, counters, virtual points)
local restaurantBlips    = {} -- [restaurantId]  = blip
local propsById          = {} -- [propId]        = synced prop row (stations, seats, counters, virtual points)

-- A virtual session (modules/virtual) spawns its station as a LOCAL prop inside
-- the kitchen shell and registers it here so everything that anchors to "the
-- station entity" — the scripted camera, oven doors, fryer baskets, slot seating —
-- resolves to the virtual one for that point's prop id.
local virtualStations = {} -- [propId] = entity while a virtual session is open

function RegisterVirtualStation(propId, ent) virtualStations[propId] = ent end
function GetClientProp(propId) return propsById[propId] end

-- The world entity a placed prop is currently rendered as — the virtual station
-- inside an open shell session if there is one, else the physical world prop.
-- Used by modules/cookfx to hang a fire on the station that's actually on screen.
function GetClientPropEntity(propId)
    propId = tonumber(propId) or propId
    local ent = virtualStations[propId]
    if ent and DoesEntityExist(ent) then return ent end
    ent = spawnedProps[propId]
    if ent and DoesEntityExist(ent) then return ent end
    return nil
end

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
    if ClearPropHighlight then ClearPropHighlight() end -- drop any hover outline/temp body
    for id, ent in pairs(spawnedProps) do
        if DespawnOvenDoors then DespawnOvenDoors(id) end
        if DespawnFryerBaskets then DespawnFryerBaskets(id) end
        SafeDeleteEntity(ent)
        spawnedProps[id] = nil
    end
    for id, idx in pairs(propInteractions) do
        DeleteInteraction(idx); propInteractions[id] = nil
    end
    for id, blip in pairs(restaurantBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
        restaurantBlips[id] = nil
    end
end

-- ─── prop spawning + interaction ─────────────────────────────────────────────

function GetStationEntity(propId) return virtualStations[propId] or spawnedProps[propId] end

-- The counter anchor's world model. A counter row is stored with an EMPTY model (it's a
-- point + heading, not a placed prop — see modules/placement), so unlike every other
-- prop the model isn't in the row: the register IS the counter, so the model belongs to
-- the anchor type rather than to the record. Its `register_brand` screen is the cashier's
-- interactive POS DUI (modules/register OpenRegisterScreen), taken over on interact.
local COUNTER_MODEL = "pickle_register_01"
-- The placement gizmo previews the real thing (modules/placement), so it reads the
-- model from here rather than keeping its own copy of the name.
function CounterModel() return COUNTER_MODEL end

-- The world model a prop row spawns, or nil for a modelless anchor (seat / virtual
-- point). ONE answer to "what does this row put in the world", because the row alone
-- can't say: a counter's `model` column is empty, so its register comes from the anchor
-- TYPE instead. Anything reasoning about a placed prop's model must go through this or
-- it will treat every counter as modelless.
local function PropModel(prop)
    if not prop then return nil end
    if prop.prop_type == "counter" then return COUNTER_MODEL end
    if not prop.model or prop.model == "" then return nil end
    return prop.model
end

-- Load `model` and create a frozen object for `prop` at its point + heading, or nil (and
-- a console line saying exactly why) if the model can't be spawned. Shared by the
-- generic station path and the counter, so a register fails as loudly as a fryer would.
local function CreatePropEntity(prop, model)
    if not model then
        -- Only reachable for a row that should carry a model but doesn't (the anchors
        -- return long before this) — i.e. a corrupt prop row. Say so rather than
        -- hashing nil.
        print(("[pickle_restaurants] ^1Prop #%s ('%s') has no model to spawn.^7")
            :format(tostring(prop.id), tostring(prop.prop_type)))
        return nil
    end
    local hash = (type(model) == "number") and model or GetHashKey(model)
    if not IsModelInCdimage(hash) then
        print(("[pickle_restaurants] ^1Model '%s' (prop #%s) is not in the game index.^7 "
            .. "Check that stream/%s.ydr exists and that data/pickle_restaurants.ytyp declares this archetype.")
            :format(tostring(model), tostring(prop.id), tostring(model)))
        return nil
    end
    RequestModel(hash)
    local started = GetGameTimer()
    while not HasModelLoaded(hash) do
        Wait(0)
        if GetGameTimer() - started > 10000 then
            print(("[pickle_restaurants] ^1Model '%s' failed to load within 10s.^7"):format(tostring(model)))
            return nil
        end
    end
    local ent = CreateObject(hash, prop.x, prop.y, prop.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ent or not DoesEntityExist(ent) then
        print(("[pickle_restaurants] ^1CreateObject failed for '%s'.^7"):format(tostring(model)))
        return nil
    end
    SetEntityCoordsNoOffset(ent, prop.x, prop.y, prop.z, false, false, false)
    SetEntityHeading(ent, prop.heading or 0.0)
    FreezeEntityPosition(ent, true)
    SetEntityCollision(ent, true, true)
    return ent
end

-- How far ABOVE a seat anchor its "Sit" target zone sits. The anchor itself is
-- bottom-based (the seated ped's root), so the zone has to be lifted to where a
-- player is actually looking — otherwise it hides under the chair. TUNE IN-GAME.
local SEAT_TARGET_Z = 1.0

local function SpawnProp(prop)
    -- A seat is an INVISIBLE sit anchor: no world model spawns — just a "Sit"
    -- interaction at the point. Players sit on the restaurant's own furniture here
    -- (the seating module plays the pose). Cleaned up via propInteractions like any
    -- other placed prop (ClearWorld / propRemoved).
    -- A DELIVERY DOOR is a pure data point: no model, no interaction, nothing in the
    -- world at all. It exists only as a destination for NPC delivery orders
    -- (modules/doorstep runs the knock + hand-off when a driver arrives at one).
    if prop.prop_type == "delivery_door" then return end

    if prop.prop_type == "seat" then
        -- Generous reach: the anchor sits at the seated pose (often up on a chair),
        -- so a tight radius reads as "too far" even standing right at it. These are
        -- forgiving enough to sit from beside the chair in both target and
        -- keypress interaction modes.
        propInteractions[prop.id] = CreateInteraction({
            -- Raised off the anchor: a seat's stored point is BOTTOM-based (the
            -- ped's root, on the floor / seat pan), so a target zone centred on it
            -- sits under the chair where a player is aiming at the seat back or the
            -- table. SEAT_TARGET_Z lifts it to roughly torso height, where the eye
            -- (and the target ray) actually goes.
            coords         = vector3(prop.x, prop.y, prop.z + SEAT_TARGET_Z),
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

    -- A counter is the REGISTER anchor: it spawns the register model at the point and
    -- carries the "Register / Management" interaction. A restaurant may have several;
    -- each is its own register. The primary (lowest-id) counter also anchors the
    -- blip/shell/NPC queue, but that's read off restaurant.counter, not this
    -- interaction. The model is COUNTER_MODEL, not prop.model — a counter row stores an
    -- empty model (it predates having one; see modules/placement).
    --
    -- The register's screen is now the cashier's own POS: interacting opens the staff
    -- register as an INTERACTIVE in-world DUI painted on the counter's `register_brand`
    -- screen (modules/register OpenRegisterScreen), the same way the kiosk works. The
    -- second option opens management (still a fullscreen NUI).
    if prop.prop_type == "counter" then
        local rest = Restaurants[prop.restaurant_id]
        local label = (rest and rest.label) or _L("main_station_generic")
        local ent = CreatePropEntity(prop, PropModel(prop))
        if ent then
            spawnedProps[prop.id] = ent
            -- The counter's screen is the always-on register POS DUI (modules/register);
            -- re-assert its texture now the model exists (AddReplaceTexture needs the
            -- prop streamed in), mirroring ReassertScreenFor for the info boards.
            if ReassertRegister then ReassertRegister() end
        end
        propInteractions[prop.id] = CreateInteraction({
            coords         = vector3(prop.x, prop.y, prop.z),
            label          = label,
            icon           = "fa-solid fa-cash-register",
            radius         = 1.5,
            interactRadius = 2.0,
            title          = label,
            options        = {
                { label = _L("main_staff_register"), icon = "fa-solid fa-cash-register" },
                { label = _L("main_management"),     icon = "fa-solid fa-users-gear" },
            },
        }, function(selection)
            if selection == 1 then
                if OpenRegisterScreen then OpenRegisterScreen(prop, ent) end
            elseif selection == 2 then
                OpenManagement(prop.restaurant_id)
            end
        end)
        return
    end

    -- A virtual register is an INVISIBLE anchor like a seat (prop_type
    -- "virtual_register"): nothing spawns in the world, and — having no screen to paint
    -- — it keeps the ordinary fullscreen NUI register (OpenRegister) rather than the
    -- in-world DUI. Same two-option interaction as a physical counter.
    if prop.prop_type == "virtual_register" then
        local rest = Restaurants[prop.restaurant_id]
        local label = (rest and rest.label) or _L("main_station_generic")
        propInteractions[prop.id] = CreateInteraction({
            coords         = vector3(prop.x, prop.y, prop.z),
            label          = label,
            icon           = "fa-solid fa-cash-register",
            radius         = 1.2,
            interactRadius = 1.8,
            title          = label,
            options        = {
                { label = _L("main_staff_register"), icon = "fa-solid fa-cash-register" },
                { label = _L("main_management"),     icon = "fa-solid fa-users-gear" },
            },
        }, function(selection)
            if selection == 1 then
                OpenRegister(prop.restaurant_id)
            elseif selection == 2 then
                OpenManagement(prop.restaurant_id)
            end
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
    local ent = CreatePropEntity(prop, PropModel(prop))
    if not ent then return end
    spawnedProps[prop.id] = ent
    debugPrint(("Spawned prop #%s '%s' at %.2f %.2f %.2f"):format(prop.id, prop.model, prop.x, prop.y, prop.z))

    -- A kiosk is a real world prop but NOT a cooking station: its interaction opens
    -- the self-service order screen as an INTERACTIVE in-world DUI (modules/kiosk
    -- OpenKioskScreen) — the customer orders on the kiosk's own screen, no fullscreen
    -- NUI, and it shows the restaurant BRAND when idle. The order still becomes a
    -- kitchen ticket a worker fulfils. Re-assert any configured brand now the model
    -- exists (its screen is a render-target texture; AddReplaceTexture only takes on a
    -- streamed model). Pass the spawned entity so the kiosk can frame its camera.
    if prop.prop_type == "kiosk" or prop.prop_type == "kiosk_ground" then
        if ReassertBrandFor then ReassertBrandFor(prop.model) end
        propInteractions[prop.id] = CreateInteraction({
            coords         = vector3(prop.x, prop.y, prop.z),
            label          = _L("main_use_kiosk"),
            icon           = "fa-solid fa-utensils",
            radius         = 1.2,
            interactRadius = 1.8,
        }, function()
            if OpenKioskScreen then OpenKioskScreen(prop, ent) end
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

local function DoApplySync(payload)
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
        BoxItem      = payload.settings.box_item or "takeout_box"
        BoxBaseModel = payload.settings.box_base_model or "pickle_takeout_box_01"
        BoxLidModel  = payload.settings.box_lid_model or "pickle_takeout_box_02"
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
    end
    -- Re-assert brand render-target bindings now that brand_images may have changed,
    -- so a brand edit takes effect after re-streaming the item (no resource restart).
    -- RefreshBrands is defined in modules/rendertarget/client.lua (same client).
    if RefreshBrands then RefreshBrands() end
    -- Same for the info SCREENS: their props were just (re)spawned above, so re-assert
    -- each screen's render-target replacement while the fresh prop exists and re-push
    -- its data (menu may have changed). RefreshScreens is in modules/screens/client.lua.
    if RefreshScreens then RefreshScreens() end
    -- And the always-on register board: the counter was just (re)spawned and its
    -- catalog/menu may have changed, so re-seed + re-paint it (modules/register).
    if RefreshRegister then RefreshRegister() end
end

-- Serialize syncs. SpawnProp yields (CreatePropEntity blocks while its model streams
-- in), so DoApplySync is asynchronous: a prop's entity isn't recorded in `spawnedProps`
-- until its model has loaded. On join a client gets TWO overlapping syncs — the server's
-- `playerJoining` push (modules/main/server.lua) and the client's own `requestSync` — and
-- config edits fire more (SyncToClient(-1)). If a second pass ran while the first was
-- still mid-spawn, its ClearWorld couldn't delete the first pass's not-yet-registered
-- entities, so both passes spawned a full set → props double up until a resource restart.
-- Guard against re-entry: while one pass runs, a newer sync just parks its payload
-- (coalesced to the latest), and we re-run once the current pass has fully finished — its
-- ClearWorld now sees the previous set registered and clears it before respawning.
local applyingSync = false
local pendingSync  = nil

local function ApplySync(payload)
    if applyingSync then
        pendingSync = payload
        return
    end
    applyingSync = true
    DoApplySync(payload)
    while pendingSync do
        local p = pendingSync
        pendingSync = nil
        DoApplySync(p)
    end
    applyingSync = false
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
    -- modelless anchors (seats / virtual points spawn no world prop) — but NOT for a
    -- counter: its row's model is empty while its register is very much in the world,
    -- so PropModel is what decides, not the column.
    local sweepModel = PropModel(prop)
    if not hadEntity and sweepModel then
        local hash = (type(sweepModel) == "number") and sweepModel or GetHashKey(sweepModel)
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

-- ─── admin prop highlight ────────────────────────────────────────────────────
-- Hovering a prop's card in the admin / boss panel flags exactly which placed thing
-- it is, using the SAME entity outline the interaction / cooking hover uses (amber
-- SetEntityDrawOutline). A physical prop's own world entity is outlined directly;
-- an INVISIBLE anchor (seat / virtual point) has no entity, so a temporary
-- body — the same one its placement previews — is spawned at the point and outlined,
-- so the highlight reads identically everywhere. SetPropHighlight is global so the
-- admin / management NUI relays can toggle it. (Panel is centred, so the world — and
-- the outline — shows around it.)
local HL_OUTLINE = { 255, 180, 40, 255 } -- amber, matching the cooking/stovetop hover
local ANCHOR_HL = {
    -- Fallback only: a counter spawns its own register now, so the real entity above is
    -- what normally gets outlined. This vanilla till stands in if COUNTER_MODEL is
    -- missing from the game index, so the admin can still see WHERE the counter is.
    counter          = { model = "prop_till_01" },
    virtual_register = { model = "prop_till_01" },  -- invisible register anchor
    virtual_point    = { model = "prop_tennis_ball" },  -- the virtual-point gizmo preview
    -- A SEAT IS DRAWN, NOT SPAWNED. It used to preview as a ghost PED here, which
    -- crashed the game: hovering a list of seat chips creates and deletes a ped per
    -- mouse-over (the panel fires on-enter, on-leave AND an unmount cleanup), and
    -- churning peds that fast — spawning one, then DeleteEntity-ing it a few frames
    -- later, repeatedly — takes the client down. Markers cost nothing, load no model
    -- and create no entity, so a seat highlight cannot crash and cannot leak.
    seat             = { marker = true },
    delivery_door    = { marker = true },  -- the NPC-delivery doorstep, same reasoning
}
local HL_MARKER = { 255, 180, 40, 170 } -- same amber as the outline, translucent
local hlReal   = nil -- a real world entity whose outline we turned on
local hlTemp   = nil -- a temp body we spawned for an invisible anchor
local hlMarker = nil -- { x, y, z, h } drawn each frame for an anchor with no body
local hlGen    = 0   -- bumped each toggle so a late async spawn can bail

-- The seat marker: a puck on the anchor plus a small ball a step along its heading,
-- so an admin sees WHERE the seat is and WHICH WAY it faces. One thread for the
-- lifetime of the resource — it idles cheaply when nothing is highlighted.
CreateThread(function()
    while true do
        local m = hlMarker
        if m then
            DrawMarker(1, m.x, m.y, m.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                       0.45, 0.45, 0.15, HL_MARKER[1], HL_MARKER[2], HL_MARKER[3], HL_MARKER[4],
                       false, false, 2, false, nil, nil, false)
            local rad = math.rad(m.h)
            DrawMarker(28, m.x - math.sin(rad) * 0.45, m.y + math.cos(rad) * 0.45, m.z - 0.75,
                       0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.10, 0.10, 0.10,
                       HL_MARKER[1], HL_MARKER[2], HL_MARKER[3], HL_MARKER[4],
                       false, false, 2, false, nil, nil, false)
            Wait(0)
        else
            Wait(250)
        end
    end
end)

function ClearPropHighlight()
    hlGen = hlGen + 1
    if hlReal and DoesEntityExist(hlReal) then SetEntityDrawOutline(hlReal, false) end
    hlReal = nil
    if hlTemp and DoesEntityExist(hlTemp) then
        SetEntityAsMissionEntity(hlTemp, true, true)
        DeleteEntity(hlTemp)
    end
    hlTemp = nil
    hlMarker = nil
end

function SetPropHighlight(propId, on)
    ClearPropHighlight()
    if not on then return end
    propId = tonumber(propId)
    local prop = propId and propsById[propId]
    if not prop then return end

    -- Physical prop (station / kiosk / screen): outline its actual world entity.
    local ent = GetStationEntity and GetStationEntity(propId)
    if ent and DoesEntityExist(ent) then
        SetEntityDrawOutline(ent, true)
        SetEntityDrawOutlineColor(HL_OUTLINE[1], HL_OUTLINE[2], HL_OUTLINE[3], HL_OUTLINE[4])
        hlReal = ent
        return
    end

    -- Invisible anchor: spawn its placement-preview body at the point and outline it.
    local spec = ANCHOR_HL[prop.prop_type]
    if not spec then return end
    local gen, x, y, z, h = hlGen, prop.x + 0.0, prop.y + 0.0, prop.z + 0.0, (prop.heading or 0.0) + 0.0

    -- Drawn, not spawned (seats). No model, no entity, nothing to clean up but a
    -- table reference — so no amount of hover churn can leak or crash.
    if spec.marker then
        hlMarker = { x = x, y = y, z = z, h = h }
        return
    end

    CreateThread(function()
        local hash = GetHashKey(spec.model)
        RequestModel(hash)
        local t = GetGameTimer()
        while not HasModelLoaded(hash) and GetGameTimer() - t < 1000 do Wait(0) end
        if not HasModelLoaded(hash) or gen ~= hlGen then SetModelAsNoLongerNeeded(hash); return end
        -- OBJECTS ONLY. Do not add a ped preview back here (see ANCHOR_HL): a hover
        -- highlight spawns and deletes its body on every mouse-over, and peds do not
        -- survive that churn — it crashes the client. Anything ped-shaped belongs in
        -- the `marker` path.
        local e
        do
            e = CreateObject(hash, x, y, z, false, false, false)
            if e and DoesEntityExist(e) then
                SetEntityHeading(e, h)
                SetEntityCollision(e, false, false)
            end
        end
        SetModelAsNoLongerNeeded(hash)
        if not e or not DoesEntityExist(e) or gen ~= hlGen then
            if e and DoesEntityExist(e) then SetEntityAsMissionEntity(e, true, true); DeleteEntity(e) end
            return
        end
        FreezeEntityPosition(e, true)
        SetEntityDrawOutline(e, true)
        SetEntityDrawOutlineColor(HL_OUTLINE[1], HL_OUTLINE[2], HL_OUTLINE[3], HL_OUTLINE[4])
        hlTemp = e
    end)
end
