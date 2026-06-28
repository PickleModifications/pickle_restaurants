-- =============================================
--  modules/npc_customers | client.lua
--  Cosmetic walk-up customers: spawns a local ped near the counter while an
--  order is pending (the order/money logic is fully server-authoritative).
-- =============================================

local orderPeds = {} -- ["rid:oid"] = ped
local PED_MODELS = { "a_m_y_business_01", "a_f_y_business_02", "a_m_m_business_01", "a_f_y_hipster_02", "a_m_y_skater_01" }

local function key(rid, oid) return tostring(rid) .. ":" .. tostring(oid) end

RegisterNetEvent("pickle_restaurants:npc:orderAdded", function(rid, oid, counter)
    if not counter then return end
    local k = key(rid, oid)
    if orderPeds[k] then return end
    CreateThread(function()
        local h = (counter.heading or 0.0) + 180.0
        local rad = math.rad(h)
        local ox = math.sin(-rad) * (1.0 + math.random() * 0.6)
        local oy = math.cos(-rad) * (1.0 + math.random() * 0.6)
        local x, y, z = counter.x + ox, counter.y + oy, counter.z
        local model = PED_MODELS[math.random(#PED_MODELS)]
        local ped = CreateNPC(GetHashKey(model), x, y, z - 1.0, counter.heading or 0.0, false, true)
        if ped and DoesEntityExist(ped) then
            SetEntityInvincible(ped, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            FreezeEntityPosition(ped, true)
            TaskTurnPedToFaceCoord(ped, counter.x, counter.y, counter.z, -1)
            orderPeds[k] = ped
        end
    end)
end)

RegisterNetEvent("pickle_restaurants:npc:orderRemoved", function(rid, oid)
    local k = key(rid, oid)
    local ped = orderPeds[k]
    if ped and DoesEntityExist(ped) then DeleteEntity(ped) end
    orderPeds[k] = nil
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for k, ped in pairs(orderPeds) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
        orderPeds[k] = nil
    end
end)
