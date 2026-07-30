-- ─────────────────────────────────────────────────────────────────────────────
-- bridge/society (server) — WHERE A RESTAURANT'S MONEY LIVES.
--
-- A restaurant's balance is its JOB's society/business account, held by whatever
-- banking resource the server runs. We do not host it: there is no `balance` of ours
-- to drift from the boss menu the rest of the server already uses, and paying wages or
-- buying stock moves the same dollars a job's own banking UI shows.
--
-- PROBED BY PROVIDER, NOT BY FRAMEWORK. Money providers are not 1:1 with frameworks —
-- Renewed-Banking `provide`s both `qb-management` AND `esx_society`, so "ESX ⇒ addon
-- accounts" is simply wrong on a server running it. This file therefore asks WHICH
-- PROVIDER is present, in preference order, and every framework bridge shares the
-- answer. It also loads after them in the `bridge/**/server.lua` glob, so this is the
-- one definition of the society API that survives.
--
-- The API (nil-safe, and `jobName` is the account name — a restaurant with no job
-- assigned has no account, which is one more reason a job is REQUIRED):
--     SocietyAvailable()                    -- is there a real account store at all
--     SocietyProvider()                     -- its name, for the boot log / diagnostics
--     GetSocietyBalance(jobName)            -- number, 0 when unknown
--     AddSocietyMoney(jobName, amount)      -- true on success
--     RemoveSocietyMoney(jobName, amount)   -- true on success; false when short
--     EnsureSocietyAccount(jobName, label)  -- best-effort create, safe to repeat
-- ─────────────────────────────────────────────────────────────────────────────

local function started(res) return GetResourceState(res) == "started" end

-- Call an export that might not exist. Indexing a missing export RAISES (the same trap
-- the phone bridge documents), so the index happens INSIDE the protected call.
local function ex(res, name, ...)
    local args = table.pack(...)
    local ok, a, b = pcall(function()
        return exports[res][name](nil, table.unpack(args, 1, args.n))
    end)
    if not ok then return nil end
    return a, b
end

-- ─── providers ───────────────────────────────────────────────────────────────
-- Each provider answers the same four questions. `get` returning nil means "I don't
-- know this account", which is different from a balance of 0 and is what stops a
-- missing account reading as a broke restaurant.
local PROVIDERS = {
    -- Renewed-Banking: the richest of them (it also shims qb-management/esx_society, so
    -- it MUST be preferred over both or we would talk to it through a narrower door).
    {
        name = "Renewed-Banking",
        ok   = function() return started("Renewed-Banking") end,
        get  = function(job) return tonumber(ex("Renewed-Banking", "getAccountMoney", job)) end,
        add  = function(job, amt) return ex("Renewed-Banking", "addAccountMoney", job, amt) ~= nil end,
        take = function(job, amt) return ex("Renewed-Banking", "removeAccountMoney", job, amt) ~= nil end,
        make = function(job, label)
            if ex("Renewed-Banking", "GetJobAccount", job) then return true end
            return ex("Renewed-Banking", "CreateJobAccount", { name = job, label = label or job }, 0) ~= nil
        end,
    },
    -- qb-management / qb-banking (and anything providing their exports).
    {
        name = "qb-management",
        ok   = function() return started("qb-management") end,
        get  = function(job) return tonumber(ex("qb-management", "GetAccount", job)) end,
        add  = function(job, amt) return ex("qb-management", "AddMoney", job, amt) ~= nil end,
        take = function(job, amt) return ex("qb-management", "RemoveMoney", job, amt) ~= nil end,
    },
    {
        name = "qb-banking",
        ok   = function() return started("qb-banking") end,
        get  = function(job) return tonumber(ex("qb-banking", "GetAccountBalance", job)) end,
        add  = function(job, amt) return ex("qb-banking", "AddMoney", job, amt) ~= nil end,
        take = function(job, amt) return ex("qb-banking", "RemoveMoney", job, amt) ~= nil end,
    },
    -- ESX addon accounts. Event-shaped, not export-shaped: the callback fires INLINE, so
    -- reading it out of a closure is safe (no yield between the trigger and the read).
    {
        name = "esx_addonaccount",
        ok   = function() return started("esx_addonaccount") end,
        get  = function(job)
            local money
            TriggerEvent("esx_addonaccount:getSharedAccount", "society_" .. job, function(acc)
                if acc then money = tonumber(acc.money) end
            end)
            return money
        end,
        add = function(job, amt)
            local done = false
            TriggerEvent("esx_addonaccount:getSharedAccount", "society_" .. job, function(acc)
                if acc then acc.addMoney(amt); done = true end
            end)
            return done
        end,
        take = function(job, amt)
            local done = false
            TriggerEvent("esx_addonaccount:getSharedAccount", "society_" .. job, function(acc)
                if acc and (tonumber(acc.money) or 0) >= amt then acc.removeMoney(amt); done = true end
            end)
            return done
        end,
    },
}

-- WE ARE THE BANK ONLY WHEN THERE IS NO BANK. A frameworkless server has no society
-- system to hold anything, and the same reasoning that made this resource the job system
-- there applies to the money: one small table, used ONLY on that path, so the feature
-- works standalone without pretending to be a bank on a server that has one.
-- (The legacy `pickle_restaurants.balance` column is NOT this store — it is dead.)
local FALLBACK = {
    name = "pickle_restaurants (standalone)",
    ok   = function() return true end,
    get  = function(job) return SocietyLocalBalance and SocietyLocalBalance(job) or 0 end,
    add  = function(job, amt) return SocietyLocalAdjust and SocietyLocalAdjust(job, amt) or false end,
    take = function(job, amt) return SocietyLocalAdjust and SocietyLocalAdjust(job, -amt) or false end,
}

local resolved = nil

local function provider()
    if resolved then return resolved end
    for _, p in ipairs(PROVIDERS) do
        if p.ok() then resolved = p break end
    end
    resolved = resolved or FALLBACK
    return resolved
end

-- Re-probe when resources start/stop: a banking resource that boots after us must not
-- leave us writing to the standalone table for the rest of the session.
AddEventHandler("onResourceStart", function() resolved = nil end)
AddEventHandler("onResourceStop", function() resolved = nil end)

-- ─── the API ─────────────────────────────────────────────────────────────────

function SocietyProvider() return provider().name end
function SocietyAvailable() return provider() ~= FALLBACK end

function GetSocietyBalance(jobName)
    if not jobName or jobName == "" then return 0 end
    return math.floor(tonumber(provider().get(jobName)) or 0)
end

function AddSocietyMoney(jobName, amount)
    amount = math.floor(tonumber(amount) or 0)
    if not jobName or jobName == "" or amount <= 0 then return false end
    return provider().add(jobName, amount) and true or false
end

function RemoveSocietyMoney(jobName, amount)
    amount = math.floor(tonumber(amount) or 0)
    if not jobName or jobName == "" or amount <= 0 then return false end
    -- Check first even though most providers check for themselves: they disagree about
    -- whether an overdraw is refused or silently allowed, and a restaurant must never be
    -- able to spend money it doesn't have.
    if GetSocietyBalance(jobName) < amount then return false end
    return provider().take(jobName, amount) and true or false
end

function EnsureSocietyAccount(jobName, label)
    if not jobName or jobName == "" then return false end
    local p = provider()
    if not p.make then return true end -- provider auto-creates on first write
    return p.make(jobName, label) and true or false
end

CreateThread(function()
    Wait(2000)
    print(("[pickle_restaurants] restaurant funds are held by: %s"):format(SocietyProvider()))
end)
