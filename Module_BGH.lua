-- ============================================
-- Module_BGH.lua / 10.10
-- Complete Big Game Hunter implementation migrated from MainScript.lua.
-- ============================================

local M = {}
local BGH = M
local LP = _G.LocalPlayer or game:GetService("Players").LocalPlayer
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}
local Client = _G.Client
local Event = _G.Event
local ownerId = _G.ownerId
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local function getFinalGateBasePos() return _G.finalGateBasePos end
local airHeight = _G.airHeight or (_G.HOVER_HEIGHT or 10)
local function getCombatAxe() return _G.bestAxeCombat end
local function isCharacterAlive()
    local character = LP.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return humanoid and humanoid.Health > 0
end
local function updateStatus(...) local fn = _G.updateStatus; if fn then return fn(...) end end
local function checkAnyCultistSpawned()
    local fn = _G.checkAnyCultistSpawned
    return fn and fn() or false
end
local function zeroEnemyHealth(target)
    local fn = _G.zeroEnemyHealth
    if fn then return fn(target) end
end
local function getToolCooldown(tool)
    local fn = _G.getToolCooldown
    return fn and fn(tool) or 0.5
end
local function shouldSkipName(name)
    local fn = _G.shouldSkipName
    return fn and fn(name) or name == "Cultist" or name == "Deer"
end
M.PRIORITY_INDEX = {
    Wolf = 1,
    Scorpion = 2,
    ["Alpha Wolf"] = 3,
    Bear = 4,
    ["Polar Bear"] = 5,
    Boar = 6,
    ["Arctic Fox"] = 7,
    ["Blue Frog"] = 8,
    Bunny = 9,
}
BGH.PRIORITY_INDEX = M.PRIORITY_INDEX

M.isBigGameHunter = (_G.__WSM_currentClass or "Unknown") == "Big Game Hunter"

local function getStat(statKey)
    local cached = CSC["Big Game Hunter"]
        and CSC["Big Game Hunter"][statKey]
    return cached or 0
end

function M.isAllQuestDone()
    local level = LP:GetAttribute("ClassLevel") or 1
    local requirements = CQ["Big Game Hunter"] and CQ["Big Game Hunter"][level + 1]
    if not requirements then return true end
    return getStat("ConsumePelt") >= (requirements.ConsumePelt or 0)
        and getStat("WolfKills") >= (requirements.WolfKills or 0)
end

BGH.isBigGameHunterAllQuestDone = M.isAllQuestDone
BGH.isBigGameHunter = M.isBigGameHunter

function M.isWolfKillsQuestDone()
    local level = LP:GetAttribute("ClassLevel") or 1
    local requirements = CQ["Big Game Hunter"] and CQ["Big Game Hunter"][level + 1]
    if not requirements or not requirements.WolfKills then return true end
    return getStat("WolfKills") >= requirements.WolfKills
end

BGH.isWolfKillsQuestDone = M.isWolfKillsQuestDone

BGH.PELT_ORDER = {
    "Wolf Pelt", "Scorpion Shell", "Alpha Wolf Pelt", "Bear Pelt",
    "Polar Bear Pelt", "Boar Tusk", "Arctic Fox Pelt", "Blue Frog Leg", "Bunny Foot",
}
BGH.PELT_ITEMS = {
    ["Bunny Foot"] = true, ["Wolf Pelt"] = true, ["Arctic Fox Pelt"] = true,
    ["Alpha Wolf Pelt"] = true, ["Bear Pelt"] = true, ["Polar Bear Pelt"] = true,
    ["Scorpion Shell"] = true, ["Boar Tusk"] = true, ["Blue Frog Leg"] = true,
}
BGH.PELT_SKIP = { ["Cultist King Antler"] = true }

-- Pelt types ตามลำดับความสำคัญ (ใช้เช็ค Complete ใน PeltList)
BGH.PELT_ORDER = {
    "Wolf Pelt",
    "Scorpion Shell",
    "Alpha Wolf Pelt",
    "Bear Pelt",
    "Polar Bear Pelt",
    "Boar Tusk",
    "Arctic Fox Pelt",
    "Blue Frog Leg",
    "Bunny Foot",
}

