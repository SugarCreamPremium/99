-- ============================================
-- Module_Pyromaniac.lua
-- Pyromaniac class: finish the level-up quest
--   EnemyKillsWithFire (the Flamethrower must land the killing shot).
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/main/Module_Pyromaniac.lua
--
-- Globals read at load time (set by MainScript before the module is loaded):
--   LocalPlayer, CLASS_QUESTS, classStatCache, __WSM_currentClass
-- Globals read lazily (defined later by MainScript):
--   Event, ownerId, Client, Config, findNightMonsters, checkAnyCultistSpawned, ensureFloating, getToolCooldown,
--   zeroEnemyHealth, finalGateBasePos, bestAxeCombat, updateStatus, forceTeleportLobby, HOVER_HEIGHT
--
-- Kill recipe (confirmed in game, see the plan):
--   zero the monster's HP -> wait 1s -> ONE flamethrower shot = instant kill that counts for the quest, 1 fuel.
--   A kill by the burn (BurnUntil) or by the axe does NOT count, so the last hit must always be the gun's direct damage.
--   Fallback when the zero did not work: wait the burn out, bring the HP down with the axe to <= the flame damage
--   (never to 0), then shoot once.
--
-- Outside a Stronghold : hunt the nearest monster (HP <= 100) with the recipe above.
-- Out of fuel          : when no fuel item can be found, fly rings around the Stronghold to stream in more of the map,
--                        refuel as soon as a Fuel Canister / Oil Barrel shows up, then go back to hunting.
-- Stronghold round     : Module_Stronghold moves the player and calls M.strongholdHit(cultists, hrp); this module
--                        only refuels. M.specialWeaponOnly() makes Module_Stronghold skip the axe.
-- Quest complete       : leave to the Lobby (outside a round right away, inside a round after it ends).
-- Fuel                 : Fuel Canister (+30, any level) and Oil Barrel (+30, only when the tank is nearly empty)
--                        are pulled next to the player and consumed (same moves as Auto-Eat in MainScript).
--                        An item the server refuses is parked and retried later.
--
-- Config (all optional)
--   Config.PyromaniacOutsideFarm   = true    -- hunt outside between Strongholds
--   Config.PyromaniacHoverHeight   = 10      -- studs above the target (default _G.HOVER_HEIGHT or 10)
--   Config.PyromaniacHitMode       = "remote" -- "remote" (one ToolDamageObject tick) or "client" (the game's ActivateTool)
--   Config.PyromaniacRefuelBelow   = 25      -- refuel when the tank is at or below this
--   Config.PyromaniacBarrelBelow   = 10      -- Oil Barrel is only tried at or below this fuel level
--   Config.PyromaniacRetryDelay    = 120     -- seconds before a refused fuel item is tried again (times fail count)
--   Config.PyromaniacMaxFuelFails  = 3       -- failures before a fuel item is given up for good
--   Config.PyromaniacSkipNames     = {}      -- extra name fragments to never hunt
--   Config.PyromaniacSearchRadius  = 500     -- radius of the fuel search flight (rings of 0.5x / 1x / 1.5x)
-- ============================================

local M = {}
local Log = _G.WSM_Log or {
    dev = function() end,
    err = function(reason, nextStep)
        warn("Error : " .. tostring(reason) .. " / " .. tostring(nextStep))
    end,
}

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LP = _G.LocalPlayer or Players.LocalPlayer
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}

local CLASS_NAME = "Pyromaniac"
local KILLS_KEY = "EnemyKillsWithFire"

M.isPyromaniac = (_G.__WSM_currentClass or "Unknown") == CLASS_NAME

local LOBBY_PLACE_ID = 79546208627805
local TARGET_DEADLINE = 25       -- seconds per target before giving up on it
local ZERO_SETTLE = 1            -- seconds between zeroing the HP and the shot
local EQUIP_SETTLE = 1           -- the first shot after an equip can be refused: wait this long after RequestEquipItem
local DEATH_WAIT = 1.5           -- seconds to wait for the model to disappear after a shot
local EXTRA_ZERO_ROUNDS = 2      -- extra zero + shot rounds before the axe fallback
local SHOT_RETRY_WAIT = 0.5      -- a refused shot is retried once after this delay
local BURN_FALLBACK = 4.3        -- burn length when BurnUntil cannot be read (measured ~4.1s)
local STALL_KILLS = 15           -- kills without quest progress before a switch / error
local BLACKLIST_SECONDS = 60     -- a target that could not be killed is skipped for this long
local CLIENT_BURST = 0.3         -- seconds the game's ActivateTool is held in "client" mode
local STRONGHOLD_REFUEL_BUDGET = 4 -- max seconds a refuel may block the Stronghold fight loop

-- ============================================
-- Helpers
-- ============================================
local function cfg(key, default)
    local c = _G.Config
    if type(c) == "table" and c[key] ~= nil then return c[key] end
    return default
