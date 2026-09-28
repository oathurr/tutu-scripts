--[[
╔══════════════════════════════════════════════════════════════════╗
║              ANIME BREAKERS FINAL HUB — LIVE                     ║
║                                                                  ║
║  Architecture:                                                   ║
║  Detection → State Store → Arbiter → Action Controller           ║
║                                        ↓                         ║
║                                   Action Adapters (LIVE)         ║
║                                        ↓                         ║
║                                   Confirmation Layer             ║
║                                                                  ║
║  All adapters are fully implemented.                             ║
║  Test environment — authorized by developer.                     ║
╚══════════════════════════════════════════════════════════════════╝
]]

-- ════════════════════════════════════════════════════════════════
-- SECTION 0: ANTI-DOUBLE EXECUTION GUARD
-- ════════════════════════════════════════════════════════════════

if getgenv().__ANIME_BREAKERS_FINAL_HUB then
    warn("[ANIME BREAKERS HUB] Already running. Aborting duplicate instance.")
    return
end
getgenv().__ANIME_BREAKERS_FINAL_HUB = true

-- ════════════════════════════════════════════════════════════════
-- SECTION 1: SERVICES & REFERENCES
-- ════════════════════════════════════════════════════════════════

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Workspace = game:GetService("Workspace")

-- Resolved references (may be nil initially)
local Refs = {
    PlayerGui = nil,
    Invite = nil,
    Gamemode = nil,
    SpawnItems = nil,        -- workspace._SPAWNITEMS
    EnemiesGamemode = nil,   -- workspace._ENEMIES.Server.Gamemode
    Character = nil,
    HumanoidRootPart = nil,
}

-- ════════════════════════════════════════════════════════════════
-- SECTION 2: CONFIGURATION
-- ════════════════════════════════════════════════════════════════

local Config = {
    ActionTimeouts = {
        EnterTrial       = 10,         -- 10s to confirm entry
        FarmTrial        = math.huge,  -- lifecycle worker: no timeout, cancelled by detection
        CollectOrb       = 15,         -- 15s total for move + interact + confirm
        ReturnToSafe     = 10,         -- 10s to return to safe position
    },
    CollectConfirmWindow   = 5,    -- seconds to correlate Triggered + Removed
    PostTrialDebounce      = 3,    -- seconds before revalidation after trial end
    TrialEntryTimeout      = 15,   -- seconds to wait for entry confirmation
    TrialEndTimeout        = 8,    -- seconds to wait for child removal after Gamemode off
    ActionRetryCooldown    = 8,    -- seconds before retrying a failed action
    MaxLogLines            = 150,
    GuiUpdateInterval      = 1,    -- seconds between GUI refreshes
    ContainerResolveRetry  = 5,    -- seconds between retries for missing containers
    OrbExpireThreshold     = 2,    -- seconds: if remaining <= this at removal, likely expired
    FarmLoopInterval       = 0.1,  -- seconds between farm loop iterations
    OrbTeleportSettleTime  = 0.25, -- seconds to wait after teleport before firing prompt
    OrbReachDistance       = 16,   -- studs: max distance to consider TARGET_REACHED
    OrbMoveMaxRetries      = 3,    -- max move attempts before giving up
    OrbMoveRetryWait       = 0.5,  -- seconds between retry attempts
}

-- ════════════════════════════════════════════════════════════════
-- SECTION 3: STATE STORE
-- ════════════════════════════════════════════════════════════════

local State = {
    -- Core states
    MainState = "IDLE",
    OrbState  = "NONE",

    -- Central action lock
    CurrentAction = {
        name       = "NONE",
        startedAt  = 0,
        attemptId  = 0,
        timeout    = 0,
        cancelled  = false,
        targetItem = nil,
    },

    -- Toggles: Monitoring
    MonitorTrial = true,
    MonitorOrb   = true,

    -- Toggles: Automation
    AutomationMaster = false,
    AutoJoinTrial    = false,
    AutoTrial        = false,
    AutoOrb          = false,
    ReturnAfterOrb   = false,

    -- Safe Return Position (manual only)
    SafeReturnPosition = nil, -- CFrame or nil
    OrbRecoveryPosition = nil, -- CFrame or nil

    -- Detection cache
    trialAvailable = false,
    trialActive    = false,
    trialModeName  = "",

    -- Orb tracking: key = Instance, value = info table
    ObservedSpawnItems = {},

    -- Counters
    TrialsDetected   = 0,
    TrialsEntered    = 0,
    TrialsFinished   = 0,
    OrbsDetected     = 0,
    OrbsCollected    = 0,
    OrbsRemoved      = 0,
    OrbsLikelyExpired = 0,

    -- Info
    LastEvent = "",
    LastAction = "",
    LastError  = "",

    -- Internal flags
    HubClosed                 = false,
    _attemptCounter           = 0,
    _trialEntryProcessed      = false,
    _trialEndProcessed        = false,
    _hadConfirmedTimeTrial    = false,  -- true only when REAL Time Trial was confirmed
    _pendingRecoveryLog       = false,  -- flag for valid trial worker recovery log
    _actionCooldowns          = {
        ENTER_TRIAL          = 0,
        FARM_TRIAL           = 0,
        COLLECT_ORB          = 0,
        RETURN_TO_SAFE       = 0,
        ORB_RECOVERY_STAGE   = 0,
        FAILSAFE_RETURN      = 0,
    },
    _pendingTasks = {},  -- tracked task.delay handles for cancellation
}

-- ════════════════════════════════════════════════════════════════
-- SECTION 4: CONNECTION MANAGER
-- ════════════════════════════════════════════════════════════════

local AllConnections = {} -- { { conn = RBXScriptConnection, tag = string } }

local function connect(signal, callback, tag)
    local ok, conn = pcall(function()
        return signal:Connect(callback)
    end)
    if ok and conn then
        table.insert(AllConnections, { conn = conn, tag = tag or "general" })
        return conn
    end
    return nil
end

local function disconnectByTag(tag)
    for i = #AllConnections, 1, -1 do
        if AllConnections[i].tag == tag then
            pcall(function() AllConnections[i].conn:Disconnect() end)
            table.remove(AllConnections, i)
        end
    end
end

local function disconnectAll()
    for _, entry in ipairs(AllConnections) do
        pcall(function() entry.conn:Disconnect() end)
    end
    AllConnections = {}
end

-- Task tracking for cleanup
local function trackedDelay(seconds, callback)
    if State.HubClosed then return nil end
    local id = {}
    State._pendingTasks[id] = true
    task.delay(seconds, function()
        State._pendingTasks[id] = nil
        if not State.HubClosed then
            callback()
        end
    end)
    return id
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 5: LOGGER
-- ════════════════════════════════════════════════════════════════

local Logger = {}
local _logBuffer = {}  -- buffered until GUI is ready
local _logGui = nil    -- set when GUI creates log scroll
local _logLayout = nil
local _logLineCount = 0

local LOG_COLORS = {
    trial    = Color3.fromRGB(90, 150, 245),
    orb      = Color3.fromRGB(240, 185, 55),
    decision = Color3.fromRGB(200, 200, 215),
    action   = Color3.fromRGB(80, 200, 125),
    state    = Color3.fromRGB(150, 150, 170),
    system   = Color3.fromRGB(130, 130, 150),
    error    = Color3.fromRGB(220, 80, 80),
    warn     = Color3.fromRGB(220, 170, 60),
    info     = Color3.fromRGB(180, 180, 195),
}

function Logger.log(message, category)
    if State.HubClosed then return end
    category = category or "info"

    local timestamp = os.date("%H:%M:%S")
    local line = timestamp .. " " .. message
    local color = LOG_COLORS[category] or LOG_COLORS.info

    if _logGui then
        Logger._addLine(line, color)
    else
        table.insert(_logBuffer, { text = line, color = color })
    end
end

function Logger._addLine(text, color)
    if not _logGui or not _logGui.Parent then return end

    _logLineCount = _logLineCount + 1
    local label = Instance.new("TextLabel")
    label.Name = "Log_" .. _logLineCount
    label.Size = UDim2.new(1, 0, 0, 14)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.RobotoMono
    label.TextSize = 11
    label.TextColor3 = color
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextWrapped = true
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.Text = text
    label.LayoutOrder = _logLineCount
    label.Parent = _logGui

    -- Trim excess lines
    local children = _logGui:GetChildren()
    local labels = {}
    for _, c in ipairs(children) do
        if c:IsA("TextLabel") then
            table.insert(labels, c)
        end
    end
    if #labels > Config.MaxLogLines then
        table.sort(labels, function(a, b)
            return a.LayoutOrder < b.LayoutOrder
        end)
        for i = 1, #labels - Config.MaxLogLines do
            labels[i]:Destroy()
        end
    end

    -- Auto-scroll to bottom
    task.defer(function()
        if _logGui and _logGui.Parent then
            _logGui.CanvasPosition = Vector2.new(0, _logGui.AbsoluteCanvasSize.Y)
        end
    end)
end

function Logger._flushBuffer()
    for _, entry in ipairs(_logBuffer) do
        Logger._addLine(entry.text, entry.color)
    end
    _logBuffer = {}
end

function Logger.clear()
    if not _logGui then return end
    for _, c in ipairs(_logGui:GetChildren()) do
        if c:IsA("TextLabel") then
            c:Destroy()
        end
    end
    _logLineCount = 0
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 6: UTILITY FUNCTIONS
-- ════════════════════════════════════════════════════════════════

local function getServerTime()
    local ok, t = pcall(function() return Workspace:GetServerTimeNow() end)
    if ok and t then return t end
    return tick()
end

