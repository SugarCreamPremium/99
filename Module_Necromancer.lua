-- ============================================
-- Module_Necromancer.lua
-- Class implementation.
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/main/Module_Necromancer.lua
--
-- Globals (อ่านตอน load ได้เลย):
--   - LocalPlayer
--   - CLASS_QUESTS (ClassesDatabase)
--   - classStatCache (table)
-- Globals (โหลดหลัง module -> ต้องอ่านแบบ lazy):
--   - findNightMonsters (function)
--   - checkAnyCultistSpawned (function)
--   - finalGateBasePos (Vector3)
--
-- หลักการ: ไม่วาร์ปและไม่สลับไม้เท้าในระหว่างรอบ Stronghold
-- (fight loop ใช้ ToolHandle อยู่) -> ยิง remote ตรงเหมือนที่ client เกมทำ
--   soul    : Client.Events.AddSoul -> NecromancerClaimSoul:FireServer(token)
--   ชุบศพ  : RequestResurrectCultist:FireServer(corpseModel)
-- ============================================

local M = {}

local LP = _G.LocalPlayer or game:GetService("Players").LocalPlayer
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}
local CollectionService = game:GetService("CollectionService")

local function checkAnyCultistSpawned()
    local fn = _G.checkAnyCultistSpawned
    return fn and fn() or false
end

local function findNightMonsters()
    local fn = _G.findNightMonsters
    return fn and fn() or {}
end

local function isCharacterAlive()
    local character = LP.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return humanoid and humanoid.Health > 0
end

local function warpBackToStronghold()
    if not isCharacterAlive() then return end
    local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local returnPos = _G.finalGateBasePos or hrp.Position
    for _ = 1, 3 do
        hrp.CFrame = CFrame.new(returnPos + Vector3.new(0, 10, 0))
            * CFrame.Angles(math.rad(-90), 0, 0)
        task.wait(0.8)
    end
end

-- ============================================
-- Quest checks
-- ============================================
M.isNecromancer = (_G.__WSM_currentClass or "Unknown") == "Necromancer"

local function stat(key)
    local s = CSC["Necromancer"]
    return s and s[key] or 0
end

local function goal(key)
    local lvl = LP:GetAttribute("ClassLevel") or 1
    local reqs = CQ["Necromancer"] and CQ["Necromancer"][lvl + 1]
    return reqs and reqs[key]
end

function M.isCultistsResurrectedDone()
    local g = goal("CultistsResurrected")
    return not g or stat("CultistsResurrected") >= g
end

function M.isPetDamageDone()
    local g = goal("PetDamageDealt")
    return not g or stat("PetDamageDealt") >= g
end

function M.isAllQuestDone()
    return M.isCultistsResurrectedDone() and M.isPetDamageDone()
end

-- ============================================
-- Remotes
-- ============================================
local ClaimSoul, Resurrect, CommandPet, UpdatePets

-- optional remotes: ถ้าไม่มีก็ข้าม (ไม่ทำให้ loop ตาย)
local function findRemote(remotes, name)
    local ok, remote = pcall(function() return remotes:WaitForChild(name, 15) end)
    return ok and remote or nil
end

local function resolveRemotes()
    local ok, remotes = pcall(function()
        return game:GetService("ReplicatedStorage"):WaitForChild("RemoteEvents", 60)
    end)
    if not ok or not remotes then return false end

    ClaimSoul = findRemote(remotes, "NecromancerClaimSoul")
    Resurrect = findRemote(remotes, "RequestResurrectCultist")
    CommandPet = findRemote(remotes, "CommandPet")
    UpdatePets = findRemote(remotes, "UpdateOwnedPets")
    return ClaimSoul ~= nil and Resurrect ~= nil
end

local function getClient()
    if _G.Client then return _G.Client end
    local ok, client = pcall(function()
        return require(LP.PlayerScripts:WaitForChild("Client", 30))
    end)
    return ok and client or nil
end

-- ============================================
-- Souls
-- ============================================
local soulsCount = function()
    return LP:GetAttribute("NecromancerSouls") or 0
end

-- shortcut: assume claim ไม่เช็คระยะ; ถ้าไม่ขึ้น souls ติดกัน 2 ครั้งจะสลับเป็น warp mode
local soulWarpMode = false
local claimFails = 0

local function setupSoulHook()
    local Client = getClient()
    if not Client or not Client.Events then
        warn("[Necromancer] Client.Events unavailable, souls disabled")
        return false
    end
    Client.Events.AddSoul:Connect(function(pos, token)
        task.spawn(function()
            if soulWarpMode and not checkAnyCultistSpawned() and isCharacterAlive() then
                local hrp = LP.Character:FindFirstChild("HumanoidRootPart")
                if hrp and typeof(pos) == "Vector3" then
                    hrp.CFrame = CFrame.new(pos)
                    task.wait(0.4)
                end
            end
            local before = soulsCount()
            pcall(function() ClaimSoul:FireServer(token) end)
            if not soulWarpMode then
                task.wait(0.5)
                if soulsCount() == before then
                    claimFails = claimFails + 1
                    if claimFails >= 2 then
                        soulWarpMode = true
                        print("[Necromancer] Soul claim needs proximity, switching to warp mode")
                    end
                else
                    claimFails = 0
                end
            end
        end)
    end)
    return true
