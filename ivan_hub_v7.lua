--[[ ====================================================================
     Иван Хаб | Steal an Egg  (v7 — жадный сканер, всё в консоль)
     Вставь в экзекьютор и нажми Execute.
     Интерфейс: «Старт/Стоп» + панель с найденными яйцами. RightShift или
     круглая кнопка «ИХ» — скрыть/показать. Всё остальное — в консоль (F9).

     Куда нести ВСЕГДА (зашито в код):
       Workspace.World.Areas.EggCarryBounds.SafeZone
==================================================================== ]]

local function IvanHubMain()

-- ============================== КОНФИГ ==================================
local Config = {
    Debug = true,             -- печатать [DEBUG] в консоль
    ScanInterval = 2,         -- как часто сканировать карту (сек)
    FarDistance = 100,        -- дальше этого: Noclip + MoveTo (без Pathfinding)
    StealAnyPrompt = false,   -- true: если яиц нет, брать ЛЮБОЙ интерактивный объект (осторожно!)
    Cooldown = 1,             -- пауза между циклами (сек)
}
-- ЖЁСТКО: база, куда несём всё украденное. Выбора зоны больше нет.
local SAFE_PATH = "World.Areas.EggCarryBounds.SafeZone"

local Rarities = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Cosmic", "Divine" }
local RarityRank = {}
for i, r in ipairs(Rarities) do RarityRank[r] = i end
local RarityRU = { Common = "Обычный", Uncommon = "Необычный", Rare = "Редкий", Epic = "Эпический", Legendary = "Легендарный",
    Mythic = "Мифический", Secret = "Секретный", Cosmic = "Космос", Divine = "Божественный" }
local RarityColor = {
    Common = Color3.fromRGB(190, 190, 190), Uncommon = Color3.fromRGB(110, 220, 110), Rare = Color3.fromRGB(90, 160, 255),
    Epic = Color3.fromRGB(190, 110, 255), Legendary = Color3.fromRGB(255, 190, 60), Mythic = Color3.fromRGB(255, 90, 120),
    Secret = Color3.fromRGB(240, 240, 240), Cosmic = Color3.fromRGB(100, 240, 255), Divine = Color3.fromRGB(255, 245, 160),
}
local RarityRUStems = {
    Divine = { "жествен" }, Cosmic = { "осмос" }, Secret = { "екретн" }, Mythic = { "ифич" }, Legendary = { "егендарн" },
    Epic = { "пич" }, Rare = { "едк" }, Uncommon = { "еобычн" }, Common = { "бычн" },
}
local EGG_NAMES = { "nestmodel", "egg", "eggspot" }                 -- имена, по которым признаём «яйцо»
local GENERIC = { world = true, map = true, areas = true, area = true, environment = true }

-- ============================== СЕРВИСЫ / СОСТОЯНИЕ =====================
local env = (getgenv and getgenv()) or _G
for _, k in ipairs({ "IvanHub", "IvanHubV5", "IvanHubV6", "IvanHubV7" }) do      -- выгружаем старые версии
    if env[k] and env[k].Unload then pcall(env[k].Unload) end
end
local IH = { Alive = true, Conns = {} }
env.IvanHubV7 = IH

local cloneref = cloneref or function(x) return x end
local Players = cloneref(game:GetService("Players"))
local RunService = cloneref(game:GetService("RunService"))
local PathfindingService = cloneref(game:GetService("PathfindingService"))
local UIS = cloneref(game:GetService("UserInputService"))
local CoreGui = cloneref(game:GetService("CoreGui"))
local TweenService = cloneref(game:GetService("TweenService"))
local LP = Players.LocalPlayer

local State = { running = false, oneShot = false, gen = 0, cycleNo = 0, farming = false, expectCarry = false,
    blacklist = {}, forced = nil, eggs = {}, scanAt = 0, scanning = false, noclip = false,
    lastCount = -1, lastSummary = "", stats = { eggs = 0, fails = 0 } }
local ui = {}

-- ============================== ОТЛАДКА =================================
local function dbg(msg, ...)
    if not Config.Debug then return end
    local args = table.pack(...)
    local parts = { tostring(msg) }
    for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
    print("[DEBUG] " .. table.concat(parts, " "))
end
local function setStatus(t)
    if ui.status then ui.status.Text = "Статус: " .. tostring(t) end
    dbg("СТАТУС:", t)
end
local function tb(e)
    return tostring(e) .. " | " .. ((debug and debug.traceback) and debug.traceback("", 2) or "")
end

