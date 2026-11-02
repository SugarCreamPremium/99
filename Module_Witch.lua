-- ============================================
-- Module_Witch.lua
-- Witch class: finish the HitPotion level-up quest by throwing the Witch Potion.
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/main/Module_Witch.lua
--
-- Globals read at load time (set by MainScript before the module is loaded):
--   LocalPlayer, CLASS_QUESTS, classStatCache, __WSM_currentClass
-- Globals read lazily (defined later by MainScript):
--   Client, Config, findNightMonsters, checkAnyCultistSpawned, ensureFloating,
--   finalGateBasePos, bestAxeCombat, updateStatus, forceTeleportLobby
--
-- Throw (direct remotes, the same calls the game client makes for a thrown potion):
--   RequestReloadFirearm(potion)                    -> { Success, Ammo }, then ReloadTime (5.5s) must pass
--   RegisterProjectile(potion, projectileId)
--   SplashProjectileExplode(position, projectileId) after the flight time (distance / speed)
-- The potion holds one charge, so there is about one throw every 6 seconds.
--
-- Behaviour
--   Outside a Stronghold : hover above the nearest monster (any monster, its HP is NOT zeroed) and throw.
--   Stronghold fight     : potion only while the quest is incomplete (M.potionOnly()). The potion stays equipped,
--                          the cultists' HP is not zeroed and the axe does not hit (MainScript / Module_Stronghold
--                          check M.potionOnly()). Throws never stop, there is no throw limit.
--   Quest complete       : force leave to the Lobby so the class can be upgraded:
--                          - outside a Stronghold round -> leave right away
--                          - inside a round -> play to the end, collect the diamonds, then leave right away
--                            (the round state comes from _G.WSM_StrongholdRound set by Module_Stronghold)
--
-- Config (all optional)
--   Config.WitchOutsideFarm     = true   -- farm outside between Strongholds
--   Config.WitchStrongholdThrow = true   -- also throw during the Stronghold fight (false = potion-only mode is off)
-- ============================================

local M = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LP = _G.LocalPlayer or Players.LocalPlayer
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}

M.isWitch = (_G.__WSM_currentClass or "Unknown") == "Witch"

local LOBBY_PLACE_ID = 79546208627805
local POTION_NAME = "Witch Potion"
local HOVER_HEIGHT = 15        -- studs above the target while farming outside
local STRONGHOLD_RANGE = 70    -- max distance to a cultist for a throw during the fight
local DEFAULT_RELOAD = 5.5
local DEFAULT_SPEED = 80       -- ThrownWeapon default ProjectileSpeed
local MIN_FLIGHT = 0.15
local MAX_FLIGHT = 1.5
local INVOKE_TIMEOUT = 4

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

