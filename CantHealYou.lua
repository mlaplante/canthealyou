-- CantHealYou

-- Attempts to automatically detect when you cast a healing spell or buff
-- on a friendly target who is out of line of sight or range and whisper
-- them if they're in your party, raid, or guild.
--
-- This can fail; if the target isn't in range and the interface knows
-- it, then it doesn't actually try to cast the spell, so the addon can't
-- detect the spellcast.  However, if that's the case, you should see the
-- red dot or number on the icon for the spell (in the default interface).
--
-- Range detection can be forced in a macro using the /chyw slash
-- command.  It behaves like /cast (taking [target=x] options, etc.).

-- create our frame for the listeners and make sure it's not visible
local CantHealYouFrame = CreateFrame("FRAME", nil, UIParent)
CantHealYouFrame:Hide()

local debugmode = false

-- keep track of the last time we whispered someone
local timestamp = {}

-- keep track of whether we're in combat, incapacitated, and a healer
local incombat = false
local ontaxi = 0
local incapacitated = false
local imahealer = false


local function Debug(text)
  if debugmode then
    print(text)
  end
end

local function toboolean(value)
  return not not value
end

-- Get spell name from numeric spell ID (handles both modern and legacy API)
local function GetSpellNameFromID(spellID)
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellID)
    if info then return info.name end
  end
  -- Fallback to deprecated API (removed in WoW Midnight)
  if GetSpellInfo then
    local name = GetSpellInfo(spellID)
    return name or tostring(spellID)
  end
  return tostring(spellID)
end

-- Update healer state based on current spec role.
-- Called on login, spec change, and role assignment.
-- IsInGroup() / IsInRaid() without args only check the HOME party category.
-- LFG/dungeon finder groups use LE_PARTY_CATEGORY_INSTANCE and must be checked
-- explicitly. These helpers cover both so the addon works in all group contexts.
local function IsInAnyRaid()
  return IsInRaid(LE_PARTY_CATEGORY_HOME) or IsInRaid(LE_PARTY_CATEGORY_INSTANCE)
end

local function IsInAnyGroup()
  return IsInGroup(LE_PARTY_CATEGORY_HOME) or IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
end

local function UpdateHealerState()
  local specIndex = GetSpecialization()
  if specIndex then
    local role = GetSpecializationRole(specIndex)
    imahealer = (role == "HEALER")
  else
    imahealer = false
  end
  -- Group-assigned role can override spec detection (checks home and instance groups)
  if IsInAnyGroup() then
    local _, isHealer, _ = UnitGroupRolesAssigned("player")
    if isHealer then imahealer = true end
  end
  Debug("imahealer = "..tostring(imahealer))
end


local function Whisper(who, message)
  -- if we're not active, we shouldn't be here.  But if we do get here, don't do the whisper!
  if not CHYconfig.Active then return end

  -- Only whisper if player is in a healer spec (when OnlyWhenHealer is enabled)
  if CHYconfig.OnlyWhenHealer and not imahealer then return end

  if not CHYconfig.InBattlegrounds then
    if (UnitInBattleground("player") ~= nil) then return end
  end

  -- get the name for who to whisper
  local name = GetUnitName(who, true)
  if not name then
    Debug("Whisper: could not resolve name for unit "..tostring(who))
    return
  end
  name = string.gsub(name, " ", "")

  Debug("Called Whisper for "..name.." with message "..message)
  if timestamp[name] and CHYconfig.Interval > 0 then
    local interval = time() - timestamp[name]
    Debug("last whispered "..who.." "..interval.." seconds ago")
    if interval < CHYconfig.Interval then
      -- too soon, don't whisper
      Debug("whispered "..name.." within last "..CHYconfig.Interval.." seconds, not whispering")
      return
    end
  end
  timestamp[name] = time()
  SendChatMessage(message, "WHISPER", nil, name)
end

