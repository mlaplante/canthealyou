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
local lowmana = false

-- Spell IDs for external cooldowns that should be announced to the group
local externalCDs = {
  [102342] = true,  -- Ironbark (Druid)
  [33206]  = true,  -- Pain Suppression (Priest)
  [86659]  = true,  -- Guardian of Ancient Kings (Holy Paladin)
  [1022]   = true,  -- Blessing of Protection (Paladin)
  [6940]   = true,  -- Blessing of Sacrifice (Paladin)
  [116849] = true,  -- Life Cocoon (Mistweaver Monk)
  [29166]  = true,  -- Innervate (Druid)
}


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

-- UnitInParty/UnitInRaid only check the HOME category; instance (LFG) group
-- members are missed. This helper checks both categories via unit token matching.
local function UnitIsInMyGroup(unit)
  if UnitInParty(unit) or UnitInRaid(unit) then return true end
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    for i = 1, 4 do
      if UnitExists("party"..i) and UnitIsUnit(unit, "party"..i) then return true end
    end
  end
  if IsInRaid(LE_PARTY_CATEGORY_INSTANCE) then
    for i = 1, 40 do
      if UnitExists("raid"..i) and UnitIsUnit(unit, "raid"..i) then return true end
    end
  end
  return false
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


local function Whisper(who, message, interval, msgType)
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

  -- per-type timestamp key: throttle each warning type independently per player
  local tsKey = name .. "_" .. (msgType or "default")
  Debug("Called Whisper for "..name.." with message "..message)
  if timestamp[tsKey] and interval and interval > 0 then
    local elapsed = time() - timestamp[tsKey]
    Debug("last whispered "..who.." "..elapsed.." seconds ago (type: "..(msgType or "default")..")")
    if elapsed < interval then
      Debug("whispered "..name.." within last "..interval.." seconds, not whispering")
      return
    end
  end
  timestamp[tsKey] = time()
  C_Timer.After(0, function()
    SendChatMessage(message, "WHISPER", nil, name)
  end)
end

-- tell party or raid something
local function Broadcast(message, interval)
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

  -- Check both home and instance (LFG) raid/party groups.
  -- Instance (LFG) parties use the INSTANCE_CHAT channel, not PARTY.
  if IsInAnyRaid() then
    group = "RAID"
  elseif IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    group = "INSTANCE_CHAT"
  elseif IsInGroup(LE_PARTY_CATEGORY_HOME) then
    group = "PARTY"
  else
    -- we're not in a group, no one to broadcast to
    return
  end

  -- use message content as timestamp key so each distinct broadcast type throttles independently
  if timestamp[message] and interval and interval > 0 then
    local elapsed = time() - timestamp[message]
    Debug("last broadcast "..elapsed.." seconds ago")
    if elapsed < interval then
      return
    end
  end

  timestamp[message] = time()
  C_Timer.After(0, function()
    SendChatMessage(message, group)
  end)
end

