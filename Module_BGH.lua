-- ============================================
-- Module_BGH.lua
-- Big Game Hunter class helpers + night loop (โหลดผ่าน loadstring)
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/refs/heads/main/Module_BGH.lua
--
-- Dependencies (globals ที่ MainScript ต้อง set ก่อน):
--   - LocalPlayer
--   - Client, Event, ownerId
--   - CLASS_QUESTS, classStatCache
--   - findNightMonsters, checkAnyCultistSpawned, zeroEnemyHealth
--   - floatAP, floatAO, ensureFloating
--   - HOVER_HEIGHT, ATTACK_INTERVAL
--   - shouldSkipName (function)
-- ============================================

local M = {}

-- ============================================
-- Quest checks
-- ============================================
M.isBigGameHunter = (_G.__WSM_currentClass or "Unknown") == "Big Game Hunter"

M.MONSTER_PRIORITY = {
    "Wolf", "Scorpion", "Alpha Wolf", "Bear",
    "Polar Bear", "Boar", "Arctic Fox", "Blue Frog", "Bunny",
}

M.PRIORITY_INDEX = {}
for i, n in ipairs(M.MONSTER_PRIORITY) do
    M.PRIORITY_INDEX[n] = i
end

M.PELT_ORDER = {
    "Wolf Pelt", "Scorpion Shell", "Alpha Wolf Pelt", "Bear Pelt",
    "Polar Bear Pelt", "Boar Tusk", "Arctic Fox Pelt", "Blue Frog Leg", "Bunny Foot",
}

M.PELT_ITEMS = {
    ["Bunny Foot"] = true, ["Wolf Pelt"] = true, ["Arctic Fox Pelt"] = true,
    ["Alpha Wolf Pelt"] = true, ["Bear Pelt"] = true, ["Polar Bear Pelt"] = true,
    ["Scorpion Shell"] = true, ["Boar Tusk"] = true, ["Blue Frog Leg"] = true,
}

M.PELT_SKIP = { ["Cultist King Antler"] = true }

function M.isWolfKillsQuestDone()
    local lvl = LocalPlayer:GetAttribute("ClassLevel") or 1
    local reqs = CLASS_QUESTS["Big Game Hunter"]
        and CLASS_QUESTS["Big Game Hunter"][lvl + 1]
    if not reqs or not reqs.WolfKills then return true end
    local have = classStatCache["Big Game Hunter"]
        and classStatCache["Big Game Hunter"]["WolfKills"] or 0
    return have >= reqs.WolfKills
end

function M.isAllQuestDone()
    local lvl = LocalPlayer:GetAttribute("ClassLevel") or 1
    local reqs = CLASS_QUESTS["Big Game Hunter"]
        and CLASS_QUESTS["Big Game Hunter"][lvl + 1]
    if not reqs then return true end
    local have = classStatCache["Big Game Hunter"] or {}
    for statKey, goal in pairs(reqs) do
        local v = have[statKey] or 0
        if v < goal then return false end
    end
    return true
end

-- ============================================
-- Helper functions
-- ============================================
function M.getActivePeltTypes()
    -- หา pelt types ที่ยังไม่ครบ limit 3
    local inv = LocalPlayer:FindFirstChild("Inventory")
    if not inv then return {} end
    local counts = {}
    for _, item in ipairs(inv:GetChildren()) do
        local name = item.Name
        if M.PELT_ITEMS[name] and not M.PELT_SKIP[name] then
            counts[name] = (counts[name] or 0) + 1
        end
    end
    local active = {}
    for _, pelt in ipairs(M.PELT_ORDER) do
        if (counts[pelt] or 0) < 3 then
            table.insert(active, pelt)
        end
    end
    return active
end

