--[[--------------------------------------------------------------------
  Time To Drink  -  Octowow / vanilla 1.12 addon   v1.3.4
  Watches a chosen healer's mana while you are in a 5-man party
  (disabled in raids) and announces in party chat when they drop
  below a configurable threshold, repeating on an adjustable cooldown.
  Optional second "OOM" alert at a lower threshold.

  Custom messages support these tokens:
    {healer}     the selected healer's name
    {mana}       the healer's current mana %
    {threshold}  the low-mana alert threshold %
    {oom}        the OOM alert threshold %

  Slash commands:
    /ttd            toggle the window
    /ttd status     print current settings + party state
    /ttd preview    print your three messages to your own chat
    /ttd test       send a test line to party chat
    /ttd oom        toggle the OOM alert on / off
    /ttd screen     toggle the on-screen warning (only you see it)
    /ttd debug      toggle verbose messages
----------------------------------------------------------------------]]

TimeToDrink = {}
local TTD = TimeToDrink

local DEFAULT_LOW_MSG = "The healer has less than {threshold}% mana"
local DEFAULT_OOM_MSG = "{healer} is OOM ({mana}% mana)!"
local DEFAULT_SET_MSG = "{healer} has been set as the healer in Time To Drink.  The party will be alerted when they drop below {threshold}% mana."

TTD.roster         = {}
TTD.selectedHealer = nil
TTD.threshold      = 40
TTD.cooldown       = 15
TTD.oomEnabled     = false
TTD.oomThreshold   = 10
TTD.lowMsg         = DEFAULT_LOW_MSG
TTD.oomMsg         = DEFAULT_OOM_MSG
TTD.setMsg         = DEFAULT_SET_MSG
TTD.screenAlert    = false   -- on-screen warning, only you see it
TTD.screenSound    = true    -- play a sound with the on-screen warning
TTD.lastAnnounce   = 0
TTD.lastOOM        = 0
TTD.lastScreenLow  = 0
TTD.lastScreenOOM  = 0
TTD.wasInParty     = false
TTD.pollElapsed    = 0
TTD.debug          = false
TTD.inWorld        = false
TTD.initialized    = false
TTD.disabled       = false
TTD.locked         = false
TTD.pos            = nil
TTD.mmbAngle       = 200
TTD.mmbHidden      = false

local MIN_COOLDOWN  = 10
local POLL_INTERVAL = 0.5
local MAX_MSG_LEN   = 200
local ADDON_PREFIX  = "TTD"

local function msg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TTD:|r " .. text)
end
local function dbg(text)
    if TTD.debug then DEFAULT_CHAT_FRAME:AddMessage("|cff8888ffTTD debug:|r " .. text) end