local function describe(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(x)
        if #parts >= 4 then break end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function wantsUpgrade()
    local list = cfg("UpgradeClass", nil)
    if type(list) ~= "table" then return false end
    for _, name in ipairs(list) do
        if name == "Witch" then return true end
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
    local reqs = CQ.Witch and CQ.Witch[currentLevel() + 1]
    return reqs and reqs.HitPotion
end

local function hitCount()
    local s = CSC.Witch
    return s and s.HitPotion or 0
end

function M.isAllQuestDone()
    local g = hitGoal()
    return not g or hitCount() >= g
end

-- true while the main loop is running (potion found, remotes resolved)
M.active = false

-- potion-only mode: the Stronghold fight must not use the axe or zero the cultists' HP.
-- Only true when this module really is throwing, otherwise the cultists would never die.
function M.potionOnly()
    return M.isWitch and M.active
        and cfg("WitchStrongholdThrow", true)
        and not M.isAllQuestDone()
end

-- ============================================
-- Remotes
-- ============================================
local Reload, Register, Explode

local function resolveRemotes()
    local ok, folder = pcall(function()
        return ReplicatedStorage:WaitForChild("RemoteEvents", 60)
    end)
    if not ok or not folder then return false end
    Reload = folder:WaitForChild("RequestReloadFirearm", 15)
    Register = folder:WaitForChild("RegisterProjectile", 15)
    Explode = folder:WaitForChild("SplashProjectileExplode", 15)
    return Reload ~= nil and Register ~= nil and Explode ~= nil
end

-- InvokeServer with a timeout so a silent server never freezes the loop
local function invoke(remote, ...)
    local args = table.pack(...)
    local done, ok, res = false, false, nil
    task.spawn(function()
        ok, res = pcall(function()
            return remote:InvokeServer(table.unpack(args, 1, args.n))
        end)
        done = true
    end)
    local t0 = tick()
    while not done and tick() - t0 < INVOKE_TIMEOUT do
        task.wait(0.05)
    end
    if not done then return false, "timeout" end
    return ok, res
end

-- ============================================
-- Tools
-- ============================================
local function getPotion()
    local inv = LP:FindFirstChild("Inventory")
    return inv and inv:FindFirstChild(POTION_NAME)
end

local function heldItem()
    local c = LP.Character
    local th = c and c:FindFirstChild("ToolHandle")
    local oi = th and th:FindFirstChild("OriginalItem")
    return oi and oi.Value or nil
end

-- RequestEquipItem may toggle, so only call it when the item is not already held
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
-- Potion state: one charge per reload
-- ============================================
local loaded = false
local readyAt = 0
local reloadFailLogged = false
local lastReloadTry = -10

local function reloadTime(potion)
    return potion:GetAttribute("ReloadTime") or DEFAULT_RELOAD
end

-- force = ask the server for a reload even if the Ammo attribute looks fine (used after every throw)
local function prepare(potion, force)
    if loaded then return true end
    if not force then
        local ammo = potion:GetAttribute("Ammo")
        if type(ammo) == "number" and ammo > 0 then
            loaded, readyAt = true, 0
            return true
        end
    end
    if potion:GetAttribute("ServerReloading") then
        -- the server is already reloading: wait a full reload time to be safe
        loaded, readyAt = true, tick() + reloadTime(potion)
        return true
    end
    if tick() - lastReloadTry < 2 then return false end -- never spam a refused reload
    lastReloadTry = tick()
    local ok, res = invoke(Reload, potion)
    if ok and type(res) == "table" and res.Success then
        loaded, readyAt = true, tick() + reloadTime(potion) + 0.3
        return true
    end
    if not reloadFailLogged then
        reloadFailLogged = true
        warn("[Witch] Reload request refused: " .. describe(res))
    end
    return false
end

local function isReady(potion)
    return loaded and tick() >= readyAt and not potion:GetAttribute("ServerReloading")
end

-- ============================================
-- Throw
-- ============================================
local function nextProjectileId()
    local client = _G.Client
    local pc = client and client.ProjectileClass
    if pc and pc.GetProjectileId then
        local ok, id = pcall(pc.GetProjectileId)
        if ok and id then return id end
    end
    return math.floor(tick() * 1000) % 1000000
end

-- target = enemy model. The explosion position is read again after the flight time.
local function throwAt(potion, target)
    local root = rootOf(target)
    local hrp = getHRP()
    if not (root and hrp) then return false end

    local speed = potion:GetAttribute("ProjectileSpeed") or DEFAULT_SPEED
    local dist = (root.Position - hrp.Position).Magnitude
    local id = nextProjectileId()

    local ok1, r1 = invoke(Register, potion, id)
    if not ok1 then
        -- error or timeout: the server did not register the projectile, so do not explode it
        warn("[Witch] RegisterProjectile failed: " .. tostring(r1))
        task.wait(2)
        return false
    end
    task.wait(math.clamp(dist / speed, MIN_FLIGHT, MAX_FLIGHT))

    local pos = root.Position
    if target.Parent then
        local nowRoot = rootOf(target)
        if nowRoot then pos = nowRoot.Position end
    end
    invoke(Explode, pos, id)

    loaded = false
    prepare(potion, true) -- start the next reload right away

    status(string.format("Witch: HitPotion %d/%d", hitCount(), hitGoal() or 0))
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

-- cultists to throw at: includes HP-zeroed ones (the HP-zero watcher runs before the throw)
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

-- release the hover and hold the axe again (not in potion-only mode); warp = also go back to the Stronghold
local function leaveOutside(warp)
    clearFloating()
    if not M.potionOnly() then equipAxe() end
    if warp then warpBackToStronghold() end
end

-- ============================================
-- Cycles
-- ============================================
local function nearestOf(list, origin)
    local best, bestDist
    for _, m in ipairs(list) do
        local r = rootOf(m)
        if r then
            local d = (r.Position - origin).Magnitude
            if not bestDist or d < bestDist then best, bestDist = m, d end
        end
    end
    return best, bestDist
end

-- Outside: any monster, nearest first, HP untouched so it can be hit again
local function outsideCycle()
    local potion = getPotion()
    if not potion then task.wait(1) return end
    local hrp = getHRP()
    if not hrp then return end

    equip(potion)
    prepare(potion)

    local finder = _G.findNightMonsters
    local okFind, monsters = pcall(finder or function() return {} end)
    if not okFind or type(monsters) ~= "table" or #monsters == 0 then
        status("Witch: waiting for monsters")
        task.wait(1)
        return
    end

    local target = nearestOf(monsters, hrp.Position)
    if not target then task.wait(1) return end

    -- follow the target until the potion is ready
    local deadline = tick() + 20
    while tick() < deadline do
        if not (target.Parent and isAlive()) then return end
        if anyCultist() or M.isAllQuestDone() then return end
        local root = rootOf(target)
        if not root then return end
        hoverAt(root.Position + Vector3.new(0, HOVER_HEIGHT, 0))
        if isReady(potion) then break end
        if not loaded then prepare(potion, true) end
        task.wait(0.2)
    end
    if not isReady(potion) then return end

    equip(potion)
    throwAt(potion, target)
end

-- Fight: stay where the Stronghold flow put us, throw at the cultist nearest to the group centre
local function fightCycle()
    local potion = getPotion()
    local hrp = getHRP()
    if not (potion and hrp) then return end

    equip(potion) -- potion only: always hold it during the fight (no-op when already held)

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

    if not isReady(potion) then
        if not loaded then prepare(potion, true) end
        return
    end

    local target = nearestOf(inRange, centroid)
    if not target then return end

    throwAt(potion, target)
end

-- ============================================
-- Leave
-- ============================================
local lastLeaveAt = 0

local function leaveToLobby(reason)
    if tick() - lastLeaveAt < 20 then return end
    lastLeaveAt = tick()
    leaveOutside(false)
    status("Witch quest done - teleporting to Lobby")
    local fn = _G.forceTeleportLobby
    if fn then
        pcall(fn, "Witch quest complete")
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
    if not M.isWitch then return end
    if not wantsUpgrade() then
        print("[Witch] Witch is not in UpgradeClass - module idle")
        return
    end
    if not resolveRemotes() then
        warn("[Witch] Remotes unavailable")
        return
    end

    local waited = 0
    while not getPotion() and waited < 60 do
        task.wait(1)
        waited += 1
    end
    if not getPotion() then
        warn("[Witch] Witch Potion not found in Inventory")
        return
    end

    M.active = true
    print("[Witch] Loop started")
    local mode = "outside"

    while true do
        if not isAlive() then
            task.wait(1)
            continue
        end

        local goal = hitGoal()
        if not goal then
            print("[Witch] No HitPotion quest left at this level - loop ended")
            break
        end

        local fighting = anyCultist()
        local busy = fighting or roundActive() or strongholdOpen()

        if hitCount() >= goal then
            pcall(_G.WSM_QuestDone, "Witch") -- unified "[Quest] Done" line, printed once
            -- Quest complete. Outside a round: leave right away. Inside a round: play to the end,
            -- the Stronghold flow collects the diamonds, then this leaves right away.
            if not busy then
                leaveToLobby(string.format("HitPotion %d/%d reached", hitCount(), goal))
                task.wait(5)
            else
                status("Witch quest complete - finishing the round")
                task.wait(0.5)
            end
            continue
        end

        if fighting then
            if mode ~= "fight" then
                if mode == "outside" then leaveOutside(true) end
                mode = "fight"
            end
            if cfg("WitchStrongholdThrow", true) then
                local ok, err = pcall(fightCycle)
                if not ok then warn("[Witch] fight cycle error: " .. tostring(err)) end
            end
        elseif busy then
            -- Stronghold open but no cultist yet / between waves: the Stronghold flow moves the player
            if mode == "outside" then leaveOutside(false) end
            mode = "idle"
        else
            mode = "outside"
            if cfg("WitchOutsideFarm", true) then
                local ok, err = pcall(outsideCycle)
                if not ok then
                    warn("[Witch] outside cycle error: " .. tostring(err))
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
