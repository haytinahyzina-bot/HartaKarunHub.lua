-- PATCH Harta.lua: altar-first beneran + BlessPick 1/2/3
-- Cara pasang: paste SELURUH blok ini di BARIS PALING AKHIR file Harta.lua,
-- lalu Commit + pastikan file di GitHub ter-update. Tidak perlu edit kode lama.

_G.HKBlessPick = _G.HKBlessPick or 1   -- 1=kiri, 2=tengah, 3=kanan
_G.HKAltarFirst = (_G.HKAltarFirst == nil) and true or _G.HKAltarFirst

-- 1) Auto-pilih blessing sesuai nomor (altar maupun mid-run)
task.spawn(function()
    local ok, svc = pcall(function()
        return game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
            .knit.Services.DungeonBuffService
    end)
    if not ok or not svc then return end
    pcall(function()
        svc.RE.BuffSelection.OnClientEvent:Connect(function(...)
            _G.HKLastBless = { ... }
            task.wait(0.4)
            local pick = tonumber(_G.HKBlessPick) or 1
            if pick < 1 or pick > 3 then pick = 1 end
            pcall(function() svc.RF.SelectBuff:InvokeServer(pick) end)
        end)
    end)
end)

-- 2) Tiap AUTO FARM baru dinyalakan: reset + langsung ke altar dulu
task.spawn(function()
    local prev = false
    while true do
        local on = _G.HK and _G.HK.autoFarm
        if on and not prev then
            _G.HKAltarDone = {}   -- reset: altar boleh dikunjungi lagi run ini
            _G.HKChestSkip = {}
            _G.HKZone.lastRoom = nil
            if _G.HKAltarFirst then
                _G.HK.goAltar = true -- blok startup bawaan: altar -> gate 1
            end
        end
        prev = on
        task.wait(0.5)
    end
end)

-- 3) Prioritas altar mid-run: kalau tidak ada target dan ada altar
--    belum dikunjungi, datangi DULU sebelum chest/patrol
task.spawn(function()
    while true do
        if _G.HK and _G.HK.autoFarm and _G.HKT == nil and _G.HKAltarFirst then
            pcall(function()
                local P = game.Players.LocalPlayer
                local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local best, bpr, bd = nil, nil, 1e9
                    for _, d in ipairs(workspace:GetDescendants()) do
                        if d:IsA("ProximityPrompt") and d.Enabled
                            and string.find(string.lower(d.ActionText), "bless") then
                            local m = d.Parent
                            while m and not m:IsA("Model") do m = m.Parent end
                            if m and not (_G.HKAltarDone or {})[m:GetFullName()] then
                                local ok, piv = pcall(function() return m:GetPivot() end)
                                if ok then
                                    local dist = (piv.Position - hrp.Position).Magnitude
                                    if dist < bd then best, bd, bpr = m, dist, d end
                                end
                            end
                        end
                    end
                    if best and bpr then
                        _G.HKAltarDone[best:GetFullName()] = true
                        local piv = best:GetPivot()
                        hrp.CFrame = CFrame.new(piv.X, piv.Y + 4, piv.Z + 2)
                        hrp.Velocity = Vector3.new()
                        task.wait(0.6)
                        pcall(function() fireproximityprompt(bpr) end)
                        task.wait(1.5)
                    end
                end
            end)
        end
        task.wait(2)
    end
end)

print("[HK] patch altar-first + blesspick aktif (pick=" .. tostring(_G.HKBlessPick) .. ")")
