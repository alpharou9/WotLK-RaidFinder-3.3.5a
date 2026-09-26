-------------------------------------------------------------------------------
-- RaidFinder  –  WotLK 3.3.5a Chat-Scanner Addon
-- Monitors Trade / LFG / General / Say / Yell / Guild chat for raid
-- recruitment messages and presents them in a filterable, scrollable UI.
--
-- /rf  or  /raidfinder   – toggle the main window
-- /rf config              – open settings panel
-- /rf clear               – wipe collected entries
-- /rf help                – print help
-------------------------------------------------------------------------------

local ADDON_NAME = "RaidFinder"

-------------------------------------------------------------------------------
-- 0.  SAVED VARIABLES  –  defaults & initialization
-------------------------------------------------------------------------------
RaidFinderDB = RaidFinderDB or {}

local DEFAULTS = {
    -- Channel toggles  (event name → enabled)
    channels = {
        CHAT_MSG_CHANNEL       = true,   -- Trade / LFG / General
        CHAT_MSG_SAY           = true,
        CHAT_MSG_YELL          = true,
        CHAT_MSG_GUILD         = true,
        CHAT_MSG_PARTY         = false,
        CHAT_MSG_PARTY_LEADER  = false,
        CHAT_MSG_RAID          = false,
        CHAT_MSG_RAID_LEADER   = false,
    },

    -- Entry lifetime in seconds  (60 – 900)
    entryLifetime = 300,

    -- Minimum GearScore to show (0 = disabled)
    minGS = 0,

    -- Sound alerts per raid  (tag → bool)
    soundAlerts = {
        ICC = false, RS = false, ToC = false, Ulduar = false,
        Naxx = false, OS = false, EoE = false, VoA = false, Ony = false,
    },

    -- Sound file to play
    soundFile = "Sound\\Interface\\RaidWarning.wav",

    -- User-added custom keywords (plain lowercase strings)
    -- These are treated as EXTRA recruit keywords on top of the built-in ones.
    customKeywords = {},
}

-- Deep-copy defaults into saved DB where keys are missing
local function applyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = {}
                applyDefaults(dst[k], v)
            else
                dst[k] = v
            end
        elseif type(v) == "table" and type(dst[k]) == "table" then
            applyDefaults(dst[k], v)
        end
    end
end

local db   -- shortcut set on PLAYER_LOGIN

-------------------------------------------------------------------------------
-- 1.  RAID & KEYWORD TABLES
-------------------------------------------------------------------------------

local RAIDS = {
    ["ICC"]   = { "icc", "icecrown", "ice crown", "citadel",
                  "marrowgar", "lord marrowgar" },
    ["RS"]    = { "ruby sanctum", "ruby", "rs%d*", "halion" },
    ["ToC"]   = { "toc", "togc", "trial of the crusader", "trial of the grand",
                  "crusader", "grand crusader", "anub'arak", "jaraxxus",
                  "lord jaraxxus" },
    ["Ulduar"]= { "ulduar", "uldu", "uld%d*", "yogg", "algalon", "freya",
                  "hodir", "thorim", "mimiron", "vezax", "assembly",
                  "flame leviathan", "leviathan", "razorscale", "ignis",
                  "xt%-002", "xt002", "deconstructor" },
    ["Naxx"]  = { "naxx", "naxxramas", "nax%d*",
                  "razuvious", "instructor", "noth", "plaguebringer",
                  "patchwerk", "anub'rekhan" },
    ["OS"]    = { "obsidian sanctum", "obsidian", "sarth", "sartharion", "os%d*" },
    ["EoE"]   = { "eye of eternity", "malygos", "eoe" },
    ["VoA"]   = { "vault of archavon", "vault", "voa", "archavon", "emalon",
                  "koralon", "toravon" },
    ["Ony"]   = { "onyxia", "ony%d*" },
}

local BUILTIN_RECRUIT_KEYWORDS = {
    "lfm", "lf%dm", "lf %d+m", "lf%d+", "looking for more", "looking for",
    "lf ", "need", "needs", "needing",
    "whisper", "whisp", "pst", "pm me", "w me", "/w",
    "come join", "join us", "recruiting", "hosted",
    "still need", "last spot", "last slot",
    "forming", "putting together",
    "weekly", "weekly quest", "must die",
}

local ROLE_PATTERNS = {
    { patterns = { "tank", "tanks", "mt", "ot", "prot" },       tag = "TANK" },
    { patterns = { "heal", "healer", "healers", "heals", "resto", "rdruid",
                   "hpal", "hpala", "disc", "holy" },            tag = "HEAL" },
    { patterns = { "dps", "rdps", "mdps", "ranged", "melee",
                   "caster", "casters" },                        tag = "DPS"  },
}

