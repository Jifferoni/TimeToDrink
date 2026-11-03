--[[--------------------------------------------------------------------
  Time To Drink  -  Octowow / vanilla 1.12 addon   v1.4.3
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
    fs:SetFont("Interface\\AddOns\\TimeToDrink\\Fonts\\PirataOne-Regular.ttf", 36, "THICKOUTLINE")
    if fs.GetFont and not fs:GetFont() then fs:SetFont("Fonts\\FRIZQT__.TTF", 26, "THICKOUTLINE") end
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

-- ===== UI look =====
-- Flat dark panel, live mana bar, sliders and switches. Two tabs:
-- Settings and Messages. Built only from 1.12 widgets.
local FONT       = "Fonts\\FRIZQT__.TTF"
local TITLE_FONT = "Interface\\AddOns\\TimeToDrink\\Fonts\\PirataOne-Regular.ttf"
local WHITE      = "Interface\\Buttons\\WHITE8X8"
local BAR_TEX    = "Interface\\TargetingFrame\\UI-StatusBar"
local THUMB_TEX  = "Interface\\Buttons\\UI-SliderBar-Button-Horizontal"

local W, PAD   = 400, 20
local CW       = W - PAD * 2
local HEAD_H   = 76
local BODY_TOP = 118           -- content starts below header + tab bar
local FOOT_H   = 44
local H        = 576
local GAP      = 5             -- Low always stays this far above OOM
local MAX_CD   = 300
local CD_STEP  = 5

local C = {
    bg     = { 0.06, 0.07, 0.09, 0.97 },
    panel2 = { 0.10, 0.11, 0.14, 1 },
    field  = { 0.04, 0.05, 0.07, 1 },
    border = { 0.33, 0.27, 0.13, 1 },
    line   = { 0.17, 0.18, 0.22, 1 },
    gold   = { 1.00, 0.83, 0.36 },
    text   = { 0.93, 0.91, 0.86 },
    muted  = { 0.66, 0.64, 0.57 },
    blue   = { 0.27, 0.58, 1.00 },
    amber  = { 1.00, 0.70, 0.22 },
    red    = { 0.95, 0.30, 0.32 },
    green  = { 0.40, 0.80, 0.40 },
    chat   = { 0.56, 0.79, 1.00 },
}

local FLAT = {
    bgFile = WHITE, edgeFile = WHITE, tile = false, tileSize = 0, edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

local function Skin(f, bg, border)
    f:SetBackdrop(FLAT)
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

local function Text(parent, size, color, flags, font)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(font or FONT, size, flags or "")
    if font and fs.GetFont and not fs:GetFont() then fs:SetFont(FONT, size, flags or "") end  -- bundled font missing
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetJustifyH("LEFT")
    return fs
end

local function Tex(parent, layer, col, a)
    local t = parent:CreateTexture(nil, layer)
    t:SetTexture(col[1], col[2], col[3], a or col[4] or 1)
    return t
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Mana bar with OOM / Low zones and marker lines
local function MakeManaBar(parent, w, h)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(w); bar:SetHeight(h)
    Skin(bar, C.field, { 0, 0, 0, 1 })
    local inner = w - 2

    local oomZone = Tex(bar, "BACKGROUND", C.red, 0.22)
    oomZone:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
    oomZone:SetHeight(h - 2)
    local lowZone = Tex(bar, "BACKGROUND", C.amber, 0.15)
    lowZone:SetHeight(h - 2)

    local sb = CreateFrame("StatusBar", nil, bar)
    sb:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
    sb:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
    sb:SetStatusBarTexture(BAR_TEX)
    sb:SetMinMaxValues(0, 100)
    sb:SetValue(0)
    sb:SetStatusBarColor(C.blue[1], C.blue[2], C.blue[3])

    local over = CreateFrame("Frame", nil, bar)
    over:SetAllPoints(bar)
    over:SetFrameLevel(sb:GetFrameLevel() + 2)
    local shine = Tex(over, "ARTWORK", { 1, 1, 1 }, 0.10)
    shine:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
    shine:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -1, -1)
    shine:SetHeight(math.floor(h / 2))
    local oomLine = Tex(over, "OVERLAY", C.red, 1);   oomLine:SetWidth(2); oomLine:SetHeight(h + 4)
    local lowLine = Tex(over, "OVERLAY", C.amber, 1); lowLine:SetWidth(2); lowLine:SetHeight(h + 4)
    local oomLabel = Text(bar, 11, C.red, "OUTLINE")
    local lowLabel = Text(bar, 11, C.amber, "OUTLINE")

    function bar.SetThresholds(self, low, oom, oomOn)
        local xo = math.max(1, math.floor(inner * oom / 100))
        local xl = math.max(xo + 1, math.floor(inner * low / 100))
        oomZone:SetWidth(xo)
        lowZone:ClearAllPoints()
        lowZone:SetPoint("TOPLEFT", bar, "TOPLEFT", 1 + xo, -1)
        lowZone:SetWidth(xl - xo)
        oomLine:ClearAllPoints(); oomLine:SetPoint("TOP", bar, "TOPLEFT", 1 + xo, 2)
        lowLine:ClearAllPoints(); lowLine:SetPoint("TOP", bar, "TOPLEFT", 1 + xl, 2)
        -- OOM label sits left of its line, Low label right of its line. Each is
        -- measured and nudged so it stays inside the bar and they never overlap.
        lowLabel:SetText("Low " .. low .. "%")
        oomLabel:SetText("OOM " .. oom .. "%")
        local oomRight = xo - 2
        if oomOn then
            local ow = oomLabel:GetStringWidth() or 50
            if oomRight < ow then oomRight = ow end               -- keep inside left edge
            oomLabel:Show(); oomLine:Show(); oomZone:Show()
        else
            oomRight = 0
            oomLabel:Hide(); oomLine:Hide(); oomZone:Hide()
        end
        local lowLeft = xl + 4
        if lowLeft < oomRight + 6 then lowLeft = oomRight + 6 end  -- never collide
        local lw = lowLabel:GetStringWidth() or 50
        if lowLeft + lw > w then lowLeft = w - lw end              -- keep inside right edge
        oomLabel:ClearAllPoints(); oomLabel:SetPoint("TOPRIGHT", bar, "BOTTOMLEFT", oomRight, -3)
        lowLabel:ClearAllPoints(); lowLabel:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", lowLeft, -3)
    end

    function bar.SetMana(self, pct, low, oom, oomOn)
        sb:SetValue(pct or 0)
        local col = C.blue
        if pct then
            if oomOn and pct < oom then col = C.red elseif pct < low then col = C.amber end
        end
        sb:SetStatusBarColor(col[1], col[2], col[3])
    end
    return bar
end

-- Slider with a colored fill. onChange(v) returns the value it accepted.
local function MakeSlider(parent, name, w, col, minV, maxV, onChange)
    local s = CreateFrame("Slider", name, parent)
    s.quiet = true
    s:SetOrientation("HORIZONTAL")
    s:SetWidth(w); s:SetHeight(17)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(1)
    s:SetThumbTexture(THUMB_TEX)
    s:EnableMouseWheel(true)

    local track = Tex(s, "BACKGROUND", C.line, 1)
    track:SetPoint("LEFT", s, "LEFT", 0, 0); track:SetPoint("RIGHT", s, "RIGHT", 0, 0); track:SetHeight(6)
    local fill = Tex(s, "ARTWORK", col, 1)
    fill:SetPoint("LEFT", track, "LEFT", 0, 0); fill:SetHeight(6)

    local function paint(v)
        -- the thumb (32px) travels inside the slider, so its center runs 16 .. w-16
        fill:SetWidth(math.max(1, 16 + (w - 32) * (v - minV) / (maxV - minV)))
    end
    s.paint = paint
    function s.SetQuiet(self, v)
        s.quiet = true
        s:SetValue(v)
        s.quiet = false
        paint(v)
    end
    s:SetScript("OnValueChanged", function()
        local v = math.floor(arg1 + 0.5)
        paint(v)
        if s.quiet then return end
        local accepted = onChange(v)
        if accepted and accepted ~= v then s:SetQuiet(accepted) end
    end)
    s:SetScript("OnMouseWheel", function()
        s:SetValue(Clamp(math.floor(s:GetValue() + 0.5) + arg1, minV, maxV))
    end)
    return s
end

local function MakeBadge(parent, col, bg)
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(50); f:SetHeight(20)
    Skin(f, bg, { col[1] * 0.5, col[2] * 0.5, col[3] * 0.5, 1 })
    f.text = Text(f, 12, col)
    f.text:SetPoint("CENTER", f, "CENTER", 0, 0)
    return f
end

local function MakeFlatButton(parent, w, h, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(w); b:SetHeight(h)
    Skin(b, C.panel2, C.border)
    b.text = Text(b, 12, C.text)
    b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.text:SetText(label)
    b:SetScript("OnClick", function() onClick(b) end)
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1) end)
    b:SetScript("OnLeave", function()
        if b.selected then b:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1)
        else b:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1) end
    end)
    function b.SetSelected(self, sel)
        b.selected = sel
        if sel then
            b:SetBackdropColor(0.23, 0.20, 0.13, 1)
            b:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 1)
            b.text:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        else
            b:SetBackdropColor(C.panel2[1], C.panel2[2], C.panel2[3], 1)
            b:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
            b.text:SetTextColor(C.text[1], C.text[2], C.text[3])
        end
    end
    return b
