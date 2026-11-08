-- Module_FancyDressed.lua
-- Fancy Dressed has nothing to farm here: CollectCostumePiece and TrickOrTreat are already
-- progressed by the AutoCandy background thread in MainScript.
-- This module only decides WHEN to go back to the Lobby: once both quests of the next level are done,
-- and never in the middle of a Stronghold round (Module_Stronghold leaves after the diamonds).

local M = {}

local CLASS = "Fancy Dressed"
local LOBBY_PLACE_ID = 79546208627805

M.isFancyDressed = false
M.active = false

local Log = _G.WSM_Log or {
    dev = function() end,
    err = function(reason, nextStep) warn("Error : " .. tostring(reason) .. " / " .. tostring(nextStep)) end,
}
local LP = game:GetService("Players").LocalPlayer

local function cfg(key, default)
    local c = _G.Config
    if type(c) == "table" and c[key] ~= nil then return c[key] end
    return default
end

local function status(text)
    if type(_G.updateStatus) == "function" then pcall(_G.updateStatus, text) end
end

local function wantsUpgrade()
    local list = cfg("UpgradeClass", nil)
    return type(list) == "table" and table.find(list, CLASS) ~= nil
end

local function currentLevel()
    return LP:GetAttribute("ClassLevel") or 1
end

-- Goals of the next level, nil when there is no quest (Lv.3 reached or unknown class)
local function questGoals()
    local quests = _G.CLASS_QUESTS or {}
    local forClass = quests[CLASS]
    return forClass and forClass[currentLevel() + 1] or nil
end

-- True when every stat of the next level has reached its goal (cache first, ClassProgress as fallback)
local function questComplete()
    local goals = questGoals()
    if not goals then return true end
    local cache = (_G.classStatCache or {})[CLASS]
    local progress = LP:FindFirstChild("ClassProgress")
    local folder = progress and progress:FindFirstChild(CLASS)
    for stat, goal in pairs(goals) do
        local have = cache and cache[stat]
        if type(have) ~= "number" and folder then have = folder:GetAttribute(stat) end
        if type(have) ~= "number" or have < goal then return false end
    end
    return true
end

function M.isAllQuestDone()
    if not M.isFancyDressed then return true end
    if currentLevel() >= 3 then return true end
    return questComplete()
end

-- Same rule as the other modules: OpenTime of the Stronghold tag <= server time means the room is open
local function strongholdOpen()
    local ok, open = pcall(function()
        for _, sh in ipairs(game:GetService("CollectionService"):GetTagged("Stronghold")) do
            if sh.Name ~= "AlienMothership" then
                local functional = sh:FindFirstChild("Functional")
                local openTime = functional and functional:GetAttribute("OpenTime")
                if type(openTime) == "number" and openTime <= workspace:GetServerTimeNow() then
                    return true
                end
            end
        end
        return false
    end)
    return ok and open == true
end

local function anyCultist()
    if type(_G.checkAnyCultistSpawned) ~= "function" then return false end
    local ok, result = pcall(_G.checkAnyCultistSpawned)
    return ok and result == true
end

local function roundActive()
    return _G.WSM_StrongholdRound == true
end

local lastLeave = 0
local function leaveToLobby()
    if game.PlaceId == LOBBY_PLACE_ID then return end
    if tick() - lastLeave < 20 then return end
    lastLeave = tick()
    status("Fancy Dressed quest done - leaving")
    if type(_G.forceTeleportLobby) == "function" then
        pcall(_G.forceTeleportLobby, "Fancy Dressed quest complete")
    else
        pcall(function()
            game:GetService("TeleportService"):Teleport(LOBBY_PLACE_ID, LP)
        end)
    end
end

function M.mainLoop()
    if not M.isFancyDressed or not wantsUpgrade() then return end
    M.active = true
    Log.dev("[FancyDressed] Watching quests (costume pieces + trick or treat)")

    while true do
        task.wait(1)
        if not questGoals() then break end

        if questComplete() then
            pcall(_G.WSM_QuestDone, CLASS)
            local busy = anyCultist() or roundActive() or strongholdOpen()
            if busy then
                status("Quest done - finishing the round")
            else
                leaveToLobby()
            end
        end
    end
    M.active = false
end

local running = false
function M.runBackground()
    if running then return end
    running = true
    task.spawn(function()
        local ok, err = pcall(M.mainLoop)
        if not ok then
            Log.err("[FancyDressed] main loop crashed: " .. tostring(err), "Fancy Dressed Lobby return is stopped")
        end
        running = false
    end)
end

function M.resume()
    M.runBackground()
end

return M
