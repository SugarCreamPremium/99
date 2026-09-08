-- ============================================
-- Module_Woodsman.lua
-- Woodsman class helpers + loops (โหลดผ่าน loadstring)
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/main/Module_Woodsman.lua
--
-- Dependencies (globals ที่ MainScript ต้อง set ก่อน):
--   - LocalPlayer
--   - Client (require(player.PlayerScripts.Client))
--   - Event (RemoteEvents.ToolDamageObject)
--   - ownerId (string)
--   - CLASS_QUESTS (ClassesDatabase)
--   - classStatCache (table)
--   - findNightMonsters (function)
--   - checkAnyCultistSpawned (function)
--   - zeroEnemyHealth (function)
--   - ensureFloating (function)
--   - collectTrees (function)
--   - floatAP, floatAO (floating variables - shared with MainScript)
--   - CHOPPABLE_TREE_NAMES (table)
-- ============================================

local M = {}

-- ============================================
-- Setup
-- ============================================
local LP = _G.LocalPlayer or game:GetService("Players").LocalPlayer
local CQ = _G.CLASS_QUESTS
local CSC = _G.classStatCache

-- ============================================
-- Quest checks
-- ============================================
M.isWoodsman = (_G.__WSM_currentClass or "Unknown") == "Woodsman"

function M.isAxeKillsDone()
    local lvl = LP:GetAttribute("ClassLevel") or 1
    local reqs = CQ["Woodsman"] and CQ["Woodsman"][lvl + 1]
    if not reqs or not reqs.WoodsmanAxeKills then return true end
    local have = CSC["Woodsman"]
        and CSC["Woodsman"]["WoodsmanAxeKills"] or 0
    return have >= reqs.WoodsmanAxeKills
end

function M.isCutTreeDone()
    local lvl = LP:GetAttribute("ClassLevel") or 1
    local reqs = CQ["Woodsman"] and CQ["Woodsman"][lvl + 1]
    if not reqs or not reqs.CutTree then return true end
    local have = CSC["Woodsman"]
        and CSC["Woodsman"]["CutTree"] or 0
    return have >= reqs.CutTree
end

function M.isAllQuestDone()
    return M.isAxeKillsDone() and M.isCutTreeDone()
end

-- ============================================
-- Axe helpers
-- ============================================
function M.getAxe()
    local lp = _G.LocalPlayer or game:GetService("Players").LocalPlayer
    local inv = lp:FindFirstChild("Inventory")
    if not inv then return nil end
    for _, tool in ipairs(inv:GetChildren()) do
        if tool.Name == "Woodsman's Axe" then
            return tool
        end
    end
    return nil
end

function M.equipAxe()
    local axe = M.getAxe()
    if not axe then
        warn("[Woodsman] Woodsman's Axe not in Inventory")
        return nil
    end
    pcall(function() Client.InventoryHandler.RequestEquipItem(axe) end)
    for i = 1, 30 do  -- 3s timeout
        task.wait(0.1)
        local char = LP.Character
        local th = char and char:FindFirstChild("ToolHandle")
        if th and th:FindFirstChild("OriginalItem")
            and th.OriginalItem.Value
            and th.OriginalItem.Value.Name == "Woodsman's Axe" then
            return th.OriginalItem.Value
        end
    end
    return nil
end

function M.ensureEquipped()
    local char = LP.Character
    local th = char and char:FindFirstChild("ToolHandle")
    local curAxe = th and th:FindFirstChild("OriginalItem")
        and th.OriginalItem.Value
    if curAxe and curAxe.Name == "Woodsman's Axe" then
        return curAxe
    end
    return M.equipAxe()
end

-- ============================================
-- Main loops
-- ============================================
function M.waitForMonsters(maxWait)
    local waited = 0
    while waited < maxWait do
        local list = _G.findNightMonsters()
        if #list > 0 then return true end
        task.wait(0.5)
        waited += 0.5
    end
    return false
end

function M.axeKillsLoop()
    if not M.isWoodsman then return "skip" end
    if M.isAxeKillsDone() then return "done" end

    print("[Woodsman] Loop started")

    local axe = M.equipAxe()
    if not axe then
        warn("[Woodsman] Woodsman's Axe not found in Inventory - cannot fight, will skip hits")
        return "impossible"
    end

    while M.isWoodsman and not M.isAxeKillsDone() do
        if _G.checkAnyCultistSpawned() then
            print("[Woodsman] Stronghold opened, pausing NightLoop")
            return "stronghold"
        end

        local findOk, monsters = pcall(_G.findNightMonsters)
        if not findOk then
            warn("[Woodsman] findNightMonsters error: " .. tostring(monsters))
            task.wait(1)
            continue
        end

        if #monsters == 0 then
            local got = M.waitForMonsters(30)
            if not got then
                warn("[Woodsman] No hittable monsters found - waiting 1s")
                task.wait(1)
            end
            continue
        end

        for _, monster in ipairs(monsters) do
            if M.isAxeKillsDone() then break end
            if _G.checkAnyCultistSpawned() then return "stronghold" end
            if not (monster and monster.Parent) then continue end

            local hrp = LP.Character
                and LP.Character:FindFirstChild("HumanoidRootPart")
            local root = monster:FindFirstChild("HumanoidRootPart")
                or monster.PrimaryPart
            if not (hrp and root) then continue end

            local axeRef = M.ensureEquipped()
            if not axeRef then
                warn("[Woodsman] No Woodsman's Axe - skipping hit")
                return "impossible"
            end

            -- ลอยเหนือมอน 30 studs
            local targetPos = root.Position + Vector3.new(0, 30, 0)
            if not _G.floatAP or not _G.floatAP.Parent then
                hrp.CFrame = CFrame.new(targetPos)
                task.wait(0.2)
                _G.ensureFloating(targetPos)
            else
                _G.floatAP.Position = targetPos
                hrp.CFrame = CFrame.new(targetPos)
            end

            -- kill: zero HP + InvokeServer
            pcall(_G.zeroEnemyHealth, monster)
            local ok, err = pcall(function()
                Event:InvokeServer(monster, axeRef, ownerId, hrp.CFrame, false)
            end)
            if not ok then
                warn("[Woodsman] InvokeServer error: " .. tostring(err))
            end

            task.wait(0.15)
        end
    end

    print("[Woodsman] Loop ended")
    return M.isAxeKillsDone() and "done" or "impossible"
