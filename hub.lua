--[[
	Anime Breakers Hub  |  Auto-Trial & Auto-Raid  v4
	Script monolitico — colar e executar no executor
	
	BridgeNet2 — zero disparos de Remote; tudo via UI clicks
	Combate passivo por area (posicionar sobre o mob)
	Mobs: workspace._ENEMIES.Server.Gamemode (subpastas)
	Trial UI: PlayerGui.Gamemode.Enabled
	Popup: PlayerGui.CenterGUI -> Gamemode Popup
	Raid Hub: PlayerGui.CenterGUI (botoes por texto)
	UI: Rayfield Library via loadstring
	
	Compativel com Lua 5.1 (sem backticks, sem continue, sem +=)
]]

-------------------------------------------------
-- 0.  ANTI-DUPLA EXECUCAO
-------------------------------------------------
if getgenv().__AB_HUB_V4 then
	warn("[AB Hub] Ja esta rodando. Ignorando.")
	return
end
getgenv().__AB_HUB_V4 = true

-------------------------------------------------
-- 1.  SERVICOS
-------------------------------------------------
local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LP        = Players.LocalPlayer

-------------------------------------------------
-- 2.  ESTADO GLOBAL
-------------------------------------------------
getgenv().AutoTrial = getgenv().AutoTrial or false
getgenv().AutoRaid  = getgenv().AutoRaid  or false
getgenv().RaidConfig = getgenv().RaidConfig or {
	Map        = "DBZ",
	Difficulty = "Normal",
	MaxWave    = 50,
}

local TrialStatus = "Desligado"
local RaidStatus  = "Desligado"

local Character = nil
local Humanoid  = nil
local RootPart  = nil

-------------------------------------------------
-- 3.  HELPERS — RESOLUCAO DE INSTANCIAS
-------------------------------------------------

local function resolve(root, path)
	local cur = root
	for seg in string.gmatch(path, "[^%.]+") do
		cur = cur:FindFirstChild(seg)
		if not cur then return nil end
	end
	return cur
end

local function getEnemyFolder()
	return resolve(Workspace, "_ENEMIES.Server.Gamemode")
end

local function isAlive()
	return Character ~= nil
		and Character.Parent ~= nil
		and Humanoid  ~= nil
		and Humanoid.Health > 0
		and RootPart  ~= nil
		and RootPart.Parent ~= nil
end

-------------------------------------------------
-- 4.  MOTOR DE COMBATE
--     GetDescendants + HumanoidRootPart + hash Parts
-------------------------------------------------

local function findValidTarget()
	local folder = getEnemyFolder()
	if not folder then return nil, nil end

	for _, desc in ipairs(folder:GetDescendants()) do
		-- Caso 1: Model com Humanoid vivo
		if desc:IsA("Model") then
			local hum = desc:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				local hrp = desc:FindFirstChild("HumanoidRootPart")
				if hrp and hrp:IsA("BasePart") then
					return desc, function()
						if hrp and hrp.Parent then return hrp.CFrame end
						return nil
					end
				end
				-- Fallback: PrimaryPart ou primeiro BasePart
				local fallback = desc.PrimaryPart
					or desc:FindFirstChildWhichIsA("BasePart", true)
				if fallback then
					return desc, function()
						if fallback and fallback.Parent then return fallback.CFrame end
						return nil
					end
				end
			end
		end

		-- Caso 2: BasePart solta (nome em hash)
		if desc:IsA("BasePart") and not desc:IsA("Terrain") then
			local parentModel = desc:FindFirstAncestorWhichIsA("Model")
			local skip = false
			if parentModel then
				local parentHum = parentModel:FindFirstChildOfClass("Humanoid")
				if parentHum then
					skip = true
				end
			end
			if not skip then
				return desc, function()
					if desc and desc.Parent then return desc.CFrame end
					return nil
				end
			end
		end
	end

	return nil, nil
end

local function countValidTargets()
	local folder = getEnemyFolder()
	if not folder then return 0 end

	local seen = {}
	local count = 0

	for _, desc in ipairs(folder:GetDescendants()) do
		if desc:IsA("Model") then
			local hum = desc:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 and not seen[desc] then
				seen[desc] = true
				count = count + 1
			end
		elseif desc:IsA("BasePart") and not desc:IsA("Terrain") then
			local parentModel = desc:FindFirstAncestorWhichIsA("Model")
			local skip = false
			if parentModel then
				local parentHum = parentModel:FindFirstChildOfClass("Humanoid")
				if parentHum then skip = true end
			end
			if not skip and not seen[desc] then
				seen[desc] = true
				count = count + 1
			end
		end
	end

	return count