-- Pelt names ที่ BigGameHunterClass กินได้ (จาก decompile u19)
-- ไม่รวม Mammoth Tusk (user ไม่ต้องการ)
BGH.PELT_ITEMS = {
    ["Bunny Foot"] = true,
    ["Wolf Pelt"] = true,
    ["Arctic Fox Pelt"] = true,
    ["Alpha Wolf Pelt"] = true,
    ["Bear Pelt"] = true,
    ["Polar Bear Pelt"] = true,
    ["Scorpion Shell"] = true,
    ["Boar Tusk"] = true,
    ["Blue Frog Leg"] = true,
}
-- Skip Cultist King Antler (user: "ไม่สนใจมัน")
BGH.PELT_SKIP = {
    ["Cultist King Antler"] = true,
}

-- สร้าง functions ทั้งหมดใน do block เพื่อไม่ให้ locals ไปนับใน outer chunk
do

-- เช็ค Quest ConsumePelt + WolfKills ครบทั้งคู่ (Lv ถัดไป)
-- ลอง cache ก่อน → fallback อ่านจาก ClassProgress folder (server replicate)
-- Quest methods above provide the canonical implementation.

BGH.isBigGameHunterAllQuestDone = M.isAllQuestDone
BGH.isWolfKillsQuestDone = M.isWolfKillsQuestDone

-- คืน list ของ monster names ที่ยัง active (PeltList ยังไม่ Complete)
-- ถ้า PeltList ยังไม่ replicate → fallback คืน priority list ทั้งหมด
-- ลำดับตาม BGH.PELT_ORDER (Wolf → Scorpion → ... → Bunny)
BGH.getActivePeltTypes = function()
    local peltToMonster = {
        ["Wolf Pelt"] = "Wolf",
        ["Scorpion Shell"] = "Scorpion",
        ["Alpha Wolf Pelt"] = "Alpha Wolf",
        ["Bear Pelt"] = "Bear",
        ["Polar Bear Pelt"] = "Polar Bear",
        ["Boar Tusk"] = "Boar",
        ["Arctic Fox Pelt"] = "Arctic Fox",
        ["Blue Frog Leg"] = "Blue Frog",
        ["Bunny Foot"] = "Bunny",
    }

    local PeltList = LP:FindFirstChild("PeltList")
    local active = {}

    if not PeltList then
        for _, peltName in ipairs(BGH.PELT_ORDER) do
            table.insert(active, peltToMonster[peltName])
        end
        return active
    end

    for _, peltName in ipairs(BGH.PELT_ORDER) do
        local peltObj = PeltList:FindFirstChild(peltName)
        if peltObj then
            -- Attribute "Complete" จะปรากฏเมื่อกินครบ limit เท่านั้น
            -- ก่อนหน้านั้น attribute เป็น nil → ถือว่ายัง active
            local complete = peltObj:GetAttribute("Complete") == true
            if not complete then
                table.insert(active, peltToMonster[peltName])
            end
            -- ถ้า Complete = true → ไม่ใส่ใน active (skip — เลิกตี type นี้)
        else
            -- ไม่มีใน PeltList → น่าจะ unlock แล้ว (ถือว่า active)
            table.insert(active, peltToMonster[peltName])
        end
    end

    return active
end

