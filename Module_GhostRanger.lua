-- ============================================
-- Module_GhostRanger.lua
-- Ghost Ranger class: finish the GhostCrossbowHits level-up quest by shooting the Ghost Crossbow.
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/main/Module_GhostRanger.lua
--
-- Globals read at load time (set by MainScript before the module is loaded):
--   LocalPlayer, CLASS_QUESTS, classStatCache, __WSM_currentClass
-- Globals read lazily (defined later by MainScript):
--   Client, Config, findNightMonsters, checkAnyCultistSpawned, ensureFloating,
--   finalGateBasePos, bestAxeCombat, updateStatus, forceTeleportLobby
--
-- Shooting
--   The module does not call the damage remotes itself: the game client reports every hit from its own projectile
--   code, which is not in the map dump. So it "clicks" the equipped crossbow with
--   Client.InventoryHandler.ActivateTool(Ray). The ray starts at the head and points at the target, raised by the
--   arrow drop (ProjectileGravity / ProjectileSpeed come from the tool attributes). Reloads are the game's own.
--
-- Behaviour (same shape as Module_Witch)
--   Outside a Stronghold : hover above the nearest monster (any monster, its HP is NOT zeroed) and shoot it.
--   Stronghold fight     : crossbow only while the quest is incomplete (M.specialWeaponOnly()). The crossbow stays equipped,
--                          the cultists' HP is not zeroed and the axe does not hit (MainScript / Module_Stronghold
--                          check M.specialWeaponOnly(), the name is kept so both class modules share one hook).
--   Quest complete       : force leave to the Lobby so the class can be upgraded:
--                          - outside a Stronghold round -> leave right away
--                          - inside a round -> play to the end, collect the diamonds, then leave right away
--
-- Config (all optional)
--   Config.GhostRangerOutsideFarm     = true  -- farm outside between Strongholds
--   Config.GhostRangerStrongholdShoot = true  -- crossbow-only mode during the Stronghold fight (false = off)
-- ============================================

local M = {}
local Log = _G.WSM_Log or {
    dev = function() end,
    err = function(reason, nextStep)
        warn("Error : " .. tostring(reason) .. " / " .. tostring(nextStep))
    end,
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LP = _G.LocalPlayer or Players.LocalPlayer
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}

local CLASS_NAME = "Ghost Ranger"
local STAT_KEY = "GhostCrossbowHits"

M.isGhostRanger = (_G.__WSM_currentClass or "Unknown") == CLASS_NAME

local LOBBY_PLACE_ID = 79546208627805
local HOVER_HEIGHT = 12            -- studs above the target while farming outside
local STRONGHOLD_RANGE = 150       -- max distance to a cultist for a shot during the fight
local OUTSIDE_RANGE = 250          -- max distance to a monster before the player hovers closer
local DEFAULT_FIRE_RATE = 0.1
local DEFAULT_SPEED = 150
local STALL_SHOTS = 40             -- shots without any GhostCrossbowHits progress before one diagnostic error

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

local function hitGoal()
    local reqs = CQ[CLASS_NAME] and CQ[CLASS_NAME][currentLevel() + 1]
    return reqs and reqs[STAT_KEY]
end

local function hitCount()
    local s = CSC[CLASS_NAME]
    return s and s[STAT_KEY] or 0
end

function M.isAllQuestDone()
    local g = hitGoal()
    return not g or hitCount() >= g
end

-- true while the main loop is running (crossbow found)
M.active = false

-- crossbow-only mode: the Stronghold fight must not use the axe or zero the cultists' HP.
-- Only true when this module really is shooting, otherwise the cultists would never die.
function M.specialWeaponOnly()
    return M.isGhostRanger and M.active
        and cfg("GhostRangerStrongholdShoot", true)
        and not M.isAllQuestDone()
end

-- ============================================
-- Tools
-- ============================================
-- Ghost Crossbow in the Inventory. The exact item name is not in the dump, so match by name keywords.
local function getCrossbow()
    local inv = LP:FindFirstChild("Inventory")
    if not inv then return nil end
    local exact = inv:FindFirstChild("Ghost Crossbow")
    if exact then return exact end
    for _, tool in ipairs(inv:GetChildren()) do
        local n = string.lower(tool.Name)
        if string.find(n, "ghost", 1, true) and (string.find(n, "crossbow", 1, true) or string.find(n, "bow", 1, true)) then
            return tool
        end
    end
    return nil
end

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
-- Shooting
-- ============================================
-- Client.InventoryHandler.ActivateTool(Ray) is the game's own "click": it runs the equipped tool's Fire(), which
-- checks the reload state, spends ammo, spawns the arrow and calls RegisterProjectile / the damage remotes itself.
-- (Confirmed in game: one ActivateTool call produced RegisterProjectile(tool, id, false).) When the magazine is
-- empty Fire() starts the game's own reload.
local shotsSinceProgress = 0
local lastCount = -1
local stallLogged = false
local lastShotAt = -10

