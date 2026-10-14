--[[
    STAR SPEED PROFILER v3 (PITY TRUTH + A/B CLIENT SPEED TEST)
    Jogo alvo: Anime Legacy Simulator
    Fonte de verdade: PlayerGui.UI.Frames.Star.Pity.Value ("Mythical Pity: 5085/7500")
    Objetivo: Verificar se a aceleração de animações locais altera o intervalo real
              de atualização do Pity (~1.00s baseline) e comparar modos (NORMAL, 2x, 5x, 10x).
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
-- CONFIGURAÇÕES PRINCIPAIS
-- ============================================================================
local DEBUG = true
local SPEED_TEST = true
local SPEED_MULTIPLIER = 2 -- Opções na UI: 1 (NORMAL), 2, 5, 10
local BASELINE_SECONDS = 1.000
local DEFAULT_BATCH_DELTA = 9 -- Usado apenas se o Pity resetar no meio de um giro (ex: 7500/7500 -> 0/7500)

-- Janela mínima para ignorar micro-atualizações de texto duplicadas no mesmo frame
local PITY_DEDUP_WINDOW = 0.08

local STAR_KEYWORDS = {
	"star", "summon", "roll", "open", "hatch", "gacha", "capsule", "egg", "result", "banner"
}

-- ============================================================================
-- ESTRUTURAS DE DADOS E COMPARAÇÃO A/B
-- ============================================================================
export type ModeStats = {
	name: string,
	multiplier: number,
	openings: number,
	realRolls: number,
	lastInterval: number,
	minInterval: number,
	maxInterval: number,
	intervals: {number},
	activeTime: number,
}

local MODES_ORDER = { "NORMAL", "2x", "5x", "10x" }
local MULTIPLIER_TO_MODE: {[number]: string} = {
	[1] = "NORMAL",
	[2] = "2x",
	[5] = "5x",
	[10] = "10x",
}

local function createEmptyModeStats(name: string, mult: number): ModeStats
	return {
		name = name,
		multiplier = mult,
		openings = 0,
		realRolls = 0,
		lastInterval = 0,
		minInterval = math.huge,
		maxInterval = 0,
		intervals = {},
		activeTime = 0,
	}
end

local ABData: {[string]: ModeStats} = {
	["NORMAL"] = createEmptyModeStats("NORMAL", 1),
	["2x"]     = createEmptyModeStats("2x", 2),
	["5x"]     = createEmptyModeStats("5x", 5),
	["10x"]    = createEmptyModeStats("10x", 10),
}

local State = {
	IsRunning = false,
	LastTick = os.clock(),
	LastPityTimestamp = nil :: number?,
	LastPityValue = nil :: number?,
	LastPityMax = nil :: number?,
	PityObject = nil :: Instance?,
	PityResolvedPath = "Procurando...",

	AcceleratedTracksCount = 0,
	DetectedAnimControllers = {} :: {[string]: boolean},
}

local Connections = {} :: {RBXScriptConnection}
local WatchedAnimators = {} :: {[Instance]: boolean}

-- ============================================================================
-- UTILITÁRIOS (CORREÇÃO DO BUG DE PATH DUPLICADO)
-- ============================================================================
-- Agora retorna o caminho limpo sem duplicar "PlayerGui.PlayerGui"
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
	for _, word in ipairs(list) do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

local function getCurrentModeName(): string
	if not SPEED_TEST or SPEED_MULTIPLIER <= 1 then
		return "NORMAL"
	end
	return MULTIPLIER_TO_MODE[SPEED_MULTIPLIER] or (tostring(SPEED_MULTIPLIER) .. "x")
end

local function getCurrentModeStats(): ModeStats
	local modeName = getCurrentModeName()
	if not ABData[modeName] then
		ABData[modeName] = createEmptyModeStats(modeName, SPEED_TEST and SPEED_MULTIPLIER or 1)
	end
	return ABData[modeName]
end

-- Extrai (atual, máximo) de textos como "Mythical Pity: 5085/7500"
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
-- ESTATÍSTICAS E CLASSIFICAÇÃO DE GANHO REAL (ANTI-OUTLIER)
-- ============================================================================
local function getAverage(list: {number}): number
	if #list == 0 then return 0 end
	local sum = 0
	for _, v in ipairs(list) do
		sum += v
	end
	return sum / #list
end

-- Retorna o 2º menor intervalo para evitar que um único outlier distorça o diagnóstico
local function getRobustMinInterval(intervals: {number}): number
	local n = #intervals
	if n == 0 then return 0 end
	local copy = table.clone(intervals)
	table.sort(copy)
	if n >= 4 then
		return copy[2] -- Ignora o 1º valor isolado se houver amostra suficiente
	end
	return copy[1]
end

local function classifyModeResult(stats: ModeStats): string
	if stats.openings < 10 or #stats.intervals < 9 then
		return string.format("AGUARDANDO DADOS (%d/10)", stats.openings)
	end

	local below070 = 0
	local between070And095 = 0

	for _, iv in ipairs(stats.intervals) do
		if iv < 0.70 then
			below070 += 1
		elseif iv < 0.95 then
			between070And095 += 1
		end
	end

	-- Exige pelo menos 3 ocorrências consistentes (não considera um único outlier)
	if below070 >= 3 then
		return "GANHO REAL CONFIRMADO"
	elseif (below070 + between070And095) >= 3 then
		return "POSSÍVEL GANHO REAL"
	else
		return "SEM GANHO REAL / APENAS VISUAL"
	end
end

local function getImprovementPercent(stats: ModeStats): number
	if #stats.intervals == 0 then return 0 end
	local avg = getAverage(stats.intervals)
	local refBaseline = BASELINE_SECONDS
	local normalStats = ABData["NORMAL"]
	if stats.name ~= "NORMAL" and #normalStats.intervals >= 5 then
		refBaseline = getAverage(normalStats.intervals)
	end
	return ((refBaseline - avg) / refBaseline) * 100
end

-- ============================================================================
-- INSPETOR E ACELERADOR CLIENT-SIDE (ANIMAÇÕES & CONTROLES DE STAR)
-- ============================================================================
local function getEffectiveSpeed(): number
	if not SPEED_TEST then
		return 1
	end
	return SPEED_MULTIPLIER
end

local function applySpeedToTrack(track: AnimationTrack, animatorPath: string)
	local targetSpeed = getEffectiveSpeed()
	if targetSpeed <= 1 then return end

	pcall(function()
		if math.abs(track.Speed - targetSpeed) > 0.01 then
			track:AdjustSpeed(targetSpeed)
			State.AcceleratedTracksCount += 1
			if DEBUG then
				local animId = track.Animation and track.Animation.AnimationId or "Desconhecido"
				print(string.format(
					"[SPEED TEST %dx] AnimationTrack acelerada!\n  Animator: %s\n  AnimationId: %s\n  Duração original: %.3fs",
					targetSpeed, animatorPath, animId, track.Length
				))
			end
		end
	end)
end

local function shouldAccelerateAnimator(animator: Instance): (boolean, string)
	local path = getCleanPath(animator)
	-- Ignora o próprio personagem do jogador andando pelo mapa, a menos que seja uma animação de Star
	if LocalPlayer.Character and animator:IsDescendantOf(LocalPlayer.Character) then
		return false, path
	end
	-- Prioriza tudo dentro de PlayerGui (ViewportFrames de Star) ou objetos de Star/Camera no Workspace
	if animator:IsDescendantOf(PlayerGui) then
		return true, path
	end
	if Workspace.CurrentCamera and animator:IsDescendantOf(Workspace.CurrentCamera) then
		return true, path
	end
	if containsKeyword(path, STAR_KEYWORDS) then
		return true, path
	end
	return false, path
end

local function watchAnimator(animator: Instance)
	if WatchedAnimators[animator] then return end
	if not (animator:IsA("Animator") or animator:IsA("AnimationController") or animator:IsA("Humanoid")) then
		return
	end

	local relevant, path = shouldAccelerateAnimator(animator)
	if not relevant then return end

	WatchedAnimators[animator] = true
	State.DetectedAnimControllers[path] = true

	if DEBUG then
		print(string.format("[DEBUG ANIMAÇÃO] Controlador 3D detectado: %s (%s)", path, animator.ClassName))
	end

	-- Acelera tracks que já estejam tocando
	pcall(function()
		local tracks = (animator :: any):GetPlayingAnimationTracks()
		for _, track in ipairs(tracks) do
			applySpeedToTrack(track, path)
		end
	end)

	-- Escuta novas animações iniciadas
	local conn = (animator :: any).AnimationPlayed:Connect(function(track: AnimationTrack)
		applySpeedToTrack(track, path)
	end)
	table.insert(Connections, conn)
end

-- Atualiza a velocidade das animações em andamento caso o usuário mude o botão (1x, 2x, 5x, 10x)
local function refreshAllPlayingTracks()
	local targetSpeed = getEffectiveSpeed()
	for animator in pairs(WatchedAnimators) do
		if animator and animator.Parent then
			pcall(function()
				for _, track in ipairs((animator :: any):GetPlayingAnimationTracks()) do
					track:AdjustSpeed(targetSpeed)
				end
			end)
		end
	end
end

-- Diagnostica quais scripts e objetos controlam a GUI da Star
local function inspectStarGuiArchitecture()
	local uiScreen = PlayerGui:FindFirstChild("UI")
	local frames = uiScreen and uiScreen:FindFirstChild("Frames")
	local starFrame = frames and frames:FindFirstChild("Star")

	print("\n===== DIAGNÓSTICO DE ARQUITETURA DA STAR =====")
	if not starFrame then
		print("[AVISO] PlayerGui.UI.Frames.Star ainda não encontrado.")
	else
		print("Container localizado: " .. getCleanPath(starFrame))
		local scriptsFound = 0
		local viewportsFound = 0

		for _, desc in ipairs(starFrame:GetDescendants()) do
			if desc:IsA("LocalScript") or desc:IsA("ModuleScript") then
				scriptsFound += 1
				print("  [Script na UI] " .. getCleanPath(desc) .. " (" .. desc.ClassName .. ")")
			elseif desc:IsA("ViewportFrame") or desc:IsA("WorldModel") then
				viewportsFound += 1
				print("  [Viewport/3D na UI] " .. getCleanPath(desc) .. " (" .. desc.ClassName .. ")")
			elseif desc:IsA("Animator") or desc:IsA("AnimationController") or desc:IsA("Humanoid") then
				watchAnimator(desc)
			end
		end

		print(string.format("Resumo em Frames.Star: %d Scripts locais | %d ViewportFrames/WorldModels", scriptsFound, viewportsFound))
	end

	-- Procura também Scripts/Modules em PlayerGui ou ReplicatedStorage com nome de Star/Summon/Roll
	for _, container in ipairs({PlayerGui, ReplicatedStorage}) do
		for _, desc in ipairs(container:GetDescendants()) do
			if (desc:IsA("LocalScript") or desc:IsA("ModuleScript")) and containsKeyword(desc.Name, STAR_KEYWORDS) then
				local p = getCleanPath(desc)
				if not State.DetectedAnimControllers[p] then
					State.DetectedAnimControllers[p] = true
					print("  [Controlador Relacionado] " .. p .. " (" .. desc.ClassName .. ")")
				end
			end
		end
	end
	print("Nota: Tweens criados via TweenService:Create() dentro de LocalScripts são isolados na memória do script.")
	print("==============================================\n")
end

-- ============================================================================
-- DETECTOR OFICIAL: PITY COMO FONTE DE VERDADE
-- ============================================================================
local function onPityRawTextChanged(newRawText: string)
	local newCur, newMax = parsePityNumbers(newRawText)
	if not newCur then return end

	-- Inicialização da primeira leitura (apenas sincroniza o valor atual sem contar abertura)
	if State.LastPityValue == nil then
		State.LastPityValue = newCur
		State.LastPityMax = newMax
		if DEBUG then
			print(string.format("[PITY SYNC] Valor inicial sincronizado: %d/%s", newCur, tostring(newMax or "?")))
		end
		return
	end

	local oldCur = State.LastPityValue
	local oldMax = State.LastPityMax or newMax
	if newCur == oldCur then return end

	local now = os.clock()
	if State.LastPityTimestamp and (now - State.LastPityTimestamp) < PITY_DEDUP_WINDOW then
		State.LastPityValue = newCur
		State.LastPityMax = newMax
		return
	end

	-- Calcula o Delta real de Rolls
	local delta = newCur - oldCur
	if delta <= 0 then
		-- Tratamento para caso o Mythical Pity resete (ex: bateu 7500/7500 ou pegou o Mythical)
		if oldMax and ((oldMax - oldCur) + newCur) > 0 and ((oldMax - oldCur) + newCur) <= 20 then
			delta = (oldMax - oldCur) + newCur
		elseif newCur > 0 and newCur <= 20 then
			delta = newCur
		else
			delta = DEFAULT_BATCH_DELTA
		end
		if DEBUG then
			print(string.format("[PITY RESET DETECTADO] %d -> %d (Assumindo Delta = +%d)", oldCur, newCur, delta))
		end
	end

	local interval: number? = nil
	if State.LastPityTimestamp ~= nil then
		interval = now - State.LastPityTimestamp
	end

	State.LastPityValue = newCur
	State.LastPityMax = newMax
	State.LastPityTimestamp = now

	-- Log detalhado exigido no F9
	if DEBUG then
		print(string.format(
			"Pity: %d -> %d\nDelta: +%d\nIntervalo: %s\nRolls reais: +%d\nModo: %s",
			oldCur,
			newCur,
			delta,
			interval and string.format("%.3fs", interval) or "1ª abertura (baseline timestamp)",
			delta,
			getCurrentModeName()
		))
	end

	-- Se o cronômetro estiver ativo ([START]), grava nas métricas do modo A/B atual
	if State.IsRunning then
		local stats = getCurrentModeStats()
		stats.openings += 1
		stats.realRolls += delta

		if interval then
			stats.lastInterval = interval
			table.insert(stats.intervals, interval)
			if interval < stats.minInterval then
				stats.minInterval = interval
			end
			if interval > stats.maxInterval then
				stats.maxInterval = interval
			end
		end
	end
end

local function connectPitySource()
	-- 1. Tenta localizar exatamente PlayerGui.UI.Frames.Star.Pity.Value
	local target: Instance? = nil
	local ui = PlayerGui:FindFirstChild("UI")
	local frames = ui and ui:FindFirstChild("Frames")
	local star = frames and frames:FindFirstChild("Star")
	local pity = star and star:FindFirstChild("Pity")
	if pity then
		target = pity:FindFirstChild("Value") or (pity:IsA("TextLabel") and pity or nil)
	end

	-- 2. Fallback automático caso a hierarquia demore a carregar
	if not target then
		for _, desc in ipairs(PlayerGui:GetDescendants()) do
			if desc:IsA("TextLabel") and string.find(string.lower(desc.Text), "pity") then
				target = desc
				break
			end
		end
	end

	if not target then
		State.PityResolvedPath = "NÃO ENCONTRADO (Clique em RECALIBRAR com a Star aberta)"
		warn("[STAR PROFILER v3] PlayerGui.UI.Frames.Star.Pity.Value não encontrado no momento.")
		return
	end

	State.PityObject = target
	State.PityResolvedPath = getCleanPath(target)

	if target:IsA("TextLabel") then
		State.LastPityValue, State.LastPityMax = parsePityNumbers(target.Text)
		local conn = target:GetPropertyChangedSignal("Text"):Connect(function()
			onPityRawTextChanged(target.Text)
		end)
		table.insert(Connections, conn)
	elseif target:IsA("ValueBase") then
		local valObj = target :: any
		State.LastPityValue, State.LastPityMax = parsePityNumbers(tostring(valObj.Value))
		local conn = valObj:GetPropertyChangedSignal("Value"):Connect(function()
			onPityRawTextChanged(tostring(valObj.Value))
		end)
		table.insert(Connections, conn)
	end

	print(string.format("[STAR PROFILER v3] Fonte de verdade conectada: %s (Pity atual: %s)", State.PityResolvedPath, tostring(State.LastPityValue or "?")))
end

-- ============================================================================
-- INICIALIZAÇÃO DE MONITORAMENTO
-- ============================================================================
local function clearConnections()
	for _, conn in ipairs(Connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(Connections)
	table.clear(WatchedAnimators)
end

local function scanAndConnectAll()
	clearConnections()
	connectPitySource()
	inspectStarGuiArchitecture()

	-- Monitora Animators existentes e futuros em PlayerGui e Workspace
	for _, inst in ipairs(PlayerGui:GetDescendants()) do
		watchAnimator(inst)
	end
	for _, inst in ipairs(Workspace:GetDescendants()) do
		watchAnimator(inst)
	end

	table.insert(Connections, PlayerGui.DescendantAdded:Connect(function(desc)
		watchAnimator(desc)
		if State.PityObject == nil and desc.Name == "Value" and desc.Parent and desc.Parent.Name == "Pity" then
			connectPitySource()
		end
	end))

	table.insert(Connections, Workspace.DescendantAdded:Connect(function(desc)
		watchAnimator(desc)
	end))
end

-- ============================================================================
-- RELATÓRIO FINAL E COMPARATIVO A/B NO CONSOLE (F9)
-- ============================================================================
local function printABReport()
	print("\n================ STAR SPEED PROFILER v3 (RELATÓRIO A/B) ================")
	print(string.format("Fonte de verdade: %s", State.PityResolvedPath))
	print(string.format("AnimationTracks aceleradas na sessão: %d", State.AcceleratedTracksCount))
	print("------------------------------------------------------------------------")

	for _, modeName in ipairs(MODES_ORDER) do
		local st = ABData[modeName]
		if st and st.openings > 0 then
			local avg = getAverage(st.intervals)
			local minInt = (st.minInterval == math.huge) and 0 or st.minInterval
			local maxInt = st.maxInterval
			local opm = (st.activeTime > 0) and ((st.openings / st.activeTime) * 60) or 0
			local rpm = (st.activeTime > 0) and ((st.realRolls / st.activeTime) * 60) or 0
			local verdict = classifyModeResult(st)

			print(string.format(
				"[%s] Aberturas: %d | Rolls Reais: %d | Tempo: %.2fs\n" ..
				"  Média: %.3fs | Menor: %.3fs (Robusto: %.3fs) | Maior: %.3fs\n" ..
				"  Aberturas/min: %.1f | Rolls/min: %.1f | Diagnóstico: %s",
				modeName, st.openings, st.realRolls, st.activeTime,
				avg, minInt, getRobustMinInterval(st.intervals), maxInt,
				opm, rpm, verdict
			))
		else
			print(string.format("[%s] Sem dados coletados", modeName))
		end
	end

	print("\n----- COMPARAÇÃO DIRETA DE INTERVALO MÉDIO -----")
	local normalAvg = (#ABData["NORMAL"].intervals > 0) and getAverage(ABData["NORMAL"].intervals) or BASELINE_SECONDS
	local bestFastAvg = math.huge

	for _, modeName in ipairs(MODES_ORDER) do
		local st = ABData[modeName]
		if #st.intervals > 0 then
			local avg = getAverage(st.intervals)
			print(string.format("%-7s %.3fs (n=%d intervalos)", modeName .. ":", avg, #st.intervals))
			if modeName ~= "NORMAL" and avg < bestFastAvg then
				bestFastAvg = avg
			end
		else
			print(string.format("%-7s ---", modeName .. ":"))
		end
	end

	print("\nResultado Conclusivo:")
	if bestFastAvg == math.huge then
		print("  Teste pelo menos um modo acelerado (2x, 5x ou 10x) para comparar com o NORMAL.")
	elseif (normalAvg - bestFastAvg) >= 0.08 and bestFastAvg < 0.95 then
		print("  A animação/delay local INFLUENCIA a frequência real das aberturas.")
	else
		print("  Nenhuma alteração real significativa (~1.00s mantido). Provável cooldown independente da animação (ou controlado por Tween interno/Servidor).")
	end
	print("========================================================================\n")
end

-- ============================================================================
-- INTERFACE GRÁFICA (PAINEL V3 COM SELETOR DE MULTIPLICADOR A/B)
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
	mainFrame.Size = UDim2.new(0, 330, 0, 415)
	mainFrame.Position = UDim2.new(0.02, 0, 0.25, 0)
	mainFrame.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	mainFrame.BorderSizePixel = 0
	mainFrame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = mainFrame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 80, 105)
	stroke.Thickness = 1.5
	stroke.Parent = mainFrame

	local titleBar = Instance.new("Frame")
	titleBar.Size = UDim2.new(1, 0, 0, 30)
	titleBar.BackgroundColor3 = Color3.fromRGB(28, 32, 42)
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
	titleLabel.Text = "STAR SPEED PROFILER v3 (A/B)"
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
	statsLabel.Size = UDim2.new(1, -24, 0, 255)
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

	-- Seletores de Multiplicador A/B (1x, 2x, 5x, 10x)
	local multButtons: {[number]: TextButton} = {}
	local multOptions = {1, 2, 5, 10}
	for i, mult in ipairs(multOptions) do
		local xOffset = 10 + (i - 1) * 79
		local label = (mult == 1) and "1x (NORM)" or (tostring(mult) .. "x")
		local btn = makeButton(label, UDim2.new(0, xOffset, 0, 298), UDim2.new(0, 73, 0, 28), Color3.fromRGB(50, 58, 75))
		multButtons[mult] = btn

		btn.MouseButton1Click:Connect(function()
			SPEED_MULTIPLIER = mult
			SPEED_TEST = (mult > 1)
			-- Reseta o último timestamp ao trocar de modo para não misturar intervalo entre dois modos
			State.LastPityTimestamp = nil
			refreshAllPlayingTracks()
			print(string.format("[STAR PROFILER v3] Modo alterado para: %s (SPEED_TEST = %s)", getCurrentModeName(), tostring(SPEED_TEST)))
		end)
	end

	local startBtn = makeButton("[START]", UDim2.new(0, 10, 0, 334), UDim2.new(0, 100, 0, 32), Color3.fromRGB(40, 140, 75))
	local stopBtn  = makeButton("[STOP]",  UDim2.new(0, 115, 0, 334), UDim2.new(0, 100, 0, 32), Color3.fromRGB(175, 55, 55))
	local resetBtn = makeButton("[RESET]", UDim2.new(0, 220, 0, 334), UDim2.new(0, 100, 0, 32), Color3.fromRGB(70, 80, 100))

	local speedToggleBtn = makeButton("SPEED TEST: ON", UDim2.new(0, 10, 0, 374), UDim2.new(0, 150, 0, 30), Color3.fromRGB(115, 75, 165))
	local recalibBtn     = makeButton("RECALIBRAR / F9", UDim2.new(0, 170, 0, 374), UDim2.new(0, 150, 0, 30), Color3.fromRGB(55, 95, 160))

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
		State.LastTick = os.clock()
		State.LastPityTimestamp = nil
		refreshAllPlayingTracks()
		print(string.format("[STAR PROFILER v3] Coleta INICIADA no modo %s.", getCurrentModeName()))
	end)

	stopBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		printABReport()
	end)

	resetBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		State.LastPityTimestamp = nil
		local modeName = getCurrentModeName()
		ABData[modeName] = createEmptyModeStats(modeName, SPEED_TEST and SPEED_MULTIPLIER or 1)
		print(string.format("[STAR PROFILER v3] Dados do modo [%s] foram resetados.", modeName))
	end)

	speedToggleBtn.MouseButton1Click:Connect(function()
		SPEED_TEST = not SPEED_TEST
		State.LastPityTimestamp = nil
		refreshAllPlayingTracks()
	end)

	recalibBtn.MouseButton1Click:Connect(function()
		scanAndConnectAll()
		printABReport()
	end)

	local renderConn
	renderConn = RunService.RenderStepped:Connect(function()
		local now = os.clock()
		local dt = now - State.LastTick
		State.LastTick = now

		local st = getCurrentModeStats()
		if State.IsRunning then
			st.activeTime += dt
		end

		-- Destaque visual do botão do multiplicador ativo
		for mult, btn in pairs(multButtons) do
			local isActive = (SPEED_TEST and SPEED_MULTIPLIER == mult) or (not SPEED_TEST and mult == 1)
			btn.BackgroundColor3 = isActive and Color3.fromRGB(45, 130, 210) or Color3.fromRGB(50, 58, 75)
		end
		speedToggleBtn.Text = SPEED_TEST and "SPEED TEST: ON" or "SPEED TEST: OFF"
		speedToggleBtn.BackgroundColor3 = SPEED_TEST and Color3.fromRGB(115, 75, 165) or Color3.fromRGB(65, 65, 75)

		local avgInt = getAverage(st.intervals)
		local minInt = (st.minInterval == math.huge) and 0 or st.minInterval
		local maxInt = st.maxInterval
		local opm = (st.activeTime > 0) and ((st.openings / st.activeTime) * 60) or 0
		local rpm = (st.activeTime > 0) and ((st.realRolls / st.activeTime) * 60) or 0
		local improvement = getImprovementPercent(st)
		local verdict = classifyModeResult(st)

		-- Linha compacta de comparação A/B em tempo real
		local normAvg = (#ABData["NORMAL"].intervals > 0) and string.format("%.3fs", getAverage(ABData["NORMAL"].intervals)) or "---"
		local x2Avg   = (#ABData["2x"].intervals > 0)     and string.format("%.3fs", getAverage(ABData["2x"].intervals))     or "---"
		local x5Avg   = (#ABData["5x"].intervals > 0)     and string.format("%.3fs", getAverage(ABData["5x"].intervals))     or "---"
		local x10Avg  = (#ABData["10x"].intervals > 0)    and string.format("%.3fs", getAverage(ABData["10x"].intervals))    or "---"

		statsLabel.Text = string.format(
			"STATUS: %s | MODO: <b>%s</b>\n" ..
			"SPEED TEST: %s | MULTIPLIER: %dx\n\n" ..
			"ABERTURAS: %d  (%.1f/min)\n" ..
			"ROLLS REAIS: %d  (%.1f/min)\n\n" ..
			"INTERVALO ATUAL: %.3fs\n" ..
			"INTERVALO MÉDIO: %.3fs\n" ..
			"MENOR / MAIOR: %.3fs / %.3fs\n\n" ..
			"BASELINE: %.3fs | MELHORA: %+.1f%%\n" ..
			"RESULTADO:\n<b>%s</b>\n\n" ..
			"A/B: N:%s | 2x:%s | 5x:%s | 10x:%s",
			State.IsRunning and '<font color="#55ff7f">RODANDO</font>' or '<font color="#ffaa55">PARADO</font>',
			st.name,
			SPEED_TEST and "ON" or "OFF",
			getEffectiveSpeed(),
			st.openings, opm,
			st.realRolls, rpm,
			st.lastInterval,
			avgInt,
			minInt, maxInt,
			BASELINE_SECONDS, improvement,
			verdict,
			normAvg, x2Avg, x5Avg, x10Avg
		)
	end)

	closeBtn.MouseButton1Click:Connect(function()
		State.IsRunning = false
		SPEED_TEST = false
		refreshAllPlayingTracks()
		if renderConn then renderConn:Disconnect() end
		if dragConn then dragConn:Disconnect() end
		clearConnections()
		screenGui:Destroy()
		print("[STAR PROFILER v3] Encerrado e conexões limpas.")
	end)
end

-- ============================================================================
-- INICIALIZAÇÃO
-- ============================================================================
createUI()
scanAndConnectAll()