end

-- On/off switch row: label on the left, switch on the right
local function MakeToggle(parent, w, label, hint, get, set)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(w); b:SetHeight(26)
    local l = Text(b, 13, C.text)
    l:SetPoint("LEFT", b, "LEFT", 0, 0)
    if hint then l:SetText(label .. "  |cffa8a392" .. hint .. "|r") else l:SetText(label) end
    local track = CreateFrame("Frame", nil, b)
    track:SetWidth(40); track:SetHeight(20)
    track:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    track:EnableMouse(false)
    local knob = Tex(track, "OVERLAY", { 0.96, 0.95, 0.91 }, 1)
    knob:SetWidth(16); knob:SetHeight(16)
    function b.Refresh(self)
        local on = get()
        if on then Skin(track, { 0.22, 0.45, 0.22, 1 }, { 0.37, 0.68, 0.35, 1 })
        else Skin(track, C.line, { 0.23, 0.24, 0.28, 1 }) end
        knob:ClearAllPoints()
        if on then knob:SetPoint("RIGHT", track, "RIGHT", -2, 0)
        else knob:SetPoint("LEFT", track, "LEFT", 2, 0) end
    end
    b:SetScript("OnClick", function()
        set(not get())
        b:Refresh()
        TTD_SaveAll()
        TTD_UpdateReadout()
    end)
    b:Refresh()
    return b
