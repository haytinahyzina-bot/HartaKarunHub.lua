-- Harta Karun Hub | single-file loader
-- Cara pakai di executor: loadstring(game:HttpGet("https://raw.githubusercontent.com/haytinahyzina-bot/HartaKarunHub/main/HartaKarunHub.lua"))()

-- Harta Karun Dungeon | Farm v4 (tulis ulang bersih)
-- Satu scanner + satu hover + attack/skill/ESP/stealth/gate.
-- Semua fitur DEFAULT OFF, nyalakan dari dashboard.
-- (Auto-load teleport SENGAJA tidak dipakai: bikin double-load.)

pcall(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
end)
task.wait(2)

_G.HK = _G.HK or {}
_G.HK.hover = false
_G.HK.height = _G.HK.height or 14
_G.HK.chest = false
_G.HK.atk = false
_G.HK.atkRange = _G.HK.atkRange or 15
_G.HK.skill = false
_G.HK.rate = _G.HK.rate or 0.25
_G.HK.esp = false
_G.HK.loot = true
_G.HK.dropLoot = false
_G.HK.speed = 28
_G.HK.noclip = false
_G.HK.infjump = false
_G.HK.fly = false
_G.HK.flyspeed = _G.HK.flyspeed or 60
_G.HK.tick = 0
_G.HK.target = "none"
_G.HK.stealth = false
_G.HK.autoFarm = false

-- Pengecualian hover (nama model). NPC quest / dummy / pemain di-skip otomatis.
_G.HKBlock = _G.HKBlock or { "Galran", "BananitaDolphinita", "Forge Archon", "Awakened Devil", "Rig" }
_G.HKZone = { room = nil }
_G.HKT = nil
_G.HKAltarDone = _G.HKAltarDone or {}

-- Tombol skill (1-4) + heal (5). Ubah sesukamu.
_G.HKSkillKeys = _G.HKSkillKeys or { "One", "Two", "Three", "Four" }
_G.HK.autoHeal = false

-- ID animasi ayunan (stealth). Damage tetap masuk (server-side).
_G.HKSwingIds = {
    ["106806110702885"] = true, ["109893308802725"] = true,
    ["126671356379936"] = true, ["112357005052418"] = true,
    ["105520255900501"] = true, ["113090603838738"] = true,
    ["82343948148104"] = true,
}

local P = game.Players.LocalPlayer
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
-- Lazy: folder Player belum tentu ter-replikasi saat execute (fresh inject).
local function getInputs()
    local ok, r = pcall(function()
        return game.ReplicatedStorage:WaitForChild("Player", 5).Remotes.Inputs
    end)
    if ok then
        return r
    end
end
local HKVIM = nil
pcall(function() HKVIM = game:GetService("VirtualInputManager") end)

local function getGen()
    for _, c in ipairs(workspace:GetChildren()) do
        if string.find(c.Name, "Generated") then
            return c
        end
    end
    return nil
end

local function mobAlive(m)
    for _, n in ipairs(_G.HKBlock) do
        if m.Name == n then
            return false
        end
    end
    local fn = m:GetFullName()
    if string.find(fn, "Dialogue_NPCS")
        or string.find(fn, "Combat_Dummies")
        or string.find(fn, "PlayerModels") then
        return false
    end
    local hum = m:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health > 0 then
        return true
    end
    local st = m:GetAttribute("State")
    if m:GetAttribute("CanAttack") == true and st ~= "Dead" then
        return true
    end
    if m:GetAttribute("HealthOverride") ~= nil and st ~= "Dead" then
        return true
    end
    return false
end

local function mobHP(m)
    local hum = m:FindFirstChildOfClass("Humanoid")
    if hum then
        return hum.Health
    end
    local ov = m:GetAttribute("HealthOverride")
    if type(ov) == "number" then
        return ov
    end
    return 1e9
end

local function mobPart(m)
    return m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("Torso")
end

-- Posisi target: part tubuh kalau ada, kalau belum materialisasi
-- (boss: aksesoris ada, badan belum) pakai tengah bounding box.
local function mobPos(m)
    local th = mobPart(m)
    if th then
        return th.Position, th
    end
    local ok, cf = pcall(function() return m:GetBoundingBox() end)
    if ok and cf then
        return cf.Position, nil
    end
    return nil, nil
end

-- Scanner: tiap 0.5 dtk petakan mob hidup ke room, prioritaskan
-- darah terendah di room aktif. Di luar Generated tetap dilirik
-- (maks 600 stud) supaya event tidak ke-skip total.
task.spawn(function()
    while true do
        pcall(function()
            local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                local chars = {}
                for _, pl in ipairs(game.Players:GetPlayers()) do
                    if pl.Character then
                        chars[pl.Character] = true
                    end
                end
                local gen = getGen()
                local scope = gen or workspace
                local rooms = {}
                if gen then
                    for _, c in ipairs(gen:GetChildren()) do
                        local n = string.match(c.Name, "^Room_(%d+)$")
                        if n and c:IsA("Model") then
                            local ok, piv = pcall(function() return c:GetPivot() end)
                            if ok then
                                rooms[tonumber(n)] = piv.Position
                            end
                        end
                    end
                end
                local byRoom = {}
                local best, bestRoom, bd = nil, nil, 1e9
                for _, d in ipairs(scope:GetDescendants()) do
                    if d:IsA("Model") and d ~= P.Character and not chars[d] then
                        if mobAlive(d) then
                            local pos = mobPos(d)
                            if pos then
                                local dist = (pos - hrp.Position).Magnitude
                                if dist < 600 then
                                    local rn, rd = 0, 1e9
                                    for n, rpos in pairs(rooms) do
                                        local dxz = Vector2.new(
                                            pos.X - rpos.X,
                                            pos.Z - rpos.Z).Magnitude
                                        if dxz < rd then
                                            rn, rd = n, dxz
                                        end
                                    end
                                    byRoom[rn] = byRoom[rn] or {}
                                    table.insert(byRoom[rn], { m = d, hp = mobHP(d) })
                                    if dist < bd then
                                        best, bestRoom, bd = d, rn, dist
                                    end
                                end
                            end
                        end
                    end
                end
                local cur = _G.HKZone.room
                local tgt = nil
                if cur and byRoom[cur] and #byRoom[cur] > 0 then
                    table.sort(byRoom[cur], function(a, b) return a.hp < b.hp end)
                    tgt = byRoom[cur][1]
                elseif best then
                    _G.HKZone.room = bestRoom
                    _G.HKZone.lastRoom = bestRoom
                    tgt = { m = best, hp = mobHP(best) }
                else
                    _G.HKZone.room = nil
                end
                _G.HKT = tgt and tgt.m or nil
                if _G.HKZone.room then
                    _G.HKZone.lastRoom = _G.HKZone.room
                end
                if tgt then
                    _G.HK.target = "R" .. tostring(_G.HKZone.room) .. " "
                        .. tgt.m.Name .. " hp" .. tostring(math.floor(tgt.hp))
                else
                    _G.HK.target = "no mob"
                end
            end
        end)
        task.wait(0.5)
    end
end)

-- Loop utama: speed lock + noclip + fly + hover tidur.
RS.Heartbeat:Connect(function()
    _G.HK.tick += 1
    local ch = P.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then
        _G.HK.target = "dead/none"
        return
    end
    if _G.HK.noclip then
        for _, v in ipairs(ch:GetDescendants()) do
            if v:IsA("BasePart") and v.CanCollide then
                v.CanCollide = false
            end
        end
    end
    if hum.WalkSpeed ~= _G.HK.speed then
        hum.WalkSpeed = _G.HK.speed
    end
    if _G.HK.fly then
        local cf = hrp.CFrame
        local mv = Vector3.new()
        if UIS:IsKeyDown(Enum.KeyCode.W) then mv += workspace.CurrentCamera.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then mv -= workspace.CurrentCamera.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then mv -= workspace.CurrentCamera.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then mv += workspace.CurrentCamera.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then mv += Vector3.new(0, 1, 0) end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then mv -= Vector3.new(0, 1, 0) end
        if mv.Magnitude > 0 then
            hrp.CFrame = cf + mv.Unit * (_G.HK.flyspeed * 0.05)
            hrp.Velocity = Vector3.new()
        end
    end
    local mob = _G.HKT
    if mob and mob.Parent and not mobAlive(mob) then
        mob = nil
    end
    if _G.HK.hx and mob then
        local pos = mobPos(mob)
        -- HOVER: patokan kepala bila ada (tinggi = di atas kepala)
        local head = mob:FindFirstChild("Head")
        if head and head:IsA("BasePart") then pos = head.Position end
        if pos then
            hum.AutoRotate = false
            local h = _G.HK.height
            if h > 30 then
                h = 30
            end
            if h < 4 then
                h = 4
            end
            -- HOVER: tidur tengkurap, kepala menghadap ke mob di bawah
            hrp.CFrame = CFrame.lookAt(pos + Vector3.new(0, h, 0), pos) * CFrame.Angles(math.rad(90), 0, 0)
            hrp.Velocity = Vector3.new()
            hrp.RotVelocity = Vector3.new()
        end
    else
        hum.AutoRotate = true
        if mob then
            _G.HK.target = mob.Name .. " (hover off)"
        end
    end
end)

