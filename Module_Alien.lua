-- ============================================
-- Module_Alien.lua / 10.10
-- Complete Alien Scientist class implementation migrated from MainScript.lua.
-- ============================================

local M = {}
local LP = _G.LocalPlayer or game:GetService("Players").LocalPlayer
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}

local function getClient() return _G.Client end
local function getDissolveRemote() return _G.dissolveRemote end
local function getToolCooldown(tool)
    local fn = _G.getToolCooldown
    return fn and fn(tool) or 0.5
end
local function zeroEnemyHealth(target)
    local fn = _G.zeroEnemyHealth
    if fn then return fn(target) end
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

M.isAlienScientist = (_G.__WSM_currentClass or "Unknown") == "Alien Scientist"

local function getDissolveRay()
    local inventory = LP:FindFirstChild("Inventory")
    return inventory and inventory:FindFirstChild("Dissolve Ray")
end

function M.isAllQuestDone()
    local level = LP:GetAttribute("ClassLevel") or 1
    local requirements = CQ["Alien Scientist"] and CQ["Alien Scientist"][level + 1]
    if not requirements or not requirements.Dissolves then return true end
    local stats = CSC["Alien Scientist"] or {}
    return (stats.Dissolves or 0) >= requirements.Dissolves
end

local function getHumanoid(character)
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function isCharacterAlive()
    local character = LP.Character
    local humanoid = getHumanoid(character)
    return humanoid and humanoid.Health > 0
end

local function cleanupCharacterFloating(character)
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    for _, name in ipairs({"FloatAlignPosition", "FloatAlignOrientation", "FloatAttachment"}) do
        local object = hrp:FindFirstChild(name)
        if object then pcall(function() object:Destroy() end) end
    end
end

local function bindDeathCleanup(character)
    local humanoid = getHumanoid(character)
    if humanoid then
        humanoid.Died:Connect(function() cleanupCharacterFloating(character) end)
    end
end

if LP.Character then bindDeathCleanup(LP.Character) end
LP.CharacterAdded:Connect(bindDeathCleanup)
LP.CharacterRemoving:Connect(cleanupCharacterFloating)

