if GetResourceState('es_extended') ~= 'started' then return end

ESX = exports.es_extended:getSharedObject()

function RegisterCallback(name, cb)
    ESX.RegisterServerCallback(name, cb)
end

function RegisterUsableItem(...)
    ESX.RegisterUsableItem(...)
end

function ShowNotification(target, text)
	TriggerClientEvent(GetCurrentResourceName()..":showNotification", target, text)
end

function GetIdentifier(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer or not xPlayer.identifier then return end
    return xPlayer.identifier
end

function GetSourceFromIdentifier(identifier)
    local xPlayer = ESX.GetPlayerFromIdentifier(identifier)
    return xPlayer and xPlayer.source or nil
end

function GetPlayerCharacterName(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then return _L("name_unknown") end
    return xPlayer.getName()
end

function CanAccessGroup(source, data)
    if not data then return true end
    local pdata = ESX.GetPlayerFromId(source)
    for k,v in pairs(data.jobs) do 
        if (pdata.job.name == k and pdata.job.grade >= v) then return true end
    end
    return false
end 

function CheckPermission(source, permission)
    if permission.ignorePermissions then return true end
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then return end
    local name = xPlayer.job.name
    local rank = xPlayer.job.grade
    local group = xPlayer.getGroup()
    if permission.jobs[name] and permission.jobs[name] <= rank then 
        return true
    end
    for i=1, #(permission.groups or {}) do 
        if group == permission.groups[i] then 
            return true 
        end
    end
end

function AddMoney(source, count, currency)
    local xPlayer = ESX.GetPlayerFromId(source)
    local currency = currency or "money"
    if (currency == "money") then
        xPlayer.addMoney(count)
    elseif (currency == "bank") then
        xPlayer.addAccountMoney("bank", count)
    elseif (currency == "dirty") then
        xPlayer.addAccountMoney("black_money", count)
    end
    TriggerClientEvent("pickle_restaurants:updateMoney", source, GetMoney(source, currency))
end

function RemoveMoney(source, count, currency)
    local xPlayer = ESX.GetPlayerFromId(source)
    local currency = currency or "money"
    if (currency == "money") then
        xPlayer.removeMoney(count)
    elseif (currency == "bank") then
        xPlayer.removeAccountMoney("bank", count)
    elseif (currency == "dirty") then
        xPlayer.removeAccountMoney("black_money", count)
    end
    TriggerClientEvent("pickle_restaurants:updateMoney", source, GetMoney(source, currency))
end

function GetMoney(source, currency)
    local xPlayer = ESX.GetPlayerFromId(source)
    local currency = currency or "money"
    local money = 0
    if (currency == "money") then
        money = xPlayer.getMoney()
    elseif (currency == "bank") then
        local acc = xPlayer.getAccount("bank")
        money = acc and acc.money or 0
    elseif (currency == "dirty") then
        money = xPlayer.getAccount("black_money").money
    end
    TriggerClientEvent("pickle_restaurants:updateMoney", source, money)
    return money
end

function GetOwnedVehicleFromPlate(plate)
    local data = MySQL.Sync.fetchAll("SELECT * FROM owned_vehicles WHERE plate=@plate;", {
        ['@plate'] = plate,
    })[1]
    return data and {owner = data.owner} or nil 
end

function AddOwnedVehicle(source, plate, model)
    local xPlayer = ESX.GetPlayerFromId(source)
    MySQL.Async.execute("INSERT INTO owned_vehicles (owner, plate, vehicle) VALUES (@owner, @plate, @vehicle);", {
        ['@owner'] = xPlayer.identifier,
        ['@plate'] = plate,
        ['@vehicle'] = json.encode({
            plate = toupper(plate),
            model = joaat(model),
        }),
    })
end

function UpdateVehiclePlate(source, plate, newPlate)
    local xPlayer = ESX.GetPlayerFromId(source)
    MySQL.Async.execute("UPDATE owned_vehicles SET plate=@newPlate WHERE owner=@owner AND plate=@plate;", {
        ['@owner'] = xPlayer.identifier,
        ['@plate'] = plate,
        ['@newPlate'] = newPlate,
    })
end

function GetPlayerJob(source)
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer then return _L("job_unknown"), _L("job_grade_unknown") end
    return {label = xPlayer.job.label, rank_label = xPlayer.job.grade_label}
end

function GetPlayerJobName(source)
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer or not xPlayer.job then return nil end
    return xPlayer.job.name
end

function SetPlayerJob(source, job, grade)
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer then return end
    xPlayer.setJob(job, grade)
end

function IsPlayerJobBoss(source, jobName)
    if not jobName then return false end
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer or not xPlayer.job then return false end
    if xPlayer.job.name ~= jobName then return false end
    if xPlayer.job.grade_name == "boss" then return true end
    local jobs = ESX.GetJobs and ESX.GetJobs() or nil
    if jobs and jobs[jobName] and jobs[jobName].grades then
        local maxGrade = -1
        for _, g in pairs(jobs[jobName].grades) do
            local lvl = tonumber(g.grade) or -1
            if lvl > maxGrade then maxGrade = lvl end
        end
        if maxGrade >= 0 and tonumber(xPlayer.job.grade) == maxGrade then return true end
    end
    return false
end

function GetEmployees(jobName, cb)
    local employees = {}
    local xPlayers = ESX.GetExtendedPlayers("job", jobName)
    for _, xPlayer in pairs(xPlayers) do
        employees[#employees + 1] = {
            source = xPlayer.source,
            name = xPlayer.getName(),
            grade = xPlayer.job.grade,
            gradeLabel = xPlayer.job.grade_label or ("Grade " .. xPlayer.job.grade),
            online = true,
        }
    end
    if type(cb) == "function" then cb(employees) end
    return employees
end

function GetJobGrades(jobName)
    local job = ESX.GetJobs()
    if not job or not job[jobName] or not job[jobName].grades then return {} end
    local grades = {}
    for _, grade in pairs(job[jobName].grades) do
        grades[#grades + 1] = {
            level = grade.grade,
            label = grade.label or ("Grade " .. grade.grade),
        }
    end
    table.sort(grades, function(a, b) return a.level < b.level end)
    return grades
end

-- ─── the normalized JOB API ───────────────────────────────────────────────────
-- A restaurant is STAFFED BY A FRAMEWORK JOB (its `metadata.job`) rather than by a
-- private employee table, so every bridge variant answers the same questions about
-- jobs in the same shape. Core's ResolvePerms and the admin/management panels only
-- ever speak this API — they never touch ESX or QB directly.
--
-- ESX has no per-grade boss flag. The long-standing convention is a grade literally
-- NAMED "boss", and failing that the highest grade of the job; that is the exact
-- heuristic IsPlayerJobBoss above has always used here and it is kept, so a server's
-- existing job definitions need no editing to be usable as a restaurant's staff.

function JobsAvailable() return true end

-- One job definition → our grades array. `boss` is decided per grade by the
-- heuristic above: the grade named "boss", else the highest grade there is.
local function esxGradeList(job)
    local grades, maxGrade = {}, -1
    for _, g in pairs((job and job.grades) or {}) do
        local lvl = tonumber(g.grade) or 0
        if lvl > maxGrade then maxGrade = lvl end
        grades[#grades + 1] = {
            grade  = lvl,
            label  = g.label or g.name or (_L("job_grade_n", lvl)),
            isboss = (g.name == "boss") or nil,
            _name  = g.name,
        }
    end
    table.sort(grades, function(a, b) return a.grade < b.grade end)
    local named = false
    for _, g in ipairs(grades) do if g.isboss then named = true end end
    for _, g in ipairs(grades) do
        if not named and g.grade == maxGrade then g.isboss = true end
        g.isboss = g.isboss == true
        g._name = nil
    end
    return grades
end

function GetJobList()
    local out = {}
    for name, job in pairs(ESX.GetJobs and ESX.GetJobs() or {}) do
        out[#out + 1] = { name = name, label = job.label or name, grades = esxGradeList(job) }
    end
    table.sort(out, function(a, b) return (a.label or a.name):lower() < (b.label or b.name):lower() end)
    return out
end

function GetJobGradeList(jobName)
    local jobs = ESX.GetJobs and ESX.GetJobs() or {}
    return jobName and jobs[jobName] and esxGradeList(jobs[jobName]) or {}
end

function GetJobLabel(jobName)
    if not jobName or jobName == "" then return nil end
    local jobs = ESX.GetJobs and ESX.GetJobs() or {}
    return (jobs[jobName] and jobs[jobName].label) or jobName
end

function GetPlayerJobInfo(source)
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer or not xPlayer.job or not xPlayer.job.name then return nil end
    local grade = tonumber(xPlayer.job.grade) or 0
    return {
        name       = xPlayer.job.name,
        label      = xPlayer.job.label or GetJobLabel(xPlayer.job.name),
        grade      = grade,
        gradeLabel = xPlayer.job.grade_label or xPlayer.job.grade_name or _L("job_grade_n", grade),
        isBoss     = IsJobBossGrade(xPlayer.job.name, grade),
        -- ESX has no duty concept of its own: everyone with the job is on it.
        onDuty     = true,
    }
end

-- jobName nil/"" = FIRE: ESX's unemployed job is the one every player falls back to.
function SetPlayerJobGrade(source, jobName, grade)
    local xPlayer = ESX.GetPlayerFromId(tonumber(source))
    if not xPlayer then return false end
    if not jobName or jobName == "" then
        xPlayer.setJob("unemployed", 0)
        return true
    end
    xPlayer.setJob(jobName, tonumber(grade) or 0)
    return true
end

function IsJobBossGrade(jobName, grade)
    grade = tonumber(grade) or 0
    for _, g in ipairs(GetJobGradeList(jobName)) do
        if g.grade == grade then return g.isboss == true end
    end
    return false
end

-- ONLINE players only: ESX keeps no queryable offline job index, and inventing a
-- raw `users` query here would tie the bridge to one server's schema. A roster that
-- lists who is actually on shift is also the more useful answer for tips + payroll.
function GetJobEmployees(jobName, cb)
    local out = {}
    if jobName and jobName ~= "" then
        for _, xPlayer in pairs(ESX.GetExtendedPlayers("job", jobName) or {}) do
            local grade = tonumber(xPlayer.job.grade) or 0
            out[#out + 1] = {
                identifier = xPlayer.identifier,
                name       = xPlayer.getName(),
                grade      = grade,
                gradeLabel = xPlayer.job.grade_label or _L("job_grade_n", grade),
            }
        end
    end
    if type(cb) == "function" then cb(out) end
    return out
end

-- ONE resource event for "this player's job may have changed", whatever the
-- framework calls it. Core listens and invalidates what it derived from the old job.
AddEventHandler("esx:setJob", function(playerId, _job, _lastJob)
    TriggerEvent("pickle_restaurants:jobChanged", tonumber(playerId))
end)

function IsPlayerAdmin(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then return false end
    local group = xPlayer.getGroup()
    for i=1, #Config.AdminGroups do 
        if group == Config.AdminGroups[i] then
            return true 
        end
    end
    return false
end

function AddSocietyMoney(name, amount)
    TriggerEvent('esx_addonaccount:getSharedAccount', "society_"..name, function(account)
        account.addMoney(amount)
    end)
end

function AddOwnedVehicle(source, model)
    local xPlayer = ESX.GetPlayerFromId(source)
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
    MySQL.Async.execute("INSERT INTO owned_vehicles (owner, plate, vehicle) VALUES (@owner, @plate, @vehicle);", {
        ['@owner'] = xPlayer.identifier,
        ['@plate'] = plate,
        ['@vehicle'] = json.encode({
            plate = toupper(plate),
            model = joaat(model),
        }),
    })
end

-- Inventory Fallback

CreateThread(function()
    Wait(100)

    if InitializeInventory then return InitializeInventory() end -- Already loaded through inventory folder.
    
    Inventory = {}

    Inventory.Items = {}
    
    Inventory.Ready = false

    Inventory.CanCarryItem = function(source, name, count)
        local xPlayer = ESX.GetPlayerFromId(source)
        if Config.InventoryLimit then 
            local item = xPlayer.getInventoryItem(name)
            return (item.limit >= item.count + count)
        else 
            return xPlayer.canCarryItem(name, count)
        end
    end

    Inventory.GetInventory = function(source)
        local xPlayer = ESX.GetPlayerFromId(source)
        local items = {}
        local data = xPlayer.getInventory()
        for i=1, #data do 
            local item = data[i]
            if item then
                items[#items + 1] = {
                    name = item.name,
                    label = item.label,
                    count = item.count,
                    weight = item.weight
                }
            end
        end
        return items
    end

    Inventory.UpdateInventory = function(source)
        SetTimeout(1000, function()
            TriggerClientEvent("pickle_restaurants:updateInventory", source, Inventory.GetInventory(source))
        end)
    end

    Inventory.AddItem = function(source, name, count, metadata) -- Metadata is not required.
        local xPlayer = ESX.GetPlayerFromId(source)
        xPlayer.addInventoryItem(name, count)
        Inventory.UpdateInventory(source)
    end

    Inventory.RemoveItem = function(source, name, count)
        local xPlayer = ESX.GetPlayerFromId(source)
        xPlayer.removeInventoryItem(name, count)
        Inventory.UpdateInventory(source)
    end

    Inventory.AddWeapon = function(source, name, count, metadata) -- Metadata is not required.
        local xPlayer = ESX.GetPlayerFromId(source)
        xPlayer.addWeapon(name, 0)
        Inventory.UpdateInventory(source)
    end

    Inventory.RemoveWeapon = function(source, name, count)
        local xPlayer = ESX.GetPlayerFromId(source)
        xPlayer.removeWeapon(name, 0)
        Inventory.UpdateInventory(source)
    end

    Inventory.GetItemCount = function(source, name)
        local xPlayer = ESX.GetPlayerFromId(source)
        local item = xPlayer.getInventoryItem(name)
        return item and item.count or 0
    end

    Inventory.HasWeapon = function(source, name, count)
        local xPlayer = ESX.GetPlayerFromId(source)
        return xPlayer.hasWeapon(name)
    end

    RegisterCallback("pickle_restaurants:getInventory", function(source, cb)
        cb(Inventory.GetInventory(source))
    end)

    -- Rebuild the catalogue from whichever live registry is in use (ox/qs), so a
    -- newly-registered item is picked up without a restart. The raw-SQL ESX path
    -- below stays a one-time load (no cheap live registry to re-read).
    Inventory.RefreshItems = function()
        local base = InventoryImageBase()
        if GetResourceState("ox_inventory") == "started" then
            local items = {}
            for item, data in pairs(exports.ox_inventory:Items() or {}) do
                items[item] = { label = data.label, image = InvImageUrl(base, item, data.image) }
            end
            Inventory.Items = items
        elseif GetResourceState("qs-inventory") == "started" then
            local items = {}
            for item, data in pairs(exports['qs-inventory']:GetItemList() or {}) do
                items[item] = { label = data.label, image = InvImageUrl(base, item, data.image) }
            end
            Inventory.Items = items
        end
    end

    -- Live existence check straight from ox when present (no stale snapshot).
    Inventory.ItemExists = function(name)
        if not name or name == "" then return false end
        if GetResourceState("ox_inventory") == "started" then return exports.ox_inventory:Items(name) ~= nil end
        return Inventory.Items[name] ~= nil
    end

    -- Per-slot access (ox only — bare ESX has no slot metadata) so item variations
    -- survive the inventory round-trip — see the qb bridge for the shape.
    if GetResourceState("ox_inventory") == "started" then
        Inventory.GetItemSlots = function(source, name)
            local out = {}
            for _, s in ipairs(exports.ox_inventory:Search(source, "slots", name) or {}) do
                out[#out + 1] = { slot = s.slot, count = s.count or 1, metadata = s.metadata }
            end
            return out
        end
        Inventory.RemoveItemSlot = function(source, name, count, slot)
            exports.ox_inventory:RemoveItem(source, name, count, nil, slot)
        end
        -- Rewrite ONE slot's metadata in place (a Restaurant Bag losing the item the
        -- customer just ate). Absent without slot metadata — callers fall back to
        -- remove + re-add.
        Inventory.SetItemMetadata = function(source, _name, slot, metadata)
            exports.ox_inventory:SetMetadata(source, slot, metadata)
            return true
        end
    end

    if GetResourceState("ox_inventory") == "started" or GetResourceState("qs-inventory") == "started" then
        Inventory.RefreshItems()
        Inventory.Ready = true
    else
        MySQL.ready(function() 
            MySQL.Async.fetchAll("SELECT * FROM items;", {}, function(results) 
                for i=1, #results do 
                    Inventory.Items[results[i].name] = {label = results[i].label}
                end
                Inventory.Ready = true
            end)
        end)
    end
end)
-- Feed the framework's needs system after a customer eats/drinks something out of
-- a restaurant vessel (modules/consume). `hunger`/`thirst` are plain 0-100
-- percentages of the bar — each framework scales them its own way. ESX keeps both
-- in esx_status, which counts 0..1,000,000. A server without esx_status simply has
-- no status to add to: the events go nowhere and eating still works (item consumed,
-- animation played). The public event at the end lets ANY other needs system hook
-- in without touching this bridge.
function Nourish(source, hunger, thirst)
    hunger, thirst = math.floor(tonumber(hunger) or 0), math.floor(tonumber(thirst) or 0)
    if hunger > 0 then TriggerClientEvent("esx_status:add", source, "hunger", hunger * 10000) end
    if thirst > 0 then TriggerClientEvent("esx_status:add", source, "thirst", thirst * 10000) end
    TriggerEvent("pickle_restaurants:nourish", source, hunger, thirst)
end

-- Stress RELIEF (0-100 percentage of the bar), the counterpart to Nourish: it
-- DRAINS a bar rather than filling one, which is why it isn't a fourth argument up
-- there. Used by anything whose effect is calming rather than feeding — a DLC toy
-- out of a kid's meal.
--
-- Stress is not part of base ESX. Where a server has it, it is almost always
-- another esx_status entry, so we remove from it the same way we add to hunger; on
-- a server without one the event goes nowhere and using the item still works. The
-- public event is the supported hook for any other stress system — handle
-- `pickle_restaurants:relax` instead of editing this bridge.
function Relax(source, stress)
    stress = math.floor(tonumber(stress) or 0)
    if stress <= 0 then return end
    TriggerClientEvent("esx_status:remove", source, "stress", stress * 10000)
    TriggerEvent("pickle_restaurants:relax", source, stress)
end
