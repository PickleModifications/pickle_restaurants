-- =============================================
--  modules/consume | client.lua
--  The customer's end of eating (see modules/consume/server.lua for the authority).
--
--    • RESTAURANT BAG — an ox_lib context menu of what's inside. Pick a line, the
--      ped eats/drinks it, the server drops that layer from the bag's metadata,
--      and the menu reopens on what's left (closing itself when the bag runs out).
--    • MEAL — eat-in only: it hands off to modules/dining, which lays the tray out
--      on the table in front of a SEATED customer to be clicked through. Using a
--      meal on your feet just tells you to sit down.
--
--  The eat animation is the shared one below, not a per-item clip: what changes is
--  only whether it's a drink (bottle) or food (burger).
-- =============================================

-- LAST-RESORT clips. Which animation actually plays is authored per FOOD (its
-- `consume.anim` picks an entry from the `consume_anims` setting) and arrives with
-- the server's answer as a full { dict, clip, prop, ms } spec — this pair only
-- covers a food that names no animation on a server whose catalogue is empty.
local EAT = {
    dict = "mp_player_inteat@burger", clip = "mp_player_int_eat_burger",
    prop = "prop_cs_burger_01",   -- held while eating (deleted after)
    ms   = 3000,
}
local DRINK = {
    dict = "mp_player_intdrink", clip = "loop_bottle",
    prop = "prop_ld_flow_bottle",
    ms   = 3000,
}

local eating = false -- one bite at a time (a second use is ignored, never queued)

local function loadDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local t = GetGameTimer()
    while not HasAnimDictLoaded(dict) and GetGameTimer() - t < 2000 do Wait(0) end
    return HasAnimDictLoaded(dict)
end

-- Play one eat/drink: the clip, a prop in the hand, and a progress bar. Returns
-- when it's done (or was cancelled by death). Seated customers keep their pose
-- afterwards — the sit loop in modules/seating re-asserts itself. Global so the
-- eat-in view (modules/dining) plays the identical mouthful.
-- `spec` is the food's own animation ({ dict, clip, prop, ms }, resolved server-side
-- from the consume_anims catalogue); `isDrink` only picks the fallback.
function ConsumeAnim(isDrink, label, spec)
    local a = (type(spec) == "table" and spec.dict and spec.clip) and spec
        or (isDrink and DRINK or EAT)
    local ms = math.max(500, math.floor(tonumber(a.ms) or 3000))
    local ped = PlayerPedId()
    local obj
    if loadDict(a.dict) then
        TaskPlayAnim(ped, a.dict, a.clip, 4.0, -4.0, -1, 49, 0.0, false, false, false)
    end
    local model = (a.prop and a.prop ~= "") and GetHashKey(a.prop) or nil
    if model then
        RequestModel(model)
        local t0 = GetGameTimer()
        while not HasModelLoaded(model) and GetGameTimer() - t0 < 1000 do Wait(0) end
    end
    if model and HasModelLoaded(model) then
        local c = GetEntityCoords(ped)
        obj = CreateObject(model, c.x, c.y, c.z, true, true, false)
        AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, 18905),
            0.13, 0.05, 0.02, -50.0, 16.0, 60.0, true, true, false, true, 1, true)
        SetModelAsNoLongerNeeded(model)
    end
    if lib and lib.progressBar then
        lib.progressBar({ duration = ms, label = label, useWhileDead = false,
                          canCancel = false, disable = { move = false, combat = true } })
    else
        Wait(ms)
    end
    if obj and DoesEntityExist(obj) then
        SetEntityAsMissionEntity(obj, true, true)
        DeleteEntity(obj)
    end
    ClearPedTasks(ped)
end

-- Eat ONE layer out of a vessel. Server-authoritative: it re-reads the slot, drops
-- the layer, and tells us what was actually consumed. Returns the fresh contents
-- (empty when the vessel is gone).
function ConsumeLayer(vessel, index)
    if eating then return nil end
    eating = true
    local res = lib.callback.await("pickle_restaurants:consume:eat", false,
        { item = vessel.item, slot = vessel.slot, index = index })
    if not (res and res.ok) then
        eating = false
        if res and res.error then ShowNotification(res.error) end
        return nil
    end
    ConsumeAnim(res.drink, res.label, res.anim)
    ShowNotification(_L(res.drink and "consume_drank" or "consume_ate", res.label))
    eating = false
    return res.contents or {}
end

-- The bag's contents menu (ox_lib context). Rebuilt after each bite so the list
-- always reflects what's really left; an emptied bag just closes.
local function showBagMenu(vessel, contents)
    if #contents == 0 then
        if lib and lib.hideContext then lib.hideContext() end
        return
    end
    local options = {}
    for _, c in ipairs(contents) do
        options[#options + 1] = {
            title = c.label,
            description = _L(c.drink and "consume_pick_drink" or "consume_pick_eat"),
            icon = c.drink and "mug-hot" or "utensils",
            image = c.image,
            onSelect = function()
                local left = ConsumeLayer(vessel, c.index)
                if left then showBagMenu(vessel, left) end
            end,
        }
    end
    lib.registerContext({
        id = "pickle_restaurants_bag",
        title = _L("consume_bag_title"),
        options = options,
    })
    lib.showContext("pickle_restaurants_bag")
end

-- The server's answer to using a vessel item.
RegisterNetEvent("pickle_restaurants:consume:open", function(d)
    if type(d) ~= "table" then return end
    local vessel = { item = d.item, slot = d.slot }
    if d.kind == "meal" then
        -- eat-in only: a meal is laid out on the table you're sitting at
        if not (IsSeated and IsSeated()) then
            return ShowNotification(_L("consume_meal_sit_first"))
        end
        if OpenMealView then OpenMealView(vessel, d.contents or {}) end
        return
    end
    showBagMenu(vessel, d.contents or {})
end)
