-- ============================================
-- Module_Vampire.lua / 10.39
-- Complete Vampire class implementation migrated from MainScript.lua.
-- ============================================

local M = {}
local LP = _G.LocalPlayer or game:GetService("Players").LocalPlayer
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}

local function getEvent() return _G.Event end
local function getOwnerId() return _G.ownerId end
local function getClient() return _G.Client end
local function getToolCooldown(tool)
    local fn = _G.getToolCooldown
    return fn and fn(tool) or 0.5
end
local function findNightMonsters()
    local fn = _G.findNightMonsters
    return fn and fn() or {}
end
local function checkAnyCultistSpawned()
    local fn = _G.checkAnyCultistSpawned
    return fn and fn() or false
end
local function getFinalGatePosition() return _G.finalGateBasePos end

local function getHumanoid(character)
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function isCharacterAlive()
    local character = LP.Character
    local humanoid = getHumanoid(character)
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

M.isVampire = (_G.__WSM_currentClass or "Unknown") == "Vampire"

local function getVampireScythe()
    local inventory = LP:FindFirstChild("Inventory")
    return inventory and inventory:FindFirstChild("Vampire Scythe")
end

function M.isLifestealDone()
    local level = LP:GetAttribute("ClassLevel") or 1
    local requirements = CQ.Vampire and CQ.Vampire[level + 1]
    if not requirements or not requirements.LifestealHealing then return true end
    local stats = CSC.Vampire or {}
    return (stats.LifestealHealing or 0) >= requirements.LifestealHealing
end

function M.isDealDamageDone()
    local level = LP:GetAttribute("ClassLevel") or 1
    local requirements = CQ.Vampire and CQ.Vampire[level + 1]
    if not requirements or not requirements.DealDamage then return true end
    local stats = CSC.Vampire or {}
    return (stats.DealDamage or 0) >= requirements.DealDamage
end

function M.isAllQuestDone()
    return M.isLifestealDone() and M.isDealDamageDone()
end

local function getMyHumanoid()
    local character = workspace:FindFirstChild(LP.Name)
    return character and character:FindFirstChildOfClass("Humanoid")
end

function M.keepHPOne()
    local hum = getMyHumanoid()
    if hum and hum.Health > 1 then
        pcall(function() hum.Health = 1 end)
    end
end

function M.restoreHP()
    local hum = getMyHumanoid()
    if hum and hum.Health < 100 then
        pcall(function() hum.Health = 100 end)
    end
end

local function cleanupCharacterFloating(character)
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    for _, name in ipairs({
        "FloatAlignPosition",
        "FloatAlignOrientation",
        "FloatAttachment",
    }) do
        local object = hrp:FindFirstChild(name)
        if object then
            pcall(function() object:Destroy() end)
        end
    end
end

local function bindDeathCleanup(character)
    local humanoid = getHumanoid(character)
    if humanoid then
        humanoid.Died:Connect(function()
            cleanupCharacterFloating(character)
        end)
    end
end

if LP.Character then bindDeathCleanup(LP.Character) end
LP.CharacterAdded:Connect(bindDeathCleanup)
LP.CharacterRemoving:Connect(cleanupCharacterFloating)