-- tell party or raid something
local function Broadcast(message)
  local group

  if ((message == nil) or (message == "")) then
    Debug("Broadcast called with empty message.  Giving up.")
    return
  end

  Debug("Broadcast called with message: "..message)

  if UnitOnTaxi("player") then
    Debug("player is on taxi, won't broadcast")
    return
  end
  if not CHYconfig.InBattlegrounds then
    if (UnitInBattleground("player") ~= nil) then return end
  end

  if not CHYconfig.Active then
    return
  end

  -- Only broadcast if player is in a healer spec (when OnlyWhenHealer is enabled)
  if CHYconfig.OnlyWhenHealer and not imahealer then return end

  -- Check both home and instance (LFG) raid/party groups
  if IsInAnyRaid() then
    group = "RAID"
  elseif IsInAnyGroup() then
    group = "PARTY"
  else
    -- we're not in a group, no one to broadcast to
    return
  end

  -- we use the message for the timestamp, so we don't send the same message within interval seconds
  if timestamp[message] and CHYconfig.Interval > 0 then
    local interval = time() - timestamp[message]
    Debug("last broadcast "..interval.." seconds ago")
    if interval < CHYconfig.Interval then
      return
    end
  end

  -- Bug fix: was timestamp["global time"] which was never checked; must match the key we check above
  timestamp[message] = time()
  SendChatMessage(message, group)
end

local function DoTheWarn(who, spell, message)
  -- Guard against nil spell to avoid string.format crash
  if not spell then spell = "?" end

  if ((message == nil) or (message == "")) then
    Debug("DoTheWarn called for "..who.." with spell "..spell.." but no message.  Giving up.")
    return
  end

  Debug("DoTheWarn called for "..who.." with spell "..spell.." and condition "..message)
  -- don't warn yourself
  if UnitIsUnit(who, "player") then Debug(who.." is player"); return end
  -- if they can attack us, we're not healing/buffing them, so forget it
  if UnitCanAttack(who, "player") then Debug(who.." can attack player"); return end
  -- no point in trying to whisper an NPC
  if not UnitIsPlayer(who) then Debug(who.." is not a player"); return end
  -- are we only doing our party/raid/guild?
  if CHYconfig.OnlyPartyRaidGuild then
    if not (UnitInParty(who) or UnitInRaid(who) or UnitIsInMyGuild(who)) then
      Debug(who.." is not in party, raid or guild")
      return
    end
  end
  -- if we make it here, all "don't tell them" tests were passed
  Debug("whisper "..who)
  Whisper(who, string.format(message, spell))
end

-- castGUID replaces rank (spell ranks were removed in modern WoW)
-- targetUnit stores a unit token ("target", "mouseover", etc.) — never a secret string
local currentspell = { ["spell"] = nil, ["castGUID"] = nil, ["targetUnit"] = nil }

local function SetDefault(key, value)
  Debug("checking to see if "..key.." is set")
  if ((CHYconfig[key] == nil) or (CHYconfig[key] == "")) then
    Debug("was not set - setting to "..tostring(value))
    CHYconfig[key] = value
  end
  if CantHealYou_Config[key] == nil then
    CantHealYou_Config[key] = value
  end
end

local function SetAllDefaults()
  SetDefault("OnlyPartyRaidGuild", true)
  SetDefault("Active", true)
  SetDefault("InBattlegrounds", true)
  SetDefault("OnlyWhenHealer", false)
  SetDefault("DoOutOfRange", true)
  SetDefault("OutOfRange", CHYstrings.OutOfRange)
  SetDefault("DoLineOfSight", true)
  SetDefault("LineOfSight", CHYstrings.LineOfSight)
  SetDefault("DoLostControl", false)
  SetDefault("LostControl", CHYstrings.LostControl)
  SetDefault("GainedControl", CHYstrings.GainedControl)
  SetDefault("DoAuraBounced", false)
  SetDefault("AuraBounced", CHYstrings.AuraBounced)
  SetDefault("DoInterrupted", false)
  SetDefault("Interrupted", CHYstrings.Interrupted)
  SetDefault("Interval", 10)