end

local function status(text)
    local fn = _G.updateStatus
    if fn then pcall(fn, text) end
end

local function isAlive()
    local c = LP.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    return h ~= nil and h.Health > 0
end

local function getHRP()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function rootOf(model)
    return model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart")
end

local function wantsUpgrade()
    local list = cfg("UpgradeClass", nil)
    if type(list) ~= "table" then return false end
    for _, name in ipairs(list) do
        if name == CLASS_NAME then return true end
    end
    return false
end

local function hoverHeight()
    return cfg("PyromaniacHoverHeight", _G.HOVER_HEIGHT or 10)
end

-- ============================================
-- Quest checks (stats come from the ClassStatUpdated cache in MainScript)
-- ============================================
local function currentLevel()
    return LP:GetAttribute("ClassLevel") or 1
end

local function goal()
    local reqs = CQ[CLASS_NAME] and CQ[CLASS_NAME][currentLevel() + 1]
    return reqs and reqs[KILLS_KEY]
end

local function have()
    local s = CSC[CLASS_NAME]
    local v = s and s[KILLS_KEY]
    return type(v) == "number" and v or 0
end

function M.isAllQuestDone()
    local g = goal()
    return not g or have() >= g
end

-- true while the main loop is running
M.active = false

local function fuelNow()
    local v = LP:GetAttribute("FlamethrowerFuel")
    return type(v) == "number" and v or 0
end

-- ============================================
-- Tools
-- ============================================
local function heldItem()
    local c = LP.Character
    local th = c and c:FindFirstChild("ToolHandle")
    local oi = th and th:FindFirstChild("OriginalItem")
    return oi and oi.Value or nil
end

local lastEquipAt = 0

-- RequestEquipItem rebuilds ToolHandle every time, so only call it when the item is not already held
local function equip(item)
    if not item or not item.Parent then return false end
    if heldItem() == item then return true end
    local client = _G.Client
    if not (client and client.InventoryHandler) then return false end
    lastEquipAt = tick()
    pcall(function() client.InventoryHandler.RequestEquipItem(item) end)
    for _ = 1, 15 do
        if heldItem() == item then return true end
        task.wait(0.1)
    end
    return false
end

local function getFlame()
    local inv = LP:FindFirstChild("Inventory")
    if not inv then return nil end
    local f = inv:FindFirstChild("Flamethrower")
    if f then return f end
    for _, tool in ipairs(inv:GetChildren()) do
        if tool:GetAttribute("ToolName") == "Flamethrower" then return tool end
    end
    return nil
end

