# CGM Probe

A small Flutter test app that reads an **Accu-Chek SmartGuide** CGM over Bluetooth
and shows the raw and decoded glucose values. It is the first step toward the
meal + glucose app; it is a developer tool, not a medical device.

## What it does

1. **Find sensor**: lists SmartGuide sensors (`AC-<serial>`) that are either
   - already connected to this phone by another app such as mySugr (shared connection), or
   - advertising nearby. The list can be tapped while the search is still running.
2. **Pair (Android)**: asks for the PIN from the applicator cap *before* connecting, like
   mySugr. The app answers Android's pairing request itself (`MainActivity.kt`), so the
   system's own PIN dialog does not appear.
3. **Connect**: reads CGM Feature, Session Start Time, Session Run Time, Status and device info,
   then subscribes to CGM Measurement (a reading every 5 min).
4. **Record**: every reading is appended to one file per sensor, in the replay format
   (`lib/cgm/replay.dart`). On Android it is in
   `/sdcard/Android/data/com.omerb.cgm_probe/files/recordings/<sensor>.txt` (`adb pull` works).
5. **Catch up**: on every (re)connection the app asks the sensor for the readings it missed.
   The sensor keeps only the **last 8 hours (96 readings)**. The button
   "Download stored readings" asks for all of them.
6. **Remember**: after the first connection the sensor is saved. Every launch reconnects,
   reloads the recording and catches up, without any tap. A lost connection is retried
   automatically. **Forget sensor** stops this (the phone pairing and recording are kept).
7. **Background (Android)**: a foreground service ("Recording glucose" notification) keeps the
   app alive with the screen off, until the app is closed.
8. **Graph**: glucose over time with the 70–180 mg/dL range shaded.
9. **Demo**: a simulated sensor goes through search, PIN entry and pairing, then replays
   8 hours recorded from a real sensor (`assets/replay/smartguide_8h.txt`).
10. **Copy**: the toolbar buttons copy the readings (CSV) or the full log to the clipboard.

The only thing the app writes to the sensor is a Record Access Control Point request for
stored readings (what mySugr does to fill gaps). It never uses the settings control point
(SOCP `2AAC`), so it cannot change sensor settings or calibration.

### Sensor behaviour learned so far

- **One pairing at a time** (CGM Feature: multiple bonds not supported). Pairing a new phone
  moves the sensor away from the old one.
- **Changing Bluetooth address** (resolvable private address). Phones with Bluetooth 4.2+
  follow it; older ones (Nexus 6P, Android 8.1) appear to keep dialing the pairing-time address
  and time out (error 133). The app then pairs again with the saved PIN, if the sensor is
  nearby (this fallback is not yet confirmed on a device).
- After a new pairing the sensor sometimes drops the link; the app reconnects.
- mySugr can rewrite the Session Start Time (seen moving by 2 s after re-pairing an iPhone).

## Running it

### Android (Galaxy S7 or newer)

1. On the phone: Settings > About phone > Software information, tap **Build number** 7 times,
   then enable **USB debugging** in Developer options.
2. Connect by USB, accept the "Allow USB debugging" prompt.
3. `flutter run` (or `flutter run --release`).
4. On Android 11 and older, **Location must be on** for Bluetooth scanning.

> **Pairing warning.** Your current sensor is paired with your iPhone. Connecting from an
> Android phone triggers a new pairing (PIN prompt), which may take the sensor away from the
> iPhone. The app asks before doing this. On Android, use **Demo** and **Find sensor** freely,
> but only pair a sensor you are prepared to move off mySugr.

### iPhone (needs a Mac with Xcode)

1. Mac: install Xcode and Flutter, add your Apple ID in Xcode > Settings > Accounts.
2. iPhone: Settings > Privacy & Security > **Developer Mode** on; connect by cable, trust the Mac.
3. Open `ios/Runner.xcworkspace` once, select the Runner target > Signing & Capabilities,
   choose your Personal Team and a unique bundle id.
4. `flutter run --release` (debug builds can't be opened from the home screen without the Mac).
5. Free Apple ID installs expire after 7 days; run step 4 again to refresh.

With mySugr running, **Find sensor** should list the sensor as "Already connected to this
phone". Tap it, wait up to 5 minutes, and compare the value with mySugr.

## Protocol notes

The SmartGuide uses the standard Bluetooth SIG **CGM Service (`181F`)**; the PIN on the
applicator cap is the Bluetooth pairing passkey.

| Characteristic | UUID | Notes |
|---|---|---|
| CGM Measurement | `2AA7` | notify; size, flags, glucose (SFLOAT mg/dL), minutes since start, status, trend, quality, CRC |
| CGM Feature | `2AA8` | capability bits, incl. E2E-CRC and multiple-bond support |
| CGM Status | `2AA9` | minutes since start + 24-bit status |
| Session Start Time | `2AAA` | UTC on the SmartGuide (time zone field 0) |
| Session Run Time | `2AAB` | 336 h = 14 days |
| RACP | `2A52` | stored readings: `01 01` all, `01 03 01 <offset>` newer than an offset; answers `06 00 01 01` |
| SOCP | `2AAC` | sensor commands (not used) |

Every record ends with an **E2E-CRC: CRC-16/MCRF4XX, little-endian**, verified against
captured bytes in `test/cgm_parser_test.dart`.

## Layout

```
lib/cgm/   pure Dart decoders (CRC, SFLOAT, characteristics), unit-tested
lib/ble/   Bluetooth: finding, connecting, reading, subscribing
lib/ui/    the single probe screen
```

`flutter test` runs the decoder tests on any machine, no phone needed.
