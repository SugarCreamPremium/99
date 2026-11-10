-- ============================================
-- Module_Gunslinger.lua
-- Gunslinger class: finish the level-up quest
--   TrustyRevolverKills (the Trusty Revolver must land the killing shot).
-- GitHub: https://raw.githubusercontent.com/SugarCreamPremium/99/main/Module_Gunslinger.lua
--
-- Globals read at load time (set by MainScript before the module is loaded):
--   LocalPlayer, CLASS_QUESTS, classStatCache, __WSM_currentClass
-- Globals read lazily (defined later by MainScript):
--   Client, Config, findNightMonsters, checkAnyCultistSpawned, ensureFloating, zeroEnemyHealth,
--   finalGateBasePos, updateStatus, forceTeleportLobby, HOVER_HEIGHT
--
-- Weapon: Trusty Revolver (ReplicatedStorage.Tools.Firearm, a projectile weapon).
--   Shots are fired with the game's own click: Client.InventoryHandler.ActivateTool(Ray). The game spends the ammo,
--   starts its own reload when the magazine is empty and sends the hit by itself.
--   Instant bullets: the weapon attribute ProjectileSpeed is raised (default 100000, no travel time) and
--   workspace.Map + Terrain are appended to Client.CollisionUtility.ProjectileParams (bullets pass walls).
--   (Confirmed in game: 2 shots killed a Bunny and TrustyRevolverKills moved.)
--
-- Kill recipe : zero the monster's HP -> wait 1s -> ONE shot. Not yet confirmed that a zeroed monster counts for the
--               quest, so when TrustyRevolverKills does not move for STALL_KILLS kills the module switches to
--               "plain" mode (no HP zeroing anywhere, M.noZero() = true) and shoots until the monster is dead.
-- Ammo        : Revolver Ammo / Explosive Revolver Ammo items in workspace.Items are pulled next to the player and
--               consumed with RequestConsumeItem (confirmed: +6 reserve per Revolver Ammo, works at any distance).
--               Explosive Revolver Ammo is NOT confirmed yet: every result is logged.
-- Chests      : M.prepare() (called by MainScript after the warp to the Stronghold floor) opens every chest in
--               workspace.Items (tag "Chest" + Interaction "ItemChest") with RequestOpenItemChest and collects all ammo.
-- Out of ammo : chests all opened + no ammo item left + magazine and reserve empty -> Humanoid.Health = 0 (the Death
--               Watcher starts the next round, chests and ammo spawn again). Never inside a Stronghold phase.
-- Stronghold  : Module_Stronghold moves the player and calls M.strongholdHit(cultists, hrp);
--               M.specialWeaponOnly() makes Module_Stronghold skip the axe while the revolver can still shoot.
-- Quest done  : leave to the Lobby (outside a round right away, inside a round after it ends).
--
-- Config (all optional)
--   Config.GunslingerOutsideFarm    = true     -- hunt outside between Strongholds
--   Config.GunslingerHoverHeight    = 10       -- studs above the target (default _G.HOVER_HEIGHT or 10)
--   Config.GunslingerHitMode        = "zero"   -- "zero" (zero HP + one shot, auto switch) or "plain" (shoot only)
--   Config.GunslingerBulletSpeed    = 100000   -- lower it (~3000) if the server starts refusing the bullets
--   Config.GunslingerRefillBelow    = 12       -- collect ammo items when the reserve is at or below this
--   Config.GunslingerSkipNames      = {}       -- extra name fragments to never hunt (Deer is always skipped)
--   Config.GunslingerMaxAmmoFails   = 3        -- failures before an ammo item is given up for good
--   Config.GunslingerRetryDelay     = 120      -- seconds before a refused ammo item is tried again (times fails)
--   Config.GunslingerResetWhenOut   = true     -- kill the character when the ammo is really gone
--   Config.GunslingerChestFallback  = 8        -- max chests opened by the ProximityPrompt fallback
-- ============================================

local M = {}
local Log = _G.WSM_Log or {
    dev = function() end,
    err = function(reason, nextStep)
        warn("Error : " .. tostring(reason) .. " / " .. tostring(nextStep))
    end,
}

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LP = _G.LocalPlayer or Players.LocalPlayer
local CQ = _G.CLASS_QUESTS or {}
local CSC = _G.classStatCache or {}

local CLASS_NAME = "Gunslinger"
local KILLS_KEY = "TrustyRevolverKills"
local GUN_NAME = "Trusty Revolver"

M.isGunslinger = (_G.__WSM_currentClass or "Unknown") == CLASS_NAME

local LOBBY_PLACE_ID = 79546208627805
local TARGET_DEADLINE = 25           -- seconds per target before giving up on it
local ZERO_SETTLE = 1                -- seconds between zeroing the HP and the shot
local EQUIP_SETTLE = 1               -- the first shot after an equip can be refused: wait after RequestEquipItem
local DEATH_WAIT = 1.5               -- seconds to wait for the model to disappear after a shot
local EXTRA_ZERO_ROUNDS = 2          -- extra zero + shot rounds before plain shooting
local SHOT_PAD = 0.15                -- added to the weapon's FireRate between two shots
local STALL_KILLS = 15               -- kills without quest progress before switching to plain mode
local BLACKLIST_SECONDS = 60         -- a target that could not be killed is skipped for this long
local RESET_DEBOUNCE = 60            -- minimum seconds between two self-resets
local CHEST_OPEN_WAIT = 1.5          -- seconds to wait for the chests to change state
local LOOT_SETTLE = 3                -- seconds to wait for chest loot to drop
local STRONGHOLD_REFILL_BUDGET = 4   -- max seconds an ammo refill may block the Stronghold fight loop
local DEFAULT_BULLET_SPEED = 100000
local AMMO_NAME = "Revolver Ammo"
local EXPLOSIVE_AMMO_NAME = "Explosive Revolver Ammo"