local SIZE_PATTERNS = {
    { patterns = { "[^%d]25[^%d]", "[^%d]25$", "^25[^%d]", "^25$" }, tag = "25" },
    { patterns = { "[^%d]10[^%d]", "[^%d]10$", "^10[^%d]", "^10$" }, tag = "10" },
}

local DIFF_PATTERNS = {
    -- [^e] avoids accidentally matching "10healers" or "10need"
    { patterns = { "heroic", "hc", "hm", "hard mode", "hardmode", "10h[^e]", "25h[^e]", "10h$", "25h$" }, tag = "HC" },
    { patterns = { "normal", "nm", "reg", "10n[^e]", "25n[^e]", "10n$", "25n$" },                         tag = "NM" },
}



local function detectGS(text)
    local gs = text:match("(%d[%d%.]+)%s*k%s*gs")
        or text:match("gs%s*(%d[%d%.]+)%s*k")
        or text:match("(%d%d%d%d+)%s*%+?%s*gs")
        or text:match("gs%s*(%d%d%d%d+)")
        or text:match("(%d[%d%.]+)%s*k%s*%+")
    if gs then
        local n = tonumber(gs)
        if n and n < 20 then n = n * 1000 end
        if n and n >= 1000 and n <= 9999 then
            return tostring(math.floor(n))
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- 2.  INTERNAL STATE
-------------------------------------------------------------------------------
local entries = {}
local MAX_ENTRIES = 200

local filterRaid  = nil
local filterRole  = nil
local filterSize  = nil
local filterText  = ""    -- free-text search bar

local mainFrame
local configFrame
local scrollFrame, scrollChild
local rows = {}
local ROW_HEIGHT = 52

-------------------------------------------------------------------------------
-- 3.  CHAT PARSING
-------------------------------------------------------------------------------

local function matchesAny(text, list)
    for _, pat in ipairs(list) do
        if text:find(pat) then return true end
    end
    return false
end

local function detectRaid(text)
    for tag, pats in pairs(RAIDS) do
        if matchesAny(text, pats) then return tag end
    end
    return nil
end

local function detectFirst(text, defs)
    for _, def in ipairs(defs) do
        if matchesAny(text, def.patterns) then return def.tag end
    end
    return nil
end

