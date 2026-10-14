--[[
    STAR TIMING DIAGNOSTIC v4 (READ-ONLY BOTTLENECK FINDER)
    Jogo alvo: Anime Legacy Simulator
    Fonte de verdade: PlayerGui.UI.Frames.Star.Pity.Value ("Mythical Pity: 5085/7500")
    Objetivo: Descobrir se o limite de ~1.00s está na cadência de tentativa do cliente (Caso A),
              em um cooldown/validação pós-input (Caso B) ou atrelado a uma Flag/UI local (Caso C).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- ============================================================================
-- CONFIGURAÇÕES DE DIAGNÓSTICO (100% READ-ONLY)
-- ============================================================================
local DEBUG = true
local DEFAULT_MAX_DELTA = 9

-- Evita que MouseButton1Down + Activated do MESMO clique contem como 2 inputs a 0.000s
local BUTTON_CLICK_DEDUP = 0.035
-- Evita leituras duplicadas se o texto do Pity atualizar duas vezes no mesmo frame
local PITY_DEDUP_WINDOW = 0.080

-- Palavras-chave para descoberta passiva de Flags / Values / Attributes
local STATE_KEYWORDS = {
	"open", "opening", "isopening", "roll", "summon", "star",
	"auto", "cooldown", "debounce", "busy", "canopen", "ready"
}

local IGNORE_KEYWORDS = {
	"timer", "fps", "ping", "clock", "timeleft", "refresh",
	"chat", "bubble", "health", "xp", "quest", "index", "music", "sound"
}

-- ============================================================================
-- ESTADO E MÉTRICAS COLETADAS
-- ============================================================================
export type CycleVisibilityEvent = {
	path: string,
	state: boolean,
	timestamp: number,
}

export type CycleFlagEvent = {
	path: string,
	oldVal: string,
	newVal: string,
	timestamp: number,
}

local State = {
	IsRunning = false,
	SessionStartTime = 0,

	-- Contadores oficiais (via Pity)
	TotalOpenings = 0,
	TotalRealRolls = 0,

	-- Timestamps absolutos (os.clock)
	LastMaxInputTime = nil :: number?,
	LastSingleInputTime = nil :: number?,
	LastAnyInputTime = nil :: number?,
	LastPityTime = nil :: number?,

	-- Rastreamento de Inputs dentro do ciclo atual (entre um Pity e o próximo)
	CycleFirstInputTime = nil :: number?,
	CycleLastInputTime = nil :: number?,
	CycleLastInputType = "NENHUM",
	CycleInputCount = 0,
	PrevOpeningInputTime = nil :: number?,

	-- Valores de Pity
	LastPityValue = nil :: number?,
	LastPityMax = nil :: number?,
	PityPath = "Procurando...",

	-- Intervalos atuais e mínimos
	LastInputToPity = 0,
	LastInputToInput = 0,
	LastPityToPity = 0,
	MinInputToInput = math.huge,
	MinPityToPity = math.huge,

	-- Históricos para médias do relatório final
	InputToInputHistory = {} :: {number},
	PityToPityHistory = {} :: {number},
	InputToPityHistory = {} :: {number},

	-- Estado do AUTO e Flags descobertas
	AutoEnabled = false,
	AutoButtonPath = "Não detectado",
	MaxButtonPath = "Não detectado",
	SingleButtonPath = "Não detectado",

	DiscoveredFlags = {} :: {[string]: boolean},
	GatingFlagHits = 0, -- Quantas vezes uma flag/visibilidade destravou logo antes do próximo giro
	LastFlagReleaseTime = nil :: number?,
	LastFlagReleaseName = nil :: string?,

	-- Eventos de visibilidade da Star no ciclo atual
	CycleVisEvents = {} :: {CycleVisibilityEvent},
	LastStarVisibleChangeTime = nil :: number?,
}

local Connections = {} :: {RBXScriptConnection}
local WatchedObjects = {} :: {[Instance]: boolean}
local ButtonLastClick = {} :: {[Instance]: number}

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

local function containsKeyword(str: string, keywords: {string}): boolean
	local lower = string.lower(str)
	for _, kw in ipairs(keywords) do
		if string.find(lower, kw, 1, true) then
			return true
		end
	end
	return false
end

local function getAverage(list: {number}): number
	if #list == 0 then return 0 end
	local sum = 0
	for _, v in ipairs(list) do
		sum += v
	end
	return sum / #list
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

-- Extrai todo o texto visível dentro de um botão (o próprio .Text ou de TextLabels filhos)
local function getButtonCombinedText(btn: GuiButton): string
	local texts = { btn.Name }
	if btn.Parent then
		table.insert(texts, btn.Parent.Name)
	end
	if btn:IsA("TextButton") and btn.Text ~= "" then
		table.insert(texts, btn.Text)
	end
	for _, desc in ipairs(btn:GetDescendants()) do
		if desc:IsA("TextLabel") and desc.Text ~= "" then
			table.insert(texts, desc.Text)
		end
	end
	return string.lower(table.concat(texts, " | "))
end

-- ============================================================================
-- CLASSIFICAÇÃO AUTOMÁTICA DE DIAGNÓSTICO (CASO A / B / C)
-- ============================================================================
local function evaluateDiagnostic(): (string, string)
	if State.TotalOpenings < 15 then
		return string.format("AGUARDANDO DADOS (%d/15 aberturas)", State.TotalOpenings),
			"Colete pelo menos 15 a 20 aberturas para classificar o gargalo."
	end

	local avgPity = getAverage(State.PityToPityHistory)
	local avgInput = getAverage(State.InputToInputHistory)
	local hasFastInputs = (#State.InputToInputHistory >= 5 and avgInput > 0 and avgInput < 0.50)
	local has1sInputs = (#State.InputToInputHistory >= 5 and avgInput >= 0.85 and avgInput <= 1.35)
	local hasFlagCorrelation = (State.GatingFlagHits >= math.floor(State.TotalOpenings * 0.4))

	-- Caso B: Usuário/Cliente envia inputs rápidos (< 0.5s), mas o Pity só avança a ~1.00s
	if hasFastInputs and avgPity >= 0.90 then
		local detail = "INPUT NÃO É O GARGALO.\nExiste cooldown/debounce/validação depois do input."
		if hasFlagCorrelation and State.LastFlagReleaseName then
			detail = detail .. string.format("\n(Nota: Flag/UI '%s' acompanha o ciclo)", State.LastFlagReleaseName)
		end
		return "CASO B: COOLDOWN PÓS-INPUT", detail
	end

	-- Caso C: O próximo input ou abertura acontece sistematicamente logo após uma Flag/UI liberar
	if hasFlagCorrelation then
		return "CASO C: FLAG/UI LOCAL CONTROLANDO CADÊNCIA",
			string.format("POSSÍVEL FLAG LOCAL CONTROLANDO A CADÊNCIA.\nSinal correlacionado: %s (%d ciclos)", tostring(State.LastFlagReleaseName or "Star.Visible"), State.GatingFlagHits)
	end

	-- Caso A: Inputs espaçados em ~1.00s (ou loop AUTO interno gerando giros a ~1.00s sem cliques extras)
	if has1sInputs or (State.AutoEnabled and #State.InputToInputHistory < 5 and avgPity >= 0.90) then
		return "CASO A: LIMITE NO CLIENTE / LOOP DO AUTO",
			"PROVÁVEL LIMITE NO CLIENTE / LOOP DO AUTO.\nO cliente parece só iniciar nova tentativa após ~1s."
	end

	return "COMPORTAMENTO MISTO / EM ANÁLISE",
		string.format("Pity médio: %.3fs | Input médio: %.3fs", avgPity, avgInput)
end

-- ============================================================================
-- 1, 2 & 3. MONITORAMENTO DE BOTÕES (MAX / SINGLE / AUTO)
-- ============================================================================
local function inferAutoStateFromButton(btn: GuiButton): boolean?
	local combined = getButtonCombinedText(btn)
	if string.find(combined, "on", 1, true) or string.find(combined, "ativo", 1, true) or string.find(combined, "stop", 1, true) then
		return true
	elseif string.find(combined, "off", 1, true) then
		return false
	end

	-- Muitos jogos no Roblox mudam a cor do botão AUTO para Verde quando ON e Vermelho/Cinza quando OFF
	local color = btn.BackgroundColor3
	if btn:IsA("ImageButton") and btn.ImageColor3 ~= Color3.new(1, 1, 1) then
		color = btn.ImageColor3
	end
	if color.G > (color.R * 1.35) and color.G > 0.45 then
		return true
	elseif color.R > (color.G * 1.35) and color.R > 0.45 then
		return false
	end
	return nil
end

local function recordGameButtonInput(buttonKind: string, btnPath: string)
	local now = os.clock()

	if buttonKind == "AUTO" then
		State.AutoEnabled = not State.AutoEnabled
		if DEBUG then
			print(string.format("[AUTO INPUT] %s\nEstado inferido: %s\nTimestamp: %.3f", btnPath, State.AutoEnabled and "ON" or "OFF", now))
		end
		return
	end

	-- Verifica correlação com Caso C (se o input ocorreu logo após uma flag ou Star.Visible liberar)
	if State.LastFlagReleaseTime and (now - State.LastFlagReleaseTime) <= 0.25 then
		State.GatingFlagHits += 1
	end

	if State.LastAnyInputTime ~= nil then
		local inputDelta = now - State.LastAnyInputTime
		State.LastInputToInput = inputDelta
		if State.IsRunning then
			table.insert(State.InputToInputHistory, inputDelta)
			if inputDelta < State.MinInputToInput then
				State.MinInputToInput = inputDelta
			end
		end
	end

	State.LastAnyInputTime = now
	if buttonKind == "MAX" then
		State.LastMaxInputTime = now
	elseif buttonKind == "SINGLE" then
		State.LastSingleInputTime = now
	end

	if State.CycleFirstInputTime == nil then
		State.CycleFirstInputTime = now
	end
	State.CycleLastInputTime = now
	State.CycleLastInputType = buttonKind
	State.CycleInputCount += 1

	if DEBUG then
		local deltaFromPity = State.LastPityTime and string.format("+%.3fs após último Pity", now - State.LastPityTime) or "Sem Pity anterior"
		print(string.format("[%s INPUT] T = %.3f (%s) | Input->Input: %.3fs", buttonKind, now, deltaFromPity, State.LastInputToInput))
	end
end

local function hookStarButton(btn: GuiButton, buttonKind: string, path: string)
	if WatchedObjects[btn] then return end
	WatchedObjects[btn] = true

	if buttonKind == "MAX" then
		State.MaxButtonPath = path
	elseif buttonKind == "SINGLE" then
		State.SingleButtonPath = path
	elseif buttonKind == "AUTO" then
		State.AutoButtonPath = path
		local initialAuto = inferAutoStateFromButton(btn)
		if initialAuto ~= nil then
			State.AutoEnabled = initialAuto
		end
	end

	if DEBUG then
		print(string.format("[BUTTON DISCOVERED] Tipo: %-6s | Path: %s", buttonKind, path))
	end

	local function onTriggered()
		local now = os.clock()
		local last = ButtonLastClick[btn] or 0
		if (now - last) < BUTTON_CLICK_DEDUP then
			return -- Ignora evento duplicado do mesmo clique físico
		end
		ButtonLastClick[btn] = now
		recordGameButtonInput(buttonKind, path)
	end

	table.insert(Connections, btn.MouseButton1Down:Connect(onTriggered))
	table.insert(Connections, btn.Activated:Connect(onTriggered))

	-- Se for o botão de AUTO, observa mudanças visuais de cor/texto para detectar ativação via tecla/atalho
	if buttonKind == "AUTO" then
		table.insert(Connections, btn:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
			local st = inferAutoStateFromButton(btn)
			if st ~= nil and st ~= State.AutoEnabled then
				State.AutoEnabled = st
				if DEBUG then
					print(string.format("[AUTO STATE CHANGE] Detectado via cor em %s -> %s (T = %.3f)", path, st and "ON" or "OFF", os.clock()))
				end
			end
		end))
	end
end

local function classifyAndHookButton(inst: Instance)
	if not inst:IsA("GuiButton") then return end
	local path = getCleanPath(inst)
	if string.find(path, "StarTimingDiagnosticUI", 1, true) then return end

	local info = getButtonCombinedText(inst)

	if string.find(info, "auto", 1, true) then
		hookStarButton(inst, "AUTO", path)
	elseif string.find(info, "max", 1, true) or string.find(info, "multi", 1, true) then
		hookStarButton(inst, "MAX", path)
	elseif string.find(info, "single", 1, true) or string.find(info, "1x", 1, true) or string.find(info, "one", 1, true) or string.find(info, "open", 1, true) then
		-- Garante que um botão genérico "Open" não sobrescreva o Max ou Close
		if not string.find(info, "close", 1, true) and not string.find(info, "exit", 1, true) and not string.find(info, "max", 1, true) then
			hookStarButton(inst, "SINGLE", path)
		end
	end
end

-- ============================================================================
-- 5. MONITORAMENTO DE VISIBILIDADE DA INTERFACE DA STAR
-- ============================================================================
local function watchStarVisibility(guiObj: Instance, path: string)
	local visKey = "vis_" .. path
	if WatchedObjects[visKey :: any] then return end
	WatchedObjects[visKey :: any] = true

	if guiObj:IsA("GuiObject") then
		table.insert(Connections, guiObj:GetPropertyChangedSignal("Visible"):Connect(function()
			local now = os.clock()
			local isVis = guiObj.Visible
			State.LastStarVisibleChangeTime = now

			-- Se a interface da Star voltou a ficar visível (fim da animação de abertura),
			-- marca como possível sinal liberador de ciclo (Caso C)
			if isVis then
				State.LastFlagReleaseTime = now
				State.LastFlagReleaseName = path .. ".Visible=true"
			end

			table.insert(State.CycleVisEvents, {
				path = path .. ".Visible",
				state = isVis,
				timestamp = now,
			})

			if DEBUG then
				local relPity = State.LastPityTime and string.format("+%.3fs desde último Pity", now - State.LastPityTime) or "antes do 1º Pity"
				print(string.format("[UI VISIBILITY] %s.Visible = %s | T = %.3f (%s)", path, tostring(isVis), now, relPity))
			end
		end))
	elseif guiObj:IsA("ScreenGui") then
		table.insert(Connections, guiObj:GetPropertyChangedSignal("Enabled"):Connect(function()
			local now = os.clock()
			local isEn = guiObj.Enabled
			table.insert(State.CycleVisEvents, {
				path = path .. ".Enabled",
				state = isEn,
				timestamp = now,
			})
			if DEBUG then
				print(string.format("[UI ENABLED] %s.Enabled = %s | T = %.3f", path, tostring(isEn), now))
			end
		end))
	end
end

-- ============================================================================
-- 6. DESCOBERTA PASSIVA DE ESTADOS LOCAIS (VALUES & ATTRIBUTES)
-- ============================================================================
local function logStateChange(fullPath: string, oldVal: any, newVal: any)
	local now = os.clock()
	State.DiscoveredFlags[fullPath] = true

	-- Verifica se é um estado de Auto
	if containsKeyword(fullPath, {"auto"}) and typeof(newVal) == "boolean" then
		State.AutoEnabled = newVal
	end

	-- Se uma flag de bloqueio (IsOpening/Busy/Cooldown) mudou para false, ou CanOpen/Ready mudou para true
	if (newVal == false and containsKeyword(fullPath, {"opening", "busy", "cooldown", "debounce"}))
		or (newVal == true and containsKeyword(fullPath, {"canopen", "ready"})) then
		State.LastFlagReleaseTime = now
		State.LastFlagReleaseName = fullPath
	end

	local deltaStr = "N/A (Sem Pity anterior)"
	if State.LastPityTime then
		deltaStr = string.format("+%.3fs", now - State.LastPityTime)
	end

	if DEBUG then
		print(string.format(
			"[STATE CHANGE]\nPath: %s\nOld: %s\nNew: %s\nTimestamp: %.3f\nDelta desde último Pity: %s",
			fullPath,
			tostring(oldVal),
			tostring(newVal),
			now,
			deltaStr
		))
	end
end

local function watchValueInstance(valObj: ValueBase)
	if WatchedObjects[valObj] then return end
	if not (valObj:IsA("BoolValue") or valObj:IsA("IntValue") or valObj:IsA("NumberValue") or valObj:IsA("StringValue")) then
		return
	end

	local path = getCleanPath(valObj)
	-- Ignora o próprio Pity.Value aqui pois ele já tem o detector principal dedicado
	if string.find(path, "Frames.Star.Pity", 1, true) then return end
	if containsKeyword(path, IGNORE_KEYWORDS) then return end
	if not containsKeyword(path, STATE_KEYWORDS) then return end

	WatchedObjects[valObj] = true
	State.DiscoveredFlags[path] = true

	local propObj = valObj :: any
	local lastVal = propObj.Value

	if DEBUG then
		print(string.format("[FLAG ENCONTRADA] %s (%s) = %s", path, valObj.ClassName, tostring(lastVal)))
	end

	table.insert(Connections, propObj:GetPropertyChangedSignal("Value"):Connect(function()
		local newVal = propObj.Value
		if newVal ~= lastVal then
			local prev = lastVal
			lastVal = newVal
			logStateChange(path, prev, newVal)
		end
	end))
end

local function watchAttributesOnInstance(inst: Instance, checkAllAttrs: boolean)
	local attrKey = "attr_" .. getCleanPath(inst)
	if WatchedObjects[attrKey :: any] then return end

	local attrs = inst:GetAttributes()
	local hasRelevantAttr = checkAllAttrs
	local basePath = (inst == LocalPlayer) and "LocalPlayer" or getCleanPath(inst)

	for attrName, val in pairs(attrs) do
		if containsKeyword(attrName, STATE_KEYWORDS) and not containsKeyword(attrName, IGNORE_KEYWORDS) then
			hasRelevantAttr = true
			local fullAttrPath = basePath .. ".Attribute." .. attrName
			State.DiscoveredFlags[fullAttrPath] = true
			if DEBUG then
				print(string.format("[ATTRIBUTE ENCONTRADO] %s = %s", fullAttrPath, tostring(val)))
			end
		end
	end

	if not hasRelevantAttr and not containsKeyword(basePath, STATE_KEYWORDS) then
		return
	end

	WatchedObjects[attrKey :: any] = true
	local cachedAttrs = inst:GetAttributes()

	table.insert(Connections, inst.AttributeChanged:Connect(function(attrName: string)
		local newVal = inst:GetAttribute(attrName)
		local oldVal = cachedAttrs[attrName]
		cachedAttrs[attrName] = newVal

		if containsKeyword(attrName, IGNORE_KEYWORDS) then return end
		if checkAllAttrs or containsKeyword(attrName, STATE_KEYWORDS) or containsKeyword(basePath, STATE_KEYWORDS) then
			logStateChange(basePath .. ".Attribute." .. attrName, oldVal, newVal)
		end
	end))
end

-- ============================================================================
-- 4. FONTE DE VERDADE: MYTHICAL PITY & TIMELINE POR ABERTURA
-- ============================================================================
local function onPityRawChanged(rawText: string)
	local newCur, newMax = parsePityNumbers(rawText)
	if not newCur then return end

	-- Sincroniza o estado inicial na primeira leitura sem contar abertura
	if State.LastPityValue == nil then
		State.LastPityValue = newCur
		State.LastPityMax = newMax
		if DEBUG then
			print(string.format("[PITY SYNC] Valor base sincronizado: %d/%s", newCur, tostring(newMax or "?")))
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

	-- Calcula rolls reais exclusivamente pelo delta do Pity
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

	-- Intervalo PITY -> PITY anterior
	local pityToPity: number? = nil
	if State.LastPityTime ~= nil then
		pityToPity = now - State.LastPityTime
		State.LastPityToPity = pityToPity
	end

	-- Correlação com o Input que originou esta abertura
	local triggerInputTime = State.CycleLastInputTime
	local inputToPity: number? = nil
	local openingInputToInput: number? = nil

	if triggerInputTime ~= nil then
		inputToPity = now - triggerInputTime
		State.LastInputToPity = inputToPity
		if State.PrevOpeningInputTime ~= nil then
			openingInputToInput = triggerInputTime - State.PrevOpeningInputTime
		end
	end

	-- Verifica se houve liberação de Flag/Visible sincronizada com esta abertura (Caso C)
	if State.LastFlagReleaseTime and (now - State.LastFlagReleaseTime) <= 0.35 then
		State.GatingFlagHits += 1
	end

	local prevPityTimestamp = State.LastPityTime
	State.LastPityValue = newCur
	State.LastPityMax = newMax
	State.LastPityTime = now
	if triggerInputTime then
		State.PrevOpeningInputTime = triggerInputTime
	end

	if State.IsRunning then
		State.TotalOpenings += 1
		State.TotalRealRolls += delta

		if pityToPity then
			table.insert(State.PityToPityHistory, pityToPity)
			if pityToPity < State.MinPityToPity then
				State.MinPityToPity = pityToPity
			end
		end
		if inputToPity then
			table.insert(State.InputToPityHistory, inputToPity)
		end
	end

	local openingIndex = State.IsRunning and State.TotalOpenings or 0

	-- Formata histórico de Star.Visible ocorrido durante este ciclo
	local visLines = {}
	local cycleRefTime = triggerInputTime or prevPityTimestamp or now
	for _, ev in ipairs(State.CycleVisEvents) do
		local relOffset = ev.timestamp - cycleRefTime
		table.insert(visLines, string.format("%s @ %+.3fs", tostring(ev.state), relOffset))
	end
	local visReport = (#visLines > 0) and table.concat(visLines, "\n") or "Sem alteração no ciclo"

	-- Imprime a Timeline completa da Abertura no F9
	if DEBUG then
		local inputHeader = (State.CycleLastInputType ~= "NENHUM") and (State.CycleLastInputType .. " INPUT:") or "MAX INPUT:"
		local inputTimeStr = triggerInputTime and string.format("T = %.3f", triggerInputTime) or "Sem clique manual no ciclo (AUTO / Interno)"
		if State.CycleInputCount > 1 then
			inputTimeStr = inputTimeStr .. string.format(" (%d cliques neste ciclo)", State.CycleInputCount)
		end

		local effectiveInputToInput = (State.LastInputToInput > 0) and string.format("%.3fs", State.LastInputToInput)
			or (openingInputToInput and string.format("%.3fs", openingInputToInput) or "N/A")

		print(string.format(
			"\n===== OPENING #%d =====\n\n" ..
			"%s\n%s\n\n" ..
			"PITY:\n%d -> %d (Delta: +%d)\nT = %.3f\n\n" ..
			"INPUT -> PITY:\n%s\n\n" ..
			"PITY -> PITY anterior:\n%s\n\n" ..
			"INPUT -> INPUT anterior:\n%s\n\n" ..
			"Star.Visible:\n%s\n" ..
			"=======================",
			openingIndex,
			inputHeader,
			inputTimeStr,
			oldCur, newCur, delta,
			now,
			inputToPity and string.format("%.3fs", inputToPity) or "N/A (Gerado pelo AUTO)",
			pityToPity and string.format("%.3fs", pityToPity) or "1ª abertura da medição",
			effectiveInputToInput,
			visReport
		))
	end

	-- Reseta os acumuladores do ciclo atual para a próxima abertura
	State.CycleFirstInputTime = nil
	State.CycleLastInputTime = nil
	State.CycleLastInputType = "NENHUM"
	State.CycleInputCount = 0
	table.clear(State.CycleVisEvents)
end

-- ============================================================================
-- ESCANEAMENTO E CONEXÃO PASSIVA
-- ============================================================================
local function clearAllConnections()
	for _, conn in ipairs(Connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(Connections)
	table.clear(WatchedObjects)
	table.clear(ButtonLastClick)
end

local function scanAndConnect()
	clearAllConnections()

	-- 1. Conecta Pity (PlayerGui.UI.Frames.Star.Pity.Value) e monitora Star Frame
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
				onPityRawChanged(pityTarget.Text)
			end))
		elseif pityTarget:IsA("ValueBase") then
			local vObj = pityTarget :: any
			State.LastPityValue, State.LastPityMax = parsePityNumbers(tostring(vObj.Value))
			table.insert(Connections, vObj:GetPropertyChangedSignal("Value"):Connect(function()
				onPityRawChanged(tostring(vObj.Value))
			end))
		end
		print(string.format("[STAR DIAGNOSTIC v4] Pity conectado: %s (Atual: %s)", State.PityPath, tostring(State.LastPityValue or "?")))
	else
		State.PityPath = "Não encontrado (Abra a Star e clique em RECALIBRAR)"
		warn("[STAR DIAGNOSTIC v4] PlayerGui.UI.Frames.Star.Pity.Value ainda não encontrado.")
	end

	-- 2. Monitora Visibilidade de PlayerGui.UI.Frames.Star e botões MAX / SINGLE / AUTO
	if starFrame then
		watchStarVisibility(starFrame, getCleanPath(starFrame))
		watchAttributesOnInstance(starFrame, true)
		for _, desc in ipairs(starFrame:GetDescendants()) do
			classifyAndHookButton(desc)
			watchAttributesOnInstance(desc, false)
			if desc:IsA("GuiObject") and containsKeyword(desc.Name, {"result", "open", "roll", "summon", "animation"}) then
				watchStarVisibility(desc, getCleanPath(desc))
			end
		end
	end

	-- Fallback para botões de Auto/Max/Single que fiquem em barras adjacentes dentro de PlayerGui.UI
	if ui then
		for _, desc in ipairs(ui:GetDescendants()) do
			if desc:IsA("GuiButton") and (containsKeyword(desc.Name, {"max", "single", "auto"}) or (desc.Parent and containsKeyword(desc.Parent.Name, {"star", "summon", "roll"}))) then
				classifyAndHookButton(desc)
			end
		end
	end

	-- 3. Monitora Flags / Values / Attributes em LocalPlayer, PlayerGui, ReplicatedStorage e Workspace
	watchAttributesOnInstance(LocalPlayer, true)
	watchAttributesOnInstance(PlayerGui, false)
	watchAttributesOnInstance(ReplicatedStorage, false)
	watchAttributesOnInstance(Workspace, false)

	for _, container in ipairs({LocalPlayer, PlayerGui, ReplicatedStorage}) do
		for _, desc in ipairs(container:GetDescendants()) do
			if desc:IsA("ValueBase") then
				watchValueInstance(desc)
			end
			if containsKeyword(desc.Name, STATE_KEYWORDS) then
				watchAttributesOnInstance(desc, true)
			end
		end
	end

	-- Em Workspace, foca em objetos relevantes (ex: Workspace.Cache.FakeStarModel) para evitar peso
	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("ValueBase") then
			watchValueInstance(desc)
		elseif containsKeyword(desc.Name, {"star", "summon", "roll", "open", "cache"}) then
			watchAttributesOnInstance(desc, true)
		end
	end

	-- Escuta novos objetos criados dinamicamente durante o giro
	table.insert(Connections, PlayerGui.DescendantAdded:Connect(function(desc)
		if desc:IsA("GuiButton") then
			classifyAndHookButton(desc)
		elseif desc:IsA("ValueBase") then
			watchValueInstance(desc)
		end
	end))

	table.insert(Connections, LocalPlayer.DescendantAdded:Connect(function(desc)
		if desc:IsA("ValueBase") then
			watchValueInstance(desc)
		end
	end))
end

-- ============================================================================
-- RELATÓRIO FINAL NO F9 (STOP)
-- ============================================================================
local function printFinalDiagnosticReport()
	local avgPity = getAverage(State.PityToPityHistory)
	local minPity = (State.MinPityToPity == math.huge) and 0 or State.MinPityToPity
	local avgInput = getAverage(State.InputToInputHistory)
	local minInput = (State.MinInputToInput == math.huge) and 0 or State.MinInputToInput
	local avgInputToPity = getAverage(State.InputToPityHistory)

	local flagsList = {}
	for flagPath in pairs(State.DiscoveredFlags) do
		table.insert(flagsList, "  - " .. flagPath)
	end
	table.sort(flagsList)
	local flagsBlock = (#flagsList > 0) and table.concat(flagsList, "\n") or "  (Nenhuma ValueBase/Attribute explícita encontrada)"

	local shortVerdict, detailedVerdict = evaluateDiagnostic()

	print("\n===== STAR TIMING DIAGNOSTIC =====")
	print(string.format("\nAberturas: %d", State.TotalOpenings))
	print(string.format("Rolls reais: %d", State.TotalRealRolls))
	print(string.format("\nPity -> Pity médio: %.3fs", avgPity))
	print(string.format("Pity -> Pity mínimo: %.3fs", minPity))
	print(string.format("\nInput -> Input médio: %s", (#State.InputToInputHistory > 0) and string.format("%.3fs", avgInput) or "N/A (Sem cliques manuais)"))
	print(string.format("Input -> Input mínimo: %s", (#State.InputToInputHistory > 0) and string.format("%.3fs", minInput) or "N/A"))
	print(string.format("\nInput -> Pity médio: %s", (#State.InputToPityHistory > 0) and string.format("%.3fs", avgInputToPity) or "N/A"))
	print(string.format("\nAUTO:\n%s", State.AutoEnabled and "ON" or "OFF"))
	print(string.format("\nBotões Mapeados:\n  MAX: %s\n  SINGLE: %s\n  AUTO: %s", State.MaxButtonPath, State.SingleButtonPath, State.AutoButtonPath))
	print(string.format("\nFlags relevantes encontradas:\n%s", flagsBlock))
	print(string.format("\nDiagnóstico (%s):\n%s", shortVerdict, detailedVerdict))
	print("==================================\n")
end

-- ============================================================================
-- INTERFACE GRÁFICA (PAINEL V4)
-- ============================================================================
local function createUI()
	local parentGui = PlayerGui
	pcall(function()
		if CoreGui:FindFirstChild("StarTimingDiagnosticUI") then
			CoreGui.StarTimingDiagnosticUI:Destroy()
		end
		if CoreGui:FindFirstChild("StarSpeedProfilerUI") then
			CoreGui.StarSpeedProfilerUI:Destroy()
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
	mainFrame.Size = UDim2.new(0, 340, 0, 410)
	mainFrame.Position = UDim2.new(0.02, 0, 0.25, 0)
	mainFrame.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	mainFrame.BorderSizePixel = 0
	mainFrame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = mainFrame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 85, 115)
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
	titleLabel.Text = "STAR TIMING DIAGNOSTIC v4"
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
	statsLabel.Size = UDim2.new(1, -24, 0, 285)
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

	local startBtn   = makeButton("[START]",      UDim2.new(0, 10, 0, 330),  UDim2.new(0, 102, 0, 32), Color3.fromRGB(40, 140, 75))
	local stopBtn    = makeButton("[STOP]",       UDim2.new(0, 119, 0, 330), UDim2.new(0, 102, 0, 32), Color3.fromRGB(175, 55, 55))
	local resetBtn   = makeButton("[RESET]",      UDim2.new(0, 228, 0, 330), UDim2.new(0, 102, 0, 32), Color3.fromRGB(70, 80, 100))
	local recalibBtn = makeButton("RECALIBRAR",   UDim2.new(0, 10, 0, 370),  UDim2.new(0, 155, 0, 30), Color3.fromRGB(55, 95, 160))
	local debugBtn   = makeButton("DEBUG F9: ON", UDim2.new(0, 175, 0, 370), UDim2.new(0, 155, 0, 30), Color3.fromRGB(110, 80, 150))

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
		if State.IsRunning then return end
		State.IsRunning = true
		State.SessionStartTime = os.clock()
		print("[STAR DIAGNOSTIC v4] Coleta de timestamps INICIADA.")
	end)

	stopBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		printFinalDiagnosticReport()
	end)

	resetBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		State.TotalOpenings = 0
		State.TotalRealRolls = 0
		State.LastMaxInputTime = nil
		State.LastSingleInputTime = nil
		State.LastAnyInputTime = nil
		State.LastPityTime = nil
		State.CycleFirstInputTime = nil
		State.CycleLastInputTime = nil
		State.CycleLastInputType = "NENHUM"
		State.CycleInputCount = 0
		State.PrevOpeningInputTime = nil
		State.LastInputToPity = 0
		State.LastInputToInput = 0
		State.LastPityToPity = 0
		State.MinInputToInput = math.huge
		State.MinPityToPity = math.huge
		State.GatingFlagHits = 0
		table.clear(State.InputToInputHistory)
		table.clear(State.PityToPityHistory)
		table.clear(State.InputToPityHistory)
		table.clear(State.CycleVisEvents)
		print("[STAR DIAGNOSTIC v4] Dados e históricos resetados.")
	end)

	recalibBtn.MouseButton1Click:Connect(function()
		scanAndConnect()
	end)

	debugBtn.MouseButton1Click:Connect(function()
		DEBUG = not DEBUG
		debugBtn.Text = DEBUG and "DEBUG F9: ON" or "DEBUG F9: OFF"
		debugBtn.BackgroundColor3 = DEBUG and Color3.fromRGB(110, 80, 150) or Color3.fromRGB(60, 60, 70)
	end)

	local renderConn
	renderConn = RunService.RenderStepped:Connect(function()
		local minIn = (State.MinInputToInput == math.huge) and 0 or State.MinInputToInput
		local minPity = (State.MinPityToPity == math.huge) and 0 or State.MinPityToPity
		local shortVerdict, _ = evaluateDiagnostic()

		statsLabel.Text = string.format(
			"STATUS: %s\n\n" ..
			"ABERTURAS: %d\n" ..
			"ROLLS REAIS: %d\n\n" ..
			"ÚLTIMO INPUT MAX: %.3f\n" ..
			"ÚLTIMO INPUT SINGLE: %.3f\n" ..
			"ÚLTIMO PITY: %.3f\n\n" ..
			"INPUT -> PITY: %.3fs\n" ..
			"INPUT -> INPUT: %.3fs\n" ..
			"PITY -> PITY: %.3fs\n\n" ..
			"MENOR INPUT -> INPUT: %.3fs\n" ..
			"MENOR PITY -> PITY: %.3fs\n\n" ..
			"AUTO: <b>%s</b>\n" ..
			"DIAG: <b>%s</b>",
			State.IsRunning and '<font color="#55ff7f">RODANDO</font>' or '<font color="#ffaa55">PARADO</font>',
			State.TotalOpenings,
			State.TotalRealRolls,
			State.LastMaxInputTime or 0,
			State.LastSingleInputTime or 0,
			State.LastPityTime or 0,
			State.LastInputToPity,
			State.LastInputToInput,
			State.LastPityToPity,
			minIn,
			minPity,
			State.AutoEnabled and '<font color="#55ff7f">ON</font>' or '<font color="#ff5555">OFF</font>',
			shortVerdict
		)
	end)

	closeBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		if renderConn then renderConn:Disconnect() end
		if dragConn then dragConn:Disconnect() end
		clearAllConnections()
		screenGui:Destroy()
		print("[STAR DIAGNOSTIC v4] Encerrado e todas as conexões foram limpas.")
	end)
end

-- ============================================================================
-- INICIALIZAÇÃO
-- ============================================================================
createUI()
scanAndConnect()
