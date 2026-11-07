-- Knox Achievements: логика достижений, всплывающее окно и список (F10).
-- Тексты берутся из Translate/<LANG>/UI.json, английский запасной вариант лежит в KnoxAchData.lua.
pcall(require, "ISUI/ISPanel")

KnoxAch = KnoxAch or {}
local KA = KnoxAch
KA.unlocked = KA.unlocked or {}
KA.stats = KA.stats or { deaths = 0 }
KA.queue = KA.queue or {}
KA.current = nil
KA.nextAt = 0
KA.killTimes = {}
KA.SAVE_FILE = "KnoxAchievements.txt"
KA.fakeMs = 0

local TIER_COLORS = {
    { 0.80, 0.50, 0.20 },
    { 0.78, 0.80, 0.85 },
    { 1.00, 0.82, 0.20 },
    { 0.85, 0.30, 1.00 },
}
local PERK_NAMES = {
    "Fitness", "Strength", "Sprinting", "Lightfoot", "Nimble", "Sneak",
    "Axe", "Blunt", "SmallBlunt", "LongBlade", "SmallBlade", "Spear", "Maintenance",
    "Aiming", "Reloading", "Woodwork", "Cooking", "Farming", "Doctor", "Electricity",
    "MetalWelding", "Mechanics", "Tailoring", "Fishing", "Trapping", "PlantScavenging",
}
local TIER_NAMES = { "Easy", "Medium", "Hard", "Hardcore" }
local BATCH_LIMIT = 3      -- больше новых достижений за раз: показываем одно общее уведомление
local TOAST_IN, TOAST_HOLD, TOAST_OUT = 450, 5200, 700

local function log(msg) print("[KnoxAch] " .. tostring(msg)) end

local function nowMs()
    local ok, v = pcall(getTimestampMs)
    if ok and type(v) == "number" then return v end
    KA.fakeMs = KA.fakeMs + 5
    return KA.fakeMs
end

local function T(key, fallback)
    local ok, s = pcall(getText, key)
    if ok and type(s) == "string" and s ~= "" and s ~= key and not string.find(s, "UI_Ach_", 1, true) then
        return s
    end
    return fallback or key
end
function KA.nameOf(a) return T("UI_Ach_" .. a.id .. "_n", a.en) end
function KA.descOf(a) return T("UI_Ach_" .. a.id .. "_d", a.ed) end

-- ========== Данные ==========
local function getData(player)
    local md = player:getModData()
    md.KnoxAch = md.KnoxAch or {}
    local d = md.KnoxAch
    d.walk = d.walk or 0
    d.drive = d.drive or 0
    d.levelups = d.levelups or 0
    d.sleeps = d.sleeps or 0
    d.realSec = d.realSec or 0
    d.wk = d.wk or {}
    d.hrDays = d.hrDays or {}
    d.hrLast = d.hrLast or {}
    d.unlocked = d.unlocked or {}
    return d
end

local function totalCount()
    return #(KnoxAchData or {})
end

local function unlockedCount()
    local n = 0
    for _ in pairs(KA.unlocked) do n = n + 1 end
    return n
end

-- ========== Сохранение (общее для всех персонажей) ==========
function KA.save()
    pcall(function()
        local w = getFileWriter(KA.SAVE_FILE, true, false)
        if not w then return end
        for id in pairs(KA.unlocked) do w:write("u:" .. id .. "\n") end
        for k, v in pairs(KA.stats) do w:write("s:" .. k .. "=" .. tostring(v) .. "\n") end
        w:close()
    end)
    pcall(function()
        local p = getSpecificPlayer(0)
        if p then
            local d = getData(p)
            for id in pairs(KA.unlocked) do d.unlocked[id] = true end
        end
    end)
end

