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
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Workspace = game:GetService("Workspace")

-- Resolved references (may be nil initially)
local Refs = {
    PlayerGui = nil,
    Invite = nil,
    Gamemode = nil,
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
    },
    PostTrialDebounce      = 3,    -- seconds before revalidation after trial end
    TrialEntryTimeout      = 15,   -- seconds to wait for entry confirmation
    TrialEndTimeout        = 8,    -- seconds to wait for child removal after Gamemode off
    ActionRetryCooldown    = 8,    -- seconds before retrying a failed action
    MaxLogLines            = 150,
    GuiUpdateInterval      = 1,    -- seconds between GUI refreshes
    ContainerResolveRetry  = 5,    -- seconds between retries for missing containers
    FarmLoopInterval       = 0.1,  -- seconds between farm loop iterations
    AntiAfkInterval        = 600,  -- seconds: 10 minutes without input triggers keep-alive
    TrialNoTargetDiagnosticThreshold = 3.0, -- seconds: consecutive time without target before logging
}

-- ════════════════════════════════════════════════════════════════
-- SECTION 3: STATE STORE
-- ════════════════════════════════════════════════════════════════

local State = {
    -- Core states
    MainState = "IDLE",

    -- Central action lock
    CurrentAction = {
        name       = "NONE",
        startedAt  = 0,
        attemptId  = 0,
        timeout    = 0,
        cancelled  = false,
    },

    -- Toggles: Monitoring
    MonitorTrial = true,

    -- Toggles: Automation
    AutomationMaster = false,
    AutoJoinTrial    = false,
    AutoTrial        = false,
    AntiAfkEnabled   = true,

    -- Detection cache
    trialAvailable = false,
    trialActive    = false,
    trialModeName  = "",

    -- Counters
    TrialsDetected   = 0,
    TrialsEntered    = 0,
    TrialsFinished   = 0,

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

local function isInstanceValid(inst)
    if not inst then return false end
    local ok, parent = pcall(function() return inst.Parent end)
    return ok and parent ~= nil
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
-- SECTION 6.5: PERSISTENCE
-- ════════════════════════════════════════════════════════════════

local Persistence = {}
local FOLDER_NAME = "AnimeBreakersHub"

local _persErrLogged = {
    api = false,
    folder = false,
    write = false,
    read = false
}

function Persistence.getConfigPath()
    local lp = Players.LocalPlayer
    if not lp then return nil end
    
    local userId = lp.UserId
    if not userId or type(userId) ~= "number" then return nil end
    
    local userIdStr = tostring(userId)
    local path = FOLDER_NAME .. "/" .. userIdStr .. "/config.json"
    
    return path, userIdStr
end

function Persistence.save()
    pcall(function()
        if not writefile then
            if not _persErrLogged.api then
                Logger.log("[SYSTEM] Persistence API missing. Settings won't be saved.", "info")
                _persErrLogged.api = true
            end
            return
        end
        
        local filePath, userIdStr = Persistence.getConfigPath()
        if not filePath then return end

        if isfolder and makefolder then
            if not isfolder(FOLDER_NAME) then
                pcall(function() makefolder(FOLDER_NAME) end)
            end
            
            local userFolder = FOLDER_NAME .. "/" .. userIdStr
            if not isfolder(userFolder) then
                local fOk = pcall(function() makefolder(userFolder) end)
                if not fOk and not _persErrLogged.folder then
                    Logger.log("[SYSTEM] Failed to create user settings folder.", "warn")
                    _persErrLogged.folder = true
                end
            end
        end
        
        local data = {
            MonitorTrial = State.MonitorTrial,
            AutomationMaster = State.AutomationMaster,
            AutoJoinTrial = State.AutoJoinTrial,
            AutoTrial = State.AutoTrial,
            AntiAfkEnabled = State.AntiAfkEnabled,
        }
        
        local wOk = pcall(function()
            writefile(filePath, HttpService:JSONEncode(data))
        end)
        if not wOk and not _persErrLogged.write then
            Logger.log("[SYSTEM] Failed to write settings file.", "warn")
            _persErrLogged.write = true
        end
    end)
end

function Persistence.load()
    pcall(function()
        local filePath, userIdStr = Persistence.getConfigPath()
        if not filePath then return end

        Logger.log("[CONFIG] account UserId=" .. userIdStr, "system")
        Logger.log("[CONFIG] path=" .. filePath, "system")

        if not readfile or not isfile then
            if not _persErrLogged.api then
                Logger.log("[SYSTEM] Persistence API missing. Using defaults.", "info")
                _persErrLogged.api = true
            end
            return
        end

        if isfile(filePath) then
            local rOk, content = pcall(function() return readfile(filePath) end)
            if not rOk then
                if not _persErrLogged.read then
                    Logger.log("[SYSTEM] Failed to read settings file.", "warn")
                    _persErrLogged.read = true
                end
                return
            end

            local jOk, data = pcall(function() return HttpService:JSONDecode(content) end)
            if not jOk then
                if not _persErrLogged.read then
                    Logger.log("[SYSTEM] Failed to decode settings file (corrupted).", "warn")
                    _persErrLogged.read = true
                end
                return
            end
            
            if type(data) == "table" then
                if type(data.MonitorTrial) == "boolean" then State.MonitorTrial = data.MonitorTrial end
                if type(data.AutomationMaster) == "boolean" then State.AutomationMaster = data.AutomationMaster end
                if type(data.AutoJoinTrial) == "boolean" then State.AutoJoinTrial = data.AutoJoinTrial end
                if type(data.AutoTrial) == "boolean" then State.AutoTrial = data.AutoTrial end
                if type(data.AntiAfkEnabled) == "boolean" then State.AntiAfkEnabled = data.AntiAfkEnabled end
            end
            
            Logger.log("[CONFIG] loaded account config", "system")
        else
            Logger.log("[CONFIG] no account config found, using defaults", "system")
        end
    end)
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 7: ACTION ADAPTERS
-- ════════════════════════════════════════════════════════════════

local Actions = {}

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

    -- Scan for the EXACT "Confirm" GuiButton structurally linked to a Time Trial Prompt
    local candidates = {}
    local ok2, descendants = pcall(function() return invite:GetDescendants() end)
    if not ok2 then return false, "cannot_scan_invite" end

    for _, desc in ipairs(descendants) do
        if context.isCancelled() then return false, "cancelled" end
        
        if desc:IsA("GuiButton") and desc.Name == "Confirm" then
            local btnOk, btnVisible = pcall(function() return desc.Visible end)
            local actOk, btnActive = pcall(function() return desc.Active end)
            local intOk, btnInteractable = pcall(function() return desc.Interactable end)
            
            -- If Interactable isn't present, assume true if it passed Active/Visible
            local isInteractable = true
            if intOk then isInteractable = btnInteractable end

            if btnOk and btnVisible and actOk and btnActive and isInteractable then
                local hasTemplate = false
                local hasValidGamemode = false
                local current = desc.Parent
                
                -- Traverse ancestors strictly checking for Template vs Real Gamemode
                while current do
                    if current.Name == "Template" then
                        hasTemplate = true
                        break
                    end
                    if current.Name:lower():find("gamemode_time trial_", 1, true) then
                        hasValidGamemode = true
                    end
                    current = current.Parent
                end

                if not hasTemplate and hasValidGamemode then
                    table.insert(candidates, desc)
                end
            end
        end
    end

    local targetButton = nil
    if #candidates == 1 then
        targetButton = candidates[1]
    elseif #candidates == 0 then
        Logger.log("[ACTION] EnterTrial: No valid Time Trial Confirm button found", "warn")
        return false, "trial_confirm_not_found"
    else
        local paths = ""
        for i, c in ipairs(candidates) do
            paths = paths .. c:GetFullName() .. (i < #candidates and ", " or "")
        end
        Logger.log("[ACTION] EnterTrial: Ambiguous confirm buttons found: " .. paths, "warn")
        return false, "ambiguous_trial_confirm"
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

function Actions.FarmTrial(context)
    if context.isCancelled() then return false, "cancelled" end

    local container = context.trialContainer
    if not container or not isInstanceValid(container) then
        return false, "no_trial_container"
    end

    Logger.log("[ACTION] FarmTrial: starting farm loop in " .. tostring(container.Name), "action")

    local noTargetSince = nil
    local diagnosticEmitted = false

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

        if foundTarget then
            if diagnosticEmitted and noTargetSince then
                local elapsed = tick() - noTargetSince
                Logger.log(string.format("[TRIAL DEBUG] target visible again after %.1fs", elapsed), "info")
            end
            noTargetSince = nil
            diagnosticEmitted = false
        else
            if not noTargetSince then
                noTargetSince = tick()
            else
                local elapsed = tick() - noTargetSince
                if elapsed >= Config.TrialNoTargetDiagnosticThreshold and not diagnosticEmitted then
                    diagnosticEmitted = true
                    
                    local totalChildren = #enemies
                    local modelCount = 0
                    local partCount = 0
                    local targetableCount = 0

                    for _, mob in ipairs(enemies) do
                        if mob:IsA("Model") then
                            modelCount = modelCount + 1
                            local hasValid = false
                            pcall(function()
                                local hrpt = mob:FindFirstChild("HumanoidRootPart")
                                if hrpt and hrpt:IsA("BasePart") then
                                    hasValid = true
                                else
                                    local pp = mob.PrimaryPart
                                    if pp and pp:IsA("BasePart") then
                                        hasValid = true
                                    else
                                        for _, c in ipairs(mob:GetChildren()) do
                                            if c:IsA("BasePart") then
                                                hasValid = true
                                                break
                                            end
                                        end
                                    end
                                end
                            end)
                            if hasValid then targetableCount = targetableCount + 1 end
                        elseif mob:IsA("BasePart") then
                            partCount = partCount + 1
                            targetableCount = targetableCount + 1
                        end
                    end

                    Logger.log(string.format("[TRIAL DEBUG] no valid target for %.1fs", elapsed), "warn")
                    local cName = ""
                    pcall(function() cName = container.Name end)
                    Logger.log(string.format("[TRIAL DEBUG] container=%s", cName), "warn")
                    Logger.log(string.format("[TRIAL DEBUG] children=%d models=%d parts=%d targetable=%d", totalChildren, modelCount, partCount, targetableCount), "warn")
                end
            end
            task.wait(0.3)
        end
    end

    Logger.log("[ACTION] FarmTrial: farm loop ended", "action")
    return true, "loop_ended"
end

function Actions.AntiAfkPulse()
    local ok, vu = pcall(function() return game:GetService("VirtualUser") end)
    if ok and vu then
        local success = pcall(function()
            vu:CaptureController()
            vu:ClickButton2(Vector2.new())
        end)
        return success
    end
    return false
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 8: FORWARD DECLARATIONS
-- ════════════════════════════════════════════════════════════════

local StateMachine   = {}
local Arbiter        = {}
local ActionController = {}
local Detection      = {}
local GuiModule      = {}
local AntiAfkSystem  = {}

-- ════════════════════════════════════════════════════════════════
-- SECTION 9: STATE MACHINE
-- ════════════════════════════════════════════════════════════════

function StateMachine.setMainState(newState)
    if State.HubClosed then return end
    local old = State.MainState
    if old == newState then return end

    State.MainState = newState
    Logger.log("[STATE] " .. old .. " -> " .. newState, "state")

    -- After state change, let the Arbiter re-evaluate
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
            State._actionCooldowns.ENTER_TRIAL = tick() + Config.ActionRetryCooldown
            StateMachine.clearCurrentAction("adapter_failed")
            Detection.revalidateStatesFromObservation()
            task.delay(Config.ActionRetryCooldown + 0.1, function()
                if not State.HubClosed then
                    Arbiter.evaluate()
                end
            end)
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

        if success and State.CurrentAction.attemptId == attemptId and not State.CurrentAction.cancelled then
            if reason == "loop_ended" then
                Logger.log("[ACTION] Trial worker ended unexpectedly", "warn")
                StateMachine.clearCurrentAction("worker_ended")
                Detection.revalidateStatesFromObservation()
                
                if State.trialActive and State.MainState == "TRIAL_ACTIVE" then
                    if State.AutomationMaster and State.AutoTrial and State.MonitorTrial then
                        Logger.log("[TRIAL] Trial still active. Scheduling worker recovery", "info")
                        State._pendingRecoveryLog = true
                        task.defer(function()
                            if not State.HubClosed then
                                Arbiter.evaluate()
                            end
                        end)
                    end
                end
            end
        elseif not success and State.CurrentAction.attemptId == attemptId and not State.CurrentAction.cancelled then
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

-- ════════════════════════════════════════════════════════════════
-- SECTION 11: ARBITER / DECISION CONTROLLER
-- ════════════════════════════════════════════════════════════════

function Arbiter.evaluate()
    if State.HubClosed then return end

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
    end
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 12: DETECTION LAYER
-- ════════════════════════════════════════════════════════════════

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

    if not State._hadConfirmedTimeTrial then return end
    if State.MainState ~= "TRIAL_ACTIVE"
       and State.MainState ~= "TRIAL_ENDING" then
        return
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
                    if State.MainState == "TRIAL_ENDING" or State.MainState == "POST_TRIAL" then
                        Logger.log("[TRIAL] preserving " .. State.MainState .. " during residual container observation", "trial")
                    elseif not State.trialActive then
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

--- Revalidate states from actual game observation (after timeout/cancel).
function Detection.revalidateStatesFromObservation()
    if State.HubClosed then return end

    local wasEndingPhase = (State.MainState == "TRIAL_ENDING" or State.MainState == "POST_TRIAL")

    if not wasEndingPhase then
        State._trialEntryProcessed = false
        State._trialEndProcessed = false
    end

    local observedTrialActive = false
    local observedTrialName = ""
    local gm = resolveEnemiesGamemode()
    if gm then
        local ok, children = pcall(function() return gm:GetChildren() end)
        if ok then
            for _, child in ipairs(children) do
                local cok, cname = pcall(function() return child.Name end)
                if cok and cname:lower():find("time trial", 1, true) then
                    observedTrialActive = true
                    observedTrialName = cname
                    break
                end
            end
        end
    end

    local invite = resolveInvite()
    local observedTrialAvailable = false
    if invite then
        local ok, enabled = pcall(function() return invite.Enabled end)
        if ok and enabled then
            if hasTextContaining(invite, "time trial") then
                observedTrialAvailable = true
            end
        end
    end

    if observedTrialActive then
        if wasEndingPhase then
            Logger.log("[TRIAL] preserving " .. State.MainState .. " during residual container observation", "trial")
            State.trialActive = true
            State.trialModeName = observedTrialName
        else
            State.trialActive = true
            State.trialModeName = observedTrialName
            State._trialEntryProcessed = true
            State._hadConfirmedTimeTrial = true
            State.MainState = "TRIAL_ACTIVE"
        end
    else
        State.trialActive = false
        if not wasEndingPhase then
            State.trialModeName = ""
        end
        
        if wasEndingPhase then
            -- Leave MainState strictly protected
        elseif observedTrialAvailable then
            State.trialAvailable = true
            State.MainState = "TRIAL_AVAILABLE"
        else
            State.trialAvailable = false
            State.MainState = "IDLE"
        end
    end
end

--- Full state reset: zeroes counters, clears transient state, re-snapshots.
function Detection.resetState()
    if State.HubClosed then return end

    Logger.log("[SYSTEM] State reset requested", "system")

    -- Zero counters
    State.TrialsDetected = 0
    State.TrialsEntered = 0
    State.TrialsFinished = 0

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
    }

    -- Cancel current action
    if State.CurrentAction.name ~= "NONE" then
        ActionController.CancelCurrent("state_reset")
    end

    -- Reset states
    State.trialAvailable = false
    State.trialActive = false
    State.trialModeName = ""
    State.MainState = "IDLE"

    -- Re-snapshot
    if State.MonitorTrial then
        Detection.snapshotTrial()
    end

    Logger.log("[SYSTEM] State reset complete", "system")
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 13.5: ANTI-AFK SUBSYSTEM
-- ════════════════════════════════════════════════════════════════

local AntiAfkSystem = {
    lastActivity = tick(),
}

function AntiAfkSystem.init()
    connect(UserInputService.InputBegan, function()
        AntiAfkSystem.lastActivity = tick()
    end, "antiafk")

    connect(UserInputService.InputEnded, function()
        AntiAfkSystem.lastActivity = tick()
    end, "antiafk")

    task.spawn(function()
        while not State.HubClosed do
            task.wait(1)
            if State.AntiAfkEnabled then
                if tick() - AntiAfkSystem.lastActivity >= Config.AntiAfkInterval then
                    local success = Actions.AntiAfkPulse()
                    if success then
                        Logger.log("[ANTI-AFK] keep-alive pulse", "system")
                        AntiAfkSystem.lastActivity = tick()
                    end
                end
            end
        end
    end)
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
local WINDOW_HEIGHT = 440
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
    local statusPanel = GuiModule._createPanel(contentFrame, "StatusPanel", 36, 1)

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
    GuiRefs.TrialVal, GuiRefs.ModeVal = createStatusRow(statusPanel, 18, "Trial:", "Mode:")

    -- ─── TOGGLES PANEL ─────────────────────────────
    local togglesPanel = GuiModule._createPanel(contentFrame, "TogglesPanel", 84, 2)

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
        Persistence.save()
        if on then
            Logger.log("[SYSTEM] Monitor Trial ON — snapshotting", "system")
            Detection.snapshotTrial()
            Detection.recoverTrialWorkerIfNeeded()
            Arbiter.evaluate()
        else
            Logger.log("[SYSTEM] Monitor Trial OFF", "system")
            local act = State.CurrentAction.name
            if act == "ENTER_TRIAL" or act == "FARM_TRIAL" then
                ActionController.CancelCurrent("monitor_trial_off")
            end
        end
    end)

    GuiRefs.TogAutoMaster, GuiRefs.SetAutoMaster = createToggle(togglesPanel, halfW + 10, 18, halfW, "Master", State.AutomationMaster, function(on)
        State.AutomationMaster = on
        Persistence.save()
        Logger.log("[SYSTEM] Automation Master " .. (on and "ON" or "OFF"), "system")
        if on then 
            if State.MonitorTrial then Detection.snapshotTrial() end
            Detection.recoverTrialWorkerIfNeeded()
            Arbiter.evaluate() 
        else
            State._pendingRecoveryLog = false
            local act = State.CurrentAction.name
            if act == "FARM_TRIAL" or act == "ENTER_TRIAL" then
                ActionController.CancelCurrent("automation_master_off")
            end
        end
    end)

    GuiRefs.TogAutoJoin, GuiRefs.SetAutoJoin = createToggle(togglesPanel, halfW + 10, 38, halfW, "Auto Join", State.AutoJoinTrial, function(on)
        State.AutoJoinTrial = on
        Persistence.save()
        Logger.log("[SYSTEM] Auto Join Trial " .. (on and "ON" or "OFF"), "system")
        if on then 
            if State.MonitorTrial then Detection.snapshotTrial() end
            Arbiter.evaluate() 
        else
            if State.CurrentAction.name == "ENTER_TRIAL" then
                ActionController.CancelCurrent("auto_join_off")
            end
        end
    end)

    GuiRefs.TogAutoTrial, GuiRefs.SetAutoTrial = createToggle(togglesPanel, halfW + 10, 58, halfW, "Auto Trial", State.AutoTrial, function(on)
        State.AutoTrial = on
        Persistence.save()
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

    GuiRefs.TogAntiAfk, GuiRefs.SetAntiAfk = createToggle(togglesPanel, 4, 38, halfW, "Anti AFK", State.AntiAfkEnabled, function(on)
        State.AntiAfkEnabled = on
        Persistence.save()
        Logger.log("[SYSTEM] Anti AFK " .. (on and "ON" or "OFF"), "system")
        if on then
            AntiAfkSystem.lastActivity = tick()
        end
    end)

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

    -- Second row for counters
    local trialCntLabel2 = Instance.new("TextLabel")
    trialCntLabel2.Size = UDim2.new(1, -8, 0, 14)
    trialCntLabel2.Position = UDim2.new(0, 4, 0, 18)
    trialCntLabel2.BackgroundTransparency = 1
    trialCntLabel2.Font = Enum.Font.RobotoMono
    trialCntLabel2.TextSize = 9
    trialCntLabel2.TextColor3 = COLORS.textDim
    trialCntLabel2.TextXAlignment = Enum.TextXAlignment.Left
    trialCntLabel2.Text = "(D=detected E=entered F=finished)"
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
    local buttonsPanel = GuiModule._createPanel(contentFrame, "ButtonsPanel", 28, 6)
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

    if GuiRefs.ModeVal then
        GuiRefs.ModeVal.Text = (State.trialModeName ~= "" and State.trialModeName) or "—"
    end

    -- Counters
    if GuiRefs.TrialCounters then
        GuiRefs.TrialCounters.Text = State.TrialsDetected
            .. "/" .. State.TrialsEntered
            .. "/" .. State.TrialsFinished
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
        EnemiesGamemode = nil,
        Character = nil,
        HumanoidRootPart = nil,
    }