local function DoTheWarn(who, spell, message, interval, msgType)
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
    if not (UnitIsInMyGroup(who) or UnitIsInMyGuild(who)) then
      Debug(who.." is not in party, raid or guild")
      return
    end
  end
  -- if we make it here, all "don't tell them" tests were passed
  Debug("whisper "..who)
  Whisper(who, string.format(message, spell), interval, msgType)
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
  -- Per-message-type intervals (migrate from old single Interval if present)
  local migratedInterval = CHYconfig.Interval or 10
  SetDefault("OutOfRangeInterval", migratedInterval)
  SetDefault("LineOfSightInterval", migratedInterval)
  SetDefault("AuraBouncedInterval", 30)
  SetDefault("InterruptedInterval", migratedInterval)
  SetDefault("LostControlInterval", 30)
  -- New features
  SetDefault("DoImmune", false)
  SetDefault("Immune", CHYstrings.Immune)
  SetDefault("ImmuneInterval", 30)
  SetDefault("DoLowMana", false)
  SetDefault("LowMana", CHYstrings.LowMana)
  SetDefault("LowManaThreshold", 20)
  SetDefault("LowManaInterval", 30)
  SetDefault("DoExternalCDs", true)
  SetDefault("ExternalCD", CHYstrings.ExternalCD)
  SetDefault("ExternalCDInterval", 0)
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
            -- Priority: mouseover > focus > target
            if UnitExists("mouseover") and not UnitIsUnit("mouseover", "target") and
               UnitIsFriend("player", "mouseover") and not UnitIsUnit("mouseover", "player") then
                currentspell.targetUnit = "mouseover"
            elseif UnitExists("focus") and UnitIsFriend("player", "focus") and
               not UnitIsUnit("focus", "player") then
                currentspell.targetUnit = "focus"
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
        local msgInterval, msgType

        -- Modern WoW (8.0+): args are (errorType, message) - error string is in arg2
        -- Legacy WoW: arg was (message) - error string was in arg1
        -- We check arg2 first; fall back to arg1 for compatibility
        local errMsg = arg2 or arg1

        Debug("error received: "..tostring(errMsg))
        if errMsg == ERR_OUT_OF_RANGE then
          if not CHYconfig.DoOutOfRange then return end
          message = CHYconfig.OutOfRange
          msgInterval = CHYconfig.OutOfRangeInterval
          msgType = "outofrange"
        elseif errMsg == SPELL_FAILED_LINE_OF_SIGHT then
          if not CHYconfig.DoLineOfSight then return end
          message = CHYconfig.LineOfSight
          msgInterval = CHYconfig.LineOfSightInterval
          msgType = "lineofsight"
        elseif errMsg == SPELL_FAILED_AURA_BOUNCED then
          if not CHYconfig.DoAuraBounced then return end
          message = CHYconfig.AuraBounced
          msgInterval = CHYconfig.AuraBouncedInterval
          msgType = "aurabounced"
        elseif errMsg == SPELL_FAILED_INTERRUPTED or errMsg == SPELL_FAILED_INTERRUPTED_COMBAT then
          if GetUnitSpeed("player") == 0 and incombat then
            -- player isn't moving, we'll assume something else interrupted
            Debug("interrupted!")
            if not CHYconfig.DoInterrupted then return end
            message = CHYconfig.Interrupted
            msgInterval = CHYconfig.InterruptedInterval
            msgType = "interrupted"
          end
        elseif errMsg == SPELL_FAILED_IMMUNE or (SPELL_FAILED_TARGETS_IMMUNE and errMsg == SPELL_FAILED_TARGETS_IMMUNE) then
          if not CHYconfig.DoImmune then return end
          message = CHYconfig.Immune
          msgInterval = CHYconfig.ImmuneInterval
          msgType = "immune"
        else
          Debug("error does not match any condition")
          return
        end
        -- we only reach here if we didn't hit the default "else"
        -- targetUnit is a unit token — pass directly, no secret string comparison needed
        if currentspell.targetUnit and message then
          Debug("warning unit "..tostring(currentspell.targetUnit))
          DoTheWarn(currentspell.targetUnit, currentspell.spell, message, msgInterval, msgType)
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
        lowmana = false  -- reset low mana state on combat end
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
    elseif event == "UNIT_POWER_UPDATE" then
      if arg1 == "player" and arg2 == "MANA" then
        if not CHYconfig.DoLowMana then return end
        local maxMana = UnitPowerMax("player", Enum.PowerType.Mana)
        if maxMana and maxMana > 0 then
          local pct = (UnitPower("player", Enum.PowerType.Mana) / maxMana) * 100
          if not lowmana and pct <= CHYconfig.LowManaThreshold then
            lowmana = true
            Broadcast(CHYconfig.LowMana, CHYconfig.LowManaInterval)
          elseif lowmana and pct > (CHYconfig.LowManaThreshold + 5) then
            lowmana = false  -- hysteresis buffer to avoid rapid toggling
          end
        end
      end
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
      Broadcast(CHYconfig.GainedControl)
    else
        -- UNIT_SPELLCAST_STOP, UNIT_SPELLCAST_CHANNEL_STOP, or UNIT_SPELLCAST_SUCCEEDED
        -- Modern WoW args: (unit, castGUID, spellID)
        if arg1 == "player" and arg2 == currentspell.castGUID then
            -- Check for external cooldown announcements before clearing currentspell
            if event == "UNIT_SPELLCAST_SUCCEEDED" then
              local spellID = arg3
              if spellID and externalCDs[spellID] and CHYconfig.DoExternalCDs and currentspell.targetUnit then
                local targetName = GetUnitName(currentspell.targetUnit, true)
                if targetName and UnitIsPlayer(currentspell.targetUnit) and not UnitIsUnit(currentspell.targetUnit, "player") then
                  local spellName = currentspell.spell or GetSpellNameFromID(spellID)
                  local msg = string.format(CHYconfig.ExternalCD, spellName, targetName)
                  Broadcast(msg, CHYconfig.ExternalCDInterval)
                end
              end
            end
            -- looks to be the spell we're keeping, so release it
            Debug("cast of "..tostring(currentspell.spell).." on "..tostring(currentspell.targetUnit).." ended")
            currentspell.spell = nil
            currentspell.castGUID = nil
            currentspell.targetUnit = nil
        end
        if incapacitated then
          incapacitated = false
          if CHYconfig.DoLostControl then
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
    -- Priority: mouseover > focus > target
    if UnitExists("mouseover") and UnitIsFriend("player", "mouseover") and not UnitIsUnit("mouseover", "player") then
      target = "mouseover"
    elseif UnitExists("focus") and UnitIsFriend("player", "focus") and not UnitIsUnit("focus", "player") then
      target = "focus"
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
    DoTheWarn(target, spell, CHYconfig.OutOfRange, CHYconfig.OutOfRangeInterval, "outofrange")
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
CantHealYouFrame:RegisterEvent("UNIT_POWER_UPDATE")
-- Note: TAXIMAP_OPENED removed (was registered but had no handler)
CantHealYouFrame:RegisterEvent("TAXIMAP_CLOSED")