local function noteProgress()
    local n = hitCount()
    if n ~= lastCount then
        lastCount = n
        shotsSinceProgress = 0
        return
    end
    if shotsSinceProgress >= STALL_SHOTS and not stallLogged then
        stallLogged = true
        Log.err("[GhostRanger] " .. STAT_KEY .. " has not moved for " .. STALL_SHOTS .. " shots (" .. n .. "/" .. tostring(hitGoal()) .. ")",
            "still shooting (this error is logged only once)")
    end
end

-- aim point with arrow drop added: the arrow flies at ProjectileSpeed with ProjectileGravity pulling it down
local function aimPoint(tool, from, targetPos)
    local speed = tool:GetAttribute("ProjectileSpeed") or DEFAULT_SPEED
    local gravity = tool:GetAttribute("ProjectileGravity") or 0
    local t = (targetPos - from).Magnitude / speed
    return targetPos + Vector3.new(0, 0.5 * gravity * t * t, 0)
end

-- target = enemy model. Returns true when a shot was sent.
local function shootAt(tool, target)
    local root = rootOf(target)
    local head = LP.Character and LP.Character:FindFirstChild("Head")
    local client = _G.Client
    if not (root and head and client and client.InventoryHandler) then return false end

    -- the tool is reloading: Fire() would return at once, do not spam it
    if tool:GetAttribute("ServerReloading") then return false end
    local finish = tool:GetAttribute("ReloadFinishTime")
    if finish and time() < finish then return false end
    local rate = tool:GetAttribute("FireRate") or DEFAULT_FIRE_RATE
    if tick() - lastShotAt < rate then return false end
    lastShotAt = tick()

    local from = head.Position
    local dir = aimPoint(tool, from, root.Position) - from
    if dir.Magnitude < 0.5 then return false end

    -- spawned: an empty magazine makes Fire() wait for the whole reload inside this call
    task.spawn(function()
        local ok, err = pcall(function()
            client.InventoryHandler.ActivateTool(Ray.new(from, dir.Unit))
        end)
        if not ok then
            Log.err("[GhostRanger] ActivateTool failed: " .. tostring(err), "retrying on the next shot")
        end
    end)

    shotsSinceProgress += 1
    noteProgress()
    status(string.format("Ghost Ranger: %s %d/%d", STAT_KEY, hitCount(), hitGoal() or 0))
    return true
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

