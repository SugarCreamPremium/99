-- ============================================
-- Module_Vampire.lua
-- Complete Vampire class implementation migrated from MainScript.lua.
-- ============================================

local M = {}
local Log = _G.WSM_Log or {
    dev = function() end,
    err = function(reason, nextStep)
        warn("Error : " .. tostring(reason) .. " / " .. tostring(nextStep))
    end,
}

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

local function isAttackableModel(model)
    return model and model.Parent and model:GetAttribute("NotAttackable") ~= true
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
    Log.dev("[Vampire] Night loop started")

    if not Client or not Client.InventoryHandler or not Event or not ownerId then
        Log.err("[Vampire] shared combat dependencies are unavailable", "night loop not started")
        return
    end
    local lastLoggedState = nil  -- เก็บ state ที่ print ล่าสุด (กัน spam)
    local wasNight = false  -- เก็บว่าเคยเป็น Night แล้วหรือยัง (กลางวันมา = เลิก)

    -- ตรวจ dependencies ตอนเริ่ม
    if not vampireScythe then
        Log.err("[Vampire] Vampire Scythe not found in Inventory", "continuing, hits will be skipped")
    end
    if not LP:FindFirstChild("Inventory") then
        Log.err("[Vampire] LocalPlayer.Inventory not found", "continuing anyway, the loop may not work")
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
            Log.err(string.format("[Vampire] could not read workspace State: %s", tostring(stateErr)), "retrying in 1s")
            task.wait(1)
        elseif currentState == nil then
            Log.err("[Vampire] workspace State is nil (game may not be initialized)", "waiting 1s and retrying")
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
                Log.dev(string.format("[Vampire] Waiting for night (State: %s)", tostring(currentState)))
                lastLoggedState = currentState
            end
            task.wait(5)
        else
            -- ===== NIGHT: pre-checks + main work =====
            wasNight = true
            if lastLoggedState ~= "Night" then
                Log.dev("[Vampire] State changed to Night")
                lastLoggedState = "Night"
            end

            -- Pre-check 1: Quest ทั้ง 2 stat ครบ? → return (exit)
            local ok1, result1 = pcall(M.isAllQuestDone)
            if not ok1 then
                Log.err(string.format("[Vampire] quest check failed: %s", tostring(result1)), "continuing the night loop")
            elseif result1 then
                pcall(_G.WSM_QuestDone, "Vampire") -- unified "[Quest] Done" line, printed once
                local restoreOk, restoreErr = pcall(M.restoreHP)
                if not restoreOk then
                    Log.err(string.format("[Vampire] restoring HP failed: %s", tostring(restoreErr)), "continuing")
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

            -- Pre-check 2: Stronghold เปิด? → return (main flow handle)
            local cultistOk, cultistResult = pcall(checkAnyCultistSpawned)
            if not cultistOk then
                Log.err(string.format("[Vampire] Stronghold check failed: %s", tostring(cultistResult)), "continuing the night loop")
            elseif cultistResult then
                Log.dev("[Vampire] Stronghold opened (Cultist found), pausing NightLoop for Stronghold")
                disableFloating()
                return
            end

            Log.dev("[Vampire] State=Night, scanning for monsters")
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
            Log.err(string.format("[Vampire] monster search failed: %s", tostring(findErr)), "retrying in 1s")
            task.wait(1)
            continue
        end
        monsters = findErr  -- pcall returns result as second value when ok
        if #monsters == 0 then
            Log.dev("[Vampire] No hittable monsters found in workspace.Characters - waiting 1s")
            task.wait(1)
            continue
        end
        -- (quiet - ไม่ print "Found N monster")

        -- ตีทีละตัว: ตีซ้ำตัวเดียวจนกว่าจะตาย หรือครบ 100 ที → เปลี่ยนตัว
        local MAX_HITS_PER_TARGET = 10
        for monsterIdx, monster in ipairs(monsters) do
            if not isAttackableModel(monster) then
                -- (quiet - ไม่ print "Monster already destroyed")
                continue
            end
            local character = LP.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            local humanoid = getHumanoid(character)
            if not hrp or not humanoid or humanoid.Health <= 0 then
                Log.err("[Vampire] character is unavailable or dead", "stopping combat")
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
                Log.err(string.format("[Vampire] [%d/%d] %s has no HumanoidRootPart/PrimaryPart", monsterIdx, #monsters, monster.Name),
                    "skipping this monster")
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
            while monster and monster.Parent
                and isCharacterAlive() and hitCount < MAX_HITS_PER_TARGET do
                -- ลด HP ตัวเองเหลือ 1 (ทุกตี — ต้องทำ Lifesteal)
                local hpOk, hpErr = pcall(M.keepHPOne)
                if not hpOk then
                    Log.err(string.format("[Vampire] keeping HP at 1 failed: %s", tostring(hpErr)), "continuing")
                end

                -- ตีด้วย Vampire Scythe (ไม่ลดเลือดมอน)
                vampireScythe = getVampireScythe()
                if vampireScythe then
                    local hitOk, hitErr = pcall(function()
                        Event:InvokeServer(monster, vampireScythe, ownerId, hrp.CFrame, false)
                    end)
                    if not hitOk then
                        Log.err(string.format("[Vampire] hit request on %s failed: %s", monster.Name, tostring(hitErr)),
                            "continuing with the next hit")
                    end
                else
                    Log.err("[Vampire] Vampire Scythe is missing", "skipping the rest of this monster")
                    break
                end
                hitCount = hitCount + 1

                if hitCount == 1 then
                    -- (quiet - ไม่ print "Hit")
                end

                -- เช็ค Quest ทั้ง 2 stat (LifestealHealing + DealDamage) ทันที
                local questOk, questResult = pcall(M.isAllQuestDone)
                if not questOk then
                    Log.err(string.format("[Vampire] quest check failed: %s", tostring(questResult)), "continuing the night loop")
                elseif questResult then
                    pcall(_G.WSM_QuestDone, "Vampire") -- unified "[Quest] Done" line, printed once
                    local restoreOk2, restoreErr2 = pcall(M.restoreHP)
                    if not restoreOk2 then
                        Log.err(string.format("[Vampire] restoring HP failed: %s", tostring(restoreErr2)), "continuing")
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
                    Log.err(string.format("[Vampire] [%d/%d] %s survived %d hits", monsterIdx, #monsters, monster.Name, MAX_HITS_PER_TARGET),
                        "skipping to the next monster")
                    break  -- ครบ 100 → เปลี่ยนตัว
                end

                task.wait(0.1)
            end
        end

        -- (quiet - ไม่ print "Finished this batch")
        task.wait(1)
    end

    disableFloating()
    if isCharacterAlive() and not M.isAllQuestDone() then
        warpBackToStronghold()
    end
    Log.dev("[Vampire] Night loop ended, at Stronghold")
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
