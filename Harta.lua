--[[
    HartaKarun Farm - standalone (no Oxide, no dependency)
    Ditulis dari nol berdasarkan reverse-engineering live Dungeon Lootr.
    ============================================================
    PAKAI:
      loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/HartaKarunFarm.lua"))()

    ALUR (sesuai video NS Hub):
      1. START -> kunci serang -> ke ALTAR dulu ambil blessing -> buka kunci
      2. Per-room berurutan: injak Zone (mancing spawn) -> habiskan mob
         -> ambil SEMUA chest room itu -> room berikutnya
      3. Blessing/chest 2-dari-3: auto-pilih sesuai nomor (default 1=kiri)
      4. Boss: dideteksi juga (HealthOverride/CanAttack, tanpa Humanoid)
      5. Selesai -> auto replay

    Pelajaran live yang dipakai:
      - Mob Katakomba TANPA Humanoid (HP di BillboardGui [cur/max])
      - Boss tanpa Humanoid/HRP (HealthOverride + CanAttack + State)
      - Teleport ke room CENTER tidak mancing spawn -> harus injak Zone
      - Enemy_Spawn mentah di bawah lantai -> JANGAN dikejar (void glitch)
      - Dummy lobby (Rig/Galran/dll) -> blacklist + leash 350
      - SelectBuff/Chest: kirim ID kalau ada, fallback index
--]]

-- ============================== CONFIG ==============================
local Config = {
    AutoFarm = false,
    AltarFirst = true,   -- ke altar dulu tiap run baru
    HoverHeight = 14,    -- hover di atas mob (studs), tidur tengkurap kepala ke mob
    SkillRange = 60,     -- skill/attack hanya keluar dalam jarak ini (+15 toleransi)
    Leash = 350,         -- mob di atas jarak ini tidak dikejar (anti void/lobby)
    BlessPick = 1,       -- 1=kiri, 2=tengah, 3=kanan
    PotionThreshold = 45,
    RoomRadius = 120,    -- radius sapu mob per-room dari tengah room
    ChestRadius = 150,   -- radius ambil chest per-room
    Dwell = 1.2,         -- jeda tiap titik biar spawn/trigger kebaca
}

-- Blacklist dummy/NPC (bukan musuh): nama + folder terlarang
local NAME_BLOCK = {
    Rig = true, Galran = true,
    ["Awakened Devil"] = true, BananitaDolphinita = true,
    ["Forge Archon"] = true,
}

-- ============================== SERVICES ==============================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local KnitSvc = ReplicatedStorage
    :WaitForChild("Packages", 10)._Index["sleitnick_knit@1.7.0"].knit.Services
local RF_Run = KnitSvc.DungeonRunService.RF
local RE_BuffSel = KnitSvc.DungeonBuffService.RE.BuffSelection
local RF_BuffPick = KnitSvc.DungeonBuffService.RF.SelectBuff
local RF_Queue = KnitSvc.DungeonQueueService.RF
local RF_Gear = KnitSvc.EquipmentService.RF
local RF_Potion = KnitSvc.PotionService.RF
-- Lazy: folder Player belum tentu ter-replikasi saat execute (fresh inject)
local function REM_Attack()
    local ok, r = pcall(function()
        return ReplicatedStorage:WaitForChild("Player", 5).Remotes.Inputs.Attack
    end)
    return ok and r or nil
end
local function REM_Skill()
    local ok, r = pcall(function()
        return ReplicatedStorage:WaitForChild("Player", 5).Remotes.Inputs.Skill
    end)
    return ok and r or nil
end

-- ============================== HELPERS ==============================
local function HRP()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function PivotOf(inst)
    local ok, cf = pcall(function() return inst:GetPivot() end)
    return ok and cf or nil
end

local function FireAttack(dir)
    local r = REM_Attack()
    if r then pcall(function() r:FireServer(dir or Vector3.new(0, 0, 1)) end) end
end