end

-------------------------------------------------
-- 5.  LEITURA DE STAGE / LEVEL DA UI
-------------------------------------------------

local function readStageText()
	local playerGui = LP:FindFirstChild("PlayerGui")
	if not playerGui then return nil end

	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and gui.Enabled then
			for _, desc in ipairs(gui:GetDescendants()) do
				if (desc:IsA("TextLabel") or desc:IsA("TextBox"))
					and desc.Visible then
					local text = desc.Text
					local lower = string.lower(text)
					if string.find(lower, "stage")
						or string.find(lower, "level")
						or string.find(lower, "wave")
						or string.find(lower, "round") then
						local clean = string.gsub(text, "%s+", " ")
						clean = string.gsub(clean, "^%s+", "")
						clean = string.gsub(clean, "%s+$", "")
						if #clean > 0 then
							return clean
						end
					end
				end
			end
		end
	end

	return nil
end

local function parseWaveNumber()
	local text = readStageText()
	if not text then return 0 end
	local num = string.match(text, "(%d+)")
	return tonumber(num) or 0
end

-------------------------------------------------
-- 6.  DETECCAO DE ESTADO DO GAMEMODE
-------------------------------------------------

local function isInsideGamemode()
	local gui = resolve(LP, "PlayerGui.Gamemode")
	if not gui then return false end
	if gui:IsA("ScreenGui") then return gui.Enabled end
	if gui:IsA("GuiObject") then return gui.Visible end
	return false
end

-------------------------------------------------
-- 7.  CLIQUE DE BOTOES (UI BYPASS)
-------------------------------------------------

local function fireClick(button)
	if not button then return end
	if firesignal then
		local ok = pcall(firesignal, button.MouseButton1Click)
		if ok then return end
		pcall(firesignal, button.Activated)
		return
	end
	pcall(function() button.MouseButton1Click:Fire() end)
end

--[[
	ClickButtonByText(startNode, targetText)
	Procura recursivamente um botao cujo texto (ou TextLabel filho)
	corresponda a targetText (case-insensitive, match parcial).
	Retorna true se encontrou e clicou.
]]
local function ClickButtonByText(startNode, targetText)
	if not startNode then return false end
	local target = string.lower(targetText)

	for _, desc in ipairs(startNode:GetDescendants()) do
		if (desc:IsA("TextButton") or desc:IsA("ImageButton")) and desc.Visible then
			-- Verificar texto direto (TextButton)
			if desc:IsA("TextButton") then
				if string.find(string.lower(desc.Text), target) then
					fireClick(desc)
					return true
				end
			end

			-- Verificar TextLabel filho (ImageButton com texto)
			for _, child in ipairs(desc:GetChildren()) do
				if child:IsA("TextLabel") then
					if string.find(string.lower(child.Text), target) then
						fireClick(desc)
						return true
					end
				end
			end

			-- Verificar o Name do botao
			if string.find(string.lower(desc.Name), target) then
				fireClick(desc)
				return true
			end
		end
	end

	return false
end

local function tryClickTrialConfirm()
	local centerGUI = resolve(LP, "PlayerGui.CenterGUI")
	if not centerGUI then return false end

	for _, child in ipairs(centerGUI:GetDescendants()) do
		if (child:IsA("Frame") or child:IsA("CanvasGroup")) then
			local nameL = string.lower(child.Name)
			if string.find(nameL, "gamemode") and child.Visible then
				for _, btn in ipairs(child:GetDescendants()) do
					if btn:IsA("GuiButton") and btn.Visible then
						local btnName = string.lower(btn.Name)
						local btnText = ""
						if btn:IsA("TextButton") then
							btnText = string.lower(btn.Text)
						end
						if string.find(btnName, "confirm")
							or string.find(btnName, "advance")
							or string.find(btnName, "continue")
							or string.find(btnName, "start")
							or string.find(btnText, "confirm")
							or string.find(btnText, "advance")
							or string.find(btnText, "continue")
							or string.find(btnText, "start") then
							fireClick(btn)
							return true
						end
					end
				end
				-- Fallback: qualquer botao visivel
				for _, btn in ipairs(child:GetDescendants()) do
					if btn:IsA("GuiButton") and btn.Visible then
						fireClick(btn)
						return true
					end
				end
			end
		end
	end

	return false