function M.nightLoop()
    if not M.isAlienScientist then return end
    local Client = getClient()
    local dissolveRemote = getDissolveRemote()
    local dissolveRay = getDissolveRay()
    print("[AlienScientist] Night loop started")
    if not Client or not Client.InventoryHandler or not dissolveRemote then
        warn("[AlienScientist] Shared dissolve dependencies are unavailable")
        return
    end

    if not Client or not Client.InventoryHandler or not dissolveRemote then
        warn("[AlienScientist] Shared dissolve dependencies are unavailable")
        return
    end

    -- Floating helpers (duplicate จาก vampireNightLoop เพื่อกัน regression)
    -- ใช้ AlignPosition + AlignOrientation ลอยค้างเหนือมอน ป้องกันตัวตกพื้นระหว่างยิง Dissolve Ray
    local floatAP = nil  -- AlignPosition
    local floatAO = nil  -- AlignOrientation
    local followThread = nil  -- task.spawn อัปเดต Position
    local function ensureFloating()
        local char = LP.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not (char and hrp) then return end

        if not hrp:FindFirstChild("FloatAttachment") then
            local att = Instance.new("Attachment")
            att.Name = "FloatAttachment"
            att.Parent = hrp
        end

        if not hrp:FindFirstChild("FloatAlignPosition") then
            floatAP = Instance.new("AlignPosition")
            floatAP.Name = "FloatAlignPosition"
            floatAP.Mode = Enum.PositionAlignmentMode.OneAttachment
            floatAP.Attachment0 = hrp.FloatAttachment
            floatAP.MaxForce = 5000
            floatAP.Responsiveness = 50
            floatAP.Position = hrp.Position
            floatAP.Parent = hrp
        end

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

        if not followThread then
            followThread = task.spawn(function()
                while floatAP and floatAP.Parent do
                    local c = LP.Character
                    local h = c and c:FindFirstChild("HumanoidRootPart")
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

    -- Cleanup floating เมื่อออกจาก function (ทุก exit path)
    -- ต้อง hook ก่อนเริ่ม loop เพราะ return หลายจุด

    local lastLoggedState, wasNight = nil, false
    local DISSOLVE_TIMEOUT = 3       -- วินาที — ถ้าเกินนี้ monster ยังไม่หาย → skip

    -- Pre-flight checks (warn only, don't abort - inventory may fill later)
    if not dissolveRay then
        warn("[AlienScientist] Dissolve Ray not found in Inventory")
    end
    if not dissolveRemote then
        warn("[AlienScientist] RequestDissolveEnemy remote not resolved")
    end

    -- Helper: วาร์ปกลับ Stronghold (ใช้ตอนจบ loop / กลางวันมา)
    local function warpBackToStronghold()
        local hrp = LP.Character
            and LP.Character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        local returnPos = getFinalGatePosition() or hrp.Position
        for _ = 1, 3 do
            hrp.CFrame = CFrame.new(returnPos + Vector3.new(0, 10, 0))
                * CFrame.Angles(math.rad(-90), 0, 0)
            task.wait(0.8)
        end
    end

    while isCharacterAlive() do
        -- ===== State check (Daytime vs Night) — ไม่ break เมื่อ Daytime, ให้ loop ทำงานต่อ =====
        local stateOk, currentState = pcall(function()
            return workspace:GetAttribute("State")
        end)
        if not stateOk then
            warn(string.format("[AlienScientist] State read error: %s", tostring(currentState)))
            task.wait(1)
        elseif currentState ~= "Night" then
            -- DAYTIME: วาร์ปกลับ + รอ Night ถัดไป (loop tick ใหม่)
            if wasNight then
                print("[AlienScientist] Daytime arrived, warping back + waiting for next night")
                disableFloating()
                warpBackToStronghold()
                wasNight = false
            end
            if lastLoggedState ~= currentState then
                print(string.format("[AlienScientist] Waiting for night (State: %s)", tostring(currentState)))
                lastLoggedState = currentState
            end
            task.wait(5)
        else
            -- ===== NIGHT: pre-checks + main work =====
            wasNight = true
            if lastLoggedState ~= "Night" then
                print("[AlienScientist] State=Night")
                lastLoggedState = "Night"
            end

            -- Pre-check 1: Quest done? → return (exit)
            local questOk, questResult = pcall(M.isAllQuestDone)
            if not questOk then
                warn(string.format("[AlienScientist] M.isAllQuestDone() error: %s", tostring(questResult)))
            elseif questResult then
                local lvl = LP:GetAttribute("ClassLevel") or 1
                local reqs = CQ["Alien Scientist"] and CQ["Alien Scientist"][lvl + 1]
                local goal = (reqs and reqs.Dissolves) or 0
                local have = CSC["Alien Scientist"]
                    and CSC["Alien Scientist"]["Dissolves"] or 0
                print(string.format("[AlienScientist] Quest done: Dissolves %d/%d", have, goal))
                disableFloating()
                warpBackToStronghold()
                return
            end

            -- Pre-check 2: Cultist spawned? → return (main flow handle)
            local cultistOk, cultistResult = pcall(checkAnyCultistSpawned)
            if not cultistOk then
                warn(string.format("[AlienScientist] checkAnyCultistSpawned() error: %s", tostring(cultistResult)))
            elseif cultistResult then
                print("[AlienScientist] Stronghold opened, pausing NightLoop")
                disableFloating()
                return
            end
        end
        -- ===== end state check =====

        -- ถ้าไม่ใช่ Night → ข้าม main work (กลับไปเช็ค state ใหม่)
        if currentState ~= "Night" then
            continue
        end

        -- ===== Main work: หา Monster =====

        -- หา Monster
        local monsters
        local findOk, findResult = pcall(findNightMonsters)
        if not findOk then
            warn(string.format("[AlienScientist] findNightMonsters() error: %s", tostring(findResult)))
            task.wait(1)
            continue
        end
        monsters = findResult
        if #monsters == 0 then
            warn("[AlienScientist] No hittable monsters found - waiting 1s")
            task.wait(1)
            continue
        end

        -- ตีทีละตัว: equip Dissolve Ray + warp เหนือ + hit 1 ครั้ง

        -- Equip Dissolve Ray แค่รอบแรก (ก่อน for loop) — ใช้ pattern ToolHandle/OriginalItem เหมือนส่วนอื่น ๆ ของ script
        local function isDissolveRayEquipped()
            local char = LP.Character
            local th = char and char:FindFirstChild("ToolHandle")
            local currentTool = th and th:FindFirstChild("OriginalItem") and th.OriginalItem.Value
            return currentTool and currentTool.Name == "Dissolve Ray"
        end
        if dissolveRay and not isDissolveRayEquipped() then
            pcall(function()
                Client.InventoryHandler.RequestEquipItem(dissolveRay)
            end)
            local tStart = os.clock()
            local equipped = false
            while (os.clock() - tStart) < 3 do
                if isDissolveRayEquipped() then
                    equipped = true
                    break
                end
                task.wait(0.1)
            end
            if not equipped then
                warn("[AlienScientist] Tool equip timeout (3s) - continuing anyway")
            end
        elseif not dissolveRay then
            warn("[AlienScientist] dissolveRay is nil - cannot equip")
        end

        for monsterIdx, monster in ipairs(monsters) do
            -- State check ใน for loop — early break ถ้า Day มาแล้ว
            if workspace:GetAttribute("State") ~= "Night" then
                disableFloating()
                warpBackToStronghold()
                return
            end

            -- Skip Bunny / Bee / Cultist* (ไม่ dissolve — ไม่ใช่เป้าหมาย)
            local skipDissolve = (monster.Name == "Bunny")
                or (monster.Name == "Bee")
                or string.find(monster.Name, "Cultist", 1, true)
            if skipDissolve then
                continue
            end

            if not (monster and monster.Parent) then
                continue
            end
            local hrp = LP.Character
                and LP.Character:FindFirstChild("HumanoidRootPart")
            if not hrp then
                warn("[AlienScientist] No HumanoidRootPart - cannot warp, breaking")
                break
            end

            -- ลอยตัวค้างเหนือมอน (AlignPosition+AlignOrientation) ป้องกันตกพื้นระหว่างยิง
            ensureFloating()

            -- Verify Dissolve Ray ยังถืออยู่ (ถ้าไม่ใช่ → re-equip)
            if not isDissolveRayEquipped() then
                pcall(function()
                    Client.InventoryHandler.RequestEquipItem(dissolveRay)
                end)
                local tStart2 = os.clock()
                while (os.clock() - tStart2) < 2 do
                    if isDissolveRayEquipped() then break end
                    task.wait(0.1)
                end
            end

            local root = monster:FindFirstChild("HumanoidRootPart")
                or monster.PrimaryPart
            if not root then
                continue
            end

            -- วาร์ปเหนือมอน 20 studs (airHeight)
            hrp.CFrame = CFrame.new(root.Position + Vector3.new(0, airHeight, 0))
                * CFrame.Angles(math.rad(-90), 0, 0)
            -- Update floating target ทันที (กัน Player เด้งกลับจุดเดิมระหว่าง follow thread update)
            if floatAP then
                floatAP.Position = hrp.Position
            end
            if floatAO then
                floatAO.CFrame = hrp.CFrame
            end
            task.wait(0.2)

            -- Quest check ก่อน hit (early exit ถ้า quest done)
            local midOk, midDone = pcall(M.isAllQuestDone)
            if midOk and midDone then
                disableFloating()
                warpBackToStronghold()
                return
            end

            -- รอ 1 วิก่อนเริ่ม dissolve (ให้ Player settle หลัง warp)
            task.wait(1)

            -- Dissolve loop: zero HP + fire ทุก 0.2s จนกว่า server ตอบ Success=true หรือเกิน 3 วินาที
            local tStart = os.clock()
            while (os.clock() - tStart) < DISSOLVE_TIMEOUT and isCharacterAlive() do
                if not (monster and monster.Parent) then
                    break
                end
                pcall(zeroEnemyHealth, monster)

                if dissolveRemote then
                    local fireOk, fireResult = pcall(function()
                        return dissolveRemote:InvokeServer(monster)
                    end)
                    if fireOk then
                        -- เช็คจาก server response: Success=true → dissolve สำเร็จ
                        if type(fireResult) == "table" and fireResult.Success == true then
                            break
                        end
                    else
                        warn(string.format("[AlienScientist] InvokeServer error: %s", tostring(fireResult)))
                    end
                else
                    warn("[AlienScientist] No dissolveRemote - skipping hit")
                    break
                end

                task.wait(0.1)
            end
        end
        task.wait(1)
    end

    disableFloating()  -- safety: cleanup ก่อนจบ function
end

-- ============================================


function M.runBackground()
    task.spawn(M.nightLoop)
end

function M.resume()
    M.nightLoop()
end

return M