-- BGH-specific monster finder:
-- - skip "Cultist*" (ใช้ shouldSkipName เดิม)
-- - skip StrongholdEnemy
-- - **ไม่ skip HP > 100** (BGH ตี Bear/Polar Bear ได้)
-- - **ไม่ skip** Friendly/Pet/Ally (BGH ตีได้ทุกอย่างที่ดรอปของได้)
-- - WolfKills gate: ถ้ายังไม่ครบ → คืน Wolf ธรรมดาก่อนตัวเดียว (override PeltList)
-- - PeltList filter: ตีเฉพาะ monster ที่ PeltList ยังไม่ Complete
-- - เรียงตาม BGH.MONSTER_PRIORITY
BGH.findMonsters = function()
    local list = {}
    local chars = workspace:FindFirstChild("Characters")
    if not chars then return list end

    local wolfOnlyMode = not BGH.isWolfKillsQuestDone()
    local activeMonsters = BGH.getActivePeltTypes()

    for _, model in ipairs(chars:GetChildren()) do
        if (_G.shouldSkipName and not _G.shouldSkipName(model.Name)) or (not _G.shouldSkipName and true) then
            if model:GetAttribute("StrongholdEnemy") ~= true then
                local hum = model:FindFirstChildOfClass("Humanoid")
                    or model:FindFirstChildWhichIsA("Humanoid", true)
                if hum and hum.Parent and hum.Health > 0 then
                    if BGH.PRIORITY_INDEX[model.Name] then
                        if wolfOnlyMode then
                            -- Wolf gate: override PeltList (ตีเฉพาะ Wolf)
                            if model.Name == "Wolf" then
                                table.insert(list, model)
                            end
                        else
                            -- filter ตาม PeltList active
                            if table.find(activeMonsters, model.Name) then
                                table.insert(list, model)
                            end
                        end
                    end
                end
            end
        end
    end

    if not wolfOnlyMode then
        table.sort(list, function(a, b)
            return (BGH.PRIORITY_INDEX[a.Name] or 999) < (BGH.PRIORITY_INDEX[b.Name] or 999)
        end)
    end
    return list
end

-- กิน pelt ตัวเดียว (pattern เดียวกับ decompile AttemptConsumePelt)
local function consumeBGHPelt(peltModel)
    if not (peltModel and peltModel.Parent) then return false end
    local name = peltModel.Name
    if not BGH.PELT_ITEMS[name] or BGH.PELT_SKIP[name] then return false end
    pcall(function() peltModel.Parent = ReplicatedStorage.TempStorage end)
    pcall(function()
        Client.Events.RequestBGHConsumePelt:FireServer(peltModel)
    end)
    return true
end

-- หา pelt ใกล้ origin ที่กินได้
local function findBGHPelts(origin, radius)
    local found = {}
    radius = radius or 50
    pcall(function()
        local items = workspace:FindFirstChild("Items")
        if not items then return end
        for _, item in ipairs(items:GetChildren()) do
            if BGH.PELT_ITEMS[item.Name] and not BGH.PELT_SKIP[item.Name] then
                local pos
                if item:IsA("Model") then
                    pos = item.PrimaryPart and item.PrimaryPart.Position or item:GetPivot().Position
                elseif item:IsA("BasePart") then
                    pos = item.Position
                end
                if pos and (pos - origin).Magnitude <= radius then
                    table.insert(found, item)
                end
            end
        end
    end)
    return found
end

-- ดึง pelt มาใกล้ตัว (pattern เดียวกับ pullItem ใน Auto-Eat)
local function pullBGHPelt(peltModel)
    local hrp = LP.Character
        and LP.Character:FindFirstChild("HumanoidRootPart")
    if not hrp or not (peltModel and peltModel.Parent) then return false end

    local StartDrag = ReplicatedStorage.RemoteEvents.RequestStartDraggingItem
    local StopDrag = ReplicatedStorage.RemoteEvents.StopDraggingItem
    if not (StartDrag and StopDrag) then return false end

    local ok = pcall(function()
        StartDrag:FireServer(peltModel)
        task.wait(0.1)
        if peltModel:IsA("Model") then
            peltModel:PivotTo(CFrame.new(hrp.Position))
        else
            peltModel.CFrame = CFrame.new(hrp.Position)
        end
        task.wait(0.1)
        StopDrag:FireServer(peltModel)
    end)
    return ok
end