end

local function tryClickLeave()
	local gamemodeGui = resolve(LP, "PlayerGui.Gamemode")
	if not gamemodeGui then return false end

	local content = gamemodeGui:FindFirstChild("Content")
	if content then
		if ClickButtonByText(content, "leave") then return true end
		if ClickButtonByText(content, "exit") then return true end
		if ClickButtonByText(content, "quit") then return true end
	end

	return ClickButtonByText(gamemodeGui, "leave")
		or ClickButtonByText(gamemodeGui, "exit")
end

-------------------------------------------------
-- 8.  MOTOR DE CLIQUES UI PARA INICIAR RAID
-------------------------------------------------

local function tryStartRaid()
	local centerGUI = resolve(LP, "PlayerGui.CenterGUI")
	if not centerGUI then
		return false, "CenterGUI nao encontrada"
	end

	local config = getgenv().RaidConfig

	-- Localizar o Raid Hub
	local raidHub = nil
	for _, child in ipairs(centerGUI:GetDescendants()) do
		if (child:IsA("Frame") or child:IsA("CanvasGroup")
			or child:IsA("ScrollingFrame")) then
			local nameL = string.lower(child.Name)
			if string.find(nameL, "raid") and child.Visible then
				raidHub = child
				break
			end
		end
	end

	if not raidHub then
		local opened = ClickButtonByText(centerGUI, "raid")
		if opened then
			task.wait(1)
			for _, child in ipairs(centerGUI:GetDescendants()) do
				if (child:IsA("Frame") or child:IsA("CanvasGroup")
					or child:IsA("ScrollingFrame"))
					and child.Visible then
					local nameL = string.lower(child.Name)
					if string.find(nameL, "raid") then
						raidHub = child
						break
					end
				end
			end
		end
		if not raidHub then
			return false, "Raid Hub nao encontrado"
		end
	end

	-- Passo 1: Selecionar Mapa
	local mapClicked = ClickButtonByText(raidHub, string.lower(config.Map))
	if not mapClicked then
		return false, "Mapa " .. config.Map .. " nao encontrado"
	end
	task.wait(0.5)

	-- Passo 2: Selecionar Dificuldade
	local diffClicked = ClickButtonByText(raidHub, string.lower(config.Difficulty))
	if not diffClicked then
		diffClicked = ClickButtonByText(centerGUI, string.lower(config.Difficulty))
	end
	task.wait(0.5)

	-- Passo 3: Create
	local createClicked = ClickButtonByText(raidHub, "create")
	if not createClicked then
		createClicked = ClickButtonByText(centerGUI, "create")
	end
	if not createClicked then
		return false, "Botao Create nao encontrado"
	end
	task.wait(1.5)

	-- Passo 4: Start
	local freshCenterGUI = resolve(LP, "PlayerGui.CenterGUI")
	if freshCenterGUI then
		local startClicked = ClickButtonByText(freshCenterGUI, "start")
		if startClicked then
			return true, "Raid iniciada!"
		end
	end

	return false, "Botao Start nao encontrado"
end

-------------------------------------------------
-- 9.  RESPAWN
-------------------------------------------------

local function onCharacterAdded(char)
	Character = char
	Humanoid  = char:WaitForChild("Humanoid", 10)
	RootPart  = char:WaitForChild("HumanoidRootPart", 10)
	if not game:IsLoaded() then game.Loaded:Wait() end
	task.wait(0.5)
end

if LP.Character then onCharacterAdded(LP.Character) end
LP.CharacterAdded:Connect(onCharacterAdded)

-------------------------------------------------
-- 10. LOOP DE COMBATE (compartilhado Trial/Raid)
-------------------------------------------------