-- the strongest axe that is not broken (MainScript's combat axe first)
local function getMelee()
    local axe = _G.bestAxeCombat
    if axe and axe.Parent then
        local dur = axe:GetAttribute("Durability")
        if dur == nil or dur > 0 then return axe end
    end
    local inv = LP:FindFirstChild("Inventory")
    if not inv then return nil end
    local best, bestDmg = nil, -1
    for _, tool in ipairs(inv:GetChildren()) do
        if tool:GetAttribute("ToolName") == "GenericAxe" then
            local dur = tool:GetAttribute("Durability")
            if dur == nil or dur > 0 then
                local dmg = tool:GetAttribute("WeaponDamage") or 0
                if dmg > bestDmg then best, bestDmg = tool, dmg end
            end
        end
    end
    return best
end

-- hold the Flamethrower and give the server a moment before the first shot
local function equipFlame(flame)
    if not equip(flame) then return false end
    local remaining = EQUIP_SETTLE - (tick() - lastEquipAt)
    if remaining > 0 then task.wait(remaining) end
    return true
end

local function cooldownOf(tool)
    local fn = _G.getToolCooldown
    local cd = 0.5
    if fn then
        local ok, v = pcall(fn, tool)
        if ok and type(v) == "number" then cd = v end
    end
    return math.max(cd, 0.1)
end

-- ============================================
-- Stronghold detection (same rules as the other modules)
-- ============================================
local function strongholdOpenTime()
    for _, sh in ipairs(CollectionService:GetTagged("Stronghold")) do
        if sh.Name ~= "AlienMothership" then
            local f = sh:FindFirstChild("Functional")
            local openTime = f and f:GetAttribute("OpenTime")
            if openTime then return openTime end
        end
    end
    return nil
end

-- a Stronghold round is running or about to run
local function strongholdOpen()
    local openTime = strongholdOpenTime()
    return openTime ~= nil and workspace:GetServerTimeNow() >= openTime
end

-- Module_Stronghold sets this from the start of a round until its diamonds are collected
local function roundActive()
    return _G.WSM_StrongholdRound == true
end

local function anyCultist()
    local fn = _G.checkAnyCultistSpawned
    return fn and fn() or false
end

-- ============================================
-- Movement
-- ============================================
local function clearFloating()
    local hrp = getHRP()
    if not hrp then return end
    for _, name in ipairs({ "FloatAlignPosition", "FloatAlignOrientation", "FloatAttachment" }) do
        local o = hrp:FindFirstChild(name)
        if o then pcall(function() o:Destroy() end) end
    end
end

-- keep the player floating at pos, facing down (warp when there is no float yet, then move the constraint)
local function hoverAt(pos)
    local hrp = getHRP()
    if not hrp then return end
    local cf = CFrame.new(pos) * CFrame.Angles(math.rad(-90), 0, 0)
    local ap = hrp:FindFirstChild("FloatAlignPosition")
    if not ap and _G.ensureFloating then
        hrp.CFrame = cf
        task.wait(0.2)
        pcall(_G.ensureFloating, pos)
        return
    end
    hrp.CFrame = cf
    if ap then ap.Position = pos end
    local ao = hrp:FindFirstChild("FloatAlignOrientation")
    if ao then ao.CFrame = cf end
end

local function warpBackToStronghold()
    local hrp = getHRP()
    if not (hrp and isAlive()) then return end
    local returnPos = _G.finalGateBasePos or hrp.Position
    for _ = 1, 3 do
        hrp.CFrame = CFrame.new(returnPos + Vector3.new(0, 10, 0)) * CFrame.Angles(math.rad(-90), 0, 0)
        task.wait(0.8)
    end
end

-- release the hover; warp = also go back to the Stronghold
local function leaveOutside(warp)
    clearFloating()
    if warp then warpBackToStronghold() end
end

-- ============================================
-- Monster state
-- ============================================
local function isDead(monster)
    return not monster.Parent
        or monster:GetAttribute("Dead") == true
        or monster:HasTag("CultistCorpse")
end

-- live health, or nil when it cannot be trusted (0 after our own zero, or missing)
local function readHealth(monster)
    local hum = monster:FindFirstChildOfClass("Humanoid") or monster:FindFirstChildWhichIsA("Humanoid", true)
    local v = hum and hum.Health or monster:GetAttribute("Health")
    if type(v) == "number" and v > 0 then return v end
    return nil
end

-- seconds of burning left on the monster (BurnUntil is compared with the server clock)
local lastShotAt = 0
local function burnRemaining(monster)
    local untilT = monster:GetAttribute("BurnUntil")
    if type(untilT) ~= "number" then
        local hum = monster:FindFirstChildOfClass("Humanoid")
        untilT = hum and hum:GetAttribute("BurnUntil")
    end
    if type(untilT) == "number" then
        return untilT - workspace:GetServerTimeNow()
    end
    return (lastShotAt + BURN_FALLBACK) - tick()
end

-- wait while following the monster; returns early when it dies / disappears or the player dies
local function trackWait(monster, seconds)
    local untilT = tick() + seconds
    while tick() < untilT do
        if not isAlive() or isDead(monster) then return end
        local root = rootOf(monster)
        if root then hoverAt(root.Position + Vector3.new(0, hoverHeight(), 0)) end
        task.wait(0.1)
    end
end

-- ============================================
-- Fuel
-- ============================================
local deferred = setmetatable({}, { __mode = "k" })  -- [item] = { fails, retryAt, failFuel }
local refueling = false
local noFuelItemLogged = false
local fuelStatusLogged = false

local function baseName(name)
    return (string.gsub(name, "_%d+$", ""))
end

local function itemPosition(item)
    local ok, cf = pcall(function() return item:GetPivot() end)
    return ok and cf and cf.Position or nil
end

local function usable(item, fuel)
    local d = deferred[item]
    if not d then return true end
    local maxFails = cfg("PyromaniacMaxFuelFails", 3)
    if d.fails >= maxFails then return false end
    if os.clock() < d.retryAt and fuel > d.failFuel - 15 then return false end
    return true
end

-- Fuel Canister first (confirmed +30), Oil Barrel only when the tank is nearly empty.
-- Returns the item, or nil plus true when something exists but is parked.
local function pickFuelItem(fuel)
    local items = workspace:FindFirstChild("Items")
    if not items then return nil, false end
    local hrp = getHRP()
    local origin = hrp and hrp.Position or Vector3.zero
    local canister, canisterDist
    local barrel, barrelDist
    local parked = false
    for _, item in ipairs(items:GetChildren()) do
        local base = baseName(item.Name)
        local isCan = base == "Fuel Canister"
        local isBar = base == "Oil Barrel"
        if (isCan or isBar) and item.Parent == items then
            if usable(item, fuel) then
                local pos = itemPosition(item)
                local dist = pos and (pos - origin).Magnitude or math.huge
                if isCan and (not canisterDist or dist < canisterDist) then
                    canister, canisterDist = item, dist
                elseif isBar and (not barrelDist or dist < barrelDist) then
                    barrel, barrelDist = item, dist
                end
            else
                parked = true
            end
        end
    end
    if canister then return canister, parked end
    if barrel and fuel <= cfg("PyromaniacBarrelBelow", 10) then return barrel, parked end
    return nil, parked
end

-- same moves as Auto-Eat in MainScript: drag the item next to the player (no range check on the client)
local function pullItem(item)
    local hrp = getHRP()
    if not hrp then return false end
    return pcall(function()
        local folder = ReplicatedStorage:WaitForChild("RemoteEvents", 5)
        local startDrag = folder.RequestStartDraggingItem
        local stopDrag = folder.StopDraggingItem
        startDrag:FireServer(item)
        task.wait(0.1)
        if item:IsA("Model") then
            item:PivotTo(CFrame.new(hrp.Position))
        else
            item.CFrame = CFrame.new(hrp.Position)
        end
        task.wait(0.1)
        stopDrag:FireServer(item)
    end)
end

local function consumeItem(item)
    local parent = item.Parent
    local temp = ReplicatedStorage:FindFirstChild("TempStorage")
    if not temp then return false end
    item.Parent = temp
    local ok, res = pcall(function()
        local folder = ReplicatedStorage:FindFirstChild("RemoteEvents")
        return folder.RequestConsumeItem:InvokeServer(item)
    end)
    if not ok or not (type(res) == "table" and res.Success) then
        if item.Parent == temp then item.Parent = parent end
        return false
    end
    return true
end

-- pull + consume one fuel item. Returns true when the tank went up.
-- budget (seconds, optional) stops trying new items once it has been used up.
local function refuelOnce(budget)
    if refueling then return false end
    if not isAlive() then return false end
    refueling = true
    local startedAt = tick()
    local gained = false

    local ok, err = pcall(function()
        for _ = 1, 3 do
            if budget and tick() - startedAt >= budget then return end
            local before = fuelNow()
            local item, parked = pickFuelItem(before)
            if not item then
                if parked then
                    if not fuelStatusLogged then
                        fuelStatusLogged = true
                        Log.dev("[Pyromaniac] fuel items are parked, retrying later")
                    end
                    status("Pyromaniac: fuel items parked, retry later")
                elseif not noFuelItemLogged then
                    noFuelItemLogged = true
                    Log.err("[Pyromaniac] no usable fuel item found in workspace.Items", "waiting and rescanning")
                end
                return
            end
            local originalParent = item.Parent
            local name = item.Name
            pullItem(item)
            consumeItem(item)
            local waitUntil = tick() + 1.5
            while tick() < waitUntil and fuelNow() <= before do
                task.wait(0.05)
            end
            local after = fuelNow()
            if after > before then
                deferred[item] = nil
                noFuelItemLogged = false
                fuelStatusLogged = false
                gained = true
                Log.dev("[Pyromaniac] refuel +" .. tostring(after - before) .. " from " .. name)
                return
            end
            if item.Parent ~= originalParent and item.Parent ~= nil and item.Parent ~= workspace:FindFirstChild("Items") then
                pcall(function() item.Parent = originalParent end)
            end
            local d = deferred[item] or { fails = 0, retryAt = 0, failFuel = before }
            d.fails += 1
            d.retryAt = os.clock() + cfg("PyromaniacRetryDelay", 120) * d.fails
            d.failFuel = before
            deferred[item] = d
            Log.err("[Pyromaniac] " .. name .. " did not add fuel (try " .. d.fails .. "/" .. cfg("PyromaniacMaxFuelFails", 3) .. ")",
                "skipping it for now, trying another item")
        end
    end)
    refueling = false
    if not ok then
        Log.err("[Pyromaniac] refuel failed: " .. tostring(err), "retrying later")
    end
    return gained
end

-- refuel until the tank is above the threshold (bounded)
local function topUp(budget)
    local startedAt = tick()
    local below = cfg("PyromaniacRefuelBelow", 25)
    local guard = 0
    while fuelNow() <= below and guard < 8 do
        guard += 1
        if budget and tick() - startedAt >= budget then break end
        if not refuelOnce(budget) then break end
    end
end

-- true when the Flamethrower can be used now or after a refuel
local function canUseFlame()
    if fuelNow() > 0 then return true end
    local item = pickFuelItem(0)
    return item ~= nil
end

-- ============================================
-- Flamethrower hits
-- ============================================
local function remote(name)
    local folder = ReplicatedStorage:FindFirstChild("RemoteEvents")
    local r = folder and folder:FindFirstChild(name)
    if r then return r end
    local c = _G.Client
    if c and c.Events then
        local ok, v = pcall(function() return c.Events[name] end)
        if ok then return v end
    end
    return nil
end

local function enemyHandler()
    local c = _G.Client
    return c and c.EnemyHandler
end

-- one damage tick on one monster (same calls as the game's Flamethrower tool module).
-- Returns "ok", "rejected" (server refused), "skip" (not damageable) or "error".
local function hitOne(monster, flame, hrp)
    local ev = _G.Event
    local eh = enemyHandler()
    if not (ev and eh and eh.ApplyLocalDamage and hrp) then return "error" end
    local dmg = flame:GetAttribute("WeaponDamage") or 6
    local okD, id, undo = pcall(eh.ApplyLocalDamage, monster, dmg)
    if not okD then return "error" end
    if id == nil then return "skip" end
    local okH, res = pcall(function() return ev:InvokeServer(monster, flame, id, hrp.CFrame) end)
    if okH and type(res) == "table" and res.Success then return "ok" end
    -- a rejected hit must be undone, otherwise the monster's HP bar drifts
    if undo then pcall(undo) end
    return "rejected"
end

-- Start -> one tick -> Stop, as close together as possible
local function flameShot(monster, flame)
    local hrp = getHRP()
    if not hrp then return "error" end
    local startR, stopR = remote("StartFlamethrower"), remote("StopFlamethrower")
    if startR then pcall(function() startR:FireServer(flame) end) end
    local result = hitOne(monster, flame, hrp)
    if stopR then pcall(function() stopR:FireServer(flame) end) end
    lastShotAt = tick()
    return result
end

-- the game's own tool handler held for a short burst (fallback mode, confirmed to count)
local function flameBurst(monster, flame)
    local client = _G.Client
    local ih = client and client.InventoryHandler
    if not (ih and ih.ActivateTool) then return "error" end
    local char = LP.Character
    local head = char and char:FindFirstChild("Head")
    local hrp = getHRP()
    if not hrp then return "error" end
    local origin = head and head.Position or hrp.Position
    local look = head and head.CFrame.LookVector or hrp.CFrame.LookVector
    pcall(ih.ActivateTool, Ray.new(origin, look))
    trackWait(monster, CLIENT_BURST)
    if ih.DeactivateTool then pcall(ih.DeactivateTool) end
    local stopR = remote("StopFlamethrower")
    if stopR then pcall(function() stopR:FireServer(flame) end) end
    lastShotAt = tick()
    return "ok"
end

local hitMode = nil -- resolved lazily from Config, then switched automatically
local function currentHitMode()
    if hitMode == nil then
        hitMode = (cfg("PyromaniacHitMode", "remote") == "client") and "client" or "remote"
    end
    return hitMode
end

-- equip + one shot, with one retry when the server refused it (first shot after an equip)
local function fire(monster, flame)
    if not equipFlame(flame) then return "error" end
    if currentHitMode() == "client" then
        return flameBurst(monster, flame)
    end
    local r = flameShot(monster, flame)
    if r == "rejected" then
        trackWait(monster, SHOT_RETRY_WAIT)
        if not isDead(monster) then r = flameShot(monster, flame) end
    end
    return r
end

local function meleeHit(monster, axe)
    local ev, owner, hrp = _G.Event, _G.ownerId, getHRP()
    if not (ev and owner and hrp) then return false end
    local ok, res = pcall(function() return ev:InvokeServer(monster, axe, owner, hrp.CFrame, false) end)
    if not ok then return false end
    return not (type(res) == "table" and res.Success == false)
end

local function waitBurnEnd(monster)
    local guard = tick() + 6
    while tick() < guard do
        if not isAlive() or isDead(monster) then return end
        if burnRemaining(monster) <= 0 then return end
        trackWait(monster, 0.2)
    end
end

-- ============================================
-- Kill stall detection (EnemyKillsWithFire does not move -> switch the hit mode)
-- ============================================
local killsSinceProgress = 0
local lastKillCount = -1
local clientStallLogged = false

local function noteKill()
    local n = have()
    if n ~= lastKillCount then
        lastKillCount = n
        killsSinceProgress = 0
        return
    end
    killsSinceProgress += 1
    if killsSinceProgress < STALL_KILLS then return end
    killsSinceProgress = 0
    local text = string.format("[Pyromaniac] %s has not moved for %d kills (%d/%s)",
        KILLS_KEY, STALL_KILLS, n, tostring(goal()))
    if currentHitMode() == "remote" then
        hitMode = "client"
        Log.err(text, "switching to the ActivateTool hit mode")
    elseif not clientStallLogged then
        clientStallLogged = true
        Log.err(text, "still hunting (this error is logged only once)")
    end
end

-- ============================================
-- Kill sequence for one monster (outside a Stronghold)
-- Returns "killed", "failed" or "abort".
-- ============================================
local function killTarget(monster)
    local flame = getFlame()
    if not flame then return "abort" end
    local flameDmg = flame:GetAttribute("WeaponDamage") or 6
    local deadline = tick() + TARGET_DEADLINE
    local hpEst = readHealth(monster) or 100

    local function stop()
        return not isAlive() or tick() >= deadline or anyCultist() or M.isAllQuestDone()
    end

    local root = rootOf(monster)
    if not root then return "failed" end
    hoverAt(root.Position + Vector3.new(0, hoverHeight(), 0))
    if not equipFlame(flame) then return "failed" end

    -- 1) zero the HP, then one flame shot (a refused first shot is retried inside fire)
    for _ = 1, 1 + EXTRA_ZERO_ROUNDS do
        if stop() then break end
        if isDead(monster) then return "killed" end
        pcall(_G.zeroEnemyHealth, monster)
        trackWait(monster, ZERO_SETTLE)
        if isDead(monster) then return "killed" end
        local r = fire(monster, flame)
        if r == "skip" then return "failed" end
        if r == "ok" then hpEst -= flameDmg end
        trackWait(monster, DEATH_WAIT)
        if isDead(monster) then return "killed" end
    end

    -- 2) the zero did not work: let the burn finish (a kill by the burn does not count), then bring the HP
    --    down with the axe to <= flameDmg (never to 0) and finish with one flame shot
    waitBurnEnd(monster)
    local axe = getMelee()
    local axeDmg = axe and (axe:GetAttribute("WeaponDamage") or 0) or 0

    while not stop() do
        if isDead(monster) then return "killed" end
        local fresh = readHealth(monster)
        if fresh and math.abs(fresh - hpEst) > 0.5 then hpEst = fresh end
        if hpEst < 1 then hpEst = flameDmg end

        if hpEst <= flameDmg then
            -- closing shot: direct flame damage
            local r = fire(monster, flame)
            if r == "skip" then return "failed" end
            if r == "ok" then hpEst -= flameDmg end
            trackWait(monster, DEATH_WAIT)
            if isDead(monster) then return "killed" end
            waitBurnEnd(monster)
            if hpEst < 1 then hpEst = flameDmg end
        elseif axe and axeDmg > 0 and hpEst - axeDmg > 0 then
            -- axe hits in one go, so the weapon is swapped only once
            if not equip(axe) then return "failed" end
            while not stop() and not isDead(monster) and hpEst > flameDmg and hpEst - axeDmg > 0 do
                local r2 = rootOf(monster)
                if r2 then hoverAt(r2.Position + Vector3.new(0, hoverHeight(), 0)) end
                if meleeHit(monster, axe) then hpEst -= axeDmg end
                local f2 = readHealth(monster)
                if f2 and math.abs(f2 - hpEst) > 0.5 then hpEst = f2 end
                trackWait(monster, cooldownOf(axe))
            end
        else
            -- the axe would kill it (or there is none): lower the HP with the flame instead
            local r = fire(monster, flame)
            if r == "skip" then return "failed" end
            if r == "ok" then hpEst -= flameDmg end
            waitBurnEnd(monster)
            if hpEst < 1 then hpEst = flameDmg end
        end
        task.wait(0.05)
    end
    if isDead(monster) then return "killed" end
    return "failed"
