-- ============================================
-- Module_Stronghold.lua / 9.39
-- Stronghold fight, chest, round, and reset flow.
-- ============================================

local M = {}

function M.run(C)
    local LocalPlayer = C.LocalPlayer
    local ReplicatedStorage = C.ReplicatedStorage
    local RunService = C.RunService
    local Client = C.Client
    local Event = C.Event
    local ownerId = C.ownerId
    local Config = C.Config
    local CLASS_QUESTS = C.CLASS_QUESTS
    local classStatCache = C.classStatCache
    local bestAxeCombat = C.bestAxeCombat
    local axe = C.axe
    local vampireScythe = C.vampireScythe
    local cannonTool = C.cannonTool
    local useCannon = C.useCannon
    local isVampire = C.isVampire
    local isAlienScientist = C.isAlienScientist
    local isAlienScientistAllQuestDone = C.isAlienScientistAllQuestDone
    local isVampireAllQuestDone = C.isVampireAllQuestDone
    local Vampire = C.Vampire
    local Alien = C.Alien
    local BGH = C.BGH
    local Woodsman = C.Woodsman
    local firePos = C.firePos
    local platform = C.platform
    local strongholdFloorPos = C.strongholdFloorPos
    local finalGateBasePos = C.finalGateBasePos
    local destroyShield = C.destroyShield
    local retryUntil = C.retryUntil
    local updateStatus = C.updateStatus
    local forceTeleportLobby = C.forceTeleportLobby
    local sendHorstDescription = C.sendHorstDescription
    local checkDiamondsGoalAndSendDone = C.checkDiamondsGoalAndSendDone
    local getLiveParts = C.getLiveParts
    local getStrongholdTimeRemaining = C.getStrongholdTimeRemaining
    local getFloorInfo = C.getFloorInfo
    local warpToTriggerZone = C.warpToTriggerZone
    local warpToStrongholdFloor = C.warpToStrongholdFloor
    local isStrongholdEnemy = C.isStrongholdEnemy
    local zeroEnemyHealth = C.zeroEnemyHealth

-- ============================================
-- STEP 6: Fight loop - วาร์ปเข้าไปหา Cultist "ทุกตัว" ทีละตัว ปรับเลือดแล้วตีตัวนั้นจากจุดใกล้
-- ทำครบรอบแล้วตัวไหนยังไม่ตาย = วนทำใหม่อีกรอบ ครบ 2 รอบเต็มยังไม่ตาย
-- = โหมดเก็บตาย: วาร์ป + ปรับเลือดเร็วก่อน "ทุกตี" (ไม่ต้องรอ) ตีซ้ำจนตาย
-- ============================================

print("\n[Step 6] Fighting Cultists in Stronghold...")
updateStatus("Fighting Cultists...")

-- Re-equip axe ก่อนเริ่ม fight เผื่อถูก unequip ระหว่างรอ
do
    Client.InventoryHandler.RequestEquipItem(bestAxeCombat)
    local waited = 0
    while waited < 3 do
        local char = LocalPlayer.Character
        local th = char and char:FindFirstChild("ToolHandle")
        if th and th:FindFirstChild("OriginalItem") then
            axe = th.OriginalItem.Value
            break
        end
        task.wait(0.1)
        waited += 0.1
    end
end

local liveHrp = getLiveParts()
local combatCenter = strongholdFloorPos or (liveHrp and liveHrp.Position) or Vector3.zero
local HOVER_HEIGHT = 10       -- ระยะมาตรฐาน: ลอย/วาร์ป "ด้านบน" ของมอน 10 studs (หันหน้าลง)
local ATTACK_INTERVAL = 0.1

-- นับว่า Cultist ตัวไหน "รอด" จาก [วาร์ปเข้าใกล้ + ปรับเลือด + รอ + ตี] ไปแล้วกี่รอบ (weak key กัน memory leak)
-- ครบ FINISH_MODE_AFTER รอบแล้วยังไม่ตาย = เข้าโหมดเก็บตาย: วาร์ป + ปรับเลือดเร็ว (ไม่รอ) + ตี ซ้ำจนตาย
local surviveCounts = setmetatable({}, {__mode = "k"})
local FINISH_MODE_AFTER = 2

-- เช็คมอนที่จะตี: ดูจาก attribute "StrongholdEnemy" บนโมเดลใน workspace.Characters โดยตรง
-- (ยกเลิกการเช็คชื่อ/ระยะ/Floor เดิมทั้งหมด - เชื่อ flag ที่เกม stamp ไว้บนตัวโมเดลเอง)
local function findCultists()
    local list = {}
    local chars = workspace:FindFirstChild("Characters")
    if not chars then return list end
    for _, c in ipairs(chars:GetChildren()) do
        if c.Name == "Deer" then continue end -- Deer ไม่ตี/ไม่ลดเลือด (จัดการโดย Deer Watcher)
        if isStrongholdEnemy(c) then
            local root = c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart")
            local hum = c:FindFirstChildOfClass("Humanoid")
                or c:FindFirstChildWhichIsA("Humanoid", true)
            -- ไม่กรอง Health > 0: เลือด 0 = ตายปลอม ต้องตีต่ออีก 1 รอบถึงตายจริง
            if root and hum then
                table.insert(list, c)
            end
        end
    end
    return list