end

local function HeaderIcon(parent, texture)
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(40); f:SetHeight(40)
    Skin(f, { 0, 0, 0, 1 }, { 0.66, 0.53, 0.18, 1 })
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
    t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    t:SetTexture(texture)
    t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    return f
end

-- Message box: commits on Enter / click-away, Escape cancels, empty = default
local function MakeMessageBox(parent, name, y, label, getVal, setVal)
    local l = Text(parent, 12, C.text)
    l:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    l:SetText(label)

    local e = CreateFrame("EditBox", name, parent)
    e:SetWidth(CW); e:SetHeight(26)
    e:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y - 16)
    Skin(e, C.field, C.border)
    e:SetFont(FONT, 12, "")
    e:SetTextColor(C.text[1], C.text[2], C.text[3])
    e:SetTextInsets(8, 8, 0, 0)
    e:SetAutoFocus(false)
    e:SetMaxLetters(MAX_MSG_LEN)
    e:SetText(getVal())

    local pv = Text(parent, 11, C.chat)
    pv:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD + 2, y - 47)
    pv:SetWidth(CW - 4); pv:SetHeight(14)
    e.preview = pv
    function e.UpdatePreview(self, fromBox)
        local tmpl = getVal()
        if fromBox then tmpl = e:GetText() end
        pv:SetText("[Party] " .. TTD_Format(tmpl, TTD_HealerPct()))
    end

    -- NOTE: never call ClearFocus() from OnEditFocusLost on 1.12 (stack overflow)
    local busy = false
    local function commit()
        if busy then return end
        busy = true
        setVal(e:GetText())
        e:SetText(getVal())
        e:UpdatePreview(false)
        TTD_SaveAll()
        busy = false
    end
    e:SetScript("OnEnterPressed", function() commit(); e:ClearFocus() end)
    e:SetScript("OnEditFocusLost", function() commit() end)
    e:SetScript("OnEditFocusGained", function() TTD.lastBox = e end)
    e:SetScript("OnEscapePressed", function()
        busy = true
        e:SetText(getVal())
        e:ClearFocus()
        e:UpdatePreview(false)
        busy = false
    end)
    e:SetScript("OnTextChanged", function() e:UpdatePreview(true) end)
    e.getVal = getVal
    return e
