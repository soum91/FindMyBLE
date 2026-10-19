# FindMyBLE

Find My style tracker for any Bluetooth LE device (built for a LARQ bottle). It holds a connection to the item, and when the link drops for longer than the alert delay you get a time-sensitive notification and a pin on the map where you left it. You get another ping when it's back in range.

Requires iOS 17+.

## What's in it

The full-screen map shows you and your item's last-seen pin. The bottom sheet has two tabs. **Items** lists what you're tracking, with status (With You, Searching, Left Behind with how long ago) and distance from you. Tap an item for its detail: the street it was left near, **Directions** in Apple Maps, **Find Nearby** (a signal-strength view that grows as you get closer), Notify When Left Behind, the alert delay, and Remove. **Me** shows permission status. Add an item with the **+** button, which scans for nearby devices.

## Getting it on your phone

**Option A: grab the IPA.** Every push to `main` builds an unsigned IPA and publishes it as a release. Download `FindMyBLE-unsigned.ipa` from the [latest release](../../releases/latest) and install with Sideloadly, AltStore or TrollStore.

**Option B: build it yourself on a Mac.**

```sh
brew install xcodegen
xcodegen generate
open FindMyBLE.xcodeproj
```

Set your team under Signing & Capabilities and run it on your phone. Background Bluetooth mode, the icon and all the permission strings are already set in `project.yml`. Optionally add the **Time Sensitive Notifications** capability (paid dev account) so Focus can't mute the alert.

## First run

Close the LARQ app first (swipe it away). Open FindMyBLE, allow notifications, allow location and pick **Always** when iOS asks the second time. Tap **+**, filter for LARQ, tap the bottle. It shows "With You" as soon as it hears the bottle. If you added it before this update, remove it and add it again so the app picks up its service ID.

## How it works

FindMyBLE doesn't hold a Bluetooth connection. Cheap gadgets like the LARQ cap drop connections to save battery and come back under a new random address, which kills any connection-based tracker. Instead the app listens for the item's advertisements by name. Every time it hears one, it pushes the "left behind" notification further out. If the item goes quiet for longer than the alert time (3 min by default), that notification fires. The notification system owns the timer, so it works even while the app is suspended.

Background scanning on iOS only works for devices that advertise a service UUID. FindMyBLE grabs those when you add the item. If an item has none, it can only be tracked while the app is open, and the item page warns you.

At each sighting the app also saves the phone's location, so the pin marks where it last heard the item.

## Why "Only When I Leave the Area"

The LARQ cap goes radio-silent for ten-plus minutes at a time even when it's sitting right next to you, so any "haven't heard it in N minutes" alarm fires while you're in the next room. The default alert mode ignores time entirely. It drops a geofence around wherever the cap was last heard and only alerts when your phone actually leaves that area without the cap coming along. Sit at home all day with a napping cap and you get nothing; walk out the door without it and you get the alert. There's a short grace after you leave so a cap that wakes on movement (it has an accelerometer) can check in before anything fires. This needs location set to Always. Turn the toggle off on the item page if you'd rather have the simple time-based alarm.

## Keep Connected (optional)

By default the app only listens for advertisements and never connects. Turn on **Keep Connected** on the item page and it holds an open BLE connection instead. A connected peripheral usually keeps its radio awake, which is what stops the LARQ cap from dropping off every few minutes, and it lets the cap report its battery level over the standard battery service. Presence tracking keeps running underneath, so left-behind alerts still work if the connection drops.

For a LARQ cap there's also **Stop Cap Power-Saving**, which sends the cap its own "power saving off" command so it keeps advertising. This is LARQ-specific, harmless, and just costs a little cap battery. It only touches the power-saving setting, nothing else on the cap.

## Gotchas

- **Don't force-quit it** from the app switcher. iOS then stops waking it for Bluetooth events.
- **After a reboot**, open it once. Restoration doesn't survive a restart.
- **Location must be set to Always**, otherwise the pin only gets saved when the app happens to be open.
- **Keep the LARQ app closed.** While it's connected to the bottle, the bottle stops advertising and FindMyBLE can't hear it.
- **Getting false alarms?** iOS slows down background scanning when the screen is locked, so bump the alert time up a few minutes.
- Find Nearby and signal strength only update while the app is open.