end

-- ลอยแบบ IY Fly (ไม่ hard-lock): ติด BodyVelocity บน HRP คนเดียวพอ
-- ตัวละครยังเป็น "ปกติ" - มี animation ฟิสิกส์ทำงาน แค่ลอยนิ่งไม่ตก
-- (เดิมใช้ PlatformStand + เคลียร์ velocity ทุกเฟรม = แข็งค้างเป็นหุ่น)
local flyBodyVelocity

local function ensureFlyBody(hrp)
    if not hrp then return end
    -- HRP เปลี่ยนไหม (ตายเกิดใหม่) ถ้าเปลี่ยนสร้างติดใหม่อัตโนมัติ
    if not flyBodyVelocity or not flyBodyVelocity.Parent then
        flyBodyVelocity = Instance.new("BodyVelocity")
        flyBodyVelocity.Name = "SugarHubHover"
        flyBodyVelocity.MaxForce = Vector3.new(9e9, 9e9, 9e9)
        flyBodyVelocity.Velocity = Vector3.zero -- ลอยนิ่ง - แรงนี้สู้แรงโน้มถ่วงเอง
        flyBodyVelocity.Parent = hrp
    end
end

local function destroyFlyBody()
    if flyBodyVelocity then
        flyBodyVelocity:Destroy()
        flyBodyVelocity = nil
    end
end

local lockConn
lockConn = RunService.Heartbeat:Connect(function()
    local hrp = getLiveParts()
    ensureFlyBody(hrp)
end)

-- Stronghold เคลียร์แล้ว = ตำแหน่ง FinalGate เปลี่ยนจากที่จับไว้ตอนแรก
local GATE_MOVE_THRESHOLD = 1     -- ขยับเกิน 1 stud ถือว่าเปลี่ยนจริง
local CLEAR_CONFIRM_COUNT = 3     -- อ่านติดกัน 3 ครั้ง กันค่ากระพริบ
local FIGHT_MIN_SECONDS = 10      -- 10 วิแรกไม่ตรวจ กันประตูขยับตอนเปิดด่าน

local function getFinalGatePart()
    local gate = workspace:FindFirstChild("FinalGate", true)
    if not gate then return nil end
    if gate:IsA("BasePart") then return gate end
    if gate:IsA("Model") then
        return gate.PrimaryPart or gate:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

local fightStart = os.clock()
local clearHits = 0
local gateOrigin = nil

do
    local part = getFinalGatePart()
    if part then gateOrigin = part.Position end
end

local function isStrongholdCleared()
    if os.clock() - fightStart < FIGHT_MIN_SECONDS then
        return false
    end

    local part = getFinalGatePart()
    if not part then
        clearHits = 0
        return false
    end

    -- ถ้าจับตำแหน่งแรกไม่ทัน (ประตู stream มาช้า) จับตอนนี้แล้วเริ่มนับใหม่
    if not gateOrigin then
        gateOrigin = part.Position
        clearHits = 0
        return false
    end

    if (part.Position - gateOrigin).Magnitude > GATE_MOVE_THRESHOLD then
        clearHits = clearHits + 1
    else
        clearHits = 0
    end

    return clearHits >= CLEAR_CONFIRM_COUNT
end

local TOTAL_ROUNDS = 3
local completedRounds = 0