end

-- ===== Build the window =====
local function TTD_CreateUI()
    if TimeToDrinkUI then return end

    local f = CreateFrame("Frame", "TimeToDrinkUI", UIParent)
    f:SetWidth(W); f:SetHeight(H)
    Skin(f, C.bg, C.border)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    if TTD.pos and TTD.pos.point and TTD.pos.relPoint and TTD.pos.x and TTD.pos.y then
        f:SetPoint(TTD.pos.point, UIParent, TTD.pos.relPoint, TTD.pos.x, TTD.pos.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() if not TTD.locked then f:StartMoving() end end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        TTD.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    f:Hide()
    table.insert(UISpecialFrames, "TimeToDrinkUI")   -- Escape closes it

    -- Header ----------------------------------------------------------
    local head = CreateFrame("Frame", nil, f)
    head:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    head:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    head:SetHeight(HEAD_H)
    Skin(head, C.panel2, { 0, 0, 0, 0 })
    local hl = Tex(f, "ARTWORK", C.border, 1)
    hl:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, 0)
    hl:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", 0, 0)
    hl:SetHeight(1)

    -- Title + tagline form one centered block. The icons sit outside the WIDER
    -- of the two lines with a fixed buffer, so they never cover any text.
    local ICON, BUFFER, CORNER = 40, 18, 34     -- CORNER = room kept for the corner buttons
    local maxHalf = W / 2 - ICON - CORNER       -- widest the text block may be (half)
    -- The 1.12 engine caps how large it draws a font, so a bigger font size
    -- alone can't enlarge the title. Instead the title lives in its own small
    -- frame that is scaled up. TITLE_SCALE is the knob for title size.
    local TITLE_SCALE = 1.5
    local titleSize, tagSize = 30, 11
    -- Vertical placement, measured from the header's center line (= icon center).
    -- Positive is up. Tweak these two numbers to nudge the lines.
    local TITLE_Y, TAG_Y = 10, -17

    local tframe = CreateFrame("Frame", nil, head)
    tframe:SetScale(TITLE_SCALE)
    tframe:SetWidth(W / TITLE_SCALE); tframe:SetHeight(60)
    -- a scaled frame's offsets are in its own (scaled) units, hence the division
    tframe:SetPoint("CENTER", head, "CENTER", 0, TITLE_Y / TITLE_SCALE)
    local title = Text(tframe, titleSize, C.gold, "OUTLINE", TITLE_FONT)
    title:SetShadowColor(0, 0, 0, 0.8)
    title:SetShadowOffset(0, -2)
    title:SetText("Time To Drink")
    title:SetPoint("CENTER", tframe, "CENTER", 0, 0)

    local tag = Text(head, tagSize, C.muted)
    tag:SetText("Keep your healer hydrated")
    tag:SetPoint("CENTER", head, "CENTER", 0, TAG_Y)
    -- shrink the tagline until it fits between the icons
    while tagSize > 8 and (tag:GetStringWidth() or 0) / 2 + BUFFER > maxHalf do
        tagSize = tagSize - 1
        tag:SetFont(FONT, tagSize, "")
    end
    -- title width on screen = its own width x the frame scale
    local titleW = (title:GetStringWidth() or 110) * TITLE_SCALE
    local textHalf = math.max(titleW, tag:GetStringWidth() or 120) / 2
    local offset = textHalf + BUFFER + ICON / 2
    HeaderIcon(head, "Interface\\Icons\\INV_Drink_18"):SetPoint("CENTER", head, "CENTER", -offset, 0)
    HeaderIcon(head, "Interface\\Icons\\INV_Drink_10"):SetPoint("CENTER", head, "CENTER", offset, 0)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    local lock = CreateFrame("Button", "TimeToDrinkLockButton", f)
    lock:SetWidth(24); lock:SetHeight(24)
    lock:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)   -- top-left, so it never crowds the right-hand icon
    lock:SetScript("OnClick", function() TTD.locked = not TTD.locked; TTD_UpdateLockVisual() end)
    TTD_UpdateLockVisual()

    -- Tabs --------------------------------------------------------------
    local pages = {}
    TTD.tabButtons = {}
    local function ShowTab(key)
        TTD.tab = key
        local k, p
        for k, p in pairs(pages) do if k == key then p:Show() else p:Hide() end end
        local i = 1
        while i <= table.getn(TTD.tabButtons) do
            local b = TTD.tabButtons[i]
            b:SetSelected(b.key == key)
            i = i + 1
        end
    end
    TTD.ShowTab = ShowTab
    local tabDefs = { { "settings", "Settings" }, { "messages", "Messages" } }
    local tx = PAD
    local ti = 1
    while ti <= 2 do
        local key = tabDefs[ti][1]
        local b = MakeFlatButton(f, 110, 26, tabDefs[ti][2], function() ShowTab(key) end)
        b.key = key
        b:SetPoint("TOPLEFT", f, "TOPLEFT", tx, -(HEAD_H + 8))
        tx = tx + 116
        table.insert(TTD.tabButtons, b)
        ti = ti + 1
    end
    local tl = Tex(f, "ARTWORK", C.line, 1)
    tl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(BODY_TOP - 2))
    tl:SetWidth(CW); tl:SetHeight(1)

    local function MakePage(key)
        local p = CreateFrame("Frame", nil, f)
        p:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -BODY_TOP)
        p:SetWidth(W); p:SetHeight(H - BODY_TOP - FOOT_H)
        pages[key] = p
        return p
    end

    -- ===== Settings page =====
    local s = MakePage("settings")

    local hlab = Text(s, 11, C.muted)
    hlab:SetPoint("TOPLEFT", s, "TOPLEFT", PAD, -14)
    hlab:SetText("HEALER")
    local dd = CreateFrame("Frame", "TimeToDrinkHealerDropdown", s, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", s, "TOPLEFT", PAD + 44, -2)
    UIDropDownMenu_SetWidth(200, dd)

    local nameText = Text(s, 14, C.text)
    nameText:SetPoint("TOPLEFT", s, "TOPLEFT", PAD, -46)
    local pctText = Text(s, 14, C.blue)
    pctText:SetPoint("TOPRIGHT", s, "TOPRIGHT", -PAD, -46)
    pctText:SetJustifyH("RIGHT")
    TTD.nameText, TTD.pctText = nameText, pctText

    local bar = MakeManaBar(s, CW, 24)
    bar:SetPoint("TOPLEFT", s, "TOPLEFT", PAD, -66)
    TTD.bar = bar

    -- threshold card
    local card = CreateFrame("Frame", nil, s)
    card:SetPoint("TOPLEFT", s, "TOPLEFT", PAD, -114)
    card:SetWidth(CW); card:SetHeight(124)
    Skin(card, C.panel2, C.line)
    local IW = CW - 32

    local lowLabel = Text(card, 13, C.text)
    lowLabel:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -12)
    lowLabel:SetText("Low mana alert below")
    TTD.lowBadge = MakeBadge(card, C.amber, { 0.23, 0.17, 0.05, 1 })
    TTD.lowBadge:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -9)
    TTD.lowSlider = MakeSlider(card, "TimeToDrinkLowSlider", IW, C.amber, 1, 100, function(v)
        if v < TTD.oomThreshold + GAP then v = TTD.oomThreshold + GAP end
        TTD.threshold = Clamp(v, 1, 100)
        TTD_RefreshThresholds()
        return TTD.threshold
    end)
    TTD.lowSlider:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -32)

    local oomLabel = Text(card, 13, C.text)
    oomLabel:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -62)
    oomLabel:SetText("OOM alert below")
    TTD.oomBadge = MakeBadge(card, C.red, { 0.23, 0.07, 0.08, 1 })
    TTD.oomBadge:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -59)
    TTD.oomSlider = MakeSlider(card, "TimeToDrinkOOMSlider", IW, C.red, 1, 100 - GAP, function(v)
        TTD.oomThreshold = Clamp(v, 1, 100 - GAP)
        if TTD.threshold < TTD.oomThreshold + GAP then TTD.threshold = TTD.oomThreshold + GAP end  -- push Low up
        TTD_RefreshThresholds()
        return TTD.oomThreshold
    end)
    TTD.oomSlider:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -82)
    local note = Text(card, 11, C.muted)
    note:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 8)
    note:SetText("Low always stays " .. GAP .. "% above OOM. Raising OOM pushes Low up.")

    -- repeat stepper
    local rl = Text(s, 13, C.text)
    rl:SetPoint("TOPLEFT", s, "TOPLEFT", PAD, -258)
    rl:SetText("Repeat alerts every")
    local plus = MakeFlatButton(s, 28, 24, "+", function()
        TTD.cooldown = Clamp(TTD.cooldown + CD_STEP, MIN_COOLDOWN, MAX_CD); TTD_RefreshFields(); TTD_SaveAll()
    end)
    plus:SetPoint("TOPRIGHT", s, "TOPRIGHT", -PAD, -252)
    local cdText = Text(s, 13, C.text)
    cdText:SetWidth(56); cdText:SetJustifyH("CENTER")
    cdText:SetPoint("RIGHT", plus, "LEFT", -8, 0)
    local minus = MakeFlatButton(s, 28, 24, "-", function()
        TTD.cooldown = Clamp(TTD.cooldown - CD_STEP, MIN_COOLDOWN, MAX_CD); TTD_RefreshFields(); TTD_SaveAll()
    end)
    minus:SetPoint("RIGHT", cdText, "LEFT", -8, 0)
    TTD.cdText = cdText

    -- switches
    local toggles = {
        { "Party chat alerts", nil,
          function() return not TTD.disabled end, function(v) TTD.disabled = not v end },
        { "OOM alert", "(second, lower alert)",
          function() return TTD.oomEnabled end, function(v) TTD.oomEnabled = v; TTD_RefreshThresholds() end },
        { "On-screen warning", "(only you see it)",
          function() return TTD.screenAlert end, function(v) TTD.screenAlert = v end },
        { "Play sound with warning", nil,
          function() return TTD.screenSound end, function(v) TTD.screenSound = v end },
    }
    TTD.toggles = {}
    local ty = -288
    local i = 1
    while i <= table.getn(toggles) do
        local t = toggles[i]
        local tg = MakeToggle(s, CW, t[1], t[2], t[3], t[4])
        tg:SetPoint("TOPLEFT", s, "TOPLEFT", PAD, ty)
        table.insert(TTD.toggles, tg)
        ty = ty - 28
        i = i + 1
    end

    -- ===== Messages page =====
    local m = MakePage("messages")
    local hint = Text(m, 11, C.muted)
    hint:SetPoint("TOPLEFT", m, "TOPLEFT", PAD, -12)
    hint:SetText("Click a token to insert it into the box you are editing:")
    local cx = PAD
    local tokens = { "{healer}", "{mana}", "{threshold}", "{oom}" }
    i = 1
    while i <= 4 do
        local token = tokens[i]
        local w = 18 + string.len(token) * 6
        local chip = MakeFlatButton(m, w, 22, token, function()
            local box = TTD.lastBox or TimeToDrinkLowMsgEdit
            box:SetFocus()
            box:Insert(token)
        end)
        chip.text:SetFont(FONT, 11, "")
        chip.text:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
        chip:SetPoint("TOPLEFT", m, "TOPLEFT", cx, -28)
        cx = cx + w + 6
        i = i + 1
    end

    TTD.msgBoxes = {
        MakeMessageBox(m, "TimeToDrinkLowMsgEdit", -66, "Low mana message",
            function() return TTD.lowMsg end,
            function(v) TTD.lowMsg = TTD_CleanMessage(v, DEFAULT_LOW_MSG) end),
        MakeMessageBox(m, "TimeToDrinkOOMMsgEdit", -136, "OOM message",
            function() return TTD.oomMsg end,
            function(v) TTD.oomMsg = TTD_CleanMessage(v, DEFAULT_OOM_MSG) end),
        MakeMessageBox(m, "TimeToDrinkSetMsgEdit", -206, "Healer picked message",
            function() return TTD.setMsg end,
            function(v) TTD.setMsg = TTD_CleanMessage(v, DEFAULT_SET_MSG) end),
    }
    local mh = Text(m, 11, C.muted)
    mh:SetPoint("TOPLEFT", m, "TOPLEFT", PAD, -274)
    mh:SetText("Enter saves, Escape cancels. An empty box goes back to its default.")

    local reset = MakeFlatButton(m, 150, 26, "Reset messages", function()
        TTD.lowMsg, TTD.oomMsg, TTD.setMsg = DEFAULT_LOW_MSG, DEFAULT_OOM_MSG, DEFAULT_SET_MSG
        TTD_SaveAll(); TTD_RefreshFields()
        msg("messages reset to defaults.")
    end)
    reset:SetPoint("TOPLEFT", m, "TOPLEFT", PAD, -300)
    local test = MakeFlatButton(m, 150, 26, "Test on-screen warning", function()
        TTD_ShowScreenAlert(TTD_Format(TTD.lowMsg, TTD_HealerPct()), "LOW")
    end)
    test:SetPoint("TOPRIGHT", m, "TOPRIGHT", -PAD, -300)

    -- Footer ------------------------------------------------------------
    local foot = CreateFrame("Frame", nil, f)
    foot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
    foot:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    foot:SetHeight(FOOT_H)
    Skin(foot, C.panel2, { 0, 0, 0, 0 })
    local fl = Tex(f, "ARTWORK", C.border, 1)
    fl:SetPoint("BOTTOMLEFT", foot, "TOPLEFT", 0, 0)
    fl:SetPoint("BOTTOMRIGHT", foot, "TOPRIGHT", 0, 0)
    fl:SetHeight(1)
    local status = Text(foot, 11, C.green)
    status:SetPoint("TOP", foot, "TOP", 0, -8)
    TTD.statusText = status
    local by = Text(foot, 11, { 0.72, 0.60, 0.35 })
    by:SetPoint("BOTTOM", foot, "BOTTOM", 0, 8)
    by:SetText("Updated by Jifferoni - The premiere healer")

    ShowTab(TTD.tab or "settings")
