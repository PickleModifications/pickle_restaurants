if GetResourceState('qb-core') ~= 'started' then return end

QBCore = exports['qb-core']:GetCoreObject()

function RegisterCallback(name, cb)
    QBCore.Functions.CreateCallback(name, cb)
end

function RegisterUsableItem(...)
    QBCore.Functions.CreateUseableItem(...)
end

function ShowNotification(target, text)
	TriggerClientEvent(GetCurrentResourceName()..":showNotification", target, text)
end

function GetIdentifier(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))?.PlayerData
    if not xPlayer or not xPlayer.citizenid then return end
    return xPlayer.citizenid 
end

function GetSourceFromIdentifier(identifier)
    local xPlayer = QBCore.Functions.GetPlayerByCitizenId(identifier)
    return xPlayer and xPlayer?.PlayerData.source or nil
end

function GetPlayerCharacterName(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer or not xPlayer.PlayerData then return _L("name_unknown") end
    return xPlayer.PlayerData.charinfo.firstname .. " " .. xPlayer.PlayerData.charinfo.lastname
end

function CanAccessGroup(source, data)
    if not data then return true end
    local pdata = QBCore.Functions.GetPlayer(tonumber(source)).PlayerData
    for k,v in pairs(data) do 
        if (pdata.job.name == k and pdata.job.grade.level >= v) then return true end
    end
    return false
end

function CheckPermission(source, permission)
    if permission.ignorePermissions then return true end
    local source = tonumber(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))?.PlayerData
    if not xPlayer then return end
    local name = xPlayer.job.name
    local rank = xPlayer.job.grade.level
    if permission.jobs[name] and permission.jobs[name] <= rank then 
        return true
    end
    for i=1, #(permission.groups or {}) do 
        if QBCore.Functions.HasPermission(source, permission.groups[i]) then 
            return true 
        end
    end
end

function AddMoney(source, count, currency)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    local currency = currency or "money"
    if (currency == "money") then
        xPlayer.Functions.AddMoney('cash', count)
    elseif (currency == "bank") then
        xPlayer.Functions.AddMoney('bank', count)
    elseif (currency == "dirty") then
        local setting = Config.FrameworkSettings.dirtyMoney
        Inventory.AddItem(source, setting == "DEFAULT" and 'dirty_money' or setting, count)
    end
    TriggerClientEvent("pickle_restaurants:updateMoney", source, money)
end

function RemoveMoney(source, count, currency)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    local currency = currency or "money"
    if (currency == "money") then
        xPlayer.Functions.RemoveMoney('cash', count)
    elseif (currency == "bank") then
        xPlayer.Functions.RemoveMoney('bank', count)
    elseif (currency == "dirty") then
        local setting = Config.FrameworkSettings.dirtyMoney
        Inventory.RemoveItem(source, setting == "DEFAULT" and 'dirty_money' or setting, count)
    end
    TriggerClientEvent("pickle_restaurants:updateMoney", source, money)
end

function GetMoney(source, currency)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    local currency = currency or "money"
    local money = 0
    if (currency == "money") then
        money = xPlayer.PlayerData.money.cash
    elseif (currency == "bank") then
        money = xPlayer.PlayerData.money.bank or 0
    elseif (currency == "dirty") then
        local setting = Config.FrameworkSettings.dirtyMoney
        money = Inventory.GetItemCount(source, setting == "DEFAULT" and 'dirty_money' or setting)
    end
    TriggerClientEvent("pickle_restaurants:updateMoney", source, money)
    return money
end

function GetOwnedVehicleFromPlate(plate)
    local data = MySQL.Sync.fetchAll("SELECT * FROM player_vehicles WHERE plate=@plate;", {
        ['@plate'] = plate,
    })[1]
    return data and {owner = data.citizenid} or nil
end