local function FireSkill(key, dir)
    local r = REM_Skill()
    if r then pcall(function() r:FireServer(key, "tap", dir or Vector3.new(0, 0, 1)) end) end
end

-- HP billboard [cur/max] (mob Katakomba tidak punya Humanoid)
local function BillboardHP(model)
    local cur, mx = 0, 0
    for _, b in ipairs(model:GetDescendants()) do
        if b:IsA("BillboardGui") then
            for _, t in ipairs(b:GetDescendants()) do
                if t:IsA("TextLabel") and type(t.Text) == "string" then
                    local c, m = t.Text:match("%[([%d,]+)/([%d,]+)%]")
                    if c then
                        c = c:gsub(",", "") m = m:gsub(",", "")
                        cur, mx = tonumber(c) or 0, tonumber(m) or 0
                        if mx > 0 then return cur, mx end
                    end
                end
            end
        end
    end
    return nil, nil
end

-- Semua yang BERDARAH = musuh:
--   Humanoid HP>0, atau billboard cur>0, atau HealthOverride+State~=Dead (boss)
local function HasBlood(model)
    local h = model:FindFirstChildOfClass("Humanoid")
    if h and h.Health > 0 then return true end
    local st = model:GetAttribute("State")
    local ov = model:GetAttribute("HealthOverride")
    if type(ov) == "number" and st ~= "Dead" then
        local cur = BillboardHP(model)
        if cur == nil or cur > 0 then return true end
    end
    if model:GetAttribute("CanAttack") == true and st ~= "Dead" then return true end
    local cur = BillboardHP(model)
    if cur and cur > 0 then return true end
    return false
end

local function IsEnemy(model)
    if not model or not model.Parent or model == LocalPlayer.Character then return false end
    if Players:GetPlayerFromCharacter(model) then return false end
    if NAME_BLOCK[model.Name] then return false end
    local par = model.Parent and model.Parent.Name or ""
    if par == "Dialogue_NPCS" or par == "RUSH_SPAWN" then return false end
    if model:GetAttribute("Idle_Type") ~= nil then return false end
    local hr = model:FindFirstChild("HumanoidRootPart")
    if hr and hr.Anchored then return false end
    return HasBlood(model)
end

local function NearestEnemy(maxDist)
    local hrp = HRP()
    if not hrp then return nil, math.huge end
    local best, bestd = nil, math.huge
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("Model") and IsEnemy(d) then
            local cf = PivotOf(d)
            if cf then
                local dist = (cf.Position - hrp.Position).Magnitude
                if dist < bestd and dist <= (maxDist or math.huge) then
                    bestd = dist
                    best = { Model = d, Pos = cf.Position, Name = d.Name }
                end
            end
        end
    end
    return best, bestd
end

local function PromptPos(prompt)
    local part = prompt.Parent
    if part and part:IsA("Attachment") then part = part.Parent end
    if part and part:IsA("BasePart") then return part.Position end
    local m = prompt:FindFirstAncestorOfClass("Model")
    if m then local cf = PivotOf(m) if cf then return cf.Position end end
    return nil
end

local function GenFolder()
    for _, c in ipairs(workspace:GetChildren()) do
        if c.Name:find("Generated_") then return c end
    end
    return nil
end

local function RoomZones() -- Zone tiap room (wajib diinjak, center saja tidak cukup)
    local gen = GenFolder()
    if not gen then return {} end
    local zones = {}
    for i = 1, 30 do
        local r = gen:FindFirstChild("Room_" .. i)
        local z = r and r:FindFirstChild("Zone")
        if z then local cf = PivotOf(z) if cf then table.insert(zones, { Index = i, Pos = cf.Position }) end end
    end
    return zones
end

local function Session()
    local ok, s = pcall(function() return RF_Run.GetSessionInfo:InvokeServer() end)
    if ok and type(s) == "table" then return s end
    return nil
end