local function formatTime(seconds)
    if not seconds or seconds < 0 then return "--:--" end
    seconds = math.floor(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return string.format("%02d:%02d", m, s)
end

local function isInstanceValid(inst)
    if not inst then return false end
    local ok, parent = pcall(function() return inst.Parent end)
    return ok and parent ~= nil
end

local function safeGetAttribute(inst, attr)
    if not isInstanceValid(inst) then return nil end
    local ok, val = pcall(function() return inst:GetAttribute(attr) end)
    if ok then return val end
    return nil
end

--- Checks if any TextLabel/TextButton/TextBox descendant contains text (case-insensitive).
--- This is a SNAPSHOT, not continuous scanning.
local function hasTextContaining(parent, searchText)
    if not isInstanceValid(parent) then return false end
    local ok, descendants = pcall(function() return parent:GetDescendants() end)
    if not ok then return false end
    local lower = searchText:lower()
    for _, desc in ipairs(descendants) do
        if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") then
            local tok, txt = pcall(function() return desc.Text end)
            if tok and txt and txt:lower():find(lower, 1, true) then
                return true
            end
        end
    end
    return false
end

local function resolvePlayerGui()
    local ok, pg = pcall(function() return LocalPlayer:FindFirstChild("PlayerGui") end)
    if ok and pg then
        Refs.PlayerGui = pg
        return pg
    end
    return nil
end

local function resolveInvite()
    local pg = Refs.PlayerGui or resolvePlayerGui()
    if not pg then return nil end
    local ok, inv = pcall(function() return pg:FindFirstChild("Invite") end)
    if ok and inv then
        Refs.Invite = inv
        return inv
    end
    return nil
end

local function resolveGamemodeGui()
    local pg = Refs.PlayerGui or resolvePlayerGui()
    if not pg then return nil end
    local ok, gm = pcall(function() return pg:FindFirstChild("Gamemode") end)
    if ok and gm then
        Refs.Gamemode = gm
        return gm
    end
    return nil
end

local function resolveSpawnItems()
    local ok, si = pcall(function() return Workspace:FindFirstChild("_SPAWNITEMS") end)
    if ok and si then
        Refs.SpawnItems = si
        return si
    end
    return nil
end

local function resolveEnemiesGamemode()
    local ok, enemies = pcall(function() return Workspace:FindFirstChild("_ENEMIES") end)
    if not ok or not enemies then return nil end
    local ok2, server = pcall(function() return enemies:FindFirstChild("Server") end)
    if not ok2 or not server then return nil end
    local ok3, gm = pcall(function() return server:FindFirstChild("Gamemode") end)
    if ok3 and gm then
        Refs.EnemiesGamemode = gm
        return gm
    end
    return nil
end

local function resolveCharacter()
    local ok, char = pcall(function() return LocalPlayer.Character end)
    if ok and char then
        Refs.Character = char
        local ok2, hrp = pcall(function() return char:FindFirstChild("HumanoidRootPart") end)
        if ok2 and hrp then
            Refs.HumanoidRootPart = hrp
        else
            Refs.HumanoidRootPart = nil
        end
        return char
    end
    return nil
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 7: ACTION ADAPTERS
-- ════════════════════════════════════════════════════════════════
-- These adapters isolate concrete gameplay actions.
-- They perform the PHYSICAL action only; confirmation is handled
-- by the Detection/Confirmation layer observing game signals.
--
-- In Roblox Studio / test harness: these can be replaced with
-- mock implementations or injected callbacks. The rest of the
-- architecture does not depend on their internals.

local Actions = {}

--[[
    EnterTrial:
    Locates the positive confirmation button inside PlayerGui.Invite.
    Searches for ANY GuiButton (TextButton or ImageButton).
    Identification heuristics:
      1. TextButton with accept keywords (join/yes/enter/accept/confirm/ok)
      2. ImageButton with green-ish BackgroundColor3
    Fires MouseButton1Click on the identified button.
    Actual entry is NOT confirmed here — the Confirmation Layer
    waits for Time Trial container in _ENEMIES.Server.Gamemode.
]]
function Actions.EnterTrial(context)
    if context.isCancelled() then return false, "cancelled" end

    -- Resolve Invite GUI
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return false, "no_playergui" end
    local invite = pg:FindFirstChild("Invite")
    if not invite then return false, "no_invite" end

    -- Verify Invite is still enabled
    local ok, enabled = pcall(function() return invite.Enabled end)
    if not ok or not enabled then return false, "invite_not_enabled" end

    -- Scan for a clickable GuiButton (TextButton OR ImageButton).
    local targetButton = nil
    local ok2, descendants = pcall(function() return invite:GetDescendants() end)
    if not ok2 then return false, "cannot_scan_invite" end

    for _, desc in ipairs(descendants) do
        if context.isCancelled() then return false, "cancelled" end
        if desc:IsA("GuiButton") then  -- covers both TextButton and ImageButton
            local btnOk, btnVisible = pcall(function() return desc.Visible end)
            if btnOk and btnVisible then
                -- Strategy 1: TextButton with accept keywords
                if desc:IsA("TextButton") then
                    local txtOk, btnText = pcall(function() return desc.Text end)
                    if txtOk and btnText then
                        local lower = btnText:lower()
                        if lower:find("join", 1, true)
                            or lower:find("yes", 1, true)
                            or lower:find("enter", 1, true)
                            or lower:find("accept", 1, true)
                            or lower:find("confirm", 1, true)
                            or lower:find("ok", 1, true) then
                            targetButton = desc
                            break
                        end
                    end
                end

                -- Strategy 2: ImageButton with green-ish color (positive action)
                if desc:IsA("ImageButton") then
                    local colOk, bgColor = pcall(function() return desc.BackgroundColor3 end)
                    if colOk and bgColor then
                        -- Green detection: G channel significantly higher than R
                        if bgColor.G > 0.4 and bgColor.G > bgColor.R * 1.3 then
                            targetButton = desc
                            break
                        end
                    end
                    -- Also check Image name for check/accept patterns
                    local imgOk, imgSrc = pcall(function() return desc.Image end)
                    if imgOk and imgSrc and imgSrc ~= "" then
                        local lowerImg = imgSrc:lower()
                        if lowerImg:find("check", 1, true)
                            or lowerImg:find("accept", 1, true)
                            or lowerImg:find("confirm", 1, true)
                            or lowerImg:find("yes", 1, true) then
                            targetButton = desc
                            break
                        end
                    end
                end
            end
        end
    end

    if not targetButton then 
        Logger.log("[ACTION] EnterTrial: Cannot determine correct button safely", "warn")
        return false, "ambiguous_button" 
    end

    if context.isCancelled() then return false, "cancelled" end

    Logger.log("[ACTION] EnterTrial: firing " .. targetButton.ClassName .. " (" .. targetButton.Name .. ")", "action")

    -- Fire the button click via MouseButton1Click signal
    local fireOk, fireErr = pcall(function()
        firesignal(targetButton.MouseButton1Click)
    end)

    if not fireOk then
        -- Fallback: try direct method if available
        local alt1 = pcall(function()
            fireclickdetector(targetButton)
        end)
        if not alt1 then
            Logger.log("[ACTION] EnterTrial: click dispatch failed, adapter needs injection", "warn")
            return false, "click_dispatch_failed: " .. tostring(fireErr)
        end
    end

    Logger.log("[ACTION] EnterTrial: button click dispatched", "action")
    return true, "click_dispatched"
end

--[[
    FarmTrial:
    Lifecycle worker that loops through enemies inside the confirmed
    trial container. Runs continuously until cancelled by detection.
    Does NOT assume Humanoid on enemies.
    Checks HumanoidRootPart > PrimaryPart > first BasePart.
    The concrete movement/attack logic is in this adapter and can
    be replaced for Studio testing.
]]
function Actions.FarmTrial(context)
    if context.isCancelled() then return false, "cancelled" end

    local container = context.trialContainer
    if not container or not isInstanceValid(container) then
        return false, "no_trial_container"
    end

    Logger.log("[ACTION] FarmTrial: starting farm loop in " .. tostring(container.Name), "action")

    -- Farm loop: runs until cancel token fires
    while not context.isCancelled() do
        -- Revalidate container still exists
        if not isInstanceValid(container) then
            Logger.log("[ACTION] FarmTrial: container destroyed, stopping", "warn")
            break
        end

        -- Revalidate character
        local character = LocalPlayer.Character
        if not character then
            task.wait(0.5)
            continue
        end
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp then
            task.wait(0.5)
            continue
        end

        -- Get enemies from the trial container ONLY
        local okChildren, enemies = pcall(function() return container:GetChildren() end)
        if not okChildren or not enemies then
            task.wait(Config.FarmLoopInterval)
            continue
        end

        local foundTarget = false
        for _, mob in ipairs(enemies) do
            if context.isCancelled() then break end
            if not mob:IsA("Model") and not mob:IsA("BasePart") then continue end

            -- Determine the target position part
            -- Rule: Do NOT assume Humanoid. Check HumanoidRootPart or PrimaryPart.
            local targetPart = nil

            if mob:IsA("Model") then
                local okHrp, mobHrp = pcall(function()
                    return mob:FindFirstChild("HumanoidRootPart")
                end)
                if okHrp and mobHrp and mobHrp:IsA("BasePart") then
                    targetPart = mobHrp
                else
                    local okPP, pp = pcall(function() return mob.PrimaryPart end)
                    if okPP and pp and pp:IsA("BasePart") then
                        targetPart = pp
                    else
                        local okDesc, children = pcall(function() return mob:GetChildren() end)
                        if okDesc then
                            for _, child in ipairs(children) do
                                if child:IsA("BasePart") then
                                    targetPart = child
                                    break
                                end
                            end
                        end
                    end
                end
            elseif mob:IsA("BasePart") then
                targetPart = mob
            end

            if targetPart and isInstanceValid(targetPart) then
                local okPos, targetPos = pcall(function() return targetPart.CFrame end)
                if okPos and targetPos then
                    foundTarget = true
                    local okTp, tpErr = pcall(function()
                        hrp.CFrame = targetPos * CFrame.new(0, 0, 3)
                    end)
                    if not okTp then
                        Logger.log("[ACTION] FarmTrial: teleport error: " .. tostring(tpErr), "warn")
                    end
                    task.wait(Config.FarmLoopInterval)
                end
            end
        end

        if not foundTarget then
            task.wait(0.3)
        end
    end

    Logger.log("[ACTION] FarmTrial: farm loop ended", "action")
    return true, "loop_ended"
end

--[[
    CollectOrb:
    1. Revalidates the orb item, Root, and ProximityPrompt.
    2. Measures distance BEFORE move.
    3. Requests move to orb position (adapter-level).
    4. Measures distance AFTER move to confirm TARGET_REACHED.
    5. If not reached, retries up to Config.OrbMoveMaxRetries.
    6. Only proceeds to interaction after TARGET_REACHED.
    7. Fires ProximityPrompt interaction (adapter-level).
    Actual collection confirmed by Confirmation Layer.
]]
function Actions.CollectOrb(context)
    if context.isCancelled() then return false, "cancelled" end

    local orbInfo = context.item
    if not orbInfo then return false, "no_orb_info" end

    -- === REVALIDATION BLOCK ===
    local function revalidateOrb()
        if not isInstanceValid(orbInfo.instance) then return false, "item_destroyed" end
        if safeGetAttribute(orbInfo.instance, "Type") ~= "CommandmentFragment" then
            return false, "type_mismatch"
        end

        -- Re-resolve Root if needed
        if not orbInfo.root or not isInstanceValid(orbInfo.root) then
            local okR, r = pcall(function() return orbInfo.instance:FindFirstChild("Root") end)
            if okR and r then
                orbInfo.root = r
            else
                return false, "root_destroyed"
            end
        end

        -- Re-resolve ProximityPrompt if needed
        if not orbInfo.prompt or not isInstanceValid(orbInfo.prompt) then
            local okP, p = pcall(function()
                return orbInfo.root:FindFirstChildOfClass("ProximityPrompt")
            end)
            if okP and p then
                orbInfo.prompt = p
            else
                return false, "no_proximity_prompt"
            end
        end

        -- Check ExpireAt
        if orbInfo.expireAt then
            local remaining = orbInfo.expireAt - getServerTime()
            if remaining <= 0 then return false, "orb_already_expired" end
        end

        return true
    end

    -- Initial revalidation
    local valid, reason = revalidateOrb()
    if not valid then return false, reason end

    -- === DISTANCE MEASUREMENT ===
    local function getDistanceToOrb()
        local character = LocalPlayer.Character
        if not character then return math.huge end
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp then return math.huge end
        if not orbInfo.root or not isInstanceValid(orbInfo.root) then return math.huge end
        local okP, orbPos = pcall(function() return orbInfo.root.Position end)
        if not okP then return math.huge end
        local okH, hrpPos = pcall(function() return hrp.Position end)
        if not okH then return math.huge end
        return (hrpPos - orbPos).Magnitude
    end

    -- === MOVE WITH RETRY ===
    local reached = false
    for attempt = 1, Config.OrbMoveMaxRetries do
        if context.isCancelled() then return false, "cancelled" end

        -- Revalidate on each attempt
        valid, reason = revalidateOrb()
        if not valid then return false, reason end

        -- Check if trial appeared (preemption)
        if State.trialAvailable or State.trialActive then
            return false, "trial_preempted_during_move"
        end

        local distBefore = getDistanceToOrb()

        -- Get fresh orb CFrame
        local okPos, orbCFrame = pcall(function() return orbInfo.root.CFrame end)
        if not okPos or not orbCFrame then return false, "cannot_read_position" end

        -- Get character HRP
        local character = LocalPlayer.Character
        if not character then return false, "no_character" end
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not hrp then return false, "no_hrp" end

        -- Request move
        Logger.log(string.format("[ORB MOVE] attempt #%d | distance_before = %.1f", attempt, distBefore), "action")

        local okTp, tpErr = pcall(function()
            hrp.CFrame = orbCFrame * CFrame.new(0, 0, 2)
        end)
        if not okTp then
            Logger.log("[ORB MOVE] move failed: " .. tostring(tpErr), "warn")
        end

        -- Wait for position to settle
        task.wait(Config.OrbTeleportSettleTime)

        if context.isCancelled() then return false, "cancelled_after_move" end

        -- Measure distance AFTER move
        local distAfter = getDistanceToOrb()
        Logger.log(string.format("[ORB MOVE] distance_after = %.1f", distAfter), "action")

        if distAfter <= Config.OrbReachDistance then
            Logger.log("[ORB MOVE] target reached", "action")
            reached = true
            break
        else
            Logger.log("[ORB MOVE] target not reached", "warn")
            if attempt < Config.OrbMoveMaxRetries then
                task.wait(Config.OrbMoveRetryWait)
            end
        end
    end

    if not reached then
        Logger.log("[ORB MOVE] failed to reach target after " .. Config.OrbMoveMaxRetries .. " attempts", "error")
        return false, "target_not_reached"
    end

    -- === INTERACTION (only after TARGET_REACHED) ===
    if context.isCancelled() then return false, "cancelled_before_interact" end

    -- Final revalidation
    valid, reason = revalidateOrb()
    if not valid then return false, reason end

    Logger.log("[ORB] Interaction requested", "orb")

    -- Fire ProximityPrompt
    local prompt = orbInfo.prompt
    local okFire, fireErr = pcall(function()
        fireproximityprompt(prompt)
    end)

    if not okFire then
        -- Fallback: try InputHoldBegin/End
        local okAlt = pcall(function()
            prompt:InputHoldBegin()
            task.wait(prompt.HoldDuration + 0.05)
            prompt:InputHoldEnd()
        end)
        if not okAlt then
            Logger.log("[ORB] Interaction dispatch failed, adapter needs injection", "warn")
            return false, "interact_dispatch_failed: " .. tostring(fireErr)
        end
    end

    Logger.log("[ACTION] CollectOrb: proximity prompt fired", "action")
    -- Actual collection confirmation is handled by the Detection Layer:
    -- ProximityPrompt.Triggered fires for LocalPlayer + item removed.
    return true, "prompt_fired"
end

--[[
    ReturnToSafePosition:
    Moves the character back to a safe location.
    If context.targetCFrame is provided, it uses that (for standalone staging).
    Otherwise, it defaults purely to State.SafeReturnPosition.
]]
function Actions.ReturnToSafePosition(context)
    if context.isCancelled() then return false, "cancelled" end

    local safeCFrame = context.targetCFrame or State.SafeReturnPosition
    if not safeCFrame then return false, "no_safe_position" end

    local character = LocalPlayer.Character
    if not character then return false, "no_character" end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return false, "no_hrp" end

    Logger.log("[POSITION] Moving to target location...", "action")

    local okTp, tpErr = pcall(function()
        hrp.CFrame = safeCFrame
    end)

    if not okTp then
        Logger.log("[POSITION] Return move failed: " .. tostring(tpErr), "warn")
        return false, "return_failed: " .. tostring(tpErr)
    end

    task.wait(0.3) -- settle

    Logger.log("[POSITION] Arrived at target location", "action")
    return true, "returned"
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 8: FORWARD DECLARATIONS
-- ════════════════════════════════════════════════════════════════

local StateMachine   = {}
local Arbiter        = {}
local ActionController = {}
local Detection      = {}
local Confirmation   = {}
local GuiModule      = {}

-- ════════════════════════════════════════════════════════════════
-- SECTION 9: STATE MACHINE
-- ════════════════════════════════════════════════════════════════

function StateMachine.setMainState(newState)
    if State.HubClosed then return end
    local old = State.MainState
    if old == newState then return end

    State.MainState = newState
    Logger.log("[STATE] " .. old .. " -> " .. newState, "state")

    -- When entering trial states, check if orbs should become PENDING
    if newState == "TRIAL_AVAILABLE" or newState == "TRIAL_ENTERING" or newState == "TRIAL_ACTIVE" then
        if State.OrbState == "AVAILABLE" then
            StateMachine.setOrbState("PENDING")
            Logger.log("[ORB] Pending because Trial has priority", "orb")
        end
    end

    -- After state change, let the Arbiter re-evaluate
    task.defer(function()
        if not State.HubClosed then
            Arbiter.evaluate()
        end
    end)
end

function StateMachine.setOrbState(newState)
    if State.HubClosed then return end
    local old = State.OrbState
    if old == newState then return end

    State.OrbState = newState

    -- Don't log trivial NONE->NONE
    if not (old == "NONE" and newState == "NONE") then
        Logger.log("[STATE] OrbState: " .. old .. " -> " .. newState, "state")
    end

    task.defer(function()
        if not State.HubClosed then
            Arbiter.evaluate()
        end
    end)
end

function StateMachine.clearCurrentAction(reason)
    local actionName = State.CurrentAction.name
    State.CurrentAction = {
        name       = "NONE",
        startedAt  = 0,
        attemptId  = 0,
        timeout    = 0,
        cancelled  = false,
        targetItem = nil,
    }
    if actionName ~= "NONE" and reason then
        Logger.log("[ACTION] " .. actionName .. " cleared: " .. reason, "action")
    end
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 10: ACTION CONTROLLER
-- ════════════════════════════════════════════════════════════════

function ActionController.RequestEnterTrial()
    if State.HubClosed then return false, "hub_closed" end
    if not State.AutomationMaster then return false, "automation_off" end
    if not State.AutoJoinTrial then return false, "auto_join_off" end
    if State.CurrentAction.name ~= "NONE" then return false, "action_locked" end
    if State.MainState ~= "TRIAL_AVAILABLE" then return false, "not_trial_available" end

    -- Check cooldown
    if tick() < (State._actionCooldowns.ENTER_TRIAL or 0) then
        return false, "cooldown"
    end

    -- Revalidate: is trial still available?
    local invite = resolveInvite()
    if not invite then return false, "invite_not_found" end
    local ok, enabled = pcall(function() return invite.Enabled end)
    if not ok or not enabled then return false, "invite_not_enabled" end
    if not hasTextContaining(invite, "time trial") then return false, "no_trial_text" end

    -- Proceed
    State._attemptCounter = State._attemptCounter + 1
    local attemptId = State._attemptCounter

    State.CurrentAction = {
        name       = "ENTER_TRIAL",
        startedAt  = tick(),
        attemptId  = attemptId,
        timeout    = Config.ActionTimeouts.EnterTrial,
        cancelled  = false,
        targetItem = nil,
    }

    StateMachine.setMainState("TRIAL_ENTERING")
    Logger.log("[ACTION] ENTER_TRIAL requested (#" .. attemptId .. ")", "action")
    State.LastAction = "ENTER_TRIAL #" .. attemptId

    -- Call adapter in separate thread
    task.spawn(function()
        local success, reason = Actions.EnterTrial({
            attemptId   = attemptId,
            isCancelled = function()
                return State.CurrentAction.cancelled
                    or State.CurrentAction.attemptId ~= attemptId
            end,
        })

        -- Adapter result does NOT determine success.
        -- Confirmation layer handles that via observed signals.
        if not success and State.CurrentAction.attemptId == attemptId and not State.CurrentAction.cancelled then
            Logger.log("[ACTION] ENTER_TRIAL adapter returned: " .. (reason or "unknown"), "warn")
        end
    end)

    return true
end

function ActionController.RequestFarmTrial()
    if State.HubClosed then return false, "hub_closed" end
    if not State.AutomationMaster then return false, "automation_off" end
    if not State.AutoTrial then return false, "auto_trial_off" end
    if State.CurrentAction.name ~= "NONE" then return false, "action_locked" end
    if State.MainState ~= "TRIAL_ACTIVE" then return false, "not_trial_active" end

    -- Check cooldown
    if tick() < (State._actionCooldowns.FARM_TRIAL or 0) then
        return false, "cooldown"
    end

    -- Revalidate: is trial still active?
    if not State.trialActive then return false, "trial_not_active" end

    -- Resolve trial container
    local trialContainer = nil
    if Refs.EnemiesGamemode and State.trialModeName ~= "" then
        local ok, child = pcall(function()
            return Refs.EnemiesGamemode:FindFirstChild(State.trialModeName)
        end)
        if ok and child then
            trialContainer = child
        end
    end

    -- Guard against starting loop without container
    if not trialContainer then
        return false, "no_trial_container_found"
    end

    State._attemptCounter = State._attemptCounter + 1
    local attemptId = State._attemptCounter

    State.CurrentAction = {
        name       = "FARM_TRIAL",
        startedAt  = tick(),
        attemptId  = attemptId,
        timeout    = Config.ActionTimeouts.FarmTrial,  -- math.huge: lifecycle worker
        cancelled  = false,
        targetItem = nil,
    }

    Logger.log("[ACTION] FARM_TRIAL requested (#" .. attemptId .. ")", "action")
    if State._pendingRecoveryLog then
        Logger.log("[TRIAL] Trial worker recovered from existing active Trial", "trial")
        State._pendingRecoveryLog = false
    end
    Logger.log("[ACTION] Trial worker started", "action")
    State.LastAction = "FARM_TRIAL #" .. attemptId

    task.spawn(function()
        local success, reason = Actions.FarmTrial({
            attemptId      = attemptId,
            isCancelled    = function()
                return State.CurrentAction.cancelled
                    or State.CurrentAction.attemptId ~= attemptId
            end,
            trialContainer = trialContainer,
        })

        if not success and State.CurrentAction.attemptId == attemptId and not State.CurrentAction.cancelled then
            Logger.log("[ACTION] FARM_TRIAL adapter returned: " .. (reason or "unknown"), "warn")
            State._actionCooldowns.FARM_TRIAL = tick() + Config.ActionRetryCooldown
            StateMachine.clearCurrentAction("adapter_failed")
            
            -- Re-evaluate after cooldown to permit safe recovery without aggressive looping
            task.delay(Config.ActionRetryCooldown + 0.1, function()
                if not State.HubClosed then
                    Arbiter.evaluate()
                end
            end)
        end
    end)

    return true
end

function ActionController.RequestCollectOrb(orbInfo)
    if State.HubClosed then return false, "hub_closed" end
    if not State.AutomationMaster then return false, "automation_off" end
    if not State.AutoOrb then return false, "auto_orb_off" end
    if State.CurrentAction.name ~= "NONE" then return false, "action_locked" end

    -- Check cooldown
    if tick() < (State._actionCooldowns.COLLECT_ORB or 0) then
        return false, "cooldown"
    end

    -- Revalidate: item still exists? (#51)
    if not orbInfo or not isInstanceValid(orbInfo.instance) then
        return false, "item_destroyed"
    end
    if safeGetAttribute(orbInfo.instance, "Type") ~= "CommandmentFragment" then
        return false, "item_type_changed"
    end
    if not isInstanceValid(orbInfo.root) then
        return false, "root_destroyed"
    end

    -- Trial priority preemption (#31)
    if State.trialAvailable or State.trialActive then
        Logger.log("[DECISION] Trial preempted pending Orb action", "decision")
        return false, "trial_has_priority"
    end
    if State.MainState == "TRIAL_AVAILABLE"
        or State.MainState == "TRIAL_ENTERING"
        or State.MainState == "TRIAL_ACTIVE" then
        Logger.log("[DECISION] Trial state preempted Orb action", "decision")
        return false, "trial_state_priority"
    end

    -- Check expiration
    local expireAt = orbInfo.expireAt
    if expireAt then
        local remaining = expireAt - getServerTime()
        if remaining <= 0 then
            return false, "orb_expired"
        end
    end

    State._attemptCounter = State._attemptCounter + 1
    local attemptId = State._attemptCounter

    State.CurrentAction = {
        name       = "COLLECT_ORB",
        startedAt  = tick(),
        attemptId  = attemptId,
        timeout    = Config.ActionTimeouts.CollectOrb,
        cancelled  = false,
        targetItem = orbInfo,
    }

    StateMachine.setOrbState("COLLECT_ATTEMPT")
    Logger.log("[ACTION] COLLECT_ORB requested (#" .. attemptId .. ")", "action")
    State.LastAction = "COLLECT_ORB #" .. attemptId

    task.spawn(function()
        local success, reason = Actions.CollectOrb({
            attemptId   = attemptId,
            isCancelled = function()
                return State.CurrentAction.cancelled
                    or State.CurrentAction.attemptId ~= attemptId
            end,
            item = orbInfo,
        })

        if not success and State.CurrentAction.attemptId == attemptId and not State.CurrentAction.cancelled then
            Logger.log("[ACTION] COLLECT_ORB adapter returned: " .. (reason or "unknown"), "warn")

            -- ORB RECOVERY LOGIC (Target Not Reached)
            if reason == "target_not_reached" then
                -- Revalidate the exact same orb specifically before triggering recovery
                local isValid = isInstanceValid(orbInfo.instance) 
                            and safeGetAttribute(orbInfo.instance, "Type") == "CommandmentFragment"
                            and isInstanceValid(orbInfo.root)
                            and isInstanceValid(orbInfo.prompt)
                            and (not orbInfo.expireAt or (orbInfo.expireAt - getServerTime() > 0))
                
                if isValid then
                    if not orbInfo.recoveryAttempted then
                        orbInfo.recoveryAttempted = true
                        Logger.log("[ORB] Target not reached. Initiating single recovery phase.", "warn")
                        StateMachine.clearCurrentAction("recovery_initiated")
                        if State.OrbRecoveryPosition then
                            StateMachine.setOrbState("RECOVERY_PENDING")
                        else
                            StateMachine.setOrbState("RECOVERY_READY")
                        end
                        return
                    else
                        orbInfo.blocked = true
                        Logger.log("[ORB] Recovery failed. Orb blocked from future retries.", "error")
                        State.LastError = "Orb recovery failed"
                        StateMachine.clearCurrentAction("recovery_failed")
                        
                        Detection.updateOrbStateAfterChange()
                        if State.SafeReturnPosition then
                            ActionController.RequestFailsafeReturn()
                        end
                        return
                    end
                else
                    Logger.log("[ORB] Orb invalidated during failure, skipping recovery.", "warn")
                end
            end

            State._actionCooldowns.COLLECT_ORB = tick() + Config.ActionRetryCooldown
            StateMachine.clearCurrentAction("adapter_failed")
        end
    end)

    return true
end

function ActionController.RequestOrbRecoveryStage(orbInfo)
    if State.HubClosed then return false, "hub_closed" end
    if not State.AutomationMaster then return false, "automation_off" end
    if not State.AutoOrb then return false, "auto_orb_off" end
    if State.CurrentAction.name ~= "NONE" then return false, "action_locked" end

    -- Recovery staging ONLY if explicit position exists
    if not State.OrbRecoveryPosition then
        return false, "no_staging_position"
    end

    -- Final validation before staging
    if not orbInfo or not isInstanceValid(orbInfo.instance) or safeGetAttribute(orbInfo.instance, "Type") ~= "CommandmentFragment" or not isInstanceValid(orbInfo.root) then
        return false, "orb_invalid"
    end
    if orbInfo.expireAt and (orbInfo.expireAt - getServerTime()) <= 0 then
        return false, "orb_expired"
    end

    State._attemptCounter = State._attemptCounter + 1
    local attemptId = State._attemptCounter

    State.CurrentAction = {
        name       = "ORB_RECOVERY_STAGE",
        startedAt  = tick(),
        attemptId  = attemptId,
        timeout    = Config.ActionTimeouts.ReturnToSafe, -- Reuse safe teleport timeout limit
        cancelled  = false,
        targetItem = orbInfo,
    }

    StateMachine.setOrbState("RECOVERY_STAGING")
    Logger.log("[ACTION] ORB_RECOVERY_STAGE requested (#" .. attemptId .. ")", "action")

    task.spawn(function()
        -- Staging move intrinsically leverages the user's explicit setup via native adapter wrapper.
        local success, reason = Actions.ReturnToSafePosition({
            attemptId   = attemptId,
            isCancelled = function()
                return State.CurrentAction.cancelled
                    or State.CurrentAction.attemptId ~= attemptId
            end,
            targetCFrame = State.OrbRecoveryPosition
        })

        if success and State.CurrentAction.attemptId == attemptId and not State.CurrentAction.cancelled then
            Logger.log("[ACTION] ORB_RECOVERY_STAGE completed", "action")
            StateMachine.clearCurrentAction("staging_completed")
            StateMachine.setOrbState("RECOVERY_READY")
        elseif not success and State.CurrentAction.attemptId == attemptId and not State.CurrentAction.cancelled then
            Logger.log("[ACTION] ORB_RECOVERY_STAGE failed: " .. (reason or "unknown"), "warn")
            orbInfo.blocked = true
            State._actionCooldowns.ORB_RECOVERY_STAGE = tick() + Config.ActionRetryCooldown
            StateMachine.clearCurrentAction("staging_failed")
            
            Detection.updateOrbStateAfterChange()
            if State.SafeReturnPosition then
                ActionController.RequestFailsafeReturn()
            end
        end
    end)
    return true
end

function ActionController.CancelCurrent(reason)
    if State.CurrentAction.name == "NONE" then return end

    local actionName = State.CurrentAction.name
    State.CurrentAction.cancelled = true
    Logger.log("[ACTION] " .. actionName .. " cancelled: " .. (reason or "no reason"), "warn")

    if actionName == "FARM_TRIAL" then
        Logger.log("[ACTION] Trial worker stopped", "warn")
    end

    -- Set cooldown so we don't immediately retry
    State._actionCooldowns[actionName] = tick() + Config.ActionRetryCooldown

    StateMachine.clearCurrentAction(reason)

    -- Revalidate state from observation
    Detection.revalidateStatesFromObservation()
end

function ActionController.checkTimeout()
    if State.CurrentAction.name == "NONE" then return end
    if State.CurrentAction.cancelled then return end

    -- FARM_TRIAL is a lifecycle worker — it does not timeout.
    -- It is cancelled by detection (trial ends, toggle off, hub closed).
    if State.CurrentAction.name == "FARM_TRIAL" then return end

    local elapsed = tick() - State.CurrentAction.startedAt
    if elapsed >= State.CurrentAction.timeout then
        local actionName = State.CurrentAction.name
        
        -- ORB RECOVERY TIMEOUT CHECK
        if actionName == "COLLECT_ORB" then
            local orbInfo = State.CurrentAction.targetItem
            if orbInfo then
                local isValid = isInstanceValid(orbInfo.instance) 
                            and safeGetAttribute(orbInfo.instance, "Type") == "CommandmentFragment"
                            and isInstanceValid(orbInfo.root)
                            and isInstanceValid(orbInfo.prompt)
                            and (not orbInfo.expireAt or (orbInfo.expireAt - getServerTime() > 0))

                if isValid then
                    if not orbInfo.recoveryAttempted then
                        orbInfo.recoveryAttempted = true
                        Logger.log("[ORB] Interaction timeout. Initiating single recovery phase.", "warn")
                        StateMachine.clearCurrentAction("timeout_recovery_initiated")
                        if State.OrbRecoveryPosition then
                            StateMachine.setOrbState("RECOVERY_PENDING")
                        else
                            StateMachine.setOrbState("RECOVERY_READY")
                        end
                        return
                    else
                        orbInfo.blocked = true
                        Logger.log("[ORB] Recovery failed after timeout. Orb blocked.", "error")
                        State.LastError = "Orb recovery timeout"
                        StateMachine.clearCurrentAction("recovery_failed")
                        
                        Detection.updateOrbStateAfterChange()
                        if State.SafeReturnPosition then
                            ActionController.RequestFailsafeReturn()
                        end
                        return
                    end
                end
            end
        end

        Logger.log("[ACTION FAILED] " .. actionName .. " timeout", "error")
        State.LastError = actionName .. " timeout"

        -- Set cooldown
        State._actionCooldowns[actionName] = tick() + Config.ActionRetryCooldown

        StateMachine.clearCurrentAction("timeout")

        -- Revalidate state from what the game actually shows
        Detection.revalidateStatesFromObservation()

        -- Re-evaluate
        Arbiter.evaluate()
    end
end

function ActionController.RequestReturnToSafe()
    if State.HubClosed then return false, "hub_closed" end
    if not State.AutomationMaster then return false, "automation_off" end
    if not State.ReturnAfterOrb then return false, "return_after_orb_off" end
    if State.CurrentAction.name ~= "NONE" then return false, "action_locked" end
    if not State.SafeReturnPosition then
        Logger.log("[POSITION] Return skipped: no fixed position", "info")
        return false, "no_safe_position"
    end

    -- Trial has priority
    if State.trialAvailable or State.trialActive
        or State.MainState == "TRIAL_AVAILABLE"
        or State.MainState == "TRIAL_ENTERING"
        or State.MainState == "TRIAL_ACTIVE" then
        return false, "trial_has_priority"
    end

    if tick() < (State._actionCooldowns.RETURN_TO_SAFE or 0) then
        return false, "cooldown"
    end

    State._attemptCounter = State._attemptCounter + 1
    local attemptId = State._attemptCounter

    State.CurrentAction = {
        name       = "RETURN_TO_SAFE",
        startedAt  = tick(),
        attemptId  = attemptId,
        timeout    = Config.ActionTimeouts.ReturnToSafe,
        cancelled  = false,
        targetItem = nil,
    }

    Logger.log("[ACTION] RETURN_TO_SAFE requested (#" .. attemptId .. ")", "action")
    State.LastAction = "RETURN_TO_SAFE #" .. attemptId

    task.spawn(function()
        local success, reason = Actions.ReturnToSafePosition({
            attemptId   = attemptId,
            isCancelled = function()
                return State.CurrentAction.cancelled
                    or State.CurrentAction.attemptId ~= attemptId
            end,
        })

        if success and State.CurrentAction.attemptId == attemptId then
            Logger.log("[ACTION] RETURN_TO_SAFE completed", "action")
            StateMachine.clearCurrentAction("return_completed")
        elseif not success and State.CurrentAction.attemptId == attemptId
            and not State.CurrentAction.cancelled then
            Logger.log("[ACTION] RETURN_TO_SAFE failed: " .. (reason or "unknown"), "warn")
        end
    end)

    return true
end

function ActionController.RequestFailsafeReturn()
    if State.HubClosed then return false, "hub_closed" end
    if not State.AutomationMaster then return false, "automation_off" end
    if State.CurrentAction.name ~= "NONE" then return false, "action_locked" end
    if not State.SafeReturnPosition then return false, "no_safe_position" end

    -- Trial has priority
    if State.trialAvailable or State.trialActive
        or State.MainState == "TRIAL_AVAILABLE"
        or State.MainState == "TRIAL_ENTERING"
        or State.MainState == "TRIAL_ACTIVE" then
        return false, "trial_has_priority"
    end

    if tick() < (State._actionCooldowns.FAILSAFE_RETURN or 0) then
        return false, "cooldown"
    end

    State._attemptCounter = State._attemptCounter + 1
    local attemptId = State._attemptCounter

    State.CurrentAction = {
        name       = "FAILSAFE_RETURN",
        startedAt  = tick(),
        attemptId  = attemptId,
        timeout    = Config.ActionTimeouts.ReturnToSafe,
        cancelled  = false,
        targetItem = nil,
    }

    Logger.log("[ACTION] FAILSAFE_RETURN requested (#" .. attemptId .. ")", "action")
    State.LastAction = "FAILSAFE_RETURN #" .. attemptId

    task.spawn(function()
        local success, reason = Actions.ReturnToSafePosition({
            attemptId   = attemptId,
            isCancelled = function()
                return State.CurrentAction.cancelled
                    or State.CurrentAction.attemptId ~= attemptId
            end,
        })

        if success and State.CurrentAction.attemptId == attemptId then
            Logger.log("[ACTION] FAILSAFE_RETURN completed", "action")
            StateMachine.clearCurrentAction("failsafe_completed")
        elseif not success and State.CurrentAction.attemptId == attemptId
            and not State.CurrentAction.cancelled then
            Logger.log("[ACTION] FAILSAFE_RETURN failed: " .. (reason or "unknown"), "warn")
            State._actionCooldowns.FAILSAFE_RETURN = tick() + Config.ActionRetryCooldown
            StateMachine.clearCurrentAction("failsafe_failed")
        end
    end)

    return true
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 11: ARBITER / DECISION CONTROLLER
-- ════════════════════════════════════════════════════════════════
-- The Arbiter decides which action (if any) should be requested,
-- based on current state and priority.
-- Priority: TRIAL_ACTIVE > TRIAL_AVAILABLE > TRIAL_ENTERING >
--           TRIAL_ENDING/POST_TRIAL > ORB_RECOVERY_STAGE > ORB_AVAILABLE > IDLE

function Arbiter.evaluate()
    if State.HubClosed then return end

    -- Check for preemption: if an Orb action is pending and Trial appeared
    if State.CurrentAction.name == "COLLECT_ORB" or State.CurrentAction.name == "ORB_RECOVERY_STAGE" or State.CurrentAction.name == "FAILSAFE_RETURN" then
        if State.trialAvailable or State.trialActive
            or State.MainState == "TRIAL_AVAILABLE"
            or State.MainState == "TRIAL_ENTERING"
            or State.MainState == "TRIAL_ACTIVE" then
            Logger.log("[DECISION] Trial preempted pending action", "decision")
            ActionController.CancelCurrent("trial_preemption")
            return -- will be re-evaluated after cancel
        end
    end

    -- If automation is off, don't request any actions
    if not State.AutomationMaster then return end

    -- If an action is already running, don't start another
    if State.CurrentAction.name ~= "NONE" then return end

    -- Priority-based evaluation
    if State.MainState == "TRIAL_ACTIVE" then
        -- Priority 1: Farm if in active trial
        if State.AutoTrial then
            if tick() >= (State._actionCooldowns.FARM_TRIAL or 0) then
                ActionController.RequestFarmTrial()
            end
        end
    elseif State.MainState == "TRIAL_AVAILABLE" then
        -- Priority 2: Enter trial if available
        if State.AutoJoinTrial then
            if tick() >= (State._actionCooldowns.ENTER_TRIAL or 0) then
                ActionController.RequestEnterTrial()
            end
        end
    elseif State.MainState == "TRIAL_ENTERING" then
        -- Priority 3: Waiting for entry confirmation, don't start new actions
        -- (already handled by action lock)
    elseif State.MainState == "TRIAL_ENDING" or State.MainState == "POST_TRIAL" then
        -- Priority 4: Waiting for trial to finish, no new actions
    elseif State.MainState == "IDLE" then
        -- Priority 5: Check if return to safe is pending
        if State.OrbState == "COLLECTED" and State.ReturnAfterOrb
            and State.SafeReturnPosition then
            if tick() >= (State._actionCooldowns.RETURN_TO_SAFE or 0) then
                ActionController.RequestReturnToSafe()
                return
            end
        end

        -- Priority 5.5: Orb recovery stage
        if State.OrbState == "RECOVERY_PENDING" and State.AutoOrb then
            if not State.trialAvailable and not State.trialActive then
                local activeOrb = Detection.getActiveOrb()
                if activeOrb and activeOrb.recoveryAttempted and not activeOrb.blocked then
                    if State.OrbRecoveryPosition then
                        if tick() >= (State._actionCooldowns.ORB_RECOVERY_STAGE or 0) then
                            ActionController.RequestOrbRecoveryStage(activeOrb)
                            return
                        end
                    else
                        StateMachine.setOrbState("RECOVERY_READY")
                        return
                    end
                else
                    Detection.updateOrbStateAfterChange()
                end
            else
                Logger.log("[DECISION] Trial has priority over Orb Recovery", "decision")
            end
        end

        -- Priority 5.6: Orb recovery ready (collect phase 2)
        if State.OrbState == "RECOVERY_READY" and State.AutoOrb then
            if not State.trialAvailable and not State.trialActive then
                local activeOrb = Detection.getActiveOrb()
                if activeOrb and activeOrb.recoveryAttempted and not activeOrb.blocked then
                    if tick() >= (State._actionCooldowns.COLLECT_ORB or 0) then
                        Logger.log("[DECISION] Requesting Orb collection (Recovery Phase)", "decision")
                        ActionController.RequestCollectOrb(activeOrb)
                        return
                    end
                else
                    Detection.updateOrbStateAfterChange()
                end
            else
                Logger.log("[DECISION] Trial has priority over Orb Recovery", "decision")
            end
        end

        -- Priority 6: Check normal orb availability
        if State.OrbState == "AVAILABLE" and State.AutoOrb then
            -- Before requesting, do a final check that no trial appeared
            if not State.trialAvailable and not State.trialActive then
                local activeOrb = Detection.getActiveOrb()
                if activeOrb then
                    if tick() >= (State._actionCooldowns.COLLECT_ORB or 0) then
                        Logger.log("[DECISION] Requesting Orb collection", "decision")
                        ActionController.RequestCollectOrb(activeOrb)
                    end
                end
            else
                Logger.log("[DECISION] Trial has priority over Orb", "decision")
            end
        end
    end
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 12: DETECTION LAYER
-- ════════════════════════════════════════════════════════════════

--- Returns the active/priority orb from ObservedSpawnItems.
--- Criteria: smallest valid ExpireAt, or first detected still existing.
function Detection.getActiveOrb()
    local bestOrb = nil
    local bestExpire = math.huge

    for inst, info in pairs(State.ObservedSpawnItems) do
        -- Blocked Orbs are ignored entirely to prevent infinite recovery loops
        if not info.removed and not info.collected and not info.blocked and isInstanceValid(inst) then
            if info.expireAt and info.expireAt > 0 then
                local remaining = info.expireAt - getServerTime()
                if remaining > 0 and info.expireAt < bestExpire then
                    bestExpire = info.expireAt
                    bestOrb = info
                end
            else
                -- No expireAt, use firstSeenAt as tiebreaker
                if not bestOrb or (not bestOrb.expireAt and info.firstSeenAt < bestOrb.firstSeenAt) then
                    bestOrb = info
                end
            end
        end
    end

    return bestOrb
end

--- Returns count of active (non-removed, non-collected) orbs.
function Detection.getActiveOrbCount()
    local count = 0
    for inst, info in pairs(State.ObservedSpawnItems) do
        if not info.removed and not info.collected and not info.blocked and isInstanceValid(inst) then
            count = count + 1
        end
    end
    return count
end

--- Inspect a single item from _SPAWNITEMS.
function Detection.inspectSpawnItem(item)
    if State.HubClosed then return end
    if not isInstanceValid(item) then return end

    -- Already tracked?
    if State.ObservedSpawnItems[item] then return end

    -- Check identity
    local itemType = safeGetAttribute(item, "Type")
    if itemType ~= "CommandmentFragment" then return end

    -- Secondary confirmation
    local spawnId = safeGetAttribute(item, "SpawnId")
    -- SpawnId == "Commandments" is secondary, not strictly required

    local expireAt = safeGetAttribute(item, "ExpireAt")
    local root = nil
    local prompt = nil

    local ok1, r = pcall(function() return item:FindFirstChild("Root") end)
    if ok1 and r then
        root = r
        local ok2, p = pcall(function() return r:FindFirstChildOfClass("ProximityPrompt") end)
        if ok2 and p then
            prompt = p
        end
    end

    -- Get position
    local position = nil
    if root then
        local ok, pos = pcall(function() return root.Position end)
        if ok then position = pos end
    end
    if not position then
        local ok, pivot = pcall(function() return item:GetPivot() end)
        if ok and pivot then position = pivot.Position end
    end

    local info = {
        instance         = item,
        hash             = item.Name,
        root             = root,
        prompt           = prompt,
        expireAt         = (type(expireAt) == "number") and expireAt or nil,
        firstSeenAt      = tick(),
        promptTriggeredAt = nil,
        removed          = false,
        collected        = false,
        blocked          = false,
        recoveryAttempted= false,
        position         = position,
        connections      = {},
    }

    State.ObservedSpawnItems[item] = info
    State.OrbsDetected = State.OrbsDetected + 1
    Logger.log("[ORB] Commandment Fragment detected (hash: " .. item.Name:sub(1, 8) .. "...)", "orb")
    State.LastEvent = "ORB detected"

    -- Determine OrbState
    if State.MainState == "TRIAL_AVAILABLE"
        or State.MainState == "TRIAL_ENTERING"
        or State.MainState == "TRIAL_ACTIVE" then
        StateMachine.setOrbState("PENDING")
        Logger.log("[ORB] Pending because Trial has priority", "orb")
    else
        StateMachine.setOrbState("AVAILABLE")
    end

    -- Connect ProximityPrompt.Triggered for collection confirmation
    if prompt then
        local trigConn = connect(prompt.Triggered, function(player)
            if State.HubClosed then return end
            if not State.MonitorOrb then return end
            if player == LocalPlayer then
                info.promptTriggeredAt = tick()
                Logger.log("[ORB] LocalPlayer triggered Collect", "orb")
                State.LastEvent = "ORB Triggered"
            end
        end, "orb_prompt")
        table.insert(info.connections, trigConn)
    end

    -- Connect Destroying / AncestryChanged for removal detection
    local function handleRemoval()
        if info.removed then return end
        info.removed = true
        Detection.handleOrbRemoved(info)
    end

    local destConn = connect(item.Destroying, function()
        if State.HubClosed then return end
        if not State.MonitorOrb then return end
        handleRemoval()
    end, "orb_lifecycle")
    if destConn then table.insert(info.connections, destConn) end

    local ancConn = connect(item.AncestryChanged, function(_, newParent)
        if State.HubClosed then return end
        if not State.MonitorOrb then return end
        if newParent == nil then
            handleRemoval()
        end
    end, "orb_lifecycle")
    if ancConn then table.insert(info.connections, ancConn) end
end

--- Handle orb removal (Destroying / AncestryChanged / ChildRemoved).
function Detection.handleOrbRemoved(orbInfo)
    if State.HubClosed then return end

    -- Check if collection was confirmed (Triggered recently by LocalPlayer)
    if orbInfo.promptTriggeredAt then
        local elapsed = tick() - orbInfo.promptTriggeredAt
        if elapsed <= Config.CollectConfirmWindow then
            -- COLLECTED confirmed
            orbInfo.collected = true
            State.OrbsCollected = State.OrbsCollected + 1
            Logger.log("[ORB] Commandment Fragment collected", "orb")
            State.LastEvent = "ORB collected"

            -- If this was the current action's target, confirm it
            if State.CurrentAction.name == "COLLECT_ORB"
                and State.CurrentAction.targetItem == orbInfo then
                Logger.log("[ACTION] COLLECT_ORB confirmed", "action")
                StateMachine.clearCurrentAction("confirmed_collected")
            end

            StateMachine.setOrbState("COLLECTED")
            Detection.cleanupOrbInfo(orbInfo)
            Detection.updateOrbStateAfterChange()
            return
        end
    end

    -- Not collected by LocalPlayer
    -- Check if likely expired
    if orbInfo.expireAt then
        local remaining = orbInfo.expireAt - getServerTime()
        if remaining <= Config.OrbExpireThreshold then
            State.OrbsLikelyExpired = State.OrbsLikelyExpired + 1
            Logger.log("[ORB] Likely expired", "orb")
            State.LastEvent = "ORB likely expired"
            StateMachine.setOrbState("LIKELY_EXPIRED")
            Detection.cleanupOrbInfo(orbInfo)
            Detection.updateOrbStateAfterChange()
            return
        end
    end

    -- Unknown removal reason
    State.OrbsRemoved = State.OrbsRemoved + 1
    Logger.log("[ORB] Removed without confirmed collection", "orb")
    State.LastEvent = "ORB removed"

    -- If this was the current action's target, fail it
    if State.CurrentAction.name == "COLLECT_ORB"
        and State.CurrentAction.targetItem == orbInfo then
        Logger.log("[ACTION FAILED] COLLECT_ORB - item removed without confirmation", "error")
        State.LastError = "COLLECT_ORB item removed"
        State._actionCooldowns.COLLECT_ORB = tick() + Config.ActionRetryCooldown
        StateMachine.clearCurrentAction("item_removed")
    end

    StateMachine.setOrbState("REMOVED")
    Detection.cleanupOrbInfo(orbInfo)
    Detection.updateOrbStateAfterChange()
end

--- Clean up connections for an orb info entry.
function Detection.cleanupOrbInfo(orbInfo)
    for _, conn in ipairs(orbInfo.connections or {}) do
        pcall(function() conn:Disconnect() end)
        -- Also remove from AllConnections
        for i = #AllConnections, 1, -1 do
            if AllConnections[i].conn == conn then
                table.remove(AllConnections, i)
                break
            end
        end
    end
    orbInfo.connections = {}
end

--- After an orb state change, check if there are other active orbs.
function Detection.updateOrbStateAfterChange()
    if State.HubClosed then return end

    -- Clean up destroyed references
    for inst, info in pairs(State.ObservedSpawnItems) do
        if info.removed or info.collected or not isInstanceValid(inst) then
            if not info.removed and not info.collected then
                info.removed = true
                info.collected = false
                Detection.cleanupOrbInfo(info)
            end
        end
    end

    -- Check if any active orbs remain
    local activeOrb = Detection.getActiveOrb()
    if activeOrb then
        -- Determine correct state based on MainState
        if State.MainState == "TRIAL_AVAILABLE"
            or State.MainState == "TRIAL_ENTERING"
            or State.MainState == "TRIAL_ACTIVE" then
            if State.OrbState ~= "PENDING" and State.OrbState ~= "COLLECT_ATTEMPT" and State.OrbState ~= "RECOVERY_STAGING" then
                StateMachine.setOrbState("PENDING")
            end
        else
            -- Restore active recovery states dynamically if applicable
            local targetState = "AVAILABLE"
            if activeOrb.recoveryAttempted and not activeOrb.blocked then
                if State.OrbState == "RECOVERY_STAGING" then targetState = "RECOVERY_STAGING"
                elseif State.OrbState == "RECOVERY_READY" then targetState = "RECOVERY_READY"
                else targetState = "RECOVERY_PENDING" end
            end

            if State.OrbState ~= targetState and State.OrbState ~= "COLLECT_ATTEMPT" then
                StateMachine.setOrbState(targetState)
            end
        end
    else
        if State.OrbState ~= "NONE"
            and State.OrbState ~= "COLLECTED"
            and State.OrbState ~= "REMOVED"
            and State.OrbState ~= "LIKELY_EXPIRED" then
            StateMachine.setOrbState("NONE")
        end
    end
end

--- Handle ChildRemoved from _SPAWNITEMS.
function Detection.handleSpawnItemRemoved(item)
    if State.HubClosed then return end
    if not State.MonitorOrb then return end

    local info = State.ObservedSpawnItems[item]
    if not info then return end
    if info.removed then return end

    info.removed = true
    Detection.handleOrbRemoved(info)
end

-- ─── TRIAL DETECTION ─────────────────────────────────────────

--- Handle Invite.Enabled changed.
function Detection.onInviteEnabledChanged()
    if State.HubClosed then return end
    if not State.MonitorTrial then return end

    local invite = Refs.Invite
    if not invite then return end

    local ok, enabled = pcall(function() return invite.Enabled end)
    if not ok then return end

    if enabled then
        -- Invite activated: snapshot for trial text
        if hasTextContaining(invite, "time trial") then
            if not State.trialAvailable and State.MainState ~= "TRIAL_ACTIVE" then
                State.trialAvailable = true
                State.TrialsDetected = State.TrialsDetected + 1
                Logger.log("[TRIAL] Time Trial available", "trial")
                State.LastEvent = "Trial available"
                StateMachine.setMainState("TRIAL_AVAILABLE")
            end
        end
    else
        -- Invite deactivated
        if State.trialAvailable then
            State.trialAvailable = false

            if State.MainState == "TRIAL_AVAILABLE" then
                -- Could mean player accepted or trial window closed
                StateMachine.setMainState("TRIAL_ENTERING")
                Logger.log("[TRIAL] Invite closed, awaiting entry confirmation...", "trial")

                -- Timeout: if no confirmation, revert to observed state
                trackedDelay(Config.TrialEntryTimeout, function()
                    if State.MainState == "TRIAL_ENTERING" then
                        Logger.log("[TRIAL] Entry not confirmed within timeout, reverting", "warn")
                        Detection.revalidateStatesFromObservation()
                    end
                end)
            end
        end
    end
end

--- Handle Gamemode.Enabled changed (PlayerGui.Gamemode).
--- IMPORTANT: Gamemode.Enabled is NOT sufficient to confirm Time Trial.
--- It also activates during Raids, Dungeons, and other game modes.
--- TRIAL_ACTIVE is ONLY confirmed by a real Time Trial container
--- existing in _ENEMIES.Server.Gamemode.
function Detection.onGamemodeEnabledChanged()
    if State.HubClosed then return end
    if not State.MonitorTrial then return end

    local gamemode = Refs.Gamemode
    if not gamemode then return end

    local ok, enabled = pcall(function() return gamemode.Enabled end)
    if not ok then return end

    if enabled then
        -- Gamemode activated: verify this is actually a Time Trial
        -- by checking for a real Time Trial container
        local isTimeTrial = false
        local gm = resolveEnemiesGamemode()
        if gm then
            local okC, children = pcall(function() return gm:GetChildren() end)
            if okC then
                for _, child in ipairs(children) do
                    local cok, cname = pcall(function() return child.Name end)
                    if cok and cname:lower():find("time trial", 1, true) then
                        isTimeTrial = true
                        break
                    end
                end
            end
        end

        if isTimeTrial then
            -- Confirmed Time Trial via real container
            -- Note: onGamemodeFolderChildAdded may have already handled this,
            -- but this serves as a secondary confirmation path.
            if not State._trialEntryProcessed then
                State._trialEntryProcessed = true
                State._hadConfirmedTimeTrial = true
                State.trialActive = true

                if State.MainState ~= "TRIAL_ACTIVE" then
                    State.TrialsEntered = State.TrialsEntered + 1
                    Logger.log("[TRIAL] real Time Trial confirmed", "trial")
                    Logger.log("[TRIAL] Entered Time Trial (confirmed by Gamemode + container)", "trial")
                    State.LastEvent = "Trial entered"
                    StateMachine.setMainState("TRIAL_ACTIVE")

                    if State.CurrentAction.name == "ENTER_TRIAL" then
                        Logger.log("[ACTION] ENTER_TRIAL confirmed", "action")
                        StateMachine.clearCurrentAction("confirmed_entry")
                    end
                end
            end
        else
            -- Non-Trial gamemode (Raid, Dungeon, etc.) — ignore
            Logger.log("[GAMEMODE] non-trial gamemode ignored", "info")
        end
    else
        -- Gamemode disabled: only process as trial ending if we
        -- actually had a confirmed Time Trial running.
        if State._hadConfirmedTimeTrial and State.trialActive and not State._trialEndProcessed then
            State._trialEndProcessed = true
            Logger.log("[TRIAL] Time Trial ending (Gamemode disabled)", "trial")
            State.LastEvent = "Trial ending"
            StateMachine.setMainState("TRIAL_ENDING")

            -- Cancel any current farm action
            if State.CurrentAction.name == "FARM_TRIAL" then
                ActionController.CancelCurrent("trial_ending")
            end

            -- Timeout: if child not removed, still transition
            trackedDelay(Config.TrialEndTimeout, function()
                if State.MainState == "TRIAL_ENDING" then
                    Logger.log("[TRIAL] Trial end timeout, forcing POST_TRIAL", "warn")
                    Detection.handleTrialFinished()
                end
            end)
        end
    end
end

--- Handle Time Trial child added to _ENEMIES.Server.Gamemode.
function Detection.onGamemodeFolderChildAdded(child)
    if State.HubClosed then return end
    if not State.MonitorTrial then return end

    local name = ""
    local ok, n = pcall(function() return child.Name end)
    if ok then name = n end

    if not name:lower():find("time trial", 1, true) then return end

    State.trialModeName = name

    if not State._trialEntryProcessed then
        State._trialEntryProcessed = true
        State._hadConfirmedTimeTrial = true
        State.trialActive = true

        if State.MainState ~= "TRIAL_ACTIVE" then
            State.TrialsEntered = State.TrialsEntered + 1
            Logger.log("[TRIAL] real Time Trial confirmed", "trial")
            Logger.log("[TRIAL] Entered Time Trial (" .. name .. ")", "trial")
            State.LastEvent = "Trial entered: " .. name
            StateMachine.setMainState("TRIAL_ACTIVE")

            if State.CurrentAction.name == "ENTER_TRIAL" then
                Logger.log("[ACTION] ENTER_TRIAL confirmed", "action")
                StateMachine.clearCurrentAction("confirmed_entry")
            end
        end
    end
end

--- Handle Time Trial child removed from _ENEMIES.Server.Gamemode.
function Detection.onGamemodeFolderChildRemoved(child)
    if State.HubClosed then return end
    if not State.MonitorTrial then return end

    local name = ""
    local ok, n = pcall(function() return child.Name end)
    if ok then name = n end

    if not name:lower():find("time trial", 1, true) then return end

    -- Trial confirmed finished
    Detection.handleTrialFinished()
end

--- Process a confirmed trial finish.
function Detection.handleTrialFinished()
    if State.HubClosed then return end

    -- Guard against double processing
    if State.MainState ~= "TRIAL_ENDING" and State.MainState ~= "TRIAL_ACTIVE" then
        -- Already processed or not in trial
        if State.MainState == "POST_TRIAL" then return end
    end

    State.trialActive = false
    State.trialAvailable = false
    State.trialModeName = ""
    State._trialEntryProcessed = false
    State._trialEndProcessed = false
    State._hadConfirmedTimeTrial = false
    State._pendingRecoveryLog = false
    State.TrialsFinished = State.TrialsFinished + 1
    Logger.log("[TRIAL] Time Trial finished", "trial")
    State.LastEvent = "Trial finished"

    -- Cancel farm action if still running
    if State.CurrentAction.name == "FARM_TRIAL" then
        ActionController.CancelCurrent("trial_finished")
    end

    StateMachine.setMainState("POST_TRIAL")

    -- Post-trial revalidation with debounce
    trackedDelay(Config.PostTrialDebounce, function()
        if State.MainState ~= "POST_TRIAL" then return end

        -- Revalidate character
        resolveCharacter()

        -- Revalidate PlayerGui bindings
        resolvePlayerGui()
        resolveInvite()
        resolveGamemodeGui()

        -- Revalidate orbs
        if State.MonitorOrb then
            Detection.snapshotOrbs()
            local activeOrb = Detection.getActiveOrb()
            if activeOrb then
                StateMachine.setOrbState("AVAILABLE")
                Logger.log("[ORB] Commandment Fragment still available after Trial", "orb")
            else
                -- Clean up any stale references
                for inst, info in pairs(State.ObservedSpawnItems) do
                    if not isInstanceValid(inst) and not info.removed and not info.collected then
                        info.removed = true
                        Detection.cleanupOrbInfo(info)
                    end
                end
                if State.OrbState == "PENDING" then
                    StateMachine.setOrbState("NONE")
                end
            end
        end

        -- Return to IDLE
        StateMachine.setMainState("IDLE")
    end)
end

-- ─── BINDING FUNCTIONS ────────────────────────────────────────

--- Bind/rebind Invite and Gamemode listeners in PlayerGui.
function Detection.bindPlayerGui()
    if State.HubClosed then return end

    -- Disconnect old bindings
    disconnectByTag("invite")
    disconnectByTag("gamemode_gui")
    disconnectByTag("playergui")

    local pg = resolvePlayerGui()
    if not pg then
        Logger.log("[SYSTEM] Waiting for PlayerGui...", "system")
        return
    end

    -- Bind Invite
    local invite = resolveInvite()
    if invite then
        connect(invite:GetPropertyChangedSignal("Enabled"), function()
            Detection.onInviteEnabledChanged()
        end, "invite")
    end

    -- Watch for Invite being added (if recreated)
    connect(pg.ChildAdded, function(child)
        if State.HubClosed then return end
        if child.Name == "Invite" then
            Refs.Invite = child
            disconnectByTag("invite")
            connect(child:GetPropertyChangedSignal("Enabled"), function()
                Detection.onInviteEnabledChanged()
            end, "invite")
            Logger.log("[SYSTEM] Invite rebound", "system")
            -- Snapshot if monitor is on
            if State.MonitorTrial then
                Detection.snapshotTrial()
            end
        elseif child.Name == "Gamemode" then
            Refs.Gamemode = child
            disconnectByTag("gamemode_gui")
            connect(child:GetPropertyChangedSignal("Enabled"), function()
                Detection.onGamemodeEnabledChanged()
            end, "gamemode_gui")
            Logger.log("[SYSTEM] Gamemode GUI rebound", "system")
        end
    end, "playergui")

    -- Bind Gamemode GUI
    local gamemode = resolveGamemodeGui()
    if gamemode then
        connect(gamemode:GetPropertyChangedSignal("Enabled"), function()
            Detection.onGamemodeEnabledChanged()
        end, "gamemode_gui")
    end
end

--- Bind/rebind _ENEMIES.Server.Gamemode folder.
function Detection.bindGamemodeFolder()
    if State.HubClosed then return end

    disconnectByTag("gamemode_folder")

    local gm = resolveEnemiesGamemode()
    if not gm then
        Logger.log("[SYSTEM] Waiting for _ENEMIES.Server.Gamemode...", "system")

        -- Try to observe creation
        local enemies = Workspace:FindFirstChild("_ENEMIES")
        if enemies then
            local server = enemies:FindFirstChild("Server")
            if server then
                connect(server.ChildAdded, function(child)
                    if child.Name == "Gamemode" then
                        Refs.EnemiesGamemode = child
                        Detection.bindGamemodeFolder()
                    end
                end, "gamemode_folder")
            else
                connect(enemies.ChildAdded, function(child)
                    if child.Name == "Server" then
                        local gmChild = child:FindFirstChild("Gamemode")
                        if gmChild then
                            Refs.EnemiesGamemode = gmChild
                            Detection.bindGamemodeFolder()
                        else
                            connect(child.ChildAdded, function(c2)
                                if c2.Name == "Gamemode" then
                                    Refs.EnemiesGamemode = c2
                                    Detection.bindGamemodeFolder()
                                end
                            end, "gamemode_folder")
                        end
                    end
                end, "gamemode_folder")
            end
        end
        return
    end

    -- Connected: watch for Time Trial children
    connect(gm.ChildAdded, function(child)
        Detection.onGamemodeFolderChildAdded(child)
    end, "gamemode_folder")

    connect(gm.ChildRemoved, function(child)
        Detection.onGamemodeFolderChildRemoved(child)
    end, "gamemode_folder")

    Logger.log("[SYSTEM] Gamemode folder bound", "system")
end

--- Bind/rebind _SPAWNITEMS.
function Detection.bindSpawnItems()
    if State.HubClosed then return end

    disconnectByTag("spawnitems")

    local si = resolveSpawnItems()
    if not si then
        Logger.log("[SYSTEM] Waiting for _SPAWNITEMS...", "system")
        -- Watch for creation
        connect(Workspace.ChildAdded, function(child)
            if child.Name == "_SPAWNITEMS" then
                Refs.SpawnItems = child
                disconnectByTag("spawnitems_wait")
                Detection.bindSpawnItems()
                -- Snapshot existing items
                if State.MonitorOrb then
                    Detection.snapshotOrbs()
                end
            end
        end, "spawnitems_wait")
        return
    end

    connect(si.ChildAdded, function(child)
        if State.HubClosed then return end
        if not State.MonitorOrb then return end
        -- Small yield to let attributes replicate
        task.defer(function()
            Detection.inspectSpawnItem(child)
        end)
    end, "spawnitems")

    connect(si.ChildRemoved, function(child)
        Detection.handleSpawnItemRemoved(child)
    end, "spawnitems")

    Logger.log("[SYSTEM] _SPAWNITEMS bound", "system")
end

--- Bind character references and handle respawns.
function Detection.bindCharacter()
    if State.HubClosed then return end

    disconnectByTag("character")

    resolveCharacter()

    connect(LocalPlayer.CharacterAdded, function(char)
        if State.HubClosed then return end
        Refs.Character = char
        local hrp = char:WaitForChild("HumanoidRootPart", 10)
        Refs.HumanoidRootPart = hrp
        Logger.log("[SYSTEM] Character respawned", "system")
    end, "character")
end

-- ─── SNAPSHOT FUNCTIONS ───────────────────────────────────────

--- Snapshot current trial state (for startup or when toggling Monitor Trial ON).
function Detection.snapshotTrial()
    if State.HubClosed then return end

    -- Check Invite
    local invite = resolveInvite()
    if invite then
        local ok, enabled = pcall(function() return invite.Enabled end)
        if ok and enabled then
            if hasTextContaining(invite, "time trial") then
                if not State.trialAvailable and State.MainState ~= "TRIAL_ACTIVE" then
                    State.trialAvailable = true
                    State.TrialsDetected = State.TrialsDetected + 1
                    Logger.log("[TRIAL] Time Trial available (snapshot)", "trial")
                    State.LastEvent = "Trial available (snapshot)"
                    StateMachine.setMainState("TRIAL_AVAILABLE")
                end
            end
        end
    end

    -- Check if trial is currently active
    local gm = resolveEnemiesGamemode()
    if gm then
        local ok, children = pcall(function() return gm:GetChildren() end)
        if ok then
            for _, child in ipairs(children) do
                local cok, cname = pcall(function() return child.Name end)
                if cok and cname:lower():find("time trial", 1, true) then
                    if not State.trialActive then
                        State.trialActive = true
                        State.trialModeName = cname
                        State._trialEntryProcessed = true
                        State._hadConfirmedTimeTrial = true

                        if State.MainState ~= "TRIAL_ACTIVE" then
                            State.TrialsEntered = State.TrialsEntered + 1
                            Logger.log("[TRIAL] real Time Trial confirmed", "trial")
                            Logger.log("[TRIAL] Time Trial active (snapshot: " .. cname .. ")", "trial")
                            State.LastEvent = "Trial active (snapshot)"
                            StateMachine.setMainState("TRIAL_ACTIVE")
                        end
                    end
                    break
                end
            end
        end
    end

    -- Also check Gamemode GUI
    local gamemodeGui = resolveGamemodeGui()
    if gamemodeGui then
        local ok, enabled = pcall(function() return gamemodeGui.Enabled end)
        if ok and enabled and State.trialActive then
            -- Additional confirmation already in TRIAL_ACTIVE state
        end
    end
end

--- Check if we just turned on automation while already in an active trial
function Detection.recoverTrialWorkerIfNeeded()
    if State.HubClosed then return end
    if State.AutomationMaster and State.AutoTrial and State.trialActive and State.CurrentAction.name ~= "FARM_TRIAL" then
        State._pendingRecoveryLog = true
    else
        State._pendingRecoveryLog = false
    end
end

--- Snapshot current orbs in _SPAWNITEMS.
function Detection.snapshotOrbs()
    if State.HubClosed then return end

    local si = resolveSpawnItems()
    if not si then return end

    local ok, children = pcall(function() return si:GetChildren() end)
    if not ok then return end

    for _, item in ipairs(children) do
        Detection.inspectSpawnItem(item)
    end
end

--- Revalidate states from actual game observation (after timeout/cancel).
function Detection.revalidateStatesFromObservation()
    if State.HubClosed then return end

    -- Reset transient flags
    State._trialEntryProcessed = false
    State._trialEndProcessed = false

    -- Check trial from scratch
    State.trialAvailable = false
    State.trialActive = false
    State.trialModeName = ""

    -- Check active trial
    local gm = resolveEnemiesGamemode()
    if gm then
        local ok, children = pcall(function() return gm:GetChildren() end)
        if ok then
            for _, child in ipairs(children) do
                local cok, cname = pcall(function() return child.Name end)
                if cok and cname:lower():find("time trial", 1, true) then
                    State.trialActive = true
                    State.trialModeName = cname
                    State._trialEntryProcessed = true
                    break
                end
            end
        end
    end

    -- Check invite
    local invite = resolveInvite()
    if invite then
        local ok, enabled = pcall(function() return invite.Enabled end)
        if ok and enabled then
            if hasTextContaining(invite, "time trial") then
                State.trialAvailable = true
            end
        end
    end

    -- Set MainState from observations
    if State.trialActive then
        State.MainState = "TRIAL_ACTIVE"
    elseif State.trialAvailable then
        State.MainState = "TRIAL_AVAILABLE"
    else
        State.MainState = "IDLE"
    end

    -- Update OrbState
    Detection.updateOrbStateAfterChange()
end

--- Full state reset: zeroes counters, clears transient state, re-snapshots.
function Detection.resetState()
    if State.HubClosed then return end

    Logger.log("[SYSTEM] State reset requested", "system")

    -- Zero counters
    State.TrialsDetected = 0
    State.TrialsEntered = 0
    State.TrialsFinished = 0
    State.OrbsDetected = 0
    State.OrbsCollected = 0
    State.OrbsRemoved = 0
    State.OrbsLikelyExpired = 0

    -- Clear info
    State.LastEvent = ""
    State.LastAction = ""
    State.LastError = ""

    -- Clear transient
    State._trialEntryProcessed = false
    State._trialEndProcessed = false
    State._hadConfirmedTimeTrial = false
    State._pendingRecoveryLog = false
    State._actionCooldowns = {
        ENTER_TRIAL = 0,
        FARM_TRIAL = 0,
        COLLECT_ORB = 0,
        RETURN_TO_SAFE = 0,
        ORB_RECOVERY_STAGE = 0,
        FAILSAFE_RETURN = 0,
    }
    -- NOTE: SafeReturnPosition and OrbRecoveryPosition are NOT cleared on reset (per spec)

    -- Cancel current action
    if State.CurrentAction.name ~= "NONE" then
        ActionController.CancelCurrent("state_reset")
    end

    -- Clean up observed orbs (but keep listeners alive)
    for inst, info in pairs(State.ObservedSpawnItems) do
        Detection.cleanupOrbInfo(info)
    end
    State.ObservedSpawnItems = {}

    -- Reset states
    State.trialAvailable = false
    State.trialActive = false
    State.trialModeName = ""
    State.MainState = "IDLE"
    State.OrbState = "NONE"

    -- Re-snapshot
    if State.MonitorTrial then
        Detection.snapshotTrial()
    end
    if State.MonitorOrb then
        Detection.snapshotOrbs()
    end

    Logger.log("[SYSTEM] State reset complete", "system")
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 13: GUI CONSTRUCTION
-- ════════════════════════════════════════════════════════════════

local COLORS = {
    bg         = Color3.fromRGB(18, 18, 28),
    panel      = Color3.fromRGB(28, 28, 42),
    panelLight = Color3.fromRGB(36, 36, 54),
    border     = Color3.fromRGB(50, 50, 72),
    titleBar   = Color3.fromRGB(30, 30, 50),
    text       = Color3.fromRGB(210, 210, 225),
    textDim    = Color3.fromRGB(130, 130, 155),
    green      = Color3.fromRGB(65, 190, 110),
    red        = Color3.fromRGB(210, 65, 65),
    blue       = Color3.fromRGB(85, 145, 240),
    gold       = Color3.fromRGB(235, 180, 50),
    btnBg      = Color3.fromRGB(42, 42, 65),
    btnHover   = Color3.fromRGB(55, 55, 80),
    closeRed   = Color3.fromRGB(170, 45, 45),
    toggleOn   = Color3.fromRGB(45, 145, 85),
    toggleOff  = Color3.fromRGB(55, 55, 75),
}

local WINDOW_WIDTH = 310
local WINDOW_HEIGHT = 590
local TITLE_HEIGHT = 26

-- GUI element references for updates
local GuiRefs = {}

function GuiModule.build()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "AnimeBreakersHUB"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.DisplayOrder = 999

    -- Main Frame
    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "MainFrame"
    mainFrame.Size = UDim2.new(0, WINDOW_WIDTH, 0, WINDOW_HEIGHT)
    mainFrame.Position = UDim2.new(0, 20, 0, 120)
    mainFrame.BackgroundColor3 = COLORS.bg
    mainFrame.BorderSizePixel = 0
    mainFrame.Parent = screenGui
    GuiRefs.MainFrame = mainFrame

    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0, 8)
    mainCorner.Parent = mainFrame

    local mainStroke = Instance.new("UIStroke")
    mainStroke.Color = COLORS.border
    mainStroke.Thickness = 1
    mainStroke.Parent = mainFrame

    -- ─── TITLE BAR ─────────────────────────────
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT)
    titleBar.BackgroundColor3 = COLORS.titleBar
    titleBar.BorderSizePixel = 0
    titleBar.Parent = mainFrame

    local tbCorner = Instance.new("UICorner")
    tbCorner.CornerRadius = UDim.new(0, 8)
    tbCorner.Parent = titleBar

    -- Fill bottom corners of title bar
    local tbFill = Instance.new("Frame")
    tbFill.Size = UDim2.new(1, 0, 0, 8)
    tbFill.Position = UDim2.new(0, 0, 1, -8)
    tbFill.BackgroundColor3 = COLORS.titleBar
    tbFill.BorderSizePixel = 0
    tbFill.Parent = titleBar

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -60, 1, 0)
    titleLabel.Position = UDim2.new(0, 10, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 12
    titleLabel.TextColor3 = COLORS.text
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Text = "ANIME BREAKERS HUB"
    titleLabel.Parent = titleBar

    -- Minimize button
    local minimizeBtn = Instance.new("TextButton")
    minimizeBtn.Name = "MinimizeBtn"
    minimizeBtn.Size = UDim2.new(0, 24, 0, 20)
    minimizeBtn.Position = UDim2.new(1, -52, 0, 3)
    minimizeBtn.BackgroundColor3 = COLORS.btnBg
    minimizeBtn.BorderSizePixel = 0
    minimizeBtn.Font = Enum.Font.GothamBold
    minimizeBtn.TextSize = 14
    minimizeBtn.TextColor3 = COLORS.textDim
    minimizeBtn.Text = "—"
    minimizeBtn.Parent = titleBar
    Instance.new("UICorner", minimizeBtn).CornerRadius = UDim.new(0, 4)

    -- Close button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseBtn"
    closeBtn.Size = UDim2.new(0, 24, 0, 20)
    closeBtn.Position = UDim2.new(1, -26, 0, 3)
    closeBtn.BackgroundColor3 = COLORS.closeRed
    closeBtn.BorderSizePixel = 0
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 12
    closeBtn.TextColor3 = COLORS.text
    closeBtn.Text = "X"
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

    -- ─── CONTENT FRAME ────────────────────────────
    local contentFrame = Instance.new("Frame")
    contentFrame.Name = "Content"
    contentFrame.Size = UDim2.new(1, -8, 1, -(TITLE_HEIGHT + 8))
    contentFrame.Position = UDim2.new(0, 4, 0, TITLE_HEIGHT + 4)
    contentFrame.BackgroundTransparency = 1
    contentFrame.ClipsDescendants = true
    contentFrame.Parent = mainFrame
    GuiRefs.ContentFrame = contentFrame

    local contentLayout = Instance.new("UIListLayout")
    contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    contentLayout.Padding = UDim.new(0, 3)
    contentLayout.Parent = contentFrame

    -- ─── STATUS PANEL ──────────────────────────────
    local statusPanel = GuiModule._createPanel(contentFrame, "StatusPanel", 68, 1)

    local function createStatusRow(parent, y, leftLabel, rightLabel)
        local leftKey = Instance.new("TextLabel")
        leftKey.Size = UDim2.new(0.5, -2, 0, 14)
        leftKey.Position = UDim2.new(0, 4, 0, y)
        leftKey.BackgroundTransparency = 1
        leftKey.Font = Enum.Font.RobotoMono
        leftKey.TextSize = 11
        leftKey.TextColor3 = COLORS.textDim
        leftKey.TextXAlignment = Enum.TextXAlignment.Left
        leftKey.Text = leftLabel
        leftKey.Parent = parent

        local leftVal = Instance.new("TextLabel")
        leftVal.Name = leftLabel:gsub("[%s:]", "") .. "Val"
        leftVal.Size = UDim2.new(0.5, -2, 0, 14)
        leftVal.Position = UDim2.new(0, 4, 0, y)
        leftVal.BackgroundTransparency = 1
        leftVal.Font = Enum.Font.RobotoMono
        leftVal.TextSize = 11
        leftVal.TextColor3 = COLORS.text
        leftVal.TextXAlignment = Enum.TextXAlignment.Right
        leftVal.Text = "--"
        leftVal.Parent = parent

        local rightKey = Instance.new("TextLabel")
        rightKey.Size = UDim2.new(0.5, -2, 0, 14)
        rightKey.Position = UDim2.new(0.5, 2, 0, y)
        rightKey.BackgroundTransparency = 1
        rightKey.Font = Enum.Font.RobotoMono
        rightKey.TextSize = 11
        rightKey.TextColor3 = COLORS.textDim
        rightKey.TextXAlignment = Enum.TextXAlignment.Left
        rightKey.Text = rightLabel
        rightKey.Parent = parent

        local rightVal = Instance.new("TextLabel")
        rightVal.Name = rightLabel:gsub("[%s:]", "") .. "Val"
        rightVal.Size = UDim2.new(0.5, -2, 0, 14)
        rightVal.Position = UDim2.new(0.5, 2, 0, y)
        rightVal.BackgroundTransparency = 1
        rightVal.Font = Enum.Font.RobotoMono
        rightVal.TextSize = 11
        rightVal.TextColor3 = COLORS.text
        rightVal.TextXAlignment = Enum.TextXAlignment.Right
        rightVal.Text = "--"
        rightVal.Parent = parent

        return leftVal, rightVal
    end

    GuiRefs.MainStateVal, GuiRefs.ActionVal = createStatusRow(statusPanel, 2, "Main:", "Action:")
    GuiRefs.TrialVal, GuiRefs.OrbStateVal = createStatusRow(statusPanel, 18, "Trial:", "Orb:")
    GuiRefs.ModeVal, GuiRefs.OrbTimerVal = createStatusRow(statusPanel, 34, "Mode:", "Timer:")
    GuiRefs.OrbPosVal, GuiRefs.OrbIdVal = createStatusRow(statusPanel, 50, "OrbPos:", "OrbID:")

    -- ─── TOGGLES PANEL ─────────────────────────────
    local togglesPanel = GuiModule._createPanel(contentFrame, "TogglesPanel", 126, 2)

    -- Header row
    local monHeader = Instance.new("TextLabel")
    monHeader.Size = UDim2.new(0.5, -2, 0, 14)
    monHeader.Position = UDim2.new(0, 4, 0, 2)
    monHeader.BackgroundTransparency = 1
    monHeader.Font = Enum.Font.GothamBold
    monHeader.TextSize = 10
    monHeader.TextColor3 = COLORS.textDim
    monHeader.TextXAlignment = Enum.TextXAlignment.Left
    monHeader.Text = "MONITORS"
    monHeader.Parent = togglesPanel

    local autoHeader = Instance.new("TextLabel")
    autoHeader.Size = UDim2.new(0.5, -2, 0, 14)
    autoHeader.Position = UDim2.new(0.5, 2, 0, 2)
    autoHeader.BackgroundTransparency = 1
    autoHeader.Font = Enum.Font.GothamBold
    autoHeader.TextSize = 10
    autoHeader.TextColor3 = COLORS.textDim
    autoHeader.TextXAlignment = Enum.TextXAlignment.Left
    autoHeader.Text = "AUTOMATION"
    autoHeader.Parent = togglesPanel

    local function createToggle(parent, x, y, w, text, initial, callback)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, w, 0, 18)
        btn.Position = UDim2.new(0, x, 0, y)
        btn.BackgroundColor3 = initial and COLORS.toggleOn or COLORS.toggleOff
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamMedium
        btn.TextSize = 10
        btn.TextColor3 = COLORS.text
        btn.Text = (initial and "● " or "○ ") .. text
        btn.Parent = parent
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

        local isOn = initial
        btn.MouseButton1Click:Connect(function()
            isOn = not isOn
            btn.BackgroundColor3 = isOn and COLORS.toggleOn or COLORS.toggleOff
            btn.Text = (isOn and "● " or "○ ") .. text
            callback(isOn)
        end)

        return btn, function(state)
            isOn = state
            btn.BackgroundColor3 = isOn and COLORS.toggleOn or COLORS.toggleOff
            btn.Text = (isOn and "● " or "○ ") .. text
        end
    end

    local halfW = math.floor((WINDOW_WIDTH - 16) / 2) - 4

    GuiRefs.TogMonTrial, GuiRefs.SetMonTrial = createToggle(togglesPanel, 4, 18, halfW, "Mon Trial", State.MonitorTrial, function(on)
        State.MonitorTrial = on
        if on then
            Logger.log("[SYSTEM] Monitor Trial ON — snapshotting", "system")
            Detection.snapshotTrial()
            Detection.recoverTrialWorkerIfNeeded()
            Arbiter.evaluate()
        else
            Logger.log("[SYSTEM] Monitor Trial OFF", "system")
        end
    end)

    GuiRefs.TogMonOrb, GuiRefs.SetMonOrb = createToggle(togglesPanel, 4, 38, halfW, "Mon Orb", State.MonitorOrb, function(on)
        State.MonitorOrb = on
        if on then
            Logger.log("[SYSTEM] Monitor Orb ON — snapshotting", "system")
            Detection.snapshotOrbs()
            Detection.updateOrbStateAfterChange()
        else
            Logger.log("[SYSTEM] Monitor Orb OFF", "system")
        end
    end)

    -- Filler for monitor column rows 3-4 (empty)

    GuiRefs.TogAutoMaster, GuiRefs.SetAutoMaster = createToggle(togglesPanel, halfW + 10, 18, halfW, "Master", State.AutomationMaster, function(on)
        State.AutomationMaster = on
        Logger.log("[SYSTEM] Automation Master " .. (on and "ON" or "OFF"), "system")
        if on then 
            if State.MonitorTrial then Detection.snapshotTrial() end
            Detection.recoverTrialWorkerIfNeeded()
            Arbiter.evaluate() 
        else
            State._pendingRecoveryLog = false
            if State.CurrentAction.name == "FARM_TRIAL" then
                ActionController.CancelCurrent("automation_master_off")
            end
        end
    end)

    GuiRefs.TogAutoJoin, GuiRefs.SetAutoJoin = createToggle(togglesPanel, halfW + 10, 38, halfW, "Auto Join", State.AutoJoinTrial, function(on)
        State.AutoJoinTrial = on
        Logger.log("[SYSTEM] Auto Join Trial " .. (on and "ON" or "OFF"), "system")
        if on then Arbiter.evaluate() end
    end)

    GuiRefs.TogAutoTrial, GuiRefs.SetAutoTrial = createToggle(togglesPanel, halfW + 10, 58, halfW, "Auto Trial", State.AutoTrial, function(on)
        State.AutoTrial = on
        Logger.log("[SYSTEM] Auto Trial " .. (on and "ON" or "OFF"), "system")
        if on then 
            if State.MonitorTrial then Detection.snapshotTrial() end
            Detection.recoverTrialWorkerIfNeeded()
            Arbiter.evaluate() 
        else
            State._pendingRecoveryLog = false
            if State.CurrentAction.name == "FARM_TRIAL" then
                ActionController.CancelCurrent("auto_trial_off")
            end
        end
    end)

    GuiRefs.TogAutoOrb, GuiRefs.SetAutoOrb = createToggle(togglesPanel, halfW + 10, 78, halfW, "Auto Orb", State.AutoOrb, function(on)
        State.AutoOrb = on
        Logger.log("[SYSTEM] Auto Orb " .. (on and "ON" or "OFF"), "system")
        if on then Arbiter.evaluate() end
    end)

    -- Return After Orb toggle (left column row 3)
    GuiRefs.TogReturnOrb, GuiRefs.SetReturnOrb = createToggle(togglesPanel, 4, 58, halfW, "Ret Orb", State.ReturnAfterOrb, function(on)
        State.ReturnAfterOrb = on
        Logger.log("[SYSTEM] Return After Orb " .. (on and "ON" or "OFF"), "system")
    end)

    -- Fixed Position display (left column row 4)
    GuiRefs.FixedPosLabel = Instance.new("TextLabel")
    GuiRefs.FixedPosLabel.Size = UDim2.new(0, halfW, 0, 18)
    GuiRefs.FixedPosLabel.Position = UDim2.new(0, 4, 0, 78)
    GuiRefs.FixedPosLabel.BackgroundTransparency = 1
    GuiRefs.FixedPosLabel.Font = Enum.Font.RobotoMono
    GuiRefs.FixedPosLabel.TextSize = 9
    GuiRefs.FixedPosLabel.TextColor3 = COLORS.textDim
    GuiRefs.FixedPosLabel.TextXAlignment = Enum.TextXAlignment.Left
    GuiRefs.FixedPosLabel.Text = State.SafeReturnPosition and "FixPos: SET" or "FixPos: NOT SET"
    GuiRefs.FixedPosLabel.Parent = togglesPanel

    -- Orb Recovery Position display (left column row 5)
    GuiRefs.OrbRecLabel = Instance.new("TextLabel")
    GuiRefs.OrbRecLabel.Size = UDim2.new(0, halfW, 0, 18)
    GuiRefs.OrbRecLabel.Position = UDim2.new(0, 4, 0, 98)
    GuiRefs.OrbRecLabel.BackgroundTransparency = 1
    GuiRefs.OrbRecLabel.Font = Enum.Font.RobotoMono
    GuiRefs.OrbRecLabel.TextSize = 9
    GuiRefs.OrbRecLabel.TextColor3 = COLORS.textDim
    GuiRefs.OrbRecLabel.TextXAlignment = Enum.TextXAlignment.Left
    GuiRefs.OrbRecLabel.Text = State.OrbRecoveryPosition and "OrbRec: SET" or "OrbRec: NOT SET"
    GuiRefs.OrbRecLabel.Parent = togglesPanel

    -- ─── COUNTERS PANEL ────────────────────────────
    local countersPanel = GuiModule._createPanel(contentFrame, "CountersPanel", 36, 3)

    local trialCntLabel = Instance.new("TextLabel")
    trialCntLabel.Size = UDim2.new(0.5, -2, 0, 14)
    trialCntLabel.Position = UDim2.new(0, 4, 0, 2)
    trialCntLabel.BackgroundTransparency = 1
    trialCntLabel.Font = Enum.Font.RobotoMono
    trialCntLabel.TextSize = 10
    trialCntLabel.TextColor3 = COLORS.textDim
    trialCntLabel.TextXAlignment = Enum.TextXAlignment.Left
    trialCntLabel.Text = "Trials D/E/F:"
    trialCntLabel.Parent = countersPanel

    GuiRefs.TrialCounters = Instance.new("TextLabel")
    GuiRefs.TrialCounters.Size = UDim2.new(0.5, -2, 0, 14)
    GuiRefs.TrialCounters.Position = UDim2.new(0, 4, 0, 2)
    GuiRefs.TrialCounters.BackgroundTransparency = 1
    GuiRefs.TrialCounters.Font = Enum.Font.RobotoMono
    GuiRefs.TrialCounters.TextSize = 10
    GuiRefs.TrialCounters.TextColor3 = COLORS.text
    GuiRefs.TrialCounters.TextXAlignment = Enum.TextXAlignment.Right
    GuiRefs.TrialCounters.Text = "0/0/0"
    GuiRefs.TrialCounters.Parent = countersPanel

    local orbCntLabel = Instance.new("TextLabel")
    orbCntLabel.Size = UDim2.new(0.5, -2, 0, 14)
    orbCntLabel.Position = UDim2.new(0.5, 2, 0, 2)
    orbCntLabel.BackgroundTransparency = 1
    orbCntLabel.Font = Enum.Font.RobotoMono
    orbCntLabel.TextSize = 10
    orbCntLabel.TextColor3 = COLORS.textDim
    orbCntLabel.TextXAlignment = Enum.TextXAlignment.Left
    orbCntLabel.Text = "Orbs D/C/R/X:"
    orbCntLabel.Parent = countersPanel

    GuiRefs.OrbCounters = Instance.new("TextLabel")
    GuiRefs.OrbCounters.Size = UDim2.new(0.5, -2, 0, 14)
    GuiRefs.OrbCounters.Position = UDim2.new(0.5, 2, 0, 2)
    GuiRefs.OrbCounters.BackgroundTransparency = 1
    GuiRefs.OrbCounters.Font = Enum.Font.RobotoMono
    GuiRefs.OrbCounters.TextSize = 10
    GuiRefs.OrbCounters.TextColor3 = COLORS.text
    GuiRefs.OrbCounters.TextXAlignment = Enum.TextXAlignment.Right
    GuiRefs.OrbCounters.Text = "0/0/0/0"
    GuiRefs.OrbCounters.Parent = countersPanel

    -- Second row for counters
    local trialCntLabel2 = Instance.new("TextLabel")
    trialCntLabel2.Size = UDim2.new(1, -8, 0, 14)
    trialCntLabel2.Position = UDim2.new(0, 4, 0, 18)
    trialCntLabel2.BackgroundTransparency = 1
    trialCntLabel2.Font = Enum.Font.RobotoMono
    trialCntLabel2.TextSize = 9
    trialCntLabel2.TextColor3 = COLORS.textDim
    trialCntLabel2.TextXAlignment = Enum.TextXAlignment.Left
    trialCntLabel2.Text = "(D=detected E=entered F=finished) (D=detected C=collected R=removed X=expired)"
    trialCntLabel2.TextWrapped = true
    trialCntLabel2.Parent = countersPanel

    -- ─── INFO PANEL ────────────────────────────────
    local infoPanel = GuiModule._createPanel(contentFrame, "InfoPanel", 34, 4)

    local lastEvtKey = Instance.new("TextLabel")
    lastEvtKey.Size = UDim2.new(0, 38, 0, 14)
    lastEvtKey.Position = UDim2.new(0, 4, 0, 2)
    lastEvtKey.BackgroundTransparency = 1
    lastEvtKey.Font = Enum.Font.RobotoMono
    lastEvtKey.TextSize = 10
    lastEvtKey.TextColor3 = COLORS.textDim
    lastEvtKey.TextXAlignment = Enum.TextXAlignment.Left
    lastEvtKey.Text = "Last:"
    lastEvtKey.Parent = infoPanel

    GuiRefs.LastEventVal = Instance.new("TextLabel")
    GuiRefs.LastEventVal.Size = UDim2.new(1, -48, 0, 14)
    GuiRefs.LastEventVal.Position = UDim2.new(0, 42, 0, 2)
    GuiRefs.LastEventVal.BackgroundTransparency = 1
    GuiRefs.LastEventVal.Font = Enum.Font.RobotoMono
    GuiRefs.LastEventVal.TextSize = 10
    GuiRefs.LastEventVal.TextColor3 = COLORS.text
    GuiRefs.LastEventVal.TextXAlignment = Enum.TextXAlignment.Left
    GuiRefs.LastEventVal.TextTruncate = Enum.TextTruncate.AtEnd
    GuiRefs.LastEventVal.Text = "--"
    GuiRefs.LastEventVal.Parent = infoPanel

    local lastErrKey = Instance.new("TextLabel")
    lastErrKey.Size = UDim2.new(0, 38, 0, 14)
    lastErrKey.Position = UDim2.new(0, 4, 0, 18)
    lastErrKey.BackgroundTransparency = 1
    lastErrKey.Font = Enum.Font.RobotoMono
    lastErrKey.TextSize = 10
    lastErrKey.TextColor3 = COLORS.textDim
    lastErrKey.TextXAlignment = Enum.TextXAlignment.Left
    lastErrKey.Text = "Err:"
    lastErrKey.Parent = infoPanel

    GuiRefs.LastErrorVal = Instance.new("TextLabel")
    GuiRefs.LastErrorVal.Size = UDim2.new(1, -48, 0, 14)
    GuiRefs.LastErrorVal.Position = UDim2.new(0, 42, 0, 18)
    GuiRefs.LastErrorVal.BackgroundTransparency = 1
    GuiRefs.LastErrorVal.Font = Enum.Font.RobotoMono
    GuiRefs.LastErrorVal.TextSize = 10
    GuiRefs.LastErrorVal.TextColor3 = COLORS.red
    GuiRefs.LastErrorVal.TextXAlignment = Enum.TextXAlignment.Left
    GuiRefs.LastErrorVal.TextTruncate = Enum.TextTruncate.AtEnd
    GuiRefs.LastErrorVal.Text = "--"
    GuiRefs.LastErrorVal.Parent = infoPanel

    -- ─── LOG PANEL ─────────────────────────────────
    local logPanel = GuiModule._createPanel(contentFrame, "LogPanel", 140, 5)

    local logHeader = Instance.new("TextLabel")
    logHeader.Size = UDim2.new(1, -8, 0, 14)
    logHeader.Position = UDim2.new(0, 4, 0, 1)
    logHeader.BackgroundTransparency = 1
    logHeader.Font = Enum.Font.GothamBold
    logHeader.TextSize = 10
    logHeader.TextColor3 = COLORS.textDim
    logHeader.TextXAlignment = Enum.TextXAlignment.Left
    logHeader.Text = "LOG"
    logHeader.Parent = logPanel

    local logScroll = Instance.new("ScrollingFrame")
    logScroll.Name = "LogScroll"
    logScroll.Size = UDim2.new(1, -8, 1, -18)
    logScroll.Position = UDim2.new(0, 4, 0, 16)
    logScroll.BackgroundColor3 = COLORS.bg
    logScroll.BorderSizePixel = 0
    logScroll.ScrollBarThickness = 4
    logScroll.ScrollBarImageColor3 = COLORS.border
    logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    logScroll.Parent = logPanel
    Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 4)

    local logLayout = Instance.new("UIListLayout")
    logLayout.SortOrder = Enum.SortOrder.LayoutOrder
    logLayout.Padding = UDim.new(0, 1)
    logLayout.Parent = logScroll

    _logGui = logScroll
    _logLayout = logLayout

    -- ─── BUTTONS PANEL ─────────────────────────────
    local buttonsPanel = GuiModule._createPanel(contentFrame, "ButtonsPanel", 82, 6)
    buttonsPanel.BackgroundTransparency = 1

    local btnWidth = math.floor((WINDOW_WIDTH - 20) / 2)

    local resetBtn = Instance.new("TextButton")
    resetBtn.Size = UDim2.new(0, btnWidth, 0, 22)
    resetBtn.Position = UDim2.new(0, 2, 0, 3)
    resetBtn.BackgroundColor3 = COLORS.btnBg
    resetBtn.BorderSizePixel = 0
    resetBtn.Font = Enum.Font.GothamMedium
    resetBtn.TextSize = 10
    resetBtn.TextColor3 = COLORS.text
    resetBtn.Text = "Reset State"
    resetBtn.Parent = buttonsPanel
    Instance.new("UICorner", resetBtn).CornerRadius = UDim.new(0, 4)

    local clearBtn = Instance.new("TextButton")
    clearBtn.Size = UDim2.new(0, btnWidth, 0, 22)
    clearBtn.Position = UDim2.new(0, btnWidth + 6, 0, 3)
    clearBtn.BackgroundColor3 = COLORS.btnBg
    clearBtn.BorderSizePixel = 0
    clearBtn.Font = Enum.Font.GothamMedium
    clearBtn.TextSize = 10
    clearBtn.TextColor3 = COLORS.text
    clearBtn.Text = "Clear Log"
    clearBtn.Parent = buttonsPanel
    Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 4)

    -- Fix Position button
    local fixPosBtn = Instance.new("TextButton")
    fixPosBtn.Size = UDim2.new(0, btnWidth, 0, 22)
    fixPosBtn.Position = UDim2.new(0, 2, 0, 28)
    fixPosBtn.BackgroundColor3 = COLORS.toggleOn
    fixPosBtn.BorderSizePixel = 0
    fixPosBtn.Font = Enum.Font.GothamMedium
    fixPosBtn.TextSize = 10
    fixPosBtn.TextColor3 = COLORS.text
    fixPosBtn.Text = "Fix Position"
    fixPosBtn.Parent = buttonsPanel
    Instance.new("UICorner", fixPosBtn).CornerRadius = UDim.new(0, 4)

    -- Clear Fixed Position button
    local clearPosBtn = Instance.new("TextButton")
    clearPosBtn.Size = UDim2.new(0, btnWidth, 0, 22)
    clearPosBtn.Position = UDim2.new(0, btnWidth + 6, 0, 28)
    clearPosBtn.BackgroundColor3 = COLORS.btnBg
    clearPosBtn.BorderSizePixel = 0
    clearPosBtn.Font = Enum.Font.GothamMedium
    clearPosBtn.TextSize = 10
    clearPosBtn.TextColor3 = COLORS.text
    clearPosBtn.Text = "Clear FixPos"
    clearPosBtn.Parent = buttonsPanel
    Instance.new("UICorner", clearPosBtn).CornerRadius = UDim.new(0, 4)

    -- Fix OrbRec button
    local fixOrbRecBtn = Instance.new("TextButton")
    fixOrbRecBtn.Size = UDim2.new(0, btnWidth, 0, 22)
    fixOrbRecBtn.Position = UDim2.new(0, 2, 0, 53)
    fixOrbRecBtn.BackgroundColor3 = COLORS.toggleOn
    fixOrbRecBtn.BorderSizePixel = 0
    fixOrbRecBtn.Font = Enum.Font.GothamMedium
    fixOrbRecBtn.TextSize = 10
    fixOrbRecBtn.TextColor3 = COLORS.text
    fixOrbRecBtn.Text = "Fix OrbRec"
    fixOrbRecBtn.Parent = buttonsPanel
    Instance.new("UICorner", fixOrbRecBtn).CornerRadius = UDim.new(0, 4)

    -- Clear OrbRec button
    local clearOrbRecBtn = Instance.new("TextButton")
    clearOrbRecBtn.Size = UDim2.new(0, btnWidth, 0, 22)
    clearOrbRecBtn.Position = UDim2.new(0, btnWidth + 6, 0, 53)
    clearOrbRecBtn.BackgroundColor3 = COLORS.btnBg
    clearOrbRecBtn.BorderSizePixel = 0
    clearOrbRecBtn.Font = Enum.Font.GothamMedium
    clearOrbRecBtn.TextSize = 10
    clearOrbRecBtn.TextColor3 = COLORS.text
    clearOrbRecBtn.Text = "Clear OrbRec"
    clearOrbRecBtn.Parent = buttonsPanel
    Instance.new("UICorner", clearOrbRecBtn).CornerRadius = UDim.new(0, 4)

    -- ─── DRAGGING ──────────────────────────────────
    local dragging = false
    local dragStart = Vector3.new()
    local startPos = UDim2.new()
    local dragInput = nil

    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = mainFrame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    titleBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    connect(UserInputService.InputChanged, function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            mainFrame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end, "gui")

    -- ─── MINIMIZE ──────────────────────────────────
    local minimized = false
    minimizeBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        contentFrame.Visible = not minimized
        if minimized then
            mainFrame.Size = UDim2.new(0, WINDOW_WIDTH, 0, TITLE_HEIGHT)
            minimizeBtn.Text = "+"
        else
            mainFrame.Size = UDim2.new(0, WINDOW_WIDTH, 0, WINDOW_HEIGHT)
            minimizeBtn.Text = "—"
        end
    end)

    -- ─── CLOSE ─────────────────────────────────────
    closeBtn.MouseButton1Click:Connect(function()
        GuiModule.close()
    end)

    -- ─── RESET STATE ───────────────────────────────
    resetBtn.MouseButton1Click:Connect(function()
        Detection.resetState()
    end)

    -- ─── CLEAR LOG ─────────────────────────────────
    clearBtn.MouseButton1Click:Connect(function()
        Logger.clear()
    end)

    -- ─── FIX POSITION ──────────────────────────────
    fixPosBtn.MouseButton1Click:Connect(function()
        local character = LocalPlayer.Character
        if character then
            local hrp = character:FindFirstChild("HumanoidRootPart")
            if hrp then
                State.SafeReturnPosition = hrp.CFrame
                local pos = hrp.Position
                Logger.log(string.format("[POSITION] Safe Position fixed: %.0f, %.0f, %.0f",
                    pos.X, pos.Y, pos.Z), "action")
                if GuiRefs.FixedPosLabel then
                    GuiRefs.FixedPosLabel.Text = string.format("FixPos: %.0f,%.0f,%.0f",
                        pos.X, pos.Y, pos.Z)
                    GuiRefs.FixedPosLabel.TextColor3 = COLORS.green
                end
            else
                Logger.log("[POSITION] Cannot fix: no HumanoidRootPart", "warn")
            end
        else
            Logger.log("[POSITION] Cannot fix: no character", "warn")
        end
    end)

    -- ─── CLEAR FIXED POSITION ──────────────────────
    clearPosBtn.MouseButton1Click:Connect(function()
        State.SafeReturnPosition = nil
        Logger.log("[POSITION] Safe Position cleared", "action")
        if GuiRefs.FixedPosLabel then
            GuiRefs.FixedPosLabel.Text = "FixPos: NOT SET"
            GuiRefs.FixedPosLabel.TextColor3 = COLORS.textDim
        end
    end)

    -- ─── FIX ORBREC ──────────────────────────────
    fixOrbRecBtn.MouseButton1Click:Connect(function()
        local character = LocalPlayer.Character
        if character then
            local hrp = character:FindFirstChild("HumanoidRootPart")
            if hrp then
                State.OrbRecoveryPosition = hrp.CFrame
                local pos = hrp.Position
                Logger.log(string.format("[POSITION] Orb Recovery Position fixed: %.0f, %.0f, %.0f",
                    pos.X, pos.Y, pos.Z), "action")
                if GuiRefs.OrbRecLabel then
                    GuiRefs.OrbRecLabel.Text = string.format("OrbRec: %.0f,%.0f,%.0f",
                        pos.X, pos.Y, pos.Z)
                    GuiRefs.OrbRecLabel.TextColor3 = COLORS.green
                end
            else
                Logger.log("[POSITION] Cannot fix OrbRec: no HumanoidRootPart", "warn")
            end
        else
            Logger.log("[POSITION] Cannot fix OrbRec: no character", "warn")
        end
    end)

    -- ─── CLEAR ORBREC ──────────────────────
    clearOrbRecBtn.MouseButton1Click:Connect(function()
        State.OrbRecoveryPosition = nil
        Logger.log("[POSITION] Orb Recovery Position cleared", "action")
        if GuiRefs.OrbRecLabel then
            GuiRefs.OrbRecLabel.Text = "OrbRec: NOT SET"
            GuiRefs.OrbRecLabel.TextColor3 = COLORS.textDim
        end
    end)

    -- Parent to PlayerGui
    local pg = resolvePlayerGui()
    if pg then
        screenGui.Parent = pg
    else
        screenGui.Parent = game:GetService("CoreGui")
    end

    GuiRefs.ScreenGui = screenGui

    -- Flush buffered log entries
    Logger._flushBuffer()

    return screenGui