-- END OF MAIN CODE.  From here down, this is stuff for the options
-- dialog

-- Layout constants for the sidebar UI
local SIDEBAR_W = 160
local CONTENT_X = 170    -- SIDEBAR_W + 10
local CONTENT_W = 520    -- 700 - SIDEBAR_W - 20
local MSG_W     = 290    -- message edit box width
local INT_W     = 40     -- interval edit box width
local CB_INDENT = 10     -- checkbox x from panel left
local MSG_XOFF  = 155    -- msg TOPLEFT offset from cb TOPLEFT (column alignment)
local ROW_H     = 28     -- vertical step between rows

local CHY_ShowSection   -- forward reference: set in OnLoad, used by OnShow

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
  ShowOptionValue("OnlyWhenHealer")
  ShowOptionValue("DoOutOfRange")
  ShowOptionValue("OutOfRange")
  ShowOptionValue("OutOfRangeInterval")
  ShowOptionValue("DoLineOfSight")
  ShowOptionValue("LineOfSight")
  ShowOptionValue("LineOfSightInterval")
  ShowOptionValue("DoInterrupted")
  ShowOptionValue("Interrupted")
  ShowOptionValue("InterruptedInterval")
  ShowOptionValue("DoLostControl")
  ShowOptionValue("LostControl")
  ShowOptionValue("LostControlInterval")
  ShowOptionValue("GainedControl")
  ShowOptionValue("DoAuraBounced")
  ShowOptionValue("AuraBounced")
  ShowOptionValue("AuraBouncedInterval")
  ShowOptionValue("DoImmune")
  ShowOptionValue("Immune")
  ShowOptionValue("ImmuneInterval")
  ShowOptionValue("DoLowMana")
  ShowOptionValue("LowMana")
  ShowOptionValue("LowManaThreshold")
  ShowOptionValue("LowManaInterval")
  ShowOptionValue("DoExternalCDs")
  ShowOptionValue("ExternalCD")
  ShowOptionValue("ExternalCDInterval")
  ShowOptionValue("Version")
  if CHY_ShowSection then CHY_ShowSection("General") end
end

local function SaveInterval(key, widget)
  local val = tonumber(widget:GetText())
  CHYconfig[key] = type(val) == "number" and val or 0
end