local function ClaimAll()
    pcall(function()
        RF_Run.SelectMidRunChests:InvokeServer({ 1, 2 })
        RF_Run.SelectChests:InvokeServer({ 1, 2 })
        local hud = LocalPlayer.PlayerGui:FindFirstChild("Main")
        hud = hud and hud:FindFirstChild("HUD")
        local cf = hud and hud:FindFirstChild("Chest_Selection")
        if cf then cf.Visible = false end
    end)
    pcall(function() RF_Gear.CollectAll:InvokeServer() end)
    local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if h and h.MaxHealth > 0 and (h.Health / h.MaxHealth * 100) < Config.PotionThreshold then
        pcall(function() RF_Potion.UsePotion:InvokeServer(1) end)
    end
end

-- ============================== BLESSING 1/2/3 ==============================
local function BlessPickNow()
    local pick = tonumber(Config.BlessPick) or 1
    if pick < 1 or pick > 3 then pick = 1 end
    local id = nil
    pcall(function()
        local opts = _G.HKFLastBless and _G.HKFLastBless[1]
        if type(opts) == "table" and type(opts[pick]) == "table" and opts[pick].Id then
            id = tostring(opts[pick].Id)
        end
    end)
    if id then pcall(function() RF_BuffPick:InvokeServer(id) end) end
    pcall(function() RF_BuffPick:InvokeServer(pick) end)
end

RE_BuffSel.OnClientEvent:Connect(function(...)
    _G.HKFLastBless = { ... }
    task.wait(0.3)
    BlessPickNow()
end)

