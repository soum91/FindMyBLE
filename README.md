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

Close the LARQ app first (swipe it away). Open FindMyBLE, allow notifications, allow location and pick **Always** when iOS asks the second time. Tap **+**, filter for LARQ, tap the bottle. It shows "With You" once connected.

## How it works

CoreBluetooth holds the connection and keeps a pending connect armed after every drop. iOS keeps that pending connect alive forever in the background, so the app hears about it the moment the item is back. The "left behind" alert is a delayed local notification that gets cancelled if the link returns within the delay window, which is why the delay works even while the app is suspended. State restoration lets iOS relaunch the app in the background for Bluetooth events.

On disconnect the app records the phone's location (the cached fix right away, then a fresh one). BLE range is about 10 to 30 m, so that pin is where the item was left.

## Gotchas

- **Don't force-quit it** from the app switcher. iOS then stops waking it for Bluetooth events.
- **After a reboot**, open it once. Restoration doesn't survive a restart.
- **Location must be set to Always**, otherwise the pin only gets saved when the app happens to be open.
- **The LARQ app may hog the bottle.** Many BLE gadgets accept only one connection. Keep the LARQ app closed and only open it to sync.
- **The cap may sleep.** If the bottle disconnects on its own to save battery you'll get false alarms. Raise the alert delay. If it still drops every few minutes, connection monitoring won't work for that device and a Find My tag is the reliable answer.
- Find Nearby and signal strength only update while the app is open.
