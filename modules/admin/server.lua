-- =============================================
--  modules/admin | server.lua
--  Admin command + callbacks: create/delete restaurants, assign owner,
--  edit global settings & cookable recipes. All gated by IsPlayerAdmin.
-- =============================================

local function buildAdminData()
    local data = {
        restaurants = {},
        theme       = GetSetting("app_theme", nil), -- App-level: skins /restaurants itself
        phoneTheme  = GetSetting("phone_theme", nil), -- ONE global skin for the companion phone app
        settings    = SettingsCache,
        -- The EFFECTIVE buy-in costs (the `ingredient_costs` setting with each
        -- installed pack's defaults underneath it). `settings.ingredient_costs` is
        -- the AUTHORED map alone, so a panel seeded from that alone showed 0 for
        -- everything a pack prices — and saving that 0 back would have written a
        -- free toy over the pack's price. The editors display from this and write to
        -- the authored map, so only a cost someone actually typed is ever stored.
        ingredientCosts = IngredientCosts(),
        -- Each installed pack's DEFAULT prices on their own. The cost editor needs
        -- these separately from the effective map: it lists a row for every packaged
        -- item (so a pack's content is priceable at all) but only STORES a row that
        -- differs from the pack's default — otherwise merely touching that screen
        -- would author every default and freeze it against future pack updates.
        dlcCosts = DlcIngredientCosts and DlcIngredientCosts() or {},
        -- The three authored creation kinds, each flagged valid/missing + per-entry
        -- annotations (defaultPrice, tap, duplicate_input, *_installed). The NUI
        -- strips the annotations before saving the array back.
        foods       = AnnotateFoods(),
        tools       = AnnotateTools(),
        ingredients = AnnotateIngredients(),
        -- The shipped default menu, verbatim — feeds the NUI's "Import Defaults"
        -- dialog (restore a deleted default / reset an edited one, no restart).
        defaults    = { foods = DEFAULT_FOODS, tools = DEFAULT_TOOLS, ingredients = DEFAULT_INGREDIENTS },
        -- READ-ONLY, not a setting: the embedded takeout-box quad (core/shared.lua).
        -- The "Inside the box" cropper locks its frame to this aspect so a crop lands
        -- in the box exactly as it was dragged. Nothing in the panel writes it back.
        boxQuad     = Config.BoxQuad,
        items       = BuildItemList(),     -- catalogue for item-pickers
        groups      = CollectGroups(),     -- every group name in use (UI suggestions)
        players     = {},
        -- Brand-texture aspects for the crop UI, from the ONE render-target registry
        -- (core/shared.lua) so the panel never hardcodes a resolution that drifts.
        renderTargets = BrandRenderTargets(),
        -- Installed DLC packs (modules/dlc), READ-ONLY: what each one is and what it
        -- contributes. Their entries also appear in the Menu tab's lists carrying a
        -- `dlc` mark, which is what renders them uneditable there — this is the
        -- inventory of packs, Settings → DLC.
        dlcs        = DlcList and DlcList() or {},
    }
    for _, r in pairs(RestaurantCache) do
        local props = {}
        for _, p in pairs(PropCache) do
            if p.restaurant_id == r.id then props[#props + 1] = PropSummary(p) end
        end
        data.restaurants[#data.restaurants + 1] = {
            id           = r.id,
            name         = r.name,
            label        = r.label,
            owner        = r.owner_identifier,
            balance      = r.balance,
            hasCounter   = r.counter ~= nil,
            hasShell     = (r.metadata and r.metadata.shell) ~= nil,
            hasNpcSpawn  = (r.metadata and r.metadata.npc_spawn) ~= nil,
            groups       = r.groups or {},
            props        = props,
            propCount    = #props,
            brand_image  = r.metadata and r.metadata.brand_image or nil,
            brand_images = r.metadata and r.metadata.brand_images or nil,
            phone_image  = r.metadata and r.metadata.phone_image or nil,
            theme        = r.metadata and r.metadata.theme or nil,
        }
    end
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        data.players[#data.players + 1] = { id = src, name = GetPlayerCharacterName(src) }
    end
    return data
end

local function openAdmin(src)
    if not IsPlayerAdmin(src) then
        return ShowNotification(src, _L("no_permission"))
    end
    TriggerClientEvent("pickle_restaurants:openAdmin", src, buildAdminData())
end

lib.callback.register("pickle_restaurants:admin:getData", function(src)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local d = buildAdminData()
    d.ok = true
    return d
end)

CreateThread(function()
    while not RestaurantsReady do Wait(200) end
    RegisterCommand(GetSetting("admin_command", "restaurants"), function(src)
        if src == 0 then return print("This command must be run in-game.") end
        openAdmin(src)
    end, false)
end)

-- ─── create / delete ─────────────────────────────────────────────────────────

local function reloadRestaurant(id)
    local row = MySQL.single.await("SELECT * FROM pickle_restaurants WHERE id = ?", { id })
    if not row then RestaurantCache[id] = nil return end
    row.blip     = (type(row.blip) == "string") and json.decode(row.blip) or row.blip
    row.counter  = (type(row.counter) == "string") and json.decode(row.counter) or row.counter
    row.roles    = (type(row.roles) == "string") and json.decode(row.roles) or row.roles
    row.groups   = (type(row.groups) == "string") and json.decode(row.groups) or row.groups
    row.metadata = (type(row.metadata) == "string") and json.decode(row.metadata) or (row.metadata or {})
    RestaurantCache[id] = row
end

lib.callback.register("pickle_restaurants:admin:create", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not d or not d.name or d.name == "" then return { ok = false, error = _L("admin_name_required") } end
    local id = MySQL.insert.await(
        "INSERT INTO pickle_restaurants (name, label, blip, balance) VALUES (?, ?, ?, ?)",
        { d.name, d.label or d.name, json.encode(GetSetting("blip", {})), GetSetting("starting_balance", 0) })
    if not id then return { ok = false } end
    reloadRestaurant(id)
    SyncToClient(-1)
    return { ok = true, id = id }
end)

lib.callback.register("pickle_restaurants:admin:delete", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local id = tonumber(d.id); if not id then return { ok = false } end
    -- collect props so clients can despawn them
    local propIds = {}
    for pid, p in pairs(PropCache) do if p.restaurant_id == id then propIds[#propIds + 1] = pid end end

    -- REFUND EVERY IN-FLIGHT TICKET FIRST. Deleting a restaurant used to drop its
    -- open orders straight out of the DB, so anyone who had pre-paid at a kiosk,
    -- register or from the phone simply lost their money with no ticket left to
    -- cancel. Go through the ONE shared refund path (core/server.lua): it's
    -- idempotent (the `refunded` flag means a ticket a cashier is cancelling at the
    -- same moment can't be paid twice), refunds the account that was charged, and
    -- queues the payout for anyone offline. This MUST run before the DELETEs below
    -- — the balance/ledger reversal it does needs the rows to still exist, and the
    -- pending-refund rows it queues live in their own table, which survives.
    local refundedCount = 0
    for _, o in pairs(OrderCache[id] or {}) do
        if o.status == "open" then
            local ok = pcall(RefundOrder, id, o, _L("refund_reason_closed"))
            if ok then refundedCount = refundedCount + 1
            else
                print(("[pickle_restaurants] REFUND FAILED deleting restaurant %s, ticket #%s (order %s)")
                    :format(tostring(id), tostring(o.ticket), tostring(o.id)))
            end
        end
    end
    if refundedCount > 0 then
        print(("[pickle_restaurants] refunded %d open ticket(s) while deleting restaurant %d"):format(refundedCount, id))
    end

    MySQL.update.await("DELETE FROM pickle_restaurants WHERE id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_props WHERE restaurant_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_employees WHERE restaurant_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_menu WHERE restaurant_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_stock WHERE restaurant_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_ledger WHERE restaurant_id = ?", { id })
    MySQL.update.await("DELETE FROM pickle_restaurant_orders WHERE restaurant_id = ?", { id })
    RestaurantCache[id] = nil
    EmployeeCache[id] = nil
    StockCache[id] = nil
    ClearOrders(id) -- drops OrderCache/NextTicket + bumps the rev so a stale register can't re-apply
    for _, pid in ipairs(propIds) do
        PropCache[pid] = nil
        TriggerClientEvent("pickle_restaurants:propRemoved", -1, pid)
        -- release state other modules key on this prop (cooking items, seat
        -- occupancy, station claims) — same notice removeProp gives
        TriggerEvent("pickle_restaurants:propDeleted", pid)
    end
    SyncToClient(-1)
    return { ok = true }
end)

lib.callback.register("pickle_restaurants:admin:setOwner", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local id = tonumber(d.id); if not GetRestaurant(id) then return { ok = false } end
    local identifier = nil
    if d.target then
        identifier = GetIdentifier(tonumber(d.target))
        if not identifier then return { ok = false, error = _L("admin_player_not_found") } end
    end
    MySQL.update.await("UPDATE pickle_restaurants SET owner_identifier = ? WHERE id = ?", { identifier, id })
    RestaurantCache[id].owner_identifier = identifier
    return { ok = true, owner = identifier }
end)

-- Recipe groups carried by a restaurant (what it may cook & sell). Groups are
-- free-form names; content with no group is available to every restaurant.
lib.callback.register("pickle_restaurants:admin:setGroups", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local id = tonumber(d.id); if not GetRestaurant(id) then return { ok = false } end
    local groups, seen = {}, {}
    for _, g in ipairs(type(d.groups) == "table" and d.groups or {}) do
        g = tostring(g):gsub("^%s+", ""):gsub("%s+$", "")
        if g ~= "" and not seen[g] then
            seen[g] = true
            groups[#groups + 1] = g
        end
    end
    MySQL.update.await("UPDATE pickle_restaurants SET `groups` = ? WHERE id = ?",
        { #groups > 0 and json.encode(groups) or nil, id })
    RestaurantCache[id].groups = #groups > 0 and groups or nil
    -- Groups decide what this restaurant may cook and sell, so the world is now
    -- stale: the synced payload is filtered per restaurant by group, and without
    -- this the menu boards, kiosk, register catalogue and cooking bar all keep
    -- offering the old set until something else happens to trigger a sync.
    SyncToClient(-1)
    ShowNotification(src, _L("admin_settings_saved"))
    return { ok = true, groups = groups }
end)

-- Branding: same per-texture URL + crop config as the boss panel, but admin-gated so
-- a server admin can brand any restaurant. Shares SetRestaurantBrand (management).
lib.callback.register("pickle_restaurants:admin:setBrandImage", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local res = SetRestaurantBrand(tonumber(d.id), d.key, d.url, d.crop)
    if res and res.ok then ShowNotification(src, _L("branding_saved")) end
    return res
end)

-- Custom per-item image: MERGE one item's { url, crop } into the global `item_images`
-- setting (a blank url clears it). Targeted so an edit in the Food & Drinks tab can't
-- clobber one made in the Ingredients tab. The override wins over the inventory image
-- in GetItemImage, so a re-sync pushes it to every world/board surface at once.
lib.callback.register("pickle_restaurants:admin:setItemImage", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not SetItemImageOverride(d.item, d.url, d.crop) then return { ok = false } end
    SyncToClient(-1)
    ShowNotification(src, _L("admin_settings_saved"))
    return { ok = true }
end)

-- Theme: same seed config as the boss panel, admin-gated. Shares
-- SetRestaurantTheme (management).
lib.callback.register("pickle_restaurants:admin:setTheme", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local res = SetRestaurantTheme(tonumber(d.id), d.theme)
    if res and res.ok then ShowNotification(src, _L("theme_saved")) end
    return res
end)

-- Rename: same identity write as the boss panel, admin-gated so a server admin can
-- rename any restaurant (the owner renames their own via management:setName).
-- Shares SetRestaurantName (management), which re-derives the internal codename
-- from the label exactly like admin:create does.
lib.callback.register("pickle_restaurants:admin:setName", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local res = SetRestaurantName(tonumber(d.id), d.label)
    if res and res.ok then ShowNotification(src, _L("mgmt_name_saved", res.label)) end
    return res
end)

-- App-level theme: skins the /restaurants admin panel itself, stored as the
-- `app_theme` setting (not per-restaurant). Client-render-only — no world sync.
lib.callback.register("pickle_restaurants:admin:setAppTheme", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    SetSetting("app_theme", SanitizeTheme(d.theme))
    ShowNotification(src, _L("theme_saved"))
    return { ok = true }
end)

-- Phone-app theme: ONE global skin for the companion phone app, stored as the
-- `phone_theme` setting (not per-restaurant — the phone keeps a single consistent
-- look). Pushed live to every open phone so the change previews without reopening.
lib.callback.register("pickle_restaurants:admin:setPhoneTheme", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    local theme = SanitizeTheme(d.theme)
    SetSetting("phone_theme", theme)
    TriggerClientEvent("pickle_restaurants:phone:pushTheme", -1, theme)
    ShowNotification(src, _L("theme_saved"))
    return { ok = true }
end)

-- ─── settings ────────────────────────────────────────────────────────────────

-- The authored menu arrays (foods/tools/ingredients) are settings like any other,
-- but each is sanitized on the way in (the NUI is untrusted) and triggers a
-- derivation rebuild so the runtime caches (RecipeCache, derived assembly/drinks/
-- crafts/finishes/condiments/baking, prep models) reflect the edit immediately.
local MENU_SANITIZERS = {
    foods       = SanitizeFoods,
    tools       = SanitizeTools,
    ingredients = SanitizeIngredients,
    -- Custom per-item images (item → { url, crop }). Rebuild picks up the new
    -- ItemImageCache so a saved image propagates to every surface via GetItemImage.
    item_images = SanitizeItemImages,
    -- The eat/drink animation catalogue foods pick from (`consume.anim`): clips are
    -- handed straight to the client, so a malformed entry is dropped here.
    consume_anims = SanitizeConsumeAnims,
}

-- Apply a settings write, routing the three authored menu keys through their
-- sanitizer. Returns true if a menu key was written (caller rebuilds derived).
local function applySetting(key, value)
    local san = MENU_SANITIZERS[key]
    if san then SetSetting(key, san(value)); return true end
    SetSetting(key, value)
    return false
end

lib.callback.register("pickle_restaurants:admin:saveSetting", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if not d.key then return { ok = false } end
    if applySetting(d.key, d.value) then RebuildDerived() end
    SyncToClient(-1) -- foods/tools/blip may have changed
    ShowNotification(src, _L("admin_settings_saved"))
    return { ok = true }
end)

-- Batch save (the debounced auto-save writes a whole settings group at once): one DB
-- write per key, ONE sync, ONE "saved" notification — so an auto-save of a multi-field
-- group doesn't spam a notification per field.
lib.callback.register("pickle_restaurants:admin:saveSettings", function(src, d)
    if not IsPlayerAdmin(src) then return { ok = false } end
    if type(d.settings) ~= "table" then return { ok = false } end
    local n, rebuild = 0, false
    for k, v in pairs(d.settings) do
        if applySetting(k, v) then rebuild = true end
        n = n + 1
    end
    if n == 0 then return { ok = false } end
    if rebuild then RebuildDerived() end
    SyncToClient(-1)
    ShowNotification(src, _L("admin_settings_saved"))
    return { ok = true }
end)

-- ─── menu ────────────────────────────────────────────────────────────────────

-- Reset the whole authored menu (foods + tools + ingredients) to the shipped
-- defaults (Settings → General). Rebuilds derived caches + syncs.
lib.callback.register("pickle_restaurants:admin:resetRecipes", function(src)
    if not IsPlayerAdmin(src) then return { ok = false } end
    ResetMenuToDefault()
    SyncToClient(-1)
    ShowNotification(src, _L("admin_recipes_reset"))
    return { ok = true }
end)
