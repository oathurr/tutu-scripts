--[[
    STAR BATCH PROFILER v2 (READ-ONLY)
    Jogo alvo: Anime Legacy Simulator
    Objetivo: Medir exclusivamente os CICLOS DE ABERTURA (Batches) e o intervalo exato
              permitido entre o início de uma abertura e a próxima.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- ============================================================================
-- CONFIGURAÇÕES PRINCIPAIS
-- ============================================================================
local DEBUG = true

-- Janela de deduplicação (em segundos). Como a abertura normal leva ~1.27s,
-- 0.45s garante que sinais atrasados da mesma abertura sejam ignorados sem bloquear o próximo ciclo.
local DEDUP_WINDOW = 0.45

-- Quando true, o profiler trava automaticamente no sinal mais confiável de início de abertura
-- (priorizando Pity > Atributo > ScreenGui/Frame raiz) para medir sempre o mesmo ponto do ciclo.
local AUTO_ANCHOR = true

-- Caso queira travar manualmente em um caminho específico visto no F9, coloque a string aqui:
local MANUAL_LOCKED_PATH: string? = nil

-- Controle de quais sinais podem contar uma ABERTURA (true) vs APENAS DEBUG (false)
local SIGNAL_CONFIG = {
	-- Sinais primários (acontecem 1 vez no início do ciclo)
	Pity = true,
	AttrCounter = true,
	ScreenGuiEnabled = true,
	GuiVisible = true,

	-- Sinais secundários (APENAS DEBUG - nunca aumentam a contagem de aberturas)
	ChildAdded = false,
	ImageChange = false,
	TextChange = false,
	Currency = false,
}

-- Prioridade dos sinais para o AUTO_ANCHOR (quanto maior, mais confiável como início de ciclo)
local SIGNAL_PRIORITY: {[string]: number} = {
	Pity = 4,
	AttrCounter = 3,
	ScreenGuiEnabled = 2,
	GuiVisible = 1,
}

local GACHA_KEYWORDS = {
	"star", "summon", "roll", "open", "hatch", "gacha",
	"pity", "result", "unit", "character", "capsule", "banner", "pull"
}

local IGNORE_KEYWORDS = {
	"timer", "cooldown", "fps", "ping", "clock", "timeleft",
	"refresh", "reset", "chat", "bubble", "health", "xp", "quest", "index"
}

-- Evita que sub-elementos de cartas/slots acionem GuiVisible como se fossem a janela principal
local CARD_SUBELEMENT_KEYWORDS = {
	"template", "card", "slot", "grid", "viewport", "icon", "rarity", "shiny"
}

-- ============================================================================
-- ESTADO DO TESTE E HISTÓRICO
-- ============================================================================
export type OpeningEntry = {
	opening: number,
	timestamp: number,
	interval: number?,
	source: string,
	signalType: string,
}

local State = {
	IsRunning = false,
	StartTime = 0,
	ElapsedTime = 0,

	TotalOpenings = 0,
	LastOpeningTimestamp = nil :: number?,

	-- Âncora automática para garantir medição do mesmo evento a cada ciclo
	AnchorPath = nil :: string?,
	AnchorType = nil :: string?,
	AnchorPriority = 0,

	MinInterval = math.huge,
	MaxInterval = 0,
	LastInterval = 0,

	Intervals = {} :: {number},
	OpeningHistory = {} :: {OpeningEntry},
}

local Connections = {} :: {RBXScriptConnection}
local WatchedInstances = {} :: {[Instance]: boolean}

-- ============================================================================
-- FUNÇÕES UTILITÁRIAS E FILTROS
-- ============================================================================
local function getCleanPath(inst: Instance): string
	local path = inst.Name
	local current = inst.Parent
	while current and current ~= game and current ~= LocalPlayer do
		path = current.Name .. "." .. path
		current = current.Parent
	end
	return path
end

local function containsKeyword(str: string, list: {string}): boolean
	local lower = string.lower(str)
	for _, word in ipairs(list) do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

local function isRelevantPath(path: string): boolean
	if string.find(path, "StarSpeedProfilerUI", 1, true) then
		return false
	end
	if containsKeyword(path, IGNORE_KEYWORDS) then
		return false
	end
	return containsKeyword(path, GACHA_KEYWORDS)
end

local function looksLikeTimerText(text: string): boolean
	if string.match(text, "^%d+:%d+") then return true end
	if string.match(string.lower(text), "%d+%s*[hms]%s+%d+%s*[hms]") then return true end
	return false
end

local function parsePityText(text: string): (number?, number?)
	local cur, max = string.match(text, "(%d+)%s*/%s*(%d+)")
	if cur and max then
		return tonumber(cur), tonumber(max)
	end
	if containsKeyword(text, {"pity"}) then
		local single = string.match(text, "(%d+)")
		if single then
			return tonumber(single), nil
		end
	end
	return nil, nil
end

local function debugPrint(signalType: string, path: string, details: string, isTrigger: boolean)
	if not DEBUG then return end
	local now = os.clock()
	local relTimeStr = ""
	if State.LastOpeningTimestamp then
		relTimeStr = string.format(" (+%.3fs após última abertura)", now - State.LastOpeningTimestamp)
	end
	local tag = isTrigger and "[TRIGGER DE ABERTURA]" or "[DEBUG - IGNORADO NA CONTAGEM]"
	print(string.format("%s [%s]%s\nCaminho: %s\n%s", tag, signalType, relTimeStr, path, details))
end

-- ============================================================================
-- NÚCLEO DE DETECÇÃO DE ABERTURA (1 CICLO = 1 ABERTURA)
-- ============================================================================
local function handleSignal(signalType: string, sourcePath: string, details: string)
	local canTrigger = SIGNAL_CONFIG[signalType] == true

	-- 1. Se for ChildAdded, ImageChange, TextChange ou Currency, apenas imprime no DEBUG e sai
	if not canTrigger then
		debugPrint(signalType, sourcePath, details, false)
		return
	end

	-- 2. Verifica filtro manual, se configurado
	if MANUAL_LOCKED_PATH and sourcePath ~= MANUAL_LOCKED_PATH then
		debugPrint(signalType, sourcePath, details .. " (Ignorado por MANUAL_LOCKED_PATH)", false)
		return
	end

	local now = os.clock()
	local priority = SIGNAL_PRIORITY[signalType] or 1

	-- 3. Verifica se estamos dentro da janela de deduplicação da abertura atual
	if State.LastOpeningTimestamp and (now - State.LastOpeningTimestamp) <= DEDUP_WINDOW then
		-- Se um sinal de prioridade MAIOR (ex: Pity) disparar poucos milissegundos após
		-- um GuiVisible no primeiro giro, promovemos o Pity para ser a Âncora oficial
		-- sem somar uma nova abertura!
		if AUTO_ANCHOR and not MANUAL_LOCKED_PATH and priority > State.AnchorPriority then
			State.AnchorPath = sourcePath
			State.AnchorType = signalType
			State.AnchorPriority = priority
			debugPrint(signalType, sourcePath, details .. " -> [PROMOVIDO A SINAL ÂNCORA]", true)
		else
			debugPrint(signalType, sourcePath, details .. " (Deduplicado dentro da janela)", false)
		end
		return
	end

	-- 4. Lógica de Sinal Âncora (garante que apenas 1 único objeto marque os ciclos)
	if AUTO_ANCHOR and not MANUAL_LOCKED_PATH then
		if State.AnchorPath == nil then
			State.AnchorPath = sourcePath
			State.AnchorType = signalType
			State.AnchorPriority = priority
		elseif sourcePath ~= State.AnchorPath then
			-- Se aparecer um sinal de prioridade mais alta (ex: Pity), assume a âncora;
			-- caso contrário, ignora sinais paralelos fora de hora.
			if priority > State.AnchorPriority then
				State.AnchorPath = sourcePath
				State.AnchorType = signalType
				State.AnchorPriority = priority
			else
				debugPrint(signalType, sourcePath, details .. " (Ignorado: diferente do Sinal Âncora)", false)
				return
			end
		end
	end

	debugPrint(signalType, sourcePath, details, true)

	-- Só registra nas métricas se o botão [START] estiver ativo
	if not State.IsRunning then
		return
	end

	local interval: number? = nil
	if State.LastOpeningTimestamp ~= nil then
		interval = now - State.LastOpeningTimestamp
		State.LastInterval = interval
		table.insert(State.Intervals, interval)

		if interval < State.MinInterval then
			State.MinInterval = interval
		end
		if interval > State.MaxInterval then
			State.MaxInterval = interval
		end
	end

	State.LastOpeningTimestamp = now
	State.TotalOpenings += 1

	table.insert(State.OpeningHistory, {
		opening = State.TotalOpenings,
		timestamp = now,
		interval = interval,
		source = sourcePath,
		signalType = signalType,
	})
end

-- ============================================================================
-- DETECTORES PASSIVOS
-- ============================================================================

-- Detector de TextLabels: Separa Pity (Trigger Primário) de TextChange comum (Apenas Debug)
local function watchTextLabel(label: TextLabel, path: string)
	local lastText = label.Text
	local isPityLabel = (parsePityText(lastText) ~= nil) or containsKeyword(path, {"pity"})
	local isPathRelevant = isRelevantPath(path)

	local conn = label:GetPropertyChangedSignal("Text"):Connect(function()
		local newText = label.Text
		if newText == lastText or newText == "" then return end
		if looksLikeTimerText(newText) then
			lastText = newText
			return
		end

		local oldCur, _ = parsePityText(lastText)
		local newCur, _ = parsePityText(newText)
		local prevStr = lastText
		lastText = newText

		-- Se for contador de Pity (ex: 20/100 -> 26/100), dispara APENAS 1 abertura
		if (oldCur and newCur and oldCur ~= newCur) or isPityLabel then
			handleSignal("Pity", path, string.format("Anterior: %s | Novo: %s", prevStr, newText))
			return
		end

		-- Demais textos relevantes ficam estritamente como TextChange (APENAS DEBUG)
		if isPathRelevant then
			handleSignal("TextChange", path, string.format("Anterior: %s | Novo: %s", prevStr, newText))
		end
	end)

	table.insert(Connections, conn)
end

-- Detector de Moedas (Estritamente DEBUG nesta versão)
local function watchValueObject(valObj: ValueBase, path: string)
	if not (valObj:IsA("NumberValue") or valObj:IsA("IntValue")) then return end
	if containsKeyword(path, IGNORE_KEYWORDS) then return end

	local numObj = valObj :: NumberValue
	local lastVal = numObj.Value

	local conn = numObj:GetPropertyChangedSignal("Value"):Connect(function()
		local newVal = numObj.Value
		local diff = newVal - lastVal
		local prevVal = lastVal
		lastVal = newVal

		if diff < 0 then
			handleSignal("Currency", path, string.format("%s -> %s (Delta: %s)", tostring(prevVal), tostring(newVal), tostring(diff)))
		end
	end)

	table.insert(Connections, conn)
end

-- Detector de Atributos do LocalPlayer
local function watchPlayerAttributes()
	local lastAttrs = LocalPlayer:GetAttributes()

	local conn = LocalPlayer.AttributeChanged:Connect(function(attrName: string)
		local newVal = LocalPlayer:GetAttribute(attrName)
		local oldVal = lastAttrs[attrName]
		lastAttrs[attrName] = newVal

		local attrPath = "LocalPlayer.Attribute." .. attrName

		if typeof(newVal) == "number" and typeof(oldVal) == "number" then
			if containsKeyword(attrName, {"pity", "roll", "star", "summon", "hatch", "open"}) and newVal > oldVal then
				handleSignal("AttrCounter", attrPath, string.format("%s -> %s", tostring(oldVal), tostring(newVal)))
			elseif newVal < oldVal and not containsKeyword(attrName, IGNORE_KEYWORDS) then
				handleSignal("Currency", attrPath, string.format("%s -> %s", tostring(oldVal), tostring(newVal)))
			end
		end
	end)

	table.insert(Connections, conn)
end

-- Detector de Objetos de GUI
local function watchGuiObject(guiObj: Instance, path: string)
	if WatchedInstances[guiObj] then return end
	WatchedInstances[guiObj] = true

	if guiObj:IsA("TextLabel") then
		watchTextLabel(guiObj, path)
	end

	if not isRelevantPath(path) then return end

	-- ScreenGui ativada (Início de Abertura)
	if guiObj:IsA("ScreenGui") then
		local conn = guiObj:GetPropertyChangedSignal("Enabled"):Connect(function()
			if guiObj.Enabled then
				handleSignal("ScreenGuiEnabled", path, "Enabled = true")
			end
		end)
		table.insert(Connections, conn)

	-- Frame/GuiObject ficando visível
	elseif guiObj:IsA("GuiObject") then
		local conn = guiObj:GetPropertyChangedSignal("Visible"):Connect(function()
			if guiObj.Visible then
				-- Se for um card/slot interno de personagem, trata apenas como DEBUG
				if containsKeyword(path, CARD_SUBELEMENT_KEYWORDS) then
					debugPrint("GuiVisibleSubElement", path, "Visible = true (Sub-elemento de carta)", false)
				elseif containsKeyword(path, {"result", "summon", "roll", "hatch", "open", "star"}) then
					handleSignal("GuiVisible", path, "Visible = true")
				end
			end
		end)
		table.insert(Connections, conn)
	end

	-- Mudança de Imagem (Estritamente DEBUG)
	if guiObj:IsA("ImageLabel") and containsKeyword(path, {"result", "unit", "character", "icon", "viewport"}) then
		local lastImg = guiObj.Image
		local conn = guiObj:GetPropertyChangedSignal("Image"):Connect(function()
			local newImg = guiObj.Image
			if newImg ~= lastImg and newImg ~= "" then
				local prevImg = lastImg
				lastImg = newImg
				handleSignal("ImageChange", path, string.format("Anterior: %s | Novo: %s", prevImg, newImg))
			end
		end)
		table.insert(Connections, conn)
	end

	-- ChildAdded (Estritamente DEBUG)
	if guiObj:IsA("GuiObject") or guiObj:IsA("Folder") or guiObj:IsA("ScreenGui") then
		local conn = guiObj.ChildAdded:Connect(function(child)
			if child:IsA("UILayout") or child:IsA("UIConstraint") or child:IsA("UICorner") or child:IsA("UIStroke") then
				return
			end
			local childPath = path .. "." .. child.Name
			if containsKeyword(childPath, {"result", "unit", "character", "card", "template", "star", "summon", "roll"}) then
				handleSignal("ChildAdded", childPath, "Classe: " .. child.ClassName)
			end
		end)
		table.insert(Connections, conn)
	end
end

-- ============================================================================
-- ESCANEAMENTO E RECALIBRAÇÃO
-- ============================================================================
local function clearWatchers()
	for _, conn in ipairs(Connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(Connections)
	table.clear(WatchedInstances)
end

local function scanAndConnect()
	clearWatchers()

	for _, desc in ipairs(PlayerGui:GetDescendants()) do
		watchGuiObject(desc, "PlayerGui." .. getCleanPath(desc))
	end

	local pgAddedConn = PlayerGui.DescendantAdded:Connect(function(desc)
		watchGuiObject(desc, "PlayerGui." .. getCleanPath(desc))
	end)
	table.insert(Connections, pgAddedConn)

	for _, desc in ipairs(LocalPlayer:GetDescendants()) do
		if desc:IsA("ValueBase") and not desc:IsDescendantOf(PlayerGui) then
			watchValueObject(desc, "LocalPlayer." .. getCleanPath(desc))
		end
	end

	local lpAddedConn = LocalPlayer.DescendantAdded:Connect(function(desc)
		if desc:IsA("ValueBase") and not desc:IsDescendantOf(PlayerGui) then
			watchValueObject(desc, "LocalPlayer." .. getCleanPath(desc))
		end
	end)
	table.insert(Connections, lpAddedConn)

	watchPlayerAttributes()

	if DEBUG then
		print("[STAR PROFILER v2] Monitorando ABERTURAS (ChildAdded/Text/Image/Currency = apenas DEBUG).")
	end
end

-- ============================================================================
-- CÁLCULO DE MÉTRICAS E RELATÓRIO FINAL
-- ============================================================================
local function getRollingWindowCounts(now: number): (number, number, number)
	local c10, c30, c60 = 0, 0, 0
	for i = #State.OpeningHistory, 1, -1 do
		local entry = State.OpeningHistory[i]
		local age = now - entry.timestamp
		if age <= 10 then
			c10 += 1
			c30 += 1
			c60 += 1
		elseif age <= 30 then
			c30 += 1
			c60 += 1
		elseif age <= 60 then
			c60 += 1
		else
			break
		end
	end
	return c10, c30, c60
end

local function getAverageInterval(): number
	if #State.Intervals == 0 then return 0 end
	local sum = 0
	for _, v in ipairs(State.Intervals) do
		sum += v
	end
	return sum / #State.Intervals
end

local function printFinalReport()
	local totalTime = State.ElapsedTime
	local totalOpenings = State.TotalOpenings
	local opm = (totalTime > 0) and ((totalOpenings / totalTime) * 60) or 0
	local avgInterval = getAverageInterval()
	local minInt = (State.MinInterval == math.huge) and 0 or State.MinInterval
	local maxInt = State.MaxInterval

	print("\n===== STAR BATCH SPEED TEST (v2) =====")
	print(string.format("Tempo total: %.2f segundos", totalTime))
	print(string.format("Aberturas: %d", totalOpenings))
	print(string.format("Aberturas/minuto: %.1f", opm))
	print(string.format("Intervalo médio entre aberturas: %.3fs", avgInterval))
	print(string.format("Menor intervalo: %.3fs", minInt))
	print(string.format("Maior intervalo: %.3fs", maxInt))
	print(string.format("Último intervalo: %.3fs", State.LastInterval))
	print(string.format("Sinal Âncora usado: [%s] %s", tostring(State.AnchorType or "Nenhum"), tostring(State.AnchorPath or "Nenhum")))
	print("\nPrimeiros 10 intervalos:")
	if #State.Intervals == 0 then
		print("  (Nenhum intervalo registrado)")
	else
		for i = 1, math.min(10, #State.Intervals) do
			print(string.format("  #%d: %.3fs", i, State.Intervals[i]))
		end
	end
	print("======================================\n")
end

-- ============================================================================
-- INTERFACE GRÁFICA (GUI COMPACTA)
-- ============================================================================
local function createUI()
	local parentGui = PlayerGui
	pcall(function()
		if CoreGui:FindFirstChild("StarSpeedProfilerUI") then
			CoreGui.StarSpeedProfilerUI:Destroy()
		end
		parentGui = CoreGui
	end)
	if PlayerGui:FindFirstChild("StarSpeedProfilerUI") then
		PlayerGui.StarSpeedProfilerUI:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StarSpeedProfilerUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = parentGui

	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 310, 0, 325)
	mainFrame.Position = UDim2.new(0.02, 0, 0.3, 0)
	mainFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	mainFrame.BorderSizePixel = 0
	mainFrame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = mainFrame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(65, 70, 90)
	stroke.Thickness = 1.5
	stroke.Parent = mainFrame

	local titleBar = Instance.new("Frame")
	titleBar.Size = UDim2.new(1, 0, 0, 30)
	titleBar.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
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
	titleLabel.Text = "STAR BATCH PROFILER v2"
	titleLabel.TextColor3 = Color3.fromRGB(240, 240, 255)
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
	statsLabel.Size = UDim2.new(1, -24, 0, 195)
	statsLabel.BackgroundTransparency = 1
	statsLabel.Font = Enum.Font.RobotoMono
	statsLabel.TextColor3 = Color3.fromRGB(220, 225, 235)
	statsLabel.TextSize = 12
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel.TextYAlignment = Enum.TextYAlignment.Top
	statsLabel.RichText = true
	statsLabel.TextTruncate = Enum.TextTruncate.AtEnd
	statsLabel.Parent = mainFrame

	local function makeButton(text: string, pos: UDim2, size: UDim2, color: Color3): TextButton
		local btn = Instance.new("TextButton")
		btn.Size = size
		btn.Position = pos
		btn.BackgroundColor3 = color
		btn.Font = Enum.Font.GothamBold
		btn.Text = text
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.TextSize = 12
		btn.AutoButtonColor = true
		btn.Parent = mainFrame

		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 5)
		c.Parent = btn
		return btn
	end

	local startBtn = makeButton("[START]", UDim2.new(0, 10, 0, 240), UDim2.new(0, 92, 0, 32), Color3.fromRGB(40, 140, 75))
	local stopBtn  = makeButton("[STOP]",  UDim2.new(0, 109, 0, 240), UDim2.new(0, 92, 0, 32), Color3.fromRGB(175, 55, 55))
	local resetBtn = makeButton("[RESET]", UDim2.new(0, 208, 0, 240), UDim2.new(0, 92, 0, 32), Color3.fromRGB(70, 80, 100))

	local recalibBtn = makeButton("RECALIBRAR", UDim2.new(0, 10, 0, 280), UDim2.new(0, 140, 0, 30), Color3.fromRGB(55, 95, 160))
	local debugBtn   = makeButton("DEBUG: ON",  UDim2.new(0, 160, 0, 280), UDim2.new(0, 140, 0, 30), Color3.fromRGB(110, 80, 150))

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
		State.StartTime = os.clock() - State.ElapsedTime
		print("[STAR PROFILER v2] Medição de ABERTURAS iniciada.")
	end)

	stopBtn.MouseButton1Click:Connect(function()
		if State.IsRunning then
			State.ElapsedTime = os.clock() - State.StartTime
			State.IsRunning = false
		end
		printFinalReport()
	end)

	resetBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		State.StartTime = 0
		State.ElapsedTime = 0
		State.TotalOpenings = 0
		State.LastOpeningTimestamp = nil
		State.AnchorPath = nil
		State.AnchorType = nil
		State.AnchorPriority = 0
		State.MinInterval = math.huge
		State.MaxInterval = 0
		State.LastInterval = 0
		table.clear(State.Intervals)
		table.clear(State.OpeningHistory)
		print("[STAR PROFILER v2] Histórico e Sinal Âncora resetados.")
	end)

	recalibBtn.MouseButton1Click:Connect(function()
		State.AnchorPath = nil
		State.AnchorType = nil
		State.AnchorPriority = 0
		scanAndConnect()
	end)

	debugBtn.MouseButton1Click:Connect(function()
		DEBUG = not DEBUG
		debugBtn.Text = DEBUG and "DEBUG: ON" or "DEBUG: OFF"
		debugBtn.BackgroundColor3 = DEBUG and Color3.fromRGB(110, 80, 150) or Color3.fromRGB(60, 60, 70)
	end)

	local renderConn
	renderConn = RunService.RenderStepped:Connect(function()
		local now = os.clock()
		if State.IsRunning then
			State.ElapsedTime = now - State.StartTime
		end

		local elapsed = State.ElapsedTime
		local opm = (elapsed > 0) and ((State.TotalOpenings / elapsed) * 60) or 0
		local avgInt = getAverageInterval()
		local minInt = (State.MinInterval == math.huge) and 0 or State.MinInterval
		local maxInt = State.MaxInterval
		local c10, c30, c60 = getRollingWindowCounts(now)

		statsLabel.Text = string.format(
			"STATUS: %s | TEMPO: %.2fs\n" ..
			"ABERTURAS: %d\n" ..
			"ABERTURAS/MIN: %.1f\n" ..
			"INTERVALO MÉDIO ENTRE ABERTURAS: %.3fs\n" ..
			"MENOR INTERVALO: %.3fs\n" ..
			"MAIOR INTERVALO: %.3fs\n" ..
			"ÚLTIMO INTERVALO: %.3fs\n" ..
			"10s | 30s | 60s: %d | %d | %d\n" ..
			"ÂNCORA: %s",
			State.IsRunning and '<font color="#55ff7f">RODANDO</font>' or '<font color="#ffaa55">PARADO</font>',
			elapsed,
			State.TotalOpenings,
			opm,
			avgInt,
			minInt,
			maxInt,
			State.LastInterval,
			c10, c30, c60,
			State.AnchorType and (State.AnchorType .. " (Travado)") or "Aguardando 1º giro..."
		)
	end)

	closeBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		if renderConn then renderConn:Disconnect() end
		if dragConn then dragConn:Disconnect() end
		clearWatchers()
		screenGui:Destroy()
		print("[STAR PROFILER v2] Encerrado.")
	end)
end

-- ============================================================================
-- INICIALIZAÇÃO
-- ============================================================================
createUI()
scanAndConnect()
