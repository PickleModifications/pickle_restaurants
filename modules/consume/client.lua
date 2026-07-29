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

-- Where a held prop sits in the hand. TUNE IN-GAME.
local HOLD = { x = 0.13, y = 0.05, z = 0.02, rx = -50.0, ry = 16.0, rz = 60.0 }

local function loadModelTimeout(name)
    local hash = (name and name ~= "") and GetHashKey(name) or nil
    if not hash then return nil end
    RequestModel(hash)
    local t0 = GetGameTimer()
    while not HasModelLoaded(hash) and GetGameTimer() - t0 < 1000 do Wait(0) end
    return HasModelLoaded(hash) and hash or nil
end

-- Put a STACK of props in the hand: the first goes to the hand bone, and each one
-- after it rides on TOP of the one below at its measured height — a cup with its
-- lid on, seated exactly the way the kitchen renders a capped cup, so what you
-- drink from matches what was poured.
--
-- Stacking onto the ENTITY below (not onto the bone with a bigger z) is deliberate:
-- the hand offset is a rotated frame, so a lid offset in bone space would drift off
-- the cup as the wrist turns. Attached to the cup, it can't.
--
-- Branding needs nothing here — the cup's texture is a render target, and
-- modules/rendertarget is already painting the NEAREST restaurant's brand onto it,
-- which is also what makes a meal carried into another restaurant read as that
-- restaurant's cup.
local function attachHeldStack(ped, models)
    local objs, below, belowH = {}, nil, 0.0
    for _, name in ipairs(models or {}) do
        local hash = loadModelTimeout(name)
        if hash then
            local c = GetEntityCoords(ped)
            local o = CreateObject(hash, c.x, c.y, c.z, true, true, false)
            if below and DoesEntityExist(below) then
                AttachEntityToEntity(o, below, 0, 0.0, 0.0, belowH, 0.0, 0.0, 0.0,
                                     true, true, false, false, 1, true)
            else
                AttachEntityToEntity(o, ped, GetPedBoneIndex(ped, 18905),
                                     HOLD.x, HOLD.y, HOLD.z, HOLD.rx, HOLD.ry, HOLD.rz,
                                     true, true, false, true, 1, true)
            end
            SetModelAsNoLongerNeeded(hash)
            local mn, mx = GetModelDimensions(hash)
            belowH = (mn and mx) and (mx.z - mn.z) or 0.12
            below = o
            objs[#objs + 1] = o
        end
    end
    return objs
end

-- Play one eat/drink: the clip, a prop in the hand, and a progress bar. Returns
-- when it's done (or was cancelled by death). Seated customers keep their pose
-- afterwards — the sit loop in modules/seating re-asserts itself. Global so the
-- eat-in view (modules/dining) plays the identical mouthful.
-- `spec` is the food's own animation ({ dict, clip, prop, ms }, resolved server-side
-- from the consume_anims catalogue); `isDrink` only picks the fallback.
-- `props` (optional): the exact models to hold, resolved server-side — a drink's
-- capped restaurant cup. Overrides the animation's own generic prop when present.
function ConsumeAnim(isDrink, label, spec, props)
    local a = (type(spec) == "table" and spec.dict and spec.clip) and spec
        or (isDrink and DRINK or EAT)
    local ms = math.max(500, math.floor(tonumber(a.ms) or 3000))
    local ped = PlayerPedId()
    if loadDict(a.dict) then
        TaskPlayAnim(ped, a.dict, a.clip, 4.0, -4.0, -1, 49, 0.0, false, false, false)
    end
    local held = (type(props) == "table" and #props > 0) and props
        or ((a.prop and a.prop ~= "") and { a.prop } or nil)
    local objs = held and attachHeldStack(ped, held) or {}
    if lib and lib.progressBar then
        lib.progressBar({ duration = ms, label = label, useWhileDead = false,
                          canCancel = false, disable = { move = false, combat = true } })
    else
        Wait(ms)
    end
    for _, o in ipairs(objs) do
        if DoesEntityExist(o) then
            SetEntityAsMissionEntity(o, true, true)
            DeleteEntity(o)
        end
    end
    ClearPedTasks(ped)
end

-- Eat ONE layer out of a vessel. Server-authoritative: it re-reads the slot, drops
-- the layer, and tells us what was actually consumed. Returns the fresh contents
-- (empty when the vessel is gone).
-- `whole` finishes the serving in one go instead of taking a single bite/sip.
function ConsumeLayer(vessel, index, whole)
    if eating then return nil end
    eating = true
    local res = lib.callback.await("pickle_restaurants:consume:eat", false,
        { item = vessel.item, slot = vessel.slot, index = index, whole = whole or nil })
    if not (res and res.ok) then
        eating = false
        if res and res.error then ShowNotification(res.error) end
        return nil
    end
    ConsumeAnim(res.drink, res.label, res.anim, res.props)
    -- Say what happened: a mouthful with more to come reads differently from the
    -- last one, and without the count a bite looks like a no-op on a big serving.
    -- A thing that is USED rather than eaten (a toy) is never part-finished — it is
    -- always the one-and-done line, whatever `bites` says.
    local left = res.bites and res.bites.left or 0
    if res.play then
        ShowNotification(_L("consume_played", res.label))
    elseif left > 0 then
        ShowNotification(_L(res.drink and "consume_sipped_left" or "consume_bit_left", res.label, left))
    else
        ShowNotification(_L(res.drink and "consume_drank" or "consume_ate", res.label))
    end
    eating = false
    return res.contents or {}
end

-- A takeout box eaten on your feet: one food, so no contents list — just the two
-- ways to eat it. Reopens after a bite while anything is left, and closes itself on
-- the last one (an emptied box returns no contents).
function showBoxMenu(vessel, food)
    local left = food.bitesLeft or 1
    lib.registerContext({
        id = "pickle_restaurants_box",
        title = food.label or _L("consume_bag_title"),
        options = {
            {
                title = _L(food.drink and "consume_take_sip" or "consume_take_bite"),
                description = _L("consume_left_n", left),
                icon = food.drink and "mug-hot" or "utensils",
                image = food.image,
                onSelect = function()
                    local rest = ConsumeLayer(vessel, 1, false)
                    if rest and #rest > 0 then
                        showBoxMenu(vessel, { label = food.label, image = food.image,
                                              drink = food.drink, bitesLeft = math.max(1, left - 1) })
                    end
                end,
            },
            {
                title = _L(food.drink and "consume_finish_drink" or "consume_finish_food"),
                description = _L("consume_finish_hint"),
                icon = "circle-check",
                onSelect = function() ConsumeLayer(vessel, 1, true) end,
            },
        },
    })
    lib.showContext("pickle_restaurants_box")
end

-- The bag's contents menu (ox_lib context). Rebuilt after each bite so the list
-- always reflects what's really left; an emptied bag just closes.
local function showBagMenu(vessel, contents)
    if #contents == 0 then
        if lib and lib.hideContext then lib.hideContext() end
        return
    end
    -- Each row opens its own two-choice menu — one mouthful, or finish it. A single
    -- onSelect could only ever do one of those, and hanging a second row off every
    -- item would double the length of a bag's list.
    local options = {}
    for _, c in ipairs(contents) do
        local left = c.bitesLeft or 1
        -- A thing that is USED rather than eaten (a toy that came with the meal) has
        -- no "one bite / finish it" to choose between — it's one action, so it gets a
        -- plain row instead of a sub-menu.
        if c.play then
            options[#options + 1] = {
                title = c.label,
                description = _L("consume_pick_use"),
                icon = "hand-sparkles",
                image = c.image,
                onSelect = function()
                    local rest = ConsumeLayer(vessel, c.index, true)
                    if rest then showBagMenu(vessel, rest) end
                end,
            }
            goto continue
        end
        local sub = "pickle_restaurants_bite_" .. tostring(c.index)
        lib.registerContext({
            id = sub,
            title = c.label,
            menu = "pickle_restaurants_bag", -- back button returns to the contents
            options = {
                {
                    title = _L(c.drink and "consume_take_sip" or "consume_take_bite"),
                    description = _L("consume_left_n", left),
                    icon = c.drink and "mug-hot" or "utensils",
                    onSelect = function()
                        local rest = ConsumeLayer(vessel, c.index, false)
                        if rest then showBagMenu(vessel, rest) end
                    end,
                },
                {
                    title = _L(c.drink and "consume_finish_drink" or "consume_finish_food"),
                    description = _L("consume_finish_hint"),
                    icon = "circle-check",
                    onSelect = function()
                        local rest = ConsumeLayer(vessel, c.index, true)
                        if rest then showBagMenu(vessel, rest) end
                    end,
                },
            },
        })
        options[#options + 1] = {
            title = c.label,
            -- the count belongs on the row you pick FROM, so a part-eaten thing is
            -- visible without opening it
            description = (left > 1) and _L("consume_left_n", left)
                or _L(c.drink and "consume_pick_drink" or "consume_pick_eat"),
            icon = c.drink and "mug-hot" or "utensils",
            image = c.image,
            arrow = true,
            menu = sub,
        }
        ::continue::
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
    -- A TAKEOUT BOX goes either way. SEATED, it is set down on the table and eaten
    -- from like a meal — you paid for a sit-down either way, and a box on the table
    -- should behave like the food it is. On your feet it's takeaway: one food, one
    -- action, eaten where you stand (no contents menu — there is only ever one
    -- thing in a box, and the server eats the whole thing whatever index we send).
    if d.kind == "box" then
        if IsSeated and IsSeated() and OpenMealView then
            OpenMealView(vessel, d.contents or {})
        else
            showBoxMenu(vessel, d.food or {})
        end
        return
    end
    showBagMenu(vessel, d.contents or {})
end)