local function combatTick()
	if not isAlive() then
		return "Aguardando respawn..."
	end

	local target, getCF = findValidTarget()

	if target and getCF then
		local cf = getCF()
		if cf then
			RootPart.CFrame = cf
		end

		-- Gruda no alvo ate ele morrer ou sair do loop
		while (getgenv().AutoTrial or getgenv().AutoRaid)
			and isAlive()
			and target
			and target.Parent ~= nil do

			local updatedCF = getCF()
			if not updatedCF then break end

			-- Valida se o mob ainda esta vivo (se for Model)
			if target:IsA("Model") then
				local hum = target:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health <= 0 then break end
			end

			RootPart.CFrame = updatedCF
			task.wait(0.1)
		end

		-- Le stage para status
		local stageText = readStageText()
		if stageText then
			return "Em Combate [" .. stageText .. "]"
		end
		return "Em Combate"
	end

	-- Sem alvos
	local stageText = readStageText()
	if stageText then
		return "Proxima Onda... [" .. stageText .. "]"
	end
	return "Proxima Onda..."
end

-------------------------------------------------
-- 11. THREAD — AUTO-TRIAL
-------------------------------------------------

local function startTrialLoop()
	task.spawn(function()
		while task.wait(0.15) do
			if not getgenv().AutoTrial then
				TrialStatus = "Desligado"
				task.wait(0.5)
			elseif not isAlive() then
				TrialStatus = "Aguardando respawn..."
				task.wait(1)
			elseif not isInsideGamemode() then
				TrialStatus = "Aguardando no Lobby / Fora da Trial"
				task.wait(0.5)
			else
				-- Dentro da Trial — combate
				TrialStatus = combatTick()
				task.wait(0.15)
			end
		end
	end)
end

-------------------------------------------------
-- 12. THREAD — AUTO-CONFIRM POPUP
-------------------------------------------------

local function startPopupLoop()
	task.spawn(function()
		while task.wait(0.5) do
			if getgenv().AutoTrial or getgenv().AutoRaid then
				local clicked = tryClickTrialConfirm()
				if clicked then
					task.wait(1)
				end
			end
		end
	end)
end

-------------------------------------------------
-- 13. THREAD — AUTO-RAID
-------------------------------------------------

local function startRaidLoop()
	task.spawn(function()
		while task.wait(0.2) do
			if not getgenv().AutoRaid then
				RaidStatus = "Desligado"
				task.wait(0.5)
			elseif not isAlive() then
				RaidStatus = "Aguardando respawn..."
				task.wait(1)
			elseif not isInsideGamemode() then
				-- Fora da Raid — tentar iniciar
				RaidStatus = "Fora da Raid — tentando iniciar..."

				local ok, msg = tryStartRaid()
				if ok then
					RaidStatus = "Raid iniciada! Carregando..."
					task.wait(3)
				else
					RaidStatus = msg
					task.wait(2)
				end
			else
				-- Dentro da Raid — verificar wave maxima
				local currentWave = parseWaveNumber()
				local maxWave     = getgenv().RaidConfig.MaxWave or 999

				if currentWave > 0 and currentWave >= maxWave then
					RaidStatus = "Wave " .. currentWave .. "/" .. maxWave .. " — Saindo..."
					local left = tryClickLeave()
					if left then
						task.wait(3)
					else
						RaidStatus = "Botao Leave nao encontrado..."
						task.wait(1)
					end
				else
					-- Combate
					local status = combatTick()
					if currentWave > 0 then
						RaidStatus = "Wave " .. currentWave .. "/" .. maxWave .. " | " .. status
					else
						RaidStatus = status
					end
					task.wait(0.15)
				end
			end
		end
	end)
end

-------------------------------------------------
-- 14. UI HUB — RAYFIELD
-------------------------------------------------