end
local function err(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff4040TTD error:|r " .. tostring(text))
end

-- 1.12 CheckButtons expect 1 / nil rather than true / false
function TTD_SetCheck(cb, on)
    if not cb then return end
    if on then cb:SetChecked(1) else cb:SetChecked(nil) end
end

-- ===== Saved variables =====
function TTD_SaveAll()
    if type(TimeToDrinkDB) ~= "table" then TimeToDrinkDB = {} end
    TimeToDrinkDB.threshold    = TTD.threshold
    TimeToDrinkDB.cooldown     = TTD.cooldown
    TimeToDrinkDB.disabled     = TTD.disabled
    TimeToDrinkDB.locked       = TTD.locked
    TimeToDrinkDB.pos          = TTD.pos
    TimeToDrinkDB.healer       = TTD.selectedHealer
    TimeToDrinkDB.mmbAngle     = TTD.mmbAngle
    TimeToDrinkDB.mmbHidden    = TTD.mmbHidden
    TimeToDrinkDB.oomEnabled   = TTD.oomEnabled
    TimeToDrinkDB.oomThreshold = TTD.oomThreshold
    TimeToDrinkDB.lowMsg       = TTD.lowMsg
    TimeToDrinkDB.oomMsg       = TTD.oomMsg
    TimeToDrinkDB.setMsg       = TTD.setMsg
    TimeToDrinkDB.screenAlert  = TTD.screenAlert
    TimeToDrinkDB.screenSound  = TTD.screenSound
end

-- ===== On-screen warning (local only, nothing is sent to chat) =====
local ALERT_HOLD = 3.0   -- seconds fully visible
local ALERT_FADE = 1.0   -- seconds to fade out

local function TTD_CreateAlertFrame()
    if TimeToDrinkAlertFrame then return end
    local a = CreateFrame("Frame", "TimeToDrinkAlertFrame", UIParent)
    a:SetFrameStrata("HIGH")
    a:SetWidth(800); a:SetHeight(60)
    a:SetPoint("TOP", UIParent, "TOP", 0, -170)
    local fs = a:CreateFontString("TimeToDrinkAlertText", "OVERLAY")
    fs:SetFont("Fonts\\FRIZQT__.TTF", 26, "THICKOUTLINE")
    fs:SetPoint("CENTER", a, "CENTER", 0, 0)
    fs:SetJustifyH("CENTER")
    a.elapsed = 0
    a:SetScript("OnUpdate", function()
        this.elapsed = this.elapsed + arg1
        if this.elapsed >= ALERT_HOLD + ALERT_FADE then
            this:Hide()
        elseif this.elapsed > ALERT_HOLD then
            this:SetAlpha(1 - (this.elapsed - ALERT_HOLD) / ALERT_FADE)
        end
    end)
    a:Hide()
end

-- kind = "LOW" or "OOM"
function TTD_ShowScreenAlert(text, kind)
    TTD_CreateAlertFrame()
    local fs = TimeToDrinkAlertText
    fs:SetText(text)
    if kind == "OOM" then fs:SetTextColor(1.0, 0.15, 0.15) else fs:SetTextColor(1.0, 0.8, 0.1) end
    TimeToDrinkAlertFrame.elapsed = 0
    TimeToDrinkAlertFrame:SetAlpha(1)
    TimeToDrinkAlertFrame:Show()
    if TTD.screenSound then PlaySoundFile("Sound\\Interface\\RaidWarning.wav") end
end

function TTD_SaveHealer()
    if type(TimeToDrinkDB) == "table" then TimeToDrinkDB.healer = TTD.selectedHealer end
end

local function TTD_InFivePlayerParty()
    if GetNumRaidMembers() > 0 then return false end
    return GetNumPartyMembers() > 0
end

local function TTD_ClampThreshold(v, fallback)
    if not v then return fallback or TTD.threshold end
    if v < 1 then v = 1 end
    if v > 100 then v = 100 end
    return math.floor(v)
end

local function TTD_ClampCooldown(v)
    if not v then return TTD.cooldown end
    if v < MIN_COOLDOWN then v = MIN_COOLDOWN end
    return math.floor(v)
end

-- Trim, strip "|" (can break chat links / disconnect on 1.12), cap length.
-- Empty input falls back to the supplied default.
local function TTD_CleanMessage(s, default)
    if type(s) ~= "string" then return default end
    s = string.gsub(s, "|", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    if s == "" then return default end
    if string.len(s) > MAX_MSG_LEN then s = string.sub(s, 1, MAX_MSG_LEN) end
    return s
end

-- ===== Roster / unit helpers =====
-- The player is always in the list. Party members are added while in a
-- 5-man party. When not in a party, the player is selected automatically.
function TTD_RefreshRoster()
    TTD.roster = {}
    local myname = UnitName("player")
    if myname then table.insert(TTD.roster, myname) end
    if TTD_InFivePlayerParty() then
        local n = GetNumPartyMembers()
        local i = 1
        while i <= n do
            local nm = UnitName("party" .. i)
            if nm then table.insert(TTD.roster, nm) end
            i = i + 1
        end
    end
    if TTD.selectedHealer then
        local found = false
        local j = 1
        while j <= table.getn(TTD.roster) do
            if TTD.roster[j] == TTD.selectedHealer then found = true end
            j = j + 1
        end
        if not found then TTD.selectedHealer = nil end
    end
    if not TTD.selectedHealer and not TTD_InFivePlayerParty() then
        TTD.selectedHealer = myname
    end
end

local function TTD_UnitForName(name)
    if not name then return nil end
    if UnitName("player") == name then return "player" end
    local n = GetNumPartyMembers()
    local i = 1
    while i <= n do
        if UnitName("party" .. i) == name then return "party" .. i end
        i = i + 1
    end
    return nil
end

-- Returns the healer's current mana % (number) or nil if unavailable.
local function TTD_HealerPct()
    local unit = TTD_UnitForName(TTD.selectedHealer)
    if not unit or not UnitExists(unit) then return nil end
    if UnitPowerType(unit) ~= 0 then return nil end
    local mm = UnitManaMax(unit)
    if not mm or mm == 0 then return nil end
    return (UnitMana(unit) / mm) * 100
end

-- ===== Message formatting =====
local function TTD_Sub(s, token, value)
    -- escape "%" in the replacement so gsub treats it literally
    local v = string.gsub(tostring(value), "%%", "%%%%")
    return (string.gsub(s, token, v))
end

function TTD_Format(template, pct)
    local s = template or ""
    s = TTD_Sub(s, "{healer}", TTD.selectedHealer or "The healer")
    s = TTD_Sub(s, "{mana}", pct and math.floor(pct) or "?")
    s = TTD_Sub(s, "{threshold}", TTD.threshold)
    s = TTD_Sub(s, "{oom}", TTD.oomThreshold)
    s = string.gsub(s, "|", "")
    if string.len(s) > 255 then s = string.sub(s, 1, 255) end
    return s
end

-- kind = "LOW" or "OOM"; also tells other TTD clients so they don't double up
local function TTD_Announce(kind, template, pct)
    SendChatMessage(TTD_Format(template, pct), "PARTY")
    if SendAddonMessage then SendAddonMessage(ADDON_PREFIX, kind, "PARTY") end
end

-- ===== Healer dropdown =====
function TTD_InitHealerDropdown()
    local dd = TimeToDrinkHealerDropdown
    if not dd then return end
    UIDropDownMenu_Initialize(dd, function()
        local i = 1
        while i <= table.getn(TTD.roster) do
            local nm   = TTD.roster[i]
            local info = {}
            info.text  = nm
            info.value = nm
            if nm == TTD.selectedHealer then info.checked = 1 end
            info.func  = function()
                TTD.selectedHealer = nm
                TTD_SaveHealer()
                local t = getglobal("TimeToDrinkHealerDropdownText")
                if t then t:SetText(nm) end
                dbg("healer set to " .. nm)
                if TTD_InFivePlayerParty() and not TTD.disabled then
                    SendChatMessage(TTD_Format(TTD.setMsg, TTD_HealerPct()), "PARTY")
                else
                    msg("healer set to " .. nm .. ". Alerts start once you are in a 5-man party.")
                end
                TTD_UpdateReadout()
            end
            UIDropDownMenu_AddButton(info)
            i = i + 1
        end
    end)

    local t = getglobal("TimeToDrinkHealerDropdownText")
    if TTD.selectedHealer then
        if t then t:SetText(TTD.selectedHealer) end
    else
        if t then t:SetText("Select healer") end
    end
end

function TTD_UpdateLockVisual()
    local lock = TimeToDrinkLockButton
    if not lock then return end
    if TTD.locked then
        lock:SetNormalTexture("Interface\\Buttons\\LockButton-Locked-Up")
        lock:SetPushedTexture("Interface\\Buttons\\LockButton-Locked-Up")
    else
        lock:SetNormalTexture("Interface\\Buttons\\LockButton-Unlocked-Up")
        lock:SetPushedTexture("Interface\\Buttons\\LockButton-Unlocked-Up")
    end
    lock:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
end

function TTD_UpdateReadout()
    local st = TimeToDrinkStatus
    if st then
        if not TTD.selectedHealer then
            st:SetText("Alerts inactive: no healer selected.")
        elseif GetNumRaidMembers() > 0 then
            st:SetText("In a raid: alerts are off.")
        elseif not TTD_InFivePlayerParty() and TTD.screenAlert then
            st:SetText("Not in a party: on-screen warnings only.")
        elseif not TTD_InFivePlayerParty() then
            st:SetText("Not in a party: alerts start when you join one.")
        elseif TTD.disabled and TTD.screenAlert then
            st:SetText("Party chat muted. On-screen warnings active.")
        elseif TTD.disabled then
            st:SetText("Alerts muted (quiet mode).")
        elseif TTD.screenAlert then
            st:SetText("Party chat and on-screen alerts active.")
        else
            st:SetText("Party chat alerts active.")
        end
    end
    local fs = TimeToDrinkReadout
    if not fs then return end
    if not TTD.selectedHealer then
        fs:SetText("Healer mana: (none selected)")
        fs:SetTextColor(0.7, 0.7, 0.7)
        return
    end
    local unit = TTD_UnitForName(TTD.selectedHealer)
    if not unit or not UnitExists(unit) then
        fs:SetText(TTD.selectedHealer .. ": not in party")
        fs:SetTextColor(0.7, 0.7, 0.7)
        return
    end
    if UnitPowerType(unit) ~= 0 then
        fs:SetText(TTD.selectedHealer .. " mana: n/a (shapeshifted)")
        fs:SetTextColor(0.7, 0.7, 0.7)
        return
    end
    local mm = UnitManaMax(unit)
    if not mm or mm == 0 then
        fs:SetText(TTD.selectedHealer .. " mana: --")
        fs:SetTextColor(0.7, 0.7, 0.7)
        return
    end
    local pct = math.floor((UnitMana(unit) / mm) * 100)
    fs:SetText(TTD.selectedHealer .. " mana: " .. pct .. "%")
    if TTD.oomEnabled and pct < TTD.oomThreshold then
        fs:SetTextColor(1.0, 0.2, 0.2)
    elseif pct < TTD.threshold then
        fs:SetTextColor(1.0, 0.75, 0.2)
    else
        fs:SetTextColor(0.4, 1.0, 0.4)
    end
end

-- ===== UI =====
-- Every widget is anchored straight to the frame's TOPLEFT with a fixed
-- x column, so larger client fonts can't push rows into each other.
local FRAME_W = 360
local FRAME_H = 628
local LABEL_X = 20
local BOX_X   = 150   -- x where numeric inputs start
local ROW     = 26

local function UI_Label(f, text, y, font)
    local fs = f:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", LABEL_X, y)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

local function UI_Divider(f, y)
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetTexture(1, 0.82, 0, 0.25)
    t:SetHeight(1)
    t:SetPoint("TOPLEFT", f, "TOPLEFT", LABEL_X - 4, y)
    t:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(LABEL_X - 4), y)
    return t
end

-- Numeric box on the same row as a label, with a unit label after it.
local function UI_NumberBox(f, name, y, maxLetters, getVal, setVal, unitText)
    local e = CreateFrame("EditBox", name, f, "InputBoxTemplate")
    e:SetWidth(40); e:SetHeight(20)
    e:SetPoint("TOPLEFT", f, "TOPLEFT", BOX_X, y + 4)
    e:SetAutoFocus(false)
    e:SetMaxLetters(maxLetters)
    e:SetText("" .. getVal())
    e:SetScript("OnTextChanged", function()
        local s = this:GetText()
        local clean = string.gsub(s, "[^0-9]", "")
        if clean ~= s then this:SetText(clean) end
    end)
    -- NOTE: never call ClearFocus() from OnEditFocusLost; on 1.12 that
    -- re-fires OnEditFocusLost and overflows the C stack.
    local busy = false
    local function commit(box)
        if busy then return end
        busy = true
        setVal(tonumber(box:GetText()))
        box:SetText("" .. getVal())
        TTD_SaveAll()
        busy = false
    end
    e:SetScript("OnEnterPressed", function() local box = this; commit(box); box:ClearFocus() end)
    e:SetScript("OnEditFocusLost", function() commit(this) end)
    e:SetScript("OnEscapePressed", function()
        local box = this
        busy = true
        box:SetText("" .. getVal())
        box:ClearFocus()
        busy = false
    end)

    local u = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    u:SetPoint("LEFT", e, "RIGHT", 6, 0)
    u:SetText(unitText)
    return e
end

-- Full-width text box for a chat message.
local function UI_TextBox(f, name, y, getVal, setVal)
    local e = CreateFrame("EditBox", name, f, "InputBoxTemplate")
    e:SetWidth(FRAME_W - (LABEL_X * 2) - 8); e:SetHeight(20)
    e:SetPoint("TOPLEFT", f, "TOPLEFT", LABEL_X + 6, y)
    e:SetAutoFocus(false)
    e:SetMaxLetters(MAX_MSG_LEN)
    e:SetText(getVal())
    local busy = false
    local function commit(box)
        if busy then return end
        busy = true
        setVal(box:GetText())
        box:SetText(getVal())
        TTD_SaveAll()
        busy = false
    end
    e:SetScript("OnEnterPressed", function() local box = this; commit(box); box:ClearFocus() end)
    e:SetScript("OnEditFocusLost", function() commit(this) end)
    e:SetScript("OnEscapePressed", function()
        local box = this
        busy = true
        box:SetText(getVal())
        box:ClearFocus()
        busy = false
    end)
    return e
end

local function UI_Check(f, name, text, y, getVal, setVal)
    local cb = CreateFrame("CheckButton", name, f, "UICheckButtonTemplate")
    cb:SetWidth(24); cb:SetHeight(24)
    cb:SetPoint("TOPLEFT", f, "TOPLEFT", LABEL_X - 5, y + 6)
    local t = getglobal(name .. "Text")
    if t then t:SetText(text) end
    TTD_SetCheck(cb, getVal())
    cb:SetScript("OnClick", function()
        if this:GetChecked() then setVal(true) else setVal(false) end
        TTD_SaveAll()
    end)
    return cb
end

local function TTD_CreateUI()
    if TimeToDrinkUI then return end

    local f = CreateFrame("Frame", "TimeToDrinkUI", UIParent)
    f:SetWidth(FRAME_W)
    f:SetHeight(FRAME_H)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    if TTD.pos and TTD.pos.point and TTD.pos.relPoint and TTD.pos.x and TTD.pos.y then
        f:SetPoint(TTD.pos.point, UIParent, TTD.pos.relPoint, TTD.pos.x, TTD.pos.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() if not TTD.locked then this:StartMoving() end end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local point, _, relPoint, x, y = this:GetPoint()
        TTD.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    f:Hide()
    -- Escape closes the window
    table.insert(UISpecialFrames, "TimeToDrinkUI")

    -- ===== Header: larger title flanked by drink icons =====
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetFont("Fonts\\FRIZQT__.TTF", 20, "OUTLINE")
    title:SetTextColor(1.0, 0.82, 0.0)
    title:SetPoint("TOP", f, "TOP", -10, -20)   -- nudged left to clear the lock/close buttons
    title:SetText("Time To Drink")

    -- Icon in a thin gold frame. Cropping the texcoords trims the default
    -- icon border so the frame sits cleanly around it.
    local function HeaderIcon(texture, side)
        local holder = CreateFrame("Frame", nil, f)
        holder:SetWidth(30); holder:SetHeight(30)
        holder:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        holder:SetBackdropBorderColor(1.0, 0.82, 0.0, 0.9)
        if side == "LEFT" then
            holder:SetPoint("RIGHT", title, "LEFT", -10, 0)
        else
            holder:SetPoint("LEFT", title, "RIGHT", 10, 0)
        end
        local icon = holder:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(24); icon:SetHeight(24)
        icon:SetPoint("CENTER", holder, "CENTER", 0, 0)
        icon:SetTexture(texture)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
    HeaderIcon("Interface\\Icons\\INV_Drink_18", "LEFT")    -- Conjured Crystal Water
    HeaderIcon("Interface\\Icons\\INV_Drink_10", "RIGHT")   -- Morning Glory Dew

    local tagline = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tagline:SetPoint("TOP", title, "BOTTOM", 0, -6)
    tagline:SetText("Keep your healer hydrated")

    UI_Divider(f, -60)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)

    local lock = CreateFrame("Button", "TimeToDrinkLockButton", f)
    lock:SetWidth(24); lock:SetHeight(24)
    lock:SetPoint("RIGHT", close, "LEFT", 2, 0)
    lock:SetScript("OnClick", function()
        TTD.locked = not TTD.locked
        TTD_UpdateLockVisual()
    end)
    TTD_UpdateLockVisual()

    local y = -76

    -- Healer selector (label left, dropdown right, same row)
    UI_Label(f, "Healer", y)
    local dd = CreateFrame("Frame", "TimeToDrinkHealerDropdown", f, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", f, "TOPLEFT", BOX_X - 18, y + 10)
    UIDropDownMenu_SetWidth(150, dd)
    y = y - 34

    -- General
    UI_NumberBox(f, "TimeToDrinkCooldownEdit", y, 4,
        function() return TTD.cooldown end,
        function(v) TTD.cooldown = TTD_ClampCooldown(v) end,
        "sec")
    UI_Label(f, "Repeat alerts every", y)
    y = y - ROW

    UI_Check(f, "TimeToDrinkDisableCheck", "Mute party chat alerts", y,
        function() return TTD.disabled end,
        function(v) TTD.disabled = v; dbg("disabled = " .. tostring(v)); TTD_UpdateReadout() end)
    y = y - ROW

    UI_Check(f, "TimeToDrinkScreenCheck", "On-screen warning (only you see it)", y,
        function() return TTD.screenAlert end,
        function(v) TTD.screenAlert = v; TTD_UpdateReadout() end)
    y = y - ROW

    UI_Check(f, "TimeToDrinkSoundCheck", "Play sound with warning", y,
        function() return TTD.screenSound end,
        function(v) TTD.screenSound = v end)
    local tb = CreateFrame("Button", "TimeToDrinkScreenTestButton", f, "UIPanelButtonTemplate")
    tb:SetWidth(60); tb:SetHeight(22)
    tb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -LABEL_X, y + 6)
    tb:SetText("Test")
    tb:SetScript("OnClick", function()
        TTD_ShowScreenAlert(TTD_Format(TTD.lowMsg, TTD_HealerPct()), "LOW")
    end)
    y = y - ROW - 4

    -- Low mana section
    UI_Divider(f, y + 6)
    UI_Label(f, "Low mana alert", y - 4, "GameFontNormal")
    y = y - 28

    UI_Label(f, "Alert below", y)
    UI_NumberBox(f, "TimeToDrinkThresholdEdit", y, 3,
        function() return TTD.threshold end,
        function(v) TTD.threshold = TTD_ClampThreshold(v, TTD.threshold) end,
        "% mana")
    y = y - ROW

    UI_Label(f, "Message", y)
    y = y - 16
    UI_TextBox(f, "TimeToDrinkLowMsgEdit", y,
        function() return TTD.lowMsg end,
        function(v) TTD.lowMsg = TTD_CleanMessage(v, DEFAULT_LOW_MSG) end)
    y = y - 34

    -- OOM section
    UI_Divider(f, y + 6)
    UI_Label(f, "Out of mana (OOM) alert", y - 4, "GameFontNormal")
    y = y - 28

    UI_Check(f, "TimeToDrinkOOMCheck", "Send OOM alert", y,
        function() return TTD.oomEnabled end,
        function(v) TTD.oomEnabled = v end)
    y = y - ROW

    UI_Label(f, "OOM below", y)
    UI_NumberBox(f, "TimeToDrinkOOMThresholdEdit", y, 3,
        function() return TTD.oomThreshold end,
        function(v) TTD.oomThreshold = TTD_ClampThreshold(v, TTD.oomThreshold) end,
        "% mana")
    y = y - ROW

    UI_Label(f, "Message", y)
    y = y - 16
    UI_TextBox(f, "TimeToDrinkOOMMsgEdit", y,
        function() return TTD.oomMsg end,
        function(v) TTD.oomMsg = TTD_CleanMessage(v, DEFAULT_OOM_MSG) end)
    y = y - 34

    -- Healer-set announcement
    UI_Divider(f, y + 6)
    UI_Label(f, "Healer selected message", y - 4, "GameFontNormal")
    y = y - 24
    UI_TextBox(f, "TimeToDrinkSetMsgEdit", y,
        function() return TTD.setMsg end,
        function(v) TTD.setMsg = TTD_CleanMessage(v, DEFAULT_SET_MSG) end)
    y = y - 32

    -- Token help (own line) + defaults button (centered underneath)
    UI_Label(f, "Tokens: {healer} {mana} {threshold} {oom}", y, "GameFontDisableSmall")
    y = y - 20
    local rb = CreateFrame("Button", "TimeToDrinkDefaultsButton", f, "UIPanelButtonTemplate")
    rb:SetWidth(130); rb:SetHeight(22)
    rb:SetPoint("TOP", f, "TOP", 0, y)
    rb:SetText("Reset messages")
    rb:SetScript("OnClick", function()
        TTD.lowMsg = DEFAULT_LOW_MSG
        TTD.oomMsg = DEFAULT_OOM_MSG
        TTD.setMsg = DEFAULT_SET_MSG
        TTD_SaveAll()
        TTD_RefreshFields()
        msg("messages reset to defaults.")
    end)
    y = y - 36

    -- Live readout + status, both centered at the bottom of the panel
    UI_Divider(f, y + 6)
    -- Footer byline
    local byline = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    byline:SetPoint("BOTTOM", f, "BOTTOM", 0, 18)
    byline:SetJustifyH("CENTER")
    byline:SetTextColor(0.75, 0.62, 0.35)
    byline:SetText("Updated by the premier healer: Jifferoni")

    local status = f:CreateFontString("TimeToDrinkStatus", "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("BOTTOM", byline, "TOP", 0, 6)
    status:SetJustifyH("CENTER")
    status:SetText("Pick a healer to activate alerts.")

    local readout = f:CreateFontString("TimeToDrinkReadout", "OVERLAY", "GameFontNormal")
    readout:SetPoint("BOTTOM", status, "TOP", 0, 6)
    readout:SetJustifyH("CENTER")
    readout:SetText("Healer mana: (none selected)")
end

function TTD_RefreshFields()
    if TimeToDrinkThresholdEdit    then TimeToDrinkThresholdEdit:SetText("" .. TTD.threshold) end
    if TimeToDrinkCooldownEdit     then TimeToDrinkCooldownEdit:SetText("" .. TTD.cooldown) end
    if TimeToDrinkOOMThresholdEdit then TimeToDrinkOOMThresholdEdit:SetText("" .. TTD.oomThreshold) end
    if TimeToDrinkLowMsgEdit       then TimeToDrinkLowMsgEdit:SetText(TTD.lowMsg) end
    if TimeToDrinkOOMMsgEdit       then TimeToDrinkOOMMsgEdit:SetText(TTD.oomMsg) end
    if TimeToDrinkSetMsgEdit       then TimeToDrinkSetMsgEdit:SetText(TTD.setMsg) end
    if TimeToDrinkDisableCheck     then TTD_SetCheck(TimeToDrinkDisableCheck, TTD.disabled) end
    if TimeToDrinkOOMCheck         then TTD_SetCheck(TimeToDrinkOOMCheck, TTD.oomEnabled) end
    if TimeToDrinkScreenCheck      then TTD_SetCheck(TimeToDrinkScreenCheck, TTD.screenAlert) end
    if TimeToDrinkSoundCheck       then TTD_SetCheck(TimeToDrinkSoundCheck, TTD.screenSound) end
end

function TTD_ShowUI()
    TTD_CreateUI()
    TTD_RefreshRoster()
    TTD_InitHealerDropdown()
    TTD_RefreshFields()
    TTD_UpdateReadout()
    TimeToDrinkUI:Show()
end

function TTD_ToggleUI()
    TTD_CreateUI()
    if TimeToDrinkUI:IsShown() then
        TimeToDrinkUI:Hide()
    else
        TTD_ShowUI()
    end
end

-- ===== Mana check =====
-- Party chat ("disabled" = muted) and the on-screen warning are independent,
-- each on its own timer, so you still get your warning even if another
-- player's addon already posted the party message.
local function TTD_CheckHealer()
    if not TTD.inWorld then return end
    if GetNumRaidMembers() > 0 then return end            -- never in raids
    -- Party chat needs a 5-man party; the on-screen warning also works solo.
    local wantParty  = (not TTD.disabled) and TTD_InFivePlayerParty()
    local wantScreen = TTD.screenAlert
    if not wantParty and not wantScreen then return end
    if not TTD.selectedHealer then return end
    local unit = TTD_UnitForName(TTD.selectedHealer)
    if not unit or not UnitExists(unit) then return end
    if UnitIsDeadOrGhost(unit) then return end
    local pct = TTD_HealerPct()
    if not pct then return end
    local now = GetTime()

    if TTD.oomEnabled and pct < TTD.oomThreshold then
        if wantParty and (now - TTD.lastOOM) >= TTD.cooldown then
            TTD_Announce("OOM", TTD.oomMsg, pct)
            TTD.lastOOM = now
            TTD.lastAnnounce = now   -- don't follow up with a low-mana line right away
            dbg("OOM announced (" .. math.floor(pct) .. "% now)")
        end
        if wantScreen and (now - TTD.lastScreenOOM) >= TTD.cooldown then
            TTD_ShowScreenAlert(TTD_Format(TTD.oomMsg, pct), "OOM")
            TTD.lastScreenOOM = now
            TTD.lastScreenLow = now
        end
    elseif pct < TTD.threshold then
        if wantParty and (now - TTD.lastAnnounce) >= TTD.cooldown then
            TTD_Announce("LOW", TTD.lowMsg, pct)
            TTD.lastAnnounce = now
            dbg("low mana announced (" .. math.floor(pct) .. "% now)")
        end
        if wantScreen and (now - TTD.lastScreenLow) >= TTD.cooldown then
            TTD_ShowScreenAlert(TTD_Format(TTD.lowMsg, pct), "LOW")
            TTD.lastScreenLow = now
        end
    end
end

-- ===== Events =====
local driver = CreateFrame("Frame", "TimeToDrinkDriver", UIParent)
driver:RegisterEvent("VARIABLES_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
driver:RegisterEvent("RAID_ROSTER_UPDATE")
driver:RegisterEvent("PLAYER_LOGOUT")
driver:RegisterEvent("CHAT_MSG_PARTY")
driver:RegisterEvent("CHAT_MSG_PARTY_LEADER")
driver:RegisterEvent("CHAT_MSG_ADDON")

driver:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        if type(TimeToDrinkDB) ~= "table" then TimeToDrinkDB = {} end
        local db = TimeToDrinkDB
        if db.threshold then TTD.threshold = TTD_ClampThreshold(db.threshold, 40) end
        if db.cooldown  then TTD.cooldown  = TTD_ClampCooldown(db.cooldown) end
        if db.disabled ~= nil then TTD.disabled = db.disabled end
        if db.locked ~= nil then TTD.locked = db.locked end
        if db.pos then TTD.pos = db.pos end
        if db.mmbAngle then TTD.mmbAngle = db.mmbAngle end
        if db.mmbHidden ~= nil then TTD.mmbHidden = db.mmbHidden end
        if db.oomEnabled ~= nil then TTD.oomEnabled = db.oomEnabled end
        if db.oomThreshold then TTD.oomThreshold = TTD_ClampThreshold(db.oomThreshold, 10) end
        TTD.lowMsg = TTD_CleanMessage(db.lowMsg, DEFAULT_LOW_MSG)
        TTD.oomMsg = TTD_CleanMessage(db.oomMsg, DEFAULT_OOM_MSG)
        TTD.setMsg = TTD_CleanMessage(db.setMsg, DEFAULT_SET_MSG)
        if db.screenAlert ~= nil then TTD.screenAlert = db.screenAlert end
        if db.screenSound ~= nil then TTD.screenSound = db.screenSound end
        TTD_CreateMinimapButton()
        TTD_UpdateMinimapButtonPosition()
        if TimeToDrinkMinimapButton then
            if TTD.mmbHidden then TimeToDrinkMinimapButton:Hide() else TimeToDrinkMinimapButton:Show() end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        TTD.inWorld = true
        if not TTD.initialized then
            TTD.wasInParty = TTD_InFivePlayerParty()
            -- Restore the saved healer only if still grouped with them
            -- (covers reload / reconnect). A genuine new party clears it on join.
            if type(TimeToDrinkDB) == "table" and TimeToDrinkDB.healer
               and TTD_InFivePlayerParty() and TTD_UnitForName(TimeToDrinkDB.healer) then
                TTD.selectedHealer = TimeToDrinkDB.healer
            else
                TTD.selectedHealer = nil
            end
            TTD_RefreshRoster()   -- selects the player when not in a party
            TTD_SaveHealer()
            TTD.initialized = true
        end

    elseif event == "PLAYER_LOGOUT" then
        TTD_SaveAll()

    elseif event == "CHAT_MSG_ADDON" then
        -- Another copy of the addon (any version 1.2+) just announced.
        if arg1 == ADDON_PREFIX then
            local now = GetTime()
            if arg2 == "OOM" then
                TTD.lastOOM = now
                TTD.lastAnnounce = now
            elseif arg2 == "LOW" then
                TTD.lastAnnounce = now
            end
        end

    elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER" then
        -- Compatibility with v1.1 clients, which only post the default text.
        if arg1 and string.find(arg1, "has less than", 1, true) and string.find(arg1, "mana", 1, true) then
            TTD.lastAnnounce = GetTime()
        end

    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        local inParty = TTD_InFivePlayerParty()
        local prevHealer = TTD.selectedHealer
        TTD_RefreshRoster()
        -- Designated healer left, while we were already grouped (not on a fresh join).
        if prevHealer and not TTD.selectedHealer and TTD.inWorld and not TTD.disabled
           and TTD.wasInParty and TTD_InFivePlayerParty() then
            SendChatMessage("The healer has left the party, please designate a new healer, or mute the addon.", "PARTY")
        end
        TTD_SaveHealer()
        -- On joining a fresh party, require the player to pick a healer again.
        if TTD.inWorld and inParty and not TTD.wasInParty then
            TTD.selectedHealer = nil
            TTD_SaveHealer()
            local ok, e = pcall(TTD_ShowUI)
            if not ok then err(e) end
        end
        if TimeToDrinkUI and TimeToDrinkUI:IsShown() then TTD_InitHealerDropdown() end
        if TimeToDrinkUI and TimeToDrinkUI:IsShown() then TTD_UpdateReadout() end
        TTD.wasInParty = inParty
    end
end)
driver:Show()

driver:SetScript("OnUpdate", function()
    TTD.pollElapsed = TTD.pollElapsed + arg1
    if TTD.pollElapsed < POLL_INTERVAL then return end
    TTD.pollElapsed = 0
    if TimeToDrinkUI and TimeToDrinkUI:IsShown() then TTD_UpdateReadout() end
    TTD_CheckHealer()
end)

-- ===== Minimap button (Morning Glory Dew icon, item 8766) =====
function TTD_UpdateMinimapButtonPosition()
    local btn = TimeToDrinkMinimapButton
    if not btn then return end
    local rad = (TTD.mmbAngle or 200) * math.pi / 180
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * 80, math.sin(rad) * 80)
end

function TTD_MinimapButtonDragUpdate()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    if not (mx and px and scale) then return end
    px = px / scale
    py = py / scale
    TTD.mmbAngle = math.deg(math.atan2(py - my, px - mx))
    TTD_UpdateMinimapButtonPosition()
end

function TTD_CreateMinimapButton()
    if TimeToDrinkMinimapButton then return end
    if not Minimap then return end

    local btn = CreateFrame("Button", "TimeToDrinkMinimapButton", Minimap)
    btn:SetWidth(31); btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(20); icon:SetHeight(20)
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 6, -6)
    local tex = nil
    if GetItemIcon then tex = GetItemIcon(8766) end
    icon:SetTexture(tex or "Interface\\Icons\\INV_Drink_10")

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetWidth(53); border:SetHeight(53)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    btn:SetScript("OnClick", function() TTD_ToggleUI() end)
    btn:SetScript("OnDragStart", function() this:SetScript("OnUpdate", TTD_MinimapButtonDragUpdate) end)
    btn:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
        if type(TimeToDrinkDB) == "table" then TimeToDrinkDB.mmbAngle = TTD.mmbAngle end
    end)
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:AddLine("Time To Drink")
        GameTooltip:AddLine("Click to open. Drag to move.", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    TTD_UpdateMinimapButtonPosition()
    if TTD.mmbHidden then btn:Hide() end
end

-- ===== Slash commands =====
SLASH_TIMETODRINK1 = "/ttd"
SLASH_TIMETODRINK2 = "/timetodrink"
SlashCmdList["TIMETODRINK"] = function(arg)
    local cmd = string.lower(arg or "")

    if cmd == "status" then
        msg("disabled=" .. tostring(TTD.disabled) .. "  threshold=" .. TTD.threshold .. "%  cooldown=" .. TTD.cooldown ..
            "s  oom=" .. (TTD.oomEnabled and (TTD.oomThreshold .. "%") or "off") .. "  healer=" ..
            (TTD.selectedHealer or "none") .. "  inParty=" .. tostring(TTD_InFivePlayerParty()) ..
            "  raid=" .. tostring(GetNumRaidMembers() > 0))
        return
    end

    if cmd == "preview" then
        local pct = TTD_HealerPct()
        msg("Low mana: " .. TTD_Format(TTD.lowMsg, pct))
        msg("OOM" .. (TTD.oomEnabled and "" or " (off)") .. ": " .. TTD_Format(TTD.oomMsg, pct))
        msg("Healer set: " .. TTD_Format(TTD.setMsg, pct))
        return
    end

    if cmd == "test" then
        if TTD_InFivePlayerParty() then
            SendChatMessage("Time To Drink test - if you see this, chat works.", "PARTY")
            msg("sent test line to party chat.")
        else
            msg("not in a 5-man party, so nothing was sent to party chat.")
        end
        return
    end

    if cmd == "oom" then
        TTD.oomEnabled = not TTD.oomEnabled
        if TimeToDrinkOOMCheck then TTD_SetCheck(TimeToDrinkOOMCheck, TTD.oomEnabled) end
        TTD_SaveAll()
        msg("OOM alert " .. (TTD.oomEnabled and ("ON (below " .. TTD.oomThreshold .. "%)") or "OFF"))
        return
    end

    if cmd == "screen" then
        TTD.screenAlert = not TTD.screenAlert
        if TimeToDrinkScreenCheck then TTD_SetCheck(TimeToDrinkScreenCheck, TTD.screenAlert) end
        TTD_SaveAll()
        msg("on-screen warning " .. (TTD.screenAlert and "ON" or "OFF"))
        if TTD.screenAlert then TTD_ShowScreenAlert(TTD_Format(TTD.lowMsg, TTD_HealerPct()), "LOW") end
        return
    end

    if cmd == "debug" then
        TTD.debug = not TTD.debug
        msg("debug " .. (TTD.debug and "ON" or "OFF"))
        return
    end

    if cmd == "reset" then
        TTD.pos = nil
        local ok, e = pcall(function()
            TTD_CreateUI()
            TimeToDrinkUI:ClearAllPoints()
            TimeToDrinkUI:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
            TTD_ShowUI()
        end)
        if ok then msg("window reset to center of screen.") else err(e) end
        return
    end

    if cmd == "enable" then
        TTD.disabled = false
        if TimeToDrinkDisableCheck then TTD_SetCheck(TimeToDrinkDisableCheck, false) end
        msg("alerts ENABLED (pick a healer to activate).")
        return
    end

    if cmd == "disable" then
        TTD.disabled = true
        if TimeToDrinkDisableCheck then TTD_SetCheck(TimeToDrinkDisableCheck, true) end
        msg("alerts DISABLED (muted).")
        return
    end

    if cmd == "minimap" then
        TTD.mmbHidden = not TTD.mmbHidden
        TTD_CreateMinimapButton()
        if TimeToDrinkMinimapButton then
            if TTD.mmbHidden then TimeToDrinkMinimapButton:Hide() else TimeToDrinkMinimapButton:Show() end
        end
        if type(TimeToDrinkDB) == "table" then TimeToDrinkDB.mmbHidden = TTD.mmbHidden end
        msg("minimap button " .. (TTD.mmbHidden and "hidden" or "shown"))
        return
    end

    local ok, e = pcall(TTD_ToggleUI)
    if not ok then err(e) end
end

msg("loaded v1.3.4. /ttd to open, /ttd preview, /ttd oom, /ttd screen, /ttd status. (5-man parties only)")