-- กิน pelt 1 ตัว พร้อม retry: กินตรงๆ → ถ้า fail (ConsumePelt stat ไม่ขยับ) → pull มาใกล้ → กินใหม่
-- คืน true ถ้ากินสำเร็จ (stat เพิ่มขึ้น) — false ถ้า 2 tries หมดแล้วยังไม่ได้
local function consumeBGHPeltWithRetry(peltModel)
    if not (peltModel and peltModel.Parent) then return false end
    local name = peltModel.Name
    if not BGH.PELT_ITEMS[name] or BGH.PELT_SKIP[name] then return false end

    -- เช็ค ConsumePelt stat ก่อน
    local have_before = getStat("ConsumePelt")

    -- Try 1: กินตรงๆ
    consumeBGHPelt(peltModel)
    task.wait(0.5)
    local have_after = getStat("ConsumePelt")
    if have_after > have_before then
        return true
    end

    -- Try 2: pull มาใกล้ตัว แล้วกินใหม่
    if not (peltModel and peltModel.Parent) then
        return false  -- หายไปแล้ว (server อาจ consume สำเร็จหลัง delay)
    end
    pullBGHPelt(peltModel)
    task.wait(0.3)
    consumeBGHPelt(peltModel)
    task.wait(0.5)
    have_after = getStat("ConsumePelt")
    return have_after > have_before
end

-- กิน pelt ทุกตัวใกล้ origin (พร้อม pull retry)
BGH.consumePeltsNear = function(origin, radius)
    local pelts = findBGHPelts(origin, radius)
    local eaten = 0
    for _, p in ipairs(pelts) do
        if consumeBGHPeltWithRetry(p) then
            eaten = eaten + 1
        end
    end
    return eaten
end

end  -- end of BGH do block


