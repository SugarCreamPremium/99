-- ============================================
-- Module_Assassin.lua
-- Assassin class: finish the level-up quests
--   PerfectKills (kill monsters without taking damage, Katana) and TravelStuds (distance travelled).
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/main/Module_Assassin.lua
--
-- Globals read at load time (set by MainScript before the module is loaded):
--   LocalPlayer, CLASS_QUESTS, classStatCache, __WSM_currentClass
-- Globals read lazily (defined later by MainScript):
--   Event, ownerId, Client, Config, findNightMonsters, checkAnyCultistSpawned, ensureFloating, getToolCooldown,
--   zeroEnemyHealth, airHeight, finalGateBasePos, bestAxeCombat, updateStatus, forceTeleportLobby, HOVER_HEIGHT
--
-- Behaviour (same shape as Module_Witch / Module_GhostRanger)
--   Outside a Stronghold : hunt the nearest monster with the Katana (PerfectKills), or fly circles (TravelStuds).
--   Stronghold round     : the Stronghold flow moves the player; this module only releases the hover and holds the axe.
--   Quest complete       : leave to the Lobby so the class can be upgraded:
--                          - outside a Stronghold round -> leave right away
--                          - inside a round -> play to the end, collect the diamonds, then leave
--   Damage taken is not handled here: the God Mode patch in MainScript swallows the client damage reports.
--
-- Hit styles (Config.AssassinHitMode)
--   "zero"  (default, Woodsman / BGH style): zero the monster's HP, wait 1s, then hit with the fixed ownerId.
--   "local" (Necromancer style)            : register the damage with Client.EnemyHandler.ApplyLocalDamage and hit,
--                                            the HP is NOT zeroed. Used automatically when "zero" does not move PerfectKills.
--
-- Config (all optional)
--   Config.AssassinOutsideFarm   = true   -- hunt / travel outside between Strongholds
--   Config.AssassinHoverHeight   = 10     -- studs above the target (default _G.HOVER_HEIGHT or 10)
--   Config.AssassinHitMode       = "zero" -- "zero" or "local"
--   Config.AssassinTravelRadius  = 500    -- radius of the TravelStuds circle
--   Config.AssassinSkipNames     = {}     -- extra name fragments to never hunt (rabbits / bunnies / bees are always skipped)
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

local LP = _G.LocalPlayer or Players.LocalPlayer
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}

local CLASS_NAME = "Assassin"
local KILLS_KEY = "PerfectKills"
local TRAVEL_KEY = "TravelStuds"

M.isAssassin = (_G.__WSM_currentClass or "Unknown") == CLASS_NAME

local LOBBY_PLACE_ID = 79546208627805
local TARGET_DEADLINE = 20           -- seconds per target before giving up on it
local ZERO_SETTLE = 1                -- seconds between zeroing the HP and the first hit
local MAX_HITS_ZERO = 5              -- hits in "zero" mode before the target counts as a failure
local ZERO_FAIL_LIMIT = 3            -- consecutive "zero" failures before switching to "local"
local STALL_KILLS = 15               -- kills without PerfectKills progress before a switch / error
local TRAVEL_STEPS = 60
local TRAVEL_SPEED = 800
local TRAVEL_STALL_LAPS = 3

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

-- ============================================
-- Quest checks (stats come from the ClassStatUpdated cache in MainScript)
-- ============================================
local function currentLevel()
    return LP:GetAttribute("ClassLevel") or 1
end

local function goal(key)
    local reqs = CQ[CLASS_NAME] and CQ[CLASS_NAME][currentLevel() + 1]
    return reqs and reqs[key]
end

local function have(key)
    local s = CSC[CLASS_NAME]
    local v = s and s[key]
    return type(v) == "number" and v or 0
end

local function statDone(key)
    local g = goal(key)
    return not g or have(key) >= g
end

function M.isKillsDone() return statDone(KILLS_KEY) end
function M.isTravelDone() return statDone(TRAVEL_KEY) end

function M.isAllQuestDone()
    return M.isKillsDone() and M.isTravelDone()
end

-- true while the main loop is running
M.active = false

-- ============================================
-- Tools
-- ============================================
local function heldItem()
    local c = LP.Character
    local th = c and c:FindFirstChild("ToolHandle")
    local oi = th and th:FindFirstChild("OriginalItem")
    return oi and oi.Value or nil
