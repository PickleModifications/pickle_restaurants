-- =============================================
--  modules/cooking | client.lua
--  The interactive station experience: a full-width bottom NUI bar of
--  ingredients you drag out into the 3D world (spawns the real food prop,
--  which cooks 01->02->03), plus draggable on-screen chips over each world
--  food prop that you drag back onto the bar to collect into your inventory.
-- =============================================

local CookObjects = {} -- [uid] = entity
local CookState   = {} -- [uid] = state string
local CookCoords  = {} -- [uid] = { x, y, z }

cookingOpen      = false
currentCookProp  = nil

-- ─── world food props (synced for everyone) ──────────────────────────────────

local function SpawnCookObject(uid, model, x, y, z, state)
    if CookObjects[uid] and DoesEntityExist(CookObjects[uid]) then DeleteEntity(CookObjects[uid]) end
    print("C")
    local ent = CreateProp(model, x, y, z, false, false, false)
    if not ent or not DoesEntityExist(ent) then return end
    SetEntityCollision(ent, false, false)
    FreezeEntityPosition(ent, true)
    CookObjects[uid] = ent
    CookState[uid]   = state
    CookCoords[uid]  = { x = x, y = y, z = z }
end

RegisterNetEvent("pickle_restaurants:cooking:spawn", function(uid, model, x, y, z, state)
    SpawnCookObject(uid, model, x, y, z, state)
end)

RegisterNetEvent("pickle_restaurants:cooking:update", function(uid, model, state)
    local c = CookCoords[uid]; if not c then return end
    SpawnCookObject(uid, model, c.x, c.y, c.z, state)
end)

RegisterNetEvent("pickle_restaurants:cooking:move", function(uid, x, y, z)
    local ent = CookObjects[uid]
    if ent and DoesEntityExist(ent) then SetEntityCoordsNoOffset(ent, x, y, z, false, false, false) end
    CookCoords[uid] = { x = x, y = y, z = z }
end)

RegisterNetEvent("pickle_restaurants:cooking:remove", function(uid)
    if CookObjects[uid] and DoesEntityExist(CookObjects[uid]) then DeleteEntity(CookObjects[uid]) end
    CookObjects[uid], CookState[uid], CookCoords[uid] = nil, nil, nil
end)

RegisterNetEvent("pickle_restaurants:cooking:bulk", function(list)
    for _, it in ipairs(list or {}) do
        SpawnCookObject(it.uid, it.model, it.x, it.y, it.z, it.state)
    end
end)

-- ─── open / close ────────────────────────────────────────────────────────────

local function RefreshBar()
    if not cookingOpen or not currentCookProp then return end
    local ing = lib.callback.await("pickle_restaurants:cooking:getIngredients", false, { prop_id = currentCookProp.id })
    SendNUIMessage({ action = "cookingIngredients", ingredients = ing })
end

local function StopCooking()
    cookingOpen = false
    currentCookProp = nil
    StopStationCamera()
    CloseNUI()
    SendNUIMessage({ action = "cookingItems", items = {} })
end

function OpenCookingStation(prop)
    if cookingOpen then return end
    currentCookProp = prop
    cookingOpen = true
    StartStationCamera(prop)
    local ing = lib.callback.await("pickle_restaurants:cooking:getIngredients", false, { prop_id = prop.id })
    OpenNUI("cooking", { station = prop.prop_type, ingredients = ing })

    -- per-frame projection of every world food prop -> NUI chip positions
    CreateThread(function()
        while cookingOpen do
            local items = {}
            for uid, ent in pairs(CookObjects) do
                if DoesEntityExist(ent) then
                    local coords = GetEntityCoords(ent)
                    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(coords.x, coords.y, coords.z)
                    items[#items + 1] = { uid = uid, state = CookState[uid] or "raw", onScreen = onScreen, x = sx, y = sy }
                end
            end
            SendNUIMessage({ action = "cookingItems", items = items })
            if IsControlJustReleased(0, 322) then StopCooking() end -- ESC fallback
            Wait(50)
        end
    end)
end

-- ─── NUI callbacks ───────────────────────────────────────────────────────────

-- bar card dropped into the world
RegisterNUICallback("cooking:dropItem", function(d, cb)
    if not currentCookProp then return cb({ ok = false }) end
    local hit, coords = CursorToWorld()
    if not hit or not coords then return cb({ ok = false, error = "Aim at the station." }) end
    local res = lib.callback.await("pickle_restaurants:cooking:place", false, {
        prop_id = currentCookProp.id, kind = d.kind, item = d.item,
        x = coords.x, y = coords.y, z = coords.z,
    })
    if res and res.ok then RefreshBar() elseif res and res.error then ShowNotification(res.error) end
    cb(res or { ok = false })
end)

-- chip dragged back onto the bar -> collect into inventory
RegisterNUICallback("cooking:collect", function(d, cb)
    local res = lib.callback.await("pickle_restaurants:cooking:collect", false, { uid = d.uid })
    if res and res.ok then
        if res.label then ShowNotification("Collected " .. res.label) end
        RefreshBar()
    end
    cb(res or { ok = false })
end)

-- chip dragged to a new spot in the world -> move
RegisterNUICallback("cooking:move", function(d, cb)
    local hit, coords = CursorToWorld()
    if not hit or not coords then return cb({ ok = false }) end
    local res = lib.callback.await("pickle_restaurants:cooking:move", false, {
        uid = d.uid, x = coords.x, y = coords.y, z = coords.z,
    })
    cb(res or { ok = false })
end)

RegisterNUICallback("cooking:close", function(_, cb)
    StopCooking()
    cb({})
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for uid, ent in pairs(CookObjects) do
        if DoesEntityExist(ent) then DeleteEntity(ent) end
    end
end)