-- Builds the full recruit-keyword list: built-in + user custom
local function getRecruitKeywords()
    local list = {}
    for _, kw in ipairs(BUILTIN_RECRUIT_KEYWORDS) do
        list[#list+1] = kw
    end
    if db and db.customKeywords then
        for _, kw in ipairs(db.customKeywords) do
            list[#list+1] = kw:lower()
        end
    end
    return list
end

local function isRecruitMessage(text)
    return matchesAny(text, getRecruitKeywords())
end

local function parseMessage(text, sender, channel)
    local lower = text:lower()

    if not isRecruitMessage(lower) then return nil end

    local raid = detectRaid(lower)
    if not raid then return nil end

    local role = detectFirst(lower, ROLE_PATTERNS)
    local size = detectFirst(lower, SIZE_PATTERNS)
    local diff = detectFirst(lower, DIFF_PATTERNS)
    local gs   = detectGS(lower)

    return {
        raid    = raid,
        role    = role,
        size    = size,
        diff    = diff,
        gs      = gs,
        sender  = sender,
        channel = channel,
        message = text,
        time    = time(),
    }
end

-------------------------------------------------------------------------------
-- 4.  ENTRY MANAGEMENT
-------------------------------------------------------------------------------

local function addEntry(entry)
    for i, e in ipairs(entries) do
        if e.sender == entry.sender and e.raid == entry.raid
           and (entry.time - e.time) < 60 then
            entries[i] = entry
            return
        end
    end
    table.insert(entries, 1, entry)
    if #entries > MAX_ENTRIES then
        table.remove(entries)
    end
end

local function pruneStale()
    local lifetime = (db and db.entryLifetime) or 300
    local now = time()
    local i = #entries
    while i >= 1 do
        if (now - entries[i].time) > lifetime then
            table.remove(entries, i)
        end
        i = i - 1
    end
end

local function clearEntries()
    wipe(entries)
end

local function getFilteredEntries()
    pruneStale()
    local minGS = (db and db.minGS) or 0
    local searchText = filterText and filterText:lower():trim() or ""
    local out = {}
    for _, e in ipairs(entries) do
        local dominated = false
        if filterRaid and e.raid ~= filterRaid then dominated = true end
        if filterRole and (e.role == nil or e.role ~= filterRole) then dominated = true end
        if filterSize and (e.size == nil or e.size ~= filterSize) then dominated = true end
        -- GearScore filter: only exclude if entry HAS a GS and it's below threshold
        if minGS > 0 and e.gs then
            local n = tonumber(e.gs)
            if n and n < minGS then dominated = true end
        end
        -- Free-text search: match against message, sender, or raid tag
        if searchText ~= "" then
            local haystack = (e.message .. " " .. e.sender .. " " .. e.raid):lower()
            if not haystack:find(searchText, 1, true) then
                dominated = true
            end
        end
        if not dominated then
            out[#out + 1] = e
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- 5.  UI HELPERS
-------------------------------------------------------------------------------

local RAID_COLORS = {
    ["ICC"]    = { r=1.0, g=0.4, b=0.4 },
    ["RS"]     = { r=1.0, g=0.2, b=0.2 },
    ["ToC"]    = { r=1.0, g=0.8, b=0.3 },
    ["Ulduar"] = { r=0.3, g=0.7, b=1.0 },
    ["Naxx"]   = { r=0.0, g=0.8, b=0.3 },
    ["OS"]     = { r=1.0, g=0.5, b=0.0 },
    ["EoE"]    = { r=0.5, g=0.5, b=1.0 },
    ["VoA"]    = { r=0.6, g=0.6, b=0.6 },
    ["Ony"]    = { r=0.8, g=0.4, b=0.8 },
}

local function raidColor(tag)
    return RAID_COLORS[tag] or { r=1, g=1, b=1 }
end

local function timeSince(t)
    local d = time() - t
    if d < 60  then return d .. "s ago" end
    return math.floor(d / 60) .. "m ago"
end

local function tagString(entry)
    local parts = {}
    if entry.size then parts[#parts+1] = entry.size end
    if entry.diff then parts[#parts+1] = entry.diff end
    if entry.role then parts[#parts+1] = entry.role end
    if entry.gs   then parts[#parts+1] = entry.gs .. " GS" end
    if #parts > 0 then
        return "  [" .. table.concat(parts, " | ") .. "]"
    end
    return ""
end

-- Shared backdrop table (3.3.5a compatible)
local BACKDROP_MAIN = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile     = true, tileSize = 32, edgeSize = 24,
    insets   = { left = 6, right = 6, top = 6, bottom = 6 },
}

local BACKDROP_TOOLTIP = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true, tileSize = 16, edgeSize = 16,
    insets   = { left = 4, right = 4, top = 4, bottom = 4 },
}

-------------------------------------------------------------------------------
-- 6.  ROW CREATION (unchanged logic)
-------------------------------------------------------------------------------

-- Forward declaration
local refreshUI

local function createRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.3)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0, 0, 0)
    row.bg = bg

    local raidTag = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    raidTag:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
    raidTag:SetWidth(60)
    raidTag:SetJustifyH("LEFT")
    row.raidTag = raidTag

    local info = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    info:SetPoint("TOPLEFT", raidTag, "TOPRIGHT", 4, 0)
    info:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    info:SetJustifyH("LEFT")
    row.info = info

    local msg = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    msg:SetPoint("TOPLEFT", raidTag, "BOTTOMLEFT", 0, -2)
    msg:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    msg:SetJustifyH("LEFT")
    msg:SetTextColor(0.7, 0.7, 0.7)
    row.msg = msg

    local timeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -4)
    timeText:SetJustifyH("RIGHT")
    timeText:SetTextColor(0.5, 0.5, 0.5)
    row.timeText = timeText

    local sep = row:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
    sep:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
    sep:SetTexture(1, 1, 1, 0.1)

    row:SetScript("OnClick", function(self)
        if self.entry then
            ChatFrame_OpenChat("/w " .. self.entry.sender .. " ")
        end
    end)

    row:SetScript("OnEnter", function(self)
        if self.entry then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.entry.sender, 1, 0.8, 0)
            GameTooltip:AddLine(self.entry.message, 1, 1, 1, true)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Channel: " .. (self.entry.channel or "?"), 0.5, 0.5, 0.5)
            GameTooltip:AddLine(timeSince(self.entry.time), 0.5, 0.5, 0.5)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cff00ff00Left-click|r to whisper", 0.5, 0.5, 0.5)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

refreshUI = function()
    if not mainFrame or not mainFrame:IsShown() then return end

    local filtered = getFilteredEntries()
    local count = #filtered

    if mainFrame.countText then
        mainFrame.countText:SetText(count .. " found")
    end

    scrollChild:SetHeight(math.max(count * ROW_HEIGHT, 1))

    while #rows < count and #rows < MAX_ENTRIES do
        local r = createRow(scrollChild, #rows + 1)
        rows[#rows + 1] = r
    end

    for i = 1, #rows do
        local row = rows[i]
        if i <= count then
            local e = filtered[i]
            row.entry = e

            local c = raidColor(e.raid)
            row.raidTag:SetText(e.raid)
            row.raidTag:SetTextColor(c.r, c.g, c.b)

            row.info:SetText(e.sender .. tagString(e))
            row.info:SetTextColor(1, 1, 1)

            local display = e.message
            if #display > 120 then display = display:sub(1, 117) .. "..." end
            row.msg:SetText(display)

            row.timeText:SetText(timeSince(e.time))

            if i % 2 == 0 then
                row.bg:SetTexture(1, 1, 1, 0.03)
            else
                row.bg:SetTexture(0, 0, 0, 0)
            end

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
            row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)
            row:Show()
        else
            row:Hide()
        end
    end
end

-------------------------------------------------------------------------------
-- 7.  FILTER BUTTON HELPER
-------------------------------------------------------------------------------

local filterButtons = {}

local function makeFilterBtn(parent, label, x, y, width, getFilter, setFilter, value)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetWidth(width)
    btn:SetHeight(22)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    btn:SetText(label)
    btn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")

    local function updateLook()
        if getFilter() == value then
            btn:GetFontString():SetTextColor(0.2, 1, 0.2)
        else
            btn:GetFontString():SetTextColor(1, 1, 1)
        end
    end

    btn:SetScript("OnClick", function()
        if getFilter() == value then
            setFilter(nil)
        else
            setFilter(value)
        end
        updateLook()
        refreshUI()
    end)

    btn.updateLook = updateLook
    return btn
end

-------------------------------------------------------------------------------
-- 8.  MAIN FRAME
-------------------------------------------------------------------------------

local function createMainFrame()
    if mainFrame then return end

    mainFrame = CreateFrame("Frame", "RaidFinderMainFrame", UIParent)
    mainFrame:SetWidth(560)
    mainFrame:SetHeight(550)
    mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 50)
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:SetClampedToScreen(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
    mainFrame:SetFrameStrata("DIALOG")
    mainFrame:SetBackdrop(BACKDROP_MAIN)
    mainFrame:SetBackdropColor(0, 0, 0, 0.92)

    -- Title
    local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", mainFrame, "TOP", 0, -14)
    title:SetText("|cff00ccffRaidFinder|r")

    -- Close
    local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -4, -4)

    -- Config gear button (top-left)
    local cfgBtn = CreateFrame("Button", nil, mainFrame)
    cfgBtn:SetWidth(20)
    cfgBtn:SetHeight(20)
    cfgBtn:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -10)
    cfgBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    cfgBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    cfgBtn:SetScript("OnClick", function() SlashCmdList["RAIDFINDER"]("config") end)
    cfgBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Open Settings", 1, 1, 1)
        GameTooltip:Show()
    end)
    cfgBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Count text
    local countText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 34, -14)
    countText:SetTextColor(0.6, 0.6, 0.6)
    mainFrame.countText = countText

    ---------------------------------------------------------------------------
    -- FILTER BAR  –  Raid
    ---------------------------------------------------------------------------
    local filterY = -36
    local fx = 14

    local raidLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", fx, filterY)
    raidLabel:SetText("Raid:")
    raidLabel:SetTextColor(0.8, 0.8, 0.2)
    fx = fx + 32

    local raidNames = { "ICC", "RS", "ToC", "Ulduar", "Naxx", "OS", "EoE", "VoA", "Ony" }
    for _, rn in ipairs(raidNames) do
        local b = makeFilterBtn(mainFrame, rn, fx, filterY - 2, 48,
            function() return filterRaid end,
            function(v) filterRaid = v end,
            rn)
        filterButtons[#filterButtons+1] = b
        fx = fx + 50
    end

    ---------------------------------------------------------------------------
    -- FILTER BAR  –  Role / Size
    ---------------------------------------------------------------------------
    filterY = filterY - 26
    fx = 14

    local roleLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    roleLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", fx, filterY)
    roleLabel:SetText("Role:")
    roleLabel:SetTextColor(0.8, 0.8, 0.2)
    fx = fx + 32

    for _, rt in ipairs({ "TANK", "HEAL", "DPS" }) do
        local b = makeFilterBtn(mainFrame, rt, fx, filterY - 2, 52,
            function() return filterRole end,
            function(v) filterRole = v end,
            rt)
        filterButtons[#filterButtons+1] = b
        fx = fx + 54
    end

    fx = fx + 20
    local sizeLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sizeLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", fx, filterY)
    sizeLabel:SetText("Size:")
    sizeLabel:SetTextColor(0.8, 0.8, 0.2)
    fx = fx + 32

    for _, sz in ipairs({ "10", "25" }) do
        local b = makeFilterBtn(mainFrame, sz, fx, filterY - 2, 40,
            function() return filterSize end,
            function(v) filterSize = v end,
            sz)
        filterButtons[#filterButtons+1] = b
        fx = fx + 42
    end

    fx = fx + 20
    local clearFiltBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    clearFiltBtn:SetWidth(60)
    clearFiltBtn:SetHeight(22)
    clearFiltBtn:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", fx, filterY - 2)
    clearFiltBtn:SetText("Reset")
    clearFiltBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    clearFiltBtn:SetScript("OnClick", function()
        filterRaid = nil
        filterRole = nil
        filterSize = nil
        filterText = ""
        if mainFrame.searchBox then mainFrame.searchBox:SetText("") end
        for _, b in ipairs(filterButtons) do
            if b.updateLook then b:updateLook() end
        end
        refreshUI()
    end)

    ---------------------------------------------------------------------------
    -- SEARCH BAR
    ---------------------------------------------------------------------------
    filterY = filterY - 28

    local searchLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 14, filterY)
    searchLabel:SetText("Search:")
    searchLabel:SetTextColor(0.8, 0.8, 0.2)

    local searchBox = CreateFrame("EditBox", "RaidFinderSearchBox", mainFrame, "InputBoxTemplate")
    searchBox:SetWidth(440)
    searchBox:SetHeight(22)
    searchBox:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 60, filterY + 2)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(100)
    searchBox:SetFontObject("GameFontNormalSmall")
    searchBox:SetScript("OnTextChanged", function(self)
        filterText = self:GetText() or ""
        refreshUI()
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    mainFrame.searchBox = searchBox

    ---------------------------------------------------------------------------
    -- SCROLL AREA
    ---------------------------------------------------------------------------
    local scrollY = filterY - 28

    scrollFrame = CreateFrame("ScrollFrame", "RaidFinderScrollFrame", mainFrame,
                              "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, scrollY)
    scrollFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -30, 10)

    scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(scrollFrame:GetWidth())
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    scrollFrame:SetScript("OnSizeChanged", function(self, w, h)
        scrollChild:SetWidth(w)
    end)

    -- Periodic refresh
    local elapsed = 0
    mainFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= 3 then
            elapsed = 0
            refreshUI()
        end
    end)

    tinsert(UISpecialFrames, "RaidFinderMainFrame")
    mainFrame:Hide()
end

-------------------------------------------------------------------------------
-- 9.  CONFIG FRAME
-------------------------------------------------------------------------------

local function createConfigFrame()
    if configFrame then return end

    configFrame = CreateFrame("Frame", "RaidFinderConfigFrame", UIParent)
    configFrame:SetWidth(440)
    configFrame:SetHeight(530)
    configFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:SetClampedToScreen(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetFrameLevel(20)
    configFrame:SetBackdrop(BACKDROP_MAIN)
    configFrame:SetBackdropColor(0, 0, 0, 0.95)

    -- Title
    local title = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", configFrame, "TOP", 0, -14)
    title:SetText("|cff00ccffRaidFinder Settings|r")

    -- Close
    local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -4, -4)

    local yOff = -42
    local LEFT = 20

    ---------------------------------------------------------------------------
    -- Helper: section header
    ---------------------------------------------------------------------------
    local function sectionHeader(text, y)
        local hdr = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hdr:SetPoint("TOPLEFT", configFrame, "TOPLEFT", LEFT, y)
        hdr:SetText("|cffffff00" .. text .. "|r")
        return y - 18
    end

    ---------------------------------------------------------------------------
    -- Helper: checkbox
    ---------------------------------------------------------------------------
    local function makeCheck(label, x, y, getValue, setValue)
        local cb = CreateFrame("CheckButton", nil, configFrame, "UICheckButtonTemplate")
        cb:SetWidth(24)
        cb:SetHeight(24)
        cb:SetPoint("TOPLEFT", configFrame, "TOPLEFT", x, y)
        cb:SetChecked(getValue())
        cb:SetScript("OnClick", function(self)
            setValue(self:GetChecked() == 1 or self:GetChecked() == true)
        end)

        local lbl = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        lbl:SetText(label)
        lbl:SetTextColor(0.9, 0.9, 0.9)

        cb.label = lbl
        return cb
    end

    ---------------------------------------------------------------------------
    -- A) CHANNELS
    ---------------------------------------------------------------------------
    yOff = sectionHeader("Channels to Monitor", yOff)

    -- Friendly labels for chat events
    local CHAN_LABELS = {
        { event = "CHAT_MSG_CHANNEL",       label = "Trade / LFG / General  (channel chat)" },
        { event = "CHAT_MSG_YELL",          label = "Yell" },
        { event = "CHAT_MSG_SAY",           label = "Say" },
        { event = "CHAT_MSG_GUILD",         label = "Guild" },
        { event = "CHAT_MSG_PARTY",         label = "Party" },
        { event = "CHAT_MSG_PARTY_LEADER",  label = "Party Leader" },
        { event = "CHAT_MSG_RAID",          label = "Raid" },
        { event = "CHAT_MSG_RAID_LEADER",   label = "Raid Leader" },
    }

    local chanChecks = {}
    for _, ch in ipairs(CHAN_LABELS) do
        local ev = ch.event
        local cb = makeCheck(ch.label, LEFT, yOff,
            function() return db.channels[ev] end,
            function(v) db.channels[ev] = v end)
        chanChecks[#chanChecks+1] = cb
        yOff = yOff - 22
    end

    yOff = yOff - 8

    ---------------------------------------------------------------------------
    -- B) ENTRY LIFETIME  (slider)
    ---------------------------------------------------------------------------
    yOff = sectionHeader("Entry Lifetime", yOff)

    local lifetimeLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lifetimeLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", LEFT, yOff)
    lifetimeLabel:SetTextColor(0.9, 0.9, 0.9)

    yOff = yOff - 16

    local slider = CreateFrame("Slider", "RaidFinderLifetimeSlider", configFrame, "OptionsSliderTemplate")
    slider:SetWidth(340)
    slider:SetHeight(16)
    slider:SetPoint("TOPLEFT", configFrame, "TOPLEFT", LEFT + 10, yOff)
    slider:SetMinMaxValues(60, 900)
    slider:SetValueStep(30)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(db.entryLifetime)

    -- Labels
    getglobal(slider:GetName() .. "Low"):SetText("1 min")
    getglobal(slider:GetName() .. "High"):SetText("15 min")
    getglobal(slider:GetName() .. "Text"):SetText("")

    local function updateLifetimeLabel()
        local v = slider:GetValue()
        local m = math.floor(v / 60)
        local s = v % 60
        local txt = m .. " min"
        if s > 0 then txt = txt .. " " .. s .. "s" end
        lifetimeLabel:SetText("Messages expire after: |cffffffff" .. txt .. "|r")
    end
    updateLifetimeLabel()

    slider:SetScript("OnValueChanged", function(self, value)
        db.entryLifetime = value
        updateLifetimeLabel()
    end)

    yOff = yOff - 30

    ---------------------------------------------------------------------------
    -- C) MINIMUM GEARSCORE  (slider)
    ---------------------------------------------------------------------------
    yOff = sectionHeader("Minimum GearScore Filter", yOff)

    local gsLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gsLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", LEFT, yOff)
    gsLabel:SetTextColor(0.9, 0.9, 0.9)

    yOff = yOff - 16

    local gsSlider = CreateFrame("Slider", "RaidFinderGSSlider", configFrame, "OptionsSliderTemplate")
    gsSlider:SetWidth(340)
    gsSlider:SetHeight(16)
    gsSlider:SetPoint("TOPLEFT", configFrame, "TOPLEFT", LEFT + 10, yOff)
    gsSlider:SetMinMaxValues(0, 6500)
    gsSlider:SetValueStep(100)
    gsSlider:SetObeyStepOnDrag(true)
    gsSlider:SetValue(db.minGS)

    getglobal(gsSlider:GetName() .. "Low"):SetText("Off")
    getglobal(gsSlider:GetName() .. "High"):SetText("6500")
    getglobal(gsSlider:GetName() .. "Text"):SetText("")

    local function updateGSLabel()
        local v = gsSlider:GetValue()
        if v == 0 then
            gsLabel:SetText("Min GS: |cffffffff(disabled – show all)|r")
        else
            gsLabel:SetText("Min GS: |cffffffff" .. v .. "|r")
        end
    end
    updateGSLabel()

    gsSlider:SetScript("OnValueChanged", function(self, value)
        db.minGS = value
        updateGSLabel()
    end)

    yOff = yOff - 30

    ---------------------------------------------------------------------------
    -- D) SOUND ALERTS  (per-raid checkboxes)
    ---------------------------------------------------------------------------
    yOff = sectionHeader("Sound Alerts  (play sound when raid is detected)", yOff)

    local soundChecks = {}
    local raidNames = { "ICC", "RS", "ToC", "Ulduar", "Naxx", "OS", "EoE", "VoA", "Ony" }
    local sx = LEFT
    local perRow = 0
    for _, rn in ipairs(raidNames) do
        local cb = makeCheck(rn, sx, yOff,
            function() return db.soundAlerts[rn] end,
            function(v) db.soundAlerts[rn] = v end)
        soundChecks[#soundChecks+1] = cb
        sx = sx + 80
        perRow = perRow + 1
        if perRow >= 5 then
            perRow = 0
            sx = LEFT
            yOff = yOff - 24
        end
    end
    if perRow > 0 then yOff = yOff - 24 end

    yOff = yOff - 8

    ---------------------------------------------------------------------------
    -- E) CUSTOM KEYWORDS
    ---------------------------------------------------------------------------
    yOff = sectionHeader("Custom Keywords  (extra recruitment words to detect)", yOff)

    -- Scrollable list of current keywords
    local kwListFrame = CreateFrame("Frame", nil, configFrame)
    kwListFrame:SetPoint("TOPLEFT", configFrame, "TOPLEFT", LEFT, yOff)
    kwListFrame:SetWidth(340)
    kwListFrame:SetHeight(60)
    kwListFrame:SetBackdrop(BACKDROP_TOOLTIP)
    kwListFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)

    local kwText = kwListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    kwText:SetPoint("TOPLEFT", kwListFrame, "TOPLEFT", 6, -4)
    kwText:SetPoint("BOTTOMRIGHT", kwListFrame, "BOTTOMRIGHT", -6, 4)
    kwText:SetJustifyH("LEFT")
    kwText:SetJustifyV("TOP")
    kwText:SetTextColor(0.8, 0.8, 0.8)

    local function refreshKWList()
        if #db.customKeywords == 0 then
            kwText:SetText("|cff666666(none – using built-in keywords only)|r")
        else
            kwText:SetText(table.concat(db.customKeywords, ",  "))
        end
    end
    refreshKWList()

    yOff = yOff - 66

    -- Input row: edit box + Add + Remove buttons
    local editBox = CreateFrame("EditBox", "RaidFinderKWEditBox", configFrame, "InputBoxTemplate")
    editBox:SetWidth(200)
    editBox:SetHeight(22)
    editBox:SetPoint("TOPLEFT", configFrame, "TOPLEFT", LEFT + 6, yOff)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(60)
    editBox:SetFontObject("GameFontNormalSmall")

    local addBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    addBtn:SetWidth(55)
    addBtn:SetHeight(22)
    addBtn:SetPoint("LEFT", editBox, "RIGHT", 6, 0)
    addBtn:SetText("Add")
    addBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")

    local removeBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    removeBtn:SetWidth(70)
    removeBtn:SetHeight(22)
    removeBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
    removeBtn:SetText("Remove")
    removeBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")

    addBtn:SetScript("OnClick", function()
        local kw = editBox:GetText():trim():lower()
        if kw == "" then return end
        -- Avoid duplicates
        for _, existing in ipairs(db.customKeywords) do
            if existing == kw then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[RaidFinder]|r Keyword already exists: " .. kw)
                return
            end
        end
        table.insert(db.customKeywords, kw)
        editBox:SetText("")
        refreshKWList()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[RaidFinder]|r Added keyword: |cff00ff00" .. kw .. "|r")
    end)

    removeBtn:SetScript("OnClick", function()
        local kw = editBox:GetText():trim():lower()
        if kw == "" then return end
        for i, existing in ipairs(db.customKeywords) do
            if existing == kw then
                table.remove(db.customKeywords, i)
                editBox:SetText("")
                refreshKWList()
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[RaidFinder]|r Removed keyword: |cffff4444" .. kw .. "|r")
                return
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[RaidFinder]|r Keyword not found: " .. kw)
    end)

    -- Enter key in edit box = add
    editBox:SetScript("OnEnterPressed", function()
        addBtn:Click()
    end)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    ---------------------------------------------------------------------------
    -- FOOTER: Reset Defaults button
    ---------------------------------------------------------------------------
    local resetBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    resetBtn:SetWidth(130)
    resetBtn:SetHeight(24)
    resetBtn:SetPoint("BOTTOMLEFT", configFrame, "BOTTOMLEFT", LEFT, 14)
    resetBtn:SetText("Reset to Defaults")
    resetBtn:GetFontString():SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    resetBtn:SetScript("OnClick", function()
        -- Wipe and reapply defaults
        wipe(db)
        applyDefaults(db, DEFAULTS)

        -- Refresh all config UI elements
        for _, cb in ipairs(chanChecks) do
            -- re-read the value
        end
        slider:SetValue(db.entryLifetime)
        updateLifetimeLabel()
        gsSlider:SetValue(db.minGS)
        updateGSLabel()
        refreshKWList()

        -- Re-check channel checkboxes (recreate is simplest, but let's just
        -- update them by re-reading)
        -- Since we can't easily iterate the checkbox references outside, we
        -- schedule a quick reopen:
        configFrame:Hide()
        configFrame = nil
        createConfigFrame()
        configFrame:Show()

        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[RaidFinder]|r Settings reset to defaults.")
    end)

    tinsert(UISpecialFrames, "RaidFinderConfigFrame")
    configFrame:Hide()

    -- Refresh keyword list when shown (in case it was changed via reset)
    configFrame:SetScript("OnShow", function()
        refreshKWList()
        slider:SetValue(db.entryLifetime)
        updateLifetimeLabel()
        gsSlider:SetValue(db.minGS)
        updateGSLabel()
    end)
