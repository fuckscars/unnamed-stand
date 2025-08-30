--==[ Stand Controller (UE-Methods Safe) ]==--

local api = getfenv().api or {}            -- survive if api is missing
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local currentview = false
local LocalPlayer = Players.LocalPlayer
local stand = LocalPlayer.Character
local voidPos = Vector3.new(0, -1000, 0)
local following = false
local returnCFrame = nil
local killed = false
local doing_task = false
local got_weapon = {Value = false}
local isspec = false
local oldcamsub = nil
local camera = workspace.CurrentCamera
local gunname = 'AUG'
local strafingConn = nil

local framework = {
    connections = {},
    ownerName = "slakkenhuis",
}

----------------------------------------------------------------
-- Small helpers to safely call UE API without exploding
----------------------------------------------------------------
local function safe(methodName, ...)
    local fn = api and api[methodName]
    if typeof(fn) == "function" then
        local ok, res = pcall(fn, api, ...)
        if ok then return res end
    end
    return nil
end

local function notify(msg, t)
    t = t or 4
    if typeof(api.Notify) == "function" then
        pcall(api.Notify, api, "[Stand] " .. tostring(msg), t)
    else
        -- fallback
        warn("[Stand] " .. tostring(msg))
    end
end

-- Get or create UE "target cache" (sticky aim list)
local function getTargetCache()
    local cache = safe("GetTargetCache")
    if typeof(cache) ~= "table" then
        cache = {}
    end
    return cache
end

-- Try to set a UE config key (new method names first, fall back to Toggles)
local function setConfigBool(key, value)
    if safe("SetConfigValue", key, value) ~= nil then return true end
    if safe("SetConfig", key, value) ~= nil then return true end
    -- legacy toggles fallback
    if key == "ragebot.disable_rendering" then
        if Toggles and Toggles.ragebot_disable_rendering and typeof(Toggles.ragebot_disable_rendering.SetValue) == "function" then
            Toggles.ragebot_disable_rendering:SetValue(value)
            return true
        end
    end
    return false
end

-- Is ragebot present?
local function hasRagebot()
    local ok = safe("IsRagebot")
    if ok ~= nil then return ok end
    -- heuristic: check for legacy Toggles
    return (Toggles and Toggles.ragebot_enabled ~= nil) or false
end

-- Bind to UE command bus if available (so you could later add api:OnCommand hooks)
local function onCommand(pattern, handler)
    if typeof(api.OnCommand) == "function" then
        pcall(api.OnCommand, api, pattern, handler)
        return true
    end
    return false
end

----------------------------------------------------------------
-- STRAFING (Target Strafe)
----------------------------------------------------------------
local function startStrafing(targetPlayer, speed)
    if strafingConn then strafingConn:Disconnect() end
    if not (targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart")) then return end

    local radius = 5
    speed = tonumber(speed) or 8
    local startTime = tick()

    strafingConn = RunService.Heartbeat:Connect(function()
        local elapsed = tick() - startTime
        local angle = elapsed * speed
        local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)

        local targetHRP = targetPlayer.Character:FindFirstChild("HumanoidRootPart")
        local myHRP = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")

        if targetHRP and myHRP then
            myHRP.CFrame = CFrame.new(targetHRP.Position + offset)
        else
            strafingConn:Disconnect()
            strafingConn = nil
        end
    end)
end

local function stopStrafing()
    if strafingConn then
        strafingConn:Disconnect()
        strafingConn = nil
    end
end

----------------------------------------------------------------
-- UI (guarded; won’t crash if methods moved)
----------------------------------------------------------------
do
    local addTab = api.AddTab
    if typeof(addTab) == "function" then
        local ok, tab = pcall(addTab, api, "Stand")
        if ok and tab and typeof(tab.AddLeftGroupbox) == "function" then
            local gb = tab:AddLeftGroupbox("Control")
            if gb and typeof(gb.AddInput) == "function" then
                gb:AddInput("stand_owner_input", {
                    Text = "Owner Username",
                    Default = framework.ownerName,
                    Placeholder = "slakkenhuis",
                    Tooltip = "Set the user who controls the stand",
                    Callback = function(value)
                        framework.ownerName = value
                        notify("Stand owner set to: " .. value, 3)
                        connectToOwner()
                    end
                })
            end
        end
    end