function CantHealYouOptions_Save()
  CHYconfig.OnlyPartyRaidGuild = toboolean(CantHealYouOptionsOnlyPartyRaidGuild:GetChecked())
  CHYconfig.Active = toboolean(CantHealYouOptionsActive:GetChecked())
  CHYconfig.InBattlegrounds = toboolean(CantHealYouOptionsInBattlegrounds:GetChecked())
  CHYconfig.OnlyWhenHealer = toboolean(CantHealYouOptionsOnlyWhenHealer:GetChecked())

  CHYconfig.DoOutOfRange = toboolean(CantHealYouOptionsDoOutOfRange:GetChecked())
  CHYconfig.OutOfRange = CantHealYouOptionsOutOfRange:GetText()
  SaveInterval("OutOfRangeInterval", CantHealYouOptionsOutOfRangeInterval)

  CHYconfig.DoLineOfSight = toboolean(CantHealYouOptionsDoLineOfSight:GetChecked())
  CHYconfig.LineOfSight = CantHealYouOptionsLineOfSight:GetText()
  SaveInterval("LineOfSightInterval", CantHealYouOptionsLineOfSightInterval)

  CHYconfig.DoInterrupted = toboolean(CantHealYouOptionsDoInterrupted:GetChecked())
  CHYconfig.Interrupted = CantHealYouOptionsInterrupted:GetText()
  SaveInterval("InterruptedInterval", CantHealYouOptionsInterruptedInterval)

  CHYconfig.DoLostControl = toboolean(CantHealYouOptionsDoLostControl:GetChecked())
  CHYconfig.LostControl = CantHealYouOptionsLostControl:GetText()
  SaveInterval("LostControlInterval", CantHealYouOptionsLostControlInterval)
  CHYconfig.GainedControl = CantHealYouOptionsGainedControl:GetText()

  CHYconfig.DoAuraBounced = toboolean(CantHealYouOptionsDoAuraBounced:GetChecked())
  CHYconfig.AuraBounced = CantHealYouOptionsAuraBounced:GetText()
  SaveInterval("AuraBouncedInterval", CantHealYouOptionsAuraBouncedInterval)

  CHYconfig.DoImmune = toboolean(CantHealYouOptionsDoImmune:GetChecked())
  CHYconfig.Immune = CantHealYouOptionsImmune:GetText()
  SaveInterval("ImmuneInterval", CantHealYouOptionsImmuneInterval)

  CHYconfig.DoLowMana = toboolean(CantHealYouOptionsDoLowMana:GetChecked())
  CHYconfig.LowMana = CantHealYouOptionsLowMana:GetText()
  local threshold = tonumber(CantHealYouOptionsLowManaThreshold:GetText())
  CHYconfig.LowManaThreshold = type(threshold) == "number" and threshold or 20
  SaveInterval("LowManaInterval", CantHealYouOptionsLowManaInterval)

  CHYconfig.DoExternalCDs = toboolean(CantHealYouOptionsDoExternalCDs:GetChecked())
  CHYconfig.ExternalCD = CantHealYouOptionsExternalCD:GetText()
  SaveInterval("ExternalCDInterval", CantHealYouOptionsExternalCDInterval)
end

