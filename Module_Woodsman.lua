-- ============================================
-- Module_Woodsman.lua / 9.04
-- Class implementation.
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/main/Module_Woodsman.lua
--
-- Class implementation.
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
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}
local Client = _G.Client
local Event = _G.Event
local ownerId = _G.ownerId

local function checkAnyCultistSpawned()
    local fn = _G.checkAnyCultistSpawned
    return type(fn) == "function" and fn() or false
end

local function findNightMonsters()
    local fn = _G.findNightMonsters
    return type(fn) == "function" and fn() or {}
end

local function ensureFloating(targetPos)
    local fn = _G.ensureFloating
    if type(fn) == "function" then fn(targetPos) end
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


local function collectTrees()
    local trees = {}
    local names = _G.CHOPPABLE_TREE_NAMES or {
        "Small Tree", "Fairy Small Tree", "Snowy Small Tree",
        "Birch Tree", "Dead Tree1", "Dead Tree2", "Dead Tree3",
    }
    local foliage = workspace:FindFirstChild("Map")
        and workspace.Map:FindFirstChild("Foliage")
    for _, item in ipairs(workspace:GetDescendants()) do
        if item:GetAttribute("Health")
            and table.find(names, item.Name)
            and (not foliage or item:IsDescendantOf(foliage)) then
            table.insert(trees, item)
        end
    end
    table.sort(trees, function(a, b)
        local pa = a:IsA("Model") and a:GetPivot().Position or a.Position
        local pb = b:IsA("Model") and b:GetPivot().Position or b.Position
        return pa.Magnitude < pb.Magnitude
    end)
    return trees
end

local function cleanupFloating(character)
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    for _, name in ipairs({"FloatAlignPosition", "FloatAlignOrientation", "FloatAttachment"}) do
        local object = hrp:FindFirstChild(name)
        if object then pcall(function() object:Destroy() end) end
    end
end

local function bindDeathCleanup(character)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid then humanoid.Died:Connect(function() cleanupFloating(character) end) end
end

if LP.Character then bindDeathCleanup(LP.Character) end
LP.CharacterAdded:Connect(bindDeathCleanup)
LP.CharacterRemoving:Connect(cleanupFloating)

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
    local lp = _G.LocalPlayer
    if not lp then
        local pl = game:GetService("Players")
        lp = pl.LocalPlayer or pl:WaitForChild("LocalPlayer")
    end
    if not lp then return nil end

    -- 1) Canonical equipped tool (preferred)
    local okClient, Client = pcall(function() return require(lp.PlayerScripts:WaitForChild("Client")) end)
    if okClient and Client and Client.InventoryHandler and Client.InventoryHandler.GetCurrentlyEquipped then
        local cur = Client.InventoryHandler.GetCurrentlyEquipped()
        if cur and ((cur.Name == "Woodsman's Axe") or (cur:GetAttribute("ToolName") == "GenericAxe")) then
            return cur
        end
    end

    -- 2) ToolHandle / OriginalItem (may be different Name from model)
    local char = lp.Character
    if char then
        local th = char:FindFirstChild("ToolHandle")
        local val = th and th:FindFirstChild("OriginalItem") and th.OriginalItem.Value
        if val and (val.Name == "Woodsman's Axe" or val:GetAttribute("ToolName") == "GenericAxe") then
            return val
        end
    end

    -- 3) Search Inventory direct + Data descendants (user says Data model holds axe)
    local function findIn(parent)
        if not parent then return nil end
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("Instance") and (child.Name == "Woodsman's Axe" or child:GetAttribute("ToolName") == "GenericAxe") then
                return child
            end
        end
        -- recursive fallback for nested Data/Tool folders
        for _, child in ipairs(parent:GetDescendants()) do
            if child:IsA("Instance") and (child.Name == "Woodsman's Axe" or child:GetAttribute("ToolName") == "GenericAxe") then
                -- only return if parent is Inventory or Data (not deep random templates)
                local p = child.Parent
                while p and p ~= lp do
                    if p.Name == "Inventory" or p.Name == "Data" then
                        return child
                    end
                    p = p.Parent
                end
            end
        end
        return nil
    end

    local inv = lp:FindFirstChild("Inventory")
    local data = lp:FindFirstChild("Data")
    local axe = findIn(inv) or findIn(data)
    if axe then
        return axe
    end
    -- final name-only fallback inside Inventory direct
    if inv then
        for _, tool in ipairs(inv:GetChildren()) do
            if tool.Name == "Woodsman's Axe" then return tool end
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
    local clientInv = (_G.Client and _G.Client.InventoryHandler) or (Client and Client.InventoryHandler)
    if not clientInv then
        warn("[Woodsman] InventoryHandler unavailable")
        return nil
    end
    pcall(function() clientInv.RequestEquipItem(axe) end)
    for i = 1, 30 do
        task.wait(0.1)
        local char = LP.Character
        local th = char and char:FindFirstChild("ToolHandle")
        local val = th and th:FindFirstChild("OriginalItem") and th.OriginalItem.Value
        if val and (val.Name == "Woodsman's Axe" or val:GetAttribute("ToolName") == "GenericAxe" or (val.Name and val.Name:find("Axe"))) then
            return val
        end
    end
    return nil