function M.nightLoop()
    if not BGH.isBigGameHunter then return end
    print("[BigGameHunter] Loop started")

    local PELT_SEARCH_RADIUS = 50
    local HOVER_HEIGHT = 20

    -- Floating helpers (เหมือน Vampire/Alien pattern) — แยก scope ด้วย do block
    -- เพื่อลด local register count ของ outer function (กัน Luau 200-register limit)
    local floatAP, floatAO, followThread

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

    -- หา Stronghold Floor position เพื่อ warp กลับตอนจบ loop / กลางวัน
    local function warpBackToStronghold()
        local hrp = LP.Character
            and LP.Character:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        local returnPos = getFinalGateBasePos() or hrp.Position
        for _ = 1, 3 do
            hrp.CFrame = CFrame.new(returnPos + Vector3.new(0, 10, 0))
                * CFrame.Angles(math.rad(-90), 0, 0)
            task.wait(0.8)
        end
    end

    -- Helper: BGH loop จบ — disable floating + warp + cleanup map/chars
    -- เรียกเมื่อ Quest done / PeltList done (BGH ทำงานเสร็จแล้ว)
    -- reason: "quest" หรือ "peltlist" — ใช้ print ที่เหมาะสม
    local function bghExitAndCleanup(reason)
        if reason == "quest" then
            local lvl = LP:GetAttribute("ClassLevel") or 1
            local reqs = CQ["Big Game Hunter"] and CQ["Big Game Hunter"][lvl + 1]
            local goal_consume = (reqs and reqs.ConsumePelt) or 0
            local goal_wolves = (reqs and reqs.WolfKills) or 0
            local have_consume = CSC["Big Game Hunter"]
                and CSC["Big Game Hunter"]["ConsumePelt"] or 0
            local have_wolves = CSC["Big Game Hunter"]
                and CSC["Big Game Hunter"]["WolfKills"] or 0
            print(string.format("[BigGameHunter] Quests done: ConsumePelt %d/%d, WolfKills %d/%d",
                have_consume, goal_consume, have_wolves, goal_wolves))
        elseif reason == "peltlist" then
            print("[BigGameHunter] All PeltList types Complete - exiting")
        end
        disableFloating()
        warpBackToStronghold()
        pcall(function()
            local map = workspace:FindFirstChild("Map")
            if map then
                local mapFolderNames = {
                    "Biomes", "Blockers", "Boundaries", "Campground", "Caves",
                    "ExplodableModels", "FishingSpots", "Foliage", "Ground",
                    "Landmarks", "MapLandmarks", "MissingKids", "Snow", "Testing", "Water",
                }
                for _, folderName in ipairs(mapFolderNames) do
                    local folder = map:FindFirstChild(folderName)
                    if folder then
                        for _, child in ipairs(folder:GetChildren()) do
                            if not (folderName == "Landmarks" and child.Name == "Stronghold") then
                                pcall(function() child:Destroy() end)
                            end
                        end
                    end
                end
            end
            local chars = workspace:FindFirstChild("Characters")
            if chars then
                for _, child in ipairs(chars:GetChildren()) do
                    pcall(function() child:Destroy() end)
                end
            end
        end)
    end

    -- Helper: BGH loop จบเพื่อเข้า Stronghold fight — แค่ disable floating + warp กลับ
    -- ไม่ cleanup เพราะ Cultist + map folders ต้องใช้ใน Stronghold fight
    local function bghExitForStronghold()
        disableFloating()
        warpBackToStronghold()
    end

    -- counter สำหรับนับจำนวนครั้งที่ "ไม่เจอ monster" (กัน infinite loop ถ้า server delay replicate)
    local noMonsterCount = 0
    local NO_MONSTER_LIMIT = 3  -- ถ้า 3 รอบติดกันไม่เจอ → exit (BGH ทำไม่ได้แล้ว)

    -- แยก main loop body ออกเป็น inner function เพื่อลด local register count
    -- (Luau จำกัด 200 registers ต่อ function — outer function มี locals เยอะเกินไป)
    local function runBGHIteration()
        if not isCharacterAlive() then
            disableFloating()
            return false
        end
        local axe = getCombatAxe()
        -- Pre-check 1: Quest done? → cleanup เต็มรูปแบบ + return (exit) — เช็คก่อน Pre-check 0
        if BGH.isBigGameHunterAllQuestDone() then
            bghExitAndCleanup("quest")
            return false  -- signal: stop loop
        end

        -- Pre-check 0: PeltList ครบทุก type แล้ว? → cleanup + warp + exit
        local activePeltTypes = BGH.getActivePeltTypes()
        if #activePeltTypes == 0 then
            bghExitAndCleanup("peltlist")
            return false  -- signal: stop loop
        end

        -- Pre-check 2: Cultist spawned? → return (Stronghold flow takes over)
        local cultistOk, cultistResult = pcall(checkAnyCultistSpawned)
        if not cultistOk then
            warn(string.format("[BigGameHunter] checkAnyCultistSpawned() error: %s", tostring(cultistResult)))
        elseif cultistResult then
            print("[BigGameHunter] Stronghold opened, pausing NightLoop")
            bghExitForStronghold()
            return false
        end

        -- หา monster ตาม priority
        local monsters
        local findOk, findResult = pcall(BGH.findMonsters)
        if not findOk then
            warn(string.format("[BigGameHunter] findBGHMonsters() error: %s", tostring(findResult)))
            task.wait(1)
            return true  -- continue
        end

        monsters = findResult
        if #monsters == 0 then
            -- ไม่เจอมอนที่ตีได้ → บินวน 1 รอบ radius 500 จนกว่าจะเจอ
            -- ใช้ finalGateBasePos เป็น center (กลาง Stronghold) เพราะอยู่ใน Stronghold
            print("[BigGameHunter] No hittable monsters - flying to find more")
            updateStatus("Scanning for monsters...")
            local foundDuringScan = false
            local hrp = LP.Character
                and LP.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                local center = getFinalGateBasePos() or hrp.Position
                local scanRadius = 500
                local scanSteps = 60
                local circumference = 2 * math.pi * scanRadius
                local speed = 800
                local duration = circumference / speed
                for i = 0, scanSteps do
                    -- Re-check ระหว่าง fly
                    if BGH.isBigGameHunterAllQuestDone() then
                        bghExitAndCleanup("quest")
                        return false
                    end
                    if checkAnyCultistSpawned() then
                        bghExitForStronghold()
                        return false
                    end
                    local angle = (i / scanSteps) * math.pi * 2
                    local scanPos = center + Vector3.new(
                        math.cos(angle) * scanRadius,
                        airHeight,
                        math.sin(angle) * scanRadius
                    )
                    hrp.CFrame = CFrame.new(scanPos)
                    if floatAP then floatAP.Position = hrp.Position end
                    if floatAO then floatAO.CFrame = hrp.CFrame end
                    task.wait(duration / scanSteps)
                    -- เช็คทุก 10 steps เผื่อเจอมอน
                    if i % 10 == 5 then
                        local ok2, recheck = pcall(BGH.findMonsters)
                        if ok2 and recheck and #recheck > 0 then
                            foundDuringScan = true
                            break
                        end
                    end
                end
            end
            -- ถ้าเจอระหว่าง fly → ไม่ต้องเข้า "รอ" mode (เด้งไป for loop เลย)
            if not foundDuringScan then
                -- นับครั้งที่ไม่เจอ monster (กัน infinite loop)
                noMonsterCount = noMonsterCount + 1
                if noMonsterCount >= NO_MONSTER_LIMIT then
                    -- Double-check PeltList Complete (กัน false positive จาก server delay replicate)
                    task.wait(2)  -- รอให้ server replicate
                    local recheck = BGH.getActivePeltTypes()
                    if #recheck == 0 then
                        -- ยืนยัน: PeltList ครบจริง → exit
                        print("[BigGameHunter] No monsters found " .. NO_MONSTER_LIMIT
                            .. " times in a row + PeltList confirmed complete - exiting")
                        bghExitAndCleanup("peltlist")
                        return false
                    else
                        -- PeltList ยังมี type active → server replicate แล้ว → monster spawn ใหม่ → วน loop ใหม่
                        print("[BigGameHunter] PeltList still has " .. #recheck .. " active types - resetting counter")
                        noMonsterCount = 0
                    end
                end
                -- หลัง fly scan 1 รอบ: ถ้า WolfKills ยังไม่ครบ + Wolf Pelt Complete + ไม่เจอ Wolf
                -- → เปลี่ยนไปทำ Pelt อื่นแทน (ถ้ามี) — รอ Wolf spawn ใหม่
                if not BGH.isWolfKillsQuestDone() then
                    local active = BGH.getActivePeltTypes()
                    if not table.find(active, "Wolf") then
                        -- Wolf Pelt Complete แต่ WolfKills ยังไม่ครบ + ไม่เจอ Wolf
                        -- → เปลี่ยนโหมด: ตี Pelt อื่นแทน (กิน ConsumePelt เพิ่ม ระหว่างรอ Wolf)
                        -- override wolfOnlyMode ชั่วคราวใน loop นี้
                        local otherMonsters = {}
                        pcall(function()
                            local chars = workspace:FindFirstChild("Characters")
                            if not chars then return end
                            for _, model in ipairs(chars:GetChildren()) do
                                if (_G.shouldSkipName and not _G.shouldSkipName(model.Name)) or (not _G.shouldSkipName and true) then
                                    if model:GetAttribute("StrongholdEnemy") ~= true then
                                        local hum = model:FindFirstChildOfClass("Humanoid")
                                            or model:FindFirstChildWhichIsA("Humanoid", true)
                                        if hum and hum.Parent and hum.Health > 0 then
                                            if BGH.PRIORITY_INDEX[model.Name] then
                                                if model.Name ~= "Wolf" then
                                                    if table.find(active, model.Name) then
                                                        table.insert(otherMonsters, model)
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end)
                        if #otherMonsters > 0 then
                            -- มี Pelt อื่นให้ตี → ตีเลย
                            table.sort(otherMonsters, function(a, b)
                                return (BGH.PRIORITY_INDEX[a.Name] or 999) < (BGH.PRIORITY_INDEX[b.Name] or 999)
                            end)
                            for _, otherMonster in ipairs(otherMonsters) do
                                if not isCharacterAlive() then
                                    disableFloating()
                                    return false
                                end
                                if not (otherMonster and otherMonster.Parent) then continue end
                                local otherRoot = otherMonster:FindFirstChild("HumanoidRootPart")
                                    or otherMonster.PrimaryPart
                                if not otherRoot then continue end
                                if axe then
                                    pcall(function() Client.InventoryHandler.RequestEquipItem(axe) end)
                                    task.wait(0.2)
                                end
                                ensureFloating()
                                local hrp2 = LP.Character
                                    and LP.Character:FindFirstChild("HumanoidRootPart")
                                if not hrp2 then break end
                                hrp2.CFrame = CFrame.new(otherRoot.Position + Vector3.new(0, HOVER_HEIGHT, 0))
                                    * CFrame.Angles(math.rad(-90), 0, 0)
                                if floatAP then floatAP.Position = hrp2.Position end
                                if floatAO then floatAO.CFrame = hrp2.CFrame end
                                task.wait(0.2)
                                pcall(zeroEnemyHealth, otherMonster)
                                task.wait(1)
                                pcall(function()
                                    Event:InvokeServer(otherMonster, axe, ownerId, hrp2.CFrame, false)
                                end)
                                while otherMonster and otherMonster.Parent do
                                    if not isCharacterAlive() then
                                        disableFloating()
                                        return false
                                    end
                                    if BGH.isBigGameHunterAllQuestDone() then
                                        bghExitAndCleanup("quest")
                                        return false
                                    end
                                    if checkAnyCultistSpawned() then
                                        bghExitForStronghold()
                                        return false
                                    end
                                    pcall(zeroEnemyHealth, otherMonster)
                                    task.wait(0.5)
                                    pcall(function()
                                        Event:InvokeServer(otherMonster, axe, ownerId, hrp2.CFrame, false)
                                    end)
                                    task.wait(0.2)
                                end
                                if not (otherMonster and otherMonster.Parent) then
                                    BGH.consumePeltsNear(otherRoot.Position, PELT_SEARCH_RADIUS)
                                end
                                task.wait(0.3)
                            end
                        else
                            -- ไม่มี Pelt อื่นให้ตี + ไม่มี Wolf → รอ (ไม่ exit — แค่ continue)
                            -- เพราะอาจมี Cultist spawn ระหว่างนี้
                            print("[BigGameHunter] No Wolf + no other pelts - waiting for spawn")
                        end
                    end
                end
            end
            return true  -- continue (วน loop ใหม่)
        end

        for monsterIdx, monster in ipairs(monsters) do
            -- Re-check ใน for loop
            if BGH.isBigGameHunterAllQuestDone() then
                bghExitAndCleanup("quest")
                return false
            end
            if checkAnyCultistSpawned() then
                bghExitForStronghold()
                return false
            end

            -- Re-check active types (กรณี PeltList Complete เปลี่ยนระหว่าง for loop)
            -- ยกเว้น Wolf gate (ถ้า WolfKills ยังไม่ครบ ต้องตี Wolf ต่อแม้ Wolf Pelt จะ Complete)
            local wolfOnlyMode = not BGH.isWolfKillsQuestDone()
            if not (wolfOnlyMode and monster.Name == "Wolf") then
                local activeNow = BGH.getActivePeltTypes()
                if not table.find(activeNow, monster.Name) then
                    continue
                end
            end

            if not (monster and monster.Parent) then continue end
            local hrp = LP.Character
                and LP.Character:FindFirstChild("HumanoidRootPart")
            if not hrp then
                warn("[BigGameHunter] No HumanoidRootPart - cannot warp, breaking")
                break
            end

            local root = monster:FindFirstChild("HumanoidRootPart")
                or monster.PrimaryPart
            if not root then
                warn(string.format("[BigGameHunter] [%d/%d] %s has no root, skipping",
                    monsterIdx, #monsters, monster.Name))
                continue
            end

            -- Equip axe ก่อนตี (กันของหลุด/ถูก unequip ระหว่างรอ — pattern เดียวกับ fight loop)
            if axe then
                pcall(function()
                    Client.InventoryHandler.RequestEquipItem(axe)
                end)
                task.wait(0.2)
            end

            -- ลอยค้างเหนือเป้า (ใช้ followThread แบบ real-time — ติดตาม monster ทุก frame)
            ensureFloating()

            -- Spawn task ติดตาม monster position (อัปเดต HRP ทุก 0.1s — ตาม monster ขยับ)
            local trackThread = task.spawn(function()
                while monster and monster.Parent and hrp and hrp.Parent and isCharacterAlive() do
                    local currentRoot = monster:FindFirstChild("HumanoidRootPart")
                        or monster.PrimaryPart
                    if currentRoot then
                        local targetPos = currentRoot.Position + Vector3.new(0, HOVER_HEIGHT, 0)
                        hrp.CFrame = CFrame.new(targetPos) * CFrame.Angles(math.rad(-90), 0, 0)
                        if floatAP then floatAP.Position = hrp.Position end
                        if floatAO then floatAO.CFrame = hrp.CFrame end
                    end
                    task.wait(0.1)
                end
            end)

            task.wait(0.2)

            -- Quest check ก่อนตี (early exit)
            if BGH.isBigGameHunterAllQuestDone() then
                pcall(function() task.cancel(trackThread) end)
                bghExitAndCleanup("quest")
                return false
            end

            -- Hit pattern: zero -> wait 1s -> axe (เหมือน Cultist)
            pcall(zeroEnemyHealth, monster)
            task.wait(1)
            pcall(function()
                Event:InvokeServer(monster, axe, ownerId, hrp.CFrame, false)
            end)
            task.wait(getToolCooldown(axe))

            -- ตีซ้ำจนกว่าจะตาย (ไม่มี cap — recheck ทุก hit)
            -- Protection: ถ้าตี 5 ครั้งติด HP ไม่ลด → เปลี่ยนตัว (กันตีค้าง)
            local noDamageStreak = 0
            while monster and monster.Parent do
                if not isCharacterAlive() then
                    pcall(function() task.cancel(trackThread) end)
                    disableFloating()
                    return false
                end
                if BGH.isBigGameHunterAllQuestDone() then
                    pcall(function() task.cancel(trackThread) end)
                    bghExitAndCleanup("quest")
                    return false
                end
                if checkAnyCultistSpawned() then
                    pcall(function() task.cancel(trackThread) end)
                    bghExitForStronghold()
                    return false
                end

                -- เช็ค HP ก่อนตี
                local humBefore = monster:FindFirstChildOfClass("Humanoid")
                    or monster:FindFirstChildWhichIsA("Humanoid", true)
                local hpBefore = humBefore and humBefore.Health or 0

                pcall(zeroEnemyHealth, monster)
                task.wait(1)
                pcall(function()
                    Event:InvokeServer(monster, axe, ownerId, hrp.CFrame, false)
                end)
                task.wait(getToolCooldown(axe))

                -- เช็ค HP หลังตี
                if monster and monster.Parent and humBefore then
                    local humAfter = monster:FindFirstChildOfClass("Humanoid")
                        or monster:FindFirstChildWhichIsA("Humanoid", true)
                    local hpAfter = humAfter and humAfter.Health or 0
                    if hpAfter >= hpBefore then
                        noDamageStreak = noDamageStreak + 1
                        if noDamageStreak >= 5 then
                            -- ตี 5 ครั้ง HP ไม่ลด → เปลี่ยนตัว
                            warn(string.format("[BigGameHunter] %s not taking damage after 5 hits - skipping",
                                monster.Name))
                            break
                        end
                    else
                        noDamageStreak = 0  -- reset (มี damage แล้ว)
                    end
                end
            end

            -- ยกเลิก track thread เมื่อจบ (monster ตายหรือเปลี่ยนตัว)
            pcall(function() task.cancel(trackThread) end)

            -- หลังตีเสร็จรอบสุดท้าย → ถ้าตายแล้ว หา pelt ใกล้จุดตาย
            if not (monster and monster.Parent) then
                local dropPos = root.Position
                BGH.consumePeltsNear(dropPos, PELT_SEARCH_RADIUS)
                noMonsterCount = 0  -- reset (kill monster สำเร็จ = โค้ดยังทำงานได้)
            end
        end
        task.wait(0.5)
        return true  -- continue
    end

    while BGH.isBigGameHunter and isCharacterAlive() do
        if not runBGHIteration() then break end
    end

    disableFloating()  -- safety cleanup
end

-- ============================================

function M.runBackground()
    task.spawn(M.nightLoop)
end

function M.resume()
    M.nightLoop()
end

return M