function CantHealYouOptions_OnLoad(self)
  self:SetSize(700, 500)

  local sections = {
    { key="General",       label="General"         },
    { key="SpellWarnings", label="Spell Warnings"  },
    { key="Status",        label="Status Warnings" },
    { key="Externals",     label="Externals"       },
  }
  local navButtons    = {}
  local contentPanels = {}

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
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile = false, tileSize = 0, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
  })
  self:SetBackdropColor(0.08, 0.09, 0.11, 0.97)
  self:SetBackdropBorderColor(0.3, 0.8, 0.9, 0.25)

  -- Register with Settings API so Game Menu → Interface → AddOns works
  if Settings and Settings.RegisterCanvasLayoutCategory then
    local category = Settings.RegisterCanvasLayoutCategory(self, "Can't Heal You")
    Settings.RegisterAddOnCategory(category)
    self.OnCommit = function() CantHealYouOptions_Save() end
    self.OnRefresh = function() CantHealYouOptions_OnShow() end
    self.OnDefault = function() end
  else
    if InterfaceOptions_AddCategory then
      self.name = "Can't Heal You"
      self.okay = function() CantHealYouOptions_Save() end
      self.cancel = nil
      InterfaceOptions_AddCategory(self)
    end
  end

  -- === Helper functions ===

  local function MakeEditBox(name, parent, width, isNumeric)
    local eb = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    eb:SetSize(width, 22)
    eb:SetAutoFocus(false)
    if isNumeric then eb:SetNumeric(true) end
    return eb
  end

  local function MakeRow(parent, anchorTo, yOff, cbName, msgName, intName, cbLabel, cbTooltip)
    local cb = CreateFrame("CheckButton", cbName, parent, "UICheckButtonTemplate")
    if anchorTo == parent then
      cb:SetPoint("TOPLEFT", parent, "TOPLEFT", CB_INDENT, yOff)
    else
      cb:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff)
    end
    CantHealYouOptions_CheckButtonText(cb, cbLabel, cbTooltip)
    local msg = MakeEditBox(msgName, parent, MSG_W, false)
    msg:SetPoint("TOPLEFT", cb, "TOPLEFT", MSG_XOFF, 3)
    local intv = MakeEditBox(intName, parent, INT_W, true)
    intv:SetPoint("LEFT", msg, "RIGHT", 10, 0)
    return cb, msg, intv
  end

  local function MakeSectionHeader(parent, text, yOff)
    local hdr = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOff)
    hdr:SetText("|cff4dcce6" .. text .. "|r")
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -3)
    line:SetSize(CONTENT_W - 10, 1)
    line:SetColorTexture(0.3, 0.8, 0.9, 0.2)
  end

  local function MakeColumnHeaders(panel)
    local m = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m:SetPoint("TOPLEFT", panel, "TOPLEFT", CB_INDENT + MSG_XOFF, -28)
    m:SetText("Message")
    local s = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    s:SetPoint("TOPLEFT", panel, "TOPLEFT", CB_INDENT + MSG_XOFF + MSG_W + 10 + 10, -28)
    s:SetText("s")
  end

  local ShowSection
  ShowSection = function(name)
    for _, sec in ipairs(sections) do
      local panel = contentPanels[sec.key]
      local btn   = navButtons[sec.key]
      if sec.key == name then
        panel:Show()
        btn._bg:SetColorTexture(0.3, 0.8, 0.9, 0.12)
        btn._lbl:SetTextColor(0.3, 0.8, 0.9, 1)
        btn._bar:Show()
        btn._active = true
      else
        panel:Hide()
        btn._bg:SetColorTexture(0, 0, 0, 0)
        btn._lbl:SetTextColor(0.65, 0.65, 0.7, 1)
        btn._bar:Hide()
        btn._active = false
      end
    end
  end
  CHY_ShowSection = ShowSection

  -- === Visual structure ===

  -- Sidebar background
  local sidebarBg = self:CreateTexture(nil, "BACKGROUND")
  sidebarBg:SetPoint("TOPLEFT", self, "TOPLEFT", 1, -1)
  sidebarBg:SetSize(SIDEBAR_W, 498)
  sidebarBg:SetColorTexture(0.05, 0.06, 0.07, 1)

  -- Title (cyan) + version (global names preserved for ShowOptionValue)
  local title = self:CreateFontString("CantHealYouOptionsTitle", "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", self, "TOPLEFT", 12, -10)
  title:SetText(CHYstrings.UItitle)
  title:SetTextColor(0.3, 0.8, 0.9, 1)

  local version = self:CreateFontString("CantHealYouOptionsVersion", "OVERLAY", "GameFontNormalSmall")
  version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)

  -- Vertical separator between sidebar and content
  local sep = self:CreateTexture(nil, "ARTWORK")
  sep:SetPoint("TOPLEFT", self, "TOPLEFT", SIDEBAR_W + 1, -1)
  sep:SetSize(1, 498)
  sep:SetColorTexture(0.2, 0.22, 0.25, 1)

  -- Close button (top right corner)
  local closeBtn = CreateFrame("Button", nil, self, "UIPanelCloseButton")
  closeBtn:SetPoint("TOPRIGHT", self, "TOPRIGHT", -5, -5)
  closeBtn:SetScript("OnClick", function() self:Hide() end)

  -- Save & Close button (bottom right)
  local saveBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
  saveBtn:SetSize(120, 22)
  saveBtn:SetText("Save & Close")
  saveBtn:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -20, 12)
  saveBtn:SetScript("OnClick", function()
    CantHealYouOptions_Save()
    self:Hide()
  end)

  -- === Content panel frames (all hidden initially) ===
  for _, sec in ipairs(sections) do
    local panel = CreateFrame("Frame", nil, self)
    panel:SetPoint("TOPLEFT", self, "TOPLEFT", CONTENT_X, -50)
    panel:SetSize(CONTENT_W, 420)
    panel:Hide()
    contentPanels[sec.key] = panel
  end

  -- === Nav buttons (stacked in sidebar) ===
  for i, sec in ipairs(sections) do
    local btn = CreateFrame("Button", nil, self)
    btn:SetSize(SIDEBAR_W - 14, 28)
    btn:SetPoint("TOPLEFT", self, "TOPLEFT", 7, -58 - (i-1)*32)
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(btn); bg:SetColorTexture(0, 0, 0, 0); btn._bg = bg
    local bar = btn:CreateTexture(nil, "OVERLAY")
    bar:SetSize(3, 18); bar:SetPoint("LEFT", btn, "LEFT", 0, 0)
    bar:SetColorTexture(0.3, 0.8, 0.9, 1); bar:Hide(); btn._bar = bar
    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("LEFT", btn, "LEFT", 10, 0); lbl:SetText(sec.label)
    lbl:SetTextColor(0.65, 0.65, 0.7, 1); btn._lbl = lbl
    btn:SetScript("OnEnter", function(b) if not b._active then b._bg:SetColorTexture(0.3, 0.8, 0.9, 0.07) end end)
    btn:SetScript("OnLeave", function(b) if not b._active then b._bg:SetColorTexture(0, 0, 0, 0)          end end)
    local secKey = sec.key
    btn:SetScript("OnClick", function() ShowSection(secKey) end)
    navButtons[sec.key] = btn
  end

  -- === Section A: General ===
  do
    local panel = contentPanels["General"]
    MakeSectionHeader(panel, "General", -8)

    local active = CreateFrame("CheckButton", "CantHealYouOptionsActive", panel, "UICheckButtonTemplate")
    active:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -30)
    CantHealYouOptions_CheckButtonText(active, CHYstrings.UImasterswitch, CHYstrings.UImasterswitchhelp)

    local onlyHealer = CreateFrame("CheckButton", "CantHealYouOptionsOnlyWhenHealer", panel, "UICheckButtonTemplate")
    onlyHealer:SetPoint("TOPLEFT", active, "BOTTOMLEFT", 0, -8)
    CantHealYouOptions_CheckButtonText(onlyHealer, CHYstrings.UIonlywhenhealer, CHYstrings.UIonlywhenhealerhelp)

    local onlyPRG = CreateFrame("CheckButton", "CantHealYouOptionsOnlyPartyRaidGuild", panel, "UICheckButtonTemplate")
    onlyPRG:SetPoint("TOPLEFT", onlyHealer, "BOTTOMLEFT", 0, -8)
    CantHealYouOptions_CheckButtonText(onlyPRG, CHYstrings.UIonlypartyraidguild, CHYstrings.UIonlypartyraidguildhelp)

    local inBG = CreateFrame("CheckButton", "CantHealYouOptionsInBattlegrounds", panel, "UICheckButtonTemplate")
    inBG:SetPoint("TOPLEFT", onlyPRG, "BOTTOMLEFT", 0, -8)
    CantHealYouOptions_CheckButtonText(inBG, CHYstrings.UIinbattlegrounds, CHYstrings.UIinbattlegroundshelp)
  end

  -- === Section B: Spell Warnings ===
  do
    local panel = contentPanels["SpellWarnings"]
    MakeSectionHeader(panel, "Spell Warnings", -8)
    MakeColumnHeaders(panel)

    local oorCb = MakeRow(panel, panel, -44,
      "CantHealYouOptionsDoOutOfRange", "CantHealYouOptionsOutOfRange", "CantHealYouOptionsOutOfRangeInterval",
      CHYstrings.UIoutofrange, CHYstrings.UIoutofrangehelp)

    local losCb = MakeRow(panel, oorCb, -ROW_H,
      "CantHealYouOptionsDoLineOfSight", "CantHealYouOptionsLineOfSight", "CantHealYouOptionsLineOfSightInterval",
      CHYstrings.UIlineofsight, CHYstrings.UIlineofsighthelp)

    local abCb = MakeRow(panel, losCb, -ROW_H,
      "CantHealYouOptionsDoAuraBounced", "CantHealYouOptionsAuraBounced", "CantHealYouOptionsAuraBouncedInterval",
      CHYstrings.UIbuffbounced, CHYstrings.UIbuffbouncedhelp)

    MakeRow(panel, abCb, -ROW_H,
      "CantHealYouOptionsDoInterrupted", "CantHealYouOptionsInterrupted", "CantHealYouOptionsInterruptedInterval",
      CHYstrings.UIinterrupted, CHYstrings.UIinterruptedhelp)
  end

  -- === Section C: Status Warnings ===
  do
    local panel = contentPanels["Status"]
    MakeSectionHeader(panel, "Status Warnings", -8)
    MakeColumnHeaders(panel)

    local lostCb, lostMsg = MakeRow(panel, panel, -44,
      "CantHealYouOptionsDoLostControl", "CantHealYouOptionsLostControl", "CantHealYouOptionsLostControlInterval",
      CHYstrings.UIincapacitated, CHYstrings.UIincapacitatedhelp)

    -- GainedControl: edit box below lostMsg, "Regained:" label to its left
    local gainedMsg = MakeEditBox("CantHealYouOptionsGainedControl", panel, MSG_W, false)
    gainedMsg:SetPoint("TOPLEFT", lostMsg, "BOTTOMLEFT", 0, -8)
    local gainedLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gainedLabel:SetPoint("RIGHT", gainedMsg, "LEFT", -4, 0)
    gainedLabel:SetText("Regained:")

    -- Immune row: -(ROW_H+30) from lostCb to clear the GainedControl box
    local immuneCb = MakeRow(panel, lostCb, -(ROW_H + 30),
      "CantHealYouOptionsDoImmune", "CantHealYouOptionsImmune", "CantHealYouOptionsImmuneInterval",
      CHYstrings.UIimmune, CHYstrings.UIimmunehelp)

    -- Low Mana: manual layout — narrower message (185) + threshold box + label + interval
    local lowCb = CreateFrame("CheckButton", "CantHealYouOptionsDoLowMana", panel, "UICheckButtonTemplate")
    lowCb:SetPoint("TOPLEFT", immuneCb, "BOTTOMLEFT", 0, -ROW_H)
    CantHealYouOptions_CheckButtonText(lowCb, CHYstrings.UIlowmana, CHYstrings.UIlowmanahelp)

    local lowMsg = MakeEditBox("CantHealYouOptionsLowMana", panel, 185, false)
    lowMsg:SetPoint("TOPLEFT", lowCb, "TOPLEFT", MSG_XOFF, 3)

    local threshold = MakeEditBox("CantHealYouOptionsLowManaThreshold", panel, 35, true)
    threshold:SetPoint("LEFT", lowMsg, "RIGHT", 10, 0)

    local threshLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    threshLabel:SetPoint("LEFT", threshold, "RIGHT", 4, 0)
    threshLabel:SetText(CHYstrings.UIlowmanathreshold)

    local lowInt = MakeEditBox("CantHealYouOptionsLowManaInterval", panel, INT_W, true)
    lowInt:SetPoint("LEFT", threshLabel, "RIGHT", 4, 0)
  end

  -- === Section D: Externals ===
  do
    local panel = contentPanels["Externals"]
    MakeSectionHeader(panel, "Externals", -8)
    MakeColumnHeaders(panel)

    MakeRow(panel, panel, -44,
      "CantHealYouOptionsDoExternalCDs", "CantHealYouOptionsExternalCD", "CantHealYouOptionsExternalCDInterval",
      CHYstrings.UIexternalcds, CHYstrings.UIexternalcdshelp)
  end

  -- Default to General section
  ShowSection("General")
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
