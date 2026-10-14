--[[
    STAR SPEED PROFILER & GACHA DIAGNOSTIC (READ-ONLY)
    Jogo alvo: Anime Legacy Simulator
    Objetivo: Medir com alta precisão (os.clock) a cadência real de abertura de Stars
              e descobrir os sinais mais confiáveis na UI/Dados do cliente.
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
local DEBUG = true -- Imprime mudanças detectadas no console (F9)
local DEDUP_WINDOW = 0.15 -- Janela (em segundos) para agrupar sinais do MESMO giro

-- Se após o primeiro teste você descobrir o caminho exato (ex: "PlayerGui.Main.Star.Pity"),
-- você pode preenchê-lo abaixo para ignorar outros sinais. Deixe nil para detecção automática.
local LOCKED_SIGNAL_PATH: string? = nil

-- Palavras-chave para filtrar apenas objetos relacionados ao Gacha/Stars
local GACHA_KEYWORDS = {
	"star", "summon", "roll", "open", "hatch", "gacha",
	"pity", "result", "unit", "character", "capsule", "banner", "pull"
}

-- Palavras-chave ignoradas para evitar falsos positivos (timers de banner, FPS, chat, etc.)
local IGNORE_KEYWORDS = {
	"timer", "cooldown", "fps", "ping", "clock", "timeleft",
	"refresh", "reset", "chat", "bubble", "health", "xp", "quest", "index"
}

-- ============================================================================
-- ESTADO DO TESTE E HISTÓRICO
-- ============================================================================
export type RollEntry = {
	roll: number,
	timestamp: number,
	interval: number?,
	batchSize: number,
	source: string
}

local State = {
	IsRunning = false,
	StartTime = 0,
	ElapsedTime = 0,

	TotalRolls = 0,          -- Total de Stars abertas (conta x3/x10)
	TotalBatches = 0,        -- Total de cliques/ciclos de abertura
	LastRollTimestamp = nil :: number?,

	-- Controle de Deduplicação e Multi-Roll dentro da mesma janela
	CurrentBatchTimestamp = 0,
	CurrentBatchCount = 0,
	CurrentBatchSpawnedCards = 0,

	MinInterval = math.huge,
	MaxInterval = 0,
	LastInterval = 0,
	LastSignalPath = "Nenhum",

	Intervals = {} :: {number},
	RollHistory = {} :: {RollEntry},
}

-- Armazenamento de conexões para evitar Memory Leak
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

-- Ignora textos que são apenas relógios/contadores de tempo (ex: "14:59", "5m 30s")
local function looksLikeTimerText(text: string): boolean
	if string.match(text, "^%d+:%d+") then return true end
	if string.match(string.lower(text), "%d+%s*[hms]%s+%d+%s*[hms]") then return true end
	return false
end

-- Tenta extrair valores de Pity em textos como "34/100", "Pity: 20 / 50", etc.
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

local function debugLog(category: string, path: string, details: string)
	if not DEBUG then return end
	print(string.format("[DEBUG] %s:\n%s\n%s", category, path, details))
end

-- ============================================================================
-- NÚCLEO DE REGISTRO DE GIROS E DEDUPLICAÇÃO
-- ============================================================================
local function registerRollSignal(sourcePath: string, detectedRollCount: number?, signalType: string)
	if LOCKED_SIGNAL_PATH and sourcePath ~= LOCKED_SIGNAL_PATH then
		return
	end

	local now = os.clock()
	local rollsToAdd = math.max(1, detectedRollCount or 1)
	State.LastSignalPath = string.format("[%s] %s", signalType, sourcePath)

	-- Só contabiliza nas métricas se o cronômetro tiver sido iniciado no [START]
	if not State.IsRunning then
		return
	end

	local timeSinceCurrentBatch = now - State.CurrentBatchTimestamp

	-- CASO 1: Estamos DENTRO da janela de deduplicação (DEDUP_WINDOW)
	-- Isso significa que múltiplos elementos da UI mudaram juntos no mesmo giro.
	if State.CurrentBatchTimestamp > 0 and timeSinceCurrentBatch <= DEDUP_WINDOW then
		-- Se um sinal mais preciso (como Pity ou múltiplos cards criados) indicar que foi
		-- um Multi-Roll (ex: x3 ou x10) maior do que o registrado no primeiro milissegundo,
		-- atualizamos apenas a diferença de Stars abertas sem criar um intervalo falso!
		if rollsToAdd > State.CurrentBatchCount then
			local diff = rollsToAdd - State.CurrentBatchCount
			State.CurrentBatchCount = rollsToAdd

			for _ = 1, diff do
				State.TotalRolls += 1
				table.insert(State.RollHistory, {
					roll = State.TotalRolls,
					timestamp = State.CurrentBatchTimestamp,
					interval = nil, -- Parte do mesmo pacote multi-roll
					batchSize = rollsToAdd,
					source = sourcePath
				})
			end
		end
		return
	end

	-- CASO 2: NOVO GIRO DETECTADO (Fora da janela de deduplicação)
	local interval: number? = nil
	if State.LastRollTimestamp ~= nil then
		interval = now - State.LastRollTimestamp
		State.LastInterval = interval
		table.insert(State.Intervals, interval)

		if interval < State.MinInterval then
			State.MinInterval = interval
		end
		if interval > State.MaxInterval then
			State.MaxInterval = interval
		end
	end

	State.LastRollTimestamp = now
	State.CurrentBatchTimestamp = now
	State.CurrentBatchCount = rollsToAdd
	State.CurrentBatchSpawnedCards = 0
	State.TotalBatches += 1

	for i = 1, rollsToAdd do
		State.TotalRolls += 1
		table.insert(State.RollHistory, {
			roll = State.TotalRolls,
			timestamp = now,
			interval = (i == 1) and interval or nil, -- Registra o intervalo real na abertura do lote
			batchSize = rollsToAdd,
			source = sourcePath
		})
	end
end

-- ============================================================================
-- DETECTORES HEURÍSTICOS (PASSIVOS)
-- ============================================================================

-- Detector 1 & 5: TextLabels (Pity, Nome de Personagem Obtido, Textos de Gacha)
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

		local oldCur, oldMax = parsePityText(lastText)
		local newCur, newMax = parsePityText(newText)

		-- Sinais de Pity têm altíssima confiabilidade e detectam Multi-Rolls (x3, x10)
		if (oldCur and newCur) or isPityLabel then
			local prevStr = lastText
			lastText = newText

			debugLog("TextLabel (Pity) mudou", path, string.format("Anterior: %s\nNovo: %s", prevStr, newText))

			local delta = 1
			if oldCur and newCur then
				if newCur > oldCur then
					delta = newCur - oldCur
				elseif newCur < oldCur and oldMax and newCur > 0 then
					-- Caso o Pity tenha resetado ao atingir o limite (ex: 99/100 -> 2/100 num x3)
					local wrapped = (oldMax - oldCur) + newCur
					if wrapped > 0 and wrapped <= 20 then
						delta = wrapped
					end
				end
			end
			-- Limite de segurança para evitar leituras incorretas de outros números
			if delta > 0 and delta <= 50 then
				registerRollSignal(path, delta, "Pity")
			end
			return
		end

		-- Outros TextLabels relevantes (ex: nome do personagem recebido, raridade)
		if isPathRelevant then
			local prevStr = lastText
			lastText = newText
			debugLog("TextLabel mudou", path, string.format("Anterior: %s\nNovo: %s", prevStr, newText))

			-- Se for um texto dentro de área de Result/Summon/Unit, conta como sinal de giro
			if containsKeyword(path, {"result", "unit", "character", "summon", "hatch", "open", "roll"}) then
				registerRollSignal(path, 1, "TextChange")
			end
		else
			lastText = newText
		end
	end)

	table.insert(Connections, conn)
end

-- Detector 2: Moedas / Currencies (Leaderstats, pastas de dados e Atributos)
-- IMPORTANTE: Só dispara sinal de giro quando a moeda DIMINUI (compra da Star),
-- ignorando quando você ganha moedas derrotando inimigos.
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

		-- Se a moeda diminuiu, é um forte indicativo de compra de Star/Gacha
		if diff < 0 then
			debugLog("Currency mudou (Gasto detectado)", path, string.format("%s -> %s (Delta: %s)", tostring(prevVal), tostring(newVal), tostring(diff)))
			registerRollSignal(path, 1, "CurrencySpend")
		end
	end)

	table.insert(Connections, conn)
