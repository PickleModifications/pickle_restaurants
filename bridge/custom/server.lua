-- Standalone bridge. Only runs when no supported framework is present.
-- Provides the same global API the modules rely on so the resource works
-- (and never errors) on a bare server. Inventory uses ox_inventory when
-- available; money is a lightweight oxmysql-backed cash store.
if GetResourceState('es_extended') == 'started' then return end
if GetResourceState('qb-core') == 'started' then return end

debugPrint("Loading standalone bridge (no ESX/QB detected).")

local Accounts = {} -- identifier -> { cash = number }

local function IdentifierOf(source)
    return GetPlayerIdentifierByType(source, 'license') or ("src:" .. tostring(source))
end

MySQL.ready(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `pickle_restaurant_accounts` (
            `identifier` VARCHAR(80) NOT NULL,
            `cash`       BIGINT      NOT NULL DEFAULT 5000,
            PRIMARY KEY (`identifier`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
end)

local function LoadAccount(identifier)
    if Accounts[identifier] then return Accounts[identifier] end
    local row = MySQL.single.await("SELECT cash FROM pickle_restaurant_accounts WHERE identifier = ?", { identifier })
    if not row then
        MySQL.insert.await("INSERT INTO pickle_restaurant_accounts (identifier, cash) VALUES (?, ?)", { identifier, 5000 })
        Accounts[identifier] = { cash = 5000 }
    else
        Accounts[identifier] = { cash = row.cash }
    end
    return Accounts[identifier]
end

function ShowNotification(target, text)
    TriggerClientEvent(GetCurrentResourceName() .. ":showNotification", target, text)
end

function GetIdentifier(source)
    if not source or source == 0 then return end
    return IdentifierOf(source)
end

function GetSourceFromIdentifier(identifier)
    for _, src in ipairs(GetPlayers()) do
        if IdentifierOf(tonumber(src)) == identifier then return tonumber(src) end
    end
    return nil
end

function GetPlayerCharacterName(source)
    return GetPlayerName(source) or "Unknown Name"
end

function GetCharacterNameByIdentifier(identifier)
    local src = GetSourceFromIdentifier(identifier)
    if src then return GetPlayerName(src) end
    return identifier
end

function CanAccessGroup(_, _) return true end

function CheckPermission(source, permission)
    if not permission or permission.ignorePermissions then return true end
    return IsPlayerAceAllowed(source, "command")
end

function IsPlayerAdmin(source)
    if IsPlayerAceAllowed(source, "command") then return true end
    for i = 1, #Config.AdminGroups do
        if IsPlayerAceAllowed(source, "group." .. Config.AdminGroups[i]) then return true end
    end
    return false
end

function GetMoney(source, currency)
    local id = GetIdentifier(source); if not id then return 0 end
    local acc = LoadAccount(id)
    return acc.cash or 0
end

function AddMoney(source, count, _)
    local id = GetIdentifier(source); if not id then return end
    local acc = LoadAccount(id)
    acc.cash = (acc.cash or 0) + RoundMoney(count)
    MySQL.update("UPDATE pickle_restaurant_accounts SET cash = ? WHERE identifier = ?", { acc.cash, id })
    TriggerClientEvent("pickle_restaurants:updateMoney", source, acc.cash)
end

function RemoveMoney(source, count, _)
    local id = GetIdentifier(source); if not id then return false end
    local acc = LoadAccount(id)
    count = RoundMoney(count)
    if (acc.cash or 0) < count then return false end
    acc.cash = acc.cash - count
    MySQL.update("UPDATE pickle_restaurant_accounts SET cash = ? WHERE identifier = ?", { acc.cash, id })
    TriggerClientEvent("pickle_restaurants:updateMoney", source, acc.cash)
    return true
end

function AddSocietyMoney(_, _) end -- restaurant balance is tracked in our own tables

-- Inventory ───────────────────────────────────────────────────────────────
CreateThread(function()
    Wait(100)
    if InitializeInventory then return InitializeInventory() end
    Inventory = {}
    Inventory.Items = {}
    Inventory.Ready = false

    local hasOx = GetResourceState("ox_inventory") == "started"

    Inventory.GetInventory = function(source)
        if hasOx then
            local items = {}
            for _, item in pairs(exports.ox_inventory:GetInventoryItems(source) or {}) do
                items[#items + 1] = { name = item.name, label = item.label, count = item.count, weight = item.weight }
            end
            return items
        end
        return {}
    end

    Inventory.GetItemCount = function(source, name)
        if hasOx then return exports.ox_inventory:GetItemCount(source, name) or 0 end
        return 0
    end

    Inventory.CanCarryItem = function(source, name, count)
        if hasOx then return exports.ox_inventory:CanCarryItem(source, name, count) end
        return true
    end

    Inventory.AddItem = function(source, name, count, metadata)
        if hasOx then exports.ox_inventory:AddItem(source, name, count, metadata) end
        TriggerClientEvent("pickle_restaurants:updateInventory", source, Inventory.GetInventory(source))
    end

    Inventory.RemoveItem = function(source, name, count)
        if hasOx then exports.ox_inventory:RemoveItem(source, name, count) end
        TriggerClientEvent("pickle_restaurants:updateInventory", source, Inventory.GetInventory(source))
    end

    Inventory.HasWeapon = function(source, name) return Inventory.GetItemCount(source, name) > 0 end
    Inventory.AddWeapon = function(source, name, count, metadata) Inventory.AddItem(source, name, count, metadata) end
    Inventory.RemoveWeapon = function(source, name, count) Inventory.RemoveItem(source, name, count) end

    -- Rebuild the catalogue from the live ox registry. Called on boot and again
    -- whenever items may have changed (see core's requestSync refresh), so we
    -- never serve a stale startup snapshot.
    Inventory.RefreshItems = function()
        if not hasOx then return end
        local items = {}
        for item, data in pairs(exports.ox_inventory:Items() or {}) do
            items[item] = { label = data.label, image = InvImageUrl(InventoryImageBase(), item, data.image) }
        end
        Inventory.Items = items
    end

    -- Live existence check straight from ox, so an item registered after this
    -- resource started is still recognised.
    Inventory.ItemExists = function(name)
        if not name or name == "" then return false end
        if hasOx then return exports.ox_inventory:Items(name) ~= nil end
        return Inventory.Items[name] ~= nil
    end

    -- Per-slot access (ox only) so item variations survive the inventory
    -- round-trip — see the qb bridge for the shape.
    if hasOx then
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
    end

    Inventory.RefreshItems()
    Inventory.Ready = true
end)
