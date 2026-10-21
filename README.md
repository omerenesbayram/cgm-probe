# CGM Probe

A small Flutter test app that reads an **Accu-Chek SmartGuide** CGM over Bluetooth
and shows the raw and decoded glucose values. It is the first step toward the
meal + glucose app; it is a developer tool, not a medical device.

## What it does

1. **Find sensor**: lists SmartGuide sensors (`AC-<serial>`) that are either
   - already connected to this phone by another app such as mySugr (shared connection), or
   - advertising nearby.
2. **Connect**: reads device info, CGM Feature, Session Start Time, Session Run Time and Status.
3. **Listen**: subscribes to CGM Measurement and shows each reading (every 5 min).
4. **Copy**: the toolbar buttons copy the readings (CSV) or the full log to the clipboard.
5. **Demo**: plays back a real captured reading, then fake data, to test the screens without a sensor.

It never writes to the sensor's control points (RACP `2A52`, SOCP `2AAC`), so it
cannot change sensor settings or calibration.

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
| RACP | `2A52` | history download (not used yet) |
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