end

function M.ensureEquipped()
    local char = LP.Character
    local th = char and char:FindFirstChild("ToolHandle")
    local cur = th and th:FindFirstChild("OriginalItem") and th.OriginalItem.Value
    if cur and (cur.Name == "Woodsman's Axe" or cur:GetAttribute("ToolName") == "GenericAxe") then
        return cur
    end
    return M.equipAxe()
end

-- ============================================
-- Main loops
-- ============================================
function M.waitForMonsters(maxWait)
    local waited = 0
    while waited < maxWait do
        local list = findNightMonsters()
        if #list > 0 then return true end
        task.wait(0.5)
        waited += 0.5
    end
    return false
end

function M.axeKillsLoop()
    if not M.isWoodsman then return "skip" end
    if M.isAxeKillsDone() then return "done" end

    local axe = M.equipAxe()
    if not axe then
        warn("[Woodsman] Woodsman's Axe not found in Inventory - cannot fight, will skip hits")
        warpBackToStronghold()
        return "impossible"
    end

    while M.isWoodsman and isCharacterAlive() and not M.isAxeKillsDone() do
        if checkAnyCultistSpawned() then
            print("[Woodsman] Stronghold opened, pausing NightLoop")
            return "stronghold"
        end

        local findOk, monsters = pcall(findNightMonsters)
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
            if checkAnyCultistSpawned() then return "stronghold" end
            if not (monster and monster.Parent) then continue end

            local hrp = LP.Character
                and LP.Character:FindFirstChild("HumanoidRootPart")
            local root = monster:FindFirstChild("HumanoidRootPart")
                or monster.PrimaryPart
            if not (hrp and root) then continue end

            local axeRef = M.ensureEquipped()
            if not axeRef then
                warn("[Woodsman] No Woodsman's Axe - skipping hit")
                warpBackToStronghold()
                return "impossible"
            end

            -- Class implementation.
            local targetPos = root.Position + Vector3.new(0, 20, 0)
            if not _G.floatAP or not _G.floatAP.Parent then
                hrp.CFrame = CFrame.new(targetPos)
                task.wait(0.2)
                ensureFloating(targetPos)
            else
                _G.floatAP.Position = targetPos
                hrp.CFrame = CFrame.new(targetPos)
            end

            -- Class implementation.
            if type(_G.zeroEnemyHealth) == "function" then
                pcall(_G.zeroEnemyHealth, monster)
            end
            task.wait(1)

            local hitCount = 0
            while monster.Parent and isCharacterAlive() and hitCount < 200 do
                local currentHrp = LP.Character
                    and LP.Character:FindFirstChild("HumanoidRootPart")
                if not currentHrp then break end

                local ok, err = pcall(function()
                    local ev = (_G.Event and _G.Event or Event)
                    ev:InvokeServer(monster, axeRef, (_G.ownerId or ownerId), currentHrp.CFrame, false)
                end)
                if not ok then
                    warn("[Woodsman] InvokeServer error: " .. tostring(err))
                    break
                end

                hitCount += 1
                task.wait(0.1)
            end
        end
    end

    local done = M.isAxeKillsDone()
    warpBackToStronghold()
    print("[Woodsman] Loop ended")
    return done and "done" or "impossible"