end

----------------------------------------------------------------
-- Weapons + Shop (kept, but “modernized” with tool cache if available)
----------------------------------------------------------------
local weapons = {
    Glock = { Name = "Glock", Aliases = {"glock"} },
    Silencer = { Name = "Silencer", Aliases = {"silencer"} },
    TacticalShotgun = { Name = "TacticalShotgun", Aliases = {"tac","tactical","tacsg","tacticalshotgun","tacticalsg"} },
    P90 = { Name = "P90", Aliases = {"p90"} },
    AUG = { Name = "AUG", Aliases = {"aug"} },
    SMG = { Name = "SMG", Aliases = {"smg"} },
    AR = { Name = "AR", Aliases = {"ar"} },
    Shotgun = { Name = "Shotgun", Aliases = {"sg","shotgun"} },
    Rifle = { Name = "Rifle", Aliases = {"rifle"} },
    RPG = { Name = "RPG", Aliases = {"rpg"} },
    ["Double-Barrel SG"] = { Name = "Double-Barrel SG", Aliases = {"db","double-barrel sg","db sg","dbsg","doublebarrel sg","doublebarrel","doublebarrelsg","double-barrel shotgun","doublebarrel shotgun","doublebarrelshotgun","double-barrelsg"} },
    Revolver = { Name = "Revolver", Aliases = {"rev","revolver"} },
    LMG = { Name = "LMG", Aliases = {"lmg"} },
    SilencerAR = { Name = "SilencerAR", Aliases = {"silencerar","sar"} },
    AK47 = { Name = "AK47", Aliases = {"ak47","ak"} },
    DrumGun = { Name = "DrumGun", Aliases = {"dg","drumgun"} },
    GrenadeLauncher = { Name = "GrenadeLauncher", Aliases = {"grenadelauncher","grenade launcher","gl"} },
    ["Drum-Shotgun"] = { Name = "Drum-Shotgun", Aliases = {"drum-shotgun","drumshotgun","dsg","drum sg","drumsg","drum-sg","drum shotgun"} },
    Flintlock = { Name = "Flintlock", Aliases = {"fl","flint","flintlock"} }
}

local shopfolder = workspace:FindFirstChild("Ignored") and workspace.Ignored:FindFirstChild("Shop")

local function getgun(alias)
    if not alias then return nil end
    local a = string.lower(tostring(alias))
    for _, gunData in pairs(weapons) do
        for _, gunAlias in ipairs(gunData.Aliases) do
            if string.lower(gunAlias) == a then
                return gunData.Name
            end
        end
    end
    return nil
end