end

-- RequestEquipItem rebuilds ToolHandle every time, so only call it when the item is not already held
local function equip(item)
    if not item or not item.Parent then return false end
    if heldItem() == item then return true end
    local client = _G.Client
    if not (client and client.InventoryHandler) then return false end
    pcall(function() client.InventoryHandler.RequestEquipItem(item) end)
    for _ = 1, 15 do
        if heldItem() == item then return true end
        task.wait(0.1)
    end
    return false
end

-- Katana first, otherwise the strongest sword / axe that is not broken
local function getWeapon()
    local inv = LP:FindFirstChild("Inventory")
    if not inv then return nil end
    local katana = inv:FindFirstChild("Katana")
    if katana then return katana end
    local best, bestDmg = nil, -1
    for _, tool in ipairs(inv:GetChildren()) do
        local kind = tool:GetAttribute("ToolName")
        if kind == "GenericSword" or kind == "GenericAxe" then
            local dur = tool:GetAttribute("Durability")
            if dur == nil or dur > 0 then
                local dmg = tool:GetAttribute("WeaponDamage") or 0
                if dmg > bestDmg then best, bestDmg = tool, dmg end
            end
        end
    end
    return best
end

-- the combat axe chosen by MainScript, or the strongest GenericAxe in the Inventory as a fallback
local function findAxe()
    local axe = _G.bestAxeCombat
    if axe and axe.Parent then return axe end
    local inv = LP:FindFirstChild("Inventory")
    local best, bestDmg = nil, -1
    if inv then
        for _, tool in ipairs(inv:GetChildren()) do
            if tool:GetAttribute("ToolName") == "GenericAxe" then
                local dmg = tool:GetAttribute("WeaponDamage") or 0
                if dmg > bestDmg then best, bestDmg = tool, dmg end
            end
        end
    end
    return best
end

local function equipAxe()
    local axe = findAxe()
    if axe then equip(axe) end
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

-- keep the player floating at pos (warp when far, then move the float constraint)
local function hoverAt(pos)
    local hrp = getHRP()
    if not hrp then return end
    local ap = hrp:FindFirstChild("FloatAlignPosition")
    if not ap and _G.ensureFloating then
        hrp.CFrame = CFrame.new(pos)
        task.wait(0.2)
        pcall(_G.ensureFloating, pos)
        return
    end
    hrp.CFrame = CFrame.new(pos)
    if ap then ap.Position = pos end
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

-- release the hover and hold the axe again; warp = also go back to the Stronghold
local function leaveOutside(warp)
    clearFloating()
    equipAxe()
    if warp then warpBackToStronghold() end
end

-- ============================================
-- Hunt (PerfectKills)
-- ============================================
local hitMode = nil            -- resolved lazily from Config, then switched automatically
local zeroFailStreak = 0
local killsSinceProgress = 0
local lastKillCount = -1
local localModeErrLogged = false
local noEnemyHandlerLogged = false

local function currentHitMode()
    if hitMode == nil then
        hitMode = (cfg("AssassinHitMode", "zero") == "local") and "local" or "zero"
    end
    return hitMode
end

-- Monsters the hunt never targets: rabbits / bunnies and bees (fast, hard to follow, not worth the time).
-- Matched on the lower-cased model name; extra names can be added with Config.AssassinSkipNames.
local function isSkippedName(name)
    local n = string.lower(name)
    if string.find(n, "bunny", 1, true) or string.find(n, "rabbit", 1, true) then return true end
    if n == "bee" or n == "bees" or string.find(n, "^bee[%s_%-]") or string.find(n, "[%s_%-]bee$") then return true end
    local extra = cfg("AssassinSkipNames", nil)
    if type(extra) == "table" then
        for _, word in ipairs(extra) do
            if type(word) == "string" and word ~= "" and string.find(n, string.lower(word), 1, true) then return true end
        end
    end
    return false
end

local function isDead(monster)
    return not monster.Parent
        or monster:GetAttribute("Dead") == true
        or monster:HasTag("CultistCorpse")
end

local function cooldownOf(tool)
    local fn = _G.getToolCooldown
    local cd = 0.42
    if fn then
        local ok, v = pcall(fn, tool)
        if ok and type(v) == "number" then cd = v end
    end
    return math.max(cd, 0.1)
end

