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
local Players = game:GetService("Players")
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

-- Cultist ข้างนอก Stronghold = ตัวที่ทิ้งศพให้ชุบ
-- (Stronghold wave ให้ soul แต่ไม่ทิ้งศพ -> กรอง StrongholdEnemy ออก)
-- ทำงานเฉพาะตอน Stronghold ไม่ได้ตีอยู่ (petDamageIdle การ์ด strongholdBusy ไว้แล้ว)
local function findWildCultists()
    local list = {}
    local chars = workspace:FindFirstChild("Characters")
    if not chars then return list end
    for _, m in ipairs(chars:GetChildren()) do
        if m:IsA("Model")
            and string.find(m.Name, "Cultist")
            and m:GetAttribute("StrongholdEnemy") ~= true
            and m:GetAttribute("Resurrected") ~= true
            and m:GetAttribute("NotAttackable") ~= true
            and not Players:GetPlayerFromCharacter(m)
            and not (m:HasTag("Friendly") or m:HasTag("Pet") or m:HasTag("Ally"))
        then
            local hum = m:FindFirstChildOfClass("Humanoid")
                or m:FindFirstChildWhichIsA("Humanoid", true)
            if hum and hum.Parent and hum.Health > 0 then
                table.insert(list, m)
            end
        end
    end
    return list
end

-- ตัวใกล้สุดก่อน (กันบินข้ามแมพไปหาตัวไกลทั้งที่ตัวใกล้กว่า)
local function nearestModel(list)
    local myPos = LP.Character and LP.Character:GetPivot().Position
    if not myPos then return list[1] end
    local best, bestDist
    for _, m in ipairs(list) do
        local root = m.PrimaryPart or m:FindFirstChild("HumanoidRootPart")
        if root then
            local dist = (root.Position - myPos).Magnitude
            if not bestDist or dist < bestDist then
                best, bestDist = m, dist
            end
        end
    end
    return best or list[1]
end

-- Stronghold: OpenTime คือเวลาเปิดรอบถัดไป (วินาที server)
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

-- Stronghold เปิด/กำลังตี = ห้ามฟาร์ม pet ต้องเคลียร์ Stronghold ให้จบก่อน
-- latch: เริ่มรอบเมื่อ OpenTime เปลี่ยน -> busy จนจบรอบ (OpenTime ถูกตั้งใหม่เมื่อเคลียร์รอบ)
local openCycle, busy = nil, false
local function strongholdBusy()
    local openTime = strongholdOpenTime()
    if openTime ~= openCycle then
        openCycle = openTime
        busy = openTime ~= nil and workspace:GetServerTimeNow() >= openTime
    end
    if checkAnyCultistSpawned() then busy = true end
    return busy
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

-- pet ที่ยังมีชีวิต: โมเดล pet มี Humanoid เป็น child ชื่อ "NPC" (EnemyHandler อ่านแบบนี้)
local function petAliveCount()
    local alive = 0
    for _, model in ipairs(CollectionService:GetTagged("TamedAnimal_" .. LP.UserId)) do
        if model.Parent and model:GetAttribute("Dead") ~= true then
            local npc = model:FindFirstChild("NPC")
            local hum = (npc and npc:IsA("Humanoid") and npc)
                or model:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                alive = alive + 1
            end
        end
    end
    return alive
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
local ClaimSoul, Resurrect, CommandPet, UpdatePets, SummonAllPets

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
    SummonAllPets = findRemote(remotes, "RequestSummonAllPets")
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

    -- วาร์ปไปชุบเฉพาะตอน Stronghold ไม่ได้ตีอยู่ (ระหว่างตี Stronghold loop คุมตำแหน่งตัวอยู่)
    if resurrectWarpMode and not strongholdBusy() and isCharacterAlive() then
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
local PET_SUMMON_COOLDOWN = 5    -- วิ กันยิง RequestSummonAllPets รัวเกิน
local lastPetSummon = 0

-- pet ไม่วาร์ปตามทันที -> ต้องเรียกกลับมาหาตัวก่อนตีทุกครั้ง
local function summonPets()
    if not SummonAllPets then return end
    if os.clock() - lastPetSummon < PET_SUMMON_COOLDOWN then return end
    lastPetSummon = os.clock()
    pcall(function() SummonAllPets:FireServer() end)
    task.wait(2.5)  -- ให้ pet เดินมาถึงก่อนเริ่มตี
end

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

    -- Cultist ก่อน = ฆ่าแล้วได้ศพไปชุบ; ไม่มีค่อยไปตีมอนกลางคืนเอา PetDamage
    local monster, mustKill = nearestModel(findWildCultists()), true
    if not monster then
        monster, mustKill = nearestModel(findNightMonsters()), false
    end
    if not monster then return end
    local root = monster:FindFirstChild("HumanoidRootPart") or monster.PrimaryPart
    if not root then return end

    local lastHP = monsterHP(monster)
    if not lastHP or lastHP <= 0 then return end

    pcall(function() Client.InventoryHandler.RequestEquipItem(weapon) end)
    task.wait(0.3)
    ensureFloating()

    -- วาร์ปไปถึงมอนก่อน แล้วเรียก pet ให้ตามมา (1 ครั้งต่อ 1 มอน)
    local hrp0 = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if hrp0 then
        hrp0.CFrame = CFrame.new(root.Position + Vector3.new(0, 10, 0))
            * CFrame.Angles(math.rad(-90), 0, 0)
    end
    summonPets()

    local deadline = os.clock() + PET_SESSION_TIMEOUT
    local lastDropAt = os.clock()
    local lastHit = 0

    while os.clock() < deadline and monster.Parent and isCharacterAlive() do
        -- Stronghold เปิด/มี Cultist = เลิกตีมอนทันที ไปเคลียร์ Stronghold ก่อน
        if strongholdBusy() then break end
        -- pet ตายหมด = ตีต่อไม่ได้ดาเมจให้ pet แล้ว จบ session ไปวาร์ปกลับ
        if petAliveCount() == 0 then break end

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
            -- เลือดไม่ลดเลย = pet ตีไม่ติด -> ตีใหม่อีกรอบ + เรียก pet กลับมา
            local w = getMeleeWeapon() or weapon
            pcall(function() Client.InventoryHandler.RequestEquipItem(w) end)
            task.wait(0.3)
            summonPets()
            lastDropAt = os.clock()
        end

        -- Cultist ต้องตายจริงถึงจะทิ้งศพ (เลือด 0 = ตายปลอมในเกมนี้) -> ตีซ้ำอีกครั้ง
        if mustKill and monster.Parent then
            local h = monsterHP(monster)
            if h and h <= 0 then
                local w = getMeleeWeapon() or weapon
                pcall(function() Event:InvokeServer(monster, w, ownerId, hrp.CFrame, false) end)
            end
        end

        task.wait(0.5)
    end
    stopFloating()

    -- pet ตายหมดระหว่างตี = ไม่มีอะไรทำต่อ กลับไปรอที่ Stronghold
    -- (Stronghold เปิดอยู่ = Stronghold loop วาร์ปเองอยู่แล้ว ไม่ต้องแย่งวาร์ป)
    if not strongholdBusy() and petAliveCount() == 0 then
        print("[Necromancer] All pets dead - returning to Stronghold")
        warpBackToStronghold()
    end
end

local function petDamageIdle()
    if petBusy then return end
    -- Stronghold เปิด/กำลังตี = ห้ามออกไปตีมอน ให้เคลียร์ Stronghold ก่อน
    if strongholdBusy() then return end
    if (LP:GetAttribute("CurrentPets") or 0) == 0 then return end
    if petAliveCount() == 0 then return end
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