function KA.load()
    pcall(function()
        local r = getFileReader(KA.SAVE_FILE, false)
        if not r then return end
        local line = r:readLine()
        while line do
            local id = string.match(line, "^u:(.+)$")
            if id then KA.unlocked[id] = true end
            local k, v = string.match(line, "^s:([%w_]+)=(.+)$")
            if k then KA.stats[k] = tonumber(v) or v end
            line = r:readLine()
        end
        r:close()
    end)
end

-- ========== Навыки ==========
local perkCache = nil
local function resolvePerks()
    if perkCache then return perkCache end
    perkCache = {}
    for _, name in ipairs(PERK_NAMES) do
        local obj = nil
        pcall(function() obj = Perks[name] end)
        if not obj then pcall(function() obj = Perks.FromString(name) end) end
        if obj then perkCache[name] = obj end
    end
    return perkCache
end

local function perkLevel(player, name)
    local obj = resolvePerks()[name]
    if not obj then return nil end
    local ok, lvl = pcall(function() return player:getPerkLevel(obj) end)
    if ok then return lvl end
    return nil
end

local function countPerks(player, minLevel)
    local cnt, total = 0, 0
    for name in pairs(resolvePerks()) do
        total = total + 1
        local l = perkLevel(player, name)
        if l and l >= minLevel then cnt = cnt + 1 end
    end
    return cnt, total
end

-- ========== Комбо (несколько убийств подряд) ==========
local function comboMax(windowMs)
    local times = KA.killTimes
    local best = 0
    for i = 1, #times do
        local c = 0
        for j = i, #times do
            if times[j] - times[i] <= windowMs then c = c + 1 else break end
        end
        if c > best then best = c end
    end
    return best
end

-- ========== Проверка условий ==========
local function check(a, c)
    local k = a.kind
    if k == "kills" then return c.kills >= a.v
    elseif k == "hours" then return c.hours >= a.v
    elseif k == "walk" then return c.walk >= a.v
    elseif k == "drive" then return c.drive >= a.v
    elseif k == "levelups" then return c.levelups >= a.v
    elseif k == "deaths" then return (tonumber(KA.stats.deaths) or 0) >= a.v
    elseif k == "sleeps" then return c.sleeps >= a.v
    elseif k == "weight" then return c.weight >= a.v
    elseif k == "overweight" then return c.maxWeight > 0 and c.weight > c.maxWeight
    elseif k == "items" then return c.items >= a.v
    elseif k == "realmin" then return c.realSec >= a.v * 60
    elseif k == "killsday" then return c.killsToday >= a.v
    elseif k == "hour" then return c.hour == a.v and not c.asleep
    elseif k == "hourdays" then return (c.hrDays[tostring(a.h)] or 0) >= a.v
    elseif k == "perk" then
        local l = perkLevel(c.player, a.perk)
        return l ~= nil and l >= a.v
    elseif k == "perkcount" then
        local cnt = countPerks(c.player, a.lvl)
        return cnt >= a.v
    elseif k == "perkall" then
        local cnt, total = countPerks(c.player, 10)
        return total > 0 and cnt >= total
    elseif k == "wk" then return (c.wk[a.grp] or 0) >= a.v
    elseif k == "combo" then return comboMax(a.sec * 1000) >= a.v
    elseif k == "flag" then return tonumber(KA.stats["flag_" .. a.flag]) == 1
    elseif k == "unlocked" then return c.unlockedCount >= a.v
    elseif k == "unlockedall" then return c.unlockedCount >= c.total - 1
    end
    return false
end