-- cultists to shoot at: includes HP-zeroed ones (the HP-zero watcher runs before the shot)
local function strongholdEnemies()
    local list = {}
    local chars = workspace:FindFirstChild("Characters")
    if not chars then return list end
    for _, m in ipairs(chars:GetChildren()) do
        if m:IsA("Model")
            and m:GetAttribute("StrongholdEnemy") == true
            and m:GetAttribute("Resurrected") ~= true
            and m:GetAttribute("NotAttackable") ~= true
            and m:GetAttribute("Dead") ~= true
            and not m:HasTag("CultistCorpse")
            and not Players:GetPlayerFromCharacter(m)
            and m:FindFirstChildOfClass("Humanoid") then
            list[#list + 1] = m
        end
    end
    return list
end

-- ============================================
-- Movement (outside only)
-- ============================================
local function clearFloating()
    local hrp = getHRP()
    if not hrp then return end
    for _, name in ipairs({ "FloatAlignPosition", "FloatAlignOrientation", "FloatAttachment" }) do
        local o = hrp:FindFirstChild(name)
        if o then pcall(function() o:Destroy() end) end
    end
end

local function hoverAt(pos)
    local hrp = getHRP()
    if not hrp then return end
    if (hrp.Position - pos).Magnitude > 20 then
        hrp.CFrame = CFrame.new(pos)
    end
    local ap = hrp:FindFirstChild("FloatAlignPosition")
    if ap then
        ap.Position = pos
    elseif _G.ensureFloating then
        task.wait(0.2)
        pcall(_G.ensureFloating, pos)
    end
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

-- release the hover and hold the axe again (not in crossbow-only mode); warp = also go back to the Stronghold
local function leaveOutside(warp)
    clearFloating()
    if not M.specialWeaponOnly() then equipAxe() end
    if warp then warpBackToStronghold() end
end

-- ============================================
-- Cycles
-- ============================================
local function nearestOf(list, origin, maxDist)
    local best, bestDist
    for _, m in ipairs(list) do
        local r = rootOf(m)
        if r then
            local d = (r.Position - origin).Magnitude
            if (not maxDist or d <= maxDist) and (not bestDist or d < bestDist) then
                best, bestDist = m, d
            end
        end
    end
    return best, bestDist
end

-- Outside: any monster, nearest first, HP untouched so it can be hit again
local function outsideCycle()
    local tool = getCrossbow()
    if not tool then task.wait(1) return end
    local hrp = getHRP()
    if not hrp then return end

    equip(tool)

    local finder = _G.findNightMonsters
    local okFind, monsters = pcall(finder or function() return {} end)
    if not okFind or type(monsters) ~= "table" or #monsters == 0 then
        status("Ghost Ranger: waiting for monsters")
        task.wait(1)
        return
    end

    local target = nearestOf(monsters, hrp.Position)
    if not target then task.wait(1) return end

    -- follow the target and keep shooting until it dies, leaves, or a Stronghold / quest end interrupts
    local deadline = tick() + 20
    while tick() < deadline do
        if not (target.Parent and isAlive()) then return end
        if anyCultist() or M.isAllQuestDone() then return end
        local root = rootOf(target)
        if not root then return end
        local hum = target:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health <= 0 then return end

        hoverAt(root.Position + Vector3.new(0, HOVER_HEIGHT, 0))
        if equip(tool) then
            local hrpNow = getHRP()
            if hrpNow and (root.Position - hrpNow.Position).Magnitude <= OUTSIDE_RANGE then
                shootAt(tool, target)
            end
        end
        task.wait(0.1)
    end
end

-- Fight: stay where the Stronghold flow put us, shoot the cultist nearest to the group centre
local function fightCycle()
    local tool = getCrossbow()
    local hrp = getHRP()
    if not (tool and hrp) then return end

    if not equip(tool) then return end -- crossbow only: always hold it during the fight (no-op when already held)

    local list = strongholdEnemies()
    local inRange, centroid = {}, Vector3.zero
    for _, m in ipairs(list) do
        local r = rootOf(m)
        if r and (r.Position - hrp.Position).Magnitude <= STRONGHOLD_RANGE then
            inRange[#inRange + 1] = m
            centroid = centroid + r.Position
        end
    end
    if #inRange == 0 then return end
    centroid = centroid / #inRange

    local target = nearestOf(inRange, centroid)
    if not target then return end

    shootAt(tool, target)
end

-- ============================================
-- Leave
-- ============================================
local lastLeaveAt = 0

local function leaveToLobby(reason)
    if tick() - lastLeaveAt < 20 then return end
    lastLeaveAt = tick()
    leaveOutside(false)
    status("Ghost Ranger quest done - teleporting to Lobby")
    local fn = _G.forceTeleportLobby
    if fn then
        pcall(fn, "Ghost Ranger quest complete")
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
    if not M.isGhostRanger then return end
    if not wantsUpgrade() then
        Log.dev("[GhostRanger] Ghost Ranger is not in UpgradeClass - module idle")
        return
    end

    local waited = 0
    while not getCrossbow() and waited < 60 do
        task.wait(1)
        waited += 1
    end
    if not getCrossbow() then
        local names = {}
        local inv = LP:FindFirstChild("Inventory")
        if inv then
            for _, t in ipairs(inv:GetChildren()) do names[#names + 1] = t.Name end
        end
        Log.err("[GhostRanger] Ghost Crossbow not found in Inventory (items: " .. table.concat(names, ", ") .. ")",
            "the Ghost Ranger loop is not started")
        return
    end

    M.active = true
    Log.dev("[GhostRanger] Loop started")
    local mode = "outside"

    while true do
        if not isAlive() then
            task.wait(1)
            continue
        end

        local goal = hitGoal()
        if not goal then
            Log.dev("[GhostRanger] No " .. STAT_KEY .. " quest left at this level - loop ended")
            break
        end

        local fighting = anyCultist()
        local busy = fighting or roundActive() or strongholdOpen()

        if hitCount() >= goal then
            pcall(_G.WSM_QuestDone, CLASS_NAME) -- unified "[Quest] Done" line, printed once
            -- Quest complete. Outside a round: leave right away. Inside a round: play to the end,
            -- the Stronghold flow collects the diamonds, then this leaves right away.
            if not busy then
                leaveToLobby(string.format("%s %d/%d reached", STAT_KEY, hitCount(), goal))
                task.wait(5)
            else
                status("Ghost Ranger quest complete - finishing the round")
                task.wait(0.5)
            end
            continue
        end

        if fighting then
            if mode ~= "fight" then
                if mode == "outside" then leaveOutside(true) end
                mode = "fight"
            end
            if cfg("GhostRangerStrongholdShoot", true) then
                local ok, err = pcall(fightCycle)
                if not ok then Log.err("[GhostRanger] fight cycle failed: " .. tostring(err), "retrying on the next tick") end
            end
        elseif busy then
            -- Stronghold open but no cultist yet / between waves: the Stronghold flow moves the player
            if mode == "outside" then leaveOutside(false) end
            mode = "idle"
        else
            mode = "outside"
            if cfg("GhostRangerOutsideFarm", true) then
                local ok, err = pcall(outsideCycle)
                if not ok then
                    Log.err("[GhostRanger] outside cycle failed: " .. tostring(err), "retrying in 1s")
                    task.wait(1)
                end
            end
        end

        task.wait(0.1)
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
