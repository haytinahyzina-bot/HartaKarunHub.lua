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
    AutoPotion = true,
    AutoChest = true,    -- ambil chest per-room
    AutoClaim = true,    -- claim mid/end chest + potion + collect gear
    RoomRadius = 120,    -- radius sapu mob per-room dari tengah room
    ChestRadius = 150,   -- radius ambil chest per-room
    Dwell = 1.2,         -- jeda tiap titik biar spawn/trigger kebaca
    Noclip = false,      -- tembus tembok
    Speed = 28,          -- WalkSpeed (default game ~16-28)
    JumpPower = 50,      -- JumpPower (default 50)
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
    if Config.AutoClaim then
        pcall(function()
            RF_Run.SelectMidRunChests:InvokeServer({ 1, 2 })
            RF_Run.SelectChests:InvokeServer({ 1, 2 })
            local hud = LocalPlayer.PlayerGui:FindFirstChild("Main")
            hud = hud and hud:FindFirstChild("HUD")
            local cf = hud and hud:FindFirstChild("Chest_Selection")
            if cf then cf.Visible = false end
        end)
        pcall(function() RF_Gear.CollectAll:InvokeServer() end)
    end
    if Config.AutoPotion then
        local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if h and h.MaxHealth > 0 and (h.Health / h.MaxHealth * 100) < Config.PotionThreshold then
            pcall(function() RF_Potion.UsePotion:InvokeServer(1) end)
        end
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
        if Config.AutoChest then LootChestsNear(z.Pos, Config.ChestRadius) end
        if Config.AutoClaim or Config.AutoPotion then ClaimAll() end
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

-- ============================== UI SENDIRI (gaya Oxide, tanpa library luar) ==============================
-- Mini UI lib: window + sidebar tab + subtab + toggle/slider/dropdown/button/notify.
local UI = {}
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local gui = Instance.new("ScreenGui")
gui.Name = "HartaKarunUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = LocalPlayer.PlayerGui end

-- splash loading
local splash = Instance.new("Frame")
splash.Size = UDim2.new(0, 260, 0, 90)
splash.Position = UDim2.new(0.5, -130, 0.5, -45)
splash.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
splash.BorderSizePixel = 0
splash.Parent = gui
Instance.new("UICorner", splash).CornerRadius = UDim.new(0, 10)
local splashT = Instance.new("TextLabel")
splashT.Size = UDim2.new(1, 0, 1, 0)
splashT.BackgroundTransparency = 1
splashT.Text = "HartaKarun\nFarm"
splashT.Font = Enum.Font.GothamBold
splashT.TextSize = 18
splashT.TextColor3 = Color3.fromRGB(255, 255, 255)
splashT.Parent = splash

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 560, 0, 380)
main.Position = UDim2.new(0.5, -280, 0.5, -190)
main.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Visible = false
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

task.delay(1.2, function()
    splash.Visible = false
    main.Visible = true
    pcall(function()
        TweenService:Create(main, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { Size = UDim2.new(0, 560, 0, 380) }):Play()
    end)
end)

-- tombol minimize (pojok kanan atas layar)
local mini = Instance.new("TextButton")
mini.Size = UDim2.new(0, 90, 0, 28)
mini.Position = UDim2.new(1, -100, 0, 10)
mini.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
mini.Text = "HK Farm"
mini.Font = Enum.Font.GothamBold
mini.TextSize = 12
mini.TextColor3 = Color3.fromRGB(255, 255, 255)
mini.Parent = gui
Instance.new("UICorner", mini).CornerRadius = UDim.new(0, 8)
mini.MouseButton1Click:Connect(function() main.Visible = not main.Visible end)

-- sidebar
local side = Instance.new("Frame")
side.Size = UDim2.new(0, 150, 1, 0)
side.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
side.BorderSizePixel = 0
side.Parent = main
Instance.new("UICorner", side).CornerRadius = UDim.new(0, 10)

local sideTitle = Instance.new("TextLabel")
sideTitle.Size = UDim2.new(1, 0, 0, 44)
sideTitle.BackgroundTransparency = 1
sideTitle.Text = "HartaKarun"
sideTitle.Font = Enum.Font.GothamBold
sideTitle.TextSize = 15
sideTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
sideTitle.Parent = side