-- ============================================
-- Helpers
-- ============================================
local function cfg(key, default)
    local c = _G.Config
    if type(c) == "table" and c[key] ~= nil then return c[key] end
    return default
end

local function status(text)
    local fn = _G.updateStatus
    if fn then pcall(fn, text) end
end

local function num(v)
    return type(v) == "number" and v or 0
end

local function isAlive()
    local c = LP.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    return h ~= nil and h.Health > 0
end

local function getHRP()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHead()
    local c = LP.Character
    return c and c:FindFirstChild("Head")
end

local function rootOf(model)
    return model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart")
end

local function wantsUpgrade()
    local list = cfg("UpgradeClass", nil)
    if type(list) ~= "table" then return false end
    for _, name in ipairs(list) do
        if name == CLASS_NAME then return true end
    end
    return false
end

local function hoverHeight()
    return cfg("GunslingerHoverHeight", _G.HOVER_HEIGHT or 10)
end

local function remote(name)
    local folder = ReplicatedStorage:FindFirstChild("RemoteEvents")
    local r = folder and folder:FindFirstChild(name)
    if r then return r end
    local c = _G.Client
    if c and c.Events then
        local ok, v = pcall(function() return c.Events[name] end)
        if ok then return v end
    end
    return nil
end

local function baseName(name)
    return (string.gsub(name, "_%d+$", ""))
end

local function itemsFolder()
    return workspace:FindFirstChild("Items")
end

local function itemPosition(item)
    local ok, cf = pcall(function() return item:GetPivot() end)
    return ok and cf and cf.Position or nil
end

-- ============================================
-- Quest checks (stats come from the ClassStatUpdated cache in MainScript)
-- ============================================
local function currentLevel()
    return LP:GetAttribute("ClassLevel") or 1
end

local function goal()
    local reqs = CQ[CLASS_NAME] and CQ[CLASS_NAME][currentLevel() + 1]
    return reqs and reqs[KILLS_KEY]
end

local function have()
    local s = CSC[CLASS_NAME]
    local v = s and s[KILLS_KEY]
    return type(v) == "number" and v or 0
end

function M.isAllQuestDone()
    local g = goal()
    return not g or have() >= g
end

-- true while the main loop is running
M.active = false

-- ============================================
-- Tools
-- ============================================
local function heldItem()
    local c = LP.Character
    local th = c and c:FindFirstChild("ToolHandle")
    local oi = th and th:FindFirstChild("OriginalItem")
    return oi and oi.Value or nil
end

local lastEquipAt = 0

-- RequestEquipItem rebuilds ToolHandle every time, so only call it when the item is not already held
local function equip(item)
    if not item or not item.Parent then return false end
    if heldItem() == item then return true end
    local client = _G.Client
    if not (client and client.InventoryHandler) then return false end
    lastEquipAt = tick()
    pcall(function() client.InventoryHandler.RequestEquipItem(item) end)
    for _ = 1, 15 do
        if heldItem() == item then return true end
        task.wait(0.1)
    end
    return false
end

local function getGun()
    local inv = LP:FindFirstChild("Inventory")
    if not inv then return nil end
    local g = inv:FindFirstChild(GUN_NAME)
    if g then return g end
    for _, tool in ipairs(inv:GetChildren()) do
        if tool:GetAttribute("ToolName") == "Firearm" and tool:GetAttribute("AmmoType") == "RevolverAmmo" then
            return tool
        end
    end
    return nil
end

-- reserve ammo = LocalPlayer attribute named like the weapon's AmmoType (drops on reload only)
local function reserveOf(gun)
    local ammoType = gun and gun:GetAttribute("AmmoType") or "RevolverAmmo"
    return num(LP:GetAttribute(ammoType))
end

-- magazine ammo = weapon attribute "Ammo" (server updates it after a shot); nil when unknown.
-- (Client.Interface.AmmoLabel is NOT used: it showed an explosion percentage in the last probe.)
local function magOf(gun)
    local v = gun and gun:GetAttribute("Ammo")
    return type(v) == "number" and v or nil
end

local function ammoStock()
    return num(LP:GetAttribute("RevolverAmmo")), num(LP:GetAttribute("ExplosiveRevolverAmmo"))
end

local function isReloading(gun)
    if gun:GetAttribute("ServerReloading") then return true end
    local finish = gun:GetAttribute("ReloadFinishTime")
    return type(finish) == "number" and time() < finish
end

local function fireRate(gun)
    local v = gun:GetAttribute("FireRate")
    return (type(v) == "number" and v > 0) and v or 0.6
end

local function reloadTime(gun)
    local v = gun:GetAttribute("ReloadTime")
    return (type(v) == "number" and v > 0) and v or 2
end

local pierceLogged = false
local pierceErrLogged = false

