--[[
    STAR TIMING DIAGNOSTIC v5 (MULTI-LAYER INPUT & LOCAL GATING INSPECTOR)
    Jogo alvo: Anime Legacy Simulator
    Modo: 100% Read-Only (Sem FireServer, sem InvokeServer, sem hooks de metamétodos, sem alterar valores)
    Objetivo:
      1. Verificar se todos os cliques físicos no MAX realmente chegam ao GuiButton ou se são bloqueados na UI.
      2. Detectar se o botão MAX é recriado (nova Instance), ocultado ou desativado durante o giro.
      3. Identificar possíveis Flags/Estados locais (Gating) na janela de 1.5s após cada clique.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local PlayerScripts = LocalPlayer:FindFirstChild("PlayerScripts")

-- ============================================================================
-- CONFIGURAÇÕES PRINCIPAIS
-- ============================================================================
local DEBUG = true

-- Janela (em segundos) para agrupar MouseButton1Down + MouseButton1Up + Activated
-- como um único clique físico processado pelo botão
local PHYSICAL_CLICK_GROUP_WINDOW = 0.18

-- Janela (em segundos) após um clique em MAX para observar mudanças de estado/flags (Gating)
local POST_CLICK_GATE_WINDOW = 1.50

-- Evita leituras duplicadas se o texto do Pity atualizar duas vezes no mesmo frame
local PITY_DEDUP_WINDOW = 0.06

local DEFAULT_MAX_DELTA = 9

local GATE_KEYWORDS = {
	"opening", "isopening", "open", "canopen", "busy", "ready",
	"cooldown", "debounce", "rolling", "isrolling", "summoning", "auto", "star"
}

local IGNORE_KEYWORDS = {
	"timer", "fps", "ping", "clock", "timeleft", "refresh",
	"chat", "bubble", "health", "xp", "quest", "index", "music", "sound"
}

-- ============================================================================
-- RASTREADOR DE IDENTIDADE DE INSTÂNCIAS (UID)
-- Permite saber se um objeto com o mesmo Path é uma nova Instance recriada
-- ============================================================================
local InstanceUIDMap = setmetatable({}, { __mode = "k" }) :: {[Instance]: number}
local NextInstanceUID = 0

local function getInstanceUID(inst: Instance): string
	local uid = InstanceUIDMap[inst]
	if not uid then
		NextInstanceUID += 1
		uid = NextInstanceUID
		InstanceUIDMap[inst] = uid
	end
	return "#" .. tostring(uid)
end

-- ============================================================================
-- ESTADO GLOBAL E MÉTRICAS DA V5
-- ============================================================================
export type CycleFlagLog = {
	path: string,
	oldVal: string,
	newVal: string,
	timestamp: number,
}

export type GateCandidateStats = {
	path: string,
	activationsAfterClick: number,
	releasesBeforeNext: number,
	lastActivatedTime: number?,
	lastReleaseTime: number?,
	lastHoldDuration: number,
	activeValue: any,
}

local State = {
	IsRunning = false,

	-- Contadores diferenciados (Item 5)
	RawMouseClicks = 0,          -- Cliques globais do mouse (qualquer lugar)
	PhysicalMaxClicks = 0,       -- Cliques físicos confirmados sobre a área/botão MAX
	ButtonEventsCount = 0,       -- Total bruto de eventos (Down + Up + Activated) disparados pelo botão
	GroupedButtonMaxClicks = 0,  -- Cliques físicos nos quais o botão MAX realmente respondeu com evento
	ButtonActivatedCount = 0,    -- Quantas vezes especificamente o evento .Activated disparou no MAX

	-- Contadores oficiais (via Pity - Item 6)
	RealOpenings = 0,
	RealRolls = 0,

	-- Timestamps e Intervalos
	LastPhysicalMaxClickTime = nil :: number?,
	LastGroupedBtnEventTime = nil :: number?,
	LastPityTime = nil :: number?,
	MinClickToClick = math.huge,
	MinPityToPity = math.huge,
	LastClickToPity = 0,
	LastPityToPity = 0,

	ClickIntervals = {} :: {number},
	ButtonClickIntervals = {} :: {number},
	PityIntervals = {} :: {number},

	-- Dados acumulados no Ciclo Atual (para o relatório CYCLE #N no F9)
	CycleRawMaxClicks = {} :: {number},
	CycleButtonActivated = {} :: {number},
	CycleButtonEvents = {} :: {string},
	CycleFlags = {} :: {CycleFlagLog},

	-- Pity
	LastPityValue = nil :: number?,
	LastPityMax = nil :: number?,
	PityPath = "Procurando...",

	-- Rastreamento de Botões e Caixas Geométricas (para detectar cliques mesmo se oculto/coberto)
	CurrentMaxButton = nil :: GuiObject?,
	CurrentMaxButtonUID = nil :: string?,
	CurrentMaxButtonPath = "Não encontrado",
	LastKnownMaxAbsPos = nil :: Vector2?,
	LastKnownMaxAbsSize = nil :: Vector2?,
	MaxButtonReplacements = 0,
	BlockedOverlayClicks = 0,

	-- Gating Local (Item 4)
	GateCandidates = {} :: {[string]: GateCandidateStats},
	BestGateCandidate = "NENHUM",
}

local Connections = {} :: {RBXScriptConnection}
local WatchedInstances = setmetatable({}, { __mode = "k" }) :: {[Instance]: boolean}

-- ============================================================================
-- FUNÇÕES UTILITÁRIAS
-- ============================================================================
local function getCleanPath(inst: Instance): string
	local parts = {}
	local current: Instance? = inst
	while current and current ~= game and current ~= LocalPlayer do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end
	return table.concat(parts, ".")
end

local function containsKeyword(str: string, list: {string}): boolean
	local lower = string.lower(str)
	for _, w in ipairs(list) do
		if string.find(lower, w, 1, true) then
			return true
		end
	end
	return false
end

local function getAverage(list: {number}): number
	if #list == 0 then return 0 end
	local s = 0
	for _, v in ipairs(list) do
		s += v
	end
	return s / #list
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

-- Identifica se uma instância pertence à hierarquia de MAX, SINGLE ou AUTO
local function classifyStarButtonHierarchy(inst: Instance): string?
	local curr: Instance? = inst
	while curr and curr ~= PlayerGui and curr.Name ~= "Star" and curr.Name ~= "Frames" do
		local n = string.lower(curr.Name)
		if n == "max" or string.find(n, "max", 1, true) or string.find(n, "multi", 1, true) then
			return "MAX"
		elseif n == "single" or string.find(n, "single", 1, true) or n == "1x" or n == "one" then
			return "SINGLE"
		elseif n == "auto" or string.find(n, "auto", 1, true) then
			return "AUTO"
		end
		curr = curr.Parent
	end

	-- Fallback pelo texto interno caso o botão tenha nome genérico
	if inst:IsA("GuiObject") then
		for _, desc in ipairs(inst:GetDescendants()) do
			if desc:IsA("TextLabel") and desc.Text ~= "" then
				local t = string.lower(desc.Text)
				if string.find(t, "max", 1, true) then return "MAX" end
				if string.find(t, "single", 1, true) then return "SINGLE" end
				if string.find(t, "auto", 1, true) then return "AUTO" end
			end
		end
	end
	return nil
end

-- ============================================================================
-- 4. MOTOR DE DETECÇÃO DE GATING LOCAL (JANELA DE 1.5s PÓS-CLIQUE)
-- ============================================================================
local function updateBestGateCandidate()
	local bestPath = "NENHUM"
	local bestScore = 0

	for path, info in pairs(State.GateCandidates) do
		-- Pontua candidatos que ativam logo após o clique e liberam próximo de ~1s
		local score = math.min(info.activationsAfterClick, info.releasesBeforeNext)
		if score >= 2 and score > bestScore then
			bestScore = score
			bestPath = string.format("%s (%.2fs | %dx)", path, info.lastHoldDuration, score)
		end
	end

	State.BestGateCandidate = bestPath
end

local function recordStateTransition(path: string, oldVal: any, newVal: any)
	local now = os.clock()
	local oldStr = tostring(oldVal)
	local newStr = tostring(newVal)

	-- Registra na timeline do ciclo atual se ocorreu perto de um clique ou durante uma abertura
	local timeSinceMaxClick = State.LastPhysicalMaxClickTime and (now - State.LastPhysicalMaxClickTime) or math.huge
	local timeSincePity = State.LastPityTime and (now - State.LastPityTime) or math.huge

	if timeSinceMaxClick <= POST_CLICK_GATE_WINDOW or timeSincePity <= POST_CLICK_GATE_WINDOW then
		table.insert(State.CycleFlags, {
			path = path,
			oldVal = oldStr,
			newVal = newStr,
			timestamp = now,
		})
	end

	-- Análise de correlação de Gating
	local cand = State.GateCandidates[path]
	if not cand then
		cand = {
			path = path,
			activationsAfterClick = 0,
			releasesBeforeNext = 0,
			lastActivatedTime = nil,
			lastReleaseTime = nil,
			lastHoldDuration = 0,
			activeValue = nil,
		}
		State.GateCandidates[path] = cand
	end

	-- Se a mudança ocorreu logo após um clique físico em MAX (ex: até 0.25s depois do clique)
	if timeSinceMaxClick <= 0.25 then
		cand.activationsAfterClick += 1
		cand.lastActivatedTime = now
		cand.activeValue = newVal
	elseif cand.lastActivatedTime and newVal ~= cand.activeValue then
		-- O estado voltou ao normal antes/perto da próxima abertura!
		local holdTime = now - cand.lastActivatedTime
		if holdTime >= 0.30 and holdTime <= 1.60 then
			cand.releasesBeforeNext += 1
			cand.lastReleaseTime = now
			cand.lastHoldDuration = holdTime
			updateBestGateCandidate()

			if DEBUG then
				print(string.format(
					"[GATE CANDIDATE MATCH] %s\n  Retornou para %s após %.3fs (Ativações: %d | Liberações: %d)",
					path, newStr, holdTime, cand.activationsAfterClick, cand.releasesBeforeNext
				))
			end
		end
		cand.lastActivatedTime = nil
	end

	if DEBUG and (timeSinceMaxClick <= POST_CLICK_GATE_WINDOW) then
		print(string.format(
			"[LOCAL STATE CHANGE] T = %.3f (+%.3fs após MAX click)\n  Path: %s\n  %s -> %s",
			now, timeSinceMaxClick, path, oldStr, newStr
		))
	end
end

-- ============================================================================
-- 1 & 3. MONITORAMENTO DE BOTÕES E SUBSTITUIÇÃO DE INSTANCE
-- ============================================================================
local function watchButtonProperties(guiObj: GuiObject, path: string, kind: string)
	local propKey = "props_" .. getInstanceUID(guiObj)
	if WatchedInstances[propKey :: any] then return end
	WatchedInstances[propKey :: any] = true

	local function logMaxState(propName: string, oldV: any, newV: any)
		local now = os.clock()
		if DEBUG then
			print(string.format(
				"[%s BUTTON STATE] Propriedade '%s' mudou\n  Path: %s [%s]\n  Old: %s -> New: %s\n  T = %.3f",
				kind, propName, path, getInstanceUID(guiObj), tostring(oldV), tostring(newV), now
			))
		end
		recordStateTransition(path .. "." .. propName, oldV, newV)
	end

	-- Monitora Visible, Active, Selectable, AutoButtonColor e Interactable
	local lastVis = guiObj.Visible
	table.insert(Connections, guiObj:GetPropertyChangedSignal("Visible"):Connect(function()
		local v = guiObj.Visible
		logMaxState("Visible", lastVis, v)
		lastVis = v
	end))

	local lastAct = guiObj.Active
	table.insert(Connections, guiObj:GetPropertyChangedSignal("Active"):Connect(function()
		local v = guiObj.Active
		logMaxState("Active", lastAct, v)
		lastAct = v
	end))

	local lastSel = guiObj.Selectable
	table.insert(Connections, guiObj:GetPropertyChangedSignal("Selectable"):Connect(function()
		local v = guiObj.Selectable
		logMaxState("Selectable", lastSel, v)
		lastSel = v
	end))

	-- Interactable (protegido por pcall para máxima compatibilidade)
	pcall(function()
		local lastInt = (guiObj :: any).Interactable
		table.insert(Connections, guiObj:GetPropertyChangedSignal("Interactable"):Connect(function()
			local v = (guiObj :: any).Interactable
			logMaxState("Interactable", lastInt, v)
			lastInt = v
		end))
	end)

	if guiObj:IsA("GuiButton") then
		local lastAbc = guiObj.AutoButtonColor
		table.insert(Connections, guiObj:GetPropertyChangedSignal("AutoButtonColor"):Connect(function()
			local v = guiObj.AutoButtonColor
			logMaxState("AutoButtonColor", lastAbc, v)
			lastAbc = v
		end))
	end

	-- Monitora remoção / troca de Parent
	table.insert(Connections, guiObj.AncestryChanged:Connect(function(_, newParent)
		if not newParent or not guiObj:IsDescendantOf(PlayerGui) then
			if DEBUG then
				print(string.format(
					"[%s BUTTON STATE] Botão removido da árvore!\n  Path antigo: %s [%s]\n  Novo Parent: %s\n  T = %.3f",
					kind, path, getInstanceUID(guiObj), tostring(newParent), os.clock()
				))
			end
		end
	end))
end

local function hookGuiButtonEvents(btn: GuiButton, kind: string)
	if WatchedInstances[btn] then return end
	WatchedInstances[btn] = true

	local path = getCleanPath(btn)
	local uid = getInstanceUID(btn)

	-- Detecta se o botão MAX principal foi substituído por uma nova Instance
	if kind == "MAX" then
		if State.CurrentMaxButton and State.CurrentMaxButton ~= btn then
			State.MaxButtonReplacements += 1
			if DEBUG then
				print(string.format(
					"\n[MAX BUTTON STATE]\nInstance mudou!\nOld: %s [%s]\nNew: %s [%s]\nT = %.3f\n",
					State.CurrentMaxButtonPath,
					tostring(State.CurrentMaxButtonUID),
					path,
					uid,
					os.clock()
				))
			end
		end
		State.CurrentMaxButton = btn
		State.CurrentMaxButtonUID = uid
		State.CurrentMaxButtonPath = path
		if btn.AbsoluteSize.X > 0 and btn.AbsoluteSize.Y > 0 then
			State.LastKnownMaxAbsPos = btn.AbsolutePosition
			State.LastKnownMaxAbsSize = btn.AbsoluteSize
		end
	end

	if DEBUG then
		print(string.format("[BUTTON HOOKED] %s -> %s [%s]", kind, path, uid))
	end

	watchButtonProperties(btn, path, kind)

	-- Camada A: Eventos individuais do próprio botão (MouseButton1Down, MouseButton1Up, Activated)
	local function onRawButtonEvent(eventName: string)
		local now = os.clock()

		-- Atualiza caixa geométrica conhecida do MAX
		if kind == "MAX" and btn.AbsoluteSize.X > 0 then
			State.LastKnownMaxAbsPos = btn.AbsolutePosition
			State.LastKnownMaxAbsSize = btn.AbsoluteSize
		end

		if State.IsRunning and kind == "MAX" then
			State.ButtonEventsCount += 1
			if eventName == "Activated" then
				State.ButtonActivatedCount += 1
				table.insert(State.CycleButtonActivated, now)
			end
			table.insert(State.CycleButtonEvents, string.format("%s @ %.3f", eventName, now))
		end

		if DEBUG then
			print(string.format("[BUTTON EVENT]\n%s (%s [%s])\n%s\nT=%.3f", kind, path, uid, eventName, now))
		end

		-- Agrupamento em Clique Físico Processado pelo Botão (PHYSICAL_CLICK_GROUP_WINDOW = 0.18s)
		if kind == "MAX" and (eventName == "MouseButton1Down" or eventName == "Activated") then
			local lastGrp = State.LastGroupedBtnEventTime
			if not lastGrp or (now - lastGrp) > PHYSICAL_CLICK_GROUP_WINDOW then
				if lastGrp and State.IsRunning then
					table.insert(State.ButtonClickIntervals, now - lastGrp)
				end
				State.LastGroupedBtnEventTime = now
				if State.IsRunning then
					State.GroupedButtonMaxClicks += 1
				end

				-- Caso o clique não tenha sido pego antes pelo InputBegan, garante registro como PhysicalMaxClick
				if not State.LastPhysicalMaxClickTime or (now - State.LastPhysicalMaxClickTime) > PHYSICAL_CLICK_GROUP_WINDOW then
					if State.LastPhysicalMaxClickTime and State.IsRunning then
						local cDelta = now - State.LastPhysicalMaxClickTime
						table.insert(State.ClickIntervals, cDelta)
						if cDelta < State.MinClickToClick then
							State.MinClickToClick = cDelta
						end
					end
					State.LastPhysicalMaxClickTime = now
					if State.IsRunning then
						State.PhysicalMaxClicks += 1
						table.insert(State.CycleRawMaxClicks, now)
					end
				end
			end
		end
	end

	table.insert(Connections, btn.MouseButton1Down:Connect(function()
		onRawButtonEvent("MouseButton1Down")
	end))
	table.insert(Connections, btn.MouseButton1Up:Connect(function()
		onRawButtonEvent("MouseButton1Up")
	end))
	table.insert(Connections, btn.Activated:Connect(function()
		onRawButtonEvent("Activated")
	end))
end

-- ============================================================================
-- 2. CAPTURA GLOBAL DO MOUSE (UserInputService + GetGuiObjectsAtPosition)
-- ============================================================================
local function isPointInsideLastMaxRect(screenPos: Vector2, inset: Vector2): boolean
	if not State.LastKnownMaxAbsPos or not State.LastKnownMaxAbsSize then
		return false
	end
	local pos = State.LastKnownMaxAbsPos
	local size = State.LastKnownMaxAbsSize

	-- Testa tanto com coordenada descontando o GuiInset quanto bruta (para ScreenGuis com IgnoreGuiInset)
	for _, testPt in ipairs({ screenPos - inset, screenPos }) do
		if testPt.X >= pos.X and testPt.X <= (pos.X + size.X)
			and testPt.Y >= pos.Y and testPt.Y <= (pos.Y + size.Y) then
			return true
		end
	end
	return false
end

local function setupGlobalMouseCapture()
	local conn = UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local now = os.clock()
		local mouseLoc = UserInputService:GetMouseLocation()
		local inset = GuiService:GetGuiInset()

		-- Ignora cliques feitos dentro da nossa própria janela de diagnóstico
		local hitGuis = {} :: {GuiObject}
		local seen = {} :: {[GuiObject]: boolean}

		pcall(function()
			-- Consulta na coordenada ajustada pelo Topbar Inset e na coordenada bruta
			local listA = PlayerGui:GetGuiObjectsAtPosition(mouseLoc.X - inset.X, mouseLoc.Y - inset.Y)
			local listB = PlayerGui:GetGuiObjectsAtPosition(mouseLoc.X, mouseLoc.Y)
			for _, g in ipairs(listA) do
				if not seen[g] then seen[g] = true; table.insert(hitGuis, g) end
			end
			for _, g in ipairs(listB) do
				if not seen[g] then seen[g] = true; table.insert(hitGuis, g) end
			end
		end)

		local topPaths = {}
		local hitMaxHierarchy = false
		local hitSingleHierarchy = false
		local hitAutoHierarchy = false

		for i, g in ipairs(hitGuis) do
			local p = getCleanPath(g)
			if string.find(p, "StarTimingDiagnosticUI", 1, true) then
				return -- Clique na UI do próprio script, ignora completamente
			end
			if i <= 6 then
				table.insert(topPaths, string.format("  %s [%s] (Active=%s)", p, getInstanceUID(g), tostring(g.Active)))
			end

			local bKind = classifyStarButtonHierarchy(g)
			if bKind == "MAX" then hitMaxHierarchy = true
			elseif bKind == "SINGLE" then hitSingleHierarchy = true
			elseif bKind == "AUTO" then hitAutoHierarchy = true
			end
		end

		if State.IsRunning then
			State.RawMouseClicks += 1
		end

		local insideMaxGeometricBox = isPointInsideLastMaxRect(mouseLoc, inset)
		local classification = "OTHER_CLICK"

		if hitMaxHierarchy then
			classification = "MAX_CLICK_RAW"
		elseif insideMaxGeometricBox then
			-- O cursor clicou exatamente na coordenada do botão MAX, mas o botão MAX estava oculto/removido!
			classification = "MAX_CLICK_RAW (GEOMETRIC_HIT_BUTTON_HIDDEN_OR_REPLACED)"
			if State.IsRunning then
				State.BlockedOverlayClicks += 1
			end
		elseif hitSingleHierarchy then
			classification = "SINGLE_CLICK_RAW"
		elseif hitAutoHierarchy then
			classification = "AUTO_CLICK_RAW"
		end

		if string.find(classification, "MAX_CLICK_RAW", 1, true) then
			if State.LastPhysicalMaxClickTime ~= nil then
				local cDelta = now - State.LastPhysicalMaxClickTime
				if State.IsRunning then
					table.insert(State.ClickIntervals, cDelta)
					if cDelta < State.MinClickToClick then
						State.MinClickToClick = cDelta
					end
				end
			end
			State.LastPhysicalMaxClickTime = now

			if State.IsRunning then
				State.PhysicalMaxClicks += 1
				table.insert(State.CycleRawMaxClicks, now)
			end
		end

		if DEBUG and (classification ~= "OTHER_CLICK" or #topPaths > 0) then
			local guiListStr = (#topPaths > 0) and table.concat(topPaths, "\n") or "  (Nenhum GuiObject visível no PlayerGui)"
			print(string.format(
				"[RAW MOUSE INPUT]\nT = %.3f\nMouse = %d, %d\n\nGUI sob cursor:\n%s\n\nCLASSIFICAÇÃO:\n%s",
				now, math.floor(mouseLoc.X), math.floor(mouseLoc.Y), guiListStr, classification
			))
		end
	end)

	table.insert(Connections, conn)
end

-- ============================================================================
-- 6 & 7. FONTE DE VERDADE: PITY & TIMELINE POR CICLO
-- ============================================================================
local function onPityTextChanged(rawText: string)
	local newCur, newMax = parsePityNumbers(rawText)
	if not newCur then return end

	if State.LastPityValue == nil then
		State.LastPityValue = newCur
		State.LastPityMax = newMax
		if DEBUG then
			print(string.format("[PITY SYNC] Valor inicial: %d/%s", newCur, tostring(newMax or "?")))
		end
		return
	end

	local oldCur = State.LastPityValue
	local oldMax = State.LastPityMax or newMax
	if newCur == oldCur then return end

	local now = os.clock()
	if State.LastPityTime and (now - State.LastPityTime) < PITY_DEDUP_WINDOW then
		State.LastPityValue = newCur
		State.LastPityMax = newMax
		return
	end

	local delta = newCur - oldCur
	if delta <= 0 then
		if oldMax and ((oldMax - oldCur) + newCur) > 0 and ((oldMax - oldCur) + newCur) <= 20 then
			delta = (oldMax - oldCur) + newCur
		elseif newCur > 0 and newCur <= 20 then
			delta = newCur
		else
			delta = DEFAULT_MAX_DELTA
		end
	end

	local pityToPity: number? = nil
	if State.LastPityTime ~= nil then
		pityToPity = now - State.LastPityTime
		State.LastPityToPity = pityToPity
	end

	if State.LastPhysicalMaxClickTime ~= nil then
		State.LastClickToPity = now - State.LastPhysicalMaxClickTime
	end

	State.LastPityValue = newCur
	State.LastPityMax = newMax
	State.LastPityTime = now

	if State.IsRunning then
		State.RealOpenings += 1
		State.RealRolls += delta

		if pityToPity then
			table.insert(State.PityIntervals, pityToPity)
			if pityToPity < State.MinPityToPity then
				State.MinPityToPity = pityToPity
			end
		end
	end

	local cycleNum = State.IsRunning and State.RealOpenings or 0

	-- Formata listas do ciclo para o F9
	local rawClicksLines = {}
	for _, t in ipairs(State.CycleRawMaxClicks) do
		table.insert(rawClicksLines, string.format("%.3f", t))
	end

	local actLines = {}
	for _, t in ipairs(State.CycleButtonActivated) do
		table.insert(actLines, string.format("%.3f", t))
	end

	local flagLines = {}
	for _, fl in ipairs(State.CycleFlags) do
		table.insert(flagLines, string.format("%s: %s -> %s @ %.3f", fl.path, fl.oldVal, fl.newVal, fl.timestamp))
	end

	if DEBUG then
		print(string.format(
			"\n===== CYCLE #%d =====\n\n" ..
			"RAW MAX CLICKS:\n%s\n\n" ..
			"BUTTON ACTIVATED:\n%s\n\n" ..
			"FLAGS:\n%s\n\n" ..
			"PITY:\n%d -> %d (Delta: +%d)\n@ %.3f\n\n" ..
			"PITY -> PITY:\n%s\n\n" ..
			"Total cliques físicos nesse ciclo:\n%d\n" ..
			"=====================",
			cycleNum,
			(#rawClicksLines > 0) and table.concat(rawClicksLines, "\n") or "(Nenhum clique físico no MAX registrado neste ciclo)",
			(#actLines > 0) and table.concat(actLines, "\n") or "(Nenhum evento .Activated disparado neste ciclo)",
			(#flagLines > 0) and table.concat(flagLines, "\n") or "(Nenhuma mudança de flag/estado capturada)",
			oldCur, newCur, delta,
			now,
			pityToPity and string.format("%.3fs", pityToPity) or "1ª abertura da sessão",
			#State.CycleRawMaxClicks
		))
	end

	-- Limpa acumuladores do ciclo recém-fechado
	table.clear(State.CycleRawMaxClicks)
	table.clear(State.CycleButtonActivated)
	table.clear(State.CycleButtonEvents)
	table.clear(State.CycleFlags)
end

-- ============================================================================
-- ESCANEAMENTO DE ESTADOS LOCAIS, BOTÕES E PITY
-- ============================================================================
local function watchValueBase(valObj: ValueBase)
	if WatchedInstances[valObj] then return end
	if not (valObj:IsA("BoolValue") or valObj:IsA("IntValue") or valObj:IsA("NumberValue") or valObj:IsA("StringValue")) then
		return
	end

	local path = getCleanPath(valObj)
	if string.find(path, "Frames.Star.Pity", 1, true) then return end
	if containsKeyword(path, IGNORE_KEYWORDS) then return end
	if not containsKeyword(path, GATE_KEYWORDS) then return end

	WatchedInstances[valObj] = true
	local propObj = valObj :: any
	local lastVal = propObj.Value

	table.insert(Connections, propObj:GetPropertyChangedSignal("Value"):Connect(function()
		local newVal = propObj.Value
		if newVal ~= lastVal then
			local prev = lastVal
			lastVal = newVal
			recordStateTransition(path, prev, newVal)
		end
	end))
end

local function watchAttributes(inst: Instance, forceAll: boolean)
	local attrKey = "attr_" .. getInstanceUID(inst)
	if WatchedInstances[attrKey :: any] then return end

	local basePath = (inst == LocalPlayer) and "LocalPlayer" or getCleanPath(inst)
	if not forceAll and not containsKeyword(basePath, GATE_KEYWORDS) then
		local hasRelevant = false
		for k in pairs(inst:GetAttributes()) do
			if containsKeyword(k, GATE_KEYWORDS) then
				hasRelevant = true
				break
			end
		end
		if not hasRelevant then return end
	end

	WatchedInstances[attrKey :: any] = true
	local cached = inst:GetAttributes()

	table.insert(Connections, inst.AttributeChanged:Connect(function(attrName: string)
		local newVal = inst:GetAttribute(attrName)
		local oldVal = cached[attrName]
		cached[attrName] = newVal
		if containsKeyword(attrName, IGNORE_KEYWORDS) then return end
		if forceAll or containsKeyword(attrName, GATE_KEYWORDS) or containsKeyword(basePath, GATE_KEYWORDS) then
			recordStateTransition(basePath .. ".Attribute." .. attrName, oldVal, newVal)
		end
	end))
end

local function inspectStarDescendant(inst: Instance)
	local bKind = classifyStarButtonHierarchy(inst)
	if bKind then
		if inst:IsA("GuiButton") then
			hookGuiButtonEvents(inst, bKind)
		elseif inst:IsA("GuiObject") and bKind == "MAX" then
			watchButtonProperties(inst, getCleanPath(inst), "MAX_CONTAINER")
			if inst.AbsoluteSize.X > 0 and not State.LastKnownMaxAbsPos then
				State.LastKnownMaxAbsPos = inst.AbsolutePosition
				State.LastKnownMaxAbsSize = inst.AbsoluteSize
			end
		end
	end

	if inst:IsA("ValueBase") then
		watchValueBase(inst)
	end
	if containsKeyword(inst.Name, GATE_KEYWORDS) then
		watchAttributes(inst, true)
	end
end

local function clearConnections()
	for _, c in ipairs(Connections) do
		if c.Connected then
			c:Disconnect()
		end
	end
	table.clear(Connections)
	table.clear(WatchedInstances)
end

local function scanAndConnectAll()
	clearConnections()
	setupGlobalMouseCapture()

	-- 1. Conecta Pity (PlayerGui.UI.Frames.Star.Pity.Value)
	local ui = PlayerGui:FindFirstChild("UI")
	local frames = ui and ui:FindFirstChild("Frames")
	local starFrame = frames and frames:FindFirstChild("Star")
	local pityFolder = starFrame and starFrame:FindFirstChild("Pity")
	local pityTarget: Instance? = pityFolder and (pityFolder:FindFirstChild("Value") or (pityFolder:IsA("TextLabel") and pityFolder or nil))

	if not pityTarget then
		for _, desc in ipairs(PlayerGui:GetDescendants()) do
			if desc:IsA("TextLabel") and string.find(string.lower(desc.Text), "pity", 1, true) then
				pityTarget = desc
				break
			end
		end
	end

	if pityTarget then
		State.PityPath = getCleanPath(pityTarget)
		if pityTarget:IsA("TextLabel") then
			State.LastPityValue, State.LastPityMax = parsePityNumbers(pityTarget.Text)
			table.insert(Connections, pityTarget:GetPropertyChangedSignal("Text"):Connect(function()
				onPityTextChanged(pityTarget.Text)
			end))
		elseif pityTarget:IsA("ValueBase") then
			local vObj = pityTarget :: any
			State.LastPityValue, State.LastPityMax = parsePityNumbers(tostring(vObj.Value))
			table.insert(Connections, vObj:GetPropertyChangedSignal("Value"):Connect(function()
				onPityTextChanged(tostring(vObj.Value))
			end))
		end
		print(string.format("[STAR DIAGNOSTIC v5] Pity conectado: %s [%s]", State.PityPath, getInstanceUID(pityTarget)))
	else
		warn("[STAR DIAGNOSTIC v5] PlayerGui.UI.Frames.Star.Pity.Value não encontrado.")
	end

	-- 2. Monitora Frame Star, Buttons.Max e toda a sub-árvore de UI
	if starFrame then
		watchButtonProperties(starFrame, getCleanPath(starFrame), "STAR_FRAME")
		watchAttributes(starFrame, true)
		for _, desc in ipairs(starFrame:GetDescendants()) do
			inspectStarDescendant(desc)
		end
	end

	-- Monitora criação dinâmica de novos botões (caso Buttons.Max seja recriado durante o giro!)
	table.insert(Connections, PlayerGui.DescendantAdded:Connect(function(desc)
		inspectStarDescendant(desc)
		-- Faz uma segunda verificação no frame seguinte caso as propriedades/nomes sejam atribuídos depois do Parent
		task.defer(function()
			if desc and desc.Parent then
				inspectStarDescendant(desc)
			end
		end)
	end))

	-- 3. Monitora estados/flags em LocalPlayer, PlayerScripts, ReplicatedStorage e Workspace
	watchAttributes(LocalPlayer, true)
	local containers = { LocalPlayer, PlayerGui, ReplicatedStorage }
	if PlayerScripts then
		table.insert(containers, PlayerScripts)
	end

	for _, cont in ipairs(containers) do
		for _, desc in ipairs(cont:GetDescendants()) do
			if desc:IsA("ValueBase") then
				watchValueBase(desc)
			end
			if containsKeyword(desc.Name, GATE_KEYWORDS) then
				watchAttributes(desc, true)
			end
		end
	end

	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("ValueBase") then
			watchValueBase(desc)
		elseif containsKeyword(desc.Name, {"star", "summon", "roll", "open", "cache"}) then
			watchAttributes(desc, true)
		end
	end
end

-- ============================================================================
-- 9. CLASSIFICAÇÃO AUTOMÁTICA FINAL (CASOS 1, 2, 3 e 4)
-- ============================================================================
local function classifyFinalBehavior(): (string, string)
	if State.RealOpenings < 5 then
		return "AGUARDANDO DADOS", "Realize cliques rápidos no botão MAX até completar pelo menos 5 a 15 aberturas."
	end

	local avgRawClick = getAverage(State.ClickIntervals)
	local avgBtnClick = getAverage(State.ButtonClickIntervals)
	local avgPity = getAverage(State.PityIntervals)

	-- Verifica se os cliques físicos (Raw Mouse) estão rápidos (< 0.35s), mas o botão para de disparar eventos
	local buttonDropRatio = (State.PhysicalMaxClicks > 0) and (State.GroupedButtonMaxClicks / State.PhysicalMaxClicks) or 1
	local guiIsBlocking = (avgRawClick > 0 and avgRawClick < 0.35)
		and ((avgBtnClick >= 0.75) or (buttonDropRatio < 0.45) or (State.BlockedOverlayClicks >= 3))

	-- CASO 3: Existe uma Flag/Propriedade local fortemente correlacionada com o ciclo de ~1s
	if State.BestGateCandidate ~= "NENHUM" then
		return "CASO 3: FORTE CANDIDATO A GATING LOCAL",
			string.format(
				"Uma flag/propriedade local acompanha o bloqueio entre o clique e a próxima abertura:\n  Gate: %s",
				State.BestGateCandidate
			)
	end

	-- CASO 1: Cliques físicos rápidos (~0.1s), mas os eventos do GuiButton só disparam ~1x/s ou são perdidos
	if guiIsBlocking then
		return "CASO 1: O PRÓPRIO GUI/BOTÃO ESTÁ BLOQUEANDO INPUTS",
			string.format(
				"Cliques físicos chegam a %.3fs (%d cliques no MAX), mas o GuiButton só disparou em %d deles (Substituições de botão: %d | Cliques com botão oculto/coberto: %d).",
				avgRawClick, State.PhysicalMaxClicks, State.GroupedButtonMaxClicks,
				State.MaxButtonReplacements, State.BlockedOverlayClicks
			)
	end

	-- CASO 2 / CASO 4: Cliques físicos (~0.1s) e eventos do botão (~0.1s) chegam normalmente, mas o Pity fica em ~1.0s
	if avgRawClick > 0 and avgRawClick < 0.35 and buttonDropRatio >= 0.65 and avgPity >= 0.85 then
		if next(State.GateCandidates) == nil then
			return "CASO 4: NENHUMA TRAVA LOCAL VISÍVEL ENCONTRADA",
				"Todos os cliques chegam ao GuiButton (~0.1s), nenhuma ValueBase/Attribute/Propriedade visível mudou, e o Pity seguiu em ~1.0s.\n" ..
				"Conclusão: O bloqueio está em uma variável local privada (upvalue dentro de closure de LocalScript) ou validação/cooldown direto no Servidor."
		else
			return "CASO 2: INPUT CHEGA AO BOTÃO, MAS É BLOQUEADO DEPOIS",
				string.format(
					"Os eventos do botão disparam normalmente (%.3fs), mas apenas 1 abertura real ocorre a cada %.3fs.",
					avgBtnClick, avgPity
				)
		end
	end

	return "EM ANÁLISE", string.format("Click médio: %.3fs | Pity médio: %.3fs", avgRawClick, avgPity)
end

local function printFinalReport()
	local clicksPerOpening = (State.RealOpenings > 0) and (State.PhysicalMaxClicks / State.RealOpenings) or 0
	local minClick = (State.MinClickToClick == math.huge) and 0 or State.MinClickToClick
	local minPity = (State.MinPityToPity == math.huge) and 0 or State.MinPityToPity
	local avgRawClick = getAverage(State.ClickIntervals)
	local avgBtnClick = getAverage(State.ButtonClickIntervals)
	local avgPity = getAverage(State.PityIntervals)
	local verdictTitle, verdictDetail = classifyFinalBehavior()

	print("\n================ STAR TIMING DIAGNOSTIC v5 (RELATÓRIO FINAL) ================")
	print(string.format("RAW MOUSE CLICKS: %d", State.RawMouseClicks))
	print(string.format("PHYSICAL MAX CLICKS (Sobre o MAX): %d", State.PhysicalMaxClicks))
	print(string.format("BUTTON EVENTS (Down+Up+Activated): %d", State.ButtonEventsCount))
	print(string.format("CLIQUES QUE ATIVARAM O BOTÃO: %d (.Activated = %d)", State.GroupedButtonMaxClicks, State.ButtonActivatedCount))
	print(string.format("SUBSTITUIÇÕES DE INSTANCE DO BOTÃO MAX: %d", State.MaxButtonReplacements))
	print("-----------------------------------------------------------------------------")
	print(string.format("ABERTURAS REAIS (Pity): %d", State.RealOpenings))
	print(string.format("ROLLS REAIS: %d", State.RealRolls))
	print(string.format("CLIQUES FÍSICOS / ABERTURA: %.2f", clicksPerOpening))
	print("-----------------------------------------------------------------------------")
	print(string.format("CLICK -> CLICK (Físico)  | Médio: %.3fs | Mínimo: %.3fs", avgRawClick, minClick))
	print(string.format("EVENT -> EVENT (Botão)   | Médio: %.3fs", avgBtnClick))
	print(string.format("PITY -> PITY (Real)      | Médio: %.3fs | Mínimo: %.3fs", avgPity, minPity))
	print(string.format("ÚLTIMO CLICK -> PITY: %.3fs", State.LastClickToPity))
	print(string.format("POSSÍVEL GATE: %s", State.BestGateCandidate))
	print("\nDIAGNÓSTICO FINAL:")
	print("  " .. verdictTitle)
	print("  " .. verdictDetail)
	print("=============================================================================\n")
end

-- ============================================================================
-- 8. INTERFACE GRÁFICA (PAINEL V5)
-- ============================================================================
local function createUI()
	local parentGui = PlayerGui
	pcall(function()
		for _, oldName in ipairs({"StarTimingDiagnosticUI", "StarSpeedProfilerUI"}) do
			if CoreGui:FindFirstChild(oldName) then
				CoreGui[oldName]:Destroy()
			end
		end
		parentGui = CoreGui
	end)
	if PlayerGui:FindFirstChild("StarTimingDiagnosticUI") then
		PlayerGui.StarTimingDiagnosticUI:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StarTimingDiagnosticUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = parentGui

	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 345, 0, 415)
	mainFrame.Position = UDim2.new(0.02, 0, 0.24, 0)
	mainFrame.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	mainFrame.BorderSizePixel = 0
	mainFrame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = mainFrame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(75, 90, 125)
	stroke.Thickness = 1.5
	stroke.Parent = mainFrame

	local titleBar = Instance.new("Frame")
	titleBar.Size = UDim2.new(1, 0, 0, 30)
	titleBar.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
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
	titleLabel.Text = "STAR TIMING DIAGNOSTIC v5"
	titleLabel.TextColor3 = Color3.fromRGB(240, 245, 255)
	titleLabel.TextSize = 13
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

	local statsLabel = Instance.new("TextLabel")
	statsLabel.Position = UDim2.new(0, 12, 0, 36)
	statsLabel.Size = UDim2.new(1, -24, 0, 290)
	statsLabel.BackgroundTransparency = 1
	statsLabel.Font = Enum.Font.RobotoMono
	statsLabel.TextColor3 = Color3.fromRGB(225, 230, 240)
	statsLabel.TextSize = 12
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel.TextYAlignment = Enum.TextYAlignment.Top
	statsLabel.RichText = true
	statsLabel.Parent = mainFrame

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

	local startBtn   = makeButton("[START]",      UDim2.new(0, 10, 0, 334),  UDim2.new(0, 104, 0, 32), Color3.fromRGB(40, 140, 75))
	local stopBtn    = makeButton("[STOP]",       UDim2.new(0, 120, 0, 334), UDim2.new(0, 104, 0, 32), Color3.fromRGB(175, 55, 55))
	local resetBtn   = makeButton("[RESET]",      UDim2.new(0, 230, 0, 334), UDim2.new(0, 104, 0, 32), Color3.fromRGB(70, 80, 100))
	local recalibBtn = makeButton("RECALIBRAR",   UDim2.new(0, 10, 0, 374),  UDim2.new(0, 157, 0, 30), Color3.fromRGB(55, 95, 160))
	local debugBtn   = makeButton("DEBUG F9: ON", UDim2.new(0, 177, 0, 374), UDim2.new(0, 157, 0, 30), Color3.fromRGB(110, 80, 150))

	-- Dragging da janela
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
	local dragConn = UserInputService.InputChanged:Connect(function(input)
		if input == dragInput and dragging then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)

	startBtn.MouseButton1Click:Connect(function()
		State.IsRunning = true
		print("[STAR DIAGNOSTIC v5] Coleta INICIADA.")
	end)

	stopBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		printFinalReport()
	end)

	resetBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		State.RawMouseClicks = 0
		State.PhysicalMaxClicks = 0
		State.ButtonEventsCount = 0
		State.GroupedButtonMaxClicks = 0
		State.ButtonActivatedCount = 0
		State.RealOpenings = 0
		State.RealRolls = 0
		State.LastPhysicalMaxClickTime = nil
		State.LastGroupedBtnEventTime = nil
		State.LastPityTime = nil
		State.MinClickToClick = math.huge
		State.MinPityToPity = math.huge
		State.LastClickToPity = 0
		State.LastPityToPity = 0
		State.MaxButtonReplacements = 0
		State.BlockedOverlayClicks = 0
		State.BestGateCandidate = "NENHUM"
		table.clear(State.ClickIntervals)
		table.clear(State.ButtonClickIntervals)
		table.clear(State.PityIntervals)
		table.clear(State.CycleRawMaxClicks)
		table.clear(State.CycleButtonActivated)
		table.clear(State.CycleButtonEvents)
		table.clear(State.CycleFlags)
		table.clear(State.GateCandidates)
		print("[STAR DIAGNOSTIC v5] Todos os contadores foram resetados.")
	end)

	recalibBtn.MouseButton1Click:Connect(function()
		scanAndConnectAll()
	end)

	debugBtn.MouseButton1Click:Connect(function()
		DEBUG = not DEBUG
		debugBtn.Text = DEBUG and "DEBUG F9: ON" or "DEBUG F9: OFF"
		debugBtn.BackgroundColor3 = DEBUG and Color3.fromRGB(110, 80, 150) or Color3.fromRGB(60, 60, 70)
	end)

	local renderConn
	renderConn = RunService.RenderStepped:Connect(function()
		local clicksPerOpen = (State.RealOpenings > 0) and (State.PhysicalMaxClicks / State.RealOpenings) or 0
		local minClick = (State.MinClickToClick == math.huge) and 0 or State.MinClickToClick
		local minPity = (State.MinPityToPity == math.huge) and 0 or State.MinPityToPity
		local verdictTitle, _ = classifyFinalBehavior()

		statsLabel.Text = string.format(
			"STATUS: %s\n\n" ..
			"RAW CLICKS: %d\n" ..
			"MAX CLICKS: %d (Btn Hit: %d)\n" ..
			"BUTTON EVENTS: %d\n\n" ..
			"ABERTURAS REAIS: %d\n" ..
			"ROLLS REAIS: %d\n\n" ..
			"CLIQUES / ABERTURA: %.1f\n\n" ..
			"MENOR CLICK -> CLICK: %.3fs\n" ..
			"MENOR PITY -> PITY: %.3fs\n\n" ..
			"ÚLTIMO CLICK -> PITY: %.3fs\n\n" ..
			"POSSÍVEL GATE:\n<b>%s</b>\n" ..
			"DIAG: <b>%s</b>",
			State.IsRunning and '<font color="#55ff7f">RODANDO</font>' or '<font color="#ffaa55">PARADO</font>',
			State.RawMouseClicks,
			State.PhysicalMaxClicks, State.GroupedButtonMaxClicks,
			State.ButtonEventsCount,
			State.RealOpenings,
			State.RealRolls,
			clicksPerOpen,
			minClick,
			minPity,
			State.LastClickToPity,
			State.BestGateCandidate,
			verdictTitle
		)
	end)

	closeBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		if renderConn then renderConn:Disconnect() end
		if dragConn then dragConn:Disconnect() end
		clearConnections()
		screenGui:Destroy()
		print("[STAR DIAGNOSTIC v5] Encerrado e todas as conexões foram limpas.")
	end)
end

-- ============================================================================
-- INICIALIZAÇÃO
-- ============================================================================
createUI()
scanAndConnectAll()