-- Attack: hanya kalau target dalam jarak atkRange.
task.spawn(function()
    while true do
        if _G.HK.atk then
            pcall(function()
                local mob = _G.HKT
                local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
                if mob and mob.Parent and hrp then
                    local pos = mobPos(mob)
                    if pos and (pos - hrp.Position).Magnitude <= (_G.HK.atkRange or 15) then
                        local inp = getInputs()
                        if inp then
                            inp.Attack:FireServer()
                        end
                    end
                end
            end)
        end
        task.wait(_G.HK.rate)
    end
end)

-- Skill via hotkey (1-4): hanya kalau target dalam jarak. Heal (5) saat HP<40%.
task.spawn(function()
    while true do
        if _G.HK.skill and HKVIM then
            pcall(function()
                local mob = _G.HKT
                local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
                local inRange = false
                if mob and mob.Parent and hrp then
                    local pos = mobPos(mob)
                    if pos and (pos - hrp.Position).Magnitude <= (_G.HK.atkRange or 15) then
                        inRange = true
                    end
                end
                if inRange then
                    for _, kn in ipairs(_G.HKSkillKeys or {}) do
                        if not _G.HK.skill then
                            break
                        end
                        HKVIM:SendKeyEvent(true, Enum.KeyCode[kn], false, game)
                        task.wait(0.05)
                        HKVIM:SendKeyEvent(false, Enum.KeyCode[kn], false, game)
                        task.wait(1.5)
                    end
                end
            end)
        end
        task.wait(0.5)
    end
end)

task.spawn(function()
    while true do
        if _G.HK.autoHeal and HKVIM then
            pcall(function()
                local hum = P.Character and P.Character:FindFirstChildOfClass("Humanoid")
                if hum and hum.MaxHealth > 0 and hum.Health / hum.MaxHealth < 0.4 then
                    HKVIM:SendKeyEvent(true, Enum.KeyCode.Five, false, game)
                    task.wait(0.05)
                    HKVIM:SendKeyEvent(false, Enum.KeyCode.Five, false, game)
                end
            end)
        end
        task.wait(2)
    end
end)

-- Infinite jump.
UIS.JumpRequest:Connect(function()
    if _G.HK.infjump and P.Character then
        local hum = P.Character:FindFirstChildOfClass("Humanoid")
        if hum then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end)

-- ESP: merah = Humanoid, oranye = attribute (Lv + State).
-- Scope dungeon saja + tiap 5 detik (hemat FPS).
task.spawn(function()
    while true do
        if _G.HK.esp then
            pcall(function()
                local scope = getGen() or workspace
                for _, d in ipairs(scope:GetDescendants()) do
                    if d:IsA("Model") and d ~= P.Character and not d:FindFirstChild("HK_ESP") then
                        local skip = false
                        for _, pl in ipairs(game.Players:GetPlayers()) do
                            if pl.Character == d then
                                skip = true
                                break
                            end
                        end
                        local label, color = nil, Color3.new(1, 0.35, 0.35)
                        if not skip then
                            local hum = d:FindFirstChildOfClass("Humanoid")
                            if hum and hum.Health > 0 then
                                label = d.Name .. " " .. tostring(math.floor(hum.Health))
                            elseif mobAlive(d) then
                                label = d.Name .. " Lv" .. tostring(d:GetAttribute("Level"))
                                    .. " " .. tostring(d:GetAttribute("State"))
                                color = Color3.new(1, 0.6, 0.2)
                            end
                        end
                        if label then
                            local ador = mobPart(d)
                            if not ador then
                                local _, p2 = mobPos(d)
                                ador = p2
                            end
                            if ador then
                                local bb = Instance.new("BillboardGui")
                                bb.Name = "HK_ESP"
                                bb.Size = UDim2.new(0, 150, 0, 32)
                                bb.StudsOffset = Vector3.new(0, 3, 0)
                                bb.AlwaysOnTop = true
                                bb.Adornee = ador
                                bb.Parent = d
                                local tl = Instance.new("TextLabel")
                                tl.Size = UDim2.new(1, 0, 1, 0)
                                tl.BackgroundTransparency = 1
                                tl.TextColor3 = color
                                tl.TextStrokeTransparency = 0
                                tl.TextSize = 13
                                tl.Font = Enum.Font.Code
                                tl.Text = label
                                tl.Parent = bb
                            end
                        end
                    end
                end
            end)
        end
        task.wait(5)
    end
end)

-- Stealth: potong ayunan pre-render. Damage tetap masuk (server-side).
RS.RenderStepped:Connect(function()
    if not (_G.HK and _G.HK.stealth) then
        return
    end
    local ch = P.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local anim = hum and hum:FindFirstChildOfClass("Animator")
    if not anim then
        return
    end
    for _, tr in ipairs(anim:GetPlayingAnimationTracks()) do
        local id = tr.Animation and tr.Animation.AnimationId or ""
        local num = string.match(id, "(%d+)")
        if num and _G.HKSwingIds[num] then
            pcall(function() tr:Stop(0) end)
        end
    end
end)