-- poller cadangan: PlayerGui + CoreGui tiap 2 detik
task.spawn(function()
    while true do
        pcall(function()
            local found = false
            for _, root in ipairs({ LocalPlayer.PlayerGui, game:GetService("CoreGui") }) do
                for _, d in ipairs(root:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Text == "PILIH BERKAT:" then found = true break end
                end
                if found then break end
            end
            if found then BlessPickNow() end
        end)
        task.wait(2)
    end
end)

-- ============================== COMBAT: hover 14 tengkurap, skill jarak ==============================
local function FightTarget(t)
    local hrp = HRP()
    if not hrp then return end
    -- patokan KEPALA mob (bukan tengah badan): 14 studs di atas kepala
    local headPos = t.Pos
    if t.Model then
        local head = t.Model:FindFirstChild("Head")
        if head and head:IsA("BasePart") then headPos = head.Position end
    end
    local hover = headPos + Vector3.new(0, Config.HoverHeight, 0)
    hrp.CFrame = CFrame.lookAt(hover, headPos) * CFrame.Angles(math.rad(90), 0, 0)
    local dist = (t.Pos - hrp.Position).Magnitude
    if dist <= Config.SkillRange + 15 then -- di luar jarak: jangan buang cooldown
        local dir = (t.Pos - hrp.Position).Unit
        FireAttack(dir)
        if not LocalPlayer:GetAttribute("Skill1_OnCooldown") then FireSkill(1, dir) task.wait(0.03) end
        if not LocalPlayer:GetAttribute("Skill2_OnCooldown") then FireSkill(2, dir) task.wait(0.03) end
        if not LocalPlayer:GetAttribute("Skill3_OnCooldown") then FireSkill(3, dir) task.wait(0.03) end
        if not LocalPlayer:GetAttribute("Skill4_OnCooldown") then FireSkill(4, dir) task.wait(0.03) end
        if LocalPlayer:GetAttribute("UltimateReady") == true then FireSkill("E", dir) end
    end
end

-- ============================== ROOM: mob habis -> chest room itu -> next ==============================
local function MobsNear(center, radius)
    local hrp = HRP()
    local list = {}
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("Model") and IsEnemy(d) then
            local cf = PivotOf(d)
            if cf and (cf.Position - center).Magnitude <= radius then
                local dist = hrp and (cf.Position - hrp.Position).Magnitude or 0
                table.insert(list, { Model = d, Pos = cf.Position, Dist = dist })
            end
        end
    end
    table.sort(list, function(a, b) return a.Dist < b.Dist end)
    return list
end

local function LootChestsNear(center, radius)
    for _, d in ipairs(workspace:GetDescendants()) do
        if not Config.AutoFarm then break end
        if d:IsA("ProximityPrompt") and d.Enabled and d.Name == "ChestPrompt" and d.HoldDuration == 0 then
            local m = d:FindFirstAncestorOfClass("Model")
            if m and (m.Name:find("DungeonChest") or m.Name:find("BossLoot")) then
                local tp = PromptPos(d)
                if tp and (tp - center).Magnitude <= radius then
                    local hrp = HRP()
                    if hrp then
                        hrp.CFrame = CFrame.new(tp + Vector3.new(0, 3, 2))
                        task.wait(0.25)
                        pcall(function() fireproximityprompt(d) end)
                        task.wait(0.4)
                    end
                end
            end
        end
    end
end

local function GoAltar()
    local hrp = HRP()
    if not hrp then return false end
    local best, bpr, bd = nil, nil, math.huge
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Enabled
            and string.find(string.lower(d.ActionText), "bless") then
            local m = d.Parent
            while m and not m:IsA("Model") do m = m.Parent end
            if m then
                local cf = PivotOf(m)
                if cf then
                    local dist = (cf.Position - hrp.Position).Magnitude
                    if dist < bd and dist <= 3000 then bd = dist best = cf.Position bpr = d end
                end
            end
        end
    end
    if best and bpr then
        hrp.CFrame = CFrame.new(best + Vector3.new(0, 3, 2))
        task.wait(0.5)
        pcall(function() fireproximityprompt(bpr) end)
        task.wait(1.5) -- tunggu UI berkat -> auto-pick jalan sendiri
        return true
    end
    return false
end

-- ============================== MAIN LOOP ==============================
local FarmGen = 0

local function FarmLoop(gen)
    -- 1) altar dulu (dikunci: tidak ada serang sampai altar/timeout 20 dtk)
    if Config.AltarFirst then
        local t0 = os.clock()
        GoAltar()
        while Config.AutoFarm and gen == FarmGen and os.clock() - t0 < 20 do
            local done = false
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("TextLabel") and d.Text == "PILIH BERKAT:" then done = true break end
            end
            if not done then break end -- UI sudah ketutup = berkat kepilih
            task.wait(1)
        end
    end
    -- 2) sapu Zone tiap room berurutan
    local zones = RoomZones()
    local idx = 1
    while Config.AutoFarm and gen == FarmGen do
        if #zones == 0 then zones = RoomZones() end
        if #zones == 0 then task.wait(1) continue end
        if idx > #zones then idx = 1 end
        local z = zones[idx]
        local hrp = HRP()
        if hrp then hrp.CFrame = CFrame.new(z.Pos + Vector3.new(0, 3, 0)) end
        task.wait(Config.Dwell)
        -- 3) habiskan mob di room ini (radius dari tengah room)
        local guard = 0
        while Config.AutoFarm and gen == FarmGen and guard < 60 do
            guard += 1
            local mobs = MobsNear(z.Pos, Config.RoomRadius)
            if #mobs == 0 then break end
            FightTarget(mobs[1])
            task.wait(0.1)
        end
        -- 4) ambil SEMUA chest room ini dulu, baru pindah
        LootChestsNear(z.Pos, Config.ChestRadius)
        ClaimAll()
        idx += 1
        task.wait(0.3)
    end
end

function SetFarm(on)
    if on then
        FarmGen += 1
        Config.AutoFarm = true
        task.spawn(function() FarmLoop(FarmGen) end)
    else
        Config.AutoFarm = false
        FarmGen += 1 -- bunuh semua loop lama (anti loop ganda)
    end
end