end

-- ===== Refresh helpers =====
function TTD_RefreshThresholds()
    if not TTD.lowSlider then return end
    TTD.lowSlider:SetQuiet(TTD.threshold)
    TTD.oomSlider:SetQuiet(TTD.oomThreshold)
    TTD.lowBadge.text:SetText(TTD.threshold .. "%")
    TTD.oomBadge.text:SetText(TTD.oomThreshold .. "%")
    if TTD.oomEnabled then
        TTD.oomSlider:SetAlpha(1); TTD.oomBadge:SetAlpha(1)
    else
        TTD.oomSlider:SetAlpha(0.4); TTD.oomBadge:SetAlpha(0.4)
    end
    TTD.bar:SetThresholds(TTD.threshold, TTD.oomThreshold, TTD.oomEnabled)
    TTD_SaveAll()
    TTD_UpdateReadout()
end

function TTD_RefreshFields()
    if not TimeToDrinkUI then return end
    TTD.cdText:SetText(TTD.cooldown .. " sec")
    local i = 1
    while i <= table.getn(TTD.toggles) do TTD.toggles[i]:Refresh(); i = i + 1 end
    i = 1
    while i <= table.getn(TTD.msgBoxes) do
        local e = TTD.msgBoxes[i]
        e:SetText(e.getVal())
        e:UpdatePreview(false)
        i = i + 1
    end
    TTD_RefreshThresholds()