local function buildContext(player)
    local d = getData(player)
    local c = { player = player, wk = d.wk, walk = d.walk, drive = d.drive,
                levelups = d.levelups, sleeps = d.sleeps, realSec = d.realSec }
    c.kills = player:getZombieKills()
    c.hours = player:getHoursSurvived()
    c.weight, c.maxWeight, c.items = 0, 0, 0
    pcall(function()
        c.weight = player:getInventory():getCapacityWeight()
        c.maxWeight = player:getMaxWeight()
        c.items = player:getInventory():getItems():size()
    end)
    c.hour, c.asleep = -1, false
    pcall(function() c.hour = getGameTime():getHour() end)
    pcall(function() c.asleep = player:isAsleep() end)
    -- убийства за игровой день
    pcall(function()
        local gt = getGameTime()
        local key = gt:getYear() * 10000 + gt:getMonth() * 100 + gt:getDay()
        if d.dayKey ~= key or d.dayStart == nil or d.dayStart > c.kills then
            d.dayKey = key
            d.dayStart = c.kills
        end
    end)
    c.killsToday = c.kills - (d.dayStart or c.kills)
    -- дни, в которые вы бодрствовали в заданный час
    pcall(function()
        local gt = getGameTime()
        local key = gt:getYear() * 10000 + gt:getMonth() * 100 + gt:getDay()
        local hk = tostring(c.hour)
        if c.hour >= 0 and not c.asleep and d.hrLast[hk] ~= key then
            d.hrLast[hk] = key
            d.hrDays[hk] = (d.hrDays[hk] or 0) + 1
        end
    end)
    c.hrDays = d.hrDays
    c.total = totalCount()
    c.unlockedCount = unlockedCount()
    return c
end