-- one hit in "zero" mode. Returns false when the request itself errored.
local function hitZero(monster, tool, hrp)
    local ev = _G.Event
    local owner = _G.ownerId
    if not (ev and owner) then return false end
    local ok = pcall(function()
        ev:InvokeServer(monster, tool, owner, hrp.CFrame, false)
    end)
    return ok
end

-- one hit in "local" mode. Returns "ok", "skip" (not damageable) or "error".
local function hitLocal(monster, tool, hrp)
    local ev = _G.Event
    local client = _G.Client
    if not ev then return "error" end
    if not (client and client.EnemyHandler and client.EnemyHandler.ApplyLocalDamage) then
        if not noEnemyHandlerLogged then
            noEnemyHandlerLogged = true
            Log.err("[Assassin] Client.EnemyHandler.ApplyLocalDamage is missing", "the local hit mode cannot be used")
        end
        return "error"
    end
    local dmg = tool:GetAttribute("WeaponDamage") or 15
    local okDmg, id, undo = pcall(function()
        return client.EnemyHandler.ApplyLocalDamage(monster, dmg)
    end)
    if not okDmg then return "error" end
    if id == nil then return "skip" end
    local okHit, res = pcall(function() return ev:InvokeServer(monster, tool, id, hrp.CFrame, false) end)
    -- a rejected hit must be undone, otherwise the monster's HP bar drifts
    if (not okHit or (type(res) == "table" and res.Success == false)) and undo then
        pcall(undo)
    end
    return okHit and "ok" or "error"
end