end

-- ════════════════════════════════════════════════════════════════
-- SECTION 14: INITIALIZATION
-- ════════════════════════════════════════════════════════════════

local function waitForStartupReadiness()
    if not game:IsLoaded() then
        print("[INIT] waiting for game")
        game.Loaded:Wait()
    end
    
    if not Players.LocalPlayer then
        print("[INIT] waiting for LocalPlayer")
        while not Players.LocalPlayer do task.wait(0.5) end
    end
    LocalPlayer = Players.LocalPlayer
    
    if not LocalPlayer:FindFirstChild("PlayerGui") then
        print("[INIT] waiting for PlayerGui")
        while not LocalPlayer:FindFirstChild("PlayerGui") do task.wait(0.5) end
    end
    
    if not LocalPlayer.Character then
        print("[INIT] waiting for Character")
        while not LocalPlayer.Character do task.wait(0.5) end
    end
    
    if not LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
        print("[INIT] waiting for HumanoidRootPart")
        while not LocalPlayer.Character:FindFirstChild("HumanoidRootPart") do task.wait(0.5) end
    end
    
    print("[INIT] dependencies ready")
    return true
end

local function initialize()
    local initOk, initErr = pcall(function()
        waitForStartupReadiness()

        -- 1. Load Persisted Settings safely
        Persistence.load()
        print("[INIT] persistence loaded")

        -- 2. Resolve PlayerGui early for GUI parent
        resolvePlayerGui()

        -- 3. Build GUI (this also flushes the log buffer)
        GuiModule.build()
        Logger.log("[INIT] GUI built", "system")

        -- 4. Resolve references
        resolveInvite()
        resolveGamemodeGui()
        resolveEnemiesGamemode()
        resolveCharacter()

        Logger.log("[INIT] refs resolved", "system")
        Logger.log("[SYSTEM]   PlayerGui: " .. (Refs.PlayerGui and "OK" or "MISSING"), "system")
        Logger.log("[SYSTEM]   Invite: " .. (Refs.Invite and "OK" or "MISSING"), "system")
        Logger.log("[SYSTEM]   Gamemode GUI: " .. (Refs.Gamemode and "OK" or "MISSING"), "system")
        Logger.log("[SYSTEM]   _ENEMIES.Server.Gamemode: " .. (Refs.EnemiesGamemode and "OK" or "MISSING"), "system")
        Logger.log("[SYSTEM]   Character: " .. (Refs.Character and "OK" or "MISSING"), "system")

        -- 5. Bind detection listeners
        Detection.bindPlayerGui()
        Detection.bindGamemodeFolder()
        Detection.bindCharacter()
        Logger.log("[INIT] listeners bound", "system")

        -- 6. Initial snapshots (#50)
        if State.MonitorTrial then
            Detection.snapshotTrial()
        end
        Detection.recoverTrialWorkerIfNeeded()
        Logger.log("[INIT] snapshots complete", "system")

        Arbiter.evaluate()

        -- 7. Start GUI update loop (~1 Hz)
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

        -- 8. Retry missing containers periodically
        task.spawn(function()
            while not State.HubClosed do
                task.wait(Config.ContainerResolveRetry)
                if State.HubClosed then break end

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

        -- 9. Init Anti-AFK
        AntiAfkSystem.init()
        Logger.log("[INIT] runtime loops started", "system")
        Logger.log("[INIT] complete", "system")
    end)

    if not initOk then
        warn("[INIT ERROR] error=" .. tostring(initErr))
        if Logger.log then
            Logger.log("[INIT ERROR] error=" .. tostring(initErr), "error")
        end
        GuiModule.close()
        return
    end

    Logger.log("[SYSTEM] HUB initialized — Main: " .. State.MainState, "system")
    Logger.log("[SYSTEM] All systems active — Raid guard ON, lifecycle farm", "system")
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

=== GAME STRUCTURE ===

3. The Time Trial child in _ENEMIES.Server.Gamemode was observed
   as "Time Trial_-1". Detection uses case-insensitive
   string.find("time trial"). Other naming variants are UNCONFIRMED.

4. Invite can activate for non-Trial reasons: mitigated by
   text check for "time trial".

5. Gamemode.Enabled activates for Raids, Dungeons, and other
   modes besides Time Trial. The system now guards against this
   by requiring a real Time Trial container in _ENEMIES.Server.Gamemode.

6. ScrollingFrame.AutomaticCanvasSize is assumed supported.

7. Instance.Destroying event is assumed available.
   AncestryChanged is fallback.

8. Character.HumanoidRootPart exists for LocalPlayer.
   Mobs may NOT follow this convention.

=== ADAPTER-SPECIFIC ===

9. firesignal() / fireproximityprompt() assumed available
   in the executor. Both adapters have fallback paths.
   In Roblox Studio, these adapters need mock/injection.

10. EnterTrial now searches for ANY GuiButton (TextButton +
    ImageButton). TextButton matched by keywords; ImageButton
    matched by green-ish BackgroundColor3 (G > 0.4, G > R*1.3)
    or Image asset name containing check/accept/confirm/yes.
    Fallback: first visible GuiButton. The exact UI layout
    (green check ImageButton, red X ImageButton) was observed
    but is UNCONFIRMED stable across all Invite variations.

11. FarmTrial is a lifecycle worker (timeout = math.huge).
    It does NOT timeout. Terminated only by:
    - Trial container destroyed
    - cancel token (trial ends, toggle off, hub closed)
    Enemy models are assumed direct children of the container.

12. FarmTrial teleports player to enemy (3-stud Z offset).
    No explicit attack — assumes proximity auto-attack.
]]