end

-- ============================================
-- Resurrection
-- ============================================
local RESURRECT_COOLDOWN = 2.2  -- ไม้เท้าเกมล็อก 2 วิหลังชุบ (NecromancerStaff.lua:190-192)
local lastResurrect = 0
-- shortcut: assume server ไม่เช็คระยะ; ถ้าชุบไม่ติด 2 ครั้งจะเริ่มวาร์ปไปที่ศพก่อนยิง
local resurrectWarpMode = false
local resurrectFails = 0

local function corpseRoot(model)
    return model.PrimaryPart
        or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChildWhichIsA("BasePart", true)
end

local function nearestCorpse()
    local myPos = LP.Character and LP.Character:GetPivot().Position
    local best, bestDist
    for _, model in ipairs(CollectionService:GetTagged("CultistCorpse")) do
        if model.Parent and model:GetAttribute("Resurrected") ~= true
            and model:GetAttribute("SoulsRequired") then
            local root = corpseRoot(model)
            if root then
                local dist = myPos and (root.Position - myPos).Magnitude or 0
                if not bestDist or dist < bestDist then
                    best, bestDist = model, dist
                end
            end
        end
    end
    return best
end

local function releaseOnePet()
    if not CommandPet then return false end
    for _, model in ipairs(CollectionService:GetTagged("TamedAnimal_" .. LP.UserId)) do
        if model.Parent and model:GetAttribute("Resurrected") == true then
            pcall(function() CommandPet:FireServer(model, "Release") end)
            if UpdatePets then pcall(function() UpdatePets:InvokeServer() end) end
            return true
        end
    end
    return false
end

local function tryResurrect()
    if os.clock() - lastResurrect < RESURRECT_COOLDOWN then return end
    local corpse = nearestCorpse()
    if not corpse then return end

    local need = corpse:GetAttribute("SoulsRequired") or 3
    if soulsCount() < need then return end

    local maxPets = LP:GetAttribute("MaxPets") or 6
    if (LP:GetAttribute("CurrentPets") or 0) >= maxPets then
        if not releaseOnePet() then return end
        task.wait(0.6)
        if (LP:GetAttribute("CurrentPets") or 0) >= maxPets then return end
    end

    if resurrectWarpMode and isCharacterAlive() then
        local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        local root = corpseRoot(corpse)
        if hrp and root then
            hrp.CFrame = CFrame.new(root.Position + Vector3.new(0, 5, 0))
            task.wait(0.3)
        end
    end

    lastResurrect = os.clock()
    local beforeSouls = soulsCount()
    pcall(function() Resurrect:FireServer(corpse) end)

    if not resurrectWarpMode then
        task.wait(0.8)
        -- server หัก soul ตอนชุบสำเร็จ -> soul ไม่ลด = โดนปฏิเสธ
        if soulsCount() == beforeSouls then
            resurrectFails = resurrectFails + 1
            if resurrectFails >= 2 then
                resurrectWarpMode = true
                print("[Necromancer] Resurrect needs proximity, switching to warp mode")
            end
        else
            resurrectFails = 0
        end
    end
end

-- ============================================
-- Pet damage (best effort - client สั่งให้ pet ตีไม่ได้)
-- ============================================
local lastPetWarp = 0
local PET_WARP_COOLDOWN = 15  -- ไม่วาร์ปถี่กว่านี้ (กันดึงตัวละครออกจาก Stronghold)

local function petDamageIdle()
    if os.clock() - lastPetWarp < PET_WARP_COOLDOWN then return end
    if checkAnyCultistSpawned() then return end
    if (LP:GetAttribute("CurrentPets") or 0) == 0 then return end
    if workspace:GetAttribute("State") ~= "Night" then return end

    local monsters = findNightMonsters()
    local target = monsters[1]
    if not target then return end

    local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    local root = target:FindFirstChild("HumanoidRootPart") or target.PrimaryPart
    if not (hrp and root) then return end

    -- ไม่ zeroEnemyHealth: ปล่อยให้ pet ตีเลือดจริงเพื่อให้ PetDamageDealt ขึ้น
    lastPetWarp = os.clock()
    hrp.CFrame = CFrame.new(root.Position + Vector3.new(0, 10, 0))
end

-- ============================================
-- Loop
-- ============================================
local running = false

function M.mainLoop()
    if not M.isNecromancer then return end
    if not resolveRemotes() then
        warn("[Necromancer] Remotes unavailable")
        return
    end
    if not setupSoulHook() then return end

    print("[Necromancer] Loop started")
    -- ไม่ exit ตอนตาย: รอ respawn แล้วทำต่อ (ไม่มี resume() ให้เรียกจาก Stronghold)
    while not M.isAllQuestDone() do
        if isCharacterAlive() then
            tryResurrect()
            petDamageIdle()
        end
        task.wait(0.3)
    end
    print("[Necromancer] Loop ended")
    if isCharacterAlive() then warpBackToStronghold() end
end

function M.runBackground()
    if running then return end
    running = true
    task.spawn(function()
        M.mainLoop()
        running = false
    end)
end

return M