function StartSolo(dungeonName, difficulty)
    pcall(function()
        RF_Queue.RequestSelectMode:InvokeServer("Solo")
        task.wait(0.3)
        RF_Queue.RequestSelectDungeon:InvokeServer(dungeonName)
        task.wait(0.3)
        RF_Queue.RequestSelectDifficulty:InvokeServer(difficulty)
        task.wait(0.3)
        RF_Queue.RequestStartSoloRun:InvokeServer()
    end)
end

-- auto replay saat run selesai
pcall(function()
    KnitSvc.DungeonRunService.RE.DungeonComplete.OnClientEvent:Connect(function()
        if Config.AutoFarm then
            task.wait(2)
            pcall(function() RF_Run.RequestReplay:InvokeServer() end)
        end
    end)
end)

-- ============================== UI MINIMAL (murni Roblox) ==============================
local gui = Instance.new("ScreenGui")
gui.Name = "HartaKarunFarm"
gui.ResetOnSpawn = false
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = LocalPlayer.PlayerGui end

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 280, 0, 400)
main.Position = UDim2.new(0, 20, 0.5, -200)
main.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 32)
title.BackgroundTransparency = 1
title.Text = "  HartaKarun Farm"
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = main

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 18)
status.Position = UDim2.new(0, 10, 0, 32)
status.BackgroundTransparency = 1
status.Text = "Status: OFF"
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextColor3 = Color3.fromRGB(255, 120, 120)
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = main

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -16, 1, -100)
scroll.Position = UDim2.new(0, 8, 0, 54)
scroll.BackgroundTransparency = 1
scroll.ScrollBarThickness = 4
scroll.CanvasSize = UDim2.new(0, 0, 0, 480)
scroll.Parent = main
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = scroll

local function Toggle(text, key)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -8, 0, 28)
    b.BackgroundColor3 = Color3.fromRGB(30, 33, 45)
    b.Font = Enum.Font.Gotham
    b.TextSize = 12
    b.TextColor3 = Color3.fromRGB(230, 230, 230)
    b.Parent = scroll
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    local function refresh() b.Text = (Config[key] and "[ON]  " or "[OFF] ") .. text end
    refresh()
    b.MouseButton1Click:Connect(function() Config[key] = not Config[key] refresh() end)
    return b
end

local function Slider(text, key, min, max, step)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, -8, 0, 40)
    f.BackgroundColor3 = Color3.fromRGB(30, 33, 45)
    f.Parent = scroll
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 6)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, -10, 0, 18)
    l.Position = UDim2.new(0, 5, 0, 2)
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.Gotham
    l.TextSize = 12
    l.TextColor3 = Color3.fromRGB(230, 230, 230)
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = f
    local function refresh() l.Text = text .. ": " .. tostring(Config[key]) end
    refresh()
    local minus = Instance.new("TextButton")
    minus.Size = UDim2.new(0.5, -3, 0, 16)
    minus.Position = UDim2.new(0, 2, 0, 22)
    minus.BackgroundColor3 = Color3.fromRGB(50, 54, 70)
    minus.Text = "-"
    minus.TextColor3 = Color3.fromRGB(255, 255, 255)
    minus.Font = Enum.Font.GothamBold
    minus.Parent = f
    local plus = Instance.new("TextButton")
    plus.Size = UDim2.new(0.5, -3, 0, 16)
    plus.Position = UDim2.new(0.5, 1, 0, 22)
    plus.BackgroundColor3 = Color3.fromRGB(50, 54, 70)
    plus.Text = "+"
    plus.TextColor3 = Color3.fromRGB(255, 255, 255)
    plus.Font = Enum.Font.GothamBold
    plus.Parent = f
    minus.MouseButton1Click:Connect(function() Config[key] = math.max(min, Config[key] - step) refresh() end)
    plus.MouseButton1Click:Connect(function() Config[key] = math.min(max, Config[key] + step) refresh() end)
end