-- instant bullets: high ProjectileSpeed + Map/Terrain removed from the bullets' collision.
-- Safe to call again and again (it only touches what is missing).
local function applySetup(gun)
    local speed = cfg("GunslingerBulletSpeed", DEFAULT_BULLET_SPEED)
    if gun:GetAttribute("ProjectileSpeed") ~= speed then
        gun:SetAttribute("ProjectileSpeed", speed)
    end

    local client = _G.Client
    local ok, params = pcall(function() return client.CollisionUtility.ProjectileParams end)
    if not (ok and typeof(params) == "RaycastParams" and params.FilterType == Enum.RaycastFilterType.Exclude) then
        if not pierceErrLogged then
            pierceErrLogged = true
            Log.err("[Gunslinger] Client.CollisionUtility.ProjectileParams is not an Exclude RaycastParams",
                "bullets will not pass walls")
        end
        return
    end
    local list = params.FilterDescendantsInstances
    local missing = {}
    for _, extra in ipairs({ workspace:FindFirstChild("Map"), workspace.Terrain }) do
        if extra and not table.find(list, extra) then missing[#missing + 1] = extra end
    end
    if #missing > 0 then
        -- append once and never restore: the game keeps adding its own entries (cobwebs) to this list
        local newList = table.clone(list)
        for _, extra in ipairs(missing) do newList[#newList + 1] = extra end
        params.FilterDescendantsInstances = newList
        if not pierceLogged then
            pierceLogged = true
            Log.dev("[Gunslinger] bullets now pass through workspace.Map and Terrain, ProjectileSpeed = " .. tostring(speed))
        end
    end
end

-- hold the revolver, give the server a moment, then apply the instant-bullet setup
local function equipGun(gun)
    if not equip(gun) then return false end
    local remaining = EQUIP_SETTLE - (tick() - lastEquipAt)
    if remaining > 0 then task.wait(remaining) end
    applySetup(gun)
    return true
end

-- ============================================
-- Stronghold detection (same rules as the other modules)
-- ============================================
local function strongholdOpenTime()
    for _, sh in ipairs(CollectionService:GetTagged("Stronghold")) do
        if sh.Name ~= "AlienMothership" then
            local f = sh:FindFirstChild("Functional")
            local openTime = f and f:GetAttribute("OpenTime")
            if openTime then return openTime end
        end
    end
    return nil
end

-- a Stronghold round is running or about to run
local function strongholdOpen()
    local openTime = strongholdOpenTime()
    return openTime ~= nil and workspace:GetServerTimeNow() >= openTime
end

-- Module_Stronghold sets this from the start of a round until its diamonds are collected
local function roundActive()
    return _G.WSM_StrongholdRound == true
end

local function anyCultist()
    local fn = _G.checkAnyCultistSpawned
    return fn and fn() or false
end

-- ============================================
-- Movement
-- ============================================
local function clearFloating()
    local hrp = getHRP()
    if not hrp then return end
    for _, name in ipairs({ "FloatAlignPosition", "FloatAlignOrientation", "FloatAttachment" }) do
        local o = hrp:FindFirstChild(name)
        if o then pcall(function() o:Destroy() end) end
    end
end

-- keep the player floating at pos, facing down (warp when there is no float yet, then move the constraint)
local function hoverAt(pos)
    local hrp = getHRP()
    if not hrp then return end
    local cf = CFrame.new(pos) * CFrame.Angles(math.rad(-90), 0, 0)
    local ap = hrp:FindFirstChild("FloatAlignPosition")
    if not ap and _G.ensureFloating then
        hrp.CFrame = cf
        task.wait(0.2)
        pcall(_G.ensureFloating, pos)
        return
    end
    hrp.CFrame = cf
    if ap then ap.Position = pos end
    local ao = hrp:FindFirstChild("FloatAlignOrientation")
    if ao then ao.CFrame = cf end
end

local function warpBackToStronghold()
    local hrp = getHRP()
    if not (hrp and isAlive()) then return end
    local returnPos = _G.finalGateBasePos or hrp.Position
    for _ = 1, 3 do
        hrp.CFrame = CFrame.new(returnPos + Vector3.new(0, 10, 0)) * CFrame.Angles(math.rad(-90), 0, 0)
        task.wait(0.8)
    end
end

-- release the hover; warp = also go back to the Stronghold
local function leaveOutside(warp)
    clearFloating()
    if warp then warpBackToStronghold() end
end

-- ============================================
-- Monster state
-- ============================================
local function isDead(monster)
    return not monster.Parent
        or monster:GetAttribute("Dead") == true
        or monster:HasTag("CultistCorpse")
end

-- wait while following the monster; returns early when it dies / disappears or the player dies
local function trackWait(monster, seconds)
    local untilT = tick() + seconds
    while tick() < untilT do
        if not isAlive() or isDead(monster) then return end
        local root = rootOf(monster)
        if root then hoverAt(root.Position + Vector3.new(0, hoverHeight(), 0)) end
        task.wait(0.1)
    end
end

-- ============================================
-- Ammo items (workspace.Items): pull next to the player + RequestConsumeItem
-- ============================================
local deferred = setmetatable({}, { __mode = "k" })  -- [item] = { fails, retryAt, failReserve }
local collecting = false
local noDeltaLogged = false

local function maxAmmoFails()
    return cfg("GunslingerMaxAmmoFails", 3)
end

local function usable(item, reserve)
    local d = deferred[item]
    if not d then return true end
    if d.fails >= maxAmmoFails() then return false end
    -- parked: wait for the retry time, unless the reserve dropped well below the level where it was refused
    if os.clock() < d.retryAt and reserve > d.failReserve - 12 then return false end
    return true
end

-- plain Revolver Ammo first (confirmed), Explosive Revolver Ammo only when no plain one is usable
local function pickAmmoItem(reserve)
    local items = itemsFolder()
    if not items then return nil end
    local hrp = getHRP()
    local origin = hrp and hrp.Position or Vector3.zero
    local plain, plainDist
    local explosive, explosiveDist
    for _, item in ipairs(items:GetChildren()) do
        local base = baseName(item.Name)
        local isPlain = base == AMMO_NAME
        local isExplosive = base == EXPLOSIVE_AMMO_NAME
        if (isPlain or isExplosive) and item.Parent == items and usable(item, reserve) then
            local pos = itemPosition(item)
            local dist = pos and (pos - origin).Magnitude or math.huge
            if isPlain and (not plainDist or dist < plainDist) then
                plain, plainDist = item, dist
            elseif isExplosive and (not explosiveDist or dist < explosiveDist) then
                explosive, explosiveDist = item, dist
            end
        end
    end
    return plain or explosive
end

-- any ammo item that has not been given up on (parked ones count)
local function hasAmmoItems()
    local items = itemsFolder()
    if not items then return false end
    for _, item in ipairs(items:GetChildren()) do
        local base = baseName(item.Name)
        if (base == AMMO_NAME or base == EXPLOSIVE_AMMO_NAME) and item.Parent == items then
            local d = deferred[item]
            if not d or d.fails < maxAmmoFails() then return true end
        end
    end
    return false
end

-- same moves as Auto-Eat in MainScript: drag the item next to the player (no range check on the server)
local function pullItem(item)
    local hrp = getHRP()
    if not hrp then return false end
    return pcall(function()
        local folder = ReplicatedStorage:WaitForChild("RemoteEvents", 5)
        local startDrag = folder.RequestStartDraggingItem
        local stopDrag = folder.StopDraggingItem
        startDrag:FireServer(item)
        task.wait(0.1)
        if item:IsA("Model") then
            item:PivotTo(CFrame.new(hrp.Position))
        else
            item.CFrame = CFrame.new(hrp.Position)
        end
        task.wait(0.1)
        stopDrag:FireServer(item)
    end)
end

local function consumeItem(item)
    local parent = item.Parent
    local temp = ReplicatedStorage:FindFirstChild("TempStorage")
    if not temp then return false end
    item.Parent = temp
    local ok, res = pcall(function()
        local folder = ReplicatedStorage:FindFirstChild("RemoteEvents")
        return folder.RequestConsumeItem:InvokeServer(item)
    end)
    if not ok or not (type(res) == "table" and res.Success) then
        if item.Parent == temp then item.Parent = parent end
        return false
    end
    return true
end

-- consume ammo items until none is usable, the budget (seconds) runs out, maxItems is reached or the server keeps
-- refusing. Returns the number of items consumed.
local function collectAmmo(budget, maxItems)
    if collecting or not isAlive() then return 0 end
    collecting = true
    local startedAt = tick()
    local taken = 0
    local refusedStreak = 0

    local ok, err = pcall(function()
        while true do
            if budget and tick() - startedAt >= budget then return end
            if maxItems and taken >= maxItems then return end
            if not isAlive() then return end

            local gun = getGun()
            local reserve = gun and reserveOf(gun) or num(LP:GetAttribute("RevolverAmmo"))
            local item = pickAmmoItem(reserve)
            if not item then return end

            local name = item.Name
            local r0, e0 = ammoStock()
            pullItem(item)
            if consumeItem(item) then
                -- the attribute can lag a little behind the server's reply
                local waitUntil = tick() + 1.5
                while tick() < waitUntil do
                    local r, e = ammoStock()
                    if r > r0 or e > e0 then break end
                    task.wait(0.05)
                end
                local r1, e1 = ammoStock()
                taken += 1
                refusedStreak = 0
                deferred[item] = nil
                Log.dev(string.format("[Gunslinger] consumed %s: reserve %d -> %d | explosive reserve %d -> %d",
                    name, r0, r1, e0, e1))
                if r1 == r0 and e1 == e0 and not noDeltaLogged then
                    noDeltaLogged = true
                    Log.err("[Gunslinger] " .. name .. " was consumed but neither ammo attribute changed",
                        "continuing (logged only once)")
                end
            else
                local d = deferred[item] or { fails = 0, retryAt = 0, failReserve = reserve }
                d.fails += 1
                d.retryAt = os.clock() + cfg("GunslingerRetryDelay", 120) * d.fails
                d.failReserve = reserve
                deferred[item] = d
                refusedStreak += 1
                Log.err(string.format("[Gunslinger] %s was refused by the server (try %d/%d, reserve %d)",
                    name, d.fails, maxAmmoFails(), reserve), "skipping it for now, trying another item")
                if refusedStreak >= 3 then
                    Log.dev("[Gunslinger] 3 refusals in a row - stopping this collection run")
                    return
                end
            end
        end
    end)
    collecting = false
    if not ok then
        Log.err("[Gunslinger] ammo collection failed: " .. tostring(err), "retrying later")
    end
    return taken
end

function M.collectAmmo()
    return collectAmmo()
end

-- true when a shot is possible now or after collecting an ammo item
local function canShoot(gun)
    local mag = magOf(gun)
    if mag == nil or mag > 0 then return true end
    if reserveOf(gun) > 0 then return true end
    return pickAmmoItem(0) ~= nil
end

-- ============================================
-- Chests (workspace.Items, tag "Chest" + Interaction "ItemChest")
-- ============================================
local chestTried = setmetatable({}, { __mode = "k" })  -- chests the open attempt has already been made for

local function chestOpened(chest)
    if not chest.Parent then return true end
    if chest:GetAttribute("LocalOpened") == true then return true end
    return chest:GetAttribute(tostring(LP.UserId) .. "Opened") == true
end

local function listChests(onlyUnopened)
    local out = {}
    local items = itemsFolder()
    if not items then return out end
    for _, c in ipairs(items:GetChildren()) do
        if c:HasTag("Chest") and c:GetAttribute("Interaction") == "ItemChest" then
            if not onlyUnopened or (not chestOpened(c) and not chestTried[c]) then
                out[#out + 1] = c
            end
        end
    end
    return out
end

-- fallback (never needed in the probe): stand next to the chest and fire its ProximityPrompt
local function openByPrompt(chest)
    local hrp = getHRP()
    if not hrp then return false end
    local prompt = chest:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not prompt then return false end
    local ok, cf = pcall(function() return chest:GetPivot() end)
    if not (ok and cf) then return false end
    hrp.CFrame = CFrame.new(cf.Position + Vector3.new(0, 4, 0))
    task.wait(0.3)
    pcall(function()
        if typeof(fireproximityprompt) == "function" then
            fireproximityprompt(prompt, 0, true)
        else
            prompt:InputHoldBegin()
            task.wait(0.1)
            prompt:InputHoldEnd()
        end
    end)
    local untilT = tick() + 2
    while tick() < untilT do
        if chestOpened(chest) then return true end
        task.wait(0.1)
    end
    return chestOpened(chest)
end

-- fire RequestOpenItemChest at every closed chest at once (confirmed 37/37), then use the prompt for leftovers.
-- Returns opened, total.
local function openChests()
    local list = listChests(true)
    if #list == 0 then return 0, 0 end

    local ev = remote("RequestOpenItemChest")
    if not ev then
        for _, c in ipairs(list) do chestTried[c] = true end
        Log.err("[Gunslinger] RequestOpenItemChest remote not found", "chests are skipped")
        return 0, #list
    end
    for _, chest in ipairs(list) do
        pcall(function() ev:FireServer(chest) end)
    end

    local untilT = tick() + CHEST_OPEN_WAIT
    while tick() < untilT do
        local allOpen = true
        for _, c in ipairs(list) do
            if not chestOpened(c) then allOpen = false break end
        end
        if allOpen then break end
        task.wait(0.1)
    end

    local failed = {}
    for _, c in ipairs(list) do
        chestTried[c] = true
        if not chestOpened(c) then failed[#failed + 1] = c end
    end

    if #failed > 0 then
        local hrp = getHRP()
        local home = hrp and hrp.CFrame
        local limit = cfg("GunslingerChestFallback", 8)
        local used = 0
        for _, c in ipairs(failed) do
            if used >= limit or not isAlive() then break end
            used += 1
            pcall(openByPrompt, c)
        end
        -- back to where the character was (the Stronghold floor), the shield / platform stay untouched
        hrp = getHRP()
        if hrp and home then hrp.CFrame = home end
        local stillClosed = 0
        for _, c in ipairs(failed) do
            if not chestOpened(c) then
                stillClosed += 1
                Log.dev("[Gunslinger] chest not opened: " .. c.Name)
            end
        end
        if stillClosed > 0 then
            Log.err("[Gunslinger] " .. stillClosed .. " chest(s) could not be opened", "continuing without them")
        end
    end

    local opened = 0
    for _, c in ipairs(list) do
        if chestOpened(c) then opened += 1 end
    end
    return opened, #list
end

-- ============================================
-- Prepare: open every chest + collect all ammo (MainScript calls this after the warp to the Stronghold floor)
-- ============================================
local preparing = false
local prepareTries = 0
M.prepared = false

function M.prepare()
    if not (M.isGunslinger and wantsUpgrade()) then return false end
    if currentLevel() >= 3 or M.isAllQuestDone() then return false end
    if preparing then return false end
    preparing = true
    prepareTries += 1

    local ok, err = pcall(function()
        local r0, e0 = ammoStock()
        status("Gunslinger: opening chests")
        local opened, total = openChests()
        Log.dev(string.format("[Gunslinger] chests opened %d/%d", opened, total))
        if total > 0 then task.wait(LOOT_SETTLE) end

        status("Gunslinger: collecting ammo")
        local taken = collectAmmo()
        local r1, e1 = ammoStock()
        local gun = getGun()
        Log.dev(string.format("[Gunslinger] prepare done: %d ammo item(s) consumed | reserve %d -> %d | explosive reserve %d -> %d | magazine %s",
            taken, r0, r1, e0, e1, tostring(gun and magOf(gun))))
    end)
    preparing = false
    M.prepared = true
    if not ok then
        Log.err("[Gunslinger] prepare failed: " .. tostring(err), "continuing without it")
    end
    return ok
end

-- ============================================
-- Hit mode: "zero" = zero the HP, then one shot. "plain" = shoot only (no HP zeroing anywhere).
-- ============================================
local hitMode = nil -- resolved lazily from Config, then switched automatically
local function currentHitMode()
    if hitMode == nil then
        hitMode = (cfg("GunslingerHitMode", "zero") == "plain") and "plain" or "zero"
    end
    return hitMode
end

-- MainScript's zeroEnemyHealth asks this: true = refuse to zero any HP (plain mode)
function M.noZero()
    return M.active and M.isGunslinger and currentHitMode() == "plain" and not M.isAllQuestDone()
end

local killsSinceProgress = 0
local lastKillCount = -1
local plainStallLogged = false

local function noteKill()
    local n = have()
    if n ~= lastKillCount then
        lastKillCount = n
        killsSinceProgress = 0
        return
    end
    killsSinceProgress += 1
    if killsSinceProgress < STALL_KILLS then return end
    killsSinceProgress = 0
    local text = string.format("[Gunslinger] %s has not moved for %d kills (%d/%s)",
        KILLS_KEY, STALL_KILLS, n, tostring(goal()))
    if currentHitMode() == "zero" then
        hitMode = "plain"
        Log.err(text, "switching to plain shooting (no HP zeroing)")
    elseif not plainStallLogged then
        plainStallLogged = true
        Log.err(text, "still hunting (this error is logged only once)")
    end
end

-- ============================================
-- Shooting
-- ============================================
local lastShotAt = -10

-- the game's own click, spawned: an empty magazine makes Fire() wait for the whole reload inside the call
local function click(from, dir)
    local client = _G.Client
    local ih = client and client.InventoryHandler
    if not (ih and ih.ActivateTool) then return false end
    task.spawn(function()
        local ok, err = pcall(function()
            ih.ActivateTool(Ray.new(from, dir))
        end)
        if not ok then
            Log.err("[Gunslinger] ActivateTool failed: " .. tostring(err), "retrying on the next shot")
        end
    end)
    return true
end

local reloadMethodLogged = false

-- magazine is empty: let the game's own Fire() reload (keeps its client-side ammo in step); when the magazine
-- does not refill, call RequestReloadFirearm directly. Returns true when the magazine has ammo again.
local function reloadGun(gun, from, dir)
    if reserveOf(gun) <= 0 then return false end
    local rt = reloadTime(gun)

    if not isReloading(gun) then
        click(from, dir)
    end
    local untilT = tick() + rt + 2.5
    while tick() < untilT do
        local mag = magOf(gun)
        if mag and mag > 0 and not isReloading(gun) then return true end
        task.wait(0.1)
    end

    -- fallback: the server call the game's reload makes
    local r = remote("RequestReloadFirearm")
    if r then
        local ok, res = pcall(function() return r:InvokeServer(gun) end)
        if ok and type(res) == "table" and res.Success then
            task.wait(rt + 0.3)
            local mag = magOf(gun)
            if mag and mag > 0 then
                if not reloadMethodLogged then
                    reloadMethodLogged = true
                    Log.dev("[Gunslinger] reload needed the RequestReloadFirearm fallback")
                end
                return true
            end
        end
    end
    return false
end

-- Returns "ok" (a shot was sent), "noammo" (nothing left to shoot with) or "error".
local function shootAt(gun, monster)
    local head, root = getHead(), rootOf(monster)
    if not (head and root) then return "error" end

    -- wait out a running reload
    local guard = tick() + reloadTime(gun) + 3
    while isReloading(gun) and tick() < guard do task.wait(0.1) end

    local from = head.Position
    local dir = root.Position - from
    if dir.Magnitude < 0.5 then return "error" end

    local mag = magOf(gun)
    if mag ~= nil and mag <= 0 then
        if reserveOf(gun) <= 0 then
            collectAmmo(STRONGHOLD_REFILL_BUDGET) -- pick up an ammo item (if any) before giving up
        end
        if not reloadGun(gun, from, dir.Unit) then return "noammo" end
    end

    -- FireRate gate of the weapon (a shot inside it is dropped silently)
    local gap = fireRate(gun) + SHOT_PAD - (tick() - lastShotAt)
    if gap > 0 then task.wait(gap) end

    -- aim again: the monster and the player moved while waiting
    head, root = getHead(), rootOf(monster)
    if not (head and root) or isDead(monster) then return "error" end
    from = head.Position
    dir = root.Position - from
    if dir.Magnitude < 0.5 then return "error" end

    lastShotAt = tick()
    if not click(from, dir.Unit) then return "error" end
    return "ok"
end

-- ============================================
-- Kill sequence for one monster (outside a Stronghold)
-- Returns "killed", "failed" or "abort".
-- ============================================
local function killTarget(monster)
    local gun = getGun()
    if not gun then return "abort" end
    local deadline = tick() + TARGET_DEADLINE

    local function stop()
        return not isAlive() or tick() >= deadline or anyCultist() or M.isAllQuestDone()
    end

    local root = rootOf(monster)
    if not root then return "failed" end
    hoverAt(root.Position + Vector3.new(0, hoverHeight(), 0))
    if not equipGun(gun) then return "failed" end

    -- 1) zero mode: zero the HP, then one shot (repeated a few times when the monster survives)
    if currentHitMode() == "zero" then
        for _ = 1, 1 + EXTRA_ZERO_ROUNDS do
            if stop() then break end
            if isDead(monster) then return "killed" end
            pcall(_G.zeroEnemyHealth, monster)
            trackWait(monster, ZERO_SETTLE)
            if isDead(monster) then return "killed" end
            local r = shootAt(gun, monster)
            if r == "noammo" then return "abort" end
            if r == "error" then return "failed" end
            trackWait(monster, DEATH_WAIT)
            if isDead(monster) then return "killed" end
        end
    end

    -- 2) plain shooting until it dies (also the fallback when zeroing did not kill it)
    while not stop() do
        if isDead(monster) then return "killed" end
        local r = shootAt(gun, monster)
        if r == "noammo" then return "abort" end
        if r == "error" then
            if isDead(monster) then return "killed" end
            return "failed"
        end
        trackWait(monster, 0.3)
    end
    if isDead(monster) then return "killed" end
    return "failed"
end

-- ============================================
-- Stronghold hook (called by Module_Stronghold after it zeroed the cultists)
-- Returns false when the revolver cannot be used (the caller falls back to its normal hit).
-- ============================================
function M.strongholdHit(cultists, hrp)
    if type(cultists) ~= "table" then return false end
    if not isAlive() then return false end
    local gun = getGun()
    if not gun then return false end

    local me = getHRP() or hrp
    if not me then return false end

    if reserveOf(gun) <= cfg("GunslingerRefillBelow", 12) then
        collectAmmo(STRONGHOLD_REFILL_BUDGET)
    end
    if not canShoot(gun) then return false end
    if not equipGun(gun) then return false end

    local targets = {}
    for _, c in ipairs(cultists) do
        if c and c.Parent and not isDead(c) then
            pcall(_G.zeroEnemyHealth, c) -- quick zero again (finish mode calls this without its own wait); refused in plain mode
            targets[#targets + 1] = c
        end
    end
    if #targets == 0 then return true end

    local shotsSent = 0
    for _, c in ipairs(targets) do
        if not isAlive() then break end
        if c.Parent and not isDead(c) then
            local r = shootAt(gun, c)
            if r == "ok" then
                shotsSent += 1
            elseif r == "noammo" then
                break
            end
        end
    end
    if shotsSent == 0 then return false end

    -- give the server a moment to remove the cultists (kept short: the fight loop is waiting)
    local untilT = tick() + 0.5
    while tick() < untilT do
        local allDead = true
        for _, c in ipairs(targets) do
            if not isDead(c) then allDead = false break end
        end
        if allDead then break end
        task.wait(0.1)
    end
    return true
end

-- Module_Stronghold asks this every tick: true = revolver only (no axe hits).
-- False when the quest is done or the revolver is really out of ammo, so the axe clears the round.
function M.specialWeaponOnly()
    if not (M.active and M.isGunslinger) then return false end
    if M.isAllQuestDone() then return false end
    local gun = getGun()
    if not gun then return false end
    return canShoot(gun)
end

-- ============================================
-- Out of ammo
-- ============================================
-- really out: magazine and reserve empty, no ammo item left in the world and every chest opened (or given up on)
function M.ammoExhausted()
    local gun = getGun()
    if not gun then return false end
    local mag = magOf(gun)
    if mag == nil or mag > 0 then return false end
    if isReloading(gun) then return false end
    if reserveOf(gun) > 0 then return false end
    if hasAmmoItems() then return false end
    if #listChests(true) > 0 then return false end
    return true
end

local lastResetAt = -1000

-- kill the character (Death Watcher in MainScript presses Play Again and the game spawns chests / ammo again)
function M.resetCharacter(reason)
    if tick() - lastResetAt < RESET_DEBOUNCE then return false end
    lastResetAt = tick()
    _G.WSM_GunslingerResets = num(_G.WSM_GunslingerResets) + 1
    local gun = getGun()
    local r, e = ammoStock()
    Log.dev(string.format("[Gunslinger] resetting the character (#%d): %s | reserve %d | explosive reserve %d | magazine %s | quest %d/%s",
        _G.WSM_GunslingerResets, tostring(reason), r, e, tostring(gun and magOf(gun)), have(), tostring(goal())))
    status("Gunslinger: out of ammo - resetting")
    clearFloating()
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function() hum.Health = 0 end)
    end
    task.wait(1.5)
    if char and isAlive() then
        pcall(function() char:BreakJoints() end)
    end
    return true
end

-- ============================================
-- Hunt (outside a Stronghold)
-- ============================================
local blacklist = setmetatable({}, { __mode = "k" }) -- [monster] = time until which it is skipped

-- rabbits and bees are shot normally; deer (HP cannot be zeroed) and the Config names are never hunted
local function isSkippedName(name)
    local n = string.lower(name)
    if string.find(n, "deer", 1, true) then return true end
    local extra = cfg("GunslingerSkipNames", nil)
    if type(extra) == "table" then
        for _, word in ipairs(extra) do
            if type(word) == "string" and word ~= "" and string.find(n, string.lower(word), 1, true) then return true end
        end
    end
    return false
end

local function nearestOf(list, origin)
    local best, bestDist
    for _, m in ipairs(list) do
        local r = rootOf(m)
        if r then
            local d = (r.Position - origin).Magnitude
            if not bestDist or d < bestDist then best, bestDist = m, d end
        end
    end
    return best
end

local lastRefillScan = 0

-- collect ammo items when the reserve is low (throttled: scanning workspace.Items is not free)
local function refillIfLow(force)
    local gun = getGun()
    if not gun then return end
    if not force and reserveOf(gun) > cfg("GunslingerRefillBelow", 12) then return end
    if not force and tick() - lastRefillScan < 5 then return end
    lastRefillScan = tick()
    collectAmmo()
end

-- Returns true when something was attacked (so the caller does not idle).
local function huntCycle()
    local hrp = getHRP()
    if not hrp then return false end
    local gun = getGun()
    if not gun then return false end

    refillIfLow(false)
    if not canShoot(gun) then
        status("Gunslinger: out of ammo, waiting")
        task.wait(1)
        return false
    end

    local finder = _G.findNightMonsters
    local okFind, monsters = pcall(finder or function() return {} end)
    if not okFind or type(monsters) ~= "table" then return false end

    local now = tick()
    local alive = {}
    for _, m in ipairs(monsters) do
        local blockedUntil = blacklist[m]
        if m.Parent and not isDead(m) and not isSkippedName(m.Name)
            and not (blockedUntil and now < blockedUntil) then
            alive[#alive + 1] = m
        end
    end
    local target = nearestOf(alive, hrp.Position)
    if not target then return false end

    local result = killTarget(target)
    if result == "killed" then
        noteKill()
    elseif result == "failed" then
        blacklist[target] = tick() + BLACKLIST_SECONDS
        Log.dev("[Gunslinger] could not kill " .. tostring(target.Name) .. " - skipping it for " .. BLACKLIST_SECONDS .. "s")
    elseif result == "abort" then
        return false
    end
    return true
end

-- ============================================
-- Leave
-- ============================================
local lastLeaveAt = 0

local function leaveToLobby(reason)
    if tick() - lastLeaveAt < 20 then return end
    lastLeaveAt = tick()
    Log.dev("[Gunslinger] Leaving: " .. tostring(reason))
    leaveOutside(false)
    status("Gunslinger quest done - teleporting to Lobby")
    local fn = _G.forceTeleportLobby
    if fn then
        pcall(fn, "Gunslinger quest complete")
    else
        task.wait(2)
        pcall(function()
            game:GetService("TeleportService"):Teleport(LOBBY_PLACE_ID, LP)
        end)
        task.wait(5)
    end
end

-- ============================================
-- Loop
-- ============================================
local running = false
local resetDisabledLogged = false

function M.mainLoop()
    if not M.isGunslinger then return end
    if not wantsUpgrade() then
        Log.dev("[Gunslinger] Gunslinger is not in UpgradeClass - module idle")
        return
    end

    local waited = 0
    while not getGun() and waited < 60 do
        task.wait(1)
        waited += 1
    end
    if not getGun() then
        local names = {}
        local inv = LP:FindFirstChild("Inventory")
        if inv then
            for _, t in ipairs(inv:GetChildren()) do names[#names + 1] = t.Name end
        end
        Log.err("[Gunslinger] no " .. GUN_NAME .. " found in Inventory (items: " .. table.concat(names, ", ") .. ")",
            "the module is idle")
        return
    end

    M.active = true
    Log.dev("[Gunslinger] Loop started")
    local mode = "outside"

    while true do
        if not isAlive() then
            task.wait(1)
            continue
        end

        if not CQ[CLASS_NAME] or not CQ[CLASS_NAME][currentLevel() + 1] then
            Log.dev("[Gunslinger] No quest left at this level - loop ended")
            break
        end

        local fighting = anyCultist()
        local busy = fighting or roundActive() or strongholdOpen()

        if M.isAllQuestDone() then
            pcall(_G.WSM_QuestDone, CLASS_NAME) -- unified "[Quest] Done" line, printed once
            -- Outside a round: leave right away. Inside a round: play to the end, the Stronghold flow
            -- collects the diamonds and leaves by itself.
            if not busy then
                leaveToLobby("quest complete")
                task.wait(5)
            else
                status("Gunslinger quest complete - finishing the round")
                task.wait(0.5)
            end
            continue
        end

        if busy then
            if mode == "outside" then leaveOutside(fighting) end -- warp back only when cultists are out
            mode = "idle" -- Module_Stronghold moves the player and calls M.strongholdHit
            local gun = getGun()
            if gun and reserveOf(gun) <= cfg("GunslingerRefillBelow", 12) then
                pcall(collectAmmo, STRONGHOLD_REFILL_BUDGET)
            end
        else
            mode = "outside"
            if cfg("GunslingerOutsideFarm", true) then
                local ok, err = pcall(function()
                    -- safety net: the MainScript hook normally ran prepare() already
                    if not M.prepared and prepareTries < 2 then
                        M.prepare()
                    end
                    if M.ammoExhausted() then
                        if cfg("GunslingerResetWhenOut", true) then
                            M.resetCharacter("ammo exhausted: chests opened, no ammo item left, reserve and magazine empty")
                            task.wait(5)
                        else
                            if not resetDisabledLogged then
                                resetDisabledLogged = true
                                Log.err("[Gunslinger] out of ammo and GunslingerResetWhenOut is false", "waiting (logged only once)")
                            end
                            status("Gunslinger: out of ammo, reset disabled")
                            task.wait(5)
                        end
                    elseif not huntCycle() then
                        status("Gunslinger: waiting for monsters")
                        task.wait(1)
                    end
                end)
                if not ok then
                    Log.err("[Gunslinger] outside cycle failed: " .. tostring(err), "retrying in 1s")
                    task.wait(1)
                end
            end
        end

        task.wait(0.3)
    end
end

function M.runBackground()
    if running then return end
    running = true
    task.spawn(function()
        M.mainLoop()
        M.active = false
        running = false
    end)
end

function M.resume()
    M.runBackground()
end

return M