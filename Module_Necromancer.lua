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
-- ตัวที่เพิ่งตีปิดยืนยันแล้ว = รอ tag CultistCorpse มาจาก server ก่อน ห้ามเลือกซ้ำ
local deadUntil = setmetatable({}, { __mode = "k" })
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
            and m:GetAttribute("Dead") ~= true
            and m:GetAttribute("Resource") ~= "IceBlock"  -- ก้อนน้ำแข็ง = ไม่ใช่เป้า (ตีเท่าไรก็ไม่ตาย)
            and not m:HasTag("IceBlock")
            and not m:HasTag("CultistCorpse")  -- ตายแล้ว = ศพ ไม่ใช่เป้าตี
            and not (deadUntil[m] and os.clock() < deadUntil[m])
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
local lastSoulShortLog = 0

local function corpseRoot(model)
    return model.PrimaryPart
        or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChildWhichIsA("BasePart", true)
end

-- เลือกศพที่ soul พอชุบก่อน (ถ้ามี) แล้วค่อยเอาตัวใกล้สุด
-- ไม่งั้นศพแพงที่อยู่ใกล้จะบล็อกศพถูกที่ soul พอ ทั้งที่ชุบได้
local function nearestCorpse()
    local myPos = LP.Character and LP.Character:GetPivot().Position
    local souls = soulsCount()
    local best, bestDist, nearestAny, nearestDist
    for _, model in ipairs(CollectionService:GetTagged("CultistCorpse")) do
        if model.Parent and model:GetAttribute("Resurrected") ~= true
            and model:GetAttribute("SoulsRequired") then
            local root = corpseRoot(model)
            if root then
                local dist = myPos and (root.Position - myPos).Magnitude or 0
                if not nearestDist or dist < nearestDist then
                    nearestAny, nearestDist = model, dist
                end
                if souls >= (model:GetAttribute("SoulsRequired") or 3)
                    and (not bestDist or dist < bestDist) then
                    best, bestDist = model, dist
                end
            end
        end
    end
    return best or nearestAny
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
    if soulsCount() < need then
        -- soul ไม่พอ = ชุบไม่ได้ (1 ตัวใช้ need souls) -> บอกไว้ ไม่ให้ดูเหมือนค้างเงียบๆ
        -- แล้วไปตี Cultist ต่อเอง (petDamageSession จะได้ไม่ต้องเดา)
        if os.clock() - lastSoulShortLog > 30 then
            lastSoulShortLog = os.clock()
            print(string.format("[Necromancer] Not enough souls - have=%d need=%d",
                soulsCount(), need))
        end
        return
    end

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
local HIT_INTERVAL = 0.2         -- วิ ระหว่างตีตอนไม่มี pet (ลดเลือดเองแล้วตีเอง)
local HIT_INTERVAL_PET = 1       -- วิ ระหว่างตีตอนมี pet (แค่ตีเบาๆ ให้ pet เข้าร่วม)
local ZERO_WAIT = 1              -- วิ รอหลังลดเลือด ก่อนเริ่มตี (ให้ server apply ก่อน)
local lastPetSummon = 0
local lastNoTargetLog = 0

-- pet ไม่วาร์ปตามทันที -> ต้องเรียกกลับมาหาตัวก่อนตีทุกครั้ง
-- ไม่รอให้ pet เดินมาถึง: ตีเองได้ทันที ส่วน pet ค่อยตามมาสมทบระหว่างตี
local function summonPets()
    if not SummonAllPets then return end
    if os.clock() - lastPetSummon < PET_SUMMON_COOLDOWN then return end
    lastPetSummon = os.clock()
    pcall(function() SummonAllPets:FireServer() end)
end