local content = Instance.new("Frame")
content.Size = UDim2.new(1, -158, 1, -8)
content.Position = UDim2.new(0, 154, 0, 4)
content.BackgroundTransparency = 1
content.Parent = main

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -8, 0, 18)
status.Position = UDim2.new(0, 4, 1, -22)
status.BackgroundTransparency = 1
status.Text = "Status: OFF"
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextColor3 = Color3.fromRGB(255, 120, 120)
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = content

function UI.Notify(title, text)
    local n = Instance.new("Frame")
    n.Size = UDim2.new(0, 240, 0, 56)
    n.Position = UDim2.new(1, -250, 0, 10 + (#gui:GetChildren() % 5) * 62)
    n.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
    n.BorderSizePixel = 0
    n.Parent = gui
    Instance.new("UICorner", n).CornerRadius = UDim.new(0, 8)
    local a = Instance.new("TextLabel")
    a.Size = UDim2.new(1, -10, 0, 20)
    a.Position = UDim2.new(0, 5, 0, 4)
    a.BackgroundTransparency = 1
    a.Text = tostring(title)
    a.Font = Enum.Font.GothamBold
    a.TextSize = 13
    a.TextColor3 = Color3.fromRGB(255, 200, 90)
    a.TextXAlignment = Enum.TextXAlignment.Left
    a.Parent = n
    local b = Instance.new("TextLabel")
    b.Size = UDim2.new(1, -10, 0, 28)
    b.Position = UDim2.new(0, 5, 0, 24)
    b.BackgroundTransparency = 1
    b.Text = tostring(text)
    b.Font = Enum.Font.Gotham
    b.TextSize = 12
    b.TextColor3 = Color3.fromRGB(230, 230, 230)
    b.TextXAlignment = Enum.TextXAlignment.Left
    b.Parent = n
    task.delay(2.5, function() pcall(function() n:Destroy() end) end)
end

local tabs = {}
function UI.AddTab(name)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -12, 0, 32)
    btn.Position = UDim2.new(0, 6, 0, 48 + #tabs * 38)
    btn.BackgroundColor3 = Color3.fromRGB(24, 27, 38)
    btn.Text = "  " .. name
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.TextColor3 = Color3.fromRGB(200, 200, 200)
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.Parent = side
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    local page = Instance.new("ScrollingFrame")
    page.Size = UDim2.new(1, 0, 1, -26)
    page.BackgroundTransparency = 1
    page.ScrollBarThickness = 4
    page.CanvasSize = UDim2.new(0, 0, 0, 600)
    page.Visible = (#tabs == 0)
    page.Parent = content
    local lay = Instance.new("UIListLayout")
    lay.Padding = UDim.new(0, 6)
    lay.Parent = page
    local tab = { Page = page, Subs = {} }
    btn.MouseButton1Click:Connect(function()
        for _, t in ipairs(tabs) do t.Page.Visible = false end
        page.Visible = true
    end)
    table.insert(tabs, tab)
    function tab:AddSubTab(subname)
        local holder = Instance.new("Frame")
        holder.Size = UDim2.new(1, -4, 0, 30)
        holder.BackgroundTransparency = 1
        holder.Parent = page
        local head = Instance.new("TextButton")
        head.Size = UDim2.new(1, 0, 0, 26)
        head.BackgroundColor3 = Color3.fromRGB(24, 27, 38)
        head.Text = "  " .. subname .. "  [-]"
        head.Font = Enum.Font.GothamBold
        head.TextSize = 12
        head.TextColor3 = Color3.fromRGB(255, 200, 90)
        head.TextXAlignment = Enum.TextXAlignment.Left
        head.Parent = holder
        Instance.new("UICorner", head).CornerRadius = UDim.new(0, 6)
        local body = Instance.new("Frame")
        body.Size = UDim2.new(1, 0, 0, 0)
        body.BackgroundTransparency = 1
        body.AutomaticSize = Enum.AutomaticSize.Y
        body.Parent = holder
        holder.AutomaticSize = Enum.AutomaticSize.Y
        local blay = Instance.new("UIListLayout")
        blay.Padding = UDim.new(0, 6)
        blay.Parent = body
        local open = true
        head.MouseButton1Click:Connect(function()
            open = not open
            body.Visible = open
            head.Text = "  " .. subname .. (open and "  [-]" or "  [+]")
        end)
        local sub = {}
        function sub:AddToggle(o)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 28)
            b.BackgroundColor3 = Color3.fromRGB(28, 31, 43)
            b.Font = Enum.Font.Gotham
            b.TextSize = 12
            b.TextColor3 = Color3.fromRGB(230, 230, 230)
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.Parent = body
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
            local state = o.Default == true
            local function ref() b.Text = "  " .. (state and "[ON]  " or "[OFF] ") .. o.Name end
            ref()
            b.MouseButton1Click:Connect(function()
                state = not state ref()
                pcall(o.Callback, state)
            end)
        end
        function sub:AddSlider(o)
            local f = Instance.new("Frame")
            f.Size = UDim2.new(1, 0, 0, 44)
            f.BackgroundColor3 = Color3.fromRGB(28, 31, 43)
            f.Parent = body
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
            local val = o.Default
            local function ref() l.Text = o.Name .. ": " .. tostring(val) .. (o.Suffix or "") end
            ref()
            local bar = Instance.new("TextButton")
            bar.Size = UDim2.new(1, -10, 0, 14)
            bar.Position = UDim2.new(0, 5, 0, 24)
            bar.BackgroundColor3 = Color3.fromRGB(45, 49, 65)
            bar.Text = ""
            bar.AutoButtonColor = false
            bar.Parent = f
            Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 7)
            local fill = Instance.new("Frame")
            fill.Size = UDim2.new((val - o.Min) / (o.Max - o.Min), 0, 1, 0)
            fill.BackgroundColor3 = Color3.fromRGB(80, 140, 255)
            fill.BorderSizePixel = 0
            fill.Parent = bar
            Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 7)
            local function setFromX(x)
                local p = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
                val = math.floor((o.Min + p * (o.Max - o.Min)) / (o.Step or 1) + 0.5) * (o.Step or 1)
                fill.Size = UDim2.new((val - o.Min) / (o.Max - o.Min), 0, 1, 0)
                ref()
                pcall(o.Callback, val)
            end
            local drag = false
            bar.InputBegan:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                    drag = true setFromX(i.Position.X)
                end
            end)
            UserInputService.InputChanged:Connect(function(i)
                if drag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                    setFromX(i.Position.X)
                end
            end)
            UserInputService.InputEnded:Connect(function(i)
                if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                    drag = false
                end
            end)
        end
        function sub:AddDropdown(o)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 28)
            b.BackgroundColor3 = Color3.fromRGB(28, 31, 43)
            b.Font = Enum.Font.Gotham
            b.TextSize = 12
            b.TextColor3 = Color3.fromRGB(230, 230, 230)
            b.Parent = body
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
            local idx = 1
            for i, v in ipairs(o.Options) do if tostring(v) == tostring(o.Default) then idx = i break end end
            local function ref() b.Text = "  " .. o.Name .. ": " .. tostring(o.Options[idx]) .. "  (klik ganti)" end
            ref()
            b.MouseButton1Click:Connect(function()
                idx = idx % #o.Options + 1 ref()
                pcall(o.Callback, o.Options[idx])
            end)
        end
        function sub:AddButton(o)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 30)
            b.BackgroundColor3 = o.Primary and Color3.fromRGB(60, 140, 70) or Color3.fromRGB(50, 90, 150)
            b.Font = Enum.Font.GothamBold
            b.TextSize = 12
            b.TextColor3 = Color3.fromRGB(255, 255, 255)
            b.Text = o.Name
            b.Parent = body
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
            b.MouseButton1Click:Connect(function() pcall(o.Callback) end)
        end
        function sub:AddSection(t)
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, 0, 0, 18)
            l.BackgroundTransparency = 1
            l.Text = t
            l.Font = Enum.Font.GothamBold
            l.TextSize = 12
            l.TextColor3 = Color3.fromRGB(255, 200, 90)
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.Parent = body
        end
        return sub
    end
    return tab
