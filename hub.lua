local R = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()
local W = R:CreateWindow({Name="TutuHub",LoadingTitle="Carregando...",ConfigurationSaving={Enabled=false}})
local T = W:CreateTab("Auto Roll", 4483362458)
local sW, bA, RS = "Dungeons Town", 15, game:GetService("ReplicatedStorage")
getgenv().aR = false

T:CreateDropdown({Name="Mundo",Options={"Namex Planet","Colosseum Kingdom","Demon Forest","Dungeons Town", "Reaper Society"},CurrentOption={"Dungeons Town"},Callback=function(O) sW=O[1] end})
T:CreateSlider({Name="Poder da Rajada",Range={1,100},Increment=1,CurrentValue=15,Callback=function(V) bA=V end})
T:CreateToggle({Name="Ligar Auto Roll",CurrentValue=false,Callback=function(V)
    getgenv().aR = V
    if V then
        task.spawn(function()
            while getgenv().aR do
                pcall(function()
                    local t = workspace:FindFirstChild("Summoners") and workspace.Summoners:FindFirstChild(sW)
                    local r, h = RS.Remotes.Summoners.RemoteEvent, RS.Remotes.Summoners.Hatch
                    for i = 1, bA do
                        task.spawn(function() r:FireServer(t or sW, "Multi") end)
                        if i % 5 == 0 then task.wait() end
                    end
                    h:FireServer(false)
                end)
                task.wait(0.5)
            end
        end)
    end
end})
