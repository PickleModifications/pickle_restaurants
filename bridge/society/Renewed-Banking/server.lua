-- bridge/society/Renewed-Banking — Renewed-Banking.
--
-- HIGHEST PRIORITY, and that is not a preference — it is a correctness rule.
-- Renewed-Banking SHIMS both qb-management and esx_society, so on a server running
-- it those two providers also answer. Talking to it through one of those narrower
-- doors would work right up until it didn't (its own account model is richer, and
-- job accounts it created are not always visible through the shim).
RegisterSocietyProvider({
    name     = "Renewed-Banking",
    resource = "Renewed-Banking",
    priority = 100,
    get  = function(job) return SocietyExport("Renewed-Banking", "getAccountMoney", job) end,
    add  = function(job, amt) return SocietyExport("Renewed-Banking", "addAccountMoney", job, amt) ~= nil end,
    take = function(job, amt) return SocietyExport("Renewed-Banking", "removeAccountMoney", job, amt) ~= nil end,
    -- The one provider that both CAN create a job account and needs telling to:
    -- it keeps organisation accounts in a cache of its own, so an account nobody
    -- created is not merely empty, it is absent.
    make = function(job, label)
        if SocietyExport("Renewed-Banking", "GetJobAccount", job) then return true end
        return SocietyExport("Renewed-Banking", "CreateJobAccount", { name = job, label = label or job }, 0) ~= nil
    end,
})