end

local function watchPlayerAttributes()
	local lastAttrs = LocalPlayer:GetAttributes()

	local conn = LocalPlayer.AttributeChanged:Connect(function(attrName: string)
		local newVal = LocalPlayer:GetAttribute(attrName)
		local oldVal = lastAttrs[attrName]
		lastAttrs[attrName] = newVal

		local attrPath = "LocalPlayer.Attribute." .. attrName

		if typeof(newVal) == "number" and typeof(oldVal) == "number" then
			if containsKeyword(attrName, {"pity", "roll", "star", "summon", "hatch"}) and newVal > oldVal then
				local delta = math.clamp(math.floor(newVal - oldVal), 1, 50)
				debugLog("Attribute (Pity/Counter) mudou", attrPath, string.format("%s -> %s", tostring(oldVal), tostring(newVal)))
				registerRollSignal(attrPath, delta, "AttrCounter")
			elseif newVal < oldVal and not containsKeyword(attrName, IGNORE_KEYWORDS) then
				debugLog("Currency/Attribute diminuiu", attrPath, string.format("%s -> %s", tostring(oldVal), tostring(newVal)))
				registerRollSignal(attrPath, 1, "AttrSpend")
			end
		end
	end)

	table.insert(Connections, conn)
end

-- Detector 3, 4 & 5: Visibilidade de Frames, Imagens e Criação de Cards de Resultado
local function watchGuiObject(guiObj: Instance, path: string)
	if WatchedInstances[guiObj] then return end
	WatchedInstances[guiObj] = true

	if guiObj:IsA("TextLabel") then
		watchTextLabel(guiObj, path)
	end

	if not isRelevantPath(path) then return end

	-- Detector 3: Aparecimento de GUI (Visible / Enabled)
	if guiObj:IsA("GuiObject") then
		local conn = guiObj:GetPropertyChangedSignal("Visible"):Connect(function()
			if guiObj.Visible then
				debugLog("GUI ficou visível", path, "Visible = true")
				if containsKeyword(path, {"result", "summon", "roll", "hatch", "open", "star", "unit"}) then
					registerRollSignal(path, 1, "GuiVisible")
				end
			end
		end)
		table.insert(Connections, conn)
	elseif guiObj:IsA("ScreenGui") then
		local conn = guiObj:GetPropertyChangedSignal("Enabled"):Connect(function()
			if guiObj.Enabled then
				debugLog("ScreenGui ativada", path, "Enabled = true")
				registerRollSignal(path, 1, "ScreenGuiEnabled")
			end
		end)
		table.insert(Connections, conn)
	end

	-- Detector 5: Mudança de Imagem de Personagem/Unidade
	if guiObj:IsA("ImageLabel") and containsKeyword(path, {"result", "unit", "character", "icon", "viewport"}) then
		local lastImg = guiObj.Image
		local conn = guiObj:GetPropertyChangedSignal("Image"):Connect(function()
			local newImg = guiObj.Image
			if newImg ~= lastImg and newImg ~= "" then
				debugLog("ImageLabel mudou", path, string.format("Anterior: %s\nNovo: %s", lastImg, newImg))
				lastImg = newImg
				registerRollSignal(path, 1, "ImageChange")
			end
		end)
		table.insert(Connections, conn)
	end

	-- Detector 4: Criação dinâmica de Frames/Modelos nos containers de resultado (suporta x3 / x10)
	if guiObj:IsA("GuiObject") or guiObj:IsA("Folder") or guiObj:IsA("ScreenGui") then
		local conn = guiObj.ChildAdded:Connect(function(child)
			if child:IsA("UILayout") or child:IsA("UIConstraint") or child:IsA("UICorner") or child:IsA("UIStroke") then
				return
			end
			local childPath = path .. "." .. child.Name
			debugLog("GUI/Objeto criado (ChildAdded)", childPath, "Tipo: " .. child.ClassName)

			if containsKeyword(childPath, {"result", "unit", "character", "card", "template", "star", "summon", "roll"}) then
				local now = os.clock()
				if (now - State.CurrentBatchTimestamp) <= DEDUP_WINDOW then
					State.CurrentBatchSpawnedCards += 1
				else
					State.CurrentBatchSpawnedCards = 1
				end
				registerRollSignal(childPath, State.CurrentBatchSpawnedCards, "ChildAdded")
			end
		end)
		table.insert(Connections, conn)
	end