end

-- ============================== ISI UI ==============================
local FarmTab   = UI.AddTab("Farm")
local PlayerTab = UI.AddTab("Player")

local AutoSub = FarmTab:AddSubTab("Auto Farm")
AutoSub:AddToggle({ Name = "Enable Auto Farm", Default = false,
    Callback = function(v)
        SetFarm(v)
        UI.Notify("Auto Farm", v and "START: altar -> zone -> chest" or "STOP")
    end })
AutoSub:AddToggle({ Name = "Altar dulu saat START", Default = true,
    Callback = function(v) Config.AltarFirst = v end })
AutoSub:AddButton({ Name = "Start Solo: Catacombs Endless", Primary = true,
    Callback = function() StartSolo("Catacombs", "Endless") UI.Notify("Solo", "Queue Catacombs Endless") end })

local RangeSub = FarmTab:AddSubTab("Hover & Jarak")
RangeSub:AddSlider({ Name = "Tinggi hover", Min = 6, Max = 30, Default = 14, Step = 1, Suffix = "",
    Callback = function(v) Config.HoverHeight = v end })
RangeSub:AddSlider({ Name = "Jarak skill", Min = 20, Max = 150, Default = 60, Step = 5, Suffix = "",
    Callback = function(v) Config.SkillRange = v end })