local function monsterHP(model)
    -- เกมนี้เก็บเลือด NPC ไว้ที่ attribute "Health" บนโมเดล (EnemyHandler.lua:370)
    -- Humanoid.Health เป็นแค่ค่าที่ server sync มา -> อ่าน attribute ก่อน
    local attr = model:GetAttribute("Health")
    if attr then return attr end
    local hum = model:FindFirstChildOfClass("Humanoid")
        or model:FindFirstChildWhichIsA("Humanoid", true)
    if hum then return hum.Health end
    return nil
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
        -- มอนกลางคืน: กรองศพ/ตัวที่เพิ่งตีปิดออกด้วย (findNightMonsters ไม่รู้จัก CultistCorpse)
        local alive = {}
        for _, m in ipairs(findNightMonsters()) do
            if not m:HasTag("CultistCorpse")
                and m:GetAttribute("Dead") ~= true
                and not (deadUntil[m] and os.clock() < deadUntil[m]) then
                table.insert(alive, m)
            end
        end
        monster, mustKill = nearestModel(alive), false
    end
    if not monster then
        -- ไม่มีเป้าเลย = บอกสาเหตุไว้ (wild = 0 เพราะติด StrongholdEnemy หรือยังไม่มีศพ)
        if os.clock() - lastNoTargetLog > 30 then
            lastNoTargetLog = os.clock()
            print(string.format("[Necromancer] No target - wild=%d night=%d souls=%d pets=%d",
                #findWildCultists(), #findNightMonsters(), soulsCount(),
                petAliveCount()))
        end
        return
    end
    local root = monster:FindFirstChild("HumanoidRootPart") or monster.PrimaryPart
    if not root then return end

    local lastHP = monsterHP(monster)
    if not lastHP then return end

    -- วาร์ปก่อนเลย (ไม่รอ equip) แล้วค่อยถือขวาน+เรียก pet
    local hrp0 = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if hrp0 then
        hrp0.CFrame = CFrame.new(root.Position + Vector3.new(0, 10, 0))
            * CFrame.Angles(math.rad(-90), 0, 0)
    end
    pcall(function() Client.InventoryHandler.RequestEquipItem(weapon) end)
    task.wait(0.15)
    ensureFloating()
    summonPets()

    local deadline = os.clock() + PET_SESSION_TIMEOUT
    local lastDropAt = os.clock()
    local zeroed = false   -- ลดเลือดไปแล้วหรือยัง (รอ ZERO_WAIT ครั้งเดียวต่อ session)

    while os.clock() < deadline and monster.Parent and isCharacterAlive() do
        -- Stronghold เปิด/มี Cultist = เลิกตีมอนทันที ไปเคลียร์ Stronghold ก่อน
        if strongholdBusy() then break end
        -- pet ตายหมด = ตีต่อไม่ได้ดาเมจให้ pet แล้ว จบ session ไปวาร์ปกลับ
        -- (แต่ถ้าเป้าคือ Cultist ยังต้องตีเองต่อ เพื่อเก็บ soul มาชุบ pet)
        if not mustKill and petAliveCount() == 0 then break end
        -- กลายเป็นศพแล้ว (tag/Dead) = ไม่มีอะไรให้ตี จบ session ไปชุบทันที
        if monster:HasTag("CultistCorpse") or monster:GetAttribute("Dead") == true then
            deadUntil[monster] = os.clock() + 5  -- กันเลือกซ้ำก่อน tag จาก server มา
            break
        end

        local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        local r = monster:FindFirstChild("HumanoidRootPart") or monster.PrimaryPart
        if not (hrp and r) then break end

        hrp.CFrame = CFrame.new(r.Position + Vector3.new(0, 10, 0))
            * CFrame.Angles(math.rad(-90), 0, 0)

        -- ไม่มี pet = วาร์ปมาแล้ว ลดเลือด รอ 1 วิ แล้วตีรัว 0.2 วิจนตาย (แบบ module อื่น)
        -- มี pet = ปล่อยเลือดไว้ให้ pet ตีเก็บ PetDamageDealt ตีแค่ 1 วิ/ครั้ง
        -- อ่าน petAliveCount() ไม่ใช่ CurrentPets: attribute ดีเลย์, pet ตายแล้วค้างค่าเดิมได้
        local hasPets = petAliveCount() > 0
        if not hasPets then
            pcall(function() _G.zeroEnemyHealth(monster) end)
            if not zeroed then
                zeroed = true
                task.wait(ZERO_WAIT)   -- รอครั้งเดียว ไม่ใช่ทุก tick
            end
        end

        local w = getMeleeWeapon() or weapon
        pcall(function() Event:InvokeServer(monster, w, ownerId, hrp.CFrame, false) end)

        local hp = monsterHP(monster)
        if hp and hp < lastHP then
            lastHP = hp
            lastDropAt = os.clock()
        elseif os.clock() - lastDropAt > PET_NO_DAMAGE_LIMIT then
            -- เลือดไม่ลดเลย = pet ตีไม่ติด -> ถือขวานใหม่ + เรียก pet กลับมา
            pcall(function() Client.InventoryHandler.RequestEquipItem(w) end)
            summonPets()
            lastDropAt = os.clock()
        end

        task.wait(hasPets and HIT_INTERVAL_PET or HIT_INTERVAL)
    end
    stopFloating()

    -- pet ตายหมดระหว่างตี = ยังอยู่ที่เดิม ปล่อยให้ loop ถัดไปหาเป้าใหม่เอง
    -- (ห้ามวาร์ปกลับ Stronghold: จะเด้งกลับทุกครั้งที่ตีได้ 1 ตัว แล้วเริ่มใหม่ไม่จบ)
end

local function petDamageIdle()
    if petBusy then return end
    if strongholdBusy() then
        -- Stronghold: MainScript ไม่ลดเลือดมอนแล้วถ้า Necromancer ยังไม่ Lv.3 (รอ pet ตีเก็บ PetDamage)
        -- แต่ fight loop วาร์ปข้ามทีละ Cultist -> pet เดินตามไม่ทัน ต้องเรียกมาที่ตัวเป็นระยะ
        if petAliveCount() > 0 then task.spawn(summonPets) end
        return
    end
    -- ไม่มี pet ก็ต้องออกไปตีเอง ไม่งั้นตอนเริ่มคลาส (CurrentPets = 0) จะไม่เคยออกไปเลย
    -- = ไม่มีทางได้ soul = ไม่มีทางได้ศพ = ไม่มีทางได้ pet (deadlock)
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