-- ============================== УТИЛИТЫ =================================
local function getChar() return LP.Character end
local function getHum() local c = LP.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function getHRP() local c = LP.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function alive() local h = getHum(); return h ~= nil and h.Health > 0 and getHRP() ~= nil end
local function hdist(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end
local function norm(s) return (tostring(s):lower():gsub("[^%w]", "")) end
local function dig(root, path)
    local n = root
    for seg in tostring(path):gmatch("[^%.]+") do
        if not n then return nil end
        n = n:FindFirstChild(seg)
    end
    return n
end
local function posOf(inst)
    local ok, p = pcall(function()
        if inst:IsA("BasePart") then return inst.Position end
        if inst:IsA("Model") then return inst:GetPivot().Position end
        local sum, n = Vector3.zero, 0
        for _, d in ipairs(inst:GetDescendants()) do
            if d:IsA("BasePart") then sum += d.Position; n += 1 end
        end
        if n > 0 then return sum / n end
    end)
    return ok and p or nil
end
local function boxOf(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.CFrame, inst.Size end
    if inst:IsA("Model") then
        local ok, cf, sz = pcall(function() return inst:GetBoundingBox() end)
        if ok then return cf, sz end
    end
    local minV, maxV, n = Vector3.one * math.huge, Vector3.one * -math.huge, 0
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("BasePart") then
            local p, s = d.Position, d.Size / 2
            minV = Vector3.new(math.min(minV.X, p.X - s.X), math.min(minV.Y, p.Y - s.Y), math.min(minV.Z, p.Z - s.Z))
            maxV = Vector3.new(math.max(maxV.X, p.X + s.X), math.max(maxV.Y, p.Y + s.Y), math.max(maxV.Z, p.Z + s.Z))
            n += 1
        end
    end
    if n == 0 then return nil end
    return CFrame.new((minV + maxV) / 2), maxV - minV
end
local function insideBox(inst, margin)
    local cf, size = boxOf(inst)
    local hrp = getHRP()
    if not cf or not hrp then return false end
    local rel = cf:PointToObjectSpace(hrp.Position)
    margin = margin or 0
    return math.abs(rel.X) <= size.X / 2 + margin and math.abs(rel.Z) <= size.Z / 2 + margin and math.abs(rel.Y) <= size.Y / 2 + 12
end
local function groundAt(x, z, yTop)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LP.Character }
    local r = workspace:Raycast(Vector3.new(x, yTop + 60, z), Vector3.new(0, -500, 0), params)
    return r and (r.Position.Y + 3) or (yTop + 3)
end
local SUF = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, Q = 1e15 }
local function parseNum(v, suffix)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return nil end
    local s = v:gsub("[%$,%s]", "")
    local num, suf = s:match("^([%d%.]+)(%a*)$")
    local n = tonumber(num)
    if not n then return nil end
    suf = ((suffix and suffix ~= "") and suffix or suf or ""):upper()
    return n * (SUF[suf] or 1)
