-- bridge/society/qb-management — QBCore's boss-menu account store.
--
-- The classic QB society account: one balance per job, read and moved by name.
-- Note this is also the door Renewed-Banking shims, which is why that provider
-- outranks this one — see bridge/society/Renewed-Banking.
RegisterSocietyProvider({
    name     = "qb-management",
    resource = "qb-management",
    priority = 70,
    get  = function(job) return SocietyExport("qb-management", "GetAccount", job) end,
    add  = function(job, amt) return SocietyExport("qb-management", "AddMoney", job, amt) ~= nil end,
    take = function(job, amt) return SocietyExport("qb-management", "RemoveMoney", job, amt) ~= nil end,
})
