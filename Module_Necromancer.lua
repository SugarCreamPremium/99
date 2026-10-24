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
    -- ปล่อย pet ที่ไม่ได้ชุบมาก่อน (Halloween/สัตว์เลี้ยงอื่น) เก็บ cultist ที่ชุบไว้ตี
    local fallback
    for _, model in ipairs(CollectionService:GetTagged("TamedAnimal_" .. LP.UserId)) do
        if model.Parent then
            if model:GetAttribute("Resurrected") ~= true then
                pcall(function() CommandPet:FireServer(model, "Release") end)
                if UpdatePets then pcall(function() UpdatePets:InvokeServer() end) end
                return true
            end
            fallback = fallback or model
        end
    end
    if fallback then
        pcall(function() CommandPet:FireServer(fallback, "Release") end)
        if UpdatePets then pcall(function() UpdatePets:InvokeServer() end) end
        return true
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
-- Pet damage (ระหว่างรอ Stronghold เปิด)
-- client สั่งให้ pet ตีไม่ได้ -> ต้องเข้าตีเองเพื่อให้ pet เข้าร่วม แล้วรอเลือดลด
-- ห้าม zeroEnemyHealth เด็ดขาด (เลือด 0 = pet ไม่มีอะไรให้ตี)
-- ============================================
local petBusy = false
local PET_SESSION_TIMEOUT = 30   -- วิ ต่อมอน 1 ตัว
local PET_NO_DAMAGE_LIMIT = 10   -- วิ ที่เลือดไม่ลด = pet ตีไม่ติด -> ตีใหม่

local function monsterHP(model)
    local hum = model:FindFirstChildOfClass("Humanoid")
        or model:FindFirstChildWhichIsA("Humanoid", true)
    if hum then return hum.Health end
    return model:GetAttribute("Health")
end

local function stopFloating()
    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    for _, name in ipairs({ "FloatAlignPosition", "FloatAlignOrientation", "FloatAttachment" }) do
        local obj = hrp:FindFirstChild(name)
        if obj then pcall(function() obj:Destroy() end) end
    end
end

-- Necromancer ไม่มี axe ในชุดคลาส -> ต้องหาขวานจริงจาก Inventory (ไม้เท้าไม่ทำดาเมจ)
local function getMeleeWeapon()
    local inv = LP:FindFirstChild("Inventory")
    if inv then
        local best, bestDmg = nil, -1
        for _, tool in ipairs(inv:GetChildren()) do
            if tool:GetAttribute("ToolName") == "GenericAxe" then
                local dmg = tool:GetAttribute("WeaponDamage") or 0
                if dmg > bestDmg then best, bestDmg = tool, dmg end
            end
        end
        if best then return best end
    end
    return _G.bestAxeCombat
end

local function petDamageSession()
    local Event = _G.Event
    local ownerId = _G.ownerId
    local ensureFloating = _G.ensureFloating
    local Client = getClient()
    if not (Event and ownerId and ensureFloating and Client) then return end

    local weapon = getMeleeWeapon()
    if not weapon then return end

    local monster = findNightMonsters()[1]
    if not monster then return end
    local root = monster:FindFirstChild("HumanoidRootPart") or monster.PrimaryPart
    if not root then return end

    local lastHP = monsterHP(monster)
    if not lastHP or lastHP <= 0 then return end

    pcall(function() Client.InventoryHandler.RequestEquipItem(weapon) end)
    task.wait(0.3)
    ensureFloating()

    local deadline = os.clock() + PET_SESSION_TIMEOUT
    local lastDropAt = os.clock()
    local lastHit = 0

    while os.clock() < deadline and monster.Parent and isCharacterAlive() do
        if checkAnyCultistSpawned() then break end

        local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        local r = monster:FindFirstChild("HumanoidRootPart") or monster.PrimaryPart
        if not (hrp and r) then break end

        hrp.CFrame = CFrame.new(r.Position + Vector3.new(0, 10, 0))
            * CFrame.Angles(math.rad(-90), 0, 0)

        if os.clock() - lastHit >= 1 then
            lastHit = os.clock()
            local w = getMeleeWeapon() or weapon
            pcall(function() Event:InvokeServer(monster, w, ownerId, hrp.CFrame, false) end)
        end

        local hp = monsterHP(monster)
        if hp and hp < lastHP then
            lastHP = hp
            lastDropAt = os.clock()
        elseif os.clock() - lastDropAt > PET_NO_DAMAGE_LIMIT then
            -- เลือดไม่ลดเลย = pet ตีไม่ติด -> ตีใหม่อีกรอบ
            local w = getMeleeWeapon() or weapon
            pcall(function() Client.InventoryHandler.RequestEquipItem(w) end)
            task.wait(0.3)
            lastDropAt = os.clock()
        end

        task.wait(0.5)
    end
    stopFloating()
end

local function petDamageIdle()
    if petBusy then return end
    if checkAnyCultistSpawned() then return end
    if (LP:GetAttribute("CurrentPets") or 0) == 0 then return end
    petBusy = true
    task.spawn(function()
        pcall(petDamageSession)
        petBusy = false
    end)
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