-- ========== Выдача достижений ==========
local function unlock(a, silent)
    if KA.unlocked[a.id] then return end
    KA.unlocked[a.id] = true
    if not silent then KA.queue[#KA.queue + 1] = a end
end

function KA.evaluate(player)
    if not player or not KnoxAchData then return end
    local newly = {}
    for pass = 1, 2 do
        local c
        local ok = pcall(function() c = buildContext(player) end)
        if not ok or not c then return end
        local found = false
        for _, a in ipairs(KnoxAchData) do
            if not KA.unlocked[a.id] then
                local okc, res = pcall(check, a, c)
                if okc and res then
                    KA.unlocked[a.id] = true
                    newly[#newly + 1] = a
                    c.unlockedCount = c.unlockedCount + 1
                    found = true
                end
            end
        end
        if not found then break end
    end
    if #newly == 0 then return end
    if #newly > BATCH_LIMIT then
        KA.queue[#KA.queue + 1] = { id = "batch", tier = 2, en = "Welcome Back, Survivor",
            ed = "{n} achievements unlocked from your existing progress.", count = #newly }
    else
        for _, a in ipairs(newly) do KA.queue[#KA.queue + 1] = a end
    end
    KA.save()
end

-- ========== Звук ==========
local function playUnlockSound()
    local player = getSpecificPlayer(0)
    local names = { "GainExperienceLevel", "KnoxAchievement" }
    for _, name in ipairs(names) do
        local id = nil
        pcall(function()
            if player and player:getEmitter() then id = player:getEmitter():playSound(name) end
        end)
        if type(id) == "number" and id ~= 0 then return true end
    end
    for _, name in ipairs(names) do
        local ok = pcall(function() getSoundManager():playUISound(name) end)
        if ok then return true end
    end
    return false
end
KA.playUnlockSound = playUnlockSound

-- ========== Отслеживание ==========
local tr = { lastX = nil, lastY = nil, lastKills = nil, lastMs = nil, wasAsleep = false, dirty = false }

local function weaponGroup(player)
    local grp = "unarmed"
    pcall(function()
        if player:getVehicle() then grp = "vehicle"; return end
        local item = player:getPrimaryHandItem()
        if not item or not instanceof(item, "HandWeapon") then grp = "unarmed"; return end
        if item:isRanged() then grp = "ranged"; return end
        local t = tostring(item:getType())
        if string.find(t, "Crowbar", 1, true) then grp = "crowbar"
        elseif string.find(t, "Katana", 1, true) then grp = "katana"
        elseif string.find(t, "BaseballBat", 1, true) then grp = "bat"
        elseif string.find(t, "Axe", 1, true) then grp = "axe"
        elseif string.find(t, "Pan", 1, true) then grp = "pan"
        else grp = "other" end
    end)
    return grp
end

local function onPlayerUpdate(player)
    if player:getPlayerNum() ~= 0 or player:isDead() then return end
    local d = getData(player)
    local ms = nowMs()

    -- расстояние
    local x, y = player:getX(), player:getY()
    if tr.lastX then
        local dx, dy = x - tr.lastX, y - tr.lastY
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist > 0 and dist < 5 then
            local inCar = false
            pcall(function() inCar = player:getVehicle() ~= nil end)
            if inCar then d.drive = d.drive + dist else d.walk = d.walk + dist end
        end
    end
    tr.lastX, tr.lastY = x, y

    -- реальное время игры
    if tr.lastMs then
        local dt = ms - tr.lastMs
        if dt > 0 and dt < 1000 then d.realSec = d.realSec + dt / 1000 end
    end
    tr.lastMs = ms

    -- убийства
    local kills = player:getZombieKills()
    if tr.lastKills == nil then
        tr.lastKills = kills
    elseif kills > tr.lastKills then
        local n = kills - tr.lastKills
        tr.lastKills = kills
        local grp = weaponGroup(player)
        d.wk[grp] = (d.wk[grp] or 0) + n
        for _ = 1, math.min(n, 10) do KA.killTimes[#KA.killTimes + 1] = ms end
        while #KA.killTimes > 0 and (ms - KA.killTimes[1]) > 90000 do table.remove(KA.killTimes, 1) end
        while #KA.killTimes > 300 do table.remove(KA.killTimes, 1) end
        tr.dirty = true
    end

    -- сон
    local asleep = false
    pcall(function() asleep = player:isAsleep() end)
    if asleep and not tr.wasAsleep then d.sleeps = d.sleeps + 1; tr.dirty = true end
    tr.wasAsleep = asleep

    if tr.dirty then
        tr.dirty = false
        KA.evaluate(player)
    end
end

local function onLevelPerk(player, perk, level, levelUp)
    local p = player or getSpecificPlayer(0)
    if not p or levelUp == false then return end
    local d = getData(p)
    d.levelups = d.levelups + 1
    KA.evaluate(p)
end

local function onPlayerDeath(player)
    pcall(function()
        KA.stats.deaths = (tonumber(KA.stats.deaths) or 0) + 1
        if player:getHoursSurvived() < 1 then KA.stats.flag_fast_death = 1 end
        if player:isAsleep() then KA.stats.flag_asleep_death = 1 end
    end)
    KA.save()
    KA.evaluate(player)
end

local function onEveryOneMinute()
    local p = getSpecificPlayer(0)
    if p and not p:isDead() then KA.evaluate(p) end
end

local function onCreatePlayer(playerNum, player)
    if playerNum ~= 0 then return end
    tr.lastX, tr.lastY, tr.lastKills, tr.lastMs, tr.wasAsleep = nil, nil, nil, nil, false
    KA.killTimes = {}
    pcall(function()
        local d = getData(player)
        for id in pairs(d.unlocked) do KA.unlocked[id] = true end
    end)
end

-- ========== Уведомление ==========
KnoxToast = ISPanel:derive("KnoxToast")

function KnoxToast:new()
    local w, h = 420, 96
    local x = math.floor(getCore():getScreenWidth() / 2 - w / 2)
    local o = ISPanel:new(x, -h, w, h)
    setmetatable(o, self)
    self.__index = self
    o.background = false
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    return o
end

function KnoxToast:prerender() end

local function wrapText(text, font, maxw, maxLines)
    local tm = getTextManager()
    local lines, line = {}, ""
    local pos = 1
    while true do
        local s, e = string.find(text, "%S+", pos)
        if not s then break end
        local word = string.sub(text, s, e)
        pos = e + 1
        local try = (line == "") and word or (line .. " " .. word)
        if tm:MeasureStringX(font, try) <= maxw or line == "" then
            line = try
        else
            lines[#lines + 1] = line
            line = word
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    if #lines > maxLines then
        local cut = {}
        for i = 1, maxLines do cut[i] = lines[i] end
        cut[maxLines] = cut[maxLines] .. "..."
        lines = cut
    end
    return lines
end

function KnoxToast:render()
    local now = nowMs()
    if not KA.current then
        if #KA.queue > 0 and now >= KA.nextAt then
            KA.current = table.remove(KA.queue, 1)
            KA.currentStart = now
            KA.playUnlockSound()
        else
            return
        end
    end
    local a = KA.current
    local t = now - KA.currentStart
    local total = TOAST_IN + TOAST_HOLD + TOAST_OUT
    if t >= total then
        KA.current = nil
        KA.nextAt = now + 250
        self:setY(-self.height)
        return
    end
    local alpha, y = 1, 70
    if t < TOAST_IN then
        local p = t / TOAST_IN
        y = -self.height + (70 + self.height) * (1 - (1 - p) * (1 - p))
        alpha = p
    elseif t > TOAST_IN + TOAST_HOLD then
        alpha = 1 - (t - TOAST_IN - TOAST_HOLD) / TOAST_OUT
    end
    self:setY(math.floor(y))

    local tier = a.tier or 1
    local col = TIER_COLORS[tier] or TIER_COLORS[1]
    local w, h = self.width, self.height
    self:drawRect(0, 0, w, h, 0.92 * alpha, 0.05, 0.05, 0.07)
    self:drawRect(0, 0, 5, h, alpha, col[1], col[2], col[3])
    self:drawRectBorder(0, 0, w, h, 0.6 * alpha, col[1], col[2], col[3])

    local tex = nil
    pcall(function() tex = getTexture("media/ui/KnoxAch_tier" .. tier .. ".png") end)
    if tex then
        self:drawTextureScaled(tex, 16, 20, 56, 56, alpha, 1, 1, 1)
    else
        self:drawRect(16, 20, 56, 56, alpha, col[1], col[2], col[3])
    end

    local tx = 88
    self:drawText(T("UI_Ach_header", "ACHIEVEMENT UNLOCKED") .. "  -  " .. T("UI_Ach_tier" .. tier, TIER_NAMES[tier] or ""),
        tx, 8, col[1], col[2], col[3], alpha, UIFont.Small)
    local name, desc
    if a.id == "batch" then
        name = T("UI_Ach_batch_n", a.en)
        desc = string.gsub(T("UI_Ach_batch_d", a.ed), "{n}", tostring(a.count or 0))
    else
        name = KA.nameOf(a)
        desc = KA.descOf(a)
    end
    self:drawText(name, tx, 26, 1, 1, 1, alpha, UIFont.Medium)
    local lines = wrapText(desc, UIFont.Small, w - tx - 12, 2)
    local fh = getTextManager():getFontHeight(UIFont.Small)
    for i, ln in ipairs(lines) do
        self:drawText(ln, tx, 52 + (i - 1) * (fh + 1), 0.82, 0.82, 0.82, alpha, UIFont.Small)
    end
end

-- ========== Список достижений (F10) ==========
KnoxAchList = ISPanel:derive("KnoxAchList")

function KnoxAchList:new()
    local w, h = 600, 460
    local x = math.floor(getCore():getScreenWidth() / 2 - w / 2)
    local y = math.floor(getCore():getScreenHeight() / 2 - h / 2)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = { r = 0.04, g = 0.04, b = 0.05, a = 0.94 }
    o.borderColor = { r = 1, g = 1, b = 1, a = 0.25 }
    o.moveWithMouse = true
    o.scroll = 0
    return o
end

local ROW_H, HEAD_H = 40, 42

function KnoxAchList:visibleRows()
    return math.max(1, math.floor((self.height - HEAD_H - 28) / ROW_H))
end

function KnoxAchList:onMouseWheel(del)
    local list = KnoxAchData or {}
    local maxScroll = math.max(0, #list - self:visibleRows())
    self.scroll = math.max(0, math.min(maxScroll, self.scroll + (del > 0 and 2 or -2)))
    return true
end

local function fitText(text, font, maxw)
    local tm = getTextManager()
    if tm:MeasureStringX(font, text) <= maxw then return text end
    while #text > 1 and tm:MeasureStringX(font, text .. "...") > maxw do
        text = string.sub(text, 1, #text - 1)
    end
    return text .. "..."
end

function KnoxAchList:render()
    local list = KnoxAchData or {}
    local w = self.width
    self:drawText(T("UI_Ach_list_title", "Achievements") .. ":  " .. unlockedCount() .. " / " .. #list,
        14, 10, 1, 1, 1, 1, UIFont.Medium)
    local rows = self:visibleRows()
    for i = 1, rows do
        local a = list[self.scroll + i]
        if not a then break end
        local y = HEAD_H + (i - 1) * ROW_H
        local col = TIER_COLORS[a.tier] or TIER_COLORS[1]
        local got = KA.unlocked[a.id] == true
        local k = got and 1 or 0.35
        self:drawRect(10, y, w - 20, ROW_H - 4, 0.5, 0.1, 0.1, 0.12)
        self:drawRect(10, y, 4, ROW_H - 4, got and 1 or 0.4, col[1], col[2], col[3])
        local tex = nil
        pcall(function() tex = getTexture("media/ui/KnoxAch_tier" .. a.tier .. ".png") end)
        if tex then
            self:drawTextureScaled(tex, 20, y + 3, 30, 30, got and 1 or 0.3, 1, 1, 1)
        end
        self:drawText(fitText(KA.nameOf(a), UIFont.Small, w - 90), 60, y + 2, k, k, k, 1, UIFont.Small)
        self:drawText(fitText(KA.descOf(a), UIFont.Small, w - 90), 60, y + 19, 0.7 * k, 0.7 * k, 0.7 * k, 1, UIFont.Small)
    end
    self:drawText(T("UI_Ach_list_hint", "Mouse wheel: scroll   F10: close"), 14, self.height - 22, 0.6, 0.6, 0.6, 1, UIFont.Small)
end

-- ========== Создание окон и клавиши ==========
local function ensureToast()
    if KA.toast then return end
    KA.toast = KnoxToast:new()
    KA.toast:initialise()
    KA.toast:instantiate()
    pcall(function() KA.toast:setConsumeMouseEvents(false) end)
    KA.toast:addToUIManager()
    pcall(function() KA.toast:setAlwaysOnTop(true) end)
end

local function toggleList()
    if KA.list and KA.list:isVisible() then
        KA.list:setVisible(false)
        return
    end
    if not KA.list then
        KA.list = KnoxAchList:new()
        KA.list:initialise()
        KA.list:instantiate()
        KA.list:addToUIManager()
    end
    KA.list:setVisible(true)
    KA.list:bringToTop()
end

local function onKeyPressed(key)
    if key ~= Keyboard.KEY_F10 then return end
    local shift = false
    pcall(function() shift = isKeyDown(Keyboard.KEY_LSHIFT) or isKeyDown(Keyboard.KEY_RSHIFT) end)
    if shift then
        -- Shift+F10: тест уведомления и звука (достижение не выдаётся)
        local list = KnoxAchData or {}
        if #list > 0 then
            KA.queue[#KA.queue + 1] = list[ZombRand(#list) + 1]
        end
        return
    end
    toggleList()
end

local function onGameStart()
    KA.load()
    ensureToast()
    log("loaded, achievements: " .. totalCount() .. ", unlocked: " .. unlockedCount())
end

Events.OnGameStart.Add(onGameStart)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnPlayerUpdate.Add(onPlayerUpdate)
Events.OnPlayerDeath.Add(onPlayerDeath)
Events.EveryOneMinute.Add(onEveryOneMinute)
Events.LevelPerk.Add(onLevelPerk)
Events.OnKeyPressed.Add(onKeyPressed)