end

function GuiModule._createPanel(parent, name, height, order)
    local panel = Instance.new("Frame")
    panel.Name = name
    panel.Size = UDim2.new(1, 0, 0, height)
    panel.BackgroundColor3 = COLORS.panel
    panel.BorderSizePixel = 0
    panel.LayoutOrder = order
    panel.Parent = parent
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 5)
    return panel
end

-- ─── GUI UPDATE LOOP ──────────────────────────────
function GuiModule.updateLoop()
    if State.HubClosed then return end

    -- Update status labels
    if GuiRefs.MainStateVal then
        GuiRefs.MainStateVal.Text = State.MainState
        GuiRefs.MainStateVal.TextColor3 =
            (State.MainState == "TRIAL_ACTIVE" and COLORS.green)
            or (State.MainState == "TRIAL_AVAILABLE" and COLORS.blue)
            or (State.MainState == "TRIAL_ENTERING" and COLORS.gold)
            or (State.MainState == "TRIAL_ENDING" and COLORS.gold)
            or COLORS.text
    end

    if GuiRefs.ActionVal then
        GuiRefs.ActionVal.Text = State.CurrentAction.name
        GuiRefs.ActionVal.TextColor3 =
            (State.CurrentAction.name ~= "NONE" and COLORS.gold) or COLORS.textDim
    end

    if GuiRefs.TrialVal then
        local trialText = ""
        if State.trialActive then
            trialText = "ACTIVE"
        elseif State.trialAvailable then
            trialText = "OPEN"
        else
            trialText = "—"
        end
        GuiRefs.TrialVal.Text = trialText
        GuiRefs.TrialVal.TextColor3 =
            State.trialActive and COLORS.green
            or State.trialAvailable and COLORS.blue
            or COLORS.textDim
    end

    if GuiRefs.OrbStateVal then
        GuiRefs.OrbStateVal.Text = State.OrbState
        GuiRefs.OrbStateVal.TextColor3 =
            (State.OrbState == "AVAILABLE" and COLORS.gold)
            or (State.OrbState == "COLLECTED" and COLORS.green)
            or (State.OrbState == "PENDING" and COLORS.blue)
            or (State.OrbState == "COLLECT_ATTEMPT" and COLORS.gold)
            or (State.OrbState == "RECOVERY_PENDING" and COLORS.gold)
            or (State.OrbState == "RECOVERY_STAGING" and COLORS.blue)
            or (State.OrbState == "RECOVERY_READY" and COLORS.gold)
            or COLORS.textDim
    end

    if GuiRefs.ModeVal then
        GuiRefs.ModeVal.Text = (State.trialModeName ~= "" and State.trialModeName) or "—"
    end

    -- Orb info
    local activeOrb = Detection.getActiveOrb()
    if GuiRefs.OrbTimerVal then
        if activeOrb then
            local remaining = nil
            if activeOrb.expireAt then
                remaining = activeOrb.expireAt - getServerTime()
            else
                -- Fallback: try reading Gui.Label.Text
                if isInstanceValid(activeOrb.instance) then
                    local gui = activeOrb.instance:FindFirstChild("Gui")
                    if gui then
                        local label = gui:FindFirstChild("Label")
                        if label and label:IsA("TextLabel") then
                            local m, s = label.Text:match("(%d+):(%d+)")
                            if m and s then
                                remaining = tonumber(m) * 60 + tonumber(s)
                            end
                        end
                    end
                end
            end
            GuiRefs.OrbTimerVal.Text = remaining and formatTime(remaining) or "—"
            GuiRefs.OrbTimerVal.TextColor3 =
                (remaining and remaining <= 60 and COLORS.red)
                or (remaining and remaining <= 180 and COLORS.gold)
                or COLORS.text
        else
            GuiRefs.OrbTimerVal.Text = "—"
            GuiRefs.OrbTimerVal.TextColor3 = COLORS.textDim
        end
    end

    if GuiRefs.OrbPosVal then
        if activeOrb and activeOrb.position then
            local p = activeOrb.position
            GuiRefs.OrbPosVal.Text = string.format("%.0f,%.0f,%.0f", p.X, p.Y, p.Z)
        else
            GuiRefs.OrbPosVal.Text = "—"
        end
        GuiRefs.OrbPosVal.TextColor3 = activeOrb and COLORS.text or COLORS.textDim
    end

    if GuiRefs.OrbIdVal then
        if activeOrb then
            GuiRefs.OrbIdVal.Text = activeOrb.hash:sub(1, 8) .. ".."
        else
            GuiRefs.OrbIdVal.Text = "—"
        end
        GuiRefs.OrbIdVal.TextColor3 = activeOrb and COLORS.text or COLORS.textDim
    end

    -- Counters
    if GuiRefs.TrialCounters then
        GuiRefs.TrialCounters.Text = State.TrialsDetected
            .. "/" .. State.TrialsEntered
            .. "/" .. State.TrialsFinished
    end
    if GuiRefs.OrbCounters then
        GuiRefs.OrbCounters.Text = State.OrbsDetected
            .. "/" .. State.OrbsCollected
            .. "/" .. State.OrbsRemoved
            .. "/" .. State.OrbsLikelyExpired
    end

    -- Info
    if GuiRefs.LastEventVal then
        GuiRefs.LastEventVal.Text = (State.LastEvent ~= "" and State.LastEvent) or "--"
    end
    if GuiRefs.LastErrorVal then
        GuiRefs.LastErrorVal.Text = (State.LastError ~= "" and State.LastError) or "--"
    end

    -- Action timeout check
    ActionController.checkTimeout()

    -- Update orb positions for tracked items
    for inst, info in pairs(State.ObservedSpawnItems) do
        if not info.removed and not info.collected and isInstanceValid(inst) then
            if info.root and isInstanceValid(info.root) then
                local ok, pos = pcall(function() return info.root.Position end)
                if ok then info.position = pos end
            end
        end
    end
