# Can't Heal You

*Originally written by Travis S. Casey. Updated for WoW Midnight (Interface 120001, build 12.0.1.66192) by Kroth (Haomarush).*

[Wago.io](https://addons.wago.io/addons/canthealyou) · [CurseForge](https://www.curseforge.com/wow/addons/cant-heal-you-for-midnight)

Healers! Ever tried to heal or buff someone, only they're out of range or out of your line of sight? And in the middle of a fight, you're casting too fast and furious to take time to tell them?

## What Can't Heal You Does

Can't Heal You will help you out by whispering the target of your spell when that happens — telling them what you're trying to cast on them, and why it isn't working, so they can try to move where you *can* heal them. Or at least you can tell them afterwards, "What? You didn't see those twenty messages telling you you were out of my line of sight?"

Beyond that, Can't Heal You can whisper people when you try to buff them but they have a higher level buff already, when you're sheeped, silenced, or otherwise prevented from casting (in some cases, it may not know that you've been prevented from casting until you try to cast a spell), and when you're interrupted while casting in combat.

To keep from spamming random people you try to buff, it also checks to see if the spell's target is in your party, raid, or guild, and only whispers them if they're in one of those.

Can't Heal You works in combination with Healbot, Grid+Clique, etc. — since it detects the game events involved with spellcasting, it should work no matter how you cast the spell. It also uses Blizzard's internal names for events and errors, so even if the interface hasn't been localized in your language, Can't Heal You will still send messages at the appropriate times.

It's not just for healers either — it works for any buff, so mages trying to hand out Arcane Intellect can automatically whisper people too!

By default, Can't Heal You only sends warnings when you are in a healer specialization (or have been assigned the healer role in a group). You can turn this off in the options panel if you want it active regardless of your spec.

Can't Heal You has a configuration panel you can open at any time with the `/chy` command. It is also accessible from the **Addons** tab in **Game Menu > Interface**. There, you can choose what things you want Can't Heal You to warn others about, change the messages that Can't Heal You gives, or even turn off Can't Heal You entirely. Each of your characters has their own configuration.

The options panel can be dragged to reposition it, and has a **Save & Close** button to apply your changes.

## Warnings and Gotchas

**Out of range detection:** If your target is already out of range when you start to cast the spell, and the game knows this (i.e., it's showing a red "out of range" dot or number on the spell), the game won't even try to cast the spell. Since Can't Heal You works by detecting the message the game sends to the server when you cast a spell and getting the target information from it, the automatic detection won't work then. See [Manual Warning](#manual-warning) below for a workaround.

**AoE spells:** Players won't get whispered for spells that don't directly target them. For example, Holy Nova won't whisper anyone since it's an AoE, not targeted.

**Interrupted spellcasts:** Can't Heal You tries to warn people when you can't heal them for a reason that's out of your control, so it tries to detect if your spellcast was interrupted because you moved and not send warnings in that case. However, Blizzard doesn't provide a way for an addon to tell whether you're moving because you wanted to, or because something knocked you back. Thus, if you're interrupted by a knockback ability, Can't Heal You most likely won't say anything about that to your target.

**Silence/stun detection:** Sometimes WoW sends a message as soon as something prevents you from casting, and sometimes it doesn't until you try to cast. Thus, if you're silenced or the like, Can't Heal You may not say anything until you try to cast a spell. On the flip side, the same thing can happen when you recover — Can't Heal You might not tell people you can cast again until you successfully cast a spell.

## Commands

| Command | Description |
|---------|-------------|
| `/chy` | Opens (or closes) the options panel |
| `/chy help` | Shows a summary of available commands |
| `/chy debug` | Toggles debug mode on or off — shows diagnostic output for troubleshooting |
| `/chy reset` | Resets all settings for this character to the defaults |
| `/chy resetall` | Resets settings for the current character and the defaults used for new characters |

## Manual Warning

*For advanced users*

As noted above, Can't Heal You doesn't see spellcasts if you're already out of range when you try to cast. However, there is a workaround if you're comfortable with macros. Can't Heal You provides a `/chyw` command to check range and automatically whisper someone if they're out of range. Use it in a macro like this:

```
#showtooltip
/chyw Greater Heal
/cast Greater Heal
```

`/chyw` accepts all the same options as `/cast`, so if you're using modifier keys to cast different spells, fancy targeting, etc., you can duplicate your `/cast` line and just change `/cast` to `/chyw`.

Have fun!