local function buildUI()
	local ok, Rayfield = pcall(function()
		return loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
	end)

	if not ok or not Rayfield then
		warn("[AB Hub] Falha ao carregar Rayfield: " .. tostring(Rayfield))
		return
	end

	-- JANELA
	local Window = Rayfield:CreateWindow({
		Name                   = "Anime Breakers Hub",
		Icon                   = "swords",
		LoadingTitle           = "Anime Breakers Hub",
		LoadingSubtitle        = "por antigrau - v4",
		Theme                  = "Default",
		DisableRayfieldPrompts = true,
		DisableBuildWarnings   = true,
		ConfigurationSaving    = { Enabled = false },
		KeySystem              = false,
	})

	-- ABA 1: AUTO-TRIAL
	local TrialTab     = Window:CreateTab("Auto-Trial", "zap")
	local TrialSection = TrialTab:CreateSection("Trial")

	TrialTab:CreateToggle({
		Name          = "Auto-Trial",
		CurrentValue  = getgenv().AutoTrial,
		Flag          = "AutoTrialToggle",
		SectionParent = TrialSection,
		Callback      = function(v)
			getgenv().AutoTrial = v
			if v then
				TrialStatus = "Iniciando..."
			else
				TrialStatus = "Desligado"
			end
		end,
	})

	local TrialStatusLabel = TrialTab:CreateLabel(
		"Status: Desligado", TrialSection
	)

	local TrialInfo = TrialTab:CreateSection("Info")
	TrialTab:CreateParagraph({
		Title   = "Como funciona",
		Content = "Ative o toggle e entre numa Trial.\n"
			.. "O script teleporta sobre os mobs usando GetDescendants.\n"
			.. "Popups de confirmacao sao clicados automaticamente.\n"
			.. "O status mostra o Stage/Level lido da interface.",
		SectionParent = TrialInfo,
	})

	-- ABA 2: AUTO-RAID
	local RaidTab     = Window:CreateTab("Auto-Raid", "shield")
	local RaidSection = RaidTab:CreateSection("Configuracao")

	RaidTab:CreateToggle({
		Name          = "Auto-Raid",
		CurrentValue  = getgenv().AutoRaid,
		Flag          = "AutoRaidToggle",
		SectionParent = RaidSection,
		Callback      = function(v)
			getgenv().AutoRaid = v
			if v then
				RaidStatus = "Iniciando..."
			else
				RaidStatus = "Desligado"
			end
		end,
	})

	RaidTab:CreateDropdown({
		Name          = "Mapa",
		Options       = {"DBZ", "AOT", "Naruto", "Nanatsu", "SoloLeveling"},
		CurrentOption = { getgenv().RaidConfig.Map },
		Flag          = "RaidMapDrop",
		SectionParent = RaidSection,
		Callback      = function(opt)
			getgenv().RaidConfig.Map = opt[1] or "DBZ"
		end,
	})

	RaidTab:CreateDropdown({
		Name          = "Dificuldade",
		Options       = {"Easy", "Normal", "Hard", "Extreme", "Nightmare"},
		CurrentOption = { getgenv().RaidConfig.Difficulty },
		Flag          = "RaidDiffDrop",
		SectionParent = RaidSection,
		Callback      = function(opt)
			getgenv().RaidConfig.Difficulty = opt[1] or "Normal"
		end,
	})

	RaidTab:CreateSlider({
		Name          = "Wave Maxima",
		Range         = {1, 100},
		Increment     = 1,
		CurrentValue  = getgenv().RaidConfig.MaxWave,
		Suffix        = " waves",
		Flag          = "RaidMaxWave",
		SectionParent = RaidSection,
		Callback      = function(v)
			getgenv().RaidConfig.MaxWave = v
		end,
	})

	local RaidStatusLabel = RaidTab:CreateLabel(
		"Status: Desligado", RaidSection
	)

	local RaidInfo = RaidTab:CreateSection("Info")
	RaidTab:CreateParagraph({
		Title   = "Como funciona",
		Content = "O script abre o Raid Hub via UI, seleciona mapa\n"
			.. "e dificuldade, clica Create -> Start.\n"
			.. "Dentro da Raid, teleporta sobre os mobs.\n"
			.. "Ao atingir a wave maxima, clica Leave.\n"
			.. "Tudo via simulacao de cliques (BridgeNet2 safe).",
		SectionParent = RaidInfo,
	})

	-- LOOP DE ATUALIZACAO DOS LABELS
	task.spawn(function()
		local lastT, lastR = "", ""
		while task.wait(0.4) do
			if TrialStatus ~= lastT then
				lastT = TrialStatus
				pcall(function()
					TrialStatusLabel:Set("Status: " .. TrialStatus)
				end)
			end
			if RaidStatus ~= lastR then
				lastR = RaidStatus
				pcall(function()
					RaidStatusLabel:Set("Status: " .. RaidStatus)
				end)
			end
		end
	end)
end

-------------------------------------------------
-- 15. INICIALIZACAO
-------------------------------------------------

if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(2)

if not Character then
	LP.CharacterAdded:Wait()
	task.wait(1)
end

startTrialLoop()
startRaidLoop()
startPopupLoop()
buildUI()

print("=======================================")
print("  Anime Breakers Hub  v4")
print("  Auto-Trial + Auto-Raid")
print("  Carregado com sucesso!")
print("=======================================")