end

function M.cutTreeLoop()
    if not M.isWoodsman then return "skip" end
    if M.isCutTreeDone() then return "done" end

    print("[Woodsman] Loop started")

    local axe = M.equipAxe()
    if not axe then
        warn("[Woodsman] Woodsman's Axe not found in Inventory - cannot fight, will skip hits")
        return "impossible"
    end

    local NO_TREE_LIMIT = 3
    local noTreeRounds = 0

    while M.isWoodsman and not M.isCutTreeDone() do
        if _G.checkAnyCultistSpawned() then
            print("[Woodsman] Stronghold opened, pausing NightLoop")
            return "stronghold"
        end

        local trees = collectTrees()
        if #trees == 0 then
            noTreeRounds += 1
            if noTreeRounds >= NO_TREE_LIMIT then
                warn("[Woodsman] No trees found - CutTree impossible (wait for next round)")
                return "impossible"
            end
            -- บินหา 1 รอบ
            local hrp0 = LP.Character
                and LP.Character:FindFirstChild("HumanoidRootPart")
            if hrp0 then
                local center = hrp0.Position
                for angle = 0, 360, 60 do
                    local rad = math.rad(angle)
                    local off = Vector3.new(math.cos(rad) * 300, 0, math.sin(rad) * 300)
                    hrp0.CFrame = CFrame.new(center + off + Vector3.new(0, 50, 0))
                    task.wait(0.3)
                end
            end
            continue
        end
        noTreeRounds = 0

        for _, tree in ipairs(trees) do
            if M.isCutTreeDone() then break end
            if _G.checkAnyCultistSpawned() then return "stronghold" end

            if not (tree and tree.Parent) then continue end
            if not tree:IsDescendantOf(workspace.Map.Foliage) then continue end

            local hrp = LP.Character
                and LP.Character:FindFirstChild("HumanoidRootPart")
            if not hrp then
                warn("[Woodsman] No HumanoidRootPart - cannot warp, breaking")
                return "impossible"
            end

            local axeRef = M.ensureEquipped()
            if not axeRef then
                warn("[Woodsman] Woodsman's Axe missing - cannot continue")
                return "impossible"
            end

            local treePos = tree:IsA("Model")
                and tree:GetPivot().Position or tree.Position
            local cutPos = treePos + Vector3.new(0, 30, 0)

            -- WASD-style random walk รอบ ๆ ต้นไม้ (floatAP ล็อคไม่ให้ตกพื้น)
            local dir = math.random(1, 4)  -- 1=W, 2=A, 3=S, 4=D
            local offset
            if dir == 1 then offset = Vector3.new(-3, 0, 0)
            elseif dir == 2 then offset = Vector3.new(0, 0, -3)
            elseif dir == 3 then offset = Vector3.new(3, 0, 0)
            else offset = Vector3.new(0, 0, 3)
            end
            local walkPos = treePos + Vector3.new(0, 30, 0) + offset
            if _G.floatAP and _G.floatAP.Parent then
                _G.floatAP.Position = walkPos
            end
            hrp.CFrame = CFrame.new(walkPos)

            if not _G.floatAP or not _G.floatAP.Parent then
                task.wait(0.2)
                _G.ensureFloating(walkPos)
            else
                _G.floatAP.Position = walkPos
                hrp.CFrame = CFrame.new(walkPos)
            end

            local hitCount = 0
            while tree.Parent and tree:IsDescendantOf(workspace.Map.Foliage)
                and hitCount < 300 do
                if M.isCutTreeDone() then break end
                if _G.checkAnyCultistSpawned() then return "stronghold" end

                hrp = LP.Character
                    and LP.Character:FindFirstChild("HumanoidRootPart")
                if not hrp then break end

                local ok, err = pcall(function()
                    Event:InvokeServer(tree, axeRef, ownerId, hrp.CFrame, false)
                end)
                if not ok then
                    warn("[Woodsman] Tree hit error: " .. tostring(err))
                    break
                end
                hitCount += 1
                task.wait(0.15)
            end
        end
    end

    print("[Woodsman] Loop ended")
    return M.isCutTreeDone() and "done" or "impossible"
end

-- ============================================
-- Run both quests (AxeKills → CutTree) ใน background
-- ============================================
function M.runBackground()
    task.spawn(function()
        if not M.isAxeKillsDone() then
            M.axeKillsLoop()
        end
        if not M.isCutTreeDone() then
            M.cutTreeLoop()
        end
    end)
end

return M