local function doOneRound()
    fightStart = os.clock()
    clearHits = 0
    -- ใช้ตำแหน่ง gate ตอน Stronghold ยังปิด (จับไว้แล้วตอน Step 3.6)
    gateOrigin = finalGateBasePos

    -- รอ Cultist เกิด
    do
        local floorCenter2 = getFloorInfo()
        local floorPos2 = floorCenter2 and (floorCenter2 + Vector3.new(0, 10, 0))

        local function anyCultistSpawned()
            local chars = workspace:FindFirstChild("Characters")
            if not chars then return false end
            for _, c in ipairs(chars:GetChildren()) do
                -- เช็คจาก attribute StrongholdEnemy บนโมเดล (ไม่ใช้ชื่อ/ตำแหน่งแล้ว)
                if isStrongholdEnemy(c) and c:FindFirstChildOfClass("Humanoid") then
                    return true
                end
            end
            return false
        end

        local waited = 0
        local WAIT_STEP = 0.2
        local SPAWN_TIMEOUT = 8
        while not anyCultistSpawned() do
            task.wait(WAIT_STEP)
            waited += WAIT_STEP
            -- อัปเดต countdown ทุก 0.2s (เมื่อ Stronghold ยังไม่เปิด) — ไม่ re-warp
            local remaining = getStrongholdTimeRemaining()
            if remaining and remaining > 0 then
                local mins = math.floor(remaining / 60)
                local secs = math.floor(remaining % 60)
                updateStatus(string.format("Stronghold opens in %02d:%02d", mins, secs))
                waited = 0
            elseif waited >= SPAWN_TIMEOUT then
                -- Stronghold เปิดแล้ว แต่ Cultist ยังไม่ spawn → re-warp เพื่อกระตุ้น
                print("[Round " .. completedRounds+1 .. "] Cultist not spawned - warping to Floor then back to TriggerZone")
                updateStatus("Re-warp waiting for spawn...")
                if floorPos2 then
                    local hrp = getLiveParts()
                    if hrp then hrp.CFrame = CFrame.new(floorPos2) end
                    task.wait(0.3)
                end
                warpToTriggerZone()
                waited = 0
            end
        end
        print("✅ Cultist spawned! (round " .. completedRounds+1 .. ")")
    end

    -- Fight loop
    while true do
        if isStrongholdCleared() then
            print("[OK] FinalGate moved -> round " .. completedRounds+1 .. " cleared")
            updateStatus("✅ Round " .. completedRounds+1 .. "/" .. TOTAL_ROUNDS .. " Cleared!")
            break
        end

        local cultists = findCultists()

        if #cultists == 0 then
            local hrp = getLiveParts()
            if hrp then hrp.CFrame = CFrame.new(combatCenter) end
            updateStatus("Waiting for Cultists... (round " .. completedRounds+1 .. ")")
            task.wait(1)
        else
            local hrp = getLiveParts()
            if not hrp then task.wait(0.2) continue end

            -- re-equip axe ก่อนตีทุก tick (เฉพาะตอนไม่ใช้ cannon)
            if not useCannon then
                local char = LocalPlayer.Character
                local th = char and char:FindFirstChild("ToolHandle")
                if not (th and th:FindFirstChild("OriginalItem")) then
                    Client.InventoryHandler.RequestEquipItem(bestAxeCombat)
                    task.wait(0.1)
                    char = LocalPlayer.Character
                    th = char and char:FindFirstChild("ToolHandle")
                    if th and th:FindFirstChild("OriginalItem") then
                        axe = th.OriginalItem.Value
                    end
                end
            end

            -- Phase 1: คำนวณ centroid ของทุก cultist + ความสูงสูงสุด -> วาร์ปจุดเดียว
            -- แล้วลดเลือดทุกตัวพร้อมกัน -> รอ 1 วิ -> ตีทุกตัวพร้อมกัน
            -- (ลดเวลาจาก N iteration เหลือ 1 batch - เร็วขึ้นมาก)
            local validCultists = {}
            local centroid = Vector3.zero
            local maxY = -math.huge
            for _, cultist in ipairs(cultists) do
                if not cultist or not cultist.Parent then continue end
                local root = cultist:FindFirstChild("HumanoidRootPart") or cultist.PrimaryPart
                if not root then continue end
                table.insert(validCultists, cultist)
                centroid = centroid + root.Position
                if root.Position.Y > maxY then maxY = root.Position.Y end
            end

            if #validCultists > 0 then
                centroid = centroid / #validCultists
                -- วาร์ปไปเหนือ centroid ให้สูงกว่าตัวที่สูงที่สุด HOVER_HEIGHT studs
                local warpPos = Vector3.new(centroid.X, maxY + HOVER_HEIGHT, centroid.Z)
                hrp.CFrame = CFrame.new(warpPos) * CFrame.Angles(math.rad(-90), 0, 0)

                updateStatus("Fighting " .. #validCultists .. " Cultists... (round " .. completedRounds+1 .. ")")

                -- รอ 0.2 วิ ก่อนลดเลือด (ให้เซิร์ฟทันเห็น CFrame ใหม่ก่อน)
                task.wait(0.2)

                -- ลดเลือดทุกตัวพร้อมกัน (1 ครั้งต่อตัว) - เร็วกว่าทีละตัวมาก
                -- ทำเสมอ (ทั้ง cannon class และ axe class) - ให้ Cultist ตายเร็ว
                for _, cultist in ipairs(validCultists) do
                    pcall(function() zeroEnemyHealth(cultist) end)
                end

                -- รอ 1 วิ ก่อนโจมตี (ให้เซิร์ฟทันเห็น CFrame ใหม่ + Health=0 replicate)
                task.wait(1)

                -- ตีทุกตัวพร้อมกันจากจุด centroid เดียวกัน
                -- (ถ้า useCannon → skip - background loop ยิงให้แล้ว)
                -- (Vampire: ใช้ Scythe แทน axe + keepHPOne ถ้า Lifesteal ยังไม่เสร็จ)
                if not useCannon then
                    -- เลือก weapon: Scythe ถ้า Vampire (ถือ Scythe จริง), axe ถ้า class อื่น
                    local weapon
                    if isVampire and vampireScythe then
                        weapon = vampireScythe
                        -- equip Scythe จริง (Client.InventoryHandler) — ให้ Player ถือ Scythe
                        pcall(function()
                            Client.InventoryHandler.RequestEquipItem(vampireScythe)
                        end)
                    else
                        weapon = axe
                    end
                    -- keepHPOne ก่อนตี (เฉพาะ Vampire + Quest ทั้ง 2 stat ยังไม่เสร็จ)
                    if isVampire and weapon and not isVampireAllQuestDone() then
                        Vampire.keepHPOne()
                    end
                    for _, cultist in ipairs(validCultists) do
                        if cultist and cultist.Parent then
                            pcall(function()
                                Event:InvokeServer(cultist, weapon, ownerId, hrp.CFrame, false)
                            end)
                        end
                    end
                end

                -- นับรอบที่ตัวนี้ยังไม่ตาย: ปรับเลือดติด = +1, ปรับเลือดไม่ติด = +2 (ไม่ทำงาน = นับหนัก)
                for _, cultist in ipairs(validCultists) do
                    local attrZero = cultist:GetAttribute("Health") == 0
                    local hum = cultist:FindFirstChildOfClass("Humanoid")
                        or cultist:FindFirstChildWhichIsA("Humanoid", true)
                    local humZero = hum and hum.Parent ~= nil and hum.Health == 0
                    local zeroed = attrZero or humZero
                    surviveCounts[cultist] = (surviveCounts[cultist] or 0) + (zeroed and 1 or 2)
                end
            end

            -- Phase 2: ตัวไหนทำครบ FINISH_MODE_AFTER รอบแล้วยังไม่ตาย
            -- = โหมดเก็บตาย: วาร์ปตามตัวมัน + ปรับเลือดเร็วก่อน "ทุกตี" (ไม่ต้องรอ) ตีซ้ำจนตาย
            for _, cultist in ipairs(cultists) do
                if cultist and cultist.Parent and (surviveCounts[cultist] or 0) >= FINISH_MODE_AFTER then
                    print("[Fight] Cultist survived " .. FINISH_MODE_AFTER
                        .. " full rounds - finish mode: quick zero + hit until dead")
                    while cultist.Parent and not isStrongholdCleared() do
                        local hrp2 = getLiveParts()
                        if not hrp2 then task.wait(0.2) continue end
                        local root2 = cultist:FindFirstChild("HumanoidRootPart") or cultist.PrimaryPart
                        if not root2 then break end

                        -- วาร์ปไปเหนือตัวมัน 10 studs (หันหน้าลง) - มันเดินหนีก็ตามไปตี
                        hrp2.CFrame = CFrame.new(root2.Position + Vector3.new(0, HOVER_HEIGHT, 0))
                            * CFrame.Angles(math.rad(-90), 0, 0)
                        task.wait()

                        -- re-equip axe ถ้าหลุดระหว่างตี
                        local char2 = LocalPlayer.Character
                        local th2 = char2 and char2:FindFirstChild("ToolHandle")
                        if not (th2 and th2:FindFirstChild("OriginalItem")) then
                            Client.InventoryHandler.RequestEquipItem(bestAxeCombat)
                            task.wait(0.1)
                            char2 = LocalPlayer.Character
                            th2 = char2 and char2:FindFirstChild("ToolHandle")
                            if th2 and th2:FindFirstChild("OriginalItem") then
                                axe = th2.OriginalItem.Value
                            end
                        end

                        -- ปรับเลือดก่อนทุกตี (แบบเร็ว ไม่รอ settle) แล้วค่อยตีทันที
                        pcall(function() zeroEnemyHealth(cultist) end)
                        -- เลือก weapon: Scythe ถ้า Vampire (equip จริง), axe ถ้า class อื่น
                        local weapon2
                        if isVampire and vampireScythe then
                            weapon2 = vampireScythe
                            -- equip Scythe จริง (Client.InventoryHandler)
                            pcall(function()
                                Client.InventoryHandler.RequestEquipItem(vampireScythe)
                            end)
                        else
                            weapon2 = axe
                        end
                        -- keepHPOne ก่อนตี (Vampire + Quest ทั้ง 2 stat ยังไม่เสร็จ)
                        if isVampire and weapon2 and not isVampireAllQuestDone() then
                            Vampire.keepHPOne()
                        end
                        pcall(function()
                            Event:InvokeServer(cultist, weapon2, ownerId, hrp2.CFrame, false)
                        end)
                        task.wait(ATTACK_INTERVAL)
                    end
                    surviveCounts[cultist] = nil -- ตายแล้ว (หรือรอบเคลียร์) - เคลียร์ตัวนับ
                end
            end

            -- กลับไปลอยจุดเดิม (เหนือจุดกลาง 10 studs) รอ tick ถัดไป
            hrp.CFrame = CFrame.new(combatCenter + Vector3.new(0, HOVER_HEIGHT, 0))
                * CFrame.Angles(math.rad(-90), 0, 0)

            task.wait(ATTACK_INTERVAL)
        end
    end
end

-- ============================================
-- STEP 6-7: วน 3 รอบ fight + เปิด chest + เก็บเพชร
-- ============================================

-- Flag: ติดเมื่อ quest ของ main class เสร็จแล้ว รอให้ round ปัจจุบันจบ + เก็บเพชรก่อน teleport
local questReadyToLeave = false

-- Quest progress watcher: แสดง % ทุกครั้งที่ quest stat อัปเดต (ทุกที่ - Lobby/Stronghold/ฟาร์ม)
if type(Config.UpgradeClass) == "table" and type(Config.UpgradeClass[1]) == "string" then
    local mainClass = Config.UpgradeClass[1]
    local cp = LocalPlayer:FindFirstChild("ClassProgress")
    local folder = cp and cp:FindFirstChild(mainClass)
    if folder then
        local lastReport = 0
        local function reportQuestProgress()
            -- cooldown 1 วิ กัน spam
            if os.clock() - lastReport < 1 then return end
            lastReport = os.clock()
            local lvl = folder:GetAttribute("Level") or 1
            if lvl >= 3 then return end
            local reqs = CLASS_QUESTS[mainClass] and CLASS_QUESTS[mainClass][lvl + 1]
            if not reqs then return end
            local totalPct, count = 0, 0
            for statKey, goal in pairs(reqs) do
                local have = folder:GetAttribute(statKey) or 0
                if type(have) == "number" and goal > 0 then
                    totalPct = totalPct + math.min(have / goal, 1) * 100
                    count = count + 1
                end
            end
            if count > 0 then
                local avgPct = math.floor(totalPct / count)
                print(string.format("[Quest] %s -> Lv.%d: %d%%", mainClass, lvl + 1, avgPct))
            end
        end
        for statKey, _ in pairs(CLASS_QUESTS[mainClass] and CLASS_QUESTS[mainClass][2] or {}) do
            folder:GetAttributeChangedSignal(statKey):Connect(reportQuestProgress)
        end
        for statKey, _ in pairs(CLASS_QUESTS[mainClass] and CLASS_QUESTS[mainClass][3] or {}) do
            folder:GetAttributeChangedSignal(statKey):Connect(reportQuestProgress)
        end
        reportQuestProgress()  -- แสดงค่าเริ่มต้น
    end
end

local diamondsReadyToTeleport = false  -- flag: รอให้จบรอบ แล้ว Teleport

while completedRounds < TOTAL_ROUNDS do
    print(string.format("\n[Step 6] Round %d/%d", completedRounds+1, TOTAL_ROUNDS))
    updateStatus(string.format("Round %d/%d - Fighting...", completedRounds+1, TOTAL_ROUNDS))

    -- Re-equip ทุกรอบ: ถ้า useCannon → Laser Cannon, ไม่งั้น axe
    if useCannon and cannonTool then
        pcall(function() Client.InventoryHandler.RequestEquipItem(cannonTool) end)
    else
        Client.InventoryHandler.RequestEquipItem(bestAxeCombat)
    end
    do
        local waited = 0
        while waited < 3 do
            local char = LocalPlayer.Character
            local th = char and char:FindFirstChild("ToolHandle")
            if th and th:FindFirstChild("OriginalItem") then
                local currentTool = th.OriginalItem.Value
                if useCannon and cannonTool and currentTool.Name == "Laser Cannon" then
                    axe = currentTool  -- ใช้ตัวแปร axe ร่วม (เพื่อ compat กับ doOneRound)
                    break
                elseif not useCannon and currentTool == bestAxeCombat then
                    axe = currentTool
                    break
                end
            end
            task.wait(0.1)
            waited += 0.1
        end
    end

    doOneRound()
    completedRounds += 1

    -- เช็ค quest ของ class ที่ equip อยู่ ถ้าครบตาม level → ตั้ง flag (รอจบ loop + เก็บเพชรก่อน)
    if Config.UpgradeClass and #Config.UpgradeClass > 0 and not questReadyToLeave then
        local equippedClass = LocalPlayer:GetAttribute("Class")
        -- ตรวจเฉพาะ class ที่ equip อยู่ และอยู่ใน UpgradeClass list
        local mainClass = nil
        if equippedClass and table.find(Config.UpgradeClass, equippedClass) then
            mainClass = equippedClass
        else
            mainClass = Config.UpgradeClass[1]
        end
        local isLobby = game.PlaceId == 79546208627805

        -- ใน Lobby: ใช้ ClassProgress folder (อ่านจาก attribute ของ folder - แม่นยำ)
        -- ในแมพฟาร์ม: ใช้ LocalPlayer attribute (folder อาจหาย)
        local level = 1
        local statSource = nil  -- table ที่ใช้อ่าน stat
        if isLobby then
            local cp = LocalPlayer:FindFirstChild("ClassProgress")
            local folder = cp and cp:FindFirstChild(mainClass)
            if folder then
                level = folder:GetAttribute("Level") or 1
                statSource = folder
            end
        else
            level = LocalPlayer:GetAttribute("ClassLevel") or 1
            statSource = classStatCache[mainClass]  -- ดักจาก ClassStatUpdated event
        end

        if statSource then
            local goalLevel = level + 1
            if goalLevel <= 3 then
                local reqs = CLASS_QUESTS[mainClass] and CLASS_QUESTS[mainClass][goalLevel]
                if reqs then
                    local allMet = true
                    local statProgress = {}
                    for statKey, goal in pairs(reqs) do
                        local have = statSource[statKey] or 0
                        table.insert(statProgress, string.format("%s %d/%d", statKey, have, goal))
                        if type(have) ~= "number" or have < goal then
                            allMet = false
                        end
                    end
                    if allMet then
                        questReadyToLeave = true
                        print(string.format("[Quest] %s ready -> Lv.%d, leaving after this round (%s)",
                            mainClass, goalLevel, table.concat(statProgress, ", ")))
                        updateStatus("Quest done - finishing round")
                    end
                end
            end
        end
    end

    -- เปิด chest
    print(string.format("\n[Step 7] Opening Diamond Chest (round %d)...", completedRounds))
    updateStatus("Opening Diamond Chest...")

    local chest = retryUntil("find Diamond Chest", function()
        local items = workspace:FindFirstChild("Items")
        return (items and items:FindFirstChild("Stronghold Diamond Chest"))
            or workspace:FindFirstChild("Stronghold Diamond Chest", true)
    end)

    -- chest อาจเป็นชนิดอื่นตอน stream ไม่เสร็จ (ไม่ใช่ Model/BasePart) - index .Position ตรงๆ พัง = สคริปต์หยุดกลาง Step 7
    local chestPos
    for _ = 1, 10 do
        if chest:IsA("Model") then
            chestPos = chest:GetPivot().Position
        elseif chest:IsA("BasePart") then
            chestPos = chest.Position
        else
            local part = chest:FindFirstChildWhichIsA("BasePart", true)
            chestPos = part and part.Position
        end
        if chestPos then break end
        task.wait(0.5)
    end
    if not chestPos then
        -- สรุปตำแหน่งไม่ได้จริง = ใช้จุดกองไฟแทน (รอบนี้หาเพชรไม่เจอ แต่ flow เดินต่อได้ ไม่ error ตาย)
        warn("[Step 7] Cannot resolve Diamond Chest position - falling back to fire position")
        chestPos = firePos
    end
    if platform and platform.Parent then
        platform.Size = Vector3.new(10, 1, 10)
        platform.Position = chestPos - Vector3.new(0, 3, 0)
    end
    for _ = 1, 15 do
        local hrp = getLiveParts()
        if hrp then hrp.CFrame = CFrame.new(chestPos + Vector3.new(0, 3, 0)) end
        task.wait(0.1)
    end

    local prompt = retryUntil("find chest ProximityPrompt", function()
        local main = chest:FindFirstChild("Main")
        local attachment = main and main:FindFirstChild("ProximityAttachment")
        local p = attachment and attachment:FindFirstChild("ProximityInteraction")
        if p and p:IsA("ProximityPrompt") then return p end
        return chest:FindFirstChildWhichIsA("ProximityPrompt", true)
    end, 0.3)

    local fires = 0
    retryUntil("fire prompt to open chest", function()
        if not prompt.Parent then return true end
        if not prompt.Enabled then
            if fires > 0 then return true end
            return nil
        end
        if typeof(fireproximityprompt) == "function" then
            fireproximityprompt(prompt, 0, true)
        else
            pcall(function() prompt.HoldDuration = 0 end)
            prompt:InputHoldBegin() task.wait(0.1) prompt:InputHoldEnd()
        end
        fires += 1
        return true
    end, 0.3)
    for _ = 1, 7 do
        if not (prompt.Parent and prompt.Enabled) then break end
        if typeof(fireproximityprompt) == "function" then
            if pcall(function() fireproximityprompt(prompt, 0, true) end) then fires += 1 end
        else
            pcall(function() prompt.HoldDuration = 0 end)
            prompt:InputHoldBegin() task.wait(0.1) prompt:InputHoldEnd()
            fires += 1
        end
        task.wait(0.25)
    end
    print(("✅ Opened chest (%d interactions)"):format(fires))
    updateStatus("✅ Chest Opened!")

    -- เก็บเพชร
    print(string.format("\n[Step 7.5] Collecting diamonds (round %d)...", completedRounds))
    updateStatus("Collecting Diamonds...")
    local COLLECT_RADIUS = 150
    local COLLECT_EMPTY_STOP = 4
    local DIAMOND_ITEM_NAME = "Diamond"
    local TakeDiamondsEvent = ReplicatedStorage.RemoteEvents.RequestTakeDiamonds

    local function getItemPart(item)
        local ok, part = pcall(function()
            if item:IsA("BasePart") then return item end
            if item:IsA("Model") then
                return item.PrimaryPart or item:FindFirstChild("Main") or item:FindFirstChildWhichIsA("BasePart", true)
            end
        end)
        if ok then return part end
    end

    local function findDiamonds(origin)
        local found = {}
        pcall(function()
            local items = workspace:FindFirstChild("Items")
            if not items then return end
            for _, item in ipairs(items:GetChildren()) do
                if item.Name == DIAMOND_ITEM_NAME then
                    local owner = item:GetAttribute("Owner")
                    if owner == nil or owner == LocalPlayer.UserId then
                        local part = getItemPart(item)
                        if part then
                            local ok2, dist = pcall(function() return (part.Position - origin).Magnitude end)
                            if ok2 and dist <= COLLECT_RADIUS then
                                table.insert(found, {model = item, part = part})
                            end
                        end
                    end
                end
            end
        end)
        return found
    end

    local origin = chestPos
    local collected = 0
    local emptyStreak = 0
    local collectRound = 0
    while emptyStreak < COLLECT_EMPTY_STOP do
        collectRound += 1
        local diamonds = findDiamonds(origin)
        if #diamonds == 0 then
            emptyStreak += 1
            print(("  round %d: no items (%d/%d)"):format(collectRound, emptyStreak, COLLECT_EMPTY_STOP))
        else
            emptyStreak = 0
            for _, d in ipairs(diamonds) do
                if d.model and d.model.Parent then
                    local startDiamonds = LocalPlayer:GetAttribute("Diamonds")
                    local tries = 0
                    local gotIt = false
                    -- เดิม while not gotIt ไม่มีเพดาน: โมเดลถูกลบ/เซิร์ฟปัด = ยิง FireServer ใส่ instance ศพไม่รู้จบ
                    while not gotIt and tries < 25 do
                        if not (d.model and d.model.Parent) then break end
                        tries += 1
                        local hrp = getLiveParts()
                        if hrp and d.part and d.part.Parent then
                            pcall(function()
                                for _ = 1, 5 do hrp.CFrame = CFrame.new(d.part.Position + Vector3.new(0,2,0)) task.wait(0.05) end
                            end)
                        end
                        pcall(function() TakeDiamondsEvent:FireServer(d.model) end)
                        task.wait(0.2)
                        if LocalPlayer:GetAttribute("Diamonds") ~= startDiamonds then gotIt = true end
                        if not gotIt and tries % 20 == 0 then
                            updateStatus(("Collecting Diamond... (%d)"):format(tries))
                        end
                    end
                    if gotIt then
                        collected += 1
                        task.wait(0.15)
                    elseif d.model and d.model.Parent then
                        warn("Diamond not collected after 25 tries - skipping")
                    end
                end
            end
        end
        updateStatus(("Collecting Diamonds... (%d)"):format(collected))
        task.wait(0.2)
    end
    print(("[OK] Collected %d diamonds (round %d)"):format(collected, completedRounds))
    updateStatus(("✅ Collected %d Diamonds"):format(collected))

    -- เช็คเงื่อนไข Teleport Lobby (Diamonds + Class Lv.3 ต้องครบทั้งคู่)
    -- ถ้าตั้ง Diamonds > 0 + BuyClass + UpgradeClass → ต้องครบทั้ง Diamonds ถึง AND Class Lv.3
    local currentDiamonds = LocalPlayer:GetAttribute("Diamonds") or 0
    local currentLvl = LocalPlayer:GetAttribute("ClassLevel") or 1
    local hasBuy = Config.BuyClass and #Config.BuyClass > 0
    local hasUpgrade = Config.UpgradeClass and #Config.UpgradeClass > 0
    local hasDiamonds = Config.Diamonds and Config.Diamonds > 0

    if hasBuy and hasUpgrade and hasDiamonds then
        -- ต้องครบทั้ง Diamonds ถึง AND Class Lv.3
        if currentDiamonds >= Config.Diamonds and currentLvl >= 3 then
            print(string.format("[Teleport] Diamonds %d/%d + Class Lv.%d - teleport to Lobby",
                currentDiamonds, Config.Diamonds, currentLvl))
            diamondsReadyToTeleport = true
        end
    elseif hasBuy and hasUpgrade and not hasDiamonds then
        -- ไม่ตั้ง Diamonds → แค่ Class Lv.3 ก็พอ
        if currentLvl >= 3 then
            print(string.format("[Teleport] Class Lv.%d - teleport to Lobby", currentLvl))
            diamondsReadyToTeleport = true
        end
    elseif hasDiamonds and not hasBuy and not hasUpgrade then
        -- แค่ Diamonds
        if currentDiamonds >= Config.Diamonds then
            print(string.format("[Teleport] Diamonds %d/%d - teleport to Lobby",
                currentDiamonds, Config.Diamonds))
            diamondsReadyToTeleport = true
        end
    end

    -- ถ้า quest พร้อมอัปแล้ว → ออกจาก Stronghold กลับ lobby (หลังเก็บเพchรเสร็จ)
    if questReadyToLeave then
        local mainClass = Config.UpgradeClass and Config.UpgradeClass[1] or "?"
        print(string.format("[Quest] %s quest complete - leaving for lobby", mainClass))
        updateStatus("Teleporting to lobby...")
        task.wait(2)
        local LOBBY_PLACE_ID = 79546208627805
        pcall(function()
            local TS = game:GetService("TeleportService")
            TS:Teleport(LOBBY_PLACE_ID, LocalPlayer)
        end)
        task.wait(5)
        useCannon = false
        return
    end

    -- ถ้า Diamonds/Lv.3 ถึง → Teleport Lobby หลังจบรอบ
    if diamondsReadyToTeleport then
        forceTeleportLobby()
        return
    end

    -- ถ้ายังไม่ครบ 3 รอบ รอ Stronghold เปิดใหม่แล้ววาร์ปกลับ
    if completedRounds < TOTAL_ROUNDS then
        -- VAMPIRE: ถ้า Quest Lifesteal ยังไม่เสร็จ → เริ่ม NightLoop ทำเรื่อยๆ จนกว่า Cultist จะ spawn
        -- ALIEN SCIENTIST: เช่นเดียวกัน - ฟาร์ม Dissolves จนกว่า Cultist จะ spawn
        -- NightLoop จะหยุดเองเมื่อ checkAnyCultistSpawned() = true
        if isVampire and not Vampire.isAllQuestDone() then
            print("[Vampire] Resuming NightLoop until Stronghold opens")
            warpToStrongholdFloor(1)
            Vampire.resume()
        elseif isAlienScientist and not isAlienScientistAllQuestDone() then
            print("[AlienScientist] Resuming NightLoop until Stronghold opens")
            warpToStrongholdFloor(1)
            Alien.resume()
        elseif BGH.isBigGameHunter and not BGH.isBigGameHunterAllQuestDone() then
            -- BGH: ถ้า PeltList ทุก type Complete แต่ Quest ยังไม่ done → ออก Lobby ทันที
            -- (BGH ทำไม่ได้แล้ว — limit per type = 3, total < Quest goal 50)
            local activeAfterRound = BGH.getActivePeltTypes()
            if #activeAfterRound == 0 then
                print("[BigGameHunter] PeltList all Complete but Quest not done - leaving for Lobby")
                forceTeleportLobby()
                return
            end
            print("[BigGameHunter] Resuming NightLoop until Stronghold opens")
            warpToStrongholdFloor(1)
            BGH.resume()
        elseif Woodsman.isWoodsman and not Woodsman.isAllQuestDone() then
            -- Woodsman: ทำ Quest ต่อ (เริ่ม AxeKills ก่อน, แล้ว CutTree)
            -- ถ้า impossible → ไม่ teleport, รอ Round ใหม่ (เหมือน Vampire/AlienScientist/BGH)
            warpToStrongholdFloor(1)

            Woodsman.resume()
        else
            -- ไม่ใช่ Vampire/AlienScientist/BigGameHunter หรือ Quest ครบแล้ว → ใช้ logic เดิม
            print(string.format("[Round %d done] Waiting 20min for Stronghold to reopen...", completedRounds))
            warpToStrongholdFloor(1)
            local WAIT_SECONDS = 20 * 60
            for i = WAIT_SECONDS, 1, -1 do
                local mins = math.floor(i / 60)
                local secs = i % 60
                updateStatus(string.format("Round %d done - Next: %02d:%02d", completedRounds, mins, secs))
                task.wait(1)
            end
            while true do
                local remaining = getStrongholdTimeRemaining()
                if not remaining or remaining <= 0 then
                    print("✅ Stronghold reopened!")
                    break
                end
                local mins = math.floor(remaining / 60)
                local secs = math.floor(remaining % 60)
                updateStatus(string.format("Waiting... %02d:%02d", mins, secs))
                task.wait(1)
            end
        end
        warpToTriggerZone()
        task.wait(1)
    end
end

if lockConn then lockConn:Disconnect() end
destroyShield()
destroyFlyBody() -- ถอน BodyVelocity คืนการควบคุมตัวละครปกติ (ไม่มี PlatformStand ให้ปลดแล้ว)

print("\n=== Sugar Hub Complete ===")
print("✅ Stronghold sequence finished! (3 rounds)")
sendHorstDescription()
checkDiamondsGoalAndSendDone()

-- รอจนครบ 100 วัน ก่อนรีเซ็ต
-- อ่านวันจาก workspace.StoryDayCounter (แบบเดียวกับ NextDayUI ที่ decompile ได้)
local function getCurrentDay()
    local storyDay = workspace:GetAttribute("StoryDayCounter")
    if storyDay then return storyDay end
    -- สำรอง: ถ้าแมพไม่มี StoryDayCounter ค่อยใช้ attribute ของผู้เล่น
    return LocalPlayer:GetAttribute("Day") or 0
end

local MIN_DAY = 100
updateStatus(string.format("Waiting Day %d+ (now: %d)...", MIN_DAY, getCurrentDay()))
while getCurrentDay() < MIN_DAY do
    updateStatus(string.format("Day %d/%d - waiting...", getCurrentDay(), MIN_DAY))
    task.wait(5)
end

print(string.format("✅ Day %d reached - resetting!", getCurrentDay()))
updateStatus("✅ Done! Resetting...")
task.wait(0.3)
pcall(function()
    -- ฆ่าตัวเองจบรอบ - ปล่อยให้ Death Watcher จับแล้วกดเล่นใหม่ต่อได้เลย (จบรอบ = เริ่มรอบใหม่)
    LocalPlayer.Character:BreakJoints()
end)

end

return M