function AddOwnedVehicle(source, model)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    local plate = ""
    local letters = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"}
    local numbers = {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
    for i = 1, 3 do
        plate = plate .. letters[math.random(1, #letters)]
    end
    plate = plate .. " "
    for i = 1, 3 do
        plate = plate .. numbers[math.random(1, #numbers)]
    end
    MySQL.Async.fetchAll('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, plate, garage, state) VALUES (@license, @citizenid, @vehicle, @hash, @plate, @garage, @state)',
    {
        ['@license'] = xPlayer.PlayerData.license,
        ['@citizenid'] = xPlayer.PlayerData.citizenid,
        ['@vehicle'] = model,
        ['@hash'] = joaat(model),
        ['@plate'] = toupper(plate),
        ['@garage'] = "pillboxgarage",
        ['@state'] = 0
    })
end

function UpdateVehiclePlate(source, plate, newPlate)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    MySQL.Async.execute('UPDATE player_vehicles SET plate = @newPlate WHERE plate = @plate AND citizenid = @citizenid',
    {
        ['@newPlate'] = newPlate,
        ['@plate'] = plate,
        ['@citizenid'] = xPlayer.PlayerData.citizenid
    })
end

function GetPlayerJob(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer then return end
    return {label = xPlayer.PlayerData.job.label, rank_label = xPlayer.PlayerData.job.grade.name}
end

function GetPlayerJobName(source)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    if not xPlayer or not xPlayer.PlayerData or not xPlayer.PlayerData.job then return nil end
    return xPlayer.PlayerData.job.name
end

function SetPlayerJob(source, job, grade)
    local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
    xPlayer.Functions.SetJob(job, grade)
end

function IsPlayerJobBoss(source, jobName)
    if not jobName then return false end
    local player = QBCore.Functions.GetPlayer(tonumber(source))
    if not player or not player.PlayerData or not player.PlayerData.job then return false end
    if player.PlayerData.job.name ~= jobName then return false end
    if player.PlayerData.job.isboss == true then return true end
    if player.PlayerData.job.grade and player.PlayerData.job.grade.isboss == true then return true end
    return false
end

function GetEmployees(jobName, cb)
    local employees = {}
    local players = QBCore.Functions.GetQBPlayers()
    for _, player in pairs(players) do
        if player and player.PlayerData and player.PlayerData.job and player.PlayerData.job.name == jobName then
            employees[#employees + 1] = {
                source = player.PlayerData.source,
                name = player.PlayerData.charinfo.firstname .. " " .. player.PlayerData.charinfo.lastname,
                grade = player.PlayerData.job.grade.level,
                gradeLabel = player.PlayerData.job.grade.name,
                online = true,
            }
        end
    end
    if type(cb) == "function" then cb(employees) end
    return employees
end

function GetJobGrades(jobName)
    local job = QBCore.Shared.Jobs[jobName]
    if not job or not job.grades then return {} end
    local grades = {}
    for level, grade in pairs(job.grades) do
        grades[#grades + 1] = {
            level = tonumber(level),
            label = grade.name or ("Grade " .. level),
        }
    end
    table.sort(grades, function(a, b) return a.level < b.level end)
    return grades
end

function IsPlayerAdmin(source)
    local source = tonumber(source)
    local permissions = QBCore.Functions.GetPermission(source)
    for i=1, #Config.AdminGroups do 
        if QBCore.Functions.HasPermission(source, Config.AdminGroups[i]) or IsPlayerAceAllowed(source, "command") then 
            return true 
        end
    end
    return false
end

function AddSocietyMoney(name, amount)
    if Config.FrameworkSettings.society == "qb-management" then
        exports["qb-management"]:AddMoney(name, amount)
    else
        exports["qb-banking"]:AddMoney(name, amount)
    end
end

-- Inventory Fallback

CreateThread(function()
    Wait(100)
    
    if InitializeInventory then return InitializeInventory() end -- Already loaded through inventory folder.
    
    Inventory = {}

    Inventory.Items = {}
    
    Inventory.Ready = false

    Inventory.CanCarryItem = function(source, name, count)
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        if not xPlayer or not xPlayer.PlayerData then return true end
        -- Be defensive: GetTotalWeight can return nil, the item may be unknown, and
        -- an item can lack a weight field. Any missing piece → assume it fits (the
        -- real AddItem still enforces capacity) rather than erroring out the caller
        -- (e.g. a whole order fulfillment) on an arithmetic-on-nil.
        local ok, weight = pcall(QBCore.Player.GetTotalWeight, xPlayer.PlayerData.items)
        if not ok or type(weight) ~= "number" then return true end
        local item = QBCore.Shared.Items[name:lower()]
        if not item or type(item.weight) ~= "number" then return true end
        local max = QBCore.Config and QBCore.Config.Player and QBCore.Config.Player.MaxWeight
        if type(max) ~= "number" then return true end
        return (weight + (item.weight * count)) <= max
    end

    Inventory.GetInventory = function(source)
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        local items = {}
        local data = xPlayer.PlayerData.items
        for slot, item in pairs(data) do 
            items[#items + 1] = {
                name = item.name,
                label = item.label,
                count = item.amount,
                weight = item.weight
            }
        end
        return items
    end

    Inventory.UpdateInventory = function(source)
        SetTimeout(1000, function()
            TriggerClientEvent("pickle_restaurants:updateInventory", source, Inventory.GetInventory(source))
        end)
    end

    Inventory.AddItem = function(source, name, count, metadata) -- Metadata is not required.
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        xPlayer.Functions.AddItem(name, count, nil, metadata)
        Inventory.UpdateInventory(source)
    end

    Inventory.RemoveItem = function(source, name, count)
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        xPlayer.Functions.RemoveItem(name, count)
        Inventory.UpdateInventory(source)
    end

    Inventory.AddWeapon = function(source, name, count, metadata) -- Metadata is not required.
        Inventory.AddItem(source, name, count, metadata)
    end

    Inventory.RemoveWeapon = function(source, name, count)
        Inventory.RemoveItem(source, name, count, metadata)
    end

    Inventory.GetItemCount = function(source, name)
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        if not xPlayer then return 0 end
        local item = xPlayer.Functions.GetItemByName(name)
        return item and item.amount or 0
    end

    Inventory.HasWeapon = function(source, name, count)
        return (Inventory.GetItemCount(source, name) > 0)
    end

    RegisterCallback("pickle_restaurants:getInventory", function(source, cb)
        cb(Inventory.GetInventory(source))
    end)

    -- When ox_inventory is in use its registry is the source of truth (item
    -- defs may live in ox's own data and never reach QBCore.Shared.Items), so
    -- prefer it and fall back to qb-core only when ox isn't running.
    local function usingOx() return GetResourceState("ox_inventory") == "started" end

    Inventory.RefreshItems = function()
        Inventory.Items = {}
        local base = InventoryImageBase()
        if usingOx() then
            for item, data in pairs(exports.ox_inventory:Items() or {}) do
                Inventory.Items[item] = { label = data.label, image = InvImageUrl(base, item, data.image) }
            end
        else
            for item, data in pairs(QBCore.Shared.Items) do
                Inventory.Items[item] = { label = data.label, image = InvImageUrl(base, item, data.image) }
            end
        end
    end
    -- Live lookup so a newly-added item is recognised without a restart.
    Inventory.ItemExists = function(name)
        if not name or name == "" then return false end
        if usingOx() then return exports.ox_inventory:Items(name) ~= nil end
        return QBCore.Shared.Items[name:lower()] ~= nil
    end

    -- Per-slot access so item variations survive the inventory round-trip: the
    -- cooking module reads each slot's metadata (build stack / cheese) and removes
    -- from the exact slot it showed. ox_inventory first, qb slots as fallback.
    Inventory.GetItemSlots = function(source, name)
        local out = {}
        if usingOx() then
            for _, s in ipairs(exports.ox_inventory:Search(source, "slots", name) or {}) do
                out[#out + 1] = { slot = s.slot, count = s.count or 1, metadata = s.metadata }
            end
            return out
        end
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        for slot, item in pairs(xPlayer and xPlayer.PlayerData.items or {}) do
            if item and item.name == name then
                out[#out + 1] = { slot = item.slot or slot, count = item.amount or 1, metadata = item.info }
            end
        end
        return out
    end

    Inventory.RemoveItemSlot = function(source, name, count, slot)
        if usingOx() then
            exports.ox_inventory:RemoveItem(source, name, count, nil, slot)
            return
        end
        local xPlayer = QBCore.Functions.GetPlayer(tonumber(source))
        if xPlayer then xPlayer.Functions.RemoveItem(name, count, slot) end
        Inventory.UpdateInventory(source)
    end

    Inventory.RefreshItems()
    Inventory.Ready = true
end)