end

function CantHealYou_OnEvent(self, event, arg1, arg2, arg3, arg4)
    Debug("Event received: "..event)
    -- Modern WoW uses ADDON_LOADED (with addon name check) instead of VARIABLES_LOADED
    if event == "ADDON_LOADED" and arg1 == "CantHealYou" then
      -- older versions had "CantHealYou_Config", which is now used for global default config
      -- if we don't have a per-character config (CHYconfig), but do have global, set
      -- per-character to the global config.  If we don't have a global config, create an
      -- empty one.

      -- workaround for "disappearing config" problem.  First, check to see
      -- if all the config strings are "".  If they are, assume we have
      -- a "disappeared" config, and set the configuration to nil so the
      -- initialization code can create a new config.
      if CantHealYou_Config then
        if CantHealYou_Config["OutOfRange"] == "" and CantHealYou_Config["LineOfSight"] == "" then
          CantHealYou_Config = nil
        end
      end
      if CHYconfig then
        if CHYconfig["OutOfRange"] == "" and CHYconfig["LineOfSight"] == ""
        and CHYconfig["LostControl"] == "" and CHYconfig["GainedControl"] == ""
        and CHYconfig["AuraBounced"] == "" and CHYconfig["Interrupted"] == "" then
          CHYconfig = nil
        end
      end

      if not CHYconfig and CantHealYou_Config then
        -- we copy each key/value pair in CantHealYou_Config to CHYconfig
        -- because CHYconfig = CantHealYou_Config would make them both
        -- point to the same table, and any alteration done to one would
        -- happen to the other
        local key, value
        CHYconfig = {}
        for key, value in pairs(CantHealYou_Config) do
          CHYconfig[key] = value
        end
      else
        CantHealYou_Config = {}
      end
      if not CHYconfig then
        -- no config exists, create an empty config
        CHYconfig = {}
      end
      -- set defaults (only those that don't have values will be set)
      SetAllDefaults()
      -- update the version number (use modern C_AddOns API if available)
      if C_AddOns and C_AddOns.GetAddOnMetadata then
        CHYconfig.Version = C_AddOns.GetAddOnMetadata("CantHealYou", "Version")
      elseif GetAddOnMetadata then
        -- Fallback to deprecated API (removed in WoW Midnight)
        CHYconfig.Version = GetAddOnMetadata("CantHealYou", "Version")
      end
      CantHealYouFrame:UnregisterEvent("ADDON_LOADED")
      -- Register in the addon compartment (minimap addon button, 10.0+)
      if AddonCompartmentFrame then
        AddonCompartmentFrame:RegisterAddon({
          text = "Can't Heal You",
          icon = "Interface\\Icons\\Spell_Holy_HolyBolt",
          notCheckable = true,
          func = function() CantHealYou_slash("") end,
        })
      end
    elseif event == "UNIT_SPELLCAST_SENT" then
        -- Modern WoW args: (unit, target, castGUID, spellID)
        -- Note: spellID is now numeric; spell ranks no longer exist
        -- arg2 is the target name but may be a "secret string" in modern WoW that cannot
        -- be compared with ==. Use GetUnitName("target") instead to get a regular string.
        if arg1 == "player" then
            -- Store unit token only (never store secret strings from GetUnitName)
            -- Prefer "mouseover" for [@mouseover] heal macros when it's a different friendly unit
            if UnitExists("mouseover") and not UnitIsUnit("mouseover", "target") and
               UnitIsFriend("player", "mouseover") and not UnitIsUnit("mouseover", "player") then
                currentspell.targetUnit = "mouseover"
            else
                currentspell.targetUnit = "target"
            end
            currentspell.castGUID = arg3
            currentspell.spell = GetSpellNameFromID(arg4)
            Debug(arg1.." is casting "..tostring(currentspell.spell).." on unit "..tostring(currentspell.targetUnit))
        end
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
        -- Modern WoW args: (unit, castGUID, spellID)
        -- NOTE: Do NOT clear currentspell here. UNIT_SPELLCAST_FAILED fires BEFORE
        -- UI_ERROR_MESSAGE, so clearing here would wipe the target before we can warn them.
        -- currentspell is cleared in UI_ERROR_MESSAGE (after warning) and in the stop/succeeded handler.
        if arg1 == "player" and arg2 == currentspell.castGUID then
            Debug("cast of "..tostring(currentspell.spell).." on "..tostring(currentspell.targetUnit).." failed (waiting for UI_ERROR_MESSAGE)")
        end
    elseif event == "UI_ERROR_MESSAGE" then
        local message

        -- Modern WoW (8.0+): args are (errorType, message) - error string is in arg2
        -- Legacy WoW: arg was (message) - error string was in arg1
        -- We check arg2 first; fall back to arg1 for compatibility
        local errMsg = arg2 or arg1

        Debug("error received: "..tostring(errMsg))
        if errMsg == ERR_OUT_OF_RANGE then
          if not CHYconfig.DoOutOfRange then return end
          message = CHYconfig.OutOfRange
        elseif errMsg == SPELL_FAILED_LINE_OF_SIGHT then
          if not CHYconfig.DoLineOfSight then return end
          message = CHYconfig.LineOfSight
        elseif errMsg == SPELL_FAILED_AURA_BOUNCED then
          if not CHYconfig.DoAuraBounced then return end
          message = CHYconfig.AuraBounced
        elseif errMsg == SPELL_FAILED_INTERRUPTED or errMsg == SPELL_FAILED_INTERRUPTED_COMBAT then
          if GetUnitSpeed("player") == 0 and incombat then
            -- player isn't moving, we'll assume something else interrupted
            Debug("interrupted!")
            if not CHYconfig.DoInterrupted then return end
            message = CHYconfig.Interrupted
          end
        else
          Debug("error does not match any condition")
          return
        end
        -- we only reach here if we didn't hit the default "else"
        -- targetUnit is a unit token — pass directly, no secret string comparison needed
        if currentspell.targetUnit then
          Debug("warning unit "..tostring(currentspell.targetUnit))
          DoTheWarn(currentspell.targetUnit, currentspell.spell, message)
          currentspell.spell = nil
          currentspell.castGUID = nil
          currentspell.targetUnit = nil
        end
    elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
      -- entering or leaving combat, so clear timers
      timestamp = {}
      if event == "PLAYER_REGEN_DISABLED" then
        Debug("entering combat")
        incombat = true
      else
        Debug("leaving combat")
        incombat = false
      end
    elseif event == "PLAYER_ENTERING_WORLD" then
      -- GetSpecialization() is not reliable during ADDON_LOADED; update here
      -- once the player is fully in the world
      UpdateHealerState()
    elseif event == "PLAYER_ROLES_ASSIGNED" then
      Debug("role assigned")
      UpdateHealerState()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
      Debug("spec changed")
      UpdateHealerState()
    elseif event == "TAXIMAP_CLOSED" then
      -- when WoW puts you on a taxi, it sends PLAYER_CONTROL_LOST before
      -- UnitOnTaxi("player") will return true.  Thus, we have to use this
      -- fake to detect whether control was lost because of using a
      -- flight master.
      ontaxi = time()
    elseif event == "PLAYER_CONTROL_LOST" then
      if ((time() - ontaxi) < 2) then
        Debug("Control lost within 2 seconds of closing taxi map - will assume is due to flight")
        return
      end
      if incapacitated then return else incapacitated = true end
      if not CHYconfig.DoLostControl then return end
      Broadcast(CHYconfig.LostControl)
    elseif event == "PLAYER_CONTROL_GAINED" or event == "PLAYER_DEAD" then
      if not incapacitated then return else incapacitated = false end
      if not CHYconfig.DoLostControl then return end
      -- Bug fix: was CHYconfig.ControlRegained (key doesn't exist); correct key is GainedControl
      Broadcast(CHYconfig.GainedControl)
    else
        -- UNIT_SPELLCAST_STOP, UNIT_SPELLCAST_CHANNEL_STOP, or UNIT_SPELLCAST_SUCCEEDED
        -- Modern WoW args: (unit, castGUID, spellID)
        if arg1 == "player" and arg2 == currentspell.castGUID then
            -- looks to be the spell we're keeping, so release it
            Debug("cast of "..tostring(currentspell.spell).." on "..tostring(currentspell.targetUnit).." ended")
            currentspell.spell = nil
            currentspell.castGUID = nil
            currentspell.targetUnit = nil
        end
        if incapacitated then
          incapacitated = false
          if CHYconfig.DoLostControl then
            -- Bug fix: was CHYconfig.ControlRegained; correct key is GainedControl
            Broadcast(CHYconfig.GainedControl)
          end
        end
    end
end

function CantHealYou_warn(str)
  local spell, target = SecureCmdOptionParse(str)
  if not spell or spell == "" then
    print("Can't Heal You: Usage: /chyw [spell name]")
    return
  end
  if not target then
    -- Prefer mouseover if it's a valid friendly unit (supports mouseover heal macros)
    if UnitExists("mouseover") and UnitIsFriend("player", "mouseover") and not UnitIsUnit("mouseover", "player") then
      target = "mouseover"
    else
      target = "target"
    end
  end
  Debug("testing range for "..spell.." on "..target)
  local inRange
  if C_Spell and C_Spell.IsSpellInRange then
    inRange = C_Spell.IsSpellInRange(spell, target)
  elseif IsSpellInRange then
    -- Fallback to deprecated API (removed in WoW Midnight)
    inRange = IsSpellInRange(spell, target)
  end
  -- Handle both modern (true/false) and legacy (1/0) return values
  if inRange == false or inRange == 0 then
    DoTheWarn(target, spell, CHYconfig.OutOfRange)
  end
end

function CantHealYou_slash(str)
  local cmd = string.lower(str)

  if cmd == "" then
    if CantHealYouOptions:IsShown() then
      CantHealYouOptions:Hide()
    else
      CantHealYouOptions_OnShow()
      CantHealYouOptions:Show()
    end
  elseif cmd == "help" then
    print("|cff00ccffCan't Heal You|r v"..tostring(CHYconfig and CHYconfig.Version or "?").." commands:")
    print("  |cffffff00/chy|r — open/close options panel")
    print("  |cffffff00/chy help|r — show this help text")
    print("  |cffffff00/chy debug|r — toggle debug mode")
    print("  |cffffff00/chy reset|r — reset this character's config to defaults")
    print("  |cffffff00/chy resetall|r — reset all characters' config to defaults")
    print("  |cffffff00/chyw [spell]|r — manually test if target is in range of [spell]")
  elseif cmd == "debug" then
    debugmode = not debugmode
    if debugmode then
      print("Can't Heal You: Debug on.")
    else
      print("Can't Heal You: Debug off.")
    end
  elseif cmd == "reset" or cmd == "resetall" then
    CHYconfig = {}
    if cmd == "resetall" then
      CantHealYou_Config = {}
    end
    SetAllDefaults()
    print("Can't Heal You: Config reset.")
  else
    print("Can't Heal You: Unknown command '"..str.."'. Type /chy help for commands.")
  end
end

SLASH_CHYMAIN1 = "/chy"
SlashCmdList["CHYMAIN"] = CantHealYou_slash

SLASH_CHYWARN1 = "/chyw"
SlashCmdList["CHYWARN"] = CantHealYou_warn

CantHealYouFrame:SetScript("OnEvent", CantHealYou_OnEvent)
-- Use ADDON_LOADED instead of deprecated VARIABLES_LOADED
CantHealYouFrame:RegisterEvent("ADDON_LOADED")
CantHealYouFrame:RegisterEvent("UNIT_SPELLCAST_SENT")
CantHealYouFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")
CantHealYouFrame:RegisterEvent("UNIT_SPELLCAST_FAILED_QUIET")
CantHealYouFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
CantHealYouFrame:RegisterEvent("UNIT_SPELLCAST_STOP")
-- Fixed: was UNIT_SPELLCAST_CHANNELED_STOP (typo) in original
CantHealYouFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
CantHealYouFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
CantHealYouFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
CantHealYouFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
CantHealYouFrame:RegisterEvent("PLAYER_CONTROL_LOST")
CantHealYouFrame:RegisterEvent("PLAYER_CONTROL_GAINED")
CantHealYouFrame:RegisterEvent("PLAYER_DEAD")
CantHealYouFrame:RegisterEvent("UI_ERROR_MESSAGE")
CantHealYouFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
CantHealYouFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
-- Note: TAXIMAP_OPENED removed (was registered but had no handler)
CantHealYouFrame:RegisterEvent("TAXIMAP_CLOSED")

-- END OF MAIN CODE.  From here down, this is stuff for the options
-- dialog

local function ShowOptionValue(name)
  local mytype = type(CHYconfig[name])
  local UIvar = _G["CantHealYouOptions"..name]

  Debug("type of "..name.." is "..mytype)

  -- Guard: if no matching widget exists for this config key, skip silently
  if not UIvar then return end

  -- all our boolean variables are displayed in checkboxes
  if mytype == "boolean" then
    UIvar:SetChecked(CHYconfig[name])
  elseif mytype == "number" then
    UIvar:SetText(tostring(CHYconfig[name]))
  elseif mytype == "string" then
    UIvar:SetText(CHYconfig[name] or "")
  else
    if UIvar.SetText then UIvar:SetText("") end
  end
end


function CantHealYouOptions_OnShow()
  ShowOptionValue("OnlyPartyRaidGuild")
  ShowOptionValue("Active")
  ShowOptionValue("InBattlegrounds")
  ShowOptionValue("DoOutOfRange")
  ShowOptionValue("OutOfRange")
  ShowOptionValue("DoLineOfSight")
  ShowOptionValue("LineOfSight")
  ShowOptionValue("DoInterrupted")
  ShowOptionValue("Interrupted")
  ShowOptionValue("DoLostControl")
  ShowOptionValue("LostControl")
  ShowOptionValue("GainedControl")
  ShowOptionValue("DoAuraBounced")
  ShowOptionValue("AuraBounced")
  ShowOptionValue("Interval")
  ShowOptionValue("Version")
end

function CantHealYouOptions_Save()
  CHYconfig.OnlyPartyRaidGuild = toboolean(CantHealYouOptionsOnlyPartyRaidGuild:GetChecked())
  CHYconfig.Active = toboolean(CantHealYouOptionsActive:GetChecked())
  CHYconfig.InBattlegrounds = toboolean(CantHealYouOptionsInBattlegrounds:GetChecked())
  CHYconfig.OnlyWhenHealer = toboolean(CantHealYouOptionsOnlyWhenHealer:GetChecked())

  CHYconfig.DoOutOfRange = toboolean(CantHealYouOptionsDoOutOfRange:GetChecked())
  CHYconfig.OutOfRange = CantHealYouOptionsOutOfRange:GetText()

  CHYconfig.DoLineOfSight = toboolean(CantHealYouOptionsDoLineOfSight:GetChecked())
  CHYconfig.LineOfSight = CantHealYouOptionsLineOfSight:GetText()

  CHYconfig.DoInterrupted = toboolean(CantHealYouOptionsDoInterrupted:GetChecked())
  CHYconfig.Interrupted = CantHealYouOptionsInterrupted:GetText()

  CHYconfig.DoLostControl = toboolean(CantHealYouOptionsDoLostControl:GetChecked())
  CHYconfig.LostControl = CantHealYouOptionsLostControl:GetText()
  CHYconfig.GainedControl = CantHealYouOptionsGainedControl:GetText()

  CHYconfig.DoAuraBounced = toboolean(CantHealYouOptionsDoAuraBounced:GetChecked())
  CHYconfig.AuraBounced = CantHealYouOptionsAuraBounced:GetText()

  CHYconfig.Interval = tonumber(CantHealYouOptionsInterval:GetText())
  if type(CHYconfig.Interval) ~= "number" then
    CHYconfig.Interval = 0
  end
end

function CantHealYouOptions_OnLoad(self)
  CantHealYouOptionsTitle:SetText(CHYstrings.UItitle)
  CantHealYouOptionsListLabel:SetText(CHYstrings.UIsendwarningsfor)
  CantHealYouOptionsIntervalLabel:SetText(CHYstrings.UIinterval)

  -- Make it a standalone draggable popup window
  self:SetMovable(true)
  self:EnableMouse(true)
  self:RegisterForDrag("LeftButton")
  self:SetScript("OnDragStart", self.StartMoving)
  self:SetScript("OnDragStop", self.StopMovingOrSizing)

  -- Apply backdrop (WoW 9.0+ requires BackdropTemplateMixin)
  if BackdropTemplateMixin then
    Mixin(self, BackdropTemplateMixin)
  end
  self:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })

  -- Close button (top right corner)
  local closeBtn = CreateFrame("Button", nil, self, "UIPanelCloseButton")
  closeBtn:SetPoint("TOPRIGHT", self, "TOPRIGHT", -5, -5)
  closeBtn:SetScript("OnClick", function() self:Hide() end)

  -- Save & Close button (bottom right)
  local saveBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
  saveBtn:SetSize(120, 22)
  saveBtn:SetText("Save & Close")
  saveBtn:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -20, 10)
  saveBtn:SetScript("OnClick", function()
    CantHealYouOptions_Save()
    self:Hide()
  end)

  -- Also register with the Settings API so Game Menu → Interface → AddOns works
  if Settings and Settings.RegisterCanvasLayoutCategory then
    local category = Settings.RegisterCanvasLayoutCategory(self, "Can't Heal You")
    Settings.RegisterAddOnCategory(category)
    self.OnCommit = function() CantHealYouOptions_Save() end
    self.OnRefresh = function() CantHealYouOptions_OnShow() end
    self.OnDefault = function() end
  else
    -- Fallback to deprecated InterfaceOptions API (removed in WoW 10.0+)
    if InterfaceOptions_AddCategory then
      self.name = "Can't Heal You"
      self.okay = function() CantHealYouOptions_Save() end
      self.cancel = nil
      InterfaceOptions_AddCategory(self)
    end
  end
end

function CantHealYouOptions_CheckButtonText(self, text, tooltiptext)
  -- In modern WoW, UICheckButtonTemplate may expose the text label as self.text
  -- rather than a global named $parentText. Try both.
  local textobj = _G[self:GetName().."Text"] or self.text
  if textobj and text then
    textobj:SetText(text)
  elseif text then
    -- Last resort: set it on the button itself (Button:SetText is always available)
    self:SetText(text)
  end
  self.tooltipText = tooltiptext
  -- Modern WoW: the old InterfaceOptions system no longer reads tooltipText automatically,
  -- so wire up tooltip display manually.
  if tooltiptext then
    self:SetScript("OnEnter", function(btn)
      GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
      GameTooltip:SetText(btn.tooltipText, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    self:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
  end
end