RangeSub:AddSlider({ Name = "Leash anti-void", Min = 100, Max = 1000, Default = 350, Step = 50, Suffix = "",
    Callback = function(v) Config.Leash = v end })

local BlessSub = FarmTab:AddSubTab("Blessing & Chest")
BlessSub:AddDropdown({ Name = "Bless Pick", Options = { "1", "2", "3" }, Default = "1",
    Callback = function(v) Config.BlessPick = tonumber(v) or 1 end })
BlessSub:AddToggle({ Name = "Auto Chest per-room", Default = true,
    Callback = function(v) Config.AutoChest = v end })
BlessSub:AddToggle({ Name = "Auto Claim + collect", Default = true,
    Callback = function(v) Config.AutoClaim = v end })
BlessSub:AddToggle({ Name = "Auto Potion", Default = true,
    Callback = function(v) Config.AutoPotion = v end })
BlessSub:AddSlider({ Name = "Threshold potion", Min = 10, Max = 90, Default = 45, Step = 5, Suffix = "%",
    Callback = function(v) Config.PotionThreshold = v end })

local MoveSub = PlayerTab:AddSubTab("Movement")
MoveSub:AddToggle({ Name = "Noclip (tembus tembok)", Default = false,
    Callback = function(v) Config.Noclip = v end })
MoveSub:AddSlider({ Name = "Speed", Min = 16, Max = 120, Default = 28, Step = 2, Suffix = "",
    Callback = function(v) Config.Speed = v end })
MoveSub:AddSlider({ Name = "Jump High", Min = 50, Max = 250, Default = 50, Step = 10, Suffix = "",
    Callback = function(v) Config.JumpPower = v end })

task.spawn(function()
    while gui.Parent do
        if Config.AutoFarm then
            local s = Session()
            if s then
                status.Text = string.format("ON | mob %s/%s | %s",
                    tostring(s.MobsRemaining), tostring(s.TotalMobsInRoom), tostring(s.Phase))
            end
        else
            status.Text = "Status: OFF"
        end
        task.wait(1)
    end
end)

-- Noclip + Speed + JumpHigh (movement, independen dari farm)
task.spawn(function()
    while gui.Parent do
        pcall(function()
            local ch = LocalPlayer.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if hum then
                if hum.WalkSpeed ~= Config.Speed then hum.WalkSpeed = Config.Speed end
                if hum.JumpPower ~= Config.JumpPower then hum.JumpPower = Config.JumpPower end
                if hum.UseJumpPower == false then hum.UseJumpPower = true end
                if Config.Noclip and ch then
                    for _, v in ipairs(ch:GetDescendants()) do
                        if v:IsA("BasePart") and v.CanCollide then v.CanCollide = false end
                    end
                end
            end
        end)
        task.wait(0.3)
    end
end)

print("[HartaKarunFarm] UI sendiri loaded (tanpa library).")
