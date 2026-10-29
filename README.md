<img width="1584" height="672" alt="image" src="https://github.com/user-attachments/assets/2b14e4c7-da52-47f9-b9d9-f9b00892ad2e" />


Time To Drink - Octowow / vanilla 1.12 addon  v1.3.4
==================================================

WHAT IT DOES
  In a 5-man party (disabled in raids) it watches a healer you pick and posts
  to PARTY chat when their mana drops below your threshold, repeating on a
  cooldown you set (minimum 10s).

  Out of a party, your own character is listed and selected automatically so
  you can set things up and watch the mana readout. When you join a new party
  the selection clears and the window opens so you can pick the real healer.

  Optional OOM alert: a second, lower threshold with its own message. When the
  healer is below the OOM threshold, the OOM message is sent instead of the
  low-mana message.

ON-SCREEN WARNING
  Tick "On-screen warning (only you see it)" to get a large message in the
  middle-top of your screen whenever the low-mana or OOM alert triggers. It
  shows the same text as the party message (yellow for low mana, red for OOM)
  with an optional raid-warning sound. Nobody else sees it.
  - It runs on its own timer, so you still see it even if another player's
    copy of the addon already posted to party chat.
  - It works even with "Mute party chat alerts" ticked, so you can use it as a
    private warning only.
  - It also works when you are not in a party (watching your own mana),
    but never in raids. Party chat alerts still need a 5-man party.
  - The Test button (or /ttd screen) shows a sample.

CUSTOM MESSAGES
  All three messages can be edited in the window (press Enter to save,
  Escape to cancel). Leaving a box empty restores its default.
    - Low mana message
    - OOM message
    - Healer selected message (sent when you pick a healer)

  Tokens you can use in any message:
    {healer}     the selected healer's name
    {mana}       the healer's current mana %
    {threshold}  your low-mana threshold %
    {oom}        your OOM threshold %

  Example:  {healer} is at {mana}% mana, slow down!
  The "Reset messages" button puts all three back to the defaults.

INSTALL
  Copy the "TimeToDrink" folder into <Octowow>\Interface\AddOns\ so you have:
     ...\Interface\AddOns\TimeToDrink\TimeToDrink.toc
     ...\Interface\AddOns\TimeToDrink\TimeToDrink.lua
  IMPORTANT: make sure it is NOT double-nested (no TimeToDrink\TimeToDrink\...).
  Then /reload or restart, and tick it in the AddOns list at character select.
  Your existing settings carry over from v1.1.

COMMANDS
  /ttd          open / close the window (Escape also closes it)
  /ttd preview  show your three messages in your own chat (nothing is sent)
  /ttd oom      turn the OOM alert on / off
  /ttd screen   turn the on-screen warning on / off
  /ttd enable   unmute party chat alerts
  /ttd disable  mute party chat alerts
  /ttd reset    recenter the window and show it
  /ttd status   print current settings and party state
  /ttd test     send a test line to party chat (only works while in a party)
  /ttd minimap  show / hide the minimap button
  /ttd debug    toggle verbose messages

TROUBLESHOOTING
  Turn on Lua errors so problems are visible:  /console scriptErrors 1
  This build also prints any error to your chat in red starting "TTD error:".