end

local function toggleConfig()
    createConfigFrame()
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        configFrame:Show()
    end
end

-------------------------------------------------------------------------------
-- 10.  TOGGLE MAIN
-------------------------------------------------------------------------------

local function toggleUI()
    createMainFrame()
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
        refreshUI()
    end
end

-------------------------------------------------------------------------------
-- 11.  EVENT HANDLING  –  dynamic channel registration
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")

-- All possible chat events we might listen to
local ALL_CHAT_EVENTS = {
    "CHAT_MSG_CHANNEL",
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
}

-- (Re)register events based on db.channels
local function updateRegisteredEvents()
    for _, ev in ipairs(ALL_CHAT_EVENTS) do
        if db.channels[ev] then
            eventFrame:RegisterEvent(ev)
        else
            pcall(function() eventFrame:UnregisterEvent(ev) end)
        end
    end
end

-- Sound alert
local function notifyNew(entry)
    if db and db.soundAlerts and db.soundAlerts[entry.raid] then
        PlaySoundFile(db.soundFile or "Sound\\Interface\\RaidWarning.wav")
    end
end

eventFrame:SetScript("OnEvent", function(self, event, msg, sender, _, _, _, _, _, channelNum, channelName, ...)
    if event == "PLAYER_LOGIN" then
        applyDefaults(RaidFinderDB, DEFAULTS)
        db = RaidFinderDB
        updateRegisteredEvents()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[RaidFinder]|r Loaded!  |cff00ff00/rf|r to open  ·  "
            .. "|cff00ff00/rf config|r for settings  ·  "
            .. "|cff00ff00/rf help|r for commands.")
        return
    end

    -- Check if this event is enabled (might have been disabled after registration)
    if db and db.channels and not db.channels[event] then return end

    if not msg or not sender then return end

    local cleanSender = sender:match("^([^%-]+)") or sender
    local chanLabel = channelName or event:gsub("CHAT_MSG_", "")

    local entry = parseMessage(msg, cleanSender, chanLabel)
    if entry then
        addEntry(entry)
        notifyNew(entry)
        refreshUI()
    end