-- count a kill and switch the hit style when PerfectKills does not move
local function noteKill()
    local n = have(KILLS_KEY)
    if n ~= lastKillCount then
        lastKillCount = n
        killsSinceProgress = 0
        return
    end
    killsSinceProgress += 1
    if killsSinceProgress < STALL_KILLS then return end
    killsSinceProgress = 0
    local text = string.format("[Assassin] %s has not moved for %d kills (%d/%s)",
        KILLS_KEY, STALL_KILLS, n, tostring(goal(KILLS_KEY)))
    if currentHitMode() == "zero" then
        hitMode = "local"
        Log.err(text, "switching to the local-damage hit mode")
    elseif not localModeErrLogged then
        localModeErrLogged = true
        Log.err(text, "still hunting (this error is logged only once)")
    end
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
local function huntCycle(tool)
    local hrp = getHRP()
    if not hrp then return false end

    local finder = _G.findNightMonsters
    local okFind, monsters = pcall(finder or function() return {} end)
    if not okFind or type(monsters) ~= "table" then return false end
    local alive = {}
    for _, m in ipairs(monsters) do
        if m.Parent and not isDead(m) and not isSkippedName(m.Name) then alive[#alive + 1] = m end
    end
    local target = nearestOf(alive, hrp.Position)
    if not target then return false end

    local height = cfg("AssassinHoverHeight", _G.HOVER_HEIGHT or 10)
    local mode = currentHitMode()
    local cooldown = cooldownOf(tool)
    local deadline = tick() + TARGET_DEADLINE
    local hits = 0
    local zeroed = false
    local died = false

    equip(tool)

    while tick() < deadline do
        if not (target.Parent and isAlive()) then break end
        if anyCultist() or M.isKillsDone() then break end
        if isDead(target) then died = true break end
        local root = rootOf(target)
        local hrpNow = getHRP()
        if not (root and hrpNow) then break end

        hoverAt(root.Position + Vector3.new(0, height, 0))
        if not equip(tool) then break end

        if mode == "zero" then
            if not zeroed then
                zeroed = true
                pcall(_G.zeroEnemyHealth, target)
                task.wait(ZERO_SETTLE)
                continue
            end
            if hits >= MAX_HITS_ZERO then break end
            if not hitZero(target, tool, hrpNow) then break end
            hits += 1
        else
            local r = hitLocal(target, tool, hrpNow)
            if r == "skip" then break end
            if r == "error" then task.wait(0.5) end
            hits += 1
        end
        task.wait(cooldown)
    end

    -- the final hit may have killed it: give the server a moment to remove / tag it
    if not died and target.Parent and not isDead(target) then
        task.wait(0.2)
    end
    died = died or isDead(target)

    if died then
        zeroFailStreak = 0
        noteKill()
    elseif mode == "zero" and hits >= MAX_HITS_ZERO then
        zeroFailStreak += 1
        if zeroFailStreak >= ZERO_FAIL_LIMIT then
            zeroFailStreak = 0
            hitMode = "local"
            Log.err("[Assassin] the zero-HP hit did not kill " .. ZERO_FAIL_LIMIT .. " targets in a row",
                "switching to the local-damage hit mode")
        end
    end
    return true
end

-- ============================================
-- Travel (TravelStuds): circle around the Stronghold at flying height, same loop as the BGH scan
-- ============================================
local travelLaps = 0
local travelLastCount = -1
local travelStallLogged = false

local function busyNow()
    return anyCultist() or roundActive() or strongholdOpen()
end

local function travelCycle()
    local hrp = getHRP()
    if not hrp then return end

    local center = _G.finalGateBasePos or hrp.Position
    local radius = cfg("AssassinTravelRadius", 500)
    local height = _G.airHeight or 150
    local duration = (2 * math.pi * radius) / TRAVEL_SPEED
    local startCount = have(TRAVEL_KEY)

    for i = 0, TRAVEL_STEPS do
        if busyNow() or M.isTravelDone() or not isAlive() then return end
        local h = getHRP()
        if not h then return end
        local angle = (i / TRAVEL_STEPS) * math.pi * 2
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
        task.wait(duration / TRAVEL_STEPS)
    end

    travelLaps += 1

    local n = have(TRAVEL_KEY)
    if n ~= travelLastCount or n ~= startCount then
        travelLastCount = n
        travelLaps = 0
    elseif travelLaps >= TRAVEL_STALL_LAPS and not travelStallLogged then
        travelStallLogged = true
        Log.err("[Assassin] " .. TRAVEL_KEY .. " has not moved for " .. TRAVEL_STALL_LAPS .. " laps (" .. n .. "/" .. tostring(goal(TRAVEL_KEY)) .. ")",
            "still flying (this error is logged only once)")
    end
end

-- ============================================
-- Leave
-- ============================================
local lastLeaveAt = 0

local function leaveToLobby(reason)
    if tick() - lastLeaveAt < 20 then return end
    lastLeaveAt = tick()
    Log.dev("[Assassin] Leaving: " .. tostring(reason))
    leaveOutside(false)
    status("Assassin quest done - teleporting to Lobby")
    local fn = _G.forceTeleportLobby
    if fn then
        pcall(fn, "Assassin quest complete")
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
    if not M.isAssassin then return end
    if not wantsUpgrade() then
        Log.dev("[Assassin] Assassin is not in UpgradeClass - module idle")
        return
    end

    local waited = 0
    while not getWeapon() and waited < 60 do
        task.wait(1)
        waited += 1
    end
    if not getWeapon() then
        local names = {}
        local inv = LP:FindFirstChild("Inventory")
        if inv then
            for _, t in ipairs(inv:GetChildren()) do names[#names + 1] = t.Name end
        end
        Log.err("[Assassin] no Katana / sword found in Inventory (items: " .. table.concat(names, ", ") .. ")",
            "hunting is off, only the travel loop can run")
    end

    M.active = true
    Log.dev("[Assassin] Loop started")
    local mode = "outside"

    while true do
        if not isAlive() then
            task.wait(1)
            continue
        end

        if not CQ[CLASS_NAME] or not CQ[CLASS_NAME][currentLevel() + 1] then
            Log.dev("[Assassin] No quest left at this level - loop ended")
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
                status("Assassin quest complete - finishing the round")
                task.wait(0.5)
            end
            continue
        end

        if busy then
            if mode == "outside" then leaveOutside(fighting) end -- warp back only when cultists are out
            mode = "idle" -- the Stronghold flow moves the player
        else
            mode = "outside"
            if cfg("AssassinOutsideFarm", true) then
                local ok, err = pcall(function()
                    local tool = getWeapon()
                    local didHunt = false
                    if not M.isKillsDone() and tool then
                        didHunt = huntCycle(tool)
                    end
                    if not didHunt then
                        if not M.isTravelDone() then
                            travelCycle()
                        else
                            status("Assassin: waiting for monsters")
                            task.wait(1)
                        end
                    end
                end)
                if not ok then
                    Log.err("[Assassin] outside cycle failed: " .. tostring(err), "retrying in 1s")
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
