-- ============================================
-- Module_Vampire.lua
-- Vampire class helpers + night loop (โหลดผ่าน loadstring)
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/refs/heads/main/Module_Vampire.lua
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
--   - floatAP, floatAO (floating variables)
--   - combatCenter (Vector3), HOVER_HEIGHT (number), ATTACK_INTERVAL (number)
--   - finishMode (bool) - shared with AlienScientist
-- ============================================

local M = {}

-- ============================================
-- Quest checks
-- ============================================
-- Setup
-- ============================================
local LP = _G.LocalPlayer or game:GetService("Players").LocalPlayer
local CQ = _G.CLASS_QUESTS
local CSC = _G.classStatCache

-- ============================================
M.isVampire = (_G.__WSM_currentClass or "Unknown") == "Vampire"

local function getVampireScythe()
    local inv = LP:FindFirstChild("Inventory")
    return inv and inv:FindFirstChild("Vampire Scythe")
end

function M.isLifestealDone()
    local lvl = LP:GetAttribute("ClassLevel") or 1
    local reqs = CQ["Vampire"] and CQ["Vampire"][lvl + 1]
    if not reqs or not reqs.LifestealHealing then return true end
    local have = CSC["Vampire"]
        and CSC["Vampire"]["LifestealHealing"] or 0
    return have >= reqs.LifestealHealing
end

function M.isDealDamageDone()
    local lvl = LP:GetAttribute("ClassLevel") or 1
    local reqs = CQ["Vampire"] and CQ["Vampire"][lvl + 1]
    if not reqs or not reqs.DealDamage then return true end
    local have = CSC["Vampire"]
        and CSC["Vampire"]["DealDamage"] or 0
    return have >= reqs.DealDamage
end

function M.isAllQuestDone()
    return M.isLifestealDone() and M.isDealDamageDone()
end

-- ============================================
-- HP helpers
-- ============================================
local function getMyHumanoid()
    local myChar = workspace:FindFirstChild(LP.Name)
    return myChar and myChar:FindFirstChildOfClass("Humanoid")
end

-- ลด HP ตัวเองเหลือ 1 (เรียกก่อนตี ถ้า Quest Lifesteal ยังไม่เสร็จ)
function M.keepHPOne()
    local hum = getMyHumanoid()
    if hum and hum.Health > 1 then
        pcall(function() hum.Health = 1 end)
    end
end

-- เซ็ต HP กลับ 100 (เรียกเมื่อ Lifesteal Quest เสร็จ)
function M.restoreHP()
    local hum = getMyHumanoid()
    if hum and hum.Health < 100 then
        pcall(function() hum.Health = 100 end)
    end
end

-- ============================================
-- Night loop
-- ============================================
function M.nightLoop()
    if not M.isVampire then return end
    print("[Vampire] Night loop started")
    local lastLoggedState = nil
    local wasNight = false
    local scythe = getVampireScythe()

    if not scythe then
        warn("[Vampire] Vampire Scythe not found in Inventory - cannot fight, will skip hits")
    end
    if not LP:FindFirstChild("Inventory") then
        warn("[Vampire] LocalPlayer.Inventory not found - cannot proceed")
    end

    while M.isVampire and not M.isAllQuestDone() do
        local stateOk, stateOrErr = pcall(function()
            return workspace:GetAttribute("State")
        end)
        if not stateOk then
            warn(string.format("[Vampire] Failed to read workspace:GetAttribute('State'): %s", tostring(stateOrErr)))
        elseif stateOrErr == nil then
            warn("[Vampire] workspace:GetAttribute('State') returned nil - game may not be initialized, waiting...")
            task.wait(5)
        else
            if lastLoggedState ~= stateOrErr then
                print(string.format("[Vampire] Current state: %s", tostring(stateOrErr)))
                lastLoggedState = stateOrErr
            end
            if stateOrErr == "Night" then
                if not wasNight then
                    print("[Vampire] State changed to Night")
                    wasNight = true
                end

                -- quest check
                local questOk, questResult = pcall(M.isAllQuestDone)
                if not questOk then
                    warn(string.format("[Vampire] isVampireAllQuestDone() error: %s", tostring(questResult)))
                elseif questResult then
                    print(string.format("[Vampire] Quests done: Lifesteal %d/%d, DealDamage %d/%d",
                        CSC["Vampire"] and CSC["Vampire"]["LifestealHealing"] or 0,
                        CQ["Vampire"] and CQ["Vampire"][(LP:GetAttribute("ClassLevel") or 1) + 1]
                            and CQ["Vampire"][(LP:GetAttribute("ClassLevel") or 1) + 1].LifestealHealing or 0,
                        CSC["Vampire"] and CSC["Vampire"]["DealDamage"] or 0,
                        CQ["Vampire"] and CQ["Vampire"][(LP:GetAttribute("ClassLevel") or 1) + 1]
                            and CQ["Vampire"][(LP:GetAttribute("ClassLevel") or 1) + 1].DealDamage or 0))
                    break
                else
                    local humOk, humErr = pcall(function()
                        local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
                        if hum and hum.Health < 100 then
                            hum.Health = 100
                        end
                    end)
                    if not humOk then
                        warn(string.format("[Vampire] restoreHP() error: %s", tostring(humErr)))
                    end
                end

                if _G.checkAnyCultistSpawned() then
                    print("[Vampire] Stronghold opened (Cultist found), pausing NightLoop for Stronghold")
                    return
                end

                print("[Vampire] State=Night, scanning for monsters")
                local findOk, findErr = pcall(_G.findNightMonsters)
                if not findOk then
                    warn(string.format("[Vampire] findNightMonsters() error: %s", tostring(findErr)))
                    task.wait(5)
                else
                    local monsters = findErr
                    if not monsters or #monsters == 0 then
                        warn("[Vampire] No hittable monsters found in workspace.Characters - waiting 1s")
                        task.wait(1)
                    else
                        print(string.format("[Vampire] Found %d monster(s) to fight", #monsters))
                        -- ตีทีละตัว
                        for _, m in ipairs(monsters) do
                            if not (m and m.Parent) then continue end
                            if M.isAllQuestDone() then break end
                            if _G.checkAnyCultistSpawned() then
                                print("[Vampire] Cultist found during fight - pausing")
                                return
                            end
                            -- ลด HP ตัวเองก่อนตี
                            M.keepHPOne()
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
                            -- ตี (ลด HP มอน 0 + InvokeServer)
                            _G.zeroEnemyHealth(m)
                            if scythe then
                                pcall(function()
                                    Event:InvokeServer(m, scythe, ownerId, hrp.CFrame, false)
                                end)
                            end
                            task.wait(_G.ATTACK_INTERVAL or 0.18)
                        end
                    end
                end
            else
                -- Daytime
                if wasNight then
                    print("[Vampire] State changed to Day - warping back to Stronghold Floor")
                    wasNight = false
                end
                print(string.format("[Vampire] Waiting for night (State: %s)", tostring(stateOrErr)))
                task.wait(2)
            end
        end
    end

    print("[Vampire] Night loop ended, at Stronghold")
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
