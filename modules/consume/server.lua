-- =============================================
--  modules/consume | server.lua
--  EATING what leaves the kitchen. Two vessels, two experiences:
--
--    • RESTAURANT BAG — takeaway. Its build-stack metadata lists every food and
--      drink packed into it. Using the bag anywhere opens an ox_lib context menu
--      of its contents; picking one consumes THAT item, rewrites the bag's
--      metadata without it, and the bag itself disappears once it's empty.
--    • MEAL — eat-in. Only usable while SEATED at one of the restaurant's placed
--      seat anchors: it lays the tray out on the table in front of the customer
--      as an interactive view (modules/dining) where they click what to eat.
--
--  Both paths share this file's authority: the slot is re-read here on every
--  action (never trusted from the client), the layer is removed server-side, and
--  the item is only re-stamped/removed by the bridge afterwards.
--
--  ITEM USE plumbing. There is no single cross-framework "usable item" hook:
--    • ESX / QBCore register a callback per item name (RegisterUsableItem).
--    • ox_inventory owns item use itself and calls an EXPORT named in the item
--      definition — `server.export = 'pickle_restaurants.useItem'` (see
--      __INSTALL/items/ox_inventory.lua), which lands in the export below.
--  Item names are ADMIN-CONFIGURABLE (bag_item / meal_item), so registration is
--  re-run whenever the settings change; already-registered names are remembered
--  so re-registering is a no-op.
-- =============================================

local Registered = {}   -- [item] = true, names already handed to the framework

-- What kind of vessel an item is, by the CURRENT settings (never cached — an admin
-- can rename either item at any time).
local function vesselKind(item)
    if not item or item == "" then return nil end
    if item == BagItemName() then return "bag" end
    if item == GetSetting("meal_item", "meal") then return "meal" end
    return nil
end

-- The build stack recorded on one inventory slot (BuildInvMeta wrote it as
-- `stack`). Returns the layer list, or an empty list for a slot with no metadata
-- (a framework that strips it, or a hand-spawned item).
local function slotStack(meta)
    if type(meta) ~= "table" then return {} end
    local st = meta.stack
    return (type(st) == "table") and st or {}
end

-- The slot the player is acting on. `slot` comes from ox_inventory's use event; on
-- ESX/QB (no slot in the hook) we fall back to the first slot holding the item —
-- which is also the one the inventory UI used. Returns slot, metadata, count.
local function findSlot(src, item, slot)
    if not (Inventory and Inventory.GetItemSlots) then return nil end
    local slots = Inventory.GetItemSlots(src, item) or {}
    if slot then
        for _, s in ipairs(slots) do
            if s.slot == slot then return s.slot, s.metadata, s.count end
        end
    end
    local first = slots[1]
    if first then return first.slot, first.metadata, first.count end
end

-- The contents of a vessel slot, as a consumer-facing list. Index is the LAYER
-- index in the recorded stack — that's what the eat callback addresses, so the
-- list the player sees and the layer the server removes are the same thing even
-- when two identical foods sit in one bag.
local function describeContents(stack)
    local out = {}
    for i, l in ipairs(stack) do
        local d = LayerDisplay and LayerDisplay(l) or nil
        out[#out + 1] = {
            index = i,
            item  = l.item,
            label = (d and d.label) or (l.item and GetItemLabel(l.item)) or l.item,
            image = d and d.image or nil,
            drink = d and d.drink or nil,
        }
    end
    return out
end

-- Write a vessel's REMAINING contents back to its slot — or destroy the vessel
-- when nothing is left. Rewriting in place keeps the item where the player had it;
-- a framework with no slot-metadata support (bare ESX) can't rewrite, so the
-- vessel is consumed whole on the first bite rather than silently duplicating.
local function writeBack(src, item, slot, stack)
    if #stack == 0 then
        if Inventory.RemoveItemSlot then Inventory.RemoveItemSlot(src, item, 1, slot)
        else Inventory.RemoveItem(src, item, 1) end
        return true, true -- rewrote, emptied
    end
    local meta = BuildInvMeta(stack, item)
    if Inventory.SetItemMetadata and Inventory.SetItemMetadata(src, item, slot, meta) then
        return true, false
    end
    if Inventory.RemoveItemSlot then Inventory.RemoveItemSlot(src, item, 1, slot)
    else Inventory.RemoveItem(src, item, 1) end
    return false, true -- couldn't rewrite: the whole vessel went with the bite
end

-- ─── the use hook ────────────────────────────────────────────────────────────