end

function M.cutTreeLoop()
    if not M.isWoodsman then return "skip" end
    if M.isCutTreeDone() then return "done" end

    print("[Woodsman] Loop started")

    local axe = M.equipAxe()
    if not axe then
        warn("[Woodsman] Woodsman's Axe not found in Inventory - cannot fight, will skip hits")
        warpBackToStronghold()
        return "impossible"
    end

    local NO_TREE_LIMIT = 3
    local noTreeRounds = 0

    while M.isWoodsman and isCharacterAlive() and not M.isCutTreeDone() do
        if checkAnyCultistSpawned() then
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
            -- Class implementation.
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
            if checkAnyCultistSpawned() then return "stronghold" end

            if not (tree and tree.Parent) then continue end
            if not tree:IsDescendantOf(workspace.Map.Foliage) then continue end

            local hrp = LP.Character
                and LP.Character:FindFirstChild("HumanoidRootPart")
            if not hrp then
                warn("[Woodsman] No HumanoidRootPart - cannot warp, breaking")
                warpBackToStronghold()
                return "impossible"
            end

            local axeRef = M.ensureEquipped()
            if not axeRef then
                warn("[Woodsman] Woodsman's Axe missing - cannot continue")
                warpBackToStronghold()
                return "impossible"
            end

            local treePos = tree:IsA("Model")
                and tree:GetPivot().Position or tree.Position
            local cutPos = treePos + Vector3.new(0, 30, 0)

            -- Class implementation.
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
                ensureFloating(walkPos)
            else
                _G.floatAP.Position = walkPos
                hrp.CFrame = CFrame.new(walkPos)
            end

            local hitCount = 0
            local treeParent = tree.Parent
            while tree.Parent == treeParent
                and tree:IsDescendantOf(workspace.Map.Foliage)
                and isCharacterAlive()
                and hitCount < 200 do
                if M.isCutTreeDone() then break end
                if checkAnyCultistSpawned() then return "stronghold" end

                hrp = LP.Character
                    and LP.Character:FindFirstChild("HumanoidRootPart")
                if not hrp then break end

                local ev = (_G.Event and _G.Event or Event)
                local ok, err = pcall(function() ev:InvokeServer(tree, axeRef, (_G.ownerId or ownerId), hrp.CFrame, false) end)
                if not ok then
                    warn("[Woodsman] Tree hit error: " .. tostring(err))
                    break
                end
                hitCount += 1
                task.wait(0.1)
            end
        end
    end

    local done = M.isCutTreeDone()
    warpBackToStronghold()
    print("[Woodsman] Loop ended")
    return done and "done" or "impossible"
end

-- ============================================
-- Class implementation.
-- ============================================
function M.runBackground()
    task.spawn(function()
        if not M.isAxeKillsDone() then
            local result = M.axeKillsLoop()
            if result ~= "done" then
                if isCharacterAlive() then warpBackToStronghold() end
                return
            end
        end
        if isCharacterAlive() and not M.isCutTreeDone() then
            local result = M.cutTreeLoop()
            if result ~= "done" then
                if isCharacterAlive() then warpBackToStronghold() end
                return
            end
        end
        if isCharacterAlive() then
            warpBackToStronghold()
        end
    end)
end

function M.resume()
    M.runBackground()
end


return M