-- Gate loop = alur full user:
--   1. Run fresh -> altar dulu (pilih otomatis via picker).
--   2. Kembali gate 1 -> bunuh semua (hover farm).
--   3. Scan chest gate itu -> datangi + buka (tunggu kebuka).
--   4. Tidak ada -> gate berikut. Ulang sampai boss mati.
--   5. Popup 2-dari-3 dipilih otomatis (poller terpisah).
-- Reset per run terdeteksi via TotalMobs (penuh = run baru).
_G.HKAltarDone = _G.HKAltarDone or {}
_G.HKChestSkip = _G.HKChestSkip or {}
task.spawn(function()
    while true do
        if _G.HK.chest and _G.HKT == nil then
            pcall(function()
                local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local gen = getGen()
                    if gen then
                        local rooms = {}
                        for _, c in ipairs(gen:GetChildren()) do
                            local n = string.match(c.Name, "^Room_(%d+)$")
                            if n and c:IsA("Model") then
                                local ok, piv = pcall(function() return c:GetPivot() end)
                                if ok then
                                    table.insert(rooms, { n = tonumber(n), pos = piv.Position })
                                end
                            end
                        end
                        table.sort(rooms, function(a, b) return a.n < b.n end)
                        local function roomOf(pos)
                            local rn, rd = 0, 1e9
                            for _, r in ipairs(rooms) do
                                local dxz = Vector2.new(
                                    pos.X - r.pos.X, pos.Z - r.pos.Z).Magnitude
                                if dxz < rd then
                                    rn, rd = r.n, dxz
                                end
                            end
                            return rn
                        end
                        -- Aturan ketat user: mob room habis -> chest ROOM ITU
                        -- dulu (semua), baru pindah gate. Skip direset tiap
                        -- ada chest yang berhasil dibuka (dependency maju).
                        local cur = _G.HKZone.room or _G.HKZone.lastRoom
                        if not cur then
                            -- Reload tengah run: tebak room dari posisi pemain.
                            cur = roomOf(hrp.Position)
                            if cur and cur ~= 0 then
                                _G.HKZone.lastRoom = cur
                            else
                                cur = nil
                            end
                        end
                        _G.HKChestSkip = _G.HKChestSkip or {}
                        -- Run fresh (mob masih penuh, belum pernah farm):
                        -- ke altar berkah DULU, baru mulai dari gate 1.
                        local freshRun = false
                        if _G.HKZone.lastRoom == nil then
                            pcall(function()
                                local rf = game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
                                    .knit.Services.DungeonRunService.RF.GetSessionInfo
                                local s = rf:InvokeServer()
                                if type(s) == "table" and tonumber(s.MobsRemaining)
                                    and tonumber(s.TotalMobsInRoom)
                                    and tonumber(s.MobsRemaining) >= tonumber(s.TotalMobsInRoom)
                                    and tonumber(s.TotalMobsInRoom) > 0 then
                                    freshRun = true
                                end
                            end)
                        end
                        if _G.HKZone.lastRoom == nil and not freshRun and cur then
                            _G.HKZone.lastRoom = cur
                        end
                        if freshRun then
                            local altar0, apr0, abd0 = nil, nil, 1e9
                            for _, d in ipairs(gen:GetDescendants()) do
                                if d:IsA("ProximityPrompt") and d.Enabled
                                    and string.find(string.lower(d.ActionText), "bless") then
                                    local m = d.Parent
                                    while m and not m:IsA("Model") do
                                        m = m.Parent
                                    end
                                    if m and not _G.HKAltarDone[m:GetFullName()] then
                                        local ok, piv = pcall(function() return m:GetPivot() end)
                                        if ok then
                                            local dist = (piv.Position - hrp.Position).Magnitude
                                            if dist < abd0 then
                                                altar0, abd0, apr0 = m, dist, d
                                            end
                                        end
                                    end
                                end
                            end
                            if altar0 and apr0 then
                                _G.HKAltarDone[altar0:GetFullName()] = true
                                local piv = altar0:GetPivot()
                                hrp.CFrame = CFrame.new(piv.X, piv.Y + 4, piv.Z + 2)
                                hrp.Velocity = Vector3.new()
                                task.wait(0.6)
                                pcall(function() fireproximityprompt(apr0) end)
                                task.wait(1.5)
                            else
                                local r1 = nil
                                for _, r in ipairs(rooms) do
                                    if r.n == 1 or not r1 or r.n < r1.n then
                                        r1 = r
                                    end
                                end
                                if r1 then
                                    hrp.CFrame = CFrame.new(r1.pos.X, r1.pos.Y + 5, r1.pos.Z)
                                    hrp.Velocity = Vector3.new()
                                    _G.HKZone.room = r1.n
                                end
                            end
                        end
                        local tgt, pr = nil, nil
                        if cur then
                            local bd = 1e9
                            for _, d in ipairs(gen:GetDescendants()) do
                                if d:IsA("ProximityPrompt") and d.Enabled
                                    and string.find(string.lower(d.ActionText), "loot") then
                                    local m = d.Parent
                                    while m and not m:IsA("Model") do
                                        m = m.Parent
                                    end
                                    if m and not _G.HKChestSkip[m:GetFullName()] then
                                        local ok, piv = pcall(function() return m:GetPivot() end)
                                        if ok and roomOf(piv.Position) == cur then
                                            local dist = (piv.Position - hrp.Position).Magnitude
                                            if dist < bd then
                                                tgt, pr, bd = m, d, dist
                                            end
                                        end
                                    end
                                end
                            end
                        end
                        if tgt and pr then
                            local piv = tgt:GetPivot()
                            hrp.CFrame = CFrame.new(piv.X, piv.Y + 4, piv.Z + 2)
                            hrp.Velocity = Vector3.new()
                            local opened = false
                            for i = 1, 8 do
                                task.wait(0.7)
                                if not pr.Enabled then
                                    opened = true
                                    break
                                end
                                pcall(function() fireproximityprompt(pr) end)
                                if _G.HKT ~= nil then
                                    break
                                end
                            end
                            if not opened and pr.Enabled then
                                _G.HKChestSkip[tgt:GetFullName()] = true
                            elseif opened then
                                _G.HKChestSkip = {}
                            end
                        else
                            local altar, apr, abd = nil, nil, 1e9
                            for _, d in ipairs(gen:GetDescendants()) do
                                if d:IsA("ProximityPrompt") and d.Enabled
                                    and string.find(string.lower(d.ActionText), "bless") then
                                    local m = d.Parent
                                    while m and not m:IsA("Model") do
                                        m = m.Parent
                                    end
                                    if m and not _G.HKAltarDone[m:GetFullName()] then
                                        local ok, piv = pcall(function() return m:GetPivot() end)
                                        if ok then
                                            local dist = (piv.Position - hrp.Position).Magnitude
                                            if dist < abd then
                                                altar, abd, apr = m, dist, d
                                            end
                                        end
                                    end
                                end
                            end
                            if altar and apr then
                                _G.HKAltarDone[altar:GetFullName()] = true
                                local piv = altar:GetPivot()
                                hrp.CFrame = CFrame.new(piv.X, piv.Y + 4, piv.Z + 2)
                                hrp.Velocity = Vector3.new()
                                task.wait(0.6)
                                pcall(function() fireproximityprompt(apr) end)
                            elseif cur then
                                local nxt = nil
                                for _, r in ipairs(rooms) do
                                    if r.n > cur and (not nxt or r.n < nxt.n) then
                                        nxt = r
                                    end
                                end
                                if not nxt then
                                    nxt = rooms[1]
                                end
                                if nxt then
                                    hrp.CFrame = CFrame.new(nxt.pos.X, nxt.pos.Y + 5, nxt.pos.Z)
                                    hrp.Velocity = Vector3.new()
                                end
                            end
                        end
                    end
                end
            end)
        end
        task.wait(2)
    end
end)

-- Auto loot drop monster: dengar event SpawnDrops, petakan pasangan
-- (id, posisi) dari payload, teleport dekat, panggil CollectDrop.
-- Bentuk payload tidak tetap jadi parser-nya adaptif; semua aman di-pcall.
_G.HKDropQueue = _G.HKDropQueue or {}
task.spawn(function()
    local svc = game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services
    local ds = svc:FindFirstChild("DropService")
    local sp = ds and ds.RE and ds.RE:FindFirstChild("SpawnDrops")
    local cd = ds and ds.RF and ds.RF:FindFirstChild("CollectDrop")
    if sp then
        pcall(function()
            sp.OnClientEvent:Connect(function(...)
                for _, a in ipairs({ ... }) do
                    local function walk(t, ctx)
                        if type(t) ~= "table" then
                            return
                        end
                        ctx = ctx or {}
                        for k, v in pairs(t) do
                            if type(v) == "table" then
                                walk(v, ctx)
                            elseif typeof(v) == "Vector3" or typeof(v) == "CFrame" then
                                ctx.pos = v
                            elseif type(v) == "string" and #v > 3 then
                                ctx.id = v
                            elseif type(v) == "number" and v > 1000 then
                                ctx.numId = v
                            end
                        end
                        if ctx.pos and (ctx.id or ctx.numId) then
                            table.insert(_G.HKDropQueue, {
                                id = ctx.id or ctx.numId,
                                pos = ctx.pos,
                            })
                        end
                    end
                    walk(a)
                end
            end)
        end)
    end
    while true do
        if _G.HK.dropLoot and cd and #_G.HKDropQueue > 0 then
            pcall(function()
                local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local job = table.remove(_G.HKDropQueue, 1)
                    if job then
                        local p = job.pos
                        if typeof(p) == "CFrame" then
                            p = p.Position
                        end
                        if typeof(p) == "Vector3" then
                            hrp.CFrame = CFrame.new(p + Vector3.new(0, 4, 0))
                            hrp.Velocity = Vector3.new()
                            task.wait(0.4)
                        end
                        pcall(function() cd:InvokeServer(job.id) end)
                    end
                end
            end)
        end
        task.wait(0.8)
    end
end)