function M.nightLoop()
    if not M.isVampire then return end
    local Client = getClient()
    local Event = getEvent()
    local ownerId = getOwnerId()
    local HOVER_HEIGHT = _G.HOVER_HEIGHT or 10
    local airHeight = _G.airHeight or HOVER_HEIGHT
    local combatCenter = getFinalGatePosition() or Vector3.new(0, 0, 0)
    local vampireScythe = getVampireScythe()
    print("[Vampire] Night loop started")

    if not Client or not Client.InventoryHandler or not Event or not ownerId then
        warn("[Vampire] Shared combat dependencies are unavailable")
        return
    end
    local lastLoggedState = nil  -- เก็บ state ที่ print ล่าสุด (กัน spam)
    local wasNight = false  -- เก็บว่าเคยเป็น Night แล้วหรือยัง (กลางวันมา = เลิก)

    -- ตรวจ dependencies ตอนเริ่ม
    if not vampireScythe then
        warn("[Vampire] Vampire Scythe not found in Inventory - cannot fight, will skip hits")
    end
    if not LP:FindFirstChild("Inventory") then
        warn("[Vampire] LP.Inventory not found - cannot proceed")
    end

    -- ใช้ AlignPosition + AlignOrientation ลอยค้าง (ไม่ Anchored HRP)
    local floatAP = nil  -- AlignPosition
    local floatAO = nil  -- AlignOrientation
    local followThread = nil  -- task.spawn อัปเดต Position
    local function ensureFloating()
        local char = LP.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not (char and hrp) then return end

        -- สร้าง Attachment ถ้ายังไม่มี
        if not hrp:FindFirstChild("FloatAttachment") then
            local att = Instance.new("Attachment")
            att.Name = "FloatAttachment"
            att.Parent = hrp
        end

        -- สร้าง AlignPosition (ล็อคตำแหน่ง)
        if not hrp:FindFirstChild("FloatAlignPosition") then
            floatAP = Instance.new("AlignPosition")
            floatAP.Name = "FloatAlignPosition"
            floatAP.Mode = Enum.PositionAlignmentMode.OneAttachment
            floatAP.Attachment0 = hrp.FloatAttachment
            floatAP.MaxForce = 5000  -- แรงพอลอยค้าง แต่ไม่ขัดขวางการวาร์ป
            floatAP.Responsiveness = 50
            floatAP.Position = hrp.Position
            floatAP.Parent = hrp
        end

        -- สร้าง AlignOrientation (ล็อคการหมุน)
        if not hrp:FindFirstChild("FloatAlignOrientation") then
            floatAO = Instance.new("AlignOrientation")
            floatAO.Name = "FloatAlignOrientation"
            floatAO.Mode = Enum.OrientationAlignmentMode.OneAttachment
            floatAO.Attachment0 = hrp.FloatAttachment
            floatAO.MaxTorque = 5000
            floatAO.Responsiveness = 50
            floatAO.CFrame = hrp.CFrame
            floatAO.Parent = hrp
        end

        -- เริ่ม task.spawn อัปเดต Position ทุก 0.5s (ตามตัว)
        if not followThread then
            followThread = task.spawn(function()
                while floatAP and floatAP.Parent do
                    local c = LP.Character
                    local h = c and c:FindFirstChild("HumanoidRootPart")
                    local hum = getHumanoid(c)
                    if hum and hum.Health <= 0 then
                        break
                    end
                    if h then
                        floatAP.Position = h.Position
                        if floatAO then
                            floatAO.CFrame = h.CFrame
                        end
                    end
                    task.wait(0.5)
                end
                followThread = nil
            end)
        end
    end

    -- ลบ AlignPosition/AlignOrientation เมื่อออกจาก NightLoop
    local function disableFloating()
        if followThread then
            pcall(function() task.cancel(followThread) end)
            followThread = nil
        end
        pcall(function() if floatAP then floatAP:Destroy() end end)
        pcall(function() if floatAO then floatAO:Destroy() end end)
        floatAP = nil
        floatAO = nil
    end

    while M.isVampire and isCharacterAlive() do
        -- ===== State check (Daytime vs Night) — ไม่ break เมื่อ Daytime, ให้ loop ทำงานต่อ =====
        local currentState
        local stateOk, stateErr = pcall(function()
            currentState = workspace:GetAttribute("State")
        end)
        if not stateOk then
            warn(string.format("[Vampire] Failed to read workspace:GetAttribute('State'): %s", tostring(stateErr)))
            task.wait(1)
        elseif currentState == nil then
            warn("[Vampire] workspace:GetAttribute('State') returned nil - game may not be initialized, waiting...")
            task.wait(1)
        elseif currentState ~= "Night" then
            -- DAYTIME: วาร์ปกลับ + รอ Night ถัดไป (loop tick ใหม่)
            if wasNight then
                disableFloating()
                -- วาร์ปกลับจุดเดิม (combatCenter หรือ getFinalGatePosition()) ซ้ำ 3 ครั้ง
                local hrp = LP.Character
                    and LP.Character:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local returnPos = getFinalGatePosition() or hrp.Position
                    for i = 1, 3 do
                        hrp.CFrame = CFrame.new(returnPos + Vector3.new(0, 10, 0))
                            * CFrame.Angles(math.rad(-90), 0, 0)
                        task.wait(0.8)
                    end
                end
                wasNight = false
            end
            -- print เฉพาะตอน state เปลี่ยน
            if lastLoggedState ~= currentState then
                print(string.format("[Vampire] Waiting for night (State: %s)", tostring(currentState)))
                lastLoggedState = currentState
            end
            task.wait(5)
        else
            -- ===== NIGHT: pre-checks + main work =====
            wasNight = true
            if lastLoggedState ~= "Night" then
                print("[Vampire] State changed to Night")
                lastLoggedState = "Night"
            end

            -- Pre-check 1: Quest ทั้ง 2 stat ครบ? → return (exit)
            local ok1, result1 = pcall(M.isAllQuestDone)
            if not ok1 then
                warn(string.format("[Vampire] M.isAllQuestDone() error: %s", tostring(result1)))
            elseif result1 then
                print(string.format("[Vampire] Quests done: Lifesteal %d/%d, DealDamage %d/%d",
                    (CSC["Vampire"] and CSC["Vampire"]["LifestealHealing"] or 0),
                    (CQ["Vampire"]
                        and CQ["Vampire"][(LP:GetAttribute("ClassLevel") or 1) + 1]
                        and CQ["Vampire"][(LP:GetAttribute("ClassLevel") or 1) + 1].LifestealHealing or 0),
                    (CSC["Vampire"] and CSC["Vampire"]["DealDamage"] or 0),
                    (CQ["Vampire"]
                        and CQ["Vampire"][(LP:GetAttribute("ClassLevel") or 1) + 1]
                        and CQ["Vampire"][(LP:GetAttribute("ClassLevel") or 1) + 1].DealDamage or 0)))
                local restoreOk, restoreErr = pcall(M.restoreHP)
                if not restoreOk then
                    warn(string.format("[Vampire] M.restoreHP() error: %s", tostring(restoreErr)))
                end
                disableFloating()
                local hrpEnd = LP.Character
                    and LP.Character:FindFirstChild("HumanoidRootPart")
                if hrpEnd then
                    local returnPos = getFinalGatePosition() or hrpEnd.Position
                    for i = 1, 3 do
                        hrpEnd.CFrame = CFrame.new(returnPos + Vector3.new(0, 10, 0))
                            * CFrame.Angles(math.rad(-90), 0, 0)
                        task.wait(0.8)
                    end
                end
                return
            end

            -- Quest ยังไม่เสร็จ → print progress
            local lvlNow = LP:GetAttribute("ClassLevel") or 1
            local reqsNow = CQ["Vampire"] and CQ["Vampire"][lvlNow + 1]
            local lhNow = CSC["Vampire"] and CSC["Vampire"]["LifestealHealing"] or 0
            local ddNow = CSC["Vampire"] and CSC["Vampire"]["DealDamage"] or 0
            local lhGoalNow = (reqsNow and reqsNow.LifestealHealing) or 0
            local ddGoalNow = (reqsNow and reqsNow.DealDamage) or 0
            print(string.format("[Vampire] Quest: Lifesteal %d/%d, DealDamage %d/%d (ClassLevel=%d)",
                lhNow, lhGoalNow, ddNow, ddGoalNow, lvlNow))

            -- Pre-check 2: Stronghold เปิด? → return (main flow handle)
            local cultistOk, cultistResult = pcall(checkAnyCultistSpawned)
            if not cultistOk then
                warn(string.format("[Vampire] checkAnyCultistSpawned() error: %s", tostring(cultistResult)))
            elseif cultistResult then
                print("[Vampire] Stronghold opened (Cultist found), pausing NightLoop for Stronghold")
                disableFloating()
                return
            end

            print("[Vampire] State=Night, scanning for monsters")
        end
        -- ===== end state check =====

        -- ถ้าไม่ใช่ Night → ข้าม main work (กลับไปเช็ค state ใหม่)
        if currentState ~= "Night" then
            continue
        end

        -- ===== Main work: หา Monster =====

        -- หา Monster ที่ไม่ใช่ Cultist
        local monsters
        local findOk, findErr = pcall(findNightMonsters)
        if not findOk then
            warn(string.format("[Vampire] findNightMonsters() error: %s", tostring(findErr)))
            task.wait(1)
            continue
        end
        monsters = findErr  -- pcall returns result as second value when ok
        if #monsters == 0 then
            warn("[Vampire] No hittable monsters found in workspace.Characters - waiting 1s")
            task.wait(1)
            continue
        end
        -- (quiet - ไม่ print "Found N monster")

        -- ตีทีละตัว: ตีซ้ำตัวเดียวจนกว่าจะตาย หรือครบ 100 ที → เปลี่ยนตัว
        local MAX_HITS_PER_TARGET = 10
        for monsterIdx, monster in ipairs(monsters) do
            if not (monster and monster.Parent) then
                -- (quiet - ไม่ print "Monster already destroyed")
                continue
            end
            local character = LP.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            local humanoid = getHumanoid(character)
            if not hrp or not humanoid or humanoid.Health <= 0 then
                warn("[Vampire] Character is unavailable or dead - stopping combat")
                disableFloating()
                return
            end

            -- ใช้ Anchored HRP ลอยค้าง (ล็อคตัวละคร)
            ensureFloating()

            -- equip Scythe จริง (Client.InventoryHandler) ให้ Player ถือ Scythe
            if vampireScythe then
                pcall(function()
                    Client.InventoryHandler.RequestEquipItem(vampireScythe)
                end)
            end

            local root = monster:FindFirstChild("HumanoidRootPart")
                or monster.PrimaryPart
            if not root then
                warn(string.format("[Vampire] [%d/%d] %s has no HumanoidRootPart/PrimaryPart, skipping",
                    monsterIdx, #monsters, monster.Name))
                continue
            end

            -- วาร์ปไปเหนือ (20 studs เหมือน Stronghold - airHeight)
            hrp.CFrame = CFrame.new(root.Position + Vector3.new(0, airHeight, 0))
                * CFrame.Angles(math.rad(-90), 0, 0)
            -- อัปเดตตำแหน่งเป้าหมายของ AlignPosition (ให้ลอยตาม)
            if floatAP then
                floatAP.Position = hrp.Position
            end
            if floatAO then
                floatAO.CFrame = hrp.CFrame
            end
            -- (quiet - ไม่ print "Warping")
            task.wait(0.2)

            -- ตีซ้ำตัวเดิมจนกว่าจะตาย หรือครบ 100 ที
            local hitCount = 0
            while monster and monster.Parent and isCharacterAlive() and hitCount < MAX_HITS_PER_TARGET do
                -- ลด HP ตัวเองเหลือ 1 (ทุกตี — ต้องทำ Lifesteal)
                local hpOk, hpErr = pcall(M.keepHPOne)
                if not hpOk then
                    warn(string.format("[Vampire] M.keepHPOne() error: %s", tostring(hpErr)))
                end

                -- ตีด้วย Vampire Scythe (ไม่ลดเลือดมอน)
                vampireScythe = getVampireScythe()
                if vampireScythe then
                    local hitOk, hitErr = pcall(function()
                        Event:InvokeServer(monster, vampireScythe, ownerId, hrp.CFrame, false)
                    end)
                    if not hitOk then
                        warn(string.format("[Vampire] Event:InvokeServer() error on %s: %s",
                            monster.Name, tostring(hitErr)))
                    end
                else
                    warn("[Vampire] No Vampire Scythe - skipping hit")
                    break
                end
                hitCount = hitCount + 1

                if hitCount == 1 then
                    -- (quiet - ไม่ print "Hit")
                end

                -- เช็ค Quest ทั้ง 2 stat (LifestealHealing + DealDamage) ทันที
                local questOk, questResult = pcall(M.isAllQuestDone)
                if not questOk then
                    warn(string.format("[Vampire] M.isAllQuestDone() error: %s", tostring(questResult)))
                elseif questResult then
                    local lvl = LP:GetAttribute("ClassLevel") or 1
                    local lh = CSC["Vampire"]
                        and CSC["Vampire"]["LifestealHealing"] or 0
                    local dd = CSC["Vampire"]
                        and CSC["Vampire"]["DealDamage"] or 0
                    local reqs = CQ["Vampire"] and CQ["Vampire"][lvl + 1]
                    local lhGoal = (reqs and reqs.LifestealHealing) or 0
                    local ddGoal = (reqs and reqs.DealDamage) or 0
                    print(string.format("[Vampire] Quests done: Lifesteal %d/%d, DealDamage %d/%d",
                        lh, lhGoal, dd, ddGoal))
                    local restoreOk2, restoreErr2 = pcall(M.restoreHP)
                    if not restoreOk2 then
                        warn(string.format("[Vampire] M.restoreHP() error: %s", tostring(restoreErr2)))
                    end
                    disableFloating()
                    local endHrp = LP.Character
                        and LP.Character:FindFirstChild("HumanoidRootPart")
                    if endHrp then
                        local returnPos = getFinalGatePosition() or endHrp.Position
                        for i = 1, 3 do
                            endHrp.CFrame = CFrame.new(returnPos + Vector3.new(0, 10, 0))
                                * CFrame.Angles(math.rad(-90), 0, 0)
                            task.wait(0.8)
                        end
                    end
                    return
                end

                -- เช็คว่ามอนตายหรือยัง (Dead attribute หรือ Humanoid.Health <= 0)
                local npc = monster:FindFirstChild("NPC")
                local monsterHumanoid = monster:FindFirstChildOfClass("Humanoid")
                local isDead = false
                if npc and npc:GetAttribute("Dead") == true then isDead = true end
                if monsterHumanoid and monsterHumanoid.Health <= 0 then isDead = true end

                if isDead then
                    -- (quiet - ไม่ print "Killed after N hits")
                    break  -- ตายแล้ว → ตัวถัดไป
                end

                if hitCount >= MAX_HITS_PER_TARGET then
                    warn(string.format("[Vampire] [%d/%d] %s survived %d hits, skipping to next",
                        monsterIdx, #monsters, monster.Name, MAX_HITS_PER_TARGET))
                    break  -- ครบ 100 → เปลี่ยนตัว
                end

                task.wait(getToolCooldown(vampireScythe))
            end
        end

        -- (quiet - ไม่ print "Finished this batch")
        task.wait(1)
    end

    disableFloating()
    if isCharacterAlive() and not M.isAllQuestDone() then
        warpBackToStronghold()
    end
    print("[Vampire] Night loop ended, at Stronghold")
end

function M.runBackground()
    task.spawn(function()
        task.spawn(function()
            local hpRestored = false
            while M.isVampire and isCharacterAlive() do
                if M.isAllQuestDone() then
                    if not hpRestored then
                        M.restoreHP()
                        hpRestored = true
                    end
                else
                    hpRestored = false
                    M.keepHPOne()
                end
                task.wait(0.5)
            end
        end)
        M.nightLoop()
    end)
end

function M.resume()
    M.nightLoop()
    if isCharacterAlive() then
        warpBackToStronghold()
    end
end

return M
