--[[
    ANIME LEGACY CLIENT / GACHA INSPECTOR (100% READ-ONLY)
    Jogo alvo: Anime Legacy Simulator
    Objetivo: Mapear Scripts, Modules, Remotes, States, Árvores de UI (Star, Rolling, StarAnimation),
              Dependências Visíveis, Roll Trace de 3.0s e Diff A/B de Snapshots.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local PlayerScripts = LocalPlayer:FindFirstChild("PlayerScripts")

-- ============================================================================
-- CONFIGURAÇÕES E PALAVRAS-CHAVE
-- ============================================================================
local CAPTURE_DURATION = 3.000 -- Duração da captura [CAPTURE ROLL] em segundos
local INSPECTOR_GUI_NAME = "AnimeLegacyGachaInspectorUI"

local SCRIPT_KEYWORDS = {
	"star", "gacha", "roll", "rolling", "summon", "open",
	"auto", "fighter", "unit", "character", "capsule", "banner", "pity"
}

local REMOTE_KEYWORDS = {
	"star", "gacha", "roll", "rolling", "summon", "open",
	"buy", "purchase", "fighter", "unit", "character", "auto"
}

local STATE_KEYWORDS = {
	"opening", "isopening", "rolling", "isrolling", "busy", "ready",
	"canopen", "cooldown", "debounce", "auto", "star", "summon", "gacha", "pity"
}

local IGNORE_KEYWORDS = {
	"chat", "bubble", "freecam", "leaderboard", "playerlist", "backpack",
	"touchgui", "topbar", "PurchasePrompt", INSPECTOR_GUI_NAME
}

-- ============================================================================
-- IDENTIFICAÇÃO ÚNICA DE INSTÂNCIAS (UID) E CAMINHOS LIMPOS
-- ============================================================================
local InstanceUIDs = setmetatable({}, { __mode = "k" }) :: {[Instance]: number}
local NextUID = 0

local function getUID(inst: Instance): string
	local id = InstanceUIDs[inst]
	if not id then
		NextUID += 1
		id = NextUID
		InstanceUIDs[inst] = id
	end
	return "#" .. tostring(id)
end

local function getCleanPath(inst: Instance): string
	local parts = {}
	local curr: Instance? = inst
	while curr and curr ~= game do
		if curr == LocalPlayer then
			table.insert(parts, 1, "LocalPlayer")
			break
		end
		table.insert(parts, 1, curr.Name)
		curr = curr.Parent
	end
	return table.concat(parts, ".")
end

local function isInspectorObject(inst: Instance): boolean
	local p = getCleanPath(inst)
	return string.find(p, INSPECTOR_GUI_NAME, 1, true) ~= nil
end

local function matchesKeywords(text: string, keywords: {string}): (boolean, string?)
	local lower = string.lower(text)
	for _, kw in ipairs(keywords) do
		if string.find(lower, kw, 1, true) then
			return true, kw
		end
	end
	return false, nil
end

local function isIgnoredPath(path: string): boolean
	local matched, _ = matchesKeywords(path, IGNORE_KEYWORDS)
	return matched
end

local function parsePityNumbers(text: string): (number?, number?)
	local cur, max = string.match(text, "(%d+)%s*/%s*(%d+)")
	if cur and max then
		return tonumber(cur), tonumber(max)
	end
	local single = string.match(text, "(%d+)")
	if single then
		return tonumber(single), nil
	end
	return nil, nil
end

-- ============================================================================
-- SISTEMA DE PONTUAÇÃO DE EVIDÊNCIAS (TOP CANDIDATES)
-- ============================================================================
export type CandidateRecord = {
	path: string,
	className: string,
	name: string,
	score: number,
	reasons: {[string]: boolean},
	changeCount: number,
}

local CandidateRegistry: {[string]: CandidateRecord} = {}

local function registerCandidateEvidence(instOrPath: Instance | string, className: string, name: string, reason: string, points: number, isRuntimeChange: boolean?)
	local path = (typeof(instOrPath) == "Instance") and getCleanPath(instOrPath) or (instOrPath :: string)
	if isIgnoredPath(path) then return end

	local rec = CandidateRegistry[path]
	if not rec then
		rec = {
			path = path,
			className = className,
			name = name,
			score = 0,
			reasons = {},
			changeCount = 0,
		}
		CandidateRegistry[path] = rec
	end

	if not rec.reasons[reason] then
		rec.reasons[reason] = true
		rec.score += points
	end

	if isRuntimeChange then
		rec.changeCount += 1
		rec.score += 1
	end
end

-- ============================================================================
-- ESTRUTURAS DE DADOS DO INVENTÁRIO
-- ============================================================================
local Inventory = {
	Scripts = {} :: {any},
	Modules = {} :: {any},
	ScriptCandidates = {} :: {any},
	Dependencies = {} :: {any},
	Remotes = {} :: {any},
	States = {} :: {any},
	AnimationObjects = {} :: {any},
	LastRollTrace = {} :: {string},
	LastDiffReport = {} :: {string},
	IsCapturingRoll = false,
	SnapshotA = nil :: any,
	SnapshotB = nil :: any,
}

local Connections = {} :: {RBXScriptConnection}
local TraceConnections = {} :: {RBXScriptConnection}

-- ============================================================================
-- 1 & 6. INVENTÁRIO DE SCRIPTS, MODULES E DEPENDÊNCIAS VISÍVEIS
-- ============================================================================
local function tryReadSourceStatus(scr: Instance): string
	local ok, src = pcall(function()
		return (scr :: any).Source
	end)
	if ok and type(src) == "string" and #src > 0 then
		return string.format("ACCESSIBLE (%d chars)", #src)
	end
	return "SOURCE NOT ACCESSIBLE"
end

local function getScriptEnabledStatus(scr: Instance): string
	if scr:IsA("ModuleScript") then
		return "N/A (ModuleScript)"
	end
	local ok, val = pcall(function()
		return (scr :: any).Enabled
	end)
	if ok then
		return tostring(val)
	end
	local okDis, disVal = pcall(function()
		return not (scr :: any).Disabled
	end)
	if okDis then
		return tostring(disVal)
	end
	return "NOT OBSERVABLE WITH CURRENT ACCESS"
end

local function inspectVisibleDependencies(inst: Instance, instPath: string)
	local deps = {}

	-- 1. Atributos no próprio Script/Module
	local attrs = inst:GetAttributes()
	for k, v in pairs(attrs) do
		table.insert(deps, string.format("Attribute '%s' = %s (%s)", k, tostring(v), typeof(v)))
	end

	-- 2. Filhos diretos e descendentes imediatos (ObjectValues, Values, Modules, Remotes, Binds)
	for _, desc in ipairs(inst:GetDescendants()) do
		if desc:IsA("ObjectValue") then
			local targetPath = desc.Value and getCleanPath(desc.Value) or "nil"
			table.insert(deps, string.format("ObjectValue '%s' -> %s", getCleanPath(desc), targetPath))
		elseif desc:IsA("ValueBase") then
			local v = (desc :: any).Value
			table.insert(deps, string.format("%s '%s' = %s", desc.ClassName, desc.Name, tostring(v)))
		elseif desc:IsA("RemoteEvent") or desc:IsA("RemoteFunction") or desc:IsA("BindableEvent") or desc:IsA("BindableFunction") then
			table.insert(deps, string.format("Child Remote/Bindable: %s (%s)", getCleanPath(desc), desc.ClassName))
		elseif desc:IsA("ModuleScript") and desc ~= inst then
			table.insert(deps, string.format("Child ModuleScript: %s", getCleanPath(desc)))
		end
	end

	-- 3. Contexto de Parent se estiver acoplado dentro de um Botão ou Frame da UI
	if inst.Parent and (inst.Parent:IsA("GuiObject") or inst.Parent:IsA("ScreenGui")) then
		table.insert(deps, string.format("Attached UI Parent: %s (%s)", getCleanPath(inst.Parent), inst.Parent.ClassName))
	end

	if #deps > 0 then
		table.insert(Inventory.Dependencies, {
			ownerPath = instPath,
			ownerClass = inst.ClassName,
			items = deps,
		})
	end
end

local function scanScriptsAndModules()
	table.clear(Inventory.Scripts)
	table.clear(Inventory.Modules)
	table.clear(Inventory.ScriptCandidates)
	table.clear(Inventory.Dependencies)

	local roots = { PlayerGui, ReplicatedStorage }
	if PlayerScripts then
		table.insert(roots, 1, PlayerScripts)
	end

	for _, root in ipairs(roots) do
		for _, desc in ipairs(root:GetDescendants()) do
			if not isInspectorObject(desc) and (desc:IsA("LocalScript") or desc:IsA("ModuleScript") or desc:IsA("Script")) then
				local path = getCleanPath(desc)
				if not isIgnoredPath(path) then
					local enabledStr = getScriptEnabledStatus(desc)
					local sourceStr = tryReadSourceStatus(desc)
					local isCandidate, matchedKw = matchesKeywords(path, SCRIPT_KEYWORDS)

					local entry = {
						className = desc.ClassName,
						path = path,
						name = desc.Name,
						enabled = enabledStr,
						sourceStatus = sourceStr,
						isCandidate = isCandidate,
						matchedKeyword = matchedKw,
						uid = getUID(desc),
					}

					if desc:IsA("ModuleScript") then
						table.insert(Inventory.Modules, entry)
					else
						table.insert(Inventory.Scripts, entry)
					end

					if isCandidate then
						table.insert(Inventory.ScriptCandidates, entry)
						registerCandidateEvidence(desc, desc.ClassName, desc.Name, "Keyword Match (" .. tostring(matchedKw) .. ")", 2, false)
					end

					inspectVisibleDependencies(desc, path)
				end
			end
		end
	end
end

-- ============================================================================
-- 2. INVENTÁRIO DE REMOTES
-- ============================================================================
local function scanRemotes()
	table.clear(Inventory.Remotes)
	local roots = { ReplicatedStorage, PlayerGui, Workspace, LocalPlayer }

	for _, root in ipairs(roots) do
		for _, desc in ipairs(root:GetDescendants()) do
			if not isInspectorObject(desc) and (
				desc:IsA("RemoteEvent")
				or desc:IsA("RemoteFunction")
				or desc:IsA("UnreliableRemoteEvent")
				or desc:IsA("BindableEvent")
				or desc:IsA("BindableFunction")
			) then
				local path = getCleanPath(desc)
				if not isIgnoredPath(path) then
					local isCand, kw = matchesKeywords(path, REMOTE_KEYWORDS)
					table.insert(Inventory.Remotes, {
						className = desc.ClassName,
						path = path,
						name = desc.Name,
						isCandidate = isCand,
						matchedKeyword = kw,
						uid = getUID(desc),
					})
					if isCand then
						registerCandidateEvidence(desc, desc.ClassName, desc.Name, "Remote Keyword (" .. tostring(kw) .. ")", 2, false)
					end
				end
			end
		end
	end
end

-- ============================================================================
-- 3. INVENTÁRIO DE STATES (VALUES & ATTRIBUTES) E OBJETOS DE ANIMAÇÃO
-- ============================================================================
local function scanStatesAndAnimations()
	table.clear(Inventory.States)
	table.clear(Inventory.AnimationObjects)

	local roots = { LocalPlayer, PlayerGui, ReplicatedStorage, Workspace }

	local function checkInstanceAttributes(inst: Instance)
		local path = getCleanPath(inst)
		if isIgnoredPath(path) then return end
		local attrs = inst:GetAttributes()
		for attrName, attrVal in pairs(attrs) do
			local fullAttrPath = path .. ".Attribute." .. attrName
			local isCand, kw = matchesKeywords(fullAttrPath, STATE_KEYWORDS)
			if isCand or inst == LocalPlayer then
				table.insert(Inventory.States, {
					kind = "Attribute (" .. typeof(attrVal) .. ")",
					path = fullAttrPath,
					name = attrName,
					value = tostring(attrVal),
					isCandidate = isCand,
				})
				if isCand then
					registerCandidateEvidence(fullAttrPath, "Attribute", attrName, "State Keyword (" .. tostring(kw) .. ")", 2, false)
				end
			end
		end
	end

	checkInstanceAttributes(LocalPlayer)

	for _, root in ipairs(roots) do
		for _, desc in ipairs(root:GetDescendants()) do
			if not isInspectorObject(desc) then
				local path = getCleanPath(desc)
				if not isIgnoredPath(path) then
					-- Values
					if desc:IsA("BoolValue") or desc:IsA("NumberValue") or desc:IsA("IntValue") or desc:IsA("StringValue") or desc:IsA("ObjectValue") then
						local isCand, kw = matchesKeywords(path, STATE_KEYWORDS)
						if isCand or root == LocalPlayer then
							local valStr = tostring((desc :: any).Value)
							table.insert(Inventory.States, {
								kind = desc.ClassName,
								path = path,
								name = desc.Name,
								value = valStr,
								isCandidate = isCand,
							})
							if isCand then
								registerCandidateEvidence(desc, desc.ClassName, desc.Name, "State Keyword (" .. tostring(kw) .. ")", 2, false)
							end
						end
					end

					-- Pity TextLabel conhecido
					if path == "PlayerGui.UI.Frames.Star.Pity.Value" and desc:IsA("TextLabel") then
						table.insert(Inventory.States, {
							kind = "TextLabel (Pity Source)",
							path = path,
							name = desc.Name,
							value = desc.Text,
							isCandidate = true,
						})
						registerCandidateEvidence(desc, desc.ClassName, desc.Name, "Confirmed Pity Truth Source", 10, false)
					end

					-- Attributes em objetos relevantes
					if next(desc:GetAttributes()) ~= nil then
						checkInstanceAttributes(desc)
					end

					-- Animation Objects
					if desc:IsA("Animation") or desc:IsA("Animator") or desc:IsA("AnimationController") or desc:IsA("ViewportFrame") then
						local isAnimCand, _ = matchesKeywords(path, SCRIPT_KEYWORDS)
						if isAnimCand or desc:IsDescendantOf(PlayerGui) or string.find(path, "Cache", 1, true) then
							local extra = ""
							if desc:IsA("Animation") then
								extra = " | AnimationId: " .. tostring(desc.AnimationId)
							end
							table.insert(Inventory.AnimationObjects, {
								className = desc.ClassName,
								path = path,
								name = desc.Name,
								extra = extra,
								uid = getUID(desc),
							})
							if isAnimCand then
								registerCandidateEvidence(desc, desc.ClassName, desc.Name, "Animation/Viewport Object", 2, false)
							end
						end
					end
				end
			end
		end
	end
end

-- ============================================================================
-- 5. MAPA DA UI (DUMP HIERÁRQUICO COMPLETO)
-- ============================================================================
local function formatUiNodeProps(inst: Instance): string
	local props = {}

	if inst:IsA("ScreenGui") then
		table.insert(props, "Enabled=" .. tostring(inst.Enabled))
		table.insert(props, "DisplayOrder=" .. tostring(inst.DisplayOrder))
	end

	if inst:IsA("GuiObject") then
		table.insert(props, "Visible=" .. tostring(inst.Visible))
		table.insert(props, "Active=" .. tostring(inst.Active))
		pcall(function()
			table.insert(props, "Interactable=" .. tostring((inst :: any).Interactable))
		end)
	end

	if inst:IsA("TextLabel") or inst:IsA("TextButton") then
		local cleanText = string.gsub(inst.Text, "\n", " ")
		if #cleanText > 40 then
			cleanText = string.sub(cleanText, 1, 40) .. "..."
		end
		table.insert(props, string.format('Text="%s"', cleanText))
	end

	if inst:IsA("ValueBase") then
		table.insert(props, "Value=" .. tostring((inst :: any).Value))
	end

	if #props == 0 then
		return ""
	end
	return " [" .. table.concat(props, " | ") .. "]"
end

local function dumpUiTree(rootInst: Instance?, labelTitle: string): {string}
	local lines = {}
	table.insert(lines, string.format("--- %s ---", labelTitle))

	if not rootInst then
		table.insert(lines, "  [NÃO ENCONTRADO NO PLAYERGUI ATUALMENTE]")
		return lines
	end

	local function traverse(node: Instance, depth: number)
		local indent = string.rep("  ", depth)
		local path = getCleanPath(node)
		local propSummary = formatUiNodeProps(node)
		table.insert(lines, string.format(
			"%s- [%s] %s (%s)%s | Path: %s",
			indent, node.ClassName, node.Name, getUID(node), propSummary, path
		))

		-- Verifica dependências visíveis também em frames/botões da UI da Star
		if node:IsA("ObjectValue") then
			local target = node.Value and getCleanPath(node.Value) or "nil"
			table.insert(lines, string.format("%s    -> ObjectValue Target: %s", indent, target))
		end

		for _, child in ipairs(node:GetChildren()) do
			traverse(child, depth + 1)
		end
	end

	traverse(rootInst, 0)
	return lines
end

local function getTargetUiRoots()
	local ui = PlayerGui:FindFirstChild("UI")
	local frames = ui and ui:FindFirstChild("Frames")
	local starFrame = frames and frames:FindFirstChild("Star")
	local rollingGui = PlayerGui:FindFirstChild("Rolling")
	local starAnimGui = PlayerGui:FindFirstChild("StarAnimation")
	return starFrame, rollingGui, starAnimGui
end

-- ============================================================================
-- 4. [CAPTURE ROLL] — TRACE DE 3 SEGUNDOS ANTES/DURANTE/DEPOIS DA ABERTURA
-- ============================================================================
local function stopRollCaptureConnections()
	for _, c in ipairs(TraceConnections) do
		if c.Connected then
			c:Disconnect()
		end
	end
	table.clear(TraceConnections)
end

local function runRollCapture(onFinishedCallback: (() -> ())?)
	if Inventory.IsCapturingRoll then
		warn("[INSPECTOR] Uma captura de Roll já está em andamento!")
		return
	end

	Inventory.IsCapturingRoll = true
	stopRollCaptureConnections()
	table.clear(Inventory.LastRollTrace)

	local t0 = os.clock()
	local lastPityChangeTimestamp: number? = nil
	local rawTraceEvents = {} :: {{ relTime: number, text: string, path: string?, inst: Instance?, className: string?, name: string? }}

	local function logTrace(msg: string, inst: Instance?, customPath: string?)
		local now = os.clock()
		local rel = math.max(0, now - t0)
		local path = customPath or (inst and getCleanPath(inst) or nil)
		table.insert(rawTraceEvents, {
			relTime = rel,
			text = string.format("T+%.3f\n%s", rel, msg),
			path = path,
			inst = inst,
			className = inst and inst.ClassName or "State",
			name = inst and inst.Name or (customPath or "Event"),
		})
	end

	print(string.format("\n[INSPECTOR] Iniciando CAPTURE ROLL por %.1f segundos! Abra uma Star agora...", CAPTURE_DURATION))

	-- 1. Snapshot inicial em T+0.000
	local starFrame, rollingGui, starAnimGui = getTargetUiRoots()
	local pityLabel = starFrame and starFrame:FindFirstChild("Pity") and starFrame.Pity:FindFirstChild("Value")
	local maxBtn = starFrame and starFrame:FindFirstChild("Buttons") and starFrame.Buttons:FindFirstChild("Max") and starFrame.Buttons.Max:FindFirstChild("Main")

	local initLines = {}
	if starFrame and starFrame:IsA("GuiObject") then
		table.insert(initLines, string.format("Star.Visible = %s", tostring(starFrame.Visible)))
	end
	if maxBtn and maxBtn:IsA("GuiObject") then
		table.insert(initLines, string.format("Buttons.Max.Main: Visible=%s | Active=%s", tostring(maxBtn.Visible), tostring(maxBtn.Active)))
	end
	if rollingGui then
		local rProp = rollingGui:IsA("ScreenGui") and ("Enabled=" .. tostring(rollingGui.Enabled))
			or (rollingGui:IsA("GuiObject") and ("Visible=" .. tostring(rollingGui.Visible)) or "Present")
		table.insert(initLines, "PlayerGui.Rolling: " .. rProp)
	end
	if starAnimGui then
		local sProp = starAnimGui:IsA("ScreenGui") and ("Enabled=" .. tostring(starAnimGui.Enabled))
			or (starAnimGui:IsA("GuiObject") and ("Visible=" .. tostring(starAnimGui.Visible)) or "Present")
		table.insert(initLines, "PlayerGui.StarAnimation: " .. sProp)
	end
	if pityLabel and pityLabel:IsA("TextLabel") then
		table.insert(initLines, "Pity initial = " .. pityLabel.Text)
	end
	logTrace(table.concat(initLines, "\n"), nil, nil)

	-- Helper para conectar monitoramento de propriedades em um objeto durante os 3 segundos
	local hookedInTrace = setmetatable({}, { __mode = "k" }) :: {[Instance]: boolean}

	local function hookInstanceForTrace(inst: Instance)
		if hookedInTrace[inst] or isInspectorObject(inst) then return end
		local path = getCleanPath(inst)
		if isIgnoredPath(path) then return end
		hookedInTrace[inst] = true

		-- Pity oficial
		if path == "PlayerGui.UI.Frames.Star.Pity.Value" and inst:IsA("TextLabel") then
			local lastText = inst.Text
			table.insert(TraceConnections, inst:GetPropertyChangedSignal("Text"):Connect(function()
				local newText = inst.Text
				if newText ~= lastText then
					local oldC, _ = parsePityNumbers(lastText)
					local newC, _ = parsePityNumbers(newText)
					local prev = lastText
					lastText = newText
					lastPityChangeTimestamp = os.clock()
					logTrace(string.format("PITY CHANGED: %s -> %s", tostring(oldC or prev), tostring(newC or newText)), inst, path)
					registerCandidateEvidence(inst, inst.ClassName, inst.Name, "Changed during Roll Trace (Pity)", 8, true)
				end
			end))
		end

		-- GuiObject Visible / Active / Interactable
		if inst:IsA("GuiObject") then
			local lastVis = inst.Visible
			table.insert(TraceConnections, inst:GetPropertyChangedSignal("Visible"):Connect(function()
				local v = inst.Visible
				if v ~= lastVis then
					lastVis = v
					logTrace(string.format("%s.Visible = %s", path, tostring(v)), inst, path)
					registerCandidateEvidence(inst, inst.ClassName, inst.Name, "Visible toggled during Roll Trace", 4, true)
				end
			end))

			local lastAct = inst.Active
			table.insert(TraceConnections, inst:GetPropertyChangedSignal("Active"):Connect(function()
				local v = inst.Active
				if v ~= lastAct then
					lastAct = v
					logTrace(string.format("%s.Active = %s", path, tostring(v)), inst, path)
					registerCandidateEvidence(inst, inst.ClassName, inst.Name, "Active toggled during Roll Trace", 3, true)
				end
			end))
		end

		-- ScreenGui / Efeitos Enabled
		if inst:IsA("ScreenGui") or inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Highlight") or inst:IsA("LocalScript") then
			pcall(function()
				local propObj = inst :: any
				local lastEn = propObj.Enabled
				table.insert(TraceConnections, inst:GetPropertyChangedSignal("Enabled"):Connect(function()
					local v = propObj.Enabled
					if v ~= lastEn then
						lastEn = v
						logTrace(string.format("%s.Enabled = %s", path, tostring(v)), inst, path)
						registerCandidateEvidence(inst, inst.ClassName, inst.Name, "Enabled toggled during Roll Trace", 4, true)
					end
				end))
			end)
		end

		-- ValueBase
		if inst:IsA("BoolValue") or inst:IsA("NumberValue") or inst:IsA("IntValue") or inst:IsA("StringValue") or inst:IsA("ObjectValue") then
			local vObj = inst :: any
			local lastVal = vObj.Value
			table.insert(TraceConnections, vObj:GetPropertyChangedSignal("Value"):Connect(function()
				local newVal = vObj.Value
				if newVal ~= lastVal then
					local prev = lastVal
					lastVal = newVal
					logTrace(string.format("VALUE CHANGED: %s (%s -> %s)", path, tostring(prev), tostring(newVal)), inst, path)
					registerCandidateEvidence(inst, inst.ClassName, inst.Name, "Value changed during Roll Trace", 5, true)
				end
			end))
		end

		-- Attributes
		local cachedAttrs = inst:GetAttributes()
		table.insert(TraceConnections, inst.AttributeChanged:Connect(function(attrName: string)
			local newVal = inst:GetAttribute(attrName)
			local oldVal = cachedAttrs[attrName]
			cachedAttrs[attrName] = newVal
			local attrPath = path .. ".Attribute." .. attrName
			logTrace(string.format("ATTRIBUTE CHANGED: %s (%s -> %s)", attrPath, tostring(oldVal), tostring(newVal)), nil, attrPath)
			registerCandidateEvidence(attrPath, "Attribute", attrName, "Attribute changed during Roll Trace", 5, true)
		end))

		-- AnimationTracks iniciadas
		if inst:IsA("Animator") or inst:IsA("AnimationController") or inst:IsA("Humanoid") then
			if not (LocalPlayer.Character and inst:IsDescendantOf(LocalPlayer.Character)) then
				table.insert(TraceConnections, (inst :: any).AnimationPlayed:Connect(function(track: AnimationTrack)
					local animId = track.Animation and track.Animation.AnimationId or "Unknown"
					logTrace(string.format("ANIMATION STARTED:\nAnimator: %s\nAnimationId: %s (Length: %.2fs)", path, animId, track.Length), inst, path)
					registerCandidateEvidence(inst, inst.ClassName, inst.Name, "Played Animation during Roll Trace", 5, true)
				end))
			end
		end
	end

	-- Conecta em LocalPlayer e nas árvores relevantes
	hookInstanceForTrace(LocalPlayer)
	for _, root in ipairs({ PlayerGui, Workspace, ReplicatedStorage }) do
		for _, desc in ipairs(root:GetDescendants()) do
			if root == PlayerGui
				or desc:IsA("ValueBase")
				or desc:IsA("Animator")
				or desc:IsA("AnimationController")
				or next(desc:GetAttributes()) ~= nil
				or matchesKeywords(getCleanPath(desc), SCRIPT_KEYWORDS) then
				hookInstanceForTrace(desc)
			end
		end

		-- Monitora novas Instances criadas e removidas durante os 3s
		table.insert(TraceConnections, root.DescendantAdded:Connect(function(desc)
			if isInspectorObject(desc) then return end
			local p = getCleanPath(desc)
			if isIgnoredPath(p) then return end
			logTrace(string.format("NEW INSTANCE (%s [%s]):\n%s", desc.ClassName, getUID(desc), p), desc, p)
			registerCandidateEvidence(desc, desc.ClassName, desc.Name, "Created during Roll Trace", 4, true)
			hookInstanceForTrace(desc)
		end))

		table.insert(TraceConnections, root.DescendantRemoving:Connect(function(desc)
			if isInspectorObject(desc) then return end
			local p = getCleanPath(desc)
			if isIgnoredPath(p) then return end
			logTrace(string.format("REMOVED INSTANCE (%s [%s]):\n%s", desc.ClassName, getUID(desc), p), desc, p)
		end))
	end

	-- Aguarda os 3 segundos sem travar a thread principal
	task.delay(CAPTURE_DURATION, function()
		stopRollCaptureConnections()
		Inventory.IsCapturingRoll = false

		-- Marca candidatos cujos eventos aconteceram sincronizados com a mudança do Pity (±150ms)
		local pityRelTime: number? = lastPityChangeTimestamp and (lastPityChangeTimestamp - t0) or nil
		for _, ev in ipairs(rawTraceEvents) do
			table.insert(Inventory.LastRollTrace, ev.text)
			if pityRelTime and ev.path and math.abs(ev.relTime - pityRelTime) <= 0.150 then
				registerCandidateEvidence(ev.path, ev.className or "Instance", ev.name or "Object", "Synchronized with Pity (<150ms)", 6, false)
			end
		end

		print("\n===== ROLL TRACE =====")
		for _, entryText in ipairs(Inventory.LastRollTrace) do
			print("\n" .. entryText)
		end
		print("\n======================\n")

		if onFinishedCallback then
			onFinishedCallback()
		end
	end)
end

-- ============================================================================
-- 7. MODO DIFF: [SNAPSHOT A], [SNAPSHOT B] E [COMPARE]
-- ============================================================================
export type NodeSnapshot = {
	uid: string,
	path: string,
	className: string,
	name: string,
	hasVisible: boolean,
	visible: boolean?,
	hasEnabled: boolean,
	enabled: boolean?,
	hasValue: boolean,
	value: string?,
	attributes: {[string]: string},
}

local function takeStateSnapshot(label: string)
	local snap = {
		label = label,
		timestamp = os.clock(),
		nodesByUid = {} :: {[string]: NodeSnapshot},
	}

	local function recordNode(inst: Instance)
		if isInspectorObject(inst) then return end
		local path = getCleanPath(inst)
		if isIgnoredPath(path) then return end

		local uid = getUID(inst)
		local node: NodeSnapshot = {
			uid = uid,
			path = path,
			className = inst.ClassName,
			name = inst.Name,
			hasVisible = false,
			visible = nil,
			hasEnabled = false,
			enabled = nil,
			hasValue = false,
			value = nil,
			attributes = {},
		}

		if inst:IsA("GuiObject") then
			node.hasVisible = true
			node.visible = inst.Visible
		end

		if inst:IsA("ScreenGui") or inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Highlight") or inst:IsA("LocalScript") then
			pcall(function()
				node.hasEnabled = true
				node.enabled = (inst :: any).Enabled
			end)
		end

		if inst:IsA("BoolValue") or inst:IsA("NumberValue") or inst:IsA("IntValue") or inst:IsA("StringValue") or inst:IsA("ObjectValue") then
			node.hasValue = true
			node.value = tostring((inst :: any).Value)
		elseif inst:IsA("TextLabel") and (
			string.find(path, "PlayerGui.UI.Frames.Star", 1, true)
			or string.find(path, "PlayerGui.Rolling", 1, true)
			or string.find(path, "PlayerGui.StarAnimation", 1, true)
		) then
			node.hasValue = true
			node.value = inst.Text
		end

		for k, v in pairs(inst:GetAttributes()) do
			node.attributes[k] = tostring(v)
		end

		snap.nodesByUid[uid] = node
	end

	recordNode(LocalPlayer)

	-- Captura PlayerGui completo e objetos relevantes em ReplicatedStorage e Workspace
	for _, desc in ipairs(PlayerGui:GetDescendants()) do
		recordNode(desc)
	end

	for _, root in ipairs({ ReplicatedStorage, Workspace, LocalPlayer }) do
		for _, desc in ipairs(root:GetDescendants()) do
			if not desc:IsDescendantOf(PlayerGui) then
				local p = getCleanPath(desc)
				if desc:IsA("ValueBase")
					or next(desc:GetAttributes()) ~= nil
					or string.find(p, "Cache", 1, true)
					or matchesKeywords(p, SCRIPT_KEYWORDS) then
					recordNode(desc)
				end
			end
		end
	end

	print(string.format("[INSPECTOR] %s capturado em T=%.3f!", label, snap.timestamp))
	return snap
end

local function compareSnapshots()
	if not Inventory.SnapshotA or not Inventory.SnapshotB then
		warn("[INSPECTOR] Capture primeiro o [SNAPSHOT A] e o [SNAPSHOT B] antes de clicar em [COMPARE]!")
		return
	end

	local snapA = Inventory.SnapshotA
	local snapB = Inventory.SnapshotB

	local added = {}
	local removed = {}
	local valueChanged = {}
	local attrChanged = {}
	local visChanged = {}
	local enabledChanged = {}

	-- Verifica REMOVED e mudanças em objetos que existem em ambos
	for uid, nodeA in pairs(snapA.nodesByUid) do
		local nodeB = snapB.nodesByUid[uid]
		if not nodeB then
			table.insert(removed, string.format("  - [%s] %s (%s)", nodeA.className, nodeA.path, uid))
		else
			-- VALUE CHANGED
			if nodeA.hasValue and nodeB.hasValue and nodeA.value ~= nodeB.value then
				table.insert(valueChanged, string.format("  * %s: '%s' -> '%s'", nodeB.path, tostring(nodeA.value), tostring(nodeB.value)))
				registerCandidateEvidence(nodeB.path, nodeB.className, nodeB.name, "Value changed in Diff A/B", 4, true)
			end

			-- VISIBLE CHANGED
			if nodeA.hasVisible and nodeB.hasVisible and nodeA.visible ~= nodeB.visible then
				table.insert(visChanged, string.format("  * %s.Visible: %s -> %s", nodeB.path, tostring(nodeA.visible), tostring(nodeB.visible)))
				registerCandidateEvidence(nodeB.path, nodeB.className, nodeB.name, "Visible changed in Diff A/B", 4, true)
			end

			-- ENABLED CHANGED
			if nodeA.hasEnabled and nodeB.hasEnabled and nodeA.enabled ~= nodeB.enabled then
				table.insert(enabledChanged, string.format("  * %s.Enabled: %s -> %s", nodeB.path, tostring(nodeA.enabled), tostring(nodeB.enabled)))
				registerCandidateEvidence(nodeB.path, nodeB.className, nodeB.name, "Enabled changed in Diff A/B", 4, true)
			end

			-- ATTRIBUTE CHANGED
			for k, valA in pairs(nodeA.attributes) do
				local valB = nodeB.attributes[k]
				if valB == nil then
					table.insert(attrChanged, string.format("  * %s.Attribute.%s: '%s' -> [REMOVED]", nodeB.path, k, valA))
				elseif valA ~= valB then
					table.insert(attrChanged, string.format("  * %s.Attribute.%s: '%s' -> '%s'", nodeB.path, k, valA, valB))
					registerCandidateEvidence(nodeB.path .. ".Attribute." .. k, "Attribute", k, "Attribute changed in Diff A/B", 4, true)
				end
			end
			for k, valB in pairs(nodeB.attributes) do
				if nodeA.attributes[k] == nil then
					table.insert(attrChanged, string.format("  * %s.Attribute.%s: [ADDED] -> '%s'", nodeB.path, k, valB))
					registerCandidateEvidence(nodeB.path .. ".Attribute." .. k, "Attribute", k, "Attribute added in Diff A/B", 4, true)
				end
			end
		end
	end

	-- Verifica ADDED (presentes em B, ausentes em A)
	for uid, nodeB in pairs(snapB.nodesByUid) do
		if not snapA.nodesByUid[uid] then
			table.insert(added, string.format("  + [%s] %s (%s)", nodeB.className, nodeB.path, uid))
			registerCandidateEvidence(nodeB.path, nodeB.className, nodeB.name, "Instance added in Diff A/B", 4, true)
		end
	end

	table.clear(Inventory.LastDiffReport)
	local function addSection(title: string, list: {string})
		table.insert(Inventory.LastDiffReport, title)
		if #list == 0 then
			table.insert(Inventory.LastDiffReport, "  (Nenhuma diferença)")
		else
			for _, item in ipairs(list) do
				table.insert(Inventory.LastDiffReport, item)
			end
		end
	end

	addSection("ADDED:", added)
	addSection("REMOVED:", removed)
	addSection("VALUE CHANGED:", valueChanged)
	addSection("ATTRIBUTE CHANGED:", attrChanged)
	addSection("VISIBLE CHANGED:", visChanged)
	addSection("ENABLED CHANGED:", enabledChanged)

	print("\n================ SNAPSHOT DIFF (A vs B) ================")
	for _, line in ipairs(Inventory.LastDiffReport) do
		print(line)
	end
	print("========================================================\n")
end

-- ============================================================================
-- 8. FUNÇÃO GLOBAL printFullReport() E SEÇÕES COMPLETAS
-- ============================================================================
local function scanAllStaticInventories()
	scanScriptsAndModules()
	scanRemotes()
	scanStatesAndAnimations()
end

local function printFullReport()
	scanAllStaticInventories()
	local starFrame, rollingGui, starAnimGui = getTargetUiRoots()

	print("\n======================================================================")
	print("             ANIME LEGACY CLIENT / GACHA INSPECTOR REPORT             ")
	print("======================================================================\n")

	-- 1. === SCRIPTS ===
	print("=== SCRIPTS ===")
	print(string.format("Total LocalScripts/Scripts escaneados: %d", #Inventory.Scripts))
	for _, s in ipairs(Inventory.Scripts) do
		if s.isCandidate then
			print(string.format(
				"[CANDIDATE] CLASS: %s | NAME: %s | ENABLED: %s\n  PATH: %s\n  SOURCE: %s",
				s.className, s.name, s.enabled, s.path, s.sourceStatus
			))
		end
	end

	-- 2. === MODULES ===
	print("\n=== MODULES ===")
	print(string.format("Total ModuleScripts escaneados: %d", #Inventory.Modules))
	for _, m in ipairs(Inventory.Modules) do
		if m.isCandidate then
			print(string.format(
				"[CANDIDATE] CLASS: %s | NAME: %s | ENABLED: %s\n  PATH: %s\n  SOURCE: %s",
				m.className, m.name, m.enabled, m.path, m.sourceStatus
			))
		end
	end

	print("\n===== SCRIPT/MODULE CANDIDATES =====")
	if #Inventory.ScriptCandidates == 0 then
		print("  (Nenhum Script/Module com nome correspondente encontrado)")
	else
		for _, c in ipairs(Inventory.ScriptCandidates) do
			print(string.format(
				"CLASS: %s\nPATH: %s\nNAME: %s\nENABLED: %s\nSOURCE: %s\n",
				c.className, c.path, c.name, c.enabled, c.sourceStatus
			))
		end
	end

	print("----- MAPA DE DEPENDÊNCIAS VISÍVEIS -----")
	print("Nota: Grafo interno de require() e upvalues em memória: NOT OBSERVABLE WITH CURRENT ACCESS")
	if #Inventory.Dependencies == 0 then
		print("  (Nenhuma ObjectValue/Atributo/Filho visível nos scripts escaneados)")
	else
		for _, dep in ipairs(Inventory.Dependencies) do
			local isRel, _ = matchesKeywords(dep.ownerPath, SCRIPT_KEYWORDS)
			if isRel then
				print(string.format("Owner: %s (%s)", dep.ownerPath, dep.ownerClass))
				for _, item in ipairs(dep.items) do
					print("  -> " .. item)
				end
			end
		end
	end

	-- 3. === REMOTES ===
	print("\n=== REMOTES ===")
	print("Nota: Interceptação passiva de FireServer/InvokeServer: NOT OBSERVABLE WITH CURRENT ACCESS")
	for _, r in ipairs(Inventory.Remotes) do
		local tag = r.isCandidate and "[CANDIDATE] " or ""
		print(string.format("%sCLASS: %-22s | NAME: %-20s | PATH: %s", tag, r.className, r.name, r.path))
	end

	-- 4. === STATES ===
	print("\n=== STATES ===")
	if #Inventory.States == 0 then
		print("  (Nenhum State/Attribute correspondente encontrado)")
	else
		for _, st in ipairs(Inventory.States) do
			local tag = st.isCandidate and "[CANDIDATE] " or ""
			print(string.format("%s[%s] %s = %s", tag, st.kind, st.path, st.value))
		end
	end

	-- 5. === STAR UI TREE ===
	print("\n=== STAR UI TREE ===")
	local starLines = dumpUiTree(starFrame, "PlayerGui.UI.Frames.Star")
	for _, l in ipairs(starLines) do
		print(l)
	end

	-- 6. === ROLLING UI TREE ===
	print("\n=== ROLLING UI TREE ===")
	local rollingLines = dumpUiTree(rollingGui, "PlayerGui.Rolling")
	for _, l in ipairs(rollingLines) do
		print(l)
	end
	local starAnimLines = dumpUiTree(starAnimGui, "PlayerGui.StarAnimation")
	for _, l in ipairs(starAnimLines) do
		print(l)
	end

	-- 7. === ANIMATION OBJECTS ===
	print("\n=== ANIMATION OBJECTS ===")
	if #Inventory.AnimationObjects == 0 then
		print("  (Nenhum Animator/Animation/ViewportFrame relevante encontrado)")
	else
		for _, anim in ipairs(Inventory.AnimationObjects) do
			print(string.format("[%s] %s (%s)%s", anim.className, anim.path, anim.uid, anim.extra))
		end
	end

	-- 8. === ROLL TRACE ===
	print("\n=== ROLL TRACE ===")
	if #Inventory.LastRollTrace == 0 then
		print("  (Nenhum Roll Trace capturado ainda. Clique em [CAPTURE ROLL] e abra uma Star!)")
	else
		for _, tLine in ipairs(Inventory.LastRollTrace) do
			print("\n" .. tLine)
		end
	end

	-- 9. === TOP CANDIDATES ===
	print("\n=== TOP CANDIDATES ===")
	print("===== TOP CANDIDATES =====")
	local sortedCandidates = {}
	for _, rec in pairs(CandidateRegistry) do
		table.insert(sortedCandidates, rec)
	end
	table.sort(sortedCandidates, function(a, b)
		return a.score > b.score
	end)

	if #sortedCandidates == 0 then
		print("  (Sem candidatos pontuados até o momento)")
	else
		for i = 1, math.min(25, #sortedCandidates) do
			local c = sortedCandidates[i]
			local reasonList = {}
			for r in pairs(c.reasons) do
				table.insert(reasonList, r)
			end
			table.sort(reasonList)
			print(string.format(
				"#%02d [Score: %d | Eventos Runtime: %d] [%s] %s\n    Evidências: %s",
				i, c.score, c.changeCount, c.className, c.path, table.concat(reasonList, " + ")
			))
		end
	end
	print("======================================================================\n")
end

-- Expõe globalmente caso queira chamar pelo console/executor
pcall(function()
	(_G :: any).printFullReport = printFullReport
end)

-- ============================================================================
-- INTERFACE GRÁFICA DO INSPECTOR
-- ============================================================================
local function createInspectorUI()
	local parentGui = PlayerGui
	pcall(function()
		for _, oldName in ipairs({ INSPECTOR_GUI_NAME, "StarTimingDiagnosticUI", "StarSpeedProfilerUI" }) do
			if CoreGui:FindFirstChild(oldName) then
				CoreGui[oldName]:Destroy()
			end
		end
		parentGui = CoreGui
	end)
	if PlayerGui:FindFirstChild(INSPECTOR_GUI_NAME) then
		PlayerGui[INSPECTOR_GUI_NAME]:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = INSPECTOR_GUI_NAME
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = parentGui

	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 355, 0, 395)
	mainFrame.Position = UDim2.new(0.02, 0, 0.22, 0)
	mainFrame.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	mainFrame.BorderSizePixel = 0
	mainFrame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = mainFrame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 100, 140)
	stroke.Thickness = 1.5
	stroke.Parent = mainFrame

	local titleBar = Instance.new("Frame")
	titleBar.Size = UDim2.new(1, 0, 0, 30)
	titleBar.BackgroundColor3 = Color3.fromRGB(28, 34, 46)
	titleBar.BorderSizePixel = 0
	titleBar.Parent = mainFrame

	local titleCorner = Instance.new("UICorner")
	titleCorner.CornerRadius = UDim.new(0, 8)
	titleCorner.Parent = titleBar

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -40, 1, 0)
	titleLabel.Position = UDim2.new(0, 10, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.Text = "ANIME LEGACY GACHA INSPECTOR"
	titleLabel.TextColor3 = Color3.fromRGB(240, 245, 255)
	titleLabel.TextSize = 12
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Parent = titleBar

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0, 28, 0, 28)
	closeBtn.Position = UDim2.new(1, -29, 0, 1)
	closeBtn.BackgroundTransparency = 1
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.Text = "X"
	closeBtn.TextColor3 = Color3.fromRGB(255, 95, 95)
	closeBtn.TextSize = 14
	closeBtn.Parent = titleBar

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Position = UDim2.new(0, 12, 0, 36)
	statusLabel.Size = UDim2.new(1, -24, 0, 200)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.RobotoMono
	statusLabel.TextColor3 = Color3.fromRGB(225, 230, 240)
	statusLabel.TextSize = 12
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextYAlignment = Enum.TextYAlignment.Top
	statusLabel.RichText = true
	statusLabel.Parent = mainFrame

	local function makeButton(text: string, pos: UDim2, size: UDim2, color: Color3): TextButton
		local btn = Instance.new("TextButton")
		btn.Size = size
		btn.Position = pos
		btn.BackgroundColor3 = color
		btn.Font = Enum.Font.GothamBold
		btn.Text = text
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.TextSize = 11
		btn.AutoButtonColor = true
		btn.Parent = mainFrame

		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 5)
		c.Parent = btn
		return btn
	end

	-- Linha 1: [CAPTURE ROLL] (3 segundos)
	local captureRollBtn = makeButton("[CAPTURE ROLL (3.0s)]", UDim2.new(0, 10, 0, 242), UDim2.new(1, -20, 0, 32), Color3.fromRGB(40, 140, 80))

	-- Linha 2: Modo Diff ([SNAPSHOT A], [SNAPSHOT B], [COMPARE])
	local snapABtn   = makeButton("[SNAPSHOT A]", UDim2.new(0, 10, 0, 280),  UDim2.new(0, 106, 0, 30), Color3.fromRGB(55, 95, 160))
	local snapBBtn   = makeButton("[SNAPSHOT B]", UDim2.new(0, 124, 0, 280), UDim2.new(0, 106, 0, 30), Color3.fromRGB(55, 95, 160))
	local compareBtn = makeButton("[COMPARE]",    UDim2.new(0, 238, 0, 280), UDim2.new(0, 107, 0, 30), Color3.fromRGB(165, 105, 45))

	-- Linha 3: Dumps específicos (UI Trees / Remotes & States)
	local dumpUiBtn  = makeButton("DUMP UI TREES", UDim2.new(0, 10, 0, 316),  UDim2.new(0, 162, 0, 30), Color3.fromRGB(70, 80, 105))
	local rescanBtn  = makeButton("RESCAN INVENTORY", UDim2.new(0, 183, 0, 316), UDim2.new(0, 162, 0, 30), Color3.fromRGB(70, 80, 105))

	-- Linha 4: Relatório Completo printFullReport()
	local fullRepBtn = makeButton("[PRINT FULL REPORT (F9)]", UDim2.new(0, 10, 0, 352), UDim2.new(1, -20, 0, 32), Color3.fromRGB(115, 75, 165))

	local function refreshStatusText(extraBanner: string?)
		local starFrame, rollingGui, starAnimGui = getTargetUiRoots()
		local pityLabel = starFrame and starFrame:FindFirstChild("Pity") and starFrame.Pity:FindFirstChild("Value")
		local pityStr = (pityLabel and pityLabel:IsA("TextLabel")) and pityLabel.Text or "N/A"

		local snapAStatus = Inventory.SnapshotA and "OK" or "Vazio"
		local snapBStatus = Inventory.SnapshotB and "OK" or "Vazio"

		statusLabel.Text = string.format(
			"STATUS: <b>%s</b>\n" ..
			"PITY ATUAL: %s\n\n" ..
			"SCRIPTS: %d | MODULES: %d (Cand: %d)\n" ..
			"REMOTES: %d | STATES: %d\n" ..
			"ANIM OBJECTS: %d\n\n" ..
			"UI ROOTS DETECTADAS:\n" ..
			"  Frames.Star:   %s\n" ..
			"  Rolling:       %s\n" ..
			"  StarAnimation: %s\n\n" ..
			"ROLL TRACE EVENTS: %d\n" ..
			"SNAPSHOT A: %s | SNAPSHOT B: %s",
			extraBanner or (Inventory.IsCapturingRoll and '<font color="#ffaa00">CAPTURANDO ROLL (3.0s)...</font>' or '<font color="#55ff7f">PRONTO (READ-ONLY)</font>'),
			pityStr,
			#Inventory.Scripts, #Inventory.Modules, #Inventory.ScriptCandidates,
			#Inventory.Remotes, #Inventory.States,
			#Inventory.AnimationObjects,
			starFrame and "SIM" or "NÃO",
			rollingGui and "SIM" or "NÃO",
			starAnimGui and "SIM" or "NÃO",
			#Inventory.LastRollTrace,
			snapAStatus, snapBStatus
		)
	end

	-- Dragging
	local dragging, dragInput, dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
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
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)
	table.insert(Connections, UserInputService.InputChanged:Connect(function(input)
		if input == dragInput and dragging then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end))

	-- Ações dos Botões
	captureRollBtn.MouseButton1Click:Connect(function()
		refreshStatusText('<font color="#ffaa00">CAPTURANDO ROLL (3.0s)...</font>')
		runRollCapture(function()
			refreshStatusText('<font color="#55ff7f">ROLL TRACE CONCLUÍDO (F9)</font>')
		end)
	end)

	snapABtn.MouseButton1Click:Connect(function()
		Inventory.SnapshotA = takeStateSnapshot("SNAPSHOT A")
		refreshStatusText('<font color="#55aaff">SNAPSHOT A SALVO</font>')
	end)

	snapBBtn.MouseButton1Click:Connect(function()
		Inventory.SnapshotB = takeStateSnapshot("SNAPSHOT B")
		refreshStatusText('<font color="#55aaff">SNAPSHOT B SALVO</font>')
	end)

	compareBtn.MouseButton1Click:Connect(function()
		compareSnapshots()
		refreshStatusText('<font color="#ffaa55">DIFF A/B IMPRESSO NO F9</font>')
	end)

	dumpUiBtn.MouseButton1Click:Connect(function()
		local starFrame, rollingGui, starAnimGui = getTargetUiRoots()
		print("\n=== STAR UI TREE ===")
		for _, l in ipairs(dumpUiTree(starFrame, "PlayerGui.UI.Frames.Star")) do print(l) end
		print("\n=== ROLLING UI TREE ===")
		for _, l in ipairs(dumpUiTree(rollingGui, "PlayerGui.Rolling")) do print(l) end
		for _, l in ipairs(dumpUiTree(starAnimGui, "PlayerGui.StarAnimation")) do print(l) end
		refreshStatusText('<font color="#55ff7f">UI TREES IMPRESSAS NO F9</font>')
	end)

	rescanBtn.MouseButton1Click:Connect(function()
		scanAllStaticInventories()
		refreshStatusText('<font color="#55ff7f">INVENTÁRIO ATUALIZADO</font>')
	end)

	fullRepBtn.MouseButton1Click:Connect(function()
		printFullReport()
		refreshStatusText('<font color="#55ff7f">FULL REPORT IMPRESSO NO F9</font>')
	end)

	closeBtn.MouseButton1Click:Connect(function()
		stopRollCaptureConnections()
		for _, c in ipairs(Connections) do
			if c.Connected then c:Disconnect() end
		end
		table.clear(Connections)
		screenGui:Destroy()
		print("[INSPECTOR] Encerrado e todas as conexões foram limpas.")
	end)

	scanAllStaticInventories()
	refreshStatusText()
end

-- ============================================================================
-- INICIALIZAÇÃO
-- ============================================================================
createInspectorUI()
print("[ANIME LEGACY INSPECTOR] Carregado! Use os botões da UI ou chame _G.printFullReport() para gerar o relatório completo.")