-- Using a vessel. A BAG opens its contents menu wherever the player stands; a MEAL
-- is eat-in only — the client checks it's seated at a restaurant and refuses (with
-- a notification) otherwise, then lays the tray out in front of them.
local function useVessel(src, item, slot)
    local kind = vesselKind(item)
    if not kind then return end
    local s, meta = findSlot(src, item, slot)
    if not s then return end
    local stack = slotStack(meta)
    if #stack == 0 then
        -- a vessel with no readable contents (a framework that strips slot
        -- metadata, or an item spawned by hand): nothing to choose from
        return ShowNotification(src, _L("consume_empty"))
    end
    TriggerClientEvent("pickle_restaurants:consume:open", src, {
        kind = kind, item = item, slot = s, contents = describeContents(stack),
    })
end

-- Consume ONE thing out of a vessel. Everything is re-validated here: the slot
-- still holds the item, the layer still exists, and the layer index still points at
-- what the player picked. Returns what was eaten so the client can play the right
-- animation and name it.
lib.callback.register("pickle_restaurants:consume:eat", function(src, d)
    local item = d and d.item
    if not vesselKind(item) then return { ok = false } end
    local slot, meta = findSlot(src, item, tonumber(d and d.slot))
    if not slot then return { ok = false } end
    local stack = slotStack(meta)
    -- A bag eats ONE layer; a meal eats one PILE, which may be several layers that
    -- were arranged together (a burger's bun/patty). Both arrive as indices into the
    -- recorded stack, removed high-to-low so earlier removals can't shift later ones.
    local idxs = {}
    if type(d.indices) == "table" then
        for _, v in ipairs(d.indices) do
            local n = tonumber(v)
            if n and stack[n] then idxs[#idxs + 1] = n end
        end
    elseif tonumber(d and d.index) then
        local n = tonumber(d.index)
        if stack[n] then idxs[1] = n end
    end
    if #idxs == 0 then return { ok = false, error = _L("consume_gone") } end
    table.sort(idxs, function(a, b) return a > b end)
    local layer = stack[idxs[#idxs]] -- the lowest index names the mouthful
    local disp = LayerDisplay and LayerDisplay(layer) or nil
    -- What THIS food does when eaten + which clip it's eaten with, authored on the
    -- food itself and filled in from the global `consume` fallback. Resolved BEFORE
    -- the layer is dropped, since it reads that layer's metadata.
    local spec = ConsumeSpecFor(layer.item, layer.stack)

    for _, n in ipairs(idxs) do table.remove(stack, n) end
    local _, emptied = writeBack(src, item, slot, stack)
    Nourish(src, spec.hunger, spec.thirst)

    return { ok = true, emptied = emptied,
             label = (disp and disp.label) or GetItemLabel(layer.item),
             drink = disp and disp.drink or nil,
             -- the full clip spec (dict/clip/prop/ms), so the client needs no
             -- catalogue of its own and an admin's retune applies immediately
             anim = spec.anim,
             -- what's left, so an open menu can refresh itself without a round trip
             contents = describeContents(stack) }
end)

-- ─── registration ────────────────────────────────────────────────────────────

-- Hand one item name to the framework's usable-item hook (ESX/QB). Harmless when
-- ox_inventory is in use — ox bypasses those hooks and calls our export instead.
local function register(item)
    if not item or item == "" or Registered[item] then return end
    Registered[item] = true
    if RegisterUsableItem then
        RegisterUsableItem(item, function(source) useVessel(source, item, nil) end)
    end
end

function RegisterConsumables()
    register(BagItemName())
    register(GetSetting("meal_item", "meal"))
end

-- ox_inventory's per-item server export. ox calls it twice around a use
-- ("usingItem" before, "usedItem" after); we act on the FIRST and cancel ox's own
-- consumption by returning false, because the vessel is only emptied once the
-- player actually picks something out of it.
exports("useItem", function(event, item, inventory, slot)
    if event ~= "usingItem" then return end
    local src = tonumber(inventory) or inventory
    useVessel(src, item and item.name or item, tonumber(slot))
    return false -- never let ox eat the vessel itself
end)

CreateThread(function()
    while not RestaurantsReady do Wait(250) end
    RegisterConsumables()
end)

-- An admin renaming bag_item / meal_item re-registers the new names (the old ones
-- stay registered and harmlessly inert).
AddEventHandler("pickle_restaurants:settingChanged", function(key)
    if RestaurantsReady and (key == "bag_item" or key == "meal_item") then RegisterConsumables() end
end)