end

-- ─── CLOSE / CLEANUP ──────────────────────────────
function GuiModule.close()
    if State.HubClosed then return end
    State.HubClosed = true

    Logger.log("[SYSTEM] HUB closing...", "system")

    -- Cancel current action
    if State.CurrentAction.name ~= "NONE" then
        State.CurrentAction.cancelled = true
        StateMachine.clearCurrentAction("hub_closed")
    end

    -- Disconnect all connections
    disconnectAll()

    -- Clean up orb connections
    for inst, info in pairs(State.ObservedSpawnItems) do
        Detection.cleanupOrbInfo(info)
    end
    State.ObservedSpawnItems = {}

    -- Invalidate pending tasks
    State._pendingTasks = {}

    -- Destroy GUI
    if GuiRefs.ScreenGui then
        pcall(function() GuiRefs.ScreenGui:Destroy() end)
        GuiRefs.ScreenGui = nil
    end

    -- Clear anti-double flag
    getgenv().__ANIME_BREAKERS_FINAL_HUB = nil

    -- Clear references
    _logGui = nil
    _logLayout = nil
    GuiRefs = {}
    Refs = {
        PlayerGui = nil,
        Invite = nil,
        Gamemode = nil,
        SpawnItems = nil,
        EnemiesGamemode = nil,
        Character = nil,
        HumanoidRootPart = nil,
    }
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 14: INITIALIZATION
-- ════════════════════════════════════════════════════════════════

