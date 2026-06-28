-- =============================================
--  modules/main | server.lua
--  Re-syncs returning players. (Most core data lives in core/server.lua.)
-- =============================================

AddEventHandler("playerJoining", function()
    -- give the client a moment to register net events
    local src = source
    SetTimeout(2000, function()
        if RestaurantsReady then SyncToClient(src) end
    end)
end)
