-- Can't Heal You localization - English

-- to localize for other languages:

-- uncomment the next line and change "enUS" to the proper string for the language you're localizing for
-- if ( GetLocale() ~= "enUS" ) then return; end

-- for each item below, translate the text associated with it.  Do not translate the text
-- between the [square brackets]!  

-- Anywhere you see %s, that's where the name of the spell being cast will appear.

CHYstrings = {

["OutOfRange"] = "I'm casting %s on you, but you're out of range!",

["LineOfSight"] = "I'm casting %s on you, but you're not in line of sight!",

["LostControl"] = "I've been incapacitated and can't heal!",

["GainedControl"] = "I've recovered and can heal again.",

["AuraBounced"] = "I'm casting %s on you, but a more powerful version is already on you.",

["Interrupted"] = "I was interrupted while casting %s on you!",

["UItitle"] = "Can't Heal You",

["UImasterswitch"] = "Master Switch",

["UImasterswitchhelp"] = "Uncheck to turn off all notifications.",

["UIsendwarningsfor"] = "Send warnings for:",

["UIonlypartyraidguild"] = "Only Party/Raid/Guild",

["UIonlypartyraidguildhelp"] = "Check to whisper only players in your party, raid, or guild.",

["UIinbattlegrounds"] = "In Battlegrounds",

["UIinbattlegroundshelp"] = "Check to enable whispering when in battlegrounds.",

["UIonlywhenhealer"] = "Only When Healer",

["UIonlywhenhealerhelp"] = "Check to only send warnings when you are in a healer specialization.",

["UIoutofrange"] = "Out of Range?",

["UIoutofrangehelp"] = "Check to whisper players if they run out of your range while you're casting.",

["UIlineofsight"] = "Line of Sight?",

["UIlineofsighthelp"] = "Check to whisper players if they're out of your line of sight when you cast.",

["UIbuffbounced"] = "Buff Bounced?",

["UIbuffbouncedhelp"] = "Check to whisper players if you try to buff them, but they have a more powerful buff on them.",

["UIinterrupted"] = "Interrupted?",

["UIinterruptedhelp"] = "Check to whisper players if you are interrupted while casting on them.",

["UIincapacitated"] = "Incapacitated?",

["UIincapacitatedhelp"] = "Check to announce to your party or raid when you are stunned, charmed, or otherwise incapacitated.",

["UIinterval"] = "seconds to wait between whispers to the same player",

["UIsavedefaults"] = "Save as Defaults",

["UIloaddefaults"] = "Set to Defaults",

}