local function initialize()
    Logger.log("[SYSTEM] Initializing Anime Breakers HUB...", "system")

    -- 1. Resolve PlayerGui
    resolvePlayerGui()

    -- 2. Build GUI (this also flushes the log buffer)
    GuiModule.build()

    -- 3. Resolve references
    resolveInvite()
    resolveGamemodeGui()
    resolveSpawnItems()
    resolveEnemiesGamemode()
    resolveCharacter()

    Logger.log("[SYSTEM] References resolved", "system")
    Logger.log("[SYSTEM]   PlayerGui: " .. (Refs.PlayerGui and "OK" or "MISSING"), "system")
    Logger.log("[SYSTEM]   Invite: " .. (Refs.Invite and "OK" or "MISSING"), "system")
    Logger.log("[SYSTEM]   Gamemode GUI: " .. (Refs.Gamemode and "OK" or "MISSING"), "system")
    Logger.log("[SYSTEM]   _SPAWNITEMS: " .. (Refs.SpawnItems and "OK" or "MISSING"), "system")
    Logger.log("[SYSTEM]   _ENEMIES.Server.Gamemode: " .. (Refs.EnemiesGamemode and "OK" or "MISSING"), "system")
    Logger.log("[SYSTEM]   Character: " .. (Refs.Character and "OK" or "MISSING"), "system")

    -- 4. Bind detection listeners
    Detection.bindPlayerGui()
    Detection.bindGamemodeFolder()
    Detection.bindSpawnItems()
    Detection.bindCharacter()

    -- 5. Initial snapshots (#50)
    if State.MonitorTrial then
        Detection.snapshotTrial()
    end
    if State.MonitorOrb then
        Detection.snapshotOrbs()
        Detection.updateOrbStateAfterChange()
    end

    -- 6. Start GUI update loop (~1 Hz)
    task.spawn(function()
        while not State.HubClosed do
            local ok, err = pcall(function()
                GuiModule.updateLoop()
            end)
            if not ok then
                State.LastError = "GUI update error"
            end
            task.wait(Config.GuiUpdateInterval)
        end
    end)

    -- 7. Retry missing containers periodically
    task.spawn(function()
        while not State.HubClosed do
            task.wait(Config.ContainerResolveRetry)
            if State.HubClosed then break end

            -- Re-resolve missing refs without spamming logs
            if not Refs.SpawnItems or not isInstanceValid(Refs.SpawnItems) then
                local si = resolveSpawnItems()
                if si then
                    Detection.bindSpawnItems()
                    if State.MonitorOrb then
                        Detection.snapshotOrbs()
                        Detection.updateOrbStateAfterChange()
                    end
                end
            end

            if not Refs.EnemiesGamemode or not isInstanceValid(Refs.EnemiesGamemode) then
                local gm = resolveEnemiesGamemode()
                if gm then
                    Detection.bindGamemodeFolder()
                    if State.MonitorTrial then
                        Detection.snapshotTrial()
                    end
                end
            end

            if not Refs.PlayerGui or not isInstanceValid(Refs.PlayerGui) then
                local pg = resolvePlayerGui()
                if pg then
                    Detection.bindPlayerGui()
                    if State.MonitorTrial then
                        Detection.snapshotTrial()
                    end
                end
            end
        end
    end)

    Logger.log("[SYSTEM] HUB initialized — Main: " .. State.MainState .. " | Orb: " .. State.OrbState, "system")
    Logger.log("[SYSTEM] All systems active — Raid guard ON, lifecycle farm, distance-verified orb", "system")
end

-- Run initialization
initialize()

--[[
════════════════════════════════════════════════════════════════
ASSUMPTIONS / UNCONFIRMED
════════════════════════════════════════════════════════════════

=== ENVIRONMENT ===

1. getgenv() is assumed available (executor environment).
   If running in standard Roblox Studio, replace with _G or shared.

2. task.spawn, task.delay, task.defer, task.wait are assumed
   available (modern Roblox task library).

3. workspace:GetServerTimeNow() is assumed available.
   Fallback to tick() if it errors.

=== GAME STRUCTURE ===

4. The Time Trial child in _ENEMIES.Server.Gamemode was observed
   as "Time Trial_-1". Detection uses case-insensitive
   string.find("time trial"). Other naming variants are UNCONFIRMED.

5. ProximityPrompt.Triggered fires with the Player as first arg.
   Standard Roblox; confirmed for CommandmentFragment case only.

6. Multiple CommandmentFragments coexisting: supported but
   never observed in testing.

7. _SPAWNITEMS may contain non-orb objects with
   Type="CommandmentFragment": UNCONFIRMED. SpawnId check exists.

8. Invite can activate for non-Trial reasons: mitigated by
   text check for "time trial".

9. Gamemode.Enabled activates for Raids, Dungeons, and other
   modes besides Time Trial. The system now guards against this
   by requiring a real Time Trial container in _ENEMIES.Server.Gamemode.

10. ScrollingFrame.AutomaticCanvasSize is assumed supported.

11. Instance.Destroying event is assumed available.
    AncestryChanged is fallback.

12. Timer display fallback reads item > Gui > Label for
    "Despawns in MM:SS". GUI structure is UNCONFIRMED stable.

13. Character.HumanoidRootPart exists for LocalPlayer.
    Mobs may NOT follow this convention.

=== ADAPTER-SPECIFIC ===

14. firesignal() / fireproximityprompt() assumed available
    in the executor. Both adapters have fallback paths.
    In Roblox Studio, these adapters need mock/injection.

15. EnterTrial now searches for ANY GuiButton (TextButton +
    ImageButton). TextButton matched by keywords; ImageButton
    matched by green-ish BackgroundColor3 (G > 0.4, G > R*1.3)
    or Image asset name containing check/accept/confirm/yes.
    Fallback: first visible GuiButton. The exact UI layout
    (green check ImageButton, red X ImageButton) was observed
    but is UNCONFIRMED stable across all Invite variations.

16. FarmTrial is a lifecycle worker (timeout = math.huge).
    It does NOT timeout. Terminated only by:
    - Trial container destroyed
    - cancel token (trial ends, toggle off, hub closed)
    Enemy models are assumed direct children of the container.

17. FarmTrial teleports player to enemy (3-stud Z offset).
    No explicit attack — assumes proximity auto-attack.

18. CollectOrb verifies TARGET_REACHED after move by measuring
    distance (HRP to Root). Threshold: Config.OrbReachDistance
    (default 16 studs). Retries up to Config.OrbMoveMaxRetries
    (default 3). Interaction fires ONLY after TARGET_REACHED.

19. The CAUSE of long-distance move failure is UNCONFIRMED.
    Possible factors: streaming, region not loaded, server
    correction. The system measures and retries defensively
    without assuming the cause.

20. ReturnToSafePosition teleports to State.SafeReturnPosition.
    Only after confirmed COLLECTED + ReturnAfterOrb ON.
    SafeReturnPosition is set MANUALLY via Fix Position button.
    Never auto-saved.
]]