end
local function fmtNum(n)
    if not n then return "Неизвестно" end
    for _, u in ipairs({ { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= u[1] then return ("%.2f%s"):format(n / u[1], u[2]) end
    end
    return tostring(math.floor(n))
end
local function connect(sig, fn)
    local c = sig:Connect(function(...)
        local ok, e = xpcall(fn, tb, ...)
        if not ok then dbg("ОШИБКА в обработчике:", e) end
    end)
    IH.Conns[#IH.Conns + 1] = c
    return c
end

-- ============================== ДАННЫЕ ЯЙЦА =============================
local function hasAny(text, list)
    for _, s in ipairs(list) do if text:find(s, 1, true) then return true end end
    return false
end

-- Вес / доход / редкость из BillboardGui.TextLabel, ObjectText и ActionText. Нет данных → «Неизвестно».
local function parseEggData(owner, prompt)
    local texts = {}
    for _, x in ipairs(owner:GetDescendants()) do
        if x:IsA("TextLabel") and x.Text ~= "" and (x:FindFirstAncestorWhichIsA("BillboardGui") or x:FindFirstAncestorWhichIsA("SurfaceGui")) then
            texts[#texts + 1] = x.Text
        end
    end
    if prompt then
        if prompt.ObjectText ~= "" then texts[#texts + 1] = prompt.ObjectText end
        if prompt.ActionText ~= "" then texts[#texts + 1] = prompt.ActionText end
    end
    local raw = table.concat(texts, " | "):gsub("<[^>]+>", "")
    local low = raw:lower()
    local d = { text = raw, name = owner.Name }
    if texts[1] then
        local first = texts[1]:gsub("<[^>]+>", ""):sub(1, 28)
        if first ~= "" then d.name = first end
    end
    local w = raw:match("([%d%.,]+)%s*%a?%s*[kK][gG]")
    if w then d.weight = tonumber((w:gsub(",", ""))) end
    local clean = raw:gsub("%$", "")
    local inc, suf = clean:match("([%d%.,]+)%s*([KkMmBbTtQq]?)%s*/%s*[sS]")
    if inc then d.income = parseNum((inc:gsub(",", "")), suf) end
    for i = #Rarities, 1, -1 do
        local r = Rarities[i]
        if low:find(r:lower(), 1, true) then d.rarity = r; break end
        local stems = RarityRUStems[r]
        if stems and hasAny(raw, stems) then d.rarity = r; break end
    end
    local attrRarity = owner:GetAttribute("Rarity")
    if not d.rarity and attrRarity then d.rarity = tostring(attrRarity) end
    return d
end

-- ============================== АГРЕССИВНЫЙ СКАНЕР ======================
local function eggName(n)
    n = tostring(n):lower()
    for _, p in ipairs(EGG_NAMES) do if n:find(p, 1, true) then return true end end
    return false
end
local function chainEgg(inst)
    local cur = inst
    for _ = 1, 5 do
        if not cur or cur == workspace then break end
        if eggName(cur.Name) then return true end
        cur = cur.Parent
    end
    return false
end
local function stealText(prompt)
    local t = (prompt.ActionText or "") .. " " .. (prompt.ObjectText or "")
    local l = t:lower()
    return l:find("steal", 1, true) ~= nil or l:find("grab", 1, true) ~= nil or t:find("расть", 1, true) ~= nil
end
local function inOtherChar(d)
    local cur = d.Parent
    for _ = 1, 6 do
        if not cur or cur == workspace then return false end
        if cur:IsA("Model") and Players:GetPlayerFromCharacter(cur) then return true end
        cur = cur.Parent
    end
    return false
end
-- «Владелец» интерактивного объекта: модель-яйцо (а не вся карта)
local function ownerOf(d)
    local best
    local cur = d.Parent
    for _ = 1, 4 do
        if not cur or cur == workspace then break end
        if cur:IsA("Model") and not GENERIC[norm(cur.Name)] then
            best = best or cur
            if eggName(cur.Name) then best = cur end
        end
        cur = cur.Parent
    end
    return best or d.Parent or d
end

local function scan()
    if State.scanning then return end
    State.scanning = true
    print("[DEBUG] Сканирую карту на яйца...")
    local t0 = os.clock()
    local byOwner, found = {}, {}
    local char = LP.Character
    local all = workspace:GetDescendants()
    for i = 1, #all do
        local d = all[i]
        if i % 4000 == 0 then task.wait() end                       -- не вешаем кадр
        local isPrompt = d:IsA("ProximityPrompt")
        local isClick = d:IsA("ClickDetector")
        local isNamed = (not isPrompt and not isClick) and (d:IsA("Model") or d:IsA("BasePart")) and eggName(d.Name)
        if isPrompt or isClick or isNamed then
            if not (char and d:IsDescendantOf(char)) and not inOtherChar(d) and not (isPrompt and not d.Enabled) then
                local owner = ownerOf(d)
                local e = byOwner[owner]
                if not e then
                    e = { owner = owner, key = owner }
                    byOwner[owner] = e
                    found[#found + 1] = e
                end
                if isPrompt then
                    if not e.prompt or stealText(d) then e.prompt = d end
                    if stealText(d) then e.stealText = true end
                end
                if isClick and not e.click then e.click = d end
                if isNamed then e.named = true end
            end
        end
    end
    -- классификация и данные
    local hrp = getHRP()
    local eggs, others = {}, {}
    for _, e in ipairs(found) do
        e.named = e.named or chainEgg(e.owner)
        if (e.prompt or e.click) and (e.named or e.stealText) then e.kind = "prompt"
        elseif e.named then e.kind = "name"
        else e.kind = "other" end
        local anchor = (e.prompt and e.prompt.Parent) or (e.click and e.click.Parent) or e.owner
        e.pos = posOf(anchor) or posOf(e.owner)
        e.part = e.owner:IsA("BasePart") and e.owner or e.owner:FindFirstChildWhichIsA("BasePart", true)
        e.dist = (hrp and e.pos) and (e.pos - hrp.Position).Magnitude or math.huge
        if e.pos then
            if e.kind == "other" then others[#others + 1] = e else eggs[#eggs + 1] = e end
        end
    end
    table.sort(others, function(a, b) return a.dist < b.dist end)
    for i = 1, math.min(15, #others) do eggs[#eggs + 1] = others[i] end   -- только 15 ближайших «прочих» объектов
    for _, e in ipairs(eggs) do e.data = parseEggData(e.owner, e.prompt) end

    State.eggs, State.scanAt = eggs, os.clock()
    local kinds = { prompt = 0, name = 0, other = 0 }
    for _, e in ipairs(eggs) do kinds[e.kind] += 1 end
    print("[DEBUG] Найдено потенциальных яиц:", #eggs)
    if #eggs == 0 then print("[DEBUG] Яиц нет! Ждем респавна.") end
    local summary = ("prompt=%d name=%d other=%d"):format(kinds.prompt, kinds.name, kinds.other)
    if #eggs ~= State.lastCount or summary ~= State.lastSummary then
        dbg(("Скан: %s | всего объектов в мире: %d | занял %.2f c"):format(summary, #all, os.clock() - t0))
        for i, e in ipairs(eggs) do
            if i > 10 then break end
            dbg(("  [%s] %s | prompt: %s | enabled: %s | click: %s | текст: %s"):format(e.kind, e.owner:GetFullName():gsub("^Workspace%.", ""),
                e.prompt and (e.prompt.ActionText .. "/" .. e.prompt.ObjectText) or "нет", e.prompt and tostring(e.prompt.Enabled) or "-",
                e.click and "да" or "нет", e.data.text ~= "" and e.data.text:sub(1, 70) or "—"))
        end
        State.lastCount, State.lastSummary = #eggs, summary
    end
    State.scanning = false
    return eggs
end

-- ============================== ДВИЖЕНИЕ ================================
-- MoveTo + MoveToFinished; застрял (скорость < 2 за 1.5 c) → прыжок, затем обход вбок
local function stepTo(target, timeout, cond, early, reach)
    reach = reach or 3.5
    local hum, hrp = getHum(), getHRP()
    if not hum or not hrp then return "dead" end
    hum:MoveTo(target)
    local finished, reachedFlag = false, false
    local conn = hum.MoveToFinished:Connect(function(r) finished = true; reachedFlag = r end)
    local t0, samples, stage = os.clock(), {}, 0
    local result = "timeout"
    while os.clock() - t0 < timeout and cond() do
        task.wait(0.1)
        hrp = getHRP()
        if not hrp or not alive() then result = "dead"; break end
        if hdist(hrp.Position, target) <= reach then result = "reached"; break end
        if early and early() then result = "reached"; break end
        if finished then
            result = reachedFlag and "reached" or "stuck"
            if not reachedFlag then dbg("MoveToFinished(false) — цель не достигнута") end
            break
        end
        samples[#samples + 1] = { os.clock(), hrp.Position }
        while #samples > 1 and os.clock() - samples[1][1] > 1.7 do table.remove(samples, 1) end
        local first = samples[1]
        local dt = os.clock() - first[1]
        if dt >= 1.5 then
            local spd = hdist(hrp.Position, first[2]) / dt
            if spd < 2 then
                stage += 1
                samples = {}
                if stage == 1 then
                    dbg(("Застрял (скорость %.1f < 2 за 1.5 c) → прыжок"):format(spd))
                    hum.Jump = true
                else
                    dbg("Всё ещё стоит → обход вбок")
                    hum:MoveTo(hrp.Position + hrp.CFrame.RightVector * ((stage % 2 == 0) and 6 or -6))
                    task.wait(0.7)
                    hum.Jump = true
                    hum:MoveTo(target)
                    if stage >= 4 then result = "stuck"; break end
                end
            else
                stage = 0
            end
        end
    end
    conn:Disconnect()
    if not cond() then return "abort" end
    return result
end

local function followPath(target, cond, early, reach)
    local hrp = getHRP()
    local path = PathfindingService:CreatePath({ AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true, WaypointSpacing = 6 })
    local ok, err = pcall(function() path:ComputeAsync(hrp.Position, target) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then
        dbg("Pathfinding: путь не построен, статус =", ok and tostring(path.Status) or tostring(err))
        return "nopath"
    end
    local wps = path:GetWaypoints()
    dbg("Pathfinding: точек в пути =", #wps)
    for i = 2, #wps do
        if not cond() then return "abort" end
        if early and early() then return "reached" end
        if wps[i].Action == Enum.PathWaypointAction.Jump then local h = getHum(); if h then h.Jump = true end end
        local r = stepTo(wps[i].Position, 6, cond, early, i == #wps and reach or 3.5)
        if r == "stuck" then dbg("Застрял на точке", i, "из", #wps, "→ пересчёт пути"); return "stuck" end
        if r == "dead" or r == "abort" then return r end
    end
    return "reached"
end

-- Ходьба: близко → Pathfinding + MoveTo; далеко (>FarDistance) → Noclip + MoveTo напрямик
local function walkTo(target, stop, cond, early)
    stop = stop or 4
    local reach = math.min(3.5, math.max(1.0, stop - 0.5))
    local t0 = os.clock()
    while cond() and os.clock() - t0 < 300 do
        local hrp = getHRP()
        if not hrp or not alive() then dbg("Персонаж мёртв/недоступен"); State.noclip = false; return false end
        local dist = hdist(hrp.Position, target)
        if dist <= stop or (early and early()) then
            dbg(("Дошёл (осталось %.0f studs)"):format(dist)); State.noclip = false; return true
        end
        local r
        if dist > Config.FarDistance then
            dbg(("До цели %.0f studs (>%d) → NOCLIP + MoveTo"):format(dist, Config.FarDistance))
            State.noclip = true
            r = stepTo(target, 10, cond, early, reach)
        else
            State.noclip = false
            dbg(("До цели %.0f studs → Pathfinding + MoveTo"):format(dist))
            r = followPath(target, cond, early, reach)
            if r == "nopath" then r = stepTo(target, 8, cond, early, reach) end
        end
        if r == "abort" or r == "dead" then State.noclip = false; return false end
    end
    State.noclip = false
    return false
end

-- ============================== КРАЖА ===================================
local function isCarrying()
    local c = getChar()
    if not c then return false end
    for _, k in ipairs({ "Carrying", "CarryingEgg", "HasEgg", "IsCarrying" }) do
        if LP:GetAttribute(k) or c:GetAttribute(k) then return true end
    end
    for _, d in ipairs(c:GetDescendants()) do
        if d.Name:lower():find("egg") then return true end
    end
    return false
end

local function stolen(e)
    if isCarrying() then return true end
    if e.prompt and (not e.prompt.Parent or not e.prompt.Enabled) then return true end
    if not e.owner.Parent then return true end
    return false
end

local function steal(e, cond)
    dbg("КРАЖА:", e.owner:GetFullName(), "| prompt =", e.prompt and "да" or "нет", "| click =", e.click and "да" or "нет",
        "| часть для touch =", e.part and e.part.Name or "нет")
    for attempt = 1, 2 do
        if not cond() or not alive() then return false end
        if e.prompt and e.prompt.Parent then
            local pp = e.prompt.Parent and posOf(e.prompt.Parent)
            local hrp = getHRP()
            if pp and hrp then
                local d = (hrp.Position - pp).Magnitude
                local maxd = e.prompt.MaxActivationDistance or 10
                dbg(("Расстояние до prompt %.1f, активация до %.1f"):format(d, maxd))
                if d > maxd - 1.5 then
                    dbg("Далеко от prompt — подхожу ближе")
                    walkTo(pp, math.max(2, maxd - 3), cond)
                end
            end
            pcall(function() e.prompt.HoldDuration = 0; e.prompt.RequiresLineOfSight = false end)
            if fireproximityprompt then
                dbg("Вызываю fireproximityprompt, попытка", attempt)
                local ok, err = pcall(fireproximityprompt, e.prompt)
                dbg("fireproximityprompt результат:", ok, err)
            else
                dbg("fireproximityprompt недоступен → InputHoldBegin/End")
                pcall(function() e.prompt:InputHoldBegin(); task.wait(0.2); e.prompt:InputHoldEnd() end)
            end
        elseif e.click and fireclickdetector then
            dbg("Нет prompt → fireclickdetector, попытка", attempt)
            local ok, err = pcall(fireclickdetector, e.click)
            dbg("fireclickdetector результат:", ok, err)
        elseif e.part and firetouchinterest and getHRP() then
            dbg("Нет prompt/click → firetouchinterest, попытка", attempt)
            pcall(function() firetouchinterest(getHRP(), e.part, 0); task.wait(0.1); firetouchinterest(getHRP(), e.part, 1) end)
        else
            dbg("НЕТ СПОСОБА ЗАБРАТЬ: нет prompt/click и нет firetouchinterest")
            return false
        end
        for _ = 1, 15 do                                       -- ждём до 1.5 c, пока яйцо окажется «в руках»
            task.wait(0.1)
            if stolen(e) then
                dbg("ЯЙЦО В РУКАХ ✔ | несу =", isCarrying(), "| prompt выключился =", e.prompt and not e.prompt.Enabled or false)
                return true
            end
        end
        dbg("Яйцо не взялось, попытка", attempt)
    end
    return false
end

local function findSafeZone()
    local z = dig(workspace, SAFE_PATH)
    if z then return z end
    dbg("SafeZone по пути не найдена:", "Workspace." .. SAFE_PATH, "→ ищу по имени SafeZone")
    for _, d in ipairs(workspace:GetDescendants()) do
        if d.Name == "SafeZone" and (d:IsA("BasePart") or d:IsA("Model")) and not d:IsDescendantOf(workspace:FindFirstChild("HalloweenDimension") or Instance.new("Folder")) then
            dbg("Нашёл запасную SafeZone:", d:GetFullName())
            return d
        end
    end
    return nil
end

local function deliver(cond)
    local zone = findSafeZone()
    if not zone then dbg("БАЗА НЕ НАЙДЕНА — нести некуда"); return false end
    local cf, size = boxOf(zone)
    if not cf then dbg("Не удалось получить размеры SafeZone"); return false end
    local top = cf.Position.Y + size.Y / 2
    local target = Vector3.new(cf.Position.X, groundAt(cf.Position.X, cf.Position.Z, top), cf.Position.Z)
    dbg("Иду на SafeZone:", zone:GetFullName(), "| центр:", math.floor(target.X) .. ", " .. math.floor(target.Z))
    local ok = walkTo(target, 6, cond, function() return insideBox(zone, -2) end)
    dbg("Доставка:", ok and "в SafeZone" or "не дошёл", "| несу яйцо =", isCarrying())
    task.wait(0.6)
    return ok
end

-- Ближайшее яйцо: сначала с prompt/click, потом «по имени», потом (если разрешено) любые объекты
local function pickNearest()
    local hrp = getHRP()
    local order = { "prompt", "name" }
    if Config.StealAnyPrompt then order[#order + 1] = "other" end
    for _, kind in ipairs(order) do
        local best, bd
        for _, e in ipairs(State.eggs) do
            local bl = State.blacklist[e.owner]
            if e.kind == kind and e.owner.Parent and e.pos and not (bl and tick() < bl) and (not e.prompt or e.prompt.Enabled) then
                local d = hrp and (e.pos - hrp.Position).Magnitude or 0
                if not bd or d < bd then best, bd = e, d end
            end
        end
        if best then return best, kind end
    end
    return nil
end

local function cycle(my)
    State.cycleNo += 1
    print("[DEBUG] ===== Цикл " .. State.cycleNo .. " =====")
    local function cond() return IH.Alive and State.gen == my and (State.running or State.oneShot) end
    if not alive() then setStatus("жду персонажа"); task.wait(1); return end

    -- яйцо уже в руках → сразу на базу
    if State.expectCarry and isCarrying() then
        setStatus("яйцо в руках → бегу на SafeZone")
        State.farming = true
        if deliver(cond) then State.stats.eggs += 1; setStatus("сдано! всего: " .. State.stats.eggs) end
        State.expectCarry = false; State.farming = false
        return
    end
    State.expectCarry = false

    if os.clock() - State.scanAt > Config.ScanInterval * 2.5 then scan() end      -- список устарел → скан прямо сейчас
    local e, kind = State.forced, nil
    State.forced = nil
    if e and e.owner.Parent and e.pos then
        kind = e.kind
        dbg("Цель выбрана вручную:", e.data.name)
    else
        e, kind = pickNearest()
    end
    if not e then
        print("[DEBUG] Яиц нет! Ждем респавна.")
        setStatus("яиц нет, жду")
        task.wait(2)
        return
    end
    local d = e.data
    dbg("Выбрано ближайшее [" .. tostring(kind) .. "]:", e.owner:GetFullName(), "| имя:", d.name, "| вес:", fmtNum(d.weight),
        "| доход:", fmtNum(d.income), "| редкость:", d.rarity or "Неизвестно")

    State.farming = true
    setStatus("иду к яйцу")
    print("[DEBUG] Иду к яйцу: ", e.owner.Name)
    local arrived = walkTo(e.pos, 4, cond)
    if not cond() then State.farming = false; return end
    if not arrived then
        dbg("НЕ ДОШЁЛ до яйца → пропускаю на 30 сек")
        State.blacklist[e.owner] = tick() + 30
        State.stats.fails += 1; State.farming = false
        return
    end

    setStatus("краду")
    if not steal(e, cond) then
        dbg("КРАЖА НЕ УДАЛАСЬ → пропускаю на 30 сек")
        State.blacklist[e.owner] = tick() + 30
        State.stats.fails += 1; State.farming = false
        return
    end
    State.expectCarry = true

    setStatus("несу на SafeZone")
    if deliver(cond) then
        State.stats.eggs += 1
        setStatus("сдано! всего: " .. State.stats.eggs)
    else
        State.stats.fails += 1
        setStatus("не удалось донести")
    end
    State.expectCarry = false
    State.farming = false
end

local function startFarm(once)
    State.gen += 1
    local my = State.gen
    if once then State.oneShot = true else State.running = true end
    dbg("СТАРТ", once and "(одно яйцо)" or "автокражи")
    task.spawn(function()
        while IH.Alive and State.gen == my and (State.running or State.oneShot) do
            local ok, err = xpcall(cycle, tb, my)
            State.farming = false
            if not ok then dbg("ОШИБКА В ЦИКЛЕ:", err); task.wait(1) end
            if State.oneShot and not State.running then State.oneShot = false; break end
            task.wait(Config.Cooldown)
        end
        State.farming = false
        State.noclip = false
    end)
end
local function stopFarm()
    State.running = false; State.oneShot = false; State.gen += 1; State.farming = false; State.noclip = false
    dbg("СТОП автокражи")
    local hum, hrp = getHum(), getHRP()
    if hum and hrp then hum:MoveTo(hrp.Position) end
end

-- ============================== ИНТЕРФЕЙС ===============================
local rows = {}
local function updatePanel()
    if not ui.list then return end
    local hrp = getHRP()
    local eggs = {}
    for _, e in ipairs(State.eggs) do eggs[#eggs + 1] = e end
    local kindRank = { prompt = 1, name = 2, other = 3 }
    table.sort(eggs, function(a, b)
        if a.kind ~= b.kind then return kindRank[a.kind] < kindRank[b.kind] end
        local ra, rb = RarityRank[a.data.rarity or ""] or 0, RarityRank[b.data.rarity or ""] or 0
        if ra ~= rb then return ra > rb end
        local ia, ib = a.data.income or 0, b.data.income or 0
        if ia ~= ib then return ia > ib end
        return a.owner:GetFullName() < b.owner:GetFullName()
    end)
    ui.count.Text = ("Найдено объектов: %d"):format(#eggs)
    local seen = {}
    for i, e in ipairs(eggs) do
        if i > 60 then break end
        seen[e.owner] = true
        local r = rows[e.owner]
        if not r then
            local f = Instance.new("Frame")
            f.Size = UDim2.new(1, -6, 0, 64); f.BackgroundColor3 = Color3.fromRGB(30, 22, 52); f.BorderSizePixel = 0; f.Parent = ui.list
            local cr = Instance.new("UICorner"); cr.CornerRadius = UDim.new(0, 8); cr.Parent = f
            local function lbl(size, pos, font, ts, xa)
                local l = Instance.new("TextLabel")
                l.BackgroundTransparency = 1; l.Size = size; l.Position = pos; l.Font = font; l.TextSize = ts
                l.TextXAlignment = xa or Enum.TextXAlignment.Left; l.TextColor3 = Color3.fromRGB(240, 235, 252); l.Parent = f
                return l
            end
            local nm = lbl(UDim2.new(1, -118, 0, 18), UDim2.fromOffset(8, 4), Enum.Font.GothamBold, 13)
            nm.TextTruncate = Enum.TextTruncate.AtEnd
            local rr = lbl(UDim2.fromOffset(110, 18), UDim2.new(1, -114, 0, 4), Enum.Font.GothamBold, 12, Enum.TextXAlignment.Right)
            local inf = lbl(UDim2.new(1, -16, 0, 16), UDim2.fromOffset(8, 24), Enum.Font.Gotham, 12)
            inf.TextColor3 = Color3.fromRGB(195, 190, 220)
            local sub = lbl(UDim2.new(1, -96, 0, 14), UDim2.fromOffset(8, 44), Enum.Font.Gotham, 11)
            sub.TextColor3 = Color3.fromRGB(150, 145, 180)
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.fromOffset(78, 22); btn.Position = UDim2.new(1, -84, 1, -28); btn.BackgroundColor3 = Color3.fromRGB(50, 170, 90)
            btn.Text = "Красть"; btn.Font = Enum.Font.GothamBold; btn.TextSize = 12; btn.TextColor3 = Color3.new(1, 1, 1); btn.Parent = f
            local c2 = Instance.new("UICorner"); c2.CornerRadius = UDim.new(0, 6); c2.Parent = btn
            r = { frame = f, nm = nm, rr = rr, inf = inf, sub = sub, btn = btn, cur = e }
            btn.MouseButton1Click:Connect(function()
                State.forced = r.cur
                dbg("ПАНЕЛЬ: «Красть» →", r.cur.data.name)
                if not State.running then startFarm(true) end
            end)
            rows[e.owner] = r
        end
        r.cur = e
        local d = e.data
        local rar = d.rarity
        r.frame.LayoutOrder = i
        r.nm.Text = d.name
        r.rr.Text = rar and (RarityRU[rar] or rar) or "Неизвестно"
        r.rr.TextColor3 = rar and RarityColor[rar] or Color3.fromRGB(170, 170, 190)
        r.inf.Text = ("Вес: %s kg   Доход: $%s/s"):format(fmtNum(d.weight), fmtNum(d.income))
        local kindText = e.kind == "prompt" and "Яйцо (prompt)" or (e.kind == "name" and "Гнездо/по имени" or "Объект")
        r.sub.Text = ("%s · %d studs"):format(kindText, hrp and math.floor((e.pos - hrp.Position).Magnitude) or 0)
    end
    for k, r in pairs(rows) do
        if not seen[k] then r.frame:Destroy(); rows[k] = nil end
    end
end

local function buildGui()
    local gui = Instance.new("ScreenGui")
    gui.Name = "IvanHubV7"; gui.ResetOnSpawn = false; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 999
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
    local okp = pcall(function() gui.Parent = (gethui and gethui()) or CoreGui end)
    if not okp or not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end
    ui.gui = gui

    local BG, ACC, ACC2 = Color3.fromRGB(14, 10, 26), Color3.fromRGB(138, 92, 255), Color3.fromRGB(255, 140, 40)
    local GREEN, RED = Color3.fromRGB(50, 170, 90), Color3.fromRGB(190, 60, 60)
    local function corner(i, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = i end
    local function stroke(i, col) local s = Instance.new("UIStroke"); s.Color = col; s.Thickness = 1.4; s.Transparency = 0.35; s.Parent = i end
    local function grad(i, c1, c2) local g = Instance.new("UIGradient"); g.Color = ColorSequence.new(c1, c2); g.Parent = i end
    local function tw(i, t, p) TweenService:Create(i, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), p):Play() end

    local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
    local root = Instance.new("Frame")
    root.Size = UDim2.fromOffset(340, 470); root.Position = UDim2.new(1, -360, 0.5, -235); root.BackgroundColor3 = BG
    root.BorderSizePixel = 0; root.Parent = gui; corner(root, 12); stroke(root, ACC2)
    local sc = Instance.new("UIScale"); sc.Scale = math.min(1, (vp.X - 16) / 360, (vp.Y - 16) / 490); sc.Parent = root

    local head = Instance.new("TextButton")
    head.Size = UDim2.new(1, 0, 0, 38); head.Text = ""; head.AutoButtonColor = false; head.BorderSizePixel = 0
    head.BackgroundColor3 = Color3.new(1, 1, 1); head.Parent = root; corner(head, 12); grad(head, ACC2, Color3.fromRGB(255, 90, 40))
    local ttl = Instance.new("TextLabel")
    ttl.BackgroundTransparency = 1; ttl.Size = UDim2.new(1, -16, 1, 0); ttl.Position = UDim2.fromOffset(12, 0); ttl.Text = "⚙  Панель кражи"
    ttl.Font = Enum.Font.GothamBold; ttl.TextSize = 16; ttl.TextColor3 = Color3.new(1, 1, 1); ttl.TextXAlignment = Enum.TextXAlignment.Left; ttl.Parent = head

    -- Старт / Стоп
    local startBtn = Instance.new("TextButton")
    startBtn.Size = UDim2.new(1, -16, 0, 36); startBtn.Position = UDim2.fromOffset(8, 46); startBtn.Font = Enum.Font.GothamBold
    startBtn.TextSize = 15; startBtn.TextColor3 = Color3.new(1, 1, 1); startBtn.Parent = root; corner(startBtn, 8)
    local function refreshBtn()
        startBtn.Text = State.running and "■  СТОП" or "▶  СТАРТ"
        tw(startBtn, 0.15, { BackgroundColor3 = State.running and RED or GREEN })
    end
    startBtn.MouseButton1Click:Connect(function()
        if State.running then stopFarm() else startFarm(false) end
        refreshBtn()
    end)
    refreshBtn()
    ui.refreshBtn = refreshBtn

    ui.status = Instance.new("TextLabel")
    ui.status.BackgroundTransparency = 1; ui.status.Size = UDim2.new(1, -16, 0, 18); ui.status.Position = UDim2.fromOffset(10, 88)
    ui.status.Font = Enum.Font.GothamMedium; ui.status.TextSize = 12; ui.status.TextXAlignment = Enum.TextXAlignment.Left
    ui.status.TextColor3 = Color3.fromRGB(235, 230, 250); ui.status.Text = "Статус: сканирую карту..."; ui.status.TextTruncate = Enum.TextTruncate.AtEnd; ui.status.Parent = root
    ui.count = Instance.new("TextLabel")
    ui.count.BackgroundTransparency = 1; ui.count.Size = UDim2.new(1, -16, 0, 16); ui.count.Position = UDim2.fromOffset(10, 106)
    ui.count.Font = Enum.Font.Gotham; ui.count.TextSize = 12; ui.count.TextXAlignment = Enum.TextXAlignment.Left
    ui.count.TextColor3 = Color3.fromRGB(170, 165, 200); ui.count.Text = "Найдено объектов: 0"; ui.count.Parent = root

    ui.list = Instance.new("ScrollingFrame")
    ui.list.Size = UDim2.new(1, -12, 1, -132); ui.list.Position = UDim2.fromOffset(6, 126); ui.list.BackgroundTransparency = 1
    ui.list.BorderSizePixel = 0; ui.list.ScrollBarThickness = 3; ui.list.AutomaticCanvasSize = Enum.AutomaticSize.Y; ui.list.CanvasSize = UDim2.new()
    ui.list.Parent = root
    do local l = Instance.new("UIListLayout"); l.Padding = UDim.new(0, 5); l.SortOrder = Enum.SortOrder.LayoutOrder; l.Parent = ui.list end

    -- перетаскивание за шапку
    do
        local dragging, ds, sp
        head.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging, ds, sp = true, i.Position, root.Position
                i.Changed:Connect(function() if i.UserInputState == Enum.UserInputState.End then dragging = false end end)
            end
        end)
        connect(UIS.InputChanged, function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - ds
                root.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
            end
        end)
    end

    -- показ/скрытие: RightShift и круглая перетаскиваемая кнопка
    local function toggleMenu() root.Visible = not root.Visible end
    connect(UIS.InputBegan, function(i, gp)
        if not gp and i.KeyCode == Enum.KeyCode.RightShift then toggleMenu() end
    end)
    local orb = Instance.new("TextButton")
    orb.Size = UDim2.fromOffset(48, 48); orb.Position = UDim2.new(0, 14, 0.5, -24); orb.Text = "ИХ"; orb.Font = Enum.Font.GothamBold
    orb.TextSize = 16; orb.TextColor3 = Color3.new(1, 1, 1); orb.AutoButtonColor = false; orb.BackgroundColor3 = Color3.new(1, 1, 1)
    orb.ZIndex = 100; orb.Parent = gui; corner(orb, 24); stroke(orb, ACC2); grad(orb, ACC, ACC2)
    do
        local down, moved, ds, sp = false, false, nil, nil
        orb.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                down, moved, ds, sp = true, false, i.Position, orb.Position
            end
        end)
        connect(UIS.InputChanged, function(i)
            if down and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - ds
                if d.Magnitude > 6 then moved = true end
                if moved then orb.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y) end
            end
        end)
        connect(UIS.InputEnded, function(i)
            if down and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
                down = false
                if not moved then toggleMenu() end
            end
        end)
    end
end

-- ============================== АНТИ-КНОКБЭК / NOCLIP ===================
connect(RunService.Heartbeat, function()
    local hum, hrp = getHum(), getHRP()
    if hum and hum.PlatformStand then hum.PlatformStand = false end
    if hrp and State.farming then
        local v = hrp.AssemblyLinearVelocity
        if Vector3.new(v.X, 0, v.Z).Magnitude > (hum and hum.WalkSpeed or 16) * 1.5 + 15 then
            hrp.AssemblyLinearVelocity = Vector3.new(v.X * 0.1, v.Y, v.Z * 0.1)
        end
    end
end)
connect(RunService.Stepped, function()
    if State.noclip and getChar() then
        for _, p in ipairs(getChar():GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = false end
        end
    end
end)

IH.Unload = function()
    IH.Alive = false
    State.running = false; State.oneShot = false; State.gen += 1; State.noclip = false
    for _, c in ipairs(IH.Conns) do pcall(function() c:Disconnect() end) end
    pcall(function() if ui.gui then ui.gui:Destroy() end end)
    env.IvanHubV7 = nil
    print("[DEBUG] Скрипт выгружен")
end

-- ============================== ЗАПУСК ==================================
dbg("Скрипт v7 запущен. Игрок:", LP.Name)
local okGui, errGui = xpcall(buildGui, tb)
if not okGui then print("[DEBUG] ОШИБКА ПОСТРОЕНИЯ GUI:", errGui) end

dbg("Функции экзекьютора: fireproximityprompt =", fireproximityprompt ~= nil, "| fireclickdetector =", fireclickdetector ~= nil,
    "| firetouchinterest =", firetouchinterest ~= nil)
dbg("SafeZone (зашита):", "Workspace." .. SAFE_PATH, "→", dig(workspace, SAFE_PATH) and "есть" or "НЕ НАЙДЕНА")

-- сканер: каждые ScanInterval секунд
task.spawn(function()
    while IH.Alive do
        local ok, err = xpcall(function()
            scan()
            updatePanel()
            if ui.refreshBtn then ui.refreshBtn() end
            if not State.running and ui.status and State.eggs and not State.farming then
                setStatus(#State.eggs > 0 and "готов (нажми СТАРТ)" or "яиц не найдено")
            end
        end, tb)
        State.scanning = false
        if not ok then dbg("ОШИБКА СКАНЕРА:", err) end
        task.wait(Config.ScanInterval)
    end
end)

connect(LP.CharacterAdded, function()
    task.wait(1.5)
    State.noclip = false; State.expectCarry = false
    dbg("Респавн: персонаж создан заново")
end)

end

local okMain, errMain = xpcall(IvanHubMain, function(e)
    return tostring(e) .. " | " .. ((debug and debug.traceback) and debug.traceback("", 2) or "")
end)
if not okMain then print("[DEBUG] КРИТИЧЕСКАЯ ОШИБКА СКРИПТА (моего кода):", errMain) end