end

function TTD_UpdateReadout()
    local st = TTD.statusText
    if st then
        local text, col
        if not TTD.selectedHealer then
            text, col = "Pick a healer to activate alerts", C.muted
        elseif GetNumRaidMembers() > 0 then
            text, col = "In a raid: alerts are off", C.muted
        elseif not TTD_InFivePlayerParty() and TTD.screenAlert then
            text, col = "Solo: on-screen warnings only", C.green
        elseif not TTD_InFivePlayerParty() then
            text, col = "Solo: alerts start when you join a party", C.muted
        elseif TTD.disabled and TTD.screenAlert then
            text, col = "Party chat off, on-screen warnings on", C.green
        elseif TTD.disabled then
            text, col = "All alerts off", C.muted
        elseif TTD.screenAlert then
            text, col = "Party + on-screen alerts active", C.green
        else
            text, col = "Party chat alerts active", C.green
        end
        st:SetText(text)
        st:SetTextColor(col[1], col[2], col[3])
    end

    if not TTD.nameText then return end
    local function grey(t)
        TTD.pctText:SetText(t)
        TTD.pctText:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
        TTD.bar:SetMana(nil, TTD.threshold, TTD.oomThreshold, TTD.oomEnabled)
    end
    if not TTD.selectedHealer then
        TTD.nameText:SetText("No healer selected")
        return grey("")
    end
    TTD.nameText:SetText(TTD.selectedHealer)
    local unit = TTD_UnitForName(TTD.selectedHealer)
    if not unit or not UnitExists(unit) then return grey("not in party") end
    if UnitPowerType(unit) ~= 0 then return grey("shapeshifted") end
    local mm = UnitManaMax(unit)
    if not mm or mm == 0 then return grey("--") end
    local pct = (UnitMana(unit) / mm) * 100
    local col = C.blue
    if TTD.oomEnabled and pct < TTD.oomThreshold then col = C.red
    elseif pct < TTD.threshold then col = C.amber end
    TTD.pctText:SetText(math.floor(pct) .. "% mana")
    TTD.pctText:SetTextColor(col[1], col[2], col[3])
    TTD.bar:SetMana(pct, TTD.threshold, TTD.oomThreshold, TTD.oomEnabled)
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
        if TTD.oomThreshold > 95 then TTD.oomThreshold = 95 end
        if TTD.threshold < TTD.oomThreshold + 5 then TTD.threshold = TTD.oomThreshold + 5 end
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
        TTD_RefreshFields()
        TTD_SaveAll()
        msg("OOM alert " .. (TTD.oomEnabled and ("ON (below " .. TTD.oomThreshold .. "%)") or "OFF"))
        return
    end

    if cmd == "screen" then
        TTD.screenAlert = not TTD.screenAlert
        TTD_RefreshFields()
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
        TTD_SaveAll(); TTD_RefreshFields(); TTD_UpdateReadout()
        msg("alerts ENABLED (pick a healer to activate).")
        return
    end

    if cmd == "disable" then
        TTD.disabled = true
        TTD_SaveAll(); TTD_RefreshFields(); TTD_UpdateReadout()
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

msg("loaded v1.4.3. /ttd to open, /ttd preview, /ttd oom, /ttd screen, /ttd status. (5-man parties only)")