-- Try UE tool cache first (if exists), else legacy walk
local function buygun(itemAlias)
    local itemName = getgun(itemAlias)
    if not itemName then notify("Cannot find weapon: " .. tostring(itemAlias)); return end

    -- Ensure tools go to backpack (legacy prep)
    if LocalPlayer.Character then
        for _, tool in pairs(LocalPlayer.Character:GetChildren()) do
            if tool:IsA("Tool") then tool.Parent = LocalPlayer.Backpack end
        end
    end

    -- UE modern: try GetToolCache + Purchase/Interact hooks if they exist
    local toolCache = safe("GetToolCache")
    if typeof(toolCache) == "table" and typeof(toolCache.Purchase) == "function" then
        local ok = pcall(toolCache.Purchase, toolCache, itemName)
        if ok then
            gunname = itemName
            notify("Purchased " .. itemName)
            return
        end
    end

    -- Legacy shop click
    if not shopfolder then notify("Shop folder not found."); return end
    for _, item in pairs(shopfolder:GetChildren()) do
        if string.find(item.Name, "%[" .. itemName .. "%]") and not string.find(item.Name, "Ammo") then
            gunname = itemName
            local itemHead = item:FindFirstChild("Head")
            if itemHead then
                local function tryBuy()
                    if not (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")) then return end
                    LocalPlayer.Character.HumanoidRootPart.CFrame = itemHead.CFrame + Vector3.new(0, 3.2, 0)
                    local clickdetector = item:FindFirstChild("ClickDetector")
                    if clickdetector then
                        clickdetector.MaxActivationDistance = 9e9
                        fireclickdetector(clickdetector)
                    end
                    for _, v in next, LocalPlayer.Backpack:GetChildren() do
                        if got_weapon.Value then break end
                        got_weapon.Value = v.Name == "[" .. gunname .. "]"
                    end
                end
                do
                    local run = true
                    got_weapon.Value = false
                    while run do
                        if got_weapon.Value == true then
                            run = false
                            break
                        end
                        tryBuy()
                        task.wait(0.5)
                    end
                end
                got_weapon.Value = false
                notify("Purchased " .. itemName)
                return
            end
            break
        end
    end
    notify("Cannot Find Weapon!")
end

local function buyammo(itemAlias)
    local itemName = getgun(itemAlias)
    if not itemName then notify("Cannot find weapon ammo: " .. tostring(itemAlias)); return end

    -- UE modern via tool cache if possible
    local toolCache = safe("GetToolCache")
    if typeof(toolCache) == "table" and typeof(toolCache.PurchaseAmmo) == "function" then
        local ok = pcall(toolCache.PurchaseAmmo, toolCache, itemName)
        if ok then
            notify("Purchased ammo for " .. itemName)
            return
        end
    end

    -- Legacy walk
    if not shopfolder then notify("Shop folder not found."); return end
    for _, item in pairs(shopfolder:GetChildren()) do
        if string.find(item.Name, "%[" .. itemName) and string.find(item.Name, "Ammo") then
            gunname = itemName
            local itemHead = item:FindFirstChild("Head")
            if itemHead then
                for i = 1, 5 do
                    if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
                        LocalPlayer.Character.HumanoidRootPart.CFrame = itemHead.CFrame + Vector3.new(0, 3.2, 0)
                    end
                    local clickdetector = item:FindFirstChild("ClickDetector")
                    if clickdetector then
                        clickdetector.MaxActivationDistance = 9e9
                        fireclickdetector(clickdetector)
                    end
                    task.wait(0.5)
                end
                notify("Purchased ammo for " .. itemName)
                return
            end
            break
        end
    end
    notify("Cannot Find Weapon Ammo!")
end

----------------------------------------------------------------
-- Utility
----------------------------------------------------------------
local function do_until(valueObject, funcToRun, delay, val)
    delay = delay or 0.25
    while true do
        if valueObject.Value == val then break end
        funcToRun()
        task.wait(delay)
    end
end

local function getByText(txt)
    if not txt or txt == "" then return nil end
    local lower = string.lower
    local needle = lower(txt)

    -- exact username
    local p = Players:FindFirstChild(txt)
    if p then return p end

    -- exact display name
    for _, pl in ipairs(Players:GetPlayers()) do
        if lower(pl.DisplayName) == needle then return pl end
    end
    -- prefix username
    for _, pl in ipairs(Players:GetPlayers()) do
        if lower(pl.Name):sub(1, #needle) == needle then return pl end
    end
    -- prefix display
    for _, pl in ipairs(Players:GetPlayers()) do
        if lower(pl.DisplayName):sub(1, #needle) == needle then return pl end
    end
    return nil
end

local function no_collide_character(char)
    for _, part in pairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide == true then
            part.CanCollide = false
        end
    end
end

local function restore_collide_character(char)
    for _, part in pairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = true
        end
    end
end

local function equipTool(toolName)
    if not stand or not stand:FindFirstChild("Humanoid") then return nil end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local tool = (backpack and backpack:FindFirstChild("[" .. toolName .. "]")) or stand:FindFirstChild("[" .. toolName .. "]")
    if tool then
        stand.Humanoid:EquipTool(tool)
        return tool
    else
        print("Tool not found: " .. toolName)
    end
    return nil
end

local function shootOnce(targetPlayer, tool)
    if not (targetPlayer and tool) then return end
    local handle = tool:FindFirstChild("Handle")
    local targetChar = targetPlayer.Character
    if not (handle and targetChar) then return end
    local head = targetChar:FindFirstChild("Head") or targetChar:FindFirstChild("HumanoidRootPart")
    if not head then return end
    local char = LocalPlayer.Character
    if not (char and char:FindFirstChild("HumanoidRootPart")) then return end

    ReplicatedStorage.MainEvent:FireServer(
        "ShootGun",
        handle,
        handle.Position,
        head.Position,
        head,
        Vector3.new(0, -1, 0)
    )
end

-- Loop until KO
local function keep_shooting(targetName)
    local tool = equipTool("AUG")
    if not tool then
        warn("No tool equipped.")
        return
    end

    local handle = tool:FindFirstChild("Handle")
    if not handle then
        warn("Handle not found in tool.")
        return
    end

    local targetPlayer = Players:FindFirstChild(targetName)
    if not targetPlayer then
        warn("Target player not found.")
        return
    end

    local targetChar = targetPlayer.Character
    if not targetChar then
        warn("Target character missing.")
        return
    end

    local targetHRP = targetChar:FindFirstChild("Head") or targetChar:FindFirstChild("HumanoidRootPart")
    if not targetHRP then
        warn("Target part missing.")
        return
    end

    local char = LocalPlayer.Character
    if not char or not char:FindFirstChild("HumanoidRootPart") then
        warn("Local character or HRP missing.")
        return
    end

    no_collide_character(char)
    local shooting = true

    local conn = RunService.Heartbeat:Connect(function()
        if not shooting then return end
        if targetChar:FindFirstChild("BodyEffects") and targetChar.BodyEffects:FindFirstChild("K.O") and targetChar.BodyEffects["K.O"].Value == true then
            shooting = false
            return
        end

        local myHRP = char:FindFirstChild("HumanoidRootPart")
        if myHRP then
            myHRP.CFrame = CFrame.new(targetHRP.Position + Vector3.new(0, -3, 0))
        end

        ReplicatedStorage.MainEvent:FireServer(
            "ShootGun",
            handle,
            handle.Position,
            targetHRP.Position,
            targetHRP,
            Vector3.new(0, -1, 0)
        )
    end)

    repeat task.wait(0.05) until (targetChar:FindFirstChild("BodyEffects") and targetChar.BodyEffects:FindFirstChild("K.O") and targetChar.BodyEffects["K.O"].Value == true)
    shooting = false
    conn:Disconnect()
    killed = true
    restore_collide_character(char)
    notify("Fired at " .. targetName)
end

local function bring(target)
    if doing_task then return end
    local char = LocalPlayer.Character
    local targetPlayer = Players:FindFirstChild(target)
    if not (targetPlayer and targetPlayer.Character) then
        notify("Target character not found.")
        return
    end
    local targetchar = targetPlayer.Character

    doing_task = true
    keep_shooting(target)
    repeat task.wait(.25) until killed
    killed = false

    do_until(targetchar.BodyEffects['K.O'], function()
        local targetHRP = targetchar:FindFirstChild("UpperTorso") or targetchar:FindFirstChild("HumanoidRootPart")
        local myHRP = char and char:FindFirstChild("HumanoidRootPart")
        if myHRP and targetHRP then
            myHRP.CFrame = CFrame.new(targetHRP.Position + Vector3.new(0, 1.25, 0))
        end
        ReplicatedStorage:WaitForChild("MainEvent"):FireServer("Grabbing", false)
    end, .5, false)

    if char and char:FindFirstChild("HumanoidRootPart") then
        local owner = Players:FindFirstChild(framework.ownerName)
        if owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart") then
            char.HumanoidRootPart.CFrame = owner.Character.HumanoidRootPart.CFrame * CFrame.new(0, 0, 3)
        end
    end
    task.wait(2)
    ReplicatedStorage.MainEvent:FireServer("Grabbing", false)
    doing_task = false
    notify("Finished bringing " .. target)
end

----------------------------------------------------------------
-- Follow owner loop
----------------------------------------------------------------
table.insert(framework.connections, RunService.Heartbeat:Connect(function()
    if not following then return end
    local owner = Players:FindFirstChild(framework.ownerName)
    if not (owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")) then return end
    local targetPos = owner.Character.HumanoidRootPart.Position + Vector3.new(3, 0, 3)
    if stand and stand:FindFirstChild("HumanoidRootPart") then
        stand:MoveTo(targetPos)
    end
end))

----------------------------------------------------------------
-- COMMAND HANDLER
----------------------------------------------------------------
local function handleCommand(msg)
    if type(msg) ~= "string" then return end
    local args = string.split(msg, " ")
    local cmd = args[1] and string.lower(args[1]) or nil

    -- build target by text robustly
    local rawArg = args[2]
    local targetPlayer = getByText(rawArg)

    -- ===== sticky aim helpers (UE cache) =====
    local function clearSticky()
        local cache = getTargetCache()
        for k in pairs(cache) do cache[k] = false end
    end
    local function setSticky(p)
        local cache = getTargetCache()
        cache[p] = true
        cache[p.Name] = true
    end

    -- ===== Commands =====

    if cmd == ".void" then
        if Toggles and Toggles.ragebot_enabled then
            Toggles.ragebot_enabled:SetValue(true)
        end
        if Options and Options.ragebot_keybind then Options.ragebot_keybind.Mode = "Always" end
        if Toggles and Toggles.character_prot_void then
            Toggles.character_prot_void:SetValue(true)
        end
        if Options and Options.character_prot_voidkeybind then Options.character_prot_voidkeybind.Mode = "Always" end
        if targetPlayer and Options and Options.ragebot_targets and Options.ragebot_targets.Value then
            Options.ragebot_targets.Value[targetPlayer.Name] = true
        end
        notify("Void on.")

    elseif cmd == ".c" then
        if Options and Options.ragebot_targets and Options.ragebot_targets.Value then
            for i, v in next, Options.ragebot_targets.Value do
                if v == true then Options.ragebot_targets.Value[i] = false end
            end
        end
        if Toggles and Toggles.ragebot_enabled then
            Toggles.ragebot_enabled:SetValue(false)
        end
        if Options and Options.ragebot_keybind then Options.ragebot_keybind.Mode = "Toggle" end
        if Toggles and Toggles.character_prot_void then
            Toggles.character_prot_void:SetValue(false)
        end
        if Options and Options.character_prot_voidkeybind then Options.character_prot_voidkeybind.Mode = "Toggle" end
        notify("Cleared.")

    elseif cmd == ".summon" then
        local owner = Players:FindFirstChild(framework.ownerName)
        if owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart") and stand and stand:FindFirstChild("HumanoidRootPart") then
            local pos = owner.Character.HumanoidRootPart.Position - owner.Character.HumanoidRootPart.CFrame.LookVector * 3
            stand.HumanoidRootPart.CFrame = CFrame.new(pos)
            following = not following
            notify("Stand summoned.")
        end

    elseif cmd == ".reset" then
        -- NEW: reset command
        local character = LocalPlayer.Character
        if character and character:FindFirstChild("Humanoid") then
            character.Humanoid.Health = 0
            notify("Stand has been reset.")
        else
            notify("Could not reset: Character or Humanoid not found.")
        end

    elseif cmd == ".hc" then
        -- just hides screen
        RunService:Set3dRenderingEnabled(false)
        notify("3D rendering disabled.")

    elseif cmd == ".uhc" then
            -- NEW: enable rendering
        RunService:Set3dRenderingEnabled(true)
        notify("3D rendering enabled.")

    elseif cmd == ".buy" then
        local alias = args[2]
        buygun(alias)

    elseif cmd == ".ammo" then
        local alias = args[2]
        buyammo(alias)

    elseif cmd == ".def" then
        if Toggles and Options and Toggles.protection_fake_position and Toggles.character_prot_void then
            if Toggles.protection_fake_position.Value ~= (Toggles.ragebot_enabled and Toggles.ragebot_enabled.Value) then
                Toggles.protection_fake_position:SetValue(true)
                if Options.protection_fake_position_keybind then Options.protection_fake_position_keybind.Mode = "Always" end
                Toggles.character_prot_void:SetValue(true)
                if Options.character_prot_voidkeybind then Options.character_prot_voidkeybind.Mode = "Always" end
            end
            if Options.protection_fake_position_keybind then
                Options.protection_fake_position_keybind.Mode = (Options.protection_fake_position_keybind.Value == "Always") and "Toggle" or "Always"
            end
            if Options.character_prot_voidkeybind then
                Options.character_prot_voidkeybind.Mode = (Options.character_prot_voidkeybind.Value == "Always") and "Toggle" or "Always"
            end
            Toggles.protection_fake_position:SetValue(not Toggles.protection_fake_position.Value)
            Toggles.character_prot_void:SetValue(not Toggles.character_prot_void.Value)
        end

    elseif cmd == ".view" then
        if not targetPlayer then return notify("No target found for .view") end
        clearSticky()
        setSticky(targetPlayer)                 -- sticky aim only
        if targetPlayer.Character and targetPlayer.Character:FindFirstChild("Humanoid") then
            workspace.CurrentCamera.CameraSubject = targetPlayer.Character.Humanoid
        end
        notify("Viewing and sticky aiming " .. targetPlayer.Name)

    elseif cmd == ".unview" then
        clearSticky()
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            workspace.CurrentCamera.CameraSubject = LocalPlayer.Character.Humanoid
        end
        notify("Stopped viewing / sticky aim cleared.")

    elseif cmd == ".bring" or cmd == ".b" then
        if not targetPlayer then
            notify("No valid target for Bring")
            return
        end
        if targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart") then
            bring(targetPlayer.Name)
        else
            notify("No valid target for Bring")
        end

    elseif cmd == ".knock" or cmd == ".k" then
        if not targetPlayer then return notify("No valid target for Knock") end
        clearSticky()
        setSticky(targetPlayer)
        local strafeSpeed = tonumber(args[3]) or 8
        startStrafing(targetPlayer, strafeSpeed)
        keep_shooting(targetPlayer.Name)
        repeat task.wait() until (targetPlayer.Character and targetPlayer.Character:FindFirstChild("BodyEffects") and targetPlayer.Character.BodyEffects:FindFirstChild("K.O") and targetPlayer.Character.BodyEffects["K.O"].Value == true)
        stopStrafing()
        notify("Knocked " .. targetPlayer.Name)
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
            local owner = Players:FindFirstChild(framework.ownerName)
            if owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart") then
                LocalPlayer.Character.HumanoidRootPart.CFrame = owner.Character.HumanoidRootPart.CFrame * CFrame.new(0, 0, 3)
            end
        end

    elseif cmd == ".auto" or cmd == ".a" then
        local target = api.Oxa29f78f486dbae86 -- preserving your original usage
        if target and typeof(target) == "Instance" and target:IsA("Player") and target.Character and target.Character:FindFirstChild("HumanoidRootPart") then
            if stand and stand:FindFirstChild("HumanoidRootPart") then
                stand.HumanoidRootPart.CFrame = target.Character.HumanoidRootPart.CFrame + Vector3.new(0,0,2)
            end
            local tool = equipTool("AUG")
            if tool then shootOnce(target, tool) end
        else
            notify("No valid ragebot target for auto attack.")
        end

    elseif cmd == ".aug" then
        local target = api.Oxa29f78f486dbae86
        if target and typeof(target) == "Instance" and target:IsA("Player") and target.Character and target.Character:FindFirstChild("HumanoidRootPart") then
            local tool = equipTool("AUG")
            if tool then shootOnce(target, tool) end
        else
            notify("No valid target for AUG attack.")
        end

    elseif cmd == ".fast" then
        local target = api.Oxa29f78f486dbae86
        if target and typeof(target) == "Instance" and target:IsA("Player") and target.Character and target.Character:FindFirstChild("HumanoidRootPart") then
            local tool1 = equipTool("Rifle")
            if tool1 then shootOnce(target, tool1) end
            task.wait(0.2)
            local tool2 = equipTool("Flintlock")
            if tool2 then shootOnce(target, tool2) end
        else
            notify("No valid target for fast attack.")
        end
    end
end

----------------------------------------------------------------
-- CHAT CONNECTION
----------------------------------------------------------------
local chatConnection = nil
function connectToOwner()
    if chatConnection then
        chatConnection:Disconnect()
        chatConnection = nil
    end
    local player = Players:FindFirstChild(framework.ownerName)
    if player then
        chatConnection = player.Chatted:Connect(handleCommand)
        notify("Listening to chat commands from: " .. framework.ownerName)
    else
        notify("Owner player not found: " .. framework.ownerName)
    end
end

table.insert(framework.connections, Players.PlayerAdded:Connect(function(player)
    if player.Name == framework.ownerName then
        connectToOwner()
    end
end))

connectToOwner()

----------------------------------------------------------------
-- CLEANUP
----------------------------------------------------------------
function api:Unload()
    for _, c in ipairs(framework.connections) do
        c:Disconnect()
    end
    if chatConnection then
        chatConnection:Disconnect()
    end
    table.clear(framework)
    notify("Unloaded Stand Controller.")
end

notify("Stand Controller loaded. Default owner: slakkenhuis")