local farmBtn = Instance.new("TextButton")
farmBtn.Size = UDim2.new(1, -8, 0, 32)
farmBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 70)
farmBtn.Font = Enum.Font.GothamBold
farmBtn.TextSize = 13
farmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
farmBtn.Text = "START FARM"
farmBtn.Parent = scroll
Instance.new("UICorner", farmBtn).CornerRadius = UDim.new(0, 6)
farmBtn.MouseButton1Click:Connect(function()
    SetFarm(not Config.AutoFarm)
    farmBtn.Text = Config.AutoFarm and "STOP FARM" or "START FARM"
    farmBtn.BackgroundColor3 = Config.AutoFarm and Color3.fromRGB(150, 60, 60) or Color3.fromRGB(60, 140, 70)
    status.Text = Config.AutoFarm and "Status: ON" or "Status: OFF"
    status.TextColor3 = Config.AutoFarm and Color3.fromRGB(120, 255, 120) or Color3.fromRGB(255, 120, 120)
end)

Toggle("Altar dulu saat START", "AltarFirst")
Slider("Tinggi hover", "HoverHeight", 6, 30, 1)
Slider("Jarak skill", "SkillRange", 20, 150, 5)
Slider("Leash anti-void", "Leash", 100, 1000, 50)

local blessRow = Instance.new("Frame")
blessRow.Size = UDim2.new(1, -8, 0, 28)
blessRow.BackgroundTransparency = 1
blessRow.Parent = scroll
local bl = Instance.new("TextLabel")
bl.Size = UDim2.new(0.4, 0, 1, 0)
bl.BackgroundTransparency = 1
bl.Text = "Bless Pick:"
bl.Font = Enum.Font.Gotham
bl.TextSize = 12
bl.TextColor3 = Color3.fromRGB(230, 230, 230)
bl.TextXAlignment = Enum.TextXAlignment.Left
bl.Parent = blessRow
for i = 1, 3 do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0.2, -4, 1, 0)
    b.Position = UDim2.new(0.4 + (i - 1) * 0.2, 2, 0, 0)
    b.BackgroundColor3 = (Config.BlessPick == i) and Color3.fromRGB(60, 140, 70) or Color3.fromRGB(30, 33, 45)
    b.Text = tostring(i)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Parent = blessRow
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.MouseButton1Click:Connect(function()
        Config.BlessPick = i
        for _, sib in ipairs(blessRow:GetChildren()) do
            if sib:IsA("TextButton") then
                sib.BackgroundColor3 = (tonumber(sib.Text) == Config.BlessPick)
                    and Color3.fromRGB(60, 140, 70) or Color3.fromRGB(30, 33, 45)
            end
        end
    end)
end

local soloBtn = Instance.new("TextButton")
soloBtn.Size = UDim2.new(1, -8, 0, 28)
soloBtn.BackgroundColor3 = Color3.fromRGB(50, 90, 150)
soloBtn.Font = Enum.Font.GothamBold
soloBtn.TextSize = 12
soloBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
soloBtn.Text = "Start Solo: Catacombs Endless"
soloBtn.Parent = scroll
Instance.new("UICorner", soloBtn).CornerRadius = UDim.new(0, 6)
soloBtn.MouseButton1Click:Connect(function() StartSolo("Catacombs", "Endless") end)

task.spawn(function()
    while gui.Parent do
        if Config.AutoFarm then
            local s = Session()
            local hrp = HRP()
            if s then
                status.Text = string.format("ON | mob %s/%s | %s",
                    tostring(s.MobsRemaining), tostring(s.TotalMobsInRoom), tostring(s.Phase))
            elseif hrp then
                status.Text = string.format("ON | %d,%d,%d",
                    math.floor(hrp.Position.X), math.floor(hrp.Position.Y), math.floor(hrp.Position.Z))
            end
        end
        task.wait(1)
    end
end)

print("[HartaKarunFarm] loaded. Tekan START FARM (altar -> zone 1..N -> chest).")