end)

-- Re-register events whenever config changes (poll every 5s while config is open)
-- This is lightweight and avoids complex callback wiring.
local cfgPollFrame = CreateFrame("Frame")
local cfgElapsed = 0
cfgPollFrame:SetScript("OnUpdate", function(self, dt)
    cfgElapsed = cfgElapsed + dt
    if cfgElapsed >= 5 then
        cfgElapsed = 0
        if db then updateRegisteredEvents() end
    end
end)

-------------------------------------------------------------------------------
-- 12.  SLASH COMMANDS
-------------------------------------------------------------------------------

SLASH_RAIDFINDER1 = "/rf"
SLASH_RAIDFINDER2 = "/raidfinder"

SlashCmdList["RAIDFINDER"] = function(input)
    local cmd = (input or ""):trim():lower()

    if cmd == "config" or cmd == "settings" or cmd == "options" then
        toggleConfig()
    elseif cmd == "clear" then
        clearEntries()
        refreshUI()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[RaidFinder]|r Entries cleared.")
    elseif cmd == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[RaidFinder]|r Commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  |cff00ff00/rf|r            – Toggle the scanner window")
        DEFAULT_CHAT_FRAME:AddMessage("  |cff00ff00/rf config|r     – Open settings panel")
        DEFAULT_CHAT_FRAME:AddMessage("  |cff00ff00/rf clear|r      – Clear all entries")
        DEFAULT_CHAT_FRAME:AddMessage("  |cff00ff00/rf help|r       – Show this help")
    else
        toggleUI()
    end
end