function M.findMonsters()
    local list = {}
    local chars = workspace:FindFirstChild("Characters")
    if not chars then return list end
    local wolfOnlyMode = not M.isWolfKillsQuestDone()
    local activeMonsters = M.getActivePeltTypes()
    for _, model in ipairs(chars:GetChildren()) do
        if not _G.shouldSkipName(model.Name) then
            if model:GetAttribute("StrongholdEnemy") ~= true then
                local hum = model:FindFirstChildOfClass("Humanoid")
                if hum and hum.Parent and hum.Health > 0 then
                    if M.PRIORITY_INDEX[model.Name] then
                        if wolfOnlyMode then
                            if model.Name == "Wolf" then table.insert(list, model) end
                        else
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
            return (M.PRIORITY_INDEX[a.Name] or 999) < (M.PRIORITY_INDEX[b.Name] or 999)
        end)
    end
    return list
end

-- ============================================
-- Night loop
-- ============================================
function M.nightLoop()
    if not M.isBigGameHunter then return end
    print("[BigGameHunter] Loop started")

    while M.isBigGameHunter and not M.isAllQuestDone() do
        if _G.checkAnyCultistSpawned() then
            print("[BigGameHunter] Stronghold opened, pausing NightLoop")
            return
        end

        local findOk, findResult = pcall(M.findMonsters)
        if not findOk then
            warn(string.format("[BigGameHunter] findBGHMonsters error: %s", tostring(findResult)))
            task.wait(2)
        else
            local monsters = findResult
            if not monsters or #monsters == 0 then
                print("[BigGameHunter] No hittable monsters - flying to find more")
                -- บินหา
                local hrp = LocalPlayer.Character
                    and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local center = hrp.Position
                    for angle = 0, 360, 60 do
                        local rad = math.rad(angle)
                        local off = Vector3.new(math.cos(rad) * 200, 0, math.sin(rad) * 200)
                        hrp.CFrame = CFrame.new(center + off + Vector3.new(0, _G.HOVER_HEIGHT, 0))
                        task.wait(0.3)
                    end
                end
            else
                for _, m in ipairs(monsters) do
                    if M.isAllQuestDone() then break end
                    if _G.checkAnyCultistSpawned() then return end
                    if not (m and m.Parent) then continue end

                    local hrp = LocalPlayer.Character
                        and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                    local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
                    if not (hrp and root) then continue end

                    -- ลอย
                    if not _G.floatAP or not _G.floatAP.Parent then
                        hrp.CFrame = CFrame.new(root.Position + Vector3.new(0, _G.HOVER_HEIGHT, 0))
                        task.wait(0.2)
                        _G.ensureFloating(root.Position + Vector3.new(0, _G.HOVER_HEIGHT, 0))
                    else
                        _G.floatAP.Position = root.Position + Vector3.new(0, _G.HOVER_HEIGHT, 0)
                        hrp.CFrame = CFrame.new(_G.floatAP.Position)
                    end

                    -- Kill
                    _G.zeroEnemyHealth(m)
                    local axe = _G.bestAxeCombat
                    if axe then
                        pcall(function()
                            Event:InvokeServer(m, axe, ownerId, hrp.CFrame, false)
                        end)
                    end
                    task.wait(_G.ATTACK_INTERVAL or 0.18)
                end
            end
        end

        -- Check quest progress
        local lvl = LocalPlayer:GetAttribute("ClassLevel") or 1
        local reqs = CLASS_QUESTS["Big Game Hunter"]
            and CLASS_QUESTS["Big Game Hunter"][lvl + 1]
        if reqs then
            local have = classStatCache["Big Game Hunter"] or {}
            local consume = have.ConsumePelt or 0
            local wolves = have.WolfKills or 0
            local goalConsume = reqs.ConsumePelt or 0
            local goalWolves = reqs.WolfKills or 0
            if consume >= goalConsume and wolves >= goalWolves then
                print("[BigGameHunter] Quests done")
                return
            end
        end
    end

    print("[BigGameHunter] Loop ended")
end

function M.runBackground()
    task.spawn(M.nightLoop)
end

function M.resume()
    M.nightLoop()
end

return M
