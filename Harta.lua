-- PATCH Harta.lua v2: chest fallback global + zone-touch idle
-- Cara pasang: paste SELURUH blok ini di BARIS PALING AKHIR file Harta.lua,
-- Commit, lalu re-execute dari raw URL. Tidak perlu edit kode lama.

_G.HKChestReach = _G.HKChestReach or 3000 -- jarak maksimum kejar chest (studs)

-- 1) Chest fallback GLOBAL: kalau gate loop tidak dapat chest di room sendiri,
--    loop ini kejar chest aktif TERDEKAT di seluruh map (bukan diam).
task.spawn(function()
    while true do
        if _G.HK and _G.HK.autoFarm and _G.HK.chest and _G.HKT == nil then
            pcall(function()
                local P = game.Players.LocalPlayer
                local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local best, bpr, bd = nil, nil, 1e9
                    for _, d in ipairs(workspace:GetDescendants()) do
                        if d:IsA("ProximityPrompt") and d.Enabled and d.Name == "ChestPrompt"
                            and d.HoldDuration == 0 then
                            local m = d.Parent
                            while m and not m:IsA("Model") do m = m.Parent end
                            if m and (string.find(m.Name, "DungeonChest") or string.find(m.Name, "BossLoot")) then
                                local part = d.Parent
                                if part and part:IsA("Attachment") then part = part.Parent end
                                local tp = nil
                                if part and part:IsA("BasePart") then
                                    tp = part.Position
                                else
                                    local ok, cf = pcall(function() return m:GetPivot() end)
                                    if ok then tp = cf.Position end
                                end
                                if tp then
                                    local dist = (tp - hrp.Position).Magnitude
                                    if dist < bd and dist <= (_G.HKChestReach or 3000) then
                                        best, bpr, bd = tp, d, dist
                                    end
                                end
                            end
                        end
                    end
                    if best and bpr and bd > 60 then -- yang dekat biar gate loop yang urus
                        hrp.CFrame = CFrame.new(best + Vector3.new(0, 3, 2))
                        hrp.Velocity = Vector3.new()
                        task.wait(0.5)
                        for _ = 1, 5 do
                            if not bpr.Enabled or _G.HKT ~= nil then break end
                            pcall(function() fireproximityprompt(bpr) end)
                            task.wait(0.7)
                        end
                    end
                end
            end)
        end
        task.wait(3)
    end
end)

-- 2) Zone-touch idle: mob 0 + tidak ada chest + slot belum complete ->
--    sentuh Zone tiap room berurutan (teleport center tidak cukup,
--    harus injak Zone volume). Terbukti mancing wave (Room_8 test).
task.spawn(function()
    local idx = 1
    local sessAt, sessMob = 0, nil
    while true do
        if _G.HK and _G.HK.autoFarm and _G.HKT == nil then
            pcall(function()
                local now = os.clock()
                if now - sessAt > 10 then
                    sessAt = now
                    sessMob = nil
                    local rf = game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
                        .knit.Services.DungeonRunService.RF.GetSessionInfo
                    local ok, s = pcall(function() return rf:InvokeServer() end)
                    if ok and type(s) == "table" and tonumber(s.MobsRemaining) then
                        sessMob = tonumber(s.MobsRemaining)
                    end
                end
                if sessMob == 0 then
                    local P = game.Players.LocalPlayer
                    local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        local gen = nil
                        for _, c in ipairs(workspace:GetChildren()) do
                            if string.find(c.Name, "Generated_") then gen = c break end
                        end
                        if gen then
                            local zones = {}
                            for i = 1, 30 do
                                local r = gen:FindFirstChild("Room_" .. i)
                                local z = r and r:FindFirstChild("Zone")
                                if z then
                                    local ok, cf = pcall(function() return z:GetPivot() end)
                                    if ok then table.insert(zones, cf.Position) end
                                end
                            end
                            if #zones > 0 then
                                if idx > #zones then idx = 1 end
                                local zp = zones[idx]
                                idx = idx + 1
                                hrp.CFrame = CFrame.new(zp + Vector3.new(0, 3, 0))
                                hrp.Velocity = Vector3.new()
                                task.wait(1.2)
                                hrp.CFrame = CFrame.new(zp + Vector3.new(8, 3, 0))
                                hrp.Velocity = Vector3.new()
                                task.wait(1.2)
                            end
                        end
                    end
                end
            end)
        end
        task.wait(2)
    end
end)

print("[HK] patch v2 aktif: chest-global + zone-touch")