-- Wave navigator: baca progress wave dari UI (slot Completed/Treasure/
-- kosong/Boss), teleport ke wave tempur yang belum selesai. Dijalankan
-- saat tidak ada target mob. Cache room di-rebuild berkala (streaming!).
_G.HKWaveNav = _G.HKWaveNav == nil and true or _G.HKWaveNav
_G.HKCombatRooms = nil
_G.HKGenName = nil
_G.HKRoomsAt = 0
task.spawn(function()
    while true do
        if _G.HKWaveNav and _G.HKT == nil then
            pcall(function()
                local P2 = game.Players.LocalPlayer
                local hrp = P2.Character and P2.Character:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local gen = getGen()
                    if gen then
                        local now = os.clock()
                        if _G.HKGenName ~= gen.Name or not _G.HKCombatRooms or now - _G.HKRoomsAt > 30 then
                            _G.HKGenName = gen.Name
                            _G.HKRoomsAt = now
                            _G.HKCombatRooms = {}
                            for _, c in ipairs(gen:GetChildren()) do
                                local n = string.match(c.Name, "^Room_(%d+)$")
                                if n and c:IsA("Model") then
                                    local hasSpawn = false
                                    local sp = c:FindFirstChild("Spawns")
                                    if sp then
                                        for _, s in ipairs(sp:GetChildren()) do
                                            if string.find(s.Name, "Enemy") then
                                                hasSpawn = true
                                                break
                                            end
                                        end
                                    end
                                    if hasSpawn then
                                        local ok, piv = pcall(function() return c:GetPivot() end)
                                        if ok then
                                            table.insert(_G.HKCombatRooms, {
                                                n = tonumber(n),
                                                pos = piv.Position,
                                            })
                                        end
                                    end
                                end
                            end
                            table.sort(_G.HKCombatRooms, function(a, b) return a.n < b.n end)
                        end
                        local cp = P2.PlayerGui.Main.HUD.Dungeon_Container
                            :FindFirstChild("Completion_Progress")
                        local list = cp and cp:FindFirstChild("List")
                        if list and _G.HKCombatRooms and #_G.HKCombatRooms > 0 then
                            local slots = {}
                            for _, c in ipairs(list:GetChildren()) do
                                if c:IsA("ImageLabel")
                                    and (c.Name == "Zone" or c.Name == "ZoneSlot") then
                                    table.insert(slots, c)
                                end
                            end
                            for i, s in ipairs(slots) do
                                local done, isBoss = false, false
                                for _, cc in ipairs(s:GetChildren()) do
                                    if cc:IsA("ImageLabel") and cc.Visible then
                                        if cc.Name == "Completed" then
                                            done = true
                                        end
                                        if cc.Name == "Boss" then
                                            isBoss = true
                                        end
                                    end
                                end
                                if not done and not isBoss then
                                    local dest = _G.HKCombatRooms[math.min(i, #_G.HKCombatRooms)]
                                    _G.HKWaveNote = "wave" .. tostring(i) .. "->R" .. tostring(dest.n)
                                    hrp.CFrame = CFrame.new(dest.pos.X, dest.pos.Y + 5, dest.pos.Z)
                                    hrp.Velocity = Vector3.new()
                                    break
                                end
                            end
                        end
                    end
                end
            end)
        end
        task.wait(3)
    end
end)
pcall(function()
    local VU = game:GetService("VirtualUser")
    P.Idled:Connect(function()
        VU:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(1)
        VU:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
end)

-- Start-up: saat AUTO FARM dinyalakan, LANGSUNG ke altar dulu
-- (tanpa syarat apa pun), baru ke gate 1. Dipicu sekali per toggle-ON
-- lewat _G.HK.goAltar.
_G.HK.goAltar = false
task.spawn(function()
    while true do
        if _G.HK.goAltar then
            _G.HK.goAltar = false
            pcall(function()
                local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
                local gen = getGen()
                if hrp and gen then
                    local best, bd, bpr = nil, 1e9, nil
                    for _, d in ipairs(gen:GetDescendants()) do
                        if d:IsA("ProximityPrompt") and d.Enabled
                            and string.find(string.lower(d.ActionText), "bless") then
                            local m = d.Parent
                            while m and not m:IsA("Model") do
                                m = m.Parent
                            end
                            if m then
                                local ok, piv = pcall(function() return m:GetPivot() end)
                                if ok then
                                    local dist = (piv.Position - hrp.Position).Magnitude
                                    if dist < bd then
                                        best, bd, bpr = m, dist, d
                                    end
                                end
                            end
                        end
                    end
                    if best and bpr then
                        local piv = best:GetPivot()
                        hrp.CFrame = CFrame.new(piv.X, piv.Y + 4, piv.Z + 2)
                        hrp.Velocity = Vector3.new()
                        task.wait(0.7)
                        pcall(function() fireproximityprompt(bpr) end)
                        task.wait(1.5)
                    end
                    for _, c in ipairs(gen:GetChildren()) do
                        local n = string.match(c.Name, "^Room_(%d+)$")
                        if n and tonumber(n) == 1 and c:IsA("Model") then
                            local ok, piv = pcall(function() return c:GetPivot() end)
                            if ok then
                                hrp.CFrame = CFrame.new(piv.X, piv.Y + 5, piv.Z)
                                hrp.Velocity = Vector3.new()
                            end
                            break
                        end
                    end
                    _G.HKZone.room = 1
                    _G.HKZone.lastRoom = 1
                end
            end)
        end
        task.wait(0.5)
    end
end)

print("[HK] farm v4 aktif (semua OFF)")


-- Harta Karun Dungeon | Auto Spin + live preview (gacha SummoningService)
-- Aman: hanya memutar ke slot DUMP yang tidak di-lock. Slot 1 & 2 WAJIB
-- locked, kalau tidak loop berhenti sendiri. Dapat Exotic -> kunci + stop.
-- Rate: Normal Exotic 0.05% | Lucky Exotic 0.1% (pity Exotic 500).

-- Harta Karun Dungeon | Auto Spin + live preview (gacha SummoningService)
-- Aman: hanya memutar ke slot DUMP yang tidak di-lock. Slot lain WAJIB
-- locked, kalau tidak loop berhenti sendiri. Dapat target -> kunci + stop.
-- Rate: Normal Exotic 0.05% | Lucky Exotic 0.1% (pity Exotic 500).
-- Dipakai oleh UI-Obsidian (tab Summon) dan overlay HK_Spin.
-- Guard generasi: reload file menaikkan gen, loop lama ikut mati.

_G.HKSpinGen = (_G.HKSpinGen or 0) + 1
local GEN = _G.HKSpinGen

_G.HKSpin = {
    on = false,
    mode = "LuckyFirst", -- "LuckyFirst" | "Lucky" | "Normal"
    delay = 1.2,
    targetRarity = "Exotic", -- berhenti saat rarity >= ini
    targetClass = "",        -- berhenti saat nama class cocok ("" = abaikan)
    dumpSlot = 3,
    log = {},
    counts = {},
    sessionRolls = 0,
}

_G.HKSpinRank = { Rare = 1, Epic = 2, Legendary = 3, Mythic = 4, Celestial = 5, Exotic = 6 }

-- Catatan: tidak ada overlay sendiri. Kontrol lewat tab Summon di UI
-- Obsidian (slot dump, mode, target rarity/class, START/STOP, status).
-- Overlay lama HK_Spin sengaja tidak dibuat lagi.

local RAR = { Rare = "R", Epic = "E", Legendary = "L", Mythic = "M", Celestial = "C", Exotic = "X" }

task.spawn(function()
    local function getRF(s, n)
        local ok, rf = pcall(function()
            return game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
                .knit.Services[s].RF[n]
        end)
        if ok then
            return rf
        end
    end
    local spin, gd, sc, tl = nil, nil, nil, nil
    local function refresh()
        -- Ditampilkan lewat label status di tab Summon (UI Obsidian).
        -- Riwayat lengkap tetap di _G.HKSpin.log.
        if _G.HKLib and not _G.HKLib.Unloaded then
            pcall(function()
                local last = "belum putar"
                if #_G.HKSpin.log > 0 then last = _G.HKSpin.log[#_G.HKSpin.log] end
                _G.HKLib.Options.HKSpinStatus:SetText(
                    "roll:" .. tostring(_G.HKSpin.sessionRolls) .. " | " .. tostring(last))
            end)
        end
    end
    refresh()
    while GEN == _G.HKSpinGen do
        if spin == nil then
            spin = getRF("SummoningService", "Spin")
            gd = getRF("SummoningService", "GetSlotData")
            sc = getRF("SummoningService", "GetSpinCounts")
            tl = getRF("SummoningService", "ToggleSlotLock")
        end
        if _G.HKSpin.on and spin and gd then
            local okAll, err = pcall(function()
                local _, slots = pcall(function() return gd:InvokeServer() end)
                if type(slots) ~= "table" then error("slot?") end
                local ds = _G.HKSpin.dumpSlot
                if slots.Slots[ds] == nil then error("slot " .. tostring(ds) .. " tidak ada") end
                for i in ipairs(slots.Slots) do
                    if i ~= ds and slots.SlotLocks[i] ~= true then
                        error("slot " .. tostring(i) .. " tidak locked!")
                    end
                end
                if slots.SlotLocks[ds] ~= false then
                    error("slot dump sudah locked (dapat bagus?)")
                end
                if slots.ActiveIndex ~= _G.HKSpin.dumpSlot then
                    local sw = getRF("SummoningService", "SwitchSlot")
                    if not sw then error("no switch") end
                    sw:InvokeServer(_G.HKSpin.dumpSlot)
                end
                local _, cnt = pcall(function() return sc:InvokeServer() end)
                local st = _G.HKSpin.mode
                if st == "LuckyFirst" then
                    st = (cnt and cnt.Lucky or 0) > 0 and "Lucky" or "Normal"
                end
                if cnt and (cnt[st] or 0) <= 0 then error(st .. " habis") end
                local res = spin:InvokeServer(st)
                if type(res) ~= "table" then error("spin?") end
                _G.HKSpin.sessionRolls += 1
                local rar = tostring(res.Rarity)
                local cls = tostring(res.ClassName)
                _G.HKSpin.counts[rar] = (_G.HKSpin.counts[rar] or 0) + 1
                table.insert(_G.HKSpin.log,
                    "[" .. (RAR[rar] or "?") .. "] " .. st:sub(1, 1) .. ":"
                    .. rar .. " " .. cls)
                local want = _G.HKSpin.targetClass or ""
                local hitClass = want ~= "" and string.lower(cls) == string.lower(want)
                local hitRar = (_G.HKSpinRank[rar] or 0)
                    >= (_G.HKSpinRank[_G.HKSpin.targetRarity] or 6)
                if hitClass or hitRar then
                    if tl then pcall(function() tl:InvokeServer(ds) end) end
                    table.insert(_G.HKSpin.log,
                        "TARGET: " .. cls .. " (" .. rar .. ") dikunci.")
                    _G.HKSpin.on = false
                end
                refresh()
            end)
            if not okAll then
                table.insert(_G.HKSpin.log, "STOP: " .. tostring(err):sub(1, 60))
                _G.HKSpin.on = false
                refresh()
            end
        end
        task.wait(_G.HKSpin.delay)
    end
end)

print("[HK] spin siap")


-- Harta Karun Dungeon | Full-auto dungeon loop
-- LOBBY -> queue solo -> farm (sistem hover) -> complete (klaim sebisanya)
-- -> replay -> ulangi. Semua panggilan berisiko di-pcall, server mengabaikan
-- yang tidak valid. Default MATI, nyalakan dari tab Misc.
-- _G.HKAuto = { on=false, dungeon="Bandits Den", diff="Normal" }

_G.HKAuto = _G.HKAuto or { on = false, dungeon = "Bandits Den", diff = "Normal" }
_G.HKAuto.replay = false
_G.HKAutoPick = _G.HKAutoPick == nil and true or _G.HKAutoPick

-- Auto replay: habis run selesai (event DungeonComplete), vote replay
-- berulang sampai sesi baru muncul (maks 60 dtk), lalu farm lanjut.
task.spawn(function()
    local svc = game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services
    local function getRF(s, n)
        local ok, rf = pcall(function()
            return svc[s].RF[n]
        end)
        if ok then
            return rf
        end
    end
    local function sessionAlive()
        local rf = getRF("DungeonRunService", "GetSessionInfo")
        if not rf then
            return false
        end
        local ok, s = pcall(function() return rf:InvokeServer() end)
        return ok and type(s) == "table" and s.LocationId ~= nil
    end
    local function doReplay()
        local rf = getRF("DungeonRunService", "RequestReplay")
        if not rf then
            return
        end
        for i = 1, 12 do
            if sessionAlive() then
                break
            end
            pcall(function() rf:InvokeServer() end)
            task.wait(5)
        end
    end
    local ok, re = pcall(function() return svc.DungeonRunService.RE.DungeonComplete end)
    if ok and re then
        pcall(function()
            re.OnClientEvent:Connect(function()
                if _G.HKAuto.replay then
                    task.spawn(doReplay)
                end
            end)
        end)
    end
    _G.HKDoReplay = doReplay
    -- Watcher cadangan: kalau fase non-Combat bertahan 30 dtk (event
    -- complete tidak datang), paksa replay. Reset tiap sesi Combat.
    task.spawn(function()
        local idle = 0
        while true do
            if _G.HKAuto and _G.HKAuto.replay then
                local rf = getRF("DungeonRunService", "GetSessionInfo")
                if rf then
                    local ok, s = pcall(function() return rf:InvokeServer() end)
                    if ok and type(s) == "table" and s.LocationId ~= nil then
                        if tostring(s.Phase) ~= "Combat" then
                            idle += 1
                            if idle >= 3 then
                                pcall(doReplay)
                                idle = -12
                            end
                        else
                            idle = 0
                        end
                    end
                end
            end
            task.wait(10)
        end
    end)
end)

-- Status run (read-only, untuk label): lobby / farming / done.
task.spawn(function()
    local function getRF(s, n)
        local ok, rf = pcall(function()
            return game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
                .knit.Services[s].RF[n]
        end)
        if ok then return rf end
    end
    local sessRF = nil
    while true do
        if sessRF == nil then
            sessRF = getRF("DungeonRunService", "GetSessionInfo")
        end
        if sessRF then
            pcall(function()
                local ok, s = pcall(function() return sessRF:InvokeServer() end)
                if ok and type(s) == "table" and s.LocationId ~= nil then
                    _G.HKAuto.state = tostring(s.Phase) .. " " .. tostring(s.MobsRemaining)
                else
                    _G.HKAuto.state = "lobby"
                end
            end)
        end
        task.wait(10)
    end
end)

print("[HK] auto dungeon siap (mati default)")

-- Auto-TAP UI: menekan tombol popup (berkah/chest/replay) lewat sentuhan
-- virtual. Cara kerja: snapshot rung HUD, saat event datang cari frame
-- BARU yang muncul berisi tombol, tap tombol tengah, verifikasi ketutup.
-- Toggle: _G.HKTap (default true).
_G.HKTap = _G.HKTap == nil and true or _G.HKTap
task.spawn(function()
    local P = game.Players.LocalPlayer
    local VIM = nil
    pcall(function() VIM = game:GetService("VirtualInputManager") end)
    local function tapGui(btn)
        if not (VIM and btn and btn:IsA("GuiObject")) then
            return false
        end
        local ok = pcall(function()
            local c = btn.AbsolutePosition + btn.AbsoluteSize / 2
            local v2 = Vector2.new(c.X, c.Y)
            VIM:SendTouchEvent(0, Enum.UserInputState.Begin, v2, game)
            task.wait(0.08)
            VIM:SendTouchEvent(0, Enum.UserInputState.End, v2, game)
        end)
        return ok
    end
    local function snapshot()
        local s = {}
        pcall(function()
            for _, d in ipairs(P.PlayerGui.Main.HUD:GetDescendants()) do
                if d:IsA("GuiObject") and d.Visible
                    and (d:IsA("TextButton") or d:IsA("ImageButton")) then
                    s[d:GetFullName()] = true
                end
            end
        end)
        return s
    end
    local function findCards()
        local found = {}
        pcall(function()
            for _, d in ipairs(P.PlayerGui.Main.HUD:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible then
                    local fp = d:GetFullName()
                    if not string.find(fp, "HK") then
                        table.insert(found, d)
                    end
                end
            end
        end)
        return found
    end
    _G.HKTapUI = {
        tap = tapGui,
        cards = findCards,
        snap = snapshot,
    }
    local svc = game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services
    -- Boss chest: tap Chest_1, Chest_2, lalu Selesai/Finish.
    local function autoChestButtons()
        local P2 = game.Players.LocalPlayer
        local cs = P2.PlayerGui.Main.HUD:FindFirstChild("Chest_Selection")
        if not (cs and cs.Visible) then
            return false
        end
        for _, n in ipairs({ "Chest_1", "Chest_2" }) do
            local b = cs:FindFirstChild(n)
            if b then
                tapGui(b)
                task.wait(0.8)
            end
        end
        task.wait(1)
        for _, d in ipairs(cs:GetDescendants()) do
            if d:IsA("GuiButton") and d.Visible then
                local t = ""
                if d:IsA("TextButton") then
                    t = tostring(d.Text)
                end
                if string.find(string.lower(t), "selesai")
                    or string.find(string.lower(d.Name), "finish") then
                    tapGui(d)
                    break
                end
            end
        end
        return true
    end
    _G.HKChestTap = autoChestButtons
    -- Replay: tap PUTAR ULANG di layar extracted.
    local function autoReplayTap()
        local P2 = game.Players.LocalPlayer
        for _, d in ipairs(P2.PlayerGui:GetDescendants()) do
            if d:IsA("ImageButton") and d.Visible then
                local has = false
                pcall(function()
                    for _, c in ipairs(d:GetDescendants()) do
                        if c:IsA("TextLabel")
                            and string.find(string.upper(tostring(c.Text)), "PUTAR ULANG") then
                            has = true
                            break
                        end
                    end
                end)
                if has then
                    tapGui(d)
                    return true
                end
            end
        end
        return false
    end
    _G.HKReplayTap = autoReplayTap
    -- Watcher: tiap 2 detik cek popup chest / replay, tap otomatis.
    task.spawn(function()
        while true do
            if _G.HKTap then
                pcall(function()
                    local P2 = game.Players.LocalPlayer
                    local cs = P2.PlayerGui.Main.HUD:FindFirstChild("Chest_Selection")
                    if cs and cs.Visible then
                        autoChestButtons()
                    elseif _G.HKAuto.replay then
                        autoReplayTap()
                    end
                end)
            end
            task.wait(2)
        end
    end)
end)

-- Auto-pick: altar berkah pilih acak, hadiah boss/mid-run ambil semua.
-- Mendengarkan event server -> client (tanpa hook), lalu jawab RF-nya.
task.spawn(function()
    local svc = game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services
    local function rf(sname, fname)
        local ok, r = pcall(function() return svc[sname].RF[fname] end)
        if ok then
            return r
        end
    end
    local function findOptions(t)
        if type(t) ~= "table" then
            return nil
        end
        local n, arr = 0, true
        for k, v in pairs(t) do
            n += 1
            if type(k) ~= "number" or type(v) ~= "table" then
                arr = false
            end
        end
        if arr and n > 0 then
            return t
        end
        for _, v in pairs(t) do
            if type(v) == "table" then
                local r = findOptions(v)
                if r then
                    return r
                end
            end
        end
        return nil
    end
    local function optId(opt)
        for _, k in ipairs({ "Id", "ID", "Index", "Name", "BuffId", "ChestId", "Key" }) do
            if opt[k] ~= nil and type(opt[k]) ~= "table" then
                return opt[k]
            end
        end
        return nil
    end
    local function hookPick(sname, ename, rfName, multi)
        local ok, re = pcall(function() return svc[sname].RE[ename] end)
        if not (ok and re) then
            return
        end
        pcall(function()
            re.OnClientEvent:Connect(function(...)
                local args = { ... }
                _G.HKSnoop = _G.HKSnoop or {}
                if not _G.HKAutoPick then
                    return
                end
                local opts = nil
                for _, a in ipairs(args) do
                    opts = findOptions(a)
                    if opts then
                        break
                    end
                end
                if not opts then
                    return
                end
                local ids = {}
                for _, o in ipairs(opts) do
                    local id = optId(o)
                    if id ~= nil then
                        table.insert(ids, id)
                    end
                end
                if #ids == 0 then
                    return
                end
                task.wait(1)
                local rfn = rf(sname, rfName)
                if rfn then
                    if multi then
                        pcall(function() rfn:InvokeServer(ids) end)
                    else
                        pcall(function() rfn:InvokeServer(ids[math.random(1, #ids)]) end)
                    end
                end
            end)
        end)
    end
    -- Buff altar: saat event BuffSelection datang, cari UI pilihannya,
    -- kumpulkan tombol opsi, coba SelectBuff dengan tiap varian
    -- (id atribut / index / nama) sampai UI ketutup. Semua dicatat.
    _G.HKBuffLog = _G.HKBuffLog or {}
    do
        local ok, re = pcall(function() return svc.DungeonBuffService.RE.BuffSelection end)
        if ok and re then
            pcall(function()
                re.OnClientEvent:Connect(function(...)
                    local args = { ... }
                    table.insert(_G.HKBuffLog, "event datang, nargs=" .. tostring(#args))
                    if not _G.HKAutoPick then
                        return
                    end
                    task.spawn(function()
                        task.wait(1.5)
                        local P = game.Players.LocalPlayer
                        local btns = {}
                        pcall(function()
                            for _, d in ipairs(P.PlayerGui:GetDescendants()) do
                                if (d:IsA("TextButton") or d:IsA("ImageButton"))
                                    and d.Visible then
                                    local fp = d:GetFullName()
                                    if string.find(fp, "Buff") and not string.find(fp, "HK") then
                                        local txt = ""
                                        if d:IsA("TextButton") then
                                            txt = tostring(d.Text)
                                        end
                                        local idv = nil
                                        pcall(function()
                                            for ak, av in pairs(d:GetAttributes()) do
                                                if type(av) ~= "table" and idv == nil then
                                                    idv = av
                                                end
                                            end
                                        end)
                                        table.insert(btns, { b = d, txt = txt, attr = idv })
                                    end
                                end
                            end
                        end)
                        table.insert(_G.HKBuffLog, "tombol buff: " .. tostring(#btns))
                        -- Cara 1 (utama): cari judul PILIH BERKAT, tap kartu tengah.
                        local tapped = false
                        pcall(function()
                            local P2 = game.Players.LocalPlayer
                            for _, d in ipairs(P2.PlayerGui:GetDescendants()) do
                                if d:IsA("TextLabel") and d.Visible
                                    and string.find(string.upper(tostring(d.Text)), "BERKAT") then
                                    local box = d.Parent
                                    while box and box.Parent ~= P2.PlayerGui do
                                        local cards = {}
                                        for _, c in ipairs(box:GetDescendants()) do
                                            if (c:IsA("TextButton") or c:IsA("ImageButton"))
                                                and c.Visible then
                                                table.insert(cards, c)
                                            end
                                        end
                                        if #cards >= 2 then
                                            local mid = cards[math.floor(#cards / 2) + 1]
                                            if _G.HKTapUI then
                                                _G.HKTapUI.tap(mid)
                                            end
                                            tapped = true
                                            break
                                        end
                                        box = box.Parent
                                    end
                                    if tapped then
                                        break
                                    end
                                end
                            end
                        end)
                        task.wait(1.5)
                        local stillOpen = false
                        pcall(function()
                            local P2 = game.Players.LocalPlayer
                            for _, d in ipairs(P2.PlayerGui:GetDescendants()) do
                                if d:IsA("TextLabel") and d.Visible
                                    and string.find(string.upper(tostring(d.Text)), "BERKAT") then
                                    stillOpen = true
                                    break
                                end
                            end
                        end)
                        if tapped and not stillOpen then
                            table.insert(_G.HKBuffLog, "OK via tap kartu")
                            return
                        end
                        if #btns == 0 then
                            return
                        end
                        local rfn = rf("DungeonBuffService", "SelectBuff")
                        if not rfn then
                            return
                        end
                        local order = {}
                        for i = 1, #btns do
                            table.insert(order, i)
                        end
                        for i = #order, 2, -1 do
                            local j = math.random(1, i)
                            order[i], order[j] = order[j], order[i]
                        end
                        for _, oi in ipairs(order) do
                            local o = btns[oi]
                            local tries = {}
                            if o.attr ~= nil then
                                table.insert(tries, o.attr)
                            end
                            table.insert(tries, oi)
                            if o.txt ~= "" then
                                table.insert(tries, o.txt)
                            end
                            for _, v in ipairs(tries) do
                                pcall(function() rfn:InvokeServer(v) end)
                                task.wait(1)
                                local closed = true
                                pcall(function()
                                    for _, d in ipairs(P.PlayerGui:GetDescendants()) do
                                        if (d:IsA("TextButton") or d:IsA("ImageButton"))
                                            and d.Visible then
                                            local fp = d:GetFullName()
                                            if string.find(fp, "Buff") and not string.find(fp, "HK") then
                                                closed = false
                                                break
                                            end
                                        end
                                    end
                                end)
                                if closed then
                                    table.insert(_G.HKBuffLog, "OK pakai " .. tostring(v))
                                    return
                                end
                            end
                        end
                        table.insert(_G.HKBuffLog, "GAGAL semua varian")
                    end)
                end)
            end)
        end
    end
    -- Chest boss/mid-run: JANGAN tebak ID ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â baca jumlah dari UI
    -- ("SELECT N CHESTS") lalu panggil SelectChests({1..N}).
    -- Terbukti live: SelectChests({1,2}) -> true + UI ketutup.
    local function autoChestUI()
        local P = game.Players.LocalPlayer
        for i = 1, 20 do
            local done = false
            pcall(function()
                local cs = P.PlayerGui.Main.HUD:FindFirstChild("Chest_Selection")
                if cs and cs.Visible then
                    local n = 2
                    for _, d in ipairs(cs:GetDescendants()) do
                        if d:IsA("TextLabel") then
                            local c = string.match(tostring(d.Text), "SELECT (%d+)")
                            if c then
                                n = tonumber(c)
                                break
                            end
                        end
                    end
                    local ids = {}
                    for k = 1, n do
                        table.insert(ids, k)
                    end
                    local rf = rfn("DungeonRunService", "SelectChests")
                    if rf then
                        pcall(function() rf:InvokeServer(ids) end)
                    end
                    local rf2 = rfn2("DungeonRunService", "SelectMidRunChests")
                    if rf2 then
                        pcall(function() rf2:InvokeServer(ids) end)
                    end
                    task.wait(1)
                    local cs2 = P.PlayerGui.Main.HUD:FindFirstChild("Chest_Selection")
                    if not cs2 or not cs2.Visible then
                        done = true
                    end
                else
                    done = true
                end
            end)
            if done then
                break
            end
            task.wait(1)
        end
    end
    local function rfn(sname, fname)
        local ok, r = pcall(function()
            return svc[sname].RF[fname]
        end)
        if ok then
            return r
        end
    end
    local function rfn2(sname, fname)
        return rfn(sname, fname)
    end
    task.spawn(function()
        while true do
            if _G.HKAutoPick then
                pcall(function()
                    local cs = game.Players.LocalPlayer.PlayerGui.Main.HUD
                        :FindFirstChild("Chest_Selection")
                    if cs and cs.Visible then
                        autoChestUI()
                    end
                end)
            end
            task.wait(3)
        end
    end)
end)


-- Harta Karun Dungeon | UI Obsidian (mstudio45/deividcomsono fork)
-- Butuh _G.HK dari Farm.lua (jalan dulu) ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â kalau belum ada, dibuatkan default.
-- Buka/tutup menu: RightShift.

pcall(function()
    game.Players.LocalPlayer.PlayerGui:FindFirstChild("HK_UI"):Destroy()
end)
if _G.HKLib then
    pcall(function() _G.HKLib:Unload() end)
    _G.HKLib = nil
end

_G.HK.hover = false
_G.HK.atk = false
_G.HK.skill = false
_G.HK.esp = false
_G.HK.loot = false
_G.HK.chest = false
_G.HK.stealth = false
_G.HK.infjump = false
_G.HK.height = _G.HK.height or 6.5
_G.HK.rate = _G.HK.rate or 0.25
_G.HK.atkRange = _G.HK.atkRange or 15
_G.HK.speed = _G.HK.speed or 32
_G.HK.flyspeed = _G.HK.flyspeed or 60
_G.HK.noclip = false
_G.HK.fly = false

_G.HKSpin = _G.HKSpin or {
    on = false, mode = "LuckyFirst", delay = 1.2,
    targetRarity = "Exotic", targetClass = "", dumpSlot = 3,
    log = {}, counts = {}, sessionRolls = 0,
}
_G.HKSpinRank = _G.HKSpinRank or
    { Rare = 1, Epic = 2, Legendary = 3, Mythic = 4, Celestial = 5, Exotic = 6 }

_G.HKAuto = _G.HKAuto or { on = false, dungeon = "Bandits Den", diff = "Normal" }

local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local lib = loadstring(game:HttpGet(repo .. "Library.lua"))()
_G.HKLib = lib

local Window = lib:CreateWindow({
    Title = "Harta Karun Hub",
    Footer = "dungeon farm",
    NotifySide = "Right",
    ShowCustomCursor = true,
})

-- ===== TAB FARM =====
local FarmTab = Window:AddTab("Farm", "swords")
local FarmL = FarmTab:AddLeftGroupbox("Hover Farm")
FarmL:AddToggle("HKAutoFarm", {
    Text = "AUTO FARM (semua)",
    Default = _G.HK.autoFarm == true,
    Callback = function(v)
        _G.HK.autoFarm = v
        for _, k in ipairs({ "atk", "skill", "esp", "loot", "chest", "stealth", "dropLoot", "autoHeal" }) do
            _G.HK[k] = v
        end
        _G.HK.hx = v
        _G.HK.hover = false
        if v then
            _G.HK.goAltar = true
        end
    end,
})
FarmL:AddToggle("HKHover", {
    Text = "Hover di atas bandit",
    Default = _G.HK.hx == true,
    Callback = function(v)
        _G.HK.hx = v
        _G.HK.hover = false
    end,
})
FarmL:AddSlider("HKHeight", {
    Text = "Tinggi hover",
    Default = math.min(_G.HK.height, 30), Min = 4, Max = 30, Rounding = 1,
    Callback = function(v) _G.HK.height = v end,
})
FarmL:AddToggle("HKChest", {
    Text = "Auto loot chest",
    Default = _G.HK.chest,
    Callback = function(v) _G.HK.chest = v end,
})
FarmL:AddToggle("HKWaveNav", {
    Text = "Navigasi wave belum selesai",
    Default = _G.HKWaveNav ~= false,
    Callback = function(v) _G.HKWaveNav = v end,
})
FarmL:AddButton({
    Text = "Mulai: Altar dulu, baru Gate 1",
    Func = function()
        task.spawn(function()
            pcall(function()
                local P = game.Players.LocalPlayer
                local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
                local gen = nil
                for _, c in ipairs(workspace:GetChildren()) do
                    if string.find(c.Name, "Generated") then
                        gen = c
                        break
                    end
                end
                if gen and hrp then
                    local best, bd, bpr = nil, 1e9, nil
                    for _, d in ipairs(gen:GetDescendants()) do
                        if d:IsA("ProximityPrompt") and d.Enabled
                            and string.find(string.lower(d.ActionText), "bless") then
                            local m = d.Parent
                            while m and not m:IsA("Model") do
                                m = m.Parent
                            end
                            if m then
                                local ok, piv = pcall(function() return m:GetPivot() end)
                                if ok then
                                    local dist = (piv.Position - hrp.Position).Magnitude
                                    if dist < bd then
                                        best, bd, bpr = m, dist, d
                                    end
                                end
                            end
                        end
                    end
                    if best and bpr then
                        local piv = best:GetPivot()
                        hrp.CFrame = CFrame.new(piv.X, piv.Y + 4, piv.Z + 2)
                        hrp.Velocity = Vector3.new()
                        task.wait(0.7)
                        pcall(function() fireproximityprompt(bpr) end)
                        task.wait(1.5)
                    end
                    local r1 = gen:FindFirstChild("Room_1")
                    if r1 and r1:IsA("Model") then
                        local piv = r1:GetPivot()
                        hrp.CFrame = CFrame.new(piv.X, piv.Y + 5, piv.Z)
                        hrp.Velocity = Vector3.new()
                    end
                end
                _G.HKZone.room = 1
                _G.HKZone.lastRoom = 1
                _G.HK.hover = true
                _G.HK.atk = true
            end)
        end)
    end,
})
FarmL:AddToggle("HKDrop", {
    Text = "Auto loot drop monster",
    Default = _G.HK.dropLoot == true,
    Callback = function(v) _G.HK.dropLoot = v end,
})

-- ===== TAB COMBAT =====
local CombatTab = Window:AddTab("Combat", "zap")
local C = CombatTab:AddLeftGroupbox("Auto Serang")
C:AddToggle("HKAtk", {
    Text = "Spam basic attack",
    Default = _G.HK.atk,
    Callback = function(v) _G.HK.atk = v end,
})
C:AddToggle("HKSkill", {
    Text = "Auto skill (tombol 1-4)",
    Default = _G.HK.skill,
    Callback = function(v) _G.HK.skill = v end,
})
C:AddToggle("HKHeal", {
    Text = "Auto heal (tombol 5, HP<40%)",
    Default = _G.HK.autoHeal == true,
    Callback = function(v) _G.HK.autoHeal = v end,
})
C:AddSlider("HKAtkRange", {
    Text = "Jarak serang",
    Default = _G.HK.atkRange or 15, Min = 5, Max = 40, Rounding = 0, Suffix = "st",
    Callback = function(v) _G.HK.atkRange = v end,
})
local C2 = CombatTab:AddLeftGroupbox("Kecepatan")
C2:AddSlider("HKRate", {
    Text = "Jeda attack",
    Default = _G.HK.rate, Min = 0.1, Max = 1, Rounding = 2, Suffix = "s",
    Callback = function(v) _G.HK.rate = v end,
})
local C3 = CombatTab:AddLeftGroupbox("Stealth")
C3:AddToggle("HKStealth", {
    Text = "Serang tanpa animasi",
    Default = _G.HK.stealth,
    Callback = function(v) _G.HK.stealth = v end,
})

-- ===== TAB VISUAL =====
local VisualTab = Window:AddTab("Visual", "eye")
local V = VisualTab:AddLeftGroupbox("ESP dan Loot")
V:AddToggle("HKEsp", {
    Text = "ESP nama + HP mob",
    Default = _G.HK.esp,
    Callback = function(v)
        _G.HK.esp = v
        if not v then
            for _, d in ipairs(workspace:GetDescendants()) do
                if d.Name == "HK_ESP" then
                    pcall(function() d:Destroy() end)
                end
            end
        end
    end,
})
V:AddToggle("HKLoot", {
    Text = "Auto loot chest dekat",
    Default = _G.HK.loot,
    Callback = function(v) _G.HK.loot = v end,
})
V:AddButton({
    Text = "Bersihkan semua ESP",
    Func = function()
        for _, d in ipairs(workspace:GetDescendants()) do
            if d.Name == "HK_ESP" then
                pcall(function() d:Destroy() end)
            end
        end
    end,
})

-- ===== TAB MOVEMENT =====
local MoveTab = Window:AddTab("Movement", "move")
local M = MoveTab:AddLeftGroupbox("Gerak")
M:AddToggle("HKNoclip", {
    Text = "Noclip",
    Default = _G.HK.noclip,
    Callback = function(v) _G.HK.noclip = v end,
})
M:AddToggle("HKInfJump", {
    Text = "Infinite jump",
    Default = _G.HK.infjump,
    Callback = function(v) _G.HK.infjump = v end,
})
M:AddToggle("HKFly", {
    Text = "Fly (WASD + Space/Ctrl)",
    Default = _G.HK.fly,
    Callback = function(v) _G.HK.fly = v end,
})
local M2 = MoveTab:AddRightGroupbox("Kecepatan")
M2:AddSlider("HKSpd", {
    Text = "Walk speed",
    Default = _G.HK.speed, Min = 16, Max = 100, Rounding = 0,
    Callback = function(v) _G.HK.speed = v end,
})
M2:AddSlider("HKFlySpd", {
    Text = "Fly speed",
    Default = _G.HK.flyspeed, Min = 20, Max = 150, Rounding = 0,
    Callback = function(v) _G.HK.flyspeed = v end,
})

-- ===== TAB MISC =====
local MiscTab = Window:AddTab("Misc", "package")
local B = MiscTab:AddLeftGroupbox("Aksi")
B:AddButton({
    Text = "Claim codes + free chest",
    Func = function()
        task.spawn(function()
            for _, c in ipairs({ "TOURNAMENT", "20MVISIT", "JACKAL", "45KLIKE", "SILVERINE", "CC_UPDATE2" }) do
                local ok, rf = pcall(function()
                    return game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
                        .knit.Services.CodesService.RF.RedeemCode
                end)
                if ok and rf then pcall(function() rf:InvokeServer(c) end) end
                task.wait(0.3)
            end
            local ok2, rf2 = pcall(function()
                return game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
                    .knit.Services.ChestService.RF.ClaimFreeChest
            end)
            if ok2 and rf2 then pcall(function() rf2:InvokeServer() end) end
            lib:Notify({ Title = "Claim", Description = "Selesai", Time = 3 })
        end)
    end,
})
B:AddButton({
    Text = "STOP SEMUA",
    Func = function()
        _G.HK.hover = false
        _G.HK.hx = false
        _G.HK.atk = false
        _G.HK.skill = false
        _G.HK.loot = false
        _G.HK.noclip = false
        _G.HK.fly = false
        _G.HKAuto.on = false
        local hum = game.Players.LocalPlayer.Character
            and game.Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum.AutoRotate = true end
        lib:Notify({ Title = "Harta Karun", Description = "Semua fitur dimatikan", Time = 3 })
    end,
})
local A = MiscTab:AddLeftGroupbox("Otomatis")
A:AddToggle("HKAutoReplay", {
    Text = "Auto replay dungeon sama",
    Default = _G.HKAuto.replay ~= false,
    Callback = function(v) _G.HKAuto.replay = v end,
})
A:AddLabel("status auto", true, "HKAutoStatus")
A:AddToggle("HKAutoPick", {
    Text = "Auto pick buff + chest",
    Default = _G.HKAutoPick ~= false,
    Callback = function(v) _G.HKAutoPick = v end,
})
A:AddToggle("HKTapUI", {
    Text = "Auto tap popup (buff/chest/replay)",
    Default = _G.HKTap ~= false,
    Callback = function(v) _G.HKTap = v end,
})

-- ===== TAB SUMMON =====
local SummonTab = Window:AddTab("Summon", "dices")
local S = SummonTab:AddLeftGroupbox("Auto Spin")
S:AddSlider("HKSpinSlot", {
    Text = "Slot tukar (dump)",
    Default = _G.HKSpin.dumpSlot, Min = 1, Max = 6, Rounding = 0,
    Callback = function(v) _G.HKSpin.dumpSlot = v end,
})
S:AddDropdown("HKSpinMode", {
    Text = "Jenis putaran",
    Values = { "LuckyFirst", "Lucky", "Normal" },
    Default = 1,
    Callback = function(v) _G.HKSpin.mode = v end,
})
S:AddDropdown("HKSpinTarget", {
    Text = "Berhenti saat rarity >=", 
    Values = { "Exotic", "Celestial", "Mythic", "Legendary" },
    Default = 1,
    Callback = function(v) _G.HKSpin.targetRarity = v end,
})
S:AddInput("HKSpinClass", {
    Text = "Target class (kosong = semua)",
    Default = "",
    Finished = true,
    Callback = function(v) _G.HKSpin.targetClass = v end,
})
S:AddButton({
    Text = "START spin",
    Func = function() _G.HKSpin.on = true end,
})
S:AddButton({
    Text = "STOP spin",
    Func = function() _G.HKSpin.on = false end,
})
S:AddLabel("status", true, "HKSpinStatus")

-- ===== TAB UI SETTINGS =====
local UITab = Window:AddTab("UI Settings", "settings")
local MG = UITab:AddLeftGroupbox("Menu")
MG:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
    Default = "RightShift",
    NoUI = true,
    Text = "Menu keybind",
})
MG:AddButton("Unload UI", function() lib:Unload() end)
lib.ToggleKeybind = lib.Options.MenuKeybind

-- Watermark status target farm
pcall(function()
    lib:SetWatermarkVisibility(true)
    lib:SetWatermark("farm: ...")
end)
task.spawn(function()
    while not lib.Unloaded do
        pcall(function()
            lib:SetWatermark("farm: " .. tostring(_G.HK and _G.HK.target or "?"))
            local last = "belum putar"
            if _G.HKSpin and #_G.HKSpin.log > 0 then
                last = _G.HKSpin.log[#_G.HKSpin.log]
            end
            lib.Options.HKSpinStatus:SetText(
                "roll:" .. tostring(_G.HKSpin and _G.HKSpin.sessionRolls or 0)
                .. " | " .. tostring(last))
            pcall(function()
                lib.Options.HKAutoStatus:SetText(
                    "auto:" .. tostring(_G.HKAuto and _G.HKAuto.state or "-"))
            end)
        end)
        task.wait(1)
    end
end)

lib:Notify({
    Title = "Harta Karun Hub",
    Description = "Semua tab terpasang. RightShift = buka/tutup.",
    Time = 5,
})
print("[HK] UI Obsidian aktif")

-- PATCH: auto blessing 1/2/3 + auto pick chest 2-dari-3 (habis bunuh boss)
-- Ganti pilihan berkat live via: _G.HKBlessPick = 1 / 2 / 3 (default 1 = kiri)
_G.HKBlessPick = _G.HKBlessPick or 1
task.spawn(function()
    local ok, svc = pcall(function()
        return game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
            .knit.Services.DungeonBuffService
    end)
    if not ok or not svc then return end
    local function pickNow()
        local pick = tonumber(_G.HKBlessPick) or 1
        if pick < 1 or pick > 3 then pick = 1 end
        local id = nil
        pcall(function()
            local opts = _G.HKLastBless and _G.HKLastBless[1]
            if type(opts) == "table" and type(opts[pick]) == "table" and opts[pick].Id then
                id = tostring(opts[pick].Id)
            end
        end)
        if id then pcall(function() svc.RF.SelectBuff:InvokeServer(id) end) end
        pcall(function() svc.RF.SelectBuff:InvokeServer(pick) end)
    end
    pcall(function()
        svc.RE.BuffSelection.OnClientEvent:Connect(function(...)
            _G.HKLastBless = { ... }
            task.wait(0.3)
            pickNow()
        end)
    end)
    -- poller cadangan tiap 2 detik (PlayerGui + CoreGui)
    while true do
        pcall(function()
            local found = false
            for _, root in ipairs({ game.Players.LocalPlayer.PlayerGui, game:GetService("CoreGui") }) do
                for _, d in ipairs(root:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Text == "PILIH BERKAT:" then found = true break end
                end
                if found then break end
            end
            if found then pickNow() end
        end)
        task.wait(2)
    end
end)

-- Auto pick chest 2-dari-3: event + poller judul "Pilih 2 Peti:"
task.spawn(function()
    local drs = nil
    pcall(function()
        drs = game.ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"]
            .knit.Services.DungeonRunService
    end)
    if not drs then return end
    local function claimChests()
        pcall(function() drs.RF.SelectMidRunChests:InvokeServer({ 1, 2 }) end)
        pcall(function() drs.RF.SelectChests:InvokeServer({ 1, 2 }) end)
        pcall(function()
            local cf = game.Players.LocalPlayer.PlayerGui.Main.HUD:FindFirstChild("Chest_Selection")
            if cf then cf.Visible = false end
        end)
    end
    pcall(function()
        drs.RE.MidRunChestSelection.OnClientEvent:Connect(function() task.wait(0.3) claimChests() end)
    end)
    pcall(function()
        drs.RE.ChestSelection.OnClientEvent:Connect(function() task.wait(0.3) claimChests() end)
    end)
    while true do
        pcall(function()
            local found = false
            for _, root in ipairs({ game.Players.LocalPlayer.PlayerGui, game:GetService("CoreGui") }) do
                for _, d in ipairs(root:GetDescendants()) do
                    if d:IsA("TextLabel") and string.find(d.Text, "Pilih 2 Peti") then found = true break end
                end
                if found then break end
            end
            if found then claimChests() end
        end)
        task.wait(2)
    end
end)

print("[HK] patch aktif: auto-blessing + auto-chest")