end

-- ============================================
-- Stronghold hook (called by Module_Stronghold after it zeroed the cultists)
-- Returns false when the flamethrower cannot be used (the caller falls back to its normal hit).
-- ============================================
function M.strongholdHit(cultists, hrp)
    if type(cultists) ~= "table" then return false end
    if not isAlive() then return false end
    local flame = getFlame()
    if not flame then return false end

    if fuelNow() <= cfg("PyromaniacRefuelBelow", 25) then
        topUp(STRONGHOLD_REFUEL_BUDGET)
    end
    if fuelNow() <= 0 then return false end

    local me = getHRP() or hrp
    if not me then return false end
    if not equipFlame(flame) then return false end

    local targets = {}
    for _, c in ipairs(cultists) do
        if c and c.Parent and not isDead(c) then
            pcall(_G.zeroEnemyHealth, c) -- quick zero again (finish mode calls this without its own wait)
            targets[#targets + 1] = c
        end
    end
    if #targets == 0 then return true end

    local anyRefused = false
    if currentHitMode() == "client" then
        local client = _G.Client
        local ih = client and client.InventoryHandler
        if ih and ih.ActivateTool then
            local char = LP.Character
            local head = char and char:FindFirstChild("Head")
            local origin = head and head.Position or me.Position
            local look = head and head.CFrame.LookVector or me.CFrame.LookVector
            pcall(ih.ActivateTool, Ray.new(origin, look))
            task.wait(CLIENT_BURST)
            if ih.DeactivateTool then pcall(ih.DeactivateTool) end
            local stopR = remote("StopFlamethrower")
            if stopR then pcall(function() stopR:FireServer(flame) end) end
        end
    else
        local startR, stopR = remote("StartFlamethrower"), remote("StopFlamethrower")
        if startR then pcall(function() startR:FireServer(flame) end) end
        for _, c in ipairs(targets) do
            local r = hitOne(c, flame, me)
            if r == "rejected" then anyRefused = true end
        end
        if stopR then pcall(function() stopR:FireServer(flame) end) end
        lastShotAt = tick()

        -- the first shot after an equip can be refused: one retry for the refused ones
        if anyRefused then
            task.wait(SHOT_RETRY_WAIT)
            if startR then pcall(function() startR:FireServer(flame) end) end
            for _, c in ipairs(targets) do
                if c.Parent and not isDead(c) then hitOne(c, flame, me) end
            end
            if stopR then pcall(function() stopR:FireServer(flame) end) end
            lastShotAt = tick()
        end
    end

    -- give the server a moment to remove the cultists (kept short: the fight loop is waiting)
    local untilT = tick() + DEATH_WAIT
    while tick() < untilT do
        local allDead = true
        for _, c in ipairs(targets) do
            if not isDead(c) then allDead = false break end
        end
        if allDead then break end
        task.wait(0.1)
    end
    return true
end

-- Module_Stronghold asks this every tick: true = flamethrower only (no axe hits).
-- False when the quest is done or there is no fuel and nothing to refuel with, so the axe clears the round.
function M.specialWeaponOnly()
    if not (M.active and M.isPyromaniac) then return false end
    if M.isAllQuestDone() then return false end
    if not getFlame() then return false end
    return canUseFlame()
end

-- ============================================
-- Hunt (outside a Stronghold)
-- ============================================
local blacklist = setmetatable({}, { __mode = "k" }) -- [monster] = time until which it is skipped

-- never hunted: rabbits / bunnies, bees (hard to follow) and deer (HP cannot be zeroed)
local function isSkippedName(name)
    local n = string.lower(name)
    if string.find(n, "bunny", 1, true) or string.find(n, "rabbit", 1, true) then return true end
    if string.find(n, "deer", 1, true) then return true end
    if n == "bee" or n == "bees" or string.find(n, "^bee[%s_%-]") or string.find(n, "[%s_%-]bee$") then return true end
    local extra = cfg("PyromaniacSkipNames", nil)
    if type(extra) == "table" then
        for _, word in ipairs(extra) do
            if type(word) == "string" and word ~= "" and string.find(n, string.lower(word), 1, true) then return true end
        end
    end
    return false
end

local function nearestOf(list, origin)
    local best, bestDist
    for _, m in ipairs(list) do
        local r = rootOf(m)
        if r then
            local d = (r.Position - origin).Magnitude
            if not bestDist or d < bestDist then best, bestDist = m, d end
        end
    end
    return best
end

-- Returns true when something was attacked (so the caller does not idle).
local function huntCycle()
    local hrp = getHRP()
    if not hrp then return false end

    local finder = _G.findNightMonsters
    local okFind, monsters = pcall(finder or function() return {} end)
    if not okFind or type(monsters) ~= "table" then return false end

    local now = tick()
    local alive = {}
    for _, m in ipairs(monsters) do
        local blockedUntil = blacklist[m]
        if m.Parent and not isDead(m) and not isSkippedName(m.Name)
            and not (blockedUntil and now < blockedUntil) then
            alive[#alive + 1] = m
        end
    end
    local target = nearestOf(alive, hrp.Position)
    if not target then return false end

    -- refuel between targets only (never in the middle of a kill)
    if fuelNow() <= cfg("PyromaniacRefuelBelow", 25) then
        topUp()
    end
    if fuelNow() <= 0 then
        status("Pyromaniac: out of fuel, waiting")
        task.wait(5)
        return false
    end

    local result = killTarget(target)
    if result == "killed" then
        noteKill()
    elseif result == "failed" then
        blacklist[target] = tick() + BLACKLIST_SECONDS
        Log.dev("[Pyromaniac] could not kill " .. tostring(target.Name) .. " - skipping it for " .. BLACKLIST_SECONDS .. "s")
    elseif result == "abort" then
        return false
    end
    return true
end

-- ============================================
-- Fuel search flight (tank empty and no usable fuel item found): fly rings so far items stream in
-- ============================================
local SEARCH_STEPS = 48
local SEARCH_SPEED = 800
local SEARCH_RINGS = { 1, 0.5, 1.5 }
local searchLap = 0
local searchLogged = false

local function busyNow()
    return anyCultist() or roundActive() or strongholdOpen()
end

-- Returns true when the tank was refilled during the flight.
local function searchFuelCycle()
    local hrp = getHRP()
    if not hrp then return false end

    if not searchLogged then
        searchLogged = true
        Log.err("[Pyromaniac] out of fuel and no usable fuel item found", "flying around to look for Fuel Canister / Oil Barrel")
    end

    local center = _G.finalGateBasePos or hrp.Position
    searchLap += 1
    local ring = SEARCH_RINGS[((searchLap - 1) % #SEARCH_RINGS) + 1]
    local radius = cfg("PyromaniacSearchRadius", 1000) * ring
    local height = _G.airHeight or 150
    local duration = (2 * math.pi * radius) / SEARCH_SPEED

    for i = 0, SEARCH_STEPS do
        if busyNow() or M.isAllQuestDone() or not isAlive() then return false end
        local h = getHRP()
        if not h then return false end

        -- something usable showed up (streamed in or its parking time ended): use it
        local item = pickFuelItem(fuelNow())
        if item then
            local before = fuelNow()
            refuelOnce(STRONGHOLD_REFUEL_BUDGET)
            if fuelNow() > before then
                status(string.format("Pyromaniac: found fuel (%d)", math.floor(fuelNow())))
                searchLogged = false
                return true
            end
        end

        local angle = (i / SEARCH_STEPS) * math.pi * 2
        local pos = center + Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
        if i == 0 and not h:FindFirstChild("FloatAlignPosition") and _G.ensureFloating then
            h.CFrame = CFrame.new(pos)
            task.wait(0.2)
            pcall(_G.ensureFloating, pos)
        end
        h.CFrame = CFrame.new(pos)
        local ap = h:FindFirstChild("FloatAlignPosition")
        if ap then ap.Position = pos end
        local ao = h:FindFirstChild("FloatAlignOrientation")
        if ao then ao.CFrame = h.CFrame end
        status(string.format("Pyromaniac: searching for fuel (lap %d)", searchLap))
        task.wait(duration / SEARCH_STEPS)
    end
    return false
end

-- ============================================
-- Leave
-- ============================================
local lastLeaveAt = 0

local function leaveToLobby(reason)
    if tick() - lastLeaveAt < 20 then return end
    lastLeaveAt = tick()
    Log.dev("[Pyromaniac] Leaving: " .. tostring(reason))
    leaveOutside(false)
    status("Pyromaniac quest done - teleporting to Lobby")
    local fn = _G.forceTeleportLobby
    if fn then
        pcall(fn, "Pyromaniac quest complete")
    else
        task.wait(2)
        pcall(function()
            game:GetService("TeleportService"):Teleport(LOBBY_PLACE_ID, LP)
        end)
        task.wait(5)
    end
end

-- ============================================
-- Loop
-- ============================================
local running = false

function M.mainLoop()
    if not M.isPyromaniac then return end
    if not wantsUpgrade() then
        Log.dev("[Pyromaniac] Pyromaniac is not in UpgradeClass - module idle")
        return
    end

    local waited = 0
    while not getFlame() and waited < 60 do
        task.wait(1)
        waited += 1
    end
    if not getFlame() then
        local names = {}
        local inv = LP:FindFirstChild("Inventory")
        if inv then
            for _, t in ipairs(inv:GetChildren()) do names[#names + 1] = t.Name end
        end
        Log.err("[Pyromaniac] no Flamethrower found in Inventory (items: " .. table.concat(names, ", ") .. ")",
            "the module is idle")
        return
    end

    M.active = true
    Log.dev("[Pyromaniac] Loop started")
    local mode = "outside"

    while true do
        if not isAlive() then
            task.wait(1)
            continue
        end

        if not CQ[CLASS_NAME] or not CQ[CLASS_NAME][currentLevel() + 1] then
            Log.dev("[Pyromaniac] No quest left at this level - loop ended")
            break
        end

        local fighting = anyCultist()
        local busy = fighting or roundActive() or strongholdOpen()

        if M.isAllQuestDone() then
            pcall(_G.WSM_QuestDone, CLASS_NAME) -- unified "[Quest] Done" line, printed once
            -- Outside a round: leave right away. Inside a round: play to the end, the Stronghold flow
            -- collects the diamonds and leaves by itself.
            if not busy then
                leaveToLobby("quest complete")
                task.wait(5)
            else
                status("Pyromaniac quest complete - finishing the round")
                task.wait(0.5)
            end
            continue
        end

        if busy then
            if mode == "outside" then leaveOutside(fighting) end -- warp back only when cultists are out
            mode = "idle" -- Module_Stronghold moves the player and calls M.strongholdHit
            if fuelNow() <= cfg("PyromaniacRefuelBelow", 25) then
                pcall(topUp, STRONGHOLD_REFUEL_BUDGET)
            end
        else
            mode = "outside"
            if cfg("PyromaniacOutsideFarm", true) then
                local ok, err = pcall(function()
                    if fuelNow() <= cfg("PyromaniacRefuelBelow", 25) then topUp() end
                    if fuelNow() <= 0 then
                        -- tank empty and nothing to refuel with: fly around and look for fuel
                        if not searchFuelCycle() then task.wait(0.5) end
                    elseif not huntCycle() then
                        status("Pyromaniac: waiting for monsters")
                        task.wait(1)
                    end
                end)
                if not ok then
                    Log.err("[Pyromaniac] outside cycle failed: " .. tostring(err), "retrying in 1s")
                    task.wait(1)
                end
            end
        end

        task.wait(0.3)
    end
end

function M.runBackground()
    if running then return end
    running = true
    task.spawn(function()
        M.mainLoop()
        M.active = false
        running = false
    end)
end

function M.resume()
    M.runBackground()
end

return M
