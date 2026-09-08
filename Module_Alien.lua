-- ============================================
-- Module_Alien.lua
-- Alien Scientist class helpers + night loop (โหลดผ่าน loadstring)
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/refs/heads/main/Module_Alien.lua
--
-- Dependencies (globals ที่ MainScript ต้อง set ก่อน):
--   - LocalPlayer
--   - dissolveRemote (RequestDissolveEnemy)
--   - CLASS_QUESTS, classStatCache
--   - findNightMonsters, checkAnyCultistSpawned, zeroEnemyHealth
--   - floatAP, floatAO, ensureFloating
--   - HOVER_HEIGHT, ATTACK_INTERVAL
-- ============================================

local M = {}

local LP = _G.LocalPlayer or game:GetService("Players").LocalPlayer
local CQ = _G.CLASS_QUESTS
local CSC = _G.classStatCache

-- ============================================
-- Quest checks
-- ============================================
M.isAlienScientist = (_G.__WSM_currentClass or "Unknown") == "Alien Scientist"

local function getDissolveRay()
    local inv = LP:FindFirstChild("Inventory")
    return inv and inv:FindFirstChild("Dissolve Ray")
end

function M.isAllQuestDone()
    local lvl = LP:GetAttribute("ClassLevel") or 1
    local reqs = CQ["Alien Scientist"]
        and CQ["Alien Scientist"][lvl + 1]
    if not reqs or not reqs.Dissolves then return true end
    local have = CSC["Alien Scientist"]
        and CSC["Alien Scientist"]["Dissolves"] or 0
    return have >= reqs.Dissolves
end

-- ============================================
-- Night loop
-- ============================================
function M.nightLoop()
    if not M.isAlienScientist then return end
    print("[AlienScientist] Night loop started")
    local ray = getDissolveRay()
    local remote = _G.dissolveRemote

    if not ray then
        warn("[AlienScientist] Dissolve Ray not found in Inventory")
    end
    if not remote then
        warn("[AlienScientist] RequestDissolveEnemy remote not resolved")
    end

    while M.isAlienScientist and not M.isAllQuestDone() do
        local stateOk, stateOrErr = pcall(function()
            return workspace:GetAttribute("State")
        end)
        if not stateOk then
            warn(string.format("[AlienScientist] State read error: %s", tostring(stateOrErr)))
            task.wait(2)
        elseif stateOrErr == "Night" then
            print("[AlienScientist] State=Night")
            if _G.checkAnyCultistSpawned() then
                print("[AlienScientist] Stronghold opened, pausing NightLoop")
                return
            end

            local questOk, questResult = pcall(M.isAllQuestDone)
            if not questOk then
                warn(string.format("[AlienScientist] isAlienScientistAllQuestDone() error: %s", tostring(questResult)))
            elseif questResult then
                local lvl = LP:GetAttribute("ClassLevel") or 1
                local goal = (CQ["Alien Scientist"]
                    and CQ["Alien Scientist"][lvl + 1]
                    and CQ["Alien Scientist"][lvl + 1].Dissolves) or 0
                local have = CSC["Alien Scientist"]
                    and CSC["Alien Scientist"]["Dissolves"] or 0
                print(string.format("[AlienScientist] Quest done: Dissolves %d/%d", have, goal))
                return
            end

            if _G.checkAnyCultistSpawned() then
                print("[AlienScientist] Stronghold opened, pausing NightLoop")
                return
            end

            local findOk, findResult = pcall(_G.findNightMonsters)
            if not findOk then
                warn(string.format("[AlienScientist] findNightMonsters error: %s", tostring(findResult)))
                task.wait(2)
            else
                local monsters = findResult
                if not monsters or #monsters == 0 then
                    warn("[AlienScientist] No hittable monsters found - waiting 1s")
                    task.wait(1)
                else
                    for _, m in ipairs(monsters) do
                        if M.isAllQuestDone() then break end
                        if _G.checkAnyCultistSpawned() then return end
                        if not (m and m.Parent) then continue end

                        -- ตรวจ Bunny (ไม่ dissolve)
                        if m.Name == "Bunny" then continue end

                        -- Equip Dissolve Ray
                        if not ray then
                            ray = getDissolveRay()
                        end
                        if not ray then continue end

                        -- ลอยเหนือมอน
                        local hrp = LP.Character
                            and LP.Character:FindFirstChild("HumanoidRootPart")
                        local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
                        if hrp and root then
                            if not _G.floatAP or not _G.floatAP.Parent then
                                hrp.CFrame = CFrame.new(root.Position + Vector3.new(0, _G.HOVER_HEIGHT, 0))
                                task.wait(0.2)
                                _G.ensureFloating(root.Position + Vector3.new(0, _G.HOVER_HEIGHT, 0))
                            else
                                _G.floatAP.Position = root.Position + Vector3.new(0, _G.HOVER_HEIGHT, 0)
                                hrp.CFrame = CFrame.new(_G.floatAP.Position)
                            end
                        end

                        -- Kill: zero HP + dissolve remote
                        _G.zeroEnemyHealth(m)
                        if remote then
                            pcall(function() remote:InvokeServer(m) end)
                        end
                        task.wait(_G.ATTACK_INTERVAL or 0.18)
                    end
                end
            end
        elseif stateOrErr == "Day" then
            print("[AlienScientist] Daytime arrived, warping back + waiting for next night")
            task.wait(5)
        else
            print(string.format("[AlienScientist] Waiting for night (State: %s)", tostring(stateOrErr)))
            task.wait(2)
        end
    end

    print("[AlienScientist] Night loop ended, at Stronghold")
end

-- ============================================
-- Run in background
-- ============================================
function M.runBackground()
    task.spawn(M.nightLoop)
end

-- Resume (เรียกตอน round end ถ้า quest ยังไม่เสร็จ)
function M.resume()
    M.nightLoop()
end

return M