end

-- ============================================================================
-- SISTEMA DE ESCANEAMENTO E RECALIBRAÇÃO
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

	-- 1. Monitora tudo dentro do PlayerGui atual e futuros elementos criados
	for _, desc in ipairs(PlayerGui:GetDescendants()) do
		watchGuiObject(desc, "PlayerGui." .. getCleanPath(desc))
	end

	local pgAddedConn = PlayerGui.DescendantAdded:Connect(function(desc)
		local path = "PlayerGui." .. getCleanPath(desc)
		watchGuiObject(desc, path)
	end)
	table.insert(Connections, pgAddedConn)

	-- 2. Monitora ValueObjects no LocalPlayer (leaderstats, Data, Currencies, etc.)
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

	-- 3. Monitora Atributos do LocalPlayer
	watchPlayerAttributes()

	if DEBUG then
		print("[STAR PROFILER] Escaneamento concluído! Monitorando eventos do cliente passivamente.")
	end
end

-- ============================================================================
-- CÁLCULO DE MÉTRICAS E RELATÓRIO FINAL
-- ============================================================================
local function getRollingWindowCounts(now: number): (number, number, number)
	local c10, c30, c60 = 0, 0, 0
	for i = #State.RollHistory, 1, -1 do
		local entry = State.RollHistory[i]
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
			break -- Como o histórico é cronológico, podemos parar aqui (otimização O(1) média)
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
	local totalRolls = State.TotalRolls
	local rpm = (totalTime > 0) and ((totalRolls / totalTime) * 60) or 0
	local avgInterval = getAverageInterval()
	local minInt = (State.MinInterval == math.huge) and 0 or State.MinInterval
	local maxInt = State.MaxInterval

	print("\n===== STAR SPEED TEST =====")
	print(string.format("Tempo: %.2f segundos", totalTime))
	print(string.format("Giros: %d (Ciclos/Aberturas: %d)", totalRolls, State.TotalBatches))
	print(string.format("Giros/minuto: %.1f", rpm))
	print(string.format("Tempo médio/giro: %.3fs", avgInterval))
	print(string.format("Menor intervalo: %.3fs", minInt))
	print(string.format("Maior intervalo: %.3fs", maxInt))
	print(string.format("Último sinal usado: %s", State.LastSignalPath))
	print("\nPrimeiros 10 intervalos:")
	if #State.Intervals == 0 then
		print("  (Nenhum intervalo registrado)")
	else
		for i = 1, math.min(10, #State.Intervals) do
			print(string.format("  %.3f", State.Intervals[i]))
		end
	end
	print("===========================\n")
end

-- ============================================================================
-- INTERFACE GRÁFICA (GUI COMPACTA E ARRASTÁVEL)
-- ============================================================================
local function createUI()
	-- Remove UI anterior se já existir
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
	mainFrame.Size = UDim2.new(0, 270, 0, 310)
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

	-- Barra de Título
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
	titleLabel.Text = "STAR SPEED PROFILER"
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

	-- Texto das Métricas
	local statsLabel = Instance.new("TextLabel")
	statsLabel.Position = UDim2.new(0, 12, 0, 38)
	statsLabel.Size = UDim2.new(1, -24, 0, 175)
	statsLabel.BackgroundTransparency = 1
	statsLabel.Font = Enum.Font.RobotoMono
	statsLabel.TextColor3 = Color3.fromRGB(220, 225, 235)
	statsLabel.TextSize = 13
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel.TextYAlignment = Enum.TextYAlignment.Top
	statsLabel.RichText = true
	statsLabel.Parent = mainFrame

	-- Criador de Botões
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

	local startBtn = makeButton("[START]", UDim2.new(0, 10, 0, 225), UDim2.new(0, 80, 0, 32), Color3.fromRGB(40, 140, 75))
	local stopBtn  = makeButton("[STOP]",  UDim2.new(0, 95, 0, 225), UDim2.new(0, 80, 0, 32), Color3.fromRGB(175, 55, 55))
	local resetBtn = makeButton("[RESET]", UDim2.new(0, 180, 0, 225), UDim2.new(0, 80, 0, 32), Color3.fromRGB(70, 80, 100))

	local recalibBtn = makeButton("RECALIBRAR", UDim2.new(0, 10, 0, 265), UDim2.new(0, 122, 0, 30), Color3.fromRGB(55, 95, 160))
	local debugBtn   = makeButton("DEBUG: ON",  UDim2.new(0, 138, 0, 265), UDim2.new(0, 122, 0, 30), Color3.fromRGB(110, 80, 150))

	-- Dragging da Janela
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

	-- Eventos dos Botões
	startBtn.MouseButton1Click:Connect(function()
		if State.IsRunning then return end
		State.IsRunning = true
		State.StartTime = os.clock() - State.ElapsedTime
		print("[STAR PROFILER] Cronômetro e medição INICIADOS.")
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
		State.TotalRolls = 0
		State.TotalBatches = 0
		State.LastRollTimestamp = nil
		State.CurrentBatchTimestamp = 0
		State.CurrentBatchCount = 0
		State.CurrentBatchSpawnedCards = 0
		State.MinInterval = math.huge
		State.MaxInterval = 0
		State.LastInterval = 0
		table.clear(State.Intervals)
		table.clear(State.RollHistory)
		print("[STAR PROFILER] Dados resetados.")
	end)

	recalibBtn.MouseButton1Click:Connect(function()
		scanAndConnect()
	end)

	debugBtn.MouseButton1Click:Connect(function()
		DEBUG = not DEBUG
		debugBtn.Text = DEBUG and "DEBUG: ON" or "DEBUG: OFF"
		debugBtn.BackgroundColor3 = DEBUG and Color3.fromRGB(110, 80, 150) or Color3.fromRGB(60, 60, 70)
	end)

	-- Loop leve de atualização visual da interface
	local renderConn
	renderConn = RunService.RenderStepped:Connect(function()
		local now = os.clock()
		if State.IsRunning then
			State.ElapsedTime = now - State.StartTime
		end

		local elapsed = State.ElapsedTime
		local rpm = (elapsed > 0) and ((State.TotalRolls / elapsed) * 60) or 0
		local avgInt = getAverageInterval()
		local minInt = (State.MinInterval == math.huge) and 0 or State.MinInterval
		local maxInt = State.MaxInterval
		local c10, c30, c60 = getRollingWindowCounts(now)

		statsLabel.Text = string.format(
			"STATUS: %s\n" ..
			"GIROS: %d\n" ..
			"TEMPO: %.2fs\n" ..
			"GIROS/MIN: %.1f\n" ..
			"INTERVALO MÉDIO: %.2fs\n" ..
			"ÚLTIMO GIRO: %.2fs\n" ..
			"MENOR INTERVALO: %.2fs\n" ..
			"MAIOR INTERVALO: %.2fs\n" ..
			"10s | 30s | 60s: %d | %d | %d",
			State.IsRunning and '<font color="#55ff7f">RODANDO</font>' or '<font color="#ffaa55">PARADO</font>',
			State.TotalRolls,
			elapsed,
			rpm,
			avgInt,
			State.LastInterval,
			minInt,
			maxInt,
			c10, c30, c60
		)
	end)

	-- Limpeza total ao fechar no [X]
	closeBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		if renderConn then renderConn:Disconnect() end
		if dragConn then dragConn:Disconnect() end
		clearWatchers()
		screenGui:Destroy()
		print("[STAR PROFILER] Encerrado e todas as conexões foram limpas.")
	end)
end

-- ============================================================================
-- INICIALIZAÇÃO
-- ============================================================================
createUI()
scanAndConnect()
